class tc_chi_d_credit_starvation extends vip_chi_base_test;

  `uvm_component_utils(tc_chi_d_credit_starvation)

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

    vip_chi_read_seq #(CHI_D_CFG_C) seq;
    item_t                        first_req;
    item_t                        second_req;
    item_t                        first_dat;
    item_t                        second_dat;
    item_t                        unexpected_dat;
    item_t                        responses[$];
    bit                           seq_done;
    bit                           saw_second_req;

    phase.raise_objection(this);

    @(posedge super.tb_env.rni_agent.vif.rst_n);
    super.wait_clocks(4);

    // Stall the SN-F's DAT completions by pausing the RN-I's DAT credit
    // advertisement (the receiver's own credit knob, not a harness wire pinch).
    super.rni_cfg.hold_dat_credit = 1'b1;

    seq = vip_chi_read_seq #(CHI_D_CFG_C)::type_id::create("credit_starvation_seq");
    seq.reset();
    seq.set_requests(2);
    seq.set_initial_addr(READ_ADDR_C + item_t::addr_t'(44'h400));
    seq.set_size(item_t::size_t'($clog2(CHI_D_CFG_C.DATA_BYTES_P)));
    seq.set_allow_retry(1'b0);
    seq.set_get_response(1'b1);
    seq.set_verbose(1'b0);

    seq_done = 1'b0;
    fork
      begin
        seq.start(super.v_sqr.rni_sequencer);
        seq_done = 1'b1;
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
        "FATAL [%s] Second read request never issued before DAT-credit stall",
        super.tc_name))
    end

    super.wait_clocks(10);

    if (super.tb_env.rni_dat_fifo.try_get(unexpected_dat)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Second read completion arrived while DAT credit was held",
        super.tc_name))
    end

    if (seq_done) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Read sequence completed before the held DAT credit was released",
        super.tc_name))
    end

    super.rni_cfg.hold_dat_credit = 1'b0;

    super.tb_env.rni_dat_fifo.get(second_dat);

    repeat (20) begin
      if (seq_done) begin
        break;
      end
      super.wait_clocks(1);
    end

    if (!seq_done) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Read sequence did not recover after DAT credit release",
        super.tc_name))
    end

    responses = seq.get_responses();
    if (responses.size() != 2) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Expected 2 read responses after DAT-credit recovery, got %0d",
        super.tc_name, responses.size()))
    end

    if (first_dat.role != VIP_CHI_ROLE_SNF_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] First completion carried wrong DAT role %0d",
        super.tc_name, first_dat.role))
    end

    if (second_dat.txn_id != second_req.txn_id) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Second stalled completion txn_id 0x%0h did not match request txn_id 0x%0h",
        super.tc_name, second_dat.txn_id, second_req.txn_id))
    end

    phase.drop_objection(this);
  endtask
endclass