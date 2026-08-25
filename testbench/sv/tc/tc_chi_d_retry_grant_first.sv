class tc_chi_d_retry_grant_first extends chi_base_test;

  `uvm_component_utils(tc_chi_d_retry_grant_first)

  localparam item_t::addr_t ADDR_C   = item_t::addr_t'(44'h3110_0000);
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
    super.snf_cfg.snf_pcrd_grant_before_ack = 1'b1;
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
    item_t::be_t   be_q   [$];
    item_t::data_t written;
    item_t wr_rsp [$];
    item_t rd_rsp [$];
    item_t obs;
    bit    saw_retry_ack;
    bit    saw_pcrd_grant;
    bit    grant_was_first;

    phase.raise_objection(this);

    written = item_t::data_t'('hCAFE_0002);
    data_q.push_back(written);

    // -- Retryable write. ------------------------------------------------------
    super.rni0_wr_seq.reset();
    super.rni0_wr_seq.set_initial_addr(ADDR_C);
    super.rni0_wr_seq.set_size(SIZE_C);
    super.rni0_wr_seq.set_allow_retry(1'b1);      // let the SN-F bounce it
    super.rni0_wr_seq.set_data(data_q);           // custom data => bounded by payload
    // Full byte enables for the seeded beat. This is what makes a sub-line write
    // legal: Table A-3 and Chapter 4 fix WriteNoSnpFull at a cache line length,
    // so a single-beat write has to be a WriteNoSnpPtl -- and a Ptl with every
    // byte enabled in its Size window is exactly "write these bytes". Supplying
    // BE is also what selects the Ptl opcode, and it keeps the enables
    // deterministic rather than randomized, which the readback depends on.
    be_q.push_back('1);
    super.rni0_wr_seq.set_be(be_q);
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

    // The ORDER is recorded, not just the presence of both. Without this the
    // testcase passes identically against a completer that ignored the knob and
    // sent RetryAck first -- which is to say, against no reordering at all, and
    // it would prove nothing about the requester absorbing one.
    saw_retry_ack  = 1'b0;
    saw_pcrd_grant = 1'b0;
    grant_was_first = 1'b0;
    while (super.tb_env.rni_rsp_fifo.try_get(obs)) begin
      if (obs.rsp_opcode == item_t::rsp_opcode_t'(VIP_CHI_RSP_RETRY_ACK_C)) begin
        saw_retry_ack = 1'b1;
      end
      if (obs.rsp_opcode == item_t::rsp_opcode_t'(VIP_CHI_RSP_PCRD_GRANT_C)) begin
        if (!saw_retry_ack && !saw_pcrd_grant) begin
          grant_was_first = 1'b1;
        end
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
        "FATAL [%s] The RetryAck's PCrdGrant was never observed",
        super.tc_name))
    end
    if (!grant_was_first) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] The PCrdGrant did not precede its RetryAck, so the reordering this testcase exists to absorb never happened on the wire",
        super.tc_name))
    end

    super.wait_clocks(SETTLE_C);

    // -- Read back and confirm the retried write committed. --------------------
    super.rni0_rd_seq.reset();
    super.rni0_rd_seq.set_requests(1);
    super.rni0_rd_seq.set_initial_addr(ADDR_C);
    super.rni0_rd_seq.set_size(SIZE_C);
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
