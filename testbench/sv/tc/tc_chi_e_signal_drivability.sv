class tc_chi_e_signal_drivability extends chi_e_base_test;

  typedef vip_chi_item #(CHI_E_WIDE_CFG_C) item_t;

  `uvm_component_utils(tc_chi_e_signal_drivability)

  vip_chi_pipelined_seq #(CHI_E_WIDE_CFG_C) snf_pipe_seq;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // Opt out of the standalone scoreboard: field-setter smoke plus SN-side
  // separated-return injection, with no complete requester transactions.

  // ---------------------------------------------------------------------------
  // Configure TB CFG
  // ---------------------------------------------------------------------------
  protected virtual function void configure_tb_cfg();

    super.configure_tb_cfg();

    super.tb_cfg.scoreboard_enable = 1'b0;
  endfunction

  // ---------------------------------------------------------------------------
  // Start Of Simulation Phase
  // ---------------------------------------------------------------------------
  function void start_of_simulation_phase(input uvm_phase phase);

    super.start_of_simulation_phase(phase);

    this.snf_pipe_seq = vip_chi_pipelined_seq #(CHI_E_WIDE_CFG_C)::type_id::create("snf_pipe_seq");
  endfunction

  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t req_item;
    item_t dat_item;
    item_t rsp_item;
    item_t comp_data_item;
    item_t comp_item;
    item_t::data_t data_beats[$];
    item_t::tag_t  req_tag_vals[];
    item_t::tu_t   req_tu_vals[];
    item_t::tag_t  rsp_tag_vals[];
    item_t::tu_t   rsp_tu_vals[];

    phase.raise_objection(this);

    // This test drives Order = 0b01 on a WRITE, which Table 13-25 marks
    // "Request accepted" and applicable only in a READ request from HN-F to SN-F
    // or HN-I to SN-I -- "Reserved in all other cases". That is deliberate and it
    // is the point: what this test proves is that the field reaches the wire
    // carrying the value the sequence asked for, whatever that value means.
    //
    // But a test whose passing criterion is "a non-conformant request was driven
    // correctly" is indistinguishable, in a regression report, from a test that
    // proves the VIP emits legal traffic. So the rule is turned down to
    // VIP_CHI_CHK_SEV_OFF_E rather than left to fail the run, and the count is
    // asserted at the end. OFF still evaluates and still tallies -- it only
    // suppresses the report -- so the non-conformance stays visible in the
    // end-of-test table and in the sweep's provoked list instead of being
    // silenced.
    //
    // The assertion is the half that matters. If the stimulus is ever changed to
    // a conformant Order, the rule stops firing, this assertion fails, and the
    // waiver comes out with it. That is the intended failure mode: a silenced
    // rule that stops firing must not look like a passing test.
    super.tb_env.rni_agent.vif.check_severity[VIP_CHI_CHK_REQ_ORDER_LEGAL_E] =
      VIP_CHI_CHK_SEV_OFF_E;
    super.tb_env.snf_agent.vif.check_severity[VIP_CHI_CHK_REQ_ORDER_LEGAL_E] =
      VIP_CHI_CHK_SEV_OFF_E;

    // Same waiver, same reason, for the Table 2-12 tuple rule. This test drives
    // MemAttr = 0x4'hc -- Cacheable with EWA deasserted -- and LikelyShared on a
    // WriteNoSnp, and the table lists neither: its Cacheable rows all carry
    // EWA = 1, and LikelyShared is 0/1 only on the two Snoopable rows.
    // IHI 0050 E section 2.9.5 is narrower still and names the opcodes that may
    // assert LikelyShared; WriteNoSnpFull is not among them.
    super.tb_env.rni_agent.vif.check_severity[VIP_CHI_CHK_REQ_ATTR_COMBINATION_LEGAL_E] =
      VIP_CHI_CHK_SEV_OFF_E;
    super.tb_env.snf_agent.vif.check_severity[VIP_CHI_CHK_REQ_ATTR_COMBINATION_LEGAL_E] =
      VIP_CHI_CHK_SEV_OFF_E;

    // And for the LikelyShared whitelist. Section 2.9.5 names the opcodes that
    // may assert the field and WriteNoSnpFull is not among them, so this is a
    // second, independent reason the same wire bit is non-conformant here -- the
    // tuple rule above faults it for being Non-snoopable, this one for the
    // opcode. Two rules, two reasons, both silenced and both asserted below.
    super.tb_env.rni_agent.vif.check_severity[VIP_CHI_CHK_REQ_LIKELY_SHARED_LEGAL_E] =
      VIP_CHI_CHK_SEV_OFF_E;
    super.tb_env.snf_agent.vif.check_severity[VIP_CHI_CHK_REQ_LIKELY_SHARED_LEGAL_E] =
      VIP_CHI_CHK_SEV_OFF_E;

    // And Endian, a fourth independent reason. Table A-3 makes the field
    // applicable only on the Atomics, and this test drives it on a WriteNoSnp.
    super.tb_env.rni_agent.vif.check_severity[VIP_CHI_CHK_REQ_ENDIAN_LEGAL_E] =
      VIP_CHI_CHK_SEV_OFF_E;
    super.tb_env.snf_agent.vif.check_severity[VIP_CHI_CHK_REQ_ENDIAN_LEGAL_E] =
      VIP_CHI_CHK_SEV_OFF_E;

    // And a fifth: AllowRetry deasserted with PCrdType 0x5 on a FIRST attempt.
    // Section 2.9.4 requires AllowRetry asserted the first time a transaction is
    // sent, and permits it deasserted only where a pre-allocated P-Credit is
    // being spent -- and nothing has granted this link a credit. Both halves of
    // the pair are here to prove the wires carry them, which is precisely the
    // non-conformance the rule exists to catch.
    super.tb_env.rni_agent.vif.check_severity[VIP_CHI_CHK_REQ_RETRY_SPENDS_GRANTED_CREDIT_E] =
      VIP_CHI_CHK_SEV_OFF_E;
    super.tb_env.snf_agent.vif.check_severity[VIP_CHI_CHK_REQ_RETRY_SPENDS_GRANTED_CREDIT_E] =
      VIP_CHI_CHK_SEV_OFF_E;

    super.drain_observation_fifos();

    req_tag_vals = new[1];
    req_tu_vals  = new[1];
    req_tag_vals[0] = item_t::tag_t'('h1234);
    req_tu_vals[0]  = item_t::tu_t'('h5);

    super.rni_wr_seq.reset();
    super.rni_wr_seq.set_requests(1);
    super.rni_wr_seq.set_initial_addr(E_DBID_RESP_ORD_ADDR_C + item_t::addr_t'('h200));
    super.rni_wr_seq.set_size(3'd6);
    super.rni_wr_seq.set_src_id(E_DBID_RESP_ORD_RNI_NODE_ID_C);
    super.rni_wr_seq.set_tgt_id(E_DBID_RESP_ORD_SNF_NODE_ID_C);
    super.rni_wr_seq.set_lp_id(item_t::lpid_t'('h55));
    super.rni_wr_seq.set_qos(4'hb);
    super.rni_wr_seq.set_ns(VIP_CHI_REQ_NON_SECURE_ACCESS_E);
    super.rni_wr_seq.set_order(VIP_CHI_ORDER_REQ_ACCEPTED_E);
    super.rni_wr_seq.set_mem_attr(4'hc);
    super.rni_wr_seq.set_allow_retry(1'b0);
    super.rni_wr_seq.set_exp_comp_ack(1'b1);
    super.rni_wr_seq.set_excl(1'b1);
    super.rni_wr_seq.set_pcrd_type(4'h5);
    super.rni_wr_seq.set_tracetag(1'b1);
    super.rni_wr_seq.set_dodwt(1'b1);
    super.rni_wr_seq.set_likelyshared(1'b1);
    super.rni_wr_seq.set_endian(1'b1);
    super.rni_wr_seq.set_group_id_ext(item_t::groupidext_t'('h2));
    super.rni_wr_seq.set_tagop(item_t::tagop_t'('h1));
    super.rni_wr_seq.set_dat_tagop(item_t::tagop_t'('h2));
    super.rni_wr_seq.set_tag(req_tag_vals);
    super.rni_wr_seq.set_tu(req_tu_vals);
    super.rni_wr_seq.set_get_response(1'b1);
    super.rni_wr_seq.set_verbose(1'b0);
    data_beats.push_back(item_t::data_t'('h0123_4567_89ab_cdef_fedc_ba98_7654_3210));
    super.rni_wr_seq.set_data(data_beats);
    super.rni_wr_seq.start(super.tb_env.rni_agent.sequencer);

    super.tb_env.rni_req_fifo.get(req_item);
    super.tb_env.rni_dat_fifo.get(dat_item);

    if ((req_item.src_id != E_DBID_RESP_ORD_RNI_NODE_ID_C) ||
        (req_item.tgt_id != E_DBID_RESP_ORD_SNF_NODE_ID_C) ||
        (req_item.lp_id  != item_t::lpid_t'('h55)) ||
        (req_item.qos    != 4'hb) ||
        (req_item.ns     != VIP_CHI_REQ_NON_SECURE_ACCESS_E) ||
        (req_item.order  != VIP_CHI_ORDER_REQ_ACCEPTED_E) ||
        (req_item.mem_attr != 4'hc) ||
        (req_item.allow_retry != 1'b0) ||
        (req_item.exp_comp_ack != 1'b1) ||
        (req_item.excl != 1'b1) ||
        (req_item.pcrd_type != 4'h5) ||
        (req_item.tracetag != 1'b1) ||
        (req_item.dodwt != 1'b1) ||
        (req_item.likelyshared != 1'b1) ||
        (req_item.endian != 1'b1) ||
        (req_item.group_id_ext != item_t::groupidext_t'('h2)) ||
        (req_item.tagop != item_t::tagop_t'('h1))) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] REQ setters did not reach the exact-E monitored request item",
        super.tc_name))
    end

    if ((dat_item.qos != 4'hb) ||
        (dat_item.dat_opcode != item_t::dat_opcode_t'(VIP_CHI_DAT_NCB_WR_DATA_COMP_ACK_C)) ||
        (dat_item.data.size() != 1) ||
        (dat_item.data[0] != item_t::data_t'('h0123_4567_89ab_cdef_fedc_ba98_7654_3210)) ||
        (dat_item.dat_tagop != item_t::tagop_t'('h2)) ||
        (dat_item.tag.size() != 1) ||
        (dat_item.tag[0] != item_t::tag_t'('h1234)) ||
        (dat_item.tu.size() != 1) ||
        (dat_item.tu[0] != item_t::tu_t'('h5))) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] DAT setters did not reach the exact-E monitored DAT item",
        super.tc_name))
    end

    super.rni_rd_seq.reset();
    super.rni_rd_seq.set_requests(1);
    super.rni_rd_seq.set_initial_addr(E_PERSIST_ADDR_C + item_t::addr_t'('h100));
    super.rni_rd_seq.set_size(3'd6);
    super.rni_rd_seq.set_src_id(E_PERSIST_RNI_NODE_ID_C);
    super.rni_rd_seq.set_tgt_id(E_PERSIST_SNF_NODE_ID_C);
    super.rni_rd_seq.set_return_nid(E_PERSIST_RNI_NODE_ID_C);
    super.rni_rd_seq.set_return_txn_id(item_t::txn_id_t'(8'h6a));
    super.rni_rd_seq.set_qos(4'h6);
    super.rni_rd_seq.set_sep_read(1'b1);
    super.rni_rd_seq.set_allow_retry(1'b0);
    super.rni_rd_seq.set_get_response(1'b1);
    super.rni_rd_seq.set_verbose(1'b0);
    super.rni_rd_seq.start(super.tb_env.rni_agent.sequencer);

    super.tb_env.rni_req_fifo.get(req_item);

    if ((req_item.opcode != item_t::req_opcode_t'(VIP_CHI_REQ_READ_NO_SNP_SEP_C)) ||
        (req_item.return_nid != E_PERSIST_RNI_NODE_ID_C) ||
        (req_item.return_txn_id != item_t::txn_id_t'(8'h6a)) ||
        (req_item.qos != 4'h6)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Separated-read setters did not reach the monitored request item",
        super.tc_name))
    end

    // The drivability checks above only care that the structured fields reached
    // the wire; clear the resulting integrated-harness observations before the
    // manual SN-F DAT/RSP phase below.
    super.drain_observation_fifos();

    rsp_tag_vals = new[1];
    rsp_tu_vals  = new[1];
    rsp_tag_vals[0] = item_t::tag_t'('h4321);
    rsp_tu_vals[0]  = item_t::tu_t'('ha);

    comp_data_item = item_t::type_id::create("comp_data_item");
    comp_data_item.direction    = VIP_CHI_DIR_READ_E;
    comp_data_item.role         = VIP_CHI_ROLE_SNF_E;
    comp_data_item.src_id       = E_MTE_SNF_NODE_ID_C;
    comp_data_item.tgt_id       = E_MTE_RNI_NODE_ID_C;
    comp_data_item.txn_id       = item_t::txn_id_t'(8'h71);
    comp_data_item.dbid         = item_t::txn_id_t'(8'h71);
    comp_data_item.dat_opcode   = item_t::dat_opcode_t'(VIP_CHI_DAT_COMP_DATA_C);
    comp_data_item.rsp_resp     = VIP_CHI_RESP_STATE_UC_E;
    comp_data_item.rsp_resp_err = VIP_CHI_RESP_ERR_DATA_ERROR_E;
    comp_data_item.qos          = 4'hd;
    comp_data_item.data         = new[1];
    comp_data_item.be           = new[1];
    comp_data_item.data[0]      = item_t::data_t'('hfeed_face_cafe_beef_dead_beef_0123_4567);
    comp_data_item.be[0]        = '1;
    comp_data_item.dat_resp     = new[1];
    comp_data_item.dat_resp_err = new[1];
    comp_data_item.dat_resp[0]      = VIP_CHI_RESP_STATE_UC_E;
    comp_data_item.dat_resp_err[0]  = VIP_CHI_RESP_ERR_DATA_ERROR_E;
    comp_data_item.set_dat_tagop(item_t::tagop_t'('h3));
    comp_data_item.set_tag(rsp_tag_vals);
    comp_data_item.set_tu(rsp_tu_vals);

    comp_item = item_t::type_id::create("comp_item");
    comp_item.direction    = VIP_CHI_DIR_READ_E;
    comp_item.role         = VIP_CHI_ROLE_SNF_E;
    comp_item.src_id       = E_MTE_SNF_NODE_ID_C;
    comp_item.tgt_id       = E_MTE_RNI_NODE_ID_C;
    comp_item.txn_id       = item_t::txn_id_t'(8'h72);
    comp_item.dbid         = item_t::txn_id_t'(8'h72);
    comp_item.rsp_opcode   = item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_C);
    comp_item.rsp_resp     = VIP_CHI_RESP_STATE_UC_E;
    comp_item.rsp_resp_err = VIP_CHI_RESP_ERR_NONDATA_ERROR_E;
    comp_item.fwd_state    = 3'h5;
    comp_item.qos          = 4'h7;

    this.snf_pipe_seq.reset();
    this.snf_pipe_seq.add_item(comp_data_item);
    this.snf_pipe_seq.add_item(comp_item);
    this.snf_pipe_seq.start(super.tb_env.snf_agent.sequencer);

    super.tb_env.snf_dat_fifo.get(dat_item);
    super.tb_env.snf_rsp_fifo.get(rsp_item);

    if ((dat_item.src_id != E_MTE_SNF_NODE_ID_C) ||
        (dat_item.tgt_id != E_MTE_RNI_NODE_ID_C) ||
        (dat_item.qos != 4'hd) ||
        (dat_item.dat_resp.size() != 1) ||
        (dat_item.dat_resp[0] != VIP_CHI_RESP_STATE_UC_E) ||
        (dat_item.dat_resp_err.size() != 1) ||
        (dat_item.dat_resp_err[0] != VIP_CHI_RESP_ERR_DATA_ERROR_E) ||
        (dat_item.dat_tagop != item_t::tagop_t'('h3)) ||
        (dat_item.tag[0] != item_t::tag_t'('h4321)) ||
        (dat_item.tu[0] != item_t::tu_t'('ha))) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] SN-F DAT fields did not reach the monitored DAT item",
        super.tc_name))
    end

    if ((rsp_item.src_id != E_MTE_SNF_NODE_ID_C) ||
        (rsp_item.tgt_id != E_MTE_RNI_NODE_ID_C) ||
        (rsp_item.qos != 4'h7) ||
        (rsp_item.dbid != item_t::txn_id_t'(8'h72)) ||
        (rsp_item.rsp_resp != VIP_CHI_RESP_STATE_UC_E) ||
        (rsp_item.rsp_resp_err != VIP_CHI_RESP_ERR_NONDATA_ERROR_E) ||
        (rsp_item.fwd_state != 3'h5)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] SN-F RSP fields did not reach the monitored RSP item",
        super.tc_name))
    end

    if ((super.tb_env.rni_agent.vif.check_fail_count[VIP_CHI_CHK_REQ_ORDER_LEGAL_E] == 0) ||
        (super.tb_env.snf_agent.vif.check_fail_count[VIP_CHI_CHK_REQ_ORDER_LEGAL_E] == 0)) begin
      `uvm_error(get_name(), $sformatf(
        "ERROR [%s] %s did not report the deliberately Reserved Order this test drives: rni_e=%0d snf_e=%0d. Either the stimulus is now conformant -- in which case drop the waiver above -- or the rule stopped evaluating, which is worse",
        super.tc_name, vip_chi_check_name(VIP_CHI_CHK_REQ_ORDER_LEGAL_E),
        super.tb_env.rni_agent.vif.check_fail_count[VIP_CHI_CHK_REQ_ORDER_LEGAL_E],
        super.tb_env.snf_agent.vif.check_fail_count[VIP_CHI_CHK_REQ_ORDER_LEGAL_E]))
    end

    if ((super.tb_env.rni_agent.vif.check_fail_count[VIP_CHI_CHK_REQ_ATTR_COMBINATION_LEGAL_E] == 0) ||
        (super.tb_env.snf_agent.vif.check_fail_count[VIP_CHI_CHK_REQ_ATTR_COMBINATION_LEGAL_E] == 0)) begin
      `uvm_error(get_name(), $sformatf(
        "ERROR [%s] %s did not report the deliberately illegal MemAttr/LikelyShared combination this test drives: rni_e=%0d snf_e=%0d. Either the stimulus is now conformant -- in which case drop the waiver above -- or the rule stopped evaluating, which is worse",
        super.tc_name, vip_chi_check_name(VIP_CHI_CHK_REQ_ATTR_COMBINATION_LEGAL_E),
        super.tb_env.rni_agent.vif.check_fail_count[VIP_CHI_CHK_REQ_ATTR_COMBINATION_LEGAL_E],
        super.tb_env.snf_agent.vif.check_fail_count[VIP_CHI_CHK_REQ_ATTR_COMBINATION_LEGAL_E]))
    end

    if ((super.tb_env.rni_agent.vif.check_fail_count[VIP_CHI_CHK_REQ_LIKELY_SHARED_LEGAL_E] == 0) ||
        (super.tb_env.snf_agent.vif.check_fail_count[VIP_CHI_CHK_REQ_LIKELY_SHARED_LEGAL_E] == 0)) begin
      `uvm_error(get_name(), $sformatf(
        "ERROR [%s] %s did not report the LikelyShared this test asserts on a WriteNoSnp: rni_e=%0d snf_e=%0d. Either the stimulus is now conformant -- in which case drop the waiver above -- or the rule stopped evaluating, which is worse",
        super.tc_name, vip_chi_check_name(VIP_CHI_CHK_REQ_LIKELY_SHARED_LEGAL_E),
        super.tb_env.rni_agent.vif.check_fail_count[VIP_CHI_CHK_REQ_LIKELY_SHARED_LEGAL_E],
        super.tb_env.snf_agent.vif.check_fail_count[VIP_CHI_CHK_REQ_LIKELY_SHARED_LEGAL_E]))
    end

    if ((super.tb_env.rni_agent.vif.check_fail_count[VIP_CHI_CHK_REQ_ENDIAN_LEGAL_E] == 0) ||
        (super.tb_env.snf_agent.vif.check_fail_count[VIP_CHI_CHK_REQ_ENDIAN_LEGAL_E] == 0)) begin
      `uvm_error(get_name(), $sformatf(
        "ERROR [%s] %s did not report the Endian this test asserts on a WriteNoSnp: rni_e=%0d snf_e=%0d. Either the stimulus is now conformant -- in which case drop the waiver above -- or the rule stopped evaluating, which is worse",
        super.tc_name, vip_chi_check_name(VIP_CHI_CHK_REQ_ENDIAN_LEGAL_E),
        super.tb_env.rni_agent.vif.check_fail_count[VIP_CHI_CHK_REQ_ENDIAN_LEGAL_E],
        super.tb_env.snf_agent.vif.check_fail_count[VIP_CHI_CHK_REQ_ENDIAN_LEGAL_E]))
    end

    if ((super.tb_env.rni_agent.vif.check_fail_count[VIP_CHI_CHK_REQ_RETRY_SPENDS_GRANTED_CREDIT_E] == 0) ||
        (super.tb_env.snf_agent.vif.check_fail_count[VIP_CHI_CHK_REQ_RETRY_SPENDS_GRANTED_CREDIT_E] == 0)) begin
      `uvm_error(get_name(), $sformatf(
        "ERROR [%s] %s did not report the AllowRetry/PCrdType pair this test drives on a first attempt: rni_e=%0d snf_e=%0d. Either the stimulus is now conformant -- in which case drop the waiver above -- or the rule stopped evaluating, which is worse",
        super.tc_name, vip_chi_check_name(VIP_CHI_CHK_REQ_RETRY_SPENDS_GRANTED_CREDIT_E),
        super.tb_env.rni_agent.vif.check_fail_count[VIP_CHI_CHK_REQ_RETRY_SPENDS_GRANTED_CREDIT_E],
        super.tb_env.snf_agent.vif.check_fail_count[VIP_CHI_CHK_REQ_RETRY_SPENDS_GRANTED_CREDIT_E]))
    end

    phase.drop_objection(this);
  endtask
endclass