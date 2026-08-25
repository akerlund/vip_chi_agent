// Negative control for the grant-cycle L-Credit rule at the WIRE, which no
// configuration alone could reach.
//
// IHI 0050 E 14.2.1 / D 13.2.1, Note: "An L-Credit cannot be used in the cycle
// it is received." The rule judges the pair before the grant is applied and only
// with the send pool at zero, because above zero a same-cycle grant and consume
// is an ordinary pipelined link spending an earlier credit while a new one
// arrives, which the Note does not forbid.
//
// Neither end can produce the case alone: the flit and the grant that authorises
// it are driven by opposite ends of the link. So the two halves are set here on
// one agent each.
//
//   The RN-I steps around its credit manager for exactly one REQ send. That
//   manager refusing at zero is the only thing that keeps the driver off the
//   wire without permission, which is what made the rule unreachable and is also
//   what makes the underflow rule trustworthy -- so the bypass is counted rather
//   than a flag, and the driver goes back to asking immediately afterwards.
//
//   The SN-F withholds its initial REQ advertisement so the peer's pool stays at
//   zero, and draws a single grant off the first inbound REQ FLITPEND. A grant
//   drawn that way lands one cycle later, which is the cycle the announced flit
//   occupies. The withheld advertisement is released behind it, so the total
//   budget handed out over the run is unchanged and the link carries on.
//
// Both vantages must report. One end reporting alone would mean the pairing is
// only being done in one direction -- the RN-I tracks its tx_req pool against
// the inbound grant, the SN-F tracks the same wire as its rx_req pool against
// the grant it emits.
//
// CHI_LCRD_UNDERFLOW must stay SILENT throughout, and that is the sharpest thing
// this test says. A flit sent with the pool at zero looks like an underflow, but
// the shadow applies the grant before the consume, so the count goes 0 -> 1 -> 0
// and never dips. That ordering is right for the counter and is exactly what hid
// this case -- the underflow rule structurally cannot catch it, which is why the
// grant-cycle rule is not redundant with it. Left at its normal severity, so a
// report would fail the run on its own.
//
// The grant-cycle rule is turned down to VIP_CHI_CHK_SEV_OFF_E rather than
// disabled: OFF still evaluates and still counts, which is what leaves a count
// to assert on.

class tc_chi_d_lcrd_grant_cycle_negctl extends chi_base_test;

  `uvm_component_utils(tc_chi_d_lcrd_grant_cycle_negctl)

  localparam item_t::addr_t ADDR_C   = item_t::addr_t'(44'h3F10_0000);
  localparam bit [2:0]      SIZE_C   = 3'd6;   // 64 B = 4 beats on the CHI-D cut
  localparam int            SETTLE_C = 40;
  // One uncredited send, so one report per vantage.
  localparam int            EXPECTED_FAILS_C = 1;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // REQ only, so the other two channels stay conformant and a report from them
  // would be a separate defect rather than this stimulus.
  // ---------------------------------------------------------------------------
  function void build_phase(input uvm_phase phase);

    super.build_phase(phase);

    super.rni_cfg.req_send_without_credit_negctl    = 1;
    super.snf_cfg.req_lcrd_grant_on_flitpend_negctl = 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    int unsigned rni_fails;
    int unsigned snf_fails;
    int unsigned rni_under;
    int unsigned snf_under;
    int unsigned rni_passes;

    phase.raise_objection(this);

    super.tb_env.rni_agent.vif.check_severity[VIP_CHI_CHK_LCRD_USED_IN_GRANT_CYCLE_E] =
      VIP_CHI_CHK_SEV_OFF_E;
    super.tb_env.snf_agent.vif.check_severity[VIP_CHI_CHK_LCRD_USED_IN_GRANT_CYCLE_E] =
      VIP_CHI_CHK_SEV_OFF_E;

    super.wait_clocks(SETTLE_C);

    // Nothing may have fired yet: no REQ flit has been sent, so the withheld
    // advertisement on its own must be silent.
    if (super.tb_env.rni_agent.vif.check_fail_count[VIP_CHI_CHK_LCRD_USED_IN_GRANT_CYCLE_E] != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s reported before any REQ flit was sent; withholding an advertisement is not the violation",
        super.tc_name, vip_chi_check_name(VIP_CHI_CHK_LCRD_USED_IN_GRANT_CYCLE_E)))
    end

    super.rni0_rd_seq.reset();
    super.rni0_rd_seq.set_requests(1);
    super.rni0_rd_seq.set_initial_addr(ADDR_C);
    super.rni0_rd_seq.set_size(SIZE_C);
    super.rni0_rd_seq.set_get_response(1'b1);
    super.rni0_rd_seq.set_verbose(1'b0);
    super.rni0_rd_seq.start(super.v_sqr.rni_sequencer);

    super.wait_clocks(SETTLE_C);

    rni_fails  = super.tb_env.rni_agent.vif.check_fail_count[VIP_CHI_CHK_LCRD_USED_IN_GRANT_CYCLE_E];
    snf_fails  = super.tb_env.snf_agent.vif.check_fail_count[VIP_CHI_CHK_LCRD_USED_IN_GRANT_CYCLE_E];
    rni_under  = super.tb_env.rni_agent.vif.check_fail_count[VIP_CHI_CHK_LCRD_UNDERFLOW_E];
    snf_under  = super.tb_env.snf_agent.vif.check_fail_count[VIP_CHI_CHK_LCRD_UNDERFLOW_E];
    rni_passes = super.tb_env.rni_agent.vif.check_pass_count[VIP_CHI_CHK_LCRD_USED_IN_GRANT_CYCLE_E];

    if (rni_passes == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s recorded no passes at all; the credit accounting is not running and the counts below would mean nothing",
        super.tc_name, vip_chi_check_name(VIP_CHI_CHK_LCRD_USED_IN_GRANT_CYCLE_E)))
    end

    if (rni_fails != EXPECTED_FAILS_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s reported %0d time(s) at the RN-I against one uncredited send, expected exactly %0d; zero means the grant did not land in the flit's own cycle, above means the rule is also flagging credited traffic",
        super.tc_name, vip_chi_check_name(VIP_CHI_CHK_LCRD_USED_IN_GRANT_CYCLE_E),
        rni_fails, EXPECTED_FAILS_C))
    end

    if (snf_fails != EXPECTED_FAILS_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s reported %0d time(s) at the SN-F, expected exactly %0d; the granting vantage is not pairing its own grant with the flit it authorises",
        super.tc_name, vip_chi_check_name(VIP_CHI_CHK_LCRD_USED_IN_GRANT_CYCLE_E),
        snf_fails, EXPECTED_FAILS_C))
    end

    if ((rni_under != 0) || (snf_under != 0)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s reported %0d time(s) at the RN-I and %0d at the SN-F, expected silence at both; the shadow applies the grant before the consume, so the count goes 0 -> 1 -> 0 and never dips -- a report here would mean the two rules are judging the same thing twice",
        super.tc_name, vip_chi_check_name(VIP_CHI_CHK_LCRD_UNDERFLOW_E),
        rni_under, snf_under))
    end

    // The link must still work on the credits it legally has, and the released
    // advertisement must not read as a further violation.
    super.rni0_rd_seq.reset();
    super.rni0_rd_seq.set_requests(4);
    super.rni0_rd_seq.set_initial_addr(ADDR_C);
    super.rni0_rd_seq.set_size(SIZE_C);
    super.rni0_rd_seq.set_get_response(1'b1);
    super.rni0_rd_seq.set_verbose(1'b0);
    super.rni0_rd_seq.start(super.v_sqr.rni_sequencer);

    super.wait_clocks(SETTLE_C);

    if ((super.tb_env.rni_agent.vif.check_fail_count[VIP_CHI_CHK_LCRD_USED_IN_GRANT_CYCLE_E] != EXPECTED_FAILS_C) ||
        (super.tb_env.snf_agent.vif.check_fail_count[VIP_CHI_CHK_LCRD_USED_IN_GRANT_CYCLE_E] != EXPECTED_FAILS_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s kept firing on credited traffic after the uncredited send; without its at-zero bound the rule fires on every busy cycle of every run",
        super.tc_name, vip_chi_check_name(VIP_CHI_CHK_LCRD_USED_IN_GRANT_CYCLE_E)))
    end

    if ((super.tb_env.rni_agent.vif.check_fail_count[VIP_CHI_CHK_LCRD_UNDERFLOW_E] != 0) ||
        (super.tb_env.snf_agent.vif.check_fail_count[VIP_CHI_CHK_LCRD_UNDERFLOW_E] != 0)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s reported on the credited traffic that followed",
        super.tc_name, vip_chi_check_name(VIP_CHI_CHK_LCRD_UNDERFLOW_E)))
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] a REQ flit sent in the cycle its only L-credit was granted was reported once at each vantage (%0d credited pairs passed first) with %s silent throughout, and the link then carried four reads to completion",
      super.tc_name, rni_passes,
      vip_chi_check_name(VIP_CHI_CHK_LCRD_UNDERFLOW_E)), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
