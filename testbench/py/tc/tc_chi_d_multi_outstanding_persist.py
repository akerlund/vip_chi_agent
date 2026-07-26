################################################################################
# pyUVM/cocotb port of tc/tc_chi_d_multi_outstanding_persist.sv.
#
# Pipeline N CleanSharedPersist CMOs. Each carries no write data and no DBID
# grant -- it just issues its REQ and completes on a single Comp RSP. Confirms the
# pipeline overlaps these RSP-only, no-data transactions (peak > 1) and hands each
# back with its Comp completion.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import ReqOpcode, RspOpcode
from chi_base_test import chi_base_test
from vip_chi_persist_seq import vip_chi_persist_seq

N_C = 6
BASE_ADDR_C = 0x3000_0000
SIZE_C = 6


class tc_chi_d_multi_outstanding_persist(chi_base_test):

  def configure(self, rni_cfg, snf_cfg):
    rni_cfg.multi_outstanding = True
    rni_cfg.multi_outstanding_write = True
    rni_cfg.max_outstanding_write = N_C
    rni_cfg.max_outstanding_read = N_C
    snf_cfg.multi_outstanding = True

  async def run_phase(self):
    self.raise_objection()

    persist_seq = vip_chi_persist_seq("persist_seq", cfg=self.chi_cfg)
    persist_seq.reset()
    persist_seq.set_sep_persist(False)       # CleanSharedPersist (Comp)
    persist_seq.set_requests(N_C)
    persist_seq.set_initial_addr(BASE_ADDR_C)
    persist_seq.set_size(SIZE_C)
    persist_seq.set_allow_retry(0)
    persist_seq.set_get_response(True)
    persist_seq.set_pipelined_send(True)
    persist_seq.set_verbose(False)
    await persist_seq.start(self.v_sqr.rni_sequencer)

    rsp = persist_seq.get_responses()
    assert len(rsp) == N_C, f"expected {N_C} persist responses, got {len(rsp)}"
    for k, r in enumerate(rsp):
      assert int(r.opcode) == int(ReqOpcode.CLEAN_SHARED_PERSIST), \
        f"persist {k} was not CleanSharedPersist (opcode 0x{int(r.opcode):x})"
      assert int(r.rsp_opcode) == int(RspOpcode.COMP), \
        f"persist {k} completion opcode 0x{int(r.rsp_opcode):x} was not Comp"

    peak = self.rni_cfg.observed_peak_outstanding
    assert peak > 1, f"persists did not overlap: peak was {peak} (expected > 1)"

    self.logger.info(
      f"Test (tc_chi_d_multi_outstanding_persist) PASS: {N_C} CleanSharedPersist "
      f"CMOs pipelined (RSP-only, no data), peak in-flight = {peak}")
    self.drop_objection()
