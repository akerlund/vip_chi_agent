# vip_chi example — UVM testbench guide

This document explains how the `vip_chi` example testbench is built and, in
detail, how the structural top (`tb/chi_tb_top.sv`) works. For the
per-testcase catalog see [../TEST_CASES.md](../TEST_CASES.md); for the
quick-start / regression-runner notes see [README.md](README.md).

The example is **DUT-less**. There is no design in the middle: the top provides
the peer-side wiring that cross-connects two real UVM agents on each link
(`RN↔SN`, or `RN↔HN↔SN`). Each link is a `chi_link_adapter` instance (see
§3.5) — the top hosts interfaces and joins them; it never fabricates CHI
traffic. All supported links co-exist in the build; a testcase selects a
topology by driving the matching agents, and idle agents stay parked.

---

## 1. Component hierarchy

```text
uvm_test_top : chi_base_test (or chi_e_base_test for the CHI-E tests)
  └─ env : chi_tb_env
       ├─ rni_agent   : vip_chi_agent #(CHI_D_CFG_C, chi_d_types_t, RNI)   // integrated requester
       ├─ snf_agent   : vip_chi_agent #(CHI_D_CFG_C, chi_d_types_t, SNF)   // integrated responder
       ├─ hrni0_agent : vip_chi_agent #(CHI_D_CFG_C, chi_d_types_t, RNI)   // HN-I requester, port 0
       ├─ hrni1_agent : vip_chi_agent #(CHI_D_CFG_C, chi_d_types_t, RNI)   // HN-I requester, port 1
       ├─ hsnf0_agent : vip_chi_agent #(CHI_D_CFG_C, chi_d_types_t, SNF)   // HN-I responder, SN target 0
       ├─ hsnf1_agent : vip_chi_agent #(CHI_D_CFG_C, chi_d_types_t, SNF)   // HN-I responder, SN target 1
       ├─ hni_agent   : vip_chi_hni_agent #(CHI_D_CFG_C, chi_d_types_t, 2, 2)  // HN-I proxy (2 RN x 2 SN)
       ├─ coverage    : vip_chi_coverage #(CHI_D_CFG_C)
       ├─ virtual_sequencer : chi_virtual_sequencer  (rni / snf / hrni0 / hrni1 sequencer handles)
       └─ per-channel uvm_tlm_analysis_fifos (rni_*, snf_*, hsnf0_req, hsnf1_req)
```

Every topology has its own dedicated agents and interfaces, and they all
co-exist in one build. The integrated pair (`rni_agent`/`snf_agent`) and the HN-I
family (`hrni0`/`hrni1`/`hsnf0`/`hsnf1` + `hni_agent`) are separate, so no
interface is ever shared between topologies. A test simply drives sequences on
the agents of the topology it exercises; the rest sit idle.

Ownership and lifecycle:

- **`chi_base_test`** owns the shared `chi_tb_config` object, builds all
  agent cfgs as `UVM_ACTIVE`, publishes `tb_cfg` + per-agent cfgs through
  `uvm_config_db`, and exposes the hooks tests override:
  `configure_tb_cfg()`, `configure_agent_cfgs()`.
- **`chi_tb_env`** builds all agents, the coverage subscriber, the
  observation FIFOs, and the virtual sequencer, and connects monitor analysis
  ports into the FIFOs + coverage.
- **`chi_tb_top`** is structural only: it hosts the interfaces, binds SVA,
  generates clock/reset, and joins the interfaces with `chi_link_adapter`
  instances.
- The **CHI-E focused tests** (`tc_chi_e_*`, `tc_chi_e_mte`, `tc_chi_e_persist`,
  `tc_chi_e_dbid_resp_ord`) all extend `chi_e_base_test`, which builds
  `chi_e_tb_env` — a real RN-I **and** SN-F agent pair on the wide CHI-E
  link (`chi_e_wide_rni_if ↔ chi_e_wide_snf_if`), joined by the `e_wide_link`
  adapter when `tb_cfg.run_e_wide_integrated` is set. There is no faked peer.

---

## 2. Co-existing topologies (no runtime mode)

There is no topology mux. Each topology has its own dedicated interfaces and
agents, all present in every build, each link permanently wired by a static
`chi_link_adapter`. A test "selects" its topology purely by which agents it
drives sequences on; the others stay idle. This is why `tb_top` needs no mode
decode and no wiring logic.

| Topology | Agents driven | Links (all static) |
| --- | --- | --- |
| Integrated | `rni_agent` → `snf_agent` | `rni_if` ↔ `snf_if` |
| HN-I pass-through | `hrni0_agent` → `hsnf0_agent` | `hni_rni0_if` ↔ `hni_rn0_if`, `hni_sn0_if` ↔ `hni_snf0_if` |
| HN-I fan-in | `hrni0` + `hrni1` → `hsnf0` | + `hni_rni1_if` ↔ `hni_rn1_if` |
| HN-I crossbar | `hrni0` + `hrni1` → `hsnf0` + `hsnf1` | + `hni_sn1_if` ↔ `hni_snf1_if` (proxy address-decodes) |
| CHI-E | `chi_e_tb_env` RN-I → SN-F | `chi_e_wide_rni_if` ↔ `chi_e_wide_snf_if` |

Every link always has two real agents on it — there are no synthetic-peer modes.
Testing one agent in isolation is done with a real peer plus directed stimulus,
not by faking the peer in the top.

The wide CHI-E link's `e_wide_link` adapter is the only one gated (by the `tb_cfg`
`run_e_wide_integrated` flag every `chi_e_base_test` sets), so the CHI-E
interfaces stay parked at idle during CHI-D tests. `tc_chi_e_mte`, `tc_chi_e_persist`,
`tc_chi_e_dbid_resp_ord`, and the `tc_chi_e_*` smokes run on it.

There is no topology/mode enum at all: topology is purely a matter of which
agents a test drives sequences on.

---

## 3. `chi_tb_top` in detail

The top is almost entirely interface instances plus one `chi_link_adapter`
per link. The only other content is clock/reset generation and the `config_db`
handoff — no topology mux, no mode decode, no fabricated traffic, no credit or
SVA-enable logic.

### 3.1 Clock and reset

- `clk`: free-running 10 ns period from an `initial forever #5`.
- `rst_n`: asserted low, released at `#30`.
- `rst_n_int = rst_n && (reset_pulse_countdown == 0)`: the interfaces actually
  use `rst_n_int`, which lets a test request a **mid-run reset pulse** (via
  `tb_cfg.request_reset_pulse(cycles)`) without disturbing the global `rst_n`.
  `tc_chi_d_reset` and `tc_chi_d_link_reactivation` exercise this.

### 3.2 Interfaces

All interfaces are `vip_chi_if` parameterized by `(CFG_P, FLIT_TYPES_T, ROLE_P)`
and clocked on `clk` / reset on `rst_n_int`.

CHI-D interfaces (`CHI_D_CFG_C`, `chi_d_types_t`) — dedicated per topology:

| Instance | Role | Used by |
| --- | --- | --- |
| `rni_if` | RN-I | `rni_agent` (integrated requester) |
| `snf_if` | SN-F | `snf_agent` (integrated responder) |
| `hni_rni0_if` | RN-I | `hrni0_agent` (HN-I requester, port 0) |
| `hni_rni1_if` | RN-I | `hrni1_agent` (HN-I requester, port 1) |
| `hni_rn0_if` | HN-I | `hni_agent` RN-facing port 0 |
| `hni_rn1_if` | HN-I | `hni_agent` RN-facing port 1 |
| `hni_sn0_if` | RN-I | `hni_agent` SN-facing port 0 |
| `hni_sn1_if` | RN-I | `hni_agent` SN-facing port 1 |
| `hni_snf0_if` | SN-F | `hsnf0_agent` (HN-I responder, SN target 0) |
| `hni_snf1_if` | SN-F | `hsnf1_agent` (HN-I responder, SN target 1) |

Note the polarity: an HN-I RN-facing port uses `ROLE_P=HNI` (SN-F signal
directions — the proxy is the *completer* toward the RN), and an HN-I SN-facing
port uses `ROLE_P=RNI` (the proxy is the *requester* toward the SN).

The wide CHI-E datapath (`CHI_E_WIDE_CFG_C`, `chi_e_wide_types_t`):

| Instance | Role | Used by |
| --- | --- | --- |
| `chi_e_wide_rni_if` | RN-I | `chi_e_tb_env.rni_agent` |
| `chi_e_wide_snf_if` | SN-F | `chi_e_tb_env.snf_agent` |

Compile-coverage anchors (never carry executable traffic — they only force the
interface to elaborate at wider flit shapes so parameterization breakage is
caught):

- `chi_d_wide_rni_if` / `chi_d_wide_snf_if` (`CHI_D_WIDE_CFG_C`)
- `chi_e_wide_hni_if` (`CHI_E_WIDE_CFG_C`, HN-I role)

### 3.3 SVA binds

`vip_chi_sva` is instantiated on `rni_if`, `snf_if`, and the wide CHI-E RN-I/SN-F
interfaces. There is no separate enable logic: each bind's `checks_enable` is an
inline expression on its own interface's link-active
(`(vif.txlinkactivereq === 1'b1) || (vif.rxlinkactivereq === 1'b1)`). An interface
whose agent is not built/driving never activates its link, so the `=== 1'b1` gate
stays low (x-safe) and idle/unused interfaces raise no spurious assertions.

### 3.4 Links (static adapters)

Every link is a **`chi_link_adapter`** instance — a small module that
cross-wires a requester-polarity endpoint's `tx*` onto a completer-polarity
endpoint's `rx*` and vice-versa. Because each topology owns dedicated interfaces
(§2), every interface has exactly one partner, so all six adapters are just
statically instantiated (no `enable`, no topology mux, no mode decode):

- `int_link` — `rni_if` ↔ `snf_if`.
- `hni_rn0_link` / `hni_rn1_link` — `hni_rni{0,1}_if` ↔ `hni_rn{0,1}_if`.
- `hni_sn0_link` / `hni_sn1_link` — `hni_sn{0,1}_if` ↔ `hni_snf{0,1}_if`.
- `e_wide_link` — `chi_e_wide_rni_if` ↔ `chi_e_wide_snf_if`.

Credit starvation (`tc_chi_d_credit_starvation`) is no longer a harness wire pinch:
it is driven through the RN-I driver's `cfg.hold_dat_credit`, which pauses that
agent's DAT credit advertisement (draining the backlog once cleared). So the
integrated link is a plain adapter like every other.

### 3.5 `config_db` handoff (`initial`)

After the structural resources exist, an `initial` block publishes the virtual
interfaces to the agents' config paths (`uvm_test_top.env.<agent>`), including
the HN-I proxy's `rn_vif_<i>` / `sn_vif_<j>` arrays, then calls `run_test()`.
From there UVM owns the scenario: the testcase builds the env, publishes
`tb_cfg`, and drives any runtime mutations on that shared object.

---

## 4. Checking strategy

Checking is layered — per-test FIFO consumption, SVA, coverage, and a
standalone scoreboard:

- Monitor analysis ports feed per-channel `uvm_tlm_analysis_fifo`s; directed
  tests consume those FIFOs and compare against sequence responses / expected
  payloads.
- `vip_chi_sva` provides transport/reset/link/credit/ordering closure per
  interface.
- `vip_chi_coverage` accumulates functional coverage from the same monitor
  streams.
- `vip_chi_scoreboard` connects in parallel to the same monitor ports (the
  integrated RN-I/SN-F pair, both proxy RNs, and the completer REQ views) and
  checks RN-I↔SN-F transaction consistency: (A) per-transaction lifecycle /
  completion contract, (B) cross-agent request fidelity / relayed-exactly-once,
  and (C) an independent, predictable-only write→read data check. On by default;
  gated per-test via `tb_cfg.scoreboard_enable` / `scoreboard_check_data`.
  Completer-originated or intentionally-partial-traffic tests opt out
  (`tc_chi_d_raw_inject`, `tc_chi_e_signal_drivability`, `tc_chi_e_snf_dat_smoke`).

For the HN-I modes, note that the RN-I monitors observe the RN↔HN links and the
SN-F monitors observe the HN↔SN links, so a test can confirm both that the RN saw
correct completions **and** that the SN actually received the forwarded requests
(proving the proxy relayed rather than short-circuited).
