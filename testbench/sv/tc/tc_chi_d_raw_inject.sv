class tc_chi_d_raw_inject extends vip_chi_base_test;

  `uvm_component_utils(tc_chi_d_raw_inject)

  vip_chi_raw_seq #(CHI_D_CFG_C) rni_raw_seq;
  vip_chi_raw_seq #(CHI_D_CFG_C) snf_raw_seq;

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // Opt out of the standalone scoreboard: this test injects raw partial/illegal
  // flits that do not form complete requester transactions by design.
  // ---------------------------------------------------------------------------
  // ---------------------------------------------------------------------------
  // Configure TB CFG
  // ---------------------------------------------------------------------------
  protected virtual function void configure_tb_cfg();

    super.configure_tb_cfg();

    super.tb_cfg.scoreboard_enable = 1'b0;
  endfunction

  // ---------------------------------------------------------------------------
  // Create the raw-flit helper sequences once topology is ready.
  // ---------------------------------------------------------------------------
  function void start_of_simulation_phase(input uvm_phase phase);

    super.start_of_simulation_phase(phase);

    this.rni_raw_seq = vip_chi_raw_seq #(CHI_D_CFG_C)::type_id::create("rni_raw_seq");
    this.snf_raw_seq = vip_chi_raw_seq #(CHI_D_CFG_C)::type_id::create("snf_raw_seq");
  endfunction

  // ---------------------------------------------------------------------------
  // Inject one raw illegal REQ on RN-I and one raw DAT/RSP pair on SN-F, then
  // verify the monitors observe the verbatim flit fields.
  // ---------------------------------------------------------------------------
  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t            req_item;
    item_t            dat_item;
    item_t            rsp_item;
    item_t::raw_req_t raw_req;
    item_t::raw_rsp_t raw_rsp;
    item_t::raw_dat_t raw_dat;

    phase.raise_objection(this);

    super.drain_observation_fifos();

    raw_req = '0;
    raw_req.txnid      = item_t::txn_id_t'(8'h61);
    raw_req.srcid      = RNI_NODE_ID_C;
    raw_req.tgtid      = SNF_NODE_ID_C;
    raw_req.opcode     = item_t::req_opcode_t'('h3f);
    raw_req.addr       = item_t::addr_t'(44'h1234_cafe000);
    raw_req.size       = item_t::size_t'(3'd2);
    raw_req.ns         = VIP_CHI_REQ_NON_SECURE_ACCESS_E;
    raw_req.allowretry = 1'b1;
    raw_req.qos        = 4'h5;

    raw_dat = '0;
    raw_dat.data       = item_t::data_t'('h0123_4567_89ab_cdef_fedc_ba98_7654_3210);
    raw_dat.be         = '1;
    raw_dat.dataid     = item_t::data_id_t'('0);
    raw_dat.ccid       = item_t::cc_id_t'('0);
    raw_dat.dbid       = item_t::txn_id_t'(8'h63);
    raw_dat.resp       = VIP_CHI_RESP_STATE_I_E;
    raw_dat.resperr    = VIP_CHI_RESP_ERR_NORMAL_OKAY_E;
    raw_dat.opcode     = item_t::dat_opcode_t'(VIP_CHI_DAT_COMP_DATA_C);
    raw_dat.txnid      = item_t::txn_id_t'(8'h63);
    raw_dat.srcid      = SNF_NODE_ID_C;
    raw_dat.tgtid      = RNI_NODE_ID_C;
    raw_dat.qos        = 4'h6;

    raw_rsp = '0;
    raw_rsp.dbid       = item_t::txn_id_t'(8'h62);
    raw_rsp.fwdstate   = '0;
    raw_rsp.resp       = VIP_CHI_RESP_STATE_I_E;
    raw_rsp.resperr    = VIP_CHI_RESP_ERR_NORMAL_OKAY_E;
    raw_rsp.opcode     = item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_C);
    raw_rsp.txnid      = item_t::txn_id_t'(8'h62);
    raw_rsp.srcid      = SNF_NODE_ID_C;
    raw_rsp.tgtid      = RNI_NODE_ID_C;
    raw_rsp.qos        = 4'h9;

    this.rni_raw_seq.reset();
    this.rni_raw_seq.add_raw_req(raw_req);
    this.rni_raw_seq.start(super.v_sqr.rni_sequencer);

    super.wait_clocks(2);

    this.snf_raw_seq.reset();
    this.snf_raw_seq.add_raw_dat(raw_dat);
    this.snf_raw_seq.add_raw_rsp(raw_rsp);
    this.snf_raw_seq.start(super.v_sqr.snf_sequencer);

    super.tb_env.rni_req_fifo.get(req_item);
    super.tb_env.snf_dat_fifo.get(dat_item);
    super.tb_env.snf_rsp_fifo.get(rsp_item);

    if (req_item.opcode != item_t::req_opcode_t'('h3f)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Monitor observed wrong raw REQ opcode 0x%0h",
        super.tc_name, req_item.opcode))
    end

    if ((req_item.addr != item_t::addr_t'(44'h1234_cafe000)) ||
        (req_item.txn_id != item_t::txn_id_t'(8'h61)) ||
        (req_item.qos != 4'h5)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Monitor observed wrong raw REQ fields",
        super.tc_name))
    end

    if (dat_item.data.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Monitor observed %0d raw DAT beats instead of 1",
        super.tc_name, dat_item.data.size()))
    end

    if ((dat_item.dat_opcode != item_t::dat_opcode_t'(VIP_CHI_DAT_COMP_DATA_C)) ||
        (dat_item.txn_id != item_t::txn_id_t'(8'h63)) ||
        (dat_item.dbid != item_t::txn_id_t'(8'h63)) ||
        (dat_item.qos != 4'h6) ||
        (dat_item.data[0] != item_t::data_t'('h0123_4567_89ab_cdef_fedc_ba98_7654_3210))) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Monitor observed wrong raw DAT fields",
        super.tc_name))
    end

    if ((rsp_item.rsp_opcode != item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_C)) ||
        (rsp_item.txn_id != item_t::txn_id_t'(8'h62)) ||
        (rsp_item.dbid != item_t::txn_id_t'(8'h62)) ||
        (rsp_item.qos != 4'h9)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Monitor observed wrong raw RSP fields",
        super.tc_name))
    end

    phase.drop_objection(this);
  endtask

endclass