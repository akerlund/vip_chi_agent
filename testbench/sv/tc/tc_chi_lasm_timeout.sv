// Negative control for the two link-activation timeouts.
//
// A link stuck in ACTIVATE or DEACTIVATE is the one failure here that no other
// rule can see, because every cycle of it is legal: holding is always a legal
// LASM step, no flit goes out to violate a channel rule, and the
// transaction-completion timeout has nothing in flight to measure. A link stuck
// coming up has not yet carried a transaction; a link stuck going down has
// already retired them all. The run simply hangs, and hangs without naming
// anything -- which is exactly the kind of failure a checker is for.
//
// Both halves are provoked from the COMPLETER, because a stuck link is an
// acknowledge that does not arrive and only the completer drives one:
//
//   phase 1  cfg.lasm_stall_activation_cycles withholds the acknowledge to the
//            bring-up request. The link sits in ACTIVATE past the bound.
//   phase 2  cfg.lasm_stall_deactivation_cycles withholds the DROP of the
//            acknowledge after the drain has finished. The link sits in
//            DEACTIVATE past the bound.
//
// Both are genuine violations rather than stimulus tuned to the check: a
// requester that has asked for the link is entitled to an answer, and a receiver
// that has had every credit returned has nothing left to wait for.
//
// The stalls are deliberately FINITE. A control that wedged the link forever
// would prove the check fires and then hang the test, so each stall clears well
// after the bound and the run continues -- which also demonstrates the reported
// link recovers, and that the timeout reports ONCE rather than once per cycle.
//
// Both rules are turned down to VIP_CHI_CHK_SEV_OFF_E rather than disabled. OFF
// still EVALUATES and still COUNTS -- it only suppresses the report -- which is
// what a negative control needs. Disabling would stop the counting too, leaving
// nothing to assert on.

class tc_chi_lasm_timeout extends chi_base_test;

  `uvm_component_utils(tc_chi_lasm_timeout)

  localparam item_t::addr_t ADDR_C   = item_t::addr_t'(44'h3DC0_0000);
  localparam bit [2:0]      SIZE_C   = 3'd6;   // 64 B = 4 beats on the CHI-D cut
  localparam int            SETTLE_C = 20;

  // The bound the checkers enforce, and the stall that must overrun it. Kept
  // well apart so the test is not sensitive to a cycle either way in the
  // handshake, and so the stall clearing is unambiguously after the report.
  localparam int TIMEOUT_C = 16;
  localparam int STALL_C   = 64;

  localparam int DEACT_TIMEOUT_C = 4000;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // Arm both bounds on every bind.
  // ---------------------------------------------------------------------------
  protected virtual function void configure_tb_cfg();

    super.configure_tb_cfg();

    super.tb_cfg.link_activation_timeout_cycles   = TIMEOUT_C;
    super.tb_cfg.link_deactivation_timeout_cycles = TIMEOUT_C;
  endfunction

  // ---------------------------------------------------------------------------
  // Stall both handshakes on the completer that owns the acknowledge.
  // ---------------------------------------------------------------------------
  protected virtual function void configure_agent_cfgs();

    super.configure_agent_cfgs();

    super.snf_cfg.lasm_stall_activation_cycles   = STALL_C;
    super.snf_cfg.lasm_stall_deactivation_cycles = STALL_C;
  endfunction

  // ---------------------------------------------------------------------------
  // Sum a rule's failures across both binds. Both ends observe the same
  // handshake, so a stuck link must be reported by both -- one end reporting
  // alone would mean the state is derived from something polarity-specific
  // rather than from the link.
  // ---------------------------------------------------------------------------
  protected function int unsigned fails(input vip_chi_check_id_t id);

    return super.tb_env.rni_agent.vif.check_fail_count[id] +
           super.tb_env.snf_agent.vif.check_fail_count[id];
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

  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    int unsigned act_rni;
    int unsigned act_snf;
    int unsigned deact_fails;

    phase.raise_objection(this);

    super.tb_env.rni_agent.vif.check_severity[VIP_CHI_CHK_LASM_ACTIVATION_TIMEOUT_E] =
      VIP_CHI_CHK_SEV_OFF_E;
    super.tb_env.snf_agent.vif.check_severity[VIP_CHI_CHK_LASM_ACTIVATION_TIMEOUT_E] =
      VIP_CHI_CHK_SEV_OFF_E;
    super.tb_env.rni_agent.vif.check_severity[VIP_CHI_CHK_LASM_DEACTIVATION_TIMEOUT_E] =
      VIP_CHI_CHK_SEV_OFF_E;
    super.tb_env.snf_agent.vif.check_severity[VIP_CHI_CHK_LASM_DEACTIVATION_TIMEOUT_E] =
      VIP_CHI_CHK_SEV_OFF_E;

    // -- Phase 1: the stalled bring-up. --------------------------------------
    //
    // The stall is already counting down from time 0, so by the time this
    // sequence completes the link has been through a long ACTIVATE, reported it,
    // recovered, and carried the traffic. Requiring the traffic to complete is
    // what proves the stall was survivable rather than fatal.
    super.rni0_rd_seq.reset();
    super.rni0_rd_seq.set_requests(1);
    super.rni0_rd_seq.set_initial_addr(ADDR_C);
    super.rni0_rd_seq.set_size(SIZE_C);
    super.rni0_rd_seq.set_get_response(1'b1);
    super.rni0_rd_seq.set_verbose(1'b0);
    super.rni0_rd_seq.start(super.v_sqr.rni_sequencer);

    super.wait_clocks(SETTLE_C);

    act_rni = super.tb_env.rni_agent.vif.check_fail_count[VIP_CHI_CHK_LASM_ACTIVATION_TIMEOUT_E];
    act_snf = super.tb_env.snf_agent.vif.check_fail_count[VIP_CHI_CHK_LASM_ACTIVATION_TIMEOUT_E];

    if ((act_rni == 0) || (act_snf == 0)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] a bring-up held %0d cycles against a %0d-cycle bound reported %0d (RN-I) / %0d (SN-F) time(s); the activation timeout is not firing",
        super.tc_name, STALL_C, TIMEOUT_C, act_rni, act_snf))
    end

    // One stuck episode, one report per bind. Reporting per cycle would bury the
    // one useful line under STALL_C - TIMEOUT_C copies of itself.
    if ((act_rni > 1) || (act_snf > 1)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] one stalled bring-up produced %0d (RN-I) / %0d (SN-F) reports; the timeout is firing per cycle rather than on the crossing",
        super.tc_name, act_rni, act_snf))
    end

    // -- Phase 2: the stalled tear-down. -------------------------------------
    super.rni_cfg.link_deactivate_request = 1'b1;
    this.wait_deactivate_done(1'b1);
    super.wait_clocks(SETTLE_C);

    deact_fails = this.fails(VIP_CHI_CHK_LASM_DEACTIVATION_TIMEOUT_E);

    if (deact_fails < 2) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] a tear-down held %0d cycles against a %0d-cycle bound reported %0d time(s) across both binds; the deactivation timeout is not firing",
        super.tc_name, STALL_C, TIMEOUT_C, deact_fails))
    end

    if (deact_fails > 2) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] one stalled tear-down produced %0d reports across two binds; the timeout is firing per cycle rather than on the crossing",
        super.tc_name, deact_fails))
    end

    // The link must still come back: a reported timeout is a diagnostic, not a
    // wedge, and a control that left the link dead could not tell the two apart.
    super.rni_cfg.link_deactivate_request = 1'b0;
    this.wait_deactivate_done(1'b0);
    super.wait_clocks(SETTLE_C);

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] a %0d-cycle stall against a %0d-cycle bound reported the stuck ACTIVATE %0d (RN-I) / %0d (SN-F) time(s) and the stuck DEACTIVATE %0d time(s) across both binds; the link recovered from each",
      super.tc_name, STALL_C, TIMEOUT_C, act_rni, act_snf, deact_fails), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
