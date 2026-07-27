# vip_chi Python testbench

This is the pyUVM/cocotb implementation of the shared `vip_chi` example
regression. It builds with FuseSoC and Verilator.

The shared testbench overview is [../README.md](../README.md). The shared
testcase catalog is [../TEST_CASES.md](../TEST_CASES.md).

## Structure

The Python flow has one HDL shell and one Python testbench top:

```text
tb/chi_hdl_top.sv
tb/chi_tb_top.py
vip_chi_agent_example_py.core
```

`chi_hdl_top.sv` exposes the Verilator-visible flat nets. `chi_tb_top.py`
creates the `ChiBus` objects, publishes them through pyUVM `ConfigDB`, and
contains one static cocotb test entry per public `tc_*` testcase.

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

## Performance

`--all` runs each testcase in its own `fusesoc --run` process, which is what
gives every test an isolated log and keeps one hang from taking the run with it.
That isolation is the dominant cost: ~0.86 s per test, of which only ~0.12 s is
the test itself.

| | 121 tests |
| --- | --- |
| `run.py --all` (one process per test) | ~105 s |
| one process, `COCOTB_TEST_FILTER` matching everything | ~25 s |

So for a local edit-run loop, filtering a batch into a single process is ~4x
faster than `--all`:

```sh
export VIP_ROOT=$(git rev-parse --show-toplevel)
export PYTHONPATH=$VIP_ROOT/testbench/py/tb:$VIP_ROOT/testbench/py/tc:$VIP_ROOT/py:$VIP_ROOT/py/seq_lib:$VIP_ROOT/submodules/vip_memory/py
COCOTB_TEST_FILTER='tc_chi_e_.*' fusesoc --cores-root . run --no-export \
  --target sim --tool verilator --run akerlund::vip_chi_agent_example_py:0
```

Profiling the in-simulator time puts ~14 % in pyvsc, so item construction is a
secondary cost rather than the main one. The monitor's flit->item builders and
`vip_chi_raw_seq._new_item` construct inside `defer_field_model()` (see
`vip_chi_item.py`), which skips the `@vsc.randobj` constraint-model build for
items that are filled directly and never randomized.
