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
