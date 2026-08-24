package chi_tb_pkg;

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


  // A0: a third width shape, used only by tc_chi_a0_smoke to exercise the
  // interface and the link adapter at narrower node IDs and a 32-byte data bus
  // than any agent-driven link here. Mirrors A0_CFG in the Python HDL shell.
  localparam vip_chi_cfg_t CHI_A0_CFG_C = '{
    ISSUE_P         : VIP_CHI_ISSUE_D_E,
    NODE_ID_WIDTH_P : 7,
    ADDR_WIDTH_P    : 44,
    DATA_BYTES_P    : 32,
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

  typedef vip_chi_types_d #(CHI_A0_CFG_C) chi_a0_types_t;
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
  // tc_chi_reset_idle_scope: one write before each reset pulse, so
  // link_ever_active latches and the reset-idle rules are armed when the pulse
  // arrives. An unarmed rule reports nothing and reads as a pass.
  localparam item_t::addr_t RESET_IDLE_ADDR_C  = item_t::addr_t'(44'h3000_C000);

  localparam item_t::txn_id_t  AUTO_READ_TXN_ID_C = item_t::txn_id_t'(8'h44);
  localparam item_t::node_id_t RNI_NODE_ID_C      = item_t::node_id_t'(11'h012);
  localparam item_t::node_id_t SNF_NODE_ID_C      = item_t::node_id_t'(11'h031);

  localparam item_e_t::addr_t    E_MTE_ADDR_C         = item_e_t::addr_t'(52'h0012_3456_7800);
  // CHI-E HN-I proxy passthrough address; decodes to SN port 0 under the proxy's
  // default stride sn_port = (addr >> 12) % 2 = (0x..8) % 2 = 0.
  localparam item_e_t::addr_t    E_HNI_WRITE_READ_ADDR_C = item_e_t::addr_t'(52'h0012_3456_8000);
  // A CHI-E configuration with MPAM enabled. Nothing in the regression sets
  // MPAM_EN_P, so the wide-MPAM flit layout was unbuilt as well as unchecked --
  // and MPAM is the one field whose WIDTH is configuration-dependent, so a
  // layout test at MPAM_EN_P = 0 cannot see it. Package scope, and spelled out
  // field by field because a localparam cannot be derived from another by
  // modification.
  localparam vip_chi_cfg_t CHI_E_MPAM_CFG_C = '{
    ISSUE_P         : CHI_E_WIDE_CFG_C.ISSUE_P,
    NODE_ID_WIDTH_P : CHI_E_WIDE_CFG_C.NODE_ID_WIDTH_P,
    ADDR_WIDTH_P    : CHI_E_WIDE_CFG_C.ADDR_WIDTH_P,
    DATA_BYTES_P    : CHI_E_WIDE_CFG_C.DATA_BYTES_P,
    DATACHECK_EN_P  : CHI_E_WIDE_CFG_C.DATACHECK_EN_P,
    POISON_EN_P     : CHI_E_WIDE_CFG_C.POISON_EN_P,
    MPAM_EN_P       : 1'b1,
    PARITY_EN_P     : CHI_E_WIDE_CFG_C.PARITY_EN_P
  };

  // CHI-E HN-I proxy port-1 path. Bit 12 is SET, so the proxy's default decode
  // -- sn_port = (addr >> 12) % N_SN_PORTS -- sends it to SN target 1, where
  // E_HNI_WRITE_READ_ADDR_C above lands on target 0. Its own 0x..3457_xxxx page
  // so no other test's data predictor sees this line. PACKAGE scope for the
  // reason given below on E_HNI_WRITE_READ_ADDR_C.
  localparam item_e_t::addr_t    E_HNI_PORT1_ADDR_C        = item_e_t::addr_t'(52'h0012_3457_1000);
  // Node id for proxy RN port 1, distinct from port 0's so a completion routed
  // to the wrong RN is visible as a hang rather than as a pass.
  localparam item_e_t::node_id_t E_HNI_PORT1_RNI_NODE_ID_C = item_e_t::node_id_t'('h013);

  // MTE tag-integrity addresses, one per test so the two never predict over each
  // other's tag image. PACKAGE scope for the reason given below on
  // E_HNI_WRITE_READ_ADDR_C: a class-scoped localparam of a
  // parameterized-class-nested type hangs vcs1fe codegen at CHI-E flit width.
  localparam item_e_t::addr_t    E_TAG_INTEGRITY_ADDR_C = item_e_t::addr_t'(52'h0012_3456_7b00);
  localparam item_e_t::addr_t    E_TAG_NEGCTL_ADDR_C    = item_e_t::addr_t'(52'h0012_3456_7c00);
  localparam item_e_t::addr_t    E_PERSIST_ADDR_C     = item_e_t::addr_t'(52'h0012_3456_7900);
  localparam item_e_t::addr_t    E_PERSIST_SEP_ADDR_C = item_e_t::addr_t'(52'h0012_3456_7a00);
  localparam item_e_t::addr_t    E_DBID_RESP_ORD_ADDR_C = item_e_t::addr_t'(52'h0012_3456_7d00);
  // WriteUniqueZero identifier control. Its own line, node-ID pair and TxnIDs so
  // nothing it injects can be confused with another testcase's traffic, and the
  // two TxnIDs are separated on purpose: one is completed cleanly and one is
  // deliberately reused while still outstanding.
  localparam item_e_t::addr_t    E_WUZ_NEGCTL_ADDR_C        = item_e_t::addr_t'(52'h0012_3456_7e00);
  localparam item_e_t::node_id_t E_WUZ_NEGCTL_RNI_NODE_ID_C = item_e_t::node_id_t'('h01e);
  localparam item_e_t::node_id_t E_WUZ_NEGCTL_SNF_NODE_ID_C = item_e_t::node_id_t'('h027);
  localparam item_e_t::txn_id_t  E_WUZ_NEGCTL_TXN_ID_PASS_C = item_e_t::txn_id_t'(8'h71);
  localparam item_e_t::txn_id_t  E_WUZ_NEGCTL_TXN_ID_DUP_C  = item_e_t::txn_id_t'(8'h72);

  // tc_chi_txnid_reuse_srcid_scope. Two DIFFERENT SrcIDs holding one TxnID is
  // the legal case section 2.5 describes, so the two node IDs must differ and
  // neither may collide with the SN-F's -- a request whose SrcID equals its
  // TgtID is a different kind of malformed and would muddy the verdict.
  localparam item_e_t::node_id_t TXNID_SCOPE_SRC_A_C  = item_e_t::node_id_t'('h01e);
  localparam item_e_t::node_id_t TXNID_SCOPE_SRC_B_C  = item_e_t::node_id_t'('h03b);
  localparam item_e_t::txn_id_t  TXNID_SCOPE_TXN_ID_C = item_e_t::txn_id_t'(8'h73);

  // tc_chi_comp_dbid_negctl. One transaction per raw-injected phase, so the
  // counts stay separable; two DBID values that must differ, so the mismatch is
  // unambiguous. Phase C drives a real atomic and needs neither.
  localparam item_e_t::txn_id_t COMP_DBID_TXN_ID_PASS_C   = item_e_t::txn_id_t'(8'h74);
  localparam item_e_t::txn_id_t COMP_DBID_TXN_ID_FAIL_C   = item_e_t::txn_id_t'(8'h75);
  localparam item_e_t::txn_id_t COMP_DBID_GRANTED_C       = item_e_t::txn_id_t'(8'h21);
  localparam item_e_t::txn_id_t COMP_DBID_OTHER_C         = item_e_t::txn_id_t'(8'h22);
  // Retry field control. Its own line, node-ID pair and TxnIDs, for the same
  // reason as the WriteUniqueZero pair above. Two TxnIDs because the two phases
  // inject on different opcodes and neither may retire the other's transaction.
  // PCRD_TYPE is non-zero and that is the whole point: phase A pairs it with
  // AllowRetry asserted, which section 2.9.4 forbids, and phase B returns it on
  // a PCrdReturn where the field is the one thing that must NOT be zero.
  localparam item_e_t::addr_t    E_RETRY_NEGCTL_ADDR_C        = item_e_t::addr_t'(52'h0012_3456_7f00);
  localparam item_e_t::node_id_t E_RETRY_NEGCTL_RNI_NODE_ID_C = item_e_t::node_id_t'('h019);
  localparam item_e_t::node_id_t E_RETRY_NEGCTL_SNF_NODE_ID_C = item_e_t::node_id_t'('h02e);
  localparam item_e_t::txn_id_t  E_RETRY_NEGCTL_TXN_ID_C      = item_e_t::txn_id_t'(8'h73);
  localparam logic [3 : 0]       E_RETRY_NEGCTL_PCRD_TYPE_C   = 4'h5;
  // A TxnID no request in this test ever uses, for the stray RetryAck of phase C.
  localparam item_e_t::txn_id_t  E_RETRY_NEGCTL_STRAY_TXN_ID_C = item_e_t::txn_id_t'(8'h74);
  // CHI-E WriteNoSnpZero readback address. Kept at PACKAGE scope (not a
  // class-scoped localparam) because a class-scoped `localparam item_e_t::addr_t`
  // hangs vcs1fe codegen at CHI-E flit width -- the same trap fixed earlier for
  // E_HNI_WRITE_READ_ADDR_C. Cast at use, never type a class constant with a
  // parameterized-class-nested type.
  localparam item_e_t::addr_t    E_WRITE_ZERO_ADDR_C  = item_e_t::addr_t'(52'h0012_3456_9000);
  // Combined Write + CMO base address. The six forms walk upwards from here in
  // E_WRITE_CMO_STRIDE_C steps so no two share a line: they are read back
  // afterwards, and one address for all six would let a later form's data hide
  // an earlier form's dropped write. PACKAGE scope for the vcs1fe reason above.
  localparam item_e_t::addr_t    E_WRITE_CMO_ADDR_C   = item_e_t::addr_t'(52'h0012_3456_a000);
  localparam int unsigned        E_WRITE_CMO_STRIDE_C = 'h1000;
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

  `include "chi_tb_config.sv"
  `include "chi_check_report.svh"

  `include "chi_virtual_sequencer.sv"
  `include "chi_tb_env.sv"
  `include "chi_e_tb_env.sv"
  `include "chi_e_proxy_tb_env.sv"
  `include "chi_coherent_tb_env.sv"

endpackage