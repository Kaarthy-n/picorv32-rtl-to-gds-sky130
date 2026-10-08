# ===============================================================================
# Ignytion IO - CRUCIBLE CORE
# Copyright (c) 2026 Ignytion IO. All rights reserved.
# Author      : IGNYTION_TECH
# File        : picorv32_rtl_to_gds/11_physical_verification/Makefile
# Created     : 2026-09-08
# Description : Make entrypoint for picorv32 DRC and LVS physical verification.
# ===============================================================================

PROJECT_ROOT := $(abspath ..)
PYTHON ?= python

.PHONY: all physical clean

all: physical

physical:
	$(PYTHON) "$(PROJECT_ROOT)/run.py" ensure_stage "$(PROJECT_ROOT)" "10_gds/picorv32_top.gds" "10_gds"
	$(PYTHON) "$(PROJECT_ROOT)/run.py" run_physical "$(PROJECT_ROOT)"

clean:
	$(PYTHON) "$(PROJECT_ROOT)/run.py" clean_dirs "$(PROJECT_ROOT)" \
		"11_physical_verification/results/extract"
	$(PYTHON) "$(PROJECT_ROOT)/run.py" clean_glob "$(PROJECT_ROOT)" \
		"11_physical_verification/results/*.log" \
		"11_physical_verification/results/*.spice" \
		"11_physical_verification/results/*.v" \
		"11_physical_verification/results/*.commands" \
		"11_physical_verification/results/*.txt" \
		"11_physical_verification/results/*.rpt" \
		"11_physical_verification/results/*.csv" \
		"11_physical_verification/results/*.ext"
	$(PYTHON) "$(PROJECT_ROOT)/run.py" clean_pycache "$(PROJECT_ROOT)" "11_physical_verification"
