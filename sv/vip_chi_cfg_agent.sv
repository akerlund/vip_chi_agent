`ifndef VIP_CHI_CFG_AGENT
`define VIP_CHI_CFG_AGENT

import uvm_pkg::*;
`include "uvm_macros.svh"
import vip_chi_types_pkg::*;

class vip_chi_cfg_agent extends uvm_object;

  `uvm_object_utils(vip_chi_cfg_agent)

  uvm_active_passive_enum is_active = UVM_ACTIVE;
  vip_chi_role_t          role      = VIP_CHI_ROLE_SNF_E;

  uvm_verbosity req_verbosity = UVM_HIGH;
  uvm_verbosity rsp_verbosity = UVM_HIGH;
  uvm_verbosity dat_verbosity = UVM_HIGH;

  int max_outstanding_read  = 16;
  int max_outstanding_write = 16;
  int max_pcrd_budget       = 8;

  // Opt-in multi-outstanding datapath (P4). Default 0 preserves the strict
  // serial path every existing testcase relies on. When set on BOTH the RN-I
  // and SN-F cfg, the RN-I decouples read issue from completion (several reads
  // in flight at once) and the SN-F buffers inbound REQs so pipelined requests
  // are not dropped while it is mid-response. First cut overlaps plain
  // ReadNoSnp only; other opcodes still run serially on the issue thread.
  bit multi_outstanding = 1'b0;

  // Selects the WRITE overlap path on the RN-I when multi_outstanding is also
  // set: read issue/completion (0, default) versus write issue/completion (1).
  // The first write cut overlaps plain WriteNoSnpFull (order NONE, no CompAck,
  // combined CompDBIDResp grant) only; the SN-F side needs no extra flag because
  // its buffered loop already services reads and writes. Ignored unless
  // multi_outstanding is set, so every serial test is unaffected.
  bit multi_outstanding_write = 1'b0;

  // Selects the unified MIXED overlap loop on the RN-I when multi_outstanding is
  // also set: one pipelined loop handles both plain ReadNoSnp and plain
  // WriteNoSnpFull, so a single test can pipeline writes and then read them back
  // for an end-to-end data-integrity check. Takes precedence over
  // multi_outstanding_write; ignored unless multi_outstanding is set.
  bit multi_outstanding_mixed = 1'b0;

  // Published by the RN-I driver: peak simultaneously in-flight transactions
  // observed, so a test can confirm overlap actually happened (not just that
  // the traffic completed serially).
  int unsigned observed_peak_outstanding = 0;

  // Published by the RN-I mixed loop: peak in-flight depth sampled at a moment
  // when at least one read AND one write were simultaneously in the pipeline, so
  // a test can prove true bidirectional overlap rather than merely same-
  // direction pipelining. 0 means reads and writes never coexisted in flight.
  int unsigned observed_peak_mixed_inflight = 0;

  // Number of initial LCRDV grants this agent advertises after link activation
  // for each inbound channel it can consume.
  int unsigned initial_req_credits = 8;
  int unsigned initial_rsp_credits = 8;
  int unsigned initial_dat_credits = 8;

  // Local caps for peer-advertised send-side credits accumulated through
  // inbound LCRDV pulses. These are intentionally decoupled from the initial
  // receive-credit grants this agent advertises on the wire.
  int unsigned req_send_credit_cap = 64;
  int unsigned rsp_send_credit_cap = 64;
  int unsigned dat_send_credit_cap = 64;

  // When set, this agent stops advertising DAT receive credits on the wire: the
  // grants it would emit accumulate and are drained once the flag clears. A test
  // can toggle it at runtime to starve the peer's DAT sends (see
  // tc_chi_credit_starvation) without the harness having to pinch the wire.
  bit hold_dat_credit = 1'b0;

  vip_chi_decerr_range_t decerr_ranges [];
  vip_chi_derr_range_t   derr_ranges   [];

  int force_retry_count = 0;

  bit split_write_rsp = 1'b0;
  bit ordered_dbid_resp = 1'b0;

  vip_mem_config mem_cfg;

  bit link_act_delay_enabled = 1'b1;
  int link_act_delay_min        = 0;
  int link_act_delay_max        = 4;

  bit req_valid_delay_enabled = 1'b1;
  int req_valid_delay_min        = 0;
  int req_valid_delay_max        = 4;

  bit rsp_valid_delay_enabled = 1'b0;
  int rsp_valid_delay_min        = 0;
  int rsp_valid_delay_max        = 2;

  bit dat_valid_delay_enabled = 1'b0;
  int dat_valid_delay_min        = 0;
  int dat_valid_delay_max        = 2;

  bit coverage_enabled   = 1'b1;
  bit allow_raw_override = 1'b1;

  int compack_timeout_cycles = 10000;

  // ---------------------------------------------------------------------------
  // Coherent (RN-F / HN-F) knobs. Ignored by the non-coherent roles, so every
  // existing test is unaffected.
  // ---------------------------------------------------------------------------
  // Initial SNP receive-credit budget an RN-F advertises after link activation
  // so the HN-F may source snoops toward it. Local cap for the HN-F's own SNP
  // send-side budget accumulated through inbound SNP LCRDV pulses.
  int unsigned initial_snp_credits = 8;
  int unsigned snp_send_credit_cap = 64;

  // Runtime SNP back-pressure knob (mirrors hold_dat_credit): when set, an RN-F
  // stops advertising SNP receive credits, so its queued grants never reach the
  // wire and the HN-F's SNP send pool starves -- an inbound snoop stalls until it
  // clears. tc_chi_coh_snp_backpressure holds it from build so even the initial
  // credits are withheld, then releases to prove the parked snoop + read complete.
  bit hold_snp_credit = 1'b0;

  // HN-F granted cache state per coherent-read class (M2: no snoops, single
  // grant). A shared-class read (ReadShared/ReadClean/ReadNotSharedDirty) lands
  // the requester in SC; a unique-class read (ReadUnique) lands it in UC. Kept
  // as knobs so a test can force a particular grant without a raw override.
  vip_chi_resp_t coh_read_shared_state = VIP_CHI_RESP_STATE_SC_E;
  vip_chi_resp_t coh_read_unique_state = VIP_CHI_RESP_STATE_UC_E;

  // RN-F cache capacity, in cache lines. 0 = unbounded (default, spec-legal and
  // what every existing test relies on). When > 0, allocating a line beyond the
  // bound triggers a SILENT eviction: a clean victim (SC/UC) is dropped with no
  // bus transaction (the home keeps a stale directory entry, resolved on a later
  // snoop). Writeback-on-eviction of a DIRTY victim is not modeled -- a bounded
  // cache that fills entirely with dirty lines fatals (see docs/FUTURE_WORK.md).
  int rnf_cache_max_lines = 0;

  // Snoop-origination latency (cycles the HN-F waits before issuing a snoop).
  // Unused until M3; declared now so the coherent config shape is stable.
  int unsigned hnf_snoop_latency = 0;

  // Negative-control knob: when set, the HN-F grants coherent reads WITHOUT
  // snooping the other sharers -- deliberately breaking coherency so a second
  // requester can end up a duplicate Unique owner. tc_chi_coherency_negctl uses
  // this to prove Checker D's single-writer invariant is not vacuous. Default 0
  // keeps the home fully coherent.
  bit hnf_suppress_snoops = 1'b0;

  // Negative-control knob: when set, the HN-F drops (does not merge) the dirty
  // data a snoop forwards as SnpRespData, so it completes the requester from
  // stale memory instead of the forwarded data -- a coherent data-integrity
  // break. tc_chi_coherency_data_negctl uses this to prove Checker D's
  // data-integrity check is not vacuous. Default 0 keeps the home coherent.
  bit hnf_corrupt_dirty_merge = 1'b0;

  // Master enable for exclusive (LL/SC) monitor modeling on the HN-F. When 0 the
  // home ignores req.excl entirely (no monitor set, every completion NormalOkay),
  // so a bench that never uses exclusives is byte-unaffected. Default 1: the home
  // honors exclusive accesses whenever an RN-F sets req.excl.
  bit exclusives_enabled = 1'b1;

  // Negative-control knob: when set, the HN-F reports ExclOkay on EVERY exclusive
  // CleanUnique (SC) regardless of whether the per-(line,port) monitor was still
  // valid -- deliberately claiming an SC won across an intervening conflict.
  // tc_chi_coh_excl_negctl uses this to prove Checker D's exclusive invariant is
  // not vacuous. Default 0 keeps the home honest (SC-success only on a live monitor).
  bit hnf_force_excl_success = 1'b0;

  // Master enable for direct-cache-transfer (DCT / forwarding-snoop) origination
  // on the HN-F. When 0 the home never issues a Snp*Fwd -- coherent reads take the
  // ordinary snoop-then-CompData-from-memory path, so every existing test is
  // byte-identical. When 1, a coherent read that hits a peer holder is served by a
  // forwarding snoop: the snoopee drives CompData straight to the requester and a
  // reduced SnpRespFwded/SnpRespDataFwded to the home, which the home relays
  // without sourcing data from its own memory. Default 0.
  bit hnf_enable_snoop_fwd = 1'b0;

  // Negative-control knob for the DCT data-integrity check: when set, the HN-F
  // corrupts the forwarded data on the relay leg (mirrors hnf_corrupt_dirty_merge
  // for the non-fwd dirty path) so the requester's CompData no longer matches the
  // data the snoopee forwarded. tc_chi_coh_fwd_data_negctl uses this to prove
  // Checker D's forwarded-data integrity check is not vacuous. Default 0.
  bit hnf_corrupt_fwd_data = 1'b0;

  // Two-level memory hierarchy: when set, the HN-F stops self-terminating and
  // instead issues downstream ReadNoSnp / WriteNoSnpFull to a real SN-F node for
  // directory-miss reads and writebacks (RN-F <-> HN-F <-> SN-F). Default 0 keeps
  // the HN-F terminating against its own vip_mem, so every existing coherent test
  // is byte-identical. hnf_downstream_snf_id is the SrcID/TgtID stamped on the
  // downstream link (node IDs are 0 in this bench).
  bit          hnf_downstream_en     = 1'b0;
  int unsigned hnf_downstream_snf_id = 0;

  // Negative-control knobs for the downstream data-integrity check: corrupt the
  // data the HN-F relays from a downstream fetch (XOR-invert), or force the SN-F
  // fetch to be treated as a DECERR. tc_chi_coh_snf_data_negctl uses these to
  // prove the end-to-end integrity check is not vacuous. Default 0.
  bit hnf_downstream_corrupt_data = 1'b0;
  bit hnf_downstream_force_decerr = 1'b0;

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name = "vip_chi_cfg_agent");
    super.new(name);
    this.mem_cfg = vip_mem_config::type_id::create("mem_cfg");
  endfunction

endclass

`endif