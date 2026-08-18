// A negative control for CHI_RSP_FIELD_ZERO, the Appendix A Table A-4 rule that
// says a field the table marks `0` or `0 a` must be driven zero.
//
// The rule was written AFTER the two defects it would have caught were already
// fixed -- Persist carrying the request's TxnID, and a bare DBIDResp carrying
// the completion's RespErr. So it passes on every existing testcase, and a rule
// that only ever passes is indistinguishable from a rule that cannot fail. This
// test supplies the missing half: three flits that violate it, one per field.
//
// PCrdGrant is the vehicle for all four because Table A-4 marks all four of its
// fields zero at once -- TxnID `0 a`, RespErr `0`, Resp `0 a`, and a `0 a`
// centred across the shared DBID field -- so one opcode exercises the whole
// predicate, and the raw-inject path already used by
// tc_chi_pcrd_leak and tc_chi_pcrd_return can put an arbitrary flit on the wire
// without teaching a driver to misbehave.
//
// What is asserted, in order of what would otherwise go unnoticed:
//
//   * the count is zero BEFORE the injection. Without this the test proves only
//     that the rule fires somewhere, not that these flits are what moved it.
//   * exactly four reports, not "at least four". Fewer means a field is not
//     covered; more means the rule is also firing on the well-formed traffic
//     that brought the link up, which would make it useless in an ordinary run.
//   * four at BOTH ends of the link. The rule is asserted twice under one ID,
//     txrsp at the SN-F that drove the flits and rxrsp at the RN-I that received
//     them, and a link may carry a bind at only one end. Checking one vantage
//     would leave the other silently untested -- which is the shape of defect
//     this whole family of rules exists to stop.
//
// The rule is turned down to VIP_CHI_CHK_SEV_OFF_E rather than disabled. OFF
// still EVALUATES and still COUNTS -- it only suppresses the report -- which is
// what a negative control needs. Disabling would stop the counting too, leaving
// nothing to assert on.

class tc_chi_rsp_field_zero_negctl extends chi_base_test;

  `uvm_component_utils(tc_chi_rsp_field_zero_negctl)

  localparam int PCRD_TYPE_C = 3;
  localparam int SETTLE_C    = 20;
  // One violating flit per zero-marked field of PCrdGrant.
  localparam int EXPECTED_C  = 4;

  vip_chi_raw_seq #(CHI_D_CFG_C) snf_raw_seq;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // The injected grants bounce nothing, so the scoreboard opens a context for
  // each that never completes and reports the stray flits as incomplete
  // transactions. That is correct of the scoreboard and beside the point here:
  // this test is a guard on one SVA rule.
  // ---------------------------------------------------------------------------
  protected virtual function void configure_tb_cfg();

    super.configure_tb_cfg();
    super.tb_cfg.scoreboard_enable = 1'b0;
  endfunction

  // ---------------------------------------------------------------------------
  // The four injected grants bounce nothing, so without this they sit in the
  // requester's bank and vip_chi_driver_rni::check_phase reports four leaked
  // P-credits at end of test -- a correct report about a real leak, and nothing
  // to do with the rule under test. Handing them back is the honest way to
  // silence it: tc_chi_pcrd_leak already covers the leak itself, and only the
  // pipelined path banks a credit at all.
  // ---------------------------------------------------------------------------
  protected virtual function void configure_agent_cfgs();

    super.configure_agent_cfgs();
    super.rni_cfg.multi_outstanding  = 1'b1;
    super.rni_cfg.return_unused_pcrd = 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Create the SN-F raw-flit helper once topology is ready.
  // ---------------------------------------------------------------------------
  function void start_of_simulation_phase(input uvm_phase phase);

    super.start_of_simulation_phase(phase);

    this.snf_raw_seq = vip_chi_raw_seq #(CHI_D_CFG_C)::type_id::create("snf_raw_seq");
  endfunction

  // ---------------------------------------------------------------------------
  // One well-formed PCrdGrant field set, to be corrupted one field at a time.
  // ---------------------------------------------------------------------------
  protected function item_t::raw_rsp_t legal_pcrd_grant();

    item_t::raw_rsp_t raw_rsp;

    raw_rsp          = '0;
    raw_rsp.opcode   = item_t::rsp_opcode_t'(VIP_CHI_RSP_PCRD_GRANT_C);
    raw_rsp.pcrdtype = PCRD_TYPE_C;
    raw_rsp.resp     = VIP_CHI_RESP_STATE_I_E;
    raw_rsp.resperr  = VIP_CHI_RESP_ERR_NORMAL_OKAY_E;
    raw_rsp.srcid    = SNF_NODE_ID_C;
    raw_rsp.tgtid    = RNI_NODE_ID_C;

    return raw_rsp;
  endfunction

  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t::raw_rsp_t bad_txnid;
    item_t::raw_rsp_t bad_resperr;
    item_t::raw_rsp_t bad_resp;
    item_t::raw_rsp_t bad_dbid;
    int unsigned      rni_before;
    int unsigned      snf_before;
    int unsigned      rni_fails;
    int unsigned      snf_fails;

    phase.raise_objection(this);

    // Suppress the report, keep the count. Both ends: the rule is asserted at
    // both and both are about to be made to fail.
    super.tb_env.rni_agent.vif.check_severity[VIP_CHI_CHK_RSP_FIELD_ZERO_E] =
      VIP_CHI_CHK_SEV_OFF_E;
    super.tb_env.snf_agent.vif.check_severity[VIP_CHI_CHK_RSP_FIELD_ZERO_E] =
      VIP_CHI_CHK_SEV_OFF_E;

    // Ordinary traffic first, to bring the link to RUN and to put a good
    // CompDBIDResp and DBIDResp past the rule. Those opcodes are in its opcode
    // set too, so this is also what proves the rule does not fire on compliant
    // flits -- the zero-before assertion below is exactly that statement.
    super.rni0_wr_seq.reset();
    super.rni0_wr_seq.set_requests(1);
    super.rni0_wr_seq.set_initial_addr(WRITE_READ_ADDR_C);
    super.rni0_wr_seq.set_size(3'd6);
    super.rni0_wr_seq.set_allow_retry(1'b0);
    super.rni0_wr_seq.set_get_response(1'b1);
    super.rni0_wr_seq.set_verbose(1'b0);
    super.rni0_wr_seq.start(super.v_sqr.rni_sequencer);

    super.wait_clocks(4);
    super.drain_observation_fifos();

    rni_before = super.tb_env.rni_agent.vif.check_fail_count[VIP_CHI_CHK_RSP_FIELD_ZERO_E];
    snf_before = super.tb_env.snf_agent.vif.check_fail_count[VIP_CHI_CHK_RSP_FIELD_ZERO_E];

    if ((rni_before != 0) || (snf_before != 0)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s already reported %0d/%0d time(s) on compliant traffic; the counts below would prove nothing",
        super.tc_name, vip_chi_check_name(VIP_CHI_CHK_RSP_FIELD_ZERO_E),
        rni_before, snf_before))
    end

    // Table A-4 PCrdGrant: TxnID = 0 a.
    bad_txnid       = this.legal_pcrd_grant();
    bad_txnid.txnid = item_t::txn_id_t'(8'h5A);

    // Table A-4 PCrdGrant: RespErr = 0. DERR is a legal RespErr encoding on the
    // responses that carry one, which is the point -- the field is well-formed
    // and still illegal here, so this fails on applicability, not on encoding.
    bad_resperr         = this.legal_pcrd_grant();
    bad_resperr.resperr = VIP_CHI_RESP_ERR_DATA_ERROR_E;

    // Table A-4 PCrdGrant: Resp = 0 a.
    bad_resp      = this.legal_pcrd_grant();
    bad_resp.resp = VIP_CHI_RESP_STATE_UC_E;

    // Table A-4 PCrdGrant: the shared DBID/TagGroupID/StashGroupID/PGroupID
    // field is 0 a. A grant that names a buffer is the mistake this catches --
    // PCrdGrant reserves a retry slot, not a write buffer.
    bad_dbid      = this.legal_pcrd_grant();
    bad_dbid.dbid = item_t::txn_id_t'(8'h1D);

    this.snf_raw_seq.reset();
    this.snf_raw_seq.add_raw_rsp(bad_txnid);
    this.snf_raw_seq.add_raw_rsp(bad_resperr);
    this.snf_raw_seq.add_raw_rsp(bad_resp);
    this.snf_raw_seq.add_raw_rsp(bad_dbid);
    this.snf_raw_seq.start(super.v_sqr.snf_sequencer);

    super.wait_clocks(SETTLE_C);

    rni_fails = super.tb_env.rni_agent.vif.check_fail_count[VIP_CHI_CHK_RSP_FIELD_ZERO_E];
    snf_fails = super.tb_env.snf_agent.vif.check_fail_count[VIP_CHI_CHK_RSP_FIELD_ZERO_E];

    if (snf_fails != EXPECTED_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s reported %0d time(s) at the SN-F (txrsp) against exactly %0d violating flits; below means a field is uncovered, above means it is firing on compliant traffic",
        super.tc_name, vip_chi_check_name(VIP_CHI_CHK_RSP_FIELD_ZERO_E),
        snf_fails, EXPECTED_C))
    end

    if (rni_fails != EXPECTED_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s reported %0d time(s) at the RN-I (rxrsp) against exactly %0d violating flits; the receiving vantage of the rule is not doing its half",
        super.tc_name, vip_chi_check_name(VIP_CHI_CHK_RSP_FIELD_ZERO_E),
        rni_fails, EXPECTED_C))
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] %s fired %0d time(s) at each end of the link, as intended",
      super.tc_name, vip_chi_check_name(VIP_CHI_CHK_RSP_FIELD_ZERO_E), rni_fails), UVM_LOW)

    phase.drop_objection(this);

  endtask

endclass
