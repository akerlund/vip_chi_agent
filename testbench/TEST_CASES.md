# vip_chi testbench testcase catalog

The shared regression currently runs **130 SystemVerilog** testcases (one
`` `include `` per `tc_*.sv` in `sv/tc/chi_tc_pkg.sv`) and **131 pyUVM/cocotb**
testcases (`tc_*.py` discovered by `py/scripts/run.py`). Those counts are
maintained here as part of adding a testcase, not re-derived: adding one means
adding its row below and updating this paragraph.

The lists are otherwise identical; the one difference is `tc_chi_sva_smoke`,
which exists only on the Python side. It is the negative control for
`py/sva/bind_chi.py`, and the SV checker it mirrors reports through SVA
`assert property ... else $error`, which a `uvm_report_catcher` cannot demote
(the same wall `tc_chi_dataid_duplicate` hit, which is why that test stands the
check down through `dat_reorder_allowed` instead of catching it fire). Writing
the SV twin therefore needs assertion-control plumbing that does not exist yet,
or the SV checks moved onto `uvm_error`. Until then this row is Python-only ON
PURPOSE. Note for `.refuse.yml`: profiles may not name it explicitly, because a
selector matching nothing is an error on the SV side; the `full` profile
matches it via `^tc_.*$`, which expands per flow.

Each testcase exercises a topology purely by which agents it drives (see [sv/UVM_TB.md](sv/UVM_TB.md) §2 for the SV harness model)
and checks observed monitor items against sequence responses or expected
payloads. This catalog is the authoritative list.

Most coherent scenarios run at both CHI-D and wide CHI-E from a single
parameterized body: `vip_chi_<scenario>_base_test #(CFG_P, TYPES_T)` extends the
parameterized `chi_coherent_base_test`, and each runnable name lives in its
own file (one class per file): `tc_chi_coh_d_<x>.sv` fixes CHI_D_CFG_C /
chi_d_types_t and `tc_chi_coh_e_<x>.sv` fixes CHI_E_WIDE_CFG_C /
chi_e_wide_types_t. Both names run independently; there is no separate
hand-maintained CHI-E scenario copy.

## Mode Legend

| Mode | Meaning |
| --- | --- |
| `n/a` | Object/unit smoke that does not build a link-level testbench. |
| `RNI` | RN-I sequence/unit smoke without a full integrated datapath. |
| `INT` | Integrated RN-I↔SN-F datapath. |
| `E-RNI` | Exact CHI-E RN-I-side smoke. |
| `E-SNF` | Exact CHI-E SN-F-side manual completion smoke. |
| `E-SNF-A` | Exact CHI-E autonomous SN-F responder smoke. |
| `E` | Wide CHI-E RN-I↔SN-F integrated datapath. |
| `HNI` | HN-I proxy path through one RN and one SN port. |
| `HNI-FANIN` | HN-I proxy path with multiple RN ports targeting one SN. |
| `HNI-XBAR` | HN-I proxy crossbar path with address-routed SN ports. |
| `COH` | Coherent RN-F/HN-F subsystem over SNP-capable links. |

### pyUVM/cocotb port

The Python port (`py/`) uses one Verilator HDL shell and one Python
testbench top:

```text
py/tb/chi_hdl_top.sv
py/tb/chi_tb_top.py
py/vip_chi_agent_example_py.core
```

`chi_hdl_top.sv` exposes all flat-net endpoint groups with unique prefixes.
`chi_tb_top.py` creates the matching `ChiBus` objects, publishes them
through pyUVM `ConfigDB`, and contains one static cocotb test entry per public
`tc_*.py` testcase. The cocotb test name, command-line name, testcase file, and
pyUVM test class all use the same public `tc_*` name.

Run it from `testbench/py`:

```sh
./scripts/run.py --build
./scripts/run.py -t tc_chi_d_read_smoke --no-build
./scripts/run.py --all --no-build
```

The script uses FuseSoC for the Verilator build/run commands. FuseSoC does not
provide a project-aware `--all` switch, so the script discovers the static
cocotb tests in `chi_tb_top.py` by their public `tc_*` names and runs one
simulator process per testcase.

Both flows run the same list of testcase names, with the single documented
exception of `tc_chi_sva_smoke` described at the top of this file.

---

## Building-block smokes

| Test | Mode | Proves |
| --- | --- | --- |
| `tc_chi_cfg_item_smoke` | n/a | cfg-item defaults and `reset()` behavior. |
| `tc_chi_cfg_invalid` | n/a | `vip_chi_cfg_agent::is_valid()` runtime self-check: one case per rule, each starting from a default config and breaking exactly one thing, plus legal and warn-only configs that must stay accepted. Catches both a rule that stops working and a rule that starts rejecting a legal setup. |
| `tc_chi_item_smoke` | n/a | item randomization, legality, copy/compare, and payload handling across CHI-D and CHI-E shapes. |
| `tc_chi_base_seq_smoke` | RNI | base-sequence helpers, wrapper sequences, and the write-zero legality path. |
| `tc_chi_opcode_pool_safe` | n/a | `PCrdReturn` is not drawable from the non-coherent legal-opcode pools: an RN-I item randomized many times across both directions and both issues never lands on it, and every drawn opcode is accepted by the legality helper. A drawn `PCrdReturn` would wedge the driver with no diagnostic. The coherent RN-F pool is drawn the same way and cross-checked against the helper, so the two hand-written opcode tables cannot drift apart. |
| `tc_chi_sva_smoke` | n/a | negative control for the Python link-layer protocol checker (`py/sva/bind_chi.py`): one induced violation per check family — flitpend without flitv, a flit sent during one-sided ACTIVATING, L-credit underflow and overflow, TXSACTIVE held past deactivation, channel traffic during reset, and a link that never reactivates — each asserted to be REPORTED. Plus two positive controls that must NOT fire: a same-cycle credit grant and consume (the race that false-fired two earlier SV attempts) and a link that reactivates inside the window. Every other testcase passes with the checkers enabled, so without this a vacuous checker would pass exactly as loudly as a working one. Python-only; see the note at the top of this file. |
| `tc_chi_a0_smoke` | n/a | the interface and `chi_link_adapter` at a third flit geometry (7-bit node IDs, 32-byte data): an agent-free link-activation handshake and one REQ flit checked verbatim on the far side. The Python twin additionally checks its packing codec against the HDL net widths — a check with no SV counterpart, since the SV interface carries the flit struct itself. |

## Integrated non-coherent datapath

| Test | Mode | Proves |
| --- | --- | --- |
| `tc_chi_d_read_smoke` | INT | `ReadNoSnp` request and `CompData` return. |
| `tc_chi_d_write_read_smoke` | INT | write to the SN-F backing store then read the same payload back. |
| `tc_chi_d_write_partial_smoke` | INT | byte-enable-masked writeback and readback. |
| `tc_chi_d_ordered_write` | INT | `CompDBIDResp` followed by `CompAck` for ordered writes. |
| `tc_chi_d_ordered_read` | INT | ordered `ReadNoSnp` returns `ReadReceipt` before `CompData`. |
| `tc_chi_txsactive_window` | INT | `TXSACTIVE` is held across the whole outstanding window rather than pulsed per flit. Four pipelined reads, both link ends sampled every cycle: each vantage must show at least one cycle asserted with no flit moving (which a per-flit pulse cannot produce), must never drop between its first assertion and the last flit, and must drop once the traffic drains. |
| `tc_chi_d_split_write_rsp` | INT | `DBIDResp` plus deferred `Comp`, with optional trailing `CompAck` under `ExpCompAck`. |
| `tc_chi_d_prefetch_tgt` | INT | `PrefetchTgt` treated as a no-completion hint. |
| `tc_chi_d_atomic` | INT | atomic store/load/swap/compare smoke using the SN-F backing memory for operand capture, RMW, old-data return, and readback. |
| `tc_chi_d_atomic_variants` | INT | broader atomic sweep: `AtomicStore[0:7]`, `AtomicLoad[0:7]`, `AtomicSwap`, matching/non-matching `AtomicCompare`. |
| `tc_chi_d_atomic_predict` | INT | scoreboard Checker-C atomic RMW prediction: each variant seeds its target with a known full-beat write, issues the atomic, then reads back — the scoreboard independently predicts the returned pre-op value and the committed post-op value, keeping the atomic predictor from silently skipping. |
| `tc_chi_e_write_zero_readback` | E | `WriteNoSnpZero` memory semantics: a non-zero line is zero-written with no DAT phase, then read back as all zeros. |
| `tc_chi_d_decerr_smoke` | INT | DECERR / NDERR behavior for writes and reads in a configured address window. |
| `tc_chi_d_derr_smoke` | INT | DERR-marked read data returned from the backing store. |
| `tc_chi_d_raw_inject` | INT | raw RN-I REQ + raw SN-F DAT/RSP injection, incl. verbatim observation of an illegal opcode (negative testing). |
| `tc_chi_dataid_out_of_order` | INT | DAT beats are placed by `DataID`, not by arrival: `snf_reverse_dat_beats` makes the SN-F return a 4-beat read in DESCENDING `DataID` and the payload must still reassemble in address order, in the monitor's item and in the requester's own response. The SVA `DataID`-ordering checks (which hold this VIP's in-order emission convention, not a CHI rule) stand down via `tb_cfg.dat_reorder_allowed`. |

## Multi-outstanding pipeline

Opt-in transaction overlap on the point-to-point RN-I↔SN-F path
(`cfg.multi_outstanding`), off by default so every other test stays strictly
serial. See [../docs/IMPLEMENTATION_PLAN.md](../docs/IMPLEMENTATION_PLAN.md).

| Test | Mode | Proves |
| --- | --- | --- |
| `tc_chi_d_multi_outstanding` | INT | six plain `ReadNoSnp` reads pipelined to a peak of 6 simultaneously in flight; each self-checks its address-derived `CompData` payload. |
| `tc_chi_d_multi_outstanding_write` | INT | six plain `WriteNoSnpFull` writes (`cfg.multi_outstanding_write`) pipelined to a peak of 6 in flight; each returns its `CompDBIDResp` completion. |
| `tc_chi_d_multi_outstanding_mixed` | INT | the unified loop (`cfg.multi_outstanding_mixed`) pipelines six `WriteNoSnpFull` writes then six `ReadNoSnp` reads to the same addresses on one driver; each read-back is checked against its captured write payload for end-to-end data integrity, with peak > 1 in flight. |
| `tc_chi_d_multi_outstanding_concurrent` | INT | seeds a read region, then forks six reads (of that region) and six writes (to a **disjoint** region) *concurrently* on one sequencer; proves reads and writes are in flight at the same instant (`observed_peak_mixed_inflight` > 1) while the seeded read-back stays intact under the opposite-direction traffic. |
| `tc_chi_d_multi_outstanding_partial` | INT | pipelines six `WriteNoSnpPtl` partial writes, each with its own data and byte-enable mask, to a peak of 6 in flight, then reads them back and checks the masked merge image (enabled bytes = written, disabled = zero background) survived the overlapped custom-BE data bursts. |
| `tc_chi_d_multi_outstanding_split` | INT | pipelines six writes against an SN-F using the split write policy (`cfg.split_write_rsp`): each is granted a `DBIDResp` then completed by a later deferred `Comp` rather than a combined `CompDBIDResp`. Confirms the pipeline overlaps these two-flit completions (peak 6), hands back `Comp`, and the data landed on read-back. |
| `tc_chi_d_multi_outstanding_compack` | INT | pipelines six `ExpCompAck` writes (peak 6): each carries an `NCBWrDataCompAck` burst and the RN-I must drive a `CompAck` back after completion. The SN-F times out if the ack is missing/mismatched, so passing proves the CompAck handshake overlapped correctly; read-back confirms the data landed. |
| `tc_chi_d_multi_outstanding_ordered` | INT | pipelines six ordered (`Order=Request_Order`) `ExpCompAck` writes (peak 6), whose ordering point is the CompAck the pipeline drives; confirms the REQ carried the Order value, the SN-F accepted every CompAck, and the data landed on read-back. |
| `tc_chi_d_multi_outstanding_ordered_read` | INT | seeds a region, then pipelines six ordered (`Order=Request_Order`) reads (peak 6). Each receives a `ReadReceipt` on RSP ahead of its `CompData`; the pipeline consumes the receipt and only retires the read once both arrive, then the read-back data is checked. |
| `tc_chi_d_multi_outstanding_atomic` | INT | seeds six granules, then pipelines six returning atomics (`AtomicLoad0` = arithmetic ADD, peak 6). Each issues write-like (`DBIDResp` grant + operand DAT) and completes read-like: the SN-F returns the pre-op value on `CompData` (matched by the DAT monitor) while the RMW writes seed+operand back. Confirms every atomic returned its own pre-op value and the read-back shows the overlapped read-modify-writes all landed. |
| `tc_chi_d_multi_outstanding_persist` | INT | pipelines six `CleanSharedPersist` CMOs (peak 6). Each carries no write data and takes no DBID grant — it issues its REQ and completes on a single `Comp` RSP. Confirms the pipeline overlaps these RSP-only, no-data transactions and hands each back with its `Comp`. |
| `tc_chi_e_multi_outstanding_persist_sep` | E | pipelines six CHI-E `CleanSharedPersistSep` CMOs (peak 6). Each completes with a two-part separated response — an intermediate `Persist` then a final `CompPersist`. The pipeline's RSP monitor consumes the intermediate `Persist` and retires each CMO on its `CompPersist`; confirms the two-flit, no-data completions overlap. |
| `tc_chi_d_multi_outstanding_retry` | INT | the retry path *inside* the pipeline: the SN-F (`force_retry_count=1`) bounces only the first of N retryable writes with `RetryAck` + `PCrdGrant`; it sits `retry_pending` awaiting its P-credit while writes 2..N complete around it, then re-issues concurrently. Asserts exactly one bounce, peak > 1 in flight, and every write (including the re-issued one) commits on read-back. |

## Credit / reset / link

| Test | Mode | Proves |
| --- | --- | --- |
| `tc_chi_d_retry` | INT | a retryable write (`AllowRetry=1`) against an SN-F armed with `cfg.force_retry_count` is bounced with `RetryAck` + `PCrdGrant`; the RN-I holds the request, consumes the credit grant, re-issues to a normal `CompDBIDResp`, and the data is confirmed committed on read-back. |
| `tc_chi_d_credit_starvation` | INT | hold SN-F DAT credit to stall a second read completion, then release it. |
| `tc_chi_d_reset` | INT | reset while traffic is in flight, including held-credit recovery. |
| `tc_chi_d_link_reactivation` | INT | synthetic reset pulse, link drop, reactivation, and post-reset forward progress. |
| `tc_chi_e_signal_drivability` | INT | structured REQ/DAT/RSP field setters, separated return routing, and exact-E tagging fields reach the wire and are observed. |

## CHI-E focused (sidecar envs)

| Test | Mode | Proves |
| --- | --- | --- |
| `tc_chi_e_req_smoke` | E-RNI | exact-CHI-E RN-I loopback smoke for REQ-only E fields. |
| `tc_chi_e_dat_smoke` | E-RNI | exact-CHI-E RN-I loopback smoke for DAT tagging on write data. |
| `tc_chi_e_snf_dat_smoke` | E-SNF | exact-CHI-E manual SN-F completion smoke for responder-side DAT tagging. |
| `tc_chi_e_mte` | E-SNF-A | exact-CHI-E autonomous SN-F tag-storage round-trip for `TagOp`/`Tag`/`TU`. |
| `tc_chi_e_persist` | E | exact-CHI-E `CleanSharedPersistSep` returns `Persist` then `CompPersist`. |
| `tc_chi_e_dbid_resp_ord` | E | exact-CHI-E ordered split write returns `DBIDRespOrd` before deferred `Comp` and trailing `CompAck`. |
| `tc_chi_e_sep_read` | E | exact-CHI-E separated read: `DataSepResp` data returns on `ReturnTxnID` (≠ request TxnID); exercises the scoreboard Checker-A return-index so the separated completion is matched rather than false-orphaned. |

## HN-I proxy suite

These route through the `vip_chi_hni_agent` proxy (see
[sv/UVM_TB.md](sv/UVM_TB.md) §1–3 and [../README.md](../README.md)). Because the
RN-I monitors watch the RN↔HN links
and the SN-F monitors watch the HN↔SN links, these tests verify both that the RN
saw correct completions **and** that the SN actually received the forwarded
request — i.e. the proxy relayed rather than short-circuited.

| Test | Mode | Proves |
| --- | --- | --- |
| `tc_chi_d_hni_passthrough` | HNI | 1×1 relay: write + readback through RN-I → HN-I → SN-F; SN-F observed the forwarded requests; readback payload matches. |
| `tc_chi_d_hni_fanin` | HNI-FANIN | two RNs (distinct node ids) fan into one SN; each RN reads back its own payload → node-id completion return works. |
| `tc_chi_d_hni_xbar` | HNI-XBAR | request **address** decodes RN0→SN0 and RN1→SN1 (stride); each SN-F saw only its own address; each RN read back its own data. |
| `tc_chi_d_hni_sam` | HNI-XBAR | same split driven by a configurable **SAM range table** using addresses that share the stride bit (so only the ranges can split them). |
| `tc_chi_d_hni_qos` | HNI-XBAR | two reads to one SN with different QoS presented together (arbitration collection window); the SN-F observes the high-QoS request first. |
| `tc_chi_d_hni_decerr` | HNI | SN-F DECERR/NDERR error responses relayed intact through the proxy for write and read. |
| `tc_chi_d_hni_atomic` | HNI | an `AtomicStore` relayed end-to-end (operand DAT forwarded to the SN, completion returned; exercises the write-settle path). |
| `tc_chi_d_hni_persist` | HNI | a completion-only `CleanSharedPersist` relayed; exercises the forwarder's RSP-only settle path (no DAT in either direction). |
| `tc_chi_d_hni_split_write_rsp` | HNI | proxied writes into an SN-F using split `DBIDResp` + deferred `Comp`; confirms the HN-I holds the RN REQ credit until both DAT and `Comp` have crossed. |

## Coherent subsystem (RN-F / HN-F / SNP)

The coherent env (`chi_coherent_tb_env`) drives two RN-F requesters against a
single multi-port HN-F home node, which terminates to its own `vip_mem` and owns a
per-line directory. Coherent reads (`ReadShared`/`ReadClean`/`ReadUnique`) that hit
another holder make the HN-F originate snoops on the SNP channel; each RN-F answers
autonomously from its own cache-state model. Every test self-checks the RN-F cache
state and the HN-F directory, and the always-on **Checker D** (`vip_chi_coherency_checker`)
watches a self-derived ownership shadow for its single-writer invariant (never two
Unique owners of a line). Coverage spans clean reads + snoops, dirty snoop
forwarding (`SnpRespData` + PassDirty), and eviction (`WriteBackFull` /
`Evict`).

| Test | Mode | Proves |
| --- | --- | --- |
| `tc_chi_coh_d_read_no_snoop` | COH | a single RN-F `ReadShared` with an empty directory: the HN-F returns `CompData(SC)` from its memory, the RN-F caches `SC`, the directory records `SC`, and **zero** snoops are issued. |
| `tc_chi_coh_d_read_then_unique` | COH | RN-F0 `ReadShared`→`SC`, then RN-F1 `ReadUnique` to the same line makes the HN-F snoop RN-F0 (`SnpUnique`); RN-F0 drops to `I`, RN-F1 is granted `UC`, directory tracks the transfer. |
| `tc_chi_coh_d_shared_read` | COH | RN-F0 `ReadUnique`→`UC`, then RN-F1 `ReadShared` makes the HN-F snoop RN-F0 (`SnpShared`) to downgrade it; RN-F0 becomes `SC`, RN-F1 is granted `SC`. |
| `tc_chi_coh_d_negctl` | COH | **negative control for Checker D**: with `cfg.hnf_suppress_snoops` the HN-F grants Unique without invalidating other holders, so two RN-F `ReadUnique`s to one line leave two Unique owners. The test fails unless Checker D flags the violation (`multi_owner` > 0); the induced error is caught and demoted so it does not count against the regression. |
| `tc_chi_coh_d_dirty_forward` | COH | dirty snoop forwarding: RN-F0 acquires a line Unique and dirties it (modelled local store), then RN-F1 `ReadShared` forces a downgrading snoop; RN-F0 answers with `SnpRespData` (PassDirty), the home merges the modified beats into memory, and RN-F1's `CompData` carries the dirtied data (asserted == RN-F0's original beats XOR the store pattern, not stale memory). |
| `tc_chi_coh_d_writeback_evict` | COH | both eviction paths: RN-F0 `WriteBackFull` (DBID grant → `CopyBackWrData` → memory commit) and RN-F1 `Evict` (RSP-only `Comp`). Both directory ports and both RN-F cache states return to Invalid. |
| `tc_chi_coh_d_read_after_writeback` | COH | writeback data integrity: RN-F0 writes a fresh payload back, then RN-F1 `ReadShared` returns exactly the written-back data (and it differs from the original image — a no-op writeback would fail). |
| `tc_chi_coh_d_write_unique_ptl` | COH | `WriteUniquePtl` data integrity: RN-F1 writes 16 byte-enabled bytes at offset 16, the HN-F invalidates RN-F0 and commits at the request address, and a full-line readback proves only the enabled lanes changed. |

## Instrumentation & checker guards

Anti-vacuity guards for the always-on measurement / checking components: each
induces the condition its component must observe and fails if the component stays
silent, so a disabled or disconnected checker cannot pass unnoticed.

| Test | Mode | Proves |
| --- | --- | --- |
| `tc_chi_d_perf_smoke` | INT | guard for `vip_chi_perf_counters` (latency / throughput / retry / back-pressure off a reset-gated cycle counter): drives reads and writes then fails unless the read/write completion counts, the latency accumulator, and the cycle counter are all non-zero. |
| `tc_chi_d_scoreboard_negctl` | INT | guard for the always-on `vip_chi_scoreboard`: after one clean write it raw-injects an orphan `Comp` RSP (bogus TxnID); a report catcher demotes the induced "Orphan RSP" error and the test fails unless the checker actually fired. |
| `tc_chi_dataid_duplicate` | INT | guard for the monitor's DataID placement checks: `snf_duplicate_dat_beat` makes the SN-F send the last beat of a read burst carrying `DataID` 0 again, so one position arrives twice and one never; a report catcher demotes both induced errors and the test fails unless BOTH the duplicate and the missing-beat check fired. Arrival-order reassembly sees neither fault -- the beat count still adds up. |
| `tc_chi_pcrd_leak` | INT | guard for the RN-I's end-of-test P-credit accounting: with the pipeline enabled (the path that banks credits) a bare `PCrdGrant` that bounces nothing is injected from the SN-F; a report catcher demotes the induced leak error and the test fails unless the driver's `check_phase` actually reported it. A leaked P-credit changes nothing observable otherwise — the traffic completes and the run goes green. |
