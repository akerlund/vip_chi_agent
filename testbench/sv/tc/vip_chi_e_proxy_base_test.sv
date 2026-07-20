// ===========================================================================
// vip_chi_e_proxy_base_test
//
// Base test for the wide CHI-E HN-I proxy topology (vip_chi_e_proxy_tb_env).
// Mirrors vip_chi_base_test's proxy scaffolding, but at CHI_E_WIDE_CFG_C and
// without a virtual sequencer: the CHI-E leaf sequencers are
// #(CHI_E_WIDE_CFG_C), so tests start sequences directly on
// tb_env.hrni{0,1}_agent.sequencer (as the CHI-E direct-pair tests do).
// ===========================================================================
class vip_chi_e_proxy_base_test extends uvm_test;

  `uvm_component_utils(vip_chi_e_proxy_base_test)

  uvm_table_printer table_printer;
  report_server     rpt_server;
  string            tc_name;
  time              phase_timeout = 5ms;

  vip_chi_e_proxy_tb_env             tb_env;
  vip_chi_tb_config                  tb_cfg;
  vip_chi_cfg_agent                  hrni0_cfg;
  vip_chi_cfg_agent                  hrni1_cfg;
  vip_chi_cfg_agent                  hsnf0_cfg;
  vip_chi_cfg_agent                  hsnf1_cfg;

  vip_chi_write_seq #(CHI_E_WIDE_CFG_C) hrni0_wr_seq;
  vip_chi_read_seq  #(CHI_E_WIDE_CFG_C) hrni0_rd_seq;

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
  // Let specialized tests seed the shared TB harness config before run_phase.
  // ---------------------------------------------------------------------------
  protected virtual function void configure_tb_cfg();

  endfunction

  // ---------------------------------------------------------------------------
  // Let specialized tests adjust agent cfg after the shared defaults are built.
  // ---------------------------------------------------------------------------
  protected virtual function void configure_agent_cfgs();

  endfunction

  // ---------------------------------------------------------------------------
  // Build the CHI-E HN-I proxy environment.
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

    // Proxy RN-facing requester agents (ports 0 and 1).
    this.hrni0_cfg = vip_chi_cfg_agent::type_id::create("hrni0_cfg");
    this.hrni0_cfg.role = VIP_CHI_ROLE_RNI_E;
    this.hrni0_cfg.is_active = UVM_ACTIVE;

    this.hrni1_cfg = vip_chi_cfg_agent::type_id::create("hrni1_cfg");
    this.hrni1_cfg.role = VIP_CHI_ROLE_RNI_E;
    this.hrni1_cfg.is_active = UVM_ACTIVE;

    // Proxy SN-facing responder agents (targets 0 and 1).
    this.hsnf0_cfg = vip_chi_cfg_agent::type_id::create("hsnf0_cfg");
    this.hsnf0_cfg.role = VIP_CHI_ROLE_SNF_E;
    this.hsnf0_cfg.is_active = UVM_ACTIVE;

    this.hsnf1_cfg = vip_chi_cfg_agent::type_id::create("hsnf1_cfg");
    this.hsnf1_cfg.role = VIP_CHI_ROLE_SNF_E;
    this.hsnf1_cfg.is_active = UVM_ACTIVE;

    this.tb_cfg = vip_chi_tb_config::type_id::create("tb_cfg");
    this.tb_cfg.reset();
    this.configure_tb_cfg();

    this.configure_agent_cfgs();

    uvm_config_db #(vip_chi_tb_config)::set(null, "*", "tb_cfg", this.tb_cfg);
    uvm_config_db #(vip_chi_cfg_agent)::set(this, "env.hrni0_agent", "cfg", this.hrni0_cfg);
    uvm_config_db #(vip_chi_cfg_agent)::set(this, "env.hrni1_agent", "cfg", this.hrni1_cfg);
    uvm_config_db #(vip_chi_cfg_agent)::set(this, "env.hsnf0_agent", "cfg", this.hsnf0_cfg);
    uvm_config_db #(vip_chi_cfg_agent)::set(this, "env.hsnf1_agent", "cfg", this.hsnf1_cfg);

    this.tb_env = vip_chi_e_proxy_tb_env::type_id::create("env", this);
  endfunction

  // ---------------------------------------------------------------------------
  // Create the shared per-test sequence handles.
  // ---------------------------------------------------------------------------
  function void start_of_simulation_phase(input uvm_phase phase);

    super.start_of_simulation_phase(phase);

    this.hrni0_wr_seq = vip_chi_write_seq #(CHI_E_WIDE_CFG_C)::type_id::create("hrni0_wr_seq");
    this.hrni0_rd_seq = vip_chi_read_seq  #(CHI_E_WIDE_CFG_C)::type_id::create("hrni0_rd_seq");
  endfunction

  // ---------------------------------------------------------------------------
  // Wait for a fixed number of shared testbench clocks.
  // ---------------------------------------------------------------------------
  protected task wait_clocks(input int cycles);

    repeat (cycles) @(posedge this.tb_env.hrni0_agent.vif.clk);

  endtask

  // ---------------------------------------------------------------------------
  // Print the shared report-server summary at end of test.
  // ---------------------------------------------------------------------------
  function void report_phase(input uvm_phase phase);

    super.report_phase(phase);

    this.rpt_server.test_report();
  endfunction
endclass
