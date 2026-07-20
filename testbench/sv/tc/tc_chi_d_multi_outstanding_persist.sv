class tc_chi_d_multi_outstanding_persist extends vip_chi_base_test;

  `uvm_component_utils(tc_chi_d_multi_outstanding_persist)

  localparam int            N_C         = 6;
  localparam item_t::addr_t BASE_ADDR_C = item_t::addr_t'(44'h3000_0000);
  localparam bit [2:0]      SIZE_C      = 3'd6;   // CMO region granule

  vip_chi_persist_seq #(CHI_D_CFG_C) persist_seq;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // Dedicated persist-CMO sequence handle (CleanSharedPersist, non-separated).
  // ---------------------------------------------------------------------------
  function void start_of_simulation_phase(input uvm_phase phase);

    super.start_of_simulation_phase(phase);

    this.persist_seq = vip_chi_persist_seq #(CHI_D_CFG_C)::type_id::create("persist_seq");
  endfunction

  // ---------------------------------------------------------------------------
  // Enable the multi-outstanding pipeline on the RN-I and the buffered SN-F.
  // ---------------------------------------------------------------------------
  protected virtual function void configure_agent_cfgs();

    super.rni_cfg.multi_outstanding        = 1'b1;
    super.rni_cfg.multi_outstanding_write  = 1'b1;

    // Persist is a no-data write-like REQ; budget the write direction.
    super.rni_cfg.max_outstanding_write    = N_C;
    super.rni_cfg.max_outstanding_read     = N_C;
    super.snf_cfg.multi_outstanding        = 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Pipeline N CleanSharedPersist CMOs. Each carries no write data and no DBID
  // grant -- it just issues its REQ and completes on a single Comp RSP. Confirms
  // the pipeline overlaps these RSP-only, no-data transactions (peak > 1) and
  // hands each back with its Comp completion.
  // ---------------------------------------------------------------------------
  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t rsp [$];
    item_t r;

    phase.raise_objection(this);

    this.persist_seq.reset();
    this.persist_seq.set_sep_persist(1'b0);       // CleanSharedPersist (Comp)
    this.persist_seq.set_requests(N_C);
    this.persist_seq.set_initial_addr(BASE_ADDR_C);
    this.persist_seq.set_size(SIZE_C);
    this.persist_seq.set_allow_retry(1'b0);
    this.persist_seq.set_get_response(1'b1);
    this.persist_seq.set_pipelined_send(1'b1);
    this.persist_seq.set_verbose(1'b0);
    this.persist_seq.start(super.v_sqr.rni_sequencer);

    rsp = this.persist_seq.get_responses();
    if (rsp.size() != N_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Expected %0d persist responses, got %0d",
        super.tc_name, N_C, rsp.size()))
    end

    foreach (rsp[k]) begin
      r = rsp[k];
      if (r.opcode != item_t::req_opcode_t'(VIP_CHI_REQ_CLEAN_SHARED_PERSIST_C)) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] Persist %0d was not CleanSharedPersist (opcode 0x%0h)",
          super.tc_name, k, r.opcode))
      end
      if (r.rsp_opcode != item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_C)) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] Persist %0d completion opcode 0x%0h was not Comp",
          super.tc_name, k, r.rsp_opcode))
      end
    end

    if (super.rni_cfg.observed_peak_outstanding <= 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Persists did not overlap: peak in-flight was %0d (expected > 1)",
        super.tc_name, super.rni_cfg.observed_peak_outstanding))
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] %0d CleanSharedPersist CMOs pipelined (RSP-only, no data); each completed on Comp; peak in-flight = %0d",
      super.tc_name, N_C, super.rni_cfg.observed_peak_outstanding), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
