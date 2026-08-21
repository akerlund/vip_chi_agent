################################################################################
# pyUVM/cocotb port of tc/tc_chi_d_hni_xbar.sv.
#
# RN0 targets an address that decodes to SN target 0; RN1 targets an address that
# decodes to SN target 1 (they differ in bit 12, the HN-I default SN decode bit).
# Verify each RN reads back its own payload (completion routed to the right RN by
# node id) and that SN-F 0 observed only RN0's address and SN-F 1 only RN1's
# (request address decode routed to the right SN). Traffic is sequential (serial
# SN-F responders); the crossbar structure is what is under test.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import DataType
from chi_hni_base_test import chi_hni_base_test
from chi_tb_pkg import WRITE_READ_ADDR_C

RN0_NODE_ID_C = 0x012
RN1_NODE_ID_C = 0x013
SN0_ADDR_C = WRITE_READ_ADDR_C
SN1_ADDR_C = WRITE_READ_ADDR_C + 0x1000


class tc_chi_d_hni_xbar(chi_hni_base_test):

  async def run_phase(self):
    self.raise_objection()

    # RN0 -> SN target 0.
    w0 = self.rni0_wr_seq
    w0.reset()
    w0.set_requests(1)
    w0.set_src_id(RN0_NODE_ID_C)
    w0.set_initial_addr(SN0_ADDR_C)
    w0.set_size(6)
    w0.set_data_type(DataType.COUNTER)
    w0.set_counter_value(0xE0)
    w0.set_counter_increment(0x1)
    w0.set_get_response(True)
    w0.set_verbose(False)
    await w0.start(self.v_sqr.hrni0_sequencer)

    # RN1 -> SN target 1.
    w1 = self.rni1_wr_seq
    w1.reset()
    w1.set_requests(1)
    w1.set_src_id(RN1_NODE_ID_C)
    w1.set_initial_addr(SN1_ADDR_C)
    w1.set_size(6)
    w1.set_data_type(DataType.COUNTER)
    w1.set_counter_value(0xF0)
    w1.set_counter_increment(0x1)
    w1.set_get_response(True)
    w1.set_verbose(False)
    await w1.start(self.v_sqr.hrni1_sequencer)

    # Readbacks.
    r0 = self.rni0_rd_seq
    r0.reset()
    r0.set_requests(1)
    r0.set_src_id(RN0_NODE_ID_C)
    r0.set_initial_addr(SN0_ADDR_C)
    r0.set_size(6)
    r0.set_get_response(True)
    r0.set_verbose(False)
    await r0.start(self.v_sqr.hrni0_sequencer)

    r1 = self.rni1_rd_seq
    r1.reset()
    r1.set_requests(1)
    r1.set_src_id(RN1_NODE_ID_C)
    r1.set_initial_addr(SN1_ADDR_C)
    r1.set_size(6)
    r1.set_get_response(True)
    r1.set_verbose(False)
    await r1.start(self.v_sqr.hrni1_sequencer)

    rn0_wr = w0.get_responses()
    rn1_wr = w1.get_responses()
    rn0_rd = r0.get_responses()
    rn1_rd = r1.get_responses()

    assert (len(rn0_wr) == 1 and len(rn1_wr) == 1 and
            len(rn0_rd) == 1 and len(rn1_rd) == 1), \
      (f"expected one response per op; got wr({len(rn0_wr)},{len(rn1_wr)}) "
       f"rd({len(rn0_rd)},{len(rn1_rd)})")

    # Per-RN readback data integrity (each RN reads back its own payload).
    assert [int(x) for x in rn0_rd[0].data] == [int(x) for x in rn0_wr[0].data], \
      "RN0 readback did not match its own written payload"
    assert [int(x) for x in rn1_rd[0].data] == [int(x) for x in rn1_wr[0].data], \
      "RN1 readback did not match its own written payload"

    # Address decode routing: SN-F 0 must have seen only RN0's address (one write
    # + one read), SN-F 1 only RN1's address.
    sn0_reqs = [await self.tb_env.hsnf0_req_fifo.get() for _ in range(2)]
    sn1_reqs = [await self.tb_env.hsnf1_req_fifo.get() for _ in range(2)]

    for q in sn0_reqs:
      assert int(q.addr) == SN0_ADDR_C, \
        f"SN-F 0 saw wrong address 0x{int(q.addr):x} (expected 0x{SN0_ADDR_C:x}) -- mis-routed"
    for q in sn1_reqs:
      assert int(q.addr) == SN1_ADDR_C, \
        f"SN-F 1 saw wrong address 0x{int(q.addr):x} (expected 0x{SN1_ADDR_C:x}) -- mis-routed"

    self.logger.info(
      "Test (tc_chi_d_hni_xbar) PASS: HN-I crossbar routed RN0->SN0 and RN1->SN1 "
      "by address, completions returned by node id")
    self.drop_objection()
