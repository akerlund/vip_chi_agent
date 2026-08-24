// Two identifier rules, asked to do their job on the one opcode no classifier
// used to claim.
//
// WriteUniqueZero is a full-line store of ZERO that puts no data on the wire.
// Its documented twin WriteNoSnpZero differs from it only in snoopability, and
// both are governed by the same identifier rules: IHI 0050 E section 2.3 gives a
// requester one live transaction per TxnID, so a second request may not carry a
// TxnID whose earlier use is still outstanding, and section 2.6 says a request
// that is accepted is completed. Neither rule is opcode-specific -- both are
// gated on a classifier that answers "does this opcode have a modeled
// completion", and an opcode the classifier does not name is walked past in
// silence by both.
//
// Silence is the problem this test exists to break. A rule that never evaluates
// produces no failure, so a full regression passes over an unclassified opcode
// without a murmur, and the tally shows the rule green because other opcodes
// exercised it. What is needed is the opposite of a passing run: this opcode, and
// these two rules, made to move.
//
// Both halves are here because either alone is misleading:
//
//   phase A  a WriteUniqueZero that COMPLETES. CHI_COMPLETION_FOLLOWS_REQ is
//            asked for a pass -- proof that the rule now arms for this opcode at
//            all. A rule that cannot arm cannot time out either, so its silence
//            on an unserviced request would be indistinguishable from success.
//   phase B  a WriteUniqueZero that REUSES a live TxnID. CHI_TXNID_REUSE_* is
//            asked for exactly one report at each end of the link. This is the
//            rule the classifier fix switched on, so it is the one that has to be
//            proved to fire and not merely to pass.
//
// Phase B completes its duplicate too. Leaving it outstanding would time out the
// completion rule and mix the two verdicts: the run would then show a reuse
// report and a timeout report, and no reader could tell whether the reuse rule
// fired or the timeout dragged it along.
//
// Why raw injection. No SN-F services WriteUniqueZero, and correctly so -- a
// snoopable store is Home business, and an SN-F cannot snoop. The opcode's real
// completer is the HN-F on the coherent topology, where a request and its
// completion are not both visible on one link and the completion timeout is
// therefore switched off by construction. That leaves this link, the only one
// where the timeout is live, and the flits have to be placed on it verbatim. The
// same raw path already carries tc_chi_d_raw_inject and
// tc_chi_rsp_field_zero_negctl.
//
// The rules under test are turned down to VIP_CHI_CHK_SEV_OFF_E rather than
// disabled. OFF still evaluates and still counts, and only suppresses the
// report, which is exactly what a negative control needs; disabling would stop
// the counting and leave nothing to assert on.

class tc_chi_e_write_unique_zero_negctl extends chi_e_base_test;

  typedef vip_chi_item #(CHI_E_WIDE_CFG_C) item_t;

  `uvm_component_utils(tc_chi_e_write_unique_zero_negctl)

  localparam int SETTLE_C = 40;
  // How long the COMPLETER holds TXSACTIVE past the close of its last window.
  //
  // The requester's half of this hold is gone. It used to be here because the
  // raw-inject path scoped a REQ's window to the flit -- "a raw flit is a single
  // injected packet with no completion to wait for" -- which stopped being true
  // for this opcode when WriteUniqueZero was classified. The raw path now
  // carries a window of its own, closed by the completion rather than by the
  // flit, so the requester covers its own transaction and needs nothing from
  // this testcase. F-CORR-021.
  //
  // What remains is not a VIP defect and does not come off with it. This test
  // drives BOTH ends: the SN-F receives a raw request it does not service, so it
  // opens its window at capture and closes it again with nothing to send, while
  // the completion arrives cycles later from the test itself. Section 14.7.2
  // requires the sideband to cover that gap and the checker is right to say so
  // -- there is simply no completer here to be wrong. Holding is legal where
  // waiving would not be: TXSACTIVE is permissive, so over-assertion is
  // conformant and under-assertion is the violation. 32 cycles covers the widest
  // injection-to-completion gap below with room to spare; the deassert bound
  // moves with it, because the checker reads the same value.
  localparam int TXSACTIVE_EXTEND_C = 32;
  // One report, on the second of the two flits. Not "at least one": more would
  // mean the rule is also firing on the compliant traffic that brought the link
  // up, which would make it useless in an ordinary run.
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
  // the scoreboard sees flits it never paired and reports them as incomplete
  // transactions. That is correct of the scoreboard and beside the point here:
  // this test is a guard on two SVA rules.
  // ---------------------------------------------------------------------------
  protected virtual function void configure_tb_cfg();

    super.configure_tb_cfg();

    super.tb_cfg.scoreboard_enable = 1'b0;
    super.tb_cfg.txsactive_extend_max_cycles = TXSACTIVE_EXTEND_C;
  endfunction

  // ---------------------------------------------------------------------------
  // The driver half of the hold, on the COMPLETER only. tb_cfg reaches the
  // checkers and has to allow at least what the driver drives, or the checker
  // would judge a window the driver never drove.
  //
  // rni_cfg is deliberately NOT set: the requester's window is the raw path's
  // own now, and leaving a hold here would hide a regression in it -- the
  // sideband would stay up for 32 cycles whether or not the fix still worked.
  // ---------------------------------------------------------------------------
  protected virtual function void configure_agent_cfgs();

    super.configure_agent_cfgs();

    super.snf_cfg.txsactive_extend_max_cycles = TXSACTIVE_EXTEND_C;
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
  // One WriteUniqueZero, well formed apart from the TxnID the caller picks.
  //
  // Table 2-9 marks the opcode's ExpCompAck prohibited, so the field stays zero
  // and the flit does not trip the CompAck rules on its way past.
  // ---------------------------------------------------------------------------
  protected function item_t::raw_req_t write_unique_zero(input item_t::txn_id_t txn_id);

    item_t::raw_req_t raw_req;

    raw_req            = '0;
    raw_req.txnid      = txn_id;
    raw_req.srcid      = E_WUZ_NEGCTL_RNI_NODE_ID_C;
    raw_req.tgtid      = E_WUZ_NEGCTL_SNF_NODE_ID_C;
    raw_req.opcode     = item_t::req_opcode_t'(VIP_CHI_REQ_WRITE_UNIQUE_ZERO_C);
    raw_req.addr       = E_WUZ_NEGCTL_ADDR_C;
    raw_req.size       = item_t::size_t'(3'd6);
    raw_req.ns         = VIP_CHI_REQ_NON_SECURE_ACCESS_E;
    // WriteUniqueZero is Snoopable only (Table 2-14), and Table 2-12 lists no
    // Snoopable row without Cacheable and EWA. A raw flit bypasses the
    // sequence's per-opcode defaults, so both fields are set here or this
    // testcase injects the exact non-conformance the two rules exist to catch.
    raw_req.snpattr    = VIP_CHI_SNP_SNOOPABLE_E;
    raw_req.memattr    = 4'b0101;
    raw_req.allowretry = 1'b1;
    raw_req.qos        = 4'h7;

    return raw_req;
  endfunction

  // ---------------------------------------------------------------------------
  // The completion the opcode takes: a combined CompDBIDResp carrying the
  // request's own TxnID. The buffer it grants goes unused because the request
  // carries no data, which is the whole point of the opcode -- the completion
  // form is normative regardless.
  // ---------------------------------------------------------------------------
  protected function item_t::raw_rsp_t comp_dbid_resp(input item_t::txn_id_t txn_id);

    item_t::raw_rsp_t raw_rsp;

    raw_rsp         = '0;
    raw_rsp.opcode  = item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_DBID_RESP_C);
    raw_rsp.txnid   = txn_id;
    raw_rsp.dbid    = txn_id;
    raw_rsp.resp    = VIP_CHI_RESP_STATE_I_E;
    raw_rsp.resperr = VIP_CHI_RESP_ERR_NORMAL_OKAY_E;
    raw_rsp.srcid   = E_WUZ_NEGCTL_SNF_NODE_ID_C;
    raw_rsp.tgtid   = E_WUZ_NEGCTL_RNI_NODE_ID_C;
    raw_rsp.qos     = 4'h7;

    return raw_rsp;
  endfunction

  // ---------------------------------------------------------------------------
  // Neither rule may have reported before the injections, or the counts below
  // would prove only that something fired somewhere.
  // ---------------------------------------------------------------------------
  protected function void require_silent(input vip_chi_check_id_t id);

    int unsigned rni_fails;
    int unsigned snf_fails;

    rni_fails = super.tb_env.rni_agent.vif.check_fail_count[id];
    snf_fails = super.tb_env.snf_agent.vif.check_fail_count[id];

    if ((rni_fails != 0) || (snf_fails != 0)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s already reported rni_e=%0d snf_e=%0d time(s) on compliant traffic; the counts below would prove nothing",
        super.tc_name, vip_chi_check_name(id), rni_fails, snf_fails))
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    int unsigned completion_pass_rni_before;
    int unsigned completion_pass_snf_before;
    int unsigned completion_pass_rni_after;
    int unsigned completion_pass_snf_after;
    int unsigned reuse_fails_rni;
    int unsigned reuse_fails_snf;

    phase.raise_objection(this);

    // Compliant traffic first: it brings the link to RUN, and it puts a request
    // and its completion past both rules so the silence asserted below is a
    // statement about compliant flits rather than about an idle link.
    super.rni_wr_seq.reset();
    super.rni_wr_seq.set_requests(1);
    super.rni_wr_seq.set_initial_addr(E_WUZ_NEGCTL_ADDR_C);
    super.rni_wr_seq.set_size(3'd6);
    super.rni_wr_seq.set_get_response(1'b1);
    super.rni_wr_seq.set_verbose(1'b0);
    super.rni_wr_seq.start(super.tb_env.rni_agent.sequencer);

    super.wait_clocks(4);
    super.drain_observation_fifos();

    this.require_silent(VIP_CHI_CHK_TXNID_REUSE_REQUESTER_E);
    this.require_silent(VIP_CHI_CHK_TXNID_REUSE_COMPLETER_E);
    this.require_silent(VIP_CHI_CHK_COMPLETION_FOLLOWS_REQ_E);

    completion_pass_rni_before =
      super.tb_env.rni_agent.vif.check_pass_count[VIP_CHI_CHK_COMPLETION_FOLLOWS_REQ_E];
    completion_pass_snf_before =
      super.tb_env.snf_agent.vif.check_pass_count[VIP_CHI_CHK_COMPLETION_FOLLOWS_REQ_E];

    // -- Phase A: a WriteUniqueZero that completes. --------------------------
    this.rni_raw_seq.reset();
    this.rni_raw_seq.add_raw_req(this.write_unique_zero(E_WUZ_NEGCTL_TXN_ID_PASS_C));
    this.rni_raw_seq.start(super.tb_env.rni_agent.sequencer);

    super.wait_clocks(4);

    this.snf_raw_seq.reset();
    this.snf_raw_seq.add_raw_rsp(this.comp_dbid_resp(E_WUZ_NEGCTL_TXN_ID_PASS_C));
    this.snf_raw_seq.start(super.tb_env.snf_agent.sequencer);

    super.wait_clocks(SETTLE_C);

    completion_pass_rni_after =
      super.tb_env.rni_agent.vif.check_pass_count[VIP_CHI_CHK_COMPLETION_FOLLOWS_REQ_E];
    completion_pass_snf_after =
      super.tb_env.snf_agent.vif.check_pass_count[VIP_CHI_CHK_COMPLETION_FOLLOWS_REQ_E];

    // Both ends. The rule is asserted twice under one ID -- the requester's own
    // txreq against the rxrsp it receives, and the completer's rxreq against the
    // txrsp it drives -- and a link may carry a bind at only one end. Checking
    // one vantage would leave the other silently untested.
    if ((completion_pass_rni_after <= completion_pass_rni_before) ||
        (completion_pass_snf_after <= completion_pass_snf_before)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s did not record a pass for WriteUniqueZero: rni_e %0d -> %0d, snf_e %0d -> %0d. The opcode is not reaching the rule",
        super.tc_name, vip_chi_check_name(VIP_CHI_CHK_COMPLETION_FOLLOWS_REQ_E),
        completion_pass_rni_before, completion_pass_rni_after,
        completion_pass_snf_before, completion_pass_snf_after))
    end

    this.require_silent(VIP_CHI_CHK_COMPLETION_FOLLOWS_REQ_E);
    this.require_silent(VIP_CHI_CHK_TXNID_REUSE_REQUESTER_E);
    this.require_silent(VIP_CHI_CHK_TXNID_REUSE_COMPLETER_E);

    // -- Phase B: a WriteUniqueZero that reuses a live TxnID. ----------------
    //
    // Suppress the report, keep the count, at both ends, because both are about
    // to be made to fail.
    super.tb_env.rni_agent.vif.check_severity[VIP_CHI_CHK_TXNID_REUSE_REQUESTER_E] =
      VIP_CHI_CHK_SEV_OFF_E;
    super.tb_env.snf_agent.vif.check_severity[VIP_CHI_CHK_TXNID_REUSE_COMPLETER_E] =
      VIP_CHI_CHK_SEV_OFF_E;

    this.rni_raw_seq.reset();
    this.rni_raw_seq.add_raw_req(this.write_unique_zero(E_WUZ_NEGCTL_TXN_ID_DUP_C));
    this.rni_raw_seq.add_raw_req(this.write_unique_zero(E_WUZ_NEGCTL_TXN_ID_DUP_C));
    this.rni_raw_seq.start(super.tb_env.rni_agent.sequencer);

    super.wait_clocks(4);

    // One completion retires both, since both name the same TxnID -- which is
    // the violation. The completion rule stays quiet either way, and that is
    // asserted below so a timeout cannot be mistaken for the reuse report.
    this.snf_raw_seq.reset();
    this.snf_raw_seq.add_raw_rsp(this.comp_dbid_resp(E_WUZ_NEGCTL_TXN_ID_DUP_C));
    this.snf_raw_seq.start(super.tb_env.snf_agent.sequencer);

    super.wait_clocks(SETTLE_C);

    reuse_fails_rni =
      super.tb_env.rni_agent.vif.check_fail_count[VIP_CHI_CHK_TXNID_REUSE_REQUESTER_E];
    reuse_fails_snf =
      super.tb_env.snf_agent.vif.check_fail_count[VIP_CHI_CHK_TXNID_REUSE_COMPLETER_E];

    if (reuse_fails_rni != EXPECTED_REUSE_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s reported %0d time(s) at the RN-I against exactly %0d duplicate WriteUniqueZero; below means the opcode is not reaching the rule, above means it is firing on compliant traffic",
        super.tc_name, vip_chi_check_name(VIP_CHI_CHK_TXNID_REUSE_REQUESTER_E),
        reuse_fails_rni, EXPECTED_REUSE_C))
    end

    if (reuse_fails_snf != EXPECTED_REUSE_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s reported %0d time(s) at the SN-F against exactly %0d duplicate WriteUniqueZero; the receiving vantage of the rule is not doing its half",
        super.tc_name, vip_chi_check_name(VIP_CHI_CHK_TXNID_REUSE_COMPLETER_E),
        reuse_fails_snf, EXPECTED_REUSE_C))
    end

    this.require_silent(VIP_CHI_CHK_COMPLETION_FOLLOWS_REQ_E);

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] WriteUniqueZero completed once under %s and reused a live TxnID once under %s / %s, reported %0d time(s) at each end",
      super.tc_name,
      vip_chi_check_name(VIP_CHI_CHK_COMPLETION_FOLLOWS_REQ_E),
      vip_chi_check_name(VIP_CHI_CHK_TXNID_REUSE_REQUESTER_E),
      vip_chi_check_name(VIP_CHI_CHK_TXNID_REUSE_COMPLETER_E),
      reuse_fails_rni), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
