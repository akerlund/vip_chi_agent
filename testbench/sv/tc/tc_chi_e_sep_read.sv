class tc_chi_e_sep_read extends chi_e_base_test;

  typedef vip_chi_item #(CHI_E_WIDE_CFG_C) item_t;

  `uvm_component_utils(tc_chi_e_sep_read)

  // ReadNoSnpSep is CHI-E only, so this runs on the direct CHI-E pair env (its
  // scoreboard is #(CHI_E_WIDE_CFG_C), enabled by default).
  //
  // NOTE: these are plain packed-vector localparams cast at use, NOT
  // `item_t::<field>_t` typed constants. A class-scoped localparam whose type is
  // a parameterized-class-nested type hangs VCS vcs1fe code-gen indefinitely at
  // CHI-E flit width (see chi_tb_pkg convention: such constants live at
  // package scope). Casting a plain literal at the call site avoids that trap.
  localparam logic [10:0] RNI_NID_C           = 11'h15;
  localparam logic [10:0] SNF_NID_C           = 11'h2a;
  localparam logic [51:0] SEP_READ_ADDR_C     = 52'h0012_3456_7A00;

  // A ReturnTxnID deliberately DIFFERENT from the request TxnID, so the
  // DataSepResp data leg returns on a key the original request never used. This
  // is the exact case the scoreboard's sep-read return index must resolve without
  // a false orphan (data leg) or false incomplete (read never retires).
  localparam logic [7:0]  SEP_RETURN_TXN_ID_C = 8'h5A;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // Drive one separated read (ReadNoSnpSep) with ReturnTxnID != TxnID and confirm
  // it completes end-to-end. The scoreboard is on: if its Checker A did not match
  // the DataSepResp back to the request via the return index, it would emit an
  // orphan-DAT / incomplete-transaction UVM_ERROR and fail this test.
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t req_item;
    item_t responses[$];
    item_t rsp_item;
    item_t obs;
    bit    saw_read_receipt;
    bit    saw_resp_sep_data;

    phase.raise_objection(this);

    super.rni_rd_seq.reset();
    super.rni_rd_seq.set_requests(1);
    super.rni_rd_seq.set_initial_addr(item_t::addr_t'(SEP_READ_ADDR_C));
    super.rni_rd_seq.set_size(3'd6);
    super.rni_rd_seq.set_sep_read(1'b1);
    super.rni_rd_seq.set_src_id(item_t::node_id_t'(RNI_NID_C));
    super.rni_rd_seq.set_tgt_id(item_t::node_id_t'(SNF_NID_C));
    super.rni_rd_seq.set_return_nid(item_t::node_id_t'(RNI_NID_C));  // must == src_id (constraint)
    super.rni_rd_seq.set_return_txn_id(item_t::txn_id_t'(SEP_RETURN_TXN_ID_C));
    super.rni_rd_seq.set_get_response(1'b1);
    super.rni_rd_seq.set_verbose(1'b0);
    super.rni_rd_seq.start(super.tb_env.rni_agent.sequencer);

    responses = super.rni_rd_seq.get_responses();

    if (responses.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Expected 1 separated-read completion, got %0d",
        super.tc_name, responses.size()))
    end
    rsp_item = responses[0];

    super.tb_env.rni_req_fifo.get(req_item);

    if (req_item.opcode != item_t::req_opcode_t'(VIP_CHI_REQ_READ_NO_SNP_SEP_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Monitored REQ was not ReadNoSnpSep: 0x%0h",
        super.tc_name, req_item.opcode))
    end

    // The test is only meaningful if the return TxnID actually differs from the
    // request TxnID (otherwise the DataSepResp would match the primary ctx key
    // and the return-index path would never be exercised).
    if (req_item.return_txn_id != item_t::txn_id_t'(SEP_RETURN_TXN_ID_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] ReturnTxnID setter did not reach the wire (saw 0x%0h)",
        super.tc_name, req_item.return_txn_id))
    end
    if (req_item.return_txn_id == req_item.txn_id) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] ReturnTxnID == TxnID (0x%0h): test would not exercise the return index",
        super.tc_name, req_item.txn_id))
    end

    // The read completed on its data leg: DataSepResp, one wide CHI-E beat. That
    // it completed at all is the proof the scoreboard matched the return leg (a
    // false orphan/incomplete would already have failed the run).
    if (rsp_item.dat_opcode != item_t::dat_opcode_t'(VIP_CHI_DAT_DATA_SEP_RESP_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Separated-read completion carried wrong DAT opcode 0x%0h",
        super.tc_name, rsp_item.dat_opcode))
    end
    if (rsp_item.data.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Separated-read returned %0d beats instead of 1 (64 B = one wide beat)",
        super.tc_name, rsp_item.data.size()))
    end

    // Every RSP the link carried, not just the first: a stray RespSepData after
    // the receipt would still be a Home-only response emitted by a Slave.
    //
    // Appendix B Table B-3 gives RespSepData one From row, ICN(HN-F, HN-I), and
    // section 2.3.1 says it in prose -- "RespSepData is permitted from the Home
    // only". What the Slave owes instead is the ReadReceipt, for every
    // ReadNoSnpSep and not only for ordered ones. Asserted here as well as in
    // the scoreboard so a Home-only response reappearing on a Slave's link fails
    // at the point it is emitted.
    saw_read_receipt  = 1'b0;
    saw_resp_sep_data = 1'b0;
    while (super.tb_env.rni_rsp_fifo.try_get(obs)) begin
      if (obs.rsp_opcode == item_t::rsp_opcode_t'(VIP_CHI_RSP_READ_RECEIPT_C)) begin
        saw_read_receipt = 1'b1;
      end
      if (obs.rsp_opcode == item_t::rsp_opcode_t'(VIP_CHI_RSP_RESP_SEP_DATA_C)) begin
        saw_resp_sep_data = 1'b1;
      end
    end

    if (!saw_read_receipt) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the Slave owes a ReadReceipt for every ReadNoSnpSep and none was seen on the RSP channel",
        super.tc_name))
    end
    if (saw_resp_sep_data) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] a RespSepData was emitted on this link; section 2.3.1 permits it from the Home only",
        super.tc_name))
    end

    if (super.tb_env.scoreboard.get_check_fail_count(
          VIP_CHI_SB_CHK_ORIGINATOR_LEGAL_E) != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] CHI_SB_ORIGINATOR_LEGAL reported %0d violation(s) on conformant separated-read traffic",
        super.tc_name, super.tb_env.scoreboard.get_check_fail_count(
          VIP_CHI_SB_CHK_ORIGINATOR_LEGAL_E)))
    end

    // The stand-in is the one departure, and it must be the ONLY one: exactly
    // the ReadNoSnpSep REQ, nothing else on the link.
    if (super.tb_env.scoreboard.get_originator_standin() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the Home stand-in fired %0d time(s); it may cover the ReadNoSnpSep REQ and nothing else",
        super.tc_name, super.tb_env.scoreboard.get_originator_standin()))
    end
    if (super.tb_env.scoreboard.get_originator_skipped() != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %0d flit(s) on this link had no Appendix B row and were not judged at all",
        super.tc_name, super.tb_env.scoreboard.get_originator_skipped()))
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] separated read completed; scoreboard matched DataSepResp on ReturnTxnID 0x%0h (!= TxnID 0x%0h)",
      super.tc_name, req_item.return_txn_id, req_item.txn_id), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
