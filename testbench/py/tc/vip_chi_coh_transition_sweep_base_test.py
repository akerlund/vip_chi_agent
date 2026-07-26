################################################################################
# pyUVM port of tc/vip_chi_coh_transition_sweep_base_test.sv.
#
# Sweep (from-state x snoop-op) cache transitions: for each initial state {SC, UC,
# UD} on a fresh line, prime RN-F0 into it then run each of 7 coherent ops on
# RN-F1, driving many distinct snoop transitions. Asserts the sweep actually
# originated snoops (>= 10). Functional coverage is observational (0.0 here).
################################################################################

from __future__ import annotations

from vip_chi_coherent_base_test import vip_chi_coherent_base_test
from vip_chi_readshared_seq import vip_chi_readshared_seq
from vip_chi_readclean_seq import vip_chi_readclean_seq
from vip_chi_readunique_seq import vip_chi_readunique_seq
from vip_chi_readonce_seq import vip_chi_readonce_seq
from vip_chi_cleaninvalid_seq import vip_chi_cleaninvalid_seq
from vip_chi_makeinvalid_seq import vip_chi_makeinvalid_seq
from vip_chi_makeunique_seq import vip_chi_makeunique_seq
from vip_chi_tb_pkg import WRITE_READ_ADDR_C

_LINE_STRIDE = 0x40
_N_STATES = 3
_N_OPS = 7
_MIN_SNOOPS = 10
_SEQ_BY_KIND = (
  vip_chi_readshared_seq, vip_chi_readclean_seq, vip_chi_readunique_seq,
  vip_chi_readonce_seq, vip_chi_cleaninvalid_seq, vip_chi_makeinvalid_seq,
  vip_chi_makeunique_seq,
)


class vip_chi_coh_transition_sweep_base_test(vip_chi_coherent_base_test):

  async def _run_op(self, node, line, kind):
    seq = _SEQ_BY_KIND[kind](f"sw_{kind}", cfg=self.chi_cfg)
    self.cfg_read_seq(seq, line)
    sequencer = (self.tb_env.hrnf0_agent.sequencer if node == 0
                 else self.tb_env.hrnf1_agent.sequencer)
    await seq.start(sequencer)
    seq.get_responses()

  async def run_phase(self):
    self.raise_objection()
    await self.wait_reset_settle()

    idx = 0
    for st in range(_N_STATES):
      for op in range(_N_OPS):
        line = WRITE_READ_ADDR_C + idx * _LINE_STRIDE
        idx += 1
        # Prime RN-F0 into the initial state: ReadShared->SC, ReadUnique->UC,
        # MakeUnique->UD.
        prime_kind = {0: 0, 1: 2}.get(st, 6)
        await self._run_op(0, line, prime_kind)
        await self._run_op(1, line, op)

    await self.wait_clocks(16)

    snoops = self.tb_env.coh_checker.get_snoop_count()
    cov = self.tb_env.coh_checker.get_cache_transition_coverage()
    self.logger.info(
      f"[coh_transition_sweep] {idx} directed combinations, {snoops} snoops "
      f"observed; cg_cache_transition = {cov:.1f}% (observational)")
    assert snoops >= _MIN_SNOOPS, \
      f"transition sweep drove only {snoops} snoops (< {_MIN_SNOOPS})"
    assert not (0.0 < cov < 99.0), \
      f"transition sweep left cg_cache_transition at {cov:.1f}%"

    self.logger.info("Test (coh_transition_sweep) PASS")
    self.drop_objection()
