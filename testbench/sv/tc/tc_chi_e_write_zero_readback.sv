class tc_chi_e_write_zero_readback extends chi_e_base_test;

  typedef vip_chi_item #(CHI_E_WIDE_CFG_C) item_t;

  `uvm_component_utils(tc_chi_e_write_zero_readback)

  // Address lives at package scope (chi_tb_pkg::E_WRITE_ZERO_ADDR_C): a
  // class-scoped `localparam item_t::addr_t` at CHI-E width hangs vcs1fe codegen.
  localparam bit [2:0] SIZE_C = 3'd6;

  vip_chi_write_zero_seq #(CHI_E_WIDE_CFG_C) rni_wr_zero_seq;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void start_of_simulation_phase(input uvm_phase phase);
    super.start_of_simulation_phase(phase);
    this.rni_wr_zero_seq = vip_chi_write_zero_seq #(CHI_E_WIDE_CFG_C)::type_id::create("rni_wr_zero_seq");
  endfunction

  task run_phase(input uvm_phase phase);

    item_t wr_rsp[$];
    item_t zero_rsp[$];
    item_t pre_rsp[$];
    item_t post_rsp[$];
    int    expected_beats;
    bit    saw_nonzero;

    phase.raise_objection(this);

    expected_beats = vip_chi_types_pkg::chi_xfer_dat_beats(
      item_t::size_t'(SIZE_C), CHI_E_WIDE_CFG_C.DATA_BYTES_P);

    // Seed a concrete non-zero line first; the zero-write check is otherwise
    // vacuous because untouched memory may already read as zero on some bytes.
    super.rni_wr_seq.reset();
    super.rni_wr_seq.set_requests(1);
    super.rni_wr_seq.set_initial_addr(E_WRITE_ZERO_ADDR_C);
    super.rni_wr_seq.set_size(SIZE_C);
    super.rni_wr_seq.set_allow_retry(1'b0);
    super.rni_wr_seq.set_data_type(VIP_CHI_DATA_ONES_E);
    super.rni_wr_seq.set_get_response(1'b1);
    super.rni_wr_seq.set_verbose(1'b0);
    super.rni_wr_seq.start(super.tb_env.rni_agent.sequencer);
    wr_rsp = super.rni_wr_seq.get_responses();

    if ((wr_rsp.size() != 1) ||
        (wr_rsp[0].rsp_opcode != item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_DBID_RESP_C))) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] seed write did not complete with CompDBIDResp",
        super.tc_name))
    end

    super.rni_rd_seq.reset();
    super.rni_rd_seq.set_requests(1);
    super.rni_rd_seq.set_initial_addr(E_WRITE_ZERO_ADDR_C);
    super.rni_rd_seq.set_size(SIZE_C);
    super.rni_rd_seq.set_allow_retry(1'b0);
    super.rni_rd_seq.set_get_response(1'b1);
    super.rni_rd_seq.set_verbose(1'b0);
    super.rni_rd_seq.start(super.tb_env.rni_agent.sequencer);
    pre_rsp = super.rni_rd_seq.get_responses();

    if ((pre_rsp.size() != 1) || (pre_rsp[0].data.size() != expected_beats)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] pre-zero readback returned %0d responses / %0d beats",
        super.tc_name, pre_rsp.size(), pre_rsp.size() ? pre_rsp[0].data.size() : 0))
    end

    saw_nonzero = 1'b0;
    foreach (pre_rsp[0].data[i]) begin
      if (pre_rsp[0].data[i] !== '0) begin
        saw_nonzero = 1'b1;
      end
    end
    if (!saw_nonzero) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] seed write readback was already all zero", super.tc_name))
    end

    this.rni_wr_zero_seq.reset();
    this.rni_wr_zero_seq.set_requests(1);
    this.rni_wr_zero_seq.set_initial_addr(E_WRITE_ZERO_ADDR_C);
    this.rni_wr_zero_seq.set_size(SIZE_C);
    this.rni_wr_zero_seq.set_allow_retry(1'b0);
    this.rni_wr_zero_seq.set_get_response(1'b1);
    this.rni_wr_zero_seq.set_verbose(1'b0);
    this.rni_wr_zero_seq.start(super.tb_env.rni_agent.sequencer);
    zero_rsp = this.rni_wr_zero_seq.get_responses();

    // WriteNoSnpZero is answered by a combined CompDBIDResp, or by DBIDResp then
    // Comp under cfg.split_write_rsp. It carries no data, so the granted buffer
    // is never used -- but the completion form is normative regardless.
    if ((zero_rsp.size() != 1) ||
        (zero_rsp[0].rsp_opcode != item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_DBID_RESP_C))) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] WriteNoSnpZero did not complete with CompDBIDResp",
        super.tc_name))
    end

    super.rni_rd_seq.reset();
    super.rni_rd_seq.set_requests(1);
    super.rni_rd_seq.set_initial_addr(E_WRITE_ZERO_ADDR_C);
    super.rni_rd_seq.set_size(SIZE_C);
    super.rni_rd_seq.set_allow_retry(1'b0);
    super.rni_rd_seq.set_get_response(1'b1);
    super.rni_rd_seq.set_verbose(1'b0);
    super.rni_rd_seq.start(super.tb_env.rni_agent.sequencer);
    post_rsp = super.rni_rd_seq.get_responses();

    if ((post_rsp.size() != 1) || (post_rsp[0].data.size() != expected_beats)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] post-zero readback returned %0d responses / %0d beats",
        super.tc_name, post_rsp.size(), post_rsp.size() ? post_rsp[0].data.size() : 0))
    end

    foreach (post_rsp[0].data[i]) begin
      if (post_rsp[0].data[i] !== '0) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] post-zero readback beat %0d was 0x%0h, expected zero",
          super.tc_name, i, post_rsp[0].data[i]))
      end
    end

    phase.drop_objection(this);
  endtask
endclass
