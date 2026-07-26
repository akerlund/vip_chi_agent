################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of tc/vip_chi_coherent_e_base_test.sv -- the CHI-E-only coherent
# scenarios' base. In the SV this fixes CHI_E_WIDE_CFG_C / chi_e_wide_types_t; in
# the py port the geometry is supplied by the harness (the E coherent tc_top
# publishes the wide ChiBus), so the base test body is geometry-agnostic and this
# is a thin extension of vip_chi_coherent_base_test.
#
################################################################################

from __future__ import annotations

from vip_chi_coherent_base_test import vip_chi_coherent_base_test


class vip_chi_coherent_e_base_test(vip_chi_coherent_base_test):
  pass
