////////////////////////////////////////////////////////////////////////////////
//
// Copyright (C) 2026 Fredrik Akerlund
// https://github.com/akerlund/vip_chi_agent
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//
////////////////////////////////////////////////////////////////////////////////

`ifndef VIP_CHI_TYPES_PKG
`define VIP_CHI_TYPES_PKG

package vip_chi_types_pkg;

  // ---------------------------------------------------------------------------
  // 1. Spec-derived field widths.
  // ---------------------------------------------------------------------------
  localparam int VIP_CHI_REQ_SIZE_WIDTH_C     = 3;
  localparam int VIP_CHI_MPAM_WIDTH_C         = 11;
  localparam int VIP_CHI_QOS_WIDTH_C          = 4;
  localparam int VIP_CHI_PCRD_TYPE_WIDTH_C    = 4;
  localparam int VIP_CHI_TAGOP_WIDTH_C        = 2;
  localparam int VIP_CHI_GROUP_ID_EXT_WIDTH_C = 3;
  localparam int VIP_CHI_RESP_WIDTH_C         = 3;
  localparam int VIP_CHI_RESP_ERR_WIDTH_C     = 2;

  // ---------------------------------------------------------------------------
  // 2. Spec-envelope maxima used by the VIP type system.
  // These width caps let the package declare one canonical superset encoding
  // for the D/E opcode spaces and one max address width for common typedefs.
  // ---------------------------------------------------------------------------

  localparam int VIP_CHI_MAX_ADDR_WIDTH_C       = 52;
  localparam int VIP_CHI_MAX_REQ_OPCODE_WIDTH_C = 7;
  localparam int VIP_CHI_MAX_RSP_OPCODE_WIDTH_C = 5;
  localparam int VIP_CHI_MAX_DAT_OPCODE_WIDTH_C = 4;
  localparam int VIP_CHI_MAX_SNP_OPCODE_WIDTH_C = 5;

  // ---------------------------------------------------------------------------
  // Convenience scalar typedefs for the fixed-width PCrdType and QoS fields.
  // Reused by the item, the REQ/RSP flit structs, the RN-I/SN-F P-credit
  // bookkeeping and the coverage sampler in place of open-coded
  // logic [VIP_CHI_*_WIDTH_C-1:0] vectors.
  // ---------------------------------------------------------------------------

  typedef logic [VIP_CHI_PCRD_TYPE_WIDTH_C - 1 : 0] vip_chi_pcrd_type_t;
  typedef logic [VIP_CHI_QOS_WIDTH_C       - 1 : 0] vip_chi_qos_t;

  // ---------------------------------------------------------------------------
  // Spec-derived response and opcode encodings.
  // ---------------------------------------------------------------------------

  localparam logic [2 : 0] VIP_CHI_RESP_NORMAL_OKAY_C = 3'b000;
  localparam logic [2 : 0] VIP_CHI_RESP_DERR_C        = 3'b010;
  localparam logic [2 : 0] VIP_CHI_RESP_NDERR_C       = 3'b011;

  localparam logic [1 : 0] VIP_CHI_RESP_ERR_NORMAL_OKAY_C = 2'b00;
  localparam logic [1 : 0] VIP_CHI_RESP_ERR_EXOKAY_C      = 2'b01;
  localparam logic [1 : 0] VIP_CHI_RESP_ERR_DERR_C        = 2'b10;
  localparam logic [1 : 0] VIP_CHI_RESP_ERR_NDERR_C       = 2'b11;

  localparam logic [VIP_CHI_MAX_REQ_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_REQ_READ_NO_SNP_C              = 7'h04;
  localparam logic [VIP_CHI_MAX_REQ_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_REQ_PCRD_RETURN_C              = 7'h05;
  localparam logic [VIP_CHI_MAX_REQ_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_REQ_READ_NO_SNP_SEP_C          = 7'h11;
  localparam logic [VIP_CHI_MAX_REQ_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_REQ_CLEAN_SHARED_PERSIST_SEP_C = 7'h13;
  localparam logic [VIP_CHI_MAX_REQ_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_REQ_WRITE_NO_SNP_PTL_C         = 7'h1C;
  localparam logic [VIP_CHI_MAX_REQ_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_REQ_WRITE_NO_SNP_FULL_C        = 7'h1D;
  localparam logic [VIP_CHI_MAX_REQ_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_REQ_CLEAN_SHARED_PERSIST_C     = 7'h27;
  localparam logic [VIP_CHI_MAX_REQ_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_REQ_ATOMIC_STORE_0_C           = 7'h28;
  localparam logic [VIP_CHI_MAX_REQ_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_REQ_ATOMIC_STORE_1_C           = 7'h29;
  localparam logic [VIP_CHI_MAX_REQ_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_REQ_ATOMIC_STORE_2_C           = 7'h2A;
  localparam logic [VIP_CHI_MAX_REQ_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_REQ_ATOMIC_STORE_3_C           = 7'h2B;
  localparam logic [VIP_CHI_MAX_REQ_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_REQ_ATOMIC_STORE_4_C           = 7'h2C;
  localparam logic [VIP_CHI_MAX_REQ_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_REQ_ATOMIC_STORE_5_C           = 7'h2D;
  localparam logic [VIP_CHI_MAX_REQ_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_REQ_ATOMIC_STORE_6_C           = 7'h2E;
  localparam logic [VIP_CHI_MAX_REQ_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_REQ_ATOMIC_STORE_7_C           = 7'h2F;
  localparam logic [VIP_CHI_MAX_REQ_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_REQ_ATOMIC_LOAD_0_C            = 7'h30;
  localparam logic [VIP_CHI_MAX_REQ_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_REQ_ATOMIC_LOAD_1_C            = 7'h31;
  localparam logic [VIP_CHI_MAX_REQ_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_REQ_ATOMIC_LOAD_2_C            = 7'h32;
  localparam logic [VIP_CHI_MAX_REQ_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_REQ_ATOMIC_LOAD_3_C            = 7'h33;
  localparam logic [VIP_CHI_MAX_REQ_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_REQ_ATOMIC_LOAD_4_C            = 7'h34;
  localparam logic [VIP_CHI_MAX_REQ_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_REQ_ATOMIC_LOAD_5_C            = 7'h35;
  localparam logic [VIP_CHI_MAX_REQ_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_REQ_ATOMIC_LOAD_6_C            = 7'h36;
  localparam logic [VIP_CHI_MAX_REQ_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_REQ_ATOMIC_LOAD_7_C            = 7'h37;
  localparam logic [VIP_CHI_MAX_REQ_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_REQ_ATOMIC_SWAP_C              = 7'h38;
  localparam logic [VIP_CHI_MAX_REQ_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_REQ_ATOMIC_COMPARE_C           = 7'h39;
  localparam logic [VIP_CHI_MAX_REQ_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_REQ_PREFETCH_TGT_C             = 7'h3A;
  localparam logic [VIP_CHI_MAX_REQ_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_REQ_MAKE_READ_UNIQUE_C         = 7'h41;
  localparam logic [VIP_CHI_MAX_REQ_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_REQ_WRITE_NO_SNP_ZERO_C        = 7'h44;

  // Coherent REQ opcodes (Tier C: RN-F <-> HN-F). All <= 0x1B so they fit the
  // narrower CHI-D 6-bit REQ opcode field as well as CHI-E's 7-bit field.
  localparam logic [VIP_CHI_MAX_REQ_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_REQ_READ_SHARED_C      = 7'h01;
  localparam logic [VIP_CHI_MAX_REQ_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_REQ_READ_CLEAN_C       = 7'h02;
  localparam logic [VIP_CHI_MAX_REQ_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_REQ_READ_UNIQUE_C      = 7'h07;
  localparam logic [VIP_CHI_MAX_REQ_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_REQ_CLEAN_SHARED_C     = 7'h08;
  localparam logic [VIP_CHI_MAX_REQ_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_REQ_CLEAN_INVALID_C    = 7'h09;
  localparam logic [VIP_CHI_MAX_REQ_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_REQ_MAKE_INVALID_C     = 7'h0A;
  localparam logic [VIP_CHI_MAX_REQ_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_REQ_CLEAN_UNIQUE_C     = 7'h0B;
  localparam logic [VIP_CHI_MAX_REQ_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_REQ_MAKE_UNIQUE_C      = 7'h0C;
  localparam logic [VIP_CHI_MAX_REQ_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_REQ_EVICT_C            = 7'h0D;
  localparam logic [VIP_CHI_MAX_REQ_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_REQ_WRITE_CLEAN_FULL_C = 7'h17;
  localparam logic [VIP_CHI_MAX_REQ_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_REQ_WRITE_BACK_FULL_C  = 7'h1B;

  // CMO / one-shot coherent additions (Tier-C follow-on). All <= 0x1B so they also
  // fit the narrower CHI-D 6-bit REQ opcode field. IHI 0050 encodings.
  localparam logic [VIP_CHI_MAX_REQ_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_REQ_READ_ONCE_C         = 7'h03;
  localparam logic [VIP_CHI_MAX_REQ_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_REQ_WRITE_UNIQUE_PTL_C  = 7'h18;
  localparam logic [VIP_CHI_MAX_REQ_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_REQ_WRITE_UNIQUE_FULL_C = 7'h19;

  // Combined Write + CMO (Issue E only). One request carrying both a write and a
  // cache-maintenance operation to the same address, which the completer must
  // apply IN THAT ORDER -- the CMO acts on the state the write leaves behind, so
  // a completer that applied them the other way round would be silently wrong on
  // exactly the case the combined form exists to make efficient.
  //
  // Table 13-14 is two-dimensional: rows are Opcode[5:0] and these all sit in
  // the Opcode[6] = 1 column, which is why they are 0x40 above the row value and
  // why they cannot fit CHI-D's 6-bit REQ opcode field at all.
  localparam logic [VIP_CHI_MAX_REQ_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_REQ_WRITE_NO_SNP_FULL_CLEAN_SH_C         = 7'h50;
  localparam logic [VIP_CHI_MAX_REQ_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_REQ_WRITE_NO_SNP_FULL_CLEAN_INV_C        = 7'h51;
  localparam logic [VIP_CHI_MAX_REQ_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_REQ_WRITE_NO_SNP_FULL_CLEAN_SH_PER_SEP_C = 7'h52;
  localparam logic [VIP_CHI_MAX_REQ_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_REQ_WRITE_NO_SNP_PTL_CLEAN_SH_C          = 7'h60;
  localparam logic [VIP_CHI_MAX_REQ_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_REQ_WRITE_NO_SNP_PTL_CLEAN_INV_C         = 7'h61;
  localparam logic [VIP_CHI_MAX_REQ_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_REQ_WRITE_NO_SNP_PTL_CLEAN_SH_PER_SEP_C  = 7'h62;

  localparam logic [VIP_CHI_MAX_RSP_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_RSP_COMP_ACK_C       = 5'h02;
  localparam logic [VIP_CHI_MAX_RSP_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_RSP_RETRY_ACK_C      = 5'h03;
  localparam logic [VIP_CHI_MAX_RSP_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_RSP_COMP_C           = 5'h04;
  localparam logic [VIP_CHI_MAX_RSP_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_RSP_COMP_DBID_RESP_C = 5'h05;
  localparam logic [VIP_CHI_MAX_RSP_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_RSP_DBID_RESP_C      = 5'h06;
  localparam logic [VIP_CHI_MAX_RSP_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_RSP_PCRD_GRANT_C     = 5'h07;
  localparam logic [VIP_CHI_MAX_RSP_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_RSP_READ_RECEIPT_C   = 5'h08;
  localparam logic [VIP_CHI_MAX_RSP_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_RSP_RESP_SEP_DATA_C  = 5'h0B;
  localparam logic [VIP_CHI_MAX_RSP_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_RSP_PERSIST_C        = 5'h0C;
  localparam logic [VIP_CHI_MAX_RSP_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_RSP_COMP_PERSIST_C   = 5'h0D;
  localparam logic [VIP_CHI_MAX_RSP_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_RSP_DBID_RESP_ORD_C  = 5'h0E;
  // The CMO half of a Combined Write's completion (Issue E only). The write half
  // completes with Comp / CompDBIDResp as any write does; the CMO half is a
  // SEPARATE response, and a completer that answered a combined request with the
  // write completion alone would leave the CMO permanently outstanding.
  localparam logic [VIP_CHI_MAX_RSP_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_RSP_COMP_CMO_C       = 5'h14;

  // Snoop-response RSP opcodes (Tier C). IHI0050 RSP encodings: SnpResp = 0x01,
  // SnpRespFwded = 0x09 (0x0A is TagMatch). Both fit the CHI-D 4-bit and CHI-E
  // 5-bit RSP opcode fields.
  localparam logic [VIP_CHI_MAX_RSP_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_RSP_SNP_RESP_C       = 5'h01;
  localparam logic [VIP_CHI_MAX_RSP_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_RSP_SNP_RESP_FWDED_C = 5'h09;

  localparam logic [VIP_CHI_MAX_DAT_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_DAT_NON_COPY_BACK_WR_DATA_C = 4'h3;
  localparam logic [VIP_CHI_MAX_DAT_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_DAT_COMP_DATA_C             = 4'h4;
  localparam logic [VIP_CHI_MAX_DAT_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_DAT_DATA_SEP_RESP_C         = 4'hB;
  localparam logic [VIP_CHI_MAX_DAT_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_DAT_NCB_WR_DATA_COMP_ACK_C  = 4'hC;

  // Snoop-response + copy-back DAT opcodes (Tier C). 0x1/0x2/0x5/0x6 are free in
  // the shared 4-bit DAT opcode field (existing members use 0x3/0x4/0xB/0xC).
  localparam logic [VIP_CHI_MAX_DAT_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_DAT_SNP_RESP_DATA_C       = 4'h1;
  localparam logic [VIP_CHI_MAX_DAT_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_DAT_COPY_BACK_WR_DATA_C   = 4'h2;
  localparam logic [VIP_CHI_MAX_DAT_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_DAT_SNP_RESP_DATA_PTL_C   = 4'h5;
  localparam logic [VIP_CHI_MAX_DAT_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_DAT_SNP_RESP_DATA_FWDED_C = 4'h6;

  // L-credit return. Opcode 0 on EVERY channel, which is why it is one block
  // rather than four entries scattered among the transaction opcodes: a flit
  // whose opcode is zero carries no transaction at all, it hands one L-credit
  // back to the receiver that granted it. That is how a sender empties its
  // credit pool before the link goes down, and without it a graceful
  // deactivation is impossible -- the credits it still held would be stranded,
  // which is exactly what VIP_CHI_CHK_LCRD_QUIESCENT_IN_STOP_E reports.
  //
  // The return itself CONSUMES the credit it returns (it is a flit like any
  // other, sent under an available credit), so N returns empty a pool of N and
  // the shadow counters need no special case. What does need a special case is
  // everything that treats a flit as a transaction: the monitor must not
  // publish one, and the flit-requires-RUN rules must admit one in DEACTIVATE,
  // which is the only state in which a sender is still permitted to transmit.
  localparam logic [VIP_CHI_MAX_REQ_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_REQ_LCRD_RETURN_C = 7'h00;
  localparam logic [VIP_CHI_MAX_RSP_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_RSP_LCRD_RETURN_C = 5'h00;
  localparam logic [VIP_CHI_MAX_DAT_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_DAT_LCRD_RETURN_C = 4'h00;
  localparam logic [VIP_CHI_MAX_SNP_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_SNP_LCRD_RETURN_C = 5'h00;

  // Snoop-request (SNP channel) opcodes (Tier C). 5-bit SnpOpcode field.
  localparam logic [VIP_CHI_MAX_SNP_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_SNP_SHARED_C        = 5'h01;
  localparam logic [VIP_CHI_MAX_SNP_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_SNP_CLEAN_C         = 5'h02;
  localparam logic [VIP_CHI_MAX_SNP_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_SNP_ONCE_C          = 5'h03;
  localparam logic [VIP_CHI_MAX_SNP_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_SNP_UNIQUE_C        = 5'h07;
  localparam logic [VIP_CHI_MAX_SNP_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_SNP_CLEAN_SHARED_C  = 5'h08;
  localparam logic [VIP_CHI_MAX_SNP_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_SNP_CLEAN_INVALID_C = 5'h09;
  localparam logic [VIP_CHI_MAX_SNP_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_SNP_MAKE_INVALID_C  = 5'h0A;

  // Forwarding (direct cache transfer, DCT) snoops -- the snooped RN-F forwards
  // CompData straight to the requester (FwdNID/FwdTxnID) plus a reduced
  // SnpRespFwded/SnpRespDataFwded to the home. IHI0050 Ch.12 encodings: each is
  // its non-fwd opcode with bit[4] set (SnpUnique 0x07 -> SnpUniqueFwd 0x17).
  // All fit the 5-bit SnpOpcode field (both issues) and are distinct above.
  localparam logic [VIP_CHI_MAX_SNP_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_SNP_SHARED_FWD_C           = 5'h11;
  localparam logic [VIP_CHI_MAX_SNP_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_SNP_CLEAN_FWD_C            = 5'h12;
  localparam logic [VIP_CHI_MAX_SNP_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_SNP_ONCE_FWD_C             = 5'h13;
  localparam logic [VIP_CHI_MAX_SNP_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_SNP_NOT_SHARED_DIRTY_FWD_C = 5'h14;
  localparam logic [VIP_CHI_MAX_SNP_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_SNP_UNIQUE_FWD_C           = 5'h17;

  // ---------------------------------------------------------------------------
  // 3. VIP-local helper constants.
  // ---------------------------------------------------------------------------

  localparam int          VIP_CHI_CACHE_LINE_BYTES_C   = 64;
  localparam int unsigned VIP_CHI_UNLIMITED_REQUESTS_C = '1;

  typedef enum logic {
    VIP_CHI_ISSUE_D_E = 1'b0,
    VIP_CHI_ISSUE_E_E = 1'b1
  } vip_chi_issue_t;

  typedef enum logic [2 : 0] {
    VIP_CHI_ROLE_MONITOR_E = 3'd0,
    VIP_CHI_ROLE_SNF_E     = 3'd1,
    VIP_CHI_ROLE_RNI_E     = 3'd2,
    VIP_CHI_ROLE_HNI_E     = 3'd3,
    VIP_CHI_ROLE_RNF_E     = 3'd4,
    VIP_CHI_ROLE_HNF_E     = 3'd5
  } vip_chi_role_t;

  typedef enum logic {
    VIP_CHI_DIR_READ_E  = 1'b0,
    VIP_CHI_DIR_WRITE_E = 1'b1
  } vip_chi_dir_t;

  typedef enum logic [2 : 0] {
    VIP_CHI_RAW_NONE_E = 3'd0,
    VIP_CHI_RAW_REQ_E  = 3'd1,
    VIP_CHI_RAW_RSP_E  = 3'd2,
    VIP_CHI_RAW_DAT_E  = 3'd3,
    VIP_CHI_RAW_SNP_E  = 3'd4
  } vip_chi_raw_channel_t;

  typedef struct packed {
    vip_chi_issue_t ISSUE_P;
    bit [31 : 0]    NODE_ID_WIDTH_P;
    bit [31 : 0]    ADDR_WIDTH_P;
    bit [31 : 0]    DATA_BYTES_P;
    bit             DATACHECK_EN_P;
    bit             POISON_EN_P;
    bit             MPAM_EN_P;
    bit             PARITY_EN_P;
  } vip_chi_cfg_t;

  localparam vip_chi_cfg_t VIP_CHI_DEFAULT_CFG_C = '{
    ISSUE_P         : VIP_CHI_ISSUE_D_E,
    NODE_ID_WIDTH_P : 32'd1,
    ADDR_WIDTH_P    : 32'd1,
    DATA_BYTES_P    : 32'd1,
    DATACHECK_EN_P  : 1'b0,
    POISON_EN_P     : 1'b0,
    MPAM_EN_P       : 1'b0,
    PARITY_EN_P     : 1'b0
  };

  typedef enum logic [2 : 0] {
    VIP_CHI_DATA_RANDOM_E  = 3'd0,
    VIP_CHI_DATA_COUNTER_E = 3'd1,
    VIP_CHI_DATA_ZEROS_E   = 3'd2,
    VIP_CHI_DATA_ONES_E    = 3'd3,
    VIP_CHI_DATA_CUSTOM_E  = 3'd4
  } vip_chi_data_type_t;

  typedef enum logic {
    VIP_CHI_REQ_SECURE_ACCESS_E     = 1'b0,
    VIP_CHI_REQ_NON_SECURE_ACCESS_E = 1'b1
  } vip_chi_req_ns_t;

  typedef enum logic {
    VIP_CHI_REQ_NORMAL_E    = 1'b0,
    VIP_CHI_REQ_EXCLUSIVE_E = 1'b1
  } vip_chi_exclusive_t;

  typedef enum logic [1 : 0] {
    VIP_CHI_ORDER_NONE_E         = 2'b00,
    VIP_CHI_ORDER_REQ_ACCEPTED_E = 2'b01,
    VIP_CHI_ORDER_REQ_ORDER_E    = 2'b10,
    VIP_CHI_ORDER_ENDPOINT_E     = 2'b11
  } vip_chi_req_order_t;

  // Link Activation State Machine. The state is a {LINKACTIVEREQ, LINKACTIVEACK}
  // pair, so it is derived from the wires rather than from which node happens to
  // originate activation -- which is what makes it usable on a VIP that
  // activates asymmetrically. One instance per LINK here, not one per direction:
  // this VIP's link adapter mirrors both sideband signals to both endpoints, so
  // a link carries a single handshake that both ends observe. See the comment on
  // link_lasm() in vip_chi_sva for why modelling it per direction is wrong.
  //
  // The encoding is the pair itself ({req, ack}), so vip_chi_lasm() is a cast
  // rather than a lookup and the enum prints as the signals a waveform shows.
  // Note that the legal cycle STOP -> ACTIVATE -> RUN -> DEACTIVATE -> STOP is
  // therefore NOT numerically ordered: DEACTIVATE (req low, ack still high) is
  // 2'b01 and ACTIVATE (req high, ack not yet) is 2'b10.
  typedef enum logic [1 : 0] {
    VIP_CHI_LASM_STOP_E       = 2'b00,
    VIP_CHI_LASM_DEACTIVATE_E = 2'b01,
    VIP_CHI_LASM_ACTIVATE_E   = 2'b10,
    VIP_CHI_LASM_RUN_E        = 2'b11
  } vip_chi_lasm_state_t;

  // Map one direction's request/acknowledge pair onto its LASM state.
  function automatic vip_chi_lasm_state_t vip_chi_lasm(input bit req, input bit ack);
    return vip_chi_lasm_state_t'({req, ack});
  endfunction

  // TRUE when `nxt` may legally follow `cur`. The LASM advances around a single
  // cycle and may hold in any state; every other pair is a protocol violation.
  // Written as an explicit case rather than arithmetic on the encoding because
  // the encoding is the signal pair, not the cycle position.
  function automatic bit vip_chi_lasm_legal_step(
    input vip_chi_lasm_state_t cur,
    input vip_chi_lasm_state_t nxt
  );
    if (cur == nxt) begin
      return 1'b1;
    end

    case (cur)
      VIP_CHI_LASM_STOP_E:       return (nxt == VIP_CHI_LASM_ACTIVATE_E);
      VIP_CHI_LASM_ACTIVATE_E:   return (nxt == VIP_CHI_LASM_RUN_E);
      VIP_CHI_LASM_RUN_E:        return (nxt == VIP_CHI_LASM_DEACTIVATE_E);
      VIP_CHI_LASM_DEACTIVATE_E: return (nxt == VIP_CHI_LASM_STOP_E);
      default:                   return 1'b0;
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // Protocol-check identity.
  //
  // One entry per RULE, not per assertion site: where a rule is asserted twice
  // because the requester and completer sides need different antecedents (the
  // completion, atomic-return and ordered-read-receipt rules), both sites carry
  // the same ID. That is what makes a disable meaningful -- a user standing a
  // rule down means the rule, not one role's half of it.
  //
  // The order is stable across releases and new entries go at the END, before
  // VIP_CHI_CHK_NUM_E: the IDs are used in plusargs and in regression exports,
  // so renumbering would silently repoint a `+vip_chi_disable_check=` written
  // against an older build.
  //
  // The names match the Python checker's rule strings exactly, with the
  // VIP_CHI_CHK_ prefix and _E suffix stripped and CHI_ prepended -- see
  // vip_chi_check_name(). Keeping one derivation rather than a second lookup
  // table is what stops the two ports drifting into different spellings of the
  // same rule.
  // ---------------------------------------------------------------------------
  typedef enum int {
    // Channel structural rules, one per REQ/RSP/DAT channel.
    VIP_CHI_CHK_REQ_FLITV_REQUIRES_LINK_E = 0,
    VIP_CHI_CHK_RSP_FLITV_REQUIRES_LINK_E,
    VIP_CHI_CHK_DAT_FLITV_REQUIRES_LINK_E,
    VIP_CHI_CHK_REQ_LCRDV_REQUIRES_LINK_E,
    VIP_CHI_CHK_RSP_LCRDV_REQUIRES_LINK_E,
    VIP_CHI_CHK_DAT_LCRDV_REQUIRES_LINK_E,
    VIP_CHI_CHK_REQ_PEND_REQUIRES_VALID_E,
    VIP_CHI_CHK_RSP_PEND_REQUIRES_VALID_E,
    VIP_CHI_CHK_DAT_PEND_REQUIRES_VALID_E,
    VIP_CHI_CHK_REQ_IDLE_IN_RESET_E,
    VIP_CHI_CHK_RSP_IDLE_IN_RESET_E,
    VIP_CHI_CHK_DAT_IDLE_IN_RESET_E,
    // X/Z rules. SV-only by design: Verilator is 2-state, so the Python port
    // cannot hold X and a mirror there could never fire.
    VIP_CHI_CHK_REQ_KNOWN_WHEN_VALID_E,
    VIP_CHI_CHK_RSP_KNOWN_WHEN_VALID_E,
    VIP_CHI_CHK_DAT_KNOWN_WHEN_VALID_E,
    // Link layer.
    VIP_CHI_CHK_LINK_SIDEBAND_IDLE_IN_RESET_E,
    VIP_CHI_CHK_LINK_RESTARTS_AFTER_RESET_E,
    VIP_CHI_CHK_LINK_DEACTIVATE_WHEN_IDLE_E,
    VIP_CHI_CHK_LASM_LEGAL_TRANSITION_E,
    VIP_CHI_CHK_LCRD_QUIESCENT_IN_STOP_E,
    VIP_CHI_CHK_LCRD_OVERFLOW_E,
    VIP_CHI_CHK_LCRD_UNDERFLOW_E,
    VIP_CHI_CHK_TXSACTIVE_COVERS_OUTSTANDING_E,
    VIP_CHI_CHK_TXSACTIVE_DEASSERT_BOUNDED_E,
    // Transaction layer.
    VIP_CHI_CHK_COMPLETION_FOLLOWS_REQ_E,
    VIP_CHI_CHK_ATOMIC_RETURN_USES_DAT_COMPLETION_E,
    VIP_CHI_CHK_ORDERED_READ_RECEIPT_BEFORE_DAT_E,
    VIP_CHI_CHK_TXNID_REUSE_REQUESTER_E,
    VIP_CHI_CHK_TXNID_REUSE_COMPLETER_E,
    VIP_CHI_CHK_WRITE_DAT_BEFORE_DBID_E,
    VIP_CHI_CHK_WRITE_DAT_TXNID_MATCHES_DBID_E,
    VIP_CHI_CHK_COMPACK_BEFORE_COMPLETION_E,
    VIP_CHI_CHK_COMPACK_WITHOUT_EXPCOMPACK_E,
    // DAT burst shape, tracked separately per direction.
    VIP_CHI_CHK_TX_DAT_FIRST_BEAT_DATAID_ZERO_E,
    VIP_CHI_CHK_RX_DAT_FIRST_BEAT_DATAID_ZERO_E,
    VIP_CHI_CHK_TX_DAT_DATAID_SEQUENTIAL_E,
    VIP_CHI_CHK_RX_DAT_DATAID_SEQUENTIAL_E,
    VIP_CHI_CHK_TX_DAT_TXNID_STABLE_E,
    VIP_CHI_CHK_RX_DAT_TXNID_STABLE_E,
    VIP_CHI_CHK_TX_WRITE_DAT_BEAT_COUNT_E,
    VIP_CHI_CHK_RX_WRITE_DAT_BEAT_COUNT_E,
    VIP_CHI_CHK_TX_READ_COMPLETION_DAT_OPCODE_E,
    VIP_CHI_CHK_RX_READ_COMPLETION_DAT_OPCODE_E,
    VIP_CHI_CHK_TX_READ_COMPLETION_DAT_BEAT_COUNT_E,
    VIP_CHI_CHK_RX_READ_COMPLETION_DAT_BEAT_COUNT_E,
    // SNP channel (vip_chi_snp_sva).
    VIP_CHI_CHK_SNP_FLITV_REQUIRES_LINK_E,
    VIP_CHI_CHK_SNP_LCRDV_REQUIRES_LINK_E,
    VIP_CHI_CHK_SNP_PEND_REQUIRES_VALID_E,
    VIP_CHI_CHK_SNP_KNOWN_WHEN_VALID_E,
    VIP_CHI_CHK_SNP_IDLE_IN_RESET_E,
    VIP_CHI_CHK_SNP_LCRD_OVERFLOW_E,
    VIP_CHI_CHK_SNP_LCRD_UNDERFLOW_E,
    // Link layer, appended. These belong with the link rules above and are down
    // here only because the order is append-only; putting them where they read
    // best would renumber the SNP block. They sit AFTER it deliberately, so
    // vip_chi_check_is_snp -- a range test, not a list -- still answers false for
    // them and vip_chi_sva keeps ownership.
    VIP_CHI_CHK_LASM_ACTIVATION_TIMEOUT_E,
    VIP_CHI_CHK_LASM_DEACTIVATION_TIMEOUT_E,
    // Must stay last: the array bound and the loop terminator.
    VIP_CHI_CHK_NUM_E
  } vip_chi_check_id_t;

  // Per-check severity. OFF still EVALUATES the rule and still counts its passes
  // and failures -- it only suppresses the report. That is deliberate: a check
  // turned off during bring-up should still show up in the end-of-test table as
  // failing, or "off" becomes indistinguishable from "fixed".
  typedef enum logic [1 : 0] {
    VIP_CHI_CHK_SEV_ERROR_E   = 2'd0,
    VIP_CHI_CHK_SEV_WARNING_E = 2'd1,
    VIP_CHI_CHK_SEV_OFF_E     = 2'd2
  } vip_chi_check_severity_t;

  // TRUE for the rules owned by vip_chi_snp_sva rather than vip_chi_sva. The two
  // binds share an interface, so each initialises and reports on only its own
  // range -- otherwise whichever elaborated second would clear the other's
  // plusarg settings, and the vacuity report would list the other's rules as
  // never exercised on every non-coherent run.
  function automatic bit vip_chi_check_is_snp(input vip_chi_check_id_t id);
    return (id >= VIP_CHI_CHK_SNP_FLITV_REQUIRES_LINK_E) &&
           (id <= VIP_CHI_CHK_SNP_LCRD_UNDERFLOW_E);
  endfunction

  // The rule's canonical name, shared with the Python checker verbatim.
  // Derived from the enum name rather than looked up in a parallel table, so a
  // new check cannot be added with a name that disagrees between the two ports.
  function automatic string vip_chi_check_name(input vip_chi_check_id_t id);
    string s;
    s = id.name();
    // Strip the "VIP_CHI_CHK_" prefix (12 chars) and the "_E" suffix (2).
    return {"CHI_", s.substr(12, s.len() - 3)};
  endfunction

  // ---------------------------------------------------------------------------
  // Scoreboard-check identity.
  //
  // The registry above covers the SVA binds only, and every scoreboard check
  // ever written here has been outside it: named nowhere, counted only when it
  // FAILED, and therefore invisible to the vacuity aggregation. A scoreboard
  // rule that never once evaluated reads, in every log and in the regression
  // summary, exactly like a rule that holds -- which is the state the whole
  // per-check mechanism exists to make impossible.
  //
  // A SECOND enum rather than more entries in the first, for a structural
  // reason: vip_chi_check_id_t sizes four fixed arrays inside EVERY vip_chi_if
  // instance, and a scoreboard rule is judged once per component, not per
  // interface. Putting them there would add rows to every interface in the
  // testbench that nothing could ever write. The two registries share the CSV
  // schema instead, which is what actually matters -- the aggregation reads both
  // through one code path and gates on both alike.
  //
  // Order is append-only for the same reason as the SVA registry: the names
  // appear in regression exports, and renumbering would silently repoint them.
  // ---------------------------------------------------------------------------
  typedef enum int {
    // Checker A -- lifecycle. Orphans are split by CHANNEL because they are
    // reached by different paths: an RSP arrives for a transaction the table
    // never opened, a DAT for one whose return leg was never registered.
    VIP_CHI_SB_CHK_TXN_COMPLETES_E = 0,
    VIP_CHI_SB_CHK_RSP_HAS_OPEN_TXN_E,
    VIP_CHI_SB_CHK_DAT_HAS_OPEN_TXN_E,
    VIP_CHI_SB_CHK_TXNID_NOT_REUSED_E,
    VIP_CHI_SB_CHK_COMPLETION_OPCODE_MODELLED_E,
    // Checker B -- cross-agent request fidelity.
    VIP_CHI_SB_CHK_REQ_RELAYED_E,
    VIP_CHI_SB_CHK_REQ_ROUTED_E,
    // Checker C -- data and MTE tag integrity. The read and atomic-return
    // compares shared one counter before this registry existed, so a regression
    // could not tell which of the two had actually run.
    VIP_CHI_SB_CHK_READ_DATA_MATCHES_E,
    VIP_CHI_SB_CHK_ATOMIC_RETURN_MATCHES_E,
    VIP_CHI_SB_CHK_READ_TAG_MATCHES_E,
    VIP_CHI_SB_CHK_READ_TAGOP_REPLAYED_E,
    VIP_CHI_SB_CHK_TAGOP_STABLE_ACROSS_BEATS_E,
    // Checker E -- ordered-stream acknowledgement order.
    VIP_CHI_SB_CHK_ORDERED_ACK_IN_ORDER_E,
    // Must stay last: the array bound and the loop terminator.
    VIP_CHI_SB_CHK_NUM_E
  } vip_chi_sb_check_id_t;

  // Same derivation as vip_chi_check_name, so the two ports cannot spell a rule
  // differently: strip "VIP_CHI_SB_CHK_" (15 chars) and "_E" (2), prepend the
  // CHI_SB_ namespace that separates these from the SVA rules in one CSV.
  function automatic string vip_chi_sb_check_name(input vip_chi_sb_check_id_t id);
    string s;
    s = id.name();
    return {"CHI_SB_", s.substr(15, s.len() - 3)};
  endfunction


  typedef enum logic [2 : 0] {
    VIP_CHI_RESP_STATE_I_E           = 3'b000,
    VIP_CHI_RESP_STATE_SC_E          = 3'b001,
    VIP_CHI_RESP_STATE_UC_E          = 3'b010,
    VIP_CHI_RESP_RESERVED_0_E        = 3'b011,
    VIP_CHI_RESP_RESERVED_1_E        = 3'b100,
    VIP_CHI_RESP_RESERVED_2_E        = 3'b101,
    VIP_CHI_RESP_STATE_UP_PD_DIRTY_E = 3'b110,
    VIP_CHI_RESP_STATE_SD_PD_DIRTY_E = 3'b111
  } vip_chi_resp_t;

  typedef enum logic [1 : 0] {
    VIP_CHI_RESP_ERR_NORMAL_OKAY_E    = 2'b00,
    VIP_CHI_RESP_ERR_EXCLUSIVE_OKAY_E = 2'b01,
    VIP_CHI_RESP_ERR_DATA_ERROR_E     = 2'b10,
    VIP_CHI_RESP_ERR_NONDATA_ERROR_E  = 2'b11
  } vip_chi_resp_err_t;

  typedef enum logic [VIP_CHI_MAX_REQ_OPCODE_WIDTH_C - 1 : 0] {
    VIP_CHI_REQ_READ_NO_SNP_E              = VIP_CHI_REQ_READ_NO_SNP_C,
    VIP_CHI_REQ_PCRD_RETURN_E              = VIP_CHI_REQ_PCRD_RETURN_C,
    VIP_CHI_REQ_READ_NO_SNP_SEP_E          = VIP_CHI_REQ_READ_NO_SNP_SEP_C,
    VIP_CHI_REQ_CLEAN_SHARED_PERSIST_SEP_E = VIP_CHI_REQ_CLEAN_SHARED_PERSIST_SEP_C,
    VIP_CHI_REQ_WRITE_NO_SNP_PTL_E         = VIP_CHI_REQ_WRITE_NO_SNP_PTL_C,
    VIP_CHI_REQ_WRITE_NO_SNP_FULL_E        = VIP_CHI_REQ_WRITE_NO_SNP_FULL_C,
    VIP_CHI_REQ_CLEAN_SHARED_PERSIST_E     = VIP_CHI_REQ_CLEAN_SHARED_PERSIST_C,
    VIP_CHI_REQ_ATOMIC_STORE_0_E           = VIP_CHI_REQ_ATOMIC_STORE_0_C,
    VIP_CHI_REQ_ATOMIC_STORE_1_E           = VIP_CHI_REQ_ATOMIC_STORE_1_C,
    VIP_CHI_REQ_ATOMIC_STORE_2_E           = VIP_CHI_REQ_ATOMIC_STORE_2_C,
    VIP_CHI_REQ_ATOMIC_STORE_3_E           = VIP_CHI_REQ_ATOMIC_STORE_3_C,
    VIP_CHI_REQ_ATOMIC_STORE_4_E           = VIP_CHI_REQ_ATOMIC_STORE_4_C,
    VIP_CHI_REQ_ATOMIC_STORE_5_E           = VIP_CHI_REQ_ATOMIC_STORE_5_C,
    VIP_CHI_REQ_ATOMIC_STORE_6_E           = VIP_CHI_REQ_ATOMIC_STORE_6_C,
    VIP_CHI_REQ_ATOMIC_STORE_7_E           = VIP_CHI_REQ_ATOMIC_STORE_7_C,
    VIP_CHI_REQ_ATOMIC_LOAD_0_E            = VIP_CHI_REQ_ATOMIC_LOAD_0_C,
    VIP_CHI_REQ_ATOMIC_LOAD_1_E            = VIP_CHI_REQ_ATOMIC_LOAD_1_C,
    VIP_CHI_REQ_ATOMIC_LOAD_2_E            = VIP_CHI_REQ_ATOMIC_LOAD_2_C,
    VIP_CHI_REQ_ATOMIC_LOAD_3_E            = VIP_CHI_REQ_ATOMIC_LOAD_3_C,
    VIP_CHI_REQ_ATOMIC_LOAD_4_E            = VIP_CHI_REQ_ATOMIC_LOAD_4_C,
    VIP_CHI_REQ_ATOMIC_LOAD_5_E            = VIP_CHI_REQ_ATOMIC_LOAD_5_C,
    VIP_CHI_REQ_ATOMIC_LOAD_6_E            = VIP_CHI_REQ_ATOMIC_LOAD_6_C,
    VIP_CHI_REQ_ATOMIC_LOAD_7_E            = VIP_CHI_REQ_ATOMIC_LOAD_7_C,
    VIP_CHI_REQ_ATOMIC_SWAP_E              = VIP_CHI_REQ_ATOMIC_SWAP_C,
    VIP_CHI_REQ_ATOMIC_COMPARE_E           = VIP_CHI_REQ_ATOMIC_COMPARE_C,
    VIP_CHI_REQ_PREFETCH_TGT_E             = VIP_CHI_REQ_PREFETCH_TGT_C,
    VIP_CHI_REQ_MAKE_READ_UNIQUE_E         = VIP_CHI_REQ_MAKE_READ_UNIQUE_C,
    VIP_CHI_REQ_WRITE_NO_SNP_ZERO_E        = VIP_CHI_REQ_WRITE_NO_SNP_ZERO_C,
    VIP_CHI_REQ_READ_SHARED_E              = VIP_CHI_REQ_READ_SHARED_C,
    VIP_CHI_REQ_READ_CLEAN_E               = VIP_CHI_REQ_READ_CLEAN_C,
    VIP_CHI_REQ_READ_UNIQUE_E              = VIP_CHI_REQ_READ_UNIQUE_C,
    VIP_CHI_REQ_CLEAN_SHARED_E             = VIP_CHI_REQ_CLEAN_SHARED_C,
    VIP_CHI_REQ_CLEAN_INVALID_E            = VIP_CHI_REQ_CLEAN_INVALID_C,
    VIP_CHI_REQ_MAKE_INVALID_E             = VIP_CHI_REQ_MAKE_INVALID_C,
    VIP_CHI_REQ_CLEAN_UNIQUE_E             = VIP_CHI_REQ_CLEAN_UNIQUE_C,
    VIP_CHI_REQ_MAKE_UNIQUE_E              = VIP_CHI_REQ_MAKE_UNIQUE_C,
    VIP_CHI_REQ_EVICT_E                    = VIP_CHI_REQ_EVICT_C,
    VIP_CHI_REQ_WRITE_CLEAN_FULL_E         = VIP_CHI_REQ_WRITE_CLEAN_FULL_C,
    VIP_CHI_REQ_WRITE_BACK_FULL_E          = VIP_CHI_REQ_WRITE_BACK_FULL_C,
    VIP_CHI_REQ_READ_ONCE_E                = VIP_CHI_REQ_READ_ONCE_C,
    VIP_CHI_REQ_WRITE_UNIQUE_PTL_E         = VIP_CHI_REQ_WRITE_UNIQUE_PTL_C,
    VIP_CHI_REQ_WRITE_UNIQUE_FULL_E        = VIP_CHI_REQ_WRITE_UNIQUE_FULL_C,
    // Combined Write + CMO (Issue E only).
    VIP_CHI_REQ_WRITE_NO_SNP_FULL_CLEAN_SH_E         = VIP_CHI_REQ_WRITE_NO_SNP_FULL_CLEAN_SH_C,
    VIP_CHI_REQ_WRITE_NO_SNP_FULL_CLEAN_INV_E        = VIP_CHI_REQ_WRITE_NO_SNP_FULL_CLEAN_INV_C,
    VIP_CHI_REQ_WRITE_NO_SNP_FULL_CLEAN_SH_PER_SEP_E = VIP_CHI_REQ_WRITE_NO_SNP_FULL_CLEAN_SH_PER_SEP_C,
    VIP_CHI_REQ_WRITE_NO_SNP_PTL_CLEAN_SH_E          = VIP_CHI_REQ_WRITE_NO_SNP_PTL_CLEAN_SH_C,
    VIP_CHI_REQ_WRITE_NO_SNP_PTL_CLEAN_INV_E         = VIP_CHI_REQ_WRITE_NO_SNP_PTL_CLEAN_INV_C,
    VIP_CHI_REQ_WRITE_NO_SNP_PTL_CLEAN_SH_PER_SEP_E  = VIP_CHI_REQ_WRITE_NO_SNP_PTL_CLEAN_SH_PER_SEP_C
  } vip_chi_req_opcode_t;

  // TRUE for the combined Write + CMO request opcodes (Issue E only).
  //
  // A function rather than a range test: the six are not contiguous -- the Full
  // forms are 0x50-0x52 and the Ptl forms 0x60-0x62 -- because Table 13-14 is
  // indexed by Opcode[5:0] with Opcode[6] selecting the column, so a family that
  // reads as one block in the table is two blocks in the encoding.
  function automatic bit vip_chi_req_opcode_is_combined_write_cmo(
    input vip_chi_req_opcode_t opcode
  );
    case (opcode)
      VIP_CHI_REQ_WRITE_NO_SNP_FULL_CLEAN_SH_E,
      VIP_CHI_REQ_WRITE_NO_SNP_FULL_CLEAN_INV_E,
      VIP_CHI_REQ_WRITE_NO_SNP_FULL_CLEAN_SH_PER_SEP_E,
      VIP_CHI_REQ_WRITE_NO_SNP_PTL_CLEAN_SH_E,
      VIP_CHI_REQ_WRITE_NO_SNP_PTL_CLEAN_INV_E,
      VIP_CHI_REQ_WRITE_NO_SNP_PTL_CLEAN_SH_PER_SEP_E: return 1'b1;
      default:                                         return 1'b0;
    endcase
  endfunction

  // TRUE when a combined Write + CMO carries a PERSISTENT CMO, whose Persist
  // response the completer must send only after the write data has arrived.
  function automatic bit vip_chi_req_opcode_combined_cmo_is_persist(
    input vip_chi_req_opcode_t opcode
  );
    return (opcode == VIP_CHI_REQ_WRITE_NO_SNP_FULL_CLEAN_SH_PER_SEP_E) ||
           (opcode == VIP_CHI_REQ_WRITE_NO_SNP_PTL_CLEAN_SH_PER_SEP_E);
  endfunction

  typedef enum logic [4 : 0] {
    VIP_CHI_ATOMIC_OP_STORE_0_E = 5'd0,
    VIP_CHI_ATOMIC_OP_STORE_1_E = 5'd1,
    VIP_CHI_ATOMIC_OP_STORE_2_E = 5'd2,
    VIP_CHI_ATOMIC_OP_STORE_3_E = 5'd3,
    VIP_CHI_ATOMIC_OP_STORE_4_E = 5'd4,
    VIP_CHI_ATOMIC_OP_STORE_5_E = 5'd5,
    VIP_CHI_ATOMIC_OP_STORE_6_E = 5'd6,
    VIP_CHI_ATOMIC_OP_STORE_7_E = 5'd7,
    VIP_CHI_ATOMIC_OP_LOAD_0_E  = 5'd8,
    VIP_CHI_ATOMIC_OP_LOAD_1_E  = 5'd9,
    VIP_CHI_ATOMIC_OP_LOAD_2_E  = 5'd10,
    VIP_CHI_ATOMIC_OP_LOAD_3_E  = 5'd11,
    VIP_CHI_ATOMIC_OP_LOAD_4_E  = 5'd12,
    VIP_CHI_ATOMIC_OP_LOAD_5_E  = 5'd13,
    VIP_CHI_ATOMIC_OP_LOAD_6_E  = 5'd14,
    VIP_CHI_ATOMIC_OP_LOAD_7_E  = 5'd15,
    VIP_CHI_ATOMIC_OP_SWAP_E    = 5'd16,
    VIP_CHI_ATOMIC_OP_COMPARE_E = 5'd17
  } vip_chi_atomic_op_t;

  typedef enum logic [VIP_CHI_MAX_RSP_OPCODE_WIDTH_C - 1 : 0] {
    VIP_CHI_RSP_COMP_ACK_E       = VIP_CHI_RSP_COMP_ACK_C,
    VIP_CHI_RSP_RETRY_ACK_E      = VIP_CHI_RSP_RETRY_ACK_C,
    VIP_CHI_RSP_COMP_E           = VIP_CHI_RSP_COMP_C,
    VIP_CHI_RSP_COMP_DBID_RESP_E = VIP_CHI_RSP_COMP_DBID_RESP_C,
    VIP_CHI_RSP_DBID_RESP_E      = VIP_CHI_RSP_DBID_RESP_C,
    VIP_CHI_RSP_PCRD_GRANT_E     = VIP_CHI_RSP_PCRD_GRANT_C,
    VIP_CHI_RSP_READ_RECEIPT_E   = VIP_CHI_RSP_READ_RECEIPT_C,
    VIP_CHI_RSP_RESP_SEP_DATA_E  = VIP_CHI_RSP_RESP_SEP_DATA_C,
    VIP_CHI_RSP_PERSIST_E        = VIP_CHI_RSP_PERSIST_C,
    VIP_CHI_RSP_COMP_PERSIST_E   = VIP_CHI_RSP_COMP_PERSIST_C,
    VIP_CHI_RSP_DBID_RESP_ORD_E  = VIP_CHI_RSP_DBID_RESP_ORD_C,
    VIP_CHI_RSP_COMP_CMO_E       = VIP_CHI_RSP_COMP_CMO_C,
    VIP_CHI_RSP_SNP_RESP_E       = VIP_CHI_RSP_SNP_RESP_C,
    VIP_CHI_RSP_SNP_RESP_FWDED_E = VIP_CHI_RSP_SNP_RESP_FWDED_C
  } vip_chi_rsp_opcode_t;

  typedef enum logic [VIP_CHI_MAX_DAT_OPCODE_WIDTH_C - 1 : 0] {
    VIP_CHI_DAT_NON_COPY_BACK_WR_DATA_E = VIP_CHI_DAT_NON_COPY_BACK_WR_DATA_C,
    VIP_CHI_DAT_COMP_DATA_E             = VIP_CHI_DAT_COMP_DATA_C,
    VIP_CHI_DAT_DATA_SEP_RESP_E         = VIP_CHI_DAT_DATA_SEP_RESP_C,
    VIP_CHI_DAT_NCB_WR_DATA_COMP_ACK_E  = VIP_CHI_DAT_NCB_WR_DATA_COMP_ACK_C,
    VIP_CHI_DAT_SNP_RESP_DATA_E         = VIP_CHI_DAT_SNP_RESP_DATA_C,
    VIP_CHI_DAT_COPY_BACK_WR_DATA_E     = VIP_CHI_DAT_COPY_BACK_WR_DATA_C,
    VIP_CHI_DAT_SNP_RESP_DATA_PTL_E     = VIP_CHI_DAT_SNP_RESP_DATA_PTL_C,
    VIP_CHI_DAT_SNP_RESP_DATA_FWDED_E   = VIP_CHI_DAT_SNP_RESP_DATA_FWDED_C
  } vip_chi_dat_opcode_t;

  typedef enum logic [VIP_CHI_MAX_SNP_OPCODE_WIDTH_C - 1 : 0] {
    VIP_CHI_SNP_SHARED_E               = VIP_CHI_SNP_SHARED_C,
    VIP_CHI_SNP_CLEAN_E                = VIP_CHI_SNP_CLEAN_C,
    VIP_CHI_SNP_ONCE_E                 = VIP_CHI_SNP_ONCE_C,
    VIP_CHI_SNP_UNIQUE_E               = VIP_CHI_SNP_UNIQUE_C,
    VIP_CHI_SNP_CLEAN_SHARED_E         = VIP_CHI_SNP_CLEAN_SHARED_C,
    VIP_CHI_SNP_CLEAN_INVALID_E        = VIP_CHI_SNP_CLEAN_INVALID_C,
    VIP_CHI_SNP_MAKE_INVALID_E         = VIP_CHI_SNP_MAKE_INVALID_C,
    VIP_CHI_SNP_SHARED_FWD_E           = VIP_CHI_SNP_SHARED_FWD_C,
    VIP_CHI_SNP_CLEAN_FWD_E            = VIP_CHI_SNP_CLEAN_FWD_C,
    VIP_CHI_SNP_ONCE_FWD_E             = VIP_CHI_SNP_ONCE_FWD_C,
    VIP_CHI_SNP_NOT_SHARED_DIRTY_FWD_E = VIP_CHI_SNP_NOT_SHARED_DIRTY_FWD_C,
    VIP_CHI_SNP_UNIQUE_FWD_E           = VIP_CHI_SNP_UNIQUE_FWD_C
  } vip_chi_snp_opcode_t;

  typedef struct packed {
    logic [VIP_CHI_MAX_ADDR_WIDTH_C - 1 : 0] base;
    logic [VIP_CHI_MAX_ADDR_WIDTH_C - 1 : 0] limit;
  } vip_chi_decerr_range_t;

  typedef struct packed {
    logic [VIP_CHI_MAX_ADDR_WIDTH_C - 1 : 0] base;
    logic [VIP_CHI_MAX_ADDR_WIDTH_C - 1 : 0] limit;
  } vip_chi_derr_range_t;

  // ---------------------------------------------------------------------------
  // Return TRUE when the cfg selects CHI-D.
  // ---------------------------------------------------------------------------
  function automatic bit vip_chi_is_issue_d(input vip_chi_cfg_t cfg);
    return (cfg.ISSUE_P == VIP_CHI_ISSUE_D_E);
  endfunction

  // ---------------------------------------------------------------------------
  // Return TRUE when the cfg selects CHI-E.
  // ---------------------------------------------------------------------------
  function automatic bit vip_chi_is_issue_e(input vip_chi_cfg_t cfg);
    return (cfg.ISSUE_P == VIP_CHI_ISSUE_E_E);
  endfunction

  // ---------------------------------------------------------------------------
  // Return TRUE when the REQ opcode is one of the supported atomic variants.
  // ---------------------------------------------------------------------------
  function automatic bit vip_chi_req_opcode_is_atomic(input vip_chi_req_opcode_t opcode);
    case (opcode)
      VIP_CHI_REQ_ATOMIC_STORE_0_E,
      VIP_CHI_REQ_ATOMIC_STORE_1_E,
      VIP_CHI_REQ_ATOMIC_STORE_2_E,
      VIP_CHI_REQ_ATOMIC_STORE_3_E,
      VIP_CHI_REQ_ATOMIC_STORE_4_E,
      VIP_CHI_REQ_ATOMIC_STORE_5_E,
      VIP_CHI_REQ_ATOMIC_STORE_6_E,
      VIP_CHI_REQ_ATOMIC_STORE_7_E,
      VIP_CHI_REQ_ATOMIC_LOAD_0_E,
      VIP_CHI_REQ_ATOMIC_LOAD_1_E,
      VIP_CHI_REQ_ATOMIC_LOAD_2_E,
      VIP_CHI_REQ_ATOMIC_LOAD_3_E,
      VIP_CHI_REQ_ATOMIC_LOAD_4_E,
      VIP_CHI_REQ_ATOMIC_LOAD_5_E,
      VIP_CHI_REQ_ATOMIC_LOAD_6_E,
      VIP_CHI_REQ_ATOMIC_LOAD_7_E,
      VIP_CHI_REQ_ATOMIC_SWAP_E,
      VIP_CHI_REQ_ATOMIC_COMPARE_E: begin
        return 1'b1;
      end
      default: begin
        return 1'b0;
      end
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // Return TRUE when the atomic request completes with CompData.
  // ---------------------------------------------------------------------------
  function automatic bit vip_chi_req_opcode_is_atomic_returning_data(input vip_chi_req_opcode_t opcode);
    case (opcode)
      VIP_CHI_REQ_ATOMIC_LOAD_0_E,
      VIP_CHI_REQ_ATOMIC_LOAD_1_E,
      VIP_CHI_REQ_ATOMIC_LOAD_2_E,
      VIP_CHI_REQ_ATOMIC_LOAD_3_E,
      VIP_CHI_REQ_ATOMIC_LOAD_4_E,
      VIP_CHI_REQ_ATOMIC_LOAD_5_E,
      VIP_CHI_REQ_ATOMIC_LOAD_6_E,
      VIP_CHI_REQ_ATOMIC_LOAD_7_E,
      VIP_CHI_REQ_ATOMIC_SWAP_E,
      VIP_CHI_REQ_ATOMIC_COMPARE_E: begin
        return 1'b1;
      end
      default: begin
        return 1'b0;
      end
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // Return TRUE when the atomic request is AtomicCompare.
  // ---------------------------------------------------------------------------
  function automatic bit vip_chi_req_opcode_is_atomic_compare(input vip_chi_req_opcode_t opcode);
    return (opcode == VIP_CHI_REQ_ATOMIC_COMPARE_E);
  endfunction

  // ---------------------------------------------------------------------------
  // Return TRUE when the atomic request is a store-style completion-only op.
  // ---------------------------------------------------------------------------
  function automatic bit vip_chi_req_opcode_is_atomic_store(input vip_chi_req_opcode_t opcode);
    case (opcode)
      VIP_CHI_REQ_ATOMIC_STORE_0_E,
      VIP_CHI_REQ_ATOMIC_STORE_1_E,
      VIP_CHI_REQ_ATOMIC_STORE_2_E,
      VIP_CHI_REQ_ATOMIC_STORE_3_E,
      VIP_CHI_REQ_ATOMIC_STORE_4_E,
      VIP_CHI_REQ_ATOMIC_STORE_5_E,
      VIP_CHI_REQ_ATOMIC_STORE_6_E,
      VIP_CHI_REQ_ATOMIC_STORE_7_E: begin
        return 1'b1;
      end
      default: begin
        return 1'b0;
      end
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // Return the [0:7] arithmetic variant encoded by AtomicStore/Load opcodes.
  // Non-variant opcodes return -1.
  // ---------------------------------------------------------------------------
  function automatic int vip_chi_req_opcode_atomic_variant(input vip_chi_req_opcode_t opcode);
    case (opcode)
      VIP_CHI_REQ_ATOMIC_STORE_0_E,
      VIP_CHI_REQ_ATOMIC_LOAD_0_E: return 0;
      VIP_CHI_REQ_ATOMIC_STORE_1_E,
      VIP_CHI_REQ_ATOMIC_LOAD_1_E: return 1;
      VIP_CHI_REQ_ATOMIC_STORE_2_E,
      VIP_CHI_REQ_ATOMIC_LOAD_2_E: return 2;
      VIP_CHI_REQ_ATOMIC_STORE_3_E,
      VIP_CHI_REQ_ATOMIC_LOAD_3_E: return 3;
      VIP_CHI_REQ_ATOMIC_STORE_4_E,
      VIP_CHI_REQ_ATOMIC_LOAD_4_E: return 4;
      VIP_CHI_REQ_ATOMIC_STORE_5_E,
      VIP_CHI_REQ_ATOMIC_LOAD_5_E: return 5;
      VIP_CHI_REQ_ATOMIC_STORE_6_E,
      VIP_CHI_REQ_ATOMIC_LOAD_6_E: return 6;
      VIP_CHI_REQ_ATOMIC_STORE_7_E,
      VIP_CHI_REQ_ATOMIC_LOAD_7_E: return 7;
      default: return -1;
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // Map one sequence-visible atomic selector onto the concrete REQ opcode.
  // ---------------------------------------------------------------------------
  function automatic vip_chi_req_opcode_t vip_chi_atomic_op_to_req_opcode(input vip_chi_atomic_op_t op);
    case (op)
      VIP_CHI_ATOMIC_OP_STORE_0_E: return VIP_CHI_REQ_ATOMIC_STORE_0_E;
      VIP_CHI_ATOMIC_OP_STORE_1_E: return VIP_CHI_REQ_ATOMIC_STORE_1_E;
      VIP_CHI_ATOMIC_OP_STORE_2_E: return VIP_CHI_REQ_ATOMIC_STORE_2_E;
      VIP_CHI_ATOMIC_OP_STORE_3_E: return VIP_CHI_REQ_ATOMIC_STORE_3_E;
      VIP_CHI_ATOMIC_OP_STORE_4_E: return VIP_CHI_REQ_ATOMIC_STORE_4_E;
      VIP_CHI_ATOMIC_OP_STORE_5_E: return VIP_CHI_REQ_ATOMIC_STORE_5_E;
      VIP_CHI_ATOMIC_OP_STORE_6_E: return VIP_CHI_REQ_ATOMIC_STORE_6_E;
      VIP_CHI_ATOMIC_OP_STORE_7_E: return VIP_CHI_REQ_ATOMIC_STORE_7_E;
      VIP_CHI_ATOMIC_OP_LOAD_0_E:  return VIP_CHI_REQ_ATOMIC_LOAD_0_E;
      VIP_CHI_ATOMIC_OP_LOAD_1_E:  return VIP_CHI_REQ_ATOMIC_LOAD_1_E;
      VIP_CHI_ATOMIC_OP_LOAD_2_E:  return VIP_CHI_REQ_ATOMIC_LOAD_2_E;
      VIP_CHI_ATOMIC_OP_LOAD_3_E:  return VIP_CHI_REQ_ATOMIC_LOAD_3_E;
      VIP_CHI_ATOMIC_OP_LOAD_4_E:  return VIP_CHI_REQ_ATOMIC_LOAD_4_E;
      VIP_CHI_ATOMIC_OP_LOAD_5_E:  return VIP_CHI_REQ_ATOMIC_LOAD_5_E;
      VIP_CHI_ATOMIC_OP_LOAD_6_E:  return VIP_CHI_REQ_ATOMIC_LOAD_6_E;
      VIP_CHI_ATOMIC_OP_LOAD_7_E:  return VIP_CHI_REQ_ATOMIC_LOAD_7_E;
      VIP_CHI_ATOMIC_OP_SWAP_E:    return VIP_CHI_REQ_ATOMIC_SWAP_E;
      VIP_CHI_ATOMIC_OP_COMPARE_E: return VIP_CHI_REQ_ATOMIC_COMPARE_E;
      default:                     return vip_chi_req_opcode_t'('0);
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // Return the TxnID width for the selected CHI issue.
  // ---------------------------------------------------------------------------
  function automatic int chi_txn_id_width(input vip_chi_issue_t issue);
    case (issue)
      VIP_CHI_ISSUE_D_E: return 10;
      VIP_CHI_ISSUE_E_E: return 12;
      default:           return 0;
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // Return the REQ opcode width for the selected CHI issue.
  // ---------------------------------------------------------------------------
  function automatic int chi_req_opcode_width(input vip_chi_issue_t issue);
    case (issue)
      VIP_CHI_ISSUE_D_E: return 6;
      VIP_CHI_ISSUE_E_E: return 7;
      default:           return 0;
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // Return the RSP opcode width for the selected CHI issue.
  // ---------------------------------------------------------------------------
  function automatic int chi_rsp_opcode_width(input vip_chi_issue_t issue);
    case (issue)
      VIP_CHI_ISSUE_D_E: return 4;
      VIP_CHI_ISSUE_E_E: return 5;
      default:           return 0;
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // Return the DAT opcode width for the selected CHI issue.
  // ---------------------------------------------------------------------------
  function automatic int chi_dat_opcode_width(input vip_chi_issue_t issue);
    case (issue)
      VIP_CHI_ISSUE_D_E,
      VIP_CHI_ISSUE_E_E: return 4;
      default:           return 0;
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // Return the SNP opcode width for the selected CHI issue (5 bits both issues).
  // ---------------------------------------------------------------------------
  function automatic int chi_snp_opcode_width(input vip_chi_issue_t issue);
    case (issue)
      VIP_CHI_ISSUE_D_E,
      VIP_CHI_ISSUE_E_E: return 5;
      default:           return 0;
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // Return the LPID width for the selected CHI issue.
  // ---------------------------------------------------------------------------
  function automatic int chi_lpid_width(input vip_chi_issue_t issue);
    case (issue)
      VIP_CHI_ISSUE_D_E: return 5;
      VIP_CHI_ISSUE_E_E: return 8;
      default:           return 0;
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // Return the poison field width for one DAT beat.
  // ---------------------------------------------------------------------------
  function automatic int chi_poison_width(input int data_bytes);
    if (data_bytes <= 0) begin
      return 1;
    end
    return ((data_bytes + 7) / 8);
  endfunction

  // ---------------------------------------------------------------------------
  // Return the datacheck field width for one DAT beat.
  // ---------------------------------------------------------------------------
  function automatic int chi_datacheck_width(input int data_bytes);
    if (data_bytes <= 0) begin
      return 1;
    end
    return data_bytes;
  endfunction

  // ---------------------------------------------------------------------------
  // Return the byte-enable width for one DAT beat.
  // ---------------------------------------------------------------------------
  function automatic int chi_be_width(input int data_bytes);
    if (data_bytes <= 0) begin
      return 1;
    end
    return data_bytes;
  endfunction

  // ---------------------------------------------------------------------------
  // Return the maximum number of DAT beats in one cache line.
  // ---------------------------------------------------------------------------
  function automatic int chi_num_dat_beats(input int data_bytes);
    if (data_bytes <= 0) begin
      return 0;
    end
    return (VIP_CHI_CACHE_LINE_BYTES_C / data_bytes);
  endfunction

  // ---------------------------------------------------------------------------
  // Return the DataID / CCID width derived from the max beat count.
  // ---------------------------------------------------------------------------
  function automatic int chi_data_id_width(input int data_bytes);
    int beats;

    beats = chi_num_dat_beats(data_bytes);
    if (beats <= 1) begin
      return 1;
    end
    return $clog2(beats);
  endfunction

  // ---------------------------------------------------------------------------
  // Convert the CHI Size encoding into a transfer size in bytes.
  // ---------------------------------------------------------------------------
  function automatic int chi_size_bytes(
    input logic [VIP_CHI_REQ_SIZE_WIDTH_C - 1 : 0] size
  );
    return (1 << size);
  endfunction

  // ---------------------------------------------------------------------------
  // Return the DAT beat count needed for one transfer.
  // ---------------------------------------------------------------------------
  function automatic int chi_xfer_dat_beats(
    input logic [VIP_CHI_REQ_SIZE_WIDTH_C - 1 : 0] size,
    input int                                      data_bytes
  );
    int size_bytes;

    if (data_bytes <= 0) begin
      return 0;
    end

    size_bytes = chi_size_bytes(size);
    if (size_bytes <= data_bytes) begin
      return 1;
    end
    return ((size_bytes + data_bytes - 1) / data_bytes);
  endfunction

  // ---------------------------------------------------------------------------
  // Return the CHI-E DAT Tag field width for one DAT beat.
  // ---------------------------------------------------------------------------
  function automatic int chi_dat_tag_width(input int data_bytes);
    int width;

    width = ((8 * data_bytes) / 32);
    if (width <= 0) begin
      return 1;
    end
    return width;
  endfunction

  // ---------------------------------------------------------------------------
  // Return the CHI-E DAT TU field width for one DAT beat.
  // ---------------------------------------------------------------------------
  function automatic int chi_dat_tu_width(input int data_bytes);
    int width;

    width = ((8 * data_bytes) / 128);
    if (width <= 0) begin
      return 1;
    end
    return width;
  endfunction

  class vip_chi_types #(
    vip_chi_cfg_t CFG_P = VIP_CHI_DEFAULT_CFG_C
  );

    localparam int NODE_ID_WIDTH_C    = CFG_P.NODE_ID_WIDTH_P;
    localparam int ADDR_WIDTH_C       = CFG_P.ADDR_WIDTH_P;
    localparam int DATA_BYTES_C       = CFG_P.DATA_BYTES_P;
    localparam int TXN_ID_WIDTH_C     = chi_txn_id_width(CFG_P.ISSUE_P);
    localparam int REQ_OPCODE_WIDTH_C = chi_req_opcode_width(CFG_P.ISSUE_P);
    localparam int RSP_OPCODE_WIDTH_C = chi_rsp_opcode_width(CFG_P.ISSUE_P);
    localparam int DAT_OPCODE_WIDTH_C = chi_dat_opcode_width(CFG_P.ISSUE_P);
    localparam int SNP_OPCODE_WIDTH_C = chi_snp_opcode_width(CFG_P.ISSUE_P);
    localparam int LPID_WIDTH_C       = chi_lpid_width(CFG_P.ISSUE_P);
    localparam bit ISSUE_E_C          = (CFG_P.ISSUE_P == VIP_CHI_ISSUE_E_E);
    localparam int DATA_ID_WIDTH_C    = chi_data_id_width(CFG_P.DATA_BYTES_P);
    localparam int DATACHECK_WIDTH_C  = chi_datacheck_width(CFG_P.DATA_BYTES_P);
    localparam int POISON_WIDTH_C     = chi_poison_width(CFG_P.DATA_BYTES_P);
    localparam int TAG_WIDTH_C        = chi_dat_tag_width(CFG_P.DATA_BYTES_P);
    localparam int TU_WIDTH_C         = chi_dat_tu_width(CFG_P.DATA_BYTES_P);

    // These names are local to the vip_chi_types #() class scope and are reached
    // only via scope resolution (e.g. vip_chi_item#(CFG_P)::addr_t). Class-scoped
    // members never enter a package/global namespace -- not even through `import`
    // -- so the short, unprefixed names cannot collide with RTL types elsewhere.
    typedef logic                                  [NODE_ID_WIDTH_C - 1 : 0] node_id_t;
    typedef logic                                     [ADDR_WIDTH_C - 1 : 0] addr_t;
    typedef logic                               [(8 * DATA_BYTES_C) - 1 : 0] data_t;
    typedef logic                       [chi_be_width(DATA_BYTES_C) - 1 : 0] be_t;
    typedef logic                                   [TXN_ID_WIDTH_C - 1 : 0] txn_id_t;
    typedef logic                               [REQ_OPCODE_WIDTH_C - 1 : 0] req_opcode_t;
    typedef logic                               [RSP_OPCODE_WIDTH_C - 1 : 0] rsp_opcode_t;
    typedef logic                               [DAT_OPCODE_WIDTH_C - 1 : 0] dat_opcode_t;
    typedef logic                               [SNP_OPCODE_WIDTH_C - 1 : 0] snp_opcode_t;
    typedef logic                                     [LPID_WIDTH_C - 1 : 0] lpid_t;
    typedef logic                         [VIP_CHI_REQ_SIZE_WIDTH_C - 1 : 0] size_t;
    typedef logic          [(ISSUE_E_C ? VIP_CHI_TAGOP_WIDTH_C : 1) - 1 : 0] tagop_t;
    typedef logic   [(ISSUE_E_C ? VIP_CHI_GROUP_ID_EXT_WIDTH_C : 1) - 1 : 0] groupidext_t;
    typedef logic                    [(ISSUE_E_C ? TAG_WIDTH_C : 1) - 1 : 0] tag_t;
    typedef logic                     [(ISSUE_E_C ? TU_WIDTH_C : 1) - 1 : 0] tu_t;
    typedef logic                                  [DATA_ID_WIDTH_C - 1 : 0] data_id_t;
    typedef logic                                  [DATA_ID_WIDTH_C - 1 : 0] cc_id_t;
    typedef logic [((CFG_P.DATACHECK_EN_P) ? DATACHECK_WIDTH_C : 1) - 1 : 0] datacheck_t;
    typedef logic       [((CFG_P.POISON_EN_P) ? POISON_WIDTH_C : 1) - 1 : 0] poison_t;
    typedef logic   [((CFG_P.MPAM_EN_P) ? VIP_CHI_MPAM_WIDTH_C : 1) - 1 : 0] mpam_t;

    // packed: this struct models a CHI wire flit beat, so a deterministic bit
    // layout is intentional (and all members are integral, so packed is valid).
    typedef struct packed {
      mpam_t              mpam;
      logic               tracetag;
      tagop_t             tagop;
      logic               expcompack;
      vip_chi_exclusive_t excl;
      groupidext_t        groupidext;
      lpid_t              lpid;
      logic               dodwt;
      logic [3 : 0]       memattr;
      vip_chi_pcrd_type_t pcrdtype;
      vip_chi_req_order_t order;
      logic               allowretry;
      logic               likelyshared;
      vip_chi_req_ns_t    ns;
      addr_t              addr;
      size_t              size;
      req_opcode_t        opcode;
      txn_id_t            returntxnid;
      logic               endian;
      node_id_t           returnnid;
      txn_id_t            txnid;
      node_id_t           srcid;
      node_id_t           tgtid;
      vip_chi_qos_t       qos;
    } vip_chi_req_flit_t;

    typedef vip_chi_req_flit_t req_flit_t;

    typedef struct packed {
      logic               tracetag;
      tagop_t             tagop;
      vip_chi_pcrd_type_t pcrdtype;
      txn_id_t            dbid;
      logic [2 : 0]       cbusy;
      logic [2 : 0]       fwdstate;
      vip_chi_resp_t      resp;
      vip_chi_resp_err_t  resperr;
      rsp_opcode_t        opcode;
      txn_id_t            txnid;
      node_id_t           srcid;
      node_id_t           tgtid;
      vip_chi_qos_t       qos;
    } vip_chi_rsp_flit_t;

    // TODO: These two types appear uselessly redundant. Remove them?
    typedef vip_chi_rsp_flit_t vip_chi_resp_flit_t;
    typedef vip_chi_rsp_flit_t rsp_flit_t;

    typedef struct packed {
      poison_t           poison;
      datacheck_t        datacheck;
      data_t             data;
      be_t               be;
      logic              tracetag;
      tu_t               tu;
      tag_t              tag;
      tagop_t            tagop;
      data_id_t          dataid;
      cc_id_t            ccid;
      txn_id_t           dbid;
      logic [2 : 0]      cbusy;
      logic [3 : 0]      datasource;
      vip_chi_resp_t     resp;
      vip_chi_resp_err_t resperr;
      dat_opcode_t       opcode;
      node_id_t          homenid;
      txn_id_t           txnid;
      node_id_t          srcid;
      node_id_t          tgtid;
      vip_chi_qos_t       qos;
    } vip_chi_dat_flit_t;

    typedef vip_chi_dat_flit_t vip_chi_data_flit_t;
    typedef vip_chi_dat_flit_t dat_flit_t;

    // Snoop-request (SNP channel) flit. Home -> RN-F direction; carries no data,
    // BE, tag, or DBID (data returns on DAT as SnpRespData, response on RSP).
    typedef struct packed {
      logic            tracetag;
      logic            donotdatapull;
      logic            rettosrc;
      snp_opcode_t     opcode;
      addr_t           addr;
      vip_chi_req_ns_t ns;
      txn_id_t         fwdtxnid;
      node_id_t        fwdnid;
      txn_id_t         txnid;
      node_id_t        srcid;
      vip_chi_qos_t       qos;
    } vip_chi_snp_flit_t;

    typedef vip_chi_snp_flit_t snp_flit_t;
  endclass

  // ---------------------------------------------------------------------------
  // Exact wire-level CHI-D flit shapes. These remove CHI-E-only fields at the
  // interface boundary while reusing the common scalar width derivation.
  // ---------------------------------------------------------------------------
  class vip_chi_types_d #(
    vip_chi_cfg_t CFG_P = VIP_CHI_DEFAULT_CFG_C
  );

    typedef vip_chi_types #(CFG_P)::node_id_t    node_id_t;
    typedef vip_chi_types #(CFG_P)::addr_t       addr_t;
    typedef vip_chi_types #(CFG_P)::data_t       data_t;
    typedef vip_chi_types #(CFG_P)::be_t         be_t;
    typedef vip_chi_types #(CFG_P)::txn_id_t     txn_id_t;
    typedef vip_chi_types #(CFG_P)::req_opcode_t req_opcode_t;
    typedef vip_chi_types #(CFG_P)::rsp_opcode_t rsp_opcode_t;
    typedef vip_chi_types #(CFG_P)::dat_opcode_t dat_opcode_t;
    typedef vip_chi_types #(CFG_P)::lpid_t       lpid_t;
    typedef vip_chi_types #(CFG_P)::size_t       size_t;
    typedef vip_chi_types #(CFG_P)::data_id_t    data_id_t;
    typedef vip_chi_types #(CFG_P)::cc_id_t      cc_id_t;
    typedef vip_chi_types #(CFG_P)::datacheck_t  datacheck_t;
    typedef vip_chi_types #(CFG_P)::poison_t     poison_t;
    typedef vip_chi_types #(CFG_P)::mpam_t       mpam_t;

    typedef struct packed {
      mpam_t              mpam;
      logic               tracetag;
      logic               expcompack;
      vip_chi_exclusive_t excl;
      lpid_t              lpid;
      logic               dodwt;
      logic [3 : 0]       memattr;
      vip_chi_pcrd_type_t pcrdtype;
      vip_chi_req_order_t order;
      logic               allowretry;
      logic               likelyshared;
      vip_chi_req_ns_t    ns;
      addr_t              addr;
      size_t              size;
      req_opcode_t        opcode;
      txn_id_t            returntxnid;
      logic               endian;
      node_id_t           returnnid;
      txn_id_t            txnid;
      node_id_t           srcid;
      node_id_t           tgtid;
      vip_chi_qos_t       qos;
    } vip_chi_req_flit_t;

    typedef vip_chi_req_flit_t req_flit_t;

    typedef struct packed {
      logic               tracetag;
      vip_chi_pcrd_type_t pcrdtype;
      txn_id_t            dbid;
      logic [2 : 0]       cbusy;
      logic [2 : 0]       fwdstate;
      vip_chi_resp_t      resp;
      vip_chi_resp_err_t  resperr;
      rsp_opcode_t        opcode;
      txn_id_t            txnid;
      node_id_t           srcid;
      node_id_t           tgtid;
      vip_chi_qos_t       qos;
    } vip_chi_rsp_flit_t;

    typedef vip_chi_rsp_flit_t vip_chi_resp_flit_t;
    typedef vip_chi_rsp_flit_t rsp_flit_t;

    typedef struct packed {
      poison_t           poison;
      datacheck_t        datacheck;
      data_t             data;
      be_t               be;
      logic              tracetag;
      data_id_t          dataid;
      cc_id_t            ccid;
      txn_id_t           dbid;
      logic [2 : 0]      cbusy;
      logic [3 : 0]      datasource;
      vip_chi_resp_t     resp;
      vip_chi_resp_err_t resperr;
      dat_opcode_t       opcode;
      node_id_t          homenid;
      txn_id_t           txnid;
      node_id_t          srcid;
      node_id_t          tgtid;
      vip_chi_qos_t       qos;
    } vip_chi_dat_flit_t;

    typedef vip_chi_dat_flit_t vip_chi_data_flit_t;
    typedef vip_chi_dat_flit_t dat_flit_t;

    typedef vip_chi_types #(CFG_P)::snp_opcode_t snp_opcode_t;
    typedef struct packed {
      logic            tracetag;
      logic            donotdatapull;
      logic            rettosrc;
      snp_opcode_t     opcode;
      addr_t           addr;
      vip_chi_req_ns_t ns;
      txn_id_t         fwdtxnid;
      node_id_t        fwdnid;
      txn_id_t         txnid;
      node_id_t        srcid;
      vip_chi_qos_t       qos;
    } vip_chi_snp_flit_t;

    typedef vip_chi_snp_flit_t snp_flit_t;
  endclass

  // ---------------------------------------------------------------------------
  // Exact wire-level CHI-E flit shapes. These preserve the E-only TagOp /
  // GroupIDExt / Tag / TU fields at the interface boundary.
  // ---------------------------------------------------------------------------
  class vip_chi_types_e #(
    vip_chi_cfg_t CFG_P = VIP_CHI_DEFAULT_CFG_C
  );

    typedef vip_chi_types #(CFG_P)::node_id_t    node_id_t;
    typedef vip_chi_types #(CFG_P)::addr_t       addr_t;
    typedef vip_chi_types #(CFG_P)::data_t       data_t;
    typedef vip_chi_types #(CFG_P)::be_t         be_t;
    typedef vip_chi_types #(CFG_P)::txn_id_t     txn_id_t;
    typedef vip_chi_types #(CFG_P)::req_opcode_t req_opcode_t;
    typedef vip_chi_types #(CFG_P)::rsp_opcode_t rsp_opcode_t;
    typedef vip_chi_types #(CFG_P)::dat_opcode_t dat_opcode_t;
    typedef vip_chi_types #(CFG_P)::lpid_t       lpid_t;
    typedef vip_chi_types #(CFG_P)::size_t       size_t;
    typedef vip_chi_types #(CFG_P)::tagop_t      tagop_t;
    typedef vip_chi_types #(CFG_P)::groupidext_t groupidext_t;
    typedef vip_chi_types #(CFG_P)::tag_t        tag_t;
    typedef vip_chi_types #(CFG_P)::tu_t         tu_t;
    typedef vip_chi_types #(CFG_P)::data_id_t    data_id_t;
    typedef vip_chi_types #(CFG_P)::cc_id_t      cc_id_t;
    typedef vip_chi_types #(CFG_P)::datacheck_t  datacheck_t;
    typedef vip_chi_types #(CFG_P)::poison_t     poison_t;
    typedef vip_chi_types #(CFG_P)::mpam_t       mpam_t;

    typedef struct packed {
      mpam_t              mpam;
      logic               tracetag;
      tagop_t             tagop;
      logic               expcompack;
      vip_chi_exclusive_t excl;
      groupidext_t        groupidext;
      lpid_t              lpid;
      logic               dodwt;
      logic [3 : 0]       memattr;
      vip_chi_pcrd_type_t pcrdtype;
      vip_chi_req_order_t order;
      logic               allowretry;
      logic               likelyshared;
      vip_chi_req_ns_t    ns;
      addr_t              addr;
      size_t              size;
      req_opcode_t        opcode;
      txn_id_t            returntxnid;
      logic               endian;
      node_id_t           returnnid;
      txn_id_t            txnid;
      node_id_t           srcid;
      node_id_t           tgtid;
      vip_chi_qos_t       qos;
    } vip_chi_req_flit_t;

    typedef vip_chi_req_flit_t req_flit_t;

    typedef struct packed {
      logic               tracetag;
      tagop_t             tagop;
      vip_chi_pcrd_type_t pcrdtype;
      txn_id_t            dbid;
      logic [2 : 0]       cbusy;
      logic [2 : 0]       fwdstate;
      vip_chi_resp_t      resp;
      vip_chi_resp_err_t  resperr;
      rsp_opcode_t        opcode;
      txn_id_t            txnid;
      node_id_t           srcid;
      node_id_t           tgtid;
      vip_chi_qos_t       qos;
    } vip_chi_rsp_flit_t;

    typedef vip_chi_rsp_flit_t vip_chi_resp_flit_t;
    typedef vip_chi_rsp_flit_t rsp_flit_t;

    typedef struct packed {
      poison_t           poison;
      datacheck_t        datacheck;
      data_t             data;
      be_t               be;
      logic              tracetag;
      tu_t               tu;
      tag_t              tag;
      tagop_t            tagop;
      data_id_t          dataid;
      cc_id_t            ccid;
      txn_id_t           dbid;
      logic [2 : 0]      cbusy;
      logic [3 : 0]      datasource;
      vip_chi_resp_t     resp;
      vip_chi_resp_err_t resperr;
      dat_opcode_t       opcode;
      node_id_t          homenid;
      txn_id_t           txnid;
      node_id_t          srcid;
      node_id_t          tgtid;
      vip_chi_qos_t       qos;
    } vip_chi_dat_flit_t;

    typedef vip_chi_dat_flit_t vip_chi_data_flit_t;
    typedef vip_chi_dat_flit_t dat_flit_t;

    typedef vip_chi_types #(CFG_P)::snp_opcode_t snp_opcode_t;
    typedef struct packed {
      logic            tracetag;
      logic            donotdatapull;
      logic            rettosrc;
      snp_opcode_t     opcode;
      addr_t           addr;
      vip_chi_req_ns_t ns;
      txn_id_t         fwdtxnid;
      node_id_t        fwdnid;
      txn_id_t         txnid;
      node_id_t        srcid;
      vip_chi_qos_t       qos;
    } vip_chi_snp_flit_t;

    typedef vip_chi_snp_flit_t snp_flit_t;
  endclass

endpackage

`endif