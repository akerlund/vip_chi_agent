// ===========================================================================
// chi_coh_data_negctl_base_test
//
// Negative control for Checker D's coherent DATA-integrity check. The HN-F is
// put into dirty-merge-corruption mode (cfg.hnf_corrupt_dirty_merge): when a
// dirty snoop forwards SnpRespData, the home drops the data instead of merging
// it, so it completes the requester from STALE memory rather than the forwarded
// value. Checker D observes the forwarded SnpRespData (recording it as the
// line's authoritative data) and then the requester's CompData carrying the
// stale value -- a mismatch it MUST flag. If it does not, the data-integrity
// check has gone vacuous and this test fails. The induced error is caught +
// demoted so it does not count against the regression verdict.
//
// Used by:
//   tc_chi_coh_d_data_negctl    (CHI-D)
//   tc_chi_coh_e_data_negctl  (wide CHI-E)
// ===========================================================================
class chi_coh_data_negctl_base_test #(
  vip_chi_cfg_t CFG_P   = CHI_D_CFG_C,
  type          TYPES_T = chi_d_types_t
) extends chi_coherent_base_test #(CFG_P, TYPES_T);

  typedef vip_chi_item #(CFG_P) item_t;

  `uvm_component_param_utils(chi_coh_data_negctl_base_test #(CFG_P, TYPES_T))

  chi_coherency_negctl_catcher coh_catcher;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // Break coherent data integrity at the home: forward stale data on a dirty snoop.
  protected virtual function void configure_agent_cfgs();
    super.hnf_cfg.hnf_corrupt_dirty_merge = 1'b1;
  endfunction

  function void start_of_simulation_phase(input uvm_phase phase);
    super.start_of_simulation_phase(phase);
    this.coh_catcher = new("coh_data_violation_catcher");
  endfunction


  task run_phase(input uvm_phase phase);

    item_t::data_t dirty_pattern;

    phase.raise_objection(this);

    super.wait_reset_settle();

    uvm_report_cb::add(null, this.coh_catcher);

    dirty_pattern = {($bits(dirty_pattern) / 8){8'h5A}};

    // RN-F0 acquires the line Unique and dirties it (modelled local store).
    this.cfg_read_seq(super.hrnf0_rdunique_seq);
    super.hrnf0_rdunique_seq.start(super.tb_env.hrnf0_agent.sequencer);
    void'(super.hrnf0_rdunique_seq.get_responses());

    super.tb_env.hrnf0_agent.rnf_driver.make_line_dirty(item_t::addr_t'(WRITE_READ_ADDR_C), dirty_pattern);

    // RN-F1 ReadShared forces a dirty forward -- but the home drops the merge, so
    // RN-F1's CompData carries stale data that mismatches the observed SnpRespData.
    this.cfg_read_seq(super.hrnf1_rdshared_seq);
    super.hrnf1_rdshared_seq.start(super.tb_env.hrnf1_agent.sequencer);
    void'(super.hrnf1_rdshared_seq.get_responses());

    super.wait_clocks(8);

    uvm_report_cb::delete(null, this.coh_catcher);

    if (!this.coh_catcher.saw_coherency_error) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Checker D did NOT flag the corrupted dirty forward - data-integrity check may be vacuous",
        super.tc_name))
    end

    if (super.tb_env.coh_checker.get_coherent_data_mismatch_count() == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Checker D data-mismatch counter is zero despite the induced corruption",
        super.tc_name))
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] Checker D correctly flagged the coherent data mismatch (negative control passed)",
      super.tc_name), UVM_LOW)

    phase.drop_objection(this);
  endtask
endclass
