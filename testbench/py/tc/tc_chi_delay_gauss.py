################################################################################
# pyUVM/cocotb port of tc/tc_chi_delay_gauss.sv.
#
# Truncated-gaussian shaping of the per-channel transmit delay: the same window
# as the uniform draw, but concentrated around a mean instead of spread flat.
#
# This is a DISTRIBUTION test, and distribution tests are where vacuous checks
# hide most easily -- a bound loose enough never to flake is usually loose
# enough to pass on a uniform draw, which would make the whole feature
# unobservable. So the assertions here are the ones a uniform draw actually
# fails:
#
#   * the mean of the shaped draws sits near the configured mean. Uniform over
#     the same window has its own mean, so this only separates the two when the
#     configured mean is deliberately OFF-CENTRE -- which is why it is, at 1 in
#     a 0..8 window (uniform would centre at 4).
#   * the configured mean's own bucket is the most frequent one. Uniform has no
#     mode at all, so any single bucket dominating by a real margin is evidence
#     of shaping rather than of luck.
#   * every draw lands inside [min, max]. Truncation is the "truncated" half of
#     truncated-gaussian, and a CDF built over the window cannot produce
#     anything outside it -- but that is exactly the kind of claim worth an
#     assertion rather than a comment.
#
# Drawn straight from the config rather than through the wire. A flit-level
# measurement of a distribution needs hundreds of transactions to say anything,
# and would be measuring the driver's plumbing (proven by tc_chi_channel_delay)
# a second time rather than the shape. Here the delay reaching the wire and the
# shape of the number are two claims, tested once each.
#
# The last phase is the control: with gauss switched back off and the same
# window, the draws must spread out again. Without it, "the numbers cluster" is
# equally consistent with a CDF that was never built and a window that happens
# to be narrow.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from chi_base_test import chi_base_test

DRAWS_C = 4000
DELAY_MIN_C = 0
DELAY_MAX_C = 8
# Deliberately off the window's centre (4), so a uniform draw cannot pass the
# mean check by accident.
DELAY_MEAN_C = 1
DELAY_STDDEV_C = 1.0

# The sample mean of 4000 draws is tight; 0.5 cycles is wide enough that this
# never flakes and far narrower than the 3.0 that separates it from uniform.
MEAN_TOLERANCE_C = 0.5


class tc_chi_delay_gauss(chi_base_test):

  def _draw_histogram(self, draws):
    counts = [0] * (DELAY_MAX_C + 1)
    for _ in range(draws):
      value = self.rni_cfg.draw_req_valid_delay()
      assert DELAY_MIN_C <= value <= DELAY_MAX_C, (
        f"a delay draw returned {value}, outside the configured window "
        f"{DELAY_MIN_C}..{DELAY_MAX_C}")
      counts[value] += 1
    return counts

  @staticmethod
  def _mean(counts):
    total = sum(counts)
    return sum(value * n for value, n in enumerate(counts)) / total

  async def run_phase(self):
    self.raise_objection()

    self.rni_cfg.req_valid_delay_enabled = True
    self.rni_cfg.req_valid_delay_min = DELAY_MIN_C
    self.rni_cfg.req_valid_delay_max = DELAY_MAX_C
    self.rni_cfg.req_valid_delay_mean = DELAY_MEAN_C
    self.rni_cfg.req_valid_delay_stddev = DELAY_STDDEV_C

    # ---- Shaped ------------------------------------------------------------
    self.rni_cfg.req_valid_delay_gauss_enabled = True
    shaped = self._draw_histogram(DRAWS_C)
    shaped_mean = self._mean(shaped)

    assert abs(shaped_mean - DELAY_MEAN_C) <= MEAN_TOLERANCE_C, (
      f"{DRAWS_C} shaped draws averaged {shaped_mean:.3f}, expected within "
      f"{MEAN_TOLERANCE_C} of the configured mean {DELAY_MEAN_C}")

    mode = shaped.index(max(shaped))
    assert mode == DELAY_MEAN_C, (
      f"the most frequent shaped delay was {mode} ({shaped[mode]} draws), "
      f"expected the configured mean {DELAY_MEAN_C} "
      f"({shaped[DELAY_MEAN_C]} draws): the draws are not centred on it")

    # ---- Uniform, same window: the control ---------------------------------
    self.rni_cfg.req_valid_delay_gauss_enabled = False
    flat = self._draw_histogram(DRAWS_C)
    flat_mean = self._mean(flat)

    assert abs(flat_mean - DELAY_MEAN_C) > MEAN_TOLERANCE_C, (
      f"with gauss off, {DRAWS_C} draws over the same window still averaged "
      f"{flat_mean:.3f}, within {MEAN_TOLERANCE_C} of the gaussian mean "
      f"{DELAY_MEAN_C}: the two shapes are indistinguishable, so this test "
      f"proves nothing about either")

    # The shaped run must be visibly more concentrated than the flat one, or
    # "centred on the mean" was measuring noise.
    assert shaped[DELAY_MEAN_C] > 2 * flat[DELAY_MEAN_C], (
      f"the shaped draws put {shaped[DELAY_MEAN_C]} samples on the mean against "
      f"{flat[DELAY_MEAN_C]} for a uniform draw over the same window: not "
      f"concentrated enough to be a distinguishable shape")

    self.logger.info(
      f"Test (tc_chi_delay_gauss) PASS: {DRAWS_C} shaped draws over "
      f"{DELAY_MIN_C}..{DELAY_MAX_C} averaged {shaped_mean:.3f} against a "
      f"configured mean of {DELAY_MEAN_C} and peaked there with "
      f"{shaped[DELAY_MEAN_C]} samples, while the same window drawn uniformly "
      f"averaged {flat_mean:.3f} and put {flat[DELAY_MEAN_C]} there")
    self.drop_objection()
