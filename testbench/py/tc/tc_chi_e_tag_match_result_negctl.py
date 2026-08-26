################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM/cocotb port of tc/tc_chi_e_tag_match_result_negctl.sv.
#
# Negative control for CHI_SB_TAG_MATCH_RESULT, which no stimulus alone can make
# fail.
#
# The rule judges the RESULT a TagMatch carried against the tags the scoreboard
# holds. A completer that performs the comparison correctly agrees with that
# shadow on every write, so the rule's failing branch is unreachable from the
# sequence side however the tags are arranged -- the completer and the
# scoreboard are reading the same tags and reaching the same answer by
# construction.
#
# So the control breaks the completer instead. `snf_tag_match_invert_result_negctl`
# has it report the OPPOSITE of what its own comparison found, which is exactly
# the defect the rule exists to catch: the responder used to fill the field from
# the cache-state enum with Resp.I, whose three bits are also Table 13-25's Fail,
# so every Match was answered Fail whatever the tags said. That reported a wrong
# result on every write while satisfying CHI_SB_TAG_MATCH_OWED on every write,
# because a response DID arrive each time.
#
# Which is why the two rules are separate, and why this asserts on both: the
# control must make the RESULT rule report and must leave the OWED rule clean.
# A control that tripped both would not show they are distinguishable, and a
# single merged rule would have gone on passing through the original defect.
#
# What is asserted:
#   * an Update write first, so there IS a stored Allocation Tag and the
#     following Match has a real answer to invert -- against untagged memory the
#     honest answer is Fail already, and inverting it would produce a Pass that
#     looks like the bug rather than the control;
#   * the TagMatch that comes back carries Fail (Resp[0] = 0) where the tags
#     matched, so the control provably reached the wire;
#   * CHI_SB_TAG_MATCH_RESULT reports exactly once;
#   * CHI_SB_TAG_MATCH_OWED reports not at all.
#
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import RspOpcode
from chi_e_base_test import chi_e_base_test
from chi_tb_pkg import (E_MTE_RNI_NODE_ID_C, E_MTE_SNF_NODE_ID_C,
                        E_MTE_WRITE_TU_C)

ADDR_C = 0x4F20_0000
SETTLE_C = 20
RULE_C = "CHI_SB_TAG_MATCH_RESULT"
OWED_RULE_C = "CHI_SB_TAG_MATCH_OWED"

# Table 13-34: 0b11 is Match on a write, 0b10 is Update.
TAGOP_MATCH_C = 0b11
TAGOP_UPDATE_C = 0b10
TAG_C = 0x1234
TU_C = 0x0          # 13.10.38: "TU field is not applicable and must be set to
                    # zero" under Match.


class tc_chi_e_tag_match_result_negctl(chi_e_base_test):

  def configure(self, rni_cfg, snf_cfg):
    super().configure(rni_cfg, snf_cfg)
    snf_cfg.snf_tag_match_invert_result_negctl = True

  async def tagged_write(self, tagop, tag, tu):
    """One tagged write to the shared address, and the TagMatch results it drew."""
    wr = self.rni_wr_seq
    wr.reset()
    wr.set_requests(1)
    wr.set_initial_addr(ADDR_C)
    wr.set_size(6)
    wr.set_src_id(E_MTE_RNI_NODE_ID_C)
    wr.set_tgt_id(E_MTE_SNF_NODE_ID_C)
    wr.set_dat_tagop(tagop)
    wr.set_tag([tag])
    wr.set_tu([tu])
    wr.set_get_response(True)
    wr.set_verbose(False)
    await wr.start(self.tb_env.rni_agent.sequencer)

    await self.wait_clocks(SETTLE_C)

    results = []
    while True:
      ok, obs = self.tb_env.rni_rsp_fifo.try_get()
      if not ok:
        break
      if int(obs.rsp_opcode) == int(RspOpcode.TAG_MATCH):
        # Table 13-25: the result is Resp[0] and nothing else in the field.
        results.append(int(obs.rsp_resp) & 1)
    return results

  async def run_phase(self):
    self.raise_objection()

    sb = self.tb_env.scoreboard
    # Declared, so the environment's end-of-test check knows this run provokes
    # it on purpose. expect_failure only changes what the aggregation and the
    # env make of the count -- the rule still evaluates, still counts and still
    # reports, which is what the assertions below read.
    sb.expect_failure(RULE_C)
    self.drain_observation_fifos()

    before_fail = sb.chk_fail.get(RULE_C, 0)
    before_owed_fail = sb.chk_fail.get(OWED_RULE_C, 0)
    assert before_fail == 0, (
      f"{RULE_C} already reported {before_fail} time(s) on bring-up traffic; "
      f"the count below would prove nothing")

    # Establish the Allocation Tag. Update stores and asks no question, so it
    # draws no TagMatch and the control has nothing to invert yet.
    drawn = await self.tagged_write(TAGOP_UPDATE_C, TAG_C, E_MTE_WRITE_TU_C)
    assert drawn == [], (
      f"an Update-tagged write drew {len(drawn)} TagMatch response(s) even "
      f"before the Match; the control is answering writes that asked nothing")

    # The same tag: the comparison finds a match, and the control reports Fail.
    drawn = await self.tagged_write(TAGOP_MATCH_C, TAG_C, TU_C)
    assert drawn == [0], (
      f"a Match-tagged write carrying the stored tag drew {drawn}, expected "
      f"[0] (Fail) from the inverting control -- either the control is not "
      f"reaching the completer, or the completer is not comparing at all and "
      f"the inversion turned its constant Fail into a Pass")

    after_fail = sb.chk_fail.get(RULE_C, 0)
    after_owed_fail = sb.chk_fail.get(OWED_RULE_C, 0)

    assert after_fail - before_fail == 1, (
      f"{RULE_C} reported {after_fail - before_fail} time(s) for one inverted "
      f"result, expected exactly 1")
    assert after_owed_fail == before_owed_fail, (
      f"{OWED_RULE_C} reported {after_owed_fail - before_owed_fail} time(s) on "
      f"a response that WAS owed; the two rules are not separable if breaking "
      f"the result also trips the obligation")

    self.logger.info(
      f"Test (tc_chi_e_tag_match_result_negctl) PASS: an inverted Tag Match "
      f"result was reported {after_fail - before_fail} time(s) by {RULE_C}, "
      f"with {OWED_RULE_C} clean")

    self.drop_objection()
