################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of vip_chi_cfg_agent.sv.
#
# Per-agent runtime policy: role, active/passive, credit caps + initial grants,
# split-write / ordered-DBID policy, DECERR/DERR ranges, timeouts, and the
# (inert-until-Tier-C) coherent RN-F/HN-F knobs. A plain settable object; in SV
# it extends uvm_object only for the factory. Defaults mirror the SV class.
#
# mem_cfg (the SN-F backing-store config) is left None here and constructed by
# the memory-backed SN-F driver in Tier A2, so the config layer carries no hard
# dependency on the vip_memory port yet.
#
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import Role, Resp, DatInterleavePolicy

# is_active values (mirror uvm_active_passive_enum).
UVM_ACTIVE = True
UVM_PASSIVE = False


class VipChiCfgAgent:

  def __init__(self, name: str = "vip_chi_cfg_agent"):
    self.name = name

    self.is_active = UVM_ACTIVE
    self.role = Role.SNF

    self.max_outstanding_read = 16
    self.max_outstanding_write = 16

    # Requester bound on P-credits banked but not yet consumed, summed over
    # every PCrdType. A completer may only grant a protocol credit against a
    # RetryAck it has already sent, so the bank cannot legitimately outgrow this
    # node's own bounced requests. 0 disables the bound.
    self.max_pcrd_budget = 8

    # Speculative TXSACTIVE extension, in cycles past the close of the
    # outstanding window. TXSACTIVE says the node MAY have snoopable
    # transactions outstanding, so holding it longer than strictly necessary is
    # always legal -- it only costs the receiver the chance to gate its snoop
    # logic. Raising this models a node that keeps the sideband up briefly in
    # anticipation of more traffic. Default 0 drops it as soon as the window
    # closes, which is the tightest legal behaviour and the one the checks
    # bound against.
    self.txsactive_extend_max_cycles = 0

    # Opt-in multi-outstanding datapath (Tier B). Default off = strict serial.
    self.multi_outstanding = False
    self.multi_outstanding_write = False
    self.multi_outstanding_mixed = False
    self.observed_peak_outstanding = 0
    self.observed_peak_mixed_inflight = 0

    # Initial LCRDV grants advertised after link activation per inbound channel.
    self.initial_req_credits = 8
    self.initial_rsp_credits = 8
    self.initial_dat_credits = 8

    # Local caps for peer-advertised send-side credits (via inbound LCRDV).
    self.req_send_credit_cap = 64
    self.rsp_send_credit_cap = 64
    self.dat_send_credit_cap = 64

    # Runtime DAT-credit back-pressure (tc_chi_d_credit_starvation).
    self.hold_dat_credit = False

    self.decerr_ranges = []   # list of (base, limit)
    self.derr_ranges = []     # list of (base, limit)

    self.force_retry_count = 0
    self.split_write_rsp = False
    self.ordered_dbid_resp = False

    # Return P-credits this requester banked but never used, with PCrdReturn.
    # The specification requires unused credits to be returned "in a timely
    # manner" -- holding one leaves the completer's re-issue slot reserved
    # forever. Default off because returning a credit puts an extra REQ flit on
    # the wire, which would change the waveform of every existing retry test.
    self.return_unused_pcrd = False

    # CleanSharedPersistSep has two legal completions: a Comp (the request
    # reached the Point of Coherency) followed by a Persist (it reached the Point
    # of Persistence), or the two combined into a single CompPersist. A requester
    # must accept both, so the completer must be able to produce both. Default
    # off = separate Comp then Persist, which is the form that carries the PoC
    # and PoP milestones as distinguishable events; the combined form collapses
    # them.
    self.combined_persist_rsp = False

    # Completer DAT beat ordering. CHI identifies a beat's position by its
    # DataID, not by its position in the burst, so a completer may return the
    # beats of one transfer in any order. Set this to have the SN-F return read
    # data in DESCENDING DataID, which proves the monitor reassembles by DataID
    # rather than by arrival.
    self.snf_reverse_dat_beats = False

    # Negative control for the monitor's duplicate-DataID check: the SN-F sends
    # the final beat of a read burst carrying DataID 0 again instead of its own
    # position, so one position arrives twice and one never arrives.
    self.snf_duplicate_dat_beat = False

    # How many in-flight read transfers the completer may take DAT beats from
    # before finishing any one of them. 1, the default, is the behaviour this VIP
    # has always had: a read's beats are emitted contiguously, so the DAT channel
    # carries one transfer at a time and every existing test sees the same wire.
    #
    # Above 1 the SN-F drains up to this many queued reads together, one beat at
    # a time in the order dat_interleave_policy names. That is legal because a
    # DAT flit is self-identifying -- TxnID says which transaction, DataID says
    # which position -- and CHI nowhere requires the beats of a transfer to be
    # contiguous on the channel. It is worth reaching because a receiver that
    # assumes contiguity reassembles correctly right up until something upstream
    # stops being contiguous, and then reports a DATA MISMATCH rather than a
    # reassembly fault.
    #
    # Requires multi_outstanding: the serial responder never holds two requests
    # at once, so there is never a second stream to interleave with (is_valid()
    # rejects the combination rather than leaving the knob silently inert).
    self.dat_interleave_depth = 1

    # Which eligible stream the next beat comes from. Only consulted when
    # dat_interleave_depth > 1.
    self.dat_interleave_policy = DatInterleavePolicy.ROUND_ROBIN

    # Cycles the responder will wait, with a read already queued, for enough
    # further reads to fill dat_interleave_depth.
    #
    # A completer only has something to interleave when two transfers are queued
    # at once, and a requester pipelines its requests a cycle or two apart --
    # without a window the responder starts the first read's data before the
    # second request is even off the wire, and dat_interleave_depth would look
    # enabled while never once engaging. Bounded, and only entered while a read
    # is already waiting, so nothing stalls on traffic that is not coming.
    #
    # Only consulted when dat_interleave_depth > 1, which is what keeps the
    # default responder's timing untouched.
    self.dat_interleave_gather_cycles = 8

    # Negative control for the MTE tag checks: the exact-CHI-E completer returns
    # the stored tag with its low bit inverted on the FIRST beat of a read burst,
    # and a different TagOp on the last beat.
    #
    # Two rules, two breakages, one knob, because they fail independently: a
    # completer whose tag store is corrupt returns the wrong tag under a
    # perfectly consistent TagOp, and one that loses track of the transfer
    # returns the right tags under a TagOp that changes mid-burst.
    self.snf_corrupt_tag = False

    # Per-transaction latency bounds, in cycles on the monitor's reset-gated
    # counter. 0 = unbounded, which is the default and preserves behaviour: a
    # bench that has never stated a latency budget should not acquire one. A
    # non-zero bound is checked at the completion milestone of each transaction,
    # so a test that cares about latency can FAIL on it rather than read it out
    # of a report after the fact.
    self.max_read_xact_latency = 0
    self.max_write_xact_latency = 0
    self.max_snp_xact_latency = 0

    # Record the arrival cycle of every DAT beat on the item (t_dat_beats).
    # Off by default: it costs an append per beat of every transfer, which is
    # not worth paying in a long run for a detail most tests never read. The
    # transaction-level milestones are always stamped and cost nothing per beat.
    self.collect_beat_timestamps = False

    # Waveform-correlated transaction recording in the monitor
    # (accept_tr / begin_tr / end_tr). Off by default: recording costs time on
    # every transaction of every run, which is not worth paying in a long
    # regression for something only read when a specific flow is being debugged.
    #
    # See vip_chi_monitor._record_begin for what this port can and cannot do
    # with it: pyUVM 4.0.1's recording backend is a stub, so the lifecycle is
    # recorded on the item but no waveform stream is produced.
    self.record_transactions = False

    # Same-line hazard rule: a requester must not have two requests outstanding
    # to one cache line at a time. On by default. A bench whose requester model
    # deliberately overlaps same-line requests turns it off rather than papering
    # over the reports.
    self.hazard_check_enable = True

    # Negative control for the scoreboard's ordered-stream check: the buffered
    # SN-F serves the SECOND of two queued ordered requests before the first, so
    # its acknowledgements come back in the wrong order while every transaction
    # still completes correctly on its own. Nothing else in the VIP can see the
    # inversion, which is the point -- it isolates the ordering check.
    self.snf_reorder_ordered_service = False

    # Negative control for the link-activation state machine check: the RN-I
    # raises txlinkactivereq and withdraws it again before the completer
    # acknowledges, stepping the LASM out of ACTIVATE without ever reaching RUN.
    # A requester that has asked for the link must wait for the acknowledge, so
    # this is a genuine illegal transition rather than an unusual-but-legal
    # sequence. It fires once per activation; the link then comes up normally.
    self.lasm_abort_activation = False

    # Negative control for the FLITPEND rules: the requester pulses
    # txreqflitpend and txrspflitpend for one cycle with no flit behind them,
    # once, after the link is up.
    #
    # What this polices is a VIP EMISSION CONVENTION, not a CHI mandate, and the
    # distinction matters. CHI's FLITPEND is a one-cycle-ahead hint that a flit
    # MIGHT follow, and a transmitter is permitted to assert it and then not
    # send -- discouraged, but legal. This VIP instead emits FLITPEND alongside
    # the flit it belongs to (the DAT driver raises it on every beat but the
    # last, to mean "more beats coming"), so a lone FLITPEND here means a driver
    # has lost track of its own burst. Same standing as the DataID-ordering
    # rules, which hold this VIP's in-order emission convention rather than a
    # CHI requirement.
    self.flitpend_without_valid = False

    # -- Graceful link deactivation -------------------------------------------
    # Raised by a test, not by the driver: there is no such thing as an idle
    # moment a driver can detect for itself. Its sequence loop blocks on the
    # sequencer forever, so "no traffic right now" is indistinguishable from
    # "between two sequences", and a driver that tore the link down on that guess
    # would deactivate in the middle of every test. The test knows when it is
    # finished; the driver does not.
    #
    # The requester then walks the second half of the LASM cycle it otherwise
    # never touches -- RUN -> DEACTIVATE -> STOP -- returning every L-credit it
    # holds on the way, because a link that stops with credits still banked
    # leaves the two ends disagreeing about what the peer may send after the next
    # bring-up (CHI_LCRD_QUIESCENT_IN_STOP is the rule that says so).
    #
    # Lowering it again brings the link back up, so one test can prove the whole
    # cycle: down cleanly, and up again carrying traffic.
    self.link_deactivate_request = False

    # Published by the driver, read by the test: set once the link has reached
    # STOP with every credit returned, cleared when it comes back up. A test
    # polls this rather than the sideband wires so it waits for the DRAIN to
    # finish and not merely for the signal to fall.
    self.link_deactivate_done = False

    # Negative controls for the two LASM timeouts (which live on the TESTBENCH
    # config, not here -- a stuck link is a property of the link, and the checker
    # that judges it is bound to an interface rather than to one endpoint's
    # driver). Both are completer-side, because the completer owns LINKACTIVEACK
    # and a stuck link is exactly an acknowledge that does not arrive:
    #   * _activation_   delays the acknowledge to a bring-up request.
    #   * _deactivation_ delays dropping the acknowledge once the link is drained.
    # Both count in cycles and default to 0 (no delay).
    self.lasm_stall_activation_cycles = 0
    self.lasm_stall_deactivation_cycles = 0

    self.mem_cfg = None       # constructed by the SN-F driver (A2)

    # Cycles the requester waits before asserting txlinkactivereq, indexed by
    # the LINK STATE it observes at that moment (LasmState: STOP, DEACTIVATE,
    # ACTIVATE, RUN).
    #
    # Every other delay in this VIP is a uniform min/max per channel, which can
    # only ever produce the same bring-up shifted in time. Making the delay a
    # function of the state the link is ALREADY in is what makes activation
    # races reachable -- a request timed to land inside the peer's tear-down
    # window is a different scenario, not the same one later, and it is
    # precisely what the LASM transition rule exists to judge.
    #
    # All zero by default, which reproduces today's behaviour exactly.
    self.lasm_req_delay_by_state = [0, 0, 0, 0]

    # Negative control for the LASM transition rule under a RACE rather than a
    # malformed sequence: the requester re-raises txlinkactivereq as soon as the
    # link enters DEACTIVATE, without waiting for the tear-down to reach STOP.
    #
    # {req=1, ack=1} is RUN, so the link jumps DEACTIVATE -> RUN, which the
    # cycle does not allow (DEACTIVATE may only advance to STOP). Distinct from
    # lasm_abort_activation, which breaks the BRING-UP half; this breaks the
    # tear-down half, and only became reachable once graceful deactivation
    # existed.
    self.lasm_reactivate_during_deactivate = False

    self.link_act_delay_enabled = True
    self.link_act_delay_min = 0
    self.link_act_delay_max = 4

    self.req_valid_delay_enabled = True
    self.req_valid_delay_min = 0
    self.req_valid_delay_max = 4

    self.rsp_valid_delay_enabled = False
    self.rsp_valid_delay_min = 0
    self.rsp_valid_delay_max = 2

    self.dat_valid_delay_enabled = False
    self.dat_valid_delay_min = 0
    self.dat_valid_delay_max = 2

    self.coverage_enabled = True
    self.allow_raw_override = True
    self.compack_timeout_cycles = 10000

    # -- Coherent RN-F / HN-F knobs (inert for non-coherent roles) -----------
    self.initial_snp_credits = 8
    self.snp_send_credit_cap = 64
    self.hold_snp_credit = False
    self.coh_read_shared_state = Resp.SC
    self.coh_read_unique_state = Resp.UC
    self.rnf_cache_max_lines = 0
    self.hnf_snoop_latency = 0
    self.hnf_suppress_snoops = False
    self.hnf_corrupt_dirty_merge = False
    self.exclusives_enabled = True
    self.hnf_force_excl_success = False
    self.hnf_enable_snoop_fwd = False
    self.hnf_corrupt_fwd_data = False
    self.hnf_downstream_en = False
    self.hnf_downstream_snf_id = 0
    self.hnf_downstream_corrupt_data = False
    self.hnf_downstream_force_decerr = False

  # ==========================================================================
  # is_valid -- runtime configuration self-check.
  #
  # vip_chi_agent's elaboration check validates the static envelope. This
  # validates the runtime object, which had no equivalent: an inconsistent
  # combination used to be discarded silently or to fail much later, deep inside
  # a driver, with a message that named the symptom rather than the cause.
  #
  # Reports EVERY problem it finds rather than stopping at the first, so one run
  # tells the user everything they need to change. Returns True when clean.
  # `silent` suppresses the reports and returns the verdict only.
  #
  # Two related rules live outside this function because they need information
  # the cfg object does not carry: `role` versus the agent's role, and
  # max_outstanding_* versus the TxnID width, both checked in the agent's
  # build_phase where the ChiCfg envelope and the role are in scope.
  # ==========================================================================
  def is_valid(self, silent: bool = True, logger=None) -> bool:
    ok = True

    def err(msg):
      nonlocal ok
      ok = False
      if not silent and logger is not None:
        logger.error(f"[VIP_CHI_CFG] {msg}")

    def warn(msg):
      if not silent and logger is not None:
        logger.warning(f"[VIP_CHI_CFG] {msg}")

    # -- Outstanding / pipeline ----------------------------------------------
    if self.max_outstanding_read < 1:
      err(f"max_outstanding_read is {self.max_outstanding_read}; must be >= 1 "
          f"(1 = strictly serial reads)")
    if self.max_outstanding_write < 1:
      err(f"max_outstanding_write is {self.max_outstanding_write}; must be >= 1 "
          f"(1 = strictly serial writes)")
    if self.max_pcrd_budget < 0:
      err(f"max_pcrd_budget is {self.max_pcrd_budget}; use 0 to leave the "
          f"P-credit bank unbounded")
    # No SV counterpart: there the field is `int unsigned`, so the language
    # already rules this out.
    if self.txsactive_extend_max_cycles < 0:
      err(f"txsactive_extend_max_cycles is {self.txsactive_extend_max_cycles}; "
          f"use 0 to drop TXSACTIVE as soon as the outstanding window closes")

    # The overlap-path selectors do nothing on their own: the RN-I only leaves
    # the serial issue path when multi_outstanding is set, so setting one of
    # these alone discards the user's intent without a word.
    if self.multi_outstanding_write and not self.multi_outstanding:
      err("multi_outstanding_write is set without multi_outstanding: the write "
          "overlap path never engages")
    if self.multi_outstanding_mixed and not self.multi_outstanding:
      err("multi_outstanding_mixed is set without multi_outstanding: the mixed "
          "overlap loop never engages")

    # The reorder knob only has anything to reorder when the SN-F buffers
    # requests; on the serial loop each REQ is serviced to completion before the
    # next is even sampled, so the negative control would silently do nothing.
    if self.snf_reorder_ordered_service and not self.multi_outstanding:
      err("snf_reorder_ordered_service is set without multi_outstanding: the "
          "serial SN-F loop never holds two requests at once, so nothing is "
          "reordered")

    # Zero is not "no interleaving", it is a depth no scheduler can honour -- the
    # emitter would have no stream to take a beat from. Reject it rather than
    # quietly reading it as 1.
    if self.dat_interleave_depth == 0:
      err("dat_interleave_depth is 0: the minimum is 1, which is one transfer "
          "at a time (no interleaving)")

    # Same reasoning as snf_reorder_ordered_service above: the serial loop
    # services one REQ to completion before sampling the next, so there is never
    # a second beat stream and the knob would be inert.
    if self.dat_interleave_depth > 1 and not self.multi_outstanding:
      err("dat_interleave_depth > 1 without multi_outstanding: the serial SN-F "
          "loop never holds two reads at once, so no beats are ever interleaved")

    # The abort is driven by activate_link, which only the requester roles run;
    # on a completer the knob would set a flag nothing reads and the negative
    # control would silently pass with the check never having fired.
    if self.lasm_abort_activation and self.role not in (Role.RNI, Role.RNF):
      err("lasm_abort_activation is set on a role that does not originate link "
          "activation: only a requester raises txlinkactivereq, so there is no "
          "activation to abort")

    # The requester pulses REQ+RSP FLITPEND; the home pulses SNP FLITPEND. Both
    # run the control, and between them they cover all three rules.
    if self.flitpend_without_valid and self.role not in (Role.RNI, Role.RNF,
                                                         Role.HNF):
      err("flitpend_without_valid is set on a role whose driver does not run "
          "the pulse: the requester emits it on REQ/RSP and the home on SNP, so "
          "on any other role it would set a flag nothing reads")

    # Same reasoning as the abort above, and the same failure if it is ignored:
    # deactivation is driven by whoever raised the request in the first place.
    if (self.lasm_reactivate_during_deactivate
        and self.role not in (Role.RNI, Role.RNF)):
      err("lasm_reactivate_during_deactivate is set on a role that does not "
          "originate link activation")

    if self.link_deactivate_request and self.role not in (Role.RNI, Role.RNF):
      err("link_deactivate_request is set on a role that does not originate "
          "link activation: only a requester drives txlinkactivereq, so there "
          "is no request to withdraw")

    # The mirror image: the stall knobs delay an acknowledge, and only a
    # completer drives one. On a requester they would set a flag nothing reads.
    if ((self.lasm_stall_activation_cycles or
         self.lasm_stall_deactivation_cycles) and
        self.role not in (Role.SNF, Role.HNF, Role.HNI)):
      err("a lasm_stall_*_cycles knob is set on a role that does not drive "
          "txlinkactiveack: only a completer acknowledges, so there is no "
          "acknowledge to delay")

    # -- Link credits ---------------------------------------------------------
    # The initial grant is advertised on the wire and then accumulates against
    # the local cap; a grant larger than its own cap can never be fully banked.
    for chan in ("req", "rsp", "dat", "snp"):
      initial = getattr(self, f"initial_{chan}_credits")
      cap = getattr(self, f"{chan}_send_credit_cap")
      if initial > cap:
        err(f"initial_{chan}_credits ({initial}) exceeds "
            f"{chan}_send_credit_cap ({cap})")

    # -- Completer policy -----------------------------------------------------
    if self.force_retry_count < 0:
      err(f"force_retry_count is {self.force_retry_count}; use 0 to never "
          f"bounce a retryable request")
    if self.compack_timeout_cycles < 0:
      err(f"compack_timeout_cycles is {self.compack_timeout_cycles}; must not "
          f"be negative")

    for name, ranges in (("decerr_ranges", self.decerr_ranges),
                         ("derr_ranges", self.derr_ranges)):
      for i, (base, limit) in enumerate(ranges):
        if base > limit:
          err(f"{name}[{i}] is inverted: base 0x{base:x} > limit 0x{limit:x}")

    # An address in both windows has two contradictory fates: DECERR completes
    # the request with a non-data error, DERR returns data marked corrupt. The
    # completer checks DECERR first, so the DERR entry is silently unreachable.
    for i, (dc_base, dc_limit) in enumerate(self.decerr_ranges):
      for j, (de_base, de_limit) in enumerate(self.derr_ranges):
        if dc_base <= de_limit and de_base <= dc_limit:
          err(f"decerr_ranges[{i}] (0x{dc_base:x}..0x{dc_limit:x}) overlaps "
              f"derr_ranges[{j}] (0x{de_base:x}..0x{de_limit:x}): DECERR wins, "
              f"so the DERR window is unreachable there")

    # -- Coherent -------------------------------------------------------------
    if self.rnf_cache_max_lines < 0:
      err(f"rnf_cache_max_lines is {self.rnf_cache_max_lines}; use 0 for an "
          f"unbounded cache")

    # A bounded cache evicts CLEAN victims silently and has no writeback path
    # for a dirty one, so a single-line bound fails in the driver as soon as the
    # workload dirties a second line. Warn rather than reject: it is a legal
    # setting for a workload that never does.
    if 0 < self.rnf_cache_max_lines < 2:
      warn(f"rnf_cache_max_lines is {self.rnf_cache_max_lines}: "
           f"writeback-on-eviction of a DIRTY victim is not modeled, so a "
           f"workload that dirties more lines than this will fail in the RN-F "
           f"driver")

    # The negative-control knobs deliberately break coherency. Leaving one set
    # outside its own negative-control test turns a real failure into a
    # mystifying one, so say so -- but do not reject: the negative-control tests
    # are exactly the legitimate users.
    negctl = {
      "hnf_suppress_snoops": self.hnf_suppress_snoops,
      "hnf_corrupt_dirty_merge": self.hnf_corrupt_dirty_merge,
      "hnf_force_excl_success": self.hnf_force_excl_success,
      "hnf_corrupt_fwd_data": self.hnf_corrupt_fwd_data,
      "hnf_downstream_corrupt_data": self.hnf_downstream_corrupt_data,
      "hnf_downstream_force_decerr": self.hnf_downstream_force_decerr,
      "snf_duplicate_dat_beat": self.snf_duplicate_dat_beat,
      "snf_corrupt_tag": self.snf_corrupt_tag,
      "snf_reorder_ordered_service": self.snf_reorder_ordered_service,
      "lasm_abort_activation": self.lasm_abort_activation,
      "lasm_reactivate_during_deactivate": self.lasm_reactivate_during_deactivate,
      "flitpend_without_valid": self.flitpend_without_valid,
    }
    on = [k for k, v in negctl.items() if v]
    if on:
      warn(f"a negative-control knob is set ({', '.join(on)}): this "
           f"deliberately breaks the invariant a checker guards")

    if self.hnf_downstream_en and self.hnf_suppress_snoops:
      warn("hnf_downstream_en with hnf_suppress_snoops: the two-level hierarchy "
           "runs against a home that is deliberately incoherent")

    # -- Delays ---------------------------------------------------------------
    # An inverted min/max makes the uniform draw see a reversed range, so it
    # stops meaning what the knob names say.
    for chan in ("link_act", "req_valid", "rsp_valid", "dat_valid"):
      lo = getattr(self, f"{chan}_delay_min")
      hi = getattr(self, f"{chan}_delay_max")
      if lo < 0:
        err(f"{chan}_delay_min is {lo}; a delay cannot be negative")
      if lo > hi:
        err(f"{chan}_delay window is inverted: min {lo} > max {hi}")

    return ok

  def add_decerr_range(self, base: int, limit: int) -> None:
    self.decerr_ranges.append((int(base), int(limit)))

  def add_derr_range(self, base: int, limit: int) -> None:
    self.derr_ranges.append((int(base), int(limit)))

  def __repr__(self):
    return (f"VipChiCfgAgent(role={Role(self.role).name}, "
            f"active={self.is_active}, multi_outstanding={self.multi_outstanding})")
