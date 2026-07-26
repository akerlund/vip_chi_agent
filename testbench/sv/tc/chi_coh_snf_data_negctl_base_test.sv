// ===========================================================================
// chi_coh_snf_data_negctl_base_test
//
// Negative control for Checker D's end-to-end downstream integrity check -- the
// mandatory anti-vacuity gate for the SN-F package. With hnf_downstream_en=1 AND
// hnf_downstream_corrupt_data=1 the HN-F fetches a cold line from the SN-F but
// relays a CORRUPTED copy to the RN-F, while the checker still observes the
// SN-F's TRUE CompData on the downstream DAT stream:
//   RN-F0 ReadShared L (cold) -> ReadNoSnp -> SN-F CompData = V (checker shadow)
//                              -> HN-F relays ~V to RN-F0        (corrupted)
// The RN-F0 CompData (~V) then mismatches the authoritative downstream value (V),
// so Checker D MUST raise a coherent data-integrity violation. If it stays silent
// the downstream-integrity seed is vacuous (e.g. snf_dat_cc unwired). The induced
// error is caught + demoted so it stays out of the regression error count.
//
// Used by:
//   tc_chi_coh_e_snf_data_negctl  (wide CHI-E)
//   tc_chi_coh_d_snf_data_negctl    (CHI-D)
// ===========================================================================
class chi_coh_snf_data_negctl_base_test #(
  vip_chi_cfg_t CFG_P   = CHI_D_CFG_C,
  type          TYPES_T = chi_d_types_t
) extends chi_coherent_base_test #(CFG_P, TYPES_T);

  typedef vip_chi_item #(CFG_P) item_t;

  `uvm_component_param_utils(chi_coh_snf_data_negctl_base_test #(CFG_P, TYPES_T))

  chi_coherency_negctl_catcher coh_catcher;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  protected virtual function void configure_agent_cfgs();
    super.hnf_cfg.hnf_downstream_en           = 1'b1;
    super.hnf_cfg.hnf_downstream_corrupt_data = 1'b1;
  endfunction

  function void start_of_simulation_phase(input uvm_phase phase);
    super.start_of_simulation_phase(phase);
    this.coh_catcher = new("coh_violation_catcher");
  endfunction


  task run_phase(input uvm_phase phase);

    phase.raise_objection(this);

    super.wait_reset_settle();

    uvm_report_cb::add(null, this.coh_catcher);

    // Cold read -> downstream fetch with a corrupted relay.
    this.cfg_read_seq(super.hrnf0_rdshared_seq);
    super.hrnf0_rdshared_seq.start(super.tb_env.hrnf0_agent.sequencer);
    void'(super.hrnf0_rdshared_seq.get_responses());

    super.wait_clocks(8);

    uvm_report_cb::delete(null, this.coh_catcher);

    if (!this.coh_catcher.saw_coherency_error) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Checker D did NOT flag the corrupted downstream fetch - the integrity seed may be vacuous",
        super.tc_name))
    end

    if (super.tb_env.coh_checker.get_coherent_data_mismatch_count() == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Checker D data-mismatch counter is zero despite the induced corruption",
        super.tc_name))
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] Checker D correctly flagged the corrupted downstream fetch (SN-F negative control passed)",
      super.tc_name), UVM_LOW)

    phase.drop_objection(this);
  endtask
endclass
