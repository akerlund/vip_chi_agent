################################################################################
# pyUVM port of tc/vip_chi_coh_reset_mid_snoop_base_test.sv.
#
# Establish cross-requester coherent state (RN-F0 SC, then RN-F1 ReadUnique snoop-
# invalidates -> directory port1 UC), pulse reset, and verify every cache + the
# directory + the checker shadow flush to Invalid/zero, then a recovery ReadShared
# rebuilds SC cleanly.
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import Resp
from vip_chi_coherent_base_test import vip_chi_coherent_base_test
from vip_chi_tb_pkg import WRITE_READ_ADDR_C


class vip_chi_coh_reset_mid_snoop_base_test(vip_chi_coherent_base_test):

  async def run_phase(self):
    self.raise_objection()
    await self.wait_reset_settle()

    self.cfg_read_seq(self.hrnf0_rdshared_seq, WRITE_READ_ADDR_C)
    await self.hrnf0_rdshared_seq.start(self.tb_env.hrnf0_agent.sequencer)
    shared_rsp = self.hrnf0_rdshared_seq.get_responses()

    self.cfg_read_seq(self.hrnf1_rdunique_seq, WRITE_READ_ADDR_C)
    await self.hrnf1_rdunique_seq.start(self.tb_env.hrnf1_agent.sequencer)
    unique_rsp = self.hrnf1_rdunique_seq.get_responses()

    assert len(shared_rsp) == 1 and len(unique_rsp) == 1, \
      f"setup expected 1+1 responses, got {len(shared_rsp)}/{len(unique_rsp)}"
    assert self.tb_env.coh_checker.get_snoop_count() != 0, \
      "no snoop fired before reset -- state not established"
    assert self.tb_env.hnf_agent.hnf_driver.get_directory_port_state(WRITE_READ_ADDR_C, 1) == int(Resp.UC), \
      "directory port1 not UC before reset"

    # Pulse reset (each agent + env + home cascade handle_reset).
    await self.pulse_reset(4)
    await self.wait_clocks(8)

    hnf = self.tb_env.hnf_agent.hnf_driver
    assert self.tb_env.hrnf0_agent.rnf_driver.get_cache_state(WRITE_READ_ADDR_C) == int(Resp.I), \
      "RN-F0 cache not flushed to I after reset"
    assert self.tb_env.hrnf1_agent.rnf_driver.get_cache_state(WRITE_READ_ADDR_C) == int(Resp.I), \
      "RN-F1 cache not flushed to I after reset"
    assert hnf.get_directory_port_state(WRITE_READ_ADDR_C, 0) == int(Resp.I), \
      "directory port0 not flushed to I after reset"
    assert hnf.get_directory_port_state(WRITE_READ_ADDR_C, 1) == int(Resp.I), \
      "directory port1 not flushed to I after reset"
    assert (self.tb_env.coh_checker.get_snoop_count() == 0 and
            self.tb_env.coh_checker.get_completion_count() == 0), \
      "coherency shadow not flushed"

    # Post-reset recovery read.
    self.cfg_read_seq(self.hrnf0_rdshared_seq, WRITE_READ_ADDR_C)
    await self.hrnf0_rdshared_seq.start(self.tb_env.hrnf0_agent.sequencer)
    recov_rsp = self.hrnf0_rdshared_seq.get_responses()
    assert len(recov_rsp) == 1 and int(recov_rsp[0].rsp_resp) == int(Resp.SC), \
      "post-reset recovery read did not complete 1 x SC"
    assert self.tb_env.hrnf0_agent.rnf_driver.get_cache_state(WRITE_READ_ADDR_C) == int(Resp.SC), \
      "RN-F0 cache not SC after post-reset recovery read"

    self.logger.info("Test (coh_reset_mid_snoop) PASS")
    self.drop_objection()
