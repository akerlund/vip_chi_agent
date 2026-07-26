################################################################################
# pyUVM/cocotb port of tc/tc_chi_d_hni_fanin.sv.
#
# Drive one transaction from each RN through the shared proxy and confirm the
# HN-I routes each SN-F completion back to the originating RN by node id: RN0 and
# RN1 each read back their own payload. Both addresses decode to the same SN
# target (they share address bit 12, the HN-I default decode bit) so this stays a
# true single-SN fan-in. A routing bug would deliver a completion to the wrong RN,
# hanging that RN's sequence (phase timeout) -- so a clean pass proves node-id
# routing works. Traffic is issued one transaction at a time (serial SN-F
# auto-responder); the fan-in structure (two RN links, one SN link, arbitrated
# sends, routed completions) is what is under test.
# Runs under: testbench/py/tb/vip_chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import DataType
from vip_chi_hni_base_test import vip_chi_hni_base_test
from vip_chi_tb_pkg import WRITE_READ_ADDR_C

RN0_NODE_ID_C = 0x012
RN1_NODE_ID_C = 0x013
RN0_ADDR_C = WRITE_READ_ADDR_C
RN1_ADDR_C = WRITE_READ_ADDR_C + 0x40


class tc_chi_d_hni_fanin(vip_chi_hni_base_test):

  async def run_phase(self):
    self.raise_objection()

    # RN0 write.
    w0 = self.rni0_wr_seq
    w0.reset()
    w0.set_requests(1)
    w0.set_src_id(RN0_NODE_ID_C)
    w0.set_initial_addr(RN0_ADDR_C)
    w0.set_size(6)
    w0.set_allow_retry(0)
    w0.set_data_type(DataType.COUNTER)
    w0.set_counter_value(0xC0)
    w0.set_counter_increment(0x1)
    w0.set_get_response(True)
    w0.set_verbose(False)
    await w0.start(self.v_sqr.hrni0_sequencer)

    # RN1 write (different node id, address, payload).
    w1 = self.rni1_wr_seq
    w1.reset()
    w1.set_requests(1)
    w1.set_src_id(RN1_NODE_ID_C)
    w1.set_initial_addr(RN1_ADDR_C)
    w1.set_size(6)
    w1.set_allow_retry(0)
    w1.set_data_type(DataType.COUNTER)
    w1.set_counter_value(0xD0)
    w1.set_counter_increment(0x1)
    w1.set_get_response(True)
    w1.set_verbose(False)
    await w1.start(self.v_sqr.hrni1_sequencer)

    # RN0 readback.
    r0 = self.rni0_rd_seq
    r0.reset()
    r0.set_requests(1)
    r0.set_src_id(RN0_NODE_ID_C)
    r0.set_initial_addr(RN0_ADDR_C)
    r0.set_size(6)
    r0.set_allow_retry(0)
    r0.set_get_response(True)
    r0.set_verbose(False)
    await r0.start(self.v_sqr.hrni0_sequencer)

    # RN1 readback.
    r1 = self.rni1_rd_seq
    r1.reset()
    r1.set_requests(1)
    r1.set_src_id(RN1_NODE_ID_C)
    r1.set_initial_addr(RN1_ADDR_C)
    r1.set_size(6)
    r1.set_allow_retry(0)
    r1.set_get_response(True)
    r1.set_verbose(False)
    await r1.start(self.v_sqr.hrni1_sequencer)

    rn0_wr = w0.get_responses()
    rn1_wr = w1.get_responses()
    rn0_rd = r0.get_responses()
    rn1_rd = r1.get_responses()

    assert len(rn0_wr) == 1 and len(rn1_wr) == 1, \
      f"expected 1 write response per RN, got RN0={len(rn0_wr)} RN1={len(rn1_wr)}"
    assert len(rn0_rd) == 1 and len(rn1_rd) == 1, \
      f"expected 1 read response per RN, got RN0={len(rn0_rd)} RN1={len(rn1_rd)}"

    # Each RN reading back its own payload proves the completion was routed to the
    # correct RN and carried the correct data end-to-end. A return routed to the
    # wrong RN would either mismatch here or hang the peer sequence (timeout).
    assert [int(x) for x in rn0_rd[0].data] == [int(x) for x in rn0_wr[0].data], \
      "RN0 readback did not match its own written payload (mis-routed completion)"
    assert [int(x) for x in rn1_rd[0].data] == [int(x) for x in rn1_wr[0].data], \
      "RN1 readback did not match its own written payload (mis-routed completion)"

    self.logger.info(
      "Test (tc_chi_d_hni_fanin) PASS: HN-I fan-in relayed and routed both RN "
      "transactions (RN0+RN1 -> HN-I -> SN-F)")
    self.drop_objection()
