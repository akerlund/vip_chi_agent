################################################################################
# pyUVM port of tc/chi_coh_fwd_target_negctl_base_test.sv.
#
# Negative control for the FwdNID/FwdTxnID VALUE rule, the half of IHI 0050 E
# 2.5 that needs the request a snoop was sent for.
#
# The SNP channel bind judges the other half from the flit alone: both fields are
# inapplicable and must be zero on any snoop that is not one of the six
# forwarding forms. On the six that ARE, it passes any value at all, because a
# link-layer checker cannot know which requester the home meant to name. The
# coherency checker can -- it already correlates a snoop to its cause by line for
# catalogue rule D8 -- so the positive half is judged there:
#
#   FwdNID   must be the Node ID of the original Requester
#   FwdTxnID must be the TxnID of the original Request
#
# cfg.hnf_snp_fwd_target_negctl adds one to each field on the first forwarding
# snoop the home sends to a port. One added rather than a constant substituted:
# every requester on this bench drives SrcID zero, so a constant zero would
# corrupt nothing and a constant one would stop corrupting the day a test gives
# them real Node IDs. Off by one is wrong whatever the right answer is.
#
# Both halves are asserted, and the conformant half is the one that matters most
# here. A rule that only ever fired on the injection would be satisfied by a
# checker that rejected EVERY forwarding snoop -- which would false-fail the
# three DCT tests in this regression. So the first phase asserts the rule
# RECORDED A PASS on a conformant forward, not merely that it stayed silent.
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import snp_opcode_is_forwarding
from chi_coherent_base_test import chi_coherent_base_test
from chi_coherency_negctl_catcher import chi_coherency_negctl_catcher


class chi_coh_fwd_target_negctl_base_test(chi_coherent_base_test):

  # The second phase corrupts TWO forwarding snoops and each is TWO reports, and
  # the decomposition is the point rather than a number to tune. The injection
  # latch is per port, and by the second phase RN-F1 is holding the line from the
  # first, so both directions forward:
  #
  #   RN-F0 ReadUnique  -> SnpUniqueFwd to RN-F1   (RN-F1 held it)
  #   RN-F1 ReadShared  -> SnpSharedFwd to RN-F0   (RN-F0 now holds it)
  #
  # and the rule judges FwdNID and FwdTxnID separately, so the message can say
  # which half broke. Two snoops, two fields each. A drop means an arm stopped
  # evaluating or a latch stopped firing; a rise means the traffic changed shape.
  CORRUPT_REPORTS = 4
  CORRUPT_FORWARDS = 2

  # DCT origination on, injection OFF: the first phase must be conformant.
  def configure_agent_cfgs(self):
    self.hnf_cfg.hnf_enable_snoop_fwd = True

  async def _drain_snoops(self):
    while self.tb_env.hrnf0_snp_fifo.can_get():
      await self.tb_env.hrnf0_snp_fifo.get()

  # One RN-F0 ReadUnique to take the line, then one RN-F1 ReadShared the home
  # serves by forwarding from RN-F0. The pair is run twice, so it is a method.
  async def _drive_one_forward(self):
    self.cfg_read_seq(self.hrnf0_rdunique_seq)
    await self.hrnf0_rdunique_seq.start(self.tb_env.hrnf0_agent.sequencer)
    self.hrnf0_rdunique_seq.get_responses()

    await self._drain_snoops()

    self.cfg_read_seq(self.hrnf1_rdshared_seq)
    await self.hrnf1_rdshared_seq.start(self.tb_env.hrnf1_agent.sequencer)
    self.hrnf1_rdshared_seq.get_responses()

    await self.wait_clocks(8)

  async def run_phase(self):
    self.raise_objection()
    await self.wait_reset_settle()

    catcher = chi_coherency_negctl_catcher("coh_violation_catcher")
    self.tb_env.coh_checker.logger.addFilter(catcher)

    # ---- The conformant half. A real forward, correctly addressed. ----
    await self._drive_one_forward()

    judged_clean = self.tb_env.coh_checker.get_snp_fwd_judged_count()
    mismatch_clean = self.tb_env.coh_checker.get_snp_fwd_mismatch_count()

    # The rule EVALUATED, and that is the assertion this phase exists for: a
    # silent rule and a passing rule read the same in a mismatch count.
    assert judged_clean >= 1, \
      f"the checker judged {judged_clean} forwarding snoop(s) on a run that " \
      f"sent one -- the FwdNID/FwdTxnID rule may never have been reached"
    assert mismatch_clean == 0, \
      f"the checker reported {mismatch_clean} FwdNID/FwdTxnID violation(s) on a " \
      f"correctly addressed forward -- the rule is stricter than IHI 0050 E 2.5"

    # ---- The corrupted half. Same traffic, mis-addressed forward. ----
    self.hnf_cfg.hnf_snp_fwd_target_negctl = True

    await self._drive_one_forward()

    # The knob did what it says. Asserted against the observed flit so a future
    # change that quietly stops honouring it turns into a failure here rather
    # than a negative control that silently tests nothing.
    assert self.tb_env.hrnf0_snp_fifo.can_get(), \
      "RN-F0 observed no snoop for the second forwarding read"
    snp_item = await self.tb_env.hrnf0_snp_fifo.get()
    assert snp_opcode_is_forwarding(int(snp_item.snp_opcode)), \
      f"the second read was not served by a forwarding snoop (snp_opcode " \
      f"0x{int(snp_item.snp_opcode):x}), so the injection had nothing to corrupt"

    self.tb_env.coh_checker.logger.removeFilter(catcher)

    judged_dirty = self.tb_env.coh_checker.get_snp_fwd_judged_count()
    mismatch_dirty = self.tb_env.coh_checker.get_snp_fwd_mismatch_count()

    assert catcher.saw_coherency_error, \
      "Checker D did NOT flag a mis-addressed forwarding snoop -- the " \
      "FwdNID/FwdTxnID rule may be vacuous"
    assert (judged_dirty - judged_clean) == self.CORRUPT_FORWARDS, \
      f"the second phase produced {judged_dirty - judged_clean} judged " \
      f"forwarding snoop(s), expected exactly {self.CORRUPT_FORWARDS}: the " \
      f"report count below is read against that shape and means nothing without it"

    # Checked EXACTLY, not as a floor: drift either way means the injection or
    # the rule changed shape and wants reading, not absorbing.
    assert (mismatch_dirty - mismatch_clean) == self.CORRUPT_REPORTS, \
      f"the mis-addressed forwards produced {mismatch_dirty - mismatch_clean} " \
      f"report(s), expected exactly {self.CORRUPT_REPORTS} " \
      f"({self.CORRUPT_FORWARDS} corrupted forwards, FwdNID and FwdTxnID judged " \
      f"separately on each)"

    self.logger.info(
      f"Test (coh_fwd_target_negctl) PASS: a correctly addressed forward passed "
      f"the rule, and the mis-addressed ones were reported "
      f"{mismatch_dirty - mismatch_clean} time(s) over {judged_dirty} judged "
      f"forwards")
    self.drop_objection()
