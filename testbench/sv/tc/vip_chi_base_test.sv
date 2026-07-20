class vip_chi_base_test extends uvm_test;

  `uvm_component_utils(vip_chi_base_test)

  uvm_table_printer       table_printer;
  report_server           rpt_server;
  string                  tc_name;
  time                    phase_timeout = 5ms;

  vip_chi_tb_env          tb_env;
  vip_chi_virtual_sequencer v_sqr;
  vip_chi_tb_config       tb_cfg;
  vip_chi_cfg_agent       rni_cfg;
  vip_chi_cfg_agent       snf_cfg;
  vip_chi_cfg_agent       hrni0_cfg;
  vip_chi_cfg_agent       hrni1_cfg;
  vip_chi_cfg_agent       hsnf0_cfg;
  vip_chi_cfg_agent       hsnf1_cfg;

  vip_chi_write_seq     #(CHI_D_CFG_C) rni0_wr_seq;
  vip_chi_read_seq      #(CHI_D_CFG_C) rni0_rd_seq;
  vip_chi_write_seq     #(CHI_D_CFG_C) rni1_wr_seq;
  vip_chi_read_seq      #(CHI_D_CFG_C) rni1_rd_seq;
  vip_chi_pipelined_seq #(CHI_D_CFG_C) snf0_pipe_seq;

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
  // Build the shared CHI test environment.
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

    // Every topology has its own dedicated agents and they all co-exist, so all
    // agents are simply active; a test drives sequences only on the topology it
    // exercises and the others stay idle. There is no per-mode is_active gating.
    this.rni_cfg = vip_chi_cfg_agent::type_id::create("rni_cfg");
    this.rni_cfg.role = VIP_CHI_ROLE_RNI_E;
    this.rni_cfg.is_active = UVM_ACTIVE;

    this.snf_cfg = vip_chi_cfg_agent::type_id::create("snf_cfg");
    this.snf_cfg.role = VIP_CHI_ROLE_SNF_E;
    this.snf_cfg.is_active = UVM_ACTIVE;

    // HN-I requester agents (proxy RN-facing ports 0 and 1).
    this.hrni0_cfg = vip_chi_cfg_agent::type_id::create("hrni0_cfg");
    this.hrni0_cfg.role = VIP_CHI_ROLE_RNI_E;
    this.hrni0_cfg.is_active = UVM_ACTIVE;

    this.hrni1_cfg = vip_chi_cfg_agent::type_id::create("hrni1_cfg");
    this.hrni1_cfg.role = VIP_CHI_ROLE_RNI_E;
    this.hrni1_cfg.is_active = UVM_ACTIVE;

    // HN-I responder agents (proxy SN-facing targets 0 and 1).
    this.hsnf0_cfg = vip_chi_cfg_agent::type_id::create("hsnf0_cfg");
    this.hsnf0_cfg.role = VIP_CHI_ROLE_SNF_E;
    this.hsnf0_cfg.is_active = UVM_ACTIVE;

    this.hsnf1_cfg = vip_chi_cfg_agent::type_id::create("hsnf1_cfg");
    this.hsnf1_cfg.role = VIP_CHI_ROLE_SNF_E;
    this.hsnf1_cfg.is_active = UVM_ACTIVE;

    // The testcase owns the shared harness config object and publishes it once
    // (the mid-run reset pulse and the CHI-E datapath enable).
    this.tb_cfg = vip_chi_tb_config::type_id::create("tb_cfg");
    this.tb_cfg.reset();
    this.configure_tb_cfg();

    this.configure_agent_cfgs();

    uvm_config_db #(vip_chi_tb_config)::set(null, "*", "tb_cfg", this.tb_cfg);
    uvm_config_db #(vip_chi_cfg_agent)::set(this, "env.rni_agent", "cfg", this.rni_cfg);
    uvm_config_db #(vip_chi_cfg_agent)::set(this, "env.snf_agent", "cfg", this.snf_cfg);
    uvm_config_db #(vip_chi_cfg_agent)::set(this, "env.hrni0_agent", "cfg", this.hrni0_cfg);
    uvm_config_db #(vip_chi_cfg_agent)::set(this, "env.hrni1_agent", "cfg", this.hrni1_cfg);
    uvm_config_db #(vip_chi_cfg_agent)::set(this, "env.hsnf0_agent", "cfg", this.hsnf0_cfg);
    uvm_config_db #(vip_chi_cfg_agent)::set(this, "env.hsnf1_agent", "cfg", this.hsnf1_cfg);

    this.tb_env = vip_chi_tb_env::type_id::create("env", this);
  endfunction

  // ---------------------------------------------------------------------------
  // Capture the environment virtual sequencer once topology is fixed.
  // ---------------------------------------------------------------------------
  function void end_of_elaboration_phase(input uvm_phase phase);

    super.end_of_elaboration_phase(phase);

    this.v_sqr = this.tb_env.vseq;
  endfunction

  // ---------------------------------------------------------------------------
  // Create the shared per-test sequence handles.
  // ---------------------------------------------------------------------------
  function void start_of_simulation_phase(input uvm_phase phase);

    super.start_of_simulation_phase(phase);

    this.rni0_wr_seq  = vip_chi_write_seq     #(CHI_D_CFG_C)::type_id::create("rni0_wr_seq");
    this.rni0_rd_seq  = vip_chi_read_seq      #(CHI_D_CFG_C)::type_id::create("rni0_rd_seq");
    this.rni1_wr_seq  = vip_chi_write_seq     #(CHI_D_CFG_C)::type_id::create("rni1_wr_seq");
    this.rni1_rd_seq  = vip_chi_read_seq      #(CHI_D_CFG_C)::type_id::create("rni1_rd_seq");
    this.snf0_pipe_seq = vip_chi_pipelined_seq #(CHI_D_CFG_C)::type_id::create("snf0_pipe_seq");
  endfunction

  // ---------------------------------------------------------------------------
  // Wait for a fixed number of shared testbench clocks.
  // ---------------------------------------------------------------------------
  protected task wait_clocks(input int cycles);

    repeat (cycles) @(posedge this.tb_env.rni_agent.vif.clk);

  endtask

  // ---------------------------------------------------------------------------
  // Drain any observed items left in the monitor FIFOs.
  // ---------------------------------------------------------------------------
  protected task drain_observation_fifos();

    item_t item;

    while (this.tb_env.rni_req_fifo.try_get(item)) begin end
    while (this.tb_env.rni_rsp_fifo.try_get(item)) begin end
    while (this.tb_env.rni_dat_fifo.try_get(item)) begin end
    while (this.tb_env.snf_req_fifo.try_get(item)) begin end
    while (this.tb_env.snf_rsp_fifo.try_get(item)) begin end
    while (this.tb_env.snf_dat_fifo.try_get(item)) begin end
  endtask

  // ---------------------------------------------------------------------------
  // Print the shared report-server summary at end of test.
  // ---------------------------------------------------------------------------
  function void report_phase(input uvm_phase phase);

    super.report_phase(phase);

    this.rpt_server.test_report();
  endfunction
endclass