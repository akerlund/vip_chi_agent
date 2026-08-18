#!/usr/bin/env bash
#
# Elaborate the SV testbench without running it.
#
# VCS build and simv run draw on different licence features, and this repository
# is regularly in a state where the build succeeds while every run licence is
# taken. sv_regression.sh conflates the two -- it builds and then sweeps -- so a
# saturated licence server makes it useless for the question "does my change
# still compile", which is most of the risk in editing SystemVerilog blind.
#
# This answers that question alone. It catches syntax, type, parameter and
# covergroup errors, missing `include`s, and testcase files absent from
# vip_chi_agent_example.core -- which is a real trap, because chi_tc_pkg.sv and
# the .core file both have to list a new testcase and forgetting the second one
# fails only at build time, with Error-[SFCOR].
#
# It builds into its own root (default: build/sv_elaborate) so it can be run
# while a regression is mid-sweep out of build/akerlund__*/. Rebuilding into the
# regression's directory would overwrite the simv it is executing.
#
#   bash scripts/sv_elaborate.sh              # exit 0 = elaborates
#   BUILD_ROOT=/tmp/e bash scripts/sv_elaborate.sh
#
# It proves nothing about behaviour. A green elaboration and a green regression
# are different claims; say which one you have.
#
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE="akerlund::vip_chi_agent_example:0"
BUILD_ROOT="${BUILD_ROOT:-$ROOT/build/sv_elaborate}"
LOG="${LOG:-$BUILD_ROOT/elaborate.log}"

ENV_FILE="${SV_REGRESSION_ENV:-$ROOT/build/sv_regression_env}"
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

if ! command -v vcs >/dev/null 2>&1; then
  echo "ERROR: vcs is not on PATH (expected $ENV_FILE to supply it)" >&2
  exit 1
fi
if ! command -v fusesoc >/dev/null 2>&1; then
  echo "ERROR: fusesoc is not on PATH (expected $ENV_FILE to supply it)" >&2
  exit 1
fi

mkdir -p "$BUILD_ROOT"
cd "$ROOT" || exit 1

if fusesoc --cores-root . run --target default --tool vcs --setup --build \
     --build-root "$BUILD_ROOT" "$CORE" > "$LOG" 2>&1; then
  echo "ELABORATE ok  ($LOG)"
  exit 0
fi

echo "ELABORATE FAILED - see $LOG" >&2
# The first Error- line is almost always the real one; the rest are fallout.
grep -m 5 -E "^Error-|^ERROR" "$LOG" >&2
exit 1
