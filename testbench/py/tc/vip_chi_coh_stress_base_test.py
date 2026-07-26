################################################################################
# pyUVM port of tc/vip_chi_coh_stress_base_test.sv.
#
# Prime both RN-Fs, then drive two concurrent random coherent-read streams over a
# small overlapping line set. Asserts the single-writer + data-integrity
# invariants hold under contention and that snoops actually fired.
################################################################################

from __future__ import annotations

import random

import cocotb

from vip_chi_coherent_base_test import vip_chi_coherent_base_test
from vip_chi_readshared_seq import vip_chi_readshared_seq
from vip_chi_readclean_seq import vip_chi_readclean_seq
from vip_chi_readunique_seq import vip_chi_readunique_seq
from vip_chi_tb_pkg import WRITE_READ_ADDR_C

_N_ITERS = 16
_N_LINES = 4
_SEQ_BY_OP = (vip_chi_readshared_seq, vip_chi_readclean_seq, vip_chi_readunique_seq)


class vip_chi_coh_stress_base_test(vip_chi_coherent_base_test):

  async def _drive_stream(self, node, sequencer, rng):
    for i in range(_N_ITERS):
      line_idx = rng.randint(0, _N_LINES - 1)
      op = rng.randint(0, 2)
      addr = WRITE_READ_ADDR_C + line_idx * 0x40
      seq = _SEQ_BY_OP[op](f"s_{node}_{i}", cfg=self.chi_cfg)
      self.cfg_read_seq(seq, addr)
      await seq.start(sequencer)

  async def run_phase(self):
    self.raise_objection()
    await self.wait_reset_settle()

    prime_rs = vip_chi_readshared_seq("prime_rs", cfg=self.chi_cfg)
    self.cfg_read_seq(prime_rs, WRITE_READ_ADDR_C)
    await prime_rs.start(self.tb_env.hrnf0_agent.sequencer)
    prime_ru = vip_chi_readunique_seq("prime_ru", cfg=self.chi_cfg)
    self.cfg_read_seq(prime_ru, WRITE_READ_ADDR_C)
    await prime_ru.start(self.tb_env.hrnf1_agent.sequencer)

    t0 = cocotb.start_soon(self._drive_stream(0, self.tb_env.hrnf0_agent.sequencer, random.Random(0xC0)))
    t1 = cocotb.start_soon(self._drive_stream(1, self.tb_env.hrnf1_agent.sequencer, random.Random(0xF1)))
    await t0
    await t1

    await self.wait_clocks(20)

    ck = self.tb_env.coh_checker
    assert ck.get_multi_owner_count() == 0, \
      f"{ck.get_multi_owner_count()} single-writer violations under stress"
    assert ck.get_coherent_data_mismatch_count() == 0, \
      f"{ck.get_coherent_data_mismatch_count()} coherent data mismatches under stress"
    assert ck.get_snoop_count() != 0, \
      "no snoops fired -- overlapping-line contention was never reached"

    self.logger.info(
      f"Test (coh_stress) PASS: completions={ck.get_completion_count()} "
      f"snoops={ck.get_snoop_count()}, no violations")
    self.drop_objection()
