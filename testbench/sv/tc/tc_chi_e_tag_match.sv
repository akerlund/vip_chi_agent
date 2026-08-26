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
// The completer answers a Match-tagged write with TagMatch.
//
// IHI 0050 E Table 13-34 gives TagOp = 0b11 as "Match Fetch" -- Match on a write:
// "the Physical Tags in the write must be checked against the Allocation Tag
// values obtained from memory". Section 2.3.1 then makes the answer an
// obligation: "If the WriteData message indicates that a Tag Match is required,
// then the Slave sends a TagMatch response after completing the required Tag
// Match operation."
//
// The VIP defined no TagMatch RSP opcode at all, while shipping memory tagging
// as a claimed and tested feature. It was reachable rather than merely absent:
// TagOp is a bare 2-bit field with no enum and no constraint, so any test could
// ask for Match and get silence back -- and against a third-party completer that
// answered correctly, the monitor would have reconstructed an opcode neither
// port knew.
//
// Modelling it needed no new flit field. Table 13-7 shares the response's DBID
// bits between DBID, PGroupID and StashGroupID, and 13.10.7 adds TagGroupID to
// that list -- the same overload PGroupID rides in.
//
// The response is routed to ReturnNID, not SrcID: the TgtID table in section 4.7
// gives TagMatch as "Request.SrcID" from a Home and "Request.ReturnNID" from a
// Slave, and section 2.5 agrees from the field's side.
//
// The RESULT is the second half, and the completer used to get it wrong in a way
// nothing could see. Table 13-25 puts the answer in Resp[0] alone -- 0b000 Fail,
// 0b001 Pass -- which is not a cache state, and the responder was filling the
// field from the cache-state enum with VIP_CHI_RESP_STATE_I_E. Those are the
// same three bits as Fail, so every Match was answered Fail, no comparison was
// ever performed, and a rule that only judged the response's PRESENCE passed on
// all of it.
//
// What is asserted, in four phases against one address:
//   * an Update write establishes the Allocation Tag and is owed no TagMatch;
//   * a Match write carrying the same tag is answered Pass;
//   * a Match write carrying a different tag is answered Fail -- so the result is
//     a function of the tags and not a constant, which one phase cannot show;
//   * a Match write carrying the original tag again is answered Pass, which is
//     what proves the failing Match in between did not WRITE its tag. Table
//     13-34 gives Update as the encoding that stores tags and Match as the one
//     that checks them, and a completer that committed on Match would have made
//     this phase report Fail.
//   * CHI_SB_TAG_MATCH_OWED and CHI_SB_TAG_MATCH_RESULT each record three passes
//     and no failure, and a TagMatch RSP is observed on the wire every time -- so
//     the test cannot pass against a completer that stayed silent, because the
//     rules are silent then too.
//
////////////////////////////////////////////////////////////////////////////////

class tc_chi_e_tag_match extends chi_e_base_test;

  typedef vip_chi_item #(CHI_E_WIDE_CFG_C) item_t;

  `uvm_component_utils(tc_chi_e_tag_match)

  localparam int SETTLE_C = 20;

  // Table 13-34: 0b11 is Match on a write, 0b10 is Update.
  localparam int unsigned TAGOP_MATCH_C  = 2'b11;
  localparam int unsigned TAGOP_UPDATE_C = 2'b10;
  localparam int unsigned TAG_C          = 'h1234;
  // One bit away, so the Fail phase differs from the Pass phase in the tag and
  // in nothing else.
  localparam int unsigned OTHER_TAG_C    = TAG_C ^ 'h1;
  // 13.10.38: "TU field is not applicable and must be set to zero" under Match.
  localparam int unsigned TU_C           = 'h0;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  // One tagged write to the shared address, and the TagMatch results it drew.
  //
  // The queue is returned rather than a single value so a phase that draws none
  // -- the Update phase, which is owed none -- is distinguishable from one that
  // drew a Fail.
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
    super.rni_wr_seq.set_initial_addr(E_TAG_MATCH_ADDR_C);
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

    bit          drawn [];
    int unsigned phase_tag [3];
    bit          phase_want [3];
    int          before_pass;
    int          before_fail;
    int          before_result_pass;
    int          before_result_fail;
    int          after_pass;
    int          after_fail;
    int          after_result_pass;
    int          after_result_fail;

    phase.raise_objection(this);

    super.drain_observation_fifos();

    before_pass = super.tb_env.scoreboard.get_check_pass_count(
      VIP_CHI_SB_CHK_TAG_MATCH_OWED_E);
    before_fail = super.tb_env.scoreboard.get_check_fail_count(
      VIP_CHI_SB_CHK_TAG_MATCH_OWED_E);
    before_result_pass = super.tb_env.scoreboard.get_check_pass_count(
      VIP_CHI_SB_CHK_TAG_MATCH_RESULT_E);
    before_result_fail = super.tb_env.scoreboard.get_check_fail_count(
      VIP_CHI_SB_CHK_TAG_MATCH_RESULT_E);

    // Phase 1: establish the Allocation Tag. Update stores; it asks no question,
    // so it is owed no answer.
    this.tagged_write(TAGOP_UPDATE_C, TAG_C, E_MTE_WRITE_TU_C, drawn);
    if (drawn.size() != 0) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] an Update-tagged write drew %0d TagMatch response(s); section 2.3.1 owes one only when the WriteData asked for the check",
      get_name(), drawn.size()))
    end

    // Phases 2-4. The third is what proves the failing Match did not store its
    // tag: if it had, the tag at this address would now be OTHER_TAG_C and this
    // phase would come back Fail.
    phase_tag  = '{TAG_C, OTHER_TAG_C, TAG_C};
    phase_want = '{1'b1,  1'b0,        1'b1};

    foreach (phase_tag[i]) begin
      this.tagged_write(TAGOP_MATCH_C, phase_tag[i], TU_C, drawn);
      if (drawn.size() != 1) begin
        `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] a Match-tagged write carrying tag 0x%0h drew %0d TagMatch response(s), expected exactly 1",
        get_name(), phase_tag[i], drawn.size()))
      end
      if (drawn[0] != phase_want[i]) begin
        `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] a Match-tagged write carrying tag 0x%0h was answered %s, expected %s -- Table 13-34 requires the physical tags to be checked against the stored Allocation Tags and Table 13-25 carries the answer in Resp[0]",
        get_name(), phase_tag[i], drawn[0] ? "Pass" : "Fail",
        phase_want[i] ? "Pass" : "Fail"))
      end
    end

    after_pass = super.tb_env.scoreboard.get_check_pass_count(
      VIP_CHI_SB_CHK_TAG_MATCH_OWED_E);
    after_fail = super.tb_env.scoreboard.get_check_fail_count(
      VIP_CHI_SB_CHK_TAG_MATCH_OWED_E);
    after_result_pass = super.tb_env.scoreboard.get_check_pass_count(
      VIP_CHI_SB_CHK_TAG_MATCH_RESULT_E);
    after_result_fail = super.tb_env.scoreboard.get_check_fail_count(
      VIP_CHI_SB_CHK_TAG_MATCH_RESULT_E);

    if (after_fail != before_fail) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] CHI_SB_TAG_MATCH_OWED reported %0d time(s) against TagMatch responses the writes' data did ask for",
      get_name(), after_fail - before_fail))
    end
    if ((after_pass - before_pass) != $size(phase_tag)) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] CHI_SB_TAG_MATCH_OWED recorded %0d pass(es) for %0d Match-tagged writes, so it is not reading every response",
      get_name(), after_pass - before_pass, $size(phase_tag)))
    end

    if (after_result_fail != before_result_fail) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] CHI_SB_TAG_MATCH_RESULT reported %0d time(s) against a completer that compared correctly",
      get_name(), after_result_fail - before_result_fail))
    end
    if ((after_result_pass - before_result_pass) != $size(phase_tag)) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] CHI_SB_TAG_MATCH_RESULT recorded %0d pass(es) for %0d Match-tagged writes -- a result rule that judged fewer responses than arrived is reporting on a subset",
      get_name(), after_result_pass - before_result_pass, $size(phase_tag)))
    end

    `uvm_info(get_name(), $sformatf(
    "PASS [%s] %0d Match-tagged writes answered Pass/Fail/Pass by tag, each judged by CHI_SB_TAG_MATCH_OWED and CHI_SB_TAG_MATCH_RESULT",
    get_name(), $size(phase_tag)), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
