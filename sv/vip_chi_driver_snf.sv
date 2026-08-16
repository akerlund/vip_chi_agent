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

`ifndef VIP_CHI_DRIVER_SNF
`define VIP_CHI_DRIVER_SNF

import uvm_pkg::*;
`include "uvm_macros.svh"
import vip_chi_types_pkg::*;
import vip_mem_types_pkg::*;
import vip_memory_pkg::*;

class vip_chi_driver_snf #(
  vip_chi_cfg_t  CFG_P        = VIP_CHI_DEFAULT_CFG_C,
  type           FLIT_TYPES_T = vip_chi_types #(CFG_P)
  ) extends uvm_driver #(vip_chi_item #(CFG_P));

  localparam int DATA_WIDTH_C = CFG_P.DATA_BYTES_P * 8;

  localparam vip_mem_cfg_t MEM_C = '{
    ADDR_WIDTH_P  : CFG_P.ADDR_WIDTH_P,
    WDATA_BYTES_P : CFG_P.DATA_BYTES_P,
    RDATA_BYTES_P : CFG_P.DATA_BYTES_P,
    ROW_BYTES_P   : CFG_P.DATA_BYTES_P
  };

  typedef vip_chi_item #(CFG_P)               item_t;
  typedef vip_chi_types #(CFG_P)::addr_t       addr_t;
  typedef vip_chi_types #(CFG_P)::be_t         be_t;
  typedef vip_chi_types #(CFG_P)::data_id_t    data_id_t;
  typedef vip_chi_types #(CFG_P)::cc_id_t      cc_id_t;
  typedef vip_chi_types #(CFG_P)::data_t       data_t;
  typedef vip_chi_types #(CFG_P)::node_id_t    node_id_t;
  typedef vip_chi_types #(CFG_P)::req_opcode_t req_opcode_t;
  typedef vip_chi_types #(CFG_P)::size_t       size_t;
  typedef vip_chi_types #(CFG_P)::txn_id_t    txn_id_t;
  typedef vip_chi_types #(CFG_P)::rsp_opcode_t rsp_opcode_t;
  typedef vip_chi_types #(CFG_P)::dat_opcode_t dat_opcode_t;
  typedef item_t::raw_rsp_t                    raw_rsp_t;
  typedef item_t::raw_dat_t                    raw_dat_t;
  typedef FLIT_TYPES_T::vip_chi_req_flit_t    req_flit_t;
  typedef FLIT_TYPES_T::vip_chi_dat_flit_t    dat_flit_t;
  typedef FLIT_TYPES_T::vip_chi_rsp_flit_t    rsp_flit_t;

  virtual vip_chi_if #(CFG_P, FLIT_TYPES_T, VIP_CHI_ROLE_SNF_E) vif_snf;
  vip_chi_cfg_agent                                            cfg;
  vip_mem #(MEM_C)                                             mem;
  protected bit                                                mem_row_written [longint];
  protected vip_chi_lcrd_mgr                                   rsp_lcrd_mgr;
  protected vip_chi_lcrd_mgr                                   dat_lcrd_mgr;
  protected int unsigned                                       req_lcrdv_pulses_pending;
  protected int unsigned                                       rsp_lcrdv_pulses_pending;
  protected int unsigned                                       dat_lcrdv_pulses_pending;

  // Credits advertised to the peer and not yet spent -- the half of quiescence a
  // sender cannot see from its own send pools. See link_drained().
  protected int unsigned                                       req_lcrd_granted;
  protected int unsigned                                       rsp_lcrd_granted;
  protected int unsigned                                       dat_lcrd_granted;

  // Set while the peer has withdrawn its activation request and this node is
  // handing its credits back. Suppresses NEW grants: a receiver may not issue
  // L-credits once the link is coming down, and a drain racing a credit loop
  // that keeps refilling the pool would never converge.
  protected bit                                                link_deactivating;

  // Countdowns for the two negative controls: one holds ACTIVATE by withholding
  // the acknowledge, the other holds DEACTIVATE past its drain by withholding
  // the drop. Both are counted in the credit loop, which is the one thread that
  // ticks every cycle regardless of what the link is doing.
  protected int unsigned                                       activate_stall_remaining;
  protected int unsigned                                       deactivate_stall_remaining;

  // Shadow of the acknowledge last driven. A clocking-block OUTPUT cannot be
  // sampled, so the two places that need to know whether this node is currently
  // acknowledging -- the bring-up wait and the deactivation tracker -- read this
  // instead of the wire. It is written in the same statement that drives the
  // signal, so the two cannot disagree.
  protected bit                                                ack_driven;
  // Buffered inbound REQ flits awaiting an auto-response, used only on the
  // multi-outstanding path so a request that arrives while the responder is
  // still driving an earlier burst is queued instead of silently dropped.
  protected req_flit_t                                         captured_reqs [$];
  // One-shot latch for cfg.snf_reorder_ordered_service (see req_response_loop):
  // the negative control inverts a single pair, so the ordered-stream check has
  // exactly one violation to report.
  protected bit                                                ordered_swap_done;
  // Count of RetryAck responses emitted so far. While this is below
  // cfg.force_retry_count, an inbound retryable REQ is bounced with a
  // RetryAck + PCrdGrant instead of being serviced (opt-in; default 0 = off).
  protected int unsigned                                       retries_issued;

  // TXSACTIVE outstanding-window state. See tx_activity_begin().
  protected int unsigned                                       tx_active_count;
  protected int unsigned                                       tx_active_extend;

  `uvm_component_param_utils(vip_chi_driver_snf #(CFG_P, FLIT_TYPES_T))

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent);
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  // Validate parent-assigned handles.
  // ---------------------------------------------------------------------------
  function void build_phase(input uvm_phase phase);
    super.build_phase(phase);

    if (!uvm_config_db #(virtual vip_chi_if #(CFG_P, FLIT_TYPES_T, VIP_CHI_ROLE_SNF_E))::get(this, "", "vif", this.vif_snf)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] driver.vif must be assigned by the parent agent",
        get_name()))
    end

    if (this.cfg == null) begin
      this.cfg = vip_chi_cfg_agent::type_id::create("default_cfg");
      this.cfg.role = VIP_CHI_ROLE_SNF_E;
    end

    this.mem = new("mem");
    this.mem.cfg = this.cfg.mem_cfg;
    this.mem.reset();
    this.mem.set_addr_width(CFG_P.ADDR_WIDTH_P);
    this.reset_credit_state();
  endfunction

  // ---------------------------------------------------------------------------
  // Keep the always-on link and credit sideband values coherent while the
  // driver is waiting or driving flits.
  // ---------------------------------------------------------------------------
  // The acknowledge follows the peer's request -- except while the link is
  // coming down, where following it immediately would be wrong.
  //
  // A receiver may only drop LINKACTIVEACK once every L-credit it advertised has
  // come back. Mirroring the request one cycle later would put the link in STOP
  // with credits still banked at both ends, which is precisely the state
  // VIP_CHI_CHK_LCRD_QUIESCENT_IN_STOP_E exists to report: the two ends would
  // disagree about what the peer may send after the next bring-up, and the first
  // flit across the reactivated link would go out unauthorised.
  //
  // So DEACTIVATE is held -- ack high, request low -- for exactly as long as the
  // drain takes. cfg.lasm_stall_deactivation_cycles then holds it longer still,
  // which is the negative control for the deactivation timeout.
  protected task drive_idle_sideband();
    if (this.vif_snf.g_drv.snf_cb.rxlinkactivereq) begin
      // cfg.lasm_stall_activation_cycles withholds the acknowledge, leaving the
      // LASM in ACTIVATE. A requester that has asked for the link is entitled to
      // an answer, so a completer that does not give one hangs the link with
      // nothing in flight to time out -- which is exactly what the activation
      // timeout exists to name.
      this.ack_driven = (this.activate_stall_remaining == 0);
    end
    else begin
      this.ack_driven = !this.link_drained();
    end
    this.vif_snf.g_drv.snf_cb.txlinkactiveack <= this.ack_driven;
  endtask

  // An inbound L-credit return is a link-layer flit, not a request. It consumes
  // the credit it hands back and nothing else, so the response loops must not
  // open a TXSACTIVE window for it, queue it, or try to answer it -- a completer
  // that treated one as a transaction would sit claiming an outstanding response
  // to a request that was never made, which is exactly what
  // VIP_CHI_CHK_LINK_DEACTIVATE_WHEN_IDLE_E then reports against it.
  //
  // Nor is the credit re-granted: the peer is handing it back, so advertising
  // it again would refill the pool the tear-down is emptying.
  protected function bit rx_req_is_lcrd_return();
    return (req_opcode_t'(this.vif_snf.g_drv.snf_cb.rxreqflit.opcode) ==
            req_opcode_t'(VIP_CHI_REQ_LCRD_RETURN_C));
  endfunction

  // Both halves of quiescence at this endpoint: nothing this node still holds,
  // and nothing it advertised that the peer still holds.
  protected function bit link_drained();
    if (this.deactivate_stall_remaining != 0) begin
      return 1'b0;
    end
    return (this.req_lcrd_granted == 0) && (this.rsp_lcrd_granted == 0) &&
           (this.dat_lcrd_granted == 0) &&
           (this.rsp_lcrd_mgr.available() == 0) && (this.dat_lcrd_mgr.available() == 0);
  endfunction

  // ---------------------------------------------------------------------------
  // TXSACTIVE outstanding-window drive.
  //
  // Deliberately the same shape as vip_chi_driver_rni's -- same method names,
  // same counter semantics -- rather than a shared base: the SN-F does not
  // inherit the RN-I, and the two roles are kept structurally parallel so a
  // reader can diff them.
  //
  // TXSACTIVE must span the whole window in which this node may have snoopable
  // transactions outstanding, not bracket each flit. For a completer that
  // window runs from taking a request off the wire to finishing its last
  // completion flit, so the count -- not any one response -- decides the level.
  // ---------------------------------------------------------------------------
  protected function void tx_activity_begin();
    this.tx_active_count++;
    this.tx_active_extend = 0;
    this.vif_snf.g_drv.snf_cb.txsactive <= 1'b1;
  endfunction

  protected function void tx_activity_end();
    if (this.tx_active_count > 0) begin
      this.tx_active_count--;
    end
    if (this.tx_active_count == 0) begin
      this.tx_active_extend = this.cfg.txsactive_extend_max_cycles;
    end
  endfunction

  // Called once per cycle from credit_loop, so the extension counts cycles
  // rather than callers.
  protected function void tx_activity_tick();
    if (this.tx_active_count > 0) begin
      return;
    end
    if (this.tx_active_extend > 0) begin
      this.tx_active_extend--;
      return;
    end
    this.vif_snf.g_drv.snf_cb.txsactive <= 1'b0;
  endfunction

  // ---------------------------------------------------------------------------
  // Reset the counted local send budgets and the queued outbound LCRDV pulses.
  // ---------------------------------------------------------------------------
  protected function void reset_credit_state();
    if (this.rsp_lcrd_mgr == null) begin
      this.rsp_lcrd_mgr = vip_chi_lcrd_mgr::type_id::create("rsp_lcrd_mgr");
    end

    if (this.dat_lcrd_mgr == null) begin
      this.dat_lcrd_mgr = vip_chi_lcrd_mgr::type_id::create("dat_lcrd_mgr");
    end

    this.rsp_lcrd_mgr.reset(this.cfg.rsp_send_credit_cap, 0);
    this.dat_lcrd_mgr.reset(this.cfg.dat_send_credit_cap, 0);
    this.req_lcrdv_pulses_pending = 0;
    this.rsp_lcrdv_pulses_pending = 0;
    this.dat_lcrdv_pulses_pending = 0;
    this.req_lcrd_granted = 0;
    this.rsp_lcrd_granted = 0;
    this.dat_lcrd_granted = 0;
    this.link_deactivating = 1'b0;
    this.activate_stall_remaining   = this.cfg.lasm_stall_activation_cycles;
    this.deactivate_stall_remaining = 0;
  endfunction

  // ---------------------------------------------------------------------------
  // SN-F consumes inbound REQ/RSP/DAT traffic, so it advertises all three
  // initial receive-credit budgets after link activation.
  // ---------------------------------------------------------------------------
  protected function void schedule_initial_credit_grants();
    this.req_lcrdv_pulses_pending += this.cfg.initial_req_credits;
    this.rsp_lcrdv_pulses_pending += this.cfg.initial_rsp_credits;
    this.dat_lcrdv_pulses_pending += this.cfg.initial_dat_credits;
  endfunction

  // ---------------------------------------------------------------------------
  // Map a byte address onto one vip_mem backing-store row.
  // ---------------------------------------------------------------------------
  protected function longint row_index_from_addr(input addr_t addr);
    return unsigned'(addr) / MEM_C.ROW_BYTES_P;
  endfunction

  // ---------------------------------------------------------------------------
  // Record that one row now has concrete backing-store data.
  // ---------------------------------------------------------------------------
  protected function void mark_backing_row(input addr_t addr);
    longint row_index;

    row_index = this.row_index_from_addr(addr);
    this.mem_row_written[row_index] = 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Return TRUE when the backing memory owns this row.
  // ---------------------------------------------------------------------------
  protected function bit has_backing_row(input addr_t addr);
    longint row_index;

    row_index = this.row_index_from_addr(addr);
    return this.mem_row_written.exists(row_index);
  endfunction

  // ---------------------------------------------------------------------------
  // Compare a CFG_P-width address against one configured [base:limit] range.
  // ---------------------------------------------------------------------------
  protected function bit addr_in_range(
    input addr_t         addr,
    input logic [51 : 0] base,
    input logic [51 : 0] limit
  );
    logic [51 : 0] addr_52;

    addr_52 = '0;
    addr_52[CFG_P.ADDR_WIDTH_P-1 : 0] = addr;
    return ((addr_52 >= base) && (addr_52 <= limit));
  endfunction

  // ---------------------------------------------------------------------------
  // Return TRUE when the address is configured to reject the request.
  // ---------------------------------------------------------------------------
  protected function bit decerr_check(input addr_t addr);
    foreach (this.cfg.decerr_ranges[i]) begin
      if (this.addr_in_range(addr, this.cfg.decerr_ranges[i].base, this.cfg.decerr_ranges[i].limit)) begin
        return 1'b1;
      end
    end
    return 1'b0;
  endfunction

  // ---------------------------------------------------------------------------
  // Return TRUE when the address is configured to return corrupt data.
  // decerr_ranges always take precedence over derr_ranges.
  // ---------------------------------------------------------------------------
  protected function bit derr_check(input addr_t addr);
    if (this.decerr_check(addr)) begin
      return 1'b0;
    end

    foreach (this.cfg.derr_ranges[i]) begin
      if (this.addr_in_range(addr, this.cfg.derr_ranges[i].base, this.cfg.derr_ranges[i].limit)) begin
        return 1'b1;
      end
    end
    return 1'b0;
  endfunction

  // ---------------------------------------------------------------------------
  // Beat position carried by the send_index'th DAT beat of a read burst. CHI
  // places a beat by its DataID rather than by its position in the burst, so the
  // completer is free to send the positions in any order as long as each beat
  // carries the payload belonging to the DataID it announces.
  //
  //   default                  : ascending, 0 .. beat_count-1
  //   cfg.snf_reverse_dat_beats: descending, beat_count-1 .. 0
  //   cfg.snf_duplicate_dat_beat: the last send repeats position 0, so one
  //     position is delivered twice and the last position never at all -- the
  //     negative control for the monitor's duplicate/missing DataID checks
  //
  // A single-beat transfer has nothing to reorder, so both knobs are inert.
  // ---------------------------------------------------------------------------
  protected function int dat_beat_position(input int send_index, input int beat_count);
    if (beat_count <= 1) begin
      return send_index;
    end

    if (this.cfg.snf_duplicate_dat_beat && (send_index == (beat_count - 1))) begin
      return 0;
    end

    if (this.cfg.snf_reverse_dat_beats) begin
      return (beat_count - 1 - send_index);
    end

    return send_index;
  endfunction

  // ---------------------------------------------------------------------------
  // Serve read data from vip_mem when a row has been written; otherwise fall
  // back to the current deterministic pattern so untouched-address smokes stay
  // stable.
  // ---------------------------------------------------------------------------
  protected function data_t read_data_beat(input addr_t addr, input int beat_index);
    addr_t                         beat_addr;
    logic [MEM_C.ROW_BYTES_P*8-1:0] mem_row;

    beat_addr = addr + addr_t'(beat_index * CFG_P.DATA_BYTES_P);
    if (this.has_backing_row(beat_addr)) begin
      mem_row = this.mem.rd_addr(beat_addr);
      return data_t'(mem_row);
    end

    return this.auto_read_data(addr, beat_index);
  endfunction

  // ---------------------------------------------------------------------------
  // Reset all SN-F driven outputs to the idle state.
  // ---------------------------------------------------------------------------
  protected function void reset_outputs();
    this.vif_snf.g_drv.snf_cb.txlinkactivereq <= 1'b0;
    this.vif_snf.g_drv.snf_cb.txlinkactiveack <= 1'b0;
    this.ack_driven                            = 1'b0;
    this.vif_snf.g_drv.snf_cb.txsactive       <= 1'b0;

    this.vif_snf.g_drv.snf_cb.txreqlcrdv      <= 1'b0;

    this.vif_snf.g_drv.snf_cb.txrspflitpend   <= 1'b0;
    this.vif_snf.g_drv.snf_cb.txrspflitv      <= 1'b0;
    this.vif_snf.g_drv.snf_cb.txrspflit       <= '0;
    this.vif_snf.g_drv.snf_cb.txrsplcrdv      <= 1'b0;

    this.vif_snf.g_drv.snf_cb.txdatflitpend   <= 1'b0;
    this.vif_snf.g_drv.snf_cb.txdatflitv      <= 1'b0;
    this.vif_snf.g_drv.snf_cb.txdatflit       <= '0;
    this.vif_snf.g_drv.snf_cb.txdatlcrdv      <= 1'b0;

    if (this.mem != null) begin
      this.mem.reset();
    end
    this.mem_row_written.delete();
    this.handle_issue_specific_reset();
  endfunction

  // ---------------------------------------------------------------------------
  // Wait for RN-I link activation, then advertise the SN-F receive budgets as
  // initial LCRDV pulses.
  // ---------------------------------------------------------------------------
  protected task activate_link();
    do begin
      @(this.vif_snf.g_drv.snf_cb);
      this.drive_idle_sideband();
    end while (this.vif_snf.rst_n && !this.vif_snf.g_drv.snf_cb.rxlinkactivereq);

    // The acknowledge may be withheld here by cfg.lasm_stall_activation_cycles;
    // see drive_idle_sideband, which is where the suppression lives because the
    // credit loop drives the same signal every cycle and would otherwise raise
    // it straight back.
    while (!this.ack_driven) begin
      @(this.vif_snf.g_drv.snf_cb);
      this.drive_idle_sideband();
    end

    this.schedule_initial_credit_grants();
  endtask

  // ---------------------------------------------------------------------------
  // Public reset hook. The parent agent drives the reset sequencing and calls
  // this before rst_n is released.
  // ---------------------------------------------------------------------------
  function void reset_vif();
    this.reset_outputs();
  endfunction

  // ---------------------------------------------------------------------------
  // Clear the SN-F local bookkeeping that does not live on the interface.
  // ---------------------------------------------------------------------------
  function void handle_reset();
    this.retries_issued = 0;
    this.ordered_swap_done = 1'b0;
    this.tx_active_count = 0;
    this.tx_active_extend = 0;
    this.reset_credit_state();
    this.reset_outputs();
  endfunction

  // ---------------------------------------------------------------------------
  // Main SN-F response-driving loop after the parent agent releases reset.
  // ---------------------------------------------------------------------------
  task driver_start();

    fork
      this.credit_loop();
      this.deactivate_drain();
      begin
        this.activate_link();
        if (this.cfg.multi_outstanding) begin
          this.seq_loop_buffered();
        end
        else begin
          this.seq_loop();
        end
      end
    join
  endtask

  // ---------------------------------------------------------------------------
  // Track inbound L-credit pulses and emit one-cycle LCRDV pulses for both the
  // initial receive-credit grant and later return-after-consume events.
  // ---------------------------------------------------------------------------
  protected task credit_loop();
    forever begin
      @(this.vif_snf.g_drv.snf_cb);

      this.track_deactivation();
      this.drive_idle_sideband();
      this.tx_activity_tick();
      this.vif_snf.g_drv.snf_cb.txreqlcrdv <=
        (this.req_lcrdv_pulses_pending != 0) && !this.link_deactivating;
      this.vif_snf.g_drv.snf_cb.txrsplcrdv <=
        (this.rsp_lcrdv_pulses_pending != 0) && !this.link_deactivating;
      this.vif_snf.g_drv.snf_cb.txdatlcrdv <=
        (this.dat_lcrdv_pulses_pending != 0) && !this.link_deactivating;

      if ((this.req_lcrdv_pulses_pending != 0) && !this.link_deactivating) begin
        this.req_lcrdv_pulses_pending--;
        this.req_lcrd_granted++;
      end

      if ((this.rsp_lcrdv_pulses_pending != 0) && !this.link_deactivating) begin
        this.rsp_lcrdv_pulses_pending--;
        this.rsp_lcrd_granted++;
      end

      if ((this.dat_lcrdv_pulses_pending != 0) && !this.link_deactivating) begin
        this.dat_lcrdv_pulses_pending--;
        this.dat_lcrd_granted++;
      end

      // Every inbound flit spends one of the credits advertised above, INCLUDING
      // an L-credit return: the return is itself a flit and consumes the credit
      // it hands back. That is what lets the drain converge with no separate
      // accounting for the two kinds.
      if (this.vif_snf.g_drv.snf_cb.rxreqflitv && (this.req_lcrd_granted != 0)) begin
        this.req_lcrd_granted--;
      end

      if (this.vif_snf.g_drv.snf_cb.rxrspflitv && (this.rsp_lcrd_granted != 0)) begin
        this.rsp_lcrd_granted--;
      end

      if (this.vif_snf.g_drv.snf_cb.rxdatflitv && (this.dat_lcrd_granted != 0)) begin
        this.dat_lcrd_granted--;
      end

      if (this.vif_snf.g_drv.snf_cb.rxrsplcrdv) begin
        this.rsp_lcrd_mgr.return_credit();
      end

      if (this.vif_snf.g_drv.snf_cb.rxdatlcrdv) begin
        this.dat_lcrd_mgr.return_credit();
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  // Hand back every send-side L-credit this node holds, once the peer has
  // withdrawn its activation request.
  //
  // A separate thread rather than a step in the credit loop, because a credit
  // return is a FLIT and the SN-F drives flits from exactly one place. The
  // guards below are what keep it that way:
  //
  //   * the link must be in DEACTIVATE, which the requester only enters after
  //     every one of its transactions has retired, so the response loop has
  //     nothing left to send; and
  //   * tx_active_count must be zero, which closes the one-cycle tail where the
  //     requester has seen its last completion but this node is still driving
  //     its final flit.
  //
  // Together those mean the two threads are never in a position to drive the TX
  // signals in the same cycle, which is what the RN-I's flit mutex buys there
  // and what this buys here without touching the existing response paths.
  // ---------------------------------------------------------------------------
  protected task deactivate_drain();

    forever begin

      while (!(this.link_deactivating && (this.tx_active_count == 0) &&
               ((this.rsp_lcrd_mgr.available() != 0) ||
                (this.dat_lcrd_mgr.available() != 0)))) begin
        @(this.vif_snf.g_drv.snf_cb);
        this.drive_idle_sideband();
      end

      while (this.rsp_lcrd_mgr.try_acquire_credit()) begin
        this.drive_rsp_lcrd_return();
      end

      while (this.dat_lcrd_mgr.try_acquire_credit()) begin
        this.drive_dat_lcrd_return();
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  // One L-credit return flit per channel. All fields zero: the opcode is the
  // whole message, and a return names no address, no TxnID and no data.
  // ---------------------------------------------------------------------------
  protected task drive_rsp_lcrd_return();

    rsp_flit_t flit;

    flit        = '0;
    flit.opcode = rsp_opcode_t'(VIP_CHI_RSP_LCRD_RETURN_C);

    @(this.vif_snf.g_drv.snf_cb);
    this.drive_idle_sideband();
    this.vif_snf.g_drv.snf_cb.txrspflitpend <= 1'b0;
    this.vif_snf.g_drv.snf_cb.txrspflit     <= flit;
    this.vif_snf.g_drv.snf_cb.txrspflitv    <= 1'b1;

    @(this.vif_snf.g_drv.snf_cb);
    this.drive_idle_sideband();
    this.vif_snf.g_drv.snf_cb.txrspflitv <= 1'b0;
    this.vif_snf.g_drv.snf_cb.txrspflit  <= '0;
  endtask

  protected task drive_dat_lcrd_return();

    dat_flit_t flit;

    flit        = '0;
    flit.opcode = dat_opcode_t'(VIP_CHI_DAT_LCRD_RETURN_C);

    @(this.vif_snf.g_drv.snf_cb);
    this.drive_idle_sideband();
    this.vif_snf.g_drv.snf_cb.txdatflitpend <= 1'b0;
    this.vif_snf.g_drv.snf_cb.txdatflit     <= flit;
    this.vif_snf.g_drv.snf_cb.txdatflitv    <= 1'b1;

    @(this.vif_snf.g_drv.snf_cb);
    this.drive_idle_sideband();
    this.vif_snf.g_drv.snf_cb.txdatflitv <= 1'b0;
    this.vif_snf.g_drv.snf_cb.txdatflit  <= '0;
  endtask

  // ---------------------------------------------------------------------------
  // Follow the peer's activation request into and back out of deactivation.
  //
  // The completer has no deactivation request of its own to make -- it reacts.
  // Everything it must do is a consequence of the request going away: stop
  // granting, hand back what it holds, and only then let the acknowledge fall.
  // ---------------------------------------------------------------------------
  protected task track_deactivation();

    if (!this.vif_snf.g_drv.snf_cb.rxlinkactivereq && this.ack_driven) begin

      // Entering DEACTIVATE: latch the negative-control stall, if any, and stand
      // the grants down.
      if (!this.link_deactivating) begin
        this.link_deactivating          = 1'b1;
        this.deactivate_stall_remaining = this.cfg.lasm_stall_deactivation_cycles;
        // Queued-but-unsent grants are dropped rather than carried across the
        // gap: they were promises about a link that no longer exists, and
        // re-activation advertises a fresh budget.
        this.req_lcrdv_pulses_pending = 0;
        this.rsp_lcrdv_pulses_pending = 0;
        this.dat_lcrdv_pulses_pending = 0;
      end

      if (this.deactivate_stall_remaining != 0) begin
        this.deactivate_stall_remaining--;
      end
    end
    else if (this.vif_snf.g_drv.snf_cb.rxlinkactivereq) begin
      // Back up. A fresh budget is advertised by activate_link on the requester's
      // next bring-up handshake.
      if (this.link_deactivating) begin
        this.link_deactivating          = 1'b0;
        this.deactivate_stall_remaining = 0;
        this.schedule_initial_credit_grants();
      end

      // The activation stall re-arms on each fresh request and counts down while
      // the request is up, so it delays every bring-up rather than only the
      // first -- a test that deactivates and reactivates stalls both times,
      // which is what makes it usable as a control on either.
      if (this.activate_stall_remaining != 0) begin
        this.activate_stall_remaining--;
      end
    end
    else begin
      // Request low and acknowledge already low: the link is at rest in STOP.
      // Re-arm the stall for the next bring-up.
      this.activate_stall_remaining = this.cfg.lasm_stall_activation_cycles;
    end
  endtask

  // ---------------------------------------------------------------------------
  // Wait until one outbound credit is available for the selected channel.
  // ---------------------------------------------------------------------------
  protected task wait_for_credit(input vip_chi_lcrd_mgr lcrd_mgr);
    forever begin
      if (lcrd_mgr.try_acquire_credit()) begin
        break;
      end

      @(this.vif_snf.g_drv.snf_cb);
      this.drive_idle_sideband();
    end
  endtask

  // ---------------------------------------------------------------------------
  // Queue one returned credit on the inbound REQ channel.
  // ---------------------------------------------------------------------------
  protected function void schedule_req_credit_return();
    this.req_lcrdv_pulses_pending++;
  endfunction

  // ---------------------------------------------------------------------------
  // Queue one returned credit on the inbound RSP channel.
  // ---------------------------------------------------------------------------
  protected function void schedule_rsp_credit_return();
    this.rsp_lcrdv_pulses_pending++;
  endfunction

  // ---------------------------------------------------------------------------
  // Queue one returned credit on the inbound DAT channel.
  // ---------------------------------------------------------------------------
  protected function void schedule_dat_credit_return();
    this.dat_lcrdv_pulses_pending++;
  endfunction

  // ---------------------------------------------------------------------------
  // Main SN-F response-driving loop after link activation.
  // ---------------------------------------------------------------------------
  protected task seq_loop();
    item_t rsp;

    forever begin
      @(this.vif_snf.g_drv.snf_cb);

      this.drive_idle_sideband();

      if (this.vif_snf.g_drv.snf_cb.rxreqflitv && this.rx_req_is_lcrd_return()) begin
        // Reclaimed, not re-granted: the peer is HANDING THIS CREDIT BACK, and
        // a receiver that answered by advertising it again would refill the pool
        // the tear-down is trying to empty and the drain would never converge.
        // The credit-loop accounting (req_lcrd_granted) already retires it.
      end
      else if (this.vif_snf.g_drv.snf_cb.rxreqflitv) begin
        this.schedule_req_credit_return();
        // The window opens when the request comes off the wire -- from here
        // until the last completion flit this node owes a response, which is
        // exactly what TXSACTIVE reports. Closed on every exit path below.
        this.tx_activity_begin();

        if (this.should_auto_retry(this.vif_snf.g_drv.snf_cb.rxreqflit)) begin
          this.retries_issued++;
          this.drive_auto_retry(this.vif_snf.g_drv.snf_cb.rxreqflit);
          this.tx_activity_end();
          continue;
        end

        if (this.req_opcode_is_auto_read(req_opcode_t'(this.vif_snf.g_drv.snf_cb.rxreqflit.opcode))) begin
          this.drive_auto_read_compdata(this.vif_snf.g_drv.snf_cb.rxreqflit);
        end
        else if (req_opcode_t'(this.vif_snf.g_drv.snf_cb.rxreqflit.opcode) == req_opcode_t'(VIP_CHI_REQ_PREFETCH_TGT_C)) begin
          // A hint with no completion: the window opens and closes with nothing
          // in between, which is the honest report -- nothing was ever owed.
          this.tx_activity_end();
          continue;
        end
        else if (this.req_opcode_is_auto_persist(req_opcode_t'(this.vif_snf.g_drv.snf_cb.rxreqflit.opcode))) begin
          this.drive_auto_persist_rsp(this.vif_snf.g_drv.snf_cb.rxreqflit);
        end
        else if (this.req_opcode_is_auto_atomic(req_opcode_t'(this.vif_snf.g_drv.snf_cb.rxreqflit.opcode))) begin
          this.drive_auto_atomic_completion(this.vif_snf.g_drv.snf_cb.rxreqflit);
        end
        else if (this.req_opcode_is_auto_write_zero(req_opcode_t'(this.vif_snf.g_drv.snf_cb.rxreqflit.opcode))) begin
          this.drive_auto_write_zero_comp(this.vif_snf.g_drv.snf_cb.rxreqflit);
        end
        else if (this.req_opcode_is_auto_write(req_opcode_t'(this.vif_snf.g_drv.snf_cb.rxreqflit.opcode))) begin
          this.drive_auto_write_comp(this.vif_snf.g_drv.snf_cb.rxreqflit);
        end
        this.tx_activity_end();
        continue;
      end

      rsp = null;
      seq_item_port.try_next_item(rsp);

      if (rsp == null) begin
        continue;
      end

      // A manually injected completion is outbound activity that no captured
      // request accounts for, so it opens a window of its own.
      if (rsp.raw_override) begin
        this.tx_activity_begin();
        this.drive_raw_item(rsp);
        this.tx_activity_end();
        seq_item_port.item_done();
        continue;
      end

      this.tx_activity_begin();
      if (rsp.data.size() > 0) begin
        this.drive_dat(rsp);
      end
      else begin
        this.drive_rsp(rsp);
      end
      this.tx_activity_end();
      seq_item_port.item_done();
    end
  endtask

  // ---------------------------------------------------------------------------
  // Buffered response loop (opt-in via cfg.multi_outstanding): one thread
  // captures every inbound REQ into a queue (returning its REQ credit at once),
  // a second drains the queue and drives each auto-response. Decoupling capture
  // from response means a request that arrives while an earlier burst is still
  // being driven is buffered rather than dropped, which is what lets the RN-I
  // keep several reads outstanding. Auto-responder only; manual SN-F response
  // sequences continue to use the serial seq_loop.
  // ---------------------------------------------------------------------------
  protected task seq_loop_buffered();
    fork
      this.req_capture_loop();
      this.req_response_loop();
    join
  endtask

  // ---------------------------------------------------------------------------
  // Capture thread: sample the REQ channel every cycle, return the REQ credit
  // immediately, and queue the flit for the response thread.
  // ---------------------------------------------------------------------------
  protected task req_capture_loop();
    forever begin
      @(this.vif_snf.g_drv.snf_cb);
      this.drive_idle_sideband();

      if (this.vif_snf.g_drv.snf_cb.rxreqflitv && this.rx_req_is_lcrd_return()) begin
        // Reclaimed, not re-granted: the peer is HANDING THIS CREDIT BACK, and
        // a receiver that answered by advertising it again would refill the pool
        // the tear-down is trying to empty and the drain would never converge.
        // The credit-loop accounting (req_lcrd_granted) already retires it.
      end
      else if (this.vif_snf.g_drv.snf_cb.rxreqflitv) begin
        this.schedule_req_credit_return();
        this.captured_reqs.push_back(this.vif_snf.g_drv.snf_cb.rxreqflit);
        // Opened at capture, not at dispatch: a buffered request is already
        // outstanding while it waits its turn in the queue, and the sideband
        // has to say so.
        this.tx_activity_begin();
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  // Response thread: drive the auto-response for each buffered REQ in order.
  // ---------------------------------------------------------------------------
  protected task req_response_loop();
    req_flit_t req;

    forever begin
      if (this.captured_reqs.size() != 0) begin
        // Negative control (cfg.snf_reorder_ordered_service): serve the second of
        // two queued ordered requests first. Every transaction still completes
        // correctly on its own -- only the order the completer acknowledges them
        // in is wrong, which is exactly the fault the ordered-stream check exists
        // to catch and the only fault it should catch. It fires ONCE, so the
        // check has exactly one inversion to report and the count a negative
        // control asserts on is unambiguous.
        if (this.cfg.snf_reorder_ordered_service && !this.ordered_swap_done &&
            (this.captured_reqs.size() >= 2) &&
            this.req_has_ordering(this.captured_reqs[0]) &&
            this.req_has_ordering(this.captured_reqs[1])) begin
          this.ordered_swap_done = 1'b1;
          req = this.captured_reqs[1];
          this.captured_reqs.delete(1);
        end
        else begin
          req = this.captured_reqs.pop_front();
        end
        this.dispatch_auto_response(req);
        this.tx_activity_end();
      end
      else begin
        @(this.vif_snf.g_drv.snf_cb);
        this.drive_idle_sideband();
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  // Drive the SN-F auto-response for one captured REQ. Mirrors the opcode
  // dispatch in seq_loop but takes the REQ by value (already off the wire) and
  // does not return credit (the capture thread already did).
  // ---------------------------------------------------------------------------
  protected task dispatch_auto_response(input req_flit_t req);
    // Same opt-in retry as the serial loop: while under force_retry_count, bounce
    // a retryable REQ with RetryAck + PCrdGrant instead of servicing it, so the
    // pipeline exercises the retry path too (no-op when force_retry_count = 0).
    if (this.should_auto_retry(req)) begin
      this.retries_issued++;
      this.drive_auto_retry(req);
      return;
    end
    if (this.req_opcode_is_auto_read(req_opcode_t'(req.opcode))) begin
      this.drive_auto_read_compdata(req);
    end
    else if (req_opcode_t'(req.opcode) == req_opcode_t'(VIP_CHI_REQ_PREFETCH_TGT_C)) begin
      // PrefetchTgt is a hint with no completion.
    end
    else if (this.req_opcode_is_auto_persist(req_opcode_t'(req.opcode))) begin
      this.drive_auto_persist_rsp(req);
    end
    else if (this.req_opcode_is_auto_atomic(req_opcode_t'(req.opcode))) begin
      this.drive_auto_atomic_completion(req);
    end
    else if (this.req_opcode_is_auto_write_zero(req_opcode_t'(req.opcode))) begin
      this.drive_auto_write_zero_comp(req);
    end
    else if (this.req_opcode_is_auto_write(req_opcode_t'(req.opcode))) begin
      this.drive_auto_write_comp(req);
    end
  endtask

  // ---------------------------------------------------------------------------
  // run_phase is intentionally empty: the parent agent owns the single rst_n
  // watcher and forks driver_start() only while the link is out of reset.
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);
  endtask

  // ---------------------------------------------------------------------------
  // Identify the first auto-responder read opcodes supported by the SN-F cut.
  // ---------------------------------------------------------------------------
  protected function bit req_opcode_is_auto_read(input req_opcode_t opcode);
    case (opcode)
      req_opcode_t'(VIP_CHI_REQ_READ_NO_SNP_C),
      req_opcode_t'(VIP_CHI_REQ_READ_NO_SNP_SEP_C): begin
        return 1'b1;
      end
      default: begin
        return 1'b0;
      end
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // Identify the first auto-responder write opcodes supported by the SN-F cut.
  // ---------------------------------------------------------------------------
  protected function bit req_opcode_is_auto_write(input req_opcode_t opcode);
    case (opcode)
      req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_FULL_C),
      req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_PTL_C): begin
        return 1'b1;
      end
      default: begin
        // The combined Write+CMO forms take the same write path: the write half
        // is an ordinary WriteNoSnp Full/Ptl, and Full vs Ptl needs no branch
        // here because the write commits through the byte enables either way.
        // What the combined form adds is the CMO half of the completion, driven
        // after the data commits -- see drive_combined_cmo_rsp.
        return this.req_opcode_is_combined_write_cmo(opcode);
      end
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // Identify a combined Write + CMO request (Issue E).
  // ---------------------------------------------------------------------------
  protected function bit req_opcode_is_combined_write_cmo(input req_opcode_t opcode);
    case (opcode)
      req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_FULL_CLEAN_SH_C),
      req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_FULL_CLEAN_INV_C),
      req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_FULL_CLEAN_SH_PER_SEP_C),
      req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_PTL_CLEAN_SH_C),
      req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_PTL_CLEAN_INV_C),
      req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_PTL_CLEAN_SH_PER_SEP_C): begin
        return 1'b1;
      end
      default: begin
        return 1'b0;
      end
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // TRUE when the combined form's CMO half is a PERSISTENT CMO, which is the one
  // that adds an observable response rather than only a CompCMO. A memory node
  // has no cache, so CleanSh and CleanInv complete with no state change; the
  // persist leg is the half a test can actually watch land in the wrong order.
  // ---------------------------------------------------------------------------
  protected function bit req_opcode_combined_cmo_is_persist(input req_opcode_t opcode);
    case (opcode)
      req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_FULL_CLEAN_SH_PER_SEP_C),
      req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_PTL_CLEAN_SH_PER_SEP_C): begin
        return 1'b1;
      end
      default: begin
        return 1'b0;
      end
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // Identify the data-less zero-write opcode handled by the SN-F cut.
  // WriteNoSnpZero carries no write data, so it completes with a single Comp
  // and never opens a DBID / write-data phase.
  // ---------------------------------------------------------------------------
  protected function bit req_opcode_is_auto_write_zero(input req_opcode_t opcode);
    return (opcode == req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_ZERO_C));
  endfunction

  // ---------------------------------------------------------------------------
  // Identify the persist request opcodes supported by the SN-F cut.
  // ---------------------------------------------------------------------------
  protected function bit req_opcode_is_auto_persist(input req_opcode_t opcode);
    case (opcode)
      req_opcode_t'(VIP_CHI_REQ_CLEAN_SHARED_PERSIST_C),
      req_opcode_t'(VIP_CHI_REQ_CLEAN_SHARED_PERSIST_SEP_C): begin
        return 1'b1;
      end
      default: begin
        return 1'b0;
      end
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // Identify the atomic request opcodes supported by the SN-F cut.
  // ---------------------------------------------------------------------------
  protected function bit req_opcode_is_auto_atomic(input req_opcode_t opcode);
    return vip_chi_types_pkg::vip_chi_req_opcode_is_atomic(vip_chi_req_opcode_t'(opcode));
  endfunction

  // ---------------------------------------------------------------------------
  // Return the arithmetic variant [0:7] encoded by AtomicStore/Load opcodes.
  // ---------------------------------------------------------------------------
  protected function int req_opcode_atomic_variant(input req_opcode_t opcode);
    return vip_chi_types_pkg::vip_chi_req_opcode_atomic_variant(vip_chi_req_opcode_t'(opcode));
  endfunction

  // ---------------------------------------------------------------------------
  // Apply the CHI AtomicStore/Load[0:7] arithmetic variant to one beat.
  // ---------------------------------------------------------------------------
  protected function data_t apply_atomic_variant(
    input int    variant,
    input data_t current_value,
    input data_t operand_value
  );
    logic signed [DATA_WIDTH_C - 1 : 0] current_signed;
    logic signed [DATA_WIDTH_C - 1 : 0] operand_signed;

    current_signed = current_value;
    operand_signed = operand_value;

    case (variant)
      0: begin
        return data_t'(current_value + operand_value);
      end
      1: begin
        return data_t'(current_value & ~operand_value);
      end
      2: begin
        return data_t'(current_value ^ operand_value);
      end
      3: begin
        return data_t'(current_value | operand_value);
      end
      4: begin
        return (current_signed > operand_signed) ? current_value : operand_value;
      end
      5: begin
        return (current_signed < operand_signed) ? current_value : operand_value;
      end
      6: begin
        return (current_value > operand_value) ? current_value : operand_value;
      end
      7: begin
        return (current_value < operand_value) ? current_value : operand_value;
      end
      default: begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] Unsupported atomic variant %0d",
          get_name(), variant))
        return current_value;
      end
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // Return TRUE when the request carries an ordering requirement.
  // ---------------------------------------------------------------------------
  protected function bit req_has_ordering(input req_flit_t req);
    return (vip_chi_req_order_t'(req.order) != VIP_CHI_ORDER_NONE_E);
  endfunction

  // ---------------------------------------------------------------------------
  // Build a deterministic first-cut read-response payload from the request.
  // ---------------------------------------------------------------------------
  protected function data_t auto_read_data(input addr_t addr, input int beat_index);
    return data_t'(addr) + data_t'(beat_index);
  endfunction

  // ---------------------------------------------------------------------------
  // Wait for one ordered-write CompAck from the RN-I.
  // ---------------------------------------------------------------------------
  protected task wait_for_comp_ack(
    input txn_id_t  req_txn_id,
    input node_id_t req_src_id,
    input node_id_t req_tgt_id
  );
    rsp_flit_t flit;
    int        cycles_waited;

    cycles_waited = 0;
    forever begin
      while (!this.vif_snf.g_drv.snf_cb.rxrspflitv) begin
        @(this.vif_snf.g_drv.snf_cb);
        this.drive_idle_sideband();
        cycles_waited++;

        if ((this.cfg.compack_timeout_cycles > 0) &&
            (cycles_waited >= this.cfg.compack_timeout_cycles)) begin
          `uvm_fatal(get_name(), $sformatf(
            "FATAL [%s] Timed out waiting %0d cycles for CompAck on txn_id 0x%0h",
            get_name(), this.cfg.compack_timeout_cycles, req_txn_id))
        end
      end

      flit = this.vif_snf.g_drv.snf_cb.rxrspflit;
      if (rsp_opcode_t'(flit.opcode) != rsp_opcode_t'(VIP_CHI_RSP_COMP_ACK_C)) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] Ordered write received opcode 0x%0h instead of CompAck",
          get_name(), flit.opcode))
      end

      if (txn_id_t'(flit.txnid) != req_txn_id) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] CompAck txn_id 0x%0h does not match request txn_id 0x%0h",
          get_name(), flit.txnid, req_txn_id))
      end

      if ((node_id_t'(flit.srcid) != req_src_id) ||
          (node_id_t'(flit.tgtid) != req_tgt_id)) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] CompAck src/tgt 0x%0h->0x%0h did not match expected 0x%0h->0x%0h",
          get_name(), flit.srcid, flit.tgtid, req_src_id, req_tgt_id))
      end

      this.schedule_rsp_credit_return();

      break;
    end
  endtask

  // ---------------------------------------------------------------------------
  // Drive one RSP flit.
  // ---------------------------------------------------------------------------
  protected task drive_rsp(input item_t rsp);
    rsp_flit_t flit;

    flit = '0;
    flit.dbid     = rsp.dbid;
    flit.fwdstate = rsp.fwd_state;
    flit.resp     = vip_chi_resp_t'(rsp.rsp_resp);
    flit.resperr  = vip_chi_resp_err_t'(rsp.rsp_resp_err);
    flit.opcode   = rsp_opcode_t'(rsp.rsp_opcode);
    flit.txnid    = rsp.txn_id;
    flit.srcid    = rsp.src_id;
    flit.tgtid    = rsp.tgt_id;
    flit.pcrdtype = rsp.pcrd_type;
    flit.qos      = rsp.qos;

    this.wait_for_credit(this.rsp_lcrd_mgr);

    @(this.vif_snf.g_drv.snf_cb);
    this.drive_idle_sideband();
    this.vif_snf.g_drv.snf_cb.txrspflitpend   <= 1'b0;
    this.vif_snf.g_drv.snf_cb.txrspflit       <= flit;
    this.vif_snf.g_drv.snf_cb.txrspflitv      <= 1'b1;

    @(this.vif_snf.g_drv.snf_cb);
    this.drive_idle_sideband();
    this.vif_snf.g_drv.snf_cb.txrspflitv      <= 1'b0;
    this.vif_snf.g_drv.snf_cb.txrspflit       <= '0;
  endtask

  // ---------------------------------------------------------------------------
  // Auto-respond to one ordered read request with a ReadReceipt before DAT.
  // ---------------------------------------------------------------------------
  protected task drive_auto_read_receipt(input req_flit_t req);
    item_t rsp;

    rsp              = new("auto_read_receipt_rsp");
    rsp.role         = VIP_CHI_ROLE_SNF_E;
    rsp.src_id       = node_id_t'(req.tgtid);
    rsp.tgt_id       = node_id_t'(req.srcid);
    rsp.txn_id       = txn_id_t'(req.txnid);
    rsp.qos          = req.qos;
    rsp.rsp_resp     = VIP_CHI_RESP_STATE_I_E;
    rsp.rsp_resp_err = VIP_CHI_RESP_ERR_NORMAL_OKAY_E;
    rsp.rsp_opcode   = item_t::rsp_opcode_t'(VIP_CHI_RSP_READ_RECEIPT_C);
    this.drive_rsp(rsp);
  endtask

  // ---------------------------------------------------------------------------
  // Drive one raw item verbatim on the responder-supported channel selected by
  // raw_channel.
  // ---------------------------------------------------------------------------
  protected task drive_raw_item(input item_t item);
    if (!this.cfg.allow_raw_override) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] raw_override is disabled in cfg",
        get_name()))
    end

    case (item.raw_channel)
      VIP_CHI_RAW_RSP_E: begin
        this.drive_raw_rsp(item);
      end
      VIP_CHI_RAW_DAT_E: begin
        this.drive_raw_dat(item);
      end
      default: begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] SN-F raw_override only supports RSP or DAT channels",
          get_name()))
      end
    endcase
  endtask

  // ---------------------------------------------------------------------------
  // Opt-in protocol-credit retry: while fewer than cfg.force_retry_count
  // RetryAcks have been sent, an inbound retryable REQ (AllowRetry=1) is bounced
  // instead of serviced. A serviced-normally re-issue (AllowRetry=0) is never
  // retried, so force_retry_count bounds the total retries a stream can see.
  // ---------------------------------------------------------------------------
  protected function bit should_auto_retry(input req_flit_t req);
    return (this.retries_issued < this.cfg.force_retry_count) && req.allowretry;
  endfunction

  // ---------------------------------------------------------------------------
  // Bounce one REQ with a RetryAck (carrying a PCrdType) followed by a matching
  // PCrdGrant, so the requester can re-issue once it holds the credit. The
  // RetryAck is keyed to the REQ's TxnID; the PCrdGrant carries only the granted
  // PCrdType (it is not tied to a TxnID).
  // ---------------------------------------------------------------------------
  protected task drive_auto_retry(input req_flit_t req);
    item_t retry_ack;
    item_t pcrd_grant;
    vip_chi_pcrd_type_t pcrd;

    pcrd = 4'h1;   // fixed non-zero P-credit type for the single-RN happy path

    retry_ack               = new("auto_retry_ack");
    retry_ack.role          = VIP_CHI_ROLE_SNF_E;
    retry_ack.src_id        = node_id_t'(req.tgtid);
    retry_ack.tgt_id        = node_id_t'(req.srcid);
    retry_ack.txn_id        = txn_id_t'(req.txnid);
    retry_ack.qos           = req.qos;
    retry_ack.pcrd_type     = pcrd;
    retry_ack.rsp_resp      = VIP_CHI_RESP_STATE_I_E;
    retry_ack.rsp_resp_err  = VIP_CHI_RESP_ERR_NORMAL_OKAY_E;
    retry_ack.rsp_opcode    = item_t::rsp_opcode_t'(VIP_CHI_RSP_RETRY_ACK_C);
    this.drive_rsp(retry_ack);

    pcrd_grant              = new("auto_pcrd_grant");
    pcrd_grant.role         = VIP_CHI_ROLE_SNF_E;
    pcrd_grant.src_id       = node_id_t'(req.tgtid);
    pcrd_grant.tgt_id       = node_id_t'(req.srcid);
    pcrd_grant.txn_id       = '0;   // PCrdGrant is not tied to a TxnID
    pcrd_grant.qos          = req.qos;
    pcrd_grant.pcrd_type    = pcrd;
    pcrd_grant.rsp_resp     = VIP_CHI_RESP_STATE_I_E;
    pcrd_grant.rsp_resp_err = VIP_CHI_RESP_ERR_NORMAL_OKAY_E;
    pcrd_grant.rsp_opcode   = item_t::rsp_opcode_t'(VIP_CHI_RSP_PCRD_GRANT_C);
    this.drive_rsp(pcrd_grant);
  endtask

  // ---------------------------------------------------------------------------
  // Drive one raw RSP flit.
  // ---------------------------------------------------------------------------
  protected task drive_raw_rsp(input item_t item);
    rsp_flit_t flit;

    flit = '0;
    flit.tracetag = item.raw_rsp.tracetag;
    flit.pcrdtype = item.raw_rsp.pcrdtype;
    flit.dbid     = item.raw_rsp.dbid;
    flit.cbusy    = item.raw_rsp.cbusy;
    flit.fwdstate = item.raw_rsp.fwdstate;
    flit.resp     = item.raw_rsp.resp;
    flit.resperr  = item.raw_rsp.resperr;
    flit.opcode   = item.raw_rsp.opcode;
    flit.txnid    = item.raw_rsp.txnid;
    flit.srcid    = item.raw_rsp.srcid;
    flit.tgtid    = item.raw_rsp.tgtid;
    flit.qos      = item.raw_rsp.qos;
    this.apply_raw_rsp_issue_specific_fields(flit, item.raw_rsp);

    this.wait_for_credit(this.rsp_lcrd_mgr);

    @(this.vif_snf.g_drv.snf_cb);
    this.drive_idle_sideband();
    this.vif_snf.g_drv.snf_cb.txrspflitpend   <= item.raw_flitpend;
    this.vif_snf.g_drv.snf_cb.txrspflit       <= flit;
    this.vif_snf.g_drv.snf_cb.txrspflitv      <= 1'b1;

    @(this.vif_snf.g_drv.snf_cb);
    this.drive_idle_sideband();
    this.vif_snf.g_drv.snf_cb.txrspflitpend   <= 1'b0;
    this.vif_snf.g_drv.snf_cb.txrspflitv      <= 1'b0;
    this.vif_snf.g_drv.snf_cb.txrspflit       <= '0;
  endtask

  // ---------------------------------------------------------------------------
  // Optional issue-specific raw-RSP hook for exact-CHI-E field presence.
  // ---------------------------------------------------------------------------
  virtual protected function void apply_raw_rsp_issue_specific_fields(
    ref rsp_flit_t flit,
    input raw_rsp_t raw
  );
  endfunction

  // ---------------------------------------------------------------------------
  // Optional issue-specific DAT-field hook. The shared implementation only
  // drives fields present in both exact CHI-D and exact CHI-E DAT shapes.
  // ---------------------------------------------------------------------------
  virtual protected function void apply_dat_issue_specific_fields(
    ref dat_flit_t   flit,
    input item_t     rsp,
    input int unsigned beat_index
  );
  endfunction

  // ---------------------------------------------------------------------------
  // Optional issue-specific raw-DAT hook for exact-CHI-E field presence.
  // ---------------------------------------------------------------------------
  virtual protected function void apply_raw_dat_issue_specific_fields(
    ref dat_flit_t flit,
    input raw_dat_t raw
  );
  endfunction

  // ---------------------------------------------------------------------------
  // Optional issue-specific reset hook for subclass-owned autonomous state.
  // ---------------------------------------------------------------------------
  virtual protected function void handle_issue_specific_reset();
  endfunction

  // ---------------------------------------------------------------------------
  // Optional issue-specific hook to capture autonomous write-side metadata
  // from each observed inbound DAT beat.
  // ---------------------------------------------------------------------------
  virtual protected function void capture_auto_write_issue_specific_fields(
    input addr_t       req_addr,
    input int unsigned beat_index,
    input dat_flit_t   flit
  );
  endfunction

  // ---------------------------------------------------------------------------
  // Optional issue-specific hook to replay autonomous read-side metadata onto
  // each outbound CompData beat.
  // ---------------------------------------------------------------------------
  virtual protected function void apply_auto_read_issue_specific_fields(
    ref dat_flit_t     flit,
    input addr_t       req_addr,
    input int unsigned beat_index
  );
  endfunction

  // ---------------------------------------------------------------------------
  // Drive one raw DAT flit.
  // ---------------------------------------------------------------------------
  protected task drive_raw_dat(input item_t item);
    dat_flit_t flit;

    flit = '0;
    flit.poison     = item.raw_dat.poison;
    flit.datacheck  = item.raw_dat.datacheck;
    flit.data       = item.raw_dat.data;
    flit.be         = item.raw_dat.be;
    flit.tracetag   = item.raw_dat.tracetag;
    flit.dataid     = item.raw_dat.dataid;
    flit.ccid       = item.raw_dat.ccid;
    flit.dbid       = item.raw_dat.dbid;
    flit.cbusy      = item.raw_dat.cbusy;
    flit.datasource = item.raw_dat.datasource;
    flit.resp       = item.raw_dat.resp;
    flit.resperr    = item.raw_dat.resperr;
    flit.opcode     = item.raw_dat.opcode;
    flit.homenid    = item.raw_dat.homenid;
    flit.txnid      = item.raw_dat.txnid;
    flit.srcid      = item.raw_dat.srcid;
    flit.tgtid      = item.raw_dat.tgtid;
    flit.qos        = item.raw_dat.qos;
    this.apply_raw_dat_issue_specific_fields(flit, item.raw_dat);

    this.wait_for_credit(this.dat_lcrd_mgr);

    @(this.vif_snf.g_drv.snf_cb);
    this.drive_idle_sideband();
    this.vif_snf.g_drv.snf_cb.txdatflitpend   <= item.raw_flitpend;
    this.vif_snf.g_drv.snf_cb.txdatflit       <= flit;
    this.vif_snf.g_drv.snf_cb.txdatflitv      <= 1'b1;

    @(this.vif_snf.g_drv.snf_cb);
    this.drive_idle_sideband();
    this.vif_snf.g_drv.snf_cb.txdatflitpend   <= 1'b0;
    this.vif_snf.g_drv.snf_cb.txdatflitv      <= 1'b0;
    this.vif_snf.g_drv.snf_cb.txdatflit       <= '0;
  endtask

  // ---------------------------------------------------------------------------
  // Drive one or more DAT flits for a completion carrying data.
  // ---------------------------------------------------------------------------
  protected task drive_dat(input item_t rsp);
    dat_flit_t flit;

    foreach (rsp.data[i]) begin
      flit = '0;
      flit.data       = rsp.data[i];
      flit.be         = rsp.be[i];
      flit.dataid     = data_id_t'(i);
      flit.ccid       = cc_id_t'(0);
      flit.dbid       = rsp.dbid;
      flit.resp       = (i < rsp.dat_resp.size()) ? rsp.dat_resp[i] : rsp.rsp_resp;
      flit.resperr    = (i < rsp.dat_resp_err.size()) ? rsp.dat_resp_err[i] : rsp.rsp_resp_err;
      flit.opcode     = rsp.dat_opcode;
      flit.txnid      = rsp.txn_id;
      flit.srcid      = rsp.src_id;
      flit.tgtid      = rsp.tgt_id;
      flit.qos        = rsp.qos;
      this.apply_dat_issue_specific_fields(flit, rsp, i);

      this.wait_for_credit(this.dat_lcrd_mgr);

      @(this.vif_snf.g_drv.snf_cb);
      this.drive_idle_sideband();
      this.vif_snf.g_drv.snf_cb.txdatflitpend   <= (i != (rsp.data.size() - 1));
      this.vif_snf.g_drv.snf_cb.txdatflit       <= flit;
      this.vif_snf.g_drv.snf_cb.txdatflitv      <= 1'b1;

      @(this.vif_snf.g_drv.snf_cb);
      this.drive_idle_sideband();
      this.vif_snf.g_drv.snf_cb.txdatflitpend   <= 1'b0;
      this.vif_snf.g_drv.snf_cb.txdatflitv      <= 1'b0;
      this.vif_snf.g_drv.snf_cb.txdatflit       <= '0;
    end

    @(this.vif_snf.g_drv.snf_cb);
    this.drive_idle_sideband();
  endtask

  // ---------------------------------------------------------------------------
  // Auto-respond to one observed non-coherent write request by collecting DAT,
  // committing it into vip_mem, then returning a simple Comp completion.
  // ---------------------------------------------------------------------------
  protected task drive_auto_write_comp(input req_flit_t req);
    item_t     rsp;
    item_t     deferred_comp_rsp;
    dat_flit_t flit;
    data_t     write_data[$];
    be_t       write_be[$];
    addr_t     req_addr;
    txn_id_t   req_txn_id;
    node_id_t  req_src_id;
    node_id_t  req_tgt_id;
    addr_t     mem_addr;
    int        beat_count;
    bit        is_decerr;

    req_addr   = addr_t'(req.addr);
    req_txn_id = txn_id_t'(req.txnid);
    req_src_id = node_id_t'(req.srcid);
    req_tgt_id = node_id_t'(req.tgtid);
    beat_count = vip_chi_types_pkg::chi_xfer_dat_beats(size_t'(req.size), CFG_P.DATA_BYTES_P);
    is_decerr  = this.decerr_check(req_addr);

    rsp          = new("auto_write_rsp");
    rsp.role     = VIP_CHI_ROLE_SNF_E;
    rsp.src_id   = req_tgt_id;
    rsp.tgt_id   = req_src_id;
    rsp.txn_id   = req_txn_id;
    rsp.dbid     = req_txn_id;
    rsp.qos      = req.qos;
    rsp.rsp_resp = VIP_CHI_RESP_STATE_I_E;
    rsp.rsp_resp_err = is_decerr ? VIP_CHI_RESP_ERR_NONDATA_ERROR_E : VIP_CHI_RESP_ERR_NORMAL_OKAY_E;
    if (this.cfg.split_write_rsp) begin
      if ((CFG_P.ISSUE_P == VIP_CHI_ISSUE_E_E) &&
          this.cfg.ordered_dbid_resp &&
          this.req_has_ordering(req)) begin
        rsp.rsp_opcode = item_t::rsp_opcode_t'(VIP_CHI_RSP_DBID_RESP_ORD_C);
      end
      else begin
        rsp.rsp_opcode = item_t::rsp_opcode_t'(VIP_CHI_RSP_DBID_RESP_C);
      end
    end
    else begin
      rsp.rsp_opcode = item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_DBID_RESP_C);
    end
    this.drive_rsp(rsp);

    if (this.cfg.split_write_rsp) begin
      deferred_comp_rsp = new("auto_write_comp_rsp");
      deferred_comp_rsp.role         = VIP_CHI_ROLE_SNF_E;
      deferred_comp_rsp.src_id       = req_tgt_id;
      deferred_comp_rsp.tgt_id       = req_src_id;
      deferred_comp_rsp.txn_id       = req_txn_id;
      deferred_comp_rsp.dbid         = req_txn_id;
      deferred_comp_rsp.qos          = req.qos;
      deferred_comp_rsp.rsp_resp     = rsp.rsp_resp;
      deferred_comp_rsp.rsp_resp_err = rsp.rsp_resp_err;
      deferred_comp_rsp.rsp_opcode   = item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_C);
    end

    for (int beat_index = 0; beat_index < beat_count; beat_index++) begin
      while (!this.vif_snf.g_drv.snf_cb.rxdatflitv) begin
        @(this.vif_snf.g_drv.snf_cb);
        this.drive_idle_sideband();
      end

      flit = this.vif_snf.g_drv.snf_cb.rxdatflit;
      if (txn_id_t'(flit.txnid) != rsp.dbid) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] Write DAT txn_id 0x%0h does not match granted DBID 0x%0h",
          get_name(), flit.txnid, rsp.dbid))
      end

      if (txn_id_t'(flit.dbid) != rsp.dbid) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] Write DAT dbid 0x%0h does not match granted DBID 0x%0h",
          get_name(), flit.dbid, rsp.dbid))
      end

      // WriteData must be sourced by the requester and targeted at this SN-F
      // (the DBID granter). Checking it here catches a routed initiator that
      // ships reversed SrcID/TgtID rather than silently accepting the data.
      if ((node_id_t'(flit.srcid) != req_src_id) ||
          (node_id_t'(flit.tgtid) != req_tgt_id)) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] Write DAT src/tgt 0x%0h->0x%0h did not match expected 0x%0h->0x%0h",
          get_name(), flit.srcid, flit.tgtid, req_src_id, req_tgt_id))
      end

      this.schedule_dat_credit_return();

      write_data.push_back(data_t'(flit.data));
      write_be.push_back(be_t'(flit.be));

      if (!is_decerr) begin
        this.capture_auto_write_issue_specific_fields(req_addr, beat_index, flit);
      end

      if (!this.vif_snf.g_drv.snf_cb.rxdatflitpend) begin
        break;
      end

      @(this.vif_snf.g_drv.snf_cb);
      this.drive_idle_sideband();
    end

    if (!is_decerr) begin
      mem_addr = req_addr;
      this.mem.wr_be(mem_addr, write_data, write_be);
      foreach (write_data[i]) begin
        this.mark_backing_row(req_addr + addr_t'(i * CFG_P.DATA_BYTES_P));
      end
    end

    if (this.cfg.split_write_rsp) begin
      this.drive_rsp(deferred_comp_rsp);
    end

    // The CMO half, and it goes HERE for a reason the spec states outright: the
    // combined request is one request carrying two operations to the same
    // address, and the CMO acts on the state the write leaves behind. Driving it
    // before the data had landed would answer for a cache maintenance that had
    // not happened yet.
    if (this.req_opcode_is_combined_write_cmo(req_opcode_t'(req.opcode))) begin
      this.drive_combined_cmo_rsp(req, rsp.rsp_resp_err);
    end

    if (req.expcompack) begin
      this.wait_for_comp_ack(req_txn_id, req_src_id, req_tgt_id);
    end
  endtask

  // ---------------------------------------------------------------------------
  // The CMO half of a combined Write + CMO completion.
  //
  // The write half completes as any write does (Comp / CompDBIDResp). The CMO
  // half is a SEPARATE response -- CompCMO -- and a completer that answered a
  // combined request with the write completion alone would leave the CMO
  // permanently outstanding at the requester.
  //
  // For the persistent forms the spec additionally requires a Persist response
  // AFTER the write data is received, which is the ordering rule this whole
  // family turns on. Persist and CompCMO may be combined into a single
  // CompPersist when both target the same node; they are kept separate here
  // because two observable events are what a test can check an order between,
  // and the combined encoding would collapse exactly the evidence.
  // ---------------------------------------------------------------------------
  protected task drive_combined_cmo_rsp(
    input req_flit_t                req,
    input vip_chi_resp_err_t        resp_err
  );
    item_t cmo_rsp;
    item_t persist_rsp;

    cmo_rsp              = new("combined_cmo_rsp");
    cmo_rsp.role         = VIP_CHI_ROLE_SNF_E;
    cmo_rsp.src_id       = node_id_t'(req.tgtid);
    cmo_rsp.tgt_id       = node_id_t'(req.srcid);
    cmo_rsp.txn_id       = txn_id_t'(req.txnid);
    cmo_rsp.dbid         = txn_id_t'(req.txnid);
    cmo_rsp.qos          = req.qos;
    cmo_rsp.rsp_resp     = VIP_CHI_RESP_STATE_I_E;
    cmo_rsp.rsp_resp_err = resp_err;
    cmo_rsp.rsp_opcode   = item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_CMO_C);
    this.drive_rsp(cmo_rsp);

    if (!this.req_opcode_combined_cmo_is_persist(req_opcode_t'(req.opcode))) begin
      return;
    end

    persist_rsp              = new("combined_persist_rsp");
    persist_rsp.role         = VIP_CHI_ROLE_SNF_E;
    persist_rsp.src_id       = node_id_t'(req.tgtid);
    persist_rsp.tgt_id       = node_id_t'(req.srcid);
    persist_rsp.txn_id       = txn_id_t'(req.txnid);
    persist_rsp.dbid         = txn_id_t'(req.txnid);
    persist_rsp.qos          = req.qos;
    persist_rsp.rsp_resp     = VIP_CHI_RESP_STATE_I_E;
    persist_rsp.rsp_resp_err = resp_err;
    persist_rsp.rsp_opcode   = item_t::rsp_opcode_t'(VIP_CHI_RSP_PERSIST_C);
    this.drive_rsp(persist_rsp);
  endtask

  // ---------------------------------------------------------------------------
  // Auto-respond to one observed WriteNoSnpZero with a data-less Comp. No write
  // data flit is expected; a successful request zeroes exactly the Size-selected
  // byte range in backing memory before completion.
  // ---------------------------------------------------------------------------
  protected task drive_auto_write_zero_comp(input req_flit_t req);
    item_t       rsp;
    item_t       comp_rsp;
    bit          is_decerr;
    addr_t       req_addr;
    data_t       zero_data[$];
    be_t         zero_be[$];
    int          beat_count;
    int unsigned transfer_bytes;
    int unsigned remaining_bytes;
    longint      first_row;
    longint      last_row;

    req_addr       = addr_t'(req.addr);
    is_decerr      = this.decerr_check(req_addr);
    transfer_bytes = 1 << int'(req.size);
    beat_count     = vip_chi_types_pkg::chi_xfer_dat_beats(size_t'(req.size), CFG_P.DATA_BYTES_P);

    if (!is_decerr) begin
      remaining_bytes = transfer_bytes;
      for (int beat_index = 0; beat_index < beat_count; beat_index++) begin
        int unsigned bytes_this_beat;

        zero_data.push_back('0);
        zero_be.push_back('0);

        bytes_this_beat = (remaining_bytes > CFG_P.DATA_BYTES_P)
                        ? CFG_P.DATA_BYTES_P
                        : remaining_bytes;
        for (int lane = 0; lane < bytes_this_beat; lane++) begin
          zero_be[beat_index][lane] = 1'b1;
        end
        remaining_bytes -= bytes_this_beat;
      end

      this.mem.wr_be(req_addr, zero_data, zero_be);
      first_row = this.row_index_from_addr(req_addr);
      last_row  = this.row_index_from_addr(req_addr + addr_t'(transfer_bytes - 1));
      for (longint row = first_row; row <= last_row; row++) begin
        this.mark_backing_row(addr_t'(row * CFG_P.DATA_BYTES_P));
      end
    end

    // The response to WriteNoSnpZero is DBIDResp and a Comp, or a combined
    // CompDBIDResp. A bare Comp is neither, and that is what this drove: the
    // request carries no write data, so the DBID looks pointless and was simply
    // left out -- but the completion form is normative regardless of whether the
    // requester ever uses the buffer it is granted.
    //
    // cfg.split_write_rsp already means "grant and complete separately" for
    // ordinary writes, so the zero write follows the same switch rather than
    // inventing a second one.
    rsp              = new("auto_write_zero_rsp");
    rsp.role         = VIP_CHI_ROLE_SNF_E;
    rsp.src_id       = node_id_t'(req.tgtid);
    rsp.tgt_id       = node_id_t'(req.srcid);
    rsp.txn_id       = txn_id_t'(req.txnid);
    rsp.dbid         = txn_id_t'(req.txnid);
    rsp.qos          = req.qos;
    rsp.rsp_resp     = VIP_CHI_RESP_STATE_I_E;
    rsp.rsp_resp_err = is_decerr ? VIP_CHI_RESP_ERR_NONDATA_ERROR_E : VIP_CHI_RESP_ERR_NORMAL_OKAY_E;

    if (!this.cfg.split_write_rsp) begin
      rsp.rsp_opcode = item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_DBID_RESP_C);
      this.drive_rsp(rsp);
      return;
    end

    rsp.rsp_opcode = item_t::rsp_opcode_t'(VIP_CHI_RSP_DBID_RESP_C);
    this.drive_rsp(rsp);

    comp_rsp              = new("auto_write_zero_comp");
    comp_rsp.role         = VIP_CHI_ROLE_SNF_E;
    comp_rsp.src_id       = node_id_t'(req.tgtid);
    comp_rsp.tgt_id       = node_id_t'(req.srcid);
    comp_rsp.txn_id       = txn_id_t'(req.txnid);
    comp_rsp.qos          = req.qos;
    comp_rsp.rsp_resp     = VIP_CHI_RESP_STATE_I_E;
    comp_rsp.rsp_resp_err = rsp.rsp_resp_err;
    comp_rsp.rsp_opcode   = item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_C);
    this.drive_rsp(comp_rsp);
  endtask

  // ---------------------------------------------------------------------------
  // Auto-respond to one observed non-coherent read request with CompData.
  // ---------------------------------------------------------------------------
  protected task drive_auto_read_compdata(input req_flit_t req);
    dat_flit_t flit;
    item_t     resp_sep_rsp;
    int        beat_count;
    int        beat_index;
    size_t     req_size;
    addr_t     req_addr;
    txn_id_t   req_txn_id;
    txn_id_t   rsp_txn_id;
    node_id_t  req_src_id;
    node_id_t  req_tgt_id;
    node_id_t  rsp_tgt_id;
    vip_chi_resp_t     resp_code;
    vip_chi_resp_err_t resp_err_code;
    bit        is_sep_read;
    bit        is_decerr;
    bit        is_derr;

    req_size   = size_t'(req.size);
    req_addr   = addr_t'(req.addr);
    req_txn_id = txn_id_t'(req.txnid);
    req_src_id = node_id_t'(req.srcid);
    req_tgt_id = node_id_t'(req.tgtid);
    is_sep_read = (req_opcode_t'(req.opcode) == req_opcode_t'(VIP_CHI_REQ_READ_NO_SNP_SEP_C));
    rsp_txn_id = is_sep_read ? txn_id_t'(req.returntxnid) : req_txn_id;
    rsp_tgt_id = is_sep_read ? node_id_t'(req.returnnid) : req_src_id;
    is_decerr  = this.decerr_check(req_addr);
    is_derr    = this.derr_check(req_addr);
    beat_count = vip_chi_types_pkg::chi_xfer_dat_beats(req_size, CFG_P.DATA_BYTES_P);

    if (is_decerr) begin
      resp_code  = VIP_CHI_RESP_STATE_I_E;
      resp_err_code = VIP_CHI_RESP_ERR_NONDATA_ERROR_E;
    end
    else begin
      resp_code  = VIP_CHI_RESP_STATE_I_E;
      resp_err_code = is_derr ? VIP_CHI_RESP_ERR_DATA_ERROR_E : VIP_CHI_RESP_ERR_NORMAL_OKAY_E;
    end

    if (this.req_has_ordering(req)) begin
      this.drive_auto_read_receipt(req);
    end

    // Separated read: the response leg (RespSepData) is sent on the RSP channel
    // to the requester (original TxnID), separate from the data leg (DataSepResp)
    // that follows on DAT to ReturnNID/ReturnTxnID. Combined reads send neither.
    if (is_sep_read) begin
      resp_sep_rsp              = new("auto_read_resp_sep");
      resp_sep_rsp.role         = VIP_CHI_ROLE_SNF_E;
      resp_sep_rsp.src_id       = req_tgt_id;
      resp_sep_rsp.tgt_id       = req_src_id;
      resp_sep_rsp.txn_id       = req_txn_id;
      resp_sep_rsp.dbid         = req_txn_id;
      resp_sep_rsp.qos          = req.qos;
      resp_sep_rsp.rsp_resp     = resp_code;
      resp_sep_rsp.rsp_resp_err = resp_err_code;
      resp_sep_rsp.rsp_opcode   = item_t::rsp_opcode_t'(VIP_CHI_RSP_RESP_SEP_DATA_C);
      this.drive_rsp(resp_sep_rsp);
    end

    for (int send_index = 0; send_index < beat_count; send_index++) begin

      // Which beat position this send carries. Ascending by default; the two
      // cfg knobs move the position without touching the payload, so the data a
      // beat carries always belongs to the DataID it announces.
      beat_index = this.dat_beat_position(send_index, beat_count);

      flit = '0;
      flit.data       = is_decerr ? '0 : this.read_data_beat(req_addr, beat_index);
      flit.be         = is_decerr ? '0 : '1;
      flit.dataid     = data_id_t'(beat_index);
      flit.ccid       = cc_id_t'(0);
      flit.dbid       = rsp_txn_id;
      flit.resp       = vip_chi_resp_t'(resp_code);
      flit.resperr    = vip_chi_resp_err_t'(resp_err_code);
      flit.opcode     = is_sep_read ?
                        item_t::dat_opcode_t'(VIP_CHI_DAT_DATA_SEP_RESP_C) :
                        item_t::dat_opcode_t'(VIP_CHI_DAT_COMP_DATA_C);
      flit.homenid    = req_tgt_id;
      flit.txnid      = rsp_txn_id;
      flit.srcid      = req_tgt_id;
      flit.tgtid      = rsp_tgt_id;
      flit.qos        = req.qos;   // echo the request QoS on CompData (P3c)

      if (!is_decerr) begin
        this.apply_auto_read_issue_specific_fields(flit, req_addr, beat_index);
      end

      this.wait_for_credit(this.dat_lcrd_mgr);

      @(this.vif_snf.g_drv.snf_cb);
      this.drive_idle_sideband();
      this.vif_snf.g_drv.snf_cb.txdatflitpend   <= (send_index != (beat_count - 1));
      this.vif_snf.g_drv.snf_cb.txdatflit       <= flit;
      this.vif_snf.g_drv.snf_cb.txdatflitv      <= 1'b1;

      @(this.vif_snf.g_drv.snf_cb);
      this.drive_idle_sideband();
      this.vif_snf.g_drv.snf_cb.txdatflitpend   <= 1'b0;
      this.vif_snf.g_drv.snf_cb.txdatflitv      <= 1'b0;
      this.vif_snf.g_drv.snf_cb.txdatflit       <= '0;
    end

    @(this.vif_snf.g_drv.snf_cb);
    this.drive_idle_sideband();
  endtask

  // ---------------------------------------------------------------------------
  // Auto-respond to one atomic request by collecting operand DAT, performing
  // the memory-side RMW, then returning either Comp or CompData.
  // ---------------------------------------------------------------------------
  protected task drive_auto_atomic_completion(input req_flit_t req);
    item_t     grant_rsp;
    item_t     final_rsp;
    item_t     compdata_rsp;
    dat_flit_t flit;
    data_t     operand_data[$];
    data_t     old_data[$];
    data_t     new_data[$];
    be_t       write_be[$];
    addr_t     req_addr;
    txn_id_t   req_txn_id;
    node_id_t  req_src_id;
    node_id_t  req_tgt_id;
    size_t     req_size;
    int        beat_count;
    int        granule_beat_count;
    int        operand_beat_count;
    int        atomic_variant;
    bit        returns_data;
    bit        is_compare;
    bit        compare_match;
    bit        is_decerr;
    bit        is_derr;
    vip_chi_resp_t     resp_code;
    vip_chi_resp_err_t resp_err_code;

    req_addr           = addr_t'(req.addr);
    req_txn_id         = txn_id_t'(req.txnid);
    req_src_id         = node_id_t'(req.srcid);
    req_tgt_id         = node_id_t'(req.tgtid);
    req_size           = size_t'(req.size);
    beat_count         = vip_chi_types_pkg::chi_xfer_dat_beats(req_size, CFG_P.DATA_BYTES_P);
    returns_data       = vip_chi_types_pkg::vip_chi_req_opcode_is_atomic_returning_data(
                           vip_chi_req_opcode_t'(req.opcode));
    is_compare         = vip_chi_types_pkg::vip_chi_req_opcode_is_atomic_compare(
                           vip_chi_req_opcode_t'(req.opcode));
    // AtomicCompare Size spans the COMBINED compare+swap payload (IHI 0050), so
    // beat_count is the full operand-DAT length; the memory granule the RMW
    // touches (compare span, pre-op read, CompData return) is the first half.
    // Every other atomic uses its whole operand span. [P2]
    granule_beat_count = is_compare ? (beat_count / 2) : beat_count;
    operand_beat_count = beat_count;
    atomic_variant     = this.req_opcode_atomic_variant(req_opcode_t'(req.opcode));
    is_decerr          = this.decerr_check(req_addr);
    is_derr            = this.derr_check(req_addr);

    grant_rsp              = new("auto_atomic_grant_rsp");
    grant_rsp.role         = VIP_CHI_ROLE_SNF_E;
    grant_rsp.src_id       = req_tgt_id;
    grant_rsp.tgt_id       = req_src_id;
    grant_rsp.txn_id       = req_txn_id;
    grant_rsp.dbid         = req_txn_id;
    grant_rsp.qos          = req.qos;
    grant_rsp.rsp_resp     = VIP_CHI_RESP_STATE_I_E;
    grant_rsp.rsp_resp_err = is_decerr ? VIP_CHI_RESP_ERR_NONDATA_ERROR_E : VIP_CHI_RESP_ERR_NORMAL_OKAY_E;

    if (returns_data) begin
      if ((CFG_P.ISSUE_P == VIP_CHI_ISSUE_E_E) &&
          this.cfg.ordered_dbid_resp &&
          this.req_has_ordering(req)) begin
        grant_rsp.rsp_opcode = item_t::rsp_opcode_t'(VIP_CHI_RSP_DBID_RESP_ORD_C);
      end
      else begin
        grant_rsp.rsp_opcode = item_t::rsp_opcode_t'(VIP_CHI_RSP_DBID_RESP_C);
      end
    end
    else if (this.cfg.split_write_rsp) begin
      if ((CFG_P.ISSUE_P == VIP_CHI_ISSUE_E_E) &&
          this.cfg.ordered_dbid_resp &&
          this.req_has_ordering(req)) begin
        grant_rsp.rsp_opcode = item_t::rsp_opcode_t'(VIP_CHI_RSP_DBID_RESP_ORD_C);
      end
      else begin
        grant_rsp.rsp_opcode = item_t::rsp_opcode_t'(VIP_CHI_RSP_DBID_RESP_C);
      end
    end
    else begin
      grant_rsp.rsp_opcode = item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_DBID_RESP_C);
    end

    this.drive_rsp(grant_rsp);

    for (int beat_index = 0; beat_index < operand_beat_count; beat_index++) begin
      while (!this.vif_snf.g_drv.snf_cb.rxdatflitv) begin
        @(this.vif_snf.g_drv.snf_cb);
        this.drive_idle_sideband();
      end

      flit = this.vif_snf.g_drv.snf_cb.rxdatflit;
      if (txn_id_t'(flit.txnid) != grant_rsp.dbid) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] Atomic DAT txn_id 0x%0h does not match granted DBID 0x%0h",
          get_name(), flit.txnid, grant_rsp.dbid))
      end

      if (txn_id_t'(flit.dbid) != grant_rsp.dbid) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] Atomic DAT dbid 0x%0h does not match granted DBID 0x%0h",
          get_name(), flit.dbid, grant_rsp.dbid))
      end

      // The atomic operand must be sourced by the requester and targeted at
      // this SN-F, exactly as for WriteData (catches reversed SrcID/TgtID).
      if ((node_id_t'(flit.srcid) != req_src_id) ||
          (node_id_t'(flit.tgtid) != req_tgt_id)) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] Atomic DAT src/tgt 0x%0h->0x%0h did not match expected 0x%0h->0x%0h",
          get_name(), flit.srcid, flit.tgtid, req_src_id, req_tgt_id))
      end

      this.schedule_dat_credit_return();
      operand_data.push_back(data_t'(flit.data));

      if (!this.vif_snf.g_drv.snf_cb.rxdatflitpend) begin
        break;
      end

      @(this.vif_snf.g_drv.snf_cb);
      this.drive_idle_sideband();
    end

    if (is_compare && (operand_data.size() != beat_count)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] AtomicCompare expected %0d operand beats, got %0d",
        get_name(), beat_count, operand_data.size()))
    end

    for (int beat_index = 0; beat_index < granule_beat_count; beat_index++) begin
      if (is_decerr) begin
        old_data.push_back('0);
      end
      else begin
        old_data.push_back(this.read_data_beat(req_addr, beat_index));
      end
    end

    // §22 L3 decision: the RMW commit is gated on DECERR only, not DERR. This is
    // deliberate and consistent with the read/write model above -- DECERR models
    // a rejected access (no state change, NONDATA_ERROR), whereas DERR models an
    // access that proceeds with its returned data flagged corrupt (DATA_ERROR).
    // So a DERR-range atomic still commits the RMW and returns the errored old
    // data on its CompData leg. Gating the commit on DERR too would be a
    // different, equally defensible memory-model stance; it is intentionally NOT
    // taken so the DERR datapath stays "operation happens, data flagged" uniform.
    if (!is_decerr) begin
      if (is_compare) begin
        compare_match = 1'b1;
        for (int beat_index = 0; beat_index < granule_beat_count; beat_index++) begin
          if (old_data[beat_index] != operand_data[beat_index]) begin
            compare_match = 1'b0;
          end
        end

        for (int beat_index = 0; beat_index < granule_beat_count; beat_index++) begin
          if (compare_match) begin
            new_data.push_back(operand_data[beat_index + granule_beat_count]);
          end
          else begin
            new_data.push_back(old_data[beat_index]);
          end
        end
      end
      else if (req_opcode_t'(req.opcode) == req_opcode_t'(VIP_CHI_REQ_ATOMIC_SWAP_C)) begin
        for (int beat_index = 0; beat_index < beat_count; beat_index++) begin
          new_data.push_back(operand_data[beat_index]);
        end
      end
      else begin
        for (int beat_index = 0; beat_index < beat_count; beat_index++) begin
          new_data.push_back(this.apply_atomic_variant(
            atomic_variant,
            old_data[beat_index],
            operand_data[beat_index]));
        end
      end

      for (int beat_index = 0; beat_index < granule_beat_count; beat_index++) begin
        write_be.push_back('1);
      end

      this.mem.wr_be(req_addr, new_data, write_be);
      foreach (new_data[i]) begin
        this.mark_backing_row(req_addr + addr_t'(i * CFG_P.DATA_BYTES_P));
      end
    end

    if (returns_data) begin
      if (is_decerr) begin
        resp_code     = VIP_CHI_RESP_STATE_I_E;
        resp_err_code = VIP_CHI_RESP_ERR_NONDATA_ERROR_E;
      end
      else begin
        resp_code     = VIP_CHI_RESP_STATE_I_E;
        resp_err_code = is_derr ? VIP_CHI_RESP_ERR_DATA_ERROR_E : VIP_CHI_RESP_ERR_NORMAL_OKAY_E;
      end

      compdata_rsp              = new("auto_atomic_compdata_rsp");
      compdata_rsp.role         = VIP_CHI_ROLE_SNF_E;
      compdata_rsp.src_id       = req_tgt_id;
      compdata_rsp.tgt_id       = req_src_id;
      compdata_rsp.txn_id       = req_txn_id;
      compdata_rsp.dbid         = req_txn_id;
      compdata_rsp.qos          = req.qos;
      compdata_rsp.dat_opcode   = item_t::dat_opcode_t'(VIP_CHI_DAT_COMP_DATA_C);
      compdata_rsp.rsp_resp     = resp_code;
      compdata_rsp.rsp_resp_err = resp_err_code;
      compdata_rsp.data         = new[granule_beat_count];
      compdata_rsp.be           = new[granule_beat_count];
      compdata_rsp.dat_resp     = new[granule_beat_count];
      compdata_rsp.dat_resp_err = new[granule_beat_count];

      for (int beat_index = 0; beat_index < granule_beat_count; beat_index++) begin
        compdata_rsp.data[beat_index]         = old_data[beat_index];
        compdata_rsp.be[beat_index]           = is_decerr ? '0 : '1;
        compdata_rsp.dat_resp[beat_index]     = resp_code;
        compdata_rsp.dat_resp_err[beat_index] = resp_err_code;
      end

      this.drive_dat(compdata_rsp);
    end
    else if (this.cfg.split_write_rsp) begin
      final_rsp              = new("auto_atomic_comp_rsp");
      final_rsp.role         = VIP_CHI_ROLE_SNF_E;
      final_rsp.src_id       = req_tgt_id;
      final_rsp.tgt_id       = req_src_id;
      final_rsp.txn_id       = req_txn_id;
      final_rsp.dbid         = req_txn_id;
      final_rsp.qos          = req.qos;
      final_rsp.rsp_resp     = VIP_CHI_RESP_STATE_I_E;
      final_rsp.rsp_resp_err = grant_rsp.rsp_resp_err;
      final_rsp.rsp_opcode   = item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_C);
      this.drive_rsp(final_rsp);
    end

    if (req.expcompack) begin
      this.wait_for_comp_ack(req_txn_id, req_src_id, req_tgt_id);
    end
  endtask

  // ---------------------------------------------------------------------------
  // Auto-respond to one persist request with completion-only RSP traffic.
  //
  // CleanSharedPersist takes a single Comp. CleanSharedPersistSep has exactly two
  // legal completions, and this drives one of them:
  //
  //   * Comp then Persist -- the request reached the Point of Coherency, then it
  //     reached the Point of Persistence. Two milestones, two responses. Default.
  //   * a single CompPersist, the two combined. cfg.combined_persist_rsp.
  //
  // It used to drive Persist then CompPersist, which is neither: the requester
  // never received a bare Comp, and persistence was signalled twice -- once
  // alone and again inside the combined response.
  // ---------------------------------------------------------------------------
  protected task drive_auto_persist_rsp(input req_flit_t req);
    item_t rsp;
    item_t persist_rsp;
    bit    is_sep;

    is_sep = (req_opcode_t'(req.opcode) == req_opcode_t'(VIP_CHI_REQ_CLEAN_SHARED_PERSIST_SEP_C));

    rsp              = new("auto_persist_rsp");
    rsp.role         = VIP_CHI_ROLE_SNF_E;
    rsp.src_id       = node_id_t'(req.tgtid);
    rsp.tgt_id       = node_id_t'(req.srcid);
    rsp.txn_id       = txn_id_t'(req.txnid);
    rsp.qos          = req.qos;
    rsp.rsp_resp     = VIP_CHI_RESP_STATE_I_E;
    rsp.rsp_resp_err = VIP_CHI_RESP_ERR_NORMAL_OKAY_E;

    if (is_sep && this.cfg.combined_persist_rsp) begin
      rsp.rsp_opcode = item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_PERSIST_C);
      this.drive_rsp(rsp);
      return;
    end

    rsp.rsp_opcode = item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_C);
    this.drive_rsp(rsp);

    if (is_sep) begin
      persist_rsp              = new("auto_persist_sep_rsp");
      persist_rsp.role         = VIP_CHI_ROLE_SNF_E;
      persist_rsp.src_id       = node_id_t'(req.tgtid);
      persist_rsp.tgt_id       = node_id_t'(req.srcid);
      persist_rsp.txn_id       = txn_id_t'(req.txnid);
      persist_rsp.qos          = req.qos;
      persist_rsp.rsp_resp     = VIP_CHI_RESP_STATE_I_E;
      persist_rsp.rsp_resp_err = VIP_CHI_RESP_ERR_NORMAL_OKAY_E;
      persist_rsp.rsp_opcode   = item_t::rsp_opcode_t'(VIP_CHI_RSP_PERSIST_C);
      this.drive_rsp(persist_rsp);
    end
  endtask

endclass

`endif
