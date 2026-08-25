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

`ifndef VIP_CHI_ATOMIC_SEQ
`define VIP_CHI_ATOMIC_SEQ

import uvm_pkg::*;
`include "uvm_macros.svh"
import vip_chi_types_pkg::*;

class vip_chi_atomic_seq #(
  vip_chi_cfg_t CFG_P = VIP_CHI_DEFAULT_CFG_C
  ) extends vip_chi_base_seq #(CFG_P);

  `uvm_object_param_utils(vip_chi_atomic_seq #(CFG_P))

  typedef vip_chi_item #(CFG_P) item_t;
  typedef vip_chi_types #(CFG_P)::req_opcode_t req_opcode_t;

  protected vip_chi_atomic_op_t atomic_op = VIP_CHI_ATOMIC_OP_STORE_0_E;

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name = "vip_chi_atomic_seq");
    super.new(name);
  endfunction

  // ---------------------------------------------------------------------------
  // Clear atomic-specific state while preserving the inherited defaults.
  // ---------------------------------------------------------------------------
  function void reset();
    super.reset();
    this.atomic_op = VIP_CHI_ATOMIC_OP_STORE_0_E;
  endfunction

  // ---------------------------------------------------------------------------
  // Select the exact atomic opcode variant to generate.
  // ---------------------------------------------------------------------------
  function void set_atomic_op(input vip_chi_atomic_op_t op);
    this.atomic_op = op;
  endfunction

  // ---------------------------------------------------------------------------
  // Preview one generated atomic request without starting the sequence.
  // ---------------------------------------------------------------------------
  function item_t preview_next_request();
    super.set_direction(VIP_CHI_DIR_WRITE_E);
    return super.preview_next_request();
  endfunction

  // ---------------------------------------------------------------------------
  // Pin write direction before the inherited generation loop runs.
  // ---------------------------------------------------------------------------
  task body();
    super.set_direction(VIP_CHI_DIR_WRITE_E);
    super.body();
  endtask

  // ---------------------------------------------------------------------------
  // §22 L7 decision, since INVERTED: atomic Size is clamped to IHI 0050
  // E Table 2-17 / D Table 2-17 by default, and the wide-operand stress profile
  // is what a sequence has to ask for.
  //
  // It used to be the other way round -- the table was modelled but gated behind
  // a knob that defaulted off, so every atomic a plain randomize() produced was
  // unconstrained and this VIP's default stimulus was out of spec. A component
  // that checks a protocol should not violate it by default.
  //
  // The stress profile itself is unchanged and still load-bearing: the atomic
  // testcases drive a full bus-beat operand -- `set_size($clog2(DATA_BYTES_P))`,
  // i.e. Size 4 (16 B) on CHI-D and Size 6 (64 B) on CHI-E -- to exercise the
  // operand DAT / RMW / return datapath at the widest beat. They call
  // set_atomic_oversized_operands(1) to say so. Note that AtomicCompare at
  // Size 5 (32 B) is LEGAL by the table and needs no opt-in, which is why the
  // compare legs of those testcases do not carry one.
  //
  // What that decision costs, now that it is checked. IHI 0050 E Table 2-17 / D
  // Table 2-17 permits at most 8 bytes for AtomicStore, AtomicLoad and AtomicSwap
  // (Size 0..3), and 2 to 32 bytes for AtomicCompare (Size 1..5). A full bus-beat
  // operand is above the ordinary limit on every geometry in this testbench, so
  // every request this sequence issues at the default Size carries a Size the
  // specification does not list for its opcode, and CHI_ATOMIC_SIZE_LEGAL reports
  // it at both ends of every link the request crosses.
  //
  // The five testcases holding this profile therefore turn the rule down to
  // VIP_CHI_CHK_SEV_OFF_E on the links they drive, and then REQUIRE that it fired.
  // OFF still evaluates and still counts -- it only suppresses the report -- so
  // the assertion is possible at all, and disabling instead would stop the
  // counting and publish enabled = 0, which reads as a rule nothing reached rather
  // than one deliberately not enforced here.
  //
  // The second half is what makes the waiver honest. A silenced rule that stopped
  // firing -- because this default changed, or the classifier regressed -- would
  // look exactly like a passing test. Each waiver is its own negative control: the
  // testcase asserts that its traffic is out of spec in the way it claims to be,
  // and a testcase moved to spec-legal sizes fails until the waiver comes out with
  // it.
  // ---------------------------------------------------------------------------
  // Force the request opcode to the selected atomic variant.
  // ---------------------------------------------------------------------------
  virtual protected function req_opcode_t choose_opcode();
    return req_opcode_t'(vip_chi_types_pkg::vip_chi_atomic_op_to_req_opcode(this.atomic_op));
  endfunction

  // ---------------------------------------------------------------------------
  // Return the fixed access label used in progress logs.
  // ---------------------------------------------------------------------------
  virtual protected function string access_name();
    case (this.atomic_op)
      VIP_CHI_ATOMIC_OP_STORE_0_E: return "AtomicStore0";
      VIP_CHI_ATOMIC_OP_STORE_1_E: return "AtomicStore1";
      VIP_CHI_ATOMIC_OP_STORE_2_E: return "AtomicStore2";
      VIP_CHI_ATOMIC_OP_STORE_3_E: return "AtomicStore3";
      VIP_CHI_ATOMIC_OP_STORE_4_E: return "AtomicStore4";
      VIP_CHI_ATOMIC_OP_STORE_5_E: return "AtomicStore5";
      VIP_CHI_ATOMIC_OP_STORE_6_E: return "AtomicStore6";
      VIP_CHI_ATOMIC_OP_STORE_7_E: return "AtomicStore7";
      VIP_CHI_ATOMIC_OP_LOAD_0_E:  return "AtomicLoad0";
      VIP_CHI_ATOMIC_OP_LOAD_1_E:  return "AtomicLoad1";
      VIP_CHI_ATOMIC_OP_LOAD_2_E:  return "AtomicLoad2";
      VIP_CHI_ATOMIC_OP_LOAD_3_E:  return "AtomicLoad3";
      VIP_CHI_ATOMIC_OP_LOAD_4_E:  return "AtomicLoad4";
      VIP_CHI_ATOMIC_OP_LOAD_5_E:  return "AtomicLoad5";
      VIP_CHI_ATOMIC_OP_LOAD_6_E:  return "AtomicLoad6";
      VIP_CHI_ATOMIC_OP_LOAD_7_E:  return "AtomicLoad7";
      VIP_CHI_ATOMIC_OP_SWAP_E:    return "AtomicSwap";
      VIP_CHI_ATOMIC_OP_COMPARE_E: return "AtomicCompare";
      default:                     return "Atomic";
    endcase
  endfunction

endclass

class vip_chi_atomic_store_seq #(
  vip_chi_cfg_t CFG_P = VIP_CHI_DEFAULT_CFG_C
  ) extends vip_chi_atomic_seq #(CFG_P);

  `uvm_object_param_utils(vip_chi_atomic_store_seq #(CFG_P))

  typedef vip_chi_item #(CFG_P) item_t;

  protected int unsigned variant = 0;

  function new(input string name = "vip_chi_atomic_store_seq");
    super.new(name);
  endfunction

  function void reset();
    super.reset();
    this.variant = 0;
    super.set_atomic_op(this.variant_to_op(this.variant));
  endfunction

  function void set_variant(input int unsigned value);
    this.variant = value;
    super.set_atomic_op(this.variant_to_op(value));
  endfunction

  function int unsigned get_variant();
    return this.variant;
  endfunction

  function item_t preview_next_request();
    super.set_atomic_op(this.variant_to_op(this.variant));
    return super.preview_next_request();
  endfunction

  task body();
    super.set_atomic_op(this.variant_to_op(this.variant));
    super.body();
  endtask

  protected function vip_chi_atomic_op_t variant_to_op(input int unsigned value);
    case (value)
      0: return VIP_CHI_ATOMIC_OP_STORE_0_E;
      1: return VIP_CHI_ATOMIC_OP_STORE_1_E;
      2: return VIP_CHI_ATOMIC_OP_STORE_2_E;
      3: return VIP_CHI_ATOMIC_OP_STORE_3_E;
      4: return VIP_CHI_ATOMIC_OP_STORE_4_E;
      5: return VIP_CHI_ATOMIC_OP_STORE_5_E;
      6: return VIP_CHI_ATOMIC_OP_STORE_6_E;
      7: return VIP_CHI_ATOMIC_OP_STORE_7_E;
      default: begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] AtomicStore variant %0d is outside [0:7]",
          get_name(), value))
        return VIP_CHI_ATOMIC_OP_STORE_0_E;
      end
    endcase
  endfunction

endclass

class vip_chi_atomic_load_seq #(
  vip_chi_cfg_t CFG_P = VIP_CHI_DEFAULT_CFG_C
  ) extends vip_chi_atomic_seq #(CFG_P);

  `uvm_object_param_utils(vip_chi_atomic_load_seq #(CFG_P))

  typedef vip_chi_item #(CFG_P) item_t;

  protected int unsigned variant = 0;

  function new(input string name = "vip_chi_atomic_load_seq");
    super.new(name);
  endfunction

  function void reset();
    super.reset();
    this.variant = 0;
    super.set_atomic_op(this.variant_to_op(this.variant));
  endfunction

  function void set_variant(input int unsigned value);
    this.variant = value;
    super.set_atomic_op(this.variant_to_op(value));
  endfunction

  function int unsigned get_variant();
    return this.variant;
  endfunction

  function item_t preview_next_request();
    super.set_atomic_op(this.variant_to_op(this.variant));
    return super.preview_next_request();
  endfunction

  task body();
    super.set_atomic_op(this.variant_to_op(this.variant));
    super.body();
  endtask

  protected function vip_chi_atomic_op_t variant_to_op(input int unsigned value);
    case (value)
      0: return VIP_CHI_ATOMIC_OP_LOAD_0_E;
      1: return VIP_CHI_ATOMIC_OP_LOAD_1_E;
      2: return VIP_CHI_ATOMIC_OP_LOAD_2_E;
      3: return VIP_CHI_ATOMIC_OP_LOAD_3_E;
      4: return VIP_CHI_ATOMIC_OP_LOAD_4_E;
      5: return VIP_CHI_ATOMIC_OP_LOAD_5_E;
      6: return VIP_CHI_ATOMIC_OP_LOAD_6_E;
      7: return VIP_CHI_ATOMIC_OP_LOAD_7_E;
      default: begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] AtomicLoad variant %0d is outside [0:7]",
          get_name(), value))
        return VIP_CHI_ATOMIC_OP_LOAD_0_E;
      end
    endcase
  endfunction

endclass

class vip_chi_atomic_swap_seq #(
  vip_chi_cfg_t CFG_P = VIP_CHI_DEFAULT_CFG_C
  ) extends vip_chi_atomic_seq #(CFG_P);

  `uvm_object_param_utils(vip_chi_atomic_swap_seq #(CFG_P))

  typedef vip_chi_item #(CFG_P) item_t;

  function new(input string name = "vip_chi_atomic_swap_seq");
    super.new(name);
  endfunction

  function void reset();
    super.reset();
    super.set_atomic_op(VIP_CHI_ATOMIC_OP_SWAP_E);
  endfunction

  function item_t preview_next_request();
    super.set_atomic_op(VIP_CHI_ATOMIC_OP_SWAP_E);
    return super.preview_next_request();
  endfunction

  task body();
    super.set_atomic_op(VIP_CHI_ATOMIC_OP_SWAP_E);
    super.body();
  endtask

endclass

class vip_chi_atomic_compare_seq #(
  vip_chi_cfg_t CFG_P = VIP_CHI_DEFAULT_CFG_C
  ) extends vip_chi_atomic_seq #(CFG_P);

  `uvm_object_param_utils(vip_chi_atomic_compare_seq #(CFG_P))

  typedef vip_chi_item #(CFG_P) item_t;
  typedef vip_chi_types #(CFG_P)::size_t size_t;

  protected function void check_supported_compare_geometry();
    int min_combined_size;

    min_combined_size = $clog2(CFG_P.DATA_BYTES_P) + 1;
    if (min_combined_size > 6) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] AtomicCompare is not supported for DATA_BYTES_P=%0d in this beat-granular model: compare+swap would require Size %0d, beyond the 3-bit CHI Size field",
        get_name(), CFG_P.DATA_BYTES_P, min_combined_size))
    end
  endfunction

  function new(input string name = "vip_chi_atomic_compare_seq");
    super.new(name);
  endfunction

  function void reset();
    super.reset();
    super.set_atomic_op(VIP_CHI_ATOMIC_OP_COMPARE_E);
  endfunction

  function item_t preview_next_request();
    super.set_atomic_op(VIP_CHI_ATOMIC_OP_COMPARE_E);
    this.check_supported_compare_geometry();
    return super.preview_next_request();
  endfunction

  task body();
    int expected_beats;

    super.set_atomic_op(VIP_CHI_ATOMIC_OP_COMPARE_E);
    this.check_supported_compare_geometry();

    if (this.item_cfg.data_type == VIP_CHI_DATA_CUSTOM_E) begin
      if (this.item_cfg.min_size != this.item_cfg.max_size) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] AtomicCompare custom payload requires a fixed Size value",
          get_name()))
      end

      // AtomicCompare Size is the COMBINED compare+swap size (IHI 0050), so the
      // custom payload must fill the whole 2^Size operand region (both halves). [P2]
      expected_beats = vip_chi_types_pkg::chi_xfer_dat_beats(
        size_t'(this.item_cfg.max_size), CFG_P.DATA_BYTES_P);

      if (this.payload_buf.data_size() != expected_beats) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] AtomicCompare custom payload requires %0d beats, have %0d",
          get_name(), expected_beats, this.payload_buf.data_size()))
      end
    end

    super.body();
  endtask

endclass

`endif
