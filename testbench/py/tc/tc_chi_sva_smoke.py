################################################################################
#
# tc_chi_sva_smoke
#
# Negative control for py/sva/bind_chi.py: one deliberate violation per check
# family, asserting the checker REPORTS it. Without this the checkers could be
# silently vacuous -- every one of the 152 regression testcases passes with them
# enabled, and a checker that can never fire passes exactly as loudly as one
# that works.
#
# The checker is driven with synthetic per-cycle samples rather than through the
# DUT. That is deliberate, and it is what makes a negative control possible at
# all here: the env builds its own bind_chi on each interface and asserts zero
# violations in report_phase, so provoking a real violation on the wires would
# fail the test it is trying to prove. Driving a private instance keeps the
# induced errors owned by this testcase.
#
# What this does NOT cover: that the checker is wired to the right nets. That is
# covered by every other testcase in the suite -- the env checkers report their
# rules as `exercised` against real traffic, which they could only do by reading
# live signals.
#
# Runs under: testbench/py/tb/chi_tb_top.py (topology-free)
################################################################################

from __future__ import annotations

import logging

from pyuvm import uvm_test

from sva.bind_chi import bind_chi, _flit_slices, _LINK_ACT_WINDOW_C
from vip_chi_types_pkg import ChiCfg, DatOpcode, ReqOpcode, ReqOrder, Role, RspOpcode

# The standalone topology's CHI-D datapath: 16 bytes, so a size-6 (64-byte)
# transfer is a 4-beat burst and a size-4 (16-byte) one is a single beat.
_DATA_BYTES_C = 16
_TIMEOUT_CYCLES_C = 8   # short, so a timeout can be provoked in a few cycles

# A link in RUN: some request and some acknowledge, which is the role-agnostic
# condition bind_chi._link_is_running tests for.
_RUN = {
  "txlinkactivereq": 1, "txlinkactiveack": 0,
  "rxlinkactivereq": 0, "rxlinkactiveack": 1,
  "txsactive": 1, "rxsactive": 1,
}
_STOP = {
  "txlinkactivereq": 0, "txlinkactiveack": 0,
  "rxlinkactivereq": 0, "rxlinkactiveack": 0,
  "txsactive": 0, "rxsactive": 0,
}
_CHANNELS = ("req", "rsp", "dat")


def _sample(base: dict, **over) -> dict:
  """One cycle of checker input: link state plus all-quiet channels."""
  s = dict(base)
  for ch in _CHANNELS:
    for d in ("tx", "rx"):
      s[f"{d}{ch}flitv"] = 0
      s[f"{d}{ch}flitpend"] = 0
      s[f"{d}{ch}lcrdv"] = 0
      s[f"{d}{ch}flit"] = None
  s.update(over)
  return s


# Every field the checker slices out of a flit, so a hand-built one is never
# short a key the real sampler would always have supplied.
_FLIT_DEFAULTS = {
  "req": {"opcode": 0, "txnid": 0, "returntxnid": 0, "size": 0,
          "expcompack": 0, "order": int(ReqOrder.NONE)},
  "rsp": {"opcode": 0, "txnid": 0, "dbid": 0},
  "dat": {"opcode": 0, "txnid": 0, "dbid": 0, "dataid": 0},
}


def _flit(d: str, ch: str, pend: int = 0, **fields) -> dict:
  """A cycle carrying one flit on {d}{ch}, as _sample() overrides."""
  return {
    f"{d}{ch}flitv": 1,
    f"{d}{ch}flitpend": pend,
    f"{d}{ch}flit": dict(_FLIT_DEFAULTS[ch], **fields),
  }


def _req(d="tx", pend=0, **fields):
  return _sample(_RUN, **_flit(d, "req", pend, **fields))


def _rsp(d="rx", pend=0, **fields):
  return _sample(_RUN, **_flit(d, "rsp", pend, **fields))


def _dat(d="tx", pend=0, **fields):
  return _sample(_RUN, **_flit(d, "dat", pend, **fields))


def _idle(n: int = 1):
  return [_sample(_RUN) for _ in range(n)]


def _checker(role: Role = Role.RNI) -> bind_chi:
  """A bind_chi with no bus, driven by hand.

  The checks are pure functions of the sampled dict, so they can be called
  directly; only `run()` needs a bus, and this bypasses it.
  """
  c = bind_chi.__new__(bind_chi)
  c.bus = None
  # Every violation below is induced on purpose, so its log line is silenced
  # rather than left to read as a real failure -- the same discipline the SV
  # negative controls apply with report catchers. The counts are unaffected:
  # _err increments fail_count before it logs, and the assertions read those.
  c.log = logging.getLogger("tc_chi_sva_smoke_induced")
  c.log.setLevel(logging.CRITICAL)
  c.errors = 0
  c.fail_count = {}
  c.pass_count = {}
  # Everything the check registry needs -- per-check enable, severity, the
  # expected-failure set and the LASM tallies -- in one call, so a field added
  # to the registry does not silently break this hand-built path.
  #
  # Nothing here declares an expected failure: this test induces its violations
  # one at a time and asserts each fired, so every one must reach the ordinary
  # error path.
  c.init_check_control()
  c._checks_enable = True
  c._lcrd = {}
  c._link_ever_active = False

  # The transaction layer needs the configuration the constructor derives from
  # the bus. CHI-D over a 16-byte datapath is the shape the standalone topology
  # already runs, so the beat arithmetic below matches what the real checkers
  # on that link compute.
  cfg = ChiCfg(data_bytes=_DATA_BYTES_C)
  c._enable_completion_timeout = True
  c._timeout_cycles = _TIMEOUT_CYCLES_C
  c.tb_cfg = None
  c._is_requester = role in (Role.RNI, Role.RNF)
  c._is_completer = role in (Role.SNF, Role.HNF)
  c._is_rni = role == Role.RNI
  c._is_snf = role == Role.SNF
  c._req_dir = "tx" if c._is_requester else "rx"
  c._completion_dir = "rx" if c._is_requester else "tx"
  c._slices = _flit_slices(cfg)
  c._data_id_mask = (1 << cfg.data_id_width) - 1
  c._data_bytes = cfg.data_bytes

  c._reset_state()
  return c


def _feed(checker: bind_chi, samples: list[dict]) -> None:
  prev = None
  for s in samples:
    checker._check_link_gating(s)
    checker._check_pend_requires_valid(s)
    checker._check_lcrd(s)
    if prev is not None:
      checker._check_deactivate_idle(prev, s)
    prev = s


def _feed_txn(checker: bind_chi, samples: list[dict]) -> None:
  """Drive the transaction layer, one cycle per sample."""
  for s in samples:
    checker._check_transactions(s)


class tc_chi_sva_smoke(uvm_test):

  def _fired(self, checker: bind_chi, rule: str) -> int:
    return checker.fail_count.get(rule, 0)

  async def run_phase(self):
    self.raise_objection()

    # ---- FLITPEND without FLITV ------------------------------------------
    c = _checker()
    _feed(c, [_sample(_RUN, txreqflitpend=1)])
    assert self._fired(c, "CHI_REQ_PEND_REQUIRES_VALID") == 1, (
      "flitpend without flitv was not reported")

    # ---- Flit sent before the link is RUN ---------------------------------
    # One-sided ACTIVATING: a request with no acknowledge yet. This is the case
    # link_is_running catches and link_is_active would not, so it also pins the
    # tighter of the two predicates.
    activating = _sample(_RUN, txreqflitv=1)
    activating["rxlinkactiveack"] = 0
    c = _checker()
    _feed(c, [activating])
    assert self._fired(c, "CHI_REQ_FLITV_REQUIRES_LINK") == 1, (
      "flit sent during one-sided ACTIVATING was not reported")

    # ---- L-credit underflow ----------------------------------------------
    # A flit launched with no credit ever granted. The driver refuses to send at
    # zero credit, so this can only mean a flit went out unauthorized.
    c = _checker()
    _feed(c, [_sample(_RUN, txreqflitv=1)])
    assert self._fired(c, "CHI_LCRD_UNDERFLOW") == 1, (
      "L-credit underflow was not reported")

    # ---- L-credit overflow -----------------------------------------------
    c = _checker()
    _feed(c, [_sample(_RUN, rxreqlcrdv=1) for _ in range(65)])
    assert self._fired(c, "CHI_LCRD_OVERFLOW") >= 1, (
      "L-credit grant past the tracked cap was not reported")

    # ---- Same-cycle grant and consume must NOT underflow ------------------
    # The positive control for the pair above, and the one that matters most:
    # the SV checker's comments record two earlier attempts that false-fired
    # here because grant and consume raced. The pool must sequence 0 -> 1 -> 0.
    c = _checker()
    _feed(c, [_sample(_RUN, rxreqlcrdv=1, txreqflitv=1)])
    assert self._fired(c, "CHI_LCRD_UNDERFLOW") == 0, (
      "a same-cycle grant and consume was miscounted as an underflow")

    # ---- TXSACTIVE still asserted after the link went down ----------------
    c = _checker()
    _feed(c, [_sample(_STOP), _sample(_STOP, txsactive=1)])
    assert self._fired(c, "CHI_LINK_DEACTIVATE_WHEN_IDLE") == 1, (
      "txsactive held past link deactivation was not reported")

    # ---- Reset idle -------------------------------------------------------
    c = _checker()
    c._check_reset_idle(_sample(_RUN, txreqflitv=1))
    assert self._fired(c, "CHI_REQ_IDLE_IN_RESET") == 1, (
      "REQ traffic during reset was not reported")
    assert self._fired(c, "CHI_LINK_SIDEBAND_IDLE_IN_RESET") == 1, (
      "link sideband active during reset was not reported")

    # ---- Link fails to restart after reset --------------------------------
    # Armed only once the interface has been active, so an unbuilt interface
    # stays silent; see the gate comment in bind_chi._check_restart_window.
    c = _checker()
    c._link_ever_active = True
    c._act_countdown = _LINK_ACT_WINDOW_C
    for _ in range(_LINK_ACT_WINDOW_C + 2):
      c._check_restart_window(_sample(_STOP))
    assert self._fired(c, "CHI_LINK_RESTARTS_AFTER_RESET") == 1, (
      "a link that never reactivated after reset was not reported")

    # ---- ...and does not fire when it does restart in time ----------------
    c = _checker()
    c._link_ever_active = True
    c._act_countdown = _LINK_ACT_WINDOW_C
    for i in range(_LINK_ACT_WINDOW_C + 2):
      c._check_restart_window(
        _sample(_RUN if i == _LINK_ACT_WINDOW_C - 2 else _STOP))
    assert self._fired(c, "CHI_LINK_RESTARTS_AFTER_RESET") == 0, (
      "a link that reactivated inside the window was reported as failing")

    # ---- An unused interface must never arm the restart check -------------
    c = _checker()
    assert not c._link_ever_active, (
      "a checker must start unarmed so an interface with no agent cannot "
      "report a spurious restart failure")

    # =======================================================================
    # Transaction layer
    # =======================================================================
    # Everything below is judged across cycles rather than from one sample, so
    # each case drives a short scripted transaction rather than a single flit.

    # ---- A TxnID reused while its first use is still outstanding ----------
    c = _checker()
    _feed_txn(c, [
      _req(opcode=int(ReqOpcode.READ_NO_SNP), txnid=5, size=4),
      _req(opcode=int(ReqOpcode.READ_NO_SNP), txnid=5, size=4),
    ])
    assert self._fired(c, "CHI_TXNID_REUSE_REQUESTER") == 1, (
      "a TxnID reused while the first request was in flight was not reported")

    # ---- ...and a completer sees the same reuse from its own side ---------
    c = _checker(Role.SNF)
    _feed_txn(c, [
      _req("rx", opcode=int(ReqOpcode.READ_NO_SNP), txnid=5, size=4),
      _req("rx", opcode=int(ReqOpcode.READ_NO_SNP), txnid=5, size=4),
    ])
    assert self._fired(c, "CHI_TXNID_REUSE_COMPLETER") == 1, (
      "a completer did not report an inbound reused TxnID")

    # ---- Write data sent with no DBID grant behind it ---------------------
    c = _checker()
    _feed_txn(c, [
      _dat(opcode=int(DatOpcode.NON_COPY_BACK_WR_DATA), txnid=3, dbid=3),
    ])
    assert self._fired(c, "CHI_WRITE_DAT_BEFORE_DBID") == 1, (
      "write DAT ahead of its DBID grant was not reported")

    # ---- Write data tagged with a TxnID that is not its DBID --------------
    c = _checker()
    _feed_txn(c, [
      _req(opcode=int(ReqOpcode.WRITE_NO_SNP_FULL), txnid=4, size=4),
      _rsp(opcode=int(RspOpcode.DBID_RESP), txnid=4, dbid=4),
      _dat(opcode=int(DatOpcode.NON_COPY_BACK_WR_DATA), txnid=9, dbid=4),
    ])
    assert self._fired(c, "CHI_WRITE_DAT_TXNID_MATCHES_DBID") == 1, (
      "write DAT whose txnid did not match its DBID was not reported")
    assert self._fired(c, "CHI_WRITE_DAT_BEFORE_DBID") == 0, (
      "a granted write was miscounted as ungranted")

    # ---- CompAck with nothing to acknowledge ------------------------------
    c = _checker()
    _feed_txn(c, [_rsp("tx", opcode=int(RspOpcode.COMP_ACK), txnid=2)])
    assert self._fired(c, "CHI_COMPACK_BEFORE_COMPLETION") == 1, (
      "CompAck ahead of any completion was not reported")
    assert self._fired(c, "CHI_COMPACK_WITHOUT_EXPCOMPACK") == 1, (
      "CompAck for a request that never asked for one was not reported")

    # ---- A burst that does not start at DataID 0 --------------------------
    c = _checker()
    _feed_txn(c, [_dat(opcode=int(DatOpcode.COMP_DATA), txnid=1, dataid=1)])
    assert self._fired(c, "CHI_TX_DAT_FIRST_BEAT_DATAID_ZERO") == 1, (
      "a burst starting away from dataid 0 was not reported")

    # ---- A burst whose DataIDs skip a position ----------------------------
    c = _checker()
    _feed_txn(c, [
      _dat(pend=1, opcode=int(DatOpcode.COMP_DATA), txnid=1, dataid=0),
      _dat(opcode=int(DatOpcode.COMP_DATA), txnid=1, dataid=2),
    ])
    assert self._fired(c, "CHI_TX_DAT_DATAID_SEQUENTIAL") == 1, (
      "a non-sequential dataid inside a burst was not reported")

    # ---- A burst that changes TxnID mid-flight ----------------------------
    c = _checker()
    _feed_txn(c, [
      _dat(pend=1, opcode=int(DatOpcode.COMP_DATA), txnid=1, dataid=0),
      _dat(opcode=int(DatOpcode.COMP_DATA), txnid=2, dataid=1),
    ])
    assert self._fired(c, "CHI_TX_DAT_TXNID_STABLE") == 1, (
      "a burst that changed txnid before flitpend dropped was not reported")

    # ---- Write burst shorter than the size its request asked for ----------
    # size 6 = 64 bytes over the 16-byte datapath = 4 beats; one is sent.
    c = _checker()
    _feed_txn(c, [
      _req(opcode=int(ReqOpcode.WRITE_NO_SNP_FULL), txnid=4, size=6),
      _rsp(opcode=int(RspOpcode.DBID_RESP), txnid=4, dbid=4),
      _dat(opcode=int(DatOpcode.NON_COPY_BACK_WR_DATA), txnid=4, dbid=4),
    ])
    assert self._fired(c, "CHI_TX_WRITE_DAT_BEAT_COUNT") == 1, (
      "a write burst shorter than its granted size was not reported")

    # ---- Read completion carrying the wrong DAT opcode --------------------
    c = _checker()
    _feed_txn(c, [
      _req(opcode=int(ReqOpcode.READ_NO_SNP), txnid=5, size=4),
      _dat("rx", opcode=int(DatOpcode.DATA_SEP_RESP), txnid=5),
    ])
    assert self._fired(c, "CHI_RX_READ_COMPLETION_DAT_OPCODE") == 1, (
      "a read completion with the wrong DAT opcode was not reported")

    # ---- Read completion shorter than the size its request asked for ------
    c = _checker()
    _feed_txn(c, [
      _req(opcode=int(ReqOpcode.READ_NO_SNP), txnid=5, size=6),
      _dat("rx", opcode=int(DatOpcode.COMP_DATA), txnid=5),
    ])
    assert self._fired(c, "CHI_RX_READ_COMPLETION_DAT_BEAT_COUNT") == 1, (
      "a read completion shorter than its request size was not reported")

    # ---- A request that is never completed --------------------------------
    c = _checker()
    _feed_txn(c, [_req(opcode=int(ReqOpcode.READ_NO_SNP), txnid=5, size=4)]
                 + _idle(_TIMEOUT_CYCLES_C + 2))
    assert self._fired(c, "CHI_COMPLETION_FOLLOWS_REQ") == 1, (
      "a request left uncompleted past the timeout was not reported")

    # ---- A data-returning atomic answered with a bare Comp ----------------
    c = _checker()
    _feed_txn(c, [
      _req(opcode=int(ReqOpcode.ATOMIC_LOAD_0), txnid=6, size=4),
      _rsp(opcode=int(RspOpcode.COMP), txnid=6),
    ])
    assert self._fired(c, "CHI_ATOMIC_RETURN_USES_DAT_COMPLETION") == 1, (
      "an atomic completed without returning its data was not reported")

    # ---- An ordered read whose data arrives before its ReadReceipt --------
    c = _checker()
    _feed_txn(c, [
      _req(opcode=int(ReqOpcode.READ_NO_SNP), txnid=5, size=4,
           order=int(ReqOrder.REQ_ORDER)),
      _dat("rx", opcode=int(DatOpcode.COMP_DATA), txnid=5),
    ])
    assert self._fired(c, "CHI_ORDERED_READ_RECEIPT_BEFORE_DAT") == 1, (
      "an ordered read completed before its ReadReceipt was not reported")

    # =======================================================================
    # Positive controls: well-formed transactions must fire nothing
    # =======================================================================
    # These matter more than the negatives above. Each check runs on every
    # cycle of every testcase in the suite, so one that false-fires on ordinary
    # traffic is worse than one that never fires at all.

    # ---- A four-beat read, request through last completion beat -----------
    c = _checker()
    _feed_txn(c, [
      _req(opcode=int(ReqOpcode.READ_NO_SNP), txnid=5, size=6),
      _dat("rx", pend=1, opcode=int(DatOpcode.COMP_DATA), txnid=5, dataid=0),
      _dat("rx", pend=1, opcode=int(DatOpcode.COMP_DATA), txnid=5, dataid=1),
      _dat("rx", pend=1, opcode=int(DatOpcode.COMP_DATA), txnid=5, dataid=2),
      _dat("rx", opcode=int(DatOpcode.COMP_DATA), txnid=5, dataid=3),
    ] + _idle(_TIMEOUT_CYCLES_C + 2))
    assert c.errors == 0, (
      f"a well-formed four-beat read raised {c.errors} violation(s): "
      f"{sorted(c.fail_count)}")

    # ---- A four-beat write, request through CompAck -----------------------
    c = _checker()
    _feed_txn(c, [
      _req(opcode=int(ReqOpcode.WRITE_NO_SNP_FULL), txnid=7, size=6,
           expcompack=1),
      _rsp(opcode=int(RspOpcode.COMP_DBID_RESP), txnid=7, dbid=7),
      _dat(pend=1, opcode=int(DatOpcode.NON_COPY_BACK_WR_DATA),
           txnid=7, dbid=7, dataid=0),
      _dat(pend=1, opcode=int(DatOpcode.NON_COPY_BACK_WR_DATA),
           txnid=7, dbid=7, dataid=1),
      _dat(pend=1, opcode=int(DatOpcode.NON_COPY_BACK_WR_DATA),
           txnid=7, dbid=7, dataid=2),
      _dat(opcode=int(DatOpcode.NON_COPY_BACK_WR_DATA),
           txnid=7, dbid=7, dataid=3),
      _rsp("tx", opcode=int(RspOpcode.COMP_ACK), txnid=7),
    ] + _idle(_TIMEOUT_CYCLES_C + 2))
    assert c.errors == 0, (
      f"a well-formed four-beat write raised {c.errors} violation(s): "
      f"{sorted(c.fail_count)}")

    # ---- An ordered read receipted before its data ------------------------
    c = _checker()
    _feed_txn(c, [
      _req(opcode=int(ReqOpcode.READ_NO_SNP), txnid=5, size=4,
           order=int(ReqOrder.REQ_ORDER)),
      _rsp(opcode=int(RspOpcode.READ_RECEIPT), txnid=5),
      _dat("rx", opcode=int(DatOpcode.COMP_DATA), txnid=5),
    ] + _idle(_TIMEOUT_CYCLES_C + 2))
    assert self._fired(c, "CHI_ORDERED_READ_RECEIPT_BEFORE_DAT") == 0, (
      "a correctly receipted ordered read was reported as out of order")
    assert c.errors == 0, (
      f"a well-formed ordered read raised {c.errors} violation(s): "
      f"{sorted(c.fail_count)}")

    # ---- A retried request may reuse its TxnID ----------------------------
    # RetryAck retires the bounced request, so the re-issue is not a reuse.
    c = _checker()
    _feed_txn(c, [
      _req(opcode=int(ReqOpcode.READ_NO_SNP), txnid=5, size=4),
      _rsp(opcode=int(RspOpcode.RETRY_ACK), txnid=5),
      _req(opcode=int(ReqOpcode.READ_NO_SNP), txnid=5, size=4),
      _dat("rx", opcode=int(DatOpcode.COMP_DATA), txnid=5),
    ] + _idle(_TIMEOUT_CYCLES_C + 2))
    assert self._fired(c, "CHI_TXNID_REUSE_REQUESTER") == 0, (
      "a TxnID re-issued after a RetryAck was reported as a reuse")

    self.logger.info(
      "Test (tc_chi_sva_smoke) PASS: every bind_chi check family reported its "
      "induced violation, and no positive control false-fired")
    self.drop_objection()
