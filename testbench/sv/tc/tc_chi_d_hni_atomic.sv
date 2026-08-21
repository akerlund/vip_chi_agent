class tc_chi_d_hni_atomic extends chi_base_test;

  `uvm_component_utils(tc_chi_d_hni_atomic)

  vip_chi_atomic_seq #(CHI_D_CFG_C) atomic_seq;

  // WRITE_READ_ADDR_C decodes to HN-I SN target 0 (address bit 12 = 0).
  localparam item_t::addr_t ATOMIC_HNI_ADDR_C = item_t::addr_t'(WRITE_READ_ADDR_C);

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // Start Of Simulation Phase
  // ---------------------------------------------------------------------------
  function void start_of_simulation_phase(input uvm_phase phase);

    super.start_of_simulation_phase(phase);

    this.atomic_seq = vip_chi_atomic_seq #(CHI_D_CFG_C)::type_id::create("atomic_seq");
  endfunction

  // ---------------------------------------------------------------------------
  // Drive one AtomicStore through the HN-I proxy and confirm the operand DAT is
  // relayed to the SN-F and the completion returns (exercises the forwarder's
  // atomic/write settle path and the RN->SN write-DAT relay).
  // ---------------------------------------------------------------------------
  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t::data_t data_beats[$];
    item_t         responses[$];
    item_t         snf_req;
    item_t::size_t beat_size;

    // The wide-operand stress profile is out of spec by Table 2-17, on purpose.
    // The rule is turned down to OFF -- still evaluated, still counted, not
    // reported -- and required to have fired before this test ends. See the
    // §22 L7 note in vip_chi_atomic_seq for why both halves are needed.
    // All FOUR binds on the chain, not just the two ends. One atomic crosses the
    // RN-facing link, the proxy's own RN and SN ports, and the SN-facing link,
    // and the rule fires wherever the flit is seen -- waiving at the ends only
    // would leave the two middle binds reporting at ERROR.
    super.tb_env.hrni0_agent.vif.check_severity[VIP_CHI_CHK_ATOMIC_SIZE_LEGAL_E] =
      VIP_CHI_CHK_SEV_OFF_E;
    super.tb_env.hni_agent.rn_vif[0].check_severity[VIP_CHI_CHK_ATOMIC_SIZE_LEGAL_E] =
      VIP_CHI_CHK_SEV_OFF_E;
    super.tb_env.hni_agent.sn_vif[0].check_severity[VIP_CHI_CHK_ATOMIC_SIZE_LEGAL_E] =
      VIP_CHI_CHK_SEV_OFF_E;
    super.tb_env.hsnf0_agent.vif.check_severity[VIP_CHI_CHK_ATOMIC_SIZE_LEGAL_E] =
      VIP_CHI_CHK_SEV_OFF_E;

    phase.raise_objection(this);

    beat_size = item_t::size_t'($clog2(CHI_D_CFG_C.DATA_BYTES_P));

    this.atomic_seq.reset();
    this.atomic_seq.set_atomic_op(VIP_CHI_ATOMIC_OP_STORE_0_E);
    this.atomic_seq.set_requests(1);
    this.atomic_seq.set_initial_addr(ATOMIC_HNI_ADDR_C);
    this.atomic_seq.set_size(beat_size);
    this.atomic_seq.set_get_response(1'b1);
    data_beats.delete();
    data_beats.push_back(item_t::data_t'('h10));
    this.atomic_seq.set_data(data_beats);
    this.atomic_seq.start(super.v_sqr.hrni0_sequencer);

    responses = this.atomic_seq.get_responses();
    if (responses.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Expected 1 atomic response through the proxy, got %0d",
        super.tc_name, responses.size()))
    end

    // The SN-F must have observed the forwarded atomic request.
    super.tb_env.hsnf0_req_fifo.get(snf_req);
    if (!vip_chi_types_pkg::vip_chi_req_opcode_is_atomic(vip_chi_req_opcode_t'(snf_req.opcode))) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] SN-F did not receive a forwarded atomic opcode (got 0x%0h)",
        super.tc_name, snf_req.opcode))
    end

    if (snf_req.addr != ATOMIC_HNI_ADDR_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Forwarded atomic address 0x%0h != 0x%0h",
        super.tc_name, snf_req.addr, ATOMIC_HNI_ADDR_C))
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] HN-I relayed an AtomicStore end-to-end (RN-I -> HN-I -> SN-F)",
      super.tc_name), UVM_LOW)

    // The waiver's second half: this traffic must have been out of spec in the
    // way the profile claims. A silenced rule that stopped firing would look
    // exactly like a passing test.
    if ((super.tb_env.hrni0_agent.vif.check_fail_count[VIP_CHI_CHK_ATOMIC_SIZE_LEGAL_E] == 0) ||
        (super.tb_env.hni_agent.rn_vif[0].check_fail_count[VIP_CHI_CHK_ATOMIC_SIZE_LEGAL_E] == 0) ||
        (super.tb_env.hni_agent.sn_vif[0].check_fail_count[VIP_CHI_CHK_ATOMIC_SIZE_LEGAL_E] == 0) ||
        (super.tb_env.hsnf0_agent.vif.check_fail_count[VIP_CHI_CHK_ATOMIC_SIZE_LEGAL_E] == 0)) begin
      `uvm_error(get_name(), $sformatf(
        "ERROR [%s] %s recorded no violation on one of the four links the atomic crosses, but this test drives the wide-operand stress profile on purpose; the proxy relayed the request, so every bind on the chain should have judged its Size",
        super.tc_name, vip_chi_check_name(VIP_CHI_CHK_ATOMIC_SIZE_LEGAL_E)))
    end

    phase.drop_objection(this);
  endtask
endclass
