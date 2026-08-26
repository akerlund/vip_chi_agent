# vip_chi_agent — future work (backlog)

The planned charter (Tiers A/B/C — SNP channel, RN-F/HN-F coherent subsystem,
Checker D, coherent coverage, HN-I proxy, scoreboard, perf counters, exclusives,
CMO, DCT forwarding, SN-F-behind-HN-F, MakeUnique, bounded-cache eviction) is
**complete and tested** — every charter item has a named testcase in
[../testbench/TEST_CASES.md](../testbench/TEST_CASES.md). The regression is
**232 SV + 233 PY** — the same list on both flows apart from three documented
exceptions: `tc_chi_sva_smoke` and `tc_chi_reject_scope`, both Python-only, and
`tc_chi_e_hni_port1`, SV-only because the SV CHI-E proxy is 2x2 and the Python
one 1x1, so its port-1 links do not exist to drive (see
[../testbench/TEST_CASES.md](../testbench/TEST_CASES.md)) — last verified green
in full on branch `dev` (2026-08-19). Those counts are not maintained by hand:
`scripts/check_test_counts.py` compares them with the tree on every sweep,
because this sentence had gone stale by twenty-odd testcases before anyone
noticed, and a stale count makes the green verdict it supports unattributable to
any state a reader can check. This file is the single
remaining backlog: optional breadth (more of
the CHI feature surface) and depth (hardening what already ships). Nothing here
is required by any current consumer.

Effort legend: S (hours) / M (a day) / L (multi-day).

---

## Current review follow-up (2026-07-20)

Source-review findings from the MakeUnique / DCT / rename follow-up pass.

- **MakeUnique DCT anti-vacuity** — `chi_coh_make_unique_dct_base_test`
  currently only enables `hnf_enable_snoop_fwd` and inherits the base zero-readback
  assertions. If the HN-F DCT gate falls back to the normal dirty-snoop path, the
  test can still pass. Add an explicit monitor-FIFO check that RN-F1 observed
  `SnpSharedFwd` and that `FwdTxnID` matches the requester read transaction. *Effort
  S; risk low.*
- **RN-F DCT no-data fallback** — `vip_chi_driver_rnf::process_snoop_fwd` falls
  back to a no-data `SnpResp` if a forwarding snoop hits a valid holder with no
  `cache_data`, but the HN-F DCT path waits for `SnpRespDataFwded`. The current
  MakeUnique materialized-zero fix prevents this for MakeUnique-owned lines, but
  the fallback itself can still wedge. Either fatal locally on missing data for a
  fwd snoop or teach the HN-F to consume the fallback deliberately. *Effort S/M;
  risk med.*
- **Stale transition-coverage comment** — `vip_chi_coherency_checker` still says
  the cache-transition sweep closes "30 reachable bins" even though the reduced
  model documents 11 reachable transition tuples. Update the comment or make it
  denominator-neutral. *Effort S; risk low.*

## Current review follow-up (2026-08-07)

- ~~**`req_opcode_is_legal()` disagrees between the ports.**~~ *Resolved
  2026-08-11.* The SV helper was stale for `ReadOnce`, `CleanInvalid`,
  `MakeInvalid`, `WriteUniqueFull` and `WriteUniquePtl` — all five are carried
  end-to-end by both ports (driver, HN-F, coherency checker, coverage, SVA) and
  are now accepted unconditionally on both sides.

  `MakeReadUnique` turned out **not** to be the same case, and neither port had
  it right. Its encoding is `0x41`, which does not fit the 6-bit CHI-D REQ
  opcode field, so it is legal only under issue E — like `WriteNoSnpZero`
  (`0x44`). SV rejected it for both issues; Python accepted it for both. Both
  helpers now gate it on `ISSUE_P`/`is_e`.

  Two related defects fell out of that and are also fixed:

  - `con_opcode_legal_rnf` offered `MakeReadUnique` to CHI-D RN-F
    randomization in both ports. In SV the `req_opcode_t'()` cast truncated it
    to `6'h01`, silently adding a second way to draw `ReadShared`; in Python
    `opcode` is a flat `rand_bit_t(7)` with no such cast, so a free CHI-D RN-F
    draw could land on `0x41` and produce an item claiming `MakeReadUnique`
    that truncates to `ReadShared` at pack time. The read pool is now
    issue-split in both ports.

    No existing test emitted such a flit, and none could have: every coherent
    sequence pins `x.opcode == opcode_val` from `_choose_opcode()`, so the RN-F
    pool is only ever checked for satisfiability against an already-decided
    opcode and never selects one. The defect is on the VIP's public
    randomization surface — a caller doing `item.randomize()` with
    `role == RNF` and no opcode pin — which is what the new test does and what
    nothing exercised before.
  - The SV helper wrote its two wide opcodes as `req_opcode_t'(...)` case
    items, which under CHI-D aliased them onto unrelated opcodes and answered
    for the wrong one. Both are now matched at full width ahead of the
    truncating case.

  `tc_chi_opcode_pool_safe` previously drew from the RN-I pool only, which is
  why the RN-F divergence survived; it now cross-checks the RN-F pool against
  the helper on both issues in both ports (verified non-vacuous by
  reintroducing the pool bug, which fails at draw 0).

---

## 1. Coherent feature breadth

Extends the RN-F / HN-F subsystem with more of the CHI coherency surface.

- **DVM** — distributed virtual memory / TLB-maintenance operations (DVMOp on the
  SNP channel, sync/complete handshakes). No requester in the current bench needs
  it. *Effort L.*
- **Stash** — `WriteUniqueFullStash`, `StashOnce*`, `StashOnceSep*`: writes/reads
  that also push a copy toward a target cache. Needs a stash-target model on the
  RN-F side. *Effort L.*
- **Graceful link deactivation on the COHERENT link** — the drain-to-`STOP`
  handshake works on the RN-I <-> SN-F link and not on the RN-F <-> HN-F one, so
  a coherent link reaches `STOP` only through a reset. Three things sit behind
  it, measured rather than inferred: the HN-F fatals with *"unsupported REQ
  opcode 0x0"* because the drain sends `ReqLCrdReturn` and the home's REQ dispatch
  has no arm for it (the SN-F has had one all along); the HN-F has no per-port
  `link_deactivating`, so the drain could never converge; and the RN-F's
  `snp_credit_loop` has no stand-down, so it would keep putting credits on the
  wire straight through a tear-down. Needs a testcase that reaches `STOP` on a
  coherent link without a reset. `README.md` scopes the feature to the
  RN-I <-> SN-F link, which is accurate today. *Effort M.*
- **Multi-SN address striping / SAM behind the HN-F** — the two-level hierarchy
  ships `N_SN_PORTS=1` (a single downstream SN-F). A SAM-routed multi-SN fan-out
  behind the home (the HN-I SAM is the template) would let the HN-F stripe misses
  across several SN-F targets by address. *Effort M.*
- **Dirty writeback-on-eviction** — the bounded RN-F cache
  (`cfg.rnf_cache_max_lines`) silently drops only CLEAN victims (SC/UC). Evicting
  a DIRTY victim needs autonomous RN-F REQ origination (a WriteBackFull with no
  triggering sequence); today a bounded cache that fills with dirty lines fatals
  with an explicit message. *Effort M.*

## 1b. Unimplemented opcodes, by protocol feature

Everything the two ports do NOT define, grouped by the feature that would bring
it in. The point of the grouping is that a list of 22 REQ encodings is not a
backlog anyone can act on, while "combined Write + CMO" is one decision covering
nine of them.

**Reproducing this list.** `scripts/check_opcodes.py --show-unimplemented` prints
it, but only when given a local markdown conversion of the specification — the
Arm document is not in this repository and must not be:

```
python3 scripts/check_opcodes.py --spec-e <your IHI0050E_a conversion>.md \
                                --show-unimplemented
```

The classification below was taken from a conversion of **IHI0050E_a**, 14019
lines, sha256 beginning `a4a12b28166eac8c`, on 2026-08-24, when the script
reported REQ 51/73, RSP 15/18, SNP 13/22, DAT 9/10. A different conversion may
split tables differently and shift those totals; the FAMILIES are what this
section commits to, not the ratios.

Each family carries one of five dispositions:

  **backlog**   wanted, not built. The subsystem it needs is named.
  **excluded**  deliberately out of scope. The reason is recorded, and a
                `scope_exclusion` row in the review trace matrix points here.
  **n/a**       does not apply to the roles this VIP models.
  **open**      an unresolved specification question, not a work item yet.
  **parser**    implemented, but missing from the opcode tables — a defect.

No family is currently `parser`: the ports agree with each other and with the
specification on all 88 opcodes they define, which `check_opcodes.py` asserts on
every run without needing a conversion.

- **DVM** — `DVMOp` (REQ 0x14), `SnpDVMOp` (SNP 0x0D). **backlog**, see §1
  above; needs TLB-maintenance sequencing, not just the two encodings.
- **Stash** — `StashOnceShared/Unique` (REQ 0x22/0x23), `StashOnceSepShared/Unique`
  (0x47/0x48), `WriteUniqueFullStash`/`WriteUniquePtlStash` (0x20/0x21),
  `SnpStashShared/Unique` (SNP 0x0C/0x0B), `SnpUniqueStash` (0x05),
  `SnpMakeInvalidStash` (0x06), `StashDone`/`CompStashDone` (RSP 0x10/0x11).
  **backlog**, see §1 above; needs a stash-target model. Note the RSP pair: a
  stash implementation is not complete without the two completion opcodes, which
  is the kind of thing an opcode-row list hides and a family list does not.
- **Combined Write + CMO** — `WriteBackFullCleanInv/CleanSh/CleanShPerSep`
  (REQ 0x59/0x58/0x5A), `WriteCleanFullCleanSh/CleanShPerSep` (0x5C/0x5E),
  `WriteUniqueFullCleanSh/CleanShPerSep` (0x54/0x56),
  `WriteUniquePtlCleanSh/CleanShPerSep` (0x64/0x66). **implemented.** All nine
  are declared, served by the HN-F and driven by `vip_chi_write_cmo_seq`, which
  now carries a write-class axis over the whole family of fifteen;
  `tc_chi_coh_e_combined_write_cmo` exercises six forms across the three coherent
  write classes and both persistence choices. One gap remains, and it is a
  property of the topology rather than of the family: the SystemVerilog home
  sends `Persist` with PGroupID zero, because the group is built from
  `GroupIDExt` and the coherent env stands up the base RN-F, which does not drive
  it. The Python port reflects the real group. Tracked under §2, *Issue-E-exact
  drivers on the coherent topology*.
- **Invalidating ReadOnce forms** — `ReadOnceCleanInvalid` (REQ 0x24),
  `ReadOnceMakeInvalid` (0x25). **backlog.** Both need the RN-F cache to act on a
  read that also invalidates, which the current model does not do.
- **ReadNotSharedDirty / SnpNotSharedDirty** — REQ 0x26, SNP 0x04. **backlog**,
  and coupled: the request is only meaningful against a snoop response that can
  return SD, so the pair lands together.
- **PreferUnique (CHI-E)** — `ReadPreferUnique` (REQ 0x4C),
  `SnpPreferUnique`/`SnpPreferUniqueFwd` (SNP 0x15/0x16). **backlog.**
- **SnpQuery (CHI-E)** — SNP 0x10. **Implemented.** The home originates it under
  `cfg.hnf_snp_query_enable`, with no request behind it (§4.5), and reconciles
  the answer against its own directory; catalogue rule D10 judges §4.5's "must
  not change the state of the cache line at the Snoopee" from the wire, with
  `cfg.rnf_snp_query_mutates_negctl` as its control. Kept in this list because
  the entry records what the "smallest coherent addition" turned out to cost.
  Three predicates elsewhere answered wrongly the moment the opcode existed:
  `snp_opcode_is_forwarding` read bit[4], which 0x10 sets and which stops
  separating the Forward snoops in Issue E; the request-to-snoop rule (D8)
  correlated a spontaneous snoop to whatever request was open on the line and
  judged it against a Table 4-5 row that does not exist; and a data-less
  `SnpResp` had never had to carry a dirty state, so nothing encoded Table 4-9 --
  where UD and UC share one encoding and SD takes the one the general cache-state
  field reserves.
- **Memory Tagging `TagMatch`** — RSP 0x0A. **Implemented.** The completer
  performs the comparison Table 13-34 requires and answers in `Resp[0]` per
  Table 13-25; `CHI_SB_TAG_MATCH_OWED` judges that the response was owed and
  `CHI_SB_TAG_MATCH_RESULT` judges what it said, each with its own negative
  control. Kept in this list because the entry records how it went wrong: the
  opcode, the response and the OWED rule all shipped while the completer
  answered a constant `Fail` and compared nothing, because `Resp[0] = 0` is also
  the encoding of cache state `I`. A presence rule cannot see a constant answer.
- **`WriteBackPtl` / `WriteEvictFull`** — REQ 0x1A / 0x15. **backlog**, tied to
  the dirty-writeback-on-eviction item in §1: both are eviction paths the bounded
  RN-F cache would need before it could evict rather than fatal.
- **`WriteDataCancel`** — DAT 0x07. **excluded.** It cancels beats of a write
  whose data the requester has already begun sending, which presupposes a
  requester that abandons a transaction mid-burst. Every driver here completes
  the bursts it starts, and building the opcode without that behaviour would
  produce a flit nothing in the bench could provoke or consume.

Nothing on this list is `n/a` or `open` today. Both dispositions are kept in the
vocabulary because the next conversion may add opcodes for roles this VIP does
not model, and an empty category is cheaper than inventing one later.

## 2. Infrastructure / breadth

- **Interface parity (`PARITY_EN_P`)** — parity signals across the whole CHI
  interface (flit + sideband), with a parity checker and error-injection. Out of
  scope for v1. *Effort M.*
- **Issue-E-exact drivers on the coherent topology** — `chi_coherent_tb_env`
  stands up the base `vip_chi_agent` at CHI-E width on the stated premise that
  "coherent reads do not depend on the E-only REQ fields that the `_e` drivers
  add". A Combined Write with a persistent CMO is the first thing that does, and
  it will not be the last: only `vip_chi_driver_rni_e` puts `GroupIDExt` on the
  wire, so the SystemVerilog home has no group to reflect and sends `Persist`
  with PGroupID zero where the Python port sends the real one.

  The home cannot read the field either, and the reason is elaboration rather
  than logic: its `req_flit_t` comes from `vip_chi_types_d` for a CHI-D
  instantiation and that struct has no `groupidext` member, so naming it fails to
  elaborate instead of failing at runtime. The SN-F already solves exactly this
  with a `req_group_id_ext` virtual hook overridden in `vip_chi_driver_snf_e`.
  Closing it means that hook on the HN-F base plus `vip_chi_driver_hnf_e`,
  `vip_chi_hnf_agent_e` — the agent has to be subclassed too, or the CHI-D
  specialization of the `_e` driver still gets elaborated — and an E coherent env
  to select them. Worth doing for the plumbing rather than for the one field:
  every later E-only REQ field on this topology needs the same. *Effort M.*
- **CHI-A / CHI-B** — earlier CHI issues. Out of scope by design; the VIP targets
  CHI-D and CHI-E.
- **System Coherency Interface (`SYSCOREQ` / `SYSCOACK`)** — the system-level
  handshake by which a system controller enables and disables an interface's
  participation in coherency (IHI 0050D Ch. 14 / IHI 0050E_a Ch. 15). Neither
  port models the two sideband signals, and no testcase drives them. Backlog
  rather than a non-goal: the VIP already models the link-level analogue (LASM
  activation, deactivation and the quiescence handshake), so the system-level
  pair is the same shape of state machine one level up, and a bench that
  connects a real RN-F to a real system controller would need it. *Effort M.*

  **Name collision, deliberately noted here:** grepping the tree for "system
  coherency" finds the VIP's own *system coherency checker* (Checker D), which
  is an unrelated thing that happens to share the words. That collision is why
  this gap survived several documentation passes: the grep that should have
  found nothing found something plausible instead. Search for `SYSCOREQ`.

- **`RSVDC` on REQ and DAT** — the specification's user-defined field, `X` bits
  wide on REQ and `Y` on DAT (IHI 0050E_a Table 13-6 / 13-9, D Table 12-6 /
  12-9). Absent from both ports, in both issues, and legal that way: the widths
  are implementation-defined and zero is a permitted value for each, so a VIP
  that declares no user-defined bits is conformant. Recorded here because it was
  the one *undocumented* omission -- every other configurable width in this VIP
  is a knob on `vip_chi_cfg_t`, so a reader comparing the flit structs against
  the tables finds `RSVDC` missing with nothing saying it was a decision.
  `scripts/check_flit_layout.py` lists it as an advisory `missing` on three
  channels; that advisory is the intended steady state, not a defect to chase.
  Adding it would mean two more config widths and no protocol behavior to check
  against, since the field's meaning is by definition outside the spec.
  *Effort S; value low.*

## 3. Depth / polish (deferred from the retired TODO.md)

- **Checker-A completion-count / opcode thinning** — the scoreboard keeps ~56
  inline `size()==N` / `rsp_opcode==…` per-test checks for precise failure
  messages even though Checker A subsumes them. Stripping them is a larger,
  aggressive pass; revisit if the suite grows. *Effort M.*
- **Agent reset-watcher level check** — the `vip_chi_agent` reset watcher requires
  a posedge of `rst_n`, so a bench with `rst_n` tied high from t0 never starts the
  drivers. Guard with a level check. *Effort S; risk med — changes reset detection
  for every test.*
- **SVA reset-branch cost** — the `vip_chi_sva` `always_ff` disable branch
  iterates all `2**txn_id_width` entries across ~12 arrays every clock while
  `!checks_enable || !rst_n`; run it once on the disable edge instead. *Effort S;
  touches `vip_chi_sva`, false-fire risk.*

## Related (tracked elsewhere)

- **`M6 cg_outstanding` coverage** — a separate workstream; do not touch from
  vip_chi.
