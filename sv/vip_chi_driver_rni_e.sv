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

`ifndef VIP_CHI_DRIVER_RNI_E
`define VIP_CHI_DRIVER_RNI_E

import uvm_pkg::*;
`include "uvm_macros.svh"
import vip_chi_types_pkg::*;

class vip_chi_driver_rni_e #(
  vip_chi_cfg_t  CFG_P        = VIP_CHI_DEFAULT_CFG_C,
  type           FLIT_TYPES_T = vip_chi_types_e #(CFG_P)
  ) extends vip_chi_driver_rni #(CFG_P, FLIT_TYPES_T);

  typedef vip_chi_item #(CFG_P)            item_t;
  typedef item_t::raw_req_t                raw_req_t;
  typedef item_t::raw_rsp_t                raw_rsp_t;
  typedef item_t::raw_dat_t                raw_dat_t;
  typedef vip_chi_types #(CFG_P)::tag_t    tag_t;
  typedef vip_chi_types #(CFG_P)::tu_t     tu_t;
  typedef FLIT_TYPES_T::vip_chi_req_flit_t req_flit_t;
  typedef FLIT_TYPES_T::vip_chi_dat_flit_t dat_flit_t;
  typedef FLIT_TYPES_T::vip_chi_rsp_flit_t rsp_flit_t;

  `uvm_component_param_utils(vip_chi_driver_rni_e #(CFG_P, FLIT_TYPES_T))

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent);
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  // Apply the exact CHI-E REQ-only fields absent from the exact CHI-D shape.
  // ---------------------------------------------------------------------------
  virtual protected function void apply_req_issue_specific_fields(
    ref   req_flit_t flit,
    input item_t     req
  );
    flit.groupidext = req.group_id_ext;
    flit.tagop      = req.tagop;
  endfunction

  // ---------------------------------------------------------------------------
  // Apply the exact CHI-E REQ-only raw fields absent from the exact CHI-D
  // shape.
  // ---------------------------------------------------------------------------
  virtual protected function void apply_raw_req_issue_specific_fields(
    ref   req_flit_t flit,
    input raw_req_t  raw
  );
    flit.groupidext = raw.groupidext;
    flit.tagop      = raw.tagop;
  endfunction

  // ---------------------------------------------------------------------------
  // Apply the exact CHI-E raw-RSP TagOp field absent from the exact CHI-D
  // shape.
  // ---------------------------------------------------------------------------
  virtual protected function void apply_raw_rsp_issue_specific_fields(
    ref   rsp_flit_t flit,
    input raw_rsp_t  raw
  );
    flit.tagop = raw.tagop;
  endfunction

  // ---------------------------------------------------------------------------
  // Apply the exact CHI-E DAT-only tagging fields absent from the exact CHI-D
  // shape.
  // ---------------------------------------------------------------------------
  virtual protected function void apply_dat_issue_specific_fields(
    ref   dat_flit_t   flit,
    input item_t       req,
    input int unsigned beat_index
  );
    flit.tagop = req.dat_tagop;
    flit.tag   = (beat_index < req.tag.size()) ? req.tag[beat_index] : tag_t'('0);
    flit.tu    = (beat_index < req.tu.size()) ? req.tu[beat_index] : tu_t'('0);
  endfunction

  // ---------------------------------------------------------------------------
  // Apply the exact CHI-E raw-DAT tagging fields absent from the exact CHI-D
  // shape.
  // ---------------------------------------------------------------------------
  virtual protected function void apply_raw_dat_issue_specific_fields(
    ref   dat_flit_t flit,
    input raw_dat_t  raw
  );
    flit.tagop = raw.tagop;
    flit.tag   = raw.tag;
    flit.tu    = raw.tu;
  endfunction
endclass

`endif