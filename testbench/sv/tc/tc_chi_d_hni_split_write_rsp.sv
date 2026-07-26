class tc_chi_d_hni_split_write_rsp extends chi_base_test;

  `uvm_component_utils(tc_chi_d_hni_split_write_rsp)

  localparam int            N_C         = 3;
  localparam item_t::addr_t BASE_ADDR_C = item_t::addr_t'(44'h2C00_0000);
  localparam bit [2:0]      SIZE_C      = 3'd6;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // Configure Agent Cfgs
  //
  // Let the requester attempt to pipeline writes, and put both SN-F targets behind
  // the proxy in split-response mode. The HN-I itself must still serialize each RN
  // port until the deferred Comp has crossed back to the requester.
  // ---------------------------------------------------------------------------
  protected virtual function void configure_agent_cfgs();

    super.hrni0_cfg.multi_outstanding       = 1'b1;
    super.hrni0_cfg.multi_outstanding_write = 1'b1;
    super.hrni0_cfg.max_outstanding_write   = N_C;

    super.hsnf0_cfg.multi_outstanding = 1'b1;
    super.hsnf1_cfg.multi_outstanding = 1'b1;
    super.hsnf0_cfg.split_write_rsp   = 1'b1;
    super.hsnf1_cfg.split_write_rsp   = 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Run Phase
  //
  // Pipeline several writes through the HN-I. A buggy proxy returned the RN-facing
  // REQ credit at the final write DAT beat, before the split Comp, allowing the
  // RN-I driver to observe >1 in flight. The fixed proxy releases the credit only
  // after both DAT and Comp have crossed, so the requester peak remains one.
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t wr_rsp[$];
    item_t rd_rsp[$];
    item_t snf_req;

    phase.raise_objection(this);

    super.rni0_wr_seq.reset();
    super.rni0_wr_seq.set_requests(N_C);
    super.rni0_wr_seq.set_initial_addr(BASE_ADDR_C);
    super.rni0_wr_seq.set_size(SIZE_C);
    super.rni0_wr_seq.set_allow_retry(1'b0);
    super.rni0_wr_seq.set_data_type(VIP_CHI_DATA_COUNTER_E);
    super.rni0_wr_seq.set_counter_value(item_t::data_t'('hc0));
    super.rni0_wr_seq.set_counter_increment(item_t::data_t'('h1));
    super.rni0_wr_seq.set_get_response(1'b1);
    super.rni0_wr_seq.set_pipelined_send(1'b1);
    super.rni0_wr_seq.set_verbose(1'b0);
    super.rni0_wr_seq.start(super.v_sqr.hrni0_sequencer);

    wr_rsp = super.rni0_wr_seq.get_responses();
    if (wr_rsp.size() != N_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Expected %0d proxied split-write completions, got %0d",
        super.tc_name, N_C, wr_rsp.size()))
    end

    foreach (wr_rsp[i]) begin
      if (wr_rsp[i].rsp_opcode != item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_C)) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] Proxied split write %0d returned opcode 0x%0h instead of deferred Comp",
          super.tc_name, i, wr_rsp[i].rsp_opcode))
      end
    end

    if (super.hrni0_cfg.observed_peak_outstanding != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] HN-I returned RN REQ credit before split write completion: peak in-flight %0d",
        super.tc_name, super.hrni0_cfg.observed_peak_outstanding))
    end

    repeat (N_C) begin
      super.tb_env.hsnf0_req_fifo.get(snf_req);
      if (snf_req.opcode != item_t::req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_FULL_C)) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] SN-F observed opcode 0x%0h instead of forwarded WriteNoSnpFull",
          super.tc_name, snf_req.opcode))
      end
    end

    super.rni0_rd_seq.reset();
    super.rni0_rd_seq.set_requests(N_C);
    super.rni0_rd_seq.set_initial_addr(BASE_ADDR_C);
    super.rni0_rd_seq.set_size(SIZE_C);
    super.rni0_rd_seq.set_allow_retry(1'b0);
    super.rni0_rd_seq.set_get_response(1'b1);
    super.rni0_rd_seq.set_pipelined_send(1'b1);
    super.rni0_rd_seq.set_verbose(1'b0);
    super.rni0_rd_seq.start(super.v_sqr.hrni0_sequencer);

    rd_rsp = super.rni0_rd_seq.get_responses();
    if (rd_rsp.size() != N_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Expected %0d proxied readback completions, got %0d",
        super.tc_name, N_C, rd_rsp.size()))
    end

    foreach (rd_rsp[i]) begin
      if (rd_rsp[i].dat_opcode != item_t::dat_opcode_t'(VIP_CHI_DAT_COMP_DATA_C)) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] Proxied readback %0d returned DAT opcode 0x%0h instead of CompData",
          super.tc_name, i, rd_rsp[i].dat_opcode))
      end
      if (rd_rsp[i].data.size() != 4) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] Proxied readback %0d returned %0d beats instead of 4",
          super.tc_name, i, rd_rsp[i].data.size()))
      end
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] HN-I split writes held RN REQ credit until deferred Comp",
      super.tc_name), UVM_LOW)

    phase.drop_objection(this);
  endtask
endclass
