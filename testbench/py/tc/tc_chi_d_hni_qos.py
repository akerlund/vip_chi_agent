################################################################################
# pyUVM/cocotb port of tc/tc_chi_d_hni_qos.sv.
#
# RN0 (low QoS) and RN1 (high QoS) present reads to the same SN target at the same
# time (both addresses share address bit 12, so they contend for one SN). Given a
# QoS arbitration collection window on the HN-I, it must forward the high-QoS
# request first, so SN-F 0 sees RN1's read before RN0's.
# Runs under: testbench/py/tb/vip_chi_tb_top.py
################################################################################

from __future__ import annotations

import cocotb

from vip_chi_hni_base_test import vip_chi_hni_base_test
from vip_chi_tb_pkg import WRITE_READ_ADDR_C

RN0_NODE_ID_C = 0x012
RN1_NODE_ID_C = 0x013
RN0_ADDR_C = WRITE_READ_ADDR_C
RN1_ADDR_C = WRITE_READ_ADDR_C + 0x40
LOW_QOS_C = 0x2
HIGH_QOS_C = 0xD


class tc_chi_d_hni_qos(vip_chi_hni_base_test):

  def configure_hni(self, hni):
    # Collection window so both requestors are captured before it arbitrates.
    hni.arb_window_cycles = 60

  async def run_phase(self):
    self.raise_objection()

    r0 = self.rni0_rd_seq
    r0.reset()
    r0.set_requests(1)
    r0.set_src_id(RN0_NODE_ID_C)
    r0.set_initial_addr(RN0_ADDR_C)
    r0.set_size(6)
    r0.set_allow_retry(0)
    r0.set_qos(LOW_QOS_C)
    r0.set_get_response(True)
    r0.set_verbose(False)

    r1 = self.rni1_rd_seq
    r1.reset()
    r1.set_requests(1)
    r1.set_src_id(RN1_NODE_ID_C)
    r1.set_initial_addr(RN1_ADDR_C)
    r1.set_size(6)
    r1.set_allow_retry(0)
    r1.set_qos(HIGH_QOS_C)
    r1.set_get_response(True)
    r1.set_verbose(False)

    t0 = cocotb.start_soon(r0.start(self.v_sqr.hrni0_sequencer))
    t1 = cocotb.start_soon(r1.start(self.v_sqr.hrni1_sequencer))
    await t0
    await t1

    rn0_rsp = r0.get_responses()
    rn1_rsp = r1.get_responses()
    assert len(rn0_rsp) == 1 and len(rn1_rsp) == 1, \
      f"expected 1 read response per RN, got RN0={len(rn0_rsp)} RN1={len(rn1_rsp)}"

    # SN-F 0 observed both reads; the first must be the high-QoS RN1 request.
    sn_reqs = [await self.tb_env.hsnf0_req_fifo.get() for _ in range(2)]

    assert int(sn_reqs[0].qos) == HIGH_QOS_C, \
      (f"first forwarded request had QoS 0x{int(sn_reqs[0].qos):x}, "
       f"expected high QoS 0x{HIGH_QOS_C:x}")
    assert int(sn_reqs[0].src_id) == RN1_NODE_ID_C, \
      (f"high-QoS request came from src 0x{int(sn_reqs[0].src_id):x}, "
       f"expected RN1 0x{RN1_NODE_ID_C:x}")
    assert int(sn_reqs[1].qos) == LOW_QOS_C, \
      (f"second forwarded request had QoS 0x{int(sn_reqs[1].qos):x}, "
       f"expected low QoS 0x{LOW_QOS_C:x}")

    self.logger.info(
      "Test (tc_chi_d_hni_qos) PASS: HN-I QoS arbitration forwarded high-QoS RN1 "
      "before low-QoS RN0")
    self.drop_objection()
