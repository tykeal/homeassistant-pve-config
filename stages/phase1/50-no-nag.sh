#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

# shellcheck source=lib/stage.sh
source "${PVE_CONFIG_LIB_DIR:?PVE_CONFIG_LIB_DIR is unset}/stage.sh"

SYSROOT=$(sysroot)

if [[ ${PVE_NO_SUBSCRIPTION:-yes} != yes ]]; then
  log_info 'PVE_NO_SUBSCRIPTION is not yes; leaving the subscription notice in place'
  exit 0
fi

# The patch lives in a script rather than being applied once, because every
# proxmox-widget-toolkit upgrade ships a fresh copy of the JavaScript and
# puts the notice back. The apt hook below re-applies it after each one.
#
# The script is the thing that has to be idempotent here: it checks for its
# own marker and does nothing, in particular not restarting pveproxy, when
# the patch is already in place.
read -r -d '' nag_script <<'NAG' || true
#!/bin/sh
# Managed by pve-config. Suppresses the no-subscription notice in the web
# interface, and does nothing at all when it is already suppressed.
JS="${PVE_CONFIG_NO_NAG_JS:-/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js}"
[ -f "$JS" ] || exit 0
if grep -q 'NoMoreNagging' "$JS" 2>/dev/null; then
  exit 0
fi
echo 'pve-config: re-applying the no-subscription notice patch'
sed -i '/.*data\.status.*active/{s/!//;s/active/NoMoreNagging/}' "$JS"
systemctl restart pveproxy.service
NAG
nag_script+=$'\n'

nag_path="${SYSROOT}/usr/local/bin/pve-no-nag.sh"
ensure_dir "${SYSROOT}/usr/local/bin" 0755 >/dev/null
write_file "${nag_path}" "${nag_script}" 0755 >/dev/null

ensure_dir "${SYSROOT}/etc/apt/apt.conf.d" 0755 >/dev/null
write_file "${SYSROOT}/etc/apt/apt.conf.d/99-pve-no-nag" \
  'DPkg::Post-Invoke { "/usr/local/bin/pve-no-nag.sh || true"; };
' 0644 >/dev/null

# Run it once now rather than waiting for the next package operation. The
# script no-ops when the patch is already applied, so this costs nothing on
# a re-run.
run_cmd "${nag_path}" || log_warn 'the no-nag patch did not apply; the web interface will still work'
