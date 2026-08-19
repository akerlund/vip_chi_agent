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

`ifndef VIP_CHI_DRIVER_HNF
`define VIP_CHI_DRIVER_HNF

import uvm_pkg::*;
`include "uvm_macros.svh"
import vip_chi_types_pkg::*;
import vip_mem_types_pkg::*;
import vip_memory_pkg::*;

// -----------------------------------------------------------------------------
// Coherent home node (HN-F). Multi-RN-F fan-in home that TERMINATES requests
// against its own memory + directory (there is no SN behind it in this cut):
//
//   RN-F[0..N_RNF_PORTS-1]  <==(RN-facing, HNF polarity)==>  HN-F  ->  vip_mem
//
// It is a NEW stateful component rather than a subclass: it must straddle every
// RN-F link at once (to originate snoops toward the other sharers in M3), which
// the single-link SN-F driver cannot do. It reuses the proven multi-port
// credit/capture STRUCTURE of vip_chi_driver_hni and the vip_mem backing store
// of vip_chi_driver_snf, but the response side terminates instead of relaying.
//
// Anti-deadlock discipline (same as HN-I): each per-port capture thread drains
// the REQ channel and returns its credit immediately, buffering the request; the
// response engine only ever waits on its own send-credit counters, never on a
// raw rxflitv it has not already captured. So no channel can back-pressure into
// a wedge.
//
// M2 scope: coherent READS only, no snoops. The directory records ownership as
// each read completes (so M3 can consult it to originate snoops), but no snoop
// is ever driven yet. Writeback/Evict/MakeUnique + snoop origination are M3/M4.
// -----------------------------------------------------------------------------
class vip_chi_driver_hnf #(
  vip_chi_cfg_t  CFG_P        = VIP_CHI_DEFAULT_CFG_C,
  type           FLIT_TYPES_T = vip_chi_types #(CFG_P),
  int            N_RNF_PORTS  = 1,
  int            N_SN_PORTS   = 0
  ) extends uvm_component;

  localparam int DATA_WIDTH_C = CFG_P.DATA_BYTES_P * 8;

  // SN-facing arrays are sized >= 1 to avoid a zero-size unpacked array when the
  // downstream feature is compiled out (N_SN_PORTS=0); every SN access is guarded
  // by (N_SN_PORTS > 0), so the extra dormant slot is never touched. Plain int
  // localparam (package-scope-safe; not a parameterized-class-nested type).
  localparam int SN_ARR_C = (N_SN_PORTS > 0) ? N_SN_PORTS : 1;

  localparam vip_mem_cfg_t MEM_C = '{
    ADDR_WIDTH_P  : CFG_P.ADDR_WIDTH_P,
    WDATA_BYTES_P : CFG_P.DATA_BYTES_P,
    RDATA_BYTES_P : CFG_P.DATA_BYTES_P,
    ROW_BYTES_P   : CFG_P.DATA_BYTES_P
  };

  typedef vip_chi_item #(CFG_P)                item_t;
  typedef vip_chi_types #(CFG_P)::node_id_t    node_id_t;
  typedef vip_chi_types #(CFG_P)::addr_t       addr_t;
  typedef vip_chi_types #(CFG_P)::txn_id_t     txn_id_t;
  typedef vip_chi_types #(CFG_P)::data_t       data_t;
  typedef vip_chi_types #(CFG_P)::be_t         be_t;
  typedef vip_chi_types #(CFG_P)::data_id_t    data_id_t;
  typedef vip_chi_types #(CFG_P)::cc_id_t      cc_id_t;
  typedef vip_chi_types #(CFG_P)::size_t       size_t;
  typedef vip_chi_types #(CFG_P)::req_opcode_t req_opcode_t;
  typedef vip_chi_types #(CFG_P)::rsp_opcode_t rsp_opcode_t;
  typedef vip_chi_types #(CFG_P)::dat_opcode_t dat_opcode_t;
  typedef FLIT_TYPES_T::vip_chi_req_flit_t     req_flit_t;
  typedef FLIT_TYPES_T::vip_chi_dat_flit_t     dat_flit_t;
  typedef FLIT_TYPES_T::vip_chi_rsp_flit_t     rsp_flit_t;
  typedef FLIT_TYPES_T::vip_chi_snp_flit_t     snp_flit_t;
  typedef FLIT_TYPES_T::snp_opcode_t           snp_opcode_t;

  // RN-facing interfaces (completer, HNF polarity via hnf_cb), one per RN-F.
  virtual vip_chi_if #(CFG_P, FLIT_TYPES_T, VIP_CHI_ROLE_HNF_E) vif_rn [N_RNF_PORTS];
  vip_chi_cfg_agent                                            cfg;

  // Backing store the home terminates reads/writes against (verbatim SN-F form).
  vip_mem #(MEM_C)     mem;
  protected bit        mem_row_written [longint];

  // Coherence directory, keyed by line-aligned address: the coherent state held
  // by each RN-F port, packed 3 bits per port ('0 == every port Invalid). A
  // missing key means the line is uncached everywhere. Consulted on each read to
  // decide which other sharers to snoop, and updated as reads/snoops resolve.
  protected logic [N_RNF_PORTS-1:0][2:0] directory [addr_t];

  // Exclusive (LL/SC) monitor, one bit per RN-F port, keyed line-aligned exactly
  // like `directory`. A set bit means that port holds a valid exclusive
  // reservation on the line taken by an exclusive load (ReadShared/ReadClean with
  // excl=1). It is CLEARED by any conflicting store/invalidate to the line (the
  // HN-F's own snoop-invalidate, a WriteBack, a WriteUnique, a CMO invalidate, or
  // a successful CleanUnique) and CONSUMED by the exclusive store (CleanUnique+excl)
  // it gates. A packed bit-vector (not an assoc-of-struct) to sidestep the VCS
  // assoc-of-dynarray quirk noted in vip_chi_driver_rnf.sv.
  protected logic [N_RNF_PORTS-1:0] excl_monitor [addr_t];

  // Rolling TxnID stamped on originated snoops (echoed back in the SnpResp).
  protected txn_id_t snp_txn_ctr;

  // Per-RN send-side budgets (HN-F -> RN-F): RSP/DAT completions + SNP snoops.
  protected vip_chi_lcrd_mgr rn_rsp_send_mgr [N_RNF_PORTS];
  protected vip_chi_lcrd_mgr rn_dat_send_mgr [N_RNF_PORTS];
  protected vip_chi_lcrd_mgr rn_snp_send_mgr [N_RNF_PORTS];

  // Per-RN inbound receive-credit grants advertised on the wire.
  protected int unsigned rn_req_lcrdv_pending [N_RNF_PORTS];
  protected int unsigned rn_rsp_lcrdv_pending [N_RNF_PORTS];
  protected int unsigned rn_dat_lcrdv_pending [N_RNF_PORTS];

  protected bit rn_link_up [N_RNF_PORTS];

  // One-shot latch per RN port for cfg.flitpend_without_valid: the control fires
  // once per link so the count a test asserts on is unambiguous.
  protected bit rn_flitpend_negctl_done [N_RNF_PORTS];

  // -------------------------------------------------------------------------
  // Downstream SN-facing side (requester polarity, RN-I role), present only when
  // N_SN_PORTS>0 and activated only when cfg.hnf_downstream_en. Mirrors the HN-I
  // SN-facing set. Dormant (declared but untouched) when the feature is off.
  // -------------------------------------------------------------------------
  virtual vip_chi_if #(CFG_P, FLIT_TYPES_T, VIP_CHI_ROLE_RNI_E) vif_sn [SN_ARR_C];

  // Per-SN send-side budgets (HN-F -> SN, requester).
  protected vip_chi_lcrd_mgr sn_req_send_mgr [SN_ARR_C];
  protected vip_chi_lcrd_mgr sn_rsp_send_mgr [SN_ARR_C];
  protected vip_chi_lcrd_mgr sn_dat_send_mgr [SN_ARR_C];

  // Per-SN inbound receive-credit grants advertised on the wire.
  protected int unsigned sn_rsp_lcrdv_pending [SN_ARR_C];
  protected int unsigned sn_dat_lcrdv_pending [SN_ARR_C];

  protected bit sn_link_up [SN_ARR_C];

  // Rolling downstream TxnID + single-outstanding completion capture (filled by
  // the independent SN capture threads, drained by the blocking downstream
  // helpers). The downstream link runs one transaction at a time, so a single
  // shared capture buffer + ready flag is sufficient (no TxnID keying needed).
  protected txn_id_t          dn_txn_ctr;
  protected data_t            dn_dat_beats [$];   // captured CompData / read beats
  protected vip_chi_resp_err_t dn_dat_resperr;    // last CompData beat's RespErr
  protected bit               dn_dat_valid;       // a full CompData burst captured
  protected rsp_flit_t        dn_rsp_q [$];       // captured downstream RSP flits

  // Captured-REQ work queue drained by the single response engine.
  typedef struct {
    int        port;
    req_flit_t flit;
  } hnf_work_t;
  protected hnf_work_t work_q [$];

  `uvm_component_param_utils(vip_chi_driver_hnf #(CFG_P, FLIT_TYPES_T, N_RNF_PORTS, N_SN_PORTS))

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent);
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  // Validate parent-assigned handles: RN-facing vifs on "rn_vif_<i>".
  // ---------------------------------------------------------------------------
  function void build_phase(input uvm_phase phase);
    super.build_phase(phase);

    foreach (this.vif_rn[i]) begin
      if (!uvm_config_db #(virtual vip_chi_if #(CFG_P, FLIT_TYPES_T, VIP_CHI_ROLE_HNF_E))::get(
            this, "", $sformatf("rn_vif_%0d", i), this.vif_rn[i])) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] RN-facing driver.rn_vif_%0d must be assigned by the parent",
          get_name(), i))
      end
    end

    // SN-facing vifs are fetched only for real downstream ports (never the dormant
    // SN_ARR_C padding slot). The parent must provide them whenever N_SN_PORTS>0.
    for (int s = 0; s < N_SN_PORTS; s++) begin
      if (!uvm_config_db #(virtual vip_chi_if #(CFG_P, FLIT_TYPES_T, VIP_CHI_ROLE_RNI_E))::get(
            this, "", $sformatf("sn_vif_%0d", s), this.vif_sn[s])) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] SN-facing driver.sn_vif_%0d must be assigned by the parent",
          get_name(), s))
      end
    end

    if (this.cfg == null) begin
      this.cfg      = vip_chi_cfg_agent::type_id::create("default_cfg");
      this.cfg.role = VIP_CHI_ROLE_HNF_E;
    end

    this.mem = new("mem");
    this.mem.cfg = this.cfg.mem_cfg;
    this.mem.reset();
    this.mem.set_addr_width(CFG_P.ADDR_WIDTH_P);
    this.reset_credit_state();
  endfunction

  // ---------------------------------------------------------------------------
  // (Re)build the credit managers and clear the inbound grant queues + state.
  // ---------------------------------------------------------------------------
  protected function void reset_credit_state();
    foreach (this.vif_rn[i]) begin
      if (this.rn_rsp_send_mgr[i] == null) begin
        this.rn_rsp_send_mgr[i] = vip_chi_lcrd_mgr::type_id::create($sformatf("rn_rsp_send_mgr_%0d", i));
      end
      if (this.rn_dat_send_mgr[i] == null) begin
        this.rn_dat_send_mgr[i] = vip_chi_lcrd_mgr::type_id::create($sformatf("rn_dat_send_mgr_%0d", i));
      end
      if (this.rn_snp_send_mgr[i] == null) begin
        this.rn_snp_send_mgr[i] = vip_chi_lcrd_mgr::type_id::create($sformatf("rn_snp_send_mgr_%0d", i));
      end

      this.rn_rsp_send_mgr[i].reset(this.cfg.rsp_send_credit_cap, 0);
      this.rn_dat_send_mgr[i].reset(this.cfg.dat_send_credit_cap, 0);
      this.rn_snp_send_mgr[i].reset(this.cfg.snp_send_credit_cap, 0);

      this.rn_req_lcrdv_pending[i] = 0;
      this.rn_rsp_lcrdv_pending[i] = 0;
      this.rn_dat_lcrdv_pending[i] = 0;
      this.rn_link_up[i]           = 1'b0;
      this.rn_flitpend_negctl_done[i] = 1'b0;
    end

    // Downstream SN-facing send managers + grant queues (real ports only).
    for (int s = 0; s < N_SN_PORTS; s++) begin
      if (this.sn_req_send_mgr[s] == null) begin
        this.sn_req_send_mgr[s] = vip_chi_lcrd_mgr::type_id::create($sformatf("sn_req_send_mgr_%0d", s));
      end
      if (this.sn_rsp_send_mgr[s] == null) begin
        this.sn_rsp_send_mgr[s] = vip_chi_lcrd_mgr::type_id::create($sformatf("sn_rsp_send_mgr_%0d", s));
      end
      if (this.sn_dat_send_mgr[s] == null) begin
        this.sn_dat_send_mgr[s] = vip_chi_lcrd_mgr::type_id::create($sformatf("sn_dat_send_mgr_%0d", s));
      end
      this.sn_req_send_mgr[s].reset(this.cfg.req_send_credit_cap, 0);
      this.sn_rsp_send_mgr[s].reset(this.cfg.rsp_send_credit_cap, 0);
      this.sn_dat_send_mgr[s].reset(this.cfg.dat_send_credit_cap, 0);
      this.sn_rsp_lcrdv_pending[s] = 0;
      this.sn_dat_lcrdv_pending[s] = 0;
      this.sn_link_up[s]           = 1'b0;
    end

    this.work_q.delete();
    this.directory.delete();
    this.excl_monitor.delete();
    this.snp_txn_ctr = '0;
    this.dn_txn_ctr  = '0;
  endfunction

  // ---------------------------------------------------------------------------
  // Idle sideband (mirror the RN-F's link-activation request onto our ack).
  // ---------------------------------------------------------------------------
  // Which channel the announce tasks are announcing on. Local to the drivers:
  // it names a clocking-block member to assign, not anything on the wire.
  typedef enum {
    ANNOUNCE_REQ_E,
    ANNOUNCE_RSP_E,
    ANNOUNCE_DAT_E,
    ANNOUNCE_SNP_E
  } announce_ch_t;

  protected task drive_rn_idle_sideband(input int p);
    this.vif_rn[p].g_drv.hnf_cb.txlinkactiveack <= this.vif_rn[p].g_drv.hnf_cb.rxlinkactivereq;
  endtask

  // ---------------------------------------------------------------------------
  // Drive every home output back to the idle state.
  // ---------------------------------------------------------------------------
  protected function void reset_outputs();
    foreach (this.vif_rn[p]) begin
      this.vif_rn[p].g_drv.hnf_cb.txlinkactivereq <= 1'b0;
      this.vif_rn[p].g_drv.hnf_cb.txlinkactiveack <= 1'b0;
      this.vif_rn[p].g_drv.hnf_cb.txsactive       <= 1'b0;
      this.vif_rn[p].g_drv.hnf_cb.txreqlcrdv      <= 1'b0;
      this.vif_rn[p].g_drv.hnf_cb.txrspflitpend   <= 1'b0;
      this.vif_rn[p].g_drv.hnf_cb.txrspflitv      <= 1'b0;
      this.vif_rn[p].g_drv.hnf_cb.txrspflit       <= '0;
      this.vif_rn[p].g_drv.hnf_cb.txrsplcrdv      <= 1'b0;
      this.vif_rn[p].g_drv.hnf_cb.txdatflitpend   <= 1'b0;
      this.vif_rn[p].g_drv.hnf_cb.txdatflitv      <= 1'b0;
      this.vif_rn[p].g_drv.hnf_cb.txdatflit       <= '0;
      this.vif_rn[p].g_drv.hnf_cb.txdatlcrdv      <= 1'b0;
      // SNP source side idles until M3 originates snoops.
      this.vif_rn[p].g_drv.hnf_cb.txsnpflitpend   <= 1'b0;
      this.vif_rn[p].g_drv.hnf_cb.txsnpflitv      <= 1'b0;
      this.vif_rn[p].g_drv.hnf_cb.txsnpflit       <= '0;
    end

    // Downstream SN-facing (requester, rni_cb) outputs idle -- driven to a known
    // 0 even when the downstream feature is off, so the unused link never floats
    // X into the (idle) SN-F. Mirrors the HN-I SN-side idle set.
    for (int s = 0; s < N_SN_PORTS; s++) begin
      this.vif_sn[s].g_drv.rni_cb.txlinkactivereq <= 1'b0;
      this.vif_sn[s].g_drv.rni_cb.txlinkactiveack <= 1'b0;
      this.vif_sn[s].g_drv.rni_cb.txsactive       <= 1'b0;
      this.vif_sn[s].g_drv.rni_cb.txreqflitpend   <= 1'b0;
      this.vif_sn[s].g_drv.rni_cb.txreqflitv      <= 1'b0;
      this.vif_sn[s].g_drv.rni_cb.txreqflit       <= '0;
      this.vif_sn[s].g_drv.rni_cb.txrspflitpend   <= 1'b0;
      this.vif_sn[s].g_drv.rni_cb.txrspflitv      <= 1'b0;
      this.vif_sn[s].g_drv.rni_cb.txrspflit       <= '0;
      this.vif_sn[s].g_drv.rni_cb.txrsplcrdv      <= 1'b0;
      this.vif_sn[s].g_drv.rni_cb.txdatflitpend   <= 1'b0;
      this.vif_sn[s].g_drv.rni_cb.txdatflitv      <= 1'b0;
      this.vif_sn[s].g_drv.rni_cb.txdatflit       <= '0;
      this.vif_sn[s].g_drv.rni_cb.txdatlcrdv      <= 1'b0;
    end

    if (this.mem != null) begin
      this.mem.reset();
    end
    this.mem_row_written.delete();
  endfunction

  // ---------------------------------------------------------------------------
  // Public reset hooks driven by the parent's all-links rst_n watcher.
  // ---------------------------------------------------------------------------
  function void reset_vif();
    this.reset_outputs();
  endfunction

  function void handle_reset();
    this.reset_credit_state();
    this.reset_outputs();
  endfunction

  // ---------------------------------------------------------------------------
  // run_phase is intentionally empty: the parent agent owns the rst_n watcher.
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);
  endtask

  // ---------------------------------------------------------------------------
  // Backing-store helpers (verbatim SN-F semantics).
  // ---------------------------------------------------------------------------
  protected function longint row_index_from_addr(input addr_t addr);
    return unsigned'(addr) / MEM_C.ROW_BYTES_P;
  endfunction

  protected function bit has_backing_row(input addr_t addr);
    return this.mem_row_written.exists(this.row_index_from_addr(addr));
  endfunction

  protected function void mark_backing_row(input addr_t addr);
    this.mem_row_written[this.row_index_from_addr(addr)] = 1'b1;
  endfunction

  protected function data_t auto_read_data(input addr_t addr, input int beat_index);
    return data_t'(addr) + data_t'(beat_index);
  endfunction

  protected function data_t read_data_beat(input addr_t addr, input int beat_index);
    addr_t                          beat_addr;
    logic [MEM_C.ROW_BYTES_P*8-1:0] mem_row;

    beat_addr = addr + addr_t'(beat_index * CFG_P.DATA_BYTES_P);
    if (this.has_backing_row(beat_addr)) begin
      mem_row = this.mem.rd_addr(beat_addr);
      return data_t'(mem_row);
    end
    return this.auto_read_data(addr, beat_index);
  endfunction

  // ---------------------------------------------------------------------------
  // Back the whole cache line in memory with its current read image before a
  // sub-beat partial write. read_data_beat already returns the real value for
  // backed beats and the synthesized pattern for unbacked ones, so writing that
  // image back (all byte-enables) is idempotent for backed rows and materializes
  // the synthesized value for unbacked rows. Without this, a WriteUniquePtl that
  // touches only some lanes of an unbacked beat (e.g. a 16 B write inside a 64 B
  // CHI-E beat) would let vip_mem::wr_be zero-fill the untouched lanes instead of
  // preserving the pre-write value the RN observed on its ReadShared.
  // ---------------------------------------------------------------------------
  protected function void backfill_line_image(input addr_t line);
    int    line_beats;
    data_t beats [$];
    be_t   be    [$];

    line_beats = VIP_CHI_CACHE_LINE_BYTES_C / CFG_P.DATA_BYTES_P;
    for (int b = 0; b < line_beats; b++) begin
      beats.push_back(this.read_data_beat(line, b));
      be.push_back('1);
    end
    this.mem.wr_be(line, beats, be);
    for (int b = 0; b < line_beats; b++) begin
      this.mark_backing_row(line + addr_t'(b * CFG_P.DATA_BYTES_P));
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Line-align an address to the 64 B coherence granule
  // (VIP_CHI_CACHE_LINE_BYTES_C), not the data-bus width, so every access and
  // snoop for one cache line resolves to a single directory entry even on a
  // narrow bus where a line spans multiple beats (P1).
  // ---------------------------------------------------------------------------
  protected function addr_t line_addr(input addr_t addr);
    return addr & ~addr_t'(VIP_CHI_CACHE_LINE_BYTES_C - 1);
  endfunction

  // ---------------------------------------------------------------------------
  // Coherent-read classification + the state the home grants for it.
  // ---------------------------------------------------------------------------
  protected function bit req_opcode_is_coherent_read(input req_opcode_t opcode);
    // MakeReadUnique shares the ReadUnique home flow (invalidate other holders,
    // then grant CompData in the unique state). It is a CHI-E 7-bit opcode
    // (0x41), so it is matched in the WIDE opcode domain -- a narrow (CHI-D)
    // req_opcode_t cannot hold 0x41 and would alias it onto ReadShared (0x01).
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

  // A coherent read that grants Unique ownership (invalidates every other
  // holder). Compared in the WIDE opcode domain so MakeReadUnique's 7-bit 0x41
  // never aliases a narrow CHI-D opcode (which would mis-classify ReadShared).
  protected function bit req_opcode_is_unique_read(input req_opcode_t opcode);
    vip_chi_req_opcode_t wop;
    wop = vip_chi_req_opcode_t'(opcode);
    return (wop == VIP_CHI_REQ_READ_UNIQUE_E) ||
           (wop == VIP_CHI_REQ_MAKE_READ_UNIQUE_E);
  endfunction

  // ---------------------------------------------------------------------------
  // The snoop this home sends for a request, from IHI 0050 E Table 4-5 / D Table
  // 4-3 by way of vip_chi_snoop_for_req. Every snoop this driver originates goes
  // through here, so the request->snoop correspondence lives in one table
  // instead of being spelled out at nine call sites.
  //
  // It replaced a single is_unique bit, and a bit cannot express Table 4-5: the
  // table has a distinct row per request and this home had two. ReadClean took
  // the not-unique branch and was snooped as though it were a ReadShared.
  //
  // `fwd` selects the Direct Cache Transfer column, which is where the actual
  // violation was -- SnpShared for a ReadClean is permitted by the bullet under
  // the table, SnpSharedFwd is not, and the DCT path could hand the requester a
  // forwarded CompData_SD_PD that Table 4-14 does not list for ReadClean.
  // ---------------------------------------------------------------------------
  protected function snp_opcode_t snoop_for(input req_opcode_t opcode,
                                            input bit          fwd = 1'b0);
    // Negative-control hook: put ReadClean back on the shared branch the
    // is_unique bit used to send it down. SnpShared is legal for a ReadClean and
    // SnpSharedFwd is not, so the SAME knob gives catalogue rule D8 one case it
    // must pass and one it must fail.
    if (this.cfg.hnf_snoop_shared_for_read_clean &&
        (vip_chi_req_opcode_t'(opcode) == VIP_CHI_REQ_READ_CLEAN_E)) begin
      return fwd ? snp_opcode_t'(VIP_CHI_SNP_SHARED_FWD_C)
                 : snp_opcode_t'(VIP_CHI_SNP_SHARED_C);
    end
    return snp_opcode_t'(vip_chi_snoop_for_req(vip_chi_req_opcode_t'(opcode), fwd));
  endfunction

  protected function vip_chi_resp_t granted_state_for(input req_opcode_t opcode);
    if (this.req_opcode_is_unique_read(opcode)) begin
      return this.cfg.coh_read_unique_state;
    end
    // ReadShared / ReadClean land the requester in the shared/clean state.
    return this.cfg.coh_read_shared_state;
  endfunction

  // ---------------------------------------------------------------------------
  // Main home loop: response engine + per-RN credit/activate/capture threads.
  // ---------------------------------------------------------------------------
  task driver_start();
    fork
      this.response_engine();
    join_none

    for (int p = 0; p < N_RNF_PORTS; p++) begin
      automatic int lp = p;
      fork
        this.rn_credit_loop(lp);
        this.rn_activate(lp);
        this.capture_req(lp);
      join_none
    end

    // Downstream SN-facing requester threads -- only when a real SN port exists
    // AND the two-level hierarchy is enabled. Off by default => the HN-F stays a
    // pure self-terminating home and the SN link idles.
    if ((N_SN_PORTS > 0) && this.cfg.hnf_downstream_en) begin
      for (int s = 0; s < N_SN_PORTS; s++) begin
        automatic int ls = s;
        fork
          this.sn_credit_loop(ls);
          this.sn_activate(ls);
          this.sn_capture_dat(ls);
          this.sn_capture_rsp(ls);
        join_none
      end
    end

    // Hold this task alive; the parent disables the fork on reset.
    forever begin
      @(this.vif_rn[0].g_drv.hnf_cb);
    end
  endtask

  // ---------------------------------------------------------------------------
  // Per-RN credit/link loop. Advertises the queued receive credits, tracks the
  // RN-F's returned send credits, and keeps the sideband coherent.
  // ---------------------------------------------------------------------------
  protected task rn_credit_loop(input int p);
    forever begin
      @(this.vif_rn[p].g_drv.hnf_cb);

      this.drive_rn_idle_sideband(p);

      this.vif_rn[p].g_drv.hnf_cb.txsactive  <= this.rn_link_up[p];
      this.vif_rn[p].g_drv.hnf_cb.txreqlcrdv <= (this.rn_req_lcrdv_pending[p] != 0);
      this.vif_rn[p].g_drv.hnf_cb.txrsplcrdv <= (this.rn_rsp_lcrdv_pending[p] != 0);
      this.vif_rn[p].g_drv.hnf_cb.txdatlcrdv <= (this.rn_dat_lcrdv_pending[p] != 0);

      if (this.rn_req_lcrdv_pending[p] != 0) begin
        this.rn_req_lcrdv_pending[p]--;
      end
      if (this.rn_rsp_lcrdv_pending[p] != 0) begin
        this.rn_rsp_lcrdv_pending[p]--;
      end
      if (this.rn_dat_lcrdv_pending[p] != 0) begin
        this.rn_dat_lcrdv_pending[p]--;
      end

      if (this.vif_rn[p].g_drv.hnf_cb.rxrsplcrdv) begin
        this.rn_rsp_send_mgr[p].return_credit();
      end
      if (this.vif_rn[p].g_drv.hnf_cb.rxdatlcrdv) begin
        this.rn_dat_send_mgr[p].return_credit();
      end
      // SNP send credit from the RN-F (consumed once M3 originates snoops).
      if (this.vif_rn[p].g_drv.hnf_cb.rxsnplcrdv) begin
        this.rn_snp_send_mgr[p].return_credit();
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  // Wait for the RN-F to activate the link, then advertise the initial receive
  // credits for every channel the home consumes (REQ + RSP + DAT).
  // ---------------------------------------------------------------------------
  protected task rn_activate(input int p);
    do begin
      @(this.vif_rn[p].g_drv.hnf_cb);
    end while (this.vif_rn[p].rst_n && !this.vif_rn[p].g_drv.hnf_cb.rxlinkactivereq);

    this.rn_req_lcrdv_pending[p] += this.cfg.initial_req_credits;
    this.rn_rsp_lcrdv_pending[p] += this.cfg.initial_rsp_credits;
    this.rn_dat_lcrdv_pending[p] += this.cfg.initial_dat_credits;
    this.rn_link_up[p] = 1'b1;
    this.drive_snp_flitpend_negctl(p);
  endtask

  // ---------------------------------------------------------------------------
  // Negative control (cfg.flitpend_without_valid): raise SNP FLITPEND for one
  // cycle with no snoop behind it.
  //
  // The SNP twin of the REQ/RSP pulse in the requester driver, and it exists for
  // the same reason: CHI_SNP_VALID_REQUIRES_PEND had never once been evaluated
  // anywhere, because nothing raises SNP FLITPEND -- the home pairs it with the
  // snoop it belongs to. A rule that has never run is indistinguishable from one
  // that does not work.
  //
  // Emitted here, once per link, with the link up and before any snoop, so the
  // rule has exactly one lone FLITPEND to report and nothing else on the wire
  // can be confused for it.
  // ---------------------------------------------------------------------------
  protected task drive_snp_flitpend_negctl(input int p);

    if (!this.cfg.flitpend_without_valid || this.rn_flitpend_negctl_done[p]) begin
      return;
    end
    this.rn_flitpend_negctl_done[p] = 1'b1;

    @(this.vif_rn[p].g_drv.hnf_cb);
    this.drive_rn_idle_sideband(p);
    this.vif_rn[p].g_drv.hnf_cb.txsnpflitpend <= 1'b1;

    @(this.vif_rn[p].g_drv.hnf_cb);
    this.drive_rn_idle_sideband(p);
    this.vif_rn[p].g_drv.hnf_cb.txsnpflitpend <= 1'b0;
  endtask

  // ---------------------------------------------------------------------------
  // Per-RN REQ ingress capture. Latches the REQ, returns its credit at once
  // (so the RN-F is free to issue again), and enqueues it for the engine.
  // ---------------------------------------------------------------------------
  protected task capture_req(input int p);
    forever begin
      while (!this.vif_rn[p].g_drv.hnf_cb.rxreqflitv) begin
        @(this.vif_rn[p].g_drv.hnf_cb);
      end

      this.work_q.push_back('{port: p, flit: this.vif_rn[p].g_drv.hnf_cb.rxreqflit});
      this.rn_req_lcrdv_pending[p] += 1;

      // Step off the accepted REQ beat before sampling for the next one.
      @(this.vif_rn[p].g_drv.hnf_cb);
    end
  endtask

  // ===========================================================================
  // Downstream SN-facing requester engine (active only when N_SN_PORTS>0 and
  // cfg.hnf_downstream_en). The HN-F acts as an RN-I-style requester toward a
  // real SN-F memory node -- ReadNoSnp/WriteNoSnpFull. Completions are captured
  // on INDEPENDENT threads into a single-outstanding buffer, so the serial
  // response_engine can block on a captured completion (dn_dat_valid) without
  // sampling a raw rxflitv or starving credit -- the same anti-deadlock
  // discipline as the blocking collect_snp_response / HN-I active_busy wait.
  // ===========================================================================

  // Mirror the SN's link-activation request onto our ack (bidirectional bring-up).
  protected task drive_sn_idle_sideband(input int s);
    this.vif_sn[s].g_drv.rni_cb.txlinkactiveack <= this.vif_sn[s].g_drv.rni_cb.rxlinkactivereq;
  endtask

  // Per-SN credit/link loop: advertise our RSP/DAT receive credits to the SN and
  // track the SN's returned REQ/RSP/DAT send credits. Owns txsactive + the
  // *lcrdv grant lines (disjoint from the REQ-drive signals downstream_read uses).
  protected task sn_credit_loop(input int s);
    forever begin
      @(this.vif_sn[s].g_drv.rni_cb);
      this.drive_sn_idle_sideband(s);
      this.vif_sn[s].g_drv.rni_cb.txsactive  <= this.sn_link_up[s];
      this.vif_sn[s].g_drv.rni_cb.txrsplcrdv <= (this.sn_rsp_lcrdv_pending[s] != 0);
      this.vif_sn[s].g_drv.rni_cb.txdatlcrdv <= (this.sn_dat_lcrdv_pending[s] != 0);
      if (this.sn_rsp_lcrdv_pending[s] != 0) begin
        this.sn_rsp_lcrdv_pending[s]--;
      end
      if (this.sn_dat_lcrdv_pending[s] != 0) begin
        this.sn_dat_lcrdv_pending[s]--;
      end
      if (this.vif_sn[s].g_drv.rni_cb.rxreqlcrdv) begin
        this.sn_req_send_mgr[s].return_credit();
      end
      if (this.vif_sn[s].g_drv.rni_cb.rxrsplcrdv) begin
        this.sn_rsp_send_mgr[s].return_credit();
      end
      if (this.vif_sn[s].g_drv.rni_cb.rxdatlcrdv) begin
        this.sn_dat_send_mgr[s].return_credit();
      end
    end
  endtask

  // Bring up the SN link as requester, then grant initial RSP/DAT receive credits.
  protected task sn_activate(input int s);
    @(this.vif_sn[s].g_drv.rni_cb);
    this.vif_sn[s].g_drv.rni_cb.txlinkactivereq <= 1'b1;
    do begin
      @(this.vif_sn[s].g_drv.rni_cb);
    end while (this.vif_sn[s].rst_n && !this.vif_sn[s].g_drv.rni_cb.rxlinkactiveack);
    this.sn_rsp_lcrdv_pending[s] += this.cfg.initial_rsp_credits;
    this.sn_dat_lcrdv_pending[s] += this.cfg.initial_dat_credits;
    this.sn_link_up[s] = 1'b1;
  endtask

  // Capture an inbound CompData / read-data burst from the SN into dn_dat_beats,
  // returning one DAT receive credit per beat, and raise dn_dat_valid on the last.
  protected task sn_capture_dat(input int s);
    dat_flit_t flit;
    bit        last;
    forever begin
      while (!this.vif_sn[s].g_drv.rni_cb.rxdatflitv) begin
        @(this.vif_sn[s].g_drv.rni_cb);
      end
      this.dn_dat_beats.delete();
      forever begin
        flit = this.vif_sn[s].g_drv.rni_cb.rxdatflit;
        this.sn_dat_lcrdv_pending[s] += 1;   // return one DAT receive credit
        this.dn_dat_beats.push_back(data_t'(flit.data));
        this.dn_dat_resperr = vip_chi_resp_err_t'(flit.resperr);
        last = !this.vif_sn[s].g_drv.rni_cb.rxdatflitpend;
        @(this.vif_sn[s].g_drv.rni_cb);
        if (last) begin
          break;
        end
        while (!this.vif_sn[s].g_drv.rni_cb.rxdatflitv) begin
          @(this.vif_sn[s].g_drv.rni_cb);
        end
      end
      this.dn_dat_valid = 1'b1;
    end
  endtask

  // Capture inbound RSP flits from the SN (DBIDResp / Comp for writes), returning
  // one RSP receive credit each, into dn_rsp_q for the blocking write helper.
  protected task sn_capture_rsp(input int s);
    rsp_flit_t flit;
    forever begin
      while (!this.vif_sn[s].g_drv.rni_cb.rxrspflitv) begin
        @(this.vif_sn[s].g_drv.rni_cb);
      end
      flit = this.vif_sn[s].g_drv.rni_cb.rxrspflit;
      this.sn_rsp_lcrdv_pending[s] += 1;
      this.dn_rsp_q.push_back(flit);
      @(this.vif_sn[s].g_drv.rni_cb);
    end
  endtask

  // Allocate the next downstream TxnID (single-outstanding, small rolling pool).
  protected function txn_id_t alloc_dn_txn();
    txn_id_t t;
    t = this.dn_txn_ctr;
    this.dn_txn_ctr = txn_id_t'(this.dn_txn_ctr + txn_id_t'(1));
    return t;
  endfunction

  // Acquire one outbound REQ send credit for the SN link.
  // Each of these holds the flit for its channel's configured transmit delay
  // before taking the credit. See the RN-I twin for why the delay lands before
  // the credit and why L-credit returns are excluded.
  //
  // wait_rn_snp_send_credit is deliberately NOT delayed: there is no
  // snp_valid_delay knob, and inventing one here would put a shape on the snoop
  // channel that no configuration can see or turn off.
  protected task wait_sn_req_send_credit(input int s);
    repeat (this.cfg.draw_req_valid_delay()) begin
      @(this.vif_sn[s].g_drv.rni_cb);
    end
    forever begin
      if (this.sn_req_send_mgr[s].try_acquire_credit()) begin
        break;
      end
      @(this.vif_sn[s].g_drv.rni_cb);
    end
  endtask

  // Blocking downstream ReadNoSnp toward SN port 0: drive the REQ and wait for
  // the captured CompData burst. Returns the fetched beats. Called from the
  // serial response_engine; it blocks ONLY on dn_dat_valid (raised by the
  // independent sn_capture_dat thread), never on a raw rxflitv.
  protected task downstream_read(input addr_t addr, input size_t size, output data_t beats [$]);
    req_flit_t flit;
    int        s;

    s = 0;
    this.dn_dat_valid = 1'b0;
    this.dn_dat_beats.delete();

    flit        = '0;
    flit.opcode = req_opcode_t'(VIP_CHI_REQ_READ_NO_SNP_C);
    flit.addr   = addr;
    flit.size   = size;
    flit.txnid  = this.alloc_dn_txn();
    flit.srcid  = node_id_t'(0);                                // HN-F is the requester
    flit.tgtid  = node_id_t'(this.cfg.hnf_downstream_snf_id);   // SN-F target

    this.wait_sn_req_send_credit(s);
    this.announce_sn_flit(s, ANNOUNCE_REQ_E);
    @(this.vif_sn[s].g_drv.rni_cb);
    this.vif_sn[s].g_drv.rni_cb.txreqflitpend <= 1'b0;
    this.vif_sn[s].g_drv.rni_cb.txreqflit     <= flit;
    this.vif_sn[s].g_drv.rni_cb.txreqflitv    <= 1'b1;
    @(this.vif_sn[s].g_drv.rni_cb);
    this.vif_sn[s].g_drv.rni_cb.txreqflitv    <= 1'b0;
    this.vif_sn[s].g_drv.rni_cb.txreqflit     <= '0;

    while (!this.dn_dat_valid) begin
      @(this.vif_sn[s].g_drv.rni_cb);
    end
    beats = this.dn_dat_beats;
  endtask

  // Acquire one outbound DAT send credit for the SN link (granted by the SN-F).
  protected task wait_sn_dat_send_credit(input int s);
    repeat (this.cfg.draw_dat_valid_delay()) begin
      @(this.vif_sn[s].g_drv.rni_cb);
    end
    forever begin
      if (this.sn_dat_send_mgr[s].try_acquire_credit()) begin
        break;
      end
      @(this.vif_sn[s].g_drv.rni_cb);
    end
  endtask

  // Blocking downstream WriteNoSnpFull toward SN port 0: drive the REQ, wait for
  // the (Comp)DBIDResp grant captured by sn_capture_rsp, then drive the
  // NonCopyBackWrData burst (txnid=dbid=granted DBID, as the SN-F validates). The
  // default SN-F grant is a combined CompDBIDResp, so no separate Comp is awaited.
  protected task downstream_write(input addr_t addr, input size_t size,
                                  input data_t beats [$], input be_t bes [$]);
    req_flit_t req_flit;
    dat_flit_t dat_flit;
    rsp_flit_t grant;
    txn_id_t   dbid;
    int        s;
    int        n_beats;

    s       = 0;
    n_beats = beats.size();

    this.dn_rsp_q.delete();

    req_flit        = '0;
    req_flit.opcode = req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_FULL_C);
    req_flit.addr   = addr;
    req_flit.size   = size;
    req_flit.txnid  = this.alloc_dn_txn();
    req_flit.srcid  = node_id_t'(0);
    req_flit.tgtid  = node_id_t'(this.cfg.hnf_downstream_snf_id);

    this.wait_sn_req_send_credit(s);
    this.announce_sn_flit(s, ANNOUNCE_REQ_E);
    @(this.vif_sn[s].g_drv.rni_cb);
    this.vif_sn[s].g_drv.rni_cb.txreqflitpend <= 1'b0;
    this.vif_sn[s].g_drv.rni_cb.txreqflit     <= req_flit;
    this.vif_sn[s].g_drv.rni_cb.txreqflitv    <= 1'b1;
    @(this.vif_sn[s].g_drv.rni_cb);
    this.vif_sn[s].g_drv.rni_cb.txreqflitv    <= 1'b0;
    this.vif_sn[s].g_drv.rni_cb.txreqflit     <= '0;

    // Wait for the DBID grant (combined CompDBIDResp by default).
    while (this.dn_rsp_q.size() == 0) begin
      @(this.vif_sn[s].g_drv.rni_cb);
    end
    grant = this.dn_rsp_q.pop_front();
    dbid  = txn_id_t'(grant.dbid);

    // Drive the write-data burst.
    for (int i = 0; i < n_beats; i++) begin
      dat_flit        = '0;
      dat_flit.data   = beats[i];
      dat_flit.be     = (i < bes.size()) ? bes[i] : '1;
      dat_flit.dataid = data_id_t'(i);
      dat_flit.dbid   = dbid;
      dat_flit.txnid  = dbid;
      dat_flit.opcode = item_t::dat_opcode_t'(VIP_CHI_DAT_NON_COPY_BACK_WR_DATA_C);
      dat_flit.srcid  = node_id_t'(0);
      dat_flit.tgtid  = node_id_t'(this.cfg.hnf_downstream_snf_id);

      this.wait_sn_dat_send_credit(s);
      this.announce_sn_flit(s, ANNOUNCE_DAT_E);
      @(this.vif_sn[s].g_drv.rni_cb);
      this.vif_sn[s].g_drv.rni_cb.txdatflitpend <= (i != (n_beats - 1));
      this.vif_sn[s].g_drv.rni_cb.txdatflit     <= dat_flit;
      this.vif_sn[s].g_drv.rni_cb.txdatflitv    <= 1'b1;
      @(this.vif_sn[s].g_drv.rni_cb);
      this.vif_sn[s].g_drv.rni_cb.txdatflitpend <= 1'b0;
      this.vif_sn[s].g_drv.rni_cb.txdatflitv    <= 1'b0;
      this.vif_sn[s].g_drv.rni_cb.txdatflit     <= '0;
    end
  endtask

  // Invalidate the HN-F's local memory image of a line (write-back model): after
  // a flush to the SN-F the line is SN-resident, so a later read must re-fetch.
  protected function void clear_backing_line(input addr_t line, input int n_beats);
    for (int i = 0; i < n_beats; i++) begin
      longint row;
      row = this.row_index_from_addr(line + addr_t'(i * CFG_P.DATA_BYTES_P));
      if (this.mem_row_written.exists(row)) begin
        this.mem_row_written.delete(row);
      end
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Acquire one outbound send credit for the RN-facing DAT channel.
  // ---------------------------------------------------------------------------
  protected task wait_rn_dat_send_credit(input int p);
    repeat (this.cfg.draw_dat_valid_delay()) begin
      @(this.vif_rn[p].g_drv.hnf_cb);
    end
    forever begin
      if (this.rn_dat_send_mgr[p].try_acquire_credit()) begin
        break;
      end
      @(this.vif_rn[p].g_drv.hnf_cb);
    end
  endtask

  // ---------------------------------------------------------------------------
  // Response engine: drain the captured-REQ queue and service each request. M2
  // handles coherent reads only; a serial engine is sufficient (single RN-F is
  // serial, and concurrent reads on distinct ports simply serialize here). M3
  // adds a per-line lock + snoop origination.
  // ---------------------------------------------------------------------------
  protected task response_engine();
    hnf_work_t w;

    forever begin
      if (this.work_q.size() != 0) begin
        w = this.work_q.pop_front();
        this.service_req(w.port, w.flit);
      end
      else begin
        @(this.vif_rn[0].g_drv.hnf_cb);
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  // Terminate one captured request: dispatch by opcode class.
  // ---------------------------------------------------------------------------
  protected task service_req(input int p, input req_flit_t req);
    req_opcode_t op;

    op = req_opcode_t'(req.opcode);

    if (this.req_opcode_is_coherent_read(op)) begin
      this.service_coherent_read(p, req);
    end
    else if ((op == req_opcode_t'(VIP_CHI_REQ_WRITE_BACK_FULL_C)) ||
             (op == req_opcode_t'(VIP_CHI_REQ_WRITE_CLEAN_FULL_C))) begin
      this.service_writeback(p, req);
    end
    else if (op == req_opcode_t'(VIP_CHI_REQ_EVICT_C)) begin
      this.service_evict(p, req);
    end
    else if (op == req_opcode_t'(VIP_CHI_REQ_CLEAN_INVALID_C)) begin
      this.service_cmo_invalidate(p, req, this.snoop_for(op));
    end
    else if (op == req_opcode_t'(VIP_CHI_REQ_MAKE_INVALID_C)) begin
      this.service_cmo_invalidate(p, req, this.snoop_for(op));
    end
    else if (op == req_opcode_t'(VIP_CHI_REQ_READ_ONCE_C)) begin
      this.service_read_once(p, req);
    end
    else if ((op == req_opcode_t'(VIP_CHI_REQ_WRITE_UNIQUE_FULL_C)) ||
             (op == req_opcode_t'(VIP_CHI_REQ_WRITE_UNIQUE_PTL_C))) begin
      this.service_write_unique(p, req);
    end
    else if (op == VIP_CHI_REQ_WRITE_UNIQUE_ZERO_C) begin
      this.service_write_unique_zero(p, req);
    end
    else if (op == VIP_CHI_REQ_WRITE_EVICT_OR_EVICT_C) begin
      this.service_write_evict_or_evict(p, req);
    end
    else if (op == req_opcode_t'(VIP_CHI_REQ_CLEAN_UNIQUE_C)) begin
      this.service_clean_unique(p, req);
    end
    else if (op == req_opcode_t'(VIP_CHI_REQ_MAKE_UNIQUE_C)) begin
      this.service_make_unique(p, req);
    end
    else begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] HN-F: unsupported REQ opcode 0x%0h", get_name(), req.opcode))
    end
  endtask

  // ---------------------------------------------------------------------------
  // Serve a MakeUnique: acquire the line Unique WITHOUT a data transfer. The
  // requester intends to overwrite the whole line, so every OTHER holder is
  // snoop-invalidated with SnpMakeInvalid (drop to I, no data forwarded -- the
  // discarded data would be overwritten anyway), the requester is granted
  // Unique-Dirty (it now owns the line and must supply all data on a later
  // writeback), and the home returns an RSP-only Comp. No self-snoop; a store
  // breaks every exclusive reservation on the line. NOTE: because no data is
  // transferred, the granted line has no defined contents in the RN-F cache until
  // the requester writes it -- self-contained state-transition scenario; a snoop
  // of the freshly-made line before a write is out of the modeled scope.
  // ---------------------------------------------------------------------------
  protected task service_make_unique(input int p, input req_flit_t req);
    addr_t                       line;
    logic [N_RNF_PORTS-1:0][2:0] entry;
    vip_chi_resp_t               cur_k;

    line  = this.line_addr(addr_t'(req.addr));
    entry = this.directory.exists(line) ? this.directory[line] : '0;

    for (int k = 0; k < N_RNF_PORTS; k++) begin
      if (k == p) begin
        continue;
      end
      if (this.cfg.hnf_suppress_snoops) begin
        continue;
      end
      cur_k = vip_chi_resp_t'(entry[k]);
      if (cur_k == VIP_CHI_RESP_STATE_I_E) begin
        continue;
      end
      this.drive_snoop(k, line, this.snoop_for(req_opcode_t'(req.opcode)));
      entry[k] = VIP_CHI_RESP_STATE_I_E;
    end

    // The requester ends up holding the line Unique-Dirty, so that is what the
    // directory records.
    entry[p] = VIP_CHI_RESP_STATE_UP_PD_DIRTY_E;
    this.directory[line] = entry;

    // A store consumes/clears every monitor on the line.
    this.excl_monitor.delete(line);

    // The COMPLETION, however, is Comp_UC and not Comp_UD_PD. IHI 0050 E Table
    // 4-19 (D Table 4-13) gives MakeUnique a final state of UD from every
    // permitted initial state and a completion response of Comp_UC: the requester
    // becomes Dirty by its own act of overwriting the whole line, not by being
    // handed anyone's dirty data, and Comp_UD_PD is reserved for the case where
    // "responsibility for a Dirty cache line is being passed" (Table 4-7).
    //
    // Sending UD_PD here was not merely an odd choice of encoding. Issue D does
    // not define UD_PD for a data-less completion at all -- D Table 4-5 permits
    // exactly Comp_I, Comp_UC and Comp_SC -- so the CHI-D cut of this home was
    // driving a Resp value the issue it implements has no meaning for.
    this.drive_rn_rsp(p,
                      item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_C),
                      txn_id_t'(req.txnid), txn_id_t'(0),
                      VIP_CHI_RESP_STATE_UC_E,
                      node_id_t'(req.tgtid), node_id_t'(req.srcid));
  endtask

  // ---------------------------------------------------------------------------
  // Serve a WriteUnique(Full/Ptl): a non-allocating coherent write. Every OTHER
  // holder is snoop-invalidated first (their copies would be stale after the
  // write) via SnpCleanInvalid, which also forwards a dirty holder's data (merged
  // to memory) so a WriteUniquePtl's unwritten bytes keep their correct pre-write
  // value. The home then grants a combined CompDBIDResp, collects the
  // NonCopyBackWrData burst into memory (byte-enables apply for a partial write),
  // and leaves the writer Invalid (it never owned the line). No self-snoop.
  // ---------------------------------------------------------------------------
  protected task service_write_unique(input int p, input req_flit_t req);
    addr_t                       line;
    addr_t                       write_addr;
    logic [N_RNF_PORTS-1:0][2:0] entry;
    int unsigned                 expected_beats;
    dat_opcode_t                 expected_dat_opcode;
    vip_chi_resp_t               cur_k;

    line  = this.line_addr(addr_t'(req.addr));
    entry = this.directory.exists(line) ? this.directory[line] : '0;

    for (int k = 0; k < N_RNF_PORTS; k++) begin
      if (k == p) begin
        continue;
      end
      if (this.cfg.hnf_suppress_snoops) begin
        continue;
      end
      cur_k = vip_chi_resp_t'(entry[k]);
      if (cur_k == VIP_CHI_RESP_STATE_I_E) begin
        continue;
      end
      this.drive_snoop(k, line, this.snoop_for(req_opcode_t'(req.opcode)));
    end

    // The line is invalid everywhere; the non-allocating writer does not own it.
    this.directory[line] = '0;
    // The write changed the line's data -> every exclusive reservation is broken.
    this.excl_monitor.delete(line);

    this.drive_rn_rsp(p,
                      item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_DBID_RESP_C),
                      txn_id_t'(req.txnid), txn_id_t'(req.txnid),
	                      VIP_CHI_RESP_STATE_I_E,
	                      node_id_t'(req.tgtid), node_id_t'(req.srcid));

    write_addr          = (req_opcode_t'(req.opcode) == req_opcode_t'(VIP_CHI_REQ_WRITE_UNIQUE_PTL_C))
                        ? addr_t'(req.addr)
                        : line;
    expected_beats      = vip_chi_types_pkg::chi_xfer_dat_beats(size_t'(req.size), CFG_P.DATA_BYTES_P);
    expected_dat_opcode = req.expcompack
                        ? dat_opcode_t'(VIP_CHI_DAT_NCB_WR_DATA_COMP_ACK_C)
                        : dat_opcode_t'(VIP_CHI_DAT_NON_COPY_BACK_WR_DATA_C);

    // A partial write must preserve the line's untouched lanes. Back the line with
    // its current read image first so wr_be merges the enabled bytes over the real
    // pre-write value rather than zero-filling the other lanes of an unbacked beat
    // (a 16 B write inside a 64 B CHI-E beat).
    if (req_opcode_t'(req.opcode) == req_opcode_t'(VIP_CHI_REQ_WRITE_UNIQUE_PTL_C)) begin
      this.backfill_line_image(line);
    end

    this.collect_write_data(p,
                            txn_id_t'(req.txnid),
                            write_addr,
                            expected_beats,
                            expected_dat_opcode,
                            node_id_t'(req.srcid),
                            node_id_t'(req.tgtid),
                            "WriteUnique");
  endtask

  // ---------------------------------------------------------------------------
  // Serve a ReadOnce: a non-allocating snapshot read. Snoop any DIRTY holder with
  // SnpOnce to fetch the current data (home memory is stale while a holder is
  // dirty); SnpOnce leaves the holder's state and data unchanged, and the
  // forwarded beats are merged to memory by collect_snp_resp_data, so the
  // CompData below (sourced from memory) carries the current value. Clean holders
  // need no snoop -- memory is authoritative. The requester does NOT allocate, so
  // it is granted resp = Invalid and the directory is left untouched (no self-snoop).
  // ---------------------------------------------------------------------------
  protected task service_read_once(input int p, input req_flit_t req);
    addr_t                       line;
    logic [N_RNF_PORTS-1:0][2:0] entry;
    vip_chi_resp_t               cur_k;

    line  = this.line_addr(addr_t'(req.addr));
    entry = this.directory.exists(line) ? this.directory[line] : '0;

    // Snoop every OTHER holder with SnpOnce. The home cannot tell from its
    // directory whether a Unique-Clean holder has SILENTLY dirtied its copy
    // (UC -> UD is not reported to the home), so any non-Invalid holder must be
    // snooped: a dirty one forwards its current data (merged to memory by
    // collect_snp_resp_data), a clean one answers no-data and memory stays
    // authoritative. SnpOnce preserves the holder's state and data.
    for (int k = 0; k < N_RNF_PORTS; k++) begin
      if (k == p) begin
        continue;
      end
      if (this.cfg.hnf_suppress_snoops) begin
        continue;
      end
      cur_k = vip_chi_resp_t'(entry[k]);
      if (cur_k != VIP_CHI_RESP_STATE_I_E) begin
        this.drive_snoop(k, line, this.snoop_for(req_opcode_t'(req.opcode)));
      end
    end

    this.drive_coherent_read_compdata(p, req, VIP_CHI_RESP_STATE_I_E);
  endtask

  // ---------------------------------------------------------------------------
  // Serve a cache-maintenance invalidate (CleanInvalid / MakeInvalid). The line
  // is invalidated at the point of coherence: snoop every OTHER holder to drop it
  // to Invalid (a node never snoops itself -- the requester invalidates its own
  // copy locally on completion), clear the whole directory entry, and return an
  // RSP-only Comp (no data goes back to the requester). CleanInvalid uses
  // SnpCleanInvalid so a dirty holder forwards its data (merged to memory by
  // collect_snp_resp_data); MakeInvalid uses SnpMakeInvalid, which discards it.
  // ---------------------------------------------------------------------------
  protected task service_cmo_invalidate(input int p, input req_flit_t req, input snp_opcode_t snp_op);
    addr_t                       line;
    logic [N_RNF_PORTS-1:0][2:0] entry;
    vip_chi_resp_t               cur_k;

    line  = this.line_addr(addr_t'(req.addr));
    entry = this.directory.exists(line) ? this.directory[line] : '0;

    for (int k = 0; k < N_RNF_PORTS; k++) begin
      if (k == p) begin
        continue;
      end
      // Negative-control hook: skip snoops so a stale holder can be induced.
      if (this.cfg.hnf_suppress_snoops) begin
        continue;
      end
      cur_k = vip_chi_resp_t'(entry[k]);
      if (cur_k == VIP_CHI_RESP_STATE_I_E) begin
        continue;
      end
      this.drive_snoop(k, line, snp_op);
    end

    // The line is now invalid everywhere (including the requester's own copy).
    this.directory[line] = '0;
    // Invalidating the line drops every port's exclusive reservation on it.
    this.excl_monitor.delete(line);

    this.drive_rn_rsp(p,
                      item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_C),
                      txn_id_t'(req.txnid), txn_id_t'(0),
                      VIP_CHI_RESP_STATE_I_E,
                      node_id_t'(req.tgtid), node_id_t'(req.srcid));
  endtask

  // ---------------------------------------------------------------------------
  // Serve a CleanUnique -- the exclusive-store (SC) opcode, and the generic
  // "upgrade a clean shared copy to Unique without data" request. The requester
  // already holds the line clean (from its load); the home invalidates every
  // OTHER holder and grants it Unique. No data is transferred (RSP-only Comp).
  //
  // Exclusive (excl=1) semantics -- the store-conditional:
  //   * Evaluate the per-(line,port) monitor BEFORE originating any snoop, because
  //     the SC's own invalidations must not consume the reservation being tested
  //     (the requester's own bit is never touched by a k!=p snoop, but evaluating
  //     first keeps the ordering unambiguous).
  //   * won := monitor still set for this port (or forced by the negative-control
  //     knob). A won SC completes Comp/ExclOkay (the store "succeeded"); a lost SC
  //     completes Comp/NormalOkay (an intervening conflict cleared the monitor --
  //     the store "failed" and the RN-F must retry).
  //   * The SC is itself a store: it consumes/clears every port's monitor on the
  //     line (paths a + c) once evaluated.
  // A non-exclusive CleanUnique always completes NormalOkay.
  // ---------------------------------------------------------------------------
  protected task service_clean_unique(input int p, input req_flit_t req);
    addr_t                       line;
    logic [N_RNF_PORTS-1:0][2:0] entry;
    vip_chi_resp_t               cur_k;
    bit                          is_excl;
    bit                          won;
    vip_chi_resp_err_t           rerr;

    line    = this.line_addr(addr_t'(req.addr));
    is_excl = this.cfg.exclusives_enabled &&
              (vip_chi_exclusive_t'(req.excl) == VIP_CHI_REQ_EXCLUSIVE_E);

    // Evaluate the reservation up front (before any snoop/clear below).
    won = 1'b0;
    if (is_excl) begin
      if (this.cfg.hnf_force_excl_success) begin
        won = 1'b1;  // negative-control: claim success regardless of the monitor
      end
      else begin
        won = this.excl_monitor.exists(line) &&
              (this.excl_monitor[line][p] === 1'b1);
      end
    end

    // Upgrade to Unique: snoop-invalidate every OTHER holder, then grant p Unique.
    entry = this.directory.exists(line) ? this.directory[line] : '0;
    for (int k = 0; k < N_RNF_PORTS; k++) begin
      if (k == p) begin
        continue;
      end
      if (this.cfg.hnf_suppress_snoops) begin
        continue;
      end
      cur_k = vip_chi_resp_t'(entry[k]);
      if (cur_k == VIP_CHI_RESP_STATE_I_E) begin
        continue;
      end
      this.drive_snoop(k, line, this.snoop_for(req_opcode_t'(req.opcode)));
      entry[k] = VIP_CHI_RESP_STATE_I_E;
    end

    // Grant the requester Unique-Clean on the wire; record the join in the
    // filter. Table 4-19 gives CleanUnique an SD row whose final state is UD, so
    // writing a flat UC here would lose a dirty copy the same way -- Table 4-14
    // footnote b again.
    entry[p] = vip_chi_req_final_state(vip_chi_req_opcode_t'(req.opcode),
                                       vip_chi_resp_t'(entry[p]),
                                       VIP_CHI_RESP_STATE_UC_E);
    this.directory[line] = entry;

    // A store consumes/clears all monitors on the line (paths a + c).
    this.excl_monitor.delete(line);

    rerr = (is_excl && won) ? VIP_CHI_RESP_ERR_EXCLUSIVE_OKAY_E
                            : VIP_CHI_RESP_ERR_NORMAL_OKAY_E;
    this.drive_rn_rsp(p,
                      item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_C),
                      txn_id_t'(req.txnid), txn_id_t'(0),
                      VIP_CHI_RESP_STATE_UC_E,
                      node_id_t'(req.tgtid), node_id_t'(req.srcid),
                      rerr);
  endtask

  // ---------------------------------------------------------------------------
  // Serve a coherent read: snoop the other holders as the request demands, grant
  // the requester, record the directory, and return CompData from memory.
  // ---------------------------------------------------------------------------
  protected task service_coherent_read(input int p, input req_flit_t req);
    addr_t                       line;
    bit                          is_unique;
    bit                          is_excl_ll;
    int                          fwd_k;
    logic [N_RNF_PORTS-1:0][2:0] entry;
    vip_chi_resp_t               cur_k;
    vip_chi_resp_t               granted;

    line      = this.line_addr(addr_t'(req.addr));
    is_unique = this.req_opcode_is_unique_read(req_opcode_t'(req.opcode));
    entry     = this.directory.exists(line) ? this.directory[line] : '0;

    // DCT (direct cache transfer) origination -- config-gated (default off, so all
    // non-DCT tests are byte-identical). When EXACTLY ONE peer holds the line and
    // the read is not an exclusive load, forward the data directly from that peer
    // (relayed by the home) instead of snoop-then-serve-from-memory. The forward
    // path invalidates/downgrades only that single peer, so when two or more peers
    // hold the line (possible with >2 RN-F ports) we must fall through to the
    // ordinary snoop path, which snoops every holder. The snoop-suppress negctl
    // and exclusive loads also stay on the ordinary path below.
    if (this.cfg.hnf_enable_snoop_fwd && !this.cfg.hnf_suppress_snoops &&
        !(this.cfg.exclusives_enabled &&
          (vip_chi_exclusive_t'(req.excl) == VIP_CHI_REQ_EXCLUSIVE_E))) begin
      int fwd_holders;
      fwd_k       = -1;
      fwd_holders = 0;
      for (int k = 0; k < N_RNF_PORTS; k++) begin
        if (k == p) begin
          continue;
        end
        if (vip_chi_resp_t'(entry[k]) != VIP_CHI_RESP_STATE_I_E) begin
          fwd_k = k;
          fwd_holders++;
        end
      end
      if (fwd_holders == 1) begin
        this.service_coherent_read_fwd(p, req, line, fwd_k, is_unique, entry);
        return;
      end
    end

    // Snoop the other sharers as the request demands, before completing. A
    // unique read invalidates every other holder; a shared read only downgrades
    // a unique holder to shared (a holder already Shared needs no snoop). The
    // requester is never snooped (no self-snoop). Data still comes from the
    // home's memory -- these are the clean, no-data snoop cases (M4 adds dirty
    // forwarding).
    for (int k = 0; k < N_RNF_PORTS; k++) begin
      if (k == p) begin
        continue;
      end
      // Negative-control hook: skip snoops entirely so a coherency violation
      // (a duplicate Unique owner) can be induced on purpose.
      if (this.cfg.hnf_suppress_snoops) begin
        continue;
      end
      cur_k = vip_chi_resp_t'(entry[k]);
      if (cur_k == VIP_CHI_RESP_STATE_I_E) begin
        continue;
      end

      if (is_unique) begin
        this.drive_snoop(k, line, this.snoop_for(req_opcode_t'(req.opcode)));
        entry[k] = VIP_CHI_RESP_STATE_I_E;
        // A snoop-invalidate to port k breaks any exclusive reservation it held.
        if (this.excl_monitor.exists(line)) begin
          this.excl_monitor[line][k] = 1'b0;
        end
      end
      // A non-unique read downgrades a Unique holder and leaves an already-Shared
      // one alone. The OPCODE now comes from Table 4-5 rather than from this
      // branch: SnpShared for a ReadShared, SnpClean for a ReadClean. The two
      // resolve the snoopee identically in this model (both end SC, both return
      // dirty data if it had any), which is why one opcode served both for so
      // long -- the difference the spec draws is in what the snoopee is
      // PERMITTED to do, not in what this RN-F does.
      else if ((cur_k == VIP_CHI_RESP_STATE_UC_E) ||
               (cur_k == VIP_CHI_RESP_STATE_UP_PD_DIRTY_E)) begin
        this.drive_snoop(k, line, this.snoop_for(req_opcode_t'(req.opcode)));
        entry[k] = VIP_CHI_RESP_STATE_SC_E;
      end
    end

    // The GRANT goes on the wire; the SNOOP FILTER records the join of the grant
    // with what this port already held. IHI 0050 E Table 4-14 footnote b is
    // explicit that the two are different: "a Home that uses a Snoop filter to
    // track the cached state at the Requester must not downgrade the state of the
    // cache line in the Snoop filter based on the state in the response to the
    // Requester." A UD holder issuing ReadClean receives CompData_SC and stays
    // UD, and a filter that wrote SC would then believe the only dirty copy in
    // the system is clean -- and could serve a later reader from memory without
    // asking for it.
    granted  = is_unique ? this.cfg.coh_read_unique_state : this.cfg.coh_read_shared_state;
    entry[p] = vip_chi_req_final_state(vip_chi_req_opcode_t'(req.opcode),
                                       vip_chi_resp_t'(entry[p]), granted);
    this.directory[line] = entry;

    // Exclusive load (LL): arm the per-(line,port) monitor and signal ExclOkay on
    // the completion so the RN-F knows its reservation was taken.
    is_excl_ll = this.cfg.exclusives_enabled &&
                 (vip_chi_exclusive_t'(req.excl) == VIP_CHI_REQ_EXCLUSIVE_E);
    if (is_excl_ll) begin
      this.excl_monitor[line][p] = 1'b1;
    end

    // Two-level hierarchy (config-gated): on a directory/mem MISS -- a line that
    // was never written/flushed locally -- fetch it from the downstream SN-F and
    // fill mem, so the CompData below is sourced from the SN-F's memory instead of
    // a home-synthesized pattern. A HIT (row already resident) is served locally
    // (an LLC hit -- no downstream traffic). Dirty-forward lines are hits (the
    // snoop merged them into mem), so they are never re-fetched.
    if (this.cfg.hnf_downstream_en && (N_SN_PORTS > 0) &&
        !this.has_backing_row(line)) begin
      data_t dn_beats [$];
      be_t   dn_be    [$];
      this.downstream_read(line, size_t'(req.size), dn_beats);
      // Negative-control: corrupt the fetched data the HN-F relays (into mem, and
      // thence the RN-F CompData) while the checker still sees the SN-F's TRUE
      // value on the downstream DAT stream -> a data-integrity mismatch it must
      // catch. Default off leaves the fetch faithful.
      if (this.cfg.hnf_downstream_corrupt_data) begin
        foreach (dn_beats[i]) begin
          dn_beats[i] = ~dn_beats[i];
        end
      end
      foreach (dn_beats[i]) begin
        dn_be.push_back('1);
      end
      this.mem.wr_be(line, dn_beats, dn_be);
      foreach (dn_beats[i]) begin
        this.mark_backing_row(line + addr_t'(i * CFG_P.DATA_BYTES_P));
      end
    end

    this.drive_coherent_read_compdata(p, req, granted, is_excl_ll);
  endtask

  // ---------------------------------------------------------------------------
  // Serve a coherent writeback (WriteBackFull / WriteCleanFull): grant a DBID
  // with a combined CompDBIDResp, collect the CopyBackWrData burst into memory,
  // and clear the requester's directory ownership (the line went to the home).
  // A combined grant means the RN-F needs no separate Comp.
  // ---------------------------------------------------------------------------
  protected task service_writeback(input int p, input req_flit_t req);
    addr_t line;

    line = this.line_addr(addr_t'(req.addr));

    // Grant: CompDBIDResp echoes the request TxnID as the DBID the WriteData
    // will carry, matched on collection.
    this.drive_rn_rsp(p,
                      item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_DBID_RESP_C),
                      txn_id_t'(req.txnid), txn_id_t'(req.txnid),
                      VIP_CHI_RESP_STATE_I_E,
                      node_id_t'(req.tgtid), node_id_t'(req.srcid));

    this.collect_write_data(p,
                            txn_id_t'(req.txnid),
                            line,
                            vip_chi_types_pkg::chi_xfer_dat_beats(size_t'(req.size), CFG_P.DATA_BYTES_P),
                            dat_opcode_t'(VIP_CHI_DAT_COPY_BACK_WR_DATA_C),
                            node_id_t'(req.srcid),
                            node_id_t'(req.tgtid),
                            "WriteBack/WriteClean");

    // The line now lives in memory; the writer holds it Invalid.
    if (this.directory.exists(line)) begin
      this.directory[line][p] = VIP_CHI_RESP_STATE_I_E;
    end
    // The writeback committed new data to the line -> reservations are broken.
    this.excl_monitor.delete(line);

    // Two-level hierarchy (config-gated): flush the just-written line to the
    // downstream SN-F (WriteNoSnpFull), then drop the local memory image so the
    // line is SN-resident (write-back). A later read misses and re-fetches it
    // from the SN-F, proving the written-back value survives downstream.
    if (this.cfg.hnf_downstream_en && (N_SN_PORTS > 0)) begin
      data_t wb_beats [$];
      be_t   wb_be    [$];
      int    nb;
      nb = vip_chi_types_pkg::chi_xfer_dat_beats(size_t'(req.size), CFG_P.DATA_BYTES_P);
      for (int i = 0; i < nb; i++) begin
        wb_beats.push_back(this.read_data_beat(line, i));
        wb_be.push_back('1);
      end
      this.downstream_write(line, size_t'(req.size), wb_beats, wb_be);
      this.clear_backing_line(line, nb);
    end
  endtask

  // ---------------------------------------------------------------------------
  // Serve an Evict: RSP-only ownership drop. Clear the requester's directory
  // entry and return a plain Comp (no data changes hands).
  // ---------------------------------------------------------------------------
  // ---------------------------------------------------------------------------
  // Serve a WriteUniqueZero: a full-line store of ZERO with no data on the wire.
  //
  // The snoopable twin of WriteNoSnpZero. The line is being overwritten in its
  // entirety, so every other holder is invalidated first and the home then zeroes
  // the line itself -- there is no write data to wait for, which is the whole
  // point of the opcode and the one thing that makes it different from a
  // WriteUniqueFull carrying zeros.
  //
  // SnpCleanInvalid rather than SnpMakeInvalid, matching service_write_unique.
  // The specification permits SnpMakeInvalid here, but only when the home knows
  // the snoopee holds no dirty tags -- a condition this directory does not track,
  // and the discarded data costs nothing because the line is about to be zeroed.
  //
  // Completion is CompDBIDResp. The specification also allows separate DBIDResp
  // and Comp; the combined form is used because it is what every other write in
  // this home already sends, and a DBID is still returned even though no data
  // will ever be sent against it.
  // ---------------------------------------------------------------------------
  protected task service_write_unique_zero(input int p, input req_flit_t req);
    addr_t                       line;
    logic [N_RNF_PORTS-1:0][2:0] entry;
    vip_chi_resp_t               cur_k;
    int                          line_beats;
    data_t                       zeros [$];
    be_t                         be    [$];

    line  = this.line_addr(addr_t'(req.addr));
    entry = this.directory.exists(line) ? this.directory[line] : '0;

    for (int k = 0; k < N_RNF_PORTS; k++) begin
      if (k == p) begin
        continue;
      end
      if (this.cfg.hnf_suppress_snoops) begin
        continue;
      end
      cur_k = vip_chi_resp_t'(entry[k]);
      if (cur_k == VIP_CHI_RESP_STATE_I_E) begin
        continue;
      end
      this.drive_snoop(k, line, this.snoop_for(req_opcode_t'(req.opcode)));
    end

    // The line is invalid everywhere; the zeroing writer does not own it either.
    this.directory[line] = '0;
    // The write changed the line's data -> every exclusive reservation is broken.
    this.excl_monitor.delete(line);

    line_beats = VIP_CHI_CACHE_LINE_BYTES_C / CFG_P.DATA_BYTES_P;
    for (int b = 0; b < line_beats; b++) begin
      zeros.push_back('0);
      be.push_back('1);
    end
    this.mem.wr_be(line, zeros, be);
    for (int b = 0; b < line_beats; b++) begin
      this.mark_backing_row(line + addr_t'(b * CFG_P.DATA_BYTES_P));
    end

    this.drive_rn_rsp(p,
                      item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_DBID_RESP_C),
                      txn_id_t'(req.txnid), txn_id_t'(req.txnid),
                      VIP_CHI_RESP_STATE_I_E,
                      node_id_t'(req.tgtid), node_id_t'(req.srcid));
  endtask

  // ---------------------------------------------------------------------------
  // Serve a WriteEvictOrEvict: the one CopyBack whose SHAPE the home chooses.
  //
  // The requester is handing back a CLEAN line that a downstream cache may want.
  // The home decides, "based on its own heuristics", whether that is worth the
  // data transfer:
  //
  //   * want it   -> CompDBIDResp, and the requester sends CopyBackWrData. No
  //                  explicit CompAck follows: the specification states that the
  //                  CopyBackWriteData message IS the implicit acknowledgement,
  //                  which is why this leg must not wait for one.
  //   * decline it -> Comp, and the requester answers with an explicit CompAck.
  //                  The transaction degenerates into an Evict.
  //
  // "Its own heuristics" is not something a test can predict, so the choice is a
  // config knob here rather than a random draw: both legs are reachable, each
  // deterministically, and a test can assert which one it asked for. That is the
  // difference between a modelled choice and an unverifiable one.
  // ---------------------------------------------------------------------------
  protected task service_write_evict_or_evict(input int p, input req_flit_t req);
    addr_t       line;
    int unsigned expected_beats;

    line = this.line_addr(addr_t'(req.addr));

    // Either way the requester ends up without the line.
    if (this.directory.exists(line)) begin
      this.directory[line][p] = VIP_CHI_RESP_STATE_I_E;
    end

    if (!this.cfg.hnf_write_evict_request_data) begin
      this.drive_rn_rsp(p,
                        item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_C),
                        txn_id_t'(req.txnid), txn_id_t'(0),
                        VIP_CHI_RESP_STATE_I_E,
                        node_id_t'(req.tgtid), node_id_t'(req.srcid));

      this.collect_comp_ack(p, txn_id_t'(req.txnid));
      return;
    end

    this.drive_rn_rsp(p,
                      item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_DBID_RESP_C),
                      txn_id_t'(req.txnid), txn_id_t'(req.txnid),
                      VIP_CHI_RESP_STATE_I_E,
                      node_id_t'(req.tgtid), node_id_t'(req.srcid));

    expected_beats = vip_chi_types_pkg::chi_xfer_dat_beats(size_t'(req.size),
                                                           CFG_P.DATA_BYTES_P);

    this.collect_write_data(p,
                            txn_id_t'(req.txnid),
                            line,
                            expected_beats,
                            dat_opcode_t'(VIP_CHI_DAT_COPY_BACK_WR_DATA_C),
                            node_id_t'(req.srcid),
                            node_id_t'(req.tgtid),
                            "WriteEvictOrEvict");
  endtask

  // ---------------------------------------------------------------------------
  // Wait for the explicit CompAck that closes the no-data leg of a
  // WriteEvictOrEvict. Same shape as collect_snp_response: any other flit on this
  // port while the serial engine is waiting means per-line concurrency arrived
  // without per-TxnID routing, so it is fatal rather than silently dropped.
  // ---------------------------------------------------------------------------
  protected task collect_comp_ack(input int p, input txn_id_t txn);
    rsp_flit_t rflit;

    forever begin
      if (this.vif_rn[p].g_drv.hnf_cb.rxrspflitv) begin
        rflit = this.vif_rn[p].g_drv.hnf_cb.rxrspflit;
        this.rn_rsp_lcrdv_pending[p] += 1;

        if ((vip_chi_rsp_opcode_t'(rflit.opcode) == vip_chi_rsp_opcode_t'(VIP_CHI_RSP_COMP_ACK_C)) &&
            (txn_id_t'(rflit.txnid) == txn)) begin
          @(this.vif_rn[p].g_drv.hnf_cb);
          this.drive_rn_idle_sideband(p);
          break;
        end

        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] port %0d: unexpected RSP (opcode 0x%0h TxnID 0x%0h) while awaiting CompAck for TxnID 0x%0h",
          get_name(), p, rflit.opcode, rflit.txnid, txn))
      end

      @(this.vif_rn[p].g_drv.hnf_cb);
      this.drive_rn_idle_sideband(p);
    end
  endtask

  protected task service_evict(input int p, input req_flit_t req);
    addr_t line;

    line = this.line_addr(addr_t'(req.addr));

    if (this.directory.exists(line)) begin
      this.directory[line][p] = VIP_CHI_RESP_STATE_I_E;
    end

    this.drive_rn_rsp(p,
                      item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_C),
                      txn_id_t'(req.txnid), txn_id_t'(0),
                      VIP_CHI_RESP_STATE_I_E,
                      node_id_t'(req.tgtid), node_id_t'(req.srcid));
  endtask

  // ---------------------------------------------------------------------------
  // Acquire one outbound send credit for the RN-facing RSP channel.
  // ---------------------------------------------------------------------------
  // ---------------------------------------------------------------------------
  // Raise FLITPEND for the cycle before a flit goes out. IHI 0050 E §14.4 /
  // D §13.4: asserted exactly one cycle before a flit is sent. Every beat of a
  // burst is announced, not only the first, because the gap cycle after each
  // beat drops it; the value driven WITH each beat keeps its burst meaning
  // (more beats follow), which is what the snoopee and the monitor read to find
  // the last one.
  // ---------------------------------------------------------------------------
  protected task announce_rn_flit(input int p, input announce_ch_t ch);
    @(this.vif_rn[p].g_drv.hnf_cb);
    this.drive_rn_idle_sideband(p);
    this.vif_rn[p].g_drv.hnf_cb.txsactive <= 1'b1;
    case (ch)
      ANNOUNCE_RSP_E: this.vif_rn[p].g_drv.hnf_cb.txrspflitpend <= 1'b1;
      ANNOUNCE_SNP_E: this.vif_rn[p].g_drv.hnf_cb.txsnpflitpend <= 1'b1;
      default:        this.vif_rn[p].g_drv.hnf_cb.txdatflitpend <= 1'b1;
    endcase
  endtask

  protected task announce_sn_flit(input int s, input announce_ch_t ch);
    @(this.vif_sn[s].g_drv.rni_cb);
    if (ch == ANNOUNCE_REQ_E) begin
      this.vif_sn[s].g_drv.rni_cb.txreqflitpend <= 1'b1;
    end
    else begin
      this.vif_sn[s].g_drv.rni_cb.txdatflitpend <= 1'b1;
    end
  endtask

  protected task wait_rn_rsp_send_credit(input int p);
    // The credit loop below keeps the sideband driven every cycle it waits, so
    // the delay has to as well -- otherwise a delayed RSP stops this port's
    // queued LCRDV pulses for the length of the delay, back-pressuring the RN
    // as a side effect of shaping our own transmit timing.
    repeat (this.cfg.draw_rsp_valid_delay()) begin
      @(this.vif_rn[p].g_drv.hnf_cb);
      this.drive_rn_idle_sideband(p);
    end
    forever begin
      if (this.rn_rsp_send_mgr[p].try_acquire_credit()) begin
        break;
      end
      @(this.vif_rn[p].g_drv.hnf_cb);
      this.drive_rn_idle_sideband(p);
    end
  endtask

  // ---------------------------------------------------------------------------
  // Drive one RSP flit toward RN-F port p (Comp / CompDBIDResp).
  // ---------------------------------------------------------------------------
  protected task drive_rn_rsp(
    input int                 p,
    input rsp_opcode_t        opcode,
    input txn_id_t            txnid,
    input txn_id_t            dbid,
    input vip_chi_resp_t      resp,
    input node_id_t           src_id,
    input node_id_t           tgt_id,
    input vip_chi_resp_err_t  resperr = VIP_CHI_RESP_ERR_NORMAL_OKAY_E
  );
    rsp_flit_t flit;

    flit         = '0;
    flit.opcode  = opcode;
    flit.txnid   = txnid;
    flit.dbid    = dbid;
    flit.resp    = resp;
    flit.resperr = resperr;
    flit.srcid   = src_id;
    flit.tgtid   = tgt_id;
    flit.qos     = '0;

    this.wait_rn_rsp_send_credit(p);

    this.announce_rn_flit(p, ANNOUNCE_RSP_E);
    @(this.vif_rn[p].g_drv.hnf_cb);
    this.drive_rn_idle_sideband(p);
    this.vif_rn[p].g_drv.hnf_cb.txsactive     <= 1'b1;
    this.vif_rn[p].g_drv.hnf_cb.txrspflitpend  <= 1'b0;
    this.vif_rn[p].g_drv.hnf_cb.txrspflit      <= flit;
    this.vif_rn[p].g_drv.hnf_cb.txrspflitv     <= 1'b1;

    @(this.vif_rn[p].g_drv.hnf_cb);
    this.drive_rn_idle_sideband(p);
    this.vif_rn[p].g_drv.hnf_cb.txrspflitv     <= 1'b0;
    this.vif_rn[p].g_drv.hnf_cb.txrspflit      <= '0;
    this.vif_rn[p].g_drv.hnf_cb.txsactive      <= 1'b0;
  endtask

  // ---------------------------------------------------------------------------
  // Collect a coherent write-data burst into memory. The home granted DBID = REQ
  // TxnID, so every beat must echo that DBID, carry the expected write-data opcode,
  // arrive from the requester to this HN-F, and present the exact beat count.
  // ---------------------------------------------------------------------------
  protected task collect_write_data(
    input int          p,
    input txn_id_t     dbid,
    input addr_t       write_addr,
    input int unsigned expected_beats,
    input dat_opcode_t expected_opcode,
    input node_id_t    expected_src_id,
    input node_id_t    expected_tgt_id,
    input string       flow_name
  );
    dat_flit_t flit;
    data_t     data_q [$];
    be_t       be_q   [$];
    bit        last_beat;

    if (expected_beats == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] port %0d: %s expected zero DAT beats",
        get_name(), p, flow_name))
    end

    for (int unsigned beat_index = 0; beat_index < expected_beats; beat_index++) begin
      while (!this.vif_rn[p].g_drv.hnf_cb.rxdatflitv) begin
        @(this.vif_rn[p].g_drv.hnf_cb);
        this.drive_rn_idle_sideband(p);
      end

      flit = this.vif_rn[p].g_drv.hnf_cb.rxdatflit;
      this.rn_dat_lcrdv_pending[p] += 1;

      if (txn_id_t'(flit.txnid) != dbid) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] port %0d: %s DAT TxnID 0x%0h != granted DBID 0x%0h",
          get_name(), p, flow_name, flit.txnid, dbid))
      end

      if (txn_id_t'(flit.dbid) != dbid) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] port %0d: %s DAT DBID 0x%0h != granted DBID 0x%0h",
          get_name(), p, flow_name, flit.dbid, dbid))
      end

      if (dat_opcode_t'(flit.opcode) != expected_opcode) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] port %0d: %s DAT opcode 0x%0h != expected 0x%0h",
          get_name(), p, flow_name, flit.opcode, expected_opcode))
      end

      if ((node_id_t'(flit.srcid) != expected_src_id) ||
          (node_id_t'(flit.tgtid) != expected_tgt_id)) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] port %0d: %s DAT src/tgt 0x%0h->0x%0h != expected 0x%0h->0x%0h",
          get_name(), p, flow_name, flit.srcid, flit.tgtid,
          expected_src_id, expected_tgt_id))
      end

      if (data_id_t'(flit.dataid) != data_id_t'(beat_index)) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] port %0d: %s DAT DataID %0d != expected %0d",
          get_name(), p, flow_name, flit.dataid, beat_index))
      end

      data_q.push_back(data_t'(flit.data));
      be_q.push_back(be_t'(flit.be));
      last_beat = !this.vif_rn[p].g_drv.hnf_cb.rxdatflitpend;

      if (last_beat != (beat_index == (expected_beats - 1))) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] port %0d: %s DAT burst ended at beat %0d with expected_beats=%0d (pend=%0b)",
          get_name(), p, flow_name, beat_index, expected_beats,
          this.vif_rn[p].g_drv.hnf_cb.rxdatflitpend))
      end

      @(this.vif_rn[p].g_drv.hnf_cb);
      this.drive_rn_idle_sideband(p);
    end

    this.mem.wr_be(write_addr, data_q, be_q);
    foreach (data_q[i]) begin
      this.mark_backing_row(write_addr + addr_t'(i * CFG_P.DATA_BYTES_P));
    end
  endtask

  // ---------------------------------------------------------------------------
  // Allocate the next snoop TxnID (echoed back in the SnpResp for matching).
  // ---------------------------------------------------------------------------
  protected function txn_id_t alloc_snp_txn();
    txn_id_t t;
    t = this.snp_txn_ctr;
    this.snp_txn_ctr = txn_id_t'(this.snp_txn_ctr + txn_id_t'(1));
    return t;
  endfunction

  // ---------------------------------------------------------------------------
  // Acquire one outbound SNP send credit for the RN-facing port.
  // ---------------------------------------------------------------------------
  protected task wait_rn_snp_send_credit(input int k);
    forever begin
      if (this.rn_snp_send_mgr[k].try_acquire_credit()) begin
        break;
      end
      @(this.vif_rn[k].g_drv.hnf_cb);
      this.drive_rn_idle_sideband(k);
    end
  endtask

  // ---------------------------------------------------------------------------
  // Originate one snoop toward RN-F port k and collect its SnpResp. Blocking:
  // the serial engine drives the snoop, then waits for the matching response
  // before completing the requester. The snooped RN-F answers on an independent
  // thread, so this never wedges (its credit was granted at activation).
  // ---------------------------------------------------------------------------
  // Send one snoop flit toward RN-F port k, returning the allocated snoop TxnID.
  // For a forwarding (DCT) snoop, fwd_nid/fwd_txn carry the requester's SrcID/TxnID
  // so the snoopee can address the forwarded data; non-fwd snoops pass '0 (the
  // flit is zero-initialised, so those fields stay 0 -- byte-identical to before).
  protected task send_snoop_flit(input int k, input addr_t line, input snp_opcode_t op,
                                 input node_id_t fwd_nid, input txn_id_t fwd_txn,
                                 output txn_id_t snp_txn);
    snp_flit_t flit;

    snp_txn = this.alloc_snp_txn();

    flit          = '0;
    flit.opcode   = op;
    flit.addr     = line;
    flit.txnid    = snp_txn;
    flit.srcid    = node_id_t'(0);   // matched by TxnID + port; SrcID is nominal
    flit.fwdnid   = fwd_nid;
    flit.fwdtxnid = fwd_txn;

    this.wait_rn_snp_send_credit(k);

    this.announce_rn_flit(k, ANNOUNCE_SNP_E);
    @(this.vif_rn[k].g_drv.hnf_cb);
    this.drive_rn_idle_sideband(k);
    this.vif_rn[k].g_drv.hnf_cb.txsactive     <= 1'b1;
    this.vif_rn[k].g_drv.hnf_cb.txsnpflitpend  <= 1'b0;
    this.vif_rn[k].g_drv.hnf_cb.txsnpflit      <= flit;
    this.vif_rn[k].g_drv.hnf_cb.txsnpflitv     <= 1'b1;

    @(this.vif_rn[k].g_drv.hnf_cb);
    this.drive_rn_idle_sideband(k);
    this.vif_rn[k].g_drv.hnf_cb.txsnpflitv     <= 1'b0;
    this.vif_rn[k].g_drv.hnf_cb.txsnpflit      <= '0;
  endtask

  protected task drive_snoop(input int k, input addr_t line, input snp_opcode_t op);
    txn_id_t snp_txn;
    this.send_snoop_flit(k, line, op, node_id_t'(0), txn_id_t'(0), snp_txn);
    this.collect_snp_response(k, snp_txn, line);
  endtask

  // ---------------------------------------------------------------------------
  // Collect the response to the originated snoop on port k. A clean snoopee
  // answers with a no-data SnpResp on RSP; a dirty snoopee forwards its modified
  // line as SnpRespData on DAT (PassDirty). For the dirty case the home merges
  // the beats into its memory at collection time, so it becomes the authority
  // and the requester's CompData (sourced from memory) carries the dirty data.
  // ---------------------------------------------------------------------------
  protected task collect_snp_response(input int k, input txn_id_t snp_txn, input addr_t line);
    rsp_flit_t           rflit;
    dat_flit_t           dflit;
    vip_chi_dat_opcode_t dop;

    forever begin
      // Our dirty response is SnpRespData / SnpRespDataPtl on DAT, carrying the
      // snoop TxnID. Any OTHER DAT flit on this port belongs to a concurrent
      // transaction (P4: e.g. a CopyBackWrData writeback beat) -- tolerate it by
      // returning its credit and stepping past, rather than mis-merging it into
      // this line's memory or fataling on the TxnID mismatch. Unreachable while
      // the response engine is serial (one transaction in flight at a time); this
      // is robustness for a future per-line-parallel engine.
      if (this.vif_rn[k].g_drv.hnf_cb.rxdatflitv) begin
        dflit = this.vif_rn[k].g_drv.hnf_cb.rxdatflit;
        dop   = vip_chi_dat_opcode_t'(dflit.opcode);
        if (((dop == vip_chi_dat_opcode_t'(VIP_CHI_DAT_SNP_RESP_DATA_C)) ||
             (dop == vip_chi_dat_opcode_t'(VIP_CHI_DAT_SNP_RESP_DATA_PTL_C))) &&
            (txn_id_t'(dflit.txnid) == snp_txn)) begin
          this.collect_snp_resp_data(k, snp_txn, line);
          break;
        end

        // The serial response engine expects only this snoop's response on the
        // RN-facing DAT channel here. A non-matching flit means per-line
        // concurrency was added without per-TxnID routing -- fatal loudly rather
        // than silently drop it (which would lose a real transaction's data).
        // Unreachable today; when a parallel engine lands, route/queue by
        // channel + TxnID instead of removing this guard. [F5]
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] port %0d: unexpected DAT (opcode 0x%0h TxnID 0x%0h) while awaiting SnpResp for snoop TxnID 0x%0h -- concurrent-transaction flit with no per-TxnID routing (F5)",
          get_name(), k, dflit.opcode, dflit.txnid, snp_txn))
      end

      // A clean snoopee answers with SnpResp on RSP, carrying the snoop TxnID.
      if (this.vif_rn[k].g_drv.hnf_cb.rxrspflitv) begin
        rflit = this.vif_rn[k].g_drv.hnf_cb.rxrspflit;
        this.rn_rsp_lcrdv_pending[k] += 1;

        if ((vip_chi_rsp_opcode_t'(rflit.opcode) == vip_chi_rsp_opcode_t'(VIP_CHI_RSP_SNP_RESP_C)) &&
            (txn_id_t'(rflit.txnid) == snp_txn)) begin
          @(this.vif_rn[k].g_drv.hnf_cb);
          this.drive_rn_idle_sideband(k);
          break;
        end

        // Non-matching RSP on the RN-facing channel while awaiting SnpResp. As on
        // the DAT path above, the serial engine never legitimately sees this;
        // fatal rather than silently drop a concurrent transaction's flit. When a
        // parallel engine lands, route/queue by channel + TxnID. [F5]
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] port %0d: unexpected RSP (opcode 0x%0h TxnID 0x%0h) while awaiting SnpResp for snoop TxnID 0x%0h -- concurrent-transaction flit with no per-TxnID routing (F5)",
          get_name(), k, rflit.opcode, rflit.txnid, snp_txn))
      end

      @(this.vif_rn[k].g_drv.hnf_cb);
      this.drive_rn_idle_sideband(k);
    end
  endtask

  // ---------------------------------------------------------------------------
  // Collect a multi-beat SnpRespData burst (positioned on its first valid beat),
  // returning DAT receive credit per beat, then merge the dirty beats into the
  // backing memory so the home holds the authoritative post-snoop data.
  // ---------------------------------------------------------------------------
  protected task collect_snp_resp_data(input int k, input txn_id_t snp_txn, input addr_t line);
    dat_flit_t flit;
    data_t     data_q [$];
    be_t       be_q   [$];
    bit        last_beat;
    int        expected_beats;

    expected_beats = vip_chi_types_pkg::chi_xfer_dat_beats(size_t'(3'd6), CFG_P.DATA_BYTES_P);

    for (int beat_index = 0; beat_index < expected_beats; beat_index++) begin
      while (!this.vif_rn[k].g_drv.hnf_cb.rxdatflitv) begin
        @(this.vif_rn[k].g_drv.hnf_cb);
        this.drive_rn_idle_sideband(k);
      end

      flit = this.vif_rn[k].g_drv.hnf_cb.rxdatflit;
      this.rn_dat_lcrdv_pending[k] += 1;

      if (txn_id_t'(flit.txnid) != snp_txn) begin
        `uvm_fatal(get_name(), $sformatf(
	          "FATAL [%s] port %0d: SnpRespData TxnID 0x%0h != snoop TxnID 0x%0h",
	          get_name(), k, flit.txnid, snp_txn))
      end

      if (txn_id_t'(flit.dbid) != snp_txn) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] port %0d: SnpRespData DBID 0x%0h != snoop TxnID 0x%0h",
          get_name(), k, flit.dbid, snp_txn))
      end

      if (dat_opcode_t'(flit.opcode) != dat_opcode_t'(VIP_CHI_DAT_SNP_RESP_DATA_C)) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] port %0d: SnpRespData opcode 0x%0h != expected 0x%0h",
          get_name(), k, flit.opcode, dat_opcode_t'(VIP_CHI_DAT_SNP_RESP_DATA_C)))
      end

      if (data_id_t'(flit.dataid) != data_id_t'(beat_index)) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] port %0d: SnpRespData DataID %0d != expected %0d",
          get_name(), k, flit.dataid, beat_index))
      end

      data_q.push_back(data_t'(flit.data));
      be_q.push_back(be_t'(flit.be));
      last_beat = !this.vif_rn[k].g_drv.hnf_cb.rxdatflitpend;

      if (last_beat != (beat_index == (expected_beats - 1))) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] port %0d: SnpRespData burst ended at beat %0d with expected_beats=%0d (pend=%0b)",
          get_name(), k, beat_index, expected_beats,
          this.vif_rn[k].g_drv.hnf_cb.rxdatflitpend))
      end

      // Step off this beat.
      @(this.vif_rn[k].g_drv.hnf_cb);
      this.drive_rn_idle_sideband(k);
    end

    // Memory takes the forwarded dirty data as authority. The negative-control
    // knob drops the merge so the requester is completed from stale memory,
    // breaking coherent data integrity on purpose.
    if (!this.cfg.hnf_corrupt_dirty_merge) begin
      this.mem.wr_be(line, data_q, be_q);
      foreach (data_q[i]) begin
        this.mark_backing_row(line + addr_t'(i * CFG_P.DATA_BYTES_P));
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  // Serve a coherent read: return CompData carrying the granted state, and
  // record the requester's new ownership in the directory (for M3 snoops).
  // ---------------------------------------------------------------------------
  protected task drive_coherent_read_compdata(
    input int            p,
    input req_flit_t     req,
    input vip_chi_resp_t gstate,
    input bit            excl_okay = 1'b0
  );
    dat_flit_t     flit;
    addr_t         req_addr;
    node_id_t      req_src_id;
    node_id_t      req_tgt_id;
    txn_id_t       req_txn_id;
    size_t         req_size;
    int            beat_count;

    req_addr   = addr_t'(req.addr);
    req_src_id = node_id_t'(req.srcid);
    req_tgt_id = node_id_t'(req.tgtid);
    req_txn_id = txn_id_t'(req.txnid);
    req_size   = size_t'(req.size);
    beat_count = vip_chi_types_pkg::chi_xfer_dat_beats(req_size, CFG_P.DATA_BYTES_P);

    for (int beat_index = 0; beat_index < beat_count; beat_index++) begin
      flit            = '0;
      flit.data       = this.read_data_beat(req_addr, beat_index);
      flit.be         = '1;
      flit.dataid     = data_id_t'(beat_index);
      flit.ccid       = cc_id_t'(0);
      flit.dbid       = req_txn_id;
      flit.resp       = gstate;
      // ExclOkay on the exclusive-load completion tells the RN-F the home set its
      // monitor; a non-exclusive read passes excl_okay=0 -> NormalOkay (unchanged).
      flit.resperr    = excl_okay ? VIP_CHI_RESP_ERR_EXCLUSIVE_OKAY_E
                                  : VIP_CHI_RESP_ERR_NORMAL_OKAY_E;
      flit.opcode     = item_t::dat_opcode_t'(VIP_CHI_DAT_COMP_DATA_C);
      flit.homenid    = req_tgt_id;
      flit.txnid      = req_txn_id;
      flit.srcid      = req_tgt_id;
      flit.tgtid      = req_src_id;
      flit.qos        = req.qos;

      this.wait_rn_dat_send_credit(p);

      this.announce_rn_flit(p, ANNOUNCE_DAT_E);
      @(this.vif_rn[p].g_drv.hnf_cb);
      this.drive_rn_idle_sideband(p);
      this.vif_rn[p].g_drv.hnf_cb.txsactive     <= 1'b1;
      this.vif_rn[p].g_drv.hnf_cb.txdatflitpend  <= (beat_index != (beat_count - 1));
      this.vif_rn[p].g_drv.hnf_cb.txdatflit      <= flit;
      this.vif_rn[p].g_drv.hnf_cb.txdatflitv     <= 1'b1;

      @(this.vif_rn[p].g_drv.hnf_cb);
      this.drive_rn_idle_sideband(p);
      this.vif_rn[p].g_drv.hnf_cb.txdatflitpend  <= 1'b0;
      this.vif_rn[p].g_drv.hnf_cb.txdatflitv     <= 1'b0;
      this.vif_rn[p].g_drv.hnf_cb.txdatflit      <= '0;
    end

    @(this.vif_rn[p].g_drv.hnf_cb);
    this.drive_rn_idle_sideband(p);
    this.vif_rn[p].g_drv.hnf_cb.txsactive <= 1'b0;
  endtask

  // ---------------------------------------------------------------------------
  // Serve a coherent read via direct cache transfer (DCT). Issue a forwarding
  // snoop to the single peer holder fwd_k carrying FwdNID/FwdTxnID = the
  // requester; the snoopee answers with a SnpRespDataFwded burst (its held data).
  // The home merges those beats into memory (authoritative) AND relays them to
  // the requester as CompData -- sourced from the forwarded data, NOT re-read from
  // memory, which is the DCT invariant the checker/negctl asserts. The requester
  // ends in the granted state; the snoopee downgrades (shared fwd) or invalidates
  // (unique fwd) per snoop_next_state, tracked in the directory.
  // ---------------------------------------------------------------------------
  protected task service_coherent_read_fwd(
    input int                          p,
    input req_flit_t                   req,
    input addr_t                       line,
    input int                          fwd_k,
    input bit                          is_unique,
    input logic [N_RNF_PORTS-1:0][2:0] entry_in
  );
    logic [N_RNF_PORTS-1:0][2:0] entry;
    vip_chi_resp_t               granted;
    vip_chi_resp_t               snoopee_next;
    snp_opcode_t                 fwd_op;
    txn_id_t                     snp_txn;
    data_t                       fwd_beats [$];

    entry        = entry_in;
    granted      = is_unique ? this.cfg.coh_read_unique_state
                             : this.cfg.coh_read_shared_state;
    fwd_op       = this.snoop_for(req_opcode_t'(req.opcode), 1'b1);
    snoopee_next = is_unique ? VIP_CHI_RESP_STATE_I_E
                             : VIP_CHI_RESP_STATE_SC_E;

    // Issue the forwarding snoop; then collect the forwarded burst and relay it.
    this.send_snoop_flit(fwd_k, line, fwd_op,
                         node_id_t'(req.srcid), txn_id_t'(req.txnid), snp_txn);
    this.collect_fwd_resp_data(fwd_k, snp_txn, line, fwd_beats);
    this.drive_relayed_compdata(p, req, granted, fwd_beats);

    // Resolve the directory: requester granted, snoopee downgraded/invalidated.
    // A unique fwd that invalidates the peer also breaks its exclusive monitor.
    // The requester's entry is the join, not the grant -- Table 4-14 footnote b,
    // as in service_coherent_read above.
    entry[fwd_k] = snoopee_next;
    entry[p]     = vip_chi_req_final_state(vip_chi_req_opcode_t'(req.opcode),
                                           vip_chi_resp_t'(entry[p]), granted);
    this.directory[line] = entry;
    if ((snoopee_next == VIP_CHI_RESP_STATE_I_E) && this.excl_monitor.exists(line)) begin
      this.excl_monitor[line][fwd_k] = 1'b0;
    end
  endtask

  // ---------------------------------------------------------------------------
  // Collect a SnpRespDataFwded burst from port k (matched by snoop TxnID),
  // returning DAT receive credit per beat, into data_q. Merges the (uncorrupted)
  // beats into memory so the home stays authoritative after the forward; the
  // caller relays a (possibly corrupted) copy to the requester.
  // ---------------------------------------------------------------------------
  protected task collect_fwd_resp_data(input int k, input txn_id_t snp_txn,
                                       input addr_t line, ref data_t data_out [$]);
    dat_flit_t flit;
    data_t     data_q [$];
    be_t       be_q   [$];
    bit        last_beat;
    int        expected_beats;

    expected_beats = vip_chi_types_pkg::chi_xfer_dat_beats(size_t'(3'd6), CFG_P.DATA_BYTES_P);

    for (int beat_index = 0; beat_index < expected_beats; beat_index++) begin
      while (!this.vif_rn[k].g_drv.hnf_cb.rxdatflitv) begin
        @(this.vif_rn[k].g_drv.hnf_cb);
        this.drive_rn_idle_sideband(k);
      end

      flit = this.vif_rn[k].g_drv.hnf_cb.rxdatflit;
      this.rn_dat_lcrdv_pending[k] += 1;

      if (txn_id_t'(flit.txnid) != snp_txn) begin
        `uvm_fatal(get_name(), $sformatf(
	          "FATAL [%s] port %0d: SnpRespDataFwded TxnID 0x%0h != snoop TxnID 0x%0h",
	          get_name(), k, flit.txnid, snp_txn))
      end

      if (txn_id_t'(flit.dbid) != snp_txn) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] port %0d: SnpRespDataFwded DBID 0x%0h != snoop TxnID 0x%0h",
          get_name(), k, flit.dbid, snp_txn))
      end

      if (dat_opcode_t'(flit.opcode) != dat_opcode_t'(VIP_CHI_DAT_SNP_RESP_DATA_FWDED_C)) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] port %0d: SnpRespDataFwded opcode 0x%0h != expected 0x%0h",
          get_name(), k, flit.opcode, dat_opcode_t'(VIP_CHI_DAT_SNP_RESP_DATA_FWDED_C)))
      end

      if (data_id_t'(flit.dataid) != data_id_t'(beat_index)) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] port %0d: SnpRespDataFwded DataID %0d != expected %0d",
          get_name(), k, flit.dataid, beat_index))
      end

      data_q.push_back(data_t'(flit.data));
      be_q.push_back(be_t'(flit.be));
      last_beat = !this.vif_rn[k].g_drv.hnf_cb.rxdatflitpend;

      if (last_beat != (beat_index == (expected_beats - 1))) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] port %0d: SnpRespDataFwded burst ended at beat %0d with expected_beats=%0d (pend=%0b)",
          get_name(), k, beat_index, expected_beats,
          this.vif_rn[k].g_drv.hnf_cb.rxdatflitpend))
      end

      @(this.vif_rn[k].g_drv.hnf_cb);
      this.drive_rn_idle_sideband(k);
    end

    // Home memory takes the forwarded data as authority (same as the non-fwd dirty
    // path). The relayed CompData is driven from data_out by the caller, so a
    // corrupt-fwd negative control can diverge the requester's copy from memory.
    this.mem.wr_be(line, data_q, be_q);
    foreach (data_q[i]) begin
      this.mark_backing_row(line + addr_t'(i * CFG_P.DATA_BYTES_P));
    end

    data_out = data_q;
  endtask

  // ---------------------------------------------------------------------------
  // Relay a forwarded burst to the requester (port p) as CompData, sourced from
  // the forwarded beats rather than home memory (the DCT data path). The
  // hnf_corrupt_fwd_data negative-control knob inverts the relayed beats so the
  // requester's data diverges from the authoritative (memory / checker-shadow)
  // copy, which Checker D's forwarded-data integrity check must catch.
  // ---------------------------------------------------------------------------
  protected task drive_relayed_compdata(
    input int            p,
    input req_flit_t     req,
    input vip_chi_resp_t gstate,
    input data_t         beats [$]
  );
    dat_flit_t flit;
    node_id_t  req_src_id;
    node_id_t  req_tgt_id;
    txn_id_t   req_txn_id;
    int        beat_count;

    req_src_id = node_id_t'(req.srcid);
    req_tgt_id = node_id_t'(req.tgtid);
    req_txn_id = txn_id_t'(req.txnid);
    beat_count = beats.size();

    for (int beat_index = 0; beat_index < beat_count; beat_index++) begin
      flit         = '0;
      flit.data    = this.cfg.hnf_corrupt_fwd_data ? ~beats[beat_index]
                                                   :  beats[beat_index];
      flit.be      = '1;
      flit.dataid  = data_id_t'(beat_index);
      flit.ccid    = cc_id_t'(0);
      flit.dbid    = req_txn_id;
      flit.resp    = gstate;
      flit.resperr = VIP_CHI_RESP_ERR_NORMAL_OKAY_E;
      flit.opcode  = item_t::dat_opcode_t'(VIP_CHI_DAT_COMP_DATA_C);
      flit.homenid = req_tgt_id;
      flit.txnid   = req_txn_id;
      flit.srcid   = req_tgt_id;
      flit.tgtid   = req_src_id;
      flit.qos     = req.qos;

      this.wait_rn_dat_send_credit(p);

      this.announce_rn_flit(p, ANNOUNCE_DAT_E);
      @(this.vif_rn[p].g_drv.hnf_cb);
      this.drive_rn_idle_sideband(p);
      this.vif_rn[p].g_drv.hnf_cb.txsactive     <= 1'b1;
      this.vif_rn[p].g_drv.hnf_cb.txdatflitpend  <= (beat_index != (beat_count - 1));
      this.vif_rn[p].g_drv.hnf_cb.txdatflit      <= flit;
      this.vif_rn[p].g_drv.hnf_cb.txdatflitv     <= 1'b1;

      @(this.vif_rn[p].g_drv.hnf_cb);
      this.drive_rn_idle_sideband(p);
      this.vif_rn[p].g_drv.hnf_cb.txdatflitpend  <= 1'b0;
      this.vif_rn[p].g_drv.hnf_cb.txdatflitv     <= 1'b0;
      this.vif_rn[p].g_drv.hnf_cb.txdatflit      <= '0;
    end

    @(this.vif_rn[p].g_drv.hnf_cb);
    this.drive_rn_idle_sideband(p);
    this.vif_rn[p].g_drv.hnf_cb.txsactive <= 1'b0;
  endtask

  // ---------------------------------------------------------------------------
  // Test/scoreboard accessor: aggregate directory state for a line (a unique
  // holder dominates, else shared if any port holds it, else Invalid).
  // ---------------------------------------------------------------------------
  function vip_chi_resp_t get_directory_state(input addr_t addr);
    addr_t                       line;
    logic [N_RNF_PORTS-1:0][2:0] entry;
    vip_chi_resp_t               st;
    vip_chi_resp_t               agg;

    line = this.line_addr(addr);
    if (!this.directory.exists(line)) begin
      return VIP_CHI_RESP_STATE_I_E;
    end

    entry = this.directory[line];
    agg   = VIP_CHI_RESP_STATE_I_E;
    for (int k = 0; k < N_RNF_PORTS; k++) begin
      st = vip_chi_resp_t'(entry[k]);
      if ((st == VIP_CHI_RESP_STATE_UC_E) || (st == VIP_CHI_RESP_STATE_UP_PD_DIRTY_E)) begin
        return st;
      end
      if (st == VIP_CHI_RESP_STATE_SC_E) begin
        agg = VIP_CHI_RESP_STATE_SC_E;
      end
    end
    return agg;
  endfunction

  // ---------------------------------------------------------------------------
  // Test/scoreboard accessor: per-port directory state for a line.
  // ---------------------------------------------------------------------------
  function vip_chi_resp_t get_directory_port_state(input addr_t addr, input int port);
    addr_t line;

    line = this.line_addr(addr);
    if (!this.directory.exists(line)) begin
      return VIP_CHI_RESP_STATE_I_E;
    end
    return vip_chi_resp_t'(this.directory[line][port]);
  endfunction

endclass

`endif
