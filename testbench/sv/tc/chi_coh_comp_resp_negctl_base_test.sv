// ===========================================================================
// chi_coh_comp_resp_negctl_base_test
//
// Negative control for CHI_RSP_COMP_RESP_LEGAL -- the Resp encodings a Comp
// response is permitted to carry, IHI 0050 E Table 4-7 / D Table 4-5.
//
// The injection is the defect this VIP actually shipped: cfg.hnf_comp_resp_negctl
// puts the home back on Comp_UD_PD for a MakeUnique completion, where the tables
// give Comp_UC.
//
// Its value as a control is that THE SAME INJECTION IS LEGAL UNDER ONE ISSUE AND
// NOT THE OTHER, and both answers are asserted:
//
//   Issue E  Table 4-7 lists Comp_UD_PD (0b110) among the four permitted
//            encodings, so the flit is well formed and the per-flit rule must
//            stay SILENT -- and must record a PASS, since a rule that declined
//            to evaluate would also be silent.
//   Issue D  Table 4-5 permits exactly Comp_I, Comp_UC and Comp_SC. It gives
//            0b110 no meaning on a Comp at all, so the rule must FIRE.
//
// A control that reported on both cuts would pass equally well against a rule
// that ignored the issue and checked E's larger set everywhere -- which would
// let the original CHI-D defect straight through. The asymmetry is the check.
//
// THE COHERENCY CHECKER REPORTS ON BOTH CUTS, and that is not collateral to be
// absorbed but the division of labour made visible. Table 4-19 gives MakeUnique
// one completion response in either issue, so the request-correlated rule
// objects wherever the encoding rule stands down. The two are asserted
// separately: one judges the flit, the other judges the flit against the request
// that caused it, and only the second can be issue-independent here.
//
// Used by:
//   tc_chi_coh_d_comp_resp_negctl    (CHI-D)
//   tc_chi_coh_e_comp_resp_negctl  (wide CHI-E)
// ===========================================================================
class chi_coh_comp_resp_negctl_base_test #(
  vip_chi_cfg_t CFG_P   = CHI_D_CFG_C,
  type          TYPES_T = chi_d_types_t
) extends chi_coherent_base_test #(CFG_P, TYPES_T);

  typedef vip_chi_item #(CFG_P) item_t;

  `uvm_component_param_utils(chi_coh_comp_resp_negctl_base_test #(CFG_P, TYPES_T))

  localparam int SETTLE_C = 20;

  // Whether this cut's dataless-completion table lists Comp_UD_PD, and therefore
  // whether the per-flit rule must fire. Overridden to 0 on the CHI-E cut.
  protected bit expect_sva_report_c = 1'b1;

  chi_coherency_negctl_catcher   coh_catcher;
  vip_chi_makeunique_seq #(CFG_P) hrnf0_mu_seq;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void start_of_simulation_phase(input uvm_phase phase);
    super.start_of_simulation_phase(phase);
    this.coh_catcher  = new("coh_comp_resp_catcher");
    this.hrnf0_mu_seq = vip_chi_makeunique_seq #(CFG_P)::type_id::create("hrnf0_mu_seq");
  endfunction

  protected virtual function void configure_agent_cfgs();
    super.hnf_cfg.hnf_comp_resp_negctl = 1'b1;
  endfunction

  // Suppress the report, keep the count. OFF still evaluates and still tallies,
  // so a provoked failure stays visible in the end-of-test table and in the
  // sweep's provoked list rather than being silenced. Applied only on the cut
  // that actually breaks the rule -- waiving it on the cut where the encoding is
  // legal would hide a rule that fired when it should not have.
  protected function void waive(input vip_chi_check_id_t id);
    super.tb_env.hrnf0_agent.vif.check_severity[id] = VIP_CHI_CHK_SEV_OFF_E;
    super.tb_env.hrnf1_agent.vif.check_severity[id] = VIP_CHI_CHK_SEV_OFF_E;
    super.tb_env.hnf_agent.rn_vif[0].check_severity[id] = VIP_CHI_CHK_SEV_OFF_E;
    super.tb_env.hnf_agent.rn_vif[1].check_severity[id] = VIP_CHI_CHK_SEV_OFF_E;
  endfunction

  protected function int unsigned sent_fails(input vip_chi_check_id_t id);
    return super.tb_env.hnf_agent.rn_vif[0].check_fail_count[id] +
           super.tb_env.hnf_agent.rn_vif[1].check_fail_count[id];
  endfunction

  protected function int unsigned recv_fails(input vip_chi_check_id_t id);
    return super.tb_env.hrnf0_agent.vif.check_fail_count[id] +
           super.tb_env.hrnf1_agent.vif.check_fail_count[id];
  endfunction

  protected function int unsigned total_passes(input vip_chi_check_id_t id);
    return super.tb_env.hnf_agent.rn_vif[0].check_pass_count[id] +
           super.tb_env.hnf_agent.rn_vif[1].check_pass_count[id] +
           super.tb_env.hrnf0_agent.vif.check_pass_count[id] +
           super.tb_env.hrnf1_agent.vif.check_pass_count[id];
  endfunction

  task run_phase(input uvm_phase phase);

    item_t       mu_rsp[$];
    int unsigned dataless_before;
    int unsigned sent;
    int unsigned recv;
    int unsigned passes;

    phase.raise_objection(this);

    if (this.expect_sva_report_c) begin
      this.waive(VIP_CHI_CHK_RSP_COMP_RESP_LEGAL_E);
    end

    super.wait_reset_settle();

    uvm_report_cb::add(null, this.coh_catcher);

    dataless_before = super.tb_env.coh_checker.get_bad_dataless_resp_count();

    this.cfg_read_seq(this.hrnf0_mu_seq);
    this.hrnf0_mu_seq.start(super.tb_env.hrnf0_agent.sequencer);
    mu_rsp = this.hrnf0_mu_seq.get_responses();

    super.wait_clocks(SETTLE_C);

    uvm_report_cb::delete(null, this.coh_catcher);

    if (mu_rsp.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] MakeUnique returned %0d completions, expected 1 -- the flit this control corrupts may never have been sent",
        super.tc_name, mu_rsp.size()))
    end

    // The knob did what it says, read off the completion the requester received.
    if (mu_rsp[0].rsp_resp != VIP_CHI_RESP_STATE_UP_PD_DIRTY_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the completion carried Resp 0x%0h, not the injected Comp_UD_PD (0x%0h) -- the control is not reaching the home",
        super.tc_name, mu_rsp[0].rsp_resp, VIP_CHI_RESP_STATE_UP_PD_DIRTY_E))
    end

    sent   = this.sent_fails(VIP_CHI_CHK_RSP_COMP_RESP_LEGAL_E);
    recv   = this.recv_fails(VIP_CHI_CHK_RSP_COMP_RESP_LEGAL_E);
    passes = this.total_passes(VIP_CHI_CHK_RSP_COMP_RESP_LEGAL_E);

    if (this.expect_sva_report_c) begin
      // Both vantages, because which end of a link sees a completion depends on
      // where the bind sits: a rule that fires only where the flit was sent does
      // not catch a third-party completer.
      if ((sent != 1) || (recv != 1)) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] Comp_UD_PD on a CHI-D completion was reported %0d time(s) at the sending end and %0d at the receiving end, expected exactly 1 at each -- D Table 4-5 gives that encoding no meaning on a Comp",
          super.tc_name, sent, recv))
      end
    end
    else begin
      if ((sent != 0) || (recv != 0)) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] the rule reported %0d/%0d time(s) on a cut where E Table 4-7 LISTS Comp_UD_PD: it is reading a fixed set rather than the issue's own table",
          super.tc_name, sent, recv))
      end
      // Silence is not enough on this cut -- a rule that never evaluated is
      // silent too, and would pass the assertion above while letting the CHI-D
      // half of the rule rot unnoticed.
      if (passes == 0) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] the rule recorded no passes on a completion it should have judged and accepted -- it may not have evaluated at all",
          super.tc_name))
      end
    end

    // The request-correlated rule objects on BOTH cuts, because Table 4-19 gives
    // MakeUnique one completion response in either issue. Asserted rather than
    // absorbed: it is what shows the encoding rule and the row rule are judging
    // different things about the same flit.
    if (super.tb_env.coh_checker.get_bad_dataless_resp_count() == dataless_before) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the coherency checker did not object to Comp_UD_PD on a MakeUnique, which Table 4-19 forbids in both issues",
        super.tc_name))
    end

    if (!this.coh_catcher.saw_coherency_error) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] no coherency violation was reported at all", super.tc_name))
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] Comp_UD_PD on a MakeUnique: the encoding rule reported %0d/%0d (expected %0s) over %0d pass(es), and the row rule objected on both cuts",
      super.tc_name, sent, recv,
      this.expect_sva_report_c ? "1/1" : "0/0", passes), UVM_LOW)

    phase.drop_objection(this);
  endtask
endclass
