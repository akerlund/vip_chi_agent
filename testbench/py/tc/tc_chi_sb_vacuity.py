################################################################################
# pyUVM/cocotb port of tc/tc_chi_sb_vacuity.sv.
#
# The scoreboard's vacuity report is a check on the checks, so it needs a check
# of its own -- the same argument tc_chi_check_vacuity makes for the SVA binds,
# applied to the half of the registry that was outside the mechanism until now.
#
# "This scoreboard rule was never exercised" is only useful if it TRACKS THE
# TRAFFIC. A report that listed every rule, or none, would look identical on a
# clean run and would be believed just as readily. That failure would be worse
# here than on the SVA side, because the scoreboard's rules had no pass counts at
# all before: a rule that stopped evaluating and a rule that always held produced
# the same log, which is precisely what this exists to end.
#
# Two phases on one run, with the same rule read twice:
#
#   phase 1  an UNORDERED read. CHI_SB_ORDERED_ACK_IN_ORDER cannot have been
#            evaluated -- nothing joined an ordered stream -- so it must read as
#            unexercised, while CHI_SB_TXN_COMPLETES, which that same read does
#            reach, must not.
#   phase 2  an ORDERED read, whose ReadReceipt is the completer committing to a
#            position in its stream. The same rule must now have moved out.
#
# Asserting the transition rather than a snapshot is what makes this
# non-tautological: a hard-coded answer would pass phase 1 and fail phase 2.
#
# The pass COUNT is asserted too, not just the rule's absence from the list. A
# rule leaves the unexercised list on its first fail as readily as on its first
# pass, so absence alone would also be satisfied by an ordered stream the
# completer got wrong.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import ReqOrder
from vip_chi_scoreboard import SB_ORDERED_ACK_IN_ORDER, SB_TXN_COMPLETES
from chi_base_test import chi_base_test

ADDR_C = 0x3C80_0000
SIZE_C = 6                      # 64 B = 4 beats on the CHI-D cut
N_C = 4
SETTLE_C = 20


class tc_chi_sb_vacuity(chi_base_test):

  def _unexercised(self, rule):
    """A rule is "not exercised" exactly when it has neither passed nor failed."""
    sb = self.tb_env.scoreboard
    return not sb.chk_pass[rule] and not sb.chk_fail[rule]

  async def run_phase(self):
    self.raise_objection()

    sb = self.tb_env.scoreboard

    # -- Phase 1: an unordered read cannot exercise the ordering rule. --------
    rd = self.rni0_rd_seq
    rd.reset()
    rd.set_requests(1)
    rd.set_initial_addr(ADDR_C)
    rd.set_size(SIZE_C)
    rd.set_get_response(True)
    rd.set_verbose(False)
    await rd.start(self.v_sqr.rni_sequencer)

    await self.wait_clocks(SETTLE_C)

    assert self._unexercised(SB_ORDERED_ACK_IN_ORDER), (
      f"{SB_ORDERED_ACK_IN_ORDER} is reported as exercised after an UNORDERED "
      f"read, which cannot reach it -- the report is not tracking the traffic")

    # The other half, and the one that makes this more than a spelling test: a
    # report that simply listed everything would satisfy the assertion above.
    assert not self._unexercised(SB_TXN_COMPLETES), (
      f"{SB_TXN_COMPLETES} is reported as unexercised after a read that "
      f"retired -- the report is listing rules it has no business listing")

    # -- Phase 2: an ordered read reaches it. ---------------------------------
    rd = self.rni0_rd_seq
    rd.reset()
    rd.set_requests(N_C)
    rd.set_initial_addr(ADDR_C)
    rd.set_size(SIZE_C)
    rd.set_order(int(ReqOrder.REQ_ORDER))
    rd.set_get_response(True)
    rd.set_verbose(False)
    await rd.start(self.v_sqr.rni_sequencer)

    await self.wait_clocks(SETTLE_C)

    assert not self._unexercised(SB_ORDERED_ACK_IN_ORDER), (
      f"{SB_ORDERED_ACK_IN_ORDER} is still reported as unexercised after {N_C} "
      f"ORDERED reads -- the report does not move, so it cannot be read as "
      f"evidence")

    # It moved because the rule PASSED, not because it failed.
    assert sb.chk_fail[SB_ORDERED_ACK_IN_ORDER] == 0, (
      f"{SB_ORDERED_ACK_IN_ORDER} reported "
      f"{sb.chk_fail[SB_ORDERED_ACK_IN_ORDER]} failure(s) against an in-order "
      f"completer")

    self.logger.info(
      f"Test (tc_chi_sb_vacuity) PASS: {SB_ORDERED_ACK_IN_ORDER} moved from "
      f"unexercised to {sb.chk_pass[SB_ORDERED_ACK_IN_ORDER]} pass(es) when the "
      f"traffic reached it, while {SB_TXN_COMPLETES} never appeared in the "
      f"report")
    self.drop_objection()
