class tc_chi_d_write_read_smoke extends chi_base_test;

  `uvm_component_utils(tc_chi_d_write_read_smoke)

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // Verify a write followed by a readback through the integrated RN-I/SN-F path.
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t                          req_items[$];
    item_t                          dat_items[$];
    item_t                          write_responses[$];
    item_t                          read_responses[$];

    phase.raise_objection(this);

    super.rni0_wr_seq.reset();
    super.rni0_wr_seq.set_requests(1);
    super.rni0_wr_seq.set_initial_addr(WRITE_READ_ADDR_C);
    super.rni0_wr_seq.set_size(3'd6);
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
    super.rni0_rd_seq.set_get_response(1'b1);
    super.rni0_rd_seq.set_verbose(1'b0);
    super.rni0_rd_seq.start(super.v_sqr.rni_sequencer);

    write_responses = super.rni0_wr_seq.get_responses();
    read_responses  = super.rni0_rd_seq.get_responses();

    if (write_responses.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Expected 1 write response, got %0d",
        super.tc_name, write_responses.size()))
    end

    if (read_responses.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Expected 1 read response, got %0d",
        super.tc_name, read_responses.size()))
    end

    repeat (2) begin
      item_t req_item;
      super.tb_env.rni_req_fifo.get(req_item);
      req_items.push_back(req_item);
    end

    repeat (2) begin
      item_t dat_item;
      super.tb_env.rni_dat_fifo.get(dat_item);
      dat_items.push_back(dat_item);
    end

    if (req_items[0].opcode != item_t::req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_FULL_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] First request was not WriteNoSnpFull: 0x%0h",
        super.tc_name, req_items[0].opcode))
    end

    if (req_items[1].opcode != item_t::req_opcode_t'(VIP_CHI_REQ_READ_NO_SNP_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Second request was not ReadNoSnp: 0x%0h",
        super.tc_name, req_items[1].opcode))
    end

    if ((req_items[0].addr != WRITE_READ_ADDR_C) || (req_items[1].addr != WRITE_READ_ADDR_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Write/read address mismatch 0x%0h 0x%0h",
        super.tc_name, req_items[0].addr, req_items[1].addr))
    end

    if (dat_items[0].role != VIP_CHI_ROLE_RNI_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] First DAT item role was not RN-I: %0d",
        super.tc_name, dat_items[0].role))
    end

    if (dat_items[1].role != VIP_CHI_ROLE_SNF_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Second DAT item role was not SN-F: %0d",
        super.tc_name, dat_items[1].role))
    end

    if (dat_items[0].data.size() != 4) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Write DAT beat count was %0d instead of 4",
        super.tc_name, dat_items[0].data.size()))
    end

    if (dat_items[1].data.size() != dat_items[0].data.size()) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Read DAT beat count %0d does not match write DAT beat count %0d",
        super.tc_name, dat_items[1].data.size(), dat_items[0].data.size()))
    end

    if (write_responses[0].rsp_opcode != item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_DBID_RESP_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Write response carried wrong opcode 0x%0h",
        super.tc_name, write_responses[0].rsp_opcode))
    end

    if (read_responses[0].dat_opcode != item_t::dat_opcode_t'(VIP_CHI_DAT_COMP_DATA_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Read response carried wrong DAT opcode 0x%0h",
        super.tc_name, read_responses[0].dat_opcode))
    end

    // Read-back data integrity (read == observed write, full-width) is now
    // covered by the standalone scoreboard (checker C write->read predictor,
    // which compares every byte here - reads_skipped_unpredictable=0). This test
    // keeps only the write-payload pattern check that validates the sequence's
    // counter data-gen, which the scoreboard does not model.
    foreach (dat_items[0].data[i]) begin
      if (dat_items[0].data[i] != (item_t::data_t'('h90) + item_t::data_t'(i))) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] Write DAT beat %0d payload mismatch 0x%0h",
          super.tc_name, i, dat_items[0].data[i]))
      end
    end

    phase.drop_objection(this);
  endtask
endclass