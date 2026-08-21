// The vacuity report is a check on the checks, so it needs a check of its own.
//
// "This rule was never exercised" is only useful if it TRACKS THE TRAFFIC. A
// report that listed everything, or nothing, would look identical on a clean run
// and would be believed just as readily -- which is the precise failure this
// whole mechanism exists to prevent, so it must not be the mechanism's own bug.
//
// Two phases on one run, with the same rule read twice:
//
//   phase 1  a plain read. CHI_COMPACK_WITHOUT_EXPCOMPACK cannot have been
//            evaluated, because nothing has sent a CompAck, so it must read as
//            unexercised -- while a rule the read DOES exercise must not.
//   phase 2  a write with ExpCompAck, which makes the requester drive CompAck.
//            The same rule must now have moved out of that state.
//
// Asserting the transition rather than a snapshot is what makes this
// non-tautological: a hard-coded answer would pass phase 1 and fail phase 2.

class tc_chi_check_vacuity extends chi_base_test;

  `uvm_component_utils(tc_chi_check_vacuity)

  // Evaluated only when a CompAck goes out, so a read-only phase cannot reach it.
  localparam vip_chi_check_id_t COMPACK_RULE_C =
    VIP_CHI_CHK_COMPACK_WITHOUT_EXPCOMPACK_E;
  // Evaluated by any outbound REQ, so the very first read reaches it.
  localparam vip_chi_check_id_t ALWAYS_RULE_C =
    VIP_CHI_CHK_REQ_FLITV_REQUIRES_LINK_E;

  localparam item_t::addr_t ADDR_C   = item_t::addr_t'(44'h3F00_0000);
  localparam bit [2:0]      SIZE_C   = 3'd6;   // 64 B = 4 beats on the CHI-D cut
  localparam int            SETTLE_C = 20;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // A rule is "not exercised" exactly when it has neither passed nor failed.
  // ---------------------------------------------------------------------------
  protected function bit rule_unexercised(input vip_chi_check_id_t id);

    return (super.tb_env.rni_agent.vif.check_pass_count[id] == 0) &&
           (super.tb_env.rni_agent.vif.check_fail_count[id] == 0);
  endfunction

  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    phase.raise_objection(this);

    // -- Phase 1: a read cannot exercise the CompAck rule. --------------------
    super.rni0_rd_seq.reset();
    super.rni0_rd_seq.set_requests(1);
    super.rni0_rd_seq.set_initial_addr(ADDR_C);
    super.rni0_rd_seq.set_size(SIZE_C);
    super.rni0_rd_seq.set_get_response(1'b1);
    super.rni0_rd_seq.set_verbose(1'b0);
    super.rni0_rd_seq.start(super.v_sqr.rni_sequencer);

    super.wait_clocks(SETTLE_C);

    if (!this.rule_unexercised(COMPACK_RULE_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s reads as exercised after read-only traffic that cannot reach it - the tallies are not tracking what ran",
        super.tc_name, vip_chi_check_name(COMPACK_RULE_C)))
    end

    if (this.rule_unexercised(ALWAYS_RULE_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s reads as not exercised after a read that must have exercised it - the tallies are under-counting",
        super.tc_name, vip_chi_check_name(ALWAYS_RULE_C)))
    end

    // -- Phase 2: a write with ExpCompAck drives a CompAck. -------------------
    super.rni0_wr_seq.reset();
    super.rni0_wr_seq.set_requests(1);
    super.rni0_wr_seq.set_initial_addr(ADDR_C);
    super.rni0_wr_seq.set_size(SIZE_C);
    super.rni0_wr_seq.set_exp_comp_ack(1'b1);
    super.rni0_wr_seq.set_get_response(1'b1);
    super.rni0_wr_seq.set_verbose(1'b0);
    super.rni0_wr_seq.start(super.v_sqr.rni_sequencer);

    super.wait_clocks(SETTLE_C);

    if (this.rule_unexercised(COMPACK_RULE_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s still reads as not exercised after a write that drove a CompAck - the tallies are stale, not live",
        super.tc_name, vip_chi_check_name(COMPACK_RULE_C)))
    end

    if (super.tb_env.rni_agent.vif.check_pass_count[COMPACK_RULE_C] == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s left the unexercised state without recording a pass - it can only have recorded a failure",
        super.tc_name, vip_chi_check_name(COMPACK_RULE_C)))
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] %s read as unexercised after a read and recorded %0d pass(es) once a CompAck went out",
      super.tc_name, vip_chi_check_name(COMPACK_RULE_C),
      super.tb_env.rni_agent.vif.check_pass_count[COMPACK_RULE_C]), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
