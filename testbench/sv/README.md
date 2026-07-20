# vip_chi example regression

This directory is the standalone UVM example for `vip_chi`. It no longer uses
one compile-only top per scenario. Instead, it builds one shared structural
harness and runs the example suite as normal UVM tests on top of that harness.

There is no DUT in the middle of this example. The shared top hosts the CHI
interfaces and joins them with `vip_chi_link_adapter` instances so two real
agents sit on every link (RN-I ↔ SN-F, RN-I ↔ HN-I ↔ SN-F, or the wide CHI-E
RN-I ↔ SN-F pair). The top never fabricates CHI traffic or fakes a peer.

## Architecture

- [tb/tb.svh](tb/tb.svh) is the single FuseSoC-compiled wrapper. It includes the
  shared TB package, the testcase package, and the shared top.
- [tb/vip_chi_tb_pkg.sv](tb/vip_chi_tb_pkg.sv) holds shared constants,
  typedefs, address labels, and env-facing declarations.
- [tb/vip_chi_tb_config.sv](tb/vip_chi_tb_config.sv) is the dedicated shared
  harness-configuration object. It is one class per file and now carries only the
  test-requestable mid-run reset pulse and the CHI-E datapath enable. Credit
  starvation moved to the RN-I agent cfg (`hold_dat_credit`).
- [tc/vip_chi_base_test.sv](tc/vip_chi_base_test.sv) owns `vip_chi_tb_config`,
  builds every agent cfg as active, publishes them through `uvm_config_db`, and
  exposes the `configure_tb_cfg()` / `configure_agent_cfgs()` hooks.
- [tb/vip_chi_link_adapter.sv](tb/vip_chi_link_adapter.sv) is the reusable
  module that cross-wires one CHI interface endpoint onto another (or parks both
  receive sides when disabled). Every link in the top is one instance of it.
- [tb/vip_chi_tb_top.sv](tb/vip_chi_tb_top.sv) is structural only. Each topology
  has its own dedicated interfaces and agents, all co-existing, so every link is
  a permanently-wired `vip_chi_link_adapter` — there is no topology mux and no
  mode decode. The top also hosts `vip_chi_sva` (each bind gated inline by its own
  interface's link-active) and generates clock/reset, including a test-requestable
  mid-run reset pulse. Credit starvation is exercised through the RN-I driver's
  `cfg.hold_dat_credit`, not the top.
- [tb/vip_chi_tb_env.sv](tb/vip_chi_tb_env.sv) builds the CHI-D agents, shared
  coverage subscriber, observation FIFOs, and virtual sequencer.
- [tc/vip_chi_tc_pkg.sv](tc/vip_chi_tc_pkg.sv) wraps the base tests and the
  concrete `tc_chi_*` tests.

The exact-CHI-E tests extend `vip_chi_e_base_test`, which builds
[tb/vip_chi_e_tb_env.sv](tb/vip_chi_e_tb_env.sv) — a real RN-I + SN-F agent pair
on the wide CHI-E link joined by the `e_wide_link` adapter.

All topologies co-exist in one build — there is no mode enum and no topology
mux. Each has its own dedicated agents; a test drives the ones it needs:

- Integrated: `rni_agent` → `snf_agent`, wired directly.
- HN-I pass-through: `hrni0_agent` → HN-I → `hsnf0_agent` (1×1 proxy).
- HN-I fan-in: `hrni0` + `hrni1` fan into `hsnf0` through the HN-I.
- HN-I crossbar: two RN-I × two SN-F, address-decoded by the HN-I.
- CHI-E: the wide RN-I/SN-F pair (`vip_chi_e_tb_env`).

Every link has two real agents on it — there are no synthetic-peer modes. See
[UVM_TB.md](UVM_TB.md) for the full component hierarchy and an elaborated
walkthrough of `tb_top`.

## Checking strategy

Checking is layered: per-test FIFO consumption, SVA, coverage, and an
always-on standalone scoreboard.

- Agent monitor outputs are connected into per-channel
  `uvm_tlm_analysis_fifo`s.
- Directed tests consume those FIFOs directly and compare the observed items
  against sequence responses or expected payloads.
- [tb/vip_chi_tb_top.sv](tb/vip_chi_tb_top.sv) instantiates `vip_chi_sva` on
  each interface for transport, reset, link, credit, and ordering checks.
- [tb/vip_chi_tb_env.sv](tb/vip_chi_tb_env.sv) connects the same monitor streams
  into `vip_chi_coverage`.
- The same monitor streams also feed `vip_chi_scoreboard` (connected in
  parallel, so per-test FIFO draining is untouched). Being a DUT-less
  VIP-on-VIP setup, it checks RN-I↔SN-F protocol/transaction consistency with
  three checkers over one requester-frame transaction table: (A) per-transaction
  lifecycle / completion contract, (B) cross-agent request fidelity (every REQ
  observed at the requester is seen once, unmodified, at the completer — proving
  the HN-I proxy relayed rather than dropped/duplicated), and (C) an independent,
  predictable-only write→read data check. It is on by default and can be gated
  per-test via `tb_cfg.scoreboard_enable` / `scoreboard_check_data`.

The scoreboard augments — rather than replaces — the per-test FIFO compares;
thinning those once it is proven authoritative is a deferred follow-up.

## Regression inventory

The full, categorized test catalog — every testcase, its harness mode, and
what it proves — lives in [TEST_CASES.md](TEST_CASES.md). It is the
authoritative list; this README does not duplicate it.

## Running

Built with [FuseSoC](https://github.com/olofk/fusesoc) driving VCS (UVM-1.2), run
from the repository root — a single recursive `--cores-root .` discovers the
agent, this example, and both submodule cores.

Build the example testbench (VCS elaborate + compile of the whole env):

```sh
git submodule update --init   # one-time: fetch vip_memory, vip_report_server
fusesoc --cores-root . run --target default --tool vcs --setup --build \
        akerlund::vip_chi_agent_example:0
```

Run a single testcase on the built simulator (any `tc_chi_*` / `tc_chi_coh_*` name):

```sh
cd build/akerlund__vip_chi_agent_example_0/default-vcs
./akerlund__vip_chi_agent_example_0 +UVM_TESTNAME=tc_chi_d_reset -l vcs.log
```

Run the full regression by looping the [TEST_CASES.md](TEST_CASES.md) catalog
names through the built simulator (a shell `for` over the `tc_chi_*` names). A
passing run ends with `Test (<name>) PASS` and `UVM_ERROR: 0 / UVM_FATAL: 0`;
treat those per-test lines as the reliable success signal. The convenience
wrapper [scripts/compile.sh](scripts/compile.sh) does the build-then-loop.

## File layout

```text
examples/vip_chi_agent/
├── README.md
├── scripts/
│   └── compile.sh
├── tb/
│   ├── tb.svh
│   ├── vip_chi_e_tb_env.sv
│   ├── vip_chi_link_adapter.sv
│   ├── vip_chi_tb_config.sv
│   ├── vip_chi_tb_env.sv
│   ├── vip_chi_tb_pkg.sv
│   ├── vip_chi_tb_top.sv
│   └── vip_chi_virtual_sequencer.sv
├── tc/
│   ├── vip_chi_base_test.sv
│   ├── vip_chi_tc_pkg.sv
│   ├── vip_chi_write_zero_fatal_catcher.sv
│   └── tc_chi_*.sv
└── yml/
    └── compile.yml
```
