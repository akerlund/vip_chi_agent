# `vip_chi` — Implementation Plan

A fully behavioral CHI protocol VIP for ZeroPoint testbenches. It provides
both **RN-F / RN-I manager** stimulus and **SN-F / HN-I subordinate responder**
roles over a self-contained CHI interface. The first implementation target is
the memory-target subordinate path (SN-F, non-coherent Read/Write) because that
is what `vip_mc`'s CHI front-end requires.

```text
[vip_chi agent (RN-I/RN-F)] ── CHI ── [DUT / vip_mc CHI port]
                                              │
[DUT] ── CHI ── [vip_chi agent (SN-F)]  ── vip_mem
```

**Goal.** A lightweight, self-contained CHI agent suitable for directed and
constrained-random verification of devices that expose or consume a CHI
interface. As of **Tier C** the VIP **also models a full coherent subsystem**: a
cache-holding **RN-F** requester, an **HN-F** home with a directory + snoop
origination + terminating memory, autonomous snoop responders (clean and
dirty-forward), and a self-derived **system coherency checker** (Checker D:
single-writer + data-integrity invariants, negative-control-proven) with
coherent functional coverage — stood up on both the CHI-D and CHI-E configs.
This supersedes the VIP's original non-goal. "Enough protocol fidelity to
generate and accept CHI traffic correctly" remains the guiding principle for the
non-coherent datapath.

**Relation to `vip_mc_chi_types_pkg`.** `vip_chi` owns its **own** parallel type
layer (`vip_chi_types_pkg`). When a TB needs the `vip_mc` CHI front-end driven by
`vip_chi`, the two are bridged at TB level via a thin connector;
`vip_chi_types_pkg` does **not** import `vip_mc_chi_types_pkg`.

This revision **commits** the previously-deferred D/E feature set (atomics,
memory tagging, persistence CMOs, ordered DBID response, HN-I) and a complete
**signal-drivability API** as required scope — see §1.3 and §12.

---

## Status (2026-07-12)

**Build is GREEN; regression is 46/46.** FuseSoC/VCS builds both CFG
specializations (CHI-D + CHI-E wide) and runs the full `tc_chi_*` regression
(FuseSoC build + a loop over the `tc_chi_*` catalog) with
`UVM_ERROR: 0 / UVM_FATAL: 0` on every test. The
committed Tier-B scope (§1.3) is **complete**: RN-I initiator, SN-F responder,
HN-I pass-through proxy (single + multi-port fan-in / crossbar / QoS),
signal-drivability + raw injection, atomics, ordered reads/writes, CHI-E memory
tagging, persistence CMOs, serial retry, and an opt-in multi-outstanding
read/write/mixed pipeline are all shipped and tested. A standalone
`vip_chi_scoreboard` (§21) now provides always-on RN-I↔SN-F transaction checking
across the suite. Remaining work is the deferred items in §1.3 Tier C and the
open interop-fidelity findings tracked in §22.

Implemented and passing (baseline, still current):

- Shared CHI-D / CHI-E type layer, interface, item, sequence library, agent
  package, and shared example top/env.
- Active RN-I initiator and active SN-F responder for non-coherent traffic,
  including autonomous SN-F memory-backed read/write completion.
- Distinct `Resp` (cache-state) vs `RespErr`; `PrefetchTgt` as a no-completion
  hint; DECERR/DERR; DBID-first write data; split write-response; ordered
  `CompAck` timing.
- Agent-owned reset (`vip_chi_agent::run_phase` is the single `rst_n` watcher;
  forks driver/monitor after release; `disable fork` + `handle_reset()` on
  assertion).
- Counted L-credits (`vip_chi_lcrd_mgr` + per-driver `credit_loop()`), with
  initial receive credits now advertised on the wire as `LCRDV` pulses after
  link activation instead of pre-seeding local availability.
- First-cut `vip_chi_coverage` and `vip_chi_sva`; item `do_copy`/`do_compare`/
  `convert2string`; base-seq attribute stamping pinned through `randomize()`.
- Explicit harness-mode selection via `chi_tb_config.tb_mode`, owned by
  `chi_base_test` and consumed by `chi_tb_top` (RN-I loopback /
  manual SN-F / autonomous SN-F), so the top stays structural and does not
  parse `+UVM_TESTNAME`.

Remaining work is **expansion** (Tier B, §1.3) and the unimplemented feature/
verification items called out below.

Update (2026-06-24, later): a first P4 probe that replaced the free-running
`TxnID` counter with a **`2**txn_id_width`-indexed** in-flight bitmap, keeping
serial control flow, regressed `timeout 60s ... vcs -buk` in `testbench/sv`
to exit `124` during VCS elaboration/codegen. Reverting it restored exit `0`.

Update (2026-07-05): **P4 read pipeline shipped.** The elaboration landmine was
the `2**txn_id_width` table; the fix sizes all in-flight bookkeeping by the
*outstanding count* (`cfg.max_outstanding_*`, small) — plain `outstanding_ids[$]`
/`outstanding_reqs[$]` pools the allocator scans linearly. Elaboration stays
~11s. Multi-outstanding is opt-in via `cfg.multi_outstanding` (default 0 keeps
the strict serial path every existing test relies on): the RN-I forks read
issue from completion and the SN-F buffers inbound REQs (capture + response
threads) so pipelined requests are not dropped mid-response; `set_pipelined_send`
launches all requests before draining responses. `tc_chi_multi_outstanding`
drives 6 reads to a peak of 6 in flight and self-checks each address-derived
payload.

Update (2026-07-05, later): **P4 write pipeline shipped** (opt-in via
`cfg.multi_outstanding` + `cfg.multi_outstanding_write`). A write requester must
drive WriteData on TX mid-transaction, so unlike reads the split is asymmetric:
one TX thread owns REQ issue + WriteData + retire + the sequencer, a second only
watches inbound RSP and records each `CompDBIDResp` grant — a single TX writer,
so the threads never fight over the bus. The SN-F is unchanged: its buffered
capture thread keeps returning REQ credit while a response is mid-flight, which
is what lets the RN-I stack up write REQs. First cut overlaps plain
`WriteNoSnpFull` (order NONE, no CompAck, combined `CompDBIDResp`) only;
`tc_chi_multi_outstanding_write` drives 6 writes to a peak of 6 in flight.
Still serial (owed): atomics, persist; and `handle_retry`.
(Partial, split-response, ExpCompAck and ordered writes were added later — see
the 2026-07-07 updates below.)

Update (2026-07-06): **P4 mixed read+write pipeline shipped** (opt-in via
`cfg.multi_outstanding` + `cfg.multi_outstanding_mixed`, which takes precedence
over the write flag). One additive loop overlaps plain `ReadNoSnp` AND
`WriteNoSnpFull` on a single driver instance — a shared TX/sequencer thread plus
two completion monitors (reads on inbound DAT, writes on inbound RSP, so they
never contend). The read-only and write-only loops are left untouched, so their
shipped tests keep exact behavior. `tc_chi_multi_outstanding_mixed` pipelines 6
writes then 6 reads to the same addresses and checks each read-back against the
captured write payload (holds for any data and any response order). **Verified
in simulation** (build clean, test Passed, full night regression green).

Update (2026-07-07): **concurrent overlap proven.** `tc_chi_multi_outstanding_mixed`
is phased (writes then reads), so it never has a read and a write in flight at the
same instant. Added `cfg.observed_peak_mixed_inflight` (the mixed loop records the
peak in-flight depth sampled while at least one read AND one write coexist) and
`tc_chi_multi_outstanding_concurrent`, which seeds a read region then forks 6 reads
of that region with 6 writes to a **disjoint** region on one sequencer — proving
true bidirectional overlap (peak mixed in-flight = 6) with the seeded read-back
intact under the opposite-direction traffic. Regression now 37/37.

Update (2026-07-07, later): **loops collapsed.** The read-only and write-only
pipelines (`seq_loop_pipelined`, `seq_loop_write_pipelined` and their helpers)
were deleted; `cfg.multi_outstanding` now always runs the single
`seq_loop_mixed_pipelined`, which serves read-only, write-only and mixed traffic
alike (a single-direction sequence simply never pushes the other kind). The
`multi_outstanding_write` / `multi_outstanding_mixed` flags are retained for
back-compat but no longer select distinct loops. Regression still 37/37.

Update (2026-07-07, later still): **partial writes overlap.** `WriteNoSnpPtl`
completes exactly like `WriteNoSnpFull` (combined `CompDBIDResp` grant + a
WriteData burst) — only the data flit differs, carrying per-byte BE, which
`drive_dat` already emits. So `is_plain_write` was relaxed to accept both full and
partial; no completion-monitor change. `pipelined_body` was also taught to bound
itself by the payload buffer in CUSTOM data mode (custom BE forces CUSTOM mode,
where `set_requests` pins the count to UNLIMITED), so pipelined + custom-BE now
compose. `tc_chi_multi_outstanding_partial` pipelines 6 `WriteNoSnpPtl` writes with
distinct data/BE, then reads back and checks the masked merge image survived the
overlapped bursts. Regression now 38/38.

Update (2026-07-07, later still): **split write responses overlap.** With the
SN-F's `cfg.split_write_rsp`, a write is granted a `DBIDResp` (buffer) and later
completed by a deferred `Comp`, rather than a combined `CompDBIDResp`. `mixed_rsp_proc`
now handles all three: CompDBIDResp sets grant+completion; DBIDResp sets grant only
(the WriteData burst may go once granted); Comp sets completion. The write retires
only once data is sent AND completion is seen, so either flit ordering works, and
the later Comp stamps the handed-back opcode. The buffered SN-F already emits split
responses (its `req_response_loop` calls the same `drive_auto_write_comp`).
`tc_chi_multi_outstanding_split` pipelines 6 split writes (peak 6), confirms each
hands back `Comp`, and reads them back. Regression now 39/39.

Update (2026-07-07, later still): **ExpCompAck writes overlap.** An `ExpCompAck`
write carries an `NCBWrDataCompAck` burst and must be acknowledged with a `CompAck`
RSP from the RN-I after completion. The TX thread (sole TX owner) drives it: a new
pipeline step, after WriteData and completion, sends `CompAck` for the first
completed-but-unacked write, and the write only retires once its CompAck is sent.
Because `stamp_rsp_flit_on_req` overwrites the item's src/tgt with the swapped
response IDs, the original REQ src/tgt are captured in `mx_ctx` at issue for the
CompAck flit (the SN-F validates CompAck src/tgt + txn_id and times out otherwise).
`tc_chi_multi_outstanding_compack` pipelines 6 ExpCompAck writes (peak 6); the SN-F
accepting every CompAck without timeout is the proof. Regression now 40/40.

Update (2026-07-07, later still): **ordered writes overlap.** In this VIP an
ordered write is an `ExpCompAck` write carrying `Order != NONE`; the ordering point
(CompAck) is already pipelined, so the change is just relaxing the `order == NONE`
gate in `is_plain_write` and accepting `DBIDRespOrd` (the CHI-E ordered split grant)
like `DBIDResp` in `mixed_rsp_proc` — needed so the relaxed gate stays sound under
split+ordered+E, though `DBIDRespOrd` itself only fires in the CHI-E harness.
`tc_chi_multi_outstanding_ordered` pipelines 6 `Order=Request_Order` ExpCompAck
writes (peak 6) and read-checks them. Regression now 41/41. (Design-plan item 1
below is done; items 2–5 remain.)

Update (2026-07-08): **ordered reads overlap.** An ordered read (`Order != NONE`)
receives a `ReadReceipt` on RSP ahead of its `CompData` on DAT. The `order == NONE`
gate in `is_plain_read` is relaxed; `mixed_rsp_proc`, which previously assumed every
RSP was a write completion, now consumes a `ReadReceipt` that matches a READ ctx
(sets `receipt_seen`) instead of fataling; and an ordered read only retires once
both its receipt and CompData are in. `tc_chi_multi_outstanding_ordered_read` seeds
a region then pipelines 6 ordered reads (peak 6) and read-checks them. Regression
now 42/42. (Design-plan item 2 done; items 3–5 remain.)

Update (2026-07-09): **atomics overlap.** Atomics join the pipeline as a third
kind, `TXN_KIND_ATOMIC`. They issue write-like — a `DBIDResp` grant on RSP, then
the operand DAT burst driven by the same step (2) that sends WriteData — but a
non-store atomic then completes read-like: the SN-F returns the pre-op value on
`CompData`, so `find_mixed_read_by_completion` now also matches a returning atomic
and `retire_mixed` gates it on `data_sent && read_done`. A store atomic completes
on RSP (combined `CompDBIDResp`, or split `DBIDResp`+`Comp`) and retires on
`data_sent && comp_seen`, i.e. the plain-write path. The RSP monitor's write
branch already handled all the grant/Comp cases, and the SN-F buffered path
already dispatched atomics to `drive_auto_atomic_completion`, so the change was
confined to the RN-I pipeline. `tc_chi_multi_outstanding_atomic` seeds 6 granules
then pipelines 6 returning `AtomicLoad0` (ADD) atomics (peak 6), checks each
returned its pre-op value on `CompData`, and reads back seed+operand. Regression
now 43/43. (Design-plan item 3 done; items 4–5 remain.)

Update (2026-07-09, later): **persist overlaps.** Persist CMOs join as a fourth
kind, `TXN_KIND_PERSIST` -- no data, no DBID grant, RSP-only completion. A new
persist branch in `mixed_rsp_proc` consumes the completion (a single `Comp` for
`CleanSharedPersist`, or an intermediate `Persist` stepped over then a final
`CompPersist` for the CHI-E `CleanSharedPersistSep`) and `retire_mixed` retires on
`comp_seen`. `tc_chi_multi_outstanding_persist` (CHI-D, Comp) and
`tc_chi_multi_outstanding_persist_sep` (CHI-E, Persist+CompPersist) each pipeline 6
CMOs to peak 6 -- the latter is the first pipelined test to run on the CHI-E
harness. Regression now 45/45. (Design-plan item 4 done; only item 5 handle_retry
remains.)

Update (2026-07-09, later still): **serial retry shipped.** The RN-I now processes
`RetryAck`/`PCrdGrant`: an SN-F armed with `cfg.force_retry_count` bounces a
retryable REQ with `RetryAck` + `PCrdGrant`, and the RN-I's new `handle_retry`
(after `drive_req`) consumes the RetryAck, waits the credit grant, and re-issues
the request (`AllowRetry=0`, granted `PCrdType`, original TxnID). Opt-in and a
no-op unless `allow_retry` is set, so all other tests are byte-identical. The bound
`vip_chi_sva` gained a rule that a `RetryAck` retires the in-flight TxnID so the
re-issue is not a reuse violation. `tc_chi_retry` bounces a write, re-issues it to
`CompDBIDResp`, and confirms the data committed. Regression now 46/46. (Design-plan
item 5's serial cut done; overlapping retry in the pipeline is the only remainder,
and it carries the least value.)

Update (2026-07-10): **standalone scoreboard shipped.** `vip_chi_scoreboard`
(§21) is added to both the base and CHI-E envs, connected in parallel to the
existing monitor analysis ports (zero per-test churn). It runs three checkers on
one TxnID-keyed transaction table — (A) per-txn lifecycle/completion contract,
(B) cross-agent request fidelity / relayed-exactly-once, (C) an independent
predictable-only write→read data check — and is gated per-test by
`tb_cfg.scoreboard_enable` / `scoreboard_check_data`. Full night regression is
46/46 green with the scoreboard active on the 40 traffic-driving tests (silent
on all); a negative control confirms it reports a dropped completion as
incomplete.

Update (2026-07-12): **plan reconciled to the shipped tree; safe per-test check
thinning.** This revision folds the outcomes of two standing reviews directly
into the plan (both review docs are retired): a plan-vs-code reconciliation
(its action items were done, so the stale §3/§8/§13/§15/§16/§19 claims are
corrected here) and a correctness / interop review (its open findings are now
recorded inline in §22). The
§19 test list is regenerated from the tree (46 tests). Two full-width
write→read smokes (`tc_chi_write_read_smoke`, `tc_chi_multi_outstanding_mixed`)
had their hand-rolled read==write compares removed now that checker C covers
them byte-for-byte; read-of-unwritten and partial-background data checks were
kept (checker C skips those as unpredictable).

### Design plan: remaining pipeline overlap (ordered / atomic / persist / retry) — DONE

The plain-write variants are done (full, partial, split, ExpCompAck). The four
owed items below are architecturally distinct; this is the intended order,
smallest/safest first. Each keeps the "TX thread is sole TX owner, monitors only
set per-entry flags" invariant.

**1. Ordered writes — DONE (2026-07-07).** In this VIP an "ordered write" is an `ExpCompAck`
write whose REQ carries `Order != NONE`; the completion mechanism (CompAck) is
already pipelined. Work: relax the `order == NONE` gate in `is_plain_write` for
writes, and teach `mixed_rsp_proc` to accept `DBIDRespOrd` (the CHI-E ordered
grant the SN-F emits when `cfg.ordered_dbid_resp`) exactly like `DBIDResp`. For a
single RN-I↔SN-F pair the issue thread already sends in sequence order and the SN-F
services REQs in capture order, so endpoint order is preserved without extra
gating. Open decision: whether to additionally *enforce* Request_Order by gating
issue of ordered request N+1 on N's ordering response — deferred unless a test
needs it (a lone requester cannot observe the difference). Test: pipeline N ordered
ExpCompAck writes, confirm CompAck + read-back. Est. ~small, one driver gate + one
opcode case.

**2. Ordered reads — DONE (2026-07-08).** An ordered read (`Order != NONE`) gets a
`ReadReceipt` (an RSP) before its `CompData`. The pipeline's RSP monitor
(`mixed_rsp_proc`) currently assumes every inbound RSP is a write completion and
fatals otherwise. Work: when the RSP is a `ReadReceipt` whose TxnID matches a READ
ctx, consume it (return credit, optionally flag receipt_seen) rather than fatal; no
retire change (reads still complete on `CompData`). Test: pipeline N ordered reads,
confirm each returns CompData after its receipt. Est. small/medium.

**3. Atomics — DONE (2026-07-09).** A non-store atomic is a hybrid: a `DBIDResp`
grant then operand WriteData (write-like), then a `CompData` return carrying the
original value (read-like). Delivered as built: added `TXN_KIND_ATOMIC` to `mx_ctx` and a
classifier `is_pipelined_atomic`; the issue step pushes the atomic ctx, the
operand-DAT step (2) drives the operand on grant exactly like a write; the RSP
monitor's write branch already records the `DBIDResp`/`CompDBIDResp`/`Comp` grants
and completions; `find_mixed_read_by_completion` now also matches a returning
atomic's `CompData`; and `retire_mixed` gained an atomic branch — `data_sent &&
read_done` for a returning atomic, `data_sent && comp_seen` for a store atomic
(the CompAck step generalizes to both kinds so an `ExpCompAck` atomic still acks).
The SN-F buffered path already routed atomics to `drive_auto_atomic_completion`,
so no SN-F change was needed. Test `tc_chi_multi_outstanding_atomic` pipelines six
returning `AtomicLoad0` (ADD) atomics (peak 6), checks each returned its pre-op
value on `CompData`, and reads back seed+operand. Store atomics reduce to the
plain-write completion path.

**4. Persist — DONE (2026-07-09).** Persist CMOs carry no write data and complete on
RSP only. Delivered as built: added a fourth kind `TXN_KIND_PERSIST` and a
classifier `is_pipelined_persist`; the issue step pushes the persist ctx and, with
no grant ever set, the operand-DAT step never fires for it; a new persist branch in
`mixed_rsp_proc` consumes the completion — a single `Comp` for `CleanSharedPersist`,
or an intermediate `Persist` (stepped over) then a final `CompPersist` for the CHI-E
`CleanSharedPersistSep`; `retire_mixed` retires a persist on `comp_seen`. Two tests:
`tc_chi_multi_outstanding_persist` (CHI-D, six `CleanSharedPersist`, Comp completion)
and `tc_chi_multi_outstanding_persist_sep` (CHI-E, six `CleanSharedPersistSep`,
Persist+CompPersist — the first pipelined test on the CHI-E harness). NB: the CHI-E
test must keep its address/size constants inline rather than in class-scope
`localparam item_t::addr_t …` — a typed class-scope localparam on the wide CHI-E
specialization hangs VCS codegen (mirror `tc_chi_persist`).

**5. handle_retry — serial path DONE (2026-07-09); pipeline overlap DONE (2026-07-13).**
Delivered on the serial driver as recommended. SN-F: opt-in `cfg.force_retry_count`
bounces the first N retryable REQs (`AllowRetry=1`) with a `RetryAck` (carrying a
`PCrdType`) followed by a matching `PCrdGrant`, via `should_auto_retry` /
`drive_auto_retry` (and `drive_rsp` now carries `pcrdtype`). RN-I: a new
`handle_retry`, run right after `drive_req`, peeks the first completion activity —
a DAT beat or a non-RetryAck RSP means no retry (left for the collector); a
`RetryAck` (matching the REQ TxnID) is consumed, `collect_pcrd_grant` waits the
`PCrdGrant`, then the request is re-issued with `AllowRetry=0`, the granted
`PCrdType`, and the original TxnID (`drive_req(req, /*alloc_id=*/0)`). No-op unless
`allow_retry` is set, so all other tests are byte-identical. The bound `vip_chi_sva`
gained a rule that a `RetryAck` retires the transaction's in-flight TxnID (so the
legitimate re-issue is not flagged as a reuse). Test `tc_chi_retry`: a retryable
write is bounced, re-issued, completes on `CompDBIDResp`, and reads back committed.
Pipeline overlap now delivered too: the RN-I mixed pipeline (`mixed_rsp_proc`)
banks `PCrdGrant`s in a per-`PCrdType` pool and the TX thread (`mixed_tx_proc`)
re-issues a bounced entry (original TxnID, `AllowRetry=0`) while the rest of the
pipeline keeps flowing; the SN-F buffered path (`dispatch_auto_response`) now runs
the same `should_auto_retry` check as the serial loop. Test
`tc_chi_multi_outstanding_retry`: 6 pipelined retryable writes, the first bounced
mid-stream, checks exactly one `RetryAck`+`PCrdGrant`, peak-in-flight > 1, and
full read-back integrity.

---

## 0. Wave 1 baseline cleanup (completed)

The initial baseline defects from the post-refactor review are closed:

- RN-I now maps `lp_id` onto REQ `lpid`, and maps DAT `poison`/
  `datacheck` onto outbound write DAT beats.
- `vip_chi_item` and `vip_chi_base_seq` now expose `set_src_id`,
  `set_tgt_id`, and `set_lp_id`, and the base sequence pins those identity
  fields through `randomize() with {}` so requests no longer pick random node
  IDs by default.
- `tc_chi_item_smoke` no longer relies on intentionally inconsistent
  randomization cases, and `con_addr_alignment` no longer calls
  `chi_size_bytes(size)` inside the solver path.

The earlier `vip_chi_sva.sv` interface-port build-breaker was already closed
before this wave.

---

## 1. CHI feature inventory and scope

### 1.1 CHI versions

| Version | `vip_chi_issue_t` | Status |
|---------|-------------------|--------|
| CHI-D | `VIP_CHI_ISSUE_D_E` | Supported |
| CHI-E | `VIP_CHI_ISSUE_E_E` | Supported |
| CHI-A/B | — | Out of scope |

Both from the **same source files**; `CFG_P.issue` gates flit widths, opcode
legality, and optional-field presence. One interface, one item, one agent tree.

**D/E deltas that affect the implementation:**

| Field / opcode | CHI-D | CHI-E |
|----------------|-------|-------|
| `TxnID` / `ReqOpcode` / `RspOpcode` / `LPID` widths | 10 / 6 / 4 / 5 | 12 / 7 / 5 / 8 |
| `TagOp`/`Tag`/`TU`; `WriteNoSnpZero`, `MakeReadUnique`, `StashOnceSep*`, `DBIDRespOrd`, `CleanSharedPersistSep` | absent | present |

Conditionally-present fields clamp to ≥1 bit in `vip_chi_types`; presence is
tested by `CFG_P.issue` / enable bits, never by typedef width.

### 1.2 Node roles

| Role | `vip_chi_role_t` | Status |
|------|------------------|--------|
| Monitor | `VIP_CHI_ROLE_MONITOR_E` | Done (passive) |
| SN-F | `VIP_CHI_ROLE_SNF_E` | Done — memory-target non-coherent responder |
| RN-I | `VIP_CHI_ROLE_RNI_E` | Done — non-coherent initiator |
| **HN-I** | `VIP_CHI_ROLE_HNI_E` | **Done** — dual-link pass-through ordering proxy (RN-facing completer + SN-facing requester), no snoop fan-out; serial per-channel flit relay exercised by `tc_chi_hni_passthrough` |
| **RN-F** | `VIP_CHI_ROLE_RNF_E` | **Done (Tier C)** — coherent requester with per-line cache state + autonomous snoop responder (clean + dirty-forward `SnpRespData`); reuses the RN-I request/credit/retry machinery |
| **HN-F** | `VIP_CHI_ROLE_HNF_E` | **Done (Tier C)** — coherent home: directory + snoop origination + terminating memory, per-line-locked transaction engine; writeback/evict with dirty merge |

`ROLE_P` is a compile-time parameter on the interface and agent (parallels
`vip_axi4`).

### 1.3 Feature scope — three tiers

**Tier A — implemented.** Link layer (activation/deactivation, `sactive`);
counted L-credits on REQ/RSP/DAT; REQ `ReadNoSnp`, `ReadNoSnpSep`,
`WriteNoSnpPtl/Full`, `WriteNoSnpZero` (E), `PrefetchTgt`, `PCrdReturn`; DAT
`CompData`, `NCBWrData`, `NCBWrDataCompAck`, `DataSepResp`; RSP `Comp`,
`CompDBIDResp`, `DBIDResp`, `RetryAck`, `PCrdGrant`, `ReadReceipt`,
`RespSepData`, `CompAck`; `PCrd` retry/grant; DECERR (NDERR both directions),
DERR (read, data-present); reset drain/re-arm.

**Tier B — implemented (committed by this revision).** Every item below is
shipped and tested; the list is retained as the scope record.

1. **Signal-drivability API (§12).** Every REQ/RSP/DAT field user-settable, plus
   a raw/override path for arbitrary (incl. illegal) flits. Closes defects
   0.1–0.3. Adds `QoS` (item field + flit map), identity setters
   (`src_id`/`tgt_id`/`lp_id`), and issue-gated CHI-E setters (`tracetag`,
   `tagop`/`tag`/`tu`, `dodwt`, `likelyshared`, `endian`, `groupidext`).
2. **Atomics (D & E):** `AtomicStore`, `AtomicLoad`, `AtomicSwap`,
   `AtomicCompare`. SN-F performs the op on `vip_mem`; RN-I sends the operand and
   (non-store) collects the original-value `CompData`. See §11.3.
3. **Ordered reads/writes:** `Order = REQ_ACCEPTED/REQ_ORDER` with `ReadReceipt`
   correlation; `DBIDRespOrd` (CHI-E ordered-write DBID).
4. **CHI-E Memory Tagging:** `TagOp`/`Tag`/`TU` on REQ/DAT, SN-F tag storage and
   replay, and the `TagMatch` RSP opcode (0x0A) are all implemented. They are
   listed as three pieces rather than one because they were finished at three
   different times and the first two shipped while the third did not — and then
   the third shipped while the comparison behind it did not. Under
   `TagOp = Match` the completer checks the write's Physical Tags against the
   stored Allocation Tags (Table 13-34) and answers in `Resp[0]` alone
   (Table 13-25); a Match write does not update the stored tags, which is what
   separates it from `Update`.
5. **Persistence CMOs:** `CleanSharedPersist`, `CleanSharedPersistSep` (E) as
   completion-only operations to the SN-F.
6. **HN-I role** (§11.4): **Done** — dual-link pass-through ordering proxy. The
   `vip_mc` connector half (wiring `vip_chi_if` ↔ `vip_mc_chi_if`) is also **done**
   — `vip_mc/vip_mc_chi_connect.sv` bridges a stock RN-I `vip_chi_if` to `vip_mc`'s
   `vip_mc_chi_if` SN endpoint, instantiated in CHI-D, CHI-E, and narrow-32 B in
   the `vip_mc` example and exercised by the `tc_vip_mc_chi_*` tests (§20).

**Tier C — coherent subsystem implemented; residual items deferred.** The SNP
channel and a full coherent RN-F/HN-F subsystem are now shipped and tested on
both the CHI-D and CHI-E configs:

- coherent requests: `ReadShared`, `ReadClean`, `ReadUnique`, `CleanUnique`,
  `MakeUnique`, `WriteBackFull`, `WriteCleanFull`, `Evict`;
- HN-F directory + snoop origination (`SnpShared`, `SnpClean`, `SnpCleanShared`,
  `SnpUnique`, `SnpCleanInvalid`, `SnpMakeInvalid`) behind a per-line-locked
  transaction engine, terminating to its own `vip_mem`;
- RN-F per-line cache + autonomous snoop responder with clean (`SnpResp`) and
  dirty-forward (`SnpRespData` + PassDirty) responses; writeback/evict with
  dirty merge into home memory;
- a self-derived system coherency checker (Checker D — single-writer +
  data-integrity invariants, each with a negative control), SNP-channel SVA, and
  coherent functional coverage (coherent-req / snoop-opcode / snoop-resp /
  cache-transition / directory-occupancy).

Still deferred: forwarding / direct-cache-transfer snoops (`Snp*Fwd`,
`SnpRespDataFwded`); `ReadOnce`/`WriteUnique`; the `MakeReadUnique`/`CleanInvalid`/
`MakeInvalid` request variants; DVM; Stash (`WriteUniqueFullStash`, `StashOnce*`,
`StashOnceSep*`); exclusives; interface parity (`PARITY_EN_P`); an SN-F behind
the HN-F (the HN-F terminates to its own memory in v1); bounded-cache silent
eviction. (The `vip_mc` connector, once listed here, is now **done** — see the
Tier B HN-I item above and §20.)

---

## 2. Architecture

```text
┌──────────────── vip_chi_agent #(CFG_P, FLIT_TYPES_T, ROLE_P) ───────────────────┐
│ sequencer ─▶ driver_rni | driver_snf | driver_hni  (selected by ROLE_P, inline)  │
│                ├ lcrd_mgr ×N (counted credits, credit_loop)                       │
│                └ activate_link() (handshake; reset-aware)                         │
│ monitor (passive, monitor_cb) ─▶ req/rsp/dat_port ─▶ coverage / scoreboard        │
└──────────────── virtual vip_chi_if #(CFG_P, FLIT_TYPES_T, ROLE_P) ────────────────┘
                                   │  vip_chi_if  ── DUT / remote vip_chi agent
```

**Key principles.** (1) Single source for D/E — no `ifdef`; widths in
`vip_chi_types #(CFG_P)`, opcode legality in item constraints +
`check_opcode_legal()`. (2) ROLE_P at compile time — the interface elaborates
only the active role's driving clocking block (`generate`-gated `g_drv`); the
agent builds the matching driver, so a `virtual vip_chi_if #(…,ROLE_P)` is only
assigned to a same-ROLE_P driver handle. (3) No external CHI package dependency;
only `vip_memory_pkg`/`bool_pkg`. (4) L-credits owned by the driver (counted),
observed passively by the monitor. (5) Reset owned by the agent (no standalone
`link_ctrl`/`reset_handler`). (6) Items are issue-neutral and **field-complete**;
the driver maps **every** item field onto the flit (defects 0.1/0.2 violate
this). (7) `vip_mem` SN-F backing store via `cfg.mem_cfg`; counter pattern if
unconfigured.

---

## 3. File layout

Reflects the current tree. `(planned)` = required-but-not-yet-present.

```
vip_chi_agent/
├── vip_chi_types_pkg.sv     (cfg, enums, opcode localparams, width helpers,
│                             vip_chi_types/_d/_e classes, REQ/RSP/DAT flit structs)
├── vip_chi_if.sv            (interface #(CFG_P, FLIT_TYPES_T, ROLE_P); monitor_cb
│                             always; ROLE_P-gated g_drv snf_cb/rni_cb)
├── vip_chi_item.sv          (uvm_sequence_item; full field set; do_copy/compare/
│                             convert2string; constraints)
├── vip_chi_cfg_item.sv      (per-item constraint template for base_seq)
├── vip_chi_cfg_agent.sv     (uvm_object; bool_t flags; mem_cfg; credit/outstanding/
│                             delay knobs; decerr/derr ranges; + qos/atomic knobs)
├── vip_chi_lcrd_mgr.sv      (counted credit object: reset/try_acquire/return)
├── vip_chi_monitor.sv       (passive; req/rsp/dat analysis ports; beat assembly)
├── vip_chi_coverage.sv      (functional coverage; subscribes monitor ports)
├── vip_chi_sequencer.sv     (uvm_sequencer #(vip_chi_item #(CFG_P)))
├── vip_chi_driver_rni.sv    (RN-I initiator)
├── vip_chi_driver_snf.sv    (SN-F responder; vip_mem backing)
├── vip_chi_driver_hni.sv    (HN-I dual-link pass-through proxy)
├── vip_chi_agent.sv         (uvm_agent; inline ROLE_P dispatch; rst_n watcher)
├── vip_chi_agent_pkg.sv     (package; all class + seq_lib includes)
├── vip_chi.svh              (compile header used by the example flow)
├── vip_chi_sva.sv           (bindable assertion module)
├── vip_chi_reset_handler.sv (planned, optional — multi-agent rst_n coordinator)
├── vip_chi_adapter.sv       (planned, optional — uvm_reg_adapter → RN-I)
├── seq_lib/  (seq_config, addr_iterator, seq_payload_buffer, seq_counter_iter,
│              base_seq, read_seq, write_seq, write_zero_seq, pipelined_seq,
│              atomic_seq, persist_seq, raw_seq; planned: pcrd_retry_seq,
│              snf_mem_preload_seq, snf_decerr_seq, snf_derr_seq)
└── vip_chi_agent.core
```

`vip_chi_link_ctrl.sv` and a separate `vip_chi_driver.sv` dispatch shell from the
original plan are **not** used — dispatch is inline in `vip_chi_agent`, link
activation lives in each driver's `activate_link()`.

Ordered traffic is currently driven through `vip_chi_base_seq` setters
(`set_order`, `set_exp_comp_ack`, `set_sep_read`) and the dedicated ordered
contract tests; there is no standalone `vip_chi_ordered_seq` class in the tree.

**External dependencies.** `vip_memory_pkg` is at
`submodules/vip/vip_memory/vip_memory_pkg.sv` and `bool_pkg` at
`submodules/vip/bool/bool_pkg.sv` (they are **not** in `common_designs`). Both
precede `vip_chi_types_pkg` in compile order.

---

## 4. `vip_chi_types_pkg`

Single source of truth for CHI constants, enums, the cfg struct, derived scalar
typedefs, and the exact wire-level flit structs.

```sv
typedef enum logic { VIP_CHI_ISSUE_D_E, VIP_CHI_ISSUE_E_E } vip_chi_issue_t; // 1 bit
typedef enum logic [2:0] {
  VIP_CHI_ROLE_MONITOR_E, VIP_CHI_ROLE_SNF_E, VIP_CHI_ROLE_RNI_E,
  VIP_CHI_ROLE_HNI_E      // done (dual-link pass-through proxy)
} vip_chi_role_t;
typedef enum logic { VIP_CHI_DIR_READ_E, VIP_CHI_DIR_WRITE_E } vip_chi_dir_t;
```

`vip_chi_cfg_t` is a `packed struct` so all config travels as one `CFG_P`
parameter; `bit [31:0]` widths are unsigned (avoid `int` signed lint).

```sv
typedef struct packed {
  vip_chi_issue_t issue;
  bit [31:0] NODE_ID_WIDTH_P;   // ≤ 11
  bit [31:0] ADDR_WIDTH_P;      // ≤ 44 (D) / ≤ 52 (E)
  bit [31:0] DATA_BYTES_P;      // power-of-two ≤ 64
  bit        DATACHECK_EN_P;
  bit        POISON_EN_P;
  bit        MPAM_EN_P;
  bit        MTE_EN_P;          // NEW (Tier B): CHI-E memory tagging
  bit        PARITY_EN_P;
} vip_chi_cfg_t;
```

`vip_chi_types #(CFG_P)` derives scalar aliases (`node_id_t`, `addr_t`,
`txn_id_t`, `size_t`=`logic[2:0]`, `req/rsp/dat_opcode_t`, `be_t`, `data_t`,
`data_id_t`, `cc_id_t`, `lpid_t`, `tag_t`, `tu_t`, `datacheck_t`, `poison_t`,
`mpam_t`, `groupidext_t`) and the **flit structs**; `vip_chi_types_d/_e`
specialise exact wire shapes (E adds `tagop`/`tag`/`tu`/`groupidext`).

**Flit field superset** (present in the structs; the driver must map all
item-exposed fields — see §6/§12): REQ `qos,tgtid,srcid,txnid,returnnid,endian,
returntxnid,opcode,size,addr,ns,likelyshared,allowretry,order,pcrdtype,memattr,
dodwt,lpid,groupidext,excl,expcompack,tagop,tracetag,mpam`; RSP `qos,tgtid,srcid,
txnid,opcode,resp,resperr,fwdstate,cbusy,dbid,pcrdtype,tagop,tracetag`; DAT `qos,
tgtid,srcid,txnid,homenid,opcode,resp,resperr,datasource,cbusy,dbid,ccid,dataid,
tagop,tag,tu,tracetag,be,data,datacheck,poison`.

**Resp vs RespErr (distinct fields):** cache-state `Resp` is `vip_chi_resp_t`
(3-bit, `VIP_CHI_RESP_STATE_*`); error is `vip_chi_resp_err_t` (2-bit):
`VIP_CHI_RESP_ERR_NORMAL_OKAY_C=2'b00`, `_EXOKAY_C=2'b01`, `_DERR_C=2'b10`,
`_NDERR_C=2'b11`.

**Constants:** `VIP_CHI_CACHE_LINE_BYTES_C=64`, `VIP_CHI_QOS_WIDTH_C`,
`VIP_CHI_MPAM_WIDTH_C=11`, `VIP_CHI_PCRD_TYPE_WIDTH_C`,
`VIP_CHI_UNLIMITED_REQUESTS_C='1`.

**Opcode localparams** at max width (7-bit REQ, 5-bit RSP, 4-bit DAT). Tier-A set
plus Tier-B: REQ `ATOMIC_STORE/LOAD/SWAP/COMPARE`, `CLEAN_SHARED_PERSIST[_SEP]`;
RSP `DBID_RESP_ORD`. `check_opcode_legal(cfg, opcode)` is the single `uvm_fatal`
gate for E-only opcodes under CHI-D.

**Width helpers:** `chi_txn_id_width`, `chi_{req,rsp,dat}_opcode_width`,
`chi_lpid_width`, `chi_poison_width=data_bytes/8`,
`chi_datacheck_width`/`chi_be_width=data_bytes`, `chi_num_dat_beats`,
`chi_data_id_width` (`$clog2`, clamp ≥1), `chi_xfer_dat_beats(size,data_bytes)=
max(1,(1<<size)/data_bytes)`, `chi_size_bytes(size)=1<<size`.

`vip_chi_decerr_range_t`/`vip_chi_derr_range_t` use `logic[51:0]` base/limit
(package scope). `vip_chi_data_type_t = {RANDOM, COUNTER, ZEROS, ONES, CUSTOM}`.

---

## 5. `vip_chi_if`

Self-contained CHI interface. **Three parameters — normative; all consumers and
the SVA bind match this:**

```sv
interface vip_chi_if #(
  parameter vip_chi_cfg_t  CFG_P        = VIP_CHI_DEFAULT_CFG_C,
  parameter type           FLIT_TYPES_T = vip_chi_types #(CFG_P),
  parameter vip_chi_role_t ROLE_P       = VIP_CHI_ROLE_MONITOR_E
)( input clk, input rst_n );
```

Signals (CHI lowercase): `{tx,rx}{req,rsp,dat}{flitpend,flitv,flit,lcrdv}`, link
sideband `txlinkactivereq/txlinkactiveack/rxlinkactivereq/rxlinkactiveack`,
`txsactive/rxsactive`.

| Clocking block | Present when | Direction summary |
|----------------|--------------|-------------------|
| `monitor_cb` | always | all inputs |
| `g_drv.snf_cb` | `ROLE_P==SNF` | drives `txrsp*`,`txdat*`(CompData), `tx*lcrdv`, `txsactive`, link req/ack; samples `rxreq*`,`rxrsp*`,`rxdat*` |
| `g_drv.rni_cb` | `ROLE_P==RNI` | drives `txreq*`,`txrsp*`(CompAck),`txdat*`(write data), credits, `txsactive`, link req/ack; samples `rxrsp*`,`rxdat*`,`rxreqlcrdv` |

Default skew `input #1step output #0`. Modports `monitor`/`snf`/`rni`.

Link model: a node drives `txlinkactivereq` and mirrors the incoming request onto
its ack (`txlinkactiveack <= rxlinkactivereq`), and samples `rxlinkactiveack`. The
example top cross-wires `tx*↔rx*` between the two agents.

> **To reconcile:** `txsactive`/`rxsactive` are currently inside the clocking
> blocks; keep an unclocked combinational view available for reset/deactivation
> and SVA logic.

---

## 6. `vip_chi_item`

One `uvm_sequence_item` for all channels/roles, carrying `direction` and `role`.
**Every protocol field is a member and is driven by the driver** (see §12 for the
user-facing setters).

### 6.1 Fields

**Identity:** `direction`, `role`, `src_id`, `tgt_id`, `txn_id`, `lp_id`,
`return_nid`, `return_txn_id`, **`qos`** (NEW).

**REQ:** `opcode`, `addr`, `size`, `ns`, `order`, `mem_attr`, `pcrd_type`,
`allow_retry`, `excl`, `exp_comp_ack`, `mpam`, plus **CHI-E control** (NEW,
issue/enable-gated): `tracetag`, `dodwt`, `likelyshared`, `endian`,
`group_id_ext`, `tagop`.

**DAT:** `dat_opcode`, `data[]`, `be[]`, `data_id[]`, `cc_id[]`, `dat_resp[]`
(`vip_chi_resp_t`), `dat_resp_err[]` (`vip_chi_resp_err_t`), `datacheck`,
`poison`, plus **CHI-E tagging** (NEW): `tag[]`, `tu[]`, `dat_tagop`.

**Atomic (NEW, Tier B):** `atomic_op` (store/load/swap/compare),
`atomic_data[]` (operand; compare+swap pair for `AtomicCompare`),
`atomic_return_data[]` (original value for non-store atomics).

**RSP:** `rsp_opcode`, `rsp_resp` (`vip_chi_resp_t`), `rsp_resp_err`
(`vip_chi_resp_err_t`), `fwd_state`, `dbid`.

**Raw override (NEW, Tier B):** `raw_override` (bit) + `raw_req`/`raw_rsp`/
`raw_dat` flit members. When set, the driver emits the raw flit verbatim and the
legality constraints are bypassed (§12.3).

`set_config(cfg)` propagates `CFG_P` before randomize.
`do_copy`/`do_compare`/`convert2string` cover all fields incl. dynamic arrays.

### 6.2 Constraints

- `con_opcode_legal`: opcode ∈ role+issue legal set (E-only excluded under D;
  coherent opcodes incl. `MakeReadUnique` excluded — Tier C; atomics/persist
  added with their Tier-B work, gated by `cfg.atomics_enabled` etc.).
- `con_size_range`: `size ∈ [min_size,max_size]` (0..6 default).
- `con_addr_alignment`: gated by `enforce_addr_alignment` (default TRUE) so
  negative/boundary tests can emit unaligned addresses. *(See defect 0.4 — verify
  the in-constraint `chi_size_bytes(size)` use is not the CNST-CIF source.)*
- `con_exp_comp_ack_legal`: `exp_comp_ack==0` for reads/prefetch/pcrd/writezero.
- `con_return_path_fields`: `return_nid==src_id` only for `ReadNoSnpSep`.
- `con_issue_gated_fields`: `mpam/datacheck/poison/tag/tu==0` when the enable bit
  is clear.
- Array sizing done in **`post_randomize()`** to `chi_xfer_dat_beats(size,
  DATA_BYTES_P)` — never via a constraint referencing `size.size()`.
- `txn_id` not constrained for uniqueness; the driver allocator owns it.

---

## 7. `vip_chi_cfg_agent`

`uvm_object` using local conventions (`bool_t`, owned `vip_mem_config mem_cfg`).
Current knobs: `is_active`, `role`, per-channel verbosity,
`max_outstanding_read/write`, `max_pcrd_budget`, `initial_{req,rsp,dat}_credits`,
`decerr_ranges[]`, `derr_ranges[]`, `force_retry_count`, `split_write_rsp`,
`mem_cfg`, link/REQ/RSP/DAT valid-delay knobs, `coverage_enabled`,
`compack_timeout_cycles`.

**New knobs (Tier B):**

```sv
node_id_t default_src_id;                 // default SrcID on RN-I requests
node_id_t default_tgt_id;                 // default TgtID (SN-F / HN node)
bit [VIP_CHI_QOS_WIDTH_C-1:0] default_qos = '0;
bool_t    atomics_enabled    = FALSE;     // allow atomic opcodes in the legal set
bool_t    ordered_dbid_resp  = FALSE;     // SN-F answers ordered writes with DBIDRespOrd (E)
bool_t    allow_raw_override  = TRUE;     // driver honors item.raw_override
```

---

## 8. `vip_chi_monitor`

Passive observer on `monitor_cb`; broadcasts one item per REQ flit (`req_port`),
per RSP flit (`rsp_port`), and per **complete** DAT transfer (`dat_port`, after
assembling all beats by `TxnID`/`DataID`). Populates `dat_opcode`,
`rsp_resp`/`rsp_resp_err`, `dat_resp`/`dat_resp_err`. It now also publishes the
common identity/QoS fields needed by coverage/scoreboard (`lp_id`, return-path
fields, `qos`, `mpam`, DAT `poison`/`datacheck`, RSP `pcrd_type`) plus the
common REQ control bits shared by the exact D/E flit shapes (`tracetag`,
`snpattr`, `likelyshared`, `endian`). The current runtime cut now also covers the
exact-E-only REQ/DAT fields exercised by the focused wide-sidecar smokes,
including autonomous SN-F tag replay in `tc_chi_mte`; remaining Tier-B parity
work is any later RSP-side exact-E additions plus future raw-override
bookkeeping. It does not correlate REQ/RSP/DAT — that is the scoreboard's job,
and `vip_chi_scoreboard` (§21) now does exactly that (lifecycle, fidelity, and
write→read data). Verbosity gated by `cfg`.

> **Open interop caveats (§22):** the monitor currently retires a DAT transfer
> on advisory `FLITPEND` deassert rather than a beat count (H1), its REQ↔DAT
> expected-beat correlation is effectively dead (H2), it indexes DAT beats by
> absolute `DataID` (M7), and it publishes RSP/DAT items with a stale
> `direction` field (M8). These are latent against the in-tree VIP-on-VIP loop
> but break against a spec-compliant external DUT. Any monitor-reassembly fix
> must preserve one-assembled-item-per-transfer, which both the per-test FIFO
> checks and the scoreboard depend on.

---

## 9. Link activation & reset

Shipped: each driver's `activate_link()` drives `txlinkactivereq` and waits for
`rxlinkactiveack`; `drive_idle_sideband()` continuously mirrors
`txlinkactiveack <= rxlinkactivereq`. Reset is owned by `vip_chi_agent::run_phase`
(single `rst_n` watcher; `disable fork` on assertion; re-arm on release).

A standalone `vip_chi_link_ctrl` is **optional** and not shipped; add it only if
multiple components need a shared link-state tracker. If added, it must race
`activate()` against `@(negedge rst_n)` with `fork…join_any; disable fork;` so a
mid-activation reset cannot leave a thread driving signals.

---

## 10. `vip_chi_lcrd_mgr` and the credit model

Shipped: a counted object — `reset(max, initial_available=0)`,
`try_acquire_credit()` (non-blocking; decrement; 0 when empty),
`return_credit()` (increment; `uvm_fatal` on overflow past the configured
capacity). Each driver runs a background `credit_loop()` that both counts peer
`LCRDV` pulses into its local send budget and emits one-cycle outbound `LCRDV`
pulses for:

- the **initial receive-credit grant** after link activation, and
- later **return-after-consume** events when a flit is actually accepted.

The shipped model is now **spec-faithful for real DUT integration**: a channel's
local sender starts at 0 available credits, while the remote receiver advertises
its buffer depth by issuing `initial_{req,rsp,dat}_credits` pulses after the link
comes up. The same counter path then handles steady-state returns, so a
spec-compliant CHI DUT can grant its initial credits without tripping overflow.
The non-blocking counter remains acceptable for the single-threaded driver loop
(the original blocking-semaphore design is dropped).

---

## 11. Drivers

### 11.1 `vip_chi_driver_snf` — SN-F responder

```text
RX-REQ → decode → addr range check (decerr/derr) →
  ReadNoSnp       → fetch vip_mem → CompData (normal beat count)
  ReadNoSnpSep    → RespSepData(RSP) then DataSepResp(DAT); + ReadReceipt if Order requires
  WriteNoSnp*     → CompDBIDResp (or DBIDResp+deferred Comp if split_write_rsp) →
                    collect DAT → commit vip_mem → if ExpCompAck wait CompAck (timeout→fatal)
  WriteNoSnpZero  → zero range in vip_mem → CompDBIDResp (or DBIDResp+Comp if
                    split_write_rsp); no DAT, and the granted buffer is unused
  Atomic*         → (Tier B) collect operand → RMW on vip_mem →
                    CompData(original) for load/swap/compare; Comp for store
  CleanSharedPersist[Sep] → (Tier B) completion-only (Comp, or Persist+CompPersist)
  PrefetchTgt     → no-completion hint
  PCrdReturn      → decrement issued-PCrd count
```

DECERR read returns `CompData(RespErr=NDERR)` with the **normal beat count**
(zeroed placeholders) — consistent with `compdata_beat_count`. DERR returns real
`vip_mem` data with `RespErr=DERR`. `decerr_ranges` precedes `derr_ranges`. No
artificial latency beyond credit + `rsp/dat_valid_delay`; `sactive` asserts while
any transaction is outstanding. The exact-CHI-E manual responder path now also
maps DAT-side tagging (`DAT tagop`, `tag`, `tu`) through an issue-specific
DAT hook in `vip_chi_driver_snf_e`, and `tc_chi_e_snf_dat_smoke` proves that
the monitor reads those fields back on transmitted completions. The same
exact-E responder path now also captures per-beat tag metadata on autonomous
write traffic and replays it on later `CompData` beats via a local SN-F tag
store; `tc_chi_mte` proves the `TagOp`/`Tag`/`TU` round-trip. Remaining
CHI-E responder work is any later RSP-side exact-E extension, not DAT tagging.

### 11.2 `vip_chi_driver_rni` — RN-I initiator

Shipped flow: pull item → `drive_req` → write: `collect_write_dbid_grant`
(extract DBID) → `drive_dat` (`txnid=DBID`) → split? `collect_write_completion` →
`CompAck` if `exp_comp_ack` → `item_done`; read: `collect_read_completion`
(assemble `CompData`) → `item_done`. The completed item returns via
`item_done(req)` so `get_response()` works.

**Required corrections/extensions:** the Wave 1/Wave 2 baseline now maps the
common request/data controls (`lpid`, `poison`, `datacheck`, `qos`) plus the
REQ-side control bits shared by the exact D/E flit families (`tracetag`,
`snpattr`, `likelyshared`, `endian`), and it keeps write DAT routing fields intact
across the early DBID-grant response. A new exact-CHI-E RN-I runtime path now
covers the REQ-only E fields that are absent from the exact-D flit family
(`groupidext`, REQ `tagop`) via issue-specific driver/monitor hooks and
`vip_chi_agent_e`. The same exact-E RN-I runtime path now also covers DAT-side
E tagging on outgoing write data (`DAT tagop`, `tag`, `tu`) and proves the
monitor readback with `tc_chi_e_dat_smoke`. Together with SN-F autonomous tag
replay validated by `tc_chi_mte`, the Tier-B exact-E tagging path is now
closed. Remaining Tier-B work is `item.raw_override` and **replacing
the free-running wrapping TxnID counter with an
in-flight bitmap** (`bit in_flight[2**chi_txn_id_width]`, round-robin allocate,
hold on `RetryAck`, release on `Comp`/`CompData`/`CompDBIDResp` — later of
`RespSepData`/`DataSepResp` for sep reads; route DAT by DBID); add atomics
(operand send + return-data collect), ordered (`Order`/`ReadReceipt`,
`DBIDRespOrd`), and `handle_retry` (record PCrdType → wait matching `PCrdGrant` →
resend `AllowRetry=0`, same TxnID).

### 11.3 Atomics (Tier B)

`AtomicStore` (no return), `AtomicLoad`/`AtomicSwap`/`AtomicCompare` (return the
pre-op value). RN-I sends the operand on DAT after the DBID grant; SN-F performs
the RMW against `vip_mem` and returns `CompData` with the original value for
non-store atomics. `atomic_op`/`atomic_data[]`/`atomic_return_data[]` carry the
item-level intent (§6.1).

### 11.4 `vip_chi_driver_hni` — HN-I proxy (Done)

Dual-link pass-through ordering proxy. A home node straddles two CHI links, so
the driver holds two virtual interfaces: an RN-facing side (`ROLE_P=HNI`, whose
`hni_cb` clocking mirrors the SN-F completer polarity — receives REQ, sources
RSP/DAT) and an SN-facing side (`ROLE_P=RNI`, the requester — sends REQ, receives
RSP/DAT). It shares `vip_chi_if` and `vip_chi_item`. Primary use: sit between an
RN DUT and the SN-F responder (or `vip_mc`, now that its CHI front-end + connector
have landed — §20.2) for routed-traffic tests.

Implementation is a **pure per-channel flit relay** — five daemons forward whole
flit structs verbatim without decoding opcodes (REQ RN→SN, RSP SN→RN, CompAck
RN→SN, write-DAT RN→SN, read-DAT SN→RN), so it is transaction-agnostic and needs
no TxnID remapping. Flow control is strictly **lock-step**: exactly one inbound
credit is granted per channel and the next is returned only after the relay has
forwarded the captured flit, which lets a single-threaded relay carry multi-beat
bursts without being outrun. This gives one-at-a-time (serial) forwarding;
overlapped/pipelined proxying is the deferred P4 work (§15). The agent creates
the driver via inline `ROLE_P` dispatch (no sequencer — the proxy is autonomous),
and the example TB (`VIP_CHI_TB_MODE_HNI_E`) routes RN-I → HN-I → SN-F for the
`tc_chi_hni_passthrough` end-to-end write+read check.

---

## 12. Stimulus API & signal drivability  *(NEW — Tier B)*

**Today:** the sequence API covers common memory traffic well (addr/size/dir/
data/ns/order/mem_attr/allow_retry/exp_comp_ack/excl/pcrd_type/sep_read/delays),
and Wave 1 plus the current Wave 2 slice added direct setters for
`src_id`/`tgt_id`/`lp_id`/`qos`, the separated-read return path, and the REQ-side
CHI-E control bits. Those REQ-side CHI-E fields now have a real exact-E runtime
path as well, not just preview randomization, and the same is now true for the
RN-I write DAT tagging fields. The raw-flit gap is now closed by
`vip_chi_raw_seq` + `item.raw_override`, and the exact-E tagging path now also
covers the autonomous/tag-storage side through the SN-F local tag store used by
`tc_chi_mte`. The remaining design work is the optional per-flit hook so
that **every signal is drivable any way the user likes.**

**12.1 Structured field setters.** Shipped today: `set_src_id`, `set_tgt_id`,
`set_lp_id`, `set_qos`, `set_return_nid`, `set_return_txn_id`, and the REQ-side
CHI-E control setters `set_tracetag`, `set_dodwt`, `set_likelyshared`,
`set_endian`, `set_group_id_ext`, `set_tagop`, each backed by a stamped `*_val`
member that `body()` pins in the `randomize() with {}` block so the value
survives randomization. The return-path setters remain subject to the item
legality rule that `return_nid`/`return_txn_id` are only meaningful on
`ReadNoSnpSep`, and the CHI-E control setters are issue-gated back to zero under
CHI-D. `group_id_ext` and REQ `tagop` now also reach the wire through the exact
CHI-E runtime path used by `tc_chi_e_req_smoke`. DAT-side setters now also
exist for the exact-E write path: `set_dat_tagop`, `set_tag`, and `set_tu`,
and `tc_chi_e_dat_smoke` proves that they survive into monitored DAT flits on
the RN-I path. Identity/QoS defaults should ultimately come from
cfg-driven node settings.

**12.2 Driver field mapping.** Wave 1 closed the known LPID and DAT
`poison`/`datacheck` gaps, and the current Wave 2 slices add `qos` on REQ/DAT/
RSP, common identity/QoS monitor readback, and REQ-side mapping/readback of the
common control bits present in both exact D/E flit shapes (`tracetag`,
`snpattr`, `likelyshared`, `endian`). Exact-E request-only mapping/readback now also covers
`groupidext` and REQ `tagop` through an issue-specific RN-I driver/monitor path.
Exact-E DAT mapping/readback on the RN-I write path now also covers `DAT tagop`,
`tag`, and `tu` through the same subclass-hook pattern, and the manual SN-F
completion path now covers the same DAT fields through `vip_chi_driver_snf_e`
plus `tc_chi_e_snf_dat_smoke`. Raw override support is now implemented across
the common RN-I/SN-F drivers plus exact-E issue-specific hooks and validated by
`tc_chi_raw_inject`. The autonomous/tag-storage half of CHI-E tagging is now
implemented and validated by `tc_chi_mte`. Rule:
an item field with no driver mapping is a bug.

**12.3 Raw-flit injection (`vip_chi_raw_seq` + `item.raw_override`).** For
arbitrary/illegal stimulus (protocol error injection, corner encodings, fuzzing),
the user builds a flit value directly and the driver emits it verbatim, bypassing
structured composition and the legality constraints:

```sv
vip_chi_raw_seq #(CHI_CFG_C) seq = vip_chi_raw_seq#(CHI_CFG_C)::type_id::create("seq");
req_flit_t f = '0;
f.opcode = 7'h7F;            // illegal opcode for a negative test
f.addr   = 64'hBAD0;
seq.add_raw_req(f);          // also add_raw_dat()/add_raw_rsp()
seq.start(env.rni_agent.sequencer);
```

This is now implemented by `vip_chi_item::{set_raw_req,set_raw_rsp,set_raw_dat}`,
`vip_chi_raw_seq`, common RN-I/SN-F raw short-circuit drive paths, and exact-E
issue-specific raw hooks. `tc_chi_raw_inject` proves a raw illegal RN-I REQ and
raw SN-F DAT/RSP flits are emitted verbatim and observed by the monitors.

`raw_override` items skip the structured legality constraints
(`con_role_legal`, `con_addr_range`, `con_size_range`,
`con_addr_alignment`, `con_opcode_legal`, `con_return_path_fields`,
`con_exp_comp_ack_legal`, and `con_issue_gated_fields`).

**12.4 Per-flit override hook (optional).** A virtual
`function void pre_drive_req(ref req_flit_t f)` (and rsp/dat variants),
default no-op, lets an env subclass mutate any field of any flit just before it is
driven — the lowest-friction "touch any signal" hook for directed corners.

With 12.1–12.4 every interface signal is reachable: common fields via setters,
everything else via the raw path or `pre_drive` hook.

---

## 13. `vip_chi_coverage`

First-cut component subscribing to RN-I and SN-F monitor req/rsp/dat ports.
Shipped covergroups are `cg_req`, `cg_rsp`, `cg_dat`, `cg_write_flow`, and
`cg_recovery`, covering request/rsp/dat opcode classes, sizes and beat counts,
error responses, write grant/completion flow, and post-reset recovery.
Coverage is instantiated at the env level and gated by `cfg.coverage_enabled`.
The passive expansion groups `cg_addr_alignment`, `cg_outstanding`,
`cg_atomic`, `cg_qos`, `cg_mte`, and `cg_ordered_read` are now implemented in
the shipped coverage component. `cg_outstanding` currently reflects the shipped
serial RN-I behavior rather than a true multi-outstanding datapath.

`vip_chi_reset_handler` (multi-agent `rst_n` coordinator) remains optional;
single-agent TBs use the agent-owned watcher.

---

## 14. `vip_chi_agent`

```sv
class vip_chi_agent #(
  vip_chi_cfg_t CFG_P = VIP_CHI_DEFAULT_CFG_C,
  type FLIT_TYPES_T = vip_chi_types #(CFG_P),
  vip_chi_role_t ROLE_P = VIP_CHI_ROLE_MONITOR_E
) extends uvm_agent;
```

- `build_phase`: fetch `vif`/`cfg`; `check_cfg_p()`; create `monitor` always;
  when active create the ROLE_P-matched driver (`rni`/`snf`/`hni`) + `sequencer`
  (inline dispatch).
- `connect_phase`: `seq_item_port` ↔ sequencer; expose
  `monitor.{req,rsp,dat}_port`.
- `run_phase`: single `rst_n` watcher; fork driver/monitor after release;
  `disable fork` + `handle_reset()` on assertion.

`check_cfg_p()` fatals on: `NODE_ID_WIDTH_P ∉ [1,11]`; `ADDR_WIDTH_P<1`, `>44`
(D)/`>52` (E); `DATA_BYTES_P` not power-of-two in `[1,64]`; `issue ∉ {D,E}`;
active agent with `ROLE_P==MONITOR`.

---

## 15. Sequence library

All user control flows through named setters on `vip_chi_base_seq` (except the
raw path, §12.3). Support objects (`seq_config`, `addr_iterator`,
`seq_payload_buffer`, `seq_counter_iter`) are owned by the base seq.

### 15.1 `vip_chi_base_seq` setter API

Shipped: `set_requests`, `set_initial_addr`, `set_addr_list`, `set_addr_stride`,
`set_addr_enabled`, `set_size`, `set_size_range`, `set_enforce_addr_alignment`,
`set_data_type`, `set_data`, `set_be`, `set_counter_value`,
`set_counter_increment`, `get_counter`, `set_src_id`, `set_tgt_id`,
`set_lp_id`, `set_qos`, `set_return_nid`, `set_return_txn_id`, `set_ns`,
`set_order`, `set_mem_attr`, `set_allow_retry`, `set_exp_comp_ack`,
`set_excl`, `set_pcrd_type`, `set_sep_read`, `set_tracetag`, `set_dodwt`,
`set_likelyshared`, `set_endian`, `set_group_id_ext`, `set_tagop`,
`set_dat_tagop`, `set_tag`, `set_tu`, `set_get_response`, `get_responses`,
`set_pipelined_send` (launch all requests, then drain responses — pairs with a
`cfg.multi_outstanding` driver, §P4), `set_request_delay`, `set_verbose`,
`set_log_denominator`, `reset`
(direction-preserving). `body()` pins all stamp fields in `randomize() with {}`.

### 15.2 Concrete sequences

| Sequence | Role | Status | Notes |
|----------|------|--------|-------|
| `vip_chi_read_seq` / `vip_chi_write_seq` | RN-I | done | direction subclasses; `set_sep_read(TRUE)` ⇒ `ReadNoSnpSep` |
| `vip_chi_write_zero_seq` | RN-I | done | `WriteNoSnpZero` (E-only; `uvm_fatal` under D) |
| `vip_chi_write_cmo_seq` | RN-I | done | combined Write + CMO (E-only; `uvm_fatal` under D). `set_partial` + `set_cmo` select one of six; opts the six into the item pool via `set_combined_write_cmo_enable` |
| `vip_chi_pipelined_seq` | RN-I | done | `set_pipelined_send` launches all requests then drains; pairs with a `cfg.multi_outstanding` driver (single mixed loop, §15 P4); enforces `min(cfg.max_outstanding_*, max_outstanding)` |
| `vip_chi_atomic_seq` | RN-I | done | `set_atomic_op`, operand via `set_data`; collects return value |
| `vip_chi_ordered_seq` | RN-I | not shipped | ordered traffic is currently driven via base-seq setters and dedicated tests; no standalone class |
| `vip_chi_persist_seq` | RN-I | done | `CleanSharedPersist[Sep]` |
| `vip_chi_raw_seq` | any | done | arbitrary/illegal flit injection (§12.3) |
| `vip_chi_pcrd_retry_seq` | RN-I | not shipped | serial retry is driven via `cfg.force_retry_count` (SN-F) + `set_allow_retry` and the RN-I `handle_retry` path, exercised by `tc_chi_retry`; no standalone seq class |
| `vip_chi_snf_mem_preload_seq` / `_decerr_seq` / `_derr_seq` | SN-F | **planned** | not yet in tree; backdoor `vip_mem` / register decerr/derr ranges are exercised today via cfg + directed tests |

**Outstanding-limit precedence:** `cfg.max_outstanding_*` is the hard driver
ceiling; `pipelined_seq.max_outstanding` is a softer goal; effective = `min(...)`.

P4 status (2026-07-05): **read + write pipelines shipped.** The earlier
allocator-only probe timed out because it indexed an in-flight table by
`2**txn_id_width`; the shipped form instead sizes the pool by the *outstanding
count* (`outstanding_ids[$]` + `outstanding_reqs[$]` for reads, `wr_ctx[$]` for
writes, all scanned linearly), which elaborates in ~11s. Multi-outstanding is
opt-in (`cfg.multi_outstanding`, default 0): the RN-I forks issue/completion
threads for plain `ReadNoSnp`, the SN-F buffers inbound REQs (capture + response
threads) so pipelined requests are not dropped, and `set_pipelined_send` launches
all requests before collecting responses. `tc_chi_multi_outstanding` reaches 6
reads in flight and self-checks each payload. The **write** path
(`cfg.multi_outstanding_write`) overlaps plain `WriteNoSnpFull`: because a
requester drives WriteData on TX mid-transaction, one TX thread owns REQ +
WriteData + retire + sequencer while a second only records inbound `CompDBIDResp`
grants (single TX writer). The SN-F is unchanged. `tc_chi_multi_outstanding_write`
reaches 6 writes in flight. These read-only and write-only pipelines were later
folded into a single **mixed** loop (`seq_loop_mixed_pipelined`, run whenever
`cfg.multi_outstanding` is set): a shared TX/sequencer thread plus two monitors
(reads complete on DAT, writes on RSP), which serves read-only, write-only and
mixed traffic alike. `tc_chi_multi_outstanding_mixed` pipelines 6 writes then 6
reads to the same addresses and checks each read-back against the captured write
payload; `tc_chi_multi_outstanding_concurrent` forks reads and writes on one
sequencer to prove they coexist in flight; `tc_chi_multi_outstanding_partial`
pipelines `WriteNoSnpPtl` and checks the masked merge image;
`tc_chi_multi_outstanding_split` overlaps split `DBIDResp`+`Comp` writes;
`tc_chi_multi_outstanding_compack` overlaps `ExpCompAck` writes;
`tc_chi_multi_outstanding_ordered` overlaps ordered writes;
`tc_chi_multi_outstanding_ordered_read` overlaps ordered reads. See the dated
status updates near the top for the full history. Owed next: extend overlap to
atomics, persist, and `handle_retry`.

---

## 16. SVA (`vip_chi_sva`)

Bindable module (non-parameterized interface port). Shipped checks:
link-before-traffic, `*flitpend ⇒ *flitv`, known-valued flit while valid,
`LCRDV` only after link activation, RN-I write DBID grant before DAT, `Comp`
before `CompAck`, sequential DAT `data_id`, and procedural DAT beat-count
checks for `CompData`, `DataSepResp`, and write-data bursts against the
originating request shape, plus procedural credit-overflow tracking, a
link-deactivate idle check keyed to the fully inactive link state,
`txn_id_unique_in_flight`, timeout-based `completion_follows_req` (excludes
`PCrdReturn`/`PrefetchTgt`), ordered-read `ReadReceipt`-before-DAT checks, and
returning-atomic DAT-completion semantic checks. `txn_id_unique_in_flight`
currently guards the shipped serial path rather than a true multi-outstanding
allocator.
`parameter int TIMEOUT_CYCLES_P = 1024`, overridable at the bind.

> **Open SVA caveats (§22):** four `p_*_idle_during_reset` properties are
> **vacuous** — their `$past(!rst_n, 1, 1'b0)` antecedent never samples (H3);
> `link_is_active()` is too permissive (true if *any* link signal is set, not
> just RUN), so "requires link" ordering checks can false-pass (M3); the
> L-credit SVA asserts only grant overflow, not the consumption rule, and has a
> same-cycle `LCRDV`+`FLITV` NBA race (M4); and
> `p_link_restarts_after_reset_release` can false-fail at the default
> `link_act_delay_max=4` (M5). Several of these must be fixed together with the
> driver behavior they would newly expose — see §22.

---

## 17. Compile order (FuseSoC cores)

```
1. vip_memory_pkg, bool_pkg          (submodules/vip_memory)
2. vip_chi_types_pkg
3. vip_chi_if
4. vip_chi_agent_pkg                 (lcrd_mgr, cfg_agent, cfg_item, item, sequencer,
                                      monitor, coverage, driver_rni/snf[/hni], agent,
                                      seq_lib/*)
5. vip_chi_sva                       (after vip_chi_if)
6. testbench/sv/tb/tb.svh        (tb pkg + tc pkg + chi_tb_top)
```

---

## 18. Example testbenches (`testbench/`)

`testbench/` owns the DUT-less example regressions. The SystemVerilog UVM flow is
under `testbench/sv` and the pyUVM/cocotb flow is under `testbench/py`; both use
one shared structural harness and a shared testcase catalog. See
`testbench/README.md`, `testbench/TEST_CASES.md`, and
`testbench/sv/UVM_TB.md` for the current flow and hierarchy documentation.

---

## 19. Contract tests

**Shipped (`tc/`, 46 tests, all passing under the FuseSoC regression).**
Regenerated from the tree; grouped by area:

- *Object / smoke:* `tc_chi_cfg_item_smoke`, `tc_chi_item_smoke`,
  `tc_chi_base_seq_smoke`.
- *Core datapath:* `tc_chi_read_smoke`, `tc_chi_write_read_smoke`,
  `tc_chi_write_partial_smoke`, `tc_chi_split_write_rsp`, `tc_chi_dbid_resp_ord`,
  `tc_chi_prefetch_tgt`, `tc_chi_decerr_smoke`, `tc_chi_derr_smoke`.
- *Atomics / ordered / persist:* `tc_chi_atomic`, `tc_chi_atomic_variants`,
  `tc_chi_ordered_read`, `tc_chi_ordered_write`, `tc_chi_persist`.
- *CHI-E:* `tc_chi_e_req_smoke`, `tc_chi_e_dat_smoke`, `tc_chi_e_snf_dat_smoke`,
  `tc_chi_mte`.
- *Link / reset / credits / retry:* `tc_chi_reset`, `tc_chi_link_reactivation`,
  `tc_chi_credit_starvation`, `tc_chi_retry`.
- *Stimulus API:* `tc_chi_signal_drivability`, `tc_chi_raw_inject`.
- *Multi-outstanding pipeline (§15 P4):* `tc_chi_multi_outstanding`,
  `_write`, `_mixed`, `_concurrent`, `_partial`, `_split`, `_compack`,
  `_ordered`, `_ordered_read`, `_atomic`, `_persist`, `_persist_sep`.
- *HN-I proxy (§20.1):* `tc_chi_hni_passthrough`, `_fanin`, `_xbar`, `_sam`,
  `_qos`, `_decerr`, `_atomic`, `_persist`.

**Scoreboard interaction (§21).** The scoreboard is active on the 40
traffic-driving tests and silent on all. Three opt out via
`scoreboard_enable=0` (they inject illegal / DUT-less-completion flits by
design): `tc_chi_raw_inject`, `tc_chi_signal_drivability`,
`tc_chi_e_snf_dat_smoke`. Three object/smoke tests (`tc_chi_base_seq_smoke`,
`tc_chi_cfg_item_smoke`, `tc_chi_item_smoke`) build no traffic so the
scoreboard observes nothing.

**Landed (2026-07-14):** the *runtime* CHI-E HN-I routed test now exists —
`tc_chi_e_hni_passthrough` on a full 2×2 CHI-E proxy topology
(`chi_e_proxy_tb_env`, new `e_hni_*` interfaces + adapters in
`chi_tb_top`). The HN-I proxy driver is a pure per-flit relay, so it carries
CHI-E flits with no `_e` subclass; the scoreboard predicts CHI-E routing + data.
Reset-recovery (`tc_chi_hni_reset`) and SN-side backpressure
(`tc_chi_hni_backpressure`) through the proxy also landed. *Build note:* a
class-scoped `localparam` typed as a parameterized-class-nested type
(`vip_chi_item #(CHI_E_WIDE_CFG_C)::addr_t`) hangs VCS `vcs1fe` codegen
indefinitely at CHI-E width — keep such constants at package scope
(`chi_tb_pkg`), which is why every address constant lives there.

---

## 20. Open questions / roadmap

1. **`vip_mc` CHI front-end connector — DONE.** `vip_mc` grew a CHI ingress
   (`vip_mc_chi_if` + `vip_mc_chi_driver` + `vip_mc_chi_cfg`/`_cmd_entry`), and
   `vip_mc/vip_mc_chi_connect.sv` cross-wires `vip_chi_if` ↔ `vip_mc_chi_if` (the
   only file naming both). The `vip_mc` example instantiates it in CHI-D, CHI-E,
   and narrow-32 B, exercised by `tc_vip_mc_chi_*`. The shipped HN-I (§11.4, §20.2)
   is the natural intermediary; the "Connector (recommended first)" model of §20.2
   is the one that landed.
2. **SNP channel + RN-F/HN-F (Tier C)** — added to `vip_chi_if` with a snoop
   driver path without disturbing SN-F/RN-I code.
3. **Performance counters** — completed reads/writes, retries, credit-stall
   cycles, reset events on `vip_chi_cfg_agent`.
4. **`txsactive`/`rxsactive` placement** (§5) — keep an unclocked view for
   reset/deactivation/SVA.
5. ~~**DAT channel directionality**~~ — CLOSED: separate `txdat*`/`rxdat*` per
   role, cross-wired as two unidirectional paths in the example top.

### 20.1 HN-I expansion (post-MVP)

The MVP HN-I (§11.4) was a **single-RN ↔ single-SN, serial, transparent** proxy.
With RN-I / SN-F / HN-I all in place the next requirements are clear, and the
first is now prototyped:

1. **Multi-port fan-in (like `vip_mc` `N_PORTS`) — PROTOTYPED.** `vip_chi_driver_hni`
   is parameterized `N_RN_PORTS` × `N_SN_PORTS` (both default 1); it holds arrays
   of RN-facing and SN-facing vifs, with per-RN and per-SN credit/link loops,
   three SN-side arbiters (REQ / CompAck-RSP / write-DAT, round-robin, write
   bursts stay port-locked) and two SN→RN routers (scan SN ports round-robin).
   **Completion routing is by node id**, learned from each forwarded REQ's
   `srcid` and matched against the SN's completion `tgtid`; the RN→SN CompAck/
   write-DAT follow a per-RN `active_sn` association set at REQ time — so **no
   TxnID table / remap is needed** (this is what keeps it clear of the P4
   elaboration landmine). Hosted by the dedicated `vip_chi_hni_agent`
   (multi-vif, no sequencer). The example runs it at `N_RN_PORTS=2, N_SN_PORTS=2`:
   `VIP_CHI_TB_MODE_HNI_E` (`tc_chi_hni_passthrough`) uses one RN/one SN;
   `VIP_CHI_TB_MODE_HNI_FANIN_E` (`tc_chi_hni_fanin`) fans two RNs into one SN;
   `VIP_CHI_TB_MODE_HNI_XBAR_E` (`tc_chi_hni_xbar`) fans two RNs across two SNs
   by address decode.
2. **Address-based SN routing / target decode — DONE.** The REQ arbiter picks
   the SN-facing port from `sn_port_of_addr(addr)`. Two decode forms ship: the
   configurable **SAM range table** (`vip_chi_hni_sam`: ordered [base:limit] ->
   SN-port entries + default, handed to the proxy via config_db, production form)
   and, as a zero-config fallback, the single-bit stride
   `(addr >> sn_addr_lsb) % N_SN_PORTS` (`sn_addr_lsb=12`). `tc_chi_hni_xbar`
   proves the stride path and `tc_chi_hni_sam` proves the SAM path with addresses
   that share the stride bit (so only the ranges can split them); both check that
   each SN-F saw only its own address and each RN read back its own payload.
3. **RN-side arbitration — DONE (QoS-weighted).** REQ ingress is now decoupled
   from forwarding: a per-RN `capture_req` latches each arriving REQ into a
   1-deep slot (which also closes a latent drop — the HN granted the credit, so
   it must accept a REQ even while busy elsewhere), and a single-outstanding
   `qos_forwarder` drains the highest-QoS pending REQ (ties round-robin). A
   configurable `arb_window_cycles` collection window lets near-simultaneous
   requestors all present before arbitration. The forwarder is gated on
   transaction completion (write settles at its last write-DAT to the SN; read
   at its last CompData to the RN — no opcode decode beyond a read/write split),
   which is also what keeps the single-REQ-at-a-time SN-F from being handed a
   second request mid-transaction. `tc_chi_hni_qos` proves it: two reads to one
   SN with different QoS presented together, and SN-F 0 observes the high-QoS
   request first. Remaining: true *overlapped* (multi-outstanding) forwarding
   still needs a buffering responder and/or the P4 work — the proxy stays
   one-transaction-at-a-time by design.
4. **Configurable HN behavior via HN-side sequences** (see §20.3): response
   shaping (added latency, `RetryAck`+`PCrdGrant` retry flow, error-response
   injection, in-window reordering within CHI ordering rules). This is what turns
   the transparent relay into a *policy* proxy and is the first thing that needs
   an HN-I **sequencer** (the MVP proxy is autonomous and has none).
5. **Overlapped/pipelined proxying (P4).** Replace the strict lock-step,
   one-at-a-time relay with real multi-outstanding forwarding once §15 P4 lands;
   the per-channel relay structure is designed to extend to this.
6. **Issue D/E:** the relay copies whole flit structs, so `vip_chi_hni_agent
   #(CHI_E_WIDE_CFG_C, …)` reuses the base `vip_chi_driver_hni` (no `_e` proxy
   variant). **Landed (2026-07-14):** a *runtime* CHI-E HN-I datapath now exists
   — `tc_chi_e_hni_passthrough` on the 2×2 `chi_e_proxy_tb_env`, relaying a
   wide-E write+read end-to-end with the scoreboard predicting CHI-E routing +
   data. E is now proven by routed simulation, not just construction. (The
   pre-existing `chi_e_wide_hni_if` elaboration anchor is retained for parity;
   the live `e_hni_rn{0,1}_if` ports also elaborate `hni_cb` at CHI-E.)

**HN-I op-set coverage.** The single-outstanding forwarder classifies each REQ
(`classify_req`) to pick the settle event, so it handles the full non-coherent
set without hanging: read / atomic-returning (settle on last CompData to RN),
write / atomic-store (last write-DAT to SN), completion-only persist & write-zero
(terminal RSP to RN), and PrefetchTgt (no completion — settled at send). Tests:
`tc_chi_hni_{passthrough,fanin,xbar,sam,qos,decerr,atomic,persist}`. Still owed:
reset-recovery through the proxy, and backpressure/credit-hold through the proxy.

### 20.2 `vip_mc` CHI front-end and L-credits

**Landed via the connector model.** `vip_mc` now has a CHI ingress and is bridged
by `vip_mc/vip_mc_chi_connect.sv`. The design note below is retained as the
rationale; the first ("Connector") model is the one that shipped.

CHI **link-layer L-credits** (per-channel LCRDV grant/consume, §16 of the CHI
spec) are handled by the *link endpoint*, not by the `vip_mc` scheduler. Two
models:

- **Connector (recommended first — SHIPPED):** a `vip_chi` SN-F (or HN-I) endpoint owns the
  CHI link + all L-credit accounting (existing `vip_chi_lcrd_mgr` + credit_loop),
  and a thin connector hands `vip_mc` *decoded* transactions. `vip_mc` never sees
  raw credits — topology is `RN → HN-I → (connector) → vip_mc`.
- **Native FE:** a `vip_mc_chi_fe` implements the CHI link layer directly,
  reusing `vip_chi_lcrd_mgr` and the credit_loop pattern, and **couples the
  inbound REQ/DAT receive-credit grant rate to `vip_mc`'s ingress-buffer
  occupancy** — i.e. the CHI FE withholds an LCRDV exactly where the AXI4 FE
  today de-asserts `AWREADY`/`ARREADY` or reports `RSP_BUF_FULL`. Outbound
  completions consume RN-granted send credits via `vip_chi_lcrd_mgr`, gated by
  the same response-scheduling logic that already drives the AXI4 responses.

Net: CHI L-credits are the wire-level expression of the back-pressure `vip_mc`
already models, so they map onto the existing buffer-gating/status signals
rather than needing a parallel accounting scheme.

### 20.3 Sequence role-labeling

Today sequences are targeted only by *which sequencer they are started on*
(`rni_sequencer` vs `snf_sequencer`); the request-generating family
(`read/write/atomic/persist/pipelined/raw`) is RN-I-oriented and the SN-F uses
`pipelined_seq` for manual responses. As HN-side (policy) sequences appear this
implicit targeting gets error-prone. Requirement: give `vip_chi_base_seq` an
`intended_role` (or role-mask) field and a `pre_start` guard that `uvm_fatal`s if
a sequence is started on a sequencer whose agent role is not in its mask — cheap
insurance, and self-documenting. HN-I MVP needs none of this (autonomous); it
becomes relevant with §20.1.4.

---

## 21. Standalone scoreboard (`vip_chi_scoreboard`)

A VIP-level, parameterized (`#(CFG_P)`) component that provides always-on
transaction-consistency checking between the two agents. This is a **DUT-less
VIP-on-VIP** setup, so the scoreboard's job is protocol/transaction consistency
(every request gets its protocol-legal completion, every relay is faithful,
every read is consistent with the writes actually observed on the wire), **not**
DUT-vs-reference. It mirrors `vip_chi_coverage` exactly: `uvm_analysis_imp_decl`
per stream, connected **in parallel** to the same monitor analysis ports the
per-test FIFOs already use (analysis ports broadcast a copy per subscriber, so
the tests' `get()` draining is untouched).

**One shared transaction table**, keyed by TxnID with a DBID→txn side-index, is
the spine all three checkers ride. A **requester-frame** table is required: the
raw monitor `txn_key` cannot join a REQ to its orientation-flipped completion
(swapped src/tgt), so the scoreboard opens a ctx on each RN-I TX REQ and matches
inbound completions back to it.

- **Checker A — lifecycle / completion contract.** For each REQ kind derive the
  expected completion set (read → `CompData`; ordered read → `ReadReceipt` then
  `CompData`; write → `CompDBIDResp` or split `DBIDResp`+`Comp`, plus TX
  write-DAT and TX `CompAck` if `ExpCompAck`; atomic store → grant + operand +
  `Comp`; non-store atomic → grant + operand + `CompData`; persist →
  `Comp` / `Persist`+`CompPersist`; prefetch → no completion) and flag
  **incomplete**, **orphan completion**, **wrong completion opcode**, and
  **TxnID reuse while in flight** (`n_incomplete` / `n_orphan` /
  `n_wrong_opcode` / `n_reuse`).
- **Checker B — cross-agent request fidelity + routing.** Every integrated RN-I
  TX REQ must appear at the SN-F stream with matching `{addr,opcode,size,txn_id}`,
  and every HN-I proxy REQ (`hrni*`) must be relayed **exactly once, unmodified**
  to some `hsnf*` port (`n_relay_mismatch`). The scoreboard now **also predicts
  the routing target**: the env hands it the HN-I's exact routing policy
  (`N_SN_PORTS`, `sn_addr_lsb`, and the same SAM object) in `connect_phase`, and
  the scoreboard replicates the driver's `sn_port_of_addr` decode (SAM ranges,
  else the address stride). Each `hrni*` REQ's predicted SN port and each `hsnf*`
  arrival's observed port go into port-tagged multisets, so a mis-route surfaces
  as a shortfall at the predicted port + a phantom at the actual port
  (`n_route_mismatch`, reusing the same multiset diff). Auto-gated to >1 SN
  target (off in the CHI-E env, which has no HN-I). This subsumes the per-test SN
  address checks in the HN-I tests (§20.1.2) into an always-on scoreboard check.
- **Checker C — independent write→read data integrity.** A byte-granular
  predicted image built **only from wire-observed writes** (not the SN-F's
  internal `vip_mem`). Write-DAT beats apply byte-enables into `pred_mem`; RN-I
  `CompData` reads are compared byte-for-byte (`n_data_mismatch`). It compares
  **predictable bytes only** — bytes never observed written (fresh reads,
  partial-write background) are skipped (`n_reads_skipped`), and non-OKAY read
  data is don't-care. **Atomics ARE modeled** (full RMW prediction): on the
  operand-DAT the target's pre-op value is snapshotted off `pred_mem` and the
  target is invalidated for the RMW window (so a concurrent reader skips it); at
  the atomic's completion the post-op value is recomputed with the same decode
  the SN-F uses (`apply_atomic_variant` for arithmetic, plus swap and
  compare-and-swap) and committed, and a returning atomic's `CompData` is
  compared byte-for-byte against the snapshotted pre-op value. This works only
  when the full target beat was previously observed written (pre-op known) and
  at full-beat granularity; an unpredictable or errored atomic leaves the target
  invalidated (nothing asserted). Exercised by `tc_chi_atomic_predict`
  (write→atomic→read across Store0/Swap/Compare) and
  `tc_chi_multi_outstanding_atomic` (returning AtomicLoad0), and
  negative-control verified. Full HN-I SAM/xbar routing prediction in checker B
  stays a follow-up.

**Gating & negative traffic.** Two `bit` knobs set by the env from `tb_cfg` in
`connect_phase` (exactly like `coverage.enabled`): `scoreboard.enable` (master)
and `scoreboard.check_data` (checker C). The env calls `handle_reset()` to flush
the ctx table + `pred_mem` on reset, so abandoned in-flight txns are not reported
as incomplete. Intentionally-illegal / DUT-less-completion tests opt out
(`tc_chi_raw_inject`, `tc_chi_signal_drivability`, `tc_chi_e_snf_dat_smoke`);
DECERR/DERR tests stay in (error completions are *legal*, and checker C skips
non-OKAY read data).

**Integration stance — augment now, migrate later.** The scoreboard runs
alongside the existing per-test FIFO checks. A first migration pass removed the
duplicated full-width read==write compares from `tc_chi_write_read_smoke` and
`tc_chi_multi_outstanding_mixed` (checker C covers them byte-for-byte,
`reads_skipped=0`); tests that read never-written / partial-background /
synthesized-pattern memory keep their own data checks, since checker C skips
those. A second pass (2026-07-14) extended the same removal to 13 more tests —
the HN-I proxy readbacks (`tc_chi_hni_passthrough`, `tc_chi_e_hni_passthrough`,
`tc_chi_hni_reset`, `tc_chi_hni_backpressure`, `tc_chi_hni_sam`,
`tc_chi_hni_xbar`, `tc_chi_hni_fanin`) and the multi-outstanding family
(`concurrent`, `ordered`, `ordered_read`, `split`, `compack`, `retry`) — each
verified to log `reads_skipped_unpredictable=0` so checker C provably compares
every readback byte. The synthesized-read, partial-write (background=0), error-read,
and atomic-model-validator tests keep their inline data checks (checker C skips
or can't independently confirm those). The completion-count / completion-opcode
inline checks (checker A's territory) are intentionally retained for precise
per-test failure messages; stripping them is a larger, still-deferred pass.

**Hardening (2026-07-14).** Two additions now that the always-on checks are
load-bearing. (1) **Negative control:** `tc_chi_scoreboard_negctl` injects an
orphan completion with the scoreboard enabled and fails if checker A does not
flag it — a standing guard that the checkers have not silently gone vacuous
(disabled, disconnected, or master-gated off), replacing the old one-time manual
Step-5 perturbation. (2) **Separated reads modeled in checker A:** a
`ReadNoSnpSep`'s `DataSepResp` leg returns on `ReturnNID`/`ReturnTxnID`, not the
original TxnID, so the ctx now registers a `sep_ret_ctx` return-index at issue
(keyed by `(stream, return_nid, return_txn_id)`, cleared on retire/reset) and the
inbound-DAT handler falls back to it before declaring an orphan. Exercised by
`tc_chi_sep_read` (scoreboard active, `ReturnTxnID != TxnID`) and negative-control
verified: without the index the DataSepResp is a false orphan and the read a false
incomplete. Regression 51→53.

---

## 22. Known open correctness / interop findings

A read-only correctness review found several checks that are **dead or vacuous**
and several driver/monitor behaviors that rely on **private conventions shared
by the RN-I and SN-F**. They are **latent today** — the VIP
passes as a closed VIP-on-VIP loop precisely because both sides agree on the
same non-standard shortcuts — but they undermine the interop goal against a
spec-compliant external CHI DUT (e.g. the `vip_mc` CHI front-end, now shipped, §20.2).
None require a scoreboard change (its DBID binding and REQ↔REQ fidelity are
unaffected).

### 22.1 Resolved (regression re-verified 46/46)

- **H1 / H2 / M7 / L1 — monitor DAT reassembly, one change.** The monitor now
  retires a transfer on its **correlated beat count** (advisory `FLITPEND` is a
  fallback only when the count is unknown), reassembles beats in **arrival
  order** rather than by absolute `DataID`, and derives the count from a real
  REQ→DAT correlation: a read's return keyed by the (echoed) requester TxnID, a
  write / atomic operand keyed by the granted DBID (staged on the REQ, promoted
  on the grant RSP). All three correlation maps are consumed on retirement, so
  they stay bounded in a reset-free run. One-assembled-item-per-transfer is
  preserved. (`vip_chi_monitor.sv`)
- **M8 — published `direction`.** RSP/DAT items now carry a meaningful
  `direction` (DAT from the write-data opcode; RSP set WRITE on the DBID-carrying
  grants) instead of the constructor default. (`vip_chi_monitor.sv`)
- **H3 — idle-during-reset SVA.** The four `p_*_idle_during_reset` properties had
  a hard-wired `$past` clock-enable of `1'b0` (vacuous); changed to `1'b1` so
  they actually check TX quiescence across two reset cycles. (`vip_chi_sva.sv`)
- **M4 — L-credit NBA race + underflow assertion (complete, 2026-07-14).** Two
  parts. (a) *NBA race:* grant and consume were two separate NBAs to the same
  counter, so a same-cycle grant was silently overwritten by the consume —
  composed into a single grant-before-consume next-value (`lcrd_next`). (b)
  *Underflow:* the count-0 floor is now a `$error`. The two prior underflow
  attempts false-fired at bring-up not because the counter lacked an
  "activation-aware initial-pool model" (the original diagnosis) but because the
  grant/consume signals were **mispaired**: each counter fed itself the LCRDV the
  local node *emits* (`tx<chan>lcrdv`) alongside the flit the local node *sends*
  (`tx<chan>flitv`) — but on a CHI channel the flit and its credit travel in
  opposite directions (see `chi_link_adapter`: `rn.rxreqlcrdv = sn.txreqlcrdv`
  while `sn.rxreqflitv = rn.txreqflitv`). A `tx<chan>flitv` send is authorized by
  the inbound `rx<chan>lcrdv`; `tx<chan>lcrdv` authorizes the peer's
  `rx<chan>flitv`. Re-pairing all six counters (`grant = rx<chan>lcrdv` for tx
  sends, `grant = tx<chan>lcrdv` for rx receives) makes each an exact shadow of
  the driver-side `vip_chi_lcrd_mgr`: it starts at 0, +1 on every real LCRDV
  pulse, -1 on every flit, so it captures the initial pool automatically (the pool
  arrives as LCRDV pulses once the link activates — no seeding needed) and can
  never reach consume-at-0 on legal traffic, because `try_acquire_credit()`
  refuses to send at 0. Validated: negative control (old mispairing) fires the
  txreq underflow 3× on `tc_chi_reset`; corrected pairing is clean across the full
  50/50 regression, including the adversarial `tc_chi_credit_starvation`,
  `tc_chi_signal_drivability`, and `tc_chi_raw_inject`. (`vip_chi_sva.sv`)
- **M5 — link-restart window.** `p_link_restarts_after_reset_release` used a
  literal `##[0:3]`, below the default `link_act_delay_max` of 4; replaced with a
  `LINK_ACT_WINDOW_P` parameter (default 32). (`vip_chi_sva.sv`)
- **M1 (partial) / L2 / L4 — driver fidelity.** The SN-F now **validates**
  write- and atomic-operand DAT SrcID/TgtID (it previously ignored them — the
  "reversed ship" premise was not reproducible, but the check hardens interop);
  the RN-I deferred write completion now accepts **only** `Comp`, not
  `CompDBIDResp`; the SN-F write grant (and split deferred comp) now echoes QoS.
  (`vip_chi_driver_snf.sv`, `vip_chi_driver_rni.sv`)
- **L6 — HN-I reset watcher.** The proxy watcher keyed only off `rn_vif[0].rst_n`
  for both proxy-start and tear-down; it now spans **every** RN- and SN-facing
  link (start only when all are released, cascade `handle_reset` when any
  resets). (`vip_chi_hni_agent.sv`)
- **M2 — separated-read response leg.** `ReadNoSnpSep` now emits `RespSepData` on
  the RSP channel (to the requester, original TxnID) ahead of the `DataSepResp`
  data leg on DAT (to ReturnNID/ReturnTxnID) — previously only the data leg was
  sent, so a spec-compliant RN awaiting the separate response would hang. The
  SN-F auto-responder drives it, the RN-I serial read path collects it (sep reads
  stay off the pipeline), and the scoreboard recognises the opcode. The read
  still retires on its data leg. (`vip_chi_driver_snf.sv`, `vip_chi_driver_rni.sv`,
  `vip_chi_scoreboard.sv`)
- **M3 — flit-vs-credit link gate split.** The single permissive
  `link_is_active()` (any activate sideband = not-STOP) gated both flit and
  L-credit "requires link" checks. Split into two: **flit** properties
  (`txreqflitv`/`txrspflitv`/`txdatflitv`) now require `link_is_running()` = RUN,
  while **L-credit** properties keep `link_is_active()` (credits legitimately flow
  from ACTIVATE, not just RUN — the earlier strict-gate revert conflated the two).
  `link_is_running()` is role-agnostic — `(txreq ‖ rxreq) && (txack ‖ rxack)` —
  because this VIP models activation asymmetrically (RN-I raises `txlinkactivereq`
  and waits for the peer ack; the SN-F never raises `txlinkactivereq`, only mirrors
  the peer's request onto `txlinkactiveack`). Tighter than the old gate (a flit
  during one-sided ACTIVATING or a DEACTIVATE tail now fails) and robust to the
  one-cycle ack-mirror skew that forced the first revert. (`vip_chi_sva.sv`)

### 22.2 Still open

- **M6** — `cg_outstanding` tracks only ordered reads and never retires them.
  Lives in `vip_chi_coverage.sv`, owned by a separate workstream; not touched.

### 22.3 Decided (2026-07-14) — documented, no behavior change

Investigated and resolved as intentional; each is now cemented with a code
comment at the site so the decision is not re-litigated as a "gap".

- **L3 — DERR-range atomic commits the RMW.** *Kept.* Consistent with the SN-F's
  read/write model: DECERR = rejected access (no state change, NONDATA_ERROR),
  DERR = access proceeds with returned data flagged corrupt (DATA_ERROR). A
  DERR-range atomic therefore commits and returns the errored old data. Gating the
  commit on DERR too is an equally defensible stance but would break the uniform
  "operation happens, data flagged" DERR datapath; not taken.
  (`vip_chi_driver_snf.sv`, `drive_auto_atomic_completion`.)
- **L5 — HN-I write-settle at the last data beat.** *Kept — intended.* For a
  non-split write the completion RSP is delivered before the data, so the final
  write-data beat is the last data-bearing event; the trailing ExpCompAck carries
  no data and is relayed independently by the CompAck arbiter (which runs past
  settle). Settling here maximizes per-SN throughput and cannot reorder data;
  deferring to the CompAck relay would only serialize the ack for no CHI-required
  benefit. (`vip_chi_driver_hni.sv`, `router_dat_rn_to_sn`.)
- **L7 — atomic Size not clamped to ≤8 B.** *Kept — deliberate.* The atomic
  testcases drive a full bus-beat operand (`set_size($clog2(DATA_BYTES_P))` =
  Size 4 / 16 B on CHI-D, Size 6 / 64 B on CHI-E) to exercise the operand DAT / RMW
  / return datapath at the widest beat, and the scoreboard/SN-F predict beats from
  that Size. A silent clamp would shrink those operands and break every atomic
  test's beat/data checks, so the sequence honors `set_size()` as-is; enforcing the
  CHI operand-size limit is left to the caller. (`vip_chi_atomic_seq.sv`.)
