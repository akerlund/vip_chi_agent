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
// The negative control for the DoNotGoToSD obedience rule.
//
// IHI 0050 E: "Snoopee receiving a Snoop request with the DoNotGoToSD bit set,
// except when the Snoop is SnpOnceFwd, must not transition to SD." The SNP
// channel already has CHI_SNP_DO_NOT_GO_TO_SD_LEGAL, which judges whether the
// bit was SET where the specification requires it. This is the other half --
// whether the snoopee OBEYED it -- and that is the half a third-party DUT can
// get wrong.
//
// Why it takes a control rather than a mutation. The RN-F responder cannot
// produce SD at all: its state map returns only I, SC or the current state,
// which is this VIP's never-SD reduction. So the rule had nothing in the
// regression that could exercise it, and a rule nothing can exercise is
// indistinguishable from one that is absent. cfg.rnf_snp_resp_sd_negctl makes
// the snoopee REPORT SD -- the shadow is untouched, because what the rule judges
// is the response.
//
// Neither neighbouring rule catches this, which is why it needed its own arm:
// catalogue D5 bounds the reported state by the snoop OPCODE and SD is not
// Unique, so a shared snoop answered SD passes it; D6 bounds the state by what
// the snoopee HELD, and an SD holder answering SD passes that too.
//
////////////////////////////////////////////////////////////////////////////////

class chi_coh_do_not_go_to_sd_negctl_base_test #(
  vip_chi_cfg_t CFG_P   = CHI_D_CFG_C,
  type          TYPES_T = chi_d_types_t
) extends chi_coherent_base_test #(CFG_P, TYPES_T);

  typedef vip_chi_item #(CFG_P) item_t;

  `uvm_component_param_utils(chi_coh_do_not_go_to_sd_negctl_base_test #(CFG_P, TYPES_T))

  localparam int SETTLE_C = 40;

  // The injection reports SD on EVERY snoop response, not only on the one this
  // control is aimed at, so it necessarily trips two neighbouring rules as well:
  // D5 (an invalidating snoop must leave the snoopee Invalid) and D6 (a snoop
  // cannot grant a permission the snoopee did not already hold). That collateral
  // is inherent rather than sloppy -- the DoNotGoToSD case under test IS an
  // invalidating snoop in Issue E, so the target case and D5's case are the same
  // flit -- and both are deliberate here.
  //
  // Demoted by message, narrowly, and then COUNTED: a blanket demotion of
  // "COHERENCY VIOLATION" would hide a real one in the same run, and a demotion
  // nobody counts is indistinguishable from a rule that stopped working.
  localparam string D5_PATTERN_C =
    "*answered invalidating snoop opcode*but every response Chapter 4 permits*";
  localparam string D6_PATTERN_C =
    "*a snoop cannot grant a permission the snoopee did not already*";

  // And the rule this control exists to provoke. Demoted for the same reason,
  // and counted separately from the collateral so the E half can assert that
  // THIS one fired and the D half that it did not -- the whole point of running
  // the control in both issues. The get_bad_snp_sd_under_no_sd_count() verdict
  // below is unchanged; only the report is demoted.
  localparam string TARGET_PATTERN_C =
    "*carried DoNotGoToSD = 1 and is not SnpOnceFwd*";

  chi_sb_rule_negctl_catcher coh_catcher;

  // Whether the home's snoop carries DoNotGoToSD on this cut, and therefore
  // whether the rule must fire. The two issues answer differently and BOTH
  // answers are asserted, because that is what shows the rule reads the bit
  // rather than reporting SD unconditionally:
  //
  //   Issue E  13.10.35 lists the invalidating snoops and SnpCleanShared as
  //            must-be-one, so the bit IS set and a snoopee reporting SD is
  //            violating it -- the rule must report.
  //   Issue D  12.9.32 lets the same bit take any value, so the cleared bit is
  //            CONFORMANT and SD is a legal answer -- the rule must stay silent.
  //
  // A control that only ran on E would pass equally well against a rule that
  // ignored the bit and fired on every SD.
  protected bit expect_report = 1'b1;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);
    this.coh_catcher = new("coh_do_not_go_to_sd_catcher");
    this.coh_catcher.add_expected(D5_PATTERN_C);
    this.coh_catcher.add_expected(D6_PATTERN_C);
    this.coh_catcher.add_expected(TARGET_PATTERN_C);

  endfunction

  // ---------------------------------------------------------------------------
  // The snoopee reports SD whatever it actually holds.
  // ---------------------------------------------------------------------------
  protected virtual function void configure_agent_cfgs();

    super.configure_agent_cfgs();

    super.hrnf0_cfg.rnf_snp_resp_sd_negctl = 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Run
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    int before_count;
    int after_count;

    phase.raise_objection(this);

    // The snoopee about to report SD against an invalidating snoop lands in
    // cg_snp_resp_legality's invalidating_must_end_invalid illegal bin, and an
    // illegal bin is not part of the UVM report path: no catcher and no severity
    // can reach it, and VCS ends the simulation on the hit -- before the UVM
    // report summary the regression script greps for is ever printed. Declaring
    // it suppresses the SAMPLE for that pairing only. Every rule still fires,
    // which is what this test asserts below.
    super.tb_env.coh_checker.expect_illegal_snp_resp = 1'b1;
    uvm_report_cb::add(null, this.coh_catcher);

    before_count = super.tb_env.coh_checker.get_bad_snp_sd_under_no_sd_count();

    if (before_count != 0) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] the DoNotGoToSD obedience rule already reported %0d time(s) before the control ran; the count below would prove nothing",
      get_name(), before_count))
    end

    // RN-F0 takes the line, so RN-F1's read has something to snoop it for. The
    // home's snoop carries DoNotGoToSD per E 13.10.35, and RN-F0 answers SD.
    super.cfg_read_seq(super.hrnf0_rdshared_seq);
    super.hrnf0_rdshared_seq.start(super.tb_env.hrnf0_agent.sequencer);

    super.cfg_read_seq(super.hrnf1_rdunique_seq);
    super.hrnf1_rdunique_seq.start(super.tb_env.hrnf1_agent.sequencer);

    super.wait_clocks(SETTLE_C);

    uvm_report_cb::delete(null, this.coh_catcher);

    // The collateral really was the collateral, and not silence. If neither
    // neighbouring rule fired, the injection did not reach the responder at all
    // and the verdict below would be about nothing.
    if ((this.coh_catcher.caught(D5_PATTERN_C) +
         this.coh_catcher.caught(D6_PATTERN_C)) == 0) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] neither D5 nor D6 reported, so the snoopee never answered SD at all and the DoNotGoToSD verdict below would prove nothing",
      get_name()))
    end

    after_count = super.tb_env.coh_checker.get_bad_snp_sd_under_no_sd_count();

    if (this.expect_report) begin
      if (after_count <= before_count) begin
        `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the snoopee reported SD under a set DoNotGoToSD and nothing said so. Either the control is not reaching the responder, or the rule is not reading the bit off the snoop that caused the response",
        get_name()))
      end
    end
    else begin
      if (after_count != before_count) begin
        `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the rule reported %0d time(s) on a cut where the snoop's DoNotGoToSD is legitimately CLEAR: D 12.9.32 lets the bit take any value, so SD is a conformant answer here. A rule that fires anyway is reading the state and not the bit",
        get_name(), after_count - before_count))
      end
    end

    // The demoted count and the rule's own tally must agree. If they diverge,
    // either a report escaped the catcher or the tally moved without a report,
    // and both mean the verdict above is measuring something other than it says.
    if (this.coh_catcher.caught(TARGET_PATTERN_C) != (after_count - before_count)) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] the DoNotGoToSD rule counted %0d violation(s) but %0d reached the report path",
      get_name(), after_count - before_count,
      this.coh_catcher.caught(TARGET_PATTERN_C)))
    end

    `uvm_info(get_name(), $sformatf(
    "PASS [%s] a snoopee reporting SD was reported %0d time(s), and this cut %s DoNotGoToSD (collateral demoted: D5 %0d, D6 %0d)",
    get_name(), after_count - before_count,
    this.expect_report ? "sets" : "does not set",
    this.coh_catcher.caught(D5_PATTERN_C),
    this.coh_catcher.caught(D6_PATTERN_C)), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
