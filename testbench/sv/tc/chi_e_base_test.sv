class chi_e_base_test extends uvm_test;

  `uvm_component_utils(chi_e_base_test)

  uvm_table_printer table_printer;
  report_server     rpt_server;
  string            tc_name;
  time              phase_timeout = 5ms;

  chi_e_tb_env                            tb_env;
  chi_tb_config                           tb_cfg;
  vip_chi_cfg_agent                           rni_cfg;
  vip_chi_cfg_agent                           snf_cfg;
  vip_chi_write_seq   #(CHI_E_WIDE_CFG_C)     rni_wr_seq;
  vip_chi_read_seq    #(CHI_E_WIDE_CFG_C)     rni_rd_seq;

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
  // Configure TB CFG
  // ---------------------------------------------------------------------------
  protected virtual function void configure_tb_cfg();

  endfunction

  // ---------------------------------------------------------------------------
  // Configure Agent Cfgs
  // ---------------------------------------------------------------------------
  protected virtual function void configure_agent_cfgs();

  endfunction

  // ---------------------------------------------------------------------------
  // Build Phase
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

    this.rni_cfg = vip_chi_cfg_agent::type_id::create("rni_cfg");
    this.rni_cfg.role = VIP_CHI_ROLE_RNI_E;
    this.rni_cfg.is_active = UVM_ACTIVE;

    this.snf_cfg = vip_chi_cfg_agent::type_id::create("snf_cfg");
    this.snf_cfg.role = VIP_CHI_ROLE_SNF_E;
    this.snf_cfg.is_active = UVM_ACTIVE;

    this.tb_cfg = chi_tb_config::type_id::create("tb_cfg");
    this.tb_cfg.reset();
    this.tb_cfg.run_e_wide_integrated = 1'b1;
    this.configure_tb_cfg();
    this.configure_agent_cfgs();

    uvm_config_db #(chi_tb_config)::set(null, "*", "tb_cfg", this.tb_cfg);
    uvm_config_db #(vip_chi_cfg_agent)::set(this, "env.rni_agent", "cfg", this.rni_cfg);
    uvm_config_db #(vip_chi_cfg_agent)::set(this, "env.snf_agent", "cfg", this.snf_cfg);

    this.tb_env = chi_e_tb_env::type_id::create("env", this);
  endfunction

  // ---------------------------------------------------------------------------
  // Start Of Simulation Phase
  // ---------------------------------------------------------------------------
  function void start_of_simulation_phase(input uvm_phase phase);

    super.start_of_simulation_phase(phase);

    this.rni_wr_seq = vip_chi_write_seq #(CHI_E_WIDE_CFG_C)::type_id::create("rni_wr_seq");
    this.rni_rd_seq = vip_chi_read_seq  #(CHI_E_WIDE_CFG_C)::type_id::create("rni_rd_seq");
  endfunction

  // ---------------------------------------------------------------------------
  // Drain Observation Fifos
  // ---------------------------------------------------------------------------
  // Idle a number of clocks on the CHI-E link. The env's own interface, so a
  // test does not have to reach for a hierarchical path.
  protected task wait_clocks(input int cycles);
    repeat (cycles) @(posedge this.tb_env.rni_agent.vif.clk);
  endtask

  protected task drain_observation_fifos();

    vip_chi_item #(CHI_E_WIDE_CFG_C) item;

    while (this.tb_env.rni_req_fifo.try_get(item)) begin end
    while (this.tb_env.rni_rsp_fifo.try_get(item)) begin end
    while (this.tb_env.rni_dat_fifo.try_get(item)) begin end
    while (this.tb_env.snf_req_fifo.try_get(item)) begin end
    while (this.tb_env.snf_rsp_fifo.try_get(item)) begin end
    while (this.tb_env.snf_dat_fifo.try_get(item)) begin end
  endtask

  // ---------------------------------------------------------------------------
  // Report Phase
  // ---------------------------------------------------------------------------
  function void report_phase(input uvm_phase phase);

    super.report_phase(phase);

    this.rpt_server.test_report();
  endfunction
endclass