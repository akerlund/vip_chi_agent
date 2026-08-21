class tc_chi_d_multi_outstanding_atomic extends chi_base_test;

  `uvm_component_utils(tc_chi_d_multi_outstanding_atomic)

  localparam int            N_C         = 6;
  localparam item_t::addr_t BASE_ADDR_C = item_t::addr_t'(44'h2F00_0000);

  // One full-beat granule per atomic (mirrors tc_chi_d_atomic): size = clog2 of
  // the data-byte width, so each AtomicLoad reads/updates exactly one beat.
  localparam int            DBYTES_C    = CHI_D_CFG_C.DATA_BYTES_P;
  localparam bit [2:0]      SIZE_C      = 3'($clog2(DBYTES_C));
  localparam int            STRIDE_C    = DBYTES_C;

  // The DBID grant precedes the SN-F RMW commit, so let the seeded writes and
  // the atomic updates settle into the backing store before reading them back.
  localparam int            SETTLE_C    = 20;

  vip_chi_atomic_load_seq #(CHI_D_CFG_C) atomic_seq;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // Dedicated returning-atomic sequence handle (AtomicLoad, arithmetic ADD).
  // ---------------------------------------------------------------------------
  function void start_of_simulation_phase(input uvm_phase phase);

    super.start_of_simulation_phase(phase);

    this.atomic_seq = vip_chi_atomic_load_seq #(CHI_D_CFG_C)::type_id::create("atomic_seq");
  endfunction

  // ---------------------------------------------------------------------------
  // Enable the multi-outstanding pipeline on the RN-I and the buffered SN-F.
  // ---------------------------------------------------------------------------
  protected virtual function void configure_agent_cfgs();

    super.rni_cfg.multi_outstanding        = 1'b1;
    super.rni_cfg.multi_outstanding_mixed  = 1'b1;

    // Atomics issue write-like (grant + operand DAT) and a returning atomic
    // completes read-like (CompData), so budget both directions to N.
    super.rni_cfg.max_outstanding_read     = N_C;
    super.rni_cfg.max_outstanding_write    = N_C;
    super.snf_cfg.multi_outstanding        = 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Seed N distinct granules, then pipeline N returning atomics (AtomicLoad0 =
  // arithmetic ADD) over them: each returns its pre-op (seeded) value on
  // CompData while the SN-F RMW writes seed+operand back. Read every granule
  // back to confirm the overlapped read-modify-writes all landed, and assert
  // the atomics actually coexisted in flight (peak > 1).
  // ---------------------------------------------------------------------------
  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t::data_t seed_q  [$];
    item_t::be_t   be_q    [$];
    item_t::data_t op_q    [$];
    item_t::data_t preop   [item_t::addr_t];   // expected returned pre-op value
    item_t::data_t updated [item_t::addr_t];   // expected read-back (seed+operand)
    item_t         wr_rsp  [$];
    item_t         at_rsp  [$];
    item_t         rd_rsp  [$];
    item_t         r;

    // The wide-operand stress profile is out of spec by Table 2-17, on purpose.
    // The rule is turned down to OFF -- still evaluated, still counted, not
    // reported -- and required to have fired before this test ends. See the
    // §22 L7 note in vip_chi_atomic_seq for why both halves are needed.
    super.tb_env.rni_agent.vif.check_severity[VIP_CHI_CHK_ATOMIC_SIZE_LEGAL_E] =
      VIP_CHI_CHK_SEV_OFF_E;
    super.tb_env.snf_agent.vif.check_severity[VIP_CHI_CHK_ATOMIC_SIZE_LEGAL_E] =
      VIP_CHI_CHK_SEV_OFF_E;

    phase.raise_objection(this);

    // Build N distinct (seed, operand) pairs keyed by their granule address.
    for (int k = 0; k < N_C; k++) begin
      item_t::addr_t a;
      item_t::data_t seed;
      item_t::data_t op;
      seed = item_t::data_t'('h0001_0000 + (k * 'h0000_0100));
      op   = item_t::data_t'('h0000_0010 + k);
      seed_q.push_back(seed);
      op_q.push_back(op);
      a = item_t::addr_t'(BASE_ADDR_C + (k * STRIDE_C));
      preop[a]   = seed;
      updated[a] = seed + op;
    end

    // -- Phase 1: seed the N granules with known values (pipelined writes). ----
    super.rni0_wr_seq.reset();
    super.rni0_wr_seq.set_initial_addr(BASE_ADDR_C);
    super.rni0_wr_seq.set_size(SIZE_C);
    super.rni0_wr_seq.set_data(seed_q);           // custom data => bounded by payload
    // Full byte enables for the seeded beat. This is what makes a sub-line write
    // legal: Table A-3 and Chapter 4 fix WriteNoSnpFull at a cache line length,
    // so a single-beat write has to be a WriteNoSnpPtl -- and a Ptl with every
    // byte enabled in its Size window is exactly "write these bytes". Supplying
    // BE is also what selects the Ptl opcode, and it keeps the enables
    // deterministic rather than randomized, which the readback depends on.
    foreach (seed_q[i]) begin
      be_q.push_back('1);
    end
    super.rni0_wr_seq.set_be(be_q);
    super.rni0_wr_seq.set_get_response(1'b1);
    super.rni0_wr_seq.set_pipelined_send(1'b1);
    super.rni0_wr_seq.set_verbose(1'b0);
    super.rni0_wr_seq.start(super.v_sqr.rni_sequencer);

    wr_rsp = super.rni0_wr_seq.get_responses();
    if (wr_rsp.size() != N_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Expected %0d seed-write responses, got %0d",
        super.tc_name, N_C, wr_rsp.size()))
    end

    super.wait_clocks(SETTLE_C);

    // -- Phase 2: pipeline N returning atomics (AtomicLoad0 = ADD). ------------
    this.atomic_seq.reset();
    this.atomic_seq.set_variant(0);              // Load0 => arithmetic ADD, returns pre-op value
    this.atomic_seq.set_initial_addr(BASE_ADDR_C);
    this.atomic_seq.set_size(SIZE_C);
    this.atomic_seq.set_data(op_q);              // one operand beat per atomic
    this.atomic_seq.set_get_response(1'b1);
    this.atomic_seq.set_pipelined_send(1'b1);
    this.atomic_seq.set_verbose(1'b0);
    this.atomic_seq.start(super.v_sqr.rni_sequencer);

    at_rsp = this.atomic_seq.get_responses();
    if (at_rsp.size() != N_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Expected %0d atomic responses, got %0d",
        super.tc_name, N_C, at_rsp.size()))
    end

    foreach (at_rsp[k]) begin
      r = at_rsp[k];

      // A non-store atomic completes on CompData carrying the pre-op value.
      if (r.dat_opcode != item_t::dat_opcode_t'(VIP_CHI_DAT_COMP_DATA_C)) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] Atomic %0d completion DAT opcode 0x%0h was not CompData",
          super.tc_name, k, r.dat_opcode))
      end
      if (!preop.exists(r.addr)) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] Atomic %0d addr 0x%0h has no matching seed",
          super.tc_name, k, r.addr))
      end
      if ((r.data.size() != 1) || (r.data[0] != preop[r.addr])) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] Atomic addr 0x%0h returned 0x%0h, expected pre-op value 0x%0h",
          super.tc_name, r.addr, r.data[0], preop[r.addr]))
      end
    end

    super.wait_clocks(SETTLE_C);

    // -- Phase 3: read every granule back and confirm seed+operand landed. -----
    super.rni0_rd_seq.reset();
    super.rni0_rd_seq.set_requests(N_C);
    super.rni0_rd_seq.set_initial_addr(BASE_ADDR_C);
    super.rni0_rd_seq.set_size(SIZE_C);
    super.rni0_rd_seq.set_get_response(1'b1);
    super.rni0_rd_seq.set_pipelined_send(1'b1);
    super.rni0_rd_seq.set_verbose(1'b0);
    super.rni0_rd_seq.start(super.v_sqr.rni_sequencer);

    rd_rsp = super.rni0_rd_seq.get_responses();
    if (rd_rsp.size() != N_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Expected %0d read responses, got %0d",
        super.tc_name, N_C, rd_rsp.size()))
    end

    foreach (rd_rsp[k]) begin
      r = rd_rsp[k];
      if (!updated.exists(r.addr)) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] Read %0d addr 0x%0h has no matching atomic",
          super.tc_name, k, r.addr))
      end
      if (r.data[0] != updated[r.addr]) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] Atomic RMW mismatch addr 0x%0h: read 0x%0h expected 0x%0h",
          super.tc_name, r.addr, r.data[0], updated[r.addr]))
      end
    end

    if (super.rni_cfg.observed_peak_outstanding <= 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Atomics did not overlap: peak in-flight was %0d (expected > 1)",
        super.tc_name, super.rni_cfg.observed_peak_outstanding))
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] %0d returning atomics (AtomicLoad0) pipelined; pre-op values + RMW read-back verified; peak in-flight = %0d",
      super.tc_name, N_C, super.rni_cfg.observed_peak_outstanding), UVM_LOW)

    // The waiver's second half: this traffic must have been out of spec in the
    // way the profile claims. A silenced rule that stopped firing would look
    // exactly like a passing test.
    if ((super.tb_env.rni_agent.vif.check_fail_count[VIP_CHI_CHK_ATOMIC_SIZE_LEGAL_E] == 0) ||
        (super.tb_env.snf_agent.vif.check_fail_count[VIP_CHI_CHK_ATOMIC_SIZE_LEGAL_E] == 0)) begin
      `uvm_error(get_name(), $sformatf(
        "ERROR [%s] %s recorded no violation at one or both ends, but this test drives the wide-operand stress profile on purpose; either the sizes are legal now and the waiver should go, or the rule stopped evaluating",
        super.tc_name, vip_chi_check_name(VIP_CHI_CHK_ATOMIC_SIZE_LEGAL_E)))
    end

    phase.drop_objection(this);
  endtask

endclass
