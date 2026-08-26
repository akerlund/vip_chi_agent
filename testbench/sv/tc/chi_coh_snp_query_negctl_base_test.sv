// ===========================================================================
// chi_coh_snp_query_negctl_base_test
//
// Negative control for catalogue rule D10, the state-preserving snoop.
//
// IHI 0050 E 4.5, SnpQuery: "The SnpQuery snoop must not change the state of the
// cache line at the Snoopee." cfg.rnf_snp_query_mutates_negctl makes RN-F0
// invalidate the line under the query and answer SnpResp_I, which is a
// self-consistent response: it reports exactly what the responder did.
//
// That self-consistency is what makes it a control and not merely a broken flit.
// The other snoop-response rules bound the answer from above and all of them
// pass it. D5 bounds it by what the opcode asked for, and a query asks for
// nothing. D6 bounds it by what the snoopee held, and I claims less rather than
// more. D7 wants a dirty copy accounted for and excludes the snoops that return
// no data, which is the set SnpQuery is in. A line can therefore be lost to a
// query with every other rule agreeing, which is the gap D10 was written for --
// so the test asserts not only that a violation was reported but that this rule
// is the one that reported it, and that nothing else did.
//
// Used by:
//   tc_chi_coh_e_snp_query_negctl  (wide CHI-E)
// ===========================================================================
class chi_coh_snp_query_negctl_base_test #(
  vip_chi_cfg_t CFG_P   = CHI_E_WIDE_CFG_C,
  type          TYPES_T = chi_e_wide_types_t
) extends chi_coherent_base_test #(CFG_P, TYPES_T);

  typedef vip_chi_item #(CFG_P) item_t;

  `uvm_component_param_utils(chi_coh_snp_query_negctl_base_test #(CFG_P, TYPES_T))

  localparam int SETTLE_C = 16;

  // The home's own report, declared as inherent collateral rather than caught by
  // accident. A snoopee that drops the line under a query necessarily
  // desynchronises the filter the query was sent to confirm -- the two are the
  // same event seen from the two ends, so a run in which D10 fires and this does
  // not would mean the home stopped comparing. It is asserted BY COUNT against
  // D10's own tally below, not merely demoted.
  localparam string DIR_MISMATCH_PATTERN_C = "*SnpQuery on line*reports state*";

  chi_coherency_negctl_catcher coh_catcher;
  chi_sb_rule_negctl_catcher   dir_catcher;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  protected virtual function void configure_agent_cfgs();
    super.hnf_cfg.hnf_snp_query_enable        = 1'b1;
    super.hrnf0_cfg.rnf_snp_query_mutates_negctl = 1'b1;
  endfunction

  function void start_of_simulation_phase(input uvm_phase phase);
    super.start_of_simulation_phase(phase);
    this.coh_catcher = new("coh_violation_catcher");
    this.dir_catcher = new("snp_query_dir_mismatch_catcher");
    this.dir_catcher.add_expected(DIR_MISMATCH_PATTERN_C);
  endfunction

  task run_phase(input uvm_phase phase);

    int judged;
    int bad;

    phase.raise_objection(this);

    super.wait_reset_settle();

    uvm_report_cb::add(null, this.coh_catcher);
    uvm_report_cb::add(null, this.dir_catcher);

    this.cfg_read_seq(super.hrnf0_rdunique_seq);
    super.hrnf0_rdunique_seq.start(super.tb_env.hrnf0_agent.sequencer);
    void'(super.hrnf0_rdunique_seq.get_responses());

    this.cfg_read_seq(super.hrnf1_rdshared_seq);
    super.hrnf1_rdshared_seq.start(super.tb_env.hrnf1_agent.sequencer);
    void'(super.hrnf1_rdshared_seq.get_responses());

    super.wait_clocks(SETTLE_C);

    uvm_report_cb::delete(null, this.coh_catcher);
    uvm_report_cb::delete(null, this.dir_catcher);

    judged = super.tb_env.coh_checker.get_snp_preserving_judged_count();
    if (judged == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] D10 judged no response, so the control had nothing to corrupt",
        super.tc_name))
    end

    if (!this.coh_catcher.saw_coherency_error) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the checker did NOT flag a snoopee that moved its line under a snoop forbidden to change it -- catalogue rule D10 may be vacuous",
        super.tc_name))
    end

    bad = super.tb_env.coh_checker.get_bad_snp_state_preserved_count();
    if (bad == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] D10 counted no violation, so the coherency error above came from a different rule",
        super.tc_name))
    end

    // And no other COHERENCY rule reported. This is the claim the header above
    // makes and the one worth proving: if some other rule also fired, D10 could
    // be removed tomorrow and this test would still pass, which is the shape of
    // a rule that looks exercised and is not.
    if (this.coh_catcher.claimed != bad) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] another coherency rule reported alongside D10 (%0d coherency errors for %0d preserved-state failures); the control is no longer isolating the one property under test",
        super.tc_name, this.coh_catcher.claimed, bad))
    end

    // The home's reconciliation, held against the same number. It is not a
    // second opinion on D10: D10 reads the response off the wire, this compares
    // the answer with a directory the checker never sees, and the control moves
    // both at once. Asserting the count rather than the flag is what makes it
    // evidence -- a home that had stopped comparing would show zero here while
    // D10 went on passing.
    if (super.tb_env.hnf_agent.hnf_driver.n_snp_query_dir_mismatch != bad) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the home reported %0d SnpQuery/directory mismatch(es) for %0d preserved-state failures; a snoopee that moved under the query desynchronises the filter by construction, so the two must agree",
        super.tc_name,
        super.tb_env.hnf_agent.hnf_driver.n_snp_query_dir_mismatch, bad))
    end

    if (this.dir_catcher.caught(DIR_MISMATCH_PATTERN_C) != bad) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the home's mismatch counter moved %0d time(s) but %0d report(s) reached the report path",
        super.tc_name, bad,
        this.dir_catcher.caught(DIR_MISMATCH_PATTERN_C)))
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] D10 reported %0d of %0d judged response(s), as the negative control intended",
      super.tc_name, bad, judged), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
