################################################################################
# pyUVM port of tc/chi_coh_make_unique_dct_base_test.sv.
#
# Same as the make_unique scenario but with DCT snoop forwarding enabled, so the
# read-after-MakeUnique is served via a forwarding snoop of RN-F1's freshly-made
# (all-zero materialized) line. Reuses the make_unique body verbatim.
################################################################################

from __future__ import annotations

from chi_coh_make_unique_base_test import chi_coh_make_unique_base_test


class chi_coh_make_unique_dct_base_test(chi_coh_make_unique_base_test):

  def configure_agent_cfgs(self):
    self.hnf_cfg.hnf_enable_snoop_fwd = True

  async def run_phase(self):
    """The inherited assertions do not distinguish the two paths.

    They require RN-F0 to read the defined all-zero image, and it reads that
    image whether the home forwarded it from RN-F1 or fetched it the ordinary
    way -- so a home whose DCT gate fell back to the normal dirty-snoop path
    would satisfy every one of them while never originating a forwarding snoop.
    Enabling a knob is not evidence that the knob was used.

    n_snp_fwd_judged is the evidence: the coherency checker counts a forwarding
    snoop only where it has correlated one to its causing request and checked the
    forwarded names against it, so a rise here says a fwd snoop went out AND that
    its FwdNID/FwdTxnID named the requester's read. The mismatch count is
    asserted beside it because judged-without-mismatch is the claim, not judged
    alone.
    """
    coh = self.tb_env.coh_checker
    fwd_judged_before = coh.get_snp_fwd_judged_count()

    await super().run_phase()

    fwd_judged_after = coh.get_snp_fwd_judged_count()
    assert fwd_judged_after > fwd_judged_before, (
      f"no forwarding snoop was judged ({fwd_judged_before} -> "
      f"{fwd_judged_after}) with hnf_enable_snoop_fwd set, so the read was "
      f"served by the ordinary snoop path and this testcase proved only what "
      f"its non-DCT parent already proves")
    assert coh.get_snp_fwd_mismatch_count() == 0, (
      f"{coh.get_snp_fwd_mismatch_count()} forwarding snoop(s) named a "
      f"requester or transaction that did not match the request they answer")
