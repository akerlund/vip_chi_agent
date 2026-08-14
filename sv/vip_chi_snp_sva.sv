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
    chk_hit(VIP_CHI_CHK_SNP_FLITV_REQUIRES_LINK_E);
  else
    chk_miss(VIP_CHI_CHK_SNP_FLITV_REQUIRES_LINK_E, $sformatf("txsnpflitv asserted before link RUN"));

  assert property (p_snp_lcrdv_requires_link)
    chk_hit(VIP_CHI_CHK_SNP_LCRDV_REQUIRES_LINK_E);
  else
    chk_miss(VIP_CHI_CHK_SNP_LCRDV_REQUIRES_LINK_E, $sformatf("txsnplcrdv asserted before link activation"));

  assert property (p_snp_pend_requires_valid)
    chk_hit(VIP_CHI_CHK_SNP_PEND_REQUIRES_VALID_E);
  else
    chk_miss(VIP_CHI_CHK_SNP_PEND_REQUIRES_VALID_E, $sformatf("txsnpflitpend asserted without txsnpflitv"));

  assert property (p_snp_known_when_valid)
    chk_hit(VIP_CHI_CHK_SNP_KNOWN_WHEN_VALID_E);
  else
    chk_miss(VIP_CHI_CHK_SNP_KNOWN_WHEN_VALID_E, $sformatf("txsnpflit has X/Z while txsnpflitv asserted"));

  assert property (p_snp_idle_during_reset)
    chk_hit(VIP_CHI_CHK_SNP_IDLE_IN_RESET_E);
  else
    chk_miss(VIP_CHI_CHK_SNP_IDLE_IN_RESET_E, $sformatf("SNP outputs not idle during reset"));

endmodule

`endif
