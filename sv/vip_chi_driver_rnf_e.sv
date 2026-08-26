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

`ifndef VIP_CHI_DRIVER_RNF_E
`define VIP_CHI_DRIVER_RNF_E

import uvm_pkg::*;
`include "uvm_macros.svh"
import vip_chi_types_pkg::*;

// The coherent requester, Issue-E-exact: the same RN-F, with the REQ and DAT
// fields the Issue E flit has and the Issue D flit does not.
//
// It exists for one field and is worth its own class for the reason that field
// shows up: 13.10.8 builds PGroupID out of {GroupIDExt[2:0], LPID[4:0]}, so a
// coherent requester that never drives GroupIDExt makes every persistent CMO on
// this link report group zero -- and report it consistently, at both ends, with
// every check agreeing. A completer cannot tell that from a requester whose
// group really is zero.
//
// vip_chi_driver_rnf extends vip_chi_driver_rni rather than vip_chi_driver_rni_e
// because the coherent link stands up on both issues. This is where the E half
// rejoins: same hooks, same bodies, one owner in vip_chi_issue_e_fields.
class vip_chi_driver_rnf_e #(
  vip_chi_cfg_t  CFG_P        = VIP_CHI_DEFAULT_CFG_C,
  type           FLIT_TYPES_T = vip_chi_types_e #(CFG_P)
  ) extends vip_chi_driver_rnf #(CFG_P, FLIT_TYPES_T);

  typedef vip_chi_item #(CFG_P)            item_t;
  typedef item_t::raw_req_t                raw_req_t;
  typedef item_t::raw_rsp_t                raw_rsp_t;
  typedef item_t::raw_dat_t                raw_dat_t;
  typedef FLIT_TYPES_T::vip_chi_req_flit_t req_flit_t;
  typedef FLIT_TYPES_T::vip_chi_rsp_flit_t rsp_flit_t;
  typedef FLIT_TYPES_T::vip_chi_dat_flit_t dat_flit_t;

  `uvm_component_param_utils(vip_chi_driver_rnf_e #(CFG_P, FLIT_TYPES_T))

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
    vip_chi_issue_e_fields #(CFG_P, FLIT_TYPES_T)::apply_req(flit, req);
  endfunction

  // ---------------------------------------------------------------------------
  // Apply the exact CHI-E REQ-only raw fields absent from the exact CHI-D
  // shape.
  // ---------------------------------------------------------------------------
  virtual protected function void apply_raw_req_issue_specific_fields(
    ref   req_flit_t flit,
    input raw_req_t  raw
  );
    vip_chi_issue_e_fields #(CFG_P, FLIT_TYPES_T)::apply_raw_req(flit, raw);
  endfunction

  // ---------------------------------------------------------------------------
  // Apply the exact CHI-E raw-RSP TagOp field absent from the exact CHI-D
  // shape.
  // ---------------------------------------------------------------------------
  virtual protected function void apply_raw_rsp_issue_specific_fields(
    ref   rsp_flit_t flit,
    input raw_rsp_t  raw
  );
    vip_chi_issue_e_fields #(CFG_P, FLIT_TYPES_T)::apply_raw_rsp(flit, raw);
  endfunction

  // ---------------------------------------------------------------------------
  // Apply the exact CHI-E DAT-only tagging fields absent from the exact CHI-D
  // shape. Reached by a coherent write's data and by SnpRespData alike -- both
  // go out of this driver's DAT path.
  // ---------------------------------------------------------------------------
  virtual protected function void apply_dat_issue_specific_fields(
    ref   dat_flit_t   flit,
    input item_t       req,
    input int unsigned beat_index
  );
    vip_chi_issue_e_fields #(CFG_P, FLIT_TYPES_T)::apply_dat(flit, req, beat_index);
  endfunction

  // ---------------------------------------------------------------------------
  // Apply the exact CHI-E raw-DAT tagging fields absent from the exact CHI-D
  // shape.
  // ---------------------------------------------------------------------------
  virtual protected function void apply_raw_dat_issue_specific_fields(
    ref   dat_flit_t flit,
    input raw_dat_t  raw
  );
    vip_chi_issue_e_fields #(CFG_P, FLIT_TYPES_T)::apply_raw_dat(flit, raw);
  endfunction
endclass

`endif
