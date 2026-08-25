module chi_tb_top;

  import uvm_pkg::*;
  import vip_chi_types_pkg::*;
  import vip_chi_agent_pkg::*;
  import chi_tb_pkg::*;
  import chi_tc_pkg::*;

  // ===========================================================================
  // vip_chi example structural top (DUT-less).
  //
  // There is no design under test. This module hosts the CHI interfaces and
  // joins each pair with a chi_link_adapter -- that is the whole job. Every
  // topology (integrated RN-I<->SN-F, the HN-I proxy family, and the wide CHI-E
  // pair) has its OWN dedicated interfaces and agents, all co-existing, so no
  // interface is ever shared and every link is a single static adapter. There
  // is no topology mux, no mode decode, and no fabricated traffic; a test simply
  // drives sequences on the agents of the topology it exercises.
  //
  //   integrated : rni_if            <-> snf_if
  //   HN-I RN0/1 : hni_rni{0,1}_if   <-> hni_rn{0,1}_if
  //   HN-I SN0/1 : hni_sn{0,1}_if    <-> hni_snf{0,1}_if
  //   CHI-E      : chi_e_wide_rni_if <-> chi_e_wide_snf_if
  //
  // The only non-adapter content is unavoidable bench scaffolding, none of which
  // touches protocol traffic:
  //   - clock / reset generation, including a test-requestable mid-run reset
  //     pulse (tc_chi_d_reset / tc_chi_d_link_reactivation);
  //   - the config_db handoff of each vif to its agent, then run_test().
  //
  // Notably NOT here anymore: credit hold/replay (now an RN-I driver cfg knob,
  // cfg.hold_dat_credit, so the integrated link is a plain adapter) and any
  // SVA-enable logic (each bind's checks_enable is an inline expression on its
  // own interface's link-active, so idle/unbuilt interfaces stay quiet).
  // ===========================================================================

  logic clk;
  logic rst_n;
  logic rst_n_int;
  int   reset_pulse_countdown;
  chi_tb_config tb_cfg;

  // --- Interface instances ----------------------------------------------------
  // One vip_chi_if per agent endpoint, role-typed, clocked on clk / rst_n_int.
  // Dedicated per topology so nothing is reused across topologies.

  // Integrated RN-I <-> SN-F.
  vip_chi_if #(.CFG_P(CHI_D_CFG_C),.FLIT_TYPES_T(chi_d_types_t),.ROLE_P(VIP_CHI_ROLE_RNI_E))
    rni_if (.clk(clk),.rst_n(rst_n_int));
  vip_chi_if #(.CFG_P(CHI_D_CFG_C),.FLIT_TYPES_T(chi_d_types_t),.ROLE_P(VIP_CHI_ROLE_SNF_E))
    snf_if (.clk(clk),.rst_n(rst_n_int));

  // HN-I requester agents (RN-I polarity) feeding the proxy's RN-facing ports.
  vip_chi_if #(.CFG_P(CHI_D_CFG_C),.FLIT_TYPES_T(chi_d_types_t),.ROLE_P(VIP_CHI_ROLE_RNI_E))
    hni_rni0_if (.clk(clk),.rst_n(rst_n_int));
  vip_chi_if #(.CFG_P(CHI_D_CFG_C),.FLIT_TYPES_T(chi_d_types_t),.ROLE_P(VIP_CHI_ROLE_RNI_E))
    hni_rni1_if (.clk(clk),.rst_n(rst_n_int));

  // HN-I proxy RN-facing ports (HN-I polarity = SN-F signal directions).
  vip_chi_if #(.CFG_P(CHI_D_CFG_C),.FLIT_TYPES_T(chi_d_types_t),.ROLE_P(VIP_CHI_ROLE_HNI_E))
    hni_rn0_if (.clk(clk),.rst_n(rst_n_int));
  vip_chi_if #(.CFG_P(CHI_D_CFG_C),.FLIT_TYPES_T(chi_d_types_t),.ROLE_P(VIP_CHI_ROLE_HNI_E))
    hni_rn1_if (.clk(clk),.rst_n(rst_n_int));

  // HN-I proxy SN-facing ports (RN-I polarity: the proxy is the requester here).
  vip_chi_if #(.CFG_P(CHI_D_CFG_C),.FLIT_TYPES_T(chi_d_types_t),.ROLE_P(VIP_CHI_ROLE_RNI_E))
    hni_sn0_if (.clk(clk),.rst_n(rst_n_int));
  vip_chi_if #(.CFG_P(CHI_D_CFG_C),.FLIT_TYPES_T(chi_d_types_t),.ROLE_P(VIP_CHI_ROLE_RNI_E))
    hni_sn1_if (.clk(clk),.rst_n(rst_n_int));

  // HN-I responder agents (SN-F polarity) behind the proxy's SN-facing ports.
  vip_chi_if #(.CFG_P(CHI_D_CFG_C),.FLIT_TYPES_T(chi_d_types_t),.ROLE_P(VIP_CHI_ROLE_SNF_E))
    hni_snf0_if (.clk(clk),.rst_n(rst_n_int));
  vip_chi_if #(.CFG_P(CHI_D_CFG_C),.FLIT_TYPES_T(chi_d_types_t),.ROLE_P(VIP_CHI_ROLE_SNF_E))
    hni_snf1_if (.clk(clk),.rst_n(rst_n_int));

  // Wide CHI-D compile-coverage anchors: no executable test instantiates
  // vip_chi_if at this width, so these unconnected instances are the only thing
  // that forces the interface to elaborate at the wider flit shape. Leave in place.
  vip_chi_if #(.CFG_P(CHI_D_WIDE_CFG_C),.FLIT_TYPES_T(chi_d_wide_types_t),.ROLE_P(VIP_CHI_ROLE_RNI_E))
    chi_d_wide_rni_if (.clk(clk),.rst_n(rst_n_int));
  vip_chi_if #(.CFG_P(CHI_D_WIDE_CFG_C),.FLIT_TYPES_T(chi_d_wide_types_t),.ROLE_P(VIP_CHI_ROLE_SNF_E))
    chi_d_wide_snf_if (.clk(clk),.rst_n(rst_n_int));

  // Wide CHI-E datapath: real RN-I + SN-F agent pair (chi_e_tb_env).
  vip_chi_if #(.CFG_P(CHI_E_WIDE_CFG_C),.FLIT_TYPES_T(chi_e_wide_types_t),.ROLE_P(VIP_CHI_ROLE_RNI_E))
    chi_e_wide_rni_if (.clk(clk),.rst_n(rst_n_int));
  vip_chi_if #(.CFG_P(CHI_E_WIDE_CFG_C),.FLIT_TYPES_T(chi_e_wide_types_t),.ROLE_P(VIP_CHI_ROLE_SNF_E))
    chi_e_wide_snf_if (.clk(clk),.rst_n(rst_n_int));

  // Compile-coverage anchor for the HN-I role at the wide CHI-E config. The live
  // CHI-E proxy ports below (e_hni_rn{0,1}_if) now also elaborate hni_cb under
  // CHI-E flit shapes; this unconnected anchor is kept for parity with the
  // CHI-D-wide anchor above and stays idle.
  vip_chi_if #(.CFG_P(CHI_E_WIDE_CFG_C),.FLIT_TYPES_T(chi_e_wide_types_t),.ROLE_P(VIP_CHI_ROLE_HNI_E))
    chi_e_wide_hni_if (.clk(clk),.rst_n(rst_n_int));

  // Wide CHI-E HN-I proxy topology (chi_e_proxy_tb_env): 2 RN-facing
  // requesters x 2 SN-facing responders, mirroring the CHI-D proxy at CHI-E
  // width. Requester agents (RN-I polarity) feed the proxy's RN-facing ports;
  // the proxy's SN-facing ports (RN-I polarity) drive the responder agents.
  vip_chi_if #(.CFG_P(CHI_E_WIDE_CFG_C),.FLIT_TYPES_T(chi_e_wide_types_t),.ROLE_P(VIP_CHI_ROLE_RNI_E))
    e_hni_rni0_if (.clk(clk),.rst_n(rst_n_int));
  vip_chi_if #(.CFG_P(CHI_E_WIDE_CFG_C),.FLIT_TYPES_T(chi_e_wide_types_t),.ROLE_P(VIP_CHI_ROLE_RNI_E))
    e_hni_rni1_if (.clk(clk),.rst_n(rst_n_int));

  vip_chi_if #(.CFG_P(CHI_E_WIDE_CFG_C),.FLIT_TYPES_T(chi_e_wide_types_t),.ROLE_P(VIP_CHI_ROLE_HNI_E))
    e_hni_rn0_if (.clk(clk),.rst_n(rst_n_int));
  vip_chi_if #(.CFG_P(CHI_E_WIDE_CFG_C),.FLIT_TYPES_T(chi_e_wide_types_t),.ROLE_P(VIP_CHI_ROLE_HNI_E))
    e_hni_rn1_if (.clk(clk),.rst_n(rst_n_int));

  vip_chi_if #(.CFG_P(CHI_E_WIDE_CFG_C),.FLIT_TYPES_T(chi_e_wide_types_t),.ROLE_P(VIP_CHI_ROLE_RNI_E))
    e_hni_sn0_if (.clk(clk),.rst_n(rst_n_int));
  vip_chi_if #(.CFG_P(CHI_E_WIDE_CFG_C),.FLIT_TYPES_T(chi_e_wide_types_t),.ROLE_P(VIP_CHI_ROLE_RNI_E))
    e_hni_sn1_if (.clk(clk),.rst_n(rst_n_int));

  vip_chi_if #(.CFG_P(CHI_E_WIDE_CFG_C),.FLIT_TYPES_T(chi_e_wide_types_t),.ROLE_P(VIP_CHI_ROLE_SNF_E))
    e_hni_snf0_if (.clk(clk),.rst_n(rst_n_int));
  vip_chi_if #(.CFG_P(CHI_E_WIDE_CFG_C),.FLIT_TYPES_T(chi_e_wide_types_t),.ROLE_P(VIP_CHI_ROLE_SNF_E))
    e_hni_snf1_if (.clk(clk),.rst_n(rst_n_int));

  // Isolated coherent RN-F <-> HN-F links (CHI-D): two requester links, each
  // paired with a home-facing link and joined by an adapter below.
  vip_chi_if #(.CFG_P(CHI_D_CFG_C),.FLIT_TYPES_T(chi_d_types_t),.ROLE_P(VIP_CHI_ROLE_RNF_E))
    coh_rnf0_if (.clk(clk),.rst_n(rst_n_int));
  vip_chi_if #(.CFG_P(CHI_D_CFG_C),.FLIT_TYPES_T(chi_d_types_t),.ROLE_P(VIP_CHI_ROLE_RNF_E))
    coh_rnf1_if (.clk(clk),.rst_n(rst_n_int));
  vip_chi_if #(.CFG_P(CHI_D_CFG_C),.FLIT_TYPES_T(chi_d_types_t),.ROLE_P(VIP_CHI_ROLE_HNF_E))
    coh_hnf0_if (.clk(clk),.rst_n(rst_n_int));
  vip_chi_if #(.CFG_P(CHI_D_CFG_C),.FLIT_TYPES_T(chi_d_types_t),.ROLE_P(VIP_CHI_ROLE_HNF_E))
    coh_hnf1_if (.clk(clk),.rst_n(rst_n_int));

  // Downstream SN-F behind the coherent HN-F (CHI-D): the HN-F is the requester
  // (RN-I polarity) toward a real SN-F memory node. Idle unless hnf_downstream_en.
  vip_chi_if #(.CFG_P(CHI_D_CFG_C),.FLIT_TYPES_T(chi_d_types_t),.ROLE_P(VIP_CHI_ROLE_RNI_E))
    coh_hnf0_sn_if (.clk(clk),.rst_n(rst_n_int));
  vip_chi_if #(.CFG_P(CHI_D_CFG_C),.FLIT_TYPES_T(chi_d_types_t),.ROLE_P(VIP_CHI_ROLE_SNF_E))
    coh_dsnf0_if (.clk(clk),.rst_n(rst_n_int));

  // Isolated coherent RN-F <-> HN-F links (CHI-E): the same coherent topology
  // brought up on the wide CHI-E config to prove parity (vip_chi_coherent_e_*).
  vip_chi_if #(.CFG_P(CHI_E_WIDE_CFG_C),.FLIT_TYPES_T(chi_e_wide_types_t),.ROLE_P(VIP_CHI_ROLE_RNF_E))
    coh_e_rnf0_if (.clk(clk),.rst_n(rst_n_int));
  vip_chi_if #(.CFG_P(CHI_E_WIDE_CFG_C),.FLIT_TYPES_T(chi_e_wide_types_t),.ROLE_P(VIP_CHI_ROLE_RNF_E))
    coh_e_rnf1_if (.clk(clk),.rst_n(rst_n_int));
  vip_chi_if #(.CFG_P(CHI_E_WIDE_CFG_C),.FLIT_TYPES_T(chi_e_wide_types_t),.ROLE_P(VIP_CHI_ROLE_HNF_E))
    coh_e_hnf0_if (.clk(clk),.rst_n(rst_n_int));
  vip_chi_if #(.CFG_P(CHI_E_WIDE_CFG_C),.FLIT_TYPES_T(chi_e_wide_types_t),.ROLE_P(VIP_CHI_ROLE_HNF_E))
    coh_e_hnf1_if (.clk(clk),.rst_n(rst_n_int));

  // Downstream SN-F behind the coherent HN-F (CHI-E parity).
  vip_chi_if #(.CFG_P(CHI_E_WIDE_CFG_C),.FLIT_TYPES_T(chi_e_wide_types_t),.ROLE_P(VIP_CHI_ROLE_RNI_E))
    coh_e_hnf0_sn_if (.clk(clk),.rst_n(rst_n_int));
  vip_chi_if #(.CFG_P(CHI_E_WIDE_CFG_C),.FLIT_TYPES_T(chi_e_wide_types_t),.ROLE_P(VIP_CHI_ROLE_SNF_E))
    coh_e_dsnf0_if (.clk(clk),.rst_n(rst_n_int));

  // Agent-free A0 link: a third width shape (7-bit node IDs, 32-byte data bus)
  // driven directly by tc_chi_a0_smoke rather than by any agent, so the
  // interface and the link adapter are exercised at a geometry no other SV link
  // here uses. Idle in every other testcase.
  vip_chi_if #(.CFG_P(CHI_A0_CFG_C),.FLIT_TYPES_T(chi_a0_types_t),.ROLE_P(VIP_CHI_ROLE_RNI_E))
    a0_rni_if (.clk(clk),.rst_n(rst_n_int));
  vip_chi_if #(.CFG_P(CHI_A0_CFG_C),.FLIT_TYPES_T(chi_a0_types_t),.ROLE_P(VIP_CHI_ROLE_SNF_E))
    a0_snf_if (.clk(clk),.rst_n(rst_n_int));

  // --- Protocol-checker (vip_chi_sva) binds -----------------------------------
  // checks_enable is an inline expression on each interface's own link-active:
  // an interface whose agent is not built/driving never activates its link, so
  // its `=== 1'b1` gate stays low (x-safe) and it raises no spurious assertions.
  //
  // dat_reorder_allowed stands the DataID-ordering checks down on every bind.
  // Only a testcase whose completer deliberately emits DAT beats out of DataID
  // order raises it, through tb_cfg (see the always_ff that latches tb_cfg
  // below); the beat-count, TxnID and credit checks are unaffected either way.
  // No declaration initializer: the always_ff below is the only driver, and a
  // declaration assignment counts as a second procedural driver (ICPD_INIT).
  // The reset branch there is what makes it 0 before any traffic.
  bit chi_dat_reorder_allowed;

  // dat_interleave_allowed stands down the checks that read one FLITPEND run as
  // one transfer. Only a testcase whose completer interleaves the beats of
  // several reads raises it, through tb_cfg. Same latched plumbing, same reason.
  bit chi_dat_interleave_allowed;

  // Cycles a sender may keep TXSACTIVE up past the close of its outstanding
  // window. Same tb_cfg-latched plumbing as chi_dat_reorder_allowed above, and
  // for the same reason: a testcase sets it at run time.
  int chi_txsactive_extend_max_cycles;

  // Cycles the LASM may dwell in ACTIVATE / DEACTIVATE before the checkers call
  // the link stuck; 0 disables. Same tb_cfg-latched plumbing again.
  int chi_link_activation_timeout_cycles;
  int chi_link_deactivation_timeout_cycles;

  vip_chi_sva #(.CFG_P(CHI_D_CFG_C),.FLIT_TYPES_T(chi_d_types_t),.ROLE_P(VIP_CHI_ROLE_RNI_E))
    rni_sva (.vif(rni_if),
      .checks_enable((rni_if.txlinkactivereq === 1'b1) || (rni_if.rxlinkactivereq === 1'b1)),
      .dat_reorder_allowed(chi_dat_reorder_allowed),
      .dat_interleave_allowed(chi_dat_interleave_allowed),
      .txsactive_extend_max_cycles(chi_txsactive_extend_max_cycles),
      .link_activation_timeout_cycles(chi_link_activation_timeout_cycles),
      .link_deactivation_timeout_cycles(chi_link_deactivation_timeout_cycles));
  vip_chi_sva #(.CFG_P(CHI_D_CFG_C),.FLIT_TYPES_T(chi_d_types_t),.ROLE_P(VIP_CHI_ROLE_SNF_E))
    snf_sva (.vif(snf_if),
      .checks_enable((snf_if.txlinkactivereq === 1'b1) || (snf_if.rxlinkactivereq === 1'b1)),
      .dat_reorder_allowed(chi_dat_reorder_allowed),
      .dat_interleave_allowed(chi_dat_interleave_allowed),
      .txsactive_extend_max_cycles(chi_txsactive_extend_max_cycles),
      .link_activation_timeout_cycles(chi_link_activation_timeout_cycles),
      .link_deactivation_timeout_cycles(chi_link_deactivation_timeout_cycles));
  vip_chi_sva #(.CFG_P(CHI_E_WIDE_CFG_C),.FLIT_TYPES_T(chi_e_wide_types_t),.ROLE_P(VIP_CHI_ROLE_RNI_E))
    rni_e_sva (.vif(chi_e_wide_rni_if),
      .checks_enable((chi_e_wide_rni_if.txlinkactivereq === 1'b1) || (chi_e_wide_rni_if.rxlinkactivereq === 1'b1)),
      .dat_reorder_allowed(chi_dat_reorder_allowed),
      .dat_interleave_allowed(chi_dat_interleave_allowed),
      .txsactive_extend_max_cycles(chi_txsactive_extend_max_cycles),
      .link_activation_timeout_cycles(chi_link_activation_timeout_cycles),
      .link_deactivation_timeout_cycles(chi_link_deactivation_timeout_cycles));
  vip_chi_sva #(.CFG_P(CHI_E_WIDE_CFG_C),.FLIT_TYPES_T(chi_e_wide_types_t),.ROLE_P(VIP_CHI_ROLE_SNF_E))
    snf_e_sva (.vif(chi_e_wide_snf_if),
      .checks_enable((chi_e_wide_snf_if.txlinkactivereq === 1'b1) || (chi_e_wide_snf_if.rxlinkactivereq === 1'b1)),
      .dat_reorder_allowed(chi_dat_reorder_allowed),
      .dat_interleave_allowed(chi_dat_interleave_allowed),
      .txsactive_extend_max_cycles(chi_txsactive_extend_max_cycles),
      .link_activation_timeout_cycles(chi_link_activation_timeout_cycles),
      .link_deactivation_timeout_cycles(chi_link_deactivation_timeout_cycles));

  // Coherent REQ/RSP/DAT checker binds. The SNP channel has a separate checker
  // below; the RN-F endpoint sees the full coherent REQ/RSP/DAT link traffic while
  // avoiding duplicate HN-F-side assertion elaboration.
  //
  // These four used to sit behind `ifdef VIP_CHI_ENABLE_COH_REQ_DAT_SVA, on the
  // grounds that "VCS assertion elaboration can dominate default build time on
  // the full example top". Nothing in the repository ever defined it -- not a
  // build script, not a .core target, not a Makefile, from the first commit
  // onward -- so the guard was never paid for and never measured. Measured
  // since, on this top with VCS X-2025.06: elaboration goes 0.155s -> 0.156s,
  // compile 8.874s -> 9.119s. One millisecond of the cost the comment claimed,
  // against 48 of the 54 registry rules that were unbound on every coherent
  // link in every SV run ever made.
  //
  // Which was worse than a gap, because it reported as success: the tallies
  // live on the interface, not in the bind, so chi_coherent_tb_env exported a
  // full set of rows for an absent checker -- 3243 rows, zero passes, zero
  // fails -- and check_vacuity.py joins on check NAME, so every rule was
  // covered by rni_sva elsewhere and nothing came back NEVER. A coherent link
  // with no checker on it looked exactly like a clean one.
  //
  // Unconditional now. If a future top does make this cost real, gate it on
  // something the vacuity report can see, not on a define whose absence is
  // indistinguishable from a pass.
  vip_chi_sva #(.CFG_P(CHI_D_CFG_C),.FLIT_TYPES_T(chi_d_types_t),.ROLE_P(VIP_CHI_ROLE_RNF_E),
                .ENABLE_COMPLETION_TIMEOUT_P(1'b0))
    coh_rnf0_sva (.vif(coh_rnf0_if),
      .checks_enable((coh_rnf0_if.txlinkactivereq === 1'b1) || (coh_rnf0_if.rxlinkactivereq === 1'b1)),
      .dat_reorder_allowed(chi_dat_reorder_allowed),
      .dat_interleave_allowed(chi_dat_interleave_allowed),
      .txsactive_extend_max_cycles(chi_txsactive_extend_max_cycles),
      .link_activation_timeout_cycles(chi_link_activation_timeout_cycles),
      .link_deactivation_timeout_cycles(chi_link_deactivation_timeout_cycles));
  vip_chi_sva #(.CFG_P(CHI_D_CFG_C),.FLIT_TYPES_T(chi_d_types_t),.ROLE_P(VIP_CHI_ROLE_RNF_E),
                .ENABLE_COMPLETION_TIMEOUT_P(1'b0))
    coh_rnf1_sva (.vif(coh_rnf1_if),
      .checks_enable((coh_rnf1_if.txlinkactivereq === 1'b1) || (coh_rnf1_if.rxlinkactivereq === 1'b1)),
      .dat_reorder_allowed(chi_dat_reorder_allowed),
      .dat_interleave_allowed(chi_dat_interleave_allowed),
      .txsactive_extend_max_cycles(chi_txsactive_extend_max_cycles),
      .link_activation_timeout_cycles(chi_link_activation_timeout_cycles),
      .link_deactivation_timeout_cycles(chi_link_deactivation_timeout_cycles));
  vip_chi_sva #(.CFG_P(CHI_E_WIDE_CFG_C),.FLIT_TYPES_T(chi_e_wide_types_t),.ROLE_P(VIP_CHI_ROLE_RNF_E),
                .ENABLE_COMPLETION_TIMEOUT_P(1'b0))
    coh_e_rnf0_sva (.vif(coh_e_rnf0_if),
      .checks_enable((coh_e_rnf0_if.txlinkactivereq === 1'b1) || (coh_e_rnf0_if.rxlinkactivereq === 1'b1)),
      .dat_reorder_allowed(chi_dat_reorder_allowed),
      .dat_interleave_allowed(chi_dat_interleave_allowed),
      .txsactive_extend_max_cycles(chi_txsactive_extend_max_cycles),
      .link_activation_timeout_cycles(chi_link_activation_timeout_cycles),
      .link_deactivation_timeout_cycles(chi_link_deactivation_timeout_cycles));
  vip_chi_sva #(.CFG_P(CHI_E_WIDE_CFG_C),.FLIT_TYPES_T(chi_e_wide_types_t),.ROLE_P(VIP_CHI_ROLE_RNF_E),
                .ENABLE_COMPLETION_TIMEOUT_P(1'b0))
    coh_e_rnf1_sva (.vif(coh_e_rnf1_if),
      .checks_enable((coh_e_rnf1_if.txlinkactivereq === 1'b1) || (coh_e_rnf1_if.rxlinkactivereq === 1'b1)),
      .dat_reorder_allowed(chi_dat_reorder_allowed),
      .dat_interleave_allowed(chi_dat_interleave_allowed),
      .txsactive_extend_max_cycles(chi_txsactive_extend_max_cycles),
      .link_activation_timeout_cycles(chi_link_activation_timeout_cycles),
      .link_deactivation_timeout_cycles(chi_link_deactivation_timeout_cycles));

  // REQ/RSP/DAT checker on the HN-F side of each coherent link.
  //
  // The HN-F endpoint carried only vip_chi_snp_sva, which has no TXSACTIVE
  // property, so the sideband of the one role that gets it wrong was watched
  // from neither direction: the RN-F bind opposite judges its OWN txsactive, on
  // a different interface. Neither endpoint had evidence for it, because neither
  // was bound.
  //
  // ENABLE_COMPLETION_TIMEOUT_P is 1'b0 for the same reason the RN-F binds pass
  // it: on a coherent link the completion the timeout waits for is not paired
  // with its request by this checker.
  //
  // TXSACTIVE_DEASSERT_BOUNDED is NOT stood down here. It was, briefly, while
  // rn_credit_loop still drove txsactive from rn_link_up[p] every cycle -- the
  // sideband never dropped and the rule reported a signal carrying no
  // information, correctly. The driver now drives it from a counted window with
  // a single owner, so the rule has something real to judge and judges it.
  vip_chi_sva #(.CFG_P(CHI_D_CFG_C),.FLIT_TYPES_T(chi_d_types_t),.ROLE_P(VIP_CHI_ROLE_HNF_E),
                .ENABLE_COMPLETION_TIMEOUT_P(1'b0))
    coh_hnf0_sva (.vif(coh_hnf0_if),
      .checks_enable((coh_hnf0_if.txlinkactivereq === 1'b1) || (coh_hnf0_if.rxlinkactivereq === 1'b1)),
      .dat_reorder_allowed(chi_dat_reorder_allowed),
      .dat_interleave_allowed(chi_dat_interleave_allowed),
      .txsactive_extend_max_cycles(chi_txsactive_extend_max_cycles),
      .link_activation_timeout_cycles(chi_link_activation_timeout_cycles),
      .link_deactivation_timeout_cycles(chi_link_deactivation_timeout_cycles));
  vip_chi_sva #(.CFG_P(CHI_D_CFG_C),.FLIT_TYPES_T(chi_d_types_t),.ROLE_P(VIP_CHI_ROLE_HNF_E),
                .ENABLE_COMPLETION_TIMEOUT_P(1'b0))
    coh_hnf1_sva (.vif(coh_hnf1_if),
      .checks_enable((coh_hnf1_if.txlinkactivereq === 1'b1) || (coh_hnf1_if.rxlinkactivereq === 1'b1)),
      .dat_reorder_allowed(chi_dat_reorder_allowed),
      .dat_interleave_allowed(chi_dat_interleave_allowed),
      .txsactive_extend_max_cycles(chi_txsactive_extend_max_cycles),
      .link_activation_timeout_cycles(chi_link_activation_timeout_cycles),
      .link_deactivation_timeout_cycles(chi_link_deactivation_timeout_cycles));
  vip_chi_sva #(.CFG_P(CHI_E_WIDE_CFG_C),.FLIT_TYPES_T(chi_e_wide_types_t),.ROLE_P(VIP_CHI_ROLE_HNF_E),
                .ENABLE_COMPLETION_TIMEOUT_P(1'b0))
    coh_e_hnf0_sva (.vif(coh_e_hnf0_if),
      .checks_enable((coh_e_hnf0_if.txlinkactivereq === 1'b1) || (coh_e_hnf0_if.rxlinkactivereq === 1'b1)),
      .dat_reorder_allowed(chi_dat_reorder_allowed),
      .dat_interleave_allowed(chi_dat_interleave_allowed),
      .txsactive_extend_max_cycles(chi_txsactive_extend_max_cycles),
      .link_activation_timeout_cycles(chi_link_activation_timeout_cycles),
      .link_deactivation_timeout_cycles(chi_link_deactivation_timeout_cycles));
  vip_chi_sva #(.CFG_P(CHI_E_WIDE_CFG_C),.FLIT_TYPES_T(chi_e_wide_types_t),.ROLE_P(VIP_CHI_ROLE_HNF_E),
                .ENABLE_COMPLETION_TIMEOUT_P(1'b0))
    coh_e_hnf1_sva (.vif(coh_e_hnf1_if),
      .checks_enable((coh_e_hnf1_if.txlinkactivereq === 1'b1) || (coh_e_hnf1_if.rxlinkactivereq === 1'b1)),
      .dat_reorder_allowed(chi_dat_reorder_allowed),
      .dat_interleave_allowed(chi_dat_interleave_allowed),
      .txsactive_extend_max_cycles(chi_txsactive_extend_max_cycles),
      .link_activation_timeout_cycles(chi_link_activation_timeout_cycles),
      .link_deactivation_timeout_cycles(chi_link_deactivation_timeout_cycles));

  // SNP-channel protocol checker on the coherent RN-F / HN-F links. Role-agnostic:
  // the HN-F side exercises the txsnp send-credit shadow, the RN-F side the rxsnp
  // receive shadow. Same x-safe link-active gate as the REQ/RSP/DAT binds above.
  vip_chi_snp_sva #(.CFG_P(CHI_D_CFG_C),.FLIT_TYPES_T(chi_d_types_t),.ROLE_P(VIP_CHI_ROLE_HNF_E))
    coh_hnf0_snp_sva (.vif(coh_hnf0_if),
      .checks_enable((coh_hnf0_if.txlinkactivereq === 1'b1) || (coh_hnf0_if.rxlinkactivereq === 1'b1)));
  vip_chi_snp_sva #(.CFG_P(CHI_D_CFG_C),.FLIT_TYPES_T(chi_d_types_t),.ROLE_P(VIP_CHI_ROLE_HNF_E))
    coh_hnf1_snp_sva (.vif(coh_hnf1_if),
      .checks_enable((coh_hnf1_if.txlinkactivereq === 1'b1) || (coh_hnf1_if.rxlinkactivereq === 1'b1)));
  vip_chi_snp_sva #(.CFG_P(CHI_D_CFG_C),.FLIT_TYPES_T(chi_d_types_t),.ROLE_P(VIP_CHI_ROLE_RNF_E))
    coh_rnf0_snp_sva (.vif(coh_rnf0_if),
      .checks_enable((coh_rnf0_if.txlinkactivereq === 1'b1) || (coh_rnf0_if.rxlinkactivereq === 1'b1)));
  vip_chi_snp_sva #(.CFG_P(CHI_D_CFG_C),.FLIT_TYPES_T(chi_d_types_t),.ROLE_P(VIP_CHI_ROLE_RNF_E))
    coh_rnf1_snp_sva (.vif(coh_rnf1_if),
      .checks_enable((coh_rnf1_if.txlinkactivereq === 1'b1) || (coh_rnf1_if.rxlinkactivereq === 1'b1)));

  // Same SNP-channel checker on the CHI-E coherent links.
  vip_chi_snp_sva #(.CFG_P(CHI_E_WIDE_CFG_C),.FLIT_TYPES_T(chi_e_wide_types_t),.ROLE_P(VIP_CHI_ROLE_HNF_E))
    coh_e_hnf0_snp_sva (.vif(coh_e_hnf0_if),
      .checks_enable((coh_e_hnf0_if.txlinkactivereq === 1'b1) || (coh_e_hnf0_if.rxlinkactivereq === 1'b1)));
  vip_chi_snp_sva #(.CFG_P(CHI_E_WIDE_CFG_C),.FLIT_TYPES_T(chi_e_wide_types_t),.ROLE_P(VIP_CHI_ROLE_HNF_E))
    coh_e_hnf1_snp_sva (.vif(coh_e_hnf1_if),
      .checks_enable((coh_e_hnf1_if.txlinkactivereq === 1'b1) || (coh_e_hnf1_if.rxlinkactivereq === 1'b1)));
  vip_chi_snp_sva #(.CFG_P(CHI_E_WIDE_CFG_C),.FLIT_TYPES_T(chi_e_wide_types_t),.ROLE_P(VIP_CHI_ROLE_RNF_E))
    coh_e_rnf0_snp_sva (.vif(coh_e_rnf0_if),
      .checks_enable((coh_e_rnf0_if.txlinkactivereq === 1'b1) || (coh_e_rnf0_if.rxlinkactivereq === 1'b1)));
  vip_chi_snp_sva #(.CFG_P(CHI_E_WIDE_CFG_C),.FLIT_TYPES_T(chi_e_wide_types_t),.ROLE_P(VIP_CHI_ROLE_RNF_E))
    coh_e_rnf1_snp_sva (.vif(coh_e_rnf1_if),
      .checks_enable((coh_e_rnf1_if.txlinkactivereq === 1'b1) || (coh_e_rnf1_if.rxlinkactivereq === 1'b1)));


  // ---------------------------------------------------------------------------
  // HN-I proxy topology: both ends of all four links, per issue.
  //
  // These sixteen interfaces carried no checker at all until -- not a
  // disabled one, none -- across twelve testcases including hni_backpressure and
  // hni_reset, which are testcases ABOUT credit and reset behavior running on
  // links where no credit or reset rule was checked.
  //
  // Both ends of each link, not one, and that is a decision rather than a copy of
  // the integrated pair above. A link's two interfaces are two views of the same
  // wires with opposite polarity, so a single bind would look like full coverage
  // while leaving half the registry unevaluated: the direction-split rules --
  // TX/RX DAT burst shape and DataID ordering, TXNID_REUSE_REQUESTER against
  // _COMPLETER, the requester-side CompAck rules against the completer-side ones
  // -- each only run at one end. The coherent links bind one end for the opposite
  // reason, stated where they are declared: there the peer's SNP range is the
  // part that needs the second bind, and the main range is fully visible from the
  // RN-F.
  //
  // Roles follow the interfaces, which already have this right: the proxy's
  // RN-facing ports are declared HN-I (a completer, whose clocking block mirrors
  // snf_cb verbatim) and its SN-facing ports RN-I (a requester). The endpoints
  // are the agents' own RN-I and SN-F views.
  //
  // The completion timeout stays ENABLED here, unlike on the coherent links. It
  // is off there because a request and its completion are not both visible on one
  // interface; on a proxy link they are -- the RN-I's request is answered on the
  // same link it arrived on, and the proxy's downstream request likewise. If
  // backpressure makes it fire, that is a measurement worth having rather than a
  // reason to switch it off in advance.
  // ---------------------------------------------------------------------------
  vip_chi_sva #(.CFG_P(CHI_D_CFG_C),.FLIT_TYPES_T(chi_d_types_t),.ROLE_P(VIP_CHI_ROLE_RNI_E))
    hni_rni0_sva (.vif(hni_rni0_if),
      .checks_enable((hni_rni0_if.txlinkactivereq === 1'b1) || (hni_rni0_if.rxlinkactivereq === 1'b1)),
      .dat_reorder_allowed(chi_dat_reorder_allowed),
      .dat_interleave_allowed(chi_dat_interleave_allowed),
      .txsactive_extend_max_cycles(chi_txsactive_extend_max_cycles),
      .link_activation_timeout_cycles(chi_link_activation_timeout_cycles),
      .link_deactivation_timeout_cycles(chi_link_deactivation_timeout_cycles));
  vip_chi_sva #(.CFG_P(CHI_D_CFG_C),.FLIT_TYPES_T(chi_d_types_t),.ROLE_P(VIP_CHI_ROLE_HNI_E),
                .TXSACTIVE_FROM_LINK_UP_P(1'b1))
    hni_rn0_sva (.vif(hni_rn0_if),
      .checks_enable((hni_rn0_if.txlinkactivereq === 1'b1) || (hni_rn0_if.rxlinkactivereq === 1'b1)),
      .dat_reorder_allowed(chi_dat_reorder_allowed),
      .dat_interleave_allowed(chi_dat_interleave_allowed),
      .txsactive_extend_max_cycles(chi_txsactive_extend_max_cycles),
      .link_activation_timeout_cycles(chi_link_activation_timeout_cycles),
      .link_deactivation_timeout_cycles(chi_link_deactivation_timeout_cycles));
  vip_chi_sva #(.CFG_P(CHI_D_CFG_C),.FLIT_TYPES_T(chi_d_types_t),.ROLE_P(VIP_CHI_ROLE_RNI_E),
                .TXSACTIVE_FROM_LINK_UP_P(1'b1),.MULTI_SOURCE_LINK_P(1'b1))
    hni_sn0_sva (.vif(hni_sn0_if),
      .checks_enable((hni_sn0_if.txlinkactivereq === 1'b1) || (hni_sn0_if.rxlinkactivereq === 1'b1)),
      .dat_reorder_allowed(chi_dat_reorder_allowed),
      .dat_interleave_allowed(chi_dat_interleave_allowed),
      .txsactive_extend_max_cycles(chi_txsactive_extend_max_cycles),
      .link_activation_timeout_cycles(chi_link_activation_timeout_cycles),
      .link_deactivation_timeout_cycles(chi_link_deactivation_timeout_cycles));
  vip_chi_sva #(.CFG_P(CHI_D_CFG_C),.FLIT_TYPES_T(chi_d_types_t),.ROLE_P(VIP_CHI_ROLE_SNF_E),
                .MULTI_SOURCE_LINK_P(1'b1))
    hni_snf0_sva (.vif(hni_snf0_if),
      .checks_enable((hni_snf0_if.txlinkactivereq === 1'b1) || (hni_snf0_if.rxlinkactivereq === 1'b1)),
      .dat_reorder_allowed(chi_dat_reorder_allowed),
      .dat_interleave_allowed(chi_dat_interleave_allowed),
      .txsactive_extend_max_cycles(chi_txsactive_extend_max_cycles),
      .link_activation_timeout_cycles(chi_link_activation_timeout_cycles),
      .link_deactivation_timeout_cycles(chi_link_deactivation_timeout_cycles));
  vip_chi_sva #(.CFG_P(CHI_D_CFG_C),.FLIT_TYPES_T(chi_d_types_t),.ROLE_P(VIP_CHI_ROLE_RNI_E))
    hni_rni1_sva (.vif(hni_rni1_if),
      .checks_enable((hni_rni1_if.txlinkactivereq === 1'b1) || (hni_rni1_if.rxlinkactivereq === 1'b1)),
      .dat_reorder_allowed(chi_dat_reorder_allowed),
      .dat_interleave_allowed(chi_dat_interleave_allowed),
      .txsactive_extend_max_cycles(chi_txsactive_extend_max_cycles),
      .link_activation_timeout_cycles(chi_link_activation_timeout_cycles),
      .link_deactivation_timeout_cycles(chi_link_deactivation_timeout_cycles));
  vip_chi_sva #(.CFG_P(CHI_D_CFG_C),.FLIT_TYPES_T(chi_d_types_t),.ROLE_P(VIP_CHI_ROLE_HNI_E),
                .TXSACTIVE_FROM_LINK_UP_P(1'b1))
    hni_rn1_sva (.vif(hni_rn1_if),
      .checks_enable((hni_rn1_if.txlinkactivereq === 1'b1) || (hni_rn1_if.rxlinkactivereq === 1'b1)),
      .dat_reorder_allowed(chi_dat_reorder_allowed),
      .dat_interleave_allowed(chi_dat_interleave_allowed),
      .txsactive_extend_max_cycles(chi_txsactive_extend_max_cycles),
      .link_activation_timeout_cycles(chi_link_activation_timeout_cycles),
      .link_deactivation_timeout_cycles(chi_link_deactivation_timeout_cycles));
  vip_chi_sva #(.CFG_P(CHI_D_CFG_C),.FLIT_TYPES_T(chi_d_types_t),.ROLE_P(VIP_CHI_ROLE_RNI_E),
                .TXSACTIVE_FROM_LINK_UP_P(1'b1),.MULTI_SOURCE_LINK_P(1'b1))
    hni_sn1_sva (.vif(hni_sn1_if),
      .checks_enable((hni_sn1_if.txlinkactivereq === 1'b1) || (hni_sn1_if.rxlinkactivereq === 1'b1)),
      .dat_reorder_allowed(chi_dat_reorder_allowed),
      .dat_interleave_allowed(chi_dat_interleave_allowed),
      .txsactive_extend_max_cycles(chi_txsactive_extend_max_cycles),
      .link_activation_timeout_cycles(chi_link_activation_timeout_cycles),
      .link_deactivation_timeout_cycles(chi_link_deactivation_timeout_cycles));
  vip_chi_sva #(.CFG_P(CHI_D_CFG_C),.FLIT_TYPES_T(chi_d_types_t),.ROLE_P(VIP_CHI_ROLE_SNF_E),
                .MULTI_SOURCE_LINK_P(1'b1))
    hni_snf1_sva (.vif(hni_snf1_if),
      .checks_enable((hni_snf1_if.txlinkactivereq === 1'b1) || (hni_snf1_if.rxlinkactivereq === 1'b1)),
      .dat_reorder_allowed(chi_dat_reorder_allowed),
      .dat_interleave_allowed(chi_dat_interleave_allowed),
      .txsactive_extend_max_cycles(chi_txsactive_extend_max_cycles),
      .link_activation_timeout_cycles(chi_link_activation_timeout_cycles),
      .link_deactivation_timeout_cycles(chi_link_deactivation_timeout_cycles));
  vip_chi_sva #(.CFG_P(CHI_E_WIDE_CFG_C),.FLIT_TYPES_T(chi_e_wide_types_t),.ROLE_P(VIP_CHI_ROLE_RNI_E))
    e_hni_rni0_sva (.vif(e_hni_rni0_if),
      .checks_enable((e_hni_rni0_if.txlinkactivereq === 1'b1) || (e_hni_rni0_if.rxlinkactivereq === 1'b1)),
      .dat_reorder_allowed(chi_dat_reorder_allowed),
      .dat_interleave_allowed(chi_dat_interleave_allowed),
      .txsactive_extend_max_cycles(chi_txsactive_extend_max_cycles),
      .link_activation_timeout_cycles(chi_link_activation_timeout_cycles),
      .link_deactivation_timeout_cycles(chi_link_deactivation_timeout_cycles));
  vip_chi_sva #(.CFG_P(CHI_E_WIDE_CFG_C),.FLIT_TYPES_T(chi_e_wide_types_t),.ROLE_P(VIP_CHI_ROLE_HNI_E),
                .TXSACTIVE_FROM_LINK_UP_P(1'b1))
    e_hni_rn0_sva (.vif(e_hni_rn0_if),
      .checks_enable((e_hni_rn0_if.txlinkactivereq === 1'b1) || (e_hni_rn0_if.rxlinkactivereq === 1'b1)),
      .dat_reorder_allowed(chi_dat_reorder_allowed),
      .dat_interleave_allowed(chi_dat_interleave_allowed),
      .txsactive_extend_max_cycles(chi_txsactive_extend_max_cycles),
      .link_activation_timeout_cycles(chi_link_activation_timeout_cycles),
      .link_deactivation_timeout_cycles(chi_link_deactivation_timeout_cycles));
  vip_chi_sva #(.CFG_P(CHI_E_WIDE_CFG_C),.FLIT_TYPES_T(chi_e_wide_types_t),.ROLE_P(VIP_CHI_ROLE_RNI_E),
                .TXSACTIVE_FROM_LINK_UP_P(1'b1),.MULTI_SOURCE_LINK_P(1'b1))
    e_hni_sn0_sva (.vif(e_hni_sn0_if),
      .checks_enable((e_hni_sn0_if.txlinkactivereq === 1'b1) || (e_hni_sn0_if.rxlinkactivereq === 1'b1)),
      .dat_reorder_allowed(chi_dat_reorder_allowed),
      .dat_interleave_allowed(chi_dat_interleave_allowed),
      .txsactive_extend_max_cycles(chi_txsactive_extend_max_cycles),
      .link_activation_timeout_cycles(chi_link_activation_timeout_cycles),
      .link_deactivation_timeout_cycles(chi_link_deactivation_timeout_cycles));
  vip_chi_sva #(.CFG_P(CHI_E_WIDE_CFG_C),.FLIT_TYPES_T(chi_e_wide_types_t),.ROLE_P(VIP_CHI_ROLE_SNF_E),
                .MULTI_SOURCE_LINK_P(1'b1))
    e_hni_snf0_sva (.vif(e_hni_snf0_if),
      .checks_enable((e_hni_snf0_if.txlinkactivereq === 1'b1) || (e_hni_snf0_if.rxlinkactivereq === 1'b1)),
      .dat_reorder_allowed(chi_dat_reorder_allowed),
      .dat_interleave_allowed(chi_dat_interleave_allowed),
      .txsactive_extend_max_cycles(chi_txsactive_extend_max_cycles),
      .link_activation_timeout_cycles(chi_link_activation_timeout_cycles),
      .link_deactivation_timeout_cycles(chi_link_deactivation_timeout_cycles));
  vip_chi_sva #(.CFG_P(CHI_E_WIDE_CFG_C),.FLIT_TYPES_T(chi_e_wide_types_t),.ROLE_P(VIP_CHI_ROLE_RNI_E))
    e_hni_rni1_sva (.vif(e_hni_rni1_if),
      .checks_enable((e_hni_rni1_if.txlinkactivereq === 1'b1) || (e_hni_rni1_if.rxlinkactivereq === 1'b1)),
      .dat_reorder_allowed(chi_dat_reorder_allowed),
      .dat_interleave_allowed(chi_dat_interleave_allowed),
      .txsactive_extend_max_cycles(chi_txsactive_extend_max_cycles),
      .link_activation_timeout_cycles(chi_link_activation_timeout_cycles),
      .link_deactivation_timeout_cycles(chi_link_deactivation_timeout_cycles));
  vip_chi_sva #(.CFG_P(CHI_E_WIDE_CFG_C),.FLIT_TYPES_T(chi_e_wide_types_t),.ROLE_P(VIP_CHI_ROLE_HNI_E),
                .TXSACTIVE_FROM_LINK_UP_P(1'b1))
    e_hni_rn1_sva (.vif(e_hni_rn1_if),
      .checks_enable((e_hni_rn1_if.txlinkactivereq === 1'b1) || (e_hni_rn1_if.rxlinkactivereq === 1'b1)),
      .dat_reorder_allowed(chi_dat_reorder_allowed),
      .dat_interleave_allowed(chi_dat_interleave_allowed),
      .txsactive_extend_max_cycles(chi_txsactive_extend_max_cycles),
      .link_activation_timeout_cycles(chi_link_activation_timeout_cycles),
      .link_deactivation_timeout_cycles(chi_link_deactivation_timeout_cycles));
  vip_chi_sva #(.CFG_P(CHI_E_WIDE_CFG_C),.FLIT_TYPES_T(chi_e_wide_types_t),.ROLE_P(VIP_CHI_ROLE_RNI_E),
                .TXSACTIVE_FROM_LINK_UP_P(1'b1),.MULTI_SOURCE_LINK_P(1'b1))
    e_hni_sn1_sva (.vif(e_hni_sn1_if),
      .checks_enable((e_hni_sn1_if.txlinkactivereq === 1'b1) || (e_hni_sn1_if.rxlinkactivereq === 1'b1)),
      .dat_reorder_allowed(chi_dat_reorder_allowed),
      .dat_interleave_allowed(chi_dat_interleave_allowed),
      .txsactive_extend_max_cycles(chi_txsactive_extend_max_cycles),
      .link_activation_timeout_cycles(chi_link_activation_timeout_cycles),
      .link_deactivation_timeout_cycles(chi_link_deactivation_timeout_cycles));
  vip_chi_sva #(.CFG_P(CHI_E_WIDE_CFG_C),.FLIT_TYPES_T(chi_e_wide_types_t),.ROLE_P(VIP_CHI_ROLE_SNF_E),
                .MULTI_SOURCE_LINK_P(1'b1))
    e_hni_snf1_sva (.vif(e_hni_snf1_if),
      .checks_enable((e_hni_snf1_if.txlinkactivereq === 1'b1) || (e_hni_snf1_if.rxlinkactivereq === 1'b1)),
      .dat_reorder_allowed(chi_dat_reorder_allowed),
      .dat_interleave_allowed(chi_dat_interleave_allowed),
      .txsactive_extend_max_cycles(chi_txsactive_extend_max_cycles),
      .link_activation_timeout_cycles(chi_link_activation_timeout_cycles),
      .link_deactivation_timeout_cycles(chi_link_deactivation_timeout_cycles));

  // ---------------------------------------------------------------------------
  // The SN-F behind each coherent HN-F, and the HN-F's own SN-facing port.
  //
  // This link carries the memory traffic of every coherent read miss and was
  // checked by nothing. Both ends again, for the reason above. The completion
  // timeout is enabled: unlike the RN-F links, a downstream ReadNoSnp and its
  // CompData are both visible here.
  //
  // The HN-F's SN-facing port drives TXSACTIVE from sn_link_up, the same shape
  // the HN-I uses on both its sides, so the same stand-down applies. Both are
  //, which named HN-F and HN-I together and had no evidence
  // for either because neither endpoint was bound.
  // ---------------------------------------------------------------------------
  vip_chi_sva #(.CFG_P(CHI_D_CFG_C),.FLIT_TYPES_T(chi_d_types_t),.ROLE_P(VIP_CHI_ROLE_RNI_E),
                .TXSACTIVE_FROM_LINK_UP_P(1'b1))
    coh_hnf0_sn_sva (.vif(coh_hnf0_sn_if),
      .checks_enable((coh_hnf0_sn_if.txlinkactivereq === 1'b1) || (coh_hnf0_sn_if.rxlinkactivereq === 1'b1)),
      .dat_reorder_allowed(chi_dat_reorder_allowed),
      .dat_interleave_allowed(chi_dat_interleave_allowed),
      .txsactive_extend_max_cycles(chi_txsactive_extend_max_cycles),
      .link_activation_timeout_cycles(chi_link_activation_timeout_cycles),
      .link_deactivation_timeout_cycles(chi_link_deactivation_timeout_cycles));
  vip_chi_sva #(.CFG_P(CHI_D_CFG_C),.FLIT_TYPES_T(chi_d_types_t),.ROLE_P(VIP_CHI_ROLE_SNF_E))
    coh_dsnf0_sva (.vif(coh_dsnf0_if),
      .checks_enable((coh_dsnf0_if.txlinkactivereq === 1'b1) || (coh_dsnf0_if.rxlinkactivereq === 1'b1)),
      .dat_reorder_allowed(chi_dat_reorder_allowed),
      .dat_interleave_allowed(chi_dat_interleave_allowed),
      .txsactive_extend_max_cycles(chi_txsactive_extend_max_cycles),
      .link_activation_timeout_cycles(chi_link_activation_timeout_cycles),
      .link_deactivation_timeout_cycles(chi_link_deactivation_timeout_cycles));
  vip_chi_sva #(.CFG_P(CHI_E_WIDE_CFG_C),.FLIT_TYPES_T(chi_e_wide_types_t),.ROLE_P(VIP_CHI_ROLE_RNI_E),
                .TXSACTIVE_FROM_LINK_UP_P(1'b1))
    coh_e_hnf0_sn_sva (.vif(coh_e_hnf0_sn_if),
      .checks_enable((coh_e_hnf0_sn_if.txlinkactivereq === 1'b1) || (coh_e_hnf0_sn_if.rxlinkactivereq === 1'b1)),
      .dat_reorder_allowed(chi_dat_reorder_allowed),
      .dat_interleave_allowed(chi_dat_interleave_allowed),
      .txsactive_extend_max_cycles(chi_txsactive_extend_max_cycles),
      .link_activation_timeout_cycles(chi_link_activation_timeout_cycles),
      .link_deactivation_timeout_cycles(chi_link_deactivation_timeout_cycles));
  vip_chi_sva #(.CFG_P(CHI_E_WIDE_CFG_C),.FLIT_TYPES_T(chi_e_wide_types_t),.ROLE_P(VIP_CHI_ROLE_SNF_E))
    coh_e_dsnf0_sva (.vif(coh_e_dsnf0_if),
      .checks_enable((coh_e_dsnf0_if.txlinkactivereq === 1'b1) || (coh_e_dsnf0_if.rxlinkactivereq === 1'b1)),
      .dat_reorder_allowed(chi_dat_reorder_allowed),
      .dat_interleave_allowed(chi_dat_interleave_allowed),
      .txsactive_extend_max_cycles(chi_txsactive_extend_max_cycles),
      .link_activation_timeout_cycles(chi_link_activation_timeout_cycles),
      .link_deactivation_timeout_cycles(chi_link_deactivation_timeout_cycles));

  // ---------------------------------------------------------------------------
  // The A0 link. Bound rather than waived: it is a live RN-I <-> SN-F pair with
  // an adapter joining it, so every structural and link rule applies to it
  // exactly as to the integrated pair, and a waiver would have to argue that
  // nothing on it is worth checking.
  //
  // CHI_A0_CFG_C, not CHI_D_CFG_C -- and that is not a detail elaboration would
  // have caught. vip_chi_sva takes `vip_chi_if vif` as a GENERIC interface port,
  // so the flit shape comes from the module's own CFG_P and FLIT_TYPES_T with no
  // check that they match the interface the bind names. Get it wrong and the
  // checker reads every flit field at the wrong offsets, silently, and reports
  // violations that are artifacts of the mismatch. A0 is a third geometry --
  // 7-bit node IDs, 32-byte data bus -- so it is the one link here where the
  // mistake is easy to make.
  // ---------------------------------------------------------------------------
  vip_chi_sva #(.CFG_P(CHI_A0_CFG_C),.FLIT_TYPES_T(chi_a0_types_t),.ROLE_P(VIP_CHI_ROLE_RNI_E),
                .HAND_DRIVEN_LINK_P(1'b1))
    a0_rni_sva (.vif(a0_rni_if),
      .checks_enable((a0_rni_if.txlinkactivereq === 1'b1) || (a0_rni_if.rxlinkactivereq === 1'b1)),
      .dat_reorder_allowed(chi_dat_reorder_allowed),
      .dat_interleave_allowed(chi_dat_interleave_allowed),
      .txsactive_extend_max_cycles(chi_txsactive_extend_max_cycles),
      .link_activation_timeout_cycles(chi_link_activation_timeout_cycles),
      .link_deactivation_timeout_cycles(chi_link_deactivation_timeout_cycles));
  vip_chi_sva #(.CFG_P(CHI_A0_CFG_C),.FLIT_TYPES_T(chi_a0_types_t),.ROLE_P(VIP_CHI_ROLE_SNF_E),
                .HAND_DRIVEN_LINK_P(1'b1))
    a0_snf_sva (.vif(a0_snf_if),
      .checks_enable((a0_snf_if.txlinkactivereq === 1'b1) || (a0_snf_if.rxlinkactivereq === 1'b1)),
      .dat_reorder_allowed(chi_dat_reorder_allowed),
      .dat_interleave_allowed(chi_dat_interleave_allowed),
      .txsactive_extend_max_cycles(chi_txsactive_extend_max_cycles),
      .link_activation_timeout_cycles(chi_link_activation_timeout_cycles),
      .link_deactivation_timeout_cycles(chi_link_deactivation_timeout_cycles));

  // --- Clock and reset (incl. the test-requestable mid-run reset pulse) -------
  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;
  end

  initial begin
    rst_n = 1'b0;
    #30 rst_n = 1'b1;
  end

  initial begin
    tb_cfg = null;
  end

  always_comb begin
    rst_n_int = rst_n && (reset_pulse_countdown == 0);
  end

  // A test arms a mid-run reset via tb_cfg.request_reset_pulse(n): the value is
  // a one-shot mailbox -- latch it into the countdown, then clear the field so
  // the pulse is not retriggered. This is the only place the top reads tb_cfg.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      reset_pulse_countdown   <= 0;
      chi_dat_reorder_allowed <= 1'b0;
      chi_dat_interleave_allowed <= 1'b0;
      chi_txsactive_extend_max_cycles <= 0;
      chi_link_activation_timeout_cycles   <= 0;
      chi_link_deactivation_timeout_cycles <= 0;
    end
    else begin
      if (tb_cfg == null) begin
        void'(uvm_config_db #(chi_tb_config)::get(null, "*", "tb_cfg", tb_cfg));
      end

      chi_dat_reorder_allowed <= (tb_cfg != null) && tb_cfg.dat_reorder_allowed;
      chi_dat_interleave_allowed <= (tb_cfg != null) && tb_cfg.dat_interleave_allowed;
      chi_txsactive_extend_max_cycles <=
        (tb_cfg != null) ? tb_cfg.txsactive_extend_max_cycles : 0;
      chi_link_activation_timeout_cycles <=
        (tb_cfg != null) ? tb_cfg.link_activation_timeout_cycles : 0;
      chi_link_deactivation_timeout_cycles <=
        (tb_cfg != null) ? tb_cfg.link_deactivation_timeout_cycles : 0;

      if ((tb_cfg != null) && (tb_cfg.reset_pulse_cycles > 0) && (reset_pulse_countdown == 0)) begin
        reset_pulse_countdown <= tb_cfg.reset_pulse_cycles;
        tb_cfg.reset_pulse_cycles = 0;
      end
      else if (reset_pulse_countdown > 0) begin
        reset_pulse_countdown <= reset_pulse_countdown - 1;
      end
    end
  end

  // --- Links ------------------------------------------------------------------
  // One static adapter per link. An unused topology's agents simply send no
  // traffic, so its interfaces carry idle. (The integrated link is a plain
  // adapter too -- credit starvation is exercised through the RN-I driver's
  // cfg.hold_dat_credit, not a harness wire pinch.)
  chi_link_adapter int_link     (.rn(rni_if),.sn(snf_if));
  chi_link_adapter a0_link      (.rn(a0_rni_if),.sn(a0_snf_if));
  chi_link_adapter hni_rn0_link (.rn(hni_rni0_if),.sn(hni_rn0_if));
  chi_link_adapter hni_rn1_link (.rn(hni_rni1_if),.sn(hni_rn1_if));
  chi_link_adapter hni_sn0_link (.rn(hni_sn0_if),.sn(hni_snf0_if));
  chi_link_adapter hni_sn1_link (.rn(hni_sn1_if),.sn(hni_snf1_if));
  chi_link_adapter e_wide_link  (.rn(chi_e_wide_rni_if),.sn(chi_e_wide_snf_if));

  // Wide CHI-E HN-I proxy links (requester leaf <-> proxy RN-facing port, and
  // proxy SN-facing port <-> responder leaf). The link adapter is unparameterized
  // so the same instance serves the wide CHI-E flit shapes.
  chi_link_adapter e_hni_rn0_link (.rn(e_hni_rni0_if),.sn(e_hni_rn0_if));
  chi_link_adapter e_hni_rn1_link (.rn(e_hni_rni1_if),.sn(e_hni_rn1_if));
  chi_link_adapter e_hni_sn0_link (.rn(e_hni_sn0_if),.sn(e_hni_snf0_if));
  chi_link_adapter e_hni_sn1_link (.rn(e_hni_sn1_if),.sn(e_hni_snf1_if));

  // Isolated coherent RN-F <-> HN-F links. The RN-F is the requester (rn), the
  // HN-F the completer (sn); the adapter cross-wires the SNP channel too.
  chi_link_adapter coh_link0 (.rn(coh_rnf0_if),.sn(coh_hnf0_if));
  chi_link_adapter coh_link1 (.rn(coh_rnf1_if),.sn(coh_hnf1_if));
  // Downstream HN-F <-> SN-F link (HN-F is the requester side).
  chi_link_adapter coh_dsn_link (.rn(coh_hnf0_sn_if),.sn(coh_dsnf0_if));

  // CHI-E coherent links.
  chi_link_adapter coh_e_link0 (.rn(coh_e_rnf0_if),.sn(coh_e_hnf0_if));
  chi_link_adapter coh_e_link1 (.rn(coh_e_rnf1_if),.sn(coh_e_hnf1_if));
  // Downstream HN-F <-> SN-F link (CHI-E parity).
  chi_link_adapter coh_e_dsn_link (.rn(coh_e_hnf0_sn_if),.sn(coh_e_dsnf0_if));

  // --- Interface handoff to the agents + run_test() ---------------------------
  initial begin
    // Agent-free A0 link, published to the testcase itself (no agent owns it).
    uvm_config_db #(virtual vip_chi_if #(CHI_A0_CFG_C, chi_a0_types_t, VIP_CHI_ROLE_RNI_E))::set(
      uvm_root::get(), "uvm_test_top", "a0_rni_vif", a0_rni_if);
    uvm_config_db #(virtual vip_chi_if #(CHI_A0_CFG_C, chi_a0_types_t, VIP_CHI_ROLE_SNF_E))::set(
      uvm_root::get(), "uvm_test_top", "a0_snf_vif", a0_snf_if);

    // Integrated pair.
    uvm_config_db #(virtual vip_chi_if #(CHI_D_CFG_C, chi_d_types_t, VIP_CHI_ROLE_RNI_E))::set(
      uvm_root::get(), "uvm_test_top.env.rni_agent", "vif", rni_if);
    uvm_config_db #(virtual vip_chi_if #(CHI_D_CFG_C, chi_d_types_t, VIP_CHI_ROLE_SNF_E))::set(
      uvm_root::get(), "uvm_test_top.env.snf_agent", "vif", snf_if);

    // HN-I requester agents.
    uvm_config_db #(virtual vip_chi_if #(CHI_D_CFG_C, chi_d_types_t, VIP_CHI_ROLE_RNI_E))::set(
      uvm_root::get(), "uvm_test_top.env.hrni0_agent", "vif", hni_rni0_if);
    uvm_config_db #(virtual vip_chi_if #(CHI_D_CFG_C, chi_d_types_t, VIP_CHI_ROLE_RNI_E))::set(
      uvm_root::get(), "uvm_test_top.env.hrni1_agent", "vif", hni_rni1_if);

    // HN-I responder agents.
    uvm_config_db #(virtual vip_chi_if #(CHI_D_CFG_C, chi_d_types_t, VIP_CHI_ROLE_SNF_E))::set(
      uvm_root::get(), "uvm_test_top.env.hsnf0_agent", "vif", hni_snf0_if);
    uvm_config_db #(virtual vip_chi_if #(CHI_D_CFG_C, chi_d_types_t, VIP_CHI_ROLE_SNF_E))::set(
      uvm_root::get(), "uvm_test_top.env.hsnf1_agent", "vif", hni_snf1_if);

    // HN-I proxy: RN-facing ports on "rn_vif_<i>", SN-facing on "sn_vif_<j>".
    uvm_config_db #(virtual vip_chi_if #(CHI_D_CFG_C, chi_d_types_t, VIP_CHI_ROLE_HNI_E))::set(
      uvm_root::get(), "uvm_test_top.env.hni_agent", "rn_vif_0", hni_rn0_if);
    uvm_config_db #(virtual vip_chi_if #(CHI_D_CFG_C, chi_d_types_t, VIP_CHI_ROLE_HNI_E))::set(
      uvm_root::get(), "uvm_test_top.env.hni_agent", "rn_vif_1", hni_rn1_if);
    uvm_config_db #(virtual vip_chi_if #(CHI_D_CFG_C, chi_d_types_t, VIP_CHI_ROLE_RNI_E))::set(
      uvm_root::get(), "uvm_test_top.env.hni_agent", "sn_vif_0", hni_sn0_if);
    uvm_config_db #(virtual vip_chi_if #(CHI_D_CFG_C, chi_d_types_t, VIP_CHI_ROLE_RNI_E))::set(
      uvm_root::get(), "uvm_test_top.env.hni_agent", "sn_vif_1", hni_sn1_if);

    // Isolated coherent env (chi_coherent_tb_env): two RN-F requesters on
    // "vif", the HN-F home's RN-facing ports on "rn_vif_<i>".
    uvm_config_db #(virtual vip_chi_if #(CHI_D_CFG_C, chi_d_types_t, VIP_CHI_ROLE_RNF_E))::set(
      uvm_root::get(), "uvm_test_top.env.hrnf0_agent", "vif", coh_rnf0_if);
    uvm_config_db #(virtual vip_chi_if #(CHI_D_CFG_C, chi_d_types_t, VIP_CHI_ROLE_RNF_E))::set(
      uvm_root::get(), "uvm_test_top.env.hrnf1_agent", "vif", coh_rnf1_if);
    uvm_config_db #(virtual vip_chi_if #(CHI_D_CFG_C, chi_d_types_t, VIP_CHI_ROLE_HNF_E))::set(
      uvm_root::get(), "uvm_test_top.env.hnf_agent", "rn_vif_0", coh_hnf0_if);
    uvm_config_db #(virtual vip_chi_if #(CHI_D_CFG_C, chi_d_types_t, VIP_CHI_ROLE_HNF_E))::set(
      uvm_root::get(), "uvm_test_top.env.hnf_agent", "rn_vif_1", coh_hnf1_if);
    // Downstream SN link: HN-F requester port "sn_vif_0", SN-F node on "vif".
    uvm_config_db #(virtual vip_chi_if #(CHI_D_CFG_C, chi_d_types_t, VIP_CHI_ROLE_RNI_E))::set(
      uvm_root::get(), "uvm_test_top.env.hnf_agent", "sn_vif_0", coh_hnf0_sn_if);
    uvm_config_db #(virtual vip_chi_if #(CHI_D_CFG_C, chi_d_types_t, VIP_CHI_ROLE_SNF_E))::set(
      uvm_root::get(), "uvm_test_top.env.dsnf0_agent", "vif", coh_dsnf0_if);

    // CHI-E coherent env (chi_coherent_e_base_test): same agent instance
    // names as the CHI-D coherent env; the vif type parameterization selects
    // which set each agent consumes, so only one env (per test) picks these up.
    uvm_config_db #(virtual vip_chi_if #(CHI_E_WIDE_CFG_C, chi_e_wide_types_t, VIP_CHI_ROLE_RNF_E))::set(
      uvm_root::get(), "uvm_test_top.env.hrnf0_agent", "vif", coh_e_rnf0_if);
    uvm_config_db #(virtual vip_chi_if #(CHI_E_WIDE_CFG_C, chi_e_wide_types_t, VIP_CHI_ROLE_RNF_E))::set(
      uvm_root::get(), "uvm_test_top.env.hrnf1_agent", "vif", coh_e_rnf1_if);
    uvm_config_db #(virtual vip_chi_if #(CHI_E_WIDE_CFG_C, chi_e_wide_types_t, VIP_CHI_ROLE_HNF_E))::set(
      uvm_root::get(), "uvm_test_top.env.hnf_agent", "rn_vif_0", coh_e_hnf0_if);
    uvm_config_db #(virtual vip_chi_if #(CHI_E_WIDE_CFG_C, chi_e_wide_types_t, VIP_CHI_ROLE_HNF_E))::set(
      uvm_root::get(), "uvm_test_top.env.hnf_agent", "rn_vif_1", coh_e_hnf1_if);
    // Downstream SN link (CHI-E parity).
    uvm_config_db #(virtual vip_chi_if #(CHI_E_WIDE_CFG_C, chi_e_wide_types_t, VIP_CHI_ROLE_RNI_E))::set(
      uvm_root::get(), "uvm_test_top.env.hnf_agent", "sn_vif_0", coh_e_hnf0_sn_if);
    uvm_config_db #(virtual vip_chi_if #(CHI_E_WIDE_CFG_C, chi_e_wide_types_t, VIP_CHI_ROLE_SNF_E))::set(
      uvm_root::get(), "uvm_test_top.env.dsnf0_agent", "vif", coh_e_dsnf0_if);

    // Wide CHI-E datapath agents (chi_e_tb_env).
    uvm_config_db #(virtual vip_chi_if #(CHI_E_WIDE_CFG_C, chi_e_wide_types_t, VIP_CHI_ROLE_RNI_E))::set(
      uvm_root::get(), "uvm_test_top.env.rni_agent", "vif", chi_e_wide_rni_if);
    uvm_config_db #(virtual vip_chi_if #(CHI_E_WIDE_CFG_C, chi_e_wide_types_t, VIP_CHI_ROLE_SNF_E))::set(
      uvm_root::get(), "uvm_test_top.env.snf_agent", "vif", chi_e_wide_snf_if);

    // Wide CHI-E HN-I proxy agents (chi_e_proxy_tb_env). Same env agent
    // paths as the CHI-D proxy, but keyed by the CHI-E-parameterized vif type,
    // so only the proxy-E env (built for these tests) consumes them.
    uvm_config_db #(virtual vip_chi_if #(CHI_E_WIDE_CFG_C, chi_e_wide_types_t, VIP_CHI_ROLE_RNI_E))::set(
      uvm_root::get(), "uvm_test_top.env.hrni0_agent", "vif", e_hni_rni0_if);
    uvm_config_db #(virtual vip_chi_if #(CHI_E_WIDE_CFG_C, chi_e_wide_types_t, VIP_CHI_ROLE_RNI_E))::set(
      uvm_root::get(), "uvm_test_top.env.hrni1_agent", "vif", e_hni_rni1_if);
    uvm_config_db #(virtual vip_chi_if #(CHI_E_WIDE_CFG_C, chi_e_wide_types_t, VIP_CHI_ROLE_SNF_E))::set(
      uvm_root::get(), "uvm_test_top.env.hsnf0_agent", "vif", e_hni_snf0_if);
    uvm_config_db #(virtual vip_chi_if #(CHI_E_WIDE_CFG_C, chi_e_wide_types_t, VIP_CHI_ROLE_SNF_E))::set(
      uvm_root::get(), "uvm_test_top.env.hsnf1_agent", "vif", e_hni_snf1_if);

    uvm_config_db #(virtual vip_chi_if #(CHI_E_WIDE_CFG_C, chi_e_wide_types_t, VIP_CHI_ROLE_HNI_E))::set(
      uvm_root::get(), "uvm_test_top.env.hni_agent", "rn_vif_0", e_hni_rn0_if);
    uvm_config_db #(virtual vip_chi_if #(CHI_E_WIDE_CFG_C, chi_e_wide_types_t, VIP_CHI_ROLE_HNI_E))::set(
      uvm_root::get(), "uvm_test_top.env.hni_agent", "rn_vif_1", e_hni_rn1_if);
    uvm_config_db #(virtual vip_chi_if #(CHI_E_WIDE_CFG_C, chi_e_wide_types_t, VIP_CHI_ROLE_RNI_E))::set(
      uvm_root::get(), "uvm_test_top.env.hni_agent", "sn_vif_0", e_hni_sn0_if);
    uvm_config_db #(virtual vip_chi_if #(CHI_E_WIDE_CFG_C, chi_e_wide_types_t, VIP_CHI_ROLE_RNI_E))::set(
      uvm_root::get(), "uvm_test_top.env.hni_agent", "sn_vif_1", e_hni_sn1_if);

    run_test();
  end

endmodule
