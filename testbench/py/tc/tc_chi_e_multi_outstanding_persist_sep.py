################################################################################
# pyUVM/cocotb port of tc/tc_chi_e_multi_outstanding_persist_sep.sv.
#
# Pipeline N CleanSharedPersistSep CMOs over the CHI-E link. Each carries no write
# data and no DBID grant, and completes with a two-part separated response: an
# intermediate Persist then a final CompPersist. The pipeline's RSP monitor
# consumes the intermediate Persist and retires each CMO on its CompPersist.
# Runs under: testbench/py/tb/vip_chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import ReqOpcode, RspOpcode
from vip_chi_e_base_test import vip_chi_e_base_test
from vip_chi_persist_seq import vip_chi_persist_seq
from vip_chi_tb_pkg import (
  E_PERSIST_SEP_ADDR_C, E_PERSIST_SEP_RNI_NODE_ID_C, E_PERSIST_SEP_SNF_NODE_ID_C,
)

N_C = 6


class tc_chi_e_multi_outstanding_persist_sep(vip_chi_e_base_test):

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
    persist_seq.set_sep_persist(True)          # CleanSharedPersistSep => Persist + CompPersist
    persist_seq.set_requests(N_C)
    persist_seq.set_initial_addr(E_PERSIST_SEP_ADDR_C)
    persist_seq.set_size(6)
    persist_seq.set_src_id(E_PERSIST_SEP_RNI_NODE_ID_C)
    persist_seq.set_tgt_id(E_PERSIST_SEP_SNF_NODE_ID_C)
    persist_seq.set_allow_retry(0)
    persist_seq.set_get_response(True)
    persist_seq.set_pipelined_send(True)
    persist_seq.set_verbose(False)
    await persist_seq.start(self.v_sqr.rni_sequencer)

    rsp = persist_seq.get_responses()
    assert len(rsp) == N_C, f"expected {N_C} persist-sep responses, got {len(rsp)}"
    for k, r in enumerate(rsp):
      assert int(r.opcode) == int(ReqOpcode.CLEAN_SHARED_PERSIST_SEP), \
        f"persist {k} was not CleanSharedPersistSep (opcode 0x{int(r.opcode):x})"
      # The pipeline consumed the intermediate Persist; final completion is CompPersist.
      assert int(r.rsp_opcode) == int(RspOpcode.COMP_PERSIST), \
        f"persist-sep {k} final opcode 0x{int(r.rsp_opcode):x} was not CompPersist"

    peak = self.rni_cfg.observed_peak_outstanding
    assert peak > 1, f"persist-sep CMOs did not overlap: peak was {peak} (expected > 1)"

    self.logger.info(
      f"Test (tc_chi_e_multi_outstanding_persist_sep) PASS: {N_C} "
      f"CleanSharedPersistSep CMOs pipelined (Persist+CompPersist), peak = {peak}")
    self.drop_objection()
