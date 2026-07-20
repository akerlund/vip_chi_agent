class tc_chi_d_hni_backpressure extends vip_chi_base_test;

  `uvm_component_utils(tc_chi_d_hni_backpressure)

  localparam int unsigned N_TXNS_C = 3;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // Build Phase
  //
  // Starve the SN-facing links: both proxy SN targets advertise only a single
  // inbound REQ and DAT credit, so the proxy's SN-facing send-credit managers
  // (sn_req_send_mgr / sn_dat_send_mgr) can only hold one outstanding REQ / one
  // outstanding write-DAT beat toward each SN at a time. Every proxied request
  // must therefore lock-step against the SN returning a fresh credit -- the
  // SN-facing analog of tc_chi_d_credit_starvation. Both targets are constrained
  // so the backpressure applies regardless of how the HN-I routes each address.
  // (Runtime credit-hold is RN-I only; the SN-F driver seeds its advertised
  // credits statically, so a constrained initial pool is the SN-side lever.)
  // ---------------------------------------------------------------------------
  function void build_phase(input uvm_phase phase);

    super.build_phase(phase);

    super.hsnf0_cfg.initial_req_credits = 1;
    super.hsnf0_cfg.initial_dat_credits = 1;
    super.hsnf1_cfg.initial_req_credits = 1;
    super.hsnf1_cfg.initial_dat_credits = 1;
  endfunction

  // ---------------------------------------------------------------------------
  // Run Phase
  //
  // Drive several write-then-read pairs through the proxy while the SN-facing
  // links are credit-starved. The proxy must serialize its forwarding against
  // the trickle of SN credits yet still relay every transaction end-to-end with
  // its payload intact -- proving it stalls and forwards correctly rather than
  // dropping, reordering, or corrupting flits under sustained backpressure.
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t write_responses[$];
    item_t read_responses[$];
    item_t::addr_t addr;
    item_t::data_t base_val;

    phase.raise_objection(this);

    @(posedge super.tb_env.hrni0_agent.vif.rst_n);
    super.wait_clocks(4);

    for (int unsigned i = 0; i < N_TXNS_C; i++) begin

      addr     = WRITE_READ_ADDR_C + item_t::addr_t'(i * 44'h100);
      base_val = item_t::data_t'('hb0) + item_t::data_t'(i * 16);

      super.rni0_wr_seq.reset();
      super.rni0_wr_seq.set_requests(1);
      super.rni0_wr_seq.set_initial_addr(addr);
      super.rni0_wr_seq.set_size(3'd6);
      super.rni0_wr_seq.set_allow_retry(1'b0);
      super.rni0_wr_seq.set_data_type(VIP_CHI_DATA_COUNTER_E);
      super.rni0_wr_seq.set_counter_value(base_val);
      super.rni0_wr_seq.set_counter_increment(item_t::data_t'('h1));
      super.rni0_wr_seq.set_get_response(1'b1);
      super.rni0_wr_seq.set_verbose(1'b0);
      super.rni0_wr_seq.start(super.v_sqr.hrni0_sequencer);

      write_responses = super.rni0_wr_seq.get_responses();
      if (write_responses.size() != 1) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] Write %0d expected 1 proxied completion under backpressure, got %0d",
          super.tc_name, i, write_responses.size()))
      end

      if (write_responses[0].rsp_opcode != item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_DBID_RESP_C)) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] Write %0d completion carried wrong opcode 0x%0h under backpressure",
          super.tc_name, i, write_responses[0].rsp_opcode))
      end

      super.rni0_rd_seq.reset();
      super.rni0_rd_seq.set_requests(1);
      super.rni0_rd_seq.set_initial_addr(addr);
      super.rni0_rd_seq.set_size(3'd6);
      super.rni0_rd_seq.set_allow_retry(1'b0);
      super.rni0_rd_seq.set_get_response(1'b1);
      super.rni0_rd_seq.set_verbose(1'b0);
      super.rni0_rd_seq.start(super.v_sqr.hrni0_sequencer);

      read_responses = super.rni0_rd_seq.get_responses();
      if (read_responses.size() != 1) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] Read %0d expected 1 proxied completion under backpressure, got %0d",
          super.tc_name, i, read_responses.size()))
      end

      if (read_responses[0].data.size() != 4) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] Read %0d returned %0d beats instead of 4 under backpressure",
          super.tc_name, i, read_responses[0].data.size()))
      end

      // Per-beat readback data integrity is now covered by the standalone
      // scoreboard (checker C write->read predictor; every byte compared here,
      // reads_skipped_unpredictable=0). The beat-count check above remains as
      // this test's structural intent.
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] HN-I proxy relayed %0d write+read pairs under SN-facing credit backpressure",
      super.tc_name, N_TXNS_C), UVM_LOW)

    phase.drop_objection(this);
  endtask
endclass
