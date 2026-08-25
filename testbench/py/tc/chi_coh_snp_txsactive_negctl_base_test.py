################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of tc/chi_coh_snp_txsactive_negctl_base_test.sv.
#
# Negative control for the RECEIVING limb of CHI_TXSACTIVE_COVERS_OUTSTANDING,
# at the SNOOPEE.
#
# E section 14.7.2 / D section 13.7.2 states the snoopee's obligation in a
# sentence of its own: "An RN-F or RN-D component must also assert TXSACTIVE
# while a Snoop transaction is in progress". The two limbs already controlled
# elsewhere are both the ICN's -- its requests and the snoops it sends. This is
# the other end of the same wire pair.
#
# cfg.rnf_txsactive_snoop_drop_negctl makes RN-F0 answer a snoop without opening
# a TXSACTIVE window at all, so the sideband stays low for the whole look-up and
# response. The rule must report those cycles.
#
# The scenario has to leave the snoopee IDLE, which is what separates this from
# the home-side control. RN-F0 takes the line Unique and its own read is allowed
# to retire before RN-F1 reads; the snoop then arrives at a node with nothing
# outstanding of its own, so the request limb cannot hold the sideband up and the
# only thing that could is the limb this control removes.
#
# What the control must NOT do is trip its neighbour.
# CHI_TXSACTIVE_DEASSERT_BOUNDED bounds how long the sideband may stay UP once
# the link is quiet, so a window that is never opened cannot fire it. Asserting
# that silence is what separates "the window was missing" from "the sideband is
# broken in both directions".
#
################################################################################

from __future__ import annotations

from chi_coherent_base_test import chi_coherent_base_test
from chi_tb_pkg import WRITE_READ_ADDR_C

_CHK_C = "CHI_TXSACTIVE_COVERS_OUTSTANDING"
_NEIGHBOUR_C = "CHI_TXSACTIVE_DEASSERT_BOUNDED"
_LINE_C = WRITE_READ_ADDR_C
_SETTLE_C = 40


class chi_coh_snp_txsactive_negctl_base_test(chi_coherent_base_test):

  def configure_agent_cfgs(self):
    self.hrnf0_cfg.rnf_txsactive_snoop_drop_negctl = True

  # The rule is judged at the snoopee's own bind, because that is where the
  # sideband being tested is driven.
  def connect_phase(self):
    super().connect_phase()
    self.tb_env.hrnf_sva[0].expect_failure(_CHK_C)

  async def run_phase(self):
    self.raise_objection()
    await self.wait_reset_settle()

    # RN-F0 takes the line Unique so the home cannot answer RN-F1 without
    # snooping it. Port 0 rather than port 1 because it is the port with a snoop
    # observation fifo, and the snoop has to be OBSERVED for the count to be
    # evidence of anything.
    self.cfg_read_seq(self.hrnf0_rdunique_seq, _LINE_C)
    await self.hrnf0_rdunique_seq.start(self.tb_env.hrnf0_agent.sequencer)
    assert len(self.hrnf0_rdunique_seq.get_responses()) == 1, \
      "RN-F0 did not acquire the line"

    # The gap is the point of the scenario, not padding: it lets RN-F0's own read
    # retire so the snoop lands on an idle node.
    await self.wait_clocks(_SETTLE_C)

    self.cfg_read_seq(self.hrnf1_rdshared_seq, _LINE_C)
    await self.hrnf1_rdshared_seq.start(self.tb_env.hrnf1_agent.sequencer)
    assert len(self.hrnf1_rdshared_seq.get_responses()) == 1, \
      "RN-F1's read never completed"

    await self.wait_clocks(_SETTLE_C)

    assert self.tb_env.hrnf0_snp_fifo.can_get(), (
      "RN-F0 was never snooped, so the home answered from its directory and "
      "the window this control removes was never needed")

    snoopee = self.tb_env.hrnf_sva[0]
    fails = snoopee.fail_count.get(_CHK_C, 0)
    assert fails > 0, (
      f"{_CHK_C} did not report a snoopee that answered a snoop with its "
      f"sideband low -- the receiving limb is vacuous")

    neighbour = snoopee.fail_count.get(_NEIGHBOUR_C, 0)
    assert neighbour == 0, (
      f"{_NEIGHBOUR_C} also reported {neighbour} time(s): this control removes "
      f"a window, it does not strand the sideband high")

    # The home is unmodified here, and its own sideband is a different wire on a
    # different interface. A report there would mean this control had reached
    # further than the snoopee it was aimed at.
    home = sum(c.fail_count.get(_CHK_C, 0) for c in self.tb_env.hnfr_sva)
    assert home == 0, (
      f"the home's own TXSACTIVE was reported {home} time(s) as well: the "
      f"control is aimed at the snoopee's window and nothing else")

    self.logger.info(
      f"Test (coh_snp_txsactive_negctl) PASS: {_CHK_C} reported {fails} "
      f"cycle(s) of a snoopee sideband held low across a snoop it was "
      f"answering, the bounding rule stayed silent, and the home's own "
      f"sideband was not touched")
    self.drop_objection()
