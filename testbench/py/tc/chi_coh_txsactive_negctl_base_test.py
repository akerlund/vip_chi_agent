################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of tc/chi_coh_txsactive_negctl_base_test.sv.
#
# Negative control for CHI_TXSACTIVE_COVERS_OUTSTANDING at the HOME.
#
# chi_coh_txsactive_window_base_test proves the home holds its RN-facing
# sideband across the whole outstanding window. This proves the rule that
# watches it would SAY SO if it did not: cfg.hnf_txsactive_early_drop_negctl
# makes the home retire the window the moment it starts serving a read rather
# than when the transaction completes, and the rule must report the cycles the
# sideband spends low with a transaction still in flight.
#
# IHI 0050 E section 14.7.2 / D section 13.7.2: the home must keep TXSACTIVE
# asserted until after the final completing flit is sent or received. Under-
# assertion is the failure that matters, because a receiver reads the sideband
# to decide when it can stop watching for snoop traffic.
#
# The read is aimed at a line the OTHER requester owns, so the home must snoop
# before it can answer: the violation window is then tens of cycles wide rather
# than the one or two a directory hit would give, and the count the test asserts
# on cannot be an artefact of a single edge.
#
# What the control must NOT do is trip its neighbour.
# CHI_TXSACTIVE_DEASSERT_BOUNDED bounds how long the sideband may stay UP once
# the link is quiet, so a sideband dropped too early cannot fire it, and this
# test asserts that silence: it is what separates "the window was too narrow"
# from "the sideband is broken in both directions".
#
################################################################################

from __future__ import annotations

from chi_coherent_base_test import chi_coherent_base_test
from chi_tb_pkg import WRITE_READ_ADDR_C

_CHK_C = "CHI_TXSACTIVE_COVERS_OUTSTANDING"
_NEIGHBOUR_C = "CHI_TXSACTIVE_DEASSERT_BOUNDED"
_LINE_C = WRITE_READ_ADDR_C
_SETTLE_C = 40


class chi_coh_txsactive_negctl_base_test(chi_coherent_base_test):

  def configure_agent_cfgs(self):
    self.hnf_cfg.hnf_txsactive_early_drop_negctl = True

  # The violation is judged where the sideband is driven, which is the home's
  # own bind. The RN-F binds see the same wire from the other side and have
  # their own window; they are asserted to stay quiet below rather than waived.
  def connect_phase(self):
    super().connect_phase()
    for checker in self.tb_env.hnfr_sva:
      checker.expect_failure(_CHK_C)

  async def run_phase(self):
    self.raise_objection()
    await self.wait_reset_settle()

    # RN-F0 takes the line Unique so the home cannot answer RN-F1 without
    # snooping, which is what makes the violation window wide. That direction
    # rather than the other because port 0 is the one with a snoop observation
    # fifo, and the snoop has to be OBSERVED for the width to be evidence.
    self.cfg_read_seq(self.hrnf0_rdunique_seq, _LINE_C)
    await self.hrnf0_rdunique_seq.start(self.tb_env.hrnf0_agent.sequencer)
    assert len(self.hrnf0_rdunique_seq.get_responses()) == 1, \
      "RN-F0 did not acquire the line"

    self.cfg_read_seq(self.hrnf1_rdshared_seq, _LINE_C)
    await self.hrnf1_rdshared_seq.start(self.tb_env.hrnf1_agent.sequencer)
    assert len(self.hrnf1_rdshared_seq.get_responses()) == 1, \
      "RN-F1's read never completed"

    await self.wait_clocks(_SETTLE_C)

    assert self.tb_env.hrnf0_snp_fifo.can_get(), (
      "RN-F0 was never snooped, so the home answered from its directory and "
      "the violation window was never opened wide")

    fails = sum(c.fail_count.get(_CHK_C, 0) for c in self.tb_env.hnfr_sva)
    assert fails > 0, (
      f"{_CHK_C} did not report a home that dropped TXSACTIVE while a "
      f"transaction it had captured was still in flight -- the rule may be "
      f"vacuous at the completer vantage")

    # The neighbour rule bounds the sideband staying UP. A window dropped too
    # early cannot trip it, and if it did the control would be exercising two
    # rules at once.
    neighbour = sum(c.fail_count.get(_NEIGHBOUR_C, 0)
                    for c in self.tb_env.hnfr_sva)
    assert neighbour == 0, (
      f"{_NEIGHBOUR_C} also reported {neighbour} time(s): this control is "
      f"meant to narrow the window, not to strand the sideband high")

    self.logger.info(
      f"Test (coh_txsactive_negctl) PASS: {_CHK_C} reported {fails} cycle(s) "
      f"of a home sideband dropped under an in-flight transaction, and the "
      f"bounding rule stayed silent")
    self.drop_objection()
