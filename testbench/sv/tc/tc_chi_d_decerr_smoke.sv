class tc_chi_d_decerr_smoke extends chi_base_test;

  `uvm_component_utils(tc_chi_d_decerr_smoke)

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // Configure Agent Cfgs
  // ---------------------------------------------------------------------------
  protected function void configure_agent_cfgs();

    super.snf_cfg.decerr_ranges = new[1];
    super.snf_cfg.decerr_ranges[0].base  = DECERR_ADDR_C;
    super.snf_cfg.decerr_ranges[0].limit = DECERR_ADDR_C + 44'h3F;
  endfunction

  // ---------------------------------------------------------------------------
  // Verify DECERR handling for both write and read paths.
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t                          req_items[$];
    item_t                          write_dat_item;
    item_t                          rsp_item;
    item_t                          dat_item;
    item_t                          write_responses[$];
    item_t                          read_responses[$];
    int                             expected_beats;

    phase.raise_objection(this);

    super.rni0_wr_seq.reset();
    super.rni0_wr_seq.set_requests(1);
    super.rni0_wr_seq.set_initial_addr(DECERR_ADDR_C);
    super.rni0_wr_seq.set_size(3'd6);
    super.rni0_wr_seq.set_allow_retry(1'b0);
    super.rni0_wr_seq.set_data_type(VIP_CHI_DATA_COUNTER_E);
    super.rni0_wr_seq.set_counter_value(item_t::data_t'('h40));
    super.rni0_wr_seq.set_counter_increment(item_t::data_t'('h1));
    super.rni0_wr_seq.set_get_response(1'b1);
    super.rni0_wr_seq.set_verbose(1'b0);
    super.rni0_wr_seq.start(super.v_sqr.rni_sequencer);

    super.rni0_rd_seq.reset();
    super.rni0_rd_seq.set_requests(1);
    super.rni0_rd_seq.set_initial_addr(DECERR_ADDR_C);
    super.rni0_rd_seq.set_size(3'd6);
    super.rni0_rd_seq.set_allow_retry(1'b0);
    super.rni0_rd_seq.set_get_response(1'b1);
    super.rni0_rd_seq.set_verbose(1'b0);
    super.rni0_rd_seq.start(super.v_sqr.rni_sequencer);

    write_responses = super.rni0_wr_seq.get_responses();
    read_responses  = super.rni0_rd_seq.get_responses();
    expected_beats  = vip_chi_types_pkg::chi_xfer_dat_beats(item_t::size_t'(3'd6), CHI_D_CFG_C.DATA_BYTES_P);

    if ((write_responses.size() != 1) || (read_responses.size() != 1)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Expected one write and one read response, got %0d and %0d",
        super.tc_name, write_responses.size(), read_responses.size()))
    end

    repeat (2) begin
      item_t req_item;
      super.tb_env.rni_req_fifo.get(req_item);
      req_items.push_back(req_item);
    end

    super.tb_env.rni_rsp_fifo.get(rsp_item);
    super.tb_env.rni_dat_fifo.get(write_dat_item);
    super.tb_env.rni_dat_fifo.get(dat_item);

    if (write_dat_item.role != VIP_CHI_ROLE_RNI_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Expected RN-I write DAT item first, got role %0d",
        super.tc_name, write_dat_item.role))
    end

    if ((req_items[0].addr != DECERR_ADDR_C) || (req_items[1].addr != DECERR_ADDR_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] DECERR request address mismatch 0x%0h 0x%0h",
        super.tc_name, req_items[0].addr, req_items[1].addr))
    end

    if (write_responses[0].rsp_resp_err != VIP_CHI_RESP_ERR_NDERR_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Write DECERR response was 0x%0h instead of NDERR",
        super.tc_name, write_responses[0].rsp_resp_err))
    end

    if (rsp_item.rsp_resp_err != VIP_CHI_RESP_ERR_NDERR_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Monitor write DECERR response was 0x%0h instead of NDERR",
        super.tc_name, rsp_item.rsp_resp_err))
    end

    if (read_responses[0].rsp_resp_err != VIP_CHI_RESP_ERR_NDERR_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Read DECERR response was 0x%0h instead of NDERR",
        super.tc_name, read_responses[0].rsp_resp_err))
    end

    if (dat_item.dat_resp_err.size() != expected_beats) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] DECERR DAT beat count was %0d instead of %0d",
        super.tc_name, dat_item.dat_resp_err.size(), expected_beats))
    end

    foreach (dat_item.dat_resp_err[i]) begin
      if (dat_item.dat_resp_err[i] != VIP_CHI_RESP_ERR_NDERR_C) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] Monitor read DECERR dat_resp_err[%0d] was 0x%0h instead of NDERR",
          super.tc_name, i, dat_item.dat_resp_err[i]))
      end
      if (read_responses[0].dat_resp_err[i] != VIP_CHI_RESP_ERR_NDERR_C) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] Read DECERR dat_resp_err[%0d] was 0x%0h instead of NDERR",
          super.tc_name, i, read_responses[0].dat_resp_err[i]))
      end
      if ((dat_item.data[i] != '0) || (read_responses[0].data[i] != '0)) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] DECERR read beat %0d should carry zeroed payload placeholders",
          super.tc_name, i))
      end
    end

    phase.drop_objection(this);
  endtask
endclass