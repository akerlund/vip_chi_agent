################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# Version of the vip_chi_agent Python port.
#
# There is ONE vip_chi_agent component; sv/ and py/ are two implementations of
# it, so they carry the SAME version. This value MUST equal the version in the
# component's SV core (vip_chi_agent/vip_chi_agent.core). check_versions.py
# asserts the two agree, so the port can't silently drift from the RTL.
#
# Uniquely named (not _version.py) because every component's py/ dir shares one
# sys.path -- a generic module name would collide, first-found winning.
#
################################################################################

__version__ = "1.0.0"
CORE_NAME = "akerlund::vip_chi_agent:1.0.0"
