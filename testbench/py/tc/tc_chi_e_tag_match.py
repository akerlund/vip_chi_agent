################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM/cocotb port of tc/tc_chi_e_tag_match.sv.
#
# The completer answers a Match-tagged write with TagMatch.
#
# IHI 0050 E Table 13-34 gives TagOp = 0b11 as "Match Fetch" -- Match on a write:
# "the Physical Tags in the write must be checked against the Allocation Tag
# values obtained from memory". Section 2.3.1 then makes the answer an
# obligation: "If the WriteData message indicates that a Tag Match is required,
# then the Slave sends a TagMatch response after completing the required Tag
# Match operation."
#
# The VIP defined no TagMatch RSP opcode at all, while shipping memory tagging as
# a claimed and tested feature. It was reachable rather than merely absent: TagOp
# is a bare 2-bit field with no enum and no constraint, so any test could ask for
# Match and get silence back -- and against a third-party completer that answered
# correctly, the monitor would have reconstructed an opcode neither port knew.
#
# Modelling it needed no new flit field. Table 13-7 shares the response's DBID
# bits between DBID, PGroupID and StashGroupID, and 13.10.7 adds TagGroupID to
# that list -- the same overload PGroupID rides in.
#
# The response is routed to ReturnNID, not SrcID: the TgtID table in section 4.7
# gives TagMatch as "Request.SrcID" from a Home and "Request.ReturnNID" from a
# Slave, and section 2.5 agrees from the field's side.
#
# The RESULT is the second half, and the completer used to get it wrong in a way
# nothing could see. Table 13-25 puts the answer in Resp[0] alone -- 0b000 Fail,
# 0b001 Pass -- which is not a cache state, and the responder was filling the
# field from the cache-state enum with Resp.I. Those are the same three bits as
# Fail, so every Match was answered Fail, no comparison was ever performed, and
# a rule that only judged the response's PRESENCE passed on all of it.
#
# What is asserted, in four phases against one address:
#   * an Update write establishes the Allocation Tag and is owed no TagMatch;
#   * a Match write carrying the same tag is answered Pass;
#   * a Match write carrying a different tag is answered Fail -- so the result is
#     a function of the tags and not a constant, which one phase cannot show;
#   * a Match write carrying the original tag again is answered Pass, which is
#     what proves the failing Match in between did not WRITE its tag. Table 13-34
#     gives Update as the encoding that stores tags and Match as the one that
#     checks them, and a completer that committed on Match would have made this
#     phase report Fail.
#   * CHI_SB_TAG_MATCH_OWED and CHI_SB_TAG_MATCH_RESULT each record three passes
#     and no failure, and a TagMatch RSP is observed on the wire every time -- so
#     the test cannot pass against a completer that stayed silent, because the
#     rules are silent then too.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import Role, RspOpcode
from chi_e_base_test import chi_e_base_test
from chi_tb_pkg import (E_MTE_RNI_NODE_ID_C, E_MTE_SNF_NODE_ID_C,
                        E_MTE_WRITE_TU_C)

ADDR_C = 0x4F00_0000
SETTLE_C = 20
RULE_C = "CHI_SB_TAG_MATCH_OWED"
RESULT_RULE_C = "CHI_SB_TAG_MATCH_RESULT"

# Table 13-34: 0b11 is Match on a write, 0b10 is Update.
TAGOP_MATCH_C = 0b11
TAGOP_UPDATE_C = 0b10
TAG_C = 0x1234
# One bit away, so the Fail phase differs from the Pass phase in the tag and in
# nothing else.
OTHER_TAG_C = TAG_C ^ 0x1
# 13.10.38 requires every TU bit asserted under Update.
UPDATE_TU_C = E_MTE_WRITE_TU_C
TU_C = 0x0          # 13.10.38: "TU field is not applicable and must be set to
                    # zero" under Match.


class tc_chi_e_tag_match(chi_e_base_test):

  async def tagged_write(self, tagop, tag, tu):
    """One tagged write to the shared address, and the TagMatch results it drew.

    Returns the Resp[0] of every TagMatch observed for this write. A list rather
    than a single value so a phase that draws none -- the Update phase, which is
    owed none -- is distinguishable from one that drew a Fail.
    """
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
    self.drain_observation_fifos()

    before_pass = sb.chk_pass.get(RULE_C, 0)
    before_fail = sb.chk_fail.get(RULE_C, 0)
    before_result_pass = sb.chk_pass.get(RESULT_RULE_C, 0)
    before_result_fail = sb.chk_fail.get(RESULT_RULE_C, 0)

    # Phase 1: establish the Allocation Tag. Update stores; it asks no question,
    # so it is owed no answer.
    drawn = await self.tagged_write(TAGOP_UPDATE_C, TAG_C, UPDATE_TU_C)
    assert drawn == [], (
      f"an Update-tagged write drew {len(drawn)} TagMatch response(s); "
      f"section 2.3.1 owes one only when the WriteData asked for the check")

    # Phases 2-4. The third is what proves the failing Match did not store its
    # tag: if it had, the tag at ADDR_C would now be OTHER_TAG_C and this would
    # come back Fail.
    # 13.10.38: "TU field is not applicable and must be set to zero" under Match.
    expected = [(TAG_C, 1), (OTHER_TAG_C, 0), (TAG_C, 1)]
    for tag, want in expected:
      drawn = await self.tagged_write(TAGOP_MATCH_C, tag, TU_C)
      assert drawn == [want], (
        f"a Match-tagged write carrying tag 0x{tag:x} drew {drawn}, expected "
        f"[{want}] ({'Pass' if want else 'Fail'}) -- Table 13-34 requires the "
        f"physical tags to be checked against the stored Allocation Tags and "
        f"Table 13-25 carries the answer in Resp[0]")

    after_pass = sb.chk_pass.get(RULE_C, 0)
    after_fail = sb.chk_fail.get(RULE_C, 0)
    after_result_pass = sb.chk_pass.get(RESULT_RULE_C, 0)
    after_result_fail = sb.chk_fail.get(RESULT_RULE_C, 0)

    assert after_fail == before_fail, (
      f"{RULE_C} reported {after_fail - before_fail} time(s) against TagMatch "
      f"responses the writes' data did ask for")
    assert after_pass - before_pass == len(expected), (
      f"{RULE_C} recorded {after_pass - before_pass} pass(es) for "
      f"{len(expected)} Match-tagged writes, so it is not reading every "
      f"response")

    assert after_result_fail == before_result_fail, (
      f"{RESULT_RULE_C} reported {after_result_fail - before_result_fail} "
      f"time(s) against a completer that compared correctly")
    assert after_result_pass - before_result_pass == len(expected), (
      f"{RESULT_RULE_C} recorded {after_result_pass - before_result_pass} "
      f"pass(es) for {len(expected)} Match-tagged writes -- a result rule that "
      f"judged fewer responses than arrived is reporting on a subset")

    self.logger.info(
      f"Test (tc_chi_e_tag_match) PASS: {len(expected)} Match-tagged writes "
      f"answered Pass/Fail/Pass by tag, each judged by {RULE_C} and "
      f"{RESULT_RULE_C}")

    self.drop_objection()
