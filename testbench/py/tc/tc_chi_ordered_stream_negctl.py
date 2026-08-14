################################################################################
# pyUVM/cocotb port of tc/tc_chi_ordered_stream_negctl.sv.
#
# Negative control for the scoreboard's ordered-stream check. With
# cfg.snf_reorder_ordered_service the buffered SN-F serves one pair of queued
# ordered requests back to front, so its acknowledgements come back in the wrong
# order. Nothing else about the traffic is wrong: every request is still
# answered, with the right opcode, the right data and the right TxnID, so no
# other checker in the bench can see the fault. If the ordering check does not
# fire here, it is a no-op everywhere.
#
# The inversion is one-shot, so the expected count is exactly one: a check that
# fired on every subsequent transaction would be cascading rather than
# pinpointing, and this asserts on the precise number.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import ReqOrder
from chi_base_test import chi_base_test
from chi_order_negctl_catcher import chi_order_negctl_catcher

N_C = 6
BASE_ADDR_C = 0x3C00_0000
SIZE_C = 6                      # 64 B = 4 beats on the CHI-D cut
SETTLE_C = 20


class tc_chi_ordered_stream_negctl(chi_base_test):

  # multi_outstanding on both ends is what gives the SN-F two queued requests to
  # invert in the first place.
  def configure(self, rni_cfg, snf_cfg):
    rni_cfg.multi_outstanding = True
    rni_cfg.max_outstanding_read = N_C
    snf_cfg.multi_outstanding = True
    snf_cfg.snf_reorder_ordered_service = True

  async def run_phase(self):
    self.raise_objection()

    # The ordering error below is induced on purpose, so it is demoted rather
    # than left in the log to read as a real failure. The catcher is what proves
    # it happened; the counter alone would not distinguish "flagged once" from
    # "flagged for a different reason".
    sb = self.tb_env.scoreboard
    catcher = chi_order_negctl_catcher("order_negctl_catcher")
    sb.logger.addFilter(catcher)

    try:
      rd = self.rni0_rd_seq
      rd.reset()
      rd.set_requests(N_C)
      rd.set_initial_addr(BASE_ADDR_C)
      rd.set_size(SIZE_C)
      rd.set_order(int(ReqOrder.REQ_ORDER))
      rd.set_allow_retry(0)
      rd.set_get_response(True)
      rd.set_pipelined_send(True)
      rd.set_verbose(False)
      await rd.start(self.v_sqr.rni_sequencer)

      peak = self.rni_cfg.observed_peak_outstanding
      rd_rsp = rd.get_responses()

      await self.wait_clocks(SETTLE_C)
    finally:
      # A failed assertion below must not leave the filter installed on a logger
      # that outlives this test.
      sb.logger.removeFilter(catcher)

    # Every read must still have completed: the injected fault is an ordering
    # fault only, and a test that also broke completion would no longer isolate
    # the check under examination.
    assert len(rd_rsp) == N_C, (
      f"expected {N_C} read responses, got {len(rd_rsp)} -- the reorder knob was "
      f"meant to change the order, not lose a transaction")
    assert peak > 1, (
      f"reads did not overlap: peak in-flight was {peak}, so the completer never "
      f"held two requests to invert")

    assert catcher.saw_order_error, (
      "scoreboard did NOT flag the inverted acknowledgement order -- the "
      "ordered-stream check may be vacuous")
    assert sb.get_order_violation_count() == 1, (
      f"ordered-stream check reported {sb.get_order_violation_count()} "
      f"violations for one injected inversion, expected exactly 1 -- it is "
      f"cascading rather than pinpointing")

    # The rest of the stream must still have been compared and found in order,
    # which is what shows the check recovers from an inversion instead of
    # derailing on it.
    assert sb.get_order_checked_count() >= N_C - 1, (
      f"only {sb.get_order_checked_count()} acknowledgements were compared in "
      f"order after the inversion, expected at least {N_C - 1}")

    self.logger.info(
      f"Test (tc_chi_ordered_stream_negctl) PASS: inverted acknowledgement "
      f"flagged exactly once; {sb.get_order_checked_count()} further "
      f"acknowledgements compared in order")
    self.drop_objection()
