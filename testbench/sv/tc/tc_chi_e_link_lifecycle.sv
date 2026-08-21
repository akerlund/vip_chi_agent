// The whole life of a CHI-E link: up, reset, up again, torn down, up again.
//
// This exists because of a measurement, not a hunch. The per-bind vacuity split
// showed six link-layer rules alive on the CHI-D link and dead on both CHI-E
// binds -- the four "channel idle in reset" rules, the activation restart, and
// the tear-down idle rule. Not one of the fourteen CHI-E testcases touched reset
// or link state, so the six had never been evaluated on a CHI-E link at all.
//
// That gap is not covered by the CHI-D equivalents. The link layer is not
// issue-invariant: CHI-E widens NodeID and Address, moves the flit layout, and
// the reset rules judge the FLITPEND / FLITV / LCRDV wires of channels whose
// widths changed underneath them. A rule that holds on a 44-bit address and a
// 16-byte data bus is not thereby known to hold on 52 bits and 64.
//
// The three phases in order, each one a prerequisite for the next:
//
//   phase 1  traffic, so link_ever_active latches and the reset rules arm. They
//            are deliberately gated on it -- an interface whose agent was never
//            built must not be judged -- so a reset before any traffic would
//            walk past all six without evaluating one.
//   phase 2  reset in the middle of the run. The four channel rules and the
//            sideband rule apply while rst_n is low; the restart rule applies
//            when it is released.
//   phase 3  a graceful deactivation to STOP and back. This is the only way to
//            reach LINK_DEACTIVATE_WHEN_IDLE's antecedent: reset takes the link
//            down without ever entering DEACTIVATE.
//
// The test then requires that each of the six recorded an evaluation on BOTH
// CHI-E binds. That check is the point of the testcase. A run that drives the
// stimulus but leaves a rule unevaluated has proved nothing about it, and a
// green verdict would say otherwise.

class tc_chi_e_link_lifecycle extends chi_e_base_test;

  typedef vip_chi_item #(CHI_E_WIDE_CFG_C) item_t;

  `uvm_component_utils(tc_chi_e_link_lifecycle)

  // No class-scope localparams here, deliberately, and the address in particular
  // is a run-time local rather than a folded constant.
  //
  // A `localparam` whose type is reached through a parameterised class -- it was
  // `localparam item_t::addr_t ADDR_C = item_t::addr_t'(...)`, where item_t is
  // vip_chi_item #(CHI_E_WIDE_CFG_C) -- makes VCS resolve that specialisation to
  // fold the constant, and elaboration of this testbench stops finishing.
  // Measured by bisection against a 13.4 s baseline: every sv/ change together
  // elaborates in 13.7 s, and sv/ plus this one file was at 39 s and still
  // climbing when it was killed. It never errors, so it reads as a slow build.
  //
  // The plain integer constants below would almost certainly be harmless, but
  // they are locals too: one rule to follow beats a rule with an exception.
  static const bit [2:0] SIZE_C   = 3'd6;
  static const int       SETTLE_C = 20;
  // Deadlock guard, not a timing budget: the drain sends one flit per banked
  // L-credit on three channels. The test waits on the published flag.
  static const int       DEACT_TIMEOUT_C = 4000;


  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // One write, used to prove the link carries traffic in each phase and to arm
  // the reset rules by latching link_ever_active.
  // ---------------------------------------------------------------------------
  protected task one_write(input item_t::addr_t addr);

    super.rni_wr_seq.reset();
    super.rni_wr_seq.set_requests(1);
    super.rni_wr_seq.set_initial_addr(addr);
    super.rni_wr_seq.set_size(SIZE_C);
    super.rni_wr_seq.set_get_response(1'b1);
    super.rni_wr_seq.set_verbose(1'b0);
    super.rni_wr_seq.start(super.tb_env.rni_agent.sequencer);
  endtask

  // ---------------------------------------------------------------------------
  // Wait for the driver to publish that the link is down and drained. The
  // sideband wires fall as soon as the handshake completes; the drain that has
  // to finish first is the part worth waiting for.
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
  // One rule had to be judged at BOTH ends of the CHI-E link. A run that drove
  // the stimulus and left a rule unevaluated has proved nothing about it, and a
  // green verdict would say otherwise.
  // ---------------------------------------------------------------------------
  protected function void require_evaluated(input vip_chi_check_id_t id);

    int unsigned rni_pass;
    int unsigned snf_pass;

    rni_pass = super.tb_env.rni_agent.vif.check_pass_count[id];
    snf_pass = super.tb_env.snf_agent.vif.check_pass_count[id];

    if ((rni_pass == 0) || (snf_pass == 0)) begin
      `uvm_error(get_name(), $sformatf(
        "ERROR [%s] %s is still vacuous on the CHI-E link: rni_e=%0d snf_e=%0d evaluation(s)",
        super.tc_name, vip_chi_check_name(id), rni_pass, snf_pass))
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t::addr_t base_addr;
    bit            saw_sideband_idle;
    bit            saw_reactivation;

    phase.raise_objection(this);

    base_addr = item_t::addr_t'(52'h0033_0000_0000);

    @(posedge super.tb_env.rni_agent.vif.rst_n);
    super.wait_clocks(4);

    if (!super.tb_env.rni_agent.vif.txlinkactivereq ||
        !super.tb_env.snf_agent.vif.txlinkactiveack) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] CHI-E link handshake was not active on both agents before phase 1",
        super.tc_name))
    end

    // -- Phase 1: traffic, so the reset rules arm. ---------------------------
    this.one_write(base_addr);
    super.wait_clocks(SETTLE_C);

    // -- Phase 2: reset in the middle of the run. ----------------------------
    super.tb_cfg.request_reset_pulse(4);

    @(negedge super.tb_env.rni_agent.vif.rst_n);
    super.wait_clocks(1);

    // Read the sideband while reset is still asserted. This is the same claim
    // p_link_sideband_idle_during_reset makes, asked from the testcase as well,
    // because a rule that stood itself down would leave nothing to notice.
    saw_sideband_idle = !super.tb_env.rni_agent.vif.txlinkactivereq &&
                        !super.tb_env.snf_agent.vif.txlinkactiveack;

    @(posedge super.tb_env.rni_agent.vif.rst_n);

    if (!saw_sideband_idle) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] CHI-E link handshake did not drop to idle during reset",
        super.tc_name))
    end

    saw_reactivation = 1'b0;
    repeat (16) begin
      if (super.tb_env.rni_agent.vif.txlinkactivereq &&
          super.tb_env.snf_agent.vif.txlinkactiveack) begin
        saw_reactivation = 1'b1;
        break;
      end
      super.wait_clocks(1);
    end

    if (!saw_reactivation) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] CHI-E link handshake was not re-asserted after reset release",
        super.tc_name))
    end

    super.wait_clocks(SETTLE_C);
    super.drain_observation_fifos();

    // A reset the link did not survive is worse than no reset at all, so the
    // link has to carry traffic again before the tear-down is attempted.
    this.one_write(base_addr + item_t::addr_t'('h100));
    super.wait_clocks(SETTLE_C);

    // -- Phase 3: graceful deactivation, the only path into DEACTIVATE. ------
    super.rni_cfg.link_deactivate_request = 1'b1;
    this.wait_deactivate_done(1'b1);
    super.wait_clocks(SETTLE_C);

    super.rni_cfg.link_deactivate_request = 1'b0;
    this.wait_deactivate_done(1'b0);
    super.wait_clocks(SETTLE_C);

    super.drain_observation_fifos();
    this.one_write(base_addr + item_t::addr_t'('h200));
    super.wait_clocks(SETTLE_C);

    // -- The verdict: every one of the six was EVALUATED, at BOTH ends. ------
    //
    // Both ends, because the two interfaces are the same wires at opposite
    // polarity and these six rules judge a node's OWN outputs. One end passing
    // says nothing about the other, and the RN-I and SN-F drivers hold their
    // channels idle by separate code.
    //
    // Six calls rather than a loop over a table of IDs. Nothing else in this
    // testbench declares a class-scope localparam unpacked array -- the testcases
    // use packed localparams and name enum constants directly -- so the IDs are
    // named here too.
    this.require_evaluated(VIP_CHI_CHK_LINK_SIDEBAND_IDLE_IN_RESET_E);
    this.require_evaluated(VIP_CHI_CHK_REQ_IDLE_IN_RESET_E);
    this.require_evaluated(VIP_CHI_CHK_RSP_IDLE_IN_RESET_E);
    this.require_evaluated(VIP_CHI_CHK_DAT_IDLE_IN_RESET_E);
    this.require_evaluated(VIP_CHI_CHK_LINK_RESTARTS_AFTER_RESET_E);
    this.require_evaluated(VIP_CHI_CHK_LINK_DEACTIVATE_WHEN_IDLE_E);

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] CHI-E link ran, reset mid-run, restarted, deactivated to STOP and carried traffic again; the six link-lifecycle rules were asked for evaluations at both ends",
      super.tc_name), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
