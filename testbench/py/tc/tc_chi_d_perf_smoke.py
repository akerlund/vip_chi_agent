################################################################################
# pyUVM/cocotb port of tc/tc_chi_d_perf_smoke.sv.
#
# Anti-vacuity guard for the always-on vip_chi_perf_counters component. Drives a
# write then a read through the integrated RN-I/SN-F path with perf enabled, then
# fails unless the perf component actually observed traffic and its deterministic
# time source ticked: read/write completion counts, per-class latency sums, and
# the cycle counter must all be non-zero. This proves the perf component is wired
# to the monitor stream and its clock loop is running.
# Runs under: testbench/py/tb/vip_chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import DataType
from vip_chi_base_test import vip_chi_base_test, WRITE_READ_ADDR_C


class tc_chi_d_perf_smoke(vip_chi_base_test):

  # Perf counters default on; make the dependency explicit for this test.
  def configure_tb_cfg(self):
    self.tb_cfg.perf_enable = True

  async def run_phase(self):
    self.raise_objection()

    wr = self.rni0_wr_seq
    wr.reset()
    wr.set_requests(1)
    wr.set_initial_addr(WRITE_READ_ADDR_C)
    wr.set_size(6)
    wr.set_allow_retry(0)
    wr.set_data_type(DataType.COUNTER)
    wr.set_counter_value(0x90)
    wr.set_counter_increment(0x1)
    wr.set_get_response(True)
    wr.set_verbose(False)
    await wr.start(self.v_sqr.rni_sequencer)

    rd = self.rni0_rd_seq
    rd.reset()
    rd.set_requests(1)
    rd.set_initial_addr(WRITE_READ_ADDR_C)
    rd.set_size(6)
    rd.set_allow_retry(0)
    rd.set_get_response(True)
    rd.set_verbose(False)
    await rd.start(self.v_sqr.rni_sequencer)

    write_responses = wr.get_responses()
    read_responses = rd.get_responses()
    assert len(write_responses) == 1 and len(read_responses) == 1, \
      f"Expected 1 write + 1 read response, got {len(write_responses)}/{len(read_responses)}"

    # Let the perf clock loop advance a few cycles past the last completion.
    await self.wait_clocks(8)

    perf = self.tb_env.perf
    assert perf.get_cycle_count() != 0, \
      "Perf cycle counter never ticked (time source dead)"
    assert perf.get_read_count() != 0, \
      "Perf observed 0 read completions"
    assert perf.get_write_count() != 0, \
      "Perf observed 0 write completions"
    assert perf.get_read_lat_sum() != 0, \
      "Perf read latency sum is zero (latency path not measuring)"
    assert perf.get_write_lat_sum() != 0, \
      "Perf write latency sum is zero (latency path not measuring)"

    self.logger.info(
      "Test (tc_chi_d_perf_smoke) PASS: perf counters observed non-vacuous "
      "read+write traffic and a live cycle base")
    self.drop_objection()
