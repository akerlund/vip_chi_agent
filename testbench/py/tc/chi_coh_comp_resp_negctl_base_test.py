################################################################################
# pyUVM port of tc/chi_coh_comp_resp_negctl_base_test.sv.
#
# Negative control for CHI_RSP_COMP_RESP_LEGAL -- the Resp encodings a Comp
# response is permitted to carry, IHI 0050 E Table 4-7 / D Table 4-5.
#
# The injection is the defect this VIP actually shipped: cfg.hnf_comp_resp_negctl
# puts the home back on Comp_UD_PD for a MakeUnique completion, where the tables
# give Comp_UC.
#
# Its value as a control is that THE SAME INJECTION IS LEGAL UNDER ONE ISSUE AND
# NOT THE OTHER, and both answers are asserted:
#
#   Issue E  Table 4-7 lists Comp_UD_PD (0b110) among the four permitted
#            encodings, so the flit is well formed and the per-flit rule must
#            stay SILENT -- and must record a PASS, since a rule that declined to
#            evaluate would also be silent.
#   Issue D  Table 4-5 permits exactly Comp_I, Comp_UC and Comp_SC. It gives
#            0b110 no meaning on a Comp at all, so the rule must FIRE.
#
# A control that reported on both cuts would pass equally well against a rule
# that ignored the issue and checked E's larger set everywhere -- which would let
# the original CHI-D defect straight through. The asymmetry is the check.
#
# THE COHERENCY CHECKER REPORTS ON BOTH CUTS, and that is not collateral to be
# absorbed but the division of labour made visible. Table 4-19 gives MakeUnique
# one completion response in either issue, so the request-correlated rule objects
# wherever the encoding rule stands down. The two are asserted separately: one
# judges the flit, the other judges the flit against the request that caused it,
# and only the second can be issue-independent here.
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import Resp
from chi_coherent_base_test import chi_coherent_base_test
from chi_coherency_negctl_catcher import chi_coherency_negctl_catcher
from vip_chi_makeunique_seq import vip_chi_makeunique_seq

_SETTLE_C = 20
_RULE_C = "CHI_RSP_COMP_RESP_LEGAL"


class chi_coh_comp_resp_negctl_base_test(chi_coherent_base_test):

  # Whether this cut's dataless-completion table lists Comp_UD_PD, and therefore
  # whether the per-flit rule must fire. Overridden to False on the CHI-E cut.
  EXPECT_SVA_REPORT_C = True

  def configure_agent_cfgs(self):
    self.hnf_cfg.hnf_comp_resp_negctl = True

  # The checkers exist by connect_phase and the violating flit goes out in
  # run_phase. Declared only on the cut that actually breaks the rule: waiving it
  # where the encoding is legal would hide a rule that fired when it should not.
  def connect_phase(self):
    super().connect_phase()
    if self.EXPECT_SVA_REPORT_C:
      for sva in self.tb_env.rnf_sva:
        sva.expect_failure(_RULE_C)

  def _by_vantage(self, chk: str) -> tuple[int, int]:
    """Fail counts split by vantage, summed across ports.

    The home's RN-facing binds are the sending end, the RN-F binds the receiving
    end. Summed rather than pinned to one port: what is under test is the
    vantage, not which RN-F happened to issue the MakeUnique.
    """
    sent = recv = 0
    for sva in self.tb_env.rnf_sva:
      n = sva.fail_count.get(chk, 0)
      if "hnfr" in sva.log.name:
        sent += n
      else:
        recv += n
    return sent, recv

  def _passes(self, chk: str) -> int:
    return sum(sva.pass_count.get(chk, 0) for sva in self.tb_env.rnf_sva)

  async def run_phase(self):
    self.raise_objection()
    await self.wait_reset_settle()

    coh = self.tb_env.coh_checker
    catcher = chi_coherency_negctl_catcher("coh_comp_resp_catcher")
    coh.logger.addFilter(catcher)

    dataless_before = coh.get_bad_dataless_resp_count()

    mu_seq = vip_chi_makeunique_seq("hrnf0_mu_seq", cfg=self.chi_cfg)
    self.cfg_read_seq(mu_seq)
    await mu_seq.start(self.tb_env.hrnf0_agent.sequencer)
    mu_rsp = mu_seq.get_responses()

    await self.wait_clocks(_SETTLE_C)

    coh.logger.removeFilter(catcher)

    assert len(mu_rsp) == 1, (
      f"MakeUnique returned {len(mu_rsp)} completions, expected 1 -- the flit "
      f"this control corrupts may never have been sent")

    # The knob did what it says, read off the completion the requester received.
    assert int(mu_rsp[0].rsp_resp) == int(Resp.UD_PD), (
      f"the completion carried Resp 0x{int(mu_rsp[0].rsp_resp):x}, not the "
      f"injected Comp_UD_PD (0x{int(Resp.UD_PD):x}) -- the control is not "
      f"reaching the home")

    sent, recv = self._by_vantage(_RULE_C)
    passes = self._passes(_RULE_C)

    if self.EXPECT_SVA_REPORT_C:
      # Both vantages, because which end of a link sees a completion depends on
      # where the bind sits: a rule that fires only where the flit was sent does
      # not catch a third-party completer.
      assert sent == 1 and recv == 1, (
        f"Comp_UD_PD on a CHI-D completion was reported {sent} time(s) at the "
        f"sending end and {recv} at the receiving end, expected exactly 1 at "
        f"each -- D Table 4-5 gives that encoding no meaning on a Comp")
    else:
      assert sent == 0 and recv == 0, (
        f"the rule reported {sent}/{recv} time(s) on a cut where E Table 4-7 "
        f"LISTS Comp_UD_PD: it is reading a fixed set rather than the issue's "
        f"own table")
      # Silence is not enough on this cut -- a rule that never evaluated is
      # silent too, and would pass the assertion above while letting the CHI-D
      # half of the rule rot unnoticed.
      assert passes > 0, (
        "the rule recorded no passes on a completion it should have judged and "
        "accepted -- it may not have evaluated at all")

    # The request-correlated rule objects on BOTH cuts, because Table 4-19 gives
    # MakeUnique one completion response in either issue. Asserted rather than
    # absorbed: it is what shows the encoding rule and the row rule are judging
    # different things about the same flit.
    assert coh.get_bad_dataless_resp_count() > dataless_before, (
      "the coherency checker did not object to Comp_UD_PD on a MakeUnique, "
      "which Table 4-19 forbids in both issues")
    assert catcher.saw_coherency_error, "no coherency violation was reported at all"

    self.logger.info(
      f"Test (coh_comp_resp_negctl) PASS: Comp_UD_PD on a MakeUnique -- the "
      f"encoding rule reported {sent}/{recv} "
      f"(expected {'1/1' if self.EXPECT_SVA_REPORT_C else '0/0'}) over {passes} "
      f"pass(es), and the row rule objected on both cuts")
    self.drop_objection()
