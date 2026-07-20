`ifndef VIP_CHI_EXCL_STORE_SEQ
`define VIP_CHI_EXCL_STORE_SEQ

import uvm_pkg::*;
`include "uvm_macros.svh"
import vip_chi_types_pkg::*;

// -----------------------------------------------------------------------------
// Exclusive store (SC): a CleanUnique with the exclusive attribute set. It is a
// WRITE-direction, RSP-only (no data) ownership upgrade. If the home's monitor
// for this (line, port) is still valid, the store "wins": the home invalidates
// the other holders, grants Unique, and completes Comp/ExclOkay. If an
// intervening conflict cleared the monitor the store "fails": the home still
// upgrades to Unique but completes Comp/NormalOkay, and the RN-F must retry.
// The exclusive result lands on req.rsp_resp_err. Pair with vip_chi_excl_load_seq.
// -----------------------------------------------------------------------------
class vip_chi_excl_store_seq #(
  vip_chi_cfg_t CFG_P = VIP_CHI_DEFAULT_CFG_C
  ) extends vip_chi_coherent_base_seq #(CFG_P);

  `uvm_object_param_utils(vip_chi_excl_store_seq #(CFG_P))

  function new(input string name = "vip_chi_excl_store_seq");
    super.new(name);
  endfunction

  task body();
    super.set_direction(VIP_CHI_DIR_WRITE_E);
    super.set_coherent_opcode(req_opcode_t'(VIP_CHI_REQ_CLEAN_UNIQUE_C));
    // Set excl AFTER any reset() the test issued in cfg (reset clears excl_val).
    super.set_excl(1'b1);
    super.body();
  endtask

endclass

`endif
