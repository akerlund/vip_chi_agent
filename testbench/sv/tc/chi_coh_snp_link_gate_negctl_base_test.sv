// ===========================================================================
// chi_coh_snp_link_gate_negctl_base_test
//
// Wire negative control for CHI_SNP_FLITV_REQUIRES_LINK, which had never been
// reachable outside a unit test.
//
// IHI 0050 E section 14.6.1 / D section 13.6.1 give an interface TWO link state
// machines, one per direction, and a channel's payload belongs to the machine
// that carries it. A snoop is the home's OUTPUT, so txsnpflitv is judged against
// the home's TRANSMIT link, which reaches RUN only when the SNOOPEE
// acknowledges. Nothing produced a home whose transmit link was anything but RUN
// while it had a snoop to send, because the two machines at a coherent endpoint
// moved together.
//
// Separating them is the whole setup, and only one lever does it.
// cfg.lasm_ack_delay_cycles holds the SNOOPEE's acknowledge down for a counted
// number of cycles after it sees the home's request. That is a CONFORMANT peer:
// Table 14-2 has the transmitter "waiting for the receiver to acknowledge" as an
// ordinary dwell in ACTIVATE, and 14.6.3 bans only the acknowledge moving BEFORE
// the request. Delaying the home's REQUEST instead cannot work -- 14.6.3 forbids
// the acknowledge to lead the request, so a home that holds its request back
// holds its acknowledge back with it and the snoopee's two machines move
// together again.
//
// What the delay exposes is a defect at the OTHER end, which is why the fix and
// the control are separate things. The home used to start transmitting on the
// strength of the peer's REQUEST rather than its own transmit link reaching RUN,
// and that is invisible while the peer acknowledges promptly -- the two events
// are two cycles apart. rn_activate now waits for the acknowledge before it
// opens the transmit gate, and cfg.hnf_send_before_tx_link_negctl stands that
// gate down so the control has the old behaviour to report.
//
// COLLATERAL, declared rather than waived: the gate is the one every RN-facing
// flit passes, so the read data that belongs to the request being serviced goes
// out early too and CHI_DAT_FLITV_REQUIRES_LINK reports on both of the home's
// ports. That is the same defect seen on a different channel, not a second one,
// and asserting it is what shows the gate covers the whole transmit link rather
// than the snoop channel alone.
//
// PHASE 2 is the OTHER rule of the same pair, and it needs a different setup for
// a reason worth stating. CHI_SNP_LCRDV_REQUIRES_LINK wants the snoopee's
// RECEIVE link in STOP while the snoopee advertises SNP credits, and no delay
// reaches that during a first bring-up: the snoopee advertises once its own
// transmit link is acknowledged, by which time the home's request is
// necessarily already up, because 14.6.3 forbids the home's acknowledge to lead
// it. So the receive machine is at least ACTIVATE and the rule permits that.
//
// cfg.rnf_snp_credit_before_link_negctl moves some of the initial advertisement
// ahead of the link instead, drawn OUT of the budget rather than added to it so
// only the timing changes. That alone is still not enough, and the reason is a
// deliberate scoping decision rather than an accident: the rule is gated on the
// link having EVER been active, so a link that has never come up cannot report
// at all. A RESET is what closes the gap -- it returns an already-active link to
// STOP, leaving the gate satisfied and the state reachable. Measured, not
// assumed: the same knob before the first activation reports nothing.
//
// Used by:
//   tc_chi_coh_e_snp_link_gate_negctl  (wide CHI-E)
//   tc_chi_coh_d_snp_link_gate_negctl  (CHI-D)
// ===========================================================================
class chi_coh_snp_link_gate_negctl_base_test #(
  vip_chi_cfg_t CFG_P   = CHI_D_CFG_C,
  type          TYPES_T = chi_d_types_t
) extends chi_coherent_base_test #(CFG_P, TYPES_T);

  typedef vip_chi_item #(CFG_P) item_t;

  `uvm_component_param_utils(chi_coh_snp_link_gate_negctl_base_test #(CFG_P, TYPES_T))

  localparam int SETTLE_C = 40;
  // Long enough that the home has a snoop to send while its transmit link is
  // still in ACTIVATE, and short enough to stay clear of any activation timeout
  // a test might enable.
  localparam int unsigned ACK_DELAY_C = 120;
  // One snoop goes out in the window, so one report at the port it goes out on.
  localparam int EXPECTED_SNP_FAILS_C = 1;
  // One report per credit the control puts out ahead of the link.
  localparam int unsigned EARLY_SNP_CREDITS_C = 2;
  localparam int EXPECTED_LCRDV_FAILS_C = int'(EARLY_SNP_CREDITS_C);
  // Long enough that the credits are still draining while the link is in STOP.
  localparam int unsigned REQ_DELAY_C = 12;

  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  // Both snoopees hold their acknowledge, so the window is open on both of the
  // home's ports and a report on only one of them would be a routing accident.
  // ---------------------------------------------------------------------------
  protected virtual function void configure_agent_cfgs();
    super.hrnf0_cfg.lasm_ack_delay_cycles = ACK_DELAY_C;
    super.hrnf1_cfg.lasm_ack_delay_cycles = ACK_DELAY_C;
    super.hnf_cfg.hnf_send_before_tx_link_negctl = 1'b1;

    // Phase 2, on the snoopee only: some of its initial SNP advertisement goes
    // out ahead of the link, and its own request is held back so the link is
    // still in STOP while they drain.
    super.hrnf0_cfg.rnf_snp_credit_before_link_negctl = EARLY_SNP_CREDITS_C;
    super.hrnf0_cfg.lasm_req_delay_by_state[0]        = REQ_DELAY_C;
  endfunction

  // ---------------------------------------------------------------------------
  // The rule's total across every SNP-capable bind in this topology.
  // ---------------------------------------------------------------------------
  protected function int unsigned snp_lcrdv_fails();

    int unsigned total;

    total = 0;
    foreach (super.tb_env.hnf_agent.rn_vif[i]) begin
      total += super.tb_env.hnf_agent.rn_vif[i].check_fail_count[VIP_CHI_CHK_SNP_LCRDV_REQUIRES_LINK_E];
    end
    total +=
      super.tb_env.hrnf0_agent.vif.check_fail_count[VIP_CHI_CHK_SNP_LCRDV_REQUIRES_LINK_E] +
      super.tb_env.hrnf1_agent.vif.check_fail_count[VIP_CHI_CHK_SNP_LCRDV_REQUIRES_LINK_E];
    return total;
  endfunction

  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t       setup_rsp[$];
    item_t       read_rsp[$];
    int unsigned snp_fails;
    int unsigned dat_fails [2];
    int unsigned lcrdv_fails;
    int unsigned snoopee_lcrdv;
    int unsigned snoopee_fails;

    phase.raise_objection(this);

    // Suppress the reports, keep the counts, at both of the home's RN-facing
    // ports: both are about to be made to fail by the same missing gate.
    foreach (super.tb_env.hnf_agent.rn_vif[i]) begin
      super.tb_env.hnf_agent.rn_vif[i].check_severity[VIP_CHI_CHK_SNP_FLITV_REQUIRES_LINK_E] =
        VIP_CHI_CHK_SEV_OFF_E;
      super.tb_env.hnf_agent.rn_vif[i].check_severity[VIP_CHI_CHK_DAT_FLITV_REQUIRES_LINK_E] =
        VIP_CHI_CHK_SEV_OFF_E;
    end
    super.tb_env.hrnf0_agent.vif.check_severity[VIP_CHI_CHK_SNP_LCRDV_REQUIRES_LINK_E] =
      VIP_CHI_CHK_SEV_OFF_E;
    super.tb_env.hrnf1_agent.vif.check_severity[VIP_CHI_CHK_SNP_LCRDV_REQUIRES_LINK_E] =
      VIP_CHI_CHK_SEV_OFF_E;

    super.wait_reset_settle();

    this.cfg_read_seq(super.hrnf0_rdunique_seq);
    super.hrnf0_rdunique_seq.start(super.tb_env.hrnf0_agent.sequencer);
    setup_rsp = super.hrnf0_rdunique_seq.get_responses();
    if (setup_rsp.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F0 did not acquire the line (got %0d response(s)); a link held in ACTIVATE must still carry traffic once it comes up",
        super.tc_name, setup_rsp.size()))
    end

    super.wait_clocks(SETTLE_C);

    this.cfg_read_seq(super.hrnf1_rdshared_seq);
    super.hrnf1_rdshared_seq.start(super.tb_env.hrnf1_agent.sequencer);
    read_rsp = super.hrnf1_rdshared_seq.get_responses();
    if (read_rsp.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F1's read never completed (got %0d response(s))",
        super.tc_name, read_rsp.size()))
    end

    super.wait_clocks(SETTLE_C);

    if (super.tb_env.hrnf0_snp_fifo.used() == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F0 was never snooped, so the home answered from its directory and the snoop this control times was never sent",
        super.tc_name))
    end

    snp_fails = super.tb_env.hnf_agent.rn_vif[0].check_fail_count[VIP_CHI_CHK_SNP_FLITV_REQUIRES_LINK_E];
    foreach (dat_fails[i]) begin
      dat_fails[i] = super.tb_env.hnf_agent.rn_vif[i].check_fail_count[VIP_CHI_CHK_DAT_FLITV_REQUIRES_LINK_E];
    end

    if (snp_fails != EXPECTED_SNP_FAILS_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s reported %0d time(s) at the home's port 0, expected exactly %0d; zero means the snoop went out after the transmit link had reached RUN and the rule is still unreachable on the wire",
        super.tc_name, vip_chi_check_name(VIP_CHI_CHK_SNP_FLITV_REQUIRES_LINK_E),
        snp_fails, EXPECTED_SNP_FAILS_C))
    end

    if ((dat_fails[0] == 0) || (dat_fails[1] == 0)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s reported %0d time(s) at port 0 and %0d at port 1, expected both non-zero; the gate this control removes covers the whole transmit link, not the snoop channel alone",
        super.tc_name, vip_chi_check_name(VIP_CHI_CHK_DAT_FLITV_REQUIRES_LINK_E),
        dat_fails[0], dat_fails[1]))
    end

    // The snoopee's own outputs are untouched: it is the peer whose slow
    // acknowledge opens the window, not the component in breach.
    snoopee_fails =
      super.tb_env.hrnf0_agent.vif.check_fail_count[VIP_CHI_CHK_SNP_FLITV_REQUIRES_LINK_E] +
      super.tb_env.hrnf1_agent.vif.check_fail_count[VIP_CHI_CHK_SNP_FLITV_REQUIRES_LINK_E];
    if (snoopee_fails != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the snoopees' own binds reported %0d time(s): a conformant peer that acknowledges slowly is not itself in breach",
        super.tc_name, snoopee_fails))
    end

    // Nothing may have reported yet: before the first activation the rule's own
    // gate stands it down, so the early credits that went out then are silent.
    lcrdv_fails = this.snp_lcrdv_fails();
    if (lcrdv_fails != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s reported %0d time(s) before any reset; the rule is gated on the link having been active, so a link that has never come up must not report",
        super.tc_name, vip_chi_check_name(VIP_CHI_CHK_SNP_LCRDV_REQUIRES_LINK_E),
        lcrdv_fails))
    end

    // -- Phase 2: a reset returns an already-active link to STOP. ------------
    super.tb_cfg.request_reset_pulse(4);
    @(negedge super.tb_env.hrnf0_agent.vif.rst_n);
    @(posedge super.tb_env.hrnf0_agent.vif.rst_n);
    super.wait_clocks(SETTLE_C);

    snoopee_lcrdv =
      super.tb_env.hrnf0_agent.vif.check_fail_count[VIP_CHI_CHK_SNP_LCRDV_REQUIRES_LINK_E];
    lcrdv_fails = this.snp_lcrdv_fails();

    if (snoopee_lcrdv != EXPECTED_LCRDV_FAILS_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s reported %0d time(s) at the snoopee, expected exactly %0d -- one per credit the control put out ahead of the link; zero means the advertisement waited for the link after all",
        super.tc_name, vip_chi_check_name(VIP_CHI_CHK_SNP_LCRDV_REQUIRES_LINK_E),
        snoopee_lcrdv, EXPECTED_LCRDV_FAILS_C))
    end

    if (lcrdv_fails != EXPECTED_LCRDV_FAILS_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s reported %0d time(s) across the four SNP binds against %0d at the snoopee; only the snoopee this control is set on advertises SNP credits, so a report anywhere else is a different defect",
        super.tc_name, vip_chi_check_name(VIP_CHI_CHK_SNP_LCRDV_REQUIRES_LINK_E),
        lcrdv_fails, snoopee_lcrdv))
    end

    `uvm_info(get_name(), $sformatf(
      "Test (%s) PASS: with the snoopees acknowledging %0d cycle(s) late, the home snooped into a transmit link still in ACTIVATE and %s reported it once, with %0d/%0d data beats reported on the same gate and both reads still completing; a reset then returned the link to STOP and %s reported the %0d credit(s) advertised ahead of it",
      super.tc_name, ACK_DELAY_C,
      vip_chi_check_name(VIP_CHI_CHK_SNP_FLITV_REQUIRES_LINK_E),
      dat_fails[0], dat_fails[1],
      vip_chi_check_name(VIP_CHI_CHK_SNP_LCRDV_REQUIRES_LINK_E),
      EXPECTED_LCRDV_FAILS_C), UVM_LOW)

    phase.drop_objection(this);

  endtask
endclass
