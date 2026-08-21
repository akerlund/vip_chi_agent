// Transaction recording, checked for the two things that can actually be wrong
// with it rather than for "it did not crash".
//
// Recording is a debug aid, so the temptation is to smoke-test it by turning it
// on and seeing the run pass. That proves nothing: the calls are no-ops when the
// knob is off, and a recorder that opened every stream and closed none would
// also pass. The two failures that matter are both about the LIFECYCLE:
//
//   * a stream opened and never closed -- the leak. Every transaction that
//     completed must have had its stream closed, so the open-stream bookkeeping
//     must be EMPTY at the end of a run in which everything retired.
//   * a stream closed on the wrong object. end_tr must be called on the item
//     begin_tr opened, and the completion arrives as a different item on a
//     different channel, so the recorder holds the opening item. Counting opens
//     against closes is what catches a recorder that closed something else.
//
// Both are checked against the monitor's own bookkeeping rather than by reading
// the transaction database back, which is a simulator artefact this testbench
// has no portable way to query. The Python twin asserts the same bookkeeping so
// the two stay comparable; only this side actually produces the waveform stream,
// because pyUVM 4.0.1's recording backend is a stub.

class tc_chi_recording_smoke extends chi_base_test;

  `uvm_component_utils(tc_chi_recording_smoke)

  localparam item_t::addr_t ADDR_C   = item_t::addr_t'(44'h3E40_0000);
  localparam bit [2:0]      SIZE_C   = 3'd6;   // 64 B = 4 beats on the CHI-D cut
  localparam int            SETTLE_C = 20;
  localparam int            N_REQ_C  = 4;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // Recording is off everywhere else; this is the test that turns it on.
  // ---------------------------------------------------------------------------
  protected virtual function void configure_agent_cfgs();

    super.configure_agent_cfgs();

    super.rni_cfg.record_transactions = 1'b1;
    super.snf_cfg.record_transactions = 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    int unsigned opened;
    int unsigned closed;
    int unsigned still_open;

    phase.raise_objection(this);

    // A read and a write: they complete on different channels (DAT and RSP), and
    // the recorder closes the stream at each. Testing only one direction would
    // leave the other's close path unexercised.
    super.rni0_rd_seq.reset();
    super.rni0_rd_seq.set_requests(N_REQ_C);
    super.rni0_rd_seq.set_initial_addr(ADDR_C);
    super.rni0_rd_seq.set_size(SIZE_C);
    super.rni0_rd_seq.set_get_response(1'b1);
    super.rni0_rd_seq.set_verbose(1'b0);
    super.rni0_rd_seq.start(super.v_sqr.rni_sequencer);

    super.rni0_wr_seq.reset();
    super.rni0_wr_seq.set_requests(N_REQ_C);
    super.rni0_wr_seq.set_initial_addr(ADDR_C);
    super.rni0_wr_seq.set_size(SIZE_C);
    super.rni0_wr_seq.set_get_response(1'b1);
    super.rni0_wr_seq.set_verbose(1'b0);
    super.rni0_wr_seq.start(super.v_sqr.rni_sequencer);

    super.wait_clocks(SETTLE_C);

    opened     = super.tb_env.rni_agent.monitor.n_tr_opened;
    closed     = super.tb_env.rni_agent.monitor.n_tr_closed;
    still_open = super.tb_env.rni_agent.monitor.tr_still_open();

    // Something must actually have been recorded, or the assertions below hold
    // trivially on a recorder that never ran.
    if (opened < (2 * N_REQ_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the monitor opened %0d transaction stream(s) for %0d requests - recording is not running",
        super.tc_name, opened, 2 * N_REQ_C))
    end

    // Every stream that was opened must have been closed. This is the leak
    // check, and it is the one a passing run cannot otherwise show.
    if (still_open != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %0d transaction stream(s) were still open after every transaction completed - end_tr is not being reached",
        super.tc_name, still_open))
    end

    if (opened != closed) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] opened %0d stream(s) but closed %0d",
        super.tc_name, opened, closed))
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] %0d stream(s) opened and all %0d closed, none left open",
      super.tc_name, opened, closed), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
