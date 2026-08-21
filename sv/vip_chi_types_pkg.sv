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
  // Table 2-15: Size 0b110 is 64 bytes, a cache line. Named because Table A-3
  // fixes it for a whole class of opcodes and a bare 3'd6 at each use site says
  // nothing about which 64 that is.
  localparam logic [VIP_CHI_REQ_SIZE_WIDTH_C - 1 : 0] VIP_CHI_REQ_SIZE_64B_C = 3'b110;
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

  // Two isolated CHI-E coherent opcodes (Opcode[6] = 1, so CHI-E only).
  //
  // WriteEvictOrEvict is a CopyBack, and the ONLY one whose completion shape the
  // home chooses: it either asks for the data (CompDBIDResp, answered with
  // CopyBackWrData, which is an implicit CompAck) or declines it (Comp, answered
  // with an explicit CompAck). ExpCompAck must be set either way.
  //
  // WriteUniqueZero is the snoopable twin of WriteNoSnpZero: a full-line store of
  // zero with no data on the wire, completed by DBIDResp* + Comp or a combined
  // CompDBIDResp, and never carrying CompAck.
  localparam logic [VIP_CHI_MAX_REQ_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_REQ_WRITE_EVICT_OR_EVICT_C     = 7'h42;
  localparam logic [VIP_CHI_MAX_REQ_OPCODE_WIDTH_C - 1 : 0] VIP_CHI_REQ_WRITE_UNIQUE_ZERO_C        = 7'h43;

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

  // IHI 0050 E Table 2-13 / D Table 2-13: SnpAttr field encodings. The field
  // says whether a transaction requires snooping, and Table 2-14 fixes the
  // permitted value per transaction type -- it is not a free attribute.
  //
  // Under Issue E this one bit is also DoDWT (E section 13.10.25, "The bit
  // shares the same field as SnpAttr"). The two never collide: DoDWT is only
  // applicable in requests from Home to Slave, and E section 2.9.3 requires
  // SnpAttr to be zero in every such request. Issue D defines no DoDWT at all.
  typedef enum logic {
    VIP_CHI_SNP_NON_SNOOPABLE_E = 1'b0,
    VIP_CHI_SNP_SNOOPABLE_E     = 1'b1
  } vip_chi_snp_attr_t;

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

  // Which in-flight transfer a completer takes the next DAT beat from when more
  // than one is eligible. CHI relates every data packet to its transaction by
  // TxnID and to its position by DataID, so a completer is free to interleave
  // the beats of several transfers on one DAT channel; nothing in the protocol
  // requires the beats of a transfer to be contiguous. See
  // vip_chi_cfg_agent::dat_interleave_depth for the gate.
  //
  //   ROUND_ROBIN : one beat per eligible stream, in turn. Deterministic, so a
  //                 test can state the exact beat order it expects.
  //   RANDOM      : a uniform draw among the eligible streams each beat. Reaches
  //                 orders round-robin never produces, including runs of beats
  //                 from one stream.
  typedef enum logic {
    VIP_CHI_DAT_INTERLEAVE_ROUND_ROBIN_E = 1'b0,
    VIP_CHI_DAT_INTERLEAVE_RANDOM_E      = 1'b1
  } vip_chi_dat_interleave_policy_t;

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
    VIP_CHI_CHK_REQ_VALID_REQUIRES_PEND_E,
    VIP_CHI_CHK_RSP_VALID_REQUIRES_PEND_E,
    VIP_CHI_CHK_DAT_VALID_REQUIRES_PEND_E,
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
    VIP_CHI_CHK_SNP_VALID_REQUIRES_PEND_E,
    VIP_CHI_CHK_SNP_KNOWN_WHEN_VALID_E,
    VIP_CHI_CHK_SNP_IDLE_IN_RESET_E,
    VIP_CHI_CHK_SNP_LCRD_OVERFLOW_E,
    VIP_CHI_CHK_SNP_LCRD_UNDERFLOW_E,
    // Per-opcode SNP field applicability. Inside the SNP block on purpose: this
    // range is what vip_chi_snp_sva owns, and a field rule judged by the main
    // checker would clear the other's plusarg settings on every coherent run.
    VIP_CHI_CHK_SNP_FWD_FIELDS_ZERO_E,
    VIP_CHI_CHK_SNP_RET_TO_SRC_LEGAL_E,
    VIP_CHI_CHK_SNP_DO_NOT_GO_TO_SD_LEGAL_E,
    // Link layer, appended. These belong with the link rules above and are down
    // here only because the order is append-only; putting them where they read
    // best would renumber the SNP block. They sit AFTER it deliberately, so
    // vip_chi_check_is_snp -- a range test, not a list -- still answers false for
    // them and vip_chi_sva keeps ownership.
    VIP_CHI_CHK_LASM_ACTIVATION_TIMEOUT_E,
    VIP_CHI_CHK_LASM_DEACTIVATION_TIMEOUT_E,
    // RSP field legality, appended for the same append-only reason. One ID for
    // one rule: Appendix A Table A-4 marks certain RSP fields `0` or `0 a` for
    // certain opcodes, and both markings mean the field must be driven zero.
    // TxnID, RespErr and Resp are asserted together because they are three
    // columns of one table, not three rules -- standing this down means "stop
    // checking A-4's zero-marked RSP fields", which is a coherent thing to want.
    VIP_CHI_CHK_RSP_FIELD_ZERO_E,
    // ExpCompAck legality, appended for the same append-only reason. The
    // converse -- a CompAck arriving for a request that never asked for one --
    // has been checked since the first cut as COMPACK_WITHOUT_EXPCOMPACK; this is
    // the direction nobody was watching, because the item constraint made it
    // unreachable. IHI 0050 E Table 2-9 / D Table 2-8 marks six RN-F opcodes
    // "Yes", and a zero in that field is a request that can never be
    // acknowledged.
    VIP_CHI_CHK_EXPCOMPACK_REQUIRED_BUT_ZERO_E,
    // Atomic operand Size against IHI 0050 E Table 2-17 / D Table 2-17, appended
    // for the same append-only reason. The VIP has had an opinion about this
    // since the first cut -- con_atomic_strict_size -- and no rule reading it, so
    // the constraint was unverified in both ports and the two mentions of the
    // table in the checkers both compute a beat count rather than judge a Size.
    // Off by default on a link whose testcase drives the recorded wide-operand
    // stress profile; see atomic_size_stress_allowed.
    VIP_CHI_CHK_ATOMIC_SIZE_LEGAL_E,
    VIP_CHI_CHK_REQ_ORDER_LEGAL_E,
    VIP_CHI_CHK_REQ_ATTR_COMBINATION_LEGAL_E,
    VIP_CHI_CHK_REQ_SNP_ATTR_LEGAL_E,
    VIP_CHI_CHK_REQ_LIKELY_SHARED_LEGAL_E,
    VIP_CHI_CHK_REQ_SIZE_LEGAL_E,
    VIP_CHI_CHK_REQ_EXCL_LEGAL_E,
    VIP_CHI_CHK_REQ_ENDIAN_LEGAL_E,
    VIP_CHI_CHK_EXPCOMPACK_PROHIBITED_BUT_SET_E,
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
           (id <= VIP_CHI_CHK_SNP_DO_NOT_GO_TO_SD_LEGAL_E);
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
    VIP_CHI_REQ_WRITE_EVICT_OR_EVICT_E     = VIP_CHI_REQ_WRITE_EVICT_OR_EVICT_C,
    VIP_CHI_REQ_WRITE_UNIQUE_ZERO_E        = VIP_CHI_REQ_WRITE_UNIQUE_ZERO_C,
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

  // TRUE for the request opcodes in which DoDWT is a field at all.
  //
  // IHI 0050 E section 13.10.25: DoDWT is "Only applicable in WriteNoSnpFull,
  // WriteNoSnpPtl and Combined Write requests from Home to Slave", is
  // "inapplicable and must be set to zero in all other requests", and "The bit
  // shares the same field as SnpAttr". This function answers the opcode half of
  // that rule; the Home-to-Slave half is a property of the link, so a caller
  // that knows its role adds it.
  //
  // The overload is safe precisely because the two lists cannot overlap. Every
  // opcode below is a WriteNoSnp form, which Table 2-14 lists as Non-snoopable
  // only, and section 2.9.3 independently requires SnpAttr to be zero in any
  // request from HN to SN. Where DoDWT can be one, SnpAttr must be zero.
  function automatic bit vip_chi_req_dodwt_applicable(
    input vip_chi_req_opcode_t opcode
  );
    if (vip_chi_req_opcode_is_combined_write_cmo(opcode)) begin
      return 1'b1;
    end
    case (opcode)
      VIP_CHI_REQ_WRITE_NO_SNP_FULL_E,
      VIP_CHI_REQ_WRITE_NO_SNP_PTL_E: return 1'b1;
      default:                        return 1'b0;
    endcase
  endfunction

  // TRUE when REQ bit 17 carries DoDWT rather than SnpAttr on this link.
  //
  // The opcode test above is not sufficient on its own: DoDWT was introduced in
  // Issue E and appears nowhere in Issue D, whose Table 12-6 names that bit
  // SnpAttr and nothing else. So under CHI-D the bit is SnpAttr for EVERY
  // opcode, including the WriteNoSnp forms. A packer or monitor that consults
  // the opcode alone reintroduces, for those opcodes, exactly the field-identity
  // error this pair of functions exists to remove.
  function automatic bit vip_chi_req_bit17_is_dodwt(
    input vip_chi_issue_t      issue,
    input vip_chi_req_opcode_t opcode
  );
    return (issue == VIP_CHI_ISSUE_E_E) && vip_chi_req_dodwt_applicable(opcode);
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
  // Return TRUE when the snoop leaves the snoopee INVALID. IHI 0050 Chapter 4,
  // Tables 4-9 and 4-11: every response permitted to SnpUnique, SnpCleanInvalid,
  // SnpMakeInvalid and SnpUniqueFwd carries the Invalid state, with or without
  // data. A snoopee that answers one of these still holding the line has not
  // given up ownership, so the requester about to take it Unique is not the only
  // owner -- which is the single-writer invariant, broken quietly.
  // ---------------------------------------------------------------------------
  function automatic bit vip_chi_snp_opcode_invalidates(input vip_chi_snp_opcode_t opcode);
    case (opcode)
      VIP_CHI_SNP_UNIQUE_E,
      VIP_CHI_SNP_CLEAN_INVALID_E,
      VIP_CHI_SNP_MAKE_INVALID_E,
      VIP_CHI_SNP_UNIQUE_FWD_E: begin
        return 1'b1;
      end
      default: begin
        return 1'b0;
      end
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // Return TRUE when the snoop forbids the snoopee from RETAINING Unique. A
  // shared snoop exists to create a sharer, so the responses Table 4-9 permits
  // to SnpShared and SnpSharedFwd carry Invalid or SharedClean and never a
  // Unique state -- if the snoopee kept Unique there would be two Unique holders
  // the moment the requester was granted Shared.
  //
  // The set is IHI 0050 E 4.3's, not a reading of the response tables: it names
  // "Must not leave the cache line in Unique state" under SnpClean/SnpCleanFwd,
  // SnpNotSharedDirty/SnpNotSharedDirtyFwd and SnpShared/SnpSharedFwd. D 4.3 is
  // identical.
  //
  // SnpClean and SnpCleanFwd are listed because this home DOES originate them,
  // which is a correction: they were left out on the stated grounds that "this
  // VIP's home never originates them", and vip_chi_snoop_for_req maps ReadClean
  // to SnpClean on the ordinary path and to SnpCleanFwd on the direct-cache-
  // transfer path, both of which several coherent testcases drive. The omission
  // was a rule that could have been evaluated and was not.
  //
  // SnpNotSharedDirty and SnpNotSharedDirtyFwd stay out, and now for a reason
  // that holds: vip_chi_snoop_for_req has no ReadNotSharedDirty case, so no
  // request in this model produces either. SnpCleanShared stays out for the same
  // kind of reason -- there is no CleanShared sequence in seq_lib, so nothing can
  // issue the request that would produce it. Both are unreachable rather than
  // unexamined, and adding them would be a rule no traffic here can confirm or
  // refute.
  // ---------------------------------------------------------------------------
  function automatic bit vip_chi_snp_opcode_forbids_retaining_unique(
    input vip_chi_snp_opcode_t opcode
  );
    case (opcode)
      VIP_CHI_SNP_SHARED_E,
      VIP_CHI_SNP_SHARED_FWD_E,
      VIP_CHI_SNP_CLEAN_E,
      VIP_CHI_SNP_CLEAN_FWD_E: begin
        return 1'b1;
      end
      default: begin
        return 1'b0;
      end
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // The three permissions a cache state carries, named separately because the
  // seven CHI states are not a total order: SharedDirty holds the dirty data
  // without the right to write it, so it is neither above nor below UniqueClean.
  // A rule written as "state must not increase" cannot be expressed on a rank;
  // it has to be expressed on the permissions themselves.
  // ---------------------------------------------------------------------------
  function automatic bit vip_chi_state_is_readable(input vip_chi_resp_t s);
    return (s != VIP_CHI_RESP_STATE_I_E);
  endfunction

  function automatic bit vip_chi_state_is_writable(input vip_chi_resp_t s);
    return (s == VIP_CHI_RESP_STATE_UC_E) || (s == VIP_CHI_RESP_STATE_UP_PD_DIRTY_E);
  endfunction

  function automatic bit vip_chi_state_holds_dirty(input vip_chi_resp_t s);
    return (s == VIP_CHI_RESP_STATE_UP_PD_DIRTY_E) ||
           (s == VIP_CHI_RESP_STATE_SD_PD_DIRTY_E);
  endfunction

  // ---------------------------------------------------------------------------
  // Return TRUE when a snoop response reports a state holding a permission the
  // snoopee did not have when the snoop arrived.
  //
  // IHI 0050 Chapter 4: a snoop is a request to give up permissions, never a
  // grant of them. Whatever the opcode, a snoopee may keep what it held, drop to
  // something weaker, or invalidate -- it may not come back readable if it was
  // Invalid, writable if it was Shared, or Dirty if it was Clean. The only path
  // that raises a cache state is a response to that node's OWN request, which
  // arrives on RSP/DAT against a transaction the snoop knows nothing about.
  //
  // This is the gate that makes it safe to take the snoopee's next state FROM
  // the response rather than deriving it: the reported state writes the shadow
  // directory, so an implementation that reports nonsense would otherwise steer
  // every later coherency check through it. The opcode ceiling
  // (vip_chi_snp_opcode_invalidates and vip_chi_snp_opcode_forbids_retaining_unique
  // above) is the other half and is independent -- it bounds the response by what
  // was ASKED, this bounds it by what was HELD, and neither implies the other.
  //
  // Read and write permission are unconditional: I -> SC needs a read, SC -> UC
  // needs a CleanUnique or MakeUnique, and both are requests the checker sees.
  // Gaining either without one is a genuine impossibility.
  //
  // BECOMING DIRTY IS CONDITIONAL, and the condition is the whole subtlety. A
  // holder turns Clean into Dirty by writing to its own cache line -- a purely
  // local act with no CHI transaction behind it, so a node granted UC can be UD
  // an instant later and nothing on the wire says so. Flagging that would report
  // the observer's blind spot as the peer's fault, which is the failure mode
  // this rule exists to avoid. But the local act needs WRITE PERMISSION: a
  // SharedClean holder cannot write, so it cannot manufacture dirty data, and an
  // SC -> SD response is impossible rather than merely unobserved. So dirty is
  // allowed to appear only where the snoopee could have written it.
  //
  // Stated as a permission comparison and not a state table on purpose: it holds
  // for all seven CHI states including the three this VIP does not model, so it
  // does not have to be revisited when one of them is added.
  // ---------------------------------------------------------------------------
  function automatic bit vip_chi_snp_resp_state_gains_permission(
    input vip_chi_resp_t from_state,
    input vip_chi_resp_t reported_state
  );
    return (vip_chi_state_is_readable(reported_state) &&
            !vip_chi_state_is_readable(from_state))   ||
           (vip_chi_state_is_writable(reported_state) &&
            !vip_chi_state_is_writable(from_state))   ||
           (vip_chi_state_holds_dirty(reported_state) &&
            !vip_chi_state_holds_dirty(from_state)    &&
            !vip_chi_state_is_writable(from_state));
  endfunction

  // ---------------------------------------------------------------------------
  // The least cache state carrying every permission either operand carries.
  //
  // The five states this VIP models are exactly the five permission triples that
  // satisfy "writable implies readable" and "dirty implies readable":
  //
  //     I  (-,-,-)   SC (R,-,-)   UC (R,W,-)   SD (R,-,D)   UD (R,W,D)
  //
  // OR-ing two such triples yields another one, so the join is total and closed
  // over the modeled set and needs no default arm. It is NOT a maximum over a
  // rank: SD and UC are incomparable (SD holds the dirty data without the right
  // to write it, UC holds the right without the data), and their join is UD --
  // a state neither operand is. That row is Table 4-14's ReadUnique-from-SD
  // case, and it is the one a rank-based implementation gets wrong.
  // ---------------------------------------------------------------------------
  function automatic vip_chi_resp_t vip_chi_state_join(input vip_chi_resp_t a,
                                                       input vip_chi_resp_t b);
    bit r, w, d;

    r = vip_chi_state_is_readable(a)   || vip_chi_state_is_readable(b);
    w = vip_chi_state_is_writable(a)   || vip_chi_state_is_writable(b);
    d = vip_chi_state_holds_dirty(a)   || vip_chi_state_holds_dirty(b);

    if (!r)      return VIP_CHI_RESP_STATE_I_E;
    if (w && d)  return VIP_CHI_RESP_STATE_UP_PD_DIRTY_E;
    if (w)       return VIP_CHI_RESP_STATE_UC_E;
    if (d)       return VIP_CHI_RESP_STATE_SD_PD_DIRTY_E;
    return VIP_CHI_RESP_STATE_SC_E;
  endfunction

  // ---------------------------------------------------------------------------
  // The Requester's cache state after its own request completes: a function of
  // the state it HELD and the state the completion GRANTED.
  //
  // IHI 0050 E Table 4-14 (§4.7.1, reads), Tables 4-17 and 4-18 (MakeReadUnique)
  // and Table 4-19 (§4.7.2, dataless); D Tables 4-12 and 4-13. Those four tables
  // are a single rule: a completion GRANTS coherence rights, it does not revoke
  // rights the Requester already holds. Every row is the permission join of the
  // two states, with one exception noted below -- checked row by row, including
  // the three that make the point:
  //
  //   ReadClean  UD + CompData_SC -> UD    (the grant is weaker; the holder keeps
  //                                         its dirty line and its write right)
  //   ReadClean  SD + CompData_UC -> UD    (join of two incomparable states)
  //   ReadUnique SD + CompData_UC -> UD    (same, and present in D as well as E)
  //
  // Taking the granted Resp verbatim -- which is what "final = Resp" does --
  // silently drops the writeback obligation for a line the Requester is still
  // responsible for, and the dirty beats along with it.
  //
  // The held state must be read at COMPLETION time, not at the time the request
  // was issued. Tables 4-17 and 4-18 make this explicit with a separate "state at
  // time of response" column: a snoop landing while the request is outstanding
  // can take the line away, and then SC-at-issue/I-at-response + CompData_UC is
  // UC, not the UD that joining against the issue-time state would give. Both
  // callers read a live shadow, so they get this for free -- but only because
  // they read it late.
  //
  // MakeUnique is the exception and the reason this takes an opcode at all. Its
  // completion is Comp_UC (Table 4-19 / D Table 4-13) yet its final state is UD
  // from every permitted initial state: the Requester has undertaken to overwrite
  // the whole line, so it becomes Dirty by its own act rather than by inheriting
  // anyone's dirty data. No join produces that, because the grant does not carry
  // it.
  //
  // Opcodes that do not appear in these tables return the held state unchanged.
  // The non-allocating reads belong to that group on purpose: §4.7.1 requires the
  // Requester to IGNORE the cache state in the CompData response to ReadNoSnp,
  // ReadOnce, ReadOnceCleanInvalid and ReadOnceMakeInvalid, so joining against it
  // would be wrong and not merely unnecessary. Callers decide separately whether
  // an opcode invalidates the line -- that is not a state this function can
  // return, since "no change" and "goes to I" are different answers.
  // ---------------------------------------------------------------------------
  function automatic vip_chi_resp_t vip_chi_req_final_state(
    input vip_chi_req_opcode_t opcode,
    input vip_chi_resp_t       held,
    input vip_chi_resp_t       granted
  );
    case (opcode)
      VIP_CHI_REQ_MAKE_UNIQUE_E: begin
        return VIP_CHI_RESP_STATE_UP_PD_DIRTY_E;
      end
      VIP_CHI_REQ_READ_SHARED_E,
      VIP_CHI_REQ_READ_CLEAN_E,
      VIP_CHI_REQ_READ_UNIQUE_E,
      VIP_CHI_REQ_MAKE_READ_UNIQUE_E,
      VIP_CHI_REQ_CLEAN_UNIQUE_E: begin
        return vip_chi_state_join(held, granted);
      end
      default: begin
        return held;
      end
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // TRUE when the Requester must DISCARD the data a read returned because the
  // line it already holds is the newer copy.
  //
  // IHI 0050 E Table 4-14 footnote c: "Data received from memory must be dropped
  // if the cache state is UD or SD, or merged if the cache state is UDP." The
  // reachable half of that is the drop: this VIP has no byte-granular dirty
  // tracking, so UDP is not modeled and the merge case cannot arise. Overwriting
  // a dirty line with the fetched copy loses the locally-modified bytes outright
  // -- the state stays right and the data goes wrong, which is worse than either
  // alone because every later data-integrity check then agrees with the loss.
  // ---------------------------------------------------------------------------
  function automatic bit vip_chi_req_keeps_local_data(input vip_chi_resp_t held);
    return vip_chi_state_holds_dirty(held);
  endfunction

  // ---------------------------------------------------------------------------
  // IHI 0050 E Table 4-5 / D Table 4-3, "Request types and the corresponding
  // snoop requests": WHICH snoop a Home is permitted to send for a given
  // request. The table is only half the rule -- the bullet list that follows it
  // in both issues widens several rows, and the widening is normative, not
  // commentary. The permitted set for a request is therefore
  //
  //   {Snoop Expected} u {Alternative snoop} u {the bullets below}
  //
  // and the bullets that matter to the requests this VIP models are:
  //
  //   B1  SnpNotSharedDirty, SnpShared or SnpClean may be used for
  //       ReadNotSharedDirty, ReadShared AND ReadClean.
  //   B2  SnpNotSharedDirtyFwd, SnpSharedFwd or SnpCleanFwd may be used for
  //       ReadShared.
  //   B3  SnpNotSharedDirtyFwd or SnpCleanFwd may be used for
  //       ReadNotSharedDirty and ReadClean.  *** SnpSharedFwd is absent here ***
  //   B4  Any invalidating snoop may be replaced by SnpUnique or SnpCleanInvalid.
  //   B5  Any Forwarding snoop may be replaced by its non-Forwarding form.
  //   B6  ReadOnce may use any non-Forwarding, non-invalidating snoop, or
  //       SnpOnceFwd.
  //
  // B1 against B3 is the whole point of this function, and it is the opposite of
  // what a reading of the table alone suggests. SnpShared for a ReadClean is
  // PERMITTED (B1). SnpSharedFwd for a ReadClean is NOT (B3 omits it, and no
  // other bullet reaches it).
  //
  // The asymmetry is not editorial. A forwarding snoop hands the cache line
  // straight to the requester in a state the SNOOPEE picks, and Table 4-34
  // (SnpSharedFwd) permits a UD or SD snoopee to forward CompData_SD_PD -- the
  // requester ends Shared Dirty. Table 4-14's ReadClean rows permit final SC or
  // UC and nothing else; there is no SD row and no CompData_SD_PD column for
  // that request. So SnpSharedFwd for a ReadClean lets one legal snoopee
  // response put the requester in a state its own request forbids, with no flit
  // anywhere in the transaction being individually illegal. The non-forwarding
  // SnpShared cannot do this: the snoopee answers the HOME, the home sources the
  // completion, and the home is bound by Table 4-14 when it picks the Resp.
  //
  // Both issues carry B1-B5 in identical words. D additionally permits
  // SnpUniqueFwd for ReadShared when only one sharer is present; E drops that
  // bullet, so it is not encoded here -- this VIP never picks it, and encoding a
  // D-only permission would make the checker accept on E what E does not allow.
  // ---------------------------------------------------------------------------
  function automatic bit vip_chi_snoop_permitted_for_req(
    input vip_chi_req_opcode_t req_op,
    input vip_chi_snp_opcode_t snp_op
  );
    case (req_op)
      // Table 4-5 row: SnpSharedFwd expected, SnpShared alternative. B1 adds
      // SnpClean and SnpNotSharedDirty; B2 adds the other two Fwd forms.
      VIP_CHI_REQ_READ_SHARED_E: begin
        return (snp_op == VIP_CHI_SNP_SHARED_E)               ||
               (snp_op == VIP_CHI_SNP_CLEAN_E)                ||
               (snp_op == VIP_CHI_SNP_SHARED_FWD_E)           ||
               (snp_op == VIP_CHI_SNP_CLEAN_FWD_E)            ||
               (snp_op == VIP_CHI_SNP_NOT_SHARED_DIRTY_FWD_E);
      end
      // Table 4-5 row: SnpCleanFwd expected, SnpClean alternative. B1 adds
      // SnpShared and SnpNotSharedDirty; B3 adds SnpNotSharedDirtyFwd ONLY.
      VIP_CHI_REQ_READ_CLEAN_E: begin
        return (snp_op == VIP_CHI_SNP_CLEAN_E)                ||
               (snp_op == VIP_CHI_SNP_SHARED_E)               ||
               (snp_op == VIP_CHI_SNP_CLEAN_FWD_E)            ||
               (snp_op == VIP_CHI_SNP_NOT_SHARED_DIRTY_FWD_E);
      end
      // SnpUniqueFwd expected, SnpUnique alternative; B4 adds SnpCleanInvalid.
      VIP_CHI_REQ_READ_UNIQUE_E: begin
        return (snp_op == VIP_CHI_SNP_UNIQUE_E)        ||
               (snp_op == VIP_CHI_SNP_UNIQUE_FWD_E)    ||
               (snp_op == VIP_CHI_SNP_CLEAN_INVALID_E);
      end
      // SnpCleanInvalid expected; SnpUnique, SnpUniqueFwd and SnpMakeInvalid are
      // listed alternatives. E-only opcode, so no D column to reconcile.
      VIP_CHI_REQ_MAKE_READ_UNIQUE_E: begin
        return (snp_op == VIP_CHI_SNP_CLEAN_INVALID_E) ||
               (snp_op == VIP_CHI_SNP_UNIQUE_E)        ||
               (snp_op == VIP_CHI_SNP_UNIQUE_FWD_E)    ||
               (snp_op == VIP_CHI_SNP_MAKE_INVALID_E);
      end
      // SnpOnceFwd expected, SnpOnce alternative, plus B6's "any non-Forwarding,
      // non-invalidating snoop" -- which is what makes SnpShared/SnpClean/
      // SnpCleanShared legal here as well.
      VIP_CHI_REQ_READ_ONCE_E: begin
        return (snp_op == VIP_CHI_SNP_ONCE_E)         ||
               (snp_op == VIP_CHI_SNP_ONCE_FWD_E)     ||
               (snp_op == VIP_CHI_SNP_SHARED_E)       ||
               (snp_op == VIP_CHI_SNP_CLEAN_E)        ||
               (snp_op == VIP_CHI_SNP_CLEAN_SHARED_E);
      end
      // SnpCleanInvalid expected, no alternative column; B4 adds SnpUnique.
      VIP_CHI_REQ_CLEAN_UNIQUE_E,
      VIP_CHI_REQ_CLEAN_INVALID_E: begin
        return (snp_op == VIP_CHI_SNP_CLEAN_INVALID_E) ||
               (snp_op == VIP_CHI_SNP_UNIQUE_E);
      end
      // SnpMakeInvalid expected; E lists SnpCleanInvalid as the alternative and
      // B4 reaches SnpUnique in both issues.
      VIP_CHI_REQ_MAKE_UNIQUE_E,
      VIP_CHI_REQ_MAKE_INVALID_E,
      VIP_CHI_REQ_WRITE_UNIQUE_FULL_E,
      VIP_CHI_REQ_WRITE_UNIQUE_ZERO_E: begin
        return (snp_op == VIP_CHI_SNP_MAKE_INVALID_E)  ||
               (snp_op == VIP_CHI_SNP_CLEAN_INVALID_E) ||
               (snp_op == VIP_CHI_SNP_UNIQUE_E);
      end
      // SnpCleanShared expected, no alternative and no bullet reaching it:
      // CleanShared is the one request in this set whose snoop is forced. The
      // pairing is encoded now, ahead of the request itself -- CleanShared is
      // not yet in the RN-F's opcode set, and adding it without this row would
      // have put the home on the SnpCleanInvalid default, invalidating a line
      // the request only asked to have cleaned.
      VIP_CHI_REQ_CLEAN_SHARED_E: begin
        return (snp_op == VIP_CHI_SNP_CLEAN_SHARED_E);
      end
      // The one row the table states as a choice rather than an expectation:
      // "SnpCleanInvalid or SnpUnique".
      VIP_CHI_REQ_WRITE_UNIQUE_PTL_E: begin
        return (snp_op == VIP_CHI_SNP_CLEAN_INVALID_E) ||
               (snp_op == VIP_CHI_SNP_UNIQUE_E);
      end
      default: begin
        // Requests whose Table 4-5 row is n/a in every snoop column -- the
        // NoSnp family, the CopyBacks, Evict, PCrdReturn. A snoop attributed to
        // one of these is judged by vip_chi_req_generates_snoop below, not here,
        // so returning FALSE would double-report the same event.
        return 1'b0;
      end
    endcase
  endfunction

  // TRUE when Table 4-5 gives the request a snoop at all. Split from the
  // predicate above so a snoop correlated to a ReadNoSnp reports "this request
  // is snoopless" rather than "this snoop is the wrong opcode", which are
  // different defects with different causes.
  function automatic bit vip_chi_req_generates_snoop(input vip_chi_req_opcode_t req_op);
    case (req_op)
      VIP_CHI_REQ_READ_SHARED_E,
      VIP_CHI_REQ_READ_CLEAN_E,
      VIP_CHI_REQ_READ_UNIQUE_E,
      VIP_CHI_REQ_MAKE_READ_UNIQUE_E,
      VIP_CHI_REQ_READ_ONCE_E,
      VIP_CHI_REQ_CLEAN_UNIQUE_E,
      VIP_CHI_REQ_CLEAN_INVALID_E,
      VIP_CHI_REQ_CLEAN_SHARED_E,
      VIP_CHI_REQ_MAKE_UNIQUE_E,
      VIP_CHI_REQ_MAKE_INVALID_E,
      VIP_CHI_REQ_WRITE_UNIQUE_FULL_E,
      VIP_CHI_REQ_WRITE_UNIQUE_PTL_E,
      VIP_CHI_REQ_WRITE_UNIQUE_ZERO_E: begin
        return 1'b1;
      end
      default: begin
        return 1'b0;
      end
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // The Home's CHOICE from the permitted set above: the snoop this VIP's HN-F
  // originates for a request, with `fwd` selecting the Direct Cache Transfer
  // column. Deliberately a separate function from the predicate, and not derived
  // from it: the driver picks and the checker judges, and a checker that asked
  // the driver's function what to expect would agree with the driver by
  // construction. They are cross-checked only at the point where it counts --
  // the checker applies the predicate to the opcode that actually appeared on
  // the wire.
  //
  // Where the choice is free the Expected column is taken, except that
  // CleanUnique/CleanInvalid/MakeReadUnique keep the SnpUnique this home has
  // always sent (B4 permits it) so the change is confined to the row the
  // spec actually forbids.
  // ---------------------------------------------------------------------------
  function automatic vip_chi_snp_opcode_t vip_chi_snoop_for_req(
    input vip_chi_req_opcode_t req_op,
    input bit                  fwd
  );
    case (req_op)
      VIP_CHI_REQ_READ_SHARED_E: begin
        return fwd ? VIP_CHI_SNP_SHARED_FWD_E : VIP_CHI_SNP_SHARED_E;
      end
      // The row this box exists for. SnpCleanFwd is the Expected forwarding
      // snoop; SnpSharedFwd -- what this home used to send for every read that
      // was not a unique read -- is permitted for ReadShared and for nothing
      // else.
      VIP_CHI_REQ_READ_CLEAN_E: begin
        return fwd ? VIP_CHI_SNP_CLEAN_FWD_E : VIP_CHI_SNP_CLEAN_E;
      end
      VIP_CHI_REQ_READ_UNIQUE_E,
      VIP_CHI_REQ_MAKE_READ_UNIQUE_E: begin
        return fwd ? VIP_CHI_SNP_UNIQUE_FWD_E : VIP_CHI_SNP_UNIQUE_E;
      end
      VIP_CHI_REQ_READ_ONCE_E: begin
        return fwd ? VIP_CHI_SNP_ONCE_FWD_E : VIP_CHI_SNP_ONCE_E;
      end
      VIP_CHI_REQ_CLEAN_UNIQUE_E: begin
        return VIP_CHI_SNP_UNIQUE_E;
      end
      VIP_CHI_REQ_CLEAN_INVALID_E,
      VIP_CHI_REQ_WRITE_UNIQUE_FULL_E,
      VIP_CHI_REQ_WRITE_UNIQUE_PTL_E,
      VIP_CHI_REQ_WRITE_UNIQUE_ZERO_E: begin
        return VIP_CHI_SNP_CLEAN_INVALID_E;
      end
      VIP_CHI_REQ_MAKE_UNIQUE_E,
      VIP_CHI_REQ_MAKE_INVALID_E: begin
        return VIP_CHI_SNP_MAKE_INVALID_E;
      end
      VIP_CHI_REQ_CLEAN_SHARED_E: begin
        return VIP_CHI_SNP_CLEAN_SHARED_E;
      end
      default: begin
        // Snoopless per Table 4-5. Callers gate on vip_chi_req_generates_snoop;
        // SnpOnce is returned rather than an X so a caller that does not is
        // wrong in a way a simulation reports instead of propagating.
        return VIP_CHI_SNP_ONCE_E;
      end
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // Three-valued because Table 2-9 is: "Yes", "Optional" and "No" are three
  // different obligations, and collapsing them to a boolean is what produced a
  // legality constraint that forced the bit to zero on the rows marked "Yes".
  // ---------------------------------------------------------------------------
  typedef enum int {
    VIP_CHI_COMPACK_PROHIBITED_E = 0,
    VIP_CHI_COMPACK_OPTIONAL_E   = 1,
    VIP_CHI_COMPACK_REQUIRED_E   = 2
  } vip_chi_compack_req_t;

  // ---------------------------------------------------------------------------
  // Whether a request must, may, or must not carry ExpCompAck -- and therefore
  // whether the requester owes a CompAck once the completion arrives.
  //
  // IHI 0050 E Table 2-9 / D Table 2-8, "Requester CompAck requirement". The
  // table has two columns, RN-F and RN-D/RN-I, and they do not agree: every
  // coherent read is "Yes" for an RN-F and "-" for an RN-I (which cannot issue
  // one at all), while ReadNoSnp is "Optional" for both. That is why the
  // requester role is an argument here rather than being read off the opcode --
  // the opcode alone does not determine the answer.
  //
  // The table is backed by prose in the same section, and the prose is where the
  // "-" cells acquire meaning:
  //
  //   * "An RN-F must include a CompAck response in all Read transactions except
  //     ReadNoSnp and ReadOnce*."
  //   * "Although not required, an RN-F is permitted to include a CompAck
  //     response in ReadNoSnp and ReadOnce* transactions."
  //   * "An RN-F must not include a CompAck response in StashOnce*, CMO, Atomic
  //     or Evict transactions."
  //   * "An RN-I or RN-D is permitted, but not required, to include a CompAck
  //     response in Read transactions."
  //   * "An RN-I or RN-D must not include a CompAck response in Dataless or
  //     Atomic transactions."
  //
  // Note which way the asymmetry runs. CleanUnique and MakeUnique are Dataless
  // requests, and Dataless is exactly the class an RN-I "must not" acknowledge --
  // yet both are "Yes" in the RN-F column. They are not CMOs (CleanShared,
  // CleanInvalid, MakeInvalid and the Persist forms are), so the RN-F "must not"
  // bullet does not reach them either. An implementation that classified by
  // request CLASS rather than by opcode would get both of them wrong, in
  // opposite directions depending on which bullet it reached for.
  //
  // REQUIRED is a two-sided obligation: the requester sets the bit and sends the
  // CompAck, and the completer waits for it before snooping the line again
  // (section 2.8.3 rule 2). PROHIBITED is one-sided -- the bit must be zero.
  // OPTIONAL means the protocol permits either, and the VIP's own policy of
  // leaving it off by default lives in the item constraint, not here.
  //
  // Every REQ opcode this VIP models is listed. The default is PROHIBITED
  // because that is the only answer that cannot put an illegal flit on the wire
  // for an opcode nobody has classified yet: it drives the bit to zero, which is
  // legal for every row except the "Yes" ones, and all of those are named above.
  // An opcode added later still has to be classified here -- ReadNotSharedDirty
  // and ReadPreferUnique are "Yes" rows this VIP does not yet model, and each
  // would be silently wrong under the default.
  // ---------------------------------------------------------------------------
  function automatic vip_chi_compack_req_t vip_chi_exp_comp_ack_requirement(
    input vip_chi_req_opcode_t req_op,
    input bit                  requester_is_rnf
  );

    // Optional for BOTH columns of the table: the two read forms an RN-F may
    // decline to acknowledge, and the two writes that use CompAck only when they
    // want Ordered Write Observation ("For Write transactions, CompAck can only
    // be used for WriteUnique and WriteNoSnp transactions when they require
    // Ordered Write Observation guarantees").
    // ReadNoSnpSep is deliberately NOT in this list. Chapter 4 gives it "Must not
    // assert ExpCompAck in the Request" and Table A-3's ExpCompAck column agrees
    // with a "0". Classifying it Optional -- as this function did -- permitted the
    // bit on an opcode the specification forbids it on, and left
    // CHI_EXPCOMPACK_PROHIBITED_BUT_SET blind to the violation, because the
    // classifier did not call it one.
    case (req_op)
      VIP_CHI_REQ_READ_NO_SNP_E,
      VIP_CHI_REQ_READ_ONCE_E,
      VIP_CHI_REQ_WRITE_UNIQUE_FULL_E,
      VIP_CHI_REQ_WRITE_UNIQUE_PTL_E,
      VIP_CHI_REQ_WRITE_NO_SNP_FULL_E,
      VIP_CHI_REQ_WRITE_NO_SNP_PTL_E: begin
        return VIP_CHI_COMPACK_OPTIONAL_E;
      end
      default: begin
      end
    endcase

    // "In a Combined Write transaction, the CompAck requirement is the same as
    // the CompAck requirement for the type of Write in the Combined Write
    // transaction." Every combined form this VIP models is a WriteNoSnp, so they
    // inherit Optional -- NOT the "No" of the CMO half bolted onto them.
    if (vip_chi_req_opcode_is_combined_write_cmo(req_op)) begin
      return VIP_CHI_COMPACK_OPTIONAL_E;
    end

    // The "Yes" rows. All of them are RN-F only; the same opcodes reaching this
    // function with requester_is_rnf low are requests an RN-I cannot issue, and
    // falling through to PROHIBITED is the right answer for a bit it must not
    // set.
    if (requester_is_rnf) begin
      case (req_op)
        VIP_CHI_REQ_READ_CLEAN_E,
        VIP_CHI_REQ_READ_SHARED_E,
        VIP_CHI_REQ_READ_UNIQUE_E,
        VIP_CHI_REQ_MAKE_READ_UNIQUE_E,
        VIP_CHI_REQ_CLEAN_UNIQUE_E,
        VIP_CHI_REQ_MAKE_UNIQUE_E,
        // WriteEvictOrEvict lets the home decline the data and answer with a
        // bare Comp, and that leg completes only when the requester acks -- so
        // the bit is not optional the way it is on every other write.
        VIP_CHI_REQ_WRITE_EVICT_OR_EVICT_E: begin
          return VIP_CHI_COMPACK_REQUIRED_E;
        end
        default: begin
        end
      endcase
    end

    return VIP_CHI_COMPACK_PROHIBITED_E;
  endfunction

  // ---------------------------------------------------------------------------
  // Shorthand for the two edges of the rule above, so a caller that only needs
  // one of them does not have to name the enum.
  // ---------------------------------------------------------------------------
  function automatic bit vip_chi_exp_comp_ack_required(
    input vip_chi_req_opcode_t req_op,
    input bit                  requester_is_rnf
  );
    return (vip_chi_exp_comp_ack_requirement(req_op, requester_is_rnf) ==
            VIP_CHI_COMPACK_REQUIRED_E);
  endfunction

  function automatic bit vip_chi_exp_comp_ack_prohibited(
    input vip_chi_req_opcode_t req_op,
    input bit                  requester_is_rnf
  );
    return (vip_chi_exp_comp_ack_requirement(req_op, requester_is_rnf) ==
            VIP_CHI_COMPACK_PROHIBITED_E);
  endfunction

  // ---------------------------------------------------------------------------
  // Return TRUE when the snoop's response must NOT carry data. The snoopee
  // invalidates the line and DISCARDS any Dirty copy instead of passing it to
  // the Home: IHI 0050 Chapter 4 lists no SnpRespData form among the responses
  // permitted to SnpMakeInvalid, only the data-less SnpResp_I (Tables 4-9 and
  // 4-11).
  //
  // The rule is not a formality. SnpMakeInvalid is what a Home sends once the
  // requester has committed to overwriting the WHOLE line -- MakeUnique, a full
  // WriteUnique -- so the cached copy is about to be superseded and the Home
  // wants it gone, not returned. A SnpRespData_I_PD there hands back beats the
  // Home then owns as Dirty data it must write out, which can land the stale
  // line in memory after the new one. A Home is also entitled to have allocated
  // no buffer and no DBID for the beats, leaving the DAT flit unmatched.
  //
  // SnpCleanInvalid is the opcode that DOES want the Dirty copy back, and the
  // two are otherwise identical in their effect on the snoopee. That is why
  // deciding the response form from the held state alone looks correct
  // everywhere else: only the opcode separates "invalidate and write back" from
  // "invalidate and drop".
  //
  // Every modeled snoop opcode is listed rather than defaulted, so an opcode
  // added later has to be classified here instead of silently inheriting the
  // permissive answer. SnpMakeInvalidStash and the stash/query snoops belong on
  // the TRUE side when they are modeled.
  // ---------------------------------------------------------------------------
  function automatic bit vip_chi_snp_opcode_returns_no_data(input vip_chi_snp_opcode_t opcode);
    case (opcode)
      VIP_CHI_SNP_MAKE_INVALID_E: begin
        return 1'b1;
      end
      VIP_CHI_SNP_SHARED_E,
      VIP_CHI_SNP_CLEAN_E,
      VIP_CHI_SNP_ONCE_E,
      VIP_CHI_SNP_UNIQUE_E,
      VIP_CHI_SNP_CLEAN_SHARED_E,
      VIP_CHI_SNP_CLEAN_INVALID_E,
      VIP_CHI_SNP_SHARED_FWD_E,
      VIP_CHI_SNP_CLEAN_FWD_E,
      VIP_CHI_SNP_ONCE_FWD_E,
      VIP_CHI_SNP_NOT_SHARED_DIRTY_FWD_E,
      VIP_CHI_SNP_UNIQUE_FWD_E: begin
        return 1'b0;
      end
      default: begin
        return 1'b0;
      end
    endcase
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
  // Return TRUE when Size is one the specification permits for this atomic.
  //
  // IHI 0050 E Table 2-17 (Atomic transaction outbound and inbound data sizes,
  // in section 2.10.4) is a closed list, and it is not the same list for every
  // atomic:
  //
  //   AtomicStore / AtomicLoad / AtomicSwap   1, 2, 4 or 8 byte   -> Size 0..3
  //   AtomicCompare                           2, 4, 8, 16 or 32   -> Size 1..5
  //
  // D Table 2-17 is the same table, with the same number, so one function serves
  // both issues.
  //
  // AtomicCompare is the exception at BOTH ends and for the same reason: its Size
  // is the COMBINED compare+swap size, so a 2-byte transaction carries two 1-byte
  // operands. That gives it a floor no other atomic has -- Size 0 would be half a
  // byte each -- and a ceiling one step higher, because 32 bytes is two 16-byte
  // operands. Deriving this from the ordinary <= 8-byte limit gets the ceiling
  // wrong in the direction that rejects legal traffic.
  //
  // Returns TRUE for anything that is not an atomic, so a caller can apply it
  // unconditionally to a REQ opcode without first asking what kind it is.
  // ---------------------------------------------------------------------------
  function automatic bit vip_chi_atomic_size_legal(
    input vip_chi_req_opcode_t                     opcode,
    input logic [VIP_CHI_REQ_SIZE_WIDTH_C - 1 : 0] size
  );
    if (!vip_chi_req_opcode_is_atomic(opcode)) begin
      return 1'b1;
    end

    if (vip_chi_req_opcode_is_atomic_compare(opcode)) begin
      return ((size >= 3'd1) && (size <= 3'd5));
    end

    return (size <= 3'd3);
  endfunction

  // ---------------------------------------------------------------------------
  // Return TRUE when this REQ's Order value is one the specification permits for
  // this opcode. TOTAL: every opcode/Order pair it does not object to is TRUE, so
  // the rule that calls it evaluates on every request rather than only on the
  // ones it can fault. A classifier that answers only for the cases it judges
  // cannot tell "no such request went by" from "the classifier forgot this
  // opcode".
  //
  // Two normative restrictions, both opcode-only, so neither needs the node-class
  // model this VIP does not have:
  //
  //   Order = 0b01 "Request accepted" (IHI 0050 E Table 13-25) is applicable only
  //   in a READ request from HN-F to SN-F, or HN-I to SN-I, and is "Reserved in
  //   all other cases". Whether a given link is Home-to-Slave is not decidable
  //   here. "The opcode is a read" is a necessary condition either way, so a
  //   WRITE carrying 0b01 is Reserved on any link, and that much is checked.
  //
  //   Order = 0b10 "Request Order" (IHI 0050 E Table 2-12, footnote a) "is
  //   permitted in ReadOnce*, WriteUnique, ReadNoSnp, WriteNoSnp and Atomic
  //   transactions only". The footnote is a superscript and does not survive a
  //   text extraction of the table, which is why the restriction reads as absent
  //   from the table body.
  //
  // Deliberately permissive where the footnote's naming is: the families are read
  // to include their variants, and the Combined Write opcodes are counted as
  // WriteNoSnp because that is what their write half is. A whitelist read
  // generously under-reports; read narrowly it would fail conformant traffic,
  // which is the worse error for a rule that runs on every request in the sweep.
  //
  // Order = 0b00 is legal everywhere. Order = 0b11 Endpoint Order is NOT judged
  // here: Table 2-12 admits it only on the two Device rows, so it is a constraint
  // on {MemAttr, Order} together and belongs to the attribute-combination rule,
  // not to this one.
  // ---------------------------------------------------------------------------
  function automatic bit vip_chi_req_order_legal(
    input vip_chi_req_opcode_t opcode,
    input vip_chi_req_order_t  order
  );
    // Checked BEFORE the per-value cases: this is a requirement on the OPCODE, so
    // it must reject every value except 0b01 rather than only the ones a
    // per-value branch happens to reach. 0b10 would otherwise slip through the
    // Request-Order whitelist, which lists ReadNoSnpSep because that value is
    // permitted on it in general -- but Chapter 4 makes 0b01 mandatory, which is
    // stricter.
    if (opcode == VIP_CHI_REQ_READ_NO_SNP_SEP_E) begin
      return (order == VIP_CHI_ORDER_REQ_ACCEPTED_E);
    end

    case (order)

      VIP_CHI_ORDER_REQ_ACCEPTED_E: begin
        case (opcode)
          VIP_CHI_REQ_READ_NO_SNP_E,
          VIP_CHI_REQ_READ_NO_SNP_SEP_E,
          VIP_CHI_REQ_READ_SHARED_E,
          VIP_CHI_REQ_READ_CLEAN_E,
          VIP_CHI_REQ_READ_UNIQUE_E,
          VIP_CHI_REQ_READ_ONCE_E: begin
            return 1'b1;
          end
          default: begin
            return 1'b0;
          end
        endcase
      end

      VIP_CHI_ORDER_REQ_ORDER_E: begin
        if (vip_chi_req_opcode_is_atomic(opcode) ||
            vip_chi_req_opcode_is_combined_write_cmo(opcode)) begin
          return 1'b1;
        end
        case (opcode)
          VIP_CHI_REQ_READ_ONCE_E,
          VIP_CHI_REQ_READ_NO_SNP_E,
          VIP_CHI_REQ_READ_NO_SNP_SEP_E,
          VIP_CHI_REQ_WRITE_UNIQUE_FULL_E,
          VIP_CHI_REQ_WRITE_UNIQUE_PTL_E,
          VIP_CHI_REQ_WRITE_UNIQUE_ZERO_E,
          VIP_CHI_REQ_WRITE_NO_SNP_FULL_E,
          VIP_CHI_REQ_WRITE_NO_SNP_PTL_E,
          VIP_CHI_REQ_WRITE_NO_SNP_ZERO_E: begin
            return 1'b1;
          end
          default: begin
            return 1'b0;
          end
        endcase
      end

      // Order = 0b00 and 0b11 land here. 0b11 Endpoint Order is not judged by
      // opcode: Table 2-12 already ties it to Device memory, and
      // vip_chi_req_attr_combination_legal owns that pairing.
      //
      // The one POSITIVE requirement on this field lives here, and it is the
      // reason the 0b01 encoding exists at all. Chapter 4 gives ReadNoSnpSep "The
      // Order field of the request must be set to b01", and its communicating node
      // pairs are exactly ICN(HN-F) to SN-F and ICN(HN-I) to SN-I -- the two cases
      // Table 13-25 names as applicable for that value. So on that opcode every
      // other Order value is wrong, which incidentally closes the gap this
      // function documents above: the Home-to-Slave condition a bind cannot decide
      // is implied by the opcode in the one place the value is mandatory.
      default: begin
        return 1'b1;
      end
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // Return TRUE when the atomic request is a store-style completion-only op.
  // IHI 0050 E Table 13-8 / D Table 12-8: one SNP packet bit carries two
  // different field names, and which one it is depends on the opcode -- the same
  // shape as REQ bit 17's SnpAttr/DoDWT overload. D Table 12-8 prints the two
  // names stacked in a single one-bit row, and D 12.9.32/12.9.33 state the
  // partition from both sides: DoNotGoToSD is "applicable in all Snoop requests
  // except SnpUniqueStash, SnpMakeInvalidStash, SnpStashShared, SnpStashUnique,
  // SnpDVMOp" and "for Stash snoop requests the same bits in the packet are used
  // for DoNotDataPull"; DoNotDataPull is "applicable in" exactly those four
  // stash snoops and "not present in Non-stash snoops". Issue E removed
  // DoNotDataPull entirely.
  //
  // NONE of the four stash snoops is modelled here, so on every opcode this VIP
  // can send or receive the bit is DoNotGoToSD, in both issues. The classifier
  // is written from the specification rather than from that fact, so that adding
  // a stash snoop cannot silently reinterpret the bit.
  // ---------------------------------------------------------------------------
  function automatic bit vip_chi_snp_bit_is_do_not_data_pull(
    input vip_chi_issue_t          issue,
    input vip_chi_snp_opcode_t     opcode
  );
    // The four stash snoops have no encoding constant in this package, so no
    // modelled opcode can reach the DoNotDataPull reading. The issue test is
    // kept because it is half the specification's rule.
    if (issue != VIP_CHI_ISSUE_D_E) begin
      return 1'b0;
    end
    case (opcode)
      default: begin
        return 1'b0;
      end
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // Return TRUE when DoNotGoToSD must be set to 1 for an opcode. E 13.10.35
  // gives three lists rather than two: any value in the non-invalidating snoops,
  // MUST BE ONE in the invalidating and stash forms plus SnpQuery, and zero in
  // SnpDVMOp. D 12.9.32 has no must-be-one list at all -- there the field is
  // applicable and takes any value outside the stash and DVM opcodes -- so this
  // is a place where the two issues genuinely differ rather than one being a
  // clarification of the other.
  //
  // A boolean answers it because the third case is unreachable here: the
  // must-be-zero opcode is SnpDVMOp, and DVM is a recorded non-goal
  // (FUTURE_WORK.md). Modelling DVM means giving this a three-valued answer.
  // Restricted to modelled opcodes for the same reason: SnpQuery,
  // SnpPreferUnique*, SnpNotSharedDirty and the stash forms have no encoding in
  // this package, so naming them would assert a reading no traffic here can
  // confirm or refute.
  // ---------------------------------------------------------------------------
  // Return TRUE when the snoop is a Forward type, the only kind in which FwdNID
  // and FwdTxnID are applicable. E 13.10.5: FwdNID is "Applicable in Forward
  // type snoops", "Inapplicable and must be zero in all other Snoop requests".
  // E 13.10.16 says the same of FwdTxnID and adds that the same bits carry
  // StashLPID in stash snoops and VMIDExt in SnpDVMOp -- neither of which is
  // modelled, so among the opcodes here the field is FwdTxnID or it is zero.
  //
  // Encoding-derived rather than listed: Chapter 12/13 give every Forward snoop
  // its non-forward opcode with bit[4] set. Reading the bit means a Forward
  // opcode added later is classified without touching this function -- and the
  // opcode constants carry that relationship in their own comment.
  // ---------------------------------------------------------------------------
  function automatic bit vip_chi_snp_opcode_is_forwarding(
    input vip_chi_snp_opcode_t opcode
  );
    return opcode[4];
  endfunction

  // ---------------------------------------------------------------------------
  // Return TRUE when RetToSrc must be zero for an opcode. IHI 0050 E 4.9 / D 4.9
  // -- identical text in both issues -- "RetToSrc is applicable and must be set
  // to zero in: Stash snoops. SnpCleanShared, SnpCleanInvalid, and
  // SnpMakeInvalid, SnpOnceFwd and SnpUniqueFwd", any value in all other snoops
  // except SnpDVMOp, and zero in SnpDVMOp.
  //
  // Note what that list is NOT. It is not "the invalidating snoops": SnpUnique
  // invalidates and may carry ANY RetToSrc value, while SnpCleanShared and
  // SnpOnceFwd do not invalidate and must carry zero. A rule written from the
  // shape of the opcode rather than from 4.9 would both miss two opcodes and
  // false-fail conformant SnpUnique traffic.
  //
  // The section carries one further rule that is deliberately not here: "Home
  // must only set RetToSrc on the Snoop request to a single Request Node." That
  // is a constraint across the several snoops of one transaction, and no single
  // interface sees them all -- it belongs to a component with a transaction
  // view, not to a link checker.
  // ---------------------------------------------------------------------------
  function automatic bit vip_chi_snp_ret_to_src_must_be_zero(
    input vip_chi_snp_opcode_t opcode
  );
    case (opcode)
      VIP_CHI_SNP_CLEAN_SHARED_E,
      VIP_CHI_SNP_CLEAN_INVALID_E,
      VIP_CHI_SNP_MAKE_INVALID_E,
      VIP_CHI_SNP_ONCE_FWD_E,
      VIP_CHI_SNP_UNIQUE_FWD_E: begin
        return 1'b1;
      end
      default: begin
        return 1'b0;
      end
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  function automatic bit vip_chi_snp_do_not_go_to_sd_required(
    input vip_chi_issue_t      issue,
    input vip_chi_snp_opcode_t opcode
  );
    if (vip_chi_snp_bit_is_do_not_data_pull(issue, opcode)) begin
      // The bit is not DoNotGoToSD at all here, so it carries no requirement.
      return 1'b0;
    end
    if (issue != VIP_CHI_ISSUE_E_E) begin
      return 1'b0;
    end
    case (opcode)
      VIP_CHI_SNP_UNIQUE_E,
      VIP_CHI_SNP_UNIQUE_FWD_E,
      VIP_CHI_SNP_CLEAN_SHARED_E,
      VIP_CHI_SNP_CLEAN_INVALID_E,
      VIP_CHI_SNP_MAKE_INVALID_E: begin
        return 1'b1;
      end
      default: begin
        return 1'b0;
      end
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // ---------------------------------------------------------------------------
  // Three-valued because Table 2-14 is: its two columns give "Y -", "- Y" and
  // "Y Y", and collapsing those to a boolean loses the difference between "must
  // be zero" and "may be either".
  typedef enum int {
    VIP_CHI_SNP_ATTR_ANY_E,
    VIP_CHI_SNP_ATTR_ZERO_E,
    VIP_CHI_SNP_ATTR_ONE_E
  } vip_chi_snp_attr_req_t;

  // What SnpAttr value this opcode is permitted to carry.
  //
  // IHI 0050 E Table 2-14 / D Table 2-14, "Snoop attributes for the different
  // transaction types".
  //
  // TOTAL: an opcode the table does not constrain returns ANY, so a caller may
  // apply this to every request without first asking what kind it is.
  //
  // Two normative tightenings are deliberately NOT applied here. Section 2.9.6
  // requires SnpAttr = 0 in a CMO, an Atomic, and ReadNoSnp/ReadNoSnpSep "from
  // Home to Slave", and section 2.9.3 requires it in ANY request from HN to SN.
  // Both are properties of the link rather than of the opcode, and whether a
  // given link is Home-to-Slave is not decidable from a role parameter here --
  // the same limitation vip_chi_req_order_legal records for Order = 0b01. A rule
  // that runs on every request must under-report rather than fail conformant
  // traffic, so the opcode half is what this answers.
  function automatic vip_chi_snp_attr_req_t vip_chi_snp_attr_requirement(
    input vip_chi_req_opcode_t opcode
  );

    // The "- Y" rows: Snoopable only. Every one of these is a coherent
    // transaction, which is why modeling this bit as DoDWT alone put the whole
    // coherent traffic class on the wire marked Non-snoopable.
    case (opcode)
      VIP_CHI_REQ_READ_ONCE_E,
      VIP_CHI_REQ_READ_CLEAN_E,
      VIP_CHI_REQ_READ_SHARED_E,
      VIP_CHI_REQ_READ_UNIQUE_E,
      VIP_CHI_REQ_MAKE_READ_UNIQUE_E,
      VIP_CHI_REQ_CLEAN_UNIQUE_E,
      VIP_CHI_REQ_MAKE_UNIQUE_E,
      VIP_CHI_REQ_EVICT_E,
      VIP_CHI_REQ_WRITE_BACK_FULL_E,
      VIP_CHI_REQ_WRITE_CLEAN_FULL_E,
      VIP_CHI_REQ_WRITE_EVICT_OR_EVICT_E,
      VIP_CHI_REQ_WRITE_UNIQUE_FULL_E,
      VIP_CHI_REQ_WRITE_UNIQUE_PTL_E,
      VIP_CHI_REQ_WRITE_UNIQUE_ZERO_E: begin
        return VIP_CHI_SNP_ATTR_ONE_E;
      end
      default: begin
      end
    endcase

    // The "Y -" rows: Non-snoopable only. Every Combined Write this VIP models
    // is a WriteNoSnp, so the family inherits the write half's requirement.
    if (vip_chi_req_opcode_is_combined_write_cmo(opcode)) begin
      return VIP_CHI_SNP_ATTR_ZERO_E;
    end
    case (opcode)
      VIP_CHI_REQ_READ_NO_SNP_E,
      VIP_CHI_REQ_READ_NO_SNP_SEP_E,
      VIP_CHI_REQ_WRITE_NO_SNP_FULL_E,
      VIP_CHI_REQ_WRITE_NO_SNP_PTL_E,
      VIP_CHI_REQ_WRITE_NO_SNP_ZERO_E: begin
        return VIP_CHI_SNP_ATTR_ZERO_E;
      end
      default: begin
      end
    endcase

    // The "Y Y" rows -- the four CMOs and the Atomics -- plus PrefetchTgt, which
    // the table marks not applicable and free to take any value, plus the credit
    // returns the table does not list at all.
    return VIP_CHI_SNP_ATTR_ANY_E;
  endfunction

  // The MemAttr value this opcode must carry, where the specification fixes it.
  //
  // IHI 0050 E section 2.9.3, the assertion-requirement lists under EWA,
  // Cacheable and Allocate:
  //
  //   EWA       "Must be asserted in any Read or Dataless transaction that is
  //             not a ReadNoSnp, ReadNoSnpSep, or CMO transaction" and "in any
  //             Write transaction that is not a WriteNoSnp transaction".
  //   Cacheable "Must be asserted for any Read transaction except for ReadNoSnp
  //             and ReadNoSnpSep", "any Dataless transaction except for
  //             CleanShared, CleanSharedPersist*, CleanInvalid, MakeInvalid",
  //             and "any Write transaction except WriteNoSnpFull and
  //             WriteNoSnpPtl".
  //   Allocate  "Must be asserted for the WriteEvictFull transaction", "Is
  //             inapplicable and must be set to zero in DVMOp, PCrdReturn and
  //             Evict transactions", and otherwise only "Can be asserted".
  //
  // Where the specification leaves a field free the answer here is zero, which
  // is Non-cacheable Non-bufferable -- a legal Table 2-12 row and what this VIP
  // has always driven. So this changes the wire image for exactly the opcodes
  // that were non-conformant: the fourteen Snoopable-only ones, and
  // WriteNoSnpZero, whose Cacheable the Write rule above does not except.
  //
  // Cacheable implies EWA here rather than merely permitting it, because Table
  // 2-12 lists no row with Cacheable = 1 and EWA = 0.
  function automatic logic [3 : 0] vip_chi_req_mem_attr_default(
    input vip_chi_req_opcode_t opcode
  );

    bit allocate, cacheable, ewa;

    allocate  = 1'b0;
    cacheable = 1'b0;
    ewa       = 1'b0;

    case (opcode)
      // Coherent reads and Dataless: neither a ReadNoSnp form nor a CMO, so both
      // Cacheable and EWA are required. Then the coherent writes, none of which
      // is a WriteNoSnp, so both are required there too.
      VIP_CHI_REQ_READ_ONCE_E,
      VIP_CHI_REQ_READ_CLEAN_E,
      VIP_CHI_REQ_READ_SHARED_E,
      VIP_CHI_REQ_READ_UNIQUE_E,
      VIP_CHI_REQ_MAKE_READ_UNIQUE_E,
      VIP_CHI_REQ_CLEAN_UNIQUE_E,
      VIP_CHI_REQ_MAKE_UNIQUE_E,
      VIP_CHI_REQ_EVICT_E,
      VIP_CHI_REQ_WRITE_BACK_FULL_E,
      VIP_CHI_REQ_WRITE_CLEAN_FULL_E,
      VIP_CHI_REQ_WRITE_EVICT_OR_EVICT_E,
      VIP_CHI_REQ_WRITE_UNIQUE_FULL_E,
      VIP_CHI_REQ_WRITE_UNIQUE_PTL_E,
      VIP_CHI_REQ_WRITE_UNIQUE_ZERO_E,
      // A Write, so Cacheable is required -- the exception list names only
      // WriteNoSnpFull and WriteNoSnpPtl. EWA is free here, but Table 2-12 has
      // no Cacheable row without it.
      VIP_CHI_REQ_WRITE_NO_SNP_ZERO_E: begin
        cacheable = 1'b1;
        ewa       = 1'b1;
      end
      default: begin
      end
    endcase

    // Section 2.9.3 requires Allocate on a WriteEvictFull and does not name
    // WriteEvictOrEvict, so asserting it here is a choice rather than the
    // letter of the text -- but it is the choice that makes the opcode mean
    // what it says. The note under that bullet reads "A Requester can convert a
    // WriteEvictFull with the Allocate bit not asserted to an Evict
    // transaction", so Allocate is exactly what separates this opcode's
    // WriteEvictFull leg from its Evict leg. Both values are Table 2-12 legal
    // (rows 9 and 8 respectively), so this is not a conformance question.
    // Plain Evict is on the inapplicable-and-zero list and keeps Allocate low.
    if (opcode == VIP_CHI_REQ_WRITE_EVICT_OR_EVICT_E) begin
      allocate = 1'b1;
    end

    // {Allocate, Cacheable, Device, EWA} -- Table 13-21 bit order. Device is
    // zero throughout: this VIP models no Device-memory stimulus, and a Device
    // request is a different Table 2-12 block entirely.
    return {allocate, cacheable, 1'b0, ewa};
  endfunction

  // TRUE when Endian is a field this opcode carries at all.
  //
  // IHI 0050 E Table A-3, Endian column: "Y" on the four Atomic opcodes, "X" --
  // inapplicable, any value -- on PrefetchTgt, and "0" on every other request
  // this VIP models. Endian selects the byte order of an Atomic's operand, so it
  // has nothing to say about a plain read or write, and the table says so by
  // requiring zero rather than by leaving it free.
  //
  // PrefetchTgt is permitted here rather than faulted, for the reason the
  // LikelyShared rule gives: "X" means any value, so asserting it is not a
  // violation.
  //
  // TOTAL: returns TRUE for everything it does not object to.
  function automatic bit vip_chi_req_endian_applicable(
    input vip_chi_req_opcode_t opcode
  );
    if (vip_chi_req_opcode_is_atomic(opcode)) begin
      return 1'b1;
    end
    return (opcode == VIP_CHI_REQ_PREFETCH_TGT_E);
  endfunction

  // TRUE when this opcode supports an Exclusive access, so may assert Excl.
  //
  // IHI 0050 E section 6.3 "Exclusive transactions" opens with "The following
  // transaction types support Exclusive accesses through an Excl bit" and then
  // names them, which makes it a closed list:
  //
  //   Exclusive Load, Snoopable location   ReadClean, ReadNotSharedDirty,
  //                                        ReadShared, ReadPreferUnique
  //   Exclusive Store, Snoopable location  CleanUnique, MakeReadUnique
  //   Exclusive Load, Non-snoopable        ReadNoSnp
  //   Exclusive Store, Non-snoopable       WriteNoSnp
  //
  // A consolidated list is why this is a rule and the neighbouring Excl
  // constraints are not: Chapter 4 states the same permission per opcode, spread
  // across forty request descriptions as "Can have exclusive attribute
  // asserted", and a whitelist assembled from those would be a transcription
  // exercise with no way to tell a missed bullet from an opcode that genuinely
  // forbids it.
  //
  // "WriteNoSnp" in that list means the Full and Ptl forms only, NOT
  // WriteNoSnpZero. Section 6.3 does not qualify the name, and a permissive
  // reading was the first thing tried here -- but Table A-3 does qualify it: the
  // Excl column gives WriteNoSnpFull and WriteNoSnpPtl "Y" and WriteNoSnpZero
  // "0", applicable-and-must-be-zero. The table is the finer authority on a
  // per-opcode question, and it makes sense: an Exclusive store has to write the
  // data it was granted exclusivity for, and WriteNoSnpZero carries none.
  //
  // TOTAL: returns TRUE for everything it does not object to.
  function automatic bit vip_chi_req_excl_permitted(
    input vip_chi_req_opcode_t opcode
  );
    case (opcode)
      VIP_CHI_REQ_READ_CLEAN_E,
      VIP_CHI_REQ_READ_SHARED_E,
      VIP_CHI_REQ_CLEAN_UNIQUE_E,
      VIP_CHI_REQ_MAKE_READ_UNIQUE_E,
      VIP_CHI_REQ_READ_NO_SNP_E,
      VIP_CHI_REQ_WRITE_NO_SNP_FULL_E,
      VIP_CHI_REQ_WRITE_NO_SNP_PTL_E: begin
        return 1'b1;
      end
      default: begin
        return 1'b0;
      end
    endcase
  endfunction

  // TRUE when Table A-3 fixes this opcode's Size at 64 bytes.
  //
  // IHI 0050 E Table A-3 "Request message field mappings part 2" (read from the
  // PDF, physical page 468) gives a literal "64B" in the Size column for these
  // opcodes and a plain "Y" -- any legal value -- for the rest. Chapter 4 says
  // the same thing per opcode in prose: "Data size is a cache line length" for
  // the fixed ones against "Data size is up to a cache line length" for the
  // others.
  //
  // The Combined Write family SPLITS here and must not be treated as one class:
  // Table A-3 gives WriteNoSnpFull(CMO) 64B and WriteNoSnpPtl(CMO) any. That
  // follows the write half, which is the same rule Table 2-14 and the CompAck
  // table use for this family.
  //
  // Size = 0b110 is 64 bytes (Table 2-15). It is independent of the data bus
  // width: a 64-byte transfer is four beats on a 16-byte bus.
  function automatic bit vip_chi_req_size_fixed_64b(
    input vip_chi_req_opcode_t opcode
  );
    case (opcode)
      // Coherent reads.
      VIP_CHI_REQ_READ_SHARED_E,
      VIP_CHI_REQ_READ_CLEAN_E,
      VIP_CHI_REQ_READ_ONCE_E,
      VIP_CHI_REQ_READ_UNIQUE_E,
      VIP_CHI_REQ_MAKE_READ_UNIQUE_E,
      // Dataless, including the CMOs.
      VIP_CHI_REQ_CLEAN_SHARED_E,
      VIP_CHI_REQ_CLEAN_SHARED_PERSIST_E,
      VIP_CHI_REQ_CLEAN_SHARED_PERSIST_SEP_E,
      VIP_CHI_REQ_CLEAN_INVALID_E,
      VIP_CHI_REQ_MAKE_INVALID_E,
      VIP_CHI_REQ_CLEAN_UNIQUE_E,
      VIP_CHI_REQ_MAKE_UNIQUE_E,
      VIP_CHI_REQ_EVICT_E,
      // CopyBack and the full writes.
      VIP_CHI_REQ_WRITE_BACK_FULL_E,
      VIP_CHI_REQ_WRITE_CLEAN_FULL_E,
      VIP_CHI_REQ_WRITE_EVICT_OR_EVICT_E,
      VIP_CHI_REQ_WRITE_UNIQUE_FULL_E,
      VIP_CHI_REQ_WRITE_UNIQUE_ZERO_E,
      VIP_CHI_REQ_WRITE_NO_SNP_FULL_E,
      VIP_CHI_REQ_WRITE_NO_SNP_ZERO_E,
      // Combined Write, Full forms only.
      VIP_CHI_REQ_WRITE_NO_SNP_FULL_CLEAN_SH_E,
      VIP_CHI_REQ_WRITE_NO_SNP_FULL_CLEAN_INV_E,
      VIP_CHI_REQ_WRITE_NO_SNP_FULL_CLEAN_SH_PER_SEP_E: begin
        return 1'b1;
      end
      default: begin
        return 1'b0;
      end
    endcase
  endfunction

  // TRUE when this opcode is permitted to assert LikelyShared.
  //
  // IHI 0050 E section 2.9.5. The section gives a named whitelist and then closes
  // it twice over: "Must not be asserted in any other Read, Write or Combined
  // Write transaction" and "Must not be asserted in any Dataless or Atomic
  // transaction". DVMOp and PCrdReturn are inapplicable-and-must-be-zero;
  // PrefetchTgt is inapplicable but may carry any value, so it is permitted here
  // rather than faulted.
  //
  // This is STRICTLY NARROWER than what Table 2-12 implies, which is why it earns
  // its own rule. The table shows LikelyShared as 0/1 only on its two Snoopable
  // rows, so the tuple rule faults it on any Non-snoopable request -- but section
  // 2.9.5 also forbids it on ReadOnce, ReadUnique, MakeReadUnique, CleanUnique,
  // MakeUnique and Evict, every one of which is Snoopable only and therefore
  // passes the tuple rule. A hint that means "this line is likely shared" is only
  // meaningful where the transaction leaves a shareable copy behind, and those
  // six do not.
  //
  // TOTAL: returns TRUE for everything it does not object to, so the rule that
  // calls it evaluates on every request.
  function automatic bit vip_chi_req_likely_shared_permitted(
    input vip_chi_req_opcode_t opcode
  );
    case (opcode)
      VIP_CHI_REQ_READ_CLEAN_E,
      VIP_CHI_REQ_READ_SHARED_E,
      VIP_CHI_REQ_WRITE_UNIQUE_PTL_E,
      VIP_CHI_REQ_WRITE_UNIQUE_FULL_E,
      VIP_CHI_REQ_WRITE_UNIQUE_ZERO_E,
      VIP_CHI_REQ_WRITE_BACK_FULL_E,
      VIP_CHI_REQ_WRITE_CLEAN_FULL_E,
      // Named in the list in its own right, alongside WriteEvictFull.
      VIP_CHI_REQ_WRITE_EVICT_OR_EVICT_E,
      // Inapplicable, "can take any value" -- not a violation to assert.
      VIP_CHI_REQ_PREFETCH_TGT_E: begin
        return 1'b1;
      end
      default: begin
        return 1'b0;
      end
    endcase
  endfunction

  // TRUE when this request's {MemAttr, SnpAttr, LikelyShared, Order} tuple is one
  // of the nine Table 2-12 permits.
  //
  // IHI 0050 E Table 2-12 / D Table 2-12, "Legal combinations of MemAttr,
  // SnpAttr, and Order field values". The table lists nine rows and closes each
  // of its two blocks with "All other values -- Not valid", so it is a whitelist
  // and every tuple outside it is a protocol error, not merely unusual.
  //
  // MemAttr bit positions are Table 13-21's: [3] Allocate, [2] Cacheable,
  // [1] Device (0 Normal, 1 Device), [0] EWA.
  //
  // This judges the tuple only. The per-opcode restrictions that also bear on
  // these fields live elsewhere on purpose: Order's opcode whitelist is
  // vip_chi_req_order_legal, and section 2.9.5 additionally restricts
  // LikelyShared to a named list of opcodes, which is narrower than the "must be
  // Snoopable" this table implies. Splitting them keeps each rule's report
  // naming one reason rather than several.
  function automatic bit vip_chi_req_attr_combination_legal(
    input logic [3 : 0]       mem_attr,
    input vip_chi_snp_attr_t  snp_attr,
    input logic               likely_shared,
    input vip_chi_req_order_t order
  );

    bit allocate, cacheable, device, ewa, snoopable, unordered_or_req_order;

    allocate  = mem_attr[3];
    cacheable = mem_attr[2];
    device    = mem_attr[1];
    ewa       = mem_attr[0];
    snoopable = (snp_attr == VIP_CHI_SNP_SNOOPABLE_E);

    // Every row but the two Endpoint-Order Device ones carries Order[0] = 0,
    // which leaves 0b00 and 0b10.
    //
    // 0b01 appears in no row, and footnote b says why: "Order = 0b01 is not used
    // for transactions' ordering". It is a Request-accepted signal rather than an
    // ordering requirement, so this table has nothing to say about it and such a
    // request is judged on its MemAttr alone. Faulting it here would fail
    // conformant traffic: ReadNoSnpSep is REQUIRED to carry 0b01 (Chapter 4, "The
    // Order field of the request must be set to b01"), and whether a given opcode
    // may carry it is vip_chi_req_order_legal's business, not this rule's.
    unordered_or_req_order = (order == VIP_CHI_ORDER_NONE_E) ||
                             (order == VIP_CHI_ORDER_REQ_ORDER_E) ||
                             (order == VIP_CHI_ORDER_REQ_ACCEPTED_E);

    if (device) begin
      // The three Device rows are Allocate = 0, Cacheable = 0, SnpAttr = 0 and
      // LikelyShared = 0 without exception.
      if (allocate || cacheable || snoopable || likely_shared) begin
        return 1'b0;
      end
      // Device nRnE is the only row with EWA = 0, and it is Endpoint Order.
      // 0b01 stands down here too, for the footnote-b reason above.
      if (!ewa) begin
        return (order == VIP_CHI_ORDER_ENDPOINT_E) ||
               (order == VIP_CHI_ORDER_REQ_ACCEPTED_E);
      end
      // EWA = 1 covers both Device nRE (Endpoint Order) and Device RE.
      return (order == VIP_CHI_ORDER_ENDPOINT_E) || unordered_or_req_order;
    end

    // Normal memory. No row here takes Endpoint Order.
    if (!unordered_or_req_order) begin
      return 1'b0;
    end
    // LikelyShared is 0/1 only on the two Snoopable rows.
    if (likely_shared && !snoopable) begin
      return 1'b0;
    end
    if (snoopable) begin
      // Snoopable WriteBack, No-allocate or Allocate: both require Cacheable
      // and EWA. This is the pairing that makes SnpAttr = 1 over a zero MemAttr
      // illegal rather than merely odd.
      return cacheable && ewa;
    end
    if (!cacheable) begin
      // Non-cacheable Non-bufferable and Non-cacheable Bufferable, differing
      // only in EWA. Neither allocates -- section 2.9.3, "Must not be asserted
      // for Normal Non-cacheable memory transactions".
      return !allocate;
    end
    // Non-snoopable WriteBack, No-allocate or Allocate: Cacheable implies EWA.
    return ewa;
  endfunction

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
      // Table 13-6 / 12-6 stack SnpAttr over DoDWT on this bit, and SnpAttr is
      // the name both issues have. See vip_chi_snp_attr_t.
      vip_chi_snp_attr_t  snpattr;
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
      mpam_t           mpam;
      logic            tracetag;
      logic            rettosrc;
      logic            donotgotosd;
      vip_chi_req_ns_t ns;
      addr_t           addr;
      snp_opcode_t     opcode;
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
      // Table 13-6 / 12-6 stack SnpAttr over DoDWT on this bit, and SnpAttr is
      // the name both issues have. See vip_chi_snp_attr_t.
      vip_chi_snp_attr_t  snpattr;
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
      mpam_t           mpam;
      logic            tracetag;
      logic            rettosrc;
      logic            donotgotosd;
      vip_chi_req_ns_t ns;
      addr_t           addr;
      snp_opcode_t     opcode;
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
      // Table 13-6 / 12-6 stack SnpAttr over DoDWT on this bit, and SnpAttr is
      // the name both issues have. See vip_chi_snp_attr_t.
      vip_chi_snp_attr_t  snpattr;
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
      mpam_t           mpam;
      logic            tracetag;
      logic            rettosrc;
      logic            donotgotosd;
      vip_chi_req_ns_t ns;
      addr_t           addr;
      snp_opcode_t     opcode;
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