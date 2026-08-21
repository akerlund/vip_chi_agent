class tc_chi_e_rsp_field_legality extends chi_e_base_test;

  typedef vip_chi_item #(CHI_E_WIDE_CFG_C) item_t;

  `uvm_component_utils(tc_chi_e_rsp_field_legality)

  vip_chi_persist_seq #(CHI_E_WIDE_CFG_C) persist_seq;

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // Configure the SN-F response forms this testcase observes.
  // ---------------------------------------------------------------------------
  protected virtual function void configure_agent_cfgs();

    super.snf_cfg.split_write_rsp   = 1'b1;
    super.snf_cfg.ordered_dbid_resp = 1'b1;
    super.snf_cfg.decerr_ranges     = new[1];
    super.snf_cfg.decerr_ranges[0].base =
      E_DBID_RESP_ORD_ADDR_C + item_t::addr_t'('h400);
    super.snf_cfg.decerr_ranges[0].limit =
      E_DBID_RESP_ORD_ADDR_C + item_t::addr_t'('h43f);
  endfunction

  // ---------------------------------------------------------------------------
  // Create the separated-persist sequence once topology is ready.
  // ---------------------------------------------------------------------------
  function void start_of_simulation_phase(input uvm_phase phase);

    super.start_of_simulation_phase(phase);

    this.persist_seq = vip_chi_persist_seq #(CHI_E_WIDE_CFG_C)::type_id::create("persist_seq");
  endfunction

  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t req_item;
    item_t dat_item;
    item_t grant_rsp;
    item_t comp_rsp;
    item_t persist_rsp;
    item_t sequence_responses[$];

    phase.raise_objection(this);

    super.rni_wr_seq.reset();
    super.rni_wr_seq.set_requests(1);
    super.rni_wr_seq.set_initial_addr(E_DBID_RESP_ORD_ADDR_C + item_t::addr_t'('h400));
    super.rni_wr_seq.set_size(3'd6);
    super.rni_wr_seq.set_src_id(E_DBID_RESP_ORD_RNI_NODE_ID_C);
    super.rni_wr_seq.set_tgt_id(E_DBID_RESP_ORD_SNF_NODE_ID_C);
    super.rni_wr_seq.set_qos(4'hd);
    super.rni_wr_seq.set_order(VIP_CHI_ORDER_REQ_ORDER_E);
    super.rni_wr_seq.set_data_type(VIP_CHI_DATA_COUNTER_E);
    super.rni_wr_seq.set_counter_value(item_t::data_t'('hb0));
    super.rni_wr_seq.set_counter_increment(item_t::data_t'('h1));
    super.rni_wr_seq.set_get_response(1'b1);
    super.rni_wr_seq.set_verbose(1'b0);
    super.rni_wr_seq.start(super.tb_env.rni_agent.sequencer);

    sequence_responses = super.rni_wr_seq.get_responses();
    if (sequence_responses.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Expected 1 split DECERR write response, got %0d",
        super.tc_name, sequence_responses.size()))
    end

    super.tb_env.rni_req_fifo.get(req_item);
    super.tb_env.rni_dat_fifo.get(dat_item);
    super.tb_env.rni_rsp_fifo.get(grant_rsp);
    super.tb_env.rni_rsp_fifo.get(comp_rsp);

    if (grant_rsp.rsp_opcode != VIP_CHI_RSP_DBID_RESP_ORD_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Split DECERR write grant opcode 0x%0h was not DBIDRespOrd",
        super.tc_name, grant_rsp.rsp_opcode))
    end

    if (grant_rsp.rsp_resp_err != VIP_CHI_RESP_ERR_NORMAL_OKAY_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] DBIDRespOrd RespErr 0x%0h was not zero",
        super.tc_name, grant_rsp.rsp_resp_err))
    end

    if (comp_rsp.rsp_opcode != VIP_CHI_RSP_COMP_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Split DECERR write completion opcode 0x%0h was not Comp",
        super.tc_name, comp_rsp.rsp_opcode))
    end

    if ((comp_rsp.rsp_resp_err != VIP_CHI_RESP_ERR_NONDATA_ERROR_E) ||
        (sequence_responses[0].rsp_resp_err != VIP_CHI_RESP_ERR_NONDATA_ERROR_E)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Deferred Comp did not preserve NDERR after zeroed DBIDRespOrd",
        super.tc_name))
    end

    this.persist_seq.reset();
    this.persist_seq.set_sep_persist(1'b1);
    this.persist_seq.set_requests(1);
    this.persist_seq.set_initial_addr(E_PERSIST_SEP_ADDR_C + item_t::addr_t'('h300));
    this.persist_seq.set_size(3'd6);
    this.persist_seq.set_src_id(E_PERSIST_SEP_RNI_NODE_ID_C);
    this.persist_seq.set_tgt_id(E_PERSIST_SEP_SNF_NODE_ID_C);
    this.persist_seq.set_qos(4'hc);
    this.persist_seq.set_get_response(1'b1);
    this.persist_seq.set_verbose(1'b0);
    this.persist_seq.start(super.tb_env.rni_agent.sequencer);

    sequence_responses = this.persist_seq.get_responses();
    if (sequence_responses.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Expected 1 CleanSharedPersistSep response, got %0d",
        super.tc_name, sequence_responses.size()))
    end

    super.tb_env.rni_req_fifo.get(req_item);
    super.tb_env.rni_rsp_fifo.get(comp_rsp);
    super.tb_env.rni_rsp_fifo.get(persist_rsp);

    if (req_item.opcode != VIP_CHI_REQ_CLEAN_SHARED_PERSIST_SEP_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Persist request opcode 0x%0h was not CleanSharedPersistSep",
        super.tc_name, req_item.opcode))
    end

    if ((comp_rsp.rsp_opcode != VIP_CHI_RSP_COMP_C) ||
        (comp_rsp.txn_id != req_item.txn_id)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] PersistSep Comp did not carry the request TxnID",
        super.tc_name))
    end

    if ((persist_rsp.rsp_opcode != VIP_CHI_RSP_PERSIST_C) ||
        (persist_rsp.txn_id != '0)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Persist flit opcode/TxnID were not Persist/zero",
        super.tc_name))
    end

    if (sequence_responses[0].rsp_opcode != VIP_CHI_RSP_PERSIST_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] PersistSep sequence response opcode 0x%0h was not Persist",
        super.tc_name, sequence_responses[0].rsp_opcode))
    end

    phase.drop_objection(this);
  endtask

endclass
