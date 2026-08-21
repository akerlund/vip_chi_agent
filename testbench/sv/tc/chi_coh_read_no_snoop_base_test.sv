// ===========================================================================
// chi_coh_read_no_snoop_base_test
//
// First coherent test: a single RN-F issues one ReadShared to the HN-F home.
// With an empty directory and a single requester there is nothing to snoop, so
// the home returns CompData directly. Asserts the full M2 datapath:
//   * the read completes with data,
//   * the granted coherent state is SC (shared),
//   * the RN-F cache model recorded SC for the line,
//   * the HN-F directory recorded SC for the line, and
//   * NO snoop was ever seen on the coherent link (the M2 no-snoop invariant).
//
// Used by:
//   tc_chi_coh_e_read_no_snoop  (wide CHI-E)
//   tc_chi_coh_d_read_no_snoop    (CHI-D)
// ===========================================================================
class chi_coh_read_no_snoop_base_test #(
  vip_chi_cfg_t CFG_P   = CHI_D_CFG_C,
  type          TYPES_T = chi_d_types_t
) extends chi_coherent_base_test #(CFG_P, TYPES_T);

  typedef vip_chi_item #(CFG_P) item_t;

  `uvm_component_param_utils(chi_coh_read_no_snoop_base_test #(CFG_P, TYPES_T))

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  // Perf counters default on; make the dependency explicit for this test.
  // ---------------------------------------------------------------------------
  protected virtual function void configure_tb_cfg();
    super.tb_cfg.perf_enable = 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Drive one ReadShared and check the coherent read datapath + no-snoop.
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t         read_responses[$];
    item_t         rsp;
    vip_chi_resp_t rnf_state;
    vip_chi_resp_t hnf_state;

    phase.raise_objection(this);

    super.wait_reset_settle();

    super.hrnf0_rdshared_seq.reset();
    super.hrnf0_rdshared_seq.set_requests(1);
    super.hrnf0_rdshared_seq.set_initial_addr(item_t::addr_t'(WRITE_READ_ADDR_C));
    super.hrnf0_rdshared_seq.set_size(3'd6);
    super.hrnf0_rdshared_seq.set_get_response(1'b1);
    super.hrnf0_rdshared_seq.set_verbose(1'b0);
    super.hrnf0_rdshared_seq.start(super.tb_env.hrnf0_agent.sequencer);

    read_responses = super.hrnf0_rdshared_seq.get_responses();

    if (read_responses.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Expected 1 ReadShared response, got %0d",
        super.tc_name, read_responses.size()))
    end

    rsp = read_responses[0];

    if (rsp.data.size() == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] ReadShared completed with no data beats", super.tc_name))
    end

    if (rsp.rsp_resp != VIP_CHI_RESP_STATE_SC_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] ReadShared granted state 0x%0h, expected SC (0x%0h)",
        super.tc_name, rsp.rsp_resp, VIP_CHI_RESP_STATE_SC_E))
    end

    // Let the perf clock loop advance a few cycles past the completion.
    super.wait_clocks(8);

    rnf_state = super.tb_env.hrnf0_agent.rnf_driver.get_cache_state(item_t::addr_t'(WRITE_READ_ADDR_C));
    if (rnf_state != VIP_CHI_RESP_STATE_SC_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F cache state 0x%0h, expected SC (0x%0h)",
        super.tc_name, rnf_state, VIP_CHI_RESP_STATE_SC_E))
    end

    hnf_state = super.tb_env.hnf_agent.hnf_driver.get_directory_state(item_t::addr_t'(WRITE_READ_ADDR_C));
    if (hnf_state != VIP_CHI_RESP_STATE_SC_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] HN-F directory state 0x%0h, expected SC (0x%0h)",
        super.tc_name, hnf_state, VIP_CHI_RESP_STATE_SC_E))
    end

    if (super.tb_env.hrnf0_snp_fifo.used() != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Expected zero snoops on the coherent link, saw %0d",
        super.tc_name, super.tb_env.hrnf0_snp_fifo.used()))
    end

    phase.drop_objection(this);
  endtask
endclass
