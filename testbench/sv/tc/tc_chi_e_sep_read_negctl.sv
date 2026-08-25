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
// The NEGATIVE control for CHI_SB_ORIGINATOR_LEGAL (F-CORR-013), in two phases,
// because the rule has two ways of being reached and only one of them is a
// defect.
//
// PHASE 1 -- a Slave emits a Home-only response. cfg.snf_resp_sep_data_negctl
// restores what both ports did before F-CORR-013: the completer answers a
// ReadNoSnpSep with RespSepData. Appendix B Table B-3 gives RespSepData one From
// row, ICN(HN-F, HN-I), and section 2.3.1 says it in prose -- "RespSepData is
// permitted from the Home only." Every field on that flit is legal, it arrives
// on the right channel at the right moment, and the requester accepts it. The
// ONLY thing wrong with it is who sent it, which is precisely the class of
// defect no other check in either port can see.
//
// PHASE 2 -- the stand-in switched off. This link is point-to-point
// RN-I <-> SN-F with no Home component on it, so the RN-I plays the Home's REQ
// leg for the separated read and the checker grants it a Home's originator
// rights for that one opcode. Clearing scoreboard.home_standin takes the grant
// away and makes the checker judge the link as literal Appendix B, where
// ReadNoSnpSep from an RN-I has no row at all. That is not a defect being
// injected -- it is the VIP's documented departure being made visible. An
// exemption nothing can switch off is an exemption nobody can audit, and this
// phase is what proves the rule reaches the separated-read REQ rather than
// passing it by.
//
// tc_chi_e_sep_read is the positive half: same traffic, ReadReceipt +
// DataSepResp, rule silent.
//
////////////////////////////////////////////////////////////////////////////////

class tc_chi_e_sep_read_negctl extends chi_e_base_test;

  typedef vip_chi_item #(CHI_E_WIDE_CFG_C) item_t;

  `uvm_component_utils(tc_chi_e_sep_read_negctl)

  localparam int SETTLE_C = 20;

  // The scoreboard reports unconditionally -- expect_failure() declares intent
  // for the CSV export and nothing more -- so the two errors this control
  // provokes on purpose have to be demoted, or the regression script's
  // "UVM_ERROR : 0" gate reads a working negative control as a failure.
  localparam string ORIG_ERR_PATTERN_C = "*may not originate*";

  chi_sb_rule_negctl_catcher sb_catcher;

  // Plain packed-vector localparams cast at use, NOT `item_t::<field>_t` typed
  // constants: a class-scoped localparam whose type is a parameterized-class
  // nested type hangs VCS code-gen at CHI-E flit width. Same convention as
  // tc_chi_e_sep_read.
  localparam logic [10:0] RNI_NID_C           = 11'h15;
  localparam logic [10:0] SNF_NID_C           = 11'h2a;
  localparam logic [51:0] SEP_READ_ADDR_C     = 52'h0012_3456_7A00;
  localparam logic [7:0]  SEP_RETURN_TXN_ID_C = 8'h5A;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);
    this.sb_catcher = new("sb_originator_catcher");
    this.sb_catcher.add_expected(ORIG_ERR_PATTERN_C);
  endfunction

  // ---------------------------------------------------------------------------
  // Phase 1's control. Phase 2 clears it again -- the two provocations must be
  // counted apart or a single increment could stand in for both.
  // ---------------------------------------------------------------------------
  protected virtual function void configure_agent_cfgs();

    super.configure_agent_cfgs();
    this.rni_cfg.snf_resp_sep_data_negctl = 1'b1;
    this.snf_cfg.snf_resp_sep_data_negctl = 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Drive one separated read.
  // ---------------------------------------------------------------------------
  protected task issue_sep_read(input logic [7:0] return_txn_id);

    super.rni_rd_seq.reset();
    super.rni_rd_seq.set_requests(1);
    super.rni_rd_seq.set_initial_addr(item_t::addr_t'(SEP_READ_ADDR_C));
    super.rni_rd_seq.set_size(3'd6);
    super.rni_rd_seq.set_sep_read(1'b1);
    super.rni_rd_seq.set_src_id(item_t::node_id_t'(RNI_NID_C));
    super.rni_rd_seq.set_tgt_id(item_t::node_id_t'(SNF_NID_C));
    super.rni_rd_seq.set_return_nid(item_t::node_id_t'(RNI_NID_C));  // must == src_id
    super.rni_rd_seq.set_return_txn_id(item_t::txn_id_t'(return_txn_id));
    super.rni_rd_seq.set_get_response(1'b1);
    super.rni_rd_seq.set_verbose(1'b0);
    super.rni_rd_seq.start(super.tb_env.rni_agent.sequencer);
  endtask

  // ---------------------------------------------------------------------------
  // Run
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t obs;
    bit    saw_resp_sep_data;
    int    before_fail;
    int    after_phase1;
    int    after_phase2;
    int    standin_before;

    phase.raise_objection(this);

    uvm_report_cb::add(null, this.sb_catcher);
    super.tb_env.scoreboard.expect_failure(VIP_CHI_SB_CHK_ORIGINATOR_LEGAL_E);

    super.drain_observation_fifos();

    before_fail = super.tb_env.scoreboard.get_check_fail_count(
      VIP_CHI_SB_CHK_ORIGINATOR_LEGAL_E);

    if (before_fail != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] CHI_SB_ORIGINATOR_LEGAL already reported %0d time(s) on bring-up traffic; the counts below would prove nothing",
        super.tc_name, before_fail))
    end

    // -- Phase 1: a Slave emitting a Home-only response -----------------------
    this.issue_sep_read(SEP_RETURN_TXN_ID_C);
    super.wait_clocks(SETTLE_C);

    // The illegal flit really went out. Without this the phase passes against a
    // completer that emitted nothing, because the rule is silent then too -- it
    // judges an arriving flit, and no flit is no judgement.
    saw_resp_sep_data = 1'b0;
    while (super.tb_env.rni_rsp_fifo.try_get(obs)) begin
      if (obs.rsp_opcode == item_t::rsp_opcode_t'(VIP_CHI_RSP_RESP_SEP_DATA_C)) begin
        saw_resp_sep_data = 1'b1;
      end
    end

    if (!saw_resp_sep_data) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the control did not emit a RespSepData at all, so nothing was provoked",
        super.tc_name))
    end

    after_phase1 = super.tb_env.scoreboard.get_check_fail_count(
      VIP_CHI_SB_CHK_ORIGINATOR_LEGAL_E);

    if (after_phase1 <= before_fail) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] CHI_SB_ORIGINATOR_LEGAL did not report a RespSepData emitted by a node in the SN-F role. Appendix B Table B-3 permits it from a Home only, so either the RSP table is not being consulted or the monitor is not attributing the flit to the node that sent it",
        super.tc_name))
    end

    // The stand-in is a REQ-side grant and must not have absorbed an RSP-side
    // violation: if this moved, the exemption is wider than it claims to be.
    if (super.tb_env.scoreboard.get_originator_standin() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the Home stand-in fired %0d time(s); it may cover the ReadNoSnpSep REQ and nothing else",
        super.tc_name, super.tb_env.scoreboard.get_originator_standin()))
    end

    // -- Phase 2: the departure made visible ----------------------------------
    this.rni_cfg.snf_resp_sep_data_negctl = 1'b0;
    this.snf_cfg.snf_resp_sep_data_negctl = 1'b0;
    super.tb_env.scoreboard.home_standin  = 1'b0;
    super.drain_observation_fifos();

    standin_before = super.tb_env.scoreboard.get_originator_standin();

    this.issue_sep_read(SEP_RETURN_TXN_ID_C + 8'd1);
    super.wait_clocks(SETTLE_C);

    after_phase2 = super.tb_env.scoreboard.get_check_fail_count(
      VIP_CHI_SB_CHK_ORIGINATOR_LEGAL_E);

    if (after_phase2 <= after_phase1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] CHI_SB_ORIGINATOR_LEGAL did not report ReadNoSnpSep from an RN-I with the Home stand-in switched off. Table B-1 gives that opcode two From rows, both ICN, so with no stand-in it has no legal originator on this link -- a silent pass here means the REQ table is not being consulted at all",
        super.tc_name))
    end

    if (super.tb_env.scoreboard.get_originator_standin() != standin_before) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the Home stand-in fired again after being switched off",
        super.tc_name))
    end

    // Both provocations went through the report path, not only through the
    // tally: a rule that increments a counter but never reports is a rule no
    // reader of the log would ever see fire.
    uvm_report_cb::delete(null, this.sb_catcher);

    if (this.sb_catcher.caught(ORIG_ERR_PATTERN_C) !=
        (after_phase2 - before_fail)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the rule counted %0d violation(s) but only %0d reached the report path; a counted-but-silent violation is invisible in a log",
        super.tc_name, after_phase2 - before_fail,
        this.sb_catcher.caught(ORIG_ERR_PATTERN_C)))
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] CHI_SB_ORIGINATOR_LEGAL reported a Home-only RespSepData from a Slave %0d time(s) and an unexempted ReadNoSnpSep from an RN-I %0d time(s)",
      super.tc_name, after_phase1 - before_fail, after_phase2 - after_phase1),
      UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
