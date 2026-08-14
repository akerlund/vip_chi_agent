// ===========================================================================
// chi_coherent_tb_env
//
// Isolated coherent environment: two coherent requesters (RN-F) fanning into a
// single coherent home node (HN-F) that terminates against its own memory +
// directory. Mirrors the standalone shape of chi_e_proxy_tb_env.
//
//   hrnf{0,1}_agent (RN-F) --> HN-F home (vip_chi_hnf_agent, 2 RN ports)
//
// Parameterized by config + flit types so the same topology stands up on both
// the narrow CHI-D config (CHI_D_CFG_C / chi_d_types_t, the default) and the wide
// CHI-E config (CHI_E_WIDE_CFG_C / chi_e_wide_types_t). It uses the base
// vip_chi_agent (not vip_chi_agent_e) even at CHI-E width: the base monitor is
// the one that publishes the SNP channel, and coherent reads do not depend on
// the E-only REQ fields that the _e drivers add.
//
// Standalone, like chi_e_tb_env: no virtual sequencer. Tests start
// sequences directly on hrnf{0,1}_agent.sequencer.
// ===========================================================================
class chi_coherent_tb_env #(
  vip_chi_cfg_t CFG_P   = CHI_D_CFG_C,
  type          TYPES_P = chi_d_types_t
  ) extends uvm_env;

  typedef vip_chi_item #(CFG_P) item_t;

  localparam int HNF_N_RNF_PORTS_C = 2;
  // One downstream SN-F behind the HN-F (RN-F <-> HN-F <-> SN-F). The link is
  // additive/idle unless a test sets cfg.hnf_downstream_en, so the baseline
  // self-terminating coherent tests are byte-unaffected.
  localparam int HNF_N_SN_PORTS_C  = 1;

  // Coherent requester agents feeding the home's two RN-facing ports.
  vip_chi_agent #(CFG_P, TYPES_P, VIP_CHI_ROLE_RNF_E) hrnf0_agent;
  vip_chi_agent #(CFG_P, TYPES_P, VIP_CHI_ROLE_RNF_E) hrnf1_agent;

  // Coherent home node straddling both RN-F links + one downstream SN link.
  vip_chi_hnf_agent #(CFG_P, TYPES_P, HNF_N_RNF_PORTS_C, HNF_N_SN_PORTS_C) hnf_agent;

  // Downstream SN-F memory node behind the HN-F (auto-responder; idle when the
  // HN-F self-terminates).
  vip_chi_agent #(CFG_P, TYPES_P, VIP_CHI_ROLE_SNF_E) dsnf0_agent;

  vip_chi_perf_counters   #(CFG_P, TYPES_P, VIP_CHI_ROLE_RNF_E) perf;
  vip_chi_coherency_checker #(CFG_P)                            coh_checker;
  vip_chi_coverage        #(CFG_P)                              cov;

  // Requester-side observation (port 0). The SNP FIFO lets a test prove zero
  // snoops were seen on the coherent path.
  uvm_tlm_analysis_fifo #(item_t) hrnf0_req_fifo;
  uvm_tlm_analysis_fifo #(item_t) hrnf0_rsp_fifo;
  uvm_tlm_analysis_fifo #(item_t) hrnf0_dat_fifo;
  uvm_tlm_analysis_fifo #(item_t) hrnf0_snp_fifo;

  // Downstream SN-F observation: the REQ FIFO lets a test prove the HN-F issued a
  // ReadNoSnp/WriteNoSnp to the SN-F; the DAT FIFO exposes the SN-F's CompData for
  // the end-to-end integrity seed (Checker D, D4).
  uvm_tlm_analysis_fifo #(item_t) dsnf0_req_fifo;

  `uvm_component_param_utils(chi_coherent_tb_env #(CFG_P, TYPES_P))

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent);
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  // Build the coherent topology components and observation FIFOs.
  // ---------------------------------------------------------------------------
  function void build_phase(input uvm_phase phase);
    super.build_phase(phase);

    this.hrnf0_agent = vip_chi_agent #(CFG_P, TYPES_P, VIP_CHI_ROLE_RNF_E)::type_id::create("hrnf0_agent", this);
    this.hrnf1_agent = vip_chi_agent #(CFG_P, TYPES_P, VIP_CHI_ROLE_RNF_E)::type_id::create("hrnf1_agent", this);
    this.hnf_agent   = vip_chi_hnf_agent #(CFG_P, TYPES_P, HNF_N_RNF_PORTS_C, HNF_N_SN_PORTS_C)::type_id::create("hnf_agent", this);
    this.dsnf0_agent = vip_chi_agent #(CFG_P, TYPES_P, VIP_CHI_ROLE_SNF_E)::type_id::create("dsnf0_agent", this);
    this.perf        = vip_chi_perf_counters #(CFG_P, TYPES_P, VIP_CHI_ROLE_RNF_E)::type_id::create("perf", this);
    this.coh_checker = vip_chi_coherency_checker #(CFG_P)::type_id::create("coh_checker", this);
    this.cov         = vip_chi_coverage #(CFG_P)::type_id::create("cov", this);

    this.hrnf0_req_fifo = new("hrnf0_req_fifo", this);
    this.hrnf0_rsp_fifo = new("hrnf0_rsp_fifo", this);
    this.hrnf0_dat_fifo = new("hrnf0_dat_fifo", this);
    this.hrnf0_snp_fifo = new("hrnf0_snp_fifo", this);
    this.dsnf0_req_fifo = new("dsnf0_req_fifo", this);
  endfunction

  // ---------------------------------------------------------------------------
  // Connect monitor outputs into observation FIFOs and the perf counters.
  // ---------------------------------------------------------------------------
  function void connect_phase(input uvm_phase phase);
    super.connect_phase(phase);

    this.hrnf0_agent.req_port.connect(this.hrnf0_req_fifo.analysis_export);
    this.hrnf0_agent.rsp_port.connect(this.hrnf0_rsp_fifo.analysis_export);
    this.hrnf0_agent.dat_port.connect(this.hrnf0_dat_fifo.analysis_export);
    this.hrnf0_agent.snp_port.connect(this.hrnf0_snp_fifo.analysis_export);

    // Downstream SN-F REQ observation (proves the HN-F issued ReadNoSnp/WriteNoSnp).
    this.dsnf0_agent.req_port.connect(this.dsnf0_req_fifo.analysis_export);

    // Checker D end-to-end integrity across the downstream fetch: correlate the
    // SN-F's ReadNoSnp (addr) + CompData (value) so a downstream-fetched RN-F
    // CompData is checked against what the SN-F actually returned.
    this.dsnf0_agent.req_port.connect(this.coh_checker.snf_req_cc);
    this.dsnf0_agent.dat_port.connect(this.coh_checker.snf_dat_cc);

    // Perf counters: subscribe to requester port 0 + take its vif as the
    // deterministic cycle/back-pressure source.
    this.hrnf0_agent.req_port.connect(this.perf.req_perf);
    this.hrnf0_agent.rsp_port.connect(this.perf.rsp_perf);
    this.hrnf0_agent.dat_port.connect(this.perf.dat_perf);
    this.perf.vif = this.hrnf0_agent.vif;

    // Checker D (coherency invariants) sees both RN-F streams: coherent-read
    // REQ + CompData resolve ownership, snoops transition it. The RSP stream is
    // required for the exclusive (LL/SC) invariant -- the SC's Comp (carrying the
    // ExclOkay/NormalOkay result) rides RSP, which nothing else in the checker
    // consumes; without it the exclusive invariant would be silently vacuous.
    this.hrnf0_agent.req_port.connect(this.coh_checker.rnf0_req_cc);
    this.hrnf0_agent.rsp_port.connect(this.coh_checker.rnf0_rsp_cc);
    this.hrnf0_agent.dat_port.connect(this.coh_checker.rnf0_dat_cc);
    this.hrnf0_agent.snp_port.connect(this.coh_checker.rnf0_snp_cc);
    this.hrnf1_agent.req_port.connect(this.coh_checker.rnf1_req_cc);
    this.hrnf1_agent.rsp_port.connect(this.coh_checker.rnf1_rsp_cc);
    this.hrnf1_agent.dat_port.connect(this.coh_checker.rnf1_dat_cc);
    this.hrnf1_agent.snp_port.connect(this.coh_checker.rnf1_snp_cc);

    this.coh_checker.hazard_check_enable = this.hrnf0_agent.cfg.hazard_check_enable;

    // Coherent functional coverage: both RN-F requester streams feed the shared
    // coverage collector (flit-level coherent groups). The state-dependent
    // cache-transition / directory-occupancy groups live on coh_checker's shadow.
    this.hrnf0_agent.req_port.connect(this.cov.rnf_req_cov_port);
    this.hrnf0_agent.rsp_port.connect(this.cov.rnf_rsp_cov_port);
    this.hrnf0_agent.dat_port.connect(this.cov.rnf_dat_cov_port);
    this.hrnf0_agent.snp_port.connect(this.cov.snp_cov_port);
    this.hrnf1_agent.req_port.connect(this.cov.rnf_req_cov_port);
    this.hrnf1_agent.rsp_port.connect(this.cov.rnf_rsp_cov_port);
    this.hrnf1_agent.dat_port.connect(this.cov.rnf_dat_cov_port);
    this.hrnf1_agent.snp_port.connect(this.cov.snp_cov_port);

    this.cov.enabled =
      this.hrnf0_agent.cfg.coverage_enabled || this.hrnf1_agent.cfg.coverage_enabled;

    begin
      chi_tb_config tb_cfg;

      if (uvm_config_db #(chi_tb_config)::get(null, "*", "tb_cfg", tb_cfg)) begin
        this.perf.enable = tb_cfg.perf_enable;
      end
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Clear checker state after a reset pulse.
  // ---------------------------------------------------------------------------
  function void handle_reset();
    this.perf.handle_reset();
    this.coh_checker.handle_reset();
    this.cov.handle_reset();
  endfunction

  // ---------------------------------------------------------------------------
  // Watch the port-0 requester reset and forward it into local checker state.
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);
    forever begin
      @(negedge this.hrnf0_agent.vif.rst_n);
      this.handle_reset();
    end
  endtask

endclass
