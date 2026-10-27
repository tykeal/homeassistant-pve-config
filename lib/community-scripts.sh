#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
# SPDX-License-Identifier: Apache-2.0

# The community-scripts pins.
#
# Phase 2 builds its guests with the community-scripts helpers, which live
# in two repositories that are versioned apart:
#
#   community-scripts/ProxmoxVE  the scripts: ct/, vm/, install/, tools/
#   community-scripts/core       the engine: core/build.func, ui/*.func,
#                                pve/backend.func, pve/vm-core.func
#
# A ct/ script is three lines of preamble that source core/build.func from
# community-scripts/core, and the engine then fetches the matching
# install/ script back out of community-scripts/ProxmoxVE. Both lookups
# fall back to the tip of main, and each honours its own variable:
# COMMUNITY_SCRIPTS_URL for the scripts, COMMUNITY_SCRIPTS_CORE_URL for the
# engine. Pinning one leaves the other floating, so a run would still pick
# up whatever upstream pushed that morning. Both are pinned here, in one
# file, and bumping one without the other is the mistake this file exists
# to prevent.
#
# Both pins are commit SHAs, and a commit SHA is the only ref that cannot
# change under a deployment. ProxmoxVE publishes a dated tag most days, but
# those tags are lightweight and upstream can move one; core publishes no
# tags at all. The dated tag is kept below as a label on the commit, for a
# human reading how old a pin is, and never reaches a URL. Do not "tidy"
# the URLs back onto the tag.
#
# README.md carries the procedure for reviewing and bumping both.

# community-scripts/ProxmoxVE, verified 2026-10-27.
COMMUNITY_SCRIPTS_PROXMOXVE_COMMIT='d4613af2edc1aac0e63ff9ea7c6d1ae03f2f43f3'
# The dated tag that named that commit. Metadata, not a ref to fetch.
# shellcheck disable=SC2034  # documentation for the commit above
COMMUNITY_SCRIPTS_PROXMOXVE_TAG='2026-10-26'

# community-scripts/core, tip of main, verified 2026-10-27. No tag exists
# to label it with: the repository has none.
COMMUNITY_SCRIPTS_CORE_COMMIT='e889c3a6a56201fd47d500954cc44b88fccebf94'

# The two variables the upstream engine reads. Each keeps a value already
# in the environment, which is how an operator points a test run at a fork
# or at an unreleased branch without editing this file. Nothing else sets
# them, so an unset environment gets the pins above.
COMMUNITY_SCRIPTS_URL="${COMMUNITY_SCRIPTS_URL:-https://raw.githubusercontent.com/community-scripts/ProxmoxVE/${COMMUNITY_SCRIPTS_PROXMOXVE_COMMIT}}"
COMMUNITY_SCRIPTS_CORE_URL="${COMMUNITY_SCRIPTS_CORE_URL:-https://raw.githubusercontent.com/community-scripts/core/${COMMUNITY_SCRIPTS_CORE_COMMIT}}"
export COMMUNITY_SCRIPTS_URL COMMUNITY_SCRIPTS_CORE_URL
