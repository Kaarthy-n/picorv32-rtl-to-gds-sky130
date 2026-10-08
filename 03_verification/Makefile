# ===============================================================================
# Ignytion IO - CRUCIBLE CORE
# File        : picorv32_rtl_to_gds/03_verification/Makefile
# Description : Verification entrypoint: self-checking testbench regression (re-runs 02_sim).
# ===============================================================================

PROJECT_ROOT := $(abspath ..)

.PHONY: all verify clean

all: verify

# The self-checking bench (store/load round trip through the SRAM and the
# address/strobe pads) is the regression; it fails the build on any mismatch.
verify:
	$(MAKE) -C "$(PROJECT_ROOT)/02_sim"

clean:
	@true
