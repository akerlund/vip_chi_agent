`ifndef VIP_CHI_READ_SEQ
`define VIP_CHI_READ_SEQ

import uvm_pkg::*;
`include "uvm_macros.svh"
import vip_chi_types_pkg::*;

class vip_chi_read_seq #(
  vip_chi_cfg_t CFG_P = VIP_CHI_DEFAULT_CFG_C
  ) extends vip_chi_base_seq #(CFG_P);

  `uvm_object_param_utils(vip_chi_read_seq #(CFG_P))

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name = "vip_chi_read_seq");
    super.new(name);
  endfunction

  // ---------------------------------------------------------------------------
  // Preview one generated read request without starting the sequence.
  // ---------------------------------------------------------------------------
  function item_t preview_next_request();
    super.set_direction(VIP_CHI_DIR_READ_E);
    return super.preview_next_request();
  endfunction

  // ---------------------------------------------------------------------------
  // Pin the request direction before the inherited generation loop runs.
  // ---------------------------------------------------------------------------
  task body();
    super.set_direction(VIP_CHI_DIR_READ_E);
    super.body();
  endtask

endclass

`endif