// ===========================================================================
// chi_coh_writeback_evict_base_test
//
// Coherent eviction to the home over both eviction paths:
//   * WriteBackFull: RN-F0 acquires a line Unique then writes it back. The home
//     grants a DBID (CompDBIDResp), collects the CopyBackWrData into memory, and
//     clears RN-F0's directory ownership; RN-F0 ends Invalid.
//   * Evict: RN-F1 acquires the line Shared then Evicts it. The home returns a
//     plain Comp (no data) and clears RN-F1's directory ownership; RN-F1 ends
//     Invalid.
// Asserts both directory ports and both RN-F cache states return to Invalid, and
// Checker D stays silent (evictions never break the single-writer invariant).
//
// Used by:
//   tc_chi_coh_e_writeback_evict  (wide CHI-E)
//   tc_chi_coh_d_writeback_evict    (CHI-D)
// ===========================================================================
class chi_coh_writeback_evict_base_test #(
  vip_chi_cfg_t CFG_P   = CHI_D_CFG_C,
  type          TYPES_T = chi_d_types_t
) extends chi_coherent_base_test #(CFG_P, TYPES_T);

  typedef vip_chi_item #(CFG_P) item_t;

  `uvm_component_param_utils(chi_coh_writeback_evict_base_test #(CFG_P, TYPES_T))

  vip_chi_writeback_seq #(CFG_P) hrnf0_wb_seq;
  vip_chi_evict_seq     #(CFG_P) hrnf1_ev_seq;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void start_of_simulation_phase(input uvm_phase phase);
    super.start_of_simulation_phase(phase);
    this.hrnf0_wb_seq = vip_chi_writeback_seq #(CFG_P)::type_id::create("hrnf0_wb_seq");
    this.hrnf1_ev_seq = vip_chi_evict_seq     #(CFG_P)::type_id::create("hrnf1_ev_seq");
  endfunction


  task run_phase(input uvm_phase phase);

    item_t wb_rsp[$];
    item_t ev_rsp[$];

    phase.raise_objection(this);

    super.wait_reset_settle();

    // --- WriteBackFull path -------------------------------------------------
    // RN-F0 acquires the line Unique, then writes it back to the home.
    this.cfg_read_seq(super.hrnf0_rdunique_seq);
    super.hrnf0_rdunique_seq.start(super.tb_env.hrnf0_agent.sequencer);
    void'(super.hrnf0_rdunique_seq.get_responses());

    this.cfg_read_seq(this.hrnf0_wb_seq);
    this.hrnf0_wb_seq.start(super.tb_env.hrnf0_agent.sequencer);
    wb_rsp = this.hrnf0_wb_seq.get_responses();

    super.wait_clocks(8);

    if (wb_rsp.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] expected 1 writeback response, got %0d", super.tc_name, wb_rsp.size()))
    end

    if (super.tb_env.hnf_agent.hnf_driver.get_directory_port_state(item_t::addr_t'(WRITE_READ_ADDR_C), 0)
        != VIP_CHI_RESP_STATE_I_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] directory port0 not Invalid after WriteBackFull", super.tc_name))
    end
    if (super.tb_env.hrnf0_agent.rnf_driver.get_cache_state(item_t::addr_t'(WRITE_READ_ADDR_C))
        != VIP_CHI_RESP_STATE_I_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F0 cache not Invalid after WriteBackFull", super.tc_name))
    end

    // --- Evict path ---------------------------------------------------------
    // RN-F1 acquires the line Shared, then Evicts it (RSP-only).
    this.cfg_read_seq(super.hrnf1_rdshared_seq);
    super.hrnf1_rdshared_seq.start(super.tb_env.hrnf1_agent.sequencer);
    void'(super.hrnf1_rdshared_seq.get_responses());

    this.cfg_read_seq(this.hrnf1_ev_seq);
    this.hrnf1_ev_seq.start(super.tb_env.hrnf1_agent.sequencer);
    ev_rsp = this.hrnf1_ev_seq.get_responses();

    super.wait_clocks(8);

    if (ev_rsp.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] expected 1 evict response, got %0d", super.tc_name, ev_rsp.size()))
    end

    if (super.tb_env.hnf_agent.hnf_driver.get_directory_port_state(item_t::addr_t'(WRITE_READ_ADDR_C), 1)
        != VIP_CHI_RESP_STATE_I_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] directory port1 not Invalid after Evict", super.tc_name))
    end
    if (super.tb_env.hrnf1_agent.rnf_driver.get_cache_state(item_t::addr_t'(WRITE_READ_ADDR_C))
        != VIP_CHI_RESP_STATE_I_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F1 cache not Invalid after Evict", super.tc_name))
    end

    if (super.tb_env.coh_checker.get_multi_owner_count() != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Checker D flagged %0d multi-owner violations on eviction traffic",
        super.tc_name, super.tb_env.coh_checker.get_multi_owner_count()))
    end

    phase.drop_objection(this);
  endtask
endclass
