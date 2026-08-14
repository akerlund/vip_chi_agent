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

  // ---------------------------------------------------------------------------
  // Fold the SVA binds' per-check tallies into the UVM verdict, and report which
  // checks never ran.
  //
  // This is what makes a protocol assertion able to FAIL A RUN. The checkers
  // report through plain $error, which raises no UVM error, sets no exit status,
  // and is not read by scripts/sv_regression.sh -- so every assertion in the SV
  // port used to be advisory, printing into a log nothing consumed. Verified
  // before this landed: a deliberately provoked LASM violation printed its error
  // twice, exited 0 with UVM_ERROR : 0, and the sweep scored it a PASS.
  //
  // A rule at severity OFF or WARNING is counted but NOT raised here: the user
  // turned it down on purpose, and overriding that from the env would make the
  // severity control meaningless.
  // ---------------------------------------------------------------------------
  // Takes the arrays rather than the interface handle: a virtual vip_chi_if is
  // typed by ROLE_P, so one signature could not accept both the RN-I and SN-F
  // handles.
  protected function void report_check_tallies(
    input string                   tag,
    input bit                      enabled    [VIP_CHI_CHK_NUM_E],
    input vip_chi_check_severity_t severity   [VIP_CHI_CHK_NUM_E],
    input int unsigned             pass_count [VIP_CHI_CHK_NUM_E],
    input int unsigned             fail_count [VIP_CHI_CHK_NUM_E]
  );
    int unsigned not_exercised;

    not_exercised = 0;

    for (int unsigned id = 0; id < int'(VIP_CHI_CHK_NUM_E); id++) begin
      if (!enabled[id]) begin
        continue;
      end

      if ((fail_count[id] > 0) &&
          (severity[id] == VIP_CHI_CHK_SEV_ERROR_E)) begin
        `uvm_error("VIP_CHI_CHECK", $sformatf(
          "%s: %s failed %0d time(s)",
          tag, vip_chi_check_name(vip_chi_check_id_t'(id)), fail_count[id]))
      end

      if ((pass_count[id] == 0) && (fail_count[id] == 0)) begin
        not_exercised++;
        // ONE LINE PER RULE, not one line carrying a list. The report server
        // wraps at a fixed column, so a list runs off the end and everything
        // past the wrap is lost to a grep -- which is exactly what happened to
        // the first cut of this report: it printed six names and dropped the
        // rest, and a regression-wide sweep built on it returned nonsense.
        `uvm_info("VIP_CHI_CHECK", $sformatf(
          "VIP_CHI CHECK NOT EXERCISED: bind=%s rule=%s",
          tag, vip_chi_check_name(vip_chi_check_id_t'(id))), UVM_LOW)
      end
    end

    // Short, so it cannot wrap: a wrapped field name splits from its value and
    // the sweep that reads it misses.
    `uvm_info("VIP_CHI_CHECK", $sformatf(
      "VIP_CHI CHECK VACUITY: bind=%s not_exercised=%0d of=%0d",
      tag, not_exercised, int'(VIP_CHI_CHK_NUM_E)), UVM_LOW)

  endfunction

  // Append this run's per-rule tallies to a CSV for cross-run aggregation.
  //
  // A regression answers "which check does NOTHING anywhere" only by unioning
  // every run, and no single run can tell you. Appending rather than rewriting
  // is what makes that union work, and each row carries the testcase name so a
  // rule exercised by exactly one test can be traced back to it -- the question
  // you actually ask once a check turns out to be near-vacuous.
  protected function void export_check_csv(
    input string                   tag,
    input bit                      enabled    [VIP_CHI_CHK_NUM_E],
    input vip_chi_check_severity_t severity   [VIP_CHI_CHK_NUM_E],
    input int unsigned             pass_count [VIP_CHI_CHK_NUM_E],
    input int unsigned             fail_count [VIP_CHI_CHK_NUM_E]
  );
    string path;
    string run_name;
    int    fd;

    if (!$value$plusargs("vip_chi_check_csv=%s", path)) begin
      return;
    end

    run_name = "unknown";
    void'($value$plusargs("UVM_TESTNAME=%s", run_name));

    // Append, and write the header only when the file is new -- the aggregation
    // script reads one file produced by a whole sweep.
    fd = $fopen(path, "r");
    if (fd == 0) begin
      fd = $fopen(path, "w");
      if (fd == 0) begin
        `uvm_warning("VIP_CHI_CHECK", $sformatf(
          "could not open %s for the check-tally export", path))
        return;
      end
      $fdisplay(fd, "run,bind,check,enabled,severity,passes,fails");
    end
    else begin
      $fclose(fd);
      fd = $fopen(path, "a");
      if (fd == 0) begin
        `uvm_warning("VIP_CHI_CHECK", $sformatf(
          "could not append to %s for the check-tally export", path))
        return;
      end
    end

    for (int unsigned id = 0; id < int'(VIP_CHI_CHK_NUM_E); id++) begin
      if (vip_chi_check_is_snp(vip_chi_check_id_t'(id))) begin
        continue;
      end
      $fdisplay(fd, "%s,%s,%s,%0d,%s,%0d,%0d",
        run_name, tag, vip_chi_check_name(vip_chi_check_id_t'(id)),
        enabled[id], severity[id].name(), pass_count[id], fail_count[id]);
    end

    $fclose(fd);
  endfunction

  function void report_phase(input uvm_phase phase);

    super.report_phase(phase);

    this.export_check_csv("rni_sva",
      this.rni_agent.vif.check_enabled, this.rni_agent.vif.check_severity,
      this.rni_agent.vif.check_pass_count, this.rni_agent.vif.check_fail_count);
    this.export_check_csv("snf_sva",
      this.snf_agent.vif.check_enabled, this.snf_agent.vif.check_severity,
      this.snf_agent.vif.check_pass_count, this.snf_agent.vif.check_fail_count);

    this.report_check_tallies("rni_sva",
      this.rni_agent.vif.check_enabled, this.rni_agent.vif.check_severity,
      this.rni_agent.vif.check_pass_count, this.rni_agent.vif.check_fail_count);
    this.report_check_tallies("snf_sva",
      this.snf_agent.vif.check_enabled, this.snf_agent.vif.check_severity,
      this.snf_agent.vif.check_pass_count, this.snf_agent.vif.check_fail_count);
  endfunction
endclass
