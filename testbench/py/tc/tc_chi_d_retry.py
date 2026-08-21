################################################################################
# pyUVM/cocotb port of tc/tc_chi_d_retry.sv.
#
# With force_retry_count=1 the SN-F bounces the first retryable write with a
# RetryAck + PCrdGrant; the RN-I re-issues (AllowRetry cleared) to a final
# CompDBIDResp. The monitor must have observed the RetryAck and the PCrdGrant,
# and the readback confirms the retried write committed.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import RspOpcode
from chi_base_test import chi_base_test

ADDR_C = 0x3100_0000
SIZE_C = 4          # one 16-byte beat
BE_FULL_C = (1 << 16) - 1   # every byte of that beat enabled
SETTLE_C = 20
WRITTEN = 0xCAFE_0001


class tc_chi_d_retry(chi_base_test):

  def configure(self, rni_cfg, snf_cfg):
    snf_cfg.force_retry_count = 1

  async def run_phase(self):
    self.raise_objection()

    wr = self.rni0_wr_seq
    wr.reset()
    wr.set_initial_addr(ADDR_C)
    wr.set_size(SIZE_C)
    wr.set_allow_retry(1)          # let the SN-F bounce it
    wr.set_data([WRITTEN])         # custom data => bounded by payload
    # Full byte enables for the one beat. This is what makes a sub-line write
    # legal: Table A-3 and Chapter 4 fix WriteNoSnpFull at a cache line length,
    # so a 16-byte write has to be a WriteNoSnpPtl -- and a Ptl with every byte
    # enabled in its Size window is exactly "write these 16 bytes". Supplying BE
    # is also what selects the Ptl opcode, and it keeps the enables deterministic
    # rather than randomized, which the readback below depends on.
    wr.set_be([BE_FULL_C])
    wr.set_get_response(True)
    wr.set_verbose(False)
    await wr.start(self.v_sqr.rni_sequencer)

    wr_rsp = wr.get_responses()
    assert len(wr_rsp) == 1
    assert int(wr_rsp[0].rsp_opcode) == int(RspOpcode.COMP_DBID_RESP)

    saw_retry_ack = False
    saw_pcrd_grant = False
    while True:
      ok, obs = self.tb_env.rni_rsp_fifo.try_get()
      if not ok:
        break
      if int(obs.rsp_opcode) == int(RspOpcode.RETRY_ACK):
        saw_retry_ack = True
      if int(obs.rsp_opcode) == int(RspOpcode.PCRD_GRANT):
        saw_pcrd_grant = True
    assert saw_retry_ack, "retryable write was never bounced with a RetryAck"
    assert saw_pcrd_grant, "RetryAck was not followed by a PCrdGrant"

    await self.wait_clocks(SETTLE_C)

    rd = self.rni0_rd_seq
    rd.reset()
    rd.set_requests(1)
    rd.set_initial_addr(ADDR_C)
    rd.set_size(SIZE_C)
    # The zero is load-bearing here, not determinism. force_retry_count above
    # bounds the TOTAL bounces this SN-F will issue, and should_auto_retry only
    # bounces a request whose AllowRetry is set -- so clearing it on the read
    # reserves the single retry for the request this test is about. Every other
    # testcase in the tree had this call for determinism it already had from
    # force_retry_count = 0, and those were removed.
    rd.set_allow_retry(0)
    rd.set_get_response(True)
    rd.set_verbose(False)
    await rd.start(self.v_sqr.rni_sequencer)

    rd_rsp = rd.get_responses()
    assert len(rd_rsp) == 1 and len(rd_rsp[0].data) == 1
    assert int(rd_rsp[0].data[0]) == WRITTEN, \
      f"retried write did not commit: read 0x{int(rd_rsp[0].data[0]):x}"

    self.logger.info("Test (tc_chi_d_retry) PASS")
    self.drop_objection()
