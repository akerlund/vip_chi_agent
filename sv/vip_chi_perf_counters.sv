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

`uvm_analysis_imp_decl(_req_perf)
`uvm_analysis_imp_decl(_rsp_perf)
`uvm_analysis_imp_decl(_dat_perf)

// ===========================================================================
// vip_chi_perf_counters
//
// Standalone, always-on performance instrumentation for the vip_chi example.
// It is a sibling of vip_chi_coverage: it subscribes to one requester stream's
// REQ/RSP/DAT analysis ports and aggregates timing/throughput statistics rather
// than sampling covergroups. It never fails a test -- it only reports a summary
// line at UVM_LOW in report_phase.
//
// Measurements (per requester stream):
//   - REQ -> completion latency (min/avg/max cycles), split read vs write.
//   - Throughput: completions per PERF_WINDOW_CYCLES_C window (avg + peak).
//   - Retry count (inbound RetryAck).
//   - Per-channel back-pressure cycles (a requester tx channel asserts flitpend
//     but no flit transfers that cycle -- a wire-only proxy for stall, not exact
//     credit accounting).
//   - Reset events.
//
// Time source is a free-running, reset-gated cycle counter driven off the shared
// monitor clocking block, so latencies are deterministic integer cycles that are
// independent of timescale and comparable across runs. The vif is handed over by
// the env in connect_phase (like the scoreboard route policy) and is null-guarded
// so the component is inert in a topology that never wires it.
// ===========================================================================
class vip_chi_perf_counters #(
  vip_chi_cfg_t  CFG_P        = VIP_CHI_DEFAULT_CFG_C,
  type           FLIT_TYPES_T = vip_chi_types #(CFG_P),
  vip_chi_role_t ROLE_P       = VIP_CHI_ROLE_MONITOR_E
  ) extends uvm_component;

  `uvm_component_param_utils(vip_chi_perf_counters #(CFG_P, FLIT_TYPES_T, ROLE_P))

  typedef vip_chi_item #(CFG_P) item_t;
  typedef item_t::txn_id_t     txn_id_t;
  typedef item_t::req_opcode_t req_opcode_t;
  typedef item_t::rsp_opcode_t rsp_opcode_t;
  typedef item_t::dat_opcode_t dat_opcode_t;

  localparam int TXN_ID_COUNT_C       = 2 ** $bits(txn_id_t);
  localparam int PERF_WINDOW_CYCLES_C = 1000;

  // Master gate (set from tb_cfg.perf_enable by the env).
  bit enable = 1'b1;

  // The requester-stream virtual interface, used only as a deterministic clock +
  // reset + back-pressure source. Same parameterization as the wiring agent.
  virtual vip_chi_if #(CFG_P, FLIT_TYPES_T, ROLE_P) vif;

  uvm_analysis_imp_req_perf #(item_t, vip_chi_perf_counters #(CFG_P, FLIT_TYPES_T, ROLE_P)) req_perf;
  uvm_analysis_imp_rsp_perf #(item_t, vip_chi_perf_counters #(CFG_P, FLIT_TYPES_T, ROLE_P)) rsp_perf;
  uvm_analysis_imp_dat_perf #(item_t, vip_chi_perf_counters #(CFG_P, FLIT_TYPES_T, ROLE_P)) dat_perf;

  // Free-running deterministic time base (cycles with rst_n high).
  protected int unsigned cycle_count;
  protected int unsigned reset_count;
  protected int unsigned retry_count;

  // Per-transaction issue bookkeeping (indexed by requester TxnID).
  protected int unsigned start_cycle_by_txn [TXN_ID_COUNT_C];
  protected bit          start_valid_by_txn [TXN_ID_COUNT_C];
  protected bit          is_write_by_txn    [TXN_ID_COUNT_C];
  protected bit          done_by_txn        [TXN_ID_COUNT_C];

  // Latency accumulators (cycles).
  protected int unsigned read_count;
  protected longint unsigned read_lat_sum;
  protected int unsigned read_lat_min;
  protected int unsigned read_lat_max;
  protected int unsigned write_count;
  protected longint unsigned write_lat_sum;
  protected int unsigned write_lat_min;
  protected int unsigned write_lat_max;

  // Throughput (completions per window).
  protected int unsigned completions_in_window;
  protected int unsigned windows_closed;
  protected int unsigned peak_completions_per_window;

  // Back-pressure cycle counters (requester tx channels).
  protected int unsigned bp_req_cycles;
  protected int unsigned bp_rsp_cycles;
  protected int unsigned bp_dat_cycles;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent);
    super.new(name, parent);
    this.clear_all();
  endfunction

  protected function void clear_all();
    int unsigned txn_idx;

    this.cycle_count                 = 0;
    this.reset_count                 = 0;
    this.retry_count                 = 0;
    this.read_count                  = 0;
    this.read_lat_sum                = 0;
    this.read_lat_min                = 0;
    this.read_lat_max                = 0;
    this.write_count                 = 0;
    this.write_lat_sum               = 0;
    this.write_lat_min               = 0;
    this.write_lat_max               = 0;
    this.completions_in_window       = 0;
    this.windows_closed              = 0;
    this.peak_completions_per_window = 0;
    this.bp_req_cycles               = 0;
    this.bp_rsp_cycles               = 0;
    this.bp_dat_cycles               = 0;

    for (txn_idx = 0; txn_idx < TXN_ID_COUNT_C; txn_idx++) begin
      this.start_cycle_by_txn[txn_idx] = 0;
      this.start_valid_by_txn[txn_idx] = 1'b0;
      this.is_write_by_txn[txn_idx]    = 1'b0;
      this.done_by_txn[txn_idx]        = 1'b0;
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Allocate the analysis imps used by the shared env.
  // ---------------------------------------------------------------------------
  function void build_phase(input uvm_phase phase);
    super.build_phase(phase);
    this.req_perf = new("req_perf", this);
    this.rsp_perf = new("rsp_perf", this);
    this.dat_perf = new("dat_perf", this);
  endfunction

  protected function int unsigned txn_to_index(input txn_id_t txn_id);
    return txn_id;
  endfunction

  // Classify a request as write vs read from its OPCODE. The monitor does not
  // populate the sequence-side `direction` field on reconstructed items, so that
  // field is unreliable here; the opcode is decoded straight from the flit. The
  // comparison is done in the full-width enum domain: item.opcode is the per-CFG
  // req_opcode_t (only 6 bits on CHI-D), so casting the 7-bit enum constants DOWN
  // to it would truncate WriteNoSnpZero (0x44) onto ReadNoSnp (0x04). Casting
  // item.opcode UP to the 7-bit enum (the coverage idiom) avoids that collision.
  protected function bit req_is_write(input req_opcode_t opcode);
    vip_chi_req_opcode_t wide_op;
    wide_op = vip_chi_req_opcode_t'(opcode);
    return ((wide_op == VIP_CHI_REQ_WRITE_NO_SNP_FULL_E) ||
            (wide_op == VIP_CHI_REQ_WRITE_NO_SNP_PTL_E)  ||
            (wide_op == VIP_CHI_REQ_WRITE_NO_SNP_ZERO_E) ||
            vip_chi_types_pkg::vip_chi_req_opcode_is_atomic(wide_op));
  endfunction

  // ---------------------------------------------------------------------------
  // Clear the in-flight bookkeeping on reset so a post-reset completion is never
  // timed against an abandoned pre-reset request. Aggregates persist across the
  // whole test (they are cumulative).
  // ---------------------------------------------------------------------------
  function void handle_reset();
    int unsigned txn_idx;

    this.reset_count++;
    for (txn_idx = 0; txn_idx < TXN_ID_COUNT_C; txn_idx++) begin
      this.start_valid_by_txn[txn_idx] = 1'b0;
      this.done_by_txn[txn_idx]        = 1'b0;
    end
  endfunction

  protected function void record_latency(input bit is_write, input int unsigned lat);
    if (is_write) begin
      if ((this.write_count == 0) || (lat < this.write_lat_min)) begin
        this.write_lat_min = lat;
      end
      if (lat > this.write_lat_max) begin
        this.write_lat_max = lat;
      end
      this.write_lat_sum += lat;
      this.write_count++;
    end
    else begin
      if ((this.read_count == 0) || (lat < this.read_lat_min)) begin
        this.read_lat_min = lat;
      end
      if (lat > this.read_lat_max) begin
        this.read_lat_max = lat;
      end
      this.read_lat_sum += lat;
      this.read_count++;
    end
    this.completions_in_window++;
  endfunction

  // Retire a transaction (first completion milestone wins).
  protected function void complete_txn(input txn_id_t txn_id);
    int unsigned txn_idx = this.txn_to_index(txn_id);

    if (!this.start_valid_by_txn[txn_idx] || this.done_by_txn[txn_idx]) begin
      return;
    end
    this.done_by_txn[txn_idx] = 1'b1;
    this.record_latency(this.is_write_by_txn[txn_idx],
                        this.cycle_count - this.start_cycle_by_txn[txn_idx]);
  endfunction

  // ---------------------------------------------------------------------------
  // Analysis callbacks: stamp REQ issue, retire on the completion milestone.
  // ---------------------------------------------------------------------------
  function void write_req_perf(input item_t item);
    int unsigned txn_idx;

    if (!this.enable || (item.role != VIP_CHI_ROLE_RNI_E)) begin
      return;
    end
    txn_idx = this.txn_to_index(item.txn_id);
    this.start_cycle_by_txn[txn_idx] = this.cycle_count;
    this.start_valid_by_txn[txn_idx] = 1'b1;
    this.is_write_by_txn[txn_idx]    = this.req_is_write(item.opcode);
    this.done_by_txn[txn_idx]        = 1'b0;
  endfunction

  function void write_rsp_perf(input item_t item);
    if (!this.enable) begin
      return;
    end
    if (item.rsp_opcode == rsp_opcode_t'(VIP_CHI_RSP_RETRY_ACK_E)) begin
      this.retry_count++;
      return;
    end
    // Write completion milestone: first Comp / CompDBIDResp from the completer.
    if ((item.role == VIP_CHI_ROLE_SNF_E) &&
        ((item.rsp_opcode == rsp_opcode_t'(VIP_CHI_RSP_COMP_E)) ||
         (item.rsp_opcode == rsp_opcode_t'(VIP_CHI_RSP_COMP_DBID_RESP_E)))) begin
      this.complete_txn(item.txn_id);
    end
  endfunction

  function void write_dat_perf(input item_t item);
    if (!this.enable) begin
      return;
    end
    // Read completion milestone: CompData / DataSepResp from the completer.
    if ((item.role == VIP_CHI_ROLE_SNF_E) &&
        ((item.dat_opcode == dat_opcode_t'(VIP_CHI_DAT_COMP_DATA_E)) ||
         (item.dat_opcode == dat_opcode_t'(VIP_CHI_DAT_DATA_SEP_RESP_E)))) begin
      this.complete_txn(item.txn_id);
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Deterministic cycle base + throughput windows + back-pressure sampling.
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);
    if (this.vif == null) begin
      return;
    end

    forever begin
      @(this.vif.monitor_cb);

      if (this.vif.rst_n !== 1'b1) begin
        continue;
      end

      this.cycle_count++;

      if ((this.cycle_count % PERF_WINDOW_CYCLES_C) == 0) begin
        if (this.completions_in_window > this.peak_completions_per_window) begin
          this.peak_completions_per_window = this.completions_in_window;
        end
        this.windows_closed++;
        this.completions_in_window = 0;
      end

      if (this.vif.monitor_cb.txreqflitpend && !this.vif.monitor_cb.txreqflitv) begin
        this.bp_req_cycles++;
      end
      if (this.vif.monitor_cb.txrspflitpend && !this.vif.monitor_cb.txrspflitv) begin
        this.bp_rsp_cycles++;
      end
      if (this.vif.monitor_cb.txdatflitpend && !this.vif.monitor_cb.txdatflitv) begin
        this.bp_dat_cycles++;
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  // Public accessors (used by the anti-vacuity smoke test).
  // ---------------------------------------------------------------------------
  function int unsigned get_cycle_count();  return this.cycle_count;  endfunction
  function int unsigned get_read_count();   return this.read_count;   endfunction
  function int unsigned get_write_count();  return this.write_count;  endfunction
  function longint unsigned get_read_lat_sum();  return this.read_lat_sum;  endfunction
  function longint unsigned get_write_lat_sum(); return this.write_lat_sum; endfunction
  function int unsigned get_retry_count();  return this.retry_count;  endfunction
  function int unsigned get_reset_count();  return this.reset_count;  endfunction

  // ---------------------------------------------------------------------------
  // One-line summary at end of test.
  // ---------------------------------------------------------------------------
  function void report_phase(input uvm_phase phase);
    int unsigned total_completions;
    int unsigned read_lat_avg;
    int unsigned write_lat_avg;
    int unsigned avg_per_window;

    super.report_phase(phase);

    if (!this.enable) begin
      return;
    end

    total_completions = this.read_count + this.write_count;
    read_lat_avg  = (this.read_count  != 0) ? int'(this.read_lat_sum  / this.read_count)  : 0;
    write_lat_avg = (this.write_count != 0) ? int'(this.write_lat_sum / this.write_count) : 0;
    avg_per_window = (this.windows_closed != 0) ?
      (total_completions / this.windows_closed) : total_completions;

    `uvm_info(get_name(), $sformatf(
      {"PERF SUMMARY: cycles=%0d resets=%0d | reads=%0d lat(min/avg/max)=%0d/%0d/%0d | ",
       "writes=%0d lat(min/avg/max)=%0d/%0d/%0d | retries=%0d | ",
       "throughput(avg/peak per %0dc)=%0d/%0d | backpressure(req/rsp/dat)=%0d/%0d/%0d"},
      this.cycle_count, this.reset_count,
      this.read_count, this.read_lat_min, read_lat_avg, this.read_lat_max,
      this.write_count, this.write_lat_min, write_lat_avg, this.write_lat_max,
      this.retry_count, PERF_WINDOW_CYCLES_C, avg_per_window, this.peak_completions_per_window,
      this.bp_req_cycles, this.bp_rsp_cycles, this.bp_dat_cycles), UVM_LOW)
  endfunction

endclass
