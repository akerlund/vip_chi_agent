################################################################################
# pyUVM/cocotb port of tc/tc_chi_d_raw_inject.sv.
#
# Inject one raw (verbatim) illegal REQ on the RN-I and one raw DAT/RSP pair on
# the SN-F, then verify the monitors observe the exact flit fields -- proving the
# raw_override path drives arbitrary bit patterns byte-for-byte, bypassing the
# item generator and legality checks.
# Runs under: testbench/py/tb/vip_chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import DatOpcode, RspOpcode, Resp, RespErr, mask
from vip_chi_base_test import vip_chi_base_test
from vip_chi_raw_seq import vip_chi_raw_seq
from vip_chi_tb_pkg import RNI_NODE_ID_C, SNF_NODE_ID_C

NON_SECURE_C = 1


class tc_chi_d_raw_inject(vip_chi_base_test):

  # The raw DAT/RSP flits are deliberately injected with no matching outstanding
  # request, so the always-on scoreboard would (correctly) flag them as orphans.
  # Disable it here -- this test proves the raw_override wire path, not lifecycle.
  def configure_tb_cfg(self):
    self.tb_cfg.scoreboard_enable = False

  async def run_phase(self):
    self.raise_objection()

    self.drain_observation_fifos()

    raw_req = {
      "txnid": 0x61, "srcid": RNI_NODE_ID_C, "tgtid": SNF_NODE_ID_C,
      "opcode": 0x3F, "addr": 0x1234_CAFE000, "size": 2,
      "ns": NON_SECURE_C, "allowretry": 1, "qos": 0x5,
    }
    raw_dat = {
      "data": 0x0123_4567_89AB_CDEF_FEDC_BA98_7654_3210, "be": mask(self.chi_cfg.be_width),
      "dataid": 0, "ccid": 0, "dbid": 0x63,
      "resp": int(Resp.I), "resperr": int(RespErr.OKAY),
      "opcode": int(DatOpcode.COMP_DATA), "txnid": 0x63,
      "srcid": SNF_NODE_ID_C, "tgtid": RNI_NODE_ID_C, "qos": 0x6,
    }
    raw_rsp = {
      "dbid": 0x62, "fwdstate": 0, "resp": int(Resp.I), "resperr": int(RespErr.OKAY),
      "opcode": int(RspOpcode.COMP), "txnid": 0x62,
      "srcid": SNF_NODE_ID_C, "tgtid": RNI_NODE_ID_C, "qos": 0x9,
    }

    rni_raw_seq = vip_chi_raw_seq("rni_raw_seq", cfg=self.chi_cfg)
    rni_raw_seq.reset()
    rni_raw_seq.add_raw_req(raw_req)
    await rni_raw_seq.start(self.v_sqr.rni_sequencer)

    await self.wait_clocks(2)

    snf_raw_seq = vip_chi_raw_seq("snf_raw_seq", cfg=self.chi_cfg)
    snf_raw_seq.reset()
    snf_raw_seq.add_raw_dat(raw_dat)
    snf_raw_seq.add_raw_rsp(raw_rsp)
    await snf_raw_seq.start(self.v_sqr.snf_sequencer)

    req_item = await self.tb_env.rni_req_fifo.get()
    dat_item = await self.tb_env.snf_dat_fifo.get()
    rsp_item = await self.tb_env.snf_rsp_fifo.get()

    assert int(req_item.opcode) == 0x3F, \
      f"monitor observed wrong raw REQ opcode 0x{int(req_item.opcode):x}"
    assert (int(req_item.addr) == 0x1234_CAFE000 and int(req_item.txn_id) == 0x61 and
            int(req_item.qos) == 0x5), \
      "monitor observed wrong raw REQ fields"

    assert len(dat_item.data) == 1, \
      f"monitor observed {len(dat_item.data)} raw DAT beats instead of 1"
    assert (int(dat_item.dat_opcode) == int(DatOpcode.COMP_DATA) and
            int(dat_item.txn_id) == 0x63 and int(dat_item.dbid) == 0x63 and
            int(dat_item.qos) == 0x6 and
            int(dat_item.data[0]) == 0x0123_4567_89AB_CDEF_FEDC_BA98_7654_3210), \
      "monitor observed wrong raw DAT fields"

    assert (int(rsp_item.rsp_opcode) == int(RspOpcode.COMP) and
            int(rsp_item.txn_id) == 0x62 and int(rsp_item.dbid) == 0x62 and
            int(rsp_item.qos) == 0x9), \
      "monitor observed wrong raw RSP fields"

    self.logger.info(
      "Test (tc_chi_d_raw_inject) PASS: raw REQ + DAT/RSP flits reached the "
      "monitors verbatim (raw_override path)")
    self.drop_objection()
