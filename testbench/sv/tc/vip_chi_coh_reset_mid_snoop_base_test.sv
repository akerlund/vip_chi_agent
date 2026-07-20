// ===========================================================================
// vip_chi_coh_reset_mid_snoop_base_test
//
// Reset teardown of a live coherent subsystem. First a snoop round-trip
// populates real coherent state on every layer:
//   RN-F0 ReadShared L  -> SC ; RN-F1 ReadUnique L -> SnpUnique(RN-F0) -> RN-F1 UC
// so the HN-F directory, both RN-F caches, and Checker D's self-derived shadow
// all hold non-trivial state and at least one snoop has fired.
//
// A reset pulse is then driven across the whole coherent topology. The test
// asserts the teardown is clean -- RN-F caches flushed to Invalid, HN-F
// directory flushed to Invalid on both ports, and the coherency shadow reset to
// zero counts -- and that the subsystem recovers: a fresh coherent read after
// reset succeeds and lands SC.
//
// Used by:
//   tc_chi_coh_e_reset_mid_snoop  (wide CHI-E)
//   tc_chi_coh_d_reset_mid_snoop    (CHI-D)
// ===========================================================================
class vip_chi_coh_reset_mid_snoop_base_test #(
  vip_chi_cfg_t CFG_P   = CHI_D_CFG_C,
  type          TYPES_T = chi_d_types_t
) extends vip_chi_coherent_base_test #(CFG_P, TYPES_T);

  typedef vip_chi_item #(CFG_P) item_t;

  `uvm_component_param_utils(vip_chi_coh_reset_mid_snoop_base_test #(CFG_P, TYPES_T))

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction


  task run_phase(input uvm_phase phase);

    item_t shared_rsp[$];
    item_t unique_rsp[$];
    item_t recov_rsp[$];

    phase.raise_objection(this);

    super.wait_reset_settle();

    // Establish coherent state, including a completed snoop round-trip.
    this.cfg_read_seq(super.hrnf0_rdshared_seq, item_t::addr_t'(WRITE_READ_ADDR_C));
    super.hrnf0_rdshared_seq.start(super.tb_env.hrnf0_agent.sequencer);
    shared_rsp = super.hrnf0_rdshared_seq.get_responses();

    this.cfg_read_seq(super.hrnf1_rdunique_seq, item_t::addr_t'(WRITE_READ_ADDR_C));
    super.hrnf1_rdunique_seq.start(super.tb_env.hrnf1_agent.sequencer);
    unique_rsp = super.hrnf1_rdunique_seq.get_responses();

    if ((shared_rsp.size() != 1) || (unique_rsp.size() != 1)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] setup expected 1+1 responses, got %0d/%0d",
        super.tc_name, shared_rsp.size(), unique_rsp.size()))
    end

    // Pre-reset sanity: a snoop fired and the directory tracks RN-F1's ownership.
    if (super.tb_env.coh_checker.get_snoop_count() == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] no snoop fired before reset -- state not established", super.tc_name))
    end
    if (super.tb_env.hnf_agent.hnf_driver.get_directory_port_state(item_t::addr_t'(WRITE_READ_ADDR_C), 1)
          != VIP_CHI_RESP_STATE_UC_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] directory port1 not UC before reset", super.tc_name))
    end

    // Pulse reset across the coherent topology and resync.
    super.tb_cfg.request_reset_pulse(4);
    @(negedge super.tb_env.hrnf0_agent.vif.rst_n);
    @(posedge super.tb_env.hrnf0_agent.vif.rst_n);
    super.wait_clocks(8);

    // Teardown must be clean: RN-F caches Invalid, HN-F directory Invalid on both
    // ports, and the checker's self-derived shadow reset to zero counts.
    if (super.tb_env.hrnf0_agent.rnf_driver.get_cache_state(item_t::addr_t'(WRITE_READ_ADDR_C))
          != VIP_CHI_RESP_STATE_I_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F0 cache not flushed to I after reset", super.tc_name))
    end
    if (super.tb_env.hrnf1_agent.rnf_driver.get_cache_state(item_t::addr_t'(WRITE_READ_ADDR_C))
          != VIP_CHI_RESP_STATE_I_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F1 cache not flushed to I after reset", super.tc_name))
    end
    if (super.tb_env.hnf_agent.hnf_driver.get_directory_port_state(item_t::addr_t'(WRITE_READ_ADDR_C), 0)
          != VIP_CHI_RESP_STATE_I_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] directory port0 not flushed to I after reset", super.tc_name))
    end
    if (super.tb_env.hnf_agent.hnf_driver.get_directory_port_state(item_t::addr_t'(WRITE_READ_ADDR_C), 1)
          != VIP_CHI_RESP_STATE_I_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] directory port1 not flushed to I after reset", super.tc_name))
    end
    if ((super.tb_env.coh_checker.get_snoop_count() != 0) ||
        (super.tb_env.coh_checker.get_completion_count() != 0)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] coherency shadow not flushed (snoops=%0d completions=%0d)",
        super.tc_name, super.tb_env.coh_checker.get_snoop_count(),
        super.tb_env.coh_checker.get_completion_count()))
    end

    // Recovery: a fresh coherent read after reset succeeds and lands SC.
    this.cfg_read_seq(super.hrnf0_rdshared_seq, item_t::addr_t'(WRITE_READ_ADDR_C));
    super.hrnf0_rdshared_seq.start(super.tb_env.hrnf0_agent.sequencer);
    recov_rsp = super.hrnf0_rdshared_seq.get_responses();

    if ((recov_rsp.size() != 1) || (recov_rsp[0].rsp_resp != VIP_CHI_RESP_STATE_SC_E)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] post-reset recovery read: %0d responses, state 0x%0h (expected 1 x SC)",
        super.tc_name, recov_rsp.size(),
        (recov_rsp.size() > 0) ? recov_rsp[0].rsp_resp : VIP_CHI_RESP_STATE_I_E))
    end
    if (super.tb_env.hrnf0_agent.rnf_driver.get_cache_state(item_t::addr_t'(WRITE_READ_ADDR_C))
          != VIP_CHI_RESP_STATE_SC_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F0 cache not SC after post-reset recovery read", super.tc_name))
    end

    phase.drop_objection(this);
  endtask
endclass
