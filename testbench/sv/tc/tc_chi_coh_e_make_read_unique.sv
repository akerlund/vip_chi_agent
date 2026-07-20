// ===========================================================================
// tc_chi_coh_e_make_read_unique
//
// CHI-E parity of the MakeReadUnique flow (MakeReadUnique is a CHI-E-only 7-bit
// opcode, 0x41, that cannot be represented in the CHI-D 6-bit REQ field -- so it
// is exercised only here). RN-F0 ReadShareds a line (-> SC), then RN-F1
// MakeReadUniques it: the home snoop-invalidates RN-F0 and grants CompData in the
// unique state, at CHI-E flit width.
// Asserts: RN-F1 granted UC carrying data, RN-F0 invalidated to I, RN-F1 cache UC,
// directory p0=I / p1=UC, RN-F0 observed a snoop, Checker D silent.
// ===========================================================================
class tc_chi_coh_e_make_read_unique extends vip_chi_coherent_e_base_test;

  typedef vip_chi_item #(CHI_E_WIDE_CFG_C) item_t;

  `uvm_component_utils(tc_chi_coh_e_make_read_unique)

  vip_chi_makereadunique_seq #(CHI_E_WIDE_CFG_C) hrnf1_mru_seq;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void start_of_simulation_phase(input uvm_phase phase);
    super.start_of_simulation_phase(phase);
    this.hrnf1_mru_seq = vip_chi_makereadunique_seq #(CHI_E_WIDE_CFG_C)::type_id::create("hrnf1_mru_seq");
  endfunction


  task run_phase(input uvm_phase phase);

    item_t         shared_rsp[$];
    item_t         mru_rsp[$];
    vip_chi_resp_t rnf0_state;
    vip_chi_resp_t rnf1_state;

    phase.raise_objection(this);

    @(posedge super.tb_env.hrnf0_agent.vif.rst_n);
    super.wait_clocks(4);

    this.cfg_read_seq(super.hrnf0_rdshared_seq);
    super.hrnf0_rdshared_seq.start(super.tb_env.hrnf0_agent.sequencer);
    shared_rsp = super.hrnf0_rdshared_seq.get_responses();

    this.cfg_read_seq(this.hrnf1_mru_seq);
    this.hrnf1_mru_seq.start(super.tb_env.hrnf1_agent.sequencer);
    mru_rsp = this.hrnf1_mru_seq.get_responses();

    if ((shared_rsp.size() != 1) || (mru_rsp.size() != 1)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] expected 1+1 responses, got %0d/%0d",
        super.tc_name, shared_rsp.size(), mru_rsp.size()))
    end

    if (mru_rsp[0].rsp_resp != VIP_CHI_RESP_STATE_UC_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] MakeReadUnique granted 0x%0h, expected UC (0x%0h)",
        super.tc_name, mru_rsp[0].rsp_resp, VIP_CHI_RESP_STATE_UC_E))
    end

    if (mru_rsp[0].data.size() == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] MakeReadUnique completed with no data beats", super.tc_name))
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
        "FATAL [%s] directory port0 not Invalid after MakeReadUnique grant to port1",
        super.tc_name))
    end
    if (super.tb_env.hnf_agent.hnf_driver.get_directory_port_state(item_t::addr_t'(WRITE_READ_ADDR_C), 1) != VIP_CHI_RESP_STATE_UC_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] directory port1 not UC after MakeReadUnique grant", super.tc_name))
    end

    if (super.tb_env.hrnf0_snp_fifo.used() == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F0 never observed the invalidating snoop", super.tc_name))
    end

    if (super.tb_env.coh_checker.get_multi_owner_count() != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %0d coherency violations on a legal MakeReadUnique",
        super.tc_name, super.tb_env.coh_checker.get_multi_owner_count()))
    end

    phase.drop_objection(this);
  endtask
endclass
