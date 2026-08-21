// The negative control for the two retry field rules, which both pass on every
// flit this VIP drives.
//
// That is the problem. A rule that has never failed is a rule whose failing
// branch has never run, and the two here are the cheapest kind to get wrong: a
// stateless implication whose antecedent is subtly unreachable passes forever
// and reports a healthy tally the whole time. Both were landed against tables
// rather than against a failure, so both need a flit that makes them move.
//
//   phase A  IHI 0050 E section 2.9.4: "If the AllowRetry field is asserted,
//            the PCrdType field must be set to 0b0000." One WriteUniqueZero
//            carrying both, which no driver in this VIP will produce, because
//            the retry machinery sets PCrdType only on the re-issue where
//            AllowRetry is already clear. CHI_REQ_ALLOW_RETRY_PCRD_ZERO is
//            asked for exactly one report at each end.
//   phase B  Table A-2 and Table A-3 mark every PCrdReturn field but QoS,
//            TgtID, SrcID, Opcode and PCrdType inapplicable and zero. One
//            PCrdReturn carrying an address. return_unused_pcrds builds its
//            flit from '0 and fills in five fields, so the violation this
//            guards against is a refactor away rather than present today --
//            which is exactly what a guard is for.
//            CHI_REQ_PCRD_RETURN_FIELDS_ZERO is asked for the same.
//   phase C  Section 2.6.5 step 2: "The TxnID is set to the same value as the
//            TxnID of the request." One RetryAck naming a TxnID no request has
//            used. The RN-I driver already fatals on this for its own
//            bookkeeping, but only while it is waiting on a specific request,
//            and only at the requester -- nothing judges the SN-F end at all.
//            CHI_RSP_RETRY_ACK_TXN_ID is asked for the same one report per
//            vantage.
//
// Both phases inject rather than configure. A cfg knob would have to reach into
// the driver's retry path to corrupt a field the driver computes correctly, and
// raw_req_t is the whole REQ flit -- so the flit can simply be placed on the
// wire, the way tc_chi_e_write_unique_zero_negctl and tc_chi_d_raw_inject
// already do it. No new knob exists to be left switched on.
//
// The rules under test go to VIP_CHI_CHK_SEV_OFF_E rather than being disabled.
// OFF still evaluates and still counts and only suppresses the report, which is
// what a negative control needs; disabling would stop the counting and leave
// nothing to assert on.

class tc_chi_e_retry_field_negctl extends chi_e_base_test;

  typedef vip_chi_item #(CHI_E_WIDE_CFG_C) item_t;

  `uvm_component_utils(tc_chi_e_retry_field_negctl)

  localparam int SETTLE_C = 40;
  // Phase A's WriteUniqueZero has a modeled completion, so the checker holds it
  // outstanding until the CompDBIDResp arrives while the raw-inject path scopes
  // the REQ's TXSACTIVE window to the flit. Holding the sideband is legal --
  // TXSACTIVE says a node MAY have traffic outstanding, so over-assertion is
  // permitted and under-assertion is the violation -- and it is honest where a
  // waiver would not be. Same value and same reason as
  // tc_chi_e_write_unique_zero_negctl.
  localparam int TXSACTIVE_EXTEND_C = 32;
  // One report per vantage, not "at least one". More would mean the rule is
  // also firing on the compliant traffic that brought the link up, which would
  // make it useless in an ordinary run.
  localparam int EXPECTED_FAILS_C = 1;

  vip_chi_raw_seq #(CHI_E_WIDE_CFG_C) rni_raw_seq;
  vip_chi_raw_seq #(CHI_E_WIDE_CFG_C) snf_raw_seq;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // The injected flits are serviced by this test, not by the responder, so the
  // scoreboard sees flits it never paired and reports them as incomplete
  // transactions. Correct of the scoreboard and beside the point here.
  // ---------------------------------------------------------------------------
  protected virtual function void configure_tb_cfg();

    super.configure_tb_cfg();

    super.tb_cfg.scoreboard_enable           = 1'b0;
    super.tb_cfg.txsactive_extend_max_cycles = TXSACTIVE_EXTEND_C;
  endfunction

  // ---------------------------------------------------------------------------
  // The driver half of the same hold: tb_cfg reaches the checkers, the agent cfg
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
  // Phase A's flit: a WriteUniqueZero that is conformant in every respect except
  // the one under test, so exactly one rule can object to it.
  //
  // Table 2-9 marks the opcode's ExpCompAck prohibited, so that field stays
  // zero. WriteUniqueZero is Snoopable only (Table 2-14) and Table 2-12 lists no
  // Snoopable row without Cacheable and EWA, so MemAttr is set here -- a raw
  // flit bypasses the sequence's per-opcode defaults, and leaving it at zero
  // would trip the attribute rules alongside the retry one and make the counts
  // below prove nothing.
  // ---------------------------------------------------------------------------
  protected function item_t::raw_req_t retry_field_violator();

    item_t::raw_req_t raw_req;

    raw_req            = '0;
    raw_req.txnid      = E_RETRY_NEGCTL_TXN_ID_C;
    raw_req.srcid      = E_RETRY_NEGCTL_RNI_NODE_ID_C;
    raw_req.tgtid      = E_RETRY_NEGCTL_SNF_NODE_ID_C;
    raw_req.opcode     = item_t::req_opcode_t'(VIP_CHI_REQ_WRITE_UNIQUE_ZERO_C);
    raw_req.addr       = E_RETRY_NEGCTL_ADDR_C;
    raw_req.size       = item_t::size_t'(3'd6);
    raw_req.ns         = VIP_CHI_REQ_NON_SECURE_ACCESS_E;
    raw_req.snpattr    = VIP_CHI_SNP_SNOOPABLE_E;
    raw_req.memattr    = 4'b0101;
    raw_req.qos        = 4'h7;
    // The violation, and nothing else on this flit is wrong.
    raw_req.allowretry = 1'b1;
    raw_req.pcrdtype   = E_RETRY_NEGCTL_PCRD_TYPE_C;

    return raw_req;
  endfunction

  // ---------------------------------------------------------------------------
  // The completion phase A's opcode takes: a combined CompDBIDResp carrying the
  // request's own TxnID. The buffer it grants goes unused because the request
  // carries no data, which is the opcode's whole point; the completion form is
  // normative regardless.
  // ---------------------------------------------------------------------------
  protected function item_t::raw_rsp_t comp_dbid_resp();

    item_t::raw_rsp_t raw_rsp;

    raw_rsp         = '0;
    raw_rsp.opcode  = item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_DBID_RESP_C);
    raw_rsp.txnid   = E_RETRY_NEGCTL_TXN_ID_C;
    raw_rsp.dbid    = E_RETRY_NEGCTL_TXN_ID_C;
    raw_rsp.resp    = VIP_CHI_RESP_STATE_I_E;
    raw_rsp.resperr = VIP_CHI_RESP_ERR_NORMAL_OKAY_E;
    raw_rsp.srcid   = E_RETRY_NEGCTL_SNF_NODE_ID_C;
    raw_rsp.tgtid   = E_RETRY_NEGCTL_RNI_NODE_ID_C;
    raw_rsp.qos     = 4'h7;

    return raw_rsp;
  endfunction

  // ---------------------------------------------------------------------------
  // Phase C's flit: a RetryAck for a transaction that does not exist.
  //
  // Well formed in every other respect -- Table A-4 gives RetryAck RespErr and
  // Resp both "0", and DBID is not valid on it -- so the only thing wrong with
  // the flit is the one thing under test.
  // ---------------------------------------------------------------------------
  protected function item_t::raw_rsp_t stray_retry_ack();

    item_t::raw_rsp_t raw_rsp;

    raw_rsp          = '0;
    raw_rsp.opcode   = item_t::rsp_opcode_t'(VIP_CHI_RSP_RETRY_ACK_C);
    raw_rsp.srcid    = E_RETRY_NEGCTL_SNF_NODE_ID_C;
    raw_rsp.tgtid    = E_RETRY_NEGCTL_RNI_NODE_ID_C;
    raw_rsp.pcrdtype = E_RETRY_NEGCTL_PCRD_TYPE_C;
    raw_rsp.qos      = 4'h7;
    // The violation: no request on this link has carried this TxnID.
    raw_rsp.txnid    = E_RETRY_NEGCTL_STRAY_TXN_ID_C;

    return raw_rsp;
  endfunction

  // ---------------------------------------------------------------------------
  // Phase B's flit: a PCrdReturn carrying an address.
  //
  // AllowRetry stays zero and PCrdType stays set, so this flit does NOT also
  // violate phase A's rule -- the two counts stay separable. TxnID stays zero
  // for the same reason: it is in the same zero-marked set as Addr, and setting
  // both would still be one report but would stop naming which field moved.
  // ---------------------------------------------------------------------------
  protected function item_t::raw_req_t pcrd_return_violator();

    item_t::raw_req_t raw_req;

    raw_req          = '0;
    raw_req.opcode   = item_t::req_opcode_t'(VIP_CHI_REQ_PCRD_RETURN_C);
    raw_req.srcid    = E_RETRY_NEGCTL_RNI_NODE_ID_C;
    raw_req.tgtid    = E_RETRY_NEGCTL_SNF_NODE_ID_C;
    raw_req.pcrdtype = E_RETRY_NEGCTL_PCRD_TYPE_C;
    raw_req.qos      = 4'h7;
    // The violation. Table A-3 gives PCrdReturn's Addr column "0a": the
    // transaction addresses nothing.
    raw_req.addr     = E_RETRY_NEGCTL_ADDR_C;

    return raw_req;
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
  // Turn the report off at both ends while keeping the count.
  // ---------------------------------------------------------------------------
  protected function void waive(input vip_chi_check_id_t id);
    super.tb_env.rni_agent.vif.check_severity[id] = VIP_CHI_CHK_SEV_OFF_E;
    super.tb_env.snf_agent.vif.check_severity[id] = VIP_CHI_CHK_SEV_OFF_E;
  endfunction

  // ---------------------------------------------------------------------------
  // Exactly one report at the sending end and one at the receiving end. Both,
  // because a rule asserted at two vantages under one id may be doing its job at
  // only one of them, and a link may carry a bind at either end alone.
  // ---------------------------------------------------------------------------
  protected function void require_provoked(input vip_chi_check_id_t id);

    int unsigned rni_fails;
    int unsigned snf_fails;

    rni_fails = super.tb_env.rni_agent.vif.check_fail_count[id];
    snf_fails = super.tb_env.snf_agent.vif.check_fail_count[id];

    if (rni_fails != EXPECTED_FAILS_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s reported %0d time(s) at the RN-I, expected exactly %0d; below means the flit is not reaching the rule, above means it is firing on compliant traffic too",
        super.tc_name, vip_chi_check_name(id), rni_fails, EXPECTED_FAILS_C))
    end

    if (snf_fails != EXPECTED_FAILS_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s reported %0d time(s) at the SN-F, expected exactly %0d; the receiving vantage of the rule is not doing its half",
        super.tc_name, vip_chi_check_name(id), snf_fails, EXPECTED_FAILS_C))
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Nothing else in the registry may have failed. This is what makes a corrupted
  // flit an honest control rather than a flit that happens to be wrong in
  // several ways at once.
  // ---------------------------------------------------------------------------
  protected function void require_nothing_else_fired(
    input vip_chi_check_id_t allowed[$]
  );

    for (int unsigned i = 0; i < VIP_CHI_CHK_NUM_E; i++) begin
      vip_chi_check_id_t id;
      id = vip_chi_check_id_t'(i);
      if (id inside {allowed}) begin
        continue;
      end
      if ((super.tb_env.rni_agent.vif.check_fail_count[id] != 0) ||
          (super.tb_env.snf_agent.vif.check_fail_count[id] != 0)) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] %s also failed (rni_e=%0d snf_e=%0d); the injected flits are wrong in more ways than the two under test",
          super.tc_name, vip_chi_check_name(id),
          super.tb_env.rni_agent.vif.check_fail_count[id],
          super.tb_env.snf_agent.vif.check_fail_count[id]))
      end
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    int unsigned allow_retry_pass_before;
    int unsigned pcrd_return_pass_before;

    phase.raise_objection(this);

    // Compliant traffic first. It brings the link to RUN and it puts real
    // requests past both rules, so the silence asserted next is a statement
    // about compliant flits rather than about an idle link.
    super.rni_wr_seq.reset();
    super.rni_wr_seq.set_requests(1);
    super.rni_wr_seq.set_initial_addr(E_RETRY_NEGCTL_ADDR_C);
    super.rni_wr_seq.set_size(3'd6);
    super.rni_wr_seq.set_get_response(1'b1);
    super.rni_wr_seq.set_verbose(1'b0);
    super.rni_wr_seq.start(super.tb_env.rni_agent.sequencer);

    super.wait_clocks(4);
    super.drain_observation_fifos();

    this.require_silent(VIP_CHI_CHK_REQ_ALLOW_RETRY_PCRD_ZERO_E);
    this.require_silent(VIP_CHI_CHK_REQ_PCRD_RETURN_FIELDS_ZERO_E);
    this.require_silent(VIP_CHI_CHK_RSP_RETRY_ACK_TXN_ID_E);

    allow_retry_pass_before =
      super.tb_env.rni_agent.vif.check_pass_count[VIP_CHI_CHK_REQ_ALLOW_RETRY_PCRD_ZERO_E];
    pcrd_return_pass_before =
      super.tb_env.rni_agent.vif.check_pass_count[VIP_CHI_CHK_REQ_PCRD_RETURN_FIELDS_ZERO_E];

    if (allow_retry_pass_before == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s recorded no pass on the compliant write; the rule is not evaluating and its silence below would mean nothing",
        super.tc_name,
        vip_chi_check_name(VIP_CHI_CHK_REQ_ALLOW_RETRY_PCRD_ZERO_E)))
    end

    // -- Phase A: AllowRetry asserted together with a P-Credit type. ---------
    this.waive(VIP_CHI_CHK_REQ_ALLOW_RETRY_PCRD_ZERO_E);

    this.rni_raw_seq.reset();
    this.rni_raw_seq.add_raw_req(this.retry_field_violator());
    this.rni_raw_seq.start(super.tb_env.rni_agent.sequencer);

    super.wait_clocks(4);

    // Complete it. Leaving it outstanding would time out the completion rule and
    // mix two verdicts into one run.
    this.snf_raw_seq.reset();
    this.snf_raw_seq.add_raw_rsp(this.comp_dbid_resp());
    this.snf_raw_seq.start(super.tb_env.snf_agent.sequencer);

    super.wait_clocks(SETTLE_C);

    this.require_provoked(VIP_CHI_CHK_REQ_ALLOW_RETRY_PCRD_ZERO_E);
    this.require_silent(VIP_CHI_CHK_REQ_PCRD_RETURN_FIELDS_ZERO_E);

    // -- Phase B: a PCrdReturn that addresses something. ---------------------
    this.waive(VIP_CHI_CHK_REQ_PCRD_RETURN_FIELDS_ZERO_E);

    this.rni_raw_seq.reset();
    this.rni_raw_seq.add_raw_req(this.pcrd_return_violator());
    this.rni_raw_seq.start(super.tb_env.rni_agent.sequencer);

    super.wait_clocks(SETTLE_C);

    this.require_provoked(VIP_CHI_CHK_REQ_PCRD_RETURN_FIELDS_ZERO_E);
    // Phase A's count must not have moved: the PCrdReturn carries AllowRetry
    // zero, so the earlier rule has nothing to say about it, and a second report
    // here would mean the two rules are not separable.
    this.require_provoked(VIP_CHI_CHK_REQ_ALLOW_RETRY_PCRD_ZERO_E);

    // Both rules must still be recording passes on the compliant flits around
    // the injections. A rule that only ever fails is as broken as one that only
    // ever passes.
    if (super.tb_env.rni_agent.vif.check_pass_count[VIP_CHI_CHK_REQ_PCRD_RETURN_FIELDS_ZERO_E] <
        pcrd_return_pass_before) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s pass count went backwards", super.tc_name,
        vip_chi_check_name(VIP_CHI_CHK_REQ_PCRD_RETURN_FIELDS_ZERO_E)))
    end

    // -- Phase C: a RetryAck for a transaction nobody opened. ----------------
    this.waive(VIP_CHI_CHK_RSP_RETRY_ACK_TXN_ID_E);

    this.snf_raw_seq.reset();
    this.snf_raw_seq.add_raw_rsp(this.stray_retry_ack());
    this.snf_raw_seq.start(super.tb_env.snf_agent.sequencer);

    super.wait_clocks(SETTLE_C);

    this.require_provoked(VIP_CHI_CHK_RSP_RETRY_ACK_TXN_ID_E);
    // The earlier two must still stand at one each: a RetryAck is an RSP and
    // neither REQ rule has anything to say about it.
    this.require_provoked(VIP_CHI_CHK_REQ_ALLOW_RETRY_PCRD_ZERO_E);
    this.require_provoked(VIP_CHI_CHK_REQ_PCRD_RETURN_FIELDS_ZERO_E);

    this.require_nothing_else_fired('{VIP_CHI_CHK_REQ_ALLOW_RETRY_PCRD_ZERO_E,
                                     VIP_CHI_CHK_REQ_PCRD_RETURN_FIELDS_ZERO_E,
                                     VIP_CHI_CHK_RSP_RETRY_ACK_TXN_ID_E});

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] %s, %s and %s each provoked once at both vantages, and nothing else in the registry fired",
      super.tc_name,
      vip_chi_check_name(VIP_CHI_CHK_REQ_ALLOW_RETRY_PCRD_ZERO_E),
      vip_chi_check_name(VIP_CHI_CHK_REQ_PCRD_RETURN_FIELDS_ZERO_E),
      vip_chi_check_name(VIP_CHI_CHK_RSP_RETRY_ACK_TXN_ID_E)), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
