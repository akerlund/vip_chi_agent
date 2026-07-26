// ===========================================================================
// tc_chi_d_perf_smoke
//
// Anti-vacuity guard for the always-on vip_chi_perf_counters component. Drives a
// write then a read through the integrated RN-I/SN-F path with perf enabled, then
// fails (uvm_fatal) unless the perf component actually observed traffic and its
// deterministic time source ticked: read/write completion counts, per-class
// latency sums, and the cycle counter must all be non-zero. This proves the perf
// component is wired to the monitor stream and its clock loop is running -- so a
// future regression that silently disconnects it (or stalls its vif) is caught.
// ===========================================================================
class tc_chi_d_perf_smoke extends chi_base_test;

  `uvm_component_utils(tc_chi_d_perf_smoke)

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // Perf counters default on; make the dependency explicit for this test.
  // ---------------------------------------------------------------------------
  protected virtual function void configure_tb_cfg();

    super.tb_cfg.perf_enable = 1'b1;

  endfunction

  // ---------------------------------------------------------------------------
  // Drive one write + one read, then assert the perf counters are non-vacuous.
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t write_responses[$];
    item_t read_responses[$];

    phase.raise_objection(this);

    super.rni0_wr_seq.reset();
    super.rni0_wr_seq.set_requests(1);
    super.rni0_wr_seq.set_initial_addr(WRITE_READ_ADDR_C);
    super.rni0_wr_seq.set_size(3'd6);
    super.rni0_wr_seq.set_allow_retry(1'b0);
    super.rni0_wr_seq.set_data_type(VIP_CHI_DATA_COUNTER_E);
    super.rni0_wr_seq.set_counter_value(item_t::data_t'('h90));
    super.rni0_wr_seq.set_counter_increment(item_t::data_t'('h1));
    super.rni0_wr_seq.set_get_response(1'b1);
    super.rni0_wr_seq.set_verbose(1'b0);
    super.rni0_wr_seq.start(super.v_sqr.rni_sequencer);

    super.rni0_rd_seq.reset();
    super.rni0_rd_seq.set_requests(1);
    super.rni0_rd_seq.set_initial_addr(WRITE_READ_ADDR_C);
    super.rni0_rd_seq.set_size(3'd6);
    super.rni0_rd_seq.set_allow_retry(1'b0);
    super.rni0_rd_seq.set_get_response(1'b1);
    super.rni0_rd_seq.set_verbose(1'b0);
    super.rni0_rd_seq.start(super.v_sqr.rni_sequencer);

    write_responses = super.rni0_wr_seq.get_responses();
    read_responses  = super.rni0_rd_seq.get_responses();

    if ((write_responses.size() != 1) || (read_responses.size() != 1)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Expected 1 write + 1 read response, got %0d/%0d",
        super.tc_name, write_responses.size(), read_responses.size()))
    end

    // Let the perf clock loop advance a few cycles past the last completion.
    super.wait_clocks(8);

    if (super.tb_env.perf.get_cycle_count() == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Perf cycle counter never ticked (time source dead)",
        super.tc_name))
    end

    if (super.tb_env.perf.get_read_count() == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Perf observed 0 read completions", super.tc_name))
    end

    if (super.tb_env.perf.get_write_count() == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Perf observed 0 write completions", super.tc_name))
    end

    if (super.tb_env.perf.get_read_lat_sum() == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Perf read latency sum is zero (latency path not measuring)",
        super.tc_name))
    end

    if (super.tb_env.perf.get_write_lat_sum() == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Perf write latency sum is zero (latency path not measuring)",
        super.tc_name))
    end

    phase.drop_objection(this);
  endtask
endclass
