#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Full SystemVerilog regression: rebuild, then run every tc_*.sv on the built
# simulator and tally the verdicts.
#
# It rebuilds first on purpose. The simulator is a compiled image, so a sweep
# against a stale binary silently reports on whatever source happened to be
# checked out when it was last built -- which is worse than not running at all.
#
# Results land in $OUT_DIR:
#   summary.txt          one line per failing test, then the SV_TOTAL tally
#   build.log            the FuseSoC/VCS build transcript
#   vcs_<testcase>.log   one simulator log per testcase (in the run directory)
#
# The Synopsys pool is shared and SNPSLMD_QUEUE is set, so a busy pool makes
# each run block in the licence queue rather than fail. A sweep started while
# colleagues are holding every seat crawls at minutes per test; that is
# contention, not a fault, and it finishes on its own.
# -----------------------------------------------------------------------------
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)

# Tool environment. An interactive shell gets VCS_HOME, the licence variables and
# the Synopsys PATH entry from the login profile, but a systemd --user timer does
# NOT -- its manager environment carries a bare PATH and no licence variables at
# all, so a scheduled sweep would die on "vcs: command not found" hours after
# anyone could notice. Sourcing a captured env file makes the scheduled run use
# the same toolchain an interactive run does.
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

CORE="akerlund::vip_chi_agent_example:0"
RUNDIR="$ROOT/build/akerlund__vip_chi_agent_example_0/default-vcs"
SIMV="./akerlund__vip_chi_agent_example_0"
OUT_DIR="${OUT_DIR:-$ROOT/build/sv_regression}"

mkdir -p "$OUT_DIR"
SUMMARY="$OUT_DIR/summary.txt"
: > "$SUMMARY"

{
  echo "started $(date -Is)"
} >> "$SUMMARY"

cd "$ROOT" || exit 1

if ! fusesoc --cores-root . run --target default --tool vcs --setup --build "$CORE" \
     > "$OUT_DIR/build.log" 2>&1; then
  echo "BUILD FAILED - see $OUT_DIR/build.log" >> "$SUMMARY"
  echo "SV_TOTAL pass=0 fail=0 build=failed" >> "$SUMMARY"
  exit 1
fi

cd "$RUNDIR" || exit 1

pass=0
fail=0
for t in $(ls "$ROOT/testbench/sv/tc"/tc_*.sv | sed 's|.*/||; s|\.sv$||'); do
  "$SIMV" +UVM_TESTNAME="$t" -l "vcs_${t}.log" > /dev/null 2>&1
  # A clean run is zero UVM_ERROR and zero UVM_FATAL. Grepping the report
  # summary rather than the exit code is deliberate: the simulator exits 0 on a
  # UVM_ERROR, so the exit code alone would call a failing test a pass.
  if grep -qE "UVM_ERROR :    0" "vcs_${t}.log" && \
     grep -qE "UVM_FATAL :    0" "vcs_${t}.log"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $t" >> "$SUMMARY"
  fi
done

{
  echo "SV_TOTAL pass=$pass fail=$fail"
  echo "finished $(date -Is)"
} >> "$SUMMARY"

exit $(( fail > 0 ))
