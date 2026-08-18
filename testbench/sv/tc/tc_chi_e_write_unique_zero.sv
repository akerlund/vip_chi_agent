// ---------------------------------------------------------------------------
// WriteUniqueZero (Issue E): a snoopable full-line store of ZERO that puts NO
// data on the wire.
//
// The whole opcode exists to avoid a data transfer, so the assertion that matters
// is the ABSENCE of one. A WriteUniqueFull carrying a line of zeros would leave
// the memory in exactly the same state and would pass any readback check, so a
// test that only read the line back would pass just as loudly on the wrong
// opcode. What separates them is the DAT channel: this transaction must complete
// without the requester ever sending a beat.
//
// What is asserted:
//
//   * the REQ that reached the wire carries WriteUniqueZero, not something the
//     solver substituted.
//   * the requester sent NO DAT flit. This is the point of the opcode.
//   * the line reads back as zero. A home that answered correctly and never
//     zeroed anything would satisfy both assertions above.
//   * the other RN-F, which held the line before the write, was snoop-invalidated
//     -- the "Unique" half. Its cache and its directory entry must both be I.
//
// A second RN-F is given the line first, on purpose: without a holder there is
// nothing to snoop, and the snoop leg would be untested while looking tested.
// ---------------------------------------------------------------------------

class tc_chi_e_write_unique_zero extends
  chi_coherent_e_base_test #(CHI_E_WIDE_CFG_C, chi_e_wide_types_t);

  `uvm_component_utils(tc_chi_e_write_unique_zero)

  localparam int SETTLE_C = 8;

  vip_chi_write_unique_zero_seq #(CHI_E_WIDE_CFG_C) wuz_seq;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void start_of_simulation_phase(input uvm_phase phase);
    super.start_of_simulation_phase(phase);
    this.wuz_seq = vip_chi_write_unique_zero_seq #(CHI_E_WIDE_CFG_C)::type_id::create("wuz_seq");
  endfunction

  task run_phase(input uvm_phase phase);

    item_t rsp[$];
    item_t rd_rsp[$];
    item_t req_item;
    item_t dat_item;

    phase.raise_objection(this);
    super.wait_reset_settle();

    // Give RN-F1 the line first, so the snoop leg has a holder to invalidate.
    // Without this the home has nothing to snoop and the "Unique" half of the
    // opcode would go untested while appearing tested.
    super.cfg_read_seq(super.hrnf1_rdshared_seq);
    super.hrnf1_rdshared_seq.start(super.tb_env.hrnf1_agent.sequencer);
    void'(super.hrnf1_rdshared_seq.get_responses());
    super.wait_clocks(SETTLE_C);

    if (super.tb_env.hrnf1_agent.rnf_driver.get_cache_state(
          item_t::addr_t'(WRITE_READ_ADDR_C)) == VIP_CHI_RESP_STATE_I_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F1 does not hold the line, so the snoop leg would not be exercised",
        super.tc_name))
    end

    // Nothing left over from the read may be mistaken for the write's traffic.
    while (super.tb_env.hrnf0_req_fifo.try_get(req_item)) begin end
    while (super.tb_env.hrnf0_dat_fifo.try_get(dat_item)) begin end

    super.cfg_read_seq(this.wuz_seq);
    this.wuz_seq.start(super.tb_env.hrnf0_agent.sequencer);
    rsp = this.wuz_seq.get_responses();
    super.wait_clocks(SETTLE_C);

    if (rsp.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] expected 1 WriteUniqueZero response, got %0d",
        super.tc_name, rsp.size()))
    end

    // ---- REQ: the opcode that actually reached the wire ---------------------
    if (!super.tb_env.hrnf0_req_fifo.try_get(req_item)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] WriteUniqueZero produced no REQ flit", super.tc_name))
    end

    // Full width on both sides: item_t here is the CHI-D package typedef, whose
    // 6-bit req_opcode_t would truncate this Opcode[6] = 1 encoding.
    if (VIP_CHI_MAX_REQ_OPCODE_WIDTH_C'(req_item.opcode) != VIP_CHI_REQ_WRITE_UNIQUE_ZERO_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] REQ opcode 0x%0h, expected 0x%0h",
        super.tc_name, req_item.opcode,
        VIP_CHI_REQ_WRITE_UNIQUE_ZERO_C))
    end

    // ---- DAT: there must be none. This is the opcode's whole purpose --------
    if (super.tb_env.hrnf0_dat_fifo.try_get(dat_item)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] WriteUniqueZero sent a DAT flit (opcode 0x%0h) -- a zero write must complete with no data on the wire",
        super.tc_name, dat_item.dat_opcode))
    end

    // ---- The Unique half: the other holder was invalidated -------------------
    // Checked BEFORE the readback below, which would legitimately give RN-F1 the
    // line back and erase the evidence.
    if (super.tb_env.hrnf1_agent.rnf_driver.get_cache_state(
          item_t::addr_t'(WRITE_READ_ADDR_C)) != VIP_CHI_RESP_STATE_I_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F1 still holds the line after WriteUniqueZero: it was not snooped out",
        super.tc_name))
    end

    if (super.tb_env.hnf_agent.hnf_driver.get_directory_port_state(
          item_t::addr_t'(WRITE_READ_ADDR_C), 1) != VIP_CHI_RESP_STATE_I_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] directory port1 not Invalid after WriteUniqueZero", super.tc_name))
    end

    if (super.tb_env.hnf_agent.hnf_driver.get_directory_port_state(
          item_t::addr_t'(WRITE_READ_ADDR_C), 0) != VIP_CHI_RESP_STATE_I_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] directory port0 not Invalid after WriteUniqueZero: the non-allocating writer must not end up owning the line",
        super.tc_name))
    end

    // ---- The line really was zeroed, read back through the protocol ---------
    // A coherent read rather than a peek into the home's memory model: the value
    // has to be observable the way a real requester would see it, and the same
    // check then means the same thing in both ports.
    super.cfg_read_seq(super.hrnf1_rdshared_seq);
    super.hrnf1_rdshared_seq.start(super.tb_env.hrnf1_agent.sequencer);
    rd_rsp = super.hrnf1_rdshared_seq.get_responses();

    if (rd_rsp.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] expected 1 readback response, got %0d",
        super.tc_name, rd_rsp.size()))
    end

    foreach (rd_rsp[0].data[beat]) begin
      if (rd_rsp[0].data[beat] !== '0) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] beat %0d of the line reads back 0x%0h after WriteUniqueZero, expected zero: the home answered but never zeroed it",
          super.tc_name, beat, rd_rsp[0].data[beat]))
      end
    end

    if (super.tb_env.coh_checker.get_multi_owner_count() != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] multi-owner violations on WriteUniqueZero traffic", super.tc_name))
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] WriteUniqueZero completed with no DAT flit, zeroed the line, and invalidated the other holder",
      super.tc_name), UVM_LOW)

    phase.drop_objection(this);
  endtask
endclass
