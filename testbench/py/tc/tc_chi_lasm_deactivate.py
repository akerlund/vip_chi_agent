################################################################################
# pyUVM/cocotb port of tc/tc_chi_lasm_deactivate.sv.
#
# The second half of the link activation state machine.
#
# Until this test existed the VIP could only take a link down by RESET, so the
# two tear-down edges -- RUN -> DEACTIVATE and DEACTIVATE -> STOP -- were checked
# but never once walked. Everything downstream of that was untestable by
# construction: CHI_LCRD_QUIESCENT_IN_STOP only ever saw the pre-activation STOP
# where the counts are trivially zero, CHI_LINK_DEACTIVATE_WHEN_IDLE could not
# reach its own antecedent, and a deactivation timeout would have had nothing to
# time.
#
# So this is not a test of one rule. It is the stimulus three rules were waiting
# for, and it asserts what that stimulus produced:
#
#   phase 1  traffic, so the link is genuinely RUN with credits banked at both
#            ends -- a tear-down from an idle link would prove nothing about
#            draining.
#   phase 2  ask for deactivation, and require that the link reaches STOP with
#            EVERY L-credit returned. The drain is the hard part: a completer
#            that simply mirrored the withdrawn request would reach STOP two
#            cycles later with both pools still full.
#   phase 3  bring it back up and read again. A tear-down that left the link
#            unusable would be a worse outcome than never tearing it down.
#
# Phase 3 is what makes phase 2 non-trivial: it would be easy to reach STOP by
# wedging the link, and only traffic afterwards distinguishes a clean
# deactivation from a broken one.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from chi_base_test import chi_base_test

ADDR_C = 0x3D80_0000
SIZE_C = 6                      # 64 B = 4 beats on the CHI-D cut
SETTLE_C = 20
# Generous: the drain sends one flit per banked credit on three channels, and the
# default budgets are 8 apiece. This is a deadlock guard, not a timing assertion
# -- the test waits on the published flag, not on this bound.
DEACT_TIMEOUT_C = 4000

_QUIESCENT_C = "CHI_LCRD_QUIESCENT_IN_STOP"
_IDLE_C = "CHI_LINK_DEACTIVATE_WHEN_IDLE"
_LCRDV_RULES_C = (
  "CHI_REQ_LCRDV_REQUIRES_LINK",
  "CHI_RSP_LCRDV_REQUIRES_LINK",
  "CHI_DAT_LCRDV_REQUIRES_LINK",
)


class tc_chi_lasm_deactivate(chi_base_test):

  async def _wait_deactivate_done(self, want):
    """Wait on the driver's published flag, not on the sideband wires.

    The wires fall as soon as the handshake completes; the point of the exercise
    is the DRAIN that has to finish first.
    """
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
    rd.set_allow_retry(0)
    rd.set_get_response(True)
    rd.set_verbose(False)
    await rd.start(self.v_sqr.rni_sequencer)

  def _fails(self, rule):
    return (self.tb_env.rni_sva.fail_count.get(rule, 0) +
            self.tb_env.snf_sva.fail_count.get(rule, 0))

  async def run_phase(self):
    self.raise_objection()

    # -- Phase 1: ordinary traffic, so the tear-down has credits to drain. ----
    await self._one_read(ADDR_C)
    await self.wait_clocks(SETTLE_C)

    quiescent_before = self._fails(_QUIESCENT_C)

    # -- Phase 2: take the link down gracefully. -----------------------------
    self.rni_cfg.link_deactivate_request = True
    await self._wait_deactivate_done(True)
    await self.wait_clocks(SETTLE_C)

    # The credit shadow survives the link going down precisely so this can be
    # asked. If it did not, the rule would be comparing zero against zero and
    # this assertion would hold no matter how badly the drain had gone.
    quiescent_after = self._fails(_QUIESCENT_C)
    assert quiescent_after == quiescent_before, (
      f"the link reached STOP with L-credits still outstanding "
      f"({quiescent_after - quiescent_before} new report(s)); the deactivation "
      f"drain did not return them")

    # No credit may be ADVERTISED once the link is down either. This is the other
    # half of quiescence and a different bug: a receiver that kept granting into
    # STOP would refill the pool the drain had just emptied.
    lcrdv_fails = sum(self._fails(r) for r in _LCRDV_RULES_C)
    assert lcrdv_fails == 0, (
      f"{lcrdv_fails} L-credit grant(s) went out with the link down")

    # The rule that could not previously reach its own antecedent. It is not
    # asked to FAIL here -- the tear-down is a clean one -- but it must have been
    # EVALUATED, or the deactivation walked past it without being judged and this
    # whole exercise proved nothing about it.
    idle_pass = self.tb_env.rni_sva.pass_count.get(_IDLE_C, 0)
    assert idle_pass > 0, (
      f"{_IDLE_C} recorded no evaluations across a full deactivation -- it is "
      f"still vacuous")

    # -- Phase 3: bring it back and prove it still works. --------------------
    self.rni_cfg.link_deactivate_request = False
    await self._wait_deactivate_done(False)
    await self.wait_clocks(SETTLE_C)

    await self._one_read(ADDR_C + 64)
    await self.wait_clocks(SETTLE_C)

    rni, snf = self.tb_env.rni_sva, self.tb_env.snf_sva
    assert rni.errors == 0 and snf.errors == 0, (
      f"checkers reported {rni.errors} (RN-I) / {snf.errors} (SN-F) violation(s) "
      f"across a deactivation that should be entirely legal")

    self.logger.info(
      f"Test (tc_chi_lasm_deactivate) PASS: link ran, deactivated to STOP with "
      f"every L-credit returned, reactivated and carried traffic again; "
      f"{_IDLE_C} evaluated {idle_pass} time(s)")
    self.drop_objection()
