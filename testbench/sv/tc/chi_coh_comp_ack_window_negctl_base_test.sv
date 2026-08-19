// ===========================================================================
// chi_coh_comp_ack_window_negctl_base_test
//
// Negative control for catalogue rule D9, the CompAck ordering window.
//
// IHI 0050 E section 2.8.3 / D section 2.8.3, rule 2 of the completion
// sequence: "An HN-F, except in the case of ReadOnce*, waits for CompAck before
// sending a subsequent snoop to the same address." The same section states the
// guarantee the requester is owed: "it is guaranteed not to receive a Snoop
// request to the same address between the point that it receives Comp and the
// point that it sends CompAck."
//
// cfg.hnf_snoop_before_comp_ack makes the home send exactly one snoop into that
// window. SnpOnce is chosen deliberately: it leaves the snoopee's state and its
// data untouched, and section 4.4 permits a home to snoop spontaneously, so
// nothing about the flit is wrong except WHEN it was sent. Any other opcode
// would also perturb the shadow, and a failure could then be blamed on D5, D6 or
// the single-writer rule instead of on the one property under test.
//
// The window is widened on purpose. cfg.rsp_valid_delay_* holds RN-F0's RSP
// flits for a fixed count of cycles, so the CompAck lands well after the
// injected snoop rather than racing it. Without that the two flits are separated
// by two or three cycles of driver plumbing and the control would pass or fail
// on timing rather than on the rule.
//
// The induced error is counted but not reported (check severity stays as it is;
// the coherency rule reports through uvm_error, so the catcher demotes it), and
// the test then asserts the D9 counter moved -- an error from some other rule
// would satisfy the catcher but not the counter.
//
// Used by:
//   tc_chi_coh_d_comp_ack_window_negctl  (CHI-D)
//   tc_chi_coh_e_comp_ack_window_negctl  (wide CHI-E)
// ===========================================================================
class chi_coh_comp_ack_window_negctl_base_test #(
  vip_chi_cfg_t CFG_P   = CHI_D_CFG_C,
  type          TYPES_T = chi_d_types_t
) extends chi_coherent_base_test #(CFG_P, TYPES_T);

  typedef vip_chi_item #(CFG_P) item_t;

  `uvm_component_param_utils(chi_coh_comp_ack_window_negctl_base_test #(CFG_P, TYPES_T))

  // Long enough that the acknowledgement cannot beat a snoop the home sends the
  // moment its last CompData beat is on the wire.
  localparam int ACK_DELAY_C = 8;
  localparam int SETTLE_C    = 40;

  chi_coherency_negctl_catcher coh_catcher;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // The home snoops inside the window; the requester answers late so the window
  // is unambiguously open when it does.
  protected virtual function void configure_agent_cfgs();
    super.hnf_cfg.hnf_snoop_before_comp_ack = 1'b1;
    super.hrnf0_cfg.rsp_valid_delay_enabled = 1'b1;
    super.hrnf0_cfg.rsp_valid_delay_min     = ACK_DELAY_C;
    super.hrnf0_cfg.rsp_valid_delay_max     = ACK_DELAY_C;
  endfunction

  function void start_of_simulation_phase(input uvm_phase phase);
    super.start_of_simulation_phase(phase);
    this.coh_catcher = new("coh_violation_catcher");
  endfunction

  task run_phase(input uvm_phase phase);

    phase.raise_objection(this);

    super.wait_reset_settle();

    uvm_report_cb::add(null, this.coh_catcher);

    this.cfg_read_seq(super.hrnf0_rdshared_seq);
    super.hrnf0_rdshared_seq.start(super.tb_env.hrnf0_agent.sequencer);
    void'(super.hrnf0_rdshared_seq.get_responses());

    super.wait_clocks(SETTLE_C);

    uvm_report_cb::delete(null, this.coh_catcher);

    // A window must have opened, or the snoop had nothing to fall inside of.
    if (super.tb_env.coh_checker.get_comp_ack_window_count() == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] no CompAck window opened, so the injected snoop was judged against nothing",
        super.tc_name))
    end

    if (!this.coh_catcher.saw_coherency_error) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the checker did NOT flag a snoop sent inside the CompAck window -- catalogue rule D9 may be vacuous",
        super.tc_name))
    end

    if (super.tb_env.coh_checker.get_comp_ack_window_snoop_count() == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] D9 counted no in-window snoop, so the coherency error above came from a different rule",
        super.tc_name))
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] D9 reported %0d snoop(s) inside a CompAck window, as the negative control intended",
      super.tc_name,
      super.tb_env.coh_checker.get_comp_ack_window_snoop_count()), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
