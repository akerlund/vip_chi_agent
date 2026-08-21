################################################################################
# pyUVM/cocotb port of tc/tc_chi_recording_smoke.sv.
#
# Transaction recording, checked for the two things that can actually be wrong
# with it rather than for "it did not crash".
#
# Recording is a debug aid, so the temptation is to smoke-test it by turning it
# on and seeing the run pass. That proves nothing: the calls are no-ops when the
# knob is off, and a recorder that opened every stream and closed none would also
# pass. The two failures that matter are both about the LIFECYCLE:
#
#   * a stream opened and never closed -- the leak. Every transaction that
#     completed must have had its stream closed, so the open-stream bookkeeping
#     must be EMPTY at the end of a run in which everything retired.
#   * a stream closed on the wrong object. end_tr must be called on the item
#     begin_tr opened, and the completion arrives as a different item on a
#     different channel, so the recorder holds the opening item. If it did not,
#     the end time would land on an object nobody kept.
#
# Both are checked against the monitor's own bookkeeping rather than against a
# transaction database, because pyUVM 4.0.1 has no database: begin_tr returns
# handle 0, do_*_tr are empty hooks, and the source says as much. The lifecycle
# is still real -- accept/begin/end times land on the item -- and that is what
# this asserts. The SV twin checks the same bookkeeping so the two tests stay
# comparable; the waveform stream itself is only produced there.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from chi_base_test import chi_base_test

ADDR_C = 0x3E40_0000
SIZE_C = 6                      # 64 B = 4 beats on the CHI-D cut
SETTLE_C = 20
N_REQ_C = 4


class tc_chi_recording_smoke(chi_base_test):

  def configure(self, rni_cfg, snf_cfg):
    rni_cfg.record_transactions = True
    snf_cfg.record_transactions = True

  async def run_phase(self):
    self.raise_objection()

    mon = self.tb_env.rni_agent.monitor

    # A read and a write: they complete on different channels (DAT and RSP), and
    # the recorder closes the stream at each. Testing only one direction would
    # leave the other's close path unexercised.
    rd = self.rni0_rd_seq
    rd.reset()
    rd.set_requests(N_REQ_C)
    rd.set_initial_addr(ADDR_C)
    rd.set_size(SIZE_C)
    rd.set_get_response(True)
    rd.set_verbose(False)
    await rd.start(self.v_sqr.rni_sequencer)

    wr = self.rni0_wr_seq
    wr.reset()
    wr.set_requests(N_REQ_C)
    wr.set_initial_addr(ADDR_C)
    wr.set_size(SIZE_C)
    wr.set_get_response(True)
    wr.set_verbose(False)
    await wr.start(self.v_sqr.rni_sequencer)

    await self.wait_clocks(SETTLE_C)

    # Something must actually have been recorded, or the assertions below hold
    # trivially on a recorder that never ran.
    assert mon.n_tr_opened >= 2 * N_REQ_C, (
      f"the monitor opened {mon.n_tr_opened} transaction stream(s) for "
      f"{2 * N_REQ_C} requests -- recording is not running")

    # Every stream that was opened must have been closed. This is the leak
    # check, and it is the one a passing run cannot otherwise show.
    assert not mon._open_tr_item, (
      f"{len(mon._open_tr_item)} transaction stream(s) were still open after "
      f"every transaction completed: TxnIDs "
      f"{sorted(mon._open_tr_item)} -- end_tr is not being reached")
    assert mon.n_tr_opened == mon.n_tr_closed, (
      f"opened {mon.n_tr_opened} stream(s) but closed {mon.n_tr_closed}")

    # And the end time must have landed on the item that carries the begin
    # time -- i.e. the recorder closed the object it opened, not the completion.
    assert mon.last_closed_item is not None, "no stream was closed at all"
    assert mon.last_closed_item.get_end_time() >= \
        mon.last_closed_item.get_begin_time() > 0, (
      "the closed item carries no coherent begin/end pair, so end_tr was called "
      "on an object other than the one begin_tr opened")

    self.logger.info(
      f"Test (tc_chi_recording_smoke) PASS: {mon.n_tr_opened} stream(s) opened "
      f"and all {mon.n_tr_closed} closed, none left open, and the end time "
      f"landed on the item that carries the begin time")
    self.drop_objection()
