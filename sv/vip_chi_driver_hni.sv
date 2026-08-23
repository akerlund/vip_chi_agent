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

`ifndef VIP_CHI_DRIVER_HNI
`define VIP_CHI_DRIVER_HNI

import uvm_pkg::*;
`include "uvm_macros.svh"
import vip_chi_types_pkg::*;

// -----------------------------------------------------------------------------
// HN-I pass-through ordering proxy (multi-RN fan-in x multi-SN fan-out).
//
// A home node sits between one or more RNs and one or more SN targets:
//
//   RN[0..N_RN_PORTS-1] <==(RN-facing)==> HN-I <==(SN-facing)==> SN[0..N_SN_PORTS-1]
//
// On each RN-facing link the HN-I plays the completer/subordinate (receives REQ,
// sources RSP/DAT), exposed via ROLE_P=HNI interfaces whose `hni_cb` clocking
// mirrors the SN-F polarity. On each SN-facing link it plays the requester
// (sends REQ, receives RSP/DAT) via ROLE_P=RNI interfaces (`rni_cb`).
//
// Pure per-flit relay (whole flit structs forwarded verbatim -> transaction- and
// CHI-D/E-agnostic, no TxnID remap). Routing, all stateless-per-transaction:
//   * REQ (RN->SN): pick an RN port round-robin, decode the request ADDRESS to
//     an SN port, forward there. Records active_sn_of_rn[p] (which SN this RN is
//     currently talking to) and port_of_node[srcid] (which RN sourced this node
//     id, for the return path).
//   * CompAck-RSP / write-DAT (RN->SN): follow active_sn_of_rn[p]. Because every
//     RN is serial (one outstanding), that association is stable for the whole
//     transaction, so no per-TxnID table is needed.
//   * completion-RSP / read-DAT (SN->RN): scan the SN ports and route each flit
//     to the RN port by tgtid (= the originating RN srcid) via port_of_node.
//
// Flow control is strictly lock-step per channel (grant one credit, return the
// next only after forwarding), so a single-threaded relay is never outrun on a
// burst; forwarding is serial. N_SN_PORTS=1 collapses the address decode to a
// constant, so the single-SN fan-in / 1x1 proxy are exact special cases.
// -----------------------------------------------------------------------------
class vip_chi_driver_hni #(
  vip_chi_cfg_t  CFG_P        = VIP_CHI_DEFAULT_CFG_C,
  type           FLIT_TYPES_T = vip_chi_types #(CFG_P),
  int            N_RN_PORTS   = 1,
  int            N_SN_PORTS   = 1
  ) extends uvm_component;

  typedef vip_chi_types #(CFG_P)::node_id_t node_id_t;
  typedef vip_chi_types #(CFG_P)::addr_t    addr_t;
  typedef FLIT_TYPES_T::vip_chi_req_flit_t  req_flit_t;
  typedef FLIT_TYPES_T::vip_chi_dat_flit_t  dat_flit_t;
  typedef FLIT_TYPES_T::vip_chi_rsp_flit_t  rsp_flit_t;

  // RN-facing interfaces (completer, SN-F polarity via ROLE_P=HNI), one per RN.
  virtual vip_chi_if #(CFG_P, FLIT_TYPES_T, VIP_CHI_ROLE_HNI_E) vif_rn [N_RN_PORTS];

  // SN-facing interfaces (requester, RN-I polarity), one per SN target.
  virtual vip_chi_if #(CFG_P, FLIT_TYPES_T, VIP_CHI_ROLE_RNI_E) vif_sn [N_SN_PORTS];
  vip_chi_cfg_agent                                            cfg;

  // Address-decode control. When `sam` is set, the request address is routed via
  // the configurable [base:limit] -> SN-port table (production form). Otherwise
  // the driver falls back to the minimal deterministic stride
  // sn_port = (addr >> sn_addr_lsb) % N_SN_PORTS.
  vip_chi_hni_sam sam;
  int unsigned    sn_addr_lsb = 12;

  // QoS arbitration collection window (cycles). When the forwarder goes idle and
  // the first REQ appears, it waits this many cycles for other RN ports to also
  // present a REQ before choosing the highest-QoS one. Default 0 preserves the
  // pick-immediately behavior; a non-zero window makes multi-port QoS ordering
  // deterministic when requestors present nearly simultaneously.
  int unsigned arb_window_cycles = 0;

  // Per-RN send-side budgets (HN -> RN).
  // Last cycle's value of this proxy's OWN transmit-link request on each
  // RN-facing port, so the acknowledge can be held one cycle past it on the way
  // down. See drive_rn_idle_sideband.

  protected vip_chi_lcrd_mgr rn_rsp_send_mgr [N_RN_PORTS];
  protected vip_chi_lcrd_mgr rn_dat_send_mgr [N_RN_PORTS];

  // Per-SN send-side budgets (HN -> SN).
  protected vip_chi_lcrd_mgr sn_req_send_mgr [N_SN_PORTS];
  protected vip_chi_lcrd_mgr sn_rsp_send_mgr [N_SN_PORTS];
  protected vip_chi_lcrd_mgr sn_dat_send_mgr [N_SN_PORTS];

  // Per-RN inbound receive-credit grants.
  protected int unsigned rn_req_lcrdv_pending [N_RN_PORTS];
  protected int unsigned rn_rsp_lcrdv_pending [N_RN_PORTS];
  protected int unsigned rn_dat_lcrdv_pending [N_RN_PORTS];

  // Per-SN inbound receive-credit grants.
  protected int unsigned sn_rsp_lcrdv_pending [N_SN_PORTS];
  protected int unsigned sn_dat_lcrdv_pending [N_SN_PORTS];

  protected bit rn_link_up [N_RN_PORTS];
  protected bit sn_link_up [N_SN_PORTS];


  // Return-path routing: RN srcid -> RN port (learned when the REQ is forwarded).
  protected int port_of_node [longint];

  // SN association: which SN port each RN is currently talking to.
  protected int active_sn_of_rn [N_RN_PORTS];

  // REQ ingress buffers (depth 1 per RN port). A per-port capture latches any
  // arriving REQ (the HN granted the credit, so it must accept it even while the
  // forwarder is busy elsewhere) and holds it until the QoS forwarder drains it.
  protected req_flit_t req_slot    [N_RN_PORTS];
  protected bit        req_pending [N_RN_PORTS];
  protected int        req_qos     [N_RN_PORTS];

  // Single-outstanding transaction gate for QoS-ordered forwarding. active_kind
  // picks which observable event settles the transaction (frees the SN):
  //   READ     -> last CompData beat relayed to the RN
  //   WRITE    -> last write-data beat relayed to the SN for combined
  //               CompDBIDResp writes; for split DBIDResp+Comp writes, both the
  //               final write-data beat and deferred Comp must be observed
  //   RSP_ONLY -> a terminal completion RSP relayed to the RN (persist / zero)
  //   NO_COMP  -> nothing comes back (PrefetchTgt); settled at forward time
  typedef enum int {
    HNI_TXN_READ_E,
    HNI_TXN_WRITE_E,
    HNI_TXN_RSP_ONLY_E,
    HNI_TXN_NO_COMP_E
  } hni_txn_kind_e;

  protected bit            active_busy;
  protected int            active_port;
  protected hni_txn_kind_e active_kind;
  protected bit            active_write_split;
  protected bit            active_write_data_done;
  protected bit            active_write_comp_done;

  // Round-robin cursors.
  protected int qos_rr_cursor;
  protected int rsp_rr_cursor;
  protected int dat_rr_cursor;
  protected int sn_rsp_rr_cursor;
  protected int sn_dat_rr_cursor;

  `uvm_component_param_utils(vip_chi_driver_hni #(CFG_P, FLIT_TYPES_T, N_RN_PORTS, N_SN_PORTS))

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent);
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  // Validate parent-assigned handles: RN-facing vifs on "rn_vif_<i>",
  // SN-facing vifs on "sn_vif_<j>".
  // ---------------------------------------------------------------------------
  function void build_phase(input uvm_phase phase);

    super.build_phase(phase);

    foreach (this.vif_rn[i]) begin

      if (!uvm_config_db #(virtual vip_chi_if #(CFG_P, FLIT_TYPES_T, VIP_CHI_ROLE_HNI_E))::get(
            this, "", $sformatf("rn_vif_%0d", i), this.vif_rn[i])) begin

              `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-facing driver.rn_vif_%0d must be assigned by the parent",
        get_name(), i))
      end
    end

    foreach (this.vif_sn[j]) begin

      if (!uvm_config_db #(virtual vip_chi_if #(CFG_P, FLIT_TYPES_T, VIP_CHI_ROLE_RNI_E))::get(
            this, "", $sformatf("sn_vif_%0d", j), this.vif_sn[j])) begin

              `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] SN-facing driver.sn_vif_%0d must be assigned by the parent",
        get_name(), j))
      end
    end

    if (this.cfg == null) begin

      this.cfg      = vip_chi_cfg_agent::type_id::create("default_cfg");
      this.cfg.role = VIP_CHI_ROLE_HNI_E;
    end

    this.reset_credit_state();
  endfunction

  // ---------------------------------------------------------------------------
  // (Re)build the credit managers and clear the inbound grant queues + routing.
  // ---------------------------------------------------------------------------
  protected function void reset_credit_state();

    foreach (this.vif_rn[i]) begin

      if (this.rn_rsp_send_mgr[i] == null) begin
        this.rn_rsp_send_mgr[i] = vip_chi_lcrd_mgr::type_id::create($sformatf("rn_rsp_send_mgr_%0d", i));
      end

      if (this.rn_dat_send_mgr[i] == null) begin
        this.rn_dat_send_mgr[i] = vip_chi_lcrd_mgr::type_id::create($sformatf("rn_dat_send_mgr_%0d", i));
      end

      this.rn_rsp_send_mgr[i].reset(this.cfg.rsp_send_credit_cap, 0);
      this.rn_dat_send_mgr[i].reset(this.cfg.dat_send_credit_cap, 0);

      this.rn_req_lcrdv_pending[i] = 0;
      this.rn_rsp_lcrdv_pending[i] = 0;
      this.rn_dat_lcrdv_pending[i] = 0;
      this.rn_link_up[i]           = 1'b0;
      this.active_sn_of_rn[i]      = 0;
    end

    foreach (this.vif_sn[j]) begin

      if (this.sn_req_send_mgr[j] == null) begin
        this.sn_req_send_mgr[j] = vip_chi_lcrd_mgr::type_id::create($sformatf("sn_req_send_mgr_%0d", j));
      end

      if (this.sn_rsp_send_mgr[j] == null) begin
        this.sn_rsp_send_mgr[j] = vip_chi_lcrd_mgr::type_id::create($sformatf("sn_rsp_send_mgr_%0d", j));
      end

      if (this.sn_dat_send_mgr[j] == null) begin
        this.sn_dat_send_mgr[j] = vip_chi_lcrd_mgr::type_id::create($sformatf("sn_dat_send_mgr_%0d", j));
      end

      this.sn_req_send_mgr[j].reset(this.cfg.req_send_credit_cap, 0);
      this.sn_rsp_send_mgr[j].reset(this.cfg.rsp_send_credit_cap, 0);
      this.sn_dat_send_mgr[j].reset(this.cfg.dat_send_credit_cap, 0);
      this.sn_rsp_lcrdv_pending[j] = 0;
      this.sn_dat_lcrdv_pending[j] = 0;
      this.sn_link_up[j]           = 1'b0;
    end

    foreach (this.req_pending[i]) begin

      this.req_pending[i] = 1'b0;
      this.req_qos[i]     = 0;
    end

    this.active_busy = 1'b0;
    this.active_port = 0;
    this.active_kind = HNI_TXN_READ_E;
    this.active_write_split     = 1'b0;
    this.active_write_data_done = 1'b0;
    this.active_write_comp_done = 1'b0;

    this.port_of_node.delete();
    this.qos_rr_cursor    = 0;
    this.rsp_rr_cursor    = 0;
    this.dat_rr_cursor    = 0;
    this.sn_rsp_rr_cursor = 0;
    this.sn_dat_rr_cursor = 0;
  endfunction

  // ---------------------------------------------------------------------------
  // Idle sidebands (mirror each peer's link-activation request onto our ack).
  // ---------------------------------------------------------------------------
  // The proxy transmits RSP and DAT toward each RN, so those channels are its
  // TXLINK on that port and IHI 0050 E 14.6.1 / D 13.6.1 makes their state
  // "controlled by" this component -- it has to ask for the link. Until now
  // txlinkactivereq was written in exactly one place on this port, as 1'b0 in
  // reset_outputs. The SN-facing port already does this correctly, which is what
  // made the omission easy to miss: the same driver gets it right one direction
  // over.
  //
  // 14.6.3 / D 13.6.3 orders the two outputs -- the acknowledge may not assert
  // before the request, nor deassert before it. The acknowledge here lags the
  // request by exactly one cycle in BOTH directions, which satisfies both.
  protected task drive_rn_idle_sideband(input int p);

    bit want_link;

    want_link = this.vif_rn[p].g_drv.hni_cb.rxlinkactivereq;

    // 14.6.3's fourth ordering binds US, not the peer: "the deassertion of TXREQ
    // must not occur before the assertion of RXACK". The acknowledge lags the
    // request by one cycle by construction, so a request held for only ONE cycle
    // is withdrawn before its own acknowledge has risen -- which breaks that
    // ordering and then, a cycle later, the first one as the acknowledge rises
    // against a request that is already down. Reachable whenever the peer
    // withdraws its request the cycle after raising it, which
    // tc_chi_lasm_illegal_transition does on purpose. Table 14-2 says the same
    // thing from the state machine's side: the transmitter "remains in the
    // ACTIVATE state while it is waiting for the receiver to acknowledge".
    //
    // Holding the request until our own acknowledge is up is the minimum that
    // satisfies the section, and it cannot stall -- the acknowledge IS this
    // request, one cycle later.
    if (this.vif_rn[p].txlinkactivereq && !this.vif_rn[p].txlinkactiveack) begin
      want_link = 1'b1;
    end

    this.vif_rn[p].g_drv.hni_cb.txlinkactivereq <= want_link;
    // The acknowledge is a ONE-CYCLE DELAY of our own request, off the wire: the
    // drive is non-blocking, so a wire read carries last cycle's value and the
    // acknowledge lands exactly one cycle behind the request in both directions.
    // Reading only wires is what makes it independent of how many threads call
    // this in one cycle.
    this.vif_rn[p].g_drv.hni_cb.txlinkactiveack <=
      this.vif_rn[p].txlinkactivereq;

  endtask

  // Ordered against our OWN request rather than mirrored, now that the SN raises
  // one. IHI 0050 E 14.6.3 / D 13.6.3: "the assertion of RXACK must not occur
  // before the assertion of TXREQ", and the deassertion likewise. Mirroring was
  // safe only while the peer's request was identically zero.
  protected task drive_sn_idle_sideband(input int s);
    this.vif_sn[s].g_drv.rni_cb.txlinkactiveack <=
      this.vif_sn[s].g_drv.rni_cb.rxlinkactivereq;
  endtask

  // ---------------------------------------------------------------------------
  // Drive every proxy output back to the idle state.
  // ---------------------------------------------------------------------------
  protected function void reset_outputs();
    foreach (this.vif_rn[p]) begin
      this.vif_rn[p].g_drv.hni_cb.txlinkactivereq <= 1'b0;
      this.vif_rn[p].g_drv.hni_cb.txlinkactiveack <= 1'b0;
      this.vif_rn[p].g_drv.hni_cb.txsactive       <= 1'b0;
      this.vif_rn[p].g_drv.hni_cb.txreqlcrdv      <= 1'b0;
      this.vif_rn[p].g_drv.hni_cb.txrspflitpend   <= 1'b0;
      this.vif_rn[p].g_drv.hni_cb.txrspflitv      <= 1'b0;
      this.vif_rn[p].g_drv.hni_cb.txrspflit       <= '0;
      this.vif_rn[p].g_drv.hni_cb.txrsplcrdv      <= 1'b0;
      this.vif_rn[p].g_drv.hni_cb.txdatflitpend   <= 1'b0;
      this.vif_rn[p].g_drv.hni_cb.txdatflitv      <= 1'b0;
      this.vif_rn[p].g_drv.hni_cb.txdatflit       <= '0;
      this.vif_rn[p].g_drv.hni_cb.txdatlcrdv      <= 1'b0;
    end

    foreach (this.vif_sn[s]) begin
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
  endfunction

  // ---------------------------------------------------------------------------
  // Public reset hooks driven by the parent's single rst_n watcher.
  // ---------------------------------------------------------------------------
  function void reset_vif();
    this.reset_outputs();
  endfunction

  function void handle_reset();
    this.reset_credit_state();
    this.reset_outputs();
  endfunction

  // ---------------------------------------------------------------------------
  // run_phase is intentionally empty: the parent owns the rst_n watcher.
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);
  endtask

  // ---------------------------------------------------------------------------
  // Address decode -> SN port.
  // ---------------------------------------------------------------------------
  protected function int sn_port_of_addr(input addr_t addr);

    int s;

    if (N_SN_PORTS <= 1) begin
      return 0;
    end

    if (this.sam != null) begin

      s = this.sam.lookup(longint'(addr));

      if ((s < 0) || (s >= N_SN_PORTS)) begin

        `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] SAM routed addr 0x%0h to SN port %0d, out of range [0:%0d]",
        get_name(), addr, s, N_SN_PORTS - 1))
      end
      return s;
    end

    return int'((longint'(addr) >> this.sn_addr_lsb) % N_SN_PORTS);
  endfunction

  // ---------------------------------------------------------------------------
  // Main proxy loop: per-RN and per-SN credit/link loops + activation, the three
  // SN-side arbiters, and the two SN->RN routers.
  // ---------------------------------------------------------------------------
  task driver_start();

    fork
      this.qos_forwarder();
      this.arbiter_rsp_rn_to_sn();
      this.arbiter_dat_rn_to_sn();
      this.router_rsp_sn_to_rn();
      this.router_dat_sn_to_rn();
    join_none

    for (int p = 0; p < N_RN_PORTS; p++) begin

      automatic int lp = p;

      fork
        this.rn_credit_loop(lp);
        this.rn_activate(lp);
        this.capture_req(lp);
      join_none
    end

    for (int s = 0; s < N_SN_PORTS; s++) begin

      automatic int ls = s;

      fork

        this.sn_credit_loop(ls);
        this.sn_activate(ls);
      join_none
    end

    // Hold this task alive (the parent disables the fork on reset).
    forever begin

      @(this.vif_sn[0].g_drv.rni_cb);
    end
  endtask

  // ---------------------------------------------------------------------------
  // Per-RN credit/link loop.
  // ---------------------------------------------------------------------------
  protected task rn_credit_loop(input int p);

    forever begin

      @(this.vif_rn[p].g_drv.hni_cb);

      this.drive_rn_idle_sideband(p);

      this.vif_rn[p].g_drv.hni_cb.txsactive   <= this.rn_link_up[p];
      this.vif_rn[p].g_drv.hni_cb.txreqlcrdv  <= (this.rn_req_lcrdv_pending[p] != 0);
      this.vif_rn[p].g_drv.hni_cb.txrsplcrdv  <= (this.rn_rsp_lcrdv_pending[p] != 0);
      this.vif_rn[p].g_drv.hni_cb.txdatlcrdv  <= (this.rn_dat_lcrdv_pending[p] != 0);

      if (this.rn_req_lcrdv_pending[p] != 0) begin
        this.rn_req_lcrdv_pending[p]--;
      end

      if (this.rn_rsp_lcrdv_pending[p] != 0) begin
        this.rn_rsp_lcrdv_pending[p]--;
      end

      if (this.rn_dat_lcrdv_pending[p] != 0) begin
        this.rn_dat_lcrdv_pending[p]--;
      end

      if (this.vif_rn[p].g_drv.hni_cb.rxrsplcrdv) begin
        this.rn_rsp_send_mgr[p].return_credit();
      end

      if (this.vif_rn[p].g_drv.hni_cb.rxdatlcrdv) begin
        this.rn_dat_send_mgr[p].return_credit();
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  // Per-SN credit/link loop.
  // ---------------------------------------------------------------------------
  protected task sn_credit_loop(input int s);

    forever begin

      @(this.vif_sn[s].g_drv.rni_cb);

      this.drive_sn_idle_sideband(s);

      this.vif_sn[s].g_drv.rni_cb.txsactive   <= this.sn_link_up[s];
      this.vif_sn[s].g_drv.rni_cb.txrsplcrdv  <= (this.sn_rsp_lcrdv_pending[s] != 0);
      this.vif_sn[s].g_drv.rni_cb.txdatlcrdv  <= (this.sn_dat_lcrdv_pending[s] != 0);

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

  // ---------------------------------------------------------------------------
  // Activation.
  // ---------------------------------------------------------------------------
  protected task rn_activate(input int p);

    do begin
      @(this.vif_rn[p].g_drv.hni_cb);
    end while (this.vif_rn[p].rst_n && !this.vif_rn[p].g_drv.hni_cb.rxlinkactivereq);

    this.rn_req_lcrdv_pending[p] += 1;
    this.rn_rsp_lcrdv_pending[p] += 1;
    this.rn_dat_lcrdv_pending[p] += 1;
    this.rn_link_up[p] = 1'b1;
  endtask

  // ---------------------------------------------------------------------------
  //
  // ---------------------------------------------------------------------------
  protected task sn_activate(input int s);

    @(this.vif_sn[s].g_drv.rni_cb);
    this.vif_sn[s].g_drv.rni_cb.txlinkactivereq <= 1'b1;

    do begin

      @(this.vif_sn[s].g_drv.rni_cb);
    end while (this.vif_sn[s].rst_n && !this.vif_sn[s].g_drv.rni_cb.rxlinkactiveack);

    this.sn_rsp_lcrdv_pending[s] += 1;
    this.sn_dat_lcrdv_pending[s] += 1;
    this.sn_link_up[s] = 1'b1;
  endtask

  // ---------------------------------------------------------------------------
  // Hold an assembled flit for its channel's configured transmit delay, then
  // take the credit. See the RN-I twin for why the delay lands before the credit
  // and why L-credit returns are excluded.
  //
  // The delay window is per AGENT while this driver is per PORT, so every RN
  // port draws from the same knob. That is the honest reading of a config that
  // has no port dimension, and it is still a real shape on each link -- the
  // draws are independent, so the ports do not move in lock step.
  // ---------------------------------------------------------------------------
  protected task wait_rn_channel_delay(input int p, input int unsigned cycles);

    repeat (cycles) begin
      @(this.vif_rn[p].g_drv.hni_cb);
    end
  endtask

  protected task wait_sn_channel_delay(input int s, input int unsigned cycles);

    repeat (cycles) begin
      @(this.vif_sn[s].g_drv.rni_cb);
    end
  endtask

  // ---------------------------------------------------------------------------
  // Credit acquire helpers.
  // ---------------------------------------------------------------------------
  // Which channel the announce tasks are announcing on. Local to the drivers:
  // it names a clocking-block member to assign, not anything on the wire.
  typedef enum {
    ANNOUNCE_REQ_E,
    ANNOUNCE_RSP_E,
    ANNOUNCE_DAT_E
  } announce_ch_t;

  protected task wait_rn_send_credit(input int p, input vip_chi_lcrd_mgr mgr);

    forever begin

      if (mgr.try_acquire_credit()) begin

        break;
      end

      @(this.vif_rn[p].g_drv.hni_cb);
    end
  endtask

  // ---------------------------------------------------------------------------
  //
  // ---------------------------------------------------------------------------
  // ---------------------------------------------------------------------------
  // Raise FLITPEND for the cycle before a relayed flit goes out.
  //
  // IHI 0050 E §14.4 / D §13.4: the signal is asserted exactly one cycle before
  // a flit is sent. The proxy relays the FLITPEND it received ALONGSIDE the flit
  // -- that value carries the burst's "more beats follow" meaning to the far
  // side -- and this is the separate one-cycle lead in front of it, which the
  // received stream cannot supply because the relay re-times every flit.
  // ---------------------------------------------------------------------------
  protected task announce_sn_flit(input int s, input announce_ch_t ch);
    @(this.vif_sn[s].g_drv.rni_cb);
    case (ch)
      ANNOUNCE_REQ_E: this.vif_sn[s].g_drv.rni_cb.txreqflitpend <= 1'b1;
      ANNOUNCE_RSP_E: this.vif_sn[s].g_drv.rni_cb.txrspflitpend <= 1'b1;
      default:        this.vif_sn[s].g_drv.rni_cb.txdatflitpend <= 1'b1;
    endcase
  endtask

  protected task announce_rn_flit(input int p, input announce_ch_t ch);
    @(this.vif_rn[p].g_drv.hni_cb);
    if (ch == ANNOUNCE_RSP_E) begin
      this.vif_rn[p].g_drv.hni_cb.txrspflitpend <= 1'b1;
    end
    else begin
      this.vif_rn[p].g_drv.hni_cb.txdatflitpend <= 1'b1;
    end
  endtask

  protected task wait_sn_send_credit(input int s, input vip_chi_lcrd_mgr mgr);

    forever begin

      if (mgr.try_acquire_credit()) begin

        break;
      end

      @(this.vif_sn[s].g_drv.rni_cb);
    end
  endtask

  // ---------------------------------------------------------------------------
  // Round-robin selectors.
  // ---------------------------------------------------------------------------
  // ---------------------------------------------------------------------------
  // Classify a forwarded REQ so the QoS forwarder knows which observable event
  // settles the transaction (see hni_txn_kind_e). This mirrors the RN-I driver's
  // per-opcode completion expectations, but only enough to pick the settle
  // event — the flit relay itself stays opcode-agnostic.
  // ---------------------------------------------------------------------------
  protected function hni_txn_kind_e classify_req(input req_flit_t flit);

    vip_chi_req_opcode_t opc;

    opc = vip_chi_req_opcode_t'(flit.opcode);

    if (opc == vip_chi_req_opcode_t'(VIP_CHI_REQ_PREFETCH_TGT_C)) begin
      return HNI_TXN_NO_COMP_E;                        // no completion at all
    end

    if ((opc == vip_chi_req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_ZERO_C)) ||
        (opc == vip_chi_req_opcode_t'(VIP_CHI_REQ_CLEAN_SHARED_PERSIST_C)) ||
        (opc == vip_chi_req_opcode_t'(VIP_CHI_REQ_CLEAN_SHARED_PERSIST_SEP_C))) begin
      return HNI_TXN_RSP_ONLY_E;                       // completion-only (no DAT)
    end

    if (vip_chi_types_pkg::vip_chi_req_opcode_is_atomic_returning_data(opc)) begin
      return HNI_TXN_READ_E;                           // operand out, CompData back
    end

    if (vip_chi_types_pkg::vip_chi_req_opcode_is_atomic(opc) ||
        (opc == vip_chi_req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_FULL_C)) ||
        (opc == vip_chi_req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_PTL_C))) begin
      return HNI_TXN_WRITE_E;                           // write / atomic-store: data to SN
    end

    return HNI_TXN_READ_E;                              // ReadNoSnp / ReadNoSnpSep
  endfunction

  // ---------------------------------------------------------------------------
  // TRUE for a terminal completion RSP opcode of a completion-only transaction.
  // ---------------------------------------------------------------------------
  protected function bit rsp_is_terminal(input rsp_flit_t flit);

    case (vip_chi_rsp_opcode_t'(flit.opcode))

      vip_chi_rsp_opcode_t'(VIP_CHI_RSP_COMP_C),
      vip_chi_rsp_opcode_t'(VIP_CHI_RSP_COMP_DBID_RESP_C),
      vip_chi_rsp_opcode_t'(VIP_CHI_RSP_COMP_PERSIST_C): begin

        return 1'b1;
      end

      default: begin
        return 1'b0;
      end
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // TRUE for the first response of a split write completion sequence.
  // ---------------------------------------------------------------------------
  protected function bit rsp_is_split_write_grant(input rsp_flit_t flit);

    case (vip_chi_rsp_opcode_t'(flit.opcode))

      vip_chi_rsp_opcode_t'(VIP_CHI_RSP_DBID_RESP_C),
      vip_chi_rsp_opcode_t'(VIP_CHI_RSP_DBID_RESP_ORD_C): begin

        return 1'b1;
      end

      default: begin
        return 1'b0;
      end
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // TRUE for a write completion response. A split write uses Comp after DBIDResp;
  // a non-split write uses the combined CompDBIDResp before the data burst.
  // ---------------------------------------------------------------------------
  protected function bit rsp_is_write_comp(input rsp_flit_t flit);

    case (vip_chi_rsp_opcode_t'(flit.opcode))

      vip_chi_rsp_opcode_t'(VIP_CHI_RSP_COMP_C),
      vip_chi_rsp_opcode_t'(VIP_CHI_RSP_COMP_DBID_RESP_C): begin

        return 1'b1;
      end

      default: begin
        return 1'b0;
      end
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // Settle the active write when all required observable write events have crossed
  // the proxy. For non-split writes, the final data beat is sufficient because the
  // combined CompDBIDResp has already been delivered; for split writes, the
  // deferred Comp must also reach the RN.
  // ---------------------------------------------------------------------------
  protected function void try_settle_active_write(input int p);

    if (!this.active_busy || (this.active_kind != HNI_TXN_WRITE_E) || (this.active_port != p)) begin
      return;
    end

    if (this.active_write_data_done &&
        (!this.active_write_split || this.active_write_comp_done)) begin
      this.active_busy = 1'b0;
    end
  endfunction

  // ---------------------------------------------------------------------------
  // TRUE when any RN port has a captured REQ awaiting forwarding.
  // ---------------------------------------------------------------------------
  protected function bit has_pending_req();

    foreach (this.req_pending[p]) begin

      if (this.req_pending[p]) begin
        return 1'b1;
      end
    end

    return 1'b0;
  endfunction

  // ---------------------------------------------------------------------------
  // Pick the pending REQ with the highest QoS (ties broken round-robin), or -1.
  // ---------------------------------------------------------------------------
  protected function int pick_qos_req_port();

    int best = -1;

    for (int k = 0; k < N_RN_PORTS; k++) begin

      int p = (this.qos_rr_cursor + k) % N_RN_PORTS;

      if (this.req_pending[p]) begin

        if ((best < 0) || (this.req_qos[p] > this.req_qos[best])) begin

          best = p;
        end
      end
    end

    if (best >= 0) begin

      this.qos_rr_cursor = (best + 1) % N_RN_PORTS;
    end

    return best;
  endfunction

  // ---------------------------------------------------------------------------
  //
  // ---------------------------------------------------------------------------
  protected function int pick_rn_rsp_port();

    for (int k = 0; k < N_RN_PORTS; k++) begin

      int p = (this.rsp_rr_cursor + k) % N_RN_PORTS;

      if (this.vif_rn[p].g_drv.hni_cb.rxrspflitv) begin

        this.rsp_rr_cursor = (p + 1) % N_RN_PORTS;
        return p;
      end
    end

    return -1;
  endfunction

  // ---------------------------------------------------------------------------
  //
  // ---------------------------------------------------------------------------
  protected function int pick_rn_dat_port();

    for (int k = 0; k < N_RN_PORTS; k++) begin

      int p = (this.dat_rr_cursor + k) % N_RN_PORTS;

      if (this.vif_rn[p].g_drv.hni_cb.rxdatflitv) begin

        this.dat_rr_cursor = (p + 1) % N_RN_PORTS;
        return p;
      end
    end

    return -1;
  endfunction

  // ---------------------------------------------------------------------------
  //
  // ---------------------------------------------------------------------------
  protected function int pick_sn_rsp_port();
    for (int k = 0; k < N_SN_PORTS; k++) begin
      int s = (this.sn_rsp_rr_cursor + k) % N_SN_PORTS;
      if (this.vif_sn[s].g_drv.rni_cb.rxrspflitv) begin
        this.sn_rsp_rr_cursor = (s + 1) % N_SN_PORTS;
        return s;
      end
    end
    return -1;
  endfunction

  // ---------------------------------------------------------------------------
  //
  // ---------------------------------------------------------------------------
  protected function int pick_sn_dat_port();

    for (int k = 0; k < N_SN_PORTS; k++) begin

      int s = (this.sn_dat_rr_cursor + k) % N_SN_PORTS;

      if (this.vif_sn[s].g_drv.rni_cb.rxdatflitv) begin

        this.sn_dat_rr_cursor = (s + 1) % N_SN_PORTS;
        return s;
      end
    end

    return -1;
  endfunction

  // ---------------------------------------------------------------------------
  //
  // ---------------------------------------------------------------------------
  protected function int resolve_rn_port(input node_id_t node);

    if (this.port_of_node.exists(longint'(node))) begin

      return this.port_of_node[longint'(node)];
    end

    return 0;
  endfunction

  // ---------------------------------------------------------------------------
  // Per-RN REQ ingress capture. Because the HN granted the RN a REQ credit, the
  // RN may present a REQ on any cycle; this per-port process latches it into the
  // 1-deep ingress slot regardless of what the forwarder is doing (fixing the
  // drop that a single shared arbiter would suffer under concurrent REQs). The
  // credit is *not* returned here — the QoS forwarder returns it once the
  // captured transaction has settled, so each RN is limited to one outstanding.
  // ---------------------------------------------------------------------------
  protected task capture_req(input int p);

    forever begin

      while (!this.vif_rn[p].g_drv.hni_cb.rxreqflitv) begin
        @(this.vif_rn[p].g_drv.hni_cb);
      end

      this.req_slot[p]    = this.vif_rn[p].g_drv.hni_cb.rxreqflit;
      this.req_qos[p]     = int'(this.vif_rn[p].g_drv.hni_cb.rxreqflit.qos);
      this.req_pending[p] = 1'b1;

      // Wait until the forwarder drains this slot before accepting the next REQ
      // (the RN cannot send another until its credit is returned anyway).
      while (this.req_pending[p]) begin

        @(this.vif_rn[p].g_drv.hni_cb);
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  // QoS-ordered REQ forwarder. Single-outstanding: when idle, forward the
  // highest-QoS pending REQ (address-decoded to its SN), then wait for that
  // transaction to settle before returning the RN's REQ credit and choosing the
  // next. Serializing here keeps the (single-REQ-at-a-time) SN responder from
  // being handed a second request mid-transaction.
  // ---------------------------------------------------------------------------
  protected task qos_forwarder();

    req_flit_t flit;
    int        p;
    int        s;

    forever begin

      // Wait until at least one REQ is captured, then hold a short collection
      // window so concurrent requestors can also present before we arbitrate.
      while (!this.has_pending_req()) begin
        @(this.vif_sn[0].g_drv.rni_cb);
      end

      repeat (this.arb_window_cycles) begin
        @(this.vif_sn[0].g_drv.rni_cb);
      end

      p = this.pick_qos_req_port();

      if (p < 0) begin
        @(this.vif_sn[0].g_drv.rni_cb);
        continue;
      end

      flit = this.req_slot[p];
      s    = this.sn_port_of_addr(addr_t'(flit.addr));

      this.port_of_node[longint'(flit.srcid)] = p;
      this.active_sn_of_rn[p]                 = s;
      this.active_port                        = p;
      this.active_kind                        = this.classify_req(flit);
      this.active_write_split                 = 1'b0;
      this.active_write_data_done             = 1'b0;
      this.active_write_comp_done             = 1'b0;
      this.active_busy                        = 1'b1;

      this.wait_sn_channel_delay(s, this.cfg.draw_req_valid_delay());
      this.wait_sn_send_credit(s, this.sn_req_send_mgr[s]);

      this.announce_sn_flit(s, ANNOUNCE_REQ_E);
      @(this.vif_sn[s].g_drv.rni_cb);
      this.vif_sn[s].g_drv.rni_cb.txreqflitpend <= 1'b0;
      this.vif_sn[s].g_drv.rni_cb.txreqflit     <= flit;
      this.vif_sn[s].g_drv.rni_cb.txreqflitv    <= 1'b1;

      @(this.vif_sn[s].g_drv.rni_cb);
      this.vif_sn[s].g_drv.rni_cb.txreqflitv    <= 1'b0;
      this.vif_sn[s].g_drv.rni_cb.txreqflit     <= '0;

      // PrefetchTgt gets no completion, so it settles as soon as it is sent.
      if (this.active_kind == HNI_TXN_NO_COMP_E) begin
        this.active_busy = 1'b0;
      end

      // Block until the routers/arbiters report the transaction settled.
      wait (this.active_busy == 1'b0);

      this.rn_req_lcrdv_pending[p] += 1;
      this.req_pending[p]           = 1'b0;
    end
  endtask

  // ---------------------------------------------------------------------------
  // CompAck-RSP arbiter: any RN -> its active SN.
  // ---------------------------------------------------------------------------
  protected task arbiter_rsp_rn_to_sn();

    rsp_flit_t flit;
    bit        pend;
    int        p;
    int        s;

    forever begin

      p = this.pick_rn_rsp_port();

      if (p < 0) begin

        @(this.vif_sn[0].g_drv.rni_cb);
        continue;
      end

      flit = this.vif_rn[p].g_drv.hni_cb.rxrspflit;
      pend = this.vif_rn[p].g_drv.hni_cb.rxrspflitpend;
      s    = this.active_sn_of_rn[p];

      this.wait_sn_channel_delay(s, this.cfg.draw_rsp_valid_delay());
      this.wait_sn_send_credit(s, this.sn_rsp_send_mgr[s]);

      this.announce_sn_flit(s, ANNOUNCE_RSP_E);
      @(this.vif_sn[s].g_drv.rni_cb);
      this.vif_sn[s].g_drv.rni_cb.txrspflitpend <= pend;
      this.vif_sn[s].g_drv.rni_cb.txrspflit     <= flit;
      this.vif_sn[s].g_drv.rni_cb.txrspflitv    <= 1'b1;

      @(this.vif_sn[s].g_drv.rni_cb);
      this.vif_sn[s].g_drv.rni_cb.txrspflitpend <= 1'b0;
      this.vif_sn[s].g_drv.rni_cb.txrspflitv    <= 1'b0;
      this.vif_sn[s].g_drv.rni_cb.txrspflit     <= '0;

      this.rn_rsp_lcrdv_pending[p] += 1;

      @(this.vif_rn[p].g_drv.hni_cb);
    end
  endtask

  // ---------------------------------------------------------------------------
  // Write-DAT arbiter: any RN -> its active SN. Stays locked to the chosen RN
  // (and SN) until the final beat (flitpend low).
  // ---------------------------------------------------------------------------
  protected task arbiter_dat_rn_to_sn();

    dat_flit_t flit;
    bit        pend;
    int        p;
    int        s;

    forever begin

      p = this.pick_rn_dat_port();

      if (p < 0) begin
        @(this.vif_sn[0].g_drv.rni_cb);
        continue;
      end
      s = this.active_sn_of_rn[p];

      forever begin

        while (!this.vif_rn[p].g_drv.hni_cb.rxdatflitv) begin
          @(this.vif_rn[p].g_drv.hni_cb);
        end

        flit = this.vif_rn[p].g_drv.hni_cb.rxdatflit;
        pend = this.vif_rn[p].g_drv.hni_cb.rxdatflitpend;

        this.wait_sn_channel_delay(s, this.cfg.draw_dat_valid_delay());
        this.wait_sn_send_credit(s, this.sn_dat_send_mgr[s]);

        this.announce_sn_flit(s, ANNOUNCE_DAT_E);
        @(this.vif_sn[s].g_drv.rni_cb);
        this.vif_sn[s].g_drv.rni_cb.txdatflitpend <= pend;
        this.vif_sn[s].g_drv.rni_cb.txdatflit     <= flit;
        this.vif_sn[s].g_drv.rni_cb.txdatflitv    <= 1'b1;

        @(this.vif_sn[s].g_drv.rni_cb);
        this.vif_sn[s].g_drv.rni_cb.txdatflitpend <= 1'b0;
        this.vif_sn[s].g_drv.rni_cb.txdatflitv    <= 1'b0;
        this.vif_sn[s].g_drv.rni_cb.txdatflit     <= '0;

        this.rn_dat_lcrdv_pending[p] += 1;

        @(this.vif_rn[p].g_drv.hni_cb);

        if (!pend) begin

          // A non-split write settles once its final write-data beat has reached
          // the SN (the combined completion RSP preceded the data). Split writes
          // are held until the deferred Comp has also reached the RN.
          //
          // §22 L5 decision: settling here -- at the last write-data beat, before
          // any ExpCompAck relay -- is intended, not a gap. For a non-split write
          // the completion RSP is already delivered before the data, so the final
          // write-data beat is the last data-bearing event of the transaction; the
          // trailing CompAck (RN->SN) carries no data and is relayed independently
          // by the CompAck arbiter, which keeps running after settle. Freeing the
          // SN here maximizes per-SN throughput and cannot reorder data. Deferring
          // settle to the CompAck relay would only serialize the ack ahead of the
          // next request for no CHI-required benefit, so it is not done.
          this.active_write_data_done = 1'b1;
          this.try_settle_active_write(p);

          break;
        end
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  // Completion-RSP router: any SN -> RN, routed by tgtid (the original srcid).
  // ---------------------------------------------------------------------------
  protected task router_rsp_sn_to_rn();

    rsp_flit_t flit;
    bit        pend;
    int        s;
    int        p;

    forever begin

      s = this.pick_sn_rsp_port();

      if (s < 0) begin

        @(this.vif_rn[0].g_drv.hni_cb);
        continue;
      end

      flit = this.vif_sn[s].g_drv.rni_cb.rxrspflit;
      pend = this.vif_sn[s].g_drv.rni_cb.rxrspflitpend;
      p    = this.resolve_rn_port(node_id_t'(flit.tgtid));

      this.wait_rn_channel_delay(p, this.cfg.draw_rsp_valid_delay());
      this.wait_rn_send_credit(p, this.rn_rsp_send_mgr[p]);

      this.announce_rn_flit(p, ANNOUNCE_RSP_E);
      @(this.vif_rn[p].g_drv.hni_cb);
      this.vif_rn[p].g_drv.hni_cb.txrspflitpend <= pend;
      this.vif_rn[p].g_drv.hni_cb.txrspflit     <= flit;
      this.vif_rn[p].g_drv.hni_cb.txrspflitv    <= 1'b1;

      @(this.vif_rn[p].g_drv.hni_cb);
      this.vif_rn[p].g_drv.hni_cb.txrspflitpend <= 1'b0;
      this.vif_rn[p].g_drv.hni_cb.txrspflitv    <= 1'b0;
      this.vif_rn[p].g_drv.hni_cb.txrspflit     <= '0;

      // §7 T3 fail-fast guard: a RetryAck relayed from an SN behind this proxy is
      // the unmodeled retry-through-proxy path. The qos_forwarder is blocked on
      // `wait (active_busy == 0)` for this very transaction and no terminal
      // completion will ever arrive (the RN must re-issue, which the wedged
      // forwarder cannot pick up) -- a permanent deadlock. Abort with a clear
      // diagnostic instead of hanging until the test timeout. Do NOT configure
      // force_retry_count on an SN placed behind an HN-I proxy.
      if (this.active_busy && (this.active_port == p) &&
          (vip_chi_rsp_opcode_t'(flit.opcode) == vip_chi_rsp_opcode_t'(VIP_CHI_RSP_RETRY_ACK_C))) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] RetryAck relayed through the HN-I proxy (txn 0x%0h, RN port %0d): retry behind a proxy is not modeled and would deadlock the forwarder -- do not set force_retry_count on an SN behind the proxy",
          get_name(), flit.txnid, p))
        // If the fatal is demoted (negative-control catcher), release the
        // forwarder so the RN's re-issue can drain instead of wedging the run.
        this.active_busy = 1'b0;
      end

      // Track split-write completion state after the RSP has been relayed. The
      // forwarder may release the next request only after both the final write DAT
      // and the deferred Comp have crossed the proxy.
      if (this.active_busy && (this.active_kind == HNI_TXN_WRITE_E) && (this.active_port == p)) begin
        if (this.rsp_is_split_write_grant(flit)) begin
          this.active_write_split = 1'b1;
        end
        if (this.rsp_is_write_comp(flit)) begin
          this.active_write_comp_done = 1'b1;
        end
        this.try_settle_active_write(p);
      end

      // A completion-only transaction (persist / write-zero) settles on its
      // terminal completion RSP reaching the RN.
      if (this.active_busy && (this.active_kind == HNI_TXN_RSP_ONLY_E) &&
          (this.active_port == p) && this.rsp_is_terminal(flit)) begin
        this.active_busy = 1'b0;
      end

      this.sn_rsp_lcrdv_pending[s] += 1;

      @(this.vif_sn[s].g_drv.rni_cb);
    end
  endtask

  // ---------------------------------------------------------------------------
  // Read-DAT / CompData router: any SN -> RN, routed by tgtid. Stays locked to
  // the chosen SN until the final beat.
  // ---------------------------------------------------------------------------
  protected task router_dat_sn_to_rn();

    dat_flit_t flit;
    bit        pend;
    int        s;
    int        p;

    forever begin

      s = this.pick_sn_dat_port();
      if (s < 0) begin
        @(this.vif_rn[0].g_drv.hni_cb);
        continue;
      end

      forever begin

        while (!this.vif_sn[s].g_drv.rni_cb.rxdatflitv) begin
          @(this.vif_sn[s].g_drv.rni_cb);
        end

        flit = this.vif_sn[s].g_drv.rni_cb.rxdatflit;
        pend = this.vif_sn[s].g_drv.rni_cb.rxdatflitpend;
        p    = this.resolve_rn_port(node_id_t'(flit.tgtid));

        this.wait_rn_channel_delay(p, this.cfg.draw_dat_valid_delay());
        this.wait_rn_send_credit(p, this.rn_dat_send_mgr[p]);

        this.announce_rn_flit(p, ANNOUNCE_DAT_E);
        @(this.vif_rn[p].g_drv.hni_cb);
        this.vif_rn[p].g_drv.hni_cb.txdatflitpend <= pend;
        this.vif_rn[p].g_drv.hni_cb.txdatflit     <= flit;
        this.vif_rn[p].g_drv.hni_cb.txdatflitv    <= 1'b1;

        @(this.vif_rn[p].g_drv.hni_cb);
        this.vif_rn[p].g_drv.hni_cb.txdatflitpend <= 1'b0;
        this.vif_rn[p].g_drv.hni_cb.txdatflitv    <= 1'b0;
        this.vif_rn[p].g_drv.hni_cb.txdatflit     <= '0;

        this.sn_dat_lcrdv_pending[s] += 1;

        @(this.vif_sn[s].g_drv.rni_cb);

        if (!pend) begin

          // A read settles once its final CompData beat has reached the RN.
          if (this.active_busy && (this.active_kind == HNI_TXN_READ_E) && (this.active_port == p)) begin

            this.active_busy = 1'b0;
          end
          break;
        end
      end
    end
  endtask
endclass

`endif
