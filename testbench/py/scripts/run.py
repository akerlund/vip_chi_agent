#!/usr/bin/env python3
################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################

from __future__ import annotations

import argparse
import ast
import os
import re
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path


CORE_C = "akerlund::vip_chi_agent_example_py:0"
TOP_MODULE_C = "vip_chi_tb_top"
SUMMARY_RE_C = re.compile(r"TESTS=(?P<tests>\d+).*FAIL=(?P<fail>\d+)")


@dataclass(frozen=True)
class TestCase:
  """Hold one public cocotb testcase entry."""
  name: str


@dataclass(frozen=True)
class TestReport:
  """Hold the result printed for one testcase."""
  name: str
  status: str
  warnings: int
  errors: int
  failures: int
  elapsed: str

  @property
  def line(self) -> str:
    """Format one fixed-width status table row."""
    return (
      f"{self.name:<48}: {self.status:<8}"
      f"{self.warnings:<11}{self.errors:<11}{self.failures:<11}{self.elapsed}"
    )


def main() -> int:
  """Parse command-line arguments and run the requested action."""
  args = parse_args()
  root = repo_root()
  cases = discover_tests(root)

  if args.list:
    for case in cases:
      print(case.name)
    return 0

  selected = select_tests(args, cases)
  if args.build or selected:
    if not args.no_build:
      rc = build(root, args.clean)
      if rc != 0 or args.build and not selected:
        return rc

  if not selected:
    return 0

  if len(selected) == 1 and not args.all:
    return run_one(root, selected[0], stream=True).failures

  reports = []
  print_header()
  for case in selected:
    print_running(case.name)
    report = run_one(root, case, stream=False)
    reports.append(report)
    print("\r" + report.line)

  failed = [report for report in reports if report.failures]
  if failed:
    print(f"Test run complete: {len(failed)} of {len(reports)} tests failed")
    print("Failed tests:")
    for report in failed:
      print(f"  {report.name}")
    return 1

  print(f"Test run complete: all {len(reports)} tests passed")
  return 0


def parse_args() -> argparse.Namespace:
  """Create the CLI used by the Python regression runner."""
  parser = argparse.ArgumentParser(description="Run CHI pyUVM/cocotb tests")
  parser.add_argument("-t", "--tc", default="", help="public tc_* testcase")
  parser.add_argument("-a", "--all", action="store_true", help="run all tests")
  parser.add_argument("-l", "--list", action="store_true", help="list tests")
  parser.add_argument("--build", action="store_true", help="build only")
  parser.add_argument("--no-build", action="store_true", help="skip build")
  parser.add_argument("--clean", action="store_true", help="clean FuseSoC build")
  args = parser.parse_args()
  if args.all and args.tc:
    parser.error("use either --all or --tc, not both")
  if not args.list and not args.build and not args.all and not args.tc:
    parser.error("use --build, --list, --all, or --tc")
  return args


def repo_root() -> Path:
  """Return the repository root containing this script."""
  return Path(__file__).resolve().parents[3]


def discover_tests(root: Path) -> list[TestCase]:
  """Discover public cocotb tests from the Python top."""
  top = root / "testbench" / "py" / "tb" / f"{TOP_MODULE_C}.py"
  tree = ast.parse(top.read_text(encoding="utf-8"))
  tests: dict[str, TestCase] = {}

  for node in tree.body:
    if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
      continue
    name = cocotb_test_name(node)
    if not name or not name.startswith("tc_"):
      continue
    body_name = body_test_name(node)
    if body_name and body_name != name:
      raise RuntimeError(
        f"{TOP_MODULE_C}.{node.name} runs {body_name}, but is named {name}"
      )
    tests[name] = TestCase(name)

  return [tests[name] for name in sorted(tests)]


def cocotb_test_name(node: ast.FunctionDef | ast.AsyncFunctionDef) -> str | None:
  """Return the configured cocotb test name for a function."""
  for decorator in node.decorator_list:
    target = decorator.func if isinstance(decorator, ast.Call) else decorator
    if not isinstance(target, ast.Attribute) or target.attr != "test":
      continue
    if isinstance(decorator, ast.Call):
      for keyword in decorator.keywords:
        if keyword.arg == "name" and isinstance(keyword.value, ast.Constant):
          if isinstance(keyword.value.value, str):
            return keyword.value.value
    return node.name
  return None


def body_test_name(node: ast.FunctionDef | ast.AsyncFunctionDef) -> str | None:
  """Return the tc_* name passed to the pyUVM testcase runner."""
  for child in ast.walk(node):
    if not isinstance(child, ast.Assign):
      continue
    if not isinstance(child.value, ast.Constant):
      continue
    if not isinstance(child.value.value, str):
      continue
    if not child.value.value.startswith("tc_"):
      continue
    for target in child.targets:
      if isinstance(target, ast.Name) and target.id == "test_name":
        return child.value.value
  return None


def select_tests(args: argparse.Namespace, cases: list[TestCase]) -> list[TestCase]:
  """Resolve the requested public testcase selection."""
  if args.list or (args.build and not args.tc and not args.all):
    return []
  if args.all:
    return cases
  by_name = {case.name: case for case in cases}
  if args.tc not in by_name:
    known = ", ".join(case.name for case in cases[:5])
    raise SystemExit(f"unknown testcase '{args.tc}' (examples: {known})")
  return [by_name[args.tc]]


def env(root: Path, case: TestCase | None = None) -> dict[str, str]:
  """Build the environment FuseSoC and cocotb need."""
  paths = [
    root / "testbench" / "py" / "tb",
    root / "testbench" / "py" / "tc",
    root / "py",
    root / "py" / "seq_lib",
    root / "submodules" / "vip_memory" / "py",
  ]
  values = os.environ.copy()
  values["VIP_ROOT"] = str(root)
  values["PYTHONPATH"] = os.pathsep.join(
    [str(path) for path in paths] + [values.get("PYTHONPATH", "")]
  )
  if case:
    values["COCOTB_TEST_FILTER"] = f"{case.name}$"
  return values


def build(root: Path, clean: bool) -> int:
  """Build the FuseSoC Verilator simulation target."""
  command = [
    "fusesoc",
    "--cores-root",
    ".",
    "run",
    "--no-export",
    "--target",
    "sim",
    "--tool",
    "verilator",
  ]
  if clean:
    command.append("--clean")
  command += ["--setup", "--build", CORE_C]
  return subprocess.run(command, cwd=root, env=env(root)).returncode


def run_one(root: Path, case: TestCase, stream: bool) -> TestReport:
  """Run one public testcase in its own simulator process."""
  log_dir = root / "testbench" / "py" / "rundir" / "verilator"
  log_dir.mkdir(parents=True, exist_ok=True)
  log_path = log_dir / f"{case.name}.log"
  command = [
    "fusesoc",
    "--cores-root",
    ".",
    "run",
    "--no-export",
    "--target",
    "sim",
    "--tool",
    "verilator",
    "--run",
    CORE_C,
  ]

  start = time.time()
  output = run_logged(command, root, env(root, case), log_path, stream)
  elapsed = format_elapsed(time.time() - start)
  warnings = count_word(output, "WARNING")
  errors = count_word(output, "ERROR")
  failures = failure_count(output)
  if failures == 0 and "TESTS=1 PASS=1 FAIL=0" not in output:
    failures = 1
  status = "Passed" if failures == 0 else "Failed"
  return TestReport(case.name, status, warnings, errors, failures, elapsed)


def run_logged(
  command: list[str],
  cwd: Path,
  values: dict[str, str],
  log_path: Path,
  stream: bool,
) -> str:
  """Run a command while writing a real-time log."""
  chunks = []
  with log_path.open("w", encoding="utf-8") as log:
    process = subprocess.Popen(
      command,
      cwd=cwd,
      env=values,
      text=True,
      stdout=subprocess.PIPE,
      stderr=subprocess.STDOUT,
      bufsize=1,
    )
    assert process.stdout is not None
    for line in process.stdout:
      chunks.append(line)
      log.write(line)
      log.flush()
      if stream:
        print(line, end="")
    rc = process.wait()
  output = "".join(chunks)
  if rc != 0 and failure_count(output) == 0:
    output += f"\nprocess exited with {rc}\n"
  return output


def count_word(text: str, word: str) -> int:
  """Count whole-word severity occurrences in command output."""
  return len(re.findall(rf"\b{re.escape(word)}\b", text))


def failure_count(text: str) -> int:
  """Return the cocotb failure count or one failure for abnormal output."""
  match = SUMMARY_RE_C.search(text)
  if match:
    return int(match.group("fail"))
  return 1 if "ERROR" in text or "process exited with" in text else 0


def format_elapsed(seconds: float) -> str:
  """Format elapsed wall time as HH:MM:SS."""
  total = int(seconds)
  hours = total // 3600
  minutes = total % 3600 // 60
  secs = total % 60
  return f"{hours:02d}:{minutes:02d}:{secs:02d}"


def print_header() -> None:
  """Print the fixed-width regression summary header."""
  print(
    f"{'Test result summary:':<49}  "
    f"{'Status':<8}{'Warnings':<11}{'Errors':<11}{'Failures':<11}Time"
  )


def print_running(name: str) -> None:
  """Print an in-place status while one testcase is running."""
  print(f"{name:<48}: Running...", end="\r", flush=True)


if __name__ == "__main__":
  sys.exit(main())
