################################################################################
# pyUVM/cocotb port of tc/tc_chi_e_signal_drivability.sv.
#
# Exact-CHI-E field-setter smoke: drive a write carrying the full structured REQ
# field set (+ CHI-E DAT tag/tu/tagop) and a separated read carrying the
# ReadNoSnpSep routing fields, verifying each reaches the monitored item; then
# inject an SN-F separated-return CompData + Comp pair (manual injection) and
# verify the responder-side DAT/RSP fields (dat_resp[er], tag/tu/tagop, fwd_state)
# reach the wire.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import (
  Dir, Role, ReqOpcode, DatOpcode, RspOpcode, Resp, RespErr, ReqOrder, mask,
)
from chi_e_base_test import chi_e_base_test
from vip_chi_pipelined_seq import vip_chi_pipelined_seq
from vip_chi_item import vip_chi_item
from chi_tb_pkg import (
  E_DBID_RESP_ORD_ADDR_C, E_DBID_RESP_ORD_RNI_NODE_ID_C,
  E_DBID_RESP_ORD_SNF_NODE_ID_C, E_PERSIST_ADDR_C,
  E_PERSIST_RNI_NODE_ID_C, E_PERSIST_SNF_NODE_ID_C,
  E_MTE_RNI_NODE_ID_C, E_MTE_SNF_NODE_ID_C,
)

NON_SECURE_C = 1
ORDER_RULE_C = "CHI_REQ_ORDER_LEGAL"
ATTR_RULE_C = "CHI_REQ_ATTR_COMBINATION_LEGAL"
LS_RULE_C = "CHI_REQ_LIKELY_SHARED_LEGAL"


class tc_chi_e_signal_drivability(chi_e_base_test):

  # SN-F flits are injected with no matching RN-I request, so the always-on
  # scoreboard would (correctly) flag them as orphans; disable it for this
  # signal-drivability test (mirrors the SV configure_tb_cfg override).
  def configure_tb_cfg(self):
    self.tb_cfg.scoreboard_enable = False

  async def run_phase(self):
    self.raise_objection()

    # This test drives Order = 0b01 on a WRITE, which Table 13-25 marks "Request
    # accepted" and applicable only in a READ request from HN-F to SN-F or HN-I to
    # SN-I -- "Reserved in all other cases". That is deliberate and it is the
    # point: what this test proves is that the field reaches the wire carrying the
    # value the sequence asked for, whatever that value means.
    #
    # But a test whose passing criterion is "a non-conformant request was driven
    # correctly" is indistinguishable, in a regression report, from a test that
    # proves the VIP emits legal traffic. So the rule is turned down to OFF rather
    # than left to fail the run, and the count is asserted at the end. OFF still
    # evaluates and still tallies -- it only suppresses the report -- so the
    # non-conformance stays visible in the end-of-test table instead of silenced.
    #
    # The assertion is the half that matters. If the stimulus is ever changed to a
    # conformant Order, the rule stops firing, that assertion fails, and the
    # waiver comes out with it.
    rni_sva, snf_sva = self.tb_env.rni_sva, self.tb_env.snf_sva
    rni_sva.off_check(ORDER_RULE_C)
    snf_sva.off_check(ORDER_RULE_C)

    # Same waiver, same reason, for the Table 2-12 tuple rule. This test drives
    # MemAttr = 0xC -- Cacheable with EWA deasserted -- and LikelyShared on a
    # WriteNoSnp, and the table lists neither: its Cacheable rows all carry
    # EWA = 1, and LikelyShared is 0/1 only on the two Snoopable rows. IHI 0050 E
    # section 2.9.5 is narrower still and names the opcodes that may assert
    # LikelyShared; WriteNoSnpFull is not among them.
    rni_sva.off_check(ATTR_RULE_C)
    snf_sva.off_check(ATTR_RULE_C)

    # And for the LikelyShared whitelist. Section 2.9.5 names the opcodes that
    # may assert the field and WriteNoSnpFull is not among them, so this is a
    # second, independent reason the same wire bit is non-conformant here -- the
    # tuple rule faults it for being Non-snoopable, this one for the opcode.
    rni_sva.off_check(LS_RULE_C)
    snf_sva.off_check(LS_RULE_C)

    self.drain_observation_fifos()

    # --- Phase 1a: exact-E write carrying the full structured REQ + DAT set ---
    wr = self.rni_wr_seq
    wr.reset()
    wr.set_requests(1)
    wr.set_initial_addr(E_DBID_RESP_ORD_ADDR_C + 0x200)
    wr.set_size(6)
    wr.set_src_id(E_DBID_RESP_ORD_RNI_NODE_ID_C)
    wr.set_tgt_id(E_DBID_RESP_ORD_SNF_NODE_ID_C)
    wr.set_lp_id(0x55)
    wr.set_qos(0xB)
    wr.set_ns(NON_SECURE_C)
    wr.set_order(int(ReqOrder.REQ_ACCEPTED))
    wr.set_mem_attr(0xC)
    wr.set_allow_retry(0)
    wr.set_exp_comp_ack(1)
    wr.set_excl(1)
    wr.set_pcrd_type(0x5)
    wr.set_tracetag(1)
    wr.set_dodwt(1)
    wr.set_likelyshared(1)
    wr.set_endian(1)
    wr.set_group_id_ext(0x2)
    wr.set_tagop(0x1)
    wr.set_dat_tagop(0x2)
    wr.set_tag([0x1234])
    wr.set_tu([0x5])
    wr.set_get_response(True)
    wr.set_verbose(False)
    wr.set_data([0x0123_4567_89AB_CDEF_FEDC_BA98_7654_3210])
    await wr.start(self.tb_env.rni_agent.sequencer)

    req_item = await self.tb_env.rni_req_fifo.get()
    dat_item = await self.tb_env.rni_dat_fifo.get()

    assert (int(req_item.src_id) == E_DBID_RESP_ORD_RNI_NODE_ID_C and
            int(req_item.tgt_id) == E_DBID_RESP_ORD_SNF_NODE_ID_C and
            int(req_item.lp_id) == 0x55 and int(req_item.qos) == 0xB and
            int(req_item.ns) == NON_SECURE_C and
            int(req_item.order) == int(ReqOrder.REQ_ACCEPTED) and
            int(req_item.mem_attr) == 0xC and int(req_item.allow_retry) == 0 and
            int(req_item.exp_comp_ack) == 1 and int(req_item.excl) == 1 and
            int(req_item.pcrd_type) == 0x5 and int(req_item.tracetag) == 1 and
            int(req_item.dodwt) == 1 and int(req_item.likelyshared) == 1 and
            int(req_item.endian) == 1 and int(req_item.group_id_ext) == 0x2 and
            int(req_item.tagop) == 0x1), \
      "REQ setters did not reach the exact-E monitored request item"

    assert (int(dat_item.qos) == 0xB and
            int(dat_item.dat_opcode) == int(DatOpcode.NCB_WR_DATA_COMP_ACK) and
            len(dat_item.data) == 1 and
            int(dat_item.data[0]) == 0x0123_4567_89AB_CDEF_FEDC_BA98_7654_3210 and
            int(dat_item.dat_tagop) == 0x2 and
            len(dat_item.tag) == 1 and int(dat_item.tag[0]) == 0x1234 and
            len(dat_item.tu) == 1 and int(dat_item.tu[0]) == 0x5), \
      "DAT setters did not reach the exact-E monitored DAT item"

    # --- Phase 1b: separated read carrying ReadNoSnpSep routing fields --------
    rd = self.rni_rd_seq
    rd.reset()
    rd.set_requests(1)
    rd.set_initial_addr(E_PERSIST_ADDR_C + 0x100)
    rd.set_size(6)
    rd.set_src_id(E_PERSIST_RNI_NODE_ID_C)
    rd.set_tgt_id(E_PERSIST_SNF_NODE_ID_C)
    rd.set_return_nid(E_PERSIST_RNI_NODE_ID_C)
    rd.set_return_txn_id(0x6A)
    rd.set_qos(0x6)
    rd.set_sep_read(1)
    rd.set_allow_retry(0)
    rd.set_get_response(True)
    rd.set_verbose(False)
    await rd.start(self.tb_env.rni_agent.sequencer)

    req_item = await self.tb_env.rni_req_fifo.get()
    assert (int(req_item.opcode) == int(ReqOpcode.READ_NO_SNP_SEP) and
            int(req_item.return_nid) == E_PERSIST_RNI_NODE_ID_C and
            int(req_item.return_txn_id) == 0x6A and int(req_item.qos) == 0x6), \
      "separated-read setters did not reach the monitored request item"

    # Clear the integrated-harness observations before the manual SN-F phase.
    self.drain_observation_fifos()

    # --- Phase 2: manual SN-F separated-return injection ----------------------
    be_all = mask(self.chi_cfg.data_bytes)

    comp_data_item = vip_chi_item("comp_data_item", cfg=self.chi_cfg)
    comp_data_item.direction = int(Dir.READ)
    comp_data_item.role = int(Role.SNF)
    comp_data_item.src_id = E_MTE_SNF_NODE_ID_C
    comp_data_item.tgt_id = E_MTE_RNI_NODE_ID_C
    comp_data_item.txn_id = 0x71
    comp_data_item.dbid = 0x71
    comp_data_item.dat_opcode = int(DatOpcode.COMP_DATA)
    comp_data_item.rsp_resp = int(Resp.UC)
    comp_data_item.rsp_resp_err = int(RespErr.DERR)
    comp_data_item.qos = 0xD
    comp_data_item.data = [0xFEED_FACE_CAFE_BEEF_DEAD_BEEF_0123_4567]
    comp_data_item.be = [be_all]
    comp_data_item.dat_resp = [int(Resp.UC)]
    comp_data_item.dat_resp_err = [int(RespErr.DERR)]
    comp_data_item.dat_tagop = 0x3
    comp_data_item.tag = [0x4321]
    comp_data_item.tu = [0xA]

    comp_item = vip_chi_item("comp_item", cfg=self.chi_cfg)
    comp_item.direction = int(Dir.READ)
    comp_item.role = int(Role.SNF)
    comp_item.src_id = E_MTE_SNF_NODE_ID_C
    comp_item.tgt_id = E_MTE_RNI_NODE_ID_C
    comp_item.txn_id = 0x72
    comp_item.dbid = 0x72
    comp_item.rsp_opcode = int(RspOpcode.COMP)
    comp_item.rsp_resp = int(Resp.UC)
    comp_item.rsp_resp_err = int(RespErr.NDERR)
    comp_item.fwd_state = 0x5
    comp_item.qos = 0x7

    snf_pipe_seq = vip_chi_pipelined_seq("snf_pipe_seq", cfg=self.chi_cfg)
    snf_pipe_seq.reset()
    snf_pipe_seq.add_item(comp_data_item)
    snf_pipe_seq.add_item(comp_item)
    await snf_pipe_seq.start(self.tb_env.snf_agent.sequencer)

    dat_item = await self.tb_env.snf_dat_fifo.get()
    rsp_item = await self.tb_env.snf_rsp_fifo.get()

    assert (int(dat_item.src_id) == E_MTE_SNF_NODE_ID_C and
            int(dat_item.tgt_id) == E_MTE_RNI_NODE_ID_C and
            int(dat_item.qos) == 0xD and
            len(dat_item.dat_resp) == 1 and int(dat_item.dat_resp[0]) == int(Resp.UC) and
            len(dat_item.dat_resp_err) == 1 and
            int(dat_item.dat_resp_err[0]) == int(RespErr.DERR) and
            int(dat_item.dat_tagop) == 0x3 and
            int(dat_item.tag[0]) == 0x4321 and int(dat_item.tu[0]) == 0xA), \
      "SN-F DAT fields did not reach the monitored DAT item"

    assert (int(rsp_item.src_id) == E_MTE_SNF_NODE_ID_C and
            int(rsp_item.tgt_id) == E_MTE_RNI_NODE_ID_C and
            int(rsp_item.qos) == 0x7 and int(rsp_item.dbid) == 0x72 and
            int(rsp_item.rsp_resp) == int(Resp.UC) and
            int(rsp_item.rsp_resp_err) == int(RespErr.NDERR) and
            int(rsp_item.fwd_state) == 0x5), \
      "SN-F RSP fields did not reach the monitored RSP item"

    self.logger.info(
      "Test (tc_chi_e_signal_drivability) PASS: structured REQ/DAT setters and "
      "manual SN-F DAT/RSP fields all reached the wire")
    rni_fails = rni_sva.fail_count.get(ORDER_RULE_C, 0)
    snf_fails = snf_sva.fail_count.get(ORDER_RULE_C, 0)
    assert rni_fails > 0 and snf_fails > 0, (
      f"{ORDER_RULE_C} did not report the deliberately Reserved Order this test "
      f"drives: rni_e={rni_fails} snf_e={snf_fails}. Either the stimulus is now "
      f"conformant -- in which case drop the waiver above -- or the rule stopped "
      f"evaluating, which is worse")

    rni_attr = rni_sva.fail_count.get(ATTR_RULE_C, 0)
    snf_attr = snf_sva.fail_count.get(ATTR_RULE_C, 0)
    assert rni_attr > 0 and snf_attr > 0, (
      f"{ATTR_RULE_C} did not report the deliberately illegal "
      f"MemAttr/LikelyShared combination this test drives: rni_e={rni_attr} "
      f"snf_e={snf_attr}. Either the stimulus is now conformant -- in which case "
      f"drop the waiver above -- or the rule stopped evaluating, which is worse")

    rni_ls = rni_sva.fail_count.get(LS_RULE_C, 0)
    snf_ls = snf_sva.fail_count.get(LS_RULE_C, 0)
    assert rni_ls > 0 and snf_ls > 0, (
      f"{LS_RULE_C} did not report the LikelyShared this test asserts on a "
      f"WriteNoSnp: rni_e={rni_ls} snf_e={snf_ls}. Either the stimulus is now "
      f"conformant -- in which case drop the waiver above -- or the rule stopped "
      f"evaluating, which is worse")

    self.drop_objection()
