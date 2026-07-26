# vip_chi SystemVerilog testbench

This is the SystemVerilog UVM implementation of the shared `vip_chi` example
regression. It builds with FuseSoC and VCS.

The shared testbench overview is [../README.md](../README.md). The shared
testcase catalog is [../TEST_CASES.md](../TEST_CASES.md). The detailed SV
harness guide is [UVM_TB.md](UVM_TB.md).

## Build And Run

Run from this directory:

```sh
fusesoc --cores-root ../.. run --target default --tool vcs --setup --build \
        akerlund::vip_chi_agent_example:0
```

Run one testcase on the built simulator:

```sh
cd ../../build/akerlund__vip_chi_agent_example_0/default-vcs
./akerlund__vip_chi_agent_example_0 +UVM_TESTNAME=tc_chi_d_read_smoke \
  -l tc_chi_d_read_smoke.log
```

The local smoke wrapper builds the same target and runs a curated subset:

```sh
./scripts/compile.sh
```

For the full regression, loop the names from [../TEST_CASES.md](../TEST_CASES.md)
through the built simulator.
