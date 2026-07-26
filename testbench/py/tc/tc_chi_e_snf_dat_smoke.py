################################################################################
# pyUVM/cocotb port of tc/tc_chi_e_snf_dat_smoke.sv.
#
# Drive one exact-CHI-E data completion from the real SN-F agent via manual
# injection (the RN-I peer is present only to bring the link up and return
# credits) and verify the monitored DAT item preserves the responder-side DAT
# tagging fields (dat_tagop / tag / tu) and routing, followed by a bare Comp RSP.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import (
  Dir, Role, DatOpcode, RspOpcode, Resp, RespErr, mask,
)
from chi_e_base_test import chi_e_base_test
from vip_chi_pipelined_seq import vip_chi_pipelined_seq
from vip_chi_item import vip_chi_item


class tc_chi_e_snf_dat_smoke(chi_e_base_test):

  # SN-F flits are injected with no matching RN-I request, so the always-on
  # scoreboard would (correctly) flag them as orphans; disable it for this
  # wire-path smoke test (mirrors the SV configure_tb_cfg override).
  def configure_tb_cfg(self):
    self.tb_cfg.scoreboard_enable = False

  async def run_phase(self):
    self.raise_objection()

    be_all = mask(self.chi_cfg.data_bytes)

    comp_data_item = vip_chi_item("comp_data_item", cfg=self.chi_cfg)
    comp_data_item.direction = int(Dir.READ)
    comp_data_item.role = int(Role.SNF)
    comp_data_item.src_id = 0x031
    comp_data_item.tgt_id = 0x012
    comp_data_item.txn_id = 0x51
    comp_data_item.dbid = 0x51
    comp_data_item.dat_opcode = int(DatOpcode.COMP_DATA)
    comp_data_item.rsp_resp = int(Resp.I)
    comp_data_item.rsp_resp_err = int(RespErr.OKAY)
    comp_data_item.qos = 0xE
    comp_data_item.data = [0x1_2233_4455_6677_8899_AABB_CCDD_EEFF]
    comp_data_item.be = [be_all]
    comp_data_item.dat_tagop = 0x2
    comp_data_item.tag = [0x2345]
    comp_data_item.tu = [0xC]

    comp_item = vip_chi_item("comp_item", cfg=self.chi_cfg)
    comp_item.direction = int(Dir.READ)
    comp_item.role = int(Role.SNF)
    comp_item.src_id = 0x031
    comp_item.tgt_id = 0x012
    comp_item.txn_id = 0x52
    comp_item.dbid = 0x52
    comp_item.rsp_opcode = int(RspOpcode.COMP)
    comp_item.rsp_resp = int(Resp.I)
    comp_item.rsp_resp_err = int(RespErr.OKAY)
    comp_item.fwd_state = 0
    comp_item.qos = 0x7

    snf_pipe_seq = vip_chi_pipelined_seq("snf_pipe_seq", cfg=self.chi_cfg)
    snf_pipe_seq.reset()
    snf_pipe_seq.add_item(comp_data_item)
    snf_pipe_seq.add_item(comp_item)
    await snf_pipe_seq.start(self.tb_env.snf_agent.sequencer)

    dat_item = await self.tb_env.snf_dat_fifo.get()
    rsp_item = await self.tb_env.snf_rsp_fifo.get()

    assert int(dat_item.role) == int(Role.SNF), \
      f"monitor observed wrong DAT role {int(dat_item.role)}"
    assert int(dat_item.dat_opcode) == int(DatOpcode.COMP_DATA), \
      f"monitor observed wrong DAT opcode 0x{int(dat_item.dat_opcode):x}"
    assert (int(dat_item.src_id) == 0x031 and int(dat_item.tgt_id) == 0x012 and
            int(dat_item.qos) == 0xE), \
      "monitor observed wrong exact-CHI-E SN-F DAT routing fields"
    assert (int(dat_item.dat_tagop) == 0x2 and
            len(dat_item.tag) == 1 and int(dat_item.tag[0]) == 0x2345 and
            len(dat_item.tu) == 1 and int(dat_item.tu[0]) == 0xC), \
      "monitor observed wrong exact-CHI-E SN-F DAT tagging fields"

    assert int(rsp_item.rsp_opcode) == int(RspOpcode.COMP), \
      f"monitor observed wrong RSP opcode 0x{int(rsp_item.rsp_opcode):x}"
    assert (int(rsp_item.src_id) == 0x031 and int(rsp_item.tgt_id) == 0x012 and
            int(rsp_item.qos) == 0x7), \
      "monitor observed wrong exact-CHI-E SN-F RSP fields"

    self.logger.info(
      "Test (tc_chi_e_snf_dat_smoke) PASS: manual SN-F CompData preserved DAT "
      "tagging + routing, followed by a Comp RSP")
    self.drop_objection()
