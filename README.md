# vip_chi

Behavioral AMBA CHI verification IP with owned flit types, a role-parameterized
interface, and UVM link/protocol-layer logic. One agent class plays one of six
roles, selected at elaboration by a class parameter; the interface and item are
shared across roles and across the CHI-D and CHI-E issues.

- **RN-I** — non-coherent requester (reads, writes, atomics, persist CMOs,
  ordered traffic, the retry handshake).
- **SN-F** — memory-target completer backed by an internal
  [vip_mem](submodules/vip_memory) store, with DECERR/DERR injection and configurable
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
- [docs/FUTURE_WORK.md](docs/FUTURE_WORK.md) — the backlog (optional breadth/depth; charter complete).
- [testbench/README.md](testbench/README.md) — shared SV/Python testbench
  overview and run commands.
- [testbench/TEST_CASES.md](testbench/TEST_CASES.md) — shared testcase catalog.

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
items so the typedefs in [vip_chi_types_pkg.sv](sv/vip_chi_types_pkg.sv)
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
[vip_chi_agent_e](sv/vip_chi_agent_e.sv), which factory-overrides the driver and
monitor to the exact-CHI-E `*_e` variants; no other factory overrides are
required. The HN-I proxy is hosted by its own
[vip_chi_hni_agent](sv/vip_chi_hni_agent.sv) (it needs both an RN-facing and an
SN-facing interface), and the coherent home node by
[vip_chi_hnf_agent](sv/vip_chi_hnf_agent.sv).

### Files

#### Integration-facing

| File | Description |
|------|-------------|
| [vip_chi.svh](sv/vip_chi.svh) | Single include entry point (packages + umbrella agent package) |
| [vip_chi_agent_pkg.sv](sv/vip_chi_agent_pkg.sv) | Umbrella UVM package; includes the classes in compile order |
| [vip_chi_types_pkg.sv](sv/vip_chi_types_pkg.sv) | Owned CHI types: flit structs, opcode/response enums, `vip_chi_cfg_t`, helpers (CHI-D + CHI-E) |
| [vip_chi_if.sv](sv/vip_chi_if.sv) | Role-gated interface; `monitor_cb` always, `g_drv.<role>_cb` selected by `ROLE_P` |
| [vip_chi_item.sv](sv/vip_chi_item.sv) | Transaction item; shared request/response object + raw-override flit views |
| [vip_chi_cfg_agent.sv](sv/vip_chi_cfg_agent.sv) | Agent runtime cfg: role, active/passive, credits, split-write/ordered-DBID, DECERR/DERR, `mem_cfg`, coverage, timeouts, delays |
| [vip_chi_cfg_item.sv](sv/vip_chi_cfg_item.sv) | Per-item randomization-knob config |
| [vip_chi_agent.sv](sv/vip_chi_agent.sv) | Role-parameterized agent; monitor + `ROLE_P`-matched driver + sequencer; owns the `rst_n` watcher |
| [vip_chi_agent_e.sv](sv/vip_chi_agent_e.sv) | CHI-E agent subclass (factory-overrides to the `*_e` driver/monitor) |
| [vip_chi_hni_agent.sv](sv/vip_chi_hni_agent.sv) | Multi-port HN-I proxy agent (`N_RN_PORTS x N_SN_PORTS`) |
| [vip_chi_hnf_agent.sv](sv/vip_chi_hnf_agent.sv) | Coherent home-node agent hosting the HN-F driver + directory |
| [vip_chi_hni_sam.sv](sv/vip_chi_hni_sam.sv) | HN-I System Address Map: `[base:limit] -> SN-port` range table |
| [vip_chi_sequencer.sv](sv/vip_chi_sequencer.sv) | `uvm_sequencer #(vip_chi_item)` with reset handling |
| [seq_lib/](sv/seq_lib/) | Sequence library — base seq setter API + read/write/atomic/persist/pipelined/coherent/raw sequences |
| [vip_chi_sva.sv](sv/vip_chi_sva.sv) | Bindable link/protocol assertions (link-before-traffic, credit rules, DBID-before-DAT, beat counts, TxnID uniqueness, timeouts) |
| [vip_chi_snp_sva.sv](sv/vip_chi_snp_sva.sv) | Bindable SNP-channel assertions for the coherent path |
| [vip_chi_coverage.sv](sv/vip_chi_coverage.sv) | Functional coverage over REQ/RSP/DAT opcode classes, sizes, errors, and coherent groups |
| [vip_chi_perf_counters.sv](sv/vip_chi_perf_counters.sv) | Latency / throughput / retry / back-pressure counters |
| [vip_chi_agent.core](vip_chi_agent.core) | FuseSoC core — build manifest (deps + filesets) |

#### Internal implementation

| File | Description |
|------|-------------|
| [vip_chi_lcrd_mgr.sv](sv/vip_chi_lcrd_mgr.sv) | Per-channel L-credit manager (`try_acquire_credit` / `return_credit`; starts at 0, learns from LCRDV pulses) |
| [vip_chi_driver_rni.sv](sv/vip_chi_driver_rni.sv) | RN-I requester driver + the opt-in multi-outstanding pipeline |
| [vip_chi_driver_snf.sv](sv/vip_chi_driver_snf.sv) | SN-F auto-responder over an internal `vip_mem` |
| [vip_chi_driver_hni.sv](sv/vip_chi_driver_hni.sv) | HN-I multi-port pass-through proxy driver |
| [vip_chi_driver_rnf.sv](sv/vip_chi_driver_rnf.sv) | RN-F coherent requester (extends RN-I; adds cache-state model + snoop responder) |
| [vip_chi_driver_hnf.sv](sv/vip_chi_driver_hnf.sv) | HN-F home-node driver (directory, snoop origination, terminates to its own `vip_mem`) |
| [vip_chi_driver_rni_e.sv](sv/vip_chi_driver_rni_e.sv) / [vip_chi_driver_snf_e.sv](sv/vip_chi_driver_snf_e.sv) | Exact-CHI-E drivers (memory tagging, E-shaped REQ/DAT) |
| [vip_chi_monitor.sv](sv/vip_chi_monitor.sv) / [vip_chi_monitor_e.sv](sv/vip_chi_monitor_e.sv) | Passive monitors; publish REQ/RSP/DAT/SNP items (the `_e` variant adds CHI-E fields) |
| [vip_chi_scoreboard.sv](sv/vip_chi_scoreboard.sv) | Checker-C predictable write→read + atomic-RMW predictor |
| [vip_chi_coherency_checker.sv](sv/vip_chi_coherency_checker.sv) | Checker-D self-derived per-line ownership shadow |

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

Autonomous auto-responder backed by an internal [vip_mem](submodules/vip_memory) store:
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
configurable [vip_chi_hni_sam](sv/vip_chi_hni_sam.sv) range table or an address
stride), and node-id completion routing. Pure flit relay — transaction- and
issue-agnostic, no TxnID remap, serial (one transaction at a time) by design.
Hosted by [vip_chi_hni_agent](sv/vip_chi_hni_agent.sv), which fetches the RN- and
SN-facing vifs (plus an optional SAM and QoS `arb_window`) via `uvm_config_db`.

### Coherent RN-F / HN-F

The coherent slice models cache coherence over the SNP channel:

- **RN-F** ([vip_chi_driver_rnf.sv](sv/vip_chi_driver_rnf.sv)) extends the RN-I
  driver, reusing its request/credit/link/retry machinery, and adds a per-line
  cache-state model and an autonomous snoop responder. Issues the coherent-REQ
  family (`ReadShared`/`ReadClean`/`ReadUnique`/`MakeReadUnique`/`ReadOnce`,
  `CleanUnique`, `WriteBack`/`Evict`, `CleanInvalid`/`MakeInvalid`,
  `WriteUnique`) and exclusives (LL/SC).
- **HN-F** ([vip_chi_driver_hnf.sv](sv/vip_chi_driver_hnf.sv), hosted by
  [vip_chi_hnf_agent](sv/vip_chi_hnf_agent.sv)) is a stateful home node with a
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
[vip_chi_cfg_agent](sv/vip_chi_cfg_agent.sv):

Every field below exists under the same name in the Python port
([py/vip_chi_cfg_agent.py](py/vip_chi_cfg_agent.py)) unless the row says
otherwise.

| Group | Fields |
|-------|--------|
| Identity | `role`, `is_active` |
| Reporting | `{req,rsp,dat}_verbosity` (`UVM_HIGH`) — per-channel monitor/driver print level. **SV only**; the Python port prints through pyUVM's own logger. |
| Outstanding | `max_outstanding_read` / `_write` (16); `max_pcrd_budget` (8, 0 = unbounded) — requester bound on P-credits banked but unconsumed, summed over every `PCrdType`. A completer only grants a credit against a `RetryAck` it already sent, so exceeding the budget means it granted credits it never owed. |
| Pipeline (opt-in) | `multi_outstanding`, `multi_outstanding_write`, `multi_outstanding_mixed`; read back `observed_peak_outstanding`, `observed_peak_mixed_inflight` |
| Credits | `initial_{req,rsp,dat}_credits` (8), `{req,rsp,dat}_send_credit_cap` (64), `hold_dat_credit` |
| Completer policy | `split_write_rsp`, `ordered_dbid_resp`, `decerr_ranges[]`, `derr_ranges[]`, `mem_cfg` |
| Requester credit return | `return_unused_pcrd` (0) — hand back P-credits this requester banked but never used, with `PCrdReturn`. The specification requires unused credits to be returned in a timely manner: a held credit keeps a re-issue slot reserved at the completer forever. Default off because the return puts an extra REQ flit on the wire. |
| Completer persist form | `combined_persist_rsp` (0) — `CleanSharedPersistSep` has two legal completions: `Comp` (reached the Point of Coherency) then `Persist` (reached the Point of Persistence), or the two combined as one `CompPersist`. A requester must accept both, so the completer can produce both. Default off is the separated form, which carries the two milestones as distinguishable events. |
| Completer DAT order | `snf_reverse_dat_beats` (0) — SN-F returns read beats in descending `DataID`. CHI places a beat by its `DataID`, not by its position in the burst, so this is a legal ordering a monitor must reassemble correctly. |
| Completer DAT interleaving | `dat_interleave_depth` (1), `dat_interleave_policy` (`ROUND_ROBIN`), `dat_interleave_gather_cycles` (8) — how many in-flight reads the SN-F may take beats from before finishing any one of them, which of the eligible transfers the next beat comes from (`ROUND_ROBIN` or `RANDOM`), and how long the responder waits with one read queued for the rest of the group. A DAT flit is self-identifying — `TxnID` names the transaction, `DataID` the position — and CHI nowhere requires a transfer's beats to be contiguous on the channel. Depth 1 is one transfer at a time, exactly the wire this VIP has always driven; above 1 requires `multi_outstanding`, since the serial responder never holds two reads at once. A link carrying interleaved beats must also stand the burst-shape assertions down (`tb_cfg.dat_interleave_allowed`), which hold this VIP's own contiguous-emission convention rather than a CHI rule. |
| Sideband | `txsactive_extend_max_cycles` (0) — cycles the driver may keep `TXSACTIVE` asserted past the close of its outstanding window. `TXSACTIVE` says the node MAY have snoopable transactions outstanding, so holding it longer is always legal; 0 is the tightest legal behaviour. The matching `tb_cfg` field of the same name widens the bound the **checkers** allow, so a test exercising a speculative extension sets both — one drives, the other judges. |
| Latency bounds | `max_read_xact_latency` / `max_write_xact_latency` / `max_snp_xact_latency` (all 0 = unbounded) — per-transaction budgets in cycles on the monitor's reset-gated counter, checked at each transaction's completion milestone. 0 preserves behaviour: a bench that never stated a latency budget does not acquire one. The report names the transaction, its opcode, the bound and the measured value |
| Timestamps | `collect_beat_timestamps` (0) — also record the arrival cycle of every DAT beat in `item.t_dat_beats`. The transaction-level milestones (`t_req_issued`, `t_dbid`, `t_first_dat`, `t_last_dat`, `t_comp`, …) are always stamped and cost nothing per beat; this adds the per-beat detail, which costs an append on every beat of every transfer |
| Retry | `force_retry_count` |
| Timeouts | `compack_timeout_cycles` (10000) — SN-F gives up waiting for a `CompAck` after this many cycles |
| Negative testing | `allow_raw_override` (1) — master gate for the item's `raw_*` flit-injection view |
| Coverage | `coverage_enabled` |
| Delays | per-channel `{req,rsp,dat}_valid_delay_{enabled,min,max}` (all `enabled` = 0) — cycles the driver holds an assembled flit before asking for a credit and asserting `FLITV`. Drawn uniformly in `[min, max]`, per flit, which inside a DAT burst means per beat. L-credit returns are never delayed: they are link-layer bookkeeping, and holding one starves the peer's send side rather than shaping this one's. `link_act_delay_{enabled,min,max}` is **not wired** — it would delay the activation request, which `lasm_req_delay_by_state` already does and does better. Shape: `{req,rsp,dat}_valid_delay_gauss_enabled` (0) selects a truncated gaussian over the same window instead of a uniform draw, centred on `<chan>_valid_delay_mean` with spread `<chan>_valid_delay_stddev`. The CDF is cached and rebuilt automatically when the knobs move, so a mid-run retune needs no explicit call |
| Coherent — SNP credits | `initial_snp_credits` (8), `snp_send_credit_cap` (64), `hold_snp_credit` — the SNP-channel mirror of the DAT credit knobs; an RN-F advertises SNP receive credits so the HN-F may source snoops, and `hold_snp_credit` starves that pool at runtime |
| Coherent — HN-F policy | `coh_read_shared_state` (`SC`) / `coh_read_unique_state` (`UC`) — cache state granted per coherent-read class; `hnf_snoop_latency` (0) — cycles the HN-F waits before issuing a snoop; `exclusives_enabled` (1) — master enable for LL/SC monitor modeling; `hnf_enable_snoop_fwd` (0) — opt-in DCT (forwarding snoops) |
| Coherent — RN-F cache | `rnf_cache_max_lines` (0 = unbounded) — cache capacity in lines; beyond it a clean victim is silently evicted |
| Coherent — two-level memory | `hnf_downstream_en` (0), `hnf_downstream_snf_id` (0) — when set, the HN-F issues downstream `ReadNoSnp`/`WriteNoSnpFull` to a real SN-F instead of terminating against its own `vip_mem` |
| Coherent — hazard rule | `hazard_check_enable` (1) — the coherency checker reports a requester that has two requests outstanding to one cache line at a time. Scoped per node: two *different* requesters contending for a line is ordinary traffic, not a hazard. Clear it for a requester model that deliberately overlaps same-line requests |
| Negative controls | see the table below |

The static width/issue envelope is the `vip_chi_cfg_t CFG_P` type parameter
(issue, node-id/addr widths, data bytes, CHI-E feature enables). The HN-I proxy
additionally accepts an optional `vip_chi_hni_sam` and a QoS `arb_window` via
`uvm_config_db`. See [docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md)
§10 (config) and §12 (stimulus API) for the field-level reference.

### Negative-control knobs

Every always-on checker in this VIP ships a knob that deliberately breaks the
invariant it guards, plus a testcase that proves the check fires. That is how a
green regression is shown to be green because the design is correct rather than
because the checker is vacuous. **All default to 0.** Setting one outside its own
negative-control test produces a coherency failure that looks like a VIP bug, so
they are listed here rather than left to a grep.

| Knob | What it breaks | Proves |
|------|----------------|--------|
| `hnf_suppress_snoops` | HN-F grants coherent reads without snooping the other sharers, so two RN-Fs can end up duplicate Unique owners | the coherency checker's single-writer invariant |
| `hnf_corrupt_dirty_merge` | HN-F drops the dirty data a `SnpRespData` forwards and completes the requester from stale memory | the coherency checker's data-integrity check |
| `hnf_force_excl_success` | HN-F reports `ExclOkay` on every exclusive `CleanUnique`, even across an intervening conflict | the coherency checker's exclusive-access invariant |
| `hnf_corrupt_fwd_data` | HN-F corrupts forwarded data on the DCT relay leg, so the requester's `CompData` no longer matches what the snoopee forwarded | the forwarded-data integrity check |
| `hnf_downstream_corrupt_data` | HN-F XOR-inverts data relayed from a downstream SN-F fetch | the end-to-end (two-level memory) integrity check |
| `hnf_downstream_force_decerr` | HN-F treats a downstream SN-F fetch as a `DECERR` | the downstream error-propagation path |
| `snf_duplicate_dat_beat` | SN-F sends the final beat of a read burst carrying `DataID` 0 again, so one beat position is delivered twice and one never at all | the monitor's duplicate-`DataID` and missing-beat checks |
| `snf_reorder_ordered_service` | buffered SN-F serves one pair of queued ordered requests back to front, so its acknowledgements arrive out of request order while every transaction still completes correctly | the scoreboard's ordered-stream acknowledgement-order check (needs `multi_outstanding`) |
| `lasm_abort_activation` | requester raises `txlinkactivereq` and withdraws it again before the completer acknowledges, so the link leaves `ACTIVATE` without ever reaching `RUN` | the link-activation state machine's legal-transition check (requester roles only) |
| `snf_corrupt_tag` | exact-CHI-E completer returns a tag and a TagOp that are not the ones it was given | the MTE tag read-back and TagOp-replay checks |
| `flitpend_without_valid` | requester pulses `txreqflitpend`/`txrspflitpend`, and the home pulses `txsnpflitpend`, for one cycle with no flit behind them | the REQ, RSP and SNP FLITPEND rules (requester and home roles) |
| `lasm_reactivate_during_deactivate` | requester raises `txlinkactivereq` again while the link is still in `DEACTIVATE`, jumping it to `RUN` | the LASM legal-transition rule, under a race rather than a malformed sequence |
| `lasm_stall_activation_cycles` | completer withholds `txlinkactiveack` for N cycles, leaving the link in `ACTIVATE` with nothing in flight to time out | the link **activation** timeout (completer roles only) |
| `lasm_stall_deactivation_cycles` | completer withholds the *drop* of `txlinkactiveack` for N cycles after the drain has finished, leaving the link in `DEACTIVATE` | the link **deactivation** timeout (completer roles only) |

---

## Transaction Item

[vip_chi_item](sv/vip_chi_item.sv) is the shared object carried on the sequencer
and republished by the monitor, parameterized by `vip_chi_cfg_t`. It carries the
REQ / RSP / DAT / SNP flit fields (opcode, address, size, IDs, QoS, order,
exclusive, `ExpCompAck`, the data/BE payload arrays, and the CHI-E MTE
`Tag`/`TU` fields) plus a raw-override view for negative testing.

Randomization is shaped by [vip_chi_cfg_item](sv/vip_chi_cfg_item.sv) and by the
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
├── vip_chi_write_cmo_seq            (combined Write + CMO, E-only)
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

The [vip_chi_base_seq](sv/seq_lib/vip_chi_base_seq.sv) setter API covers request
count and addressing (`set_requests`, `set_initial_addr`, `set_addr_list`,
`set_addr_stride`, `set_enforce_addr_alignment`), transfer shape (`set_size`,
`set_size_range`), payload (`set_data_type`, `set_data`, `set_be`,
`set_counter_value`), identity/attributes (`set_src_id`, `set_tgt_id`,
`set_qos`, `set_order`, `set_ns`, `set_mem_attr`), flow control (`set_allow_retry`,
`set_exp_comp_ack`, `set_excl`, `set_pcrd_type`, `set_sep_read`), opcode-pool
opt-ins (`set_atomic_strict_size`, `set_combined_write_cmo_enable`), and CHI-E MTE
(`set_tagop`, `set_tag`, `set_tu`). Enable response capture with
`set_get_response(1)` and collect with `get_responses()`; start with
`seq.start(<sequencer>)`.

---

## Common Recipes

Canonical patterns, each lifted from an example test in
[testbench/sv/tc](testbench/sv/tc).

### Write a counter pattern and read it back

The foundational integration check
([tc_chi_d_write_read_smoke](testbench/sv/tc/tc_chi_d_write_read_smoke.sv)):

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
[tc_chi_d_multi_outstanding_concurrent](testbench/sv/tc/tc_chi_d_multi_outstanding_concurrent.sv).

### Exercise the retry handshake

Set `cfg.force_retry_count` on the completer; the RN-I holds, consumes the
`PCrdGrant`, and re-issues. See
[tc_chi_d_retry](testbench/sv/tc/tc_chi_d_retry.sv).

### Route through the HN-I proxy

Two RNs fan into two SNs by address. Hand the proxy a
[vip_chi_hni_sam](sv/vip_chi_hni_sam.sv) for explicit `[base:limit] -> SN` ranges,
or rely on the address stride. See
[tc_chi_d_hni_xbar](testbench/sv/tc/tc_chi_d_hni_xbar.sv),
[tc_chi_d_hni_fanin](testbench/sv/tc/tc_chi_d_hni_fanin.sv), and
[tc_chi_d_hni_sam](testbench/sv/tc/tc_chi_d_hni_sam.sv).

### Drive coherent traffic and observe snoops

An RN-F read that hits another RN-F's line originates a snoop from the HN-F. See
[tc_chi_coh_d_shared_read](testbench/sv/tc/tc_chi_coh_d_shared_read.sv),
[tc_chi_coh_d_dirty_forward](testbench/sv/tc/tc_chi_coh_d_dirty_forward.sv),
and [tc_chi_coh_d_writeback_evict](testbench/sv/tc/tc_chi_coh_d_writeback_evict.sv).

### Inject error responses

Add address ranges to `cfg.decerr_ranges` / `cfg.derr_ranges` on the SN-F. See
[tc_chi_d_decerr_smoke](testbench/sv/tc/tc_chi_d_decerr_smoke.sv) and
[tc_chi_d_derr_smoke](testbench/sv/tc/tc_chi_d_derr_smoke.sv).

### Reset mid-traffic

Pulse `rst_n` while a storm runs; the agent watcher flushes queues, drops
objections, and resumes on release. See
[tc_chi_d_reset](testbench/sv/tc/tc_chi_d_reset.sv) and
[tc_chi_coh_d_reset_mid_snoop](testbench/sv/tc/tc_chi_coh_d_reset_mid_snoop.sv).

---

## Monitor Analysis Ports

[vip_chi_monitor](sv/vip_chi_monitor.sv) publishes four
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

- **Scoreboard** ([vip_chi_scoreboard.sv](sv/vip_chi_scoreboard.sv)) — Checker-C:
  predicts read data from wire-observed writes (predictable-only) and resolves
  atomic RMW results, flagging opcode/data/route mismatches and orphans.
  Checker-E rides the same transaction table: requests carrying a non-zero
  `Order` field form one stream per (requester, `Order` value), and the
  completer must acknowledge them in the order it received them. The
  acknowledgement is the first inbound response — the `ReadReceipt` of an
  ordered read, the `DBIDResp`/`CompDBIDResp` of an ordered write — since that
  is the flit committing a position; the data burst after it may overlap freely.
  Gated by `tb_cfg.scoreboard_check_order` (default on).
- **Coherency checker** ([vip_chi_coherency_checker.sv](sv/vip_chi_coherency_checker.sv))
  — Checker-D: a self-derived per-line ownership shadow (never the HN-F
  directory) whose core invariant is *never two Unique owners of one line*. It
  also carries the same-line hazard rule: one requester must not have two
  requests outstanding to a single cache line, since the completer resolves them
  in whatever order it likes and nothing on the link could then say which result
  belongs to which. A line is claimed at the REQ and released at the completion
  response; the rule is per node, so two different requesters contending for a
  line is ordinary traffic. Gated by `cfg.hazard_check_enable` (default on).
- **SVA** ([vip_chi_sva.sv](sv/vip_chi_sva.sv),
  [vip_chi_snp_sva.sv](sv/vip_chi_snp_sva.sv)) — bindable link/protocol and
  SNP-channel assertions: link-before-traffic, L-credit accounting,
  DBID-before-DAT, `Comp`-before-`CompAck`, beat counts, in-flight TxnID
  uniqueness, and completion timeouts.
- **Link activation state machine** — the SVA tracks a `{LINKACTIVEREQ,
  LINKACTIVEACK}` state per link (`STOP` / `ACTIVATE` / `RUN` / `DEACTIVATE`)
  and requires every step to hold or advance one place around
  `STOP → ACTIVATE → RUN → DEACTIVATE → STOP`. One state machine per *link*,
  not per direction: the link adapter mirrors both sideband signals to both
  endpoints, so a link carries a single activation handshake that both ends
  observe. Flits are gated on `RUN` and L-credits on "not `STOP`" — credits
  legitimately flow from `ACTIVATE` onward, which is how the initial pool
  reaches the peer before the link is `RUN` at all. The state also carries the
  rule that no L-credit may still be outstanding once a link reaches `STOP`.
  Provoked by `cfg.lasm_abort_activation`; state and legal-edge tallies are
  reported per bind at end of test.
- **Graceful link deactivation** — `cfg.link_deactivate_request` walks the
  tear-down half of that cycle, which reset alone can never reach. The requester
  waits for its traffic to retire, stops advertising receive credits, drops
  `LINKACTIVEREQ`, and returns every L-credit it still holds as `LCrdReturn`
  flits (opcode 0 on every channel); the completer does the same and only then
  drops its acknowledge, so the link reaches `STOP` genuinely empty. Lowering the
  request brings it back up. `cfg.link_deactivate_done` is the driver's published
  "down and drained" flag — poll that rather than the sideband, which falls as
  soon as the handshake completes and says nothing about the drain.

  `DEACTIVATE` is the one state in which a sender may still transmit, and only
  L-credit returns: the flit-gating rules admit opcode 0 there and nothing else.
- **Peer-state-relative activation delay** — `cfg.lasm_req_delay_by_state[]`
  holds the requester's `LINKACTIVEREQ` off by a number of cycles chosen by the
  link state it observes at that moment (`STOP` / `DEACTIVATE` / `ACTIVATE` /
  `RUN`), all zero by default. Every other delay here is a uniform min/max per
  channel, which can only ever produce the same bring-up shifted in time; making
  the delay a function of the state the link is *already* in is what makes
  activation races reachable, and those races are exactly what the LASM
  transition rule exists to judge.
- **Link activation/deactivation timeouts** —
  `tb_cfg.link_activation_timeout_cycles` and
  `tb_cfg.link_deactivation_timeout_cycles` (0 = disabled, the default) bound how
  long the LASM may dwell in `ACTIVATE` or `DEACTIVATE`. They cover the one
  failure no other rule can see, because every cycle of it is legal: holding is
  always a legal LASM step, no flit goes out to violate a channel rule, and the
  transaction-completion timeout has nothing in flight to measure — a link stuck
  coming up has not yet carried a transaction, and one stuck going down has
  already retired them all. Each reports once, on the crossing. They live on the
  *testbench* config rather than the per-agent config because a stuck link is a
  property of the link, and the checker that judges it is bound to an interface
  rather than to one endpoint's driver.
- **Transaction recording** — `cfg.record_transactions` (default off) has the
  monitor bracket each transaction with `accept_tr` / `begin_tr` / `end_tr`, so a
  waveform viewer shows transaction streams rather than raw flits across four
  channels and two links. A retry re-issue is recorded as a CHILD of the attempt
  it replaces, not as a second unrelated transaction on the same TxnID. Off by
  default because recording costs time and database space on every transaction
  of every run, and is only read when a specific flow is being debugged.

  Two limits, both stated rather than discovered: a snoop is its own stream and
  not a child of the request that caused it, because the two are seen by
  different monitor instances on different ports and neither holds the other's
  handle (the TxnID appears on both, so they still correlate by eye); and the
  Python port records the lifecycle but produces no stream, because pyUVM 4.0.1's
  recording backend is a stub — `begin_tr` returns handle 0 and the `do_*_tr`
  hooks are empty.
- **Perf counters** ([vip_chi_perf_counters.sv](sv/vip_chi_perf_counters.sv)) —
  per-requester latency (min/avg/max, read/write), throughput, retry count, and
  per-channel back-pressure cycles, off a reset-gated cycle counter.

Every always-on checker ships with a negative-control test that fails if the
check is vacuous (e.g.
[tc_chi_d_scoreboard_negctl](testbench/sv/tc/tc_chi_d_scoreboard_negctl.sv)).

### Per-check identity, enable and statistics

Every protocol rule has a stable identity (`vip_chi_check_id_t` in SV,
`CHECK_IDS` in Python — the same 54 names, in the same order), a severity, and
pass/fail counters. The scoreboard's rules carry the same identity in a second
registry of 13 (`vip_chi_sb_check_id_t` / `CHECK_IDS_SB`, all named `CHI_SB_*`);
they are a separate enum because the SVA IDs size four arrays inside *every*
`vip_chi_if` instance while a scoreboard rule is judged once per component, but
they share the export schema, so one aggregation reads both. Two things follow
that did not hold before:

* **An assertion failure fails the run.** The SV checkers report through plain
  `$error`, which raises no UVM error, sets no exit status, and is not read by
  `scripts/sv_regression.sh` — so every SV protocol assertion used to print into
  a log nothing consumed. The tallies are published on `vip_chi_if` and the env
  folds them into the verdict at `report_phase`. `vip_chi_sva` and `vip_chi_if`
  stay UVM-free, so they remain bindable in a non-UVM bench.
* **A rule that never RAN is distinguishable from one that held.** Zero passes
  and zero fails means the rule was never evaluated, which a clean log otherwise
  looks exactly like. This is why the scoreboard rules needed *pass* counts:
  every scoreboard check here counted only its failures, so a check that had
  stopped evaluating produced the same output as one that always held.

Addressing one check:

| | SV | Python |
|---|---|---|
| Disable (no reports, no counts) | `+vip_chi_disable_check=CHI_LCRD_UNDERFLOW` | `VIP_CHI_DISABLE_CHECK=CHI_LCRD_UNDERFLOW` |
| Demote to warning (still counted) | `+vip_chi_warn_check=<ID>[,<ID>]` | `VIP_CHI_WARN_CHECK=<ID>[,<ID>]` |
| Silence but keep counting | `vif.check_severity[<ID>] = VIP_CHI_CHK_SEV_OFF_E` | `checker.expect_failure("<ID>")` |
| Declare a provoked SCOREBOARD rule | `scoreboard.expect_failure(<ID>)` | `scoreboard.expect_failure("<ID>")` |

An unknown name is an error, not a shrug: the whole value of naming checks is
being able to address one, and a silently-dropped typo leaves you believing a
check is off when it is still firing.

`OFF` still **evaluates and counts** — it only suppresses the report — which is
what a negative control needs to prove its rule fires. Disabling stops the
counting too, so a disabled rule shows as *not exercised* rather than as quietly
holding.

On the scoreboard, `expect_failure` declares intent for the export and does
**not** silence the report. The difference is deliberate: the scoreboard's report
*is* its verdict — it raises a UVM error, and its negative controls assert
through a report catcher that the message was actually emitted — so suppressing
it would delete the evidence those tests depend on. A scoreboard rule stands down
only with the knob that owns it (`scoreboard_check_data`, `scoreboard_check_order`,
or multi-SN routing), and the export records that as *disabled*, which does not
gate.

### Reading the vacuity report

Each run prints, per bind, one line per rule it never evaluated:

```
VIP_CHI CHECK VACUITY: bind=rni_sva not_exercised=12 of=52
VIP_CHI CHECK NOT EXERCISED: bind=rni_sva rule=CHI_REQ_IDLE_IN_RESET
VIP_CHI SB CHECK VACUITY: not_exercised=3 of=12
  SB CHECK NOT EXERCISED  CHI_SB_ATOMIC_RETURN_MATCHES
```

One line per rule, deliberately: the report server wraps at a fixed column, so a
single line carrying a list loses everything past the wrap — and a sweep built on
it silently reports on a fraction of the data.

A single run cannot tell you which check does nothing *anywhere*; only the union
over a regression can. Both flows append per-rule tallies to a CSV, and
[scripts/check_vacuity.py](scripts/check_vacuity.py) aggregates them:

```bash
# SV: scripts/sv_regression.sh does this and appends the report to summary.txt
./simv +UVM_TESTNAME=<tc> +vip_chi_check_csv=tallies.csv

# Python
VIP_CHI_CHECK_CSV=tallies.csv python3 testbench/py/scripts/run.py --all

python3 scripts/check_vacuity.py tallies.csv

# Label the sources to also find rules only one port ever evaluated
python3 scripts/check_vacuity.py sv=sv_tallies.csv py=py_tallies.csv
```

It reports `NEVER` (zero passes and zero fails in every run), `THIN` (exercised
by one or two runs — alive, but one deleted testcase from becoming `NEVER`),
`FAILING`, and `PROVOKED` (failures a negative control asked for, which are
evidence the rule works rather than a bug). It exits non-zero on `NEVER`.

Aggregation is on `(bind, check)`, not on the check name alone. A rule is a
property of an interface: the same name is bound to more than a dozen of them
and can be exercised on one and dead on the rest, so a join on the name reports
the union and a checker that never elaborated reads as a clean link. `DEAD ON A
BIND` lists the rules an interface is checking in name only. That list is not
gated by default because it is untriaged — some of it is structural, since a
request and its completion are not both visible on one coherent link.

`--fail-on-bind-gaps` turns that list into an error, and takes a comma-separated
list of bind globs so a bind-set can start gating the day its own triage lands
rather than waiting for the last one:

```sh
python3 scripts/check_vacuity.py sv=… py=… --fail-on-bind-gaps=scoreboard
python3 scripts/check_vacuity.py sv=… py=… --fail-on-bind-gaps='rni_*,snf_*'
python3 scripts/check_vacuity.py sv=… py=… --fail-on-bind-gaps   # every bind
```

Binds selected this way are marked `[gating]` in the report. A glob that matches
no bind is an error (exit 2) rather than a silent pass, because a typo otherwise
reads exactly like a bind-set with nothing left to fix. Quote globs so the shell
does not expand them, and prefer the `--fail-on-bind-gaps=…` form: the bare flag
takes an optional value, so a glob written after a space would be read as one of
the CSV arguments.

`EVIDENCE FROM ONE SOURCE ONLY` needs the `LABEL=path` form above, and is
suppressed without it: with a single CSV the question has no meaning. The four
X/Z rules are excluded, because Verilator is 2-state and cannot evaluate them by
construction — they are already reported as absent by design.

Both of those sections compare the inputs against each other, so a CSV left over
from an earlier sitting reads as a rule the other port never exercised. Nothing
in the file records which revision produced it, so the report warns when its
inputs were written more than an hour apart and names the older one. It is a
warning and not an error: comparing an archived sweep against a fresh one is a
reasonable thing to do, and the report should say what it is comparing rather
than refuse to.

### Checking the encodings against the specification

Every opcode constant here is a transcription of a number out of Arm IHI 0050,
and a wrong transcription is invisible from inside: the VIP drives a
legal-looking flit and the testbench agrees with itself, because both ends read
the same wrong constant. `docs/FUTURE_WORK.md` records what one such mistake
already cost.

[scripts/check_opcodes.py](scripts/check_opcodes.py) removes the guesswork:

```bash
# The two ports against each other — no specification needed
python3 scripts/check_opcodes.py

# …and both against the document
python3 scripts/check_opcodes.py --spec-e ~/chi/IHI0050E.md --spec-d ~/chi/IHI0050D.md
```

It reads the REQ/RSP/SNP/DAT opcode tables out of a **markdown conversion** of
the spec and reports `PORT` (the SV and Python packages disagree), `MISMATCH`
(our value differs from the spec's), `UNKNOWN` (a name the spec's tables do not
have), and `ISSUE` (a CHI-D randomization pool offering an Issue-E-only opcode —
the mistake `FUTURE_WORK` describes, now caught automatically). `--show-unimplemented`
lists the opcode space this VIP does not yet cover, which is what the CHI-E
breadth tasks are picked from.

**The Arm document is not in this repository and must not be** — only our own
constants live here. With no conversion available the script checks the two
ports against each other and says plainly what went unchecked: an absent
authority is not the same as a disagreement with one.

---

## Interface

[vip_chi_if](sv/vip_chi_if.sv) carries the REQ/RSP/DAT/SNP flit, link-activation,
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
multiple-driver error — mirroring the vip_axi4 interface pattern. The SNP-channel
signals are tied idle except on the HN-F (tx) and RN-F
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

## Example Testbenches

[testbench](testbench) contains the DUT-less example regressions. There are two
flows for the same testcase catalog:

- [testbench/sv](testbench/sv) is the SystemVerilog UVM flow, built with
  FuseSoC and VCS.
- [testbench/py](testbench/py) is the pyUVM/cocotb flow, built with FuseSoC and
  Verilator.

Both flows use one shared structural harness and cover integrated RN-I/SN-F,
HN-I proxy, CHI-E, and coherent RN-F/HN-F scenarios. See
[testbench/README.md](testbench/README.md) for run commands and
[testbench/TEST_CASES.md](testbench/TEST_CASES.md) for the testcase catalog.
