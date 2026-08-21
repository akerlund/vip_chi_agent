class tc_chi_d_hni_xbar extends chi_base_test;

  `uvm_component_utils(tc_chi_d_hni_xbar)

  localparam item_t::node_id_t RN0_NODE_ID_C = item_t::node_id_t'('h012);
  localparam item_t::node_id_t RN1_NODE_ID_C = item_t::node_id_t'('h013);

  // Addresses differ in bit 12 (the HN-I default SN decode bit) so RN0's address
  // routes to SN target 0 and RN1's to SN target 1.
  localparam item_t::addr_t    SN0_ADDR_C    = item_t::addr_t'(WRITE_READ_ADDR_C);
  localparam item_t::addr_t    SN1_ADDR_C    = item_t::addr_t'(WRITE_READ_ADDR_C + 'h1000);

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // RN0 targets an address that decodes to SN target 0; RN1 targets an address
  // that decodes to SN target 1. Verify:
  //   * each RN reads back its own payload (completion routed to the right RN),
  //   * SN-F 0 observed only RN0's address and SN-F 1 only RN1's address
  //     (request address decode routed to the right SN).
  // Traffic is sequential (serial SN-F responders); the crossbar structure
  // (2 RN links, 2 SN links, address-decoded REQ + node-id-routed completions)
  // is what is under test.
  // ---------------------------------------------------------------------------
  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t rn0_wr_rsp[$];
    item_t rn1_wr_rsp[$];
    item_t rn0_rd_rsp[$];
    item_t rn1_rd_rsp[$];
    item_t sn0_reqs[$];
    item_t sn1_reqs[$];
    item_t r;

    phase.raise_objection(this);

    // RN0 -> SN target 0.
    super.rni0_wr_seq.reset();
    super.rni0_wr_seq.set_requests(1);
    super.rni0_wr_seq.set_src_id(RN0_NODE_ID_C);
    super.rni0_wr_seq.set_initial_addr(SN0_ADDR_C);
    super.rni0_wr_seq.set_size(3'd6);
    super.rni0_wr_seq.set_data_type(VIP_CHI_DATA_COUNTER_E);
    super.rni0_wr_seq.set_counter_value(item_t::data_t'('he0));
    super.rni0_wr_seq.set_counter_increment(item_t::data_t'('h1));
    super.rni0_wr_seq.set_get_response(1'b1);
    super.rni0_wr_seq.start(super.v_sqr.hrni0_sequencer);

    // RN1 -> SN target 1.
    super.rni1_wr_seq.reset();
    super.rni1_wr_seq.set_requests(1);
    super.rni1_wr_seq.set_src_id(RN1_NODE_ID_C);
    super.rni1_wr_seq.set_initial_addr(SN1_ADDR_C);
    super.rni1_wr_seq.set_size(3'd6);
    super.rni1_wr_seq.set_data_type(VIP_CHI_DATA_COUNTER_E);
    super.rni1_wr_seq.set_counter_value(item_t::data_t'('hf0));
    super.rni1_wr_seq.set_counter_increment(item_t::data_t'('h1));
    super.rni1_wr_seq.set_get_response(1'b1);
    super.rni1_wr_seq.start(super.v_sqr.hrni1_sequencer);

    // Readbacks.
    super.rni0_rd_seq.reset();
    super.rni0_rd_seq.set_requests(1);
    super.rni0_rd_seq.set_src_id(RN0_NODE_ID_C);
    super.rni0_rd_seq.set_initial_addr(SN0_ADDR_C);
    super.rni0_rd_seq.set_size(3'd6);
    super.rni0_rd_seq.set_get_response(1'b1);
    super.rni0_rd_seq.start(super.v_sqr.hrni0_sequencer);

    super.rni1_rd_seq.reset();
    super.rni1_rd_seq.set_requests(1);
    super.rni1_rd_seq.set_src_id(RN1_NODE_ID_C);
    super.rni1_rd_seq.set_initial_addr(SN1_ADDR_C);
    super.rni1_rd_seq.set_size(3'd6);
    super.rni1_rd_seq.set_get_response(1'b1);
    super.rni1_rd_seq.start(super.v_sqr.hrni1_sequencer);

    rn0_wr_rsp = super.rni0_wr_seq.get_responses();
    rn1_wr_rsp = super.rni1_wr_seq.get_responses();
    rn0_rd_rsp = super.rni0_rd_seq.get_responses();
    rn1_rd_rsp = super.rni1_rd_seq.get_responses();

    if ((rn0_wr_rsp.size() != 1) || (rn1_wr_rsp.size() != 1) ||
        (rn0_rd_rsp.size() != 1) || (rn1_rd_rsp.size() != 1)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Expected one response per op; got wr(%0d,%0d) rd(%0d,%0d)",
        super.tc_name, rn0_wr_rsp.size(), rn1_wr_rsp.size(),
        rn0_rd_rsp.size(), rn1_rd_rsp.size()))
    end

    // Per-RN readback data integrity (each RN reads back its own payload) is now
    // covered by the standalone scoreboard: checker C compares every byte
    // (reads_skipped_unpredictable=0) and checker A binds each completion to its
    // requester. The address-decode routing proof below stays — it is this
    // test's intent.

    // Address decode routing: SN-F 0 must have seen only RN0's address, SN-F 1
    // only RN1's address (one write + one read request each).
    repeat (2) begin
      super.tb_env.hsnf0_req_fifo.get(r);
      sn0_reqs.push_back(r);
    end
    repeat (2) begin
      super.tb_env.hsnf1_req_fifo.get(r);
      sn1_reqs.push_back(r);
    end

    foreach (sn0_reqs[i]) begin
      if (sn0_reqs[i].addr != SN0_ADDR_C) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] SN-F 0 saw wrong address 0x%0h (expected 0x%0h) — mis-routed",
          super.tc_name, sn0_reqs[i].addr, SN0_ADDR_C))
      end
    end
    foreach (sn1_reqs[i]) begin
      if (sn1_reqs[i].addr != SN1_ADDR_C) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] SN-F 1 saw wrong address 0x%0h (expected 0x%0h) — mis-routed",
          super.tc_name, sn1_reqs[i].addr, SN1_ADDR_C))
      end
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] HN-I crossbar routed RN0->SN0 and RN1->SN1 by address, completions returned by node id",
      super.tc_name), UVM_LOW)

    phase.drop_objection(this);
  endtask
endclass
