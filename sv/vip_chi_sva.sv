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
    end
    else begin
      req_outstanding_delta = 0;

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
              chk_miss(VIP_CHI_CHK_TXNID_REUSE_REQUESTER_E, $sformatf("requester reused a TxnID while the earlier request was still in flight"));
            end
            else begin
              chk_hit(VIP_CHI_CHK_TXNID_REUSE_REQUESTER_E);
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
          if (!write_completion_seen_by_txn[txn_id_to_index(txn_id_t'(vif.txrspflit.txnid))]) begin
            chk_miss(VIP_CHI_CHK_COMPACK_BEFORE_COMPLETION_E, $sformatf("CompAck was sent before a write completion response"));
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
              chk_miss(VIP_CHI_CHK_TXNID_REUSE_COMPLETER_E, $sformatf("completer observed a reused request TxnID while the earlier request was still in flight"));
            end
            else begin
              chk_hit(VIP_CHI_CHK_TXNID_REUSE_COMPLETER_E);
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
                if (expected_completion_opcode_by_txn[txn_idx] != dat_opcode_t'(vif.txdatflit.opcode)) begin
                  chk_miss(VIP_CHI_CHK_TX_READ_COMPLETION_DAT_OPCODE_E, $sformatf("TX read completion DAT opcode did not match the request type"));
                end
                else begin
                  chk_hit(VIP_CHI_CHK_TX_READ_COMPLETION_DAT_OPCODE_E);
                end
                if (expected_completion_beats_by_txn[txn_idx] != 1) begin
                  chk_miss(VIP_CHI_CHK_TX_READ_COMPLETION_DAT_BEAT_COUNT_E, $sformatf("TX read completion DAT burst beat count did not match the request size"));
                end
                else begin
                  chk_hit(VIP_CHI_CHK_TX_READ_COMPLETION_DAT_BEAT_COUNT_E);
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
            chk_miss(VIP_CHI_CHK_TX_DAT_TXNID_STABLE_E, $sformatf("TX DAT burst changed txnid before txdatflitpend dropped"));
          end
          else begin
            chk_hit(VIP_CHI_CHK_TX_DAT_TXNID_STABLE_E);
          end

          if (!dat_reorder_allowed &&
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
                if (expected_completion_opcode_by_txn[txn_idx] != txdat_burst_opcode) begin
                  chk_miss(VIP_CHI_CHK_TX_READ_COMPLETION_DAT_OPCODE_E, $sformatf("TX read completion DAT opcode did not match the request type"));
                end
                else begin
                  chk_hit(VIP_CHI_CHK_TX_READ_COMPLETION_DAT_OPCODE_E);
                end
                if (expected_completion_beats_by_txn[txn_idx] != (txdat_burst_count + 1)) begin
                  chk_miss(VIP_CHI_CHK_TX_READ_COMPLETION_DAT_BEAT_COUNT_E, $sformatf("TX read completion DAT burst beat count did not match the request size"));
                end
                else begin
                  chk_hit(VIP_CHI_CHK_TX_READ_COMPLETION_DAT_BEAT_COUNT_E);
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
                if (expected_completion_opcode_by_txn[txn_idx] != dat_opcode_t'(vif.rxdatflit.opcode)) begin
                  chk_miss(VIP_CHI_CHK_RX_READ_COMPLETION_DAT_OPCODE_E, $sformatf("RX read completion DAT opcode did not match the request type"));
                end
                else begin
                  chk_hit(VIP_CHI_CHK_RX_READ_COMPLETION_DAT_OPCODE_E);
                end
                if (expected_completion_beats_by_txn[txn_idx] != 1) begin
                  chk_miss(VIP_CHI_CHK_RX_READ_COMPLETION_DAT_BEAT_COUNT_E, $sformatf("RX read completion DAT burst beat count did not match the request size"));
                end
                else begin
                  chk_hit(VIP_CHI_CHK_RX_READ_COMPLETION_DAT_BEAT_COUNT_E);
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
            chk_miss(VIP_CHI_CHK_RX_DAT_TXNID_STABLE_E, $sformatf("RX DAT burst changed txnid before rxdatflitpend dropped"));
          end
          else begin
            chk_hit(VIP_CHI_CHK_RX_DAT_TXNID_STABLE_E);
          end

          if (!dat_reorder_allowed &&
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
                if (expected_completion_opcode_by_txn[txn_idx] != rxdat_burst_opcode) begin
                  chk_miss(VIP_CHI_CHK_RX_READ_COMPLETION_DAT_OPCODE_E, $sformatf("RX read completion DAT opcode did not match the request type"));
                end
                else begin
                  chk_hit(VIP_CHI_CHK_RX_READ_COMPLETION_DAT_OPCODE_E);
                end
                if (expected_completion_beats_by_txn[txn_idx] != (rxdat_burst_count + 1)) begin
                  chk_miss(VIP_CHI_CHK_RX_READ_COMPLETION_DAT_BEAT_COUNT_E, $sformatf("RX read completion DAT burst beat count did not match the request size"));
                end
                else begin
                  chk_hit(VIP_CHI_CHK_RX_READ_COMPLETION_DAT_BEAT_COUNT_E);
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

  assert property (p_req_pend_requires_valid)
    chk_hit(VIP_CHI_CHK_REQ_PEND_REQUIRES_VALID_E);
  else
    chk_miss(VIP_CHI_CHK_REQ_PEND_REQUIRES_VALID_E, $sformatf("txreqflitpend asserted without txreqflitv"));

  assert property (p_rsp_pend_requires_valid)
    chk_hit(VIP_CHI_CHK_RSP_PEND_REQUIRES_VALID_E);
  else
    chk_miss(VIP_CHI_CHK_RSP_PEND_REQUIRES_VALID_E, $sformatf("txrspflitpend asserted without txrspflitv"));

  assert property (p_dat_pend_requires_valid)
    chk_hit(VIP_CHI_CHK_DAT_PEND_REQUIRES_VALID_E);
  else
    chk_miss(VIP_CHI_CHK_DAT_PEND_REQUIRES_VALID_E, $sformatf("txdatflitpend asserted without txdatflitv"));

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

endmodule

`endif
