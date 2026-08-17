// ---------------------------------------------------------------------------
// WriteEvictOrEvict (Issue E): the one CopyBack whose SHAPE the completer picks.
//
// The RN-F offers a clean line back and the home decides, on its own heuristics,
// whether it wants the data:
//
//   CompDBIDResp -> yes. The requester sends CopyBackWrData, and that message is
//                   itself the implicit CompAck. No explicit CompAck follows.
//   Comp         -> no. The requester sends an explicit CompAck and no data. The
//                   transaction degenerates into an Evict.
//
// Both legs run here, because a test that only drove one would leave the other as
// a branch nothing has ever taken -- and the two legs differ in the two things
// easiest to get wrong: whether data moves, and which acknowledgement closes the
// transaction. "Its own heuristics" is not predictable, so the home's choice is
// cfg.hnf_write_evict_request_data and each leg is driven deliberately.
//
// What separates the legs on the wire, and so what is asserted:
//
//   * data leg: exactly one CopyBackWrData burst from the requester, and NO
//     CompAck. An implementation that sent the ack anyway would be sending one
//     the home never expects.
//   * no-data leg: NO DAT flit at all, and exactly one CompAck.
//
// Either way the line leaves the requester's cache and its directory entry goes
// Invalid -- that is the "Evict" in the name, and it holds on both branches.
// ---------------------------------------------------------------------------

class tc_chi_e_write_evict_or_evict extends
  chi_coherent_e_base_test #(CHI_E_WIDE_CFG_C, chi_e_wide_types_t);

  `uvm_component_utils(tc_chi_e_write_evict_or_evict)

  localparam int SETTLE_C = 8;

  vip_chi_write_evict_or_evict_seq #(CHI_E_WIDE_CFG_C) weoe_seq;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void start_of_simulation_phase(input uvm_phase phase);
    super.start_of_simulation_phase(phase);
    this.weoe_seq =
      vip_chi_write_evict_or_evict_seq #(CHI_E_WIDE_CFG_C)::type_id::create("weoe_seq");
  endfunction

  // ---------------------------------------------------------------------------
  // One WriteEvictOrEvict from RN-F0, with the home's choice forced. Returns how
  // many DAT beats and how many CompAcks the requester's own link carried.
  // ---------------------------------------------------------------------------
  protected task drive_leg(
    input  bit request_data,
    output int dat_beats,
    output int comp_acks
  );

    item_t rsp[$];
    item_t req_item;
    item_t dat_item;
    item_t rsp_item;

    dat_beats = 0;
    comp_acks = 0;

    // The requester must actually hold a clean line to offer back, or the
    // transaction would be reporting on a line it never had.
    super.cfg_read_seq(super.hrnf0_rdshared_seq);
    super.hrnf0_rdshared_seq.start(super.tb_env.hrnf0_agent.sequencer);
    void'(super.hrnf0_rdshared_seq.get_responses());
    super.wait_clocks(SETTLE_C);

    if (super.tb_env.hrnf0_agent.rnf_driver.get_cache_state(
          item_t::addr_t'(WRITE_READ_ADDR_C)) == VIP_CHI_RESP_STATE_I_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F0 holds no line, so there is nothing to evict", super.tc_name))
    end

    while (super.tb_env.hrnf0_req_fifo.try_get(req_item)) begin end
    while (super.tb_env.hrnf0_dat_fifo.try_get(dat_item)) begin end
    while (super.tb_env.hrnf0_rsp_fifo.try_get(rsp_item)) begin end

    super.hrnf0_cfg.hnf_write_evict_request_data = request_data;
    super.hnf_cfg.hnf_write_evict_request_data   = request_data;

    super.cfg_read_seq(this.weoe_seq);
    this.weoe_seq.start(super.tb_env.hrnf0_agent.sequencer);
    rsp = this.weoe_seq.get_responses();
    super.wait_clocks(SETTLE_C);

    if (rsp.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] expected 1 response, got %0d", super.tc_name, rsp.size()))
    end

    if (!super.tb_env.hrnf0_req_fifo.try_get(req_item)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] WriteEvictOrEvict produced no REQ flit", super.tc_name))
    end

    if (req_item.opcode != item_t::req_opcode_t'(VIP_CHI_REQ_WRITE_EVICT_OR_EVICT_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] REQ opcode 0x%0h, expected 0x%0h",
        super.tc_name, req_item.opcode,
        item_t::req_opcode_t'(VIP_CHI_REQ_WRITE_EVICT_OR_EVICT_C)))
    end

    if (!req_item.exp_comp_ack) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] WriteEvictOrEvict must set ExpCompAck: the no-data leg completes only on the acknowledgement",
        super.tc_name))
    end

    while (super.tb_env.hrnf0_dat_fifo.try_get(dat_item)) begin

      if (dat_item.dat_opcode != item_t::dat_opcode_t'(VIP_CHI_DAT_COPY_BACK_WR_DATA_C)) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] WriteEvictOrEvict data was 0x%0h, expected CopyBackWrData: it is a CopyBack, and that message is also the implicit CompAck",
          super.tc_name, dat_item.dat_opcode))
      end

      dat_beats += dat_item.data.size();
    end

    while (super.tb_env.hrnf0_rsp_fifo.try_get(rsp_item)) begin
      if (rsp_item.rsp_opcode == item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_ACK_C)) begin
        comp_acks++;
      end
    end

    // Either way the line leaves the requester -- the "Evict" in the name.
    if (super.tb_env.hrnf0_agent.rnf_driver.get_cache_state(
          item_t::addr_t'(WRITE_READ_ADDR_C)) != VIP_CHI_RESP_STATE_I_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F0 still holds the line after WriteEvictOrEvict", super.tc_name))
    end

    if (super.tb_env.hnf_agent.hnf_driver.get_directory_port_state(
          item_t::addr_t'(WRITE_READ_ADDR_C), 0) != VIP_CHI_RESP_STATE_I_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] directory port0 not Invalid after WriteEvictOrEvict", super.tc_name))
    end
  endtask

  task run_phase(input uvm_phase phase);

    int dat_beats;
    int comp_acks;

    phase.raise_objection(this);
    super.wait_reset_settle();

    // ---- Leg 1: the home asks for the data ---------------------------------
    this.drive_leg(1'b1, dat_beats, comp_acks);

    if (dat_beats == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the home answered CompDBIDResp but no CopyBackWrData was sent: the data leg never moved any data",
        super.tc_name))
    end

    if (comp_acks != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the data leg sent %0d explicit CompAck(s): CopyBackWrData is itself the implicit acknowledgement, so an explicit one is a response the home never expects",
        super.tc_name, comp_acks))
    end

    // ---- Leg 2: the home declines it ---------------------------------------
    this.drive_leg(1'b0, dat_beats, comp_acks);

    if (dat_beats != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the home answered Comp but the requester still sent %0d data beat(s): the no-data leg must not move data",
        super.tc_name, dat_beats))
    end

    if (comp_acks != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the no-data leg sent %0d CompAck(s), expected exactly 1: a bare Comp completes only when the requester acknowledges it",
        super.tc_name, comp_acks))
    end

    if (super.tb_env.coh_checker.get_multi_owner_count() != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] multi-owner violations on WriteEvictOrEvict traffic", super.tc_name))
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] the data leg sent CopyBackWrData with no explicit CompAck, the no-data leg sent one CompAck and no data, and the line left the cache on both",
      super.tc_name), UVM_LOW)

    phase.drop_objection(this);
  endtask
endclass
