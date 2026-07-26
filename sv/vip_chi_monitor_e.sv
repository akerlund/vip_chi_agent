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

`ifndef VIP_CHI_MONITOR_E
`define VIP_CHI_MONITOR_E

import uvm_pkg::*;
`include "uvm_macros.svh"
import vip_chi_types_pkg::*;

class vip_chi_monitor_e #(
  vip_chi_cfg_t  CFG_P        = VIP_CHI_DEFAULT_CFG_C,
  type           FLIT_TYPES_T = vip_chi_types_e #(CFG_P),
  vip_chi_role_t ROLE_P       = VIP_CHI_ROLE_MONITOR_E
  ) extends vip_chi_monitor #(CFG_P, FLIT_TYPES_T, ROLE_P);

  typedef vip_chi_item  #(CFG_P)               item_t;
  typedef vip_chi_types #(CFG_P)::tagop_t      tagop_t;
  typedef vip_chi_types #(CFG_P)::groupidext_t groupidext_t;
  typedef vip_chi_types #(CFG_P)::tag_t        tag_t;
  typedef vip_chi_types #(CFG_P)::tu_t         tu_t;
  typedef FLIT_TYPES_T::vip_chi_req_flit_t     req_flit_t;
  typedef FLIT_TYPES_T::vip_chi_dat_flit_t     dat_flit_t;

  `uvm_component_param_utils(vip_chi_monitor_e #(CFG_P, FLIT_TYPES_T, ROLE_P))

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent);
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  // Capture the exact CHI-E REQ-only fields absent from the exact CHI-D shape.
  // ---------------------------------------------------------------------------
  virtual protected function void capture_req_issue_specific_fields(
    input req_flit_t flit,
    inout item_t     item
  );
    item.group_id_ext = groupidext_t'(flit.groupidext);
    item.tagop        = tagop_t'(flit.tagop);
  endfunction

  // ---------------------------------------------------------------------------
  // Capture the exact CHI-E DAT-only tagging fields absent from the exact
  // CHI-D shape.
  // ---------------------------------------------------------------------------
  virtual protected function void capture_dat_issue_specific_fields(
    input dat_flit_t flit,
    inout item_t     item,
    input int        beat_index
  );
    item.dat_tagop       = tagop_t'(flit.tagop);
    item.tag[beat_index] = tag_t'(flit.tag);
    item.tu[beat_index]  = tu_t'(flit.tu);
  endfunction

endclass

`endif