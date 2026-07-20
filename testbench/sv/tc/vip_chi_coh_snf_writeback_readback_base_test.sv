// ===========================================================================
// vip_chi_coh_snf_writeback_readback_base_test
//
// Two-level hierarchy: writeback flush to the SN-F, then a re-fetch proves the
// value is SN-resident. With hnf_downstream_en=1 a WriteBackFull is flushed to
// the SN-F (WriteNoSnpFull) and the HN-F drops its local memory image, so a later
// read MISSES and must re-fetch the written-back value from the SN-F:
//   RN-F0 ReadUnique L (cold) -> ReadNoSnp fetch (original image)
//   RN-F0 WriteBackFull L      -> WriteNoSnpFull flush to SN-F + local invalidate
//   RN-F1 ReadShared L         -> MISS -> ReadNoSnp re-fetch -> written-back data
// Asserts: the read-back equals the writeback payload and differs from the
// original (non-vacuous); the SN-F observed exactly ReadNoSnp, WriteNoSnpFull,
// ReadNoSnp in order (the full downstream round-trip); Checker D silent.
//
// Used by:
//   tc_chi_coh_e_snf_writeback_readback  (wide CHI-E)
//   tc_chi_coh_d_snf_writeback_readback    (CHI-D)
// ===========================================================================
class vip_chi_coh_snf_writeback_readback_base_test #(
  vip_chi_cfg_t CFG_P   = CHI_D_CFG_C,
  type          TYPES_T = chi_d_types_t
) extends vip_chi_coherent_base_test #(CFG_P, TYPES_T);

  typedef vip_chi_item #(CFG_P) item_t;

  `uvm_component_param_utils(vip_chi_coh_snf_writeback_readback_base_test #(CFG_P, TYPES_T))

  vip_chi_writeback_seq #(CFG_P) hrnf0_wb_seq;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  protected virtual function void configure_agent_cfgs();
    super.hnf_cfg.hnf_downstream_en = 1'b1;
  endfunction

  function void start_of_simulation_phase(input uvm_phase phase);
    super.start_of_simulation_phase(phase);
    this.hrnf0_wb_seq = vip_chi_writeback_seq #(CFG_P)::type_id::create("hrnf0_wb_seq");
  endfunction


  task run_phase(input uvm_phase phase);

    item_t rdu_rsp[$];
    item_t wb_rsp[$];
    item_t rd_rsp[$];
    item_t dn_req;
    bit    differs_from_original;
    vip_chi_req_opcode_t dn_ops [$];

    phase.raise_objection(this);

    super.wait_reset_settle();

    // 1) RN-F0 acquires the cold line Unique (fetched from the SN-F).
    this.cfg_read_seq(super.hrnf0_rdunique_seq);
    super.hrnf0_rdunique_seq.start(super.tb_env.hrnf0_agent.sequencer);
    rdu_rsp = super.hrnf0_rdunique_seq.get_responses();

    // 2) RN-F0 writes a fresh payload back -> flushed to the SN-F + local invalidate.
    this.cfg_read_seq(this.hrnf0_wb_seq);
    this.hrnf0_wb_seq.start(super.tb_env.hrnf0_agent.sequencer);
    wb_rsp = this.hrnf0_wb_seq.get_responses();

    // 3) RN-F1 reads Shared -> local miss -> re-fetch from the SN-F.
    this.cfg_read_seq(super.hrnf1_rdshared_seq);
    super.hrnf1_rdshared_seq.start(super.tb_env.hrnf1_agent.sequencer);
    rd_rsp = super.hrnf1_rdshared_seq.get_responses();

    super.wait_clocks(8);

    if ((rdu_rsp.size() != 1) || (wb_rsp.size() != 1) || (rd_rsp.size() != 1)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] expected 1/1/1 responses, got %0d/%0d/%0d",
        super.tc_name, rdu_rsp.size(), wb_rsp.size(), rd_rsp.size()))
    end

    if ((wb_rsp[0].data.size() != rd_rsp[0].data.size()) ||
        (rdu_rsp[0].data.size() != rd_rsp[0].data.size())) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] beat-count mismatch: rdu %0d wb %0d rd %0d", super.tc_name,
        rdu_rsp[0].data.size(), wb_rsp[0].data.size(), rd_rsp[0].data.size()))
    end

    // Re-fetched read-back must equal the writeback payload (survived in the SN-F).
    foreach (rd_rsp[0].data[i]) begin
      if (rd_rsp[0].data[i] !== wb_rsp[0].data[i]) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] beat %0d re-fetched 0x%0h != written-back 0x%0h",
          super.tc_name, i, rd_rsp[0].data[i], wb_rsp[0].data[i]))
      end
    end

    // Non-vacuity: it must differ from the original image (else a no-op flush
    // or a stale local hit would masquerade as a pass).
    differs_from_original = 1'b0;
    foreach (rd_rsp[0].data[i]) begin
      if (rd_rsp[0].data[i] !== rdu_rsp[0].data[i]) begin
        differs_from_original = 1'b1;
      end
    end
    if (!differs_from_original) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] re-fetched data equals the original image - check is vacuous",
        super.tc_name))
    end

    // The SN-F must have seen ReadNoSnp, WriteNoSnpFull, ReadNoSnp in order.
    while (super.tb_env.dsnf0_req_fifo.try_get(dn_req)) begin
      dn_ops.push_back(vip_chi_req_opcode_t'(dn_req.opcode));
    end
    if (dn_ops.size() != 3) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] SN-F saw %0d downstream REQs, expected 3 (read/write/read)",
        super.tc_name, dn_ops.size()))
    end
    if ((dn_ops[0] != VIP_CHI_REQ_READ_NO_SNP_E) ||
        (dn_ops[1] != VIP_CHI_REQ_WRITE_NO_SNP_FULL_E) ||
        (dn_ops[2] != VIP_CHI_REQ_READ_NO_SNP_E)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] downstream REQ sequence 0x%0h/0x%0h/0x%0h, expected ReadNoSnp/WriteNoSnpFull/ReadNoSnp",
        super.tc_name, dn_ops[0], dn_ops[1], dn_ops[2]))
    end

    if ((super.tb_env.coh_checker.get_multi_owner_count() != 0) ||
        (super.tb_env.coh_checker.get_coherent_data_mismatch_count() != 0)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] coherency violation on a legal writeback+refetch (multi=%0d data=%0d)",
        super.tc_name, super.tb_env.coh_checker.get_multi_owner_count(),
        super.tb_env.coh_checker.get_coherent_data_mismatch_count()))
    end

    phase.drop_objection(this);
  endtask
endclass
