// ===========================================================================
// vip_chi_coh_excl_negctl_base_test
//
// Negative control for Checker D's EXCLUSIVE invariant -- the mandatory
// anti-vacuity gate for the LL/SC package. The home is forced to LIE about the
// exclusive result (cfg.hnf_force_excl_success), reporting ExclOkay on an SC
// whose monitor was actually cleared by an intervening store:
//   RN-F0 LL (ReadClean+excl) L  -> ExclOkay, Checker-D shadow reservation set
//   RN-F1 WriteUnique L          -> real monitor + Checker-D shadow cleared
//   RN-F0 SC (CleanUnique+excl) L -> home FORCES ExclOkay despite the cleared
//                                    monitor -> a false "store won"
// Checker D's self-derived shadow saw the intervening store, so an SC reporting
// success with no continuously-valid reservation MUST raise EXCLUSIVE VIOLATION.
// If it does not, the invariant is vacuous (e.g. the RSP stream was never wired
// to the checker) and this test fails. The induced error is caught + demoted so
// it stays out of the regression error count. This is the test that proves the
// RSP-subscription add is load-bearing.
//
// Used by:
//   tc_chi_coh_e_excl_negctl  (wide CHI-E)
//   tc_chi_coh_d_excl_negctl    (CHI-D)
// ===========================================================================
class vip_chi_coh_excl_negctl_base_test #(
  vip_chi_cfg_t CFG_P   = CHI_D_CFG_C,
  type          TYPES_T = chi_d_types_t
) extends vip_chi_coherent_base_test #(CFG_P, TYPES_T);

  typedef vip_chi_item #(CFG_P) item_t;

  `uvm_component_param_utils(vip_chi_coh_excl_negctl_base_test #(CFG_P, TYPES_T))

  vip_chi_coherency_negctl_catcher    coh_catcher;
  vip_chi_excl_load_seq   #(CFG_P) hrnf0_ll_seq;
  vip_chi_excl_store_seq  #(CFG_P) hrnf0_sc_seq;
  vip_chi_writeunique_seq #(CFG_P) hrnf1_wu_seq;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // Force the home to report ExclOkay on every SC regardless of the monitor.
  protected virtual function void configure_agent_cfgs();
    super.hnf_cfg.hnf_force_excl_success = 1'b1;
  endfunction

  function void start_of_simulation_phase(input uvm_phase phase);
    super.start_of_simulation_phase(phase);
    this.coh_catcher  = new("coh_violation_catcher");
    this.hrnf0_ll_seq = vip_chi_excl_load_seq   #(CFG_P)::type_id::create("hrnf0_ll_seq");
    this.hrnf0_sc_seq = vip_chi_excl_store_seq  #(CFG_P)::type_id::create("hrnf0_sc_seq");
    this.hrnf1_wu_seq = vip_chi_writeunique_seq #(CFG_P)::type_id::create("hrnf1_wu_seq");
  endfunction


  task run_phase(input uvm_phase phase);

    phase.raise_objection(this);

    super.wait_reset_settle();

    uvm_report_cb::add(null, this.coh_catcher);

    // RN-F0 exclusive load -> arms the monitor + Checker-D shadow reservation.
    this.cfg_read_seq(this.hrnf0_ll_seq);
    this.hrnf0_ll_seq.start(super.tb_env.hrnf0_agent.sequencer);
    void'(this.hrnf0_ll_seq.get_responses());

    // RN-F1 remote store -> clears the real monitor AND the Checker-D shadow.
    this.cfg_read_seq(this.hrnf1_wu_seq);
    this.hrnf1_wu_seq.start(super.tb_env.hrnf1_agent.sequencer);
    void'(this.hrnf1_wu_seq.get_responses());

    // RN-F0 exclusive store -> the forced home reports ExclOkay anyway (a lie).
    this.cfg_read_seq(this.hrnf0_sc_seq);
    this.hrnf0_sc_seq.start(super.tb_env.hrnf0_agent.sequencer);
    void'(this.hrnf0_sc_seq.get_responses());

    super.wait_clocks(8);

    uvm_report_cb::delete(null, this.coh_catcher);

    if (!this.coh_catcher.saw_coherency_error) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Checker D did NOT flag the false SC success - the exclusive invariant may be vacuous (RSP stream unwired?)",
        super.tc_name))
    end

    if (super.tb_env.coh_checker.get_excl_violation_count() == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Checker D exclusive-violation counter is zero despite the induced false success",
        super.tc_name))
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] Checker D correctly flagged the false SC success (exclusive negative control passed)",
      super.tc_name), UVM_LOW)

    phase.drop_objection(this);
  endtask
endclass
