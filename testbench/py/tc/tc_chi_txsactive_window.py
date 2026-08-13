################################################################################
# pyUVM/cocotb port of tc/tc_chi_txsactive_window.sv.
#
# TXSACTIVE reports that this node MAY have snoopable transactions outstanding,
# so it has to stay asserted across that WHOLE window. The distinction this test
# exists to pin down is between that and a signal merely bracketing each flit:
# both look identical on the cycles carrying flits, and differ only in the gaps
# between them -- which is exactly the interval a receiver reads the sideband to
# decide whether it can gate its snoop logic.
#
# So the evidence is collected in the gaps, on both ends of the link, and the
# traffic is chosen to be the shape that tells the two apart:
#
#   * The requester runs PIPELINED. A sideband scoped to one transaction looks
#     correct on a single serial read -- it rises with the REQ and falls at the
#     completion either way. It is only with several reads overlapping that the
#     difference shows: the sideband must survive the FIRST read retiring while
#     its peers are still in flight, which is a statement about the count of
#     outstanding transactions rather than about any one of them.
#
#   * The completer is watched too. Its response is an RSP and a multi-beat DAT
#     burst separated by credit waits, so a per-flit bracket leaves the sideband
#     low in between while it still owes the rest of the completion.
#
# Requirements on each vantage:
#   * at least one cycle with TXSACTIVE high and NOT a single flit moving --
#     a per-flit pulse cannot produce this cycle, so its presence is positive
#     proof of the held window rather than of the flits themselves;
#   * TXSACTIVE never low between the first and last flit, which is the
#     under-assertion a receiver would be misled by;
#   * TXSACTIVE back low once the traffic has drained, so the window closes and
#     the signal still carries information.
#
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

import cocotb

from chi_base_test import chi_base_test
from chi_tb_pkg import READ_ADDR_C

_CHANNELS_C = ("req", "rsp", "dat")
_READS_C = 4
_DRAIN_CYCLES_C = 32


class tc_chi_txsactive_window(chi_base_test):

  def __init__(self, name, parent):
    super().__init__(name, parent)
    self.trace = {}
    self._sampling = False

  # Both ends must be pipelined: the RN-I to keep several reads in flight, and
  # the SN-F to buffer inbound REQs so it does not drop one while mid-burst.
  def configure(self, rni_cfg, snf_cfg):
    rni_cfg.multi_outstanding = True
    rni_cfg.max_outstanding_read = _READS_C
    snf_cfg.multi_outstanding = True

  async def _sample_loop(self, tag, bus):
    """One (txsactive, flit_moving) tuple per cycle for as long as armed."""
    trace = self.trace[tag]
    while self._sampling:
      await bus.rising()
      await bus.read_only()
      moving = any(bus.get_or(f"{d}{ch}flitv")
                   for d in ("tx", "rx") for ch in _CHANNELS_C)
      trace.append((1 if bus.get_or("txsactive") else 0, 1 if moving else 0))

  def _judge(self, tag):
    """Judge one vantage's trace.

    The window runs from the first cycle TXSACTIVE is asserted to the last
    cycle a flit moves -- NOT from the first flit. A completer learns of a
    request by observing it on the wire and can only raise its sideband on the
    following edge, so anchoring at the first flit would charge it for one
    cycle of inherent sequential latency at window open. Anchoring at the first
    assertion keeps the claim the one that matters: once the node has said it
    has work outstanding, it must not drop the signal until that work is done.
    """
    trace = self.trace[tag]
    moving_idx = [i for i, (_, moving) in enumerate(trace) if moving]
    assert moving_idx, f"[{tag}] no flit was observed at all -- trace is empty"
    high_idx = [i for i, (tx, _) in enumerate(trace) if tx]
    assert high_idx, f"[{tag}] TXSACTIVE was never asserted at all"

    first, last = high_idx[0], moving_idx[-1]
    assert first <= last, (
      f"[{tag}] TXSACTIVE first rose at {first}, after the last flit at "
      f"{last}: the sideband never covered any traffic")
    window = trace[first:last + 1]

    held_in_gap = sum(1 for tx, moving in window if tx and not moving)
    assert held_in_gap > 0, (
      f"[{tag}] TXSACTIVE was never asserted on a cycle without a flit: it is "
      f"being pulsed per flit rather than held across the outstanding window")

    low = [i for i, (tx, _) in enumerate(window) if not tx]
    assert not low, (
      f"[{tag}] TXSACTIVE dropped on {len(low)} cycle(s) inside the "
      f"outstanding window (first at trace index {first + low[0]} of "
      f"{first}..{last}): a receiver reading it there would stand its snoop "
      f"logic down while transactions were still in flight")

    assert trace[-1][0] == 0, (
      f"[{tag}] TXSACTIVE was still asserted {_DRAIN_CYCLES_C} cycles after "
      f"the last flit: the window never closed")

    return held_in_gap

  async def run_phase(self):
    self.raise_objection()

    buses = {"rni": self.tb_env.rni_vif, "snf": self.tb_env.snf_vif}
    for tag in buses:
      self.trace[tag] = []

    self._sampling = True
    samplers = [cocotb.start_soon(self._sample_loop(tag, bus))
                for tag, bus in buses.items()]

    rd = self.rni0_rd_seq
    rd.reset()
    rd.set_requests(_READS_C)
    rd.set_initial_addr(READ_ADDR_C + 0x200)
    rd.set_size(6)
    rd.set_allow_retry(0)
    rd.set_get_response(True)
    rd.set_pipelined_send(True)
    rd.set_verbose(False)
    await rd.start(self.v_sqr.rni_sequencer)

    assert len(rd.get_responses()) == _READS_C, (
      f"expected {_READS_C} read completions, got {len(rd.get_responses())}")

    # The pipeline has to have actually overlapped, or the requester vantage
    # degenerates to the serial case this test is not trying to prove.
    peak = self.rni_cfg.observed_peak_outstanding
    assert peak > 1, (
      f"the reads did not overlap (peak outstanding {peak}): the sideband was "
      f"never asked to survive one transaction retiring under another")

    # Let the window close and the sideband settle before judging the tail.
    await self.wait_clocks(_DRAIN_CYCLES_C)
    self._sampling = False
    await self.wait_clocks(2)
    for s in samplers:
      s.kill()

    gaps = {tag: self._judge(tag) for tag in buses}

    self.logger.info(
      f"Test (tc_chi_txsactive_window) PASS: TXSACTIVE held across the whole "
      f"outstanding window on both vantages with peak {peak} reads overlapping "
      f"(flit-free cycles covered: requester={gaps['rni']}, "
      f"completer={gaps['snf']})")
    self.drop_objection()
