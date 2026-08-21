################################################################################
# pyUVM/cocotb port of tc/tc_chi_lasm_timeout.sv.
#
# Negative control for the two link-activation timeouts.
#
# A link stuck in ACTIVATE or DEACTIVATE is the one failure here that no other
# rule can see, because every cycle of it is legal: holding is always a legal
# LASM step, no flit goes out to violate a channel rule, and the
# transaction-completion timeout has nothing in flight to measure. A link stuck
# coming up has not yet carried a transaction; a link stuck going down has
# already retired them all. The run simply hangs, and hangs without naming
# anything -- which is exactly the kind of failure a checker is for.
#
# Both halves are provoked from the COMPLETER, because a stuck link is an
# acknowledge that does not arrive and only the completer drives one:
#
#   phase 1  cfg.lasm_stall_activation_cycles withholds the acknowledge to the
#            bring-up request. The link sits in ACTIVATE past the bound.
#   phase 2  cfg.lasm_stall_deactivation_cycles withholds the DROP of the
#            acknowledge after the drain has finished. The link sits in
#            DEACTIVATE past the bound.
#
# Both are genuine violations rather than stimulus tuned to the check: a
# requester that has asked for the link is entitled to an answer, and a receiver
# that has had every credit returned has nothing left to wait for.
#
# The stalls are deliberately FINITE. A control that wedged the link forever
# would prove the check fires and then hang the test, so each stall clears well
# after the bound and the run continues -- which also demonstrates the reported
# link recovers, and that the timeout reports ONCE rather than once per cycle.
#
# The expected failures are declared per RULE, not by waiving the checker: a test
# whose whole purpose is to prove two rules fire must not also be blind to a
# third, unintended violation riding along with them.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from chi_base_test import chi_base_test

_ACT_C = "CHI_LASM_ACTIVATION_TIMEOUT"
_DEACT_C = "CHI_LASM_DEACTIVATION_TIMEOUT"

ADDR_C = 0x3DC0_0000
SIZE_C = 6                      # 64 B = 4 beats on the CHI-D cut
SETTLE_C = 20

# The bound the checkers enforce, and the stall that must overrun it. Kept well
# apart so the test is not sensitive to a cycle either way in the handshake, and
# so the stall clearing is unambiguously after the report.
TIMEOUT_C = 16
STALL_C = 64

DEACT_TIMEOUT_C = 4000


class tc_chi_lasm_timeout(chi_base_test):

  def configure_tb_cfg(self):
    self.tb_cfg.link_activation_timeout_cycles = TIMEOUT_C
    self.tb_cfg.link_deactivation_timeout_cycles = TIMEOUT_C

  def configure(self, rni_cfg, snf_cfg):
    snf_cfg.lasm_stall_activation_cycles = STALL_C
    snf_cfg.lasm_stall_deactivation_cycles = STALL_C

  # The checkers exist by connect_phase and the stalled bring-up happens during
  # link activation in run_phase, so this is early enough to declare the waivers
  # and late enough for the checkers to be there.
  def connect_phase(self):
    super().connect_phase()
    for checker in (self.tb_env.rni_sva, self.tb_env.snf_sva):
      checker.expect_failure(_ACT_C)
      checker.expect_failure(_DEACT_C)

  async def _wait_deactivate_done(self, want):
    waited = 0
    while bool(self.rni_cfg.link_deactivate_done) != want:
      await self.wait_clocks(1)
      waited += 1
      assert waited <= DEACT_TIMEOUT_C, (
        f"link_deactivate_done never reached {want} within {DEACT_TIMEOUT_C} "
        f"cycles -- the link is stuck")

  async def run_phase(self):
    self.raise_objection()

    rni, snf = self.tb_env.rni_sva, self.tb_env.snf_sva

    # -- Phase 1: the stalled bring-up. --------------------------------------
    #
    # The stall is already counting down from time 0, so by the time this
    # sequence completes the link has been through a long ACTIVATE, reported it,
    # recovered, and carried the traffic. Requiring the traffic to complete is
    # what proves the stall was survivable rather than fatal.
    rd = self.rni0_rd_seq
    rd.reset()
    rd.set_requests(1)
    rd.set_initial_addr(ADDR_C)
    rd.set_size(SIZE_C)
    rd.set_get_response(True)
    rd.set_verbose(False)
    await rd.start(self.v_sqr.rni_sequencer)

    await self.wait_clocks(SETTLE_C)

    act_rni = rni.fail_count.get(_ACT_C, 0)
    act_snf = snf.fail_count.get(_ACT_C, 0)

    # Both ends observe the same handshake, so both must have seen the stuck
    # bring-up. One end reporting alone would mean the state is being derived
    # from something polarity-specific rather than from the link.
    assert act_rni >= 1 and act_snf >= 1, (
      f"a bring-up held {STALL_C} cycles against a {TIMEOUT_C}-cycle bound "
      f"reported {act_rni} (RN-I) / {act_snf} (SN-F) time(s); the activation "
      f"timeout is not firing")

    # One stuck episode, one report per bind. Reporting per cycle would bury the
    # one useful line under STALL_C - TIMEOUT_C copies of itself.
    assert act_rni <= 1 and act_snf <= 1, (
      f"one stalled bring-up produced {act_rni} (RN-I) / {act_snf} (SN-F) "
      f"reports; the timeout is firing per cycle rather than on the crossing")

    # -- Phase 2: the stalled tear-down. -------------------------------------
    self.rni_cfg.link_deactivate_request = True
    await self._wait_deactivate_done(True)
    await self.wait_clocks(SETTLE_C)

    deact_rni = rni.fail_count.get(_DEACT_C, 0)
    deact_snf = snf.fail_count.get(_DEACT_C, 0)

    assert deact_rni >= 1 and deact_snf >= 1, (
      f"a tear-down held {STALL_C} cycles against a {TIMEOUT_C}-cycle bound "
      f"reported {deact_rni} (RN-I) / {deact_snf} (SN-F) time(s); the "
      f"deactivation timeout is not firing")

    assert deact_rni <= 1 and deact_snf <= 1, (
      f"one stalled tear-down produced {deact_rni} (RN-I) / {deact_snf} (SN-F) "
      f"reports; the timeout is firing per cycle rather than on the crossing")

    # The link must still come back: a reported timeout is a diagnostic, not a
    # wedge, and a control that left the link dead could not tell the two apart.
    self.rni_cfg.link_deactivate_request = False
    await self._wait_deactivate_done(False)
    await self.wait_clocks(SETTLE_C)

    # The deliberate failures are demoted, so nothing else may have fired.
    assert rni.errors == 0 and snf.errors == 0, (
      f"checkers reported {rni.errors} (RN-I) / {snf.errors} (SN-F) unexpected "
      f"violation(s) beyond the declared {_ACT_C} / {_DEACT_C}")

    self.logger.info(
      f"Test (tc_chi_lasm_timeout) PASS: a {STALL_C}-cycle stall against a "
      f"{TIMEOUT_C}-cycle bound reported the stuck ACTIVATE {act_rni} (RN-I) / "
      f"{act_snf} (SN-F) time(s) and the stuck DEACTIVATE {deact_rni} / "
      f"{deact_snf} time(s); the link recovered from each")
    self.drop_objection()
