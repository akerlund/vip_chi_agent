################################################################################
# pyUVM/cocotb port of tc/tc_chi_d_write_partial_smoke.sv.
#
# WriteNoSnpPtl with a byte-enable mask then a readback: the SN-F commits only
# the enabled bytes, so the read returns the byte-masked payload.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import Role, ReqOpcode, RspOpcode, DatOpcode
from chi_base_test import chi_base_test
from chi_tb_pkg import WRITE_ADDR_C

WRITE_DATA = 0x0011_2233_4455_6677_8899_AABB_CCDD_EEFF
WRITE_BE = 0b1111_0000_0011_0101


def _expected_partial(data, be, data_bytes):
  result = 0
  for byte_index in range(data_bytes):
    if (be >> byte_index) & 1:
      result |= ((data >> (8 * byte_index)) & 0xFF) << (8 * byte_index)
  return result


class tc_chi_d_write_partial_smoke(chi_base_test):

  async def run_phase(self):
    self.raise_objection()
    expected = _expected_partial(WRITE_DATA, WRITE_BE, self.chi_cfg.data_bytes)

    wr = self.rni0_wr_seq
    wr.reset()
    wr.set_initial_addr(WRITE_ADDR_C)
    wr.set_size(4)
    wr.set_data([WRITE_DATA])
    wr.set_be([WRITE_BE])
    wr.set_get_response(True)
    wr.set_verbose(False)
    await wr.start(self.v_sqr.rni_sequencer)

    rd = self.rni0_rd_seq
    rd.reset()
    rd.set_requests(1)
    rd.set_initial_addr(WRITE_ADDR_C)
    rd.set_size(4)
    rd.set_get_response(True)
    rd.set_verbose(False)
    await rd.start(self.v_sqr.rni_sequencer)

    write_responses = wr.get_responses()
    read_responses = rd.get_responses()
    assert len(write_responses) == 1 and len(read_responses) == 1

    req_items = [await self.tb_env.rni_req_fifo.get() for _ in range(2)]
    dat_items = [await self.tb_env.rni_dat_fifo.get() for _ in range(2)]

    assert int(req_items[0].opcode) == int(ReqOpcode.WRITE_NO_SNP_PTL)
    assert int(req_items[1].opcode) == int(ReqOpcode.READ_NO_SNP)
    assert int(req_items[0].addr) == WRITE_ADDR_C
    assert int(req_items[1].addr) == WRITE_ADDR_C
    assert int(dat_items[0].role) == int(Role.RNI)
    assert int(dat_items[1].role) == int(Role.SNF)
    assert len(dat_items[0].data) == 1 and len(dat_items[1].data) == 1
    assert int(dat_items[0].be[0]) == WRITE_BE
    assert int(dat_items[0].data[0]) == WRITE_DATA
    assert int(write_responses[0].rsp_opcode) == int(RspOpcode.COMP_DBID_RESP)
    assert int(read_responses[0].dat_opcode) == int(DatOpcode.COMP_DATA)
    assert int(dat_items[1].data[0]) == expected
    assert int(read_responses[0].data[0]) == expected

    self.logger.info("Test (tc_chi_d_write_partial_smoke) PASS")
    self.drop_objection()
