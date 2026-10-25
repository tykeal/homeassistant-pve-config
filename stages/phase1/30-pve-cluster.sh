#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

# shellcheck source=lib/stage.sh
source "${PVE_CONFIG_LIB_DIR:?PVE_CONFIG_LIB_DIR is unset}/stage.sh"

stage_require PVE_HOSTNAME

SYSROOT=$(sysroot)
BRIDGE=${PVE_BRIDGE_NAME}
WAIT=${PVE_NETWORK_WAIT_SECONDS:-60}

# pve-cluster reads /etc/hosts to work out which node it is. On a DHCP host
# it can win the race against the lease, decide it is nameless and refuse to
# start, so it is held until the bridge address and /etc/hosts agree.
#
# The wait lives in its own script rather than inline in ExecStartPre.
# systemd expands $ip in a unit file before /bin/sh ever sees it, which
# would leave the comparison testing an empty string against /etc/hosts and
# the wait passing immediately.
helper_dir="${SYSROOT}/usr/local/lib/pve-config"
helper="${helper_dir}/wait-for-ip.sh"
ensure_dir "${helper_dir}" 0755 >/dev/null

read -r -d '' helper_body <<HELPER || true
#!/bin/sh
# Managed by pve-config. Succeeds as soon as ${BRIDGE} holds an address that
# /etc/hosts already knows about, and gives up quietly once the configured
# wait has passed so a host with no lease still boots.
#
# The wait is a single-quoted assignment rather than text substituted into
# the loop, so a configured value cannot be read as shell syntax here.
bridge='${BRIDGE}'
wait_seconds=$(_config_quote "${WAIT}")
HELPER
helper_body+=$'\n'

read -r -d '' helper_loop <<'HELPER' || true
i=0
while [ "$i" -lt "$wait_seconds" ]; do
  ip=$(ip -4 -o addr show "$bridge" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n 1)
  if [ -n "$ip" ] && grep -q "^$ip[[:space:]]" /etc/hosts; then
    exit 0
  fi
  sleep 1
  i=$((i + 1))
done
exit 0
HELPER
helper_body+="${helper_loop}"$'\n'

helper_state=$(write_file "${helper}" "${helper_body}" 0755)

dropin_dir="${SYSROOT}/etc/systemd/system/pve-cluster.service.d"
dropin="${dropin_dir}/wait-for-ip.conf"
ensure_dir "${dropin_dir}" 0755 >/dev/null

dropin_body="[Service]
ExecStartPre=/usr/local/lib/pve-config/wait-for-ip.sh
"

dropin_state=unchanged
state_of dropin_state write_file "${dropin}" "${dropin_body}" 0644
if [[ ${dropin_state} == changed || ${helper_state} == changed ]]; then
  systemd_daemon_reload >/dev/null
fi

service_start pve-cluster.service >/dev/null

# /etc/pve only appears once pve-cluster has published its FUSE mount, and
# everything below writes through it.
if ! pve_wait_for_cluster "${WAIT}"; then
  die "pve-cluster did not publish $(sysroot)/etc/pve within ${WAIT}s."
fi

# --- node directory -------------------------------------------------------

# Proxmox names the node directory after the hostname it was installed
# with. Renaming it is the one irreversible step in this phase, so it only
# happens when there is exactly one stale directory and nothing already
# occupies the new name.
nodes_dir="${SYSROOT}/etc/pve/nodes"
if dry_run_enabled && [[ ! -d ${nodes_dir} ]]; then
  log_info "would rename the node directory under ${nodes_dir} to ${PVE_HOSTNAME}"
else
  mapfile -t node_dirs < <(
    cd -- "${nodes_dir}" 2>/dev/null && printf '%s\n' */ | sed 's#/$##'
  )
  existing=''
  for candidate in ${node_dirs[@]+"${node_dirs[@]}"}; do
    [[ ${candidate} == '*' ]] && continue
    existing=${candidate}
    break
  done

  if [[ -z ${existing} ]]; then
    log_warn "no node directory under ${nodes_dir}; leaving it to pve-cluster"
  elif [[ ${existing} == "${PVE_HOSTNAME}" ]]; then
    log_info "node directory is already ${PVE_HOSTNAME}"
  elif [[ -e "${nodes_dir}/${PVE_HOSTNAME}" ]]; then
    log_warn "${nodes_dir}/${PVE_HOSTNAME} already exists; leaving ${existing} alone"
  elif [[ ${#node_dirs[@]} -gt 1 ]]; then
    log_warn "${nodes_dir} holds several nodes; refusing to guess which one is this host"
  else
    pve_node_rename "${nodes_dir}" "${existing}" "${PVE_HOSTNAME}" >/dev/null
  fi
fi

# --- remaining services ---------------------------------------------------

for unit in pvedaemon.service pveproxy.service pvestatd.service; do
  service_start "${unit}" >/dev/null
done

log_info 'pve-cluster and the Proxmox daemons are running'
