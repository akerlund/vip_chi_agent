// ===========================================================================
// tc_chi_coh_d_wr_direction
//
// P3(a)/(b) validator: the monitor classifies a coherent WriteBackFull REQ and
// its CopyBackWrData DAT beats as WRITE direction. Both were previously
// mislabelled READ -- direction_from_opcode omitted the coherent writes (P3a),
// and dat_opcode_is_write_data omitted CopyBackWrData (P3b), which also leaked
// the staged wr_beats_by_dbid entry. RN-F0 acquires a line Unique then writes it
// back; the monitored REQ and DAT items are pulled from the coherent env
// observation FIFOs and their direction asserted.
//
// Anti-vacuity: without P3(a) the WriteBackFull REQ is READ; without P3(b) the
// CopyBackWrData DAT beat is READ. Either bug fires the matching assertion.
//
// CHI-D only: the classification is opcode-based and identical at CHI-E, so one
// concrete test suffices (no shared base).
// ===========================================================================
class tc_chi_coh_d_wr_direction extends vip_chi_coherent_base_test #(CHI_D_CFG_C, chi_d_types_t);

  typedef vip_chi_item #(CHI_D_CFG_C) item_t;

  vip_chi_writeback_seq #(CHI_D_CFG_C) hrnf0_wb_seq;

  `uvm_component_utils(tc_chi_coh_d_wr_direction)

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void start_of_simulation_phase(input uvm_phase phase);
    super.start_of_simulation_phase(phase);
    this.hrnf0_wb_seq = vip_chi_writeback_seq #(CHI_D_CFG_C)::type_id::create("hrnf0_wb_seq");
  endfunction

  task run_phase(input uvm_phase phase);
    item_t it;
    bit    saw_wb_req;
    bit    saw_cbwd_dat;

    phase.raise_objection(this);

    super.wait_reset_settle();

    // RN-F0 acquires the line Unique, then writes it back (CopyBackWrData burst).
    this.cfg_read_seq(super.hrnf0_rdunique_seq);
    super.hrnf0_rdunique_seq.start(super.tb_env.hrnf0_agent.sequencer);
    void'(super.hrnf0_rdunique_seq.get_responses());

    this.cfg_read_seq(this.hrnf0_wb_seq);
    this.hrnf0_wb_seq.start(super.tb_env.hrnf0_agent.sequencer);
    void'(this.hrnf0_wb_seq.get_responses());

    super.wait_clocks(8);

    // --- P3(a): the WriteBackFull REQ is classified WRITE. --------------------
    saw_wb_req = 1'b0;
    while (super.tb_env.hrnf0_req_fifo.try_get(it)) begin
      if (it.opcode == item_t::req_opcode_t'(VIP_CHI_REQ_WRITE_BACK_FULL_C)) begin
        saw_wb_req = 1'b1;
        if (it.direction != VIP_CHI_DIR_WRITE_E) begin
          `uvm_fatal(get_name(), $sformatf(
            "FATAL [%s] P3(a): WriteBackFull REQ direction is %s, expected WRITE",
            super.tc_name, it.direction.name()))
        end
      end
    end
    if (!saw_wb_req) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] P3(a): never observed a WriteBackFull REQ item", super.tc_name))
    end

    // --- P3(b): the CopyBackWrData DAT beats are classified WRITE. ------------
    saw_cbwd_dat = 1'b0;
    while (super.tb_env.hrnf0_dat_fifo.try_get(it)) begin
      if (it.dat_opcode == item_t::dat_opcode_t'(VIP_CHI_DAT_COPY_BACK_WR_DATA_C)) begin
        saw_cbwd_dat = 1'b1;
        if (it.direction != VIP_CHI_DIR_WRITE_E) begin
          `uvm_fatal(get_name(), $sformatf(
            "FATAL [%s] P3(b): CopyBackWrData DAT direction is %s, expected WRITE",
            super.tc_name, it.direction.name()))
        end
      end
    end
    if (!saw_cbwd_dat) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] P3(b): never observed a CopyBackWrData DAT item", super.tc_name))
    end

    phase.drop_objection(this);
  endtask
endclass
