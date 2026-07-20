`ifndef VIP_CHI_MAKEUNIQUE_SEQ
`define VIP_CHI_MAKEUNIQUE_SEQ

import uvm_pkg::*;
`include "uvm_macros.svh"
import vip_chi_types_pkg::*;

// -----------------------------------------------------------------------------
// Coherent MakeUnique: a no-data unique acquire. The requester intends to
// overwrite the whole line, so it needs write permission but NOT the current
// data. The home snoops every other holder with SnpMakeInvalid (drop to I, no
// data forwarded) and returns an RSP-only Comp granting Unique-Dirty. No write
// data burst follows (get_payload_beat_count() = 0), unlike WriteUnique.
// -----------------------------------------------------------------------------
class vip_chi_makeunique_seq #(
  vip_chi_cfg_t CFG_P = VIP_CHI_DEFAULT_CFG_C
  ) extends vip_chi_coherent_base_seq #(CFG_P);

  `uvm_object_param_utils(vip_chi_makeunique_seq #(CFG_P))

  function new(input string name = "vip_chi_makeunique_seq");
    super.new(name);
  endfunction

  task body();
    super.set_direction(VIP_CHI_DIR_WRITE_E);
    super.set_coherent_opcode(req_opcode_t'(VIP_CHI_REQ_MAKE_UNIQUE_C));
    super.body();
  endtask

endclass

`endif
