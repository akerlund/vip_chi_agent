################################################################################
# pyUVM/cocotb port of tc/tc_chi_pcrd_leak.sv.
#
# Negative control for the RN-I's end-of-test P-credit accounting. The requester
# banks a PCrdGrant against the RetryAck that owed it; a grant nothing bounced is
# a credit the completer set aside and the requester never took. Nothing else in
# the flow notices - the traffic completes and the test passes - so the only
# thing standing between a half-finished retry handshake and a green run is the
# driver's check_phase.
#
# Inject a bare PCrdGrant from the SN-F with the RN-I pipelined (the path that
# banks credits), then require the leak to have been counted. The deliberately
# induced error is demoted by a logging.Filter catcher, exactly as the SV
# report-catcher does.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

import logging

from vip_chi_types_pkg import Resp, RespErr, RspOpcode
from chi_base_test import chi_base_test, WRITE_READ_ADDR_C
from vip_chi_raw_seq import vip_chi_raw_seq
from chi_tb_pkg import RNI_NODE_ID_C, SNF_NODE_ID_C

PCRD_TYPE_C = 0x3


class _pcrd_leak_catcher(logging.Filter):
  """Demote the leak error this test induces on purpose, and record that it fired."""

  def __init__(self):
    super().__init__()
    self.saw_leak_error = False

  def filter(self, record):
    if record.levelno >= logging.ERROR and "never consumed" in record.getMessage():
      self.saw_leak_error = True
      record.levelno = logging.INFO
      record.levelname = "INFO"
    return True


class tc_chi_pcrd_leak(chi_base_test):

  def __init__(self, name, parent):
    super().__init__(name, parent)
    self.catcher = _pcrd_leak_catcher()

  def configure_tb_cfg(self):
    # The injected PCrdGrant bounces nothing, so the scoreboard opens a context
    # for it that never completes and reports the stray flit as an incomplete
    # transaction. That is correct of the scoreboard and beside the point here:
    # this test is a guard on the driver's credit accounting, so keep the
    # scoreboard's separate (and correct) complaint out of the verdict.
    self.tb_cfg.scoreboard_enable = False

  def configure(self, rni_cfg, snf_cfg):
    # Only the pipelined path banks P-credits: the serial retry handler pairs its
    # single RetryAck and PCrdGrant directly and never holds one. So the RN-I is
    # pipelined and the SN-F is NOT -- its buffered loop is auto-responder only
    # and never pulls from its sequencer, which would leave the raw injection
    # below waiting forever. A single write needs no SN-F buffering anyway.
    rni_cfg.multi_outstanding = True

  async def run_phase(self):
    self.raise_objection()

    driver = self.tb_env.rni_agent.rni_driver
    driver.logger.addFilter(self.catcher)

    # One clean write brings the link to RUN through the pipelined loop, so the
    # RSP monitor that banks P-credits is running when the grant arrives.
    wr = self.rni0_wr_seq
    wr.reset()
    wr.set_requests(1)
    wr.set_initial_addr(WRITE_READ_ADDR_C)
    wr.set_size(6)
    wr.set_allow_retry(0)
    wr.set_get_response(True)
    wr.set_verbose(False)
    await wr.start(self.v_sqr.rni_sequencer)

    await self.wait_clocks(4)

    # A PCrdGrant that bounces nothing. The RN-I banks it, and no pipeline entry
    # is owed that PCrdType, so it stays banked for the rest of the run.
    raw_rsp = {
      "dbid": 0, "fwdstate": 0,
      "resp": int(Resp.I), "resperr": int(RespErr.OKAY),
      "opcode": int(RspOpcode.PCRD_GRANT), "txnid": 0,
      "pcrdtype": PCRD_TYPE_C,
      "srcid": SNF_NODE_ID_C, "tgtid": RNI_NODE_ID_C, "qos": 0x0,
    }

    snf_raw_seq = vip_chi_raw_seq("snf_raw_seq", cfg=self.chi_cfg)
    snf_raw_seq.reset()
    snf_raw_seq.add_raw_rsp(raw_rsp)
    await snf_raw_seq.start(self.v_sqr.snf_sequencer)

    await self.wait_clocks(8)

    assert driver.pcrd_pool.get(PCRD_TYPE_C, 0) == 1, (
      "the injected PCrdGrant was not banked, so the leak the check_phase looks "
      "for was never created")

    self.drop_objection()

  # report_phase, not check_phase: pyUVM runs check_phase TOP-DOWN (a port
  # deviation from UVM's bottom-up check_phase), so a test asserting there would
  # run before the driver it is checking. report_phase is the next phase, so the
  # driver's verdict is in by then on both flows.
  def report_phase(self):
    driver = self.tb_env.rni_agent.rni_driver
    driver.logger.removeFilter(self.catcher)

    assert driver.n_pcrd_leak == 1, (
      f"RN-I did NOT report the leaked P-credit (n_pcrd_leak="
      f"{driver.n_pcrd_leak}) - the end-of-test credit accounting may be vacuous")
    assert self.catcher.saw_leak_error, \
      "the leak was counted but never reported"

    self.logger.info(
      "Test (tc_chi_pcrd_leak) PASS: RN-I reported the granted-and-unused "
      "P-credit (negative control passed)")
