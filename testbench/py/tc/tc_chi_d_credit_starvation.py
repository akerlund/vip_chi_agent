################################################################################
# pyUVM/cocotb port of tc/tc_chi_d_credit_starvation.sv.
#
# Stall the SN-F's DAT completions by pausing the RN-I's DAT-credit advertisement
# (hold_dat_credit -- the receiver's own credit knob). A 2-request read parks its
# second completion while the credit is held (no DAT arrives, the sequence does
# not finish), then recovers cleanly once the credit is released. rni/snf DAT
# pools are held at one apiece to preserve the stall shape.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

import cocotb

from vip_chi_types_pkg import Role, clog2
from chi_base_test import chi_base_test
from vip_chi_read_seq import vip_chi_read_seq
from chi_tb_pkg import READ_ADDR_C


class tc_chi_d_credit_starvation(chi_base_test):

  def configure(self, rni_cfg, snf_cfg):
    rni_cfg.initial_dat_credits = 1
    snf_cfg.initial_dat_credits = 1

  async def run_phase(self):
    self.raise_objection()

    await self.wait_clocks(4)

    self.rni_cfg.hold_dat_credit = True

    seq = vip_chi_read_seq("credit_starvation_seq", cfg=self.chi_cfg)
    seq.reset()
    seq.set_requests(2)
    seq.set_initial_addr(READ_ADDR_C + 0x400)
    seq.set_size(clog2(self.chi_cfg.data_bytes))
    seq.set_allow_retry(0)
    seq.set_get_response(True)
    seq.set_verbose(False)

    done = {"seq": False}

    async def _run_seq():
      await seq.start(self.v_sqr.rni_sequencer)
      done["seq"] = True

    cocotb.start_soon(_run_seq())

    first_req = await self.tb_env.rni_req_fifo.get()
    first_dat = await self.tb_env.rni_dat_fifo.get()

    saw_second_req = False
    second_req = None
    for _ in range(20):
      ok, second_req = self.tb_env.rni_req_fifo.try_get()
      if ok:
        saw_second_req = True
        break
      await self.wait_clocks(1)
    assert saw_second_req, "second read request never issued before DAT-credit stall"

    await self.wait_clocks(10)

    ok, _unexpected = self.tb_env.rni_dat_fifo.try_get()
    assert not ok, "second read completion arrived while DAT credit was held"
    assert not done["seq"], "read sequence completed before the held DAT credit was released"

    self.rni_cfg.hold_dat_credit = False

    second_dat = await self.tb_env.rni_dat_fifo.get()

    recovered = False
    for _ in range(20):
      if done["seq"]:
        recovered = True
        break
      await self.wait_clocks(1)
    assert recovered, "read sequence did not recover after DAT credit release"

    responses = seq.get_responses()
    assert len(responses) == 2, \
      f"expected 2 read responses after DAT-credit recovery, got {len(responses)}"
    assert int(first_dat.role) == int(Role.SNF), \
      f"first completion carried wrong DAT role {int(first_dat.role)}"
    assert int(second_dat.txn_id) == int(second_req.txn_id), \
      (f"second stalled completion txn_id 0x{int(second_dat.txn_id):x} did not "
       f"match request txn_id 0x{int(second_req.txn_id):x}")

    self.logger.info(
      "Test (tc_chi_d_credit_starvation) PASS: held DAT credit stalled the second "
      "completion, released credit recovered it")
    self.drop_objection()
