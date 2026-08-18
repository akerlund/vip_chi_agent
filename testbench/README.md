# vip_chi testbenches

This directory contains the DUT-less example regressions for `vip_chi`.

There are two implementations of the same verification intent:

- [sv](sv) is the SystemVerilog UVM flow, built with FuseSoC and VCS.
- [py](py) is the pyUVM/cocotb flow, built with FuseSoC and Verilator.

Both flows build one shared structural harness. A testcase selects a scenario by
driving the agents it needs; the top does not decode the testcase name and does
not fabricate CHI traffic. Every active link is between two real VIP agents.

The shared testcase catalog is [TEST_CASES.md](TEST_CASES.md): **149 SystemVerilog
and 150 pyUVM/cocotb** testcases, the same list on both sides bar one Python-only
entry.

## How it works

There is no DUT. A CHI link here is two VIP agents facing each other, and the
harness is the wiring between them:

```text
  agent A (RN-I)                                   agent B (SN-F)
  ┌────────────┐   tx*  ───────────────►  rx*     ┌────────────┐
  │  driver    │        chi_link_adapter          │   driver   │
  │  monitor   │   rx*  ◄───────────────  tx*     │   monitor  │
  └────────────┘                                  └────────────┘
        │ analysis ports                                │
        └──────────────► scoreboard / coverage / perf ◄──┘
```

`chi_link_adapter` is the whole interconnect: it cross-wires each endpoint's
transmit signals to the other's receive signals, in both directions, including
the sideband and the SNP channel. It contains no protocol logic, so a bug in one
agent cannot be absorbed by the harness before the other agent sees it.

**One compiled image holds every topology.** All interfaces, links and agents
elaborate in every build; a testcase drives the ones it needs and the rest carry
idle. That is why an unused topology costs nothing but also why an agent that is
never built leaves its link inactive rather than absent — the protocol checkers
are gated on link activity precisely so an idle link raises nothing.

Reset is shared: one clock and one reset for the whole top, with the reset pulse
driven by the testcase through `chi_tb_config`.

## By the numbers (SystemVerilog flow)

Everything below lives in [sv/tb/chi_tb_top.sv](sv/tb/chi_tb_top.sv).

| Element | Count | Notes |
|---|---|---|
| `vip_chi_if` instances | **37** | 14 RN-I · 10 SN-F · 5 HN-I · 4 RN-F · 4 HN-F |
| `chi_link_adapter` instances | **17** | joins 34 of those interfaces into links |
| Unconnected interfaces | **3** | compile-coverage anchors, see below |
| `vip_chi_sva` binds (REQ/RSP/DAT/link) | **8** | 4 non-coherent + 4 coherent; all unconditional |
| `vip_chi_snp_sva` binds (SNP channel) | **8** | 4 CHI-D + 4 CHI-E |
| Environments | **4** | one per topology family |
| Scoreboards | **3** | one instance per env that has one; the coherent env has none |

The 3 unconnected interfaces are deliberate: two at `CHI_D_WIDE_CFG_C` and one
HN-I at `CHI_E_WIDE_CFG_C`. No executable test instantiates the interface at
those shapes, so these instances are the only thing forcing it to elaborate
there. They stay idle and are not a leftover.

### Link config shapes

Four config shapes are in the build. A config fixes the flit geometry, so an
interface, an agent and a checker are all typed by it.

| Config | Issue | Node ID | Address | Data bus | Used by |
|---|---|---|---|---|---|
| `CHI_D_CFG_C` | D | 11 bit | 44 bit | 16 B | integrated pair, HN-I proxy, coherent CHI-D |
| `CHI_E_WIDE_CFG_C` | E | 11 bit | 52 bit | 64 B | CHI-E pair, CHI-E proxy, coherent CHI-E |
| `CHI_D_WIDE_CFG_C` | D | 11 bit | 44 bit | 64 B | compile anchor only |
| `CHI_A0_CFG_C` | D | 7 bit | 44 bit | 32 B | `tc_chi_a0_smoke`, driven directly with no agent |

The 16-byte CHI-D bus is why a 64-byte transfer is a four-beat burst there and a
single beat on the CHI-E link — a difference that decides which checks a given
testcase can reach.

## Environments and agents

The testcase's base class picks the environment (SV); on the Python side the
`_run_*` helper in [py/tb/chi_tb_top.py](py/tb/chi_tb_top.py) does, by publishing
the set of buses that env expects.

| Env | Topology | Agents | Analysis components |
|---|---|---|---|
| `chi_tb_env` | integrated RN-I ↔ SN-F **and** the CHI-D HN-I proxy (2 RN ports × 2 SN ports) | 6 leaf + 1 HN-I proxy | scoreboard, coverage, perf |
| `chi_e_tb_env` | wide CHI-E RN-I ↔ SN-F | 2 (`vip_chi_agent_e`) | scoreboard, coverage |
| `chi_e_proxy_tb_env` | CHI-E HN-I proxy | 4 leaf + 1 HN-I proxy | scoreboard, coverage, perf |
| `chi_coherent_tb_env` | RN-F ↔ HN-F over the SNP channel, one downstream SN-F, at both issues | 3 leaf + 1 HN-F home | coherency checker, coverage, perf |

The proxy and home agents are not leaves: `vip_chi_hni_agent` straddles 2 RN-facing
and 2 SN-facing ports, and `vip_chi_hnf_agent` 2 RN-F ports and 1 downstream SN
port. Each of their ports is its own interface, which is why the interface count
is so much higher than the agent count.

The Python side is the same shape with one difference: it splits the CHI-D proxy
into its own `chi_proxy_tb_env` rather than folding it into `chi_tb_env`, and its
`chi_tb_env` carries **both** the CHI-D and the CHI-E integrated pair (a CHI-E
testcase runs through it with CHI-E buses), so there is no separate `chi_e_tb_env`.

## One scoreboard per environment, not one per agent

`vip_chi_scoreboard` is a **single component per environment** that subscribes to
every agent's monitor in parallel through 12 analysis imps:

- 3 requester streams × REQ/RSP/DAT (`rni`, `hrni0`, `hrni1`)
- 3 completer REQ views (`snf`, `hsnf0`, `hsnf1`)

One scoreboard rather than one per link, because two of its four checkers compare
what one agent saw against what another saw — a per-agent scoreboard could not.
An env wires only the streams its topology has; the rest stay unconnected and
their checkers stay dormant.

| Checker | What it holds the design to |
|---|---|
| **A** lifecycle | every requester transaction reaches the completion its opcode requires, no orphan responses, no TxnID reused while in flight |
| **B** cross-agent fidelity | the REQ observed at the requester is the REQ observed at the completer, and (multi-SN only) it arrived at the SN its address decodes to |
| **C** data + MTE tags | an independent predicted memory image, committed only from observed writes that resolved OKAY and compared only where predictable; the tag/TagUpdate/TagOp half alongside it |
| **E** ordered streams | a completer that took on an ordering obligation acknowledges the stream in the order it received it |

The coherent env has **no scoreboard**. Its invariants are about cache state
across nodes rather than one requester's transaction table, so it runs
`vip_chi_coherency_checker` instead: single-owner, line hazard, exclusive
monitor, and coherent data integrity.

## Checkers, and what fails a run

Two independent checker families run alongside the scoreboard:

| Rules | SV | Python |
|---|---|---|
| REQ/RSP/DAT + link rules | `vip_chi_sva` bind | `sva/bind_chi.py` |
| SNP channel rules | `vip_chi_snp_sva` bind | `sva/bind_chi_snp.py` |

Every rule in both families, and every scoreboard rule, carries a stable name, a
severity and **pass and fail counts** — see the per-check section of the
[root README](../README.md). Two consequences worth knowing when reading a log:

- An assertion failure fails the run. The SV checkers report through `$error`,
  which raises no UVM error and sets no exit status, so the env folds the
  interface's fail counts into the verdict at `report_phase`. A bind no env reads
  is therefore advisory — which is a real failure mode, not a hypothetical: the
  CHI-E link's two binds were in exactly that state until they were wired in.
- A rule with zero passes *and* zero fails never ran, which a clean log otherwise
  looks exactly like. Each run prints its unexercised rules, and
  `scripts/check_vacuity.py` unions a whole regression to find the rules nothing
  anywhere reaches.

The HN-I proxy links carry no SVA binds on either flow: the proxy is a verbatim
per-flit relay, and its leaf links are already judged at both endpoints.

## Layout

```text
testbench/
├── README.md                  # this file
├── TEST_CASES.md              # shared testcase catalog
├── .refuse.yml                # named regression targets, shared by both flows
├── sv/
│   ├── README.md              # VCS/UVM run notes
│   ├── UVM_TB.md              # detailed SV harness guide
│   ├── scripts/compile.sh     # SV smoke build/run wrapper
│   ├── tb/                    # SV structural top and environments
│   ├── tc/                    # SV UVM tests
│   └── vip_chi_agent_example.core
└── py/
    ├── README.md              # Verilator/cocotb run notes
    ├── scripts/run.py         # Python build/list/run wrapper
    ├── tb/                    # flat HDL top and Python environments
    ├── tc/                    # pyUVM/cocotb tests
    └── vip_chi_agent_example_py.core
```

The two flows are not source-identical. The SV flow uses real SystemVerilog
interfaces, agents and UVM tests. Verilator does not support the interface
constructs the SV top relies on, so the Python flow uses a flat-net HDL shell
([py/tb/chi_hdl_top.sv](py/tb/chi_hdl_top.sv)) — one prefixed net group per
endpoint, cross-wired by macro, with no interfaces, no UVM and no behaviour —
and builds the agents, buses, environments and test wrappers in Python. A
`ChiBus` object binds a prefix to the same field API the SV interface exposes.

## Running

Fetch submodules once from the repository root:

```sh
git submodule update --init
```

SV/VCS flow:

```sh
cd testbench/sv
fusesoc --cores-root ../.. run --target default --tool vcs --setup --build \
        akerlund::vip_chi_agent_example:0

cd ../../build/akerlund__vip_chi_agent_example_0/default-vcs
./akerlund__vip_chi_agent_example_0 +UVM_TESTNAME=tc_chi_d_read_smoke \
  -l tc_chi_d_read_smoke.log
```

The whole SV sweep, with the per-check aggregation appended to its summary:

```sh
scripts/sv_regression.sh          # from the repository root
```

Python/Verilator flow:

```sh
cd testbench/py
./scripts/run.py --build
./scripts/run.py -t tc_chi_d_read_smoke --no-build
./scripts/run.py --all --no-build
```

See [sv/README.md](sv/README.md) and [py/README.md](py/README.md) for
flow-specific notes.

## Named regressions

[.refuse.yml](.refuse.yml) defines regression targets shared by both flows, run
through `refuse` from either testbench directory:

```sh
cd testbench/py                       # or testbench/sv
refuse verilator --list-regressions   # or: refuse simv --list-regressions
refuse verilator --regression smoke
refuse verilator --regression full
```

Both flows run the same public `tc_*` names, so one profile selects the same
scenarios on either side.

| Profile | Selects |
| --- | --- |
| `full` | everything, 4 seeded repeats |
| `smoke` | one scenario per topology: integrated read/write, CHI-E link, HN-I proxy, coherent at both issues |
| `unit` | object-level smokes and the config self-check (no link topology) |
| `link` | point-to-point RN-I ↔ SN-F datapath |
| `pipeline` | the opt-in multi-outstanding overlap family |
| `chi_e` | exact CHI-E behaviour, non-coherent and coherent |
| `proxy` | HN-I proxy paths |
| `coherent` | RN-F / HN-F subsystem over the SNP channel, both issues |
| `dataid` | DAT beat placement by `DataID` and its malformed-burst negative control |
| `negative` | every test that provokes a checker on purpose, including the anti-vacuity guards that are not named `*_negctl` |
| `coverage` | everything, with coverage collection enabled |

A regression selector that matches nothing is an error, so a profile cannot
silently stop covering what it names. Adding a negative control means adding it
to `negative`, not just naming it well: a violation test selected by no profile
is a test that never runs.
