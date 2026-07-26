################################################################################
# pyUVM/cocotb port of tc/tc_chi_d_ordered_read.sv.
#
# ReadNoSnp with Order=RequestOrder: the SN-F sends a ReadReceipt on RSP ahead of
# the CompData burst. Checks the receipt routing/role and the read payload.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import Role, ReqOpcode, ReqOrder, RspOpcode, DatOpcode
from chi_base_test import chi_base_test
from chi_tb_pkg import READ_ADDR_C


class tc_chi_d_ordered_read(chi_base_test):

  async def run_phase(self):
    self.raise_objection()

    rd = self.rni0_rd_seq
    rd.reset()
    rd.set_requests(1)
    rd.set_initial_addr(READ_ADDR_C + 0x100)
    rd.set_size(6)
    rd.set_order(int(ReqOrder.REQ_ORDER))
    rd.set_allow_retry(0)
    rd.set_get_response(True)
    rd.set_verbose(False)
    await rd.start(self.v_sqr.rni_sequencer)

    responses = rd.get_responses()
    assert len(responses) == 1
    rsp = responses[0]

    req_item = await self.tb_env.rni_req_fifo.get()
    receipt = await self.tb_env.rni_rsp_fifo.get()
    dat_item = await self.tb_env.rni_dat_fifo.get()

    assert int(req_item.opcode) == int(ReqOpcode.READ_NO_SNP)
    assert int(req_item.order) == int(ReqOrder.REQ_ORDER)
    assert int(receipt.role) == int(Role.SNF)
    assert int(receipt.rsp_opcode) == int(RspOpcode.READ_RECEIPT)
    assert int(receipt.txn_id) == int(req_item.txn_id)
    assert int(receipt.src_id) == int(req_item.tgt_id)
    assert int(receipt.tgt_id) == int(req_item.src_id)
    assert int(dat_item.dat_opcode) == int(DatOpcode.COMP_DATA)
    assert int(rsp.txn_id) == int(req_item.txn_id)
    assert int(rsp.dbid) == int(req_item.txn_id)
    assert int(rsp.src_id) == int(req_item.tgt_id)
    assert int(rsp.tgt_id) == int(req_item.src_id)
    assert len(rsp.data) == len(dat_item.data) and len(rsp.data) > 0

    for i in range(len(rsp.data)):
      expected = (int(req_item.addr) + i) & ((1 << (8 * self.chi_cfg.data_bytes)) - 1)
      assert int(rsp.data[i]) == expected
      assert int(dat_item.data[i]) == expected

    self.logger.info("Test (tc_chi_d_ordered_read) PASS")
    self.drop_objection()
