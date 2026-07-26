class tc_chi_d_derr_smoke extends chi_base_test;

  `uvm_component_utils(tc_chi_d_derr_smoke)

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

    super.snf_cfg.derr_ranges = new[1];
    super.snf_cfg.derr_ranges[0].base  = DERR_ADDR_C;
    super.snf_cfg.derr_ranges[0].limit = DERR_ADDR_C + 44'h3F;
  endfunction

  // ---------------------------------------------------------------------------
  // Verify DERR-marked read data after priming the backing store with a write.
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t                          dat_item;
    item_t                          write_responses[$];
    item_t                          read_responses[$];

    phase.raise_objection(this);

    super.rni0_wr_seq.reset();
    super.rni0_wr_seq.set_requests(1);
    super.rni0_wr_seq.set_initial_addr(DERR_ADDR_C);
    super.rni0_wr_seq.set_size(3'd6);
    super.rni0_wr_seq.set_allow_retry(1'b0);
    super.rni0_wr_seq.set_data_type(VIP_CHI_DATA_COUNTER_E);
    super.rni0_wr_seq.set_counter_value(item_t::data_t'('h70));
    super.rni0_wr_seq.set_counter_increment(item_t::data_t'('h1));
    super.rni0_wr_seq.set_get_response(1'b1);
    super.rni0_wr_seq.set_verbose(1'b0);
    super.rni0_wr_seq.start(super.v_sqr.rni_sequencer);

    super.rni0_rd_seq.reset();
    super.rni0_rd_seq.set_requests(1);
    super.rni0_rd_seq.set_initial_addr(DERR_ADDR_C);
    super.rni0_rd_seq.set_size(3'd6);
    super.rni0_rd_seq.set_allow_retry(1'b0);
    super.rni0_rd_seq.set_get_response(1'b1);
    super.rni0_rd_seq.set_verbose(1'b0);
    super.rni0_rd_seq.start(super.v_sqr.rni_sequencer);

    write_responses = super.rni0_wr_seq.get_responses();
    read_responses  = super.rni0_rd_seq.get_responses();
    super.tb_env.rni_dat_fifo.get(dat_item);
    super.tb_env.rni_dat_fifo.get(dat_item);

    if ((write_responses.size() != 1) || (read_responses.size() != 1)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Expected one write and one read response, got %0d and %0d",
        super.tc_name, write_responses.size(), read_responses.size()))
    end

    if (write_responses[0].rsp_resp_err != VIP_CHI_RESP_ERR_NORMAL_OKAY_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Priming write response was 0x%0h instead of NormalOkay",
        super.tc_name, write_responses[0].rsp_resp_err))
    end

    if (read_responses[0].rsp_resp_err != VIP_CHI_RESP_ERR_DERR_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Read DERR response was 0x%0h instead of DERR",
        super.tc_name, read_responses[0].rsp_resp_err))
    end

    foreach (read_responses[0].data[i]) begin
      if (read_responses[0].dat_resp_err[i] != VIP_CHI_RESP_ERR_DERR_C) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] Read DERR dat_resp_err[%0d] was 0x%0h instead of DERR",
          super.tc_name, i, read_responses[0].dat_resp_err[i]))
      end
      if (read_responses[0].data[i] != (item_t::data_t'('h70) + item_t::data_t'(i))) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] Read DERR data[%0d] mismatch 0x%0h",
          super.tc_name, i, read_responses[0].data[i]))
      end
    end

    if (dat_item.role != VIP_CHI_ROLE_SNF_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Monitor DERR DAT role was %0d instead of SN-F",
        super.tc_name, dat_item.role))
    end

    foreach (dat_item.dat_resp_err[i]) begin
      if (dat_item.dat_resp_err[i] != VIP_CHI_RESP_ERR_DERR_C) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] Monitor DERR dat_resp_err[%0d] was 0x%0h instead of DERR",
          super.tc_name, i, dat_item.dat_resp_err[i]))
      end
    end

    phase.drop_objection(this);
  endtask
endclass