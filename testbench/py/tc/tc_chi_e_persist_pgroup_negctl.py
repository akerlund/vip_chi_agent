################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM/cocotb port of tc/tc_chi_e_persist_pgroup_negctl.sv.
#
# PGroupID reflected in the persist responses.
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
# The first step was to add it to the item and to both exact-E flit
# layouts. Table 13-6 gives the REQ side as ONE 8-bit position shared four ways
# -- "{GroupIDExt[2:0], LPID[4:0]} / PGroupID[7:0] / StashGroupID[7:0] /
# TagGroupID[7:0]" -- and Table 13-7 gives the RSP side as "DBID[11:0] /
# {4'b0, PGroupID[7:0]} / {4'b0, StashGroupID[7:0]}". Section 13.10.8 then
# writes the request-side encoding as an equation: PGroupID[7:0] =
# {GroupIDExt[2:0], LPID[4:0]}. Adding a physical field would have made this
# VIP's flits wider than the specification's -- in BOTH ports, so no parity
# check could have seen it. It is modelled here as what it is: a view.
#
# The negative control. cfg.snf_persist_pgroup_corrupt_negctl makes the completer
# return the requested group plus one -- a wrong-but-plausible value rather than
# zero, deliberately: zero is also what a completer that never learned about the
# field would send, and the rule has to fail on both. Incrementing also keeps the
# response inside the 8-bit field, so nothing else objects first.
#
# What is asserted:
#   * CHI_SB_PERSIST_PGROUP_MATCHES reports at least once. The transaction still
#     completes -- a wrong group identifier is invisible to every other check,
#     which is exactly why this rule had to exist.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from chi_e_base_test import chi_e_base_test
from vip_chi_persist_seq import vip_chi_persist_seq

ADDR_C = 0x4E20_0000
SETTLE_C = 20
RULE_C = "CHI_SB_PERSIST_PGROUP_MATCHES"

# Both halves of 13.10.8's equation are non-zero and different, so a completer
# that reflected GroupIDExt alone, or LPID alone, or swapped them, fails.
GROUP_ID_EXT_C = 0b101
LP_ID_C = 0b01011
PGROUP_ID_C = (GROUP_ID_EXT_C << 5) | LP_ID_C


class tc_chi_e_persist_pgroup_negctl(chi_e_base_test):

  def configure(self, rni_cfg, snf_cfg):
    super().configure(rni_cfg, snf_cfg)
    snf_cfg.snf_persist_pgroup_corrupt_negctl = True

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
    assert before_fail == 0, (
      f"{RULE_C} already reported {before_fail} time(s) on bring-up traffic; "
      f"the count below would prove nothing")

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

    after_fail = sb.chk_fail.get(RULE_C, 0)

    assert after_fail > before_fail, (
      f"{RULE_C} did not report a Persist carrying the wrong PGroupID. Either "
      f"the control is not reaching the completer, or the rule is comparing the "
      f"response against itself rather than against what the request asked for")

    self.logger.info(
      f"Test (tc_chi_e_persist_pgroup_negctl) PASS: a Persist returning a "
      f"PGroupID other than the requested 0x{PGROUP_ID_C:02x} was reported "
      f"{after_fail - before_fail} time(s) by {RULE_C}")

    self.drop_objection()
