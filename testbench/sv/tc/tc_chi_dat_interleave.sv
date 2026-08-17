// A DAT flit names its transaction in TxnID and its position in DataID, so a
// completer may interleave the beats of several reads on one DAT channel; CHI
// nowhere requires a transfer's beats to be contiguous. With
// cfg.dat_interleave_depth = 2 the SN-F drains two queued reads together, one
// beat each in turn, and both payloads must still arrive whole and in address
// order -- in the items the monitor publishes and in the responses the sequences
// read back.
//
// What this reaches that nothing else does: every receiver in the tree used to
// read the FLITPEND deassert as "this transfer ended", which is only the same
// thing while one transfer owns the channel. A receiver that keeps that
// assumption does not fail loudly here -- it staples one read's beats onto
// another's and reports a DATA MISMATCH, pointing at the data path rather than
// at its own reassembly.

class tc_chi_dat_interleave extends chi_base_test;

  `uvm_component_utils(tc_chi_dat_interleave)

  localparam int N_C     = 2;             // reads in flight = dat_interleave_depth
  localparam int BEATS_C = 4;             // size 6 = 64 bytes over a 16-byte bus
  localparam item_t::addr_t BASE_ADDR_C = item_t::addr_t'(44'h2700_0000);

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // Interleaving is legal, but it is not this VIP's own emission convention,
  // which the protocol checkers' burst-shape rules hold by default: TxnID
  // stability across a FLITPEND run, and the run's beat count. Stand those down.
  // The per-TxnID retirement, the credit rules and everything else keep checking
  // -- including the outstanding/TXSACTIVE pair, which is exactly what would
  // catch a checker that lost track of an interleaved transfer.
  // ---------------------------------------------------------------------------
  protected virtual function void configure_tb_cfg();

    super.configure_tb_cfg();
    super.tb_cfg.dat_interleave_allowed = 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Two reads in flight at the requester, and a completer that drains both
  // together one beat at a time. Round-robin rather than random so the expected
  // emission order is a fact this test can state, not a distribution it has to
  // sample.
  // ---------------------------------------------------------------------------
  protected virtual function void configure_agent_cfgs();

    super.configure_agent_cfgs();
    super.rni_cfg.multi_outstanding       = 1'b1;
    super.rni_cfg.multi_outstanding_mixed = 1'b1;
    super.rni_cfg.max_outstanding_read    = N_C;
    super.snf_cfg.multi_outstanding       = 1'b1;
    super.snf_cfg.dat_interleave_depth    = N_C;
    super.snf_cfg.dat_interleave_policy   = VIP_CHI_DAT_INTERLEAVE_ROUND_ROBIN_E;
  endfunction

  // ---------------------------------------------------------------------------
  // Pipeline two reads, then require both payloads whole on both reassembly
  // paths and require that the beats really did alternate on the wire.
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t           responses[$];
    item_t           rsp_item;
    item_t           dat_item;
    item_t           dat_items[$];
    item_t::addr_t   addr;
    item_t::data_t   base_data;
    item_t::txn_id_t log[$];
    item_t::txn_id_t distinct[$];
    int              switches;
    bit              seen_txn[item_t::txn_id_t];

    phase.raise_objection(this);

    super.rni0_rd_seq.reset();
    super.rni0_rd_seq.set_requests(N_C);
    super.rni0_rd_seq.set_initial_addr(BASE_ADDR_C);
    super.rni0_rd_seq.set_size(3'd6);
    super.rni0_rd_seq.set_allow_retry(1'b0);
    super.rni0_rd_seq.set_get_response(1'b1);
    super.rni0_rd_seq.set_pipelined_send(1'b1);
    super.rni0_rd_seq.set_verbose(1'b0);
    super.rni0_rd_seq.start(super.v_sqr.rni_sequencer);

    responses = super.rni0_rd_seq.get_responses();
    if (responses.size() != N_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Expected %0d read responses, got %0d",
        super.tc_name, N_C, responses.size()))
    end

    // Anti-vacuity, and the whole point of the test: the beats really did
    // alternate between the two transfers on the wire. Without this the payload
    // checks below pass just as happily on a completer that never interleaved.
    switches = super.tb_env.snf_agent.snf_driver.n_dat_stream_switches;
    if (switches == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] No interleaving reached the wire: the SN-F emitted every transfer's beats contiguously (switches=%0d)",
        super.tc_name, switches))
    end

    // Round-robin over two equal-length reads is a strict alternation, so the
    // emitted TxnID sequence is fully determined: A B A B A B A B.
    log = super.tb_env.snf_agent.snf_driver.dat_beat_txn_log;
    if (log.size() != (N_C * BEATS_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Expected %0d DAT beats on the wire, got %0d",
        super.tc_name, N_C * BEATS_C, log.size()))
    end
    foreach (log[i]) begin
      if (!seen_txn.exists(log[i])) begin
        seen_txn[log[i]] = 1'b1;
        distinct.push_back(log[i]);
      end
      if ((i > 0) && (log[i] == log[i - 1])) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] Round-robin emitted two consecutive beats of transfer 0x%0h at position %0d",
          super.tc_name, log[i], i))
      end
    end
    if (distinct.size() != N_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Expected beats from %0d distinct transfers, saw %0d",
        super.tc_name, N_C, distinct.size()))
    end

    // Both payloads whole and in address order, read back through the sequence.
    foreach (responses[k]) begin
      rsp_item = responses[k];
      addr     = rsp_item.addr;

      if (rsp_item.dat_opcode != item_t::dat_opcode_t'(VIP_CHI_DAT_COMP_DATA_C)) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] Read %0d carried DAT opcode 0x%0h, expected CompData",
          super.tc_name, k, rsp_item.dat_opcode))
      end
      if (rsp_item.data.size() != BEATS_C) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] Read %0d reassembled %0d beats, expected %0d",
          super.tc_name, k, rsp_item.data.size(), BEATS_C))
      end
      foreach (rsp_item.data[i]) begin
        if (int'(rsp_item.data_id[i]) != i) begin
          `uvm_fatal(get_name(), $sformatf(
            "FATAL [%s] Read %0d position %0d carries DataID %0d - beats were not placed by DataID",
            super.tc_name, k, i, rsp_item.data_id[i]))
        end
        if (rsp_item.data[i] != (item_t::data_t'(addr) + item_t::data_t'(i))) begin
          `uvm_fatal(get_name(), $sformatf(
            "FATAL [%s] Read %0d addr 0x%0h beat %0d payload 0x%0h, expected 0x%0h",
            super.tc_name, k, addr, i, rsp_item.data[i],
            (item_t::data_t'(addr) + item_t::data_t'(i))))
        end
      end
    end

    // And the same, independently, in what the monitor assembled off the wire.
    // The two are separate readers of the same interleaved stream: the sequence
    // response comes from the RN-I driver's collector, the item below from the
    // monitor's. Checking only one would leave the other free to staple beats
    // together unnoticed.
    for (int k = 0; k < N_C; k++) begin
      super.tb_env.rni_dat_fifo.get(dat_item);
      dat_items.push_back(dat_item);
    end

    foreach (dat_items[k]) begin
      dat_item = dat_items[k];

      if (dat_item.data.size() != BEATS_C) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] Monitor reassembled %0d beats for txn 0x%0h, expected %0d",
          super.tc_name, dat_item.data.size(), dat_item.txn_id, BEATS_C))
      end

      base_data = dat_item.data[0];
      foreach (dat_item.data[i]) begin
        if (int'(dat_item.data_id[i]) != i) begin
          `uvm_fatal(get_name(), $sformatf(
            "FATAL [%s] Monitor did not place txn 0x%0h by DataID: position %0d carries DataID %0d",
            super.tc_name, dat_item.txn_id, i, dat_item.data_id[i]))
        end
        // Contiguity against this transfer's OWN first beat: the payload of the
        // backing store is addr+beat, so beats stapled in from the other read
        // land on the wrong stride and show up here.
        if (dat_item.data[i] != (base_data + item_t::data_t'(i))) begin
          `uvm_fatal(get_name(), $sformatf(
            "FATAL [%s] Monitor txn 0x%0h beat %0d payload 0x%0h is not contiguous with beat 0 (0x%0h) - beats of two transfers were assembled into one",
            super.tc_name, dat_item.txn_id, i, dat_item.data[i], base_data))
        end
      end
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] %0d reads interleaved beat by beat (%0d stream switches), both payloads whole",
      super.tc_name, N_C, switches), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
