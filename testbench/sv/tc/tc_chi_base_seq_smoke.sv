class tc_chi_base_seq_smoke extends uvm_test;

  `uvm_component_utils(tc_chi_base_seq_smoke)

  string tc_name;

  typedef vip_chi_types #(CHI_D_WIDE_CFG_C)::addr_t       addr_t;
  typedef vip_chi_item  #(CHI_D_WIDE_CFG_C)::data_t       data_t;
  typedef vip_chi_item  #(CHI_D_WIDE_CFG_C)::be_t         be_t;
  typedef vip_chi_types #(CHI_E_WIDE_CFG_C)::addr_t       addr_e_t;
  typedef vip_chi_types #(CHI_E_WIDE_CFG_C)::req_opcode_t req_opcode_e_t;
  typedef vip_chi_item  #(CHI_E_WIDE_CFG_C)::groupidext_t groupidext_e_t;
  typedef vip_chi_item  #(CHI_E_WIDE_CFG_C)::tagop_t      tagop_e_t;
  typedef vip_chi_item  #(CHI_E_WIDE_CFG_C)::tag_t        dat_tag_e_t;
  typedef vip_chi_item  #(CHI_E_WIDE_CFG_C)::tu_t         dat_tu_e_t;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

    tc_name = name;
    void'($value$plusargs("UVM_TESTNAME=%s", tc_name));
  endfunction

  // ---------------------------------------------------------------------------
  // Verify base-sequence helpers and derived sequence behavior inside UVM.
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    vip_chi_seq_config                              seq_cfg;
    vip_chi_addr_iterator        #(CHI_D_WIDE_CFG_C) addr_iter;
    vip_chi_seq_payload_buffer   #(CHI_D_WIDE_CFG_C) payload_buf;
    vip_chi_seq_counter_iter     #(CHI_D_WIDE_CFG_C) counter_iter;
    vip_chi_cfg_item                                cfg_item;
    vip_chi_item                 #(CHI_D_WIDE_CFG_C) item;
    vip_chi_base_seq             #(CHI_D_WIDE_CFG_C) seq;
    vip_chi_read_seq             #(CHI_D_WIDE_CFG_C) read_seq;
    vip_chi_read_seq             #(CHI_E_WIDE_CFG_C) read_seq_e;
    vip_chi_write_seq            #(CHI_D_WIDE_CFG_C) write_seq;
    vip_chi_write_seq            #(CHI_E_WIDE_CFG_C) write_seq_e;
    vip_chi_item                 #(CHI_D_WIDE_CFG_C) preview_item;
    vip_chi_item                 #(CHI_E_WIDE_CFG_C) preview_item_e;
    vip_chi_item                 #(CHI_E_WIDE_CFG_C) preview_item_e_dat;
    vip_chi_write_zero_seq       #(CHI_E_WIDE_CFG_C) write_zero_seq_e;
    vip_chi_write_zero_seq       #(CHI_D_WIDE_CFG_C) write_zero_seq_d;
    chi_write_zero_fatal_catcher                 write_zero_catcher;
    vip_chi_pipelined_seq        #(CHI_D_WIDE_CFG_C) pipelined_seq;

    addr_t addr_list [];
    data_t data_q     [$];
    be_t   be_q       [$];
    dat_tag_e_t tag_q_e [];
    dat_tu_e_t  tu_q_e  [];
    addr_t next_addr;

    phase.raise_objection(this);

    seq_cfg = new("seq_cfg");
    seq_cfg.reset();
    if (seq_cfg.requests != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] vip_chi_seq_config reset() did not restore requests",
        tc_name))
    end

    addr_iter = new("addr_iter");
    addr_iter.set_initial_addr(addr_t'('h1000));
    if (addr_iter.current() != addr_t'('h1000)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] vip_chi_addr_iterator current() mismatch",
        tc_name))
    end

    next_addr = addr_iter.advance(3'd6);
    if (next_addr != addr_t'('h1040)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] vip_chi_addr_iterator auto-stride mismatch",
        tc_name))
    end

    addr_iter.set_increment(16);
    next_addr = addr_iter.advance(3'd0);
    if (next_addr != addr_t'('h1050)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] vip_chi_addr_iterator fixed-stride mismatch",
        tc_name))
    end

    addr_list    = new[2];
    addr_list[0] = addr_t'('h2000);
    addr_list[1] = addr_t'('h3000);
    addr_iter.load_list(addr_list);
    if (addr_iter.list_size() != 2) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] vip_chi_addr_iterator list_size() mismatch",
        tc_name))
    end

    if (addr_iter.pop_list_front() != addr_t'('h2000)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] vip_chi_addr_iterator pop_list_front() mismatch",
        tc_name))
    end

    cfg_item            = new("cfg_item");
    cfg_item.direction  = VIP_CHI_DIR_WRITE_E;
    cfg_item.data_type  = VIP_CHI_DATA_CUSTOM_E;
    cfg_item.min_size   = 6;
    cfg_item.max_size   = 6;

    payload_buf = new("payload_buf");
    data_q.push_back(data_t'('h1234));
    be_q.push_back(be_t'('1));
    payload_buf.set_data(data_q);
    payload_buf.set_be(be_q);
    payload_buf.clamp_size(cfg_item);

    item = new("custom_item");
    item.set_size(3'd6);
    item.set_data_type(VIP_CHI_DATA_CUSTOM_E);
    item.set_deferred_custom_payload(1'b1);
    if (!item.randomize() with {
      direction == VIP_CHI_DIR_WRITE_E;
      role      == VIP_CHI_ROLE_RNI_E;
      opcode    == VIP_CHI_REQ_WRITE_NO_SNP_PTL_C;
    }) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Deferred CUSTOM item failed to randomize",
        tc_name))
    end

    payload_buf.apply(item, cfg_item);
    if ((item.data.size() != 1) || (item.data[0] != data_t'('h1234))) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] vip_chi_seq_payload_buffer apply() did not stamp custom data",
        tc_name))
    end

    if ((item.be.size() != 1) || (item.be[0] != be_t'('1))) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] vip_chi_seq_payload_buffer apply() did not stamp custom BE",
        tc_name))
    end

    if (!payload_buf.exhausted()) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] vip_chi_seq_payload_buffer did not consume the custom slice",
        tc_name))
    end

    counter_iter = new("counter_iter");
    counter_iter.set_counter(data_t'('h10));
    counter_iter.set_increment(data_t'('h4));

    cfg_item.data_type = VIP_CHI_DATA_COUNTER_E;
    item = new("counter_item");
    item.set_size(3'd6);
    item.set_data_type(VIP_CHI_DATA_COUNTER_E);
    counter_iter.configure_item(item);
    if (!item.randomize() with {
      direction == VIP_CHI_DIR_WRITE_E;
      role      == VIP_CHI_ROLE_RNI_E;
      opcode    == VIP_CHI_REQ_WRITE_NO_SNP_FULL_C;
    }) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] COUNTER item failed to randomize",
        tc_name))
    end

    counter_iter.advance(item, cfg_item);
    if (counter_iter.get_counter() != data_t'('h14)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] vip_chi_seq_counter_iter did not advance after one beat",
        tc_name))
    end

    seq = new("seq");
    seq.set_initial_addr(addr_t'('h4000));
    seq.set_size(3'd6);
    seq.set_requests(4);
    seq.set_data_type(VIP_CHI_DATA_COUNTER_E);
    seq.set_counter_value(data_t'('h20));
    seq.set_counter_increment(data_t'('h2));
    if (seq.get_counter() != data_t'('h20)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] vip_chi_base_seq counter setter/getter mismatch",
        tc_name))
    end

    seq.set_ns(1'b0);
    seq.set_order(VIP_CHI_ORDER_REQ_ORDER_E);
    seq.set_mem_attr(4'hf);
    seq.set_allow_retry(1'b0);
    seq.set_exp_comp_ack(1'b1);
    seq.set_excl(1'b1);
    seq.set_pcrd_type(4'h5);
    seq.set_get_response(1'b1);
    seq.set_request_delay(1'b1, 1, 2, 10ns);
    seq.set_verbose(1'b0);
    seq.set_log_denominator(8);
    seq.reset();

    if (seq.get_counter() != '0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] vip_chi_base_seq reset() did not reset the counter iterator",
        tc_name))
    end

    read_seq = new("read_seq");
    read_seq.set_requests(0);
    read_seq.body();
    if (read_seq.get_direction() != VIP_CHI_DIR_READ_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] vip_chi_read_seq did not pin READ direction",
        tc_name))
    end

    read_seq.reset();
    if (read_seq.get_direction() != VIP_CHI_DIR_READ_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] vip_chi_read_seq reset() did not preserve READ direction",
        tc_name))
    end

    write_seq = new("write_seq");
    write_seq.set_requests(0);
    write_seq.body();
    if (write_seq.get_direction() != VIP_CHI_DIR_WRITE_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] vip_chi_write_seq did not pin WRITE direction",
        tc_name))
    end

    write_seq.reset();
    if (write_seq.get_direction() != VIP_CHI_DIR_WRITE_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] vip_chi_write_seq reset() did not preserve WRITE direction",
        tc_name))
    end

    write_seq.set_initial_addr(addr_t'('h4400));
    write_seq.set_size(3'd6);
    write_seq.set_data_type(VIP_CHI_DATA_COUNTER_E);
    write_seq.set_src_id(vip_chi_item #(CHI_D_WIDE_CFG_C)::node_id_t'('h12));
    write_seq.set_tgt_id(vip_chi_item #(CHI_D_WIDE_CFG_C)::node_id_t'('h34));
    write_seq.set_lp_id(vip_chi_item #(CHI_D_WIDE_CFG_C)::lpid_t'('h7));
    write_seq.set_qos(4'h9);
    write_seq.set_ns(1'b0);
    write_seq.set_order(VIP_CHI_ORDER_REQ_ORDER_E);
    write_seq.set_mem_attr(4'hf);
    write_seq.set_allow_retry(1'b0);
    write_seq.set_exp_comp_ack(1'b1);
    write_seq.set_excl(1'b1);
    write_seq.set_pcrd_type(4'h5);
    preview_item = write_seq.preview_next_request();

    if (preview_item.addr != addr_t'('h4400)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] vip_chi_write_seq preview did not preserve the stamped address",
        tc_name))
    end

    if (preview_item.direction != VIP_CHI_DIR_WRITE_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] vip_chi_write_seq preview did not preserve WRITE direction",
        tc_name))
    end

    if (preview_item.role != VIP_CHI_ROLE_RNI_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] vip_chi_write_seq preview did not preserve RN-I role",
        tc_name))
    end

    if ((preview_item.src_id != vip_chi_item #(CHI_D_WIDE_CFG_C)::node_id_t'('h12)) ||
        (preview_item.tgt_id != vip_chi_item #(CHI_D_WIDE_CFG_C)::node_id_t'('h34)) ||
        (preview_item.lp_id  != vip_chi_item #(CHI_D_WIDE_CFG_C)::lpid_t'('h7))) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] vip_chi_write_seq preview did not preserve stamped identity fields",
        tc_name))
    end

    if (preview_item.qos != 4'h9) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] vip_chi_write_seq preview did not preserve stamped QoS field",
        tc_name))
    end

    read_seq_e = new("read_seq_e");
    read_seq_e.set_initial_addr(addr_e_t'('h4600));
    read_seq_e.set_size(3'd6);
    read_seq_e.set_sep_read(1'b1);
    read_seq_e.set_src_id(vip_chi_item #(CHI_E_WIDE_CFG_C)::node_id_t'('h5));
    read_seq_e.set_tgt_id(vip_chi_item #(CHI_E_WIDE_CFG_C)::node_id_t'('h2));
    read_seq_e.set_return_nid(vip_chi_item #(CHI_E_WIDE_CFG_C)::node_id_t'('h5));
    read_seq_e.set_return_txn_id(vip_chi_item #(CHI_E_WIDE_CFG_C)::txn_id_t'('h2a));
    read_seq_e.set_qos(4'h6);
    read_seq_e.set_tracetag(1'b1);
    read_seq_e.set_dodwt(1'b1);
    read_seq_e.set_likelyshared(1'b1);
    read_seq_e.set_endian(1'b1);
    read_seq_e.set_group_id_ext(groupidext_e_t'('h5));
    read_seq_e.set_tagop(tagop_e_t'('h2));
    preview_item_e = read_seq_e.preview_next_request();

    if (preview_item_e.opcode != req_opcode_e_t'(VIP_CHI_REQ_READ_NO_SNP_SEP_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] vip_chi_read_seq CHI-E preview did not choose ReadNoSnpSep",
        tc_name))
    end

    if ((preview_item_e.return_nid != vip_chi_item #(CHI_E_WIDE_CFG_C)::node_id_t'('h5)) ||
        (preview_item_e.return_txn_id != vip_chi_item #(CHI_E_WIDE_CFG_C)::txn_id_t'('h2a)) ||
        (preview_item_e.qos != 4'h6)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] vip_chi_read_seq CHI-E preview did not preserve stamped return-path/QoS fields",
        tc_name))
    end

    if ((preview_item_e.tracetag != 1'b1) ||
        (preview_item_e.dodwt != 1'b1) ||
        (preview_item_e.likelyshared != 1'b1) ||
        (preview_item_e.endian != 1'b1) ||
        (preview_item_e.group_id_ext != groupidext_e_t'('h5)) ||
        (preview_item_e.tagop != tagop_e_t'('h2))) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] vip_chi_read_seq CHI-E preview did not preserve stamped control/tagop fields",
        tc_name))
    end

    write_seq_e = new("write_seq_e");
    write_seq_e.set_initial_addr(addr_e_t'('h4800));
    write_seq_e.set_size(3'd6);
    write_seq_e.set_dat_tagop(tagop_e_t'('h1));
    tag_q_e = new[1];
    tag_q_e[0] = dat_tag_e_t'('h3);
    tu_q_e = new[1];
    tu_q_e[0] = dat_tu_e_t'('h1);
    write_seq_e.set_tag(tag_q_e);
    write_seq_e.set_tu(tu_q_e);
    preview_item_e_dat = write_seq_e.preview_next_request();

    if ((preview_item_e_dat.dat_tagop != tagop_e_t'('h1)) ||
        (preview_item_e_dat.tag.size() != 1) ||
        (preview_item_e_dat.tu.size() != 1) ||
        (preview_item_e_dat.tag[0] != dat_tag_e_t'('h3)) ||
        (preview_item_e_dat.tu[0] != dat_tu_e_t'('h1))) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] vip_chi_write_seq CHI-E preview did not preserve stamped DAT tagging fields",
        tc_name))
    end

    if (preview_item.opcode != item_t::req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_FULL_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] vip_chi_write_seq preview chose the wrong write opcode",
        tc_name))
    end

    if ((preview_item.ns != 1'b0) ||
        (preview_item.order != VIP_CHI_ORDER_REQ_ORDER_E) ||
        (preview_item.mem_attr != 4'hf) ||
        (preview_item.allow_retry != 1'b0) ||
        (preview_item.exp_comp_ack != 1'b1) ||
        (preview_item.excl != 1'b1) ||
        (preview_item.pcrd_type != 4'h5)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] vip_chi_write_seq preview did not preserve stamped control fields",
        tc_name))
    end

    if (preview_item.dat_opcode != item_t::dat_opcode_t'(VIP_CHI_DAT_NCB_WR_DATA_COMP_ACK_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] vip_chi_write_seq preview did not derive CompAck-capable DAT opcode",
        tc_name))
    end

    write_zero_seq_e = new("write_zero_seq_e");
    write_zero_seq_e.set_requests(0);
    write_zero_seq_e.body();
    if (write_zero_seq_e.get_direction() != VIP_CHI_DIR_WRITE_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] vip_chi_write_zero_seq did not pin WRITE direction",
        tc_name))
    end

    if (write_zero_seq_e.get_opcode() != req_opcode_e_t'(VIP_CHI_REQ_WRITE_NO_SNP_ZERO_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] vip_chi_write_zero_seq did not force WriteNoSnpZero",
        tc_name))
    end

    if (write_zero_seq_e.get_access_name() != "WriteNoSnpZero") begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] vip_chi_write_zero_seq reported the wrong access label",
        tc_name))
    end

    write_zero_seq_e.reset();
    if (write_zero_seq_e.get_direction() != VIP_CHI_DIR_WRITE_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] vip_chi_write_zero_seq reset() did not preserve WRITE direction",
        tc_name))
    end

    write_zero_catcher = new("write_zero_catcher");
    uvm_report_cb::add(null, write_zero_catcher);
    write_zero_seq_d = new("write_zero_seq_d");
    write_zero_seq_d.set_requests(0);
    write_zero_seq_d.body();
    if (!write_zero_catcher.saw_write_zero_issue_fatal) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] vip_chi_write_zero_seq did not fatal under CHI-D",
        tc_name))
    end
    uvm_report_cb::delete(null, write_zero_catcher);

    pipelined_seq = new("pipelined_seq");
    if (pipelined_seq.max_outstanding != 8) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] vip_chi_pipelined_seq default max_outstanding mismatch",
        tc_name))
    end

    if (pipelined_seq.item_count() != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] vip_chi_pipelined_seq should start with an empty queue",
        tc_name))
    end

    item = new("pipelined_item");
    item.set_config(CHI_D_WIDE_CFG_C);
    pipelined_seq.add_item(item);
    if (pipelined_seq.item_count() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] vip_chi_pipelined_seq add_item() did not queue the item",
        tc_name))
    end

    pipelined_seq.set_get_response(1'b1);
    pipelined_seq.reset();
    if (pipelined_seq.item_count() != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] vip_chi_pipelined_seq reset() did not clear queued items",
        tc_name))
    end

    if (pipelined_seq.response_count() != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] vip_chi_pipelined_seq reset() did not clear collected responses",
        tc_name))
    end

    if (pipelined_seq.max_outstanding != 8) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] vip_chi_pipelined_seq reset() did not restore max_outstanding",
        tc_name))
    end

    phase.drop_objection(this);
  endtask
endclass