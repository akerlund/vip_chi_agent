// ===========================================================================
// vip_chi_coh_fwd_data_negctl_base_test
//
// Negative control for Checker D's forwarded-data integrity check -- the
// mandatory anti-vacuity gate for the DCT package. With hnf_enable_snoop_fwd=1
// AND hnf_corrupt_fwd_data=1, the home merges the CORRECT forwarded beats into
// memory / the checker's shadow but relays a CORRUPTED copy to the requester:
//   RN-F0 ReadUnique L    -> UC, data D
//   RN-F1 ReadShared L    -> SnpSharedFwd(RN-F0) -> SnpRespDataFwded(D)
//                            -> checker shadow line_data = D (from the forward)
//                            -> home relays CompData(~D) to RN-F1  [corrupted]
// The requester's forwarded CompData (~D) then mismatches the authoritative
// forwarded data (D) the checker recorded, so Checker D MUST raise a coherency
// data-integrity violation. If it stays silent the fwd-integrity check is vacuous
// (e.g. line_data was never established from SnpRespDataFwded). The induced error
// is caught + demoted so it stays out of the regression error count.
//
// Used by:
//   tc_chi_coh_e_fwd_data_negctl  (wide CHI-E)
//   tc_chi_coh_d_fwd_data_negctl    (CHI-D)
// ===========================================================================
class vip_chi_coh_fwd_data_negctl_base_test #(
  vip_chi_cfg_t CFG_P   = CHI_D_CFG_C,
  type          TYPES_T = chi_d_types_t
) extends vip_chi_coherent_base_test #(CFG_P, TYPES_T);

  typedef vip_chi_item #(CFG_P) item_t;

  `uvm_component_param_utils(vip_chi_coh_fwd_data_negctl_base_test #(CFG_P, TYPES_T))

  vip_chi_coherency_negctl_catcher coh_catcher;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // Enable DCT and corrupt the relayed (forwarded) data on purpose.
  protected virtual function void configure_agent_cfgs();
    super.hnf_cfg.hnf_enable_snoop_fwd  = 1'b1;
    super.hnf_cfg.hnf_corrupt_fwd_data  = 1'b1;
  endfunction

  function void start_of_simulation_phase(input uvm_phase phase);
    super.start_of_simulation_phase(phase);
    this.coh_catcher = new("coh_violation_catcher");
  endfunction


  task run_phase(input uvm_phase phase);

    phase.raise_objection(this);

    super.wait_reset_settle();

    uvm_report_cb::add(null, this.coh_catcher);

    // RN-F0 acquires the line Unique (sole holder with data).
    this.cfg_read_seq(super.hrnf0_rdunique_seq);
    super.hrnf0_rdunique_seq.start(super.tb_env.hrnf0_agent.sequencer);
    void'(super.hrnf0_rdunique_seq.get_responses());

    // RN-F1 ReadShared -> DCT forward; the home relays a corrupted copy.
    this.cfg_read_seq(super.hrnf1_rdshared_seq);
    super.hrnf1_rdshared_seq.start(super.tb_env.hrnf1_agent.sequencer);
    void'(super.hrnf1_rdshared_seq.get_responses());

    super.wait_clocks(8);

    uvm_report_cb::delete(null, this.coh_catcher);

    if (!this.coh_catcher.saw_coherency_error) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Checker D did NOT flag the corrupted forwarded data - the fwd-integrity check may be vacuous",
        super.tc_name))
    end

    if (super.tb_env.coh_checker.get_coherent_data_mismatch_count() == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Checker D data-mismatch counter is zero despite the induced corruption",
        super.tc_name))
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] Checker D correctly flagged the corrupted forward (DCT negative control passed)",
      super.tc_name), UVM_LOW)

    phase.drop_objection(this);
  endtask
endclass
