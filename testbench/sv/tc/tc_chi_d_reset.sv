class tc_chi_d_reset extends chi_base_test;

  `uvm_component_utils(tc_chi_d_reset)

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // Build Phase
  // ---------------------------------------------------------------------------
  function void build_phase(input uvm_phase phase);

    super.build_phase(phase);

    // SN-F DAT send progress is now limited by RN-I's advertised DAT credits,
    // so keep both sides at one credit to preserve the original stall shape.
    super.rni_cfg.initial_dat_credits = 1;
    super.snf_cfg.initial_dat_credits = 1;
  endfunction

  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    vip_chi_read_seq #(CHI_D_CFG_C) pre_reset_seq;
    item_t                        first_req;
    item_t                        second_req;
    item_t                        first_dat;
    item_t                        post_req;
    item_t                        post_dat;
    item_t                        responses[$];
    bit                           pre_reset_done;
    bit                           saw_second_req;

    phase.raise_objection(this);

    @(posedge super.tb_env.rni_agent.vif.rst_n);
    super.wait_clocks(4);

    super.rni_cfg.hold_dat_credit = 1'b1;

    pre_reset_seq = vip_chi_read_seq #(CHI_D_CFG_C)::type_id::create("pre_reset_seq");
    pre_reset_seq.reset();
    pre_reset_seq.set_requests(2);
    pre_reset_seq.set_initial_addr(READ_ADDR_C + item_t::addr_t'(44'h800));
    pre_reset_seq.set_size(item_t::size_t'($clog2(CHI_D_CFG_C.DATA_BYTES_P)));
    pre_reset_seq.set_allow_retry(1'b0);
    pre_reset_seq.set_get_response(1'b1);
    pre_reset_seq.set_verbose(1'b0);

    pre_reset_done = 1'b0;
    fork
      begin
        pre_reset_seq.start(super.v_sqr.rni_sequencer);
        pre_reset_done = 1'b1;
      end
    join_none

    super.tb_env.rni_req_fifo.get(first_req);
    super.tb_env.rni_dat_fifo.get(first_dat);

    saw_second_req = 1'b0;
    repeat (20) begin
      if (super.tb_env.rni_req_fifo.try_get(second_req)) begin
        saw_second_req = 1'b1;
        break;
      end
      super.wait_clocks(1);
    end

    if (!saw_second_req) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Did not reach an in-flight second request before reset",
        super.tc_name))
    end

    super.tb_cfg.request_reset_pulse(3);
    super.rni_cfg.hold_dat_credit = 1'b0;

    @(negedge super.tb_env.rni_agent.vif.rst_n);
    @(posedge super.tb_env.rni_agent.vif.rst_n);

    repeat (20) begin
      if (pre_reset_done) begin
        break;
      end
      super.wait_clocks(1);
    end

    if (!pre_reset_done) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Pre-reset read sequence did not terminate after reset handling",
        super.tc_name))
    end

    super.wait_clocks(4);
    super.drain_observation_fifos();

    super.rni0_rd_seq.reset();
    super.rni0_rd_seq.set_requests(1);
    super.rni0_rd_seq.set_initial_addr(READ_ADDR_C + item_t::addr_t'(44'hA00));
    super.rni0_rd_seq.set_size(3'd6);
    super.rni0_rd_seq.set_allow_retry(1'b0);
    super.rni0_rd_seq.set_get_response(1'b1);
    super.rni0_rd_seq.set_verbose(1'b0);
    super.rni0_rd_seq.start(super.v_sqr.rni_sequencer);

    responses = super.rni0_rd_seq.get_responses();
    if (responses.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Expected 1 post-reset read response, got %0d",
        super.tc_name, responses.size()))
    end

    if (first_dat.role != VIP_CHI_ROLE_SNF_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] First completion carried wrong DAT role %0d",
        super.tc_name, first_dat.role))
    end

    super.tb_env.rni_req_fifo.get(post_req);
    super.tb_env.rni_dat_fifo.get(post_dat);

    if (post_req.addr != (READ_ADDR_C + item_t::addr_t'(44'hA00))) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Post-reset read used wrong address 0x%0h",
        super.tc_name, post_req.addr))
    end

    if (responses[0].txn_id != post_req.txn_id) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Post-reset read response txn_id 0x%0h did not match REQ txn_id 0x%0h",
        super.tc_name, responses[0].txn_id, post_req.txn_id))
    end

    if (post_dat.role != VIP_CHI_ROLE_SNF_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Post-reset completion carried wrong DAT role %0d",
        super.tc_name, post_dat.role))
    end

    phase.drop_objection(this);
  endtask
endclass