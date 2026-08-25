#!/usr/bin/env python3
"""No assertion gate may change inside the edge the assertions sample.

A concurrent assertion samples its body in the Preponed region. Its
`disable iff` expression is NOT sampled: it is evaluated with whatever the
variable holds when the attempt is considered, in the Observed region. So a gate
that moves between those two points buys one cycle judged with the wrong pairing
-- sampled values from one side of the transition, a gate from the other.

Which sources can do that, measured rather than assumed:

  * A clocking block's `output #0` drive lands in Re-NBA, AFTER Observed, so a
    gate derived from driver outputs cannot change inside the edge. Measured zero
    such cycles across the link-lifecycle testcases.
  * An `always_ff @(posedge clk)` NBA lands in NBA, BEFORE Observed, so anything
    combinationally derived from harness state CAN. Measured: `rst_n_int` was
    `rst_n && (reset_pulse_countdown == 0)`, the countdown is a posedge NBA, and
    every rule gated `disable iff (!vif.rst_n)` was judged once per reset pulse
    against the parked reset window it was gated off for.

So the invariant this enforces is about the SOURCE of each gate, which is
readable from the top and cannot be read from a waveform after the fact:

  1. Every `.checks_enable(...)` connection is a function of interface wires
     only -- no harness variable may appear in it.
  2. `rst_n_int` keeps its falling-edge-registered release term.

Both were true at the moment this was written; the point is that neither is
enforced by anything else, and the second was false for the whole life of the
bench before it was found by accident.

Usage:
  check_gate_timing.py [<chi_tb_top.sv>]

Exit 1 on any violation.
"""
from __future__ import annotations

import os
import re
import sys

RELEASE_TERM_C = "pulse_rst_n"
# An interface wire reference: <name>_if.<signal>. Anything else inside a
# checks_enable expression is a harness variable.
IF_REF_RE_C = re.compile(r"\b([A-Za-z_][A-Za-z0-9_]*_if)\.([A-Za-z_][A-Za-z0-9_]*)\b")
IDENT_RE_C = re.compile(r"\b([A-Za-z_][A-Za-z0-9_]*)\b")
# Words that may appear in the expression without being a signal.
ALLOWED_WORDS_C = {"b0", "b1", "bx", "bz"}


def checks_enable_exprs(src: str) -> list[tuple[int, str]]:
    """Every .checks_enable(<expr>) connection, with its 1-based line number."""
    out: list[tuple[int, str]] = []
    for m in re.finditer(r"\.checks_enable\s*\(", src):
        i = m.end()
        depth = 1
        while i < len(src) and depth:
            if src[i] == "(":
                depth += 1
            elif src[i] == ")":
                depth -= 1
            i += 1
        out.append((src.count("\n", 0, m.start()) + 1, src[m.end():i - 1]))
    return out


def main(argv: list[str]) -> int:
    here = os.path.dirname(os.path.abspath(__file__))
    path = argv[1] if len(argv) > 1 else os.path.join(
        here, "..", "testbench", "sv", "tb", "chi_tb_top.sv")
    try:
        src = open(path, encoding="utf-8").read()
    except OSError as exc:
        print(f"ERROR: cannot read {path}: {exc}")
        return 1

    bad = 0

    exprs = checks_enable_exprs(src)
    if not exprs:
        print(f"ERROR: no .checks_enable connection found in {path} -- this "
              f"check is reading the wrong file or the wiring has moved")
        return 1

    for line, expr in exprs:
        flat = IF_REF_RE_C.sub(" ", expr)
        strays = {w for w in IDENT_RE_C.findall(flat) if w not in ALLOWED_WORDS_C}
        if strays:
            bad += 1
            print(f"  {os.path.basename(path)}:{line}: checks_enable reads "
                  f"{', '.join(sorted(strays))}, which is not an interface wire")

    reset_lines = [(n + 1, ln) for n, ln in enumerate(src.splitlines())
                   if re.search(r"^\s*rst_n_int\s*=", ln)]
    if not reset_lines:
        print("ERROR: no rst_n_int assignment found -- this check is reading "
              "the wrong file or the reset wiring has moved")
        return 1
    for line, text in reset_lines:
        if RELEASE_TERM_C not in text:
            bad += 1
            print(f"  {os.path.basename(path)}:{line}: rst_n_int has no "
                  f"{RELEASE_TERM_C} term, so its release lands in the NBA "
                  f"region the properties are evaluated after")

    if bad:
        print(f"\n{bad} assertion gate(s) can change inside the sampling edge")
        return 1

    print(f"every assertion gate is stable across the sampling edge "
          f"({len(exprs)} checks_enable connection(s), "
          f"{len(reset_lines)} rst_n_int assignment(s))")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
