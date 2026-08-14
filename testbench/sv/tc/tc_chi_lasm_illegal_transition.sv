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

    phase.raise_objection(this);

    // Suppress the report, keep the count. Done here rather than through a
    // dedicated port: any test can address any check this way, which is what
    // replaced the one-off suppression the first cut of this test needed.
    super.tb_env.rni_agent.vif.check_severity[VIP_CHI_CHK_LASM_LEGAL_TRANSITION_E] =
      VIP_CHI_CHK_SEV_OFF_E;
    super.tb_env.snf_agent.vif.check_severity[VIP_CHI_CHK_LASM_LEGAL_TRANSITION_E] =
      VIP_CHI_CHK_SEV_OFF_E;

    // Ordinary traffic after the aborted bring-up: the link must have come up
    // properly on the second attempt, or this would hang rather than pass.
    super.rni0_rd_seq.reset();
    super.rni0_rd_seq.set_requests(1);
    super.rni0_rd_seq.set_initial_addr(ADDR_C);
    super.rni0_rd_seq.set_size(SIZE_C);
    super.rni0_rd_seq.set_allow_retry(1'b0);
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

    // Exactly one aborted bring-up, so the run must not be littered with them:
    // a check that fired on the legal activation that followed would count more.
    if ((rni_fails > 2) || (snf_fails > 2)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] one aborted activation produced %0d (RN-I) / %0d (SN-F) counts; the legal bring-up that followed is being flagged too",
        super.tc_name, rni_fails, snf_fails))
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] aborted activation flagged %0d (RN-I) / %0d (SN-F) time(s), the bring-up that followed was not, and one read completed over the recovered link",
      super.tc_name, rni_fails, snf_fails), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
