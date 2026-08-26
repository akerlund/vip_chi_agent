################################################################################
# pyUVM port of tc/chi_coh_lasm_deactivate_base_test.sv.
#
# Graceful deactivation on the COHERENT link.
#
# The RN-I to SN-F link has been able to reach STOP without a reset since
# tc_chi_lasm_deactivate; the RN-F to HN-F link could not, and three separate
# things stood in the way. None of them was visible from the requester, because
# the requester's half of the tear-down was already written:
#
#   * the home's REQ ingress had no arm for ReqLCrdReturn, so the drain's first
#     returned credit reached the opcode dispatch and stopped the simulation with
#     "unsupported REQ opcode 0x0";
#   * the home had no per-port tear-down state, so it kept advertising credits
#     into a link that was coming down and dropped its acknowledge two cycles
#     after the request fell, whatever it still held; and
#   * the requester's SNP credit loop had no stand-down, so it kept granting
#     snoop credits straight through the tear-down.
#
# The fourth channel is what makes this link different from the one that already
# worked. SNP runs home to requester, so the home holds the send credits and the
# requester grants them -- and CHI_LCRD_QUIESCENT_IN_STOP cannot see any of it,
# because the SNP rules live in their own bind so a non-coherent link elaborates
# none of them. The tear-down would have been judged on three channels of four,
# and the missing one is the channel only this link has. Hence
# CHI_SNP_LCRD_QUIESCENT_IN_STOP, and hence the pre-tear-down reading below that
# proves the home really held snoop credits to strand.
#
#   phase 1  coherent traffic that SNOOPS: port 1 reads a line port 0 holds
#            Unique, so the home has sent snoops on port 0 and spent credits from
#            all four pools. A tear-down from an idle link proves nothing about
#            draining.
#   phase 2  take port 0 down, and require STOP with every credit returned on all
#            four channels -- while port 1 stays up, because a home that could
#            only tear down by taking every port with it would pass a
#            single-port test and fail the first real one.
#   phase 3  bring port 0 back and snoop again. A tear-down that left the link
#            unusable would be a worse outcome than never tearing it down, and
#            re-granting the initial budget on the way back up is the half that
#            has no analogue in the requester's own path.
#
# Used by:
#   tc_chi_coh_d_lasm_deactivate   (CHI-D)
#   tc_chi_coh_e_lasm_deactivate   (wide CHI-E)
#
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from chi_coherent_base_test import chi_coherent_base_test

LINE_C = 0x4A00_0000
SETTLE_C = 24
# Generous: the drain sends one flit per banked credit on three channels at each
# end, and the default budgets are 8 apiece. A deadlock guard, not a timing
# assertion -- the test waits on the driver's published flag, not on this bound.
DEACT_TIMEOUT_C = 6000

_QUIESCENT_C = "CHI_LCRD_QUIESCENT_IN_STOP"
_SNP_QUIESCENT_C = "CHI_SNP_LCRD_QUIESCENT_IN_STOP"
_IDLE_C = "CHI_LINK_DEACTIVATE_WHEN_IDLE"
_SNP_LINK_C = "CHI_SNP_FLITV_REQUIRES_LINK"
_LCRDV_RULES_C = (
  "CHI_REQ_LCRDV_REQUIRES_LINK",
  "CHI_RSP_LCRDV_REQUIRES_LINK",
  "CHI_DAT_LCRDV_REQUIRES_LINK",
  "CHI_SNP_LCRDV_REQUIRES_LINK",
)


class chi_coh_lasm_deactivate_base_test(chi_coherent_base_test):

  # -- the two ends of the link under test ------------------------------------
  # Read from BOTH, always. The requester and the home each see one half of
  # quiescence -- what it holds, and what it granted that the peer still holds --
  # and a rule read at one end only cannot distinguish a clean tear-down from one
  # where the other end stranded everything.
  def _link_binds(self):
    return (self.tb_env.hrnf_sva[0], self.tb_env.hnfr_sva[0])

  def _snp_binds(self):
    return [b for b in self.tb_env.snp_sva
            if b.log.name.endswith(("hrnf0_snp_sva", "hnfr0_snp_sva"))]

  def _fails(self, binds, rule):
    return sum(b.fail_count.get(rule, 0) for b in binds)

  def _passes(self, binds, rule):
    return sum(b.pass_count.get(rule, 0) for b in binds)

  async def _wait_deactivate_done(self, want):
    """Wait on the driver's published flag, not on the sideband wires.

    The wires fall as soon as the handshake completes; the point of the exercise
    is the DRAIN that has to finish first, and on this link that drain runs at
    both ends at once.
    """
    waited = 0
    while bool(self.hrnf0_cfg.link_deactivate_done) != want:
      await self.wait_clocks(1)
      waited += 1
      assert waited <= DEACT_TIMEOUT_C, (
        f"link_deactivate_done never reached {want} within {DEACT_TIMEOUT_C} "
        f"cycles -- the coherent link is stuck mid-tear-down")

  async def _snooping_traffic(self):
    """Port 0 takes the line Unique, then port 1 reads it: the home must snoop.

    The snoop is the point. It is what puts the home's SNP send pool to work, so
    the credits the tear-down has to hand back on that channel are real rather
    than the untouched initial budget.
    """
    self.cfg_read_seq(self.hrnf0_rdunique_seq, LINE_C)
    await self.hrnf0_rdunique_seq.start(self.tb_env.hrnf0_agent.sequencer)
    self.cfg_read_seq(self.hrnf1_rdshared_seq, LINE_C)
    await self.hrnf1_rdshared_seq.start(self.tb_env.hrnf1_agent.sequencer)

  async def run_phase(self):
    self.raise_objection()
    await self.wait_reset_settle()

    hnf = self.tb_env.hnf_agent.hnf_driver
    rnf0 = self.tb_env.hrnf0_agent.rnf_driver

    # -- Phase 1: traffic, so the tear-down has credits to drain. -------------
    await self._snooping_traffic()
    await self.wait_clocks(SETTLE_C)

    snp_held_before = hnf.rn_snp_send[0].available
    snp_granted_before = rnf0.snp_lcrd_granted

    # Non-vacuity, and the reason it is asserted rather than assumed: every
    # assertion after this one is satisfied by a link that never put a snoop
    # credit anywhere. If the home holds none and the requester granted none,
    # the SNP half of the tear-down has nothing to do and its clean result means
    # nothing.
    assert snp_held_before > 0, (
      "the home holds no SNP send credits before the tear-down, so the snoop "
      "channel has nothing to drain and every SNP assertion below is vacuous")
    assert snp_granted_before > 0, (
      "the requester has granted no SNP credits before the tear-down, so its "
      "own wait for their return cannot distinguish a drain from a no-op")

    quiescent_before = self._fails(self._link_binds(), _QUIESCENT_C)
    snp_quiescent_before = self._fails(self._snp_binds(), _SNP_QUIESCENT_C)
    snp_link_before = self._fails(self._snp_binds(), _SNP_LINK_C)

    # -- Phase 2: take port 0 down gracefully, port 1 untouched. --------------
    self.hrnf0_cfg.link_deactivate_request = True
    await self._wait_deactivate_done(True)
    await self.wait_clocks(SETTLE_C)

    # The credit shadows survive the link going down precisely so these can be
    # asked. If they did not, the rules would be comparing zero against zero and
    # both assertions would hold no matter how badly the drain had gone.
    quiescent_after = self._fails(self._link_binds(), _QUIESCENT_C)
    assert quiescent_after == quiescent_before, (
      f"the coherent link reached STOP with REQ/RSP/DAT L-credits still "
      f"outstanding ({quiescent_after - quiescent_before} new report(s)); the "
      f"deactivation drain did not return them")

    snp_quiescent_after = self._fails(self._snp_binds(), _SNP_QUIESCENT_C)
    assert snp_quiescent_after == snp_quiescent_before, (
      f"the coherent link reached STOP with SNOOP L-credits still outstanding "
      f"({snp_quiescent_after - snp_quiescent_before} new report(s)); the home "
      f"holds the send credits on this channel and nothing else can hand them "
      f"back")

    # EVALUATED, not merely un-failed. The SNP rule is new and the tear-down it
    # judges is the only thing that reaches it, so a zero fail count with a zero
    # pass count would mean the rule never ran -- which is what the three
    # channels it joins looked like before a coherent link could deactivate at
    # all.
    snp_quiescent_pass = self._passes(self._snp_binds(), _SNP_QUIESCENT_C)
    assert snp_quiescent_pass > 0, (
      f"{_SNP_QUIESCENT_C} recorded no evaluations across a full coherent "
      f"deactivation -- it is still vacuous")

    # Both drains are finished at the driver's own accounting, which is the half
    # the wire cannot show: a pool emptied by dropping credits on the floor and
    # one emptied by returning them look identical from STOP.
    assert hnf.rn_snp_send[0].available == 0, (
      f"the home still holds {hnf.rn_snp_send[0].available} SNP send credit(s) "
      f"after the tear-down completed")
    assert rnf0.snp_lcrd_granted == 0, (
      f"the requester still counts {rnf0.snp_lcrd_granted} SNP credit(s) as "
      f"granted after the tear-down completed")

    # A snoop credit return is a flit sent in DEACTIVATE, which is legal for an
    # L-credit return and for nothing else. The rule admitting it is the narrow
    # exception, so it has to be checked that the exception did not swallow the
    # rule.
    snp_link_after = self._fails(self._snp_binds(), _SNP_LINK_C)
    assert snp_link_after == snp_link_before, (
      f"{snp_link_after - snp_link_before} snoop flit(s) went out with the "
      f"transmit link out of RUN and not as an L-credit return")

    # No credit may be ADVERTISED once the link is down either. The other half of
    # quiescence and a different bug: a receiver that kept granting into STOP
    # would refill the pool the drain had just emptied. SNP is in this list for
    # the first time -- it is the channel whose grant loop had no stand-down.
    lcrdv_fails = (sum(self._fails(self._link_binds(), r)
                       for r in _LCRDV_RULES_C[:3])
                   + self._fails(self._snp_binds(), _LCRDV_RULES_C[3]))
    assert lcrdv_fails == 0, (
      f"{lcrdv_fails} L-credit grant(s) went out with the link down")

    # The rule that could not previously reach its own antecedent on this link.
    # Not asked to FAIL -- the tear-down is a clean one -- but it must have been
    # EVALUATED, or the deactivation walked past it unjudged.
    idle_pass = self._passes(self._link_binds(), _IDLE_C)
    assert idle_pass > 0, (
      f"{_IDLE_C} recorded no evaluations across a full coherent deactivation "
      f"-- it is still vacuous")

    # Port 1 was never asked to go down. A home that tore down every port at
    # once would pass everything above.
    assert not hnf.rn_link_deactivating[1], (
      "taking port 0 down also put port 1 into tear-down: the home's "
      "deactivation state is not per port")

    # -- Phase 3: bring it back and prove it still snoops. --------------------
    self.hrnf0_cfg.link_deactivate_request = False
    await self._wait_deactivate_done(False)
    await self.wait_clocks(SETTLE_C)

    self.drain_observation_fifos()
    await self._snooping_traffic()
    await self.wait_clocks(SETTLE_C)

    # A snoop after the bring-up is what proves the SNP channel came back: the
    # home can only send one under a credit the requester re-granted, and the
    # re-grant is the step the requester's own tear-down path has no analogue
    # for. Read off the wire rather than from the driver, so a re-granted credit
    # that never carried a snoop does not count.
    snooped = 0
    while self.tb_env.hrnf0_snp_fifo.can_get():
      await self.tb_env.hrnf0_snp_fifo.get()
      snooped += 1
    assert snooped > 0, (
      "no snoop reached port 0 after reactivation: the SNP receive budget was "
      "never re-advertised, so the channel came back dead")

    # Named here as well as counted by the env's check_phase, because a
    # tear-down that violated something at THIS port is the failure this test
    # exists to catch and the env's total names every bind at once.
    errs = sum(b.errors for b in self._link_binds())
    snp_errs = sum(b.errors for b in self._snp_binds())
    assert errs == 0 and snp_errs == 0, (
      f"checkers reported {errs} link / {snp_errs} snoop-channel violation(s) "
      f"across a deactivation that should be entirely legal")

    self.logger.info(
      f"Test ({self.get_name()}) PASS: coherent link ran with snoops, "
      f"deactivated port 0 to STOP with all four channels' L-credits returned "
      f"({snp_held_before} snoop credit(s) drained by the home, "
      f"{snp_granted_before} tracked by the requester), reactivated and snooped "
      f"again ({snooped} snoop(s)); {_SNP_QUIESCENT_C} evaluated "
      f"{snp_quiescent_pass} time(s), {_IDLE_C} {idle_pass} time(s)")
    self.drop_objection()
