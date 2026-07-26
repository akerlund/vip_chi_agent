# vip_chi Python testbench

This is the pyUVM/cocotb implementation of the shared `vip_chi` example
regression. It builds with FuseSoC and Verilator.

The shared testbench overview is [../README.md](../README.md). The shared
testcase catalog is [../TEST_CASES.md](../TEST_CASES.md).

## Structure

The Python flow has one HDL shell and one Python testbench top:

```text
tb/vip_chi_hdl_top.sv
tb/vip_chi_tb_top.py
vip_chi_agent_example_py.core
```

`vip_chi_hdl_top.sv` exposes the Verilator-visible flat nets. `vip_chi_tb_top.py`
creates the `ChiBus` objects, publishes them through pyUVM `ConfigDB`, and
contains one static cocotb wrapper per public `tc_*` testcase.

## Build And Run

Run from this directory:

```sh
./scripts/run.py --build
./scripts/run.py --list
./scripts/run.py -t tc_chi_d_read_smoke --no-build
./scripts/run.py --all --no-build
```

Logs are written under `rundir/verilator/` using the public testcase name, for
example `rundir/verilator/tc_chi_d_read_smoke.log`.
