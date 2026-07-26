################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of tb/chi_tb_pkg.sv -- the shared CHI-D / CHI-E runtime configs
# and the directed-test address / node-id / payload constants.
#
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import ChiCfg, Issue

# ---- runtime configs (mirror CHI_D_CFG_C / CHI_E_WIDE_CFG_C) ----------------
CHI_D_CFG = ChiCfg(issue=Issue.D, node_id_width=11, addr_width=44, data_bytes=16)
CHI_D_WIDE_CFG = ChiCfg(issue=Issue.D, node_id_width=11, addr_width=44, data_bytes=64)
CHI_E_WIDE_CFG = ChiCfg(issue=Issue.E, node_id_width=11, addr_width=52, data_bytes=64)

# ---- CHI-D directed-test constants -----------------------------------------
ATOMIC_ADDR_C = 0x0000_1240
ATOMIC_VARIANT_BASE_ADDR_C = 0x0000_1800
ATOMIC_VARIANT_ADDR_STRIDE_C = 0x0000_0040
WRITE_READ_ADDR_C = 0x3000_8000
WRITE_ADDR_C = 0x3000_9000
DECERR_ADDR_C = 0x3000_A000
DERR_ADDR_C = 0x3000_B000
READ_ADDR_C = 0x2000_4000
AUTO_READ_ADDR_C = 0x1000_2000

AUTO_READ_TXN_ID_C = 0x44
RNI_NODE_ID_C = 0x012
SNF_NODE_ID_C = 0x031

# ---- CHI-E directed-test constants -----------------------------------------
E_MTE_ADDR_C = 0x0012_3456_7800
E_HNI_WRITE_READ_ADDR_C = 0x0012_3456_8000
E_PERSIST_ADDR_C = 0x0012_3456_7900
E_PERSIST_SEP_ADDR_C = 0x0012_3456_7A00
E_DBID_RESP_ORD_ADDR_C = 0x0012_3456_7D00
E_WRITE_ZERO_ADDR_C = 0x0012_3456_9000

E_MTE_WRITE_TXN_ID_C = 0x61
E_MTE_READ_TXN_ID_C = 0x62
E_MTE_RNI_NODE_ID_C = 0x01C
E_MTE_SNF_NODE_ID_C = 0x022
E_PERSIST_RNI_NODE_ID_C = 0x016
E_PERSIST_SNF_NODE_ID_C = 0x02B
E_PERSIST_SEP_RNI_NODE_ID_C = 0x017
E_PERSIST_SEP_SNF_NODE_ID_C = 0x02C
E_DBID_RESP_ORD_RNI_NODE_ID_C = 0x01D
E_DBID_RESP_ORD_SNF_NODE_ID_C = 0x026
E_MTE_WRITE_DATA_C = 0x1_2233_4455_6677_8899_AABB_CCDD_EEFF
E_MTE_WRITE_TAGOP_C = 0x2
E_MTE_WRITE_TAG_C = 0x3456
E_MTE_WRITE_TU_C = 0xB
