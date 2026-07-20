class tc_chi_d_ordered_read extends vip_chi_base_test;

  `uvm_component_utils(tc_chi_d_ordered_read)

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // Drive one ordered read and verify ReadReceipt precedes the returned data.
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t req_item;
    item_t receipt_item;
    item_t dat_item;
    item_t responses[$];
    item_t rsp_item;

    phase.raise_objection(this);

    super.rni0_rd_seq.reset();
    super.rni0_rd_seq.set_requests(1);
    super.rni0_rd_seq.set_initial_addr(READ_ADDR_C + item_t::addr_t'(44'h100));
    super.rni0_rd_seq.set_size(3'd6);
    super.rni0_rd_seq.set_order(VIP_CHI_ORDER_REQ_ORDER_E);
    super.rni0_rd_seq.set_allow_retry(1'b0);
    super.rni0_rd_seq.set_get_response(1'b1);
    super.rni0_rd_seq.set_verbose(1'b0);
    super.rni0_rd_seq.start(super.v_sqr.rni_sequencer);

    responses = super.rni0_rd_seq.get_responses();
    if (responses.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Expected 1 ordered-read response, got %0d",
        super.tc_name, responses.size()))
    end
    rsp_item = responses[0];

    super.tb_env.rni_req_fifo.get(req_item);
    super.tb_env.rni_rsp_fifo.get(receipt_item);
    super.tb_env.rni_dat_fifo.get(dat_item);

    if (req_item.opcode != item_t::req_opcode_t'(VIP_CHI_REQ_READ_NO_SNP_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Monitor observed wrong ordered-read REQ opcode 0x%0h",
        super.tc_name, req_item.opcode))
    end

    if (req_item.order != VIP_CHI_ORDER_REQ_ORDER_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Ordered-read REQ carried wrong Order value 0x%0h",
        super.tc_name, req_item.order))
    end

    if (receipt_item.role != VIP_CHI_ROLE_SNF_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] ReadReceipt carried wrong role %0d",
        super.tc_name, receipt_item.role))
    end

    if (receipt_item.rsp_opcode != item_t::rsp_opcode_t'(VIP_CHI_RSP_READ_RECEIPT_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Ordered-read RSP opcode 0x%0h was not ReadReceipt",
        super.tc_name, receipt_item.rsp_opcode))
    end

    if ((receipt_item.txn_id != req_item.txn_id) ||
        (receipt_item.src_id != req_item.tgt_id) ||
        (receipt_item.tgt_id != req_item.src_id)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] ReadReceipt routing fields did not match the ordered read request",
        super.tc_name))
    end

    if (dat_item.dat_opcode != item_t::dat_opcode_t'(VIP_CHI_DAT_COMP_DATA_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Ordered-read DAT opcode 0x%0h was not CompData",
        super.tc_name, dat_item.dat_opcode))
    end

    if ((rsp_item.txn_id != req_item.txn_id) ||
        (rsp_item.dbid != req_item.txn_id) ||
        (rsp_item.src_id != req_item.tgt_id) ||
        (rsp_item.tgt_id != req_item.src_id)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Ordered-read sequence response routing fields were incorrect",
        super.tc_name))
    end

    if (rsp_item.data.size() != dat_item.data.size()) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Ordered-read response beat count %0d did not match monitor beat count %0d",
        super.tc_name, rsp_item.data.size(), dat_item.data.size()))
    end

    if (rsp_item.data.size() == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Ordered-read returned zero data beats",
        super.tc_name))
    end

    foreach (rsp_item.data[i]) begin
      item_t::data_t expected_data;

      expected_data = item_t::data_t'(req_item.addr) + item_t::data_t'(i);
      if (rsp_item.data[i] != expected_data) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] Ordered-read response beat %0d payload mismatch 0x%0h",
          super.tc_name, i, rsp_item.data[i]))
      end
      if (dat_item.data[i] != expected_data) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] Ordered-read monitor beat %0d payload mismatch 0x%0h",
          super.tc_name, i, dat_item.data[i]))
      end
    end

    phase.drop_objection(this);
  endtask
endclass