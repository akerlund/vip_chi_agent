`ifndef VIP_CHI_ITEM
`define VIP_CHI_ITEM

import uvm_pkg::*;
`include "uvm_macros.svh"
import vip_chi_types_pkg::*;

class vip_chi_item #(
  vip_chi_cfg_t CFG_P = VIP_CHI_DEFAULT_CFG_C
  ) extends uvm_sequence_item;

  // ---------------------------------------------------------------------------
  // Constants derived from CFG_P.
  // ---------------------------------------------------------------------------
  localparam int ADDR_WIDTH_C = CFG_P.ADDR_WIDTH_P;
  localparam int DATA_BYTES_C = CFG_P.DATA_BYTES_P;

  // ---------------------------------------------------------------------------
  // Central per-CFG_P typedef aliases. Item fields use these names so width
  // or issue changes land in vip_chi_types_pkg without an item rewrite.
  // ---------------------------------------------------------------------------
  typedef vip_chi_types #(CFG_P)::node_id_t    node_id_t;
  typedef vip_chi_types #(CFG_P)::addr_t       addr_t;
  typedef vip_chi_types #(CFG_P)::data_t       data_t;
  typedef vip_chi_types #(CFG_P)::be_t         be_t;
  typedef vip_chi_types #(CFG_P)::txn_id_t     txn_id_t;
  typedef vip_chi_types #(CFG_P)::req_opcode_t req_opcode_t;
  typedef vip_chi_types #(CFG_P)::rsp_opcode_t rsp_opcode_t;
  typedef vip_chi_types #(CFG_P)::dat_opcode_t dat_opcode_t;
  typedef vip_chi_types #(CFG_P)::lpid_t       lpid_t;
  typedef vip_chi_types #(CFG_P)::size_t       size_t;
  typedef vip_chi_types #(CFG_P)::tagop_t      tagop_t;
  typedef vip_chi_types #(CFG_P)::groupidext_t groupidext_t;
  typedef vip_chi_types #(CFG_P)::tag_t        tag_t;
  typedef vip_chi_types #(CFG_P)::tu_t         tu_t;
  typedef vip_chi_types #(CFG_P)::data_id_t    data_id_t;
  typedef vip_chi_types #(CFG_P)::cc_id_t      cc_id_t;
  typedef vip_chi_types #(CFG_P)::datacheck_t  datacheck_t;
  typedef vip_chi_types #(CFG_P)::poison_t     poison_t;
  typedef vip_chi_types #(CFG_P)::mpam_t       mpam_t;
  typedef vip_chi_types #(CFG_P)::snp_opcode_t snp_opcode_t;
  typedef vip_chi_types #(CFG_P)::req_flit_t   raw_req_t;
  typedef vip_chi_types #(CFG_P)::rsp_flit_t   raw_rsp_t;
  typedef vip_chi_types #(CFG_P)::dat_flit_t   raw_dat_t;
  typedef vip_chi_types #(CFG_P)::snp_flit_t   raw_snp_t;

  // ---------------------------------------------------------------------------
  // Common transaction identity and routing. These fields are shared across
  // request generation and completion correlation for both RN-I and SN-F use.
  // ---------------------------------------------------------------------------
  rand vip_chi_dir_t  direction     = VIP_CHI_DIR_READ_E;
  rand vip_chi_role_t role          = VIP_CHI_ROLE_RNI_E;
  rand node_id_t      src_id        = '0;
  rand node_id_t      tgt_id        = '0;
  rand txn_id_t       txn_id        = '0;
  rand lpid_t         lp_id         = '0;
  rand node_id_t      return_nid    = '0;
  rand txn_id_t       return_txn_id = '0;
  rand vip_chi_qos_t  qos = '0;

  // ---------------------------------------------------------------------------
  // Request payload. These fields describe the REQ flit randomized by
  // sequences before the driver maps the item onto the interface.
  // ---------------------------------------------------------------------------
  rand req_opcode_t   opcode       = req_opcode_t'(VIP_CHI_REQ_READ_NO_SNP_C);
  rand addr_t         addr         = '0;
  rand size_t         size         = '0;
  rand logic          ns           = 1'b1;
  rand logic [1 : 0]  order        = VIP_CHI_ORDER_NONE_E;
  rand logic [3 : 0]  mem_attr     = '0;
  rand vip_chi_pcrd_type_t pcrd_type = '0;
  rand logic          allow_retry  = 1'b1;
  rand logic          excl         = 1'b0;
  rand logic          exp_comp_ack = 1'b0;
  rand logic          tracetag     = 1'b0;
  rand logic          dodwt        = 1'b0;
  rand logic          likelyshared = 1'b0;
  rand logic          endian       = 1'b0;
  rand groupidext_t   group_id_ext = '0;
  rand tagop_t        tagop        = '0;
  rand mpam_t         mpam         = '0;
  rand datacheck_t    datacheck    = '0;
  rand poison_t       poison       = '0;

  // ---------------------------------------------------------------------------
  // DAT payload. For writes these arrays are prepared before send; for read
  // completions the monitor/driver will later populate the corresponding data.
  // ---------------------------------------------------------------------------
  tagop_t             dat_tagop    = '0;
  dat_opcode_t        dat_opcode   = dat_opcode_t'(VIP_CHI_DAT_COMP_DATA_C);
  data_t              data         [];
  be_t                be           [];
  tag_t               tag          [];
  tu_t                tu           [];
  data_id_t           data_id      [];
  cc_id_t             cc_id        [];
  vip_chi_resp_t      dat_resp     [];
  vip_chi_resp_err_t  dat_resp_err [];

  // ---------------------------------------------------------------------------
  // Response payload. These fields hold completion-side information observed
  // on RSP or derived while correlating RSP and DAT activity.
  // ---------------------------------------------------------------------------
  rsp_opcode_t        rsp_opcode   = rsp_opcode_t'(VIP_CHI_RSP_COMP_C);
  vip_chi_resp_t      rsp_resp     = VIP_CHI_RESP_STATE_I_E;
  vip_chi_resp_err_t  rsp_resp_err = VIP_CHI_RESP_ERR_NORMAL_OKAY_E;
  logic [2 : 0]       fwd_state    = '0;
  txn_id_t            dbid         = '0;

  // ---------------------------------------------------------------------------
  // Snoop payload (Tier C). Populated by the monitor for observed snoops and set
  // explicitly by RN-F/HN-F drivers and sequences. Not randomized (no coherent
  // role is legal for con_role_legal yet), so these do not perturb existing
  // randomization streams.
  // ---------------------------------------------------------------------------
  logic          is_snoop         = 1'b0;
  snp_opcode_t   snp_opcode       = snp_opcode_t'(VIP_CHI_SNP_SHARED_C);
  addr_t         snp_addr         = '0;
  node_id_t      fwd_nid          = '0;
  txn_id_t       fwd_txn_id       = '0;
  logic          ret_to_src       = 1'b0;
  logic          do_not_data_pull = 1'b0;
  vip_chi_resp_t snp_resp         = VIP_CHI_RESP_STATE_I_E;

  // ---------------------------------------------------------------------------
  // Raw override. When enabled, the driver emits the selected raw flit shape
  // verbatim instead of deriving a flit from the structured item fields.
  // ---------------------------------------------------------------------------
  bit                  raw_override = 1'b0;
  vip_chi_raw_channel_t raw_channel = VIP_CHI_RAW_NONE_E;
  logic                raw_flitpend = 1'b0;
  raw_req_t            raw_req      = '0;
  raw_rsp_t            raw_rsp      = '0;
  raw_dat_t            raw_dat      = '0;
  raw_snp_t            raw_snp      = '0;

  // ---------------------------------------------------------------------------
  // Per-item randomization knobs. These are not protocol fields; they steer
  // how the item randomizes and how helper code builds payload content.
  // ---------------------------------------------------------------------------
  vip_chi_cfg_t       cfg          = CFG_P;
  addr_t              min_addr     = '0;
  addr_t              max_addr     = '1;
  bit                 enforce_addr_alignment = 1'b1;
  bit                 atomic_strict_size = 1'b0;
  vip_chi_data_type_t data_type    = VIP_CHI_DATA_RANDOM_E;

  // ---------------------------------------------------------------------------
  // Internal payload-generation state used by CUSTOM and COUNTER data modes.
  // ---------------------------------------------------------------------------
  protected int       min_size     = 0;
  protected int       max_size     = 6;
  protected data_t    custom_data  [];
  protected be_t      custom_be    [];
  protected tag_t     custom_tag   [];
  protected tu_t      custom_tu    [];
  protected logic     deferred_custom_payload = 1'b0;
  protected data_t    counter_value     = '0;
  protected data_t    counter_increment = data_t'(1);

  `uvm_object_param_utils(vip_chi_item #(CFG_P))

  typedef vip_chi_item #(CFG_P) item_t;

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name = "vip_chi_item");

    super.new(name);
    this.cfg      = CFG_P;
    this.min_addr = '0;
    this.max_addr = '1;
  endfunction

  // ---------------------------------------------------------------------------
  // Apply a runtime cfg and require it to match the class parameterization.
  // ---------------------------------------------------------------------------
  function void set_config(input vip_chi_cfg_t cfg);

    if (!cfg_matches_param(cfg)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] set_config() does not match CFG_P",
        get_name()))
    end
    this.cfg = cfg;
  endfunction

  // ---------------------------------------------------------------------------
  // Pin Size to one exact CHI transfer-size encoding.
  // ---------------------------------------------------------------------------
  function void set_size(input size_t value);
    set_size_range(int'(value), int'(value));
  endfunction

  // ---------------------------------------------------------------------------
  // Constrain the legal randomization range for the CHI Size field.
  // ---------------------------------------------------------------------------
  function void set_size_range(input int min, input int max);

    if ((min < 0) || (max > 6) || (min > max)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Illegal size range [%0d:%0d]",
        get_name(), min, max))
    end
    this.min_size = min;
    this.max_size = max;
  endfunction

  // ---------------------------------------------------------------------------
  // Select the policy used to generate write payload data.
  // ---------------------------------------------------------------------------
  function void set_data_type(input vip_chi_data_type_t value);
    this.data_type = value;
  endfunction

  // ---------------------------------------------------------------------------
  // Enable or disable the default size-alignment constraint.
  // ---------------------------------------------------------------------------
  function void set_enforce_addr_alignment(input bit value);
    this.enforce_addr_alignment = value;
  endfunction

  // ---------------------------------------------------------------------------
  // Opt in to CHI-size-legal atomic operand generation. Default off preserves the
  // existing full-beat stress tests.
  // ---------------------------------------------------------------------------
  function void set_atomic_strict_size(input bit value);
    this.atomic_strict_size = value;
  endfunction

  // ---------------------------------------------------------------------------
  // Load custom per-beat data and switch the item into CUSTOM data mode.
  // ---------------------------------------------------------------------------
  function void set_data(input data_t value[]);

    this.custom_data = new[value.size()];
    foreach (value[i]) begin
      this.custom_data[i] = value[i];
    end
    this.data_type = VIP_CHI_DATA_CUSTOM_E;
  endfunction

  // ---------------------------------------------------------------------------
  // Load custom per-beat byte enables used alongside CUSTOM payload data.
  // ---------------------------------------------------------------------------
  function void set_be(input be_t value[]);

    this.custom_be = new[value.size()];
    foreach (value[i]) begin
      this.custom_be[i] = value[i];
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Load custom per-beat CHI-E Tag values for DAT payload beats.
  // ---------------------------------------------------------------------------
  function void set_tag(input tag_t value[]);

    this.custom_tag = new[value.size()];
    this.tag        = new[value.size()];
    foreach (value[i]) begin
      this.custom_tag[i] = value[i];
      this.tag[i]        = value[i];
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Load custom per-beat CHI-E TU values for DAT payload beats.
  // ---------------------------------------------------------------------------
  function void set_tu(input tu_t value[]);

    this.custom_tu = new[value.size()];
    this.tu        = new[value.size()];
    foreach (value[i]) begin
      this.custom_tu[i] = value[i];
      this.tu[i]        = value[i];
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Allow a sequence-owned payload buffer to populate CUSTOM data after
  // randomize() has sized the transfer-specific beat arrays.
  // ---------------------------------------------------------------------------
  function void set_deferred_custom_payload(input logic enable);
    this.deferred_custom_payload = enable;
  endfunction

  // ---------------------------------------------------------------------------
  // Set the starting value for COUNTER payload generation.
  // ---------------------------------------------------------------------------
  function void set_counter_value(input data_t start);
    this.counter_value = start;
  endfunction

  // ---------------------------------------------------------------------------
  // Set the per-beat increment for COUNTER payload generation.
  // ---------------------------------------------------------------------------
  function void set_counter_increment(input data_t increment);
    this.counter_increment = increment;
  endfunction

  // ---------------------------------------------------------------------------
  // Return the current counter state for the next COUNTER-generated beat.
  // ---------------------------------------------------------------------------
  function data_t get_counter();
    return this.counter_value;
  endfunction

  // ---------------------------------------------------------------------------
  // Override the request NS attribute.
  // ---------------------------------------------------------------------------
  function void set_src_id(input node_id_t value);
    this.src_id = value;
  endfunction

  // ---------------------------------------------------------------------------
  // Override the request target node identifier.
  // ---------------------------------------------------------------------------
  function void set_tgt_id(input node_id_t value);
    this.tgt_id = value;
  endfunction

  // ---------------------------------------------------------------------------
  // Override the request logical processor identifier.
  // ---------------------------------------------------------------------------
  function void set_lp_id(input lpid_t value);
    this.lp_id = value;
  endfunction

  // ---------------------------------------------------------------------------
  // Override the request return NodeID used by the remote completion path.
  // ---------------------------------------------------------------------------
  function void set_return_nid(input node_id_t value);
    this.return_nid = value;
  endfunction

  // ---------------------------------------------------------------------------
  // Override the request return TxnID used by the remote completion path.
  // ---------------------------------------------------------------------------
  function void set_return_txn_id(input txn_id_t value);
    this.return_txn_id = value;
  endfunction

  // ---------------------------------------------------------------------------
  // Override the request QoS value.
  // ---------------------------------------------------------------------------
  function void set_qos(input vip_chi_qos_t value);
    this.qos = value;
  endfunction

  // ---------------------------------------------------------------------------
  // Override the CHI-E TraceTag field.
  // ---------------------------------------------------------------------------
  function void set_tracetag(input logic value);
    this.tracetag = value;
  endfunction

  // ---------------------------------------------------------------------------
  // Override the CHI-E DoDWT field.
  // ---------------------------------------------------------------------------
  function void set_dodwt(input logic value);
    this.dodwt = value;
  endfunction

  // ---------------------------------------------------------------------------
  // Override the CHI-E LikelyShared field.
  // ---------------------------------------------------------------------------
  function void set_likelyshared(input logic value);
    this.likelyshared = value;
  endfunction

  // ---------------------------------------------------------------------------
  // Override the CHI-E Endian field.
  // ---------------------------------------------------------------------------
  function void set_endian(input logic value);
    this.endian = value;
  endfunction

  // ---------------------------------------------------------------------------
  // Override the CHI-E GroupIDExt field.
  // ---------------------------------------------------------------------------
  function void set_group_id_ext(input groupidext_t value);
    this.group_id_ext = value;
  endfunction

  // ---------------------------------------------------------------------------
  // Override the CHI-E TagOp field.
  // ---------------------------------------------------------------------------
  function void set_tagop(input tagop_t value);
    this.tagop = value;
  endfunction

  // ---------------------------------------------------------------------------
  // Override the CHI-E DAT TagOp field.
  // ---------------------------------------------------------------------------
  function void set_dat_tagop(input tagop_t value);
    this.dat_tagop = value;
  endfunction

  // ---------------------------------------------------------------------------
  // Clear any raw-override state and return the item to structured mode.
  // ---------------------------------------------------------------------------
  function void clear_raw_override();
    this.raw_override = 1'b0;
    this.raw_channel  = VIP_CHI_RAW_NONE_E;
    this.raw_flitpend = 1'b0;
    this.raw_req      = '0;
    this.raw_rsp      = '0;
    this.raw_dat      = '0;
    this.raw_snp      = '0;
  endfunction

  // ---------------------------------------------------------------------------
  // Emit one raw REQ flit verbatim on the next driver send.
  // ---------------------------------------------------------------------------
  function void set_raw_req(input raw_req_t value, input logic flitpend = 1'b0);
    this.clear_raw_override();
    this.raw_override = 1'b1;
    this.raw_channel  = VIP_CHI_RAW_REQ_E;
    this.raw_flitpend = flitpend;
    this.raw_req      = value;
  endfunction

  // ---------------------------------------------------------------------------
  // Emit one raw RSP flit verbatim on the next driver send.
  // ---------------------------------------------------------------------------
  function void set_raw_rsp(input raw_rsp_t value, input logic flitpend = 1'b0);
    this.clear_raw_override();
    this.raw_override = 1'b1;
    this.raw_channel  = VIP_CHI_RAW_RSP_E;
    this.raw_flitpend = flitpend;
    this.raw_rsp      = value;
  endfunction

  // ---------------------------------------------------------------------------
  // Emit one raw DAT flit verbatim on the next driver send.
  // ---------------------------------------------------------------------------
  function void set_raw_dat(input raw_dat_t value, input logic flitpend = 1'b0);
    this.clear_raw_override();
    this.raw_override = 1'b1;
    this.raw_channel  = VIP_CHI_RAW_DAT_E;
    this.raw_flitpend = flitpend;
    this.raw_dat      = value;
  endfunction

  // ---------------------------------------------------------------------------
  // Emit one raw SNP flit verbatim on the next driver send (Tier C).
  // ---------------------------------------------------------------------------
  function void set_raw_snp(input raw_snp_t value, input logic flitpend = 1'b0);
    this.clear_raw_override();
    this.raw_override = 1'b1;
    this.raw_channel  = VIP_CHI_RAW_SNP_E;
    this.raw_flitpend = flitpend;
    this.raw_snp      = value;
  endfunction

  // ---------------------------------------------------------------------------
  // Override the request NS attribute.
  // ---------------------------------------------------------------------------
  function void set_ns(input logic value);
    this.ns = value;
  endfunction

  // ---------------------------------------------------------------------------
  // Override the request ordering attribute.
  // ---------------------------------------------------------------------------
  function void set_order(input logic [1 : 0] value);
    this.order = value;
  endfunction

  // ---------------------------------------------------------------------------
  // Override the request MemAttr field.
  // ---------------------------------------------------------------------------
  function void set_mem_attr(input logic [3 : 0] value);
    this.mem_attr = value;
  endfunction

  // ---------------------------------------------------------------------------
  // Control whether the request permits RetryAck responses.
  // ---------------------------------------------------------------------------
  function void set_allow_retry(input logic value);
    this.allow_retry = value;
  endfunction

  // ---------------------------------------------------------------------------
  // Control whether ordered writes expect a later CompAck.
  // ---------------------------------------------------------------------------
  function void set_exp_comp_ack(input logic value);
    this.exp_comp_ack = value;
  endfunction

  // ---------------------------------------------------------------------------
  // Override the request exclusive-access attribute.
  // ---------------------------------------------------------------------------
  function void set_excl(input logic value);
    this.excl = value;
  endfunction

  // ---------------------------------------------------------------------------
  // Override the request PCrdType field.
  // ---------------------------------------------------------------------------
  function void set_pcrd_type(input vip_chi_pcrd_type_t value);
    this.pcrd_type = value;
  endfunction

  // ---------------------------------------------------------------------------
  // Check whether one REQ opcode is legal for this CFG_P and direction.
  // ---------------------------------------------------------------------------
  function bit req_opcode_is_legal(input req_opcode_t value, input vip_chi_dir_t dir);

    case (dir)
      VIP_CHI_DIR_READ_E: begin
        case (value)
          req_opcode_t'(VIP_CHI_REQ_READ_NO_SNP_C),
          req_opcode_t'(VIP_CHI_REQ_PREFETCH_TGT_C),
          req_opcode_t'(VIP_CHI_REQ_PCRD_RETURN_C),
          req_opcode_t'(VIP_CHI_REQ_READ_SHARED_C),
          req_opcode_t'(VIP_CHI_REQ_READ_CLEAN_C),
          req_opcode_t'(VIP_CHI_REQ_READ_UNIQUE_C): begin
            return 1'b1;
          end
          req_opcode_t'(VIP_CHI_REQ_READ_NO_SNP_SEP_C): begin
            return (CFG_P.ISSUE_P == VIP_CHI_ISSUE_E_E);
          end
          default: begin
            return 1'b0;
          end
        endcase
      end
      VIP_CHI_DIR_WRITE_E: begin
        case (value)
          req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_PTL_C),
          req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_FULL_C),
          req_opcode_t'(VIP_CHI_REQ_CLEAN_SHARED_PERSIST_C),
          req_opcode_t'(VIP_CHI_REQ_ATOMIC_STORE_0_C),
          req_opcode_t'(VIP_CHI_REQ_ATOMIC_STORE_1_C),
          req_opcode_t'(VIP_CHI_REQ_ATOMIC_STORE_2_C),
          req_opcode_t'(VIP_CHI_REQ_ATOMIC_STORE_3_C),
          req_opcode_t'(VIP_CHI_REQ_ATOMIC_STORE_4_C),
          req_opcode_t'(VIP_CHI_REQ_ATOMIC_STORE_5_C),
          req_opcode_t'(VIP_CHI_REQ_ATOMIC_STORE_6_C),
          req_opcode_t'(VIP_CHI_REQ_ATOMIC_STORE_7_C),
          req_opcode_t'(VIP_CHI_REQ_ATOMIC_LOAD_0_C),
          req_opcode_t'(VIP_CHI_REQ_ATOMIC_LOAD_1_C),
          req_opcode_t'(VIP_CHI_REQ_ATOMIC_LOAD_2_C),
          req_opcode_t'(VIP_CHI_REQ_ATOMIC_LOAD_3_C),
          req_opcode_t'(VIP_CHI_REQ_ATOMIC_LOAD_4_C),
          req_opcode_t'(VIP_CHI_REQ_ATOMIC_LOAD_5_C),
          req_opcode_t'(VIP_CHI_REQ_ATOMIC_LOAD_6_C),
          req_opcode_t'(VIP_CHI_REQ_ATOMIC_LOAD_7_C),
          req_opcode_t'(VIP_CHI_REQ_ATOMIC_SWAP_C),
          req_opcode_t'(VIP_CHI_REQ_ATOMIC_COMPARE_C),
          req_opcode_t'(VIP_CHI_REQ_PCRD_RETURN_C),
          req_opcode_t'(VIP_CHI_REQ_WRITE_BACK_FULL_C),
          req_opcode_t'(VIP_CHI_REQ_WRITE_CLEAN_FULL_C),
          req_opcode_t'(VIP_CHI_REQ_EVICT_C),
          req_opcode_t'(VIP_CHI_REQ_CLEAN_UNIQUE_C),
          req_opcode_t'(VIP_CHI_REQ_MAKE_UNIQUE_C): begin
            return 1'b1;
          end
          req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_ZERO_C),
          req_opcode_t'(VIP_CHI_REQ_CLEAN_SHARED_PERSIST_SEP_C): begin
            return (CFG_P.ISSUE_P == VIP_CHI_ISSUE_E_E);
          end
          default: begin
            return 1'b0;
          end
        endcase
      end
      default: begin
        return 1'b0;
      end
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // Return the number of DAT beats the current request must carry.
  // ---------------------------------------------------------------------------
  function int get_payload_beat_count();

    // AtomicCompare carries two operands (compare value + swap value). Per IHI
    // 0050 the REQ Size field is the COMBINED compare+swap size: the operand
    // payload is 2^Size bytes total, split in half (first half = compare, second
    // half = swap). So the operand-DAT length is chi_xfer_dat_beats(Size) for the
    // whole payload; the memory granule the RMW touches is the first half.
    // con_atomic_compare_size keeps each half beat-aligned (Size >= clog2(bus)+1)
    // so the split never falls inside a beat. [P2]
    if (vip_chi_types_pkg::vip_chi_req_opcode_is_atomic_compare(vip_chi_req_opcode_t'(opcode))) begin
      return vip_chi_types_pkg::chi_xfer_dat_beats(size, DATA_BYTES_C);
    end

    if (vip_chi_types_pkg::vip_chi_req_opcode_is_atomic(vip_chi_req_opcode_t'(opcode))) begin
      return vip_chi_types_pkg::chi_xfer_dat_beats(size, DATA_BYTES_C);
    end

    if ((opcode == req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_FULL_C)) ||
        (opcode == req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_PTL_C)) ||
        (opcode == req_opcode_t'(VIP_CHI_REQ_WRITE_BACK_FULL_C)) ||
        (opcode == req_opcode_t'(VIP_CHI_REQ_WRITE_CLEAN_FULL_C)) ||
        (opcode == req_opcode_t'(VIP_CHI_REQ_WRITE_UNIQUE_FULL_C)) ||
        (opcode == req_opcode_t'(VIP_CHI_REQ_WRITE_UNIQUE_PTL_C))) begin
      return vip_chi_types_pkg::chi_xfer_dat_beats(size, DATA_BYTES_C);
    end
    return 0;
  endfunction

  // ---------------------------------------------------------------------------
  // Validate user-provided randomization knobs before solving constraints.
  // ---------------------------------------------------------------------------
  function void pre_randomize();

    if (this.min_addr > this.max_addr) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] min_addr is larger than max_addr",
        get_name()))
    end

    if (this.data_type == VIP_CHI_DATA_CUSTOM_E) begin
      if ((this.custom_data.size() == 0) && !this.deferred_custom_payload) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] CUSTOM data_type requires set_data() before randomize()",
          get_name()))
      end
      if ((this.custom_data.size() != 0) &&
          (this.custom_be.size() != 0) &&
          (this.custom_be.size() != this.custom_data.size())) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] custom_be length must match custom_data length",
          get_name()))
      end
    end

    if ((this.custom_tag.size() != 0) &&
        (this.custom_tu.size() != 0) &&
        (this.custom_tu.size() != this.custom_tag.size())) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] custom_tu length must match custom_tag length",
        get_name()))
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Resize payload arrays and synthesize per-beat content after randomization.
  // ---------------------------------------------------------------------------
  function void post_randomize();
    int    beats;
    data_t next_counter;

    beats = get_payload_beat_count();

    if ((this.data_type == VIP_CHI_DATA_CUSTOM_E) &&
        (this.custom_data.size() != 0) &&
        (beats != this.custom_data.size())) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] custom_data beats=%0d but opcode/size require %0d beats",
        get_name(), this.custom_data.size(), beats))
    end

    if ((this.custom_data.size() != 0) &&
        (this.custom_be.size() != 0) &&
        (beats != this.custom_be.size())) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] custom_be beats=%0d but opcode/size require %0d beats",
        get_name(), this.custom_be.size(), beats))
    end

    if ((this.custom_tag.size() != 0) &&
        (beats != this.custom_tag.size())) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] custom_tag beats=%0d but opcode/size require %0d beats",
        get_name(), this.custom_tag.size(), beats))
    end

    if ((this.custom_tu.size() != 0) &&
        (beats != this.custom_tu.size())) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] custom_tu beats=%0d but opcode/size require %0d beats",
        get_name(), this.custom_tu.size(), beats))
    end

    this.data         = new[beats];
    this.be           = new[beats];
    this.tag          = new[beats];
    this.tu           = new[beats];
    this.data_id      = new[beats];
    this.cc_id        = new[beats];
    this.dat_resp     = new[beats];
    this.dat_resp_err = new[beats];

    next_counter = this.counter_value;
    for (int beat = 0; beat < beats; beat++) begin
      case (this.data_type)
        VIP_CHI_DATA_COUNTER_E: begin
          this.data[beat] = next_counter;
          next_counter   += this.counter_increment;
        end
        VIP_CHI_DATA_ZEROS_E: begin
          this.data[beat] = '0;
        end
        VIP_CHI_DATA_ONES_E: begin
          this.data[beat] = '1;
        end
        VIP_CHI_DATA_CUSTOM_E: begin
          if (this.custom_data.size() != 0) begin
            this.data[beat] = this.custom_data[beat];
          end
          else begin
            this.data[beat] = '0;
          end
        end
        default: begin
          this.data[beat] = make_random_data();
        end
      endcase

      if (this.custom_be.size() != 0) begin
        this.be[beat] = this.custom_be[beat];
      end
      else if ((this.opcode == req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_PTL_C)) ||
               (this.opcode == req_opcode_t'(VIP_CHI_REQ_WRITE_UNIQUE_PTL_C))) begin
        this.be[beat] = make_random_be();
      end
      else begin
        this.be[beat] = '1;
      end

      if (this.custom_tag.size() != 0) begin
        this.tag[beat] = this.custom_tag[beat];
      end
      else begin
        this.tag[beat] = '0;
      end

      if (this.custom_tu.size() != 0) begin
        this.tu[beat] = this.custom_tu[beat];
      end
      else begin
        this.tu[beat] = '0;
      end

      this.data_id[beat]      = data_id_t'(beat);
      this.cc_id[beat]        = cc_id_t'(beat);
      this.dat_resp[beat]     = VIP_CHI_RESP_STATE_I_E;
      this.dat_resp_err[beat] = VIP_CHI_RESP_ERR_NORMAL_OKAY_E;
    end

    if (this.data_type == VIP_CHI_DATA_COUNTER_E) begin
      this.counter_value = next_counter;
    end

    if (!CFG_P.DATACHECK_EN_P || (beats == 0)) begin
      this.datacheck = '0;
    end
    if (!CFG_P.POISON_EN_P || (beats == 0)) begin
      this.poison = '0;
    end
    if ((CFG_P.ISSUE_P != VIP_CHI_ISSUE_E_E) || (beats == 0)) begin
      this.dat_tagop = '0;
      foreach (this.tag[beat]) begin
        this.tag[beat] = '0;
      end
      foreach (this.tu[beat]) begin
        this.tu[beat] = '0;
      end
    end

    if ((this.opcode == req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_FULL_C)) ||
        (this.opcode == req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_PTL_C)) ||
        // WriteUnique is a non-allocating coherent write: its data travels as
        // NonCopyBackWrData (the requester is not an owner giving a line back).
        (this.opcode == req_opcode_t'(VIP_CHI_REQ_WRITE_UNIQUE_FULL_C)) ||
        (this.opcode == req_opcode_t'(VIP_CHI_REQ_WRITE_UNIQUE_PTL_C)) ||
        vip_chi_types_pkg::vip_chi_req_opcode_is_atomic(vip_chi_req_opcode_t'(this.opcode))) begin
      if (this.exp_comp_ack) begin
        this.dat_opcode = dat_opcode_t'(VIP_CHI_DAT_NCB_WR_DATA_COMP_ACK_C);
      end
      else begin
        this.dat_opcode = dat_opcode_t'(VIP_CHI_DAT_NON_COPY_BACK_WR_DATA_C);
      end
    end
    else if ((this.opcode == req_opcode_t'(VIP_CHI_REQ_WRITE_BACK_FULL_C)) ||
             (this.opcode == req_opcode_t'(VIP_CHI_REQ_WRITE_CLEAN_FULL_C))) begin
      // Coherent writeback data travels as CopyBackWrData.
      this.dat_opcode = dat_opcode_t'(VIP_CHI_DAT_COPY_BACK_WR_DATA_C);
    end
    else if (this.opcode == req_opcode_t'(VIP_CHI_REQ_READ_NO_SNP_SEP_C)) begin
      this.dat_opcode = dat_opcode_t'(VIP_CHI_DAT_DATA_SEP_RESP_C);
    end
    else begin
      this.dat_opcode = dat_opcode_t'(VIP_CHI_DAT_COMP_DATA_C);
    end

    this.deferred_custom_payload = 1'b0;
  endfunction

  // ---------------------------------------------------------------------------
  // Copy all scalar and dynamic-array state, including request/response payload.
  // ---------------------------------------------------------------------------
  function void do_copy(input uvm_object rhs);
    item_t rhs_item;

    super.do_copy(rhs);
    if (!$cast(rhs_item, rhs)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] do_copy() cast failed",
        get_name()))
    end

    this.direction               = rhs_item.direction;
    this.role                    = rhs_item.role;
    this.src_id                  = rhs_item.src_id;
    this.tgt_id                  = rhs_item.tgt_id;
    this.txn_id                  = rhs_item.txn_id;
    this.lp_id                   = rhs_item.lp_id;
    this.return_nid              = rhs_item.return_nid;
    this.return_txn_id           = rhs_item.return_txn_id;
    this.qos                     = rhs_item.qos;
    this.opcode                  = rhs_item.opcode;
    this.addr                    = rhs_item.addr;
    this.size                    = rhs_item.size;
    this.ns                      = rhs_item.ns;
    this.order                   = rhs_item.order;
    this.mem_attr                = rhs_item.mem_attr;
    this.pcrd_type               = rhs_item.pcrd_type;
    this.allow_retry             = rhs_item.allow_retry;
    this.excl                    = rhs_item.excl;
    this.exp_comp_ack            = rhs_item.exp_comp_ack;
    this.tracetag                = rhs_item.tracetag;
    this.dodwt                   = rhs_item.dodwt;
    this.likelyshared            = rhs_item.likelyshared;
    this.endian                  = rhs_item.endian;
    this.group_id_ext            = rhs_item.group_id_ext;
    this.tagop                   = rhs_item.tagop;
    this.dat_tagop               = rhs_item.dat_tagop;
    this.mpam                    = rhs_item.mpam;
    this.datacheck               = rhs_item.datacheck;
    this.poison                  = rhs_item.poison;
    this.dat_opcode              = rhs_item.dat_opcode;
    this.rsp_opcode              = rhs_item.rsp_opcode;
    this.rsp_resp                = rhs_item.rsp_resp;
    this.rsp_resp_err            = rhs_item.rsp_resp_err;
    this.fwd_state               = rhs_item.fwd_state;
    this.dbid                    = rhs_item.dbid;
    this.is_snoop                = rhs_item.is_snoop;
    this.snp_opcode              = rhs_item.snp_opcode;
    this.snp_addr                = rhs_item.snp_addr;
    this.fwd_nid                 = rhs_item.fwd_nid;
    this.fwd_txn_id              = rhs_item.fwd_txn_id;
    this.ret_to_src              = rhs_item.ret_to_src;
    this.do_not_data_pull        = rhs_item.do_not_data_pull;
    this.snp_resp                = rhs_item.snp_resp;
    this.raw_override            = rhs_item.raw_override;
    this.raw_channel             = rhs_item.raw_channel;
    this.raw_flitpend            = rhs_item.raw_flitpend;
    this.raw_req                 = rhs_item.raw_req;
    this.raw_rsp                 = rhs_item.raw_rsp;
    this.raw_dat                 = rhs_item.raw_dat;
    this.raw_snp                 = rhs_item.raw_snp;
    this.cfg                     = rhs_item.cfg;
    this.min_addr                = rhs_item.min_addr;
    this.max_addr                = rhs_item.max_addr;
    this.enforce_addr_alignment  = rhs_item.enforce_addr_alignment;
    this.atomic_strict_size      = rhs_item.atomic_strict_size;
    this.data_type               = rhs_item.data_type;
    this.min_size                = rhs_item.min_size;
    this.max_size                = rhs_item.max_size;
    this.deferred_custom_payload = rhs_item.deferred_custom_payload;
    this.counter_value           = rhs_item.counter_value;
    this.counter_increment       = rhs_item.counter_increment;

    this.data = new[rhs_item.data.size()];
    foreach (rhs_item.data[i]) begin
      this.data[i] = rhs_item.data[i];
    end

    this.be = new[rhs_item.be.size()];
    foreach (rhs_item.be[i]) begin
      this.be[i] = rhs_item.be[i];
    end

    this.tag = new[rhs_item.tag.size()];
    foreach (rhs_item.tag[i]) begin
      this.tag[i] = rhs_item.tag[i];
    end

    this.tu = new[rhs_item.tu.size()];
    foreach (rhs_item.tu[i]) begin
      this.tu[i] = rhs_item.tu[i];
    end

    this.data_id = new[rhs_item.data_id.size()];
    foreach (rhs_item.data_id[i]) begin
      this.data_id[i] = rhs_item.data_id[i];
    end

    this.cc_id = new[rhs_item.cc_id.size()];
    foreach (rhs_item.cc_id[i]) begin
      this.cc_id[i] = rhs_item.cc_id[i];
    end

    this.dat_resp = new[rhs_item.dat_resp.size()];
    foreach (rhs_item.dat_resp[i]) begin
      this.dat_resp[i] = rhs_item.dat_resp[i];
    end

    this.dat_resp_err = new[rhs_item.dat_resp_err.size()];
    foreach (rhs_item.dat_resp_err[i]) begin
      this.dat_resp_err[i] = rhs_item.dat_resp_err[i];
    end

    this.custom_data = new[rhs_item.custom_data.size()];
    foreach (rhs_item.custom_data[i]) begin
      this.custom_data[i] = rhs_item.custom_data[i];
    end

    this.custom_be = new[rhs_item.custom_be.size()];
    foreach (rhs_item.custom_be[i]) begin
      this.custom_be[i] = rhs_item.custom_be[i];
    end

    this.custom_tag = new[rhs_item.custom_tag.size()];
    foreach (rhs_item.custom_tag[i]) begin
      this.custom_tag[i] = rhs_item.custom_tag[i];
    end

    this.custom_tu = new[rhs_item.custom_tu.size()];
    foreach (rhs_item.custom_tu[i]) begin
      this.custom_tu[i] = rhs_item.custom_tu[i];
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Compare all scalar and dynamic-array state so payload-bearing items work
  // with UVM compare helpers.
  // ---------------------------------------------------------------------------
  function bit do_compare(input uvm_object rhs, input uvm_comparer comparer);
    item_t rhs_item;

    if (!super.do_compare(rhs, comparer)) begin
      return 1'b0;
    end

    if (!$cast(rhs_item, rhs)) begin
      return 1'b0;
    end

    if ((this.direction                !== rhs_item.direction) ||
        (this.role                     !== rhs_item.role) ||
        (this.src_id                   !== rhs_item.src_id) ||
        (this.tgt_id                   !== rhs_item.tgt_id) ||
        (this.txn_id                   !== rhs_item.txn_id) ||
        (this.lp_id                    !== rhs_item.lp_id) ||
        (this.return_nid               !== rhs_item.return_nid) ||
        (this.return_txn_id            !== rhs_item.return_txn_id) ||
        (this.qos                      !== rhs_item.qos) ||
        (this.opcode                   !== rhs_item.opcode) ||
        (this.addr                     !== rhs_item.addr) ||
        (this.size                     !== rhs_item.size) ||
        (this.ns                       !== rhs_item.ns) ||
        (this.order                    !== rhs_item.order) ||
        (this.mem_attr                 !== rhs_item.mem_attr) ||
        (this.pcrd_type                !== rhs_item.pcrd_type) ||
        (this.allow_retry              !== rhs_item.allow_retry) ||
        (this.excl                     !== rhs_item.excl) ||
        (this.exp_comp_ack             !== rhs_item.exp_comp_ack) ||
        (this.tracetag                 !== rhs_item.tracetag) ||
        (this.dodwt                    !== rhs_item.dodwt) ||
        (this.likelyshared             !== rhs_item.likelyshared) ||
        (this.endian                   !== rhs_item.endian) ||
        (this.group_id_ext             !== rhs_item.group_id_ext) ||
        (this.tagop                    !== rhs_item.tagop) ||
        (this.dat_tagop                !== rhs_item.dat_tagop) ||
        (this.mpam                     !== rhs_item.mpam) ||
        (this.datacheck                !== rhs_item.datacheck) ||
        (this.poison                   !== rhs_item.poison) ||
        (this.dat_opcode               !== rhs_item.dat_opcode) ||
        (this.rsp_opcode               !== rhs_item.rsp_opcode) ||
        (this.rsp_resp                 !== rhs_item.rsp_resp) ||
        (this.rsp_resp_err             !== rhs_item.rsp_resp_err) ||
        (this.fwd_state                !== rhs_item.fwd_state) ||
        (this.dbid                     !== rhs_item.dbid) ||
        (this.is_snoop                 !== rhs_item.is_snoop) ||
        (this.snp_opcode               !== rhs_item.snp_opcode) ||
        (this.snp_addr                 !== rhs_item.snp_addr) ||
        (this.fwd_nid                  !== rhs_item.fwd_nid) ||
        (this.fwd_txn_id               !== rhs_item.fwd_txn_id) ||
        (this.ret_to_src               !== rhs_item.ret_to_src) ||
        (this.do_not_data_pull         !== rhs_item.do_not_data_pull) ||
        (this.snp_resp                 !== rhs_item.snp_resp) ||
        (this.raw_override             !== rhs_item.raw_override) ||
        (this.raw_channel              !== rhs_item.raw_channel) ||
        (this.raw_flitpend             !== rhs_item.raw_flitpend) ||
        (this.raw_req                  !== rhs_item.raw_req) ||
        (this.raw_rsp                  !== rhs_item.raw_rsp) ||
        (this.raw_dat                  !== rhs_item.raw_dat) ||
        (this.raw_snp                  !== rhs_item.raw_snp) ||
        (this.cfg                      !== rhs_item.cfg) ||
        (this.min_addr                 !== rhs_item.min_addr) ||
        (this.max_addr                 !== rhs_item.max_addr) ||
        (this.enforce_addr_alignment   !== rhs_item.enforce_addr_alignment) ||
        (this.atomic_strict_size       !== rhs_item.atomic_strict_size) ||
        (this.data_type                !== rhs_item.data_type) ||
        (this.min_size                 !== rhs_item.min_size) ||
        (this.max_size                 !== rhs_item.max_size) ||
        (this.deferred_custom_payload  !== rhs_item.deferred_custom_payload) ||
        (this.counter_value            !== rhs_item.counter_value) ||
        (this.counter_increment        !== rhs_item.counter_increment)) begin
      return 1'b0;
    end

    if ((this.data.size() !== rhs_item.data.size()) ||
        (this.be.size() !== rhs_item.be.size()) ||
        (this.tag.size() !== rhs_item.tag.size()) ||
        (this.tu.size() !== rhs_item.tu.size()) ||
        (this.data_id.size() !== rhs_item.data_id.size()) ||
        (this.cc_id.size() !== rhs_item.cc_id.size()) ||
        (this.dat_resp.size() !== rhs_item.dat_resp.size()) ||
        (this.dat_resp_err.size() !== rhs_item.dat_resp_err.size()) ||
        (this.custom_data.size() !== rhs_item.custom_data.size()) ||
        (this.custom_be.size() !== rhs_item.custom_be.size()) ||
        (this.custom_tag.size() !== rhs_item.custom_tag.size()) ||
        (this.custom_tu.size() !== rhs_item.custom_tu.size())) begin
      return 1'b0;
    end

    foreach (this.data[i]) begin
      if (this.data[i] !== rhs_item.data[i]) begin
        return 1'b0;
      end
    end

    foreach (this.be[i]) begin
      if (this.be[i] !== rhs_item.be[i]) begin
        return 1'b0;
      end
    end

    foreach (this.tag[i]) begin
      if (this.tag[i] !== rhs_item.tag[i]) begin
        return 1'b0;
      end
    end

    foreach (this.tu[i]) begin
      if (this.tu[i] !== rhs_item.tu[i]) begin
        return 1'b0;
      end
    end

    foreach (this.data_id[i]) begin
      if (this.data_id[i] !== rhs_item.data_id[i]) begin
        return 1'b0;
      end
    end

    foreach (this.cc_id[i]) begin
      if (this.cc_id[i] !== rhs_item.cc_id[i]) begin
        return 1'b0;
      end
    end

    foreach (this.dat_resp[i]) begin
      if (this.dat_resp[i] !== rhs_item.dat_resp[i]) begin
        return 1'b0;
      end
    end

    foreach (this.dat_resp_err[i]) begin
      if (this.dat_resp_err[i] !== rhs_item.dat_resp_err[i]) begin
        return 1'b0;
      end
    end

    foreach (this.custom_data[i]) begin
      if (this.custom_data[i] !== rhs_item.custom_data[i]) begin
        return 1'b0;
      end
    end

    foreach (this.custom_be[i]) begin
      if (this.custom_be[i] !== rhs_item.custom_be[i]) begin
        return 1'b0;
      end
    end

    foreach (this.custom_tag[i]) begin
      if (this.custom_tag[i] !== rhs_item.custom_tag[i]) begin
        return 1'b0;
      end
    end

    foreach (this.custom_tu[i]) begin
      if (this.custom_tu[i] !== rhs_item.custom_tu[i]) begin
        return 1'b0;
      end
    end

    return 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Summarize the item's key routing and payload state for debug logs.
  // ---------------------------------------------------------------------------
  function string convert2string();
    return $sformatf(
      "%s dir=%0d role=%0d src=0x%0h tgt=0x%0h txn=0x%0h ret_nid=0x%0h ret_txn=0x%0h lp_id=0x%0h qos=0x%0h tracetag=%0b tagop=0x%0h dat_tagop=0x%0h dodwt=%0b likelyshared=%0b endian=%0b excl=%0b group_id_ext=0x%0h opcode=0x%0h addr=0x%0h size=%0d dbid=0x%0h dat_beats=%0d rsp_opcode=0x%0h rsp_resp=0x%0h rsp_resp_err=0x%0h raw=%0b raw_ch=%0d raw_pend=%0b raw_req=0x%0h raw_rsp=0x%0h raw_dat=0x%0h raw_snp=0x%0h is_snoop=%0b snp_opcode=0x%0h snp_addr=0x%0h snp_resp=0x%0h",
      super.convert2string(),
      this.direction,
      this.role,
      this.src_id,
      this.tgt_id,
      this.txn_id,
      this.return_nid,
      this.return_txn_id,
      this.lp_id,
      this.qos,
      this.tracetag,
      this.tagop,
      this.dat_tagop,
      this.dodwt,
      this.likelyshared,
      this.endian,
      this.excl,
      this.group_id_ext,
      this.opcode,
      this.addr,
      this.size,
      this.dbid,
      this.data.size(),
      this.rsp_opcode,
      this.rsp_resp,
        this.rsp_resp_err,
        this.raw_override,
        this.raw_channel,
        this.raw_flitpend,
        this.raw_req,
        this.raw_rsp,
        this.raw_dat,
        this.raw_snp,
        this.is_snoop,
        this.snp_opcode,
        this.snp_addr,
        this.snp_resp);
  endfunction

  // ---------------------------------------------------------------------------
  // Constraints: role is limited to the two currently supported active views.
  // ---------------------------------------------------------------------------
  constraint con_role_legal {
    if (!raw_override) {
      role inside {VIP_CHI_ROLE_SNF_E, VIP_CHI_ROLE_RNI_E, VIP_CHI_ROLE_RNF_E};
    }
  }

  // ---------------------------------------------------------------------------
  // Constraints: address range comes from the per-item randomization knobs.
  // ---------------------------------------------------------------------------
  constraint con_addr_range {
    if (!raw_override) {
      addr inside {[min_addr : max_addr]};
    }
  }

  // ---------------------------------------------------------------------------
  // Constraints: Size is randomized within the configured caller range.
  // ---------------------------------------------------------------------------
  constraint con_size_range {
    if (!raw_override) {
      size >= min_size;
      size <= max_size;
    }
  }

  // ---------------------------------------------------------------------------
  // Constraints: AtomicCompare Size is the COMBINED compare+swap size (IHI 0050),
  // so the operand payload spans two halves. Require each half to be at least one
  // bus beat (Size >= clog2(DATA_BYTES)+1) so the compare/swap split lands on a
  // beat boundary -- the SN-F RMW and the scoreboard predictor both model the
  // compare at beat granularity, so a sub-beat half is not supported. [P2]
  // ---------------------------------------------------------------------------
  constraint con_atomic_compare_size {
    if (!raw_override && (opcode == req_opcode_t'(VIP_CHI_REQ_ATOMIC_COMPARE_C))) {
      size >= ($clog2(DATA_BYTES_C) + 1);
    }
  }

  // ---------------------------------------------------------------------------
  // Constraints: AtomicCompare is unmodellable on a wide bus. Its combined
  // compare+swap Size must be at least one bus beat per half (con_atomic_compare_size:
  // Size >= clog2(DATA_BYTES)+1). On a >= 64 B bus that floor is Size 7, which
  // exceeds the largest legal CHI Size (6 = 64 B), so no Size satisfies it -- a free
  // write-opcode draw that lands on AtomicCompare would make randomize() fail
  // (CNST-CIF). Exclude it from random draws on such configs; the AtomicCompare
  // sequence independently fatals with an explicit geometry message there. [P2]
  // ---------------------------------------------------------------------------
  constraint con_atomic_compare_supported {
    if (!raw_override && (($clog2(DATA_BYTES_C) + 1) > 6)) {
      opcode != req_opcode_t'(VIP_CHI_REQ_ATOMIC_COMPARE_C);
    }
  }

  // ---------------------------------------------------------------------------
  // Constraints: optional spec-size legality for atomics. The default stress mode
  // allows full bus-beat atomics; when enabled, ordinary atomics are limited to an
  // 8-byte operand (Size <= 3). AtomicCompare uses combined compare+swap Size, so
  // the largest strict compare is 16 bytes total (two 8-byte operands).
  // ---------------------------------------------------------------------------
  constraint con_atomic_strict_size {
    if (!raw_override && atomic_strict_size &&
        vip_chi_types_pkg::vip_chi_req_opcode_is_atomic(vip_chi_req_opcode_t'(opcode))) {
      if (opcode == req_opcode_t'(VIP_CHI_REQ_ATOMIC_COMPARE_C)) {
        size <= 4;
      }
      else {
        size <= 3;
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Constraints: default traffic is size-aligned so the first cut emits only
  // legal requests unless a test overrides the address explicitly.
  // ---------------------------------------------------------------------------
  constraint con_addr_alignment {
    if (!raw_override && enforce_addr_alignment) {
      (addr & ((addr_t'(1) << size) - addr_t'(1))) == '0;
    }
  }

  // ---------------------------------------------------------------------------
  // Constraints: REQ opcode set depends on both direction and CHI issue.
  // PCrdReturn is deliberately excluded (T1): the SN-F silently ignores it and
  // the RN-I unconditionally waits for a completion that never comes, so a plain
  // randomize() picking it would wedge the driver with no diagnostic. A test that
  // genuinely needs it must set it explicitly via raw_override.
  // ---------------------------------------------------------------------------
  constraint con_opcode_legal {
    if (!raw_override && (role != VIP_CHI_ROLE_RNF_E)) {
      if (direction == VIP_CHI_DIR_READ_E) {
        if (CFG_P.ISSUE_P == VIP_CHI_ISSUE_E_E) {
          opcode inside {
            req_opcode_t'(VIP_CHI_REQ_READ_NO_SNP_C),
            req_opcode_t'(VIP_CHI_REQ_PREFETCH_TGT_C),
            req_opcode_t'(VIP_CHI_REQ_READ_NO_SNP_SEP_C)
          };
        }
        else {
          opcode inside {
            req_opcode_t'(VIP_CHI_REQ_READ_NO_SNP_C),
            req_opcode_t'(VIP_CHI_REQ_PREFETCH_TGT_C)
          };
        }
      }
      else {
        if (CFG_P.ISSUE_P == VIP_CHI_ISSUE_E_E) {
          opcode inside {
            req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_PTL_C),
            req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_FULL_C),
            req_opcode_t'(VIP_CHI_REQ_CLEAN_SHARED_PERSIST_C),
            req_opcode_t'(VIP_CHI_REQ_ATOMIC_STORE_0_C),
            req_opcode_t'(VIP_CHI_REQ_ATOMIC_STORE_1_C),
            req_opcode_t'(VIP_CHI_REQ_ATOMIC_STORE_2_C),
            req_opcode_t'(VIP_CHI_REQ_ATOMIC_STORE_3_C),
            req_opcode_t'(VIP_CHI_REQ_ATOMIC_STORE_4_C),
            req_opcode_t'(VIP_CHI_REQ_ATOMIC_STORE_5_C),
            req_opcode_t'(VIP_CHI_REQ_ATOMIC_STORE_6_C),
            req_opcode_t'(VIP_CHI_REQ_ATOMIC_STORE_7_C),
            req_opcode_t'(VIP_CHI_REQ_ATOMIC_LOAD_0_C),
            req_opcode_t'(VIP_CHI_REQ_ATOMIC_LOAD_1_C),
            req_opcode_t'(VIP_CHI_REQ_ATOMIC_LOAD_2_C),
            req_opcode_t'(VIP_CHI_REQ_ATOMIC_LOAD_3_C),
            req_opcode_t'(VIP_CHI_REQ_ATOMIC_LOAD_4_C),
            req_opcode_t'(VIP_CHI_REQ_ATOMIC_LOAD_5_C),
            req_opcode_t'(VIP_CHI_REQ_ATOMIC_LOAD_6_C),
            req_opcode_t'(VIP_CHI_REQ_ATOMIC_LOAD_7_C),
            req_opcode_t'(VIP_CHI_REQ_ATOMIC_SWAP_C),
            req_opcode_t'(VIP_CHI_REQ_ATOMIC_COMPARE_C),
            req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_ZERO_C),
            req_opcode_t'(VIP_CHI_REQ_CLEAN_SHARED_PERSIST_SEP_C)
          };
        }
        else {
          opcode inside {
            req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_PTL_C),
            req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_FULL_C),
            req_opcode_t'(VIP_CHI_REQ_CLEAN_SHARED_PERSIST_C),
            req_opcode_t'(VIP_CHI_REQ_ATOMIC_STORE_0_C),
            req_opcode_t'(VIP_CHI_REQ_ATOMIC_STORE_1_C),
            req_opcode_t'(VIP_CHI_REQ_ATOMIC_STORE_2_C),
            req_opcode_t'(VIP_CHI_REQ_ATOMIC_STORE_3_C),
            req_opcode_t'(VIP_CHI_REQ_ATOMIC_STORE_4_C),
            req_opcode_t'(VIP_CHI_REQ_ATOMIC_STORE_5_C),
            req_opcode_t'(VIP_CHI_REQ_ATOMIC_STORE_6_C),
            req_opcode_t'(VIP_CHI_REQ_ATOMIC_STORE_7_C),
            req_opcode_t'(VIP_CHI_REQ_ATOMIC_LOAD_0_C),
            req_opcode_t'(VIP_CHI_REQ_ATOMIC_LOAD_1_C),
            req_opcode_t'(VIP_CHI_REQ_ATOMIC_LOAD_2_C),
            req_opcode_t'(VIP_CHI_REQ_ATOMIC_LOAD_3_C),
            req_opcode_t'(VIP_CHI_REQ_ATOMIC_LOAD_4_C),
            req_opcode_t'(VIP_CHI_REQ_ATOMIC_LOAD_5_C),
            req_opcode_t'(VIP_CHI_REQ_ATOMIC_LOAD_6_C),
            req_opcode_t'(VIP_CHI_REQ_ATOMIC_LOAD_7_C),
            req_opcode_t'(VIP_CHI_REQ_ATOMIC_SWAP_C),
            req_opcode_t'(VIP_CHI_REQ_ATOMIC_COMPARE_C)
          };
        }
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Constraints: coherent (RN-F) REQ opcode set. Kept separate from the
  // non-coherent con_opcode_legal (which excludes the RN-F role) so RN-I/SN-F
  // randomization is unchanged. M2 issues coherent reads only; the write/CMO
  // set is permitted here for the M4 writeback/evict flows but is inert until a
  // sequence generates it.
  // ---------------------------------------------------------------------------
  constraint con_opcode_legal_rnf {
    if (!raw_override && (role == VIP_CHI_ROLE_RNF_E)) {
      if (direction == VIP_CHI_DIR_READ_E) {
        opcode inside {
          req_opcode_t'(VIP_CHI_REQ_READ_SHARED_C),
          req_opcode_t'(VIP_CHI_REQ_READ_CLEAN_C),
          req_opcode_t'(VIP_CHI_REQ_READ_UNIQUE_C),
          // MakeReadUnique acquires Unique AND fetches data (read-family completion).
          req_opcode_t'(VIP_CHI_REQ_MAKE_READ_UNIQUE_C),
          // ReadOnce is a non-allocating snapshot read (M2).
          req_opcode_t'(VIP_CHI_REQ_READ_ONCE_C)
        };
      }
      else {
        opcode inside {
          req_opcode_t'(VIP_CHI_REQ_WRITE_BACK_FULL_C),
          req_opcode_t'(VIP_CHI_REQ_WRITE_CLEAN_FULL_C),
          req_opcode_t'(VIP_CHI_REQ_EVICT_C),
          req_opcode_t'(VIP_CHI_REQ_CLEAN_UNIQUE_C),
          // MakeUnique: no-data unique acquire (the requester will overwrite the
          // whole line). RSP-only Comp granting Unique-Dirty; the HN-F invalidates
          // every other holder via SnpMakeInvalid. Modeled by service_make_unique.
          req_opcode_t'(VIP_CHI_REQ_MAKE_UNIQUE_C),
          // CMO invalidating ops: RSP-only Comp completion, like Evict.
          req_opcode_t'(VIP_CHI_REQ_CLEAN_INVALID_C),
          req_opcode_t'(VIP_CHI_REQ_MAKE_INVALID_C),
          // WriteUnique: non-allocating coherent write (M2).
          req_opcode_t'(VIP_CHI_REQ_WRITE_UNIQUE_FULL_C),
          req_opcode_t'(VIP_CHI_REQ_WRITE_UNIQUE_PTL_C)
        };
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Constraints: separated-read return routing is only meaningful for
  // ReadNoSnpSep; all other requests clear the return path fields.
  // ---------------------------------------------------------------------------
  constraint con_return_path_fields {
    if (!raw_override && (opcode == req_opcode_t'(VIP_CHI_REQ_READ_NO_SNP_SEP_C))) {
      return_nid == src_id;
    }
    else if (!raw_override) {
      return_nid == '0;
      return_txn_id == '0;
    }
  }

  // ---------------------------------------------------------------------------
  // Constraints: ExpCompAck is limited to write flows that can legally use it.
  // ---------------------------------------------------------------------------
  constraint con_exp_comp_ack_legal {
    if (!raw_override && (direction == VIP_CHI_DIR_READ_E)) {
      exp_comp_ack == 1'b0;
    }
    if (!raw_override &&
        ((opcode == req_opcode_t'(VIP_CHI_REQ_PREFETCH_TGT_C)) ||
           (opcode == req_opcode_t'(VIP_CHI_REQ_PCRD_RETURN_C)) ||
           (opcode == req_opcode_t'(VIP_CHI_REQ_CLEAN_SHARED_PERSIST_C)) ||
           (opcode == req_opcode_t'(VIP_CHI_REQ_CLEAN_SHARED_PERSIST_SEP_C)) ||
           (opcode == req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_ZERO_C)) ||
           // MakeUnique is modeled as a plain RSP-only Comp (no CompAck), so a free
           // randomize() must not draw ExpCompAck and wedge the RN-F waiting to ack
           // a completion the HN-F never expects (T1/T2 trap-hardening).
           (opcode == req_opcode_t'(VIP_CHI_REQ_MAKE_UNIQUE_C)) ||
           vip_chi_types_pkg::vip_chi_req_opcode_is_atomic(vip_chi_req_opcode_t'(opcode)))) {
      exp_comp_ack == 1'b0;
    }
  }

  // ---------------------------------------------------------------------------
  // Constraints: issue-gated optional fields are forced to zero when absent.
  // ---------------------------------------------------------------------------
  constraint con_issue_gated_fields {
    if (!raw_override && (CFG_P.ISSUE_P != VIP_CHI_ISSUE_E_E)) {
      tracetag     == 1'b0;
      dodwt        == 1'b0;
      likelyshared == 1'b0;
      endian       == 1'b0;
      group_id_ext == '0;
      tagop        == '0;
    }
    if (!raw_override && !CFG_P.MPAM_EN_P) {
      mpam == '0;
    }
    if (!raw_override && !CFG_P.DATACHECK_EN_P) {
      datacheck == '0;
    }
    if (!raw_override && !CFG_P.POISON_EN_P) {
      poison == '0;
    }
  }

  // ---------------------------------------------------------------------------
  // Compare a runtime cfg with the compile-time CFG_P specialization.
  // ---------------------------------------------------------------------------
  protected function bit cfg_matches_param(input vip_chi_cfg_t cfg);

    return (cfg.ISSUE_P           == CFG_P.ISSUE_P)           &&
           (cfg.NODE_ID_WIDTH_P == CFG_P.NODE_ID_WIDTH_P) &&
           (cfg.ADDR_WIDTH_P    == CFG_P.ADDR_WIDTH_P)    &&
           (cfg.DATA_BYTES_P    == CFG_P.DATA_BYTES_P)    &&
           (cfg.DATACHECK_EN_P  == CFG_P.DATACHECK_EN_P)  &&
           (cfg.POISON_EN_P     == CFG_P.POISON_EN_P)     &&
           (cfg.MPAM_EN_P       == CFG_P.MPAM_EN_P)       &&
           (cfg.PARITY_EN_P     == CFG_P.PARITY_EN_P);
  endfunction

  // ---------------------------------------------------------------------------
  // Build one random full-width beat used by RANDOM payload mode.
  // ---------------------------------------------------------------------------
  protected function data_t make_random_data();
    data_t value;

    value = '0;
    for (int byte_idx = 0; byte_idx < DATA_BYTES_C; byte_idx++) begin
      value[(8 * byte_idx) +: 8] = $urandom;
    end
    return value;
  endfunction

  // ---------------------------------------------------------------------------
  // Build one random byte-enable mask and keep at least one byte active.
  // ---------------------------------------------------------------------------
  protected function be_t make_random_be();
    be_t value;

    value = '0;
    foreach (value[idx]) begin
      value[idx] = $urandom_range(0, 1);
    end
    if (value == '0) begin
      value[0] = 1'b1;
    end
    return value;
  endfunction

endclass

`endif
