// NEGATIVE control for CHI_REQ_VALID_REQUIRES_PEND: a flit sent with no FLITPEND
// in the cycle before it, which IHI 0050 E §14.4 / D §13.4 require.
//
// This is the control the suite did not have. The rule it replaced ran the
// obligation backwards -- `flitpend |-> flitv` -- and its control drove a lone
// FLITPEND, which the specification explicitly permits; that stimulus is now the
// POSITIVE control in tc_chi_flitpend_without_valid. Nothing anywhere drove the
// thing the rule actually forbids, so the corrected rule needs this to show it
// can fail at all.
//
// cfg.flit_without_flitpend drops the one-cycle announcement in front of exactly
// one flit and then stops, so the rest of the run is legal traffic the same rule
// must pass. Both halves are asserted:
//   * the rule must report exactly once -- one unannounced flit;
//   * the flits after it must still pass, or the rule would be firing on
//     well-formed traffic too and would be useless in an ordinary run.
//
// The rule is turned down to VIP_CHI_CHK_SEV_OFF_E rather than disabled. OFF
// still EVALUATES and still COUNTS -- it only suppresses the report -- which is
// what a negative control needs. Disabling would stop the counting too, leaving
// nothing to assert on.

class tc_chi_flit_without_flitpend extends chi_base_test;

  `uvm_component_utils(tc_chi_flit_without_flitpend)

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

    super.rni_cfg.flit_without_flitpend = 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    int unsigned req_fails;
    int unsigned req_pass;

    phase.raise_objection(this);

    // Suppress the report, keep the count.
    super.tb_env.rni_agent.vif.check_severity[VIP_CHI_CHK_REQ_VALID_REQUIRES_PEND_E] =
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

    req_fails = super.tb_env.rni_agent.vif.check_fail_count[VIP_CHI_CHK_REQ_VALID_REQUIRES_PEND_E];
    req_pass  = super.tb_env.rni_agent.vif.check_pass_count[VIP_CHI_CHK_REQ_VALID_REQUIRES_PEND_E];

    // Exactly one: the control is one-shot. Zero means the rule cannot see the
    // violation it exists for; more than one means the control did not stop, and
    // the run would say nothing about legal traffic still passing.
    if (req_fails != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s reported %0d time(s) against exactly one unannounced flit; at 0 the rule cannot see its own violation, above 1 the one-shot control did not stop",
        super.tc_name, vip_chi_check_name(VIP_CHI_CHK_REQ_VALID_REQUIRES_PEND_E), req_fails))
    end

    // And the announced flits around it must still pass, or the rule would be
    // rejecting well-formed traffic -- which is exactly the defect it replaced.
    if (req_pass == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s recorded no passes, so this run does not show the rule accepting the announced flits either side of the one it caught",
        super.tc_name, vip_chi_check_name(VIP_CHI_CHK_REQ_VALID_REQUIRES_PEND_E)))
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] one unannounced flit was caught once, and %0d announced flit(s) passed the same rule",
      super.tc_name, req_pass), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
