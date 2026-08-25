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
// PGroupID reflected in the persist responses (F-INTOP-010).
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
// F-INTOP-010's first task was to add it to the item and to both exact-E flit
// layouts. Table 13-6 gives the REQ side as ONE 8-bit position shared four ways
// -- "{GroupIDExt[2:0], LPID[4:0]} / PGroupID[7:0] / StashGroupID[7:0] /
// TagGroupID[7:0]" -- and Table 13-7 gives the RSP side as "DBID[11:0] /
// {4'b0, PGroupID[7:0]} / {4'b0, StashGroupID[7:0]}". Section 13.10.8 then
// writes the request-side encoding as an equation: PGroupID[7:0] =
// {GroupIDExt[2:0], LPID[4:0]}. Adding a physical field would have made this
// VIP's flits wider than the specification's -- in BOTH ports, so no parity
// check could have seen it. It is modelled here as what it is: a view.
//
// The negative control. cfg.snf_persist_pgroup_corrupt_negctl makes the completer
// return the requested group plus one -- a wrong-but-plausible value rather than
// zero, deliberately: zero is also what a completer that never learned about the
// field would send, and the rule has to fail on both. Incrementing also keeps the
// response inside the 8-bit field, so nothing else objects first.
//
// The transaction still completes -- a wrong group identifier is invisible to
// every other check, which is exactly why this rule had to exist.
//
////////////////////////////////////////////////////////////////////////////////

class tc_chi_e_persist_pgroup_negctl extends chi_e_base_test;

  typedef vip_chi_item #(CHI_E_WIDE_CFG_C) item_t;

  `uvm_component_utils(tc_chi_e_persist_pgroup_negctl)

  vip_chi_persist_seq #(CHI_E_WIDE_CFG_C) persist_seq;

  localparam int SETTLE_C = 20;

  // The scoreboard reports unconditionally -- expect_failure() below declares
  // intent for the CSV export and nothing more -- so the error this control
  // provokes on purpose has to be demoted, or the regression script's
  // "UVM_ERROR : 0" gate reads a working negative control as a failure.
  localparam string SB_ERR_PATTERN_C =
    "*Persist-family response returned PGroupID*";

  chi_sb_rule_negctl_catcher sb_catcher;

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
    this.sb_catcher = new("sb_persist_pgroup_catcher");
    this.sb_catcher.add_expected(SB_ERR_PATTERN_C);
  endfunction

  // ---------------------------------------------------------------------------
  // Start of simulation
  // ---------------------------------------------------------------------------
  function void start_of_simulation_phase(input uvm_phase phase);

    super.start_of_simulation_phase(phase);

    this.persist_seq =
      vip_chi_persist_seq #(CHI_E_WIDE_CFG_C)::type_id::create("persist_seq");
  endfunction

  // ---------------------------------------------------------------------------
  // The control itself: the completer returns the wrong persistence group.
  // ---------------------------------------------------------------------------
  protected virtual function void configure_agent_cfgs();

    super.configure_agent_cfgs();
    this.snf_cfg.snf_persist_pgroup_corrupt_negctl = 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Run
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t rsp_q[$];
    int    before_fail;
    int    after_fail;

    phase.raise_objection(this);

    uvm_report_cb::add(null, this.sb_catcher);

    super.drain_observation_fifos();

    before_fail = super.tb_env.scoreboard.get_check_fail_count(
      VIP_CHI_SB_CHK_PERSIST_PGROUP_MATCHES_E);
    if (before_fail != 0) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] CHI_SB_PERSIST_PGROUP_MATCHES already reported %0d time(s) on bring-up traffic; the count below would prove nothing",
      get_name(), before_fail))
    end

    super.tb_env.scoreboard.expect_failure(VIP_CHI_SB_CHK_PERSIST_PGROUP_MATCHES_E);

    this.persist_seq.reset();
    // After reset(), which clears it.
    this.persist_seq.set_sep_persist(1'b1);
    this.persist_seq.set_requests(1);
    this.persist_seq.set_initial_addr(E_PERSIST_PGROUP_NEGCTL_ADDR_C);
    this.persist_seq.set_size(6);
    this.persist_seq.set_group_id_ext(GROUP_ID_EXT_C);
    this.persist_seq.set_lp_id(LP_ID_C);
    this.persist_seq.set_get_response(1'b1);
    this.persist_seq.set_verbose(1'b0);
    this.persist_seq.start(super.tb_env.rni_agent.sequencer);

    rsp_q = this.persist_seq.get_responses();
    if (rsp_q.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] the CleanSharedPersistSep returned %0d responses, expected 1",
      get_name(), rsp_q.size()))
    end

    super.wait_clocks(SETTLE_C);

    after_fail = super.tb_env.scoreboard.get_check_fail_count(
      VIP_CHI_SB_CHK_PERSIST_PGROUP_MATCHES_E);

    if (after_fail <= before_fail) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] CHI_SB_PERSIST_PGROUP_MATCHES did not report a Persist carrying the wrong PGroupID. Either the control is not reaching the completer, or the rule is comparing the response against itself rather than against what the request asked for",
      get_name()))
    end

    // The violation went through the report path, not only through the tally: a
    // rule that increments a counter but never reports is a rule no reader of
    // the log would ever see fire.
    uvm_report_cb::delete(null, this.sb_catcher);

    if (this.sb_catcher.caught(SB_ERR_PATTERN_C) == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the rule counted a violation but none reached the report path; a counted-but-silent violation is invisible in a log",
        get_name()))
    end

    `uvm_info(get_name(), $sformatf(
    "PASS [%s] a Persist returning a PGroupID other than the requested 0x%02h was reported %0d time(s) by CHI_SB_PERSIST_PGROUP_MATCHES",
    get_name(), PGROUP_ID_C, after_fail - before_fail), UVM_LOW)


    phase.drop_objection(this);
  endtask

endclass
