################################################################################
# pyUVM/cocotb port of tc/tc_chi_d_hni_sam.sv.
#
# Same crossbar checks as tc_chi_d_hni_xbar, but the SN split is driven by an
# explicit SAM range table rather than the address stride. Both addresses share
# address bit 12 (= 0), so the HN-I *default* stride decode would route both to SN
# target 0. Only the configured SAM ranges below split them across the two SN
# targets -- so a clean pass proves the SAM range table (not the fallback stride)
# drove the routing.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import DataType
from chi_hni_base_test import chi_hni_base_test
from vip_chi_hni_sam import vip_chi_hni_sam

RN0_NODE_ID_C = 0x012
RN1_NODE_ID_C = 0x013
SN0_ADDR_C = 0x3000_8000
SN1_ADDR_C = 0x3001_8000


class tc_chi_d_hni_sam(chi_hni_base_test):

  def configure_hni(self, hni):
    # Two explicit 64 KB ranges mapping to SN targets 0 and 1.
    sam = vip_chi_hni_sam("hni_sam")
    sam.default_port = 0
    sam.add_range(0x3000_0000, 0x3000_FFFF, 0)
    sam.add_range(0x3001_0000, 0x3001_FFFF, 1)
    hni.sam = sam

  async def run_phase(self):
    self.raise_objection()

    w0 = self.rni0_wr_seq
    w0.reset()
    w0.set_requests(1)
    w0.set_src_id(RN0_NODE_ID_C)
    w0.set_initial_addr(SN0_ADDR_C)
    w0.set_size(6)
    w0.set_allow_retry(0)
    w0.set_data_type(DataType.COUNTER)
    w0.set_counter_value(0x30)
    w0.set_counter_increment(0x1)
    w0.set_get_response(True)
    w0.set_verbose(False)
    await w0.start(self.v_sqr.hrni0_sequencer)

    w1 = self.rni1_wr_seq
    w1.reset()
    w1.set_requests(1)
    w1.set_src_id(RN1_NODE_ID_C)
    w1.set_initial_addr(SN1_ADDR_C)
    w1.set_size(6)
    w1.set_allow_retry(0)
    w1.set_data_type(DataType.COUNTER)
    w1.set_counter_value(0x50)
    w1.set_counter_increment(0x1)
    w1.set_get_response(True)
    w1.set_verbose(False)
    await w1.start(self.v_sqr.hrni1_sequencer)

    r0 = self.rni0_rd_seq
    r0.reset()
    r0.set_requests(1)
    r0.set_src_id(RN0_NODE_ID_C)
    r0.set_initial_addr(SN0_ADDR_C)
    r0.set_size(6)
    r0.set_allow_retry(0)
    r0.set_get_response(True)
    r0.set_verbose(False)
    await r0.start(self.v_sqr.hrni0_sequencer)

    r1 = self.rni1_rd_seq
    r1.reset()
    r1.set_requests(1)
    r1.set_src_id(RN1_NODE_ID_C)
    r1.set_initial_addr(SN1_ADDR_C)
    r1.set_size(6)
    r1.set_allow_retry(0)
    r1.set_get_response(True)
    r1.set_verbose(False)
    await r1.start(self.v_sqr.hrni1_sequencer)

    rn0_rd = r0.get_responses()
    rn1_rd = r1.get_responses()
    rn0_wr = w0.get_responses()
    rn1_wr = w1.get_responses()

    assert len(rn0_rd) == 1 and len(rn1_rd) == 1, \
      f"expected 1 read response per RN, got RN0={len(rn0_rd)} RN1={len(rn1_rd)}"

    assert [int(x) for x in rn0_rd[0].data] == [int(x) for x in rn0_wr[0].data], \
      "RN0 readback did not match its own written payload"
    assert [int(x) for x in rn1_rd[0].data] == [int(x) for x in rn1_wr[0].data], \
      "RN1 readback did not match its own written payload"

    # SAM routing proof: SN-F 0 saw only SN0_ADDR_C, SN-F 1 only SN1_ADDR_C.
    sn0_reqs = [await self.tb_env.hsnf0_req_fifo.get() for _ in range(2)]
    sn1_reqs = [await self.tb_env.hsnf1_req_fifo.get() for _ in range(2)]

    for q in sn0_reqs:
      assert int(q.addr) == SN0_ADDR_C, \
        f"SN-F 0 saw 0x{int(q.addr):x} (expected 0x{SN0_ADDR_C:x}) -- SAM mis-routed"
    for q in sn1_reqs:
      assert int(q.addr) == SN1_ADDR_C, \
        f"SN-F 1 saw 0x{int(q.addr):x} (expected 0x{SN1_ADDR_C:x}) -- SAM mis-routed"

    self.logger.info(
      "Test (tc_chi_d_hni_sam) PASS: HN-I SAM range table routed RN0->SN0 and "
      "RN1->SN1 (addresses share the default stride bit)")
    self.drop_objection()
