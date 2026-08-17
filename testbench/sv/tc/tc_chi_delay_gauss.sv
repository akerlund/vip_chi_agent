// ---------------------------------------------------------------------------
// Truncated-gaussian shaping of the per-channel transmit delay: the same window
// as the uniform draw, but concentrated around a mean instead of spread flat.
//
// This is a DISTRIBUTION test, and distribution tests are where vacuous checks
// hide most easily -- a bound loose enough never to flake is usually loose
// enough to pass on a uniform draw, which would make the whole feature
// unobservable. So the assertions here are the ones a uniform draw actually
// fails:
//
//   * the mean of the shaped draws sits near the configured mean. Uniform over
//     the same window has its own mean, so this only separates the two when the
//     configured mean is deliberately OFF-CENTRE -- which is why it is, at 1 in
//     a 0..8 window (uniform would centre at 4).
//   * the configured mean's own bucket is the most frequent one. Uniform has no
//     mode at all, so any single bucket dominating by a real margin is evidence
//     of shaping rather than of luck.
//   * every draw lands inside [min, max]. Truncation is the "truncated" half of
//     truncated-gaussian, and a CDF built over the window cannot produce
//     anything outside it -- but that is exactly the kind of claim worth an
//     assertion rather than a comment.
//
// Drawn straight from the config rather than through the wire. A flit-level
// measurement of a distribution needs hundreds of transactions to say anything,
// and would be measuring the driver's plumbing (proven by tc_chi_channel_delay)
// a second time rather than the shape. Here the delay reaching the wire and the
// shape of the number are two claims, tested once each.
//
// The last phase is the control: with gauss switched back off and the same
// window, the draws must spread out again. Without it, "the numbers cluster" is
// equally consistent with a CDF that was never built and a window that happens
// to be narrow.
// ---------------------------------------------------------------------------

class tc_chi_delay_gauss extends chi_base_test;

  `uvm_component_utils(tc_chi_delay_gauss)

  localparam int  DRAWS_C        = 4000;
  localparam int  DELAY_MIN_C    = 0;
  localparam int  DELAY_MAX_C    = 8;
  // Deliberately off the window's centre (4), so a uniform draw cannot pass the
  // mean check by accident.
  localparam int  DELAY_MEAN_C   = 1;
  localparam real DELAY_STDDEV_C = 1.0;

  // The sample mean of 4000 draws is tight; 0.5 cycles is wide enough that this
  // never flakes and far narrower than the 3.0 that separates it from uniform.
  localparam real MEAN_TOLERANCE_C = 0.5;

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  // DRAWS_C draws from the REQ channel, bucketed by value.
  // ---------------------------------------------------------------------------
  protected task draw_histogram(output int counts [DELAY_MAX_C + 1]);

    int unsigned value;

    foreach (counts[i]) begin
      counts[i] = 0;
    end

    repeat (DRAWS_C) begin

      value = super.rni_cfg.draw_req_valid_delay();

      if ((value < DELAY_MIN_C) || (value > DELAY_MAX_C)) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] a delay draw returned %0d, outside the configured window %0d..%0d",
          super.tc_name, value, DELAY_MIN_C, DELAY_MAX_C))
      end

      counts[value]++;
    end
  endtask

  // ---------------------------------------------------------------------------
  // Mean of a bucketed histogram.
  // ---------------------------------------------------------------------------
  protected function real histogram_mean(input int counts [DELAY_MAX_C + 1]);

    int  total;
    real weighted;

    total    = 0;
    weighted = 0.0;

    foreach (counts[value]) begin
      total    += counts[value];
      weighted += real'(value) * real'(counts[value]);
    end

    return weighted / real'(total);
  endfunction

  // ---------------------------------------------------------------------------
  // Index of the most frequent bucket.
  // ---------------------------------------------------------------------------
  protected function int histogram_mode(input int counts [DELAY_MAX_C + 1]);

    histogram_mode = 0;

    foreach (counts[value]) begin
      if (counts[value] > counts[histogram_mode]) begin
        histogram_mode = value;
      end
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    int  shaped [DELAY_MAX_C + 1];
    int  flat   [DELAY_MAX_C + 1];
    real shaped_mean;
    real flat_mean;
    int  mode;

    phase.raise_objection(this);

    super.rni_cfg.req_valid_delay_enabled = 1'b1;
    super.rni_cfg.req_valid_delay_min     = DELAY_MIN_C;
    super.rni_cfg.req_valid_delay_max     = DELAY_MAX_C;
    super.rni_cfg.req_valid_delay_mean    = DELAY_MEAN_C;
    super.rni_cfg.req_valid_delay_stddev  = DELAY_STDDEV_C;

    // ---- Shaped -------------------------------------------------------------
    super.rni_cfg.req_valid_delay_gauss_enabled = 1'b1;
    this.draw_histogram(shaped);
    shaped_mean = this.histogram_mean(shaped);

    if (((shaped_mean - real'(DELAY_MEAN_C)) >  MEAN_TOLERANCE_C) ||
        ((shaped_mean - real'(DELAY_MEAN_C)) < -MEAN_TOLERANCE_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %0d shaped draws averaged %0.3f, expected within %0.3f of the configured mean %0d",
        super.tc_name, DRAWS_C, shaped_mean, MEAN_TOLERANCE_C, DELAY_MEAN_C))
    end

    mode = this.histogram_mode(shaped);
    if (mode != DELAY_MEAN_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the most frequent shaped delay was %0d (%0d draws), expected the configured mean %0d (%0d draws): the draws are not centred on it",
        super.tc_name, mode, shaped[mode], DELAY_MEAN_C, shaped[DELAY_MEAN_C]))
    end

    // ---- Uniform, same window: the control ---------------------------------
    super.rni_cfg.req_valid_delay_gauss_enabled = 1'b0;
    this.draw_histogram(flat);
    flat_mean = this.histogram_mean(flat);

    if (((flat_mean - real'(DELAY_MEAN_C)) <=  MEAN_TOLERANCE_C) &&
        ((flat_mean - real'(DELAY_MEAN_C)) >= -MEAN_TOLERANCE_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] with gauss off, %0d draws over the same window still averaged %0.3f, within %0.3f of the gaussian mean %0d: the two shapes are indistinguishable, so this test proves nothing about either",
        super.tc_name, DRAWS_C, flat_mean, MEAN_TOLERANCE_C, DELAY_MEAN_C))
    end

    // The shaped run must be visibly more concentrated than the flat one, or
    // "centred on the mean" was measuring noise.
    if (shaped[DELAY_MEAN_C] <= (2 * flat[DELAY_MEAN_C])) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the shaped draws put %0d samples on the mean against %0d for a uniform draw over the same window: not concentrated enough to be a distinguishable shape",
        super.tc_name, shaped[DELAY_MEAN_C], flat[DELAY_MEAN_C]))
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] %0d shaped draws over %0d..%0d averaged %0.3f against a configured mean of %0d and peaked there with %0d samples, while the same window drawn uniformly averaged %0.3f and put %0d there",
      super.tc_name, DRAWS_C, DELAY_MIN_C, DELAY_MAX_C, shaped_mean,
      DELAY_MEAN_C, shaped[DELAY_MEAN_C], flat_mean, flat[DELAY_MEAN_C]), UVM_LOW)

    phase.drop_objection(this);
  endtask
endclass
