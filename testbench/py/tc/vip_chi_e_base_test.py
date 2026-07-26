################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of tc/vip_chi_e_base_test.sv (CHI-E integrated pair). Reuses the
# issue-agnostic vip_chi_base_test scaffolding (the ChiCfg is taken from the
# ChiBus, which is CHI-E here) and exposes the rni_wr_seq / rni_rd_seq handles
# the CHI-E tests drive.
#
################################################################################

from __future__ import annotations

from vip_chi_base_test import vip_chi_base_test


class vip_chi_e_base_test(vip_chi_base_test):

  def build_phase(self):
    super().build_phase()
    self.rni_wr_seq = self.rni0_wr_seq
    self.rni_rd_seq = self.rni0_rd_seq
