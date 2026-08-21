################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM/cocotb port of tc/tc_chi_d_write_read_smoke.sv.
#
# The Tier-A2 make-or-break gate: a WriteNoSnpFull followed by a ReadNoSnp at the
# same address, driven end to end through the integrated RN-I requester / SN-F
# completer pair. It checks the two observed REQ opcodes + address, that the DAT
# bursts reassemble to 4 beats each and are attributed to RN-I (write) then SN-F
# (read), the write grant opcode (CompDBIDResp), the read completion opcode
# (CompData), and the RN-I COUNTER write-payload pattern (0x90 + beat).
#
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import Role, DataType, ReqOpcode, RspOpcode, DatOpcode
from chi_base_test import chi_base_test, WRITE_READ_ADDR_C


class tc_chi_d_write_read_smoke(chi_base_test):

  async def run_phase(self):
    self.raise_objection()

    wr = self.rni0_wr_seq
    wr.reset()
    wr.set_requests(1)
    wr.set_initial_addr(WRITE_READ_ADDR_C)
    wr.set_size(6)
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
    rd.set_get_response(True)
    rd.set_verbose(False)
    await rd.start(self.v_sqr.rni_sequencer)

    write_responses = wr.get_responses()
    read_responses = rd.get_responses()

    assert len(write_responses) == 1, \
      f"expected 1 write response, got {len(write_responses)}"
    assert len(read_responses) == 1, \
      f"expected 1 read response, got {len(read_responses)}"

    req_items = [await self.tb_env.rni_req_fifo.get() for _ in range(2)]
    dat_items = [await self.tb_env.rni_dat_fifo.get() for _ in range(2)]

    assert int(req_items[0].opcode) == int(ReqOpcode.WRITE_NO_SNP_FULL), \
      f"first request was not WriteNoSnpFull: 0x{int(req_items[0].opcode):x}"
    assert int(req_items[1].opcode) == int(ReqOpcode.READ_NO_SNP), \
      f"second request was not ReadNoSnp: 0x{int(req_items[1].opcode):x}"
    assert int(req_items[0].addr) == WRITE_READ_ADDR_C, \
      f"write address mismatch 0x{int(req_items[0].addr):x}"
    assert int(req_items[1].addr) == WRITE_READ_ADDR_C, \
      f"read address mismatch 0x{int(req_items[1].addr):x}"

    assert int(dat_items[0].role) == int(Role.RNI), \
      f"first DAT item role was not RN-I: {int(dat_items[0].role)}"
    assert int(dat_items[1].role) == int(Role.SNF), \
      f"second DAT item role was not SN-F: {int(dat_items[1].role)}"

    assert len(dat_items[0].data) == 4, \
      f"write DAT beat count was {len(dat_items[0].data)} instead of 4"
    assert len(dat_items[1].data) == len(dat_items[0].data), \
      (f"read DAT beat count {len(dat_items[1].data)} != write DAT beat "
       f"count {len(dat_items[0].data)}")

    assert int(write_responses[0].rsp_opcode) == int(RspOpcode.COMP_DBID_RESP), \
      f"write response carried wrong opcode 0x{int(write_responses[0].rsp_opcode):x}"
    assert int(read_responses[0].dat_opcode) == int(DatOpcode.COMP_DATA), \
      f"read response carried wrong DAT opcode 0x{int(read_responses[0].dat_opcode):x}"

    for i, beat in enumerate(dat_items[0].data):
      assert int(beat) == (0x90 + i), \
        f"write DAT beat {i} payload mismatch 0x{int(beat):x}"

    self.logger.info("Test (tc_chi_d_write_read_smoke) PASS")
    self.drop_objection()
