################################################################################
# pyUVM/cocotb port of tc/tc_chi_d_scoreboard_negctl.sv.
#
# Negative control: the standalone scoreboard stays ENABLED (default). One clean
# write opens+retires a ctx normally (no complaint), then a bare Comp RSP whose
# TxnID matches no outstanding request is injected on the SN-F. The RN-I monitor
# observes it inbound and Checker A MUST flag it as an orphan completion; if it
# does not, the scoreboard has silently gone vacuous and the test fails. The
# deliberately-injected orphan error is demoted by a logging.Filter catcher so it
# does not pollute the regression, exactly as the SV report-catcher does.
# Runs under: testbench/py/tb/vip_chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import Resp, RespErr, RspOpcode
from vip_chi_base_test import vip_chi_base_test, WRITE_READ_ADDR_C
from vip_chi_raw_seq import vip_chi_raw_seq
from vip_chi_scoreboard_negctl_catcher import vip_chi_scoreboard_negctl_catcher
from vip_chi_tb_pkg import RNI_NODE_ID_C, SNF_NODE_ID_C

ORPHAN_TXN_C = 0xF7


class tc_chi_d_scoreboard_negctl(vip_chi_base_test):

  async def run_phase(self):
    self.raise_objection()

    scoreboard = self.tb_env.scoreboard
    catcher = vip_chi_scoreboard_negctl_catcher("sb_orphan_catcher")
    # Catch (and demote) the single orphan error the scoreboard is expected to
    # emit, so it does not count against the regression verdict.
    scoreboard.logger.addFilter(catcher)

    # 1) One clean write brings the link to RUN and opens+retires a ctx normally.
    #    The scoreboard must NOT complain about this legal transaction.
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

    # 2) Inject a bare Comp RSP whose TxnID matches no outstanding request. The
    #    RN-I monitor observes it inbound (role SN-F) and Checker A must report it
    #    as an orphan completion (no open ctx for that {tgt,txn}).
    raw_rsp = {
      "dbid": ORPHAN_TXN_C, "fwdstate": 0,
      "resp": int(Resp.I), "resperr": int(RespErr.OKAY),
      "opcode": int(RspOpcode.COMP), "txnid": ORPHAN_TXN_C,
      "srcid": SNF_NODE_ID_C, "tgtid": RNI_NODE_ID_C, "qos": 0x0,
    }

    snf_raw_seq = vip_chi_raw_seq("snf_raw_seq", cfg=self.chi_cfg)
    snf_raw_seq.reset()
    snf_raw_seq.add_raw_rsp(raw_rsp)
    await snf_raw_seq.start(self.v_sqr.snf_sequencer)

    await self.wait_clocks(8)

    scoreboard.logger.removeFilter(catcher)

    # 3) Verdict: the scoreboard MUST have flagged the injected orphan.
    assert catcher.saw_orphan_error, \
      "scoreboard did NOT flag the injected orphan completion - it may be " \
      "vacuous or disconnected"

    self.logger.info(
      "Test (tc_chi_d_scoreboard_negctl) PASS: scoreboard correctly flagged the "
      "injected orphan (negative control passed)")
    self.drop_objection()
