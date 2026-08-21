class tc_chi_d_hni_fanin extends chi_base_test;

  `uvm_component_utils(tc_chi_d_hni_fanin)

  localparam item_t::node_id_t RN0_NODE_ID_C = item_t::node_id_t'('h012);
  localparam item_t::node_id_t RN1_NODE_ID_C = item_t::node_id_t'('h013);

  // Both addresses decode to the same SN target (they share address bit 12, the
  // HN-I default decode bit) so this stays a true single-SN fan-in.
  localparam item_t::addr_t    RN0_ADDR_C    = item_t::addr_t'(WRITE_READ_ADDR_C);
  localparam item_t::addr_t    RN1_ADDR_C    = item_t::addr_t'(WRITE_READ_ADDR_C + 'h40);

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // Drive one transaction from each RN through the shared proxy and confirm the
  // HN-I routes each SN-F completion back to the originating RN by node id: RN0
  // reads back its own payload, RN1 reads back its own (different) payload. A
  // routing bug would deliver a completion to the wrong RN, hanging that RN's
  // sequence (phase timeout) — so a clean pass proves node-id routing works.
  //
  // Traffic is issued one transaction at a time because the example SN-F is a
  // serial auto-responder; the fan-in structure (two RN links, one SN link,
  // arbitrated sends, routed completions) is what is under test here.
  // ---------------------------------------------------------------------------
  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t rn0_wr_rsp[$];
    item_t rn1_wr_rsp[$];
    item_t rn0_rd_rsp[$];
    item_t rn1_rd_rsp[$];

    phase.raise_objection(this);

    // RN0 write.
    super.rni0_wr_seq.reset();
    super.rni0_wr_seq.set_requests(1);
    super.rni0_wr_seq.set_src_id(RN0_NODE_ID_C);
    super.rni0_wr_seq.set_initial_addr(RN0_ADDR_C);
    super.rni0_wr_seq.set_size(3'd6);
    super.rni0_wr_seq.set_data_type(VIP_CHI_DATA_COUNTER_E);
    super.rni0_wr_seq.set_counter_value(item_t::data_t'('hc0));
    super.rni0_wr_seq.set_counter_increment(item_t::data_t'('h1));
    super.rni0_wr_seq.set_get_response(1'b1);
    super.rni0_wr_seq.start(super.v_sqr.hrni0_sequencer);

    // RN1 write (different node id, different address, different payload).
    super.rni1_wr_seq.reset();
    super.rni1_wr_seq.set_requests(1);
    super.rni1_wr_seq.set_src_id(RN1_NODE_ID_C);
    super.rni1_wr_seq.set_initial_addr(RN1_ADDR_C);
    super.rni1_wr_seq.set_size(3'd6);
    super.rni1_wr_seq.set_data_type(VIP_CHI_DATA_COUNTER_E);
    super.rni1_wr_seq.set_counter_value(item_t::data_t'('hd0));
    super.rni1_wr_seq.set_counter_increment(item_t::data_t'('h1));
    super.rni1_wr_seq.set_get_response(1'b1);
    super.rni1_wr_seq.start(super.v_sqr.hrni1_sequencer);

    // RN0 readback.
    super.rni0_rd_seq.reset();
    super.rni0_rd_seq.set_requests(1);
    super.rni0_rd_seq.set_src_id(RN0_NODE_ID_C);
    super.rni0_rd_seq.set_initial_addr(RN0_ADDR_C);
    super.rni0_rd_seq.set_size(3'd6);
    super.rni0_rd_seq.set_get_response(1'b1);
    super.rni0_rd_seq.start(super.v_sqr.hrni0_sequencer);

    // RN1 readback.
    super.rni1_rd_seq.reset();
    super.rni1_rd_seq.set_requests(1);
    super.rni1_rd_seq.set_src_id(RN1_NODE_ID_C);
    super.rni1_rd_seq.set_initial_addr(RN1_ADDR_C);
    super.rni1_rd_seq.set_size(3'd6);
    super.rni1_rd_seq.set_get_response(1'b1);
    super.rni1_rd_seq.start(super.v_sqr.hrni1_sequencer);

    rn0_wr_rsp = super.rni0_wr_seq.get_responses();
    rn1_wr_rsp = super.rni1_wr_seq.get_responses();
    rn0_rd_rsp = super.rni0_rd_seq.get_responses();
    rn1_rd_rsp = super.rni1_rd_seq.get_responses();

    if ((rn0_wr_rsp.size() != 1) || (rn1_wr_rsp.size() != 1)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Expected 1 write response per RN, got RN0=%0d RN1=%0d",
        super.tc_name, rn0_wr_rsp.size(), rn1_wr_rsp.size()))
    end

    if ((rn0_rd_rsp.size() != 1) || (rn1_rd_rsp.size() != 1)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Expected 1 read response per RN, got RN0=%0d RN1=%0d",
        super.tc_name, rn0_rd_rsp.size(), rn1_rd_rsp.size()))
    end

    // Each RN reading back its own payload — proof the completion was routed to
    // the correct RN port and carried the correct data end-to-end — is now
    // covered by the standalone scoreboard: checker C compares every byte
    // against the RN's own wire-observed write (reads_skipped_unpredictable=0),
    // and checker A binds each completion to its requester, so a return routed
    // to the wrong RN surfaces as an orphan/incomplete there.

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] HN-I fan-in relayed and routed both RN transactions (RN0+RN1 -> HN-I -> SN-F)",
      super.tc_name), UVM_LOW)

    phase.drop_objection(this);
  endtask
endclass
