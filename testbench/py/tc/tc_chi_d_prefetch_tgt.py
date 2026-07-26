################################################################################
# pyUVM/cocotb port of tc/tc_chi_d_prefetch_tgt.sv.
#
# Verify PrefetchTgt is accepted as a no-completion hint: the RN-I drives only the
# REQ and retires the item locally (RN-I role), and no RSP or DAT ever comes back.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import ReqOpcode, Role
from chi_base_test import chi_base_test
from chi_prefetch_tgt_seq import chi_prefetch_tgt_seq
from chi_tb_pkg import READ_ADDR_C


class tc_chi_d_prefetch_tgt(chi_base_test):

  async def run_phase(self):
    self.raise_objection()

    seq = chi_prefetch_tgt_seq("prefetch_tgt_seq", cfg=self.chi_cfg)
    seq.reset()
    seq.set_requests(1)
    seq.set_initial_addr(READ_ADDR_C + 0x180)
    seq.set_size(6)
    seq.set_allow_retry(0)
    seq.set_get_response(True)
    seq.set_verbose(False)
    await seq.start(self.v_sqr.rni_sequencer)

    responses = seq.get_responses()
    assert len(responses) == 1, \
      f"expected 1 PrefetchTgt response item, got {len(responses)}"

    req_item = await self.tb_env.rni_req_fifo.get()
    assert int(req_item.opcode) == int(ReqOpcode.PREFETCH_TGT), \
      f"monitor observed wrong PrefetchTgt opcode 0x{int(req_item.opcode):x}"
    assert int(responses[0].opcode) == int(ReqOpcode.PREFETCH_TGT), \
      f"sequence response item opcode 0x{int(responses[0].opcode):x} was not PrefetchTgt"
    assert int(responses[0].role) == int(Role.RNI), \
      f"PrefetchTgt should retire locally with RN-I role, got {int(responses[0].role)}"

    # A PrefetchTgt has no completion: after a few cycles neither an RSP nor a DAT
    # item may appear on the requester monitor.
    await self.wait_clocks(4)

    ok, rsp_item = self.tb_env.rni_rsp_fifo.try_get()
    assert not ok, \
      f"PrefetchTgt unexpectedly produced an RSP item opcode 0x{int(rsp_item.rsp_opcode):x}"
    assert self.tb_env.rni_dat_fifo.used() == 0, \
      f"PrefetchTgt unexpectedly produced {self.tb_env.rni_dat_fifo.used()} DAT item(s)"

    self.logger.info(
      "Test (tc_chi_d_prefetch_tgt) PASS: PrefetchTgt retired locally as a "
      "no-completion hint")
    self.drop_objection()
