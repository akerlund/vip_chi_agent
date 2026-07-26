################################################################################
# pyUVM port of tc/tc_chi_coh_d_line_granularity.sv (D-only standalone body).
#
# One RN-F ReadShared, then verify the cache + directory report SC for BOTH the
# line-base address and a mid-line address (offset 0x20) -- proving the line key
# is 64 B granular (P1), not data-bus-width granular.
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import Resp
from chi_coherent_base_test import chi_coherent_base_test
from chi_tb_pkg import WRITE_READ_ADDR_C

_MID_LINE_OFFSET = 0x20


class chi_coh_line_granularity_base_test(chi_coherent_base_test):

  async def run_phase(self):
    self.raise_objection()
    await self.wait_reset_settle()

    base_addr = WRITE_READ_ADDR_C
    mid_addr = base_addr + _MID_LINE_OFFSET

    self.cfg_read_seq(self.hrnf0_rdshared_seq, base_addr)
    await self.hrnf0_rdshared_seq.start(self.tb_env.hrnf0_agent.sequencer)
    read_responses = self.hrnf0_rdshared_seq.get_responses()
    assert len(read_responses) == 1, \
      f"expected 1 ReadShared response, got {len(read_responses)}"

    await self.wait_clocks(8)

    drv = self.tb_env.hrnf0_agent.rnf_driver
    hnf = self.tb_env.hnf_agent.hnf_driver
    assert drv.get_cache_state(base_addr) == int(Resp.SC), \
      "RN-F cache at line base not SC"
    assert hnf.get_directory_state(base_addr) == int(Resp.SC), \
      "HN-F directory at line base not SC"
    assert drv.get_cache_state(mid_addr) == int(Resp.SC), \
      "P1: RN-F cache at mid-line not SC -- line key is not 64 B granular"
    assert hnf.get_directory_state(mid_addr) == int(Resp.SC), \
      "P1: HN-F directory at mid-line not SC -- line key is not 64 B granular"

    self.logger.info("Test (coh_line_granularity) PASS")
    self.drop_objection()
