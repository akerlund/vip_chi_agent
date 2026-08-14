// Negative control for the scoreboard's ordered-stream check. With
// cfg.snf_reorder_ordered_service the buffered SN-F serves one pair of queued
// ordered requests back to front, so its acknowledgements come back in the wrong
// order. Nothing else about the traffic is wrong: every request is still
// answered, with the right opcode, the right data and the right TxnID, so no
// other checker in the bench can see the fault. If the ordering check does not
// fire here, it is a no-op everywhere.
//
// The inversion is one-shot, so the expected count is exactly one: a check that
// fired on every subsequent transaction would be cascading rather than
// pinpointing, and this asserts on the precise number.

class tc_chi_ordered_stream_negctl extends chi_base_test;

  `uvm_component_utils(tc_chi_ordered_stream_negctl)

  localparam int            N_C         = 6;
  localparam item_t::addr_t BASE_ADDR_C = item_t::addr_t'(44'h3C00_0000);
  localparam bit [2:0]      SIZE_C      = 3'd6;   // 64 B = 4 beats on the CHI-D cut
  localparam int            SETTLE_C    = 20;

  chi_order_negctl_catcher order_catcher;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // Arm the inversion on the completer. multi_outstanding on both ends is what
  // gives the SN-F two queued requests to invert in the first place.
  // ---------------------------------------------------------------------------
  protected virtual function void configure_agent_cfgs();

    super.configure_agent_cfgs();

    super.rni_cfg.multi_outstanding    = 1'b1;
    super.rni_cfg.max_outstanding_read = N_C;
    super.snf_cfg.multi_outstanding    = 1'b1;
    super.snf_cfg.snf_reorder_ordered_service = 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Create the report catcher once topology is ready.
  // ---------------------------------------------------------------------------
  function void start_of_simulation_phase(input uvm_phase phase);

    super.start_of_simulation_phase(phase);

    this.order_catcher = new("chi_order_negctl_catcher");
  endfunction

  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t rd_rsp [$];
    int    peak;

    phase.raise_objection(this);

    uvm_report_cb::add(null, this.order_catcher);

    super.rni0_rd_seq.reset();
    super.rni0_rd_seq.set_requests(N_C);
    super.rni0_rd_seq.set_initial_addr(BASE_ADDR_C);
    super.rni0_rd_seq.set_size(SIZE_C);
    super.rni0_rd_seq.set_order(VIP_CHI_ORDER_REQ_ORDER_E);
    super.rni0_rd_seq.set_allow_retry(1'b0);
    super.rni0_rd_seq.set_get_response(1'b1);
    super.rni0_rd_seq.set_pipelined_send(1'b1);
    super.rni0_rd_seq.set_verbose(1'b0);
    super.rni0_rd_seq.start(super.v_sqr.rni_sequencer);

    peak   = super.rni_cfg.observed_peak_outstanding;
    rd_rsp = super.rni0_rd_seq.get_responses();

    super.wait_clocks(SETTLE_C);

    uvm_report_cb::delete(null, this.order_catcher);

    // Every read must still have completed: the injected fault is an ordering
    // fault only, and a test that also broke completion would no longer isolate
    // the check under examination.
    if (rd_rsp.size() != N_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Expected %0d read responses, got %0d - the reorder knob was meant to change the order, not lose a transaction",
        super.tc_name, N_C, rd_rsp.size()))
    end

    if (peak <= 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Reads did not overlap: peak in-flight was %0d, so the completer never held two requests to invert",
        super.tc_name, peak))
    end

    if (!this.order_catcher.saw_order_error) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Scoreboard did NOT flag the inverted acknowledgement order - the ordered-stream check may be vacuous",
        super.tc_name))
    end

    if (super.tb_env.scoreboard.get_order_violation_count() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Ordered-stream check reported %0d violations for one injected inversion, expected exactly 1 - it is cascading rather than pinpointing",
        super.tc_name, super.tb_env.scoreboard.get_order_violation_count()))
    end

    // The rest of the stream must still have been compared and found in order,
    // which is what shows the check recovers from an inversion instead of
    // derailing on it.
    if (super.tb_env.scoreboard.get_order_checked_count() < (N_C - 1)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Only %0d acknowledgements were compared in order after the inversion, expected at least %0d",
        super.tc_name, super.tb_env.scoreboard.get_order_checked_count(), N_C - 1))
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] Inverted acknowledgement flagged exactly once; %0d further acknowledgements compared in order (negative control passed)",
      super.tc_name, super.tb_env.scoreboard.get_order_checked_count()), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
