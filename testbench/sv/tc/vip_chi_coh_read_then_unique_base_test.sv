// ===========================================================================
// vip_chi_coh_read_then_unique_base_test
//
// Invalidating snoop round-trip. RN-F0 first ReadShareds a line (-> SC), then
// RN-F1 ReadUniques the same line. The home must snoop-invalidate RN-F0 before
// granting RN-F1 unique ownership:
//   RN-F0 ReadShared L        -> SC, directory[L]={p0:SC}
//   RN-F1 ReadUnique L        -> HN-F SnpUnique(RN-F0) -> RN-F0 SnpResp(I)
//                                -> HN-F CompData(UC) to RN-F1
// Asserts: RN-F1 granted UC, RN-F0 cache invalidated to I, RN-F1 cache UC, the
// directory shows p0=I / p1=UC, and RN-F0 actually observed a snoop.
//
// Used by:
//   tc_chi_coh_e_read_then_unique  (wide CHI-E)
//   tc_chi_coh_d_read_then_unique    (CHI-D)
// ===========================================================================
class vip_chi_coh_read_then_unique_base_test #(
  vip_chi_cfg_t CFG_P   = CHI_D_CFG_C,
  type          TYPES_T = chi_d_types_t
) extends vip_chi_coherent_base_test #(CFG_P, TYPES_T);

  typedef vip_chi_item #(CFG_P) item_t;

  `uvm_component_param_utils(vip_chi_coh_read_then_unique_base_test #(CFG_P, TYPES_T))

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction


  task run_phase(input uvm_phase phase);

    item_t         shared_rsp[$];
    item_t         unique_rsp[$];
    vip_chi_resp_t rnf0_state;
    vip_chi_resp_t rnf1_state;

    phase.raise_objection(this);

    super.wait_reset_settle();

    // RN-F0 acquires the line Shared.
    this.cfg_read_seq(super.hrnf0_rdshared_seq);
    super.hrnf0_rdshared_seq.start(super.tb_env.hrnf0_agent.sequencer);
    shared_rsp = super.hrnf0_rdshared_seq.get_responses();

    // RN-F1 then acquires it Unique, forcing a snoop-invalidate of RN-F0.
    this.cfg_read_seq(super.hrnf1_rdunique_seq);
    super.hrnf1_rdunique_seq.start(super.tb_env.hrnf1_agent.sequencer);
    unique_rsp = super.hrnf1_rdunique_seq.get_responses();

    if ((shared_rsp.size() != 1) || (unique_rsp.size() != 1)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] expected 1+1 responses, got %0d/%0d",
        super.tc_name, shared_rsp.size(), unique_rsp.size()))
    end

    if (unique_rsp[0].rsp_resp != VIP_CHI_RESP_STATE_UC_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] ReadUnique granted 0x%0h, expected UC (0x%0h)",
        super.tc_name, unique_rsp[0].rsp_resp, VIP_CHI_RESP_STATE_UC_E))
    end

    super.wait_clocks(8);

    rnf0_state = super.tb_env.hrnf0_agent.rnf_driver.get_cache_state(item_t::addr_t'(WRITE_READ_ADDR_C));
    rnf1_state = super.tb_env.hrnf1_agent.rnf_driver.get_cache_state(item_t::addr_t'(WRITE_READ_ADDR_C));

    if (rnf0_state != VIP_CHI_RESP_STATE_I_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F0 cache 0x%0h after invalidating snoop, expected I",
        super.tc_name, rnf0_state))
    end

    if (rnf1_state != VIP_CHI_RESP_STATE_UC_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F1 cache 0x%0h, expected UC", super.tc_name, rnf1_state))
    end

    if (super.tb_env.hnf_agent.hnf_driver.get_directory_port_state(item_t::addr_t'(WRITE_READ_ADDR_C), 0) != VIP_CHI_RESP_STATE_I_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] directory port0 not Invalid after unique grant to port1",
        super.tc_name))
    end
    if (super.tb_env.hnf_agent.hnf_driver.get_directory_port_state(item_t::addr_t'(WRITE_READ_ADDR_C), 1) != VIP_CHI_RESP_STATE_UC_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] directory port1 not UC after unique grant", super.tc_name))
    end

    if (super.tb_env.hrnf0_snp_fifo.used() == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F0 never observed the invalidating snoop", super.tc_name))
    end

    phase.drop_objection(this);
  endtask
endclass
