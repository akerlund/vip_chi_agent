class tc_chi_e_multi_outstanding_persist_sep extends chi_e_base_test;

  typedef vip_chi_item #(CHI_E_WIDE_CFG_C) item_t;

  `uvm_component_utils(tc_chi_e_multi_outstanding_persist_sep)

  localparam int N_C = 6;

  vip_chi_persist_seq #(CHI_E_WIDE_CFG_C) persist_seq;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // Dedicated separated-persist sequence handle (CHI-E CleanSharedPersistSep).
  // ---------------------------------------------------------------------------
  function void start_of_simulation_phase(input uvm_phase phase);

    super.start_of_simulation_phase(phase);

    this.persist_seq = vip_chi_persist_seq #(CHI_E_WIDE_CFG_C)::type_id::create("persist_seq");
  endfunction

  // ---------------------------------------------------------------------------
  // Enable the multi-outstanding pipeline on the RN-I and the buffered SN-F.
  // ---------------------------------------------------------------------------
  protected virtual function void configure_agent_cfgs();

    super.rni_cfg.multi_outstanding        = 1'b1;
    super.rni_cfg.multi_outstanding_write  = 1'b1;
    super.rni_cfg.max_outstanding_write    = N_C;
    super.rni_cfg.max_outstanding_read     = N_C;
    super.snf_cfg.multi_outstanding        = 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Pipeline N CleanSharedPersistSep CMOs over the CHI-E link. Each carries no
  // write data and no DBID grant, and completes with a two-part separated
  // response: an intermediate Persist then a final CompPersist. The pipeline's
  // RSP monitor consumes the intermediate Persist and retires each CMO on its
  // CompPersist. Confirms these RSP-only, two-flit completions overlap (peak >
  // 1) and each is handed back showing its final CompPersist.
  // ---------------------------------------------------------------------------
  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t rsp [$];
    item_t r;

    phase.raise_objection(this);

    this.persist_seq.reset();
    this.persist_seq.set_sep_persist(1'b1);        // CleanSharedPersistSep => Persist + CompPersist
    this.persist_seq.set_requests(N_C);
    this.persist_seq.set_initial_addr(E_PERSIST_SEP_ADDR_C);
    this.persist_seq.set_size(3'd6);
    this.persist_seq.set_src_id(E_PERSIST_SEP_RNI_NODE_ID_C);
    this.persist_seq.set_tgt_id(E_PERSIST_SEP_SNF_NODE_ID_C);
    this.persist_seq.set_allow_retry(1'b0);
    this.persist_seq.set_get_response(1'b1);
    this.persist_seq.set_pipelined_send(1'b1);
    this.persist_seq.set_verbose(1'b0);
    this.persist_seq.start(super.tb_env.rni_agent.sequencer);

    rsp = this.persist_seq.get_responses();
    if (rsp.size() != N_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Expected %0d persist-sep responses, got %0d",
        super.tc_name, N_C, rsp.size()))
    end

    foreach (rsp[k]) begin
      r = rsp[k];
      if (r.opcode != item_t::req_opcode_t'(VIP_CHI_REQ_CLEAN_SHARED_PERSIST_SEP_C)) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] Persist %0d was not CleanSharedPersistSep (opcode 0x%0h)",
          super.tc_name, k, r.opcode))
      end

      // Two milestones, in order: Comp says Point of Coherency, Persist says
      // Point of Persistence. The item carries the LAST completion stamped on
      // it, so a retired separated persist shows Persist -- and it only retires
      // once both have arrived, which is what keeps a pipelined persist from
      // being handed back while its Persist is still in flight.
      if (r.rsp_opcode != item_t::rsp_opcode_t'(VIP_CHI_RSP_PERSIST_C)) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] Persist-sep %0d final completion opcode 0x%0h was not Persist",
          super.tc_name, k, r.rsp_opcode))
      end
    end

    if (super.rni_cfg.observed_peak_outstanding <= 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Persist-sep CMOs did not overlap: peak in-flight was %0d (expected > 1)",
        super.tc_name, super.rni_cfg.observed_peak_outstanding))
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] %0d CleanSharedPersistSep CMOs pipelined (Persist+CompPersist consumed); peak in-flight = %0d",
      super.tc_name, N_C, super.rni_cfg.observed_peak_outstanding), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
