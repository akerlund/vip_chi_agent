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
# The completer answers a Match-tagged write with TagMatch (F-COV-001).
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
# that list -- the same overload PGroupID rides in F-INTOP-010.
#
# The response is routed to ReturnNID, not SrcID: the TgtID table in section 4.7
# gives TagMatch as "Request.SrcID" from a Home and "Request.ReturnNID" from a
# Slave, and section 2.5 agrees from the field's side.
#
# What is asserted:
#   * CHI_SB_TAG_MATCH_OWED records a pass and no failure;
#   * a TagMatch RSP is actually observed on the wire, so the test cannot pass
#     against a completer that stayed silent -- the rule is silent then too.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import Role, RspOpcode
from chi_e_base_test import chi_e_base_test
from chi_tb_pkg import E_MTE_RNI_NODE_ID_C, E_MTE_SNF_NODE_ID_C

ADDR_C = 0x4F00_0000
SETTLE_C = 20
RULE_C = "CHI_SB_TAG_MATCH_OWED"

# Table 13-34: 0b11 is Match on a write.
TAGOP_MATCH_C = 0b11
TAG_C = 0x1234
TU_C = 0x0          # 13.10.38: "TU field is not applicable and must be set to
                    # zero" under Match.


class tc_chi_e_tag_match(chi_e_base_test):

  async def run_phase(self):
    self.raise_objection()

    sb = self.tb_env.scoreboard
    self.drain_observation_fifos()

    before_pass = sb.chk_pass.get(RULE_C, 0)
    before_fail = sb.chk_fail.get(RULE_C, 0)

    wr = self.rni_wr_seq
    wr.reset()
    wr.set_requests(1)
    wr.set_initial_addr(ADDR_C)
    wr.set_size(6)
    wr.set_src_id(E_MTE_RNI_NODE_ID_C)
    wr.set_tgt_id(E_MTE_SNF_NODE_ID_C)
    wr.set_dat_tagop(TAGOP_MATCH_C)
    wr.set_tag([TAG_C])
    wr.set_tu([TU_C])
    wr.set_get_response(True)
    wr.set_verbose(False)
    await wr.start(self.tb_env.rni_agent.sequencer)

    await self.wait_clocks(SETTLE_C)

    # The response really went out. Without this the testcase passes against a
    # completer that answered nothing, because the rule is silent then too --
    # it judges an arriving TagMatch, and no TagMatch is no judgement.
    saw_tag_match = False
    while True:
      ok, obs = self.tb_env.rni_rsp_fifo.try_get()
      if not ok:
        break
      if int(obs.rsp_opcode) == int(RspOpcode.TAG_MATCH):
        saw_tag_match = True
    assert saw_tag_match, (
      "no TagMatch RSP was observed for a write whose data carried "
      "TagOp = Match; section 2.3.1 owes one")

    after_pass = sb.chk_pass.get(RULE_C, 0)
    after_fail = sb.chk_fail.get(RULE_C, 0)

    assert after_fail == before_fail, (
      f"{RULE_C} reported {after_fail - before_fail} time(s) against a TagMatch "
      f"the write's data did ask for")
    assert after_pass > before_pass, (
      f"{RULE_C} recorded no pass, so the rule is not reading the response")

    self.logger.info(
      f"Test (tc_chi_e_tag_match) PASS: a Match-tagged write was answered with "
      f"TagMatch, checked {after_pass - before_pass} time(s) by {RULE_C}")

    self.drop_objection()
