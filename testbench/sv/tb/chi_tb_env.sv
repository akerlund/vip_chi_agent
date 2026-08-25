class chi_tb_env extends uvm_env;

  // Integrated RN-I <-> SN-F pair.
  vip_chi_agent #(CHI_D_CFG_C, chi_d_types_t, VIP_CHI_ROLE_RNI_E) rni_agent;
  vip_chi_agent #(CHI_D_CFG_C, chi_d_types_t, VIP_CHI_ROLE_SNF_E) snf_agent;

  // HN-I topology: two dedicated requester agents feeding the proxy's RN-facing
  // ports, and two dedicated responder agents behind its SN-facing ports. These
  // are separate from the integrated pair so no interface is reused across
  // topologies (the top can then wire every link as a static adapter). They sit
  // idle in tests that do not drive them.
  vip_chi_agent #(CHI_D_CFG_C, chi_d_types_t, VIP_CHI_ROLE_RNI_E) hrni0_agent;
  vip_chi_agent #(CHI_D_CFG_C, chi_d_types_t, VIP_CHI_ROLE_RNI_E) hrni1_agent;
  vip_chi_agent #(CHI_D_CFG_C, chi_d_types_t, VIP_CHI_ROLE_SNF_E) hsnf0_agent;
  vip_chi_agent #(CHI_D_CFG_C, chi_d_types_t, VIP_CHI_ROLE_SNF_E) hsnf1_agent;

  localparam int HNI_N_RN_PORTS_C = 2;
  localparam int HNI_N_SN_PORTS_C = 2;

  vip_chi_hni_agent #(CHI_D_CFG_C, chi_d_types_t, HNI_N_RN_PORTS_C, HNI_N_SN_PORTS_C) hni_agent;

  vip_chi_coverage   #(CHI_D_CFG_C) coverage;
  vip_chi_scoreboard #(CHI_D_CFG_C) scoreboard;
  vip_chi_perf_counters #(CHI_D_CFG_C, chi_d_types_t, VIP_CHI_ROLE_RNI_E) perf;
  chi_virtual_sequencer       vseq;

  // Integrated-pair observation FIFOs.
  uvm_tlm_analysis_fifo #(item_t) rni_req_fifo;
  uvm_tlm_analysis_fifo #(item_t) rni_rsp_fifo;
  uvm_tlm_analysis_fifo #(item_t) rni_dat_fifo;
  uvm_tlm_analysis_fifo #(item_t) snf_req_fifo;
  uvm_tlm_analysis_fifo #(item_t) snf_rsp_fifo;
  uvm_tlm_analysis_fifo #(item_t) snf_dat_fifo;

  // HN-I responder REQ observation (proves the proxy forwarded to each SN).
  uvm_tlm_analysis_fifo #(item_t) hsnf0_req_fifo;
  uvm_tlm_analysis_fifo #(item_t) hsnf1_req_fifo;

  `uvm_component_utils(chi_tb_env)

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // Build environment components and analysis FIFOs.
  // ---------------------------------------------------------------------------
  function void build_phase(input uvm_phase phase);

    super.build_phase(phase);

    this.rni_agent   = vip_chi_agent #(CHI_D_CFG_C, chi_d_types_t, VIP_CHI_ROLE_RNI_E)::type_id::create("rni_agent", this);
    this.snf_agent   = vip_chi_agent #(CHI_D_CFG_C, chi_d_types_t, VIP_CHI_ROLE_SNF_E)::type_id::create("snf_agent", this);
    this.hrni0_agent = vip_chi_agent #(CHI_D_CFG_C, chi_d_types_t, VIP_CHI_ROLE_RNI_E)::type_id::create("hrni0_agent", this);
    this.hrni1_agent = vip_chi_agent #(CHI_D_CFG_C, chi_d_types_t, VIP_CHI_ROLE_RNI_E)::type_id::create("hrni1_agent", this);
    this.hsnf0_agent = vip_chi_agent #(CHI_D_CFG_C, chi_d_types_t, VIP_CHI_ROLE_SNF_E)::type_id::create("hsnf0_agent", this);
    this.hsnf1_agent = vip_chi_agent #(CHI_D_CFG_C, chi_d_types_t, VIP_CHI_ROLE_SNF_E)::type_id::create("hsnf1_agent", this);
    this.hni_agent   = vip_chi_hni_agent #(CHI_D_CFG_C, chi_d_types_t, HNI_N_RN_PORTS_C, HNI_N_SN_PORTS_C)::type_id::create("hni_agent", this);
    this.coverage    = vip_chi_coverage #(CHI_D_CFG_C)::type_id::create("coverage", this);
    this.scoreboard  = vip_chi_scoreboard #(CHI_D_CFG_C)::type_id::create("scoreboard", this);
    this.perf        = vip_chi_perf_counters #(CHI_D_CFG_C, chi_d_types_t, VIP_CHI_ROLE_RNI_E)::type_id::create("perf", this);
    this.vseq        = chi_virtual_sequencer::type_id::create("virtual_sequencer", this);

    this.rni_req_fifo   = new("rni_req_fifo", this);
    this.rni_rsp_fifo   = new("rni_rsp_fifo", this);
    this.rni_dat_fifo   = new("rni_dat_fifo", this);
    this.snf_req_fifo   = new("snf_req_fifo", this);
    this.snf_rsp_fifo   = new("snf_rsp_fifo", this);
    this.snf_dat_fifo   = new("snf_dat_fifo", this);
    this.hsnf0_req_fifo = new("hsnf0_req_fifo", this);
    this.hsnf1_req_fifo = new("hsnf1_req_fifo", this);

    uvm_config_db #(chi_virtual_sequencer)::set(
      this, {"virtual_sequencer", "*"}, "virtual_sequencer", this.vseq);
  endfunction

  // ---------------------------------------------------------------------------
  // Connect agent monitor outputs into per-channel observation FIFOs.
  // ---------------------------------------------------------------------------
  function void connect_phase(input uvm_phase phase);

    super.connect_phase(phase);

    // This example env stops at monitor visibility + coverage. Directed tests
    // consume these FIFOs directly instead of routing checking through a
    // scoreboard while the standalone CHI example remains bring-up oriented.
    this.rni_agent.req_port.connect(this.rni_req_fifo.analysis_export);
    this.rni_agent.rsp_port.connect(this.rni_rsp_fifo.analysis_export);
    this.rni_agent.dat_port.connect(this.rni_dat_fifo.analysis_export);
    this.snf_agent.req_port.connect(this.snf_req_fifo.analysis_export);
    this.snf_agent.rsp_port.connect(this.snf_rsp_fifo.analysis_export);
    this.snf_agent.dat_port.connect(this.snf_dat_fifo.analysis_export);
    this.hsnf0_agent.req_port.connect(this.hsnf0_req_fifo.analysis_export);
    this.hsnf1_agent.req_port.connect(this.hsnf1_req_fifo.analysis_export);

    this.rni_agent.req_port.connect(this.coverage.rni_req_cov_port);
    this.rni_agent.rsp_port.connect(this.coverage.rni_rsp_cov_port);
    this.rni_agent.dat_port.connect(this.coverage.rni_dat_cov_port);
    this.snf_agent.req_port.connect(this.coverage.snf_req_cov_port);
    this.snf_agent.rsp_port.connect(this.coverage.snf_rsp_cov_port);
    this.snf_agent.dat_port.connect(this.coverage.snf_dat_cov_port);

    this.coverage.enabled =
      this.rni_agent.cfg.coverage_enabled || this.snf_agent.cfg.coverage_enabled;

    // Perf counters: subscribe to the integrated requester stream + take its vif
    // as the deterministic cycle/back-pressure source.
    this.rni_agent.req_port.connect(this.perf.req_perf);
    this.rni_agent.rsp_port.connect(this.perf.rsp_perf);
    this.rni_agent.dat_port.connect(this.perf.dat_perf);
    this.perf.vif = this.rni_agent.vif;

    // Standalone scoreboard, connected in parallel to the same monitor ports:
    // requester views (integrated + both proxy RNs) drive lifecycle/data checks,
    // completer REQ views drive request-fidelity checks.
    this.rni_agent.req_port.connect(this.scoreboard.rni_req_sb);
    this.rni_agent.rsp_port.connect(this.scoreboard.rni_rsp_sb);
    this.rni_agent.dat_port.connect(this.scoreboard.rni_dat_sb);
    this.hrni0_agent.req_port.connect(this.scoreboard.hrni0_req_sb);
    this.hrni0_agent.rsp_port.connect(this.scoreboard.hrni0_rsp_sb);
    this.hrni0_agent.dat_port.connect(this.scoreboard.hrni0_dat_sb);
    this.hrni1_agent.req_port.connect(this.scoreboard.hrni1_req_sb);
    this.hrni1_agent.rsp_port.connect(this.scoreboard.hrni1_rsp_sb);
    this.hrni1_agent.dat_port.connect(this.scoreboard.hrni1_dat_sb);
    this.snf_agent.req_port.connect(this.scoreboard.snf_req_sb);
    this.hsnf0_agent.req_port.connect(this.scoreboard.hsnf0_req_sb);
    this.hsnf1_agent.req_port.connect(this.scoreboard.hsnf1_req_sb);

    begin
      chi_tb_config tb_cfg;

      if (uvm_config_db #(chi_tb_config)::get(null, "*", "tb_cfg", tb_cfg)) begin
        this.scoreboard.enable      = tb_cfg.scoreboard_enable;
        this.scoreboard.check_data  = tb_cfg.scoreboard_check_data;
        this.scoreboard.check_order = tb_cfg.scoreboard_check_order;
        this.perf.enable            = tb_cfg.perf_enable;
      end
    end

    // Hand the scoreboard the HN-I's exact routing policy (port count, stride
    // LSB, optional SAM) so Checker B can predict each proxied REQ's SN target.
    // The driver has fetched any config_db SAM by now (agent build_phase).
    this.scoreboard.set_route_policy(
      HNI_N_SN_PORTS_C,
      this.hni_agent.hni_driver.sn_addr_lsb,
      this.hni_agent.hni_driver.sam);

    this.vseq.rni_sequencer   = this.rni_agent.sequencer;
    this.vseq.snf_sequencer   = this.snf_agent.sequencer;
    this.vseq.hrni0_sequencer = this.hrni0_agent.sequencer;
    this.vseq.hrni1_sequencer = this.hrni1_agent.sequencer;
  endfunction

  // ---------------------------------------------------------------------------
  // Clear coverage and scoreboard state after a reset pulse.
  // ---------------------------------------------------------------------------
  function void handle_reset();

    this.coverage.handle_reset();

    this.scoreboard.handle_reset();

    this.perf.handle_reset();
  endfunction

  // ---------------------------------------------------------------------------
  // Watch the shared RN-I reset and forward it into local checker state.
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    forever begin
      @(negedge this.rni_agent.vif.rst_n);

      this.handle_reset();
    end
  endtask

  function void report_phase(input uvm_phase phase);

    super.report_phase(phase);

    chi_check_export_csv("rni_sva", CHI_CHECK_SCOPE_MAIN_E,
      this.rni_agent.vif.check_enabled, this.rni_agent.vif.check_severity,
      this.rni_agent.vif.check_pass_count, this.rni_agent.vif.check_fail_count);
    chi_check_export_csv("snf_sva", CHI_CHECK_SCOPE_MAIN_E,
      this.snf_agent.vif.check_enabled, this.snf_agent.vif.check_severity,
      this.snf_agent.vif.check_pass_count, this.snf_agent.vif.check_fail_count);

    chi_check_report_tallies("rni_sva", CHI_CHECK_SCOPE_MAIN_E,
      this.rni_agent.vif.check_enabled, this.rni_agent.vif.check_severity,
      this.rni_agent.vif.check_pass_count, this.rni_agent.vif.check_fail_count);
    chi_check_report_tallies("snf_sva", CHI_CHECK_SCOPE_MAIN_E,
      this.snf_agent.vif.check_enabled, this.snf_agent.vif.check_severity,
      this.snf_agent.vif.check_pass_count, this.snf_agent.vif.check_fail_count);

    // The HN-I proxy topology's eight binds, added. Until then this
    // env exported two rows and owned ten interfaces, and an aggregation over
    // rows cannot report the absence of rows -- so the proxy links read as
    // covered by the two that were there. chi_check_report.svh's own header
    // records this lesson from an earlier occurrence one level down, at the bind
    // rather than at the env.
    chi_check_export_csv("hni_rni0_sva", CHI_CHECK_SCOPE_MAIN_E,
      this.hrni0_agent.vif.check_enabled, this.hrni0_agent.vif.check_severity,
      this.hrni0_agent.vif.check_pass_count, this.hrni0_agent.vif.check_fail_count);
    chi_check_report_tallies("hni_rni0_sva", CHI_CHECK_SCOPE_MAIN_E,
      this.hrni0_agent.vif.check_enabled, this.hrni0_agent.vif.check_severity,
      this.hrni0_agent.vif.check_pass_count, this.hrni0_agent.vif.check_fail_count);
    chi_check_export_csv("hni_rn0_sva", CHI_CHECK_SCOPE_MAIN_E,
      this.hni_agent.rn_vif[0].check_enabled, this.hni_agent.rn_vif[0].check_severity,
      this.hni_agent.rn_vif[0].check_pass_count, this.hni_agent.rn_vif[0].check_fail_count);
    chi_check_report_tallies("hni_rn0_sva", CHI_CHECK_SCOPE_MAIN_E,
      this.hni_agent.rn_vif[0].check_enabled, this.hni_agent.rn_vif[0].check_severity,
      this.hni_agent.rn_vif[0].check_pass_count, this.hni_agent.rn_vif[0].check_fail_count);
    chi_check_export_csv("hni_sn0_sva", CHI_CHECK_SCOPE_MAIN_E,
      this.hni_agent.sn_vif[0].check_enabled, this.hni_agent.sn_vif[0].check_severity,
      this.hni_agent.sn_vif[0].check_pass_count, this.hni_agent.sn_vif[0].check_fail_count);
    chi_check_report_tallies("hni_sn0_sva", CHI_CHECK_SCOPE_MAIN_E,
      this.hni_agent.sn_vif[0].check_enabled, this.hni_agent.sn_vif[0].check_severity,
      this.hni_agent.sn_vif[0].check_pass_count, this.hni_agent.sn_vif[0].check_fail_count);
    chi_check_export_csv("hni_snf0_sva", CHI_CHECK_SCOPE_MAIN_E,
      this.hsnf0_agent.vif.check_enabled, this.hsnf0_agent.vif.check_severity,
      this.hsnf0_agent.vif.check_pass_count, this.hsnf0_agent.vif.check_fail_count);
    chi_check_report_tallies("hni_snf0_sva", CHI_CHECK_SCOPE_MAIN_E,
      this.hsnf0_agent.vif.check_enabled, this.hsnf0_agent.vif.check_severity,
      this.hsnf0_agent.vif.check_pass_count, this.hsnf0_agent.vif.check_fail_count);
    chi_check_export_csv("hni_rni1_sva", CHI_CHECK_SCOPE_MAIN_E,
      this.hrni1_agent.vif.check_enabled, this.hrni1_agent.vif.check_severity,
      this.hrni1_agent.vif.check_pass_count, this.hrni1_agent.vif.check_fail_count);
    chi_check_report_tallies("hni_rni1_sva", CHI_CHECK_SCOPE_MAIN_E,
      this.hrni1_agent.vif.check_enabled, this.hrni1_agent.vif.check_severity,
      this.hrni1_agent.vif.check_pass_count, this.hrni1_agent.vif.check_fail_count);
    chi_check_export_csv("hni_rn1_sva", CHI_CHECK_SCOPE_MAIN_E,
      this.hni_agent.rn_vif[1].check_enabled, this.hni_agent.rn_vif[1].check_severity,
      this.hni_agent.rn_vif[1].check_pass_count, this.hni_agent.rn_vif[1].check_fail_count);
    chi_check_report_tallies("hni_rn1_sva", CHI_CHECK_SCOPE_MAIN_E,
      this.hni_agent.rn_vif[1].check_enabled, this.hni_agent.rn_vif[1].check_severity,
      this.hni_agent.rn_vif[1].check_pass_count, this.hni_agent.rn_vif[1].check_fail_count);
    chi_check_export_csv("hni_sn1_sva", CHI_CHECK_SCOPE_MAIN_E,
      this.hni_agent.sn_vif[1].check_enabled, this.hni_agent.sn_vif[1].check_severity,
      this.hni_agent.sn_vif[1].check_pass_count, this.hni_agent.sn_vif[1].check_fail_count);
    chi_check_report_tallies("hni_sn1_sva", CHI_CHECK_SCOPE_MAIN_E,
      this.hni_agent.sn_vif[1].check_enabled, this.hni_agent.sn_vif[1].check_severity,
      this.hni_agent.sn_vif[1].check_pass_count, this.hni_agent.sn_vif[1].check_fail_count);
    chi_check_export_csv("hni_snf1_sva", CHI_CHECK_SCOPE_MAIN_E,
      this.hsnf1_agent.vif.check_enabled, this.hsnf1_agent.vif.check_severity,
      this.hsnf1_agent.vif.check_pass_count, this.hsnf1_agent.vif.check_fail_count);
    chi_check_report_tallies("hni_snf1_sva", CHI_CHECK_SCOPE_MAIN_E,
      this.hsnf1_agent.vif.check_enabled, this.hsnf1_agent.vif.check_severity,
      this.hsnf1_agent.vif.check_pass_count, this.hsnf1_agent.vif.check_fail_count);

    // The scoreboard's rules go into the SAME export, under its own bind name.
    // They were outside the mechanism entirely until now, which meant a
    // scoreboard check could stop evaluating and no report anywhere would say
    // so.
    this.scoreboard.report_checks();
    this.scoreboard.export_check_csv();
  endfunction
endclass
