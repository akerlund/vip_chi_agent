################################################################################
# pyUVM port of tc/vip_chi_coh_fwd_dirty_base_test.sv.
#
# DCT dirty forward (hnf_enable_snoop_fwd). RN-F0 ReadUniques + dirties a line;
# RN-F1 ReadShareds it -> SnpSharedFwd, RN-F0 forwards its dirtied data, the home
# relays it AND merges to memory. Both end SC; a read-back returns the merged dirty
# data.
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import Resp, SnpOpcode
from vip_chi_coherent_base_test import vip_chi_coherent_base_test
from vip_chi_tb_pkg import WRITE_READ_ADDR_C


class vip_chi_coh_fwd_dirty_base_test(vip_chi_coherent_base_test):

  def configure_agent_cfgs(self):
    self.hnf_cfg.hnf_enable_snoop_fwd = True

  async def run_phase(self):
    self.raise_objection()
    await self.wait_reset_settle()

    dirty_pattern = int("3C" * self.chi_cfg.data_bytes, 16)

    self.cfg_read_seq(self.hrnf0_rdunique_seq)
    await self.hrnf0_rdunique_seq.start(self.tb_env.hrnf0_agent.sequencer)
    unique_rsp = self.hrnf0_rdunique_seq.get_responses()
    self.tb_env.hrnf0_agent.rnf_driver.make_line_dirty(WRITE_READ_ADDR_C, dirty_pattern)

    self.cfg_read_seq(self.hrnf1_rdshared_seq)
    await self.hrnf1_rdshared_seq.start(self.tb_env.hrnf1_agent.sequencer)
    shared_rsp = self.hrnf1_rdshared_seq.get_responses()

    assert len(unique_rsp) == 1 and len(shared_rsp) == 1, \
      f"expected 1+1 responses, got {len(unique_rsp)}/{len(shared_rsp)}"
    assert int(shared_rsp[0].rsp_resp) == int(Resp.SC), \
      f"ReadShared granted 0x{int(shared_rsp[0].rsp_resp):x}, expected SC"
    assert len(unique_rsp[0].data) == len(shared_rsp[0].data), "beat-count mismatch"
    for i in range(len(shared_rsp[0].data)):
      exp = int(unique_rsp[0].data[i]) ^ dirty_pattern
      assert int(shared_rsp[0].data[i]) == exp, \
        f"beat {i} forwarded 0x{int(shared_rsp[0].data[i]):x}, expected dirtied 0x{exp:x}"

    assert self.tb_env.hrnf0_snp_fifo.can_get(), \
      "RN-F0 observed no snoop for the forwarding read"
    snp_item = await self.tb_env.hrnf0_snp_fifo.get()
    assert int(snp_item.snp_opcode) == int(SnpOpcode.SHARED_FWD), \
      f"expected SnpSharedFwd, got snp_opcode 0x{int(snp_item.snp_opcode):x}"
    assert int(snp_item.fwd_txn_id) == int(shared_rsp[0].txn_id), \
      "forwarding snoop FwdTxnID != requester read TxnID"

    await self.wait_clocks(8)

    assert self.tb_env.hrnf0_agent.rnf_driver.get_cache_state(WRITE_READ_ADDR_C) == int(Resp.SC), \
      "RN-F0 cache not SC after passing dirty data via fwd"
    assert self.tb_env.hrnf1_agent.rnf_driver.get_cache_state(WRITE_READ_ADDR_C) == int(Resp.SC), \
      "RN-F1 cache not SC"

    # Read-back must return the merged dirty data.
    self.cfg_read_seq(self.hrnf1_rdshared_seq)
    await self.hrnf1_rdshared_seq.start(self.tb_env.hrnf1_agent.sequencer)
    readback_rsp = self.hrnf1_rdshared_seq.get_responses()
    assert len(readback_rsp) == 1, f"expected 1 read-back response, got {len(readback_rsp)}"
    for i in range(len(readback_rsp[0].data)):
      exp = int(unique_rsp[0].data[i]) ^ dirty_pattern
      assert int(readback_rsp[0].data[i]) == exp, \
        f"beat {i} read-back 0x{int(readback_rsp[0].data[i]):x}, expected merged dirty 0x{exp:x}"

    assert self.tb_env.coh_checker.get_multi_owner_count() == 0, \
      "coherency violations on a legal dirty forward"

    self.logger.info("Test (coh_fwd_dirty) PASS")
    self.drop_objection()
