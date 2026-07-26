################################################################################
# pyUVM/cocotb port of tc/tc_chi_d_multi_outstanding.sv.
#
# Launch N pipelined ReadNoSnp requests through the opt-in multi-outstanding
# datapath (RN-I decoupled issue/completion + buffered SN-F), confirm each
# returns its own address-derived 4-beat payload, and confirm the reads actually
# overlapped in flight (observed_peak_outstanding > 1).
# Runs under: testbench/py/tb/vip_chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import Role, DatOpcode
from vip_chi_base_test import vip_chi_base_test

N_READS_C = 6
MO_BASE_ADDR_C = 0x2200_0000
READ_SIZE_C = 6      # 64 bytes => 4 beats at 16 bytes/beat (CHI-D)
BEATS_C = 4


class tc_chi_d_multi_outstanding(vip_chi_base_test):

  def configure(self, rni_cfg, snf_cfg):
    rni_cfg.multi_outstanding = True
    rni_cfg.max_outstanding_read = N_READS_C
    snf_cfg.multi_outstanding = True

  async def run_phase(self):
    self.raise_objection()

    rd = self.rni0_rd_seq
    rd.reset()
    rd.set_requests(N_READS_C)
    rd.set_initial_addr(MO_BASE_ADDR_C)
    rd.set_size(READ_SIZE_C)
    rd.set_allow_retry(0)
    rd.set_get_response(True)
    rd.set_pipelined_send(True)
    rd.set_verbose(False)
    await rd.start(self.v_sqr.rni_sequencer)

    responses = rd.get_responses()
    assert len(responses) == N_READS_C, \
      f"expected {N_READS_C} read responses, got {len(responses)}"

    for k, rsp in enumerate(responses):
      assert int(rsp.role) == int(Role.SNF), \
        f"read {k} response carried wrong role {int(rsp.role)}"
      assert int(rsp.dat_opcode) == int(DatOpcode.COMP_DATA), \
        f"read {k} response carried wrong DAT opcode 0x{int(rsp.dat_opcode):x}"
      assert len(rsp.data) == BEATS_C, \
        f"read {k} response carried {len(rsp.data)} beats instead of {BEATS_C}"
      # Each response self-describes its request address, so the payload check
      # holds regardless of the order responses are collected in.
      for i in range(len(rsp.data)):
        expected = (int(rsp.addr) + i) & ((1 << (self.chi_cfg.data_bytes * 8)) - 1)
        assert int(rsp.data[i]) == expected, \
          f"read {k} beat {i} payload 0x{int(rsp.data[i]):x} (addr 0x{int(rsp.addr):x})"

    peak = self.rni_cfg.observed_peak_outstanding
    assert peak > 1, f"reads did not overlap: peak in-flight was {peak} (expected > 1)"

    self.logger.info(
      f"Test (tc_chi_d_multi_outstanding) PASS: {N_READS_C} pipelined reads, "
      f"peak in-flight = {peak}")
    self.drop_objection()
