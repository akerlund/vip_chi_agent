################################################################################
# pyUVM/cocotb port of tc/tc_chi_d_read_smoke.sv.
#
# ReadNoSnp through the integrated pair: checks the observed REQ opcode/addr, the
# CompData response (role SN-F, opcode, txn_id/dbid/src/tgt echo), the 4-beat
# reassembly, and the deterministic SN-F read pattern (READ_ADDR + beat).
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import Role, ReqOpcode, DatOpcode
from chi_base_test import chi_base_test
from chi_tb_pkg import READ_ADDR_C


class tc_chi_d_read_smoke(chi_base_test):

  async def run_phase(self):
    self.raise_objection()

    rd = self.rni0_rd_seq
    rd.reset()
    rd.set_requests(1)
    rd.set_initial_addr(READ_ADDR_C)
    rd.set_size(6)
    rd.set_allow_retry(0)
    rd.set_get_response(True)
    rd.set_verbose(False)
    await rd.start(self.v_sqr.rni_sequencer)

    responses = rd.get_responses()
    assert len(responses) == 1, f"expected 1 read response, got {len(responses)}"
    rsp = responses[0]

    req_item = await self.tb_env.rni_req_fifo.get()
    dat_item = await self.tb_env.rni_dat_fifo.get()

    assert int(req_item.opcode) == int(ReqOpcode.READ_NO_SNP)
    assert int(req_item.addr) == READ_ADDR_C
    assert int(rsp.role) == int(Role.SNF)
    assert int(rsp.dat_opcode) == int(DatOpcode.COMP_DATA)
    assert int(rsp.txn_id) == int(req_item.txn_id)
    assert int(rsp.dbid) == int(req_item.txn_id)
    assert int(rsp.src_id) == int(req_item.tgt_id)
    assert int(rsp.tgt_id) == int(req_item.src_id)
    assert len(rsp.data) == 4, f"read response carried {len(rsp.data)} beats"

    assert int(dat_item.role) == int(Role.SNF)
    assert len(dat_item.data) == len(rsp.data)
    for i in range(len(rsp.data)):
      assert int(rsp.data[i]) == (READ_ADDR_C + i), \
        f"read beat {i} payload 0x{int(rsp.data[i]):x}"
      assert int(dat_item.data[i]) == int(rsp.data[i])

    self.logger.info("Test (tc_chi_d_read_smoke) PASS")
    self.drop_objection()
