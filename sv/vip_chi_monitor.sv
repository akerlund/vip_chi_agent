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

`ifndef VIP_CHI_MONITOR
`define VIP_CHI_MONITOR

import uvm_pkg::*;
`include "uvm_macros.svh"
import vip_chi_types_pkg::*;

class vip_chi_monitor #(
  vip_chi_cfg_t  CFG_P        = VIP_CHI_DEFAULT_CFG_C,
  type           FLIT_TYPES_T = vip_chi_types #(CFG_P),
  vip_chi_role_t ROLE_P       = VIP_CHI_ROLE_MONITOR_E
  ) extends uvm_monitor;

  typedef vip_chi_item  #(CFG_P)               item_t;
  typedef vip_chi_types #(CFG_P)::node_id_t    node_id_t;
  typedef vip_chi_types #(CFG_P)::addr_t       addr_t;
  typedef vip_chi_types #(CFG_P)::txn_id_t     txn_id_t;
  typedef vip_chi_types #(CFG_P)::lpid_t       lpid_t;
  typedef vip_chi_types #(CFG_P)::size_t       size_t;
  typedef vip_chi_types #(CFG_P)::req_opcode_t req_opcode_t;
  typedef vip_chi_types #(CFG_P)::rsp_opcode_t rsp_opcode_t;
  typedef vip_chi_types #(CFG_P)::dat_opcode_t dat_opcode_t;
  typedef vip_chi_types #(CFG_P)::snp_opcode_t snp_opcode_t;
  typedef vip_chi_types #(CFG_P)::data_t       data_t;
  typedef vip_chi_types #(CFG_P)::be_t         be_t;
  typedef vip_chi_types #(CFG_P)::data_id_t    data_id_t;
  typedef vip_chi_types #(CFG_P)::cc_id_t      cc_id_t;
  typedef vip_chi_types #(CFG_P)::datacheck_t  datacheck_t;
  typedef vip_chi_types #(CFG_P)::poison_t     poison_t;
  typedef vip_chi_types #(CFG_P)::mpam_t       mpam_t;
  typedef FLIT_TYPES_T::vip_chi_req_flit_t     req_flit_t;
  typedef FLIT_TYPES_T::vip_chi_rsp_flit_t     rsp_flit_t;
  typedef FLIT_TYPES_T::vip_chi_dat_flit_t     dat_flit_t;
  typedef FLIT_TYPES_T::vip_chi_snp_flit_t     snp_flit_t;

  virtual vip_chi_if #(CFG_P, FLIT_TYPES_T, ROLE_P) vif;

  // cg_sactive sample scratch.
  protected bit sactive_sampled_once;
  protected bit txsactive_sample;
  protected bit rxsactive_sample;
  protected bit sactive_flit_moving_sample;
  vip_chi_cfg_agent                                 cfg;

  uvm_analysis_port #(item_t) req_port;
  uvm_analysis_port #(item_t) rsp_port;
  uvm_analysis_port #(item_t) dat_port;
  uvm_analysis_port #(item_t) snp_port;

  // Per-transfer DAT reassembly state, keyed by {role,src,tgt,txnid}. A transfer
  // retires on its correlated beat count when known (see the correlation maps
  // below), falling back to the advisory FLITPEND deassert only when the count
  // is not.
  //
  // Beats are PLACED BY DataID whenever the expected beat count is known: CHI
  // lets the beats of one transfer arrive in any order precisely because DataID
  // carries the position, so indexing by arrival order silently mis-assembles a
  // payload the moment a completer exercises that permission -- and the failure
  // surfaces downstream as a scoreboard data mismatch pointing at the data path
  // rather than at the reassembly. The running receive counter remains the
  // placement index only on the fallback path, where no beat count is known and
  // therefore no DataID range can be validated.
  protected item_t dat_item_by_key[string];
  protected int    dat_received_beats_by_key[string];

  // Which beat positions of an in-flight transfer have already been written, so
  // a repeated DataID is reported rather than silently overwriting the earlier
  // beat, and a position never written is reported when the transfer closes.
  // Only populated on the DataID-placed path.
  typedef bit dat_beat_seen_t [];
  protected dat_beat_seen_t dat_beat_seen_by_key[string];

  // REQ->DAT beat-count correlation. Reads echo the requester TxnID on the
  // returning data, so their expected beat count is keyed by TxnID. Writes and
  // atomic operands ship their data under the granted DBID (used as the DAT
  // TxnID), so their count is keyed by DBID once the grant is observed. All
  // three are consumed on retirement, so they stay bounded in a reset-free run.
  protected int    rd_beats_by_txnid[txn_id_t];  // read return, keyed by REQ TxnID
  protected int    wr_beats_by_txnid[txn_id_t];  // write/operand out, keyed by REQ TxnID (staging)
  protected int    wr_beats_by_dbid[txn_id_t];   // write/operand out, keyed by granted DBID

  // ---------------------------------------------------------------------------
  // Transaction timestamps.
  //
  // Milestones arrive on different channels and are published as different
  // items -- the REQ on one, its Comp on another -- so a record per TxnID
  // accumulates them and every published item carries the whole set known so
  // far. That is what lets a consumer of the analysis stream call latency() on
  // the completion it receives, instead of having to correlate two items.
  //
  // Cycles come from a reset-gated free-running counter, NOT $time: that keeps
  // every latency a timescale-independent integer. The counter advances before
  // any stamping, so the first observable cycle is 1 and 0 stays available as
  // "milestone not reached".
  // ---------------------------------------------------------------------------
  typedef struct {
    int unsigned t_req_issued;
    int unsigned t_retry_ack;
    int unsigned t_pcrd_grant;
    int unsigned t_req_reissued;
    int unsigned t_dbid;
    int unsigned t_first_dat;
    int unsigned t_last_dat;
    int unsigned t_comp;
    int unsigned t_compack;
    int unsigned retry_count;
    bit          is_write;   // which bound applies; not a milestone
  } txn_times_t;

  protected int unsigned cycle_count;
  protected txn_times_t  txn_times [txn_id_t];
  // Snoop records are kept apart from request records: a snoop's TxnID is
  // allocated by the home, a request's by the requester, and on a coherent link
  // both are visible on the same monitor. Sharing one map would let two
  // unrelated transactions that happen to pick the same number overwrite each
  // other's milestones.
  protected txn_times_t  snp_times [txn_id_t];

  // Per-beat arrival cycles cost an array grow on every beat of every transfer,
  // which is not worth paying in a long run for a detail most tests never read.
  // Set by the agent from its cfg; default off.
  bit          collect_beat_timestamps = 1'b0;

  // Waveform-correlated transaction recording. Off by default: a recorded
  // stream costs simulator time and database space on every transaction of every
  // run, which is not worth paying in a long regression for something only read
  // when a specific flow is being debugged.
  bit record_transactions = 1'b0;

  // The REQ item whose stream is open, per in-flight TxnID, plus its handle.
  //
  // The item is held because end_tr must be called on the SAME object begin_tr
  // opened, and the completion arrives as a DIFFERENT item on a different
  // channel -- ending the stream on the completion item would silently open a
  // second stream and never close the first. The handle is held so a retry
  // re-issue can be recorded as a CHILD of the attempt it replaces rather than
  // as an unrelated transaction.
  protected item_t open_tr_item   [txn_id_t];
  protected int    open_tr_handle [txn_id_t];
  protected item_t open_snp_item  [txn_id_t];

  // Whole-run stream tallies, readable by a test. A recorder that opened every
  // stream and closed none would otherwise look identical to a correct one on a
  // passing run, so these are what the smoke test asserts on: opened must equal
  // closed, and nothing may still be open once every transaction has retired.
  int unsigned n_tr_opened;
  int unsigned n_tr_closed;
  int unsigned n_tr_still_open;

  // Latency bounds, 0 = unbounded. Set by the agent from its cfg.
  int unsigned max_read_xact_latency  = 0;
  int unsigned max_write_xact_latency = 0;
  int unsigned max_snp_xact_latency   = 0;

  // Whole-run tally, deliberately NOT cleared by handle_reset() -- like the
  // DataID violation counter it reports on the run, not on the current epoch.
  int unsigned n_latency_violation;

  `uvm_component_param_utils(vip_chi_monitor #(CFG_P, FLIT_TYPES_T, ROLE_P))

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent);
    super.new(name, parent);
    this.cg_sactive = new();
    this.req_port = new("req_port", this);
    this.rsp_port = new("rsp_port", this);
    this.dat_port = new("dat_port", this);
    this.snp_port = new("snp_port", this);
  endfunction

  // ---------------------------------------------------------------------------
  // Validate the monitor wiring supplied by the parent agent.
  // ---------------------------------------------------------------------------
  function void build_phase(input uvm_phase phase);
    super.build_phase(phase);

    if (this.vif == null) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] monitor.vif must be assigned by the parent agent",
        get_name()))
    end
  endfunction

  // ---------------------------------------------------------------------------
  // TXSACTIVE / RXSACTIVE sideband coverage.
  //
  // Lives here rather than in vip_chi_coverage because these are per-interface
  // WIRES sampled every cycle, while that collector is item-fed and shared
  // across roles -- it never sees the interface, and an item-boundary sample
  // would be a constant now that the sideband is held for the whole window.
  //
  // cx_tx_traffic is the bin that matters: TXSACTIVE asserted on a cycle with
  // NO flit moving is the held-across-the-window behaviour, which a per-flit
  // pulse could never produce. Its absence would mean the sideband had gone
  // back to bracketing individual flits.
  covergroup cg_sactive;
    option.per_instance = 1;

    cp_txsactive: coverpoint this.txsactive_sample {
      bins low  = {1'b0};
      bins high = {1'b1};
    }

    cp_rxsactive: coverpoint this.rxsactive_sample {
      bins low  = {1'b0};
      bins high = {1'b1};
    }

    cp_flit_moving: coverpoint this.sactive_flit_moving_sample {
      bins idle    = {1'b0};
      bins traffic = {1'b1};
    }

    cx_tx_traffic: cross cp_txsactive, cp_flit_moving;
    cx_tx_rx:      cross cp_txsactive, cp_rxsactive;
  endgroup

  // ---------------------------------------------------------------------------
  // Timestamp helpers.
  // ---------------------------------------------------------------------------
  // Copy the accumulated milestones for this TxnID onto a published item. The
  // is_write flag is monitor bookkeeping and deliberately not published.
  protected function void stamp_item(input item_t item, input txn_id_t txn_id);
    txn_times_t rec;
    if (!this.txn_times.exists(txn_id)) begin
      return;
    end
    rec                 = this.txn_times[txn_id];
    item.t_req_issued   = rec.t_req_issued;
    item.t_retry_ack    = rec.t_retry_ack;
    item.t_pcrd_grant   = rec.t_pcrd_grant;
    item.t_req_reissued = rec.t_req_reissued;
    item.t_dbid         = rec.t_dbid;
    item.t_first_dat    = rec.t_first_dat;
    item.t_last_dat     = rec.t_last_dat;
    item.t_comp         = rec.t_comp;
    item.t_compack      = rec.t_compack;
    item.retry_count    = rec.retry_count;
  endfunction

  // ---------------------------------------------------------------------------
  // Transaction recording.
  //
  // accept_tr / begin_tr / end_tr rather than a bare begin/end pair, because the
  // three carry different information and a waveform viewer shows them
  // separately: ACCEPTED is when the monitor saw the request on the wire, BEGUN
  // is when it started being serviced, ENDED is its completion milestone. For an
  // observed transaction the first two coincide, which is exactly why both are
  // called -- a stream missing its accept time reads as though the monitor
  // invented the transaction at the moment it began.
  // ---------------------------------------------------------------------------
  protected function void record_begin(input item_t  item,
                                       input txn_id_t txn_id,
                                       input string  stream,
                                       input bit     is_snoop = 1'b0);
    int handle;

    if (!this.record_transactions) begin
      return;
    end

    // A retry re-issue is the SAME transaction making a second attempt, so it
    // nests under the attempt it replaces. Recording it as a fresh top-level
    // stream would show two unrelated transactions on one TxnID and lose the
    // very relationship a reader is looking for.
    if (!is_snoop && this.open_tr_handle.exists(txn_id)) begin
      void'(this.begin_child_tr(item, this.open_tr_handle[txn_id], stream));
      return;
    end

    this.accept_tr(item);
    handle = this.begin_tr(item, stream);
    this.n_tr_opened++;

    if (is_snoop) begin
      this.open_snp_item[txn_id] = item;
    end
    else begin
      this.open_tr_item[txn_id]   = item;
      this.open_tr_handle[txn_id] = handle;
    end
  endfunction

  // Closes the stream on the item that OPENED it, not on the completion item.
  protected function void record_end(input txn_id_t txn_id,
                                     input bit      is_snoop = 1'b0);
    if (!this.record_transactions) begin
      return;
    end

    if (is_snoop) begin
      if (this.open_snp_item.exists(txn_id)) begin
        this.end_tr(this.open_snp_item[txn_id]);
        this.n_tr_closed++;
        this.open_snp_item.delete(txn_id);
      end
      return;
    end

    if (this.open_tr_item.exists(txn_id)) begin
      this.end_tr(this.open_tr_item[txn_id]);
      this.n_tr_closed++;
      this.open_tr_item.delete(txn_id);
      this.open_tr_handle.delete(txn_id);
    end
  endfunction

  // How many streams are still open. A function rather than a variable so it
  // cannot go stale, and because a testcase compiles into a package and may not
  // reach into the monitor's associative arrays itself.
  function int unsigned tr_still_open();
    return this.open_tr_item.num() + this.open_snp_item.num();
  endfunction

  // Latency bound, checked once at the transaction's completion milestone
  // against the item's OWN timestamps -- so the number reported is the same one
  // a test reads back off the item, not a separately-derived figure that could
  // disagree with it.
  protected function void check_latency_bound(input item_t   item,
                                              input txn_id_t txn_id,
                                              input bit      is_write,
                                              input bit      is_snoop = 1'b0);
    int unsigned bound;
    int unsigned measured;
    string       kind;

    if (is_snoop) begin
      bound = this.max_snp_xact_latency;
      kind  = "snoop";
    end
    else if (is_write) begin
      bound = this.max_write_xact_latency;
      kind  = "write";
    end
    else begin
      bound = this.max_read_xact_latency;
      kind  = "read";
    end

    if (bound == 0) begin
      return;
    end
    measured = item.latency();
    if (measured <= bound) begin
      return;
    end

    this.n_latency_violation++;
    `uvm_error(get_name(), $sformatf(
      "[%s] %s transaction txn_id 0x%0h (opcode=0x%0h) took %0d cycles, exceeding the configured bound of %0d",
      get_name(), kind, txn_id, is_snoop ? item.snp_opcode : item.opcode,
      measured, bound))
  endfunction

  // A snoop completes on its SnpResp (RSP) or SnpRespData (DAT). Both carry the
  // snoop's TxnID, so the bound is evaluated wherever the response lands.
  protected function void close_snoop(input item_t item, input txn_id_t txn_id);
    txn_times_t rec;
    if (!this.snp_times.exists(txn_id)) begin
      return;
    end
    rec = this.snp_times[txn_id];
    this.snp_times.delete(txn_id);
    item.t_req_issued = rec.t_req_issued;
    item.t_comp       = this.cycle_count;
    this.check_latency_bound(item, txn_id, 1'b0, 1'b1);
    this.record_end(txn_id, 1'b1);
  endfunction

  // Sampled only when the covered tuple changes: the bins are three bits wide,
  // so a per-cycle sample would add cost without adding information.
  protected function void sample_sactive();

    bit tx_now;
    bit rx_now;
    bit moving_now;

    tx_now = this.vif.monitor_cb.txsactive;
    rx_now = this.vif.monitor_cb.rxsactive;
    moving_now = this.vif.monitor_cb.txreqflitv || this.vif.monitor_cb.txrspflitv ||
                 this.vif.monitor_cb.txdatflitv || this.vif.monitor_cb.rxreqflitv ||
                 this.vif.monitor_cb.rxrspflitv || this.vif.monitor_cb.rxdatflitv;

    if (this.sactive_sampled_once &&
        (tx_now == this.txsactive_sample) &&
        (rx_now == this.rxsactive_sample) &&
        (moving_now == this.sactive_flit_moving_sample)) begin
      return;
    end

    this.txsactive_sample            = tx_now;
    this.rxsactive_sample            = rx_now;
    this.sactive_flit_moving_sample  = moving_now;
    this.sactive_sampled_once        = 1'b1;
    this.cg_sactive.sample();
  endfunction

  // ---------------------------------------------------------------------------
  // Public sampling entry point. The parent agent owns the reset watcher and
  // forks this task only while rst_n is deasserted.
  // ---------------------------------------------------------------------------
  task monitor_start();

    forever begin

      @(this.vif.monitor_cb);

      if (!this.vif.rst_n) begin
        continue;
      end

      // Advance BEFORE stamping, so the first observable cycle is 1 and 0 stays
      // available as "milestone not reached".
      this.cycle_count++;

      this.sample_sactive();

      // An L-credit return (opcode 0 on every channel) is a link-layer flit, not
      // a transaction: it hands one credit back and names no address, no TxnID
      // and no data. Publishing one would invent a transaction the scoreboard
      // then waits forever to complete, so the filter belongs HERE rather than in
      // each publish_* -- one place where a flit becomes an item, one place where
      // the link layer is separated from the protocol layer.
      if (this.vif.monitor_cb.txreqflitv && !this.req_is_lcrd_return(this.vif.monitor_cb.txreqflit)) begin
        this.publish_req(this.vif.monitor_cb.txreqflit, ROLE_P);
      end

      if (this.vif.monitor_cb.rxreqflitv && !this.req_is_lcrd_return(this.vif.monitor_cb.rxreqflit)) begin
        this.publish_req(this.vif.monitor_cb.rxreqflit, this.peer_role());
      end

      if (this.vif.monitor_cb.txrspflitv && !this.rsp_is_lcrd_return(this.vif.monitor_cb.txrspflit)) begin
        this.publish_rsp(this.vif.monitor_cb.txrspflit, ROLE_P);
      end

      if (this.vif.monitor_cb.rxrspflitv && !this.rsp_is_lcrd_return(this.vif.monitor_cb.rxrspflit)) begin
        this.publish_rsp(this.vif.monitor_cb.rxrspflit, this.peer_role());
      end

      if (this.vif.monitor_cb.txdatflitv && !this.dat_is_lcrd_return(this.vif.monitor_cb.txdatflit)) begin
        this.publish_dat(this.vif.monitor_cb.txdatflit, this.vif.monitor_cb.txdatflitpend, ROLE_P);
      end

      if (this.vif.monitor_cb.rxdatflitv && !this.dat_is_lcrd_return(this.vif.monitor_cb.rxdatflit)) begin
        this.publish_dat(this.vif.monitor_cb.rxdatflit, this.vif.monitor_cb.rxdatflitpend, this.peer_role());
      end

      // Snoop channel (Tier C). A home node (HN-F) sources snoops on its TX; a
      // fully-coherent requester (RN-F) receives them on its RX. Both are idle
      // on non-coherent links, so this never fires there.
      if (this.vif.monitor_cb.txsnpflitv && !this.snp_is_lcrd_return(this.vif.monitor_cb.txsnpflit)) begin
        this.publish_snp(this.vif.monitor_cb.txsnpflit, ROLE_P);
      end

      if (this.vif.monitor_cb.rxsnpflitv && !this.snp_is_lcrd_return(this.vif.monitor_cb.rxsnpflit)) begin
        this.publish_snp(this.vif.monitor_cb.rxsnpflit, this.peer_role());
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  // One predicate per channel rather than a single opcode == 0 test, because the
  // opcode field is a different type and a different width on each, and comparing
  // a 4-bit DAT opcode against an untyped zero is how the wrong field ends up
  // compared once someone widens one of them.
  // ---------------------------------------------------------------------------
  protected function bit req_is_lcrd_return(input req_flit_t flit);
    return (req_opcode_t'(flit.opcode) == req_opcode_t'(VIP_CHI_REQ_LCRD_RETURN_C));
  endfunction

  protected function bit rsp_is_lcrd_return(input rsp_flit_t flit);
    return (rsp_opcode_t'(flit.opcode) == rsp_opcode_t'(VIP_CHI_RSP_LCRD_RETURN_C));
  endfunction

  protected function bit dat_is_lcrd_return(input dat_flit_t flit);
    return (dat_opcode_t'(flit.opcode) == dat_opcode_t'(VIP_CHI_DAT_LCRD_RETURN_C));
  endfunction

  protected function bit snp_is_lcrd_return(input snp_flit_t flit);
    return (snp_opcode_t'(flit.opcode) == snp_opcode_t'(VIP_CHI_SNP_LCRD_RETURN_C));
  endfunction

  // ---------------------------------------------------------------------------
  // The parent agent owns the reset watcher and calls monitor_start().
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);
  endtask

  // ---------------------------------------------------------------------------
  // Drop any partially assembled DAT transactions on reset.
  // ---------------------------------------------------------------------------
  function void handle_reset();
    this.dat_item_by_key.delete();
    this.dat_received_beats_by_key.delete();
    this.dat_beat_seen_by_key.delete();
    this.rd_beats_by_txnid.delete();
    this.wr_beats_by_txnid.delete();
    this.wr_beats_by_dbid.delete();
    // The cycle base restarts with the link, along with the milestone records:
    // a latency spanning a reset is not a latency, the transaction was
    // abandoned. n_latency_violation is a whole-run tally and survives.
    this.cycle_count = 0;
    this.txn_times.delete();
    this.snp_times.delete();
  endfunction

  // ---------------------------------------------------------------------------
  // TRUE when a DAT opcode carries requester-sourced write / atomic-operand
  // data (keyed by DBID) rather than data returned to the requester.
  // ---------------------------------------------------------------------------
  protected function bit dat_opcode_is_write_data(input dat_opcode_t opcode);
    // CopyBackWrData (coherent writeback data) must count as write data too:
    // otherwise its staged wr_beats_by_dbid entry is never consumed/deleted (a
    // slow leak + stale-count hazard on DBID reuse) and the DAT item is
    // mislabelled a read. [P3(b)]
    return (opcode == dat_opcode_t'(VIP_CHI_DAT_NON_COPY_BACK_WR_DATA_C)) ||
           (opcode == dat_opcode_t'(VIP_CHI_DAT_NCB_WR_DATA_COMP_ACK_C))   ||
           (opcode == dat_opcode_t'(VIP_CHI_DAT_COPY_BACK_WR_DATA_C));
  endfunction

  // ---------------------------------------------------------------------------
  // TRUE for read opcodes whose returned data spans the request Size, so their
  // beat count can be derived up front and keyed by the (echoed) TxnID.
  // ---------------------------------------------------------------------------
  protected function bit req_opcode_is_plain_read(input req_opcode_t opcode);
    return (opcode == req_opcode_t'(VIP_CHI_REQ_READ_NO_SNP_C)) ||
           (opcode == req_opcode_t'(VIP_CHI_REQ_READ_NO_SNP_SEP_C));
  endfunction

  // ---------------------------------------------------------------------------
  // Map the opposite endpoint role for RX-channel observations.
  // ---------------------------------------------------------------------------
  protected function vip_chi_role_t peer_role();
    if (ROLE_P == VIP_CHI_ROLE_RNI_E) begin
      return VIP_CHI_ROLE_SNF_E;
    end

    if (ROLE_P == VIP_CHI_ROLE_SNF_E) begin
      return VIP_CHI_ROLE_RNI_E;
    end

    if (ROLE_P == VIP_CHI_ROLE_RNF_E) begin
      return VIP_CHI_ROLE_HNF_E;
    end

    if (ROLE_P == VIP_CHI_ROLE_HNF_E) begin
      return VIP_CHI_ROLE_RNF_E;
    end

    return VIP_CHI_ROLE_MONITOR_E;
  endfunction

  // ---------------------------------------------------------------------------
  // Infer request direction from the opcode carried on the REQ flit.
  // ---------------------------------------------------------------------------
  protected function vip_chi_dir_t direction_from_opcode(input req_opcode_t opcode);
    // WRITE = the requester ships data (or zeroes) upstream: the non-coherent
    // WriteNoSnp*, the coherent writebacks / WriteUnique, and the atomics (which
    // carry an operand). This mirrors driver_rni::req_expects_write_data (+ the
    // no-data WriteNoSnpZero); everything else (reads, CMOs, Evict, ...) is READ.
    // Atomics are matched in the WIDE opcode domain so a 7-bit atomic opcode
    // cannot alias a narrow CHI-D opcode. [P3(a)]
    if (vip_chi_types_pkg::vip_chi_req_opcode_is_atomic(vip_chi_req_opcode_t'(opcode))) begin
      return VIP_CHI_DIR_WRITE_E;
    end
    case (VIP_CHI_MAX_REQ_OPCODE_WIDTH_C'(opcode))
      VIP_CHI_REQ_WRITE_NO_SNP_PTL_C,
      VIP_CHI_REQ_WRITE_NO_SNP_FULL_C,
      VIP_CHI_REQ_WRITE_NO_SNP_ZERO_C,
      VIP_CHI_REQ_WRITE_BACK_FULL_C,
      VIP_CHI_REQ_WRITE_CLEAN_FULL_C,
      VIP_CHI_REQ_WRITE_UNIQUE_FULL_C,
      VIP_CHI_REQ_WRITE_UNIQUE_PTL_C: begin
        return VIP_CHI_DIR_WRITE_E;
      end
      default: begin
        return VIP_CHI_DIR_READ_E;
      end
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // Correlate REQ and DAT activity per observed endpoint and transaction id.
  // ---------------------------------------------------------------------------
  protected function string txn_key(
    input vip_chi_role_t observed_role,
    input node_id_t      src_id,
    input node_id_t      tgt_id,
    input txn_id_t       txn_id
  );
    return $sformatf("%0d_%0h_%0h_%0h", observed_role, src_id, tgt_id, txn_id);
  endfunction

  // ---------------------------------------------------------------------------
  // Publish one REQ flit as a CHI item.
  // ---------------------------------------------------------------------------
  protected function void publish_req(
    input req_flit_t      flit,
    input vip_chi_role_t  observed_role
  );
    item_t item;
    int    beats;

    item = new("monitor_req_item");
    // set_config seeds the item's CFG-derived widths/typedefs (item.new does not
    // take CFG_P), so field assignments below and any downstream item method use
    // the correct parameterization.
    item.set_config(CFG_P);
    item.role          = observed_role;
    item.direction     = this.direction_from_opcode(req_opcode_t'(flit.opcode));
    item.src_id        = node_id_t'(flit.srcid);
    item.tgt_id        = node_id_t'(flit.tgtid);
    item.txn_id        = txn_id_t'(flit.txnid);
    item.lp_id         = lpid_t'(flit.lpid);
    item.return_nid    = node_id_t'(flit.returnnid);
    item.return_txn_id = txn_id_t'(flit.returntxnid);
    item.qos           = flit.qos;
    item.opcode        = req_opcode_t'(flit.opcode);
    item.addr          = addr_t'(flit.addr);
    item.size          = size_t'(flit.size);
    item.ns            = flit.ns;
    item.tracetag      = flit.tracetag;
    // The mirror of the packer: one wire bit, decoded into whichever of the two
    // fields this opcode actually carries. Reporting it under the wrong name is
    // how a peer correctly asserting SnpAttr would show up as DoDWT.
    if (vip_chi_types_pkg::vip_chi_req_bit17_is_dodwt(
          CFG_P.ISSUE_P, vip_chi_req_opcode_t'(flit.opcode))) begin
      item.dodwt       = flit.snpattr;
      item.snp_attr    = VIP_CHI_SNP_NON_SNOOPABLE_E;
    end
    else begin
      item.snp_attr    = flit.snpattr;
      item.dodwt       = 1'b0;
    end
    item.likelyshared  = flit.likelyshared;
    item.endian        = flit.endian;
    item.order         = flit.order;
    item.mem_attr      = flit.memattr;
    item.pcrd_type     = flit.pcrdtype;
    item.allow_retry   = flit.allowretry;
    item.excl          = flit.excl;
    item.exp_comp_ack  = flit.expcompack;
    item.mpam          = mpam_t'(flit.mpam);
    this.capture_req_issue_specific_fields(flit, item);

    // Seed the REQ->DAT beat-count correlation. A plain read's data returns
    // under the same TxnID; a write / atomic operand's data ships under the
    // DBID granted later (staged here by TxnID, promoted on the grant RSP).
    if (this.req_opcode_is_plain_read(item.opcode)) begin
      beats = vip_chi_types_pkg::chi_xfer_dat_beats(item.size, CFG_P.DATA_BYTES_P);
      if (beats > 0) begin
        this.rd_beats_by_txnid[item.txn_id] = beats;
      end
    end
    else begin
      beats = item.get_payload_beat_count();
      if (beats > 0) begin
        this.wr_beats_by_txnid[item.txn_id] = beats;
      end
    end

    // A REQ on a TxnID that already saw a RetryAck is the re-issue, not a new
    // transaction: it keeps the original record so retry_count accumulates and
    // latency() can measure from the re-issue the completer is answerable for.
    begin
      txn_times_t rec;
      rec = this.txn_times.exists(item.txn_id) ? this.txn_times[item.txn_id]
                                               : txn_times_t'{default: 0};
      if (rec.t_retry_ack != 0) begin
        rec.t_req_reissued = this.cycle_count;
      end
      else begin
        rec = txn_times_t'{default: 0};
        rec.t_req_issued = this.cycle_count;
      end
      // Which bound will apply at completion. Recorded here because the request
      // opcode is the only place the direction is stated, and the completion
      // arrives on a different channel carrying a different item.
      rec.is_write = (item.direction == VIP_CHI_DIR_WRITE_E);
      this.txn_times[item.txn_id] = rec;
    end
    this.stamp_item(item, item.txn_id);

    this.record_begin(item, item.txn_id, "chi_req");

    this.req_port.write(item);
  endfunction

  // ---------------------------------------------------------------------------
  // Optional issue-specific REQ-field hook. The shared implementation only
  // captures fields present in both exact CHI-D and exact CHI-E REQ shapes.
  // ---------------------------------------------------------------------------
  virtual protected function void capture_req_issue_specific_fields(
    input req_flit_t flit,
    inout item_t     item
  );
  endfunction

  // ---------------------------------------------------------------------------
  // Optional issue-specific DAT-field hook. The shared implementation only
  // captures fields present in both exact CHI-D and exact CHI-E DAT shapes.
  // ---------------------------------------------------------------------------
  virtual protected function void capture_dat_issue_specific_fields(
    input dat_flit_t flit,
    inout item_t     item,
    input int        beat_index
  );
  endfunction

  // ---------------------------------------------------------------------------
  // Publish one RSP flit as a CHI item.
  // ---------------------------------------------------------------------------
  protected function void publish_rsp(
    input rsp_flit_t      flit,
    input vip_chi_role_t  observed_role
  );
    item_t item;

    item = new("monitor_rsp_item");
    item.set_config(CFG_P);
    item.role       = observed_role;
    // A response has no intrinsic direction; label the DBID-carrying write
    // grants WRITE so consumers see a meaningful value rather than the default.
    item.direction  =
      ((rsp_opcode_t'(flit.opcode) == rsp_opcode_t'(VIP_CHI_RSP_COMP_DBID_RESP_C)) ||
       (rsp_opcode_t'(flit.opcode) == rsp_opcode_t'(VIP_CHI_RSP_DBID_RESP_C))      ||
       (rsp_opcode_t'(flit.opcode) == rsp_opcode_t'(VIP_CHI_RSP_DBID_RESP_ORD_C))) ?
        VIP_CHI_DIR_WRITE_E : VIP_CHI_DIR_READ_E;
    item.src_id     = node_id_t'(flit.srcid);
    item.tgt_id     = node_id_t'(flit.tgtid);
    item.txn_id     = txn_id_t'(flit.txnid);
    item.dbid       = txn_id_t'(flit.dbid);
    item.qos        = flit.qos;
    item.rsp_opcode = rsp_opcode_t'(flit.opcode);
    item.rsp_resp   = vip_chi_resp_t'(flit.resp);
    item.rsp_resp_err = vip_chi_resp_err_t'(flit.resperr);
    item.fwd_state  = flit.fwdstate;
    item.pcrd_type  = flit.pcrdtype;

    // On a DBID-carrying grant, promote the staged write/operand beat count
    // from the requester TxnID to the DBID the data will actually ship under.
    if (((item.rsp_opcode == rsp_opcode_t'(VIP_CHI_RSP_COMP_DBID_RESP_C)) ||
         (item.rsp_opcode == rsp_opcode_t'(VIP_CHI_RSP_DBID_RESP_C))      ||
         (item.rsp_opcode == rsp_opcode_t'(VIP_CHI_RSP_DBID_RESP_ORD_C))) &&
        this.wr_beats_by_txnid.exists(item.txn_id)) begin
      this.wr_beats_by_dbid[item.dbid] = this.wr_beats_by_txnid[item.txn_id];
      this.wr_beats_by_txnid.delete(item.txn_id);
    end

    begin
      txn_times_t rec;
      bit         is_completion;
      rec = this.txn_times.exists(item.txn_id) ? this.txn_times[item.txn_id]
                                               : txn_times_t'{default: 0};
      is_completion =
        (item.rsp_opcode == rsp_opcode_t'(VIP_CHI_RSP_COMP_C)) ||
        (item.rsp_opcode == rsp_opcode_t'(VIP_CHI_RSP_COMP_DBID_RESP_C)) ||
        (item.rsp_opcode == rsp_opcode_t'(VIP_CHI_RSP_COMP_PERSIST_C));

      if (((item.rsp_opcode == rsp_opcode_t'(VIP_CHI_RSP_COMP_DBID_RESP_C)) ||
           (item.rsp_opcode == rsp_opcode_t'(VIP_CHI_RSP_DBID_RESP_C))      ||
           (item.rsp_opcode == rsp_opcode_t'(VIP_CHI_RSP_DBID_RESP_ORD_C))) &&
          (rec.t_dbid == 0)) begin
        rec.t_dbid = this.cycle_count;
      end
      if (is_completion && (rec.t_comp == 0)) begin
        rec.t_comp = this.cycle_count;
      end
      if ((item.rsp_opcode == rsp_opcode_t'(VIP_CHI_RSP_COMP_ACK_C)) &&
          (rec.t_compack == 0)) begin
        rec.t_compack = this.cycle_count;
      end
      if (item.rsp_opcode == rsp_opcode_t'(VIP_CHI_RSP_RETRY_ACK_C)) begin
        rec.t_retry_ack = this.cycle_count;
        rec.retry_count++;
      end
      // CHI makes PCrdGrant credit-typed rather than TxnID-correlated, so this
      // is only as good as the completer's choice of TxnID on the grant. It is
      // recorded for visibility, never used by a bound.
      if ((item.rsp_opcode == rsp_opcode_t'(VIP_CHI_RSP_PCRD_GRANT_C)) &&
          (rec.t_pcrd_grant == 0)) begin
        rec.t_pcrd_grant = this.cycle_count;
      end
      this.txn_times[item.txn_id] = rec;
      this.stamp_item(item, item.txn_id);

      // A transaction whose completion is an RSP (a write, a data-less acquire,
      // a persist) is bounded here. A read completes on DAT and is bounded there.
      if (is_completion) begin
        this.check_latency_bound(item, item.txn_id, rec.is_write);
        this.record_end(item.txn_id);
      end
    end

    // A snoop answers with SnpResp on RSP; that closes its latency window.
    if ((item.rsp_opcode == rsp_opcode_t'(VIP_CHI_RSP_SNP_RESP_C)) ||
        (item.rsp_opcode == rsp_opcode_t'(VIP_CHI_RSP_SNP_RESP_FWDED_C))) begin
      this.close_snoop(item, item.txn_id);
    end

    this.rsp_port.write(item);
  endfunction

  // ---------------------------------------------------------------------------
  // Publish one DAT flit as a one-beat CHI item.
  // ---------------------------------------------------------------------------
  protected function void publish_dat(
    input dat_flit_t      flit,
    input logic           flit_pending,
    input vip_chi_role_t  observed_role
  );
    item_t     item;
    string     key;
    txn_id_t   dat_txn_id;
    bit        is_write_data;
    int        expected_beats;
    int              alloc_beats;
    int              beat_index;
    bit              place_beat;
    bit              transfer_done;
    dat_beat_seen_t  beat_seen;

    dat_txn_id    = txn_id_t'(flit.txnid);
    is_write_data = this.dat_opcode_is_write_data(dat_opcode_t'(flit.opcode));

    // Correlated beat count for this transfer: write/operand data is keyed by
    // the granted DBID, returned read data by the (echoed) requester TxnID.
    // 0 means "unknown" -> fall back to the advisory FLITPEND deassert.
    expected_beats = 0;
    if (is_write_data) begin
      if (this.wr_beats_by_dbid.exists(dat_txn_id)) begin
        expected_beats = this.wr_beats_by_dbid[dat_txn_id];
      end
    end
    else begin
      if (this.rd_beats_by_txnid.exists(dat_txn_id)) begin
        expected_beats = this.rd_beats_by_txnid[dat_txn_id];
      end
    end

    key = this.txn_key(
      observed_role,
      node_id_t'(flit.srcid),
      node_id_t'(flit.tgtid),
      dat_txn_id);

    if (!this.dat_item_by_key.exists(key)) begin
      alloc_beats = (expected_beats > 0) ? expected_beats : 1;

      item = new("monitor_dat_item");
      item.set_config(CFG_P);
      item.role       = observed_role;
      item.direction  = is_write_data ? VIP_CHI_DIR_WRITE_E : VIP_CHI_DIR_READ_E;
      item.src_id     = node_id_t'(flit.srcid);
      item.tgt_id     = node_id_t'(flit.tgtid);
      item.txn_id     = dat_txn_id;
      item.dbid       = txn_id_t'(flit.dbid);
      item.qos        = flit.qos;
      item.poison     = poison_t'(flit.poison);
      item.datacheck  = datacheck_t'(flit.datacheck);
      item.dat_opcode = dat_opcode_t'(flit.opcode);

      item.data         = new[alloc_beats];
      item.be           = new[alloc_beats];
      item.tag          = new[alloc_beats];
      item.dat_tagop_beats = new[alloc_beats];
      item.tu           = new[alloc_beats];
      item.data_id      = new[alloc_beats];
      item.cc_id        = new[alloc_beats];
      item.dat_resp     = new[alloc_beats];
      item.dat_resp_err = new[alloc_beats];

      this.dat_item_by_key[key] = item;
      this.dat_received_beats_by_key[key] = 0;
      if (expected_beats > 0) begin
        beat_seen = new[expected_beats];
        this.dat_beat_seen_by_key[key] = beat_seen;
      end
      // First beat of this transfer. Recorded against the DAT TxnID, which for
      // write data is the granted DBID rather than the request's own TxnID --
      // the same correlation the beat-count bookkeeping above uses.
      begin
        txn_times_t rec;
        rec = this.txn_times.exists(dat_txn_id) ? this.txn_times[dat_txn_id]
                                                : txn_times_t'{default: 0};
        if (rec.t_first_dat == 0) begin
          rec.t_first_dat = this.cycle_count;
        end
        this.txn_times[dat_txn_id] = rec;
      end
    end

    item = this.dat_item_by_key[key];

    if (this.collect_beat_timestamps) begin
      item.t_dat_beats = new[item.t_dat_beats.size() + 1](item.t_dat_beats);
      item.t_dat_beats[item.t_dat_beats.size() - 1] = this.cycle_count;
    end

    // Place by DataID when the beat count is known; the running receive counter
    // stays the index only where no count is available to bound DataID against.
    place_beat = 1'b1;
    if (expected_beats > 0) begin
      // The beat count can only become known once the correlating REQ or DBID
      // grant has been seen. That always precedes the data in this VIP, but an
      // item opened on the unknown-count path must still be placeable if it does
      // not: size the placement state on first use rather than assuming it.
      if (!this.dat_beat_seen_by_key.exists(key)) begin
        beat_seen = new[expected_beats];
        this.dat_beat_seen_by_key[key] = beat_seen;
      end
      else if (this.dat_beat_seen_by_key[key].size() < expected_beats) begin
        beat_seen = new[expected_beats](this.dat_beat_seen_by_key[key]);
        this.dat_beat_seen_by_key[key] = beat_seen;
      end

      beat_index = int'(flit.dataid);

      if (beat_index >= expected_beats) begin
        // Unplaceable: report it and drop the payload, but still count the beat
        // so the transfer retires. Its empty slot is named at transfer close.
        `uvm_error(get_name(), $sformatf(
          "[%s] DAT DataID %0d is outside the %0d-beat transfer for txn_id 0x%0h -- beat dropped",
          get_name(), beat_index, expected_beats, dat_txn_id))
        place_beat = 1'b0;
      end
      else begin
        if (this.dat_beat_seen_by_key[key][beat_index]) begin
          `uvm_error(get_name(), $sformatf(
            "[%s] duplicate DAT DataID %0d for txn_id 0x%0h: this beat position was already delivered",
            get_name(), beat_index, dat_txn_id))
        end
        this.dat_beat_seen_by_key[key][beat_index] = 1'b1;
      end
    end
    else begin
      beat_index = this.dat_received_beats_by_key[key];
    end

    if (!place_beat) begin
      this.dat_received_beats_by_key[key]++;
      if (this.dat_received_beats_by_key[key] >= expected_beats) begin
        this.retire_dat_transfer(key, item, dat_txn_id, is_write_data, expected_beats);
      end
      return;
    end

    if (beat_index >= item.data.size()) begin
      item.data         = new[beat_index + 1](item.data);
      item.be           = new[beat_index + 1](item.be);
      item.tag          = new[beat_index + 1](item.tag);
      item.dat_tagop_beats = new[beat_index + 1](item.dat_tagop_beats);
      item.tu           = new[beat_index + 1](item.tu);
      item.data_id      = new[beat_index + 1](item.data_id);
      item.cc_id        = new[beat_index + 1](item.cc_id);
      item.dat_resp     = new[beat_index + 1](item.dat_resp);
      item.dat_resp_err = new[beat_index + 1](item.dat_resp_err);
    end

    item.data[beat_index]         = data_t'(flit.data);
    item.be[beat_index]           = be_t'(flit.be);
    item.data_id[beat_index]      = data_id_t'(flit.dataid);
    item.cc_id[beat_index]        = cc_id_t'(flit.ccid);
    item.dat_resp[beat_index]     = vip_chi_resp_t'(flit.resp);
    item.dat_resp_err[beat_index] = vip_chi_resp_err_t'(flit.resperr);
    this.capture_dat_issue_specific_fields(flit, item, beat_index);

    this.dat_received_beats_by_key[key]++;

    // Retire on the correlated beat count when known (robust to a DUT that
    // holds or bubbles FLITPEND); otherwise trust the advisory FLITPEND.
    if (expected_beats > 0) begin
      transfer_done = (this.dat_received_beats_by_key[key] >= expected_beats);
    end
    else begin
      transfer_done = !flit_pending;
    end

    if (transfer_done) begin
      this.retire_dat_transfer(key, item, dat_txn_id, is_write_data, expected_beats);
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Publish a completed DAT transfer and drop its reassembly state.
  //
  // Every beat position must have been filled. On the DataID-placed path a
  // duplicate or out-of-range DataID consumes a beat of the expected count
  // without filling its slot, so the gap it leaves is named here instead of
  // being published as an untouched (zero) beat that reads as a data mismatch.
  // ---------------------------------------------------------------------------
  protected function void retire_dat_transfer(
    input string   key,
    input item_t   item,
    input txn_id_t dat_txn_id,
    input bit      is_write_data,
    input int      expected_beats
  );
    if ((expected_beats > 0) && this.dat_beat_seen_by_key.exists(key)) begin
      for (int i = 0; i < expected_beats; i++) begin
        if (!this.dat_beat_seen_by_key[key][i]) begin
          `uvm_error(get_name(), $sformatf(
            "[%s] DAT transfer for txn_id 0x%0h closed with no beat carrying DataID %0d (of %0d)",
            get_name(), dat_txn_id, i, expected_beats))
        end
      end
    end

    begin
      txn_times_t rec;
      rec = this.txn_times.exists(dat_txn_id) ? this.txn_times[dat_txn_id]
                                              : txn_times_t'{default: 0};
      rec.t_last_dat = this.cycle_count;
      this.txn_times[dat_txn_id] = rec;
      this.stamp_item(item, dat_txn_id);

      // Read data IS the completion; write data is not (its Comp bounds it on
      // the RSP side), so only the read direction is bounded here.
      if (!is_write_data) begin
        this.check_latency_bound(item, dat_txn_id, 1'b0);
        this.record_end(dat_txn_id);
      end
    end

    // A snoop may answer with a SnpRespData family burst; that closes its
    // latency window just as a SnpResp on RSP would.
    if ((item.dat_opcode == dat_opcode_t'(VIP_CHI_DAT_SNP_RESP_DATA_C)) ||
        (item.dat_opcode == dat_opcode_t'(VIP_CHI_DAT_SNP_RESP_DATA_PTL_C)) ||
        (item.dat_opcode == dat_opcode_t'(VIP_CHI_DAT_SNP_RESP_DATA_FWDED_C))) begin
      this.close_snoop(item, dat_txn_id);
    end

    this.dat_port.write(item);
    this.dat_item_by_key.delete(key);
    this.dat_received_beats_by_key.delete(key);
    this.dat_beat_seen_by_key.delete(key);
    if (is_write_data) begin
      this.wr_beats_by_dbid.delete(dat_txn_id);
    end
    else begin
      this.rd_beats_by_txnid.delete(dat_txn_id);
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Publish one SNP flit as a CHI item (single flit, no reassembly). The snoop
  // response (SnpResp on RSP, SnpRespData on DAT) is captured by publish_rsp /
  // publish_dat once those opcodes exist -- no extra work here.
  // ---------------------------------------------------------------------------
  protected function void publish_snp(
    input snp_flit_t     flit,
    input vip_chi_role_t observed_role
  );
    item_t item;

    item = new("monitor_snp_item");
    item.set_config(CFG_P);
    item.role             = observed_role;
    item.is_snoop         = 1'b1;
    item.src_id           = node_id_t'(flit.srcid);
    item.txn_id           = txn_id_t'(flit.txnid);
    item.fwd_nid          = node_id_t'(flit.fwdnid);
    item.fwd_txn_id       = txn_id_t'(flit.fwdtxnid);
    item.snp_opcode       = flit.opcode;
    item.snp_addr         = addr_t'(flit.addr);
    item.ns               = flit.ns;
    item.ret_to_src       = flit.rettosrc;
    item.do_not_data_pull = flit.donotdatapull;
    item.tracetag         = flit.tracetag;
    item.qos              = flit.qos;

    begin
      txn_times_t rec;
      rec = txn_times_t'{default: 0};
      rec.t_req_issued = this.cycle_count;
      this.snp_times[item.txn_id] = rec;
      item.t_req_issued = this.cycle_count;
    end

    // Its own stream rather than a child of the request that caused it, and the
    // reason is structural rather than a shortcut. A snoop leaves the home on a
    // DIFFERENT port from the one the originating request arrived on, so the two
    // are seen by two different monitor instances and neither holds the other's
    // transaction handle. Parenting across them would need a handle registry
    // shared by every monitor on the home -- which is the "snoop nesting" half of
    // this task, and is left out on purpose rather than faked. The snoop's TxnID
    // is on both streams, so a reader can still correlate them by eye.
    this.record_begin(item, item.txn_id, "chi_snp", 1'b1);

    this.snp_port.write(item);
  endfunction

endclass

`endif