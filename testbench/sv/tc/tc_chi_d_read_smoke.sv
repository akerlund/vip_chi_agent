class tc_chi_d_read_smoke extends chi_base_test;

  `uvm_component_utils(tc_chi_d_read_smoke)

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // Drive one read and verify both collected and sequence-returned payloads.
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t                        req_item;
    item_t                        dat_item;
    item_t                        responses[$];
    item_t                        rsp_item;

    phase.raise_objection(this);

    super.rni0_rd_seq.reset();
    super.rni0_rd_seq.set_requests(1);
    super.rni0_rd_seq.set_initial_addr(READ_ADDR_C);
    super.rni0_rd_seq.set_size(3'd6);
    super.rni0_rd_seq.set_get_response(1'b1);
    super.rni0_rd_seq.set_verbose(1'b0);
    super.rni0_rd_seq.start(super.v_sqr.rni_sequencer);

    responses = super.rni0_rd_seq.get_responses();
    if (responses.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Expected 1 read response, got %0d",
        super.tc_name, responses.size()))
    end
    rsp_item = responses[0];

    super.tb_env.rni_req_fifo.get(req_item);
    super.tb_env.rni_dat_fifo.get(dat_item);

    if (req_item.opcode != item_t::req_opcode_t'(VIP_CHI_REQ_READ_NO_SNP_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Monitor observed wrong REQ opcode 0x%0h",
        super.tc_name, req_item.opcode))
    end

    if (req_item.addr != READ_ADDR_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Monitor observed wrong REQ address 0x%0h",
        super.tc_name, req_item.addr))
    end

    if (rsp_item.role != VIP_CHI_ROLE_SNF_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Read response carried wrong role %0d",
        super.tc_name, rsp_item.role))
    end

    if (rsp_item.dat_opcode != item_t::dat_opcode_t'(VIP_CHI_DAT_COMP_DATA_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Read response carried wrong DAT opcode 0x%0h",
        super.tc_name, rsp_item.dat_opcode))
    end

    if (rsp_item.txn_id != req_item.txn_id) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Read response carried wrong txn_id 0x%0h",
        super.tc_name, rsp_item.txn_id))
    end

    if (rsp_item.dbid != req_item.txn_id) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Read response carried wrong dbid 0x%0h",
        super.tc_name, rsp_item.dbid))
    end

    if (rsp_item.src_id != req_item.tgt_id) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Read response carried wrong src_id 0x%0h",
        super.tc_name, rsp_item.src_id))
    end

    if (rsp_item.tgt_id != req_item.src_id) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Read response carried wrong tgt_id 0x%0h",
        super.tc_name, rsp_item.tgt_id))
    end

    if (rsp_item.data.size() != 4) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Read response carried %0d beats instead of 4",
        super.tc_name, rsp_item.data.size()))
    end

    if (dat_item.role != VIP_CHI_ROLE_SNF_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Monitor observed wrong DAT role %0d",
        super.tc_name, dat_item.role))
    end

    if (dat_item.data.size() != rsp_item.data.size()) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Monitor DAT beat count %0d does not match response beat count %0d",
        super.tc_name, dat_item.data.size(), rsp_item.data.size()))
    end

    foreach (rsp_item.data[i]) begin
      if (rsp_item.data[i] != (item_t::data_t'(READ_ADDR_C) + item_t::data_t'(i))) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] Read response beat %0d payload mismatch 0x%0h",
          super.tc_name, i, rsp_item.data[i]))
      end
      if (dat_item.data[i] != rsp_item.data[i]) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] Monitor DAT beat %0d payload mismatch 0x%0h vs 0x%0h",
          super.tc_name, i, dat_item.data[i], rsp_item.data[i]))
      end
    end

    phase.drop_objection(this);
  endtask
endclass