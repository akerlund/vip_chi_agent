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
module vip_chi_snp_sva #(
  parameter vip_chi_cfg_t  CFG_P        = VIP_CHI_DEFAULT_CFG_C,
  parameter type           FLIT_TYPES_T = vip_chi_types #(CFG_P),
  parameter vip_chi_role_t ROLE_P       = VIP_CHI_ROLE_MONITOR_E
  )(
    vip_chi_if vif,
    input bit  checks_enable
  );

  localparam int unsigned SNP_SEND_CAP_C = 64;

  // This link's LASM as seen from this endpoint, matching vip_chi_sva -- one
  // state machine per link, formed from the live request/acknowledge pair
  // whichever polarity this bind sits on. See the long comment there.
  function automatic vip_chi_lasm_state_t link_lasm();
    return vip_chi_lasm((vif.txlinkactivereq || vif.rxlinkactivereq),
                        (vif.txlinkactiveack || vif.rxlinkactiveack));
  endfunction

  // Anywhere but STOP (ACTIVATE/RUN/DEACTIVATE). Credit returns are legal from
  // ACTIVATE onward.
  function automatic bit link_is_active();
    return (link_lasm() != VIP_CHI_LASM_STOP_E);
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

  always_ff @(posedge vif.clk or negedge vif.rst_n) begin
    if (!checks_enable || !vif.rst_n) begin
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

  function automatic void chk_miss(input vip_chi_check_id_t id, input string msg);
    if (!vif.check_enabled[id]) begin
      return;
    end
    vif.check_fail_count[id] = vif.check_fail_count[id] + 1;
    case (vif.check_severity[id])
      VIP_CHI_CHK_SEV_OFF_E: begin
      end
      VIP_CHI_CHK_SEV_WARNING_E: begin
        $warning("vip_chi_snp_sva: [%s] %s", vip_chi_check_name(id), msg);
      end
      default: begin
        $error("vip_chi_snp_sva: [%s] %s", vip_chi_check_name(id), msg);
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
      vif.txsnpflitv |-> snp_fwd_fields_legal(tx_snp_view());
  endproperty

  property p_rx_snp_fwd_fields_zero;
    @(posedge vif.clk) disable iff (!checks_enable || !vif.rst_n)
      vif.rxsnpflitv |-> snp_fwd_fields_legal(rx_snp_view());
  endproperty

  property p_tx_snp_ret_to_src_legal;
    @(posedge vif.clk) disable iff (!checks_enable || !vif.rst_n)
      vif.txsnpflitv |-> snp_ret_to_src_legal(tx_snp_view());
  endproperty

  property p_rx_snp_ret_to_src_legal;
    @(posedge vif.clk) disable iff (!checks_enable || !vif.rst_n)
      vif.rxsnpflitv |-> snp_ret_to_src_legal(rx_snp_view());
  endproperty

  property p_tx_snp_do_not_go_to_sd_legal;
    @(posedge vif.clk) disable iff (!checks_enable || !vif.rst_n)
      vif.txsnpflitv |-> snp_do_not_go_to_sd_legal(tx_snp_view());
  endproperty

  property p_rx_snp_do_not_go_to_sd_legal;
    @(posedge vif.clk) disable iff (!checks_enable || !vif.rst_n)
      vif.rxsnpflitv |-> snp_do_not_go_to_sd_legal(rx_snp_view());
  endproperty

  // Structural properties (tx side: the SNP source drives txsnp*/receives credit
  // returns; on an RN-F interface these are idle so the checks are vacuous).
  property p_snp_flit_requires_link;
    @(posedge vif.clk) disable iff (!checks_enable || !vif.rst_n)
      vif.txsnpflitv |-> (link_lasm() == VIP_CHI_LASM_RUN_E);
  endproperty

  property p_snp_lcrdv_requires_link;
    @(posedge vif.clk) disable iff (!checks_enable || !vif.rst_n)
      vif.txsnplcrdv |-> link_is_active();
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
  property p_snp_idle_during_reset;
    @(posedge vif.clk) disable iff (!link_ever_active)
      (!vif.rst_n && $past(!vif.rst_n, 1, 1'b1)) |->
        ((vif.txsnpflitv !== 1'b1) && (vif.txsnpflitpend !== 1'b1) &&
         (vif.txsnplcrdv !== 1'b1));
  endproperty

  assert property (p_snp_flit_requires_link)
    chk_hit(VIP_CHI_CHK_SNP_FLITV_REQUIRES_LINK_E);
  else
    chk_miss(VIP_CHI_CHK_SNP_FLITV_REQUIRES_LINK_E, $sformatf("txsnpflitv asserted before link RUN"));

  assert property (p_snp_lcrdv_requires_link)
    chk_hit(VIP_CHI_CHK_SNP_LCRDV_REQUIRES_LINK_E);
  else
    chk_miss(VIP_CHI_CHK_SNP_LCRDV_REQUIRES_LINK_E, $sformatf("txsnplcrdv asserted before link activation"));

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
  else
    chk_miss(VIP_CHI_CHK_SNP_FWD_FIELDS_ZERO_E, $sformatf(
      "sent snoop opcode 0x%0h is not a Forward type but carries FwdNID=0x%0h FwdTxnID=0x%0h",
      tx_snp_view().opcode, tx_snp_view().fwdnid, tx_snp_view().fwdtxnid));

  assert property (p_rx_snp_fwd_fields_zero)
    chk_hit(VIP_CHI_CHK_SNP_FWD_FIELDS_ZERO_E);
  else
    chk_miss(VIP_CHI_CHK_SNP_FWD_FIELDS_ZERO_E, $sformatf(
      "received snoop opcode 0x%0h is not a Forward type but carries FwdNID=0x%0h FwdTxnID=0x%0h",
      rx_snp_view().opcode, rx_snp_view().fwdnid, rx_snp_view().fwdtxnid));

  assert property (p_tx_snp_ret_to_src_legal)
    chk_hit(VIP_CHI_CHK_SNP_RET_TO_SRC_LEGAL_E);
  else
    chk_miss(VIP_CHI_CHK_SNP_RET_TO_SRC_LEGAL_E, $sformatf(
      "sent snoop opcode 0x%0h must carry RetToSrc = 0 (IHI 0050 E 4.9 / D 4.9)",
      tx_snp_view().opcode));

  assert property (p_rx_snp_ret_to_src_legal)
    chk_hit(VIP_CHI_CHK_SNP_RET_TO_SRC_LEGAL_E);
  else
    chk_miss(VIP_CHI_CHK_SNP_RET_TO_SRC_LEGAL_E, $sformatf(
      "received snoop opcode 0x%0h must carry RetToSrc = 0 (IHI 0050 E 4.9 / D 4.9)",
      rx_snp_view().opcode));

  assert property (p_tx_snp_do_not_go_to_sd_legal)
    chk_hit(VIP_CHI_CHK_SNP_DO_NOT_GO_TO_SD_LEGAL_E);
  else
    chk_miss(VIP_CHI_CHK_SNP_DO_NOT_GO_TO_SD_LEGAL_E, $sformatf(
      "sent snoop opcode 0x%0h must carry DoNotGoToSD = 1 (IHI 0050 E 13.10.35)",
      tx_snp_view().opcode));

  assert property (p_rx_snp_do_not_go_to_sd_legal)
    chk_hit(VIP_CHI_CHK_SNP_DO_NOT_GO_TO_SD_LEGAL_E);
  else
    chk_miss(VIP_CHI_CHK_SNP_DO_NOT_GO_TO_SD_LEGAL_E, $sformatf(
      "received snoop opcode 0x%0h must carry DoNotGoToSD = 1 (IHI 0050 E 13.10.35)",
      rx_snp_view().opcode));

endmodule

`endif
