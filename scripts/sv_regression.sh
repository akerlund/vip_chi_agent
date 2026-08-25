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
#   summary.txt          one line per failing or hung test, then the SV_TOTAL
#                        tally. FAIL and HUNG are separate outcomes: a FAIL
#                        reached a verdict and it was bad, a HUNG reached no
#                        verdict at all (see TEST_TIMEOUT_S below).
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
# Per-check tally export. A single run cannot say which check does nothing
# anywhere -- only the union over the sweep can -- so each run appends its rows
# and scripts/check_vacuity.py reads the lot.
CHECK_CSV="${CHECK_CSV:-$OUT_DIR/check_tallies.csv}"
# The opcode-evidence companion. Separate from the tally file on purpose: that
# one is keyed (run, bind, check) and three gates read it, so widening it to
# carry an opcode would multiply every row to say something about the STIMULUS
# rather than about which check ran.
OPCODE_CSV="${OPCODE_CSV:-$OUT_DIR/opcode_evidence.csv}"
# Per-test wall-clock ceiling. A simulator that stops advancing time does not
# exit and does not fail -- it spins, and the sweep waits on it forever. One
# hung testcase then costs the WHOLE regression rather than one verdict, which
# is how a sweep comes back after hours with no result at all instead of "158
# passed, 1 hung". Kept generous: this is a stuck-detector, not a performance
# budget, and a slow test blocking the licence queue is normal.
TEST_TIMEOUT_S="${TEST_TIMEOUT_S:-600}"

mkdir -p "$OUT_DIR"
SUMMARY="$OUT_DIR/summary.txt"
: > "$SUMMARY"
rm -f "$CHECK_CSV" "$OPCODE_CSV"

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

# The revision the tallies were produced at, passed to each run as a plusarg.
#
# check_vacuity.py compares the two ports' CSVs against each other, and both of
# the sections that do so are meaningless if the inputs describe different code.
# The exporter stamps whatever this supplies; "unknown" if it supplies nothing,
# which is why this is computed once here rather than left to the simulator.
# "-dirty" matters as much as the hash during development: two sweeps of one
# commit can still be of different code.
SOURCE_REV="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]; then
  SOURCE_REV="${SOURCE_REV}-dirty"
fi

pass=0
fail=0
hung=0
for t in $(ls "$ROOT/testbench/sv/tc"/tc_*.sv | sed 's|.*/||; s|\.sv$||'); do
  timeout --signal=TERM "$TEST_TIMEOUT_S" \
    "$SIMV" +UVM_TESTNAME="$t" +vip_chi_check_csv="$CHECK_CSV" \
      +vip_chi_opcode_csv="$OPCODE_CSV" \
    +vip_chi_rev="$SOURCE_REV" \
    -l "vcs_${t}.log" > /dev/null 2>&1
  rc=$?
  # 124 is timeout(1) reporting it fired. Counted apart from a failure on
  # purpose: a FAIL is a verdict that was reached and was bad, a HUNG is no
  # verdict at all, and the two want different follow-up. Reported before the
  # log is consulted, because a spinning simulator leaves a log whose last
  # buffered line is whatever it managed to flush -- which can read as clean.
  if [ "$rc" -eq 124 ]; then
    hung=$((hung + 1))
    echo "HUNG: $t (no verdict after ${TEST_TIMEOUT_S}s)" >> "$SUMMARY"
    continue
  fi
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
  echo "SV_TOTAL pass=$pass fail=$fail hung=$hung"
  echo "finished $(date -Is)"
} >> "$SUMMARY"

# Report which checks the whole sweep never exercised. Advisory here -- a green
# sweep with a dead check is still a real result to look at, and failing the
# regression on it would hide the pass/fail verdict behind a separate concern.
if [ -f "$CHECK_CSV" ]; then
  python3 "$ROOT/scripts/check_vacuity.py" "$CHECK_CSV" >> "$SUMMARY" 2>&1 || true
fi

# Opcode encodings: the two ports against each other always, and both against
# the specification when a conversion of it is available (CHI_SPEC_E_MD). The
# Arm document is not in this repository, so this checks what it can and says
# what it could not. Advisory here for the same reason as the vacuity report --
# the pass/fail verdict above should not be buried behind a separate concern.
python3 "$ROOT/scripts/check_opcodes.py" >> "$SUMMARY" 2>&1 || true

# Cross-port parity of the hand-transcribed surfaces: the check-ID registries,
# non-opcode enums and flit field order (check_type_parity), and the agent-config
# fields (check_cfg_parity). Both compare the ports to each other and need no
# simulator, so they run here for the same reason the opcode check does -- a
# parity claim nothing sweeps is a claim that decays between reviews. Advisory,
# like the two above, so the pass/fail verdict stays legible.
python3 "$ROOT/scripts/check_type_parity.py" >> "$SUMMARY" 2>&1 || true
python3 "$ROOT/scripts/check_cfg_parity.py" >> "$SUMMARY" 2>&1 || true

# Opcode CLASSIFIER coverage. The checks above compare what the two ports SAY;
# this one asks which opcodes each port's checker actually applies its rules to.
# A classifier that forgets an opcode family switches every rule it gates off for
# that family silently -- no failure, and healthy-looking tally rows from the
# opcodes it did not forget, so check_vacuity.py cannot see it. That is how the
# combined Write + CMO family stood the write-burst checks down for six opcodes,
# and how WriteUniqueZero arrived two commits later with TxnID reuse and the
# completion timeout not applying to it. Needs no simulator and no specification.
python3 "$ROOT/scripts/check_classifier_coverage.py" >> "$SUMMARY" 2>&1 || true

# Table 12-2 entered twice: once as the classifier CHI_REQ_TAGOP_LEGAL reads when
# it judges a flit, once as the opcode groups con_tagop_legal solves when it
# decides what this VIP will emit. They cannot be one expression -- a function
# call inside a SystemVerilog constraint makes every rand argument solve-ordered
# -- so this compares them opcode by opcode. A generator and a checker that
# disagree about the same table is the worse of the two failures: either the VIP
# emits requests its own rule then reports, or both were edited wrong together and
# the table stops being the authority either of them claims. No simulator needed.
python3 "$ROOT/scripts/check_tagop_groups.py" >> "$SUMMARY" 2>&1 || true

# The two illegal-bin checks, on the two coherency crosses. An illegal covergroup
# bin is not part of the UVM report path: VCS treats the hit as a verification
# error and ends the simulation, before the report summary this script greps
# for, so a wrong bin fails a run in a way that reads like a simulator problem
# rather than like a wrong bin.
#
#   check_snp_resp_illegal_bins.py  the bins of cg_snp_resp_legality against
#                                   snp_resp_hits_illegal_bin, the predicate a
#                                   negative control declares to suppress a
#                                   deliberate hit. Two copies of one rule, and a
#                                   drift makes the control unsuppressable again.
#   check_req_snp_illegal_bins.py   the bins of cg_req_snp_pairing against
#                                   Table 4-5 itself, as the D8 rule reads it.
#                                   The direction that matters is one way round:
#                                   a bin claiming a PERMITTED pairing ends the
#                                   run on conformant traffic.
#
# GATES rather than advisory, by the same criterion check_bind_coverage.py meets
# below: each compares two statements of one table that are both in this
# repository, so neither needs a second flow, a simulator or a specification, and
# there is nothing for either to be inconclusive about. The parity checks above
# are advisory because a missing Python sweep is not a failure of this one; these
# have no such excuse, and their failure mode is a run that breaks LATER with
# nothing in its log to say why.
python3 "$ROOT/scripts/check_snp_resp_illegal_bins.py" >> "$SUMMARY" 2>&1 || illegal_bins_bad=1
python3 "$ROOT/scripts/check_req_snp_illegal_bins.py" >> "$SUMMARY" 2>&1 || illegal_bins_bad=1

# Source comments must not point at the review scaffolding. Finding IDs, trace
# rows and box numbers live in documents that are deleted when a review closes,
# so a comment citing one is unreadable the moment that happens -- and in the
# meantime is unreadable to anyone without that document open. Keep the
# specification citation, drop the ID. Also warns about a maintained testcase
# count in a comment, and about a comment narrating a defect's history rather
# than describing the code. No simulator needed.
python3 "$ROOT/scripts/check_review_refs.py" >> "$SUMMARY" 2>&1 || true

# What the two ports DECIDED about the same stimulus, per (testcase, rule).
#
# Every other cross-port gate compares a SURFACE -- config fields, enums, opcode
# sets, classifiers, testcase lists -- and all of them pass when the ports agree
# about what EXISTS. This one asks whether they agreed about what happened, which
# is where the divergences have actually been: five of the six defects the first
# licensed sweep found were one-port defects with the other port already right.
#
# It needs BOTH ports' CSVs. The Python one is now written to a defaulted path by
# testbench/py/scripts/run.py, so it exists after any pyUVM sweep; until that
# default existed this was a manual step, which is how four divergences reached
# the tree. Advisory here, and it reports rather than gates when the pyUVM file
# is absent -- a missing Python sweep is not a failure of this one.
PY_TALLIES="$ROOT/build/py_regression/check_tallies.csv"
if [ -f "$PY_TALLIES" ]; then
  python3 "$ROOT/scripts/check_tally_parity.py" \
    "$OUT_DIR/check_tallies.csv" "$PY_TALLIES" >> "$SUMMARY" 2>&1 || true
else
  echo "tally parity: no pyUVM CSV at $PY_TALLIES; run testbench/py/scripts/run.py -a" >> "$SUMMARY"
fi

# The regression sizes quoted in prose, against the testcases that exist. The
# sweep is the only place that knows both numbers at once.
python3 "$ROOT/scripts/check_test_counts.py" >> "$SUMMARY" 2>&1 || true

# What the two ports' coherency checkers JUDGED on the same testcase. Every check
# above compares a SURFACE -- enums, config fields, opcode sets, classifiers,
# testcase lists -- and all of them pass when the ports agree about what exists.
# None looks at what the ports DECIDED when the same stimulus went through them,
# and that is where the divergences have been: the Python DAT hook judging 14 of
# 19 snoop responses against SV's 19, and the SV reset clearing 13 of 16 counters.
# Both numbers were printed by both flows and nobody was comparing them.
#
# Needs the PYTHON logs as well, so it reports and exits 1 when only this flow has
# run. Advisory here, like the checks above: a missing Python sweep is not a
# failure of this one.
python3 "$ROOT/scripts/check_counter_parity.py" >> "$SUMMARY" 2>&1 || true

# Every live link carries a checker, and every checker reports somewhere. This is
# the one check above that reads the HARNESS first and the rows second, and that
# order is the whole point: check_vacuity.py aggregates over exported rows, and an
# aggregation over rows cannot report the absence of rows. Sixteen HN-I proxy
# interfaces carried no bind at all across twelve testcases, exporting nothing,
# and every report that existed read as a report on the whole testbench.
#
# It is a GATE, not advisory. Unlike the parity checks above it needs no second
# flow and no specification -- the top and this sweep's own CSV are both present
# by definition -- so there is nothing for it to be inconclusive about, and a new
# topology added without a checker should stop the sweep rather than be noted in
# a file someone reads later.
python3 "$ROOT/scripts/check_bind_coverage.py" --csv "$OUT_DIR/check_tallies.csv" \
  >> "$SUMMARY" 2>&1 || bind_gap=1

# The per-opcode evidence axis, and it is a JOIN rather than a reading of either
# input. The classifiers that gate the REQ-derived checks are pure functions of
# the opcode, so which opcodes they CLAIM needs no simulation; which opcodes the
# regression DRIVES needs nothing but a sweep. Neither is a defect on its own --
# an opcode nothing drives costs nothing however it is classified, and an opcode
# that is driven is fine as long as something claims it. Driven AND unclaimed
# means every REQ-derived rule stood down for traffic that really went out,
# while still accumulating passes from the opcodes it does claim, so no artifact
# that exists reports it as anything but healthy. That has happened twice, to the
# same opcode family, and both times a human found it.
#
# Both ports' censuses, because either flow can be the one that drives a family
# first. A GATE, by the same criterion as check_bind_coverage.py above: the
# sweep's own CSV is present by definition and the classifier half is source, so
# there is nothing for it to be inconclusive about.
python3 "$ROOT/scripts/check_opcode_evidence.py" "$OPCODE_CSV" \
  "$ROOT/build/py_regression/opcode_evidence.csv" >> "$SUMMARY" 2>&1 || opcode_gap=1

exit $(( fail > 0 || ${bind_gap:-0} > 0 || ${illegal_bins_bad:-0} > 0 || ${opcode_gap:-0} > 0 ))
