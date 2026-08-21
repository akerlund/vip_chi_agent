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

    # Exactly one aborted bring-up, so the run must not be littered with them:
    # a check that fired on the legal activation that followed would report more.
    assert rni_fails <= 2 and snf_fails <= 2, (
      f"one aborted activation produced {rni_fails} (RN-I) / {snf_fails} (SN-F) "
      f"reports; the legal bring-up that followed is being flagged too")

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
