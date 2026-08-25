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
// The NEGATIVE control for CHI_SB_TAG_MATCH_OWED (F-COV-001).
//
// cfg.snf_tag_match_unrequested_negctl makes the completer answer whether or not
// the data asked, and this testcase drives a write whose data carries
// TagOp = Transfer -- so the TagMatch that comes back is owed to nobody.
//
// An unrequested TagMatch is not harmless. A Requester that tracks Match
// completions by counting them goes permanently out of step, and nothing else in
// the checker would notice: the write completes normally, every field is legal,
// and the response is a legal opcode for the channel. That is the whole reason
// this needed a rule of its own.
//
// tc_chi_e_tag_match is the positive half: same traffic, TagOp = Match, rule
// silent.
//
////////////////////////////////////////////////////////////////////////////////

class tc_chi_e_tag_match_negctl extends chi_e_base_test;

  typedef vip_chi_item #(CHI_E_WIDE_CFG_C) item_t;

  `uvm_component_utils(tc_chi_e_tag_match_negctl)

  localparam int SETTLE_C = 20;

  // The scoreboard reports unconditionally -- expect_failure() declares intent
  // for the CSV export and nothing more -- so the error this control provokes on
  // purpose has to be demoted, or the regression script's "UVM_ERROR : 0" gate
  // reads a working negative control as a failure.
  localparam string SB_ERR_PATTERN_C = "*TagMatch returned for a write whose data carried no TagOp = Match*";

  chi_sb_rule_negctl_catcher sb_catcher;

  // Table 13-34: 0b11 is Match on a write.
  localparam int unsigned TAGOP_MATCH_C    = 2'b11;
  localparam int unsigned TAGOP_TRANSFER_C = 2'b01;
  localparam int unsigned TAG_C         = 'h1234;
  // 13.10.38: "TU field is not applicable and must be set to zero" under Match.
  localparam int unsigned TU_C          = 'h0;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);
    this.sb_catcher = new("sb_tag_match_catcher");
    this.sb_catcher.add_expected(SB_ERR_PATTERN_C);
  endfunction

  // ---------------------------------------------------------------------------
  // The control itself: the completer answers a write that asked for no check.
  // ---------------------------------------------------------------------------
  protected virtual function void configure_agent_cfgs();

    super.configure_agent_cfgs();
    this.snf_cfg.snf_tag_match_unrequested_negctl = 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Run
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t obs;
    bit    saw_tag_match;
    int    before_fail;
    int    after_fail;

    phase.raise_objection(this);

    uvm_report_cb::add(null, this.sb_catcher);
    super.tb_env.scoreboard.expect_failure(VIP_CHI_SB_CHK_TAG_MATCH_OWED_E);

    super.drain_observation_fifos();

    before_fail = super.tb_env.scoreboard.get_check_fail_count(
      VIP_CHI_SB_CHK_TAG_MATCH_OWED_E);

    super.rni_wr_seq.reset();
    super.rni_wr_seq.set_requests(1);
    super.rni_wr_seq.set_initial_addr(E_TAG_MATCH_NEGCTL_ADDR_C);
    super.rni_wr_seq.set_size(6);
    super.rni_wr_seq.set_src_id(E_MTE_RNI_NODE_ID_C);
    super.rni_wr_seq.set_tgt_id(E_MTE_SNF_NODE_ID_C);
    // Transfer, NOT Match: this write asks for no check, so the TagMatch the
    // control emits is owed to nobody.
    super.rni_wr_seq.set_dat_tagop(TAGOP_TRANSFER_C);
    // Pinned, because this write does not ask for a Match and so does not get
    // the requester-defaulted ReturnNID a Match-tagged one would. Without it the
    // completer's unrequested TagMatch is addressed to node 0 and never binds to
    // this transaction -- the control would provoke an orphan instead of the
    // rule it is aimed at. The obligation is what is under test, not the route.
    super.rni_wr_seq.set_return_nid(E_MTE_RNI_NODE_ID_C);
    super.rni_wr_seq.set_tag('{TAG_C});
    super.rni_wr_seq.set_tu('{TU_C});
    super.rni_wr_seq.set_get_response(1'b1);
    super.rni_wr_seq.set_verbose(1'b0);
    super.rni_wr_seq.start(super.tb_env.rni_agent.sequencer);

    super.wait_clocks(SETTLE_C);

    // The response really went out. Without this the testcase passes against a
    // completer that answered nothing, because the rule is silent then too --
    // it judges an arriving TagMatch, and no TagMatch is no judgement.
    saw_tag_match = 1'b0;
    while (super.tb_env.rni_rsp_fifo.try_get(obs)) begin
      if (obs.rsp_opcode == item_t::rsp_opcode_t'(VIP_CHI_RSP_TAG_MATCH_C)) begin
        saw_tag_match = 1'b1;
      end
    end
    if (!saw_tag_match) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] the control did not emit a TagMatch at all, so nothing was provoked",
      get_name()))
    end

    after_fail = super.tb_env.scoreboard.get_check_fail_count(
      VIP_CHI_SB_CHK_TAG_MATCH_OWED_E);

    if (after_fail <= before_fail) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] CHI_SB_TAG_MATCH_OWED did not report a TagMatch returned for a write whose data carried no TagOp = Match. Either the control is not reaching the completer, or the rule is keying on the response arriving rather than on whether it was owed",
      get_name()))
    end

    // The violation went through the report path, not only through the tally: a
    // rule that increments a counter but never reports is a rule no reader of
    // the log would ever see fire.
    uvm_report_cb::delete(null, this.sb_catcher);

    if (this.sb_catcher.caught(SB_ERR_PATTERN_C) == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the rule counted a violation but none reached the report path; a counted-but-silent violation is invisible in a log",
        super.tc_name))
    end

    `uvm_info(get_name(), $sformatf(
    "PASS [%s] an unrequested TagMatch was reported %0d time(s) by CHI_SB_TAG_MATCH_OWED",
    get_name(), after_fail - before_fail), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
