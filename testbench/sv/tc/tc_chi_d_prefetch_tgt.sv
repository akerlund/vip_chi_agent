class tc_chi_d_prefetch_tgt extends chi_base_test;

  `uvm_component_utils(tc_chi_d_prefetch_tgt)

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // Verify PrefetchTgt is accepted as a no-completion hint.
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    chi_prefetch_tgt_seq seq;
    item_t                   req_item;
    item_t                   rsp_item;
    item_t                   responses[$];

    phase.raise_objection(this);

    seq = new("prefetch_tgt_seq");
    seq.reset();
    seq.set_requests(1);
    seq.set_initial_addr(READ_ADDR_C + item_t::addr_t'(44'h180));
    seq.set_size(3'd6);
    seq.set_get_response(1'b1);
    seq.set_verbose(1'b0);
    seq.start(super.v_sqr.rni_sequencer);

    responses = seq.get_responses();
    if (responses.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Expected 1 PrefetchTgt response item, got %0d",
        super.tc_name, responses.size()))
    end

    super.tb_env.rni_req_fifo.get(req_item);

    if (req_item.opcode != item_t::req_opcode_t'(VIP_CHI_REQ_PREFETCH_TGT_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Monitor observed wrong PrefetchTgt opcode 0x%0h",
        super.tc_name, req_item.opcode))
    end

    if (responses[0].opcode != item_t::req_opcode_t'(VIP_CHI_REQ_PREFETCH_TGT_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Sequence response item opcode 0x%0h was not PrefetchTgt",
        super.tc_name, responses[0].opcode))
    end

    if (responses[0].role != VIP_CHI_ROLE_RNI_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] PrefetchTgt should retire locally with RN-I role, got %0d",
        super.tc_name, responses[0].role))
    end

    repeat (4) begin
      @(super.tb_env.rni_agent.vif.monitor_cb);
    end

    if (super.tb_env.rni_rsp_fifo.try_get(rsp_item)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] PrefetchTgt unexpectedly produced an RSP item opcode 0x%0h",
        super.tc_name, rsp_item.rsp_opcode))
    end

    if (super.tb_env.rni_dat_fifo.used() != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] PrefetchTgt unexpectedly produced %0d DAT item(s)",
        super.tc_name, super.tb_env.rni_dat_fifo.used()))
    end

    phase.drop_objection(this);
  endtask
endclass