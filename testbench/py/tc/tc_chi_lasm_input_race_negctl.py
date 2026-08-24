################################################################################
# pyUVM/cocotb port of tc/tc_chi_lasm_input_race_negctl.sv.
#
# Negative control for the OBSERVER half of the asynchronous race condition.
#
# E section 14.6.3 / D section 13.6.3 states four orderings on a component's own
# two outputs and then, separately, an obligation on whoever WATCHES a pair that
# arrived out of order:
#
#   "For all input race conditions, a component that observes the input race is
#    required to wait for both signals before changing any output signals. This
#    is represented in Figure 14-5 by the fact that the only permitted output
#    transition from a race state is caused by the arrival of the other signal
#    associated with the race condition."
#
# This test exists because FIXING the VIP removed the rule's only failing
# observation. CHI_LASM_INPUT_RACE_HOLD had exactly one, and it was the VIP's own
# defect -- the completer's acknowledge moving through a race -- rather than
# deliberate stimulus. With that fixed the rule could no longer fail anywhere,
# which in every log and in the vacuity report is indistinguishable from a rule
# that is never evaluated.
#
# Two knobs, and it takes both, which is the shape of the requirement:
#   * the REQUESTER aborts its activation, which is what produces a pair of
#     outputs arriving at the completer out of order -- the race;
#   * the COMPLETER then ignores it and moves its outputs through it.
#
# Neither alone is a control. Without the abort there is no race to observe and
# the rule is vacuous; without the ignore the completer waits and the rule
# passes. That is why the two are separate knobs rather than one.
#
# The expected failures are declared per RULE, not by waiving the checker: a test
# whose purpose is to prove one rule fires must not be blind to a second.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from chi_base_test import chi_base_test

_HOLD_RULE_C = "CHI_LASM_INPUT_RACE_HOLD"
# The abort is a genuine illegal transition and a banned output race as well, so
# both fire. Neither is what this test is about; each has its own control in
# tc_chi_lasm_illegal_transition, so they are declared and only sanity-bounded.
_TRANS_RULE_C = "CHI_LASM_LEGAL_TRANSITION"
_OUT_RULE_C = "CHI_LASM_OUTPUT_RACE"

# One race observed, one output moved through it, one report. The requester
# observes none: its own inputs are the completer's two outputs, and those stay
# ordered whatever this knob does to the completer's reaction.
_HOLD_REPORTS_RNI_C = 0
_HOLD_REPORTS_SNF_C = 1

ADDR_C = 0x3E00_0000
SIZE_C = 6                      # 64 B = 4 beats on the CHI-D cut
SETTLE_C = 20


class tc_chi_lasm_input_race_negctl(chi_base_test):

  def configure(self, rni_cfg, snf_cfg):
    # The abort makes the race; the ignore makes the violation.
    rni_cfg.lasm_abort_activation = True
    snf_cfg.lasm_ignore_input_race = True

  def connect_phase(self):
    super().connect_phase()
    for checker in (self.tb_env.rni_sva, self.tb_env.snf_sva):
      checker.expect_failure(_HOLD_RULE_C)
      checker.expect_failure(_TRANS_RULE_C)
      checker.expect_failure(_OUT_RULE_C)

  async def run_phase(self):
    self.raise_objection()

    # Ordinary traffic after the aborted bring-up. This matters more here than in
    # the sibling test: a completer that ignores the race must still end up with
    # a working link, or the control would be proving the rule fires by wedging
    # the interface.
    rd = self.rni0_rd_seq
    rd.reset()
    rd.set_requests(1)
    rd.set_initial_addr(ADDR_C)
    rd.set_size(SIZE_C)
    rd.set_get_response(True)
    rd.set_verbose(False)
    await rd.start(self.v_sqr.rni_sequencer)

    await self.wait_clocks(SETTLE_C)

    rni = self.tb_env.rni_sva
    snf = self.tb_env.snf_sva

    rni_hold = rni.fail_count.get(_HOLD_RULE_C, 0)
    snf_hold = snf.fail_count.get(_HOLD_RULE_C, 0)

    assert rni_hold == _HOLD_REPORTS_RNI_C and snf_hold == _HOLD_REPORTS_SNF_C, (
      f"the observed input race produced {rni_hold} (RN-I) / {snf_hold} (SN-F) "
      f"hold violation(s), expected exactly {_HOLD_REPORTS_RNI_C} / "
      f"{_HOLD_REPORTS_SNF_C}; zero at the completer means the knob no longer "
      f"defeats the hold, or the race is not being observed at all")

    # NO pass-count assertion, deliberately. The rule is `armed -> stable`, so it
    # only evaluates in a cycle where a race is armed -- and with this knob on,
    # every such cycle is a violation. There is one race in this run, so a
    # passing evaluation cannot exist here to assert on. The pass side of the
    # evidence lives in tc_chi_lasm_race, where the completer observes a race and
    # waits it out; between the two the rule is shown to distinguish. The guard
    # against a rule that reports on everything is the requester's ZERO above.

    # The abort still has to be the illegal transition it always was: if this
    # went to zero the stimulus stopped happening and the race came from
    # somewhere else.
    rni_trans = rni.fail_count.get(_TRANS_RULE_C, 0)
    snf_trans = snf.fail_count.get(_TRANS_RULE_C, 0)
    assert rni_trans > 0 and snf_trans > 0, (
      f"the aborted activation produced {rni_trans} (RN-I) / {snf_trans} (SN-F) "
      f"illegal-transition report(s); the stimulus this control rests on is not "
      f"happening")

    self.logger.info(
      f"Test (tc_chi_lasm_input_race_negctl) PASS: a completer that ignored an "
      f"observed input race was flagged {snf_hold} time(s) at its own bind and "
      f"{rni_hold} at the requester's, and the link still carried a read to "
      f"completion")
    self.drop_objection()
