#!/usr/bin/env python3
"""Check SV/Python type-layer parity beyond opcode values.

`check_opcodes.py` compares opcode constants against the converted CHI
specification and across the two ports. This companion check covers the other
hand-transcribed surfaces that can drift while both ports still pass their own
tests:

  * SVA and scoreboard check registries, including order.
  * Non-opcode enum encodings.
  * Exact CHI-D / CHI-E flit field order for REQ/RSP/DAT/SNP.

The script compares the two VIP implementations to each other. It is not a
substitute for reading Appendix A of IHI 0050 for field meanings, but it catches
SV/Python pack/unpack drift before a behavioral review starts.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent


def _load_py_types():
  sys.path.insert(0, str(ROOT / "py"))
  import vip_chi_types_pkg as py_types

  return py_types


def _read_sv() -> str:
  return (ROOT / "sv" / "vip_chi_types_pkg.sv").read_text(encoding="utf-8")


def _sv_bit_value(sv: str, name: str) -> int | None:
  match = re.search(rf"\b{name}\s*=\s*\d+'([bdh])([0-9A-Fa-f_]+)", sv)
  if not match:
    return None
  base = {"b": 2, "d": 10, "h": 16}[match.group(1)]
  return int(match.group(2).replace("_", ""), base)


def _class_block(sv: str, class_name: str) -> str:
  match = re.search(rf"class {class_name}\b(.*?)\n\s*endclass", sv, re.S)
  if not match:
    raise RuntimeError(f"could not find {class_name}")
  return match.group(1)


def _struct_fields(block: str, struct_name: str) -> list[str]:
  matches = re.findall(
    r"typedef struct packed\s*\{([^{}]*)\}\s+([A-Za-z0-9_]+);", block, re.S
  )
  for body, name in matches:
    if name != struct_name:
      continue
    fields: list[str] = []
    for raw in body.splitlines():
      line = raw.split("//", 1)[0].strip()
      if not line:
        continue
      fields.append(line.rstrip(";").split()[-1])
    return fields
  raise RuntimeError(f"could not find {struct_name}")


def _sv_check_names(sv: str, enum_name: str, prefix: str, out_prefix: str) -> list[str]:
  match = re.search(
    rf"typedef enum int \{{(.*?){prefix}NUM_E\s*\n\s*\}} {enum_name};", sv, re.S
  )
  if not match:
    raise RuntimeError(f"could not find {enum_name}")
  return [out_prefix + name for name in re.findall(rf"{prefix}([A-Z0-9_]+)_E", match.group(1))]


def _compare_check_registries(sv: str, py_types) -> list[str]:
  errors: list[str] = []
  checks = [
    (
      "SVA_CHECK_IDS",
      _sv_check_names(sv, "vip_chi_check_id_t", "VIP_CHI_CHK_", "CHI_"),
      list(py_types.CHECK_IDS),
    ),
    (
      "SB_CHECK_IDS",
      _sv_check_names(sv, "vip_chi_sb_check_id_t", "VIP_CHI_SB_CHK_", "CHI_SB_"),
      list(py_types.CHECK_IDS_SB),
    ),
  ]

  for label, sv_names, py_names in checks:
    print(f"{label}: sv={len(sv_names)} py={len(py_names)}")
    if sv_names == py_names:
      print(f"{label}: order and names match")
      continue
    errors.append(f"{label}: registry mismatch")
    sv_set, py_set = set(sv_names), set(py_names)
    missing_py = sorted(sv_set - py_set)
    missing_sv = sorted(py_set - sv_set)
    if missing_py:
      print(f"{label}: missing_in_py={missing_py}")
    if missing_sv:
      print(f"{label}: missing_in_sv={missing_sv}")
    for idx, (sv_name, py_name) in enumerate(zip(sv_names, py_names)):
      if sv_name != py_name:
        print(f"{label}: first_order_mismatch index={idx} sv={sv_name} py={py_name}")
        break
  return errors


def _compare_non_opcode_enums(sv: str, py_types) -> list[str]:
  checks: list[tuple[str, str, int, int | None]] = []

  for py_name, sv_name in {
    "I": "VIP_CHI_RESP_STATE_I_E",
    "SC": "VIP_CHI_RESP_STATE_SC_E",
    "UC": "VIP_CHI_RESP_STATE_UC_E",
    "RESERVED_0": "VIP_CHI_RESP_RESERVED_0_E",
    "RESERVED_1": "VIP_CHI_RESP_RESERVED_1_E",
    "RESERVED_2": "VIP_CHI_RESP_RESERVED_2_E",
    "UD_PD": "VIP_CHI_RESP_STATE_UP_PD_DIRTY_E",
    "SD_PD": "VIP_CHI_RESP_STATE_SD_PD_DIRTY_E",
  }.items():
    checks.append(("Resp", py_name, int(py_types.Resp[py_name]), _sv_bit_value(sv, sv_name)))

  for py_name, sv_name in {
    "OKAY": "VIP_CHI_RESP_ERR_NORMAL_OKAY_E",
    "EXOKAY": "VIP_CHI_RESP_ERR_EXCLUSIVE_OKAY_E",
    "DERR": "VIP_CHI_RESP_ERR_DATA_ERROR_E",
    "NDERR": "VIP_CHI_RESP_ERR_NONDATA_ERROR_E",
  }.items():
    checks.append(("RespErr", py_name, int(py_types.RespErr[py_name]), _sv_bit_value(sv, sv_name)))

  enum_specs = [
    ("AtomicOp", py_types.AtomicOp, {m.name: f"VIP_CHI_ATOMIC_OP_{m.name}_E" for m in py_types.AtomicOp}),
    ("Issue", py_types.Issue, {"D": "VIP_CHI_ISSUE_D_E", "E": "VIP_CHI_ISSUE_E_E"}),
    ("Role", py_types.Role, {m.name: f"VIP_CHI_ROLE_{m.name}_E" for m in py_types.Role}),
    ("Dir", py_types.Dir, {"READ": "VIP_CHI_DIR_READ_E", "WRITE": "VIP_CHI_DIR_WRITE_E"}),
    ("RawChannel", py_types.RawChannel, {m.name: f"VIP_CHI_RAW_{m.name}_E" for m in py_types.RawChannel}),
    ("DataType", py_types.DataType, {m.name: f"VIP_CHI_DATA_{m.name}_E" for m in py_types.DataType}),
    (
      "ReqNs",
      py_types.ReqNs,
      {
        "SECURE": "VIP_CHI_REQ_SECURE_ACCESS_E",
        "NON_SECURE": "VIP_CHI_REQ_NON_SECURE_ACCESS_E",
      },
    ),
    (
      "Exclusive",
      py_types.Exclusive,
      {"NORMAL": "VIP_CHI_REQ_NORMAL_E", "EXCLUSIVE": "VIP_CHI_REQ_EXCLUSIVE_E"},
    ),
    (
      "ReqOrder",
      py_types.ReqOrder,
      {
        "NONE": "VIP_CHI_ORDER_NONE_E",
        "REQ_ACCEPTED": "VIP_CHI_ORDER_REQ_ACCEPTED_E",
        "REQ_ORDER": "VIP_CHI_ORDER_REQ_ORDER_E",
        "ENDPOINT": "VIP_CHI_ORDER_ENDPOINT_E",
      },
    ),
    (
      "LasmState",
      py_types.LasmState,
      {
        "STOP": "VIP_CHI_LASM_STOP_E",
        "DEACTIVATE": "VIP_CHI_LASM_DEACTIVATE_E",
        "ACTIVATE": "VIP_CHI_LASM_ACTIVATE_E",
        "RUN": "VIP_CHI_LASM_RUN_E",
      },
    ),
  ]

  for enum_name, py_enum, mapping in enum_specs:
    for member in py_enum:
      checks.append((enum_name, member.name, int(member), _sv_bit_value(sv, mapping[member.name])))

  failures = [(enum_name, name, py, sv_value) for enum_name, name, py, sv_value in checks if sv_value != py]
  print(f"non-opcode enum values checked: {len(checks)}")
  if not failures:
    print("non-opcode enum parity: clean")
    return []

  for enum_name, name, py, sv_value in failures:
    print(f"  {enum_name}.{name}: py={py} sv={sv_value}")
  return [f"non-opcode enum parity mismatch: {len(failures)}"]


def _compare_flit_layouts(sv: str, py_types) -> list[str]:
  channels = [
    ("req", "vip_chi_req_flit_t"),
    ("rsp", "vip_chi_rsp_flit_t"),
    ("dat", "vip_chi_dat_flit_t"),
    ("snp", "vip_chi_snp_flit_t"),
  ]
  failures: list[tuple[str, str, list[str], list[str]]] = []

  for issue, class_name, cfg in [
    (
      py_types.Issue.D,
      "vip_chi_types_d",
      py_types.ChiCfg(issue=py_types.Issue.D, node_id_width=7, addr_width=44, data_bytes=32),
    ),
    (
      py_types.Issue.E,
      "vip_chi_types_e",
      py_types.ChiCfg(issue=py_types.Issue.E, node_id_width=11, addr_width=48, data_bytes=64),
    ),
  ]:
    block = _class_block(sv, class_name)
    for channel, struct_name in channels:
      sv_fields = _struct_fields(block, struct_name)
      py_fields = [name for name, _ in py_types.flit_layout(cfg, channel)]
      print(f"{issue.name} {channel}: sv_fields={len(sv_fields)} py_fields={len(py_fields)}")
      if sv_fields != py_fields:
        failures.append((issue.name, channel, sv_fields, py_fields))

  if not failures:
    print("flit field order parity: clean")
    return []

  for issue, channel, sv_fields, py_fields in failures:
    print(f"  {issue} {channel}:")
    print(f"    sv={sv_fields}")
    print(f"    py={py_fields}")
  return [f"flit field order parity mismatch: {len(failures)}"]


def main() -> int:
  sv = _read_sv()
  py_types = _load_py_types()

  errors: list[str] = []
  errors.extend(_compare_check_registries(sv, py_types))
  errors.extend(_compare_non_opcode_enums(sv, py_types))
  errors.extend(_compare_flit_layouts(sv, py_types))

  if errors:
    print("\nFAILED:")
    for error in errors:
      print(f"  {error}")
    return 1

  print("\nSV/Python type parity checks passed")
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
