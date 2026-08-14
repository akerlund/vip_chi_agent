################################################################################
# pyUVM/cocotb port of tc/tc_chi_check_vacuity.sv.
#
# The vacuity report is a check on the checks, so it needs a check of its own.
#
# "This rule was never exercised" is only useful if it TRACKS THE TRAFFIC. A
# report that listed everything, or nothing, would look identical on a clean run
# and would be believed just as readily -- which is the precise failure this
# whole mechanism exists to prevent, so it must not be the mechanism's own bug.
#
# Two phases on one run, with the same rule read twice:
#
#   phase 1  a plain read. CHI_COMPACK_WITHOUT_EXPCOMPACK cannot have been
#            evaluated, because nothing has sent a CompAck, so the report must
#            list it -- while a rule the read DOES exercise must be absent.
#   phase 2  a write with ExpCompAck, which makes the requester drive CompAck.
#            The same rule must now have moved OUT of the report.
#
# Asserting the transition rather than a snapshot is what makes this
# non-tautological: a hard-coded list would pass phase 1 and fail phase 2.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from chi_base_test import chi_base_test

# Evaluated only when a CompAck goes out, so a read-only phase cannot reach it.
COMPACK_RULE_C = "CHI_COMPACK_WITHOUT_EXPCOMPACK"
# Evaluated by any outbound REQ, so the very first read reaches it.
ALWAYS_RULE_C = "CHI_REQ_FLITV_REQUIRES_LINK"

ADDR_C = 0x3F00_0000
SIZE_C = 6                      # 64 B = 4 beats on the CHI-D cut
SETTLE_C = 20


class tc_chi_check_vacuity(chi_base_test):

  async def run_phase(self):
    self.raise_objection()

    rni = self.tb_env.rni_sva

    # -- Phase 1: a read cannot exercise the CompAck rule. --------------------
    rd = self.rni0_rd_seq
    rd.reset()
    rd.set_requests(1)
    rd.set_initial_addr(ADDR_C)
    rd.set_size(SIZE_C)
    rd.set_allow_retry(0)
    rd.set_get_response(True)
    rd.set_verbose(False)
    await rd.start(self.v_sqr.rni_sequencer)

    await self.wait_clocks(SETTLE_C)

    missing = rni.not_exercised()

    assert COMPACK_RULE_C in missing, (
      f"{COMPACK_RULE_C} is absent from the vacuity report after read-only "
      f"traffic that cannot reach it -- the report is not tracking what ran")
    assert ALWAYS_RULE_C not in missing, (
      f"{ALWAYS_RULE_C} is listed as not exercised after a read that must have "
      f"exercised it -- the report is over-reporting")

    # The count and the list have to agree, or a sweep reading one and a human
    # reading the other draw different conclusions from the same run.
    assert len(missing) == len(set(missing)), (
      "the vacuity report lists a rule more than once")

    # -- Phase 2: a write with ExpCompAck drives a CompAck. -------------------
    wr = self.rni0_wr_seq
    wr.reset()
    wr.set_requests(1)
    wr.set_initial_addr(ADDR_C)
    wr.set_size(SIZE_C)
    wr.set_exp_comp_ack(1)
    wr.set_allow_retry(0)
    wr.set_get_response(True)
    wr.set_verbose(False)
    await wr.start(self.v_sqr.rni_sequencer)

    await self.wait_clocks(SETTLE_C)

    missing_after = rni.not_exercised()

    assert COMPACK_RULE_C not in missing_after, (
      f"{COMPACK_RULE_C} is still listed as not exercised after a write that "
      f"drove a CompAck -- the report is stale, not live")
    assert rni.pass_count.get(COMPACK_RULE_C, 0) > 0, (
      f"{COMPACK_RULE_C} left the vacuity report without recording a pass; the "
      f"report and the tallies disagree")

    # It must have SHRUNK by that rule, not been rebuilt differently: everything
    # unexercised after phase 2 must also have been unexercised after phase 1.
    assert set(missing_after) <= set(missing), (
      f"rules appeared in the vacuity report between phases: "
      f"{sorted(set(missing_after) - set(missing))}")

    self.logger.info(
      f"Test (tc_chi_check_vacuity) PASS: {COMPACK_RULE_C} was reported "
      f"unexercised after a read ({len(missing)} listed) and dropped out once a "
      f"CompAck went out ({len(missing_after)} listed)")
    self.drop_objection()
