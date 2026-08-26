################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of vip_chi_coverage.sv -- functional coverage collector.
#
# Faithful port of the SV covergroups and their stateful sampling. Ten analysis
# imps (rni/snf/rnf x req/rsp/dat + snp) feed fourteen covergroups; the shared
# non-coherent env wires the rni/snf ports (cg_req/rsp/dat/write_flow/atomic/
# qos/mte/ordered_read/outstanding/recovery/addr_alignment) and the coherent env
# wires the rnf/snp ports (cg_coherent_req/snp_opcode/snp_resp). Coverage is
# observational and never affects a test verdict.
#
# pyvsc note: coverpoints have no per-point `iff`; where the SV guards a point
# (cp_write_txn_matches_dbid), the Python sample value defaults to 1 for the
# non-applicable opcodes, so the point is exercised but never mis-attributed.
#
################################################################################

from __future__ import annotations

import vsc

from pyuvm import uvm_component

from vip_chi_types_pkg import (
  Role, Dir, ReqOpcode, RspOpcode, DatOpcode, SnpOpcode, Resp, RespErr, ReqOrder,
  QOS_WIDTH, CACHE_LINE_BYTES, chi_size_bytes,
  req_opcode_is_atomic, req_opcode_is_atomic_returning_data, req_opcode_atomic_variant,
)
from vip_chi_analysis_imp import vip_chi_analysis_imp

_BIG = 1 << 20                       # open-ended range upper bound ([N:$])
_QOS_MAX = (1 << QOS_WIDTH) - 1
_TAGOP_MAX = (1 << 2) - 1

# Recovery / qos / mte channel enumerations (mirror the SV local enums).
_CH_REQ, _CH_RSP, _CH_DAT = 0, 1, 2
_MTE_REQ, _MTE_DAT = 0, 1


# ---------------------------------------------------------------------------
# Covergroups.
# ---------------------------------------------------------------------------
@vsc.covergroup
class cg_req:
  def __init__(self):
    self.with_sample(role=vsc.uint32_t(), direction=vsc.uint32_t(),
                     opcode=vsc.uint32_t(), size=vsc.uint32_t(),
                     comp_ack=vsc.uint32_t(), allow_retry=vsc.uint32_t(),
                     epoch=vsc.uint32_t())
    self.cp_role = vsc.coverpoint(self.role, bins=dict(
      rni=vsc.bin(int(Role.RNI)), snf=vsc.bin(int(Role.SNF))))
    self.cp_dir = vsc.coverpoint(self.direction, bins=dict(
      read=vsc.bin(int(Dir.READ)), write=vsc.bin(int(Dir.WRITE))))
    self.cp_opcode = vsc.coverpoint(self.opcode, bins=dict(
      read_no_snp=vsc.bin(int(ReqOpcode.READ_NO_SNP)),
      read_no_snp_sep=vsc.bin(int(ReqOpcode.READ_NO_SNP_SEP)),
      write_no_snp_ptl=vsc.bin(int(ReqOpcode.WRITE_NO_SNP_PTL)),
      write_no_snp_full=vsc.bin(int(ReqOpcode.WRITE_NO_SNP_FULL)),
      write_no_snp_zero=vsc.bin(int(ReqOpcode.WRITE_NO_SNP_ZERO)),
      prefetch_tgt=vsc.bin(int(ReqOpcode.PREFETCH_TGT))))
    self.cp_size = vsc.coverpoint(self.size, bins=dict(
      size_small=vsc.bin([0, 2]), size_medium=vsc.bin([3, 5]), size_large=vsc.bin(6)))
    self.cp_comp_ack = vsc.coverpoint(self.comp_ack, bins=dict(
      no=vsc.bin(0), yes=vsc.bin(1)))
    self.cp_allow_retry = vsc.coverpoint(self.allow_retry, bins=dict(
      no=vsc.bin(0), yes=vsc.bin(1)))
    self.cp_epoch = vsc.coverpoint(self.epoch, bins=dict(
      pre_reset_epoch=vsc.bin(0), post_reset_epoch=vsc.bin(1)))
    self.cx_opcode_dir = vsc.cross([self.cp_opcode, self.cp_dir])
    self.cx_opcode_comp_ack = vsc.cross([self.cp_opcode, self.cp_comp_ack])
    self.cx_opcode_epoch = vsc.cross([self.cp_opcode, self.cp_epoch])


@vsc.covergroup
class cg_rsp:
  def __init__(self):
    self.with_sample(role=vsc.uint32_t(), opcode=vsc.uint32_t(),
                     resp_err=vsc.uint32_t(), epoch=vsc.uint32_t())
    self.cp_role = vsc.coverpoint(self.role, bins=dict(
      rni=vsc.bin(int(Role.RNI)), snf=vsc.bin(int(Role.SNF))))
    self.cp_opcode = vsc.coverpoint(self.opcode, bins=dict(
      comp=vsc.bin(int(RspOpcode.COMP)),
      comp_dbid_resp=vsc.bin(int(RspOpcode.COMP_DBID_RESP)),
      dbid_resp=vsc.bin(int(RspOpcode.DBID_RESP)),
      comp_ack=vsc.bin(int(RspOpcode.COMP_ACK)),
      read_receipt=vsc.bin(int(RspOpcode.READ_RECEIPT))))
    self.cp_resp_err = vsc.coverpoint(self.resp_err, bins=dict(
      normal=vsc.bin(int(RespErr.OKAY)), exokay=vsc.bin(int(RespErr.EXOKAY)),
      dataerr=vsc.bin(int(RespErr.DERR)), nderr=vsc.bin(int(RespErr.NDERR))))
    self.cp_epoch = vsc.coverpoint(self.epoch, bins=dict(
      pre_reset_epoch=vsc.bin(0), post_reset_epoch=vsc.bin(1)))
    self.cx_opcode_resp_err = vsc.cross([self.cp_opcode, self.cp_resp_err])
    self.cx_opcode_epoch = vsc.cross([self.cp_opcode, self.cp_epoch])


@vsc.covergroup
class cg_dat:
  def __init__(self):
    self.with_sample(role=vsc.uint32_t(), opcode=vsc.uint32_t(), beats=vsc.uint32_t(),
                     resp_err=vsc.uint32_t(), first_data_id_zero=vsc.uint32_t(),
                     data_ids_contiguous=vsc.uint32_t(), write_txn_matches_dbid=vsc.uint32_t(),
                     epoch=vsc.uint32_t())
    self.cp_role = vsc.coverpoint(self.role, bins=dict(
      rni=vsc.bin(int(Role.RNI)), snf=vsc.bin(int(Role.SNF))))
    self.cp_opcode = vsc.coverpoint(self.opcode, bins=dict(
      wr_data=vsc.bin(int(DatOpcode.NON_COPY_BACK_WR_DATA)),
      comp_data=vsc.bin(int(DatOpcode.COMP_DATA)),
      wr_data_comp_ack=vsc.bin(int(DatOpcode.NCB_WR_DATA_COMP_ACK)),
      sep_resp=vsc.bin(int(DatOpcode.DATA_SEP_RESP))))
    self.cp_beats = vsc.coverpoint(self.beats, bins=dict(
      one=vsc.bin(1), few=vsc.bin([2, 4]), many=vsc.bin([5, _BIG])))
    self.cp_resp_err = vsc.coverpoint(self.resp_err, bins=dict(
      normal=vsc.bin(int(RespErr.OKAY)), exokay=vsc.bin(int(RespErr.EXOKAY)),
      dataerr=vsc.bin(int(RespErr.DERR)), nderr=vsc.bin(int(RespErr.NDERR))))
    self.cp_first_data_id_zero = vsc.coverpoint(self.first_data_id_zero, bins=dict(
      no=vsc.bin(0), yes=vsc.bin(1)))
    self.cp_data_ids_contiguous = vsc.coverpoint(self.data_ids_contiguous, bins=dict(
      no=vsc.bin(0), yes=vsc.bin(1)))
    self.cp_write_txn_matches_dbid = vsc.coverpoint(self.write_txn_matches_dbid, bins=dict(
      no=vsc.bin(0), yes=vsc.bin(1)))
    self.cp_epoch = vsc.coverpoint(self.epoch, bins=dict(
      pre_reset_epoch=vsc.bin(0), post_reset_epoch=vsc.bin(1)))
    self.cx_opcode_beats = vsc.cross([self.cp_opcode, self.cp_beats])
    self.cx_opcode_data_ids = vsc.cross([self.cp_opcode, self.cp_data_ids_contiguous])
    self.cx_opcode_resp_err = vsc.cross([self.cp_opcode, self.cp_resp_err])
    self.cx_opcode_write_txn_dbid = vsc.cross([self.cp_opcode, self.cp_write_txn_matches_dbid])
    self.cx_opcode_epoch = vsc.cross([self.cp_opcode, self.cp_epoch])


@vsc.covergroup
class cg_write_flow:
  def __init__(self):
    self.with_sample(first_rsp=vsc.uint32_t(), completion_rsp=vsc.uint32_t(),
                     dat_opcode=vsc.uint32_t(), comp_ack_expected=vsc.uint32_t(),
                     comp_ack_seen=vsc.uint32_t(), dbid_matches_req=vsc.uint32_t(),
                     split=vsc.uint32_t(), epoch=vsc.uint32_t())
    self.cp_first_rsp_opcode = vsc.coverpoint(self.first_rsp, bins=dict(
      comp=vsc.bin(int(RspOpcode.COMP)),
      comp_dbid_resp=vsc.bin(int(RspOpcode.COMP_DBID_RESP)),
      dbid_resp=vsc.bin(int(RspOpcode.DBID_RESP))))
    self.cp_completion_rsp_opcode = vsc.coverpoint(self.completion_rsp, bins=dict(
      comp=vsc.bin(int(RspOpcode.COMP)),
      comp_dbid_resp=vsc.bin(int(RspOpcode.COMP_DBID_RESP))))
    self.cp_dat_opcode = vsc.coverpoint(self.dat_opcode, bins=dict(
      wr_data=vsc.bin(int(DatOpcode.NON_COPY_BACK_WR_DATA)),
      wr_data_comp_ack=vsc.bin(int(DatOpcode.NCB_WR_DATA_COMP_ACK))))
    self.cp_comp_ack_expected = vsc.coverpoint(self.comp_ack_expected, bins=dict(
      no=vsc.bin(0), yes=vsc.bin(1)))
    self.cp_comp_ack_seen = vsc.coverpoint(self.comp_ack_seen, bins=dict(
      no=vsc.bin(0), yes=vsc.bin(1)))
    self.cp_dbid_matches_req = vsc.coverpoint(self.dbid_matches_req, bins=dict(
      no=vsc.bin(0), yes=vsc.bin(1)))
    self.cp_split = vsc.coverpoint(self.split, bins=dict(
      no=vsc.bin(0), yes=vsc.bin(1)))
    self.cp_epoch = vsc.coverpoint(self.epoch, bins=dict(
      pre_reset_epoch=vsc.bin(0), post_reset_epoch=vsc.bin(1)))
    self.cx_first_rsp_comp_ack = vsc.cross(
      [self.cp_first_rsp_opcode, self.cp_comp_ack_expected, self.cp_comp_ack_seen])
    self.cx_split_completion = vsc.cross([self.cp_split, self.cp_completion_rsp_opcode])
    self.cx_dat_comp_ack = vsc.cross([self.cp_dat_opcode, self.cp_comp_ack_expected])
    self.cx_split_epoch = vsc.cross([self.cp_split, self.cp_epoch])


@vsc.covergroup
class cg_recovery:
  def __init__(self):
    self.with_sample(channel=vsc.uint32_t(), role=vsc.uint32_t())
    self.cp_channel = vsc.coverpoint(self.channel, bins=dict(
      req=vsc.bin(_CH_REQ), rsp=vsc.bin(_CH_RSP), dat=vsc.bin(_CH_DAT)))
    self.cp_role = vsc.coverpoint(self.role, bins=dict(
      rni=vsc.bin(int(Role.RNI)), snf=vsc.bin(int(Role.SNF))))
    self.cx_channel_role = vsc.cross([self.cp_channel, self.cp_role])


@vsc.covergroup
class cg_addr_alignment:
  def __init__(self):
    self.with_sample(direction=vsc.uint32_t(), transfer_aligned=vsc.uint32_t(),
                     cacheline_aligned=vsc.uint32_t())
    self.cp_dir = vsc.coverpoint(self.direction, bins=dict(
      read=vsc.bin(int(Dir.READ)), write=vsc.bin(int(Dir.WRITE))))
    self.cp_transfer_aligned = vsc.coverpoint(self.transfer_aligned, bins=dict(
      no=vsc.bin(0), yes=vsc.bin(1)))
    self.cp_cacheline_aligned = vsc.coverpoint(self.cacheline_aligned, bins=dict(
      no=vsc.bin(0), yes=vsc.bin(1)))
    self.cx_dir_alignment = vsc.cross(
      [self.cp_dir, self.cp_transfer_aligned, self.cp_cacheline_aligned])


@vsc.covergroup
class cg_atomic:
  def __init__(self):
    self.with_sample(role=vsc.uint32_t(), kind=vsc.uint32_t(),
                     size=vsc.uint32_t(), returns_data=vsc.uint32_t())
    self.cp_role = vsc.coverpoint(self.role, bins=dict(
      rni=vsc.bin(int(Role.RNI)), snf=vsc.bin(int(Role.SNF))))
    self.cp_kind = vsc.coverpoint(self.kind, bins=dict(
      variant_0=vsc.bin(0), variant_1=vsc.bin(1), variant_2=vsc.bin(2),
      variant_3=vsc.bin(3), variant_4=vsc.bin(4), variant_5=vsc.bin(5),
      variant_6=vsc.bin(6), variant_7=vsc.bin(7), swap=vsc.bin(8), compare=vsc.bin(9)))
    self.cp_size = vsc.coverpoint(self.size, bins=dict(
      one_beat=vsc.bin([0, 2]), few_beats=vsc.bin([3, 6])))
    self.cp_returns_data = vsc.coverpoint(self.returns_data, bins=dict(
      no=vsc.bin(0), yes=vsc.bin(1)))
    self.cx_kind_size = vsc.cross([self.cp_kind, self.cp_size])
    self.cx_kind_returns_data = vsc.cross([self.cp_kind, self.cp_returns_data])


@vsc.covergroup
class cg_qos:
  def __init__(self):
    self.with_sample(channel=vsc.uint32_t(), qos=vsc.uint32_t(), role=vsc.uint32_t())
    self.cp_channel = vsc.coverpoint(self.channel, bins=dict(
      req=vsc.bin(_CH_REQ), rsp=vsc.bin(_CH_RSP), dat=vsc.bin(_CH_DAT)))
    self.cp_qos = vsc.coverpoint(self.qos, bins=dict(
      all_values=vsc.bin_array([], [0, _QOS_MAX])))
    self.cp_role = vsc.coverpoint(self.role, bins=dict(
      rni=vsc.bin(int(Role.RNI)), snf=vsc.bin(int(Role.SNF))))
    self.cx_channel_qos = vsc.cross([self.cp_channel, self.cp_qos])


@vsc.covergroup
class cg_mte:
  def __init__(self):
    self.with_sample(channel=vsc.uint32_t(), tagop=vsc.uint32_t(),
                     has_tag=vsc.uint32_t(), has_tu=vsc.uint32_t())
    self.cp_channel = vsc.coverpoint(self.channel, bins=dict(
      req=vsc.bin(_MTE_REQ), dat=vsc.bin(_MTE_DAT)))
    self.cp_tagop = vsc.coverpoint(self.tagop, bins=dict(
      zero=vsc.bin(0), nonzero=vsc.bin_array([], [1, _TAGOP_MAX])))
    self.cp_has_tag = vsc.coverpoint(self.has_tag, bins=dict(no=vsc.bin(0), yes=vsc.bin(1)))
    self.cp_has_tu = vsc.coverpoint(self.has_tu, bins=dict(no=vsc.bin(0), yes=vsc.bin(1)))
    self.cx_channel_tagop = vsc.cross([self.cp_channel, self.cp_tagop])


@vsc.covergroup
class cg_ordered_read:
  def __init__(self):
    self.with_sample(order=vsc.uint32_t(), dat_opcode=vsc.uint32_t(),
                     receipt_seen=vsc.uint32_t())
    self.cp_order = vsc.coverpoint(self.order, bins=dict(
      accepted=vsc.bin(int(ReqOrder.REQ_ACCEPTED)), ordered=vsc.bin(int(ReqOrder.REQ_ORDER))))
    self.cp_dat_opcode = vsc.coverpoint(self.dat_opcode, bins=dict(
      comp_data=vsc.bin(int(DatOpcode.COMP_DATA)), sep_data=vsc.bin(int(DatOpcode.DATA_SEP_RESP))))
    self.cp_receipt_seen = vsc.coverpoint(self.receipt_seen, bins=dict(
      no=vsc.bin(0), yes=vsc.bin(1)))
    self.cx_order_receipt = vsc.cross([self.cp_order, self.cp_receipt_seen])
    self.cx_opcode_receipt = vsc.cross([self.cp_dat_opcode, self.cp_receipt_seen])


@vsc.covergroup
class cg_outstanding:
  def __init__(self):
    self.with_sample(reads=vsc.uint32_t(), writes=vsc.uint32_t())
    self.cp_reads = vsc.coverpoint(self.reads, bins=dict(
      zero=vsc.bin(0), one=vsc.bin(1), many=vsc.bin([2, _BIG])))
    self.cp_writes = vsc.coverpoint(self.writes, bins=dict(
      zero=vsc.bin(0), one=vsc.bin(1), many=vsc.bin([2, _BIG])))
    self.cx_reads_writes = vsc.cross([self.cp_reads, self.cp_writes])


@vsc.covergroup
class cg_coherent_req:
  def __init__(self):
    self.with_sample(opcode=vsc.uint32_t(), direction=vsc.uint32_t())
    self.cp_opcode = vsc.coverpoint(self.opcode, bins=dict(
      read_shared=vsc.bin(int(ReqOpcode.READ_SHARED)),
      read_clean=vsc.bin(int(ReqOpcode.READ_CLEAN)),
      read_unique=vsc.bin(int(ReqOpcode.READ_UNIQUE)),
      clean_unique=vsc.bin(int(ReqOpcode.CLEAN_UNIQUE)),
      make_unique=vsc.bin(int(ReqOpcode.MAKE_UNIQUE)),
      make_read_unique=vsc.bin(int(ReqOpcode.MAKE_READ_UNIQUE)),
      clean_invalid=vsc.bin(int(ReqOpcode.CLEAN_INVALID)),
      make_invalid=vsc.bin(int(ReqOpcode.MAKE_INVALID)),
      read_once=vsc.bin(int(ReqOpcode.READ_ONCE)),
      write_unique_full=vsc.bin(int(ReqOpcode.WRITE_UNIQUE_FULL)),
      write_unique_ptl=vsc.bin(int(ReqOpcode.WRITE_UNIQUE_PTL)),
      evict=vsc.bin(int(ReqOpcode.EVICT)),
      write_back_full=vsc.bin(int(ReqOpcode.WRITE_BACK_FULL)),
      write_clean_full=vsc.bin(int(ReqOpcode.WRITE_CLEAN_FULL))))
    self.cp_dir = vsc.coverpoint(self.direction, bins=dict(
      read=vsc.bin(int(Dir.READ)), write=vsc.bin(int(Dir.WRITE))))
    self.cx_opcode_dir = vsc.cross([self.cp_opcode, self.cp_dir])


@vsc.covergroup
class cg_snp_opcode:
  def __init__(self):
    self.with_sample(snp_opcode=vsc.uint32_t())
    self.cp_snp_opcode = vsc.coverpoint(self.snp_opcode, bins=dict(
      snp_shared=vsc.bin(int(SnpOpcode.SHARED)),
      snp_clean=vsc.bin(int(SnpOpcode.CLEAN)),
      snp_clean_shared=vsc.bin(int(SnpOpcode.CLEAN_SHARED)),
      snp_unique=vsc.bin(int(SnpOpcode.UNIQUE)),
      snp_clean_invalid=vsc.bin(int(SnpOpcode.CLEAN_INVALID)),
      snp_make_invalid=vsc.bin(int(SnpOpcode.MAKE_INVALID)),
      snp_query=vsc.bin(int(SnpOpcode.QUERY)),
      snp_shared_fwd=vsc.bin(int(SnpOpcode.SHARED_FWD)),
      snp_clean_fwd=vsc.bin(int(SnpOpcode.CLEAN_FWD)),
      snp_once_fwd=vsc.bin(int(SnpOpcode.ONCE_FWD)),
      snp_not_shared_dirty_fwd=vsc.bin(int(SnpOpcode.NOT_SHARED_DIRTY_FWD)),
      snp_unique_fwd=vsc.bin(int(SnpOpcode.UNIQUE_FWD))))


@vsc.covergroup
class cg_snp_resp:
  def __init__(self):
    self.with_sample(resp_state=vsc.uint32_t(), pass_dirty=vsc.uint32_t())
    self.cp_resp_state = vsc.coverpoint(self.resp_state, bins=dict(
      inv=vsc.bin(int(Resp.I)), sc=vsc.bin(int(Resp.SC)), uc=vsc.bin(int(Resp.UC)),
      ud=vsc.bin(int(Resp.UD_PD)), sd=vsc.bin(int(Resp.SD_PD))))
    self.cp_pass_dirty = vsc.coverpoint(self.pass_dirty, bins=dict(
      clean=vsc.bin(0), dirty=vsc.bin(1)))
    self.cx_state_pass_dirty = vsc.cross([self.cp_resp_state, self.cp_pass_dirty])


# ---------------------------------------------------------------------------
# Collector component.
# ---------------------------------------------------------------------------
class vip_chi_coverage(uvm_component):

  def __init__(self, name, parent):
    super().__init__(name, parent)
    self.cfg = None
    self.enabled = True
    self.reset_epoch = 0

    self.cg_req = cg_req()
    self.cg_rsp = cg_rsp()
    self.cg_dat = cg_dat()
    self.cg_write_flow = cg_write_flow()
    self.cg_recovery = cg_recovery()
    self.cg_addr_alignment = cg_addr_alignment()
    self.cg_atomic = cg_atomic()
    self.cg_qos = cg_qos()
    self.cg_mte = cg_mte()
    self.cg_ordered_read = cg_ordered_read()
    self.cg_outstanding = cg_outstanding()
    self.cg_coherent_req = cg_coherent_req()
    self.cg_snp_opcode = cg_snp_opcode()
    self.cg_snp_resp = cg_snp_resp()

    # Analysis-imp ports (allocated in build_phase).
    for p in ("rni_req_cov_port", "rni_rsp_cov_port", "rni_dat_cov_port",
              "snf_req_cov_port", "snf_rsp_cov_port", "snf_dat_cov_port",
              "rnf_req_cov_port", "rnf_rsp_cov_port", "rnf_dat_cov_port",
              "snp_cov_port"):
      setattr(self, p, None)

    self._reset_scratch()

  def set_cfg(self, cfg):
    self.cfg = cfg

  def build_phase(self):
    self.rni_req_cov_port = vip_chi_analysis_imp("rni_req_cov_port", self, self.write_rni_req)
    self.rni_rsp_cov_port = vip_chi_analysis_imp("rni_rsp_cov_port", self, self.write_rni_rsp)
    self.rni_dat_cov_port = vip_chi_analysis_imp("rni_dat_cov_port", self, self.write_rni_dat)
    self.snf_req_cov_port = vip_chi_analysis_imp("snf_req_cov_port", self, self.write_snf_req)
    self.snf_rsp_cov_port = vip_chi_analysis_imp("snf_rsp_cov_port", self, self.write_snf_rsp)
    self.snf_dat_cov_port = vip_chi_analysis_imp("snf_dat_cov_port", self, self.write_snf_dat)
    self.rnf_req_cov_port = vip_chi_analysis_imp("rnf_req_cov_port", self, self.write_rnf_req)
    self.rnf_rsp_cov_port = vip_chi_analysis_imp("rnf_rsp_cov_port", self, self.write_rnf_rsp)
    self.rnf_dat_cov_port = vip_chi_analysis_imp("rnf_dat_cov_port", self, self.write_rnf_dat)
    self.snp_cov_port = vip_chi_analysis_imp("snp_cov_port", self, self.write_snp)

  # ------------------------------------------------------------------------
  # Per-txn / per-role scratch (SV fixed arrays -> Python dicts keyed by txn).
  # ------------------------------------------------------------------------
  def _reset_scratch(self):
    self._epoch_sample = bool(self.reset_epoch)
    self.write_req_seen = {}
    self.write_first_rsp_seen = {}
    self.write_completion_seen = {}
    self.write_dat_seen = {}
    self.write_comp_ack_seen = {}
    self.write_flow_sampled = {}
    self.write_exp_comp_ack = {}
    self.write_dbid_matches_req = {}
    self.write_first_rsp_opcode = {}
    self.write_completion_rsp_opcode = {}
    self.write_dat_opcode = {}
    self.granted_req_txn_by_dbid = {}
    self.ordered_read_completion_valid_by_req = {}
    self.ordered_read_completion_txn_by_req = {}
    self.ordered_read_req_seen = {}
    self.ordered_read_receipt_seen = {}
    self.recovered_req_by_role = {0: False, 1: False}
    self.recovered_rsp_by_role = {0: False, 1: False}
    self.recovered_dat_by_role = {0: False, 1: False}

  def handle_reset(self):
    self.reset_epoch += 1
    self._reset_scratch()

  # ------------------------------------------------------------------------
  # Helpers.
  # ------------------------------------------------------------------------
  @staticmethod
  def _role_index(role):
    return 1 if int(role) == int(Role.SNF) else 0

  @staticmethod
  def _is_write_dat_opcode(opcode):
    return int(opcode) in (int(DatOpcode.NON_COPY_BACK_WR_DATA),
                           int(DatOpcode.NCB_WR_DATA_COMP_ACK))

  @staticmethod
  def _atomic_kind_bucket(opcode):
    op = int(opcode)
    if op == int(ReqOpcode.ATOMIC_SWAP):
      return 8
    if op == int(ReqOpcode.ATOMIC_COMPARE):
      return 9
    return req_opcode_atomic_variant(op)

  @staticmethod
  def _has_nonzero(seq):
    return any(int(v) != 0 for v in seq)

  @staticmethod
  def _data_ids_contiguous(item):
    ids = item.data_id
    if len(ids) < 2:
      return True
    for i in range(1, len(ids)):
      if int(ids[i]) != ((int(ids[i - 1]) + 1) & 0xFFFFFFFF):
        return False
    return True

  def _sample_qos(self, channel, qos, role):
    if not self.enabled:
      return
    self.cg_qos.sample(channel, int(qos), int(role))

  def _maybe_sample_recovery(self, channel, role):
    if self.reset_epoch == 0:
      return
    idx = self._role_index(role)
    table = {_CH_REQ: self.recovered_req_by_role,
             _CH_RSP: self.recovered_rsp_by_role,
             _CH_DAT: self.recovered_dat_by_role}[channel]
    if table.get(idx, False):
      return
    table[idx] = True
    self.cg_recovery.sample(channel, int(role))

  def _sample_outstanding(self):
    if not self.enabled:
      return
    reads = sum(1 for v in self.ordered_read_completion_valid_by_req.values() if v)
    writes = sum(1 for t in self.write_req_seen
                 if self.write_req_seen.get(t) and not self.write_completion_seen.get(t))
    self.cg_outstanding.sample(reads, writes)

  def _maybe_sample_write_flow(self, txn):
    if (not self.write_req_seen.get(txn) or self.write_flow_sampled.get(txn) or
        not self.write_dat_seen.get(txn) or not self.write_completion_seen.get(txn)):
      return
    if self.write_exp_comp_ack.get(txn) and not self.write_comp_ack_seen.get(txn):
      return
    split = 1 if int(self.write_first_rsp_opcode.get(txn, int(RspOpcode.COMP))) == \
      int(RspOpcode.DBID_RESP) else 0
    self.cg_write_flow.sample(
      int(self.write_first_rsp_opcode.get(txn, int(RspOpcode.COMP))),
      int(self.write_completion_rsp_opcode.get(txn, int(RspOpcode.COMP))),
      int(self.write_dat_opcode.get(txn, int(DatOpcode.NON_COPY_BACK_WR_DATA))),
      1 if self.write_exp_comp_ack.get(txn) else 0,
      1 if self.write_comp_ack_seen.get(txn) else 0,
      1 if self.write_dbid_matches_req.get(txn, True) else 0,
      split,
      1 if self.reset_epoch != 0 else 0)
    self.write_flow_sampled[txn] = True

  def _sample_mte_req(self, item):
    if not self.enabled or int(item.tagop) == 0:
      return
    self.cg_mte.sample(_MTE_REQ, int(item.tagop), 0, 0)

  def _sample_mte_dat(self, item):
    if not self.enabled:
      return
    has_tag = self._has_nonzero(item.tag)
    has_tu = self._has_nonzero(item.tu)
    if int(item.dat_tagop) == 0 and not has_tag and not has_tu:
      return
    self.cg_mte.sample(_MTE_DAT, int(item.dat_tagop), 1 if has_tag else 0, 1 if has_tu else 0)

  # ------------------------------------------------------------------------
  # Non-coherent sampling.
  # ------------------------------------------------------------------------
  def sample_req(self, item):
    if not self.enabled:
      return
    epoch = 1 if self.reset_epoch != 0 else 0
    self.cg_req.sample(int(item.role), int(item.direction), int(item.opcode),
                       int(item.size), int(item.exp_comp_ack), int(item.allow_retry), epoch)
    self._sample_qos(_CH_REQ, item.qos, item.role)
    self._maybe_sample_recovery(_CH_REQ, item.role)

    size_bytes = chi_size_bytes(int(item.size))
    transfer_aligned = 1 if (size_bytes == 0 or (int(item.addr) % size_bytes) == 0) else 0
    cacheline_aligned = 1 if (int(item.addr) % CACHE_LINE_BYTES) == 0 else 0
    self.cg_addr_alignment.sample(int(item.direction), transfer_aligned, cacheline_aligned)

    if req_opcode_is_atomic(int(item.opcode)):
      self.cg_atomic.sample(int(item.role), self._atomic_kind_bucket(item.opcode),
                            int(item.size),
                            1 if req_opcode_is_atomic_returning_data(int(item.opcode)) else 0)

    self._sample_mte_req(item)

    if (int(item.role) == int(Role.RNI) and int(item.direction) == int(Dir.READ) and
        int(item.order) != int(ReqOrder.NONE) and
        int(item.opcode) in (int(ReqOpcode.READ_NO_SNP), int(ReqOpcode.READ_NO_SNP_SEP))):
      txn = int(item.txn_id)
      completion_txn = int(item.return_txn_id) if int(item.opcode) == \
        int(ReqOpcode.READ_NO_SNP_SEP) else txn
      self.ordered_read_completion_valid_by_req[txn] = True
      self.ordered_read_completion_txn_by_req[txn] = completion_txn
      self.ordered_read_req_seen[completion_txn] = True
      self.ordered_read_receipt_seen[completion_txn] = False

    if int(item.role) == int(Role.RNI) and int(item.direction) == int(Dir.WRITE):
      txn = int(item.txn_id)
      self.write_req_seen[txn] = True
      self.write_first_rsp_seen[txn] = False
      self.write_completion_seen[txn] = False
      self.write_dat_seen[txn] = False
      self.write_comp_ack_seen[txn] = False
      self.write_flow_sampled[txn] = False
      self.write_exp_comp_ack[txn] = bool(int(item.exp_comp_ack))
      self.write_dbid_matches_req[txn] = False
      self.write_first_rsp_opcode[txn] = int(RspOpcode.COMP)
      self.write_completion_rsp_opcode[txn] = int(RspOpcode.COMP)
      self.write_dat_opcode[txn] = int(DatOpcode.NON_COPY_BACK_WR_DATA)

    self._sample_outstanding()

  def sample_rsp(self, item):
    if not self.enabled:
      return
    epoch = 1 if self.reset_epoch != 0 else 0
    self.cg_rsp.sample(int(item.role), int(item.rsp_opcode), int(item.rsp_resp_err), epoch)
    self._sample_qos(_CH_RSP, item.qos, item.role)
    self._maybe_sample_recovery(_CH_RSP, item.role)

    txn = int(item.txn_id)
    if int(item.role) == int(Role.SNF) and int(item.rsp_opcode) == int(RspOpcode.READ_RECEIPT):
      if self.ordered_read_completion_valid_by_req.get(txn):
        ctxn = self.ordered_read_completion_txn_by_req.get(txn)
        self.ordered_read_receipt_seen[ctxn] = True

    if int(item.role) == int(Role.SNF) and self.write_req_seen.get(txn):
      if not self.write_first_rsp_seen.get(txn):
        self.write_first_rsp_seen[txn] = True
        self.write_first_rsp_opcode[txn] = int(item.rsp_opcode)
        if int(item.rsp_opcode) in (int(RspOpcode.DBID_RESP), int(RspOpcode.COMP_DBID_RESP)):
          self.write_dbid_matches_req[txn] = (int(item.dbid) == txn)
        else:
          self.write_dbid_matches_req[txn] = True

      if int(item.rsp_opcode) in (int(RspOpcode.DBID_RESP), int(RspOpcode.COMP_DBID_RESP)):
        self.granted_req_txn_by_dbid[int(item.dbid)] = txn

      if int(item.rsp_opcode) in (int(RspOpcode.COMP), int(RspOpcode.COMP_DBID_RESP)):
        self.write_completion_seen[txn] = True
        self.write_completion_rsp_opcode[txn] = int(item.rsp_opcode)

      self._maybe_sample_write_flow(txn)

    elif (int(item.role) == int(Role.RNI) and
          int(item.rsp_opcode) == int(RspOpcode.COMP_ACK) and self.write_req_seen.get(txn)):
      self.write_comp_ack_seen[txn] = True
      self._maybe_sample_write_flow(txn)

    self._sample_outstanding()

  def sample_dat(self, item):
    if not self.enabled:
      return
    epoch = 1 if self.reset_epoch != 0 else 0
    beats = len(item.data)
    first_data_id_zero = 1 if (len(item.data_id) == 0 or int(item.data_id[0]) == 0) else 0
    data_ids_contiguous = 1 if self._data_ids_contiguous(item) else 0
    write_txn_matches_dbid = 1 if (not self._is_write_dat_opcode(item.dat_opcode) or
                                   int(item.txn_id) == int(item.dbid)) else 0
    if len(item.dat_resp_err) > 0:
      resp_err = int(item.dat_resp_err[0])
    else:
      resp_err = int(item.rsp_resp_err)

    self.cg_dat.sample(int(item.role), int(item.dat_opcode), beats, resp_err,
                       first_data_id_zero, data_ids_contiguous, write_txn_matches_dbid, epoch)
    self._sample_qos(_CH_DAT, item.qos, item.role)
    self._sample_mte_dat(item)
    self._maybe_sample_recovery(_CH_DAT, item.role)

    txn = int(item.txn_id)
    if (int(item.role) == int(Role.SNF) and
        int(item.dat_opcode) in (int(DatOpcode.COMP_DATA), int(DatOpcode.DATA_SEP_RESP))):
      if self.ordered_read_req_seen.get(txn):
        receipt_seen = bool(self.ordered_read_receipt_seen.get(txn))
        order = int(ReqOrder.REQ_ORDER) if receipt_seen else int(ReqOrder.REQ_ACCEPTED)
        self.cg_ordered_read.sample(order, int(item.dat_opcode), 1 if receipt_seen else 0)
        self.ordered_read_req_seen[txn] = False
        self.ordered_read_receipt_seen[txn] = False

    if int(item.role) == int(Role.RNI) and self._is_write_dat_opcode(item.dat_opcode):
      dbid = int(item.dbid)
      wtxn = self.granted_req_txn_by_dbid.get(dbid, txn)
      if self.write_req_seen.get(wtxn):
        self.write_dat_seen[wtxn] = True
        self.write_dat_opcode[wtxn] = int(item.dat_opcode)
        self._maybe_sample_write_flow(wtxn)

    self._sample_outstanding()

  # ------------------------------------------------------------------------
  # Coherent (Tier C) sampling.
  # ------------------------------------------------------------------------
  def sample_coherent_req(self, item):
    if not self.enabled:
      return
    self.cg_coherent_req.sample(int(item.opcode), int(item.direction))

  def sample_snp(self, item):
    if not self.enabled:
      return
    self.cg_snp_opcode.sample(int(item.snp_opcode))

  def sample_snp_resp_clean(self, item):
    if not self.enabled:
      return
    self.cg_snp_resp.sample(int(item.rsp_resp), 0)

  def sample_snp_resp_dirty(self, item):
    if not self.enabled:
      return
    state = int(item.dat_resp[-1]) if len(item.dat_resp) > 0 else int(Resp.I)
    self.cg_snp_resp.sample(state, 1)

  # ------------------------------------------------------------------------
  # Analysis-imp write handlers.
  # ------------------------------------------------------------------------
  def write_rni_req(self, item): self.sample_req(item)
  def write_rni_rsp(self, item): self.sample_rsp(item)
  def write_rni_dat(self, item): self.sample_dat(item)
  def write_snf_req(self, item): self.sample_req(item)
  def write_snf_rsp(self, item): self.sample_rsp(item)
  def write_snf_dat(self, item): self.sample_dat(item)

  def write_rnf_req(self, item):
    if int(item.role) == int(Role.RNF):
      self.sample_coherent_req(item)

  def write_rnf_rsp(self, item):
    if int(item.role) == int(Role.RNF) and int(item.rsp_opcode) == int(RspOpcode.SNP_RESP):
      self.sample_snp_resp_clean(item)

  def write_rnf_dat(self, item):
    if int(item.role) == int(Role.RNF) and int(item.dat_opcode) in (
        int(DatOpcode.SNP_RESP_DATA), int(DatOpcode.SNP_RESP_DATA_FWDED)):
      self.sample_snp_resp_dirty(item)

  def write_snp(self, item):
    if getattr(item, "is_snoop", False):
      self.sample_snp(item)
