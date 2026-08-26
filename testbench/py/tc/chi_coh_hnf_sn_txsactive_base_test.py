################################################################################
# pyUVM port of tc/chi_coh_hnf_sn_txsactive_base_test.sv.
#
# The home's SN-facing TXSACTIVE is a WINDOW around its own downstream requests,
# not a level that follows the link.
#
# IHI 0050 E section 14.7.2: "The interconnect interface to an SN must assert
# TXSACTIVE before, or in the same cycle in which its initiating Request flit is
# sent. It must keep TXSACTIVE asserted until after the final completing flit is
# sent or received." Read with the general statement earlier in that section --
# deassertion "implies that the component has completed all transactions in
# progress" -- this is a window opened by a request the home SENDS.
#
# The home used to drive it from sn_link_up, so it was high from bring-up to
# tear-down whatever it had downstream. Legal by the letter, since over-assertion
# always is, and carrying no information at all -- which is the state
# CHI_TXSACTIVE_DEASSERT_BOUNDED exists to report and could not, because the bind
# stood that rule down for exactly this drive.
#
# What is asserted, from a per-cycle trace of the home's SN-facing port taken
# after the link is already up:
#
#   * TXSACTIVE is LOW for at least one cycle BEFORE the first downstream flit.
#     This is the claim the old drive could not satisfy at all: the link comes up
#     long before the home has anything to fetch, so a sideband tied to link
#     state has no low cycle here.
#   * TXSACTIVE is HIGH on every cycle a flit moves in either direction. That is
#     the requirement itself -- the window must cover the request and everything
#     up to the final completing flit.
#   * TXSACTIVE is HIGH on at least one cycle with no flit moving, so it is a
#     held window rather than a per-flit pulse.
#   * TXSACTIVE is LOW again once the traffic has drained, so the window closes
#     and the signal still carries information.
#
# Used by:
#   tc_chi_coh_d_hnf_sn_txsactive   (CHI-D)
#   tc_chi_coh_e_hnf_sn_txsactive   (wide CHI-E)
#
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

import cocotb
from pyuvm import ConfigDB

from vip_chi_types_pkg import ReqOpcode
from chi_coherent_base_test import chi_coherent_base_test

_CHANNELS_C = ("req", "rsp", "dat")
_SETTLE_C = 8
_DRAIN_CYCLES_C = 32


class chi_coh_hnf_sn_txsactive_base_test(chi_coherent_base_test):

  def __init__(self, name, parent):
    super().__init__(name, parent)
    self.trace = []
    self._sampling = False

  def configure_agent_cfgs(self):
    self.hnf_cfg.hnf_downstream_en = True

  async def _sample_loop(self, bus):
    """One (txsactive, flit_moving) tuple per cycle for as long as armed."""
    while self._sampling:
      await bus.rising()
      await bus.read_only()
      moving = any(bus.get_or(f"{d}{ch}flitv")
                   for d in ("tx", "rx") for ch in _CHANNELS_C)
      self.trace.append((1 if bus.get_or("txsactive") else 0,
                         1 if moving else 0))

  def _judge(self):
    moving_idx = [i for i, (_, moving) in enumerate(self.trace) if moving]
    assert moving_idx, (
      "no flit moved on the home's SN-facing link at all, so the sideband was "
      "never asked to cover anything -- the downstream fetch did not happen")

    first, last = moving_idx[0], moving_idx[-1]

    # The claim the old drive could not satisfy. Sampling starts after the link
    # is already up, so a sideband tied to link state is high from trace index 0.
    low_before = [i for i in range(first) if not self.trace[i][0]]
    assert low_before, (
      f"TXSACTIVE was already asserted on every one of the {first} cycle(s) "
      f"before the first downstream flit: it is following the link state, not a "
      f"window opened by the home's own request")

    # The requirement itself.
    uncovered = [i for i in moving_idx if not self.trace[i][0]]
    assert not uncovered, (
      f"TXSACTIVE was low on {len(uncovered)} cycle(s) carrying a flit (first "
      f"at trace index {uncovered[0]}): section 14.7.2 requires it asserted "
      f"before or with the initiating Request flit and held until after the "
      f"final completing flit")

    window = self.trace[first:last + 1]
    held_in_gap = sum(1 for tx, moving in window if tx and not moving)
    assert held_in_gap > 0, (
      "TXSACTIVE was never asserted on a cycle without a flit inside the "
      "window: it is being pulsed per flit rather than held across the "
      "outstanding transaction")

    assert self.trace[-1][0] == 0, (
      f"TXSACTIVE was still asserted {_DRAIN_CYCLES_C} cycles after the last "
      f"downstream flit: the window never closed, which is the state a "
      f"link-driven sideband is permanently in")

    return len(low_before), len(moving_idx), held_in_gap

  async def run_phase(self):
    self.raise_objection()
    await self.wait_reset_settle()

    # The home's SN-facing port. Sampling starts here, with the link already up
    # and nothing downstream outstanding, which is what makes the low-before
    # assertion meaningful.
    sn_bus = ConfigDB().get(self, "", "hnfs0_vif")
    self._sampling = True
    sampler = cocotb.start_soon(self._sample_loop(sn_bus))
    await self.wait_clocks(_SETTLE_C)

    self.cfg_read_seq(self.hrnf0_rdshared_seq)
    await self.hrnf0_rdshared_seq.start(self.tb_env.hrnf0_agent.sequencer)

    await self.wait_clocks(_DRAIN_CYCLES_C)
    self._sampling = False
    await self.wait_clocks(2)

    # The downstream fetch really happened. Without this the trace could be judged
    # against a run where the home answered from its own memory and the sideband
    # correctly never rose -- which every assertion above would survive except
    # the first, and that one only by accident.
    n_dn = 0
    while self.tb_env.dsnf0_req_fifo.can_get():
      dn = await self.tb_env.dsnf0_req_fifo.get()
      n_dn += 1
      assert int(dn.opcode) == int(ReqOpcode.READ_NO_SNP), \
        f"downstream REQ opcode 0x{int(dn.opcode):x}, expected ReadNoSnp"
    assert n_dn == 1, \
      f"SN-F saw {n_dn} downstream REQs, expected exactly 1 ReadNoSnp"

    low_before, n_moving, held_in_gap = self._judge()

    self.logger.info(
      f"Test (coh_hnf_sn_txsactive) PASS: {low_before} idle cycle(s) before the "
      f"window opened, {n_moving} flit cycle(s) all covered, {held_in_gap} "
      f"held cycle(s) inside it, and the window closed")
    self.drop_objection()
