// ---------------------------------------------------------------------------
// Per-channel transmit delay: cycles the driver holds an assembled flit before
// asking for a credit and asserting FLITV.
//
// This test exists because the knobs it drives spent a long time doing nothing.
// req/rsp/dat_valid_delay_{enabled,min,max} were declared in both config ports,
// validated by is_valid(), listed in the README and described by the
// implementation notes as active -- while no driver in either port ever read
// them. Configuration that no test drives is indistinguishable from
// configuration that does not work.
//
// Measured in cycles of elapsed simulation time over an identical burst, with
// min == max so the draw is fixed rather than random -- a random window makes
// the expectation a range, and a range wide enough to be safe is wide enough to
// pass on a delay that only fired once.
//
// The growth against the undelayed baseline is deliberately NOT asserted to be
// N * D. A delay can overlap a wait the driver would have made anyway -- chiefly
// waiting for an L-credit to come back -- so the first few cycles of each delay
// are absorbed into slack that already existed, and the burst grows by slightly
// less. That is correct behaviour, not a defect: the knob holds the flit before
// asking for credit, and if credit was not ready the hold costs nothing.
//
// What IS exact is the INCREMENT between two delay widths. Per request the added
// time is max(0, D - slack), so once D exceeds the slack the extra is fully
// additive, and going from D to 2D must cost exactly N * D more. That is the
// assertion that says every one of the N requests paid, not just one of them.
//
// The last phase is the control that matters most: with the window still set
// and the enable off, the burst must take EXACTLY the baseline again. It is what
// separates "the enable gates the delay" from "the window is applied
// unconditionally and the enable is decoration", which is the exact failure mode
// this whole family already had once.
//
// Disjoint address ranges throughout, one per burst, so every burst writes fresh
// backing rows and the phases differ only in the knob under test.
// ---------------------------------------------------------------------------

class tc_chi_channel_delay extends chi_base_test;

  // item_t is the package typedef from chi_tb_pkg (vip_chi_item #(CHI_D_CFG_C)).
  // Do NOT redeclare it at class scope here. An identical class-scoped typedef
  // compiles and runs correctly, but the six `localparam item_t::addr_t X =
  // item_t::addr_t'(...)` below then cast through the CLASS-scoped name, and VCS
  // re-elaborates the parameterized specialization for each one: measured 12s ->
  // >7min, i.e. the build never finishes in practice. Removing the redundant
  // typedef alone takes it back to 12s. Sibling tests using this same localparam
  // pattern (tc_chi_dat_interleave and friends) inherit the package typedef and
  // are unaffected -- the hazard is the duplicate, not the pattern.

  `uvm_component_utils(tc_chi_channel_delay)

  localparam int N_C          = 8;      // requests per phase
  localparam int DELAY_C      = 4;      // fixed delay width, in cycles
  localparam int SIZE_C       = 6;
  localparam int SETTLE_C     = 20;
  localparam int CLK_PERIOD_C = 10;     // ns, matches chi_tb_top

  localparam item_t::addr_t BASE_W_C = item_t::addr_t'(44'h3000_0000); // warm-up
  localparam item_t::addr_t BASE_A_C = item_t::addr_t'(44'h3100_0000);
  localparam item_t::addr_t BASE_B_C = item_t::addr_t'(44'h3200_0000);
  localparam item_t::addr_t BASE_C_C = item_t::addr_t'(44'h3300_0000);
  localparam item_t::addr_t BASE_D_C = item_t::addr_t'(44'h3400_0000);
  localparam item_t::addr_t STRIDE_C = item_t::addr_t'(44'h1000);

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  // One burst of N_C writes from `base`, returning how many clock cycles it
  // took. The sequence is reconfigured identically every time, so the only thing
  // that can move the number is the delay knob.
  // ---------------------------------------------------------------------------
  protected task run_burst(input item_t::addr_t base, output int unsigned cycles);

    time t0;

    t0 = $time;

    super.rni0_wr_seq.reset();
    super.rni0_wr_seq.set_requests(N_C);
    super.rni0_wr_seq.set_initial_addr(base);
    super.rni0_wr_seq.set_addr_stride(STRIDE_C);
    super.rni0_wr_seq.set_size(SIZE_C);
    super.rni0_wr_seq.set_allow_retry(1'b0);
    super.rni0_wr_seq.set_get_response(1'b1);
    super.rni0_wr_seq.set_verbose(1'b0);
    super.rni0_wr_seq.start(super.tb_env.rni_agent.sequencer);

    cycles = int'(($time - t0) / CLK_PERIOD_C);
  endtask

  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    int unsigned warm_cycles;
    int unsigned base_cycles;
    int unsigned single_cycles;
    int unsigned double_cycles;
    int unsigned gated_cycles;
    int unsigned step;

    phase.raise_objection(this);

    super.drain_observation_fifos();

    super.rni_cfg.req_valid_delay_enabled = 1'b0;
    super.rni_cfg.dat_valid_delay_enabled = 1'b0;

    // A warm-up burst, measured and thrown away. The FIRST burst after link
    // bring-up is a few cycles slower than every later one, and comparing a
    // later burst against it would report that difference as the knob's doing.
    this.run_burst(BASE_W_C, warm_cycles);
    super.wait_clocks(SETTLE_C);

    // ---- Phase A: the delay off, which is the shipped default ---------------
    this.run_burst(BASE_A_C, base_cycles);
    super.wait_clocks(SETTLE_C);

    if (base_cycles == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the baseline burst took no time at all, so nothing was measured",
        super.tc_name))
    end

    // ---- Phase B: REQ delayed by DELAY_C ------------------------------------
    super.rni_cfg.req_valid_delay_enabled = 1'b1;
    super.rni_cfg.req_valid_delay_min     = DELAY_C;
    super.rni_cfg.req_valid_delay_max     = DELAY_C;
    this.run_burst(BASE_B_C, single_cycles);
    super.wait_clocks(SETTLE_C);

    if (single_cycles <= base_cycles) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the delayed burst took %0d cycles against a %0d-cycle baseline: the delay never reached the wire",
        super.tc_name, single_cycles, base_cycles))
    end

    // ---- Phase C: the same burst at twice the delay -------------------------
    super.rni_cfg.req_valid_delay_min = 2 * DELAY_C;
    super.rni_cfg.req_valid_delay_max = 2 * DELAY_C;
    this.run_burst(BASE_C_C, double_cycles);
    super.wait_clocks(SETTLE_C);

    step = double_cycles - single_cycles;
    if (step != (N_C * DELAY_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] doubling the delay from %0d to %0d cycles cost %0d more cycles over %0d requests, expected exactly %0d: the delay is not being paid once per request",
        super.tc_name, DELAY_C, 2 * DELAY_C, step, N_C, N_C * DELAY_C))
    end

    // ---- Phase D: the window still set, the enable back off -----------------
    super.rni_cfg.req_valid_delay_enabled = 1'b0;
    this.run_burst(BASE_D_C, gated_cycles);
    super.wait_clocks(SETTLE_C);

    if (gated_cycles != base_cycles) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] with the enable off and the window still %0d..%0d, the burst took %0d cycles against a %0d-cycle baseline: the enable does not gate the delay",
        super.tc_name, 2 * DELAY_C, 2 * DELAY_C, gated_cycles, base_cycles))
    end

    super.wait_clocks(SETTLE_C);
    super.drain_observation_fifos();

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] %0d writes took %0d cycles undelayed, %0d at a %0d-cycle REQ delay and %0d at %0d (a step of %0d, exactly %0d x %0d), and %0d again with the enable off",
      super.tc_name, N_C, base_cycles, single_cycles, DELAY_C, double_cycles,
      2 * DELAY_C, step, N_C, DELAY_C, gated_cycles), UVM_LOW)

    phase.drop_objection(this);
  endtask
endclass
