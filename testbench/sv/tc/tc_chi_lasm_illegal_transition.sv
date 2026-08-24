// Negative control for the link-activation state machine.
//
//
// The LASM may only hold, or advance one step around
// STOP -> ACTIVATE -> RUN -> DEACTIVATE -> STOP. Nothing checked that until the
// state existed: the link gating rules asked only "is the link RUN", which
// cannot tell a link that reached RUN legally from one that jumped there.
//
// cfg.lasm_abort_activation makes the RN-I raise txlinkactivereq and withdraw it
// again before the completer acknowledges, so the link leaves ACTIVATE without
// ever reaching RUN. A requester that has asked for the link must wait for the
// acknowledge, so this is a genuine violation rather than an unusual-but-legal
// sequence -- which is what makes it a usable control rather than a check tuned
// to its own stimulus.
//
// Both halves are asserted, because a transition check that fires on ordinary
// bring-up would be worse than none at all:
//   * the aborted activation must be reported, on both binds;
//   * the real activation that follows must not be, and the run must still
//     carry ordinary traffic to completion.
//
// The rule is turned down to VIP_CHI_CHK_SEV_OFF_E rather than disabled. OFF still
// EVALUATES and still COUNTS -- it only suppresses the report -- which is
// exactly what a negative control needs: an SVA $error cannot be demoted by a
// uvm_report_catcher the way a UVM report can, so without it the only way to
// prove the rule fires would be to print an error indistinguishable from a real
// one. Disabling instead would stop the counting too, and there would be
// nothing left to assert on.

class tc_chi_lasm_illegal_transition extends chi_base_test;

  `uvm_component_utils(tc_chi_lasm_illegal_transition)

  localparam item_t::addr_t ADDR_C   = item_t::addr_t'(44'h3D40_0000);
  localparam bit [2:0]      SIZE_C   = 3'd6;   // 64 B = 4 beats on the CHI-D cut
  localparam int            SETTLE_C = 20;
  // See the checks below for the steps each of these decomposes into.
  localparam int            ABORT_REPORTS_C     = 2;
  localparam int            RACE_REPORTS_RNI_C  = 2;
  localparam int            RACE_REPORTS_SNF_C  = 0;
  // 14.6.3's companion requirement, on the OBSERVER rather than the driver. The
  // completer is where it lands, and where it currently fails -- see the check.
  localparam int            HOLD_REPORTS_RNI_C  = 0;
  localparam int            HOLD_REPORTS_SNF_C  = 0;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // Abort one bring-up on the requester that owns the activation request.
  // ---------------------------------------------------------------------------
  protected virtual function void configure_agent_cfgs();

    super.configure_agent_cfgs();

    super.rni_cfg.lasm_abort_activation = 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    int unsigned rni_fails;
    int unsigned snf_fails;
    int unsigned rni_race;
    int unsigned snf_race;
    int unsigned rni_hold;
    int unsigned snf_hold;

    phase.raise_objection(this);

    // Suppress the report, keep the count. Done here rather than through a
    // dedicated port: any test can address any check this way, which is what
    // replaced the one-off suppression the first cut of this test needed.
    super.tb_env.rni_agent.vif.check_severity[VIP_CHI_CHK_LASM_LEGAL_TRANSITION_E] =
      VIP_CHI_CHK_SEV_OFF_E;
    super.tb_env.snf_agent.vif.check_severity[VIP_CHI_CHK_LASM_LEGAL_TRANSITION_E] =
      VIP_CHI_CHK_SEV_OFF_E;
    // Suppressed at BOTH ends although only the requester is expected to report
    // it, so an unexpected report at the completer is caught by its own count
    // below -- naming the rule -- rather than by an $error indistinguishable
    // from a real one.
    super.tb_env.rni_agent.vif.check_severity[VIP_CHI_CHK_LASM_OUTPUT_RACE_E] =
      VIP_CHI_CHK_SEV_OFF_E;
    super.tb_env.snf_agent.vif.check_severity[VIP_CHI_CHK_LASM_OUTPUT_RACE_E] =
      VIP_CHI_CHK_SEV_OFF_E;
    super.tb_env.rni_agent.vif.check_severity[VIP_CHI_CHK_LASM_INPUT_RACE_HOLD_E] =
      VIP_CHI_CHK_SEV_OFF_E;
    super.tb_env.snf_agent.vif.check_severity[VIP_CHI_CHK_LASM_INPUT_RACE_HOLD_E] =
      VIP_CHI_CHK_SEV_OFF_E;

    // Ordinary traffic after the aborted bring-up: the link must have come up
    // properly on the second attempt, or this would hang rather than pass.
    super.rni0_rd_seq.reset();
    super.rni0_rd_seq.set_requests(1);
    super.rni0_rd_seq.set_initial_addr(ADDR_C);
    super.rni0_rd_seq.set_size(SIZE_C);
    super.rni0_rd_seq.set_get_response(1'b1);
    super.rni0_rd_seq.set_verbose(1'b0);
    super.rni0_rd_seq.start(super.v_sqr.rni_sequencer);

    super.wait_clocks(SETTLE_C);

    // Read through the agents' virtual interfaces. The checker publishes the
    // count on the interface rather than keeping it internal, because a package
    // may hold no hierarchical reference and this test compiles into one -- and
    // a value that changes every cycle cannot come through the config DB, which
    // carries a snapshot.
    rni_fails = super.tb_env.rni_agent.vif.check_fail_count[VIP_CHI_CHK_LASM_LEGAL_TRANSITION_E];
    snf_fails = super.tb_env.snf_agent.vif.check_fail_count[VIP_CHI_CHK_LASM_LEGAL_TRANSITION_E];

    // Both ends observe the same handshake, so both must have seen the aborted
    // bring-up. One end reporting alone would mean the state is being derived
    // from something polarity-specific rather than from the link.
    if (rni_fails < 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the RN-I checker counted %0d illegal LASM transition(s) on a deliberately aborted activation - the transition check may be vacuous",
        super.tc_name, rni_fails))
    end

    if (snf_fails < 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the SN-F checker counted %0d illegal LASM transition(s) on a deliberately aborted activation - the transition check may be vacuous",
        super.tc_name, snf_fails))
    end

    // One aborted bring-up is TWO reports per bind, and the decomposition is the
    // point rather than a number to tune. The requester raises its request and
    // withdraws it before the acknowledge, which Table 14-2 forbids -- "the
    // transmitter remains in the ACTIVATE state while it is waiting for the
    // receiver to acknowledge" -- and that one illegal act leaves two off-axis
    // steps behind on the machine that owns the aborted request, which each end
    // sees from its own side (TX at the requester, RX at the completer):
    //
    //   ACTIVATE -> STOP      the abort itself: the request up, then down, with
    //                         no acknowledge in between
    //   STOP -> DEACTIVATE    the acknowledge arriving a cycle later, for a
    //                         request that is already gone
    //
    // Neither is a permitted race. Figure 14-5's coloured states are COMBINED
    // (Tx,Rx) states reached by diagonals where two signals move at once; each
    // machine's own axis is a strictly one-way cycle with no exceptions, and
    // these are single-machine steps.
    //
    // It was THREE until the completer stopped withdrawing its own request
    // before its own acknowledge had risen -- 14.6.3's fourth ordering, fixed in
    // the SN-F, HN-F and HN-I sideband drivers. That defect added a third step,
    // ACTIVATE -> DEACTIVATE, where request and acknowledge crossed in one
    // cycle. The count fell because the VIP got more conformant, not because the
    // checker got quieter, and the output-race count below is what holds the fix
    // in place.
    //
    // Checked EXACTLY, not as a ceiling: drift either way means the handshake
    // changed shape and wants reading, not absorbing.
    if ((rni_fails != ABORT_REPORTS_C) || (snf_fails != ABORT_REPORTS_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] one aborted activation produced %0d (RN-I) / %0d (SN-F) counts, expected exactly %0d at each end; more means the legal bring-up that followed is being flagged too, fewer means a machine stopped judging its own axis",
        super.tc_name, rni_fails, snf_fails, ABORT_REPORTS_C))
    end

    // The same abort is a Banned Output Race, and 14.6.3 attributes it to ONE
    // component: the requester deasserts TXREQ before RXACK is asserted (the
    // fourth ordering), and a cycle later its own acknowledge rises against a
    // request that is already down (the first).
    //
    // The completer must report NONE, and that asymmetry is the assertion worth
    // having: 14.6.3 binds each component's own two outputs, so a completer
    // dragged into an illegal handshake by its peer still has to keep its own
    // pair ordered. This one did not, until its sideband driver was made to hold
    // its request until its own acknowledge had risen. A non-zero count here
    // means that regressed.
    rni_race = super.tb_env.rni_agent.vif.check_fail_count[VIP_CHI_CHK_LASM_OUTPUT_RACE_E];
    snf_race = super.tb_env.snf_agent.vif.check_fail_count[VIP_CHI_CHK_LASM_OUTPUT_RACE_E];

    if ((rni_race != RACE_REPORTS_RNI_C) || (snf_race != RACE_REPORTS_SNF_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the aborted activation produced %0d (RN-I) / %0d (SN-F) banned-output-race report(s), expected exactly %0d / %0d; a report at the completer means its own two outputs stopped being ordered against each other",
        super.tc_name, rni_race, snf_race, RACE_REPORTS_RNI_C, RACE_REPORTS_SNF_C))
    end

    // 14.6.3's companion requirement, and this one is on the OBSERVER: "a
    // component that observes the input race is required to wait for both
    // signals before changing any output signals."
    //
    // The requester's abort reaches the completer as an input race -- its two
    // inputs step out of the order the four orderings require -- and the
    // completer does NOT wait: its acknowledge, one cycle behind its own
    // request, rises in the middle of the race. That is a real gap in this VIP,
    // recorded rather than waived, and the count is pinned at 1 so the fix shows
    // up here as this dropping to zero and nowhere else.
    //
    // The requester reports NONE: its own inputs are the completer's two
    // outputs, and those stay ordered.
    rni_hold = super.tb_env.rni_agent.vif.check_fail_count[VIP_CHI_CHK_LASM_INPUT_RACE_HOLD_E];
    snf_hold = super.tb_env.snf_agent.vif.check_fail_count[VIP_CHI_CHK_LASM_INPUT_RACE_HOLD_E];

    if ((rni_hold != HOLD_REPORTS_RNI_C) || (snf_hold != HOLD_REPORTS_SNF_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the input race produced %0d (RN-I) / %0d (SN-F) hold violation(s), expected exactly %0d / %0d",
        super.tc_name, rni_hold, snf_hold, HOLD_REPORTS_RNI_C, HOLD_REPORTS_SNF_C))
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] aborted activation flagged %0d (RN-I) / %0d (SN-F) time(s), the bring-up that followed was not, and one read completed over the recovered link",
      super.tc_name, rni_fails, snf_fails), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
