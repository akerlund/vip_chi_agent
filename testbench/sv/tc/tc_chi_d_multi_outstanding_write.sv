class tc_chi_d_multi_outstanding_write extends chi_base_test;

  `uvm_component_utils(tc_chi_d_multi_outstanding_write)

  // Enough writes that several REQs are in flight before the first completes.
  localparam int            N_WRITES_C     = 6;
  localparam item_t::addr_t WR_BASE_ADDR_C = item_t::addr_t'(44'h2400_0000);

  // size 6 => 64 bytes => 4 beats at 16 bytes/beat for the CHI-D cut.
  localparam bit [2:0]      WRITE_SIZE_C   = 3'd6;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // Turn on the opt-in multi-outstanding WRITE datapath for the point-to-point
  // RN-I and the buffered SN-F. Left off, every other test keeps the strict
  // serial path. The SN-F only needs multi_outstanding: its buffered loop
  // already services writes, and the capture thread keeps returning REQ credit
  // while a response is mid-flight, which is what lets the RN-I stack up REQs.
  // ---------------------------------------------------------------------------
  // ---------------------------------------------------------------------------
  // Configure Agent Cfgs
  // ---------------------------------------------------------------------------
  protected virtual function void configure_agent_cfgs();

    super.rni_cfg.multi_outstanding        = 1'b1;
    super.rni_cfg.multi_outstanding_write  = 1'b1;
    super.rni_cfg.max_outstanding_write    = N_WRITES_C;
    super.snf_cfg.multi_outstanding        = 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Launch N pipelined writes, confirm each returns its CompDBIDResp completion,
  // and confirm the writes actually overlapped in flight.
  // ---------------------------------------------------------------------------
  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t responses[$];
    item_t rsp;

    phase.raise_objection(this);

    super.rni0_wr_seq.reset();
    super.rni0_wr_seq.set_requests(N_WRITES_C);
    super.rni0_wr_seq.set_initial_addr(WR_BASE_ADDR_C);
    super.rni0_wr_seq.set_size(WRITE_SIZE_C);
    super.rni0_wr_seq.set_allow_retry(1'b0);
    super.rni0_wr_seq.set_get_response(1'b1);
    super.rni0_wr_seq.set_pipelined_send(1'b1);
    super.rni0_wr_seq.set_verbose(1'b0);
    super.rni0_wr_seq.start(super.v_sqr.rni_sequencer);

    responses = super.rni0_wr_seq.get_responses();

    if (responses.size() != N_WRITES_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Expected %0d write responses, got %0d",
        super.tc_name, N_WRITES_C, responses.size()))
    end

    foreach (responses[k]) begin
      rsp = responses[k];

      if (rsp.role != VIP_CHI_ROLE_SNF_E) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] Write %0d response carried wrong role %0d",
          super.tc_name, k, rsp.role))
      end

      if (rsp.rsp_opcode != item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_DBID_RESP_C)) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] Write %0d response carried wrong RSP opcode 0x%0h",
          super.tc_name, k, rsp.rsp_opcode))
      end

      if (rsp.rsp_resp_err != VIP_CHI_RESP_ERR_NORMAL_OKAY_E) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] Write %0d completed with error status 0x%0h",
          super.tc_name, k, rsp.rsp_resp_err))
      end
    end

    // The whole point of extending P4 to writes: the write REQs must have been
    // simultaneously in flight, not merely completed one after another.
    if (super.rni_cfg.observed_peak_outstanding <= 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Writes did not overlap: peak in-flight was %0d (expected > 1)",
        super.tc_name, super.rni_cfg.observed_peak_outstanding))
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] %0d pipelined writes completed; peak in-flight = %0d",
      super.tc_name, N_WRITES_C, super.rni_cfg.observed_peak_outstanding), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
