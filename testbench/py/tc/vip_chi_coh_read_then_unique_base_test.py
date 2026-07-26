################################################################################
# pyUVM port of tc/vip_chi_coh_read_then_unique_base_test.sv.
#
# RN-F0 ReadShareds a line (-> SC), then RN-F1 ReadUniques it, forcing a snoop-
# invalidate of RN-F0. Asserts RN-F1 granted UC, RN-F0 invalidated, directory
# ports {I, UC}, and RN-F0 observed the invalidating snoop.
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import Resp
from vip_chi_coherent_base_test import vip_chi_coherent_base_test
from vip_chi_tb_pkg import WRITE_READ_ADDR_C


class vip_chi_coh_read_then_unique_base_test(vip_chi_coherent_base_test):

  async def run_phase(self):
    self.raise_objection()
    await self.wait_reset_settle()

    self.cfg_read_seq(self.hrnf0_rdshared_seq)
    await self.hrnf0_rdshared_seq.start(self.tb_env.hrnf0_agent.sequencer)
    shared_rsp = self.hrnf0_rdshared_seq.get_responses()

    self.cfg_read_seq(self.hrnf1_rdunique_seq)
    await self.hrnf1_rdunique_seq.start(self.tb_env.hrnf1_agent.sequencer)
    unique_rsp = self.hrnf1_rdunique_seq.get_responses()

    assert len(shared_rsp) == 1 and len(unique_rsp) == 1, \
      f"expected 1+1 responses, got {len(shared_rsp)}/{len(unique_rsp)}"
    assert int(unique_rsp[0].rsp_resp) == int(Resp.UC), \
      f"ReadUnique granted 0x{int(unique_rsp[0].rsp_resp):x}, expected UC"

    await self.wait_clocks(8)

    rnf0 = self.tb_env.hrnf0_agent.rnf_driver.get_cache_state(WRITE_READ_ADDR_C)
    rnf1 = self.tb_env.hrnf1_agent.rnf_driver.get_cache_state(WRITE_READ_ADDR_C)
    assert rnf0 == int(Resp.I), f"RN-F0 cache 0x{rnf0:x} after invalidating snoop, expected I"
    assert rnf1 == int(Resp.UC), f"RN-F1 cache 0x{rnf1:x}, expected UC"

    hnf = self.tb_env.hnf_agent.hnf_driver
    assert hnf.get_directory_port_state(WRITE_READ_ADDR_C, 0) == int(Resp.I), \
      "directory port0 not Invalid after unique grant to port1"
    assert hnf.get_directory_port_state(WRITE_READ_ADDR_C, 1) == int(Resp.UC), \
      "directory port1 not UC after unique grant"
    assert self.tb_env.hrnf0_snp_fifo.can_get(), \
      "RN-F0 never observed the invalidating snoop"

    self.logger.info("Test (coh_read_then_unique) PASS")
    self.drop_objection()
