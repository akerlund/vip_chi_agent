class tc_chi_e_dbid_resp_ord extends vip_chi_e_base_test;

  typedef vip_chi_item #(CHI_E_WIDE_CFG_C) item_t;

  `uvm_component_utils(tc_chi_e_dbid_resp_ord)

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // Match the real SN-F responder configuration required for DBIDRespOrd.
  // ---------------------------------------------------------------------------
  protected virtual function void configure_agent_cfgs();

    super.snf_cfg.split_write_rsp   = 1'b1;
    super.snf_cfg.ordered_dbid_resp = 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Drive one ordered exact-CHI-E write and verify DBIDRespOrd + Comp +
  // CompAck ordering through the integrated RN-I/SN-F path.
  // ---------------------------------------------------------------------------
  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t req_item;
    item_t dat_item;
    item_t rsp_items[$];
    item_t write_responses[$];

    phase.raise_objection(this);

    super.rni_wr_seq.reset();
    super.rni_wr_seq.set_requests(1);
    super.rni_wr_seq.set_initial_addr(E_DBID_RESP_ORD_ADDR_C);
    super.rni_wr_seq.set_size(3'd6);
    super.rni_wr_seq.set_src_id(E_DBID_RESP_ORD_RNI_NODE_ID_C);
    super.rni_wr_seq.set_tgt_id(E_DBID_RESP_ORD_SNF_NODE_ID_C);
    super.rni_wr_seq.set_qos(4'he);
    super.rni_wr_seq.set_order(VIP_CHI_ORDER_REQ_ORDER_E);
    super.rni_wr_seq.set_allow_retry(1'b0);
    super.rni_wr_seq.set_exp_comp_ack(1'b1);
    super.rni_wr_seq.set_data_type(VIP_CHI_DATA_COUNTER_E);
    super.rni_wr_seq.set_counter_value(item_t::data_t'('h90));
    super.rni_wr_seq.set_counter_increment(item_t::data_t'('h1));
    super.rni_wr_seq.set_get_response(1'b1);
    super.rni_wr_seq.set_verbose(1'b0);
    super.rni_wr_seq.start(super.tb_env.rni_agent.sequencer);

    write_responses = super.rni_wr_seq.get_responses();
    if (write_responses.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Expected 1 ordered exact-E write response, got %0d",
        super.tc_name, write_responses.size()))
    end

    super.tb_env.rni_req_fifo.get(req_item);
    super.tb_env.rni_dat_fifo.get(dat_item);
    repeat (3) begin
      item_t rsp_item;
      super.tb_env.rni_rsp_fifo.get(rsp_item);
      rsp_items.push_back(rsp_item);
    end

    if (req_item.order != VIP_CHI_ORDER_REQ_ORDER_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Exact-E ordered write REQ carried wrong Order value 0x%0h",
        super.tc_name, req_item.order))
    end

    if (dat_item.dat_opcode != item_t::dat_opcode_t'(VIP_CHI_DAT_NCB_WR_DATA_COMP_ACK_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Exact-E ordered write DAT opcode 0x%0h was not NCBWrDataCompAck",
        super.tc_name, dat_item.dat_opcode))
    end

    if (rsp_items[0].rsp_opcode != item_t::rsp_opcode_t'(VIP_CHI_RSP_DBID_RESP_ORD_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] First ordered exact-E write RSP opcode 0x%0h was not DBIDRespOrd",
        super.tc_name, rsp_items[0].rsp_opcode))
    end

    if (rsp_items[1].rsp_opcode != item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Second ordered exact-E write RSP opcode 0x%0h was not deferred Comp",
        super.tc_name, rsp_items[1].rsp_opcode))
    end

    if (rsp_items[2].rsp_opcode != item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_ACK_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Third ordered exact-E write RSP opcode 0x%0h was not CompAck",
        super.tc_name, rsp_items[2].rsp_opcode))
    end

    if ((rsp_items[0].role != VIP_CHI_ROLE_SNF_E) ||
        (rsp_items[1].role != VIP_CHI_ROLE_SNF_E) ||
        (rsp_items[2].role != VIP_CHI_ROLE_RNI_E)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Exact-E ordered write RSP roles did not match DBIDRespOrd/Comp/CompAck flow",
        super.tc_name))
    end

    if ((rsp_items[0].dbid != req_item.txn_id) ||
        (rsp_items[1].dbid != req_item.txn_id) ||
        (rsp_items[2].txn_id != req_item.txn_id)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Exact-E ordered write completion identifiers did not match the request txn_id",
        super.tc_name))
    end

    if (write_responses[0].rsp_opcode != item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Exact-E ordered write sequence response opcode 0x%0h was not deferred Comp",
        super.tc_name, write_responses[0].rsp_opcode))
    end

    if (write_responses[0].dbid != req_item.txn_id) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Exact-E ordered write sequence response dbid 0x%0h did not match txn_id 0x%0h",
        super.tc_name, write_responses[0].dbid, req_item.txn_id))
    end

    phase.drop_objection(this);
  endtask
endclass