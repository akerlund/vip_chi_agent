class tc_chi_e_req_smoke extends chi_e_base_test;

  typedef vip_chi_item #(CHI_E_WIDE_CFG_C) item_t;

  `uvm_component_utils(tc_chi_e_req_smoke)

  vip_chi_write_zero_seq #(CHI_E_WIDE_CFG_C) rni_wr_zero_seq;

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // Create the exact-CHI-E write-zero sequence once topology is ready.
  // ---------------------------------------------------------------------------
  function void start_of_simulation_phase(input uvm_phase phase);

    super.start_of_simulation_phase(phase);

    this.rni_wr_zero_seq = vip_chi_write_zero_seq #(CHI_E_WIDE_CFG_C)::type_id::create("rni_wr_zero_seq");
  endfunction

  // ---------------------------------------------------------------------------
  // Drive one exact-CHI-E write through the real RN-I -> SN-F path and verify
  // the REQ monitor publishes the E-only fields and the SN-F returns Comp.
  // ---------------------------------------------------------------------------
  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t req_item;
    item_t rsp_item;

    phase.raise_objection(this);

    this.rni_wr_zero_seq.reset();
    this.rni_wr_zero_seq.set_requests(1);
    this.rni_wr_zero_seq.set_initial_addr(52'h0012_3456_7800);
    this.rni_wr_zero_seq.set_size(3'd6);
    this.rni_wr_zero_seq.set_src_id(item_t::node_id_t'('h15));
    this.rni_wr_zero_seq.set_tgt_id(item_t::node_id_t'('h2a));
    this.rni_wr_zero_seq.set_lp_id(item_t::lpid_t'('h9));
    this.rni_wr_zero_seq.set_qos(4'hb);
    this.rni_wr_zero_seq.set_tracetag(1'b1);
    this.rni_wr_zero_seq.set_dodwt(1'b1);
    this.rni_wr_zero_seq.set_likelyshared(1'b1);
    this.rni_wr_zero_seq.set_endian(1'b1);
    this.rni_wr_zero_seq.set_group_id_ext(item_t::groupidext_t'('h3));
    this.rni_wr_zero_seq.set_tagop(item_t::tagop_t'('h2));
    this.rni_wr_zero_seq.set_get_response(1'b1);
    this.rni_wr_zero_seq.set_verbose(1'b0);
    this.rni_wr_zero_seq.start(super.tb_env.rni_agent.sequencer);

    super.tb_env.rni_req_fifo.get(req_item);
    super.tb_env.rni_rsp_fifo.get(rsp_item);

    if (req_item.opcode != item_t::req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_ZERO_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Monitor observed wrong REQ opcode 0x%0h",
        super.tc_name, req_item.opcode))
    end

    if (req_item.addr != 52'h0012_3456_7800) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Monitor observed wrong REQ address 0x%0h",
        super.tc_name, req_item.addr))
    end

    if ((req_item.src_id != item_t::node_id_t'('h15)) ||
        (req_item.tgt_id != item_t::node_id_t'('h2a)) ||
        (req_item.lp_id  != item_t::lpid_t'('h9))  ||
        (req_item.qos    != 4'hb)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Monitor observed wrong exact-CHI-E common REQ fields",
        super.tc_name))
    end

    if ((req_item.tracetag != 1'b1) ||
        (req_item.dodwt != 1'b1) ||
        (req_item.likelyshared != 1'b1) ||
        (req_item.endian != 1'b1) ||
        (req_item.group_id_ext != item_t::groupidext_t'('h3)) ||
        (req_item.tagop != item_t::tagop_t'('h2))) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Monitor observed wrong exact-CHI-E REQ-only fields",
        super.tc_name))
    end

    if (rsp_item.rsp_opcode != item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Monitor observed wrong RSP opcode 0x%0h",
        super.tc_name, rsp_item.rsp_opcode))
    end

    phase.drop_objection(this);
  endtask

endclass
