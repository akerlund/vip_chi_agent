################################################################################
# pyUVM/cocotb port of tc/tc_chi_d_hni_decerr.sv.
#
# A write + readback to a DECERR-configured SN-F address through the proxy: the
# HN-I must relay the SN-F's NDERR completion (RSP resp_err on both the write and
# read, and per-beat dat_resp_err on the read) verbatim back to the RN-I.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import RespErr, DataType
from chi_hni_base_test import chi_hni_base_test
from chi_tb_pkg import DECERR_ADDR_C


class tc_chi_d_hni_decerr(chi_hni_base_test):

  def configure(self):
    self.hsnf0_cfg.add_decerr_range(DECERR_ADDR_C, DECERR_ADDR_C + 0x3F)

  async def run_phase(self):
    self.raise_objection()

    wr = self.rni0_wr_seq
    wr.reset()
    wr.set_requests(1)
    wr.set_initial_addr(DECERR_ADDR_C)
    wr.set_size(6)
    wr.set_allow_retry(0)
    wr.set_data_type(DataType.COUNTER)
    wr.set_counter_value(0x40)
    wr.set_get_response(True)
    wr.set_verbose(False)
    await wr.start(self.v_sqr.hrni0_sequencer)

    rd = self.rni0_rd_seq
    rd.reset()
    rd.set_requests(1)
    rd.set_initial_addr(DECERR_ADDR_C)
    rd.set_size(6)
    rd.set_allow_retry(0)
    rd.set_get_response(True)
    rd.set_verbose(False)
    await rd.start(self.v_sqr.hrni0_sequencer)

    write_responses = wr.get_responses()
    read_responses = rd.get_responses()
    assert len(write_responses) == 1 and len(read_responses) == 1

    assert int(write_responses[0].rsp_resp_err) == int(RespErr.NDERR), \
      f"proxied write DECERR response was 0x{int(write_responses[0].rsp_resp_err):x}, not NDERR"
    assert int(read_responses[0].rsp_resp_err) == int(RespErr.NDERR), \
      f"proxied read DECERR response was 0x{int(read_responses[0].rsp_resp_err):x}, not NDERR"
    for i, e in enumerate(read_responses[0].dat_resp_err):
      assert int(e) == int(RespErr.NDERR), \
        f"proxied read DECERR dat_resp_err[{i}] was 0x{int(e):x}, not NDERR"

    self.logger.info(
      "Test (tc_chi_d_hni_decerr) PASS: HN-I relayed SN-F DECERR responses "
      "(write + read) intact")
    self.drop_objection()
