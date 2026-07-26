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

`ifndef VIP_CHI_DRIVER_SNF_E
`define VIP_CHI_DRIVER_SNF_E

import uvm_pkg::*;
`include "uvm_macros.svh"
import vip_chi_types_pkg::*;

class vip_chi_driver_snf_e #(
  vip_chi_cfg_t  CFG_P        = VIP_CHI_DEFAULT_CFG_C,
  type           FLIT_TYPES_T = vip_chi_types_e #(CFG_P)
  ) extends vip_chi_driver_snf #(CFG_P, FLIT_TYPES_T);

  typedef vip_chi_item #(CFG_P)            item_t;
  typedef vip_chi_types #(CFG_P)::addr_t   addr_t;
  typedef vip_chi_types #(CFG_P)::tagop_t  tagop_t;
  typedef item_t::raw_rsp_t                raw_rsp_t;
  typedef item_t::raw_dat_t                raw_dat_t;
  typedef vip_chi_types #(CFG_P)::tag_t    tag_t;
  typedef vip_chi_types #(CFG_P)::tu_t     tu_t;
  typedef FLIT_TYPES_T::vip_chi_dat_flit_t dat_flit_t;
  typedef FLIT_TYPES_T::vip_chi_rsp_flit_t rsp_flit_t;

  typedef struct packed {
    tagop_t dat_tagop;
    tag_t   tag;
    tu_t    tu;
  } auto_tag_store_entry_t;

  protected auto_tag_store_entry_t auto_tag_store_by_beat [longint];

  `uvm_component_param_utils(vip_chi_driver_snf_e #(CFG_P, FLIT_TYPES_T))

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent);
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  // Map one byte address onto a beat-granular tag-storage slot.
  // ---------------------------------------------------------------------------
  protected function longint auto_tag_slot_from_addr(input addr_t addr);
    return unsigned'(addr) / CFG_P.DATA_BYTES_P;
  endfunction

  // ---------------------------------------------------------------------------
  // Clear the exact-E autonomous tag store alongside the common reset path.
  // ---------------------------------------------------------------------------
  virtual protected function void handle_issue_specific_reset();
    this.auto_tag_store_by_beat.delete();
  endfunction

  // ---------------------------------------------------------------------------
  // Apply the exact CHI-E DAT-only tagging fields absent from the exact CHI-D
  // shape.
  // ---------------------------------------------------------------------------
  virtual protected function void apply_dat_issue_specific_fields(
    ref dat_flit_t     flit,
    input item_t       rsp,
    input int unsigned beat_index
  );
    flit.tagop = rsp.dat_tagop;
    flit.tag   = (beat_index < rsp.tag.size()) ? rsp.tag[beat_index] : tag_t'('0);
    flit.tu    = (beat_index < rsp.tu.size()) ? rsp.tu[beat_index] : tu_t'('0);
  endfunction

  // ---------------------------------------------------------------------------
  // Apply the exact CHI-E raw-RSP TagOp field absent from the exact CHI-D
  // shape.
  // ---------------------------------------------------------------------------
  virtual protected function void apply_raw_rsp_issue_specific_fields(
    ref rsp_flit_t flit,
    input raw_rsp_t raw
  );
    flit.tagop = raw.tagop;
  endfunction

  // ---------------------------------------------------------------------------
  // Apply the exact CHI-E raw-DAT tagging fields absent from the exact CHI-D
  // shape.
  // ---------------------------------------------------------------------------
  virtual protected function void apply_raw_dat_issue_specific_fields(
    ref dat_flit_t flit,
    input raw_dat_t raw
  );
    flit.tagop = raw.tagop;
    flit.tag   = raw.tag;
    flit.tu    = raw.tu;
  endfunction

  // ---------------------------------------------------------------------------
  // Capture write-side exact-E DAT tagging into the autonomous SN-F backing
  // store so later autonomous reads can replay the same metadata.
  // ---------------------------------------------------------------------------
  virtual protected function void capture_auto_write_issue_specific_fields(
    input addr_t       req_addr,
    input int unsigned beat_index,
    input dat_flit_t   flit
  );
    addr_t   beat_addr;
    longint  beat_slot;

    beat_addr = req_addr + addr_t'(beat_index * CFG_P.DATA_BYTES_P);
    beat_slot = this.auto_tag_slot_from_addr(beat_addr);

    this.auto_tag_store_by_beat[beat_slot].dat_tagop = tagop_t'(flit.tagop);
    this.auto_tag_store_by_beat[beat_slot].tag       = tag_t'(flit.tag);
    this.auto_tag_store_by_beat[beat_slot].tu        = tu_t'(flit.tu);
  endfunction

  // ---------------------------------------------------------------------------
  // Replay stored exact-E DAT tagging on autonomous CompData responses.
  // Untouched addresses continue to read back zero tagging metadata.
  // ---------------------------------------------------------------------------
  virtual protected function void apply_auto_read_issue_specific_fields(
    ref dat_flit_t     flit,
    input addr_t       req_addr,
    input int unsigned beat_index
  );
    addr_t  beat_addr;
    longint beat_slot;

    beat_addr = req_addr + addr_t'(beat_index * CFG_P.DATA_BYTES_P);
    beat_slot = this.auto_tag_slot_from_addr(beat_addr);

    if (this.auto_tag_store_by_beat.exists(beat_slot)) begin
      flit.tagop = this.auto_tag_store_by_beat[beat_slot].dat_tagop;
      flit.tag   = this.auto_tag_store_by_beat[beat_slot].tag;
      flit.tu    = this.auto_tag_store_by_beat[beat_slot].tu;
    end
  endfunction

endclass

`endif