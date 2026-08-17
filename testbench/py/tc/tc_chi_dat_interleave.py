################################################################################
# pyUVM/cocotb port of tc/tc_chi_dat_interleave.sv.
#
# A DAT flit names its transaction in TxnID and its position in DataID, so a
# completer may interleave the beats of several reads on one DAT channel; CHI
# nowhere requires a transfer's beats to be contiguous. With
# cfg.dat_interleave_depth = 2 the SN-F drains two queued reads together, one
# beat each in turn, and both payloads must still arrive whole and in address
# order -- in the items the monitor publishes and in the responses the sequences
# read back.
#
# What this reaches that nothing else does: every receiver in the tree used to
# read the FLITPEND deassert as "this transfer ended", which is only the same
# thing while one transfer owns the channel. A receiver that keeps that
# assumption does not fail loudly here -- it staples one read's beats onto
# another's and reports a DATA MISMATCH, pointing at the data path rather than
# at its own reassembly.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import DatOpcode, DatInterleavePolicy
from chi_base_test import chi_base_test

N_C = 2             # two reads in flight, matching dat_interleave_depth
BEATS_C = 4         # size 6 = 64 bytes over a 16-byte CHI-D data bus
BASE_ADDR_C = 0x2700_0000
SIZE_C = 6


class tc_chi_dat_interleave(chi_base_test):

  def configure(self, rni_cfg, snf_cfg):
    rni_cfg.multi_outstanding = True
    rni_cfg.multi_outstanding_mixed = True
    rni_cfg.max_outstanding_read = N_C
    snf_cfg.multi_outstanding = True
    snf_cfg.dat_interleave_depth = N_C
    # Round-robin rather than random so the expected emission order is a fact
    # this test can state, not a distribution it has to sample.
    snf_cfg.dat_interleave_policy = DatInterleavePolicy.ROUND_ROBIN

  def configure_tb_cfg(self):
    # Interleaving is legal, but it is not this VIP's own emission convention,
    # which the protocol checkers' burst-shape rules hold by default: TxnID
    # stability across a FLITPEND run, and the run's beat count. Stand those
    # down. The per-TxnID retirement, the credit rules and everything else keep
    # checking -- including the outstanding/TXSACTIVE pair, which is exactly what
    # would catch a checker that lost track of an interleaved transfer.
    self.tb_cfg.dat_interleave_allowed = True

  async def run_phase(self):
    self.raise_objection()

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

    responses = rd.get_responses()
    assert len(responses) == N_C, \
      f"expected {N_C} read responses, got {len(responses)}"

    snf = self.tb_env.snf_agent.snf_driver

    # Anti-vacuity, and the whole point of the test: the beats really did
    # alternate between the two transfers on the wire. Without this the payload
    # checks below pass just as happily on a completer that never interleaved.
    assert snf.n_dat_stream_switches > 0, \
      ("no interleaving reached the wire: the SN-F emitted every transfer's "
       f"beats contiguously (switches={snf.n_dat_stream_switches})")

    # Round-robin over two equal-length reads is a strict alternation, so the
    # emitted TxnID sequence is fully determined: A B A B A B A B.
    log = [int(t) for t in snf.dat_beat_txn_log]
    assert len(log) == N_C * BEATS_C, \
      f"expected {N_C * BEATS_C} DAT beats on the wire, got {len(log)}"
    assert len(set(log)) == N_C, \
      f"expected beats from {N_C} distinct transfers, saw TxnIDs {sorted(set(log))}"
    for i in range(1, len(log)):
      assert log[i] != log[i - 1], \
        f"round-robin emitted two consecutive beats of the same transfer: {log}"

    # Both payloads whole and in address order, read back through the sequence.
    for k, rsp in enumerate(responses):
      addr = int(rsp.addr)
      assert int(rsp.dat_opcode) == int(DatOpcode.COMP_DATA), \
        f"read {k} carried wrong DAT opcode 0x{int(rsp.dat_opcode):x}"
      assert len(rsp.data) == BEATS_C, \
        f"read {k} reassembled {len(rsp.data)} beats, expected {BEATS_C}"
      assert [int(d) for d in rsp.data_id] == list(range(BEATS_C)), \
        f"read {k} beats were not placed by DataID: {[int(d) for d in rsp.data_id]}"
      for i in range(BEATS_C):
        assert int(rsp.data[i]) == (addr + i), \
          (f"read {k} addr 0x{addr:x} beat {i} payload 0x{int(rsp.data[i]):x}, "
           f"expected 0x{addr + i:x}")

    # And the same, independently, in what the monitor assembled off the wire.
    # The two are separate readers of the same interleaved stream: the sequence
    # response comes from the RN-I driver's collector, the item below from the
    # monitor's. Checking only one would leave the other free to staple beats
    # together unnoticed.
    seen = {}
    for _ in range(N_C):
      dat_item = await self.tb_env.rni_dat_fifo.get()
      seen[int(dat_item.txn_id)] = dat_item
    assert len(seen) == N_C, \
      f"monitor published {len(seen)} distinct transfers, expected {N_C}"

    for txn, item in seen.items():
      assert len(item.data) == BEATS_C, \
        f"monitor reassembled {len(item.data)} beats for txn 0x{txn:x}"
      assert [int(d) for d in item.data_id] == list(range(BEATS_C)), \
        (f"monitor did not place txn 0x{txn:x} by DataID: "
         f"{[int(d) for d in item.data_id]}")
      base = int(item.data[0])
      for i in range(BEATS_C):
        assert int(item.data[i]) == (base + i), \
          (f"monitor txn 0x{txn:x} beat {i} payload 0x{int(item.data[i]):x} is "
           f"not contiguous with beat 0 (0x{base:x}) -- beats of two transfers "
           f"were assembled into one")

    mon = self.tb_env.rni_agent.monitor
    assert mon.n_dataid_violation == 0, \
      f"interleaved traffic raised {mon.n_dataid_violation} DataID violations"

    self.logger.info(
      f"Test (tc_chi_dat_interleave) PASS: {N_C} reads interleaved beat by beat "
      f"({snf.n_dat_stream_switches} stream switches), both payloads whole")
    self.drop_objection()
