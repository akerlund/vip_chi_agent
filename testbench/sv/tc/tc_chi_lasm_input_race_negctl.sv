// Negative control for the OBSERVER half of the asynchronous race condition.
//
// IHI 0050 E §14.6.3 / D §13.6.3 states four orderings on a component's own two
// outputs and then, separately, an obligation on whoever WATCHES a pair that
// arrived out of order:
//
//   "For all input race conditions, a component that observes the input race is
//    required to wait for both signals before changing any output signals. This
//    is represented in Figure 14-5 by the fact that the only permitted output
//    transition from a race state is caused by the arrival of the other signal
//    associated with the race condition."
//
// This test exists because FIXING the VIP removed the rule's only failing
// observation. CHI_LASM_INPUT_RACE_HOLD had exactly one, and it was the VIP's
// own defect -- the completer's acknowledge moving through a race -- rather than
// deliberate stimulus. With that fixed the rule could no longer fail anywhere,
// which in every log and in the vacuity report is indistinguishable from a rule
// that is never evaluated. A rule that cannot fail is the state this VIP's
// per-check mechanism exists to make impossible.
//
// Two knobs, and it takes both, which is the shape of the requirement:
//   * the REQUESTER aborts its activation, which is what produces a pair of
//     outputs arriving at the completer out of order -- the race;
//   * the COMPLETER then ignores it and moves its outputs through it.
//
// Neither alone is a control. Without the abort there is no race to observe and
// the rule is vacuous; without the ignore the completer waits and the rule
// passes. That is why the two are separate knobs rather than one.
//
// The rule is turned down to VIP_CHI_CHK_SEV_OFF_E rather than disabled. OFF
// still EVALUATES and still COUNTS -- it only suppresses the report -- which is
// what a negative control needs: an SVA $error cannot be demoted by a
// uvm_report_catcher, so without it the only way to prove the rule fires would
// be to print an error indistinguishable from a real one.

class tc_chi_lasm_input_race_negctl extends chi_base_test;

  `uvm_component_utils(tc_chi_lasm_input_race_negctl)

  localparam item_t::addr_t ADDR_C   = item_t::addr_t'(44'h3E00_0000);
  localparam bit [2:0]      SIZE_C   = 3'd6;   // 64 B = 4 beats on the CHI-D cut
  localparam int            SETTLE_C = 20;

  // One race observed, one output moved through it, one report. The requester
  // observes none: its own inputs are the completer's two outputs, and those
  // stay ordered whatever this knob does to the completer's reaction.
  localparam int            HOLD_REPORTS_RNI_C = 0;
  localparam int            HOLD_REPORTS_SNF_C = 1;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // The abort makes the race; the ignore makes the violation.
  // ---------------------------------------------------------------------------
  protected virtual function void configure_agent_cfgs();

    super.configure_agent_cfgs();

    super.rni_cfg.lasm_abort_activation  = 1'b1;
    super.snf_cfg.lasm_ignore_input_race = 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    int unsigned rni_hold;
    int unsigned snf_hold;
    int unsigned rni_trans;
    int unsigned snf_trans;

    phase.raise_objection(this);

    // Suppress the report, keep the count, at both ends -- so an unexpected
    // report at the requester is caught by its own count below rather than by an
    // $error that reads like a real one.
    super.tb_env.rni_agent.vif.check_severity[VIP_CHI_CHK_LASM_INPUT_RACE_HOLD_E] =
      VIP_CHI_CHK_SEV_OFF_E;
    super.tb_env.snf_agent.vif.check_severity[VIP_CHI_CHK_LASM_INPUT_RACE_HOLD_E] =
      VIP_CHI_CHK_SEV_OFF_E;

    // The abort is a genuine illegal transition, so the transition rule fires
    // too. It is not what this test is about, and it has its own control in
    // tc_chi_lasm_illegal_transition -- suppressed here and only sanity-bounded.
    super.tb_env.rni_agent.vif.check_severity[VIP_CHI_CHK_LASM_LEGAL_TRANSITION_E] =
      VIP_CHI_CHK_SEV_OFF_E;
    super.tb_env.snf_agent.vif.check_severity[VIP_CHI_CHK_LASM_LEGAL_TRANSITION_E] =
      VIP_CHI_CHK_SEV_OFF_E;
    super.tb_env.rni_agent.vif.check_severity[VIP_CHI_CHK_LASM_OUTPUT_RACE_E] =
      VIP_CHI_CHK_SEV_OFF_E;
    super.tb_env.snf_agent.vif.check_severity[VIP_CHI_CHK_LASM_OUTPUT_RACE_E] =
      VIP_CHI_CHK_SEV_OFF_E;

    // Ordinary traffic after the aborted bring-up: the link must have come up
    // properly on the second attempt, or this would hang rather than pass. That
    // matters more here than in the sibling test -- a completer that ignores the
    // race must still end up with a working link, or the control would be
    // proving the rule fires by wedging the interface.
    super.rni0_rd_seq.reset();
    super.rni0_rd_seq.set_requests(1);
    super.rni0_rd_seq.set_initial_addr(ADDR_C);
    super.rni0_rd_seq.set_size(SIZE_C);
    super.rni0_rd_seq.set_get_response(1'b1);
    super.rni0_rd_seq.set_verbose(1'b0);
    super.rni0_rd_seq.start(super.v_sqr.rni_sequencer);

    super.wait_clocks(SETTLE_C);

    rni_hold = super.tb_env.rni_agent.vif.check_fail_count[VIP_CHI_CHK_LASM_INPUT_RACE_HOLD_E];
    snf_hold = super.tb_env.snf_agent.vif.check_fail_count[VIP_CHI_CHK_LASM_INPUT_RACE_HOLD_E];

    if ((rni_hold != HOLD_REPORTS_RNI_C) || (snf_hold != HOLD_REPORTS_SNF_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the observed input race produced %0d (RN-I) / %0d (SN-F) hold violation(s), expected exactly %0d / %0d; zero at the completer means the knob no longer defeats the hold, or the race is not being observed at all",
        super.tc_name, rni_hold, snf_hold, HOLD_REPORTS_RNI_C, HOLD_REPORTS_SNF_C))
    end

    // NO pass-count assertion here, and that is deliberate rather than an
    // omission. The property is `armed |-> stable`, so it only ever evaluates
    // non-vacuously in a cycle where a race is armed -- and with this knob on,
    // every such cycle is a violation. There is exactly one race in this run, so
    // a passing evaluation cannot exist here to assert on.
    //
    // The pass side of the evidence lives in tc_chi_lasm_race, where the
    // completer observes a race and waits it out correctly. Between the two the
    // rule is shown to distinguish: it fires there and only there. The guard
    // against a rule that reports on everything is the requester's ZERO above.
    // The abort still has to be the illegal transition it always was: if this
    // count went to zero the stimulus stopped happening and the race above came
    // from somewhere else.
    rni_trans = super.tb_env.rni_agent.vif.check_fail_count[VIP_CHI_CHK_LASM_LEGAL_TRANSITION_E];
    snf_trans = super.tb_env.snf_agent.vif.check_fail_count[VIP_CHI_CHK_LASM_LEGAL_TRANSITION_E];

    if ((rni_trans == 0) || (snf_trans == 0)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the aborted activation produced %0d (RN-I) / %0d (SN-F) illegal-transition report(s); the stimulus this control rests on is not happening",
        super.tc_name, rni_trans, snf_trans))
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] a completer that ignored an observed input race was flagged %0d time(s) at its own bind and %0d at the requester's, and the link still carried a read to completion",
      super.tc_name, snf_hold, rni_hold), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
