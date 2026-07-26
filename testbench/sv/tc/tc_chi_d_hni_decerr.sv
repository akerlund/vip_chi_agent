class tc_chi_d_hni_decerr extends chi_base_test;

  `uvm_component_utils(tc_chi_d_hni_decerr)

  // DECERR_ADDR_C (0x3000_A000) decodes to HN-I SN target 0 (address bit 12 = 0).

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // Mark the target address as a DECERR region on SN target 0.

  // ---------------------------------------------------------------------------
  // Configure Agent Cfgs
  // ---------------------------------------------------------------------------
  protected function void configure_agent_cfgs();

    super.hsnf0_cfg.decerr_ranges = new[1];
    super.hsnf0_cfg.decerr_ranges[0].base  = DECERR_ADDR_C;
    super.hsnf0_cfg.decerr_ranges[0].limit = DECERR_ADDR_C + 44'h3F;
  endfunction

  // A write and a read to a DECERR address must have the SN-F's error response
  // relayed intact back through the HN-I proxy to the RN.

  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t write_responses[$];
    item_t read_responses[$];

    phase.raise_objection(this);

    super.rni0_wr_seq.reset();
    super.rni0_wr_seq.set_requests(1);
    super.rni0_wr_seq.set_initial_addr(DECERR_ADDR_C);
    super.rni0_wr_seq.set_size(3'd6);
    super.rni0_wr_seq.set_allow_retry(1'b0);
    super.rni0_wr_seq.set_data_type(VIP_CHI_DATA_COUNTER_E);
    super.rni0_wr_seq.set_counter_value(item_t::data_t'('h40));
    super.rni0_wr_seq.set_get_response(1'b1);
    super.rni0_wr_seq.start(super.v_sqr.hrni0_sequencer);

    super.rni0_rd_seq.reset();
    super.rni0_rd_seq.set_requests(1);
    super.rni0_rd_seq.set_initial_addr(DECERR_ADDR_C);
    super.rni0_rd_seq.set_size(3'd6);
    super.rni0_rd_seq.set_allow_retry(1'b0);
    super.rni0_rd_seq.set_get_response(1'b1);
    super.rni0_rd_seq.start(super.v_sqr.hrni0_sequencer);

    write_responses = super.rni0_wr_seq.get_responses();
    read_responses  = super.rni0_rd_seq.get_responses();

    if ((write_responses.size() != 1) || (read_responses.size() != 1)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Expected 1 write and 1 read response, got %0d and %0d",
        super.tc_name, write_responses.size(), read_responses.size()))
    end

    if (write_responses[0].rsp_resp_err != VIP_CHI_RESP_ERR_NDERR_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Proxied write DECERR response was 0x%0h, not NDERR",
        super.tc_name, write_responses[0].rsp_resp_err))
    end

    if (read_responses[0].rsp_resp_err != VIP_CHI_RESP_ERR_NDERR_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Proxied read DECERR response was 0x%0h, not NDERR",
        super.tc_name, read_responses[0].rsp_resp_err))
    end

    foreach (read_responses[0].dat_resp_err[i]) begin
      if (read_responses[0].dat_resp_err[i] != VIP_CHI_RESP_ERR_NDERR_C) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] Proxied read DECERR dat_resp_err[%0d] was 0x%0h, not NDERR",
          super.tc_name, i, read_responses[0].dat_resp_err[i]))
      end
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] HN-I relayed SN-F DECERR responses (write + read) intact",
      super.tc_name), UVM_LOW)

    phase.drop_objection(this);
  endtask
endclass
