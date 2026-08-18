////////////////////////////////////////////////////////////////////////////////
//
// Copyright (C) 2026 Fredrik Akerlund
// https://github.com/akerlund/vip_chi_agent
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//
////////////////////////////////////////////////////////////////////////////////

`ifndef VIP_CHI_DRIVER_RNF
`define VIP_CHI_DRIVER_RNF

import uvm_pkg::*;
`include "uvm_macros.svh"
import vip_chi_types_pkg::*;

// -----------------------------------------------------------------------------
// Coherent requester (RN-F).
//
// RN-F is an RN-I that also participates in the coherence protocol: it issues
// coherent REQ opcodes (ReadShared/ReadClean/ReadUnique, ... MakeUnique/Evict/
// WriteBack in later milestones), holds a per-line cache-state model, and (from
// M3) answers snoops. It reuses the ENTIRE RN-I request/credit/link/retry
// machinery by extending vip_chi_driver_rni with ROLE_P=VIP_CHI_ROLE_RNF_E; the
// RNF interface arm exposes its driving clocking block under the name rni_cb (a
// superset that adds the SNP receive channel), so the inherited driver body
// binds without change. Only the coherent-specific additions live here, wired in
// through the three base extension hooks:
//   * post_activate_hook  - advertise the initial SNP receive credits.
//   * extra_rx_channels   - fork the SNP receive-credit loop (M3 adds the snoop
//                           responder).
//   * on_transaction_complete - record the granted state into the cache model.
//
// M2 scope: coherent READS only, and no snoop ever fires (the HN-F directory
// does not originate snoops yet), so the SNP receive channel carries credit but
// no traffic. The cache model tracks state only; data tracking + the snoop
// responder land in M3.
// -----------------------------------------------------------------------------
class vip_chi_driver_rnf #(
  vip_chi_cfg_t  CFG_P        = VIP_CHI_DEFAULT_CFG_C,
  type           FLIT_TYPES_T = vip_chi_types #(CFG_P)
  ) extends vip_chi_driver_rni #(CFG_P, FLIT_TYPES_T, VIP_CHI_ROLE_RNF_E);

  typedef vip_chi_types #(CFG_P)::addr_t   addr_t;
  typedef FLIT_TYPES_T::vip_chi_snp_flit_t snp_flit_t;
  typedef FLIT_TYPES_T::snp_opcode_t       snp_opcode_t;

  // Per-line cache-state model, keyed by the line-aligned address. Tracks the
  // held coherent state (populated from each coherent read's granted state); the
  // snoop responder answers from this shadow.
  vip_chi_resp_t cache_state [addr_t];

  // Per-line cached DATA, parallel to cache_state (one dynamic array of beats per
  // line). Populated from each coherent read's CompData, and mutated by
  // make_line_dirty() to model a local store that dirties a held line. When the
  // line is in a PassDirty state, a snoop forwards these beats to the home as
  // SnpRespData (M4b dirty forwarding). A parallel assoc array of dynamic arrays
  // (not a struct-with-dynarray) sidesteps the VCS assoc-of-struct quirk.
  protected data_t cache_data [addr_t][];

  // Outbound SNP receive-credit pulses queued for the HN-F (drained one per
  // cycle onto txsnplcrdv by snp_credit_loop, mirroring the RSP/DAT credit path).
  protected int unsigned snp_lcrdv_pulses_pending;

  `uvm_component_param_utils(vip_chi_driver_rnf #(CFG_P, FLIT_TYPES_T))

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent);
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  // Line-align an address to the coherence granule so every access to one line
  // maps to a single cache entry. CHI coherency operates on the 64 B cache line
  // (VIP_CHI_CACHE_LINE_BYTES_C), NOT the data-bus width: a narrow bus
  // (DATA_BYTES_P < 64) carries one line in several beats, so a mid-line address
  // must still resolve to the single line key (P1).
  // ---------------------------------------------------------------------------
  protected function addr_t line_addr(input addr_t addr);
    return addr & ~addr_t'(VIP_CHI_CACHE_LINE_BYTES_C - 1);
  endfunction

  // ---------------------------------------------------------------------------
  // TRUE for the coherent-read REQ opcodes this cut issues. ReadNoSnp stays
  // non-coherent and does not populate the cache.
  // ---------------------------------------------------------------------------
  protected function bit req_opcode_is_coherent_read(input req_opcode_t opcode);
    // MakeReadUnique fetches data into the unique state, so it populates the
    // cache exactly like ReadUnique. It is a CHI-E 7-bit opcode (0x41), matched
    // in the WIDE opcode domain so it cannot alias a narrow CHI-D opcode.
    if (vip_chi_req_opcode_t'(opcode) == VIP_CHI_REQ_MAKE_READ_UNIQUE_E) begin
      return 1'b1;
    end
    case (opcode)
      req_opcode_t'(VIP_CHI_REQ_READ_SHARED_C),
      req_opcode_t'(VIP_CHI_REQ_READ_CLEAN_C),
      req_opcode_t'(VIP_CHI_REQ_READ_UNIQUE_C): begin
        return 1'b1;
      end
      default: begin
        return 1'b0;
      end
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // TRUE for the invalidating CMOs the RN-F issues (CleanInvalid / MakeInvalid).
  // They complete RSP-only (a plain Comp, like Evict) and invalidate the
  // requester's own copy of the line.
  // ---------------------------------------------------------------------------
  protected function bit req_opcode_is_coherent_cmo(input req_opcode_t opcode);
    return (opcode == req_opcode_t'(VIP_CHI_REQ_CLEAN_INVALID_C)) ||
           (opcode == req_opcode_t'(VIP_CHI_REQ_MAKE_INVALID_C));
  endfunction

  // ---------------------------------------------------------------------------
  // TRUE for the non-allocating coherent writes (WriteUnique Full/Ptl). The
  // requester does not hold the line after the write (ends Invalid), so any copy
  // it happened to hold is dropped on completion.
  // ---------------------------------------------------------------------------
  protected function bit req_opcode_is_coherent_write_unique(input req_opcode_t opcode);
    return (opcode == req_opcode_t'(VIP_CHI_REQ_WRITE_UNIQUE_FULL_C)) ||
           (opcode == req_opcode_t'(VIP_CHI_REQ_WRITE_UNIQUE_PTL_C));
  endfunction

  // ---------------------------------------------------------------------------
  // Clear coherent-local state on reset (the base clears the RN-I bookkeeping).
  // ---------------------------------------------------------------------------
  function void handle_reset();
    this.cache_state.delete();
    this.cache_data.delete();
    this.snp_lcrdv_pulses_pending = 0;
    super.handle_reset();
    this.reset_snp_outputs();
  endfunction

  // ---------------------------------------------------------------------------
  // Model a local store into a line the RN-F holds: mutate the cached beats by
  // XORing a pattern and move the line to a unique-dirty (PassDirty) state, so a
  // subsequent snoop forwards the modified data to the home. The line must
  // already be held with data (acquired via a coherent read). Test-facing.
  // ---------------------------------------------------------------------------
  function void make_line_dirty(input addr_t addr, input data_t xor_pattern);
    addr_t line;

    line = this.line_addr(addr);
    if (!this.cache_data.exists(line)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] make_line_dirty on line 0x%0h that is not held with data",
        get_name(), line))
      return;
    end

    foreach (this.cache_data[line][i]) begin
      this.cache_data[line][i] = this.cache_data[line][i] ^ xor_pattern;
    end
    this.cache_state[line] = VIP_CHI_RESP_STATE_UP_PD_DIRTY_E;
  endfunction

  // ---------------------------------------------------------------------------
  // TRUE for the PassDirty cache states whose snoop response must carry data.
  // ---------------------------------------------------------------------------
  protected function bit state_is_dirty(input vip_chi_resp_t state);
    return (state == VIP_CHI_RESP_STATE_UP_PD_DIRTY_E) ||
           (state == VIP_CHI_RESP_STATE_SD_PD_DIRTY_E);
  endfunction

  // ---------------------------------------------------------------------------
  // Bounded-cache silent eviction. When cfg.rnf_cache_max_lines > 0 and allocating
  // `new_line` would exceed the bound, drop a CLEAN victim (SC/UC) SILENTLY -- no
  // bus transaction; the home keeps a (stale) directory entry that a later snoop
  // resolves, since the evicted line now answers the snoop Invalid. Deterministic
  // victim: the lowest-address clean line (assoc arrays iterate in key order). A
  // bounded cache full of DIRTY lines fatals -- writeback-on-eviction of a dirty
  // victim needs autonomous REQ origination and is not modeled (docs/FUTURE_WORK.md).
  // No-op when unbounded (max <= 0) or when new_line is already resident.
  // ---------------------------------------------------------------------------
  protected function void evict_for_capacity(input addr_t new_line);
    addr_t victim;
    bit    found;

    if (this.cfg.rnf_cache_max_lines <= 0) begin
      return;
    end
    if (this.cache_state.exists(new_line)) begin
      return;  // reusing a resident line -- no new allocation
    end

    while (this.cache_state.size() >= this.cfg.rnf_cache_max_lines) begin
      found = 1'b0;
      foreach (this.cache_state[a]) begin
        if (!this.state_is_dirty(this.cache_state[a])) begin
          victim = a;
          found  = 1'b1;
          break;
        end
      end
      if (!found) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] bounded RN-F cache (max %0d lines) is full of DIRTY lines while allocating 0x%0h; dirty writeback-on-eviction is not modeled (docs/FUTURE_WORK.md)",
          get_name(), this.cfg.rnf_cache_max_lines, new_line))
        return;
      end
      `uvm_info(get_name(), $sformatf(
        "[%s] bounded cache: silently evicting clean line 0x%0h to allocate 0x%0h",
        get_name(), victim, new_line), UVM_HIGH)
      this.cache_state.delete(victim);
      if (this.cache_data.exists(victim)) begin
        this.cache_data.delete(victim);
      end
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Public reset hook: idle the SNP-side output in addition to the RN-I outputs.
  // ---------------------------------------------------------------------------
  function void reset_vif();
    super.reset_vif();
    this.reset_snp_outputs();
  endfunction

  // ---------------------------------------------------------------------------
  // Drive the RN-F SNP receive-credit output to idle.
  // ---------------------------------------------------------------------------
  protected function void reset_snp_outputs();
    this.vif_rni.g_drv.rni_cb.txsnplcrdv <= 1'b0;
  endfunction

  // ---------------------------------------------------------------------------
  // Advertise the initial SNP receive-credit budget once the link is up.
  // ---------------------------------------------------------------------------
  protected task post_activate_hook();
    this.snp_lcrdv_pulses_pending += this.cfg.initial_snp_credits;
  endtask

  // ---------------------------------------------------------------------------
  // Fork the coherent receive channels alongside the base credit loop: the SNP
  // receive-credit loop and the autonomous snoop responder.
  // ---------------------------------------------------------------------------
  protected task extra_rx_channels();
    fork
      this.snp_credit_loop();
      this.snoop_responder();
    join_none
  endtask

  // ---------------------------------------------------------------------------
  // Emit one-cycle txsnplcrdv pulses for the queued SNP receive credits. Drives
  // only txsnplcrdv, which no other loop touches, so it coexists with the base
  // credit_loop on the shared rni_cb clock.
  // ---------------------------------------------------------------------------
  protected task snp_credit_loop();
    bit snp_hold;
    forever begin
      @(this.vif_rni.g_drv.rni_cb);

      // cfg.hold_snp_credit lets a test starve the HN-F's SNP send pool by pausing
      // credit advertisement; the pending grants accumulate and drain once cleared.
      snp_hold = this.cfg.hold_snp_credit;

      this.vif_rni.g_drv.rni_cb.txsnplcrdv <= (this.snp_lcrdv_pulses_pending != 0) && !snp_hold;

      if ((this.snp_lcrdv_pulses_pending != 0) && !snp_hold) begin
        this.snp_lcrdv_pulses_pending--;
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  // Queue one returned SNP receive credit (drained onto txsnplcrdv by the loop).
  // ---------------------------------------------------------------------------
  protected function void schedule_snp_credit_return();
    this.snp_lcrdv_pulses_pending++;
  endfunction

  // ---------------------------------------------------------------------------
  // Autonomous snoop responder: capture each inbound snoop, return its credit,
  // update the cache state, and drive the SnpResp. Independent of the request
  // thread so a snoop is answered from the current cache state regardless of
  // what the requester side is doing.
  // ---------------------------------------------------------------------------
  protected task snoop_responder();
    snp_flit_t snp;

    forever begin
      while (!this.vif_rni.g_drv.rni_cb.rxsnpflitv) begin
        @(this.vif_rni.g_drv.rni_cb);
        this.drive_idle_sideband();
      end

      snp = this.vif_rni.g_drv.rni_cb.rxsnpflit;
      this.schedule_snp_credit_return();

      // Step off the accepted snoop beat before responding.
      @(this.vif_rni.g_drv.rni_cb);
      this.drive_idle_sideband();

      // A snoop response is outbound activity this node owes the home, so it
      // opens a TXSACTIVE window of its own: the request-side count knows
      // nothing about it, and a SnpRespData burst can span many cycles during
      // which the sideband must not drop.
      this.tx_activity_begin();
      this.process_snoop(snp);
      this.tx_activity_end();
    end
  endtask

  // ---------------------------------------------------------------------------
  // TRUE for the forwarding (DCT) snoop opcodes -- the snoopee forwards its data
  // for relay to the requester instead of answering a plain SnpResp/SnpRespData.
  // ---------------------------------------------------------------------------
  protected function bit snp_opcode_is_fwd(input snp_opcode_t op);
    case (op)
      snp_opcode_t'(VIP_CHI_SNP_SHARED_FWD_C),
      snp_opcode_t'(VIP_CHI_SNP_CLEAN_FWD_C),
      snp_opcode_t'(VIP_CHI_SNP_ONCE_FWD_C),
      snp_opcode_t'(VIP_CHI_SNP_NOT_SHARED_DIRTY_FWD_C),
      snp_opcode_t'(VIP_CHI_SNP_UNIQUE_FWD_C): return 1'b1;
      default: return 1'b0;
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // Resulting cache state after a snoop, for the clean (no-data) cases handled
  // in this cut. Dirty forwarding (SnpRespData / PassDirty) is M4.
  //   Snp{Shared,Clean,CleanShared} -> retain Shared (SC), unless already I.
  //   Snp{Unique,CleanInvalid,MakeInvalid} -> Invalid (I).
  //   SnpOnce -> unchanged (a snapshot snoop; no state change).
  // Forwarding snoops resolve the snoopee's own resulting state identically to
  // their non-fwd counterparts (the fwd is about WHERE the data goes, not the
  // snoopee's retained state):
  //   Snp{Shared,Clean,NotSharedDirty}Fwd -> retain SC; SnpUniqueFwd -> I;
  //   SnpOnceFwd -> unchanged (snapshot).
  // ---------------------------------------------------------------------------
  protected function vip_chi_resp_t snoop_next_state(
    input snp_opcode_t   snp_opcode,
    input vip_chi_resp_t current
  );
    case (snp_opcode)
      snp_opcode_t'(VIP_CHI_SNP_SHARED_C),
      snp_opcode_t'(VIP_CHI_SNP_CLEAN_C),
      snp_opcode_t'(VIP_CHI_SNP_CLEAN_SHARED_C),
      snp_opcode_t'(VIP_CHI_SNP_SHARED_FWD_C),
      snp_opcode_t'(VIP_CHI_SNP_CLEAN_FWD_C),
      snp_opcode_t'(VIP_CHI_SNP_NOT_SHARED_DIRTY_FWD_C): begin
        return (current == VIP_CHI_RESP_STATE_I_E) ? VIP_CHI_RESP_STATE_I_E
                                                   : VIP_CHI_RESP_STATE_SC_E;
      end
      snp_opcode_t'(VIP_CHI_SNP_UNIQUE_C),
      snp_opcode_t'(VIP_CHI_SNP_CLEAN_INVALID_C),
      snp_opcode_t'(VIP_CHI_SNP_MAKE_INVALID_C),
      snp_opcode_t'(VIP_CHI_SNP_UNIQUE_FWD_C): begin
        return VIP_CHI_RESP_STATE_I_E;
      end
      default: begin
        // SnpOnce / SnpOnceFwd and anything else: no state change.
        return current;
      end
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // Apply one snoop to the cache model and drive its SnpResp.
  // ---------------------------------------------------------------------------
  protected task process_snoop(input snp_flit_t snp);
    addr_t         line;
    vip_chi_resp_t cur;
    vip_chi_resp_t nxt;
    bit            was_dirty;
    data_t         fwd_data [];

    // Forwarding (DCT) snoops take the dedicated fwd-response path.
    if (this.snp_opcode_is_fwd(snp_opcode_t'(snp.opcode))) begin
      this.process_snoop_fwd(snp);
      return;
    end

    line      = this.line_addr(addr_t'(snp.addr));
    cur       = this.cache_state.exists(line) ? this.cache_state[line] : VIP_CHI_RESP_STATE_I_E;
    nxt       = this.snoop_next_state(snp_opcode_t'(snp.opcode), cur);
    was_dirty = this.state_is_dirty(cur);

    // Snapshot the beats to forward BEFORE mutating the model, so the response
    // carries the data held at snoop time.
    if (was_dirty && this.cache_data.exists(line)) begin
      fwd_data = this.cache_data[line];
    end

    // Update the held state. A snoop that lands the line Invalid drops both the
    // state and the data; otherwise keep the resulting state, and drop the data
    // copy if we just passed our dirty data to the home (we are now clean).
    if (nxt == VIP_CHI_RESP_STATE_I_E) begin
      if (this.cache_state.exists(line)) this.cache_state.delete(line);
      if (this.cache_data.exists(line))  this.cache_data.delete(line);
    end
    else begin
      this.cache_state[line] = nxt;
      // Drop the retained dirty copy only if this snoop moved us OUT of a dirty
      // (PassDirty) state -- i.e. we handed our dirty data to the home and are now
      // clean. SnpOnce is a snapshot that leaves the holder dirty, so it forwards
      // a copy of its data but keeps holding it.
      if (was_dirty && !this.state_is_dirty(nxt) && this.cache_data.exists(line)) begin
        this.cache_data.delete(line);
      end
    end

    // A dirty holder forwards its modified data to the home as SnpRespData
    // (PassDirty); a clean holder answers with a no-data SnpResp on RSP.
    if (was_dirty && (fwd_data.size() != 0)) begin
      this.drive_snp_resp_data(snp, nxt, fwd_data);
    end
    else begin
      this.drive_snp_resp(snp, nxt);
    end
  endtask

  // ---------------------------------------------------------------------------
  // Apply a forwarding (DCT) snoop and drive the forwarded response. Unlike the
  // non-fwd path, a fwd snoop ALWAYS carries data (the requester is reading and
  // needs the line), so even a clean holder forwards its current beats. The data
  // travels to the home as SnpRespDataFwded; the home relays it to the requester
  // (FwdNID/FwdTxnID) as CompData without sourcing from its own memory, and takes
  // the beats as authoritative. The snoopee's own resulting state follows
  // snoop_next_state (SC for a shared fwd, I for a unique fwd, unchanged for a
  // snapshot SnpOnceFwd). This is the home-relayed DCT model for a bench with no
  // point-to-point RN-F<->RN-F wire (see docs/plan); the data-less SnpRespFwded
  // RSP variant is unused here because the requester's data must traverse the home.
  // ---------------------------------------------------------------------------
  protected task process_snoop_fwd(input snp_flit_t snp);
    addr_t         line;
    vip_chi_resp_t cur;
    vip_chi_resp_t nxt;
    data_t         fwd_data [];

    line = this.line_addr(addr_t'(snp.addr));
    cur  = this.cache_state.exists(line) ? this.cache_state[line] : VIP_CHI_RESP_STATE_I_E;
    nxt  = this.snoop_next_state(snp_opcode_t'(snp.opcode), cur);

    // Snapshot the held beats (current value, clean or dirtied) BEFORE mutating.
    if (this.cache_data.exists(line)) begin
      fwd_data = this.cache_data[line];
    end

    // Update held state. A unique fwd invalidates (drop state + data); a shared
    // fwd retains SC; a snapshot SnpOnceFwd leaves both untouched.
    if (nxt == VIP_CHI_RESP_STATE_I_E) begin
      if (this.cache_state.exists(line)) this.cache_state.delete(line);
      if (this.cache_data.exists(line))  this.cache_data.delete(line);
    end
    else begin
      this.cache_state[line] = nxt;
    end

    // Forward the data via SnpRespDataFwded (DAT). If the holder had no data (a
    // fwd snoop should only target a valid holder), fall back to a no-data
    // SnpResp so the home is not left waiting -- defensive only.
    if (fwd_data.size() != 0) begin
      this.drive_snp_resp_data(snp, nxt, fwd_data, 1'b1 /*is_fwd*/);
    end
    else begin
      this.drive_snp_resp(snp, nxt);
    end
  endtask

  // ---------------------------------------------------------------------------
  // Drive one SnpResp on the RSP channel (clean, no data). The snoop's TxnID is
  // echoed so the home can match the response; the home matches on TxnID + port,
  // so exact SrcID is not required here.
  // ---------------------------------------------------------------------------
  protected task drive_snp_resp(input snp_flit_t snp, input vip_chi_resp_t resp_state);
    rsp_flit_t flit;

    flit = '0;
    flit.opcode  = rsp_opcode_t'(VIP_CHI_RSP_SNP_RESP_C);
    flit.resp    = resp_state;
    flit.resperr = VIP_CHI_RESP_ERR_NORMAL_OKAY_E;
    flit.txnid   = snp.txnid;
    flit.srcid   = node_id_t'(0);
    flit.tgtid   = node_id_t'(snp.srcid);
    flit.qos     = snp.qos;

    this.wait_rsp_credit();

    // Serialize against the request thread's own flit drivers: the snoop
    // responder runs concurrently with seq_loop, so both would otherwise drive
    // the RSP flit group in the same cycle. Taken after credit and held only
    // across the two beat edges (never a completion wait), so it can never
    // wedge against a writeback DAT burst on the request thread (M4).
    this.acquire_tx_flit();
    @(this.vif_rni.g_drv.rni_cb);
    this.drive_idle_sideband();
    this.vif_rni.g_drv.rni_cb.txrspflitpend <= 1'b0;
    this.vif_rni.g_drv.rni_cb.txrspflit     <= flit;
    this.vif_rni.g_drv.rni_cb.txrspflitv    <= 1'b1;

    @(this.vif_rni.g_drv.rni_cb);
    this.drive_idle_sideband();
    this.vif_rni.g_drv.rni_cb.txrspflitv    <= 1'b0;
    this.vif_rni.g_drv.rni_cb.txrspflit     <= '0;
    this.release_tx_flit();
  endtask

  // ---------------------------------------------------------------------------
  // Drive a dirty snoop response as SnpRespData on the DAT channel: one beat per
  // held line beat, carrying the modified data with PassDirty semantics (the
  // resulting snoopee state travels in resp; the home takes the dirty data as
  // authority). The snoop TxnID is echoed in dbid/txnid so the home can match.
  // Uses the DAT send-credit path and the M4a tx-flit mutex, so it is safe to
  // run concurrently with the request thread's own DAT drives.
  // ---------------------------------------------------------------------------
  protected task drive_snp_resp_data(
    input snp_flit_t     snp,
    input vip_chi_resp_t resp_state,
    input data_t         beats [],
    input bit            is_fwd = 1'b0
  );
    dat_flit_t flit;
    int        n_beats;

    n_beats = beats.size();

    // Hold the mutex across the whole burst (beat atomicity); the home returns
    // the DAT credit each beat waits on independently of anything this thread
    // drives, so the burst always drains and releases the key.
    this.acquire_tx_flit();
    foreach (beats[i]) begin
      flit         = '0;
      flit.data    = beats[i];
      flit.be      = '1;
      flit.dataid  = data_id_t'(i);
      flit.dbid    = snp.txnid;
      flit.resp    = resp_state;
      flit.resperr = VIP_CHI_RESP_ERR_NORMAL_OKAY_E;
      // A forwarding snoop responds with SnpRespDataFwded (the home relays the
      // beats to the requester); a plain dirty snoop uses SnpRespData (merge only).
      flit.opcode  = is_fwd ? item_t::dat_opcode_t'(VIP_CHI_DAT_SNP_RESP_DATA_FWDED_C)
                            : item_t::dat_opcode_t'(VIP_CHI_DAT_SNP_RESP_DATA_C);
      flit.txnid   = snp.txnid;
      flit.srcid   = node_id_t'(0);
      flit.tgtid   = node_id_t'(snp.srcid);
      flit.qos     = snp.qos;

      this.wait_dat_credit();

      @(this.vif_rni.g_drv.rni_cb);
      this.drive_idle_sideband();
      this.vif_rni.g_drv.rni_cb.txdatflitpend <= (i != (n_beats - 1));
      this.vif_rni.g_drv.rni_cb.txdatflit     <= flit;
      this.vif_rni.g_drv.rni_cb.txdatflitv    <= 1'b1;

      @(this.vif_rni.g_drv.rni_cb);
      this.drive_idle_sideband();
      this.vif_rni.g_drv.rni_cb.txdatflitpend <= 1'b0;
      this.vif_rni.g_drv.rni_cb.txdatflitv    <= 1'b0;
      this.vif_rni.g_drv.rni_cb.txdatflit     <= '0;
    end

    @(this.vif_rni.g_drv.rni_cb);
    this.drive_idle_sideband();
    this.release_tx_flit();
  endtask

  // ---------------------------------------------------------------------------
  // Record the granted coherent state as each request retires. A coherent read
  // completes with CompData carrying the granted state in rsp_resp.
  // ---------------------------------------------------------------------------
  protected function void on_transaction_complete(input item_t req);
    addr_t line;

    line = this.line_addr(addr_t'(req.addr));

    if ((req.direction == VIP_CHI_DIR_READ_E) &&
        this.req_opcode_is_coherent_read(req.opcode)) begin
      this.evict_for_capacity(line);
      this.cache_state[line] = req.rsp_resp;
      // Record the granted beats so a later snoop can forward them if the line
      // is dirtied (make_line_dirty) before the snoop arrives.
      this.cache_data[line] = new[req.data.size()];
      foreach (req.data[i]) begin
        this.cache_data[line][i] = req.data[i];
      end
    end
    else if (this.req_opcode_is_coherent_evicting_write(req.opcode) ||
             this.req_opcode_is_coherent_cmo(req.opcode) ||
             this.req_opcode_is_coherent_write_unique(req.opcode)) begin
      // WriteBackFull / Evict give the line up to the home; CleanInvalid /
      // MakeInvalid invalidate the requester's own copy; WriteUnique is
      // non-allocating. Either way the line leaves this cache (Invalid, no data).
      if (this.cache_state.exists(line)) this.cache_state.delete(line);
      if (this.cache_data.exists(line))  this.cache_data.delete(line);
    end
    else if (req.opcode == req_opcode_t'(VIP_CHI_REQ_CLEAN_UNIQUE_C)) begin
      // CleanUnique upgrades a line the RN already holds (clean) to Unique-Clean;
      // no data is transferred, so the held beats are preserved. For an exclusive
      // store (SC) the upgrade is conditional on the exclusive result: ExclOkay =>
      // the store won, take Unique; NormalOkay => it lost (an intervening conflict
      // cleared the home's monitor) so the line is left untouched and the RN must
      // retry. A non-exclusive CleanUnique always upgrades. Only a currently-held
      // line is touched -- a lost SC may have been snoop-invalidated out already.
      if (this.cache_state.exists(line)) begin
        if (!req.excl || (req.rsp_resp_err == VIP_CHI_RESP_ERR_EXCLUSIVE_OKAY_E)) begin
          this.cache_state[line] = VIP_CHI_RESP_STATE_UC_E;
        end
      end
    end
    else if (req.opcode == req_opcode_t'(VIP_CHI_REQ_MAKE_UNIQUE_C)) begin
      // MakeUnique acquires the line Unique-Dirty WITHOUT a data transfer. The RN
      // now owns the line and must be able to answer a later snoop: a downgrading
      // snoop of a PassDirty holder forwards SnpRespData, and a DCT snoop forwards
      // SnpRespDataFwded -- both need real beats. Leaving cache_data empty would
      // make process_snoop() forward a no-data SnpResp (the home then serves stale
      // memory) and make the DCT path wedge (the home waits for SnpRespDataFwded).
      // So materialize a defined image -- zeros, the freshly-"made" line the
      // requester will overwrite -- sized to the coherence line. [fix F2]
      this.evict_for_capacity(line);
      this.cache_state[line] = VIP_CHI_RESP_STATE_UP_PD_DIRTY_E;
      this.cache_data[line]  = new[VIP_CHI_CACHE_LINE_BYTES_C / CFG_P.DATA_BYTES_P];
      foreach (this.cache_data[line][i]) begin
        this.cache_data[line][i] = '0;
      end
    end
  endfunction

  // ---------------------------------------------------------------------------
  // TRUE for the coherent writes that evict the line to the home (leaving the
  // RN-F holding it Invalid on completion).
  // ---------------------------------------------------------------------------
  protected function bit req_opcode_is_coherent_evicting_write(input req_opcode_t opcode);
    return (opcode == req_opcode_t'(VIP_CHI_REQ_WRITE_BACK_FULL_C)) ||
           (opcode == req_opcode_t'(VIP_CHI_REQ_EVICT_C)) ||
           // WriteEvictOrEvict gives the line up either way: with the data when
           // the home asks for it, and as a plain Evict when it does not.
           (opcode == VIP_CHI_REQ_WRITE_EVICT_OR_EVICT_C);
  endfunction

  // ---------------------------------------------------------------------------
  // Test/scoreboard accessor: the held state for a line (I when never cached).
  // ---------------------------------------------------------------------------
  function vip_chi_resp_t get_cache_state(input addr_t addr);
    addr_t line;

    line = this.line_addr(addr);
    if (this.cache_state.exists(line)) begin
      return this.cache_state[line];
    end
    return VIP_CHI_RESP_STATE_I_E;
  endfunction

endclass

`endif
