# vip_chi_agent — future work (backlog)

The planned charter (Tiers A/B/C — SNP channel, RN-F/HN-F coherent subsystem,
Checker D, coherent coverage, HN-I proxy, scoreboard, perf counters, exclusives,
CMO, DCT forwarding, SN-F-behind-HN-F, MakeUnique, bounded-cache eviction) is
**complete and tested** — regression **124/124** green on branch `dram`
(2026-07-20). This file is the single remaining backlog: optional breadth (more
of the CHI feature surface) and depth (hardening what already ships). Nothing
here is required by any current consumer.

Effort legend: S (hours) / M (a day) / L (multi-day).

---

## Current review follow-up (2026-07-20)

Source-review findings from the MakeUnique / DCT / rename follow-up pass.

- **MakeUnique DCT anti-vacuity** — `vip_chi_coh_make_unique_dct_base_test`
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
- **Regression script scope mismatch** — `examples/vip_chi_agent/README.md` calls
  `scripts/compile.sh` the full regression, but the script's `TESTS` list does not
  include the coherent suite or the new `tc_chi_coh_{d,e}_make_unique_dct` tests.
  Either extend the script or rename the README claim to a compile/integrated-smoke
  flow. *Effort S; risk low.*
- **Rename/reorg documentation drift** — docs still contain old `examples/vip_chi`
  paths and pre-reorg `tb/` / `tc/` links instead of `examples/vip_chi_agent` and
  `sv/tb` / `sv/tc`. Refresh the command snippets and links after the
  `vip_chi_agent/sv` layout move. *Effort S; risk low.*
- **Stale transition-coverage comment** — `vip_chi_coherency_checker` still says
  the cache-transition sweep closes "30 reachable bins" even though the reduced
  model documents 11 reachable transition tuples. Update the comment or make it
  denominator-neutral. *Effort S; risk low.*

---

## 1. Coherent feature breadth

Extends the RN-F / HN-F subsystem with more of the CHI coherency surface.

- **DVM** — distributed virtual memory / TLB-maintenance operations (DVMOp on the
  SNP channel, sync/complete handshakes). No requester in the current bench needs
  it. *Effort L.*
- **Stash** — `WriteUniqueFullStash`, `StashOnce*`, `StashOnceSep*`: writes/reads
  that also push a copy toward a target cache. Needs a stash-target model on the
  RN-F side. *Effort L.*
- **Multi-SN address striping / SAM behind the HN-F** — the two-level hierarchy
  ships `N_SN_PORTS=1` (a single downstream SN-F). A SAM-routed multi-SN fan-out
  behind the home (the HN-I SAM is the template) would let the HN-F stripe misses
  across several SN-F targets by address. *Effort M.*
- **Dirty writeback-on-eviction** — the bounded RN-F cache
  (`cfg.rnf_cache_max_lines`) silently drops only CLEAN victims (SC/UC). Evicting
  a DIRTY victim needs autonomous RN-F REQ origination (a WriteBackFull with no
  triggering sequence); today a bounded cache that fills with dirty lines fatals
  with an explicit message. *Effort M.*

## 2. Infrastructure / breadth

- **Interface parity (`PARITY_EN_P`)** — parity signals across the whole CHI
  interface (flit + sideband), with a parity checker and error-injection. Out of
  scope for v1. *Effort M.*
- **CHI-A / CHI-B** — earlier CHI issues. Out of scope by design; the VIP targets
  CHI-D and CHI-E.

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
