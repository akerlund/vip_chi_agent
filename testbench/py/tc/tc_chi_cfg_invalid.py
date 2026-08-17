################################################################################
# pyUVM/cocotb port of tc/tc_chi_cfg_invalid.sv.
#
# Config self-validation.
#
# is_valid() exists so an inconsistent configuration is reported once, at build
# time, instead of surfacing later as a hang or a silently-ignored knob. This
# test drives it directly with silent=True (verdict only, no reports), one case
# per rule, so the expected failures do not pollute the test's own error count.
#
# Each case starts from a known-good config, breaks exactly one thing, and
# asserts is_valid() flips to False -- so a rule that stops working is caught,
# and so is a rule that starts rejecting a legal config.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_cfg_agent import VipChiCfgAgent, UVM_PASSIVE
from chi_base_test import chi_base_test


class tc_chi_cfg_invalid(chi_base_test):

  def __init__(self, name, parent):
    super().__init__(name, parent)
    self.rejected = 0
    self.accepted = 0

  def fresh(self) -> VipChiCfgAgent:
    """A known-good starting point for every case."""
    return VipChiCfgAgent("case")

  def expect_invalid(self, cfg, what):
    assert not cfg.is_valid(silent=True), \
      f"is_valid() accepted an invalid config: {what}"
    self.rejected += 1

  def expect_valid(self, cfg, what):
    assert cfg.is_valid(silent=True), \
      f"is_valid() rejected a legal config: {what}"
    self.accepted += 1

  async def run_phase(self):
    self.raise_objection()

    # A freshly-constructed config must be valid, or every case below is
    # meaningless.
    assert VipChiCfgAgent("baseline").is_valid(silent=True), \
      "a default-constructed VipChiCfgAgent is not valid"

    # ---- Rules that must REJECT --------------------------------------------
    c = self.fresh(); c.max_outstanding_read = 0
    self.expect_invalid(c, "max_outstanding_read below 1")

    c = self.fresh(); c.max_outstanding_write = -1
    self.expect_invalid(c, "max_outstanding_write below 1")

    c = self.fresh(); c.max_pcrd_budget = -1
    self.expect_invalid(c, "negative P-credit budget")

    c = self.fresh(); c.multi_outstanding_write = True
    self.expect_invalid(c, "multi_outstanding_write without multi_outstanding")

    c = self.fresh(); c.multi_outstanding_mixed = True
    self.expect_invalid(c, "multi_outstanding_mixed without multi_outstanding")

    c = self.fresh(); c.snf_reorder_ordered_service = True
    self.expect_invalid(c, "snf_reorder_ordered_service without multi_outstanding")

    c = self.fresh(); c.dat_interleave_depth = 0
    self.expect_invalid(c, "dat_interleave_depth of 0")

    c = self.fresh(); c.dat_interleave_depth = 2
    self.expect_invalid(c, "dat_interleave_depth above 1 without multi_outstanding")

    c = self.fresh()
    c.req_valid_delay_enabled = True
    c.req_valid_delay_gauss_enabled = True
    c.req_valid_delay_stddev = 0.0
    self.expect_invalid(c, "gaussian delay shaping with a zero spread")

    c = self.fresh()
    c.rsp_valid_delay_gauss_enabled = True
    self.expect_invalid(c, "gaussian shaping on a channel whose delay is off")

    c = self.fresh(); c.initial_req_credits = 65
    self.expect_invalid(c, "initial REQ credits above the send-credit cap")

    c = self.fresh(); c.initial_dat_credits = 65
    self.expect_invalid(c, "initial DAT credits above the send-credit cap")

    c = self.fresh(); c.initial_snp_credits = 65
    self.expect_invalid(c, "initial SNP credits above the send-credit cap")

    c = self.fresh(); c.force_retry_count = -1
    self.expect_invalid(c, "negative force_retry_count")

    c = self.fresh(); c.compack_timeout_cycles = -1
    self.expect_invalid(c, "negative CompAck timeout")

    c = self.fresh(); c.add_decerr_range(0x2000, 0x1000)
    self.expect_invalid(c, "inverted DECERR range")

    c = self.fresh(); c.add_derr_range(0x2000, 0x1000)
    self.expect_invalid(c, "inverted DERR range")

    c = self.fresh()
    c.add_decerr_range(0x1000, 0x2000)
    c.add_derr_range(0x1800, 0x2800)
    self.expect_invalid(c, "DECERR range overlapping a DERR range")

    c = self.fresh(); c.rnf_cache_max_lines = -1
    self.expect_invalid(c, "negative RN-F cache bound")

    c = self.fresh(); c.req_valid_delay_min = 99
    self.expect_invalid(c, "inverted REQ valid-delay window")

    c = self.fresh(); c.link_act_delay_min = -1
    self.expect_invalid(c, "negative link-activation delay")

    # ---- Rules that only WARN must not flip the verdict ---------------------
    c = self.fresh(); c.rnf_cache_max_lines = 1
    self.expect_valid(c, "single-line RN-F cache (no dirty writeback modeled)")

    c = self.fresh(); c.hnf_suppress_snoops = True
    self.expect_valid(c, "a negative-control knob set on purpose")

    c = self.fresh()
    c.hnf_downstream_en = True
    c.hnf_suppress_snoops = True
    self.expect_valid(c, "two-level hierarchy with snoops suppressed")

    # ---- Legal configurations must stay legal -------------------------------
    c = self.fresh()
    c.multi_outstanding = True
    c.multi_outstanding_mixed = True
    self.expect_valid(c, "the mixed overlap loop with its master enable")

    c = self.fresh()
    c.multi_outstanding = True
    c.snf_reorder_ordered_service = True
    self.expect_valid(c, "the ordered-service reorder knob with its master enable")

    c = self.fresh()
    c.multi_outstanding = True
    c.dat_interleave_depth = 4
    self.expect_valid(c, "DAT beat interleaving with its master enable")

    c = self.fresh()
    c.dat_valid_delay_enabled = True
    c.dat_valid_delay_gauss_enabled = True
    self.expect_valid(c, "gaussian delay shaping with its channel delay enabled")

    c = self.fresh()
    c.add_decerr_range(0x1000, 0x2000)
    c.add_derr_range(0x3000, 0x4000)
    self.expect_valid(c, "disjoint DECERR and DERR ranges")

    c = self.fresh(); c.is_active = UVM_PASSIVE
    self.expect_valid(c, "a passive agent")

    self.logger.info(
      f"Test (tc_chi_cfg_invalid) PASS: {self.rejected} rejection rules and "
      f"{self.accepted} accept/warn-only rules verified")
    self.drop_objection()
