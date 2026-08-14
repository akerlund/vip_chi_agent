// Ordered-stream acknowledgement order, the positive case. A source that sets
// the REQ Order field is asking the completer for a guarantee, and the completer
// must acknowledge the requests in the order it received them. This pipelines an
// ordered write stream and an ordered read stream deep enough that the completer
// holds several at once -- which is the only condition under which it could get
// the order wrong -- and requires the scoreboard to have compared every one of
// them and found none out of place.
//
// The in-order tally is asserted, not just the violation count: a run where the
// check never got to compare anything would otherwise look identical to a clean
// one. tc_chi_ordered_stream_negctl is the other half, proving the same check
// does fire when the completer answers out of order.

class tc_chi_ordered_stream extends chi_base_test;

  `uvm_component_utils(tc_chi_ordered_stream)

  localparam int            N_C         = 6;
  localparam item_t::addr_t BASE_ADDR_C = item_t::addr_t'(44'h3B00_0000);
  localparam bit [2:0]      SIZE_C      = 3'd6;   // 64 B = 4 beats on the CHI-D cut
  localparam int            SETTLE_C    = 20;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // Both ends have to overlap for the stream to have any depth: the RN-I must
  // keep several requests in flight and the SN-F must buffer them rather than
  // servicing each to completion before sampling the next.
  // ---------------------------------------------------------------------------
  protected virtual function void configure_agent_cfgs();

    super.configure_agent_cfgs();

    super.rni_cfg.multi_outstanding       = 1'b1;
    super.rni_cfg.multi_outstanding_write = 1'b1;
    super.rni_cfg.max_outstanding_read    = N_C;
    super.rni_cfg.max_outstanding_write   = N_C;
    super.snf_cfg.multi_outstanding       = 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    int wr_peak;
    int rd_peak;
    int acks;

    phase.raise_objection(this);

    // -- An ordered write stream: each write is acknowledged by its DBIDResp /
    //    CompDBIDResp, which is the flit the completer commits a position in.
    super.rni0_wr_seq.reset();
    super.rni0_wr_seq.set_requests(N_C);
    super.rni0_wr_seq.set_initial_addr(BASE_ADDR_C);
    super.rni0_wr_seq.set_size(SIZE_C);
    super.rni0_wr_seq.set_order(VIP_CHI_ORDER_REQ_ORDER_E);
    super.rni0_wr_seq.set_exp_comp_ack(1'b1);
    super.rni0_wr_seq.set_allow_retry(1'b0);
    super.rni0_wr_seq.set_get_response(1'b1);
    super.rni0_wr_seq.set_pipelined_send(1'b1);
    super.rni0_wr_seq.set_verbose(1'b0);
    super.rni0_wr_seq.start(super.v_sqr.rni_sequencer);

    wr_peak = super.rni_cfg.observed_peak_outstanding;

    super.wait_clocks(SETTLE_C);

    // -- An ordered read stream: each read is acknowledged by its ReadReceipt,
    //    which arrives on RSP ahead of the CompData burst on DAT.
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

    rd_peak = super.rni_cfg.observed_peak_outstanding;

    super.wait_clocks(SETTLE_C);

    // A stream one deep can never be out of order, so a run that never overlapped
    // proves nothing about the completer and must not be read as a pass.
    if ((wr_peak <= 1) || (rd_peak <= 1)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Ordered streams did not overlap: peak in-flight was %0d (writes) / %0d (reads), expected > 1 for both",
        super.tc_name, wr_peak, rd_peak))
    end

    acks = super.tb_env.scoreboard.get_order_checked_count();

    if (acks < (2 * N_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Ordered-stream check compared only %0d acknowledgements, expected at least %0d - the check did not see this traffic",
        super.tc_name, acks, 2 * N_C))
    end

    if (super.tb_env.scoreboard.get_order_violation_count() != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Ordered-stream check reported %0d out-of-order acknowledgement(s) on a completer that serves requests first-come-first-served",
        super.tc_name, super.tb_env.scoreboard.get_order_violation_count()))
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] %0d ordered writes + %0d ordered reads acknowledged in order (%0d compared; peak in-flight %0d / %0d)",
      super.tc_name, N_C, N_C, acks, wr_peak, rd_peak), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
