# vip_chi

Behavioral AMBA CHI verification IP with owned flit types, a role-parameterized
interface, and UVM link/protocol-layer logic. One agent class plays one of six
roles, selected at elaboration by a class parameter; the interface and item are
shared across roles and across the CHI-D and CHI-E issues.

- **RN-I** — non-coherent requester (reads, writes, atomics, persist CMOs,
  ordered traffic, the retry handshake).
- **SN-F** — memory-target completer backed by an internal
  [vip_mem](../vip_memory) store, with DECERR/DERR injection and configurable
  split-write / ordered-DBID behaviour.
- **HN-I** — an `N_RN x N_SN` pass-through ordering proxy (QoS fan-in, SAM /
  stride address fan-out, node-id completion routing).
- **RN-F / HN-F** — the coherent requester / home-node pair over the SNP
  channel: RN-F cache model + autonomous snoop responder, HN-F directory +
  snoop origination, exclusives (LL/SC), the CMO / coherent-REQ family, DCT
  forwarding snoops, and an optional downstream SN-F.
- **Monitor** — observes the bus passively; four analysis ports feed
  scoreboards, the coherency checker, and the coverage subscriber.

Both **CHI-D** and **CHI-E** issues are supported, selected by `CFG_P.issue`.
Exact CHI-E-only flit fields (memory tagging, `DBIDRespOrd`, wider IDs) are
driven by the `*_e` driver / monitor / agent subclasses.

### Documentation map

This README covers the quick-start path, the agent architecture, and the
higher-level features. The heavy reference material lives under `docs/`:

- [docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md) — architecture, the
  flit/config contracts, per-role behaviour, §10 config reference, §12 stimulus
  API, the HN-I expansion (§20), and the open interop findings (§22).
- [docs/CHI_PRIMER.md](docs/CHI_PRIMER.md) — background on the CHI channels and
  flows the VIP models.
- [docs/SCOREBOARD_PLAN.md](docs/SCOREBOARD_PLAN.md) — the Checker-C / Checker-D
  scoreboard design.
- [docs/FUTURE_WORK.md](docs/FUTURE_WORK.md) — the backlog (optional breadth/depth; charter complete).

---

## Quick Start

### 1. Include the agent

```systemverilog
`include "vip_chi.svh"
```

This pulls in `bool_pkg`, the `vip_mem` packages, `vip_chi_types_pkg`,
`vip_chi_if`, the bindable SVA (`vip_chi_sva`, `vip_chi_snp_sva`), and
`vip_chi_agent_pkg`.

### 2. Parameterize

Every cooperating class takes a `vip_chi_cfg_t` (the static width/issue
envelope) **and** a flit-type set (the D- or E-shaped struct family):

```systemverilog
localparam vip_chi_cfg_t MY_CHI_CFG_C = '{
  issue           : VIP_CHI_ISSUE_D_E,
  NODE_ID_WIDTH_P : 11,
  ADDR_WIDTH_P    : 44,
  DATA_BYTES_P    : 16,
  DATACHECK_EN_P  : 1'b0,
  POISON_EN_P     : 1'b0,
  MPAM_EN_P       : 1'b0,
  PARITY_EN_P     : 1'b0
};

typedef vip_chi_types_d #(MY_CHI_CFG_C) my_chi_types_t;   // vip_chi_types_e for CHI-E
```

Use the same `(CFG, FLIT_TYPES_T)` pair for the interface, agent, monitor, and
items so the typedefs in [vip_chi_types_pkg.sv](vip_chi_types_pkg.sv)
(`addr_t`, `data_t`, `txn_id_t`, the flit structs) resolve consistently.

### 3. Instantiate the interface

```systemverilog
vip_chi_if #(
  .CFG_P        ( MY_CHI_CFG_C        ),
  .FLIT_TYPES_T ( my_chi_types_t      ),
  .ROLE_P       ( VIP_CHI_ROLE_RNI_E  )
) chi_vif (
  .clk          ( clk                 ),
  .rst_n        ( rst_n               )
);
```

The third parameter is the role and decides which driving clocking block the
interface emits — `rni_cb` for a requester, `snf_cb` for a completer, `hni_cb` /
`hnf_cb` for the proxies, or none for a passive monitor (`monitor_cb` is always
present).

### 4. Configure and create the agent

```systemverilog
vip_chi_cfg_agent cfg;
vip_chi_agent #(MY_CHI_CFG_C, my_chi_types_t, VIP_CHI_ROLE_RNI_E) rn_agent;

cfg = vip_chi_cfg_agent::type_id::create("cfg");
cfg.is_active = UVM_ACTIVE;
cfg.role      = VIP_CHI_ROLE_RNI_E;         // runtime role must match ROLE_P

uvm_config_db #(vip_chi_cfg_agent)::set(this, "rn_agent*", "cfg", cfg);
uvm_config_db #(virtual vip_chi_if #(MY_CHI_CFG_C, my_chi_types_t, VIP_CHI_ROLE_RNI_E))::set(
  this, "rn_agent*", "vif", chi_vif);

rn_agent = vip_chi_agent #(MY_CHI_CFG_C, my_chi_types_t, VIP_CHI_ROLE_RNI_E)
             ::type_id::create("rn_agent", this);
```

The role is a compile-time parameter on the agent **and** a runtime field on the
cfg — set both to the same value. The agent builds the monitor always and, when
active, the `ROLE_P`-matched driver plus a sequencer.

### 5. Run a sequence

```systemverilog
vip_chi_write_seq #(MY_CHI_CFG_C) wr_seq;
wr_seq = vip_chi_write_seq #(MY_CHI_CFG_C)::type_id::create("wr_seq");

wr_seq.set_requests(8);
wr_seq.set_initial_addr(44'h3000_8000);
wr_seq.set_size(4);                              // 2**4 = 16 B (one CHI-D beat)
wr_seq.set_data_type(VIP_CHI_DATA_COUNTER_E);
wr_seq.start(rn_agent.sequencer);
```

---

## Architecture

```text
vip_chi_agent #(CFG, FLIT_TYPES_T, ROLE_P)
├── vip_chi_monitor          — samples monitor_cb; req / rsp / dat / snp analysis ports
├── vip_chi_sequencer        — reset-aware sequencer (active agents only)
└── one driver, selected by ROLE_P:
    ├── vip_chi_driver_rni    — RN-I non-coherent requester
    ├── vip_chi_driver_snf    — SN-F memory completer (internal vip_mem)
    ├── vip_chi_driver_hni    — HN-I proxy relay
    ├── vip_chi_driver_rnf    — RN-F coherent requester (extends RN-I: cache + snoop responder)
    └── vip_chi_driver_hnf    — HN-F home node (directory + snoop origination)

Dedicated multi-port agents (own their rst_n watcher and per-port link loops):
  vip_chi_hni_agent  #(CFG, TYPES, N_RN_PORTS, N_SN_PORTS)   — HN-I proxy
  vip_chi_hnf_agent  #(CFG, TYPES, N_RNF_PORTS, N_SN_PORTS)  — coherent home node

Separately instantiable, env-level:
  vip_chi_coverage           — functional-coverage subscriber
  vip_chi_scoreboard         — Checker-C predictable-data + atomic-RMW scoreboard
  vip_chi_coherency_checker  — Checker-D self-derived ownership shadow
  vip_chi_perf_counters      — latency / throughput / retry / back-pressure counters
  vip_chi_sva / vip_chi_snp_sva — bindable link/protocol + snoop assertions
```

The agent picks the driver subclass in `build_phase` from the `ROLE_P`
parameter — `VIP_CHI_ROLE_RNI_E` → `vip_chi_driver_rni`, `SNF_E` →
`vip_chi_driver_snf`, `RNF_E` → `vip_chi_driver_rnf`, `HNF_E` →
`vip_chi_driver_hnf`, `MONITOR_E` → no driver (passive). For CHI-E, instantiate
[vip_chi_agent_e](vip_chi_agent_e.sv), which factory-overrides the driver and
monitor to the exact-CHI-E `*_e` variants; no other factory overrides are
required. The HN-I proxy is hosted by its own
[vip_chi_hni_agent](vip_chi_hni_agent.sv) (it needs both an RN-facing and an
SN-facing interface), and the coherent home node by
[vip_chi_hnf_agent](vip_chi_hnf_agent.sv).

### Files

#### Integration-facing

| File | Description |
|------|-------------|
| [vip_chi.svh](vip_chi.svh) | Single include entry point (packages + umbrella agent package) |
| [vip_chi_agent_pkg.sv](vip_chi_agent_pkg.sv) | Umbrella UVM package; includes the classes in compile order |
| [vip_chi_types_pkg.sv](vip_chi_types_pkg.sv) | Owned CHI types: flit structs, opcode/response enums, `vip_chi_cfg_t`, helpers (CHI-D + CHI-E) |
| [vip_chi_if.sv](vip_chi_if.sv) | Role-gated interface; `monitor_cb` always, `g_drv.<role>_cb` selected by `ROLE_P` |
| [vip_chi_item.sv](vip_chi_item.sv) | Transaction item; shared request/response object + raw-override flit views |
| [vip_chi_cfg_agent.sv](vip_chi_cfg_agent.sv) | Agent runtime cfg: role, active/passive, credits, split-write/ordered-DBID, DECERR/DERR, `mem_cfg`, coverage, timeouts, delays |
| [vip_chi_cfg_item.sv](vip_chi_cfg_item.sv) | Per-item randomization-knob config |
| [vip_chi_agent.sv](vip_chi_agent.sv) | Role-parameterized agent; monitor + `ROLE_P`-matched driver + sequencer; owns the `rst_n` watcher |
| [vip_chi_agent_e.sv](vip_chi_agent_e.sv) | CHI-E agent subclass (factory-overrides to the `*_e` driver/monitor) |
| [vip_chi_hni_agent.sv](vip_chi_hni_agent.sv) | Multi-port HN-I proxy agent (`N_RN_PORTS x N_SN_PORTS`) |
| [vip_chi_hnf_agent.sv](vip_chi_hnf_agent.sv) | Coherent home-node agent hosting the HN-F driver + directory |
| [vip_chi_hni_sam.sv](vip_chi_hni_sam.sv) | HN-I System Address Map: `[base:limit] -> SN-port` range table |
| [vip_chi_sequencer.sv](vip_chi_sequencer.sv) | `uvm_sequencer #(vip_chi_item)` with reset handling |
| [seq_lib/](seq_lib/) | Sequence library — base seq setter API + read/write/atomic/persist/pipelined/coherent/raw sequences |
| [vip_chi_sva.sv](vip_chi_sva.sv) | Bindable link/protocol assertions (link-before-traffic, credit rules, DBID-before-DAT, beat counts, TxnID uniqueness, timeouts) |
| [vip_chi_snp_sva.sv](vip_chi_snp_sva.sv) | Bindable SNP-channel assertions for the coherent path |
| [vip_chi_coverage.sv](vip_chi_coverage.sv) | Functional coverage over REQ/RSP/DAT opcode classes, sizes, errors, and coherent groups |
| [vip_chi_perf_counters.sv](vip_chi_perf_counters.sv) | Latency / throughput / retry / back-pressure counters |
| `yml/compile.yml` | Build manifest |

#### Internal implementation

| File | Description |
|------|-------------|
| [vip_chi_lcrd_mgr.sv](vip_chi_lcrd_mgr.sv) | Per-channel L-credit manager (`try_acquire_credit` / `return_credit`; starts at 0, learns from LCRDV pulses) |
| [vip_chi_driver_rni.sv](vip_chi_driver_rni.sv) | RN-I requester driver + the opt-in multi-outstanding pipeline |
| [vip_chi_driver_snf.sv](vip_chi_driver_snf.sv) | SN-F auto-responder over an internal `vip_mem` |
| [vip_chi_driver_hni.sv](vip_chi_driver_hni.sv) | HN-I multi-port pass-through proxy driver |
| [vip_chi_driver_rnf.sv](vip_chi_driver_rnf.sv) | RN-F coherent requester (extends RN-I; adds cache-state model + snoop responder) |
| [vip_chi_driver_hnf.sv](vip_chi_driver_hnf.sv) | HN-F home-node driver (directory, snoop origination, terminates to its own `vip_mem`) |
| [vip_chi_driver_rni_e.sv](vip_chi_driver_rni_e.sv) / [vip_chi_driver_snf_e.sv](vip_chi_driver_snf_e.sv) | Exact-CHI-E drivers (memory tagging, E-shaped REQ/DAT) |
| [vip_chi_monitor.sv](vip_chi_monitor.sv) / [vip_chi_monitor_e.sv](vip_chi_monitor_e.sv) | Passive monitors; publish REQ/RSP/DAT/SNP items (the `_e` variant adds CHI-E fields) |
| [vip_chi_scoreboard.sv](vip_chi_scoreboard.sv) | Checker-C predictable write→read + atomic-RMW predictor |
| [vip_chi_coherency_checker.sv](vip_chi_coherency_checker.sv) | Checker-D self-derived per-line ownership shadow |

---

## Agent Roles

### RN-I Requester

Drives REQ from sequence items, manages send/receive credits and link
activation, and collects the per-opcode completion flow (read `CompData`, write
`DBID`/`Comp`, atomic operand + `CompData`, persist, ordered `ReadReceipt`,
`CompAck`). Instantiated with `ROLE_P = VIP_CHI_ROLE_RNI_E`.

Supported non-coherent datapath: `ReadNoSnp`(`/Sep`), `WriteNoSnp`
Full/Ptl/Zero, atomics (store/load/swap/compare with SN-side RMW), persist CMOs
(`CleanSharedPersist`/`Sep`), ordered reads and ordered-write `DBIDRespOrd`,
`PrefetchTgt`, split vs combined write responses, the `RetryAck`/`PCrdGrant`
retry handshake (opt-in via `cfg.force_retry_count`), and a raw-flit override
path for negative testing.

**Multi-outstanding pipeline (opt-in).** With `cfg.multi_outstanding` the
point-to-point RN-I↔SN-F path overlaps transactions instead of running strictly
serial: the RN-I decouples issue from completion and the SN-F buffers inbound
REQs (capture + response threads) so pipelined requests are not dropped
mid-response. A single unified loop overlaps reads and writes together — a
driver can write a block and read it back for an end-to-end integrity check, or
run both directions concurrently (`cfg.observed_peak_mixed_inflight` records the
peak depth at which both were in flight). The `multi_outstanding_write` /
`multi_outstanding_mixed` flags are retained for back-compat but no longer
select distinct loops. Default off, so every serial test is byte-identical. The
retry handshake runs on the serial path only.

### SN-F Completer (Memory Responder)

Autonomous auto-responder backed by an internal [vip_mem](../vip_memory) store:
receives REQ, grants credits, performs reads / writes / atomic RMW / persist,
injects DECERR/DERR by address range, and drives `CompData`/RSP with
configurable split-write and ordered-DBID behaviour. Instantiated with
`ROLE_P = VIP_CHI_ROLE_SNF_E`.

There is no agent-level memory facade — the backing store is private to the
driver. Verify committed data with a read-back sequence and/or the scoreboard
(Checker-C predicts read data from observed writes).

### HN-I Proxy

An `N_RN_PORTS x N_SN_PORTS` home node that relays flits between RN-facing and
SN-facing links: QoS-weighted fan-in arbitration, address fan-out (a
configurable [vip_chi_hni_sam](vip_chi_hni_sam.sv) range table or an address
stride), and node-id completion routing. Pure flit relay — transaction- and
issue-agnostic, no TxnID remap, serial (one transaction at a time) by design.
Hosted by [vip_chi_hni_agent](vip_chi_hni_agent.sv), which fetches the RN- and
SN-facing vifs (plus an optional SAM and QoS `arb_window`) via `uvm_config_db`.

### Coherent RN-F / HN-F

The coherent slice models cache coherence over the SNP channel:

- **RN-F** ([vip_chi_driver_rnf.sv](vip_chi_driver_rnf.sv)) extends the RN-I
  driver, reusing its request/credit/link/retry machinery, and adds a per-line
  cache-state model and an autonomous snoop responder. Issues the coherent-REQ
  family (`ReadShared`/`ReadClean`/`ReadUnique`/`MakeReadUnique`/`ReadOnce`,
  `CleanUnique`, `WriteBack`/`Evict`, `CleanInvalid`/`MakeInvalid`,
  `WriteUnique`) and exclusives (LL/SC).
- **HN-F** ([vip_chi_driver_hnf.sv](vip_chi_driver_hnf.sv), hosted by
  [vip_chi_hnf_agent](vip_chi_hnf_agent.sv)) is a stateful home node with a
  directory: it terminates requests against its own `vip_mem`, originates snoops
  to sharers/owners, collects `SnpResp`(`Data`), merges dirty forwards, and
  completes with the granted state. DCT forwarding snoops and an optional
  downstream SN-F are modelled.

This is a **behavioural** coherence model scoped to the flows the example suite
exercises — not a full CHI interoperability model.

### Passive Monitor

Observes bus traffic without driving. Use `ROLE_P = VIP_CHI_ROLE_MONITOR_E` and
`cfg.is_active = UVM_PASSIVE`; only the monitor is created and all four analysis
ports remain available.

---

## Configuration

Per-agent runtime policy lives on
[vip_chi_cfg_agent](vip_chi_cfg_agent.sv):

| Group | Fields |
|-------|--------|
| Identity | `role`, `is_active` |
| Outstanding | `max_outstanding_read` / `_write` (16), `max_pcrd_budget` (8) |
| Pipeline (opt-in) | `multi_outstanding`, `multi_outstanding_write`, `multi_outstanding_mixed`; read back `observed_peak_outstanding`, `observed_peak_mixed_inflight` |
| Credits | `initial_{req,rsp,dat}_credits` (8), `{req,rsp,dat}_send_credit_cap` (64), `hold_dat_credit` |
| Completer policy | `split_write_rsp`, `ordered_dbid_resp`, `decerr_ranges[]`, `derr_ranges[]`, `mem_cfg` |
| Retry | `force_retry_count` |
| Coverage / delays | `coverage_enabled`, `link_act_delay_{min,max}`, per-channel `*_valid_delay_{min,max}` |

The static width/issue envelope is the `vip_chi_cfg_t CFG_P` type parameter
(issue, node-id/addr widths, data bytes, CHI-E feature enables). The HN-I proxy
additionally accepts an optional `vip_chi_hni_sam` and a QoS `arb_window` via
`uvm_config_db`. See [docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md)
§10 (config) and §12 (stimulus API) for the field-level reference.

---

## Transaction Item

[vip_chi_item](vip_chi_item.sv) is the shared object carried on the sequencer
and republished by the monitor, parameterized by `vip_chi_cfg_t`. It carries the
REQ / RSP / DAT / SNP flit fields (opcode, address, size, IDs, QoS, order,
exclusive, `ExpCompAck`, the data/BE payload arrays, and the CHI-E MTE
`Tag`/`TU` fields) plus a raw-override view for negative testing.

Randomization is shaped by [vip_chi_cfg_item](vip_chi_cfg_item.sv) and by the
sequence setters. Key legality constraints baked into the item include
size-aligned addressing, per-role/per-direction opcode pools, and the
combined-Size rule for `AtomicCompare` (Size denotes the combined compare+swap
span). The item can be randomized standalone or with inline constraints:

```systemverilog
req = vip_chi_item #(MY_CHI_CFG_C)::type_id::create("req");
req.randomize() with {
  opcode == req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_FULL_C);
  size   == 4;
};
```

---

## Sequence Library

```text
vip_chi_base_seq                     (setter API + generation loop)
├── vip_chi_read_seq / vip_chi_write_seq / vip_chi_write_zero_seq
├── vip_chi_atomic_seq  (+ store / load / compare variants)
├── vip_chi_persist_seq
├── vip_chi_pipelined_seq            (caller pre-builds items)
├── vip_chi_raw_seq                  (raw-flit injection)
└── vip_chi_coherent_base_seq
    ├── vip_chi_readshared / readclean / readunique / makereadunique_seq
    ├── vip_chi_cleaninvalid / makeinvalid_seq
    ├── vip_chi_writeback / evict / writeunique_seq
    └── vip_chi_excl_load / excl_store_seq

Helpers: vip_chi_seq_config, vip_chi_addr_iterator,
         vip_chi_seq_counter_iter, vip_chi_seq_payload_buffer
```

The [vip_chi_base_seq](seq_lib/vip_chi_base_seq.sv) setter API covers request
count and addressing (`set_requests`, `set_initial_addr`, `set_addr_list`,
`set_addr_stride`, `set_enforce_addr_alignment`), transfer shape (`set_size`,
`set_size_range`), payload (`set_data_type`, `set_data`, `set_be`,
`set_counter_value`), identity/attributes (`set_src_id`, `set_tgt_id`,
`set_qos`, `set_order`, `set_ns`, `set_mem_attr`), flow control (`set_allow_retry`,
`set_exp_comp_ack`, `set_excl`, `set_pcrd_type`, `set_sep_read`), and CHI-E MTE
(`set_tagop`, `set_tag`, `set_tu`). Enable response capture with
`set_get_response(1)` and collect with `get_responses()`; start with
`seq.start(<sequencer>)`.

---

## Common Recipes

Canonical patterns, each lifted from an example test in
[../examples/vip_chi_agent/tc](../examples/vip_chi_agent/tc).

### Write a counter pattern and read it back

The foundational integration check
([tc_chi_d_write_read_smoke](../examples/vip_chi_agent/sv/tc/tc_chi_d_write_read_smoke.sv)):

```systemverilog
wr_seq.set_requests(N);
wr_seq.set_initial_addr(44'h3000_8000);
wr_seq.set_size(4);
wr_seq.set_data_type(VIP_CHI_DATA_COUNTER_E);
wr_seq.set_counter_value(0);
wr_seq.start(v_sqr.rni_sequencer);

rd_seq.set_requests(N);
rd_seq.set_initial_addr(44'h3000_8000);
rd_seq.set_size(4);
rd_seq.set_get_response(1);
rd_seq.start(v_sqr.rni_sequencer);
// verify rd_seq.get_responses()[i].data against the counter
```

### Overlap transactions (multi-outstanding)

Set `cfg.multi_outstanding` on **both** the RN-I and SN-F cfgs, then confirm the
overlap actually happened via `observed_peak_mixed_inflight`. See
[tc_chi_d_multi_outstanding_concurrent](../examples/vip_chi_agent/sv/tc/tc_chi_d_multi_outstanding_concurrent.sv).

### Exercise the retry handshake

Set `cfg.force_retry_count` on the completer; the RN-I holds, consumes the
`PCrdGrant`, and re-issues. See
[tc_chi_d_retry](../examples/vip_chi_agent/sv/tc/tc_chi_d_retry.sv).

### Route through the HN-I proxy

Two RNs fan into two SNs by address. Hand the proxy a
[vip_chi_hni_sam](vip_chi_hni_sam.sv) for explicit `[base:limit] -> SN` ranges,
or rely on the address stride. See
[tc_chi_d_hni_xbar](../examples/vip_chi_agent/sv/tc/tc_chi_d_hni_xbar.sv),
[tc_chi_d_hni_fanin](../examples/vip_chi_agent/sv/tc/tc_chi_d_hni_fanin.sv), and
[tc_chi_d_hni_sam](../examples/vip_chi_agent/sv/tc/tc_chi_d_hni_sam.sv).

### Drive coherent traffic and observe snoops

An RN-F read that hits another RN-F's line originates a snoop from the HN-F. See
[tc_chi_coh_d_shared_read](../examples/vip_chi_agent/sv/tc/tc_chi_coh_d_shared_read.sv),
[tc_chi_coh_d_dirty_forward](../examples/vip_chi_agent/sv/tc/tc_chi_coh_d_dirty_forward.sv),
and [tc_chi_coh_d_writeback_evict](../examples/vip_chi_agent/sv/tc/tc_chi_coh_d_writeback_evict.sv).

### Inject error responses

Add address ranges to `cfg.decerr_ranges` / `cfg.derr_ranges` on the SN-F. See
[tc_chi_d_decerr_smoke](../examples/vip_chi_agent/sv/tc/tc_chi_d_decerr_smoke.sv) and
[tc_chi_d_derr_smoke](../examples/vip_chi_agent/sv/tc/tc_chi_d_derr_smoke.sv).

### Reset mid-traffic

Pulse `rst_n` while a storm runs; the agent watcher flushes queues, drops
objections, and resumes on release. See
[tc_chi_d_reset](../examples/vip_chi_agent/sv/tc/tc_chi_d_reset.sv) and
[tc_chi_coh_d_reset_mid_snoop](../examples/vip_chi_agent/sv/tc/tc_chi_coh_d_reset_mid_snoop.sv).

---

## Monitor Analysis Ports

[vip_chi_monitor](vip_chi_monitor.sv) publishes four
`uvm_analysis_port #(vip_chi_item)` streams for scoreboarding, coherency
checking, and coverage:

| Port | Fires on | Item contents |
|------|----------|---------------|
| `req_port` | REQ flit | Request flit (opcode, addr, size, IDs) |
| `rsp_port` | RSP flit | Response flit (`Comp` / `DBID` / `RetryAck` / …) |
| `dat_port` | DAT burst complete | Data flit(s) — the whole payload |
| `snp_port` | SNP flit | Snoop request/response (coherent path) |

```systemverilog
function void connect_phase(uvm_phase phase);
  agent.monitor.req_port.connect(my_subscriber.analysis_export);
  agent.monitor.dat_port.connect(my_scoreboard.dat_imp);
endfunction
```

The `_e` monitor republishes the CHI-E-only fields on the same ports.

---

## Checkers & Coverage

- **Scoreboard** ([vip_chi_scoreboard.sv](vip_chi_scoreboard.sv)) — Checker-C:
  predicts read data from wire-observed writes (predictable-only) and resolves
  atomic RMW results, flagging opcode/data/route mismatches and orphans.
- **Coherency checker** ([vip_chi_coherency_checker.sv](vip_chi_coherency_checker.sv))
  — Checker-D: a self-derived per-line ownership shadow (never the HN-F
  directory) whose core invariant is *never two Unique owners of one line*.
- **SVA** ([vip_chi_sva.sv](vip_chi_sva.sv),
  [vip_chi_snp_sva.sv](vip_chi_snp_sva.sv)) — bindable link/protocol and
  SNP-channel assertions: link-before-traffic, L-credit accounting,
  DBID-before-DAT, `Comp`-before-`CompAck`, beat counts, in-flight TxnID
  uniqueness, and completion timeouts.
- **Perf counters** ([vip_chi_perf_counters.sv](vip_chi_perf_counters.sv)) —
  per-requester latency (min/avg/max, read/write), throughput, retry count, and
  per-channel back-pressure cycles, off a reset-gated cycle counter.

Every always-on checker ships with a negative-control test that fails if the
check is vacuous (e.g.
[tc_chi_d_scoreboard_negctl](../examples/vip_chi_agent/sv/tc/tc_chi_d_scoreboard_negctl.sv)).

---

## Interface

[vip_chi_if](vip_chi_if.sv) carries the REQ/RSP/DAT/SNP flit, link-activation,
and L-credit signals plus role-gated clocking blocks:

| Block / Modport | Elaborated when | Used by |
|-----------------|-----------------|---------|
| `monitor_cb` (clocking) + `monitor` (modport) | always | Monitor — all inputs, `#1step` sampling |
| `g_drv.rni_cb` | `ROLE_P == RNI_E` **or** `RNF_E` (superset) | RN-I / RN-F driver |
| `g_drv.snf_cb` | `ROLE_P == SNF_E` | SN-F driver |
| `g_drv.hni_cb` | `ROLE_P == HNI_E` | HN-I proxy driver |
| `g_drv.hnf_cb` | `ROLE_P == HNF_E` | HN-F home-node driver |

Only the active role's driving clocking block is elaborated (inside a
`generate`), so a role reads a signal it does not drive without a VCS
multiple-driver error — mirroring the [vip_axi4_if](../vip_axi4_agent/vip_axi4_if.sv)
pattern. The SNP-channel signals are tied idle except on the HN-F (tx) and RN-F
(rx) sides. Drivers reach their clocking block via hierarchical reference
(`vif.g_drv.<role>_cb`) because VCS does not support modports inside generate
blocks.

---

## Reset Handling

Each active agent watches `rst_n` and automatically:

1. Calls `handle_reset()` on the monitor, driver, and sequencer on `negedge
   rst_n`.
2. Flushes internal queues, credit shadows, and pending transactions.
3. Stops active sequences and drops objections.
4. Resumes on `posedge rst_n` (drivers re-run link activation from zero
   credits).

Passive agents reset monitor state only. The multi-port HN-I and HN-F agents own
a single watcher that cascades reset across all of their per-port links (a snoop
spans two links, so the home node tears both down together).

---

## Example Testbench

[../examples/vip_chi](../examples/vip_chi) is a DUT-less structural top that
cross-wires the agents in several modes — integrated RN-I↔SN-F, RN-I loopback,
SN-F manual/auto, HN-I passthrough/fan-in/crossbar, a CHI-E sidecar, and the
coherent RN-F/HN-F topology — driven by 100+ testcases.

```text
examples/vip_chi_agent/
├── tb/
│   ├── vip_chi_tb_top.sv          — top: interface instances + per-mode cross-wiring
│   ├── vip_chi_tb_pkg.sv          — CHI_D / CHI_D_WIDE / CHI_E_WIDE cfg + type typedefs
│   ├── vip_chi_tb_config.sv       — shared harness config (reset pulse, CHI-E enable)
│   ├── vip_chi_tb_env.sv          — CHI-D env (RN-I + SN-F + 2x2 HN-I + coverage + scoreboard + perf)
│   ├── vip_chi_coherent_tb_env.sv — coherent RN-F/HN-F env
│   ├── vip_chi_e_tb_env.sv / vip_chi_e_proxy_tb_env.sv — CHI-E envs
│   ├── vip_chi_link_adapter.sv    — cross-wires two role interfaces into one CHI link
│   └── vip_chi_virtual_sequencer.sv — rni / snf / hrni0 / hrni1 sequencer handles
├── tc/                            — vip_chi_base_test + tc_chi_* / tc_chi_coh_* testcases
└── yml/                           — build configuration
```

### Building and running

Built with [FuseSoC](https://github.com/olofk/fusesoc) driving VCS (UVM-1.2).
Run from the repository root (a single recursive `--cores-root .` discovers the
agent, the example, and both submodule cores).

```sh
# One-time: fetch the submodule dependencies (vip_memory, vip_report_server)
git submodule update --init

# Build the example testbench (VCS elaborate + compile of the whole env)
fusesoc --cores-root . run --target default --tool vcs --setup --build \
        akerlund::vip_chi_agent_example:0

# Run one testcase on the built simulator (any tc_chi_* / tc_chi_coh_* name)
cd build/akerlund__vip_chi_agent_example_0/default-vcs
./akerlund__vip_chi_agent_example_0 +UVM_TESTNAME=tc_chi_d_write_read_smoke -l vcs.log
```

A passing run ends with `Test (<name>) PASS` and `UVM_ERROR: 0 / UVM_FATAL: 0`.
The full testcase catalog is in [testbench/sv/TEST_CASES.md](testbench/sv/TEST_CASES.md).
