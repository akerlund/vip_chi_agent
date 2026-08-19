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

`ifndef VIP_CHI_CFG_AGENT
`define VIP_CHI_CFG_AGENT

import uvm_pkg::*;
`include "uvm_macros.svh"
import vip_chi_types_pkg::*;

class vip_chi_cfg_agent extends uvm_object;

  `uvm_object_utils(vip_chi_cfg_agent)

  uvm_active_passive_enum is_active = UVM_ACTIVE;
  vip_chi_role_t          role      = VIP_CHI_ROLE_SNF_E;

  uvm_verbosity req_verbosity = UVM_HIGH;
  uvm_verbosity rsp_verbosity = UVM_HIGH;
  uvm_verbosity dat_verbosity = UVM_HIGH;

  int max_outstanding_read  = 16;
  int max_outstanding_write = 16;

  // Requester bound on P-credits banked but not yet consumed, summed over every
  // PCrdType. A completer may only grant a protocol credit against a RetryAck it
  // has already sent, so the bank cannot legitimately outgrow this node's own
  // bounced requests; going past the budget means the completer granted credits
  // it never owed. 0 disables the bound. Ignored by the completer roles.
  int max_pcrd_budget = 8;

  // Speculative TXSACTIVE extension, in cycles past the close of the
  // outstanding window. TXSACTIVE says the node MAY have snoopable transactions
  // outstanding, so holding it longer than strictly necessary is always legal --
  // it only costs the receiver the chance to gate its snoop logic. Raising this
  // models a node that keeps the sideband up briefly in anticipation of more
  // traffic. Default 0 drops it as soon as the window closes, which is the
  // tightest legal behaviour and the one the checks bound against.
  int unsigned txsactive_extend_max_cycles = 0;

  // Opt-in multi-outstanding datapath (P4). Default 0 preserves the strict
  // serial path every existing testcase relies on. When set on BOTH the RN-I
  // and SN-F cfg, the RN-I decouples read issue from completion (several reads
  // in flight at once) and the SN-F buffers inbound REQs so pipelined requests
  // are not dropped while it is mid-response. First cut overlaps plain
  // ReadNoSnp only; other opcodes still run serially on the issue thread.
  bit multi_outstanding = 1'b0;

  // Selects the WRITE overlap path on the RN-I when multi_outstanding is also
  // set: read issue/completion (0, default) versus write issue/completion (1).
  // The first write cut overlaps plain WriteNoSnpFull (order NONE, no CompAck,
  // combined CompDBIDResp grant) only; the SN-F side needs no extra flag because
  // its buffered loop already services reads and writes. Ignored unless
  // multi_outstanding is set, so every serial test is unaffected.
  bit multi_outstanding_write = 1'b0;

  // Selects the unified MIXED overlap loop on the RN-I when multi_outstanding is
  // also set: one pipelined loop handles both plain ReadNoSnp and plain
  // WriteNoSnpFull, so a single test can pipeline writes and then read them back
  // for an end-to-end data-integrity check. Takes precedence over
  // multi_outstanding_write; ignored unless multi_outstanding is set.
  bit multi_outstanding_mixed = 1'b0;

  // Published by the RN-I driver: peak simultaneously in-flight transactions
  // observed, so a test can confirm overlap actually happened (not just that
  // the traffic completed serially).
  int unsigned observed_peak_outstanding = 0;

  // Published by the RN-I mixed loop: peak in-flight depth sampled at a moment
  // when at least one read AND one write were simultaneously in the pipeline, so
  // a test can prove true bidirectional overlap rather than merely same-
  // direction pipelining. 0 means reads and writes never coexisted in flight.
  int unsigned observed_peak_mixed_inflight = 0;

  // Number of initial LCRDV grants this agent advertises after link activation
  // for each inbound channel it can consume.
  int unsigned initial_req_credits = 8;
  int unsigned initial_rsp_credits = 8;
  int unsigned initial_dat_credits = 8;

  // Local caps for peer-advertised send-side credits accumulated through
  // inbound LCRDV pulses. These are intentionally decoupled from the initial
  // receive-credit grants this agent advertises on the wire.
  int unsigned req_send_credit_cap = 64;
  int unsigned rsp_send_credit_cap = 64;
  int unsigned dat_send_credit_cap = 64;

  // When set, this agent stops advertising DAT receive credits on the wire: the
  // grants it would emit accumulate and are drained once the flag clears. A test
  // can toggle it at runtime to starve the peer's DAT sends (see
  // tc_chi_credit_starvation) without the harness having to pinch the wire.
  bit hold_dat_credit = 1'b0;

  vip_chi_decerr_range_t decerr_ranges [];
  vip_chi_derr_range_t   derr_ranges   [];

  int force_retry_count = 0;

  bit split_write_rsp = 1'b0;
  bit ordered_dbid_resp = 1'b0;

  // Return P-credits this requester banked but never used, with PCrdReturn.
  // The specification requires unused credits to be returned "in a timely
  // manner" -- holding one leaves the completer's re-issue slot reserved
  // forever. Default off because returning a credit puts an extra REQ flit on
  // the wire, which would change the waveform of every existing retry test.
  bit return_unused_pcrd = 1'b0;

  // CleanSharedPersistSep has two legal completions: a Comp (the request reached
  // the Point of Coherency) followed by a Persist (it reached the Point of
  // Persistence), or the two combined into a single CompPersist. A requester
  // must accept both, so the completer must be able to produce both. Default off
  // = separate Comp then Persist, which is the form that carries the PoC and PoP
  // milestones as distinguishable events; the combined form collapses them.
  bit combined_persist_rsp = 1'b0;

  // Completer DAT beat ordering. CHI identifies a beat's position by its DataID,
  // not by its position in the burst, so a completer is free to return the beats
  // of one transfer in any order. This VIP's completers emit them in ascending
  // DataID by default; set this to have the SN-F return read data in DESCENDING
  // DataID instead, which is what proves the monitor reassembles by DataID
  // rather than by arrival. A link carrying reordered beats must also be told to
  // stand down the DataID-ordering assertions (+CHI_DAT_REORDER in the example
  // testbench), which exist to hold the default convention.
  bit snf_reverse_dat_beats = 1'b0;

  // Negative-control knob for the monitor's duplicate-DataID check: when set,
  // the SN-F sends the FINAL beat of a read burst carrying DataID 0 again
  // instead of its own position, so one position is delivered twice and one
  // never at all. Both the duplicate check and the missing-beat check must fire.
  // Default 0 keeps every burst well formed.
  bit snf_duplicate_dat_beat = 1'b0;

  // How many in-flight read transfers the completer may take DAT beats from
  // before finishing any one of them. 1, the default, is the behaviour this VIP
  // has always had: a read's beats are emitted contiguously, so the DAT channel
  // carries one transfer at a time and every existing test sees the same wire.
  //
  // Above 1 the SN-F drains up to this many queued reads together, one beat at a
  // time in the order dat_interleave_policy names. That is legal because a DAT
  // flit is self-identifying -- TxnID says which transaction, DataID says which
  // position -- and CHI nowhere requires the beats of a transfer to be
  // contiguous on the channel. It is worth reaching because a receiver that
  // assumes contiguity reassembles correctly right up until something upstream
  // stops being contiguous, and then reports a DATA MISMATCH rather than a
  // reassembly fault.
  //
  // Requires multi_outstanding: the serial responder never holds two requests at
  // once, so there is never a second stream to interleave with (is_valid()
  // rejects the combination rather than leaving the knob silently inert).
  int unsigned dat_interleave_depth = 1;

  // Which eligible stream the next beat comes from. Only consulted when
  // dat_interleave_depth > 1.
  vip_chi_dat_interleave_policy_t dat_interleave_policy =
    VIP_CHI_DAT_INTERLEAVE_ROUND_ROBIN_E;

  // Cycles the responder will wait, with a read already queued, for enough
  // further reads to fill dat_interleave_depth.
  //
  // A completer only has something to interleave when two transfers are queued
  // at once, and a requester pipelines its requests a cycle or two apart --
  // without a window the responder starts the first read's data before the
  // second request is even off the wire, and dat_interleave_depth would look
  // enabled while never once engaging. Bounded, and only entered while a read is
  // already waiting, so nothing stalls on traffic that is not coming.
  //
  // Only consulted when dat_interleave_depth > 1, which is what keeps the
  // default responder's timing untouched.
  int unsigned dat_interleave_gather_cycles = 8;

  // Negative-control knob for the MTE tag checks: when set, the exact-CHI-E
  // completer returns the stored tag with its low bit inverted on the FIRST beat
  // of a read burst, and a different TagOp on the last beat.
  //
  // Two rules, two breakages, one knob, because they fail independently: a
  // completer whose tag store is corrupt returns the wrong tag with a perfectly
  // consistent TagOp, and one that loses track of the transfer returns the right
  // tags under a TagOp that changes mid-burst. A control that broke only one
  // would leave the other unproven.
  //
  // Default 0 replays the stored tagging verbatim.
  bit snf_corrupt_tag = 1'b0;

  // Per-transaction latency bounds, in cycles on the monitor's reset-gated
  // counter. 0 = unbounded, which is the default and preserves behaviour: a
  // bench that has never stated a latency budget should not acquire one. A
  // non-zero bound is checked at the completion milestone of each transaction,
  // so a test that cares about latency can FAIL on it rather than read it out of
  // a report after the fact.
  int unsigned max_read_xact_latency  = 0;
  int unsigned max_write_xact_latency = 0;
  int unsigned max_snp_xact_latency   = 0;

  // Record the arrival cycle of every DAT beat on the item (t_dat_beats). Off by
  // default: it costs an array grow per beat of every transfer, which is not
  // worth paying in a long run for a detail most tests never read. The
  // transaction-level milestones are always stamped and cost nothing per beat.
  bit collect_beat_timestamps = 1'b0;

  // Waveform-correlated transaction recording in the monitor
  // (accept_tr / begin_tr / end_tr). Off by default: a recorded stream costs
  // simulator time and database space on every transaction of every run, which
  // is not worth paying in a long regression for something only read when a
  // specific flow is being debugged.
  //
  // The highest-value flows here are exactly the ones hardest to read as raw
  // flits -- a retry re-issue, a snoop, a DCT forward -- so the recording nests
  // a re-issue under the attempt it replaces rather than showing two unrelated
  // transactions on one TxnID.
  bit record_transactions = 1'b0;

  // Same-line hazard rule: a requester must not have two requests outstanding to
  // one cache line at a time. On by default. A bench whose requester model
  // deliberately overlaps same-line requests turns it off rather than papering
  // over the reports.
  bit hazard_check_enable = 1'b1;

  // Negative-control knob for the scoreboard's ordered-stream check: when set,
  // the buffered SN-F serves the SECOND of two queued ordered requests before the
  // first, so its acknowledgements come back in the wrong order while every
  // transaction still completes correctly on its own. Nothing else in the VIP can
  // see the inversion, which is the point -- it isolates the ordering check.
  // Default 0 keeps the completer strictly first-come-first-served.
  bit snf_reorder_ordered_service = 1'b0;

  // Negative-control knob for the link-activation state machine check: when set,
  // the RN-I raises txlinkactivereq and withdraws it again before the completer
  // acknowledges, stepping the LASM out of ACTIVATE without ever reaching RUN.
  // A requester that has asked for the link must wait for the acknowledge, so
  // this is a genuine illegal transition rather than an unusual-but-legal
  // sequence. It fires once per activation; the link then comes up normally.
  // Default 0 keeps bring-up a clean STOP -> ACTIVATE -> RUN.
  bit lasm_abort_activation = 1'b0;

  // POSITIVE-control knob for the FLITPEND rule: when set, the requester pulses
  // txreqflitpend and txrspflitpend for one cycle with no flit behind them,
  // once, after the link is up.
  //
  // IHI 0050 E §14.4 / D §13.4 permit exactly this -- "a transmitter is
  // permitted to assert and then deassert this signal without sending a flit" --
  // and also permit holding it permanently asserted, and asserting it while
  // holding no L-Credit. The obligation runs the other way, from the flit
  // backwards, so a lone FLITPEND owes nothing and nothing may be reported.
  //
  // It was a NEGATIVE control until CHI_*_VALID_REQUIRES_PEND replaced the
  // inverted rule it was built for. The old rule read `flitpend |-> flitv` and
  // this pulse was written to trip it, which made the suite assert that legal
  // CHI traffic must be reported as a violation. The stimulus was right and the
  // expectation was backwards, so the knob is kept and the verdict inverted.
  //
  // Default 0 keeps the link quiet between flits.
  bit flitpend_without_valid = 1'b0;

  // Negative-control knob for the FLITPEND rule: when set, the requester drops
  // the one-cycle announcement in front of exactly one flit, so it goes out with
  // FLITPEND low in the cycle before it. One-shot -- see announce_flit -- because
  // the point is to prove the rule fires, and every later flit stays legal.
  //
  // Default 0 announces every flit.
  bit flit_without_flitpend = 1'b0;

  // ---------------------------------------------------------------------------
  // Graceful link deactivation.
  //
  // Raised by a test, not by the driver: there is no such thing as an idle
  // moment a driver can detect for itself. Its sequence loop blocks on the
  // sequencer forever, so "no traffic right now" is indistinguishable from
  // "between two sequences", and a driver that tore the link down on that guess
  // would deactivate in the middle of every test. The test knows when it is
  // finished; the driver does not.
  //
  // The requester then walks the second half of the LASM cycle it otherwise
  // never touches -- RUN -> DEACTIVATE -> STOP -- returning every L-credit it
  // holds on the way, because a link that stops with credits still banked leaves
  // the two ends disagreeing about what the peer may send after the next
  // bring-up (VIP_CHI_CHK_LCRD_QUIESCENT_IN_STOP_E is the rule that says so).
  //
  // Lowering it again brings the link back up, so one test can prove the whole
  // cycle: down cleanly, and up again carrying traffic.
  bit link_deactivate_request = 1'b0;

  // Published by the driver, read by the test: set once the link has reached
  // STOP with every credit returned, cleared when it comes back up. A test polls
  // this rather than the sideband wires so it waits for the DRAIN to finish and
  // not merely for the signal to fall.
  bit link_deactivate_done = 1'b0;

  // Negative controls for the two LASM timeouts (which live on the TESTBENCH
  // config, not here -- a stuck link is a property of the link, and the checker
  // that judges it is bound to an interface rather than to one endpoint's
  // driver). Both are completer-side, because the completer owns LINKACTIVEACK
  // and a stuck link is exactly an acknowledge that does not arrive:
  //   * _activation_   delays the acknowledge to a bring-up request.
  //   * _deactivation_ delays dropping the acknowledge once the link is drained.
  // Both count in cycles and default to 0 (no delay).
  int unsigned lasm_stall_activation_cycles   = 0;
  int unsigned lasm_stall_deactivation_cycles = 0;

  vip_mem_config mem_cfg;

  // Cycles the requester waits before asserting txlinkactivereq, indexed by the
  // LINK STATE it observes at that moment (vip_chi_lasm_state_t: STOP,
  // DEACTIVATE, ACTIVATE, RUN).
  //
  // Every other delay in this VIP is a uniform min/max per channel, which can
  // only ever produce the same bring-up shifted in time. Making the delay a
  // function of the state the link is ALREADY in is what makes activation races
  // reachable -- a request timed to land inside the peer's tear-down window is a
  // different scenario, not the same one later, and it is precisely what the
  // LASM transition rule exists to judge.
  //
  // All zero by default, which reproduces today's behaviour exactly.
  int unsigned lasm_req_delay_by_state [4] = '{default: 0};

  // Negative control for the LASM transition rule under a RACE rather than a
  // malformed sequence: the requester re-raises txlinkactivereq as soon as the
  // link enters DEACTIVATE, without waiting for the tear-down to reach STOP.
  //
  // {req=1, ack=1} is RUN, so the link jumps DEACTIVATE -> RUN, which the cycle
  // does not allow (DEACTIVATE may only advance to STOP). It is a genuine
  // violation rather than stimulus tuned to the check: a requester that has
  // withdrawn its request has committed to the tear-down and may not change its
  // mind half way through.
  //
  // Distinct from lasm_abort_activation, which breaks the BRING-UP half by
  // withdrawing a request before the acknowledge. This breaks the tear-down
  // half, and only became reachable once graceful deactivation existed.
  bit lasm_reactivate_during_deactivate = 1'b0;

  // Per-channel transmit delay: cycles the driver holds an assembled flit before
  // asking for a credit and asserting FLITV. Drawn through draw_*_valid_delay()
  // below, which owns the distribution.
  //
  // These three read `enabled = 0` because that is what the wire has always
  // done. They were declared, validated and documented long before anything
  // drew from them, and req_valid_delay_enabled in particular sat at 1 while no
  // driver in either port ever read it -- so its value never meant anything.
  // Wiring them up without flipping that default would have retimed every
  // existing test as a side effect of making a knob work.
  //
  // link_act_delay_* is NOT wired. It would delay the activation request, which
  // is exactly what lasm_req_delay_by_state already does and does better, being
  // a function of the link state the requester acts from rather than a flat
  // window. Two delays on one event would only be confusing; this one is
  // superseded.
  bit link_act_delay_enabled = 1'b1;
  int link_act_delay_min        = 0;
  int link_act_delay_max        = 4;

  // The shape of the draw inside [min, max]. Off is uniform, which is what the
  // window alone has always meant; on is a truncated gaussian centred on
  // <chan>_valid_delay_mean with spread <chan>_valid_delay_stddev, which puts
  // most flits near the mean and a few out at the edges the way real handshake
  // latency does, rather than spreading them flat across the window.
  //
  // The mean/stddev defaults are non-zero and inside each window on purpose: a
  // test that flips only the gauss flag gets a usable distribution rather than a
  // config error or a point mass at an edge.
  bit  req_valid_delay_enabled = 1'b0;
  int  req_valid_delay_min        = 0;
  int  req_valid_delay_max        = 4;
  bit  req_valid_delay_gauss_enabled = 1'b0;
  int  req_valid_delay_mean          = 2;
  real req_valid_delay_stddev        = 1.0;

  bit  rsp_valid_delay_enabled = 1'b0;
  int  rsp_valid_delay_min        = 0;
  int  rsp_valid_delay_max        = 2;
  bit  rsp_valid_delay_gauss_enabled = 1'b0;
  int  rsp_valid_delay_mean          = 1;
  real rsp_valid_delay_stddev        = 1.0;

  bit  dat_valid_delay_enabled = 1'b0;
  int  dat_valid_delay_min        = 0;
  int  dat_valid_delay_max        = 2;
  bit  dat_valid_delay_gauss_enabled = 1'b0;
  int  dat_valid_delay_mean          = 1;
  real dat_valid_delay_stddev        = 1.0;

  // Cached CDFs, one per channel. Null until the first gauss draw on that
  // channel: a config that never enables gauss never allocates one.
  protected vip_gauss g_req_valid_delay;
  protected vip_gauss g_rsp_valid_delay;
  protected vip_gauss g_dat_valid_delay;

  // The knob values each cached CDF was built from, as a signature string. A
  // draw compares the current knobs against this and rebuilds when they differ.
  protected string g_req_valid_delay_built = "";
  protected string g_rsp_valid_delay_built = "";
  protected string g_dat_valid_delay_built = "";

  bit coverage_enabled   = 1'b1;
  bit allow_raw_override = 1'b1;

  int compack_timeout_cycles = 10000;

  // ---------------------------------------------------------------------------
  // Coherent (RN-F / HN-F) knobs. Ignored by the non-coherent roles, so every
  // existing test is unaffected.
  // ---------------------------------------------------------------------------
  // Initial SNP receive-credit budget an RN-F advertises after link activation
  // so the HN-F may source snoops toward it. Local cap for the HN-F's own SNP
  // send-side budget accumulated through inbound SNP LCRDV pulses.
  int unsigned initial_snp_credits = 8;
  int unsigned snp_send_credit_cap = 64;

  // Runtime SNP back-pressure knob (mirrors hold_dat_credit): when set, an RN-F
  // stops advertising SNP receive credits, so its queued grants never reach the
  // wire and the HN-F's SNP send pool starves -- an inbound snoop stalls until it
  // clears. tc_chi_coh_snp_backpressure holds it from build so even the initial
  // credits are withheld, then releases to prove the parked snoop + read complete.
  bit hold_snp_credit = 1'b0;

  // HN-F granted cache state per coherent-read class (M2: no snoops, single
  // grant). A shared-class read (ReadShared/ReadClean/ReadNotSharedDirty) lands
  // the requester in SC; a unique-class read (ReadUnique) lands it in UC. Kept
  // as knobs so a test can force a particular grant without a raw override.
  vip_chi_resp_t coh_read_shared_state = VIP_CHI_RESP_STATE_SC_E;
  vip_chi_resp_t coh_read_unique_state = VIP_CHI_RESP_STATE_UC_E;

  // RN-F cache capacity, in cache lines. 0 = unbounded (default, spec-legal and
  // what every existing test relies on). When > 0, allocating a line beyond the
  // bound triggers a SILENT eviction: a clean victim (SC/UC) is dropped with no
  // bus transaction (the home keeps a stale directory entry, resolved on a later
  // snoop). Writeback-on-eviction of a DIRTY victim is not modeled -- a bounded
  // cache that fills entirely with dirty lines fatals (see docs/FUTURE_WORK.md).
  int rnf_cache_max_lines = 0;

  // Snoop-origination latency (cycles the HN-F waits before issuing a snoop).
  // Unused until M3; declared now so the coherent config shape is stable.
  int unsigned hnf_snoop_latency = 0;

  // Which leg of a WriteEvictOrEvict this home takes. The specification leaves
  // the choice to "its own heuristics", which is not something a test can
  // predict, so it is a knob rather than a draw -- both legs stay reachable, each
  // deterministically, and a test can assert the one it asked for.
  //
  //   1 (default) -> ask for the data: CompDBIDResp, answered with
  //                  CopyBackWrData, which is itself the implicit CompAck.
  //   0           -> decline it: a bare Comp, answered with an explicit CompAck.
  //                  The transaction degenerates into an Evict.
  bit hnf_write_evict_request_data = 1'b1;

  // Negative-control knob: when set, the HN-F grants coherent reads WITHOUT
  // snooping the other sharers -- deliberately breaking coherency so a second
  // requester can end up a duplicate Unique owner. tc_chi_coherency_negctl uses
  // this to prove Checker D's single-writer invariant is not vacuous. Default 0
  // keeps the home fully coherent.
  bit hnf_suppress_snoops = 1'b0;

  // Negative-control knob: when set, the HN-F drops (does not merge) the dirty
  // data a snoop forwards as SnpRespData, so it completes the requester from
  // stale memory instead of the forwarded data -- a coherent data-integrity
  // break. tc_chi_coherency_data_negctl uses this to prove Checker D's
  // data-integrity check is not vacuous. Default 0 keeps the home coherent.
  bit hnf_corrupt_dirty_merge = 1'b0;

  // Negative-control knob: when set, the RN-F takes its final cache state
  // VERBATIM from the granted Resp and overwrites its cached beats with the
  // fetched ones -- the pre-3.2 behaviour, before IHI 0050 E Table 4-14's
  // held-state half was implemented. A UD holder that issues ReadClean then
  // drops to SC and loses its modified bytes, so the next snoop of that line
  // answers without data and the only dirty copy in the system is gone.
  // tc_chi_coh_{d,e}_req_final_state_negctl uses this to prove catalogue rule D7
  // reports the loss. Default 0 keeps the RN-F conformant.
  bit rnf_req_final_state_verbatim = 1'b0;

  // Master enable for exclusive (LL/SC) monitor modeling on the HN-F. When 0 the
  // home ignores req.excl entirely (no monitor set, every completion NormalOkay),
  // so a bench that never uses exclusives is byte-unaffected. Default 1: the home
  // honors exclusive accesses whenever an RN-F sets req.excl.
  bit exclusives_enabled = 1'b1;

  // Negative-control knob: when set, the HN-F reports ExclOkay on EVERY exclusive
  // CleanUnique (SC) regardless of whether the per-(line,port) monitor was still
  // valid -- deliberately claiming an SC won across an intervening conflict.
  // tc_chi_coh_excl_negctl uses this to prove Checker D's exclusive invariant is
  // not vacuous. Default 0 keeps the home honest (SC-success only on a live monitor).
  bit hnf_force_excl_success = 1'b0;

  // Master enable for direct-cache-transfer (DCT / forwarding-snoop) origination
  // on the HN-F. When 0 the home never issues a Snp*Fwd -- coherent reads take the
  // ordinary snoop-then-CompData-from-memory path, so every existing test is
  // byte-identical. When 1, a coherent read that hits a peer holder is served by a
  // forwarding snoop: the snoopee drives CompData straight to the requester and a
  // reduced SnpRespFwded/SnpRespDataFwded to the home, which the home relays
  // without sourcing data from its own memory. Default 0.
  bit hnf_enable_snoop_fwd = 1'b0;

  // Negative-control knob for the DCT data-integrity check: when set, the HN-F
  // corrupts the forwarded data on the relay leg (mirrors hnf_corrupt_dirty_merge
  // for the non-fwd dirty path) so the requester's CompData no longer matches the
  // data the snoopee forwarded. tc_chi_coh_fwd_data_negctl uses this to prove
  // Checker D's forwarded-data integrity check is not vacuous. Default 0.
  bit hnf_corrupt_fwd_data = 1'b0;

  // Two-level memory hierarchy: when set, the HN-F stops self-terminating and
  // instead issues downstream ReadNoSnp / WriteNoSnpFull to a real SN-F node for
  // directory-miss reads and writebacks (RN-F <-> HN-F <-> SN-F). Default 0 keeps
  // the HN-F terminating against its own vip_mem, so every existing coherent test
  // is byte-identical. hnf_downstream_snf_id is the SrcID/TgtID stamped on the
  // downstream link (node IDs are 0 in this bench).
  bit          hnf_downstream_en     = 1'b0;
  int unsigned hnf_downstream_snf_id = 0;

  // Negative-control knobs for the downstream data-integrity check: corrupt the
  // data the HN-F relays from a downstream fetch (XOR-invert), or force the SN-F
  // fetch to be treated as a DECERR. tc_chi_coh_snf_data_negctl uses these to
  // prove the end-to-end integrity check is not vacuous. Default 0.
  bit hnf_downstream_corrupt_data = 1'b0;
  bit hnf_downstream_force_decerr = 1'b0;

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name = "vip_chi_cfg_agent");
    super.new(name);
    this.mem_cfg = vip_mem_config::type_id::create("mem_cfg");
  endfunction

  // ---------------------------------------------------------------------------
  // One delay window. An inverted min/max makes $urandom_range see a reversed
  // range, so the draw stops meaning what the knob names say.
  // ---------------------------------------------------------------------------
  protected function bit check_delay_window(
    input string chan,
    input int    delay_min,
    input int    delay_max,
    input bit    silent
  );
    check_delay_window = 1'b1;

    if (delay_min < 0) begin
      if (!silent) begin
        `uvm_error("VIP_CHI_CFG", $sformatf(
          "%s_valid_delay_min is %0d; a delay cannot be negative", chan, delay_min))
      end
      check_delay_window = 1'b0;
    end

    if (delay_min > delay_max) begin
      if (!silent) begin
        `uvm_error("VIP_CHI_CFG", $sformatf(
          "%s_valid_delay window is inverted: min %0d > max %0d",
          chan, delay_min, delay_max))
      end
      check_delay_window = 1'b0;
    end
  endfunction

  // ---------------------------------------------------------------------------
  // One channel's gaussian shaping knobs.
  //
  // Both rules exist because the alternative is silence. vip_gauss fatals on a
  // non-positive stddev, so catching it here turns a mid-run simulator abort
  // into a config error naming the channel. And a shape set on a channel whose
  // delay is switched off is the exact failure this feature was built to end:
  // configuration that reads as active and does nothing.
  // ---------------------------------------------------------------------------
  protected function bit check_delay_gauss(
    input string chan,
    input bit    delay_enabled,
    input bit    gauss_enabled,
    input real   stddev,
    input bit    silent
  );
    check_delay_gauss = 1'b1;

    if (!gauss_enabled) begin
      return check_delay_gauss;
    end

    if (stddev <= 0.0) begin
      if (!silent) begin
        `uvm_error("VIP_CHI_CFG", $sformatf(
          "%s_valid_delay_stddev is %0f; a gaussian spread must be greater than zero",
          chan, stddev))
      end
      check_delay_gauss = 1'b0;
    end

    if (!delay_enabled) begin
      if (!silent) begin
        `uvm_error("VIP_CHI_CFG", $sformatf(
          "%s_valid_delay_gauss_enabled is set while %s_valid_delay_enabled is not: the channel draws no delay at all, so the shape would never be used",
          chan, chan))
      end
      check_delay_gauss = 1'b0;
    end
  endfunction

  // ---------------------------------------------------------------------------
  // One channel delay draw, in cycles: how long the driver holds an assembled
  // flit before it asks for a credit and puts it on the wire.
  //
  // The distribution lives HERE, not in the drivers. A driver asks its channel
  // for a number of cycles and waits that many; it has no opinion about how the
  // number was produced. That is what lets the shape change without touching a
  // single driver.
  //
  // Disabled returns 0, which is the same wire behaviour as before these were
  // wired up at all.
  // ---------------------------------------------------------------------------
  // The shape is chosen here too: uniform across the window, or a truncated
  // gaussian drawn from a cached CDF.
  //
  // The CDF is (re)built whenever the knobs it was built from have moved, which
  // is a deliberate departure from the sibling agent's contract. There,
  // rebuild_gauss_cdfs() must be called by hand after any retune and a missed
  // call is a null dereference. Tests in this VIP retune mid-run as a matter of
  // course -- tc_chi_channel_delay changes the window three times in one run --
  // so a draw that silently used a stale CDF, or fataled on a fresh one, would
  // be a trap set for exactly the tests this feature exists for.
  protected function int unsigned draw_delay(
    input     bit       enabled,
    input     int       delay_min,
    input     int       delay_max,
    input     bit       gauss_enabled,
    input     int       mean,
    input     real      stddev,
    input     string    name,
    ref       vip_gauss g,
    ref       string    built
  );
    if (!enabled) begin
      return 0;
    end

    if (!gauss_enabled) begin
      return $urandom_range(delay_max, delay_min);
    end

    this.build_gauss_cdf(delay_min, delay_max, mean, stddev, name, g, built);

    return g.get_r_cdf_int();
  endfunction

  // ---------------------------------------------------------------------------
  // Allocate the channel's vip_gauss on first use and (re)build its CDF when the
  // knobs it was built from have moved. A no-op on the common path.
  // ---------------------------------------------------------------------------
  protected function void build_gauss_cdf(
    input     int       delay_min,
    input     int       delay_max,
    input     int       mean,
    input     real      stddev,
    input     string    name,
    ref       vip_gauss g,
    ref       string    built
  );
    string want;

    want = $sformatf("%0d:%0d:%0d:%f", delay_min, delay_max, mean, stddev);

    if ((g != null) && (built == want)) begin
      return;
    end

    if (g == null) begin
      g = vip_gauss::type_id::create(name);
    end

    g.gen_cdf(delay_min, delay_max, mean, stddev);
    built = want;
  endfunction

  function int unsigned draw_req_valid_delay();
    return this.draw_delay(this.req_valid_delay_enabled,
                           this.req_valid_delay_min, this.req_valid_delay_max,
                           this.req_valid_delay_gauss_enabled,
                           this.req_valid_delay_mean, this.req_valid_delay_stddev,
                           "g_req_valid_delay",
                           this.g_req_valid_delay, this.g_req_valid_delay_built);
  endfunction

  function int unsigned draw_rsp_valid_delay();
    return this.draw_delay(this.rsp_valid_delay_enabled,
                           this.rsp_valid_delay_min, this.rsp_valid_delay_max,
                           this.rsp_valid_delay_gauss_enabled,
                           this.rsp_valid_delay_mean, this.rsp_valid_delay_stddev,
                           "g_rsp_valid_delay",
                           this.g_rsp_valid_delay, this.g_rsp_valid_delay_built);
  endfunction

  function int unsigned draw_dat_valid_delay();
    return this.draw_delay(this.dat_valid_delay_enabled,
                           this.dat_valid_delay_min, this.dat_valid_delay_max,
                           this.dat_valid_delay_gauss_enabled,
                           this.dat_valid_delay_mean, this.dat_valid_delay_stddev,
                           "g_dat_valid_delay",
                           this.g_dat_valid_delay, this.g_dat_valid_delay_built);
  endfunction

  // ---------------------------------------------------------------------------
  // Build every gauss-enabled channel's CDF up front, so the first delayed flit
  // does not pay for it. The agent calls this from build_phase.
  //
  // Nothing DEPENDS on this having been called -- the draw builds on demand --
  // and it draws no random numbers, so calling it cannot shift the RNG stream
  // of a run that was not using gauss anyway.
  // ---------------------------------------------------------------------------
  function void rebuild_gauss_cdfs();

    if (this.req_valid_delay_gauss_enabled) begin
      this.build_gauss_cdf(this.req_valid_delay_min, this.req_valid_delay_max,
                           this.req_valid_delay_mean, this.req_valid_delay_stddev,
                           "g_req_valid_delay",
                           this.g_req_valid_delay, this.g_req_valid_delay_built);
    end

    if (this.rsp_valid_delay_gauss_enabled) begin
      this.build_gauss_cdf(this.rsp_valid_delay_min, this.rsp_valid_delay_max,
                           this.rsp_valid_delay_mean, this.rsp_valid_delay_stddev,
                           "g_rsp_valid_delay",
                           this.g_rsp_valid_delay, this.g_rsp_valid_delay_built);
    end

    if (this.dat_valid_delay_gauss_enabled) begin
      this.build_gauss_cdf(this.dat_valid_delay_min, this.dat_valid_delay_max,
                           this.dat_valid_delay_mean, this.dat_valid_delay_stddev,
                           "g_dat_valid_delay",
                           this.g_dat_valid_delay, this.g_dat_valid_delay_built);
    end
  endfunction

  // ---------------------------------------------------------------------------
  // TRUE when two inclusive address ranges share at least one address.
  // ---------------------------------------------------------------------------
  protected function bit ranges_overlap(
    input logic [VIP_CHI_MAX_ADDR_WIDTH_C-1:0] a_base,
    input logic [VIP_CHI_MAX_ADDR_WIDTH_C-1:0] a_limit,
    input logic [VIP_CHI_MAX_ADDR_WIDTH_C-1:0] b_base,
    input logic [VIP_CHI_MAX_ADDR_WIDTH_C-1:0] b_limit
  );
    return (a_base <= b_limit) && (b_base <= a_limit);
  endfunction

  // ---------------------------------------------------------------------------
  // is_valid -- runtime configuration self-check.
  //
  // vip_chi_agent::check_cfg_p() validates the ELABORATION parameters. This
  // validates the runtime object, which had no equivalent: an inconsistent
  // combination used to be discarded silently or to fail much later, deep inside
  // a driver, with a message that named the symptom rather than the cause.
  //
  // Reports EVERY problem it finds rather than stopping at the first, so one run
  // tells the user everything they need to change. Returns 1 when clean.
  //
  // `silent` suppresses the reports and returns the verdict only, so a test can
  // assert on validity without polluting its own error count.
  //
  // Two related rules live outside this function because they need information
  // the cfg object does not carry: `role` versus the agent's `ROLE_P`, and
  // max_outstanding_* versus the TxnID width, both checked in
  // vip_chi_agent::build_phase where CFG_P and ROLE_P are in scope.
  // ---------------------------------------------------------------------------
  function bit is_valid(input bit silent = 1'b1);

    is_valid = 1'b1;

    // ---- Outstanding / pipeline --------------------------------------------
    if (this.max_outstanding_read < 1) begin
      if (!silent) begin
        `uvm_error("VIP_CHI_CFG", $sformatf(
          "max_outstanding_read is %0d; must be >= 1 (1 = strictly serial reads)",
          this.max_outstanding_read))
      end
      is_valid = 1'b0;
    end

    if (this.max_outstanding_write < 1) begin
      if (!silent) begin
        `uvm_error("VIP_CHI_CFG", $sformatf(
          "max_outstanding_write is %0d; must be >= 1 (1 = strictly serial writes)",
          this.max_outstanding_write))
      end
      is_valid = 1'b0;
    end

    if (this.max_pcrd_budget < 0) begin
      if (!silent) begin
        `uvm_error("VIP_CHI_CFG", $sformatf(
          "max_pcrd_budget is %0d; use 0 to leave the P-credit bank unbounded",
          this.max_pcrd_budget))
      end
      is_valid = 1'b0;
    end

    // The overlap-path selectors do nothing on their own: the RN-I only leaves
    // the serial issue path when multi_outstanding is set, so setting one of
    // these alone discards the user's intent without a word.
    if (this.multi_outstanding_write && !this.multi_outstanding) begin
      if (!silent) begin
        `uvm_error("VIP_CHI_CFG",
          "multi_outstanding_write is set without multi_outstanding: the write overlap path never engages")
      end
      is_valid = 1'b0;
    end

    if (this.multi_outstanding_mixed && !this.multi_outstanding) begin
      if (!silent) begin
        `uvm_error("VIP_CHI_CFG",
          "multi_outstanding_mixed is set without multi_outstanding: the mixed overlap loop never engages")
      end
      is_valid = 1'b0;
    end

    // ---- Link credits -------------------------------------------------------
    // The initial grant is advertised on the wire and then accumulates against
    // the local cap; a grant larger than its own cap can never be fully banked.
    if (this.initial_req_credits > this.req_send_credit_cap) begin
      if (!silent) begin
        `uvm_error("VIP_CHI_CFG", $sformatf(
          "initial_req_credits (%0d) exceeds req_send_credit_cap (%0d)",
          this.initial_req_credits, this.req_send_credit_cap))
      end
      is_valid = 1'b0;
    end

    if (this.initial_rsp_credits > this.rsp_send_credit_cap) begin
      if (!silent) begin
        `uvm_error("VIP_CHI_CFG", $sformatf(
          "initial_rsp_credits (%0d) exceeds rsp_send_credit_cap (%0d)",
          this.initial_rsp_credits, this.rsp_send_credit_cap))
      end
      is_valid = 1'b0;
    end

    if (this.initial_dat_credits > this.dat_send_credit_cap) begin
      if (!silent) begin
        `uvm_error("VIP_CHI_CFG", $sformatf(
          "initial_dat_credits (%0d) exceeds dat_send_credit_cap (%0d)",
          this.initial_dat_credits, this.dat_send_credit_cap))
      end
      is_valid = 1'b0;
    end

    if (this.initial_snp_credits > this.snp_send_credit_cap) begin
      if (!silent) begin
        `uvm_error("VIP_CHI_CFG", $sformatf(
          "initial_snp_credits (%0d) exceeds snp_send_credit_cap (%0d)",
          this.initial_snp_credits, this.snp_send_credit_cap))
      end
      is_valid = 1'b0;
    end

    // ---- Completer policy ---------------------------------------------------
    if (this.force_retry_count < 0) begin
      if (!silent) begin
        `uvm_error("VIP_CHI_CFG", $sformatf(
          "force_retry_count is %0d; use 0 to never bounce a retryable request",
          this.force_retry_count))
      end
      is_valid = 1'b0;
    end

    if (this.compack_timeout_cycles < 0) begin
      if (!silent) begin
        `uvm_error("VIP_CHI_CFG", $sformatf(
          "compack_timeout_cycles is %0d; must not be negative",
          this.compack_timeout_cycles))
      end
      is_valid = 1'b0;
    end

    // An address in both windows has two contradictory fates: DECERR completes
    // the request with a non-data error, DERR returns data marked corrupt. The
    // completer checks DECERR first, so the DERR entry is silently unreachable.
    foreach (this.decerr_ranges[i]) begin
      if (this.decerr_ranges[i].base > this.decerr_ranges[i].limit) begin
        if (!silent) begin
          `uvm_error("VIP_CHI_CFG", $sformatf(
            "decerr_ranges[%0d] is inverted: base 0x%0h > limit 0x%0h",
            i, this.decerr_ranges[i].base, this.decerr_ranges[i].limit))
        end
        is_valid = 1'b0;
      end
    end

    foreach (this.derr_ranges[i]) begin
      if (this.derr_ranges[i].base > this.derr_ranges[i].limit) begin
        if (!silent) begin
          `uvm_error("VIP_CHI_CFG", $sformatf(
            "derr_ranges[%0d] is inverted: base 0x%0h > limit 0x%0h",
            i, this.derr_ranges[i].base, this.derr_ranges[i].limit))
        end
        is_valid = 1'b0;
      end
    end

    foreach (this.decerr_ranges[i]) begin
      foreach (this.derr_ranges[j]) begin
        if (this.ranges_overlap(this.decerr_ranges[i].base, this.decerr_ranges[i].limit,
                                this.derr_ranges[j].base,   this.derr_ranges[j].limit)) begin
          if (!silent) begin
            `uvm_error("VIP_CHI_CFG", $sformatf(
              "decerr_ranges[%0d] (0x%0h..0x%0h) overlaps derr_ranges[%0d] (0x%0h..0x%0h): DECERR wins, so the DERR window is unreachable there",
              i, this.decerr_ranges[i].base, this.decerr_ranges[i].limit,
              j, this.derr_ranges[j].base,   this.derr_ranges[j].limit))
          end
          is_valid = 1'b0;
        end
      end
    end

    // ---- Coherent -----------------------------------------------------------
    if (this.rnf_cache_max_lines < 0) begin
      if (!silent) begin
        `uvm_error("VIP_CHI_CFG", $sformatf(
          "rnf_cache_max_lines is %0d; use 0 for an unbounded cache",
          this.rnf_cache_max_lines))
      end
      is_valid = 1'b0;
    end

    // A bounded cache evicts CLEAN victims silently and has no writeback path
    // for a dirty one, so a single-line bound fatals in the driver as soon as
    // the workload dirties a second line. Warn rather than reject: it is a legal
    // setting for a workload that never does.
    if ((this.rnf_cache_max_lines > 0) && (this.rnf_cache_max_lines < 2)) begin
      if (!silent) begin
        `uvm_warning("VIP_CHI_CFG", $sformatf(
          "rnf_cache_max_lines is %0d: writeback-on-eviction of a DIRTY victim is not modeled, so a workload that dirties more lines than this will fatal in the RN-F driver",
          this.rnf_cache_max_lines))
      end
    end

    // The negative-control knobs deliberately break coherency. Leaving one set
    // outside its own negative-control test turns a real failure into a
    // mystifying one, so say so -- but do not reject: the negative-control tests
    // are exactly the legitimate users.
    if (this.hnf_suppress_snoops || this.hnf_corrupt_dirty_merge ||
        this.rnf_req_final_state_verbatim ||
        this.hnf_force_excl_success || this.hnf_corrupt_fwd_data ||
        this.hnf_downstream_corrupt_data || this.hnf_downstream_force_decerr ||
        this.snf_duplicate_dat_beat || this.snf_reorder_ordered_service ||
        this.snf_corrupt_tag ||
        this.lasm_abort_activation || this.flit_without_flitpend ||
        this.lasm_reactivate_during_deactivate) begin
      if (!silent) begin
        `uvm_warning("VIP_CHI_CFG", $sformatf(
          "a negative-control knob is set (suppress_snoops=%0b corrupt_dirty_merge=%0b force_excl_success=%0b corrupt_fwd_data=%0b downstream_corrupt_data=%0b downstream_force_decerr=%0b snf_duplicate_dat_beat=%0b snf_reorder_ordered_service=%0b lasm_abort_activation=%0b): this deliberately breaks the invariant a checker guards",
          this.hnf_suppress_snoops, this.hnf_corrupt_dirty_merge,
          this.hnf_force_excl_success, this.hnf_corrupt_fwd_data,
          this.hnf_downstream_corrupt_data, this.hnf_downstream_force_decerr,
          this.snf_duplicate_dat_beat, this.snf_reorder_ordered_service,
          this.lasm_abort_activation))
      end
    end

    // The abort is driven by activate_link, which only the requester roles run;
    // on a completer the knob would set a flag nothing reads and the negative
    // control would silently pass with the check never having fired.
    if (this.lasm_abort_activation &&
        (this.role != VIP_CHI_ROLE_RNI_E) && (this.role != VIP_CHI_ROLE_RNF_E)) begin
      if (!silent) begin
        `uvm_error("VIP_CHI_CFG",
          "lasm_abort_activation is set on a role that does not originate link activation: only a requester raises txlinkactivereq, so there is no activation to abort")
      end
      is_valid = 1'b0;
    end

    // Same reasoning as the abort above, and the same failure if it is ignored:
    // deactivation is driven by whoever raised the request in the first place.
    // The requester pulses REQ+RSP FLITPEND; the home pulses SNP FLITPEND. Both
    // run the control, and between them they cover all three rules. Any other
    // role would set a flag nothing reads.
    // Implemented in the RN-I announce path, which RN-F inherits. On any other
    // role it would set a flag nothing reads.
    if (this.flit_without_flitpend &&
        (this.role != VIP_CHI_ROLE_RNI_E) && (this.role != VIP_CHI_ROLE_RNF_E)) begin
      if (!silent) begin
        `uvm_error("VIP_CHI_CFG",
          "flit_without_flitpend is set on a role whose driver does not run the control: the announcement it suppresses lives in the RN-I send path, which only the requester roles use")
      end
      is_valid = 1'b0;
    end

    if (this.flitpend_without_valid &&
        (this.role != VIP_CHI_ROLE_RNI_E) && (this.role != VIP_CHI_ROLE_RNF_E) &&
        (this.role != VIP_CHI_ROLE_HNF_E)) begin
      if (!silent) begin
        `uvm_error("VIP_CHI_CFG",
          "flitpend_without_valid is set on a role whose driver does not run the pulse: the requester emits it on REQ/RSP and the home on SNP, so on any other role it would set a flag nothing reads")
      end
      is_valid = 1'b0;
    end

    // Same reasoning as the abort and the deactivation request: it is the
    // requester that drives txlinkactivereq, so on any other role this would set
    // a flag nothing reads.
    if (this.lasm_reactivate_during_deactivate &&
        (this.role != VIP_CHI_ROLE_RNI_E) && (this.role != VIP_CHI_ROLE_RNF_E)) begin
      if (!silent) begin
        `uvm_error("VIP_CHI_CFG",
          "lasm_reactivate_during_deactivate is set on a role that does not originate link activation")
      end
      is_valid = 1'b0;
    end

    if (this.link_deactivate_request &&
        (this.role != VIP_CHI_ROLE_RNI_E) && (this.role != VIP_CHI_ROLE_RNF_E)) begin
      if (!silent) begin
        `uvm_error("VIP_CHI_CFG",
          "link_deactivate_request is set on a role that does not originate link activation: only a requester drives txlinkactivereq, so there is no request to withdraw")
      end
      is_valid = 1'b0;
    end

    // The mirror image: the stall knobs delay an acknowledge, and only a
    // completer drives one. On a requester they would set a flag nothing reads.
    if (((this.lasm_stall_activation_cycles != 0) ||
         (this.lasm_stall_deactivation_cycles != 0)) &&
        (this.role != VIP_CHI_ROLE_SNF_E) && (this.role != VIP_CHI_ROLE_HNF_E) &&
        (this.role != VIP_CHI_ROLE_HNI_E)) begin
      if (!silent) begin
        `uvm_error("VIP_CHI_CFG",
          "a lasm_stall_*_cycles knob is set on a role that does not drive txlinkactiveack: only a completer acknowledges, so there is no acknowledge to delay")
      end
      is_valid = 1'b0;
    end

    // The reorder knob only has anything to reorder when the SN-F buffers
    // requests; on the serial loop each REQ is serviced to completion before the
    // next is even sampled, so the negative control would silently do nothing.
    if (this.snf_reorder_ordered_service && !this.multi_outstanding) begin
      if (!silent) begin
        `uvm_error("VIP_CHI_CFG",
          "snf_reorder_ordered_service is set without multi_outstanding: the serial SN-F loop never holds two requests at once, so nothing is reordered")
      end
      is_valid = 1'b0;
    end

    // Zero is not "no interleaving", it is a depth no scheduler can honour --
    // the emitter would have no stream to take a beat from. Reject it rather
    // than quietly reading it as 1.
    if (this.dat_interleave_depth == 0) begin
      if (!silent) begin
        `uvm_error("VIP_CHI_CFG",
          "dat_interleave_depth is 0: the minimum is 1, which is one transfer at a time (no interleaving)")
      end
      is_valid = 1'b0;
    end

    // Same reasoning as snf_reorder_ordered_service above: the serial loop
    // services one REQ to completion before sampling the next, so there is never
    // a second beat stream and the knob would be inert.
    if ((this.dat_interleave_depth > 1) && !this.multi_outstanding) begin
      if (!silent) begin
        `uvm_error("VIP_CHI_CFG",
          "dat_interleave_depth > 1 without multi_outstanding: the serial SN-F loop never holds two reads at once, so no beats are ever interleaved")
      end
      is_valid = 1'b0;
    end

    if (this.hnf_downstream_en && this.hnf_suppress_snoops) begin
      if (!silent) begin
        `uvm_warning("VIP_CHI_CFG",
          "hnf_downstream_en with hnf_suppress_snoops: the two-level hierarchy runs against a home that is deliberately incoherent")
      end
    end

    // ---- Delays -------------------------------------------------------------
    is_valid &= this.check_delay_window("link_act", this.link_act_delay_min,
                                        this.link_act_delay_max, silent);
    is_valid &= this.check_delay_window("req", this.req_valid_delay_min,
                                        this.req_valid_delay_max, silent);
    is_valid &= this.check_delay_window("rsp", this.rsp_valid_delay_min,
                                        this.rsp_valid_delay_max, silent);
    is_valid &= this.check_delay_window("dat", this.dat_valid_delay_min,
                                        this.dat_valid_delay_max, silent);

    is_valid &= this.check_delay_gauss("req", this.req_valid_delay_enabled,
                                       this.req_valid_delay_gauss_enabled,
                                       this.req_valid_delay_stddev, silent);
    is_valid &= this.check_delay_gauss("rsp", this.rsp_valid_delay_enabled,
                                       this.rsp_valid_delay_gauss_enabled,
                                       this.rsp_valid_delay_stddev, silent);
    is_valid &= this.check_delay_gauss("dat", this.dat_valid_delay_enabled,
                                       this.dat_valid_delay_gauss_enabled,
                                       this.dat_valid_delay_stddev, silent);
  endfunction

endclass

`endif