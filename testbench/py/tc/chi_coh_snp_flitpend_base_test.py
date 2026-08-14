################################################################################
# pyUVM port of tc/chi_coh_snp_flitpend_base_test.sv.
#
# Negative control for CHI_SNP_PEND_REQUIRES_VALID, the last rule in the registry
# that no test could reach.
#
# The SNP twin of tc_chi_flitpend_without_valid, and it exists for the same
# reason: nothing ever raised SNP FLITPEND, because the home pairs it with the
# snoop it belongs to. A rule that has never once been evaluated is
# indistinguishable from a rule that does not work, and a clean regression that
# contains one is quietly reporting less than it appears to.
#
# It is a separate test from the REQ/RSP one because the SNP channel only exists
# on a coherent link: the requester-side control has no SNP to pulse, and this
# one has no requester.
#
# cfg.flitpend_without_valid makes the home raise SNP FLITPEND for one cycle,
# once per RN link, with the link up and before any snoop. Both halves are
# asserted by the single "exactly one" bound:
#   * fewer than one means the rule never fired and is still vacuous;
#   * more than one means it fired on something other than the deliberate pulse,
#     and the snooped traffic that follows is there to give it the chance.
#
# Note the home drives SNP FLITPEND LOW on its real snoops, so this rule takes no
# passes from them. That is worth stating rather than leaving to be discovered:
# its only evaluation in the whole regression is this control, so the vacuity
# report lists it as exercised-but-THIN, which is the honest description. Making
# the home assert FLITPEND with each snoop would change every coherent waveform,
# and unlike the DAT channel there is no burst for a "more beats coming" hint to
# mean anything about.
#
# The expected failure is declared per RULE rather than by waiving the checker: a
# test whose whole purpose is to prove one rule fires must not also be blind to a
# second, unintended violation riding along with it.
################################################################################

from __future__ import annotations

from chi_coherent_base_test import chi_coherent_base_test

_RULE_C = "CHI_SNP_PEND_REQUIRES_VALID"
SETTLE_C = 40


class chi_coh_snp_flitpend_base_test(chi_coherent_base_test):

  def configure_agent_cfgs(self):
    self.hnf_cfg.flitpend_without_valid = True

  def connect_phase(self):
    super().connect_phase()
    # Every SNP bind: the home pulses once per link, and both ends of each link
    # observe the same wire.
    for checker in self.tb_env.snp_sva:
      checker.expect_failure(_RULE_C)

  async def run_phase(self):
    self.raise_objection()
    await self.wait_reset_settle()

    # Coherent traffic that actually snoops: RN-F0 takes the line Unique, then
    # RN-F1 reads it, which forces the home to snoop RN-F0. Its job here is to
    # put real snoops on the wire AFTER the malformed pulse, so the "exactly one"
    # bound below has something that could break it. It also proves the pulse
    # left the link usable rather than wedged.
    self.cfg_read_seq(self.hrnf0_rdunique_seq)
    await self.hrnf0_rdunique_seq.start(self.tb_env.hrnf0_agent.sequencer)
    self.hrnf0_rdunique_seq.get_responses()
    self.cfg_read_seq(self.hrnf1_rdshared_seq)
    await self.hrnf1_rdshared_seq.start(self.tb_env.hrnf1_agent.sequencer)
    self.hrnf1_rdshared_seq.get_responses()

    await self.wait_clocks(SETTLE_C)

    # One lone FLITPEND per link, so exactly one report per SNP bind that saw it.
    # Fewer means the rule never fired and is still vacuous; more means it fired
    # on something other than the deliberate pulse.
    fired = [c for c in self.tb_env.snp_sva if c.fail_count.get(_RULE_C, 0)]
    assert fired, (
      f"{_RULE_C} reported nothing on any SNP bind against a deliberate lone "
      f"FLITPEND -- the rule is still vacuous")
    for checker in fired:
      n = checker.fail_count.get(_RULE_C, 0)
      assert n == 1, (
        f"{_RULE_C} reported {n} time(s) on {checker.log.name} against exactly "
        f"one lone SNP FLITPEND; it is firing on something other than the pulse")

    # The deliberate failures are demoted, so nothing else may have fired.
    total = sum(c.errors for c in self.tb_env.snp_sva)
    assert total == 0, (
      f"SNP checkers reported {total} unexpected violation(s) beyond the "
      f"declared {_RULE_C}")

    self.logger.info(
      f"Test (coh_snp_flitpend) PASS: one lone SNP FLITPEND was reported exactly "
      f"once on each of {len(fired)} bind(s); the snooped coherent traffic that "
      f"followed completed and added no further report")
    self.drop_objection()
