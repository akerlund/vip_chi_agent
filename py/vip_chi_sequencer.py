################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of vip_chi_sequencer.sv.
#
# Reset-aware sequencer. handle_reset() stops in-flight sequences on reset. In
# SV it drops phase objections and restarts the phase-default sequence; in pyUVM
# the equivalent hazard is the driver<->sequencer handshake latch: when the
# agent kills the driver mid-transaction (after get_next_item() but before
# item_done()), the export's current_item is left non-None and the restarted
# driver loop's get_next_item() raises. Clear that latch and drain any stale
# in-flight items left over from a sequence killed across the reset boundary.
#
################################################################################

from __future__ import annotations

from pyuvm import uvm_sequencer


# Handshake conditions (CocotbEvents) a sequence may be parked on inside the
# start_item()/finish_item() protocol. Pulsing them releases the awaiting
# sequence so it can unwind across a reset boundary.
_ITEM_CONDS = ("finish_condition", "item_ready", "start_condition")


def _release_item(item) -> None:
  """Pulse an item's handshake conditions so a parked sequence unblocks."""
  if item is None:
    return
  for name in _ITEM_CONDS:
    cond = getattr(item, name, None)
    if cond is not None:
      try:
        cond.set()
        cond.clear()
      except Exception:
        pass


def _drain(q, release=False) -> None:
  if q is None:
    return
  while True:
    try:
      item = q.get_nowait()
    except Exception:
      break
    if release:
      _release_item(item)


class vip_chi_sequencer(uvm_sequencer):

  def __init__(self, name, parent):
    super().__init__(name, parent)

  def handle_reset(self) -> None:
    exp = getattr(self, "seq_item_export", None)
    if exp is not None:
      # The agent kills the driver mid-transaction (after get_next_item() but
      # before item_done()), so a sequence parked in finish_item() awaits a
      # finish_condition that will never fire. Release the in-flight item (and
      # any still queued) so the stalled sequence unwinds instead of hanging.
      _release_item(getattr(exp, "current_item", None))
      exp.current_item = None
      _drain(getattr(exp, "req_q", None), release=True)
      _drain(getattr(exp, "rsp_q", None))
    _drain(getattr(self, "seq_q", None), release=True)
