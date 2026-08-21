################################################################################
# pyUVM/cocotb port of tc/tc_chi_latency_bound.sv.
#
# Per-transaction latency bounds. A test that cares about latency has to be able
# to FAIL on it, not read it out of a report after the run.
#
# Both halves, because a bound is only meaningful if it does both things:
#   * a generous bound must stay silent on ordinary traffic -- a check that
#     fires on everything is not a bound, it is noise;
#   * a bound tighter than the observed latency must fire, and the report must
#     name the measured value so the reader can see by how much.
#
# The bound is tightened rather than the completer slowed. Both produce the same
# comparison, but a fixed small bound is deterministic: a delay knob would leave
# the test asserting on a margin that depends on how the completer's delays
# happened to land.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from chi_base_test import chi_base_test
from chi_latency_negctl_catcher import chi_latency_negctl_catcher

_ADDR_C = 0x3E00_0000
_SIZE_C = 6                     # 64 B = 4 beats on the CHI-D cut
_GENEROUS_C = 10_000            # far above anything this bench produces
_TIGHT_C = 1                    # below any real read: a read cannot complete in 1


class tc_chi_latency_bound(chi_base_test):

  async def _one_read(self):
    rd = self.rni0_rd_seq
    rd.reset()
    rd.set_requests(1)
    rd.set_initial_addr(_ADDR_C)
    rd.set_size(_SIZE_C)
    rd.set_get_response(True)
    rd.set_verbose(False)
    await rd.start(self.v_sqr.rni_sequencer)

  async def run_phase(self):
    self.raise_objection()

    mon = self.tb_env.rni_agent.monitor

    # -- Generous bound: ordinary traffic must not trip it. --------------------
    mon.max_read_xact_latency = _GENEROUS_C
    await self._one_read()
    await self.wait_clocks(20)

    assert mon.n_latency_violation == 0, (
      f"{mon.n_latency_violation} latency violation(s) under a bound of "
      f"{_GENEROUS_C} cycles -- the check is firing on ordinary traffic")

    # -- Tight bound: the same traffic must trip it, exactly once. -------------
    catcher = chi_latency_negctl_catcher("latency_negctl_catcher")
    mon.logger.addFilter(catcher)
    try:
      mon.max_read_xact_latency = _TIGHT_C
      await self._one_read()
      await self.wait_clocks(20)
    finally:
      # A failed assertion below must not leave the filter installed on a logger
      # that outlives this test.
      mon.logger.removeFilter(catcher)
      mon.max_read_xact_latency = 0

    assert catcher.saw_latency_error, (
      f"a read was not flagged against a bound of {_TIGHT_C} cycle(s) -- the "
      f"latency check may be vacuous")
    assert catcher.n_latency_errors == 1, (
      f"one over-budget read produced {catcher.n_latency_errors} reports, "
      f"expected exactly 1")
    assert mon.n_latency_violation == 1, (
      f"the monitor's violation counter reads {mon.n_latency_violation}, "
      f"expected 1 -- the counter and the report disagree")

    self.logger.info(
      f"Test (tc_chi_latency_bound) PASS: silent at {_GENEROUS_C} cycles, "
      f"flagged exactly once at {_TIGHT_C}")
    self.drop_objection()
