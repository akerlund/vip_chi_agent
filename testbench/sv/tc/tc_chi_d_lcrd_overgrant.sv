// Negative control for the L-Credit overflow rule, which could not fire before.
//
// IHI 0050 E 14.2.1 / D 13.2.1: "The minimum number of L-Credits that a receiver
// can provide is one. The maximum number of L-Credits that a receiver can
// provide is 15." One LCRDV signal per channel, so the bound is per channel.
//
// The checker's bound was 64 -- a number the specification does not contain --
// and the comment beside it said as much, describing it as a bound on "the
// shadow counter, not the protocol". At 64 the rule was a false NEGATIVE: a
// receiver advertising 16 through 64 credits on a channel was over-granting, and
// every one of those grants was reported as fine. Nothing in the regression
// advertised more than 8, so the rule had also never been asked.
//
// This test asks it. The SN-F advertises 16 REQ receive credits after link
// activation, one more than the protocol permits, and the sixteenth grant must
// be reported at BOTH vantages -- the RN-I counting the grants that arrive and
// the SN-F counting the grants it emits. One end reporting alone would mean the
// accounting is only being done in one direction.
//
// Exactly one report, not "at least one": the fifteen legal grants that precede
// it must not be flagged, and the rule must not keep firing afterwards on a link
// that then carries ordinary traffic.
//
// The cfg validator deliberately still ACCEPTS 16 here. A configuration that
// could not express an over-granting receiver could not model a broken peer, and
// then this control could not exist -- the checker is the right place to report
// the violation, not the knob that sets it up.
//
// The rule is turned down to VIP_CHI_CHK_SEV_OFF_E rather than disabled: OFF
// still evaluates and still counts, which is what leaves a count to assert on.

class tc_chi_d_lcrd_overgrant extends chi_base_test;

  `uvm_component_utils(tc_chi_d_lcrd_overgrant)

  localparam item_t::addr_t ADDR_C   = item_t::addr_t'(44'h3F00_0000);
  localparam bit [2:0]      SIZE_C   = 3'd6;   // 64 B = 4 beats on the CHI-D cut
  localparam int            SETTLE_C = 40;
  // One over-grant, so one report per vantage.
  localparam int            EXPECTED_FAILS_C = 1;
  // The protocol maximum is 15; advertising this many is one too many.
  localparam int unsigned   OVERGRANT_C = 16;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // Over-advertise on REQ only, so the other two channels stay conformant and
  // any report from them would be a separate defect rather than this stimulus.
  // ---------------------------------------------------------------------------
  function void build_phase(input uvm_phase phase);

    super.build_phase(phase);

    super.snf_cfg.initial_req_credits = OVERGRANT_C;
  endfunction

  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    int unsigned rni_fails;
    int unsigned snf_fails;
    int unsigned rni_passes;

    phase.raise_objection(this);

    // Suppress the report, keep the count, at both ends: both are about to be
    // made to fail by the same sixteenth grant.
    super.tb_env.rni_agent.vif.check_severity[VIP_CHI_CHK_LCRD_OVERFLOW_E] =
      VIP_CHI_CHK_SEV_OFF_E;
    super.tb_env.snf_agent.vif.check_severity[VIP_CHI_CHK_LCRD_OVERFLOW_E] =
      VIP_CHI_CHK_SEV_OFF_E;

    // Let the whole initial advertisement land before any flit consumes a
    // credit, or the count would never reach the bound.
    super.wait_clocks(SETTLE_C);

    rni_fails  = super.tb_env.rni_agent.vif.check_fail_count[VIP_CHI_CHK_LCRD_OVERFLOW_E];
    snf_fails  = super.tb_env.snf_agent.vif.check_fail_count[VIP_CHI_CHK_LCRD_OVERFLOW_E];
    rni_passes = super.tb_env.rni_agent.vif.check_pass_count[VIP_CHI_CHK_LCRD_OVERFLOW_E];

    if (rni_passes == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s recorded no passes at all; the credit accounting is not running and the count below would mean nothing",
        super.tc_name, vip_chi_check_name(VIP_CHI_CHK_LCRD_OVERFLOW_E)))
    end

    if (rni_fails != EXPECTED_FAILS_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s reported %0d time(s) at the RN-I against one over-grant, expected exactly %0d; below means the bound is still above the protocol maximum of 15, above means the legal grants are being flagged too",
        super.tc_name, vip_chi_check_name(VIP_CHI_CHK_LCRD_OVERFLOW_E),
        rni_fails, EXPECTED_FAILS_C))
    end

    if (snf_fails != EXPECTED_FAILS_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s reported %0d time(s) at the SN-F, expected exactly %0d; the emitting vantage is not counting its own grants",
        super.tc_name, vip_chi_check_name(VIP_CHI_CHK_LCRD_OVERFLOW_E),
        snf_fails, EXPECTED_FAILS_C))
    end

    // The link must still work on the credits it legally has. An over-granting
    // peer is a reportable defect, not a reason for the requester to stop.
    super.rni0_rd_seq.reset();
    super.rni0_rd_seq.set_requests(1);
    super.rni0_rd_seq.set_initial_addr(ADDR_C);
    super.rni0_rd_seq.set_size(SIZE_C);
    super.rni0_rd_seq.set_get_response(1'b1);
    super.rni0_rd_seq.set_verbose(1'b0);
    super.rni0_rd_seq.start(super.v_sqr.rni_sequencer);

    super.wait_clocks(SETTLE_C);

    if (super.tb_env.rni_agent.vif.check_fail_count[VIP_CHI_CHK_LCRD_OVERFLOW_E] !=
        EXPECTED_FAILS_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s kept firing after the over-grant, on traffic that spends credits rather than granting them",
        super.tc_name, vip_chi_check_name(VIP_CHI_CHK_LCRD_OVERFLOW_E)))
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] a receiver advertising %0d REQ credits was reported once at each vantage (%0d legal grants passed first), and the link then carried a read to completion",
      super.tc_name, OVERGRANT_C, rni_passes), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
