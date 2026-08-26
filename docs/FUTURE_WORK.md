# vip_chi_agent — future work (backlog)

The planned charter is complete and tested: every charter item has a named
testcase in [../testbench/TEST_CASES.md](../testbench/TEST_CASES.md), and no open
defects remain. Everything below is optional — breadth (more of the CHI feature
surface) or depth (hardening what already ships). **Nothing here is required by
any current consumer.**

Every item is a tickable box. Effort: S (hours) / M (about a day) / L
(multi-day); risk is stated where it is not low.

Regression counts are not maintained here. `scripts/check_test_counts.py`
compares the documented figures with the tree on every sweep, because this file
once carried a count that had gone stale by twenty-odd testcases.

---

## 1. Documentation

- [ ] **Bring the milestone-plan document into line with the tree.** Six
      line-referenced edits, each measured, in
      `docs/review_claude/gap_analysis_reconciliation.md`. The work it describes
      is done; the document still asserts, in the present tense and with nothing
      dated, a state three milestones back — and every one of the six understates
      what exists. The opening five-gap summary is the one that matters most: all
      five gaps and both smaller absences that follow it are closed. Fix it with a
      dated line and a status column, **not** a rewrite — that section is the
      record of where the VIP started, and losing it loses the reason the work was
      done. Give the verification line a commit as well as a count: these figures
      have gone stale twice between being measured and being applied, both times
      because the line stated a number with no date. *Effort S.*

## 2. Coherency depth

- [ ] **Scoreboard completion contract for combined requests.** A combined
      Write + CMO must not retire without its CMO half. Nothing currently refuses
      to, so a completer that answered only the write would pass. *Effort S/M.*
- [ ] **RN-F DCT no-data fallback.** `process_snoop_fwd` falls back to a no-data
      `SnpResp` when a forwarding snoop hits a valid holder with no `cache_data`,
      while the HN-F DCT path waits for `SnpRespDataFwded`. The MakeUnique
      materialised-zero fix prevents this for MakeUnique-owned lines; the fallback
      itself can still wedge. Either fatal locally on missing data for a forwarding
      snoop, or teach the home to consume the fallback deliberately. *Effort S/M;
      risk med.*
- [ ] **Dirty writeback-on-eviction.** The bounded RN-F cache
      (`cfg.rnf_cache_max_lines`) drops only CLEAN victims. Evicting a DIRTY one
      needs autonomous RN-F REQ origination — a `WriteBackFull` with no triggering
      sequence. Today a bounded cache that fills with dirty lines fatals with an
      explicit message. Pairs with the `WriteBackPtl` / `WriteEvictFull` item in
      §3. *Effort M.*
- [ ] **Multi-SN address striping / SAM behind the HN-F.** The two-level hierarchy
      ships `N_SN_PORTS = 1`. A SAM-routed fan-out behind the home (the HN-I SAM is
      the template) would let the HN-F stripe misses across several SN-F targets by
      address. *Effort M.*

## 3. Opcode families

Grouped by the subsystem that would bring them in, because a list of 22 REQ
encodings is not a backlog anyone can act on while "Stash" is one decision
covering twelve. `scripts/check_opcodes.py --show-unimplemented` reproduces the
list, given your own markdown conversion of the specification — the Arm document
is not in this repository and must not be.

- [ ] **DVM.** `DVMOp` REQ `0x14`, `SnpDVMOp` SNP `0x0D`. Needs TLB-maintenance
      sequencing with sync/complete handshakes, not just the two encodings.
      *Effort L.*
- [ ] **Stash.** `StashOnceShared`/`Unique` REQ `0x22`/`0x23`, `StashOnceSep*`
      `0x47`/`0x48`, `WriteUnique*Stash` `0x20`/`0x21`, `SnpStash*` SNP
      `0x0C`/`0x0B`, `SnpUniqueStash` `0x05`, `SnpMakeInvalidStash` `0x06`,
      `StashDone`/`CompStashDone` RSP `0x10`/`0x11`. Needs a stash-target model on
      the RN-F side. Note the RSP pair: a stash implementation is not complete
      without the two completion opcodes, which is what an opcode-row list hides
      and a family list does not. *Effort L.*
- [ ] **Invalidating `ReadOnce` forms.** `ReadOnceCleanInvalid` REQ `0x24`,
      `ReadOnceMakeInvalid` `0x25`. Needs the RN-F cache to act on a read that also
      invalidates. *Effort M.*
- [ ] **`ReadNotSharedDirty` / `SnpNotSharedDirty`.** REQ `0x26`, SNP `0x04`.
      Coupled: the request is only meaningful against a snoop response that can
      return SD, so the pair lands together. *Effort M.*
- [ ] **PreferUnique (CHI-E).** `ReadPreferUnique` REQ `0x4C`,
      `SnpPreferUnique`/`SnpPreferUniqueFwd` SNP `0x15`/`0x16`. *Effort M.*
- [ ] **`WriteBackPtl` / `WriteEvictFull`.** REQ `0x1A` / `0x15`. Both are eviction
      paths the bounded RN-F cache would need before it could evict rather than
      fatal, so this lands with the dirty-writeback item in §2. *Effort M.*

## 4. Interface and system breadth

- [ ] **System Coherency Interface (`SYSCOREQ` / `SYSCOACK`).** The system-level
      handshake by which a controller enables and disables an interface's
      participation in coherency (IHI 0050E_a Ch. 15 / D Ch. 14). Neither port
      models the two sideband signals and no testcase drives them. Backlog rather
      than a non-goal: the VIP already models the link-level analogue, so this is
      the same shape of state machine one level up. **Search for `SYSCOREQ`, not
      "system coherency"** — the latter finds the VIP's own system coherency
      checker (Checker D), an unrelated thing sharing the words, which is why this
      gap survived several documentation passes. *Effort M.*
- [ ] **Interface parity (`PARITY_EN_P`).** Parity across the whole CHI interface,
      flit and sideband, with a checker and error injection. *Effort M.*
- [ ] **`RSVDC` on REQ and DAT.** The specification's user-defined field, `X` bits
      on REQ and `Y` on DAT (IHI 0050E_a Table 13-6 / 13-9). Absent from both ports
      in both issues, and legal that way: the widths are implementation-defined and
      zero is permitted for each. `scripts/check_flit_layout.py` lists it as an
      advisory `missing` and that advisory is the intended steady state. Adding it
      means two more config widths and no protocol behaviour to check, since the
      field's meaning is by definition outside the specification. *Effort S; value
      low.*

## 5. Polish

- [ ] **Agent reset-watcher level check.** The `vip_chi_agent` reset watcher
      requires a posedge of `rst_n`, so a bench with `rst_n` tied high from t0
      never starts the drivers. Guard with a level check. *Effort S; risk med — it
      changes reset detection for every test.*
- [ ] **SVA reset-branch cost.** The `vip_chi_sva` `always_ff` disable branch
      iterates all `2**txn_id_width` entries across ~12 arrays every clock while
      `!checks_enable || !rst_n`; run it once on the disable edge instead.
      *Effort S; false-fire risk.*
- [ ] **Checker-A completion-count / opcode thinning.** The scoreboard keeps ~56
      inline `size()==N` / `rsp_opcode==…` per-test checks for precise failure
      messages even though Checker A subsumes them. Revisit if the suite grows.
      *Effort M.*
- [ ] **`tc_chi_channel_delay` order dependence.** Only if a single-process sweep
      ever becomes the way this suite is run. The test asserts two exact cycle
      equalities and fails — baseline 151 cycles against 152 — when the whole suite
      runs as one cocotb regression in one simulator process, because state a
      preceding testcase leaves behind reaches it. Under
      `testbench/py/scripts/run.py` every testcase gets its own simulator
      invocation, so nothing can carry and this is unreachable. Find the carried
      state and make each burst start from something the test controls. **Do not
      widen the equality to a tolerance** — that is the one assertion in the file
      that cannot be weakened without losing its point: it is what separates "the
      enable gates the delay" from "the window is applied unconditionally and the
      enable is decoration". Ruled out already: the M3.2 code, the stimulus (the
      solved request fields are byte-identical across both bursts), the random seed,
      and L-credit phase. *Effort M; value low.*

---

## Not planned

No boxes: these are recorded decisions, kept so they are not re-proposed as
oversights.

- **Interconnect model / system env** (`svt_chi_interconnect`,
  `svt_chi_system_env`, the `ic_*` agents) — the HN-I proxy and HN-F home already
  cover the topologies this VIP's users build.
- **CHI-A / B / C / F** — the VIP targets CHI-D and CHI-E.
- **`WriteDataCancel`** (DAT `0x07`) — it cancels beats of a write already in
  flight, presupposing a requester that abandons a transaction mid-burst. Every
  driver here completes the bursts it starts, so the opcode would produce a flit
  nothing in the bench could provoke or consume.
- **The full 32-way hazard cross-product** — the single same-line invariant
  catches the overwhelming majority.
- **Snoop nested under its originating REQ.** A snoop leaves the home on a
  different port from the one its request arrived on, so the two are seen by two
  monitor instances and neither holds the other's transaction handle. Parenting
  them needs a handle registry shared by every monitor on the home. The snoop is
  its own stream and its TxnID appears on both, so a reader can still correlate
  them; faking the parent link would be worse than not having it.
- **Per-check covergroups.** Their purpose was regression-level aggregation of
  which checks ran, and the CSV export does it better: pass *and* fail counts per
  run per bind, surviving outside the coverage database, working identically on the
  Python port which has no covergroups at all. Reinstate only if per-check
  coverage is wanted as a **sign-off metric**, which is a different question
  wanting different bins.
- **A "wait for credit accumulation" reference event.** The credit pool is empty at
  bring-up by construction — credits arrive as LCRDV pulses only after the link
  activates — so there is nothing to wait for at the moment the request is raised.
  It would be a knob with no reachable second state.
- **The `reasonable_*` constraint pattern** — the `vip_chi_cfg_item` +
  sequence-setter approach is clearer and does not fight the caller's own
  `randomize() with`.
- **`svt_pattern` / XML / FSDB property export** — infrastructure for a commercial
  debug tool chain that does not exist here. The useful slice, plusarg check
  disable, already ships.
- **`use_tlm_generic_payload` / `use_pv_socket`** — TLM-2.0 interop with no
  consumer.
- **`M6 cg_outstanding` coverage** — a separate workstream; do not touch from
  vip_chi.
