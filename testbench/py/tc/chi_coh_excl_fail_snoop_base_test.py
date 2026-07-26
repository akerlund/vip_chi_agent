################################################################################
# pyUVM port of tc/chi_coh_excl_fail_snoop_base_test.sv.
#
# RN-F0 exclusive load; RN-F1 ReadUnique invalidates RN-F0 (breaking its
# reservation via the snoop); RN-F0 exclusive store then loses -> SC completes
# NormalOkay, RN-F0 ends Invalid, no violations.
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import Resp, RespErr
from chi_coherent_base_test import chi_coherent_base_test
from vip_chi_excl_load_seq import vip_chi_excl_load_seq
from vip_chi_excl_store_seq import vip_chi_excl_store_seq
from chi_tb_pkg import WRITE_READ_ADDR_C


class chi_coh_excl_fail_snoop_base_test(chi_coherent_base_test):

  async def run_phase(self):
    self.raise_objection()
    await self.wait_reset_settle()

    ll_seq = vip_chi_excl_load_seq("hrnf0_ll_seq", cfg=self.chi_cfg)
    self.cfg_read_seq(ll_seq)
    await ll_seq.start(self.tb_env.hrnf0_agent.sequencer)
    ll_rsp = ll_seq.get_responses()

    self.cfg_read_seq(self.hrnf1_rdunique_seq)
    await self.hrnf1_rdunique_seq.start(self.tb_env.hrnf1_agent.sequencer)
    ru_rsp = self.hrnf1_rdunique_seq.get_responses()

    sc_seq = vip_chi_excl_store_seq("hrnf0_sc_seq", cfg=self.chi_cfg)
    self.cfg_read_seq(sc_seq)
    await sc_seq.start(self.tb_env.hrnf0_agent.sequencer)
    sc_rsp = sc_seq.get_responses()

    await self.wait_clocks(8)

    assert len(ll_rsp) == 1 and len(ru_rsp) == 1 and len(sc_rsp) == 1, \
      f"expected 1+1+1 responses, got {len(ll_rsp)}/{len(ru_rsp)}/{len(sc_rsp)}"
    assert int(ll_rsp[0].rsp_resp_err) == int(RespErr.EXOKAY), \
      f"LL completion resperr 0x{int(ll_rsp[0].rsp_resp_err):x}, expected ExclOkay"
    assert int(sc_rsp[0].rsp_resp_err) == int(RespErr.OKAY), \
      f"SC completion resperr 0x{int(sc_rsp[0].rsp_resp_err):x}, expected NormalOkay (store should have LOST)"

    rnf0 = self.tb_env.hrnf0_agent.rnf_driver.get_cache_state(WRITE_READ_ADDR_C)
    assert rnf0 == int(Resp.I), f"RN-F0 cache 0x{rnf0:x} after a LOST SC, expected I"
    assert self.tb_env.coh_checker.get_multi_owner_count() == 0, \
      "coherency violations on a legitimate SC failure"

    self.logger.info("Test (coh_excl_fail_snoop) PASS")
    self.drop_objection()
