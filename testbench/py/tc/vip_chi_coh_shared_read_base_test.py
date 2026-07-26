################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of tc/vip_chi_coh_shared_read_base_test.sv.
#
# Downgrading snoop round-trip. RN-F0 first ReadUniques a line (-> UC), then RN-F1
# ReadShareds the same line. The home must snoop-downgrade RN-F0 to Shared before
# granting RN-F1 a shared copy. Asserts: RN-F1 granted SC, RN-F0 downgraded UC->SC,
# both directory ports SC, and RN-F0 actually observed a snoop.
#
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import Resp
from vip_chi_coherent_base_test import vip_chi_coherent_base_test
from vip_chi_tb_pkg import WRITE_READ_ADDR_C


class vip_chi_coh_shared_read_base_test(vip_chi_coherent_base_test):

  async def run_phase(self):
    self.raise_objection()

    await self.wait_reset_settle()

    # RN-F0 acquires the line Unique.
    self.cfg_read_seq(self.hrnf0_rdunique_seq)
    await self.hrnf0_rdunique_seq.start(self.tb_env.hrnf0_agent.sequencer)
    unique_rsp = self.hrnf0_rdunique_seq.get_responses()

    # RN-F1 then reads Shared, forcing a snoop-downgrade of RN-F0.
    self.cfg_read_seq(self.hrnf1_rdshared_seq)
    await self.hrnf1_rdshared_seq.start(self.tb_env.hrnf1_agent.sequencer)
    shared_rsp = self.hrnf1_rdshared_seq.get_responses()

    assert len(unique_rsp) == 1 and len(shared_rsp) == 1, \
      f"expected 1+1 responses, got {len(unique_rsp)}/{len(shared_rsp)}"
    assert int(shared_rsp[0].rsp_resp) == int(Resp.SC), \
      f"ReadShared granted 0x{int(shared_rsp[0].rsp_resp):x}, expected SC"

    await self.wait_clocks(8)

    rnf0_state = self.tb_env.hrnf0_agent.rnf_driver.get_cache_state(WRITE_READ_ADDR_C)
    rnf1_state = self.tb_env.hrnf1_agent.rnf_driver.get_cache_state(WRITE_READ_ADDR_C)
    assert rnf0_state == int(Resp.SC), \
      f"RN-F0 cache 0x{rnf0_state:x} after downgrading snoop, expected SC"
    assert rnf1_state == int(Resp.SC), \
      f"RN-F1 cache 0x{rnf1_state:x}, expected SC"

    hnf = self.tb_env.hnf_agent.hnf_driver
    assert hnf.get_directory_port_state(WRITE_READ_ADDR_C, 0) == int(Resp.SC), \
      "directory port0 not SC after downgrade"
    assert hnf.get_directory_port_state(WRITE_READ_ADDR_C, 1) == int(Resp.SC), \
      "directory port1 not SC after shared read"

    assert self.tb_env.hrnf0_snp_fifo.can_get(), \
      "RN-F0 never observed the downgrading snoop"

    self.logger.info(
      "Test (coh_shared_read) PASS: ReadUnique then cross-requester ReadShared "
      "snoop-downgraded RN-F0 UC->SC; both ports SC; snoop observed")
    self.drop_objection()
