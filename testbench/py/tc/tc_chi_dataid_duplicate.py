################################################################################
# pyUVM/cocotb port of tc/tc_chi_dataid_duplicate.sv.
#
# Negative control for the monitor's DataID placement checks. With
# cfg.snf_duplicate_dat_beat the SN-F sends the final beat of a read burst
# carrying DataID 0 again instead of its own position, so one position is
# delivered twice and the last position never at all. Both checks must fire:
# reassembly by arrival order cannot see either fault, because the beat count
# still adds up and every slot still gets written.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from chi_base_test import chi_base_test
from chi_dataid_negctl_catcher import chi_dataid_negctl_catcher
from chi_tb_pkg import READ_ADDR_C

BEATS_C = 4     # size 6 = 64 bytes over a 16-byte CHI-D data bus


class tc_chi_dataid_duplicate(chi_base_test):

  def configure(self, rni_cfg, snf_cfg):
    snf_cfg.snf_duplicate_dat_beat = True

  def configure_tb_cfg(self):
    # The malformed burst is not a data-integrity failure to report twice: the
    # DataID checks own this scenario, so keep the scoreboard's payload check out
    # of the verdict. Everything else about the transfer stays checked.
    self.tb_cfg.scoreboard_check_data = False
    # Same reasoning for the protocol checkers' DataID-ordering rules: the
    # repeated position makes the burst 0,1,2,0, which those rules correctly
    # call non-sequential. They hold this VIP's in-order emission convention and
    # own a different question from the one under test here -- stand them down
    # and let the monitor's duplicate / missing-beat checks judge this burst.
    self.tb_cfg.dat_reorder_allowed = True

  async def run_phase(self):
    self.raise_objection()

    # The two errors below are induced on purpose, so they are demoted rather
    # than left in the log to read as real failures. The catcher is what proves
    # they happened: asserting on the monitor's counter alone would pass on two
    # duplicate reports and never notice the missing-beat check had gone
    # silent. The burst crosses the link, so both endpoints see both faults.
    catcher = chi_dataid_negctl_catcher("dataid_negctl_catcher")
    monitors = (self.tb_env.rni_agent.monitor, self.tb_env.snf_agent.monitor)
    for mon in monitors:
      mon.logger.addFilter(catcher)

    try:
      rd = self.rni0_rd_seq
      rd.reset()
      rd.set_requests(1)
      rd.set_initial_addr(READ_ADDR_C)
      rd.set_size(6)
      rd.set_get_response(True)
      rd.set_verbose(False)
      await rd.start(self.v_sqr.rni_sequencer)

      dat_item = await self.tb_env.rni_dat_fifo.get()
      await self.wait_clocks(8)
    finally:
      # A failed assertion below must not leave the filter installed on a
      # logger that outlives this test.
      for mon in monitors:
        mon.logger.removeFilter(catcher)

    assert len(dat_item.data) == BEATS_C, (
      f"monitor reassembled {len(dat_item.data)} beats, expected {BEATS_C}")

    # Two distinct faults from the one malformed burst, each with its own check:
    # DataID 0 arrived twice, and no beat ever carried the last position.
    assert catcher.saw_duplicate_error, (
      "monitor did NOT flag the repeated DataID -- the duplicate check may be "
      "vacuous")
    assert catcher.saw_missing_error, (
      "monitor did NOT flag the position no beat carried -- the missing-beat "
      "check may be vacuous")
    assert self.tb_env.rni_agent.monitor.n_dataid_violation >= 2, (
      "the requester's DataID violation counter did not move with the reports")

    self.logger.info(
      "Test (tc_chi_dataid_duplicate) PASS: monitor flagged both the "
      "duplicated and the missing DataID")
    self.drop_objection()
