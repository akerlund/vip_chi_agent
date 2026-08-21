################################################################################
# pyUVM/cocotb port of tc/tc_chi_ordered_stream.sv.
#
# Ordered-stream acknowledgement order, the positive case. A source that sets the
# REQ Order field is asking the completer for a guarantee, and the completer must
# acknowledge the requests in the order it received them. This pipelines an
# ordered write stream and an ordered read stream deep enough that the completer
# holds several at once -- which is the only condition under which it could get
# the order wrong -- and requires the scoreboard to have compared every one of
# them and found none out of place.
#
# The in-order tally is asserted, not just the violation count: a run where the
# check never got to compare anything would otherwise look identical to a clean
# one. tc_chi_ordered_stream_negctl is the other half, proving the same check
# does fire when the completer answers out of order.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import ReqOrder
from chi_base_test import chi_base_test

N_C = 6
BASE_ADDR_C = 0x3B00_0000
SIZE_C = 6                      # 64 B = 4 beats on the CHI-D cut
SETTLE_C = 20


class tc_chi_ordered_stream(chi_base_test):

  # Both ends have to overlap for the stream to have any depth: the RN-I must
  # keep several requests in flight and the SN-F must buffer them rather than
  # servicing each to completion before sampling the next.
  def configure(self, rni_cfg, snf_cfg):
    rni_cfg.multi_outstanding = True
    rni_cfg.multi_outstanding_write = True
    rni_cfg.max_outstanding_read = N_C
    rni_cfg.max_outstanding_write = N_C
    snf_cfg.multi_outstanding = True

  async def run_phase(self):
    self.raise_objection()

    # An ordered write stream: each write is acknowledged by its DBIDResp /
    # CompDBIDResp, which is the flit the completer commits a position in.
    wr = self.rni0_wr_seq
    wr.reset()
    wr.set_requests(N_C)
    wr.set_initial_addr(BASE_ADDR_C)
    wr.set_size(SIZE_C)
    wr.set_order(int(ReqOrder.REQ_ORDER))
    wr.set_exp_comp_ack(1)
    wr.set_get_response(True)
    wr.set_pipelined_send(True)
    wr.set_verbose(False)
    await wr.start(self.v_sqr.rni_sequencer)

    wr_peak = self.rni_cfg.observed_peak_outstanding

    await self.wait_clocks(SETTLE_C)

    # An ordered read stream: each read is acknowledged by its ReadReceipt, which
    # arrives on RSP ahead of the CompData burst on DAT.
    rd = self.rni0_rd_seq
    rd.reset()
    rd.set_requests(N_C)
    rd.set_initial_addr(BASE_ADDR_C)
    rd.set_size(SIZE_C)
    rd.set_order(int(ReqOrder.REQ_ORDER))
    rd.set_get_response(True)
    rd.set_pipelined_send(True)
    rd.set_verbose(False)
    await rd.start(self.v_sqr.rni_sequencer)

    rd_peak = self.rni_cfg.observed_peak_outstanding

    await self.wait_clocks(SETTLE_C)

    # A stream one deep can never be out of order, so a run that never overlapped
    # proves nothing about the completer and must not be read as a pass.
    assert wr_peak > 1 and rd_peak > 1, (
      f"ordered streams did not overlap: peak in-flight was {wr_peak} (writes) / "
      f"{rd_peak} (reads), expected > 1 for both")

    sb = self.tb_env.scoreboard
    acks = sb.get_order_checked_count()

    assert acks >= 2 * N_C, (
      f"ordered-stream check compared only {acks} acknowledgements, expected at "
      f"least {2 * N_C} -- the check did not see this traffic")
    assert sb.get_order_violation_count() == 0, (
      f"ordered-stream check reported {sb.get_order_violation_count()} "
      f"out-of-order acknowledgement(s) on a completer that serves requests "
      f"first-come-first-served")

    self.logger.info(
      f"Test (tc_chi_ordered_stream) PASS: {N_C} ordered writes + {N_C} ordered "
      f"reads acknowledged in order ({acks} compared; peak in-flight "
      f"{wr_peak} / {rd_peak})")
    self.drop_objection()
