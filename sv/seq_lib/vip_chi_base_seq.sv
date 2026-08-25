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

`ifndef VIP_CHI_BASE_SEQ
`define VIP_CHI_BASE_SEQ

import uvm_pkg::*;
`include "uvm_macros.svh"
import vip_chi_types_pkg::*;

class vip_chi_base_seq #(
  vip_chi_cfg_t CFG_P = VIP_CHI_DEFAULT_CFG_C
  ) extends uvm_sequence #(vip_chi_item #(CFG_P));

  `uvm_object_param_utils(vip_chi_base_seq #(CFG_P))

  typedef vip_chi_item  #(CFG_P) item_t;
  typedef item_t                 responses_t [$];
  typedef vip_chi_types #(CFG_P)::addr_t       addr_t;
  typedef vip_chi_types #(CFG_P)::data_t       data_t;
  typedef vip_chi_types #(CFG_P)::be_t         be_t;
  typedef vip_chi_types #(CFG_P)::node_id_t    node_id_t;
  typedef vip_chi_types #(CFG_P)::txn_id_t     txn_id_t;
  typedef vip_chi_types #(CFG_P)::lpid_t       lpid_t;
  typedef vip_chi_types #(CFG_P)::tagop_t      tagop_t;
  typedef vip_chi_types #(CFG_P)::groupidext_t groupidext_t;
  typedef vip_chi_types #(CFG_P)::tag_t        tag_t;
  typedef vip_chi_types #(CFG_P)::tu_t         tu_t;
  typedef vip_chi_types #(CFG_P)::req_opcode_t req_opcode_t;

  protected vip_chi_seq_config                   cfg;
  protected vip_chi_cfg_item                     item_cfg;
  protected vip_chi_addr_iterator      #(CFG_P) addr_iter;
  protected vip_chi_seq_payload_buffer #(CFG_P) payload_buf;
  protected vip_chi_seq_counter_iter   #(CFG_P) counter_iter;

  protected logic       ns_val           = 1'b1;
  protected logic [1:0] order_val        = VIP_CHI_ORDER_NONE_E;
  // MemAttr and SnpAttr are opcode-derived for the same reason ExpCompAck is,
  // described below: IHI 0050 E section 2.9.3 fixes EWA, Cacheable and Allocate
  // per opcode, and Table 2-14 fixes SnpAttr per opcode, so "the value the
  // sequence stamps" is only meaningful once the opcode is known. Left alone,
  // the sequence reads both off the tables for the opcode it just chose; a
  // setter call turns the *_val into an override.
  protected logic [3:0] mem_attr_val     = 4'b0;
  protected bit         mem_attr_forced  = 1'b0;
  // Size joins MemAttr and SnpAttr as opcode-derived: Table A-3 fixes it at 64
  // bytes for every coherent read, dataless and CopyBack opcode and for the full
  // writes, leaving it free only on the Ptl forms, ReadNoSnp and the Atomics.
  // The default range is [0, 6], so before this the full writes randomized to
  // sizes the table does not allow them.
  protected bit         size_forced      = 1'b0;
  // Order is opcode-derived in exactly one place: Chapter 4 requires
  // ReadNoSnpSep to carry 0b01. Everywhere else the field is a caller policy, so
  // this flag exists only so that one requirement does not override an explicit
  // set_order().
  protected bit         order_forced     = 1'b0;
  protected vip_chi_snp_attr_t snp_attr_val    = VIP_CHI_SNP_NON_SNOOPABLE_E;
  protected bit                snp_attr_forced = 1'b0;
  protected logic       allow_retry_val  = 1'b1;
  // ExpCompAck is not a plain stamped field like the ones around it: IHI 0050 E
  // Table 2-9 / D Table 2-8 makes it required on some opcodes, optional on
  // others and forbidden on the rest, so "the value the sequence stamps" is only
  // meaningful once the opcode is known. exp_comp_ack_val therefore holds an
  // OVERRIDE, and exp_comp_ack_forced says whether anyone asked for one. Left
  // alone, the sequence reads the answer off the table for the opcode it just
  // chose. This is what stops a plain coherent-read sequence from stamping the
  // zero that the item constraint now (correctly) refuses.
  protected logic       exp_comp_ack_val    = 1'b0;
  protected bit         exp_comp_ack_forced = 1'b0;
  protected logic       excl_val         = 1'b0;
  protected logic [3:0] pcrd_type_val    = 4'b0;
  protected node_id_t   src_id_val       = '0;
  protected node_id_t   tgt_id_val       = '0;
  protected lpid_t      lp_id_val        = '0;
  protected node_id_t   return_nid_val   = '0;
  protected bit         return_nid_forced = 1'b0;
  protected txn_id_t    return_txn_id_val = '0;
  protected logic [VIP_CHI_QOS_WIDTH_C - 1:0] qos_val = '0;
  protected logic       tracetag_val     = 1'b0;
  protected logic       dodwt_val        = 1'b0;
  protected logic       likelyshared_val = 1'b0;
  protected logic       endian_val       = 1'b0;
  protected groupidext_t group_id_ext_val = '0;
  protected tagop_t     tagop_val        = '0;
  protected tagop_t     dat_tagop_val    = '0;
  // Whether the test pinned the WriteData TagOp itself. Unpinned, it is
  // DERIVED from the request's TagOp -- see build_request_item.
  protected bit         dat_tagop_forced = 1'b0;
  protected tag_t       tag_val          [];
  protected tu_t        tu_val           [];
  protected bit         sep_read_enabled = 1'b0;
  // When set, body() launches every request before collecting any response, so
  // a multi-outstanding driver (cfg.multi_outstanding) can overlap them. Default
  // 0 keeps the strict one-request-at-a-time send/collect loop.
  bit                   pipelined_send   = 1'b0;

  protected responses_t responses;

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name = "vip_chi_base_seq");

    super.new(name);
    this.cfg          = vip_chi_seq_config                  ::type_id::create("cfg");
    this.item_cfg     = vip_chi_cfg_item                    ::type_id::create("item_cfg");
    this.addr_iter    = vip_chi_addr_iterator      #(CFG_P)::type_id::create("addr_iter");
    this.payload_buf  = vip_chi_seq_payload_buffer #(CFG_P)::type_id::create("payload_buf");
    this.counter_iter = vip_chi_seq_counter_iter   #(CFG_P)::type_id::create("counter_iter");
    this.reset();
  endfunction

  // ---------------------------------------------------------------------------
  // Restore sequence state while preserving the direction pinned by a concrete
  // read/write subclass.
  // ---------------------------------------------------------------------------
  function void reset();

    vip_chi_dir_t saved_direction;
    bit           saved_oversized;

    saved_direction = this.item_cfg.direction;
    // Preserved for the same reason direction is: the wide-operand stress
    // profile is a property of the SEQUENCE, not of one
    // request, so it survives reset() the way direction does. Without this a
    // reset() mid-testcase would silently restore Table 2-17 and the next
    // set_size() above the ordinary limit would fail randomization rather than
    // drive the operand the testcase exists to drive.
    saved_oversized = this.item_cfg.atomic_oversized_operands;
    this.cfg.reset();
    this.item_cfg.reset();
    this.addr_iter.reset();
    this.payload_buf.reset();
    this.counter_iter.reset();

    this.item_cfg.direction                 = saved_direction;
    this.item_cfg.atomic_oversized_operands = saved_oversized;
    this.ns_val             = 1'b1;
    this.order_val          = VIP_CHI_ORDER_NONE_E;
    this.mem_attr_val       = 4'b0;
    this.allow_retry_val    = 1'b1;
    this.exp_comp_ack_val   = 1'b0;
    this.exp_comp_ack_forced = 1'b0;
    this.mem_attr_forced     = 1'b0;
    this.snp_attr_forced     = 1'b0;
    this.size_forced         = 1'b0;
    this.order_forced        = 1'b0;
    this.excl_val           = 1'b0;
    this.pcrd_type_val      = 4'b0;
    this.src_id_val         = '0;
    this.tgt_id_val         = '0;
    this.lp_id_val          = '0;
    this.return_nid_val     = '0;
    this.return_nid_forced  = 1'b0;
    this.return_txn_id_val  = '0;
    this.qos_val            = '0;
    this.tracetag_val       = 1'b0;
    this.snp_attr_val       = VIP_CHI_SNP_NON_SNOOPABLE_E;
    this.dodwt_val          = 1'b0;
    this.mem_attr_val       = 4'b0;
    this.likelyshared_val   = 1'b0;
    this.endian_val         = 1'b0;
    this.group_id_ext_val   = '0;
    this.tagop_val          = '0;
    this.dat_tagop_val      = '0;
    this.dat_tagop_forced   = 1'b0;
    this.tag_val.delete();
    this.tu_val.delete();
    this.sep_read_enabled   = 1'b0;
    this.pipelined_send     = 1'b0;
    this.responses.delete();
  endfunction

  // ---------------------------------------------------------------------------
  // Enable/disable pipelined send: launch all requests, then collect responses.
  // ---------------------------------------------------------------------------
  function void set_pipelined_send(input bit enabled);
    this.pipelined_send = enabled;
  endfunction

  // ---------------------------------------------------------------------------
  // Protected direction pin used by concrete read/write subclasses.
  // ---------------------------------------------------------------------------
  protected function void set_direction(input vip_chi_dir_t direction);
    this.item_cfg.direction = direction;
  endfunction

  // ---------------------------------------------------------------------------
  // Expose the currently pinned request direction for smoke checks.
  // ---------------------------------------------------------------------------
  function vip_chi_dir_t get_direction();
    return this.item_cfg.direction;
  endfunction

  // ---------------------------------------------------------------------------
  // Set how many requests the sequence should generate.
  // ---------------------------------------------------------------------------
  function void set_requests(input int requests);

    if (this.addr_iter.list_size() > 0) begin
      `uvm_warning(get_name(), $sformatf(
        "WARNING [%s] set_requests(%0d) called while addr_iter holds %0d list entries",
        get_name(), requests, this.addr_iter.list_size()))
    end

    if (requests < 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] set_requests(%0d) is negative",
        get_name(), requests))
    end

    if (this.item_cfg.data_type == VIP_CHI_DATA_CUSTOM_E) begin
      this.cfg.requests = VIP_CHI_UNLIMITED_REQUESTS_C;
    end
    else begin
      this.cfg.requests = requests;
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Set the first request address.
  // ---------------------------------------------------------------------------
  function void set_initial_addr(input addr_t addr);
    this.addr_iter.set_initial_addr(addr);
  endfunction

  // ---------------------------------------------------------------------------
  // Load an explicit per-request address list.
  // ---------------------------------------------------------------------------
  function void set_addr_list(input addr_t list []);

    this.addr_iter.load_list(list);
    this.cfg.requests = this.addr_iter.list_size();
    if (this.addr_iter.list_size() != 0) begin
      this.addr_iter.set_initial_addr(this.addr_iter.pop_list_front());
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Set a fixed address stride between requests. Zero restores auto-stride.
  // ---------------------------------------------------------------------------
  function void set_addr_stride(input longint stride);
    this.addr_iter.set_increment(stride);
  endfunction

  // ---------------------------------------------------------------------------
  // Enable or disable address advancement between requests.
  // ---------------------------------------------------------------------------
  function void set_addr_enabled(input bit enabled);
    this.addr_iter.set_enabled(enabled);
  endfunction

  // ---------------------------------------------------------------------------
  // Pin the CHI Size field to one exact value.
  // ---------------------------------------------------------------------------
  function void set_size(input logic [2:0] size);
    this.item_cfg.min_size = int'(size);
    this.item_cfg.max_size = int'(size);
    this.size_forced       = 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Constrain the CHI Size randomization range.
  // ---------------------------------------------------------------------------
  function void set_size_range(input int min_size, input int max_size);

    if ((min_size < 0) || (max_size > 6) || (min_size > max_size)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Illegal size range [%0d:%0d]",
        get_name(), min_size, max_size))
    end

    this.size_forced       = 1'b1;
    this.item_cfg.min_size = min_size;
    this.item_cfg.max_size = max_size;
  endfunction

  // ---------------------------------------------------------------------------
  // Enable or disable the default size-alignment rule on generated requests.
  // ---------------------------------------------------------------------------
  function void set_enforce_addr_alignment(input bit value);
    this.item_cfg.enforce_addr_alignment = value;
  endfunction

  // ---------------------------------------------------------------------------
  // Enable CHI-size-legal atomic operands (ordinary atomics <=8B; AtomicCompare
  // <=16B combined). Default off preserves the existing full-beat stress tests.
  // ---------------------------------------------------------------------------
  function void set_atomic_oversized_operands(input bit enabled);
    this.item_cfg.atomic_oversized_operands = enabled;
  endfunction

  // ---------------------------------------------------------------------------
  // Admit the combined Write + CMO opcodes into the randomized write pool.
  // Default off keeps every existing random write test emitting exactly what it
  // emitted before.
  // ---------------------------------------------------------------------------
  function void set_combined_write_cmo_enable(input bit enabled);
    this.item_cfg.combined_write_cmo_enable = enabled;
  endfunction

  function void set_write_unique_zero_enable(input bit enabled);
    this.item_cfg.write_unique_zero_enable = enabled;
  endfunction

  function void set_write_evict_or_evict_enable(input bit enabled);
    this.item_cfg.write_evict_or_evict_enable = enabled;
  endfunction

  // ---------------------------------------------------------------------------
  // Select the write payload generation mode.
  // ---------------------------------------------------------------------------
  function void set_data_type(input vip_chi_data_type_t data_type);
    this.item_cfg.data_type = data_type;
    if (data_type == VIP_CHI_DATA_CUSTOM_E) begin
      this.cfg.requests = VIP_CHI_UNLIMITED_REQUESTS_C;
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Load custom write payload beats and switch into CUSTOM mode.
  // ---------------------------------------------------------------------------
  function void set_data(input data_t data [$]);
    this.payload_buf.set_data(data);
    this.item_cfg.data_type = VIP_CHI_DATA_CUSTOM_E;
    this.cfg.requests = VIP_CHI_UNLIMITED_REQUESTS_C;
  endfunction

  // ---------------------------------------------------------------------------
  // Load custom byte enables for CUSTOM write payload mode.
  // ---------------------------------------------------------------------------
  function void set_be(input be_t be [$]);
    this.payload_buf.set_be(be);
  endfunction

  // ---------------------------------------------------------------------------
  // Set the first COUNTER-mode payload value.
  // ---------------------------------------------------------------------------
  function void set_counter_value(input data_t start);
    this.counter_iter.set_counter(start);
  endfunction

  // ---------------------------------------------------------------------------
  // Set the COUNTER-mode per-beat increment.
  // ---------------------------------------------------------------------------
  function void set_counter_increment(input data_t increment);
    this.counter_iter.set_increment(increment);
  endfunction

  // ---------------------------------------------------------------------------
  // Return the current COUNTER-mode value.
  // ---------------------------------------------------------------------------
  function data_t get_counter();
    return this.counter_iter.get_counter();
  endfunction

  // ---------------------------------------------------------------------------
  // Set the SrcID stamped onto every generated request.
  // ---------------------------------------------------------------------------
  function void set_src_id(input node_id_t src_id);
    this.src_id_val = src_id;
  endfunction

  // ---------------------------------------------------------------------------
  // Set the TgtID stamped onto every generated request.
  // ---------------------------------------------------------------------------
  function void set_tgt_id(input node_id_t tgt_id);
    this.tgt_id_val = tgt_id;
  endfunction

  // ---------------------------------------------------------------------------
  // Set the LPID stamped onto every generated request.
  // ---------------------------------------------------------------------------
  function void set_lp_id(input lpid_t lp_id);
    this.lp_id_val = lp_id;
  endfunction

  // ---------------------------------------------------------------------------
  // Set the ReturnNID stamped onto every generated request.
  // ---------------------------------------------------------------------------
  function void set_return_nid(input node_id_t return_nid);
    this.return_nid_val    = return_nid;
    this.return_nid_forced = 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Set the ReturnTxnID stamped onto every generated request.
  // ---------------------------------------------------------------------------
  function void set_return_txn_id(input txn_id_t return_txn_id);
    this.return_txn_id_val = return_txn_id;
  endfunction

  // ---------------------------------------------------------------------------
  // Set the QoS field stamped onto every generated request.
  // ---------------------------------------------------------------------------
  function void set_qos(input logic [VIP_CHI_QOS_WIDTH_C - 1:0] qos);
    this.qos_val = qos;
  endfunction

  // ---------------------------------------------------------------------------
  // Set the CHI-E TraceTag field stamped onto every generated request.
  // ---------------------------------------------------------------------------
  function void set_tracetag(input logic tracetag);
    this.tracetag_val = tracetag;
  endfunction

  // ---------------------------------------------------------------------------
  // Set the SnpAttr field stamped onto every generated request. Present in both
  // issues; see vip_chi_snp_attr_t.
  // ---------------------------------------------------------------------------
  function void set_snp_attr(input vip_chi_snp_attr_t snp_attr);
    this.snp_attr_val    = snp_attr;
    this.snp_attr_forced = 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Set the CHI-E DoDWT field stamped onto every generated request. Only the
  // opcodes vip_chi_req_dodwt_applicable() names carry the field; asking for a
  // one on any other request is rejected by the item rather than quietly
  // rewritten into SnpAttr, because the two share REQ bit 17.
  // ---------------------------------------------------------------------------
  function void set_dodwt(input logic dodwt);
    this.dodwt_val = dodwt;
  endfunction

  // ---------------------------------------------------------------------------
  // Set the CHI-E LikelyShared field stamped onto every generated request.
  // ---------------------------------------------------------------------------
  function void set_likelyshared(input logic likelyshared);
    this.likelyshared_val = likelyshared;
  endfunction

  // ---------------------------------------------------------------------------
  // Set the CHI-E Endian field stamped onto every generated request.
  // ---------------------------------------------------------------------------
  function void set_endian(input logic endian);
    this.endian_val = endian;
  endfunction

  // ---------------------------------------------------------------------------
  // Set the CHI-E GroupIDExt field stamped onto every generated request.
  // ---------------------------------------------------------------------------
  function void set_group_id_ext(input groupidext_t group_id_ext);
    this.group_id_ext_val = group_id_ext;
  endfunction

  // ---------------------------------------------------------------------------
  // Set the CHI-E TagOp field stamped onto every generated request.
  // ---------------------------------------------------------------------------
  function void set_tagop(input tagop_t tagop);
    this.tagop_val = tagop;
  endfunction

  // ---------------------------------------------------------------------------
  // Set the CHI-E DAT TagOp field stamped onto every generated write.
  // ---------------------------------------------------------------------------
  function void set_dat_tagop(input tagop_t dat_tagop);
    this.dat_tagop_val    = dat_tagop;
    this.dat_tagop_forced = 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Set the per-beat CHI-E DAT Tag values stamped onto every generated write.
  // ---------------------------------------------------------------------------
  function void set_tag(input tag_t tag[]);
    this.tag_val = new[tag.size()];
    foreach (tag[i]) begin
      this.tag_val[i] = tag[i];
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Set the per-beat CHI-E DAT TU values stamped onto every generated write.
  // ---------------------------------------------------------------------------
  function void set_tu(input tu_t tu[]);
    this.tu_val = new[tu.size()];
    foreach (tu[i]) begin
      this.tu_val[i] = tu[i];
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Set the NS attribute stamped onto every generated request.
  // ---------------------------------------------------------------------------
  function void set_ns(input logic ns);
    this.ns_val = ns;
  endfunction

  // ---------------------------------------------------------------------------
  // Set the Order field stamped onto every generated request.
  // ---------------------------------------------------------------------------
  function void set_order(input logic [1:0] order);
    this.order_val    = order;
    this.order_forced = 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Set the MemAttr field stamped onto every generated request.
  // ---------------------------------------------------------------------------
  function void set_mem_attr(input logic [3:0] mem_attr);
    this.mem_attr_val    = mem_attr;
    this.mem_attr_forced = 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Control whether generated requests allow RetryAck responses.
  // ---------------------------------------------------------------------------
  function void set_allow_retry(input logic allow_retry);
    this.allow_retry_val = allow_retry;
  endfunction

  // ---------------------------------------------------------------------------
  // Control whether generated writes expect a later CompAck.
  // ---------------------------------------------------------------------------
  function void set_exp_comp_ack(input logic exp_comp_ack);
    this.exp_comp_ack_val    = exp_comp_ack;
    this.exp_comp_ack_forced = 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Control the Excl field stamped onto every generated request.
  // ---------------------------------------------------------------------------
  function void set_excl(input logic excl);
    this.excl_val = excl;
  endfunction

  // ---------------------------------------------------------------------------
  // Set the PCrdType stamped onto generated requests.
  // ---------------------------------------------------------------------------
  function void set_pcrd_type(input logic [3:0] pcrd_type);
    this.pcrd_type_val = pcrd_type;
  endfunction

  // ---------------------------------------------------------------------------
  // Switch read traffic between ReadNoSnp and ReadNoSnpSep.
  // ---------------------------------------------------------------------------
  function void set_sep_read(input bit enabled);
    this.sep_read_enabled = enabled;
  endfunction

  // ---------------------------------------------------------------------------
  // Enable or disable synchronous response collection.
  // ---------------------------------------------------------------------------
  function void set_get_response(input bit enabled);
    this.item_cfg.get_response = enabled;
  endfunction

  // ---------------------------------------------------------------------------
  // Drain and return the collected response queue.
  // ---------------------------------------------------------------------------
  function responses_t get_responses();
    get_responses = this.responses;
    this.responses.delete();
  endfunction

  // ---------------------------------------------------------------------------
  // Configure an inter-request delay in units of one caller-supplied period.
  // ---------------------------------------------------------------------------
  function void set_request_delay(
    input bit      enabled,
    input int      min_delay,
    input int      max_delay,
    input realtime period
  );

    if ((min_delay < 0) || (max_delay < min_delay)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Illegal request delay range [%0d:%0d]",
        get_name(), min_delay, max_delay))
    end

    if (enabled && (period <= 0.0)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] request-delay period must be > 0 when enabled",
        get_name()))
    end

    this.cfg.request_delay_enabled = enabled;
    this.cfg.request_delay_min     = min_delay;
    this.cfg.request_delay_max     = max_delay;
    this.cfg.clock_period          = period;
  endfunction

  // ---------------------------------------------------------------------------
  // Enable or disable sequence progress logging.
  // ---------------------------------------------------------------------------
  function void set_verbose(input bit verbose);
    this.cfg.verbose = verbose;
  endfunction

  // ---------------------------------------------------------------------------
  // Control how often progress messages are printed.
  // ---------------------------------------------------------------------------
  function void set_log_denominator(input int log_denominator);

    if (log_denominator <= 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] log_denominator must be > 0",
        get_name()))
    end

    this.cfg.log_denominator = log_denominator;
  endfunction

  // ---------------------------------------------------------------------------
  // Generate items according to the configured iterator, payload, and stamp
  // state, then send them through the sequencer.
  // ---------------------------------------------------------------------------
  protected function item_t build_request_item(input int unsigned request_idx);
    item_t         req;
    vip_chi_dir_t  direction_val;
    req_opcode_t   opcode_val;
    vip_chi_role_t role_val_v;
    logic          exp_comp_ack_eff;
    logic [3:0]    mem_attr_eff;
    logic [1:0]    order_eff;
    node_id_t      return_nid_eff;
    bit            tag_match_write;
    vip_chi_snp_attr_t snp_attr_eff;

    req = new($sformatf("req_%0d", request_idx));
    req.set_config(CFG_P);

    if (this.item_cfg.data_type == VIP_CHI_DATA_CUSTOM_E) begin
      if (this.payload_buf.exhausted()) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] CUSTOM data mode requires queued payload data",
          get_name()))
      end
      this.payload_buf.clamp_size(this.item_cfg);
      req.set_deferred_custom_payload(1'b1);
    end

    req.set_size_range(this.item_cfg.min_size, this.item_cfg.max_size);
    req.set_data_type(this.item_cfg.data_type);
    req.set_enforce_addr_alignment(this.item_cfg.enforce_addr_alignment);
    req.set_atomic_oversized_operands(this.item_cfg.atomic_oversized_operands);
    req.set_combined_write_cmo_enable(this.item_cfg.combined_write_cmo_enable);
    req.set_write_unique_zero_enable(this.item_cfg.write_unique_zero_enable);
    req.set_write_evict_or_evict_enable(this.item_cfg.write_evict_or_evict_enable);
    req.min_addr = this.addr_iter.current();
    req.max_addr = this.addr_iter.current();
    req.set_ns(this.ns_val);
    req.set_allow_retry(this.allow_retry_val);
    req.set_excl(this.excl_val);
    req.set_pcrd_type(this.pcrd_type_val);
    this.counter_iter.configure_item(req);

    direction_val = this.item_cfg.direction;
    opcode_val    = this.choose_opcode();
    role_val_v    = this.role_val();

    // Has to come after choose_opcode(): the table is indexed by opcode, and
    // asking it before the opcode exists is how the field ended up being stamped
    // from a per-sequence constant in the first place. An explicit
    // set_exp_comp_ack() still wins -- including a deliberate zero, which the
    // item constraint will then reject if the opcode requires the bit, and that
    // rejection is the point.
    exp_comp_ack_eff = this.exp_comp_ack_forced ? this.exp_comp_ack_val
                     : vip_chi_types_pkg::vip_chi_exp_comp_ack_required(
                         vip_chi_req_opcode_t'(opcode_val),
                         (role_val_v == VIP_CHI_ROLE_RNF_E));
    req.set_exp_comp_ack(exp_comp_ack_eff);

    // The same shape for MemAttr and SnpAttr, and after choose_opcode() for the
    // same reason. The two must move together: Table 2-12 lists no Snoopable row
    // without Cacheable and EWA, so a request with SnpAttr = 1 over the old
    // all-zero MemAttr default would be a combination the table calls Not valid.
    mem_attr_eff = this.mem_attr_forced ? this.mem_attr_val
                 : vip_chi_types_pkg::vip_chi_req_mem_attr_default(
                     vip_chi_req_opcode_t'(opcode_val));
    snp_attr_eff = this.snp_attr_forced ? this.snp_attr_val
                 : ((vip_chi_types_pkg::vip_chi_snp_attr_requirement(
                       vip_chi_req_opcode_t'(opcode_val)) ==
                     vip_chi_types_pkg::VIP_CHI_SNP_ATTR_ONE_E)
                    ? VIP_CHI_SNP_SNOOPABLE_E : VIP_CHI_SNP_NON_SNOOPABLE_E);
    req.set_mem_attr(mem_attr_eff);
    req.set_snp_attr(snp_attr_eff);

    // Size, same shape again. An explicit set_size()/set_size_range() still
    // wins -- and if it names a size Table A-3 forbids for the chosen opcode,
    // CHI_REQ_SIZE_LEGAL reports it rather than the sequence silently
    // overriding the caller.
    if (!this.size_forced &&
        vip_chi_types_pkg::vip_chi_req_size_fixed_64b(
          vip_chi_req_opcode_t'(opcode_val))) begin
      req.set_size(VIP_CHI_REQ_SIZE_64B_C);
    end

    // ReturnNID, opcode-derived for the requests whose RESPONSE is routed by it.
    //
    // IHI 0050 E 2.8 sends a PCMO's Persist to ReturnNID rather than to SrcID,
    // so a combined Write + persistent CMO that leaves the field at zero asks
    // the completer to send the Persist to node 0. The requester wants it back,
    // so the default is its own node -- the same shape ReadNoSnpSep already has,
    // where the item pins return_nid == src_id.
    //
    // An explicit set_return_nid() still wins, which is what makes the routing
    // testable at all: a test can point the Persist at a node that is NOT the
    // requester and check where it lands. See F-CORR-012.
    //
    // A Match-tagged write is owed a TagMatch, and section 4.7's TgtID table
    // routes that response to ReturnNID when a Slave sends it. Section 2.5 gives
    // the expected value: "In WriteNoSnp with TagOp Match [...] the ReturnNID
    // value is expected to be the original Requester Node ID but is permitted to
    // be the Home Node ID." Left at the default of zero, the completer's answer
    // goes to node 0 and never reaches the requester that asked for the check.
    //
    // Known at build time because the tag operation is a SEQUENCE setting
    // (set_dat_tagop), not something decided per beat.
    tag_match_write = (this.dat_tagop_val == tagop_t'(VIP_CHI_TAGOP_MATCH_C)) &&
                      (direction_val == VIP_CHI_DIR_WRITE_E);

    return_nid_eff = this.return_nid_forced ? this.return_nid_val
                   : ((tag_match_write ||
                       (vip_chi_types_pkg::vip_chi_req_opcode_is_combined_write_cmo(
                          vip_chi_req_opcode_t'(opcode_val)) &&
                        vip_chi_types_pkg::vip_chi_req_opcode_combined_cmo_is_persist(
                          vip_chi_req_opcode_t'(opcode_val))))
                      ? this.src_id_val : this.return_nid_val);

    // Order, opcode-derived for the single opcode that mandates a value.
    order_eff = (!this.order_forced &&
                 (req_opcode_t'(opcode_val) ==
                  req_opcode_t'(VIP_CHI_REQ_READ_NO_SNP_SEP_C)))
              ? VIP_CHI_ORDER_REQ_ACCEPTED_E : this.order_val;
    req.set_order(order_eff);
    if (!req.randomize() with {
      direction     == direction_val;
      role          == local::role_val_v;
      opcode        == opcode_val;
      src_id        == local::this.src_id_val;
      tgt_id        == local::this.tgt_id_val;
      lp_id         == local::this.lp_id_val;
      return_nid    == local::return_nid_eff;
      return_txn_id == local::this.return_txn_id_val;
      qos           == local::this.qos_val;
      tracetag      == local::this.tracetag_val;
      snp_attr      == local::snp_attr_eff;
      dodwt         == local::this.dodwt_val;
      likelyshared  == local::this.likelyshared_val;
      endian        == local::this.endian_val;
      group_id_ext  == local::this.group_id_ext_val;
      tagop         == local::this.tagop_val;
      ns            == local::this.ns_val;
      order         == local::order_eff;
      mem_attr      == local::mem_attr_eff;
      allow_retry   == local::this.allow_retry_val;
      exp_comp_ack  == local::exp_comp_ack_eff;
      excl          == local::this.excl_val;
      pcrd_type     == local::this.pcrd_type_val;
    }) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Failed to randomize request %0d",
        get_name(), request_idx))
    end

    if (this.item_cfg.data_type == VIP_CHI_DATA_CUSTOM_E) begin
      this.payload_buf.apply(req, this.item_cfg);
    end

    // Unpinned, the WriteData TagOp FOLLOWS the request's. Section 12.5: "The
    // TagOp value in the WriteData message is typically the same as the value in
    // the Request message, except when either the write data is snooped out or
    // the write is canceled." 12.5.1 then gives the permitted WriteData values
    // per request value, and Invalid is on every one of those lists -- so the old
    // unconditional zero was never illegal, it just said "this write was
    // cancelled" on every write that asked for a tag operation, and the completer
    // had nothing to do. Nothing related the two fields at all before this.
    //
    // apply_dat_tagop also re-derives TU per 12.5.2; the item owns that because
    // the item owns the widths. A test that pinned either keeps its pin --
    // 12.5.1's Invalid case is a real behaviour a negative control needs to be
    // able to produce. See F-CORR-009.
    // Derive first, then let an explicit pin overwrite -- the same order as the
    // Python port, so the two cannot end up agreeing by different routes.
    req.apply_dat_tagop(this.dat_tagop_forced ? this.dat_tagop_val
                                              : tagop_t'(this.tagop_val));

    if (this.tag_val.size() != 0) begin
      req.set_tag(this.tag_val);
    end
    if (this.tu_val.size() != 0) begin
      req.set_tu(this.tu_val);
    end

    return req;
  endfunction

  // ---------------------------------------------------------------------------
  // Preview the next generated item without starting it on a sequencer.
  // ---------------------------------------------------------------------------
  virtual function item_t preview_next_request();
    return this.build_request_item(0);
  endfunction

  // ---------------------------------------------------------------------------
  // Generate items according to the configured iterator, payload, and stamp
  // state, then send them through the sequencer.
  // ---------------------------------------------------------------------------
  task body();
    item_t          req;
    item_t          rsp;
    int unsigned    request_idx;

    if ((this.cfg.requests == VIP_CHI_UNLIMITED_REQUESTS_C) &&
        (this.item_cfg.data_type != VIP_CHI_DATA_CUSTOM_E)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] unlimited requests are only supported in CUSTOM data mode",
        get_name()))
    end

    if ((this.item_cfg.data_type == VIP_CHI_DATA_CUSTOM_E) && this.payload_buf.exhausted()) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] CUSTOM data mode requires queued payload data",
        get_name()))
    end

    if (this.pipelined_send) begin
      this.pipelined_body();
      return;
    end

    request_idx = 0;
    forever begin
      if ((this.cfg.requests != VIP_CHI_UNLIMITED_REQUESTS_C) &&
          (request_idx >= this.cfg.requests)) begin
        break;
      end

      if ((this.item_cfg.data_type == VIP_CHI_DATA_CUSTOM_E) && this.payload_buf.exhausted()) begin
        break;
      end

      this.apply_request_delay(request_idx);
      this.cfg.log_status(int'(request_idx), this.access_name(), get_name());

      req = this.build_request_item(request_idx);

      start_item(req);
      finish_item(req);

      if (this.item_cfg.get_response) begin
        get_response(rsp);
        this.responses.push_back(rsp);
      end

      this.counter_iter.advance(req, this.item_cfg);
      void'(this.addr_iter.advance(req.size));
      request_idx++;
    end
  endtask

  // ---------------------------------------------------------------------------
  // Pipelined send: generate and launch every request first (finish_item
  // returns as soon as the driver has issued the request, not when it
  // completes), then drain the responses. Overlap only materializes when the
  // driver runs cfg.multi_outstanding; against a serial driver this collects
  // the same responses one-by-one and simply reorders the loop.
  // ---------------------------------------------------------------------------
  protected task pipelined_body();
    item_t       req;
    item_t       rsp;
    int unsigned n;

    if (this.item_cfg.data_type == VIP_CHI_DATA_CUSTOM_E) begin
      // CUSTOM mode is bounded by the queued payload, not cfg.requests
      // (set_requests pins cfg.requests to UNLIMITED in custom mode). Launch a
      // request per queued payload until the buffer drains; n is the count sent.
      n = 0;
      while (!this.payload_buf.exhausted()) begin
        this.cfg.log_status(int'(n), this.access_name(), get_name());
        req = this.build_request_item(n);

        start_item(req);
        finish_item(req);

        this.counter_iter.advance(req, this.item_cfg);
        void'(this.addr_iter.advance(req.size));
        n++;
      end
    end
    else begin
      if (this.cfg.requests == VIP_CHI_UNLIMITED_REQUESTS_C) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] pipelined_send requires a bounded request count",
          get_name()))
      end

      n = this.cfg.requests;

      for (int unsigned i = 0; i < n; i++) begin
        this.cfg.log_status(int'(i), this.access_name(), get_name());
        req = this.build_request_item(i);

        start_item(req);
        finish_item(req);

        this.counter_iter.advance(req, this.item_cfg);
        void'(this.addr_iter.advance(req.size));
      end
    end

    if (this.item_cfg.get_response) begin
      for (int unsigned i = 0; i < n; i++) begin
        get_response(rsp);
        this.responses.push_back(rsp);
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  // Apply the configured inter-request delay before request N>0.
  // ---------------------------------------------------------------------------
  protected task apply_request_delay(input int unsigned request_idx);
    int delay_cycles;

    if (!this.cfg.request_delay_enabled || (request_idx == 0)) begin
      return;
    end

    delay_cycles = $urandom_range(this.cfg.request_delay_max, this.cfg.request_delay_min);
    #(delay_cycles * this.cfg.clock_period);
  endtask

  // ---------------------------------------------------------------------------
  // Return the requester role stamped onto every generated request. Base is
  // RN-I; the coherent sequence overrides this to RN-F.
  // ---------------------------------------------------------------------------
  virtual protected function vip_chi_role_t role_val();
    return VIP_CHI_ROLE_RNI_E;
  endfunction

  // ---------------------------------------------------------------------------
  // Return the opcode stamped onto the next generated request.
  // ---------------------------------------------------------------------------
  virtual protected function req_opcode_t choose_opcode();

    if (this.item_cfg.direction == VIP_CHI_DIR_READ_E) begin
      if (this.sep_read_enabled) begin
        if (CFG_P.ISSUE_P != VIP_CHI_ISSUE_E_E) begin
          `uvm_fatal(get_name(), $sformatf(
            "FATAL [%s] ReadNoSnpSep is only legal under CHI-E",
            get_name()))
        end
        return req_opcode_t'(VIP_CHI_REQ_READ_NO_SNP_SEP_C);
      end
      return req_opcode_t'(VIP_CHI_REQ_READ_NO_SNP_C);
    end

    if (this.payload_buf.has_custom_be()) begin
      return req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_PTL_C);
    end
    return req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_FULL_C);
  endfunction

  // ---------------------------------------------------------------------------
  // Return a short access label for progress logging.
  // ---------------------------------------------------------------------------
  virtual protected function string access_name();

    if (this.item_cfg.direction == VIP_CHI_DIR_READ_E) begin
      if (this.sep_read_enabled) begin
        return "ReadNoSnpSep";
      end
      return "ReadNoSnp";
    end

    if (this.payload_buf.has_custom_be()) begin
      return "WriteNoSnpPtl";
    end
    return "WriteNoSnpFull";
  endfunction

endclass

`endif
