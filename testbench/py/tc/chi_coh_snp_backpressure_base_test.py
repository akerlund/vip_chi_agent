################################################################################
# pyUVM port of tc/chi_coh_snp_backpressure_base_test.sv.
#
# RN-F0 holds its SNP receive credit; RN-F0 ReadShareds a line (SC), then RN-F1
# ReadUniques it in the background. With RN-F0 withholding SNP credit the home
# cannot deliver the invalidating snoop, so the ReadUnique STALLS. After releasing
# the credit the snoop is delivered, RN-F0 goes I and the ReadUnique completes UC.
################################################################################

from __future__ import annotations

import cocotb

from vip_chi_types_pkg import Resp
from chi_coherent_base_test import chi_coherent_base_test
from chi_tb_pkg import WRITE_READ_ADDR_C


class chi_coh_snp_backpressure_base_test(chi_coherent_base_test):

  def configure_agent_cfgs(self):
    self.hrnf0_cfg.hold_snp_credit = True

  async def run_phase(self):
    self.raise_objection()
    await self.wait_reset_settle()

    self.cfg_read_seq(self.hrnf0_rdshared_seq, WRITE_READ_ADDR_C)
    await self.hrnf0_rdshared_seq.start(self.tb_env.hrnf0_agent.sequencer)
    shared_rsp = self.hrnf0_rdshared_seq.get_responses()
    assert len(shared_rsp) == 1, \
      f"ReadShared setup returned {len(shared_rsp)} responses, expected 1"

    self.cfg_read_seq(self.hrnf1_rdunique_seq, WRITE_READ_ADDR_C)
    self._unique_done = False

    async def _bg():
      await self.hrnf1_rdunique_seq.start(self.tb_env.hrnf1_agent.sequencer)
      self._unique_done = True

    cocotb.start_soon(_bg())

    await self.wait_clocks(60)
    assert not self._unique_done, "ReadUnique completed despite SNP credit starvation"
    assert self.tb_env.hrnf0_agent.rnf_driver.get_cache_state(WRITE_READ_ADDR_C) == int(Resp.SC), \
      "RN-F0 state changed during stall, expected SC (snoop not yet delivered)"
    assert not self.tb_env.hrnf0_snp_fifo.can_get(), \
      "RN-F0 observed a snoop while SNP credits were withheld"

    # Release the SNP receive credit.
    self.hrnf0_cfg.hold_snp_credit = False
    for _ in range(400):
      if self._unique_done:
        break
      await self.wait_clocks(1)
    assert self._unique_done, "ReadUnique never completed after SNP credit release"

    unique_rsp = self.hrnf1_rdunique_seq.get_responses()
    assert len(unique_rsp) == 1 and int(unique_rsp[0].rsp_resp) == int(Resp.UC), \
      "ReadUnique after release did not complete 1 x UC"
    assert self.tb_env.hrnf0_snp_fifo.can_get(), \
      "RN-F0 never observed the snoop after credit release"
    assert self.tb_env.hrnf0_agent.rnf_driver.get_cache_state(WRITE_READ_ADDR_C) == int(Resp.I), \
      "RN-F0 state after snoop, expected I"

    self.logger.info("Test (coh_snp_backpressure) PASS")
    self.drop_objection()
