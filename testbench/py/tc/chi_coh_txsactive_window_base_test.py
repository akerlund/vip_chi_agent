################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of tc/chi_coh_txsactive_window_base_test.sv.
#
# TXSACTIVE at the HOME: the window opens when a request is CAPTURED, not when
# the home gets round to serving it.
#
# IHI 0050 E section 14.7.2 / D section 13.7.2 states the obligation separately
# for each role, and the home's is its own: on receiving a transaction
# initiating flit it must assert TXSACTIVE before or in the same cycle in which
# its first Response flit is sent, and "keep TXSACTIVE asserted until after the
# final completing flit is sent or received".
#
# tc_chi_txsactive_window already proves the held window on the RN-I requester
# and SN-F completer vantages. The home's is a different claim, because a home
# serves one request at a time out of a queue: the interval a request spends
# WAITING is part of the window the specification asks for, and it is invisible
# on any run where the home is never busy when a request arrives.
#
# So the queue is made non-empty on purpose. RN-F1 reads a line RN-F0 owns,
# which the home can only answer by snooping RN-F0 first -- tens of cycles --
# and RN-F0's own read of a DIFFERENT line is launched into the middle of that.
# It is captured on port 0 and then sits in the queue while the home finishes
# port 1's transaction, so on port 0 the whole interval between the request
# arriving and the first response flit going out is queueing delay:
#
#   * an implementation that raises TXSACTIVE when it starts SERVING a request
#     leaves the sideband low across that interval, and fails the lead check;
#   * one that pulses per flit leaves it low in the gaps, and fails the held
#     check;
#   * one that drives it from link-up passes both and fails the close check.
#
# Two requesters rather than one pipelined requester is a fact about the VIP
# rather than a preference: the multi-outstanding datapath covers ReadNoSnp,
# WriteNoSnp, atomics and persist only, so a single RN-F cannot hold two
# coherent reads in flight and the cross-port queue is what makes the home's
# waiting interval reachable at all.
#
################################################################################

from __future__ import annotations

import cocotb

from pyuvm import ConfigDB

from vip_chi_types_pkg import Resp
from chi_coherent_base_test import chi_coherent_base_test
from chi_tb_pkg import WRITE_READ_ADDR_C

# Every channel, snoops included: "no flit moving" has to mean the port is
# genuinely idle, and port 0 carries the snoop for the other transaction.
_ALL_CHANNELS_C = ("req", "rsp", "dat", "snp")
# The home's response flits to this port. Snoops are excluded deliberately: a
# snoop belongs to the OTHER requester's transaction, and 14.7.2's deadline is
# the first Response flit of the transaction this port initiated.
_RSP_CHANNELS_C = ("rsp", "dat")

_LINE_A_C = WRITE_READ_ADDR_C
_LINE_B_C = WRITE_READ_ADDR_C + 0x400
# Long enough that RN-F1's request is captured first and its snoop round trip is
# under way, short enough that it has not completed.
_LAUNCH_SKEW_C = 6
# The queueing interval has to be real, not a one-cycle accident of arbitration.
_MIN_QUEUE_CYCLES_C = 4
_DRAIN_CYCLES_C = 48


class chi_coh_txsactive_window_base_test(chi_coherent_base_test):

  def __init__(self, name, parent):
    super().__init__(name, parent)
    self.trace = []
    self._sampling = False

  async def _sample_loop(self, bus):
    """Per cycle on the home's port-0 wire: what the sideband did, what moved."""
    while self._sampling:
      await bus.rising()
      await bus.read_only()
      moving = any(bus.get_or(f"{d}{ch}flitv")
                   for d in ("tx", "rx") for ch in _ALL_CHANNELS_C)
      # tx is the home's own direction: rx REQ is the request arriving.
      self.trace.append((
        1 if bus.get_or("txsactive") else 0,
        1 if moving else 0,
        1 if bus.get_or("rxreqflitv") else 0,
        1 if any(bus.get_or(f"tx{ch}flitv") for ch in _RSP_CHANNELS_C) else 0))

  def _judge(self):
    tx = [t[0] for t in self.trace]
    moving = [t[1] for t in self.trace]
    req_in = [t[2] for t in self.trace]
    rsp_out = [t[3] for t in self.trace]

    def first(seq):
      return next((i for i, v in enumerate(seq) if v), None)

    req_idx = first(req_in)
    assert req_idx is not None, \
      "no request arrived on the home's port 0 -- nothing to judge"
    rsp_idx = first(rsp_out)
    assert rsp_idx is not None, (
      "the home sent no response flit on port 0: the request it captured was "
      "never answered")
    high_idx = first(tx)
    assert high_idx is not None, "the home never asserted TXSACTIVE on port 0"

    # The queueing interval has to exist, or this test degenerates into the
    # serial case tc_chi_txsactive_window already covers.
    queued = rsp_idx - req_idx
    assert queued >= _MIN_QUEUE_CYCLES_C, (
      f"the home answered port 0 only {queued} cycle(s) after the request "
      f"arrived: it was not busy with the other port, so the waiting interval "
      f"this test exists to measure never happened")

    # 14.7.2's deadline: asserted before or in the cycle of the first Response
    # flit. This is the half a dispatch-time window fails, because the home does
    # not start serving until the other transaction is done.
    assert high_idx <= rsp_idx, (
      f"the home first asserted TXSACTIVE at cycle {high_idx}, after its first "
      f"response flit on port 0 at {rsp_idx}: 14.7.2 requires the sideband up "
      f"before or in the cycle of the first Response flit")

    # And it must have been up for the whole wait, not raised just in time.
    # From req_idx + 1: the home observes the arriving flit at one edge and can
    # only reflect it at the next, so charging it for the arrival cycle itself
    # would be charging it for inherent sequential latency rather than for
    # anything the specification asks of it. Every cycle after that is the
    # home's own choice.
    low_in_wait = [i for i in range(req_idx + 1, rsp_idx + 1) if not tx[i]]
    assert not low_in_wait, (
      f"the home dropped TXSACTIVE on {len(low_in_wait)} cycle(s) of the "
      f"{queued}-cycle interval a captured request spent waiting for service "
      f"(first at {low_in_wait[0]}, request arrived at {req_idx}): the window "
      f"has to cover the wait, not only the service")

    last_moving = max(i for i, v in enumerate(moving) if v)
    window = range(high_idx, last_moving + 1)

    held_in_gap = sum(1 for i in window if tx[i] and not moving[i])
    assert held_in_gap > 0, (
      "the home never asserted TXSACTIVE on a cycle without a flit: it is "
      "pulsing per flit rather than holding across the outstanding window")

    low = [i for i in window if not tx[i]]
    assert not low, (
      f"the home dropped TXSACTIVE on {len(low)} cycle(s) inside the "
      f"outstanding window (first at {low[0]} of {high_idx}..{last_moving}): a "
      f"receiver reading it there would stand its snoop logic down while the "
      f"home still owed a completion")

    assert tx[-1] == 0, (
      f"the home still asserted TXSACTIVE {_DRAIN_CYCLES_C} cycles after the "
      f"last flit: the window never closed, so the sideband carries nothing")

    return queued, rsp_idx - high_idx, held_in_gap

  async def run_phase(self):
    self.raise_objection()
    await self.wait_reset_settle()

    # Setup, before sampling starts: RN-F0 takes line A Unique, so RN-F1's read
    # of A cannot be answered without snooping RN-F0.
    self.cfg_read_seq(self.hrnf0_rdunique_seq, _LINE_A_C)
    await self.hrnf0_rdunique_seq.start(self.tb_env.hrnf0_agent.sequencer)
    assert len(self.hrnf0_rdunique_seq.get_responses()) == 1, \
      "RN-F0 did not acquire line A"
    await self.wait_clocks(8)

    hnf_bus = ConfigDB().get(self, "", "hnfr0_vif")
    self._sampling = True
    sampler = cocotb.start_soon(self._sample_loop(hnf_bus))

    async def rnf1_read_a():
      self.cfg_read_seq(self.hrnf1_rdshared_seq, _LINE_A_C)
      await self.hrnf1_rdshared_seq.start(self.tb_env.hrnf1_agent.sequencer)

    async def rnf0_read_b():
      await self.wait_clocks(_LAUNCH_SKEW_C)
      self.cfg_read_seq(self.hrnf0_rdshared_seq, _LINE_B_C)
      await self.hrnf0_rdshared_seq.start(self.tb_env.hrnf0_agent.sequencer)

    both = [cocotb.start_soon(rnf1_read_a()), cocotb.start_soon(rnf0_read_b())]
    for t in both:
      await t

    rsp_a = self.hrnf1_rdshared_seq.get_responses()
    rsp_b = self.hrnf0_rdshared_seq.get_responses()
    assert len(rsp_a) == 1 and len(rsp_b) == 1, \
      f"expected 1+1 responses, got {len(rsp_a)}/{len(rsp_b)}"
    assert int(rsp_a[0].rsp_resp) == int(Resp.SC), \
      f"RN-F1 read of line A granted 0x{int(rsp_a[0].rsp_resp):x}, expected SC"

    # The snoop is what made the home busy; without it there was no queue.
    assert self.tb_env.hrnf0_snp_fifo.can_get(), \
      "RN-F0 was never snooped, so the home was not busy when RN-F0's own " \
      "request arrived"

    await self.wait_clocks(_DRAIN_CYCLES_C)
    self._sampling = False
    await self.wait_clocks(2)
    sampler.kill()

    queued, lead, gaps = self._judge()

    self.logger.info(
      f"Test (coh_txsactive_window) PASS: the home held TXSACTIVE on port 0 "
      f"across a {queued}-cycle wait for service, raising it {lead} cycle(s) "
      f"before its first response flit, covering {gaps} flit-free cycle(s), "
      f"and closed it after the traffic drained")
    self.drop_objection()
