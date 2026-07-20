class tc_chi_d_hni_reset extends vip_chi_base_test;

  `uvm_component_utils(tc_chi_d_hni_reset)

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // Build Phase
  //
  // Hold the RN-facing and SN-facing DAT credit pools at one apiece so a stalled
  // read parks cleanly in flight (the same stall shape tc_chi_d_reset uses on the
  // integrated pair), giving a deterministic mid-proxy reset point.
  // ---------------------------------------------------------------------------
  function void build_phase(input uvm_phase phase);

    super.build_phase(phase);

    super.hrni0_cfg.initial_dat_credits = 1;
    super.hsnf0_cfg.initial_dat_credits = 1;
  endfunction

  // ---------------------------------------------------------------------------
  // Run Phase
  //
  // Reset a proxy link while traffic is straddling the HN-I: park a read in
  // flight (its completion held at the RN-facing port, its request already
  // forwarded to the SN), pulse reset, and confirm the proxy's all-links watcher
  // tears the in-flight transaction down cleanly (the stalled sequence unwinds)
  // and then restarts -- a fresh write+read relays end-to-end with intact data.
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    vip_chi_read_seq #(CHI_D_CFG_C) inflight_seq;
    item_t                        snf_req;
    item_t                        snf_reqs[$];
    item_t                        drain_item;
    item_t                        write_responses[$];
    item_t                        read_responses[$];
    bit                           inflight_done;
    bit                           inflight_recovered;

    phase.raise_objection(this);

    @(posedge super.tb_env.hrni0_agent.vif.rst_n);
    super.wait_clocks(4);

    // Freeze the RN-facing DAT completions so the second read parks in flight
    // with its request already relayed to the SN behind the proxy.
    super.hrni0_cfg.hold_dat_credit = 1'b1;

    inflight_seq = vip_chi_read_seq #(CHI_D_CFG_C)::type_id::create("inflight_seq");
    inflight_seq.reset();
    inflight_seq.set_requests(2);
    inflight_seq.set_initial_addr(WRITE_READ_ADDR_C);
    inflight_seq.set_size(3'd6);
    inflight_seq.set_allow_retry(1'b0);
    inflight_seq.set_get_response(1'b1);
    inflight_seq.set_verbose(1'b0);

    inflight_done = 1'b0;
    fork
      begin
        inflight_seq.start(super.v_sqr.hrni0_sequencer);
        inflight_done = 1'b1;
      end
    join_none

    // Block until the proxy has actually forwarded a request to the SN: now
    // there is genuine in-flight traffic straddling the HN-I when reset lands.
    super.tb_env.hsnf0_req_fifo.get(snf_req);

    // Reset the links mid-flight and release the credit hold so the RN-I driver
    // can unwind the parked sequence during reset handling.
    super.tb_cfg.request_reset_pulse(3);
    super.hrni0_cfg.hold_dat_credit = 1'b0;

    @(negedge super.tb_env.hrni0_agent.vif.rst_n);
    @(posedge super.tb_env.hrni0_agent.vif.rst_n);

    // Clean teardown: the in-flight sequence must unwind (not hang) once the
    // proxy tears down and the RN-facing link resets.
    inflight_recovered = 1'b0;
    repeat (40) begin
      if (inflight_done) begin
        inflight_recovered = 1'b1;
        break;
      end
      super.wait_clocks(1);
    end

    if (!inflight_recovered) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] In-flight proxy read did not unwind after the mid-proxy reset",
        super.tc_name))
    end

    super.wait_clocks(4);
    super.drain_observation_fifos();
    while (super.tb_env.hsnf0_req_fifo.try_get(drain_item)) begin end
    while (super.tb_env.hsnf1_req_fifo.try_get(drain_item)) begin end

    // Restart: a fresh write+read must relay end-to-end through the recovered
    // proxy, and the SN must observe both forwarded requests.
    super.rni0_wr_seq.reset();
    super.rni0_wr_seq.set_requests(1);
    super.rni0_wr_seq.set_initial_addr(WRITE_READ_ADDR_C);
    super.rni0_wr_seq.set_size(3'd6);
    super.rni0_wr_seq.set_allow_retry(1'b0);
    super.rni0_wr_seq.set_data_type(VIP_CHI_DATA_COUNTER_E);
    super.rni0_wr_seq.set_counter_value(item_t::data_t'('h50));
    super.rni0_wr_seq.set_counter_increment(item_t::data_t'('h1));
    super.rni0_wr_seq.set_get_response(1'b1);
    super.rni0_wr_seq.set_verbose(1'b0);
    super.rni0_wr_seq.start(super.v_sqr.hrni0_sequencer);

    super.rni0_rd_seq.reset();
    super.rni0_rd_seq.set_requests(1);
    super.rni0_rd_seq.set_initial_addr(WRITE_READ_ADDR_C);
    super.rni0_rd_seq.set_size(3'd6);
    super.rni0_rd_seq.set_allow_retry(1'b0);
    super.rni0_rd_seq.set_get_response(1'b1);
    super.rni0_rd_seq.set_verbose(1'b0);
    super.rni0_rd_seq.start(super.v_sqr.hrni0_sequencer);

    write_responses = super.rni0_wr_seq.get_responses();
    read_responses  = super.rni0_rd_seq.get_responses();

    if (write_responses.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Expected 1 post-reset write completion through the proxy, got %0d",
        super.tc_name, write_responses.size()))
    end

    if (read_responses.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Expected 1 post-reset read completion through the proxy, got %0d",
        super.tc_name, read_responses.size()))
    end

    repeat (2) begin
      super.tb_env.hsnf0_req_fifo.get(snf_req);
      snf_reqs.push_back(snf_req);
    end

    if (snf_reqs[0].opcode != item_t::req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_FULL_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Post-reset SN-F did not receive the forwarded WriteNoSnpFull: 0x%0h",
        super.tc_name, snf_reqs[0].opcode))
    end

    if (snf_reqs[1].opcode != item_t::req_opcode_t'(VIP_CHI_REQ_READ_NO_SNP_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Post-reset SN-F did not receive the forwarded ReadNoSnp: 0x%0h",
        super.tc_name, snf_reqs[1].opcode))
    end

    if (read_responses[0].data.size() != 4) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Post-reset proxied read returned %0d beats instead of 4",
        super.tc_name, read_responses[0].data.size()))
    end

    // Post-reset per-beat readback data integrity is now covered by the
    // standalone scoreboard (checker C write->read predictor; the env flushes
    // pred_mem on reset, so the post-reset write repopulates it and the readback
    // compares every byte, reads_skipped_unpredictable=0). The beat-count check
    // above remains as this test's structural intent.

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] HN-I proxy torn down mid-flight by reset and cleanly restarted",
      super.tc_name), UVM_LOW)

    phase.drop_objection(this);
  endtask
endclass
