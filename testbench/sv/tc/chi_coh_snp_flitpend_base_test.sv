// ===========================================================================
// chi_coh_snp_flitpend_base_test
//
// Negative control for CHI_SNP_PEND_REQUIRES_VALID, the last rule in the
// registry that no test could reach.
//
// The SNP twin of tc_chi_flitpend_without_valid, and it exists for the same
// reason: nothing ever raised SNP FLITPEND, because the home pairs it with the
// snoop it belongs to. A rule that has never once been evaluated is
// indistinguishable from a rule that does not work, and a clean regression that
// contains one is quietly reporting less than it appears to.
//
// It is a separate test from the REQ/RSP one because the SNP channel only exists
// on a coherent link: the requester-side control has no SNP to pulse, and this
// one has no requester.
//
// cfg.flitpend_without_valid makes the home raise SNP FLITPEND for one cycle,
// once per RN link, with the link up and before any snoop. Both halves are
// asserted by the single "exactly one" bound:
//   * fewer than one means the rule never fired and is still vacuous;
//   * more than one means it is firing on something other than the deliberate
//     pulse, and the snooped traffic that follows is there to give it the
//     chance -- a rule that also reported on ordinary snoops would be useless.
//
// Note the home drives SNP FLITPEND LOW on its real snoops, so this rule takes
// no passes from them. That is worth stating rather than leaving to be
// discovered: its only evaluation in the whole regression is this control, so
// the vacuity report lists it as exercised-but-THIN, which is the honest
// description. Making the home assert FLITPEND with each snoop would change
// every coherent waveform, and unlike the DAT channel there is no burst for a
// "more beats coming" hint to mean anything about.
//
// The rule is turned down to VIP_CHI_CHK_SEV_OFF_E rather than disabled. OFF
// still EVALUATES and still COUNTS -- it only suppresses the report -- which is
// what a negative control needs. Disabling would stop the counting too, leaving
// nothing to assert on.
//
// Used by:
//   tc_chi_coh_d_snp_flitpend  (CHI-D)
// ===========================================================================
class chi_coh_snp_flitpend_base_test #(
  vip_chi_cfg_t CFG_P   = CHI_D_CFG_C,
  type          TYPES_T = chi_d_types_t
) extends chi_coherent_base_test #(CFG_P, TYPES_T);

  typedef vip_chi_item #(CFG_P) item_t;

  `uvm_component_param_utils(chi_coh_snp_flitpend_base_test #(CFG_P, TYPES_T))

  localparam int SETTLE_C = 40;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  // Pulse the lone FLITPEND from the home, which is the node that drives SNP.
  // ---------------------------------------------------------------------------
  protected virtual function void configure_agent_cfgs();
    super.hnf_cfg.flitpend_without_valid = 1'b1;
  endfunction

  task run_phase(input uvm_phase phase);

    int unsigned pend_fails;
    int unsigned snoop_passes;

    phase.raise_objection(this);

    super.wait_reset_settle();

    // Suppress the report, keep the count. Both RN-facing ports, because the
    // home pulses once per link and each has its own bind.
    foreach (super.tb_env.hnf_agent.rn_vif[i]) begin
      super.tb_env.hnf_agent.rn_vif[i].check_severity[VIP_CHI_CHK_SNP_PEND_REQUIRES_VALID_E] =
        VIP_CHI_CHK_SEV_OFF_E;
    end
    super.tb_env.hrnf0_agent.vif.check_severity[VIP_CHI_CHK_SNP_PEND_REQUIRES_VALID_E] =
      VIP_CHI_CHK_SEV_OFF_E;
    super.tb_env.hrnf1_agent.vif.check_severity[VIP_CHI_CHK_SNP_PEND_REQUIRES_VALID_E] =
      VIP_CHI_CHK_SEV_OFF_E;

    // Coherent traffic that actually snoops: RN-F0 takes the line Unique, then
    // RN-F1 reads it, which forces the home to snoop RN-F0. Its job here is to
    // put real snoops on the wire AFTER the malformed pulse, so the "exactly
    // one" bound below has something that could break it. It also proves the
    // pulse left the link usable rather than wedged.
    this.cfg_read_seq(super.hrnf0_rdunique_seq);
    super.hrnf0_rdunique_seq.start(super.tb_env.hrnf0_agent.sequencer);
    void'(super.hrnf0_rdunique_seq.get_responses());

    this.cfg_read_seq(super.hrnf1_rdshared_seq);
    super.hrnf1_rdshared_seq.start(super.tb_env.hrnf1_agent.sequencer);
    void'(super.hrnf1_rdshared_seq.get_responses());

    super.wait_clocks(SETTLE_C);

    pend_fails =
      super.tb_env.hnf_agent.rn_vif[0].check_fail_count[VIP_CHI_CHK_SNP_PEND_REQUIRES_VALID_E];
    snoop_passes =
      super.tb_env.hnf_agent.rn_vif[0].check_pass_count[VIP_CHI_CHK_SNP_PEND_REQUIRES_VALID_E];

    // One lone FLITPEND per link, so exactly one report on this one. Fewer means
    // the rule never fired and is still vacuous; more means it fired on
    // something other than the deliberate pulse, which the snoops above gave it
    // the chance to do.
    if (pend_fails != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s reported %0d time(s) on port 0 against exactly one lone SNP FLITPEND; it is vacuous at 0 and firing on something other than the pulse above 1",
        super.tc_name, vip_chi_check_name(VIP_CHI_CHK_SNP_PEND_REQUIRES_VALID_E),
        pend_fails))
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] one lone SNP FLITPEND was reported exactly once; the snooped coherent traffic that followed completed and added no further report (%0d pass(es), since the home drives FLITPEND low on real snoops)",
      super.tc_name, snoop_passes), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
