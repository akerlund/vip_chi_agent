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

`ifndef VIP_CHI_CFG_ITEM
`define VIP_CHI_CFG_ITEM

import uvm_pkg::*;
`include "uvm_macros.svh"
import vip_chi_types_pkg::*;

class vip_chi_cfg_item extends uvm_object;

  // ---------------------------------------------------------------------------
  // Per-item randomization knobs. These fields are sequence-facing controls
  // rather than protocol flit payload.
  // ---------------------------------------------------------------------------

  vip_chi_dir_t       direction              = VIP_CHI_DIR_READ_E;
  vip_chi_data_type_t data_type              = VIP_CHI_DATA_RANDOM_E;
  int                 min_size               = 0;
  int                 max_size               = 6;
  bit                 enforce_addr_alignment = 1'b1;
  // See vip_chi_item for why this selects the DEVIATION and defaults off.
  bit                 atomic_oversized_operands     = 1'b0;
  // Combined Write + CMO opt-in. Default OFF, and the default is the point:
  // these six are legal writes, so leaving them in the randomization pool
  // unconditionally would have every existing random write test start emitting
  // them and change every waveform in the regression.
  bit                 combined_write_cmo_enable = 1'b0;
  bit                 write_unique_zero_enable = 1'b0;
  bit                 write_evict_or_evict_enable = 1'b0;
  bit                 get_response           = 1'b0;

  `uvm_object_utils_begin(vip_chi_cfg_item)
  `uvm_field_enum(vip_chi_dir_t,       direction, UVM_PRINT)
  `uvm_field_enum(vip_chi_data_type_t, data_type, UVM_PRINT)
  `uvm_field_int(min_size,                        UVM_PRINT)
  `uvm_field_int(max_size,                        UVM_PRINT)
  `uvm_field_int(enforce_addr_alignment,          UVM_PRINT)
  `uvm_field_int(atomic_oversized_operands,              UVM_PRINT)
  `uvm_field_int(combined_write_cmo_enable,       UVM_PRINT)
  `uvm_field_int(write_unique_zero_enable,        UVM_PRINT)
  `uvm_field_int(write_evict_or_evict_enable,     UVM_PRINT)
  `uvm_field_int(get_response,                    UVM_PRINT)
  `uvm_object_utils_end

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name = "vip_chi_cfg_item");
    super.new(name);
  endfunction

  // ---------------------------------------------------------------------------
  // Restore default knobs while preserving the direction pinned by the
  // owning concrete sequence.
  // ---------------------------------------------------------------------------
  function void reset();

    vip_chi_dir_t saved_direction;

    saved_direction    = this.direction;
    this.direction     = saved_direction;
    this.data_type     = VIP_CHI_DATA_RANDOM_E;
    this.min_size      = 0;
    this.max_size      = 6;
    this.enforce_addr_alignment = 1'b1;
    this.atomic_oversized_operands     = 1'b0;
    this.combined_write_cmo_enable = 1'b0;
    this.write_unique_zero_enable = 1'b0;
    this.write_evict_or_evict_enable = 1'b0;
    this.get_response  = 1'b0;
  endfunction
endclass

`endif
