################################################################################
# pyUVM port of tc/chi_coh_write_unique_ptl_base_test.sv.
#
# RN-F0 takes a Shared copy (captures the pre-write image); RN-F1 does a 16-byte
# WriteUniquePtl at offset 16. Asserts the generated opcode / CompDBIDResp / BE,
# RN-F0 invalidated, a full-line read-back equals the BE-applied expected image
# (differing from the original), no violations.
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import Resp, ReqOpcode, RspOpcode, mask
from chi_coherent_base_test import chi_coherent_base_test
from vip_chi_writeunique_seq import vip_chi_writeunique_seq
from chi_tb_pkg import WRITE_READ_ADDR_C

_WRITE_BYTES = 16
_WRITE_OFFSET_BYTES = 16
_WRITE_SIZE = 4   # 16-byte transfer


class chi_coh_write_unique_ptl_base_test(chi_coherent_base_test):

  async def run_phase(self):
    self.raise_objection()
    await self.wait_reset_settle()

    db = self.chi_cfg.data_bytes
    assert db >= _WRITE_BYTES, \
      f"data_bytes={db} cannot cover the {_WRITE_BYTES}-byte WriteUniquePtl payload"

    write_addr = WRITE_READ_ADDR_C + _WRITE_OFFSET_BYTES

    # 1) RN-F0 takes a Shared copy and captures the pre-write image.
    self.cfg_read_seq(self.hrnf0_rdshared_seq)
    await self.hrnf0_rdshared_seq.start(self.tb_env.hrnf0_agent.sequencer)
    rds_rsp = self.hrnf0_rdshared_seq.get_responses()
    assert len(rds_rsp) == 1, f"expected 1 initial ReadShared response, got {len(rds_rsp)}"
    expected = [int(b) for b in rds_rsp[0].data]

    # 2) RN-F1 performs a 16-byte WriteUniquePtl at offset 16.
    payload = sum((0xA0 + i) << (8 * i) for i in range(_WRITE_BYTES))
    be = mask(_WRITE_BYTES)

    wu_seq = vip_chi_writeunique_seq("hrnf1_wu_ptl_seq", cfg=self.chi_cfg)
    wu_seq.reset()
    wu_seq.set_partial(True)
    wu_seq.set_initial_addr(write_addr)
    wu_seq.set_size(_WRITE_SIZE)
    wu_seq.set_allow_retry(0)
    wu_seq.set_data([payload])
    wu_seq.set_be([be])
    wu_seq.set_get_response(True)
    wu_seq.set_verbose(False)
    await wu_seq.start(self.tb_env.hrnf1_agent.sequencer)
    wu_rsp = wu_seq.get_responses()
    assert len(wu_rsp) == 1, f"expected 1 WriteUniquePtl response, got {len(wu_rsp)}"

    wu = wu_rsp[0]
    assert int(wu.opcode) == int(ReqOpcode.WRITE_UNIQUE_PTL), \
      f"generated opcode 0x{int(wu.opcode):x} instead of WriteUniquePtl"
    assert int(wu.rsp_opcode) == int(RspOpcode.COMP_DBID_RESP), \
      f"WriteUniquePtl completion opcode 0x{int(wu.rsp_opcode):x} was not CompDBIDResp"
    assert len(wu.be) == 1, f"WriteUniquePtl carried {len(wu.be)} BE beats instead of 1"
    assert int(wu.be[0]) == be, f"WriteUniquePtl BE 0x{int(wu.be[0]):x} != expected 0x{be:x}"

    await self.wait_clocks(8)

    assert self.tb_env.hrnf0_agent.rnf_driver.get_cache_state(WRITE_READ_ADDR_C) == int(Resp.I), \
      "RN-F0 not invalidated by WriteUniquePtl"
    assert self.tb_env.hrnf1_agent.rnf_driver.get_cache_state(WRITE_READ_ADDR_C) == int(Resp.I), \
      "RN-F1 cache not Invalid after WriteUniquePtl"
    assert self.tb_env.hrnf0_snp_fifo.can_get(), \
      "RN-F0 never observed the invalidating WriteUniquePtl snoop"
    # drain snoop fifo
    while self.tb_env.hrnf0_snp_fifo.can_get():
      self.tb_env.hrnf0_snp_fifo.try_get()

    # 3) Apply the byte-enabled write to the expected line image.
    for byte_idx in range(_WRITE_BYTES):
      line_byte = _WRITE_OFFSET_BYTES + byte_idx
      beat = line_byte // db
      lane = line_byte % db
      b = (payload >> (8 * byte_idx)) & 0xFF
      expected[beat] = (expected[beat] & ~(0xFF << (8 * lane))) | (b << (8 * lane))

    # 4) Full-line read-back must equal the BE-applied expected image.
    self.cfg_read_seq(self.hrnf0_rdshared_seq)
    await self.hrnf0_rdshared_seq.start(self.tb_env.hrnf0_agent.sequencer)
    rd_rsp = self.hrnf0_rdshared_seq.get_responses()
    assert len(rd_rsp) == 1, f"expected 1 readback response, got {len(rd_rsp)}"
    assert len(rd_rsp[0].data) == len(expected), \
      f"readback beat count {len(rd_rsp[0].data)} != expected {len(expected)}"
    for i in range(len(expected)):
      assert int(rd_rsp[0].data[i]) == expected[i], \
        f"readback beat {i} 0x{int(rd_rsp[0].data[i]):x} != BE-applied expected 0x{expected[i]:x}"

    differs = any(expected[i] != int(rds_rsp[0].data[i]) for i in range(len(expected)))
    assert differs, "WriteUniquePtl expected image equals the original image"
    assert self.tb_env.coh_checker.get_multi_owner_count() == 0, \
      "coherency violations on legal WriteUniquePtl"

    self.logger.info("Test (coh_write_unique_ptl) PASS")
    self.drop_objection()
