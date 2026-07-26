################################################################################
# pyUVM/cocotb port of tc/tc_chi_d_hni_reset.sv.
#
# Reset a proxy link while traffic is straddling the HN-I: park a read in flight
# (its completion held at the RN-facing port by hold_dat_credit, its request
# already forwarded to the SN), pulse reset, and confirm the proxy's all-links
# watcher tears the in-flight transaction down cleanly (the stalled sequence
# unwinds) and then restarts -- a fresh write+read relays end-to-end. The
# RN-facing and SN-facing DAT credit pools are held at one apiece so the stalled
# read parks deterministically.
# Runs under: testbench/py/tb/vip_chi_tb_top.py
################################################################################

from __future__ import annotations

import cocotb

from vip_chi_types_pkg import ReqOpcode
from vip_chi_hni_base_test import vip_chi_hni_base_test
from vip_chi_read_seq import vip_chi_read_seq
from vip_chi_tb_pkg import WRITE_READ_ADDR_C


class tc_chi_d_hni_reset(vip_chi_hni_base_test):

  def configure(self):
    # Hold RN-facing and SN-facing DAT credit pools at one apiece so a stalled
    # read parks cleanly in flight, giving a deterministic mid-proxy reset point.
    self.hrni0_cfg.initial_dat_credits = 1
    self.hsnf0_cfg.initial_dat_credits = 1

  async def run_phase(self):
    self.raise_objection()

    await self.wait_clocks(4)

    # Freeze the RN-facing DAT completions so the second read parks in flight with
    # its request already relayed to the SN behind the proxy.
    self.hrni0_cfg.hold_dat_credit = True

    inflight_seq = vip_chi_read_seq("inflight_seq", cfg=self.chi_cfg)
    inflight_seq.reset()
    inflight_seq.set_requests(2)
    inflight_seq.set_initial_addr(WRITE_READ_ADDR_C)
    inflight_seq.set_size(6)
    inflight_seq.set_allow_retry(0)
    inflight_seq.set_get_response(True)
    inflight_seq.set_verbose(False)

    done = {"inflight": False}

    async def _run_seq():
      await inflight_seq.start(self.v_sqr.hrni0_sequencer)
      done["inflight"] = True

    cocotb.start_soon(_run_seq())

    # Block until the proxy has actually forwarded a request to the SN: now there
    # is genuine in-flight traffic straddling the HN-I when reset lands. The
    # fifo.get() resolves inside the monitor's sampling (ReadOnly) region, so step
    # to a writable region before driving reset.
    await self.tb_env.hsnf0_req_fifo.get()
    await self.wait_clocks(1)

    # Reset the links mid-flight and release the credit hold so the RN-I driver
    # can unwind the parked sequence during reset handling.
    await self.pulse_reset(3)
    self.hrni0_cfg.hold_dat_credit = False

    # Clean teardown: the in-flight sequence must unwind (not hang) once the proxy
    # tears down and the RN-facing link resets.
    recovered = False
    for _ in range(60):
      if done["inflight"]:
        recovered = True
        break
      await self.wait_clocks(1)
    assert recovered, "in-flight proxy read did not unwind after the mid-proxy reset"

    await self.wait_clocks(4)
    self.drain_observation_fifos()

    # Restart: a fresh write+read must relay end-to-end through the recovered
    # proxy, and the SN must observe both forwarded requests.
    wr = self.rni0_wr_seq
    wr.reset()
    wr.set_requests(1)
    wr.set_initial_addr(WRITE_READ_ADDR_C)
    wr.set_size(6)
    wr.set_allow_retry(0)
    wr.set_get_response(True)
    wr.set_verbose(False)
    await wr.start(self.v_sqr.hrni0_sequencer)

    rd = self.rni0_rd_seq
    rd.reset()
    rd.set_requests(1)
    rd.set_initial_addr(WRITE_READ_ADDR_C)
    rd.set_size(6)
    rd.set_allow_retry(0)
    rd.set_get_response(True)
    rd.set_verbose(False)
    await rd.start(self.v_sqr.hrni0_sequencer)

    write_responses = wr.get_responses()
    read_responses = rd.get_responses()
    assert len(write_responses) == 1, \
      f"expected 1 post-reset write completion through the proxy, got {len(write_responses)}"
    assert len(read_responses) == 1, \
      f"expected 1 post-reset read completion through the proxy, got {len(read_responses)}"

    snf_reqs = [await self.tb_env.hsnf0_req_fifo.get() for _ in range(2)]
    assert int(snf_reqs[0].opcode) == int(ReqOpcode.WRITE_NO_SNP_FULL), \
      f"post-reset SN-F did not receive the forwarded WriteNoSnpFull: 0x{int(snf_reqs[0].opcode):x}"
    assert int(snf_reqs[1].opcode) == int(ReqOpcode.READ_NO_SNP), \
      f"post-reset SN-F did not receive the forwarded ReadNoSnp: 0x{int(snf_reqs[1].opcode):x}"
    assert len(read_responses[0].data) == 4, \
      f"post-reset proxied read returned {len(read_responses[0].data)} beats instead of 4"

    self.logger.info(
      "Test (tc_chi_d_hni_reset) PASS: HN-I proxy torn down mid-flight by reset "
      "and cleanly restarted")
    self.drop_objection()
