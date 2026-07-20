package vip_chi_tb_pkg;

  `include "uvm_macros.svh"
  import uvm_pkg::*;

  import vip_chi_types_pkg::*;
  import vip_chi_agent_pkg::*;

  localparam vip_chi_cfg_t CHI_D_CFG_C = '{
    ISSUE_P         : VIP_CHI_ISSUE_D_E,
    NODE_ID_WIDTH_P : 11,
    ADDR_WIDTH_P    : 44,
    DATA_BYTES_P    : 16,
    DATACHECK_EN_P  : 1'b0,
    POISON_EN_P     : 1'b0,
    MPAM_EN_P       : 1'b0,
    PARITY_EN_P     : 1'b0
  };


  localparam vip_chi_cfg_t CHI_D_WIDE_CFG_C = '{
    ISSUE_P         : VIP_CHI_ISSUE_D_E,
    NODE_ID_WIDTH_P : 11,
    ADDR_WIDTH_P    : 44,
    DATA_BYTES_P    : 64,
    DATACHECK_EN_P  : 1'b0,
    POISON_EN_P     : 1'b0,
    MPAM_EN_P       : 1'b0,
    PARITY_EN_P     : 1'b0
  };

  localparam vip_chi_cfg_t CHI_E_WIDE_CFG_C = '{
    ISSUE_P         : VIP_CHI_ISSUE_E_E,
    NODE_ID_WIDTH_P : 11,
    ADDR_WIDTH_P    : 52,
    DATA_BYTES_P    : 64,
    DATACHECK_EN_P  : 1'b0,
    POISON_EN_P     : 1'b0,
    MPAM_EN_P       : 1'b0,
    PARITY_EN_P     : 1'b0
  };

  typedef vip_chi_types_d #(CHI_D_CFG_C) chi_d_types_t;
  typedef vip_chi_types_d #(CHI_D_WIDE_CFG_C) chi_d_wide_types_t;
  typedef vip_chi_types_e #(CHI_E_WIDE_CFG_C) chi_e_wide_types_t;
  typedef vip_chi_item    #(CHI_D_CFG_C) item_t;
  typedef vip_chi_item    #(CHI_E_WIDE_CFG_C) item_e_t;

  localparam item_t::addr_t ATOMIC_ADDR_C              = item_t::addr_t'(44'h0000_1240);
  localparam item_t::addr_t ATOMIC_VARIANT_BASE_ADDR_C = item_t::addr_t'(44'h0000_1800);
  localparam item_t::addr_t ATOMIC_VARIANT_ADDR_STRIDE_C = item_t::addr_t'(44'h0000_0040);
  localparam item_t::addr_t WRITE_READ_ADDR_C = item_t::addr_t'(44'h3000_8000);
  localparam item_t::addr_t WRITE_ADDR_C      = item_t::addr_t'(44'h3000_9000);
  localparam item_t::addr_t DECERR_ADDR_C     = item_t::addr_t'(44'h3000_A000);
  localparam item_t::addr_t DERR_ADDR_C       = item_t::addr_t'(44'h3000_B000);
  localparam item_t::addr_t READ_ADDR_C       = item_t::addr_t'(44'h2000_4000);
  localparam item_t::addr_t AUTO_READ_ADDR_C  = item_t::addr_t'(44'h1000_2000);

  localparam item_t::txn_id_t  AUTO_READ_TXN_ID_C = item_t::txn_id_t'(8'h44);
  localparam item_t::node_id_t RNI_NODE_ID_C      = item_t::node_id_t'(11'h012);
  localparam item_t::node_id_t SNF_NODE_ID_C      = item_t::node_id_t'(11'h031);

  localparam item_e_t::addr_t    E_MTE_ADDR_C         = item_e_t::addr_t'(52'h0012_3456_7800);
  // CHI-E HN-I proxy passthrough address; decodes to SN port 0 under the proxy's
  // default stride sn_port = (addr >> 12) % 2 = (0x..8) % 2 = 0.
  localparam item_e_t::addr_t    E_HNI_WRITE_READ_ADDR_C = item_e_t::addr_t'(52'h0012_3456_8000);
  localparam item_e_t::addr_t    E_PERSIST_ADDR_C     = item_e_t::addr_t'(52'h0012_3456_7900);
  localparam item_e_t::addr_t    E_PERSIST_SEP_ADDR_C = item_e_t::addr_t'(52'h0012_3456_7a00);
  localparam item_e_t::addr_t    E_DBID_RESP_ORD_ADDR_C = item_e_t::addr_t'(52'h0012_3456_7d00);
  // CHI-E WriteNoSnpZero readback address. Kept at PACKAGE scope (not a
  // class-scoped localparam) because a class-scoped `localparam item_e_t::addr_t`
  // hangs vcs1fe codegen at CHI-E flit width -- the same trap fixed earlier for
  // E_HNI_WRITE_READ_ADDR_C. Cast at use, never type a class constant with a
  // parameterized-class-nested type.
  localparam item_e_t::addr_t    E_WRITE_ZERO_ADDR_C  = item_e_t::addr_t'(52'h0012_3456_9000);
  localparam item_e_t::txn_id_t  E_MTE_WRITE_TXN_ID_C = item_e_t::txn_id_t'(8'h61);
  localparam item_e_t::txn_id_t  E_MTE_READ_TXN_ID_C  = item_e_t::txn_id_t'(8'h62);
  localparam item_e_t::node_id_t E_MTE_RNI_NODE_ID_C  = item_e_t::node_id_t'('h01c);
  localparam item_e_t::node_id_t E_MTE_SNF_NODE_ID_C  = item_e_t::node_id_t'('h022);
  localparam item_e_t::node_id_t E_PERSIST_RNI_NODE_ID_C = item_e_t::node_id_t'('h016);
  localparam item_e_t::node_id_t E_PERSIST_SNF_NODE_ID_C = item_e_t::node_id_t'('h02b);
  localparam item_e_t::node_id_t E_PERSIST_SEP_RNI_NODE_ID_C = item_e_t::node_id_t'('h017);
  localparam item_e_t::node_id_t E_PERSIST_SEP_SNF_NODE_ID_C = item_e_t::node_id_t'('h02c);
  localparam item_e_t::node_id_t E_DBID_RESP_ORD_RNI_NODE_ID_C = item_e_t::node_id_t'('h01d);
  localparam item_e_t::node_id_t E_DBID_RESP_ORD_SNF_NODE_ID_C = item_e_t::node_id_t'('h026);
  localparam item_e_t::data_t    E_MTE_WRITE_DATA_C   = item_e_t::data_t'('h1_2233_4455_6677_8899_aabb_ccdd_eeff);
  localparam item_e_t::tagop_t   E_MTE_WRITE_TAGOP_C  = item_e_t::tagop_t'('h2);
  localparam item_e_t::tag_t     E_MTE_WRITE_TAG_C    = item_e_t::tag_t'('h3456);
  localparam item_e_t::tu_t      E_MTE_WRITE_TU_C     = item_e_t::tu_t'('hb);

  `include "vip_chi_tb_config.sv"

  `include "vip_chi_virtual_sequencer.sv"
  `include "vip_chi_tb_env.sv"
  `include "vip_chi_e_tb_env.sv"
  `include "vip_chi_e_proxy_tb_env.sv"
  `include "vip_chi_coherent_tb_env.sv"

endpackage