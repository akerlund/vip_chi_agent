################################################################################
# pyUVM port of tc/vip_chi_coh_fwd_unique_base_test.sv.
#
# DCT unique forward (hnf_enable_snoop_fwd). RN-F0 ReadUniques; RN-F1 ReadUniques
# the same line -> the home issues SnpUniqueFwd to RN-F0 (which forwards its data
# and invalidates), and relays it as CompData. RN-F0 ends I, RN-F1 ends UC; the
# observed snoop is SnpUniqueFwd carrying the requester's FwdTxnID.
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import Resp, SnpOpcode
from vip_chi_coherent_base_test import vip_chi_coherent_base_test
from vip_chi_tb_pkg import WRITE_READ_ADDR_C


class vip_chi_coh_fwd_unique_base_test(vip_chi_coherent_base_test):

  def configure_agent_cfgs(self):
    self.hnf_cfg.hnf_enable_snoop_fwd = True

  async def run_phase(self):
    self.raise_objection()
    await self.wait_reset_settle()

    self.cfg_read_seq(self.hrnf0_rdunique_seq)
    await self.hrnf0_rdunique_seq.start(self.tb_env.hrnf0_agent.sequencer)
    unique0_rsp = self.hrnf0_rdunique_seq.get_responses()

    self.cfg_read_seq(self.hrnf1_rdunique_seq)
    await self.hrnf1_rdunique_seq.start(self.tb_env.hrnf1_agent.sequencer)
    unique1_rsp = self.hrnf1_rdunique_seq.get_responses()

    assert len(unique0_rsp) == 1 and len(unique1_rsp) == 1, \
      f"expected 1+1 responses, got {len(unique0_rsp)}/{len(unique1_rsp)}"
    assert int(unique1_rsp[0].rsp_resp) == int(Resp.UC), \
      f"ReadUnique granted 0x{int(unique1_rsp[0].rsp_resp):x}, expected UC"
    assert len(unique0_rsp[0].data) == len(unique1_rsp[0].data), "beat-count mismatch"
    for i in range(len(unique1_rsp[0].data)):
      assert int(unique1_rsp[0].data[i]) == int(unique0_rsp[0].data[i]), \
        f"beat {i} forwarded 0x{int(unique1_rsp[0].data[i]):x} != RN-F0 held 0x{int(unique0_rsp[0].data[i]):x}"

    assert self.tb_env.hrnf0_snp_fifo.can_get(), \
      "RN-F0 observed no snoop for the forwarding read"
    snp_item = await self.tb_env.hrnf0_snp_fifo.get()
    assert int(snp_item.snp_opcode) == int(SnpOpcode.UNIQUE_FWD), \
      f"expected SnpUniqueFwd, got snp_opcode 0x{int(snp_item.snp_opcode):x}"
    assert int(snp_item.fwd_txn_id) == int(unique1_rsp[0].txn_id), \
      f"forwarding snoop FwdTxnID 0x{int(snp_item.fwd_txn_id):x} != requester read TxnID 0x{int(unique1_rsp[0].txn_id):x}"

    await self.wait_clocks(8)

    hnf = self.tb_env.hnf_agent.hnf_driver
    assert self.tb_env.hrnf0_agent.rnf_driver.get_cache_state(WRITE_READ_ADDR_C) == int(Resp.I), \
      "RN-F0 cache not I after unique forward"
    assert self.tb_env.hrnf1_agent.rnf_driver.get_cache_state(WRITE_READ_ADDR_C) == int(Resp.UC), \
      "RN-F1 cache not UC"
    assert hnf.get_directory_port_state(WRITE_READ_ADDR_C, 0) == int(Resp.I), \
      "directory port0 not Invalid after unique forward"
    assert hnf.get_directory_port_state(WRITE_READ_ADDR_C, 1) == int(Resp.UC), \
      "directory port1 not UC after unique forward"
    assert self.tb_env.coh_checker.get_multi_owner_count() == 0, \
      "coherency violations on a legal unique forward"

    self.logger.info("Test (coh_fwd_unique) PASS")
    self.drop_objection()
