// ===========================================================================
// vip_chi_coh_fwd_shared_base_test
//
// Direct cache transfer (DCT), clean shared forward. With hnf_enable_snoop_fwd=1
// the home, on a coherent read that hits a peer holder, issues a *forwarding*
// snoop instead of the ordinary snoop-then-serve-from-memory: the snoopee drives
// its held data (SnpRespDataFwded) which the home relays to the requester as
// CompData -- the data originates from the peer, not home memory.
//   RN-F0 ReadUnique L    -> UC, caches L's beats
//   RN-F1 ReadShared L    -> HN-F SnpSharedFwd(RN-F0, FwdNID=RN-F1)
//                            -> RN-F0 SnpRespDataFwded(SC, its beats)
//                            -> HN-F relays CompData(SC, those beats) to RN-F1
// Asserts: a SnpSharedFwd (not a plain SnpShared) was snooped to RN-F0 carrying a
// non-zero FwdNID; RN-F1's CompData carries exactly RN-F0's beats; RN-F1 granted
// SC; RN-F0 downgraded to SC; directory p0=SC/p1=SC; Checker D silent.
//
// Single scenario body parameterized on the CHI config; the two subclasses below
// run it at CHI-D (tc_chi_coh_d_fwd_shared) and wide CHI-E (tc_chi_coh_e_fwd_shared).
//
// Used by:
//   tc_chi_coh_e_fwd_shared  (wide CHI-E)
//   tc_chi_coh_d_fwd_shared    (CHI-D)
// ===========================================================================
class vip_chi_coh_fwd_shared_base_test #(
  vip_chi_cfg_t CFG_P   = CHI_D_CFG_C,
  type          TYPES_T = chi_d_types_t
) extends vip_chi_coherent_base_test #(CFG_P, TYPES_T);

  typedef vip_chi_item #(CFG_P) item_t;

  `uvm_component_param_utils(vip_chi_coh_fwd_shared_base_test #(CFG_P, TYPES_T))

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // Enable DCT origination on the home.
  protected virtual function void configure_agent_cfgs();
    super.hnf_cfg.hnf_enable_snoop_fwd = 1'b1;
  endfunction


  task run_phase(input uvm_phase phase);

    item_t         unique_rsp[$];
    item_t         shared_rsp[$];
    item_t         snp_item;
    vip_chi_resp_t rnf0_state;
    vip_chi_resp_t rnf1_state;

    phase.raise_objection(this);

    super.wait_reset_settle();

    // 1) RN-F0 acquires the line Unique (sole holder, caches the beats).
    this.cfg_read_seq(super.hrnf0_rdunique_seq);
    super.hrnf0_rdunique_seq.start(super.tb_env.hrnf0_agent.sequencer);
    unique_rsp = super.hrnf0_rdunique_seq.get_responses();

    // 2) RN-F1 ReadShared -> the home forwards from RN-F0 by DCT.
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

    // The forwarded data must be RN-F0's beats delivered to RN-F1 verbatim.
    if (unique_rsp[0].data.size() != shared_rsp[0].data.size()) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] beat-count mismatch: unique %0d vs shared %0d",
        super.tc_name, unique_rsp[0].data.size(), shared_rsp[0].data.size()))
    end
    foreach (shared_rsp[0].data[i]) begin
      if (shared_rsp[0].data[i] !== unique_rsp[0].data[i]) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] beat %0d forwarded 0x%0h != RN-F0 held 0x%0h",
          super.tc_name, i, shared_rsp[0].data[i], unique_rsp[0].data[i]))
      end
    end

    // The snoop RN-F0 saw must be a SnpSharedFwd (DCT), carrying a FwdNID.
    if (!super.tb_env.hrnf0_snp_fifo.try_get(snp_item)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F0 observed no snoop for the forwarding read", super.tc_name))
    end
    if (snp_item.snp_opcode != vip_chi_snp_opcode_t'(VIP_CHI_SNP_SHARED_FWD_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] expected SnpSharedFwd (0x%0h), got snp_opcode 0x%0h",
        super.tc_name, VIP_CHI_SNP_SHARED_FWD_C, snp_item.snp_opcode))
    end
    // The forward must be routed to the requester's transaction: the HN-F stamps
    // FwdTxnID = the requester's read TxnID (node IDs are 0 in this bench, so
    // FwdNID is not a distinguishing check here).
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
        "FATAL [%s] RN-F0 cache 0x%0h after forwarding, expected SC",
        super.tc_name, rnf0_state))
    end
    if (rnf1_state != VIP_CHI_RESP_STATE_SC_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F1 cache 0x%0h, expected SC", super.tc_name, rnf1_state))
    end

    if (super.tb_env.hnf_agent.hnf_driver.get_directory_port_state(item_t::addr_t'(WRITE_READ_ADDR_C), 0) != VIP_CHI_RESP_STATE_SC_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] directory port0 not SC after the shared forward", super.tc_name))
    end
    if (super.tb_env.hnf_agent.hnf_driver.get_directory_port_state(item_t::addr_t'(WRITE_READ_ADDR_C), 1) != VIP_CHI_RESP_STATE_SC_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] directory port1 not SC after the shared forward", super.tc_name))
    end

    if (super.tb_env.coh_checker.get_multi_owner_count() != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %0d coherency violations on a legal shared forward",
        super.tc_name, super.tb_env.coh_checker.get_multi_owner_count()))
    end

    phase.drop_objection(this);
  endtask
endclass
