// The TxnID-reuse rules read against the scope IHI 0050 E section 2.5 actually
// gives them:
//
//   "It is required that the TxnID, except for PrefetchTgt, must be unique for a
//    given Requester. The Requester is identified by the SrcID."
//
// So the rule has two halves that pull in opposite directions, and a checker can
// get one right while getting the other wrong:
//
//   step 2  two SOURCES holding the same TxnID at once is LEGAL, and on a
//           fan-in link unavoidable -- each requester allocates from its own
//           pool and nothing coordinates them. The rule must not report.
//   step 3  ONE source reusing its own live TxnID is the violation, and it stays
//           a violation after another source has touched the same value.
//
// Step 3 is the one that matters, and it is why this test exists rather than
// resting on tc_chi_e_write_unique_zero_negctl, which already proves a plain
// self-reuse reports. The shadow behind these rules used to be one slot per
// TxnID with a note of the LAST source to claim it. Under that shape:
//
//   A takes TxnID T          slot T is live, owner A
//   B takes TxnID T          legal, and the owner becomes B
//   A takes TxnID T again    owner is B, so A != owner -- PASSES, wrongly
//
// The violation went missing exactly because a legal event happened in between.
// That is a MISSED violation, which no ordinary test can see: the run is green
// either way. Only a control that walks the three steps in order can tell the
// two shadows apart, and this one fails against the old one at step 3.
//
// Raw injection, because SrcID is what is under test and a sequence stamps its
// own. The flits are otherwise the same well-formed WriteUniqueZero that
// tc_chi_e_write_unique_zero_negctl uses, for the same reason: it has a modeled
// completion, so the reuse rule arms on it, and its completion form is a single
// CompDBIDResp.
//
// Completions are TARGETED, and that is load-bearing. A response retires the
// request it is aimed at, so the checker reads the requester's identity out of
// the response's TgtID -- a completion aimed at A must not retire B's claim on
// the same TxnID. Injecting one completion per source is what proves it does
// not.
//
// Runs under: testbench/sv/tb/chi_tb_top.sv
class tc_chi_txnid_reuse_srcid_scope extends chi_e_base_test;

  typedef vip_chi_item #(CHI_E_WIDE_CFG_C) item_t;

  `uvm_component_utils(tc_chi_txnid_reuse_srcid_scope)

  localparam int SETTLE_C = 40;
  // Same hold, and the same reason, as tc_chi_e_write_unique_zero_negctl: the
  // raw-inject path scopes a REQ's outstanding window to the flit, and these
  // requests stay outstanding until the completions below. Under-assertion is
  // the violation TXSACTIVE_COVERS_OUTSTANDING reports; over-assertion is legal.
  localparam int TXSACTIVE_EXTEND_C = 48;
  // One report, on step 3's flit alone. Steps 1 and 2 are legal traffic and must
  // contribute nothing, which is what makes "exactly one" the right assertion
  // and "at least one" the wrong one.
  localparam int EXPECTED_REUSE_C = 1;

  vip_chi_raw_seq #(CHI_E_WIDE_CFG_C) rni_raw_seq;
  vip_chi_raw_seq #(CHI_E_WIDE_CFG_C) snf_raw_seq;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // The injected requests are serviced by this test, not by the responder, so
  // the scoreboard sees flits it never paired. That is correct of the scoreboard
  // and beside the point here: this test is a guard on one SVA rule.
  // ---------------------------------------------------------------------------
  protected virtual function void configure_tb_cfg();

    super.configure_tb_cfg();

    super.tb_cfg.scoreboard_enable = 1'b0;
    super.tb_cfg.txsactive_extend_max_cycles = TXSACTIVE_EXTEND_C;
  endfunction

  // ---------------------------------------------------------------------------
  // The driver half of the same hold. tb_cfg reaches the checkers; the agent cfg
  // reaches the RN-I that drives the wire, and both have to agree or the checker
  // would judge a window the driver never drove.
  // ---------------------------------------------------------------------------
  protected virtual function void configure_agent_cfgs();

    super.configure_agent_cfgs();

    super.rni_cfg.txsactive_extend_max_cycles = TXSACTIVE_EXTEND_C;
  endfunction

  // ---------------------------------------------------------------------------
  // Create the raw-flit helpers once topology is ready.
  // ---------------------------------------------------------------------------
  function void start_of_simulation_phase(input uvm_phase phase);

    super.start_of_simulation_phase(phase);

    this.rni_raw_seq = vip_chi_raw_seq #(CHI_E_WIDE_CFG_C)::type_id::create("rni_raw_seq");
    this.snf_raw_seq = vip_chi_raw_seq #(CHI_E_WIDE_CFG_C)::type_id::create("snf_raw_seq");
  endfunction

  // ---------------------------------------------------------------------------
  // One WriteUniqueZero from the SrcID the caller picks.
  // ---------------------------------------------------------------------------
  protected function item_t::raw_req_t write_unique_zero(
      input item_t::node_id_t src_id, input item_t::txn_id_t txn_id);

    item_t::raw_req_t raw_req;

    raw_req            = '0;
    raw_req.txnid      = txn_id;
    raw_req.srcid      = src_id;
    raw_req.tgtid      = E_WUZ_NEGCTL_SNF_NODE_ID_C;
    raw_req.opcode     = item_t::req_opcode_t'(VIP_CHI_REQ_WRITE_UNIQUE_ZERO_C);
    raw_req.addr       = E_WUZ_NEGCTL_ADDR_C;
    raw_req.size       = item_t::size_t'(3'd6);
    raw_req.ns         = VIP_CHI_REQ_NON_SECURE_ACCESS_E;
    // Snoopable only (Table 2-14), and Table 2-12 lists no Snoopable row without
    // Cacheable and EWA. A raw flit bypasses the sequence's per-opcode defaults.
    raw_req.snpattr    = VIP_CHI_SNP_SNOOPABLE_E;
    raw_req.memattr    = 4'b0101;
    raw_req.allowretry = 1'b1;
    raw_req.qos        = 4'h7;

    return raw_req;
  endfunction

  // ---------------------------------------------------------------------------
  // The completion, aimed at one requester. TgtID is the field the checker keys
  // the retirement on, so this is what decides WHOSE claim is released.
  // ---------------------------------------------------------------------------
  protected function item_t::raw_rsp_t comp_dbid_resp(
      input item_t::node_id_t tgt_id, input item_t::txn_id_t txn_id);

    item_t::raw_rsp_t raw_rsp;

    raw_rsp         = '0;
    raw_rsp.opcode  = item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_DBID_RESP_C);
    raw_rsp.txnid   = txn_id;
    raw_rsp.dbid    = txn_id;
    raw_rsp.resp    = VIP_CHI_RESP_STATE_I_E;
    raw_rsp.resperr = VIP_CHI_RESP_ERR_NORMAL_OKAY_E;
    raw_rsp.srcid   = E_WUZ_NEGCTL_SNF_NODE_ID_C;
    raw_rsp.tgtid   = tgt_id;
    raw_rsp.qos     = 4'h7;

    return raw_rsp;
  endfunction

  // ---------------------------------------------------------------------------
  // Inject one request and let it land.
  // ---------------------------------------------------------------------------
  protected task inject_req(input item_t::node_id_t src_id,
                            input item_t::txn_id_t txn_id);

    this.rni_raw_seq.reset();
    this.rni_raw_seq.add_raw_req(this.write_unique_zero(src_id, txn_id));
    this.rni_raw_seq.start(super.tb_env.rni_agent.sequencer);
    super.wait_clocks(4);
  endtask

  protected task inject_completion(input item_t::node_id_t tgt_id,
                                   input item_t::txn_id_t txn_id);

    this.snf_raw_seq.reset();
    this.snf_raw_seq.add_raw_rsp(this.comp_dbid_resp(tgt_id, txn_id));
    this.snf_raw_seq.start(super.tb_env.snf_agent.sequencer);
    super.wait_clocks(4);
  endtask

  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    int unsigned pass_rni_before;
    int unsigned pass_snf_before;
    int unsigned pass_rni_after;
    int unsigned pass_snf_after;
    int unsigned reuse_fails_rni;
    int unsigned reuse_fails_snf;
    int unsigned completion_fails_rni;
    int unsigned completion_fails_snf;

    phase.raise_objection(this);

    // Compliant traffic first: it brings the link to RUN, so the silence
    // asserted below is a statement about compliant flits, not about an idle
    // link.
    super.rni_wr_seq.reset();
    super.rni_wr_seq.set_requests(1);
    super.rni_wr_seq.set_initial_addr(E_WUZ_NEGCTL_ADDR_C);
    super.rni_wr_seq.set_size(3'd6);
    super.rni_wr_seq.set_get_response(1'b1);
    super.rni_wr_seq.set_verbose(1'b0);
    super.rni_wr_seq.start(super.tb_env.rni_agent.sequencer);

    super.wait_clocks(4);
    super.drain_observation_fifos();

    reuse_fails_rni =
      super.tb_env.rni_agent.vif.check_fail_count[VIP_CHI_CHK_TXNID_REUSE_REQUESTER_E];
    reuse_fails_snf =
      super.tb_env.snf_agent.vif.check_fail_count[VIP_CHI_CHK_TXNID_REUSE_COMPLETER_E];

    if ((reuse_fails_rni != 0) || (reuse_fails_snf != 0)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the reuse rules already reported rni_e=%0d snf_e=%0d time(s) on compliant traffic; the counts below would prove nothing",
        super.tc_name, reuse_fails_rni, reuse_fails_snf))
    end

    // -- Step 1: source A claims the TxnID. ----------------------------------
    this.inject_req(TXNID_SCOPE_SRC_A_C, TXNID_SCOPE_TXN_ID_C);

    // -- Step 2: source B claims the SAME TxnID. Legal, and must pass. -------
    pass_rni_before =
      super.tb_env.rni_agent.vif.check_pass_count[VIP_CHI_CHK_TXNID_REUSE_REQUESTER_E];
    pass_snf_before =
      super.tb_env.snf_agent.vif.check_pass_count[VIP_CHI_CHK_TXNID_REUSE_COMPLETER_E];

    this.inject_req(TXNID_SCOPE_SRC_B_C, TXNID_SCOPE_TXN_ID_C);

    reuse_fails_rni =
      super.tb_env.rni_agent.vif.check_fail_count[VIP_CHI_CHK_TXNID_REUSE_REQUESTER_E];
    reuse_fails_snf =
      super.tb_env.snf_agent.vif.check_fail_count[VIP_CHI_CHK_TXNID_REUSE_COMPLETER_E];

    if ((reuse_fails_rni != 0) || (reuse_fails_snf != 0)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] a second SOURCE claiming TxnID 0x%0h reported rni_e=%0d snf_e=%0d; section 2.5 scopes uniqueness to a requester identified by SrcID, so this is legal traffic and the rule is reading 'unique per link' instead",
        super.tc_name, TXNID_SCOPE_TXN_ID_C, reuse_fails_rni, reuse_fails_snf))
    end

    pass_rni_after =
      super.tb_env.rni_agent.vif.check_pass_count[VIP_CHI_CHK_TXNID_REUSE_REQUESTER_E];
    pass_snf_after =
      super.tb_env.snf_agent.vif.check_pass_count[VIP_CHI_CHK_TXNID_REUSE_COMPLETER_E];

    if ((pass_rni_after <= pass_rni_before) || (pass_snf_after <= pass_snf_before)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the reuse rules recorded no pass for the second source: rni_e %0d -> %0d, snf_e %0d -> %0d. Silence here is a rule that never evaluated, not a rule that held",
        super.tc_name, pass_rni_before, pass_rni_after,
        pass_snf_before, pass_snf_after))
    end

    // -- Step 3: source A reuses its OWN live TxnID. Must report. ------------
    //
    // Suppress the report, keep the count, because both ends are about to fail.
    super.tb_env.rni_agent.vif.check_severity[VIP_CHI_CHK_TXNID_REUSE_REQUESTER_E] =
      VIP_CHI_CHK_SEV_OFF_E;
    super.tb_env.snf_agent.vif.check_severity[VIP_CHI_CHK_TXNID_REUSE_COMPLETER_E] =
      VIP_CHI_CHK_SEV_OFF_E;

    this.inject_req(TXNID_SCOPE_SRC_A_C, TXNID_SCOPE_TXN_ID_C);

    // One completion per source, each aimed at the requester that holds the
    // claim. Two are needed, and that is the point: a single completion would
    // leave one source's claim live and time the completion rule out.
    this.inject_completion(TXNID_SCOPE_SRC_A_C, TXNID_SCOPE_TXN_ID_C);
    this.inject_completion(TXNID_SCOPE_SRC_B_C, TXNID_SCOPE_TXN_ID_C);

    super.wait_clocks(SETTLE_C);

    reuse_fails_rni =
      super.tb_env.rni_agent.vif.check_fail_count[VIP_CHI_CHK_TXNID_REUSE_REQUESTER_E];
    reuse_fails_snf =
      super.tb_env.snf_agent.vif.check_fail_count[VIP_CHI_CHK_TXNID_REUSE_COMPLETER_E];

    if (reuse_fails_rni != EXPECTED_REUSE_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s reported %0d time(s) at the RN-I against exactly %0d. Zero means the shadow lost source A's claim when source B touched the same TxnID -- the missed violation this test exists for; more means it is also firing on the legal step 2",
        super.tc_name, vip_chi_check_name(VIP_CHI_CHK_TXNID_REUSE_REQUESTER_E),
        reuse_fails_rni, EXPECTED_REUSE_C))
    end

    if (reuse_fails_snf != EXPECTED_REUSE_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s reported %0d time(s) at the SN-F against exactly %0d; the receiving vantage is not doing its half",
        super.tc_name, vip_chi_check_name(VIP_CHI_CHK_TXNID_REUSE_COMPLETER_E),
        reuse_fails_snf, EXPECTED_REUSE_C))
    end

    completion_fails_rni =
      super.tb_env.rni_agent.vif.check_fail_count[VIP_CHI_CHK_COMPLETION_FOLLOWS_REQ_E];
    completion_fails_snf =
      super.tb_env.snf_agent.vif.check_fail_count[VIP_CHI_CHK_COMPLETION_FOLLOWS_REQ_E];

    if ((completion_fails_rni != 0) || (completion_fails_snf != 0)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s reported rni_e=%0d snf_e=%0d; a completion timeout would mean one source's claim was never retired, which would mix the verdicts",
        super.tc_name, vip_chi_check_name(VIP_CHI_CHK_COMPLETION_FOLLOWS_REQ_E),
        completion_fails_rni, completion_fails_snf))
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] two sources held TxnID 0x%0h at once without a report, and source A reusing its own live TxnID afterwards reported %0d time(s) at each end",
      super.tc_name, TXNID_SCOPE_TXN_ID_C, reuse_fails_rni), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
