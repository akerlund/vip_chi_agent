// ===========================================================================
// chi_coh_snoop_match_negctl_base_test
//
// Negative control for chi_coh_read_clean_snoop_base_test. The home is put back
// on the pre-Table-4-5 snoop choice for ReadClean with
// cfg.hnf_snoop_shared_for_read_clean: one is_unique bit, so a ReadClean is
// snooped as though it were a ReadShared.
//
// The knob is worth having because it produces one LEGAL snoop and one ILLEGAL
// one from the same line of code, which is the distinction catalogue rule D8 has
// to draw and the reason the rule is not simply "the snoop must equal the
// Expected column":
//
//   DCT off:  ReadClean -> SnpShared     PERMITTED. The bullet under Table 4-5
//                                        names SnpShared for ReadClean outright.
//                                        D8 must stay SILENT here.
//   DCT on:   ReadClean -> SnpSharedFwd  NOT permitted. The forwarding bullet
//                                        gives ReadClean SnpNotSharedDirtyFwd or
//                                        SnpCleanFwd only. D8 MUST fire.
//
// A control that only drove the second half would pass just as well against a
// checker that rejected every SnpShared it saw, which would false-fail every
// ReadShared in the regression. Driving both halves is what shows the rule is
// the table and not an approximation of it.
//
// The induced error is caught + demoted so it does not count against the
// verdict, and the test then asserts the counter moved -- an error from some
// other rule would satisfy the catcher but not the counter.
//
// Used by:
//   tc_chi_coh_d_snoop_match_negctl    (CHI-D)
//   tc_chi_coh_e_snoop_match_negctl  (wide CHI-E)
// ===========================================================================
class chi_coh_snoop_match_negctl_base_test #(
  vip_chi_cfg_t CFG_P   = CHI_D_CFG_C,
  type          TYPES_T = chi_d_types_t
) extends chi_coherent_base_test #(CFG_P, TYPES_T);

  typedef vip_chi_item #(CFG_P) item_t;

  `uvm_component_param_utils(chi_coh_snoop_match_negctl_base_test #(CFG_P, TYPES_T))

  chi_coherency_negctl_catcher   coh_catcher;
  vip_chi_readclean_seq #(CFG_P) hrnf1_rdclean_seq;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // Put the home back on the is_unique bit for ReadClean.
  protected virtual function void configure_agent_cfgs();
    super.hnf_cfg.hnf_snoop_shared_for_read_clean = 1'b1;
  endfunction

  function void start_of_simulation_phase(input uvm_phase phase);
    super.start_of_simulation_phase(phase);
    this.coh_catcher       = new("coh_violation_catcher");
    this.hrnf1_rdclean_seq = vip_chi_readclean_seq #(CFG_P)::type_id::create("hrnf1_rdclean_seq");
  endfunction

  task run_phase(input uvm_phase phase);

    item_t snp_item;
    item_t drain;
    int    mismatch_after_legal_half;

    phase.raise_objection(this);

    super.wait_reset_settle();

    uvm_report_cb::add(null, this.coh_catcher);

    // ---- The legal half. DCT off, so the knob yields SnpShared. ----
    this.cfg_read_seq(super.hrnf0_rdunique_seq);
    super.hrnf0_rdunique_seq.start(super.tb_env.hrnf0_agent.sequencer);
    void'(super.hrnf0_rdunique_seq.get_responses());

    while (super.tb_env.hrnf0_snp_fifo.try_get(drain)) begin
    end

    this.cfg_read_seq(this.hrnf1_rdclean_seq);
    this.hrnf1_rdclean_seq.start(super.tb_env.hrnf1_agent.sequencer);
    void'(this.hrnf1_rdclean_seq.get_responses());

    super.wait_clocks(8);

    // The knob did what it says. Asserted so a future change that quietly stops
    // honouring it turns into a failure here rather than a negative control that
    // silently tests nothing.
    if (!super.tb_env.hrnf0_snp_fifo.try_get(snp_item)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F0 observed no snoop for the non-forwarded ReadClean", super.tc_name))
    end
    if (snp_item.snp_opcode != item_t::snp_opcode_t'(VIP_CHI_SNP_SHARED_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] expected the knob's SnpShared (0x%0h), got snp_opcode 0x%0h",
        super.tc_name, VIP_CHI_SNP_SHARED_C, snp_item.snp_opcode))
    end

    mismatch_after_legal_half = super.tb_env.coh_checker.get_snp_req_mismatch_count();
    if (mismatch_after_legal_half != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] D8 reported %0d mismatches for SnpShared on a ReadClean, which the bullet under Table 4-5 permits -- the rule is stricter than the spec",
        super.tc_name, mismatch_after_legal_half))
    end

    // ---- The illegal half. DCT on, so the same knob yields SnpSharedFwd. ----
    super.hnf_cfg.hnf_enable_snoop_fwd = 1'b1;

    this.cfg_read_seq(super.hrnf0_rdunique_seq);
    super.hrnf0_rdunique_seq.start(super.tb_env.hrnf0_agent.sequencer);
    void'(super.hrnf0_rdunique_seq.get_responses());

    while (super.tb_env.hrnf0_snp_fifo.try_get(drain)) begin
    end

    this.cfg_read_seq(this.hrnf1_rdclean_seq);
    this.hrnf1_rdclean_seq.start(super.tb_env.hrnf1_agent.sequencer);
    void'(this.hrnf1_rdclean_seq.get_responses());

    super.wait_clocks(8);

    if (!super.tb_env.hrnf0_snp_fifo.try_get(snp_item)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F0 observed no snoop for the forwarded ReadClean", super.tc_name))
    end
    if (snp_item.snp_opcode != item_t::snp_opcode_t'(VIP_CHI_SNP_SHARED_FWD_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] expected the knob's SnpSharedFwd (0x%0h), got snp_opcode 0x%0h",
        super.tc_name, VIP_CHI_SNP_SHARED_FWD_C, snp_item.snp_opcode))
    end

    uvm_report_cb::delete(null, this.coh_catcher);

    if (!this.coh_catcher.saw_coherency_error) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Checker D did NOT flag SnpSharedFwd on a ReadClean -- catalogue rule D8 may be vacuous",
        super.tc_name))
    end

    if (super.tb_env.coh_checker.get_snp_req_mismatch_count() ==
        mismatch_after_legal_half) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] D8 reported no snoop/request mismatch, so the coherency error above came from a different rule",
        super.tc_name))
    end

    phase.drop_objection(this);
  endtask
endclass
