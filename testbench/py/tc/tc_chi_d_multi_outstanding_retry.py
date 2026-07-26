################################################################################
# pyUVM/cocotb port of tc/tc_chi_d_multi_outstanding_retry.sv.
#
# Pipeline N retryable writes while the SN-F (force_retry_count=1) bounces exactly
# one with RetryAck + PCrdGrant mid-pipeline. The RN-I banks the PCrdType credit
# and re-issues the bounced entry (AllowRetry cleared) while the rest of the
# pipeline keeps flowing. Confirms exactly one RetryAck + one PCrdGrant occurred,
# the writes overlapped, and every write (incl. the re-issued one) committed.
# Runs under: testbench/py/tb/vip_chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import RspOpcode, RespErr, DataType
from vip_chi_base_test import vip_chi_base_test

N_C = 6
BASE_ADDR_C = 0x2700_0000
SIZE_C = 6
SETTLE_C = 20


class tc_chi_d_multi_outstanding_retry(vip_chi_base_test):

  def configure(self, rni_cfg, snf_cfg):
    rni_cfg.multi_outstanding = True
    rni_cfg.multi_outstanding_write = True
    rni_cfg.max_outstanding_write = N_C
    snf_cfg.multi_outstanding = True
    snf_cfg.force_retry_count = 1

  async def run_phase(self):
    self.raise_objection()

    wr = self.rni0_wr_seq
    wr.reset()
    wr.set_requests(N_C)
    wr.set_initial_addr(BASE_ADDR_C)
    wr.set_size(SIZE_C)
    wr.set_allow_retry(1)                 # every write may be bounced...
    wr.set_data_type(DataType.COUNTER)
    wr.set_get_response(True)
    wr.set_pipelined_send(True)
    wr.set_verbose(False)
    await wr.start(self.v_sqr.rni_sequencer)

    wr_rsp = wr.get_responses()
    assert len(wr_rsp) == N_C, f"expected {N_C} write responses, got {len(wr_rsp)}"
    written = {}
    for k, w in enumerate(wr_rsp):
      assert int(w.rsp_opcode) == int(RspOpcode.COMP_DBID_RESP), \
        f"write {k} carried wrong RSP opcode 0x{int(w.rsp_opcode):x}"
      assert int(w.rsp_resp_err) == int(RespErr.OKAY), \
        f"write {k} completed with error status 0x{int(w.rsp_resp_err):x}"
      written[int(w.addr)] = w

    peak = self.rni_cfg.observed_peak_outstanding
    assert peak > 1, f"writes did not overlap: peak was {peak} (expected > 1)"

    # -- Exactly one bounce (RetryAck + PCrdGrant) happened mid-pipeline. ------
    await self.wait_clocks(5)
    n_retry_ack = n_pcrd_grant = 0
    while True:
      ok, obs = self.tb_env.rni_rsp_fifo.try_get()
      if not ok:
        break
      if int(obs.rsp_opcode) == int(RspOpcode.RETRY_ACK):
        n_retry_ack += 1
      if int(obs.rsp_opcode) == int(RspOpcode.PCRD_GRANT):
        n_pcrd_grant += 1
    assert n_retry_ack == 1, f"expected exactly 1 RetryAck, saw {n_retry_ack}"
    assert n_pcrd_grant == 1, f"expected exactly 1 PCrdGrant, saw {n_pcrd_grant}"

    await self.wait_clocks(SETTLE_C)

    # -- Read every address back; each (incl. the re-issued write) must commit. -
    rd = self.rni0_rd_seq
    rd.reset()
    rd.set_requests(N_C)
    rd.set_initial_addr(BASE_ADDR_C)
    rd.set_size(SIZE_C)
    rd.set_allow_retry(0)
    rd.set_get_response(True)
    rd.set_pipelined_send(True)
    rd.set_verbose(False)
    await rd.start(self.v_sqr.rni_sequencer)

    rd_rsp = rd.get_responses()
    assert len(rd_rsp) == N_C, f"expected {N_C} read responses, got {len(rd_rsp)}"
    for r in rd_rsp:
      assert int(r.addr) in written, f"read addr 0x{int(r.addr):x} had no write"
      w = written[int(r.addr)]
      assert len(r.data) == len(w.data), \
        f"read addr 0x{int(r.addr):x} beat count {len(r.data)} != write {len(w.data)}"

    self.logger.info(
      f"Test (tc_chi_d_multi_outstanding_retry) PASS: {N_C} writes pipelined, "
      f"first bounced (RetryAck+PCrdGrant) and re-issued mid-flight, peak = {peak}")
    self.drop_objection()
