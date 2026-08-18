#!/usr/bin/env python3
"""Check this VIP's opcode encodings against the Arm CHI specification.

Every opcode constant here is a transcription of a number out of Arm IHI 0050,
and a transcription is exactly the kind of claim that rots quietly: a wrong hex
value produces a VIP that drives a legal-looking flit nothing will ever question,
and the testbench agrees with itself because both ends read the same wrong
constant. `docs/FUTURE_WORK.md` records what one such mistake already cost --
`MakeReadUnique` offered to a CHI-D requester, where the opcode does not fit the
field, caught by hand rather than by anything automatic.

This is the same discipline as scripts/check_vacuity.py, applied to the numbers
instead of the checks: read the authority, compare, and fail on a difference.

It compares three things and reports:

  PORT       the SV and Python packages disagree about an opcode's value, or one
             of them does not define it at all. Needs no specification, so it
             runs on any machine -- and it is the worst of the three: both ports
             would be internally consistent, each would pass its own regression,
             and the SV and Python runs of the "same" testcase would be driving
             different opcodes.
  MISMATCH   we define a name the spec also defines, at a different value. This
             is the one that produces wrong flits.
  UNKNOWN    we define a name the spec's tables do not have at all -- a typo, a
             renamed opcode, or an invention.
  ISSUE      an opcode our CHI-D pools may randomize onto that exists only in
             the Issue E table. Needs both specs (--spec-d).

and, informationally, how much of the spec's opcode space this VIP implements.
The last three read the four opcode tables (REQ / RSP / SNP / DAT) out of a
MARKDOWN conversion of the specification.

**The specification is not in this repository and must not be.** It is Arm's
copyrighted document; only our own constants live here. Point this at your local
conversion:

  python3 scripts/check_opcodes.py --spec-e ~/chi/IHI0050E.md \\
                                   --spec-d ~/chi/IHI0050D.md

or set CHI_SPEC_E_MD / CHI_SPEC_D_MD. With no spec available it says so and
checks only what it can -- an absent authority is not the same as a disagreement
with one, so a machine without the document is not blocked, it is just told what
went unchecked.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

# The channel prefix the spec puts on names we store bare. Our SNP enum drops the
# "Snp" that every snoop opcode carries, and each channel spells its own
# credit return ("ReqLCrdReturn", "RespLCrdReturn", ...), so a bare name is
# retried with the prefix before it is called unknown.
_CHANNEL_PREFIX_C = {"REQ": "req", "RSP": "resp", "SNP": "snp", "DAT": "data"}

# Rows to skip: reserved encodings, and names the spec parenthesises as removed
# ("Reserved (EOBarrier)").
_SKIP_ROW_C = re.compile(r"^reserved", re.IGNORECASE)

_ROW_C = re.compile(r"^\|\s*(0x[0-9A-Fa-f]+)\s*(?:-\s*(0x[0-9A-Fa-f]+)\s*)?\|(.*)\|\s*$")

# Every opcode constant in the SV package is declared at its channel's opcode
# width, which is what distinguishes the ~80 of them from every other localparam
# in a 1000-line file.
_SV_OPCODE_C = re.compile(
  r"\[VIP_CHI_MAX_(REQ|RSP|SNP|DAT)_OPCODE_WIDTH_C\s*-\s*1\s*:\s*0\]\s*"
  r"VIP_CHI_\1_(\w+?)_C\s*=\s*\d+'h([0-9A-Fa-f]+)")


def _parse_sv_package(path: Path) -> dict[str, dict[str, int]]:
  """The SV port's opcode constants, by channel.

  The two ports transcribe the same numbers from the same document into two
  files, and nothing has ever compared them. A divergence there is worse than a
  divergence from the spec: both ports would be internally consistent, each
  would pass its own regression, and the SV and Python runs of the "same"
  testcase would be driving different opcodes.
  """
  out: dict[str, dict[str, int]] = {c: {} for c in _CHANNEL_PREFIX_C}
  for channel, name, value in _SV_OPCODE_C.findall(path.read_text(encoding="utf-8")):
    out[channel][name] = int(value, 16)
  return out


def _norm(name: str) -> str:
  """Fold a name to the form both spellings agree on.

  WRITE_NO_SNP_FULL and WriteNoSnpFull are the same opcode written by two
  conventions; comparing them any other way means hand-maintaining a second
  table of names, which is one more thing that can be wrong.
  """
  return re.sub(r"[^a-z0-9]", "", name.lower())


def _parse_channel(text: str, channel: str) -> dict[str, int]:
  """Pull one channel's opcode table out of the spec markdown.

  The REQ table in Issue E is two-dimensional -- rows are Opcode[5:0] and the two
  columns are Opcode[6]=0 and Opcode[6]=1 -- so a row contributes two opcodes,
  the second at +0x40. Issue D has no Opcode[6] and one column. Reading the
  column count off the row is what lets one parser serve both documents.
  """
  start = text.find(f"## {channel} channel opcodes")
  if start < 0:
    return {}

  out: dict[str, int] = {}
  seen_row = False
  for line in text[start:].splitlines()[1:]:
    line = line.strip()
    # Stop at the next section, but only once this one's rows have been read:
    # the Issue E REQ table is split in two by a note, and the second half is
    # introduced by a plain "(continued)" caption rather than a heading. Running
    # past the end instead is what made the DAT channel appear to have 26
    # opcodes -- the slice was swallowing the PCrdType table further down.
    if seen_row and line.startswith("## "):
      break
    m = _ROW_C.match(line)
    if not m:
      continue
    seen_row = True
    lo = int(m.group(1), 16)
    hi = int(m.group(2), 16) if m.group(2) else lo
    cols = [c.strip() for c in m.group(3).split("|")]

    for col_index, name in enumerate(cols):
      if not name or _SKIP_ROW_C.match(name):
        continue
      base = lo + (0x40 * col_index)      # Opcode[6] for the E-format REQ table
      if hi == lo:
        out[_norm(name)] = base
        continue
      # A ranged row is an opcode family: AtomicStore over 0x28-0x2F is eight
      # opcodes whose low bits select the operation. Expand it so the members
      # can be matched individually, which is how this VIP names them.
      for i in range(hi - lo + 1):
        out[_norm(f"{name}{i}")] = base + i
  return out


def _parse_spec(path: str) -> dict[str, dict[str, int]]:
  text = Path(path).read_text(encoding="utf-8", errors="replace")
  tables = {c: _parse_channel(text, c) for c in _CHANNEL_PREFIX_C}
  missing = [c for c, t in tables.items() if not t]
  if missing:
    print(f"warning: {path}: no opcode rows found for {', '.join(missing)} -- "
          f"is this a conversion of IHI 0050?", file=sys.stderr)
  return tables


def _lookup(spec: dict[str, int], channel: str, name: str):
  """Find our name in the spec table, retrying with the channel prefix."""
  key = _norm(name)
  if key in spec:
    return spec[key]
  prefixed = _norm(_CHANNEL_PREFIX_C[channel] + name)
  return spec.get(prefixed)


# The CHI-D width of each channel's opcode field, read from the SV package's own
# width functions so this can never drift from them.
_SV_WIDTH_FN_C = re.compile(
  r"function automatic int chi_(req|rsp|dat|snp)_opcode_width.*?"
  r"VIP_CHI_ISSUE_D_E\s*(?:,\s*VIP_CHI_ISSUE_E_E\s*)?:\s*return\s*(\d+)",
  re.DOTALL)

# A cast of an opcode constant through an ISSUE-PARAMETERIZED opcode type, with
# or without a class scope ("req_opcode_t'(X)", "item_t::req_opcode_t'(X)").
# `vip_chi_req_opcode_t` -- the full-width package enum -- is deliberately NOT
# matched: the lookbehind rejects it, because widening is the safe direction.
_NARROW_CAST_C = re.compile(
  r"(?<![\w])((?:\w+::)?)(req|rsp|dat|snp)_opcode_t'\(\s*(VIP_CHI_(?:REQ|RSP|SNP|DAT)_\w+_C)\s*\)")


def _parse_d_widths(path: Path) -> dict[str, int]:
  """Each channel's CHI-D opcode field width, from the SV width functions."""
  text = path.read_text(encoding="utf-8")
  return {ch.upper(): int(w) for ch, w in _SV_WIDTH_FN_C.findall(text)}


def _scan_narrow_casts(root: Path, sv: dict[str, dict[str, int]],
                       d_widths: dict[str, int]) -> list[tuple]:
  """Opcode constants cast through a type too narrow to hold them in CHI-D.

  The trap this exists for: `req_opcode_t` is 6 bits in CHI-D, so writing
  `req_opcode_t'(VIP_CHI_REQ_WRITE_EVICT_OR_EVICT_C)` -- an Opcode[6] = 1
  encoding -- silently drops the top bit and produces ReadClean. The comparison
  still compiles, still reads correctly, and now answers for a DIFFERENT,
  perfectly ordinary opcode. `docs/FUTURE_WORK.md` records the first time this
  was caught by hand; every occurrence since has been caught the same way.

  Widening is safe and needs no cast at all: `==` extends both operands to the
  wider one, so a bare comparison against the full-width constant is correct in
  either issue. Only `case` items genuinely need the narrow form, and those must
  be hoisted into a full-width guard instead (see req_opcode_is_legal).
  """
  hits = []
  # Source only. rundir/ and build/ hold FuseSoC's copies of these same files;
  # counting them reports each hit twice and pins the count to whatever was last
  # built rather than to what is checked in.
  files = sorted(list((root / "sv").rglob("*.sv"))
                 + list((root / "testbench" / "sv").rglob("*.sv")))
  files = [f for f in files
           if not any(part in ("rundir", "build") for part in f.parts)]
  for path in files:
    for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
      for scope, channel, const in _NARROW_CAST_C.findall(line):
        ch = channel.upper()
        name = const[len("VIP_CHI_"):]
        if not name.startswith(ch + "_"):
          continue
        # A scope that names an Issue-E specialization outright
        # (`vip_chi_item #(CHI_E_WIDE_CFG_C)::req_opcode_t`) is already the wide
        # type; nothing truncates there.
        if "CHI_E" in line[:line.index(const)]:
          continue
        value = sv.get(ch, {}).get(name[len(ch) + 1:-2])
        if value is None:
          continue
        width = d_widths.get(ch)
        if width is None or value < (1 << width):
          continue
        # Which shape it is decides whether it can lie. In a comparison the
        # truncated constant silently EQUALS a different, ordinary opcode, and
        # the code then answers for that one. In an assignment it merely narrows
        # a value that fits the issue the code runs under, so it is advisory.
        stripped = line.strip()
        compares = ("==" in line or "!=" in line or "inside" in line
                    or stripped.endswith(",") or stripped.endswith(":")
                    or stripped.endswith(": begin"))
        hits.append((path.relative_to(root), lineno, scope + channel + "_opcode_t",
                     const, value, width, "compare" if compares else "assign"))
  return hits


def main() -> int:
  ap = argparse.ArgumentParser(description=__doc__,
                               formatter_class=argparse.RawDescriptionHelpFormatter)
  ap.add_argument("--spec-e", default=os.environ.get("CHI_SPEC_E_MD", ""),
                  help="markdown conversion of IHI 0050 Issue E (or CHI_SPEC_E_MD)")
  ap.add_argument("--spec-d", default=os.environ.get("CHI_SPEC_D_MD", ""),
                  help="markdown conversion of IHI 0050 Issue D (or CHI_SPEC_D_MD)")
  ap.add_argument("--show-unimplemented", action="store_true",
                  help="list the spec opcodes this VIP does not implement")
  args = ap.parse_args()

  root = Path(__file__).resolve().parent.parent
  sys.path.insert(0, str(root / "py"))
  from vip_chi_types_pkg import ReqOpcode, RspOpcode, SnpOpcode, DatOpcode

  ours = {"REQ": ReqOpcode, "RSP": RspOpcode, "SNP": SnpOpcode, "DAT": DatOpcode}

  # The two ports agree or they do not, and answering that needs no spec -- so
  # it runs first, and on any machine.
  sv = _parse_sv_package(root / "sv" / "vip_chi_types_pkg.sv")
  ports, sv_checked = [], 0
  for channel, enum in ours.items():
    for member in enum:
      if member.name not in sv[channel]:
        ports.append((channel, member.name, int(member), None))
        continue
      sv_checked += 1
      if sv[channel][member.name] != int(member):
        ports.append((channel, member.name, int(member), sv[channel][member.name]))
  for channel in ours:
    py_names = {m.name for m in ours[channel]}
    for name, value in sv[channel].items():
      if name not in py_names:
        ports.append((channel, name, None, value))

  d_widths = _parse_d_widths(root / "sv" / "vip_chi_types_pkg.sv")
  narrow = _scan_narrow_casts(root, sv, d_widths)

  print(f"opcodes compared between the SV and Python ports: {sv_checked}")
  widths_s = ", ".join(f"{c} {w}" for c, w in sorted(d_widths.items()))
  print(f"opcode casts scanned for CHI-D truncation; CHI-D widths: {widths_s}")
  cmp_hits = [h for h in narrow if h[6] == "compare"]
  asn_hits = [h for h in narrow if h[6] == "assign"]
  print(f"opcode casts that truncate in CHI-D: {len(cmp_hits)} comparing, "
        f"{len(asn_hits)} assigning")
  if cmp_hits:
    print(f"\nNARROW COMPARE ({len(cmp_hits)}) -- truncated constant matches a "
          f"DIFFERENT CHI-D opcode:")
    for rel, lineno, typename, const, value, width, _ in cmp_hits:
      print(f"  {rel}:{lineno}: {typename}'({const}) = 0x{value:02X} -> "
            f"0x{value & ((1 << width) - 1):02X} in {width}-bit CHI-D")
  if asn_hits:
    print(f"\nNARROW ASSIGN ({len(asn_hits)}) -- advisory; narrows on write, "
          f"does not silently match another opcode:")
    for rel, lineno, typename, const, value, width, _ in asn_hits:
      print(f"  {rel}:{lineno}: {typename}'({const}) = 0x{value:02X}")
  if ports:
    print(f"\nPORT DIVERGENCE ({len(ports)}) -- the two ports do not agree:")
    for channel, name, py, sv_value in ports:
      py_s = "absent" if py is None else f"0x{py:02X}"
      sv_s = "absent" if sv_value is None else f"0x{sv_value:02X}"
      print(f"  {channel} {name:<32s} py={py_s:<8s} sv={sv_s}")

  if not args.spec_e:
    print("\nno specification given (--spec-e / CHI_SPEC_E_MD); encodings not "
          "checked against it.")
    print("The Arm document is not in this repository and must not be; point "
          "this at your own conversion of it.")
    return 1 if (ports or cmp_hits) else 0
  if not Path(args.spec_e).is_file():
    print(f"error: no such file: {args.spec_e}", file=sys.stderr)
    return 2

  spec_e = _parse_spec(args.spec_e)
  spec_d = _parse_spec(args.spec_d) if args.spec_d else {}

  mismatch, unknown, checked = [], [], 0
  for channel, enum in ours.items():
    for member in enum:
      got = _lookup(spec_e[channel], channel, member.name)
      if got is None:
        unknown.append((channel, member.name, int(member)))
        continue
      checked += 1
      if got != int(member):
        mismatch.append((channel, member.name, int(member), got))

  # An opcode a CHI-D pool can randomize onto that exists only in Issue E does
  # not fit the narrower CHI-D opcode field. That is a real defect this VIP has
  # had before, and it is invisible until a random draw happens to land on it.
  issue = []
  if spec_d:
    import vip_chi_item
    d_pools = {
      "_READ_OPCODES_D": vip_chi_item._READ_OPCODES_D,
      "_WRITE_OPCODES_D": vip_chi_item._WRITE_OPCODES_D,
      "_RNF_READ_OPCODES_D": vip_chi_item._RNF_READ_OPCODES_D,
    }
    by_value_e = {v: k for k, v in spec_e["REQ"].items()}
    for pool_name, pool in d_pools.items():
      for opcode in pool:
        value = int(opcode)
        name = by_value_e.get(value)
        if name is None:
          continue
        if name not in spec_d["REQ"] or spec_d["REQ"][name] != value:
          issue.append((pool_name, getattr(opcode, "name", str(opcode)), value))

  print(f"opcodes checked against the specification: {checked}")

  if mismatch:
    print(f"\nMISMATCH ({len(mismatch)}) -- our value differs from the spec's:")
    for channel, name, mine, theirs in mismatch:
      print(f"  {channel} {name:<32s} ours=0x{mine:02X} spec=0x{theirs:02X}")

  if unknown:
    print(f"\nUNKNOWN ({len(unknown)}) -- not in the spec's opcode tables:")
    for channel, name, mine in unknown:
      print(f"  {channel} {name:<32s} ours=0x{mine:02X}")

  if issue:
    print(f"\nISSUE ({len(issue)}) -- CHI-D pools offering an Issue-E-only opcode:")
    for pool_name, name, value in issue:
      print(f"  {pool_name}: {name} (0x{value:02X})")

  if args.show_unimplemented:
    for channel, enum in ours.items():
      have = {_norm(m.name) for m in enum} | {
        _norm(_CHANNEL_PREFIX_C[channel] + m.name) for m in enum}
      missing = sorted(n for n in spec_e[channel] if n not in have)
      print(f"\n{channel}: {len(spec_e[channel]) - len(missing)} of "
            f"{len(spec_e[channel])} spec opcodes implemented")
      for name in missing:
        print(f"  0x{spec_e[channel][name]:02X}  {name}")

  if not mismatch and not unknown and not issue and not ports:
    print("\nthe two ports agree, every opcode this VIP defines matches the "
          "specification, and no CHI-D pool offers an Issue-E-only opcode")
    return 0
  return 1


if __name__ == "__main__":
  sys.exit(main())
