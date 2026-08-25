################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM/cocotb port of tc/tc_chi_e_persist_pgroup.sv.
#
# PGroupID reflected in the persist responses (F-INTOP-010).
#
# IHI 0050 E section 2.5: "A CleanSharedPersistSep and Combined Write with PCMO
# request includes a PGroupID to identify the Persistence Group that the request
# belongs to. If a Requester has persistent CMO requests from different
# functional agents that it would like to identify for performant persistent CMO
# handling, it can assign a different PGroupID value to each group [...] The
# PGroupID value returned in the Persist response can be used by a Requester to
# separately track completions of Persist responses from each group."
#
# So a completer that returns the wrong group does not break the transaction. It
# breaks the requester's ability to tell two groups apart -- a defect no
# completion-shape check can see, which is why this needed a rule of its own
# (CHI_SB_PERSIST_PGROUP_MATCHES) rather than an extra clause on an existing one.
#
# **PGroupID is not a field, and the finding was wrong to ask for one.**
# F-INTOP-010's first task was to add it to the item and to both exact-E flit
# layouts. Table 13-6 gives the REQ side as ONE 8-bit position shared four ways
# -- "{GroupIDExt[2:0], LPID[4:0]} / PGroupID[7:0] / StashGroupID[7:0] /
# TagGroupID[7:0]" -- and Table 13-7 gives the RSP side as "DBID[11:0] /
# {4'b0, PGroupID[7:0]} / {4'b0, StashGroupID[7:0]}". Section 13.10.8 then
# writes the request-side encoding as an equation: PGroupID[7:0] =
# {GroupIDExt[2:0], LPID[4:0]}. Adding a physical field would have made this
# VIP's flits wider than the specification's -- in BOTH ports, so no parity
# check could have seen it. It is modelled here as what it is: a view.
#
# This half drives a standalone CleanSharedPersistSep with a non-zero group, in
# both halves of the encoding: GroupIDExt carries the high three bits and LPID
# the low five, so a completer that reflected only one of them fails.
#
# What is asserted:
#   * CHI_SB_PERSIST_PGROUP_MATCHES records a pass and no failure;
#   * the transaction completes, so the reflection is not achieved by dropping
#     the response.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from chi_e_base_test import chi_e_base_test
from vip_chi_persist_seq import vip_chi_persist_seq

ADDR_C = 0x4E00_0000
SETTLE_C = 20
RULE_C = "CHI_SB_PERSIST_PGROUP_MATCHES"

# Both halves of 13.10.8's equation are non-zero and different, so a completer
# that reflected GroupIDExt alone, or LPID alone, or swapped them, fails.
GROUP_ID_EXT_C = 0b101
LP_ID_C = 0b01011
PGROUP_ID_C = (GROUP_ID_EXT_C << 5) | LP_ID_C


class tc_chi_e_persist_pgroup(chi_e_base_test):

  async def run_phase(self):
    self.raise_objection()

    sb = self.tb_env.scoreboard
    self.drain_observation_fifos()

    before_pass = sb.chk_pass.get(RULE_C, 0)
    before_fail = sb.chk_fail.get(RULE_C, 0)

    seq = vip_chi_persist_seq("persist_pgroup_seq", cfg=self.chi_cfg)
    seq.reset()
    # After reset(), which clears it.
    seq.set_sep_persist(True)
    seq.set_requests(1)
    seq.set_initial_addr(ADDR_C)
    seq.set_size(6)
    seq.set_group_id_ext(GROUP_ID_EXT_C)
    seq.set_lp_id(LP_ID_C)
    seq.set_get_response(True)
    seq.set_verbose(False)
    await seq.start(self.v_sqr.rni_sequencer)

    responses = seq.get_responses()
    assert len(responses) == 1, (
      f"the CleanSharedPersistSep returned {len(responses)} responses, "
      f"expected 1")

    await self.wait_clocks(SETTLE_C)

    after_pass = sb.chk_pass.get(RULE_C, 0)
    after_fail = sb.chk_fail.get(RULE_C, 0)

    assert after_fail == before_fail, (
      f"{RULE_C} reported {after_fail - before_fail} time(s) against a Persist "
      f"that should have carried back PGroupID 0x{PGROUP_ID_C:02x}")
    assert after_pass > before_pass, (
      f"{RULE_C} recorded no pass, so this testcase proves nothing. Either the "
      f"Persist never reached the scoreboard or the rule is not reading it")

    self.logger.info(
      f"Test (tc_chi_e_persist_pgroup) PASS: a CleanSharedPersistSep's Persist "
      f"carried back PGroupID 0x{PGROUP_ID_C:02x}, checked "
      f"{after_pass - before_pass} time(s) by {RULE_C}")

    self.drop_objection()
