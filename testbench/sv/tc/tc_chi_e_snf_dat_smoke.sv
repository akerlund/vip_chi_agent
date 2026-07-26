class tc_chi_e_snf_dat_smoke extends chi_e_base_test;

  typedef vip_chi_item #(CHI_E_WIDE_CFG_C) item_t;

  `uvm_component_utils(tc_chi_e_snf_dat_smoke)

  vip_chi_pipelined_seq #(CHI_E_WIDE_CFG_C) snf_pipe_seq;

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // Opt out of the standalone scoreboard: this test drives SN-F completions
  // with no soliciting RN-I request, which the requester-frame lifecycle
  // checker would otherwise report as orphan completions.
  // ---------------------------------------------------------------------------
  // ---------------------------------------------------------------------------
  // Configure TB CFG
  // ---------------------------------------------------------------------------
  protected virtual function void configure_tb_cfg();

    super.configure_tb_cfg();

    super.tb_cfg.scoreboard_enable = 1'b0;
  endfunction

  // ---------------------------------------------------------------------------
  // Create the exact-CHI-E SN-F completion sequence once topology is ready.
  // ---------------------------------------------------------------------------
  function void start_of_simulation_phase(input uvm_phase phase);

    super.start_of_simulation_phase(phase);

    this.snf_pipe_seq = vip_chi_pipelined_seq #(CHI_E_WIDE_CFG_C)::type_id::create("snf_pipe_seq");
  endfunction

  // ---------------------------------------------------------------------------
  // Drive one exact-CHI-E data completion from the real SN-F agent (the RN-I
  // peer is present only to bring the link up and return credits) and verify
  // the monitored DAT item preserves the responder-side DAT tagging fields.
  // ---------------------------------------------------------------------------
  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t            comp_data_item;
    item_t            comp_item;
    item_t            dat_item;
    item_t            rsp_item;
    item_t::tag_t     tag_vals[];
    item_t::tu_t      tu_vals[];

    phase.raise_objection(this);

    tag_vals    = new[1];
    tu_vals     = new[1];
    tag_vals[0] = item_t::tag_t'('h2345);
    tu_vals[0]  = item_t::tu_t'('hc);

    comp_data_item = item_t::type_id::create("comp_data_item");
    comp_data_item.direction    = VIP_CHI_DIR_READ_E;
    comp_data_item.role         = VIP_CHI_ROLE_SNF_E;
    comp_data_item.src_id       = item_t::node_id_t'('h031);
    comp_data_item.tgt_id       = item_t::node_id_t'('h012);
    comp_data_item.txn_id       = item_t::txn_id_t'(8'h51);
    comp_data_item.dbid         = item_t::txn_id_t'(8'h51);
    comp_data_item.dat_opcode   = item_t::dat_opcode_t'(VIP_CHI_DAT_COMP_DATA_C);
    comp_data_item.rsp_resp     = VIP_CHI_RESP_STATE_I_E;
    comp_data_item.rsp_resp_err = VIP_CHI_RESP_ERR_NORMAL_OKAY_E;
    comp_data_item.qos          = 4'he;
    comp_data_item.data         = new[1];
    comp_data_item.be           = new[1];
    comp_data_item.data[0]      = item_t::data_t'('h1_2233_4455_6677_8899_aabb_ccdd_eeff);
    comp_data_item.be[0]        = '1;
    comp_data_item.set_dat_tagop(item_t::tagop_t'('h2));
    comp_data_item.set_tag(tag_vals);
    comp_data_item.set_tu(tu_vals);

    comp_item = item_t::type_id::create("comp_item");
    comp_item.direction    = VIP_CHI_DIR_READ_E;
    comp_item.role         = VIP_CHI_ROLE_SNF_E;
    comp_item.src_id       = item_t::node_id_t'('h031);
    comp_item.tgt_id       = item_t::node_id_t'('h012);
    comp_item.txn_id       = item_t::txn_id_t'(8'h52);
    comp_item.dbid         = item_t::txn_id_t'(8'h52);
    comp_item.rsp_opcode   = item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_C);
    comp_item.rsp_resp     = VIP_CHI_RESP_STATE_I_E;
    comp_item.rsp_resp_err = VIP_CHI_RESP_ERR_NORMAL_OKAY_E;
    comp_item.fwd_state    = '0;
    comp_item.qos          = 4'h7;

    this.snf_pipe_seq.reset();
    this.snf_pipe_seq.add_item(comp_data_item);
    this.snf_pipe_seq.add_item(comp_item);
    this.snf_pipe_seq.start(super.tb_env.snf_agent.sequencer);

    super.tb_env.snf_dat_fifo.get(dat_item);
    super.tb_env.snf_rsp_fifo.get(rsp_item);

    if (dat_item.role != VIP_CHI_ROLE_SNF_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Monitor observed wrong DAT role %0d",
        super.tc_name, dat_item.role))
    end

    if (dat_item.dat_opcode != item_t::dat_opcode_t'(VIP_CHI_DAT_COMP_DATA_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Monitor observed wrong DAT opcode 0x%0h",
        super.tc_name, dat_item.dat_opcode))
    end

    if ((dat_item.src_id != item_t::node_id_t'('h031)) ||
        (dat_item.tgt_id != item_t::node_id_t'('h012)) ||
        (dat_item.qos != 4'he)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Monitor observed wrong exact-CHI-E SN-F DAT routing fields",
        super.tc_name))
    end

    if ((dat_item.dat_tagop != item_t::tagop_t'('h2)) ||
        (dat_item.tag.size() != 1) ||
        (dat_item.tag[0] != item_t::tag_t'('h2345)) ||
        (dat_item.tu.size() != 1) ||
        (dat_item.tu[0] != item_t::tu_t'('hc))) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Monitor observed wrong exact-CHI-E SN-F DAT tagging fields",
        super.tc_name))
    end

    if (rsp_item.rsp_opcode != item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Monitor observed wrong RSP opcode 0x%0h",
        super.tc_name, rsp_item.rsp_opcode))
    end

    if ((rsp_item.src_id != item_t::node_id_t'('h031)) ||
        (rsp_item.tgt_id != item_t::node_id_t'('h012)) ||
        (rsp_item.qos != 4'h7)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Monitor observed wrong exact-CHI-E SN-F RSP fields",
        super.tc_name))
    end

    phase.drop_objection(this);
  endtask

endclass
