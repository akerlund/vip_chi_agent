# CHI — A Fundamentals Primer

A self-contained introduction to the **Arm AMBA 5 CHI** (Coherent Hub Interface)
protocol: what it is, how the interface is wired, how flow control (link credits
and protocol credits) works, and how the common transactions flow. This is
background reading for working on `vip_chi`; it is deliberately conceptual and
spec-faithful at the level you need to read/write the VIP, not a substitute for
the Arm specification.

> **Authoritative source.** The normative document is *Arm AMBA 5 CHI
> Architecture Specification* (Arm IHI 0050). Exact field encodings (opcode hex
> values, bit positions) come from there; this primer gives names, widths, and
> semantics. CHI issues referenced here: **CHI-D** and **CHI-E** (the two this
> VIP supports).

---

## Table of contents

1. [What CHI is and where it sits](#1-what-chi-is-and-where-it-sits)
2. [Node types and topology](#2-node-types-and-topology)
3. [The layered model: protocol / network / link](#3-the-layered-model)
4. [Channels: REQ, RSP, DAT, SNP](#4-channels)
5. [The physical interface: flit signal groups](#5-the-physical-interface-flit-signal-groups)
6. [Link layer: activation handshake and states](#6-link-layer-activation)
7. [Link credits (L-Credits) — channel flow control](#7-link-credits-l-credits)
8. [Protocol credits (P-Credits) — the retry mechanism](#8-protocol-credits-p-credits)
9. [Transaction identifiers: TxnID, DBID, NID, LPID](#9-transaction-identifiers)
10. [Key request fields](#10-key-request-fields)
11. [Data transfer: size, beats, DataID, CCID, BE](#11-data-transfer)
12. [Responses: Resp (cache state) vs RespErr](#12-responses-resp-vs-resperr)
13. [Transaction flows (the ones that matter here)](#13-transaction-flows)
14. [Coherency in one page (why RN-I/SN-F skip it)](#14-coherency-in-one-page)
15. [Ordering](#15-ordering)
16. [CHI-D vs CHI-E deltas](#16-chi-d-vs-chi-e-deltas)
17. [How this maps onto `vip_chi`](#17-how-this-maps-onto-vip_chi)
18. [Multiple outstanding transactions](#18-multiple-outstanding-transactions)
19. [Glossary](#19-glossary)

---

## 1. What CHI is and where it sits

**CHI** is Arm's **cache-coherent, packet-based, credited** interconnect protocol.
It is the successor to ACE for high-end systems: where AXI/ACE use
address/data/response *channels with VALID/READY handshakes*, CHI uses
**unidirectional message channels carrying flits, with credit-based flow
control** and explicit **node-to-node routing** by ID.

Key characteristics that differ from AXI:

| Aspect | AXI/ACE | CHI |
|--------|---------|-----|
| Flow control | VALID/READY per channel | **Credit-based** (no READY); sender needs a credit to send |
| Transport | point-to-point | **routed** by `SrcID`/`TgtID` across an interconnect |
| Unit of transfer | beats on AW/W/B/AR/R | **flits** on REQ/RSP/DAT/SNP |
| Coherency | ACE adds snoop channels | native, with a **Home Node** directory/ordering point |
| Transaction match | AxID | **TxnID** (+ `DBID` for the data phase) |

CHI is used inside Arm CMN-style interconnects and by memory controllers that
expose a CHI **subordinate** port (which is exactly what `vip_mc` does, and why
`vip_chi` exists).

---

## 2. Node types and topology

Every CHI agent is a **node** with a unique **Node ID**. Three families:

- **Request Node (RN)** — issues transactions (reads, writes, etc.).
  - **RN-F** (*Fully coherent*): has a cache, must accept **snoops**.
  - **RN-I** (*I/O coherent*): no cache, issues requests but is **not snooped**.
  - **RN-D**: like RN-I but also handles DVM (TLB/maintenance) messages.
- **Home Node (HN)** — the ordering and coherency point for a region of address
  space. All requests for that region funnel through it.
  - **HN-F** (*Fully coherent*): owns the coherency directory/snoop filter, issues
    snoops to RN-Fs, orders requests, talks to memory behind it.
  - **HN-I** (*I/O*): an ordering/routing proxy for non-coherent (e.g. peripheral)
    space — no snoop fan-out.
- **Subordinate Node (SN)** — the endpoint that actually holds data (memory).
  - **SN-F**: a memory target (e.g. a DRAM/memory-controller port). Never issues
    requests, never snooped; it just **completes** the requests routed to it.
  - **SN-I**: subordinate for I/O/peripheral space.
- **Miscellaneous Node (MN)** — handles DVM and similar system messages.

```text
        snoops          requests              requests
 RN-F ◀────────  HN-F ◀──────────  (other RNs)        HN-F ──────────▶ SN-F (memory)
   │  responses    │  directory/order                    completions     ▲
   └──── requests ─┘                                                      │
                                                                     vip_mem-like store

 RN-I ──── requests ────▶ HN-I ──── requests ────▶ SN-I/SN-F   (no snoops anywhere)
```

A **typical full system**: RN → HN (orders + snoops peers if coherent) → SN
(memory). A **direct RN↔SN pair** (no HN) is the simplest legal topology for
non-coherent traffic, and is exactly what `vip_chi`'s first cut models: an RN-I
talking straight to an SN-F.

---

## 3. The layered model

CHI is defined in three layers:

1. **Protocol layer** — transactions, opcodes, coherency states, the rules for
   what responses a request requires. This is "what the traffic *means*."
2. **Network / transport layer** — routing flits between nodes using `TgtID` /
   `SrcID`. In a point-to-point bring-up (like this VIP) there is effectively no
   routing fabric; IDs still travel in the flits.
3. **Link layer** — turns messages into **flits**, manages **L-credits**, and
   runs the **link activation** handshake. This is "how bits cross one hop."

A **flit** (*flow control unit*) is the atomic unit a channel transfers in one
cycle. A protocol message is usually one flit (REQ/RSP), but a data transfer can
be several DAT flits (**beats**).

---

## 4. Channels

CHI has **four** logical channel types. Each physical channel instance is
**unidirectional**.

| Channel | Carries | Driven by |
|---------|---------|-----------|
| **REQ** | Requests (reads, writes, CMOs, atomics, prefetch…) | requester → home/subordinate |
| **RSP** | Responses with no data (Comp, DBIDResp, RetryAck, CompAck, ReadReceipt…) | either direction |
| **DAT** | Data (read data, write data, snoop data) | either direction |
| **SNP** | Snoops (coherency queries/invalidations) | home → coherent RN only |

Because channels are unidirectional, each **node** has a set of **TX** (outgoing)
and **RX** (incoming) channels appropriate to its role:

- **RN-F** TX: REQ, RSP, DAT.  RX: **SNP**, RSP, DAT.
- **RN-I** TX: REQ, RSP, DAT.  RX: RSP, DAT.  *(no SNP — not snooped)*
- **SN-F** TX: RSP, DAT.  RX: REQ, DAT.  *(no REQ out, no SNP)*
- **HN-F** sits in the middle and has the union, including SNP TX.

So a non-coherent **RN-I ↔ SN-F** pair uses **six unidirectional channels**:

```text
                 REQ  (ReadNoSnp / WriteNoSnp / …)
   RN-I  ───────────────────────────────────────────▶  SN-F
         ◀───────────────────────────────────────────
                 RSP  (Comp, DBIDResp, ReadReceipt…)

   RN-I  ───────── DAT (write data) ─────────────────▶  SN-F
         ◀──────── DAT (read CompData) ───────────────
                 (DAT is used in BOTH directions)

   RN-I  ───────── RSP (CompAck) ────────────────────▶  SN-F
```

Note **DAT is bidirectional at the pair level**: write data flows RN→SN, read
data flows SN→RN, on *separate* TX/RX DAT channels. (This is why `vip_chi_if`
keeps distinct `txdat*`/`rxdat*` groups per role.)

---

## 5. The physical interface: flit signal groups

Every channel `X` (REQ/RSP/DAT/SNP), in a given direction, is a bundle of four
signal groups. Using the `TX` direction as the example (`RX` is the mirror):

| Signal | Driver | Meaning |
|--------|--------|---------|
| `TXxFLITPEND` | sender | **Flit pending** — early "a flit is coming next cycle" hint. Lets the receiver wake clock-gated logic. A *performance* signal; not part of the data contract. |
| `TXxFLITV` | sender | **Flit valid** — the flit on `TXxFLIT` is valid **this** cycle. Asserting it **consumes exactly one L-credit**. |
| `TXxFLIT` | sender | **The flit payload** — the packed message (all the fields: opcode, addr, IDs, data, …). |
| `TXxLCRDV` | **receiver** | **Link credit valid** — the receiver grants **one** L-credit per asserted cycle. Flows opposite to the data. |

For an RN that has REQ/RSP/DAT out and SNP/RSP/DAT in, that is a lot of signals;
hence the verbose CHI signal list. The crucial point:

> **There is no `READY` signal.** A sender transfers a flit by asserting `FLITV`
> for one cycle, and it is *only allowed to do so if it currently holds a
> link-credit*. The receiver must have a buffer slot for every credit it has
> granted, so an accepted flit can never be back-pressured. Flow control is
> **100% credit-based**.

`FLITPEND` may be asserted speculatively and then `FLITV` need not follow
immediately — treat `FLITPEND` as advisory and key all functional behavior off
`FLITV`.

---

## 6. Link layer: activation

Before any flit or credit can move, the link must be **activated**. Each
unidirectional link has its own 2-signal activation handshake:

- `TXLINKACTIVEREQ` — driven by the **transmitter**, "I want the link up."
- `TXLINKACTIVEACK` — driven by the **receiver**, "acknowledged."

(The opposite link uses `RXLINKACTIVEREQ`/`RXLINKACTIVEACK` from this node's
point of view.)

These two bits encode a **4-state link state machine**:

| State | `REQ` | `ACK` | Meaning |
|-------|:-----:|:-----:|---------|
| **STOP** | 0 | 0 | Link down; no flits, no credits. |
| **ACTIVATE** | 1 | 0 | TX has requested up; RX is bringing it up and starts **granting initial L-credits**. |
| **RUN** | 1 | 1 | Link up; flits may be sent (if credits held); credits flow. |
| **DEACTIVATE** | 0 | 1 | TX has requested down; sender must **return all outstanding L-credits** before STOP. |

Legal transitions form a loop: `STOP → ACTIVATE → RUN → DEACTIVATE → STOP`. The
**transmitter** moves REQ (0→1 to start, 1→0 to tear down); the **receiver**
moves ACK in response. You cannot skip states.

Two practical rules:
- **Credits are only granted/consumed in RUN** (initial grant begins as the link
  enters RUN from ACTIVATE).
- **Before going to STOP**, the side that holds credits must **return them all**
  during DEACTIVATE, so both sides' credit accounting returns to zero. Tearing
  the link down with credits outstanding is illegal.

A reset (`rst_n` low) forces the link back to STOP and zeroes all credit/in-flight
state; the link must be re-activated after reset deasserts.

---

## 7. Link credits (L-Credits)

**L-Credits are per-channel, per-direction buffering permits.** They are the
entire flow-control mechanism in CHI.

How it works, for one channel `X` in one direction:

1. After activation, the **receiver** advertises its buffer depth by pulsing
   `XLCRDV` once per credit (e.g. 4 pulses ⇒ 4 initial credits). Each pulse =
   "I have room for one more flit."
2. The **sender** keeps a credit counter. It may assert `XFLITV` (send a flit)
   **only if its counter > 0**, and each `FLITV` **decrements** the counter by 1.
3. When the receiver frees a buffer slot (it has consumed/forwarded a flit), it
   pulses `XLCRDV` again to **return** the credit; the sender **increments**.
4. The counter therefore oscillates but never exceeds the total the receiver
   ever granted. A sender that runs out of credits simply stalls until more are
   returned — *that* is back-pressure.

Key consequences and gotchas:

- **One credit = one flit of buffering.** It is a hard guarantee: the receiver
  *must* be able to sink every flit it has granted a credit for. There is no
  retry at the link layer.
- **Initial grant arrives on the wire**, as `LCRDV` pulses after the link enters
  RUN — there is no out-of-band "pre-seeding." A model that pre-loads its credit
  counter *and* also counts the initial-grant pulses will double-count. (This is
  the exact subtlety `vip_chi`'s credit model must get right to interoperate with
  a real CHI DUT.)
- **L-Credits are independent per channel** (REQ has its own, RSP its own, DAT
  its own) and per direction. A `ReqLCrdReturn`/`PCrdReturn`-style "credit
  return" message is a *protocol*-credit concept (next section), distinct from
  these link credits.
- L-Credits say nothing about *which* transaction — they are pure transport
  buffering. Transaction identity lives in the flit fields.

---

## 8. Protocol credits (P-Credits)

Separate from link buffering, the **protocol layer** has its own credit/retry
mechanism so a completer (typically a Home Node, or an SN with limited resources)
can refuse a request it currently has no resource for, instead of blocking the
link.

The flow:

1. A requester sends a REQ with **`AllowRetry = 1`** — "I hold no protocol credit
   for you; you are allowed to bounce me."
2. If the completer cannot accept it, it replies on RSP with **`RetryAck`**
   (this does *not* complete the transaction; it parks it). The completer
   remembers it owes the requester a credit, tagged with a **`PCrdType`**.
3. When the completer frees a resource, it sends **`PCrdGrant`** (on RSP) carrying
   the matching `PCrdType`.
4. The requester now **re-sends the same request** — *same `TxnID`* — but with
   **`AllowRetry = 0`** and the granted `PCrdType`. Because the requester now
   holds a protocol credit, the completer must accept it.
5. Unused protocol credits are handed back with **`PCrdReturn`**.

So:
- **L-Credit** = "do I have a link buffer slot to put this flit in?" (transport).
- **P-Credit** = "does the completer have a transaction-tracking resource to
  accept this request?" (protocol). Conveyed via `RetryAck`/`PCrdGrant`/`PCrdType`/
  `AllowRetry`.

A request can be retried multiple times; `TxnID` is held (not freed) across the
retry, and the data/response phase only happens after a non-retried acceptance.

**A credit belongs to a `PCrdType`, not to a transaction.** §2.11 states it
outright — *"There is no fixed relationship between credits and particular
transactions"* — and two consequences follow that are easy to get wrong:

- **A granted credit may be spent on a different request** than the one whose
  `RetryAck` earned it, provided the `PCrdType` matches. A requester banks
  credits *by type* and draws from that bank; it does not hold one aside per
  bounced transaction.
- **`PCrdGrant` may arrive *before* the `RetryAck` it answers.** §2.11 names the
  reordering explicitly and makes absorbing it mandatory: *"It is possible that
  a reordering interconnect can reorder the responses such that the PCrdGrant is
  received by the Requester before the RetryAck response for the transaction is
  received. In this case, the Requester **must** record the credit it has
  received, including the credit type, so that it can assign the credit
  appropriately when it does receive the RetryAck response."* The specification
  softens the likelihood — *"It is expected to be rare"* — but not the
  requirement.

Step 4 above therefore reads more precisely as: the requester re-sends once it
*holds* a credit of the owed type, whenever and however that credit arrived.

---

## 9. Transaction identifiers

CHI threads identity through several fields:

- **`TxnID`** — the requester's handle for a transaction. Must be **unique among a
  source node's outstanding transactions** (10 bits in CHI-D, 12 bits in CHI-E).
  Responses echo it so the requester can match them.
- **`SrcID` / `TgtID`** — node IDs used to route the flit. A response swaps them
  (the completer's `SrcID` is the requester's `TgtID`, etc.).
- **`DBID` (Data Buffer ID)** — *the completer's* handle for the write-data
  buffer it just allocated. When a completer is ready to receive write data it
  sends `DBIDResp`/`CompDBIDResp` carrying a `DBID`. The requester then sends the
  write-data flits with their **`TxnID` field set to that `DBID`** (not the
  original request `TxnID`). This is why "write data is keyed on DBID" — it tells
  the completer which of its buffers the data belongs in.
- **`ReturnNID` / `ReturnTxnID`** — for **separated** responses (e.g.
  `ReadNoSnpSep`), the request tells the data source *where* to send the data
  (`ReturnNID`) and *what TxnID* to stamp on it (`ReturnTxnID`), since the data
  may come from a different node than the one that sent the response.
- **`LPID` (Logical Processor ID)** — sub-identifies a logical processor/thread
  within one RN (5 bits CHI-D, 8 bits CHI-E). Lets a single node multiplex
  several logical sources.
- **`HomeNID`** — on data flits, identifies the home node involved.

The lifetime of a `TxnID` at the requester: allocate on issue → hold through any
`RetryAck` retries → release when the transaction's completion arrives
(`Comp` / `CompData` / `CompDBIDResp`; for a *separated* read, the later of
`RespSepData` and `DataSepResp`). A `DBIDResp` alone does **not** free the
original request `TxnID` — completion does.

---

## 10. Key request fields

A REQ flit carries (names per CHI; not exhaustive):

| Field | Meaning |
|-------|---------|
| `Opcode` | What kind of request (see §13). 6 bits CHI-D / 7 bits CHI-E. |
| `Addr` | Physical address (up to 44 bits CHI-D, 52 bits CHI-E). |
| `Size` | Transfer size as a power of two — see §11. |
| `NS` | Non-secure bit (Arm security state of the access). |
| `Order` | Ordering requirement for this request (see §15). |
| `MemAttr` | Memory attributes (cacheable/bufferable/device/etc.). |
| `SnpAttr` | Snoop attribute (coherent requests). |
| `Excl` | Exclusive access (LL/SC-style atomics via exclusive monitor). |
| `ExpCompAck` | "Expect CompAck" — this transaction's completion must be acknowledged by the requester with a `CompAck` (used for ordering; see §15). |
| `AllowRetry` | Protocol-retry permission (see §8). |
| `PCrdType` | Protocol-credit type for the retry handshake. |
| `LPID` | Logical processor id (§9). |
| `QoS` | 4-bit quality-of-service / priority hint for arbitration. |
| `LikelyShared`, `DoDWT`, `Endian` | Coherency/data hints (mostly CHI-E and coherent flows). |
| `TraceTag` | Debug/trace marker propagated through the transaction. |
| `MPAM` | Memory-system performance partitioning/monitoring id (optional). |
| `TagOp` / `Tag` / `TU` | **CHI-E** Memory Tagging Extension fields (allocation tags). |
| `RSVDC` | Reserved-for-user bits (implementation-defined sideband). |

---

## 11. Data transfer

- **Cache line = 64 bytes**, always, in CHI. Most coherent transfers move a full
  line; non-coherent reads/writes can be smaller.
- **`Size`** is a 3-bit log2 byte count: `0→1B, 1→2B, 2→4B, 3→8B, 4→16B, 5→32B,
  6→64B` (the value `7` is reserved). So a transaction moves `2^Size` bytes.
- **DAT data width** is an implementation parameter (commonly 128/256/512 bits).
  If a transfer is larger than one DAT flit's data field, it is split into
  multiple **beats**.
  - Number of beats for a transfer ≈ `ceil(transfer_bytes / data_bytes_per_flit)`.
  - With a 512-bit (64B) data path, every legal transfer fits in **one** beat.
- **`DataID`** — identifies *which chunk* of the 64B line this beat carries
  (its position, in units of the data-path width). The receiver reassembles beats
  by `DataID`.
- **`CCID` (Critical Chunk ID)** — which chunk is the *critical* (first-requested)
  one, so a requester can be unblocked as soon as the needed chunk arrives even if
  the line streams out of order.
- **`BE` (Byte Enable)** — one bit per data byte; says which bytes are valid/
  written. Essential for **partial writes** (`WriteNoSnpPtl`): only `BE`-set bytes
  are committed.
- **`Poison`** — one bit per 64 bits of data, marking that chunk as containing a
  detected-but-uncorrected error (consumer should fault if it uses it).
- **`DataCheck`** — per-byte parity/check bits for end-to-end data-integrity
  checking across the link (separate purpose from `BE`).

---

## 12. Responses: Resp vs RespErr

Two **separate** fields travel on responses/data — do not conflate them:

- **`RespErr`** (2 bits) — the **completion status / error**:

  | Value | Name | Meaning |
  |:-----:|------|---------|
  | `00` | **NormalOkay** (OK) | Success. |
  | `01` | **ExclusiveOkay** (EXOKAY) | Exclusive access succeeded. |
  | `10` | **DERR** (Data Error) | Data is returned but **corrupt** (e.g. uncorrectable ECC at a valid location). |
  | `11` | **NDERR** (Non-Data Error) | Request **rejected** — no valid data (e.g. unmapped/illegal address). |

- **`Resp`** (3 bits) — the resulting **cache-line coherence state** for coherent
  responses (`I`, `UC`, `UD`, `SC`, `SD`, …). For non-coherent traffic this is
  effectively `I` and carries little meaning.

A memory subordinate (SN-F) thus reports errors via **`RespErr`**: `NDERR` for a
rejected/unmapped access, `DERR` for "here is the data but it's flagged corrupt."
"DECERR" is an AXI concept — CHI has no separate DECERR field; an
address-decode failure is simply `RespErr = NDERR`.

---

## 13. Transaction flows

Only the non-coherent + memory flows are detailed here (the ones `vip_chi`
implements first); coherent flows are sketched in §14.

### 13.1 Non-snooping read — `ReadNoSnp`

```text
RN ──REQ: ReadNoSnp (Addr,Size,TxnID)──▶ SN
RN ◀─DAT: CompData (Data beats, TxnID, RespErr)── SN
```
The completer returns the data on the **DAT** channel as `CompData`, one or more
beats, echoing the request `TxnID`, with `RespErr` status. Done.

### 13.2 Separated read — `ReadNoSnpSep` (and `ReadReceipt`)

A "separated" read splits the *response* (a status flit) from the *data*. Unlike
every other flow in this file it is a **three-node** flow, and which node sends
what is the whole point of it:

```text
RN ──REQ: Read* ─────────────────────────────────────▶ HN
RN ◀─RSP: RespSepData (status) ───────────────────────  HN
              HN ──REQ: ReadNoSnpSep (ReturnNID, ReturnTxnID)──▶ SN
              HN ◀─RSP: ReadReceipt ──────────────────────────── SN
RN ◀─DAT: DataSepResp (Data, keyed on ReturnTxnID) ─────────────  SN
```

Three restrictions from §2.3.1, all of them about the *sender*:

- `ReadNoSnpSep` **must only be sent by the Home to the Slave**. Appendix B
  Table B-1 gives it two `From` rows, `ICN(HN-F)→SN-F` and `ICN(HN-I)→SN-I`;
  there is no row in which a Request Node sends it.
- `RespSepData` **is permitted from the Home only** — Table B-3 gives it one
  `From` row, `ICN(HN-F, HN-I)`. A Slave may not send it.
- The Slave **must send `ReadReceipt` to the Home** after receiving
  `ReadNoSnpSep`. That is the Slave's own owed response, not an ordering
  courtesy: unlike `ReadReceipt` on an ordinary read, it is owed whether or not
  the request's `Order` field demands one.

The data leg goes to `ReturnNID`/`ReturnTxnID`, and Table B-4 lists `SN-F →
RN-F, RN-D, RN-I` as its **expected** target — so the data reaches the original
requester directly, bypassing the Home.

**What this VIP does, and how it differs.** The `vip_chi_agent` topology is
point-to-point `RN-I ↔ SN-F`: there is no Home component on the link. On the
separated-read path the **RN-I agent stands in for the Home**, playing the
Home's REQ leg — which is what the item constraint forcing `ReturnNID == SrcID`
has always been compensating for. The Slave's half is then literally
conformant: `ReadReceipt` goes to the Home stand-in and `DataSepResp` to the
requester.

The departure is the `ReadNoSnpSep` originator, and it is checked rather than
assumed: `CHI_SB_ORIGINATOR_LEGAL` encodes Appendix B and grants the RN-I a
Home's originator rights for that one opcode. `scoreboard.home_standin = 0`
takes the grant away and makes the checker report the departure, which is what
`tc_chi_e_sep_read_negctl` phase 2 asserts. Earlier versions of this VIP had the
completer answer with `RespSepData` — a Home-only response emitted by a Slave —
and nothing could see it, because the only party judging the flow was the VIP's
own completer. See F-CORR-013.

### 13.3 Non-snooping write — `WriteNoSnpFull` / `WriteNoSnpPtl`

The write **data cannot be sent until the completer grants a buffer (DBID)**:

```text
RN ──REQ: WriteNoSnp* (Addr,Size,TxnID,ExpCompAck?)──▶ SN
RN ◀─RSP: CompDBIDResp (DBID, RespErr)────────────── SN   (combined: "ready + complete")
RN ──DAT: NCBWrData (Data/BE, TxnID = DBID)─────────▶ SN
   (if ExpCompAck:)
RN ──RSP: CompAck ─────────────────────────────────▶ SN
```
- `WriteNoSnpFull` writes a whole `Size`-region; `WriteNoSnpPtl` writes only the
  `BE`-enabled bytes.
- The completer can answer in **one combined** flit (`CompDBIDResp` = grant +
  completion) or **split** it into `DBIDResp` (grant first) then a deferred
  `Comp` (completion after the data is committed). The split form exposes the
  window where data has been sent but completion hasn't arrived — useful for
  testing.
- The **write data flit's `TxnID` field = the `DBID`** the completer gave
  (§9), so the completer routes it to the right buffer.
- If `ExpCompAck = 1` (ordered write), the requester must send a final `CompAck`
  *after* it has received completion.

### 13.4 Zero write — `WriteNoSnpZero` (CHI-E)

A write that zeroes the addressed region with **no data transfer at all**: the
completer just zeroes the bytes and completes. No DAT beats.

The completion is still a *write* completion, though — `DBIDResp` and a `Comp`,
or the combined `CompDBIDResp`. A bare `Comp` is not one of the legal forms. The
granted buffer is never used, because the requester sends no data; the grant is
part of the response shape regardless.

### 13.5 Atomics (CHI-D/E) — `AtomicStore/Load/Swap/Compare`

A read-modify-write performed *at the completer*:
- The RN sends the request and then the **operand** on DAT.
- The completer applies the operation to memory.
- For `AtomicStore` there is no return value (just completion); for
  `AtomicLoad` / `AtomicSwap` / `AtomicCompare` the completer returns the
  **original (pre-op) value** as `CompData`.

### 13.6 `PrefetchTgt`

A pure **hint**: "you may want to fetch this address." It receives **no protocol
response** — fire-and-forget.

### 13.7 `PCrdReturn`

Returns an unused protocol credit to the completer (§8). No data, no completion.

---

## 14. Coherency in one page

Coherent flows (RN-F ↔ HN-F) are **out of scope for `vip_chi`'s first cuts** but
worth understanding so you know what's being avoided:

- Cache lines have **MOESI-like states**, named in CHI as `I` (Invalid), `UC`
  (Unique Clean), `UD` (Unique Dirty), `SC` (Shared Clean), `SD` (Shared Dirty),
  plus partials.
- A coherent read (`ReadShared`, `ReadUnique`, `ReadClean`, `ReadOnce`, …) goes to
  the **Home Node**, which consults its **snoop filter/directory** and, if needed,
  **snoops** peer RN-Fs over the **SNP** channel (`SnpShared`, `SnpUnique`,
  `SnpClean`, `SnpOnce`, …).
- Snooped caches respond with `SnpResp` (state) and optionally `SnpRespData` (the
  line), which the HN forwards.
- Writes back to memory use `WriteBack*`/`WriteClean*`/`Evict`; cache maintenance
  uses `CleanShared`/`CleanInvalid`/`MakeInvalid`/`CleanSharedPersist` (the last
  for durability/persistence).
- `MakeUnique`/`CleanUnique` obtain write permission without (necessarily)
  fetching data.

The reason a memory-target VIP can ignore all of this: an **SN-F is never
snooped and holds no coherency state** — it just stores bytes and completes
`*NoSnp*` requests. The Home Node absorbs all coherency complexity.

---

## 15. Ordering

By default CHI requests to *different* addresses are **unordered** — the
interconnect may reorder them. Ordering is requested explicitly:

- **`Order` field (request):** raises the ordering requirement, e.g.
  *Request Accepted* order or *Request Order* (Endpoint Order). When set, the
  completer issues a **`ReadReceipt`** (reads) or orders the request relative to
  others from the same source. This is how device-memory ordering and
  producer/consumer streams are enforced.
- **`ExpCompAck` + `CompAck` (writes):** an *ordered write* sets `ExpCompAck`, and
  the requester sends a `CompAck` after receiving completion. This closes the
  ordering loop so the home/endpoint knows the requester has observed completion
  before subsequent ordered transactions proceed.
- **`DBIDRespOrd` (CHI-E):** an ordered variant of the write `DBIDResp` that
  additionally conveys ordering guarantees.

Same-address hazards (a read and write to the same line) are always ordered by the
home/endpoint regardless of the `Order` field.

---

## 16. CHI-D vs CHI-E deltas

The two issues this VIP supports differ in width and feature set:

| Aspect | CHI-D | CHI-E |
|--------|-------|-------|
| `TxnID` width | 10 bits (1024 ids) | 12 bits (4096 ids) |
| `ReqOpcode` / `RspOpcode` width | 6 / 4 bits | 7 / 5 bits |
| `LPID` width | 5 bits | 8 bits |
| Memory Tagging (`TagOp`/`Tag`/`TU`) | — | yes |
| `WriteNoSnpZero` | — | yes |
| `MakeReadUnique` | — | yes |
| `DBIDRespOrd` (ordered DBID) | — | yes |
| `StashOnceSep*`, `CleanSharedPersistSep` | — | yes |

Because the wider/extra-field version is a **superset**, a single source base can
support both by defining all fields at max width and **gating** the CHI-E-only
opcodes/fields by the configured issue (which is exactly the `vip_chi_types`
strategy).

---

## 17. How this maps onto `vip_chi`

Tying the protocol back to the VIP (see `IMPLEMENTATION_PLAN.md` for detail):

- **Roles** are the `vip_chi_role_t` values: `RNI`, `SNF`, `HNI`, `MONITOR`.
  First cut implements the **RN-I initiator** and the **SN-F memory responder**;
  the SN-F has a real `vip_mem` backing store.
- **Channels/signals** live in `vip_chi_if.sv` with the verbatim CHI signal names
  (`txreqflitv`, `txreqflit`, `txreqlcrdv`, `txlinkactivereq`, …). Each role has a
  clocking block (`rni_cb`/`snf_cb`) that drives its TX groups and samples its RX
  groups; the monitor samples everything.
- **L-credits** are tracked in `vip_chi_lcrd_mgr` (a counted credit object) plus a
  per-driver `credit_loop()` that returns one credit per observed `LCRDV` pulse
  and emits return pulses on consumed flits. Getting the **initial-grant** model
  right (credits advertised on the wire vs pre-seeded) is what makes it
  interoperate with a real CHI DUT — see PLAN §10.
- **P-credits / retry** are exercised by the `cfg.force_retry_count` knob (SN-F
  bounces a retryable REQ with `RetryAck` + `PCrdGrant`; the RN-I holds, waits the
  grant, and re-issues) — see `tc_chi_retry`. Serial path only.
- **Transactions**: the RN-I driver implements §13.1–13.3 (read, separated read,
  write with DBID-keyed data, split/combined completion, ordered `CompAck`); the
  SN-F driver implements the completer side against `vip_mem`, including
  `RespErr = NDERR`/`DERR` injection by address range.
- **Item fields** in `vip_chi_item` mirror §10–§12 (identity, request, data,
  response). The stimulus API (PLAN §12) is what lets a test set any of these
  per-transaction.

---

## 18. Multiple outstanding transactions

Nothing in CHI says "one transaction at a time." A requester may have **as many
transactions in flight as it has free `TxnID`s** (§9), bounded only by the
link credits it has been granted (§7) and, for writes, the completer's data-buffer
grants (`DBID`, §8/§9). Completions come back tagged with the original `TxnID`, so
they can arrive **in any order** and the requester still matches each one. This is
the whole point of the ID space — it lets a real RN keep the pipe full instead of
stalling a full round-trip per access.

A verification model can nonetheless choose to be **single-outstanding**: issue one
request, wait for its completion, then issue the next. That is deterministic and
trivial to self-check, but it never exercises a DUT's ability to track several
concurrent `TxnID`s, reorder completions, or manage its DBID pool under pressure.
So `vip_chi` keeps the serial path as the default and adds an **opt-in
multi-outstanding datapath** that decouples issue from completion.

**Reads vs writes are asymmetric.** A read completes purely on *inbound* data
(`CompData` on DAT), so its driver can cleanly split into an "issue" thread and a
"collect" thread. A write, however, must **drive `WriteData` mid-transaction** —
only after the completer returns a `DBID` grant — so its TX bus has a single owner
that issues the `REQ`, waits for the grant, drives the data, and retires. The
completer side (SN-F) needs no change: its buffered capture thread keeps returning
`REQ` credit while a response is still in flight, which is exactly what lets the
requester stack requests up.

The RN-I driver therefore has just two loops: the default **serial** `seq_loop`,
and a single **multi-outstanding** pipeline (`seq_loop_mixed_pipelined`) taken
whenever `cfg.multi_outstanding` is set (the master switch; `0` keeps every serial
test byte-identical). That one pipeline overlaps plain reads and writes together,
so read-only, write-only and mixed traffic are all just the same loop fed a
different stream — a single-direction sequence simply never enqueues the other
kind. The table below is therefore a guide to *usage patterns*, not distinct code
paths:

| Usage pattern | `cfg` (with `multi_outstanding=1`) | What overlaps | Completion path(s) | Example test(s) |
|---|---|---|---|---|
| **Serial** (default) | `multi_outstanding=0` → `seq_loop` | nothing — one txn at a time | per-opcode, inline | the other 33 tests |
| **Read-only** | *(no extra flag)* | `ReadNoSnp` (any `Order`) | inbound DAT `CompData` (+ RSP `ReadReceipt` if ordered) | `tc_chi_multi_outstanding`, `_ordered_read` |
| **Write-only** | `multi_outstanding_write`† | `WriteNoSnpFull` / `WriteNoSnpPtl` (± `ExpCompAck`, any `Order`) | inbound RSP `CompDBIDResp`, or split `DBIDResp`+`Comp` (+ TX `CompAck`) | `tc_chi_multi_outstanding_write`, `_partial`, `_split`, `_compack`, `_ordered` |
| **Mixed** | `multi_outstanding_mixed`† | reads **and** writes together | DAT for reads, RSP for writes (never contend) | `tc_chi_multi_outstanding_mixed` (phased), `tc_chi_multi_outstanding_concurrent` (simultaneous) |
| **Atomic** | *(no extra flag)* | `AtomicStore`/`Load`/`Swap`/`Compare` | grant on RSP + operand on TX DAT, then RSP `Comp` (store) or inbound DAT `CompData` (non-store, returns pre-op value) | `tc_chi_multi_outstanding_atomic` |
| **Persist** | *(no extra flag)* | `CleanSharedPersist` / CHI-E `CleanSharedPersistSep` | RSP only, no data: a single `Comp`, or `Persist` (stepped over) then `CompPersist` (separated) | `tc_chi_multi_outstanding_persist`, `_persist_sep` |

† The `multi_outstanding_write` / `multi_outstanding_mixed` flags are retained for
back-compat but no longer select distinct loops — they all run the one pipeline.

Depth is capped by `cfg.max_outstanding_read` / `max_outstanding_write`. The driver
publishes two peaks so a test can *prove* overlap actually happened rather than
assume it: **`observed_peak_outstanding`** (max total in flight) and
**`observed_peak_mixed_inflight`** (max depth sampled while a read *and* a write
were simultaneously live — `> 1` only if the two directions truly coexisted, which
a phased "write then read" test never achieves but the concurrent test does).

Overlap currently covers `ReadNoSnp` (ordered reads consume their `ReadReceipt`)
and full/partial `WriteNoSnp` (`WriteNoSnpFull` / `WriteNoSnpPtl`, the latter
carrying per-byte BE), with either a combined `CompDBIDResp` or a split
`DBIDResp`+`Comp` write
completion, `ExpCompAck` writes (the TX thread drives the `CompAck` after
completion), ordered writes (any `Order` value — the CompAck is the ordering
point), atomics (a store atomic completes on RSP just like a write, while a
non-store atomic (`AtomicLoad`/`Swap`/`Compare`) issues write-like (grant +
operand DAT) and then completes read-like, the completer returning the pre-op
value on `CompData`), and persist CMOs (`CleanSharedPersist` / CHI-E
`CleanSharedPersistSep`) which carry no data and complete on RSP only. The
protocol-credit retry handshake (`RetryAck`/`PCrdGrant`, opt-in
`cfg.force_retry_count`) is implemented on the serial driver but is not overlapped
in the pipeline. The HN-I proxy is likewise serial by design.
See `IMPLEMENTATION_PLAN.md` §P4 for the opcode scope and owed extensions.

---

## 19. Glossary

| Term | Expansion / meaning |
|------|---------------------|
| **CHI** | Coherent Hub Interface (Arm AMBA 5). |
| **RN / HN / SN** | Request / Home / Subordinate Node. Suffix `-F` fully coherent, `-I` I/O, `-D` DVM, `-F` (SN) memory. |
| **MN** | Miscellaneous Node (DVM, etc.). |
| **REQ/RSP/DAT/SNP** | The four channel types: request, response, data, snoop. |
| **Flit** | Flow-control unit; one channel transfer. |
| **Beat** | One DAT flit of a multi-flit data transfer. |
| **L-Credit** | Link credit — per-channel transport buffering permit (`LCRDV`). |
| **P-Credit** | Protocol credit — completer resource permit, via retry handshake. |
| **TxnID** | Transaction ID (requester's handle). |
| **DBID** | Data Buffer ID (completer's write-data buffer handle). |
| **SrcID / TgtID** | Source / target node IDs (routing). |
| **NID** | Node ID (`ReturnNID`, `HomeNID`, …). |
| **LPID** | Logical Processor ID. |
| **Size** | log2 of transfer bytes (`2^Size`, 1–64 B). |
| **DataID** | Chunk position of a data beat within the 64 B line. |
| **CCID** | Critical Chunk ID (which chunk is requested first). |
| **BE** | Byte Enable (per-byte write mask). |
| **RespErr** | 2-bit completion status: OK / EXOKAY / DERR / NDERR. |
| **Resp** | 3-bit resulting cache-line coherence state. |
| **DERR / NDERR** | Data Error (corrupt data returned) / Non-Data Error (request rejected). |
| **CompData** | Read-data + completion on DAT. |
| **DBIDResp / CompDBIDResp** | Write-buffer grant (separate / combined with completion). |
| **NCBWrData** | Non-CopyBack Write Data (non-coherent write data on DAT). |
| **CompAck** | Completion acknowledgement from requester (ordered transactions). |
| **ReadReceipt** | Ordering ack for an ordered read. |
| **RetryAck / PCrdGrant / PCrdType / AllowRetry** | Protocol-credit retry handshake (§8). |
| **ExpCompAck** | Request bit demanding a `CompAck`. |
| **Order** | Request field selecting an ordering requirement. |
| **MTE** | Memory Tagging Extension (CHI-E `TagOp`/`Tag`/`TU`). |
| **CMO** | Cache Maintenance Operation (`CleanShared`, `CleanInvalid`, `CleanSharedPersist`, …). |
| **DVM** | Distributed Virtual Memory (TLB/maintenance messages). |
| **QoS** | Quality of Service priority field. |
| **MPAM** | Memory System Performance Partitioning And Monitoring. |
| **Poison** | Per-64-bit marker for detected-uncorrected data error. |
| **DataCheck** | Per-byte data-integrity check bits. |
| **`sactive`** | "Snoop/system active" sideband indicating outstanding activity (used for safe link deactivation). |
| **LINKACTIVEREQ/ACK** | Link activation handshake (STOP/ACTIVATE/RUN/DEACTIVATE). |
| **FLITPEND / FLITV / FLIT / LCRDV** | The four per-channel signal groups (§5). |

---

*This primer is intentionally protocol-focused. For VIP structure, roles,
sequences, and the feature roadmap, see `IMPLEMENTATION_PLAN.md` in this
directory.*
