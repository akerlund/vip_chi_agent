################################################################################
# pyUVM port of tc/vip_chi_coh_make_unique_base_test.sv.
#
# Both RN-Fs take a line Shared; RN-F1 MakeUniques it (no data transfer). Asserts
# an RSP-only Comp granting Unique-Dirty, a snoop was originated, RN-F0 + directory
# port0 invalidated, RN-F1 + directory port1 Unique-Dirty, a read-back returns the
# materialized all-zero image (F2), and no coherency violations.
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import Resp, RspOpcode
from vip_chi_coherent_base_test import vip_chi_coherent_base_test
from vip_chi_makeunique_seq import vip_chi_makeunique_seq
from vip_chi_tb_pkg import WRITE_READ_ADDR_C


class vip_chi_coh_make_unique_base_test(vip_chi_coherent_base_test):

  async def run_phase(self):
    self.raise_objection()
    await self.wait_reset_settle()

    # Both RN-Fs take the line Shared.
    self.cfg_read_seq(self.hrnf0_rdshared_seq)
    await self.hrnf0_rdshared_seq.start(self.tb_env.hrnf0_agent.sequencer)
    self.hrnf0_rdshared_seq.get_responses()
    self.cfg_read_seq(self.hrnf1_rdshared_seq)
    await self.hrnf1_rdshared_seq.start(self.tb_env.hrnf1_agent.sequencer)
    self.hrnf1_rdshared_seq.get_responses()

    snoops_before = self.tb_env.coh_checker.get_snoop_count()

    # RN-F1 acquires the line Unique via MakeUnique (no data transfer).
    mu_seq = vip_chi_makeunique_seq("hrnf1_mu_seq", cfg=self.chi_cfg)
    self.cfg_read_seq(mu_seq)
    await mu_seq.start(self.tb_env.hrnf1_agent.sequencer)
    mu_rsp = mu_seq.get_responses()

    await self.wait_clocks(8)

    assert len(mu_rsp) == 1, f"MakeUnique expected 1 completion, got {len(mu_rsp)}"
    assert int(mu_rsp[0].rsp_opcode) == int(RspOpcode.COMP), \
      f"MakeUnique completion opcode 0x{int(mu_rsp[0].rsp_opcode):x} was not Comp"
    assert len(mu_rsp[0].data) == 0, \
      f"MakeUnique returned {len(mu_rsp[0].data)} data beats, expected 0 (RSP-only Comp)"
    assert int(mu_rsp[0].rsp_resp) == int(Resp.UD_PD), \
      f"MakeUnique granted resp 0x{int(mu_rsp[0].rsp_resp):x}, expected Unique-Dirty"
    assert self.tb_env.coh_checker.get_snoop_count() > snoops_before, \
      "MakeUnique originated no snoop"

    hnf = self.tb_env.hnf_agent.hnf_driver
    assert self.tb_env.hrnf0_agent.rnf_driver.get_cache_state(WRITE_READ_ADDR_C) == int(Resp.I), \
      "RN-F0 cache not Invalid after MakeUnique"
    assert hnf.get_directory_port_state(WRITE_READ_ADDR_C, 0) == int(Resp.I), \
      "directory port0 not Invalid after MakeUnique"
    assert self.tb_env.hrnf1_agent.rnf_driver.get_cache_state(WRITE_READ_ADDR_C) == int(Resp.UD_PD), \
      "RN-F1 cache not Unique-Dirty after MakeUnique"
    assert hnf.get_directory_port_state(WRITE_READ_ADDR_C, 1) == int(Resp.UD_PD), \
      "directory port1 not Unique-Dirty after MakeUnique"

    # F2: read the freshly-made line back -> materialized all-zero image.
    self.cfg_read_seq(self.hrnf0_rdshared_seq)
    await self.hrnf0_rdshared_seq.start(self.tb_env.hrnf0_agent.sequencer)
    rd_rsp = self.hrnf0_rdshared_seq.get_responses()
    assert len(rd_rsp) == 1, f"read-after-MakeUnique expected 1 response, got {len(rd_rsp)}"
    for i in range(len(rd_rsp[0].data)):
      assert int(rd_rsp[0].data[i]) == 0, \
        f"read-after-MakeUnique beat {i} = 0x{int(rd_rsp[0].data[i]):x}, expected all-zero image"

    assert self.tb_env.coh_checker.get_multi_owner_count() == 0, \
      "coherency violations on legal MakeUnique"

    self.logger.info("Test (coh_make_unique) PASS")
    self.drop_objection()
