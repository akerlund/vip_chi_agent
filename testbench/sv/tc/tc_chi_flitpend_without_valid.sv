// POSITIVE control for CHI_REQ/RSP/DAT_VALID_REQUIRES_PEND: legal traffic that
// the rule must NOT report.
//
// IHI 0050 E §14.4 / D §13.4 permit a transmitter to "assert and then deassert
// this signal without sending a flit", permit holding it permanently asserted,
// and permit asserting it while holding no L-Credit. The obligation runs the
// other way -- from the flit backwards -- so a lone FLITPEND owes nothing.
//
// This test was a NEGATIVE control until the rule was corrected. It drove the
// same stimulus and asserted that each channel reported exactly one violation,
// because the rule then read `flitpend |-> flitv` and this pulse tripped it. The
// suite therefore asserted that legal CHI traffic must be reported as a
// violation, and passed for doing so. The stimulus was always right; only the
// expected verdict was backwards, so the knob and the pulse are kept and the
// assertions inverted.
//
// cfg.flitpend_without_valid pulses FLITPEND on REQ and RSP for one cycle with
// no flit behind it, once, after the link is up. Both halves are asserted:
//   * neither rule may report at all -- the pulse is permitted;
//   * ordinary traffic afterwards must still be judged, or a run that checked
//     nothing would pass this test just as well.

class tc_chi_flitpend_without_valid extends chi_base_test;

  `uvm_component_utils(tc_chi_flitpend_without_valid)

  localparam item_t::addr_t ADDR_C   = item_t::addr_t'(44'h3E00_0000);
  localparam bit [2:0]      SIZE_C   = 3'd6;   // 64 B = 4 beats on the CHI-D cut
  localparam int            SETTLE_C = 20;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // Emit the lone FLITPEND on the requester that drives those two channels.
  // ---------------------------------------------------------------------------
  protected virtual function void configure_agent_cfgs();

    super.configure_agent_cfgs();

    super.rni_cfg.flitpend_without_valid = 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    vip_chi_check_id_t rules [3];
    int unsigned       fails;
    int unsigned       passes;

    phase.raise_objection(this);

    rules = '{VIP_CHI_CHK_REQ_VALID_REQUIRES_PEND_E,
              VIP_CHI_CHK_RSP_VALID_REQUIRES_PEND_E,
              VIP_CHI_CHK_DAT_VALID_REQUIRES_PEND_E};

    // A write, not a read: the requester transmits a REQ flit and then the
    // WriteData beats, so all three rules are exercised on well-formed traffic
    // after the lone pulse. A read would leave the RSP side untouched.
    super.rni0_wr_seq.reset();
    super.rni0_wr_seq.set_requests(1);
    super.rni0_wr_seq.set_initial_addr(ADDR_C);
    super.rni0_wr_seq.set_size(SIZE_C);
    super.rni0_wr_seq.set_exp_comp_ack(1'b1);
    super.rni0_wr_seq.set_allow_retry(1'b0);
    super.rni0_wr_seq.set_get_response(1'b1);
    super.rni0_wr_seq.set_verbose(1'b0);
    super.rni0_wr_seq.start(super.v_sqr.rni_sequencer);

    super.wait_clocks(SETTLE_C);

    foreach (rules[i]) begin

      fails  = super.tb_env.rni_agent.vif.check_fail_count[rules[i]];
      passes = super.tb_env.rni_agent.vif.check_pass_count[rules[i]];

      // The pulse is permitted, so nothing may be reported for it.
      if (fails != 0) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] %s reported %0d time(s) against a FLITPEND pulse that §14.4 explicitly permits",
          super.tc_name, vip_chi_check_name(rules[i]), fails))
      end

      // ...and the run has to have judged something, or a checker that never
      // ran would satisfy the assertion above just as well as a correct one.
      if (passes == 0) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] %s recorded no passes, so this run says nothing about the rule holding on the flits the write drove",
          super.tc_name, vip_chi_check_name(rules[i])))
      end
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] a lone FLITPEND on REQ and RSP was not reported, and the write that followed was judged on all three channels",
      super.tc_name), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
