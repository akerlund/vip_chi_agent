// ===========================================================================
// chi_e_proxy_tb_env
//
// Wide CHI-E HN-I proxy environment: the CHI-D proxy topology (chi_tb_env)
// re-cast at CHI_E_WIDE_CFG_C. Two dedicated requester agents feed the proxy's
// RN-facing ports and two dedicated responder agents sit behind its SN-facing
// ports, all straddled by a single multi-port HN-I proxy.
//
//   hrni{0,1}_agent (RN-I) --> HN-I proxy --> hsnf{0,1}_agent (SN-F)
//
// The leaves are vip_chi_agent_e so the exact-CHI-E RN-I / SN-F driver and
// monitor variants reach the wire (E-only REQ + DAT-tag fields). The proxy
// itself is the plain vip_chi_hni_agent: vip_chi_driver_hni is a pure per-flit
// relay -- it forwards whole flit structs verbatim and only reads config-
// agnostic fields (opcode/addr/srcid/qos/tgtid) -- so it is CHI-D/E-agnostic
// and needs no _e subclass. Only the flit shapes (from chi_e_wide_types_t)
// widen.
//
// Standalone, like chi_e_tb_env: no virtual sequencer (the CHI-E leaf
// sequencers are #(CHI_E_WIDE_CFG_C); the CHI-D chi_virtual_sequencer holds
// #(CHI_D_CFG_C) handles). Tests start sequences directly on
// hrni{0,1}_agent.sequencer.
// ===========================================================================
class chi_e_proxy_tb_env extends uvm_env;

  typedef vip_chi_item #(CHI_E_WIDE_CFG_C) item_t;

  localparam int HNI_N_RN_PORTS_C = 2;
  localparam int HNI_N_SN_PORTS_C = 2;

  // Proxy RN-facing requester agents (ports 0 and 1) and SN-facing responder
  // agents (targets 0 and 1). Exact-CHI-E variants via vip_chi_agent_e.
  vip_chi_agent_e #(CHI_E_WIDE_CFG_C, chi_e_wide_types_t, VIP_CHI_ROLE_RNI_E) hrni0_agent;
  vip_chi_agent_e #(CHI_E_WIDE_CFG_C, chi_e_wide_types_t, VIP_CHI_ROLE_RNI_E) hrni1_agent;
  vip_chi_agent_e #(CHI_E_WIDE_CFG_C, chi_e_wide_types_t, VIP_CHI_ROLE_SNF_E) hsnf0_agent;
  vip_chi_agent_e #(CHI_E_WIDE_CFG_C, chi_e_wide_types_t, VIP_CHI_ROLE_SNF_E) hsnf1_agent;

  vip_chi_hni_agent #(CHI_E_WIDE_CFG_C, chi_e_wide_types_t, HNI_N_RN_PORTS_C, HNI_N_SN_PORTS_C) hni_agent;

  vip_chi_coverage   #(CHI_E_WIDE_CFG_C) coverage;
  vip_chi_scoreboard #(CHI_E_WIDE_CFG_C) scoreboard;
  vip_chi_perf_counters #(CHI_E_WIDE_CFG_C, chi_e_wide_types_t, VIP_CHI_ROLE_RNI_E) perf;

  // Requester-side observation (proxy RN-facing port 0).
  uvm_tlm_analysis_fifo #(item_t) hrni0_req_fifo;
  uvm_tlm_analysis_fifo #(item_t) hrni0_rsp_fifo;
  uvm_tlm_analysis_fifo #(item_t) hrni0_dat_fifo;

  // Completer-side REQ observation (proves the proxy forwarded to each SN).
  uvm_tlm_analysis_fifo #(item_t) hsnf0_req_fifo;
  uvm_tlm_analysis_fifo #(item_t) hsnf1_req_fifo;

  `uvm_component_utils(chi_e_proxy_tb_env)

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // Build the proxy topology components and observation FIFOs.
  // ---------------------------------------------------------------------------
  function void build_phase(input uvm_phase phase);

    super.build_phase(phase);

    this.hrni0_agent = vip_chi_agent_e #(CHI_E_WIDE_CFG_C, chi_e_wide_types_t, VIP_CHI_ROLE_RNI_E)::type_id::create("hrni0_agent", this);
    this.hrni1_agent = vip_chi_agent_e #(CHI_E_WIDE_CFG_C, chi_e_wide_types_t, VIP_CHI_ROLE_RNI_E)::type_id::create("hrni1_agent", this);
    this.hsnf0_agent = vip_chi_agent_e #(CHI_E_WIDE_CFG_C, chi_e_wide_types_t, VIP_CHI_ROLE_SNF_E)::type_id::create("hsnf0_agent", this);
    this.hsnf1_agent = vip_chi_agent_e #(CHI_E_WIDE_CFG_C, chi_e_wide_types_t, VIP_CHI_ROLE_SNF_E)::type_id::create("hsnf1_agent", this);
    this.hni_agent   = vip_chi_hni_agent #(CHI_E_WIDE_CFG_C, chi_e_wide_types_t, HNI_N_RN_PORTS_C, HNI_N_SN_PORTS_C)::type_id::create("hni_agent", this);
    this.coverage    = vip_chi_coverage #(CHI_E_WIDE_CFG_C)::type_id::create("coverage", this);
    this.scoreboard  = vip_chi_scoreboard #(CHI_E_WIDE_CFG_C)::type_id::create("scoreboard", this);
    this.perf        = vip_chi_perf_counters #(CHI_E_WIDE_CFG_C, chi_e_wide_types_t, VIP_CHI_ROLE_RNI_E)::type_id::create("perf", this);

    this.hrni0_req_fifo = new("hrni0_req_fifo", this);
    this.hrni0_rsp_fifo = new("hrni0_rsp_fifo", this);
    this.hrni0_dat_fifo = new("hrni0_dat_fifo", this);
    this.hsnf0_req_fifo = new("hsnf0_req_fifo", this);
    this.hsnf1_req_fifo = new("hsnf1_req_fifo", this);
  endfunction

  // ---------------------------------------------------------------------------
  // Connect monitor outputs into observation FIFOs, coverage, and the
  // standalone scoreboard (requester lifecycle/data + completer REQ fidelity).
  // ---------------------------------------------------------------------------
  function void connect_phase(input uvm_phase phase);

    super.connect_phase(phase);

    // Requester-side observation (port 0) + forwarded-REQ observation at both
    // SN targets. Tests consume these directly alongside sequence responses.
    this.hrni0_agent.req_port.connect(this.hrni0_req_fifo.analysis_export);
    this.hrni0_agent.rsp_port.connect(this.hrni0_rsp_fifo.analysis_export);
    this.hrni0_agent.dat_port.connect(this.hrni0_dat_fifo.analysis_export);
    this.hsnf0_agent.req_port.connect(this.hsnf0_req_fifo.analysis_export);
    this.hsnf1_agent.req_port.connect(this.hsnf1_req_fifo.analysis_export);

    // Coverage samples one requester + one completer view of the proxied path.
    this.hrni0_agent.req_port.connect(this.coverage.rni_req_cov_port);
    this.hrni0_agent.rsp_port.connect(this.coverage.rni_rsp_cov_port);
    this.hrni0_agent.dat_port.connect(this.coverage.rni_dat_cov_port);
    this.hsnf0_agent.req_port.connect(this.coverage.snf_req_cov_port);

    this.coverage.enabled =
      this.hrni0_agent.cfg.coverage_enabled || this.hsnf0_agent.cfg.coverage_enabled;

    // Perf counters: subscribe to proxy requester port 0 + take its vif as the
    // deterministic cycle/back-pressure source.
    this.hrni0_agent.req_port.connect(this.perf.req_perf);
    this.hrni0_agent.rsp_port.connect(this.perf.rsp_perf);
    this.hrni0_agent.dat_port.connect(this.perf.dat_perf);
    this.perf.vif = this.hrni0_agent.vif;

    // Scoreboard: both proxy requester streams drive lifecycle/data checks;
    // both completer REQ views drive request-fidelity + routing checks.
    this.hrni0_agent.req_port.connect(this.scoreboard.hrni0_req_sb);
    this.hrni0_agent.rsp_port.connect(this.scoreboard.hrni0_rsp_sb);
    this.hrni0_agent.dat_port.connect(this.scoreboard.hrni0_dat_sb);
    this.hrni1_agent.req_port.connect(this.scoreboard.hrni1_req_sb);
    this.hrni1_agent.rsp_port.connect(this.scoreboard.hrni1_rsp_sb);
    this.hrni1_agent.dat_port.connect(this.scoreboard.hrni1_dat_sb);
    this.hsnf0_agent.req_port.connect(this.scoreboard.hsnf0_req_sb);
    this.hsnf1_agent.req_port.connect(this.scoreboard.hsnf1_req_sb);

    begin
      chi_tb_config tb_cfg;

      if (uvm_config_db #(chi_tb_config)::get(null, "*", "tb_cfg", tb_cfg)) begin
        this.scoreboard.enable     = tb_cfg.scoreboard_enable;
        this.scoreboard.check_data = tb_cfg.scoreboard_check_data;
        this.perf.enable           = tb_cfg.perf_enable;
      end
    end

    // Hand the scoreboard the proxy's exact routing policy (SN port count,
    // stride LSB, optional SAM) so Checker B can predict each proxied REQ's SN
    // target. The driver has fetched any config_db SAM by now (agent build).
    this.scoreboard.set_route_policy(
      HNI_N_SN_PORTS_C,
      this.hni_agent.hni_driver.sn_addr_lsb,
      this.hni_agent.hni_driver.sam);
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
  // Watch the RN-facing port-0 reset and forward it into local checker state.
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    forever begin
      @(negedge this.hrni0_agent.vif.rst_n);

      this.handle_reset();
    end
  endtask
  // ---------------------------------------------------------------------------
  // The scoreboard's rules go into the same per-check export as the SVA binds',
  // under its own bind name. They were outside the mechanism entirely until now,
  // which meant a scoreboard check could stop evaluating and no report anywhere
  // would say so.
  // ---------------------------------------------------------------------------
  function void report_phase(input uvm_phase phase);

    super.report_phase(phase);

    this.scoreboard.report_checks();
    this.scoreboard.export_check_csv();
  endfunction
endclass
