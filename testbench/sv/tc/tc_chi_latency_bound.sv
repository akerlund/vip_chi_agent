// Per-transaction latency bounds. A test that cares about latency has to be able
// to FAIL on it, not read it out of a report after the run.
//
// Both halves, because a bound is only meaningful if it does both things:
//   * a generous bound must stay silent on ordinary traffic -- a check that
//     fires on everything is not a bound, it is noise;
//   * a bound tighter than the observed latency must fire, and the report must
//     name the measured value so the reader can see by how much.
//
// The bound is tightened rather than the completer slowed. Both produce the same
// comparison, but a fixed small bound is deterministic: a delay knob would leave
// the test asserting on a margin that depends on how the completer's delays
// happened to land.

class tc_chi_latency_bound extends chi_base_test;

  `uvm_component_utils(tc_chi_latency_bound)

  localparam item_t::addr_t ADDR_C     = item_t::addr_t'(44'h3E00_0000);
  localparam bit [2:0]      SIZE_C     = 3'd6;    // 64 B = 4 beats on the CHI-D cut
  localparam int unsigned   GENEROUS_C = 10000;   // far above anything this bench produces
  localparam int unsigned   TIGHT_C    = 1;       // below any real read

  chi_latency_negctl_catcher latency_catcher;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // Create the report catcher once topology is ready.
  // ---------------------------------------------------------------------------
  function void start_of_simulation_phase(input uvm_phase phase);

    super.start_of_simulation_phase(phase);

    this.latency_catcher = new("latency_negctl_catcher");
  endfunction

  // ---------------------------------------------------------------------------
  // One read of the shared address.
  // ---------------------------------------------------------------------------
  protected task one_read();

    super.rni0_rd_seq.reset();
    super.rni0_rd_seq.set_requests(1);
    super.rni0_rd_seq.set_initial_addr(ADDR_C);
    super.rni0_rd_seq.set_size(SIZE_C);
    super.rni0_rd_seq.set_get_response(1'b1);
    super.rni0_rd_seq.set_verbose(1'b0);
    super.rni0_rd_seq.start(super.v_sqr.rni_sequencer);
  endtask

  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    phase.raise_objection(this);

    // -- Generous bound: ordinary traffic must not trip it. -------------------
    super.tb_env.rni_agent.monitor.max_read_xact_latency = GENEROUS_C;
    this.one_read();
    super.wait_clocks(20);

    if (super.tb_env.rni_agent.monitor.n_latency_violation != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %0d latency violation(s) under a bound of %0d cycles - the check is firing on ordinary traffic",
        super.tc_name, super.tb_env.rni_agent.monitor.n_latency_violation, GENEROUS_C))
    end

    // -- Tight bound: the same traffic must trip it, exactly once. -------------
    uvm_report_cb::add(null, this.latency_catcher);

    super.tb_env.rni_agent.monitor.max_read_xact_latency = TIGHT_C;
    this.one_read();
    super.wait_clocks(20);

    uvm_report_cb::delete(null, this.latency_catcher);
    super.tb_env.rni_agent.monitor.max_read_xact_latency = 0;

    if (!this.latency_catcher.saw_latency_error) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] a read was not flagged against a bound of %0d cycle(s) - the latency check may be vacuous",
        super.tc_name, TIGHT_C))
    end

    if (this.latency_catcher.n_latency_errors != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] one over-budget read produced %0d reports, expected exactly 1",
        super.tc_name, this.latency_catcher.n_latency_errors))
    end

    if (super.tb_env.rni_agent.monitor.n_latency_violation != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the monitor's violation counter reads %0d, expected 1 - the counter and the report disagree",
        super.tc_name, super.tb_env.rni_agent.monitor.n_latency_violation))
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] silent at %0d cycles, flagged exactly once at %0d",
      super.tc_name, GENEROUS_C, TIGHT_C), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
