################################################################################
# pyUVM/cocotb port of tc/tc_chi_e_sep_read.sv.
#
# ReadNoSnpSep (CHI-E): the Slave's owed ReadReceipt on RSP precedes the data
# leg (DataSepResp on DAT), which returns under ReturnTxnID (!= TxnID).
#
# The RSP leg used to be RespSepData, which Appendix B Table B-3 permits from a
# Home only ("RespSepData is permitted from the Home only", section 2.3.1) --
# this test asserts the whole RSP leg so a Home-only response reappearing on a
# Slave's link fails here and not only in the scoreboard.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import ReqOpcode, DatOpcode, RspOpcode
from chi_e_base_test import chi_e_base_test

RNI_NID_C = 0x15
SNF_NID_C = 0x2A
SEP_READ_ADDR_C = 0x0012_3456_7A00
SEP_RETURN_TXN_ID_C = 0x5A


class tc_chi_e_sep_read(chi_e_base_test):

  async def run_phase(self):
    self.raise_objection()

    rd = self.rni_rd_seq
    rd.reset()
    rd.set_requests(1)
    rd.set_initial_addr(SEP_READ_ADDR_C)
    rd.set_size(6)
    rd.set_sep_read(True)
    rd.set_src_id(RNI_NID_C)
    rd.set_tgt_id(SNF_NID_C)
    rd.set_return_nid(RNI_NID_C)          # must == src_id
    rd.set_return_txn_id(SEP_RETURN_TXN_ID_C)
    rd.set_get_response(True)
    rd.set_verbose(False)
    await rd.start(self.tb_env.rni_agent.sequencer)

    responses = rd.get_responses()
    assert len(responses) == 1
    rsp = responses[0]

    req_item = await self.tb_env.rni_req_fifo.get()
    assert int(req_item.opcode) == int(ReqOpcode.READ_NO_SNP_SEP)
    assert int(req_item.return_txn_id) == SEP_RETURN_TXN_ID_C
    assert int(req_item.return_txn_id) != int(req_item.txn_id)
    assert int(rsp.dat_opcode) == int(DatOpcode.DATA_SEP_RESP)
    assert len(rsp.data) == 1

    # Every RSP the link carried, not just the first: a stray RespSepData after
    # the receipt would still be a Home-only response emitted by a Slave.
    rsp_opcodes = []
    while self.tb_env.rni_rsp_fifo.can_get():
      _, item = self.tb_env.rni_rsp_fifo.try_get()
      rsp_opcodes.append(int(item.rsp_opcode))

    assert int(RspOpcode.READ_RECEIPT) in rsp_opcodes, (
      f"the Slave owes a ReadReceipt for every ReadNoSnpSep; RSP leg was "
      f"{[hex(o) for o in rsp_opcodes]}")
    assert int(RspOpcode.RESP_SEP_DATA) not in rsp_opcodes, (
      f"RespSepData is permitted from the Home only (section 2.3.1); RSP leg "
      f"was {[hex(o) for o in rsp_opcodes]}")

    sb = self.tb_env.scoreboard
    assert sb.n_originator_illegal == 0
    # The stand-in is the one departure, and it must be the ONLY one: exactly
    # the ReadNoSnpSep REQ, nothing else on the link.
    assert sb.n_originator_standin == 1
    assert sb.n_originator_skipped == 0

    self.logger.info("Test (tc_chi_e_sep_read) PASS")
    self.drop_objection()
