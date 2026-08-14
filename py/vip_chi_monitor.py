################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of vip_chi_monitor.sv.
#
# Passive 4-channel monitor. Each observed edge it samples every asserted tx/rx
# {req,rsp,dat,snp} flitv, unpacks the flit through the vip_chi_types_pkg codec,
# and publishes a vip_chi_item on the matching analysis port. A tx-side flit is
# attributed to THIS endpoint's role; an rx-side flit to the peer role.
#
# REQ/RSP/SNP publish one item per flit; DAT is reassembled into ONE item per
# transfer. The beat count is correlated from the REQ (plain reads key by the
# echoed TxnID; writes/atomic operands stage by TxnID and promote to the granted
# DBID on the DBID-carrying RSP), falling back to the advisory FLITPEND deassert
# when the count is unknown -- mirroring the SV monitor exactly.
#
# The single-flit field mapping stays factored into module-level builders so it
# is unit-testable without a simulation; the class owns the stateful DAT
# reassembly + REQ/DAT correlation and the live ChiBus collect loop.
#
################################################################################

from __future__ import annotations

import vsc

from pyuvm import uvm_monitor, uvm_analysis_port

from vip_chi_types_pkg import (
  ChiCfg, Role, Dir, ReqOpcode, RspOpcode, DatOpcode, unpack,
  req_opcode_is_atomic, chi_xfer_dat_beats,
)
from vip_chi_if import ChiBus, CHANNELS
from vip_chi_item import vip_chi_item, defer_field_model

# Opcodes whose REQ ships data upstream (direction_from_opcode WRITE set).
_WRITE_DIR_OPCODES = {
  int(ReqOpcode.WRITE_NO_SNP_PTL), int(ReqOpcode.WRITE_NO_SNP_FULL),
  int(ReqOpcode.WRITE_NO_SNP_ZERO), int(ReqOpcode.WRITE_BACK_FULL),
  int(ReqOpcode.WRITE_CLEAN_FULL), int(ReqOpcode.WRITE_UNIQUE_FULL),
  int(ReqOpcode.WRITE_UNIQUE_PTL),
}

# DAT opcodes carrying requester-sourced write / atomic-operand data (keyed by
# the granted DBID) rather than data returned to the requester.
_WRITE_DAT_OPCODES = {
  int(DatOpcode.NON_COPY_BACK_WR_DATA), int(DatOpcode.NCB_WR_DATA_COMP_ACK),
  int(DatOpcode.COPY_BACK_WR_DATA),
}

_PLAIN_READ_OPCODES = {int(ReqOpcode.READ_NO_SNP), int(ReqOpcode.READ_NO_SNP_SEP)}

_DBID_GRANT_OPCODES = {
  int(RspOpcode.COMP_DBID_RESP), int(RspOpcode.DBID_RESP),
  int(RspOpcode.DBID_RESP_ORD),
}

# RSP opcodes that complete a transaction, for the t_comp milestone. DBIDResp
# alone is a buffer grant, not a completion, and has its own milestone.
_COMPLETION_RSP_OPCODES = {
  int(RspOpcode.COMP), int(RspOpcode.COMP_DBID_RESP),
  int(RspOpcode.COMP_PERSIST),
}

# Snoop-completing opcodes, per channel. A snoop answers with SnpResp on RSP or
# a SnpRespData family burst on DAT; either closes the snoop's latency window.
_SNP_RESP_RSP_OPCODES = {
  int(RspOpcode.SNP_RESP), int(RspOpcode.SNP_RESP_FWDED),
}
_SNP_RESP_DAT_OPCODES = {
  int(DatOpcode.SNP_RESP_DATA), int(DatOpcode.SNP_RESP_DATA_PTL),
  int(DatOpcode.SNP_RESP_DATA_FWDED),
}

# Bookkeeping kept in a transaction record but not published on the item: it
# tells the monitor which bound applies, and is not a milestone.
_TXN_REC_PRIVATE = frozenset({"is_write"})

_PEER = {
  Role.RNI: Role.SNF, Role.SNF: Role.RNI,
  Role.RNF: Role.HNF, Role.HNF: Role.RNF,
}


def peer_role(role: Role) -> Role:
  return _PEER.get(Role(role), Role.MONITOR)


def direction_from_opcode(opcode: int) -> Dir:
  op = int(opcode)
  if req_opcode_is_atomic(op) or op in _WRITE_DIR_OPCODES:
    return Dir.WRITE
  return Dir.READ


# ---------------------------------------------------------------------------
# flit -> item builders (pure; unit-testable without a simulator).
# ---------------------------------------------------------------------------


def req_item_from_flit(cfg: ChiCfg, flit: int, observed_role: Role) -> vip_chi_item:
  f = unpack(cfg, "req", flit)
  # Observed traffic: every field is filled from the flit and the item is
  # never randomized, so skip the constraint-model build.
  with defer_field_model():
    it = vip_chi_item("monitor_req_item", cfg)
  it.raw_override = True                     # observed, not solver-produced
  it.role = int(observed_role)
  it.direction = int(direction_from_opcode(f["opcode"]))
  it.src_id, it.tgt_id, it.txn_id = f["srcid"], f["tgtid"], f["txnid"]
  it.lp_id, it.return_nid, it.return_txn_id = f["lpid"], f["returnnid"], f["returntxnid"]
  it.qos, it.opcode, it.addr, it.size = f["qos"], f["opcode"], f["addr"], f["size"]
  it.ns, it.order, it.mem_attr, it.pcrd_type = f["ns"], f["order"], f["memattr"], f["pcrdtype"]
  it.allow_retry, it.excl, it.exp_comp_ack = f["allowretry"], f["excl"], f["expcompack"]
  it.tracetag, it.dodwt = f["tracetag"], f["dodwt"]
  it.likelyshared, it.endian, it.mpam = f["likelyshared"], f["endian"], f["mpam"]
  if cfg.is_e:
    it.tagop, it.group_id_ext = f.get("tagop", 0), f.get("groupidext", 0)
  return it


def rsp_item_from_flit(cfg: ChiCfg, flit: int, observed_role: Role) -> vip_chi_item:
  f = unpack(cfg, "rsp", flit)
  # Observed traffic: every field is filled from the flit and the item is
  # never randomized, so skip the constraint-model build.
  with defer_field_model():
    it = vip_chi_item("monitor_rsp_item", cfg)
  it.raw_override = True
  it.role = int(observed_role)
  it.src_id, it.tgt_id, it.txn_id = f["srcid"], f["tgtid"], f["txnid"]
  it.qos, it.rsp_opcode, it.dbid = f["qos"], f["opcode"], f["dbid"]
  it.rsp_resp, it.rsp_resp_err = f["resp"], f["resperr"]
  it.pcrd_type, it.fwd_state, it.tracetag = f["pcrdtype"], f["fwdstate"], f["tracetag"]
  # A DBID-carrying grant is labelled WRITE; every other RSP defaults READ.
  it.direction = int(Dir.WRITE) if f["opcode"] in _DBID_GRANT_OPCODES else int(Dir.READ)
  return it


def dat_item_from_flit(cfg: ChiCfg, flit: int, observed_role: Role) -> vip_chi_item:
  """Single-beat view of one DAT flit (the live monitor reassembles bursts)."""
  f = unpack(cfg, "dat", flit)
  # Observed traffic: every field is filled from the flit and the item is
  # never randomized, so skip the constraint-model build.
  with defer_field_model():
    it = vip_chi_item("monitor_dat_item", cfg)
  it.raw_override = True
  it.role = int(observed_role)
  it.src_id, it.tgt_id, it.txn_id = f["srcid"], f["tgtid"], f["txnid"]
  it.qos, it.dat_opcode, it.dbid = f["qos"], f["opcode"], f["dbid"]
  it.rsp_resp, it.rsp_resp_err = f["resp"], f["resperr"]
  it.data = [f["data"]]
  it.be = [f["be"]]
  it.data_id = [f["dataid"]]
  it.cc_id = [f["ccid"]]
  return it


def snp_item_from_flit(cfg: ChiCfg, flit: int, observed_role: Role) -> vip_chi_item:
  f = unpack(cfg, "snp", flit)
  # Observed traffic: every field is filled from the flit and the item is
  # never randomized, so skip the constraint-model build.
  with defer_field_model():
    it = vip_chi_item("monitor_snp_item", cfg)
  it.raw_override = True
  it.role = int(observed_role)
  it.is_snoop = True
  it.src_id, it.txn_id = f["srcid"], f["txnid"]
  it.qos, it.snp_opcode, it.snp_addr = f["qos"], f["opcode"], f["addr"]
  it.fwd_nid, it.fwd_txn_id = f["fwdnid"], f["fwdtxnid"]
  it.ns = f["ns"]
  it.ret_to_src, it.do_not_data_pull = bool(f["rettosrc"]), bool(f["donotdatapull"])
  return it


@vsc.covergroup
class cg_sactive:
  """TXSACTIVE / RXSACTIVE sideband coverage.

  Lives here rather than in vip_chi_coverage because these are per-interface
  WIRES sampled every cycle, while that collector is item-fed and shared across
  roles -- it never sees the interface, and an item-boundary sample would be a
  constant now that the sideband is held for the whole window.

  cx_tx_traffic is the bin that matters: TXSACTIVE asserted on a cycle with NO
  flit moving is the held-across-the-window behaviour, which a per-flit pulse
  could never produce. Its absence would mean the sideband had gone back to
  bracketing individual flits.
  """

  def __init__(self):
    self.with_sample(txsactive=vsc.uint32_t(), rxsactive=vsc.uint32_t(),
                     flit_moving=vsc.uint32_t())
    self.cp_txsactive = vsc.coverpoint(self.txsactive, bins=dict(
      low=vsc.bin(0), high=vsc.bin(1)))
    self.cp_rxsactive = vsc.coverpoint(self.rxsactive, bins=dict(
      low=vsc.bin(0), high=vsc.bin(1)))
    self.cp_flit_moving = vsc.coverpoint(self.flit_moving, bins=dict(
      idle=vsc.bin(0), traffic=vsc.bin(1)))
    self.cx_tx_traffic = vsc.cross([self.cp_txsactive, self.cp_flit_moving])
    self.cx_tx_rx = vsc.cross([self.cp_txsactive, self.cp_rxsactive])


class vip_chi_monitor(uvm_monitor):

  def __init__(self, name, parent):
    super().__init__(name, parent)
    self.cfg = None
    self.role = Role.MONITOR
    self.bus = None
    self.req_port = uvm_analysis_port("req_port", self)
    self.rsp_port = uvm_analysis_port("rsp_port", self)
    self.dat_port = uvm_analysis_port("dat_port", self)
    self.snp_port = uvm_analysis_port("snp_port", self)
    # DataID placement violations seen so far (duplicate, out-of-range, or a
    # position no beat carried). A self.logger.error() does not auto-fail pyUVM,
    # so the negative-control testcase asserts on this counter. Deliberately not
    # cleared by _reset_state(): it is a whole-run tally, not per-transfer state.
    self.n_dataid_violation = 0
    # Latency-bound violations. A whole-run tally like n_dataid_violation, and
    # like it deliberately NOT cleared by _reset_state().
    self.n_latency_violation = 0
    # cg_sactive and its last-sampled tuple. Sampled only on change: the bins
    # are three bits wide, so a per-cycle sample would add cost without adding
    # information.
    self.cg_sactive = cg_sactive()
    self._sactive_last = None
    self._reset_state()

  def _reset_state(self):
    # DAT reassembly state, keyed by (role, src, tgt, txnid).
    self.dat_item_by_key = {}
    self.dat_beats_by_key = {}
    # Which beat positions of an in-flight transfer have already been written,
    # so a repeated DataID is reported rather than silently overwriting the
    # earlier beat, and a position never written is reported at transfer close.
    # Only populated on the DataID-placed path.
    self.dat_beat_seen_by_key = {}
    # REQ->DAT beat-count correlation.
    self.rd_beats_by_txnid = {}
    self.wr_beats_by_txnid = {}
    self.wr_beats_by_dbid = {}
    # Reset-gated free-running cycle counter and the per-transaction milestone
    # records stamped from it (txn_id -> {field: cycle}). Counting cycles rather
    # than reading $time is what keeps every latency a timescale-independent
    # integer. It restarts at reset, along with the records, because a latency
    # spanning a reset is not a latency -- the transaction was abandoned.
    self.cycle_count = 0
    self.txn_times = {}
    self.snp_times = {}

  def set_bus(self, bus: ChiBus, cfg: ChiCfg, role: Role) -> None:
    self.bus = bus
    self.cfg = cfg
    self.role = role

  # Per-beat arrival cycles cost a list append on every beat of every transfer,
  # which is not worth paying in a long run for a detail most tests never read.
  # Set by the agent from its cfg; default off.
  collect_beat_timestamps = False

  # Latency bounds, 0 = unbounded. Set by the agent from its cfg.
  max_read_xact_latency = 0
  max_write_xact_latency = 0
  max_snp_xact_latency = 0

  def handle_reset(self):
    self._reset_state()

  def _sample_sactive(self):
    bus = self.bus
    moving = any(bus.get_or(f"{d}{ch}flitv")
                 for d in ("tx", "rx") for ch in ("req", "rsp", "dat"))
    tup = (1 if bus.get_or("txsactive") else 0,
           1 if bus.get_or("rxsactive") else 0,
           1 if moving else 0)
    if tup == self._sactive_last:
      return
    self._sactive_last = tup
    self.cg_sactive.sample(tup[0], tup[1], tup[2])

  # ==========================================================================
  # Transaction timestamps.
  #
  # Milestones arrive on different channels and are published as different
  # items -- the REQ on one, its Comp on another -- so a record per TxnID
  # accumulates them and every published item carries the whole set known so
  # far. That is what lets a sequence call latency() on the response it gets
  # back, instead of having to correlate two items itself.
  # ==========================================================================
  def _txn_rec(self, txn_id):
    return self.txn_times.setdefault(int(txn_id), {})

  def _stamp(self, item, txn_id):
    """Copy the accumulated milestones for this TxnID onto a published item."""
    rec = self.txn_times.get(int(txn_id))
    if not rec:
      return
    for field, cycle in rec.items():
      if field in _TXN_REC_PRIVATE:
        continue
      setattr(item, field, cycle)

  # ==========================================================================
  # Latency bounds. Checked once, at the transaction's completion milestone,
  # against the item's own timestamps -- so the number reported is the same one
  # a test can read back off the item, not a separately-derived figure that
  # could disagree with it.
  # ==========================================================================
  def _check_latency_bound(self, item, txn_id, is_write, is_snoop=False):
    if is_snoop:
      bound = self.max_snp_xact_latency
      kind = "snoop"
    elif is_write:
      bound = self.max_write_xact_latency
      kind = "write"
    else:
      bound = self.max_read_xact_latency
      kind = "read"
    if bound <= 0:
      return
    measured = item.latency()
    if measured <= bound:
      return
    self.n_latency_violation += 1
    opcode = int(item.snp_opcode) if is_snoop else int(item.opcode)
    self.logger.error(
      f"[{self.get_name()}] {kind} transaction txn_id 0x{int(txn_id):x} "
      f"(opcode=0x{opcode:x}) took {measured} cycles, exceeding the "
      f"configured bound of {bound}")

  def _publish_req(self, flit_int, observed_role):
    it = req_item_from_flit(self.cfg, flit_int, observed_role)
    op = int(it.opcode)
    if op in _PLAIN_READ_OPCODES:
      beats = chi_xfer_dat_beats(int(it.size), self.cfg.data_bytes)
      if beats > 0:
        self.rd_beats_by_txnid[int(it.txn_id)] = beats
    else:
      beats = it.get_payload_beat_count()
      if beats > 0:
        self.wr_beats_by_txnid[int(it.txn_id)] = beats

    # A REQ on a TxnID that already saw a RetryAck is the re-issue, not a new
    # transaction: it keeps the original record so retry_count accumulates and
    # latency() can measure from the re-issue the completer is answerable for.
    rec = self._txn_rec(it.txn_id)
    if rec.get("t_retry_ack"):
      rec["t_req_reissued"] = self.cycle_count
    else:
      rec.clear()
      rec["t_req_issued"] = self.cycle_count
    # Which bound will apply at completion. Recorded here because the request
    # opcode is the only place the direction is stated, and the completion
    # arrives on a different channel carrying a different item.
    rec["is_write"] = int(it.direction) == int(Dir.WRITE)
    self._stamp(it, it.txn_id)
    self.req_port.write(it)

  def _publish_rsp(self, flit_int, observed_role):
    it = rsp_item_from_flit(self.cfg, flit_int, observed_role)
    opc = int(it.rsp_opcode)
    if opc in _DBID_GRANT_OPCODES:
      txn = int(it.txn_id)
      if txn in self.wr_beats_by_txnid:
        self.wr_beats_by_dbid[int(it.dbid)] = self.wr_beats_by_txnid.pop(txn)

    rec = self._txn_rec(it.txn_id)
    if opc in _DBID_GRANT_OPCODES:
      rec.setdefault("t_dbid", self.cycle_count)
    if opc in _COMPLETION_RSP_OPCODES:
      rec.setdefault("t_comp", self.cycle_count)
    if opc == int(RspOpcode.COMP_ACK):
      rec.setdefault("t_compack", self.cycle_count)
    if opc == int(RspOpcode.RETRY_ACK):
      rec["t_retry_ack"] = self.cycle_count
      rec["retry_count"] = rec.get("retry_count", 0) + 1
    if opc == int(RspOpcode.PCRD_GRANT):
      # CHI makes PCrdGrant credit-typed rather than TxnID-correlated, so this
      # is only as good as the completer's choice of TxnID on the grant. It is
      # recorded for visibility, never used by a bound.
      rec.setdefault("t_pcrd_grant", self.cycle_count)
    self._stamp(it, it.txn_id)

    # A transaction whose completion is an RSP (a write, a data-less acquire, a
    # persist) is bounded here. A read completes on DAT and is bounded there.
    if opc in _COMPLETION_RSP_OPCODES:
      self._check_latency_bound(it, it.txn_id, rec.get("is_write", True))
    if opc in _SNP_RESP_RSP_OPCODES:
      self._close_snoop(it, it.txn_id)

    self.rsp_port.write(it)

  def _publish_snp(self, flit_int, observed_role):
    it = snp_item_from_flit(self.cfg, flit_int, observed_role)
    # Snoop records are kept apart from request records: a snoop's TxnID is
    # allocated by the home, a request's by the requester, and on a coherent
    # link both are visible on the same monitor. Sharing one map would let two
    # unrelated transactions that happen to pick the same number overwrite each
    # other's milestones.
    self.snp_times[int(it.txn_id)] = {"t_req_issued": self.cycle_count}
    it.t_req_issued = self.cycle_count
    self.snp_port.write(it)

  # A snoop completes on its SnpResp (RSP) or SnpRespData (DAT). Both carry the
  # snoop's TxnID, so the bound is evaluated wherever the response lands.
  def _close_snoop(self, item, txn_id):
    rec = self.snp_times.pop(int(txn_id), None)
    if rec is None:
      return
    item.t_req_issued = rec["t_req_issued"]
    item.t_comp = self.cycle_count
    self._check_latency_bound(item, txn_id, False, is_snoop=True)

  def _publish_dat(self, flit_int, flit_pending, observed_role):
    f = unpack(self.cfg, "dat", flit_int)
    dat_txn = f["txnid"]
    is_write_data = f["opcode"] in _WRITE_DAT_OPCODES

    if is_write_data:
      expected = self.wr_beats_by_dbid.get(dat_txn, 0)
    else:
      expected = self.rd_beats_by_txnid.get(dat_txn, 0)

    key = (int(observed_role), f["srcid"], f["tgtid"], dat_txn)

    it = self.dat_item_by_key.get(key)
    if it is None:
      # Observed traffic, never randomized - skip the constraint model.
      with defer_field_model():
        it = vip_chi_item("monitor_dat_item", self.cfg)
      it.raw_override = True
      it.role = int(observed_role)
      it.direction = int(Dir.WRITE) if is_write_data else int(Dir.READ)
      it.src_id, it.tgt_id, it.txn_id = f["srcid"], f["tgtid"], dat_txn
      it.dbid, it.qos = f["dbid"], f["qos"]
      it.poison, it.datacheck = f["poison"], f["datacheck"]
      it.dat_opcode = f["opcode"]
      if self.cfg.is_e:
        it.dat_tagop = f.get("tagop", 0)
      # Sized up front on the DataID-placed path so a beat can be written to
      # its own position; the fallback path still appends in arrival order.
      n = expected if expected > 0 else 0
      it.data, it.be = [0] * n, [0] * n
      it.data_id, it.cc_id = [0] * n, [0] * n
      it.dat_resp, it.dat_resp_err = [0] * n, [0] * n
      it.tag, it.tu = [0] * n, [0] * n
      self.dat_item_by_key[key] = it
      self.dat_beats_by_key[key] = 0
      if expected > 0:
        self.dat_beat_seen_by_key[key] = [False] * expected
      # First beat of this transfer. Recorded against the DAT TxnID, which for
      # write data is the granted DBID rather than the request's own TxnID --
      # the same correlation the beat-count bookkeeping above uses.
      self._txn_rec(dat_txn).setdefault("t_first_dat", self.cycle_count)

    if self.collect_beat_timestamps:
      it.t_dat_beats.append(self.cycle_count)

    # Place by DataID when the beat count is known; the running receive counter
    # stays the index only where no count is available to bound DataID against.
    if expected > 0:
      # The beat count can only become known once the correlating REQ or DBID
      # grant has been seen. That always precedes the data in this VIP, but an
      # item opened on the unknown-count path must not KeyError if it does not:
      # size the placement state on first use instead of assuming allocation.
      seen = self.dat_beat_seen_by_key.get(key)
      if seen is None or len(seen) < expected:
        seen = (seen or []) + [False] * (expected - len(seen or []))
        self.dat_beat_seen_by_key[key] = seen
        for lst in (it.data, it.be, it.data_id, it.cc_id,
                    it.dat_resp, it.dat_resp_err, it.tag, it.tu):
          lst.extend([0] * (expected - len(lst)))

      beat_index = int(f["dataid"])
      if beat_index >= expected:
        # Unplaceable: report it and drop the payload, but still count the beat
        # so the transfer retires. Its empty slot is named at transfer close.
        self.n_dataid_violation += 1
        self.logger.error(
          f"[{self.get_name()}] DAT DataID {beat_index} is outside the "
          f"{expected}-beat transfer for txn_id 0x{dat_txn:x} -- beat dropped")
        self.dat_beats_by_key[key] += 1
        if self.dat_beats_by_key[key] >= expected:
          self._retire_dat_transfer(key, it, dat_txn, is_write_data, expected)
        return
      if self.dat_beat_seen_by_key[key][beat_index]:
        self.n_dataid_violation += 1
        self.logger.error(
          f"[{self.get_name()}] duplicate DAT DataID {beat_index} for txn_id "
          f"0x{dat_txn:x}: this beat position was already delivered")
      self.dat_beat_seen_by_key[key][beat_index] = True
      it.data[beat_index] = f["data"]
      it.be[beat_index] = f["be"]
      it.data_id[beat_index] = f["dataid"]
      it.cc_id[beat_index] = f["ccid"]
      it.dat_resp[beat_index] = f["resp"]
      it.dat_resp_err[beat_index] = f["resperr"]
      it.tag[beat_index] = f.get("tag", 0)
      it.tu[beat_index] = f.get("tu", 0)
    else:
      it.data.append(f["data"])
      it.be.append(f["be"])
      it.data_id.append(f["dataid"])
      it.cc_id.append(f["ccid"])
      it.dat_resp.append(f["resp"])
      it.dat_resp_err.append(f["resperr"])
      it.tag.append(f.get("tag", 0))
      it.tu.append(f.get("tu", 0))
    self.dat_beats_by_key[key] += 1

    if expected > 0:
      done = self.dat_beats_by_key[key] >= expected
    else:
      done = not flit_pending

    if done:
      self._retire_dat_transfer(key, it, dat_txn, is_write_data, expected)

  # Publish a completed DAT transfer and drop its reassembly state.
  #
  # Every beat position must have been filled. On the DataID-placed path a
  # duplicate or out-of-range DataID consumes a beat of the expected count
  # without filling its slot, so the gap it leaves is named here instead of
  # being published as an untouched (zero) beat that reads as a data mismatch.
  def _retire_dat_transfer(self, key, it, dat_txn, is_write_data, expected):
    if expected > 0:
      for i, seen in enumerate(self.dat_beat_seen_by_key[key]):
        if not seen:
          self.n_dataid_violation += 1
          self.logger.error(
            f"[{self.get_name()}] DAT transfer for txn_id 0x{dat_txn:x} closed "
            f"with no beat carrying DataID {i} (of {expected})")

    self._txn_rec(dat_txn)["t_last_dat"] = self.cycle_count
    self._stamp(it, dat_txn)

    # Read data IS the completion; write data is not (its Comp bounds it on the
    # RSP side), so only the read direction is bounded here.
    if not is_write_data:
      self._check_latency_bound(it, dat_txn, False)
    if int(it.dat_opcode) in _SNP_RESP_DAT_OPCODES:
      self._close_snoop(it, dat_txn)

    self.dat_port.write(it)
    del self.dat_item_by_key[key]
    del self.dat_beats_by_key[key]
    self.dat_beat_seen_by_key.pop(key, None)
    if is_write_data:
      self.wr_beats_by_dbid.pop(dat_txn, None)
    else:
      self.rd_beats_by_txnid.pop(dat_txn, None)

  # ==========================================================================
  async def monitor_start(self):
    """Sample the bus each edge; publish every asserted tx/rx flit."""
    bus, me, peer = self.bus, self.role, peer_role(self.role)
    while True:
      await bus.rising()
      await bus.read_only()
      if bus.in_reset():
        continue

      # Advance BEFORE stamping, so the first observable cycle is 1 and 0 stays
      # available as "milestone not reached".
      self.cycle_count += 1

      self._sample_sactive()

      # An L-credit return (opcode 0 on every channel) is a link-layer flit, not
      # a transaction: it hands one credit back and names no address, no TxnID
      # and no data. Publishing one would invent a transaction the scoreboard
      # then waits forever to complete, so the filter belongs HERE rather than in
      # each _publish_* -- one place where a flit becomes an item, one place
      # where the link layer is separated from the protocol layer.
      if bus.get_or("txreqflitv") and not self._is_lcrd_return("req", bus.get("txreqflit")):
        self._publish_req(bus.get("txreqflit"), me)
      if bus.get_or("rxreqflitv") and not self._is_lcrd_return("req", bus.get("rxreqflit")):
        self._publish_req(bus.get("rxreqflit"), peer)

      if bus.get_or("txrspflitv") and not self._is_lcrd_return("rsp", bus.get("txrspflit")):
        self._publish_rsp(bus.get("txrspflit"), me)
      if bus.get_or("rxrspflitv") and not self._is_lcrd_return("rsp", bus.get("rxrspflit")):
        self._publish_rsp(bus.get("rxrspflit"), peer)

      if bus.get_or("txdatflitv") and not self._is_lcrd_return("dat", bus.get("txdatflit")):
        self._publish_dat(bus.get("txdatflit"), bus.get_or("txdatflitpend"), me)
      if bus.get_or("rxdatflitv") and not self._is_lcrd_return("dat", bus.get("rxdatflit")):
        self._publish_dat(bus.get("rxdatflit"), bus.get_or("rxdatflitpend"), peer)

      if bus.get_or("txsnpflitv") and not self._is_lcrd_return("snp", bus.get("txsnpflit")):
        self._publish_snp(bus.get("txsnpflit"), me)
      if bus.get_or("rxsnpflitv") and not self._is_lcrd_return("snp", bus.get("rxsnpflit")):
        self._publish_snp(bus.get("rxsnpflit"), peer)

  def _is_lcrd_return(self, channel: str, flit_int) -> bool:
    """True for an L-credit return flit on `channel` (opcode 0 on all four)."""
    return int(unpack(self.cfg, channel, int(flit_int))["opcode"]) == 0
