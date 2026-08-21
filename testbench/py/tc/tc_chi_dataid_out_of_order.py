################################################################################
# pyUVM/cocotb port of tc/tc_chi_dataid_out_of_order.sv.
#
# CHI identifies a data beat's position by its DataID, not by where it sits in
# the burst, so a completer may return the beats of one transfer in any order.
# With cfg.snf_reverse_dat_beats the SN-F returns them in DESCENDING DataID: the
# payload must still reassemble in address order, both in the item the monitor
# publishes and in the response the sequence reads back. Reassembling by arrival
# instead would leave both reversed and surface as a data mismatch pointing at
# the data path rather than at the reassembly.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import Role, ReqOpcode, DatOpcode
from chi_base_test import chi_base_test
from chi_tb_pkg import READ_ADDR_C

BEATS_C = 4     # size 6 = 64 bytes over a 16-byte CHI-D data bus


class tc_chi_dataid_out_of_order(chi_base_test):

  def configure(self, rni_cfg, snf_cfg):
    snf_cfg.snf_reverse_dat_beats = True

  def configure_tb_cfg(self):
    # Reversing the beat order is legal -- DataID carries the position -- but it
    # is not this VIP's own emission convention, which the protocol checkers'
    # DataID-ordering rules hold by default. Stand them down for this test; the
    # beat-count, TxnID and credit rules keep checking.
    self.tb_cfg.dat_reorder_allowed = True

  async def run_phase(self):
    self.raise_objection()

    rd = self.rni0_rd_seq
    rd.reset()
    rd.set_requests(1)
    rd.set_initial_addr(READ_ADDR_C)
    rd.set_size(6)
    rd.set_get_response(True)
    rd.set_verbose(False)
    await rd.start(self.v_sqr.rni_sequencer)

    responses = rd.get_responses()
    assert len(responses) == 1, f"expected 1 read response, got {len(responses)}"
    rsp = responses[0]

    req_item = await self.tb_env.rni_req_fifo.get()
    dat_item = await self.tb_env.rni_dat_fifo.get()

    assert int(req_item.opcode) == int(ReqOpcode.READ_NO_SNP)
    assert int(dat_item.role) == int(Role.SNF)
    assert int(dat_item.dat_opcode) == int(DatOpcode.COMP_DATA)

    # Anti-vacuity: the completer really is emitting the positions in reverse,
    # so the payload check below is testing reassembly and not just an in-order
    # burst that would pass either way.
    snf = self.tb_env.snf_agent.snf_driver
    assert [snf.dat_beat_position(i, BEATS_C) for i in range(BEATS_C)] == \
      list(range(BEATS_C - 1, -1, -1)), \
      "SN-F did not reverse the DAT beat order -- the scenario is vacuous"

    assert len(dat_item.data) == BEATS_C, \
      f"monitor reassembled {len(dat_item.data)} beats, expected {BEATS_C}"
    assert [int(d) for d in dat_item.data_id] == list(range(BEATS_C)), \
      f"beats were not placed by DataID: {[int(d) for d in dat_item.data_id]}"

    # Payload in ADDRESS order despite arrival in reverse order.
    for i in range(BEATS_C):
      assert int(dat_item.data[i]) == (READ_ADDR_C + i), \
        f"monitor beat {i} payload 0x{int(dat_item.data[i]):x}"
      assert int(rsp.data[i]) == (READ_ADDR_C + i), \
        f"sequence response beat {i} payload 0x{int(rsp.data[i]):x}"

    # Reassembling a legal reordering is not a protocol violation.
    mon = self.tb_env.rni_agent.monitor
    assert mon.n_dataid_violation == 0, \
      f"legal out-of-order burst raised {mon.n_dataid_violation} DataID violations"

    self.logger.info("Test (tc_chi_dataid_out_of_order) PASS")
    self.drop_objection()
