################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of vip_chi_cfg_agent.sv.
#
# Per-agent runtime policy: role, active/passive, credit caps + initial grants,
# split-write / ordered-DBID policy, DECERR/DERR ranges, timeouts, and the
# (inert-until-Tier-C) coherent RN-F/HN-F knobs. A plain settable object; in SV
# it extends uvm_object only for the factory. Defaults mirror the SV class.
#
# mem_cfg (the SN-F backing-store config) is left None here and constructed by
# the memory-backed SN-F driver in Tier A2, so the config layer carries no hard
# dependency on the vip_memory port yet.
#
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import Role, Resp

# is_active values (mirror uvm_active_passive_enum).
UVM_ACTIVE = True
UVM_PASSIVE = False


class VipChiCfgAgent:

  def __init__(self, name: str = "vip_chi_cfg_agent"):
    self.name = name

    self.is_active = UVM_ACTIVE
    self.role = Role.SNF

    self.max_outstanding_read = 16
    self.max_outstanding_write = 16
    self.max_pcrd_budget = 8

    # Opt-in multi-outstanding datapath (Tier B). Default off = strict serial.
    self.multi_outstanding = False
    self.multi_outstanding_write = False
    self.multi_outstanding_mixed = False
    self.observed_peak_outstanding = 0
    self.observed_peak_mixed_inflight = 0

    # Initial LCRDV grants advertised after link activation per inbound channel.
    self.initial_req_credits = 8
    self.initial_rsp_credits = 8
    self.initial_dat_credits = 8

    # Local caps for peer-advertised send-side credits (via inbound LCRDV).
    self.req_send_credit_cap = 64
    self.rsp_send_credit_cap = 64
    self.dat_send_credit_cap = 64

    # Runtime DAT-credit back-pressure (tc_chi_d_credit_starvation).
    self.hold_dat_credit = False

    self.decerr_ranges = []   # list of (base, limit)
    self.derr_ranges = []     # list of (base, limit)

    self.force_retry_count = 0
    self.split_write_rsp = False
    self.ordered_dbid_resp = False

    self.mem_cfg = None       # constructed by the SN-F driver (A2)

    self.link_act_delay_enabled = True
    self.link_act_delay_min = 0
    self.link_act_delay_max = 4

    self.req_valid_delay_enabled = True
    self.req_valid_delay_min = 0
    self.req_valid_delay_max = 4

    self.rsp_valid_delay_enabled = False
    self.rsp_valid_delay_min = 0
    self.rsp_valid_delay_max = 2

    self.dat_valid_delay_enabled = False
    self.dat_valid_delay_min = 0
    self.dat_valid_delay_max = 2

    self.coverage_enabled = True
    self.allow_raw_override = True
    self.compack_timeout_cycles = 10000

    # -- Coherent RN-F / HN-F knobs (inert for non-coherent roles) -----------
    self.initial_snp_credits = 8
    self.snp_send_credit_cap = 64
    self.hold_snp_credit = False
    self.coh_read_shared_state = Resp.SC
    self.coh_read_unique_state = Resp.UC
    self.rnf_cache_max_lines = 0
    self.hnf_snoop_latency = 0
    self.hnf_suppress_snoops = False
    self.hnf_corrupt_dirty_merge = False
    self.exclusives_enabled = True
    self.hnf_force_excl_success = False
    self.hnf_enable_snoop_fwd = False
    self.hnf_corrupt_fwd_data = False
    self.hnf_downstream_en = False
    self.hnf_downstream_snf_id = 0
    self.hnf_downstream_corrupt_data = False
    self.hnf_downstream_force_decerr = False

  def add_decerr_range(self, base: int, limit: int) -> None:
    self.decerr_ranges.append((int(base), int(limit)))

  def add_derr_range(self, base: int, limit: int) -> None:
    self.derr_ranges.append((int(base), int(limit)))

  def __repr__(self):
    return (f"VipChiCfgAgent(role={Role(self.role).name}, "
            f"active={self.is_active}, multi_outstanding={self.multi_outstanding})")
