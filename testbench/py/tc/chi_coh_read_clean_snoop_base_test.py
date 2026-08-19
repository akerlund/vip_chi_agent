################################################################################
# pyUVM port of tc/chi_coh_read_clean_snoop_base_test.sv.
#
# The snoop a Home sends must be one IHI 0050 E Table 4-5 / D Table 4-3 permits
# for the request that caused it. Directed positive test for the ReadClean row,
# on both of its paths.
#
# The table gives ReadClean SnpCleanFwd as the expected snoop and SnpClean as the
# alternative. The bullet list under the table then widens the row twice, and
# asymmetrically -- which is why this test drives both paths:
#
#   "Use SnpNotSharedDirty or SnpShared or SnpClean for ReadNotSharedDirty,
#    ReadShared and ReadClean transactions."
#   "Use SnpNotSharedDirtyFwd or SnpCleanFwd for ReadNotSharedDirty and ReadClean
#    transactions."
#
# SnpShared is permitted for a ReadClean. SnpSharedFwd is not, and no other
# bullet reaches it. The asymmetry is not editorial: Table 4-34 permits a UD or
# SD snoopee answering SnpSharedFwd to forward CompData_SD_PD, and Table 4-14's
# ReadClean rows permit final SC or UC and nothing else -- so SnpSharedFwd for a
# ReadClean can put the requester in a state its own request forbids, with no
# individual flit being illegal.
#
# Before Table 4-5 was modeled the home chose its snoop from a single is_unique
# bit, so both paths sent SnpShared / SnpSharedFwd: ReadClean was snooped as
# though it were a ReadShared. The regression could not see it -- no test drove
# ReadClean on the DCT path at all, and the transition covergroup's snoop bins
# were drawn from the set of opcodes the home DID send.
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import SnpOpcode
from chi_coherent_base_test import chi_coherent_base_test
from vip_chi_readclean_seq import vip_chi_readclean_seq


class chi_coh_read_clean_snoop_base_test(chi_coherent_base_test):

  async def _drain_snoops(self):
    while self.tb_env.hrnf0_snp_fifo.can_get():
      await self.tb_env.hrnf0_snp_fifo.get()

  async def _sole_snoop_opcode(self, what):
    """The single snoop RN-F0 observed. More than one would make the opcode
    assertion ambiguous about which one it read."""
    assert self.tb_env.hrnf0_snp_fifo.can_get(), \
      f"RN-F0 observed no snoop for the {what}"
    snp_item = await self.tb_env.hrnf0_snp_fifo.get()
    assert not self.tb_env.hrnf0_snp_fifo.can_get(), \
      f"RN-F0 observed more than one snoop for the {what}"
    return int(snp_item.snp_opcode)

  async def run_phase(self):
    self.raise_objection()
    await self.wait_reset_settle()

    judged_before = self.tb_env.coh_checker.get_snp_req_judged_count()

    # ---- Path 1: no DCT. RN-F0 takes the line Unique, RN-F1 ReadCleans it. ----
    self.cfg_read_seq(self.hrnf0_rdunique_seq)
    await self.hrnf0_rdunique_seq.start(self.tb_env.hrnf0_agent.sequencer)
    self.hrnf0_rdunique_seq.get_responses()

    # RN-F0 was Invalid, so its ReadUnique snooped nobody; drain anything the
    # fifo picked up so the ReadClean's snoop is the only entry in it.
    await self._drain_snoops()

    rc_seq = vip_chi_readclean_seq("hrnf1_rdclean_seq", cfg=self.chi_cfg)
    self.cfg_read_seq(rc_seq)
    await rc_seq.start(self.tb_env.hrnf1_agent.sequencer)
    rc_seq.get_responses()

    await self.wait_clocks(8)

    got = await self._sole_snoop_opcode("non-forwarded ReadClean")
    assert got == int(SnpOpcode.CLEAN), \
      f"ReadClean snooped with 0x{got:x}, expected SnpClean " \
      f"(0x{int(SnpOpcode.CLEAN):x}) -- Table 4-5 gives ReadClean SnpClean, not " \
      f"the SnpShared (0x{int(SnpOpcode.SHARED):x}) an is_unique bit produces"

    # ---- Path 2: DCT. The home forwards from the single holder. ----
    self.hnf_cfg.hnf_enable_snoop_fwd = True

    # RN-F0 re-acquires Unique (this invalidates RN-F1, leaving RN-F0 the sole
    # holder again so the next ReadClean qualifies for the forwarding path).
    self.cfg_read_seq(self.hrnf0_rdunique_seq)
    await self.hrnf0_rdunique_seq.start(self.tb_env.hrnf0_agent.sequencer)
    self.hrnf0_rdunique_seq.get_responses()

    await self._drain_snoops()

    rc2_seq = vip_chi_readclean_seq("hrnf1_rdclean_fwd_seq", cfg=self.chi_cfg)
    self.cfg_read_seq(rc2_seq)
    await rc2_seq.start(self.tb_env.hrnf1_agent.sequencer)
    rc2_seq.get_responses()

    await self.wait_clocks(8)

    got = await self._sole_snoop_opcode("forwarded ReadClean")
    assert got == int(SnpOpcode.CLEAN_FWD), \
      f"forwarded ReadClean snooped with 0x{got:x}, expected SnpCleanFwd " \
      f"(0x{int(SnpOpcode.CLEAN_FWD):x}) -- SnpSharedFwd " \
      f"(0x{int(SnpOpcode.SHARED_FWD):x}) is permitted for ReadShared and for " \
      f"nothing else"

    # Catalogue rule D8 must have had something to judge. Without this the two
    # opcode assertions above could both pass while the checker's correlation
    # silently found no cause for any snoop and judged nothing at all.
    assert self.tb_env.coh_checker.get_snp_req_judged_count() > judged_before, \
      f"catalogue rule D8 judged no snoop against its request " \
      f"(judged {self.tb_env.coh_checker.get_snp_req_judged_count()}, was " \
      f"{judged_before}) -- the request/snoop correlation is not working"
    assert self.tb_env.coh_checker.get_snp_req_mismatch_count() == 0, \
      "catalogue rule D8 reported snoop/request mismatches on conformant stimulus"

    self.logger.info("Test (coh_read_clean_snoop) PASS")
    self.drop_objection()
