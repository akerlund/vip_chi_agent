class tc_chi_e_mte extends chi_e_base_test;

  typedef vip_chi_item #(CHI_E_WIDE_CFG_C) item_t;

  `uvm_component_utils(tc_chi_e_mte)

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // Ignore write-side DAT observations and return the SN-F CompData item once
  // it appears.
  // ---------------------------------------------------------------------------
  // ---------------------------------------------------------------------------
  // Get SNF Compdata
  // ---------------------------------------------------------------------------
  protected task get_snf_compdata(output item_t dat_item);

    forever begin
      super.tb_env.snf_dat_fifo.get(dat_item);

      if ((dat_item.role == VIP_CHI_ROLE_SNF_E) &&
          (dat_item.dat_opcode == item_t::dat_opcode_t'(VIP_CHI_DAT_COMP_DATA_C))) begin
        return;
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  // Write one tagged exact-E beat through the real RN-I/SN-F path and verify
  // the later real SN-F read completion replays the same DAT tag metadata.
  // ---------------------------------------------------------------------------
  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t     write_req_item;
    item_t     read_req_item;
    item_t     write_rsp_item;
    item_t     rsp_item;
    item_t     dat_item;
    item_t     write_responses[$];
    item_t     read_responses[$];
    item_t::data_t write_data[$];
    item_t::tag_t  write_tag[$];
    item_t::tu_t   write_tu[$];

    phase.raise_objection(this);

    write_data.push_back(E_MTE_WRITE_DATA_C);
    write_tag.push_back(E_MTE_WRITE_TAG_C);
    write_tu.push_back(E_MTE_WRITE_TU_C);

    super.rni_wr_seq.reset();
    super.rni_wr_seq.set_requests(1);
    super.rni_wr_seq.set_initial_addr(E_MTE_ADDR_C);
    super.rni_wr_seq.set_size(3'd6);
    super.rni_wr_seq.set_src_id(E_MTE_RNI_NODE_ID_C);
    super.rni_wr_seq.set_tgt_id(E_MTE_SNF_NODE_ID_C);
    super.rni_wr_seq.set_qos(4'hd);
    super.rni_wr_seq.set_allow_retry(1'b0);
    super.rni_wr_seq.set_get_response(1'b1);
    super.rni_wr_seq.set_verbose(1'b0);
    super.rni_wr_seq.set_data(write_data);
    super.rni_wr_seq.set_dat_tagop(E_MTE_WRITE_TAGOP_C);
    super.rni_wr_seq.set_tag(write_tag);
    super.rni_wr_seq.set_tu(write_tu);
    super.rni_wr_seq.start(super.tb_env.rni_agent.sequencer);

    super.rni_rd_seq.reset();
    super.rni_rd_seq.set_requests(1);
    super.rni_rd_seq.set_initial_addr(E_MTE_ADDR_C);
    super.rni_rd_seq.set_size(3'd6);
    super.rni_rd_seq.set_src_id(E_MTE_RNI_NODE_ID_C);
    super.rni_rd_seq.set_tgt_id(E_MTE_SNF_NODE_ID_C);
    super.rni_rd_seq.set_qos(4'h6);
    super.rni_rd_seq.set_allow_retry(1'b0);
    super.rni_rd_seq.set_get_response(1'b1);
    super.rni_rd_seq.set_verbose(1'b0);
    super.rni_rd_seq.start(super.tb_env.rni_agent.sequencer);

    write_responses = super.rni_wr_seq.get_responses();
    read_responses  = super.rni_rd_seq.get_responses();

    if ((write_responses.size() != 1) ||
        (write_responses[0].rsp_opcode != item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_DBID_RESP_C))) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Exact-E tagged write did not complete with CompDBIDResp",
        super.tc_name))
    end

    if ((read_responses.size() != 1) ||
        (read_responses[0].data.size() != 1) ||
        (read_responses[0].data[0] != E_MTE_WRITE_DATA_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Exact-E tagged readback did not return the expected data",
        super.tc_name))
    end

    super.tb_env.rni_req_fifo.get(write_req_item);
    super.tb_env.rni_req_fifo.get(read_req_item);
    super.tb_env.snf_rsp_fifo.get(write_rsp_item);

    if (write_rsp_item.rsp_opcode != item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_DBID_RESP_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Monitor observed wrong write completion opcode 0x%0h",
        super.tc_name, write_rsp_item.rsp_opcode))
    end

    if ((write_rsp_item.txn_id != write_req_item.txn_id) ||
        (write_rsp_item.dbid != write_req_item.txn_id) ||
        (write_rsp_item.src_id != write_req_item.tgt_id) ||
        (write_rsp_item.tgt_id != write_req_item.src_id)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Monitor observed wrong write completion routing fields",
        super.tc_name))
    end

    this.get_snf_compdata(dat_item);

    if ((dat_item.role != VIP_CHI_ROLE_SNF_E) ||
        (dat_item.dat_opcode != item_t::dat_opcode_t'(VIP_CHI_DAT_COMP_DATA_C))) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Monitor observed wrong autonomous read DAT metadata",
        super.tc_name))
    end

    if ((dat_item.txn_id != read_req_item.txn_id) ||
        (dat_item.dbid != read_req_item.txn_id) ||
        (dat_item.src_id != read_req_item.tgt_id) ||
        (dat_item.tgt_id != read_req_item.src_id)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Monitor observed wrong autonomous read DAT routing fields",
        super.tc_name))
    end

    if ((dat_item.data.size() != 1) ||
        (dat_item.data[0] != E_MTE_WRITE_DATA_C) ||
        (dat_item.be.size() != 1) ||
        (dat_item.be[0] != '1)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Monitor observed wrong autonomous read DAT payload",
        super.tc_name))
    end

    if ((dat_item.dat_tagop != E_MTE_WRITE_TAGOP_C) ||
        (dat_item.tag.size() != 1) ||
        (dat_item.tag[0] != E_MTE_WRITE_TAG_C) ||
        (dat_item.tu.size() != 1) ||
        (dat_item.tu[0] != E_MTE_WRITE_TU_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Monitor observed wrong autonomous read DAT tagging fields",
        super.tc_name))
    end

    phase.drop_objection(this);
  endtask

endclass