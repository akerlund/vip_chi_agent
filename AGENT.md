# Working on `vip_chi_agent`

Practices this codebase has arrived at, most of them the hard way. Each one says
why, because a rule without its reason gets dropped the first time it is
inconvenient.

If you read nothing else: **this VIP is two implementations of one thing**, and
almost every practice below exists because that is easy to get wrong in a way no
test notices.

---

## 1. Both ports, always

Every behavioural change lands in the SystemVerilog port (`sv/`) **and** the
pyUVM/cocotb port (`py/`), in the same commit, with the same testcase in
`testbench/sv/tc/` and `testbench/py/tc/`.

Not for symmetry — because the two ports are each other's reference. A defect
present in one is visible as a disagreement; a defect present in both is
invisible. That is exactly what `scripts/check_counter_parity.py` and
`check_tally_parity.py` exist to catch, and it is why "I'll port it after" is a
false economy: the port is where you find out you were wrong.

**Parity of surface is not parity of behaviour.** `check_cfg_parity.py` proves a
config knob exists in both ports. It cannot prove both ports *read* it. A knob
that only one driver honours passes every parity gate — which is why
`check_flitpend_negctl.py` was written, after exactly that happened.

## 2. Measure; never infer

Run the command. Build times, regression tallies, rule counts, backlog sizes,
"is this implemented" — read them out of the tree, do not reason to them.

This repository has been wrong about its own state in every direction: a
regression count stale by twenty-odd testcases, a milestone plan understating
its own completion in six places, a candidate ledger listing twenty rules as
unbuilt that were built under names it never learned. In each case the document
was written by someone who knew the answer at the time.

Corollary: **do not hand-maintain a number in prose.** If a count must appear in
a document, a gate must compare it with the tree — `check_test_counts.py` does
this for regression sizes, `check_type_parity.py` for rule counts.

## 3. Both regressions, before you commit

```sh
./scripts/sv_regression.sh                  # builds, sweeps, runs every gate
python3 testbench/py/scripts/run.py --all   # one simulator process per testcase
```

`run.py --all` **is** the Python regression. A single-process cocotb sweep is
not: state carries between testcases there, it invents failures that do not
reproduce standalone, and it writes none of the per-test logs the parity gates
read. If a test fails only in a single-process sweep, that is a fact about the
sweep.

The SV flow needs **Verilator 5.050 or newer** where Verilator is used; 5.044
mishandles `--top-module` on names containing `__`. Do not rename wrappers to
work around it.

Say which claim you have. A green elaboration and a green regression are
different statements, and `scripts/sv_elaborate.sh` exists so you can make the
weaker one honestly when the licence pool is full.

## 4. A new rule has to earn its identity

Before adding a check ID:

- **Prove it can fail alone.** Mutate the code it judges and confirm *that rule
  and nothing else* reports. If another rule always fires with it, you have
  found a second name for one obligation, and the vacuity report will
  double-count your coverage for ever.
- **Prove it is not vacuous.** A zero fail count means nothing without a non-zero
  pass count. A rule that never evaluated is indistinguishable from one that does
  not work.
- **Give it a negative control**, and know what the control proves. A control
  that reads counters proves the counters move. It does **not** prove the verdict
  path — that needs a mutation, done separately.

Two failure shapes worth knowing by name:

- **A presence rule cannot see a constant answer.** "A response arrived" passes
  against a completer that always says the same thing. The value needs its own
  rule and its own control. This shipped once with the completer answering a
  constant `Fail` and comparing nothing.
- **A vantage can be dead two ways** — stood down, or live but never reached.
  Each hides the other, so audit both at every bind. `check_bind_coverage.py` and
  `check_vacuity.py` are the tools.

## 5. Predicates rot

- **Never derive a classifier from a bit pattern.** `opcode & 0x10` meant
  "Forward snoop" until Issue E added two opcodes that set bit 4 and forward
  nothing. A bit-derived predicate keeps answering after it stops being right,
  and it answers *permissively*.
- **A widening predicate breaks its callers silently.** When a family grows, every
  call site whose comment assumed the old membership is now wrong — and the
  comment reads as a decision, which is what stops anyone re-checking it. One
  such comment cost a deadlock.
- **A hand-kept opcode list will drift.** Ask the shared classifier in
  `vip_chi_types_pkg`. `check_classifier_coverage.py` compares the two ports'
  classifiers opcode by opcode; it cannot compare a list nobody registered.
- **Omissions must raise, not default.** A field whitelist that yields `None` for
  a missing entry lets a rule compare `None` to `None` and pass. Prefer the
  `KeyError`; a guard like `if "x" in f` turns a real rule into a silent no-op.

## 6. Adding the first instance of anything

When a channel is about to carry a new *kind* of message, budget for every reader
that never had to tell it apart — not for the feature.

Graceful deactivation on the coherent link was booked at three measured defects
and took six. The three extras were one sentence left unsaid — *a link-layer flit
is not a transaction* — in three places, all on the snoop channel, because that
was the only channel that had never carried an `LCrdReturn`. A reader that has
only ever seen one kind of traffic is indistinguishable from one that checks.

Do it as an audit with a list, before you write the feature.

## 7. Two ends that agree can both be wrong

No parity check, counter or scoreboard rule can see a requester and a completer
that are consistent and consistently wrong. `Persist` carried `PGroupID` zero at
both vantages for as long as the field went undriven, and every check agreed.

So when a test pins a round-tripped value, **pin something a silent link cannot
produce**: bits set in both halves of the field's equation, never zero, never a
value one end could supply on its own.

## 8. Comments describe the code, not its history

`scripts/check_review_refs.py` enforces the first half of this: no source comment
may cite a finding ID, a trace row or a review box number. The review scaffolding
is temporary; the code is not.

The rest is convention, and it is what makes the comments in this tree worth
reading:

- State the rule and its clause — issue, section, table.
- State *why* the code is shaped this way, especially where an obvious
  alternative is wrong. Several comments here exist only to say "this was tried
  and it broke X".
- Do not narrate a defect's life. "This used to be wrong" is archaeology; "this
  reads the wire rather than a saved copy, because an attribute is not a wire" is
  a reason.
- Never maintain a count in a comment. It rots the next time someone adds a test.

## 9. SystemVerilog specifics that have cost time

- **Issue-specific flit members fail at *elaboration*.** A CHI-D specialization of
  a driver naming an Issue-E-only field does not read zero — it does not compile.
  No `if (ISSUE_P)` helps. The selection has to sit at a **class boundary**, and
  the agent and env need subclassing too, or the wrong specialization still gets
  elaborated.
- **There are no mixins.** A static helper class parameterized identically is the
  substitute; `vip_chi_issue_e_fields` is the worked example.
- **Class-scope `localparam`**: plain `int`/`bit` are fine. Never type one through
  `item_t::`, and never the array form.
- **`disable iff` is not sampled.** If a tally and a waveform disagree about
  whether a rule fired, the gate moved inside the edge. Clocking-block outputs
  cannot race; NBA-derived signals can. `check_gate_timing.py` guards this.
- **One writer per signal.** A level driven from two places is decided by
  whichever assignment ran last, and it will differ between the ports. The HN-F
  driver has no channel lock at all — its invariant is that *every* flit leaves
  through one serial engine — so adding a coroutine that sends a flit outside it
  reintroduces a defect nothing will catch.

## 10. The gates

There are 19. `sv_regression.sh` runs 16 of them after the sweep; the three it
does not are `check_citation_parity`, `check_flit_layout` and
`check_flitpend_negctl` — the middle one because it needs a specification
conversion, so **run those three by hand** when you touch a rule's clause, a flit
layout, or a driver's flit announcement. Run whichever others your change touches
while you work; the regression is not the place to find out.

| Gate | Catches |
| --- | --- |
| `check_type_parity` | rule registries, enum values, flit field order, documented rule counts |
| `check_counter_parity` | the two ports judging the same testcase differently |
| `check_tally_parity` | which port reported a failure, per testcase per rule |
| `check_cfg_parity` | a config field in one port only |
| `check_flitpend_negctl` | a knob one port's drivers do not honour |
| `check_bind_coverage` | a live link with no checker; a checker that reports nothing |
| `check_vacuity` | rules never evaluated, per bind |
| `check_citation_parity` | a rule with no clause, or a different clause in each port |
| `check_classifier_coverage` | the two ports' opcode classifiers disagreeing |
| `check_opcodes` | an encoding that disagrees with the specification |
| `check_opcode_evidence` | an opcode the regression drives that nothing judges |
| `check_flit_layout` | a field in the wrong bit position |
| `check_gate_timing` | an assertion gate that moves inside the sampling edge |
| `check_review_refs` | a source comment citing review scaffolding |
| `check_test_counts` | a regression size quoted in prose that has gone stale |
| `check_{req_snp,snp_resp}_illegal_bins` | a covergroup illegal bin the predicate does not forbid |
| `check_tagop_groups` | Table 12-2 entered twice and disagreeing |
| `check_import_path_parity` | the two launchers naming different import paths |

`check_opcodes`, `check_opcode_evidence` and `check_flit_layout` need your own
markdown/PDF conversion of the Arm specification, passed via `--spec-e` /
`CHI_SPEC_E_MD` / `CHI_SPEC_E_PDF`. **The Arm document must never be committed
here**, and neither must converted extracts of it. Cite by issue, section and
table only.

## 11. Documents

`docs/FUTURE_WORK.md` is the single backlog and holds **only work with tickable
boxes** — no retrospectives, no "this got fixed", no counts. Everything else
about the tree belongs in the code, in `README.md`, or in
`docs/IMPLEMENTATION_PLAN.md`.

A document asserting a property is not evidence of it. If prose claims something
a script could check, either make the script check it or expect the prose to be
wrong within a month. Both have happened here repeatedly.

## 12. Working style

- **Keep a queue on disk** and work it without prompting: a session-sized list of
  items, skip what is blocked, do not stall on one thing.
- **Finish the whole item.** A change is done when both ports build, both
  regressions pass, every touched gate is green, and the documents agree with the
  tree.
- **Report faithfully.** If a test fails, say so with the output. If a step was
  skipped, say that. State which claim you have — elaborated, or swept.
- **Commit on the current branch.** Do not create branches unless asked.
