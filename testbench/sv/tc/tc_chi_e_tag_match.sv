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
// What is asserted:
//   * CHI_SB_TAG_MATCH_OWED records a pass and no failure;
//   * a TagMatch RSP is actually observed on the wire, so the test cannot pass
//     against a completer that stayed silent -- the rule is silent then too.
//
////////////////////////////////////////////////////////////////////////////////

class tc_chi_e_tag_match extends chi_e_base_test;

  typedef vip_chi_item #(CHI_E_WIDE_CFG_C) item_t;

  `uvm_component_utils(tc_chi_e_tag_match)

  localparam int SETTLE_C = 20;

  // Table 13-34: 0b11 is Match on a write.
  localparam int unsigned TAGOP_MATCH_C = 2'b11;
  localparam int unsigned TAG_C         = 'h1234;
  // 13.10.38: "TU field is not applicable and must be set to zero" under Match.
  localparam int unsigned TU_C          = 'h0;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  // Run
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t obs;
    bit    saw_tag_match;
    int    before_pass;
    int    before_fail;
    int    after_pass;
    int    after_fail;

    phase.raise_objection(this);

    super.drain_observation_fifos();

    before_pass = super.tb_env.scoreboard.get_check_pass_count(
      VIP_CHI_SB_CHK_TAG_MATCH_OWED_E);
    before_fail = super.tb_env.scoreboard.get_check_fail_count(
      VIP_CHI_SB_CHK_TAG_MATCH_OWED_E);

    super.rni_wr_seq.reset();
    super.rni_wr_seq.set_requests(1);
    super.rni_wr_seq.set_initial_addr(E_TAG_MATCH_ADDR_C);
    super.rni_wr_seq.set_size(6);
    super.rni_wr_seq.set_src_id(E_MTE_RNI_NODE_ID_C);
    super.rni_wr_seq.set_tgt_id(E_MTE_SNF_NODE_ID_C);
    super.rni_wr_seq.set_dat_tagop(TAGOP_MATCH_C);
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
      "FATAL [%s] no TagMatch RSP was observed for a write whose data carried TagOp = Match; section 2.3.1 owes one",
      get_name()))
    end

    after_pass = super.tb_env.scoreboard.get_check_pass_count(
      VIP_CHI_SB_CHK_TAG_MATCH_OWED_E);
    after_fail = super.tb_env.scoreboard.get_check_fail_count(
      VIP_CHI_SB_CHK_TAG_MATCH_OWED_E);

    if (after_fail != before_fail) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] CHI_SB_TAG_MATCH_OWED reported %0d time(s) against a TagMatch the write's data did ask for",
      get_name(), after_fail - before_fail))
    end
    if (after_pass <= before_pass) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] CHI_SB_TAG_MATCH_OWED recorded no pass, so the rule is not reading the response",
      get_name()))
    end

    `uvm_info(get_name(), $sformatf(
    "PASS [%s] a Match-tagged write was answered with TagMatch, checked %0d time(s) by CHI_SB_TAG_MATCH_OWED",
    get_name(), after_pass - before_pass), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
