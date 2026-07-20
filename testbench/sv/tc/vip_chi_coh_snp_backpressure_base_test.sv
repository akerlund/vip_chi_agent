// ===========================================================================
// vip_chi_coh_snp_backpressure_base_test
//
// SNP-channel back-pressure. RN-F0's SNP receive credits are withheld from
// build (hold_snp_credit), so the HN-F's SNP send pool starves and it cannot
// snoop RN-F0. Sequence:
//   RN-F0 ReadShared L        -> SC (no snoop needed; completes normally)
//   RN-F1 ReadUnique L        -> HN-F must SnpUnique RN-F0, but has no SNP send
//                                credit -> the snoop, and thus the ReadUnique,
//                                stalls indefinitely.
// The test proves the stall (ReadUnique does not complete, RN-F0 keeps SC, no
// snoop observed), then releases the credits and proves the parked snoop flows:
// RN-F0 is invalidated and RN-F1's ReadUnique completes with UC.
//
// Used by:
//   tc_chi_coh_e_snp_backpressure  (wide CHI-E)
//   tc_chi_coh_d_snp_backpressure    (CHI-D)
// ===========================================================================
class vip_chi_coh_snp_backpressure_base_test #(
  vip_chi_cfg_t CFG_P   = CHI_D_CFG_C,
  type          TYPES_T = chi_d_types_t
) extends vip_chi_coherent_base_test #(CFG_P, TYPES_T);

  typedef vip_chi_item #(CFG_P) item_t;

  `uvm_component_param_utils(vip_chi_coh_snp_backpressure_base_test #(CFG_P, TYPES_T))

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // Withhold RN-F0's SNP receive credits from the very start so even its initial
  // credit advertisement never reaches the wire -> the HN-F begins with a starved
  // SNP send pool.
  protected virtual function void configure_agent_cfgs();
    super.configure_agent_cfgs();
    super.hrnf0_cfg.hold_snp_credit = 1'b1;
  endfunction


  task run_phase(input uvm_phase phase);

    item_t         shared_rsp[$];
    item_t         unique_rsp[$];
    vip_chi_resp_t rnf0_state;
    bit            unique_done;
    int            i;

    phase.raise_objection(this);

    super.wait_reset_settle();

    // RN-F0 acquires the line Shared -- no snoop needed, so this completes despite
    // the withheld SNP credits.
    this.cfg_read_seq(super.hrnf0_rdshared_seq, item_t::addr_t'(WRITE_READ_ADDR_C));
    super.hrnf0_rdshared_seq.start(super.tb_env.hrnf0_agent.sequencer);
    shared_rsp = super.hrnf0_rdshared_seq.get_responses();
    if (shared_rsp.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] ReadShared setup returned %0d responses, expected 1",
        super.tc_name, shared_rsp.size()))
    end

    // RN-F1 ReadUniques the same line: the HN-F must snoop-invalidate RN-F0, but
    // its SNP send pool is starved, so the request parks. Fork the (blocking)
    // start so the test can observe the stall.
    this.cfg_read_seq(super.hrnf1_rdunique_seq, item_t::addr_t'(WRITE_READ_ADDR_C));
    unique_done = 1'b0;
    fork
      begin
        super.hrnf1_rdunique_seq.start(super.tb_env.hrnf1_agent.sequencer);
        unique_done = 1'b1;
      end
    join_none

    // Hold the snoop parked and confirm no progress: the ReadUnique has not
    // completed, RN-F0 still holds SC, and no snoop reached RN-F0.
    super.wait_clocks(60);

    if (unique_done) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] ReadUnique completed despite SNP credit starvation", super.tc_name))
    end
    rnf0_state = super.tb_env.hrnf0_agent.rnf_driver.get_cache_state(item_t::addr_t'(WRITE_READ_ADDR_C));
    if (rnf0_state != VIP_CHI_RESP_STATE_SC_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F0 state 0x%0h during stall, expected SC (snoop not yet delivered)",
        super.tc_name, rnf0_state))
    end
    if (super.tb_env.hrnf0_snp_fifo.used() != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F0 observed a snoop while SNP credits were withheld", super.tc_name))
    end

    // Release the credits: the queued grants drain, the HN-F's SNP send pool
    // refills, and the parked snoop flows to completion.
    super.hrnf0_cfg.hold_snp_credit = 1'b0;

    for (i = 0; i < 400; i++) begin
      if (unique_done) begin
        break;
      end
      super.wait_clocks(1);
    end
    if (!unique_done) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] ReadUnique never completed after SNP credit release", super.tc_name))
    end

    unique_rsp = super.hrnf1_rdunique_seq.get_responses();
    if ((unique_rsp.size() != 1) || (unique_rsp[0].rsp_resp != VIP_CHI_RESP_STATE_UC_E)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] ReadUnique after release: %0d responses, state 0x%0h (expected 1 x UC)",
        super.tc_name, unique_rsp.size(),
        (unique_rsp.size() > 0) ? unique_rsp[0].rsp_resp : VIP_CHI_RESP_STATE_I_E))
    end

    if (super.tb_env.hrnf0_snp_fifo.used() == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F0 never observed the snoop after credit release", super.tc_name))
    end
    rnf0_state = super.tb_env.hrnf0_agent.rnf_driver.get_cache_state(item_t::addr_t'(WRITE_READ_ADDR_C));
    if (rnf0_state != VIP_CHI_RESP_STATE_I_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F0 state 0x%0h after snoop, expected I", super.tc_name, rnf0_state))
    end

    phase.drop_objection(this);
  endtask
endclass
