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
  bit                 atomic_strict_size     = 1'b0;
  bit                 get_response           = 1'b0;

  `uvm_object_utils_begin(vip_chi_cfg_item)
  `uvm_field_enum(vip_chi_dir_t,       direction, UVM_PRINT)
  `uvm_field_enum(vip_chi_data_type_t, data_type, UVM_PRINT)
  `uvm_field_int(min_size,                        UVM_PRINT)
  `uvm_field_int(max_size,                        UVM_PRINT)
  `uvm_field_int(enforce_addr_alignment,          UVM_PRINT)
  `uvm_field_int(atomic_strict_size,              UVM_PRINT)
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
    this.atomic_strict_size     = 1'b0;
    this.get_response  = 1'b0;
  endfunction
endclass

`endif
