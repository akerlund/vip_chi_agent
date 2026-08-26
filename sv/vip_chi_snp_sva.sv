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

`ifndef VIP_CHI_SNP_SVA
`define VIP_CHI_SNP_SVA

// -----------------------------------------------------------------------------
// vip_chi_snp_sva -- focused protocol checker for the SNP channel only.
//
// The full vip_chi_sva checks REQ/RSP/DAT and is bound to the RN-I/SN-F and
// CHI-E links; its structural + credit properties were validated against those
// non-coherent flows. Rather than widen it (and risk false-firing on coherent
// traffic it never saw), this small sibling checks ONLY the SNP channel and is
// bound to the coherent RN-F/HN-F interfaces.
//
// It is deliberately role-agnostic: the SNP flit flows home->RN, so on an HN-F
// interface the send side (txsnp*) is live and the receive side idle, and on an
// RN-F interface the reverse. The properties key off whichever signals are live;
// the idle side is vacuously true. Two credit shadows mirror the driver-side
// vip_chi_lcrd_mgr pools exactly (see vip_chi_sva for the pairing rationale):
//   * txsnp pool (HN-F send): granted by the inbound rxsnplcrdv, consumed by
//     each txsnpflitv -- an underflow means a snoop was launched with no credit.
//   * rxsnp pool (RN-F receive): granted by this node's own txsnplcrdv, consumed
//     by each rxsnpflitv -- an underflow means the peer over-sent snoops.
// -----------------------------------------------------------------------------
// -----------------------------------------------------------------------------
// A warning about ROLE_P, for whoever reaches for it first.
//
// It is passed at every instantiation with a real role -- HN-F on the home side,
// RN-F on the requester side -- and NOTHING IN THIS MODULE READS IT. Every
// property here is gated on `rst_n` and on one of `checks_enable` or
// `link_ever_active`, all three of them runtime state the per-ID enable/severity
// array already models, so no rule in this file can be switched off by
// elaboration.
//
// That is the only reason does not apply here. That finding is about
// exactly this: `check_enabled` doubles as the ownership record -- "an ID left
// false is either switched off or belongs to a bind this interface does not
// carry" -- and it records the RUNTIME array, not the parameters. A property
// gated in its `disable iff` on an elaboration parameter therefore exports
// `enabled=1 passes=0 fails=0`, which reads as a rule nothing reached rather
// than one that could never fire. It took a per-bind vacuity axis to notice, in
// vip_chi_sva, for ENABLE_COMPLETION_TIMEOUT_P.
//
// So: if you gate a property on ROLE_P (or on any parameter), the ownership
// `initial` below has to clear that ID's `check_enabled` on the binds where the
// gate is false, in the same commit. Otherwise the tally will claim the rule is
// live on interfaces where it cannot evaluate.
// -----------------------------------------------------------------------------
module vip_chi_snp_sva #(
  parameter vip_chi_cfg_t  CFG_P        = VIP_CHI_DEFAULT_CFG_C,
  parameter type           FLIT_TYPES_T = vip_chi_types #(CFG_P),
  parameter vip_chi_role_t ROLE_P       = VIP_CHI_ROLE_MONITOR_E
  )(
    vip_chi_if vif,
    input bit  checks_enable
  );

  // The protocol maximum, not a shadow-counter bound. IHI 0050 E 14.2.1 /
  // D 13.2.1: "The minimum number of L-Credits that a receiver can provide is
  // one. The maximum number of L-Credits that a receiver can provide is 15."
  // One LCRDV signal per channel, and SNP is a channel like any other.
  //
  // This was 64, which is not a number the specification contains. At 64 the
  // overflow rule could not fire on any conformant-looking peer -- a receiver
  // granting 16 through 64 credits was over-granting and reported as fine, so
  // the rule was a false NEGATIVE rather than a false alarm. 15 is the value
  // that makes it a protocol check.
  localparam int unsigned LCRD_MAX_C = 15;
  localparam int unsigned SNP_SEND_CAP_C = LCRD_MAX_C;

  // TWO state machines, matching vip_chi_sva -- see the long comment there, and
  // 14.6.1, which defines them by the direction of the PAYLOAD rather than by
  // signal name. This file kept the OR-collapsed form after the main checker
  // abandoned it, so the two SNP rules below were the last pair in the VIP still
  // judged against "whichever direction happened to be up".
  //
  // The SNP channel splits across BOTH machines, which is why it matters here:
  //
  //   txsnpflitv   we SEND snoops   -> the payload is our output  -> TX
  //   txsnplcrdv   we GRANT credit  -> we RECEIVE snoops, so the
  //                                    payload is our input       -> RX
  //
  // A home sends snoops and an RN-F receives them, so at either endpoint exactly
  // one of the two is live -- and under the reduction each was judged against a
  // state the other direction could satisfy on its behalf.
  function automatic vip_chi_lasm_state_t tx_lasm();
    return vip_chi_lasm(vif.txlinkactivereq, vif.rxlinkactiveack);
  endfunction

  function automatic vip_chi_lasm_state_t rx_lasm();
    return vip_chi_lasm(vif.rxlinkactivereq, vif.txlinkactiveack);
  endfunction

  // Anywhere but STOP (ACTIVATE/RUN/DEACTIVATE). Credit grants are legal from
  // ACTIVATE onward, which is how the initial pool reaches the peer before the
  // link is RUN at all.
  function automatic bit rx_link_is_active();
    return (rx_lasm() != VIP_CHI_LASM_STOP_E);
  endfunction

  // Single-NBA credit update: grant (+1, overflow flagged) then consume (-1,
  // underflow flagged) so a same-cycle grant+consume is safe (0->1->0).
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
        chk_miss(VIP_CHI_CHK_SNP_LCRD_OVERFLOW_E, $sformatf("%s SNP L-credit grant overflowed the tracked count", chan));
      end
      else begin
        chk_hit(VIP_CHI_CHK_SNP_LCRD_OVERFLOW_E);
        nxt = nxt + 1;
      end
    end
    if (consume) begin
      if (nxt == 0) begin
        chk_miss(VIP_CHI_CHK_SNP_LCRD_UNDERFLOW_E, $sformatf("%s SNP L-credit consumed with no credit available (underflow)", chan));
      end
      else begin
        chk_hit(VIP_CHI_CHK_SNP_LCRD_UNDERFLOW_E);
        nxt = nxt - 1;
      end
    end
    return nxt;
  endfunction

  int unsigned txsnp_lcrd_count;
  int unsigned rxsnp_lcrd_count;

  // Sticky "this interface's link has come up at least once". Gates the
  // reset-idle rule below, for the reason given there; deliberately survives
  // reset, which is exactly what makes it usable as that gate.
  bit link_ever_active;

  always_ff @(posedge vif.clk) begin
    if ((vif.txlinkactivereq === 1'b1) || (vif.rxlinkactivereq === 1'b1)) begin
      link_ever_active <= 1'b1;
    end
  end

  // Gated on RESET ONLY, like the REQ/RSP/DAT shadow in vip_chi_sva and unlike
  // the rest of the tracked state here. Under the checks_enable gate these counts
  // were wiped the moment the link left RUN, so a credit granted before a
  // tear-down was forgotten across it -- and the first snoop after the next
  // bring-up could spend a stale credit with the underflow rule counting from
  // zero either way. Surviving the gap is what makes the counts mean anything
  // across it; only a reset genuinely discards both ends' state. The pyUVM twin
  // has always cleared on reset alone, so this was also a cross-port difference
  // in the model that no gate compares.
  always_ff @(posedge vif.clk or negedge vif.rst_n) begin
    if (!vif.rst_n) begin
      txsnp_lcrd_count <= 0;
      rxsnp_lcrd_count <= 0;
    end
    else begin
      // txsnp send pool (HN-F): a txsnpflitv send is authorized by the inbound
      // rxsnplcrdv (the RN-F's SNP receive credit, cross-wired to us).
      txsnp_lcrd_count <= lcrd_next(txsnp_lcrd_count, vif.rxsnplcrdv, vif.txsnpflitv, SNP_SEND_CAP_C, "txsnp");
      // rxsnp receive shadow (RN-F): an inbound rxsnpflitv was authorized by this
      // node's own earlier txsnplcrdv grant.
      rxsnp_lcrd_count <= lcrd_next(rxsnp_lcrd_count, vif.txsnplcrdv, vif.rxsnpflitv, SNP_SEND_CAP_C, "rxsnp");
    end
  end

  // Per-check identity, enable, severity and statistics. Mirrors vip_chi_sva --
  // see the long comment there. This bind owns ONLY the CHI_SNP_* range, so it
  // initialises only those IDs: the main checker shares this interface and
  // whichever elaborated second would otherwise clear the other's settings.
  function automatic void apply_check_plusarg(input string arg, input bit as_warning);
    string list;
    string name;
    int    start_pos;
    bit    matched;

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
          if (vip_chi_check_is_snp(vip_chi_check_id_t'(id)) &&
              (vip_chi_check_name(vip_chi_check_id_t'(id)) == name)) begin
            matched = 1'b1;
            if (as_warning) begin
              vif.check_severity[id] = VIP_CHI_CHK_SEV_WARNING_E;
            end
            else begin
              vif.check_enabled[id] = 1'b0;
            end
          end
        end
        // Unmatched names are NOT fatal here: the main checker owns most of the
        // registry and validates the same plusarg, so a name outside the SNP
        // range is that bind's business, not an error.
      end
    end
  endfunction

  initial begin
    for (int unsigned id = 0; id < int'(VIP_CHI_CHK_NUM_E); id++) begin
      if (vip_chi_check_is_snp(vip_chi_check_id_t'(id))) begin
        vif.check_severity[id]   = VIP_CHI_CHK_SEV_ERROR_E;
        vif.check_enabled[id]    = 1'b1;
        vif.check_pass_count[id] = 0;
        vif.check_fail_count[id] = 0;
      end
    end
    apply_check_plusarg("vip_chi_disable_check=%s", 1'b0);
    apply_check_plusarg("vip_chi_warn_check=%s", 1'b1);
  end

  function automatic void chk_hit(input vip_chi_check_id_t id);
    if (!vif.check_enabled[id]) begin
      return;
    end
    vif.check_pass_count[id] = vif.check_pass_count[id] + 1;
  endfunction

  // The clause the rule enforces, appended to every report so a log line names
  // the text that was violated and not only the rule that noticed. Empty for
  // the X/Z rules, which claim none -- see vip_chi_check_spec.
  function automatic string chk_where(input vip_chi_check_id_t id);
    string s;
    s = vip_chi_check_spec(id);
    return (s.len() == 0) ? "" : {" IHI 0050 ", s, "."};
  endfunction

  function automatic void chk_miss(input vip_chi_check_id_t id, input string msg);
    if (!vif.check_enabled[id]) begin
      return;
    end
    vif.check_fail_count[id] = vif.check_fail_count[id] + 1;
    case (vif.check_severity[id])
      VIP_CHI_CHK_SEV_OFF_E: begin
      end
      VIP_CHI_CHK_SEV_WARNING_E: begin
        $warning("vip_chi_snp_sva: [%s] %s%s", vip_chi_check_name(id), msg, chk_where(id));
      end
      default: begin
        $error("vip_chi_snp_sva: [%s] %s%s", vip_chi_check_name(id), msg, chk_where(id));
      end
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // Per-opcode field applicability, judged at BOTH ends of the link. The three
  // rules below are total: every snoop flit records a pass or a fail, so a zero
  // count means no snoop reached this checker rather than "the classifier
  // declined this opcode". That distinction is the whole reason the tallies are
  // readable -- see the CHI_REQ_* field rules in vip_chi_sva for the same shape.
  //
  // Both vantages because they answer different questions. The tx side says this
  // VIP does not GENERATE an illegal snoop; the rx side says it REPORTS one
  // arriving from a DUT, which is the half an integration depends on. This
  // module is bound to both ends of every coherent link, so one property pair
  // covers both without a role parameter.
  // ---------------------------------------------------------------------------
  typedef FLIT_TYPES_T::vip_chi_snp_flit_t snp_flit_view_t;

  function automatic snp_flit_view_t tx_snp_view();
    return snp_flit_view_t'(vif.txsnpflit);
  endfunction

  function automatic snp_flit_view_t rx_snp_view();
    return snp_flit_view_t'(vif.rxsnpflit);
  endfunction

  // An L-credit return is a link-layer flit, not a snoop: SNP opcode 0x00 is
  // SnpLCrdReturn and every other field of it is zero. The three field rules
  // below decline it rather than passing it, because they all pass trivially on
  // an all-zero flit and a pass recorded there would count a credit return among
  // the snoops this checker has judged -- which is the evidence a zero fail count
  // is read against.
  function automatic bit snp_is_lcrd_return(input snp_flit_view_t flit);
    return (vip_chi_snp_opcode_t'(flit.opcode) ==
            vip_chi_snp_opcode_t'(VIP_CHI_SNP_LCRD_RETURN_C));
  endfunction

  // The six report messages below run in the REACTIVE region, where the wire may
  // already carry the next snoop, so reading the views live names the wrong flit.
  // The views cannot be $sampled() as a whole -- they read the interface inside a
  // function -- so each action block samples the raw flit and casts it here. Same
  // cast, one region earlier.
  function automatic snp_flit_view_t snp_view_of(
    input logic [$bits(snp_flit_view_t)-1:0] raw
  );
    return snp_flit_view_t'(raw);
  endfunction

  // FwdNID and FwdTxnID are applicable only in Forward type snoops and must be
  // zero in every other snoop request (E 13.10.5 / 13.10.16).
  function automatic bit snp_fwd_fields_legal(input snp_flit_view_t flit);
    if (vip_chi_types_pkg::vip_chi_snp_opcode_is_forwarding(
          vip_chi_snp_opcode_t'(flit.opcode))) begin
      return 1'b1;
    end
    return (flit.fwdnid == '0) && (flit.fwdtxnid == '0);
  endfunction

  function automatic bit snp_ret_to_src_legal(input snp_flit_view_t flit);
    if (vip_chi_types_pkg::vip_chi_snp_ret_to_src_must_be_zero(
          vip_chi_snp_opcode_t'(flit.opcode))) begin
      return (flit.rettosrc == 1'b0);
    end
    return 1'b1;
  endfunction

  function automatic bit snp_do_not_go_to_sd_legal(input snp_flit_view_t flit);
    if (vip_chi_types_pkg::vip_chi_snp_do_not_go_to_sd_required(
          CFG_P.ISSUE_P, vip_chi_snp_opcode_t'(flit.opcode))) begin
      return (flit.donotgotosd == 1'b1);
    end
    return 1'b1;
  endfunction

  property p_tx_snp_fwd_fields_zero;
    @(posedge vif.clk) disable iff (!checks_enable || !vif.rst_n)
      (vif.txsnpflitv && !snp_is_lcrd_return(tx_snp_view())) |->
        snp_fwd_fields_legal(tx_snp_view());
  endproperty

  property p_rx_snp_fwd_fields_zero;
    @(posedge vif.clk) disable iff (!checks_enable || !vif.rst_n)
      (vif.rxsnpflitv && !snp_is_lcrd_return(rx_snp_view())) |->
        snp_fwd_fields_legal(rx_snp_view());
  endproperty

  property p_tx_snp_ret_to_src_legal;
    @(posedge vif.clk) disable iff (!checks_enable || !vif.rst_n)
      (vif.txsnpflitv && !snp_is_lcrd_return(tx_snp_view())) |->
        snp_ret_to_src_legal(tx_snp_view());
  endproperty

  property p_rx_snp_ret_to_src_legal;
    @(posedge vif.clk) disable iff (!checks_enable || !vif.rst_n)
      (vif.rxsnpflitv && !snp_is_lcrd_return(rx_snp_view())) |->
        snp_ret_to_src_legal(rx_snp_view());
  endproperty

  property p_tx_snp_do_not_go_to_sd_legal;
    @(posedge vif.clk) disable iff (!checks_enable || !vif.rst_n)
      (vif.txsnpflitv && !snp_is_lcrd_return(tx_snp_view())) |->
        snp_do_not_go_to_sd_legal(tx_snp_view());
  endproperty

  property p_rx_snp_do_not_go_to_sd_legal;
    @(posedge vif.clk) disable iff (!checks_enable || !vif.rst_n)
      (vif.rxsnpflitv && !snp_is_lcrd_return(rx_snp_view())) |->
        snp_do_not_go_to_sd_legal(rx_snp_view());
  endproperty

  // Structural properties (tx side: the SNP source drives txsnp*/receives credit
  // returns; on an RN-F interface these are idle so the checks are vacuous).
  //
  // Gated on link_ever_active rather than checks_enable, and these two are the
  // SNP twins of the REQ/RSP/DAT rules that moved for the same reason.
  // checks_enable IS this interface's activation request, so it is low in both
  // DEACTIVATE and STOP -- exactly the two states in which "no snoop may go out"
  // and "no credit may be advertised once the link is down" have any content. The
  // gate switched each rule off in the only state it could fail in, and left the
  // tear-down completely unwatched on this channel.
  // DEACTIVATE admits exactly one kind of flit, and the REQ/RSP/DAT twin in
  // vip_chi_sva carries the same exception for the same reason: a sender asked to
  // take the link down must first hand back every L-credit it holds, and the only
  // way to hand one back is to send a flit under it. Refusing all traffic here
  // would make a clean tear-down impossible on this channel -- the SNP credits
  // would be stranded and the quiescence rule below would fire on a home that
  // did everything right.
  //
  // Anything other than a credit return is still a violation in DEACTIVATE, which
  // is what keeps the exception narrow: it admits the one flit the tear-down needs
  // and nothing else.
  function automatic bit snp_send_allowed();
    if (tx_lasm() == VIP_CHI_LASM_RUN_E) begin
      return 1'b1;
    end
    if (tx_lasm() != VIP_CHI_LASM_DEACTIVATE_E) begin
      return 1'b0;
    end
    return snp_is_lcrd_return(tx_snp_view());
  endfunction

  property p_snp_flit_requires_link;
    @(posedge vif.clk) disable iff (!link_ever_active || !vif.rst_n)
      vif.txsnpflitv |-> snp_send_allowed();
  endproperty

  property p_snp_lcrdv_requires_link;
    @(posedge vif.clk) disable iff (!link_ever_active || !vif.rst_n)
      vif.txsnplcrdv |-> rx_link_is_active();
  endproperty

  // The SNP half of "no credit may be left stranded by a tear-down". The
  // REQ/RSP/DAT rule in vip_chi_sva cannot reach this channel -- the SNP rules
  // live in this module precisely so a non-coherent link elaborates none of them,
  // and this module owns the only SNP credit shadow there is. So on a coherent
  // link the tear-down was judged on three channels of four, and the missing one
  // is the channel only that link has.
  //
  // Split by pool for the reason the REQ/RSP/DAT twin is: each pool belongs to
  // one machine. txsnp is what this component may still SEND, so it is stranded
  // when the TRANSMIT link stops; rxsnp is what it has GRANTED and the peer may
  // still spend, so it is stranded when the RECEIVE link stops.
  property p_tx_snp_lcrd_quiescent_in_stop;
    @(posedge vif.clk) disable iff (!vif.rst_n)
      (tx_lasm() == VIP_CHI_LASM_STOP_E) |-> (txsnp_lcrd_count == 0);
  endproperty

  property p_rx_snp_lcrd_quiescent_in_stop;
    @(posedge vif.clk) disable iff (!vif.rst_n)
      (rx_lasm() == VIP_CHI_LASM_STOP_E) |-> (rxsnp_lcrd_count == 0);
  endproperty

  // FLITPEND announces a flit one cycle ahead; the obligation runs from the flit
  // backwards (IHI 0050 E §14.4 / D §13.4). See vip_chi_sva for why this is one
  // property and not the two bullets the section states.
  property p_snp_valid_requires_pend;
    @(posedge vif.clk) disable iff (!checks_enable || !vif.rst_n)
      vif.txsnpflitv |-> $past(vif.txsnpflitpend);
  endproperty

  property p_snp_known_when_valid;
    @(posedge vif.clk) disable iff (!checks_enable || !vif.rst_n)
      vif.txsnpflitv |-> !$isunknown(vif.txsnpflit);
  endproperty

  // Gated on link_ever_active, NOT on checks_enable, and for the same reason the
  // four reset-idle rules in vip_chi_sva are: checks_enable IS this interface's
  // activation request, and nothing is driven during reset, so the link is never
  // active while this rule applies. Under that gate it could not fire at all.
  //
  // The terms test `!== 1'b1` rather than `!signal` for the same reason too.
  // Each role drives one side of the SNP channel and not the other -- an HN-F
  // sources snoops and never drives txsnplcrdv, an RN-F grants SNP credits and
  // never drives the snoop flit signals -- so those nets sit at X, and `!x` is
  // x. The rule's content is that nothing is ASSERTED during reset.
  // IHI 0050 E 14.1.3 / D 13.1.3 lists exactly TX***LCRDV, TX***FLITV,
  // TXLINKACTIVEREQ and RXLINKACTIVEACK, then closes the set with "All other
  // signals can be any value." FLITPEND is not in it, and 14.4 / D 13.4 permits
  // a transmitter "to keep the signal permanently asserted" -- so a conformant
  // snoop transmitter may hold TXSNPFLITPEND high through reset. The REQ, RSP
  // and DAT twins in vip_chi_sva.sv carry the full reasoning.
  property p_snp_idle_during_reset;
    @(posedge vif.clk) disable iff (!link_ever_active)
      (!vif.rst_n && $past(!vif.rst_n, 1, 1'b1)) |->
        ((vif.txsnpflitv !== 1'b1) && (vif.txsnplcrdv !== 1'b1));
  endproperty

  assert property (p_snp_flit_requires_link)
    chk_hit(VIP_CHI_CHK_SNP_FLITV_REQUIRES_LINK_E);
  else
    chk_miss(VIP_CHI_CHK_SNP_FLITV_REQUIRES_LINK_E, $sformatf("txsnpflitv asserted before link RUN"));

  assert property (p_snp_lcrdv_requires_link)
    chk_hit(VIP_CHI_CHK_SNP_LCRDV_REQUIRES_LINK_E);
  else
    chk_miss(VIP_CHI_CHK_SNP_LCRDV_REQUIRES_LINK_E, $sformatf("txsnplcrdv asserted before link activation"));

  // One check id for both pools: it is one obligation -- no SNP credit may be
  // left stranded by a tear-down -- and a user standing it down wants both quiet.
  // The report names which direction, which is the distinction that matters.
  assert property (p_tx_snp_lcrd_quiescent_in_stop)
    chk_hit(VIP_CHI_CHK_SNP_LCRD_QUIESCENT_IN_STOP_E);
  else
    chk_miss(VIP_CHI_CHK_SNP_LCRD_QUIESCENT_IN_STOP_E, $sformatf(
      "SNP L-credits we may still SEND are outstanding with the TRANSMIT link in STOP (txsnp=%0d)",
      $sampled(txsnp_lcrd_count)));

  assert property (p_rx_snp_lcrd_quiescent_in_stop)
    chk_hit(VIP_CHI_CHK_SNP_LCRD_QUIESCENT_IN_STOP_E);
  else
    chk_miss(VIP_CHI_CHK_SNP_LCRD_QUIESCENT_IN_STOP_E, $sformatf(
      "SNP L-credits we have GRANTED are outstanding with the RECEIVE link in STOP (rxsnp=%0d)",
      $sampled(rxsnp_lcrd_count)));

  assert property (p_snp_valid_requires_pend)
    chk_hit(VIP_CHI_CHK_SNP_VALID_REQUIRES_PEND_E);
  else
    chk_miss(VIP_CHI_CHK_SNP_VALID_REQUIRES_PEND_E, $sformatf("txsnpflitv sent without txsnpflitpend in the preceding cycle"));

  assert property (p_snp_known_when_valid)
    chk_hit(VIP_CHI_CHK_SNP_KNOWN_WHEN_VALID_E);
  else
    chk_miss(VIP_CHI_CHK_SNP_KNOWN_WHEN_VALID_E, $sformatf("txsnpflit has X/Z while txsnpflitv asserted"));

  assert property (p_snp_idle_during_reset)
    chk_hit(VIP_CHI_CHK_SNP_IDLE_IN_RESET_E);
  else
    chk_miss(VIP_CHI_CHK_SNP_IDLE_IN_RESET_E, $sformatf("SNP outputs not idle during reset"));

  assert property (p_tx_snp_fwd_fields_zero)
    chk_hit(VIP_CHI_CHK_SNP_FWD_FIELDS_ZERO_E);
  else begin : b_snp_fwd_fields_zero_tx_miss
    snp_flit_view_t judged;
    judged = snp_view_of($sampled(vif.txsnpflit));
    chk_miss(VIP_CHI_CHK_SNP_FWD_FIELDS_ZERO_E, $sformatf(
      "sent snoop opcode 0x%0h is not a Forward type but carries FwdNID=0x%0h FwdTxnID=0x%0h",
      judged.opcode, judged.fwdnid, judged.fwdtxnid));
  end

  assert property (p_rx_snp_fwd_fields_zero)
    chk_hit(VIP_CHI_CHK_SNP_FWD_FIELDS_ZERO_E);
  else begin : b_snp_fwd_fields_zero_rx_miss
    snp_flit_view_t judged;
    judged = snp_view_of($sampled(vif.rxsnpflit));
    chk_miss(VIP_CHI_CHK_SNP_FWD_FIELDS_ZERO_E, $sformatf(
      "received snoop opcode 0x%0h is not a Forward type but carries FwdNID=0x%0h FwdTxnID=0x%0h",
      judged.opcode, judged.fwdnid, judged.fwdtxnid));
  end

  assert property (p_tx_snp_ret_to_src_legal)
    chk_hit(VIP_CHI_CHK_SNP_RET_TO_SRC_LEGAL_E);
  else begin : b_vip_chi_chk_snp_ret_to_src_legal_e_tx_1_miss
    snp_flit_view_t judged;
    judged = snp_view_of($sampled(vif.txsnpflit));
    chk_miss(VIP_CHI_CHK_SNP_RET_TO_SRC_LEGAL_E, $sformatf(
      "sent snoop opcode 0x%0h must carry RetToSrc = 0 (IHI 0050 E 4.9 / D 4.9)",
      judged.opcode));
  end

  assert property (p_rx_snp_ret_to_src_legal)
    chk_hit(VIP_CHI_CHK_SNP_RET_TO_SRC_LEGAL_E);
  else begin : b_vip_chi_chk_snp_ret_to_src_legal_e_rx_2_miss
    snp_flit_view_t judged;
    judged = snp_view_of($sampled(vif.rxsnpflit));
    chk_miss(VIP_CHI_CHK_SNP_RET_TO_SRC_LEGAL_E, $sformatf(
      "received snoop opcode 0x%0h must carry RetToSrc = 0 (IHI 0050 E 4.9 / D 4.9)",
      judged.opcode));
  end

  assert property (p_tx_snp_do_not_go_to_sd_legal)
    chk_hit(VIP_CHI_CHK_SNP_DO_NOT_GO_TO_SD_LEGAL_E);
  else begin : b_vip_chi_chk_snp_do_not_go_to_sd_legal_e_tx_3_miss
    snp_flit_view_t judged;
    judged = snp_view_of($sampled(vif.txsnpflit));
    chk_miss(VIP_CHI_CHK_SNP_DO_NOT_GO_TO_SD_LEGAL_E, $sformatf(
      "sent snoop opcode 0x%0h must carry DoNotGoToSD = 1 (IHI 0050 E 13.10.35)",
      judged.opcode));
  end

  assert property (p_rx_snp_do_not_go_to_sd_legal)
    chk_hit(VIP_CHI_CHK_SNP_DO_NOT_GO_TO_SD_LEGAL_E);
  else begin : b_vip_chi_chk_snp_do_not_go_to_sd_legal_e_rx_4_miss
    snp_flit_view_t judged;
    judged = snp_view_of($sampled(vif.rxsnpflit));
    chk_miss(VIP_CHI_CHK_SNP_DO_NOT_GO_TO_SD_LEGAL_E, $sformatf(
      "received snoop opcode 0x%0h must carry DoNotGoToSD = 1 (IHI 0050 E 13.10.35)",
      judged.opcode));
  end

endmodule

`endif
