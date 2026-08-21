// ===========================================================================
// chi_coherent_base_test
//
// Base test for the isolated coherent topology (chi_coherent_tb_env): two
// RN-F requesters fanning into one HN-F home. Parameterized on the CHI config +
// flit-type bundle so a single scenario body runs at both CHI-D (CHI_D_CFG_C /
// chi_d_types_t, the defaults) and wide CHI-E (CHI_E_WIDE_CFG_C / chi_e_wide_types_t)
// widths. Mirrors chi_e_proxy_base_test's standalone scaffolding (no virtual
// sequencer; tests start sequences directly on tb_env.hrnf{0,1}_agent.sequencer).
//
// A concrete scenario derives a parameterized vip_chi_<scenario>_base_test from
// this (one class per file), and each runnable specialization lives in its own
// tc_ file -- tc_chi_coh_d_<x>.sv fixes CHI_D_CFG_C / chi_d_types_t and
// tc_chi_coh_e_<x>.sv fixes CHI_E_WIDE_CFG_C / chi_e_wide_types_t -- so both
// names are runnable by `+UVM_TESTNAME`.
//
// Used by: every vip_chi_<scenario>_base_test in this directory (each lists
// its own runnable tests) and chi_coherent_e_base_test (the CHI-E-only
// scenarios' base).
// ===========================================================================
class chi_coherent_base_test #(
  vip_chi_cfg_t CFG_P   = CHI_D_CFG_C,
  type          TYPES_T = chi_d_types_t
) extends uvm_test;

  `uvm_component_param_utils(chi_coherent_base_test #(CFG_P, TYPES_T))

  typedef vip_chi_item #(CFG_P) item_t;

  uvm_table_printer table_printer;
  report_server     rpt_server;
  string            tc_name;
  time              phase_timeout = 5ms;

  chi_coherent_tb_env #(CFG_P, TYPES_T) tb_env;
  chi_tb_config       tb_cfg;
  vip_chi_cfg_agent       hrnf0_cfg;
  vip_chi_cfg_agent       hrnf1_cfg;
  vip_chi_cfg_agent       hnf_cfg;

  vip_chi_readshared_seq #(CFG_P) hrnf0_rdshared_seq;
  vip_chi_readunique_seq #(CFG_P) hrnf0_rdunique_seq;
  vip_chi_readshared_seq #(CFG_P) hrnf1_rdshared_seq;
  vip_chi_readunique_seq #(CFG_P) hrnf1_rdunique_seq;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    int seed;

    super.new(name, parent);

    void'($value$plusargs("UVM_TESTNAME=%s", tc_name));

    if ($value$plusargs("ntb_random_seed=%d", seed)) begin
      `uvm_info(get_name(), $sformatf(
        "INFO [%s] Random seed value: %0d",
        tc_name, seed), UVM_LOW)
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Hooks for specialized tests to seed the shared/agent configs.
  // ---------------------------------------------------------------------------
  protected virtual function void configure_tb_cfg();
  endfunction

  protected virtual function void configure_agent_cfgs();
  endfunction

  // ---------------------------------------------------------------------------
  // Build the coherent environment.
  // ---------------------------------------------------------------------------
  function void build_phase(input uvm_phase phase);

    super.build_phase(phase);

    uvm_top.set_timeout(phase_timeout, 1);
    uvm_config_db #(uvm_verbosity)::set(this, "*", "recording_detail", UVM_FULL);

    rpt_server = new("report_server0");
    uvm_report_server::set_server(rpt_server);

    table_printer                     = new();
    table_printer.knobs.depth         = 3;
    table_printer.knobs.default_radix = UVM_DEC;

    // Coherent requester agents (ports 0 and 1).
    this.hrnf0_cfg = vip_chi_cfg_agent::type_id::create("hrnf0_cfg");
    this.hrnf0_cfg.role = VIP_CHI_ROLE_RNF_E;
    this.hrnf0_cfg.is_active = UVM_ACTIVE;

    this.hrnf1_cfg = vip_chi_cfg_agent::type_id::create("hrnf1_cfg");
    this.hrnf1_cfg.role = VIP_CHI_ROLE_RNF_E;
    this.hrnf1_cfg.is_active = UVM_ACTIVE;

    // Coherent home node.
    this.hnf_cfg = vip_chi_cfg_agent::type_id::create("hnf_cfg");
    this.hnf_cfg.role = VIP_CHI_ROLE_HNF_E;
    this.hnf_cfg.is_active = UVM_ACTIVE;

    this.tb_cfg = chi_tb_config::type_id::create("tb_cfg");
    this.tb_cfg.reset();
    this.configure_tb_cfg();

    this.configure_agent_cfgs();

    uvm_config_db #(chi_tb_config)::set(null, "*", "tb_cfg", this.tb_cfg);
    uvm_config_db #(vip_chi_cfg_agent)::set(this, "env.hrnf0_agent", "cfg", this.hrnf0_cfg);
    uvm_config_db #(vip_chi_cfg_agent)::set(this, "env.hrnf1_agent", "cfg", this.hrnf1_cfg);
    uvm_config_db #(vip_chi_cfg_agent)::set(this, "env.hnf_agent",   "cfg", this.hnf_cfg);

    this.tb_env = chi_coherent_tb_env #(CFG_P, TYPES_T)::type_id::create("env", this);
  endfunction

  // ---------------------------------------------------------------------------
  // Create the shared per-test sequence handles.
  // ---------------------------------------------------------------------------
  function void start_of_simulation_phase(input uvm_phase phase);

    super.start_of_simulation_phase(phase);

    this.hrnf0_rdshared_seq = vip_chi_readshared_seq #(CFG_P)::type_id::create("hrnf0_rdshared_seq");
    this.hrnf0_rdunique_seq = vip_chi_readunique_seq #(CFG_P)::type_id::create("hrnf0_rdunique_seq");
    this.hrnf1_rdshared_seq = vip_chi_readshared_seq #(CFG_P)::type_id::create("hrnf1_rdshared_seq");
    this.hrnf1_rdunique_seq = vip_chi_readunique_seq #(CFG_P)::type_id::create("hrnf1_rdunique_seq");
  endfunction

  // ---------------------------------------------------------------------------
  // Wait until the coherent links are out of reset before a scenario drives or
  // samples state. Level-checked first so it is safe whether run_phase starts
  // during reset (wait for the release edge) or after it (already high -> no
  // wait, no hang). The +4-clock settle lets the agents' link bring-up complete.
  // ---------------------------------------------------------------------------
  protected task wait_reset_settle();
    if (!this.tb_env.hrnf0_agent.vif.rst_n) begin
      @(posedge this.tb_env.hrnf0_agent.vif.rst_n);
    end
    this.wait_clocks(4);
  endtask

  // ---------------------------------------------------------------------------
  // Configure a coherent sequence for one single-line, cache-line-sized request:
  // no retries, blocking response collection, quiet. `addr` defaults to the
  // shared coherent test line.
  // ---------------------------------------------------------------------------
  protected function void cfg_read_seq(
    input vip_chi_coherent_base_seq #(CFG_P) seq,
    input item_t::addr_t addr = item_t::addr_t'(WRITE_READ_ADDR_C)
  );
    seq.reset();
    seq.set_requests(1);
    seq.set_initial_addr(addr);
    seq.set_size(3'd6);
    seq.set_get_response(1'b1);
    seq.set_verbose(1'b0);
  endfunction

  // ---------------------------------------------------------------------------
  // Wait for a fixed number of shared testbench clocks.
  // ---------------------------------------------------------------------------
  protected task wait_clocks(input int cycles);
    repeat (cycles) @(posedge this.tb_env.hrnf0_agent.vif.clk);
  endtask

  // ---------------------------------------------------------------------------
  // Print the shared report-server summary at end of test.
  // ---------------------------------------------------------------------------
  function void report_phase(input uvm_phase phase);
    super.report_phase(phase);
    this.rpt_server.test_report();
  endfunction
endclass
