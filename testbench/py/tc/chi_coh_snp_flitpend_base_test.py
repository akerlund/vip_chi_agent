################################################################################
# pyUVM port of tc/chi_coh_snp_flitpend_base_test.sv.
#
# POSITIVE control for CHI_SNP_VALID_REQUIRES_PEND: legal traffic the rule must
# NOT report, on the one channel that only exists on a coherent link.
#
# The SNP twin of tc_chi_flitpend_without_valid, and inverted for the same
# reason. E section 14.4 / D section 13.4 permit a transmitter to "assert and
# then deassert this signal without sending a flit", so the home's lone SNP
# FLITPEND pulse is legal and owes nothing. The rule this test was written for
# ran the obligation backwards and reported that pulse as a violation; the
# corrected rule runs it from the flit backwards, so the same stimulus is now
# evidence the rule does not reject legal traffic.
#
# It is a separate test from the REQ/RSP one because the SNP channel only exists
# on a coherent link: the requester-side control has no SNP to pulse, and this
# one has no requester.
#
# cfg.flitpend_without_valid makes the home raise SNP FLITPEND for one cycle,
# once per RN link, with the link up and before any snoop. Both halves are
# asserted:
#   * no SNP bind may report -- the pulse is permitted;
#   * the snoops that follow must be judged, or a checker that never ran would
#     satisfy the first half just as well.
#
# The second half is now reachable, and it was not before. The home used to drive
# SNP FLITPEND low on its real snoops, so this rule took no passes from them and
# its only evaluation in the whole regression was this control -- exercised, but
# THIN. Every snoop is now announced one cycle ahead like any other flit, so the
# rule is judged on ordinary coherent traffic and the THIN listing goes away.
################################################################################

from __future__ import annotations

from chi_coherent_base_test import chi_coherent_base_test

_RULE_C = "CHI_SNP_VALID_REQUIRES_PEND"
SETTLE_C = 40


class chi_coh_snp_flitpend_base_test(chi_coherent_base_test):

  def configure_agent_cfgs(self):
    self.hnf_cfg.flitpend_without_valid = True

  async def run_phase(self):
    self.raise_objection()
    await self.wait_reset_settle()

    # Coherent traffic that actually snoops: RN-F0 takes the line Unique, then
    # RN-F1 reads it, which forces the home to snoop RN-F0. Its job here is to
    # put real snoops on the wire after the pulse, so the rule has well-formed
    # SNP flits to pass. It also proves the pulse left the link usable rather
    # than wedged.
    self.cfg_read_seq(self.hrnf0_rdunique_seq)
    await self.hrnf0_rdunique_seq.start(self.tb_env.hrnf0_agent.sequencer)
    self.hrnf0_rdunique_seq.get_responses()
    self.cfg_read_seq(self.hrnf1_rdshared_seq)
    await self.hrnf1_rdshared_seq.start(self.tb_env.hrnf1_agent.sequencer)
    self.hrnf1_rdshared_seq.get_responses()

    await self.wait_clocks(SETTLE_C)

    # The pulse is permitted, so no bind may report it.
    for checker in self.tb_env.snp_sva:
      n = checker.fail_count.get(_RULE_C, 0)
      assert n == 0, (
        f"{_RULE_C} reported {n} time(s) on {checker.log.name} against a "
        f"FLITPEND pulse that E section 14.4 explicitly permits")

    # ...and the snoops that followed have to have been judged, or a checker
    # that never ran would satisfy the loop above just as well.
    judged = [c for c in self.tb_env.snp_sva if c.pass_count.get(_RULE_C, 0)]
    assert judged, (
      f"{_RULE_C} recorded no passes on any SNP bind, so this run says nothing "
      f"about the rule holding on the snoops the coherent traffic drove")

    # Nothing else may have fired either.
    total = sum(c.errors for c in self.tb_env.snp_sva)
    assert total == 0, (
      f"SNP checkers reported {total} unexpected violation(s)")

    self.logger.info(
      f"Test (coh_snp_flitpend) PASS: a lone SNP FLITPEND was not reported, and "
      f"the snoops that followed were judged on {len(judged)} bind(s)")
    self.drop_objection()
