#!/usr/bin/env python3
"""The two Python import-path lists must name the same directories.

The pyUVM testbench is launched two ways, and each builds its own import path:

  testbench/py/tb/chi_tb_top.py   _PATHS, inserted into sys.path at import time
  testbench/py/scripts/run.py     paths, exported as PYTHONPATH

A path in run.py and missing from the bootstrap is invisible under run.py --
which supplies it anyway -- and fatal under every other launcher. The bootstrap
is the list that has to be complete, since it raises on a missing directory.

Exit 0 when the two lists name the same set and every directory exists.
"""

import ast
import sys
from pathlib import Path

ROOT_C = Path(__file__).resolve().parent.parent
TB_TOP_C = ROOT_C / "testbench" / "py" / "tb" / "chi_tb_top.py"
RUN_PY_C = ROOT_C / "testbench" / "py" / "scripts" / "run.py"

# What each list's base name means, as a path relative to the repository root.
# Both files build their entries as `<base> / "a" / "b"`, so resolving the base
# is all that is needed to compare them.
BASES_C = {
  "_ROOT": Path("."),
  "root": Path("."),
  "_PY_ROOT": Path("testbench") / "py",
}


def _path_from_expr(node):
  """Return a repo-relative Path for a `<base> / "a" / "b"` expression.

  Returns None for anything else, so an unrelated list assignment cannot be
  mistaken for one of the two under test.
  """
  parts = []
  current = node
  while isinstance(current, ast.BinOp) and isinstance(current.op, ast.Div):
    if not isinstance(current.right, ast.Constant) or not isinstance(current.right.value, str):
      return None
    parts.append(current.right.value)
    current = current.left
  if not isinstance(current, ast.Name) or current.id not in BASES_C:
    return None
  base = BASES_C[current.id]
  for part in reversed(parts):
    base = base / part
  return Path(*base.parts) if base.parts != (".",) else Path(".")


def _extract(path: Path, target: str) -> set[Path] | None:
  """Pull the named list assignment out of a source file."""
  tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
  for node in ast.walk(tree):
    if not isinstance(node, ast.Assign) or not isinstance(node.value, ast.List):
      continue
    names = [t.id for t in node.targets if isinstance(t, ast.Name)]
    if target not in names:
      continue
    found = set()
    for element in node.value.elts:
      resolved = _path_from_expr(element)
      if resolved is None:
        print(f"{path.name}: {target} has an entry this script cannot read; "
              f"teach it the new shape rather than leaving the list unchecked")
        return None
      found.add(resolved)
    return found
  print(f"{path.name}: no list assignment named {target} -- it was renamed or "
        f"restructured, and this gate is now checking nothing")
  return None


def main() -> int:
  boot = _extract(TB_TOP_C, "_PATHS")
  runner = _extract(RUN_PY_C, "paths")
  if boot is None or runner is None:
    return 1

  bad = 0
  missing_from_boot = sorted(runner - boot)
  missing_from_runner = sorted(boot - runner)

  if missing_from_boot:
    bad = 1
    print("in run.py but NOT in the testbench bootstrap "
          "(invisible under run.py, fatal under any other launcher):")
    for path in missing_from_boot:
      print(f"  {path}")
  if missing_from_runner:
    bad = 1
    print("in the testbench bootstrap but not in run.py:")
    for path in missing_from_runner:
      print(f"  {path}")

  for path in sorted(boot | runner):
    if not (ROOT_C / path).is_dir():
      bad = 1
      print(f"listed but not a directory: {path}")

  if bad:
    print(f"\n{len(missing_from_boot) + len(missing_from_runner)} import-path "
          f"divergence(s)")
    return 1

  print(f"both launchers name the same {len(boot)} import path(s), all present")
  return 0


if __name__ == "__main__":
  sys.exit(main())
