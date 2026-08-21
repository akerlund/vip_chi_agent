class tc_chi_d_hni_sam extends chi_base_test;

  `uvm_component_utils(tc_chi_d_hni_sam)

  localparam item_t::node_id_t RN0_NODE_ID_C = item_t::node_id_t'('h012);
  localparam item_t::node_id_t RN1_NODE_ID_C = item_t::node_id_t'('h013);

  // Both addresses share address bit 12 (= 0), so the HN-I *default* stride
  // decode would route both to SN target 0. Only the configured SAM ranges below
  // split them across the two SN targets — so a clean pass proves the SAM range
  // table (not the fallback stride) drove the routing.
  localparam item_t::addr_t    SN0_ADDR_C    = item_t::addr_t'(44'h3000_8000);
  localparam item_t::addr_t    SN1_ADDR_C    = item_t::addr_t'(44'h3001_8000);

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // Publish a configurable SAM to the HN-I proxy before it builds: two explicit
  // 64 KB address ranges mapping to SN targets 0 and 1.
  // ---------------------------------------------------------------------------
  // ---------------------------------------------------------------------------
  // Build Phase
  // ---------------------------------------------------------------------------
  function void build_phase(input uvm_phase phase);

    vip_chi_hni_sam sam;

    super.build_phase(phase);

    sam = vip_chi_hni_sam::type_id::create("hni_sam");
    sam.default_port = 0;
    sam.add_range(64'h3000_0000, 64'h3000_FFFF, 0);
    sam.add_range(64'h3001_0000, 64'h3001_FFFF, 1);

    uvm_config_db #(vip_chi_hni_sam)::set(this, "env.hni_agent", "sam", sam);
  endfunction

  // ---------------------------------------------------------------------------
  // Same crossbar checks as tc_chi_d_hni_xbar, but the SN split is driven by the
  // SAM ranges rather than the address stride.
  // ---------------------------------------------------------------------------
  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t rn0_rd_rsp[$];
    item_t rn1_rd_rsp[$];
    item_t sn0_reqs[$];
    item_t sn1_reqs[$];
    item_t r;

    phase.raise_objection(this);

    super.rni0_wr_seq.reset();
    super.rni0_wr_seq.set_requests(1);
    super.rni0_wr_seq.set_src_id(RN0_NODE_ID_C);
    super.rni0_wr_seq.set_initial_addr(SN0_ADDR_C);
    super.rni0_wr_seq.set_size(3'd6);
    super.rni0_wr_seq.set_data_type(VIP_CHI_DATA_COUNTER_E);
    super.rni0_wr_seq.set_counter_value(item_t::data_t'('h30));
    super.rni0_wr_seq.set_counter_increment(item_t::data_t'('h1));
    super.rni0_wr_seq.set_get_response(1'b1);
    super.rni0_wr_seq.start(super.v_sqr.hrni0_sequencer);

    super.rni1_wr_seq.reset();
    super.rni1_wr_seq.set_requests(1);
    super.rni1_wr_seq.set_src_id(RN1_NODE_ID_C);
    super.rni1_wr_seq.set_initial_addr(SN1_ADDR_C);
    super.rni1_wr_seq.set_size(3'd6);
    super.rni1_wr_seq.set_data_type(VIP_CHI_DATA_COUNTER_E);
    super.rni1_wr_seq.set_counter_value(item_t::data_t'('h50));
    super.rni1_wr_seq.set_counter_increment(item_t::data_t'('h1));
    super.rni1_wr_seq.set_get_response(1'b1);
    super.rni1_wr_seq.start(super.v_sqr.hrni1_sequencer);

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

    rn0_rd_rsp = super.rni0_rd_seq.get_responses();
    rn1_rd_rsp = super.rni1_rd_seq.get_responses();

    if ((rn0_rd_rsp.size() != 1) || (rn1_rd_rsp.size() != 1)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Expected 1 read response per RN, got RN0=%0d RN1=%0d",
        super.tc_name, rn0_rd_rsp.size(), rn1_rd_rsp.size()))
    end

    // Per-RN readback data integrity (each RN reads back its own payload) is now
    // covered by the standalone scoreboard: checker C compares every byte
    // (reads_skipped_unpredictable=0) and checker A binds each completion to its
    // requester. The SAM routing proof below stays — it is this test's intent.

    // SAM routing proof: SN-F 0 saw only SN0_ADDR_C, SN-F 1 only SN1_ADDR_C.
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
          "FATAL [%s] SN-F 0 saw 0x%0h (expected 0x%0h) — SAM mis-routed",
          super.tc_name, sn0_reqs[i].addr, SN0_ADDR_C))
      end
    end
    foreach (sn1_reqs[i]) begin
      if (sn1_reqs[i].addr != SN1_ADDR_C) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] SN-F 1 saw 0x%0h (expected 0x%0h) — SAM mis-routed",
          super.tc_name, sn1_reqs[i].addr, SN1_ADDR_C))
      end
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] HN-I SAM range table routed RN0->SN0 and RN1->SN1 (addresses share the default stride bit)",
      super.tc_name), UVM_LOW)

    phase.drop_objection(this);
  endtask
endclass
