// ===========================================================================
// chi_coh_snp_field_negctl_base_test
//
// Negative control for the three per-opcode SNP field rules:
// CHI_SNP_FWD_FIELDS_ZERO, CHI_SNP_RET_TO_SRC_LEGAL and
// CHI_SNP_DO_NOT_GO_TO_SD_LEGAL. All three landed as regression guards with
// hundreds of passes and no way to make them fail, and a rule nobody has seen
// fail is a rule nobody has tested.
//
// One snoop provokes all three, which is not a shortcut -- SnpCleanInvalid is in
// all three of the specification's sets at once:
//
//   * it is not a Forward type, so FwdNID must be zero (E 13.10.5 / 13.10.16)
//   * it is named in E 4.9 / D 4.9's RetToSrc must-be-zero list
//   * it is named in E 13.10.35's DoNotGoToSD must-be-one list
//
// A CleanInvalid from RN-F0, on a line RN-F1 holds Shared, makes the home send
// exactly that snoop. The three cfg knobs each corrupt one field of it and each
// fires once per port, so every rule sees exactly one violation.
//
// Three corruptions on one flit would normally be the thing this file's siblings
// warn against -- "a control that breaks two rules at once cannot show which of
// them is being exercised". What makes it sound here is that the three are
// different FIELDS judged by different rules, and the test closes by requiring
// that NO other check in the registry recorded a failure. That is a stronger
// statement than three separate single-field tests would each make: it says the
// three corruptions trip exactly the three intended rules and nothing else.
//
// Both vantages are asserted. The SNP checker is bound to both ends of every
// coherent link, so the home's copy of the rule (judging what it SENT) and the
// snoopee's (judging what it RECEIVED) must both report -- one end reporting
// while the other stays quiet would mean a rule that only works in one
// direction, which against a real DUT is the difference between catching its
// snoop and generating one.
//
// Used by:
//   tc_chi_coh_e_snp_field_negctl  (wide CHI-E)
//
// CHI-E only, and that is the point rather than a limitation. D 12.9.32 has no
// DoNotGoToSD must-be-one list, so under Issue D the cleared bit is CONFORMANT
// and the rule is right to stay quiet -- there is nothing to provoke.
// ===========================================================================
class chi_coh_snp_field_negctl_base_test #(
  vip_chi_cfg_t CFG_P   = CHI_E_WIDE_CFG_C,
  type          TYPES_T = chi_e_wide_types_t
) extends chi_coherent_base_test #(CFG_P, TYPES_T);

  typedef vip_chi_item #(CFG_P) item_t;

  `uvm_component_param_utils(chi_coh_snp_field_negctl_base_test #(CFG_P, TYPES_T))

  vip_chi_cleaninvalid_seq #(CFG_P) hrnf0_ci_seq;

  localparam int SETTLE_C = 20;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void start_of_simulation_phase(input uvm_phase phase);
    super.start_of_simulation_phase(phase);
    this.hrnf0_ci_seq = vip_chi_cleaninvalid_seq #(CFG_P)::type_id::create("hrnf0_ci_seq");
  endfunction

  protected virtual function void configure_agent_cfgs();
    super.hnf_cfg.hnf_snp_fwd_fields_negctl       = 1'b1;
    super.hnf_cfg.hnf_snp_ret_to_src_negctl       = 1'b1;
    super.hnf_cfg.hnf_snp_do_not_go_to_sd_negctl  = 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Suppress the report, keep the count. OFF still evaluates and still tallies,
  // so the provoked failures stay visible in the end-of-test table and in the
  // sweep's provoked list rather than being silenced.
  // ---------------------------------------------------------------------------
  protected function void waive(input vip_chi_check_id_t id);
    super.tb_env.hrnf0_agent.vif.check_severity[id] = VIP_CHI_CHK_SEV_OFF_E;
    super.tb_env.hrnf1_agent.vif.check_severity[id] = VIP_CHI_CHK_SEV_OFF_E;
    super.tb_env.hnf_agent.rn_vif[0].check_severity[id] = VIP_CHI_CHK_SEV_OFF_E;
    super.tb_env.hnf_agent.rn_vif[1].check_severity[id] = VIP_CHI_CHK_SEV_OFF_E;
  endfunction

  // ---------------------------------------------------------------------------
  // The rule must have failed at the sending end AND at the receiving end. The
  // snoop goes to whichever port holds the line, so the counts are summed across
  // ports rather than pinned to one -- what is under test is the vantage, not
  // which RN-F happened to be the snoopee.
  // ---------------------------------------------------------------------------
  protected function void require_provoked(input vip_chi_check_id_t id);

    int unsigned sent_fails;
    int unsigned recv_fails;

    sent_fails = super.tb_env.hnf_agent.rn_vif[0].check_fail_count[id] +
                 super.tb_env.hnf_agent.rn_vif[1].check_fail_count[id];
    recv_fails = super.tb_env.hrnf0_agent.vif.check_fail_count[id] +
                 super.tb_env.hrnf1_agent.vif.check_fail_count[id];

    if (sent_fails != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s reported %0d time(s) at the sending end, expected exactly 1",
        super.tc_name, vip_chi_check_name(id), sent_fails))
    end

    if (recv_fails != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s reported %0d time(s) at the receiving end, expected exactly 1 -- a rule that fires only where the flit was sent does not catch a DUT's snoop",
        super.tc_name, vip_chi_check_name(id), recv_fails))
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] %s provoked once at each vantage", super.tc_name,
      vip_chi_check_name(id)), UVM_LOW)
  endfunction

  // ---------------------------------------------------------------------------
  // Nothing else in the registry may have failed. This is what keeps three
  // corruptions on one flit an honest control.
  // ---------------------------------------------------------------------------
  protected function void require_nothing_else_fired();

    for (int unsigned i = 0; i < int'(VIP_CHI_CHK_NUM_E); i++) begin

      vip_chi_check_id_t id = vip_chi_check_id_t'(i);
      int unsigned       total;

      if ((id == VIP_CHI_CHK_SNP_FWD_FIELDS_ZERO_E) ||
          (id == VIP_CHI_CHK_SNP_RET_TO_SRC_LEGAL_E) ||
          (id == VIP_CHI_CHK_SNP_DO_NOT_GO_TO_SD_LEGAL_E)) begin
        continue;
      end

      total = super.tb_env.hrnf0_agent.vif.check_fail_count[id] +
              super.tb_env.hrnf1_agent.vif.check_fail_count[id] +
              super.tb_env.hnf_agent.rn_vif[0].check_fail_count[id] +
              super.tb_env.hnf_agent.rn_vif[1].check_fail_count[id];

      if (total != 0) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] %s also failed %0d time(s): this control is exercising more than the three field rules it is about",
          super.tc_name, vip_chi_check_name(id), total))
      end
    end
  endfunction

  task run_phase(input uvm_phase phase);

    item_t ci_rsp[$];

    phase.raise_objection(this);

    this.waive(VIP_CHI_CHK_SNP_FWD_FIELDS_ZERO_E);
    this.waive(VIP_CHI_CHK_SNP_RET_TO_SRC_LEGAL_E);
    this.waive(VIP_CHI_CHK_SNP_DO_NOT_GO_TO_SD_LEGAL_E);

    super.wait_reset_settle();

    // RN-F1 takes the line Shared so the CleanInvalid has somebody to snoop.
    this.cfg_read_seq(super.hrnf1_rdshared_seq);
    super.hrnf1_rdshared_seq.start(super.tb_env.hrnf1_agent.sequencer);
    void'(super.hrnf1_rdshared_seq.get_responses());

    this.cfg_read_seq(this.hrnf0_ci_seq);
    this.hrnf0_ci_seq.start(super.tb_env.hrnf0_agent.sequencer);
    ci_rsp = this.hrnf0_ci_seq.get_responses();

    super.wait_clocks(SETTLE_C);

    if (ci_rsp.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] CleanInvalid returned %0d completions, expected 1 -- the snoop this control needs may not have been sent",
        super.tc_name, ci_rsp.size()))
    end

    this.require_provoked(VIP_CHI_CHK_SNP_FWD_FIELDS_ZERO_E);
    this.require_provoked(VIP_CHI_CHK_SNP_RET_TO_SRC_LEGAL_E);
    this.require_provoked(VIP_CHI_CHK_SNP_DO_NOT_GO_TO_SD_LEGAL_E);
    this.require_nothing_else_fired();

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] one SnpCleanInvalid with three corrupted fields provoked exactly three rules, at both vantages",
      super.tc_name), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
