class tc_chi_d_hni_persist extends vip_chi_base_test;

  `uvm_component_utils(tc_chi_d_hni_persist)

  vip_chi_persist_seq #(CHI_D_CFG_C) persist_seq;

  // WRITE_READ_ADDR_C decodes to HN-I SN target 0 (address bit 12 = 0).
  localparam item_t::addr_t PERSIST_HNI_ADDR_C = item_t::addr_t'(WRITE_READ_ADDR_C);

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

    this.persist_seq = vip_chi_persist_seq #(CHI_D_CFG_C)::type_id::create("persist_seq");
  endfunction

  // ---------------------------------------------------------------------------
  // Drive one CleanSharedPersist through the HN-I proxy. This is a
  // completion-only transaction (no DAT in either direction), so it exercises
  // the forwarder's RSP-only settle path: without it the single-outstanding
  // forwarder would wait forever for a data beat and hang.
  // ---------------------------------------------------------------------------
  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t responses[$];

    phase.raise_objection(this);

    this.persist_seq.reset();
    this.persist_seq.set_requests(1);
    this.persist_seq.set_initial_addr(PERSIST_HNI_ADDR_C);
    this.persist_seq.set_size(3'd6);
    this.persist_seq.set_allow_retry(1'b0);
    this.persist_seq.set_get_response(1'b1);
    this.persist_seq.start(super.v_sqr.hrni0_sequencer);

    responses = this.persist_seq.get_responses();
    if (responses.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Expected 1 persist completion through the proxy, got %0d",
        super.tc_name, responses.size()))
    end

    if (responses[0].rsp_opcode != item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Proxied persist completion opcode 0x%0h was not Comp",
        super.tc_name, responses[0].rsp_opcode))
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] HN-I relayed a completion-only CleanSharedPersist (RSP-only settle path)",
      super.tc_name), UVM_LOW)

    phase.drop_objection(this);
  endtask
endclass
