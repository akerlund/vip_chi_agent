################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM/cocotb port of tc/tc_chi_e_persist_return_nid.sv.
#
# Where a PCMO's Persist is addressed.
#
# IHI 0050 E section 2.8: "The ReturnNID value in the request must be used as the
# target in the following responses by the Slave: in the DBIDResp, if the DoDWT
# bit in the request is set to one; in the Persist, if the CMO in the request is
# a PCMO." CompCMO is NOT in that list and keeps SrcID -- the two responses to
# one combined request go to two different fields, which is the whole point.
#
# The regression could not have caught the completer getting this wrong, and the
# reason is worth stating: every other test leaves ReturnNID at zero or at the
# requester's own node, so SrcID and ReturnNID name the same node and a Persist
# sent to either lands in the same place. This test is the one that separates
# them -- ReturnNID is set to a node that is NOT the requester, so the two
# fields disagree and the routing becomes observable.
#
# What is asserted, at both ends of the claim:
#   * the scoreboard's CHI_SB_RSP_TGTID_CORRECT records a pass and no failure,
#     which is the rule reading the TgtID off the wire;
#   * the transaction still completes, so the reroute is not achieved by
#     dropping the response.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_write_cmo_seq import vip_chi_write_cmo_seq, CMO_CLEAN_SH_PER_SEP
from chi_e_base_test import chi_e_base_test

ADDR_C = 0x4B00_0000
SIZE_C = 6
SETTLE_C = 20
RULE_C = "CHI_SB_RSP_TGTID_CORRECT"

# A node that is deliberately NOT the requester and NOT the completer, so a
# Persist addressed to SrcID and one addressed to ReturnNID are distinguishable.
# It does not have to exist: the link is point to point, so the flit arrives
# here whatever its TgtID says, and the TgtID is the thing under test.
RETURN_NID_C = 0x1A5


class tc_chi_e_persist_return_nid(chi_e_base_test):

  async def run_phase(self):
    self.raise_objection()

    sb = self.tb_env.scoreboard
    self.drain_observation_fifos()

    before_pass = sb.chk_pass.get(RULE_C, 0)
    before_fail = sb.chk_fail.get(RULE_C, 0)

    seq = vip_chi_write_cmo_seq("write_cmo_persist_return_nid", cfg=self.chi_cfg)
    seq.set_partial(False)
    seq.set_cmo(CMO_CLEAN_SH_PER_SEP)
    seq.reset()
    seq.set_requests(1)
    seq.set_initial_addr(ADDR_C)
    seq.set_size(SIZE_C)
    # The whole point of the testcase. Without this the field defaults to the
    # requester's own node and the rule below cannot tell the two apart.
    seq.set_return_nid(RETURN_NID_C)
    seq.set_get_response(True)
    seq.set_verbose(False)
    await seq.start(self.v_sqr.rni_sequencer)

    responses = seq.get_responses()
    assert len(responses) == 1, (
      f"the combined Write + PCMO returned {len(responses)} responses, "
      f"expected 1; a reroute that drops the transaction proves nothing")

    await self.wait_clocks(SETTLE_C)

    after_pass = sb.chk_pass.get(RULE_C, 0)
    after_fail = sb.chk_fail.get(RULE_C, 0)

    assert after_fail == before_fail, (
      f"{RULE_C} reported {after_fail - before_fail} time(s) against a Persist "
      f"the completer should have addressed to ReturnNID 0x{RETURN_NID_C:x}: "
      f"section 2.8 routes a PCMO's Persist there, not to the requester's SrcID")
    assert after_pass > before_pass, (
      f"{RULE_C} recorded no pass, so this testcase proves nothing. Either the "
      f"Persist never reached the scoreboard or the rule is not reading it -- "
      f"and a rule with no passes is indistinguishable from one that is absent")

    self.logger.info(
      f"Test (tc_chi_e_persist_return_nid) PASS: the Persist for a combined "
      f"Write + PCMO was addressed to ReturnNID 0x{RETURN_NID_C:x} rather than "
      f"to the requester, checked {after_pass - before_pass} time(s) by {RULE_C}")

    self.drop_objection()
