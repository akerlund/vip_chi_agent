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
//
// Where a Direct Write Transfer's DBIDResp is addressed.
//
// This is the OTHER limb of the rule tc_chi_e_persist_return_nid covers. IHI
// 0050 E Table 2-8 gives both in three rows:
//
//     DoDWT  CMO type                    DBIDResp          Persist
//       1    All                         HN.Req.ReturnNID  HN.Req.ReturnNID
//       0    CleanShared / CleanInvalid  HN.Req.SrcID      -
//       0    Persistent                  HN.Req.SrcID      HN.Req.ReturnNID
//
// and section 2.5 sends the TxnID with the target: "when DoDWT = 1, ReturnTxnID
// value is expected to be the original Requester TxnID [...] Used as the TxnID
// in the DBIDResp response". A DBIDResp under DWT is the one response in this
// VIP that changes BOTH addressing fields on a single request bit.
//
// The limb was unreachable rather than merely unchecked. DoDWT is REQ bit 17,
// shared with SnpAttr, and until then was fixed the item modelled that
// bit as DoDWT alone and every sequence pinned it to zero -- so no request could
// ask for DWT, and the routing rule had nothing to be wrong about. Fixing the
// field identity is what made this testable, which is the whole argument for
// fixing the field identity before the routing.
//
// Both fields are moved off the requester, and deliberately not to the same
// value: ReturnNID and ReturnTxnID are separate obligations, and a completer
// that got one right and the other wrong would pass a test that only separated
// one of them.
//
// What is asserted, at both ends of the claim:
//   * CHI_SB_RSP_TGTID_CORRECT records a pass and no failure, which is the rule
//     reading the grant's TgtID/TxnID off the wire;
//   * the write still completes, so the reroute is not achieved by dropping the
//     response -- the requester had to find its grant at the new address to
//     send its data at all.
//
////////////////////////////////////////////////////////////////////////////////

class tc_chi_e_dwt_dbid_return_nid extends chi_e_base_test;

  typedef vip_chi_item #(CHI_E_WIDE_CFG_C) item_t;

  `uvm_component_utils(tc_chi_e_dwt_dbid_return_nid)

  vip_chi_write_seq #(CHI_E_WIDE_CFG_C) write_seq;

  localparam int SIZE_C   = 6;
  localparam int SETTLE_C = 20;

  // A node that is deliberately NOT the requester and NOT the completer, so a
  // grant addressed to SrcID and one addressed to ReturnNID are
  // distinguishable. It does not have to exist: the link is point to point, so
  // the flit arrives here whatever its TgtID says, and the TgtID is the thing
  // under test.
  localparam int unsigned RETURN_NID_C = 'h1A5;

  // Likewise off the requester's own TxnID. Picked high so it cannot collide
  // with an allocated TxnID and be right by accident.
  localparam int unsigned RETURN_TXN_ID_C = 'h5C;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  // Start of simulation
  // ---------------------------------------------------------------------------
  function void start_of_simulation_phase(input uvm_phase phase);

    super.start_of_simulation_phase(phase);

    this.write_seq =
      vip_chi_write_seq #(CHI_E_WIDE_CFG_C)::type_id::create("write_seq");
  endfunction

  // ---------------------------------------------------------------------------
  // Run
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t wr_rsp[$];
    int    before_pass;
    int    before_fail;
    int    after_pass;
    int    after_fail;

    phase.raise_objection(this);

    super.drain_observation_fifos();

    before_pass = super.tb_env.scoreboard.get_check_pass_count(
      VIP_CHI_SB_CHK_RSP_TGTID_CORRECT_E);
    before_fail = super.tb_env.scoreboard.get_check_fail_count(
      VIP_CHI_SB_CHK_RSP_TGTID_CORRECT_E);

    this.write_seq.reset();
    this.write_seq.set_requests(1);
    this.write_seq.set_initial_addr(E_DWT_RETURN_NID_ADDR_C);
    this.write_seq.set_size(SIZE_C);
    // The three settings that make the routing observable. Without the first
    // there is no DWT; without the other two the return path names the
    // requester and a grant sent either way lands in the same place.
    this.write_seq.set_dodwt(1'b1);
    this.write_seq.set_return_nid(RETURN_NID_C);
    this.write_seq.set_return_txn_id(RETURN_TXN_ID_C);
    this.write_seq.set_get_response(1'b1);
    this.write_seq.set_verbose(1'b0);
    this.write_seq.start(super.tb_env.rni_agent.sequencer);

    wr_rsp = this.write_seq.get_responses();
    if (wr_rsp.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] the DWT write returned %0d responses, expected 1; a reroute that drops the transaction proves nothing",
      get_name(), wr_rsp.size()))
    end

    super.wait_clocks(SETTLE_C);

    after_pass = super.tb_env.scoreboard.get_check_pass_count(
      VIP_CHI_SB_CHK_RSP_TGTID_CORRECT_E);
    after_fail = super.tb_env.scoreboard.get_check_fail_count(
      VIP_CHI_SB_CHK_RSP_TGTID_CORRECT_E);

    if (after_fail != before_fail) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] CHI_SB_RSP_TGTID_CORRECT reported %0d time(s) against a DBIDResp the completer should have addressed to ReturnNID 0x%0h under ReturnTxnID 0x%0h: Table 2-8 routes a DWT grant there, not to the requester's SrcID/TxnID",
      get_name(), after_fail - before_fail, RETURN_NID_C, RETURN_TXN_ID_C))
    end

    if (after_pass <= before_pass) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] CHI_SB_RSP_TGTID_CORRECT recorded no pass, so this testcase proves nothing. Either the grant never reached the scoreboard or the rule is not reading it -- and a rule with no passes is indistinguishable from one that is absent",
      get_name()))
    end

    `uvm_info(get_name(), $sformatf(
    "PASS [%s] the DBIDResp for a DoDWT write was addressed to ReturnNID 0x%0h under ReturnTxnID 0x%0h, checked %0d time(s) by CHI_SB_RSP_TGTID_CORRECT",
    get_name(), RETURN_NID_C, RETURN_TXN_ID_C, after_pass - before_pass), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
