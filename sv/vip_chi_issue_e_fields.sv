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

`ifndef VIP_CHI_ISSUE_E_FIELDS
`define VIP_CHI_ISSUE_E_FIELDS

import uvm_pkg::*;
`include "uvm_macros.svh"
import vip_chi_types_pkg::*;

// The Issue-E-only flit fields, assigned in one place.
//
// SystemVerilog gives no way to share an implementation across two classes with
// different bases, so every `_e` driver in this package used to carry its own
// copy of these bodies -- and two of them carried the same three verbatim. A
// static helper is the mixin this language does not have: each `_e` driver keeps
// its own override, and the override is one call.
//
// The duplication was not hypothetical. The bodies exist because a field is
// present in the Issue E flit and absent from the Issue D one, so the set grows
// whenever Issue E gains a field this VIP models -- and a set that grows in two
// or three places is the shape that ends up disagreeing with itself. Nothing
// would fail loudly: the driver that was not updated would put a zero on the
// wire, which is a legal value for most of these.
//
// Only ever specialized at Issue E, because only `_e` drivers call it. That is
// what makes naming `flit.groupidext` legal here at all: a member reference to a
// field the Issue D flit does not have fails at ELABORATION, not at runtime, so
// no amount of runtime issue-testing can protect a shared body.
class vip_chi_issue_e_fields #(
  vip_chi_cfg_t CFG_P        = VIP_CHI_DEFAULT_CFG_C,
  type          FLIT_TYPES_T = vip_chi_types_e #(CFG_P)
);

  typedef vip_chi_item #(CFG_P)            item_t;
  typedef item_t::raw_req_t                raw_req_t;
  typedef item_t::raw_rsp_t                raw_rsp_t;
  typedef item_t::raw_dat_t                raw_dat_t;
  typedef vip_chi_types #(CFG_P)::tag_t    tag_t;
  typedef vip_chi_types #(CFG_P)::tu_t     tu_t;
  typedef FLIT_TYPES_T::vip_chi_req_flit_t req_flit_t;
  typedef FLIT_TYPES_T::vip_chi_rsp_flit_t rsp_flit_t;
  typedef FLIT_TYPES_T::vip_chi_dat_flit_t dat_flit_t;

  // REQ: GroupIDExt and TagOp. GroupIDExt is the field 13.10.8 builds PGroupID
  // out of -- PGroupID[7:0] = {GroupIDExt[2:0], LPID[4:0]} -- so a requester
  // that leaves it here leaves every persistent CMO reporting group zero.
  static function void apply_req(ref req_flit_t flit, input item_t req);
    flit.groupidext = req.group_id_ext;
    flit.tagop      = req.tagop;
  endfunction

  static function void apply_raw_req(ref req_flit_t flit, input raw_req_t raw);
    flit.groupidext = raw.groupidext;
    flit.tagop      = raw.tagop;
  endfunction

  static function void apply_raw_rsp(ref rsp_flit_t flit, input raw_rsp_t raw);
    flit.tagop = raw.tagop;
  endfunction

  // DAT tagging is per beat, and the guards are not defensive padding: a
  // transfer wider than the item's tag arrays is how a short item reaches a long
  // burst, and an out-of-range read would be the failure rather than the zero.
  static function void apply_dat(
    ref   dat_flit_t   flit,
    input item_t       item,
    input int unsigned beat_index
  );
    flit.tagop = item.dat_tagop;
    flit.tag   = (beat_index < item.tag.size()) ? item.tag[beat_index] : tag_t'('0);
    flit.tu    = (beat_index < item.tu.size()) ? item.tu[beat_index] : tu_t'('0);
  endfunction

  static function void apply_raw_dat(ref dat_flit_t flit, input raw_dat_t raw);
    flit.tagop = raw.tagop;
    flit.tag   = raw.tag;
    flit.tu    = raw.tu;
  endfunction

endclass

`endif
