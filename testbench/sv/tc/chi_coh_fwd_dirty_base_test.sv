// ===========================================================================
// chi_coh_fwd_dirty_base_test
//
// Direct cache transfer (DCT) of DIRTY data. Like tc_chi_coh_d_dirty_forward but
// with hnf_enable_snoop_fwd=1, so the modified data reaches the requester by a
// forwarding snoop rather than a plain downgrade + serve-from-memory:
//   RN-F0 ReadUnique L        -> UC, caches L's beats
//   make_line_dirty(L, PAT)   -> UD, held beats = orig ^ PAT
//   RN-F1 ReadShared L        -> HN-F SnpSharedFwd(RN-F0, FwdNID=RN-F1)
//                                -> RN-F0 SnpRespDataFwded(SC, orig^PAT)
//                                -> HN-F merges orig^PAT to memory AND relays it
//                                   as CompData(SC, orig^PAT) to RN-F1
// Asserts: RN-F1's forwarded CompData carries the DIRTIED data (orig ^ PAT, which
// differs from the original image); the snoop was a SnpSharedFwd; RN-F1 SC,
// RN-F0 SC; a follow-up read sees the merged dirty data (home now authoritative);
// Checker D silent.
//
// Used by:
//   tc_chi_coh_e_fwd_dirty  (wide CHI-E)
//   tc_chi_coh_d_fwd_dirty    (CHI-D)
// ===========================================================================
class chi_coh_fwd_dirty_base_test #(
  vip_chi_cfg_t CFG_P   = CHI_D_CFG_C,
  type          TYPES_T = chi_d_types_t
) extends chi_coherent_base_test #(CFG_P, TYPES_T);

  typedef vip_chi_item #(CFG_P) item_t;

  `uvm_component_param_utils(chi_coh_fwd_dirty_base_test #(CFG_P, TYPES_T))

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  protected virtual function void configure_agent_cfgs();
    super.hnf_cfg.hnf_enable_snoop_fwd = 1'b1;
  endfunction


  task run_phase(input uvm_phase phase);

    item_t         unique_rsp[$];
    item_t         shared_rsp[$];
    item_t         readback_rsp[$];
    item_t         snp_item;
    vip_chi_resp_t rnf0_state;
    vip_chi_resp_t rnf1_state;
    item_t::data_t dirty_pattern;

    phase.raise_objection(this);

    super.wait_reset_settle();

    dirty_pattern = {($bits(dirty_pattern) / 8){8'h3C}};

    // 1) RN-F0 acquires Unique and dirties the line locally.
    this.cfg_read_seq(super.hrnf0_rdunique_seq);
    super.hrnf0_rdunique_seq.start(super.tb_env.hrnf0_agent.sequencer);
    unique_rsp = super.hrnf0_rdunique_seq.get_responses();

    super.tb_env.hrnf0_agent.rnf_driver.make_line_dirty(item_t::addr_t'(WRITE_READ_ADDR_C), dirty_pattern);

    // 2) RN-F1 ReadShared -> DCT forward of the dirty data.
    this.cfg_read_seq(super.hrnf1_rdshared_seq);
    super.hrnf1_rdshared_seq.start(super.tb_env.hrnf1_agent.sequencer);
    shared_rsp = super.hrnf1_rdshared_seq.get_responses();

    if ((unique_rsp.size() != 1) || (shared_rsp.size() != 1)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] expected 1+1 responses, got %0d/%0d",
        super.tc_name, unique_rsp.size(), shared_rsp.size()))
    end

    if (shared_rsp[0].rsp_resp != VIP_CHI_RESP_STATE_SC_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] ReadShared granted 0x%0h, expected SC",
        super.tc_name, shared_rsp[0].rsp_resp))
    end

    // Forwarded data must be RN-F0's DIRTIED copy (orig ^ pattern).
    if (unique_rsp[0].data.size() != shared_rsp[0].data.size()) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] beat-count mismatch: unique %0d vs shared %0d",
        super.tc_name, unique_rsp[0].data.size(), shared_rsp[0].data.size()))
    end
    foreach (shared_rsp[0].data[i]) begin
      if (shared_rsp[0].data[i] !== (unique_rsp[0].data[i] ^ dirty_pattern)) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] beat %0d forwarded 0x%0h, expected dirtied 0x%0h",
          super.tc_name, i, shared_rsp[0].data[i],
          (unique_rsp[0].data[i] ^ dirty_pattern)))
      end
    end

    // The snoop must be a SnpSharedFwd routed to RN-F1's transaction.
    if (!super.tb_env.hrnf0_snp_fifo.try_get(snp_item)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F0 observed no snoop for the forwarding read", super.tc_name))
    end
    if (snp_item.snp_opcode != vip_chi_snp_opcode_t'(VIP_CHI_SNP_SHARED_FWD_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] expected SnpSharedFwd (0x%0h), got snp_opcode 0x%0h",
        super.tc_name, VIP_CHI_SNP_SHARED_FWD_C, snp_item.snp_opcode))
    end
    if (snp_item.fwd_txn_id != shared_rsp[0].txn_id) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] forwarding snoop FwdTxnID 0x%0h != requester read TxnID 0x%0h",
        super.tc_name, snp_item.fwd_txn_id, shared_rsp[0].txn_id))
    end

    super.wait_clocks(8);

    rnf0_state = super.tb_env.hrnf0_agent.rnf_driver.get_cache_state(item_t::addr_t'(WRITE_READ_ADDR_C));
    rnf1_state = super.tb_env.hrnf1_agent.rnf_driver.get_cache_state(item_t::addr_t'(WRITE_READ_ADDR_C));

    if (rnf0_state != VIP_CHI_RESP_STATE_SC_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F0 cache 0x%0h after passing dirty data via fwd, expected SC",
        super.tc_name, rnf0_state))
    end
    if (rnf1_state != VIP_CHI_RESP_STATE_SC_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F1 cache 0x%0h, expected SC", super.tc_name, rnf1_state))
    end

    // The home merged the forwarded dirty data: a fresh read-back returns it.
    this.cfg_read_seq(super.hrnf1_rdshared_seq);
    super.hrnf1_rdshared_seq.start(super.tb_env.hrnf1_agent.sequencer);
    readback_rsp = super.hrnf1_rdshared_seq.get_responses();
    if (readback_rsp.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] expected 1 read-back response, got %0d", super.tc_name, readback_rsp.size()))
    end
    foreach (readback_rsp[0].data[i]) begin
      if (readback_rsp[0].data[i] !== (unique_rsp[0].data[i] ^ dirty_pattern)) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] beat %0d read-back 0x%0h, expected merged dirty 0x%0h",
          super.tc_name, i, readback_rsp[0].data[i],
          (unique_rsp[0].data[i] ^ dirty_pattern)))
      end
    end

    if (super.tb_env.coh_checker.get_multi_owner_count() != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %0d coherency violations on a legal dirty forward",
        super.tc_name, super.tb_env.coh_checker.get_multi_owner_count()))
    end

    phase.drop_objection(this);
  endtask
endclass
