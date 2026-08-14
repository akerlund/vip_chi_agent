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

`ifndef VIP_CHI_SVA
`define VIP_CHI_SVA

module vip_chi_sva #(
  parameter vip_chi_cfg_t  CFG_P        = VIP_CHI_DEFAULT_CFG_C,
  parameter type           FLIT_TYPES_T = vip_chi_types #(CFG_P),
  parameter vip_chi_role_t ROLE_P       = VIP_CHI_ROLE_MONITOR_E,
  parameter int            TIMEOUT_CYCLES_P = 1024,
  parameter bit            ENABLE_COMPLETION_TIMEOUT_P = 1'b1,
  // Cycles allowed after reset release for the link to begin re-activating.
  // Must comfortably exceed cfg_agent.link_act_delay_max (default 4) plus the
  // req->ack handshake, or p_link_restarts_after_reset_release false-fails.
  parameter int            LINK_ACT_WINDOW_P = 32
  )(
    vip_chi_if vif,
    input bit  checks_enable,
    // The DAT beats of one transfer may legally arrive in any order -- DataID
    // carries the position, not arrival. This VIP's own drivers always emit them
    // in order, so the DataID-ordering checks below hold that convention by
    // default and catch a driver regression. Drive this high on a link whose
    // completer deliberately reorders beats: the ordering checks stand down,
    // everything else (beat counts, TxnID stability, credits) keeps checking.
    input bit  dat_reorder_allowed,
    // Cycles a sender may keep TXSACTIVE asserted past the close of its
    // outstanding window (cfg_agent.txsactive_extend_max_cycles). An input
    // rather than a parameter, like dat_reorder_allowed above and for the same
    // reason: a testcase sets the knob at run time, and elaboration is over by
    // then.
    input int  txsactive_extend_max_cycles,
    // Suppress the link-activation transition $error while still COUNTING it,
    // for the negative-control test that deliberately aborts a bring-up. An SVA
    // $error cannot be demoted by a uvm_report_catcher the way a UVM report can,
    // so a test that must prove the rule fired would otherwise have to print an
    // error indistinguishable from a real one. Standing the check down entirely
    // -- what a reordering test does to the DataID rules -- is not an option
    // here: the whole point is to observe that it fired.
    input bit  lasm_illegal_expected
  );

  typedef vip_chi_types #(CFG_P)::txn_id_t     txn_id_t;
  typedef vip_chi_types #(CFG_P)::data_id_t    data_id_t;
  typedef vip_chi_types #(CFG_P)::req_opcode_t req_opcode_t;
  typedef vip_chi_types #(CFG_P)::rsp_opcode_t rsp_opcode_t;
  typedef vip_chi_types #(CFG_P)::dat_opcode_t dat_opcode_t;
  typedef vip_chi_types #(CFG_P)::size_t       size_t;

  localparam int TXN_ID_COUNT_C = 2 ** $bits(txn_id_t);
  localparam int unsigned REQ_SEND_CAP_C = 64;
  localparam int unsigned RSP_SEND_CAP_C = 64;
  localparam int unsigned DAT_SEND_CAP_C = 64;
  localparam bit ROLE_IS_REQUESTER_C =
    (ROLE_P == VIP_CHI_ROLE_RNI_E) || (ROLE_P == VIP_CHI_ROLE_RNF_E);
  localparam bit ROLE_IS_COMPLETER_C =
    (ROLE_P == VIP_CHI_ROLE_SNF_E) || (ROLE_P == VIP_CHI_ROLE_HNF_E);

  // Idle cycles a sender may keep TXSACTIVE up past the close of its
  // outstanding window before p_txsactive_deassert_bounded calls it stuck.
  // Deliberately loose: a checker watching the wire cannot see the moment the
  // SENDER considers a transaction retired, only the moment its last flit went
  // by, so the bound has to clear that gap. It is a stuck-signal check, not a
  // latency measurement -- TXSACTIVE_EXTEND_MAX_CYCLES_P is what a test
  // tightens or extends.
  localparam int TXSACTIVE_SETTLE_CYCLES_C = 16;

  // The Link Activation State Machine of THIS LINK, as seen from this endpoint.
  //
  // One state machine per link, not one per direction. chi_link_adapter mirrors
  // both sideband signals to both endpoints -- the requester-polarity endpoint
  // drives LINKACTIVEREQ and the completer-polarity one drives LINKACTIVEACK,
  // and each is copied to the other side -- so a link carries a single
  // activation handshake that both endpoints observe, not two independently
  // activated directions. Modelling it as two would leave one of them wired to a
  // request nobody ever raises (an SN-F never asserts txlinkactivereq; it only
  // mirrors the peer's request onto txlinkactiveack), permanently in STOP, and
  // every flit the peer sent across it would look like a violation.
  //
  // Which of the two request signals is live depends on this endpoint's
  // polarity, and polarity is not a function of ROLE_P alone -- an HN-I port
  // takes either, depending on which side it faces. The OR is exact rather than
  // a heuristic: at any endpoint the signal of each pair that is not the live
  // one is identically zero, so req_either is the link's request and ack_either
  // its acknowledge, whichever end this bind sits on:
  //   RN-I RUN => txlinkactivereq & rxlinkactiveack
  //   SN-F RUN => rxlinkactivereq & txlinkactiveack
  // and both reduce to {req_either, ack_either} == RUN.
  function automatic vip_chi_lasm_state_t link_lasm();
    return vip_chi_lasm((vif.txlinkactivereq || vif.rxlinkactivereq),
                        (vif.txlinkactiveack || vif.rxlinkactiveack));
  endfunction

  // Anywhere but STOP (ACTIVATE / RUN / DEACTIVATE). The correct gate for the
  // L-CREDIT properties: L-credits legitimately flow from ACTIVATE onward, not
  // just in RUN, so credit returns must be allowed as soon as the link leaves
  // STOP. That is how the initial pool reaches the peer before the link is RUN
  // at all. Flit sends are gated more tightly, on RUN itself.
  //
  // Kept as a combinational predicate rather than read off the registered state
  // because two properties need the answer for a cycle other than the current
  // one. It is exactly (link_lasm() != STOP), and the earlier hand-written
  // OR-of-four form it replaced was the same expression.
  function automatic bit link_is_active();
    return (link_lasm() != VIP_CHI_LASM_STOP_E);
  endfunction

  // The registered LASM, one cycle behind link_lasm(). Advanced OUTSIDE the
  // checks_enable gate, deliberately: that gate is this interface's own link
  // activity, so gating the state machine on it would blind exactly the half of
  // the cycle where the link comes down -- in DEACTIVATE and STOP the gate is
  // low, and RUN -> DEACTIVATE -> STOP could never be judged. It also has to
  // advance across the gap regardless, or the state would be stale the moment
  // the link came back and the first transition after every deactivation would
  // be measured from the wrong place.
  //
  // lasm_dwell counts cycles held in the current state. Nothing in M2.4 reads it
  // -- it exists because a state machine that cannot say HOW LONG it has been
  // stuck can only report a wrong transition, never a missing one.
  vip_chi_lasm_state_t lasm_state;
  int unsigned         lasm_dwell;

  always_ff @(posedge vif.clk) begin
    if (!vif.rst_n) begin
      // Out of reset the sideband is held idle, which the reset-idle rule
      // already requires, so STOP is the state the link genuinely restarts in.
      lasm_state <= VIP_CHI_LASM_STOP_E;
      lasm_dwell <= 0;
    end
    else begin
      lasm_state <= link_lasm();
      lasm_dwell <= (link_lasm() == lasm_state) ? (lasm_dwell + 1) : 0;
    end
  end

  // LASM coverage lives here rather than in vip_chi_coverage, and the reason is
  // structural: that component is a pure analysis-port subscriber with no
  // interface handle at all. Link state is a wire property, so carrying it there
  // would mean plumbing a virtual interface into a component deliberately built
  // without one, and routing a per-cycle signal through an analysis port to get
  // it there. Sampling beside the state machine keeps the two in step by
  // construction.
  covergroup cg_lasm;
    option.per_instance = 1;

    cp_state: coverpoint lasm_state {
      bins stop       = {VIP_CHI_LASM_STOP_E};
      bins activate   = {VIP_CHI_LASM_ACTIVATE_E};
      bins run        = {VIP_CHI_LASM_RUN_E};
      bins deactivate = {VIP_CHI_LASM_DEACTIVATE_E};
    }

    // The legal cycle as transition bins. An ILLEGAL step deliberately lands in
    // no bin -- reporting it is the assertion's job, and giving it a bin would
    // let a regression "cover" a violation. What this records is which parts of
    // the cycle the traffic actually walked: a link that comes up and never goes
    // down covers two of the four edges, and the report is what says so.
    cp_transition: coverpoint lasm_state {
      bins bring_up  = (VIP_CHI_LASM_STOP_E       => VIP_CHI_LASM_ACTIVATE_E);
      bins running   = (VIP_CHI_LASM_ACTIVATE_E   => VIP_CHI_LASM_RUN_E);
      bins tear_down = (VIP_CHI_LASM_RUN_E        => VIP_CHI_LASM_DEACTIVATE_E);
      bins stopped   = (VIP_CHI_LASM_DEACTIVATE_E => VIP_CHI_LASM_STOP_E);
    }
  endgroup

  cg_lasm cov_lasm;

  initial begin
    cov_lasm = new();
  end

  // Sampled only out of reset, so a reset gap breaks the transition chain rather
  // than manufacturing an edge across it.
  always_ff @(posedge vif.clk) begin
    if (vif.rst_n) begin
      cov_lasm.sample();
    end
  end

  function automatic bit req_opcode_is_coherent_read(input req_opcode_t opcode);
    return ((opcode == req_opcode_t'(VIP_CHI_REQ_READ_SHARED_C)) ||
            (opcode == req_opcode_t'(VIP_CHI_REQ_READ_CLEAN_C)) ||
            (opcode == req_opcode_t'(VIP_CHI_REQ_READ_UNIQUE_C)) ||
            (opcode == req_opcode_t'(VIP_CHI_REQ_MAKE_READ_UNIQUE_C)) ||
            (opcode == req_opcode_t'(VIP_CHI_REQ_READ_ONCE_C)));
  endfunction

  function automatic bit req_opcode_is_coherent_write_data(input req_opcode_t opcode);
    return ((opcode == req_opcode_t'(VIP_CHI_REQ_WRITE_BACK_FULL_C)) ||
            (opcode == req_opcode_t'(VIP_CHI_REQ_WRITE_CLEAN_FULL_C)) ||
            (opcode == req_opcode_t'(VIP_CHI_REQ_WRITE_UNIQUE_FULL_C)) ||
            (opcode == req_opcode_t'(VIP_CHI_REQ_WRITE_UNIQUE_PTL_C)));
  endfunction

  function automatic bit req_opcode_is_coherent_rsp_only(input req_opcode_t opcode);
    return ((opcode == req_opcode_t'(VIP_CHI_REQ_EVICT_C)) ||
            (opcode == req_opcode_t'(VIP_CHI_REQ_CLEAN_INVALID_C)) ||
            (opcode == req_opcode_t'(VIP_CHI_REQ_MAKE_INVALID_C)) ||
            (opcode == req_opcode_t'(VIP_CHI_REQ_CLEAN_UNIQUE_C)) ||
            // MakeUnique completes on an RSP-only Comp (no data), like CleanUnique.
            (opcode == req_opcode_t'(VIP_CHI_REQ_MAKE_UNIQUE_C)));
  endfunction

  // Compose an L-credit count update for one channel in a single next-value so
  // a same-cycle grant and consume no longer race on the NBA (previously the
  // grant and consume were two separate NBAs to the same counter and the consume
  // silently overwrote the grant). Overflow past the tracked cap is flagged, and
  // underflow (a flit consuming a credit at count 0) is flagged as well -- see M4.
  //
  // M4 -- credit-underflow (fixed 2026-07-14). This counter is an exact shadow of
  // the driver-side vip_chi_lcrd_mgr for one send-credit pool: it starts at 0 on
  // reset, +1 on every peer LCRDV grant, -1 on every flit the local endpoint
  // launches. It therefore captures the initial credit pool automatically, because
  // that pool arrives as real LCRDV pulses on the wire once the link activates --
  // no separate activation-aware seeding is needed. The two earlier M4 attempts
  // false-fired at bring-up because they were built on a mispaired counter: the
  // grant/consume pair below feeds each pool the LCRDV that actually authorizes
  // the flit it counts (see the always_ff pairing) -- a tx<chan>flitv send is
  // credited by the inbound rx<chan>lcrdv, not the outbound tx<chan>lcrdv (which
  // credits the peer's rx<chan>flitv). With the pairing corrected the counter can
  // never legitimately reach 0-and-consume: the driver's try_acquire_credit()
  // refuses to send at 0, so a fired underflow is always a real violation (a flit
  // driven with no credit). The grant-before-consume order here keeps a same-cycle
  // grant+consume safe (0 -> 1 -> 0), matching the NBA fix.
  function automatic int unsigned lcrd_next(
    input int unsigned cur,
    input bit          grant,
    input bit          consume,
    input int unsigned cap,
    input string       chan
  );
    int unsigned nxt;
    nxt = cur;
    if (grant) begin
      if (cur == cap) begin
        $error("vip_chi_sva: %s L-credit grant overflowed the tracked count", chan);
      end
      else begin
        nxt = nxt + 1;
      end
    end
    if (consume) begin
      if (nxt == 0) begin
        $error("vip_chi_sva: %s L-credit consumed with no credit available (underflow)", chan);
      end
      else begin
        nxt = nxt - 1;
      end
    end
    return nxt;
  endfunction

  function automatic int unsigned txn_id_to_index(input txn_id_t txn_id);
    return txn_id;
  endfunction

  function automatic bit req_has_modeled_completion(input req_opcode_t opcode);
    case (opcode)
      req_opcode_t'(VIP_CHI_REQ_READ_NO_SNP_C),
      req_opcode_t'(VIP_CHI_REQ_READ_NO_SNP_SEP_C),
      req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_PTL_C),
      req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_FULL_C),
      req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_ZERO_C),
      req_opcode_t'(VIP_CHI_REQ_CLEAN_SHARED_PERSIST_C),
      req_opcode_t'(VIP_CHI_REQ_CLEAN_SHARED_PERSIST_SEP_C): begin
        return 1'b1;
      end
      default: begin
        return req_opcode_is_coherent_read(opcode) ||
               req_opcode_is_coherent_write_data(opcode) ||
               req_opcode_is_coherent_rsp_only(opcode) ||
               vip_chi_types_pkg::vip_chi_req_opcode_is_atomic(
                 vip_chi_req_opcode_t'(opcode));
      end
    endcase
  endfunction

  function automatic bit req_completion_uses_dat(input req_opcode_t opcode);
    return ((opcode == req_opcode_t'(VIP_CHI_REQ_READ_NO_SNP_C)) ||
            (opcode == req_opcode_t'(VIP_CHI_REQ_READ_NO_SNP_SEP_C)) ||
            req_opcode_is_coherent_read(opcode) ||
            vip_chi_types_pkg::vip_chi_req_opcode_is_atomic_returning_data(
              vip_chi_req_opcode_t'(opcode)));
  endfunction

  function automatic bit is_final_rsp_completion(
    input req_opcode_t opcode,
    input rsp_opcode_t rsp_opcode
  );
    if (req_completion_uses_dat(opcode)) begin
      return 1'b0;
    end

    if (opcode == req_opcode_t'(VIP_CHI_REQ_CLEAN_SHARED_PERSIST_SEP_C)) begin
      return (rsp_opcode == rsp_opcode_t'(VIP_CHI_RSP_COMP_PERSIST_C));
    end

    return ((rsp_opcode == rsp_opcode_t'(VIP_CHI_RSP_COMP_C)) ||
            (rsp_opcode == rsp_opcode_t'(VIP_CHI_RSP_COMP_DBID_RESP_C)));
  endfunction

  function automatic txn_id_t completion_txn_for_req(
    input req_opcode_t opcode,
    input txn_id_t     req_txn_id,
    input txn_id_t     return_txn_id
  );
    if (opcode == req_opcode_t'(VIP_CHI_REQ_READ_NO_SNP_SEP_C)) begin
      return return_txn_id;
    end

    return req_txn_id;
  endfunction

  function automatic bit rni_final_completion_observed(
    input req_opcode_t opcode,
    input txn_id_t     req_txn_id,
    input txn_id_t     completion_txn_id
  );
    if (req_completion_uses_dat(opcode)) begin
      return (vif.rxdatflitv && !vif.rxdatflitpend &&
              (txn_id_t'(vif.rxdatflit.txnid) == completion_txn_id) &&
              (dat_opcode_t'(vif.rxdatflit.opcode) == expected_completion_dat_opcode(opcode)));
    end

    return (vif.rxrspflitv &&
            (txn_id_t'(vif.rxrspflit.txnid) == req_txn_id) &&
            is_final_rsp_completion(opcode, rsp_opcode_t'(vif.rxrspflit.opcode)));
  endfunction

  function automatic bit snf_final_completion_observed(
    input req_opcode_t opcode,
    input txn_id_t     req_txn_id,
    input txn_id_t     completion_txn_id
  );
    if (req_completion_uses_dat(opcode)) begin
      return (vif.txdatflitv && !vif.txdatflitpend &&
              (txn_id_t'(vif.txdatflit.txnid) == completion_txn_id) &&
              (dat_opcode_t'(vif.txdatflit.opcode) == expected_completion_dat_opcode(opcode)));
    end

    return (vif.txrspflitv &&
            (txn_id_t'(vif.txrspflit.txnid) == req_txn_id) &&
            is_final_rsp_completion(opcode, rsp_opcode_t'(vif.txrspflit.opcode)));
  endfunction

  function automatic bit is_write_req_opcode(input req_opcode_t opcode);
    return ((opcode == req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_PTL_C)) ||
            (opcode == req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_FULL_C)) ||
            (opcode == req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_ZERO_C)) ||
            req_opcode_is_coherent_write_data(opcode) ||
            vip_chi_types_pkg::vip_chi_req_opcode_is_atomic(
              vip_chi_req_opcode_t'(opcode)));
  endfunction

  function automatic bit is_write_dat_opcode(input dat_opcode_t opcode);
    return ((opcode == dat_opcode_t'(VIP_CHI_DAT_NON_COPY_BACK_WR_DATA_C)) ||
            (opcode == dat_opcode_t'(VIP_CHI_DAT_NCB_WR_DATA_COMP_ACK_C)) ||
            (opcode == dat_opcode_t'(VIP_CHI_DAT_COPY_BACK_WR_DATA_C)));
  endfunction

  function automatic int unsigned req_write_payload_beats(
    input req_opcode_t opcode,
    input size_t       size
  );
    // AtomicCompare Size is the COMBINED compare+swap size (IHI 0050): the write
    // payload spans the whole 2^Size operand region in one contiguous run. [P2]
    if (vip_chi_types_pkg::vip_chi_req_opcode_is_atomic_compare(
          vip_chi_req_opcode_t'(opcode))) begin
      return vip_chi_types_pkg::chi_xfer_dat_beats(size, CFG_P.DATA_BYTES_P);
    end

    if (vip_chi_types_pkg::vip_chi_req_opcode_is_atomic(
          vip_chi_req_opcode_t'(opcode)) ||
        (opcode == req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_PTL_C)) ||
        (opcode == req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_FULL_C)) ||
        req_opcode_is_coherent_write_data(opcode)) begin
      return vip_chi_types_pkg::chi_xfer_dat_beats(size, CFG_P.DATA_BYTES_P);
    end

    return 0;
  endfunction

  function automatic int unsigned req_completion_payload_beats(
    input req_opcode_t opcode,
    input size_t       size
  );
    // AtomicCompare Size is the COMBINED compare+swap size (IHI 0050), but its
    // CompData returns only the pre-op value of the compared location -- one
    // operand = the granule = half of the 2^Size operand span. [P2]
    if (vip_chi_types_pkg::vip_chi_req_opcode_is_atomic_compare(
          vip_chi_req_opcode_t'(opcode))) begin
      return vip_chi_types_pkg::chi_xfer_dat_beats(size, CFG_P.DATA_BYTES_P) / 2;
    end

    if ((opcode == req_opcode_t'(VIP_CHI_REQ_READ_NO_SNP_C)) ||
        (opcode == req_opcode_t'(VIP_CHI_REQ_READ_NO_SNP_SEP_C)) ||
        req_opcode_is_coherent_read(opcode) ||
        vip_chi_types_pkg::vip_chi_req_opcode_is_atomic_returning_data(
          vip_chi_req_opcode_t'(opcode))) begin
      return vip_chi_types_pkg::chi_xfer_dat_beats(size, CFG_P.DATA_BYTES_P);
    end

    return 0;
  endfunction

  function automatic dat_opcode_t expected_completion_dat_opcode(
    input req_opcode_t opcode
  );
    if (opcode == req_opcode_t'(VIP_CHI_REQ_READ_NO_SNP_SEP_C)) begin
      return dat_opcode_t'(VIP_CHI_DAT_DATA_SEP_RESP_C);
    end

    return dat_opcode_t'(VIP_CHI_DAT_COMP_DATA_C);
  endfunction

  bit req_exp_comp_ack_by_txn[TXN_ID_COUNT_C];
  bit write_completion_seen_by_txn[TXN_ID_COUNT_C];
  bit write_grant_seen_by_dbid[TXN_ID_COUNT_C];
  int unsigned expected_write_beats_by_txn[TXN_ID_COUNT_C];
  int unsigned expected_write_beats_by_dbid[TXN_ID_COUNT_C];
  bit expected_write_valid_by_dbid[TXN_ID_COUNT_C];
  int unsigned expected_completion_beats_by_txn[TXN_ID_COUNT_C];
  dat_opcode_t  expected_completion_opcode_by_txn[TXN_ID_COUNT_C];
  bit expected_completion_valid_by_txn[TXN_ID_COUNT_C];
  bit txdat_burst_active;
  txn_id_t txdat_burst_txn_id;
  data_id_t txdat_expected_data_id;
  int unsigned txdat_burst_count;
  dat_opcode_t txdat_burst_opcode;
  bit rxdat_burst_active;
  txn_id_t rxdat_burst_txn_id;
  data_id_t rxdat_expected_data_id;
  int unsigned rxdat_burst_count;
  dat_opcode_t rxdat_burst_opcode;
  // Sticky "this interface has carried link traffic at least once". Gates
  // p_link_restarts_after_reset_release; see the comment on that property for
  // why it deliberately is NOT reset with everything else.
  bit link_ever_active;

  always_ff @(posedge vif.clk) begin
    if (link_is_active()) begin
      link_ever_active <= 1'b1;
    end
  end

  int unsigned txreq_lcrd_count;
  int unsigned txrsp_lcrd_count;
  int unsigned txdat_lcrd_count;
  int unsigned rxreq_lcrd_count;
  int unsigned rxrsp_lcrd_count;
  int unsigned rxdat_lcrd_count;
  bit req_inflight_by_txn[TXN_ID_COUNT_C];

  // Running population count of req_inflight_by_txn. Maintained alongside the
  // array rather than reduced from it: the TxnID space is 1024 entries on CHI-D
  // and 4096 on CHI-E, and p_txsactive_covers_outstanding needs the answer on
  // EVERY clock, which is not something to spend a full-array reduction on.
  //
  // Every site that sets or clears a bit contributes to req_outstanding_delta,
  // a blocking accumulator applied once at the end of this always_ff. That is
  // what keeps the count right when a request goes out in the same cycle a
  // completion retires another: one NBA update carrying the net change, rather
  // than several read-modify-writes all reading the same stale value.
  int unsigned req_outstanding_count;
  int          req_outstanding_delta;

  // Consecutive fully-idle cycles with TXSACTIVE still up, and a latch so one
  // stuck episode reports once rather than once per cycle.
  int unsigned txsactive_idle_cycles;
  bit          txsactive_bound_reported;

  // Nothing this checker knows to be outstanding, and not a single flit moving
  // in either direction on any channel. The flit terms are what keep the
  // deassert bound clear of a sender's own retire tail: a completion, and any
  // CompAck chasing it, are flits, so the idle run only starts once the link is
  // genuinely quiet.
  function automatic bit link_quiet();
    return ((req_outstanding_count == 0) &&
            !vif.txreqflitv && !vif.txrspflitv && !vif.txdatflitv &&
            !vif.rxreqflitv && !vif.rxrspflitv && !vif.rxdatflitv);
  endfunction
  bit dat_completion_req_valid_by_txn[TXN_ID_COUNT_C];
  txn_id_t dat_completion_req_txn_by_txn[TXN_ID_COUNT_C];

  always_ff @(posedge vif.clk or negedge vif.rst_n) begin
    if (!checks_enable || !vif.rst_n) begin
      for (int txn_i = 0; txn_i < TXN_ID_COUNT_C; txn_i++) begin
        req_exp_comp_ack_by_txn[txn_i]    <= 1'b0;
        write_completion_seen_by_txn[txn_i] <= 1'b0;
        write_grant_seen_by_dbid[txn_i]   <= 1'b0;
        expected_write_beats_by_txn[txn_i] <= 0;
        expected_write_beats_by_dbid[txn_i] <= 0;
        expected_write_valid_by_dbid[txn_i] <= 1'b0;
        expected_completion_beats_by_txn[txn_i] <= 0;
        expected_completion_opcode_by_txn[txn_i] <=
          dat_opcode_t'(VIP_CHI_DAT_COMP_DATA_C);
        expected_completion_valid_by_txn[txn_i] <= 1'b0;
        req_inflight_by_txn[txn_i] <= 1'b0;
        dat_completion_req_valid_by_txn[txn_i] <= 1'b0;
        dat_completion_req_txn_by_txn[txn_i] <= '0;
      end

      req_outstanding_count <= 0;
      txsactive_idle_cycles <= 0;
      txsactive_bound_reported <= 1'b0;

      txdat_burst_active    <= 1'b0;
      txdat_burst_txn_id    <= '0;
      txdat_expected_data_id <= '0;
      txdat_burst_count     <= 0;
      txdat_burst_opcode    <= dat_opcode_t'(VIP_CHI_DAT_COMP_DATA_C);
      rxdat_burst_active    <= 1'b0;
      rxdat_burst_txn_id    <= '0;
      rxdat_expected_data_id <= '0;
      rxdat_burst_count     <= 0;
      rxdat_burst_opcode    <= dat_opcode_t'(VIP_CHI_DAT_COMP_DATA_C);
      txreq_lcrd_count      <= 0;
      txrsp_lcrd_count      <= 0;
      txdat_lcrd_count      <= 0;
      rxreq_lcrd_count      <= 0;
      rxrsp_lcrd_count      <= 0;
      rxdat_lcrd_count      <= 0;
    end
    else begin
      req_outstanding_delta = 0;

      // Each pool is credited by the LCRDV that authorizes the flit it counts,
      // which travels opposite to that flit on the same channel (see the link
      // adapter's cross-wire). A tx<chan> send is granted by the inbound
      // rx<chan>lcrdv; a rx<chan> receive is granted by this node's own outbound
      // tx<chan>lcrdv (which it emitted earlier for the peer). Pairing them this
      // way makes each counter an exact shadow of the peer/local lcrd_mgr, so the
      // M4 underflow check in lcrd_next() only ever fires on a real violation.
      txreq_lcrd_count <= lcrd_next(txreq_lcrd_count, vif.rxreqlcrdv, vif.txreqflitv, REQ_SEND_CAP_C, "txreq");
      txrsp_lcrd_count <= lcrd_next(txrsp_lcrd_count, vif.rxrsplcrdv, vif.txrspflitv, RSP_SEND_CAP_C, "txrsp");
      txdat_lcrd_count <= lcrd_next(txdat_lcrd_count, vif.rxdatlcrdv, vif.txdatflitv, DAT_SEND_CAP_C, "txdat");
      rxreq_lcrd_count <= lcrd_next(rxreq_lcrd_count, vif.txreqlcrdv, vif.rxreqflitv, REQ_SEND_CAP_C, "rxreq");
      rxrsp_lcrd_count <= lcrd_next(rxrsp_lcrd_count, vif.txrsplcrdv, vif.rxrspflitv, RSP_SEND_CAP_C, "rxrsp");
      rxdat_lcrd_count <= lcrd_next(rxdat_lcrd_count, vif.txdatlcrdv, vif.rxdatflitv, DAT_SEND_CAP_C, "rxdat");

      if (ROLE_IS_REQUESTER_C) begin
        if (vif.txreqflitv) begin
          int unsigned txn_idx;
          int unsigned completion_idx;
          int unsigned beat_count;
          req_opcode_t req_opcode;

          req_opcode = req_opcode_t'(vif.txreqflit.opcode);
          txn_idx = txn_id_to_index(txn_id_t'(vif.txreqflit.txnid));
          if (req_has_modeled_completion(req_opcode)) begin
            if (req_inflight_by_txn[txn_idx]) begin
              $error("vip_chi_sva: requester reused a TxnID while the earlier request was still in flight");
            end
            if (!req_inflight_by_txn[txn_idx]) begin
              req_outstanding_delta++;
            end
            req_inflight_by_txn[txn_idx] <= 1'b1;
          end
          expected_write_beats_by_txn[txn_idx] <= req_write_payload_beats(
            req_opcode, size_t'(vif.txreqflit.size));

          beat_count = req_completion_payload_beats(
            req_opcode, size_t'(vif.txreqflit.size));
          if (beat_count != 0) begin
            completion_idx = txn_id_to_index(
              completion_txn_for_req(
                req_opcode,
                txn_id_t'(vif.txreqflit.txnid),
                txn_id_t'(vif.txreqflit.returntxnid)));
            expected_completion_beats_by_txn[completion_idx] <= beat_count;
            expected_completion_opcode_by_txn[completion_idx] <=
              expected_completion_dat_opcode(req_opcode);
            expected_completion_valid_by_txn[completion_idx] <= 1'b1;
            dat_completion_req_valid_by_txn[completion_idx] <= 1'b1;
            dat_completion_req_txn_by_txn[completion_idx] <= txn_id_t'(vif.txreqflit.txnid);
          end
        end

        if (vif.txreqflitv && is_write_req_opcode(req_opcode_t'(vif.txreqflit.opcode))) begin
          req_exp_comp_ack_by_txn[txn_id_to_index(txn_id_t'(vif.txreqflit.txnid))] <=
            vif.txreqflit.expcompack;
          write_completion_seen_by_txn[txn_id_to_index(txn_id_t'(vif.txreqflit.txnid))] <=
            1'b0;
        end

        if (vif.rxrspflitv) begin
          case (rsp_opcode_t'(vif.rxrspflit.opcode))
            rsp_opcode_t'(VIP_CHI_RSP_DBID_RESP_C): begin
              write_grant_seen_by_dbid[txn_id_to_index(txn_id_t'(vif.rxrspflit.dbid))] <= 1'b1;
              expected_write_beats_by_dbid[txn_id_to_index(txn_id_t'(vif.rxrspflit.dbid))] <=
                expected_write_beats_by_txn[txn_id_to_index(txn_id_t'(vif.rxrspflit.txnid))];
              expected_write_valid_by_dbid[txn_id_to_index(txn_id_t'(vif.rxrspflit.dbid))] <=
                (expected_write_beats_by_txn[txn_id_to_index(txn_id_t'(vif.rxrspflit.txnid))] != 0);
            end

            rsp_opcode_t'(VIP_CHI_RSP_DBID_RESP_ORD_C): begin
              write_grant_seen_by_dbid[txn_id_to_index(txn_id_t'(vif.rxrspflit.dbid))] <= 1'b1;
              expected_write_beats_by_dbid[txn_id_to_index(txn_id_t'(vif.rxrspflit.dbid))] <=
                expected_write_beats_by_txn[txn_id_to_index(txn_id_t'(vif.rxrspflit.txnid))];
              expected_write_valid_by_dbid[txn_id_to_index(txn_id_t'(vif.rxrspflit.dbid))] <=
                (expected_write_beats_by_txn[txn_id_to_index(txn_id_t'(vif.rxrspflit.txnid))] != 0);
            end

            rsp_opcode_t'(VIP_CHI_RSP_COMP_DBID_RESP_C): begin
              write_grant_seen_by_dbid[txn_id_to_index(txn_id_t'(vif.rxrspflit.dbid))] <= 1'b1;
              expected_write_beats_by_dbid[txn_id_to_index(txn_id_t'(vif.rxrspflit.dbid))] <=
                expected_write_beats_by_txn[txn_id_to_index(txn_id_t'(vif.rxrspflit.txnid))];
              expected_write_valid_by_dbid[txn_id_to_index(txn_id_t'(vif.rxrspflit.dbid))] <=
                (expected_write_beats_by_txn[txn_id_to_index(txn_id_t'(vif.rxrspflit.txnid))] != 0);
              write_completion_seen_by_txn[txn_id_to_index(txn_id_t'(vif.rxrspflit.txnid))] <= 1'b1;
              if (req_inflight_by_txn[txn_id_to_index(txn_id_t'(vif.rxrspflit.txnid))]) begin
                req_outstanding_delta--;
              end
              req_inflight_by_txn[txn_id_to_index(txn_id_t'(vif.rxrspflit.txnid))] <= 1'b0;
            end

            rsp_opcode_t'(VIP_CHI_RSP_COMP_C): begin
              write_completion_seen_by_txn[txn_id_to_index(txn_id_t'(vif.rxrspflit.txnid))] <= 1'b1;
              if (req_inflight_by_txn[txn_id_to_index(txn_id_t'(vif.rxrspflit.txnid))]) begin
                req_outstanding_delta--;
              end
              req_inflight_by_txn[txn_id_to_index(txn_id_t'(vif.rxrspflit.txnid))] <= 1'b0;
            end

            rsp_opcode_t'(VIP_CHI_RSP_COMP_PERSIST_C): begin
              if (req_inflight_by_txn[txn_id_to_index(txn_id_t'(vif.rxrspflit.txnid))]) begin
                req_outstanding_delta--;
              end
              req_inflight_by_txn[txn_id_to_index(txn_id_t'(vif.rxrspflit.txnid))] <= 1'b0;
            end

            rsp_opcode_t'(VIP_CHI_RSP_RETRY_ACK_C): begin
              // A RetryAck retires the bounced request: the completer did not
              // accept it, so its TxnID is released and the requester re-issues
              // after the matching PCrdGrant. Clear the in-flight marker so that
              // legitimate re-issue is not flagged as a TxnID reuse.
              if (req_inflight_by_txn[txn_id_to_index(txn_id_t'(vif.rxrspflit.txnid))]) begin
                req_outstanding_delta--;
              end
              req_inflight_by_txn[txn_id_to_index(txn_id_t'(vif.rxrspflit.txnid))] <= 1'b0;
            end

            default: begin
            end
          endcase
        end

        if (vif.txdatflitv && is_write_dat_opcode(dat_opcode_t'(vif.txdatflit.opcode))) begin
          if (!write_grant_seen_by_dbid[txn_id_to_index(txn_id_t'(vif.txdatflit.dbid))]) begin
            $error("vip_chi_sva: write DAT was sent before a DBID-bearing grant response");
          end

          if (txn_id_t'(vif.txdatflit.txnid) != txn_id_t'(vif.txdatflit.dbid)) begin
            $error("vip_chi_sva: write DAT txnid did not match DBID on the wire");
          end

          if (!vif.txdatflitpend) begin
            write_grant_seen_by_dbid[txn_id_to_index(txn_id_t'(vif.txdatflit.dbid))] <= 1'b0;
          end
        end

        if (vif.txrspflitv &&
            (rsp_opcode_t'(vif.txrspflit.opcode) == rsp_opcode_t'(VIP_CHI_RSP_COMP_ACK_C))) begin
          if (!write_completion_seen_by_txn[txn_id_to_index(txn_id_t'(vif.txrspflit.txnid))]) begin
            $error("vip_chi_sva: CompAck was sent before a write completion response");
          end

          if (!req_exp_comp_ack_by_txn[txn_id_to_index(txn_id_t'(vif.txrspflit.txnid))]) begin
            $error("vip_chi_sva: CompAck was sent for a request without ExpCompAck");
          end

          req_exp_comp_ack_by_txn[txn_id_to_index(txn_id_t'(vif.txrspflit.txnid))] <= 1'b0;
          write_completion_seen_by_txn[txn_id_to_index(txn_id_t'(vif.txrspflit.txnid))] <= 1'b0;
        end
      end
      else if (ROLE_IS_COMPLETER_C) begin
        if (vif.rxreqflitv) begin
          int unsigned txn_idx;
          int unsigned completion_idx;
          int unsigned beat_count;
          req_opcode_t req_opcode;

          req_opcode = req_opcode_t'(vif.rxreqflit.opcode);
          txn_idx = txn_id_to_index(txn_id_t'(vif.rxreqflit.txnid));
          if (req_has_modeled_completion(req_opcode)) begin
            if (req_inflight_by_txn[txn_idx]) begin
              $error("vip_chi_sva: completer observed a reused request TxnID while the earlier request was still in flight");
            end
            if (!req_inflight_by_txn[txn_idx]) begin
              req_outstanding_delta++;
            end
            req_inflight_by_txn[txn_idx] <= 1'b1;
          end
          expected_write_beats_by_txn[txn_idx] <= req_write_payload_beats(
            req_opcode, size_t'(vif.rxreqflit.size));

          beat_count = req_completion_payload_beats(
            req_opcode, size_t'(vif.rxreqflit.size));
          if (beat_count != 0) begin
            completion_idx = txn_id_to_index(
              completion_txn_for_req(
                req_opcode,
                txn_id_t'(vif.rxreqflit.txnid),
                txn_id_t'(vif.rxreqflit.returntxnid)));
            expected_completion_beats_by_txn[completion_idx] <= beat_count;
            expected_completion_opcode_by_txn[completion_idx] <=
              expected_completion_dat_opcode(req_opcode);
            expected_completion_valid_by_txn[completion_idx] <= 1'b1;
            dat_completion_req_valid_by_txn[completion_idx] <= 1'b1;
            dat_completion_req_txn_by_txn[completion_idx] <= txn_id_t'(vif.rxreqflit.txnid);
          end
        end

        if (vif.txrspflitv) begin
          case (rsp_opcode_t'(vif.txrspflit.opcode))
            rsp_opcode_t'(VIP_CHI_RSP_DBID_RESP_C),
            rsp_opcode_t'(VIP_CHI_RSP_DBID_RESP_ORD_C),
            rsp_opcode_t'(VIP_CHI_RSP_COMP_DBID_RESP_C): begin
              expected_write_beats_by_dbid[txn_id_to_index(txn_id_t'(vif.txrspflit.dbid))] <=
                expected_write_beats_by_txn[txn_id_to_index(txn_id_t'(vif.txrspflit.txnid))];
              expected_write_valid_by_dbid[txn_id_to_index(txn_id_t'(vif.txrspflit.dbid))] <=
                (expected_write_beats_by_txn[txn_id_to_index(txn_id_t'(vif.txrspflit.txnid))] != 0);
            end
            rsp_opcode_t'(VIP_CHI_RSP_RETRY_ACK_C): begin
              // Mirror of the RN-I side: a RetryAck this SN-F drove retires the
              // bounced request's TxnID, so clear the in-flight marker and allow
              // the requester's re-issue to reuse it without a reuse violation.
              if (req_inflight_by_txn[txn_id_to_index(txn_id_t'(vif.txrspflit.txnid))]) begin
                req_outstanding_delta--;
              end
              req_inflight_by_txn[txn_id_to_index(txn_id_t'(vif.txrspflit.txnid))] <= 1'b0;
            end
            default: begin
            end
          endcase
        end
      end

      if (vif.txdatflitv) begin
        if (!txdat_burst_active) begin
          txdat_burst_count <= 1;
          txdat_burst_opcode <= dat_opcode_t'(vif.txdatflit.opcode);
          if (!dat_reorder_allowed &&
              (data_id_t'(vif.txdatflit.dataid) != data_id_t'('0))) begin
            $error("vip_chi_sva: first TX DAT beat did not start at dataid 0");
          end

          if (vif.txdatflitpend) begin
            txdat_burst_active     <= 1'b1;
            txdat_burst_txn_id     <= txn_id_t'(vif.txdatflit.txnid);
            txdat_expected_data_id <= data_id_t'(data_id_t'(vif.txdatflit.dataid) + data_id_t'(1));
          end
          else begin
            if (ROLE_IS_REQUESTER_C &&
                is_write_dat_opcode(dat_opcode_t'(vif.txdatflit.opcode))) begin
              int unsigned dbid_idx;

              dbid_idx = txn_id_to_index(txn_id_t'(vif.txdatflit.dbid));
              if (expected_write_valid_by_dbid[dbid_idx] &&
                  (expected_write_beats_by_dbid[dbid_idx] != 1)) begin
                $error("vip_chi_sva: TX write DAT burst beat count did not match the granted request size");
              end
              expected_write_valid_by_dbid[dbid_idx] <= 1'b0;
            end
            else if (ROLE_IS_COMPLETER_C &&
                     ((dat_opcode_t'(vif.txdatflit.opcode) == dat_opcode_t'(VIP_CHI_DAT_COMP_DATA_C)) ||
                      (dat_opcode_t'(vif.txdatflit.opcode) == dat_opcode_t'(VIP_CHI_DAT_DATA_SEP_RESP_C)))) begin
              int unsigned txn_idx;

              txn_idx = txn_id_to_index(txn_id_t'(vif.txdatflit.txnid));
              if (expected_completion_valid_by_txn[txn_idx]) begin
                if (expected_completion_opcode_by_txn[txn_idx] != dat_opcode_t'(vif.txdatflit.opcode)) begin
                  $error("vip_chi_sva: TX read completion DAT opcode did not match the request type");
                end
                if (expected_completion_beats_by_txn[txn_idx] != 1) begin
                  $error("vip_chi_sva: TX read completion DAT burst beat count did not match the request size");
                end
                expected_completion_valid_by_txn[txn_idx] <= 1'b0;
                if (dat_completion_req_valid_by_txn[txn_idx]) begin
                  if (req_inflight_by_txn[txn_id_to_index(dat_completion_req_txn_by_txn[txn_idx])]) begin
                    req_outstanding_delta--;
                  end
                  req_inflight_by_txn[txn_id_to_index(dat_completion_req_txn_by_txn[txn_idx])] <= 1'b0;
                  dat_completion_req_valid_by_txn[txn_idx] <= 1'b0;
                end
              end
            end
          end
        end
        else begin
          if (txn_id_t'(vif.txdatflit.txnid) != txdat_burst_txn_id) begin
            $error("vip_chi_sva: TX DAT burst changed txnid before txdatflitpend dropped");
          end

          if (!dat_reorder_allowed &&
              (data_id_t'(vif.txdatflit.dataid) != txdat_expected_data_id)) begin
            $error("vip_chi_sva: TX DAT burst dataid was not sequential");
          end

          txdat_burst_count <= txdat_burst_count + 1;
          if (vif.txdatflitpend) begin
            txdat_expected_data_id <= data_id_t'(txdat_expected_data_id + data_id_t'(1));
          end
          else begin
            if (ROLE_IS_REQUESTER_C &&
                is_write_dat_opcode(txdat_burst_opcode)) begin
              int unsigned dbid_idx;

              dbid_idx = txn_id_to_index(txn_id_t'(vif.txdatflit.dbid));
              if (expected_write_valid_by_dbid[dbid_idx] &&
                  (expected_write_beats_by_dbid[dbid_idx] != (txdat_burst_count + 1))) begin
                $error("vip_chi_sva: TX write DAT burst beat count did not match the granted request size");
              end
              expected_write_valid_by_dbid[dbid_idx] <= 1'b0;
            end
            else if (ROLE_IS_COMPLETER_C &&
                     ((txdat_burst_opcode == dat_opcode_t'(VIP_CHI_DAT_COMP_DATA_C)) ||
                      (txdat_burst_opcode == dat_opcode_t'(VIP_CHI_DAT_DATA_SEP_RESP_C)))) begin
              int unsigned txn_idx;

              txn_idx = txn_id_to_index(txn_id_t'(vif.txdatflit.txnid));
              if (expected_completion_valid_by_txn[txn_idx]) begin
                if (expected_completion_opcode_by_txn[txn_idx] != txdat_burst_opcode) begin
                  $error("vip_chi_sva: TX read completion DAT opcode did not match the request type");
                end
                if (expected_completion_beats_by_txn[txn_idx] != (txdat_burst_count + 1)) begin
                  $error("vip_chi_sva: TX read completion DAT burst beat count did not match the request size");
                end
                expected_completion_valid_by_txn[txn_idx] <= 1'b0;
                if (dat_completion_req_valid_by_txn[txn_idx]) begin
                  if (req_inflight_by_txn[txn_id_to_index(dat_completion_req_txn_by_txn[txn_idx])]) begin
                    req_outstanding_delta--;
                  end
                  req_inflight_by_txn[txn_id_to_index(dat_completion_req_txn_by_txn[txn_idx])] <= 1'b0;
                  dat_completion_req_valid_by_txn[txn_idx] <= 1'b0;
                end
              end
            end
            txdat_burst_active     <= 1'b0;
            txdat_burst_txn_id     <= '0;
            txdat_expected_data_id <= '0;
            txdat_burst_count      <= 0;
            txdat_burst_opcode     <= dat_opcode_t'(VIP_CHI_DAT_COMP_DATA_C);
          end
        end
      end

      if (vif.rxdatflitv) begin
        if (!rxdat_burst_active) begin
          rxdat_burst_count <= 1;
          rxdat_burst_opcode <= dat_opcode_t'(vif.rxdatflit.opcode);
          if (!dat_reorder_allowed &&
              (data_id_t'(vif.rxdatflit.dataid) != data_id_t'('0))) begin
            $error("vip_chi_sva: first RX DAT beat did not start at dataid 0");
          end

          if (vif.rxdatflitpend) begin
            rxdat_burst_active     <= 1'b1;
            rxdat_burst_txn_id     <= txn_id_t'(vif.rxdatflit.txnid);
            rxdat_expected_data_id <= data_id_t'(data_id_t'(vif.rxdatflit.dataid) + data_id_t'(1));
          end
          else begin
            if (ROLE_IS_COMPLETER_C &&
                is_write_dat_opcode(dat_opcode_t'(vif.rxdatflit.opcode))) begin
              int unsigned dbid_idx;

              dbid_idx = txn_id_to_index(txn_id_t'(vif.rxdatflit.dbid));
              if (expected_write_valid_by_dbid[dbid_idx] &&
                  (expected_write_beats_by_dbid[dbid_idx] != 1)) begin
                $error("vip_chi_sva: RX write DAT burst beat count did not match the granted request size");
              end
              expected_write_valid_by_dbid[dbid_idx] <= 1'b0;
            end
            else if (ROLE_IS_REQUESTER_C &&
                     ((dat_opcode_t'(vif.rxdatflit.opcode) == dat_opcode_t'(VIP_CHI_DAT_COMP_DATA_C)) ||
                      (dat_opcode_t'(vif.rxdatflit.opcode) == dat_opcode_t'(VIP_CHI_DAT_DATA_SEP_RESP_C)))) begin
              int unsigned txn_idx;

              txn_idx = txn_id_to_index(txn_id_t'(vif.rxdatflit.txnid));
              if (expected_completion_valid_by_txn[txn_idx]) begin
                if (expected_completion_opcode_by_txn[txn_idx] != dat_opcode_t'(vif.rxdatflit.opcode)) begin
                  $error("vip_chi_sva: RX read completion DAT opcode did not match the request type");
                end
                if (expected_completion_beats_by_txn[txn_idx] != 1) begin
                  $error("vip_chi_sva: RX read completion DAT burst beat count did not match the request size");
                end
                expected_completion_valid_by_txn[txn_idx] <= 1'b0;
                if (dat_completion_req_valid_by_txn[txn_idx]) begin
                  if (req_inflight_by_txn[txn_id_to_index(dat_completion_req_txn_by_txn[txn_idx])]) begin
                    req_outstanding_delta--;
                  end
                  req_inflight_by_txn[txn_id_to_index(dat_completion_req_txn_by_txn[txn_idx])] <= 1'b0;
                  dat_completion_req_valid_by_txn[txn_idx] <= 1'b0;
                end
              end
            end
          end
        end
        else begin
          if (txn_id_t'(vif.rxdatflit.txnid) != rxdat_burst_txn_id) begin
            $error("vip_chi_sva: RX DAT burst changed txnid before rxdatflitpend dropped");
          end

          if (!dat_reorder_allowed &&
              (data_id_t'(vif.rxdatflit.dataid) != rxdat_expected_data_id)) begin
            $error("vip_chi_sva: RX DAT burst dataid was not sequential");
          end

          rxdat_burst_count <= rxdat_burst_count + 1;
          if (vif.rxdatflitpend) begin
            rxdat_expected_data_id <= data_id_t'(rxdat_expected_data_id + data_id_t'(1));
          end
          else begin
            if (ROLE_IS_COMPLETER_C &&
                is_write_dat_opcode(rxdat_burst_opcode)) begin
              int unsigned dbid_idx;

              dbid_idx = txn_id_to_index(txn_id_t'(vif.rxdatflit.dbid));
              if (expected_write_valid_by_dbid[dbid_idx] &&
                  (expected_write_beats_by_dbid[dbid_idx] != (rxdat_burst_count + 1))) begin
                $error("vip_chi_sva: RX write DAT burst beat count did not match the granted request size");
              end
              expected_write_valid_by_dbid[dbid_idx] <= 1'b0;
            end
            else if (ROLE_IS_REQUESTER_C &&
                     ((rxdat_burst_opcode == dat_opcode_t'(VIP_CHI_DAT_COMP_DATA_C)) ||
                      (rxdat_burst_opcode == dat_opcode_t'(VIP_CHI_DAT_DATA_SEP_RESP_C)))) begin
              int unsigned txn_idx;

              txn_idx = txn_id_to_index(txn_id_t'(vif.rxdatflit.txnid));
              if (expected_completion_valid_by_txn[txn_idx]) begin
                if (expected_completion_opcode_by_txn[txn_idx] != rxdat_burst_opcode) begin
                  $error("vip_chi_sva: RX read completion DAT opcode did not match the request type");
                end
                if (expected_completion_beats_by_txn[txn_idx] != (rxdat_burst_count + 1)) begin
                  $error("vip_chi_sva: RX read completion DAT burst beat count did not match the request size");
                end
                expected_completion_valid_by_txn[txn_idx] <= 1'b0;
                if (dat_completion_req_valid_by_txn[txn_idx]) begin
                  if (req_inflight_by_txn[txn_id_to_index(dat_completion_req_txn_by_txn[txn_idx])]) begin
                    req_outstanding_delta--;
                  end
                  req_inflight_by_txn[txn_id_to_index(dat_completion_req_txn_by_txn[txn_idx])] <= 1'b0;
                  dat_completion_req_valid_by_txn[txn_idx] <= 1'b0;
                end
              end
            end
            rxdat_burst_active     <= 1'b0;
            rxdat_burst_txn_id     <= '0;
            rxdat_expected_data_id <= '0;
            rxdat_burst_count      <= 0;
            rxdat_burst_opcode     <= dat_opcode_t'(VIP_CHI_DAT_COMP_DATA_C);
          end
        end
      end

      // One NBA update carrying the net change every site above contributed.
      req_outstanding_count <= req_outstanding_count + req_outstanding_delta;

      // An episode ends the moment anything happens on the link, which is what
      // keeps the bound clear of a sender's own retire tail.
      if (link_quiet() && vif.txsactive) begin
        txsactive_idle_cycles <= txsactive_idle_cycles + 1;
        if (txsactive_idle_cycles >
            (TXSACTIVE_SETTLE_CYCLES_C + txsactive_extend_max_cycles)) begin
          txsactive_bound_reported <= 1'b1;
        end
      end
      else begin
        txsactive_idle_cycles    <= 0;
        txsactive_bound_reported <= 1'b0;
      end
    end
  end

  // The LASM may only hold, or advance one step around
  // STOP -> ACTIVATE -> RUN -> DEACTIVATE -> STOP. Every other pair is illegal:
  // a link that jumps STOP -> RUN skipped the acknowledge that authorises it,
  // and one that jumps RUN -> STOP dropped request and acknowledge together
  // instead of retiring the acknowledge after the request.
  //
  // Gated on rst_n only, NOT on checks_enable -- see the comment on lasm_state
  // for why gating a link-state rule on link activity would blind it to the
  // deactivation half of the cycle. An interface whose agent is never built
  // holds STOP throughout and only ever sees the legal hold, so it stays silent.
  //
  // vif.lasm_illegal_count is the observable: it counts every illegal step
  // whether or not the report was suppressed, so the negative control can assert
  // the rule fired exactly once and an ordinary run can assert it never did.
  // That makes this the one check whose non-vacuity a test can read directly
  // rather than infer from a silent log. It is published on the INTERFACE
  // because a package may hold no hierarchical reference and the testcases are
  // compiled into one -- see the declaration in vip_chi_if.
  always_ff @(posedge vif.clk) begin
    if (!vif.rst_n) begin
      vif.lasm_illegal_count <= 0;
    end
    else if (!vip_chi_lasm_legal_step(lasm_state, link_lasm())) begin
      vif.lasm_illegal_count <= vif.lasm_illegal_count + 1;
    end
  end

  property p_lasm_legal_transition;
    @(posedge vif.clk) disable iff (!vif.rst_n || lasm_illegal_expected)
      vip_chi_lasm_legal_step(lasm_state, link_lasm());
  endproperty

  // No L-credit may still be outstanding while the link is in STOP. A sender
  // must have returned every credit it holds before the link goes down; one left
  // behind means the shadow and the link disagree about what the peer is
  // entitled to send, and that disagreement is what the NEXT activation starts
  // from -- a pool seeded with a stale credit lets the first flit after bring-up
  // go out unauthorised, which the underflow rule could then never catch because
  // the count never reaches zero.
  property p_lcrd_quiescent_in_stop;
    @(posedge vif.clk) disable iff (!vif.rst_n)
      (link_lasm() == VIP_CHI_LASM_STOP_E) |->
        ((txreq_lcrd_count == 0) && (txrsp_lcrd_count == 0) &&
         (txdat_lcrd_count == 0) && (rxreq_lcrd_count == 0) &&
         (rxrsp_lcrd_count == 0) && (rxdat_lcrd_count == 0));
  endproperty

  property p_req_requires_link;
    @(posedge vif.clk) disable iff (!checks_enable || !vif.rst_n)
      vif.txreqflitv |-> (link_lasm() == VIP_CHI_LASM_RUN_E);
  endproperty

  property p_rsp_requires_link;
    @(posedge vif.clk) disable iff (!checks_enable || !vif.rst_n)
      vif.txrspflitv |-> (link_lasm() == VIP_CHI_LASM_RUN_E);
  endproperty

  property p_dat_requires_link;
    @(posedge vif.clk) disable iff (!checks_enable || !vif.rst_n)
      vif.txdatflitv |-> (link_lasm() == VIP_CHI_LASM_RUN_E);
  endproperty

  property p_req_lcrdv_requires_link;
    @(posedge vif.clk) disable iff (!checks_enable || !vif.rst_n)
      vif.txreqlcrdv |-> link_is_active();
  endproperty

  property p_rsp_lcrdv_requires_link;
    @(posedge vif.clk) disable iff (!checks_enable || !vif.rst_n)
      vif.txrsplcrdv |-> link_is_active();
  endproperty

  property p_dat_lcrdv_requires_link;
    @(posedge vif.clk) disable iff (!checks_enable || !vif.rst_n)
      vif.txdatlcrdv |-> link_is_active();
  endproperty

  property p_req_pend_requires_valid;
    @(posedge vif.clk) disable iff (!checks_enable || !vif.rst_n)
      vif.txreqflitpend |-> vif.txreqflitv;
  endproperty

  property p_rsp_pend_requires_valid;
    @(posedge vif.clk) disable iff (!checks_enable || !vif.rst_n)
      vif.txrspflitpend |-> vif.txrspflitv;
  endproperty

  property p_dat_pend_requires_valid;
    @(posedge vif.clk) disable iff (!checks_enable || !vif.rst_n)
      vif.txdatflitpend |-> vif.txdatflitv;
  endproperty

  property p_req_known_when_valid;
    @(posedge vif.clk) disable iff (!checks_enable || !vif.rst_n)
      vif.txreqflitv |-> !$isunknown(vif.txreqflit);
  endproperty

  property p_rsp_known_when_valid;
    @(posedge vif.clk) disable iff (!checks_enable || !vif.rst_n)
      vif.txrspflitv |-> !$isunknown(vif.txrspflit);
  endproperty

  property p_dat_known_when_valid;
    @(posedge vif.clk) disable iff (!checks_enable || !vif.rst_n)
      vif.txdatflitv |-> !$isunknown(vif.txdatflit);
  endproperty

  property p_link_sideband_idle_during_reset;
    @(posedge vif.clk) disable iff (!checks_enable)
      (!vif.rst_n && $past(!vif.rst_n, 1, 1'b1)) |->
        (!vif.txlinkactivereq && !vif.txlinkactiveack && !vif.txsactive);
  endproperty

  property p_req_idle_during_reset;
    @(posedge vif.clk) disable iff (!checks_enable)
      (!vif.rst_n && $past(!vif.rst_n, 1, 1'b1)) |->
        (!vif.txreqflitv && !vif.txreqflitpend && !vif.txreqlcrdv);
  endproperty

  property p_rsp_idle_during_reset;
    @(posedge vif.clk) disable iff (!checks_enable)
      (!vif.rst_n && $past(!vif.rst_n, 1, 1'b1)) |->
        (!vif.txrspflitv && !vif.txrspflitpend && !vif.txrsplcrdv);
  endproperty

  property p_dat_idle_during_reset;
    @(posedge vif.clk) disable iff (!checks_enable)
      (!vif.rst_n && $past(!vif.rst_n, 1, 1'b1)) |->
        (!vif.txdatflitv && !vif.txdatflitpend && !vif.txdatlcrdv);
  endproperty

  // NOT gated on checks_enable, unlike every other property here, and the
  // exception is the whole point. checks_enable is this interface's current
  // link activity, and the attempt starts at $rose(rst_n) -- the one moment the
  // link is guaranteed idle, because p_link_sideband_idle_during_reset requires
  // it. `disable iff` therefore killed every attempt at cycle 0 and the check
  // could never fire: it read as "if the link is up, the link comes up".
  //
  // link_ever_active is the gate that carries the intended meaning. It latches
  // the first time this interface's link activates and deliberately survives
  // reset, so an interface whose agent is never built stays unarmed (no
  // spurious failure on an idle link), while one that has carried traffic must
  // bring its link back after every later reset release.
  property p_link_restarts_after_reset_release;
    @(posedge vif.clk) disable iff (!link_ever_active)
      $rose(vif.rst_n) |=> ##[0:LINK_ACT_WINDOW_P] link_is_active();
  endproperty

  property p_link_deactivate_when_idle;
    @(posedge vif.clk) disable iff (!checks_enable || !vif.rst_n)
      !link_is_active() |=> !vif.txsactive;
  endproperty

  // TXSACTIVE against the outstanding window.
  //
  // TXSACTIVE tells the receiver this node may have snoopable transactions
  // outstanding. The receiver's use for it is to decide when it can stop
  // watching for snoop traffic, so the failure that matters is UNDER-assertion:
  // the sideband low while transactions are still in flight tells the receiver
  // it may stand down when it may not.
  //
  // Requester vantage only. TXSACTIVE reports the TRANSMITTING node's own
  // outstanding transactions, and a completer has none: the requests it is
  // servicing belong to the requester at the other end of the link, which is
  // the node whose sideband covers them. req_outstanding_count tracks received
  // requests at a completer, so it would otherwise read that peer's window off
  // the wrong wire.
  property p_txsactive_covers_outstanding;
    @(posedge vif.clk) disable iff (!checks_enable || !vif.rst_n ||
                                    !ROLE_IS_REQUESTER_C)
      (req_outstanding_count > 0) |-> vif.txsactive;
  endproperty

  // Over-assertion is legal -- "may have" is permissive -- so this is not the
  // mirror of the property above. It bounds how long the signal may stay up
  // once the link has gone completely quiet, which catches a sender that raises
  // TXSACTIVE and then never lowers it: still legal by the letter, but it makes
  // the sideband carry no information at all.
  property p_txsactive_deassert_bounded;
    @(posedge vif.clk) disable iff (!checks_enable || !vif.rst_n)
      !(link_quiet() && vif.txsactive && !txsactive_bound_reported &&
        (txsactive_idle_cycles >
         (TXSACTIVE_SETTLE_CYCLES_C + txsactive_extend_max_cycles)));
  endproperty

  property p_rni_completion_follows_req;
    txn_id_t req_txn_id;
    txn_id_t completion_txn_id;
    req_opcode_t req_opcode;

    @(posedge vif.clk) disable iff (!ENABLE_COMPLETION_TIMEOUT_P ||
                                     !checks_enable || !vif.rst_n ||
                                     !ROLE_IS_REQUESTER_C)
      (vif.txreqflitv && req_has_modeled_completion(req_opcode_t'(vif.txreqflit.opcode)),
       req_txn_id = txn_id_t'(vif.txreqflit.txnid),
       req_opcode = req_opcode_t'(vif.txreqflit.opcode),
       completion_txn_id = completion_txn_for_req(
         req_opcode_t'(vif.txreqflit.opcode),
         txn_id_t'(vif.txreqflit.txnid),
         txn_id_t'(vif.txreqflit.returntxnid)))
      |-> ##[0:TIMEOUT_CYCLES_P]
          rni_final_completion_observed(req_opcode, req_txn_id, completion_txn_id);
  endproperty

  property p_snf_completion_follows_req;
    txn_id_t req_txn_id;
    txn_id_t completion_txn_id;
    req_opcode_t req_opcode;

    @(posedge vif.clk) disable iff (!ENABLE_COMPLETION_TIMEOUT_P ||
                                     !checks_enable || !vif.rst_n ||
                                     !ROLE_IS_COMPLETER_C)
      (vif.rxreqflitv && req_has_modeled_completion(req_opcode_t'(vif.rxreqflit.opcode)),
       req_txn_id = txn_id_t'(vif.rxreqflit.txnid),
       req_opcode = req_opcode_t'(vif.rxreqflit.opcode),
       completion_txn_id = completion_txn_for_req(
         req_opcode_t'(vif.rxreqflit.opcode),
         txn_id_t'(vif.rxreqflit.txnid),
         txn_id_t'(vif.rxreqflit.returntxnid)))
      |-> ##[0:TIMEOUT_CYCLES_P]
          snf_final_completion_observed(req_opcode, req_txn_id, completion_txn_id);
  endproperty

  property p_rni_atomic_return_uses_dat_completion;
    txn_id_t req_txn_id;
    txn_id_t completion_txn_id;

    @(posedge vif.clk) disable iff (!checks_enable || !vif.rst_n ||
                                     (ROLE_P != VIP_CHI_ROLE_RNI_E))
      (vif.txreqflitv &&
       vip_chi_types_pkg::vip_chi_req_opcode_is_atomic_returning_data(
         vip_chi_req_opcode_t'(vif.txreqflit.opcode)),
       req_txn_id = txn_id_t'(vif.txreqflit.txnid),
       completion_txn_id = completion_txn_for_req(
         req_opcode_t'(vif.txreqflit.opcode),
         txn_id_t'(vif.txreqflit.txnid),
         txn_id_t'(vif.txreqflit.returntxnid)))
      |-> (!(vif.rxrspflitv &&
             (txn_id_t'(vif.rxrspflit.txnid) == req_txn_id) &&
             ((rsp_opcode_t'(vif.rxrspflit.opcode) == rsp_opcode_t'(VIP_CHI_RSP_COMP_C)) ||
              (rsp_opcode_t'(vif.rxrspflit.opcode) == rsp_opcode_t'(VIP_CHI_RSP_COMP_DBID_RESP_C)))))
          until_with
          (vif.rxdatflitv && !vif.rxdatflitpend &&
           (txn_id_t'(vif.rxdatflit.txnid) == completion_txn_id) &&
           (dat_opcode_t'(vif.rxdatflit.opcode) == dat_opcode_t'(VIP_CHI_DAT_COMP_DATA_C)));
  endproperty

  property p_snf_atomic_return_uses_dat_completion;
    txn_id_t req_txn_id;
    txn_id_t completion_txn_id;

    @(posedge vif.clk) disable iff (!checks_enable || !vif.rst_n ||
                                     (ROLE_P != VIP_CHI_ROLE_SNF_E))
      (vif.rxreqflitv &&
       vip_chi_types_pkg::vip_chi_req_opcode_is_atomic_returning_data(
         vip_chi_req_opcode_t'(vif.rxreqflit.opcode)),
       req_txn_id = txn_id_t'(vif.rxreqflit.txnid),
       completion_txn_id = completion_txn_for_req(
         req_opcode_t'(vif.rxreqflit.opcode),
         txn_id_t'(vif.rxreqflit.txnid),
         txn_id_t'(vif.rxreqflit.returntxnid)))
      |-> (!(vif.txrspflitv &&
             (txn_id_t'(vif.txrspflit.txnid) == req_txn_id) &&
             ((rsp_opcode_t'(vif.txrspflit.opcode) == rsp_opcode_t'(VIP_CHI_RSP_COMP_C)) ||
              (rsp_opcode_t'(vif.txrspflit.opcode) == rsp_opcode_t'(VIP_CHI_RSP_COMP_DBID_RESP_C)))))
          until_with
          (vif.txdatflitv && !vif.txdatflitpend &&
           (txn_id_t'(vif.txdatflit.txnid) == completion_txn_id) &&
           (dat_opcode_t'(vif.txdatflit.opcode) == dat_opcode_t'(VIP_CHI_DAT_COMP_DATA_C)));
  endproperty

  property p_rni_ordered_read_receipt_before_dat;
    txn_id_t req_txn_id;
    txn_id_t completion_txn_id;
    req_opcode_t req_opcode;

    @(posedge vif.clk) disable iff (!checks_enable || !vif.rst_n ||
                                     (ROLE_P != VIP_CHI_ROLE_RNI_E))
      (vif.txreqflitv &&
       ((req_opcode_t'(vif.txreqflit.opcode) == req_opcode_t'(VIP_CHI_REQ_READ_NO_SNP_C)) ||
        (req_opcode_t'(vif.txreqflit.opcode) == req_opcode_t'(VIP_CHI_REQ_READ_NO_SNP_SEP_C))) &&
       (vip_chi_req_order_t'(vif.txreqflit.order) != VIP_CHI_ORDER_NONE_E),
       req_txn_id = txn_id_t'(vif.txreqflit.txnid),
       req_opcode = req_opcode_t'(vif.txreqflit.opcode),
       completion_txn_id = completion_txn_for_req(
         req_opcode_t'(vif.txreqflit.opcode),
         txn_id_t'(vif.txreqflit.txnid),
         txn_id_t'(vif.txreqflit.returntxnid)))
      |-> (!rni_final_completion_observed(
              req_opcode, req_txn_id, completion_txn_id))
          until_with (vif.rxrspflitv &&
                      (txn_id_t'(vif.rxrspflit.txnid) == req_txn_id) &&
                      (rsp_opcode_t'(vif.rxrspflit.opcode) == rsp_opcode_t'(VIP_CHI_RSP_READ_RECEIPT_C)));
  endproperty

  property p_snf_ordered_read_receipt_before_dat;
    txn_id_t req_txn_id;
    txn_id_t completion_txn_id;
    req_opcode_t req_opcode;

    @(posedge vif.clk) disable iff (!checks_enable || !vif.rst_n ||
                                     (ROLE_P != VIP_CHI_ROLE_SNF_E))
      (vif.rxreqflitv &&
       ((req_opcode_t'(vif.rxreqflit.opcode) == req_opcode_t'(VIP_CHI_REQ_READ_NO_SNP_C)) ||
        (req_opcode_t'(vif.rxreqflit.opcode) == req_opcode_t'(VIP_CHI_REQ_READ_NO_SNP_SEP_C))) &&
       (vip_chi_req_order_t'(vif.rxreqflit.order) != VIP_CHI_ORDER_NONE_E),
       req_txn_id = txn_id_t'(vif.rxreqflit.txnid),
       req_opcode = req_opcode_t'(vif.rxreqflit.opcode),
       completion_txn_id = completion_txn_for_req(
         req_opcode_t'(vif.rxreqflit.opcode),
         txn_id_t'(vif.rxreqflit.txnid),
         txn_id_t'(vif.rxreqflit.returntxnid)))
      |-> (!snf_final_completion_observed(
              req_opcode, req_txn_id, completion_txn_id))
          until_with (vif.txrspflitv &&
                      (txn_id_t'(vif.txrspflit.txnid) == req_txn_id) &&
                      (rsp_opcode_t'(vif.txrspflit.opcode) == rsp_opcode_t'(VIP_CHI_RSP_READ_RECEIPT_C)));
  endproperty

  assert property (p_lasm_legal_transition)
    else $error(
      "vip_chi_sva: link stepped %s -> %s; the LASM may only hold or advance STOP -> ACTIVATE -> RUN -> DEACTIVATE -> STOP",
      lasm_state.name(), link_lasm().name());

  assert property (p_lcrd_quiescent_in_stop)
    else $error(
      "vip_chi_sva: L-credits still outstanding with the link in STOP (tx req/rsp/dat=%0d/%0d/%0d rx req/rsp/dat=%0d/%0d/%0d)",
      txreq_lcrd_count, txrsp_lcrd_count, txdat_lcrd_count,
      rxreq_lcrd_count, rxrsp_lcrd_count, rxdat_lcrd_count);

  assert property (p_req_requires_link)
    else $error("vip_chi_sva: txreqflitv asserted before link activation");

  assert property (p_rsp_requires_link)
    else $error("vip_chi_sva: txrspflitv asserted before link activation");

  assert property (p_dat_requires_link)
    else $error("vip_chi_sva: txdatflitv asserted before link activation");

  assert property (p_req_lcrdv_requires_link)
    else $error("vip_chi_sva: txreqlcrdv asserted before link activation");

  assert property (p_rsp_lcrdv_requires_link)
    else $error("vip_chi_sva: txrsplcrdv asserted before link activation");

  assert property (p_dat_lcrdv_requires_link)
    else $error("vip_chi_sva: txdatlcrdv asserted before link activation");

  assert property (p_req_pend_requires_valid)
    else $error("vip_chi_sva: txreqflitpend asserted without txreqflitv");

  assert property (p_rsp_pend_requires_valid)
    else $error("vip_chi_sva: txrspflitpend asserted without txrspflitv");

  assert property (p_dat_pend_requires_valid)
    else $error("vip_chi_sva: txdatflitpend asserted without txdatflitv");

  assert property (p_req_known_when_valid)
    else $error("vip_chi_sva: txreqflit contains X/Z while valid");

  assert property (p_rsp_known_when_valid)
    else $error("vip_chi_sva: txrspflit contains X/Z while valid");

  assert property (p_dat_known_when_valid)
    else $error("vip_chi_sva: txdatflit contains X/Z while valid");

  assert property (p_link_sideband_idle_during_reset)
    else $error("vip_chi_sva: link sideband was not held idle during reset");

  assert property (p_req_idle_during_reset)
    else $error("vip_chi_sva: REQ channel was not held idle during reset");

  assert property (p_rsp_idle_during_reset)
    else $error("vip_chi_sva: RSP channel was not held idle during reset");

  assert property (p_dat_idle_during_reset)
    else $error("vip_chi_sva: DAT channel was not held idle during reset");

  assert property (p_link_restarts_after_reset_release)
    else $error("vip_chi_sva: link activation did not restart after reset release");

  assert property (p_rni_completion_follows_req)
    else $error("vip_chi_sva: RN-I request did not observe a matching completion within TIMEOUT_CYCLES_P");

  assert property (p_snf_completion_follows_req)
    else $error("vip_chi_sva: SN-F-observed request did not drive a matching completion within TIMEOUT_CYCLES_P");

  assert property (p_rni_atomic_return_uses_dat_completion)
    else $error("vip_chi_sva: RN-I returning atomic observed a final RSP completion before CompData");

  assert property (p_snf_atomic_return_uses_dat_completion)
    else $error("vip_chi_sva: SN-F returning atomic drove a final RSP completion before CompData");

  assert property (p_rni_ordered_read_receipt_before_dat)
    else $error("vip_chi_sva: RN-I ordered read completion arrived before ReadReceipt");

  assert property (p_snf_ordered_read_receipt_before_dat)
    else $error("vip_chi_sva: SN-F ordered read drove DAT completion before ReadReceipt");

  assert property (p_link_deactivate_when_idle)
    else $error("vip_chi_sva: link entered DEACTIVATE while transmit activity was still present");

  assert property (p_txsactive_covers_outstanding)
    else $error("vip_chi_sva: TXSACTIVE was low with transactions still outstanding");

  assert property (p_txsactive_deassert_bounded)
    else $error("vip_chi_sva: TXSACTIVE stayed asserted with nothing outstanding and no flit on any channel");

endmodule

`endif
