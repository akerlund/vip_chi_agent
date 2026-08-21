################################################################################
# pyUVM/cocotb port of tc/tc_chi_lasm_race.sv.
#
# The link activation state machine under a RACE rather than a malformed
# sequence.
#
# tc_chi_lasm_illegal_transition breaks the BRING-UP half: a request withdrawn
# before the acknowledge. This breaks the TEAR-DOWN half, and it could not exist
# until graceful deactivation did -- there was no tear-down to race with.
#
# cfg.lasm_reactivate_during_deactivate makes the requester change its mind half
# way through: the link is in DEACTIVATE (request low, acknowledge still high,
# completer still returning credits) and the requester raises its request again.
# The pair {1,1} is RUN, so the link jumps DEACTIVATE -> RUN, which the cycle
# does not allow -- DEACTIVATE may only advance to STOP.
#
# It is a genuine violation rather than stimulus tuned to the check: a requester
# that has withdrawn its request has committed to the tear-down. What makes it a
# RACE rather than simply a wrong sequence is WHEN it lands -- inside the window
# where the completer has not yet decided to drop its acknowledge, which no
# amount of shifting a uniform delay could reach.
#
# Both halves are asserted: the illegal step must be reported on both binds, and
# the link must still come back and carry traffic, because a race that left the
# link dead would be indistinguishable from a wedge.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from chi_base_test import chi_base_test

_RULE_C = "CHI_LASM_LEGAL_TRANSITION"
ADDR_C = 0x3E80_0000
SIZE_C = 6                      # 64 B = 4 beats on the CHI-D cut
SETTLE_C = 20
DEACT_TIMEOUT_C = 4000


class tc_chi_lasm_race(chi_base_test):

  def configure(self, rni_cfg, snf_cfg):
    rni_cfg.lasm_reactivate_during_deactivate = True

  def connect_phase(self):
    super().connect_phase()
    for checker in (self.tb_env.rni_sva, self.tb_env.snf_sva):
      checker.expect_failure(_RULE_C)

  async def _wait_deactivate_done(self, want):
    waited = 0
    while bool(self.rni_cfg.link_deactivate_done) != want:
      await self.wait_clocks(1)
      waited += 1
      assert waited <= DEACT_TIMEOUT_C, (
        f"link_deactivate_done never reached {want} within {DEACT_TIMEOUT_C} "
        f"cycles -- the link is stuck")

  async def _one_read(self, addr):
    rd = self.rni0_rd_seq
    rd.reset()
    rd.set_requests(1)
    rd.set_initial_addr(addr)
    rd.set_size(SIZE_C)
    rd.set_get_response(True)
    rd.set_verbose(False)
    await rd.start(self.v_sqr.rni_sequencer)

  async def run_phase(self):
    self.raise_objection()

    rni, snf = self.tb_env.rni_sva, self.tb_env.snf_sva

    # Traffic first, so the tear-down has something real to tear down.
    await self._one_read(ADDR_C)
    await self.wait_clocks(SETTLE_C)

    # Deactivate. The driver races its own tear-down on the way through.
    self.rni_cfg.link_deactivate_request = True
    await self._wait_deactivate_done(True)
    await self.wait_clocks(SETTLE_C)

    rni_fails = rni.fail_count.get(_RULE_C, 0)
    snf_fails = snf.fail_count.get(_RULE_C, 0)

    # Both ends observe the same handshake, so both must have seen the race. One
    # end reporting alone would mean the state is derived from something
    # polarity-specific rather than from the link.
    assert rni_fails >= 1 and snf_fails >= 1, (
      f"a request raised inside the tear-down window produced {rni_fails} "
      f"(RN-I) / {snf_fails} (SN-F) illegal-transition report(s); the rule does "
      f"not see the race")

    # Bring it back and prove the link survived the race.
    self.rni_cfg.link_deactivate_request = False
    await self._wait_deactivate_done(False)
    await self.wait_clocks(SETTLE_C)

    await self._one_read(ADDR_C + 64)
    await self.wait_clocks(SETTLE_C)

    assert rni.errors == 0 and snf.errors == 0, (
      f"checkers reported {rni.errors} (RN-I) / {snf.errors} (SN-F) unexpected "
      f"violation(s) beyond the declared {_RULE_C}")

    self.logger.info(
      f"Test (tc_chi_lasm_race) PASS: a request raised inside the tear-down "
      f"window was flagged {rni_fails} (RN-I) / {snf_fails} (SN-F) time(s), and "
      f"the link recovered and carried traffic again")
    self.drop_objection()
