// Negative control for the per-check enable itself.
//
// Before checks had identities, a user who hit one false fire during bring-up
// had to disable a whole bind and lose every other rule with it. The fix is only
// worth anything if a disable is actually TARGETED, so this asserts both halves
// on one run of ordinary traffic:
//
//   * the disabled rule records NOTHING -- not a pass, not a fail. Recording
//     passes would be worse than useless: the vacuity report would show a rule
//     the user switched off as quietly holding.
//   * a sibling rule on the same channel family still records passes, which is
//     what says the disable hit one rule rather than the bind.
//
// The sibling is checked on the SAME traffic rather than a second run, because a
// disable that silently took the whole bind down would otherwise be invisible --
// both rules would read zero and the test would pass.

class tc_chi_check_disable extends chi_base_test;

  `uvm_component_utils(tc_chi_check_disable)

  // Both fire on an ordinary WRITE, which is why the traffic is a write: the
  // requester transmits the REQ flit and then the WriteData beats, so one rule
  // sees each. A read would not do -- the requester only RECEIVES the data
  // beats, and these rules are on the transmit side, so the sibling would read
  // zero and the test would fail for a reason unrelated to the disable.
  localparam vip_chi_check_id_t DISABLED_C = VIP_CHI_CHK_REQ_FLITV_REQUIRES_LINK_E;
  localparam vip_chi_check_id_t SIBLING_C  = VIP_CHI_CHK_DAT_FLITV_REQUIRES_LINK_E;

  localparam item_t::addr_t ADDR_C   = item_t::addr_t'(44'h3E80_0000);
  localparam bit [2:0]      SIZE_C   = 3'd6;   // 64 B = 4 beats on the CHI-D cut
  localparam int            SETTLE_C = 20;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    int unsigned disabled_pass;
    int unsigned disabled_fail;
    int unsigned sibling_pass;

    phase.raise_objection(this);

    // Before any traffic. The checkers seed their registry in an initial block
    // at time 0, and the first flit does not go out until the sequence starts.
    super.tb_env.rni_agent.vif.check_enabled[DISABLED_C] = 1'b0;
    super.tb_env.snf_agent.vif.check_enabled[DISABLED_C] = 1'b0;

    super.rni0_wr_seq.reset();
    super.rni0_wr_seq.set_requests(2);
    super.rni0_wr_seq.set_initial_addr(ADDR_C);
    super.rni0_wr_seq.set_size(SIZE_C);
    super.rni0_wr_seq.set_allow_retry(1'b0);
    super.rni0_wr_seq.set_get_response(1'b1);
    super.rni0_wr_seq.set_verbose(1'b0);
    super.rni0_wr_seq.start(super.v_sqr.rni_sequencer);

    super.wait_clocks(SETTLE_C);

    disabled_pass = super.tb_env.rni_agent.vif.check_pass_count[DISABLED_C];
    disabled_fail = super.tb_env.rni_agent.vif.check_fail_count[DISABLED_C];
    sibling_pass  = super.tb_env.rni_agent.vif.check_pass_count[SIBLING_C];

    // The sibling has to have fired, or this run proves nothing about the
    // disable: a bind that never checked anything would satisfy the next
    // assertion trivially.
    if (sibling_pass == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s recorded 0 passes on traffic that should exercise it - the run proves nothing about the disable",
        super.tc_name, vip_chi_check_name(SIBLING_C)))
    end

    if ((disabled_pass != 0) || (disabled_fail != 0)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s was disabled but recorded %0d pass(es) and %0d fail(es); a disabled rule must record nothing, or the vacuity report shows a switched-off rule as quietly holding",
        super.tc_name, vip_chi_check_name(DISABLED_C), disabled_pass, disabled_fail))
    end

    if (super.tb_env.rni_agent.vif.check_enabled[SIBLING_C] != 1'b1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s was disabled too - the disable was not targeted",
        super.tc_name, vip_chi_check_name(SIBLING_C)))
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] %s recorded nothing while %s recorded %0d pass(es) on the same traffic",
      super.tc_name, vip_chi_check_name(DISABLED_C),
      vip_chi_check_name(SIBLING_C), sibling_pass), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
