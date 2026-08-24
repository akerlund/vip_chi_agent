################################################################################
# pyUVM/cocotb port of tc/tc_chi_lasm_illegal_transition.sv.
#
# Negative control for the link-activation state machine.
#
# The LASM may only hold, or advance one step around
# STOP -> ACTIVATE -> RUN -> DEACTIVATE -> STOP. Nothing checked that until the
# state existed: the link gating rules asked only "is the link RUN", which cannot
# tell a link that reached RUN legally from one that jumped there.
#
# cfg.lasm_abort_activation makes the RN-I raise txlinkactivereq and withdraw it
# again before the completer acknowledges, so the link leaves ACTIVATE without
# ever reaching RUN. A requester that has asked for the link must wait for the
# acknowledge, so this is a genuine violation rather than an unusual-but-legal
# sequence -- which is what makes it a usable control rather than a check tuned
# to its own stimulus.
#
# Both halves are asserted, because a transition check that fires on ordinary
# bring-up would be worse than none at all:
#   * the aborted activation must be reported, on both binds;
#   * the real activation that follows must not be, and the run must still carry
#     ordinary traffic to completion.
#
# The expected failure is declared per RULE, not by waiving the checker: a test
# whose whole purpose is to prove one rule fires must not also be blind to a
# second, unintended violation riding along with it.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from chi_base_test import chi_base_test

_RULE_C = "CHI_LASM_LEGAL_TRANSITION"
# 14.6.3's Banned Output Race, which the same abort violates -- see the second
# assertion below for why the two ends do not report it symmetrically.
_RACE_RULE_C = "CHI_LASM_OUTPUT_RACE"
# See the assertions below for the steps each of these decomposes into.
_ABORT_REPORTS_C = 2
_RACE_REPORTS_RNI_C = 2
_RACE_REPORTS_SNF_C = 0
# 14.6.3's companion requirement, on the OBSERVER rather than the driver. The
# completer is where it lands, and where it currently fails -- see the check.
_HOLD_RULE_C = "CHI_LASM_INPUT_RACE_HOLD"
_HOLD_REPORTS_RNI_C = 0
_HOLD_REPORTS_SNF_C = 0
ADDR_C = 0x3D40_0000
SIZE_C = 6                      # 64 B = 4 beats on the CHI-D cut
SETTLE_C = 20


class tc_chi_lasm_illegal_transition(chi_base_test):

  def configure(self, rni_cfg, snf_cfg):
    rni_cfg.lasm_abort_activation = True

  # The checkers exist by connect_phase and the abort happens during link
  # bring-up in run_phase, so this is early enough to declare the waiver and late
  # enough for the checkers to be there.
  def connect_phase(self):
    super().connect_phase()
    for checker in (self.tb_env.rni_sva, self.tb_env.snf_sva):
      checker.expect_failure(_RULE_C)
      # Declared at BOTH binds even though only the requester is expected to
      # report it, so a stray report at the completer fails on its own count
      # below rather than on the generic "unexpected violation" assertion --
      # which would say nothing about which rule moved.
      checker.expect_failure(_RACE_RULE_C)
      checker.expect_failure(_HOLD_RULE_C)

  async def run_phase(self):
    self.raise_objection()

    # Ordinary traffic after the aborted bring-up: the link must have come up
    # properly on the second attempt, or this would hang rather than pass.
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

    rni_fails = rni.fail_count.get(_RULE_C, 0)
    snf_fails = snf.fail_count.get(_RULE_C, 0)

    # Both ends observe the same handshake, so both must have seen the aborted
    # bring-up. One end reporting alone would mean the state is being derived
    # from something polarity-specific rather than from the link.
    assert rni_fails >= 1, (
      f"the RN-I checker reported {rni_fails} illegal LASM transition(s) on a "
      f"deliberately aborted activation -- the transition check may be vacuous")
    assert snf_fails >= 1, (
      f"the SN-F checker reported {snf_fails} illegal LASM transition(s) on a "
      f"deliberately aborted activation -- the transition check may be vacuous")

    # Exactly one aborted bring-up, so the run must not be littered with them --
    # one aborted activation is TWO reports per bind, and the decomposition is
    # the point rather than a number to tune. The requester raises its request
    # and withdraws it before the acknowledge, which Table 14-2 forbids -- "the
    # transmitter remains in the ACTIVATE state while it is waiting for the
    # receiver to acknowledge" -- and that one illegal act leaves two off-axis
    # steps behind on the machine that owns the aborted request, which each end
    # sees from its own side (TX at the requester, RX at the completer):
    #
    #   ACTIVATE -> STOP      the abort itself: the request up, then down, with
    #                         no acknowledge in between
    #   STOP -> DEACTIVATE    the acknowledge arriving a cycle later, for a
    #                         request that is already gone
    #
    # Neither is a permitted race. Figure 14-5's coloured states are COMBINED
    # (Tx,Rx) states reached by diagonals where two signals move at once; each
    # machine's own axis is a strictly one-way cycle with no exceptions, and
    # these are single-machine steps.
    #
    # It was THREE until the completer stopped withdrawing its own request
    # before its own acknowledge had risen (14.6.3's fourth ordering, fixed in
    # the SN-F/HN-F/HN-I sideband drivers). That defect added a third step,
    # ACTIVATE -> DEACTIVATE, where the request and the acknowledge crossed in
    # one cycle. The count fell because the VIP got more conformant, not because
    # the checker got quieter -- and CHI_LASM_OUTPUT_RACE below is what holds
    # that fix in place.
    #
    # Asserted EXACTLY, not as a ceiling: a drift in either direction means the
    # handshake changed shape and should be read, not absorbed.
    assert rni_fails == _ABORT_REPORTS_C and snf_fails == _ABORT_REPORTS_C, (
      f"one aborted activation produced {rni_fails} (RN-I) / {snf_fails} (SN-F) "
      f"reports, expected exactly {_ABORT_REPORTS_C} at each end; more means the "
      f"legal bring-up that followed is being flagged too, fewer means a machine "
      f"stopped judging its own axis")

    # The same abort is a Banned Output Race, and 14.6.3 attributes it to ONE
    # component: the requester deasserts TXREQ before RXACK is asserted (the
    # fourth ordering), and a cycle later its acknowledge rises against a
    # request that is already down (the first). Two reports, both at the RN-I.
    #
    # The completer must report NONE, and that asymmetry is the assertion worth
    # having: 14.6.3 binds each component's own two outputs, so a completer
    # dragged into an illegal handshake by its peer still has to keep its own
    # pair ordered. It did not, until the sideband drivers were made to hold
    # their request until their own acknowledge had risen -- before that fix the
    # SN-F reported one of these too. A non-zero count here means that
    # regressed.
    rni_race = rni.fail_count.get(_RACE_RULE_C, 0)
    snf_race = snf.fail_count.get(_RACE_RULE_C, 0)
    assert rni_race == _RACE_REPORTS_RNI_C and snf_race == _RACE_REPORTS_SNF_C, (
      f"the aborted activation produced {rni_race} (RN-I) / {snf_race} (SN-F) "
      f"banned-output-race report(s), expected exactly {_RACE_REPORTS_RNI_C} / "
      f"{_RACE_REPORTS_SNF_C}; a report at the completer means its own two "
      f"outputs stopped being ordered against each other")

    # 14.6.3's companion requirement, and this one is on the OBSERVER: "a
    # component that observes the input race is required to wait for both
    # signals before changing any output signals."
    #
    # The requester's abort reaches the completer as an input race -- its two
    # inputs step out of the order the four orderings require -- and the
    # completer does NOT wait: its acknowledge, one cycle behind its own
    # request, rises in the middle of the race. That is a real gap in this VIP
    # (F-CORR-025) and the count is pinned at 1 rather than waived, so the fix
    # will show up here as this dropping to 0 and nowhere else.
    #
    # The requester reports NONE: its own inputs are the completer's two
    # outputs, and those stay ordered.
    rni_hold = rni.fail_count.get(_HOLD_RULE_C, 0)
    snf_hold = snf.fail_count.get(_HOLD_RULE_C, 0)
    assert rni_hold == _HOLD_REPORTS_RNI_C and snf_hold == _HOLD_REPORTS_SNF_C, (
      f"the input race produced {rni_hold} (RN-I) / {snf_hold} (SN-F) hold "
      f"violation(s), expected exactly {_HOLD_REPORTS_RNI_C} / "
      f"{_HOLD_REPORTS_SNF_C}")

    # The deliberate failures are demoted, so nothing else may have fired.
    assert rni.errors == 0 and snf.errors == 0, (
      f"checkers reported {rni.errors} (RN-I) / {snf.errors} (SN-F) unexpected "
      f"violation(s) beyond the declared {_RULE_C}")

    # The legal cycle still has to have been walked, or the abort would have
    # been the only thing this test proved.
    assert rni.pass_count.get(_RULE_C, 0) > 0, (
      "the transition check recorded no legal steps at all")

    self.logger.info(
      f"Test (tc_chi_lasm_illegal_transition) PASS: aborted activation flagged "
      f"{rni_fails} (RN-I) / {snf_fails} (SN-F) time(s), the bring-up that "
      f"followed was not, and one read completed over the recovered link")
    self.drop_objection()
