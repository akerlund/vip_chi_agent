// IHI 0050 E section 2.5 / D section 2.5:
//
//   "A Comp response message sent separate from a DBIDResp or DBIDRespOrd
//    message for a Write transaction must include the same DBID field value."
//
// and, two lines later, the exemption that has to be built in rather than
// retrofitted: for Atomic transactions the same equality is "permitted, but is
// not required". A rule written for writes and applied to atomics would
// false-fail a conformant completer, so the exemption gets a phase of its own.
//
//   phase A  a split response whose Comp CARRIES the granted DBID. Must pass,
//            and must RECORD a pass -- the rule arms only on a separate grant,
//            so silence here would mean it never evaluated.
//   phase B  a split response whose Comp carries a different DBID. Must report
//            exactly once at each end.
//   phase C  a real ATOMIC, serviced by the SN-F's own responder, which splits
//            its response exactly as a conformant completer does. The rule must
//            neither FAIL nor PASS: the exemption means it does not evaluate,
//            and a rule that evaluated and held would record a pass.
//
// Phase C is why this test is three phases rather than two. A rule can be
// perfectly right about writes and still be wrong, and the wrongness only shows
// on traffic a conformant completer is allowed to produce.
//
// The PASS count is what makes phase C discriminating, and it is worth being
// explicit about why. The SN-F's own atomic completion carries MATCHING DBIDs,
// because the SN-F is conformant. So with the exemption removed the rule would
// not fail there -- it would quietly record a pass. Asserting only "no new
// failure" would therefore pass with the exemption deleted, and prove nothing.
//
// Phases A and B use raw injection, because no completer here splits a response
// with a renumbered DBID and correctly so -- that is the point of a negative
// control. Phase C uses the real responder, because what it needs is a
// CONFORMANT atomic and the SN-F already drives one.
//
// Runs under: testbench/sv/tb/chi_tb_top.sv
class tc_chi_comp_dbid_negctl extends chi_e_base_test;

  typedef vip_chi_item #(CHI_E_WIDE_CFG_C) item_t;

  `uvm_component_utils(tc_chi_comp_dbid_negctl)

  localparam int SETTLE_C = 40;
  localparam int TXSACTIVE_EXTEND_C = 48;
  // AtomicStore returns no data, so phase C does not also have to satisfy
  // CHI_ATOMIC_RETURN_USES_DAT_COMPLETION. Size 3 is 8 bytes, which Table 2-17
  // permits for every atomic but Compare.
  localparam int unsigned ATOMIC_SIZE_C = 3;
  // One report, on phase B alone.
  localparam int EXPECTED_FAIL_C = 1;

  vip_chi_raw_seq    #(CHI_E_WIDE_CFG_C) rni_raw_seq;
  vip_chi_raw_seq    #(CHI_E_WIDE_CFG_C) snf_raw_seq;
  vip_chi_atomic_seq #(CHI_E_WIDE_CFG_C) atomic_seq;

  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // The injected transactions are serviced by this test, not by the responder,
  // so the scoreboard sees flits it never paired.
  // ---------------------------------------------------------------------------
  protected virtual function void configure_tb_cfg();

    super.configure_tb_cfg();

    super.tb_cfg.scoreboard_enable = 1'b0;
    super.tb_cfg.txsactive_extend_max_cycles = TXSACTIVE_EXTEND_C;
  endfunction

  protected virtual function void configure_agent_cfgs();

    super.configure_agent_cfgs();

    super.rni_cfg.txsactive_extend_max_cycles = TXSACTIVE_EXTEND_C;
    // Phase C needs the SN-F to SPLIT its atomic response, because a combined
    // CompDBIDResp carries the only DBID the transaction has and cannot
    // disagree with anything -- the rule would never arm and the phase would
    // prove nothing. With this set the SN-F drives DBIDResp then Comp, both
    // carrying the request's TxnID as DBID, which is exactly the conformant
    // split the exemption has to stay quiet about.
    super.snf_cfg.split_write_rsp = 1'b1;
  endfunction

  function void start_of_simulation_phase(input uvm_phase phase);

    super.start_of_simulation_phase(phase);

    this.rni_raw_seq = vip_chi_raw_seq #(CHI_E_WIDE_CFG_C)::type_id::create("rni_raw_seq");
    this.snf_raw_seq = vip_chi_raw_seq #(CHI_E_WIDE_CFG_C)::type_id::create("snf_raw_seq");
    this.atomic_seq  = vip_chi_atomic_seq #(CHI_E_WIDE_CFG_C)::type_id::create("atomic_seq");
  endfunction

  // ---------------------------------------------------------------------------
  // One request, well formed apart from what the caller picks.
  // ---------------------------------------------------------------------------
  // The opcode arrives at FULL width and is narrowed once, on the assignment
  // below. Casting it at the call site instead makes the constant a truncated
  // COMPARE operand, which check_opcodes.py rejects and is right to: 0x43 in six
  // CHI-D bits is 0x03, a different opcode, and this helper's shape is exactly
  // the one that has hidden that mistake before.
  protected function item_t::raw_req_t make_req(
      input logic [VIP_CHI_MAX_REQ_OPCODE_WIDTH_C - 1 : 0] opcode,
      input item_t::txn_id_t     txn_id,
      input item_t::size_t       size,
      input logic                snpattr,
      input logic [3 : 0]        memattr);

    item_t::raw_req_t raw_req;

    raw_req            = '0;
    raw_req.txnid      = txn_id;
    raw_req.srcid      = E_WUZ_NEGCTL_RNI_NODE_ID_C;
    raw_req.tgtid      = E_WUZ_NEGCTL_SNF_NODE_ID_C;
    raw_req.opcode     = item_t::req_opcode_t'(opcode);
    raw_req.addr       = E_WUZ_NEGCTL_ADDR_C;
    raw_req.size       = size;
    raw_req.ns         = VIP_CHI_REQ_NON_SECURE_ACCESS_E;
    raw_req.snpattr    = snpattr;
    raw_req.memattr    = memattr;
    raw_req.allowretry = 1'b1;
    raw_req.qos        = 4'h7;

    return raw_req;
  endfunction

  // Snoopable only (Table 2-14), and Table 2-12 lists no Snoopable row without
  // Cacheable and EWA.
  protected function item_t::raw_req_t write_unique_zero(input item_t::txn_id_t txn_id);

    return this.make_req(VIP_CHI_REQ_WRITE_UNIQUE_ZERO_C,
                         txn_id, item_t::size_t'(3'd6), VIP_CHI_SNP_SNOOPABLE_E,
                         4'b0101);
  endfunction

  protected function item_t::raw_rsp_t make_rsp(
      input item_t::rsp_opcode_t opcode,
      input item_t::txn_id_t     txn_id,
      input item_t::txn_id_t     dbid);

    item_t::raw_rsp_t raw_rsp;

    raw_rsp         = '0;
    raw_rsp.opcode  = opcode;
    raw_rsp.txnid   = txn_id;
    raw_rsp.dbid    = dbid;
    raw_rsp.resp    = VIP_CHI_RESP_STATE_I_E;
    raw_rsp.resperr = VIP_CHI_RESP_ERR_NORMAL_OKAY_E;
    raw_rsp.srcid   = E_WUZ_NEGCTL_SNF_NODE_ID_C;
    raw_rsp.tgtid   = E_WUZ_NEGCTL_RNI_NODE_ID_C;
    raw_rsp.qos     = 4'h7;

    return raw_rsp;
  endfunction

  protected task inject_req(input item_t::raw_req_t raw_req);

    this.rni_raw_seq.reset();
    this.rni_raw_seq.add_raw_req(raw_req);
    this.rni_raw_seq.start(super.tb_env.rni_agent.sequencer);
    super.wait_clocks(4);
  endtask

  protected task inject_rsp(input item_t::raw_rsp_t raw_rsp);

    this.snf_raw_seq.reset();
    this.snf_raw_seq.add_raw_rsp(raw_rsp);
    this.snf_raw_seq.start(super.tb_env.snf_agent.sequencer);
    super.wait_clocks(4);
  endtask

  // ---------------------------------------------------------------------------
  // A split response: the grant first, then the completion, which is the only
  // shape in which two messages carry a DBID that could disagree.
  // ---------------------------------------------------------------------------
  protected task split_response(input item_t::txn_id_t txn_id,
                                input item_t::txn_id_t comp_dbid);

    this.inject_rsp(this.make_rsp(item_t::rsp_opcode_t'(VIP_CHI_RSP_DBID_RESP_C),
                                  txn_id, COMP_DBID_GRANTED_C));
    this.inject_rsp(this.make_rsp(item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_C),
                                  txn_id, comp_dbid));
  endtask

  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    int unsigned pass_rni_before;
    int unsigned pass_snf_before;
    int unsigned pass_rni_after;
    int unsigned pass_snf_after;
    int unsigned fail_rni;
    int unsigned fail_snf;
    int unsigned after_rni;
    int unsigned after_snf;
    item_t::data_t atomic_data[$];

    phase.raise_objection(this);

    super.rni_wr_seq.reset();
    super.rni_wr_seq.set_requests(1);
    super.rni_wr_seq.set_initial_addr(E_WUZ_NEGCTL_ADDR_C);
    super.rni_wr_seq.set_size(3'd6);
    super.rni_wr_seq.set_get_response(1'b1);
    super.rni_wr_seq.set_verbose(1'b0);
    super.rni_wr_seq.start(super.tb_env.rni_agent.sequencer);

    super.wait_clocks(4);
    super.drain_observation_fifos();

    fail_rni = super.tb_env.rni_agent.vif.check_fail_count[VIP_CHI_CHK_COMP_DBID_MATCHES_GRANT_E];
    fail_snf = super.tb_env.snf_agent.vif.check_fail_count[VIP_CHI_CHK_COMP_DBID_MATCHES_GRANT_E];

    if ((fail_rni != 0) || (fail_snf != 0)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s already reported rni_e=%0d snf_e=%0d time(s) on compliant traffic; the counts below would prove nothing",
        super.tc_name, vip_chi_check_name(VIP_CHI_CHK_COMP_DBID_MATCHES_GRANT_E),
        fail_rni, fail_snf))
    end

    // -- Phase A: the Comp carries the granted DBID. Must pass. --------------
    pass_rni_before = super.tb_env.rni_agent.vif.check_pass_count[VIP_CHI_CHK_COMP_DBID_MATCHES_GRANT_E];
    pass_snf_before = super.tb_env.snf_agent.vif.check_pass_count[VIP_CHI_CHK_COMP_DBID_MATCHES_GRANT_E];

    this.inject_req(this.write_unique_zero(COMP_DBID_TXN_ID_PASS_C));
    this.split_response(COMP_DBID_TXN_ID_PASS_C, COMP_DBID_GRANTED_C);
    super.wait_clocks(SETTLE_C);

    pass_rni_after = super.tb_env.rni_agent.vif.check_pass_count[VIP_CHI_CHK_COMP_DBID_MATCHES_GRANT_E];
    pass_snf_after = super.tb_env.snf_agent.vif.check_pass_count[VIP_CHI_CHK_COMP_DBID_MATCHES_GRANT_E];

    if ((pass_rni_after <= pass_rni_before) || (pass_snf_after <= pass_snf_before)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s recorded no pass for a conformant split response: rni_e %0d -> %0d, snf_e %0d -> %0d. The rule arms only on a SEPARATE grant, so silence here means the grant is not reaching it",
        super.tc_name, vip_chi_check_name(VIP_CHI_CHK_COMP_DBID_MATCHES_GRANT_E),
        pass_rni_before, pass_rni_after, pass_snf_before, pass_snf_after))
    end

    fail_rni = super.tb_env.rni_agent.vif.check_fail_count[VIP_CHI_CHK_COMP_DBID_MATCHES_GRANT_E];
    fail_snf = super.tb_env.snf_agent.vif.check_fail_count[VIP_CHI_CHK_COMP_DBID_MATCHES_GRANT_E];

    if ((fail_rni != 0) || (fail_snf != 0)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s reported rni_e=%0d snf_e=%0d on a Comp that carried exactly the granted DBID",
        super.tc_name, vip_chi_check_name(VIP_CHI_CHK_COMP_DBID_MATCHES_GRANT_E),
        fail_rni, fail_snf))
    end

    // -- Phase B: the Comp carries a different DBID. Must report. ------------
    super.tb_env.rni_agent.vif.check_severity[VIP_CHI_CHK_COMP_DBID_MATCHES_GRANT_E] =
      VIP_CHI_CHK_SEV_OFF_E;
    super.tb_env.snf_agent.vif.check_severity[VIP_CHI_CHK_COMP_DBID_MATCHES_GRANT_E] =
      VIP_CHI_CHK_SEV_OFF_E;

    this.inject_req(this.write_unique_zero(COMP_DBID_TXN_ID_FAIL_C));
    this.split_response(COMP_DBID_TXN_ID_FAIL_C, COMP_DBID_OTHER_C);
    super.wait_clocks(SETTLE_C);

    fail_rni = super.tb_env.rni_agent.vif.check_fail_count[VIP_CHI_CHK_COMP_DBID_MATCHES_GRANT_E];
    fail_snf = super.tb_env.snf_agent.vif.check_fail_count[VIP_CHI_CHK_COMP_DBID_MATCHES_GRANT_E];

    if (fail_rni != EXPECTED_FAIL_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s reported %0d time(s) at the RN-I against exactly %0d; below means the mismatch is not reaching the rule, above means it is firing on phase A as well",
        super.tc_name, vip_chi_check_name(VIP_CHI_CHK_COMP_DBID_MATCHES_GRANT_E),
        fail_rni, EXPECTED_FAIL_C))
    end

    if (fail_snf != EXPECTED_FAIL_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s reported %0d time(s) at the SN-F against exactly %0d; the sending vantage is not doing its half",
        super.tc_name, vip_chi_check_name(VIP_CHI_CHK_COMP_DBID_MATCHES_GRANT_E),
        fail_snf, EXPECTED_FAIL_C))
    end

    // -- Phase C: a real ATOMIC. The rule must not evaluate at all. ----------
    pass_rni_before = super.tb_env.rni_agent.vif.check_pass_count[VIP_CHI_CHK_COMP_DBID_MATCHES_GRANT_E];
    pass_snf_before = super.tb_env.snf_agent.vif.check_pass_count[VIP_CHI_CHK_COMP_DBID_MATCHES_GRANT_E];

    this.atomic_seq.reset();
    this.atomic_seq.set_atomic_op(VIP_CHI_ATOMIC_OP_STORE_0_E);
    this.atomic_seq.set_requests(1);
    this.atomic_seq.set_initial_addr(ATOMIC_ADDR_C);
    this.atomic_seq.set_size(item_t::size_t'(ATOMIC_SIZE_C));
    this.atomic_seq.set_get_response(1'b1);
    this.atomic_seq.set_verbose(1'b0);
    atomic_data.delete();
    atomic_data.push_back(8'h10);
    this.atomic_seq.set_data(atomic_data);
    this.atomic_seq.start(super.tb_env.rni_agent.sequencer);

    super.wait_clocks(SETTLE_C);

    after_rni = super.tb_env.rni_agent.vif.check_fail_count[VIP_CHI_CHK_COMP_DBID_MATCHES_GRANT_E];
    after_snf = super.tb_env.snf_agent.vif.check_fail_count[VIP_CHI_CHK_COMP_DBID_MATCHES_GRANT_E];

    if ((after_rni != fail_rni) || (after_snf != fail_snf)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s reported on an ATOMIC transaction: rni_e %0d -> %0d, snf_e %0d -> %0d. Section 2.5 makes the DBID equality 'permitted, but is not required' for atomics, so a completer that renumbers one is conformant and this rule is inventing a requirement",
        super.tc_name, vip_chi_check_name(VIP_CHI_CHK_COMP_DBID_MATCHES_GRANT_E),
        fail_rni, after_rni, fail_snf, after_snf))
    end

    pass_rni_after = super.tb_env.rni_agent.vif.check_pass_count[VIP_CHI_CHK_COMP_DBID_MATCHES_GRANT_E];
    pass_snf_after = super.tb_env.snf_agent.vif.check_pass_count[VIP_CHI_CHK_COMP_DBID_MATCHES_GRANT_E];

    if ((pass_rni_after != pass_rni_before) || (pass_snf_after != pass_snf_before)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s EVALUATED on an ATOMIC transaction: rni_e %0d -> %0d, snf_e %0d -> %0d. The SN-F's own atomic completion carries matching DBIDs, so a rule without the exemption records a pass here rather than a failure -- which is why this check, and not the failure count above, is what proves the exemption is in place",
        super.tc_name, vip_chi_check_name(VIP_CHI_CHK_COMP_DBID_MATCHES_GRANT_E),
        pass_rni_before, pass_rni_after, pass_snf_before, pass_snf_after))
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] %s passed a matching split response, reported %0d time(s) at each end on a mismatched one, and neither failed nor evaluated on a conformant Atomic",
      super.tc_name, vip_chi_check_name(VIP_CHI_CHK_COMP_DBID_MATCHES_GRANT_E),
      fail_rni), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
