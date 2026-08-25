################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM/cocotb port of tc/tc_chi_e_tag_match_negctl.sv.
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
# The NEGATIVE control. cfg.snf_tag_match_unrequested_negctl makes the completer
# answer whether or not the data asked, and this testcase drives a write whose
# data carries TagOp = Transfer -- so the TagMatch that comes back is owed to
# nobody.
#
# An unrequested TagMatch is not harmless. A Requester that tracks Match
# completions by counting them goes permanently out of step, and nothing else in
# the checker would notice: the write completes normally, every field is legal,
# and the response is a legal opcode for the channel. That is the whole reason
# this needed a rule of its own.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import Role, RspOpcode
from chi_e_base_test import chi_e_base_test
from chi_tb_pkg import E_MTE_RNI_NODE_ID_C, E_MTE_SNF_NODE_ID_C

ADDR_C = 0x4F10_0000
SETTLE_C = 20
RULE_C = "CHI_SB_TAG_MATCH_OWED"

# Table 13-34: 0b11 is Match on a write.
TAGOP_MATCH_C = 0b11
TAGOP_TRANSFER_C = 0b01
TAG_C = 0x1234
TU_C = 0x0          # 13.10.38: "TU field is not applicable and must be set to
                    # zero" under Match.


class tc_chi_e_tag_match_negctl(chi_e_base_test):

  def configure(self, rni_cfg, snf_cfg):
    super().configure(rni_cfg, snf_cfg)
    snf_cfg.snf_tag_match_unrequested_negctl = True

  async def run_phase(self):
    self.raise_objection()

    sb = self.tb_env.scoreboard
    self.drain_observation_fifos()

    before_fail = sb.chk_fail.get(RULE_C, 0)
    assert before_fail == 0, (
      f"{RULE_C} already reported {before_fail} time(s) on bring-up traffic; "
      f"the count below would prove nothing")

    wr = self.rni_wr_seq
    wr.reset()
    wr.set_requests(1)
    wr.set_initial_addr(ADDR_C)
    wr.set_size(6)
    wr.set_src_id(E_MTE_RNI_NODE_ID_C)
    wr.set_tgt_id(E_MTE_SNF_NODE_ID_C)
    # Transfer, NOT Match: this write asks for no check, so the TagMatch the
    # control emits is owed to nobody.
    wr.set_dat_tagop(TAGOP_TRANSFER_C)
    # Pinned, because this write does not ask for a Match and so does not get
    # the requester-defaulted ReturnNID a Match-tagged one would. Without it the
    # completer's unrequested TagMatch is addressed to node 0 and never binds to
    # this transaction -- the control would provoke an orphan instead of the
    # rule it is aimed at. The obligation is what is under test here, not the
    # routing, so the route is held fixed.
    wr.set_return_nid(E_MTE_RNI_NODE_ID_C)
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
      "the control did not emit a TagMatch at all, so nothing was provoked")

    after_fail = sb.chk_fail.get(RULE_C, 0)
    assert after_fail > before_fail, (
      f"{RULE_C} did not report a TagMatch returned for a write whose data "
      f"carried no TagOp = Match. Either the control is not reaching the "
      f"completer, or the rule is keying on the response arriving rather than "
      f"on whether it was owed")

    self.logger.info(
      f"Test (tc_chi_e_tag_match_negctl) PASS: an unrequested TagMatch was "
      f"reported {after_fail - before_fail} time(s) by {RULE_C}")

    self.drop_objection()
