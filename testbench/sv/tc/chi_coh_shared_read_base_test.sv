// ===========================================================================
// chi_coh_shared_read_base_test
//
// Downgrading snoop round-trip. RN-F0 first ReadUniques a line (-> UC), then
// RN-F1 ReadShareds the same line. The home must snoop-downgrade RN-F0 to
// Shared before granting RN-F1 a shared copy:
//   RN-F0 ReadUnique L        -> UC, directory[L]={p0:UC}
//   RN-F1 ReadShared L        -> HN-F SnpShared(RN-F0) -> RN-F0 SnpResp(SC)
//                                -> HN-F CompData(SC) to RN-F1
// Asserts: RN-F1 granted SC, RN-F0 downgraded UC->SC, both directory ports SC,
// and RN-F0 actually observed a snoop.
//
// Used by:
//   tc_chi_coh_e_shared_read  (wide CHI-E)
//   tc_chi_coh_d_shared_read    (CHI-D)
// ===========================================================================
class chi_coh_shared_read_base_test #(
  vip_chi_cfg_t CFG_P   = CHI_D_CFG_C,
  type          TYPES_T = chi_d_types_t
) extends chi_coherent_base_test #(CFG_P, TYPES_T);

  typedef vip_chi_item #(CFG_P) item_t;

  `uvm_component_param_utils(chi_coh_shared_read_base_test #(CFG_P, TYPES_T))

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction


  task run_phase(input uvm_phase phase);

    item_t         unique_rsp[$];
    item_t         shared_rsp[$];
    vip_chi_resp_t rnf0_state;
    vip_chi_resp_t rnf1_state;

    phase.raise_objection(this);

    super.wait_reset_settle();

    // RN-F0 acquires the line Unique.
    this.cfg_read_seq(super.hrnf0_rdunique_seq);
    super.hrnf0_rdunique_seq.start(super.tb_env.hrnf0_agent.sequencer);
    unique_rsp = super.hrnf0_rdunique_seq.get_responses();

    // RN-F1 then reads Shared, forcing a snoop-downgrade of RN-F0.
    this.cfg_read_seq(super.hrnf1_rdshared_seq);
    super.hrnf1_rdshared_seq.start(super.tb_env.hrnf1_agent.sequencer);
    shared_rsp = super.hrnf1_rdshared_seq.get_responses();

    if ((unique_rsp.size() != 1) || (shared_rsp.size() != 1)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] expected 1+1 responses, got %0d/%0d",
        super.tc_name, unique_rsp.size(), shared_rsp.size()))
    end

    if (shared_rsp[0].rsp_resp != VIP_CHI_RESP_STATE_SC_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] ReadShared granted 0x%0h, expected SC (0x%0h)",
        super.tc_name, shared_rsp[0].rsp_resp, VIP_CHI_RESP_STATE_SC_E))
    end

    super.wait_clocks(8);

    rnf0_state = super.tb_env.hrnf0_agent.rnf_driver.get_cache_state(item_t::addr_t'(WRITE_READ_ADDR_C));
    rnf1_state = super.tb_env.hrnf1_agent.rnf_driver.get_cache_state(item_t::addr_t'(WRITE_READ_ADDR_C));

    if (rnf0_state != VIP_CHI_RESP_STATE_SC_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F0 cache 0x%0h after downgrading snoop, expected SC",
        super.tc_name, rnf0_state))
    end

    if (rnf1_state != VIP_CHI_RESP_STATE_SC_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F1 cache 0x%0h, expected SC", super.tc_name, rnf1_state))
    end

    if (super.tb_env.hnf_agent.hnf_driver.get_directory_port_state(item_t::addr_t'(WRITE_READ_ADDR_C), 0) != VIP_CHI_RESP_STATE_SC_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] directory port0 not SC after downgrade", super.tc_name))
    end
    if (super.tb_env.hnf_agent.hnf_driver.get_directory_port_state(item_t::addr_t'(WRITE_READ_ADDR_C), 1) != VIP_CHI_RESP_STATE_SC_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] directory port1 not SC after shared read", super.tc_name))
    end

    if (super.tb_env.hrnf0_snp_fifo.used() == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F0 never observed the downgrading snoop", super.tc_name))
    end

    phase.drop_objection(this);
  endtask
endclass
