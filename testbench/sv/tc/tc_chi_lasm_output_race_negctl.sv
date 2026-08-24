// Negative control for IHI 0050 E §14.6.3 / D §13.6.3's SECOND ordering.
//
// The section states ONE relationship -- "Output X must change after or at the
// same time as output Y, but it is not permitted to change before output Y" --
// and instantiates it four times on a component's own two LINKACTIVE outputs.
// All four report under one check id, CHI_LASM_OUTPUT_RACE, because they are one
// statement about one pair of signals.
//
// That single id is what makes this test necessary. Three of the four are
// provoked elsewhere: tc_chi_lasm_illegal_transition's aborted activation
// reaches the FOURTH ("the deassertion of TXREQ must not occur before the
// assertion of RXACK") and then the FIRST as the acknowledge rises against a
// request already down, and tc_chi_lasm_race's tear-down window reaches the
// THIRD. Nothing reached the SECOND:
//
//   "The deassertion of RXACK must not occur before the deassertion of TXREQ."
//
// So the rule read as exercised in the vacuity report while a quarter of it had
// never once failed -- which is the cost of the one-id decision, and is worth
// paying only if the gap is closed rather than left implicit.
//
// cfg.lasm_ack_falls_first has the completer drop its acknowledge once while its
// own request is still asserted. That is the banned step directly: the two
// outputs are ours, the acknowledge moves first, and no peer behaviour is
// involved. It is a genuine violation rather than stimulus tuned to the check --
// the acknowledge is the answer to a request this component is still making.
//
// The rule is turned down to VIP_CHI_CHK_SEV_OFF_E rather than disabled. OFF
// still EVALUATES and still COUNTS -- it only suppresses the report.

class tc_chi_lasm_output_race_negctl extends chi_base_test;

  `uvm_component_utils(tc_chi_lasm_output_race_negctl)

  localparam item_t::addr_t ADDR_C   = item_t::addr_t'(44'h3F00_0000);
  localparam bit [2:0]      SIZE_C   = 3'd6;   // 64 B = 4 beats on the CHI-D cut
  localparam int            SETTLE_C = 20;

  // One dropped acknowledge is one banned step, at the bind whose outputs they
  // are. The requester must report NONE: 14.6.3 constrains each component's OWN
  // pair, and observing a peer's two inputs arrive out of order is expressly
  // permitted -- that is the Async Input Race, and it is a different rule.
  localparam int            RACE_REPORTS_RNI_C = 0;
  localparam int            RACE_REPORTS_SNF_C = 1;
  // The same dropped acknowledge is also an illegal LASM step, and BOTH ends see
  // it -- see the check below for why the two rules are not redundant.
  localparam int            TRANS_REPORTS_C    = 1;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // The completer breaks the ordering on its own two outputs.
  // ---------------------------------------------------------------------------
  protected virtual function void configure_agent_cfgs();

    super.configure_agent_cfgs();

    super.snf_cfg.lasm_ack_falls_first = 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    int unsigned rni_race;
    int unsigned snf_race;
    int unsigned rni_hold;
    int unsigned snf_hold;
    int unsigned rni_trans;
    int unsigned snf_trans;

    phase.raise_objection(this);

    // Suppressed at BOTH ends although only the completer is expected to report,
    // so a report at the requester is caught by its own count below rather than
    // by an $error indistinguishable from a real one.
    super.tb_env.rni_agent.vif.check_severity[VIP_CHI_CHK_LASM_OUTPUT_RACE_E] =
      VIP_CHI_CHK_SEV_OFF_E;
    super.tb_env.snf_agent.vif.check_severity[VIP_CHI_CHK_LASM_OUTPUT_RACE_E] =
      VIP_CHI_CHK_SEV_OFF_E;

    // The dropped acknowledge reaches the REQUESTER as an out-of-order input
    // pair, so its hold obligation arms. That is the observer rule and a
    // different one; it is declared here and bounded below rather than left to
    // fire as an unexplained error.
    super.tb_env.rni_agent.vif.check_severity[VIP_CHI_CHK_LASM_INPUT_RACE_HOLD_E] =
      VIP_CHI_CHK_SEV_OFF_E;
    super.tb_env.snf_agent.vif.check_severity[VIP_CHI_CHK_LASM_INPUT_RACE_HOLD_E] =
      VIP_CHI_CHK_SEV_OFF_E;

    super.tb_env.rni_agent.vif.check_severity[VIP_CHI_CHK_LASM_LEGAL_TRANSITION_E] =
      VIP_CHI_CHK_SEV_OFF_E;
    super.tb_env.snf_agent.vif.check_severity[VIP_CHI_CHK_LASM_LEGAL_TRANSITION_E] =
      VIP_CHI_CHK_SEV_OFF_E;

    // Traffic, so the link is genuinely up when the acknowledge is dropped --
    // the banned step has to happen on a running link, not during bring-up.
    super.rni0_rd_seq.reset();
    super.rni0_rd_seq.set_requests(1);
    super.rni0_rd_seq.set_initial_addr(ADDR_C);
    super.rni0_rd_seq.set_size(SIZE_C);
    super.rni0_rd_seq.set_get_response(1'b1);
    super.rni0_rd_seq.set_verbose(1'b0);
    super.rni0_rd_seq.start(super.v_sqr.rni_sequencer);

    super.wait_clocks(SETTLE_C);

    rni_race = super.tb_env.rni_agent.vif.check_fail_count[VIP_CHI_CHK_LASM_OUTPUT_RACE_E];
    snf_race = super.tb_env.snf_agent.vif.check_fail_count[VIP_CHI_CHK_LASM_OUTPUT_RACE_E];

    if ((rni_race != RACE_REPORTS_RNI_C) || (snf_race != RACE_REPORTS_SNF_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the dropped acknowledge produced %0d (RN-I) / %0d (SN-F) banned-output-race report(s), expected exactly %0d / %0d; zero at the completer means the second ordering is still unprovoked, which is the gap this test exists to close",
        super.tc_name, rni_race, snf_race, RACE_REPORTS_RNI_C, RACE_REPORTS_SNF_C))
    end

    // The rule must have PASSED as well, and here that assertion is available
    // where the input-race control could not offer it: the ordering rules
    // evaluate on every real edge of either output, so a link that came up and
    // ran has passed them many times. A rule reporting on everything would show
    // no passes at all.
    if (super.tb_env.snf_agent.vif.check_pass_count[VIP_CHI_CHK_LASM_OUTPUT_RACE_E] == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the output-race rule recorded no passes at the completer, so the one failure cannot be distinguished from a rule that fires on every edge",
        super.tc_name))
    end

    // The observer half, bounded rather than ignored. The requester sees the
    // completer's pair arrive out of order and must hold its own outputs; it
    // does, so this is zero -- and a non-zero count here would mean the hold
    // fixed in the same phase as this rule had regressed.
    rni_hold = super.tb_env.rni_agent.vif.check_fail_count[VIP_CHI_CHK_LASM_INPUT_RACE_HOLD_E];
    snf_hold = super.tb_env.snf_agent.vif.check_fail_count[VIP_CHI_CHK_LASM_INPUT_RACE_HOLD_E];

    if ((rni_hold != 0) || (snf_hold != 0)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the observer hold reported %0d (RN-I) / %0d (SN-F) violation(s) where none was expected; a component that sees a peer's outputs arrive out of order must wait for both before moving its own",
        super.tc_name, rni_hold, snf_hold))
    end

    // One banned step, THREE reports, and the decomposition is the point. The
    // acknowledge falls while the request is still up, so {1,1} -> {1,0}: that is
    // RUN -> ACTIVATE, which the one-way cycle forbids, and it is off-axis on the
    // completer's TRANSMIT machine and on the requester's RECEIVE machine -- the
    // same handshake seen from both ends.
    //
    // The two rules are NOT redundant, and this is the cleanest place in the
    // regression to see why. The transition rule says the state moved backwards;
    // the output-race rule says WHICH OF THE TWO OUTPUTS moved first, and so
    // which component is at fault. A monitor at a midpoint can see the state step
    // without being able to attribute it -- 14.6.3 says as much -- and only the
    // ordering rule answers that, which is why it reports at the completer alone
    // while the transition reports at both.
    rni_trans = super.tb_env.rni_agent.vif.check_fail_count[VIP_CHI_CHK_LASM_LEGAL_TRANSITION_E];
    snf_trans = super.tb_env.snf_agent.vif.check_fail_count[VIP_CHI_CHK_LASM_LEGAL_TRANSITION_E];

    if ((rni_trans != TRANS_REPORTS_C) || (snf_trans != TRANS_REPORTS_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the dropped acknowledge produced %0d (RN-I) / %0d (SN-F) illegal-transition report(s), expected exactly %0d at each end",
        super.tc_name, rni_trans, snf_trans, TRANS_REPORTS_C))
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] an acknowledge dropped ahead of its own request was flagged %0d time(s) at the completer and %0d at the requester, and the link carried a read to completion",
      super.tc_name, snf_race, rni_race), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
