################################################################################
# pyUVM/cocotb port of tc/tc_chi_e_hni_passthrough.sv.
#
# Drive a wide-CHI-E write then a readback through the HN-I proxy and confirm it
# relayed both end-to-end: the RN-I sees correct completions, SN-F 0 actually
# observed the forwarded requests, and the readback payload matches. At
# CHI_E_WIDE_CFG (DATA_BYTES = 64) a Size-6 (64 B) access is a single wide DAT
# beat, so the CompData carries exactly one beat.
# Runs under: testbench/py/tb/vip_chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import ReqOpcode, RspOpcode, DatOpcode, DataType
from vip_chi_e_hni_base_test import vip_chi_e_hni_base_test
from vip_chi_tb_pkg import E_HNI_WRITE_READ_ADDR_C


class tc_chi_e_hni_passthrough(vip_chi_e_hni_base_test):

  async def run_phase(self):
    self.raise_objection()

    wr = self.hrni0_wr_seq
    wr.reset()
    wr.set_requests(1)
    wr.set_initial_addr(E_HNI_WRITE_READ_ADDR_C)
    wr.set_size(6)
    wr.set_allow_retry(0)
    wr.set_data_type(DataType.COUNTER)
    wr.set_counter_value(0xB0)
    wr.set_counter_increment(0x1)
    wr.set_get_response(True)
    wr.set_verbose(False)
    await wr.start(self.tb_env.hrni0_agent.sequencer)

    rd = self.hrni0_rd_seq
    rd.reset()
    rd.set_requests(1)
    rd.set_initial_addr(E_HNI_WRITE_READ_ADDR_C)
    rd.set_size(6)
    rd.set_allow_retry(0)
    rd.set_get_response(True)
    rd.set_verbose(False)
    await rd.start(self.tb_env.hrni0_agent.sequencer)

    write_responses = wr.get_responses()
    read_responses = rd.get_responses()
    assert len(write_responses) == 1, \
      f"expected 1 write response through the CHI-E proxy, got {len(write_responses)}"
    assert len(read_responses) == 1, \
      f"expected 1 read response through the CHI-E proxy, got {len(read_responses)}"

    # SN-F 0 sits on the far side of the proxy, so its monitor only observes
    # traffic the HN-I actually forwarded. Both requests must appear there.
    snf_reqs = [await self.tb_env.hsnf0_req_fifo.get() for _ in range(2)]
    assert int(snf_reqs[0].opcode) == int(ReqOpcode.WRITE_NO_SNP_FULL), \
      f"SN-F did not receive the forwarded WriteNoSnpFull: 0x{int(snf_reqs[0].opcode):x}"
    assert int(snf_reqs[1].opcode) == int(ReqOpcode.READ_NO_SNP), \
      f"SN-F did not receive the forwarded ReadNoSnp: 0x{int(snf_reqs[1].opcode):x}"
    assert int(snf_reqs[0].addr) == E_HNI_WRITE_READ_ADDR_C and \
      int(snf_reqs[1].addr) == E_HNI_WRITE_READ_ADDR_C, \
      f"forwarded request address mismatch 0x{int(snf_reqs[0].addr):x} " \
      f"0x{int(snf_reqs[1].addr):x}"

    assert int(write_responses[0].rsp_opcode) == int(RspOpcode.COMP_DBID_RESP), \
      f"proxied CHI-E write completion wrong opcode 0x{int(write_responses[0].rsp_opcode):x}"
    assert int(read_responses[0].dat_opcode) == int(DatOpcode.COMP_DATA), \
      f"proxied CHI-E read completion wrong DAT opcode 0x{int(read_responses[0].dat_opcode):x}"
    assert len(read_responses[0].data) == 1, \
      f"proxied CHI-E read returned {len(read_responses[0].data)} beats instead of 1 " \
      "(64 B = one wide beat)"

    # Readback data integrity: the single wide beat matches what was written.
    assert [int(x) for x in read_responses[0].data] == \
           [int(x) for x in write_responses[0].data], \
      "CHI-E proxied readback did not match the written payload"

    self.logger.info(
      "Test (tc_chi_e_hni_passthrough) PASS: HN-I proxy relayed a wide CHI-E "
      "write+read end-to-end (RN-I -> HN-I -> SN-F)")
    self.drop_objection()
