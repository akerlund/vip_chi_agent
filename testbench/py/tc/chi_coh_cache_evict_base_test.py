################################################################################
# pyUVM port of tc/chi_coh_cache_evict_base_test.sv.
#
# Bound RN-F0's cache to 2 lines, then read three lines Shared: allocating the
# third silently evicts the lowest-address clean line (A). Asserts A is Invalid,
# B and C are held Shared, and no coherency violations.
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import Resp
from chi_coherent_base_test import chi_coherent_base_test
from chi_tb_pkg import WRITE_READ_ADDR_C

_MAX_LINES = 2
_LINE_STRIDE = 0x40   # 64 B coherence granule


class chi_coh_cache_evict_base_test(chi_coherent_base_test):

  def configure_agent_cfgs(self):
    # Bound RN-F0's cache so a third allocation forces a silent eviction.
    self.hrnf0_cfg.rnf_cache_max_lines = _MAX_LINES

  async def _read_shared_line(self, line):
    self.cfg_read_seq(self.hrnf0_rdshared_seq, line)
    await self.hrnf0_rdshared_seq.start(self.tb_env.hrnf0_agent.sequencer)
    self.hrnf0_rdshared_seq.get_responses()

  async def run_phase(self):
    self.raise_objection()
    await self.wait_reset_settle()

    line_a = WRITE_READ_ADDR_C
    line_b = line_a + _LINE_STRIDE
    line_c = line_a + 2 * _LINE_STRIDE

    await self._read_shared_line(line_a)
    await self._read_shared_line(line_b)
    await self._read_shared_line(line_c)

    await self.wait_clocks(8)

    drv = self.tb_env.hrnf0_agent.rnf_driver
    assert drv.get_cache_state(line_a) == int(Resp.I), \
      f"line A (0x{line_a:x}) was not silently evicted (state 0x{drv.get_cache_state(line_a):x})"
    assert drv.get_cache_state(line_b) == int(Resp.SC), \
      f"line B (0x{line_b:x}) not held Shared after eviction"
    assert drv.get_cache_state(line_c) == int(Resp.SC), \
      f"line C (0x{line_c:x}) not held Shared after eviction"
    assert self.tb_env.coh_checker.get_multi_owner_count() == 0, \
      "coherency violations on a bounded-cache silent eviction"

    self.logger.info("Test (coh_cache_evict) PASS")
    self.drop_objection()
