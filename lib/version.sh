#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
# SPDX-License-Identifier: Apache-2.0

# The toolkit version, stamped in at release time.
#
# The committed tree always reads 0.0.0. The release workflow rewrites the
# assignment below from the pushed tag while it builds the tarball, so only
# a released artefact ever carries a real version. A test guards the
# placeholder so a real version cannot be committed by accident.
#
# This file holds one assignment and nothing else so that the workflow's
# sed has a single unambiguous target. The assignment is deliberately not
# readonly: every library here is safe to source more than once, and a
# readonly re-assignment would abort a stage running under `set -e`.

# shellcheck disable=SC2034  # read by the driver and by lib/state.sh
PVE_CONFIG_VERSION='0.0.0'
