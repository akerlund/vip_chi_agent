class tc_chi_d_link_reactivation extends chi_base_test;

  `uvm_component_utils(tc_chi_d_link_reactivation)

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t responses[$];
    item_t req_item;
    item_t dat_item;
    bit    saw_reactivation;

    phase.raise_objection(this);

    @(posedge super.tb_env.rni_agent.vif.rst_n);
    super.wait_clocks(4);

    super.tb_cfg.reset();

    if (!super.tb_env.rni_agent.vif.txlinkactivereq ||
        !super.tb_env.snf_agent.vif.txlinkactiveack) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Initial link handshake was not active on both agents",
        super.tc_name))
    end

    super.tb_cfg.request_reset_pulse(3);

    @(negedge super.tb_env.rni_agent.vif.rst_n);
    super.wait_clocks(1);

    if (super.tb_env.rni_agent.vif.txlinkactivereq ||
        super.tb_env.snf_agent.vif.txlinkactiveack) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Link handshake did not drop to idle during reset",
        super.tc_name))
    end

    @(posedge super.tb_env.rni_agent.vif.rst_n);

    saw_reactivation = 1'b0;
    repeat (10) begin
      if (super.tb_env.rni_agent.vif.txlinkactivereq &&
          super.tb_env.snf_agent.vif.txlinkactiveack) begin
        saw_reactivation = 1'b1;
        break;
      end
      super.wait_clocks(1);
    end

    if (!saw_reactivation) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Link handshake was not re-asserted after reset release",
        super.tc_name))
    end

    super.drain_observation_fifos();

    super.rni0_rd_seq.reset();
    super.rni0_rd_seq.set_requests(1);
    super.rni0_rd_seq.set_initial_addr(READ_ADDR_C + item_t::addr_t'(44'hC00));
    super.rni0_rd_seq.set_size(3'd6);
    super.rni0_rd_seq.set_allow_retry(1'b0);
    super.rni0_rd_seq.set_get_response(1'b1);
    super.rni0_rd_seq.set_verbose(1'b0);
    super.rni0_rd_seq.start(super.v_sqr.rni_sequencer);

    responses = super.rni0_rd_seq.get_responses();
    if (responses.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Expected 1 post-reactivation read response, got %0d",
        super.tc_name, responses.size()))
    end

    super.tb_env.rni_req_fifo.get(req_item);
    super.tb_env.rni_dat_fifo.get(dat_item);

    if (dat_item.role != VIP_CHI_ROLE_SNF_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Post-reactivation DAT role was %0d instead of SN-F",
        super.tc_name, dat_item.role))
    end

    if (responses[0].txn_id != req_item.txn_id) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Post-reactivation response txn_id 0x%0h did not match request txn_id 0x%0h",
        super.tc_name, responses[0].txn_id, req_item.txn_id))
    end

    phase.drop_objection(this);
  endtask
endclass