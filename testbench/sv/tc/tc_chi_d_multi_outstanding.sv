class tc_chi_d_multi_outstanding extends chi_base_test;

  `uvm_component_utils(tc_chi_d_multi_outstanding)

  // Enough reads that several are in flight before the first completes.
  localparam int            N_READS_C      = 6;
  localparam item_t::addr_t MO_BASE_ADDR_C = item_t::addr_t'(44'h2200_0000);

  // size 6 => 64 bytes => 4 beats at 16 bytes/beat for the CHI-D cut.
  localparam bit [2:0]      READ_SIZE_C    = 3'd6;
  localparam int            BEATS_C        = 4;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // Turn on the opt-in multi-outstanding datapath for the point-to-point RN-I
  // and SN-F. Left off, every other test keeps the strict serial path.
  // ---------------------------------------------------------------------------
  // ---------------------------------------------------------------------------
  // Configure Agent Cfgs
  // ---------------------------------------------------------------------------
  protected virtual function void configure_agent_cfgs();

    super.rni_cfg.multi_outstanding    = 1'b1;
    super.rni_cfg.max_outstanding_read = N_READS_C;
    super.snf_cfg.multi_outstanding    = 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Launch N pipelined reads, confirm each returns its own address-derived
  // payload, and confirm the reads actually overlapped in flight.
  // ---------------------------------------------------------------------------
  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t responses[$];
    item_t rsp;

    phase.raise_objection(this);

    super.rni0_rd_seq.reset();
    super.rni0_rd_seq.set_requests(N_READS_C);
    super.rni0_rd_seq.set_initial_addr(MO_BASE_ADDR_C);
    super.rni0_rd_seq.set_size(READ_SIZE_C);
    super.rni0_rd_seq.set_get_response(1'b1);
    super.rni0_rd_seq.set_pipelined_send(1'b1);
    super.rni0_rd_seq.set_verbose(1'b0);
    super.rni0_rd_seq.start(super.v_sqr.rni_sequencer);

    responses = super.rni0_rd_seq.get_responses();

    if (responses.size() != N_READS_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Expected %0d read responses, got %0d",
        super.tc_name, N_READS_C, responses.size()))
    end

    foreach (responses[k]) begin
      rsp = responses[k];

      if (rsp.role != VIP_CHI_ROLE_SNF_E) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] Read %0d response carried wrong role %0d",
          super.tc_name, k, rsp.role))
      end

      if (rsp.dat_opcode != item_t::dat_opcode_t'(VIP_CHI_DAT_COMP_DATA_C)) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] Read %0d response carried wrong DAT opcode 0x%0h",
          super.tc_name, k, rsp.dat_opcode))
      end

      if (rsp.data.size() != BEATS_C) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] Read %0d response carried %0d beats instead of %0d",
          super.tc_name, k, rsp.data.size(), BEATS_C))
      end

      // Each response self-describes its request address, so the payload check
      // holds regardless of the order responses are collected in.
      foreach (rsp.data[i]) begin
        if (rsp.data[i] != (item_t::data_t'(rsp.addr) + item_t::data_t'(i))) begin
          `uvm_fatal(get_name(), $sformatf(
            "FATAL [%s] Read %0d beat %0d payload mismatch 0x%0h (addr 0x%0h)",
            super.tc_name, k, i, rsp.data[i], rsp.addr))
        end
      end
    end

    // The whole point of P4: the reads must have been simultaneously in flight,
    // not merely completed one after another.
    if (super.rni_cfg.observed_peak_outstanding <= 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Reads did not overlap: peak in-flight was %0d (expected > 1)",
        super.tc_name, super.rni_cfg.observed_peak_outstanding))
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] %0d pipelined reads completed; peak in-flight = %0d",
      super.tc_name, N_READS_C, super.rni_cfg.observed_peak_outstanding), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
