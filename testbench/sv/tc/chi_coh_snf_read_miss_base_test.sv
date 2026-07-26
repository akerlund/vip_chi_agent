// ===========================================================================
// chi_coh_snf_read_miss_base_test
//
// Two-level hierarchy: cold-miss downstream READ fetch. With hnf_downstream_en=1
// the HN-F no longer synthesizes cold-line data itself -- on a directory/mem miss
// it issues a ReadNoSnp to the downstream SN-F, fills its memory from the reply,
// and completes the RN-F from the fetched line:
//   RN-F0 ReadShared L (cold) -> HN-F miss -> ReadNoSnp(L) to SN-F
//                              -> SN-F CompData -> HN-F fills mem, grants SC
// Asserts: RN-F0 is granted SC with data; the SN-F observed exactly one ReadNoSnp
// for the line (the definitive proof the fetch happened -- the HN-F and SN-F share
// the same synthetic backing pattern, so a data value alone cannot distinguish a
// downstream fetch from a local synthesis); Checker D silent.
//
// Used by:
//   tc_chi_coh_e_snf_read_miss  (wide CHI-E)
//   tc_chi_coh_d_snf_read_miss    (CHI-D)
// ===========================================================================
class chi_coh_snf_read_miss_base_test #(
  vip_chi_cfg_t CFG_P   = CHI_D_CFG_C,
  type          TYPES_T = chi_d_types_t
) extends chi_coherent_base_test #(CFG_P, TYPES_T);

  typedef vip_chi_item #(CFG_P) item_t;

  `uvm_component_param_utils(chi_coh_snf_read_miss_base_test #(CFG_P, TYPES_T))

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // Enable the downstream SN-F behind the HN-F.
  protected virtual function void configure_agent_cfgs();
    super.hnf_cfg.hnf_downstream_en = 1'b1;
  endfunction


  task run_phase(input uvm_phase phase);

    item_t shared_rsp[$];
    item_t dn_req;
    int    n_dn_req;

    phase.raise_objection(this);

    super.wait_reset_settle();

    // RN-F0 reads a cold line -> the HN-F must fetch it from the SN-F.
    this.cfg_read_seq(super.hrnf0_rdshared_seq);
    super.hrnf0_rdshared_seq.start(super.tb_env.hrnf0_agent.sequencer);
    shared_rsp = super.hrnf0_rdshared_seq.get_responses();

    super.wait_clocks(8);

    if (shared_rsp.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] expected 1 response, got %0d", super.tc_name, shared_rsp.size()))
    end
    if (shared_rsp[0].rsp_resp != VIP_CHI_RESP_STATE_SC_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] ReadShared granted 0x%0h, expected SC", super.tc_name, shared_rsp[0].rsp_resp))
    end
    if (shared_rsp[0].data.size() == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] ReadShared returned no data beats", super.tc_name))
    end

    // The SN-F must have seen exactly one ReadNoSnp for the line (proof of fetch).
    n_dn_req = 0;
    while (super.tb_env.dsnf0_req_fifo.try_get(dn_req)) begin
      n_dn_req++;
      if (vip_chi_req_opcode_t'(dn_req.opcode) != VIP_CHI_REQ_READ_NO_SNP_E) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] downstream REQ opcode 0x%0h, expected ReadNoSnp (0x%0h)",
          super.tc_name, dn_req.opcode, VIP_CHI_REQ_READ_NO_SNP_C))
      end
      if (dn_req.addr != item_t::addr_t'(WRITE_READ_ADDR_C)) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] downstream ReadNoSnp addr 0x%0h, expected 0x%0h",
          super.tc_name, dn_req.addr, item_t::addr_t'(WRITE_READ_ADDR_C)))
      end
    end
    if (n_dn_req != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] SN-F saw %0d downstream REQs, expected exactly 1 ReadNoSnp",
        super.tc_name, n_dn_req))
    end

    if ((super.tb_env.coh_checker.get_multi_owner_count() != 0) ||
        (super.tb_env.coh_checker.get_coherent_data_mismatch_count() != 0)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] coherency violation on a legal downstream fetch (multi=%0d data=%0d)",
        super.tc_name, super.tb_env.coh_checker.get_multi_owner_count(),
        super.tb_env.coh_checker.get_coherent_data_mismatch_count()))
    end

    phase.drop_objection(this);
  endtask
endclass
