################################################################################
# pyUVM/cocotb port of tc/tc_chi_e_tag_integrity.sv.
#
# MTE tag read-back integrity, checked rather than merely modelled.
#
# The exact-CHI-E completer has kept a per-beat tag store and replayed it since
# it was written, and nothing ever checked what came back. A model nothing checks
# is the same defect as a check nothing exercises, seen from the other side: it
# can be wrong for a whole regression without one test noticing.
#
# A tagged write, then a read of the same line. The scoreboard predicts tag,
# TagUpdate and TagOp per beat alongside the data it already predicted, and the
# read-back must match.
#
# The assertion that matters is NOT "no mismatches" -- a scoreboard that compared
# nothing would satisfy that too, which is the whole lesson of the vacuity work.
# It is "tags were COMPARED, and none mismatched". Zero out of zero is not a pass.
#
# ONE beat, and that is a property of the link rather than a choice: the wide
# CHI-E link is 64 bytes and CHI's maximum transfer Size is also 64 bytes, so
# every MTE transfer here is a single beat.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from chi_e_base_test import chi_e_base_test
from chi_tb_pkg import (
  E_TAG_INTEGRITY_ADDR_C, E_MTE_RNI_NODE_ID_C, E_MTE_SNF_NODE_ID_C,
  E_MTE_WRITE_TAGOP_C,
)

N_BEATS_C = 1
SETTLE_C = 40
WRITE_DATA_C = 0xA5A5_0000_0000_0000
WRITE_TAG_C = 0x3
WRITE_TU_C = 0x1


class tc_chi_e_tag_integrity(chi_e_base_test):

  async def run_phase(self):
    self.raise_objection()

    wr = self.rni_wr_seq
    wr.reset()
    wr.set_requests(1)
    wr.set_initial_addr(E_TAG_INTEGRITY_ADDR_C)
    wr.set_size(6)
    wr.set_src_id(E_MTE_RNI_NODE_ID_C)
    wr.set_tgt_id(E_MTE_SNF_NODE_ID_C)
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
    rd.set_initial_addr(E_TAG_INTEGRITY_ADDR_C)
    rd.set_size(6)
    rd.set_src_id(E_MTE_RNI_NODE_ID_C)
    rd.set_tgt_id(E_MTE_SNF_NODE_ID_C)
    rd.set_get_response(True)
    rd.set_verbose(False)
    await rd.start(self.tb_env.rni_agent.sequencer)
    rd.get_responses()

    await self.wait_clocks(SETTLE_C)

    sb = self.tb_env.scoreboard

    # The half a clean run cannot show you: the scoreboard must actually have
    # compared tags. Without this the two assertions below hold on a scoreboard
    # that never predicted a single one.
    assert sb.n_tag_checked >= N_BEATS_C, (
      f"the scoreboard compared {sb.n_tag_checked} tag(s) against a "
      f"{N_BEATS_C}-beat tagged write; the tag path is not being checked at all")
    assert sb.n_tag_mismatch == 0, (
      f"{sb.n_tag_mismatch} tag mismatch(es) on a read-back of tags this test "
      f"wrote")
    assert sb.n_tagop_replay_mismatch == 0, (
      f"{sb.n_tagop_replay_mismatch} TagOp replay mismatch(es) on a read-back "
      f"of a TagOp this test wrote")

    self.logger.info(
      f"Test (tc_chi_e_tag_integrity) PASS: {sb.n_tag_checked} tag(s) compared "
      f"on read-back, all matching, and the TagOp replayed as written")
    self.drop_objection()
