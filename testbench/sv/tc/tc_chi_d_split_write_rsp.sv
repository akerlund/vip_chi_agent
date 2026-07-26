class tc_chi_d_split_write_rsp extends chi_base_test;

  `uvm_component_utils(tc_chi_d_split_write_rsp)

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // Enable the split DBIDResp + deferred Comp policy on the autonomous SN-F.
  // ---------------------------------------------------------------------------
  function void build_phase(input uvm_phase phase);

    super.build_phase(phase);

    super.snf_cfg.split_write_rsp = 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Run one split-write case and verify the observed response ordering.
  // ---------------------------------------------------------------------------
  protected task run_split_case(
    input logic          exp_comp_ack,
    input item_t::addr_t addr
  );

    item_t rsp_items[$];
    item_t req_item;
    item_t dat_item;
    item_t write_responses[$];
    int    expected_rsp_count;

    super.rni0_wr_seq.reset();
    super.rni0_wr_seq.set_requests(1);
    super.rni0_wr_seq.set_initial_addr(addr);
    super.rni0_wr_seq.set_size(3'd6);
    super.rni0_wr_seq.set_allow_retry(1'b0);
    super.rni0_wr_seq.set_data_type(VIP_CHI_DATA_COUNTER_E);
    super.rni0_wr_seq.set_counter_value(item_t::data_t'(exp_comp_ack ? 'h70 : 'h40));
    super.rni0_wr_seq.set_counter_increment(item_t::data_t'('h1));
    super.rni0_wr_seq.set_exp_comp_ack(exp_comp_ack);
    super.rni0_wr_seq.set_get_response(1'b1);
    super.rni0_wr_seq.set_verbose(1'b0);
    super.rni0_wr_seq.start(super.v_sqr.rni_sequencer);

    write_responses = super.rni0_wr_seq.get_responses();
    if (write_responses.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Expected 1 split-write response, got %0d",
        super.tc_name, write_responses.size()))
    end

    super.tb_env.rni_req_fifo.get(req_item);
    super.tb_env.rni_dat_fifo.get(dat_item);

    expected_rsp_count = exp_comp_ack ? 3 : 2;
    repeat (expected_rsp_count) begin
      item_t rsp_item;
      super.tb_env.rni_rsp_fifo.get(rsp_item);
      rsp_items.push_back(rsp_item);
    end

    if (rsp_items[0].role != VIP_CHI_ROLE_SNF_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] First split-write RSP role was %0d instead of SN-F",
        super.tc_name, rsp_items[0].role))
    end

    if (rsp_items[0].rsp_opcode != item_t::rsp_opcode_t'(VIP_CHI_RSP_DBID_RESP_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] First split-write RSP opcode 0x%0h was not DBIDResp",
        super.tc_name, rsp_items[0].rsp_opcode))
    end

    if (rsp_items[1].role != VIP_CHI_ROLE_SNF_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Second split-write RSP role was %0d instead of SN-F",
        super.tc_name, rsp_items[1].role))
    end

    if (rsp_items[1].rsp_opcode != item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Second split-write RSP opcode 0x%0h was not deferred Comp",
        super.tc_name, rsp_items[1].rsp_opcode))
    end

    if (rsp_items[0].dbid != req_item.txn_id) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] DBIDResp dbid 0x%0h did not match REQ txn_id 0x%0h",
        super.tc_name, rsp_items[0].dbid, req_item.txn_id))
    end

    if (write_responses[0].rsp_opcode != item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Split-write sequence response opcode 0x%0h was not deferred Comp",
        super.tc_name, write_responses[0].rsp_opcode))
    end

    if (write_responses[0].dbid != req_item.txn_id) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Split-write sequence response dbid 0x%0h did not match REQ txn_id 0x%0h",
        super.tc_name, write_responses[0].dbid, req_item.txn_id))
    end

    if (exp_comp_ack) begin
      if (dat_item.dat_opcode != item_t::dat_opcode_t'(VIP_CHI_DAT_NCB_WR_DATA_COMP_ACK_C)) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] Ordered split-write DAT opcode 0x%0h was not NCBWrDataCompAck",
          super.tc_name, dat_item.dat_opcode))
      end
      if (rsp_items[2].rsp_opcode != item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_ACK_C)) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] Third split-write RSP opcode 0x%0h was not CompAck",
          super.tc_name, rsp_items[2].rsp_opcode))
      end
      if (rsp_items[2].role != VIP_CHI_ROLE_RNI_E) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] Third split-write RSP role was %0d instead of RN-I",
          super.tc_name, rsp_items[2].role))
      end
    end
    else begin
      if (dat_item.dat_opcode != item_t::dat_opcode_t'(VIP_CHI_DAT_NON_COPY_BACK_WR_DATA_C)) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] Split-write DAT opcode 0x%0h was not NCBWrData",
          super.tc_name, dat_item.dat_opcode))
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  // Verify both split-write variants: plain DBIDResp+Comp and ordered write
  // with the later CompAck.
  // ---------------------------------------------------------------------------
  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    phase.raise_objection(this);

    this.run_split_case(1'b0, WRITE_ADDR_C + item_t::addr_t'(44'h200));
    this.run_split_case(1'b1, WRITE_ADDR_C + item_t::addr_t'(44'h300));

    phase.drop_objection(this);
  endtask
endclass