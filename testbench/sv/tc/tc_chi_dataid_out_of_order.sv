// CHI identifies a data beat's position by its DataID, not by where it sits in
// the burst, so a completer may return the beats of one transfer in any order.
// With cfg.snf_reverse_dat_beats the SN-F returns them in DESCENDING DataID: the
// payload must still reassemble in address order, both in the item the monitor
// publishes and in the response the sequence reads back. Reassembling by arrival
// instead would leave both reversed and surface as a data mismatch pointing at
// the data path rather than at the reassembly.

class tc_chi_dataid_out_of_order extends chi_base_test;

  `uvm_component_utils(tc_chi_dataid_out_of_order)

  localparam int BEATS_C = 4;   // size 6 = 64 bytes over a 16-byte CHI-D bus

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // The DataID-ordering assertions hold this VIP's own in-order emission
  // convention, not a CHI rule. This test breaks the convention on purpose, so
  // stand exactly those checks down and leave every other check armed.
  // ---------------------------------------------------------------------------
  protected virtual function void configure_tb_cfg();

    super.configure_tb_cfg();
    super.tb_cfg.dat_reorder_allowed = 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Have the completer return the beats of a read in reverse DataID order.
  // ---------------------------------------------------------------------------
  protected virtual function void configure_agent_cfgs();

    super.configure_agent_cfgs();
    super.snf_cfg.snf_reverse_dat_beats = 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Read a full line back and require address-ordered payload on both paths.
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t req_item;
    item_t dat_item;
    item_t responses[$];
    item_t rsp_item;

    phase.raise_objection(this);

    super.rni0_rd_seq.reset();
    super.rni0_rd_seq.set_requests(1);
    super.rni0_rd_seq.set_initial_addr(READ_ADDR_C);
    super.rni0_rd_seq.set_size(3'd6);
    super.rni0_rd_seq.set_allow_retry(1'b0);
    super.rni0_rd_seq.set_get_response(1'b1);
    super.rni0_rd_seq.set_verbose(1'b0);
    super.rni0_rd_seq.start(super.v_sqr.rni_sequencer);

    responses = super.rni0_rd_seq.get_responses();
    if (responses.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Expected 1 read response, got %0d",
        super.tc_name, responses.size()))
    end
    rsp_item = responses[0];

    super.tb_env.rni_req_fifo.get(req_item);
    super.tb_env.rni_dat_fifo.get(dat_item);

    if (dat_item.data.size() != BEATS_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Monitor reassembled %0d beats, expected %0d",
        super.tc_name, dat_item.data.size(), BEATS_C))
    end

    // Placement is by DataID: every position is filled by the beat that names
    // it, so the recorded DataIDs read back in order regardless of arrival.
    foreach (dat_item.data_id[i]) begin
      if (int'(dat_item.data_id[i]) != i) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] Beat at position %0d carries DataID %0d - beats were not placed by DataID",
          super.tc_name, i, dat_item.data_id[i]))
      end
    end

    // Payload in ADDRESS order despite arrival in reverse order, on both the
    // monitor's reassembly and the requester's own response assembly.
    foreach (dat_item.data[i]) begin
      if (dat_item.data[i] != (item_t::data_t'(READ_ADDR_C) + item_t::data_t'(i))) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] Monitor beat %0d payload mismatch 0x%0h",
          super.tc_name, i, dat_item.data[i]))
      end
      if (rsp_item.data[i] != (item_t::data_t'(READ_ADDR_C) + item_t::data_t'(i))) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] Sequence response beat %0d payload mismatch 0x%0h",
          super.tc_name, i, rsp_item.data[i]))
      end
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] Reverse-DataID read burst reassembled in address order",
      super.tc_name), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
