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

`ifndef VIP_CHI_SCOREBOARD
`define VIP_CHI_SCOREBOARD

import uvm_pkg::*;
`include "uvm_macros.svh"
import vip_chi_types_pkg::*;

// -----------------------------------------------------------------------------
// Standalone, always-on protocol scoreboard for the vip_chi example.
//
// The example is a DUT-less VIP-on-VIP setup (RN-I <-> SN-F, plus an HN-I proxy
// fan-in/xbar), so this scoreboard checks transaction/protocol consistency
// between the two agents rather than DUT-vs-reference. Three checkers share one
// transaction table keyed in the requester frame:
//
//   A - lifecycle / completion contract (per requester transaction)
//   B - cross-agent request fidelity (REQ observed at requester == at completer)
//   C - independent, predictable-only data integrity (write->read)
//   E - ordered-stream acknowledgement order (per requester ordered stream)
//
// It connects in parallel to the same monitor analysis ports the observation
// FIFOs and coverage already use, so the per-test FIFO draining is untouched.
// -----------------------------------------------------------------------------

// Which requester stream an observation arrived on (TxnID alone is not unique
// across the integrated pair and the two proxy RNs).
typedef enum int {
  VIP_CHI_SB_STREAM_RNI,
  VIP_CHI_SB_STREAM_HRNI0,
  VIP_CHI_SB_STREAM_HRNI1
} vip_chi_sb_stream_e;

// Coarse transaction class used to pick the completion contract.
typedef enum int {
  VIP_CHI_SB_READ,
  VIP_CHI_SB_WRITE,
  VIP_CHI_SB_WRITE_NODATA,
  VIP_CHI_SB_ATOMIC,
  VIP_CHI_SB_PERSIST,
  VIP_CHI_SB_PERSIST_SEP,
  VIP_CHI_SB_PREFETCH,
  VIP_CHI_SB_OTHER
} vip_chi_sb_kind_e;

// -----------------------------------------------------------------------------
// Per-transaction context. A class (not a struct) so the primary table and the
// DBID side-index can hold handles to the same object.
// -----------------------------------------------------------------------------
class vip_chi_sb_ctx #(
  vip_chi_cfg_t CFG_P = VIP_CHI_DEFAULT_CFG_C
  );

  typedef vip_chi_item #(CFG_P)  item_t;
  typedef item_t::node_id_t      node_id_t;
  typedef item_t::addr_t         addr_t;
  typedef item_t::txn_id_t       txn_id_t;
  typedef item_t::size_t         size_t;
  typedef item_t::req_opcode_t   req_opcode_t;
  typedef item_t::data_t         data_t;
  typedef item_t::tag_t          tag_t;
  typedef item_t::tu_t           tu_t;
  typedef item_t::tagop_t        tagop_t;

  // Identity (the normalized key).
  vip_chi_sb_stream_e stream;
  node_id_t           requester_node;   // src_id of the REQ == tgt_id of completions
  txn_id_t            txn_id;

  // Request attributes captured once at REQ.
  addr_t              addr;
  size_t              size;
  req_opcode_t        opcode;
  vip_chi_sb_kind_e   kind;
  bit                 ordered;
  bit                 exp_comp_ack;
  bit                 allow_retry;

  // Checker E position. order_val is the REQ Order field verbatim; ord_key names
  // the stream FIFO this transaction was enrolled in, so it can be withdrawn
  // again without searching every stream.
  bit [1:0]           order_val;
  string              ord_key;
  bit                 ord_enrolled;

  // Separated read (ReadNoSnpSep): the DataSepResp data leg returns on
  // ReturnNID/ReturnTxnID rather than the original requester TxnID, so the ctx
  // is also indexed by (stream, return_nid, return_txn_id) to match that leg.
  bit                 sep_read;
  node_id_t           return_nid;
  txn_id_t            return_txn_id;

  // Completion contract: which milestones are REQUIRED to retire.
  bit  need_grant, need_write_data, need_read_data, need_comp;
  bit  need_receipt, need_persist, need_compack;
  // The CMO half of a combined Write + CMO. A separate milestone from the
  // write's own completion, because that is what it is on the wire: a completer
  // that answered a combined request with the write completion alone would leave
  // the CMO outstanding, and without this the scoreboard would retire the
  // transaction anyway and never notice.
  bit  need_comp_cmo;

  // Milestones OBSERVED.
  bit  grant_seen, write_data_sent, read_data_seen, comp_seen;
  bit  receipt_seen, persist_seen, compack_seen;
  bit  comp_cmo_seen;
  bit  retry_seen, pcrd_seen;

  txn_id_t            dbid;
  bit                 retired;

  // Checker C: hold the observed write-DAT until the completion resolves so the
  // predicted image only commits data that actually landed (OKAY completion).
  item_t              wr_dat_item;
  bit                 wr_committed;
  vip_chi_resp_err_t  comp_err;

  // Checker C atomic RMW prediction: the target's pre-op value is captured off
  // pred_mem when the operand DAT is observed (before the target is invalidated
  // for the RMW window). At completion the new value is recomputed and committed
  // and, for returning atomics, the CompData is compared against this pre-op
  // value. atomic_old_valid is 0 when any target byte was unknown (unpredictable).
  data_t              atomic_old [];
  bit                 atomic_old_valid;
  bit                 atomic_resolved;

  function new();
    this.comp_err = VIP_CHI_RESP_ERR_NORMAL_OKAY_E;
  endfunction

  // All required milestones observed?
  function bit contract_met();
    return (!need_grant      || grant_seen)
        && (!need_write_data || write_data_sent)
        && (!need_read_data  || read_data_seen)
        && (!need_comp       || comp_seen)
        && (!need_receipt    || receipt_seen)
        && (!need_persist    || persist_seen)
        && (!need_compack    || compack_seen)
        && (!need_comp_cmo   || comp_cmo_seen);
  endfunction

  // Reset completion state for a legitimate retry re-issue (keep identity).
  function void reset_milestones();
    this.grant_seen      = 1'b0;
    this.write_data_sent = 1'b0;
    this.read_data_seen  = 1'b0;
    this.comp_seen       = 1'b0;
    this.receipt_seen    = 1'b0;
    this.persist_seen    = 1'b0;
    this.compack_seen    = 1'b0;
    this.comp_cmo_seen   = 1'b0;
    this.retry_seen      = 1'b0;
    this.pcrd_seen       = 1'b0;
    this.retired         = 1'b0;
    this.wr_dat_item     = null;
    this.wr_committed    = 1'b0;
    this.comp_err        = VIP_CHI_RESP_ERR_NORMAL_OKAY_E;
    this.atomic_old      = {};
    this.atomic_old_valid = 1'b0;
    this.atomic_resolved = 1'b0;
  endfunction

endclass

// -----------------------------------------------------------------------------
// Analysis imps: requester streams feed Checkers A & C, completer req streams
// feed Checker B fidelity only. Suffixes are globally unique (_sb).
// -----------------------------------------------------------------------------
`uvm_analysis_imp_decl(_rni_req_sb)
`uvm_analysis_imp_decl(_rni_rsp_sb)
`uvm_analysis_imp_decl(_rni_dat_sb)
`uvm_analysis_imp_decl(_hrni0_req_sb)
`uvm_analysis_imp_decl(_hrni0_rsp_sb)
`uvm_analysis_imp_decl(_hrni0_dat_sb)
`uvm_analysis_imp_decl(_hrni1_req_sb)
`uvm_analysis_imp_decl(_hrni1_rsp_sb)
`uvm_analysis_imp_decl(_hrni1_dat_sb)
`uvm_analysis_imp_decl(_snf_req_sb)
`uvm_analysis_imp_decl(_hsnf0_req_sb)
`uvm_analysis_imp_decl(_hsnf1_req_sb)

class vip_chi_scoreboard #(
  vip_chi_cfg_t CFG_P = VIP_CHI_DEFAULT_CFG_C
  ) extends uvm_component;

  `uvm_component_param_utils(vip_chi_scoreboard #(CFG_P))

  typedef vip_chi_item #(CFG_P)  item_t;
  typedef item_t::node_id_t      node_id_t;
  typedef item_t::addr_t         addr_t;
  typedef item_t::txn_id_t       txn_id_t;
  typedef item_t::size_t         size_t;
  typedef item_t::req_opcode_t   req_opcode_t;
  typedef item_t::rsp_opcode_t   rsp_opcode_t;
  typedef item_t::dat_opcode_t   dat_opcode_t;
  typedef item_t::data_t         data_t;
  typedef item_t::tag_t          tag_t;
  typedef item_t::tu_t           tu_t;
  typedef item_t::tagop_t        tagop_t;
  typedef vip_chi_sb_ctx #(CFG_P) ctx_t;

  localparam int DATA_BYTES_C = CFG_P.DATA_BYTES_P;

  // Gating knobs, set by the env from tb_cfg in connect_phase.
  bit enable      = 1'b1;  // master on/off (A + B + C + E)
  bit check_data  = 1'b1;  // Checker C on/off (A + B still run)
  bit check_order = 1'b1;  // Checker E on/off (A + B + C still run)

  // Checker B HN-I routing prediction: the env hands over the exact routing
  // policy the HN-I driver uses (port count, stride LSB, optional SAM) so the
  // scoreboard can independently re-derive each request's SN target from its
  // address and confirm it landed on that port. route_check stays off (nothing
  // to prove) when there is a single SN target. See set_route_policy().
  bit             route_check = 1'b0;
  int             n_sn_ports  = 1;
  int unsigned    sn_addr_lsb = 12;
  vip_chi_hni_sam hni_sam;     // null => stride decode (mirrors the driver)

  // Requester views (integrated + both proxy RNs).
  uvm_analysis_imp_rni_req_sb   #(item_t, vip_chi_scoreboard #(CFG_P)) rni_req_sb;
  uvm_analysis_imp_rni_rsp_sb   #(item_t, vip_chi_scoreboard #(CFG_P)) rni_rsp_sb;
  uvm_analysis_imp_rni_dat_sb   #(item_t, vip_chi_scoreboard #(CFG_P)) rni_dat_sb;
  uvm_analysis_imp_hrni0_req_sb #(item_t, vip_chi_scoreboard #(CFG_P)) hrni0_req_sb;
  uvm_analysis_imp_hrni0_rsp_sb #(item_t, vip_chi_scoreboard #(CFG_P)) hrni0_rsp_sb;
  uvm_analysis_imp_hrni0_dat_sb #(item_t, vip_chi_scoreboard #(CFG_P)) hrni0_dat_sb;
  uvm_analysis_imp_hrni1_req_sb #(item_t, vip_chi_scoreboard #(CFG_P)) hrni1_req_sb;
  uvm_analysis_imp_hrni1_rsp_sb #(item_t, vip_chi_scoreboard #(CFG_P)) hrni1_rsp_sb;
  uvm_analysis_imp_hrni1_dat_sb #(item_t, vip_chi_scoreboard #(CFG_P)) hrni1_dat_sb;
  // Completer-side req (Checker B fidelity is REQ<->REQ).
  uvm_analysis_imp_snf_req_sb   #(item_t, vip_chi_scoreboard #(CFG_P)) snf_req_sb;
  uvm_analysis_imp_hsnf0_req_sb #(item_t, vip_chi_scoreboard #(CFG_P)) hsnf0_req_sb;
  uvm_analysis_imp_hsnf1_req_sb #(item_t, vip_chi_scoreboard #(CFG_P)) hsnf1_req_sb;

  // Shared transaction table + DBID side-index (both hold the same handle).
  protected ctx_t open_ctx    [string];   // key: stream_reqnode_txn
  protected ctx_t ctx_by_dbid [string];   // key: stream_dbid  (binds write-DAT)
  protected ctx_t sep_ret_ctx [string];   // key: stream_returnnid_returntxn
                                           // (binds a ReadNoSnpSep DataSepResp)

  // Checker C: independent, byte-granular predicted image (observed writes only).
  protected byte  pred_mem [addr_t];
  protected bit   written  [addr_t];

  // Checker B: canonical-key request multisets, matched at check_phase.
  protected int   int_req_cnt [string];   // integrated requester (rni)
  protected int   int_cmp_cnt [string];   // integrated completer (snf)
  protected int   hni_req_cnt [string];   // proxy requester (hrni*)
  protected int   hni_cmp_cnt [string];   // proxy completer (hsnf*)

  // Checker B routing: per-request multisets tagged with the SN port. The key
  // is "p<port>|<canon_key>", so a mis-route surfaces as a shortfall at the
  // predicted port AND a phantom at the observed port under the same compare.
  protected int   hni_route_pred [string]; // predicted target port per hrni REQ
  protected int   hni_route_obs  [string]; // observed arrival port per hsnf REQ

  // Checker E: one expected-acknowledgement FIFO per ordered stream. The key is
  // "stream_srcid_order" and the queue holds TxnIDs in the order the requester
  // issued them; the head is what the completer owes an acknowledgement for next.
  protected txn_id_t ord_fifo [string][$];

  // Per-rule tallies, the scoreboard's half of the per-check registry.
  //
  // PASSES are the point. Every scoreboard check here counted only its
  // failures, which makes a rule that never ran and a rule that always holds
  // produce the identical log -- and the whole regression could not tell them
  // apart. A pass count is what turns "no errors" into "compared N times and
  // none differed", and it is what the cross-run aggregation reads.
  //
  // The legacy n_* counters below are now FUNCTIONS derived from these rather
  // than fields kept beside them, so a new check site that forgets to bump its
  // rule cannot leave the summary line reading right while the export reads
  // zero.
  protected int                      chk_pass     [VIP_CHI_SB_CHK_NUM_E];
  protected int                      chk_fail     [VIP_CHI_SB_CHK_NUM_E];
  protected vip_chi_check_severity_t chk_severity [VIP_CHI_SB_CHK_NUM_E];

  // Advisory tallies, deliberately NOT rules: they count what the
  // predictable-only discipline SKIPPED, which is neither a pass nor a failure,
  // and they are the denominator that makes a zero-mismatch run readable.
  protected int n_reads_skipped;

  // Checker C, MTE half: the predicted TAG image, alongside pred_mem/written and
  // committed by the same rule (an observed write that resolved OKAY).
  //
  // Keyed by BEAT, not by byte, because a tag covers a whole beat's worth of
  // data in this VIP's model -- the SN-F stores one tag + tu per beat slot and
  // replays it. Predicting per byte would claim a granularity the model does not
  // have.
  //
  // What this checks is the store-and-replay path, which is what the VIP
  // actually implements: the tag that comes back must be the tag that went in.
  // It deliberately does NOT model TagOp semantics (Invalid / Transfer / Update /
  // Match), because the VIP does not either -- the completer replays TagOp
  // verbatim. A checker that invented those semantics would be checking itself.
  protected tag_t   pred_tag   [addr_t];
  protected tu_t    pred_tu    [addr_t];
  protected tagop_t pred_tagop [addr_t];
  protected bit   tag_written  [addr_t];
  protected int   n_tag_reads_skipped;
  // Tags actually COMPARED. Without it a clean run cannot tell a correct tag
  // path from one the scoreboard never predicted, which is the whole lesson of
  // the vacuity work: zero mismatches out of zero comparisons is not a pass.
  protected int   n_tag_checked;

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent);
    super.new(name, parent);

    foreach (this.chk_severity[i]) begin
      this.chk_severity[i] = VIP_CHI_CHK_SEV_ERROR_E;
    end
    // An unmodelled completion opcode has always been a warning: a genuinely
    // wrong completion still surfaces as an incomplete at check_phase, so
    // failing here would double-report the same defect.
    this.chk_severity[VIP_CHI_SB_CHK_COMPLETION_OPCODE_MODELLED_E] =
      VIP_CHI_CHK_SEV_WARNING_E;
  endfunction

  // ---------------------------------------------------------------------------
  // The per-rule tally.
  //
  // Reporting is unconditional, unlike the SVA checkers' severity handling, and
  // the difference is deliberate. There, a rule turned OFF is counted but
  // silent, which is what a negative control needs. Here the report IS the
  // verdict -- the scoreboard raises a uvm_error and the negative controls
  // assert, through a report catcher, that the message was actually emitted.
  // Suppressing it would delete the evidence those tests depend on, so severity
  // on this side declares INTENT for the export and nothing more; see
  // expect_failure.
  // ---------------------------------------------------------------------------
  protected function void chk_ok(input vip_chi_sb_check_id_t id);
    this.chk_pass[id]++;
  endfunction

  protected function void chk_bad(
    input vip_chi_sb_check_id_t id,
    input string                msg
  );
    this.chk_fail[id]++;
    if (this.chk_severity[id] == VIP_CHI_CHK_SEV_WARNING_E) begin
      `uvm_warning(get_name(), msg)
    end
    else begin
      `uvm_error(get_name(), msg)
    end
  endfunction

  // Declare that this run provokes `id` on purpose. Without it the cross-run
  // aggregation reads a negative control as a genuine regression failure -- the
  // run that PROVES a check fires would be reported as the check failing.
  // Per rule rather than per checker, so a second, unintended violation inside
  // the same run still stands out.
  function void expect_failure(input vip_chi_sb_check_id_t id);
    this.chk_severity[id] = VIP_CHI_CHK_SEV_OFF_E;
  endfunction

  // Whether this run could evaluate the rule at all. A rule standing down
  // because its knob is off was not exercised BY REQUEST, which is a different
  // thing from a hole: gating on a knob the user turned off would teach the
  // reader to ignore the report and hide the real gaps with it.
  function bit chk_rule_enabled(input vip_chi_sb_check_id_t id);
    if (!this.enable) begin
      return 1'b0;
    end
    case (id)
      VIP_CHI_SB_CHK_READ_DATA_MATCHES_E,
      VIP_CHI_SB_CHK_ATOMIC_RETURN_MATCHES_E,
      VIP_CHI_SB_CHK_READ_TAG_MATCHES_E,
      VIP_CHI_SB_CHK_READ_TAGOP_REPLAYED_E,
      VIP_CHI_SB_CHK_TAGOP_STABLE_ACROSS_BEATS_E: return this.check_data;
      VIP_CHI_SB_CHK_ORDERED_ACK_IN_ORDER_E:      return this.check_order;
      VIP_CHI_SB_CHK_REQ_ROUTED_E:                return this.route_check;
      default:                                    return 1'b1;
    endcase
  endfunction

  function int get_check_pass_count(input vip_chi_sb_check_id_t id);
    return this.chk_pass[id];
  endfunction

  function int get_check_fail_count(input vip_chi_sb_check_id_t id);
    return this.chk_fail[id];
  endfunction

  // ---------------------------------------------------------------------------
  // The legacy tallies, DERIVED from the registry rather than kept beside it.
  // ---------------------------------------------------------------------------
  protected function int n_incomplete();
    return this.chk_fail[VIP_CHI_SB_CHK_TXN_COMPLETES_E];
  endfunction

  protected function int n_orphan();
    return this.chk_fail[VIP_CHI_SB_CHK_RSP_HAS_OPEN_TXN_E] +
           this.chk_fail[VIP_CHI_SB_CHK_DAT_HAS_OPEN_TXN_E];
  endfunction

  protected function int n_wrong_opcode();
    return this.chk_fail[VIP_CHI_SB_CHK_COMPLETION_OPCODE_MODELLED_E];
  endfunction

  protected function int n_reuse();
    return this.chk_fail[VIP_CHI_SB_CHK_TXNID_NOT_REUSED_E];
  endfunction

  protected function int n_data_mismatch();
    return this.chk_fail[VIP_CHI_SB_CHK_READ_DATA_MATCHES_E] +
           this.chk_fail[VIP_CHI_SB_CHK_ATOMIC_RETURN_MATCHES_E];
  endfunction

  protected function int n_relay_mismatch();
    return this.chk_fail[VIP_CHI_SB_CHK_REQ_RELAYED_E];
  endfunction

  protected function int n_route_mismatch();
    return this.chk_fail[VIP_CHI_SB_CHK_REQ_ROUTED_E];
  endfunction

  protected function int n_tag_mismatch();
    return this.chk_fail[VIP_CHI_SB_CHK_READ_TAG_MATCHES_E];
  endfunction

  protected function int n_tagop_replay_mismatch();
    return this.chk_fail[VIP_CHI_SB_CHK_READ_TAGOP_REPLAYED_E];
  endfunction

  protected function int n_tagop_mismatch();
    return this.chk_fail[VIP_CHI_SB_CHK_TAGOP_STABLE_ACROSS_BEATS_E];
  endfunction

  protected function int n_order_violation();
    return this.chk_fail[VIP_CHI_SB_CHK_ORDERED_ACK_IN_ORDER_E];
  endfunction

  protected function int n_order_checked();
    return this.chk_pass[VIP_CHI_SB_CHK_ORDERED_ACK_IN_ORDER_E];
  endfunction

  // ---------------------------------------------------------------------------
  // Allocate the analysis imps.
  // ---------------------------------------------------------------------------
  function void build_phase(input uvm_phase phase);
    super.build_phase(phase);

    this.rni_req_sb   = new("rni_req_sb", this);
    this.rni_rsp_sb   = new("rni_rsp_sb", this);
    this.rni_dat_sb   = new("rni_dat_sb", this);
    this.hrni0_req_sb = new("hrni0_req_sb", this);
    this.hrni0_rsp_sb = new("hrni0_rsp_sb", this);
    this.hrni0_dat_sb = new("hrni0_dat_sb", this);
    this.hrni1_req_sb = new("hrni1_req_sb", this);
    this.hrni1_rsp_sb = new("hrni1_rsp_sb", this);
    this.hrni1_dat_sb = new("hrni1_dat_sb", this);
    this.snf_req_sb   = new("snf_req_sb", this);
    this.hsnf0_req_sb = new("hsnf0_req_sb", this);
    this.hsnf1_req_sb = new("hsnf1_req_sb", this);
  endfunction

  // ---------------------------------------------------------------------------
  // Keys.
  // ---------------------------------------------------------------------------
  protected function string ctx_key(
    input vip_chi_sb_stream_e stream,
    input node_id_t           requester_node,
    input txn_id_t            txn_id
  );
    return $sformatf("%0d_%0h_%0h", stream, requester_node, txn_id);
  endfunction

  protected function string dbid_key(
    input vip_chi_sb_stream_e stream,
    input txn_id_t            dbid
  );
    return $sformatf("%0d_%0h", stream, dbid);
  endfunction

  // Full canonical REQ identity - never addr/opcode alone (tests deliberately
  // vary src/tgt, e.g. tc_chi_e_req_smoke sets src=0x15,tgt=0x2a).
  protected function string canon_key(input item_t item);
    return $sformatf("%0h_%0h_%0h_%0h_%0h_%0d",
      item.src_id, item.tgt_id, item.txn_id, item.addr, item.opcode, item.size);
  endfunction

  // At a requester agent, TX flits carry ROLE_P (RN-I), RX flits peer_role
  // (SN-F). Direction, not opcode, distinguishes requester-sourced flits.
  protected function bit is_outbound(input item_t item);
    return (item.role == VIP_CHI_ROLE_RNI_E);
  endfunction

  // ---------------------------------------------------------------------------
  // Checker B - HN-I routing prediction helpers.
  // ---------------------------------------------------------------------------
  // Install the HN-I routing policy (env, connect_phase). The per-port routing
  // check only runs when there is more than one SN target to disambiguate.
  function void set_route_policy(input int            sn_ports,
                                 input int unsigned    addr_lsb,
                                 input vip_chi_hni_sam sam);
    this.n_sn_ports  = sn_ports;
    this.sn_addr_lsb = addr_lsb;
    this.hni_sam     = sam;
    this.route_check = (sn_ports > 1);
  endfunction

  // Re-derive an address's SN target port, mirroring the HN-I driver's
  // sn_port_of_addr() exactly (SAM ranges first, else the address stride).
  protected function int sn_port_of_addr(input addr_t addr);
    int s;
    if (this.n_sn_ports <= 1) begin
      return 0;
    end
    if (this.hni_sam != null) begin
      s = this.hni_sam.lookup(longint'(addr));
      // Out-of-range SAM target: the driver would fatal; flag it as a route error.
      if ((s < 0) || (s >= this.n_sn_ports)) begin
        return -1;
      end
      return s;
    end
    return int'((longint'(addr) >> this.sn_addr_lsb) % this.n_sn_ports);
  endfunction

  // Port-tagged canonical key: same request on the wrong port => two mismatches.
  protected function string route_key(input int port, input item_t item);
    return $sformatf("p%0d|%s", port, this.canon_key(item));
  endfunction

  // ---------------------------------------------------------------------------
  // Derive the completion contract from a requester REQ.
  // ---------------------------------------------------------------------------
  protected function void set_contract(input ctx_t ctx, input item_t item);
    req_opcode_t opc = item.opcode;

    ctx.ordered      = (item.order != VIP_CHI_ORDER_NONE_E);
    ctx.order_val    = item.order;
    ctx.exp_comp_ack = item.exp_comp_ack;
    ctx.allow_retry  = item.allow_retry;

    ctx.need_grant = 1'b0; ctx.need_write_data = 1'b0; ctx.need_read_data = 1'b0;
    ctx.need_comp  = 1'b0; ctx.need_receipt = 1'b0; ctx.need_persist = 1'b0;
    ctx.need_compack = 1'b0; ctx.need_comp_cmo = 1'b0;

    // A combined Write + CMO is a write that additionally owes the CMO half's
    // own completion, and -- for the persistent forms -- a Persist the spec
    // requires only AFTER the write data. Checked before the case below because
    // the six are not contiguous in the encoding.
    if (vip_chi_types_pkg::vip_chi_req_opcode_is_combined_write_cmo(
          vip_chi_req_opcode_t'(opc))) begin
      ctx.kind            = VIP_CHI_SB_WRITE;
      ctx.need_grant      = 1'b1;
      ctx.need_write_data = 1'b1;
      ctx.need_comp       = 1'b1;
      ctx.need_comp_cmo   = 1'b1;
      ctx.need_persist    =
        vip_chi_types_pkg::vip_chi_req_opcode_combined_cmo_is_persist(
          vip_chi_req_opcode_t'(opc));
      ctx.need_compack    = ctx.exp_comp_ack;
      return;
    end

    if (vip_chi_types_pkg::vip_chi_req_opcode_is_atomic(vip_chi_req_opcode_t'(opc))) begin
      ctx.kind            = VIP_CHI_SB_ATOMIC;
      ctx.need_grant      = 1'b1;
      ctx.need_write_data = 1'b1;
      if (vip_chi_types_pkg::vip_chi_req_opcode_is_atomic_returning_data(
            vip_chi_req_opcode_t'(opc))) begin
        ctx.need_read_data = 1'b1;
      end
      else begin
        ctx.need_comp = 1'b1;
      end
      return;
    end

    case (opc)
      req_opcode_t'(VIP_CHI_REQ_READ_NO_SNP_C),
      req_opcode_t'(VIP_CHI_REQ_READ_NO_SNP_SEP_C): begin
        ctx.kind           = VIP_CHI_SB_READ;
        ctx.need_read_data = 1'b1;
        if (ctx.ordered) begin
          ctx.need_receipt = 1'b1;
        end
      end
      req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_FULL_C),
      req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_PTL_C): begin
        ctx.kind            = VIP_CHI_SB_WRITE;
        ctx.need_grant      = 1'b1;
        ctx.need_write_data = 1'b1;
        ctx.need_comp       = 1'b1;
        ctx.need_compack    = ctx.exp_comp_ack;
      end
      req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_ZERO_C): begin
        ctx.kind      = VIP_CHI_SB_WRITE_NODATA;
        ctx.need_comp = 1'b1;
      end
      req_opcode_t'(VIP_CHI_REQ_CLEAN_SHARED_PERSIST_C): begin
        ctx.kind      = VIP_CHI_SB_PERSIST;
        ctx.need_comp = 1'b1;
      end
      req_opcode_t'(VIP_CHI_REQ_CLEAN_SHARED_PERSIST_SEP_C): begin
        ctx.kind         = VIP_CHI_SB_PERSIST_SEP;
        ctx.need_persist = 1'b1;
        ctx.need_comp    = 1'b1;
      end
      req_opcode_t'(VIP_CHI_REQ_PREFETCH_TGT_C): begin
        ctx.kind = VIP_CHI_SB_PREFETCH;   // no completion
      end
      default: begin
        ctx.kind = VIP_CHI_SB_OTHER;      // e.g. PcrdReturn - no completion tracked
      end
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // Checker E - ordered-stream acknowledgement order.
  //
  // A request carrying a non-zero Order field joins an ordered stream: the
  // requests one source issues with the same Order value are a sequence the
  // completer has taken on an ordering obligation for, and it must acknowledge
  // them in the order it received them. This VIP's requesters pipeline ordered
  // requests rather than stalling on each acknowledgement (see
  // observed_peak_outstanding in the ordered multi-outstanding tests), so the
  // obligation sits entirely on the completer side, which is what is checked.
  //
  // The observable is the FIRST inbound response of any kind for a transaction --
  // the ReadReceipt of an ordered read, the DBIDResp / CompDBIDResp of an ordered
  // write. That is the flit in which the completer commits to a position in the
  // stream, so that is what is compared; the data burst that follows may overlap
  // its neighbours freely and says nothing about ordering.
  //
  // Streams are keyed per requester stream AND per Order value, so two sources,
  // or one source mixing Request_Order with Request_Accepted traffic, do not
  // constrain each other.
  // ---------------------------------------------------------------------------
  protected function string ord_stream_key(input vip_chi_sb_stream_e stream,
                                           input node_id_t           src_id,
                                           input bit [1:0]           order_val);
    return $sformatf("%0d_%0h_%0h", stream, src_id, order_val);
  endfunction

  // Position of a TxnID in a stream FIFO, or -1. Linear, but an ordered stream is
  // only ever as deep as the requester's outstanding budget.
  protected function int ord_find(input string key, input txn_id_t txn_id);
    if (!this.ord_fifo.exists(key)) begin
      return -1;
    end
    for (int i = 0; i < this.ord_fifo[key].size(); i++) begin
      if (this.ord_fifo[key][i] == txn_id) begin
        return i;
      end
    end
    return -1;
  endfunction

  // Take the tail position in this transaction's stream. Requests that never draw
  // a completion (prefetch, PCrdReturn) are left out: nothing would ever
  // acknowledge them, so enrolling one would wedge the stream behind it.
  protected function void ord_enroll(input ctx_t ctx);
    if (!this.check_order || !ctx.ordered || ctx.ord_enrolled) begin
      return;
    end
    if ((ctx.kind == VIP_CHI_SB_PREFETCH) || (ctx.kind == VIP_CHI_SB_OTHER)) begin
      return;
    end
    ctx.ord_key      = this.ord_stream_key(ctx.stream, ctx.requester_node, ctx.order_val);
    ctx.ord_enrolled = 1'b1;
    this.ord_fifo[ctx.ord_key].push_back(ctx.txn_id);
  endfunction

  // A RetryAck withdraws the request from its stream: it was not accepted, so the
  // completer owes it nothing, and the re-issue takes a fresh position at the tail
  // rather than holding one it never got.
  protected function void ord_withdraw(input ctx_t ctx);
    int idx;
    if (!ctx.ord_enrolled) begin
      return;
    end
    ctx.ord_enrolled = 1'b0;
    idx = this.ord_find(ctx.ord_key, ctx.txn_id);
    if (idx >= 0) begin
      this.ord_fifo[ctx.ord_key].delete(idx);
      if (this.ord_fifo[ctx.ord_key].size() == 0) begin
        this.ord_fifo.delete(ctx.ord_key);
      end
    end
  endfunction

  // The completer has acknowledged this transaction: it must be the one at the
  // head of its stream.
  protected function void ord_observe(input ctx_t ctx);
    int      idx;
    txn_id_t expected;

    if (!ctx.ord_enrolled) begin
      return;
    end
    ctx.ord_enrolled = 1'b0;
    if (!this.ord_fifo.exists(ctx.ord_key) || (this.ord_fifo[ctx.ord_key].size() == 0)) begin
      return;
    end

    expected = this.ord_fifo[ctx.ord_key][0];
    if (expected == ctx.txn_id) begin
      // Count the in-order acknowledgement as well as the violation: a check that
      // only ever tallies failures reads, in a passing log, exactly like a check
      // that never ran.
      this.chk_ok(VIP_CHI_SB_CHK_ORDERED_ACK_IN_ORDER_E);
      void'(this.ord_fifo[ctx.ord_key].pop_front());
    end
    else begin
      this.chk_bad(VIP_CHI_SB_CHK_ORDERED_ACK_IN_ORDER_E, $sformatf(
        "Ordered stream out of order: stream=%0d src=0x%0h order=0x%0h expected txn=0x%0h to be acknowledged first, observed txn=0x%0h",
        ctx.stream, ctx.requester_node, ctx.order_val, expected, ctx.txn_id));
      // Drop the transaction that jumped the queue from wherever it sits, so one
      // inversion costs one error instead of cascading down the rest of the stream.
      idx = this.ord_find(ctx.ord_key, ctx.txn_id);
      if (idx >= 0) begin
        this.ord_fifo[ctx.ord_key].delete(idx);
      end
    end

    if (this.ord_fifo.exists(ctx.ord_key) && (this.ord_fifo[ctx.ord_key].size() == 0)) begin
      this.ord_fifo.delete(ctx.ord_key);
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Checker A/C - requester REQ.
  // ---------------------------------------------------------------------------
  protected function void handle_req(input vip_chi_sb_stream_e stream, input item_t item);
    string key;
    ctx_t  ctx;

    if (!this.enable || !this.is_outbound(item)) begin
      return;
    end

    // Checker B: record the requester-issued REQ.
    if (stream == VIP_CHI_SB_STREAM_RNI) begin
      this.int_req_cnt[this.canon_key(item)]++;
    end
    else begin
      this.hni_req_cnt[this.canon_key(item)]++;
      // Predict which SN target this REQ must be relayed to.
      if (this.route_check) begin
        this.hni_route_pred[this.route_key(this.sn_port_of_addr(item.addr), item)]++;
      end
    end

    key = this.ctx_key(stream, item.src_id, item.txn_id);

    if (this.open_ctx.exists(key)) begin
      ctx = this.open_ctx[key];
      if (!ctx.retired) begin
        if (ctx.retry_seen) begin
          // Legitimate retry re-issue (same TxnID) - reset and keep tracking. It
          // counts as a PASS of the reuse rule rather than as nothing at all:
          // re-using the ID of a refused request is the one case the rule has to
          // let through, so it is exactly where the rule earns its keep.
          this.chk_ok(VIP_CHI_SB_CHK_TXNID_NOT_REUSED_E);
          ctx.reset_milestones();
          this.set_contract(ctx, item);
          ctx.addr = item.addr;
          ctx.size = item.size;
          this.ord_enroll(ctx);
          return;
        end
        this.chk_bad(VIP_CHI_SB_CHK_TXNID_NOT_REUSED_E, $sformatf(
          "TxnID reuse while in flight: stream=%0d src=0x%0h txn=0x%0h opcode=0x%0h",
          stream, item.src_id, item.txn_id, item.opcode));
        // fall through and overwrite with a fresh ctx
      end
      else begin
        this.chk_ok(VIP_CHI_SB_CHK_TXNID_NOT_REUSED_E);
      end
    end
    else begin
      this.chk_ok(VIP_CHI_SB_CHK_TXNID_NOT_REUSED_E);
    end

    ctx                = new();
    ctx.stream         = stream;
    ctx.requester_node = item.src_id;
    ctx.txn_id         = item.txn_id;
    ctx.addr           = item.addr;
    ctx.size           = item.size;
    ctx.opcode         = item.opcode;
    this.set_contract(ctx, item);
    this.open_ctx[key] = ctx;
    this.ord_enroll(ctx);

    // Separated read: the DataSepResp leg returns on ReturnNID/ReturnTxnID, not
    // the original TxnID, so index the ctx by the completion key that data leg
    // will actually carry. Without this the DataSepResp is a false orphan and
    // the read a false incomplete.
    if (item.opcode == req_opcode_t'(VIP_CHI_REQ_READ_NO_SNP_SEP_C)) begin
      ctx.sep_read      = 1'b1;
      ctx.return_nid    = item.return_nid;
      ctx.return_txn_id = item.return_txn_id;
      this.sep_ret_ctx[this.ctx_key(stream, item.return_nid, item.return_txn_id)] = ctx;
    end

    // No-completion requests (prefetch / pcrd-return) retire on issue but stay
    // in the table so a later reuse of the TxnID is still caught.
    this.check_and_retire(ctx);
  endfunction

  // ---------------------------------------------------------------------------
  // Checker A - requester RSP.
  // ---------------------------------------------------------------------------
  protected function void handle_rsp(input vip_chi_sb_stream_e stream, input item_t item);
    string       key;
    ctx_t        ctx;
    rsp_opcode_t opc;
    bit          opc_modelled;

    if (!this.enable) begin
      return;
    end

    opc          = item.rsp_opcode;
    opc_modelled = 1'b1;

    // Outbound RSP from the requester == CompAck (keyed by src_id).
    if (this.is_outbound(item)) begin
      if (opc == rsp_opcode_t'(VIP_CHI_RSP_COMP_ACK_C)) begin
        key = this.ctx_key(stream, item.src_id, item.txn_id);
        if (this.open_ctx.exists(key)) begin
          ctx = this.open_ctx[key];
          ctx.compack_seen = 1'b1;
          this.check_and_retire(ctx);
        end
      end
      return;
    end

    // PCrdGrant is credit-typed, not TxnID-correlated: attach it to any open
    // retried ctx on this stream rather than risk a false orphan.
    if (opc == rsp_opcode_t'(VIP_CHI_RSP_PCRD_GRANT_C)) begin
      foreach (this.open_ctx[k]) begin
        if ((this.open_ctx[k].stream == stream) &&
            this.open_ctx[k].retry_seen && !this.open_ctx[k].retired) begin
          this.open_ctx[k].pcrd_seen = 1'b1;
        end
      end
      return;
    end

    // Inbound completion (keyed by tgt_id == requester node).
    key = this.ctx_key(stream, item.tgt_id, item.txn_id);
    if (!this.open_ctx.exists(key)) begin
      this.chk_bad(VIP_CHI_SB_CHK_RSP_HAS_OPEN_TXN_E, $sformatf(
        "Orphan RSP (no open ctx): stream=%0d tgt=0x%0h txn=0x%0h rsp_opcode=0x%0h",
        stream, item.tgt_id, item.txn_id, opc));
      return;
    end
    this.chk_ok(VIP_CHI_SB_CHK_RSP_HAS_OPEN_TXN_E);
    ctx = this.open_ctx[key];

    case (opc)
      rsp_opcode_t'(VIP_CHI_RSP_COMP_C): begin
        ctx.comp_seen = 1'b1;
        ctx.comp_err  = item.rsp_resp_err;
      end
      rsp_opcode_t'(VIP_CHI_RSP_COMP_DBID_RESP_C): begin
        ctx.grant_seen = 1'b1;
        ctx.comp_seen  = 1'b1;
        ctx.comp_err   = item.rsp_resp_err;
        this.record_grant(ctx, item);
      end
      rsp_opcode_t'(VIP_CHI_RSP_DBID_RESP_C),
      rsp_opcode_t'(VIP_CHI_RSP_DBID_RESP_ORD_C): begin
        ctx.grant_seen = 1'b1;
        this.record_grant(ctx, item);
      end
      rsp_opcode_t'(VIP_CHI_RSP_READ_RECEIPT_C): begin
        ctx.receipt_seen = 1'b1;
      end
      rsp_opcode_t'(VIP_CHI_RSP_RESP_SEP_DATA_C): begin
        // Separated read's response leg. The read still retires on its
        // DataSepResp (read_data_seen); recording the response error here keeps
        // this legal opcode from being flagged as unmodeled.
        ctx.comp_err = item.rsp_resp_err;
      end
      rsp_opcode_t'(VIP_CHI_RSP_COMP_CMO_C): begin
        ctx.comp_cmo_seen = 1'b1;
      end
      rsp_opcode_t'(VIP_CHI_RSP_PERSIST_C): begin
        ctx.persist_seen = 1'b1;
      end
      rsp_opcode_t'(VIP_CHI_RSP_COMP_PERSIST_C): begin
        ctx.comp_seen = 1'b1;
        ctx.comp_err  = item.rsp_resp_err;
      end
      rsp_opcode_t'(VIP_CHI_RSP_RETRY_ACK_C): begin
        ctx.retry_seen = 1'b1;
        // Not an acknowledgement -- the request was refused, so it leaves its
        // ordered stream and rejoins at the tail when it is re-issued.
        this.ord_withdraw(ctx);
      end
      default: begin
        // Unmodeled completion opcode: warn rather than fail. A genuinely wrong
        // completion still surfaces as an "incomplete" at check_phase (the
        // required milestone never ticks), so this cannot mask a real bug while
        // it does avoid false-failing on a legal opcode this contract omits.
        opc_modelled = 1'b0;
        this.chk_bad(VIP_CHI_SB_CHK_COMPLETION_OPCODE_MODELLED_E, $sformatf(
          "Unmodeled completion RSP opcode 0x%0h for kind=%0d stream=%0d txn=0x%0h",
          opc, ctx.kind, stream, item.txn_id));
      end
    endcase

    // Every branch above except the default and the RetryAck: a refusal is not a
    // completion opcode, so counting it here would inflate the rule with flits it
    // does not judge.
    if (opc_modelled && (opc != rsp_opcode_t'(VIP_CHI_RSP_RETRY_ACK_C))) begin
      this.chk_ok(VIP_CHI_SB_CHK_COMPLETION_OPCODE_MODELLED_E);
    end

    // Checker E: the first inbound response is the completer committing to this
    // transaction's position in its ordered stream. A no-op after that, and a
    // no-op for the RetryAck the branch above already withdrew.
    this.ord_observe(ctx);

    this.maybe_commit_write(ctx);
    this.resolve_atomic(ctx, null);  // store atomic completes on its Comp RSP
    this.check_and_retire(ctx);
  endfunction

  // ---------------------------------------------------------------------------
  // Checker A/C - requester DAT.
  // ---------------------------------------------------------------------------
  protected function void handle_dat(input vip_chi_sb_stream_e stream, input item_t item);
    string key;
    ctx_t  ctx;

    if (!this.enable) begin
      return;
    end

    if (this.is_outbound(item)) begin
      // Write / atomic-operand data: both the DBID and TxnID fields carry the
      // granted DBID (vip_chi_driver_rni.sv:777,781), so bind through the DBID
      // side-index - try dbid then txnid to stay robust across data paths.
      key = this.dbid_key(stream, item.dbid);
      if (!this.ctx_by_dbid.exists(key)) begin
        key = this.dbid_key(stream, item.txn_id);
      end
      if (this.ctx_by_dbid.exists(key)) begin
        ctx = this.ctx_by_dbid[key];
        ctx.write_data_sent = 1'b1;
        ctx.wr_dat_item     = item;
        this.maybe_commit_write(ctx);
        this.capture_atomic_old(ctx);
        // Cover the combined-grant store atomic, whose CompDBIDResp already set
        // comp_seen before this operand arrived; a returning atomic still waits
        // for its CompData (resolve_atomic no-ops until then).
        this.resolve_atomic(ctx, null);
        this.check_and_retire(ctx);
      end
      return;
    end

    // Inbound read-completion data (CompData / DataSepResp), keyed by tgt_id.
    key = this.ctx_key(stream, item.tgt_id, item.txn_id);
    if (this.open_ctx.exists(key)) begin
      ctx = this.open_ctx[key];
    end
    else if (this.sep_ret_ctx.exists(key)) begin
      // A ReadNoSnpSep's DataSepResp returns on ReturnNID/ReturnTxnID, so it
      // matches the sep-read return index rather than the primary open_ctx key.
      ctx = this.sep_ret_ctx[key];
    end
    else begin
      this.chk_bad(VIP_CHI_SB_CHK_DAT_HAS_OPEN_TXN_E, $sformatf(
        "Orphan DAT (no open ctx): stream=%0d tgt=0x%0h txn=0x%0h dat_opcode=0x%0h",
        stream, item.tgt_id, item.txn_id, item.dat_opcode));
      return;
    end
    this.chk_ok(VIP_CHI_SB_CHK_DAT_HAS_OPEN_TXN_E);
    ctx.read_data_seen = 1'b1;

    // Checker E: normally the ReadReceipt got here first and this is a no-op; it
    // is the acknowledgement only for an ordered transaction whose completer
    // answers on DAT alone.
    this.ord_observe(ctx);

    // Checker C: plain reads compare against wire-observed writes; a returning
    // atomic's CompData is its completion, so resolve the RMW here (compare the
    // pre-op return value and commit the post-op image). Error data is
    // don't-care in both paths.
    if (this.check_data && (ctx.kind == VIP_CHI_SB_READ)) begin
      this.compare_read(ctx, item);
    end
    else if (this.check_data && (ctx.kind == VIP_CHI_SB_ATOMIC)) begin
      this.resolve_atomic(ctx, item);
    end

    this.check_and_retire(ctx);
  endfunction

  // ---------------------------------------------------------------------------
  // Record a granted DBID and seed the side-index for the coming write-DAT.
  // ---------------------------------------------------------------------------
  protected function void record_grant(input ctx_t ctx, input item_t item);
    ctx.dbid = item.dbid;
    this.ctx_by_dbid[this.dbid_key(ctx.stream, item.dbid)] = ctx;
  endfunction

  // ---------------------------------------------------------------------------
  // Checker C - commit an observed write to the predicted image, but only once
  // the completion has resolved OKAY (an NDERR-rejected write never landed).
  // ---------------------------------------------------------------------------
  protected function void maybe_commit_write(input ctx_t ctx);
    addr_t       a;
    int unsigned transfer_bytes;

    if (!this.check_data || ctx.wr_committed) begin
      return;
    end

    // WriteNoSnpZero carries no DAT phase; an OKAY completion zeroes exactly the
    // Size-selected byte range in backing memory (mirrors the SN-F auto-responder
    // vip_chi_driver_snf::drive_auto_write_zero_comp). Predict that here so a later
    // readback of the zeroed range is byte-checked rather than left predicting the
    // stale pre-zero image.
    if (ctx.kind == VIP_CHI_SB_WRITE_NODATA) begin
      if (!ctx.comp_seen) begin
        return;
      end
      if (ctx.comp_err != VIP_CHI_RESP_ERR_NORMAL_OKAY_E) begin
        ctx.wr_committed = 1'b1;   // rejected zero-write never landed
        return;
      end
      transfer_bytes = 1 << int'(ctx.size);
      for (int unsigned k = 0; k < transfer_bytes; k++) begin
        a = ctx.addr + addr_t'(k);
        this.pred_mem[a] = 8'h00;
        this.written[a]  = 1'b1;
      end
      ctx.wr_committed = 1'b1;
      return;
    end

    if (ctx.kind != VIP_CHI_SB_WRITE) begin
      return;
    end
    if (!ctx.write_data_sent || !ctx.comp_seen || (ctx.wr_dat_item == null)) begin
      return;
    end
    if (ctx.comp_err != VIP_CHI_RESP_ERR_NORMAL_OKAY_E) begin
      ctx.wr_committed = 1'b1;   // resolved (rejected) - nothing to commit
      return;
    end

    foreach (ctx.wr_dat_item.data[i]) begin
      for (int j = 0; j < DATA_BYTES_C; j++) begin
        if ((i < ctx.wr_dat_item.be.size()) && ctx.wr_dat_item.be[i][j]) begin
          a = ctx.addr + addr_t'((i * DATA_BYTES_C) + j);
          this.pred_mem[a] = byte'(ctx.wr_dat_item.data[i][(8 * j) +: 8]);
          this.written[a]  = 1'b1;
        end
      end
    end
    this.commit_write_tags(ctx, ctx.wr_dat_item);
    ctx.wr_committed = 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Checker C - number of memory beats an atomic targets. AtomicCompare ships
  // twice the operand beats (compare values then swap values) but mutates only
  // the first half of memory; every other atomic targets its full operand span.
  // ---------------------------------------------------------------------------
  protected function int atomic_target_beats(input ctx_t ctx);
    int operand_beats;
    operand_beats = ctx.wr_dat_item.data.size();
    if (vip_chi_types_pkg::vip_chi_req_opcode_is_atomic_compare(
          vip_chi_req_opcode_t'(ctx.opcode))) begin
      return operand_beats / 2;
    end
    return operand_beats;
  endfunction

  // ---------------------------------------------------------------------------
  // Checker C - the CHI AtomicStore/Load[0:7] arithmetic variant, applied over
  // the full beat width. Mirrors the SN-F reference exactly
  // (vip_chi_driver_snf.sv apply_atomic_variant) so the predicted post-op image
  // matches the completer's byte-for-byte.
  // ---------------------------------------------------------------------------
  protected function data_t apply_atomic_variant_sb(
    input int    variant,
    input data_t current_value,
    input data_t operand_value
  );
    case (variant)
      0:       return data_t'(current_value + operand_value);
      1:       return data_t'(current_value & ~operand_value);
      2:       return data_t'(current_value ^ operand_value);
      3:       return data_t'(current_value | operand_value);
      4:       return ($signed(current_value) > $signed(operand_value)) ? current_value : operand_value;
      5:       return ($signed(current_value) < $signed(operand_value)) ? current_value : operand_value;
      6:       return (current_value > operand_value) ? current_value : operand_value;
      7:       return (current_value < operand_value) ? current_value : operand_value;
      default: return current_value;
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // Checker C - on the operand-DAT, snapshot the target's pre-op value off the
  // predicted image, then drop the target from the observed-write set for the
  // RMW window (so a concurrent read skips it rather than sees the stale pre-op
  // bytes). atomic_old_valid is cleared if any target byte was never observed
  // written, i.e. its pre-op value is unpredictable and no RMW can be modelled.
  // The post-op value is recomputed and committed later, in resolve_atomic().
  // ---------------------------------------------------------------------------
  protected function void capture_atomic_old(input ctx_t ctx);
    int    beat_count;
    addr_t a;

    if (!this.check_data || (ctx.kind != VIP_CHI_SB_ATOMIC) ||
        (ctx.wr_dat_item == null)) begin
      return;
    end

    beat_count = this.atomic_target_beats(ctx);
    ctx.atomic_old = new[beat_count];
    ctx.atomic_old_valid = 1'b1;

    for (int i = 0; i < beat_count; i++) begin
      data_t beat;
      beat = '0;
      for (int j = 0; j < DATA_BYTES_C; j++) begin
        a = ctx.addr + addr_t'((i * DATA_BYTES_C) + j);
        if (this.written.exists(a)) begin
          beat[(8 * j) +: 8] = this.pred_mem[a];
        end
        else begin
          ctx.atomic_old_valid = 1'b0;
        end
      end
      ctx.atomic_old[i] = beat;
    end

    // Invalidate the target range for the RMW window.
    for (int i = 0; i < beat_count; i++) begin
      for (int j = 0; j < DATA_BYTES_C; j++) begin
        a = ctx.addr + addr_t'((i * DATA_BYTES_C) + j);
        if (this.written.exists(a))  this.written.delete(a);
        if (this.pred_mem.exists(a)) this.pred_mem.delete(a);
      end
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Checker C - at the atomic completion (CompData for a returning atomic, the
  // Comp RSP for a store atomic), recompute the post-op image from the captured
  // pre-op value and the observed operand using the same decode the SN-F uses,
  // compare a returning atomic's CompData against the pre-op value, and commit
  // the post-op value so a later read-back is predictable. On an errored or
  // unpredictable atomic the target simply stays invalidated (nothing asserted).
  // ---------------------------------------------------------------------------
  protected function void resolve_atomic(input ctx_t ctx, input item_t ret_item);
    int                beat_count;
    bit                returns_data;
    bit                is_compare;
    bit                is_swap;
    bit                compare_match;
    int                variant;
    vip_chi_resp_err_t err;
    data_t             new_beat;
    addr_t             a;

    if (!this.check_data || (ctx.kind != VIP_CHI_SB_ATOMIC) ||
        (ctx.wr_dat_item == null) || ctx.atomic_resolved) begin
      return;
    end
    if (!ctx.write_data_sent) begin
      return;  // operand not observed yet
    end

    returns_data = vip_chi_types_pkg::vip_chi_req_opcode_is_atomic_returning_data(
                     vip_chi_req_opcode_t'(ctx.opcode));

    // Fire only at the true completion.
    if (returns_data) begin
      if (ret_item == null) begin
        return;  // CompData not arrived
      end
    end
    else begin
      if (!ctx.comp_seen) begin
        return;  // Comp not arrived
      end
    end
    ctx.atomic_resolved = 1'b1;

    err = returns_data ?
            (((ret_item != null) && (ret_item.dat_resp_err.size() > 0)) ?
               ret_item.dat_resp_err[0] : VIP_CHI_RESP_ERR_NORMAL_OKAY_E) :
            ctx.comp_err;

    // Errored or unpredictable: leave the target invalidated (dropped at operand
    // time); do not compare the return nor commit a post-op value.
    if ((err != VIP_CHI_RESP_ERR_NORMAL_OKAY_E) || !ctx.atomic_old_valid) begin
      return;
    end

    beat_count = this.atomic_target_beats(ctx);
    is_compare = vip_chi_types_pkg::vip_chi_req_opcode_is_atomic_compare(
                   vip_chi_req_opcode_t'(ctx.opcode));
    is_swap    = (ctx.opcode == req_opcode_t'(VIP_CHI_REQ_ATOMIC_SWAP_C));
    variant    = vip_chi_types_pkg::vip_chi_req_opcode_atomic_variant(
                   vip_chi_req_opcode_t'(ctx.opcode));

    // A returning atomic returns the pre-op value on CompData: compare it against
    // the captured pre-op image, byte-granular.
    if (returns_data && (ret_item != null)) begin
      for (int i = 0; (i < beat_count) && (i < ret_item.data.size()); i++) begin
        for (int j = 0; j < DATA_BYTES_C; j++) begin
          logic [7:0] exp_b, got_b;
          exp_b = ctx.atomic_old[i][(8 * j) +: 8];
          got_b = ret_item.data[i][(8 * j) +: 8];
          if (byte'(got_b) != byte'(exp_b)) begin
            this.chk_bad(VIP_CHI_SB_CHK_ATOMIC_RETURN_MATCHES_E, $sformatf(
              "Atomic return mismatch stream=%0d txn=0x%0h addr=0x%0h exp=0x%0h got=0x%0h",
              ctx.stream, ctx.txn_id,
              ctx.addr + addr_t'((i * DATA_BYTES_C) + j), exp_b, got_b));
          end
          else begin
            this.chk_ok(VIP_CHI_SB_CHK_ATOMIC_RETURN_MATCHES_E);
          end
        end
      end
    end

    // AtomicCompare stores the swap half only on a full-target match.
    compare_match = 1'b1;
    if (is_compare) begin
      for (int k = 0; k < beat_count; k++) begin
        if (ctx.atomic_old[k] != ctx.wr_dat_item.data[k]) begin
          compare_match = 1'b0;
        end
      end
    end

    // Recompute and commit the post-op value so a later read-back is predictable.
    for (int i = 0; i < beat_count; i++) begin
      if (is_compare) begin
        new_beat = compare_match ? ctx.wr_dat_item.data[i + beat_count]
                                 : ctx.atomic_old[i];
      end
      else if (is_swap) begin
        new_beat = ctx.wr_dat_item.data[i];
      end
      else begin
        new_beat = this.apply_atomic_variant_sb(
                     variant, ctx.atomic_old[i], ctx.wr_dat_item.data[i]);
      end

      for (int j = 0; j < DATA_BYTES_C; j++) begin
        a = ctx.addr + addr_t'((i * DATA_BYTES_C) + j);
        this.pred_mem[a] = byte'(new_beat[(8 * j) +: 8]);
        this.written[a]  = 1'b1;
      end
    end
  endfunction

  // ---------------------------------------------------------------------------
  // ---------------------------------------------------------------------------
  // Checker C, MTE half - the two tag rules.
  //
  // The VIP has kept a per-beat tag store and replayed it since the exact-CHI-E
  // completer was written, and nothing ever checked what came back. A model
  // nothing checks is the same defect as a check nothing exercises, seen from
  // the other side: it can be wrong for a whole regression without one test
  // noticing.
  // ---------------------------------------------------------------------------
  protected function void compare_read_tags(input ctx_t ctx, input item_t item);
    addr_t  slot;
    tagop_t first_op;
    bit     tagops_agreed;
    bit     tag_matched;

    if (!this.check_data) begin
      return;
    end

    // Rule 1: one TagOp for the whole transfer. CHI carries TagOp per flit but
    // requires it identical across the beats of one transfer, and the item's
    // scalar dat_tagop cannot show a disagreement -- every beat overwrites it,
    // so the last beat wins. dat_tagop_beats is why this is checkable at all.
    //
    // This was recorded as UNREACHABLE on this testbench when it was written,
    // and that was WRONG. The claim was that the only MTE-capable link here is
    // the 64-byte CHI-E one and CHI's maximum transfer Size is also 64 bytes, so
    // every transfer carrying TAGS is a single beat -- true, and irrelevant,
    // because the loop below does not require tags. dat_tagop_beats is sized per
    // beat for EVERY data transfer, so any multi-beat read exercises this rule,
    // and the whole CHI-D regression does: 36 runs, comparing TagOp zero against
    // TagOp zero across four beats.
    //
    // Naming the rule in the registry is what found that out, on the first sweep
    // after it was named. What remains genuinely out of reach here is the
    // FAILING direction -- a multi-beat burst whose beats carry disagreeing
    // non-zero TagOps -- because no link in this testbench is both MTE-capable
    // and narrow enough to burst. That is why the M3.1 negative control could not
    // break this rule, and it is a statement about the negative control, not
    // about whether the rule runs. Rule 3 below is the half a control can break.
    if (item.dat_tagop_beats.size() > 1) begin
      first_op = item.dat_tagop_beats[0];
      tagops_agreed = 1'b1;
      foreach (item.dat_tagop_beats[i]) begin
        if (item.dat_tagop_beats[i] != first_op) begin
          tagops_agreed = 1'b0;
          this.chk_bad(VIP_CHI_SB_CHK_TAGOP_STABLE_ACROSS_BEATS_E, $sformatf(
            "TagOp mismatch across beats stream=%0d txn=0x%0h beat=%0d exp=0x%0h got=0x%0h",
            ctx.stream, ctx.txn_id, i, first_op, item.dat_tagop_beats[i]));
          break;   // one report per transfer, not one per remaining beat
        end
      end
      if (tagops_agreed) begin
        this.chk_ok(VIP_CHI_SB_CHK_TAGOP_STABLE_ACROSS_BEATS_E);
      end
    end

    // Rule 2: the tag that comes back is the tag that went in. Same
    // predictable-only discipline as the data compare above -- a beat whose tag
    // this scoreboard never observed being written is skipped, because the
    // completer synthesizes tagging the scoreboard did not originate.
    foreach (item.tag[i]) begin
      slot = ctx.addr + addr_t'(i * DATA_BYTES_C);
      if (!this.tag_written.exists(slot)) begin
        this.n_tag_reads_skipped++;
        continue;
      end
      this.n_tag_checked++;
      tag_matched = 1'b1;
      if (item.tag[i] != this.pred_tag[slot]) begin
        tag_matched = 1'b0;
        this.chk_bad(VIP_CHI_SB_CHK_READ_TAG_MATCHES_E, $sformatf(
          "Tag mismatch stream=%0d txn=0x%0h addr=0x%0h exp=0x%0h got=0x%0h",
          ctx.stream, ctx.txn_id, slot, this.pred_tag[slot], item.tag[i]));
      end
      if ((item.tu.size() > i) && (item.tu[i] != this.pred_tu[slot])) begin
        tag_matched = 1'b0;
        this.chk_bad(VIP_CHI_SB_CHK_READ_TAG_MATCHES_E, $sformatf(
          "TagUpdate mismatch stream=%0d txn=0x%0h addr=0x%0h exp=0x%0h got=0x%0h",
          ctx.stream, ctx.txn_id, slot, this.pred_tu[slot], item.tu[i]));
      end
      if (tag_matched) begin
        this.chk_ok(VIP_CHI_SB_CHK_READ_TAG_MATCHES_E);
      end

      // Rule 3: the TagOp that comes back is the TagOp that went in. The
      // reachable half of rule 1's concern -- it needs only ONE beat, so unlike
      // rule 1 it is exercised on this testbench's 64-byte MTE link. A completer
      // that invented a TagOp instead of replaying the stored one is caught
      // here; one that changed TagOp mid-burst needs rule 1 and a narrower link.
      if (i < item.dat_tagop_beats.size()) begin
        if (item.dat_tagop_beats[i] != this.pred_tagop[slot]) begin
          this.chk_bad(VIP_CHI_SB_CHK_READ_TAGOP_REPLAYED_E, $sformatf(
            "TagOp replay mismatch stream=%0d txn=0x%0h addr=0x%0h exp=0x%0h got=0x%0h",
            ctx.stream, ctx.txn_id, slot, this.pred_tagop[slot],
            item.dat_tagop_beats[i]));
        end
        else begin
          this.chk_ok(VIP_CHI_SB_CHK_READ_TAGOP_REPLAYED_E);
        end
      end
    end
  endfunction

  // Commit an observed write's tagging into the predicted image, under the same
  // rule as the data commit: only once the completion resolved OKAY.
  protected function void commit_write_tags(input ctx_t ctx, input item_t item);
    addr_t slot;

    if (!this.check_data || (item == null)) begin
      return;
    end

    foreach (item.tag[i]) begin
      slot = ctx.addr + addr_t'(i * DATA_BYTES_C);
      this.pred_tag[slot]    = item.tag[i];
      this.pred_tu[slot]     = (item.tu.size() > i) ? item.tu[i] : tu_t'(0);
      this.pred_tagop[slot]  = (i < item.dat_tagop_beats.size())
                                 ? item.dat_tagop_beats[i] : item.dat_tagop;
      this.tag_written[slot] = 1'b1;
    end
  endfunction

  // Checker C - predictable-only read compare (skip bytes never observed
  // written; the SN-F synthesizes a deterministic pattern the scoreboard did
  // not originate and must not predict).
  // ---------------------------------------------------------------------------
  protected function void compare_read(input ctx_t ctx, input item_t item);
    addr_t     a;
    logic [7:0] got;

    // Error read data is don't-care.
    if ((item.dat_resp_err.size() > 0) &&
        (item.dat_resp_err[0] != VIP_CHI_RESP_ERR_NORMAL_OKAY_E)) begin
      return;
    end

    foreach (item.data[i]) begin
      for (int j = 0; j < DATA_BYTES_C; j++) begin
        a = ctx.addr + addr_t'((i * DATA_BYTES_C) + j);
        if (!this.written.exists(a)) begin
          this.n_reads_skipped++;
          continue;
        end
        got = item.data[i][(8 * j) +: 8];
        if (byte'(got) != this.pred_mem[a]) begin
          this.chk_bad(VIP_CHI_SB_CHK_READ_DATA_MATCHES_E, $sformatf(
            "Data mismatch stream=%0d txn=0x%0h addr=0x%0h exp=0x%0h got=0x%0h",
            ctx.stream, ctx.txn_id, a, this.pred_mem[a], got));
        end
        else begin
          this.chk_ok(VIP_CHI_SB_CHK_READ_DATA_MATCHES_E);
        end
      end
    end

    this.compare_read_tags(ctx, item);
  endfunction

  // ---------------------------------------------------------------------------
  // Retire when the contract is met; drop the DBID index entry (the DBID may be
  // reused by a later write).
  // ---------------------------------------------------------------------------
  protected function void check_and_retire(input ctx_t ctx);
    string dkey;
    string skey;

    if (ctx.retired || !ctx.contract_met()) begin
      return;
    end
    ctx.retired = 1'b1;
    // The pass half of the completion rule. Its failure half fires once, at
    // check_phase, on whatever is left open -- so without this the rule would
    // report zero of both on every clean run and be indistinguishable from a
    // scoreboard that had stopped tracking transactions altogether.
    this.chk_ok(VIP_CHI_SB_CHK_TXN_COMPLETES_E);
    dkey = this.dbid_key(ctx.stream, ctx.dbid);
    if (this.ctx_by_dbid.exists(dkey) && (this.ctx_by_dbid[dkey] == ctx)) begin
      this.ctx_by_dbid.delete(dkey);
    end
    if (ctx.sep_read) begin
      skey = this.ctx_key(ctx.stream, ctx.return_nid, ctx.return_txn_id);
      if (this.sep_ret_ctx.exists(skey) && (this.sep_ret_ctx[skey] == ctx)) begin
        this.sep_ret_ctx.delete(skey);
      end
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Checker B - completer-side REQ recording.
  // ---------------------------------------------------------------------------
  protected function void handle_cmp_req(input bit hni, input int port, input item_t item);
    if (!this.enable) begin
      return;
    end
    if (hni) begin
      this.hni_cmp_cnt[this.canon_key(item)]++;
      // Record the SN port this REQ actually arrived on (checked vs prediction).
      if (this.route_check) begin
        this.hni_route_obs[this.route_key(port, item)]++;
      end
    end
    else begin
      this.int_cmp_cnt[this.canon_key(item)]++;
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Analysis imp write callbacks.
  // ---------------------------------------------------------------------------
  function void write_rni_req_sb   (input item_t item); this.handle_req(VIP_CHI_SB_STREAM_RNI,   item); endfunction
  function void write_rni_rsp_sb   (input item_t item); this.handle_rsp(VIP_CHI_SB_STREAM_RNI,   item); endfunction
  function void write_rni_dat_sb   (input item_t item); this.handle_dat(VIP_CHI_SB_STREAM_RNI,   item); endfunction
  function void write_hrni0_req_sb (input item_t item); this.handle_req(VIP_CHI_SB_STREAM_HRNI0, item); endfunction
  function void write_hrni0_rsp_sb (input item_t item); this.handle_rsp(VIP_CHI_SB_STREAM_HRNI0, item); endfunction
  function void write_hrni0_dat_sb (input item_t item); this.handle_dat(VIP_CHI_SB_STREAM_HRNI0, item); endfunction
  function void write_hrni1_req_sb (input item_t item); this.handle_req(VIP_CHI_SB_STREAM_HRNI1, item); endfunction
  function void write_hrni1_rsp_sb (input item_t item); this.handle_rsp(VIP_CHI_SB_STREAM_HRNI1, item); endfunction
  function void write_hrni1_dat_sb (input item_t item); this.handle_dat(VIP_CHI_SB_STREAM_HRNI1, item); endfunction
  function void write_snf_req_sb   (input item_t item); this.handle_cmp_req(1'b0, 0, item); endfunction
  function void write_hsnf0_req_sb (input item_t item); this.handle_cmp_req(1'b1, 0, item); endfunction
  function void write_hsnf1_req_sb (input item_t item); this.handle_cmp_req(1'b1, 1, item); endfunction

  // ---------------------------------------------------------------------------
  // Flush all in-flight state on reset (abandoned txns must not report as
  // incomplete; the SN-F wipes its backing store on reset too).
  // ---------------------------------------------------------------------------
  function void handle_reset();
    this.open_ctx.delete();
    this.ctx_by_dbid.delete();
    this.sep_ret_ctx.delete();
    this.pred_mem.delete();
    this.written.delete();
    this.int_req_cnt.delete();
    this.int_cmp_cnt.delete();
    this.hni_req_cnt.delete();
    this.hni_cmp_cnt.delete();
    this.hni_route_pred.delete();
    this.hni_route_obs.delete();
    this.ord_fifo.delete();
  endfunction

  // ---------------------------------------------------------------------------
  // Checker B multiset compare between requester and completer views.
  // ---------------------------------------------------------------------------
  protected function void check_relay(
    input string                label,
    ref   int                   req_cnt [string],
    ref   int                   cmp_cnt [string],
    input vip_chi_sb_check_id_t id
  );
    foreach (req_cnt[k]) begin
      int seen = cmp_cnt.exists(k) ? cmp_cnt[k] : 0;
      if (seen < req_cnt[k]) begin
        this.chk_bad(id, $sformatf(
          "%s: request key=%s issued %0d time(s) but observed at completer %0d time(s)",
          label, k, req_cnt[k], seen));
      end
      else begin
        // One pass per request key that arrived, so a run in which the two views
        // simply never met -- no requester traffic, or a completer imp nothing
        // connected -- cannot read as a clean compare.
        this.chk_ok(id);
      end
    end
    foreach (cmp_cnt[k]) begin
      int issued = req_cnt.exists(k) ? req_cnt[k] : 0;
      if (cmp_cnt[k] > issued) begin
        this.chk_bad(id, $sformatf(
          "%s: phantom request key=%s at completer %0d time(s) but issued %0d time(s)",
          label, k, cmp_cnt[k], issued));
      end
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Checker E accessors: the violation count for a negative control, and the
  // in-order tally so a positive test can require that the check actually ran.
  // ---------------------------------------------------------------------------
  function int get_tag_mismatch_count();      return this.n_tag_mismatch();      endfunction
  function int get_tagop_mismatch_count();    return this.n_tagop_mismatch();    endfunction
  function int get_tagop_replay_mismatch_count(); return this.n_tagop_replay_mismatch(); endfunction
  function int get_tag_checked_count();       return this.n_tag_checked;         endfunction

  function int get_order_violation_count(); return this.n_order_violation(); endfunction
  function int get_order_checked_count();   return this.n_order_checked();   endfunction

  // ---------------------------------------------------------------------------
  // Final checks: incomplete transactions + request fidelity.
  // ---------------------------------------------------------------------------
  function void check_phase(input uvm_phase phase);
    super.check_phase(phase);

    if (!this.enable) begin
      return;
    end

    foreach (this.open_ctx[k]) begin
      ctx_t ctx = this.open_ctx[k];
      if (!ctx.retired) begin
        this.chk_bad(VIP_CHI_SB_CHK_TXN_COMPLETES_E, $sformatf(
          "Incomplete transaction stream=%0d node=0x%0h txn=0x%0h opcode=0x%0h kind=%0d (grant=%0b wdat=%0b rdat=%0b comp=%0b rcpt=%0b prst=%0b cack=%0b)",
          ctx.stream, ctx.requester_node, ctx.txn_id, ctx.opcode, ctx.kind,
          ctx.grant_seen, ctx.write_data_sent, ctx.read_data_seen, ctx.comp_seen,
          ctx.receipt_seen, ctx.persist_seen, ctx.compack_seen));
      end
    end

    this.check_relay("Checker-B integrated", this.int_req_cnt, this.int_cmp_cnt,
                     VIP_CHI_SB_CHK_REQ_RELAYED_E);
    this.check_relay("Checker-B HN-I proxy", this.hni_req_cnt, this.hni_cmp_cnt,
                     VIP_CHI_SB_CHK_REQ_RELAYED_E);

    // Per-port routing fidelity: each proxied REQ must land on the SN target its
    // address decodes to. Mis-route => shortfall at predicted + phantom at actual.
    if (this.route_check) begin
      this.check_relay("Checker-B HN-I routing", this.hni_route_pred,
                       this.hni_route_obs, VIP_CHI_SB_CHK_REQ_ROUTED_E);
    end

    `uvm_info(get_name(), $sformatf(
      "scoreboard summary: incomplete=%0d orphan=%0d wrong_opcode=%0d reuse=%0d data_mismatch=%0d relay_mismatch=%0d route_mismatch=%0d (reads_skipped_unpredictable=%0d)",
      this.n_incomplete(), this.n_orphan(), this.n_wrong_opcode(), this.n_reuse(),
      this.n_data_mismatch(), this.n_relay_mismatch(), this.n_route_mismatch(),
      this.n_reads_skipped), UVM_LOW);

    // The MTE tag half on its OWN line, for the same reason Checker E below is:
    // appended to the summary above it falls past the report server's wrap
    // column, and a wrapped field name is a field nobody can sweep for.
    `uvm_info(get_name(), $sformatf(
      "scoreboard tag summary: tag_checked=%0d tag_mismatch=%0d tagop_replay_mismatch=%0d tagop_beat_mismatch=%0d (tag_reads_skipped_unpredictable=%0d)",
      this.n_tag_checked, this.n_tag_mismatch(), this.n_tagop_replay_mismatch(),
      this.n_tagop_mismatch(), this.n_tag_reads_skipped),
      UVM_LOW);

    // Checker E on its own line, deliberately: appended to the summary above it
    // fell past the report server's wrap column, which split the field name from
    // its value and made the tally impossible to grep for across a regression --
    // exactly the sweep an ordered-stream check needs to prove it is not vacuous.
    `uvm_info(get_name(), $sformatf(
      "ordered-stream summary: order_violation=%0d order_in_order=%0d",
      this.n_order_violation(), this.n_order_checked()), UVM_LOW);
  endfunction

  // ---------------------------------------------------------------------------
  // The per-rule report and its export, in the same shape and the same CSV
  // schema as the SVA checkers' -- which is what lets one aggregation script
  // read both and gate on both.
  //
  // Called from the env's report_phase rather than done here, because
  // check_phase is where the last failures are still being counted: reporting
  // from inside it would publish a tally taken before the run's own
  // end-of-test checks had finished writing it.
  // ---------------------------------------------------------------------------
  function void report_checks();
    int unsigned not_exercised;
    int unsigned in_scope;

    not_exercised = 0;
    in_scope      = 0;

    for (int unsigned i = 0; i < int'(VIP_CHI_SB_CHK_NUM_E); i++) begin
      vip_chi_sb_check_id_t id = vip_chi_sb_check_id_t'(i);
      if (!this.chk_rule_enabled(id)) begin
        continue;
      end
      in_scope++;
      if ((this.chk_pass[id] == 0) && (this.chk_fail[id] == 0)) begin
        not_exercised++;
        // One line per rule: the report server wraps at a fixed column, so a
        // line carrying a list loses everything past the wrap.
        `uvm_info(get_name(), $sformatf(
          "SB CHECK NOT EXERCISED  %s", vip_chi_sb_check_name(id)), UVM_LOW)
      end
    end

    `uvm_info(get_name(), $sformatf(
      "VIP_CHI SB CHECK VACUITY: not_exercised=%0d of=%0d",
      not_exercised, in_scope), UVM_LOW)
  endfunction

  function void export_check_csv();
    string path;
    string run_name;
    int    fd;

    if (!$value$plusargs("vip_chi_check_csv=%s", path)) begin
      return;
    end

    run_name = "unknown";
    void'($value$plusargs("UVM_TESTNAME=%s", run_name));

    // Append, and write the header only when the file is new -- the aggregation
    // script reads one file produced by a whole sweep.
    fd = $fopen(path, "r");
    if (fd == 0) begin
      fd = $fopen(path, "w");
      if (fd == 0) begin
        `uvm_warning(get_name(), $sformatf(
          "could not open %s for the check-tally export", path))
        return;
      end
      $fdisplay(fd, "run,bind,check,enabled,severity,passes,fails");
    end
    else begin
      $fclose(fd);
      fd = $fopen(path, "a");
      if (fd == 0) begin
        `uvm_warning(get_name(), $sformatf(
          "could not append to %s for the check-tally export", path))
        return;
      end
    end

    for (int unsigned i = 0; i < int'(VIP_CHI_SB_CHK_NUM_E); i++) begin
      vip_chi_sb_check_id_t id = vip_chi_sb_check_id_t'(i);
      $fdisplay(fd, "%s,%s,%s,%0d,%s,%0d,%0d",
        run_name, get_name(), vip_chi_sb_check_name(id),
        this.chk_rule_enabled(id), this.chk_severity[id].name(),
        this.chk_pass[id], this.chk_fail[id]);
    end

    $fclose(fd);
  endfunction

endclass

`endif
