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
// The negative control for the DWT limb of CHI_SB_RSP_TGTID_CORRECT (F-CORR-012).
//
// cfg.snf_dwt_dbid_target_srcid_negctl makes the completer address the write's
// DBIDResp at the request's SrcID under the request's own TxnID, when DoDWT = 1
// puts it at ReturnNID under ReturnTxnID (Table 2-8, and section 2.5 for the
// TxnID). That is what both ports did before this finding was fixed, so the
// control reproduces a real defect rather than an invented one.
//
// tc_chi_e_dwt_dbid_return_nid is the positive half: same traffic, same
// distinct return path, completer behaving, rule silent.
//
// The requester also refuses the misrouted grant, because it is waiting on
// ReturnTxnID and the flit carries the request's own. In this port that refusal
// is a `uvm_fatal, and chi_route_negctl_catcher demotes it and records that it
// happened -- so the refusal is not worked around here, it is the second half
// of the verdict.
//
// What is asserted, at both ends of the claim:
//   * CHI_SB_RSP_TGTID_CORRECT reports at least once, which is the rule reading
//     the grant's address off the wire and finding it wrong;
//   * the requester refused the misrouted grant, which is the other observer of
//     the same defect and proves the control reached the completer at all.
//
////////////////////////////////////////////////////////////////////////////////

class tc_chi_e_dwt_dbid_return_nid_negctl extends chi_e_base_test;

  typedef vip_chi_item #(CHI_E_WIDE_CFG_C) item_t;

  `uvm_component_utils(tc_chi_e_dwt_dbid_return_nid_negctl)

  vip_chi_write_seq #(CHI_E_WIDE_CFG_C) write_seq;
  chi_route_negctl_catcher              route_catcher;

  // The rule this control exists to provoke raises a scoreboard uvm_error, and
  // the scoreboard reports unconditionally -- expect_failure() declares intent
  // for the CSV export and nothing more. Without demoting it here the control
  // works perfectly and still fails, because sv_regression.sh gates on
  // "UVM_ERROR :    0". The count is still asserted below; only the report is demoted.
  localparam string SB_ERR_PATTERN_C = "*DoDWT was set, so Table 2-8 routes it to ReturnNID*";

  chi_sb_rule_negctl_catcher              sb_catcher;

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
      vip_chi_write_seq #(CHI_E_WIDE_CFG_C)::type_id::create("write_seq_negctl");
    this.route_catcher = new("dwt_route_catcher");
    this.sb_catcher = new("dwt_sb_catcher");
    this.sb_catcher.add_expected(SB_ERR_PATTERN_C);
  endfunction

  // ---------------------------------------------------------------------------
  // The control itself: the completer keeps the grant at SrcID/TxnID.
  // ---------------------------------------------------------------------------
  protected virtual function void configure_agent_cfgs();

    super.configure_agent_cfgs();
    this.snf_cfg.snf_dwt_dbid_target_srcid_negctl = 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Run
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    int    before_fail;
    int    after_fail;

    phase.raise_objection(this);

    super.drain_observation_fifos();

    before_fail = super.tb_env.scoreboard.get_check_fail_count(
      VIP_CHI_SB_CHK_RSP_TGTID_CORRECT_E);
    if (before_fail != 0) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] CHI_SB_RSP_TGTID_CORRECT already reported %0d time(s) on bring-up traffic; the count below would prove nothing",
      get_name(), before_fail))
    end

    // Demote the requester's refusal of the misrouted grant, and record it.
    uvm_report_cb::add(null, this.route_catcher);
    uvm_report_cb::add(null, this.sb_catcher);

    // And say WHICH rule is being provoked, so the cross-run aggregation records
    // the failure as asked-for rather than reporting the run that proves the
    // check fires as the check failing.
    super.tb_env.scoreboard.expect_failure(VIP_CHI_SB_CHK_RSP_TGTID_CORRECT_E);

    this.write_seq.reset();
    this.write_seq.set_requests(1);
    this.write_seq.set_initial_addr(E_DWT_RETURN_NID_NEGCTL_ADDR_C);
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

    super.wait_clocks(SETTLE_C);

    uvm_report_cb::delete(null, this.route_catcher);

    uvm_report_cb::delete(null, this.sb_catcher);

    after_fail = super.tb_env.scoreboard.get_check_fail_count(
      VIP_CHI_SB_CHK_RSP_TGTID_CORRECT_E);

    if (after_fail <= before_fail) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] CHI_SB_RSP_TGTID_CORRECT did not report a DWT grant addressed to SrcID/TxnID when Table 2-8 requires ReturnNID/ReturnTxnID. Either the control is not reaching the completer, or the rule has gone back to pairing the grant by the very fields it is supposed to judge -- which would make it unable to fail",
      get_name()))
    end

    if (!this.route_catcher.saw_grant_txn_refusal) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] the requester accepted a grant addressed to its own TxnID under DoDWT. The scoreboard rule and the requester are two independent observers of this defect and both are expected to object; one of them staying quiet means the grant never carried the wrong address at all",
      get_name()))
    end

    `uvm_info(get_name(), $sformatf(
    "PASS [%s] a DWT grant misrouted to SrcID/TxnID was reported %0d time(s) by CHI_SB_RSP_TGTID_CORRECT, and the requester refused it",
    get_name(), after_fail - before_fail), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
