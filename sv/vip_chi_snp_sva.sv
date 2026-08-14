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
        $error("vip_chi_snp_sva: %s SNP L-credit grant overflowed the tracked count", chan);
      end
      else begin
        nxt = nxt + 1;
      end
    end
    if (consume) begin
      if (nxt == 0) begin
        $error("vip_chi_snp_sva: %s SNP L-credit consumed with no credit available (underflow)", chan);
      end
      else begin
        nxt = nxt - 1;
      end
    end
    return nxt;
  endfunction

  int unsigned txsnp_lcrd_count;
  int unsigned rxsnp_lcrd_count;

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

  property p_snp_pend_requires_valid;
    @(posedge vif.clk) disable iff (!checks_enable || !vif.rst_n)
      vif.txsnpflitpend |-> vif.txsnpflitv;
  endproperty

  property p_snp_known_when_valid;
    @(posedge vif.clk) disable iff (!checks_enable || !vif.rst_n)
      vif.txsnpflitv |-> !$isunknown(vif.txsnpflit);
  endproperty

  property p_snp_idle_during_reset;
    @(posedge vif.clk) disable iff (!checks_enable)
      (!vif.rst_n && $past(!vif.rst_n, 1, 1'b1)) |->
        (!vif.txsnpflitv && !vif.txsnpflitpend && !vif.txsnplcrdv);
  endproperty

  assert property (p_snp_flit_requires_link)
    else $error("vip_chi_snp_sva: txsnpflitv asserted before link RUN");

  assert property (p_snp_lcrdv_requires_link)
    else $error("vip_chi_snp_sva: txsnplcrdv asserted before link activation");

  assert property (p_snp_pend_requires_valid)
    else $error("vip_chi_snp_sva: txsnpflitpend asserted without txsnpflitv");

  assert property (p_snp_known_when_valid)
    else $error("vip_chi_snp_sva: txsnpflit has X/Z while txsnpflitv asserted");

  assert property (p_snp_idle_during_reset)
    else $error("vip_chi_snp_sva: SNP outputs not idle during reset");

endmodule

`endif
