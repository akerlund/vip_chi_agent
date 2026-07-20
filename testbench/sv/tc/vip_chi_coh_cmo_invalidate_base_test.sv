// ===========================================================================
// vip_chi_coh_cmo_invalidate_base_test
//
// Cache-maintenance invalidation at the point of coherence, both variants:
//   * CleanInvalid: RN-F0 and RN-F1 both hold the line Shared; RN-F0 issues
//     CleanInvalid. The home snoops the other holder (SnpCleanInvalid) and the
//     requester invalidates its own copy on completion -> the whole line goes to
//     Invalid everywhere; the home returns an RSP-only Comp (no data).
//   * MakeInvalid: after re-acquiring the line Shared on both RN-Fs, RN-F1
//     issues MakeInvalid (SnpMakeInvalid, no dirty preserve) -> same end state.
// Asserts, for each variant: exactly one (data-less) completion, BOTH RN-F caches
// and BOTH directory ports return to Invalid, a snoop fired, and Checker D stays
// silent (invalidation never breaks the single-writer invariant).
//
// Used by:
//   tc_chi_coh_d_cmo_invalidate    (CHI-D)
//   tc_chi_coh_e_cmo_invalidate  (wide CHI-E)
// ===========================================================================
class vip_chi_coh_cmo_invalidate_base_test #(
  vip_chi_cfg_t CFG_P   = CHI_D_CFG_C,
  type          TYPES_T = chi_d_types_t
) extends vip_chi_coherent_base_test #(CFG_P, TYPES_T);

  typedef vip_chi_item #(CFG_P) item_t;

  `uvm_component_param_utils(vip_chi_coh_cmo_invalidate_base_test #(CFG_P, TYPES_T))

  vip_chi_cleaninvalid_seq #(CFG_P) hrnf0_ci_seq;
  vip_chi_makeinvalid_seq  #(CFG_P) hrnf1_mi_seq;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void start_of_simulation_phase(input uvm_phase phase);
    super.start_of_simulation_phase(phase);
    this.hrnf0_ci_seq = vip_chi_cleaninvalid_seq #(CFG_P)::type_id::create("hrnf0_ci_seq");
    this.hrnf1_mi_seq = vip_chi_makeinvalid_seq  #(CFG_P)::type_id::create("hrnf1_mi_seq");
  endfunction


  // Assert both RN-F caches and both directory ports are Invalid for the line.
  protected function void check_line_invalidated(input string tag);
    if (super.tb_env.hrnf0_agent.rnf_driver.get_cache_state(item_t::addr_t'(WRITE_READ_ADDR_C)) != VIP_CHI_RESP_STATE_I_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s: RN-F0 cache not Invalid after CMO", super.tc_name, tag))
    end
    if (super.tb_env.hrnf1_agent.rnf_driver.get_cache_state(item_t::addr_t'(WRITE_READ_ADDR_C)) != VIP_CHI_RESP_STATE_I_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s: RN-F1 cache not Invalid after CMO", super.tc_name, tag))
    end
    if (super.tb_env.hnf_agent.hnf_driver.get_directory_port_state(item_t::addr_t'(WRITE_READ_ADDR_C), 0) != VIP_CHI_RESP_STATE_I_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s: directory port0 not Invalid after CMO", super.tc_name, tag))
    end
    if (super.tb_env.hnf_agent.hnf_driver.get_directory_port_state(item_t::addr_t'(WRITE_READ_ADDR_C), 1) != VIP_CHI_RESP_STATE_I_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s: directory port1 not Invalid after CMO", super.tc_name, tag))
    end
  endfunction

  task run_phase(input uvm_phase phase);

    item_t ci_rsp[$];
    item_t mi_rsp[$];
    int    snoops_before;

    phase.raise_objection(this);

    super.wait_reset_settle();

    // --- CleanInvalid -------------------------------------------------------
    // Both RN-Fs take the line Shared, then RN-F0 CleanInvalids it.
    this.cfg_read_seq(super.hrnf0_rdshared_seq);
    super.hrnf0_rdshared_seq.start(super.tb_env.hrnf0_agent.sequencer);
    void'(super.hrnf0_rdshared_seq.get_responses());

    this.cfg_read_seq(super.hrnf1_rdshared_seq);
    super.hrnf1_rdshared_seq.start(super.tb_env.hrnf1_agent.sequencer);
    void'(super.hrnf1_rdshared_seq.get_responses());

    snoops_before = super.tb_env.coh_checker.get_snoop_count();

    this.cfg_read_seq(this.hrnf0_ci_seq);
    this.hrnf0_ci_seq.start(super.tb_env.hrnf0_agent.sequencer);
    ci_rsp = this.hrnf0_ci_seq.get_responses();

    super.wait_clocks(8);

    if (ci_rsp.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] CleanInvalid expected 1 completion, got %0d", super.tc_name, ci_rsp.size()))
    end
    if (ci_rsp[0].data.size() != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] CleanInvalid returned %0d data beats, expected 0 (RSP-only Comp)",
        super.tc_name, ci_rsp[0].data.size()))
    end
    if (super.tb_env.coh_checker.get_snoop_count() <= snoops_before) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] CleanInvalid originated no snoop (count %0d -> %0d)",
        super.tc_name, snoops_before, super.tb_env.coh_checker.get_snoop_count()))
    end
    this.check_line_invalidated("CleanInvalid");

    // --- MakeInvalid --------------------------------------------------------
    // Re-acquire the line Shared on both RN-Fs, then RN-F1 MakeInvalids it.
    this.cfg_read_seq(super.hrnf0_rdshared_seq);
    super.hrnf0_rdshared_seq.start(super.tb_env.hrnf0_agent.sequencer);
    void'(super.hrnf0_rdshared_seq.get_responses());

    this.cfg_read_seq(super.hrnf1_rdshared_seq);
    super.hrnf1_rdshared_seq.start(super.tb_env.hrnf1_agent.sequencer);
    void'(super.hrnf1_rdshared_seq.get_responses());

    snoops_before = super.tb_env.coh_checker.get_snoop_count();

    this.cfg_read_seq(this.hrnf1_mi_seq);
    this.hrnf1_mi_seq.start(super.tb_env.hrnf1_agent.sequencer);
    mi_rsp = this.hrnf1_mi_seq.get_responses();

    super.wait_clocks(8);

    if (mi_rsp.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] MakeInvalid expected 1 completion, got %0d", super.tc_name, mi_rsp.size()))
    end
    if (mi_rsp[0].data.size() != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] MakeInvalid returned %0d data beats, expected 0 (RSP-only Comp)",
        super.tc_name, mi_rsp[0].data.size()))
    end
    if (super.tb_env.coh_checker.get_snoop_count() <= snoops_before) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] MakeInvalid originated no snoop (count %0d -> %0d)",
        super.tc_name, snoops_before, super.tb_env.coh_checker.get_snoop_count()))
    end
    this.check_line_invalidated("MakeInvalid");

    if (super.tb_env.coh_checker.get_multi_owner_count() != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %0d coherency violations on legal CMO invalidation",
        super.tc_name, super.tb_env.coh_checker.get_multi_owner_count()))
    end

    phase.drop_objection(this);
  endtask
endclass
