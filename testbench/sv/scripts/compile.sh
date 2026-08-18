#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# FuseSoC-backed build + run for the vip_chi front-end compile smokes.
#
# This smoke build proves the current shared-scenario slices:
# - vip_chi_types_pkg + vip_chi_if elaborate with exact CHI-D and CHI-E shapes
# - one shared chi_tb_top hosts every scenario; each link is a
#   chi_link_adapter joining two real agents, and the active topology is
#   selected by testcase configuration instead of one top per scenario
# - vip_chi_agent_pkg packages the current class surface, including the first
#   sequencer cut, and can be consumed through a single package import
# - a first RN-I agent path can start a packaged write sequence, drive REQ/DAT
#   flits onto vip_chi_if, and let the packaged monitor observe them
# - a first SN-F agent path can start a packaged pipelined response sequence,
#   drive multi-beat CompData plus Comp completion traffic onto vip_chi_if,
#   and let the packaged monitor observe the assembled DAT and RSP items
# - a first autonomous SN-F read-responder path can observe a remote ReadNoSnp
#   request on vip_chi_if and return assembled CompData without a sequence item
# - a first integrated RN-I->SN-F read path can issue ReadNoSnp through the
#   RN-I sequencer/driver stack, receive CompData back through the RN-I driver
#   response path, and let the RN-I monitor observe the same completion
# - a first integrated RN-I->SN-F write-then-read path can commit write data
#   into the SN-F backing memory and read the same payload back on a later
#   ReadNoSnp through the real sequencer and driver stacks
# - a first integrated RN-I->SN-F partial-write path can commit BE-masked
#   write data into the SN-F backing memory and read back only the enabled
#   bytes, with untouched lanes preserved as zero in the fresh backing row
# - cfg-driven `decerr_ranges` now force NDERR on both writes and reads in the
#   autonomous SN-F path, with writes rejected and reads returned using the
#   normal beat count with zeroed CompData placeholders carrying NDERR
# - cfg-driven `derr_ranges` now force DERR on reads in the autonomous SN-F
#   path while still returning data from the SN-F backing memory
# - a first integrated RN-I->SN-F atomic path can issue operand DAT, perform
#   autonomous backing-memory RMW in the SN-F, and return either completion-only
#   or old-data CompData depending on the atomic opcode
# - convenience atomic family sequences now cover AtomicStore[0:7],
#   AtomicLoad[0:7], AtomicSwap, and AtomicCompare with a broader integrated
#   sweep test that checks per-variant readback behavior
# - signal-drivability contract tests now prove structured REQ/DAT/RSP setters,
#   separated-read return routing, and exact-E tagging fields reach the wire and
#   are observed back through the monitors
# - the HN-I proxy suite routes RN-I -> HN-I -> SN-F through the shared top for
#   pass-through, fan-in, address-decoded crossbar, SAM, and QoS scenarios
# - vip_chi_item compiles under UVM and randomizes representative requests
# - vip_chi_cfg_item preserves its documented defaults and reset semantics
# - vip_chi_base_seq, the first concrete wrappers, and a caller-driven pipelined sequence compile and execute locally
# -----------------------------------------------------------------------------
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)   # repo root (vip_chi_agent)
CORE="akerlund::vip_chi_agent_example:0"
RUNDIR="build/akerlund__vip_chi_agent_example_0/default-vcs"
SIMV="./akerlund__vip_chi_agent_example_0"

TESTS=(
  tc_chi_cfg_item_smoke
  tc_chi_item_smoke
  tc_chi_base_seq_smoke
  tc_chi_d_raw_inject
  tc_chi_e_req_smoke
  tc_chi_e_dat_smoke
  tc_chi_e_snf_dat_smoke
  tc_chi_e_mte
  tc_chi_d_read_smoke
  tc_chi_d_reset
  tc_chi_d_credit_starvation
  tc_chi_d_link_reactivation
  tc_chi_d_prefetch_tgt
  tc_chi_e_signal_drivability
  tc_chi_d_ordered_write
  tc_chi_d_ordered_read
  tc_chi_e_dbid_resp_ord
  tc_chi_e_rsp_field_legality
  tc_chi_e_persist
  tc_chi_e_write_zero_readback
  tc_chi_e_write_cmo
  tc_chi_d_split_write_rsp
  tc_chi_d_atomic
  tc_chi_d_atomic_variants
  tc_chi_d_write_read_smoke
  tc_chi_d_write_partial_smoke
  tc_chi_d_decerr_smoke
  tc_chi_d_derr_smoke
  tc_chi_d_hni_passthrough
  tc_chi_d_hni_fanin
  tc_chi_d_hni_xbar
  tc_chi_d_hni_sam
  tc_chi_d_hni_qos
  tc_chi_d_hni_decerr
  tc_chi_d_hni_atomic
  tc_chi_d_hni_persist
  tc_chi_d_hni_split_write_rsp
  tc_chi_d_hni_reset
  tc_chi_d_hni_backpressure
)

cd "$ROOT"

if ! command -v fusesoc >/dev/null 2>&1; then
  echo "ERROR: fusesoc is not on PATH (pip install fusesoc; run 'git submodule update --init' once)" >&2
  exit 1
fi

# Clean build: VCS elaborate + compile of the whole env.
fusesoc --cores-root . run --target default --tool vcs --setup --build "$CORE"

# Run each smoke on the built simulator.
cd "$RUNDIR"
for test_name in "${TESTS[@]}"; do
  "$SIMV" +UVM_TESTNAME="$test_name" -l "vcs_${test_name}.log"
done
