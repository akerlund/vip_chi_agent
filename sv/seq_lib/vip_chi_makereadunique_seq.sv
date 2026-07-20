`ifndef VIP_CHI_MAKEREADUNIQUE_SEQ
`define VIP_CHI_MAKEREADUNIQUE_SEQ

import uvm_pkg::*;
`include "uvm_macros.svh"
import vip_chi_types_pkg::*;

// -----------------------------------------------------------------------------
// Coherent MakeReadUnique: acquire a line in the unique (UC/UD) state AND fetch
// its data. Contrast MakeUnique, which acquires Unique WITHOUT data because the
// requester overwrites the whole line. The home invalidates every other holder
// (SnpUnique) and grants CompData in the unique state.
// -----------------------------------------------------------------------------
class vip_chi_makereadunique_seq #(
  vip_chi_cfg_t CFG_P = VIP_CHI_DEFAULT_CFG_C
  ) extends vip_chi_coherent_base_seq #(CFG_P);

  `uvm_object_param_utils(vip_chi_makereadunique_seq #(CFG_P))

  function new(input string name = "vip_chi_makereadunique_seq");
    super.new(name);
  endfunction

  task body();
    super.set_direction(VIP_CHI_DIR_READ_E);
    super.set_coherent_opcode(req_opcode_t'(VIP_CHI_REQ_MAKE_READ_UNIQUE_C));
    super.body();
  endtask

endclass

`endif
