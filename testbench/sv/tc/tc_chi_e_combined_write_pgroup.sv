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
// PGroupID reflected in the persist responses.
//
// IHI 0050 E section 2.5: "A CleanSharedPersistSep and Combined Write with PCMO
// request includes a PGroupID to identify the Persistence Group that the request
// belongs to [...] The PGroupID value returned in the Persist response can be
// used by a Requester to separately track completions of Persist responses from
// each group."
//
// So a completer that returns the wrong group does not break the transaction. It
// breaks the requester's ability to tell two groups apart -- a defect no
// completion-shape check can see, which is why this needed a rule of its own
// (CHI_SB_PERSIST_PGROUP_MATCHES) rather than an extra clause on an existing one.
//
// **PGroupID is not a field, and the finding was wrong to ask for one.**
// The first step was to add it to the item and to both exact-E flit
// layouts. Table 13-6 gives the REQ side as ONE 8-bit position shared four ways
// -- "{GroupIDExt[2:0], LPID[4:0]} / PGroupID[7:0] / StashGroupID[7:0] /
// TagGroupID[7:0]" -- and Table 13-7 gives the RSP side as "DBID[11:0] /
// {4'b0, PGroupID[7:0]} / {4'b0, StashGroupID[7:0]}". Section 13.10.8 then
// writes the request-side encoding as an equation: PGroupID[7:0] =
// {GroupIDExt[2:0], LPID[4:0]}. Adding a physical field would have made this
// VIP's flits wider than the specification's -- in BOTH ports, so no parity
// check could have seen it. It is modelled here as what it is: a view.
//
// This half drives a combined Write + PCMO with a non-zero group, in both halves
// of the encoding: GroupIDExt carries the high three bits and LPID the low five,
// so a completer that reflected only one of them fails.
//
// The combined Write is here because 13.10.7's field summary OMITS it -- it names
// only "the CleanSharedPersistSep request" -- while section 2.5 names it twice,
// once as an obligation: "PGroupID must be sent in the CleanSharedPersistSep
// request and a Combined Write request that includes a PCMO." The classifier
// follows 2.5, and this testcase is what makes that reading load-bearing rather
// than a comment.
//
////////////////////////////////////////////////////////////////////////////////

class tc_chi_e_combined_write_pgroup extends chi_e_base_test;

  typedef vip_chi_item #(CHI_E_WIDE_CFG_C) item_t;

  `uvm_component_utils(tc_chi_e_combined_write_pgroup)

  vip_chi_write_cmo_seq #(CHI_E_WIDE_CFG_C) write_cmo_seq;

  localparam int SETTLE_C = 20;

  // Both halves of 13.10.8's equation are non-zero and different, so a completer
  // that reflected GroupIDExt alone, or LPID alone, or swapped them, fails.
  localparam int unsigned GROUP_ID_EXT_C = 3'b101;
  localparam int unsigned LP_ID_C        = 5'b01011;
  localparam int unsigned PGROUP_ID_C    = (GROUP_ID_EXT_C << 5) | LP_ID_C;

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

    this.write_cmo_seq =
      vip_chi_write_cmo_seq #(CHI_E_WIDE_CFG_C)::type_id::create("write_cmo_seq");
  endfunction

  // ---------------------------------------------------------------------------
  // Run
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t rsp_q[$];
    int    before_pass;
    int    before_fail;
    int    after_pass;
    int    after_fail;

    phase.raise_objection(this);

    super.drain_observation_fifos();

    before_pass = super.tb_env.scoreboard.get_check_pass_count(
      VIP_CHI_SB_CHK_PERSIST_PGROUP_MATCHES_E);
    before_fail = super.tb_env.scoreboard.get_check_fail_count(
      VIP_CHI_SB_CHK_PERSIST_PGROUP_MATCHES_E);

    this.write_cmo_seq.set_partial(1'b0);
    this.write_cmo_seq.set_cmo(VIP_CHI_CMO_CLEAN_SH_PER_SEP_E);
    this.write_cmo_seq.reset();
    this.write_cmo_seq.set_requests(1);
    this.write_cmo_seq.set_initial_addr(E_COMBINED_WRITE_PGROUP_ADDR_C);
    this.write_cmo_seq.set_size(6);
    this.write_cmo_seq.set_group_id_ext(GROUP_ID_EXT_C);
    this.write_cmo_seq.set_lp_id(LP_ID_C);
    this.write_cmo_seq.set_get_response(1'b1);
    this.write_cmo_seq.set_verbose(1'b0);
    this.write_cmo_seq.start(super.tb_env.rni_agent.sequencer);

    rsp_q = this.write_cmo_seq.get_responses();
    if (rsp_q.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] the combined Write + PCMO returned %0d responses, expected 1",
      get_name(), rsp_q.size()))
    end

    super.wait_clocks(SETTLE_C);

    after_pass = super.tb_env.scoreboard.get_check_pass_count(
      VIP_CHI_SB_CHK_PERSIST_PGROUP_MATCHES_E);
    after_fail = super.tb_env.scoreboard.get_check_fail_count(
      VIP_CHI_SB_CHK_PERSIST_PGROUP_MATCHES_E);

    if (after_fail != before_fail) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] CHI_SB_PERSIST_PGROUP_MATCHES reported %0d time(s) against a Persist that should have carried back PGroupID 0x%02h",
      get_name(), after_fail - before_fail, PGROUP_ID_C))
    end

    if (after_pass <= before_pass) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] CHI_SB_PERSIST_PGROUP_MATCHES recorded no pass, so this testcase proves nothing. Either the Persist never reached the scoreboard or the rule is not reading it",
      get_name()))
    end

    `uvm_info(get_name(), $sformatf(
    "PASS [%s] a combined Write + PCMO's Persist carried back PGroupID 0x%02h, checked %0d time(s) by CHI_SB_PERSIST_PGROUP_MATCHES",
    get_name(), PGROUP_ID_C, after_pass - before_pass), UVM_LOW)


    phase.drop_objection(this);
  endtask

endclass
