// Per-transaction timestamps on the observed item. The monitor stamps each
// milestone from its reset-gated free-running cycle counter, so a consumer of
// the analysis stream can ask what a single transaction cost instead of reading
// one aggregate number at the end of the run.
//
// What this pins down:
//   * the milestones are populated at all, and 0 still means "not reached";
//   * they are MONOTONIC -- a request cannot be granted before it was issued,
//     nor its last beat arrive before its first;
//   * latency() agrees with the perf counters' independently-derived aggregate.
//     Two measurements of the same interval that disagree mean one of them is
//     wrong, and that is exactly what a single aggregate number cannot reveal.

class tc_chi_item_timestamps extends chi_base_test;

  `uvm_component_utils(tc_chi_item_timestamps)

  localparam item_t::addr_t ADDR_C = item_t::addr_t'(44'h3D00_0000);
  localparam bit [2:0]      SIZE_C = 3'd6;   // 64 B = 4 beats on the CHI-D cut

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

    item_t            dat_item;
    item_t            read_dat;
    longint unsigned  perf_read_lat;

    phase.raise_objection(this);

    // -- A write, then a read of the same line. -------------------------------
    super.rni0_wr_seq.reset();
    super.rni0_wr_seq.set_requests(1);
    super.rni0_wr_seq.set_initial_addr(ADDR_C);
    super.rni0_wr_seq.set_size(SIZE_C);
    super.rni0_wr_seq.set_get_response(1'b1);
    super.rni0_wr_seq.set_verbose(1'b0);
    super.rni0_wr_seq.start(super.v_sqr.rni_sequencer);

    super.rni0_rd_seq.reset();
    super.rni0_rd_seq.set_requests(1);
    super.rni0_rd_seq.set_initial_addr(ADDR_C);
    super.rni0_rd_seq.set_size(SIZE_C);
    super.rni0_rd_seq.set_get_response(1'b1);
    super.rni0_rd_seq.set_verbose(1'b0);
    super.rni0_rd_seq.start(super.v_sqr.rni_sequencer);

    super.wait_clocks(20);

    // The timestamps ride the monitor's analysis stream, so they are read off
    // the observed items rather than off the driver's response object.
    read_dat = null;
    while (super.tb_env.rni_dat_fifo.try_get(dat_item)) begin
      if (dat_item.dat_opcode == item_t::dat_opcode_t'(VIP_CHI_DAT_COMP_DATA_C)) begin
        read_dat = dat_item;
      end
    end

    if (read_dat == null) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] no CompData was observed for the read", super.tc_name))
    end

    // -- Milestones present. --------------------------------------------------
    if (read_dat.t_req_issued == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] t_req_issued is 0 on an observed read - the REQ milestone was never stamped, or the stamp did not travel to the completion item",
        super.tc_name))
    end

    if ((read_dat.t_first_dat == 0) || (read_dat.t_last_dat == 0)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] data milestones missing: t_first_dat=%0d t_last_dat=%0d",
        super.tc_name, read_dat.t_first_dat, read_dat.t_last_dat))
    end

    // -- Monotonic. -----------------------------------------------------------
    if (read_dat.t_req_issued > read_dat.t_first_dat) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] read data arrived at cycle %0d, before its request was issued at %0d",
        super.tc_name, read_dat.t_first_dat, read_dat.t_req_issued))
    end

    if (read_dat.t_first_dat > read_dat.t_last_dat) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] read burst ended at %0d, before it began at %0d",
        super.tc_name, read_dat.t_last_dat, read_dat.t_first_dat))
    end

    // -- Accessors self-consistent. -------------------------------------------
    if (read_dat.latency() == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] read latency() returned 0 on a completed read", super.tc_name))
    end

    if (read_dat.data_burst_time() != (read_dat.t_last_dat - read_dat.t_first_dat)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] data_burst_time() disagrees with the beat milestones it is derived from",
        super.tc_name))
    end

    // -- Cross-check against the perf counters. -------------------------------
    // Both measure the same interval from the same cycle base but by entirely
    // separate paths, so agreement is real evidence and disagreement localizes
    // the bug to one of them.
    if (super.tb_env.perf.get_read_count() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] expected exactly 1 completed read for the cross-check, perf counted %0d",
        super.tc_name, super.tb_env.perf.get_read_count()))
    end

    perf_read_lat = super.tb_env.perf.get_read_lat_sum();
    if (read_dat.latency() != perf_read_lat) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] item latency() = %0d but the perf counters measured %0d for the same read - the two cycle bases disagree",
        super.tc_name, read_dat.latency(), perf_read_lat))
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] req=%0d first_dat=%0d last_dat=%0d latency=%0d burst=%0d (perf agrees at %0d)",
      super.tc_name, read_dat.t_req_issued, read_dat.t_first_dat,
      read_dat.t_last_dat, read_dat.latency(), read_dat.data_burst_time(),
      perf_read_lat), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
