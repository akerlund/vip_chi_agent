################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of tc/chi_coh_read_no_snoop_base_test.sv.
#
# First coherent test: a single RN-F issues one ReadShared to the HN-F home. With
# an empty directory and a single requester there is nothing to snoop, so the home
# returns CompData directly. Asserts the full datapath: the read completes with
# data, granted state SC, the RN-F cache + HN-F directory recorded SC, and NO
# snoop was ever seen on the coherent link.
#
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import Resp
from chi_coherent_base_test import chi_coherent_base_test
from chi_tb_pkg import WRITE_READ_ADDR_C


class chi_coh_read_no_snoop_base_test(chi_coherent_base_test):

  def configure_tb_cfg(self):
    self.tb_cfg.perf_enable = True

  async def run_phase(self):
    self.raise_objection()

    await self.wait_reset_settle()

    seq = self.hrnf0_rdshared_seq
    seq.reset()
    seq.set_requests(1)
    seq.set_initial_addr(WRITE_READ_ADDR_C)
    seq.set_size(6)
    seq.set_get_response(True)
    seq.set_verbose(False)
    await seq.start(self.tb_env.hrnf0_agent.sequencer)
    responses = seq.get_responses()

    assert len(responses) == 1, \
      f"expected 1 ReadShared response, got {len(responses)}"
    rsp = responses[0]
    assert len(rsp.data) != 0, "ReadShared completed with no data beats"
    assert int(rsp.rsp_resp) == int(Resp.SC), \
      f"ReadShared granted state 0x{int(rsp.rsp_resp):x}, expected SC (0x{int(Resp.SC):x})"

    # Let the perf clock loop advance a few cycles past the completion.
    await self.wait_clocks(8)

    rnf_state = self.tb_env.hrnf0_agent.rnf_driver.get_cache_state(WRITE_READ_ADDR_C)
    assert rnf_state == int(Resp.SC), \
      f"RN-F cache state 0x{rnf_state:x}, expected SC (0x{int(Resp.SC):x})"

    hnf_state = self.tb_env.hnf_agent.hnf_driver.get_directory_state(WRITE_READ_ADDR_C)
    assert hnf_state == int(Resp.SC), \
      f"HN-F directory state 0x{hnf_state:x}, expected SC (0x{int(Resp.SC):x})"

    assert not self.tb_env.hrnf0_snp_fifo.can_get(), \
      "expected zero snoops on the coherent link"

    self.logger.info(
      "Test (coh_read_no_snoop) PASS: coherent ReadShared datapath + granted SC "
      "+ RN-F/HN-F state SC + zero snoops")
    self.drop_objection()
