# vip_chi testbenches

This directory contains the DUT-less example regressions for `vip_chi`.

There are two implementations of the same verification intent:

- [sv](sv) is the SystemVerilog UVM flow, built with FuseSoC and VCS.
- [py](py) is the pyUVM/cocotb flow, built with FuseSoC and Verilator.

Both flows build one shared structural harness. A testcase selects a scenario by
driving the agents it needs; the top does not decode the testcase name and does
not fabricate CHI traffic. Every active link is between two real VIP agents.

The shared testcase catalog is [TEST_CASES.md](TEST_CASES.md).

## Topologies

The testbenches cover the same scenario families:

- Integrated RN-I to SN-F traffic.
- HN-I proxy paths: pass-through, fan-in, crossbar, SAM, QoS, reset, errors.
- Wide CHI-E requester/completer traffic.
- Coherent RN-F/HN-F traffic over SNP-capable links.

The SystemVerilog and Python flows are not source-identical. The SV flow uses
real SystemVerilog interfaces, agents, and UVM tests. The Python flow uses a
flat-net HDL shell for Verilator and builds the agents, buses, environments, and
test wrappers in Python.

## Layout

```text
testbench/
├── README.md                  # shared testbench overview
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
