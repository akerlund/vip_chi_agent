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
// The NEGATIVE control for CHI_SB_TAG_MATCH_RESULT, which no stimulus alone can
// make fail.
//
// The rule judges the RESULT a TagMatch carried against the tags the scoreboard
// holds. A completer that performs the comparison correctly agrees with that
// shadow on every write, so the rule's failing branch is unreachable from the
// sequence side however the tags are arranged -- the completer and the
// scoreboard are reading the same tags and reaching the same answer by
// construction.
//
// So the control breaks the completer instead. cfg.snf_tag_match_invert_result_negctl
// has it report the OPPOSITE of what its own comparison found, which is exactly
// the defect the rule exists to catch: the responder used to fill the field from
// the cache-state enum with VIP_CHI_RESP_STATE_I_E, whose three bits are also
// Table 13-25's Fail, so every Match was answered Fail whatever the tags said.
// That reported a wrong result on every write while satisfying
// CHI_SB_TAG_MATCH_OWED on every write, because a response DID arrive each time.
//
// Which is why the two rules are separate, and why this asserts on both: the
// control must make the RESULT rule report and must leave the OWED rule clean.
// A control that tripped both would not show they are distinguishable, and a
// single merged rule would have gone on passing through the original defect.
//
// What is asserted:
//   * an Update write first, so there IS a stored Allocation Tag and the
//     following Match has a real answer to invert -- against untagged memory the
//     honest answer is Fail already, and inverting it would produce a Pass that
//     looks like the bug rather than the control;
//   * the TagMatch that comes back carries Fail (Resp[0] = 0) where the tags
//     matched, so the control provably reached the wire;
//   * CHI_SB_TAG_MATCH_RESULT reports exactly once;
//   * CHI_SB_TAG_MATCH_OWED reports not at all.
//
////////////////////////////////////////////////////////////////////////////////

class tc_chi_e_tag_match_result_negctl extends chi_e_base_test;

  typedef vip_chi_item #(CHI_E_WIDE_CFG_C) item_t;

  `uvm_component_utils(tc_chi_e_tag_match_result_negctl)

  localparam int SETTLE_C = 20;

  // The scoreboard reports unconditionally -- expect_failure() declares intent
  // for the CSV export and nothing more -- so the error this control provokes on
  // purpose has to be demoted, or the regression script's "UVM_ERROR : 0" gate
  // reads a working negative control as a failure.
  localparam string SB_ERR_PATTERN_C = "*TagMatch reported*for a write whose tags*";

  chi_sb_rule_negctl_catcher sb_catcher;

  // Table 13-34: 0b11 is Match on a write, 0b10 is Update.
  localparam int unsigned TAGOP_MATCH_C  = 2'b11;
  localparam int unsigned TAGOP_UPDATE_C = 2'b10;
  localparam int unsigned TAG_C          = 'h1234;
  // 13.10.38: "TU field is not applicable and must be set to zero" under Match.
  localparam int unsigned TU_C           = 'h0;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);
    this.sb_catcher = new("sb_tag_match_result_catcher");
    this.sb_catcher.add_expected(SB_ERR_PATTERN_C);
  endfunction

  // ---------------------------------------------------------------------------
  // The control itself: the completer reports the opposite of what it found.
  // ---------------------------------------------------------------------------
  protected virtual function void configure_agent_cfgs();

    super.configure_agent_cfgs();
    this.snf_cfg.snf_tag_match_invert_result_negctl = 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // One tagged write to the shared address, and the TagMatch results it drew.
  // ---------------------------------------------------------------------------
  task tagged_write(
    input  int unsigned tagop,
    input  int unsigned tag,
    input  int unsigned tu,
    output bit          results []
  );
    item_t obs;
    bit    drawn [$];

    super.rni_wr_seq.reset();
    super.rni_wr_seq.set_requests(1);
    super.rni_wr_seq.set_initial_addr(E_TAG_MATCH_RESULT_ADDR_C);
    super.rni_wr_seq.set_size(6);
    super.rni_wr_seq.set_src_id(E_MTE_RNI_NODE_ID_C);
    super.rni_wr_seq.set_tgt_id(E_MTE_SNF_NODE_ID_C);
    super.rni_wr_seq.set_dat_tagop(tagop);
    super.rni_wr_seq.set_tag('{tag});
    super.rni_wr_seq.set_tu('{tu});
    super.rni_wr_seq.set_get_response(1'b1);
    super.rni_wr_seq.set_verbose(1'b0);
    super.rni_wr_seq.start(super.tb_env.rni_agent.sequencer);

    super.wait_clocks(SETTLE_C);

    while (super.tb_env.rni_rsp_fifo.try_get(obs)) begin
      if (obs.rsp_opcode == item_t::rsp_opcode_t'(VIP_CHI_RSP_TAG_MATCH_C)) begin
        // Table 13-25: the result is Resp[0] and nothing else in the field.
        drawn.push_back(obs.rsp_resp[0]);
      end
    end

    results = new [drawn.size()];
    foreach (drawn[i]) begin
      results[i] = drawn[i];
    end
  endtask

  // ---------------------------------------------------------------------------
  // Run
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    bit drawn [];
    int before_fail;
    int before_owed_fail;
    int after_fail;
    int after_owed_fail;

    phase.raise_objection(this);

    uvm_report_cb::add(null, this.sb_catcher);
    super.tb_env.scoreboard.expect_failure(VIP_CHI_SB_CHK_TAG_MATCH_RESULT_E);

    super.drain_observation_fifos();

    before_fail = super.tb_env.scoreboard.get_check_fail_count(
      VIP_CHI_SB_CHK_TAG_MATCH_RESULT_E);
    before_owed_fail = super.tb_env.scoreboard.get_check_fail_count(
      VIP_CHI_SB_CHK_TAG_MATCH_OWED_E);

    if (before_fail != 0) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] CHI_SB_TAG_MATCH_RESULT already reported %0d time(s) on bring-up traffic; the count below would prove nothing",
      get_name(), before_fail))
    end

    // Establish the Allocation Tag. Update stores and asks no question, so it
    // draws no TagMatch and the control has nothing to invert yet.
    this.tagged_write(TAGOP_UPDATE_C, TAG_C, E_MTE_WRITE_TU_C, drawn);
    if (drawn.size() != 0) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] an Update-tagged write drew %0d TagMatch response(s) even before the Match; the control is answering writes that asked nothing",
      get_name(), drawn.size()))
    end

    // The same tag: the comparison finds a match, and the control reports Fail.
    this.tagged_write(TAGOP_MATCH_C, TAG_C, TU_C, drawn);
    if (drawn.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] a Match-tagged write drew %0d TagMatch response(s), expected exactly 1",
      get_name(), drawn.size()))
    end
    if (drawn[0] != 1'b0) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] a Match-tagged write carrying the stored tag was answered Pass, expected Fail from the inverting control -- either the control is not reaching the completer, or the completer is not comparing at all and the inversion turned its constant Fail into a Pass",
      get_name()))
    end

    after_fail = super.tb_env.scoreboard.get_check_fail_count(
      VIP_CHI_SB_CHK_TAG_MATCH_RESULT_E);
    after_owed_fail = super.tb_env.scoreboard.get_check_fail_count(
      VIP_CHI_SB_CHK_TAG_MATCH_OWED_E);

    if ((after_fail - before_fail) != 1) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] CHI_SB_TAG_MATCH_RESULT reported %0d time(s) for one inverted result, expected exactly 1",
      get_name(), after_fail - before_fail))
    end
    if (after_owed_fail != before_owed_fail) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] CHI_SB_TAG_MATCH_OWED reported %0d time(s) on a response that WAS owed; the two rules are not separable if breaking the result also trips the obligation",
      get_name(), after_owed_fail - before_owed_fail))
    end

    `uvm_info(get_name(), $sformatf(
    "PASS [%s] an inverted Tag Match result was reported %0d time(s) by CHI_SB_TAG_MATCH_RESULT, with CHI_SB_TAG_MATCH_OWED clean",
    get_name(), after_fail - before_fail), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
