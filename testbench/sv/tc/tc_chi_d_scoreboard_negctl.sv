class tc_chi_d_scoreboard_negctl extends chi_base_test;

  `uvm_component_utils(tc_chi_d_scoreboard_negctl)

  chi_scoreboard_negctl_catcher sb_catcher;
  vip_chi_raw_seq #(CHI_D_CFG_C)      snf_raw_seq;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // Create the catcher and the SN-F raw-flit helper once topology is ready.
  // ---------------------------------------------------------------------------
  function void start_of_simulation_phase(input uvm_phase phase);

    super.start_of_simulation_phase(phase);

    this.sb_catcher  = new("sb_orphan_catcher");
    this.snf_raw_seq = vip_chi_raw_seq #(CHI_D_CFG_C)::type_id::create("snf_raw_seq");
  endfunction

  // ---------------------------------------------------------------------------
  // Negative control: the standalone scoreboard stays ENABLED (default). Inject a
  // completion the scoreboard MUST flag as an orphan; if it does not, the
  // scoreboard has silently gone vacuous (checker disabled / analysis ports
  // disconnected / master gate off) and this test fails. This is the standing
  // guard that the always-on data/lifecycle checks — which 13 tests now lean on
  // after the §4 migration — still actually fire.
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t::raw_rsp_t raw_rsp;

    phase.raise_objection(this);

    // Catch (and demote) the single orphan error the scoreboard is expected to
    // emit, so it does not count against the regression verdict.
    uvm_report_cb::add(null, this.sb_catcher);

    // And say WHICH rule is being provoked, so the cross-run aggregation records
    // the failure as asked-for rather than reporting the run that proves the
    // check fires as the check failing. Per rule, not per checker: a second,
    // unintended scoreboard violation in this run must still stand out.
    super.tb_env.scoreboard.expect_failure(VIP_CHI_SB_CHK_RSP_HAS_OPEN_TXN_E);

    // 1) One clean write brings the link to RUN and opens+retires a ctx normally.
    //    The scoreboard must NOT complain about this legal transaction.
    super.rni0_wr_seq.reset();
    super.rni0_wr_seq.set_requests(1);
    super.rni0_wr_seq.set_initial_addr(WRITE_READ_ADDR_C);
    super.rni0_wr_seq.set_size(3'd6);
    super.rni0_wr_seq.set_get_response(1'b1);
    super.rni0_wr_seq.set_verbose(1'b0);
    super.rni0_wr_seq.start(super.v_sqr.rni_sequencer);

    super.wait_clocks(4);

    // 2) Inject a bare Comp RSP whose TxnID matches no outstanding request. The
    //    RN-I monitor observes it inbound (role SN-F) and Checker A must report it
    //    as an orphan completion (no open ctx for that {tgt,txn}).
    raw_rsp         = '0;
    raw_rsp.dbid    = item_t::txn_id_t'(8'hF7);
    raw_rsp.resp    = VIP_CHI_RESP_STATE_I_E;
    raw_rsp.resperr = VIP_CHI_RESP_ERR_NORMAL_OKAY_E;
    raw_rsp.opcode  = item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_C);
    raw_rsp.txnid   = item_t::txn_id_t'(8'hF7);
    raw_rsp.srcid   = SNF_NODE_ID_C;
    raw_rsp.tgtid   = RNI_NODE_ID_C;
    raw_rsp.qos     = 4'h0;

    this.snf_raw_seq.reset();
    this.snf_raw_seq.add_raw_rsp(raw_rsp);
    this.snf_raw_seq.start(super.v_sqr.snf_sequencer);

    super.wait_clocks(8);

    uvm_report_cb::delete(null, this.sb_catcher);

    // 3) Verdict: the scoreboard MUST have flagged the injected orphan.
    if (!this.sb_catcher.saw_orphan_error) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] scoreboard did NOT flag the injected orphan completion - it may be vacuous or disconnected",
        super.tc_name))
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] scoreboard correctly flagged the injected orphan (negative control passed)",
      super.tc_name), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
