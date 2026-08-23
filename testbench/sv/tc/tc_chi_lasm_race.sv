// The link activation state machine under a RACE rather than a malformed
// sequence.
//
// tc_chi_lasm_illegal_transition breaks the BRING-UP half: a request withdrawn
// before the acknowledge. This breaks the TEAR-DOWN half, and it could not exist
// until graceful deactivation did -- there was no tear-down to race with.
//
// cfg.lasm_reactivate_during_deactivate makes the requester change its mind half
// way through: the link is in DEACTIVATE (request low, acknowledge still high,
// completer still returning credits) and the requester raises its request again.
// The pair {1,1} is RUN, so the link jumps DEACTIVATE -> RUN, which the cycle
// does not allow -- DEACTIVATE may only advance to STOP.
//
// It is a genuine violation rather than stimulus tuned to the check: a requester
// that has withdrawn its request has committed to the tear-down. What makes it a
// RACE rather than simply a wrong sequence is WHEN it lands -- inside the window
// where the completer has not yet decided to drop its acknowledge, which no
// amount of shifting a uniform delay could reach.
//
// Both halves are asserted:
//   * the illegal step must be reported, on both binds -- one end reporting
//     alone would mean the state is derived from something polarity-specific;
//   * the link must still come back and carry traffic, because a race that left
//     the link dead would be indistinguishable from a wedge.
//
// The rule is turned down to VIP_CHI_CHK_SEV_OFF_E rather than disabled: OFF
// still evaluates and still counts, which is what a negative control needs.

class tc_chi_lasm_race extends chi_base_test;

  `uvm_component_utils(tc_chi_lasm_race)

  localparam item_t::addr_t ADDR_C   = item_t::addr_t'(44'h3E80_0000);
  localparam bit [2:0]      SIZE_C   = 3'd6;   // 64 B = 4 beats on the CHI-D cut
  localparam int            SETTLE_C = 20;
  localparam int            DEACT_TIMEOUT_C = 4000;
  // The same re-request is a Banned Output Race, and only at the requester --
  // see the check below for why the two ends differ.
  localparam int            RACE_REPORTS_RNI_C = 1;
  localparam int            RACE_REPORTS_SNF_C = 0;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // Race the tear-down on the requester that owns the activation request.
  // ---------------------------------------------------------------------------
  protected virtual function void configure_agent_cfgs();

    super.configure_agent_cfgs();

    super.rni_cfg.lasm_reactivate_during_deactivate = 1'b1;
  endfunction

  protected task wait_deactivate_done(input bit want);

    int waited;

    waited = 0;
    while (super.rni_cfg.link_deactivate_done != want) begin
      super.wait_clocks(1);
      waited++;
      if (waited > DEACT_TIMEOUT_C) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] link_deactivate_done never reached %0b within %0d cycles - the link is stuck",
          super.tc_name, want, DEACT_TIMEOUT_C))
      end
    end
  endtask

  protected task one_read(input item_t::addr_t addr);

    super.rni0_rd_seq.reset();
    super.rni0_rd_seq.set_requests(1);
    super.rni0_rd_seq.set_initial_addr(addr);
    super.rni0_rd_seq.set_size(SIZE_C);
    super.rni0_rd_seq.set_get_response(1'b1);
    super.rni0_rd_seq.set_verbose(1'b0);
    super.rni0_rd_seq.start(super.v_sqr.rni_sequencer);
  endtask

  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    int unsigned rni_fails;
    int unsigned snf_fails;
    int unsigned rni_race;
    int unsigned snf_race;

    phase.raise_objection(this);

    super.tb_env.rni_agent.vif.check_severity[VIP_CHI_CHK_LASM_LEGAL_TRANSITION_E] =
      VIP_CHI_CHK_SEV_OFF_E;
    super.tb_env.snf_agent.vif.check_severity[VIP_CHI_CHK_LASM_LEGAL_TRANSITION_E] =
      VIP_CHI_CHK_SEV_OFF_E;
    // Suppressed at BOTH ends although only the requester is expected to report
    // it, so an unexpected report at the completer is caught by its own count
    // below rather than by an $error that reads like a real one.
    super.tb_env.rni_agent.vif.check_severity[VIP_CHI_CHK_LASM_OUTPUT_RACE_E] =
      VIP_CHI_CHK_SEV_OFF_E;
    super.tb_env.snf_agent.vif.check_severity[VIP_CHI_CHK_LASM_OUTPUT_RACE_E] =
      VIP_CHI_CHK_SEV_OFF_E;

    // Traffic first, so the tear-down has something real to tear down.
    this.one_read(ADDR_C);
    super.wait_clocks(SETTLE_C);

    // Deactivate. The driver races its own tear-down on the way through.
    super.rni_cfg.link_deactivate_request = 1'b1;
    this.wait_deactivate_done(1'b1);
    super.wait_clocks(SETTLE_C);

    rni_fails = super.tb_env.rni_agent.vif.check_fail_count[VIP_CHI_CHK_LASM_LEGAL_TRANSITION_E];
    snf_fails = super.tb_env.snf_agent.vif.check_fail_count[VIP_CHI_CHK_LASM_LEGAL_TRANSITION_E];

    if ((rni_fails == 0) || (snf_fails == 0)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] a request raised inside the tear-down window produced %0d (RN-I) / %0d (SN-F) illegal-transition report(s); the rule does not see the race",
        super.tc_name, rni_fails, snf_fails))
    end

    // The re-request is a Banned Output Race as well as an illegal step, and
    // 14.6.3's THIRD ordering is the one it breaks: "the assertion of TXREQ must
    // not occur before the deassertion of RXACK". The requester raises its
    // request while it is still acknowledging the peer's, which is exactly the
    // tear-down window this test aims at -- so the two rules catch one act from
    // two directions, one as a state step and one as an output ordering.
    //
    // Only the requester reports it. 14.6.3 constrains each component's OWN two
    // outputs, and the completer never changes its mind mid-tear-down, so its
    // pair stays ordered throughout.
    rni_race = super.tb_env.rni_agent.vif.check_fail_count[VIP_CHI_CHK_LASM_OUTPUT_RACE_E];
    snf_race = super.tb_env.snf_agent.vif.check_fail_count[VIP_CHI_CHK_LASM_OUTPUT_RACE_E];

    if ((rni_race != RACE_REPORTS_RNI_C) || (snf_race != RACE_REPORTS_SNF_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the tear-down-window re-request produced %0d (RN-I) / %0d (SN-F) banned-output-race report(s), expected exactly %0d / %0d",
        super.tc_name, rni_race, snf_race, RACE_REPORTS_RNI_C, RACE_REPORTS_SNF_C))
    end

    // Bring it back and prove the link survived the race.
    super.rni_cfg.link_deactivate_request = 1'b0;
    this.wait_deactivate_done(1'b0);
    super.wait_clocks(SETTLE_C);

    this.one_read(ADDR_C + 64);
    super.wait_clocks(SETTLE_C);

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] a request raised inside the tear-down window was flagged %0d (RN-I) / %0d (SN-F) time(s), and the link recovered and carried traffic again",
      super.tc_name, rni_fails, snf_fails), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
