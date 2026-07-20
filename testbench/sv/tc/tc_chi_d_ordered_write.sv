class tc_chi_d_ordered_write extends vip_chi_base_test;

  `uvm_component_utils(tc_chi_d_ordered_write)

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // Verify ordered writes return CompDBIDResp first and CompAck afterward.
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t req_item;
    item_t dat_item;
    item_t rsp_items[$];
    item_t write_responses[$];

    phase.raise_objection(this);

    super.rni0_wr_seq.reset();
    super.rni0_wr_seq.set_requests(1);
    super.rni0_wr_seq.set_initial_addr(WRITE_ADDR_C + item_t::addr_t'(44'h100));
    super.rni0_wr_seq.set_size(3'd6);
    super.rni0_wr_seq.set_allow_retry(1'b0);
    super.rni0_wr_seq.set_data_type(VIP_CHI_DATA_COUNTER_E);
    super.rni0_wr_seq.set_counter_value(item_t::data_t'('h20));
    super.rni0_wr_seq.set_counter_increment(item_t::data_t'('h1));
    super.rni0_wr_seq.set_exp_comp_ack(1'b1);
    super.rni0_wr_seq.set_get_response(1'b1);
    super.rni0_wr_seq.set_verbose(1'b0);
    super.rni0_wr_seq.start(super.v_sqr.rni_sequencer);

    write_responses = super.rni0_wr_seq.get_responses();
    if (write_responses.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Expected 1 ordered-write response, got %0d",
        super.tc_name, write_responses.size()))
    end

    super.tb_env.rni_req_fifo.get(req_item);
    super.tb_env.rni_dat_fifo.get(dat_item);
    repeat (2) begin
      item_t rsp_item;
      super.tb_env.rni_rsp_fifo.get(rsp_item);
      rsp_items.push_back(rsp_item);
    end

    if (req_item.exp_comp_ack != 1'b1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Ordered write REQ did not carry ExpCompAck",
        super.tc_name))
    end

    if (dat_item.dat_opcode != item_t::dat_opcode_t'(VIP_CHI_DAT_NCB_WR_DATA_COMP_ACK_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Ordered write DAT opcode 0x%0h was not NCBWrDataCompAck",
        super.tc_name, dat_item.dat_opcode))
    end

    if (rsp_items[0].role != VIP_CHI_ROLE_SNF_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] First ordered-write RSP role was %0d instead of SN-F",
        super.tc_name, rsp_items[0].role))
    end

    if (rsp_items[0].rsp_opcode != item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_DBID_RESP_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] First ordered-write RSP opcode 0x%0h was not CompDBIDResp",
        super.tc_name, rsp_items[0].rsp_opcode))
    end

    if (rsp_items[0].dbid != req_item.txn_id) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Ordered-write DBID 0x%0h did not match REQ txn_id 0x%0h",
        super.tc_name, rsp_items[0].dbid, req_item.txn_id))
    end

    if (rsp_items[1].role != VIP_CHI_ROLE_RNI_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Second ordered-write RSP role was %0d instead of RN-I",
        super.tc_name, rsp_items[1].role))
    end

    if (rsp_items[1].rsp_opcode != item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_ACK_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Second ordered-write RSP opcode 0x%0h was not CompAck",
        super.tc_name, rsp_items[1].rsp_opcode))
    end

    if (rsp_items[1].txn_id != req_item.txn_id) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] CompAck txn_id 0x%0h did not match REQ txn_id 0x%0h",
        super.tc_name, rsp_items[1].txn_id, req_item.txn_id))
    end

    if (write_responses[0].rsp_opcode != item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_DBID_RESP_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Ordered-write sequence response opcode 0x%0h was not CompDBIDResp",
        super.tc_name, write_responses[0].rsp_opcode))
    end

    phase.drop_objection(this);
  endtask
endclass