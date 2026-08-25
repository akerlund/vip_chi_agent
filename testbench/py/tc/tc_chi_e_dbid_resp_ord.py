################################################################################
# pyUVM/cocotb port of tc/tc_chi_e_dbid_resp_ord.sv.
#
# CHI-E ordered WriteNoSnpFull with ExpCompAck against a split-write SN-F that
# has ordered_dbid_resp enabled: the grant is DBIDRespOrd, followed by the
# deferred Comp and the RN-I CompAck. Write data is NCBWrDataCompAck.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import Role, DataType, ReqOrder, RspOpcode, DatOpcode
from chi_e_base_test import chi_e_base_test
from chi_tb_pkg import (
  E_DBID_RESP_ORD_ADDR_C, E_DBID_RESP_ORD_RNI_NODE_ID_C, E_DBID_RESP_ORD_SNF_NODE_ID_C,
)


class tc_chi_e_dbid_resp_ord(chi_e_base_test):

  def configure(self, rni_cfg, snf_cfg):
    snf_cfg.split_write_rsp = True
    snf_cfg.ordered_dbid_resp = True

  async def run_phase(self):
    self.raise_objection()

    wr = self.rni_wr_seq
    wr.reset()
    wr.set_requests(1)
    wr.set_initial_addr(E_DBID_RESP_ORD_ADDR_C)
    wr.set_size(6)
    wr.set_src_id(E_DBID_RESP_ORD_RNI_NODE_ID_C)
    wr.set_tgt_id(E_DBID_RESP_ORD_SNF_NODE_ID_C)
    wr.set_qos(0xE)
    wr.set_order(int(ReqOrder.REQ_ORDER))
    wr.set_exp_comp_ack(1)
    wr.set_data_type(DataType.COUNTER)
    wr.set_counter_value(0x90)
    wr.set_counter_increment(0x1)
    wr.set_get_response(True)
    wr.set_verbose(False)
    await wr.start(self.tb_env.rni_agent.sequencer)

    write_responses = wr.get_responses()
    assert len(write_responses) == 1

    req_item = await self.tb_env.rni_req_fifo.get()
    dat_item = await self.tb_env.rni_dat_fifo.get()
    rsp_items = [await self.tb_env.rni_rsp_fifo.get() for _ in range(3)]

    assert int(req_item.order) == int(ReqOrder.REQ_ORDER)
    assert int(dat_item.dat_opcode) == int(DatOpcode.NCB_WR_DATA_COMP_ACK)
    assert int(rsp_items[0].rsp_opcode) == int(RspOpcode.DBID_RESP_ORD)
    assert int(rsp_items[1].rsp_opcode) == int(RspOpcode.COMP)
    assert int(rsp_items[2].rsp_opcode) == int(RspOpcode.COMP_ACK)
    assert int(rsp_items[0].role) == int(Role.SNF)
    assert int(rsp_items[1].role) == int(Role.SNF)
    assert int(rsp_items[2].role) == int(Role.RNI)
    assert int(rsp_items[0].dbid) == int(req_item.txn_id)
    assert int(rsp_items[1].dbid) == int(req_item.txn_id)
    assert int(rsp_items[2].txn_id) == int(req_item.txn_id)
    assert int(write_responses[0].rsp_opcode) == int(RspOpcode.COMP)
    assert int(write_responses[0].dbid) == int(req_item.txn_id)

    # Appendix B, both directions of the claim.
    #
    # Table B-3 gives DBIDRespOrd ONE From row, ICN(HN-F, HN-I, MN), while plain
    # DBIDResp has three including "SN-F -> ... RN-I". So the response this test
    # exists to prove is one a Slave may not send in a real system: section 2.6
    # makes it a Point of Serialization guarantee, and a Slave is not the PoS
    # for other Requesters. On this two-node link it is the only ordering point
    # there is, which is why the checker grants it the stand-in -- and why the
    # grant has to be visible rather than assumed.
    #
    # CHI_SB_ORIGINATOR_LEGAL found this on its first sweep, in the SystemVerilog
    # port, before anyone had read Table B-3 for DBIDRespOrd.
    sb = self.tb_env.scoreboard
    assert sb.n_originator_illegal == 0, (
      f"Appendix B reported {sb.n_originator_illegal} violation(s) on ordered "
      f"write traffic the stand-in is supposed to cover")
    standin_after_traffic = sb.n_originator_standin
    assert standin_after_traffic >= 1, (
      "the completer-side stand-in never fired, so this test proves nothing "
      "about DBIDRespOrd's originator")

    # And the other direction: with the stand-in switched off the same response
    # must be REPORTED. Without this the assertion above is satisfied by a rule
    # that permits DBIDRespOrd from anyone.
    sb.home_standin = False
    self.drain_observation_fifos()

    wr.reset()
    wr.set_requests(1)
    wr.set_initial_addr(E_DBID_RESP_ORD_ADDR_C + 0x100)
    wr.set_size(6)
    wr.set_src_id(E_DBID_RESP_ORD_RNI_NODE_ID_C)
    wr.set_tgt_id(E_DBID_RESP_ORD_SNF_NODE_ID_C)
    wr.set_order(int(ReqOrder.REQ_ORDER))
    wr.set_exp_comp_ack(1)
    wr.set_get_response(True)
    wr.set_verbose(False)
    await wr.start(self.tb_env.rni_agent.sequencer)
    await self.wait_clocks(20)

    assert sb.n_originator_illegal > 0, (
      "with the Home stand-in switched off, a Slave's DBIDRespOrd must be "
      "reported: Table B-3 permits it from the ICN only")
    assert sb.n_originator_standin == standin_after_traffic, (
      "the stand-in fired again after being switched off")

    self.logger.info(
      f"Test (tc_chi_e_dbid_resp_ord) PASS: DBIDRespOrd covered by the "
      f"completer-side Home stand-in {standin_after_traffic} time(s), and "
      f"reported {sb.n_originator_illegal} time(s) with it off")
    self.drop_objection()
