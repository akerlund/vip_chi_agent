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
// The negative control for the snoop response-FORM rule: a dirty snoopee
// answers SnpMakeInvalid on DAT, carrying the copy that snoop asks it to
// discard.
//
// IHI 0050 Chapter 4 defines SnpMakeInvalid by exactly that property -- the
// snoopee invalidates and discards any Dirty copy -- and Tables 4-9 / 4-11 list
// no SnpRespData form among its permitted responses. The encoding on the wire
// is legal in itself; what is prohibited is sending it IN ANSWER TO THIS SNOOP,
// so the rule needs the request and the response paired and cannot be written
// on encodings alone.
//
// Why a control is needed at all. The conforming snoopee never emits this
// pairing, so the rule's zero in every other run is unfalsifiable on its own:
// silence and absence look identical. cfg.rnf_snp_resp_data_negctl puts a dirty
// holder back on the data-bearing path for a no-data snoop, which is a response
// a real snoopee could emit -- the decision is corrupted, not the flit.
//
// The stimulus is the shortest path to a dirty holder meeting an invalidating
// snoop: RN-F0 takes the line with MakeUnique, which grants Unique-Dirty and
// materializes beats, then RN-F1 issues MakeInvalid, which makes the home send
// SnpMakeInvalid to RN-F0.
//
// The neighbouring rules must stay SILENT, and that is asserted rather than
// assumed. What is wrong here is the CHANNEL alone: the reported state is
// Invalid, which is what every response Chapter 4 permits to an invalidating
// snoop reports, so D5 passes it; and D7, which catches dirty data NOT handed
// over, excludes this opcode because discarding is what it asks for. A report
// from either would mean the form rule is being credited with a violation
// something else found.
//
////////////////////////////////////////////////////////////////////////////////

class chi_coh_snp_resp_data_negctl_base_test #(
  vip_chi_cfg_t CFG_P   = CHI_D_CFG_C,
  type          TYPES_T = chi_d_types_t
) extends chi_coherent_base_test #(CFG_P, TYPES_T);

  typedef vip_chi_item #(CFG_P) item_t;

  `uvm_component_param_utils(chi_coh_snp_resp_data_negctl_base_test #(CFG_P, TYPES_T))

  localparam int SETTLE_C = 40;

  // The rule this control exists to provoke. Demoted by message so the run can
  // still gate on "UVM_ERROR : 0", and then COUNTED: a demotion nobody counts is
  // indistinguishable from a rule that stopped working.
  localparam string TARGET_PATTERN_C =
    "*that snoop returns no data and discards its dirty copy*";

  chi_sb_rule_negctl_catcher coh_catcher;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);
    this.coh_catcher = new("coh_snp_resp_data_catcher");
    this.coh_catcher.add_expected(TARGET_PATTERN_C);

  endfunction

  // ---------------------------------------------------------------------------
  // The snoopee answers a no-data snoop with data.
  // ---------------------------------------------------------------------------
  protected virtual function void configure_agent_cfgs();

    super.configure_agent_cfgs();

    super.hrnf0_cfg.rnf_snp_resp_data_negctl = 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Run
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    vip_chi_makeunique_seq  #(CFG_P) mu_seq;
    vip_chi_makeinvalid_seq #(CFG_P) mi_seq;
    int    form_before;
    int    form_after;
    int    dirty_snoops_before;
    int    state_before;

    phase.raise_objection(this);

    super.wait_reset_settle();

    // SnpMakeInvalid answered with data is one of cg_snp_resp_legality's
    // illegal bins, and an illegal bin is not part of the UVM report path: no
    // catcher and no severity can reach it, and VCS ends the simulation on the
    // hit -- before the UVM report summary the regression script greps for is
    // ever printed. Declaring it suppresses the SAMPLE for that pairing only.
    // Every rule still fires, which is what this test asserts below.
    super.tb_env.coh_checker.expect_illegal_snp_resp = 1'b1;
    uvm_report_cb::add(null, this.coh_catcher);

    form_before         = super.tb_env.coh_checker.get_bad_snp_resp_form_count();
    state_before        = super.tb_env.coh_checker.get_bad_snp_resp_state_count();
    dirty_snoops_before = super.tb_env.coh_checker.get_snp_no_data_on_dirty_count();

    if (form_before != 0) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] the response-form rule already reported %0d time(s) before the control ran; the count below would prove nothing",
      get_name(), form_before))
    end

    mu_seq = vip_chi_makeunique_seq  #(CFG_P)::type_id::create("mu_seq");
    mi_seq = vip_chi_makeinvalid_seq #(CFG_P)::type_id::create("mi_seq");

    // RN-F0 to Unique-Dirty, so the snoop that follows meets a holder with beats
    // to hand over.
    super.cfg_read_seq(mu_seq);
    mu_seq.start(super.tb_env.hrnf0_agent.sequencer);
    void'(mu_seq.get_responses());

    // RN-F1 invalidates the same line: the home sends SnpMakeInvalid to RN-F0.
    super.cfg_read_seq(mi_seq);
    mi_seq.start(super.tb_env.hrnf1_agent.sequencer);
    void'(mi_seq.get_responses());

    super.wait_clocks(SETTLE_C);

    uvm_report_cb::delete(null, this.coh_catcher);

    // The snoop reached a DIRTY holder, which is the only combination that can
    // distinguish the two behaviours: a clean holder answers on RSP whatever
    // the opcode says, so a verdict taken over one would hold equally against a
    // rule that never ran.
    if (super.tb_env.coh_checker.get_snp_no_data_on_dirty_count() <=
        dirty_snoops_before) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] no no-data snoop reached a dirty holder, so the control had nothing to corrupt and the verdict below would be about nothing",
      get_name()))
    end

    form_after = super.tb_env.coh_checker.get_bad_snp_resp_form_count();

    if (form_after <= form_before) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] a dirty snoopee answered SnpMakeInvalid with data and nothing said so. Either the control is not reaching the responder, or the rule is not pairing the response channel with the snoop that asked",
      get_name()))
    end

    // The demoted count and the rule's own tally must agree. If they diverge,
    // either a report escaped the catcher or the tally moved without a report,
    // and both mean the verdict above is measuring something other than it says.
    if (this.coh_catcher.caught(TARGET_PATTERN_C) != (form_after - form_before)) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] the response-form rule counted %0d violation(s) but %0d reached the report path",
      get_name(), form_after - form_before,
      this.coh_catcher.caught(TARGET_PATTERN_C)))
    end

    // The state axis is untouched by this control, and D5 judging the same
    // response must say so. A report here would mean the two rules are reading
    // one field between them.
    if (super.tb_env.coh_checker.get_bad_snp_resp_state_count() != state_before) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] the state rule reported %0d time(s) on a response whose state is Invalid, which is the only state Chapter 4 permits to an invalidating snoop",
      get_name(),
      super.tb_env.coh_checker.get_bad_snp_resp_state_count() - state_before))
    end

    if (super.tb_env.coh_checker.get_multi_owner_count() != 0) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] %0d single-writer violation(s) while only the response form was corrupted",
      get_name(), super.tb_env.coh_checker.get_multi_owner_count()))
    end

    `uvm_info(get_name(), $sformatf(
    "PASS [%s] a dirty snoopee answering SnpMakeInvalid on DAT was reported %0d time(s), and the state rule beside it stayed silent",
    get_name(), form_after - form_before), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
