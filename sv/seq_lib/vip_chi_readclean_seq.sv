`ifndef VIP_CHI_READCLEAN_SEQ
`define VIP_CHI_READCLEAN_SEQ

import uvm_pkg::*;
`include "uvm_macros.svh"
import vip_chi_types_pkg::*;

// -----------------------------------------------------------------------------
// Coherent ReadClean: fetch a line into a clean (SC/UC) state.
// -----------------------------------------------------------------------------
class vip_chi_readclean_seq #(
  vip_chi_cfg_t CFG_P = VIP_CHI_DEFAULT_CFG_C
  ) extends vip_chi_coherent_base_seq #(CFG_P);

  `uvm_object_param_utils(vip_chi_readclean_seq #(CFG_P))

  function new(input string name = "vip_chi_readclean_seq");
    super.new(name);
  endfunction

  task body();
    super.set_direction(VIP_CHI_DIR_READ_E);
    super.set_coherent_opcode(req_opcode_t'(VIP_CHI_REQ_READ_CLEAN_C));
    super.body();
  endtask

endclass

`endif
