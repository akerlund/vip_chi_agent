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
  vip_chi_if #(.CFG_P(CHI_D_CFG_C), .FLIT_TYPES_T(chi_d_types_t), .ROLE_P(VIP_CHI_ROLE_RNI_E))
    rni_if (.clk(clk), .rst_n(rst_n_int));
  vip_chi_if #(.CFG_P(CHI_D_CFG_C), .FLIT_TYPES_T(chi_d_types_t), .ROLE_P(VIP_CHI_ROLE_SNF_E))
    snf_if (.clk(clk), .rst_n(rst_n_int));

  // HN-I requester agents (RN-I polarity) feeding the proxy's RN-facing ports.
  vip_chi_if #(.CFG_P(CHI_D_CFG_C), .FLIT_TYPES_T(chi_d_types_t), .ROLE_P(VIP_CHI_ROLE_RNI_E))
    hni_rni0_if (.clk(clk), .rst_n(rst_n_int));
  vip_chi_if #(.CFG_P(CHI_D_CFG_C), .FLIT_TYPES_T(chi_d_types_t), .ROLE_P(VIP_CHI_ROLE_RNI_E))
    hni_rni1_if (.clk(clk), .rst_n(rst_n_int));

  // HN-I proxy RN-facing ports (HN-I polarity = SN-F signal directions).
  vip_chi_if #(.CFG_P(CHI_D_CFG_C), .FLIT_TYPES_T(chi_d_types_t), .ROLE_P(VIP_CHI_ROLE_HNI_E))
    hni_rn0_if (.clk(clk), .rst_n(rst_n_int));
  vip_chi_if #(.CFG_P(CHI_D_CFG_C), .FLIT_TYPES_T(chi_d_types_t), .ROLE_P(VIP_CHI_ROLE_HNI_E))
    hni_rn1_if (.clk(clk), .rst_n(rst_n_int));

  // HN-I proxy SN-facing ports (RN-I polarity: the proxy is the requester here).
  vip_chi_if #(.CFG_P(CHI_D_CFG_C), .FLIT_TYPES_T(chi_d_types_t), .ROLE_P(VIP_CHI_ROLE_RNI_E))
    hni_sn0_if (.clk(clk), .rst_n(rst_n_int));
  vip_chi_if #(.CFG_P(CHI_D_CFG_C), .FLIT_TYPES_T(chi_d_types_t), .ROLE_P(VIP_CHI_ROLE_RNI_E))
    hni_sn1_if (.clk(clk), .rst_n(rst_n_int));

  // HN-I responder agents (SN-F polarity) behind the proxy's SN-facing ports.
  vip_chi_if #(.CFG_P(CHI_D_CFG_C), .FLIT_TYPES_T(chi_d_types_t), .ROLE_P(VIP_CHI_ROLE_SNF_E))
    hni_snf0_if (.clk(clk), .rst_n(rst_n_int));
  vip_chi_if #(.CFG_P(CHI_D_CFG_C), .FLIT_TYPES_T(chi_d_types_t), .ROLE_P(VIP_CHI_ROLE_SNF_E))
    hni_snf1_if (.clk(clk), .rst_n(rst_n_int));

  // Wide CHI-D compile-coverage anchors: no executable test instantiates
  // vip_chi_if at this width, so these unconnected instances are the only thing
  // that forces the interface to elaborate at the wider flit shape. Leave in place.
  vip_chi_if #(.CFG_P(CHI_D_WIDE_CFG_C), .FLIT_TYPES_T(chi_d_wide_types_t), .ROLE_P(VIP_CHI_ROLE_RNI_E))
    chi_d_wide_rni_if (.clk(clk), .rst_n(rst_n_int));
  vip_chi_if #(.CFG_P(CHI_D_WIDE_CFG_C), .FLIT_TYPES_T(chi_d_wide_types_t), .ROLE_P(VIP_CHI_ROLE_SNF_E))
    chi_d_wide_snf_if (.clk(clk), .rst_n(rst_n_int));

  // Wide CHI-E datapath: real RN-I + SN-F agent pair (chi_e_tb_env).
  vip_chi_if #(.CFG_P(CHI_E_WIDE_CFG_C), .FLIT_TYPES_T(chi_e_wide_types_t), .ROLE_P(VIP_CHI_ROLE_RNI_E))
    chi_e_wide_rni_if (.clk(clk), .rst_n(rst_n_int));
  vip_chi_if #(.CFG_P(CHI_E_WIDE_CFG_C), .FLIT_TYPES_T(chi_e_wide_types_t), .ROLE_P(VIP_CHI_ROLE_SNF_E))
    chi_e_wide_snf_if (.clk(clk), .rst_n(rst_n_int));

  // Compile-coverage anchor for the HN-I role at the wide CHI-E config. The live
  // CHI-E proxy ports below (e_hni_rn{0,1}_if) now also elaborate hni_cb under
  // CHI-E flit shapes; this unconnected anchor is kept for parity with the
  // CHI-D-wide anchor above and stays idle.
  vip_chi_if #(.CFG_P(CHI_E_WIDE_CFG_C), .FLIT_TYPES_T(chi_e_wide_types_t), .ROLE_P(VIP_CHI_ROLE_HNI_E))
    chi_e_wide_hni_if (.clk(clk), .rst_n(rst_n_int));

  // Wide CHI-E HN-I proxy topology (chi_e_proxy_tb_env): 2 RN-facing
  // requesters x 2 SN-facing responders, mirroring the CHI-D proxy at CHI-E
  // width. Requester agents (RN-I polarity) feed the proxy's RN-facing ports;
  // the proxy's SN-facing ports (RN-I polarity) drive the responder agents.
  vip_chi_if #(.CFG_P(CHI_E_WIDE_CFG_C), .FLIT_TYPES_T(chi_e_wide_types_t), .ROLE_P(VIP_CHI_ROLE_RNI_E))
    e_hni_rni0_if (.clk(clk), .rst_n(rst_n_int));
  vip_chi_if #(.CFG_P(CHI_E_WIDE_CFG_C), .FLIT_TYPES_T(chi_e_wide_types_t), .ROLE_P(VIP_CHI_ROLE_RNI_E))
    e_hni_rni1_if (.clk(clk), .rst_n(rst_n_int));

  vip_chi_if #(.CFG_P(CHI_E_WIDE_CFG_C), .FLIT_TYPES_T(chi_e_wide_types_t), .ROLE_P(VIP_CHI_ROLE_HNI_E))
    e_hni_rn0_if (.clk(clk), .rst_n(rst_n_int));
  vip_chi_if #(.CFG_P(CHI_E_WIDE_CFG_C), .FLIT_TYPES_T(chi_e_wide_types_t), .ROLE_P(VIP_CHI_ROLE_HNI_E))
    e_hni_rn1_if (.clk(clk), .rst_n(rst_n_int));

  vip_chi_if #(.CFG_P(CHI_E_WIDE_CFG_C), .FLIT_TYPES_T(chi_e_wide_types_t), .ROLE_P(VIP_CHI_ROLE_RNI_E))
    e_hni_sn0_if (.clk(clk), .rst_n(rst_n_int));
  vip_chi_if #(.CFG_P(CHI_E_WIDE_CFG_C), .FLIT_TYPES_T(chi_e_wide_types_t), .ROLE_P(VIP_CHI_ROLE_RNI_E))
    e_hni_sn1_if (.clk(clk), .rst_n(rst_n_int));

  vip_chi_if #(.CFG_P(CHI_E_WIDE_CFG_C), .FLIT_TYPES_T(chi_e_wide_types_t), .ROLE_P(VIP_CHI_ROLE_SNF_E))
    e_hni_snf0_if (.clk(clk), .rst_n(rst_n_int));
  vip_chi_if #(.CFG_P(CHI_E_WIDE_CFG_C), .FLIT_TYPES_T(chi_e_wide_types_t), .ROLE_P(VIP_CHI_ROLE_SNF_E))
    e_hni_snf1_if (.clk(clk), .rst_n(rst_n_int));

  // Isolated coherent RN-F <-> HN-F links (CHI-D): two requester links, each
  // paired with a home-facing link and joined by an adapter below.
  vip_chi_if #(.CFG_P(CHI_D_CFG_C), .FLIT_TYPES_T(chi_d_types_t), .ROLE_P(VIP_CHI_ROLE_RNF_E))
    coh_rnf0_if (.clk(clk), .rst_n(rst_n_int));
  vip_chi_if #(.CFG_P(CHI_D_CFG_C), .FLIT_TYPES_T(chi_d_types_t), .ROLE_P(VIP_CHI_ROLE_RNF_E))
    coh_rnf1_if (.clk(clk), .rst_n(rst_n_int));
  vip_chi_if #(.CFG_P(CHI_D_CFG_C), .FLIT_TYPES_T(chi_d_types_t), .ROLE_P(VIP_CHI_ROLE_HNF_E))
    coh_hnf0_if (.clk(clk), .rst_n(rst_n_int));
  vip_chi_if #(.CFG_P(CHI_D_CFG_C), .FLIT_TYPES_T(chi_d_types_t), .ROLE_P(VIP_CHI_ROLE_HNF_E))
    coh_hnf1_if (.clk(clk), .rst_n(rst_n_int));

  // Downstream SN-F behind the coherent HN-F (CHI-D): the HN-F is the requester
  // (RN-I polarity) toward a real SN-F memory node. Idle unless hnf_downstream_en.
  vip_chi_if #(.CFG_P(CHI_D_CFG_C), .FLIT_TYPES_T(chi_d_types_t), .ROLE_P(VIP_CHI_ROLE_RNI_E))
    coh_hnf0_sn_if (.clk(clk), .rst_n(rst_n_int));
  vip_chi_if #(.CFG_P(CHI_D_CFG_C), .FLIT_TYPES_T(chi_d_types_t), .ROLE_P(VIP_CHI_ROLE_SNF_E))
    coh_dsnf0_if (.clk(clk), .rst_n(rst_n_int));

  // Isolated coherent RN-F <-> HN-F links (CHI-E): the same coherent topology
  // brought up on the wide CHI-E config to prove parity (vip_chi_coherent_e_*).
  vip_chi_if #(.CFG_P(CHI_E_WIDE_CFG_C), .FLIT_TYPES_T(chi_e_wide_types_t), .ROLE_P(VIP_CHI_ROLE_RNF_E))
    coh_e_rnf0_if (.clk(clk), .rst_n(rst_n_int));
  vip_chi_if #(.CFG_P(CHI_E_WIDE_CFG_C), .FLIT_TYPES_T(chi_e_wide_types_t), .ROLE_P(VIP_CHI_ROLE_RNF_E))
    coh_e_rnf1_if (.clk(clk), .rst_n(rst_n_int));
  vip_chi_if #(.CFG_P(CHI_E_WIDE_CFG_C), .FLIT_TYPES_T(chi_e_wide_types_t), .ROLE_P(VIP_CHI_ROLE_HNF_E))
    coh_e_hnf0_if (.clk(clk), .rst_n(rst_n_int));
  vip_chi_if #(.CFG_P(CHI_E_WIDE_CFG_C), .FLIT_TYPES_T(chi_e_wide_types_t), .ROLE_P(VIP_CHI_ROLE_HNF_E))
    coh_e_hnf1_if (.clk(clk), .rst_n(rst_n_int));

  // Downstream SN-F behind the coherent HN-F (CHI-E parity).
  vip_chi_if #(.CFG_P(CHI_E_WIDE_CFG_C), .FLIT_TYPES_T(chi_e_wide_types_t), .ROLE_P(VIP_CHI_ROLE_RNI_E))
    coh_e_hnf0_sn_if (.clk(clk), .rst_n(rst_n_int));
  vip_chi_if #(.CFG_P(CHI_E_WIDE_CFG_C), .FLIT_TYPES_T(chi_e_wide_types_t), .ROLE_P(VIP_CHI_ROLE_SNF_E))
    coh_e_dsnf0_if (.clk(clk), .rst_n(rst_n_int));

  // Agent-free A0 link: a third width shape (7-bit node IDs, 32-byte data bus)
  // driven directly by tc_chi_a0_smoke rather than by any agent, so the
  // interface and the link adapter are exercised at a geometry no other SV link
  // here uses. Idle in every other testcase.
  vip_chi_if #(.CFG_P(CHI_A0_CFG_C), .FLIT_TYPES_T(chi_a0_types_t), .ROLE_P(VIP_CHI_ROLE_RNI_E))
    a0_rni_if (.clk(clk), .rst_n(rst_n_int));
  vip_chi_if #(.CFG_P(CHI_A0_CFG_C), .FLIT_TYPES_T(chi_a0_types_t), .ROLE_P(VIP_CHI_ROLE_SNF_E))
    a0_snf_if (.clk(clk), .rst_n(rst_n_int));

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

  // Cycles a sender may keep TXSACTIVE up past the close of its outstanding
  // window. Same tb_cfg-latched plumbing as chi_dat_reorder_allowed above, and
  // for the same reason: a testcase sets it at run time.
  int chi_txsactive_extend_max_cycles;

  vip_chi_sva #(.CFG_P(CHI_D_CFG_C), .FLIT_TYPES_T(chi_d_types_t), .ROLE_P(VIP_CHI_ROLE_RNI_E))
    rni_sva (.vif(rni_if),
      .checks_enable((rni_if.txlinkactivereq === 1'b1) || (rni_if.rxlinkactivereq === 1'b1)),
      .dat_reorder_allowed(chi_dat_reorder_allowed),
      .txsactive_extend_max_cycles(chi_txsactive_extend_max_cycles));
  vip_chi_sva #(.CFG_P(CHI_D_CFG_C), .FLIT_TYPES_T(chi_d_types_t), .ROLE_P(VIP_CHI_ROLE_SNF_E))
    snf_sva (.vif(snf_if),
      .checks_enable((snf_if.txlinkactivereq === 1'b1) || (snf_if.rxlinkactivereq === 1'b1)),
      .dat_reorder_allowed(chi_dat_reorder_allowed),
      .txsactive_extend_max_cycles(chi_txsactive_extend_max_cycles));
  vip_chi_sva #(.CFG_P(CHI_E_WIDE_CFG_C), .FLIT_TYPES_T(chi_e_wide_types_t), .ROLE_P(VIP_CHI_ROLE_RNI_E))
    rni_e_sva (.vif(chi_e_wide_rni_if),
      .checks_enable((chi_e_wide_rni_if.txlinkactivereq === 1'b1) || (chi_e_wide_rni_if.rxlinkactivereq === 1'b1)),
      .dat_reorder_allowed(chi_dat_reorder_allowed),
      .txsactive_extend_max_cycles(chi_txsactive_extend_max_cycles));
  vip_chi_sva #(.CFG_P(CHI_E_WIDE_CFG_C), .FLIT_TYPES_T(chi_e_wide_types_t), .ROLE_P(VIP_CHI_ROLE_SNF_E))
    snf_e_sva (.vif(chi_e_wide_snf_if),
      .checks_enable((chi_e_wide_snf_if.txlinkactivereq === 1'b1) || (chi_e_wide_snf_if.rxlinkactivereq === 1'b1)),
      .dat_reorder_allowed(chi_dat_reorder_allowed),
      .txsactive_extend_max_cycles(chi_txsactive_extend_max_cycles));

  // Coherent REQ/RSP/DAT checker binds. The SNP channel has a separate checker
  // below; the RN-F endpoint sees the full coherent REQ/RSP/DAT link traffic while
  // avoiding duplicate HN-F-side assertion elaboration. These temporal/procedural
  // SVA instances are compile-gated because VCS assertion elaboration can dominate
  // default build time on the full example top.
`ifdef VIP_CHI_ENABLE_COH_REQ_DAT_SVA
  vip_chi_sva #(.CFG_P(CHI_D_CFG_C), .FLIT_TYPES_T(chi_d_types_t), .ROLE_P(VIP_CHI_ROLE_RNF_E),
                .ENABLE_COMPLETION_TIMEOUT_P(1'b0))
    coh_rnf0_sva (.vif(coh_rnf0_if),
      .checks_enable((coh_rnf0_if.txlinkactivereq === 1'b1) || (coh_rnf0_if.rxlinkactivereq === 1'b1)),
      .dat_reorder_allowed(chi_dat_reorder_allowed),
      .txsactive_extend_max_cycles(chi_txsactive_extend_max_cycles));
  vip_chi_sva #(.CFG_P(CHI_D_CFG_C), .FLIT_TYPES_T(chi_d_types_t), .ROLE_P(VIP_CHI_ROLE_RNF_E),
                .ENABLE_COMPLETION_TIMEOUT_P(1'b0))
    coh_rnf1_sva (.vif(coh_rnf1_if),
      .checks_enable((coh_rnf1_if.txlinkactivereq === 1'b1) || (coh_rnf1_if.rxlinkactivereq === 1'b1)),
      .dat_reorder_allowed(chi_dat_reorder_allowed),
      .txsactive_extend_max_cycles(chi_txsactive_extend_max_cycles));
  vip_chi_sva #(.CFG_P(CHI_E_WIDE_CFG_C), .FLIT_TYPES_T(chi_e_wide_types_t), .ROLE_P(VIP_CHI_ROLE_RNF_E),
                .ENABLE_COMPLETION_TIMEOUT_P(1'b0))
    coh_e_rnf0_sva (.vif(coh_e_rnf0_if),
      .checks_enable((coh_e_rnf0_if.txlinkactivereq === 1'b1) || (coh_e_rnf0_if.rxlinkactivereq === 1'b1)),
      .dat_reorder_allowed(chi_dat_reorder_allowed),
      .txsactive_extend_max_cycles(chi_txsactive_extend_max_cycles));
  vip_chi_sva #(.CFG_P(CHI_E_WIDE_CFG_C), .FLIT_TYPES_T(chi_e_wide_types_t), .ROLE_P(VIP_CHI_ROLE_RNF_E),
                .ENABLE_COMPLETION_TIMEOUT_P(1'b0))
    coh_e_rnf1_sva (.vif(coh_e_rnf1_if),
      .checks_enable((coh_e_rnf1_if.txlinkactivereq === 1'b1) || (coh_e_rnf1_if.rxlinkactivereq === 1'b1)),
      .dat_reorder_allowed(chi_dat_reorder_allowed),
      .txsactive_extend_max_cycles(chi_txsactive_extend_max_cycles));
`endif

  // SNP-channel protocol checker on the coherent RN-F / HN-F links. Role-agnostic:
  // the HN-F side exercises the txsnp send-credit shadow, the RN-F side the rxsnp
  // receive shadow. Same x-safe link-active gate as the REQ/RSP/DAT binds above.
  vip_chi_snp_sva #(.CFG_P(CHI_D_CFG_C), .FLIT_TYPES_T(chi_d_types_t), .ROLE_P(VIP_CHI_ROLE_HNF_E))
    coh_hnf0_snp_sva (.vif(coh_hnf0_if),
      .checks_enable((coh_hnf0_if.txlinkactivereq === 1'b1) || (coh_hnf0_if.rxlinkactivereq === 1'b1)));
  vip_chi_snp_sva #(.CFG_P(CHI_D_CFG_C), .FLIT_TYPES_T(chi_d_types_t), .ROLE_P(VIP_CHI_ROLE_HNF_E))
    coh_hnf1_snp_sva (.vif(coh_hnf1_if),
      .checks_enable((coh_hnf1_if.txlinkactivereq === 1'b1) || (coh_hnf1_if.rxlinkactivereq === 1'b1)));
  vip_chi_snp_sva #(.CFG_P(CHI_D_CFG_C), .FLIT_TYPES_T(chi_d_types_t), .ROLE_P(VIP_CHI_ROLE_RNF_E))
    coh_rnf0_snp_sva (.vif(coh_rnf0_if),
      .checks_enable((coh_rnf0_if.txlinkactivereq === 1'b1) || (coh_rnf0_if.rxlinkactivereq === 1'b1)));
  vip_chi_snp_sva #(.CFG_P(CHI_D_CFG_C), .FLIT_TYPES_T(chi_d_types_t), .ROLE_P(VIP_CHI_ROLE_RNF_E))
    coh_rnf1_snp_sva (.vif(coh_rnf1_if),
      .checks_enable((coh_rnf1_if.txlinkactivereq === 1'b1) || (coh_rnf1_if.rxlinkactivereq === 1'b1)));

  // Same SNP-channel checker on the CHI-E coherent links.
  vip_chi_snp_sva #(.CFG_P(CHI_E_WIDE_CFG_C), .FLIT_TYPES_T(chi_e_wide_types_t), .ROLE_P(VIP_CHI_ROLE_HNF_E))
    coh_e_hnf0_snp_sva (.vif(coh_e_hnf0_if),
      .checks_enable((coh_e_hnf0_if.txlinkactivereq === 1'b1) || (coh_e_hnf0_if.rxlinkactivereq === 1'b1)));
  vip_chi_snp_sva #(.CFG_P(CHI_E_WIDE_CFG_C), .FLIT_TYPES_T(chi_e_wide_types_t), .ROLE_P(VIP_CHI_ROLE_HNF_E))
    coh_e_hnf1_snp_sva (.vif(coh_e_hnf1_if),
      .checks_enable((coh_e_hnf1_if.txlinkactivereq === 1'b1) || (coh_e_hnf1_if.rxlinkactivereq === 1'b1)));
  vip_chi_snp_sva #(.CFG_P(CHI_E_WIDE_CFG_C), .FLIT_TYPES_T(chi_e_wide_types_t), .ROLE_P(VIP_CHI_ROLE_RNF_E))
    coh_e_rnf0_snp_sva (.vif(coh_e_rnf0_if),
      .checks_enable((coh_e_rnf0_if.txlinkactivereq === 1'b1) || (coh_e_rnf0_if.rxlinkactivereq === 1'b1)));
  vip_chi_snp_sva #(.CFG_P(CHI_E_WIDE_CFG_C), .FLIT_TYPES_T(chi_e_wide_types_t), .ROLE_P(VIP_CHI_ROLE_RNF_E))
    coh_e_rnf1_snp_sva (.vif(coh_e_rnf1_if),
      .checks_enable((coh_e_rnf1_if.txlinkactivereq === 1'b1) || (coh_e_rnf1_if.rxlinkactivereq === 1'b1)));

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
      chi_txsactive_extend_max_cycles <= 0;
    end
    else begin
      if (tb_cfg == null) begin
        void'(uvm_config_db #(chi_tb_config)::get(null, "*", "tb_cfg", tb_cfg));
      end

      chi_dat_reorder_allowed <= (tb_cfg != null) && tb_cfg.dat_reorder_allowed;
      chi_txsactive_extend_max_cycles <=
        (tb_cfg != null) ? tb_cfg.txsactive_extend_max_cycles : 0;

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
  chi_link_adapter int_link     (.rn(rni_if),      .sn(snf_if));
  chi_link_adapter a0_link      (.rn(a0_rni_if),   .sn(a0_snf_if));
  chi_link_adapter hni_rn0_link (.rn(hni_rni0_if), .sn(hni_rn0_if));
  chi_link_adapter hni_rn1_link (.rn(hni_rni1_if), .sn(hni_rn1_if));
  chi_link_adapter hni_sn0_link (.rn(hni_sn0_if),  .sn(hni_snf0_if));
  chi_link_adapter hni_sn1_link (.rn(hni_sn1_if),  .sn(hni_snf1_if));
  chi_link_adapter e_wide_link  (.rn(chi_e_wide_rni_if), .sn(chi_e_wide_snf_if));

  // Wide CHI-E HN-I proxy links (requester leaf <-> proxy RN-facing port, and
  // proxy SN-facing port <-> responder leaf). The link adapter is unparameterized
  // so the same instance serves the wide CHI-E flit shapes.
  chi_link_adapter e_hni_rn0_link (.rn(e_hni_rni0_if), .sn(e_hni_rn0_if));
  chi_link_adapter e_hni_rn1_link (.rn(e_hni_rni1_if), .sn(e_hni_rn1_if));
  chi_link_adapter e_hni_sn0_link (.rn(e_hni_sn0_if),  .sn(e_hni_snf0_if));
  chi_link_adapter e_hni_sn1_link (.rn(e_hni_sn1_if),  .sn(e_hni_snf1_if));

  // Isolated coherent RN-F <-> HN-F links. The RN-F is the requester (rn), the
  // HN-F the completer (sn); the adapter cross-wires the SNP channel too.
  chi_link_adapter coh_link0 (.rn(coh_rnf0_if), .sn(coh_hnf0_if));
  chi_link_adapter coh_link1 (.rn(coh_rnf1_if), .sn(coh_hnf1_if));
  // Downstream HN-F <-> SN-F link (HN-F is the requester side).
  chi_link_adapter coh_dsn_link (.rn(coh_hnf0_sn_if), .sn(coh_dsnf0_if));

  // CHI-E coherent links.
  chi_link_adapter coh_e_link0 (.rn(coh_e_rnf0_if), .sn(coh_e_hnf0_if));
  chi_link_adapter coh_e_link1 (.rn(coh_e_rnf1_if), .sn(coh_e_hnf1_if));
  // Downstream HN-F <-> SN-F link (CHI-E parity).
  chi_link_adapter coh_e_dsn_link (.rn(coh_e_hnf0_sn_if), .sn(coh_e_dsnf0_if));

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
