// ===========================================================================
// tc_chi_coh_e_cmo_negctl
//
// Negative control for Checker D's single-writer invariant, exercised through the
// new MakeReadUnique unique-acquire at CHI-E (MakeReadUnique is a CHI-E-only 7-bit
// opcode). The HN-F is put into snoop-suppression mode (hnf_suppress_snoops), so a
// MakeReadUnique grants Unique WITHOUT invalidating the existing Unique holder:
//   RN-F0 ReadUnique L     -> UC
//   RN-F1 MakeReadUnique L -> (snoop suppressed) grants UC without invalidating
//                             RN-F0 -> two Unique owners of one line
// Checker D's multi-owner invariant MUST fire; if it does not, MakeReadUnique's
// completion is not feeding the shadow (vacuous) and this test fails. The induced
// error is caught + demoted. Proves MakeReadUnique is tracked by the same
// single-writer check as ReadUnique, at CHI-E flit width.
// ===========================================================================
class tc_chi_coh_e_cmo_negctl extends vip_chi_coherent_e_base_test;

  typedef vip_chi_item #(CHI_E_WIDE_CFG_C) item_t;

  `uvm_component_utils(tc_chi_coh_e_cmo_negctl)

  vip_chi_coherency_negctl_catcher        coh_catcher;
  vip_chi_makereadunique_seq #(CHI_E_WIDE_CFG_C) hrnf1_mru_seq;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  protected virtual function void configure_agent_cfgs();
    super.hnf_cfg.hnf_suppress_snoops = 1'b1;
  endfunction

  function void start_of_simulation_phase(input uvm_phase phase);
    super.start_of_simulation_phase(phase);
    this.coh_catcher   = new("coh_violation_catcher");
    this.hrnf1_mru_seq = vip_chi_makereadunique_seq #(CHI_E_WIDE_CFG_C)::type_id::create("hrnf1_mru_seq");
  endfunction


  task run_phase(input uvm_phase phase);

    phase.raise_objection(this);

    @(posedge super.tb_env.hrnf0_agent.vif.rst_n);
    super.wait_clocks(4);

    uvm_report_cb::add(null, this.coh_catcher);

    this.cfg_read_seq(super.hrnf0_rdunique_seq);
    super.hrnf0_rdunique_seq.start(super.tb_env.hrnf0_agent.sequencer);
    void'(super.hrnf0_rdunique_seq.get_responses());

    this.cfg_read_seq(this.hrnf1_mru_seq);
    this.hrnf1_mru_seq.start(super.tb_env.hrnf1_agent.sequencer);
    void'(this.hrnf1_mru_seq.get_responses());

    super.wait_clocks(8);

    uvm_report_cb::delete(null, this.coh_catcher);

    if (!this.coh_catcher.saw_coherency_error) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Checker D did NOT flag the duplicate Unique owner on MakeReadUnique - it may be vacuous",
        super.tc_name))
    end

    if (super.tb_env.coh_checker.get_multi_owner_count() == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Checker D multi-owner counter is zero despite the induced violation",
        super.tc_name))
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] Checker D correctly flagged the MakeReadUnique duplicate owner (negative control passed)",
      super.tc_name), UVM_LOW)

    phase.drop_objection(this);
  endtask
endclass
