#!/usr/bin/env python3
"""Check this VIP's packed flit layouts against the Arm CHI specification.

`scripts/check_type_parity.py` already compares the SV structs to the Python
pack layouts. That check is necessary and not sufficient: it compares the two
ports to *each other* and never to Arm, so a field order transcribed wrongly
once and mirrored faithfully into both ports passes it forever. This script
supplies the missing side -- the specification itself.

It reads the four flit tables per issue:

  Issue D  Table 12-6 Request / 12-7 Response / 12-8 Snoop / 12-9 Data
  Issue E  Table 13-6 Request / 13-7 Response / 13-8 Snoop / 13-9 Data

and reports:

  ORDER    a field this VIP declares exists in the spec table, but not at the
           position the VIP puts it. This is the defect the parity check cannot
           see, and the one that produces a flit whose every field is right and
           whose wire image is wrong.
  UNKNOWN  a field this VIP declares that the spec table does not list under any
           of its names -- a typo, an invention, or a field borrowed from the
           other issue.
  MISSING  a spec field this VIP does not model. Advisory, not a failure: the
           VIP excludes Stash, DVM and MPAM by declaration, and a scope
           exclusion is not a layout defect.

**Why the PDF and not the markdown.** The tables carry stacked names -- one set
of bits with several names depending on the transaction, printed as several rows
against a single width. `SnpAttr` over `DoDWT`, `StashNIDValid` over `Endian`
over `Deep`, `ReturnNID` over `StashNID` over `SLCRepHint`. The markdown
conversion keeps the stack in some cells and drops all but the first name in
others, without any marker to say which happened. A field list derived from the
converted tables is therefore unsafe in a way no parser can detect, so this
reads `pdftotext -layout` output, where every stacked name survives.

**The specification is not in this repository and must not be.** Only field
names this VIP already declares are stored here; the authority is read at run
time from your local PDFs:

  python3 scripts/check_flit_layout.py --spec-d-pdf ~/chi/IHI0050D.pdf \\
                                       --spec-e-pdf ~/chi/IHI0050E_a.pdf

or set CHI_SPEC_D_PDF / CHI_SPEC_E_PDF, or CHI_SPEC_PDF_DIR holding both under
their published file names. With no PDF available it says so and checks nothing
rather than reporting a clean run -- an absent authority is not agreement with
one.

Exit status: 0 clean, 1 a real ORDER/UNKNOWN difference, 2 INCONCLUSIVE (the
authority could not be read, or a table parsed to something that is not a flit
table). 2 is deliberately distinct from 0: a check that cannot see its input has
not passed.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import check_type_parity as parity  # noqa: E402  (path set above)


ROOT = Path(__file__).resolve().parent.parent

# The published file names, used when only CHI_SPEC_PDF_DIR is given.
_PDF_NAME_C = {
  "D": "IHI0050D_amba_5_chi_architecture_spec.pdf",
  "E": "IHI0050E_a_amba_5_chi_architecture_spec.pdf",
}

# Table numbers per issue. The link layer is Chapter 12 in Issue D and Chapter 13
# in Issue E -- Issue E inserts Memory Tagging as Chapter 12 and pushes every
# later chapter up by one -- so the same four tables carry different numbers.
_TABLES_C = {
  "D": {"req": "12-6", "rsp": "12-7", "snp": "12-8", "dat": "12-9"},
  "E": {"req": "13-6", "rsp": "13-7", "snp": "13-8", "dat": "13-9"},
}

_STRUCT_C = {
  "req": "vip_chi_req_flit_t",
  "rsp": "vip_chi_rsp_flit_t",
  "dat": "vip_chi_dat_flit_t",
  "snp": "vip_chi_snp_flit_t",
}

# Below this many parsed positions the page is not a flit table and the result is
# INCONCLUSIVE. The smallest of the four (RSP) carries well over a dozen.
_MIN_POSITIONS_C = 8

# Rows that are not fields. "Total" closes every table; the bus-width rows for
# MPAM and RSVDC repeat the field name's width options on their own lines.
_STOP_ROW_C = "total"

# The page footer. It sits in the same columns as the table body, so without
# this the copyright band parses as two more fields.
_FOOTER_C = re.compile(r"Copyright ©|Non-Confidential|ARM IHI \d|^ID\d{6}")


def _norm(name: str) -> str:
  """Reduce a spec or VIP field name to a comparable key.

  Case, bit ranges and punctuation all differ between the document and the
  source; nothing else is allowed to.
  """
  name = re.sub(r"\[[^\]]*\]", "", name)
  # "DataCheck (DC)" and "Poison (P)" introduce the abbreviation the width rows
  # below them use; the field's name is the part before it.
  name = re.sub(r"\([^)]*\)", "", name)
  return re.sub(r"[^a-z0-9]", "", name.lower())


def _width_token(rest: str) -> str:
  """The width from the columns right of the field name, or "" if there is none.

  The width column cannot be sliced at the header's "Comments" offset: the Data
  flit table indents its body differently from its own header, so that offset
  lands inside the comment text and every row reads as though it carried a
  width. What separates the two columns reliably is shape, not position. Every
  width in these tables either starts with a digit (4, 12, "7 to 11", "0 or
  DW/8 = 16, 32, 64") or carries an "=" ("M=0", "SAW = 41 to 49", "DW/32 = 4,
  8, 16"). No comment does either in its first column-group -- they read "-",
  "SBZ", "Used for DCT", "Width determined by NodeID_Width", "Memory tagging".
  The one comment that does contain an "=", the Data row's "DW = Data bus
  width", sits in the group after the width and is never the first.
  """
  text = rest.strip()
  if not text:
    return ""
  first = re.split(r"\s{2,}", text)[0].strip()
  if not first[:1].isdigit() and "=" not in first:
    return ""
  return first


def _is_constant(part: str) -> bool:
  """TRUE for a zero-fill or SBZ term inside a brace group, e.g. 6'b0.

  The apostrophe is optional because the two issues do not agree on it: Issue E
  writes {1'b0, FwdState[2:0]} and Issue D writes {0b0, FwdState}.
  """
  return bool(re.match(r"^\s*\(?[^,]*?['’]?b[01]+\s*$", part)) or not _norm(part)


_PAGE_CACHE: dict[Path, list[str]] = {}


def _pdf_pages(pdf: Path) -> list[str]:
  """Every page of one PDF as laid-out text, extracted in a single pass.

  One pass, not one per page: these documents run to several hundred pages and
  a per-page subprocess turns a two-second check into a several-minute one.
  pdftotext separates pages with a form feed.
  """
  if pdf in _PAGE_CACHE:
    return _PAGE_CACHE[pdf]
  out = subprocess.run(["pdftotext", "-layout", str(pdf), "-"],
                       capture_output=True, text=True)
  if out.returncode != 0:
    raise RuntimeError(f"pdftotext failed on {pdf.name}: {out.stderr.strip()}")
  _PAGE_CACHE[pdf] = out.stdout.split("\f")
  return _PAGE_CACHE[pdf]


def _find_table_pages(pdf: Path, table: str) -> list[str]:
  """Every page carrying the caption for one table, in document order.

  Pages are searched rather than hardcoded on purpose: a page number is the one
  fact about a document that a reprint changes and nobody notices.
  """
  caption = re.compile(rf"Table {re.escape(table)}\s")
  return [page for page in _pdf_pages(pdf) if caption.search(page)]


def _parse_table(text: str, caption: re.Pattern) -> list[dict]:
  """Parse one flit table's Field / Field width / Comments rows, in bit order.

  Returns one entry per set of bits, each with:
    primary  the canonical name(s), LSB-first, with constants dropped
    names    every name the table gives those bits, normalized

  A row carrying a width opens a new set of bits. Rows below it with an empty
  width column are further names for the same bits: either the continuation of
  one brace group split across lines, or a genuine alternative name. Brace
  balance tells the two apart.
  """
  positions: list[dict] = []

  # Start at the caption, not at the first header on the page. A page routinely
  # carries the tail of one table and the head of the next -- Issue D prints
  # "Table 12-6 (continued)" and "Table 12-7" on the same page -- so the first
  # header below the caption is the only one that belongs to this table.
  found = caption.search(text)
  if not found:
    return positions
  lines = text[found.end():].split("\n")

  index = 0
  while index < len(lines):
    # "Field width" in the REQ/RSP/SNP tables, "Field Width" in the DAT ones.
    header = re.match(r"^(\s*)Field(\s+)Field width(\s+)Comments\s*$",
                      lines[index], re.I)
    if not header:
      index += 1
      continue

    width_col = len(header.group(1)) + len("Field") + len(header.group(2))
    index += 1

    # Accumulator for a brace group spread over several lines, and the width
    # that opened it -- the width sits on the group's first line only, so it
    # has to survive until the closing brace arrives.
    pending: list[str] = []
    pending_width = ""

    while index < len(lines):
      line = lines[index]
      index += 1
      if not line.strip():
        continue
      if _FOOTER_C.search(line):
        break
      name = line[:width_col].strip()
      width = _width_token(line[width_col:])

      # A width with no name is a further width option for the field above
      # (MPAM's M=0 / M=11, RSVDC's Y=0 / Y=4,8,...), not a new field.
      if not name:
        continue
      if _norm(name) == _STOP_ROW_C:
        break

      group = pending + [name]
      width = pending_width or width
      if "".join(group).count("{") != "".join(group).count("}"):
        pending = group
        pending_width = width
        continue
      pending = []
      pending_width = ""

      joined = " ".join(group)
      parts = [p for p in re.split(r",", joined.strip("{} ")) if not _is_constant(p)]
      names = [_norm(p) for p in parts if _norm(p)]
      if not names:
        continue

      if width:
        # LSB-first inside a brace group: the leftmost term is the MSB, so a
        # composite reverses into the bit-zero-first sequence the table is in.
        positions.append({"primary": list(reversed(names)),
                          "names": set(names), "width": width})
      elif positions:
        positions[-1]["names"].update(names)

    if positions:
      return positions

  return positions


def _spec_positions(pdf: Path, table: str) -> list[dict]:
  caption = re.compile(rf"Table {re.escape(table)}\s[^\n]*")
  pages = _find_table_pages(pdf, table)
  if not pages:
    raise RuntimeError(f"Table {table} not found in {pdf.name}")
  merged: list[dict] = []
  for page in pages:
    merged.extend(_parse_table(page, caption))
  return merged


def _vip_fields(sv: str, issue: str, channel: str) -> list[str]:
  """The VIP's field order for one flit, LSB-first.

  The SV structs are packed MSB-first, so the declaration order is the reverse
  of the bit-zero-first order the specification tables are printed in.
  """
  block = parity._class_block(sv, f"vip_chi_types_{issue.lower()}")
  return list(reversed(parity._struct_fields(block, _STRUCT_C[channel])))


def _compare(vip: list[str], positions: list[dict]):
  """Walk the VIP's fields against the spec's positions in order.

  One position may absorb several consecutive VIP fields: the VIP splits some
  brace groups the table prints as one set of bits ({GroupIDExt, LPID}) into
  separate struct members. A field that matches a position already passed is an
  ORDER difference; one that matches no position at all is UNKNOWN.

  Also returns WHICH VIP fields landed on each position, because splitting a
  brace group is only legal if the parts still add up to the position's width.
  That is not a refinement of the order check, it is the other half of it: this
  function passed a CHI-E request flit three bits too wide (F-CORR-026) while
  reporting every field in its right place, and it was right to -- every field
  WAS in its right place. Nobody was adding them up.
  """
  order: list[str] = []
  unknown: list[str] = []
  cursor = 0
  consumed = [False] * len(positions)
  absorbed: dict[int, list[str]] = {}

  for field in vip:
    key = _norm(field)
    hit = next((i for i in range(cursor, len(positions)) if key in positions[i]["names"]), None)
    if hit is not None:
      for i in range(cursor, hit):
        pass
      consumed[hit] = True
      absorbed.setdefault(hit, []).append(field)
      # Stay on this position while it still has unmatched constituents, so a
      # split brace group does not read as an ORDER difference.
      remaining = [n for n in positions[hit]["primary"] if n != key]
      cursor = hit if remaining and any(_norm(f) in remaining for f in vip) else hit + 1
      continue

    back = next((i for i in range(0, cursor) if key in positions[i]["names"]), None)
    if back is not None:
      order.append(field)
      consumed[back] = True
      absorbed.setdefault(back, []).append(field)
    else:
      unknown.append(field)

  missing = [
    "/".join(positions[i]["primary"]) for i in range(len(positions))
    if not consumed[i] and positions[i]["primary"]
  ]
  return order, unknown, missing, absorbed


def _fixed_width(position: dict) -> int | None:
  """The position's width when the table states it as a plain integer.

  None for everything else, and the "everything else" is the point: widths given
  as a range ("7 to 11"), as a symbol ("M = 11", "SAW = 41 to 49") or as an
  expression are configuration-dependent, and comparing them would mean
  reimplementing the VIP's own width functions inside its checker. The plain
  integers are the rows where the specification admits no freedom at all, so a
  disagreement there is unambiguous.
  """
  token = position.get("width", "")
  return int(token) if token.isdigit() else None


def _vip_widths(py_types, issue: str, channel: str) -> dict[str, int]:
  """Field -> width for one channel, from the PYTHON layout.

  The Python port is used because its widths are values, computed by the same
  code that packs the flits; the SV struct declares them as parameterized
  expressions that would have to be re-evaluated to read. check_type_parity
  holds the two ports' field sets together, and this script's order pass reads
  the SV struct -- so a width taken from Python and an order taken from SV are
  still describing one flit.

  Read at the widest configuration. Every width this compares is a plain integer
  in the table, so none of them varies with the configuration anyway -- but a
  config has to be picked, and the widest is the one where a truncation shows.
  """
  cfg = py_types.ChiCfg(
    issue=py_types.Issue.E if issue == "E" else py_types.Issue.D,
    node_id_width=11, addr_width=52, data_bytes=64, mpam_en=True)
  return {_norm(name): width for name, width in py_types.flit_layout(cfg, channel)}


def _check_widths(vip_widths: dict[str, int], positions: list[dict],
                  absorbed: dict[int, list[str]], table: str) -> list[str]:
  """Every position whose width the table fixes must be filled exactly.

  Summed, not compared one-to-one: the VIP splits some brace groups the table
  prints as one set of bits, which is allowed, and what is not allowed is for
  the parts to add up to something else. That is how a CHI-E request flit ran
  three bits wide with every field in the right place -- GroupIDExt (3) and LPID
  (8) sharing an 8-bit position between them. See F-CORR-026.
  """
  problems: list[str] = []
  for index, fields in sorted(absorbed.items()):
    want = _fixed_width(positions[index])
    if want is None:
      continue
    known = [f for f in fields if _norm(f) in vip_widths]
    if len(known) != len(fields):
      continue
    got = sum(vip_widths[_norm(f)] for f in known)
    if got != want:
      name = "/".join(positions[index]["primary"]) or "?"
      problems.append(
        f"{name}: Table {table} gives {want} bits, VIP declares {got} "
        f"({' + '.join(f'{f}={vip_widths[_norm(f)]}' for f in known)})")
  return problems


def _check_issue(sv: str, issue: str, pdf: Path, verbose: bool,
                 py_types) -> tuple[list[str], list[str]]:
  errors: list[str] = []
  inconclusive: list[str] = []

  for channel, table in _TABLES_C[issue].items():
    try:
      positions = _spec_positions(pdf, table)
    except RuntimeError as exc:
      inconclusive.append(f"CHI-{issue} {channel}: {exc}")
      continue

    if len(positions) < _MIN_POSITIONS_C:
      inconclusive.append(
        f"CHI-{issue} {channel}: Table {table} parsed to {len(positions)} positions, "
        f"fewer than the {_MIN_POSITIONS_C} any flit table has -- not a flit table"
      )
      continue

    # A guard tied to the shape the data must have, rather than to a count a
    # mis-parse can clear: every CHI flit begins at bit zero with QoS, and the
    # first three of the four also carry TgtID immediately after (SNP has no
    # target). A parse that does not start that way is reading something else.
    if positions[0]["primary"][:1] != ["qos"]:
      inconclusive.append(
        f"CHI-{issue} {channel}: Table {table} parsed with "
        f"'{'/'.join(positions[0]['primary'])}' at bit zero, not QoS"
      )
      continue

    vip = _vip_fields(sv, issue, channel)
    order, unknown, missing, absorbed = _compare(vip, positions)

    print(f"CHI-{issue} {channel}: spec Table {table} {len(positions)} positions, "
          f"VIP {len(vip)} fields")
    if verbose:
      print(f"    spec: {[ '/'.join(p['primary']) for p in positions ]}")
      print(f"    vip : {vip}")
    for field in order:
      print(f"  ORDER   {field}: declared out of the position Table {table} gives it")
      errors.append(f"CHI-{issue} {channel} ORDER {field}")
    for field in unknown:
      print(f"  UNKNOWN {field}: Table {table} lists no field under that name")
      errors.append(f"CHI-{issue} {channel} UNKNOWN {field}")
    for problem in _check_widths(_vip_widths(py_types, issue, channel),
                                 positions, absorbed, table):
      print(f"  WIDTH   {problem}")
      errors.append(f"CHI-{issue} {channel} WIDTH {problem}")
    if missing:
      print(f"  missing (advisory, {len(missing)}): {', '.join(missing)}")

  return errors, inconclusive


def _resolve(issue: str, given: str) -> Path | None:
  if given:
    return Path(given).expanduser()
  directory = os.environ.get("CHI_SPEC_PDF_DIR", "")
  if directory:
    candidate = Path(directory).expanduser() / _PDF_NAME_C[issue]
    if candidate.is_file():
      return candidate
  return None


def main() -> int:
  ap = argparse.ArgumentParser(description=__doc__,
                               formatter_class=argparse.RawDescriptionHelpFormatter)
  ap.add_argument("--spec-d-pdf", default=os.environ.get("CHI_SPEC_D_PDF", ""),
                  help="IHI 0050 Issue D PDF (or CHI_SPEC_D_PDF / CHI_SPEC_PDF_DIR)")
  ap.add_argument("--spec-e-pdf", default=os.environ.get("CHI_SPEC_E_PDF", ""),
                  help="IHI 0050 Issue E PDF (or CHI_SPEC_E_PDF / CHI_SPEC_PDF_DIR)")
  ap.add_argument("--verbose", action="store_true",
                  help="print both field sequences per channel")
  args = ap.parse_args()

  if not shutil.which("pdftotext") or not shutil.which("pdfinfo"):
    print("INCONCLUSIVE: pdftotext/pdfinfo not installed (poppler-utils); "
          "the flit tables cannot be read")
    return 2

  sv = parity._read_sv()
  # The Python port supplies the field WIDTHS the order pass cannot read off the
  # SV struct's parameterized expressions. See _vip_widths.
  py_types = parity._load_py_types()
  errors: list[str] = []
  inconclusive: list[str] = []
  checked = 0

  for issue in ("D", "E"):
    pdf = _resolve(issue, getattr(args, f"spec_{issue.lower()}_pdf"))
    if pdf is None:
      inconclusive.append(f"CHI-{issue}: no PDF given (--spec-{issue.lower()}-pdf / "
                          f"CHI_SPEC_{issue}_PDF / CHI_SPEC_PDF_DIR)")
      continue
    if not pdf.is_file():
      inconclusive.append(f"CHI-{issue}: {pdf} is not a file")
      continue
    issue_errors, issue_inconclusive = _check_issue(sv, issue, pdf, args.verbose,
                                                    py_types)
    errors.extend(issue_errors)
    inconclusive.extend(issue_inconclusive)
    checked += 1

  if inconclusive:
    print("\nINCONCLUSIVE:")
    for line in inconclusive:
      print(f"  {line}")

  if errors:
    print(f"\nFAILED: {len(errors)} flit layout difference(s) against the specification")
    return 1

  if checked == 0 or inconclusive:
    print("\nnothing was verified against the specification; this is not a pass")
    return 2

  print("\nevery flit field this VIP declares sits where the specification puts it")
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
