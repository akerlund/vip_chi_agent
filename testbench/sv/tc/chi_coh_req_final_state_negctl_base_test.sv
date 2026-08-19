// ===========================================================================
// chi_coh_req_final_state_negctl_base_test
//
// Negative control for chi_coh_req_retain_base_test. RN-F1 is put back on the
// pre-Table-4-14 behaviour with cfg.rnf_req_final_state_verbatim: its final
// cache state becomes the granted Resp on its own, and the fetched beats
// overwrite whatever it held.
//
// The line is acquired with MakeUnique rather than ReadUnique + make_line_dirty,
// and that choice is the whole scenario. A local store is SILENT: the checker
// cannot see it either, so a shadow built the honest way reads UC and rule D7 --
// which keys off the state the SHADOW believed the snoopee held -- has nothing
// to fire on. MakeUnique is the one path in this VIP that grants an OBSERVABLE
// Unique-Dirty, so it is the only way to give the checker a dirty snoopee to
// have an opinion about. (This is the same reason the transition sweep primes
// its UD from-state with MakeUnique.)
//
//   RN-F1 MakeUnique L        -> UD, observable: driver, shadow and snoop filter
//   make_line_dirty(L, PAT)   -> beats become orig ^ PAT
//   RN-F1 ReadClean L         -> granted CompData_SC
//                                -> RN-F1 wrongly drops to SC and takes the
//                                   fetched beats; its dirty copy is gone
//   RN-F0 ReadShared L        -> HN-F SnpShared(RN-F1)
//                                -> RN-F1, now clean, answers SnpResp with NO
//                                   data -- and the shadow says it held UD
//
// Catalogue rule D7 MUST fire on that last step: a snoopee holding Dirty has to
// hand the dirty data over unless it is keeping it, and this one has done
// neither. That is the whole reason D7 is worth having -- the reported STATE is
// legal (D5 and D6 both pass SC from UD, and the earlier response-form rule
// reads the other direction), so without D7 a silently discarded dirty line
// produces no violation anywhere and surfaces later as stale data with every
// check agreeing.
//
// Non-vacuous by construction: with the fix in place RN-F1 is still UD at the
// snoop, forwards its modified beats, and D7 has nothing to report -- which is
// what the positive test asserts. The induced error is caught + demoted so it
// does not count against the verdict.
//
// Used by:
//   tc_chi_coh_d_req_final_state_negctl    (CHI-D)
//   tc_chi_coh_e_req_final_state_negctl  (wide CHI-E)
// ===========================================================================
class chi_coh_req_final_state_negctl_base_test #(
  vip_chi_cfg_t CFG_P   = CHI_D_CFG_C,
  type          TYPES_T = chi_d_types_t
) extends chi_coherent_base_test #(CFG_P, TYPES_T);

  typedef vip_chi_item #(CFG_P) item_t;

  `uvm_component_param_utils(chi_coh_req_final_state_negctl_base_test #(CFG_P, TYPES_T))

  chi_coherency_negctl_catcher     coh_catcher;
  vip_chi_readclean_seq  #(CFG_P)  hrnf1_rdclean_seq;
  vip_chi_makeunique_seq #(CFG_P)  hrnf1_mu_seq;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // Put RN-F1 -- the requester under test -- back on the verbatim assignment.
  protected virtual function void configure_agent_cfgs();
    super.hrnf1_cfg.rnf_req_final_state_verbatim = 1'b1;
  endfunction

  function void start_of_simulation_phase(input uvm_phase phase);
    super.start_of_simulation_phase(phase);
    this.coh_catcher       = new("coh_violation_catcher");
    this.hrnf1_rdclean_seq = vip_chi_readclean_seq #(CFG_P)::type_id::create("hrnf1_rdclean_seq");
    this.hrnf1_mu_seq      = vip_chi_makeunique_seq #(CFG_P)::type_id::create("hrnf1_mu_seq");
  endfunction

  task run_phase(input uvm_phase phase);

    vip_chi_resp_t rnf1_state;
    item_t::data_t dirty_pattern;

    phase.raise_objection(this);

    super.wait_reset_settle();

    uvm_report_cb::add(null, this.coh_catcher);

    dirty_pattern = {($bits(dirty_pattern) / 8){8'h5A}};

    this.cfg_read_seq(this.hrnf1_mu_seq);
    this.hrnf1_mu_seq.start(super.tb_env.hrnf1_agent.sequencer);
    void'(this.hrnf1_mu_seq.get_responses());

    super.tb_env.hrnf1_agent.rnf_driver.make_line_dirty(
      item_t::addr_t'(WRITE_READ_ADDR_C), dirty_pattern);

    this.cfg_read_seq(this.hrnf1_rdclean_seq);
    this.hrnf1_rdclean_seq.start(super.tb_env.hrnf1_agent.sequencer);
    void'(this.hrnf1_rdclean_seq.get_responses());

    super.wait_clocks(8);

    // The knob did what it says: RN-F1 took the granted SC verbatim. Asserted so
    // a future change that quietly stops honouring the knob turns into a failure
    // here rather than a negative control that silently tests nothing.
    rnf1_state = super.tb_env.hrnf1_agent.rnf_driver.get_cache_state(
                   item_t::addr_t'(WRITE_READ_ADDR_C));
    if (rnf1_state != VIP_CHI_RESP_STATE_SC_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F1 cache 0x%0h, expected the verbatim SC (0x%0h) the negative-control knob induces",
        super.tc_name, rnf1_state, VIP_CHI_RESP_STATE_SC_E))
    end

    // Now make the home snoop it. The shadow still holds UD -- correctly, it
    // applied Table 4-14 -- so the data-less response is the dirty line going
    // missing.
    this.cfg_read_seq(super.hrnf0_rdshared_seq);
    super.hrnf0_rdshared_seq.start(super.tb_env.hrnf0_agent.sequencer);
    void'(super.hrnf0_rdshared_seq.get_responses());

    super.wait_clocks(8);

    uvm_report_cb::delete(null, this.coh_catcher);

    if (!this.coh_catcher.saw_coherency_error) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Checker D did NOT flag the discarded dirty copy -- catalogue rule D7 may be vacuous",
        super.tc_name))
    end

    if (super.tb_env.coh_checker.get_snp_dirty_lost_count() == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] D7 reported no dirty-copy loss, so the coherency error above came from a different rule",
        super.tc_name))
    end

    phase.drop_objection(this);
  endtask
endclass
