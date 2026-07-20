`ifndef VIP_CHI_MONITOR
`define VIP_CHI_MONITOR

import uvm_pkg::*;
`include "uvm_macros.svh"
import vip_chi_types_pkg::*;

class vip_chi_monitor #(
  vip_chi_cfg_t  CFG_P        = VIP_CHI_DEFAULT_CFG_C,
  type           FLIT_TYPES_T = vip_chi_types #(CFG_P),
  vip_chi_role_t ROLE_P       = VIP_CHI_ROLE_MONITOR_E
  ) extends uvm_monitor;

  typedef vip_chi_item  #(CFG_P)               item_t;
  typedef vip_chi_types #(CFG_P)::node_id_t    node_id_t;
  typedef vip_chi_types #(CFG_P)::addr_t       addr_t;
  typedef vip_chi_types #(CFG_P)::txn_id_t     txn_id_t;
  typedef vip_chi_types #(CFG_P)::lpid_t       lpid_t;
  typedef vip_chi_types #(CFG_P)::size_t       size_t;
  typedef vip_chi_types #(CFG_P)::req_opcode_t req_opcode_t;
  typedef vip_chi_types #(CFG_P)::rsp_opcode_t rsp_opcode_t;
  typedef vip_chi_types #(CFG_P)::dat_opcode_t dat_opcode_t;
  typedef vip_chi_types #(CFG_P)::data_t       data_t;
  typedef vip_chi_types #(CFG_P)::be_t         be_t;
  typedef vip_chi_types #(CFG_P)::data_id_t    data_id_t;
  typedef vip_chi_types #(CFG_P)::cc_id_t      cc_id_t;
  typedef vip_chi_types #(CFG_P)::datacheck_t  datacheck_t;
  typedef vip_chi_types #(CFG_P)::poison_t     poison_t;
  typedef vip_chi_types #(CFG_P)::mpam_t       mpam_t;
  typedef FLIT_TYPES_T::vip_chi_req_flit_t     req_flit_t;
  typedef FLIT_TYPES_T::vip_chi_rsp_flit_t     rsp_flit_t;
  typedef FLIT_TYPES_T::vip_chi_dat_flit_t     dat_flit_t;
  typedef FLIT_TYPES_T::vip_chi_snp_flit_t     snp_flit_t;

  virtual vip_chi_if #(CFG_P, FLIT_TYPES_T, ROLE_P) vif;
  vip_chi_cfg_agent                                 cfg;

  uvm_analysis_port #(item_t) req_port;
  uvm_analysis_port #(item_t) rsp_port;
  uvm_analysis_port #(item_t) dat_port;
  uvm_analysis_port #(item_t) snp_port;

  // Per-transfer DAT reassembly state, keyed by {role,src,tgt,txnid}. Beats are
  // stored in arrival order (not by absolute DataID) and a transfer retires on
  // its correlated beat count when known (see the correlation maps below),
  // falling back to the advisory FLITPEND deassert only when the count is not.
  protected item_t dat_item_by_key[string];
  protected int    dat_received_beats_by_key[string];

  // REQ->DAT beat-count correlation. Reads echo the requester TxnID on the
  // returning data, so their expected beat count is keyed by TxnID. Writes and
  // atomic operands ship their data under the granted DBID (used as the DAT
  // TxnID), so their count is keyed by DBID once the grant is observed. All
  // three are consumed on retirement, so they stay bounded in a reset-free run.
  protected int    rd_beats_by_txnid[txn_id_t];  // read return, keyed by REQ TxnID
  protected int    wr_beats_by_txnid[txn_id_t];  // write/operand out, keyed by REQ TxnID (staging)
  protected int    wr_beats_by_dbid[txn_id_t];   // write/operand out, keyed by granted DBID

  `uvm_component_param_utils(vip_chi_monitor #(CFG_P, FLIT_TYPES_T, ROLE_P))

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent);
    super.new(name, parent);
    this.req_port = new("req_port", this);
    this.rsp_port = new("rsp_port", this);
    this.dat_port = new("dat_port", this);
    this.snp_port = new("snp_port", this);
  endfunction

  // ---------------------------------------------------------------------------
  // Validate the monitor wiring supplied by the parent agent.
  // ---------------------------------------------------------------------------
  function void build_phase(input uvm_phase phase);
    super.build_phase(phase);

    if (this.vif == null) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] monitor.vif must be assigned by the parent agent",
        get_name()))
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Public sampling entry point. The parent agent owns the reset watcher and
  // forks this task only while rst_n is deasserted.
  // ---------------------------------------------------------------------------
  task monitor_start();

    forever begin

      @(this.vif.monitor_cb);

      if (!this.vif.rst_n) begin
        continue;
      end

      if (this.vif.monitor_cb.txreqflitv) begin
        this.publish_req(this.vif.monitor_cb.txreqflit, ROLE_P);
      end

      if (this.vif.monitor_cb.rxreqflitv) begin
        this.publish_req(this.vif.monitor_cb.rxreqflit, this.peer_role());
      end

      if (this.vif.monitor_cb.txrspflitv) begin
        this.publish_rsp(this.vif.monitor_cb.txrspflit, ROLE_P);
      end

      if (this.vif.monitor_cb.rxrspflitv) begin
        this.publish_rsp(this.vif.monitor_cb.rxrspflit, this.peer_role());
      end

      if (this.vif.monitor_cb.txdatflitv) begin
        this.publish_dat(this.vif.monitor_cb.txdatflit, this.vif.monitor_cb.txdatflitpend, ROLE_P);
      end

      if (this.vif.monitor_cb.rxdatflitv) begin
        this.publish_dat(this.vif.monitor_cb.rxdatflit, this.vif.monitor_cb.rxdatflitpend, this.peer_role());
      end

      // Snoop channel (Tier C). A home node (HN-F) sources snoops on its TX; a
      // fully-coherent requester (RN-F) receives them on its RX. Both are idle
      // on non-coherent links, so this never fires there.
      if (this.vif.monitor_cb.txsnpflitv) begin
        this.publish_snp(this.vif.monitor_cb.txsnpflit, ROLE_P);
      end

      if (this.vif.monitor_cb.rxsnpflitv) begin
        this.publish_snp(this.vif.monitor_cb.rxsnpflit, this.peer_role());
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  // The parent agent owns the reset watcher and calls monitor_start().
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);
  endtask

  // ---------------------------------------------------------------------------
  // Drop any partially assembled DAT transactions on reset.
  // ---------------------------------------------------------------------------
  function void handle_reset();
    this.dat_item_by_key.delete();
    this.dat_received_beats_by_key.delete();
    this.rd_beats_by_txnid.delete();
    this.wr_beats_by_txnid.delete();
    this.wr_beats_by_dbid.delete();
  endfunction

  // ---------------------------------------------------------------------------
  // TRUE when a DAT opcode carries requester-sourced write / atomic-operand
  // data (keyed by DBID) rather than data returned to the requester.
  // ---------------------------------------------------------------------------
  protected function bit dat_opcode_is_write_data(input dat_opcode_t opcode);
    // CopyBackWrData (coherent writeback data) must count as write data too:
    // otherwise its staged wr_beats_by_dbid entry is never consumed/deleted (a
    // slow leak + stale-count hazard on DBID reuse) and the DAT item is
    // mislabelled a read. [P3(b)]
    return (opcode == dat_opcode_t'(VIP_CHI_DAT_NON_COPY_BACK_WR_DATA_C)) ||
           (opcode == dat_opcode_t'(VIP_CHI_DAT_NCB_WR_DATA_COMP_ACK_C))   ||
           (opcode == dat_opcode_t'(VIP_CHI_DAT_COPY_BACK_WR_DATA_C));
  endfunction

  // ---------------------------------------------------------------------------
  // TRUE for read opcodes whose returned data spans the request Size, so their
  // beat count can be derived up front and keyed by the (echoed) TxnID.
  // ---------------------------------------------------------------------------
  protected function bit req_opcode_is_plain_read(input req_opcode_t opcode);
    return (opcode == req_opcode_t'(VIP_CHI_REQ_READ_NO_SNP_C)) ||
           (opcode == req_opcode_t'(VIP_CHI_REQ_READ_NO_SNP_SEP_C));
  endfunction

  // ---------------------------------------------------------------------------
  // Map the opposite endpoint role for RX-channel observations.
  // ---------------------------------------------------------------------------
  protected function vip_chi_role_t peer_role();
    if (ROLE_P == VIP_CHI_ROLE_RNI_E) begin
      return VIP_CHI_ROLE_SNF_E;
    end

    if (ROLE_P == VIP_CHI_ROLE_SNF_E) begin
      return VIP_CHI_ROLE_RNI_E;
    end

    if (ROLE_P == VIP_CHI_ROLE_RNF_E) begin
      return VIP_CHI_ROLE_HNF_E;
    end

    if (ROLE_P == VIP_CHI_ROLE_HNF_E) begin
      return VIP_CHI_ROLE_RNF_E;
    end

    return VIP_CHI_ROLE_MONITOR_E;
  endfunction

  // ---------------------------------------------------------------------------
  // Infer request direction from the opcode carried on the REQ flit.
  // ---------------------------------------------------------------------------
  protected function vip_chi_dir_t direction_from_opcode(input req_opcode_t opcode);
    // WRITE = the requester ships data (or zeroes) upstream: the non-coherent
    // WriteNoSnp*, the coherent writebacks / WriteUnique, and the atomics (which
    // carry an operand). This mirrors driver_rni::req_expects_write_data (+ the
    // no-data WriteNoSnpZero); everything else (reads, CMOs, Evict, ...) is READ.
    // Atomics are matched in the WIDE opcode domain so a 7-bit atomic opcode
    // cannot alias a narrow CHI-D opcode. [P3(a)]
    if (vip_chi_types_pkg::vip_chi_req_opcode_is_atomic(vip_chi_req_opcode_t'(opcode))) begin
      return VIP_CHI_DIR_WRITE_E;
    end
    case (opcode)
      req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_PTL_C),
      req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_FULL_C),
      req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_ZERO_C),
      req_opcode_t'(VIP_CHI_REQ_WRITE_BACK_FULL_C),
      req_opcode_t'(VIP_CHI_REQ_WRITE_CLEAN_FULL_C),
      req_opcode_t'(VIP_CHI_REQ_WRITE_UNIQUE_FULL_C),
      req_opcode_t'(VIP_CHI_REQ_WRITE_UNIQUE_PTL_C): begin
        return VIP_CHI_DIR_WRITE_E;
      end
      default: begin
        return VIP_CHI_DIR_READ_E;
      end
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // Correlate REQ and DAT activity per observed endpoint and transaction id.
  // ---------------------------------------------------------------------------
  protected function string txn_key(
    input vip_chi_role_t observed_role,
    input node_id_t      src_id,
    input node_id_t      tgt_id,
    input txn_id_t       txn_id
  );
    return $sformatf("%0d_%0h_%0h_%0h", observed_role, src_id, tgt_id, txn_id);
  endfunction

  // ---------------------------------------------------------------------------
  // Publish one REQ flit as a CHI item.
  // ---------------------------------------------------------------------------
  protected function void publish_req(
    input req_flit_t      flit,
    input vip_chi_role_t  observed_role
  );
    item_t item;
    int    beats;

    item = new("monitor_req_item");
    // set_config seeds the item's CFG-derived widths/typedefs (item.new does not
    // take CFG_P), so field assignments below and any downstream item method use
    // the correct parameterization.
    item.set_config(CFG_P);
    item.role          = observed_role;
    item.direction     = this.direction_from_opcode(req_opcode_t'(flit.opcode));
    item.src_id        = node_id_t'(flit.srcid);
    item.tgt_id        = node_id_t'(flit.tgtid);
    item.txn_id        = txn_id_t'(flit.txnid);
    item.lp_id         = lpid_t'(flit.lpid);
    item.return_nid    = node_id_t'(flit.returnnid);
    item.return_txn_id = txn_id_t'(flit.returntxnid);
    item.qos           = flit.qos;
    item.opcode        = req_opcode_t'(flit.opcode);
    item.addr          = addr_t'(flit.addr);
    item.size          = size_t'(flit.size);
    item.ns            = flit.ns;
    item.tracetag      = flit.tracetag;
    item.dodwt         = flit.dodwt;
    item.likelyshared  = flit.likelyshared;
    item.endian        = flit.endian;
    item.order         = flit.order;
    item.mem_attr      = flit.memattr;
    item.pcrd_type     = flit.pcrdtype;
    item.allow_retry   = flit.allowretry;
    item.excl          = flit.excl;
    item.exp_comp_ack  = flit.expcompack;
    item.mpam          = mpam_t'(flit.mpam);
    this.capture_req_issue_specific_fields(flit, item);

    // Seed the REQ->DAT beat-count correlation. A plain read's data returns
    // under the same TxnID; a write / atomic operand's data ships under the
    // DBID granted later (staged here by TxnID, promoted on the grant RSP).
    if (this.req_opcode_is_plain_read(item.opcode)) begin
      beats = vip_chi_types_pkg::chi_xfer_dat_beats(item.size, CFG_P.DATA_BYTES_P);
      if (beats > 0) begin
        this.rd_beats_by_txnid[item.txn_id] = beats;
      end
    end
    else begin
      beats = item.get_payload_beat_count();
      if (beats > 0) begin
        this.wr_beats_by_txnid[item.txn_id] = beats;
      end
    end

    this.req_port.write(item);
  endfunction

  // ---------------------------------------------------------------------------
  // Optional issue-specific REQ-field hook. The shared implementation only
  // captures fields present in both exact CHI-D and exact CHI-E REQ shapes.
  // ---------------------------------------------------------------------------
  virtual protected function void capture_req_issue_specific_fields(
    input req_flit_t flit,
    inout item_t     item
  );
  endfunction

  // ---------------------------------------------------------------------------
  // Optional issue-specific DAT-field hook. The shared implementation only
  // captures fields present in both exact CHI-D and exact CHI-E DAT shapes.
  // ---------------------------------------------------------------------------
  virtual protected function void capture_dat_issue_specific_fields(
    input dat_flit_t flit,
    inout item_t     item,
    input int        beat_index
  );
  endfunction

  // ---------------------------------------------------------------------------
  // Publish one RSP flit as a CHI item.
  // ---------------------------------------------------------------------------
  protected function void publish_rsp(
    input rsp_flit_t      flit,
    input vip_chi_role_t  observed_role
  );
    item_t item;

    item = new("monitor_rsp_item");
    item.set_config(CFG_P);
    item.role       = observed_role;
    // A response has no intrinsic direction; label the DBID-carrying write
    // grants WRITE so consumers see a meaningful value rather than the default.
    item.direction  =
      ((rsp_opcode_t'(flit.opcode) == rsp_opcode_t'(VIP_CHI_RSP_COMP_DBID_RESP_C)) ||
       (rsp_opcode_t'(flit.opcode) == rsp_opcode_t'(VIP_CHI_RSP_DBID_RESP_C))      ||
       (rsp_opcode_t'(flit.opcode) == rsp_opcode_t'(VIP_CHI_RSP_DBID_RESP_ORD_C))) ?
        VIP_CHI_DIR_WRITE_E : VIP_CHI_DIR_READ_E;
    item.src_id     = node_id_t'(flit.srcid);
    item.tgt_id     = node_id_t'(flit.tgtid);
    item.txn_id     = txn_id_t'(flit.txnid);
    item.dbid       = txn_id_t'(flit.dbid);
    item.qos        = flit.qos;
    item.rsp_opcode = rsp_opcode_t'(flit.opcode);
    item.rsp_resp   = vip_chi_resp_t'(flit.resp);
    item.rsp_resp_err = vip_chi_resp_err_t'(flit.resperr);
    item.fwd_state  = flit.fwdstate;
    item.pcrd_type  = flit.pcrdtype;

    // On a DBID-carrying grant, promote the staged write/operand beat count
    // from the requester TxnID to the DBID the data will actually ship under.
    if (((item.rsp_opcode == rsp_opcode_t'(VIP_CHI_RSP_COMP_DBID_RESP_C)) ||
         (item.rsp_opcode == rsp_opcode_t'(VIP_CHI_RSP_DBID_RESP_C))      ||
         (item.rsp_opcode == rsp_opcode_t'(VIP_CHI_RSP_DBID_RESP_ORD_C))) &&
        this.wr_beats_by_txnid.exists(item.txn_id)) begin
      this.wr_beats_by_dbid[item.dbid] = this.wr_beats_by_txnid[item.txn_id];
      this.wr_beats_by_txnid.delete(item.txn_id);
    end

    this.rsp_port.write(item);
  endfunction

  // ---------------------------------------------------------------------------
  // Publish one DAT flit as a one-beat CHI item.
  // ---------------------------------------------------------------------------
  protected function void publish_dat(
    input dat_flit_t      flit,
    input logic           flit_pending,
    input vip_chi_role_t  observed_role
  );
    item_t     item;
    string     key;
    txn_id_t   dat_txn_id;
    bit        is_write_data;
    int        expected_beats;
    int        alloc_beats;
    int        beat_index;
    bit        transfer_done;

    dat_txn_id    = txn_id_t'(flit.txnid);
    is_write_data = this.dat_opcode_is_write_data(dat_opcode_t'(flit.opcode));

    // Correlated beat count for this transfer: write/operand data is keyed by
    // the granted DBID, returned read data by the (echoed) requester TxnID.
    // 0 means "unknown" -> fall back to the advisory FLITPEND deassert.
    expected_beats = 0;
    if (is_write_data) begin
      if (this.wr_beats_by_dbid.exists(dat_txn_id)) begin
        expected_beats = this.wr_beats_by_dbid[dat_txn_id];
      end
    end
    else begin
      if (this.rd_beats_by_txnid.exists(dat_txn_id)) begin
        expected_beats = this.rd_beats_by_txnid[dat_txn_id];
      end
    end

    key = this.txn_key(
      observed_role,
      node_id_t'(flit.srcid),
      node_id_t'(flit.tgtid),
      dat_txn_id);

    if (!this.dat_item_by_key.exists(key)) begin
      alloc_beats = (expected_beats > 0) ? expected_beats : 1;

      item = new("monitor_dat_item");
      item.set_config(CFG_P);
      item.role       = observed_role;
      item.direction  = is_write_data ? VIP_CHI_DIR_WRITE_E : VIP_CHI_DIR_READ_E;
      item.src_id     = node_id_t'(flit.srcid);
      item.tgt_id     = node_id_t'(flit.tgtid);
      item.txn_id     = dat_txn_id;
      item.dbid       = txn_id_t'(flit.dbid);
      item.qos        = flit.qos;
      item.poison     = poison_t'(flit.poison);
      item.datacheck  = datacheck_t'(flit.datacheck);
      item.dat_opcode = dat_opcode_t'(flit.opcode);

      item.data         = new[alloc_beats];
      item.be           = new[alloc_beats];
      item.tag          = new[alloc_beats];
      item.tu           = new[alloc_beats];
      item.data_id      = new[alloc_beats];
      item.cc_id        = new[alloc_beats];
      item.dat_resp     = new[alloc_beats];
      item.dat_resp_err = new[alloc_beats];

      this.dat_item_by_key[key] = item;
      this.dat_received_beats_by_key[key] = 0;
    end

    item       = this.dat_item_by_key[key];
    beat_index = this.dat_received_beats_by_key[key];  // arrival order, not absolute DataID

    if (beat_index >= item.data.size()) begin
      item.data         = new[beat_index + 1](item.data);
      item.be           = new[beat_index + 1](item.be);
      item.tag          = new[beat_index + 1](item.tag);
      item.tu           = new[beat_index + 1](item.tu);
      item.data_id      = new[beat_index + 1](item.data_id);
      item.cc_id        = new[beat_index + 1](item.cc_id);
      item.dat_resp     = new[beat_index + 1](item.dat_resp);
      item.dat_resp_err = new[beat_index + 1](item.dat_resp_err);
    end

    item.data[beat_index]         = data_t'(flit.data);
    item.be[beat_index]           = be_t'(flit.be);
    item.data_id[beat_index]      = data_id_t'(flit.dataid);
    item.cc_id[beat_index]        = cc_id_t'(flit.ccid);
    item.dat_resp[beat_index]     = vip_chi_resp_t'(flit.resp);
    item.dat_resp_err[beat_index] = vip_chi_resp_err_t'(flit.resperr);
    this.capture_dat_issue_specific_fields(flit, item, beat_index);

    this.dat_received_beats_by_key[key]++;

    // Retire on the correlated beat count when known (robust to a DUT that
    // holds or bubbles FLITPEND); otherwise trust the advisory FLITPEND.
    if (expected_beats > 0) begin
      transfer_done = (this.dat_received_beats_by_key[key] >= expected_beats);
    end
    else begin
      transfer_done = !flit_pending;
    end

    if (transfer_done) begin
      this.dat_port.write(item);
      this.dat_item_by_key.delete(key);
      this.dat_received_beats_by_key.delete(key);
      if (is_write_data) begin
        this.wr_beats_by_dbid.delete(dat_txn_id);
      end
      else begin
        this.rd_beats_by_txnid.delete(dat_txn_id);
      end
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Publish one SNP flit as a CHI item (single flit, no reassembly). The snoop
  // response (SnpResp on RSP, SnpRespData on DAT) is captured by publish_rsp /
  // publish_dat once those opcodes exist -- no extra work here.
  // ---------------------------------------------------------------------------
  protected function void publish_snp(
    input snp_flit_t     flit,
    input vip_chi_role_t observed_role
  );
    item_t item;

    item = new("monitor_snp_item");
    item.set_config(CFG_P);
    item.role             = observed_role;
    item.is_snoop         = 1'b1;
    item.src_id           = node_id_t'(flit.srcid);
    item.txn_id           = txn_id_t'(flit.txnid);
    item.fwd_nid          = node_id_t'(flit.fwdnid);
    item.fwd_txn_id       = txn_id_t'(flit.fwdtxnid);
    item.snp_opcode       = flit.opcode;
    item.snp_addr         = addr_t'(flit.addr);
    item.ns               = flit.ns;
    item.ret_to_src       = flit.rettosrc;
    item.do_not_data_pull = flit.donotdatapull;
    item.tracetag         = flit.tracetag;
    item.qos              = flit.qos;
    this.snp_port.write(item);
  endfunction

endclass

`endif