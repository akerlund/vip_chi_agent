################################################################################
# pyUVM/cocotb port of tc/chi_coh_snp_field_negctl_base_test.sv.
#
# Negative control for the three per-opcode SNP field rules:
# CHI_SNP_FWD_FIELDS_ZERO, CHI_SNP_RET_TO_SRC_LEGAL and
# CHI_SNP_DO_NOT_GO_TO_SD_LEGAL. All three landed as regression guards with
# hundreds of passes and no way to make them fail, and a rule nobody has seen
# fail is a rule nobody has tested.
#
# One snoop provokes all three, which is not a shortcut -- SnpCleanInvalid is in
# all three of the specification's sets at once:
#
#   * it is not a Forward type, so FwdNID must be zero (E 13.10.5 / 13.10.16)
#   * it is named in E 4.9 / D 4.9's RetToSrc must-be-zero list
#   * it is named in E 13.10.35's DoNotGoToSD must-be-one list
#
# A CleanInvalid from RN-F0, on a line RN-F1 holds Shared, makes the home send
# exactly that snoop. The three cfg knobs each corrupt one field of it and each
# fires once per port, so every rule sees exactly one violation.
#
# Three corruptions on one flit would normally be what this file's siblings warn
# against -- a control that breaks two rules at once cannot show which of them is
# being exercised. What makes it sound here is that the three are different
# FIELDS judged by different rules, and the test closes by requiring that NO
# other check recorded a failure. That is a stronger statement than three
# separate single-field tests would each make.
#
# Both vantages are asserted. The SNP checker is bound to both ends of every
# coherent link, so the home's copy of the rule (judging what it SENT) and the
# snoopee's (judging what it RECEIVED) must both report -- one end reporting
# while the other stays quiet would mean a rule that only works in one
# direction, which against a real DUT is the difference between catching its
# snoop and generating one.
#
# CHI-E only, and that is the point rather than a limitation: D 12.9.32 has no
# DoNotGoToSD must-be-one list, so under Issue D the cleared bit is CONFORMANT
# and the rule is right to stay quiet -- there is nothing to provoke.
#
# Used by:
#   tc_chi_coh_e_snp_field_negctl  (wide CHI-E)
################################################################################

from __future__ import annotations

from chi_coherent_base_test import chi_coherent_base_test
from vip_chi_types_pkg import CHECK_IDS_SNP
from vip_chi_cleaninvalid_seq import vip_chi_cleaninvalid_seq

_PROVOKED_C = (
  "CHI_SNP_FWD_FIELDS_ZERO",
  "CHI_SNP_RET_TO_SRC_LEGAL",
  "CHI_SNP_DO_NOT_GO_TO_SD_LEGAL",
)
_SETTLE_C = 20


class chi_coh_snp_field_negctl_base_test(chi_coherent_base_test):

  def configure_agent_cfgs(self):
    self.hnf_cfg.hnf_snp_fwd_fields_negctl = True
    self.hnf_cfg.hnf_snp_ret_to_src_negctl = True
    self.hnf_cfg.hnf_snp_do_not_go_to_sd_negctl = True

  # The checkers exist by connect_phase and the violating flit goes out in
  # run_phase, so this is early enough to declare the waivers and late enough for
  # the checkers to be there.
  def connect_phase(self):
    super().connect_phase()
    for sva in self.tb_env.snp_sva:
      for chk in _PROVOKED_C:
        sva.expect_failure(chk)

  def _sent_and_received(self, chk: str) -> tuple[int, int]:
    """Fail counts split by vantage, summed across ports.

    The snoop goes to whichever port holds the line, so the counts are summed
    rather than pinned to one: what is under test is the vantage, not which RN-F
    happened to be the snoopee. The home's RN-facing binds are the sending end,
    the RN-F binds the receiving end.
    """
    sent = recv = 0
    for sva in self.tb_env.snp_sva:
      n = sva.fail_count.get(chk, 0)
      if "hnfr" in sva.log.name:
        sent += n
      else:
        recv += n
    return sent, recv

  async def run_phase(self):
    self.raise_objection()
    await self.wait_reset_settle()

    # RN-F1 takes the line Shared so the CleanInvalid has somebody to snoop.
    self.cfg_read_seq(self.hrnf1_rdshared_seq)
    await self.hrnf1_rdshared_seq.start(self.tb_env.hrnf1_agent.sequencer)
    self.hrnf1_rdshared_seq.get_responses()

    ci_seq = vip_chi_cleaninvalid_seq("hrnf0_ci_seq", cfg=self.chi_cfg)
    self.cfg_read_seq(ci_seq)
    await ci_seq.start(self.tb_env.hrnf0_agent.sequencer)
    ci_rsp = ci_seq.get_responses()

    await self.wait_clocks(_SETTLE_C)

    assert len(ci_rsp) == 1, (
      f"CleanInvalid returned {len(ci_rsp)} completions, expected 1 -- the "
      "snoop this control needs may not have been sent")

    for chk in _PROVOKED_C:
      sent, recv = self._sent_and_received(chk)
      assert sent == 1, (
        f"{chk} reported {sent} time(s) at the sending end, expected exactly 1")
      assert recv == 1, (
        f"{chk} reported {recv} time(s) at the receiving end, expected exactly "
        "1 -- a rule that fires only where the flit was sent does not catch a "
        "DUT's snoop")
      self.logger.info(f"{chk} provoked once at each vantage")

    # Nothing else may have failed. This is what keeps three corruptions on one
    # flit an honest control.
    for sva in self.tb_env.snp_sva:
      for chk in CHECK_IDS_SNP:
        if chk in _PROVOKED_C:
          continue
        assert sva.fail_count.get(chk, 0) == 0, (
          f"{chk} also failed on {sva.log.name}: this control is exercising "
          "more than the three field rules it is about")

    self.logger.info(
      "Test PASS: one SnpCleanInvalid with three corrupted fields provoked "
      "exactly three rules, at both vantages")
    self.drop_objection()
