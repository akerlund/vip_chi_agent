################################################################################
# pyUVM/cocotb port of tc/tc_chi_d_reset.sv.
#
# Reset a link while a read is parked in flight (DAT completion frozen by
# hold_dat_credit), then confirm the RN-I driver tears the in-flight transaction
# down cleanly (the stalled sequence unwinds) and restarts -- a fresh read relays
# end-to-end afterwards. rni/snf DAT credit pools are held at one apiece so the
# stalled read parks deterministically.
# Runs under: testbench/py/tb/vip_chi_tb_top.py
################################################################################

from __future__ import annotations

import cocotb

from vip_chi_types_pkg import Role, clog2
from vip_chi_base_test import vip_chi_base_test
from vip_chi_read_seq import vip_chi_read_seq
from vip_chi_tb_pkg import READ_ADDR_C


class tc_chi_d_reset(vip_chi_base_test):

  def configure(self, rni_cfg, snf_cfg):
    # SN-F DAT send progress is limited by RN-I's advertised DAT credits, so keep
    # both sides at one credit to preserve the original stall shape.
    rni_cfg.initial_dat_credits = 1
    snf_cfg.initial_dat_credits = 1

  async def run_phase(self):
    self.raise_objection()

    await self.wait_clocks(4)

    self.rni_cfg.hold_dat_credit = True

    pre_reset_seq = vip_chi_read_seq("pre_reset_seq", cfg=self.chi_cfg)
    pre_reset_seq.reset()
    pre_reset_seq.set_requests(2)
    pre_reset_seq.set_initial_addr(READ_ADDR_C + 0x800)
    pre_reset_seq.set_size(clog2(self.chi_cfg.data_bytes))
    pre_reset_seq.set_allow_retry(0)
    pre_reset_seq.set_get_response(True)
    pre_reset_seq.set_verbose(False)

    done = {"pre": False}

    async def _run_seq():
      await pre_reset_seq.start(self.v_sqr.rni_sequencer)
      done["pre"] = True

    cocotb.start_soon(_run_seq())

    first_req = await self.tb_env.rni_req_fifo.get()
    first_dat = await self.tb_env.rni_dat_fifo.get()

    saw_second_req = False
    for _ in range(20):
      ok, _second = self.tb_env.rni_req_fifo.try_get()
      if ok:
        saw_second_req = True
        break
      await self.wait_clocks(1)
    assert saw_second_req, "did not reach an in-flight second request before reset"

    await self.pulse_reset(3)
    self.rni_cfg.hold_dat_credit = False

    recovered = False
    for _ in range(40):
      if done["pre"]:
        recovered = True
        break
      await self.wait_clocks(1)
    assert recovered, "pre-reset read sequence did not terminate after reset handling"

    await self.wait_clocks(4)
    self.drain_observation_fifos()

    rd = self.rni0_rd_seq
    rd.reset()
    rd.set_requests(1)
    rd.set_initial_addr(READ_ADDR_C + 0xA00)
    rd.set_size(6)
    rd.set_allow_retry(0)
    rd.set_get_response(True)
    rd.set_verbose(False)
    await rd.start(self.v_sqr.rni_sequencer)

    responses = rd.get_responses()
    assert len(responses) == 1, \
      f"expected 1 post-reset read response, got {len(responses)}"

    assert int(first_dat.role) == int(Role.SNF), \
      f"first completion carried wrong DAT role {int(first_dat.role)}"

    post_req = await self.tb_env.rni_req_fifo.get()
    post_dat = await self.tb_env.rni_dat_fifo.get()

    assert int(post_req.addr) == (READ_ADDR_C + 0xA00), \
      f"post-reset read used wrong address 0x{int(post_req.addr):x}"
    assert int(responses[0].txn_id) == int(post_req.txn_id), \
      (f"post-reset read response txn_id 0x{int(responses[0].txn_id):x} did not "
       f"match REQ txn_id 0x{int(post_req.txn_id):x}")
    assert int(post_dat.role) == int(Role.SNF), \
      f"post-reset completion carried wrong DAT role {int(post_dat.role)}"

    self.logger.info(
      "Test (tc_chi_d_reset) PASS: link reset tore down the in-flight read and "
      "the driver cleanly restarted")
    self.drop_objection()
