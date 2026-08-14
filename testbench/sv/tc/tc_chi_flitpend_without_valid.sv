// Negative control for the two FLITPEND rules, which no other test could reach.
//
// CHI_REQ_PEND_REQUIRES_VALID and CHI_RSP_PEND_REQUIRES_VALID were never
// exercised anywhere in either regression, and the reason was simply that
// nothing ever raised FLITPEND on those two channels: the drivers pair it with
// the flit it belongs to, and only the DAT burst has a use for it (raised on
// every beat but the last, meaning "more beats coming"), which is why the DAT
// twin of this rule was the only one of the three ever evaluated.
//
// So this is a rule that had never once run. That is indistinguishable from a
// rule that does not work, and the whole point of the vacuity report is to say
// so rather than let a clean regression imply otherwise.
//
// What the rule polices is a VIP EMISSION CONVENTION, not a CHI mandate, and the
// distinction is worth stating because it changes what a failure means. CHI's
// FLITPEND is a one-cycle-ahead hint that a flit MIGHT follow, and a transmitter
// is permitted to assert it and then not send -- discouraged, but legal. This
// VIP emits FLITPEND alongside its flit, so a lone FLITPEND means a driver has
// lost track of its own burst. Same standing as the DataID-ordering rules, which
// hold this VIP's in-order emission convention rather than a CHI requirement.
//
// cfg.flitpend_without_valid pulses FLITPEND on REQ and RSP for one cycle with
// no flit behind it, once, after the link is up. Both halves are asserted:
//   * each rule must report exactly once -- one lone FLITPEND per channel;
//   * ordinary traffic afterwards must complete and must not add reports, or the
//     rules would be firing on well-formed flits too.
//
// The rules are turned down to VIP_CHI_CHK_SEV_OFF_E rather than disabled. OFF
// still EVALUATES and still COUNTS -- it only suppresses the report -- which is
// what a negative control needs. Disabling would stop the counting too, leaving
// nothing to assert on.

class tc_chi_flitpend_without_valid extends chi_base_test;

  `uvm_component_utils(tc_chi_flitpend_without_valid)

  localparam item_t::addr_t ADDR_C   = item_t::addr_t'(44'h3E00_0000);
  localparam bit [2:0]      SIZE_C   = 3'd6;   // 64 B = 4 beats on the CHI-D cut
  localparam int            SETTLE_C = 20;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // Emit the lone FLITPEND on the requester that drives those two channels.
  // ---------------------------------------------------------------------------
  protected virtual function void configure_agent_cfgs();

    super.configure_agent_cfgs();

    super.rni_cfg.flitpend_without_valid = 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    int unsigned req_fails;
    int unsigned rsp_fails;
    int unsigned dat_pass;

    phase.raise_objection(this);

    // Suppress the report, keep the count.
    super.tb_env.rni_agent.vif.check_severity[VIP_CHI_CHK_REQ_PEND_REQUIRES_VALID_E] =
      VIP_CHI_CHK_SEV_OFF_E;
    super.tb_env.rni_agent.vif.check_severity[VIP_CHI_CHK_RSP_PEND_REQUIRES_VALID_E] =
      VIP_CHI_CHK_SEV_OFF_E;

    // A write, not a read: the requester transmits a REQ flit and then the
    // WriteData beats, so the rules see well-formed FLITPEND on two channels
    // after the deliberately malformed pulse. A read would leave the RSP side
    // untouched and the second assertion below would prove nothing.
    super.rni0_wr_seq.reset();
    super.rni0_wr_seq.set_requests(1);
    super.rni0_wr_seq.set_initial_addr(ADDR_C);
    super.rni0_wr_seq.set_size(SIZE_C);
    super.rni0_wr_seq.set_exp_comp_ack(1'b1);
    super.rni0_wr_seq.set_allow_retry(1'b0);
    super.rni0_wr_seq.set_get_response(1'b1);
    super.rni0_wr_seq.set_verbose(1'b0);
    super.rni0_wr_seq.start(super.v_sqr.rni_sequencer);

    super.wait_clocks(SETTLE_C);

    req_fails = super.tb_env.rni_agent.vif.check_fail_count[VIP_CHI_CHK_REQ_PEND_REQUIRES_VALID_E];
    rsp_fails = super.tb_env.rni_agent.vif.check_fail_count[VIP_CHI_CHK_RSP_PEND_REQUIRES_VALID_E];
    dat_pass  = super.tb_env.rni_agent.vif.check_pass_count[VIP_CHI_CHK_DAT_PEND_REQUIRES_VALID_E];

    // One lone FLITPEND per channel, so exactly one report per channel. Fewer
    // means the rule never fired and is still vacuous; more means it is also
    // firing on the well-formed FLITPEND the write's own flits carry, which
    // would make it useless in an ordinary run.
    if (req_fails != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s reported %0d time(s) against exactly one lone FLITPEND; it is vacuous at 0 and firing on well-formed flits above 1",
        super.tc_name, vip_chi_check_name(VIP_CHI_CHK_REQ_PEND_REQUIRES_VALID_E), req_fails))
    end

    if (rsp_fails != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s reported %0d time(s) against exactly one lone FLITPEND; it is vacuous at 0 and firing on well-formed flits above 1",
        super.tc_name, vip_chi_check_name(VIP_CHI_CHK_RSP_PEND_REQUIRES_VALID_E), rsp_fails))
    end

    // And the traffic that followed still has to have gone through, or the
    // control would have broken the link rather than exercised a rule.
    if (dat_pass == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the write drove no well-formed DAT FLITPEND, so this run says nothing about the rules holding on ordinary traffic",
        super.tc_name))
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] one lone FLITPEND on each of REQ and RSP was reported exactly once per channel, and the write that followed drove %0d well-formed DAT FLITPEND(s) without adding a report",
      super.tc_name, dat_pass), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
