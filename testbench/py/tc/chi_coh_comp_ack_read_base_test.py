################################################################################
# pyUVM port of tc/chi_coh_comp_ack_read_base_test.sv.
#
# The read half of CompAck, and the ordering guarantee it buys.
#
# IHI 0050 E Table 2-9 / D Table 2-8 mark ReadClean, ReadShared, ReadUnique and
# MakeReadUnique "Yes" in the RN-F column, and section 2.8.3 says the same thing
# in prose: "An RN-F must include a CompAck response in all Read transactions
# except ReadNoSnp and ReadOnce*." Until Table 2-9 was implemented, this VIP's
# item constraint forced ExpCompAck to zero on EVERY read, so no coherent read it
# ever issued was conformant, and the acknowledgement -- along with the ordering
# guarantee that is its entire purpose -- was absent from the model.
#
# Two things are asserted, and the second is the one worth having:
#
#   1. The read opened and closed a CompAck window. Opened means the request
#      carried ExpCompAck and its CompData arrived; closed means the CompAck
#      itself was seen on the wire.
#
#   2. A LATER read of the same line, from the other RN-F, snooped this one --
#      and that snoop landed outside the window. This is section 2.8.3 rule 2,
#      judged from the wire by catalogue rule D9.
#
# The second assertion needs the first: if no window ever opened, "no snoop
# inside a window" is true of a run in which nothing was ever checked.
################################################################################

from __future__ import annotations

from chi_coherent_base_test import chi_coherent_base_test

_SETTLE_C = 20


class chi_coh_comp_ack_read_base_test(chi_coherent_base_test):

  async def _drain_snoops(self):
    while self.tb_env.hrnf0_snp_fifo.can_get():
      await self.tb_env.hrnf0_snp_fifo.get()

  async def run_phase(self):
    self.raise_objection()
    await self.wait_reset_settle()

    # ---- RN-F0 takes the line Shared. Table 2-9: CompAck required. ----
    self.cfg_read_seq(self.hrnf0_rdshared_seq)
    await self.hrnf0_rdshared_seq.start(self.tb_env.hrnf0_agent.sequencer)
    self.hrnf0_rdshared_seq.get_responses()

    await self.wait_clocks(_SETTLE_C)

    windows_after_first = self.tb_env.coh_checker.get_comp_ack_window_count()
    assert windows_after_first > 0, (
      "the ReadShared opened no CompAck window: either ExpCompAck was not set on "
      "a request Table 2-9 marks required, or its completion was never observed")
    assert self.tb_env.coh_checker.get_comp_ack_window_unclosed_count() == 0, (
      "a CompAck window was still open when the next one opened -- the RN-F did "
      "not send the CompAck section 2.8.3 requires after CompData")

    await self._drain_snoops()

    # ---- RN-F1 reads the same line Unique, which forces a snoop of RN-F0. ----
    snoops_before = self.tb_env.coh_checker.get_snoop_count()

    self.cfg_read_seq(self.hrnf1_rdunique_seq)
    await self.hrnf1_rdunique_seq.start(self.tb_env.hrnf1_agent.sequencer)
    self.hrnf1_rdunique_seq.get_responses()

    await self.wait_clocks(_SETTLE_C)

    # The snoop has to have happened, or the ordering assertion below is a
    # statement about a run with no snoop in it.
    assert self.tb_env.hrnf0_snp_fifo.can_get(), (
      "RN-F1's ReadUnique did not snoop RN-F0, so this run says nothing about "
      "where a snoop may fall")
    await self.tb_env.hrnf0_snp_fifo.get()

    assert self.tb_env.coh_checker.get_snoop_count() > snoops_before, \
      "the coherency checker observed no snoop, so rule D9 had nothing to judge"

    in_window = self.tb_env.coh_checker.get_comp_ack_window_snoop_count()
    assert in_window == 0, (
      f"{in_window} snoop(s) arrived inside a CompAck window; section 2.8.3 "
      f"requires the home to wait for CompAck before snooping the same address")

    assert self.tb_env.coh_checker.get_comp_ack_window_count() > windows_after_first, \
      "RN-F1's ReadUnique opened no CompAck window of its own; Table 2-9 marks " \
      "it required too"

    self.logger.info(
      f"Test (coh_comp_ack_read) PASS: "
      f"{self.tb_env.coh_checker.get_comp_ack_window_count()} CompAck windows "
      f"opened and closed, and the snoop that followed fell outside every one")
    self.drop_objection()
