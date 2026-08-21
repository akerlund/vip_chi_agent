################################################################################
# pyUVM/cocotb port of tc/tc_chi_d_qos_echo.sv.
#
# The SN-F must echo the full QoS on both completion legs: the write CompDBIDResp
# (RSP) and the read CompData (DAT).
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from chi_base_test import chi_base_test
from chi_tb_pkg import WRITE_READ_ADDR_C

QOS_C = 0xA


class tc_chi_d_qos_echo(chi_base_test):

  async def run_phase(self):
    self.raise_objection()

    wr = self.rni0_wr_seq
    wr.reset()
    wr.set_requests(1)
    wr.set_initial_addr(WRITE_READ_ADDR_C)
    wr.set_size(6)
    wr.set_qos(QOS_C)
    wr.set_get_response(True)
    wr.set_verbose(False)
    await wr.start(self.v_sqr.rni_sequencer)

    rd = self.rni0_rd_seq
    rd.reset()
    rd.set_requests(1)
    rd.set_initial_addr(WRITE_READ_ADDR_C)
    rd.set_size(6)
    rd.set_qos(QOS_C)
    rd.set_get_response(True)
    rd.set_verbose(False)
    await rd.start(self.v_sqr.rni_sequencer)

    write_responses = wr.get_responses()
    read_responses = rd.get_responses()
    assert len(write_responses) == 1 and len(read_responses) == 1

    assert int(write_responses[0].qos) == QOS_C, \
      f"write completion QoS 0x{int(write_responses[0].qos):x} != 0x{QOS_C:x}"
    assert int(read_responses[0].qos) == QOS_C, \
      f"read completion QoS 0x{int(read_responses[0].qos):x} != 0x{QOS_C:x}"

    self.logger.info("Test (tc_chi_d_qos_echo) PASS")
    self.drop_objection()
