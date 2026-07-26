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