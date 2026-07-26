################################################################################
# pyUVM port of tc/chi_coh_read_once_base_test.sv.
#
# RN-F0 ReadUniques + locally dirties a line; RN-F1 ReadOnces it -- a snapshot
# that must forward RN-F0's CURRENT (dirty) data without changing RN-F0's state or
# allocating at RN-F1. Asserts ReadOnce granted I, returned data = orig ^ pattern,
# RN-F0 keeps UD, RN-F1 stays I, directory port1 I, snoop observed, no violations.
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import Resp
from chi_coherent_base_test import chi_coherent_base_test
from vip_chi_readonce_seq import vip_chi_readonce_seq
from chi_tb_pkg import WRITE_READ_ADDR_C


class chi_coh_read_once_base_test(chi_coherent_base_test):

  async def run_phase(self):
    self.raise_objection()
    await self.wait_reset_settle()

    dirty_pattern = int("C3" * self.chi_cfg.data_bytes, 16)

    # 1) RN-F0 acquires the line Unique and caches the granted beats.
    self.cfg_read_seq(self.hrnf0_rdunique_seq)
    await self.hrnf0_rdunique_seq.start(self.tb_env.hrnf0_agent.sequencer)
    unique_rsp = self.hrnf0_rdunique_seq.get_responses()

    # 2) Model a local store: dirty RN-F0's cached line.
    self.tb_env.hrnf0_agent.rnf_driver.make_line_dirty(WRITE_READ_ADDR_C, dirty_pattern)

    # 3) RN-F1 ReadOnces: a snapshot forwarding RN-F0's current (dirty) data.
    ro_seq = vip_chi_readonce_seq("hrnf1_ro_seq", cfg=self.chi_cfg)
    self.cfg_read_seq(ro_seq)
    await ro_seq.start(self.tb_env.hrnf1_agent.sequencer)
    once_rsp = ro_seq.get_responses()

    assert len(unique_rsp) == 1 and len(once_rsp) == 1, \
      f"expected 1+1 responses, got {len(unique_rsp)}/{len(once_rsp)}"
    assert int(once_rsp[0].rsp_resp) == int(Resp.I), \
      f"ReadOnce granted 0x{int(once_rsp[0].rsp_resp):x}, expected I (no ownership)"
    assert len(once_rsp[0].data) != 0, "ReadOnce completed with no data beats"
    assert len(unique_rsp[0].data) == len(once_rsp[0].data), \
      f"beat-count mismatch: unique {len(unique_rsp[0].data)} vs once {len(once_rsp[0].data)}"
    for i in range(len(once_rsp[0].data)):
      exp = int(unique_rsp[0].data[i]) ^ dirty_pattern
      assert int(once_rsp[0].data[i]) == exp, \
        f"beat {i} ReadOnce returned 0x{int(once_rsp[0].data[i]):x}, expected current 0x{exp:x}"

    await self.wait_clocks(8)

    rnf0 = self.tb_env.hrnf0_agent.rnf_driver.get_cache_state(WRITE_READ_ADDR_C)
    rnf1 = self.tb_env.hrnf1_agent.rnf_driver.get_cache_state(WRITE_READ_ADDR_C)
    assert rnf0 == int(Resp.UD_PD), \
      f"RN-F0 cache 0x{rnf0:x} after SnpOnce, expected UD (preserved)"
    assert rnf1 == int(Resp.I), \
      f"RN-F1 cache 0x{rnf1:x} after ReadOnce, expected I (non-allocating)"
    assert self.tb_env.hnf_agent.hnf_driver.get_directory_port_state(WRITE_READ_ADDR_C, 1) == int(Resp.I), \
      "directory port1 not Invalid after ReadOnce (must not allocate)"
    assert self.tb_env.hrnf0_snp_fifo.can_get(), "RN-F0 never observed the SnpOnce"
    assert self.tb_env.coh_checker.get_multi_owner_count() == 0, \
      "coherency violations on a legal ReadOnce"

    self.logger.info("Test (coh_read_once) PASS")
    self.drop_objection()
