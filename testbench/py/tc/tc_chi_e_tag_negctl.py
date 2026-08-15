################################################################################
# pyUVM/cocotb port of tc/tc_chi_e_tag_negctl.sv.
#
# Negative control for the MTE tag checks.
#
# The checks added alongside this test would be worth nothing if they could not
# fail, and a tag path that has been replaying correctly for its whole life gives
# them no chance to. cfg.snf_corrupt_tag makes the completer break both reachable
# rules, in two INDEPENDENT ways, because the two fail independently:
#
#   the TAG comes back with its low bit flipped -- a corrupt tag store.
#   the TAGOP comes back flipped too -- a completer that invented a TagOp
#   instead of replaying the one it was given.
#
# Both must be reported. A control that broke only one would leave the other
# unproven.
#
# Both breakages land on the same beat, and that is forced by the link rather
# than chosen: the only MTE-capable link here is 64 bytes and CHI's maximum
# transfer Size is 64 bytes, so every MTE transfer has exactly one beat. The
# scoreboard's third rule -- one TagOp across the beats of a transfer -- cannot
# be provoked here at all for the same reason, and is recorded as unreachable
# where it is defined rather than left to look exercised.
#
# The induced errors are demoted by a filter so they do not count against the
# regression verdict, and the counters are asserted directly.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

import logging

from chi_e_base_test import chi_e_base_test
from vip_chi_scoreboard import SB_READ_TAG_MATCHES, SB_READ_TAGOP_REPLAYED
from chi_tb_pkg import (
  E_TAG_NEGCTL_ADDR_C, E_MTE_RNI_NODE_ID_C, E_MTE_SNF_NODE_ID_C,
  E_MTE_WRITE_TAGOP_C,
)

SETTLE_C = 40
WRITE_DATA_C = 0x5A5A_0000_0000_0000
WRITE_TAG_C = 0x3
WRITE_TU_C = 0x1


class _tag_negctl_filter(logging.Filter):
  """Demote the two deliberately-injected tag errors.

  Matches only the two messages this control injects, so a THIRD unexpected
  scoreboard error in the same run still fails the test -- which is the point of
  demoting per message rather than waiving the component.
  """

  def __init__(self, name=""):
    super().__init__(name)
    self.saw_tag_error = False
    self.saw_tagop_error = False

  def filter(self, record):
    msg = record.getMessage()
    if record.levelno == logging.ERROR and "Tag mismatch" in msg:
      self.saw_tag_error = True
      record.levelno, record.levelname = logging.INFO, "INFO"
      return True
    if record.levelno == logging.ERROR and "TagOp replay mismatch" in msg:
      self.saw_tagop_error = True
      record.levelno, record.levelname = logging.INFO, "INFO"
      return True
    return True


class tc_chi_e_tag_negctl(chi_e_base_test):

  def configure(self, rni_cfg, snf_cfg):
    snf_cfg.snf_corrupt_tag = True

  async def run_phase(self):
    self.raise_objection()

    catcher = _tag_negctl_filter("tag_negctl_catcher")
    self.tb_env.scoreboard.logger.addFilter(catcher)
    # Both reachable tag rules are broken here on purpose, declared one by one
    # so the aggregation records them as provoked -- and so a THIRD,
    # unintended scoreboard violation would still be reported.
    self.tb_env.scoreboard.expect_failure(SB_READ_TAG_MATCHES)
    self.tb_env.scoreboard.expect_failure(SB_READ_TAGOP_REPLAYED)

    wr = self.rni_wr_seq
    wr.reset()
    wr.set_requests(1)
    wr.set_initial_addr(E_TAG_NEGCTL_ADDR_C)
    wr.set_size(6)
    wr.set_src_id(E_MTE_RNI_NODE_ID_C)
    wr.set_tgt_id(E_MTE_SNF_NODE_ID_C)
    wr.set_allow_retry(0)
    wr.set_get_response(True)
    wr.set_verbose(False)
    wr.set_data([WRITE_DATA_C])
    wr.set_dat_tagop(E_MTE_WRITE_TAGOP_C)
    wr.set_tag([WRITE_TAG_C])
    wr.set_tu([WRITE_TU_C])
    await wr.start(self.tb_env.rni_agent.sequencer)
    wr.get_responses()

    rd = self.rni_rd_seq
    rd.reset()
    rd.set_requests(1)
    rd.set_initial_addr(E_TAG_NEGCTL_ADDR_C)
    rd.set_size(6)
    rd.set_src_id(E_MTE_RNI_NODE_ID_C)
    rd.set_tgt_id(E_MTE_SNF_NODE_ID_C)
    rd.set_allow_retry(0)
    rd.set_get_response(True)
    rd.set_verbose(False)
    await rd.start(self.tb_env.rni_agent.sequencer)
    rd.get_responses()

    await self.wait_clocks(SETTLE_C)
    self.tb_env.scoreboard.logger.removeFilter(catcher)

    sb = self.tb_env.scoreboard

    assert sb.n_tag_mismatch > 0, (
      "the completer returned a corrupted tag and the read-back check reported "
      "nothing -- it is vacuous")
    assert sb.n_tagop_replay_mismatch > 0, (
      "the completer returned a TagOp it was never given and the replay check "
      "reported nothing -- it is vacuous")

    self.logger.info(
      f"Test (tc_chi_e_tag_negctl) PASS: a corrupted tag was reported "
      f"{sb.n_tag_mismatch} time(s) and a corrupted TagOp "
      f"{sb.n_tagop_replay_mismatch} time(s); both reachable rules fire")
    self.drop_objection()
