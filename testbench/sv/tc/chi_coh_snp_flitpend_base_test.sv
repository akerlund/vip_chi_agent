// ===========================================================================
// chi_coh_snp_flitpend_base_test
//
// POSITIVE control for CHI_SNP_VALID_REQUIRES_PEND: legal traffic the rule must
// NOT report, on the one channel that only exists on a coherent link.
//
// The SNP twin of tc_chi_flitpend_without_valid, and inverted for the same
// reason. IHI 0050 E §14.4 / D §13.4 permit a transmitter to "assert and then
// deassert this signal without sending a flit", so the home's lone SNP FLITPEND
// pulse is legal and owes nothing. The rule this test was written for ran the
// obligation backwards and reported that pulse as a violation; the corrected
// rule runs it from the flit backwards, so the same stimulus is now evidence
// that the rule does not reject legal traffic.
//
// It is a separate test from the REQ/RSP one because the SNP channel only exists
// on a coherent link: the requester-side control has no SNP to pulse, and this
// one has no requester.
//
// cfg.flitpend_without_valid makes the home raise SNP FLITPEND for one cycle,
// once per RN link, with the link up and before any snoop. Both halves are
// asserted:
//   * no bind may report -- the pulse is permitted;
//   * the snoops that follow must be judged, or a checker that never ran would
//     satisfy the first half just as well.
//
// The second half is now reachable, and it was not before. The home used to
// drive SNP FLITPEND low on its real snoops, so this rule took no passes from
// them and its only evaluation in the whole regression was this control --
// exercised, but THIN. Every snoop is now announced one cycle ahead like any
// other flit, so the rule is judged on ordinary coherent traffic and the THIN
// listing goes away.
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

    // Coherent traffic that actually snoops: RN-F0 takes the line Unique, then
    // RN-F1 reads it, which forces the home to snoop RN-F0. Its job here is to
    // put real snoops on the wire after the pulse, so the rule has well-formed
    // SNP flits to pass. It also proves the pulse left the link usable rather
    // than wedged.
    this.cfg_read_seq(super.hrnf0_rdunique_seq);
    super.hrnf0_rdunique_seq.start(super.tb_env.hrnf0_agent.sequencer);
    void'(super.hrnf0_rdunique_seq.get_responses());

    this.cfg_read_seq(super.hrnf1_rdshared_seq);
    super.hrnf1_rdshared_seq.start(super.tb_env.hrnf1_agent.sequencer);
    void'(super.hrnf1_rdshared_seq.get_responses());

    super.wait_clocks(SETTLE_C);

    pend_fails =
      super.tb_env.hnf_agent.rn_vif[0].check_fail_count[VIP_CHI_CHK_SNP_VALID_REQUIRES_PEND_E];
    snoop_passes =
      super.tb_env.hnf_agent.rn_vif[0].check_pass_count[VIP_CHI_CHK_SNP_VALID_REQUIRES_PEND_E];

    // The pulse is permitted, so nothing may be reported for it.
    if (pend_fails != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s reported %0d time(s) against a FLITPEND pulse that §14.4 explicitly permits",
        super.tc_name, vip_chi_check_name(VIP_CHI_CHK_SNP_VALID_REQUIRES_PEND_E),
        pend_fails))
    end

    // ...and the snoops that followed have to have been judged, or a checker
    // that never ran would satisfy the assertion above just as well.
    if (snoop_passes == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s recorded no passes, so this run says nothing about the rule holding on the snoops the coherent traffic drove",
        super.tc_name, vip_chi_check_name(VIP_CHI_CHK_SNP_VALID_REQUIRES_PEND_E)))
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] a lone SNP FLITPEND was not reported, and the snoops that followed were judged %0d time(s)",
      super.tc_name, snoop_passes), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
