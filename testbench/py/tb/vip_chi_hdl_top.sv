////////////////////////////////////////////////////////////////////////////////
//
// Copyright (C) 2026 Fredrik Akerlund
// https://github.com/akerlund/vip_chi_agent
//
// SPDX short notice -- see the SystemVerilog originals for the full MIT text.
//
// Description:
//
//   Combined flat-net Verilator shell for the vip_chi_agent pyUVM/cocotb flow.
//   It contains the endpoint groups from the split Python HDL tops, but gives
//   every topology a unique prefix so one compiled model can host all tests.
//
//   This top contains no SV interfaces, no UVM, and no behavior beyond the
//   symmetric tx-to-rx CHI link cross-wires. Cocotb owns clock/reset, creates
//   ChiBus handles for the flat nets, and starts the pyUVM tests.
//
////////////////////////////////////////////////////////////////////////////////

`default_nettype none

`define CHI_IF_NETS(P, REQ_W, RSP_W, DAT_W, SNP_W) \
  logic P``txlinkactivereq, P``txlinkactiveack, P``rxlinkactivereq, P``rxlinkactiveack; \
  logic P``txsactive, P``rxsactive; \
  logic P``txreqflitpend, P``txreqflitv, P``txreqlcrdv; logic [REQ_W-1:0] P``txreqflit; \
  logic P``rxreqflitpend, P``rxreqflitv, P``rxreqlcrdv; logic [REQ_W-1:0] P``rxreqflit; \
  logic P``txrspflitpend, P``txrspflitv, P``txrsplcrdv; logic [RSP_W-1:0] P``txrspflit; \
  logic P``rxrspflitpend, P``rxrspflitv, P``rxrsplcrdv; logic [RSP_W-1:0] P``rxrspflit; \
  logic P``txdatflitpend, P``txdatflitv, P``txdatlcrdv; logic [DAT_W-1:0] P``txdatflit; \
  logic P``rxdatflitpend, P``rxdatflitv, P``rxdatlcrdv; logic [DAT_W-1:0] P``rxdatflit; \
  logic P``txsnpflitpend, P``txsnpflitv, P``txsnplcrdv; logic [SNP_W-1:0] P``txsnpflit; \
  logic P``rxsnpflitpend, P``rxsnpflitv, P``rxsnplcrdv; logic [SNP_W-1:0] P``rxsnpflit;

`define CHI_XWIRE(D, S) \
  assign D``rxlinkactivereq = S``txlinkactivereq; \
  assign D``rxlinkactiveack = S``txlinkactiveack; \
  assign D``rxsactive       = S``txsactive; \
  assign D``rxreqflitpend = S``txreqflitpend; assign D``rxreqflitv = S``txreqflitv; \
  assign D``rxreqflit     = S``txreqflit;     assign D``rxreqlcrdv = S``txreqlcrdv; \
  assign D``rxrspflitpend = S``txrspflitpend; assign D``rxrspflitv = S``txrspflitv; \
  assign D``rxrspflit     = S``txrspflit;     assign D``rxrsplcrdv = S``txrsplcrdv; \
  assign D``rxdatflitpend = S``txdatflitpend; assign D``rxdatflitv = S``txdatflitv; \
  assign D``rxdatflit     = S``txdatflit;     assign D``rxdatlcrdv = S``txdatlcrdv; \
  assign D``rxsnpflitpend = S``txsnpflitpend; assign D``rxsnpflitv = S``txsnpflitv; \
  assign D``rxsnpflit     = S``txsnpflit;     assign D``rxsnplcrdv = S``txsnplcrdv;

module vip_chi_hdl_top (
    input wire clk,
    input wire rst_n
  );

  import vip_chi_types_pkg::*;

  localparam vip_chi_cfg_t A0_CFG = '{
    ISSUE_P         : VIP_CHI_ISSUE_D_E,
    NODE_ID_WIDTH_P : 7,
    ADDR_WIDTH_P    : 44,
    DATA_BYTES_P    : 32,
    DATACHECK_EN_P  : 1'b0,
    POISON_EN_P     : 1'b0,
    MPAM_EN_P       : 1'b0,
    PARITY_EN_P     : 1'b0
  };

  localparam vip_chi_cfg_t D_CFG = '{
    ISSUE_P         : VIP_CHI_ISSUE_D_E,
    NODE_ID_WIDTH_P : 11,
    ADDR_WIDTH_P    : 44,
    DATA_BYTES_P    : 16,
    DATACHECK_EN_P  : 1'b0,
    POISON_EN_P     : 1'b0,
    MPAM_EN_P       : 1'b0,
    PARITY_EN_P     : 1'b0
  };

  localparam vip_chi_cfg_t E_CFG = '{
    ISSUE_P         : VIP_CHI_ISSUE_E_E,
    NODE_ID_WIDTH_P : 11,
    ADDR_WIDTH_P    : 52,
    DATA_BYTES_P    : 64,
    DATACHECK_EN_P  : 1'b0,
    POISON_EN_P     : 1'b0,
    MPAM_EN_P       : 1'b0,
    PARITY_EN_P     : 1'b0
  };

  localparam int A0_REQ_W = $bits(vip_chi_types_d#(A0_CFG)::vip_chi_req_flit_t);
  localparam int A0_RSP_W = $bits(vip_chi_types_d#(A0_CFG)::vip_chi_rsp_flit_t);
  localparam int A0_DAT_W = $bits(vip_chi_types_d#(A0_CFG)::vip_chi_dat_flit_t);
  localparam int A0_SNP_W = $bits(vip_chi_types_d#(A0_CFG)::vip_chi_snp_flit_t);

  localparam int D_REQ_W = $bits(vip_chi_types_d#(D_CFG)::vip_chi_req_flit_t);
  localparam int D_RSP_W = $bits(vip_chi_types_d#(D_CFG)::vip_chi_rsp_flit_t);
  localparam int D_DAT_W = $bits(vip_chi_types_d#(D_CFG)::vip_chi_dat_flit_t);
  localparam int D_SNP_W = $bits(vip_chi_types_d#(D_CFG)::vip_chi_snp_flit_t);

  localparam int E_REQ_W = $bits(vip_chi_types_e#(E_CFG)::vip_chi_req_flit_t);
  localparam int E_RSP_W = $bits(vip_chi_types_e#(E_CFG)::vip_chi_rsp_flit_t);
  localparam int E_DAT_W = $bits(vip_chi_types_e#(E_CFG)::vip_chi_dat_flit_t);
  localparam int E_SNP_W = $bits(vip_chi_types_e#(E_CFG)::vip_chi_snp_flit_t);

  // verilator lint_off UNDRIVEN
  // verilator lint_off UNUSEDSIGNAL

  `CHI_IF_NETS(a0_rni_, A0_REQ_W, A0_RSP_W, A0_DAT_W, A0_SNP_W)
  `CHI_IF_NETS(a0_snf_, A0_REQ_W, A0_RSP_W, A0_DAT_W, A0_SNP_W)

  `CHI_IF_NETS(d_rni_, D_REQ_W, D_RSP_W, D_DAT_W, D_SNP_W)
  `CHI_IF_NETS(d_snf_, D_REQ_W, D_RSP_W, D_DAT_W, D_SNP_W)

  `CHI_IF_NETS(e_rni_, E_REQ_W, E_RSP_W, E_DAT_W, E_SNP_W)
  `CHI_IF_NETS(e_snf_, E_REQ_W, E_RSP_W, E_DAT_W, E_SNP_W)

  `CHI_IF_NETS(d_hni_rni0_, D_REQ_W, D_RSP_W, D_DAT_W, D_SNP_W)
  `CHI_IF_NETS(d_hni_rni1_, D_REQ_W, D_RSP_W, D_DAT_W, D_SNP_W)
  `CHI_IF_NETS(d_hni_hrn0_, D_REQ_W, D_RSP_W, D_DAT_W, D_SNP_W)
  `CHI_IF_NETS(d_hni_hrn1_, D_REQ_W, D_RSP_W, D_DAT_W, D_SNP_W)
  `CHI_IF_NETS(d_hni_hsn0_, D_REQ_W, D_RSP_W, D_DAT_W, D_SNP_W)
  `CHI_IF_NETS(d_hni_hsn1_, D_REQ_W, D_RSP_W, D_DAT_W, D_SNP_W)
  `CHI_IF_NETS(d_hni_snf0_, D_REQ_W, D_RSP_W, D_DAT_W, D_SNP_W)
  `CHI_IF_NETS(d_hni_snf1_, D_REQ_W, D_RSP_W, D_DAT_W, D_SNP_W)

  `CHI_IF_NETS(e_hni_rni0_, E_REQ_W, E_RSP_W, E_DAT_W, E_SNP_W)
  `CHI_IF_NETS(e_hni_rni1_, E_REQ_W, E_RSP_W, E_DAT_W, E_SNP_W)
  `CHI_IF_NETS(e_hni_hrn0_, E_REQ_W, E_RSP_W, E_DAT_W, E_SNP_W)
  `CHI_IF_NETS(e_hni_hrn1_, E_REQ_W, E_RSP_W, E_DAT_W, E_SNP_W)
  `CHI_IF_NETS(e_hni_hsn0_, E_REQ_W, E_RSP_W, E_DAT_W, E_SNP_W)
  `CHI_IF_NETS(e_hni_hsn1_, E_REQ_W, E_RSP_W, E_DAT_W, E_SNP_W)
  `CHI_IF_NETS(e_hni_snf0_, E_REQ_W, E_RSP_W, E_DAT_W, E_SNP_W)
  `CHI_IF_NETS(e_hni_snf1_, E_REQ_W, E_RSP_W, E_DAT_W, E_SNP_W)

  `CHI_IF_NETS(d_coh_hrnf0_, D_REQ_W, D_RSP_W, D_DAT_W, D_SNP_W)
  `CHI_IF_NETS(d_coh_hrnf1_, D_REQ_W, D_RSP_W, D_DAT_W, D_SNP_W)
  `CHI_IF_NETS(d_coh_hnfr0_, D_REQ_W, D_RSP_W, D_DAT_W, D_SNP_W)
  `CHI_IF_NETS(d_coh_hnfr1_, D_REQ_W, D_RSP_W, D_DAT_W, D_SNP_W)
  `CHI_IF_NETS(d_coh_hnfs0_, D_REQ_W, D_RSP_W, D_DAT_W, D_SNP_W)
  `CHI_IF_NETS(d_coh_dsnf0_, D_REQ_W, D_RSP_W, D_DAT_W, D_SNP_W)

  `CHI_IF_NETS(e_coh_hrnf0_, E_REQ_W, E_RSP_W, E_DAT_W, E_SNP_W)
  `CHI_IF_NETS(e_coh_hrnf1_, E_REQ_W, E_RSP_W, E_DAT_W, E_SNP_W)
  `CHI_IF_NETS(e_coh_hnfr0_, E_REQ_W, E_RSP_W, E_DAT_W, E_SNP_W)
  `CHI_IF_NETS(e_coh_hnfr1_, E_REQ_W, E_RSP_W, E_DAT_W, E_SNP_W)
  `CHI_IF_NETS(e_coh_hnfs0_, E_REQ_W, E_RSP_W, E_DAT_W, E_SNP_W)
  `CHI_IF_NETS(e_coh_dsnf0_, E_REQ_W, E_RSP_W, E_DAT_W, E_SNP_W)

  // verilator lint_on UNDRIVEN
  // verilator lint_on UNUSEDSIGNAL

  `CHI_XWIRE(a0_snf_, a0_rni_)
  `CHI_XWIRE(a0_rni_, a0_snf_)

  `CHI_XWIRE(d_snf_, d_rni_)
  `CHI_XWIRE(d_rni_, d_snf_)

  `CHI_XWIRE(e_snf_, e_rni_)
  `CHI_XWIRE(e_rni_, e_snf_)

  `CHI_XWIRE(d_hni_hrn0_, d_hni_rni0_)
  `CHI_XWIRE(d_hni_rni0_, d_hni_hrn0_)
  `CHI_XWIRE(d_hni_hrn1_, d_hni_rni1_)
  `CHI_XWIRE(d_hni_rni1_, d_hni_hrn1_)
  `CHI_XWIRE(d_hni_snf0_, d_hni_hsn0_)
  `CHI_XWIRE(d_hni_hsn0_, d_hni_snf0_)
  `CHI_XWIRE(d_hni_snf1_, d_hni_hsn1_)
  `CHI_XWIRE(d_hni_hsn1_, d_hni_snf1_)

  `CHI_XWIRE(e_hni_hrn0_, e_hni_rni0_)
  `CHI_XWIRE(e_hni_rni0_, e_hni_hrn0_)
  `CHI_XWIRE(e_hni_hrn1_, e_hni_rni1_)
  `CHI_XWIRE(e_hni_rni1_, e_hni_hrn1_)
  `CHI_XWIRE(e_hni_snf0_, e_hni_hsn0_)
  `CHI_XWIRE(e_hni_hsn0_, e_hni_snf0_)
  `CHI_XWIRE(e_hni_snf1_, e_hni_hsn1_)
  `CHI_XWIRE(e_hni_hsn1_, e_hni_snf1_)

  `CHI_XWIRE(d_coh_hnfr0_, d_coh_hrnf0_)
  `CHI_XWIRE(d_coh_hrnf0_, d_coh_hnfr0_)
  `CHI_XWIRE(d_coh_hnfr1_, d_coh_hrnf1_)
  `CHI_XWIRE(d_coh_hrnf1_, d_coh_hnfr1_)
  `CHI_XWIRE(d_coh_dsnf0_, d_coh_hnfs0_)
  `CHI_XWIRE(d_coh_hnfs0_, d_coh_dsnf0_)

  `CHI_XWIRE(e_coh_hnfr0_, e_coh_hrnf0_)
  `CHI_XWIRE(e_coh_hrnf0_, e_coh_hnfr0_)
  `CHI_XWIRE(e_coh_hnfr1_, e_coh_hrnf1_)
  `CHI_XWIRE(e_coh_hrnf1_, e_coh_hnfr1_)
  `CHI_XWIRE(e_coh_dsnf0_, e_coh_hnfs0_)
  `CHI_XWIRE(e_coh_hnfs0_, e_coh_dsnf0_)

endmodule

`undef CHI_IF_NETS
`undef CHI_XWIRE

`default_nettype wire
