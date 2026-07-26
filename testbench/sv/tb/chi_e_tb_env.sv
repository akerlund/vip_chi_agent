class chi_e_tb_env extends uvm_env;

  typedef vip_chi_item #(CHI_E_WIDE_CFG_C) item_t;

  vip_chi_agent_e #(CHI_E_WIDE_CFG_C, chi_e_wide_types_t, VIP_CHI_ROLE_RNI_E) rni_agent;
  vip_chi_agent_e #(CHI_E_WIDE_CFG_C, chi_e_wide_types_t, VIP_CHI_ROLE_SNF_E) snf_agent;
  vip_chi_coverage #(CHI_E_WIDE_CFG_C)                                          coverage;
  vip_chi_scoreboard #(CHI_E_WIDE_CFG_C)                                        scoreboard;
  uvm_tlm_analysis_fifo #(item_t)                                               rni_req_fifo;
  uvm_tlm_analysis_fifo #(item_t)                                               rni_rsp_fifo;
  uvm_tlm_analysis_fifo #(item_t)                                               rni_dat_fifo;
  uvm_tlm_analysis_fifo #(item_t)                                               snf_req_fifo;
  uvm_tlm_analysis_fifo #(item_t)                                               snf_rsp_fifo;
  uvm_tlm_analysis_fifo #(item_t)                                               snf_dat_fifo;

  `uvm_component_utils(chi_e_tb_env)

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // Build Phase
  // ---------------------------------------------------------------------------
  function void build_phase(input uvm_phase phase);

    super.build_phase(phase);

    this.rni_agent    = vip_chi_agent_e #(CHI_E_WIDE_CFG_C, chi_e_wide_types_t, VIP_CHI_ROLE_RNI_E)::type_id::create("rni_agent", this);
    this.snf_agent    = vip_chi_agent_e #(CHI_E_WIDE_CFG_C, chi_e_wide_types_t, VIP_CHI_ROLE_SNF_E)::type_id::create("snf_agent", this);
    this.coverage     = vip_chi_coverage #(CHI_E_WIDE_CFG_C)::type_id::create("coverage", this);
    this.scoreboard   = vip_chi_scoreboard #(CHI_E_WIDE_CFG_C)::type_id::create("scoreboard", this);
    this.rni_req_fifo = new("rni_req_fifo", this);
    this.rni_rsp_fifo = new("rni_rsp_fifo", this);
    this.rni_dat_fifo = new("rni_dat_fifo", this);
    this.snf_req_fifo = new("snf_req_fifo", this);
    this.snf_rsp_fifo = new("snf_rsp_fifo", this);
    this.snf_dat_fifo = new("snf_dat_fifo", this);
  endfunction

  // ---------------------------------------------------------------------------
  // Connect Phase
  // ---------------------------------------------------------------------------
  function void connect_phase(input uvm_phase phase);

    super.connect_phase(phase);

    this.rni_agent.req_port.connect(this.rni_req_fifo.analysis_export);
    this.rni_agent.rsp_port.connect(this.rni_rsp_fifo.analysis_export);
    this.rni_agent.dat_port.connect(this.rni_dat_fifo.analysis_export);
    this.snf_agent.req_port.connect(this.snf_req_fifo.analysis_export);
    this.snf_agent.rsp_port.connect(this.snf_rsp_fifo.analysis_export);
    this.snf_agent.dat_port.connect(this.snf_dat_fifo.analysis_export);

    this.rni_agent.req_port.connect(this.coverage.rni_req_cov_port);
    this.rni_agent.rsp_port.connect(this.coverage.rni_rsp_cov_port);
    this.rni_agent.dat_port.connect(this.coverage.rni_dat_cov_port);
    this.snf_agent.req_port.connect(this.coverage.snf_req_cov_port);
    this.snf_agent.rsp_port.connect(this.coverage.snf_rsp_cov_port);
    this.snf_agent.dat_port.connect(this.coverage.snf_dat_cov_port);

    this.coverage.enabled =
      this.rni_agent.cfg.coverage_enabled || this.snf_agent.cfg.coverage_enabled;

    // Standalone scoreboard - integrated streams only (no HN-I in the E env).
    this.rni_agent.req_port.connect(this.scoreboard.rni_req_sb);
    this.rni_agent.rsp_port.connect(this.scoreboard.rni_rsp_sb);
    this.rni_agent.dat_port.connect(this.scoreboard.rni_dat_sb);
    this.snf_agent.req_port.connect(this.scoreboard.snf_req_sb);

    begin
      chi_tb_config tb_cfg;
      if (uvm_config_db #(chi_tb_config)::get(null, "*", "tb_cfg", tb_cfg)) begin
        this.scoreboard.enable     = tb_cfg.scoreboard_enable;
        this.scoreboard.check_data = tb_cfg.scoreboard_check_data;
      end
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Handle Reset
  // ---------------------------------------------------------------------------
  function void handle_reset();

    this.coverage.handle_reset();

    this.scoreboard.handle_reset();
  endfunction

  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    forever begin
      @(negedge this.rni_agent.vif.rst_n);

      this.handle_reset();
    end
  endtask
endclass