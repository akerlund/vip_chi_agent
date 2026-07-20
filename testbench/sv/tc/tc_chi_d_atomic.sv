class tc_chi_d_atomic extends vip_chi_base_test;

  typedef vip_chi_item #(CHI_D_CFG_C) item_t;

  `uvm_component_utils(tc_chi_d_atomic)

  vip_chi_atomic_seq #(CHI_D_CFG_C) atomic_seq;

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // Create the dedicated atomic sequence handle.
  // ---------------------------------------------------------------------------
  function void start_of_simulation_phase(input uvm_phase phase);

    super.start_of_simulation_phase(phase);

    this.atomic_seq = vip_chi_atomic_seq #(CHI_D_CFG_C)::type_id::create("atomic_seq");
  endfunction

  // ---------------------------------------------------------------------------
  // Verify AtomicStore/Load/Swap/Compare against the integrated SN-F backing
  // store and check that non-store atomics return the original value.
  // ---------------------------------------------------------------------------
  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t request_item;
    item_t rsp_item;
    item_t dat_item;
    item_t dat_items[$];
    item_t sequence_responses[$];
    item_t read_responses[$];
    item_t::data_t data_beats[$];
    item_t::data_t initial_value;
    item_t::data_t store_operand;
    item_t::data_t load_operand;
    item_t::data_t swap_operand;
    item_t::data_t compare_operand;
    item_t::data_t compare_swap_value;
    item_t::data_t expected_after_store;
    item_t::data_t expected_after_load;
    item_t::size_t beat_size;

    phase.raise_objection(this);

    beat_size          = item_t::size_t'($clog2(CHI_D_CFG_C.DATA_BYTES_P));
    initial_value      = item_t::data_t'(ATOMIC_ADDR_C);
    store_operand      = item_t::data_t'('h10);
    load_operand       = item_t::data_t'('h03);
    swap_operand       = item_t::data_t'('h4455);
    compare_operand    = swap_operand;
    compare_swap_value = item_t::data_t'('h99aa);
    expected_after_store = initial_value + store_operand;
    expected_after_load  = expected_after_store + load_operand;

    this.atomic_seq.reset();
    this.atomic_seq.set_atomic_op(VIP_CHI_ATOMIC_OP_STORE_0_E);
    this.atomic_seq.set_requests(1);
    this.atomic_seq.set_initial_addr(ATOMIC_ADDR_C);
    this.atomic_seq.set_size(beat_size);
    this.atomic_seq.set_allow_retry(1'b0);
    this.atomic_seq.set_get_response(1'b1);
    this.atomic_seq.set_verbose(1'b0);
    data_beats.delete();
    data_beats.push_back(store_operand);
    this.atomic_seq.set_data(data_beats);
    this.atomic_seq.start(super.v_sqr.rni_sequencer);

    sequence_responses = this.atomic_seq.get_responses();
    if (sequence_responses.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Expected 1 AtomicStore response, got %0d",
        super.tc_name, sequence_responses.size()))
    end

    super.tb_env.rni_req_fifo.get(request_item);
  dat_items.delete();
  super.tb_env.rni_dat_fifo.get(dat_item);
  dat_items.push_back(dat_item);
    super.tb_env.rni_rsp_fifo.get(rsp_item);

    if (request_item.opcode != item_t::req_opcode_t'(VIP_CHI_REQ_ATOMIC_STORE_0_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] AtomicStore request opcode was 0x%0h",
        super.tc_name, request_item.opcode))
    end

    if ((dat_items[0].role != VIP_CHI_ROLE_RNI_E) ||
        (dat_items[0].data.size() != 1) ||
        (dat_items[0].data[0] != store_operand)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] AtomicStore operand DAT did not match the generated request",
        super.tc_name))
    end

    if (sequence_responses[0].rsp_opcode != item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_DBID_RESP_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] AtomicStore response opcode 0x%0h was not CompDBIDResp",
        super.tc_name, sequence_responses[0].rsp_opcode))
    end

    this.atomic_seq.reset();
    this.atomic_seq.set_atomic_op(VIP_CHI_ATOMIC_OP_LOAD_0_E);
    this.atomic_seq.set_requests(1);
    this.atomic_seq.set_initial_addr(ATOMIC_ADDR_C);
    this.atomic_seq.set_size(beat_size);
    this.atomic_seq.set_allow_retry(1'b0);
    this.atomic_seq.set_get_response(1'b1);
    this.atomic_seq.set_verbose(1'b0);
    data_beats.delete();
    data_beats.push_back(load_operand);
    this.atomic_seq.set_data(data_beats);
    this.atomic_seq.start(super.v_sqr.rni_sequencer);

    sequence_responses = this.atomic_seq.get_responses();
    if (sequence_responses.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Expected 1 AtomicLoad response, got %0d",
        super.tc_name, sequence_responses.size()))
    end

    super.tb_env.rni_req_fifo.get(request_item);
    super.tb_env.rni_rsp_fifo.get(rsp_item);
    dat_items.delete();
    repeat (2) begin
      super.tb_env.rni_dat_fifo.get(dat_item);
      dat_items.push_back(dat_item);
    end

    if (request_item.opcode != item_t::req_opcode_t'(VIP_CHI_REQ_ATOMIC_LOAD_0_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] AtomicLoad request opcode was 0x%0h",
        super.tc_name, request_item.opcode))
    end

    if ((rsp_item.rsp_opcode != item_t::rsp_opcode_t'(VIP_CHI_RSP_DBID_RESP_C)) &&
        (rsp_item.rsp_opcode != item_t::rsp_opcode_t'(VIP_CHI_RSP_DBID_RESP_ORD_C))) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] AtomicLoad grant opcode 0x%0h was not DBIDResp/DBIDRespOrd",
        super.tc_name, rsp_item.rsp_opcode))
    end

    if ((dat_items[0].role != VIP_CHI_ROLE_RNI_E) ||
        (dat_items[0].data.size() != 1) ||
        (dat_items[0].data[0] != load_operand)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] AtomicLoad operand DAT did not match the generated request",
        super.tc_name))
    end

    if ((dat_items[1].role != VIP_CHI_ROLE_SNF_E) ||
        (dat_items[1].data.size() != 1) ||
        (dat_items[1].data[0] != expected_after_store)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] AtomicLoad CompData did not carry the expected pre-op value",
        super.tc_name))
    end

    if ((sequence_responses[0].dat_opcode != item_t::dat_opcode_t'(VIP_CHI_DAT_COMP_DATA_C)) ||
        (sequence_responses[0].data.size() != 1) ||
        (sequence_responses[0].data[0] != expected_after_store)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] AtomicLoad did not return the expected pre-op value",
        super.tc_name))
    end

    this.atomic_seq.reset();
    this.atomic_seq.set_atomic_op(VIP_CHI_ATOMIC_OP_SWAP_E);
    this.atomic_seq.set_requests(1);
    this.atomic_seq.set_initial_addr(ATOMIC_ADDR_C);
    this.atomic_seq.set_size(beat_size);
    this.atomic_seq.set_allow_retry(1'b0);
    this.atomic_seq.set_get_response(1'b1);
    this.atomic_seq.set_verbose(1'b0);
    data_beats.delete();
    data_beats.push_back(swap_operand);
    this.atomic_seq.set_data(data_beats);
    this.atomic_seq.start(super.v_sqr.rni_sequencer);

    sequence_responses = this.atomic_seq.get_responses();
    if ((sequence_responses.size() != 1) ||
        (sequence_responses[0].data.size() != 1) ||
        (sequence_responses[0].data[0] != expected_after_load)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] AtomicSwap did not return the expected pre-swap value",
        super.tc_name))
    end

    super.tb_env.rni_req_fifo.get(request_item);
    super.tb_env.rni_rsp_fifo.get(rsp_item);
    dat_items.delete();
    repeat (2) begin
      super.tb_env.rni_dat_fifo.get(dat_item);
      dat_items.push_back(dat_item);
    end

    if (request_item.opcode != item_t::req_opcode_t'(VIP_CHI_REQ_ATOMIC_SWAP_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] AtomicSwap request opcode was 0x%0h",
        super.tc_name, request_item.opcode))
    end

    if ((dat_items[0].role != VIP_CHI_ROLE_RNI_E) ||
        (dat_items[0].data.size() != 1) ||
        (dat_items[0].data[0] != swap_operand)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] AtomicSwap operand DAT did not match the generated request",
        super.tc_name))
    end

    if ((dat_items[1].role != VIP_CHI_ROLE_SNF_E) ||
        (dat_items[1].data.size() != 1) ||
        (dat_items[1].data[0] != expected_after_load)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] AtomicSwap CompData did not carry the expected pre-swap value",
        super.tc_name))
    end

    this.atomic_seq.reset();
    this.atomic_seq.set_atomic_op(VIP_CHI_ATOMIC_OP_COMPARE_E);
    this.atomic_seq.set_requests(1);
    this.atomic_seq.set_initial_addr(ATOMIC_ADDR_C);
    // AtomicCompare Size is the COMBINED compare+swap size (IHI 0050): the two
    // beat_size operands span Size = beat_size + 1. [P2]
    this.atomic_seq.set_size(item_t::size_t'(beat_size + 1));
    this.atomic_seq.set_allow_retry(1'b0);
    this.atomic_seq.set_get_response(1'b1);
    this.atomic_seq.set_verbose(1'b0);
    data_beats.delete();
    data_beats.push_back(compare_operand);
    data_beats.push_back(compare_swap_value);
    this.atomic_seq.set_data(data_beats);
    this.atomic_seq.start(super.v_sqr.rni_sequencer);

    sequence_responses = this.atomic_seq.get_responses();
    if ((sequence_responses.size() != 1) ||
        (sequence_responses[0].data.size() != 1) ||
        (sequence_responses[0].data[0] != swap_operand)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] AtomicCompare did not return the expected pre-compare value",
        super.tc_name))
    end

    super.tb_env.rni_req_fifo.get(request_item);
    super.tb_env.rni_rsp_fifo.get(rsp_item);
    dat_items.delete();
    repeat (2) begin
      super.tb_env.rni_dat_fifo.get(dat_item);
      dat_items.push_back(dat_item);
    end

    if (request_item.opcode != item_t::req_opcode_t'(VIP_CHI_REQ_ATOMIC_COMPARE_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] AtomicCompare request opcode was 0x%0h",
        super.tc_name, request_item.opcode))
    end

    if ((dat_items[0].role != VIP_CHI_ROLE_RNI_E) ||
        (dat_items[0].data.size() != 2) ||
        (dat_items[0].data[0] != compare_operand) ||
        (dat_items[0].data[1] != compare_swap_value)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] AtomicCompare operand DAT did not carry compare and swap beats",
        super.tc_name))
    end

    // [P2] Spec-fidelity guard: the monitored REQ.Size must span the COMBINED
    // compare+swap payload, so chi_xfer_dat_beats(Size) equals the operand-DAT
    // beat count. Before the combined-Size fix the wire carried Size = one
    // operand, i.e. beats(Size)=1 for this 2-beat operand DAT, and this fires.
    if (vip_chi_types_pkg::chi_xfer_dat_beats(
          request_item.size, CHI_D_CFG_C.DATA_BYTES_P) != dat_items[0].data.size()) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] AtomicCompare REQ.Size %0d spans %0d beats but the operand DAT carried %0d",
        super.tc_name, request_item.size,
        vip_chi_types_pkg::chi_xfer_dat_beats(request_item.size, CHI_D_CFG_C.DATA_BYTES_P),
        dat_items[0].data.size()))
    end

    if ((dat_items[1].role != VIP_CHI_ROLE_SNF_E) ||
        (dat_items[1].data.size() != 1) ||
        (dat_items[1].data[0] != swap_operand)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] AtomicCompare CompData did not carry the expected pre-compare value",
        super.tc_name))
    end

    super.rni0_rd_seq.reset();
    super.rni0_rd_seq.set_requests(1);
    super.rni0_rd_seq.set_initial_addr(ATOMIC_ADDR_C);
    super.rni0_rd_seq.set_size(beat_size);
    super.rni0_rd_seq.set_allow_retry(1'b0);
    super.rni0_rd_seq.set_get_response(1'b1);
    super.rni0_rd_seq.set_verbose(1'b0);
    super.rni0_rd_seq.start(super.v_sqr.rni_sequencer);

    read_responses = super.rni0_rd_seq.get_responses();
    if ((read_responses.size() != 1) ||
        (read_responses[0].data.size() != 1) ||
        (read_responses[0].data[0] != compare_swap_value)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] AtomicCompare did not update the SN-F backing store",
        super.tc_name))
    end

    phase.drop_objection(this);
  endtask
endclass