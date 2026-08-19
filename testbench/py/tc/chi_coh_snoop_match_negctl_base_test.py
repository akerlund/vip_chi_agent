################################################################################
# pyUVM port of tc/chi_coh_snoop_match_negctl_base_test.sv.
#
# Negative control for chi_coh_read_clean_snoop_base_test. The home is put back
# on the pre-Table-4-5 snoop choice for ReadClean with
# cfg.hnf_snoop_shared_for_read_clean: one is_unique bit, so a ReadClean is
# snooped as though it were a ReadShared.
#
# The knob is worth having because it produces one LEGAL snoop and one ILLEGAL
# one from the same line of code, which is the distinction catalogue rule D8 has
# to draw and the reason the rule is not simply "the snoop must equal the
# Expected column":
#
#   DCT off:  ReadClean -> SnpShared     PERMITTED. The bullet under Table 4-5
#                                        names SnpShared for ReadClean outright.
#                                        D8 must stay SILENT here.
#   DCT on:   ReadClean -> SnpSharedFwd  NOT permitted. The forwarding bullet
#                                        gives ReadClean SnpNotSharedDirtyFwd or
#                                        SnpCleanFwd only. D8 MUST fire.
#
# A control that only drove the second half would pass just as well against a
# checker that rejected every SnpShared it saw, which would false-fail every
# ReadShared in the regression. Driving both halves is what shows the rule is the
# table and not an approximation of it.
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import SnpOpcode
from chi_coherent_base_test import chi_coherent_base_test
from chi_coherency_negctl_catcher import chi_coherency_negctl_catcher
from vip_chi_readclean_seq import vip_chi_readclean_seq


class chi_coh_snoop_match_negctl_base_test(chi_coherent_base_test):

  # Put the home back on the is_unique bit for ReadClean.
  def configure_agent_cfgs(self):
    self.hnf_cfg.hnf_snoop_shared_for_read_clean = True

  async def _drain_snoops(self):
    while self.tb_env.hrnf0_snp_fifo.can_get():
      await self.tb_env.hrnf0_snp_fifo.get()

  async def run_phase(self):
    self.raise_objection()
    await self.wait_reset_settle()

    catcher = chi_coherency_negctl_catcher("coh_violation_catcher")
    self.tb_env.coh_checker.logger.addFilter(catcher)

    # ---- The legal half. DCT off, so the knob yields SnpShared. ----
    self.cfg_read_seq(self.hrnf0_rdunique_seq)
    await self.hrnf0_rdunique_seq.start(self.tb_env.hrnf0_agent.sequencer)
    self.hrnf0_rdunique_seq.get_responses()

    await self._drain_snoops()

    rc_seq = vip_chi_readclean_seq("hrnf1_rdclean_seq", cfg=self.chi_cfg)
    self.cfg_read_seq(rc_seq)
    await rc_seq.start(self.tb_env.hrnf1_agent.sequencer)
    rc_seq.get_responses()

    await self.wait_clocks(8)

    # The knob did what it says. Asserted so a future change that quietly stops
    # honouring it turns into a failure here rather than a negative control that
    # silently tests nothing.
    assert self.tb_env.hrnf0_snp_fifo.can_get(), \
      "RN-F0 observed no snoop for the non-forwarded ReadClean"
    snp_item = await self.tb_env.hrnf0_snp_fifo.get()
    assert int(snp_item.snp_opcode) == int(SnpOpcode.SHARED), \
      f"expected the knob's SnpShared, got snp_opcode 0x{int(snp_item.snp_opcode):x}"

    mismatch_after_legal_half = self.tb_env.coh_checker.get_snp_req_mismatch_count()
    assert mismatch_after_legal_half == 0, \
      f"D8 reported {mismatch_after_legal_half} mismatches for SnpShared on a " \
      f"ReadClean, which the bullet under Table 4-5 permits -- the rule is " \
      f"stricter than the spec"

    # ---- The illegal half. DCT on, so the same knob yields SnpSharedFwd. ----
    self.hnf_cfg.hnf_enable_snoop_fwd = True

    self.cfg_read_seq(self.hrnf0_rdunique_seq)
    await self.hrnf0_rdunique_seq.start(self.tb_env.hrnf0_agent.sequencer)
    self.hrnf0_rdunique_seq.get_responses()

    await self._drain_snoops()

    rc2_seq = vip_chi_readclean_seq("hrnf1_rdclean_fwd_seq", cfg=self.chi_cfg)
    self.cfg_read_seq(rc2_seq)
    await rc2_seq.start(self.tb_env.hrnf1_agent.sequencer)
    rc2_seq.get_responses()

    await self.wait_clocks(8)

    assert self.tb_env.hrnf0_snp_fifo.can_get(), \
      "RN-F0 observed no snoop for the forwarded ReadClean"
    snp_item = await self.tb_env.hrnf0_snp_fifo.get()
    assert int(snp_item.snp_opcode) == int(SnpOpcode.SHARED_FWD), \
      f"expected the knob's SnpSharedFwd, got snp_opcode 0x{int(snp_item.snp_opcode):x}"

    self.tb_env.coh_checker.logger.removeFilter(catcher)

    assert catcher.saw_coherency_error, \
      "Checker D did NOT flag SnpSharedFwd on a ReadClean -- catalogue rule D8 " \
      "may be vacuous"
    assert self.tb_env.coh_checker.get_snp_req_mismatch_count() > \
      mismatch_after_legal_half, \
      "D8 reported no snoop/request mismatch, so the coherency error above came " \
      "from a different rule"

    self.logger.info(
      "Test (coh_snoop_match_negctl) PASS: Checker D flagged SnpSharedFwd on a "
      "ReadClean and stayed silent on the SnpShared the spec permits")
    self.drop_objection()
