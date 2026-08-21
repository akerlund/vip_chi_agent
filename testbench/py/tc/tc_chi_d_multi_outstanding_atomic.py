################################################################################
# pyUVM/cocotb port of tc/tc_chi_d_multi_outstanding_atomic.sv.
#
# Seed N distinct granules, then pipeline N returning atomics (AtomicLoad0 =
# arithmetic ADD): each returns its pre-op (seeded) value on CompData while the
# SN-F RMW writes seed+operand back. Read every granule back to confirm the
# overlapped read-modify-writes landed, and assert the atomics coexisted in
# flight (peak > 1). Atomics ride the unified mixed loop as a bidirectional kind.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import DatOpcode, clog2
from chi_base_test import chi_base_test
import chi_atomic_size_stress as atomic_size_stress
from vip_chi_atomic_seq import vip_chi_atomic_load_seq

N_C = 6
BASE_ADDR_C = 0x2F00_0000
SETTLE_C = 20


class tc_chi_d_multi_outstanding_atomic(chi_base_test):

  def configure(self, rni_cfg, snf_cfg):
    rni_cfg.multi_outstanding = True
    rni_cfg.multi_outstanding_mixed = True
    rni_cfg.max_outstanding_read = N_C
    rni_cfg.max_outstanding_write = N_C
    snf_cfg.multi_outstanding = True

  async def run_phase(self):
    self.raise_objection()
    # The wide-operand stress profile is out of spec by Table 2-17, on purpose.
    # arm() silences the rule and keeps its tally; assert_reported() below turns
    # the waiver into its own control. See chi_atomic_size_stress.
    _checkers = (self.tb_env.rni_sva, self.tb_env.snf_sva)
    atomic_size_stress.arm(_checkers)
    dbytes = self.chi_cfg.data_bytes
    size = clog2(dbytes)      # widest single-beat operand (Size 4 on CHI-D)
    stride = dbytes

    atomic_seq = vip_chi_atomic_load_seq("atomic_seq", cfg=self.chi_cfg)

    # Build N distinct (seed, operand) pairs keyed by granule address.
    seed_q, op_q, preop, updated = [], [], {}, {}
    for k in range(N_C):
      seed = 0x0001_0000 + k * 0x0000_0100
      op = 0x0000_0010 + k
      seed_q.append(seed)
      op_q.append(op)
      a = BASE_ADDR_C + k * stride
      preop[a] = seed
      updated[a] = seed + op

    # -- Phase 1: seed the N granules with known values (pipelined writes). ----
    wr = self.rni0_wr_seq
    wr.reset()
    wr.set_initial_addr(BASE_ADDR_C)
    wr.set_size(size)
    wr.set_data(seed_q)               # custom data => bounded by payload
    # Full byte enables for the seeded beat. This is what makes a sub-line write
    # legal: Table A-3 and Chapter 4 fix WriteNoSnpFull at a cache line length, so
    # a single-beat write has to be a WriteNoSnpPtl -- and a Ptl with every byte
    # enabled in its Size window is exactly "write these bytes". Supplying BE is
    # also what selects the Ptl opcode, and it keeps the enables deterministic
    # rather than randomized, which the readback depends on.
    wr.set_be([(1 << dbytes) - 1] * len(seed_q))
    wr.set_get_response(True)
    wr.set_pipelined_send(True)
    wr.set_verbose(False)
    await wr.start(self.v_sqr.rni_sequencer)
    assert len(wr.get_responses()) == N_C

    await self.wait_clocks(SETTLE_C)

    # -- Phase 2: pipeline N returning atomics (AtomicLoad0 = ADD). ------------
    atomic_seq.reset()
    atomic_seq.set_variant(0)          # Load0 => arithmetic ADD, returns pre-op value
    atomic_seq.set_initial_addr(BASE_ADDR_C)
    atomic_seq.set_size(size)
    atomic_seq.set_data(op_q)          # one operand beat per atomic
    atomic_seq.set_get_response(True)
    atomic_seq.set_pipelined_send(True)
    atomic_seq.set_verbose(False)
    await atomic_seq.start(self.v_sqr.rni_sequencer)

    at_rsp = atomic_seq.get_responses()
    assert len(at_rsp) == N_C, f"expected {N_C} atomic responses, got {len(at_rsp)}"
    for k, r in enumerate(at_rsp):
      assert int(r.dat_opcode) == int(DatOpcode.COMP_DATA), \
        f"atomic {k} completion DAT opcode 0x{int(r.dat_opcode):x} was not CompData"
      assert int(r.addr) in preop, f"atomic {k} addr 0x{int(r.addr):x} has no seed"
      assert len(r.data) == 1 and int(r.data[0]) == preop[int(r.addr)], \
        f"atomic addr 0x{int(r.addr):x} returned 0x{int(r.data[0]):x}, " \
        f"expected pre-op 0x{preop[int(r.addr)]:x}"

    await self.wait_clocks(SETTLE_C)

    # -- Phase 3: read every granule back and confirm seed+operand landed. -----
    rd = self.rni0_rd_seq
    rd.reset()
    rd.set_requests(N_C)
    rd.set_initial_addr(BASE_ADDR_C)
    rd.set_size(size)
    rd.set_get_response(True)
    rd.set_pipelined_send(True)
    rd.set_verbose(False)
    await rd.start(self.v_sqr.rni_sequencer)

    rd_rsp = rd.get_responses()
    assert len(rd_rsp) == N_C, f"expected {N_C} read responses, got {len(rd_rsp)}"
    for k, r in enumerate(rd_rsp):
      assert int(r.addr) in updated, f"read {k} addr 0x{int(r.addr):x} has no atomic"
      assert int(r.data[0]) == updated[int(r.addr)], \
        f"atomic RMW mismatch addr 0x{int(r.addr):x}: read 0x{int(r.data[0]):x} " \
        f"expected 0x{updated[int(r.addr)]:x}"

    peak = self.rni_cfg.observed_peak_outstanding
    assert peak > 1, f"atomics did not overlap: peak was {peak} (expected > 1)"

    self.logger.info(
      f"Test (tc_chi_d_multi_outstanding_atomic) PASS: {N_C} returning atomics "
      f"pipelined, pre-op + RMW read-back verified, peak in-flight = {peak}")
    atomic_size_stress.assert_reported(_checkers, "the atomic operands above")
    self.drop_objection()
