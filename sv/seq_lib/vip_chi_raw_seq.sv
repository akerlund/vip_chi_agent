`ifndef VIP_CHI_RAW_SEQ
`define VIP_CHI_RAW_SEQ

import uvm_pkg::*;
`include "uvm_macros.svh"
import vip_chi_types_pkg::*;

class vip_chi_raw_seq #(
  vip_chi_cfg_t CFG_P = VIP_CHI_DEFAULT_CFG_C
  ) extends vip_chi_pipelined_seq #(CFG_P);

  `uvm_object_param_utils(vip_chi_raw_seq #(CFG_P))

  typedef vip_chi_item #(CFG_P) item_t;
  typedef item_t::raw_req_t     raw_req_t;
  typedef item_t::raw_rsp_t     raw_rsp_t;
  typedef item_t::raw_dat_t     raw_dat_t;

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name = "vip_chi_raw_seq");
    super.new(name);
  endfunction

  // ---------------------------------------------------------------------------
  // Append one raw REQ-flit item.
  // ---------------------------------------------------------------------------
  function void add_raw_req(input raw_req_t flit, input logic flitpend = 1'b0);
    item_t item;

    item = item_t::type_id::create($sformatf("raw_req_item_%0d", this.items.size()));
    item.set_raw_req(flit, flitpend);
    this.add_item(item);
  endfunction

  // ---------------------------------------------------------------------------
  // Append one raw RSP-flit item.
  // ---------------------------------------------------------------------------
  function void add_raw_rsp(input raw_rsp_t flit, input logic flitpend = 1'b0);
    item_t item;

    item = item_t::type_id::create($sformatf("raw_rsp_item_%0d", this.items.size()));
    item.set_raw_rsp(flit, flitpend);
    this.add_item(item);
  endfunction

  // ---------------------------------------------------------------------------
  // Append one raw DAT-flit item.
  // ---------------------------------------------------------------------------
  function void add_raw_dat(input raw_dat_t flit, input logic flitpend = 1'b0);
    item_t item;

    item = item_t::type_id::create($sformatf("raw_dat_item_%0d", this.items.size()));
    item.set_raw_dat(flit, flitpend);
    this.add_item(item);
  endfunction

endclass

`endif