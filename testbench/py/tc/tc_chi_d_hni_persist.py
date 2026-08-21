################################################################################
# pyUVM/cocotb port of tc/tc_chi_d_hni_persist.sv.
#
# A CleanSharedPersist CMO through the proxy: no data, no DBID grant -- just a REQ
# forwarded to the SN-F and a single Comp relayed back. Exercises the HN-I's
# RSP-only settle path (active_kind = RSP_ONLY, settled on the terminal Comp).
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import RspOpcode
from chi_hni_base_test import chi_hni_base_test
from vip_chi_persist_seq import vip_chi_persist_seq
from chi_tb_pkg import WRITE_READ_ADDR_C


class tc_chi_d_hni_persist(chi_hni_base_test):

  async def run_phase(self):
    self.raise_objection()

    persist_seq = vip_chi_persist_seq("persist_seq", cfg=self.chi_cfg)
    persist_seq.reset()
    persist_seq.set_requests(1)
    persist_seq.set_initial_addr(WRITE_READ_ADDR_C)
    persist_seq.set_size(6)
    persist_seq.set_get_response(True)
    persist_seq.set_verbose(False)
    await persist_seq.start(self.v_sqr.hrni0_sequencer)

    responses = persist_seq.get_responses()
    assert len(responses) == 1, \
      f"expected 1 persist completion through the proxy, got {len(responses)}"
    assert int(responses[0].rsp_opcode) == int(RspOpcode.COMP), \
      f"proxied persist completion opcode 0x{int(responses[0].rsp_opcode):x} was not Comp"

    self.logger.info(
      "Test (tc_chi_d_hni_persist) PASS: HN-I relayed a completion-only "
      "CleanSharedPersist (RSP-only settle path)")
    self.drop_objection()
