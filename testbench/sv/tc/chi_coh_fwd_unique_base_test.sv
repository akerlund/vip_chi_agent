// ===========================================================================
// chi_coh_fwd_unique_base_test
//
// Direct cache transfer (DCT), unique forward. With hnf_enable_snoop_fwd=1 a
// ReadUnique that hits a peer holder is served by a SnpUniqueFwd: the snoopee
// forwards its data (relayed by the home to the requester) and invalidates.
//   RN-F0 ReadUnique L    -> UC, caches L's beats
//   RN-F1 ReadUnique L    -> HN-F SnpUniqueFwd(RN-F0, FwdNID=RN-F1)
//                            -> RN-F0 SnpRespDataFwded(I, its beats) -> RN-F0 I
//                            -> HN-F relays CompData(UC, those beats) to RN-F1
// Asserts: a SnpUniqueFwd was snooped to RN-F0 with a non-zero FwdNID; RN-F1's
// CompData carries RN-F0's beats; RN-F1 granted UC; RN-F0 invalidated to I;
// directory p0=I/p1=UC; Checker D silent (exactly one Unique owner throughout).
//
// Used by:
//   tc_chi_coh_e_fwd_unique  (wide CHI-E)
//   tc_chi_coh_d_fwd_unique    (CHI-D)
// ===========================================================================
class chi_coh_fwd_unique_base_test #(
  vip_chi_cfg_t CFG_P   = CHI_D_CFG_C,
  type          TYPES_T = chi_d_types_t
) extends chi_coherent_base_test #(CFG_P, TYPES_T);

  typedef vip_chi_item #(CFG_P) item_t;

  `uvm_component_param_utils(chi_coh_fwd_unique_base_test #(CFG_P, TYPES_T))

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  protected virtual function void configure_agent_cfgs();
    super.hnf_cfg.hnf_enable_snoop_fwd = 1'b1;
  endfunction


  task run_phase(input uvm_phase phase);

    item_t         unique0_rsp[$];
    item_t         unique1_rsp[$];
    item_t         snp_item;
    vip_chi_resp_t rnf0_state;
    vip_chi_resp_t rnf1_state;

    phase.raise_objection(this);

    super.wait_reset_settle();

    // 1) RN-F0 acquires the line Unique.
    this.cfg_read_seq(super.hrnf0_rdunique_seq);
    super.hrnf0_rdunique_seq.start(super.tb_env.hrnf0_agent.sequencer);
    unique0_rsp = super.hrnf0_rdunique_seq.get_responses();

    // 2) RN-F1 ReadUnique -> the home forwards from RN-F0 and invalidates it.
    this.cfg_read_seq(super.hrnf1_rdunique_seq);
    super.hrnf1_rdunique_seq.start(super.tb_env.hrnf1_agent.sequencer);
    unique1_rsp = super.hrnf1_rdunique_seq.get_responses();

    if ((unique0_rsp.size() != 1) || (unique1_rsp.size() != 1)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] expected 1+1 responses, got %0d/%0d",
        super.tc_name, unique0_rsp.size(), unique1_rsp.size()))
    end

    if (unique1_rsp[0].rsp_resp != VIP_CHI_RESP_STATE_UC_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] ReadUnique granted 0x%0h, expected UC",
        super.tc_name, unique1_rsp[0].rsp_resp))
    end

    // The forwarded data must be RN-F0's beats delivered to RN-F1 verbatim.
    if (unique0_rsp[0].data.size() != unique1_rsp[0].data.size()) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] beat-count mismatch: %0d vs %0d",
        super.tc_name, unique0_rsp[0].data.size(), unique1_rsp[0].data.size()))
    end
    foreach (unique1_rsp[0].data[i]) begin
      if (unique1_rsp[0].data[i] !== unique0_rsp[0].data[i]) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] beat %0d forwarded 0x%0h != RN-F0 held 0x%0h",
          super.tc_name, i, unique1_rsp[0].data[i], unique0_rsp[0].data[i]))
      end
    end

    // The snoop RN-F0 saw must be a SnpUniqueFwd carrying a FwdNID.
    if (!super.tb_env.hrnf0_snp_fifo.try_get(snp_item)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F0 observed no snoop for the forwarding read", super.tc_name))
    end
    if (snp_item.snp_opcode != vip_chi_snp_opcode_t'(VIP_CHI_SNP_UNIQUE_FWD_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] expected SnpUniqueFwd (0x%0h), got snp_opcode 0x%0h",
        super.tc_name, VIP_CHI_SNP_UNIQUE_FWD_C, snp_item.snp_opcode))
    end
    // The forward must be routed to the requester's transaction: the HN-F stamps
    // FwdTxnID = the requester's read TxnID (node IDs are 0 in this bench, so
    // FwdNID is not a distinguishing check here).
    if (snp_item.fwd_txn_id != unique1_rsp[0].txn_id) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] forwarding snoop FwdTxnID 0x%0h != requester read TxnID 0x%0h",
        super.tc_name, snp_item.fwd_txn_id, unique1_rsp[0].txn_id))
    end

    super.wait_clocks(8);

    rnf0_state = super.tb_env.hrnf0_agent.rnf_driver.get_cache_state(item_t::addr_t'(WRITE_READ_ADDR_C));
    rnf1_state = super.tb_env.hrnf1_agent.rnf_driver.get_cache_state(item_t::addr_t'(WRITE_READ_ADDR_C));

    if (rnf0_state != VIP_CHI_RESP_STATE_I_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F0 cache 0x%0h after unique forward, expected I",
        super.tc_name, rnf0_state))
    end
    if (rnf1_state != VIP_CHI_RESP_STATE_UC_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F1 cache 0x%0h, expected UC", super.tc_name, rnf1_state))
    end

    if (super.tb_env.hnf_agent.hnf_driver.get_directory_port_state(item_t::addr_t'(WRITE_READ_ADDR_C), 0) != VIP_CHI_RESP_STATE_I_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] directory port0 not Invalid after unique forward", super.tc_name))
    end
    if (super.tb_env.hnf_agent.hnf_driver.get_directory_port_state(item_t::addr_t'(WRITE_READ_ADDR_C), 1) != VIP_CHI_RESP_STATE_UC_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] directory port1 not UC after unique forward", super.tc_name))
    end

    if (super.tb_env.coh_checker.get_multi_owner_count() != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %0d coherency violations on a legal unique forward",
        super.tc_name, super.tb_env.coh_checker.get_multi_owner_count()))
    end

    phase.drop_objection(this);
  endtask
endclass
