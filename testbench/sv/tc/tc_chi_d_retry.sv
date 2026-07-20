class tc_chi_d_retry extends vip_chi_base_test;

  `uvm_component_utils(tc_chi_d_retry)

  localparam item_t::addr_t ADDR_C   = item_t::addr_t'(44'h3100_0000);
  localparam bit [2:0]      SIZE_C    = 3'd4;    // one 16-byte beat
  localparam int            SETTLE_C  = 20;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // Arm the SN-F to bounce the first retryable REQ once (RetryAck + PCrdGrant),
  // exercising the RN-I retry/hold/re-issue path. Serial driver (retry is not
  // wired into the multi-outstanding pipeline).
  // ---------------------------------------------------------------------------
  // ---------------------------------------------------------------------------
  // Configure Agent Cfgs
  // ---------------------------------------------------------------------------
  protected virtual function void configure_agent_cfgs();

    super.snf_cfg.force_retry_count = 1;
  endfunction

  // ---------------------------------------------------------------------------
  // Drive one retryable write, confirm it was bounced with RetryAck + PCrdGrant
  // and then re-issued to a normal CompDBIDResp completion, and read the data
  // back to prove the retried write actually committed.
  // ---------------------------------------------------------------------------
  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t::data_t data_q [$];
    item_t::data_t written;
    item_t wr_rsp [$];
    item_t rd_rsp [$];
    item_t obs;
    bit    saw_retry_ack;
    bit    saw_pcrd_grant;

    phase.raise_objection(this);

    written = item_t::data_t'('hCAFE_0001);
    data_q.push_back(written);

    // -- Retryable write. ------------------------------------------------------
    super.rni0_wr_seq.reset();
    super.rni0_wr_seq.set_initial_addr(ADDR_C);
    super.rni0_wr_seq.set_size(SIZE_C);
    super.rni0_wr_seq.set_allow_retry(1'b1);      // let the SN-F bounce it
    super.rni0_wr_seq.set_data(data_q);           // custom data => bounded by payload
    super.rni0_wr_seq.set_get_response(1'b1);
    super.rni0_wr_seq.set_verbose(1'b0);
    super.rni0_wr_seq.start(super.v_sqr.rni_sequencer);

    wr_rsp = super.rni0_wr_seq.get_responses();
    if (wr_rsp.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Expected 1 write response, got %0d",
        super.tc_name, wr_rsp.size()))
    end
    if (wr_rsp[0].rsp_opcode != item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_DBID_RESP_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Retried write completion opcode 0x%0h was not CompDBIDResp",
        super.tc_name, wr_rsp[0].rsp_opcode))
    end

    // The RN-I monitor observed every inbound RSP: a RetryAck and a PCrdGrant
    // must precede the final CompDBIDResp for a bounced-then-re-issued write.
    saw_retry_ack  = 1'b0;
    saw_pcrd_grant = 1'b0;
    while (super.tb_env.rni_rsp_fifo.try_get(obs)) begin
      if (obs.rsp_opcode == item_t::rsp_opcode_t'(VIP_CHI_RSP_RETRY_ACK_C)) begin
        saw_retry_ack = 1'b1;
      end
      if (obs.rsp_opcode == item_t::rsp_opcode_t'(VIP_CHI_RSP_PCRD_GRANT_C)) begin
        saw_pcrd_grant = 1'b1;
      end
    end
    if (!saw_retry_ack) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Retryable write was never bounced with a RetryAck",
        super.tc_name))
    end
    if (!saw_pcrd_grant) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RetryAck was not followed by a PCrdGrant",
        super.tc_name))
    end

    super.wait_clocks(SETTLE_C);

    // -- Read back and confirm the retried write committed. --------------------
    super.rni0_rd_seq.reset();
    super.rni0_rd_seq.set_requests(1);
    super.rni0_rd_seq.set_initial_addr(ADDR_C);
    super.rni0_rd_seq.set_size(SIZE_C);
    super.rni0_rd_seq.set_allow_retry(1'b0);
    super.rni0_rd_seq.set_get_response(1'b1);
    super.rni0_rd_seq.set_verbose(1'b0);
    super.rni0_rd_seq.start(super.v_sqr.rni_sequencer);

    rd_rsp = super.rni0_rd_seq.get_responses();
    if ((rd_rsp.size() != 1) || (rd_rsp[0].data.size() != 1)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Read-back did not return one data beat",
        super.tc_name))
    end
    if (rd_rsp[0].data[0] != written) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Retried write did not commit: read 0x%0h expected 0x%0h",
        super.tc_name, rd_rsp[0].data[0], written))
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] retryable write bounced (RetryAck + PCrdGrant), re-issued to CompDBIDResp, and committed (read-back 0x%0h)",
      super.tc_name, rd_rsp[0].data[0]), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
