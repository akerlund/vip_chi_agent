################################################################################
# pyUVM port of tc/vip_chi_coh_snf_read_miss_base_test.sv.
#
# Two-level hierarchy (hnf_downstream_en): a ReadShared misses the HN-F's local
# memory, so the home fetches the line from the downstream SN-F with exactly one
# ReadNoSnp (to WRITE_READ_ADDR_C) and fills before completing. Asserts SC + data,
# exactly 1 downstream ReadNoSnp, no violations.
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import Resp, ReqOpcode
from vip_chi_coherent_base_test import vip_chi_coherent_base_test
from vip_chi_tb_pkg import WRITE_READ_ADDR_C


class vip_chi_coh_snf_read_miss_base_test(vip_chi_coherent_base_test):

  def configure_agent_cfgs(self):
    self.hnf_cfg.hnf_downstream_en = True

  async def run_phase(self):
    self.raise_objection()
    await self.wait_reset_settle()

    self.cfg_read_seq(self.hrnf0_rdshared_seq)
    await self.hrnf0_rdshared_seq.start(self.tb_env.hrnf0_agent.sequencer)
    shared_rsp = self.hrnf0_rdshared_seq.get_responses()

    await self.wait_clocks(8)

    assert len(shared_rsp) == 1, f"expected 1 response, got {len(shared_rsp)}"
    assert int(shared_rsp[0].rsp_resp) == int(Resp.SC), \
      f"ReadShared granted 0x{int(shared_rsp[0].rsp_resp):x}, expected SC"
    assert len(shared_rsp[0].data) != 0, "ReadShared returned no data beats"

    n_dn = 0
    while self.tb_env.dsnf0_req_fifo.can_get():
      dn = await self.tb_env.dsnf0_req_fifo.get()
      n_dn += 1
      assert int(dn.opcode) == int(ReqOpcode.READ_NO_SNP), \
        f"downstream REQ opcode 0x{int(dn.opcode):x}, expected ReadNoSnp"
      assert int(dn.addr) == WRITE_READ_ADDR_C, \
        f"downstream ReadNoSnp addr 0x{int(dn.addr):x}, expected 0x{WRITE_READ_ADDR_C:x}"
    assert n_dn == 1, f"SN-F saw {n_dn} downstream REQs, expected exactly 1 ReadNoSnp"

    assert (self.tb_env.coh_checker.get_multi_owner_count() == 0 and
            self.tb_env.coh_checker.get_coherent_data_mismatch_count() == 0), \
      "coherency violation on a legal downstream fetch"

    self.logger.info("Test (coh_snf_read_miss) PASS")
    self.drop_objection()
