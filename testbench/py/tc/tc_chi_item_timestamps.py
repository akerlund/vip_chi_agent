################################################################################
# pyUVM/cocotb port of tc/tc_chi_item_timestamps.sv.
#
# Per-transaction timestamps on the observed item. The monitor stamps each
# milestone from its reset-gated free-running cycle counter, so a consumer of
# the analysis stream can ask what a single transaction cost instead of reading
# one aggregate number at the end of the run.
#
# What this pins down:
#   * the milestones are populated at all, and 0 still means "not reached";
#   * they are MONOTONIC -- a request cannot be granted before it was issued,
#     nor its last beat arrive before its first;
#   * latency() agrees with the perf counters' independently-derived aggregate.
#     Two measurements of the same interval that disagree mean one of them is
#     wrong, and that is exactly what a single aggregate number cannot reveal.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import DatOpcode
from chi_base_test import chi_base_test

_ADDR_C = 0x3D00_0000
_SIZE_C = 6                     # 64 B = 4 beats on the CHI-D cut


class tc_chi_item_timestamps(chi_base_test):

  async def run_phase(self):
    self.raise_objection()

    # -- A write, then a read of the same line. --------------------------------
    wr = self.rni0_wr_seq
    wr.reset()
    wr.set_requests(1)
    wr.set_initial_addr(_ADDR_C)
    wr.set_size(_SIZE_C)
    wr.set_get_response(True)
    wr.set_verbose(False)
    await wr.start(self.v_sqr.rni_sequencer)

    rd = self.rni0_rd_seq
    rd.reset()
    rd.set_requests(1)
    rd.set_initial_addr(_ADDR_C)
    rd.set_size(_SIZE_C)
    rd.set_get_response(True)
    rd.set_verbose(False)
    await rd.start(self.v_sqr.rni_sequencer)

    await self.wait_clocks(20)

    # The timestamps ride the monitor's analysis stream, so they are read off
    # the observed items rather than off the driver's response object.
    read_dat = None
    while self.tb_env.rni_dat_fifo.can_get():
      it = await self.tb_env.rni_dat_fifo.get()
      if int(it.dat_opcode) == int(DatOpcode.COMP_DATA):
        read_dat = it
    assert read_dat is not None, "no CompData was observed for the read"

    # -- Milestones present. ---------------------------------------------------
    assert read_dat.t_req_issued > 0, (
      "t_req_issued is 0 on an observed read -- the REQ milestone was never "
      "stamped, or the stamp did not travel to the completion item")
    assert read_dat.t_first_dat > 0 and read_dat.t_last_dat > 0, (
      f"data milestones missing: t_first_dat={read_dat.t_first_dat} "
      f"t_last_dat={read_dat.t_last_dat}")

    # -- Monotonic. ------------------------------------------------------------
    assert read_dat.t_req_issued <= read_dat.t_first_dat, (
      f"read data arrived at cycle {read_dat.t_first_dat}, before its request "
      f"was issued at {read_dat.t_req_issued}")
    assert read_dat.t_first_dat <= read_dat.t_last_dat, (
      f"read burst ended at {read_dat.t_last_dat}, before it began at "
      f"{read_dat.t_first_dat}")

    # -- Accessors self-consistent. -------------------------------------------
    assert read_dat.latency() > 0, "read latency() returned 0 on a completed read"
    assert read_dat.data_burst_time() == (read_dat.t_last_dat - read_dat.t_first_dat), (
      "data_burst_time() disagrees with the beat milestones it is derived from")

    # -- Cross-check against the perf counters. -------------------------------
    # Both measure the same interval from the same cycle base but by entirely
    # separate paths, so agreement is real evidence and disagreement localizes
    # the bug to one of them.
    perf = self.tb_env.perf
    assert perf.get_read_count() == 1, (
      f"expected exactly 1 completed read for the cross-check, perf counted "
      f"{perf.get_read_count()}")
    perf_read_lat = perf.get_read_lat_sum()
    assert read_dat.latency() == perf_read_lat, (
      f"item latency() = {read_dat.latency()} but the perf counters measured "
      f"{perf_read_lat} for the same read -- the two cycle bases disagree")

    self.logger.info(
      f"Test (tc_chi_item_timestamps) PASS: req={read_dat.t_req_issued} "
      f"first_dat={read_dat.t_first_dat} last_dat={read_dat.t_last_dat} "
      f"latency={read_dat.latency()} burst={read_dat.data_burst_time()} "
      f"(perf agrees at {perf_read_lat})")
    self.drop_objection()
