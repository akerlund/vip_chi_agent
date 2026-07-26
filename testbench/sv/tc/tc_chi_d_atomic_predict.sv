// Exercise the scoreboard's Checker-C atomic RMW prediction across variants.
//
// The predictor can only model an atomic whose target was previously observed
// written (its pre-op value must be known and not an SN-F-synthesized pattern),
// and it works at full-beat granularity. So each variant here first seeds its
// target with a known full-beat WRITE, then issues the atomic, then reads the
// granule back. The scoreboard independently predicts the returned pre-op value
// (returning atomics) and the committed post-op value (checked by the read-back)
// -- a silent skip would leave the feature unverified, so this test is the
// regression guard that keeps the prediction live. The test also self-checks the
// same values so it fails loudly even with the scoreboard disabled.
class tc_chi_d_atomic_predict extends chi_base_test;

  // item_t is the package-level typedef (chi_tb_pkg). Do NOT re-typedef it
  // at class scope: a shadowing `typedef vip_chi_item #(CHI_D_CFG_C) item_t;` used
  // in a localparam type below sends VCS elaboration into an infinite spin.
  `uvm_component_utils(tc_chi_d_atomic_predict)

  localparam item_t::addr_t STORE_ADDR_C   = item_t::addr_t'(44'h3A00_0000);
  localparam item_t::addr_t SWAP_ADDR_C    = item_t::addr_t'(44'h3A00_0100);
  localparam item_t::addr_t COMPARE_ADDR_C = item_t::addr_t'(44'h3A00_0200);
  localparam int            SETTLE_C       = 8;

  vip_chi_atomic_seq #(CHI_D_CFG_C) atomic_seq;

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

  // Seed one full-beat granule with a known value via an observed write.

  // ---------------------------------------------------------------------------
  // Seed Write
  // ---------------------------------------------------------------------------
  protected task seed_write(
    input item_t::addr_t addr,
    input item_t::data_t value,
    input item_t::size_t beat_size
  );

    item_t::data_t data_q[$];
    item_t         wr_rsp[$];

    data_q.delete();
    data_q.push_back(value);
    super.rni0_wr_seq.reset();
    super.rni0_wr_seq.set_initial_addr(addr);
    super.rni0_wr_seq.set_size(beat_size);
    super.rni0_wr_seq.set_allow_retry(1'b0);
    super.rni0_wr_seq.set_data(data_q);
    super.rni0_wr_seq.set_get_response(1'b1);
    super.rni0_wr_seq.set_verbose(1'b0);
    super.rni0_wr_seq.start(super.v_sqr.rni_sequencer);

    wr_rsp = super.rni0_wr_seq.get_responses();
    if (wr_rsp.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] seed write to 0x%0h expected 1 response, got %0d",
        super.tc_name, addr, wr_rsp.size()))
    end
    super.wait_clocks(SETTLE_C);
  endtask

  // Read one full-beat granule back and check it against the expected post-op.

  // ---------------------------------------------------------------------------
  // Read Check
  // ---------------------------------------------------------------------------
  protected task read_check(
    input item_t::addr_t addr,
    input item_t::data_t expected,
    input item_t::size_t beat_size,
    input string         label
  );

    item_t rd_rsp[$];

    super.rni0_rd_seq.reset();
    super.rni0_rd_seq.set_requests(1);
    super.rni0_rd_seq.set_initial_addr(addr);
    super.rni0_rd_seq.set_size(beat_size);
    super.rni0_rd_seq.set_allow_retry(1'b0);
    super.rni0_rd_seq.set_get_response(1'b1);
    super.rni0_rd_seq.set_verbose(1'b0);
    super.rni0_rd_seq.start(super.v_sqr.rni_sequencer);

    rd_rsp = super.rni0_rd_seq.get_responses();
    if ((rd_rsp.size() != 1) || (rd_rsp[0].data.size() != 1) ||
        (rd_rsp[0].data[0] != expected)) begin

      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] %s read-back 0x%0h != expected 0x%0h",
      super.tc_name, label,
      (rd_rsp.size() > 0 && rd_rsp[0].data.size() > 0) ? rd_rsp[0].data[0] : '0,
      expected))
    end
  endtask

  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t         at_rsp[$];
    item_t::data_t data_q[$];
    item_t::size_t beat_size;
    item_t::data_t store_seed, store_op;
    item_t::data_t swap_seed, swap_op;
    item_t::data_t cmp_seed, cmp_swap;

    phase.raise_objection(this);

    beat_size  = item_t::size_t'($clog2(CHI_D_CFG_C.DATA_BYTES_P));
    store_seed = item_t::data_t'('h0000_1000);
    store_op   = item_t::data_t'('h0000_0025);
    swap_seed  = item_t::data_t'('hCAFE_0001);
    swap_op    = item_t::data_t'('h0BAD_F00D);
    cmp_seed   = item_t::data_t'('h1234_5678);
    cmp_swap   = item_t::data_t'('h9999_AAAA);

    // -- AtomicStore0 (ADD), non-returning: commit path resolves on the Comp. --
    this.seed_write(STORE_ADDR_C, store_seed, beat_size);
    this.atomic_seq.reset();
    this.atomic_seq.set_atomic_op(VIP_CHI_ATOMIC_OP_STORE_0_E);
    this.atomic_seq.set_requests(1);
    this.atomic_seq.set_initial_addr(STORE_ADDR_C);
    this.atomic_seq.set_size(beat_size);
    this.atomic_seq.set_allow_retry(1'b0);
    this.atomic_seq.set_get_response(1'b1);
    this.atomic_seq.set_verbose(1'b0);

    data_q.delete();
    data_q.push_back(store_op);

    this.atomic_seq.set_data(data_q);
    this.atomic_seq.start(super.v_sqr.rni_sequencer);
    at_rsp = this.atomic_seq.get_responses();

    if (at_rsp.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] AtomicStore0 expected 1 response",
      super.tc_name))
    end

    super.wait_clocks(SETTLE_C);
    this.read_check(STORE_ADDR_C, item_t::data_t'(store_seed + store_op),
                    beat_size, "AtomicStore0(ADD)");

    // -- AtomicSwap, returning: return == pre-op seed, store == operand. -------
    this.seed_write(SWAP_ADDR_C, swap_seed, beat_size);
    this.atomic_seq.reset();
    this.atomic_seq.set_atomic_op(VIP_CHI_ATOMIC_OP_SWAP_E);
    this.atomic_seq.set_requests(1);
    this.atomic_seq.set_initial_addr(SWAP_ADDR_C);
    this.atomic_seq.set_size(beat_size);
    this.atomic_seq.set_allow_retry(1'b0);
    this.atomic_seq.set_get_response(1'b1);
    this.atomic_seq.set_verbose(1'b0);
    data_q.delete();
    data_q.push_back(swap_op);
    this.atomic_seq.set_data(data_q);
    this.atomic_seq.start(super.v_sqr.rni_sequencer);
    at_rsp = this.atomic_seq.get_responses();

    if ((at_rsp.size() != 1) || (at_rsp[0].data.size() != 1) ||
        (at_rsp[0].data[0] != swap_seed)) begin

      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] AtomicSwap did not return the pre-op seed",
      super.tc_name))
    end

    super.wait_clocks(SETTLE_C);
    this.read_check(SWAP_ADDR_C, swap_op, beat_size, "AtomicSwap");

    // -- AtomicCompare (match): return == pre-op seed, store == swap value. ----
    this.seed_write(COMPARE_ADDR_C, cmp_seed, beat_size);
    this.atomic_seq.reset();
    this.atomic_seq.set_atomic_op(VIP_CHI_ATOMIC_OP_COMPARE_E);
    this.atomic_seq.set_requests(1);
    this.atomic_seq.set_initial_addr(COMPARE_ADDR_C);
    // AtomicCompare Size is the COMBINED compare+swap size (IHI 0050): two
    // beat_size operands -> Size = beat_size + 1. Seed/read-back stay at the
    // per-operand granule (beat_size). [P2]
    this.atomic_seq.set_size(item_t::size_t'(beat_size + 1));
    this.atomic_seq.set_allow_retry(1'b0);
    this.atomic_seq.set_get_response(1'b1);
    this.atomic_seq.set_verbose(1'b0);
    data_q.delete();
    data_q.push_back(cmp_seed);   // compare value == seed => match
    data_q.push_back(cmp_swap);   // swap value stored on match
    this.atomic_seq.set_data(data_q);
    this.atomic_seq.start(super.v_sqr.rni_sequencer);

    at_rsp = this.atomic_seq.get_responses();
    if ((at_rsp.size() != 1) || (at_rsp[0].data.size() != 1) ||
        (at_rsp[0].data[0] != cmp_seed)) begin

      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] AtomicCompare did not return the pre-op seed",
      super.tc_name))
    end

    super.wait_clocks(SETTLE_C);
    this.read_check(COMPARE_ADDR_C, cmp_swap, beat_size, "AtomicCompare(match)");

    `uvm_info(get_name(), $sformatf(
    "INFO [%s] atomic RMW prediction exercised: Store0(ADD), Swap, Compare(match) seeded, applied, read back",
    super.tc_name), UVM_LOW)

    phase.drop_objection(this);
  endtask
endclass
