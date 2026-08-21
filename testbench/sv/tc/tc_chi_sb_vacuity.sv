// The scoreboard's vacuity report is a check on the checks, so it needs a check
// of its own -- the same argument tc_chi_check_vacuity makes for the SVA binds,
// applied to the half of the registry that was outside the mechanism until now.
//
// "This scoreboard rule was never exercised" is only useful if it TRACKS THE
// TRAFFIC. A report that listed every rule, or none, would look identical on a
// clean run and would be believed just as readily. That failure would be worse
// here than on the SVA side, because the scoreboard's rules had no pass counts
// at all before: a rule that stopped evaluating and a rule that always held
// produced the same log, which is precisely what this exists to end.
//
// Two phases on one run, with the same rule read twice:
//
//   phase 1  an UNORDERED read. CHI_SB_ORDERED_ACK_IN_ORDER cannot have been
//            evaluated -- nothing joined an ordered stream -- so it must read as
//            unexercised, while CHI_SB_TXN_COMPLETES, which that same read does
//            reach, must not.
//   phase 2  an ORDERED read, whose ReadReceipt is the completer committing to a
//            position in its stream. The same rule must now have moved out.
//
// Asserting the transition rather than a snapshot is what makes this
// non-tautological: a hard-coded answer would pass phase 1 and fail phase 2.
//
// The pass COUNT is asserted too, not just the rule's absence from the list. A
// rule leaves the unexercised list on its first fail as readily as on its first
// pass, so absence alone would also be satisfied by an ordered stream the
// completer got wrong.

class tc_chi_sb_vacuity extends chi_base_test;

  `uvm_component_utils(tc_chi_sb_vacuity)

  // Reached only by a request that carries a non-zero Order field.
  localparam vip_chi_sb_check_id_t ORDER_RULE_C =
    VIP_CHI_SB_CHK_ORDERED_ACK_IN_ORDER_E;
  // Reached by any transaction that retires, so the very first read reaches it.
  localparam vip_chi_sb_check_id_t ALWAYS_RULE_C =
    VIP_CHI_SB_CHK_TXN_COMPLETES_E;

  localparam item_t::addr_t ADDR_C   = item_t::addr_t'(44'h3C80_0000);
  localparam bit [2:0]      SIZE_C   = 3'd6;   // 64 B = 4 beats on the CHI-D cut
  localparam int            N_C      = 4;
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
  protected function bit rule_unexercised(input vip_chi_sb_check_id_t id);

    return (super.tb_env.scoreboard.get_check_pass_count(id) == 0) &&
           (super.tb_env.scoreboard.get_check_fail_count(id) == 0);
  endfunction

  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    phase.raise_objection(this);

    // -- Phase 1: an unordered read cannot exercise the ordering rule. --------
    super.rni0_rd_seq.reset();
    super.rni0_rd_seq.set_requests(1);
    super.rni0_rd_seq.set_initial_addr(ADDR_C);
    super.rni0_rd_seq.set_size(SIZE_C);
    super.rni0_rd_seq.set_get_response(1'b1);
    super.rni0_rd_seq.set_verbose(1'b0);
    super.rni0_rd_seq.start(super.v_sqr.rni_sequencer);

    super.wait_clocks(SETTLE_C);

    if (!this.rule_unexercised(ORDER_RULE_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s is reported as exercised after an UNORDERED read, which cannot reach it - the report is not tracking the traffic",
        super.tc_name, vip_chi_sb_check_name(ORDER_RULE_C)))
    end

    // The other half, and the one that makes this more than a spelling test: a
    // report that simply listed everything would satisfy the assertion above.
    if (this.rule_unexercised(ALWAYS_RULE_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s is reported as unexercised after a read that retired - the report is listing rules it has no business listing",
        super.tc_name, vip_chi_sb_check_name(ALWAYS_RULE_C)))
    end

    // -- Phase 2: an ordered read reaches it. ---------------------------------
    super.rni0_rd_seq.reset();
    super.rni0_rd_seq.set_requests(N_C);
    super.rni0_rd_seq.set_initial_addr(ADDR_C);
    super.rni0_rd_seq.set_size(SIZE_C);
    super.rni0_rd_seq.set_order(VIP_CHI_ORDER_REQ_ORDER_E);
    super.rni0_rd_seq.set_get_response(1'b1);
    super.rni0_rd_seq.set_verbose(1'b0);
    super.rni0_rd_seq.start(super.v_sqr.rni_sequencer);

    super.wait_clocks(SETTLE_C);

    if (this.rule_unexercised(ORDER_RULE_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s is still reported as unexercised after %0d ORDERED reads - the report does not move, so it cannot be read as evidence",
        super.tc_name, vip_chi_sb_check_name(ORDER_RULE_C), N_C))
    end

    // It moved because the rule PASSED, not because it failed.
    if (super.tb_env.scoreboard.get_check_fail_count(ORDER_RULE_C) != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s reported %0d failure(s) against an in-order completer",
        super.tc_name, vip_chi_sb_check_name(ORDER_RULE_C),
        super.tb_env.scoreboard.get_check_fail_count(ORDER_RULE_C)))
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] %s moved from unexercised to %0d pass(es) when the traffic reached it, while %s never appeared in the report",
      super.tc_name, vip_chi_sb_check_name(ORDER_RULE_C),
      super.tb_env.scoreboard.get_check_pass_count(ORDER_RULE_C),
      vip_chi_sb_check_name(ALWAYS_RULE_C)), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
