# Changelog

All notable changes to `vip_chi_agent` are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] — 2026-08-26

First release. An AMBA CHI verification IP shipped as **two implementations of
one specification** — SystemVerilog/UVM and pyUVM/cocotb — kept at parity by
gates rather than by intention, because a defect present in one port shows up as
a disagreement and a defect present in both is invisible.

### Added

**Protocol surface**

- CHI-D and CHI-E, selected by `CFG_P.issue`, with the Issue-E-only flit fields
  (memory tagging, `DBIDRespOrd`, wider IDs, `GroupIDExt`) driven by `*_e`
  subclasses — a class boundary rather than a runtime test, because a CHI-D
  specialization naming an E-only struct member fails at elaboration.
- All four channels (REQ, RSP, DAT, SNP) with owned flit structs whose field
  order is checked position-by-position against the specification's layout
  tables.
- Reads, writes, CopyBack, dataless requests, atomics, CMOs and persistent CMOs,
  exclusives, and the CHI-E combined Write + CMO family.
- The retry handshake modelled as a credit **pool** rather than a first-attempt
  pairing, because §2.6.5 permits a re-issue to carry a different TxnID from the
  request that was retried.
- Ordered streams, `ReadReceipt`, separated reads, split-write responses, and
  both legal completion forms of `CleanSharedPersistSep`.
- Memory tagging: `TagOp`, tag beats, per-beat uniformity, read-back and
  `TagMatch`.

**Roles and topologies**

- One role-parameterized agent playing six roles selected at elaboration: RN-I
  requester, SN-F memory completer, HN-I proxy, coherent RN-F and HN-F, and
  passive monitor.
- `N_RN × N_SN` HN-I pass-through proxy with QoS fan-in, a System Address Map or
  stride fan-out, and node-id completion routing.
- Coherent RN-F/HN-F pair over the SNP channel: an RN-F cache model with an
  autonomous snoop responder, an HN-F directory with snoop origination.
- Optional two-level memory, the HN-F issuing downstream `ReadNoSnp` /
  `WriteNoSnpFull` to a real SN-F rather than terminating against its own memory.

**Link layer**

- Per-channel L-credit managers that start at zero and learn from `LCRDV`
  pulses.
- The `{LINKACTIVEREQ, LINKACTIVEACK}` state machine, tracked per direction.
- Graceful deactivation on every link including the coherent one — retire
  traffic, stop advertising receive credits, drop the request, return every held
  L-credit, and only then reach `STOP` genuinely empty. On the coherent link that
  is four channels, and the home tears one RN port down without disturbing the
  others.
- Activation delays chosen by the link state the peer is *already* in, which is
  what makes bring-up races reachable at all.
- `TXSACTIVE` driven from a counted outstanding window, with a configurable legal
  over-extension.

**Coherency**

- Cache states I, SC, UC, UD and SD as the wire encodes them, plus a per-byte
  dirty mask on the requester — UDP shares UD's `Resp` encoding, so the mask is
  the only thing that can distinguish them.
- Snoop families including the DCT forwarding forms and CHI-E `SnpQuery`, the one
  a home may send with no request behind it.
- Exclusive monitor (LL/SC) with conflict-driven failure.

**Checking and coverage**

- **103 named rules** — 85 bindable link/protocol/SNP assertions and 18
  scoreboard rules — each with a stable identity, a severity, pass and fail
  counters, and the specification clause it enforces. 99 are mirrored in Python;
  the four that are not are X/Z rules Verilator's two-state model cannot hold.
- A self-derived per-line ownership shadow, never the HN-F directory, whose core
  invariant is *never two Unique owners of one line*.
- A predictable-data and atomic-RMW scoreboard, and an ordered-stream
  acknowledgement-order check.
- Per-rule pass counts, so a rule the test list never reached reports as NOT
  EXERCISED rather than reading like one that passed — attributed per bind and
  exported per run, with dead (bind, rule) pairs classified as vantage, geometry
  or missing stimulus.
- A negative control for every always-on checker: a knob that breaks exactly the
  invariant it guards.

**Verification of the VIP itself**

- **234 SystemVerilog and 235 pyUVM/cocotb testcases**, the same list on both
  flows apart from three documented exceptions.
- 19 cross-port and specification gates, 16 of them run by the regression:
  registry, config, classifier, counter and tally parity between the ports;
  opcode encodings and flit layouts against the Arm specification; assertion-gate
  timing; per-opcode evidence; and prose counts against the tree.

### Known limitations

Recorded rather than omitted; each is a tickable item in
[docs/FUTURE_WORK.md](docs/FUTURE_WORK.md).

- The HN-I drives `TXSACTIVE` from link state rather than from an outstanding
  window, on both its RN- and SN-facing ports. Legal by the letter, since
  over-assertion always is, but it carries no information — and it keeps
  `CHI_TXSACTIVE_DEASSERT_BOUNDED` and `CHI_TXSACTIVE_COVERS_OUTSTANDING` stood
  down at those binds. The equivalent drive was removed from the HN-F.
- Deferred rather than partially implemented: DVM, stash, multi-SN striping
  behind the HN-F, and the SYSCO sideband.
- Not modelled: a full interconnect / system environment, and CHI issues
  A / B / C / F.

[1.0.0]: https://github.com/akerlund/vip_chi/releases/tag/v1.0.0
