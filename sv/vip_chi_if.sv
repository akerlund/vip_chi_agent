`ifndef VIP_CHI_IF
`define VIP_CHI_IF

import vip_chi_types_pkg::*;

interface vip_chi_if #(
  parameter vip_chi_cfg_t  CFG_P  = VIP_CHI_DEFAULT_CFG_C,
  parameter type FLIT_TYPES_T = vip_chi_types #(CFG_P),
  parameter vip_chi_role_t ROLE_P = VIP_CHI_ROLE_MONITOR_E
  )(
    input clk,
    input rst_n
  );

  typedef FLIT_TYPES_T::vip_chi_req_flit_t  vip_chi_req_flit_t;
  typedef FLIT_TYPES_T::vip_chi_rsp_flit_t  vip_chi_rsp_flit_t;
  typedef FLIT_TYPES_T::vip_chi_resp_flit_t vip_chi_resp_flit_t;
  typedef FLIT_TYPES_T::vip_chi_dat_flit_t  vip_chi_dat_flit_t;
  typedef FLIT_TYPES_T::vip_chi_data_flit_t vip_chi_data_flit_t;
  typedef FLIT_TYPES_T::vip_chi_snp_flit_t  vip_chi_snp_flit_t;
  typedef vip_chi_req_flit_t  req_flit_t;
  typedef vip_chi_resp_flit_t rsp_flit_t;
  typedef vip_chi_data_flit_t dat_flit_t;
  typedef vip_chi_snp_flit_t  snp_flit_t;

  // ---------------------------------------------------------------------------
  // Link state and activation handshake.
  // ---------------------------------------------------------------------------
  logic txlinkactivereq;
  logic txlinkactiveack;
  logic rxlinkactivereq;
  logic rxlinkactiveack;
  logic txsactive;
  logic rxsactive;

  // ---------------------------------------------------------------------------
  // Request channel.
  // ---------------------------------------------------------------------------
  logic      txreqflitpend;
  logic      txreqflitv;
  req_flit_t txreqflit;
  logic      txreqlcrdv;

  logic      rxreqflitpend;
  logic      rxreqflitv;
  req_flit_t rxreqflit;
  logic      rxreqlcrdv;

  // ---------------------------------------------------------------------------
  // Response channel.
  // ---------------------------------------------------------------------------
  logic      txrspflitpend;
  logic      txrspflitv;
  rsp_flit_t txrspflit;
  logic      txrsplcrdv;

  logic      rxrspflitpend;
  logic      rxrspflitv;
  rsp_flit_t rxrspflit;
  logic      rxrsplcrdv;

  // ---------------------------------------------------------------------------
  // Data channel.
  // ---------------------------------------------------------------------------
  logic      txdatflitpend;
  logic      txdatflitv;
  dat_flit_t txdatflit;
  logic      txdatlcrdv;

  logic      rxdatflitpend;
  logic      rxdatflitv;
  dat_flit_t rxdatflit;
  logic      rxdatlcrdv;

  // ---------------------------------------------------------------------------
  // Snoop channel (Tier C). Flows home (HN-F) -> requester (RN-F) -- opposite
  // REQ. Only ROLE_P==HNF sources snoops (drives txsnp*); only ROLE_P==RNF
  // receives them and returns SNP receive-credit (drives txsnplcrdv). Every
  // other role keeps the channel tied idle (see the tie-off generate below), so
  // links carrying no coherent traffic present a quiescent SNP channel.
  // ---------------------------------------------------------------------------
  logic      txsnpflitpend;
  logic      txsnpflitv;
  snp_flit_t txsnpflit;
  logic      txsnplcrdv;

  logic      rxsnpflitpend;
  logic      rxsnpflitv;
  snp_flit_t rxsnpflit;
  logic      rxsnplcrdv;

  generate
    if (ROLE_P != VIP_CHI_ROLE_HNF_E) begin: g_snp_tx_idle
      assign txsnpflitpend = 1'b0;
      assign txsnpflitv    = 1'b0;
      assign txsnpflit     = '0;
    end
    if (ROLE_P != VIP_CHI_ROLE_RNF_E) begin: g_snp_crd_idle
      assign txsnplcrdv    = 1'b0;
    end
  endgenerate

  // ---------------------------------------------------------------------------
  // Passive monitor clocking block.
  // ---------------------------------------------------------------------------
  clocking monitor_cb @(posedge clk);

    default input #1step;

    input txlinkactivereq;
    input txlinkactiveack;
    input rxlinkactivereq;
    input rxlinkactiveack;
    input txsactive;
    input rxsactive;

    input txreqflitpend;
    input txreqflitv;
    input txreqflit;
    input txreqlcrdv;
    input rxreqflitpend;
    input rxreqflitv;
    input rxreqflit;
    input rxreqlcrdv;

    input txrspflitpend;
    input txrspflitv;
    input txrspflit;
    input txrsplcrdv;
    input rxrspflitpend;
    input rxrspflitv;
    input rxrspflit;
    input rxrsplcrdv;

    input txdatflitpend;
    input txdatflitv;
    input txdatflit;
    input txdatlcrdv;
    input rxdatflitpend;
    input rxdatflitv;
    input rxdatflit;
    input rxdatlcrdv;

    input txsnpflitpend;
    input txsnpflitv;
    input txsnpflit;
    input txsnplcrdv;
    input rxsnpflitpend;
    input rxsnpflitv;
    input rxsnpflit;
    input rxsnplcrdv;
  endclocking

  modport monitor (clocking monitor_cb, input clk, input rst_n);

  // ---------------------------------------------------------------------------
  // Raw-signal modports. Active drivers typically use the role-gated clocking
  // blocks below, but these modports are useful for structural hookups.
  // ---------------------------------------------------------------------------
  modport snf (
    input  clk,
    input  rst_n,
    output txlinkactivereq,
    output txlinkactiveack,
    input  rxlinkactivereq,
    input  rxlinkactiveack,
    output txsactive,
    input  rxsactive,
    input  rxreqflitpend,
    input  rxreqflitv,
    input  rxreqflit,
    output txreqlcrdv,
    output txrspflitpend,
    output txrspflitv,
    output txrspflit,
    output txrsplcrdv,
    input  rxrspflitpend,
    input  rxrspflitv,
    input  rxrspflit,
    input  rxrsplcrdv,
    output txdatflitpend,
    output txdatflitv,
    output txdatflit,
    output txdatlcrdv,
    input  rxdatflitpend,
    input  rxdatflitv,
    input  rxdatflit,
    input  rxdatlcrdv
  );

  modport rni (
    input  clk,
    input  rst_n,
    output txlinkactivereq,
    output txlinkactiveack,
    input  rxlinkactivereq,
    input  rxlinkactiveack,
    output txsactive,
    input  rxsactive,
    output txreqflitpend,
    output txreqflitv,
    output txreqflit,
    input  rxreqlcrdv,
    output txrspflitpend,
    output txrspflitv,
    output txrspflit,
    output txrsplcrdv,
    input  rxrspflitpend,
    input  rxrspflitv,
    input  rxrspflit,
    input  rxrsplcrdv,
    output txdatflitpend,
    output txdatflitv,
    output txdatflit,
    output txdatlcrdv,
    input  rxdatflitpend,
    input  rxdatflitv,
    input  rxdatflit,
    input  rxdatlcrdv
  );

  // ---------------------------------------------------------------------------
  // Role-gated driving clocking blocks. This mirrors the vip_axi4_if pattern:
  // only the active role's clocking block is elaborated, which avoids giving
  // both sides a procedural-driver context on the same signals.
  // ---------------------------------------------------------------------------
  generate

    if (ROLE_P == VIP_CHI_ROLE_SNF_E) begin: g_drv

      clocking snf_cb @(posedge clk);

        default input #1step output #0;

        output txlinkactivereq;
        output txlinkactiveack;
        input  rxlinkactivereq;
        input  rxlinkactiveack;
        output txsactive;
        input  rxsactive;

        input  rxreqflitpend;
        input  rxreqflitv;
        input  rxreqflit;
        output txreqlcrdv;

        output txrspflitpend;
        output txrspflitv;
        output txrspflit;
        output txrsplcrdv;
        input  rxrspflitpend;
        input  rxrspflitv;
        input  rxrspflit;
        input  rxrsplcrdv;

        output txdatflitpend;
        output txdatflitv;
        output txdatflit;
        output txdatlcrdv;
        input  rxdatflitpend;
        input  rxdatflitv;
        input  rxdatflit;
        input  rxdatlcrdv;
      endclocking
    end
    else if (ROLE_P == VIP_CHI_ROLE_HNI_E) begin: g_drv

      // HN-I RN-facing side. A home node sits between an RN and an SN, so on the
      // link that faces the RN it plays the completer/subordinate role: it
      // receives REQ, sources RSP/DAT completions, and grants inbound REQ/RSP/
      // DAT credits. Those directions are identical to the SN-F clocking block,
      // so this mirrors snf_cb verbatim. The SN-facing side of the same proxy
      // uses a separate ROLE_P=RNI interface (rni_cb) to act as the requester.
      clocking hni_cb @(posedge clk);

        default input #1step output #0;

        output txlinkactivereq;
        output txlinkactiveack;
        input  rxlinkactivereq;
        input  rxlinkactiveack;
        output txsactive;
        input  rxsactive;

        input  rxreqflitpend;
        input  rxreqflitv;
        input  rxreqflit;
        output txreqlcrdv;

        output txrspflitpend;
        output txrspflitv;
        output txrspflit;
        output txrsplcrdv;
        input  rxrspflitpend;
        input  rxrspflitv;
        input  rxrspflit;
        input  rxrsplcrdv;

        output txdatflitpend;
        output txdatflitv;
        output txdatflit;
        output txdatlcrdv;
        input  rxdatflitpend;
        input  rxdatflitv;
        input  rxdatflit;
        input  rxdatlcrdv;
      endclocking
    end
    else if (ROLE_P == VIP_CHI_ROLE_RNI_E) begin: g_drv

      clocking rni_cb @(posedge clk);

        default input #1step output #0;

        output txlinkactivereq;
        output txlinkactiveack;
        input  rxlinkactivereq;
        input  rxlinkactiveack;
        output txsactive;
        input  rxsactive;

        output txreqflitpend;
        output txreqflitv;
        output txreqflit;
        input  rxreqlcrdv;

        output txrspflitpend;
        output txrspflitv;
        output txrspflit;
        output txrsplcrdv;
        input  rxrspflitpend;
        input  rxrspflitv;
        input  rxrspflit;
        input  rxrsplcrdv;

        output txdatflitpend;
        output txdatflitv;
        output txdatflit;
        output txdatlcrdv;
        input  rxdatflitpend;
        input  rxdatflitv;
        input  rxdatflit;
        input  rxdatlcrdv;
      endclocking
    end
    else if (ROLE_P == VIP_CHI_ROLE_RNF_E) begin: g_drv

      // Coherent requester (RN-F). It plays the requester on REQ/RSP/DAT exactly
      // like an RN-I, so this clocking block is a SUPERSET of rni_cb and is named
      // rni_cb on purpose: the RN-F driver extends vip_chi_driver_rni, whose body
      // references g_drv.rni_cb, and that body binds unchanged here. The superset
      // adds the SNP receive channel (snoops flow home->RN-F) plus the RN-F's own
      // SNP receive-credit output. Snoop RESPONSES go back out on txrsp/txdat,
      // which rni_cb already carries -- no extra SNP-tx is needed on this side.
      clocking rni_cb @(posedge clk);

        default input #1step output #0;

        output txlinkactivereq;
        output txlinkactiveack;
        input  rxlinkactivereq;
        input  rxlinkactiveack;
        output txsactive;
        input  rxsactive;

        output txreqflitpend;
        output txreqflitv;
        output txreqflit;
        input  rxreqlcrdv;

        output txrspflitpend;
        output txrspflitv;
        output txrspflit;
        output txrsplcrdv;
        input  rxrspflitpend;
        input  rxrspflitv;
        input  rxrspflit;
        input  rxrsplcrdv;

        output txdatflitpend;
        output txdatflitv;
        output txdatflit;
        output txdatlcrdv;
        input  rxdatflitpend;
        input  rxdatflitv;
        input  rxdatflit;
        input  rxdatlcrdv;

        // Inbound snoops (home -> RN-F) + this RN-F's SNP receive-credit grant.
        input  rxsnpflitpend;
        input  rxsnpflitv;
        input  rxsnpflit;
        output txsnplcrdv;
      endclocking
    end
    else if (ROLE_P == VIP_CHI_ROLE_HNF_E) begin: g_drv

      // Coherent home node (HN-F). Toward each RN-F it is the completer, so on
      // REQ/RSP/DAT this mirrors hni_cb (receive REQ, source RSP/DAT, grant the
      // inbound REQ/RSP/DAT credits). It additionally SOURCES snoops on the SNP
      // channel (home -> RN-F) and consumes the RN-F's SNP receive-credit.
      clocking hnf_cb @(posedge clk);

        default input #1step output #0;

        output txlinkactivereq;
        output txlinkactiveack;
        input  rxlinkactivereq;
        input  rxlinkactiveack;
        output txsactive;
        input  rxsactive;

        input  rxreqflitpend;
        input  rxreqflitv;
        input  rxreqflit;
        output txreqlcrdv;

        output txrspflitpend;
        output txrspflitv;
        output txrspflit;
        output txrsplcrdv;
        input  rxrspflitpend;
        input  rxrspflitv;
        input  rxrspflit;
        input  rxrsplcrdv;

        output txdatflitpend;
        output txdatflitv;
        output txdatflit;
        output txdatlcrdv;
        input  rxdatflitpend;
        input  rxdatflitv;
        input  rxdatflit;
        input  rxdatlcrdv;

        // Outbound snoops (HN-F -> RN-F) + inbound SNP send-credit from the RN-F.
        output txsnpflitpend;
        output txsnpflitv;
        output txsnpflit;
        input  rxsnplcrdv;
      endclocking
    end
  endgenerate

endinterface

`endif