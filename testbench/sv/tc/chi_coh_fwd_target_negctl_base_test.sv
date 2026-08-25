// ===========================================================================
// chi_coh_fwd_target_negctl_base_test
//
// Negative control for the FwdNID/FwdTxnID VALUE rule, the half of IHI 0050 E
// 2.5 that needs the request a snoop was sent for.
//
// The SNP channel bind judges the other half from the flit alone: both fields
// are inapplicable and must be zero on any snoop that is not one of the six
// forwarding forms. On the six that ARE, it passes any value at all, because a
// link-layer checker cannot know which requester the home meant to name. The
// coherency checker can -- it already correlates a snoop to its cause by line
// for catalogue rule D8 -- so the positive half is judged there:
//
//   FwdNID   must be the Node ID of the original Requester
//   FwdTxnID must be the TxnID of the original Request
//
// cfg.hnf_snp_fwd_target_negctl adds one to each field on the first forwarding
// snoop the home sends to a port. One added rather than a constant substituted:
// every requester on this bench drives SrcID zero, so a constant zero would
// corrupt nothing and a constant one would stop corrupting the day a test gives
// them real Node IDs. Off by one is wrong whatever the right answer is.
//
// Both halves are asserted, and the conformant half is the one that matters
// most here. A rule that only ever fired on the injection would be satisfied by
// a checker that rejected EVERY forwarding snoop -- which would false-fail the
// three DCT tests in this regression. So the first phase asserts the rule
// RECORDED A PASS on a conformant forward, not merely that it stayed silent.
//
// The induced errors are caught + demoted so they do not count against the
// verdict, and the test then asserts the counter moved by the exact amount the
// injection accounts for. An error from some other rule would satisfy the
// catcher but not the counter.
//
// Used by:
//   tc_chi_coh_d_fwd_target_negctl    (CHI-D)
//   tc_chi_coh_e_fwd_target_negctl  (wide CHI-E)
// ===========================================================================
class chi_coh_fwd_target_negctl_base_test #(
  vip_chi_cfg_t CFG_P   = CHI_D_CFG_C,
  type          TYPES_T = chi_d_types_t
) extends chi_coherent_base_test #(CFG_P, TYPES_T);

  typedef vip_chi_item #(CFG_P) item_t;

  `uvm_component_param_utils(chi_coh_fwd_target_negctl_base_test #(CFG_P, TYPES_T))

  // The second phase corrupts TWO forwarding snoops and each is TWO reports, and
  // the decomposition is the point rather than a number to tune. The injection
  // latch is per port, and by the second phase RN-F1 is holding the line from the
  // first, so both directions forward:
  //
  //   RN-F0 ReadUnique  -> SnpUniqueFwd to RN-F1   (RN-F1 held it)
  //   RN-F1 ReadShared  -> SnpSharedFwd to RN-F0   (RN-F0 now holds it)
  //
  // and the rule judges FwdNID and FwdTxnID separately, so the message can say
  // which half broke. Two snoops, two fields each. A drop means an arm stopped
  // evaluating or a latch stopped firing; a rise means the traffic changed shape.
  localparam int CORRUPT_REPORTS_C  = 4;
  localparam int CORRUPT_FORWARDS_C = 2;

  chi_coherency_negctl_catcher coh_catcher;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // DCT origination on, injection OFF: the first phase must be conformant.
  protected virtual function void configure_agent_cfgs();
    super.hnf_cfg.hnf_enable_snoop_fwd = 1'b1;
  endfunction

  function void start_of_simulation_phase(input uvm_phase phase);
    super.start_of_simulation_phase(phase);
    this.coh_catcher = new("coh_violation_catcher");
  endfunction

  // One RN-F0 ReadUnique to take the line, then one RN-F1 ReadShared the home
  // serves by forwarding from RN-F0. The pair is run twice, so it is a task.
  protected task drive_one_forward();
    item_t drain;

    this.cfg_read_seq(super.hrnf0_rdunique_seq);
    super.hrnf0_rdunique_seq.start(super.tb_env.hrnf0_agent.sequencer);
    void'(super.hrnf0_rdunique_seq.get_responses());

    while (super.tb_env.hrnf0_snp_fifo.try_get(drain)) begin
    end

    this.cfg_read_seq(super.hrnf1_rdshared_seq);
    super.hrnf1_rdshared_seq.start(super.tb_env.hrnf1_agent.sequencer);
    void'(super.hrnf1_rdshared_seq.get_responses());

    super.wait_clocks(8);
  endtask

  task run_phase(input uvm_phase phase);

    item_t snp_item;
    int    judged_clean;
    int    mismatch_clean;
    int    judged_dirty;
    int    mismatch_dirty;

    phase.raise_objection(this);

    super.wait_reset_settle();

    uvm_report_cb::add(null, this.coh_catcher);

    // ---- The conformant half. A real forward, correctly addressed. ----
    this.drive_one_forward();

    judged_clean   = super.tb_env.coh_checker.get_snp_fwd_judged_count();
    mismatch_clean = super.tb_env.coh_checker.get_snp_fwd_mismatch_count();

    // The rule EVALUATED, and that is the assertion this phase exists for: a
    // silent rule and a passing rule read the same in a mismatch count.
    if (judged_clean < 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the checker judged %0d forwarding snoop(s) on a run that sent one -- the FwdNID/FwdTxnID rule may never have been reached",
        super.tc_name, judged_clean))
    end

    if (mismatch_clean != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the checker reported %0d FwdNID/FwdTxnID violation(s) on a correctly addressed forward -- the rule is stricter than IHI 0050 E 2.5",
        super.tc_name, mismatch_clean))
    end

    // ---- The corrupted half. Same traffic, mis-addressed forward. ----
    super.hnf_cfg.hnf_snp_fwd_target_negctl = 1'b1;

    this.drive_one_forward();

    // The knob did what it says. Asserted against the observed flit so a future
    // change that quietly stops honouring it turns into a failure here rather
    // than a negative control that silently tests nothing.
    if (!super.tb_env.hrnf0_snp_fifo.try_get(snp_item)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F0 observed no snoop for the second forwarding read", super.tc_name))
    end
    if (!vip_chi_snp_opcode_is_forwarding(vip_chi_snp_opcode_t'(snp_item.snp_opcode))) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the second read was not served by a forwarding snoop (snp_opcode 0x%0h), so the injection had nothing to corrupt",
        super.tc_name, snp_item.snp_opcode))
    end

    uvm_report_cb::delete(null, this.coh_catcher);

    judged_dirty   = super.tb_env.coh_checker.get_snp_fwd_judged_count();
    mismatch_dirty = super.tb_env.coh_checker.get_snp_fwd_mismatch_count();

    if (!this.coh_catcher.saw_coherency_error) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Checker D did NOT flag a mis-addressed forwarding snoop -- the FwdNID/FwdTxnID rule may be vacuous",
        super.tc_name))
    end

    if ((judged_dirty - judged_clean) != CORRUPT_FORWARDS_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the second phase produced %0d judged forwarding snoop(s), expected exactly %0d: the report count below is read against that shape and means nothing without it",
        super.tc_name, judged_dirty - judged_clean, CORRUPT_FORWARDS_C))
    end

    // Checked EXACTLY, not as a floor: drift either way means the injection or
    // the rule changed shape and wants reading, not absorbing.
    if ((mismatch_dirty - mismatch_clean) != CORRUPT_REPORTS_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the mis-addressed forwards produced %0d report(s), expected exactly %0d (%0d corrupted forwards, FwdNID and FwdTxnID judged separately on each)",
        super.tc_name, mismatch_dirty - mismatch_clean, CORRUPT_REPORTS_C,
        CORRUPT_FORWARDS_C))
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] a correctly addressed forward passed the rule, and the mis-addressed ones were reported %0d time(s) over %0d judged forwards",
      super.tc_name, mismatch_dirty - mismatch_clean, judged_dirty), UVM_LOW)

    phase.drop_objection(this);
  endtask
endclass
