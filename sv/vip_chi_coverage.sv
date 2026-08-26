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

`uvm_analysis_imp_decl(_rni_req_cov_port)
`uvm_analysis_imp_decl(_rni_rsp_cov_port)
`uvm_analysis_imp_decl(_rni_dat_cov_port)
`uvm_analysis_imp_decl(_snf_req_cov_port)
`uvm_analysis_imp_decl(_snf_rsp_cov_port)
`uvm_analysis_imp_decl(_snf_dat_cov_port)
`uvm_analysis_imp_decl(_rnf_req_cov_port)
`uvm_analysis_imp_decl(_rnf_rsp_cov_port)
`uvm_analysis_imp_decl(_rnf_dat_cov_port)
`uvm_analysis_imp_decl(_snp_cov_port)

class vip_chi_coverage #(
  vip_chi_cfg_t CFG_P = VIP_CHI_DEFAULT_CFG_C
  ) extends uvm_component;

  `uvm_component_param_utils(vip_chi_coverage #(CFG_P))

  typedef vip_chi_item #(CFG_P) item_t;
  typedef item_t::txn_id_t       txn_id_t;
  typedef item_t::data_id_t      data_id_t;
  typedef item_t::req_opcode_t   req_opcode_t;
  typedef item_t::rsp_opcode_t   rsp_opcode_t;
  typedef item_t::dat_opcode_t   dat_opcode_t;
  typedef item_t::snp_opcode_t   snp_opcode_t;
  typedef item_t::size_t         size_t;
  typedef item_t::tagop_t        tagop_t;

  localparam int TXN_ID_COUNT_C = 2 ** $bits(txn_id_t);
  localparam int QOS_MAX_C = (1 << VIP_CHI_QOS_WIDTH_C) - 1;
  localparam int TAGOP_MAX_C = (1 << $bits(tagop_t)) - 1;

  typedef enum int unsigned {
    VIP_CHI_RECOVERY_REQ_E,
    VIP_CHI_RECOVERY_RSP_E,
    VIP_CHI_RECOVERY_DAT_E
  } recovery_channel_e;

  typedef enum int unsigned {
    VIP_CHI_QOS_REQ_E,
    VIP_CHI_QOS_RSP_E,
    VIP_CHI_QOS_DAT_E
  } qos_channel_e;

  typedef enum int unsigned {
    VIP_CHI_MTE_REQ_E,
    VIP_CHI_MTE_DAT_E
  } mte_channel_e;

  bit enabled = 1'b1;

  uvm_analysis_imp_rni_req_cov_port #(item_t, vip_chi_coverage #(CFG_P)) rni_req_cov_port;
  uvm_analysis_imp_rni_rsp_cov_port #(item_t, vip_chi_coverage #(CFG_P)) rni_rsp_cov_port;
  uvm_analysis_imp_rni_dat_cov_port #(item_t, vip_chi_coverage #(CFG_P)) rni_dat_cov_port;
  uvm_analysis_imp_snf_req_cov_port #(item_t, vip_chi_coverage #(CFG_P)) snf_req_cov_port;
  uvm_analysis_imp_snf_rsp_cov_port #(item_t, vip_chi_coverage #(CFG_P)) snf_rsp_cov_port;
  uvm_analysis_imp_snf_dat_cov_port #(item_t, vip_chi_coverage #(CFG_P)) snf_dat_cov_port;
  // Coherent (Tier C): RN-F coherent requests + snoop responses, plus the SNP
  // channel. Wired only in the coherent env; unconnected (and thus silent) on
  // the non-coherent shared env.
  uvm_analysis_imp_rnf_req_cov_port #(item_t, vip_chi_coverage #(CFG_P)) rnf_req_cov_port;
  uvm_analysis_imp_rnf_rsp_cov_port #(item_t, vip_chi_coverage #(CFG_P)) rnf_rsp_cov_port;
  uvm_analysis_imp_rnf_dat_cov_port #(item_t, vip_chi_coverage #(CFG_P)) rnf_dat_cov_port;
  uvm_analysis_imp_snp_cov_port     #(item_t, vip_chi_coverage #(CFG_P)) snp_cov_port;

  protected item_t              req_item;
  protected item_t              rsp_item;
  protected item_t              dat_item;
  protected int unsigned        dat_beats_sample;
  protected bit                 post_reset_epoch_sample;
  protected int unsigned        reset_epoch;
  protected bit                 req_transfer_aligned_sample;
  protected bit                 req_cacheline_aligned_sample;
  protected int                 atomic_kind_sample;
  protected size_t              atomic_size_sample;
  protected bit                 atomic_returns_data_sample;
  protected vip_chi_qos_t       qos_sample;
  protected qos_channel_e       qos_channel_sample;
  protected mte_channel_e       mte_channel_sample;
  protected tagop_t             mte_tagop_sample;
  protected bit                 mte_tag_nonzero_sample;
  protected bit                 mte_tu_nonzero_sample;
  protected logic [1 : 0]       ordered_read_order_sample;
  protected dat_opcode_t        ordered_read_dat_opcode_sample;
  protected bit                 ordered_read_receipt_seen_sample;
  protected vip_chi_resp_err_t  dat_resp_err_sample;
  protected bit                 dat_first_data_id_zero_sample;
  protected bit                 dat_data_ids_contiguous_sample;
  protected bit                 dat_write_txn_matches_dbid_sample;
  protected rsp_opcode_t        write_first_rsp_opcode_sample;
  protected rsp_opcode_t        write_completion_rsp_opcode_sample;
  protected dat_opcode_t        write_dat_opcode_sample;
  protected bit                 write_flow_comp_ack_expected_sample;
  protected bit                 write_flow_comp_ack_seen_sample;
  protected bit                 write_flow_dbid_matches_req_txn_sample;
  protected bit                 write_flow_split_sample;
  protected recovery_channel_e  recovery_channel_sample;
  protected vip_chi_role_t      recovery_role_sample;
  protected bit                 write_req_seen_by_txn[TXN_ID_COUNT_C];
  protected bit                 write_first_rsp_seen_by_txn[TXN_ID_COUNT_C];
  protected bit                 write_completion_seen_by_txn[TXN_ID_COUNT_C];
  protected bit                 write_dat_seen_by_txn[TXN_ID_COUNT_C];
  protected bit                 write_comp_ack_seen_by_txn[TXN_ID_COUNT_C];
  protected bit                 write_flow_sampled_by_txn[TXN_ID_COUNT_C];
  protected bit                 write_exp_comp_ack_by_txn[TXN_ID_COUNT_C];
  protected bit                 write_dbid_matches_req_by_txn[TXN_ID_COUNT_C];
  protected int unsigned        outstanding_reads_sample;
  protected int unsigned        outstanding_writes_sample;
  protected bit                 granted_req_txn_valid_by_dbid[TXN_ID_COUNT_C];
  protected txn_id_t            granted_req_txn_by_dbid[TXN_ID_COUNT_C];
  protected rsp_opcode_t        write_first_rsp_opcode_by_txn[TXN_ID_COUNT_C];
  protected rsp_opcode_t        write_completion_rsp_opcode_by_txn[TXN_ID_COUNT_C];
  protected dat_opcode_t        write_dat_opcode_by_txn[TXN_ID_COUNT_C];
  protected bit                 post_reset_req_recovered_by_role[2];
  protected bit                 post_reset_rsp_recovered_by_role[2];
  protected bit                 post_reset_dat_recovered_by_role[2];
  protected bit                 ordered_read_req_seen_by_completion_txn[TXN_ID_COUNT_C];
  protected bit                 ordered_read_receipt_seen_by_completion_txn[TXN_ID_COUNT_C];
  protected bit                 ordered_read_completion_valid_by_req[TXN_ID_COUNT_C];
  protected txn_id_t            ordered_read_completion_txn_by_req[TXN_ID_COUNT_C];

  // Coherent (Tier C) sample scratch.
  protected item_t              coh_req_item;
  protected snp_opcode_t        snp_opcode_sample;
  protected vip_chi_resp_t      snp_resp_state_sample;
  protected bit                 snp_resp_pass_dirty_sample;

  covergroup cg_req;
    option.per_instance = 1;

    cp_role: coverpoint this.req_item.role {
      bins rni = {VIP_CHI_ROLE_RNI_E};
      bins snf = {VIP_CHI_ROLE_SNF_E};
    }

    cp_dir: coverpoint this.req_item.direction {
      bins read  = {VIP_CHI_DIR_READ_E};
      bins write = {VIP_CHI_DIR_WRITE_E};
    }

    cp_opcode: coverpoint this.req_item.opcode {
      bins read_no_snp       = {VIP_CHI_REQ_READ_NO_SNP_E};
      bins read_no_snp_sep   = {VIP_CHI_REQ_READ_NO_SNP_SEP_E};
      bins write_no_snp_ptl  = {VIP_CHI_REQ_WRITE_NO_SNP_PTL_E};
      bins write_no_snp_full = {VIP_CHI_REQ_WRITE_NO_SNP_FULL_E};
      bins write_no_snp_zero = {VIP_CHI_REQ_WRITE_NO_SNP_ZERO_E};
      bins prefetch_tgt      = {VIP_CHI_REQ_PREFETCH_TGT_E};
    }

    cp_size: coverpoint this.req_item.size {
      bins size_small  = {[0:2]};
      bins size_medium = {[3:5]};
      bins size_large  = {6};
    }

    cp_comp_ack: coverpoint this.req_item.exp_comp_ack {
      bins no  = {1'b0};
      bins yes = {1'b1};
    }

    cp_allow_retry: coverpoint this.req_item.allow_retry {
      bins no  = {1'b0};
      bins yes = {1'b1};
    }

    cp_epoch: coverpoint this.post_reset_epoch_sample {
      bins pre_reset_epoch  = {1'b0};
      bins post_reset_epoch = {1'b1};
    }

    cx_opcode_dir: cross cp_opcode, cp_dir;
    cx_opcode_comp_ack: cross cp_opcode, cp_comp_ack;
    cx_opcode_epoch: cross cp_opcode, cp_epoch;
  endgroup

  covergroup cg_rsp;
    option.per_instance = 1;

    cp_role: coverpoint this.rsp_item.role {
      bins rni = {VIP_CHI_ROLE_RNI_E};
      bins snf = {VIP_CHI_ROLE_SNF_E};
    }

    cp_opcode: coverpoint this.rsp_item.rsp_opcode {
      bins comp           = {VIP_CHI_RSP_COMP_E};
      bins comp_dbid_resp = {VIP_CHI_RSP_COMP_DBID_RESP_E};
      bins dbid_resp      = {VIP_CHI_RSP_DBID_RESP_E};
      bins comp_ack       = {VIP_CHI_RSP_COMP_ACK_E};
      bins read_receipt   = {VIP_CHI_RSP_READ_RECEIPT_E};
    }

    cp_resp_err: coverpoint this.rsp_item.rsp_resp_err {
      bins normal   = {VIP_CHI_RESP_ERR_NORMAL_OKAY_E};
      bins exokay   = {VIP_CHI_RESP_ERR_EXCLUSIVE_OKAY_E};
      bins dataerr  = {VIP_CHI_RESP_ERR_DATA_ERROR_E};
      bins nderr    = {VIP_CHI_RESP_ERR_NONDATA_ERROR_E};
    }

    cp_epoch: coverpoint this.post_reset_epoch_sample {
      bins pre_reset_epoch  = {1'b0};
      bins post_reset_epoch = {1'b1};
    }

    cx_opcode_resp_err: cross cp_opcode, cp_resp_err;
    cx_opcode_epoch: cross cp_opcode, cp_epoch;
  endgroup

  covergroup cg_dat;
    option.per_instance = 1;

    cp_role: coverpoint this.dat_item.role {
      bins rni = {VIP_CHI_ROLE_RNI_E};
      bins snf = {VIP_CHI_ROLE_SNF_E};
    }

    cp_opcode: coverpoint this.dat_item.dat_opcode {
      bins wr_data          = {VIP_CHI_DAT_NON_COPY_BACK_WR_DATA_E};
      bins comp_data        = {VIP_CHI_DAT_COMP_DATA_E};
      bins wr_data_comp_ack = {VIP_CHI_DAT_NCB_WR_DATA_COMP_ACK_E};
      bins sep_resp         = {VIP_CHI_DAT_DATA_SEP_RESP_E};
    }

    cp_beats: coverpoint this.dat_beats_sample {
      bins one   = {1};
      bins few   = {[2:4]};
      bins many  = {[5:$]};
    }

    cp_resp_err: coverpoint this.dat_resp_err_sample {
      bins normal   = {VIP_CHI_RESP_ERR_NORMAL_OKAY_E};
      bins exokay   = {VIP_CHI_RESP_ERR_EXCLUSIVE_OKAY_E};
      bins dataerr  = {VIP_CHI_RESP_ERR_DATA_ERROR_E};
      bins nderr    = {VIP_CHI_RESP_ERR_NONDATA_ERROR_E};
    }

    cp_first_data_id_zero: coverpoint this.dat_first_data_id_zero_sample {
      bins no  = {1'b0};
      bins yes = {1'b1};
    }

    cp_data_ids_contiguous: coverpoint this.dat_data_ids_contiguous_sample {
      bins no  = {1'b0};
      bins yes = {1'b1};
    }

    cp_write_txn_matches_dbid: coverpoint this.dat_write_txn_matches_dbid_sample iff (
      (this.dat_item.dat_opcode == dat_opcode_t'(VIP_CHI_DAT_NON_COPY_BACK_WR_DATA_E)) ||
      (this.dat_item.dat_opcode == dat_opcode_t'(VIP_CHI_DAT_NCB_WR_DATA_COMP_ACK_E))) {
      bins no  = {1'b0};
      bins yes = {1'b1};
    }

    cp_epoch: coverpoint this.post_reset_epoch_sample {
      bins pre_reset_epoch  = {1'b0};
      bins post_reset_epoch = {1'b1};
    }

    cx_opcode_beats: cross cp_opcode, cp_beats;
    cx_opcode_data_ids: cross cp_opcode, cp_data_ids_contiguous;
    cx_opcode_resp_err: cross cp_opcode, cp_resp_err;
    cx_opcode_write_txn_dbid: cross cp_opcode, cp_write_txn_matches_dbid;
    cx_opcode_epoch: cross cp_opcode, cp_epoch;
  endgroup

  covergroup cg_write_flow;
    option.per_instance = 1;

    cp_first_rsp_opcode: coverpoint this.write_first_rsp_opcode_sample {
      bins comp           = {VIP_CHI_RSP_COMP_E};
      bins comp_dbid_resp = {VIP_CHI_RSP_COMP_DBID_RESP_E};
      bins dbid_resp      = {VIP_CHI_RSP_DBID_RESP_E};
    }

    cp_completion_rsp_opcode: coverpoint this.write_completion_rsp_opcode_sample {
      bins comp           = {VIP_CHI_RSP_COMP_E};
      bins comp_dbid_resp = {VIP_CHI_RSP_COMP_DBID_RESP_E};
    }

    cp_dat_opcode: coverpoint this.write_dat_opcode_sample {
      bins wr_data          = {VIP_CHI_DAT_NON_COPY_BACK_WR_DATA_E};
      bins wr_data_comp_ack = {VIP_CHI_DAT_NCB_WR_DATA_COMP_ACK_E};
    }

    cp_comp_ack_expected: coverpoint this.write_flow_comp_ack_expected_sample {
      bins no  = {1'b0};
      bins yes = {1'b1};
    }

    cp_comp_ack_seen: coverpoint this.write_flow_comp_ack_seen_sample {
      bins no  = {1'b0};
      bins yes = {1'b1};
    }

    cp_dbid_matches_req: coverpoint this.write_flow_dbid_matches_req_txn_sample {
      bins no  = {1'b0};
      bins yes = {1'b1};
    }

    cp_split: coverpoint this.write_flow_split_sample {
      bins no  = {1'b0};
      bins yes = {1'b1};
    }

    cp_epoch: coverpoint this.post_reset_epoch_sample {
      bins pre_reset_epoch  = {1'b0};
      bins post_reset_epoch = {1'b1};
    }

    cx_first_rsp_comp_ack: cross cp_first_rsp_opcode, cp_comp_ack_expected, cp_comp_ack_seen;
    cx_split_completion: cross cp_split, cp_completion_rsp_opcode;
    cx_dat_comp_ack: cross cp_dat_opcode, cp_comp_ack_expected;
    cx_split_epoch: cross cp_split, cp_epoch;
  endgroup

  covergroup cg_recovery;
    option.per_instance = 1;

    cp_channel: coverpoint this.recovery_channel_sample {
      bins req = {VIP_CHI_RECOVERY_REQ_E};
      bins rsp = {VIP_CHI_RECOVERY_RSP_E};
      bins dat = {VIP_CHI_RECOVERY_DAT_E};
    }

    cp_role: coverpoint this.recovery_role_sample {
      bins rni = {VIP_CHI_ROLE_RNI_E};
      bins snf = {VIP_CHI_ROLE_SNF_E};
    }

    cx_channel_role: cross cp_channel, cp_role;
  endgroup

  covergroup cg_addr_alignment;
    option.per_instance = 1;

    cp_dir: coverpoint this.req_item.direction {
      bins read  = {VIP_CHI_DIR_READ_E};
      bins write = {VIP_CHI_DIR_WRITE_E};
    }

    cp_transfer_aligned: coverpoint this.req_transfer_aligned_sample {
      bins no  = {1'b0};
      bins yes = {1'b1};
    }

    cp_cacheline_aligned: coverpoint this.req_cacheline_aligned_sample {
      bins no  = {1'b0};
      bins yes = {1'b1};
    }

    cx_dir_alignment: cross cp_dir, cp_transfer_aligned, cp_cacheline_aligned;
  endgroup

  covergroup cg_atomic;
    option.per_instance = 1;

    cp_role: coverpoint this.req_item.role {
      bins rni = {VIP_CHI_ROLE_RNI_E};
      bins snf = {VIP_CHI_ROLE_SNF_E};
    }

    cp_kind: coverpoint this.atomic_kind_sample {
      bins variant_0 = {0};
      bins variant_1 = {1};
      bins variant_2 = {2};
      bins variant_3 = {3};
      bins variant_4 = {4};
      bins variant_5 = {5};
      bins variant_6 = {6};
      bins variant_7 = {7};
      bins swap      = {8};
      bins compare   = {9};
    }

    cp_size: coverpoint this.atomic_size_sample {
      bins one_beat  = {[0:2]};
      bins few_beats = {[3:6]};
    }

    cp_returns_data: coverpoint this.atomic_returns_data_sample {
      bins no  = {1'b0};
      bins yes = {1'b1};
    }

    cx_kind_size: cross cp_kind, cp_size;
    cx_kind_returns_data: cross cp_kind, cp_returns_data;
  endgroup

  covergroup cg_qos;
    option.per_instance = 1;

    cp_channel: coverpoint this.qos_channel_sample {
      bins req = {VIP_CHI_QOS_REQ_E};
      bins rsp = {VIP_CHI_QOS_RSP_E};
      bins dat = {VIP_CHI_QOS_DAT_E};
    }

    cp_qos: coverpoint this.qos_sample {
      bins all_values[] = {[0:QOS_MAX_C]};
    }

    cp_role: coverpoint ((this.qos_channel_sample == VIP_CHI_QOS_REQ_E) ? this.req_item.role :
                         (this.qos_channel_sample == VIP_CHI_QOS_RSP_E) ? this.rsp_item.role :
                         this.dat_item.role) {
      bins rni = {VIP_CHI_ROLE_RNI_E};
      bins snf = {VIP_CHI_ROLE_SNF_E};
    }

    cx_channel_qos: cross cp_channel, cp_qos;
  endgroup

  covergroup cg_mte;
    option.per_instance = 1;

    cp_channel: coverpoint this.mte_channel_sample {
      bins req = {VIP_CHI_MTE_REQ_E};
      bins dat = {VIP_CHI_MTE_DAT_E};
    }

    cp_tagop: coverpoint this.mte_tagop_sample {
      bins zero = {0};
      bins nonzero[] = {[1:TAGOP_MAX_C]};
    }

    cp_has_tag: coverpoint this.mte_tag_nonzero_sample {
      bins no  = {1'b0};
      bins yes = {1'b1};
    }

    cp_has_tu: coverpoint this.mte_tu_nonzero_sample {
      bins no  = {1'b0};
      bins yes = {1'b1};
    }

    cx_channel_tagop: cross cp_channel, cp_tagop;
  endgroup

  covergroup cg_ordered_read;
    option.per_instance = 1;

    cp_order: coverpoint this.ordered_read_order_sample {
      bins accepted = {VIP_CHI_ORDER_REQ_ACCEPTED_E};
      bins ordered  = {VIP_CHI_ORDER_REQ_ORDER_E};
    }

    cp_dat_opcode: coverpoint this.ordered_read_dat_opcode_sample {
      bins comp_data = {VIP_CHI_DAT_COMP_DATA_E};
      bins sep_data  = {VIP_CHI_DAT_DATA_SEP_RESP_E};
    }

    cp_receipt_seen: coverpoint this.ordered_read_receipt_seen_sample {
      bins no  = {1'b0};
      bins yes = {1'b1};
    }

    cx_order_receipt: cross cp_order, cp_receipt_seen;
    cx_opcode_receipt: cross cp_dat_opcode, cp_receipt_seen;
  endgroup

  covergroup cg_outstanding;
    option.per_instance = 1;

    cp_reads: coverpoint this.outstanding_reads_sample {
      bins zero = {0};
      bins one  = {1};
      bins many = {[2:$]};
    }

    cp_writes: coverpoint this.outstanding_writes_sample {
      bins zero = {0};
      bins one  = {1};
      bins many = {[2:$]};
    }

    cx_reads_writes: cross cp_reads, cp_writes;
  endgroup

  // Coherent request opcodes issued by an RN-F (Tier C). Crossed with direction
  // to separate the read-family (ReadShared/Clean/Unique) from the ownership and
  // eviction flows (CleanUnique/MakeUnique/Evict/WriteBack/WriteCleanFull).
  covergroup cg_coherent_req;
    option.per_instance = 1;

    cp_opcode: coverpoint vip_chi_req_opcode_t'(this.coh_req_item.opcode) {
      bins read_shared      = {VIP_CHI_REQ_READ_SHARED_E};
      bins read_clean       = {VIP_CHI_REQ_READ_CLEAN_E};
      bins read_unique      = {VIP_CHI_REQ_READ_UNIQUE_E};
      bins clean_unique     = {VIP_CHI_REQ_CLEAN_UNIQUE_E};
      bins make_unique      = {VIP_CHI_REQ_MAKE_UNIQUE_E};
      bins make_read_unique = {VIP_CHI_REQ_MAKE_READ_UNIQUE_E};
      bins clean_invalid    = {VIP_CHI_REQ_CLEAN_INVALID_E};
      bins make_invalid     = {VIP_CHI_REQ_MAKE_INVALID_E};
      bins read_once        = {VIP_CHI_REQ_READ_ONCE_E};
      bins write_unique_full = {VIP_CHI_REQ_WRITE_UNIQUE_FULL_E};
      bins write_unique_ptl  = {VIP_CHI_REQ_WRITE_UNIQUE_PTL_E};
      bins evict            = {VIP_CHI_REQ_EVICT_E};
      bins write_back_full  = {VIP_CHI_REQ_WRITE_BACK_FULL_E};
      bins write_clean_full = {VIP_CHI_REQ_WRITE_CLEAN_FULL_E};
    }

    cp_dir: coverpoint this.coh_req_item.direction {
      bins read  = {VIP_CHI_DIR_READ_E};
      bins write = {VIP_CHI_DIR_WRITE_E};
    }

    cx_opcode_dir: cross cp_opcode, cp_dir;
  endgroup

  // Snoop opcodes seen inbound on an RN-F (originated by the HN-F directory).
  covergroup cg_snp_opcode;
    option.per_instance = 1;

    cp_snp_opcode: coverpoint this.snp_opcode_sample {
      bins snp_shared        = {VIP_CHI_SNP_SHARED_C};
      bins snp_clean         = {VIP_CHI_SNP_CLEAN_C};
      bins snp_clean_shared  = {VIP_CHI_SNP_CLEAN_SHARED_C};
      bins snp_unique        = {VIP_CHI_SNP_UNIQUE_C};
      bins snp_clean_invalid = {VIP_CHI_SNP_CLEAN_INVALID_C};
      bins snp_make_invalid  = {VIP_CHI_SNP_MAKE_INVALID_C};
      bins snp_query         = {VIP_CHI_SNP_QUERY_C};
      // Forwarding (DCT) snoops.
      bins snp_shared_fwd           = {VIP_CHI_SNP_SHARED_FWD_C};
      bins snp_clean_fwd            = {VIP_CHI_SNP_CLEAN_FWD_C};
      bins snp_once_fwd             = {VIP_CHI_SNP_ONCE_FWD_C};
      bins snp_not_shared_dirty_fwd = {VIP_CHI_SNP_NOT_SHARED_DIRTY_FWD_C};
      bins snp_unique_fwd           = {VIP_CHI_SNP_UNIQUE_FWD_C};
    }
  endgroup

  // Snoop-response resulting state crossed with pass-dirty: a clean response
  // (SnpResp on RSP, pass_dirty=0) versus a dirty forward (SnpRespData on DAT,
  // pass_dirty=1) that carries modified beats back to the home.
  covergroup cg_snp_resp;
    option.per_instance = 1;

    cp_resp_state: coverpoint this.snp_resp_state_sample {
      bins inv = {VIP_CHI_RESP_STATE_I_E};
      bins sc  = {VIP_CHI_RESP_STATE_SC_E};
      bins uc  = {VIP_CHI_RESP_STATE_UC_E};
      bins ud  = {VIP_CHI_RESP_STATE_UP_PD_DIRTY_E};
      bins sd  = {VIP_CHI_RESP_STATE_SD_PD_DIRTY_E};
    }

    cp_pass_dirty: coverpoint this.snp_resp_pass_dirty_sample {
      bins clean = {1'b0};
      bins dirty = {1'b1};
    }

    cx_state_pass_dirty: cross cp_resp_state, cp_pass_dirty;
  endgroup

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent);
    super.new(name, parent);
    this.cg_req = new();
    this.cg_rsp = new();
    this.cg_dat = new();
    this.cg_write_flow = new();
    this.cg_recovery = new();
    this.cg_addr_alignment = new();
    this.cg_atomic = new();
    this.cg_qos = new();
    this.cg_mte = new();
    this.cg_ordered_read = new();
    this.cg_outstanding = new();
    this.cg_coherent_req = new();
    this.cg_snp_opcode = new();
    this.cg_snp_resp = new();
  endfunction

  protected function int unsigned role_to_index(input vip_chi_role_t role);
    return (role == VIP_CHI_ROLE_SNF_E) ? 1 : 0;
  endfunction

  protected function int unsigned txn_to_index(input txn_id_t txn_id);
    return txn_id;
  endfunction

  protected function bit is_write_dat_opcode(input dat_opcode_t opcode);
    return ((opcode == dat_opcode_t'(VIP_CHI_DAT_NON_COPY_BACK_WR_DATA_E)) ||
            (opcode == dat_opcode_t'(VIP_CHI_DAT_NCB_WR_DATA_COMP_ACK_E)));
  endfunction

  protected function int atomic_kind_bucket(input req_opcode_t opcode);
    if (opcode == req_opcode_t'(VIP_CHI_REQ_ATOMIC_SWAP_C)) begin
      return 8;
    end
    if (opcode == req_opcode_t'(VIP_CHI_REQ_ATOMIC_COMPARE_C)) begin
      return 9;
    end
    return vip_chi_types_pkg::vip_chi_req_opcode_atomic_variant(
      vip_chi_req_opcode_t'(opcode));
  endfunction

  protected function bit item_has_nonzero_tag(input item_t item);
    foreach (item.tag[i]) begin
      if (item.tag[i] != '0) begin
        return 1'b1;
      end
    end
    return 1'b0;
  endfunction

  protected function bit item_has_nonzero_tu(input item_t item);
    foreach (item.tu[i]) begin
      if (item.tu[i] != '0) begin
        return 1'b1;
      end
    end
    return 1'b0;
  endfunction

  protected function void sample_qos_value(
    input qos_channel_e channel,
    input vip_chi_qos_t qos
  );
    if (!this.enabled) begin
      return;
    end

    this.qos_channel_sample = channel;
    this.qos_sample = qos;
    this.cg_qos.sample();
  endfunction

  protected function void sample_mte_req(input item_t item);
    if (!this.enabled || (item.tagop == '0)) begin
      return;
    end

    this.mte_channel_sample = VIP_CHI_MTE_REQ_E;
    this.mte_tagop_sample = item.tagop;
    this.mte_tag_nonzero_sample = 1'b0;
    this.mte_tu_nonzero_sample = 1'b0;
    this.cg_mte.sample();
  endfunction

  protected function void sample_mte_dat(input item_t item);
    if (!this.enabled) begin
      return;
    end

    if ((item.dat_tagop == '0) && !this.item_has_nonzero_tag(item) &&
        !this.item_has_nonzero_tu(item)) begin
      return;
    end

    this.mte_channel_sample = VIP_CHI_MTE_DAT_E;
    this.mte_tagop_sample = item.dat_tagop;
    this.mte_tag_nonzero_sample = this.item_has_nonzero_tag(item);
    this.mte_tu_nonzero_sample = this.item_has_nonzero_tu(item);
    this.cg_mte.sample();
  endfunction

  protected function void sample_outstanding_counts();
    int unsigned txn_idx;

    if (!this.enabled) begin
      return;
    end

    this.outstanding_reads_sample = 0;
    this.outstanding_writes_sample = 0;
    for (txn_idx = 0; txn_idx < TXN_ID_COUNT_C; txn_idx++) begin
      if (this.write_req_seen_by_txn[txn_idx] && !this.write_completion_seen_by_txn[txn_idx]) begin
        this.outstanding_writes_sample++;
      end
      if (this.ordered_read_completion_valid_by_req[txn_idx]) begin
        this.outstanding_reads_sample++;
      end
    end

    this.cg_outstanding.sample();
  endfunction

  protected function bit are_data_ids_contiguous(input item_t item);
    if (item.data_id.size() < 2) begin
      return 1'b1;
    end

    foreach (item.data_id[i]) begin
      if ((i > 0) &&
          (item.data_id[i] != data_id_t'(item.data_id[i - 1] + data_id_t'(1)))) begin
        return 1'b0;
      end
    end

    return 1'b1;
  endfunction

  protected function void maybe_sample_recovery(
    input recovery_channel_e channel,
    input vip_chi_role_t     role
  );
    int unsigned role_idx;

    if (this.reset_epoch == 0) begin
      return;
    end

    role_idx = this.role_to_index(role);

    case (channel)
      VIP_CHI_RECOVERY_REQ_E: begin
        if (this.post_reset_req_recovered_by_role[role_idx]) begin
          return;
        end
        this.post_reset_req_recovered_by_role[role_idx] = 1'b1;
      end

      VIP_CHI_RECOVERY_RSP_E: begin
        if (this.post_reset_rsp_recovered_by_role[role_idx]) begin
          return;
        end
        this.post_reset_rsp_recovered_by_role[role_idx] = 1'b1;
      end

      VIP_CHI_RECOVERY_DAT_E: begin
        if (this.post_reset_dat_recovered_by_role[role_idx]) begin
          return;
        end
        this.post_reset_dat_recovered_by_role[role_idx] = 1'b1;
      end
    endcase

    this.recovery_channel_sample = channel;
    this.recovery_role_sample = role;
    this.post_reset_epoch_sample = 1'b1;
    this.cg_recovery.sample();
  endfunction

  protected function void maybe_sample_write_flow(input int unsigned txn_idx);
    if (!this.write_req_seen_by_txn[txn_idx] ||
        this.write_flow_sampled_by_txn[txn_idx] ||
        !this.write_dat_seen_by_txn[txn_idx] ||
        !this.write_completion_seen_by_txn[txn_idx]) begin
      return;
    end

    if (this.write_exp_comp_ack_by_txn[txn_idx] &&
        !this.write_comp_ack_seen_by_txn[txn_idx]) begin
      return;
    end

    this.write_first_rsp_opcode_sample = this.write_first_rsp_opcode_by_txn[txn_idx];
    this.write_completion_rsp_opcode_sample = this.write_completion_rsp_opcode_by_txn[txn_idx];
    this.write_dat_opcode_sample = this.write_dat_opcode_by_txn[txn_idx];
    this.write_flow_comp_ack_expected_sample = this.write_exp_comp_ack_by_txn[txn_idx];
    this.write_flow_comp_ack_seen_sample = this.write_comp_ack_seen_by_txn[txn_idx];
    this.write_flow_dbid_matches_req_txn_sample = this.write_dbid_matches_req_by_txn[txn_idx];
    this.write_flow_split_sample =
      (this.write_first_rsp_opcode_by_txn[txn_idx] == rsp_opcode_t'(VIP_CHI_RSP_DBID_RESP_E));
    this.post_reset_epoch_sample = (this.reset_epoch != 0);
    this.cg_write_flow.sample();
    this.write_flow_sampled_by_txn[txn_idx] = 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Allocate the analysis imps used by the shared env.
  // ---------------------------------------------------------------------------
  function void build_phase(input uvm_phase phase);
    super.build_phase(phase);

    this.rni_req_cov_port = new("rni_req_cov_port", this);
    this.rni_rsp_cov_port = new("rni_rsp_cov_port", this);
    this.rni_dat_cov_port = new("rni_dat_cov_port", this);
    this.snf_req_cov_port = new("snf_req_cov_port", this);
    this.snf_rsp_cov_port = new("snf_rsp_cov_port", this);
    this.snf_dat_cov_port = new("snf_dat_cov_port", this);
    this.rnf_req_cov_port = new("rnf_req_cov_port", this);
    this.rnf_rsp_cov_port = new("rnf_rsp_cov_port", this);
    this.rnf_dat_cov_port = new("rnf_dat_cov_port", this);
    this.snp_cov_port     = new("snp_cov_port", this);
  endfunction

  // ---------------------------------------------------------------------------
  // Reset any sampled scratch state between reset epochs.
  // ---------------------------------------------------------------------------
  function void handle_reset();
    int unsigned txn_idx;
    int unsigned role_idx;

    this.reset_epoch++;
    this.req_item          = null;
    this.rsp_item          = null;
    this.dat_item          = null;
    this.dat_beats_sample  = 0;
    this.post_reset_epoch_sample = 1'b1;
    this.dat_resp_err_sample = VIP_CHI_RESP_ERR_NORMAL_OKAY_E;
    this.dat_first_data_id_zero_sample = 1'b1;
    this.dat_data_ids_contiguous_sample = 1'b1;
    this.dat_write_txn_matches_dbid_sample = 1'b1;
    this.write_first_rsp_opcode_sample = rsp_opcode_t'(VIP_CHI_RSP_COMP_E);
    this.write_completion_rsp_opcode_sample = rsp_opcode_t'(VIP_CHI_RSP_COMP_E);
    this.write_dat_opcode_sample = dat_opcode_t'(VIP_CHI_DAT_NON_COPY_BACK_WR_DATA_E);
    this.write_flow_comp_ack_expected_sample = 1'b0;
    this.write_flow_comp_ack_seen_sample = 1'b0;
    this.write_flow_dbid_matches_req_txn_sample = 1'b1;
    this.write_flow_split_sample = 1'b0;
    this.req_transfer_aligned_sample = 1'b1;
    this.req_cacheline_aligned_sample = 1'b1;
    this.atomic_kind_sample = 0;
    this.atomic_size_sample = size_t'('0);
    this.atomic_returns_data_sample = 1'b0;
    this.qos_sample = '0;
    this.mte_tagop_sample = '0;
    this.mte_tag_nonzero_sample = 1'b0;
    this.mte_tu_nonzero_sample = 1'b0;
    this.ordered_read_order_sample = VIP_CHI_ORDER_REQ_ACCEPTED_E;
    this.ordered_read_dat_opcode_sample = dat_opcode_t'(VIP_CHI_DAT_COMP_DATA_E);
    this.ordered_read_receipt_seen_sample = 1'b0;
    this.coh_req_item = null;
    this.snp_opcode_sample = snp_opcode_t'(VIP_CHI_SNP_SHARED_C);
    this.snp_resp_state_sample = VIP_CHI_RESP_STATE_I_E;
    this.snp_resp_pass_dirty_sample = 1'b0;

    for (txn_idx = 0; txn_idx < TXN_ID_COUNT_C; txn_idx++) begin
      this.write_req_seen_by_txn[txn_idx] = 1'b0;
      this.write_first_rsp_seen_by_txn[txn_idx] = 1'b0;
      this.write_completion_seen_by_txn[txn_idx] = 1'b0;
      this.write_dat_seen_by_txn[txn_idx] = 1'b0;
      this.write_comp_ack_seen_by_txn[txn_idx] = 1'b0;
      this.write_flow_sampled_by_txn[txn_idx] = 1'b0;
      this.write_exp_comp_ack_by_txn[txn_idx] = 1'b0;
      this.write_dbid_matches_req_by_txn[txn_idx] = 1'b0;
      this.granted_req_txn_valid_by_dbid[txn_idx] = 1'b0;
      this.granted_req_txn_by_dbid[txn_idx] = '0;
      this.write_first_rsp_opcode_by_txn[txn_idx] = rsp_opcode_t'(VIP_CHI_RSP_COMP_E);
      this.write_completion_rsp_opcode_by_txn[txn_idx] = rsp_opcode_t'(VIP_CHI_RSP_COMP_E);
      this.write_dat_opcode_by_txn[txn_idx] = dat_opcode_t'(VIP_CHI_DAT_NON_COPY_BACK_WR_DATA_E);
      this.ordered_read_req_seen_by_completion_txn[txn_idx] = 1'b0;
      this.ordered_read_receipt_seen_by_completion_txn[txn_idx] = 1'b0;
      this.ordered_read_completion_valid_by_req[txn_idx] = 1'b0;
      this.ordered_read_completion_txn_by_req[txn_idx] = '0;
    end

    for (role_idx = 0; role_idx < 2; role_idx++) begin
      this.post_reset_req_recovered_by_role[role_idx] = 1'b0;
      this.post_reset_rsp_recovered_by_role[role_idx] = 1'b0;
      this.post_reset_dat_recovered_by_role[role_idx] = 1'b0;
    end
  endfunction

  protected function void sample_req(input item_t item);
    int unsigned txn_idx;

    if (!this.enabled) begin
      return;
    end

    this.req_item = item;
    this.post_reset_epoch_sample = (this.reset_epoch != 0);
    this.cg_req.sample();
    this.sample_qos_value(VIP_CHI_QOS_REQ_E, item.qos);
    this.maybe_sample_recovery(VIP_CHI_RECOVERY_REQ_E, item.role);

    this.req_transfer_aligned_sample =
      ((vip_chi_types_pkg::chi_size_bytes(size_t'(item.size)) == 0) ? 1'b1 :
       ((item.addr % vip_chi_types_pkg::chi_size_bytes(size_t'(item.size))) == 0));
    this.req_cacheline_aligned_sample =
      ((item.addr % VIP_CHI_CACHE_LINE_BYTES_C) == 0);
    this.cg_addr_alignment.sample();

    if (vip_chi_types_pkg::vip_chi_req_opcode_is_atomic(
          vip_chi_req_opcode_t'(item.opcode))) begin
      this.atomic_kind_sample = this.atomic_kind_bucket(item.opcode);
      this.atomic_size_sample = size_t'(item.size);
      this.atomic_returns_data_sample =
        vip_chi_types_pkg::vip_chi_req_opcode_is_atomic_returning_data(
          vip_chi_req_opcode_t'(item.opcode));
      this.cg_atomic.sample();
    end

    this.sample_mte_req(item);

    if ((item.role == VIP_CHI_ROLE_RNI_E) &&
        (item.direction == VIP_CHI_DIR_READ_E) &&
        (item.order != VIP_CHI_ORDER_NONE_E) &&
        ((item.opcode == req_opcode_t'(VIP_CHI_REQ_READ_NO_SNP_C)) ||
         (item.opcode == req_opcode_t'(VIP_CHI_REQ_READ_NO_SNP_SEP_C)))) begin
      txn_idx = this.txn_to_index(item.txn_id);
      this.ordered_read_completion_valid_by_req[txn_idx] = 1'b1;
      this.ordered_read_completion_txn_by_req[txn_idx] =
        (item.opcode == req_opcode_t'(VIP_CHI_REQ_READ_NO_SNP_SEP_C)) ?
          item.return_txn_id : item.txn_id;
      this.ordered_read_req_seen_by_completion_txn[
        this.txn_to_index(this.ordered_read_completion_txn_by_req[txn_idx])] = 1'b1;
      this.ordered_read_receipt_seen_by_completion_txn[
        this.txn_to_index(this.ordered_read_completion_txn_by_req[txn_idx])] = 1'b0;
    end

    if ((item.role == VIP_CHI_ROLE_RNI_E) && (item.direction == VIP_CHI_DIR_WRITE_E)) begin
      txn_idx = this.txn_to_index(item.txn_id);
      this.write_req_seen_by_txn[txn_idx] = 1'b1;
      this.write_first_rsp_seen_by_txn[txn_idx] = 1'b0;
      this.write_completion_seen_by_txn[txn_idx] = 1'b0;
      this.write_dat_seen_by_txn[txn_idx] = 1'b0;
      this.write_comp_ack_seen_by_txn[txn_idx] = 1'b0;
      this.write_flow_sampled_by_txn[txn_idx] = 1'b0;
      this.write_exp_comp_ack_by_txn[txn_idx] = item.exp_comp_ack;
      this.write_dbid_matches_req_by_txn[txn_idx] = 1'b0;
      this.write_first_rsp_opcode_by_txn[txn_idx] = rsp_opcode_t'(VIP_CHI_RSP_COMP_E);
      this.write_completion_rsp_opcode_by_txn[txn_idx] = rsp_opcode_t'(VIP_CHI_RSP_COMP_E);
      this.write_dat_opcode_by_txn[txn_idx] = dat_opcode_t'(VIP_CHI_DAT_NON_COPY_BACK_WR_DATA_E);
    end

    this.sample_outstanding_counts();
  endfunction

  protected function void sample_rsp(input item_t item);
    int unsigned txn_idx;
    int unsigned dbid_idx;

    if (!this.enabled) begin
      return;
    end

    this.rsp_item = item;
    this.post_reset_epoch_sample = (this.reset_epoch != 0);
    this.cg_rsp.sample();
    this.sample_qos_value(VIP_CHI_QOS_RSP_E, item.qos);
    this.maybe_sample_recovery(VIP_CHI_RECOVERY_RSP_E, item.role);

    if ((item.role == VIP_CHI_ROLE_SNF_E) &&
        (item.rsp_opcode == rsp_opcode_t'(VIP_CHI_RSP_READ_RECEIPT_E))) begin
      txn_idx = this.txn_to_index(item.txn_id);
      if (this.ordered_read_completion_valid_by_req[txn_idx]) begin
        this.ordered_read_receipt_seen_by_completion_txn[
          this.txn_to_index(this.ordered_read_completion_txn_by_req[txn_idx])] = 1'b1;
      end
    end

    if ((item.role == VIP_CHI_ROLE_SNF_E) &&
        this.write_req_seen_by_txn[this.txn_to_index(item.txn_id)]) begin
      txn_idx = this.txn_to_index(item.txn_id);

      if (!this.write_first_rsp_seen_by_txn[txn_idx]) begin
        this.write_first_rsp_seen_by_txn[txn_idx] = 1'b1;
        this.write_first_rsp_opcode_by_txn[txn_idx] = item.rsp_opcode;
        if ((item.rsp_opcode == rsp_opcode_t'(VIP_CHI_RSP_DBID_RESP_E)) ||
            (item.rsp_opcode == rsp_opcode_t'(VIP_CHI_RSP_COMP_DBID_RESP_E))) begin
          this.write_dbid_matches_req_by_txn[txn_idx] = (item.dbid == item.txn_id);
        end
        else begin
          this.write_dbid_matches_req_by_txn[txn_idx] = 1'b1;
        end
      end

      if ((item.rsp_opcode == rsp_opcode_t'(VIP_CHI_RSP_DBID_RESP_E)) ||
          (item.rsp_opcode == rsp_opcode_t'(VIP_CHI_RSP_COMP_DBID_RESP_E))) begin
        dbid_idx = this.txn_to_index(item.dbid);
        this.granted_req_txn_valid_by_dbid[dbid_idx] = 1'b1;
        this.granted_req_txn_by_dbid[dbid_idx] = item.txn_id;
      end

      if ((item.rsp_opcode == rsp_opcode_t'(VIP_CHI_RSP_COMP_E)) ||
          (item.rsp_opcode == rsp_opcode_t'(VIP_CHI_RSP_COMP_DBID_RESP_E))) begin
        this.write_completion_seen_by_txn[txn_idx] = 1'b1;
        this.write_completion_rsp_opcode_by_txn[txn_idx] = item.rsp_opcode;
      end

      this.maybe_sample_write_flow(txn_idx);
    end
    else if ((item.role == VIP_CHI_ROLE_RNI_E) &&
             (item.rsp_opcode == rsp_opcode_t'(VIP_CHI_RSP_COMP_ACK_E)) &&
             this.write_req_seen_by_txn[this.txn_to_index(item.txn_id)]) begin
      txn_idx = this.txn_to_index(item.txn_id);
      this.write_comp_ack_seen_by_txn[txn_idx] = 1'b1;
      this.maybe_sample_write_flow(txn_idx);
    end

    this.sample_outstanding_counts();
  endfunction

  protected function void sample_dat(input item_t item);
    int unsigned txn_idx;
    int unsigned dbid_idx;

    if (!this.enabled) begin
      return;
    end

    this.dat_item = item;
    this.post_reset_epoch_sample = (this.reset_epoch != 0);
    this.dat_beats_sample = item.data.size();
    this.dat_first_data_id_zero_sample =
      ((item.data_id.size() == 0) || (item.data_id[0] == data_id_t'('0)));
    this.dat_data_ids_contiguous_sample = this.are_data_ids_contiguous(item);
    this.dat_write_txn_matches_dbid_sample =
      !this.is_write_dat_opcode(item.dat_opcode) || (item.txn_id == item.dbid);

    if (item.dat_resp_err.size() > 0) begin
      this.dat_resp_err_sample = item.dat_resp_err[0];
    end
    else begin
      this.dat_resp_err_sample = item.rsp_resp_err;
    end

    this.cg_dat.sample();
    this.sample_qos_value(VIP_CHI_QOS_DAT_E, item.qos);
    this.sample_mte_dat(item);
    this.maybe_sample_recovery(VIP_CHI_RECOVERY_DAT_E, item.role);

    if ((item.role == VIP_CHI_ROLE_SNF_E) &&
        ((item.dat_opcode == dat_opcode_t'(VIP_CHI_DAT_COMP_DATA_E)) ||
         (item.dat_opcode == dat_opcode_t'(VIP_CHI_DAT_DATA_SEP_RESP_E)))) begin
      txn_idx = this.txn_to_index(item.txn_id);
      if (this.ordered_read_req_seen_by_completion_txn[txn_idx]) begin
        this.ordered_read_dat_opcode_sample = item.dat_opcode;
        this.ordered_read_receipt_seen_sample =
          this.ordered_read_receipt_seen_by_completion_txn[txn_idx];
        this.ordered_read_order_sample = this.ordered_read_receipt_seen_sample ?
          VIP_CHI_ORDER_REQ_ORDER_E : VIP_CHI_ORDER_REQ_ACCEPTED_E;
        this.cg_ordered_read.sample();
        this.ordered_read_req_seen_by_completion_txn[txn_idx] = 1'b0;
        this.ordered_read_receipt_seen_by_completion_txn[txn_idx] = 1'b0;
      end
    end

    if ((item.role == VIP_CHI_ROLE_RNI_E) && this.is_write_dat_opcode(item.dat_opcode)) begin
      dbid_idx = this.txn_to_index(item.dbid);

      if (this.granted_req_txn_valid_by_dbid[dbid_idx]) begin
        txn_idx = this.txn_to_index(this.granted_req_txn_by_dbid[dbid_idx]);
      end
      else begin
        txn_idx = this.txn_to_index(item.txn_id);
      end

      if (this.write_req_seen_by_txn[txn_idx]) begin
        this.write_dat_seen_by_txn[txn_idx] = 1'b1;
        this.write_dat_opcode_by_txn[txn_idx] = item.dat_opcode;
        this.maybe_sample_write_flow(txn_idx);
      end
    end

    this.sample_outstanding_counts();
  endfunction

  function void write_rni_req_cov_port(input item_t item);
    this.sample_req(item);
  endfunction

  function void write_rni_rsp_cov_port(input item_t item);
    this.sample_rsp(item);
  endfunction

  function void write_rni_dat_cov_port(input item_t item);
    this.sample_dat(item);
  endfunction

  function void write_snf_req_cov_port(input item_t item);
    this.sample_req(item);
  endfunction

  function void write_snf_rsp_cov_port(input item_t item);
    this.sample_rsp(item);
  endfunction

  function void write_snf_dat_cov_port(input item_t item);
    this.sample_dat(item);
  endfunction

  // ---------------------------------------------------------------------------
  // Coherent (Tier C) sampling.
  // ---------------------------------------------------------------------------
  protected function void sample_coherent_req(input item_t item);
    if (!this.enabled) begin
      return;
    end
    this.coh_req_item = item;
    this.cg_coherent_req.sample();
  endfunction

  protected function void sample_snp(input item_t item);
    if (!this.enabled) begin
      return;
    end
    this.snp_opcode_sample = item.snp_opcode;
    this.cg_snp_opcode.sample();
  endfunction

  protected function void sample_snp_resp_clean(input item_t item);
    if (!this.enabled) begin
      return;
    end
    this.snp_resp_state_sample = item.rsp_resp;
    this.snp_resp_pass_dirty_sample = 1'b0;
    this.cg_snp_resp.sample();
  endfunction

  protected function void sample_snp_resp_dirty(input item_t item);
    if (!this.enabled) begin
      return;
    end
    this.snp_resp_state_sample = (item.dat_resp.size() > 0) ?
      item.dat_resp[item.dat_resp.size() - 1] : VIP_CHI_RESP_STATE_I_E;
    this.snp_resp_pass_dirty_sample = 1'b1;
    this.cg_snp_resp.sample();
  endfunction

  // RN-F coherent request stream: sample only requests this RN-F sourced.
  function void write_rnf_req_cov_port(input item_t item);
    if (item.role == VIP_CHI_ROLE_RNF_E) begin
      this.sample_coherent_req(item);
    end
  endfunction

  // RN-F RSP stream: a clean snoop response (SnpResp) driven by this RN-F.
  function void write_rnf_rsp_cov_port(input item_t item);
    if ((item.role == VIP_CHI_ROLE_RNF_E) &&
        (item.rsp_opcode == rsp_opcode_t'(VIP_CHI_RSP_SNP_RESP_E))) begin
      this.sample_snp_resp_clean(item);
    end
  endfunction

  // RN-F DAT stream: a snoop response carrying data driven by this RN-F -- either
  // a plain dirty forward (SnpRespData) or a direct-cache-transfer forward
  // (SnpRespDataFwded). Both sample cg_snp_resp with pass_dirty=1.
  function void write_rnf_dat_cov_port(input item_t item);
    if ((item.role == VIP_CHI_ROLE_RNF_E) &&
        ((item.dat_opcode == dat_opcode_t'(VIP_CHI_DAT_SNP_RESP_DATA_E)) ||
         (item.dat_opcode == dat_opcode_t'(VIP_CHI_DAT_SNP_RESP_DATA_FWDED_E)))) begin
      this.sample_snp_resp_dirty(item);
    end
  endfunction

  // SNP channel: every inbound snoop flit.
  function void write_snp_cov_port(input item_t item);
    if (item.is_snoop) begin
      this.sample_snp(item);
    end
  endfunction

endclass