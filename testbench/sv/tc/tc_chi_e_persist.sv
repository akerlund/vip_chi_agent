class tc_chi_e_persist extends vip_chi_e_base_test;

  typedef vip_chi_item #(CHI_E_WIDE_CFG_C) item_t;

  `uvm_component_utils(tc_chi_e_persist)
  vip_chi_persist_seq #(CHI_E_WIDE_CFG_C) persist_seq;

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // Create the persist sequence once topology is ready.
  // ---------------------------------------------------------------------------
  function void start_of_simulation_phase(input uvm_phase phase);

    super.start_of_simulation_phase(phase);

    this.persist_seq = vip_chi_persist_seq #(CHI_E_WIDE_CFG_C)::type_id::create("persist_seq");
  endfunction

  // ---------------------------------------------------------------------------
  // Drive one non-separated and one separated persist request through the
  // integrated RN-I/SN-F path and verify the observed completions.
  // ---------------------------------------------------------------------------
  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t req_item;
    item_t rsp_item;
    item_t persist_rsp_item;
    item_t comp_persist_rsp_item;
    item_t sequence_responses[$];
    item_t unexpected_dat;

    phase.raise_objection(this);

    this.persist_seq.reset();
    this.persist_seq.set_requests(1);
    this.persist_seq.set_initial_addr(E_PERSIST_ADDR_C);
    this.persist_seq.set_size(3'd6);
    this.persist_seq.set_src_id(E_PERSIST_RNI_NODE_ID_C);
    this.persist_seq.set_tgt_id(E_PERSIST_SNF_NODE_ID_C);
    this.persist_seq.set_qos(4'h9);
    this.persist_seq.set_allow_retry(1'b0);
    this.persist_seq.set_get_response(1'b1);
    this.persist_seq.set_verbose(1'b0);
    this.persist_seq.start(super.tb_env.rni_agent.sequencer);

    sequence_responses = this.persist_seq.get_responses();
    if (sequence_responses.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Expected 1 CleanSharedPersist response, got %0d",
        super.tc_name, sequence_responses.size()))
    end

    super.tb_env.rni_req_fifo.get(req_item);
    super.tb_env.rni_rsp_fifo.get(rsp_item);
    if (super.tb_env.rni_dat_fifo.try_get(unexpected_dat)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] CleanSharedPersist unexpectedly produced DAT traffic",
        super.tc_name))
    end

    if (req_item.opcode != item_t::req_opcode_t'(VIP_CHI_REQ_CLEAN_SHARED_PERSIST_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Monitor observed wrong persist REQ opcode 0x%0h",
        super.tc_name, req_item.opcode))
    end

    if (rsp_item.rsp_opcode != item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Persist RSP opcode 0x%0h was not Comp",
        super.tc_name, rsp_item.rsp_opcode))
    end

    if (sequence_responses[0].rsp_opcode != item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Persist sequence response opcode 0x%0h was not Comp",
        super.tc_name, sequence_responses[0].rsp_opcode))
    end

    if ((rsp_item.txn_id != req_item.txn_id) ||
        (rsp_item.src_id != req_item.tgt_id) ||
        (rsp_item.tgt_id != req_item.src_id)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Persist completion routing fields did not match the request",
        super.tc_name))
    end

    this.persist_seq.reset();
    this.persist_seq.set_sep_persist(1'b1);
    this.persist_seq.set_requests(1);
    this.persist_seq.set_initial_addr(E_PERSIST_SEP_ADDR_C);
    this.persist_seq.set_size(3'd6);
    this.persist_seq.set_src_id(E_PERSIST_SEP_RNI_NODE_ID_C);
    this.persist_seq.set_tgt_id(E_PERSIST_SEP_SNF_NODE_ID_C);
    this.persist_seq.set_qos(4'ha);
    this.persist_seq.set_allow_retry(1'b0);
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
    super.tb_env.rni_rsp_fifo.get(persist_rsp_item);
    super.tb_env.rni_rsp_fifo.get(comp_persist_rsp_item);
    if (super.tb_env.rni_dat_fifo.try_get(unexpected_dat)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] CleanSharedPersistSep unexpectedly produced DAT traffic",
        super.tc_name))
    end

    if (req_item.opcode != item_t::req_opcode_t'(VIP_CHI_REQ_CLEAN_SHARED_PERSIST_SEP_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Monitor observed wrong persist-sep REQ opcode 0x%0h",
        super.tc_name, req_item.opcode))
    end

    if (persist_rsp_item.rsp_opcode != item_t::rsp_opcode_t'(VIP_CHI_RSP_PERSIST_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] PersistSep first RSP opcode 0x%0h was not Persist",
        super.tc_name, persist_rsp_item.rsp_opcode))
    end

    if (comp_persist_rsp_item.rsp_opcode != item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_PERSIST_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] PersistSep second RSP opcode 0x%0h was not CompPersist",
        super.tc_name, comp_persist_rsp_item.rsp_opcode))
    end

    if ((persist_rsp_item.txn_id != req_item.txn_id) ||
        (comp_persist_rsp_item.txn_id != req_item.txn_id) ||
        (persist_rsp_item.src_id != req_item.tgt_id) ||
        (persist_rsp_item.tgt_id != req_item.src_id) ||
        (comp_persist_rsp_item.src_id != req_item.tgt_id) ||
        (comp_persist_rsp_item.tgt_id != req_item.src_id)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] PersistSep completion routing fields did not match the request",
        super.tc_name))
    end

    if (sequence_responses[0].rsp_opcode != item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_PERSIST_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] PersistSep sequence response opcode 0x%0h was not CompPersist",
        super.tc_name, sequence_responses[0].rsp_opcode))
    end

    phase.drop_objection(this);
  endtask

endclass