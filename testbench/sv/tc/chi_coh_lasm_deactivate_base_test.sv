// ===========================================================================
// chi_coh_lasm_deactivate_base_test
//
// Graceful deactivation on the COHERENT link.
//
// The RN-I to SN-F link has been able to reach STOP without a reset since
// tc_chi_lasm_deactivate; the RN-F to HN-F link could not, and three separate
// things stood in the way. None of them was visible from the requester, because
// the requester's half of the tear-down was already written:
//
//   * the home's REQ ingress had no arm for ReqLCrdReturn, so the drain's first
//     returned credit reached the opcode dispatch and stopped the simulation
//     with "unsupported REQ opcode 0x0";
//   * the home had no per-port tear-down state, so it kept advertising credits
//     into a link that was coming down and dropped its acknowledge two cycles
//     after the request fell, whatever it still held; and
//   * the requester's SNP credit loop had no stand-down, so it kept granting
//     snoop credits straight through the tear-down.
//
// The fourth channel is what makes this link different from the one that
// already worked. SNP runs home to requester, so the home holds the send
// credits and the requester grants them -- and CHI_LCRD_QUIESCENT_IN_STOP
// cannot see any of it, because the SNP rules live in their own module so a
// non-coherent link elaborates none of them. The tear-down would have been
// judged on three channels of four, and the missing one is the channel only
// this link has. Hence CHI_SNP_LCRD_QUIESCENT_IN_STOP, and hence the
// pre-tear-down reading below that proves the home really held snoop credits to
// strand.
//
//   phase 1  coherent traffic that SNOOPS: port 1 reads a line port 0 holds
//            Unique, so the home has sent snoops on port 0 and spent credits
//            from all four pools. A tear-down from an idle link proves nothing
//            about draining.
//   phase 2  take port 0 down, and require STOP with every credit returned on
//            all four channels -- while port 1 stays up, because a home that
//            could only tear down by taking every port with it would pass a
//            single-port test and fail the first real one.
//   phase 3  bring port 0 back and snoop again. A tear-down that left the link
//            unusable would be a worse outcome than never tearing it down, and
//            re-granting the initial budget on the way back up is the half that
//            has no analogue in the requester's own path.
//
// Used by:
//   tc_chi_coh_d_lasm_deactivate   (CHI-D)
//   tc_chi_coh_e_lasm_deactivate   (wide CHI-E)
// ===========================================================================
class chi_coh_lasm_deactivate_base_test #(
  vip_chi_cfg_t CFG_P   = CHI_D_CFG_C,
  type          TYPES_T = chi_d_types_t
) extends chi_coherent_base_test #(CFG_P, TYPES_T);

  typedef vip_chi_item #(CFG_P) item_t;

  `uvm_component_param_utils(chi_coh_lasm_deactivate_base_test #(CFG_P, TYPES_T))

  // A plain integral localparam, cast where it is used: a class-scope localparam
  // typed through item_t:: is not something this tree declares.
  localparam longint unsigned LINE_C   = 64'h4A00_0000;
  localparam int              SETTLE_C = 24;
  // Generous: the drain sends one flit per banked credit on three channels at
  // each end, and the default budgets are 8 apiece. A deadlock guard, not a
  // timing assertion -- the test waits on the driver's published flag, not on
  // this bound.
  localparam int              DEACT_TIMEOUT_C = 6000;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // -- the two ends of the link under test ------------------------------------
  // Read from BOTH, always. The requester and the home each see one half of
  // quiescence -- what it holds, and what it granted that the peer still holds
  // -- and a rule read at one end only cannot distinguish a clean tear-down
  // from one where the other end stranded everything. On this port both binds
  // and both SNP binds write into their own interface's tally array, so the sum
  // is over the two interfaces rather than over four objects.
  protected function int fails(input vip_chi_check_id_t id);
    return this.tb_env.hrnf0_agent.vif.check_fail_count[id] +
           this.tb_env.hnf_agent.rn_vif[0].check_fail_count[id];
  endfunction

  protected function int passes(input vip_chi_check_id_t id);
    return this.tb_env.hrnf0_agent.vif.check_pass_count[id] +
           this.tb_env.hnf_agent.rn_vif[0].check_pass_count[id];
  endfunction

  // Wait on the driver's published flag, not on the sideband wires: the wires
  // fall as soon as the handshake completes, and the point of the exercise is
  // the DRAIN that has to finish first -- which on this link runs at both ends
  // at once.
  protected task wait_deactivate_done(input bit want);

    int waited;

    waited = 0;
    while (this.hrnf0_cfg.link_deactivate_done != want) begin
      this.wait_clocks(1);
      waited++;
      if (waited > DEACT_TIMEOUT_C) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] link_deactivate_done never reached %0d within %0d cycles -- the coherent link is stuck mid-tear-down",
          get_name(), want, DEACT_TIMEOUT_C))
      end
    end

  endtask

  // Port 0 takes the line Unique, then port 1 reads it: the home must snoop.
  // The snoop is the point -- it is what puts the home's SNP send pool to work,
  // so the credits the tear-down has to hand back on that channel are real
  // rather than the untouched initial budget.
  protected task snooping_traffic();
    this.cfg_read_seq(this.hrnf0_rdunique_seq, item_t::addr_t'(LINE_C));
    this.hrnf0_rdunique_seq.start(this.tb_env.hrnf0_agent.sequencer);
    this.cfg_read_seq(this.hrnf1_rdshared_seq, item_t::addr_t'(LINE_C));
    this.hrnf1_rdshared_seq.start(this.tb_env.hrnf1_agent.sequencer);
  endtask

  task run_phase(input uvm_phase phase);

    item_t       snp_item;
    int unsigned snp_held_before;
    int unsigned snp_granted_before;
    int          quiescent_before;
    int          quiescent_after;
    int          snp_quiescent_before;
    int          snp_quiescent_after;
    int          snp_quiescent_pass;
    int          snp_link_before;
    int          snp_link_after;
    int          lcrdv_fails;
    int          idle_pass;
    int          snooped;

    phase.raise_objection(this);

    super.wait_reset_settle();

    // -- Phase 1: traffic, so the tear-down has credits to drain. ------------
    this.snooping_traffic();
    this.wait_clocks(SETTLE_C);

    snp_held_before    = this.tb_env.hnf_agent.hnf_driver.snp_credits_held(0);
    snp_granted_before = this.tb_env.hrnf0_agent.rnf_driver.snp_credits_granted();

    // Non-vacuity, and the reason it is asserted rather than assumed: every
    // assertion after this one is satisfied by a link that never put a snoop
    // credit anywhere. If the home holds none and the requester granted none,
    // the SNP half of the tear-down has nothing to do and its clean result
    // means nothing.
    if (snp_held_before == 0) begin
      `uvm_error(get_name(), $sformatf(
        "ERROR [%s] the home holds no SNP send credits before the tear-down, so the snoop channel has nothing to drain and every SNP assertion below is vacuous",
        get_name()))
    end
    if (snp_granted_before == 0) begin
      `uvm_error(get_name(), $sformatf(
        "ERROR [%s] the requester has granted no SNP credits before the tear-down, so its own wait for their return cannot distinguish a drain from a no-op",
        get_name()))
    end

    quiescent_before     = this.fails(VIP_CHI_CHK_LCRD_QUIESCENT_IN_STOP_E);
    snp_quiescent_before = this.fails(VIP_CHI_CHK_SNP_LCRD_QUIESCENT_IN_STOP_E);
    snp_link_before      = this.fails(VIP_CHI_CHK_SNP_FLITV_REQUIRES_LINK_E);

    // -- Phase 2: take port 0 down gracefully, port 1 untouched. -------------
    this.hrnf0_cfg.link_deactivate_request = 1'b1;
    this.wait_deactivate_done(1'b1);
    this.wait_clocks(SETTLE_C);

    // The credit shadows survive the link going down precisely so these can be
    // asked. If they did not, the rules would be comparing zero against zero
    // and both checks would hold no matter how badly the drain had gone.
    quiescent_after = this.fails(VIP_CHI_CHK_LCRD_QUIESCENT_IN_STOP_E);
    if (quiescent_after != quiescent_before) begin
      `uvm_error(get_name(), $sformatf(
        "ERROR [%s] the coherent link reached STOP with REQ/RSP/DAT L-credits still outstanding (%0d new report(s)); the deactivation drain did not return them",
        get_name(), quiescent_after - quiescent_before))
    end

    snp_quiescent_after = this.fails(VIP_CHI_CHK_SNP_LCRD_QUIESCENT_IN_STOP_E);
    if (snp_quiescent_after != snp_quiescent_before) begin
      `uvm_error(get_name(), $sformatf(
        "ERROR [%s] the coherent link reached STOP with SNOOP L-credits still outstanding (%0d new report(s)); the home holds the send credits on this channel and nothing else can hand them back",
        get_name(), snp_quiescent_after - snp_quiescent_before))
    end

    // EVALUATED, not merely un-failed. The SNP rule is new and the tear-down it
    // judges is the only thing that reaches it, so a zero fail count with a
    // zero pass count would mean the rule never ran -- which is what the three
    // channels it joins looked like before a coherent link could deactivate at
    // all.
    snp_quiescent_pass = this.passes(VIP_CHI_CHK_SNP_LCRD_QUIESCENT_IN_STOP_E);
    if (snp_quiescent_pass == 0) begin
      `uvm_error(get_name(), $sformatf(
        "ERROR [%s] CHI_SNP_LCRD_QUIESCENT_IN_STOP recorded no evaluations across a full coherent deactivation -- it is still vacuous",
        get_name()))
    end

    // Both drains are finished at the drivers' own accounting, which is the
    // half the wire cannot show: a pool emptied by dropping credits on the
    // floor and one emptied by returning them look identical from STOP.
    if (this.tb_env.hnf_agent.hnf_driver.snp_credits_held(0) != 0) begin
      `uvm_error(get_name(), $sformatf(
        "ERROR [%s] the home still holds %0d SNP send credit(s) after the tear-down completed",
        get_name(), this.tb_env.hnf_agent.hnf_driver.snp_credits_held(0)))
    end
    if (this.tb_env.hrnf0_agent.rnf_driver.snp_credits_granted() != 0) begin
      `uvm_error(get_name(), $sformatf(
        "ERROR [%s] the requester still counts %0d SNP credit(s) as granted after the tear-down completed",
        get_name(), this.tb_env.hrnf0_agent.rnf_driver.snp_credits_granted()))
    end

    // A snoop credit return is a flit sent in DEACTIVATE, which is legal for an
    // L-credit return and for nothing else. The rule admitting it is the narrow
    // exception, so it has to be checked that the exception did not swallow the
    // rule.
    snp_link_after = this.fails(VIP_CHI_CHK_SNP_FLITV_REQUIRES_LINK_E);
    if (snp_link_after != snp_link_before) begin
      `uvm_error(get_name(), $sformatf(
        "ERROR [%s] %0d snoop flit(s) went out with the transmit link out of RUN and not as an L-credit return",
        get_name(), snp_link_after - snp_link_before))
    end

    // No credit may be ADVERTISED once the link is down either. The other half
    // of quiescence and a different bug: a receiver that kept granting into
    // STOP would refill the pool the drain had just emptied. SNP is in this
    // list for the first time -- it is the channel whose grant loop had no
    // stand-down.
    lcrdv_fails = this.fails(VIP_CHI_CHK_REQ_LCRDV_REQUIRES_LINK_E) +
                  this.fails(VIP_CHI_CHK_RSP_LCRDV_REQUIRES_LINK_E) +
                  this.fails(VIP_CHI_CHK_DAT_LCRDV_REQUIRES_LINK_E) +
                  this.fails(VIP_CHI_CHK_SNP_LCRDV_REQUIRES_LINK_E);
    if (lcrdv_fails != 0) begin
      `uvm_error(get_name(), $sformatf(
        "ERROR [%s] %0d L-credit grant(s) went out with the link down",
        get_name(), lcrdv_fails))
    end

    // The rule that could not previously reach its own antecedent on this link.
    // Not asked to FAIL -- the tear-down is a clean one -- but it must have
    // been EVALUATED, or the deactivation walked past it unjudged.
    idle_pass = this.passes(VIP_CHI_CHK_LINK_DEACTIVATE_WHEN_IDLE_E);
    if (idle_pass == 0) begin
      `uvm_error(get_name(), $sformatf(
        "ERROR [%s] CHI_LINK_DEACTIVATE_WHEN_IDLE recorded no evaluations across a full coherent deactivation -- it is still vacuous",
        get_name()))
    end

    // Port 1 was never asked to go down. A home that tore down every port at
    // once would pass everything above.
    if (this.tb_env.hnf_agent.hnf_driver.link_deactivating_on(1)) begin
      `uvm_error(get_name(), $sformatf(
        "ERROR [%s] taking port 0 down also put port 1 into tear-down: the home's deactivation state is not per port",
        get_name()))
    end

    // -- Phase 3: bring it back and prove it still snoops. -------------------
    this.hrnf0_cfg.link_deactivate_request = 1'b0;
    this.wait_deactivate_done(1'b0);
    this.wait_clocks(SETTLE_C);

    while (this.tb_env.hrnf0_snp_fifo.try_get(snp_item)) begin
      // Drop the snoops from before the tear-down: the count below is evidence
      // about the link that came back.
    end

    this.snooping_traffic();
    this.wait_clocks(SETTLE_C);

    // A snoop after the bring-up is what proves the SNP channel came back: the
    // home can only send one under a credit the requester re-granted, and the
    // re-grant is the step the requester's own tear-down path has no analogue
    // for. Counted off the monitored channel rather than from the driver, so a
    // re-granted credit that never carried a snoop does not count.
    snooped = 0;
    while (this.tb_env.hrnf0_snp_fifo.try_get(snp_item)) begin
      snooped++;
    end
    if (snooped == 0) begin
      `uvm_error(get_name(), $sformatf(
        "ERROR [%s] no snoop reached port 0 after reactivation: the SNP receive budget was never re-advertised, so the channel came back dead",
        get_name()))
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] PASS: coherent link ran with snoops, deactivated port 0 to STOP with all four channels' L-credits returned (%0d snoop credit(s) drained by the home, %0d tracked by the requester), reactivated and snooped again (%0d snoop(s)); CHI_SNP_LCRD_QUIESCENT_IN_STOP evaluated %0d time(s), CHI_LINK_DEACTIVATE_WHEN_IDLE %0d time(s)",
      get_name(), snp_held_before, snp_granted_before, snooped,
      snp_quiescent_pass, idle_pass), UVM_LOW)

    phase.drop_objection(this);

  endtask
endclass
