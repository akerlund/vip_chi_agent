################################################################################
# pyUVM/cocotb port of tc/tc_chi_check_disable.sv.
#
# Negative control for the per-check enable itself.
#
# Before checks had identities, a user who hit one false fire during bring-up had
# to disable a whole bind and lose every other rule with it. The fix is only
# worth anything if a disable is actually TARGETED, so this asserts both halves
# on one run of ordinary traffic:
#
#   * the disabled rule records NOTHING -- not a pass, not a fail. Recording
#     passes would be worse than useless: the vacuity report would show a rule
#     the user switched off as quietly holding.
#   * a sibling rule on the same channel family still records passes, which is
#     what says the disable hit one rule rather than the bind.
#
# The sibling is checked on the SAME traffic rather than a second run, because a
# disable that silently took the whole bind down would otherwise be invisible --
# both rules would read zero and the test would pass.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from chi_base_test import chi_base_test

# Both fire on an ordinary WRITE, which is why the traffic is a write: the
# requester transmits the REQ flit and then the WriteData beats, so one rule sees
# each. A read would not do -- the requester only RECEIVES the data beats, and
# these rules are on the transmit side, so the sibling would read zero and the
# test would fail for a reason that has nothing to do with the disable.
DISABLED_C = "CHI_REQ_FLITV_REQUIRES_LINK"
SIBLING_C = "CHI_DAT_FLITV_REQUIRES_LINK"

ADDR_C = 0x3E80_0000
SIZE_C = 6                      # 64 B = 4 beats on the CHI-D cut
SETTLE_C = 20


class tc_chi_check_disable(chi_base_test):

  # Before any traffic: the checkers exist by connect_phase and the first flit
  # does not go out until run_phase.
  def connect_phase(self):
    super().connect_phase()
    for checker in (self.tb_env.rni_sva, self.tb_env.snf_sva):
      checker.disable_check(DISABLED_C)

  async def run_phase(self):
    self.raise_objection()

    wr = self.rni0_wr_seq
    wr.reset()
    wr.set_requests(2)
    wr.set_initial_addr(ADDR_C)
    wr.set_size(SIZE_C)
    wr.set_allow_retry(0)
    wr.set_get_response(True)
    wr.set_verbose(False)
    await wr.start(self.v_sqr.rni_sequencer)

    await self.wait_clocks(SETTLE_C)

    rni = self.tb_env.rni_sva

    disabled_pass = rni.pass_count.get(DISABLED_C, 0)
    disabled_fail = rni.fail_count.get(DISABLED_C, 0)
    sibling_pass = rni.pass_count.get(SIBLING_C, 0)

    # The sibling has to have fired, or this run proves nothing about the
    # disable: a bind that never checked anything would satisfy the first
    # assertion trivially.
    assert sibling_pass > 0, (
      f"{SIBLING_C} recorded {sibling_pass} passes on traffic that should "
      f"exercise it -- the run proves nothing about the disable")

    assert disabled_pass == 0 and disabled_fail == 0, (
      f"{DISABLED_C} was disabled but recorded {disabled_pass} pass(es) and "
      f"{disabled_fail} fail(es); a disabled rule must record nothing, or the "
      f"vacuity report shows a switched-off rule as quietly holding")

    # A disabled rule is excluded from the vacuity report on purpose: it did not
    # run BY REQUEST, and listing it would train the reader to ignore the list.
    assert DISABLED_C not in rni.not_exercised(), (
      f"{DISABLED_C} was disabled but is listed as not exercised; the report "
      f"must distinguish 'switched off' from 'never ran'")

    assert not rni.check_enable[DISABLED_C], (
      f"{DISABLED_C} does not read back as disabled")
    assert rni.check_enable[SIBLING_C], (
      f"{SIBLING_C} was disabled too -- the disable was not targeted")

    self.logger.info(
      f"Test (tc_chi_check_disable) PASS: {DISABLED_C} recorded nothing while "
      f"{SIBLING_C} recorded {sibling_pass} pass(es) on the same traffic")
    self.drop_objection()
