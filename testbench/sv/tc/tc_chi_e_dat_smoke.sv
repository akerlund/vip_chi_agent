class tc_chi_e_dat_smoke extends chi_e_base_test;

  typedef vip_chi_item #(CHI_E_WIDE_CFG_C) item_t;

  `uvm_component_utils(tc_chi_e_dat_smoke)

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // Drive one exact-CHI-E write through the real RN-I -> SN-F path and verify
  // the DAT monitor publishes the E-only DAT tagging fields.
  // ---------------------------------------------------------------------------
  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t req_item;
    item_t rsp_item;
    item_t dat_item;
    item_t::tag_t tag_vals[];
    item_t::tu_t  tu_vals[];

    phase.raise_objection(this);

    tag_vals    = new[1];
    tu_vals     = new[1];
    tag_vals[0] = item_t::tag_t'('h1234);
    tu_vals[0]  = item_t::tu_t'('ha);

    super.rni_wr_seq.reset();
    super.rni_wr_seq.set_requests(1);
    super.rni_wr_seq.set_initial_addr(52'h0012_3456_7c00);
    super.rni_wr_seq.set_size(3'd6);
    super.rni_wr_seq.set_src_id(item_t::node_id_t'('h1c));
    super.rni_wr_seq.set_tgt_id(item_t::node_id_t'('h22));
    super.rni_wr_seq.set_lp_id(item_t::lpid_t'('hb));
    super.rni_wr_seq.set_qos(4'hd);
    super.rni_wr_seq.set_dat_tagop(item_t::tagop_t'('h1));
    super.rni_wr_seq.set_tag(tag_vals);
    super.rni_wr_seq.set_tu(tu_vals);
    super.rni_wr_seq.set_get_response(1'b1);
    super.rni_wr_seq.set_verbose(1'b0);
    super.rni_wr_seq.start(super.tb_env.rni_agent.sequencer);

    super.tb_env.rni_req_fifo.get(req_item);
    super.tb_env.rni_rsp_fifo.get(rsp_item);
    super.tb_env.rni_dat_fifo.get(dat_item);

    if (req_item.opcode != item_t::req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_FULL_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Monitor observed wrong REQ opcode 0x%0h",
        super.tc_name, req_item.opcode))
    end

    if (rsp_item.rsp_opcode != item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_DBID_RESP_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Monitor observed wrong RSP opcode 0x%0h",
        super.tc_name, rsp_item.rsp_opcode))
    end

    if ((dat_item.src_id != item_t::node_id_t'('h1c)) ||
        (dat_item.tgt_id != item_t::node_id_t'('h22)) ||
        (dat_item.qos != 4'hd)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Monitor observed wrong exact-CHI-E DAT routing fields",
        super.tc_name))
    end

    if ((dat_item.dat_tagop != item_t::tagop_t'('h1)) ||
        (dat_item.tag.size() != 1) ||
        (dat_item.tag[0] != item_t::tag_t'('h1234)) ||
        (dat_item.tu.size() != 1) ||
        (dat_item.tu[0] != item_t::tu_t'('ha))) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Monitor observed wrong exact-CHI-E DAT tagging fields",
        super.tc_name))
    end

    phase.drop_objection(this);
  endtask

endclass
