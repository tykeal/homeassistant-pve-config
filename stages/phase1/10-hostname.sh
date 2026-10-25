#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

# shellcheck source=lib/stage.sh
source "${PVE_CONFIG_LIB_DIR:?PVE_CONFIG_LIB_DIR is unset}/stage.sh"

stage_require PVE_HOSTNAME PVE_FQDN

SYSROOT=$(sysroot)

# hostnamectl is asked for the fully qualified name first and /etc/hostname
# is written with the short one afterwards, because hostnamectl writes the
# name it is given into that same file. The order is what leaves the kernel
# knowing the FQDN while the static name stays short, which is what Proxmox
# expects of a node.
current=$(hostname 2>/dev/null) || current=''
if [[ ${current} != "${PVE_FQDN}" ]]; then
  run_cmd hostnamectl set-hostname "${PVE_FQDN}" ||
    die "Unable to set the hostname to ${PVE_FQDN}"
fi

write_file "${SYSROOT}/etc/hostname" "${PVE_HOSTNAME}"$'\n' 0644 >/dev/null

# Postfix is installed on a stock Proxmox host but is not guaranteed to be,
# and main.cf is the operator's file: only the one directive that names this
# host is converged, wherever in the file it happens to sit.
postfix_main="${SYSROOT}/etc/postfix/main.cf"
if [[ -f ${postfix_main} ]]; then
  if [[ $(ensure_exact_line "${postfix_main}" '^[[:space:]]*myhostname[[:space:]]*=' \
    "myhostname = ${PVE_FQDN}") == changed ]]; then
    log_info "postfix now announces itself as ${PVE_FQDN}"
  fi
else
  log_info 'postfix is not installed; leaving its hostname alone'
fi

log_info "hostname configured: ${PVE_HOSTNAME} (${PVE_FQDN})"
