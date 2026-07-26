################################################################################
# pyUVM port of tc/chi_coh_fwd_shared_base_test.sv.
#
# DCT shared forward (hnf_enable_snoop_fwd). RN-F0 ReadUniques a line; RN-F1
# ReadShareds it -> the home issues SnpSharedFwd (FwdTxnID = requester's read
# TxnID) to RN-F0, which forwards its data; the home relays it as CompData. Both
# end SC; the observed snoop is SnpSharedFwd carrying the requester's FwdTxnID.
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import Resp, SnpOpcode
from chi_coherent_base_test import chi_coherent_base_test
from chi_tb_pkg import WRITE_READ_ADDR_C


class chi_coh_fwd_shared_base_test(chi_coherent_base_test):

  def configure_agent_cfgs(self):
    self.hnf_cfg.hnf_enable_snoop_fwd = True

  async def run_phase(self):
    self.raise_objection()
    await self.wait_reset_settle()

    self.cfg_read_seq(self.hrnf0_rdunique_seq)
    await self.hrnf0_rdunique_seq.start(self.tb_env.hrnf0_agent.sequencer)
    unique_rsp = self.hrnf0_rdunique_seq.get_responses()

    self.cfg_read_seq(self.hrnf1_rdshared_seq)
    await self.hrnf1_rdshared_seq.start(self.tb_env.hrnf1_agent.sequencer)
    shared_rsp = self.hrnf1_rdshared_seq.get_responses()

    assert len(unique_rsp) == 1 and len(shared_rsp) == 1, \
      f"expected 1+1 responses, got {len(unique_rsp)}/{len(shared_rsp)}"
    assert int(shared_rsp[0].rsp_resp) == int(Resp.SC), \
      f"ReadShared granted 0x{int(shared_rsp[0].rsp_resp):x}, expected SC"
    assert len(unique_rsp[0].data) == len(shared_rsp[0].data), "beat-count mismatch"
    for i in range(len(shared_rsp[0].data)):
      assert int(shared_rsp[0].data[i]) == int(unique_rsp[0].data[i]), \
        f"beat {i} forwarded 0x{int(shared_rsp[0].data[i]):x} != RN-F0 held 0x{int(unique_rsp[0].data[i]):x}"

    assert self.tb_env.hrnf0_snp_fifo.can_get(), \
      "RN-F0 observed no snoop for the forwarding read"
    snp_item = await self.tb_env.hrnf0_snp_fifo.get()
    assert int(snp_item.snp_opcode) == int(SnpOpcode.SHARED_FWD), \
      f"expected SnpSharedFwd, got snp_opcode 0x{int(snp_item.snp_opcode):x}"
    assert int(snp_item.fwd_txn_id) == int(shared_rsp[0].txn_id), \
      f"forwarding snoop FwdTxnID 0x{int(snp_item.fwd_txn_id):x} != requester read TxnID 0x{int(shared_rsp[0].txn_id):x}"

    await self.wait_clocks(8)

    hnf = self.tb_env.hnf_agent.hnf_driver
    assert self.tb_env.hrnf0_agent.rnf_driver.get_cache_state(WRITE_READ_ADDR_C) == int(Resp.SC), \
      "RN-F0 cache not SC after forwarding"
    assert self.tb_env.hrnf1_agent.rnf_driver.get_cache_state(WRITE_READ_ADDR_C) == int(Resp.SC), \
      "RN-F1 cache not SC"
    assert hnf.get_directory_port_state(WRITE_READ_ADDR_C, 0) == int(Resp.SC), \
      "directory port0 not SC after the shared forward"
    assert hnf.get_directory_port_state(WRITE_READ_ADDR_C, 1) == int(Resp.SC), \
      "directory port1 not SC after the shared forward"
    assert self.tb_env.coh_checker.get_multi_owner_count() == 0, \
      "coherency violations on a legal shared forward"

    self.logger.info("Test (coh_fwd_shared) PASS")
    self.drop_objection()
