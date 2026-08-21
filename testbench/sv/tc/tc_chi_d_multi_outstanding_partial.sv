class tc_chi_d_multi_outstanding_partial extends chi_base_test;

  `uvm_component_utils(tc_chi_d_multi_outstanding_partial)

  localparam int            N_C         = 6;
  localparam item_t::addr_t BASE_ADDR_C = item_t::addr_t'(44'h2A00_0000);

  // size 4 => 16 bytes => one 16-byte beat, so each partial write masks a single
  // beat and the read-back merge check stays one beat per address.
  localparam bit [2:0]      SIZE_C      = 3'd4;
  localparam int            STRIDE_C    = 16;   // 2**SIZE_C bytes per request

  // CompDBIDResp is granted before the SN-F commits, so let the masked writes
  // settle into the backing store before reading them back.
  localparam int            SETTLE_C    = 20;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // The masked image a partial write leaves against a zero background: enabled
  // bytes take the write data, disabled bytes stay zero (fresh addresses).
  // ---------------------------------------------------------------------------
  // ---------------------------------------------------------------------------
  // Expected Partial Data
  // ---------------------------------------------------------------------------
  protected function item_t::data_t expected_partial_data(
    input item_t::data_t write_data,
    input item_t::be_t   write_be
  );

    expected_partial_data = '0;
    for (int b = 0; b < CHI_D_CFG_C.DATA_BYTES_P; b++) begin
      if (write_be[b]) begin
        expected_partial_data[8*b +: 8] = write_data[8*b +: 8];
      end
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Enable the multi-outstanding pipeline on the RN-I and the buffered SN-F.
  // ---------------------------------------------------------------------------
  protected virtual function void configure_agent_cfgs();

    super.rni_cfg.multi_outstanding        = 1'b1;
    super.rni_cfg.multi_outstanding_write  = 1'b1;
    super.rni_cfg.max_outstanding_write    = N_C;
    super.snf_cfg.multi_outstanding        = 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Pipeline N partial (WriteNoSnpPtl) writes to distinct fresh addresses, each
  // with its own data and byte-enable mask, then read every address back and
  // confirm the masked merge image survived the overlapped, custom-BE data
  // bursts. Setting custom BE makes the write sequence emit WriteNoSnpPtl.
  // ---------------------------------------------------------------------------
  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t::data_t data_q [$];
    item_t::be_t   be_q   [$];
    item_t::data_t expected [item_t::addr_t];
    item_t         wr_rsp [$];
    item_t         rd_rsp [$];
    item_t         r;

    phase.raise_objection(this);

    // Build N distinct payload/BE pairs and the expected masked image per addr.
    for (int k = 0; k < N_C; k++) begin
      item_t::addr_t a;
      data_q.push_back(item_t::data_t'({4{(32'hAABB_0000 | k)}}));
      be_q.push_back(item_t::be_t'(16'hF00F ^ (16'h1 << k)));   // varied, non-zero
      a = item_t::addr_t'(BASE_ADDR_C + (k * STRIDE_C));
      expected[a] = this.expected_partial_data(data_q[k], be_q[k]);
    end

    // -- Phase 1: pipeline N partial writes. -----------------------------------
    super.rni0_wr_seq.reset();
    super.rni0_wr_seq.set_initial_addr(BASE_ADDR_C);
    super.rni0_wr_seq.set_size(SIZE_C);
    super.rni0_wr_seq.set_data(data_q);           // custom data => CUSTOM mode
    super.rni0_wr_seq.set_be(be_q);               // custom BE   => WriteNoSnpPtl
    super.rni0_wr_seq.set_get_response(1'b1);      // count is bounded by the payload
    super.rni0_wr_seq.set_pipelined_send(1'b1);
    super.rni0_wr_seq.set_verbose(1'b0);
    super.rni0_wr_seq.start(super.v_sqr.rni_sequencer);

    wr_rsp = super.rni0_wr_seq.get_responses();
    if (wr_rsp.size() != N_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Expected %0d partial-write responses, got %0d",
        super.tc_name, N_C, wr_rsp.size()))
    end
    foreach (wr_rsp[k]) begin
      if (wr_rsp[k].opcode != item_t::req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_PTL_C)) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] Write %0d was not WriteNoSnpPtl (opcode 0x%0h)",
          super.tc_name, k, wr_rsp[k].opcode))
      end
      if (wr_rsp[k].rsp_opcode != item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_DBID_RESP_C)) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] Partial write %0d carried wrong RSP opcode 0x%0h",
          super.tc_name, k, wr_rsp[k].rsp_opcode))
      end
    end

    super.wait_clocks(SETTLE_C);

    // -- Phase 2: read every address back and check the masked merge image. ----
    super.rni0_rd_seq.reset();
    super.rni0_rd_seq.set_requests(N_C);
    super.rni0_rd_seq.set_initial_addr(BASE_ADDR_C);
    super.rni0_rd_seq.set_size(SIZE_C);
    super.rni0_rd_seq.set_get_response(1'b1);
    super.rni0_rd_seq.set_pipelined_send(1'b1);
    super.rni0_rd_seq.set_verbose(1'b0);
    super.rni0_rd_seq.start(super.v_sqr.rni_sequencer);

    rd_rsp = super.rni0_rd_seq.get_responses();
    if (rd_rsp.size() != N_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Expected %0d read responses, got %0d",
        super.tc_name, N_C, rd_rsp.size()))
    end

    foreach (rd_rsp[k]) begin
      r = rd_rsp[k];
      if (r.dat_opcode != item_t::dat_opcode_t'(VIP_CHI_DAT_COMP_DATA_C)) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] Read %0d carried wrong DAT opcode 0x%0h",
          super.tc_name, k, r.dat_opcode))
      end
      if (!expected.exists(r.addr)) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] Read %0d addr 0x%0h has no matching partial write",
          super.tc_name, k, r.addr))
      end
      if (r.data[0] != expected[r.addr]) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] Partial merge mismatch addr 0x%0h: read 0x%0h expected 0x%0h",
          super.tc_name, r.addr, r.data[0], expected[r.addr]))
      end
    end

    if (super.rni_cfg.observed_peak_outstanding <= 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Partial writes did not overlap: peak in-flight was %0d (expected > 1)",
        super.tc_name, super.rni_cfg.observed_peak_outstanding))
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] %0d WriteNoSnpPtl writes pipelined; masked read-back verified; peak in-flight = %0d",
      super.tc_name, N_C, super.rni_cfg.observed_peak_outstanding), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
