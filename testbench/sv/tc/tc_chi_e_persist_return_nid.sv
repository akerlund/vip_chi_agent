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
// Where a PCMO's Persist is addressed (F-CORR-012).
//
// IHI 0050 E section 2.8: "The ReturnNID value in the request must be used as
// the target in the following responses by the Slave: in the DBIDResp, if the
// DoDWT bit in the request is set to one; in the Persist, if the CMO in the
// request is a PCMO." CompCMO is NOT in that list and keeps SrcID -- the two
// responses to one combined request go to two different fields, which is the
// whole point.
//
// The regression could not have caught the completer getting this wrong, and the
// reason is worth stating: every other test leaves ReturnNID at zero or at the
// requester's own node, so SrcID and ReturnNID name the same node and a Persist
// sent to either lands in the same place. This test is the one that separates
// them -- ReturnNID is set to a node that is NOT the requester, so the two
// fields disagree and the routing becomes observable.
//
// What is asserted, at both ends of the claim:
//   * CHI_SB_RSP_TGTID_CORRECT records a pass and no failure, which is the rule
//     reading the TgtID off the wire;
//   * the transaction still completes, so the reroute is not achieved by
//     dropping the response.
//
////////////////////////////////////////////////////////////////////////////////

class tc_chi_e_persist_return_nid extends chi_e_base_test;

  typedef vip_chi_item #(CHI_E_WIDE_CFG_C) item_t;

  `uvm_component_utils(tc_chi_e_persist_return_nid)

  vip_chi_write_cmo_seq #(CHI_E_WIDE_CFG_C) write_cmo_seq;

  localparam int SIZE_C   = 6;
  localparam int SETTLE_C = 20;

  // A node that is deliberately NOT the requester and NOT the completer, so a
  // Persist addressed to SrcID and one addressed to ReturnNID are
  // distinguishable. It does not have to exist: the link is point to point, so
  // the flit arrives here whatever its TgtID says, and the TgtID is the thing
  // under test.
  localparam int unsigned RETURN_NID_C = 'h1A5;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // Create the sequence handle.
  // ---------------------------------------------------------------------------
  function void start_of_simulation_phase(input uvm_phase phase);

    super.start_of_simulation_phase(phase);

    this.write_cmo_seq =
      vip_chi_write_cmo_seq #(CHI_E_WIDE_CFG_C)::type_id::create("write_cmo_seq");
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

    this.write_cmo_seq.reset();
    this.write_cmo_seq.set_partial(1'b0);
    this.write_cmo_seq.set_cmo(VIP_CHI_CMO_CLEAN_SH_PER_SEP_E);
    this.write_cmo_seq.set_requests(1);
    this.write_cmo_seq.set_initial_addr(E_PERSIST_RETURN_NID_ADDR_C);
    this.write_cmo_seq.set_size(SIZE_C);
    // The whole point of the testcase. Without this the field defaults to the
    // requester's own node and the rule below cannot tell the two apart.
    this.write_cmo_seq.set_return_nid(RETURN_NID_C);
    this.write_cmo_seq.set_get_response(1'b1);
    this.write_cmo_seq.set_verbose(1'b0);
    this.write_cmo_seq.start(super.tb_env.rni_agent.sequencer);

    wr_rsp = this.write_cmo_seq.get_responses();
    if (wr_rsp.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] the combined Write + PCMO returned %0d responses, expected 1; a reroute that drops the transaction proves nothing",
      get_name(), wr_rsp.size()))
    end

    super.wait_clocks(SETTLE_C);

    after_pass = super.tb_env.scoreboard.get_check_pass_count(
      VIP_CHI_SB_CHK_RSP_TGTID_CORRECT_E);
    after_fail = super.tb_env.scoreboard.get_check_fail_count(
      VIP_CHI_SB_CHK_RSP_TGTID_CORRECT_E);

    if (after_fail != before_fail) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] CHI_SB_RSP_TGTID_CORRECT reported %0d time(s) against a Persist the completer should have addressed to ReturnNID 0x%0h: section 2.8 routes a PCMO's Persist there, not to the requester's SrcID",
      get_name(), after_fail - before_fail, RETURN_NID_C))
    end

    if (after_pass <= before_pass) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] CHI_SB_RSP_TGTID_CORRECT recorded no pass, so this testcase proves nothing. Either the Persist never reached the scoreboard or the rule is not reading it -- and a rule with no passes is indistinguishable from one that is absent",
      get_name()))
    end

    `uvm_info(get_name(), $sformatf(
    "PASS [%s] the Persist for a combined Write + PCMO was addressed to ReturnNID 0x%0h rather than to the requester, checked %0d time(s) by CHI_SB_RSP_TGTID_CORRECT",
    get_name(), RETURN_NID_C, after_pass - before_pass), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
