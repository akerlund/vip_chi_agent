class tc_chi_e_dbid_resp_ord extends chi_e_base_test;

  typedef vip_chi_item #(CHI_E_WIDE_CFG_C) item_t;

  `uvm_component_utils(tc_chi_e_dbid_resp_ord)

  // The scoreboard reports unconditionally, so the deliberate violation in the
  // second half below has to be demoted or sv_regression.sh's "UVM_ERROR : 0"
  // gate reads a working control as a failure.
  localparam string ORIG_ERR_PATTERN_C = "*may not originate*";

  chi_sb_rule_negctl_catcher sb_catcher;

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);
    this.sb_catcher = new("sb_originator_catcher");
    this.sb_catcher.add_expected(ORIG_ERR_PATTERN_C);

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
    int    standin_after_traffic;

    phase.raise_objection(this);

    super.rni_wr_seq.reset();
    super.rni_wr_seq.set_requests(1);
    super.rni_wr_seq.set_initial_addr(E_DBID_RESP_ORD_ADDR_C);
    super.rni_wr_seq.set_size(3'd6);
    super.rni_wr_seq.set_src_id(E_DBID_RESP_ORD_RNI_NODE_ID_C);
    super.rni_wr_seq.set_tgt_id(E_DBID_RESP_ORD_SNF_NODE_ID_C);
    super.rni_wr_seq.set_qos(4'he);
    super.rni_wr_seq.set_order(VIP_CHI_ORDER_REQ_ORDER_E);
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

    // -------------------------------------------------------------------------
    // Appendix B, both directions of the claim.
    //
    // Table B-3 gives DBIDRespOrd ONE From row, ICN(HN-F, HN-I, MN), while plain
    // DBIDResp has three including "SN-F -> ... RN-I". So the response this test
    // exists to prove is one a Slave may not send in a real system: section 2.6
    // makes it a Point of Serialization guarantee, and a Slave is not the PoS
    // for other Requesters. On this two-node link it is the only ordering point
    // there is, which is why the checker grants it the stand-in -- and why the
    // grant has to be visible rather than assumed.
    //
    // CHI_SB_ORIGINATOR_LEGAL found this HERE, on its first sweep, before anyone
    // had read Table B-3 for DBIDRespOrd. See F-CORR-013.
    // -------------------------------------------------------------------------
    if (super.tb_env.scoreboard.get_check_fail_count(
          VIP_CHI_SB_CHK_ORIGINATOR_LEGAL_E) != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Appendix B reported %0d violation(s) on ordered write traffic the stand-in is supposed to cover",
        super.tc_name, super.tb_env.scoreboard.get_check_fail_count(
          VIP_CHI_SB_CHK_ORIGINATOR_LEGAL_E)))
    end

    standin_after_traffic = super.tb_env.scoreboard.get_originator_standin();
    if (standin_after_traffic < 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the completer-side stand-in never fired, so this test proves nothing about DBIDRespOrd's originator",
        super.tc_name))
    end

    // And the other direction: with the stand-in switched off the same response
    // must be REPORTED. Without this the check above is satisfied by a rule that
    // permits DBIDRespOrd from anyone.
    uvm_report_cb::add(null, this.sb_catcher);
    super.tb_env.scoreboard.expect_failure(VIP_CHI_SB_CHK_ORIGINATOR_LEGAL_E);
    super.tb_env.scoreboard.home_standin = 1'b0;
    super.drain_observation_fifos();

    super.rni_wr_seq.reset();
    super.rni_wr_seq.set_requests(1);
    super.rni_wr_seq.set_initial_addr(E_DBID_RESP_ORD_ADDR_C + 'h100);
    super.rni_wr_seq.set_size(3'd6);
    super.rni_wr_seq.set_src_id(E_DBID_RESP_ORD_RNI_NODE_ID_C);
    super.rni_wr_seq.set_tgt_id(E_DBID_RESP_ORD_SNF_NODE_ID_C);
    super.rni_wr_seq.set_order(VIP_CHI_ORDER_REQ_ORDER_E);
    super.rni_wr_seq.set_exp_comp_ack(1'b1);
    super.rni_wr_seq.set_get_response(1'b1);
    super.rni_wr_seq.set_verbose(1'b0);
    super.rni_wr_seq.start(super.tb_env.rni_agent.sequencer);
    super.wait_clocks(20);

    uvm_report_cb::delete(null, this.sb_catcher);

    if (super.tb_env.scoreboard.get_check_fail_count(
          VIP_CHI_SB_CHK_ORIGINATOR_LEGAL_E) == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] with the Home stand-in switched off, a Slave's DBIDRespOrd must be reported: Table B-3 permits it from the ICN only",
        super.tc_name))
    end

    if (super.tb_env.scoreboard.get_originator_standin() != standin_after_traffic) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the stand-in fired again after being switched off",
        super.tc_name))
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] DBIDRespOrd covered by the completer-side Home stand-in %0d time(s), and reported %0d time(s) with it off",
      super.tc_name, standin_after_traffic,
      super.tb_env.scoreboard.get_check_fail_count(
        VIP_CHI_SB_CHK_ORIGINATOR_LEGAL_E)), UVM_LOW)

    phase.drop_objection(this);
  endtask
endclass