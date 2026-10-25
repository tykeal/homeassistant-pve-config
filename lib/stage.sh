#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
# SPDX-License-Identifier: Apache-2.0

# The prelude every stage sources. A stage is a child process with none of
# the driver's state beyond the environment, so it pulls in the same set of
# libraries the driver did and in the same order.

_PVE_STAGE_LIB_DIR=${PVE_CONFIG_LIB_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}

# shellcheck source=lib/common.sh
source "${_PVE_STAGE_LIB_DIR}/common.sh"
# shellcheck source=lib/version.sh
source "${_PVE_STAGE_LIB_DIR}/version.sh"
# shellcheck source=lib/config.sh
source "${_PVE_STAGE_LIB_DIR}/config.sh"
# shellcheck source=lib/detect.sh
source "${_PVE_STAGE_LIB_DIR}/detect.sh"
# shellcheck source=lib/pkg.sh
source "${_PVE_STAGE_LIB_DIR}/pkg.sh"
# shellcheck source=lib/users.sh
source "${_PVE_STAGE_LIB_DIR}/users.sh"
# shellcheck source=lib/service.sh
source "${_PVE_STAGE_LIB_DIR}/service.sh"
# shellcheck source=lib/pve.sh
source "${_PVE_STAGE_LIB_DIR}/pve.sh"

# The management bridge name is fixed by convention rather than configured.
# Every Proxmox document, every support answer and every one of this
# toolkit's own guest stages says vmbr0; making it a variable would buy
# nothing and cost the ability to say that plainly. It is deliberately not
# exported: a PVE_* name in the environment would be loadable from the
# configuration file, which would make it configurable after all.
# shellcheck disable=SC2034  # read by the stages that source this prelude
PVE_BRIDGE_NAME='vmbr0'

# Fails with a clear message rather than letting a stage write a file built
# around an empty value.
stage_require() {
  local key
  for key in "$@"; do
    [[ -n ${!key:-} ]] ||
      die "${key} is required but unset; re-run the driver so it can resolve the configuration."
  done
}

# Phase 1 replaces this host's networking, hostname and SSH configuration on
# the assumption that it is a Proxmox VE node. Run against an ordinary
# Debian machine by mistake it would get most of the way through that before
# the first pve command failed, so the check happens before any of it.
#
# A dry run and a scratch tree are both exempt: neither touches the host,
# and the tests have no Proxmox tooling at all.
stage_require_proxmox() {
  local marker
  [[ -z $(sysroot) ]] || return 0
  dry_run_enabled && return 0
  [[ ${PVE_CONFIG_SKIP_PLATFORM_CHECK:-0} == 1 ]] && return 0

  for marker in /usr/bin/pveversion /usr/bin/pvesh /usr/sbin/pvecm; do
    [[ -x ${marker} ]] && return 0
  done
  die 'This does not look like a Proxmox VE host: no pveversion, pvesh or pvecm. Refusing to reconfigure it.'
}

stage_require_proxmox
