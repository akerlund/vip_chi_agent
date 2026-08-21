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
  // More than one requester's traffic converges on this link. The TxnID-reuse
  // shadow is indexed by TxnID alone, so it cannot hold two sources' claims on
  // the same value at once -- and IHI 0050 E section 2.5 makes that a legal
  // situation ("unique for a given Requester. The Requester is identified by the
  // SrcID"). Scoping the rule by SrcID, done below, removes the systematic false
  // report; what remains is that the shadow is lossy, so on a genuinely
  // multi-source link the rule stands down and says so through enabled=0 rather
  // than reporting on state it cannot keep. See F-CHK-018 for the rework.
  parameter bit            MULTI_SOURCE_LINK_P         = 1'b0,
  // This endpoint drives TXSACTIVE from link-up rather than from its outstanding
  // window, so the sideband is a constant for as long as the link is up. That is
  // legal -- section 14.7.2's obligation is a lower bound and "may have" is
  // permissive -- but it is exactly what TXSACTIVE_DEASSERT_BOUNDED exists to
  // report, so the rule would fire on every run rather than on a defect. The
  // driver behavior is F-CORR-005 (box 1.6); until that lands, the binds on such
  // an endpoint stand the rule down explicitly.
  parameter bit            TXSACTIVE_FROM_LINK_UP_P    = 1'b0,
  // This link is driven by a testcase directly, without the driver's credit and
  // FLITPEND machinery -- the A0 smoke link, whose whole job is to prove the
  // interface and the adapter carry a flit verbatim at a third geometry. It
  // raises FLITV with no preceding FLITPEND, consumes credit that was never
  // granted, and never retires the transaction it starts, so the flit-protocol
  // rules report facts about the testcase rather than about the VIP. They stand
  // down here; LASM, reset-idle, known-when-valid, link gating and the sideband
  // rules stay live, and those are the ones a third geometry is worth checking
  // for. This is the "bind or explicitly waive" choice of F-CHK-004, resolved as
  // a partial bind with the waived rules named.
  parameter bit            HAND_DRIVEN_LINK_P          = 1'b0,
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
    // The DAT channel may carry the beats of MORE THAN ONE transfer between one
    // FLITPEND assertion and the next -- the completer is interleaving them (see
    // vip_chi_cfg_agent::dat_interleave_depth). CHI permits this: a DAT flit
    // names its transaction in TxnID and its position in DataID, and nothing
    // requires a transfer's beats to be contiguous on the channel.
    //
    // What stands down is exactly the set of checks that read a FLITPEND run as
    // one transfer: TxnID stability across the run, the run's beat count, and
    // (with dat_reorder_allowed) the DataID-ordering pair. The bookkeeping that
    // retires a completed transfer does NOT stand down -- it is counted per
    // TxnID and stays correct either way, which is what keeps the outstanding /
    // TXSACTIVE checks armed on an interleaved link.
    input bit  dat_interleave_allowed,
    // Cycles a sender may keep TXSACTIVE asserted past the close of its
    // outstanding window (cfg_agent.txsactive_extend_max_cycles). An input
    // rather than a parameter, like dat_reorder_allowed above and for the same
    // reason: a testcase sets the knob at run time, and elaboration is over by
    // then.
    input int  txsactive_extend_max_cycles,
    // Cycles the LASM may dwell in ACTIVATE / DEACTIVATE before the link counts
    // as stuck. 0 = disabled, which is the default. Inputs rather than
    // parameters for the same reason as the two above: a testcase sets them at
    // run time and elaboration is over by then.
    //
    // These cover what the transaction-completion timeout cannot. A link stuck
    // coming up has no transaction in flight to time out, so without them the
    // run simply hangs -- and it hangs in the one place where no protocol rule
    // is being violated on any cycle, only the absence of progress.
    input int  link_activation_timeout_cycles,
    input int  link_deactivation_timeout_cycles
  );

  typedef vip_chi_types #(CFG_P)::txn_id_t     txn_id_t;
  typedef vip_chi_types #(CFG_P)::data_id_t    data_id_t;
  typedef vip_chi_types #(CFG_P)::req_opcode_t req_opcode_t;
  typedef vip_chi_types #(CFG_P)::rsp_opcode_t rsp_opcode_t;
  typedef vip_chi_types #(CFG_P)::dat_opcode_t dat_opcode_t;
  typedef vip_chi_types #(CFG_P)::size_t       size_t;
  typedef vip_chi_types #(CFG_P)::node_id_t    node_id_t;
  // Through FLIT_TYPES_T, not through vip_chi_types #(CFG_P): the interface
  // declares txreqflit with the ISSUE-SPECIFIC type, so a CHI-D bind's REQ flit
  // genuinely has no TagOp or GroupIDExt member and naming one here would fail
  // elaboration rather than read zero.
  typedef FLIT_TYPES_T::vip_chi_req_flit_t     req_flit_t;

  localparam int TXN_ID_COUNT_C = 2 ** $bits(txn_id_t);
  // The protocol maximum, not a shadow-counter bound. IHI 0050 E 14.2.1 /
  // D 13.2.1: "The minimum number of L-Credits that a receiver can provide is
  // one. The maximum number of L-Credits that a receiver can provide is 15."
  // One LCRDV signal per channel, so the bound is per channel.
  //
  // This was 64, which is not a number the specification contains. At 64 the
  // overflow rule could not fire on any conformant-looking peer -- a receiver
  // granting 16 through 64 credits was over-granting and reported as fine, so
  // the rule was a false NEGATIVE rather than a false alarm. 15 is the value
  // that makes it a protocol check.
  localparam int unsigned LCRD_MAX_C = 15;
  localparam int unsigned REQ_SEND_CAP_C = LCRD_MAX_C;
  localparam int unsigned RSP_SEND_CAP_C = LCRD_MAX_C;
  localparam int unsigned DAT_SEND_CAP_C = LCRD_MAX_C;
  // Which end of a link this bind sits on, which is what decides whether a
  // request arrives on rxreq or leaves on txreq. Every transaction-level rule
  // below is gated on one of these two, so a role in NEITHER set leaves a bind
  // checking the structural rules only -- enabled, reporting, and silent on
  // everything that needs a transaction.
  //
  // HN-I is a completer, and the interface says so in as many words: its
  // RN-facing clocking block "mirrors snf_cb verbatim" because "a home node sits
  // between an RN and an SN, so on the link that faces the RN it plays the
  // completer/subordinate role". Its SN-FACING ports are separate interfaces
  // declared ROLE_P=RNI, so they land in the requester set on their own. Leaving
  // HN-I out of both sets is what made the proxy topology's RN-facing binds
  // structural-only when they were first added.
  localparam bit ROLE_IS_REQUESTER_C =
    (ROLE_P == VIP_CHI_ROLE_RNI_E) || (ROLE_P == VIP_CHI_ROLE_RNF_E);
  localparam bit ROLE_IS_COMPLETER_C =
    (ROLE_P == VIP_CHI_ROLE_SNF_E) || (ROLE_P == VIP_CHI_ROLE_HNF_E) ||
    (ROLE_P == VIP_CHI_ROLE_HNI_E);

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

  // May a flit go out in the current link state?
  //
  // RUN is the ordinary answer. DEACTIVATE is the exception, and it exists for
  // exactly one kind of flit: a sender that has been asked to bring the link
  // down must first hand back every L-credit it holds, and the only way to hand
  // one back is to send a flit under it. Refusing all traffic in DEACTIVATE
  // would therefore make a clean tear-down impossible -- the credits would be
  // stranded and VIP_CHI_CHK_LCRD_QUIESCENT_IN_STOP_E would fire on a link that
  // did everything right.
  //
  // Anything OTHER than an L-credit return is still a violation there, which is
  // what keeps the exception narrow: it admits the one flit the tear-down needs
  // and nothing else.
  function automatic bit flit_send_allowed(input bit is_lcrd_return);
    if (link_lasm() == VIP_CHI_LASM_RUN_E) begin
      return 1'b1;
    end
    return (link_lasm() == VIP_CHI_LASM_DEACTIVATE_E) && is_lcrd_return;
  endfunction

  function automatic bit tx_req_is_lcrd_return();
    return (req_opcode_t'(vif.txreqflit.opcode) == req_opcode_t'(VIP_CHI_REQ_LCRD_RETURN_C));
  endfunction

  function automatic bit tx_rsp_is_lcrd_return();
    return (rsp_opcode_t'(vif.txrspflit.opcode) == rsp_opcode_t'(VIP_CHI_RSP_LCRD_RETURN_C));
  endfunction

  function automatic bit tx_dat_is_lcrd_return();
    return (dat_opcode_t'(vif.txdatflit.opcode) == dat_opcode_t'(VIP_CHI_DAT_LCRD_RETURN_C));
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
  // lasm_dwell counts cycles held in the current state, which is what the two
  // link timeouts below measure. A state machine that cannot say HOW LONG it has
  // been somewhere can only report a wrong transition, never a missing one --
  // and a link that never leaves ACTIVATE is precisely a missing one.
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
            (opcode == VIP_CHI_REQ_MAKE_READ_UNIQUE_C) ||
            (opcode == req_opcode_t'(VIP_CHI_REQ_READ_ONCE_C)));
  endfunction

  function automatic bit req_opcode_is_coherent_write_data(input req_opcode_t opcode);
    return ((opcode == req_opcode_t'(VIP_CHI_REQ_WRITE_BACK_FULL_C)) ||
            (opcode == req_opcode_t'(VIP_CHI_REQ_WRITE_CLEAN_FULL_C)) ||
            (opcode == req_opcode_t'(VIP_CHI_REQ_WRITE_UNIQUE_FULL_C)) ||
            (opcode == req_opcode_t'(VIP_CHI_REQ_WRITE_UNIQUE_PTL_C)) ||
            // WriteEvictOrEvict is a CopyBack whose data is CONDITIONAL: the home asks for it with CompDBIDResp or declines with a bare Comp.
            // Listing it here is still right, and the conditionality takes care of itself -- the burst-length check arms only when a DBID is granted, which is exactly the leg that carries data.
            (opcode == VIP_CHI_REQ_WRITE_EVICT_OR_EVICT_C));
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
        chk_miss(VIP_CHI_CHK_LCRD_OVERFLOW_E, $sformatf("%s L-credit grant overflowed the tracked count", chan));
      end
      else begin
        chk_hit(VIP_CHI_CHK_LCRD_OVERFLOW_E);
        nxt = nxt + 1;
      end
    end
    if (consume) begin
      if (nxt == 0) begin
        chk_miss(VIP_CHI_CHK_LCRD_UNDERFLOW_E, $sformatf("%s L-credit consumed with no credit available (underflow)", chan));
      end
      else begin
        chk_hit(VIP_CHI_CHK_LCRD_UNDERFLOW_E);
        nxt = nxt - 1;
      end
    end
    return nxt;
  endfunction

  function automatic int unsigned txn_id_to_index(input txn_id_t txn_id);
    return txn_id;
  endfunction

  // Expected read-completion shape per TxnID, recorded when the request is seen.
  // Declared here, ahead of the rest of the tracking state further down, because
  // dat_transfer_last_beat() below reads them.
  int unsigned expected_completion_beats_by_txn[TXN_ID_COUNT_C];
  dat_opcode_t  expected_completion_opcode_by_txn[TXN_ID_COUNT_C];
  bit expected_completion_valid_by_txn[TXN_ID_COUNT_C];

  // Read-completion DAT beats seen so far, counted PER TRANSFER rather than per
  // FLITPEND run. The run is not necessarily one transfer: a completer may
  // interleave the beats of several reads on one DAT channel (see
  // vip_chi_cfg_agent::dat_interleave_depth), and the burst tracker further down
  // -- which follows the run -- would then retire only whichever transfer
  // happened to send the run's last beat, leaving every other one outstanding
  // forever. That surfaces at the end of the test as a TXSACTIVE failure, with
  // nothing to point at the data. Counting by TxnID retires each transfer on its
  // own last beat, which on contiguous traffic is the very beat the run ends at.
  int unsigned txdat_beats_by_txn[TXN_ID_COUNT_C];
  int unsigned rxdat_beats_by_txn[TXN_ID_COUNT_C];

  function automatic bit req_has_modeled_completion(input req_opcode_t opcode);
    case (VIP_CHI_MAX_REQ_OPCODE_WIDTH_C'(opcode))
      VIP_CHI_REQ_READ_NO_SNP_C,
      VIP_CHI_REQ_READ_NO_SNP_SEP_C,
      VIP_CHI_REQ_WRITE_NO_SNP_PTL_C,
      VIP_CHI_REQ_WRITE_NO_SNP_FULL_C,
      VIP_CHI_REQ_WRITE_NO_SNP_ZERO_C,
      // WriteUniqueZero is the snoopable twin of WriteNoSnpZero and completes
      // the same way, with a bare Comp. Naming only one of the pair left every
      // rule gated on this function standing down for the other -- TxnID reuse
      // and the completion timeout, in both ports -- for an opcode that ships
      // with its own sequence, testcase and completer service routine.
      VIP_CHI_REQ_WRITE_UNIQUE_ZERO_C,
      VIP_CHI_REQ_CLEAN_SHARED_PERSIST_C,
      VIP_CHI_REQ_CLEAN_SHARED_PERSIST_SEP_C: begin
        return 1'b1;
      end
      default: begin
        // The combined Write + CMO family completes exactly as its plain write
        // half does, and it ships with sequences, a testcase and a completer
        // service routine -- so leaving it out stood the TxnID-reuse rules and
        // the completion timeout down for six opcodes the regression drives. The
        // same omission the WriteUniqueZero comment above records, for a family
        // rather than for one opcode. It stayed invisible because
        // check_classifier_coverage saw the six claimed by is_write_req_opcode,
        // a classifier that answered a question about ExpCompAck and nothing
        // about completions; the six surfaced the moment that function was
        // deleted.
        return req_opcode_is_coherent_read(opcode) ||
               req_opcode_is_coherent_write_data(opcode) ||
               req_opcode_is_coherent_rsp_only(opcode) ||
               vip_chi_types_pkg::vip_chi_req_opcode_is_combined_write_cmo(
                 vip_chi_req_opcode_t'(opcode)) ||
               vip_chi_types_pkg::vip_chi_req_opcode_is_atomic(
                 vip_chi_req_opcode_t'(opcode));
      end
    endcase
  endfunction

  function automatic bit req_completion_uses_dat(input req_opcode_t opcode);
    return ((opcode == VIP_CHI_REQ_READ_NO_SNP_C) ||
            (opcode == VIP_CHI_REQ_READ_NO_SNP_SEP_C) ||
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

  // TRUE when the DAT beat on the wire this cycle is the LAST one of its own
  // transfer.
  //
  // The FLITPEND deassert used to answer this on its own, and on contiguous
  // traffic it still does -- the transfer's last beat is the run's last beat.
  // It stops answering it the moment a completer interleaves transfers, because
  // FLITPEND then says the CHANNEL has more to send, not that THIS transfer
  // does. Counting the transfer's own beats is the reading that holds either
  // way; the FLITPEND fallback covers a transfer with no request on record,
  // where there is no expected count to compare against.
  function automatic bit dat_transfer_last_beat(
    input bit      is_rx,
    input txn_id_t completion_txn_id
  );
    int unsigned idx;

    idx = txn_id_to_index(completion_txn_id);
    if (!expected_completion_valid_by_txn[idx]) begin
      return is_rx ? !vif.rxdatflitpend : !vif.txdatflitpend;
    end

    return (((is_rx ? rxdat_beats_by_txn[idx] : txdat_beats_by_txn[idx]) + 1) >=
            expected_completion_beats_by_txn[idx]);
  endfunction

  function automatic bit rni_final_completion_observed(
    input req_opcode_t opcode,
    input txn_id_t     req_txn_id,
    input txn_id_t     completion_txn_id
  );
    if (req_completion_uses_dat(opcode)) begin
      return (vif.rxdatflitv &&
              (txn_id_t'(vif.rxdatflit.txnid) == completion_txn_id) &&
              dat_transfer_last_beat(1'b1, completion_txn_id) &&
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
      return (vif.txdatflitv &&
              (txn_id_t'(vif.txdatflit.txnid) == completion_txn_id) &&
              dat_transfer_last_beat(1'b0, completion_txn_id) &&
              (dat_opcode_t'(vif.txdatflit.opcode) == expected_completion_dat_opcode(opcode)));
    end

    return (vif.txrspflitv &&
            (txn_id_t'(vif.txrspflit.txnid) == req_txn_id) &&
            is_final_rsp_completion(opcode, rsp_opcode_t'(vif.txrspflit.opcode)));
  endfunction

  function automatic bit is_write_dat_opcode(input dat_opcode_t opcode);
    return ((opcode == dat_opcode_t'(VIP_CHI_DAT_NON_COPY_BACK_WR_DATA_C)) ||
            (opcode == dat_opcode_t'(VIP_CHI_DAT_NCB_WR_DATA_COMP_ACK_C)) ||
            (opcode == dat_opcode_t'(VIP_CHI_DAT_COPY_BACK_WR_DATA_C)));
  endfunction

  // ---------------------------------------------------------------------------
  // Appendix A Table A-4 field legality, for the fields the table marks zero.
  //
  // Table A-1 gives the vocabulary and the distinction that matters here:
  //
  //   0     the field is applicable but must be set to zero
  //   0 a   the field is INAPPLICABLE to this message and must be set to zero
  //   Y     applicable, carries a value -- nothing to assert
  //   -     not applicable, and NOT required to be zero -- asserting on it is a
  //         false positive waiting for stimulus
  //   X     don't care -- likewise not assertable
  //
  // Only `0` and `0 a` are assertable, and they impose the same obligation, so
  // the three lists below merge them. `-` and `X` are deliberately absent: that
  // is why Persist.DBID, which A-4 marks `-`, is not checked even though the
  // driver copies the request's TxnID into it.
  //
  // Source: IHI0050E_a, Table A-4 Response message field mappings, page A-469.
  //
  // Two opcodes A-4 also marks are absent below because this VIP does not model
  // them, and a rule may not name an opcode that has no constant:
  //
  //   StashDone  TxnID = 0 a   Stash is excluded from this VIP by declaration
  //   TagMatch   TxnID = 0 a   Add to rsp_a4_txnid_is_zero_field below when
  //                            VIP_CHI_RSP_TAG_MATCH_C (5'h0A) is introduced.
  //                            TagMatch is a response to a request and so is
  //                            naturally built by copying the request's TxnID,
  //                            which this rule forbids.
  // ---------------------------------------------------------------------------
  function automatic bit rsp_a4_txnid_is_zero_field(input rsp_opcode_t opcode);
    return ((opcode == VIP_CHI_RSP_PERSIST_C) ||
            (opcode == VIP_CHI_RSP_PCRD_GRANT_C));
  endfunction

  function automatic bit rsp_a4_resperr_is_zero_field(input rsp_opcode_t opcode);
    // A-4's RespErr column reads `0` for exactly these six: none of them carries
    // error status. The completion that DOES carry it for a write is
    // CompDBIDResp (RespErr = Y), which is why a completer must not copy its
    // buffer grant's RespErr onto the completion, or the reverse.
    return ((opcode == VIP_CHI_RSP_COMP_ACK_C)     ||
            (opcode == VIP_CHI_RSP_RETRY_ACK_C)    ||
            (opcode == VIP_CHI_RSP_PCRD_GRANT_C)   ||
            (opcode == VIP_CHI_RSP_READ_RECEIPT_C) ||
            (opcode == VIP_CHI_RSP_DBID_RESP_C)    ||
            (opcode == VIP_CHI_RSP_DBID_RESP_ORD_C));
  endfunction

  // A-4 lists DBID, TagGroupID, StashGroupID and PGroupID as four NAMES over one
  // shared group of packet bits; the table header brackets them under a single
  // `CF` (combined field) marker. Most rows mark each name separately. PCrdGrant
  // instead carries one `0 a` spanning the whole group, which marks the shared
  // field as a whole inapplicable and required to be zero.
  //
  // Only DBID is asserted here: it is the only one of the four names this VIP
  // models on the RSP flit. Persist is deliberately absent -- A-4 gives Persist
  // DBID `-`, not applicable and NOT required to be zero, which is why the
  // driver may legally put the request's TxnID there.
  function automatic bit rsp_a4_dbid_is_zero_field(input rsp_opcode_t opcode);
    return (opcode == VIP_CHI_RSP_PCRD_GRANT_C);
  endfunction

  function automatic bit rsp_a4_resp_is_zero_field(input rsp_opcode_t opcode);
    // Everything in the RespErr set above, plus two more. CompDBIDResp is the
    // one A-4 marks plain `0` rather than `0 a`, and section 4 says why in
    // words: "The Resp field of a Comp or CompDBIDResp response must be set to
    // zero for a Write transaction completion" -- cache state travels on the
    // WriteData, not on the completion. Persist is `0 a`.
    //
    // Comp is NOT here. A-4 gives it Resp = Y, because the same opcode completes
    // reads and dataless transactions where the field carries cache state.
    return (rsp_a4_resperr_is_zero_field(opcode) ||
            (opcode == VIP_CHI_RSP_COMP_DBID_RESP_C) ||
            (opcode == VIP_CHI_RSP_PERSIST_C));
  endfunction

  // Does A-4 mark ANY field zero for this opcode? This is the rule's antecedent
  // and must stay out of its body. Folded into the consequent instead, every
  // Comp, CompData grant and SnpResp on the link would count as a pass for a
  // rule that never applied to it: the tally would report thousands of hits and
  // the vacuity report would call the rule exercised, while the opcodes it
  // actually governs might never have been driven.
  function automatic bit rsp_a4_has_zero_field(input rsp_opcode_t opcode);
    return (rsp_a4_txnid_is_zero_field(opcode)   ||
            rsp_a4_resperr_is_zero_field(opcode) ||
            rsp_a4_resp_is_zero_field(opcode)    ||
            rsp_a4_dbid_is_zero_field(opcode));
  endfunction

  // The opcode constants are compared BARE, with no cast down to rsp_opcode_t.
  // That type is 4 bits in CHI-D and 5 in CHI-E, so a cast would silently alias
  // any constant above 0x0F onto another opcode -- CompCMO (5'h14) becomes
  // Comp (4'h4). Everything named here happens to fit in four bits today, which
  // is exactly why a cast would look correct until TagMatch or CompCMO joined
  // the list. Bare comparison zero-extends the narrower operand and is right in
  // both issues, permanently.
  function automatic bit rsp_a4_zero_fields_legal(
    input rsp_opcode_t opcode,
    input txn_id_t     txnid,
    input logic [1:0]  resperr,
    input logic [2:0]  resp,
    input txn_id_t     dbid
  );
    // X is not this rule's business. p_rsp_known_when_valid already fails an
    // unknown flit under its own ID; without this guard an X in any of the four
    // fields would fail here too, reporting a field-legality defect for what is
    // really an X-propagation one and charging it to the wrong check.
    if ($isunknown({opcode, txnid, resperr, resp, dbid})) return 1'b1;
    if (rsp_a4_txnid_is_zero_field(opcode)   && (txnid   !== '0)) return 1'b0;
    if (rsp_a4_resperr_is_zero_field(opcode) && (resperr !== '0)) return 1'b0;
    if (rsp_a4_resp_is_zero_field(opcode)    && (resp    !== '0)) return 1'b0;
    if (rsp_a4_dbid_is_zero_field(opcode)    && (dbid    !== '0)) return 1'b0;
    return 1'b1;
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

    // The combined Write + CMO family carries the write half's data burst like
    // any other write. Omitting it returned zero beats, which cleared
    // expected_write_valid_by_dbid and stood the write-burst length checks down
    // for all six forms -- they passed by never being asked.
    if (vip_chi_types_pkg::vip_chi_req_opcode_is_atomic(
          vip_chi_req_opcode_t'(opcode)) ||
        (opcode == req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_PTL_C)) ||
        (opcode == req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_FULL_C)) ||
        vip_chi_types_pkg::vip_chi_req_opcode_is_combined_write_cmo(
          vip_chi_req_opcode_t'(opcode)) ||
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
  // "A completion this TxnID's CompAck may acknowledge has been seen." It used
  // to be write-only, in both senses: only writes recorded one, and only writes
  // could reach it. Section 2.8.3 rule 1 names three ways a read arrives at the
  // same point -- "an RN-F sends a CompAck after receiving Comp, RespSepData or
  // CompData, or both RespSepData and DataSepResp" -- so a read completion sets
  // it as well now.
  bit completion_seen_by_txn[TXN_ID_COUNT_C];
  bit write_grant_seen_by_dbid[TXN_ID_COUNT_C];
  int unsigned expected_write_beats_by_txn[TXN_ID_COUNT_C];
  int unsigned expected_write_beats_by_dbid[TXN_ID_COUNT_C];
  bit expected_write_valid_by_dbid[TXN_ID_COUNT_C];
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
  // Which SrcID owns the TxnID currently occupying each slot.
  //
  // IHI 0050 E section 2.5 scopes the uniqueness rule to a source and says so
  // twice over: "It is required that the TxnID, except for PrefetchTgt, must be
  // unique for a given Requester. The Requester is identified by the SrcID."
  // Two requests carrying the same TxnID from DIFFERENT SrcIDs are therefore
  // legal and ordinary -- and unavoidable on a link where more than one
  // requester's traffic converges, because each allocates from its own pool.
  //
  // Without this the reuse rules read the spec as "unique per link", which is a
  // stricter rule than the one written. It went unnoticed because no bind sat on
  // a fan-in link: the integrated topology is one requester to one completer, and
  // the coherent binds sit at the RN-F ends, one source each. The proxy's
  // SN-facing links, bound for the first time by box 0.3, carry two.
  node_id_t req_src_by_txn[TXN_ID_COUNT_C];
  bit       req_src_valid_by_txn[TXN_ID_COUNT_C];

  // Which TxnIDs a request has actually put on the wire, tracked SEPARATELY from
  // req_inflight_by_txn and deliberately so.
  //
  // req_inflight_by_txn is set only for req_has_modeled_completion's opcodes,
  // because what it exists for is pairing a request with the completion that
  // retires it. RETRY_ACK_TXN_ID asks a different question -- did any request
  // carry this TxnID -- and gating it on that whitelist would make a RetryAck for
  // a coherent read unjudgeable rather than judged, which is the shape of failure
  // the total-classifier rule exists to prevent.
  //
  // Cleared on the RetryAck that consumes it and nowhere else. That leaves the
  // rule blind to a stray RetryAck naming a TxnID whose transaction completed
  // normally, and blind is the right direction: the alternative is a clear in
  // every completion arm, and a slot cleared one cycle early would false-fail
  // the legitimate RetryAck that a permissive rule simply misses.
  bit       req_txn_id_seen_by_txn[TXN_ID_COUNT_C];

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

  // P-Credits this link has seen granted and not yet seen spent, per PCrdType,
  // with the same blocking-accumulator shape as req_outstanding_delta above and
  // for the same reason: a grant can land in the cycle a credit is spent, and
  // two read-modify-writes would both read the same stale value.
  //
  // Counted rather than flagged because section 2.6.5 is explicit that "there is
  // no fixed relationship between credits and particular transactions" -- a
  // requester holding several grants of one type picks freely which bounced
  // transaction to re-issue against which. A count is the most the wire
  // supports, and it is enough: a request spending a credit nobody granted is
  // visible in it, and that is the violation.
  int unsigned pcrd_held_by_type[2 ** VIP_CHI_PCRD_TYPE_WIDTH_C];
  int          pcrd_delta_by_type[2 ** VIP_CHI_PCRD_TYPE_WIDTH_C];

  // The pool as of this cycle: the registered count plus whatever the
  // accumulator has already taken in. Reading the register alone would make a
  // grant invisible to a spend in the same cycle and false-fail it, which for a
  // rule this strict is the one direction that must not happen.
  function automatic int pcrd_available(input vip_chi_pcrd_type_t pcrd_type);
    return int'(pcrd_held_by_type[pcrd_type]) + pcrd_delta_by_type[pcrd_type];
  endfunction

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

  // The L-credit shadow, gated on RESET ONLY -- deliberately, and unlike every
  // other piece of tracked state here.
  //
  // Under the usual checks_enable gate these counters were cleared the moment
  // the link left RUN, which made p_lcrd_quiescent_in_stop unable to fail: the
  // gate zeroed the counts on the way into DEACTIVATE, so by the time the link
  // reached STOP the rule was asking whether zero equalled zero. The one rule
  // whose entire job is to catch credits stranded by a tear-down was blind to
  // every tear-down.
  //
  // Surviving the gap is also what makes the counts MEAN anything across it: a
  // credit granted before a link went down is exactly the credit that must not
  // still be banked after it, and a counter that forgets at the boundary cannot
  // say so. Only a reset clears them, because a reset is the one event that
  // genuinely discards both ends' state.
  always_ff @(posedge vif.clk or negedge vif.rst_n) begin
    if (!vif.rst_n) begin
      txreq_lcrd_count <= 0;
      txrsp_lcrd_count <= 0;
      txdat_lcrd_count <= 0;
      rxreq_lcrd_count <= 0;
      rxrsp_lcrd_count <= 0;
      rxdat_lcrd_count <= 0;
    end
    else begin
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
    end
  end

  always_ff @(posedge vif.clk or negedge vif.rst_n) begin
    if (!checks_enable || !vif.rst_n) begin
      for (int txn_i = 0; txn_i < TXN_ID_COUNT_C; txn_i++) begin
        req_exp_comp_ack_by_txn[txn_i]    <= 1'b0;
        completion_seen_by_txn[txn_i] <= 1'b0;
        write_grant_seen_by_dbid[txn_i]   <= 1'b0;
        expected_write_beats_by_txn[txn_i] <= 0;
        expected_write_beats_by_dbid[txn_i] <= 0;
        expected_write_valid_by_dbid[txn_i] <= 1'b0;
        expected_completion_beats_by_txn[txn_i] <= 0;
        expected_completion_opcode_by_txn[txn_i] <=
          dat_opcode_t'(VIP_CHI_DAT_COMP_DATA_C);
        expected_completion_valid_by_txn[txn_i] <= 1'b0;
        txdat_beats_by_txn[txn_i] <= 0;
        rxdat_beats_by_txn[txn_i] <= 0;
        req_inflight_by_txn[txn_i] <= 1'b0;
        req_src_valid_by_txn[txn_i] <= 1'b0;
        req_src_by_txn[txn_i]       <= '0;
        req_txn_id_seen_by_txn[txn_i] <= 1'b0;
        dat_completion_req_valid_by_txn[txn_i] <= 1'b0;
        dat_completion_req_txn_by_txn[txn_i] <= '0;
      end

      for (int unsigned pcrd_i = 0;
           pcrd_i < (2 ** VIP_CHI_PCRD_TYPE_WIDTH_C); pcrd_i++) begin
        pcrd_held_by_type[pcrd_i] <= 0;
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
    end
    else begin
      req_outstanding_delta = 0;
      for (int unsigned pcrd_i = 0;
           pcrd_i < (2 ** VIP_CHI_PCRD_TYPE_WIDTH_C); pcrd_i++) begin
        pcrd_delta_by_type[pcrd_i] = 0;
      end

      // A PCrdGrant credits the pool the requests on this link draw from,
      // whichever direction carries it: at a requester bind the grant arrives on
      // rxrsp, at a completer bind it leaves on txrsp, and one link has one
      // pool. Counted here rather than in the per-role response blocks further
      // down so that the spend checks below read a pool this cycle's grant is
      // already in -- section 2.6.5 permits a grant to arrive before the
      // RetryAck that owed it, so there is nothing else to pair it with.
      if (vif.rxrspflitv &&
          (rsp_opcode_t'(vif.rxrspflit.opcode) ==
           rsp_opcode_t'(VIP_CHI_RSP_PCRD_GRANT_C))) begin
        pcrd_delta_by_type[vif.rxrspflit.pcrdtype]++;
      end
      if (vif.txrspflitv &&
          (rsp_opcode_t'(vif.txrspflit.opcode) ==
           rsp_opcode_t'(VIP_CHI_RSP_PCRD_GRANT_C))) begin
        pcrd_delta_by_type[vif.txrspflit.pcrdtype]++;
      end

      if (ROLE_IS_REQUESTER_C) begin
        if (vif.txreqflitv) begin
          int unsigned txn_idx;
          int unsigned completion_idx;
          int unsigned beat_count;
          req_opcode_t req_opcode;

          req_opcode = req_opcode_t'(vif.txreqflit.opcode);
          txn_idx = txn_id_to_index(txn_id_t'(vif.txreqflit.txnid));
          // Not gated on req_has_modeled_completion: see the declaration.
          // ReqLCrdReturn and PCrdReturn are excluded because both are required
          // to drive TxnID zero, so marking slot 0 for them would leave the one
          // slot a real request can also use permanently unjudgeable.
          if ((req_opcode != req_opcode_t'(VIP_CHI_REQ_PCRD_RETURN_C)) &&
              (req_opcode != req_opcode_t'(VIP_CHI_REQ_LCRD_RETURN_C))) begin
            req_txn_id_seen_by_txn[txn_idx] <= 1'b1;
          end

          if (req_has_modeled_completion(req_opcode)) begin
            // Same SrcID reusing a live slot is the violation. A DIFFERENT SrcID
            // landing on the same slot is a pass, not a decline: section 2.5's
            // rule is satisfied outright, because the two requests are
            // distinguishable by the field the spec names.
            if (req_inflight_by_txn[txn_idx] && req_src_valid_by_txn[txn_idx] &&
                (req_src_by_txn[txn_idx] === node_id_t'(vif.txreqflit.srcid))) begin
              chk_miss(VIP_CHI_CHK_TXNID_REUSE_REQUESTER_E, $sformatf("requester reused a TxnID while the earlier request was still in flight"));
            end
            else begin
              chk_hit(VIP_CHI_CHK_TXNID_REUSE_REQUESTER_E);
            end
            if (!req_inflight_by_txn[txn_idx]) begin
              req_outstanding_delta++;
            end
            req_inflight_by_txn[txn_idx]  <= 1'b1;
            req_src_by_txn[txn_idx]       <= node_id_t'(vif.txreqflit.srcid);
            req_src_valid_by_txn[txn_idx] <= 1'b1;
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

        // Every request, not only writes. The write-only gate was correct for
        // exactly as long as ExpCompAck was unreachable on a read: the moment
        // Table 2-9 was implemented and the four coherent reads started setting
        // the bit, a read's CompAck would have arrived against a tracker that had
        // recorded nothing -- and COMPACK_WITHOUT_EXPCOMPACK would have fired on
        // every conformant coherent read in the regression.
        if (vif.txreqflitv) begin
          req_exp_comp_ack_by_txn[txn_id_to_index(txn_id_t'(vif.txreqflit.txnid))] <=
            vif.txreqflit.expcompack;
          completion_seen_by_txn[txn_id_to_index(txn_id_t'(vif.txreqflit.txnid))] <=
            1'b0;

          // Table 2-9's "Yes" column, checked from the requester's own vantage.
          // The role argument is a constant one: every opcode the table marks
          // required is an opcode only an RN-F may issue at all, so no ROLE_P
          // test is needed here -- a non-RN-F sending one of them is a different
          // violation, of the opcode legality rule rather than of this one.
          if (vip_chi_exp_comp_ack_required(
                vip_chi_req_opcode_t'(vif.txreqflit.opcode), 1'b1) &&
              !vif.txreqflit.expcompack) begin
            chk_miss(VIP_CHI_CHK_EXPCOMPACK_REQUIRED_BUT_ZERO_E, $sformatf("a request whose opcode requires CompAck was issued with ExpCompAck = 0"));
          end
          else begin
            chk_hit(VIP_CHI_CHK_EXPCOMPACK_REQUIRED_BUT_ZERO_E);
          end

          // Atomic operand Size against Table 2-17, from the sender's vantage.
          //
          // The classifier passes anything that is not an atomic, so this needs
          // no opcode-family gate: the rule reads "if this is an atomic, its Size
          // is one the table lists", and every other opcode records a pass
          // trivially. That is the same shape as the ExpCompAck rule above and it
          // is deliberate -- a rule that only evaluates for the family it judges
          // cannot distinguish "no atomic went by" from "the classifier forgot
          // this opcode", which is how the combined Write + CMO family went six
          // opcodes unclaimed.
          //
          // The wide-operand stress profile that vip_chi_atomic_seq records as a
          // deliberate decision violates this rule on purpose. Those testcases
          // turn it down to VIP_CHI_CHK_SEV_OFF_E rather than being exempted
          // here, for the reason the LASM illegal-transition test gives: OFF
          // still evaluates and still tallies, so the rule stays visible as
          // exercised-and-failing on exactly the links where the violation is
          // intended, instead of publishing enabled = 0 and reading as a rule
          // nothing ever reached.
          if (!vip_chi_types_pkg::vip_chi_atomic_size_legal(
                vip_chi_req_opcode_t'(vif.txreqflit.opcode),
                vif.txreqflit.size)) begin
            chk_miss(VIP_CHI_CHK_ATOMIC_SIZE_LEGAL_E, $sformatf(
              "atomic opcode 0x%0h was issued with Size %0d, which Table 2-17 does not permit for it",
              vif.txreqflit.opcode, vif.txreqflit.size));
          end
          else begin
            chk_hit(VIP_CHI_CHK_ATOMIC_SIZE_LEGAL_E);
          end

          // Order legality against Table 13-25 and Table 2-12 footnote a, from
          // the sender's vantage. The classifier passes anything it does not
          // object to, so this evaluates on every request and not only on the
          // ones carrying an ordered value -- the distinction between "no
          // ordered request went by" and "the classifier forgot this opcode" is
          // one a tally cannot make afterwards.
          if (!vip_chi_types_pkg::vip_chi_req_order_legal(
                vip_chi_req_opcode_t'(vif.txreqflit.opcode),
                vip_chi_req_order_t'(vif.txreqflit.order))) begin
            chk_miss(VIP_CHI_CHK_REQ_ORDER_LEGAL_E, $sformatf(
              "opcode 0x%0h was issued with Order 0b%02b, which the specification does not permit for it",
              vif.txreqflit.opcode, vif.txreqflit.order));
          end
          else begin
            chk_hit(VIP_CHI_CHK_REQ_ORDER_LEGAL_E);
          end

          // Table 2-12 as a whitelist. Total for the same reason as the rule
          // above: the table closes each of its two blocks with "All other
          // values -- Not valid", so a tuple outside the nine rows is a protocol
          // error and every request has a tuple to judge.
          if (!vip_chi_types_pkg::vip_chi_req_attr_combination_legal(
                vif.txreqflit.memattr,
                vip_chi_snp_attr_t'(vif.txreqflit.snpattr),
                vif.txreqflit.likelyshared,
                vip_chi_req_order_t'(vif.txreqflit.order))) begin
            chk_miss(VIP_CHI_CHK_REQ_ATTR_COMBINATION_LEGAL_E, $sformatf(
              "request was issued with MemAttr 0x%0h (Allocate %0b Cacheable %0b Device %0b EWA %0b), SnpAttr %0b, LikelyShared %0b and Order 0b%02b, a combination Table 2-12 does not list",
              vif.txreqflit.memattr, vif.txreqflit.memattr[3],
              vif.txreqflit.memattr[2], vif.txreqflit.memattr[1],
              vif.txreqflit.memattr[0], vif.txreqflit.snpattr,
              vif.txreqflit.likelyshared, vif.txreqflit.order));
          end
          else begin
            chk_hit(VIP_CHI_CHK_REQ_ATTR_COMBINATION_LEGAL_E);
          end

          // Table 2-14's per-opcode SnpAttr requirement, which the tuple rule
          // above cannot express: Table 2-12 says which combinations are legal,
          // Table 2-14 says which of them this opcode may use. A coherent request
          // marked Non-snoopable satisfies the tuple rule and is still wrong.
          // Judged only where the bit IS SnpAttr. Under Issue E the same bit is
          // DoDWT on WriteNoSnpFull, WriteNoSnpPtl and Combined Write, and a
          // conformant DoDWT = 1 there puts a one on the wire that is not an
          // SnpAttr claim at all. The specification separates the two by role --
          // DoDWT is applicable only from Home to Slave -- which a bind cannot
          // establish, so on those opcodes the rule has nothing to falsify and
          // says so by passing rather than by not evaluating.
          if (vip_chi_types_pkg::vip_chi_req_bit17_is_dodwt(
                CFG_P.ISSUE_P, vip_chi_req_opcode_t'(vif.txreqflit.opcode))) begin
            chk_hit(VIP_CHI_CHK_REQ_SNP_ATTR_LEGAL_E);
          end
          else if ((vip_chi_types_pkg::vip_chi_snp_attr_requirement(
                      vip_chi_req_opcode_t'(vif.txreqflit.opcode)) ==
                    vip_chi_types_pkg::VIP_CHI_SNP_ATTR_ONE_E) &&
                   (vif.txreqflit.snpattr != VIP_CHI_SNP_SNOOPABLE_E)) begin
            chk_miss(VIP_CHI_CHK_REQ_SNP_ATTR_LEGAL_E, $sformatf(
              "opcode 0x%0h was issued Non-snoopable, and Table 2-14 lists it as Snoopable only",
              vif.txreqflit.opcode));
          end
          else if ((vip_chi_types_pkg::vip_chi_snp_attr_requirement(
                      vip_chi_req_opcode_t'(vif.txreqflit.opcode)) ==
                    vip_chi_types_pkg::VIP_CHI_SNP_ATTR_ZERO_E) &&
                   (vif.txreqflit.snpattr != VIP_CHI_SNP_NON_SNOOPABLE_E)) begin
            chk_miss(VIP_CHI_CHK_REQ_SNP_ATTR_LEGAL_E, $sformatf(
              "opcode 0x%0h was issued Snoopable, and Table 2-14 lists it as Non-snoopable only",
              vif.txreqflit.opcode));
          end
          else begin
            chk_hit(VIP_CHI_CHK_REQ_SNP_ATTR_LEGAL_E);
          end

          // Section 2.9.5's LikelyShared whitelist. Narrower than the tuple rule
          // above, which only knows the table's "LikelyShared implies Snoopable":
          // this also faults the six Snoopable-only opcodes the section excludes.
          if (vif.txreqflit.likelyshared &&
              !vip_chi_types_pkg::vip_chi_req_likely_shared_permitted(
                 vip_chi_req_opcode_t'(vif.txreqflit.opcode))) begin
            chk_miss(VIP_CHI_CHK_REQ_LIKELY_SHARED_LEGAL_E, $sformatf(
              "opcode 0x%0h was issued with LikelyShared asserted, which section 2.9.5 does not permit for it",
              vif.txreqflit.opcode));
          end
          else begin
            chk_hit(VIP_CHI_CHK_REQ_LIKELY_SHARED_LEGAL_E);
          end

          // Table A-3 fixes Size at 64 bytes for every coherent read, dataless
          // and CopyBack opcode, and for the full writes. Size = 0b110 is 64
          // bytes (Table 2-15), independent of the data bus width.
          if (vip_chi_types_pkg::vip_chi_req_size_fixed_64b(
                vip_chi_req_opcode_t'(vif.txreqflit.opcode)) &&
              (vif.txreqflit.size != VIP_CHI_REQ_SIZE_64B_C)) begin
            chk_miss(VIP_CHI_CHK_REQ_SIZE_LEGAL_E, $sformatf(
              "opcode 0x%0h was issued with Size 0b%03b, and Table A-3 fixes its Size at 64 bytes (0b110)",
              vif.txreqflit.opcode, vif.txreqflit.size));
          end
          else begin
            chk_hit(VIP_CHI_CHK_REQ_SIZE_LEGAL_E);
          end

          // Section 6.3's closed list of transactions that support an Exclusive
          // access. Excl on anything else is not a weaker guarantee, it is a bit
          // the receiver has no defined behavior for.
          if (vif.txreqflit.excl != VIP_CHI_REQ_NORMAL_E &&
              !vip_chi_types_pkg::vip_chi_req_excl_permitted(
                 vip_chi_req_opcode_t'(vif.txreqflit.opcode))) begin
            chk_miss(VIP_CHI_CHK_REQ_EXCL_LEGAL_E, $sformatf(
              "opcode 0x%0h was issued with Excl asserted, and section 6.3 does not list it as supporting Exclusive accesses",
              vif.txreqflit.opcode));
          end
          else begin
            chk_hit(VIP_CHI_CHK_REQ_EXCL_LEGAL_E);
          end

          // Table A-3's Endian column: applicable on the Atomics only. Endian
          // selects an Atomic operand's byte order and has nothing to say about a
          // plain read or write, which the table states as must-be-zero rather
          // than as free.
          if (vif.txreqflit.endian &&
              !vip_chi_types_pkg::vip_chi_req_endian_applicable(
                 vip_chi_req_opcode_t'(vif.txreqflit.opcode))) begin
            chk_miss(VIP_CHI_CHK_REQ_ENDIAN_LEGAL_E, $sformatf(
              "opcode 0x%0h was issued with Endian asserted, and Table A-3 makes the field inapplicable outside an Atomic",
              vif.txreqflit.opcode));
          end
          else begin
            chk_hit(VIP_CHI_CHK_REQ_ENDIAN_LEGAL_E);
          end

          // ReturnNID and ReturnTxnID are inapplicable and must be zero outside
          // the request sets IHI 0050 E 13.10.4 / 13.10.15 name, and the two sets
          // differ: CleanSharedPersistSep may carry a ReturnNID and must not
          // carry a ReturnTxnID, because a separated persist gets an RSP rather
          // than data. Folded into ONE check id because it is one obligation --
          // the return path is not in use, so neither half of it may be set --
          // and a user standing it down wants both halves quiet.
          if ((vif.txreqflit.returnnid != '0) &&
              !vip_chi_types_pkg::vip_chi_req_return_nid_applicable(
                 vip_chi_req_opcode_t'(vif.txreqflit.opcode))) begin
            chk_miss(VIP_CHI_CHK_REQ_RETURN_PATH_LEGAL_E, $sformatf(
              "opcode 0x%0h was issued with ReturnNID 0x%0h, and section 13.10.4 makes the field inapplicable and zero for it",
              vif.txreqflit.opcode, vif.txreqflit.returnnid));
          end
          else if ((vif.txreqflit.returntxnid != '0) &&
                   !vip_chi_types_pkg::vip_chi_req_return_txn_id_applicable(
                      vip_chi_req_opcode_t'(vif.txreqflit.opcode))) begin
            chk_miss(VIP_CHI_CHK_REQ_RETURN_PATH_LEGAL_E, $sformatf(
              "opcode 0x%0h was issued with ReturnTxnID 0x%0h, and section 13.10.15 makes the field inapplicable and zero for it",
              vif.txreqflit.opcode, vif.txreqflit.returntxnid));
          end
          else begin
            chk_hit(VIP_CHI_CHK_REQ_RETURN_PATH_LEGAL_E);
          end

          // The other half of Table 2-9, which nothing checked: the table marks
          // ExpCompAck prohibited on a whole class of requests, and until now only
          // the required-but-zero direction was reported. Table A-3's ExpCompAck
          // column agrees, giving "0" on every opcode the requirement function
          // classifies as prohibited.
          //
          // The role argument is a constant one for the same reason the required
          // direction uses it, read the other way round: passing RN-F shrinks the
          // prohibited set, because the opcodes an RN-F may acknowledge are
          // exactly the ones lifted out of it. That is the under-reporting
          // direction, which is what a rule on every request should prefer.
          if (vif.txreqflit.expcompack &&
              vip_chi_types_pkg::vip_chi_exp_comp_ack_prohibited(
                vip_chi_req_opcode_t'(vif.txreqflit.opcode),
                1'b1)) begin
            chk_miss(VIP_CHI_CHK_EXPCOMPACK_PROHIBITED_BUT_SET_E, $sformatf(
              "opcode 0x%0h was issued with ExpCompAck asserted, and Table 2-9 prohibits the bit for it",
              vif.txreqflit.opcode));
          end
          else begin
            chk_hit(VIP_CHI_CHK_EXPCOMPACK_PROHIBITED_BUT_SET_E);
          end

          // Section 2.9.4's first-attempt rule, read through the credit pool. A
          // request with AllowRetry deasserted is claiming to spend a
          // pre-allocated P-Credit, so this link must have seen a PCrdGrant of
          // that PCrdType that is still unspent.
          //
          // PrefetchTgt is exempt because section 2.9.4 REQUIRES its AllowRetry
          // deasserted and it needs no credit; ReqLCrdReturn carries no
          // transaction at all; PCrdReturn spends without being judged, for the
          // reason given at the check id.
          if (!vif.txreqflit.allowretry &&
              (req_opcode_t'(vif.txreqflit.opcode) !=
                 req_opcode_t'(VIP_CHI_REQ_PREFETCH_TGT_C)) &&
              (req_opcode_t'(vif.txreqflit.opcode) !=
                 req_opcode_t'(VIP_CHI_REQ_LCRD_RETURN_C)) &&
              (req_opcode_t'(vif.txreqflit.opcode) !=
                 req_opcode_t'(VIP_CHI_REQ_PCRD_RETURN_C))) begin
            if (pcrd_available(vif.txreqflit.pcrdtype) == 0) begin
              chk_miss(VIP_CHI_CHK_REQ_RETRY_SPENDS_GRANTED_CREDIT_E, $sformatf(
                "opcode 0x%0h was issued with AllowRetry deasserted and PCrdType 0x%0h, and this link has seen no unspent PCrdGrant of that type; section 2.9.4 requires AllowRetry asserted on a first attempt",
                vif.txreqflit.opcode, vif.txreqflit.pcrdtype));
            end
            else begin
              chk_hit(VIP_CHI_CHK_REQ_RETRY_SPENDS_GRANTED_CREDIT_E);
              pcrd_delta_by_type[vif.txreqflit.pcrdtype]--;
            end
          end
          else if (req_opcode_t'(vif.txreqflit.opcode) ==
                   req_opcode_t'(VIP_CHI_REQ_PCRD_RETURN_C)) begin
            if (pcrd_available(vif.txreqflit.pcrdtype) != 0) begin
              pcrd_delta_by_type[vif.txreqflit.pcrdtype]--;
            end
          end
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
              completion_seen_by_txn[txn_id_to_index(txn_id_t'(vif.rxrspflit.txnid))] <= 1'b1;
              if (req_inflight_by_txn[txn_id_to_index(txn_id_t'(vif.rxrspflit.txnid))]) begin
                req_outstanding_delta--;
              end
              req_inflight_by_txn[txn_id_to_index(txn_id_t'(vif.rxrspflit.txnid))] <= 1'b0;
            end

            rsp_opcode_t'(VIP_CHI_RSP_COMP_C): begin
              completion_seen_by_txn[txn_id_to_index(txn_id_t'(vif.rxrspflit.txnid))] <= 1'b1;
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

              // Section 2.6.5 requires this flit to carry the bounced request's
              // TxnID, so a RetryAck landing on a slot no request has used
              // bounced nothing -- and the credit that follows it would have no
              // transaction to re-issue.
              if (req_txn_id_seen_by_txn[txn_id_to_index(txn_id_t'(vif.rxrspflit.txnid))]) begin
                chk_hit(VIP_CHI_CHK_RSP_RETRY_ACK_TXN_ID_E);
              end
              else begin
                chk_miss(VIP_CHI_CHK_RSP_RETRY_ACK_TXN_ID_E, $sformatf(
                  "RetryAck arrived with TxnID 0x%0h, which no request on this link has used; section 2.6.5 requires the bounced request's TxnID",
                  txn_id_t'(vif.rxrspflit.txnid)));
              end
              req_txn_id_seen_by_txn[txn_id_to_index(txn_id_t'(vif.rxrspflit.txnid))] <= 1'b0;
            end

            default: begin
            end
          endcase
        end

        // HomeNID is applicable in CompData and DataSepResp and inapplicable
        // and zero in every other Data message (IHI 0050 E 13.10.3). Judged on
        // whichever direction carries a DAT flit, so one rule covers both the
        // sending and the receiving vantage without a role test: the requester
        // sends write data and receives completions, the completer the reverse.
        if (vif.txdatflitv) begin
          if ((vif.txdatflit.homenid != '0) &&
              !vip_chi_types_pkg::vip_chi_dat_home_nid_applicable(
                 vip_chi_dat_opcode_t'(vif.txdatflit.opcode))) begin
            chk_miss(VIP_CHI_CHK_DAT_HOME_NID_LEGAL_E, $sformatf(
              "sent DAT opcode 0x%0h carried HomeNID 0x%0h, and section 13.10.3 makes the field inapplicable and zero outside CompData and DataSepResp",
              vif.txdatflit.opcode, vif.txdatflit.homenid));
          end
          else begin
            chk_hit(VIP_CHI_CHK_DAT_HOME_NID_LEGAL_E);
          end

          // Table A-5 gives CBusy "0" on the write-data opcodes: a requester
          // sending write data has no completer-busy level to report.
          if ((vif.txdatflit.cbusy != '0) &&
              !vip_chi_types_pkg::vip_chi_dat_cbusy_applicable(
                 vip_chi_dat_opcode_t'(vif.txdatflit.opcode))) begin
            chk_miss(VIP_CHI_CHK_DAT_CBUSY_LEGAL_E, $sformatf(
              "sent DAT opcode 0x%0h carried CBusy 0x%0h, and Table A-5 makes the field inapplicable and zero on write data",
              vif.txdatflit.opcode, vif.txdatflit.cbusy));
          end
          else begin
            chk_hit(VIP_CHI_CHK_DAT_CBUSY_LEGAL_E);
          end
        end

        if (vif.rxdatflitv) begin
          if ((vif.rxdatflit.homenid != '0) &&
              !vip_chi_types_pkg::vip_chi_dat_home_nid_applicable(
                 vip_chi_dat_opcode_t'(vif.rxdatflit.opcode))) begin
            chk_miss(VIP_CHI_CHK_DAT_HOME_NID_LEGAL_E, $sformatf(
              "received DAT opcode 0x%0h carried HomeNID 0x%0h, and section 13.10.3 makes the field inapplicable and zero outside CompData and DataSepResp",
              vif.rxdatflit.opcode, vif.rxdatflit.homenid));
          end
          else begin
            chk_hit(VIP_CHI_CHK_DAT_HOME_NID_LEGAL_E);
          end

          // Table A-5 gives CBusy "0" on the write-data opcodes: a requester
          // sending write data has no completer-busy level to report.
          if ((vif.rxdatflit.cbusy != '0) &&
              !vip_chi_types_pkg::vip_chi_dat_cbusy_applicable(
                 vip_chi_dat_opcode_t'(vif.rxdatflit.opcode))) begin
            chk_miss(VIP_CHI_CHK_DAT_CBUSY_LEGAL_E, $sformatf(
              "received DAT opcode 0x%0h carried CBusy 0x%0h, and Table A-5 makes the field inapplicable and zero on write data",
              vif.rxdatflit.opcode, vif.rxdatflit.cbusy));
          end
          else begin
            chk_hit(VIP_CHI_CHK_DAT_CBUSY_LEGAL_E);
          end
        end

        if (vif.txdatflitv && is_write_dat_opcode(dat_opcode_t'(vif.txdatflit.opcode))) begin
          if (!write_grant_seen_by_dbid[txn_id_to_index(txn_id_t'(vif.txdatflit.dbid))]) begin
            chk_miss(VIP_CHI_CHK_WRITE_DAT_BEFORE_DBID_E, $sformatf("write DAT was sent before a DBID-bearing grant response"));
          end
          else begin
            chk_hit(VIP_CHI_CHK_WRITE_DAT_BEFORE_DBID_E);
          end

          if (txn_id_t'(vif.txdatflit.txnid) != txn_id_t'(vif.txdatflit.dbid)) begin
            chk_miss(VIP_CHI_CHK_WRITE_DAT_TXNID_MATCHES_DBID_E, $sformatf("write DAT txnid did not match DBID on the wire"));
          end
          else begin
            chk_hit(VIP_CHI_CHK_WRITE_DAT_TXNID_MATCHES_DBID_E);
          end

          if (!vif.txdatflitpend) begin
            write_grant_seen_by_dbid[txn_id_to_index(txn_id_t'(vif.txdatflit.dbid))] <= 1'b0;
          end
        end

        if (vif.txrspflitv &&
            (rsp_opcode_t'(vif.txrspflit.opcode) == rsp_opcode_t'(VIP_CHI_RSP_COMP_ACK_C))) begin
          if (!completion_seen_by_txn[txn_id_to_index(txn_id_t'(vif.txrspflit.txnid))]) begin
            chk_miss(VIP_CHI_CHK_COMPACK_BEFORE_COMPLETION_E, $sformatf("CompAck was sent before the completion it acknowledges"));
          end
          else begin
            chk_hit(VIP_CHI_CHK_COMPACK_BEFORE_COMPLETION_E);
          end

          if (!req_exp_comp_ack_by_txn[txn_id_to_index(txn_id_t'(vif.txrspflit.txnid))]) begin
            chk_miss(VIP_CHI_CHK_COMPACK_WITHOUT_EXPCOMPACK_E, $sformatf("CompAck was sent for a request without ExpCompAck"));
          end
          else begin
            chk_hit(VIP_CHI_CHK_COMPACK_WITHOUT_EXPCOMPACK_E);
          end

          req_exp_comp_ack_by_txn[txn_id_to_index(txn_id_t'(vif.txrspflit.txnid))] <= 1'b0;
          completion_seen_by_txn[txn_id_to_index(txn_id_t'(vif.txrspflit.txnid))] <= 1'b0;
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

          // The same rule from the other end of the link. One rule, two
          // directions, one check ID -- the RSP_FIELD_ZERO pattern, and for the
          // same reason: a link may carry a bind at only one end, so checking
          // solely from the requester's vantage would be silently one-sided on
          // exactly the links where the peer is the device under test rather than
          // this VIP.
          //
          // In THIS testbench it can only pass. The coherent link carries the
          // main bind at the RN-F ends alone, and the completer binds that do
          // exist sit on links no required-CompAck opcode crosses (an RN-I cannot
          // issue one). That is a property of where the binds are, not of the
          // rule, which is why the negative control asserts the requester vantage
          // and says so.
          if (vip_chi_exp_comp_ack_required(
                vip_chi_req_opcode_t'(vif.rxreqflit.opcode), 1'b1) &&
              !vif.rxreqflit.expcompack) begin
            chk_miss(VIP_CHI_CHK_EXPCOMPACK_REQUIRED_BUT_ZERO_E, $sformatf("a request whose opcode requires CompAck was received with ExpCompAck = 0"));
          end
          else begin
            chk_hit(VIP_CHI_CHK_EXPCOMPACK_REQUIRED_BUT_ZERO_E);
          end

          // The same Table 2-17 rule from the receiving end. One rule, two
          // vantages, one check ID -- the RSP_FIELD_ZERO pattern -- because a
          // link may carry a bind at only one end, and on a link whose requester
          // is the device under test the completer's vantage is the only one
          // there is.
          if (!vip_chi_types_pkg::vip_chi_atomic_size_legal(
                vip_chi_req_opcode_t'(vif.rxreqflit.opcode),
                vif.rxreqflit.size)) begin
            chk_miss(VIP_CHI_CHK_ATOMIC_SIZE_LEGAL_E, $sformatf(
              "atomic opcode 0x%0h was received with Size %0d, which Table 2-17 does not permit for it",
              vif.rxreqflit.opcode, vif.rxreqflit.size));
          end
          else begin
            chk_hit(VIP_CHI_CHK_ATOMIC_SIZE_LEGAL_E);
          end

          // The same Order rule from the receiving end, one check ID across both
          // vantages, for the reason given above the atomic-size mirror.
          if (!vip_chi_types_pkg::vip_chi_req_order_legal(
                vip_chi_req_opcode_t'(vif.rxreqflit.opcode),
                vip_chi_req_order_t'(vif.rxreqflit.order))) begin
            chk_miss(VIP_CHI_CHK_REQ_ORDER_LEGAL_E, $sformatf(
              "opcode 0x%0h was received with Order 0b%02b, which the specification does not permit for it",
              vif.rxreqflit.opcode, vif.rxreqflit.order));
          end
          else begin
            chk_hit(VIP_CHI_CHK_REQ_ORDER_LEGAL_E);
          end

          // The same Table 2-12 rule from the receiving end.
          if (!vip_chi_types_pkg::vip_chi_req_attr_combination_legal(
                vif.rxreqflit.memattr,
                vip_chi_snp_attr_t'(vif.rxreqflit.snpattr),
                vif.rxreqflit.likelyshared,
                vip_chi_req_order_t'(vif.rxreqflit.order))) begin
            chk_miss(VIP_CHI_CHK_REQ_ATTR_COMBINATION_LEGAL_E, $sformatf(
              "request was received with MemAttr 0x%0h (Allocate %0b Cacheable %0b Device %0b EWA %0b), SnpAttr %0b, LikelyShared %0b and Order 0b%02b, a combination Table 2-12 does not list",
              vif.rxreqflit.memattr, vif.rxreqflit.memattr[3],
              vif.rxreqflit.memattr[2], vif.rxreqflit.memattr[1],
              vif.rxreqflit.memattr[0], vif.rxreqflit.snpattr,
              vif.rxreqflit.likelyshared, vif.rxreqflit.order));
          end
          else begin
            chk_hit(VIP_CHI_CHK_REQ_ATTR_COMBINATION_LEGAL_E);
          end

          // The same Table 2-14 rule from the receiving end.
          // Judged only where the bit IS SnpAttr. Under Issue E the same bit is
          // DoDWT on WriteNoSnpFull, WriteNoSnpPtl and Combined Write, and a
          // conformant DoDWT = 1 there puts a one on the wire that is not an
          // SnpAttr claim at all. The specification separates the two by role --
          // DoDWT is applicable only from Home to Slave -- which a bind cannot
          // establish, so on those opcodes the rule has nothing to falsify and
          // says so by passing rather than by not evaluating.
          if (vip_chi_types_pkg::vip_chi_req_bit17_is_dodwt(
                CFG_P.ISSUE_P, vip_chi_req_opcode_t'(vif.rxreqflit.opcode))) begin
            chk_hit(VIP_CHI_CHK_REQ_SNP_ATTR_LEGAL_E);
          end
          else if ((vip_chi_types_pkg::vip_chi_snp_attr_requirement(
                      vip_chi_req_opcode_t'(vif.rxreqflit.opcode)) ==
                    vip_chi_types_pkg::VIP_CHI_SNP_ATTR_ONE_E) &&
                   (vif.rxreqflit.snpattr != VIP_CHI_SNP_SNOOPABLE_E)) begin
            chk_miss(VIP_CHI_CHK_REQ_SNP_ATTR_LEGAL_E, $sformatf(
              "opcode 0x%0h was received Non-snoopable, and Table 2-14 lists it as Snoopable only",
              vif.rxreqflit.opcode));
          end
          else if ((vip_chi_types_pkg::vip_chi_snp_attr_requirement(
                      vip_chi_req_opcode_t'(vif.rxreqflit.opcode)) ==
                    vip_chi_types_pkg::VIP_CHI_SNP_ATTR_ZERO_E) &&
                   (vif.rxreqflit.snpattr != VIP_CHI_SNP_NON_SNOOPABLE_E)) begin
            chk_miss(VIP_CHI_CHK_REQ_SNP_ATTR_LEGAL_E, $sformatf(
              "opcode 0x%0h was received Snoopable, and Table 2-14 lists it as Non-snoopable only",
              vif.rxreqflit.opcode));
          end
          else begin
            chk_hit(VIP_CHI_CHK_REQ_SNP_ATTR_LEGAL_E);
          end

          // Section 2.9.5's LikelyShared whitelist. Narrower than the tuple rule
          // above, which only knows the table's "LikelyShared implies Snoopable":
          // this also faults the six Snoopable-only opcodes the section excludes.
          if (vif.rxreqflit.likelyshared &&
              !vip_chi_types_pkg::vip_chi_req_likely_shared_permitted(
                 vip_chi_req_opcode_t'(vif.rxreqflit.opcode))) begin
            chk_miss(VIP_CHI_CHK_REQ_LIKELY_SHARED_LEGAL_E, $sformatf(
              "opcode 0x%0h was received with LikelyShared asserted, which section 2.9.5 does not permit for it",
              vif.rxreqflit.opcode));
          end
          else begin
            chk_hit(VIP_CHI_CHK_REQ_LIKELY_SHARED_LEGAL_E);
          end

          // Table A-3 fixes Size at 64 bytes for every coherent read, dataless
          // and CopyBack opcode, and for the full writes. Size = 0b110 is 64
          // bytes (Table 2-15), independent of the data bus width.
          if (vip_chi_types_pkg::vip_chi_req_size_fixed_64b(
                vip_chi_req_opcode_t'(vif.rxreqflit.opcode)) &&
              (vif.rxreqflit.size != VIP_CHI_REQ_SIZE_64B_C)) begin
            chk_miss(VIP_CHI_CHK_REQ_SIZE_LEGAL_E, $sformatf(
              "opcode 0x%0h was received with Size 0b%03b, and Table A-3 fixes its Size at 64 bytes (0b110)",
              vif.rxreqflit.opcode, vif.rxreqflit.size));
          end
          else begin
            chk_hit(VIP_CHI_CHK_REQ_SIZE_LEGAL_E);
          end

          // Section 6.3's closed list of transactions that support an Exclusive
          // access. Excl on anything else is not a weaker guarantee, it is a bit
          // the receiver has no defined behavior for.
          if (vif.rxreqflit.excl != VIP_CHI_REQ_NORMAL_E &&
              !vip_chi_types_pkg::vip_chi_req_excl_permitted(
                 vip_chi_req_opcode_t'(vif.rxreqflit.opcode))) begin
            chk_miss(VIP_CHI_CHK_REQ_EXCL_LEGAL_E, $sformatf(
              "opcode 0x%0h was received with Excl asserted, and section 6.3 does not list it as supporting Exclusive accesses",
              vif.rxreqflit.opcode));
          end
          else begin
            chk_hit(VIP_CHI_CHK_REQ_EXCL_LEGAL_E);
          end

          // Table A-3's Endian column: applicable on the Atomics only. Endian
          // selects an Atomic operand's byte order and has nothing to say about a
          // plain read or write, which the table states as must-be-zero rather
          // than as free.
          if (vif.rxreqflit.endian &&
              !vip_chi_types_pkg::vip_chi_req_endian_applicable(
                 vip_chi_req_opcode_t'(vif.rxreqflit.opcode))) begin
            chk_miss(VIP_CHI_CHK_REQ_ENDIAN_LEGAL_E, $sformatf(
              "opcode 0x%0h was received with Endian asserted, and Table A-3 makes the field inapplicable outside an Atomic",
              vif.rxreqflit.opcode));
          end
          else begin
            chk_hit(VIP_CHI_CHK_REQ_ENDIAN_LEGAL_E);
          end

          // ReturnNID and ReturnTxnID are inapplicable and must be zero outside
          // the request sets IHI 0050 E 13.10.4 / 13.10.15 name, and the two sets
          // differ: CleanSharedPersistSep may carry a ReturnNID and must not
          // carry a ReturnTxnID, because a separated persist gets an RSP rather
          // than data. Folded into ONE check id because it is one obligation --
          // the return path is not in use, so neither half of it may be set --
          // and a user standing it down wants both halves quiet.
          if ((vif.rxreqflit.returnnid != '0) &&
              !vip_chi_types_pkg::vip_chi_req_return_nid_applicable(
                 vip_chi_req_opcode_t'(vif.rxreqflit.opcode))) begin
            chk_miss(VIP_CHI_CHK_REQ_RETURN_PATH_LEGAL_E, $sformatf(
              "opcode 0x%0h was received with ReturnNID 0x%0h, and section 13.10.4 makes the field inapplicable and zero for it",
              vif.rxreqflit.opcode, vif.rxreqflit.returnnid));
          end
          else if ((vif.rxreqflit.returntxnid != '0) &&
                   !vip_chi_types_pkg::vip_chi_req_return_txn_id_applicable(
                      vip_chi_req_opcode_t'(vif.rxreqflit.opcode))) begin
            chk_miss(VIP_CHI_CHK_REQ_RETURN_PATH_LEGAL_E, $sformatf(
              "opcode 0x%0h was received with ReturnTxnID 0x%0h, and section 13.10.15 makes the field inapplicable and zero for it",
              vif.rxreqflit.opcode, vif.rxreqflit.returntxnid));
          end
          else begin
            chk_hit(VIP_CHI_CHK_REQ_RETURN_PATH_LEGAL_E);
          end

          // The other half of Table 2-9, which nothing checked: the table marks
          // ExpCompAck prohibited on a whole class of requests, and until now only
          // the required-but-zero direction was reported. Table A-3's ExpCompAck
          // column agrees, giving "0" on every opcode the requirement function
          // classifies as prohibited.
          //
          // The role argument is a constant one for the same reason the required
          // direction uses it, read the other way round: passing RN-F shrinks the
          // prohibited set, because the opcodes an RN-F may acknowledge are
          // exactly the ones lifted out of it. That is the under-reporting
          // direction, which is what a rule on every request should prefer.
          if (vif.rxreqflit.expcompack &&
              vip_chi_types_pkg::vip_chi_exp_comp_ack_prohibited(
                vip_chi_req_opcode_t'(vif.rxreqflit.opcode),
                1'b1)) begin
            chk_miss(VIP_CHI_CHK_EXPCOMPACK_PROHIBITED_BUT_SET_E, $sformatf(
              "opcode 0x%0h was received with ExpCompAck asserted, and Table 2-9 prohibits the bit for it",
              vif.rxreqflit.opcode));
          end
          else begin
            chk_hit(VIP_CHI_CHK_EXPCOMPACK_PROHIBITED_BUT_SET_E);
          end

          // Section 2.9.4's first-attempt rule, read through the credit pool. A
          // request with AllowRetry deasserted is claiming to spend a
          // pre-allocated P-Credit, so this link must have seen a PCrdGrant of
          // that PCrdType that is still unspent.
          //
          // PrefetchTgt is exempt because section 2.9.4 REQUIRES its AllowRetry
          // deasserted and it needs no credit; ReqLCrdReturn carries no
          // transaction at all; PCrdReturn spends without being judged, for the
          // reason given at the check id.
          if (!vif.rxreqflit.allowretry &&
              (req_opcode_t'(vif.rxreqflit.opcode) !=
                 req_opcode_t'(VIP_CHI_REQ_PREFETCH_TGT_C)) &&
              (req_opcode_t'(vif.rxreqflit.opcode) !=
                 req_opcode_t'(VIP_CHI_REQ_LCRD_RETURN_C)) &&
              (req_opcode_t'(vif.rxreqflit.opcode) !=
                 req_opcode_t'(VIP_CHI_REQ_PCRD_RETURN_C))) begin
            if (pcrd_available(vif.rxreqflit.pcrdtype) == 0) begin
              chk_miss(VIP_CHI_CHK_REQ_RETRY_SPENDS_GRANTED_CREDIT_E, $sformatf(
                "opcode 0x%0h was received with AllowRetry deasserted and PCrdType 0x%0h, and this link has seen no unspent PCrdGrant of that type; section 2.9.4 requires AllowRetry asserted on a first attempt",
                vif.rxreqflit.opcode, vif.rxreqflit.pcrdtype));
            end
            else begin
              chk_hit(VIP_CHI_CHK_REQ_RETRY_SPENDS_GRANTED_CREDIT_E);
              pcrd_delta_by_type[vif.rxreqflit.pcrdtype]--;
            end
          end
          else if (req_opcode_t'(vif.rxreqflit.opcode) ==
                   req_opcode_t'(VIP_CHI_REQ_PCRD_RETURN_C)) begin
            if (pcrd_available(vif.rxreqflit.pcrdtype) != 0) begin
              pcrd_delta_by_type[vif.rxreqflit.pcrdtype]--;
            end
          end

          // Not gated on req_has_modeled_completion: see the declaration.
          // ReqLCrdReturn and PCrdReturn are excluded because both are required
          // to drive TxnID zero, so marking slot 0 for them would leave the one
          // slot a real request can also use permanently unjudgeable.
          if ((req_opcode != req_opcode_t'(VIP_CHI_REQ_PCRD_RETURN_C)) &&
              (req_opcode != req_opcode_t'(VIP_CHI_REQ_LCRD_RETURN_C))) begin
            req_txn_id_seen_by_txn[txn_idx] <= 1'b1;
          end

          if (req_has_modeled_completion(req_opcode)) begin
            // Same SrcID reusing a live slot is the violation. A DIFFERENT SrcID
            // landing on the same slot is a pass, not a decline: section 2.5's
            // rule is satisfied outright, because the two requests are
            // distinguishable by the field the spec names.
            if (req_inflight_by_txn[txn_idx] && req_src_valid_by_txn[txn_idx] &&
                (req_src_by_txn[txn_idx] === node_id_t'(vif.rxreqflit.srcid))) begin
              chk_miss(VIP_CHI_CHK_TXNID_REUSE_COMPLETER_E, $sformatf("completer observed a reused request TxnID while the earlier request was still in flight"));
            end
            else begin
              chk_hit(VIP_CHI_CHK_TXNID_REUSE_COMPLETER_E);
            end
            if (!req_inflight_by_txn[txn_idx]) begin
              req_outstanding_delta++;
            end
            req_inflight_by_txn[txn_idx]  <= 1'b1;
            req_src_by_txn[txn_idx]       <= node_id_t'(vif.rxreqflit.srcid);
            req_src_valid_by_txn[txn_idx] <= 1'b1;
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

              // Section 2.6.5 read at the sending vantage: a completer must
              // bounce a request it received, and the TxnID is the only thing
              // naming which one.
              if (req_txn_id_seen_by_txn[txn_id_to_index(txn_id_t'(vif.txrspflit.txnid))]) begin
                chk_hit(VIP_CHI_CHK_RSP_RETRY_ACK_TXN_ID_E);
              end
              else begin
                chk_miss(VIP_CHI_CHK_RSP_RETRY_ACK_TXN_ID_E, $sformatf(
                  "RetryAck was sent with TxnID 0x%0h, which no request received on this link has used; section 2.6.5 requires the bounced request's TxnID",
                  txn_id_t'(vif.txrspflit.txnid)));
              end
              req_txn_id_seen_by_txn[txn_id_to_index(txn_id_t'(vif.txrspflit.txnid))] <= 1'b0;
            end
            default: begin
            end
          endcase
        end
      end

      if (vif.txdatflitv) begin
        // Retire the read completion this beat belongs to, counted by TxnID --
        // see txdat_beats_by_txn. This runs on every beat and is deliberately
        // NOT part of the FLITPEND-run tracker below: the run tells you when the
        // CHANNEL went quiet, which is only the same thing as "this transfer
        // finished" while no two transfers share the channel.
        //
        // The clears here are non-blocking, so the run-end code below still sees
        // this cycle's pre-update values and its own beat-count check is
        // unaffected.
        if (ROLE_IS_COMPLETER_C &&
            ((dat_opcode_t'(vif.txdatflit.opcode) == dat_opcode_t'(VIP_CHI_DAT_COMP_DATA_C)) ||
             (dat_opcode_t'(vif.txdatflit.opcode) == dat_opcode_t'(VIP_CHI_DAT_DATA_SEP_RESP_C)))) begin
          int unsigned rt_txn_idx;
          int unsigned rt_beats;

          rt_txn_idx = txn_id_to_index(txn_id_t'(vif.txdatflit.txnid));
          rt_beats   = txdat_beats_by_txn[rt_txn_idx] + 1;

          if (!expected_completion_valid_by_txn[rt_txn_idx]) begin
            // No request on record for this TxnID. The orphan itself is the
            // scoreboard's to report; here it just must not accumulate a count
            // that a later, legitimate transfer would inherit.
            txdat_beats_by_txn[rt_txn_idx] <= 0;
          end
          else if (rt_beats >= expected_completion_beats_by_txn[rt_txn_idx]) begin
            if (expected_completion_opcode_by_txn[rt_txn_idx] != dat_opcode_t'(vif.txdatflit.opcode)) begin
              chk_miss(VIP_CHI_CHK_TX_READ_COMPLETION_DAT_OPCODE_E, $sformatf("TX read completion DAT opcode did not match the request type"));
            end
            else begin
              chk_hit(VIP_CHI_CHK_TX_READ_COMPLETION_DAT_OPCODE_E);
            end
            expected_completion_valid_by_txn[rt_txn_idx] <= 1'b0;
            txdat_beats_by_txn[rt_txn_idx] <= 0;
            if (dat_completion_req_valid_by_txn[rt_txn_idx]) begin
              if (req_inflight_by_txn[txn_id_to_index(dat_completion_req_txn_by_txn[rt_txn_idx])]) begin
                req_outstanding_delta--;
              end
              req_inflight_by_txn[txn_id_to_index(dat_completion_req_txn_by_txn[rt_txn_idx])] <= 1'b0;
              dat_completion_req_valid_by_txn[rt_txn_idx] <= 1'b0;
            end
          end
          else begin
            txdat_beats_by_txn[rt_txn_idx] <= rt_beats;
          end
        end

        if (!txdat_burst_active) begin
          txdat_burst_count <= 1;
          txdat_burst_opcode <= dat_opcode_t'(vif.txdatflit.opcode);
          if (!dat_reorder_allowed && !dat_interleave_allowed &&
              (data_id_t'(vif.txdatflit.dataid) != data_id_t'('0))) begin
            chk_miss(VIP_CHI_CHK_TX_DAT_FIRST_BEAT_DATAID_ZERO_E, $sformatf("first TX DAT beat did not start at dataid 0"));
          end
          else begin
            chk_hit(VIP_CHI_CHK_TX_DAT_FIRST_BEAT_DATAID_ZERO_E);
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
                chk_miss(VIP_CHI_CHK_TX_WRITE_DAT_BEAT_COUNT_E, $sformatf("TX write DAT burst beat count did not match the granted request size"));
              end
              else begin
                chk_hit(VIP_CHI_CHK_TX_WRITE_DAT_BEAT_COUNT_E);
              end
              expected_write_valid_by_dbid[dbid_idx] <= 1'b0;
            end
            else if (ROLE_IS_COMPLETER_C &&
                     ((dat_opcode_t'(vif.txdatflit.opcode) == dat_opcode_t'(VIP_CHI_DAT_COMP_DATA_C)) ||
                      (dat_opcode_t'(vif.txdatflit.opcode) == dat_opcode_t'(VIP_CHI_DAT_DATA_SEP_RESP_C)))) begin
              int unsigned txn_idx;

              txn_idx = txn_id_to_index(txn_id_t'(vif.txdatflit.txnid));
              if (expected_completion_valid_by_txn[txn_idx]) begin
                if (!dat_interleave_allowed &&
                    (expected_completion_beats_by_txn[txn_idx] != 1)) begin
                  chk_miss(VIP_CHI_CHK_TX_READ_COMPLETION_DAT_BEAT_COUNT_E, $sformatf("TX read completion DAT burst beat count did not match the request size"));
                end
                else begin
                  chk_hit(VIP_CHI_CHK_TX_READ_COMPLETION_DAT_BEAT_COUNT_E);
                end
              end
            end
          end
        end
        else begin
          if (!dat_interleave_allowed &&
              (txn_id_t'(vif.txdatflit.txnid) != txdat_burst_txn_id)) begin
            chk_miss(VIP_CHI_CHK_TX_DAT_TXNID_STABLE_E, $sformatf("TX DAT burst changed txnid before txdatflitpend dropped"));
          end
          else begin
            chk_hit(VIP_CHI_CHK_TX_DAT_TXNID_STABLE_E);
          end

          if (!dat_reorder_allowed && !dat_interleave_allowed &&
              (data_id_t'(vif.txdatflit.dataid) != txdat_expected_data_id)) begin
            chk_miss(VIP_CHI_CHK_TX_DAT_DATAID_SEQUENTIAL_E, $sformatf("TX DAT burst dataid was not sequential"));
          end
          else begin
            chk_hit(VIP_CHI_CHK_TX_DAT_DATAID_SEQUENTIAL_E);
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
                chk_miss(VIP_CHI_CHK_TX_WRITE_DAT_BEAT_COUNT_E, $sformatf("TX write DAT burst beat count did not match the granted request size"));
              end
              else begin
                chk_hit(VIP_CHI_CHK_TX_WRITE_DAT_BEAT_COUNT_E);
              end
              expected_write_valid_by_dbid[dbid_idx] <= 1'b0;
            end
            else if (ROLE_IS_COMPLETER_C &&
                     ((txdat_burst_opcode == dat_opcode_t'(VIP_CHI_DAT_COMP_DATA_C)) ||
                      (txdat_burst_opcode == dat_opcode_t'(VIP_CHI_DAT_DATA_SEP_RESP_C)))) begin
              int unsigned txn_idx;

              txn_idx = txn_id_to_index(txn_id_t'(vif.txdatflit.txnid));
              if (expected_completion_valid_by_txn[txn_idx]) begin
                if (!dat_interleave_allowed &&
                    (expected_completion_beats_by_txn[txn_idx] != (txdat_burst_count + 1))) begin
                  chk_miss(VIP_CHI_CHK_TX_READ_COMPLETION_DAT_BEAT_COUNT_E, $sformatf("TX read completion DAT burst beat count did not match the request size"));
                end
                else begin
                  chk_hit(VIP_CHI_CHK_TX_READ_COMPLETION_DAT_BEAT_COUNT_E);
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
        // Requester-side twin of the TX retirement above: this end receives the
        // interleaved beats the completer sent, so it needs the same per-TxnID
        // accounting to know which transfer just finished.
        if (ROLE_IS_REQUESTER_C &&
            ((dat_opcode_t'(vif.rxdatflit.opcode) == dat_opcode_t'(VIP_CHI_DAT_COMP_DATA_C)) ||
             (dat_opcode_t'(vif.rxdatflit.opcode) == dat_opcode_t'(VIP_CHI_DAT_DATA_SEP_RESP_C)))) begin
          int unsigned rr_txn_idx;
          int unsigned rr_beats;

          rr_txn_idx = txn_id_to_index(txn_id_t'(vif.rxdatflit.txnid));
          rr_beats   = rxdat_beats_by_txn[rr_txn_idx] + 1;

          if (!expected_completion_valid_by_txn[rr_txn_idx]) begin
            rxdat_beats_by_txn[rr_txn_idx] <= 0;
          end
          else if (rr_beats >= expected_completion_beats_by_txn[rr_txn_idx]) begin
            if (expected_completion_opcode_by_txn[rr_txn_idx] != dat_opcode_t'(vif.rxdatflit.opcode)) begin
              chk_miss(VIP_CHI_CHK_RX_READ_COMPLETION_DAT_OPCODE_E, $sformatf("RX read completion DAT opcode did not match the request type"));
            end
            else begin
              chk_hit(VIP_CHI_CHK_RX_READ_COMPLETION_DAT_OPCODE_E);
            end
            expected_completion_valid_by_txn[rr_txn_idx] <= 1'b0;
            rxdat_beats_by_txn[rr_txn_idx] <= 0;
            // The read half of section 2.8.3 rule 1. Keyed by the REQUEST's
            // TxnID, not the completion's: a separated read returns its data
            // under ReturnTxnID, but the CompAck that closes it still carries the
            // TxnID the request was issued with.
            completion_seen_by_txn[
              dat_completion_req_valid_by_txn[rr_txn_idx]
                ? txn_id_to_index(dat_completion_req_txn_by_txn[rr_txn_idx])
                : rr_txn_idx] <= 1'b1;
            if (dat_completion_req_valid_by_txn[rr_txn_idx]) begin
              if (req_inflight_by_txn[txn_id_to_index(dat_completion_req_txn_by_txn[rr_txn_idx])]) begin
                req_outstanding_delta--;
              end
              req_inflight_by_txn[txn_id_to_index(dat_completion_req_txn_by_txn[rr_txn_idx])] <= 1'b0;
              dat_completion_req_valid_by_txn[rr_txn_idx] <= 1'b0;
            end
          end
          else begin
            rxdat_beats_by_txn[rr_txn_idx] <= rr_beats;
          end
        end

        if (!rxdat_burst_active) begin
          rxdat_burst_count <= 1;
          rxdat_burst_opcode <= dat_opcode_t'(vif.rxdatflit.opcode);
          if (!dat_reorder_allowed && !dat_interleave_allowed &&
              (data_id_t'(vif.rxdatflit.dataid) != data_id_t'('0))) begin
            chk_miss(VIP_CHI_CHK_RX_DAT_FIRST_BEAT_DATAID_ZERO_E, $sformatf("first RX DAT beat did not start at dataid 0"));
          end
          else begin
            chk_hit(VIP_CHI_CHK_RX_DAT_FIRST_BEAT_DATAID_ZERO_E);
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
                chk_miss(VIP_CHI_CHK_RX_WRITE_DAT_BEAT_COUNT_E, $sformatf("RX write DAT burst beat count did not match the granted request size"));
              end
              else begin
                chk_hit(VIP_CHI_CHK_RX_WRITE_DAT_BEAT_COUNT_E);
              end
              expected_write_valid_by_dbid[dbid_idx] <= 1'b0;
            end
            else if (ROLE_IS_REQUESTER_C &&
                     ((dat_opcode_t'(vif.rxdatflit.opcode) == dat_opcode_t'(VIP_CHI_DAT_COMP_DATA_C)) ||
                      (dat_opcode_t'(vif.rxdatflit.opcode) == dat_opcode_t'(VIP_CHI_DAT_DATA_SEP_RESP_C)))) begin
              int unsigned txn_idx;

              txn_idx = txn_id_to_index(txn_id_t'(vif.rxdatflit.txnid));
              if (expected_completion_valid_by_txn[txn_idx]) begin
                if (!dat_interleave_allowed &&
                    (expected_completion_beats_by_txn[txn_idx] != 1)) begin
                  chk_miss(VIP_CHI_CHK_RX_READ_COMPLETION_DAT_BEAT_COUNT_E, $sformatf("RX read completion DAT burst beat count did not match the request size"));
                end
                else begin
                  chk_hit(VIP_CHI_CHK_RX_READ_COMPLETION_DAT_BEAT_COUNT_E);
                end
              end
            end
          end
        end
        else begin
          if (!dat_interleave_allowed &&
              (txn_id_t'(vif.rxdatflit.txnid) != rxdat_burst_txn_id)) begin
            chk_miss(VIP_CHI_CHK_RX_DAT_TXNID_STABLE_E, $sformatf("RX DAT burst changed txnid before rxdatflitpend dropped"));
          end
          else begin
            chk_hit(VIP_CHI_CHK_RX_DAT_TXNID_STABLE_E);
          end

          if (!dat_reorder_allowed && !dat_interleave_allowed &&
              (data_id_t'(vif.rxdatflit.dataid) != rxdat_expected_data_id)) begin
            chk_miss(VIP_CHI_CHK_RX_DAT_DATAID_SEQUENTIAL_E, $sformatf("RX DAT burst dataid was not sequential"));
          end
          else begin
            chk_hit(VIP_CHI_CHK_RX_DAT_DATAID_SEQUENTIAL_E);
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
                chk_miss(VIP_CHI_CHK_RX_WRITE_DAT_BEAT_COUNT_E, $sformatf("RX write DAT burst beat count did not match the granted request size"));
              end
              else begin
                chk_hit(VIP_CHI_CHK_RX_WRITE_DAT_BEAT_COUNT_E);
              end
              expected_write_valid_by_dbid[dbid_idx] <= 1'b0;
            end
            else if (ROLE_IS_REQUESTER_C &&
                     ((rxdat_burst_opcode == dat_opcode_t'(VIP_CHI_DAT_COMP_DATA_C)) ||
                      (rxdat_burst_opcode == dat_opcode_t'(VIP_CHI_DAT_DATA_SEP_RESP_C)))) begin
              int unsigned txn_idx;

              txn_idx = txn_id_to_index(txn_id_t'(vif.rxdatflit.txnid));
              if (expected_completion_valid_by_txn[txn_idx]) begin
                if (!dat_interleave_allowed &&
                    (expected_completion_beats_by_txn[txn_idx] != (rxdat_burst_count + 1))) begin
                  chk_miss(VIP_CHI_CHK_RX_READ_COMPLETION_DAT_BEAT_COUNT_E, $sformatf("RX read completion DAT burst beat count did not match the request size"));
                end
                else begin
                  chk_hit(VIP_CHI_CHK_RX_READ_COMPLETION_DAT_BEAT_COUNT_E);
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
      for (int unsigned pcrd_i = 0;
           pcrd_i < (2 ** VIP_CHI_PCRD_TYPE_WIDTH_C); pcrd_i++) begin
        pcrd_held_by_type[pcrd_i] <=
          unsigned'(int'(pcrd_held_by_type[pcrd_i]) + pcrd_delta_by_type[pcrd_i]);
      end

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
  // ---------------------------------------------------------------------------
  // Per-check identity, enable, severity and statistics.
  //
  // Every rule has a stable vip_chi_check_id_t, a severity, and pass/fail
  // counters published on the interface. Two things follow that did not hold
  // before:
  //
  //   * an SVA failure can FAIL A RUN. $error does not raise a UVM error, does
  //     not set the exit status, and is not read by the regression script, so
  //     every assertion here used to print into a log nothing consumed. The env
  //     now reads vif.check_fail_count at report_phase and raises the error.
  //   * a rule that never RAN is distinguishable from one that held. A pass
  //     count of zero and a fail count of zero means the rule was never
  //     evaluated, which is what the end-of-test vacuity report surfaces.
  //
  // DEVIATION worth naming: the per-check enable is applied in the assertion
  // ACTION BLOCKS, not by threading a per-check bit through each property's
  // `disable iff`. A `disable iff` that goes true mid-flight kills in-flight
  // attempts, so moving the gate there would quietly change the verdicts of
  // every multi-cycle property here for no gain. checks_enable stays as the
  // module-wide link-active gate it always was, and a disabled check simply
  // records nothing: neither pass nor fail, matching the Python port, so the
  // vacuity report shows it as not exercised rather than as quietly holding.
  // ---------------------------------------------------------------------------

  // +vip_chi_disable_check=<ID>[,<ID>...] and +vip_chi_warn_check=<ID>[,...].
  // An unknown name is fatal rather than ignored: the entire value of naming a
  // check is being able to address it, and a silently-dropped typo leaves the
  // user believing a check is off when it is still firing.
  function automatic void apply_check_plusarg(input string arg, input bit as_warning);
    string   list;
    string   name;
    int      start_pos;
    bit      matched;

    if (!$value$plusargs(arg, list)) begin
      return;
    end

    start_pos = 0;
    for (int i = 0; i <= list.len(); i++) begin
      if ((i == list.len()) || (list[i] == ",")) begin
        name = list.substr(start_pos, i - 1);
        start_pos = i + 1;
        if (name.len() == 0) begin
          continue;
        end
        matched = 1'b0;
        for (int unsigned id = 0; id < int'(VIP_CHI_CHK_NUM_E); id++) begin
          if (vip_chi_check_name(vip_chi_check_id_t'(id)) == name) begin
            matched = 1'b1;
            if (as_warning) begin
              vif.check_severity[id] = VIP_CHI_CHK_SEV_WARNING_E;
            end
            else begin
              vif.check_enabled[id] = 1'b0;
            end
          end
        end
        if (!matched) begin
          $fatal(1, "vip_chi_sva: %s names an unknown check '%s'", arg, name);
        end
      end
    end
  endfunction

  initial begin
    for (int unsigned id = 0; id < int'(VIP_CHI_CHK_NUM_E); id++) begin
      // Only the IDs this checker owns: vip_chi_snp_sva initialises the SNP
      // range on the same interface, and whichever elaborated second would
      // otherwise clear the other's plusarg settings.
      if (!vip_chi_check_is_snp(vip_chi_check_id_t'(id))) begin
        vif.check_severity[id]   = VIP_CHI_CHK_SEV_ERROR_E;
        vif.check_enabled[id]    = 1'b1;
        vif.check_pass_count[id] = 0;
        vif.check_fail_count[id] = 0;
      end
    end
    // A rule the elaboration parameters switched off is not owned by this
    // instance either. check_enabled doubles as ownership -- see vip_chi_if --
    // and the tally CSV exports it as the `enabled` column, so leaving it set
    // publishes a rule that CANNOT evaluate here as one that is enabled and
    // simply never fired. That is the difference between "this link stands this
    // check down on purpose" and "this check found no traffic", and a vacuity
    // report cannot tell them apart from the outside.
    //
    // ENABLE_COMPLETION_TIMEOUT_P is the only parameter that gates a property,
    // and it gates both p_rni_completion_follows_req and
    // p_snf_completion_follows_req, which share one ID. The coherent binds pass
    // it 1'b0 -- a request and its completion are not both visible on one
    // coherent link -- so without this the four coherent binds each report
    // CHI_COMPLETION_FOLLOWS_REQ as an unexercised enabled rule forever.
    if (!ENABLE_COMPLETION_TIMEOUT_P) begin
      vif.check_enabled[VIP_CHI_CHK_COMPLETION_FOLLOWS_REQ_E] = 1'b0;
    end

    if (MULTI_SOURCE_LINK_P) begin
      vif.check_enabled[VIP_CHI_CHK_TXNID_REUSE_REQUESTER_E] = 1'b0;
      vif.check_enabled[VIP_CHI_CHK_TXNID_REUSE_COMPLETER_E] = 1'b0;
    end

    if (TXSACTIVE_FROM_LINK_UP_P) begin
      vif.check_enabled[VIP_CHI_CHK_TXSACTIVE_DEASSERT_BOUNDED_E] = 1'b0;
    end

    if (HAND_DRIVEN_LINK_P) begin
      vif.check_enabled[VIP_CHI_CHK_REQ_VALID_REQUIRES_PEND_E] = 1'b0;
      vif.check_enabled[VIP_CHI_CHK_RSP_VALID_REQUIRES_PEND_E] = 1'b0;
      vif.check_enabled[VIP_CHI_CHK_DAT_VALID_REQUIRES_PEND_E] = 1'b0;
      vif.check_enabled[VIP_CHI_CHK_LCRD_OVERFLOW_E]           = 1'b0;
      vif.check_enabled[VIP_CHI_CHK_LCRD_UNDERFLOW_E]          = 1'b0;
      vif.check_enabled[VIP_CHI_CHK_LCRD_QUIESCENT_IN_STOP_E]  = 1'b0;
      vif.check_enabled[VIP_CHI_CHK_TXNID_REUSE_REQUESTER_E]   = 1'b0;
      vif.check_enabled[VIP_CHI_CHK_TXNID_REUSE_COMPLETER_E]   = 1'b0;
      vif.check_enabled[VIP_CHI_CHK_TXSACTIVE_COVERS_OUTSTANDING_E] = 1'b0;
      vif.check_enabled[VIP_CHI_CHK_TXSACTIVE_DEASSERT_BOUNDED_E]   = 1'b0;
    end

    apply_check_plusarg("vip_chi_disable_check=%s", 1'b0);
    apply_check_plusarg("vip_chi_warn_check=%s", 1'b1);
  end

  // One evaluation that held.
  function automatic void chk_hit(input vip_chi_check_id_t id);
    if (!vif.check_enabled[id]) begin
      return;
    end
    vif.check_pass_count[id] = vif.check_pass_count[id] + 1;
  endfunction

  // One evaluation that did not hold. Counted before the severity is consulted,
  // so a check turned down to WARNING or OFF still shows in the end-of-test
  // table as failing -- otherwise "off" reads the same as "fixed".
  function automatic void chk_miss(input vip_chi_check_id_t id, input string msg);
    if (!vif.check_enabled[id]) begin
      return;
    end
    vif.check_fail_count[id] = vif.check_fail_count[id] + 1;
    case (vif.check_severity[id])
      VIP_CHI_CHK_SEV_OFF_E: begin
        // Counted, not reported.
      end
      VIP_CHI_CHK_SEV_WARNING_E: begin
        $warning("vip_chi_sva: [%s] %s", vip_chi_check_name(id), msg);
      end
      default: begin
        $error("vip_chi_sva: [%s] %s", vip_chi_check_name(id), msg);
      end
    endcase
  endfunction

  property p_lasm_legal_transition;
    @(posedge vif.clk) disable iff (!vif.rst_n)
      vip_chi_lasm_legal_step(lasm_state, link_lasm());
  endproperty

  // A link that never leaves ACTIVATE or DEACTIVATE is stuck, and stuck is the
  // one failure mode no other rule here can see: every cycle of it is legal.
  // The transition rule is satisfied (holding is always a legal step), no flit
  // goes out to violate a channel rule, and the transaction-completion timeout
  // has nothing in flight to measure -- the run simply hangs, and hangs without
  // naming anything.
  //
  // Measured on the dwell counter rather than as a bounded SVA window, so the
  // bound can be a run-time knob rather than an elaboration-time constant, and
  // so the report can state HOW LONG the link has been there.
  //
  // Fired on the crossing, not on every cycle beyond it: a stuck link would
  // otherwise report once per cycle for the rest of the run, which buries the
  // first (and only useful) report under thousands of copies.
  property p_lasm_activation_timeout;
    @(posedge vif.clk) disable iff (!vif.rst_n || (link_activation_timeout_cycles <= 0))
      !((link_lasm() == VIP_CHI_LASM_ACTIVATE_E) &&
        (lasm_dwell == unsigned'(link_activation_timeout_cycles)));
  endproperty

  property p_lasm_deactivation_timeout;
    @(posedge vif.clk) disable iff (!vif.rst_n || (link_deactivation_timeout_cycles <= 0))
      !((link_lasm() == VIP_CHI_LASM_DEACTIVATE_E) &&
        (lasm_dwell == unsigned'(link_deactivation_timeout_cycles)));
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

  // Gated on link_ever_active rather than checks_enable, and the three rules
  // below are the reason the distinction matters.
  //
  // checks_enable is this interface's ACTIVATION REQUEST, so it is low in both
  // DEACTIVATE and STOP -- exactly the two states in which "a flit must not go
  // out" has any content. Under that gate the rules could only ever judge a
  // link that was already up, which is the half of the question that never
  // fails, and the tear-down flits would have gone completely unwatched.
  //
  // link_ever_active carries the intended meaning instead, the same way
  // p_link_restarts_after_reset_release uses it: an interface whose agent is
  // never built stays unarmed and cannot false-fail on an idle link, while one
  // that has carried traffic is judged for the whole life of the link.
  property p_req_requires_link;
    @(posedge vif.clk) disable iff (!link_ever_active || !vif.rst_n)
      vif.txreqflitv |-> flit_send_allowed(tx_req_is_lcrd_return());
  endproperty

  property p_rsp_requires_link;
    @(posedge vif.clk) disable iff (!link_ever_active || !vif.rst_n)
      vif.txrspflitv |-> flit_send_allowed(tx_rsp_is_lcrd_return());
  endproperty

  property p_dat_requires_link;
    @(posedge vif.clk) disable iff (!link_ever_active || !vif.rst_n)
      vif.txdatflitv |-> flit_send_allowed(tx_dat_is_lcrd_return());
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

  // ---------------------------------------------------------------------------
  // FLITPEND announces a flit one cycle ahead. The obligation runs FROM THE FLIT
  // BACKWARDS: IHI 0050 E §14.4 / D §13.4 require that the signal is asserted
  // exactly one cycle before a flit is sent, and that a deasserted FLITPEND
  // forbids a flit in the next cycle. Those two are one statement read from
  // either end -- flitv(t) |-> flitpend(t-1) is the contrapositive of
  // !flitpend(t-1) |=> !flitv(t) -- so this is one property per channel and not
  // two. A second ID could never fail without the first, and a rule that cannot
  // fail independently reports coverage it does not have.
  //
  // Nothing constrains FLITPEND when no flit follows. The same section PERMITS a
  // transmitter to hold it permanently asserted, to assert it while holding no
  // L-Credit, and to assert and then deassert it without sending a flit. The
  // rule this replaced tested `flitpend |-> flitv`, which reports all three as
  // violations.
  // ---------------------------------------------------------------------------
  property p_req_valid_requires_pend;
    @(posedge vif.clk) disable iff (!checks_enable || !vif.rst_n)
      vif.txreqflitv |-> $past(vif.txreqflitpend);
  endproperty

  property p_rsp_valid_requires_pend;
    @(posedge vif.clk) disable iff (!checks_enable || !vif.rst_n)
      vif.txrspflitv |-> $past(vif.txrspflitpend);
  endproperty

  property p_dat_valid_requires_pend;
    @(posedge vif.clk) disable iff (!checks_enable || !vif.rst_n)
      vif.txdatflitv |-> $past(vif.txdatflitpend);
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

  // Table A-4 zero-field legality, asserted from both vantages of the link.
  //
  // One rule, two antecedents, one check ID -- the pattern the check registry
  // documents. It is not decoration: which of the two sees a given opcode
  // depends on which end of the link this bind sits on. A PCrdGrant is txrsp at
  // the completer and rxrsp at the requester, and a link may carry a bind at
  // only one end. Checking a single direction would leave the rule silently
  // one-sided on any link instrumented at one end only.
  //
  // Both directions are gated on checks_enable rather than link_ever_active:
  // these are flit-content rules, and a flit that is on the wire at all has
  // already passed the activation rules above under their own IDs.
  property p_tx_rsp_field_zero;
    @(posedge vif.clk) disable iff (!checks_enable || !vif.rst_n)
      (vif.txrspflitv &&
       rsp_a4_has_zero_field(rsp_opcode_t'(vif.txrspflit.opcode)))
      |-> rsp_a4_zero_fields_legal(rsp_opcode_t'(vif.txrspflit.opcode),
                                   txn_id_t'(vif.txrspflit.txnid),
                                   vif.txrspflit.resperr,
                                   vif.txrspflit.resp,
                                   txn_id_t'(vif.txrspflit.dbid));
  endproperty

  property p_rx_rsp_field_zero;
    @(posedge vif.clk) disable iff (!checks_enable || !vif.rst_n)
      (vif.rxrspflitv &&
       rsp_a4_has_zero_field(rsp_opcode_t'(vif.rxrspflit.opcode)))
      |-> rsp_a4_zero_fields_legal(rsp_opcode_t'(vif.rxrspflit.opcode),
                                   txn_id_t'(vif.rxrspflit.txnid),
                                   vif.rxrspflit.resperr,
                                   vif.rxrspflit.resp,
                                   txn_id_t'(vif.rxrspflit.dbid));
  endproperty

  // The four reset-idle rules are gated on link_ever_active, NOT on
  // checks_enable, and the sideband one below shows why in the sharpest form
  // this codebase has produced:
  //
  //   checks_enable IS (txlinkactivereq || rxlinkactivereq).
  //   p_link_sideband_idle_during_reset REQUIRES !txlinkactivereq in reset.
  //
  // So the rule's own requirement is what switched the rule off. A driver that
  // satisfied it held the sideband idle, which made checks_enable low, which
  // killed every attempt -- and the only design the gate would ever have let
  // through is one that violated the rule by raising the request during reset,
  // which is the one case the rule then had no chance to report. The three
  // channel rules had the same gate for the same reason: nothing is driven
  // during reset, so the link is never active while they apply.
  //
  // link_ever_active carries the intended meaning. It latches the first time
  // this interface's link comes up and survives reset, so an interface whose
  // agent is never built stays unarmed, while one that has carried traffic must
  // hold its outputs idle through every later reset.
  //
  // The terms test `!== 1'b1` rather than `!signal`, and that is not defensive
  // style -- it is what the rule means. Each role's clocking block deliberately
  // carries only the signals that role DRIVES: an RN-I sources requests and so
  // never drives txreqlcrdv, an SN-F grants REQ credits and so never drives the
  // REQ flit signals. Those nets sit at X for the whole run, and `!x` is x, so
  // the plain form reported every one of them the moment the gate above was
  // fixed -- four reports per reset on a link doing nothing wrong. The rule's
  // content is that nothing is ASSERTED during reset; a net this node does not
  // drive at all is a different question, and not this rule's.
  // WHAT MUST BE DEASSERTED, and it is a closed list. IHI 0050 E 14.1.3 /
  // D 13.1.3:
  //
  //   "During reset the following interface signals must be deasserted by the
  //    component:  TX***LCRDV.  TX***FLITV.  TXLINKACTIVEREQ and
  //    RXLINKACTIVEACK. [...] All other signals can be any value."
  //
  // Four items, then a sentence that closes the set. Both issues carry it
  // word for word. So FLITPEND and TXSACTIVE are NOT in it, and requiring them
  // low rejects two behaviors the specification permits in as many words:
  //
  //   FLITPEND -- 14.4 / D 13.4: "A transmitter is permitted to keep the signal
  //   permanently asserted." A transmitter that does is conformant and holds it
  //   through reset, and the old rule reported it every cycle.
  //
  //   TXSACTIVE -- 14.7 / D 13.7 places no reset requirement on it, 14.7.4 calls
  //   SACTIVE signaling "orthogonal to the LINKACTIVE states", and 14.7.2
  //   permits an interconnect interface to "use the RXSACTIVE input signal to
  //   directly generate the TXSACTIVE output signal". RXSACTIVE is an input, so
  //   by the sentence above it may be any value during reset -- which makes a
  //   high TXSACTIVE in reset not merely permitted but the direct consequence of
  //   a permitted implementation choice.
  //
  // THE TWO LINKACTIVE TERMS BELOW ARE THE RIGHT TWO, and the naming is what
  // makes that non-obvious. This interface names signals by DIRECTION -- `tx*`
  // is what this component drives -- while the specification names them by
  // CHANNEL GROUP, where TXLINKACTIVEACK is the peer's acknowledge of our
  // transmit link. Mapping the modports onto 14.5.1's four wires:
  //
  //   spec TXLINKACTIVEREQ (our output)  == vif.txlinkactivereq
  //   spec RXLINKACTIVEACK (our output)  == vif.txlinkactiveack
  //   spec TXLINKACTIVEACK (peer drives) == vif.rxlinkactiveack
  //   spec RXLINKACTIVEREQ (peer drives) == vif.rxlinkactivereq
  //
  // So `txlinkactivereq && txlinkactiveack` is exactly the spec's
  // "TXLINKACTIVEREQ and RXLINKACTIVEACK" -- the two LINKACTIVE signals a
  // component drives, which are the only two it could deassert. Checking
  // vif.rxlinkactiveack instead would judge the peer's output at this bind and
  // report a component that is not this one.
  //
  // TX***LCRDV keeps its term for the same reason: a credit is driven by the
  // receiver of the channel it credits, so the LCRDV signals in the modports
  // that are outputs are the ones this component can hold low.
  property p_link_sideband_idle_during_reset;
    @(posedge vif.clk) disable iff (!link_ever_active)
      (!vif.rst_n && $past(!vif.rst_n, 1, 1'b1)) |->
        ((vif.txlinkactivereq !== 1'b1) && (vif.txlinkactiveack !== 1'b1));
  endproperty

  property p_req_idle_during_reset;
    @(posedge vif.clk) disable iff (!link_ever_active)
      (!vif.rst_n && $past(!vif.rst_n, 1, 1'b1)) |->
        ((vif.txreqflitv !== 1'b1) && (vif.txreqlcrdv !== 1'b1));
  endproperty

  property p_rsp_idle_during_reset;
    @(posedge vif.clk) disable iff (!link_ever_active)
      (!vif.rst_n && $past(!vif.rst_n, 1, 1'b1)) |->
        ((vif.txrspflitv !== 1'b1) && (vif.txrsplcrdv !== 1'b1));
  endproperty

  property p_dat_idle_during_reset;
    @(posedge vif.clk) disable iff (!link_ever_active)
      (!vif.rst_n && $past(!vif.rst_n, 1, 1'b1)) |->
        ((vif.txdatflitv !== 1'b1) && (vif.txdatlcrdv !== 1'b1));
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

  // TXSACTIVE may only be asserted while the link is RUN.
  //
  // This rule was VACUOUS BY CONSTRUCTION until the graceful-deactivation path
  // existed, and in two independent ways worth recording, because both are easy
  // to reintroduce:
  //
  //   1. its gate defeated it. The antecedent needed the link DOWN and
  //      checks_enable IS this interface's activation request, so on every cycle
  //      the antecedent could have held, `disable iff` had already killed the
  //      attempt. The rule read as "if the link is up, the link is down".
  //   2. nothing walked the states it judges. The VIP could only take a link
  //      down by reset, so DEACTIVATE was never entered at all.
  //
  // Both are fixed here: link_ever_active gates it (an interface whose agent is
  // never built stays unarmed; one that has carried traffic is judged for the
  // whole life of the link), and the antecedent is widened from STOP alone to
  // the whole tear-down half, DEACTIVATE and STOP, which is what the rule's name
  // has always claimed. A node tearing its link down must not still be telling
  // the receiver it may have snoopable transactions outstanding.
  //
  // ACTIVATE is deliberately NOT included, and the distinction is the point.
  // TXSACTIVE is an early warning, not a report: a node bringing a link up
  // already knows whether it will have snoopable traffic, and raising the
  // sideband while it waits for the acknowledge is exactly what the signal is
  // for -- it gives the receiver time to stop gating its snoop logic before the
  // first flit arrives. Only the tear-down half carries the claim that nothing
  // can be outstanding, because the tear-down only begins once everything has
  // retired.
  property p_link_deactivate_when_idle;
    @(posedge vif.clk) disable iff (!link_ever_active || !vif.rst_n)
      ((link_lasm() == VIP_CHI_LASM_DEACTIVATE_E) ||
       (link_lasm() == VIP_CHI_LASM_STOP_E)) |=> !vif.txsactive;
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
    chk_hit(VIP_CHI_CHK_LASM_LEGAL_TRANSITION_E);
  else
    chk_miss(VIP_CHI_CHK_LASM_LEGAL_TRANSITION_E, $sformatf("link stepped %s -> %s; the LASM may only hold or advance STOP -> ACTIVATE -> RUN -> DEACTIVATE -> STOP",
      lasm_state.name(), link_lasm().name()));

  assert property (p_lasm_activation_timeout)
    chk_hit(VIP_CHI_CHK_LASM_ACTIVATION_TIMEOUT_E);
  else
    chk_miss(VIP_CHI_CHK_LASM_ACTIVATION_TIMEOUT_E, $sformatf(
      "link stuck in ACTIVATE for %0d cycles (tx bring-up unacknowledged, limit %0d)",
      lasm_dwell, link_activation_timeout_cycles));

  assert property (p_lasm_deactivation_timeout)
    chk_hit(VIP_CHI_CHK_LASM_DEACTIVATION_TIMEOUT_E);
  else
    chk_miss(VIP_CHI_CHK_LASM_DEACTIVATION_TIMEOUT_E, $sformatf(
      "link stuck in DEACTIVATE for %0d cycles (tx tear-down unacknowledged, limit %0d)",
      lasm_dwell, link_deactivation_timeout_cycles));

  assert property (p_lcrd_quiescent_in_stop)
    chk_hit(VIP_CHI_CHK_LCRD_QUIESCENT_IN_STOP_E);
  else
    chk_miss(VIP_CHI_CHK_LCRD_QUIESCENT_IN_STOP_E, $sformatf("L-credits still outstanding with the link in STOP (tx req/rsp/dat=%0d/%0d/%0d rx req/rsp/dat=%0d/%0d/%0d)",
      txreq_lcrd_count, txrsp_lcrd_count, txdat_lcrd_count,
      rxreq_lcrd_count, rxrsp_lcrd_count, rxdat_lcrd_count));

  assert property (p_req_requires_link)
    chk_hit(VIP_CHI_CHK_REQ_FLITV_REQUIRES_LINK_E);
  else
    chk_miss(VIP_CHI_CHK_REQ_FLITV_REQUIRES_LINK_E, $sformatf("txreqflitv asserted before link activation"));

  assert property (p_rsp_requires_link)
    chk_hit(VIP_CHI_CHK_RSP_FLITV_REQUIRES_LINK_E);
  else
    chk_miss(VIP_CHI_CHK_RSP_FLITV_REQUIRES_LINK_E, $sformatf("txrspflitv asserted before link activation"));

  assert property (p_dat_requires_link)
    chk_hit(VIP_CHI_CHK_DAT_FLITV_REQUIRES_LINK_E);
  else
    chk_miss(VIP_CHI_CHK_DAT_FLITV_REQUIRES_LINK_E, $sformatf("txdatflitv asserted before link activation"));

  assert property (p_req_lcrdv_requires_link)
    chk_hit(VIP_CHI_CHK_REQ_LCRDV_REQUIRES_LINK_E);
  else
    chk_miss(VIP_CHI_CHK_REQ_LCRDV_REQUIRES_LINK_E, $sformatf("txreqlcrdv asserted before link activation"));

  assert property (p_rsp_lcrdv_requires_link)
    chk_hit(VIP_CHI_CHK_RSP_LCRDV_REQUIRES_LINK_E);
  else
    chk_miss(VIP_CHI_CHK_RSP_LCRDV_REQUIRES_LINK_E, $sformatf("txrsplcrdv asserted before link activation"));

  assert property (p_dat_lcrdv_requires_link)
    chk_hit(VIP_CHI_CHK_DAT_LCRDV_REQUIRES_LINK_E);
  else
    chk_miss(VIP_CHI_CHK_DAT_LCRDV_REQUIRES_LINK_E, $sformatf("txdatlcrdv asserted before link activation"));

  assert property (p_req_valid_requires_pend)
    chk_hit(VIP_CHI_CHK_REQ_VALID_REQUIRES_PEND_E);
  else
    chk_miss(VIP_CHI_CHK_REQ_VALID_REQUIRES_PEND_E, $sformatf("txreqflitv sent without txreqflitpend in the preceding cycle"));

  assert property (p_rsp_valid_requires_pend)
    chk_hit(VIP_CHI_CHK_RSP_VALID_REQUIRES_PEND_E);
  else
    chk_miss(VIP_CHI_CHK_RSP_VALID_REQUIRES_PEND_E, $sformatf("txrspflitv sent without txrspflitpend in the preceding cycle"));

  assert property (p_dat_valid_requires_pend)
    chk_hit(VIP_CHI_CHK_DAT_VALID_REQUIRES_PEND_E);
  else
    chk_miss(VIP_CHI_CHK_DAT_VALID_REQUIRES_PEND_E, $sformatf("txdatflitv sent without txdatflitpend in the preceding cycle"));

  assert property (p_req_known_when_valid)
    chk_hit(VIP_CHI_CHK_REQ_KNOWN_WHEN_VALID_E);
  else
    chk_miss(VIP_CHI_CHK_REQ_KNOWN_WHEN_VALID_E, $sformatf("txreqflit contains X/Z while valid"));

  assert property (p_rsp_known_when_valid)
    chk_hit(VIP_CHI_CHK_RSP_KNOWN_WHEN_VALID_E);
  else
    chk_miss(VIP_CHI_CHK_RSP_KNOWN_WHEN_VALID_E, $sformatf("txrspflit contains X/Z while valid"));

  assert property (p_dat_known_when_valid)
    chk_hit(VIP_CHI_CHK_DAT_KNOWN_WHEN_VALID_E);
  else
    chk_miss(VIP_CHI_CHK_DAT_KNOWN_WHEN_VALID_E, $sformatf("txdatflit contains X/Z while valid"));

  // These two are the first chk_miss messages in this file to report VALUES
  // rather than a constant string, so they are also the first to meet the
  // action block's sampling problem: it runs in the Reactive region, where the
  // wire may already carry the next flit. $sampled() returns what the assertion
  // actually judged. A message naming the wrong flit is worse than no message.
  assert property (p_tx_rsp_field_zero)
    chk_hit(VIP_CHI_CHK_RSP_FIELD_ZERO_E);
  else
    chk_miss(VIP_CHI_CHK_RSP_FIELD_ZERO_E, $sformatf(
      "txrsp opcode 0x%0h drove a Table A-4 zero-marked field non-zero (TxnID=0x%0h RespErr=0x%0h Resp=0x%0h DBID=0x%0h)",
      $sampled(vif.txrspflit.opcode), $sampled(vif.txrspflit.txnid),
      $sampled(vif.txrspflit.resperr), $sampled(vif.txrspflit.resp),
      $sampled(vif.txrspflit.dbid)));

  assert property (p_rx_rsp_field_zero)
    chk_hit(VIP_CHI_CHK_RSP_FIELD_ZERO_E);
  else
    chk_miss(VIP_CHI_CHK_RSP_FIELD_ZERO_E, $sformatf(
      "rxrsp opcode 0x%0h drove a Table A-4 zero-marked field non-zero (TxnID=0x%0h RespErr=0x%0h Resp=0x%0h DBID=0x%0h)",
      $sampled(vif.rxrspflit.opcode), $sampled(vif.rxrspflit.txnid),
      $sampled(vif.rxrspflit.resperr), $sampled(vif.rxrspflit.resp),
      $sampled(vif.rxrspflit.dbid)));

  assert property (p_link_sideband_idle_during_reset)
    chk_hit(VIP_CHI_CHK_LINK_SIDEBAND_IDLE_IN_RESET_E);
  else
    chk_miss(VIP_CHI_CHK_LINK_SIDEBAND_IDLE_IN_RESET_E, $sformatf("link sideband was not held idle during reset"));

  assert property (p_req_idle_during_reset)
    chk_hit(VIP_CHI_CHK_REQ_IDLE_IN_RESET_E);
  else
    chk_miss(VIP_CHI_CHK_REQ_IDLE_IN_RESET_E, $sformatf("REQ channel was not held idle during reset"));

  assert property (p_rsp_idle_during_reset)
    chk_hit(VIP_CHI_CHK_RSP_IDLE_IN_RESET_E);
  else
    chk_miss(VIP_CHI_CHK_RSP_IDLE_IN_RESET_E, $sformatf("RSP channel was not held idle during reset"));

  assert property (p_dat_idle_during_reset)
    chk_hit(VIP_CHI_CHK_DAT_IDLE_IN_RESET_E);
  else
    chk_miss(VIP_CHI_CHK_DAT_IDLE_IN_RESET_E, $sformatf("DAT channel was not held idle during reset"));

  assert property (p_link_restarts_after_reset_release)
    chk_hit(VIP_CHI_CHK_LINK_RESTARTS_AFTER_RESET_E);
  else
    chk_miss(VIP_CHI_CHK_LINK_RESTARTS_AFTER_RESET_E, $sformatf("link activation did not restart after reset release"));

  assert property (p_rni_completion_follows_req)
    chk_hit(VIP_CHI_CHK_COMPLETION_FOLLOWS_REQ_E);
  else
    chk_miss(VIP_CHI_CHK_COMPLETION_FOLLOWS_REQ_E, $sformatf("RN-I request did not observe a matching completion within TIMEOUT_CYCLES_P"));

  assert property (p_snf_completion_follows_req)
    chk_hit(VIP_CHI_CHK_COMPLETION_FOLLOWS_REQ_E);
  else
    chk_miss(VIP_CHI_CHK_COMPLETION_FOLLOWS_REQ_E, $sformatf("SN-F-observed request did not drive a matching completion within TIMEOUT_CYCLES_P"));

  assert property (p_rni_atomic_return_uses_dat_completion)
    chk_hit(VIP_CHI_CHK_ATOMIC_RETURN_USES_DAT_COMPLETION_E);
  else
    chk_miss(VIP_CHI_CHK_ATOMIC_RETURN_USES_DAT_COMPLETION_E, $sformatf("RN-I returning atomic observed a final RSP completion before CompData"));

  assert property (p_snf_atomic_return_uses_dat_completion)
    chk_hit(VIP_CHI_CHK_ATOMIC_RETURN_USES_DAT_COMPLETION_E);
  else
    chk_miss(VIP_CHI_CHK_ATOMIC_RETURN_USES_DAT_COMPLETION_E, $sformatf("SN-F returning atomic drove a final RSP completion before CompData"));

  assert property (p_rni_ordered_read_receipt_before_dat)
    chk_hit(VIP_CHI_CHK_ORDERED_READ_RECEIPT_BEFORE_DAT_E);
  else
    chk_miss(VIP_CHI_CHK_ORDERED_READ_RECEIPT_BEFORE_DAT_E, $sformatf("RN-I ordered read completion arrived before ReadReceipt"));

  assert property (p_snf_ordered_read_receipt_before_dat)
    chk_hit(VIP_CHI_CHK_ORDERED_READ_RECEIPT_BEFORE_DAT_E);
  else
    chk_miss(VIP_CHI_CHK_ORDERED_READ_RECEIPT_BEFORE_DAT_E, $sformatf("SN-F ordered read drove DAT completion before ReadReceipt"));

  assert property (p_link_deactivate_when_idle)
    chk_hit(VIP_CHI_CHK_LINK_DEACTIVATE_WHEN_IDLE_E);
  else
    chk_miss(VIP_CHI_CHK_LINK_DEACTIVATE_WHEN_IDLE_E, $sformatf("txsactive was asserted with the link in %s; nothing can be outstanding once a tear-down has begun", link_lasm().name()));

  assert property (p_txsactive_covers_outstanding)
    chk_hit(VIP_CHI_CHK_TXSACTIVE_COVERS_OUTSTANDING_E);
  else
    chk_miss(VIP_CHI_CHK_TXSACTIVE_COVERS_OUTSTANDING_E, $sformatf("TXSACTIVE was low with transactions still outstanding"));

  assert property (p_txsactive_deassert_bounded)
    chk_hit(VIP_CHI_CHK_TXSACTIVE_DEASSERT_BOUNDED_E);
  else
    chk_miss(VIP_CHI_CHK_TXSACTIVE_DEASSERT_BOUNDED_E, $sformatf("TXSACTIVE stayed asserted with nothing outstanding and no flit on any channel"));

  // ---------------------------------------------------------------------------
  // TagOp legality (IHI 0050 E Table 12-2), in its own generate-guarded block
  // rather than alongside the other REQ field rules -- and the guard is the
  // point. Memory tagging is an Issue E feature, so TagOp is not a member of
  // vip_chi_types_d's REQ flit at all: a rule reading vif.*reqflit.tagop from
  // the shared procedural block does not merely stand down on a CHI-D link, it
  // fails to ELABORATE there. A generate-if is pruned before elaboration, which
  // is what makes the field readable only where it exists.
  //
  // A concurrent assertion rather than a statement in the big always_ff, for a
  // second reason worth recording: the per-check counters live on the interface
  // and are written by that always_ff, and SystemVerilog forbids a second
  // always_ff writing the same variable. An assertion action block is not a
  // second procedural driver, which is why every rule in this file that needs
  // its own sampling condition takes this form.
  //
  // Both vantages, matching the other per-opcode REQ rules: the tx side says
  // this VIP does not generate an illegal TagOp, the rx side says it reports one
  // arriving from a DUT.
  // ---------------------------------------------------------------------------
  // ---------------------------------------------------------------------------
  // Retry field legality -- IHI 0050 E section 2.9.4 / D section 2.9.4, and the
  // PCrdReturn rows of E Table A-2 / Table A-3 (D's equivalents agree: D drops
  // only the TagOp column, and D's part-2 row is uniformly "0a", so column
  // identity does not even have to be resolved there).
  //
  // Both rules pass on this VIP today. They are here because the retry
  // machinery has been built since the first cut with nothing judging the
  // fields it drives, and because the PCrdReturn one guards a specific and
  // plausible regression: the driver builds the flit from '0 and fills in five
  // fields, and the obvious "simplification" is to copy the retried request and
  // overwrite the opcode.
  // ---------------------------------------------------------------------------

  // Every column Table A-2 and Table A-3 mark inapplicable-and-zero for
  // PCrdReturn, restricted to the members both issues carry. What is NOT here
  // matters as much as what is:
  //
  //   QoS, TgtID, SrcID, Opcode  applicable -- the transaction's identity
  //   PCrdType                   applicable, and section 2.6.6 requires it to
  //                              match the grant being returned, so a zero here
  //                              would be the bug
  //   TraceTag                   Table A-2 gives it "Y". A conformant PCrdReturn
  //                              may carry a trace tag and asserting zero would
  //                              false-fail it.
  //   RSVDC                      "Y", and not modelled on this flit anyway
  //   DoDWT                      "-" in Table A-3: it shares SnpAttr's bit, and
  //                              the VIP models the bit as snpattr, which IS
  //                              asserted zero just below
  //
  // The shared-bit columns reach their VIP names the same way: StashNID lands on
  // returnnid, StashLPIDValid on returntxnid, and TagGroupID[4:0] with
  // GroupIDExt on lpid (plus the separate groupidext member on Issue E, checked
  // in g_req_pcrd_return_tagged_fields below).
  function automatic bit req_pcrd_return_fields_zero(input req_flit_t f);
    return ((f.txnid        == '0)   &&
            (f.returnnid    == '0)   &&
            (f.returntxnid  == '0)   &&
            (f.endian       == 1'b0) &&
            (f.size         == '0)   &&
            (f.addr         == '0)   &&
            (f.ns           == '0)   &&
            (f.likelyshared == 1'b0) &&
            (f.allowretry   == 1'b0) &&
            (f.order        == '0)   &&
            (f.memattr      == '0)   &&
            (f.snpattr      == '0)   &&
            (f.lpid         == '0)   &&
            (f.excl         == '0)   &&
            (f.expcompack   == 1'b0) &&
            (f.mpam         == '0));
  endfunction

  function automatic bit req_is_pcrd_return(input req_opcode_t opcode);
    return (opcode == req_opcode_t'(VIP_CHI_REQ_PCRD_RETURN_C));
  endfunction

  property p_tx_req_allow_retry_pcrd_zero;
    @(posedge vif.clk) disable iff (!checks_enable || !vif.rst_n)
      (ROLE_IS_REQUESTER_C && vif.txreqflitv && vif.txreqflit.allowretry) |->
        (vif.txreqflit.pcrdtype == '0);
  endproperty

  property p_rx_req_allow_retry_pcrd_zero;
    @(posedge vif.clk) disable iff (!checks_enable || !vif.rst_n)
      (ROLE_IS_COMPLETER_C && vif.rxreqflitv && vif.rxreqflit.allowretry) |->
        (vif.rxreqflit.pcrdtype == '0);
  endproperty

  property p_tx_req_pcrd_return_fields_zero;
    @(posedge vif.clk) disable iff (!checks_enable || !vif.rst_n)
      (ROLE_IS_REQUESTER_C && vif.txreqflitv &&
       req_is_pcrd_return(req_opcode_t'(vif.txreqflit.opcode))) |->
        req_pcrd_return_fields_zero(vif.txreqflit);
  endproperty

  property p_rx_req_pcrd_return_fields_zero;
    @(posedge vif.clk) disable iff (!checks_enable || !vif.rst_n)
      (ROLE_IS_COMPLETER_C && vif.rxreqflitv &&
       req_is_pcrd_return(req_opcode_t'(vif.rxreqflit.opcode))) |->
        req_pcrd_return_fields_zero(vif.rxreqflit);
  endproperty

  assert property (p_tx_req_allow_retry_pcrd_zero)
    chk_hit(VIP_CHI_CHK_REQ_ALLOW_RETRY_PCRD_ZERO_E);
  else
    chk_miss(VIP_CHI_CHK_REQ_ALLOW_RETRY_PCRD_ZERO_E, $sformatf(
      "opcode 0x%0h was issued with AllowRetry set and PCrdType 0x%0h; section 2.9.4 requires PCrdType zero while a Retry response is still allowed",
      $sampled(vif.txreqflit.opcode), $sampled(vif.txreqflit.pcrdtype)));

  assert property (p_rx_req_allow_retry_pcrd_zero)
    chk_hit(VIP_CHI_CHK_REQ_ALLOW_RETRY_PCRD_ZERO_E);
  else
    chk_miss(VIP_CHI_CHK_REQ_ALLOW_RETRY_PCRD_ZERO_E, $sformatf(
      "opcode 0x%0h was received with AllowRetry set and PCrdType 0x%0h; section 2.9.4 requires PCrdType zero while a Retry response is still allowed",
      $sampled(vif.rxreqflit.opcode), $sampled(vif.rxreqflit.pcrdtype)));

  assert property (p_tx_req_pcrd_return_fields_zero)
    chk_hit(VIP_CHI_CHK_REQ_PCRD_RETURN_FIELDS_ZERO_E);
  else
    chk_miss(VIP_CHI_CHK_REQ_PCRD_RETURN_FIELDS_ZERO_E, $sformatf(
      "PCrdReturn was issued with a Table A-2/A-3 zero-marked field non-zero (TxnID=0x%0h Addr=0x%0h Size=0x%0h NS=%0b AllowRetry=%0b Order=0x%0h MemAttr=0x%0h SnpAttr=%0b LPID=0x%0h Excl=%0b ExpCompAck=%0b Endian=%0b ReturnNID=0x%0h ReturnTxnID=0x%0h LikelyShared=%0b MPAM=0x%0h)",
      $sampled(vif.txreqflit.txnid), $sampled(vif.txreqflit.addr),
      $sampled(vif.txreqflit.size), $sampled(vif.txreqflit.ns),
      $sampled(vif.txreqflit.allowretry), $sampled(vif.txreqflit.order),
      $sampled(vif.txreqflit.memattr), $sampled(vif.txreqflit.snpattr),
      $sampled(vif.txreqflit.lpid), $sampled(vif.txreqflit.excl),
      $sampled(vif.txreqflit.expcompack), $sampled(vif.txreqflit.endian),
      $sampled(vif.txreqflit.returnnid), $sampled(vif.txreqflit.returntxnid),
      $sampled(vif.txreqflit.likelyshared), $sampled(vif.txreqflit.mpam)));

  assert property (p_rx_req_pcrd_return_fields_zero)
    chk_hit(VIP_CHI_CHK_REQ_PCRD_RETURN_FIELDS_ZERO_E);
  else
    chk_miss(VIP_CHI_CHK_REQ_PCRD_RETURN_FIELDS_ZERO_E, $sformatf(
      "PCrdReturn was received with a Table A-2/A-3 zero-marked field non-zero (TxnID=0x%0h Addr=0x%0h Size=0x%0h NS=%0b AllowRetry=%0b Order=0x%0h MemAttr=0x%0h SnpAttr=%0b LPID=0x%0h Excl=%0b ExpCompAck=%0b Endian=%0b ReturnNID=0x%0h ReturnTxnID=0x%0h LikelyShared=%0b MPAM=0x%0h)",
      $sampled(vif.rxreqflit.txnid), $sampled(vif.rxreqflit.addr),
      $sampled(vif.rxreqflit.size), $sampled(vif.rxreqflit.ns),
      $sampled(vif.rxreqflit.allowretry), $sampled(vif.rxreqflit.order),
      $sampled(vif.rxreqflit.memattr), $sampled(vif.rxreqflit.snpattr),
      $sampled(vif.rxreqflit.lpid), $sampled(vif.rxreqflit.excl),
      $sampled(vif.rxreqflit.expcompack), $sampled(vif.rxreqflit.endian),
      $sampled(vif.rxreqflit.returnnid), $sampled(vif.rxreqflit.returntxnid),
      $sampled(vif.rxreqflit.likelyshared), $sampled(vif.rxreqflit.mpam)));

  // The two PCrdReturn columns that exist only on Issue E, under the same check
  // id: TagOp is absent from Table A-2 on Issue D, and GroupIDExt is folded into
  // the LPID member there rather than carried separately. Split out because a
  // CHI-D bind's REQ flit has neither member, so naming them above would fail
  // elaboration on every D bind rather than read zero.
  if (CFG_P.ISSUE_P == VIP_CHI_ISSUE_E_E) begin : g_req_pcrd_return_tagged_fields

    property p_tx_req_pcrd_return_e_fields_zero;
      @(posedge vif.clk) disable iff (!checks_enable || !vif.rst_n)
        (ROLE_IS_REQUESTER_C && vif.txreqflitv &&
         req_is_pcrd_return(req_opcode_t'(vif.txreqflit.opcode))) |->
          ((vif.txreqflit.tagop == '0) && (vif.txreqflit.groupidext == '0));
    endproperty

    property p_rx_req_pcrd_return_e_fields_zero;
      @(posedge vif.clk) disable iff (!checks_enable || !vif.rst_n)
        (ROLE_IS_COMPLETER_C && vif.rxreqflitv &&
         req_is_pcrd_return(req_opcode_t'(vif.rxreqflit.opcode))) |->
          ((vif.rxreqflit.tagop == '0) && (vif.rxreqflit.groupidext == '0));
    endproperty

    assert property (p_tx_req_pcrd_return_e_fields_zero)
      chk_hit(VIP_CHI_CHK_REQ_PCRD_RETURN_FIELDS_ZERO_E);
    else
      chk_miss(VIP_CHI_CHK_REQ_PCRD_RETURN_FIELDS_ZERO_E, $sformatf(
        "PCrdReturn was issued with TagOp 0x%0h GroupIDExt 0x%0h, and Table A-2/A-3 make both inapplicable and zero for it",
        $sampled(vif.txreqflit.tagop), $sampled(vif.txreqflit.groupidext)));

    assert property (p_rx_req_pcrd_return_e_fields_zero)
      chk_hit(VIP_CHI_CHK_REQ_PCRD_RETURN_FIELDS_ZERO_E);
    else
      chk_miss(VIP_CHI_CHK_REQ_PCRD_RETURN_FIELDS_ZERO_E, $sformatf(
        "PCrdReturn was received with TagOp 0x%0h GroupIDExt 0x%0h, and Table A-2/A-3 make both inapplicable and zero for it",
        $sampled(vif.rxreqflit.tagop), $sampled(vif.rxreqflit.groupidext)));
  end

  if (CFG_P.ISSUE_P == VIP_CHI_ISSUE_E_E) begin : g_req_tagop_legal

    // A helper because SystemVerilog does not permit a bit-select of a function
    // call result, and the mask is the natural shape for a five-column table over
    // a two-bit field.
    function automatic bit tagop_permitted(
      input vip_chi_req_opcode_t opcode,
      input logic [1 : 0]        tagop
    );
      logic [3 : 0] mask;
      mask = vip_chi_types_pkg::vip_chi_req_tagop_permitted_mask(
               CFG_P.ISSUE_P, opcode);
      return mask[tagop];
    endfunction

    property p_tx_req_tagop_legal;
      @(posedge vif.clk) disable iff (!checks_enable || !vif.rst_n)
        (ROLE_IS_REQUESTER_C && vif.txreqflitv) |->
          tagop_permitted(vip_chi_req_opcode_t'(vif.txreqflit.opcode),
                          vif.txreqflit.tagop);
    endproperty

    property p_rx_req_tagop_legal;
      @(posedge vif.clk) disable iff (!checks_enable || !vif.rst_n)
        (ROLE_IS_COMPLETER_C && vif.rxreqflitv) |->
          tagop_permitted(vip_chi_req_opcode_t'(vif.rxreqflit.opcode),
                          vif.rxreqflit.tagop);
    endproperty

    assert property (p_tx_req_tagop_legal)
      chk_hit(VIP_CHI_CHK_REQ_TAGOP_LEGAL_E);
    else
      chk_miss(VIP_CHI_CHK_REQ_TAGOP_LEGAL_E, $sformatf(
        "opcode 0x%0h was issued with TagOp 0x%0h, which Table 12-2 does not permit for it",
        vif.txreqflit.opcode, vif.txreqflit.tagop));

    assert property (p_rx_req_tagop_legal)
      chk_hit(VIP_CHI_CHK_REQ_TAGOP_LEGAL_E);
    else
      chk_miss(VIP_CHI_CHK_REQ_TAGOP_LEGAL_E, $sformatf(
        "opcode 0x%0h was received with TagOp 0x%0h, which Table 12-2 does not permit for it",
        vif.rxreqflit.opcode, vif.rxreqflit.tagop));
  end

endmodule

`endif
