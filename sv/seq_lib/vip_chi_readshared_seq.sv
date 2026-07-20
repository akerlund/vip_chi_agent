`ifndef VIP_CHI_READSHARED_SEQ
`define VIP_CHI_READSHARED_SEQ

import uvm_pkg::*;
`include "uvm_macros.svh"
import vip_chi_types_pkg::*;

// -----------------------------------------------------------------------------
// Coherent ReadShared: fetch a line into the shared (SC) state.
// -----------------------------------------------------------------------------
class vip_chi_readshared_seq #(
  vip_chi_cfg_t CFG_P = VIP_CHI_DEFAULT_CFG_C
  ) extends vip_chi_coherent_base_seq #(CFG_P);

  `uvm_object_param_utils(vip_chi_readshared_seq #(CFG_P))

  function new(input string name = "vip_chi_readshared_seq");
    super.new(name);
  endfunction

  task body();
    super.set_direction(VIP_CHI_DIR_READ_E);
    super.set_coherent_opcode(req_opcode_t'(VIP_CHI_REQ_READ_SHARED_C));
    super.body();
  endtask

endclass

`endif
