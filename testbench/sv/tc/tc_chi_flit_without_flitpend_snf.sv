// NEGATIVE control for CHI_RSP_VALID_REQUIRES_PEND on the COMPLETER's flits.
//
// tc_chi_flit_without_flitpend is the same control on the requester. This one
// exists because, until then it could not: cfg.flit_without_flitpend was
// honoured only inside the RN-I announce path, and the config layer REJECTED the
// knob on any other role with "on any other role it would set a flag nothing
// reads" -- which was true, and was the defect. The gap had been written down as
// a rule instead of closed.
//
// Every driver that announces a flit now routes it through a helper that
// consults the knob, so setting it on a role selects WHICH role drops its
// announcement. scripts/check_flitpend_negctl.py holds that property: it fails
// if any driver announces a flit outside a helper honouring the knob.
//
// Why it matters that this is the SN-F. The rule tallied plenty of passes on
// completer flits already, so nobody would have called it unexercised -- but a
// rule that has never been shown to FAIL on a path has not been shown to be
// watching that path at all. Passes prove the flits arrive; only a failure
// proves the check is reading them.
//
// Both halves are asserted:
//   * the rule must report exactly once -- one unannounced flit;
//   * the flits after it must still pass, or the rule would be firing on
//     well-formed traffic too.
//
// The rule is turned down to VIP_CHI_CHK_SEV_OFF_E rather than disabled. OFF
// still EVALUATES and still COUNTS -- it only suppresses the report -- which is
// what a negative control needs. Disabling would stop the counting too, leaving
// nothing to assert on.

class tc_chi_flit_without_flitpend_snf extends chi_base_test;

  `uvm_component_utils(tc_chi_flit_without_flitpend_snf)

  localparam item_t::addr_t ADDR_C   = item_t::addr_t'(44'h3E10_0000);
  localparam bit [2:0]      SIZE_C   = 3'd6;   // 64 B = 4 beats on the CHI-D cut
  localparam int            SETTLE_C = 20;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // Drop one announcement on the requester that owns the send path.
  // ---------------------------------------------------------------------------
  protected virtual function void configure_agent_cfgs();

    super.configure_agent_cfgs();

    super.snf_cfg.flit_without_flitpend = 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    int unsigned req_fails;
    int unsigned req_pass;

    phase.raise_objection(this);

    // Suppress the report, keep the count.
    super.tb_env.snf_agent.vif.check_severity[VIP_CHI_CHK_RSP_VALID_REQUIRES_PEND_E] =
      VIP_CHI_CHK_SEV_OFF_E;

    // Two writes: the first carries the unannounced flit, the second is ordinary
    // traffic the rule has to pass. One write alone could not tell a rule that
    // fires once from one that fires on everything.
    super.rni0_wr_seq.reset();
    super.rni0_wr_seq.set_requests(2);
    super.rni0_wr_seq.set_initial_addr(ADDR_C);
    super.rni0_wr_seq.set_size(SIZE_C);
    super.rni0_wr_seq.set_exp_comp_ack(1'b1);
    super.rni0_wr_seq.set_get_response(1'b1);
    super.rni0_wr_seq.set_verbose(1'b0);
    super.rni0_wr_seq.start(super.v_sqr.rni_sequencer);

    super.wait_clocks(SETTLE_C);

    req_fails = super.tb_env.snf_agent.vif.check_fail_count[VIP_CHI_CHK_RSP_VALID_REQUIRES_PEND_E];
    req_pass  = super.tb_env.snf_agent.vif.check_pass_count[VIP_CHI_CHK_RSP_VALID_REQUIRES_PEND_E];

    // Exactly one: the control is one-shot. Zero means the rule cannot see the
    // violation it exists for; more than one means the control did not stop, and
    // the run would say nothing about legal traffic still passing.
    if (req_fails != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s reported %0d time(s) against exactly one unannounced flit; at 0 the rule cannot see its own violation, above 1 the one-shot control did not stop",
        super.tc_name, vip_chi_check_name(VIP_CHI_CHK_RSP_VALID_REQUIRES_PEND_E), req_fails))
    end

    // And the announced flits around it must still pass, or the rule would be
    // rejecting well-formed traffic -- which is exactly the defect it replaced.
    if (req_pass == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s recorded no passes, so this run does not show the rule accepting the announced flits either side of the one it caught",
        super.tc_name, vip_chi_check_name(VIP_CHI_CHK_RSP_VALID_REQUIRES_PEND_E)))
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] one unannounced flit was caught once, and %0d announced flit(s) passed the same rule",
      super.tc_name, req_pass), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
