// ===========================================================================
// chi_coh_negctl_base_test
//
// Negative control for Checker D (coherency invariants). The HN-F is put into
// snoop-suppression mode (cfg.hnf_suppress_snoops), so it grants coherent reads
// WITHOUT invalidating the other holders -- a deliberate coherency break. Two
// RN-F then ReadUnique the SAME line: with no intervening invalidate they both
// end up Unique owners, which Checker D's single-writer invariant MUST flag. If
// it does not, the checker has gone vacuous (disabled / disconnected) and this
// test fails. The induced error is caught + demoted so it does not count against
// the regression verdict.
//
// Used by:
//   tc_chi_coh_e_negctl  (wide CHI-E)
//   tc_chi_coh_d_negctl    (CHI-D)
// ===========================================================================
class chi_coh_negctl_base_test #(
  vip_chi_cfg_t CFG_P   = CHI_D_CFG_C,
  type          TYPES_T = chi_d_types_t
) extends chi_coherent_base_test #(CFG_P, TYPES_T);

  typedef vip_chi_item #(CFG_P) item_t;

  `uvm_component_param_utils(chi_coh_negctl_base_test #(CFG_P, TYPES_T))

  chi_coherency_negctl_catcher coh_catcher;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  // Break coherency at the home: grant unique without snoop-invalidating others.
  // ---------------------------------------------------------------------------
  protected virtual function void configure_agent_cfgs();
    super.hnf_cfg.hnf_suppress_snoops = 1'b1;
  endfunction

  function void start_of_simulation_phase(input uvm_phase phase);
    super.start_of_simulation_phase(phase);
    this.coh_catcher = new("coh_violation_catcher");
  endfunction


  task run_phase(input uvm_phase phase);

    phase.raise_objection(this);

    super.wait_reset_settle();

    uvm_report_cb::add(null, this.coh_catcher);

    // RN-F0 acquires the line Unique.
    this.cfg_read_seq(super.hrnf0_rdunique_seq);
    super.hrnf0_rdunique_seq.start(super.tb_env.hrnf0_agent.sequencer);
    void'(super.hrnf0_rdunique_seq.get_responses());

    // RN-F1 ReadUniques the SAME line. Snoops are suppressed, so RN-F0 is never
    // invalidated -> two Unique owners -> Checker D must fire.
    this.cfg_read_seq(super.hrnf1_rdunique_seq);
    super.hrnf1_rdunique_seq.start(super.tb_env.hrnf1_agent.sequencer);
    void'(super.hrnf1_rdunique_seq.get_responses());

    super.wait_clocks(8);

    uvm_report_cb::delete(null, this.coh_catcher);

    if (!this.coh_catcher.saw_coherency_error) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Checker D did NOT flag the duplicate Unique owner - it may be vacuous or disconnected",
        super.tc_name))
    end

    if (super.tb_env.coh_checker.get_multi_owner_count() == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Checker D multi-owner counter is zero despite the induced violation",
        super.tc_name))
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] Checker D correctly flagged the duplicate Unique owner (negative control passed)",
      super.tc_name), UVM_LOW)

    phase.drop_objection(this);
  endtask
endclass
