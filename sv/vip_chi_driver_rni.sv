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

`ifndef VIP_CHI_DRIVER_RNI
`define VIP_CHI_DRIVER_RNI

import uvm_pkg::*;
`include "uvm_macros.svh"
import vip_chi_types_pkg::*;

class vip_chi_driver_rni #(
  vip_chi_cfg_t  CFG_P        = VIP_CHI_DEFAULT_CFG_C,
  type           FLIT_TYPES_T = vip_chi_types #(CFG_P),
  // Requester role of the driven link. Defaults to RN-I so every existing
  // instantiation (#(CFG,FLIT)) is byte-identical. The coherent RN-F driver
  // extends this class with ROLE_P=VIP_CHI_ROLE_RNF_E: the RNF interface arm
  // exposes a clocking block ALSO named rni_cb (a superset carrying the SNP
  // receive channel + txsnplcrdv), so this whole body binds unchanged there.
  vip_chi_role_t ROLE_P       = VIP_CHI_ROLE_RNI_E
  ) extends uvm_driver #(vip_chi_item #(CFG_P));

  typedef vip_chi_item #(CFG_P)                item_t;
  typedef vip_chi_types #(CFG_P)::node_id_t    node_id_t;
  typedef vip_chi_types #(CFG_P)::txn_id_t     txn_id_t;
  typedef vip_chi_types #(CFG_P)::data_t       data_t;
  typedef vip_chi_types #(CFG_P)::be_t         be_t;
  typedef vip_chi_types #(CFG_P)::data_id_t    data_id_t;
  typedef vip_chi_types #(CFG_P)::cc_id_t      cc_id_t;
  typedef vip_chi_types #(CFG_P)::req_opcode_t req_opcode_t;
  typedef vip_chi_types #(CFG_P)::rsp_opcode_t rsp_opcode_t;
  typedef vip_chi_types #(CFG_P)::dat_opcode_t dat_opcode_t;
  typedef item_t::raw_req_t                    raw_req_t;
  typedef item_t::raw_rsp_t                    raw_rsp_t;
  typedef item_t::raw_dat_t                    raw_dat_t;
  typedef FLIT_TYPES_T::vip_chi_req_flit_t     req_flit_t;
  typedef FLIT_TYPES_T::vip_chi_dat_flit_t     dat_flit_t;
  typedef FLIT_TYPES_T::vip_chi_rsp_flit_t     rsp_flit_t;

  virtual vip_chi_if #(CFG_P, FLIT_TYPES_T, ROLE_P)            vif_rni;
  vip_chi_cfg_agent                                            cfg;

  protected txn_id_t next_txn_id = '0;

  // Outstanding-transaction TxnID pool. Sized by the number of in-flight
  // transactions (<= cfg.max_outstanding_*), NEVER by 2**txn_id_width: the
  // allocator only ever scans this queue, so it stays small and
  // elaboration-safe. A 2**txn_id_width in-flight table blew the VCS
  // elaboration/codegen budget in an earlier probe (see IMPLEMENTATION_PLAN
  // P4 notes); this queue form is the replacement probe strategy.
  protected txn_id_t outstanding_ids[$];

  // MIXED read+write pipeline context (cfg.multi_outstanding). One loop overlaps
  // plain ReadNoSnp and plain WriteNoSnpFull so a single test can pipeline reads
  // and writes together (write-then-read data-integrity checks, or concurrent
  // bidirectional traffic). Same outstanding-count sizing discipline as the
  // outstanding_ids pool above: scanned linearly, bounded by
  // cfg.max_outstanding_read/write, never by 2**txn_id_width. Only the TX thread
  // mutates the queue structure, while the two completion monitors set per-entry
  // flags (reads complete on inbound DAT, writes on inbound RSP).
  typedef enum bit [1:0] {TXN_KIND_READ, TXN_KIND_WRITE, TXN_KIND_ATOMIC, TXN_KIND_PERSIST} txn_kind_e;

  typedef struct {
    txn_kind_e kind;
    item_t     item;
    txn_id_t   dbid;
    bit        grant_seen;
    bit        comp_seen;
    bit        data_sent;
    bit        read_done;
    bit        receipt_seen;   // ordered reads: ReadReceipt (RSP) has arrived
    // Separated persist: Comp says Point of Coherency, Persist says Point of
    // Persistence, and the transaction is not done until BOTH have arrived --
    // or a single CompPersist has, which is both at once. comp_seen alone would
    // retire on the Comp and leave the Persist to arrive against a closed
    // transaction.
    bit        persist_seen;
    bit        compack_sent;   // exp_comp_ack writes: CompAck has been driven
    bit        retry_pending;  // RetryAck seen; awaiting a P-credit to re-issue
    bit        retried;        // already re-issued once (allow_retry now cleared)
    vip_chi_pcrd_type_t pcrd_type;  // PCrdType owed by the RetryAck
    node_id_t  req_src_id;     // original REQ src/tgt (stamp overwrites item's),
    node_id_t  req_tgt_id;     // captured at issue for the CompAck flit
  } mx_ctx_t;

  protected mx_ctx_t mx_ctx [$];

  // Read-data beats banked per in-flight transfer, keyed by the TxnID the
  // completion carries. A completer may interleave the beats of several reads on
  // the DAT channel, so a beat is filed against the transaction its TxnID names
  // rather than assumed to belong to whichever read is currently being
  // collected. Kept beside mx_ctx rather than inside it because the context
  // queue is indexed by position and shifts as entries retire, while a TxnID
  // does not move. Entries are deleted the moment their transfer is placed.
  protected dat_flit_t mx_dat_beats [txn_id_t][$];

  // Pipeline P-credit pool: PCrdGrant is credit-typed, not TxnID-tied, so a
  // grant banks one credit of its PCrdType here and any bounced pipeline entry
  // owed that type consumes one to re-issue (mirrors the serial handle_retry,
  // which can pair its single RetryAck/PCrdGrant directly).
  protected int unsigned pcrd_pool [vip_chi_pcrd_type_t];
  // PCrdType -> the granter's SrcID and our own NodeID, both taken off the
  // PCrdGrant. PCrdReturn must carry the granter as its TgtID ("the TgtID must
  // match the SrcID of the credit that was obtained") and this requester as its
  // SrcID, so both identities have to survive banking; the count alone cannot
  // say where to send the credit back. They come off the grant rather than out
  // of config because the grant is addressed to us: its TgtID is this requester.
  protected node_id_t    pcrd_granter [vip_chi_pcrd_type_t];
  protected node_id_t    pcrd_own_id  [vip_chi_pcrd_type_t];
  int unsigned           n_pcrd_returned = 0;

  protected vip_chi_lcrd_mgr req_lcrd_mgr;
  protected vip_chi_lcrd_mgr rsp_lcrd_mgr;
  protected vip_chi_lcrd_mgr dat_lcrd_mgr;
  protected int unsigned     rsp_lcrdv_pulses_pending;
  protected int unsigned     dat_lcrdv_pulses_pending;

  // Set once the first inbound DAT flit is seen; cfg.hold_dat_credit only takes
  // effect afterwards so the initial credit advertisement still bootstraps.
  protected bit seen_rx_dat_flit;

  // One-shot latch for cfg.lasm_abort_activation (see activate_link): the
  // negative control aborts a single bring-up, so the LASM check has exactly one
  // illegal transition to report. Cleared in handle_reset, so a test that resets
  // mid-run gets the control again on the next activation rather than silently
  // losing it.
  protected bit lasm_abort_done;

  // One-shot latch for cfg.flitpend_without_valid, same reasoning as the abort
  // above: the control fires once so the count a test asserts on is unambiguous.
  protected bit flitpend_negctl_done;

  // One-shot latch for cfg.lasm_reactivate_during_deactivate, same reasoning as
  // the other controls: it fires once so the count a test asserts on is
  // unambiguous.
  protected bit lasm_race_done;

  // Shadow of the activation request last driven. A clocking-block OUTPUT cannot
  // be sampled, so the per-state delay -- which needs the CURRENT link state,
  // and the request is half of it -- reads this instead of the wire. Written by
  // drive_link_req, which is the only thing that drives the signal, so the two
  // cannot disagree.
  protected bit req_driven;

  // Graceful-deactivation state (see deactivate_watch).
  //
  // link_deactivating suppresses NEW receive-credit grants: a receiver may not
  // issue L-credits once the link is coming down, or the drain would be chasing
  // a pool the credit loop keeps refilling and would never finish.
  //
  // rsp/dat_lcrd_granted are the credits this node has advertised and the peer
  // has not yet spent -- the mirror image of the send-side managers, and the
  // half of quiescence a sender cannot see from its own pools. The link is only
  // drained when BOTH halves are empty at both ends.
  protected bit          link_deactivating;
  protected int unsigned rsp_lcrd_granted;
  protected int unsigned dat_lcrd_granted;

  // Single mutex arbitrating the txreq/txrsp/txdat flit groups. In RN-I there
  // is exactly one flit-driving
  // thread (seq_loop / mixed_tx_proc), so this key is always immediately
  // available and adds zero simulation time -- the existing waveforms are
  // byte-identical. It becomes load-bearing in RN-F, where the autonomous
  // snoop responder drives the RSP/DAT channels concurrently with the request
  // thread: every flit-driving critical section takes the key so the two
  // threads never drive the shared TX signals in the same cycle. The key is
  // acquired only AFTER wait_for_credit() and held only across the two
  // beat-driving clock edges, never across a credit wait or a completion wait,
  // so it can never wedge against another flit driver (M4 dirty-forwarding /
  // writeback rely on this).
  protected semaphore tx_flit_arb;

  // TXSACTIVE outstanding-window state. See tx_activity_begin().
  protected int unsigned tx_active_count;
  protected int unsigned tx_active_extend;

  `uvm_component_param_utils(vip_chi_driver_rni #(CFG_P, FLIT_TYPES_T, ROLE_P))

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent);
    super.new(name, parent);
    this.tx_flit_arb = new(1);
  endfunction

  // ---------------------------------------------------------------------------
  // Validate parent-assigned handles.
  // ---------------------------------------------------------------------------
  function void build_phase(input uvm_phase phase);

    super.build_phase(phase);

    if (!uvm_config_db #(virtual vip_chi_if #(CFG_P, FLIT_TYPES_T, ROLE_P))::get(this, "", "vif", this.vif_rni)) begin

      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] driver.vif must be assigned by the parent agent",
      get_name()))
    end

    if (this.cfg == null) begin

      this.cfg = vip_chi_cfg_agent::type_id::create("default_cfg");
      this.cfg.role = ROLE_P;
    end

    this.reset_credit_state();
  endfunction

  // ---------------------------------------------------------------------------
  // Keep the always-on link acknowledgement and completion credits coherent
  // while the RN-I is waiting or driving traffic.
  // ---------------------------------------------------------------------------
  protected task drive_idle_sideband();
    this.vif_rni.g_drv.rni_cb.txlinkactiveack <= this.vif_rni.g_drv.rni_cb.rxlinkactivereq;
  endtask

  // ---------------------------------------------------------------------------
  // TXSACTIVE outstanding-window drive.
  //
  // TXSACTIVE tells the receiver this node MAY have snoopable transactions
  // outstanding, so it must stay asserted across that WHOLE window -- not
  // bracket each flit. A per-flit pulse drops the signal to zero while requests
  // are still in flight, which is precisely the interval a receiver reads it to
  // decide whether it can gate its snoop logic.
  //
  // So the signal is a level driven from a counter rather than a pulse driven
  // by whoever happens to be sending. Every transaction brackets itself with
  // begin/end, and the count -- not any one transaction -- decides the level.
  // That is what makes overlapping transactions correct: with the pipeline
  // running, one transaction retiring no longer drops the sideband out from
  // under the others still outstanding.
  //
  // The window counted here is EVERY outstanding transaction, not just the
  // snoopable ones. Over-assertion is always legal (the signal is permissive --
  // "may have"), under-assertion is the protocol violation, and counting
  // uniformly keeps one mechanism across roles that have no snoopable traffic
  // at all. cfg.txsactive_extend_max_cycles then holds it a bounded number of
  // cycles past the close, modelling a node that speculates on more traffic.
  //
  // Assertion is immediate (in the caller's cycle, as the old per-flit pulse
  // was) and only the DROP is deferred to the per-cycle tick, so the sideband
  // still rises in the same cycle as the first flit it covers.
  // ---------------------------------------------------------------------------
  protected function void tx_activity_begin();
    this.tx_active_count++;
    this.tx_active_extend = 0;
    this.vif_rni.g_drv.rni_cb.txsactive <= 1'b1;
  endfunction

  protected function void tx_activity_end();
    if (this.tx_active_count > 0) begin
      this.tx_active_count--;
    end
    if (this.tx_active_count == 0) begin
      this.tx_active_extend = this.cfg.txsactive_extend_max_cycles;
    end
  endfunction

  // Called once per cycle from credit_loop -- once, so the extension counts
  // cycles rather than callers. With the default extension of 0 the drop lands
  // on the first edge after the window closes, which is the cycle the per-flit
  // pulse used to drop on.
  protected function void tx_activity_tick();
    if (this.tx_active_count > 0) begin
      return;
    end
    if (this.tx_active_extend > 0) begin
      this.tx_active_extend--;
      return;
    end
    this.vif_rni.g_drv.rni_cb.txsactive <= 1'b0;
  endfunction

  // ---------------------------------------------------------------------------
  // Reset the counted local send budgets and the queued outbound LCRDV pulses.
  // ---------------------------------------------------------------------------
  protected function void reset_credit_state();

    if (this.req_lcrd_mgr == null) begin
      this.req_lcrd_mgr = vip_chi_lcrd_mgr::type_id::create("req_lcrd_mgr");
    end

    if (this.rsp_lcrd_mgr == null) begin
      this.rsp_lcrd_mgr = vip_chi_lcrd_mgr::type_id::create("rsp_lcrd_mgr");
    end

    if (this.dat_lcrd_mgr == null) begin
      this.dat_lcrd_mgr = vip_chi_lcrd_mgr::type_id::create("dat_lcrd_mgr");
    end

    this.req_lcrd_mgr.reset(this.cfg.req_send_credit_cap, 0);
    this.rsp_lcrd_mgr.reset(this.cfg.rsp_send_credit_cap, 0);
    this.dat_lcrd_mgr.reset(this.cfg.dat_send_credit_cap, 0);
    this.rsp_lcrdv_pulses_pending = 0;
    this.dat_lcrdv_pulses_pending = 0;
    this.rsp_lcrd_granted = 0;
    this.dat_lcrd_granted = 0;
    this.link_deactivating = 1'b0;
    this.seen_rx_dat_flit = 1'b0;
  endfunction

  // ---------------------------------------------------------------------------
  // RN-I consumes inbound RSP/DAT flits, so it must advertise those initial
  // receive credits on the wire after link activation.
  // ---------------------------------------------------------------------------
  protected function void schedule_initial_credit_grants();
    this.rsp_lcrdv_pulses_pending += this.cfg.initial_rsp_credits;
    this.dat_lcrdv_pulses_pending += this.cfg.initial_dat_credits;
  endfunction

  // ---------------------------------------------------------------------------
  // Reset all RN-I driven outputs to the idle state.
  // ---------------------------------------------------------------------------
  protected function void reset_outputs();
    this.drive_link_req(1'b0);
    this.vif_rni.g_drv.rni_cb.txlinkactiveack <= 1'b0;
    this.vif_rni.g_drv.rni_cb.txsactive       <= 1'b0;

    this.vif_rni.g_drv.rni_cb.txreqflitpend   <= 1'b0;
    this.vif_rni.g_drv.rni_cb.txreqflitv      <= 1'b0;
    this.vif_rni.g_drv.rni_cb.txreqflit       <= '0;

    this.vif_rni.g_drv.rni_cb.txrspflitpend   <= 1'b0;
    this.vif_rni.g_drv.rni_cb.txrspflitv      <= 1'b0;
    this.vif_rni.g_drv.rni_cb.txrspflit       <= '0;
    this.vif_rni.g_drv.rni_cb.txrsplcrdv      <= 1'b0;

    this.vif_rni.g_drv.rni_cb.txdatflitpend   <= 1'b0;
    this.vif_rni.g_drv.rni_cb.txdatflitv      <= 1'b0;
    this.vif_rni.g_drv.rni_cb.txdatflit       <= '0;
    this.vif_rni.g_drv.rni_cb.txdatlcrdv      <= 1'b0;
  endfunction

  // ---------------------------------------------------------------------------
  // PrefetchTgt is modeled as a no-completion hint, so the RN-I should retire
  // it locally instead of waiting for DAT on the completion path.
  // ---------------------------------------------------------------------------
  protected function bit req_expects_read_completion(input item_t req);
    return (req.opcode != req_opcode_t'(VIP_CHI_REQ_PREFETCH_TGT_C));
  endfunction

  // ---------------------------------------------------------------------------
  // Full and partial writes must wait for a DBID-carrying response before DAT.
  // ---------------------------------------------------------------------------
  protected function bit req_expects_write_data(input item_t req);

    case (req.opcode)

      req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_FULL_C),
      req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_PTL_C),
      // Coherent writebacks carry a CopyBackWrData burst after the DBID grant.
      req_opcode_t'(VIP_CHI_REQ_WRITE_BACK_FULL_C),
      req_opcode_t'(VIP_CHI_REQ_WRITE_CLEAN_FULL_C),
      // WriteUnique carries a NonCopyBackWrData burst after the DBID grant.
      req_opcode_t'(VIP_CHI_REQ_WRITE_UNIQUE_FULL_C),
      req_opcode_t'(VIP_CHI_REQ_WRITE_UNIQUE_PTL_C): begin
        return 1'b1;
      end

      default: begin
        // A combined Write + CMO carries the write's data burst like any other
        // write; the CMO half adds responses, not data.
        if (vip_chi_types_pkg::vip_chi_req_opcode_is_combined_write_cmo(
              vip_chi_req_opcode_t'(req.opcode))) begin
          return 1'b1;
        end
        return vip_chi_types_pkg::vip_chi_req_opcode_is_atomic(vip_chi_req_opcode_t'(req.opcode));
      end
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // A combined Write + CMO owes the requester a SECOND completion.
  //
  // The write half completes exactly like an ordinary write, so without this the
  // driver would retire the transaction on the write's completion alone and
  // leave the CMO's CompCMO -- and, for the persistent forms, its Persist --
  // sitting in the response stream to be mistaken for the NEXT transaction's
  // completion. That is not hypothetical: it is what happened the first time
  // this ran, and it surfaced as a wrong-opcode assertion on an unrelated write.
  // ---------------------------------------------------------------------------
  protected function bit req_is_combined_write_cmo(input item_t req);
    return vip_chi_types_pkg::vip_chi_req_opcode_is_combined_write_cmo(
      vip_chi_req_opcode_t'(req.opcode));
  endfunction

  protected function bit req_expects_combined_persist(input item_t req);
    return vip_chi_types_pkg::vip_chi_req_opcode_combined_cmo_is_persist(
      vip_chi_req_opcode_t'(req.opcode));
  endfunction

  // --------------------------------------------------------------------------
  // Non-store atomics complete with CompData after the operand DAT phase.
  // --------------------------------------------------------------------------
  protected function bit req_expects_atomic_data_completion(input item_t req);
    return vip_chi_types_pkg::vip_chi_req_opcode_is_atomic_returning_data(
      vip_chi_req_opcode_t'(req.opcode));
  endfunction

  // ---------------------------------------------------------------------------
  // CleanSharedPersistSep returns two RSP completions and never carries DAT.
  // ---------------------------------------------------------------------------
  protected function bit req_expects_persist_sep_completion(input item_t req);
    return (req.opcode == req_opcode_t'(VIP_CHI_REQ_CLEAN_SHARED_PERSIST_SEP_C));
  endfunction

  // ---------------------------------------------------------------------------
  // Ordered reads expect one ReadReceipt on the RSP channel before CompData.
  // ---------------------------------------------------------------------------
  protected function bit req_expects_read_receipt(input item_t req);
    return (req_expects_read_completion(req) &&
            (vip_chi_req_order_t'(req.order) != VIP_CHI_ORDER_NONE_E));
  endfunction

  // ---------------------------------------------------------------------------
  // Separated reads return DAT on ReturnTxnID rather than the request TxnID.
  // ---------------------------------------------------------------------------
  protected function txn_id_t expected_read_completion_txn_id(input item_t req);

    if (req.opcode == req_opcode_t'(VIP_CHI_REQ_READ_NO_SNP_SEP_C)) begin
      return req.return_txn_id;
    end

    return req.txn_id;
  endfunction

  // ---------------------------------------------------------------------------
  // Public reset hook. The parent agent drives the reset sequencing and calls
  // this before rst_n is released.
  // ---------------------------------------------------------------------------
  function void reset_vif();

    this.reset_outputs();
  endfunction

  // ---------------------------------------------------------------------------
  // Clear the RN-I local bookkeeping that does not live on the interface.
  // ---------------------------------------------------------------------------
  function void handle_reset();

    this.next_txn_id = '0;
    this.outstanding_ids.delete();
    this.mx_ctx.delete();
    this.mx_dat_beats.delete();
    this.pcrd_pool.delete();
    this.pcrd_granter.delete();
    this.pcrd_own_id.delete();
    this.tx_active_count = 0;
    this.tx_active_extend = 0;
    this.lasm_abort_done = 1'b0;
    this.flitpend_negctl_done = 1'b0;
    this.lasm_race_done = 1'b0;
    // A reset takes the link down by force, which is not the graceful path: the
    // published "done" would otherwise survive as a claim about a drain that
    // never happened.
    if (this.cfg != null) begin
      this.cfg.link_deactivate_done = 1'b0;
    end
    this.reset_credit_state();
    this.reset_outputs();
    // The agent tears down driver_start() with disable-fork on reset, which may
    // kill a flit driver mid-critical-section holding the key. Re-seed a fresh
    // one-key mutex so the re-forked threads never block on a lost key.
    this.tx_flit_arb = new(1);
  endfunction

  // ---------------------------------------------------------------------------
  // Is this TxnID currently outstanding? Linear scan over the in-flight pool,
  // which is bounded by cfg.max_outstanding_* rather than the TxnID space.
  // ---------------------------------------------------------------------------
  protected function bit txn_id_in_flight(input txn_id_t id);

    foreach (this.outstanding_ids[i]) begin
      if (this.outstanding_ids[i] == id) begin
        return 1'b1;
      end
    end

    return 1'b0;
  endfunction

  // ---------------------------------------------------------------------------
  // Allocate a unique in-flight TxnID: advance the free-running counter,
  // skipping any value still outstanding, and record it in the pool. Serial
  // flow keeps at most one entry here; the pool exists so the multi-outstanding
  // path can allocate without colliding with a completion still on the wire.
  // ---------------------------------------------------------------------------
  protected function txn_id_t alloc_txn_id();

    txn_id_t cand;

    forever begin

      cand = this.next_txn_id;
      this.next_txn_id = txn_id_t'(this.next_txn_id + txn_id_t'(1));

      if (!this.txn_id_in_flight(cand)) begin

        this.outstanding_ids.push_back(cand);

        if (this.outstanding_ids.size() > this.cfg.observed_peak_outstanding) begin

          this.cfg.observed_peak_outstanding = this.outstanding_ids.size();
        end

        return cand;
      end
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Release a TxnID back to the pool once its transaction has fully completed.
  // ---------------------------------------------------------------------------
  protected function void free_txn_id(input txn_id_t id);

    foreach (this.outstanding_ids[i]) begin

      if (this.outstanding_ids[i] == id) begin

        this.outstanding_ids.delete(i);
        return;
      end
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Main RN-I request-driving loop after the parent agent releases reset.
  // ---------------------------------------------------------------------------
  task driver_start();

    fork

      this.credit_loop();

      // Coherent-role extension point: RN-F forks its SNP receive-credit loop and
      // snoop responder here. Empty in RN-I (returns at once; harmless in join).
      this.extra_rx_channels();

      // Watches cfg.link_deactivate_request. A separate thread rather than a
      // step in the sequence loop below, because the loop blocks on the
      // sequencer: a test that has stopped sending is exactly a test whose
      // driver is parked in get_next_item and would never look at the flag.
      this.deactivate_watch();

      begin

        this.activate_link();

        // Coherent-role extension point: RN-F advertises its initial SNP receive
        // credits now that the link is up. Empty in RN-I.
        this.post_activate_hook();

        if (this.cfg.multi_outstanding) begin

          // One unified pipeline overlaps plain reads and writes; the read-only
          // (multi_outstanding_write=0) and write-only (=1) modes are just this
          // loop fed a single direction. The _write / _mixed flags are retained
          // for back-compat but no longer select distinct loops.
          this.seq_loop_mixed_pipelined();
        end
        else begin

          this.seq_loop();
        end
      end
    join
  endtask

  // ---------------------------------------------------------------------------
  // Track inbound L-credit pulses and emit one-cycle LCRDV pulses for both the
  // initial receive-credit grant and later return-after-consume events.
  // ---------------------------------------------------------------------------
  protected task credit_loop();

    logic dat_hold;

    forever begin

      @(this.vif_rni.g_drv.rni_cb);

      this.drive_idle_sideband();
      this.tx_activity_tick();

      if (this.vif_rni.g_drv.rni_cb.rxdatflitv) begin

        this.seen_rx_dat_flit = 1'b1;
      end

      // cfg.hold_dat_credit lets a test stall the peer's DAT sends by pausing
      // DAT credit advertisement; the pending grants accumulate and drain once
      // the flag clears, so no credit is lost. It only applies after the first
      // inbound DAT flit, so the initial credit grant still bootstraps the link.
      //
      // link_deactivating holds BOTH channels for a different reason: a receiver
      // must not issue L-credits once the link is coming down. Without it the
      // drain could never finish -- every credit the peer returned would be
      // handed straight back.
      dat_hold = (this.cfg.hold_dat_credit && this.seen_rx_dat_flit) ||
                 this.link_deactivating;

      this.vif_rni.g_drv.rni_cb.txrsplcrdv <=
        (this.rsp_lcrdv_pulses_pending != 0) && !this.link_deactivating;
      this.vif_rni.g_drv.rni_cb.txdatlcrdv <= (this.dat_lcrdv_pulses_pending != 0) && !dat_hold;

      if ((this.rsp_lcrdv_pulses_pending != 0) && !this.link_deactivating) begin
        this.rsp_lcrdv_pulses_pending--;
        this.rsp_lcrd_granted++;
      end

      if ((this.dat_lcrdv_pulses_pending != 0) && !dat_hold) begin
        this.dat_lcrdv_pulses_pending--;
        this.dat_lcrd_granted++;
      end

      // Every inbound flit spends one of the credits advertised above, INCLUDING
      // an L-credit return: the return is itself a flit and consumes the credit
      // it hands back. That is what lets the drain converge with no separate
      // accounting for the two kinds.
      if (this.vif_rni.g_drv.rni_cb.rxrspflitv && (this.rsp_lcrd_granted != 0)) begin
        this.rsp_lcrd_granted--;
      end

      if (this.vif_rni.g_drv.rni_cb.rxdatflitv && (this.dat_lcrd_granted != 0)) begin
        this.dat_lcrd_granted--;
      end

      if (this.vif_rni.g_drv.rni_cb.rxreqlcrdv) begin
        this.req_lcrd_mgr.return_credit();
      end

      if (this.vif_rni.g_drv.rni_cb.rxrsplcrdv) begin
        this.rsp_lcrd_mgr.return_credit();
      end

      if (this.vif_rni.g_drv.rni_cb.rxdatlcrdv) begin
        this.dat_lcrd_mgr.return_credit();
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  // Wait until one outbound credit is available for the selected channel.
  // ---------------------------------------------------------------------------
  protected task wait_for_credit(input vip_chi_lcrd_mgr lcrd_mgr);

    forever begin

      if (lcrd_mgr.try_acquire_credit()) begin
        break;
      end

      @(this.vif_rni.g_drv.rni_cb);
      this.drive_idle_sideband();
    end
  endtask

  // ---------------------------------------------------------------------------
  // Hold an assembled flit for its channel's configured transmit delay, then
  // take the credit.
  //
  // BEFORE the credit and before acquire_tx_flit(), on purpose. The delay models
  // a source that is not ready yet, which is upstream of asking for permission
  // to send; taking the TX-flit mutex first would make one channel's delay stall
  // every other channel's driver, and holding a credit across it would reserve
  // link resources for a flit that has not been offered.
  //
  // Per FLIT, which inside a DAT burst means per beat. That is what the knob
  // says -- a transmit delay on a channel -- and gapped beats are legal: a beat
  // counter counts FLITV cycles, not consecutive ones.
  //
  // NOT applied to L-credit returns. Those are link-layer bookkeeping rather
  // than traffic, and delaying a credit return starves the peer's send side
  // instead of shaping this side's.
  // ---------------------------------------------------------------------------
  protected task wait_channel_delay(input int unsigned cycles);

    repeat (cycles) begin
      @(this.vif_rni.g_drv.rni_cb);
      this.drive_idle_sideband();
    end
  endtask

  protected task wait_req_credit();
    this.wait_channel_delay(this.cfg.draw_req_valid_delay());
    this.wait_for_credit(this.req_lcrd_mgr);
  endtask

  protected task wait_rsp_credit();
    this.wait_channel_delay(this.cfg.draw_rsp_valid_delay());
    this.wait_for_credit(this.rsp_lcrd_mgr);
  endtask

  protected task wait_dat_credit();
    this.wait_channel_delay(this.cfg.draw_dat_valid_delay());
    this.wait_for_credit(this.dat_lcrd_mgr);
  endtask

  // ---------------------------------------------------------------------------
  // Queue one returned credit on the inbound RSP channel.
  // ---------------------------------------------------------------------------
  protected function void schedule_rsp_credit_return();
    this.rsp_lcrdv_pulses_pending++;
  endfunction

  // ---------------------------------------------------------------------------
  // Queue one returned credit on the inbound DAT channel.
  // ---------------------------------------------------------------------------
  protected function void schedule_dat_credit_return();
    this.dat_lcrdv_pulses_pending++;
  endfunction

  // ---------------------------------------------------------------------------
  // Take/release the TX flit-driving mutex. Every task that drives a
  // txreq/txrsp/txdat flit group brackets its beat-driving section with these
  // so concurrent flit drivers (the RN-F snoop responder vs the request thread)
  // are serialized on the shared TX signals. Always acquired AFTER credit and
  // released before any completion wait -- see tx_flit_arb's declaration.
  //
  // txsactive is deliberately NOT among the signals this protects. It is a
  // level driven from tx_active_count, so two concurrent senders compute the
  // same value and cannot disagree; it also has to stay asserted ACROSS the
  // gaps when neither holds the key, which a mutex-guarded signal could not.
  // ---------------------------------------------------------------------------
  protected task acquire_tx_flit();
    this.tx_flit_arb.get(1);
  endtask

  protected function void release_tx_flit();
    this.tx_flit_arb.put(1);
  endfunction

  // ---------------------------------------------------------------------------
  // Main RN-I request-driving loop after link activation.
  // ---------------------------------------------------------------------------
  protected task seq_loop();

    item_t     req;
    bit        wait_for_deferred_comp;
    bit        send_write_data;
    node_id_t  req_src_id;
    node_id_t  req_tgt_id;
    rsp_flit_t write_grant_flit;

    forever begin

      seq_item_port.get_next_item(req);

      if (req == null) begin

        `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] get_next_item() returned NULL",
        get_name()))
      end

      if (req.raw_override) begin

        this.drive_raw_item(req);
        seq_item_port.item_done(req);
        continue;
      end

      this.drive_req(req);

      if (req.direction == VIP_CHI_DIR_WRITE_E) begin

        // Absorb any RetryAck/PCrdGrant and re-issue before the completion flow
        // (a no-op unless the request allowed retry and the SN-F bounced it).
        this.handle_retry(req);
        req_src_id         = req.src_id;
        req_tgt_id         = req.tgt_id;
        send_write_data    = this.req_expects_write_data(req);
        wait_for_deferred_comp = 1'b0;

        if (req.opcode == VIP_CHI_REQ_WRITE_EVICT_OR_EVICT_C) begin

          this.drive_write_evict_or_evict(req, req_src_id, req_tgt_id);
        end
        else if (send_write_data) begin

          this.collect_write_dbid_grant(req, wait_for_deferred_comp, write_grant_flit);
          this.drive_dat(req);

          if (this.req_expects_atomic_data_completion(req)) begin

            if (!wait_for_deferred_comp) begin

              `uvm_fatal(get_name(), $sformatf(
              "FATAL [%s] Non-store atomic grant opcode 0x%0h was not DBIDResp/DBIDRespOrd",
              get_name(), write_grant_flit.opcode))
            end

            this.collect_read_completion(req);
          end
          else if (wait_for_deferred_comp) begin

            this.collect_write_completion(req);
          end
          else begin

            this.stamp_rsp_flit_on_req(req, write_grant_flit);
          end
        end
        else begin

          if (this.req_expects_persist_sep_completion(req)) begin

            this.collect_persist_sep_completion(req);
          end
          else if ((req.opcode == VIP_CHI_REQ_WRITE_NO_SNP_ZERO_C) ||
                   // WriteUniqueZero is the snoopable twin and completes the same
                   // two ways: DBIDResp* + Comp, or a combined CompDBIDResp.
                   (req.opcode == VIP_CHI_REQ_WRITE_UNIQUE_ZERO_C)) begin

            this.collect_write_zero_completion(req);
          end
          else begin

            this.collect_write_completion(req);
          end
        end

        // The CMO half's completion, which arrives after the write's because the
        // completer may only send it once the write data has landed.
        if (this.req_is_combined_write_cmo(req)) begin

          this.collect_combined_cmo_completion(req, req_src_id, req_tgt_id);
        end

        // WriteEvictOrEvict always sets ExpCompAck but acknowledges itself: the
        // data leg's CopyBackWrData IS the acknowledgement, and the no-data leg
        // already sent an explicit CompAck above. Either way a second one here
        // would be a CompAck the home never expects.
        if (req.exp_comp_ack &&
            (req.opcode != VIP_CHI_REQ_WRITE_EVICT_OR_EVICT_C)) begin

          this.drive_comp_ack(req.txn_id, req_src_id, req_tgt_id);
        end

        @(this.vif_rni.g_drv.rni_cb);
        this.drive_idle_sideband();
        this.tx_activity_end();
        this.on_transaction_complete(req);
        this.free_txn_id(req.txn_id);
        seq_item_port.item_done(req);
      end
      else begin

        if (this.req_expects_read_completion(req)) begin

          // Absorb any RetryAck/PCrdGrant and re-issue before the read
          // completion flow (a no-op unless retry was allowed and bounced).
          this.handle_retry(req);
          if (this.req_expects_read_receipt(req)) begin
            this.collect_read_receipt(req);
          end

          // A separated read receives its response on RSP (RespSepData) ahead of
          // the DataSepResp data leg on DAT.
          if (req.opcode == req_opcode_t'(VIP_CHI_REQ_READ_NO_SNP_SEP_C)) begin

            this.collect_resp_sep_data(req);
          end

          this.collect_read_completion(req);
        end
        else begin

          @(this.vif_rni.g_drv.rni_cb);
          this.drive_idle_sideband();
        end

        this.tx_activity_end();
        this.on_transaction_complete(req);
        this.free_txn_id(req.txn_id);
        seq_item_port.item_done(req);
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  // run_phase is intentionally empty: the parent agent owns the single rst_n
  // watcher and forks driver_start() only while the link is out of reset.
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);
  endtask

  // ---------------------------------------------------------------------------
  // Coherent-role extension hooks (all no-ops for RN-I, so the base path stays
  // byte-identical). The RN-F subclass overrides them to add the SNP channel
  // without copying driver_start / seq_loop:
  //   * extra_rx_channels  - forked alongside credit_loop; RN-F starts its SNP
  //                          receive-credit loop and snoop responder here.
  //   * post_activate_hook - runs once after activate_link; RN-F advertises its
  //                          initial SNP receive credits here.
  //   * on_transaction_complete - runs as each request retires in seq_loop;
  //                          RN-F updates its per-line cache-state model here.
  // ---------------------------------------------------------------------------
  virtual protected task extra_rx_channels();
  endtask

  virtual protected task post_activate_hook();
  endtask

  virtual protected function void on_transaction_complete(input item_t req);
  endfunction

  // ---------------------------------------------------------------------------
  // Drive link activation, wait for the remote ack, then advertise the
  // RN-I receive budgets as initial LCRDV pulses.
  // ---------------------------------------------------------------------------
  protected task activate_link();

    @(this.vif_rni.g_drv.rni_cb);
    this.drive_idle_sideband();

    // Negative control (cfg.lasm_abort_activation): raise the activation request
    // and withdraw it again before the completer has acknowledged it, which
    // steps the LASM out of ACTIVATE without ever reaching RUN. A requester is
    // not entitled to do that -- once it has asked for the link it must wait for
    // the acknowledge -- so it is a genuine illegal transition rather than an
    // unusual-but-legal sequence, which is what makes it a usable control.
    //
    // It fires ONCE, before the real activation below, so the check has exactly
    // one aborted bring-up to report and the count a negative control asserts on
    // is unambiguous. The link then activates normally, so the rest of the test
    // is ordinary traffic.
    if (this.cfg.lasm_abort_activation && !this.lasm_abort_done) begin
      this.lasm_abort_done = 1'b1;
      this.drive_link_req(1'b1);
      @(this.vif_rni.g_drv.rni_cb);
      this.drive_idle_sideband();
      this.drive_link_req(1'b0);
      @(this.vif_rni.g_drv.rni_cb);
      this.drive_idle_sideband();
      // Let the completer's mirrored acknowledge retire before asking again, so
      // the aborted attempt and the real one are two separate bring-ups rather
      // than one ambiguous glitch.
      repeat (4) begin
        @(this.vif_rni.g_drv.rni_cb);
        this.drive_idle_sideband();
      end
    end

    this.wait_lasm_req_delay();

    this.drive_link_req(1'b1);

    do begin

      @(this.vif_rni.g_drv.rni_cb);
      this.drive_idle_sideband();
    end while (this.vif_rni.rst_n && !this.vif_rni.g_drv.rni_cb.rxlinkactiveack);

    this.schedule_initial_credit_grants();
    this.drive_flitpend_negctl();
  endtask

  // ---------------------------------------------------------------------------
  // The link state this endpoint currently observes.
  //
  // One LASM per link, so the requester's own txlinkactivereq and the peer's
  // mirrored acknowledge are the whole state -- the same pair the checkers read.
  // ---------------------------------------------------------------------------
  protected function vip_chi_lasm_state_t observed_lasm();
    return vip_chi_lasm(this.req_driven,
                        this.vif_rni.g_drv.rni_cb.rxlinkactiveack === 1'b1);
  endfunction

  // The only place txlinkactivereq is driven, so the shadow above cannot drift.
  protected function void drive_link_req(input bit value);
    this.req_driven = value;
    this.vif_rni.g_drv.rni_cb.txlinkactivereq <= value;
  endfunction

  // ---------------------------------------------------------------------------
  // Hold off the activation request by cfg.lasm_req_delay_by_state, indexed by
  // the state the link is in RIGHT NOW.
  //
  // Sampled once, before the wait, deliberately: the delay is a property of the
  // state the requester decided to act from, and re-reading it each cycle would
  // make the wait chase a moving index and never settle.
  // ---------------------------------------------------------------------------
  protected task wait_lasm_req_delay();

    int unsigned cycles;

    cycles = this.cfg.lasm_req_delay_by_state[int'(this.observed_lasm())];

    repeat (cycles) begin
      @(this.vif_rni.g_drv.rni_cb);
      this.drive_idle_sideband();
    end
  endtask

  // ---------------------------------------------------------------------------
  // Negative control (cfg.flitpend_without_valid): raise FLITPEND on REQ and RSP
  // for one cycle with no flit behind it.
  //
  // Emitted here, once, with the link up and before any traffic, so the two
  // rules have exactly one lone FLITPEND to report and nothing else on the wire
  // can be confused for it. Both channels in the same cycle because the rules
  // are per channel and one pulse should exercise each exactly once.
  // ---------------------------------------------------------------------------
  protected task drive_flitpend_negctl();

    if (!this.cfg.flitpend_without_valid || this.flitpend_negctl_done) begin
      return;
    end
    this.flitpend_negctl_done = 1'b1;

    this.acquire_tx_flit();
    @(this.vif_rni.g_drv.rni_cb);
    this.drive_idle_sideband();
    this.vif_rni.g_drv.rni_cb.txreqflitpend <= 1'b1;
    this.vif_rni.g_drv.rni_cb.txrspflitpend <= 1'b1;

    @(this.vif_rni.g_drv.rni_cb);
    this.drive_idle_sideband();
    this.vif_rni.g_drv.rni_cb.txreqflitpend <= 1'b0;
    this.vif_rni.g_drv.rni_cb.txrspflitpend <= 1'b0;
    this.release_tx_flit();
  endtask

  // ---------------------------------------------------------------------------
  // Graceful link deactivation: the second half of the LASM cycle.
  //
  // Without this the VIP could only ever take a link down by RESET, so the two
  // tear-down edges (RUN -> DEACTIVATE, DEACTIVATE -> STOP) were checked but
  // never once walked, and every rule that only holds while a link is coming
  // down was untestable by construction.
  //
  // The order below is the protocol's, and each step exists because the one
  // before it makes the next legal:
  //
  //   1. wait for the traffic to retire. A deactivation with a transaction still
  //      in flight would strand it -- the completion has nowhere to arrive.
  //   2. stop advertising receive credits. A receiver may not issue L-credits
  //      once the link is coming down, and a drain racing a credit loop that
  //      keeps refilling the pool would never converge.
  //   3. drop LINKACTIVEREQ. The link is now in DEACTIVATE, which is the one
  //      state in which a sender may still transmit -- and only L-credit
  //      returns.
  //   4. return every credit still held, on all three channels.
  //   5. wait for the peer to do the same, which is what finally drops the
  //      acknowledge and puts the link in STOP with both pools empty.
  //
  // Lowering the request afterwards brings the link back up, so a single test
  // can prove the whole cycle rather than only its first half.
  // ---------------------------------------------------------------------------
  protected task deactivate_watch();

    // Forked alongside activate_link rather than after it, so wait for the link
    // to be up before watching for a request to take it down. A test that set
    // the flag before time 0 would otherwise withdraw a request never raised.
    while (!this.vif_rni.g_drv.rni_cb.rxlinkactiveack) begin
      @(this.vif_rni.g_drv.rni_cb);
    end

    forever begin

      // Idle here on every test that never asks, at no cost beyond the poll the
      // credit loop is already making anyway.
      while (!this.cfg.link_deactivate_request) begin
        @(this.vif_rni.g_drv.rni_cb);
        this.drive_idle_sideband();
      end

      // 1. Let the traffic retire. tx_active_extend is waited on as well as the
      // count: TXSACTIVE says this node MAY have snoopable transactions
      // outstanding, and taking a link down while still claiming that tells the
      // receiver to keep watching a link that is about to stop existing.
      while ((this.outstanding_ids.size() != 0) || (this.tx_active_count != 0) ||
             (this.tx_active_extend != 0)) begin
        @(this.vif_rni.g_drv.rni_cb);
        this.drive_idle_sideband();
      end

      // The count reaching zero only ARMS the drop; tx_activity_tick lowers the
      // signal on its next call, so give it that cycle before the request falls.
      @(this.vif_rni.g_drv.rni_cb);
      this.drive_idle_sideband();

      // 2 + 3. Stand the grants down, then withdraw the request. Both in the
      // same cycle: the credit loop reads the flag on its next edge, which is
      // the same edge the lowered request reaches the wire on.
      this.link_deactivating = 1'b1;
      this.drive_link_req(1'b0);

      @(this.vif_rni.g_drv.rni_cb);
      this.drive_idle_sideband();

      // Negative control (cfg.lasm_reactivate_during_deactivate): change our
      // mind half way through the tear-down. The link is in DEACTIVATE (request
      // low, acknowledge still high), so raising the request again makes the
      // pair {1,1} = RUN -- a jump the cycle does not allow, since DEACTIVATE
      // may only advance to STOP.
      //
      // Placed HERE, before the drain, because that is what makes it a race
      // rather than a malformed sequence: the completer is still returning
      // credits and has not yet decided to drop its acknowledge.
      if (this.cfg.lasm_reactivate_during_deactivate && !this.lasm_race_done) begin
        this.lasm_race_done = 1'b1;
        this.drive_link_req(1'b1);
        @(this.vif_rni.g_drv.rni_cb);
        this.drive_idle_sideband();
        this.drive_link_req(1'b0);
        @(this.vif_rni.g_drv.rni_cb);
        this.drive_idle_sideband();
      end

      // 4. Hand back what this node holds.
      this.drain_tx_credits();

      // 5. And wait for the peer to hand back what it holds. The completer drops
      // its acknowledge on the same condition, so this loop ends at STOP.
      while ((this.rsp_lcrd_granted != 0) || (this.dat_lcrd_granted != 0)) begin
        @(this.vif_rni.g_drv.rni_cb);
        this.drive_idle_sideband();
      end

      // Queued-but-unsent grants are dropped rather than carried across the gap:
      // they were promises about a link that no longer exists, and re-activation
      // advertises a fresh budget from schedule_initial_credit_grants().
      this.rsp_lcrdv_pulses_pending = 0;
      this.dat_lcrdv_pulses_pending = 0;
      this.seen_rx_dat_flit         = 1'b0;

      this.cfg.link_deactivate_done = 1'b1;

      `uvm_info(get_name(), $sformatf(
        "INFO [%s] link deactivated: every L-credit returned, link in STOP",
        get_name()), UVM_LOW)

      // Held down until the test asks for the link back.
      while (this.cfg.link_deactivate_request) begin
        @(this.vif_rni.g_drv.rni_cb);
        this.drive_idle_sideband();
      end

      this.link_deactivating        = 1'b0;
      this.cfg.link_deactivate_done = 1'b0;
      this.activate_link();
      this.post_activate_hook();

      `uvm_info(get_name(), $sformatf(
        "INFO [%s] link reactivated after a graceful deactivation",
        get_name()), UVM_LOW)
    end
  endtask

  // ---------------------------------------------------------------------------
  // Return every send-side L-credit this node still holds, one flit per credit.
  //
  // An L-credit return is a flit like any other and is sent UNDER one of the
  // credits it returns, so the loop needs no separate budget: acquiring is what
  // makes the send legal, and the pool empties itself. That symmetry is also why
  // the credit shadow in the checkers needs no special case for it.
  // ---------------------------------------------------------------------------
  protected task drain_tx_credits();

    while (this.req_lcrd_mgr.try_acquire_credit()) begin
      this.drive_req_lcrd_return();
    end

    while (this.rsp_lcrd_mgr.try_acquire_credit()) begin
      this.drive_rsp_lcrd_return();
    end

    while (this.dat_lcrd_mgr.try_acquire_credit()) begin
      this.drive_dat_lcrd_return();
    end
  endtask

  // ---------------------------------------------------------------------------
  // One L-credit return flit per channel. All fields zero: the opcode is the
  // whole message, and a return names no address, no TxnID and no data.
  // ---------------------------------------------------------------------------
  protected task drive_req_lcrd_return();

    req_flit_t flit;

    flit        = '0;
    flit.opcode = req_opcode_t'(VIP_CHI_REQ_LCRD_RETURN_C);

    this.acquire_tx_flit();
    @(this.vif_rni.g_drv.rni_cb);
    this.drive_idle_sideband();
    this.vif_rni.g_drv.rni_cb.txreqflitpend <= 1'b0;
    this.vif_rni.g_drv.rni_cb.txreqflit     <= flit;
    this.vif_rni.g_drv.rni_cb.txreqflitv    <= 1'b1;

    @(this.vif_rni.g_drv.rni_cb);
    this.drive_idle_sideband();
    this.vif_rni.g_drv.rni_cb.txreqflitv <= 1'b0;
    this.vif_rni.g_drv.rni_cb.txreqflit  <= '0;
    this.release_tx_flit();
  endtask

  // ---------------------------------------------------------------------------
  // Hand back every banked P-credit with PCrdReturn.
  //
  // PCrdReturn is a NOP transaction that consumes the credit it names, so it is
  // the only way to give one back. There is no response to wait for -- which is
  // also why a randomly generated PCrdReturn would wedge this driver, and why
  // the opcode is kept out of the item randomization pools.
  //
  // Identifier fields are fixed by the specification rather than chosen: TxnID
  // is not used and must be zero, TgtID must match the SrcID of the node that
  // granted the credit, and PCrdType must match the grant's.
  // ---------------------------------------------------------------------------
  task return_unused_pcrds();

    req_flit_t          flit;
    vip_chi_pcrd_type_t pcrd_type;

    if (!this.pcrd_pool.first(pcrd_type)) begin
      return;
    end

    do begin
      while (this.pcrd_pool[pcrd_type] > 0) begin

        flit          = '0;
        flit.opcode   = req_opcode_t'(VIP_CHI_REQ_PCRD_RETURN_C);
        flit.pcrdtype = pcrd_type;
        flit.txnid    = '0;
        flit.srcid    = this.pcrd_own_id.exists(pcrd_type)
                      ? this.pcrd_own_id[pcrd_type] : '0;
        flit.tgtid    = this.pcrd_granter.exists(pcrd_type)
                      ? this.pcrd_granter[pcrd_type] : '0;

        this.wait_req_credit();
        this.acquire_tx_flit();
        @(this.vif_rni.g_drv.rni_cb);
        this.drive_idle_sideband();
        this.vif_rni.g_drv.rni_cb.txreqflitpend <= 1'b0;
        this.vif_rni.g_drv.rni_cb.txreqflit     <= flit;
        this.vif_rni.g_drv.rni_cb.txreqflitv    <= 1'b1;

        @(this.vif_rni.g_drv.rni_cb);
        this.drive_idle_sideband();
        this.vif_rni.g_drv.rni_cb.txreqflitv <= 1'b0;
        this.vif_rni.g_drv.rni_cb.txreqflit  <= '0;
        this.release_tx_flit();

        this.pcrd_pool[pcrd_type] -= 1;
        this.n_pcrd_returned++;
      end
    end while (this.pcrd_pool.next(pcrd_type));
  endtask

  protected task drive_rsp_lcrd_return();

    rsp_flit_t flit;

    flit        = '0;
    flit.opcode = rsp_opcode_t'(VIP_CHI_RSP_LCRD_RETURN_C);

    this.acquire_tx_flit();
    @(this.vif_rni.g_drv.rni_cb);
    this.drive_idle_sideband();
    this.vif_rni.g_drv.rni_cb.txrspflitpend <= 1'b0;
    this.vif_rni.g_drv.rni_cb.txrspflit     <= flit;
    this.vif_rni.g_drv.rni_cb.txrspflitv    <= 1'b1;

    @(this.vif_rni.g_drv.rni_cb);
    this.drive_idle_sideband();
    this.vif_rni.g_drv.rni_cb.txrspflitv <= 1'b0;
    this.vif_rni.g_drv.rni_cb.txrspflit  <= '0;
    this.release_tx_flit();
  endtask

  protected task drive_dat_lcrd_return();

    dat_flit_t flit;

    flit        = '0;
    flit.opcode = dat_opcode_t'(VIP_CHI_DAT_LCRD_RETURN_C);

    this.acquire_tx_flit();
    @(this.vif_rni.g_drv.rni_cb);
    this.drive_idle_sideband();
    this.vif_rni.g_drv.rni_cb.txdatflitpend <= 1'b0;
    this.vif_rni.g_drv.rni_cb.txdatflit     <= flit;
    this.vif_rni.g_drv.rni_cb.txdatflitv    <= 1'b1;

    @(this.vif_rni.g_drv.rni_cb);
    this.drive_idle_sideband();
    this.vif_rni.g_drv.rni_cb.txdatflitv <= 1'b0;
    this.vif_rni.g_drv.rni_cb.txdatflit  <= '0;
    this.release_tx_flit();
  endtask

  // ---------------------------------------------------------------------------
  // Drive one REQ flit.
  // ---------------------------------------------------------------------------
  protected task drive_req(input item_t req, input bit alloc_id = 1'b1);

    req_flit_t flit;

    // A retry re-issue keeps the original TxnID (alloc_id = 0); a fresh request
    // allocates one from the in-flight pool.
    if (alloc_id) begin

      req.txn_id = this.alloc_txn_id();
    end

    flit = '0;
    flit.mpam         = req.mpam;
    flit.tracetag     = req.tracetag;
    flit.expcompack   = req.exp_comp_ack;
    flit.excl         = vip_chi_exclusive_t'(req.excl);
    flit.dodwt        = req.dodwt;
    flit.memattr      = req.mem_attr;
    flit.pcrdtype     = req.pcrd_type;
    flit.order        = vip_chi_req_order_t'(req.order);
    flit.allowretry   = req.allow_retry;
    flit.likelyshared = req.likelyshared;
    flit.ns           = vip_chi_req_ns_t'(req.ns);
    flit.addr         = req.addr;
    flit.size         = req.size;
    flit.opcode       = req_opcode_t'(req.opcode);
    flit.returntxnid  = req.return_txn_id;
    flit.endian       = req.endian;
    flit.returnnid    = req.return_nid;
    flit.lpid         = req.lp_id;
    flit.txnid        = req.txn_id;
    flit.srcid        = req.src_id;
    flit.tgtid        = req.tgt_id;
    flit.qos          = req.qos;

    this.apply_req_issue_specific_fields(flit, req);
    this.wait_req_credit();

    this.acquire_tx_flit();
    @(this.vif_rni.g_drv.rni_cb);
    this.drive_idle_sideband();
    // alloc_id is exactly "this is a fresh transaction", so it is also the right
    // predicate for opening the TXSACTIVE window: handle_retry() and the mixed
    // pipeline both re-issue with alloc_id=0, and a re-issue must not open a
    // second window over a transaction that already has one.
    if (alloc_id) begin
      this.tx_activity_begin();
    end
    this.vif_rni.g_drv.rni_cb.txreqflitpend <= 1'b0;
    this.vif_rni.g_drv.rni_cb.txreqflit     <= flit;
    this.vif_rni.g_drv.rni_cb.txreqflitv    <= 1'b1;

    @(this.vif_rni.g_drv.rni_cb);
    this.drive_idle_sideband();
    this.vif_rni.g_drv.rni_cb.txreqflitv <= 1'b0;
    this.vif_rni.g_drv.rni_cb.txreqflit  <= '0;
    this.release_tx_flit();
  endtask

  // ---------------------------------------------------------------------------
  // Drive one raw item verbatim on the channel selected by raw_channel.
  // ---------------------------------------------------------------------------
  protected task drive_raw_item(input item_t item);

    if (!this.cfg.allow_raw_override) begin

      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] raw_override is disabled in cfg",
      get_name()))
    end

    case (item.raw_channel)

      VIP_CHI_RAW_REQ_E: begin
        this.drive_raw_req(item);
      end

      VIP_CHI_RAW_RSP_E: begin
        this.drive_raw_rsp(item);
      end

      VIP_CHI_RAW_DAT_E: begin
        this.drive_raw_dat(item);
      end

      default: begin
        `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] raw_override item has no raw channel selected",
        get_name()))
      end
    endcase
  endtask

  // ---------------------------------------------------------------------------
  // Drive one raw REQ flit.
  // ---------------------------------------------------------------------------
  protected task drive_raw_req(input item_t item);

    req_flit_t flit;

    flit = '0;
    flit.mpam         = item.raw_req.mpam;
    flit.tracetag     = item.raw_req.tracetag;
    flit.expcompack   = item.raw_req.expcompack;
    flit.excl         = item.raw_req.excl;
    flit.lpid         = item.raw_req.lpid;
    flit.dodwt        = item.raw_req.dodwt;
    flit.memattr      = item.raw_req.memattr;
    flit.pcrdtype     = item.raw_req.pcrdtype;
    flit.order        = item.raw_req.order;
    flit.allowretry   = item.raw_req.allowretry;
    flit.likelyshared = item.raw_req.likelyshared;
    flit.ns           = item.raw_req.ns;
    flit.addr         = item.raw_req.addr;
    flit.size         = item.raw_req.size;
    flit.opcode       = item.raw_req.opcode;
    flit.returntxnid  = item.raw_req.returntxnid;
    flit.endian       = item.raw_req.endian;
    flit.returnnid    = item.raw_req.returnnid;
    flit.txnid        = item.raw_req.txnid;
    flit.srcid        = item.raw_req.srcid;
    flit.tgtid        = item.raw_req.tgtid;
    flit.qos          = item.raw_req.qos;

    this.apply_raw_req_issue_specific_fields(flit, item.raw_req);
    this.wait_req_credit();

    this.acquire_tx_flit();
    @(this.vif_rni.g_drv.rni_cb);
    this.drive_idle_sideband();
    // A raw flit is a single injected packet with no completion to wait
    // for, so its window is the flit itself.
    this.tx_activity_begin();
    this.vif_rni.g_drv.rni_cb.txreqflitpend <= item.raw_flitpend;
    this.vif_rni.g_drv.rni_cb.txreqflit     <= flit;
    this.vif_rni.g_drv.rni_cb.txreqflitv    <= 1'b1;

    @(this.vif_rni.g_drv.rni_cb);
    this.drive_idle_sideband();
    this.vif_rni.g_drv.rni_cb.txreqflitpend <= 1'b0;
    this.vif_rni.g_drv.rni_cb.txreqflitv    <= 1'b0;
    this.vif_rni.g_drv.rni_cb.txreqflit     <= '0;
    this.tx_activity_end();
    this.release_tx_flit();
  endtask

  // ---------------------------------------------------------------------------
  // Drive one raw RSP flit.
  // ---------------------------------------------------------------------------
  protected task drive_raw_rsp(input item_t item);

    rsp_flit_t flit;

    flit = '0;
    flit.tracetag = item.raw_rsp.tracetag;
    flit.pcrdtype = item.raw_rsp.pcrdtype;
    flit.dbid     = item.raw_rsp.dbid;
    flit.cbusy    = item.raw_rsp.cbusy;
    flit.fwdstate = item.raw_rsp.fwdstate;
    flit.resp     = item.raw_rsp.resp;
    flit.resperr  = item.raw_rsp.resperr;
    flit.opcode   = item.raw_rsp.opcode;
    flit.txnid    = item.raw_rsp.txnid;
    flit.srcid    = item.raw_rsp.srcid;
    flit.tgtid    = item.raw_rsp.tgtid;
    flit.qos      = item.raw_rsp.qos;

    this.apply_raw_rsp_issue_specific_fields(flit, item.raw_rsp);
    this.wait_rsp_credit();

    this.acquire_tx_flit();
    @(this.vif_rni.g_drv.rni_cb);
    this.drive_idle_sideband();
    // A raw flit is a single injected packet with no completion to wait
    // for, so its window is the flit itself.
    this.tx_activity_begin();
    this.vif_rni.g_drv.rni_cb.txrspflitpend <= item.raw_flitpend;
    this.vif_rni.g_drv.rni_cb.txrspflit     <= flit;
    this.vif_rni.g_drv.rni_cb.txrspflitv    <= 1'b1;

    @(this.vif_rni.g_drv.rni_cb);
    this.drive_idle_sideband();
    this.vif_rni.g_drv.rni_cb.txrspflitpend <= 1'b0;
    this.vif_rni.g_drv.rni_cb.txrspflitv    <= 1'b0;
    this.vif_rni.g_drv.rni_cb.txrspflit     <= '0;
    this.tx_activity_end();
    this.release_tx_flit();
  endtask

  // ---------------------------------------------------------------------------
  // Drive one raw DAT flit.
  // ---------------------------------------------------------------------------
  protected task drive_raw_dat(input item_t item);

    dat_flit_t flit;

    flit = '0;
    flit.poison     = item.raw_dat.poison;
    flit.datacheck  = item.raw_dat.datacheck;
    flit.data       = item.raw_dat.data;
    flit.be         = item.raw_dat.be;
    flit.tracetag   = item.raw_dat.tracetag;
    flit.dataid     = item.raw_dat.dataid;
    flit.ccid       = item.raw_dat.ccid;
    flit.dbid       = item.raw_dat.dbid;
    flit.cbusy      = item.raw_dat.cbusy;
    flit.datasource = item.raw_dat.datasource;
    flit.resp       = item.raw_dat.resp;
    flit.resperr    = item.raw_dat.resperr;
    flit.opcode     = item.raw_dat.opcode;
    flit.homenid    = item.raw_dat.homenid;
    flit.txnid      = item.raw_dat.txnid;
    flit.srcid      = item.raw_dat.srcid;
    flit.tgtid      = item.raw_dat.tgtid;
    flit.qos        = item.raw_dat.qos;

    this.apply_raw_dat_issue_specific_fields(flit, item.raw_dat);
    this.wait_dat_credit();

    this.acquire_tx_flit();
    @(this.vif_rni.g_drv.rni_cb);
    this.drive_idle_sideband();
    // A raw flit is a single injected packet with no completion to wait
    // for, so its window is the flit itself.
    this.tx_activity_begin();
    this.vif_rni.g_drv.rni_cb.txdatflitpend <= item.raw_flitpend;
    this.vif_rni.g_drv.rni_cb.txdatflit     <= flit;
    this.vif_rni.g_drv.rni_cb.txdatflitv    <= 1'b1;

    @(this.vif_rni.g_drv.rni_cb);
    this.drive_idle_sideband();
    this.vif_rni.g_drv.rni_cb.txdatflitpend <= 1'b0;
    this.vif_rni.g_drv.rni_cb.txdatflitv    <= 1'b0;
    this.vif_rni.g_drv.rni_cb.txdatflit     <= '0;
    this.tx_activity_end();
    this.release_tx_flit();
  endtask

  // ---------------------------------------------------------------------------
  // Optional issue-specific raw-REQ hook for exact-CHI-E field presence.
  // ---------------------------------------------------------------------------
  virtual protected function void apply_raw_req_issue_specific_fields(
    ref   req_flit_t flit,
    input raw_req_t  raw
  );
  endfunction

  // ---------------------------------------------------------------------------
  // Optional issue-specific raw-RSP hook for exact-CHI-E field presence.
  // ---------------------------------------------------------------------------
  virtual protected function void apply_raw_rsp_issue_specific_fields(
    ref   rsp_flit_t flit,
    input raw_rsp_t  raw
  );
  endfunction

  // ---------------------------------------------------------------------------
  // Optional issue-specific raw-DAT hook for exact-CHI-E field presence.
  // ---------------------------------------------------------------------------
  virtual protected function void apply_raw_dat_issue_specific_fields(
    ref   dat_flit_t flit,
    input raw_dat_t  raw
  );
  endfunction

  // ---------------------------------------------------------------------------
  // Optional issue-specific REQ-field hook. The shared implementation only
  // drives fields present in both exact CHI-D and exact CHI-E REQ shapes.
  // ---------------------------------------------------------------------------
  virtual protected function void apply_req_issue_specific_fields(
    ref   req_flit_t flit,
    input item_t     req
  );
  endfunction

  // ---------------------------------------------------------------------------
  // Optional issue-specific DAT-field hook. The shared implementation only
  // drives fields present in both exact CHI-D and exact CHI-E DAT shapes.
  // ---------------------------------------------------------------------------
  virtual protected function void apply_dat_issue_specific_fields(
    ref   dat_flit_t   flit,
    input item_t       req,
    input int unsigned beat_index
  );
  endfunction

  // ---------------------------------------------------------------------------
  // Drive zero or more DAT beats for a write request.
  // ---------------------------------------------------------------------------
  protected task drive_dat(input item_t req);

    dat_flit_t flit;

    if (req.opcode == VIP_CHI_REQ_WRITE_NO_SNP_ZERO_C) begin

      return;
    end

    // Hold the TX flit mutex for the whole burst so a concurrent flit driver
    // (an RN-F snoop responder's SnpRespData in M4) cannot interleave beats of
    // another packet into this one. Safe against wedging: the DAT send credit
    // that each beat waits on is returned by the receiver independently of any
    // snoop response, so the burst always drains and releases the key.
    this.acquire_tx_flit();
    foreach (req.data[i]) begin

      flit = '0;
      flit.data       = req.data[i];
      flit.be         = req.be[i];
      flit.poison     = CFG_P.POISON_EN_P ? req.poison : '0;
      flit.datacheck  = CFG_P.DATACHECK_EN_P ? req.datacheck : '0;
      flit.dataid     = data_id_t'(i);
      flit.ccid       = cc_id_t'(0);
      flit.dbid       = req.dbid;
      flit.resp       = (i < req.dat_resp.size()) ? req.dat_resp[i] : VIP_CHI_RESP_STATE_I_E;
      flit.resperr    = (i < req.dat_resp_err.size()) ? req.dat_resp_err[i] : VIP_CHI_RESP_ERR_NORMAL_OKAY_E;
      flit.opcode     = req.dat_opcode;
      flit.txnid      = req.dbid;
      flit.srcid      = req.src_id;
      flit.tgtid      = req.tgt_id;
      flit.qos        = req.qos;

      this.apply_dat_issue_specific_fields(flit, req, i);
      this.wait_dat_credit();

      @(this.vif_rni.g_drv.rni_cb);
      this.drive_idle_sideband();
      this.vif_rni.g_drv.rni_cb.txdatflitpend <= (i != (req.data.size() - 1));
      this.vif_rni.g_drv.rni_cb.txdatflit     <= flit;
      this.vif_rni.g_drv.rni_cb.txdatflitv    <= 1'b1;

      @(this.vif_rni.g_drv.rni_cb);
      this.drive_idle_sideband();
      this.vif_rni.g_drv.rni_cb.txdatflitpend <= 1'b0;
      this.vif_rni.g_drv.rni_cb.txdatflitv    <= 1'b0;
      this.vif_rni.g_drv.rni_cb.txdatflit     <= '0;
    end
    this.release_tx_flit();

  endtask

  // ---------------------------------------------------------------------------
  // Stamp one received RSP flit onto the shared request/response object.
  // ---------------------------------------------------------------------------
  protected function void stamp_rsp_flit_on_req(input item_t req, input rsp_flit_t flit);

    req.role         = VIP_CHI_ROLE_SNF_E;
    req.src_id       = node_id_t'(flit.srcid);
    req.tgt_id       = node_id_t'(flit.tgtid);
    req.qos          = flit.qos;
    req.rsp_opcode   = rsp_opcode_t'(flit.opcode);
    req.rsp_resp     = vip_chi_resp_t'(flit.resp);
    req.rsp_resp_err = vip_chi_resp_err_t'(flit.resperr);
    req.dbid         = txn_id_t'(flit.dbid);
  endfunction

  // ---------------------------------------------------------------------------
  // Wait for one matching RSP flit on the inbound completion channel.
  // ---------------------------------------------------------------------------
  protected task wait_for_matching_rsp(input txn_id_t req_txn_id, output rsp_flit_t flit);

    forever begin

      while (!this.vif_rni.g_drv.rni_cb.rxrspflitv) begin

        @(this.vif_rni.g_drv.rni_cb);
        this.drive_idle_sideband();
      end

      flit = this.vif_rni.g_drv.rni_cb.rxrspflit;

      if (txn_id_t'(flit.txnid) != req_txn_id) begin

        `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Write completion txn_id 0x%0h does not match request txn_id 0x%0h",
        get_name(), flit.txnid, req_txn_id))
      end

      this.schedule_rsp_credit_return();

      break;
    end
  endtask

  // ---------------------------------------------------------------------------
  // Standalone Persist has no applicable TxnID. Match the already-open
  // transaction by the requester/completer routing pair instead.
  // ---------------------------------------------------------------------------
  protected task wait_for_standalone_persist_rsp(
    input  node_id_t  req_src_id,
    input  node_id_t  req_tgt_id,
    output rsp_flit_t flit
  );

    forever begin

      while (!this.vif_rni.g_drv.rni_cb.rxrspflitv) begin

        @(this.vif_rni.g_drv.rni_cb);
        this.drive_idle_sideband();
      end

      flit = this.vif_rni.g_drv.rni_cb.rxrspflit;

      if ((node_id_t'(flit.srcid) != req_tgt_id) ||
          (node_id_t'(flit.tgtid) != req_src_id)) begin

        `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Standalone Persist route 0x%0h->0x%0h does not match expected 0x%0h->0x%0h",
        get_name(), flit.srcid, flit.tgtid, req_tgt_id, req_src_id))
      end

      this.schedule_rsp_credit_return();

      break;
    end
  endtask

  // ---------------------------------------------------------------------------
  // Wait for the initial DBID-carrying write response before sending DAT.
  // ---------------------------------------------------------------------------
  // ---------------------------------------------------------------------------
  // WriteEvictOrEvict: the one write whose shape the COMPLETER chooses.
  //
  // The requester hands back a clean line and the home decides whether it wants
  // the data. Both answers are legal and neither is predictable from the request,
  // so the requester cannot commit to a data phase until the first response tells
  // it which transaction this turned out to be:
  //
  //   CompDBIDResp -> the home wants it. Send CopyBackWrData. No CompAck follows:
  //                   the specification states the CopyBackWriteData message is
  //                   itself the implicit acknowledgement.
  //   Comp         -> the home declined. Send an explicit CompAck and no data.
  //                   The transaction degenerates into an Evict.
  //
  // This is why the opcode cannot ride the ordinary write path: that path decides
  // whether to send data from the OPCODE alone, before any response has arrived.
  // ---------------------------------------------------------------------------
  protected task drive_write_evict_or_evict(
    inout item_t    req,
    input node_id_t req_src_id,
    input node_id_t req_tgt_id
  );

    rsp_flit_t flit;

    this.wait_for_matching_rsp(req.txn_id, flit);
    this.stamp_rsp_flit_on_req(req, flit);

    if (rsp_opcode_t'(flit.opcode) == rsp_opcode_t'(VIP_CHI_RSP_COMP_DBID_RESP_C)) begin

      req.dbid = txn_id_t'(flit.dbid);
      this.drive_dat(req);
      return;
    end

    if (rsp_opcode_t'(flit.opcode) != rsp_opcode_t'(VIP_CHI_RSP_COMP_C)) begin

      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] WriteEvictOrEvict first response opcode 0x%0h was neither CompDBIDResp nor Comp",
      get_name(), flit.opcode))
    end

    this.drive_comp_ack(req.txn_id, req_src_id, req_tgt_id);
  endtask

  protected task collect_write_dbid_grant(
    inout  item_t     req,
    output bit        wait_for_deferred_comp,
    output rsp_flit_t flit
  );

    this.wait_for_matching_rsp(req.txn_id, flit);
    req.dbid = txn_id_t'(flit.dbid);

    case (rsp_opcode_t'(flit.opcode))

      rsp_opcode_t'(VIP_CHI_RSP_COMP_DBID_RESP_C): begin
        wait_for_deferred_comp = 1'b0;
      end

      rsp_opcode_t'(VIP_CHI_RSP_DBID_RESP_C): begin
        wait_for_deferred_comp = 1'b1;
      end

      rsp_opcode_t'(VIP_CHI_RSP_DBID_RESP_ORD_C): begin
        wait_for_deferred_comp = 1'b1;
      end

      default: begin
        `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Write grant opcode 0x%0h was not CompDBIDResp/DBIDResp/DBIDRespOrd",
        get_name(), flit.opcode))
      end
    endcase
  endtask

  // ---------------------------------------------------------------------------
  // Wait for one matching ReadReceipt on the inbound RSP channel.
  // ---------------------------------------------------------------------------
  protected task collect_read_receipt(input item_t req);

    rsp_flit_t flit;

    this.wait_for_matching_rsp(req.txn_id, flit);

    if (rsp_opcode_t'(flit.opcode) != rsp_opcode_t'(VIP_CHI_RSP_READ_RECEIPT_C)) begin

      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] Ordered read receipt opcode 0x%0h was not ReadReceipt",
      get_name(), flit.opcode))
    end

    // Step off the accepted ReadReceipt beat so a following RSP collection (a
    // separated read's RespSepData) cannot reconsume it while rxrspflitv is
    // still high this cycle.
    @(this.vif_rni.g_drv.rni_cb);
    this.drive_idle_sideband();
  endtask

  // ---------------------------------------------------------------------------
  // Wait for one RespSepData on the inbound RSP channel: the response leg of a
  // separated read, carrying the completion Resp ahead of the DataSepResp data.
  // ---------------------------------------------------------------------------
  protected task collect_resp_sep_data(inout item_t req);

    rsp_flit_t flit;

    this.wait_for_matching_rsp(req.txn_id, flit);
    this.stamp_rsp_flit_on_req(req, flit);

    if (rsp_opcode_t'(flit.opcode) != rsp_opcode_t'(VIP_CHI_RSP_RESP_SEP_DATA_C)) begin

      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] Separated read response opcode 0x%0h was not RespSepData",
      get_name(), flit.opcode))
    end

    // Step off the accepted RespSepData beat before the DataSepResp collection.
    @(this.vif_rni.g_drv.rni_cb);
    this.drive_idle_sideband();
  endtask

  // ---------------------------------------------------------------------------
  // A P-credit granted and never consumed is a leaked protocol credit: the
  // completer set aside a re-issue slot this requester never took, and nothing
  // else in the flow notices -- the traffic completes, the test passes, and the
  // retry handshake is left half-finished. Name whatever is still banked at end
  // of test, with its PCrdType, so the leak is attributable.
  //
  // A reset clears the bank (handle_reset), which is correct: credits do not
  // survive a link teardown, so only a leak in the final reset-free stretch is
  // reported.
  // ---------------------------------------------------------------------------
  function void check_phase(input uvm_phase phase);

    vip_chi_pcrd_type_t pcrd_type;

    super.check_phase(phase);

    if (this.pcrd_pool_total() == 0) begin
      return;
    end

    if (this.pcrd_pool.first(pcrd_type)) begin
      do begin
        if (this.pcrd_pool[pcrd_type] > 0) begin
          `uvm_error(get_name(), $sformatf(
            "[%s] %0d P-credit(s) of PCrdType 0x%0h were granted and never consumed at end of test: the retry handshake is left half-finished",
            get_name(), this.pcrd_pool[pcrd_type], pcrd_type))
        end
      end while (this.pcrd_pool.next(pcrd_type));
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Total P-credits currently banked and unconsumed, summed over every PCrdType.
  // ---------------------------------------------------------------------------
  protected function int unsigned pcrd_pool_total();
    vip_chi_pcrd_type_t t;
    pcrd_pool_total = 0;
    if (this.pcrd_pool.first(t)) begin
      do begin
        pcrd_pool_total += this.pcrd_pool[t];
      end while (this.pcrd_pool.next(t));
    end
  endfunction

  // ---------------------------------------------------------------------------
  // cfg.max_pcrd_budget bounds how many P-credits this requester is willing to
  // hold at once. A completer may only grant a credit against a RetryAck it has
  // already sent, so the bank can never legitimately outgrow the number of
  // requests this node has in flight: exceeding the budget means the completer
  // granted credits it never owed, and the surplus would otherwise sit in the
  // pool authorizing re-issues that nothing bounced. 0 disables the bound.
  // ---------------------------------------------------------------------------
  protected function void check_pcrd_budget();
    if (this.cfg.max_pcrd_budget <= 0) begin
      return;
    end
    if (this.pcrd_pool_total() > int'(this.cfg.max_pcrd_budget)) begin
      `uvm_error(get_name(), $sformatf(
        "[%s] banked P-credits (%0d) exceeded cfg.max_pcrd_budget (%0d): the completer granted more protocol credits than it bounced requests",
        get_name(), this.pcrd_pool_total(), this.cfg.max_pcrd_budget))
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Wait for one PCrdGrant on the inbound RSP channel (the credit that lets a
  // retried request be re-issued). PCrdGrant is not tied to a TxnID; a single-RN
  // requester simply consumes the next grant.
  // ---------------------------------------------------------------------------
  protected task collect_pcrd_grant(input vip_chi_pcrd_type_t pcrd_type);

    forever begin

      while (!this.vif_rni.g_drv.rni_cb.rxrspflitv) begin

        @(this.vif_rni.g_drv.rni_cb);
        this.drive_idle_sideband();
      end

      if (rsp_opcode_t'(this.vif_rni.g_drv.rni_cb.rxrspflit.opcode) !=
          rsp_opcode_t'(VIP_CHI_RSP_PCRD_GRANT_C)) begin

        `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Expected PCrdGrant after RetryAck, got RSP opcode 0x%0h",
        get_name(), this.vif_rni.g_drv.rni_cb.rxrspflit.opcode))
      end

      // The PCrdGrant must return the PCrdType the RetryAck owed; a mismatch means
      // the completer granted a credit for a different pool than it promised (7.4).
      if (this.vif_rni.g_drv.rni_cb.rxrspflit.pcrdtype != pcrd_type) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] PCrdGrant PCrdType 0x%0h != the 0x%0h owed by the RetryAck",
          get_name(), this.vif_rni.g_drv.rni_cb.rxrspflit.pcrdtype, pcrd_type))
      end

      this.schedule_rsp_credit_return();

      // Step off the accepted PCrdGrant beat before the caller re-issues.
      @(this.vif_rni.g_drv.rni_cb);
      this.drive_idle_sideband();
      break;
    end
  endtask

  // ---------------------------------------------------------------------------
  // Protocol-credit retry handling, run right after a request is driven. Only
  // engages when the request allowed retry (AllowRetry=1); otherwise it is a
  // no-op so every existing test stays byte-identical. It peeks the first
  // inbound completion activity: a DAT beat (read data) or a non-RetryAck RSP
  // (a write grant / ReadReceipt) means no retry, so it returns and leaves that
  // flit for the normal completion collector. A RetryAck means the completer
  // bounced the request: consume it, wait the matching PCrdGrant, then re-issue
  // the same request with AllowRetry cleared and the granted PCrdType, and peek
  // again (the re-issue may itself complete or, in principle, be retried again).
  // ---------------------------------------------------------------------------
  protected task handle_retry(inout item_t req);

    rsp_flit_t          flit;
    vip_chi_pcrd_type_t pcrd;

    if (!req.allow_retry) begin
      return;
    end

    forever begin

      while (!this.vif_rni.g_drv.rni_cb.rxrspflitv &&
             !this.vif_rni.g_drv.rni_cb.rxdatflitv) begin

        @(this.vif_rni.g_drv.rni_cb);
        this.drive_idle_sideband();
      end

      // A DAT beat is a read completion -- no retry; leave it for the collector.
      if (!this.vif_rni.g_drv.rni_cb.rxrspflitv) begin
        return;
      end

      flit = this.vif_rni.g_drv.rni_cb.rxrspflit;

      // A non-RetryAck RSP is a normal completion (write grant / ReadReceipt);
      // leave it in place for the collector to consume.
      if (rsp_opcode_t'(flit.opcode) != rsp_opcode_t'(VIP_CHI_RSP_RETRY_ACK_C)) begin
        return;
      end

      if (txn_id_t'(flit.txnid) != req.txn_id) begin
        `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RetryAck txn_id 0x%0h does not match request txn_id 0x%0h",
        get_name(), flit.txnid, req.txn_id))
      end

      pcrd = flit.pcrdtype;
      this.schedule_rsp_credit_return();

      // Step off the accepted RetryAck beat.
      @(this.vif_rni.g_drv.rni_cb);
      this.drive_idle_sideband();

      this.collect_pcrd_grant(pcrd);

      // Re-issue the same request: clear AllowRetry (the completer must now
      // service it), carry the granted PCrdType, and keep the original TxnID.
      req.allow_retry = 1'b0;
      req.pcrd_type   = pcrd;
      this.drive_req(req, 1'b0);
    end
  endtask

  // ---------------------------------------------------------------------------
  // Wait for the final write completion on RSP and stamp it onto the request
  // object before returning it through the sequencer response path.
  // ---------------------------------------------------------------------------
  protected task collect_write_completion(inout item_t req);

    rsp_flit_t flit;

    this.wait_for_matching_rsp(req.txn_id, flit);
    this.stamp_rsp_flit_on_req(req, flit);

    // This is the deferred completion after a split DBIDResp grant: the buffer
    // was already granted, so only a plain Comp is legal here. A CompDBIDResp
    // (combined grant + completion) would be a protocol error at this point.
    if (rsp_opcode_t'(flit.opcode) != rsp_opcode_t'(VIP_CHI_RSP_COMP_C)) begin

      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] Deferred write completion opcode 0x%0h was not Comp",
      get_name(), flit.opcode))
    end
  endtask

  // ---------------------------------------------------------------------------
  // Collect CompCMO, and the Persist the persistent forms add after it.
  // ---------------------------------------------------------------------------
  protected task collect_combined_cmo_completion(
    inout  item_t    req,
    input  node_id_t req_src_id,
    input  node_id_t req_tgt_id
  );

    rsp_flit_t flit;

    // Step off the write's completion beat first, so this wait cannot reconsume
    // the flit that already retired the write half.
    @(this.vif_rni.g_drv.rni_cb);
    this.drive_idle_sideband();

    this.wait_for_matching_rsp(req.txn_id, flit);

    if (flit.opcode != VIP_CHI_RSP_COMP_CMO_C) begin

      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] combined Write+CMO completion opcode 0x%0h was not CompCMO",
      get_name(), flit.opcode))
    end

    if (!this.req_expects_combined_persist(req)) begin
      return;
    end

    @(this.vif_rni.g_drv.rni_cb);
    this.drive_idle_sideband();

    this.wait_for_standalone_persist_rsp(req_src_id, req_tgt_id, flit);

    if (rsp_opcode_t'(flit.opcode) != rsp_opcode_t'(VIP_CHI_RSP_PERSIST_C)) begin

      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] combined Write+PCMO persist opcode 0x%0h was not Persist",
      get_name(), flit.opcode))
    end
  endtask

  // ---------------------------------------------------------------------------
  // Collect a zero-write completion, in either of its two legal forms.
  //
  // WriteNoSnpZero is answered by DBIDResp and a Comp, or by a combined
  // CompDBIDResp. It carries no write data, so the granted buffer is never used
  // and the DBID looks pointless -- which is exactly why this used to accept a
  // bare Comp, matching a completer that sent one. Both were wrong together.
  // ---------------------------------------------------------------------------
  protected task collect_write_zero_completion(inout item_t req);

    rsp_flit_t flit;

    this.wait_for_matching_rsp(req.txn_id, flit);

    if (rsp_opcode_t'(flit.opcode) == rsp_opcode_t'(VIP_CHI_RSP_COMP_DBID_RESP_C)) begin

      this.stamp_rsp_flit_on_req(req, flit);
      return;
    end

    if (rsp_opcode_t'(flit.opcode) != rsp_opcode_t'(VIP_CHI_RSP_DBID_RESP_C)) begin

      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] Zero-write first response opcode 0x%0h was neither DBIDResp nor CompDBIDResp",
      get_name(), flit.opcode))
    end

    @(this.vif_rni.g_drv.rni_cb);
    this.drive_idle_sideband();

    this.wait_for_matching_rsp(req.txn_id, flit);
    this.stamp_rsp_flit_on_req(req, flit);

    if (rsp_opcode_t'(flit.opcode) != rsp_opcode_t'(VIP_CHI_RSP_COMP_C)) begin

      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] Zero-write completion after DBIDResp had opcode 0x%0h, not Comp",
      get_name(), flit.opcode))
    end
  endtask

  // ---------------------------------------------------------------------------
  // Collect a separated-persist completion, in either of its two legal forms.
  //
  // A requester MUST accept both, so this accepts both rather than picking one:
  //
  //   * Comp then Persist  -- Point of Coherency reached, then Point of
  //                           Persistence. Two milestones, two responses.
  //   * CompPersist alone  -- the completer combined them.
  //
  // Everything else is rejected, and the rejection is the point. This used to
  // demand Persist THEN CompPersist, which is neither form: no bare Comp ever
  // arrived, and persistence was signalled twice. Because the requester demanded
  // exactly what this VIP's own completer produced, the two agreed with each
  // other and the pair was wrong together.
  // ---------------------------------------------------------------------------
  protected task collect_persist_sep_completion(inout item_t req);

    rsp_flit_t flit;
    node_id_t  req_src_id;
    node_id_t  req_tgt_id;

    req_src_id = req.src_id;
    req_tgt_id = req.tgt_id;

    this.wait_for_matching_rsp(req.txn_id, flit);

    // The combined form is the whole completion: nothing follows it.
    if (rsp_opcode_t'(flit.opcode) == rsp_opcode_t'(VIP_CHI_RSP_COMP_PERSIST_C)) begin

      this.stamp_rsp_flit_on_req(req, flit);
      return;
    end

    if (rsp_opcode_t'(flit.opcode) != rsp_opcode_t'(VIP_CHI_RSP_COMP_C)) begin

      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] PersistSep first completion opcode 0x%0h was neither Comp nor CompPersist",
      get_name(), flit.opcode))
    end

    // Step off the accepted Comp beat so the next wait cannot reconsume the
    // same flit while rxrspflitv is still high in the current cycle.
    @(this.vif_rni.g_drv.rni_cb);
    this.drive_idle_sideband();

    this.wait_for_standalone_persist_rsp(req_src_id, req_tgt_id, flit);
    this.stamp_rsp_flit_on_req(req, flit);

    if (rsp_opcode_t'(flit.opcode) != rsp_opcode_t'(VIP_CHI_RSP_PERSIST_C)) begin

      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] PersistSep completion after Comp had opcode 0x%0h, not Persist",
      get_name(), flit.opcode))
    end
  endtask

  // ---------------------------------------------------------------------------
  // Send one CompAck on the RSP channel after an ordered-write completion.
  // ---------------------------------------------------------------------------
  protected task drive_comp_ack(
    input txn_id_t  txn_id,
    input node_id_t src_id,
    input node_id_t tgt_id
  );
    rsp_flit_t flit;

    flit = '0;
    flit.opcode = rsp_opcode_t'(VIP_CHI_RSP_COMP_ACK_C);
    flit.txnid  = txn_id;
    flit.srcid  = src_id;
    flit.tgtid  = tgt_id;

    this.wait_rsp_credit();

    this.acquire_tx_flit();
    @(this.vif_rni.g_drv.rni_cb);
    this.drive_idle_sideband();
    this.vif_rni.g_drv.rni_cb.txrspflitpend <= 1'b0;
    this.vif_rni.g_drv.rni_cb.txrspflit     <= flit;
    this.vif_rni.g_drv.rni_cb.txrspflitv    <= 1'b1;

    @(this.vif_rni.g_drv.rni_cb);
    this.drive_idle_sideband();
    this.vif_rni.g_drv.rni_cb.txrspflitv    <= 1'b0;
    this.vif_rni.g_drv.rni_cb.txrspflit     <= '0;
    this.release_tx_flit();
  endtask

  // ---------------------------------------------------------------------------
  // Wait for the first-cut read CompData return and stamp it onto the request
  // object before sending it back through the sequencer response path.
  // ---------------------------------------------------------------------------
  // No clear_activity argument any more: TXSACTIVE is closed at the shared
  // retire point, so a collector no longer needs to know whether it is the
  // serial path (which used to drop the sideband here) or the pipelined one
  // (which had to be told not to, or it would have dropped it while its peers
  // were still outstanding).
  // Fields a read-data beat carries about the transfer as a whole, copied onto
  // the request so a sequence can read them back. Every beat of a transfer
  // carries the same values, so the last one to land wins and it does not matter
  // which order they arrived in.
  protected function void stamp_dat_beat_on_req(
    inout item_t     req,
    input dat_flit_t flit
  );
    req.role         = VIP_CHI_ROLE_SNF_E;
    req.src_id       = node_id_t'(flit.srcid);
    req.tgt_id       = node_id_t'(flit.tgtid);
    req.qos          = flit.qos;
    req.dat_opcode   = item_t::dat_opcode_t'(flit.opcode);
    req.dbid         = txn_id_t'(flit.dbid);
    req.rsp_resp     = vip_chi_resp_t'(flit.resp);
    req.rsp_resp_err = vip_chi_resp_err_t'(flit.resperr);
  endfunction

  // Place each beat at the position its DataID names, not at the position it
  // arrived in: CHI lets the beats of one transfer return in any order, and a
  // sequence reading back req.data[] must see the payload in address order
  // regardless. A DataID outside the burst cannot be placed, so that beat keeps
  // its arrival slot and the arrival order stands for the whole burst -- the
  // monitor is the component that reports the malformed DataID.
  protected function void place_dat_beats(
    inout item_t     req,
    input dat_flit_t beats[$]
  );
    bit placeable;
    int beat_pos;

    req.data         = new[beats.size()];
    req.be           = new[beats.size()];
    req.data_id      = new[beats.size()];
    req.cc_id        = new[beats.size()];
    req.dat_resp     = new[beats.size()];
    req.dat_resp_err = new[beats.size()];

    placeable = 1'b1;
    foreach (beats[i]) begin
      if (int'(beats[i].dataid) >= beats.size()) begin
        placeable = 1'b0;
      end
    end

    foreach (beats[i]) begin
      beat_pos                   = placeable ? int'(beats[i].dataid) : i;
      req.data[beat_pos]         = data_t'(beats[i].data);
      req.be[beat_pos]           = be_t'(beats[i].be);
      req.data_id[beat_pos]      = data_id_t'(beats[i].dataid);
      req.cc_id[beat_pos]        = cc_id_t'(beats[i].ccid);
      req.dat_resp[beat_pos]     = vip_chi_resp_t'(beats[i].resp);
      req.dat_resp_err[beat_pos] = vip_chi_resp_err_t'(beats[i].resperr);
    end
  endfunction

  // Collect ONE read's data as a contiguous run of beats, terminated by the
  // FLITPEND deassert. Used by the serial issue paths and by the atomic data
  // completion, all of which have exactly one transfer outstanding, so no beat on
  // the channel can belong to anything else. The mixed pipeline cannot assume
  // that and files beats by TxnID instead -- see mixed_dat_proc.
  protected task collect_read_completion(inout item_t req);

    dat_flit_t         flit;
    dat_flit_t         beats[$];
    txn_id_t           expected_txn_id;

    expected_txn_id = this.expected_read_completion_txn_id(req);

    forever begin

      while (!this.vif_rni.g_drv.rni_cb.rxdatflitv) begin

        @(this.vif_rni.g_drv.rni_cb);
        this.drive_idle_sideband();
      end

      flit = this.vif_rni.g_drv.rni_cb.rxdatflit;

      if (txn_id_t'(flit.txnid) != expected_txn_id) begin

        `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Read completion txn_id 0x%0h does not match expected completion txn_id 0x%0h",
        get_name(), flit.txnid, expected_txn_id))
      end

      this.schedule_dat_credit_return();

      beats.push_back(flit);
      this.stamp_dat_beat_on_req(req, flit);

      if (!this.vif_rni.g_drv.rni_cb.rxdatflitpend) begin
        break;
      end

      @(this.vif_rni.g_drv.rni_cb);
      this.drive_idle_sideband();
    end

    this.place_dat_beats(req, beats);

    @(this.vif_rni.g_drv.rni_cb);
    this.drive_idle_sideband();
  endtask

  // ---------------------------------------------------------------------------
  // Plain, non-ordered ReadNoSnp is the only opcode the first multi-outstanding
  // cut overlaps. Everything else stays on the serial issue path.
  // ---------------------------------------------------------------------------
  protected function bit is_plain_read(input item_t req);

    // ReadNoSnp at any Order value: an ordered read (Order != NONE) additionally
    // receives a ReadReceipt on RSP ahead of its CompData, which mixed_rsp_proc
    // consumes. Separated reads (ReadNoSnpSep) still run serially.
    return (req.opcode == req_opcode_t'(VIP_CHI_REQ_READ_NO_SNP_C)) &&
           !req.raw_override;
  endfunction

  // ---------------------------------------------------------------------------
  // Plain, non-ordered WriteNoSnpFull with no CompAck is the only opcode the
  // first multi-outstanding WRITE cut overlaps. Partial writes, ordered writes,
  // atomics, persist, exp_comp_ack and split DBIDResp+Comp all stay serial.
  // ---------------------------------------------------------------------------
  protected function bit is_plain_write(input item_t req);
    // Full and partial WriteNoSnp share the pipeline, at any Order value: the
    // completion mechanism is the same (combined CompDBIDResp, or split
    // DBIDResp/DBIDRespOrd + Comp) and, for ordered writes, the ExpCompAck /
    // CompAck handshake the TX thread already drives provides the ordering point.
    // WriteNoSnpPtl just carries per-byte BE, which drive_dat already emits.
    // Atomics and persist overlap too, but as their own kinds
    // (is_pipelined_atomic / is_pipelined_persist).
    return ((req.opcode == req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_FULL_C)) ||
            (req.opcode == req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_PTL_C))) &&
           !req.raw_override;
  endfunction

  // ---------------------------------------------------------------------------
  // Atomics overlap in the pipeline as a hybrid kind. They issue write-like (a
  // DBID grant then an operand DAT burst), but a non-store atomic then completes
  // read-like: the SN-F returns the pre-op value on CompData (DAT), matched by
  // find_mixed_read_by_completion and retired on read_done. A store atomic
  // instead completes on RSP (a combined CompDBIDResp, or a split DBIDResp+Comp
  // like a write) and retires on comp_seen. Both cover AtomicStore/Load/Swap/
  // Compare across the [0:7] arithmetic variants.
  // ---------------------------------------------------------------------------
  protected function bit is_pipelined_atomic(input item_t req);
    return vip_chi_types_pkg::vip_chi_req_opcode_is_atomic(
             vip_chi_req_opcode_t'(req.opcode)) && !req.raw_override;
  endfunction

  // ---------------------------------------------------------------------------
  // Persist CMOs overlap as their own no-data kind. A CleanSharedPersist(Sep)
  // carries no write data and takes no DBID grant: it just issues its REQ and
  // completes on RSP -- a single Comp for the non-separated form, or a Persist
  // (intermediate) then CompPersist (final) for the CHI-E separated form. The
  // pipeline therefore never drives DAT for a persist and retires it on the
  // final completion (comp_seen).
  // ---------------------------------------------------------------------------
  protected function bit is_pipelined_persist(input item_t req);
    return ((req.opcode == req_opcode_t'(VIP_CHI_REQ_CLEAN_SHARED_PERSIST_C)) ||
            (req.opcode == req_opcode_t'(VIP_CHI_REQ_CLEAN_SHARED_PERSIST_SEP_C))) &&
           !req.raw_override;
  endfunction

  // ---------------------------------------------------------------------------
  // The single multi-outstanding pipeline (opt-in via cfg.multi_outstanding).
  // One loop overlaps plain ReadNoSnp, WriteNoSnp Full/Ptl AND atomics, so it
  // serves read-only, write-only, mixed and atomic traffic alike -- a read-only
  // sequence simply never pushes a write entry, and vice versa. A test can
  // pipeline a batch of writes then read them back (data-integrity check) or run
  // both directions concurrently. Reads (and non-store atomics) complete on
  // inbound DAT, writes (store atomics and persist CMOs) on inbound RSP, so the
  // two completion monitors never contend; TX stays a single writer (tx thread).
  // The multi_outstanding_write / multi_outstanding_mixed cfg flags are retained
  // for back-compat but no longer select distinct loops.
  // ---------------------------------------------------------------------------
  protected task seq_loop_mixed_pipelined();

    fork

      this.mixed_tx_proc();
      this.mixed_rsp_proc();
      this.mixed_dat_proc();
    join
  endtask

  // ---------------------------------------------------------------------------
  // Locate any in-flight mixed entry by its request TxnID (linear, bounded by
  // the outstanding count). Matches a write's CompDBIDResp and re-finds a read
  // entry after its completion collection yielded.
  // ---------------------------------------------------------------------------
  protected function int find_mixed_ctx_by_txn(input txn_id_t txn);

    foreach (this.mx_ctx[i]) begin

      if (this.mx_ctx[i].item.txn_id == txn) begin

        return i;
      end
    end

    return -1;
  endfunction

  // ---------------------------------------------------------------------------
  // Locate the separated-persist entry owed a standalone Persist. The flit has no
  // applicable TxnID, so match by route after the TxnID-keyed Comp milestone.
  // ---------------------------------------------------------------------------
  protected function int find_mixed_persist_ctx(
    input node_id_t rsp_src_id,
    input node_id_t rsp_tgt_id
  );

    foreach (this.mx_ctx[i]) begin

      if ((this.mx_ctx[i].kind == TXN_KIND_PERSIST) &&
          this.mx_ctx[i].comp_seen &&
          !this.mx_ctx[i].persist_seen &&
          (this.mx_ctx[i].req_tgt_id == rsp_src_id) &&
          (this.mx_ctx[i].req_src_id == rsp_tgt_id)) begin

        return i;
      end
    end

    return -1;
  endfunction

  // ---------------------------------------------------------------------------
  // Locate the outstanding transaction whose expected completion TxnID matches
  // an inbound CompData beat: a plain READ (separated reads complete on
  // ReturnTxnID) or a non-store ATOMIC, which returns its pre-op value on
  // CompData just like a read.
  // ---------------------------------------------------------------------------
  protected function int find_mixed_read_by_completion(input txn_id_t txn);

    foreach (this.mx_ctx[i]) begin

      if (((this.mx_ctx[i].kind == TXN_KIND_READ) ||
           ((this.mx_ctx[i].kind == TXN_KIND_ATOMIC) &&
            this.req_expects_atomic_data_completion(this.mx_ctx[i].item))) &&
          (this.expected_read_completion_txn_id(this.mx_ctx[i].item) == txn)) begin

            return i;
      end
    end

    return -1;
  endfunction

  // ---------------------------------------------------------------------------
  // Shared TX + sequencer thread. Issue-first (reads or writes, up to the
  // configured depth), then drive a pending WriteData burst, then retire any
  // finished transaction. Sole owner of TX and seq_item_port.
  // ---------------------------------------------------------------------------
  protected task mixed_tx_proc();

    item_t   req;
    int      max_out;
    int      max_rd;
    int      max_wr;
    int      idx;
    mx_ctx_t ctx;

    forever begin

      this.sample_mixed_overlap();

      max_rd  = (this.cfg.max_outstanding_read  > 0) ? this.cfg.max_outstanding_read  : 1;
      max_wr  = (this.cfg.max_outstanding_write > 0) ? this.cfg.max_outstanding_write : 1;
      max_out = (max_rd > max_wr) ? max_rd : max_wr;

      // 0) Re-issue a bounced entry whose PCrdType credit is now in hand. Kept
      //    ahead of fresh issue so a held retry makes progress the moment its
      //    credit lands, while the rest of the pipeline keeps flowing around it.
      idx = -1;
      foreach (this.mx_ctx[i]) begin
        if (this.mx_ctx[i].retry_pending && !this.mx_ctx[i].retried &&
            this.pcrd_pool.exists(this.mx_ctx[i].pcrd_type) &&
            (this.pcrd_pool[this.mx_ctx[i].pcrd_type] > 0)) begin
          idx = i;
          break;
        end
      end
      if (idx >= 0) begin
        this.pcrd_pool[this.mx_ctx[idx].pcrd_type] -= 1;
        // Re-issue the same request with AllowRetry cleared (the completer must
        // now service it) and the granted PCrdType, keeping the original TxnID
        // (alloc_id=0). grant/comp stay unset, so the normal RSP/DAT flow retires it.
        this.mx_ctx[idx].item.allow_retry = 1'b0;
        this.mx_ctx[idx].item.pcrd_type   = this.mx_ctx[idx].pcrd_type;
        this.mx_ctx[idx].retry_pending    = 1'b0;
        this.mx_ctx[idx].retried          = 1'b1;
        this.drive_req(this.mx_ctx[idx].item, 1'b0);
        continue;
      end

      // 0b) Hand back credits nothing is waiting for. Gated on an IDLE pipeline,
      //    because that is the only moment when "nothing can claim this credit"
      //    is knowable: a bounced request still sits in mx_ctx with
      //    retry_pending set, so returning a credit while any context is live
      //    risks giving away the one a re-issue is about to need, and that
      //    request would then never go out again. (The Python twin also checks
      //    its pre-accepted queue; this port pulls items on demand through
      //    try_next_item, so an empty mx_ctx is the whole condition here.)
      if (this.cfg.return_unused_pcrd && (this.mx_ctx.size() == 0) &&
          (this.pcrd_pool_total() > 0)) begin
        this.return_unused_pcrds();
        continue;
      end

      // 1) Issue-first: launch the next plain read or write if depth allows AND a
      //    REQ link-credit is actually in hand. The credit gate is essential: if we
      //    entered drive_req() with no REQ credit it would block this single TX
      //    thread inside wait_for_credit(), starving steps 2/2b (which drive an
      //    already-granted write's data) -- a deadlock when the completer withholds
      //    the next REQ credit until the in-flight write settles (e.g. the HN-I
      //    proxy's 1-deep per-RN gate on a split write). Skipping issue here lets
      //    the loop fall through, push the pending write data, and free the
      //    completer to return the credit. Against a completer with slack credits
      //    (initial_req_credits >= max_out) this gate is never the limiter, so the
      //    existing multi-outstanding behaviour is unchanged.
      if ((this.mx_ctx.size() < max_out) && this.req_lcrd_mgr.has_credit()) begin
        req = null;
        seq_item_port.try_next_item(req);
        if (req != null) begin
          if (this.is_plain_read(req)) begin
            this.drive_req(req);
            ctx = '{kind: TXN_KIND_READ, item: req, dbid: '0,
                    grant_seen: 1'b0, comp_seen: 1'b0, data_sent: 1'b0, read_done: 1'b0,
                    receipt_seen: 1'b0, persist_seen: 1'b0, compack_sent: 1'b0,
                    retry_pending: 1'b0, retried: 1'b0, pcrd_type: '0,
                    req_src_id: req.src_id, req_tgt_id: req.tgt_id};
            this.mx_ctx.push_back(ctx);
            seq_item_port.item_done();
            continue;
          end
          else if (this.is_plain_write(req)) begin
            this.drive_req(req);
            ctx = '{kind: TXN_KIND_WRITE, item: req, dbid: '0,
                    grant_seen: 1'b0, comp_seen: 1'b0, data_sent: 1'b0, read_done: 1'b0,
                    receipt_seen: 1'b0, persist_seen: 1'b0, compack_sent: 1'b0,
                    retry_pending: 1'b0, retried: 1'b0, pcrd_type: '0,
                    req_src_id: req.src_id, req_tgt_id: req.tgt_id};
            this.mx_ctx.push_back(ctx);
            seq_item_port.item_done();
            continue;
          end
          else if (this.is_pipelined_atomic(req)) begin
            this.drive_req(req);
            ctx = '{kind: TXN_KIND_ATOMIC, item: req, dbid: '0,
                    grant_seen: 1'b0, comp_seen: 1'b0, data_sent: 1'b0, read_done: 1'b0,
                    receipt_seen: 1'b0, persist_seen: 1'b0, compack_sent: 1'b0,
                    retry_pending: 1'b0, retried: 1'b0, pcrd_type: '0,
                    req_src_id: req.src_id, req_tgt_id: req.tgt_id};
            this.mx_ctx.push_back(ctx);
            seq_item_port.item_done();
            continue;
          end
          else if (this.is_pipelined_persist(req)) begin
            this.drive_req(req);
            ctx = '{kind: TXN_KIND_PERSIST, item: req, dbid: '0,
                    grant_seen: 1'b0, comp_seen: 1'b0, data_sent: 1'b0, read_done: 1'b0,
                    receipt_seen: 1'b0, persist_seen: 1'b0, compack_sent: 1'b0,
                    retry_pending: 1'b0, retried: 1'b0, pcrd_type: '0,
                    req_src_id: req.src_id, req_tgt_id: req.tgt_id};
            this.mx_ctx.push_back(ctx);
            seq_item_port.item_done();
            continue;
          end
          else begin
            `uvm_fatal(get_name(), $sformatf(
              "FATAL [%s] mixed pipeline supports ReadNoSnp / WriteNoSnp / atomics / persist only (opcode 0x%0h)",
              get_name(), req.opcode))
          end
        end
      end

      // 2) Drive WriteData/operand for the first granted write or atomic that
      //    has not sent it yet (atomics send their operand burst just like a
      //    write sends its data, both keyed on the granted DBID).
      idx = -1;
      foreach (this.mx_ctx[i]) begin
        if (((this.mx_ctx[i].kind == TXN_KIND_WRITE) ||
             (this.mx_ctx[i].kind == TXN_KIND_ATOMIC)) &&
            this.mx_ctx[i].grant_seen && !this.mx_ctx[i].data_sent) begin
          idx = i;
          break;
        end
      end
      if (idx >= 0) begin
        this.drive_dat(this.mx_ctx[idx].item);
        this.mx_ctx[idx].data_sent = 1'b1;
        continue;
      end

      // 2b) Drive CompAck for the first completed exp_comp_ack write not yet
      //     acked. Ordered after the data (data_sent) and completion (comp_seen),
      //     matching the SN-F which waits for CompAck after Comp.
      idx = -1;
      foreach (this.mx_ctx[i]) begin
        if (((this.mx_ctx[i].kind == TXN_KIND_WRITE) ||
             (this.mx_ctx[i].kind == TXN_KIND_ATOMIC)) &&
            this.mx_ctx[i].item.exp_comp_ack &&
            this.mx_ctx[i].data_sent &&
            (this.mx_ctx[i].comp_seen || this.mx_ctx[i].read_done) &&
            !this.mx_ctx[i].compack_sent) begin
          idx = i;
          break;
        end
      end
      if (idx >= 0) begin
        this.drive_comp_ack(this.mx_ctx[idx].item.txn_id,
                            this.mx_ctx[idx].req_src_id,
                            this.mx_ctx[idx].req_tgt_id);
        this.mx_ctx[idx].compack_sent = 1'b1;
        continue;
      end

      // 3) Retire every finished transaction.
      if (this.retire_mixed()) begin
        continue;
      end

      // 4) Nothing to do this cycle.
      @(this.vif_rni.g_drv.rni_cb);
      this.drive_idle_sideband();
    end
  endtask

  // ---------------------------------------------------------------------------
  // Sample bidirectional overlap: whenever the pipeline simultaneously holds at
  // least one read and one write entry, record the peak total in-flight depth at
  // that instant. Lets a test prove reads and writes actually coexisted in
  // flight, not just that traffic pipelined in a single direction.
  // ---------------------------------------------------------------------------
  protected function void sample_mixed_overlap();
    int n_rd;
    int n_wr;

    n_rd = 0;
    n_wr = 0;
    foreach (this.mx_ctx[i]) begin
      // An atomic is bidirectional (operand write + data read), not a pure write;
      // counting it as a write reported false read/write overlap. Exclude it from
      // this pure-read-vs-pure-write concurrency metric (7.4). READ -> read,
      // WRITE/PERSIST -> write.
      case (this.mx_ctx[i].kind)
        TXN_KIND_READ:   n_rd++;
        TXN_KIND_ATOMIC: /* bidirectional -- excluded */ ;
        default:         n_wr++;
      endcase
    end

    if ((n_rd > 0) && (n_wr > 0) &&
        (this.mx_ctx.size() > this.cfg.observed_peak_mixed_inflight)) begin
      this.cfg.observed_peak_mixed_inflight = this.mx_ctx.size();
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Hand back and release every finished mixed transaction: a read once its
  // CompData is assembled, a write once its data is sent and completion seen.
  // No timing controls, so the scan/mutate is atomic against the monitors.
  // ---------------------------------------------------------------------------
  protected function bit retire_mixed();
    bit retired;
    bit done;
    int i;

    retired = 1'b0;
    i = 0;
    while (i < this.mx_ctx.size()) begin
      if (this.mx_ctx[i].kind == TXN_KIND_READ) begin
        // A read is done once its CompData is assembled; an ordered read must
        // also have seen its ReadReceipt.
        done = this.mx_ctx[i].read_done &&
               ((vip_chi_req_order_t'(this.mx_ctx[i].item.order) == VIP_CHI_ORDER_NONE_E) ||
                this.mx_ctx[i].receipt_seen);
      end
      else if (this.mx_ctx[i].kind == TXN_KIND_ATOMIC) begin
        // An atomic is done once its operand is sent and its completion arrives:
        // a non-store atomic completes on CompData (read_done), a store atomic on
        // its RSP (comp_seen). An exp_comp_ack atomic must also have acked.
        if (this.req_expects_atomic_data_completion(this.mx_ctx[i].item)) begin
          done = this.mx_ctx[i].data_sent && this.mx_ctx[i].read_done;
        end
        else begin
          done = this.mx_ctx[i].data_sent && this.mx_ctx[i].comp_seen;
        end
        done = done && (!this.mx_ctx[i].item.exp_comp_ack || this.mx_ctx[i].compack_sent);
      end
      else if (this.mx_ctx[i].kind == TXN_KIND_PERSIST) begin
        // A persist has no data phase. CleanSharedPersist is done on its Comp.
        // The separated form owes BOTH milestones -- Point of Coherency and Point
        // of Persistence -- so retiring on comp_seen alone would close the
        // transaction while its Persist was still in flight, and that Persist
        // would then arrive against a transaction the driver had forgotten.
        // A CompPersist sets both flags, so the combined form still retires on
        // one flit.
        if (this.req_expects_persist_sep_completion(this.mx_ctx[i].item)) begin
          done = this.mx_ctx[i].comp_seen && this.mx_ctx[i].persist_seen;
        end
        else begin
          done = this.mx_ctx[i].comp_seen;
        end
      end
      else begin
        // A write is done once data is sent and completion is seen; an
        // exp_comp_ack write must also have driven its CompAck.
        done = this.mx_ctx[i].data_sent && this.mx_ctx[i].comp_seen &&
               (!this.mx_ctx[i].item.exp_comp_ack || this.mx_ctx[i].compack_sent);
      end

      if (done) begin
        seq_item_port.put_response(this.mx_ctx[i].item);
        this.free_txn_id(this.mx_ctx[i].item.txn_id);
        // The retire point the pipelined path shares with the serial loop: the
        // count only reaches zero once the LAST outstanding transaction is out.
        this.tx_activity_end();
        this.mx_ctx.delete(i);
        retired = 1'b1;
      end
      else begin
        i++;
      end
    end
    return retired;
  endfunction

  // ---------------------------------------------------------------------------
  // Write-completion monitor: match each inbound write RSP to its outstanding
  // write and record grant/completion. Two policies are supported: a combined
  // CompDBIDResp (grant + completion in one flit) or a split DBIDResp (grant)
  // followed later by a deferred Comp (completion), selected by the SN-F's
  // cfg.split_write_rsp. grant_seen lets the TX thread drive WriteData; the write
  // retires only once data is sent AND comp_seen is set. Drives no TX, touches no
  // sequencer state.
  // ---------------------------------------------------------------------------
  protected task mixed_rsp_proc();
    rsp_flit_t   flit;
    txn_id_t     txn;
    int          idx;
    rsp_opcode_t op;

    forever begin
      while (!this.vif_rni.g_drv.rni_cb.rxrspflitv) begin
        @(this.vif_rni.g_drv.rni_cb);
        this.drive_idle_sideband();
      end

      flit = this.vif_rni.g_drv.rni_cb.rxrspflit;
      txn  = txn_id_t'(flit.txnid);
      op   = rsp_opcode_t'(flit.opcode);
      this.schedule_rsp_credit_return();

      // PCrdGrant is credit-typed, not TxnID-tied: bank one credit of its
      // PCrdType for a bounced entry to consume, then step off (no ctx lookup).
      if (op == rsp_opcode_t'(VIP_CHI_RSP_PCRD_GRANT_C)) begin
        this.pcrd_pool[flit.pcrdtype] += 1;
        this.pcrd_granter[flit.pcrdtype] = node_id_t'(flit.srcid);
        this.pcrd_own_id[flit.pcrdtype]  = node_id_t'(flit.tgtid);
        this.check_pcrd_budget();
        @(this.vif_rni.g_drv.rni_cb);
        this.drive_idle_sideband();
        continue;
      end

      if (op == VIP_CHI_RSP_PERSIST_C) begin
        idx = this.find_mixed_persist_ctx(node_id_t'(flit.srcid), node_id_t'(flit.tgtid));
      end
      else begin
        idx = this.find_mixed_ctx_by_txn(txn);
      end
      if (idx < 0) begin
        if (op == VIP_CHI_RSP_PERSIST_C) begin
          `uvm_fatal(get_name(), $sformatf(
            "FATAL [%s] Standalone Persist route 0x%0h->0x%0h matches no outstanding separated-persist transaction",
            get_name(), flit.srcid, flit.tgtid))
        end
        else begin
          `uvm_fatal(get_name(), $sformatf(
            "FATAL [%s] RSP txn_id 0x%0h matches no outstanding transaction",
            get_name(), txn))
        end
      end

      // RetryAck bounces this request: mark the entry for re-issue once its
      // PCrdType credit is in hand (the TX thread re-drives it), record the owed
      // type, and step off. A re-issue carries allow_retry=0, so a second
      // RetryAck for the same entry is a protocol error.
      if (op == rsp_opcode_t'(VIP_CHI_RSP_RETRY_ACK_C)) begin
        if (this.mx_ctx[idx].retried) begin
          `uvm_fatal(get_name(), $sformatf(
            "FATAL [%s] second RetryAck for txn_id 0x%0h (re-issue must not be retryable)",
            get_name(), txn))
        end
        this.mx_ctx[idx].retry_pending = 1'b1;
        this.mx_ctx[idx].pcrd_type     = flit.pcrdtype;
        @(this.vif_rni.g_drv.rni_cb);
        this.drive_idle_sideband();
        continue;
      end

      // An ordered read receives a ReadReceipt on the RSP channel ahead of its
      // CompData on DAT. Record it and step off; the read still completes and
      // retires on the DAT side (mixed_dat_proc), gated on receipt_seen.
      if (this.mx_ctx[idx].kind == TXN_KIND_READ) begin
        if (op != rsp_opcode_t'(VIP_CHI_RSP_READ_RECEIPT_C)) begin
          `uvm_fatal(get_name(), $sformatf(
            "FATAL [%s] read RSP txn_id 0x%0h expected ReadReceipt, got opcode 0x%0h",
            get_name(), txn, flit.opcode))
        end
        this.mx_ctx[idx].receipt_seen = 1'b1;
        @(this.vif_rni.g_drv.rni_cb);
        this.drive_idle_sideband();
        continue;
      end

      // A persist CMO carries no data and completes on RSP only:
      //
      //   * CleanSharedPersist      -- a single Comp.
      //   * CleanSharedPersistSep   -- Comp (Point of Coherency) then Persist
      //                                (Point of Persistence), or the two
      //                                combined as one CompPersist.
      //
      // Both separated forms are accepted because a requester must accept both.
      // stamp so the handed-back item shows the latest completion opcode.
      if (this.mx_ctx[idx].kind == TXN_KIND_PERSIST) begin
        this.stamp_rsp_flit_on_req(this.mx_ctx[idx].item, flit);
        case (op)
          rsp_opcode_t'(VIP_CHI_RSP_PERSIST_C): begin
            this.mx_ctx[idx].persist_seen = 1'b1;
          end
          rsp_opcode_t'(VIP_CHI_RSP_COMP_PERSIST_C): begin
            // Comp and Persist in one flit: both milestones at once.
            this.mx_ctx[idx].comp_seen    = 1'b1;
            this.mx_ctx[idx].persist_seen = 1'b1;
          end
          rsp_opcode_t'(VIP_CHI_RSP_COMP_C): begin
            this.mx_ctx[idx].comp_seen = 1'b1;
          end
          default: begin
            `uvm_fatal(get_name(), $sformatf(
              "FATAL [%s] pipeline persist expects Persist/CompPersist/Comp, got opcode 0x%0h",
              get_name(), flit.opcode))
          end
        endcase
        @(this.vif_rni.g_drv.rni_cb);
        this.drive_idle_sideband();
        continue;
      end

      // Writes and atomics share this branch: both take a DBID grant on RSP and,
      // for the split/store cases, a later Comp. stamp records the response
      // fields on the request item; for the split policy the later Comp
      // overwrites rsp_opcode so the handed-back item shows Comp, matching the
      // serial split-write behavior. A non-store atomic gets only its DBIDResp
      // grant here; its CompData completion is handled on the DAT side.
      this.stamp_rsp_flit_on_req(this.mx_ctx[idx].item, flit);

      case (op)
        rsp_opcode_t'(VIP_CHI_RSP_COMP_DBID_RESP_C): begin
          // Combined: grant and completion arrive together.
          this.mx_ctx[idx].dbid       = txn_id_t'(flit.dbid);
          this.mx_ctx[idx].grant_seen = 1'b1;
          this.mx_ctx[idx].comp_seen  = 1'b1;
        end
        rsp_opcode_t'(VIP_CHI_RSP_DBID_RESP_C),
        rsp_opcode_t'(VIP_CHI_RSP_DBID_RESP_ORD_C): begin
          // Split grant (DBIDRespOrd is the CHI-E ordered variant): buffer
          // allocated, completion still owed via a later Comp.
          this.mx_ctx[idx].dbid       = txn_id_t'(flit.dbid);
          this.mx_ctx[idx].grant_seen = 1'b1;
        end
        rsp_opcode_t'(VIP_CHI_RSP_COMP_C): begin
          // Split completion, following the earlier DBIDResp.
          this.mx_ctx[idx].comp_seen  = 1'b1;
        end
        default: begin
          `uvm_fatal(get_name(), $sformatf(
            "FATAL [%s] pipeline write/atomic expects CompDBIDResp or DBIDResp+Comp, got opcode 0x%0h",
            get_name(), flit.opcode))
        end
      endcase

      @(this.vif_rni.g_drv.rni_cb);
      this.drive_idle_sideband();
    end
  endtask

  // ---------------------------------------------------------------------------
  // Read-completion monitor: for each inbound CompData burst, match it to the
  // outstanding read by TxnID, assemble the payload onto the request item, and
  // flag it done for the TX thread to retire. Drives no TX, no sequencer.
  // ---------------------------------------------------------------------------
  // The pipeline's DAT receive path, one beat at a time.
  //
  // Each beat is filed against the transaction its TxnID names and the transfer
  // retires on its OWN beat count, derived from the request Size. That is the
  // difference from collect_read_completion: with several reads outstanding a
  // completer may interleave their beats on the channel, and the FLITPEND
  // deassert then marks the end of the channel's activity rather than the end of
  // any one transfer. Counting beats per transaction is the only reading that
  // survives both shapes -- and it costs nothing on contiguous traffic, where the
  // count is reached on exactly the beat FLITPEND would have marked.
  protected task mixed_dat_proc();
    dat_flit_t beat;
    txn_id_t   beat_txn;
    txn_id_t   req_txn;
    int        idx;
    int        expected;
    bit        complete;
    item_t     r;

    forever begin
      while (!this.vif_rni.g_drv.rni_cb.rxdatflitv) begin
        @(this.vif_rni.g_drv.rni_cb);
        this.drive_idle_sideband();
      end

      beat     = this.vif_rni.g_drv.rni_cb.rxdatflit;
      beat_txn = txn_id_t'(beat.txnid);

      idx = this.find_mixed_read_by_completion(beat_txn);
      if (idx < 0) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] Mixed CompData TxnID 0x%0h matches no outstanding read",
          get_name(), beat_txn))
      end

      r = this.mx_ctx[idx].item;

      // Atomic data completions keep the contiguous collector: the returned size
      // is not the request Size (AtomicCompare returns half of it), so there is
      // no beat count to retire on, and the completer never interleaves them.
      if (this.mx_ctx[idx].kind != TXN_KIND_READ) begin
        this.collect_read_completion(r);
        idx = this.find_mixed_ctx_by_txn(r.txn_id);
        if (idx < 0) begin
          `uvm_fatal(get_name(), $sformatf(
            "FATAL [%s] Mixed read TxnID 0x%0h vanished before completion",
            get_name(), r.txn_id))
        end
        this.mx_ctx[idx].read_done = 1'b1;
        continue;
      end

      this.schedule_dat_credit_return();
      this.mx_dat_beats[beat_txn].push_back(beat);
      this.stamp_dat_beat_on_req(r, beat);

      expected = vip_chi_types_pkg::chi_xfer_dat_beats(int'(r.size), CFG_P.DATA_BYTES_P);
      complete = (this.mx_dat_beats[beat_txn].size() >= expected);
      if (complete) begin
        this.place_dat_beats(r, this.mx_dat_beats[beat_txn]);
        this.mx_dat_beats.delete(beat_txn);
      end

      req_txn = r.txn_id;

      @(this.vif_rni.g_drv.rni_cb);
      this.drive_idle_sideband();

      if (complete) begin
        // Re-find by request TxnID: the queue may have shifted while this thread
        // was blocked (only the TX thread deletes, and it will not retire this
        // read until read_done is set just below).
        idx = this.find_mixed_ctx_by_txn(req_txn);
        if (idx < 0) begin
          `uvm_fatal(get_name(), $sformatf(
            "FATAL [%s] Mixed read TxnID 0x%0h vanished before completion",
            get_name(), req_txn))
        end
        this.mx_ctx[idx].read_done = 1'b1;
      end
    end
  endtask

endclass

`endif
