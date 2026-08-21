################################################################################
# pyUVM/cocotb port of tc/tc_chi_channel_delay.sv.
#
# Per-channel transmit delay: cycles the driver holds an assembled flit before
# asking for a credit and asserting FLITV.
#
# This test exists because the knobs it drives spent a long time doing nothing.
# req/rsp/dat_valid_delay_{enabled,min,max} were declared in both config ports,
# validated by is_valid(), listed in the README and described by the
# implementation notes as active -- while no driver in either port ever read
# them. Configuration that no test drives is indistinguishable from
# configuration that does not work.
#
# Measured in cycles of elapsed simulation time over an identical burst, with
# min == max so the draw is fixed rather than random -- a random window makes
# the expectation a range, and a range wide enough to be safe is wide enough to
# pass on a delay that only fired once.
#
# The growth against the undelayed baseline is deliberately NOT asserted to be
# N * D. A delay can overlap a wait the driver would have made anyway -- chiefly
# waiting for an L-credit to come back -- so the first few cycles of each delay
# are absorbed into slack that already existed, and the burst grows by slightly
# less. That is correct behaviour, not a defect: the knob holds the flit before
# asking for credit, and if credit was not ready the hold costs nothing.
#
# What IS exact is the INCREMENT between two delay widths. Per request the added
# time is max(0, D - slack), so once D exceeds the slack the extra is fully
# additive, and going from D to 2D must cost exactly N * D more. That is the
# assertion that says every one of the N requests paid, not just one of them.
#
# The last phase is the control that matters most: with the window still set
# and the enable off, the burst must take EXACTLY the baseline again. It is what
# separates "the enable gates the delay" from "the window is applied
# unconditionally and the enable is decoration", which is the exact failure mode
# this whole family already had once.
#
# Disjoint address ranges throughout, one per burst, so every burst writes fresh
# backing rows and the phases differ only in the knob under test.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from cocotb.utils import get_sim_time

from chi_base_test import chi_base_test

N_C = 8                         # requests per phase
DELAY_C = 4                     # fixed delay width, in cycles
SIZE_C = 6
SETTLE_C = 20
CLK_PERIOD_C = 10               # ns, matches chi_tb_top

BASE_W_C = 0x3000_0000          # warm-up, discarded
BASE_A_C = 0x3100_0000
BASE_B_C = 0x3200_0000
BASE_C_C = 0x3300_0000
BASE_D_C = 0x3400_0000
STRIDE_C = 0x1000


class tc_chi_channel_delay(chi_base_test):

  # ---------------------------------------------------------------------------
  # One burst of N_C writes from `base`, returning how many clock cycles it
  # took. The sequence is reconfigured identically every time, so the only thing
  # that can move the number is the delay knob.
  # ---------------------------------------------------------------------------
  async def run_burst(self, base):
    t0 = get_sim_time("ns")

    seq = self.rni0_wr_seq
    seq.reset()
    seq.set_requests(N_C)
    seq.set_initial_addr(base)
    seq.set_addr_stride(STRIDE_C)
    seq.set_size(SIZE_C)
    seq.set_get_response(True)
    seq.set_verbose(False)
    await seq.start(self.v_sqr.rni_sequencer)

    return int((get_sim_time("ns") - t0) // CLK_PERIOD_C)

  async def run_phase(self):
    self.raise_objection()

    self.drain_observation_fifos()

    self.rni_cfg.req_valid_delay_enabled = False
    self.rni_cfg.dat_valid_delay_enabled = False

    # A warm-up burst, measured and thrown away. The FIRST burst after link
    # bring-up is a few cycles slower than every later one, and comparing a
    # later burst against it would report that difference as the knob's doing.
    await self.run_burst(BASE_W_C)
    await self.wait_clocks(SETTLE_C)

    # ---- Phase A: the delay off, which is the shipped default ---------------
    base_cycles = await self.run_burst(BASE_A_C)
    await self.wait_clocks(SETTLE_C)

    assert base_cycles > 0, (
      "the baseline burst took no time at all, so nothing was measured")

    # ---- Phase B: REQ delayed by DELAY_C ------------------------------------
    self.rni_cfg.req_valid_delay_enabled = True
    self.rni_cfg.req_valid_delay_min = DELAY_C
    self.rni_cfg.req_valid_delay_max = DELAY_C
    single_cycles = await self.run_burst(BASE_B_C)
    await self.wait_clocks(SETTLE_C)

    assert single_cycles > base_cycles, (
      f"the delayed burst took {single_cycles} cycles against a "
      f"{base_cycles}-cycle baseline: the delay never reached the wire")

    # ---- Phase C: the same burst at twice the delay -------------------------
    self.rni_cfg.req_valid_delay_min = 2 * DELAY_C
    self.rni_cfg.req_valid_delay_max = 2 * DELAY_C
    double_cycles = await self.run_burst(BASE_C_C)
    await self.wait_clocks(SETTLE_C)

    step = double_cycles - single_cycles
    assert step == N_C * DELAY_C, (
      f"doubling the delay from {DELAY_C} to {2 * DELAY_C} cycles cost "
      f"{step} more cycles over {N_C} requests, expected exactly "
      f"{N_C * DELAY_C}: the delay is not being paid once per request")

    # ---- Phase D: the window still set, the enable back off -----------------
    self.rni_cfg.req_valid_delay_enabled = False
    gated_cycles = await self.run_burst(BASE_D_C)
    await self.wait_clocks(SETTLE_C)

    assert gated_cycles == base_cycles, (
      f"with the enable off and the window still {2 * DELAY_C}..{2 * DELAY_C}, "
      f"the burst took {gated_cycles} cycles against a {base_cycles}-cycle "
      f"baseline: the enable does not gate the delay")

    await self.wait_clocks(SETTLE_C)
    self.drain_observation_fifos()

    self.logger.info(
      f"Test (tc_chi_channel_delay) PASS: {N_C} writes took {base_cycles} "
      f"cycles undelayed, {single_cycles} at a {DELAY_C}-cycle REQ delay and "
      f"{double_cycles} at {2 * DELAY_C} (a step of {step}, exactly "
      f"{N_C} x {DELAY_C}), and {gated_cycles} again with the enable off")
    self.drop_objection()
