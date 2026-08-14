// The second half of the link activation state machine.
//
// Until this test existed the VIP could only take a link down by RESET, so the
// two tear-down edges -- RUN -> DEACTIVATE and DEACTIVATE -> STOP -- were
// checked but never once walked. Everything downstream of that was untestable
// by construction: CHI_LCRD_QUIESCENT_IN_STOP only ever saw the pre-activation
// STOP where the counts are trivially zero, CHI_LINK_DEACTIVATE_WHEN_IDLE could
// not reach its own antecedent, and a deactivation timeout would have had
// nothing to time.
//
// So this is not a test of one rule. It is the stimulus three rules were waiting
// for, and it asserts what that stimulus produced:
//
//   phase 1  traffic, so the link is genuinely RUN with credits banked at both
//            ends -- a tear-down from an idle link would prove nothing about
//            draining.
//   phase 2  ask for deactivation, and require that the link reaches STOP with
//            EVERY L-credit returned. The drain is the hard part: a completer
//            that simply mirrored the withdrawn request would reach STOP two
//            cycles later with both pools still full.
//   phase 3  bring it back up and read again. A tear-down that left the link
//            unusable would be a worse outcome than never tearing it down.
//
// Phase 3 is what makes phase 2 non-trivial: it would be easy to reach STOP by
// wedging the link, and only traffic afterwards distinguishes a clean
// deactivation from a broken one.

class tc_chi_lasm_deactivate extends chi_base_test;

  `uvm_component_utils(tc_chi_lasm_deactivate)

  localparam item_t::addr_t ADDR_C   = item_t::addr_t'(44'h3D80_0000);
  localparam bit [2:0]      SIZE_C   = 3'd6;   // 64 B = 4 beats on the CHI-D cut
  localparam int            SETTLE_C = 20;
  // Generous: the drain sends one flit per banked credit on three channels, and
  // the default budgets are 8 apiece. This is a deadlock guard, not a timing
  // assertion -- the test waits on the published flag, not on this bound.
  localparam int            DEACT_TIMEOUT_C = 4000;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // Wait for the driver to publish that the link is down and drained, rather
  // than watching the sideband: the wires fall as soon as the handshake
  // completes, and the point of the exercise is the DRAIN that has to finish
  // first.
  // ---------------------------------------------------------------------------
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
  // One read, used to prove the link carries traffic before and after.
  // ---------------------------------------------------------------------------
  protected task one_read(input item_t::addr_t addr);

    super.rni0_rd_seq.reset();
    super.rni0_rd_seq.set_requests(1);
    super.rni0_rd_seq.set_initial_addr(addr);
    super.rni0_rd_seq.set_size(SIZE_C);
    super.rni0_rd_seq.set_allow_retry(1'b0);
    super.rni0_rd_seq.set_get_response(1'b1);
    super.rni0_rd_seq.set_verbose(1'b0);
    super.rni0_rd_seq.start(super.v_sqr.rni_sequencer);
  endtask

  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    int unsigned quiescent_fails_before;
    int unsigned quiescent_fails_after;
    int unsigned deactivate_idle_pass;
    int unsigned lcrdv_fails;

    phase.raise_objection(this);

    // -- Phase 1: ordinary traffic, so the tear-down has credits to drain. ----
    this.one_read(ADDR_C);
    super.wait_clocks(SETTLE_C);

    quiescent_fails_before =
      super.tb_env.rni_agent.vif.check_fail_count[VIP_CHI_CHK_LCRD_QUIESCENT_IN_STOP_E] +
      super.tb_env.snf_agent.vif.check_fail_count[VIP_CHI_CHK_LCRD_QUIESCENT_IN_STOP_E];

    // -- Phase 2: take the link down gracefully. -----------------------------
    super.rni_cfg.link_deactivate_request = 1'b1;
    this.wait_deactivate_done(1'b1);
    super.wait_clocks(SETTLE_C);

    // The credit shadow survives the link going down precisely so this can be
    // asked. If it did not, the rule would be comparing zero against zero and
    // this assertion would hold no matter how badly the drain had gone.
    quiescent_fails_after =
      super.tb_env.rni_agent.vif.check_fail_count[VIP_CHI_CHK_LCRD_QUIESCENT_IN_STOP_E] +
      super.tb_env.snf_agent.vif.check_fail_count[VIP_CHI_CHK_LCRD_QUIESCENT_IN_STOP_E];

    if (quiescent_fails_after != quiescent_fails_before) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the link reached STOP with L-credits still outstanding (%0d new report(s)); the deactivation drain did not return them",
        super.tc_name, quiescent_fails_after - quiescent_fails_before))
    end

    // No credit may be ADVERTISED once the link is down either. This is the
    // other half of quiescence and a different bug: a receiver that kept
    // granting into STOP would refill the pool the drain had just emptied.
    lcrdv_fails =
      super.tb_env.rni_agent.vif.check_fail_count[VIP_CHI_CHK_RSP_LCRDV_REQUIRES_LINK_E] +
      super.tb_env.rni_agent.vif.check_fail_count[VIP_CHI_CHK_DAT_LCRDV_REQUIRES_LINK_E] +
      super.tb_env.snf_agent.vif.check_fail_count[VIP_CHI_CHK_REQ_LCRDV_REQUIRES_LINK_E];

    if (lcrdv_fails != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %0d L-credit grant(s) went out with the link down",
        super.tc_name, lcrdv_fails))
    end

    // The rule that could not previously reach its own antecedent. It is not
    // asked to FAIL here -- the tear-down is a clean one -- but it must have
    // been EVALUATED, or the deactivation walked past it without being judged
    // and this whole exercise proved nothing about it.
    deactivate_idle_pass =
      super.tb_env.rni_agent.vif.check_pass_count[VIP_CHI_CHK_LINK_DEACTIVATE_WHEN_IDLE_E];

    if (deactivate_idle_pass == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s recorded no evaluations across a full deactivation - it is still vacuous",
        super.tc_name, vip_chi_check_name(VIP_CHI_CHK_LINK_DEACTIVATE_WHEN_IDLE_E)))
    end

    // -- Phase 3: bring it back and prove it still works. --------------------
    super.rni_cfg.link_deactivate_request = 1'b0;
    this.wait_deactivate_done(1'b0);
    super.wait_clocks(SETTLE_C);

    this.one_read(ADDR_C + 64);
    super.wait_clocks(SETTLE_C);

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] link ran, deactivated to STOP with every L-credit returned, reactivated and carried traffic again; %s evaluated %0d time(s)",
      super.tc_name, vip_chi_check_name(VIP_CHI_CHK_LINK_DEACTIVATE_WHEN_IDLE_E),
      deactivate_idle_pass), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
