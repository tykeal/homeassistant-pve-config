#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

# shellcheck source=lib/stage.sh
source "${PVE_CONFIG_LIB_DIR:?PVE_CONFIG_LIB_DIR is unset}/stage.sh"

stage_require PVE_HOSTNAME PVE_FQDN PVE_BRIDGE_PORTS

SYSROOT=$(sysroot)
BRIDGE=${PVE_BRIDGE_NAME}
MODE=${PVE_BRIDGE_MODE:-dhcp}
WAIT=${PVE_NETWORK_WAIT_SECONDS:-60}

read -r -a BRIDGE_PORTS <<<"${PVE_BRIDGE_PORTS}"
if [[ ${#BRIDGE_PORTS[@]} -eq 0 ]]; then
  mapfile -t detected < <(detect_physical_nics 2>/dev/null) || true
  die "PVE_BRIDGE_PORTS is empty, and the uplink could not be identified. Set it to the interface vmbr0 should hold. Physical interfaces present: ${detected[*]:-none}"
fi

# ifupdown2 ships Proxmox's networking but leaves DHCP to the classic
# client, which is not pulled in as a dependency.
if [[ ${MODE} == dhcp ]]; then
  pkg_install isc-dhcp-client >/dev/null
fi

# --- /etc/network/interfaces ----------------------------------------------

interfaces="# Managed by pve-config. Edits are overwritten on the next run.
# For more information, see interfaces(5).

source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback
"

# Only the ports the operator or uplink detection chose. Enslaving every
# port a machine has would put two live ports in one bridge with STP off,
# and merge a storage or WAN port into management on anything larger.
for port in "${BRIDGE_PORTS[@]}"; do
  interfaces+="
auto ${port}
iface ${port} inet manual
"
done

interfaces+="
auto ${BRIDGE}
"
case ${MODE} in
  dhcp)
    interfaces+="iface ${BRIDGE} inet dhcp
"
    ;;
  static)
    [[ -n ${PVE_BRIDGE_ADDRESS:-} ]] ||
      die 'PVE_BRIDGE_MODE is static but PVE_BRIDGE_ADDRESS is unset.'
    interfaces+="iface ${BRIDGE} inet static
        address ${PVE_BRIDGE_ADDRESS}
"
    if [[ -n ${PVE_BRIDGE_GATEWAY:-} ]]; then
      interfaces+="        gateway ${PVE_BRIDGE_GATEWAY}
"
    fi
    ;;
  *) die "PVE_BRIDGE_MODE must be dhcp or static, got: ${MODE}" ;;
esac

interfaces+="        bridge-ports ${BRIDGE_PORTS[*]}
        bridge-stp off
        bridge-fd 0
"

interfaces_path="${SYSROOT}/etc/network/interfaces"
ensure_dir "${SYSROOT}/etc/network" 0755 >/dev/null

# Everything this stage writes describes lo, the chosen ports and vmbr0.
# Anything else the file already held -- a storage port with an address, a
# VLAN, a second bridge -- would be dropped, and `ifreload -a` would take
# those networks down while vmbr0 still came up with an address, so nothing
# later in the stage would notice the loss.
unmanaged_stanzas() {
  local line name method managed
  local -a fields=()
  [[ -f ${interfaces_path} ]] || return 0
  while IFS= read -r line || [[ -n ${line} ]]; do
    line=${line#"${line%%[![:space:]]*}"}
    [[ ${line} == iface[[:space:]]* ]] || continue
    read -r -a fields <<<"${line}"
    name=${fields[1]:-}
    method=${fields[3]:-}
    [[ -n ${name} ]] || continue
    [[ ${name} == lo || ${name} == "${BRIDGE}" ]] && continue
    managed=0
    for port in "${BRIDGE_PORTS[@]}"; do
      [[ ${name} == "${port}" ]] && managed=1
    done
    [[ ${managed} -eq 1 ]] && continue
    # A bare `manual` stanza for a port this host is not using describes
    # nothing and costs nothing to drop. A method, a VLAN, an alias or
    # another bridge or bond is somebody's configuration.
    case ${name} in
      vmbr* | bond* | *.* | *:*) ;;
      *)
        [[ ${method} == manual || -z ${method} ]] && continue
        ;;
    esac
    printf '%s\n' "${name}"
  done <"${interfaces_path}"
}

mapfile -t UNMANAGED < <(unmanaged_stanzas)
if [[ ${#UNMANAGED[@]} -gt 0 ]]; then
  if [[ ${PVE_NETWORK_TAKEOVER:-no} == yes ]]; then
    log_warn "replacing ${interfaces_path}, dropping: ${UNMANAGED[*]}"
  else
    die "${interfaces_path} also describes ${UNMANAGED[*]}, which this stage would drop. Move them into /etc/network/interfaces.d, or set PVE_NETWORK_TAKEOVER=yes to replace the file anyway."
  fi
fi

# --- dhclient exit hook ---------------------------------------------------

# The body is a quoted heredoc so that $reason and $new_ip_address reach the
# generated script untouched; this host's own names are substituted in
# afterwards, which is the only expansion that should happen here.
read -r -d '' hook <<'HOOK' || true
#!/bin/sh
# Managed by pve-config. Keeps /etc/hosts on whatever address the bridge is
# leased, so that pve-cluster and the web interface agree about this node.

case "${reason}" in
  BOUND | RENEW | REBIND | REBOOT)
    # Only the management bridge. dhclient runs every exit hook for every
    # interface it manages, so a lease on a storage or WAN port would
    # otherwise rewrite this node's address with that port's.
    if [ "${interface}" = '@BRIDGE@' ] && [ -n "${new_ip_address}" ]; then
      pve_hosts_tmp=$(mktemp /etc/hosts.pve-config.XXXXXX) || pve_hosts_tmp=''
      if [ -n "${pve_hosts_tmp}" ]; then
        grep -v "[[:space:]]@FQDN@\([[:space:]]\|$\)" /etc/hosts \
          >"${pve_hosts_tmp}" || true
        printf '%s\t%s\t%s\n' "${new_ip_address}" '@FQDN@' '@SHORT@' \
          >>"${pve_hosts_tmp}"
        cat "${pve_hosts_tmp}" >/etc/hosts
        rm -f "${pve_hosts_tmp}"
      fi
    fi
    ;;
esac
HOOK

hook=${hook//@FQDN@/${PVE_FQDN}}
hook=${hook//@SHORT@/${PVE_HOSTNAME}}
hook=${hook//@BRIDGE@/${BRIDGE}}
hook+=$'\n'

ensure_dir "${SYSROOT}/etc/dhcp/dhclient-exit-hooks.d" 0755 >/dev/null
write_file "${SYSROOT}/etc/dhcp/dhclient-exit-hooks.d/update-etc-hosts" \
  "${hook}" 0755 >/dev/null

# --- bring the bridge up --------------------------------------------------

network_reload() {
  if command -v ifreload >/dev/null 2>&1; then
    run_cmd ifreload -a
  else
    run_cmd ifup -a
  fi
}

# Puts back whatever was there before, and reloads onto it. This runs when
# the new description cannot be activated or produces no lease, which on a
# remote host is the difference between a failed stage and an unreachable
# machine.
PREVIOUS_BODY=''
HAD_PREVIOUS=0
PREVIOUS_HOSTS=''
HAD_PREVIOUS_HOSTS=0
ROLLBACK_ARMED=0
hosts_path="${SYSROOT}/etc/hosts"

network_rollback() {
  [[ ${ROLLBACK_ARMED} -eq 1 ]] || return 0
  ROLLBACK_ARMED=0
  log_warn "restoring the previous ${interfaces_path}"
  if [[ ${HAD_PREVIOUS} -eq 1 ]]; then
    _atomic_install "${interfaces_path}" "${PREVIOUS_BODY}" 0644
  else
    rm -f -- "${interfaces_path}"
  fi
  # The dhclient hook installed above rewrites /etc/hosts as soon as the
  # bridge takes a lease, so by the time anything fails the hosts file can
  # already describe the configuration being rolled back. Restoring the
  # interfaces alone would leave the two disagreeing, and nothing runs the
  # hook again to repair it.
  if [[ ${HAD_PREVIOUS_HOSTS} -eq 1 ]]; then
    _atomic_install "${hosts_path}" "${PREVIOUS_HOSTS}" 0644
    log_warn "restored the previous ${hosts_path}"
  fi
  network_reload || log_error 'The previous network configuration could not be reloaded either.'
}

# The window that has to be covered runs from the moment the new description
# is activated to the moment /etc/hosts agrees with it. Anything that ends
# the stage inside that window -- a failed write, errexit, or the operator's
# connection dying with it -- has to put the old configuration back, or the
# host is left live on a description nothing else on it knows about.
arm_rollback() {
  ROLLBACK_ARMED=1
  trap network_rollback EXIT
  trap 'exit 1' HUP INT TERM
}

disarm_rollback() {
  ROLLBACK_ARMED=0
  trap - EXIT HUP INT TERM
}

if [[ -f ${interfaces_path} ]]; then
  HAD_PREVIOUS=1
  _slurp PREVIOUS_BODY "${interfaces_path}"
fi
if [[ -f ${hosts_path} ]]; then
  HAD_PREVIOUS_HOSTS=1
  _slurp PREVIOUS_HOSTS "${hosts_path}"
fi

# Checked before it is installed, not after: ifupdown2 will refuse a file it
# cannot parse, and finding that out from the live configuration means
# finding it out with the interfaces already down.
if write_file_pending "${interfaces_path}" "${interfaces}" 0644; then
  backup_file "${interfaces_path}" >/dev/null
fi
interfaces_state=$(install_validated "${interfaces_path}" "${interfaces}" 0644 \
  validate_interfaces_file)

address=$(detect_ipv4_address "${BRIDGE}" 2>/dev/null) || address=''

# Reconfiguring is only worth the risk when the description changed or the
# bridge has no address at all. The script this replaces ran `ifdown -a`
# first, which on a re-run takes the host off the network before it has
# anywhere to put it back.
if [[ ${interfaces_state} == changed || -z ${address} ]]; then
  if ! dry_run_enabled && [[ ${interfaces_state} == changed ]]; then
    arm_rollback
  fi
  if ! network_reload; then
    network_rollback
    die 'Unable to activate the network configuration'
  fi
fi

# Always re-read the address after a reload. The one captured above is the
# pre-reload answer, and writing it into /etc/hosts after the bridge has
# been rebuilt is how a host ends up resolving its own name to an address
# it no longer holds.
if dry_run_enabled; then
  log_info "would wait up to ${WAIT}s for ${BRIDGE} to hold an address"
  address=$(detect_ipv4_address "${BRIDGE}" 2>/dev/null) || address=''
else
  address=''
  waited=0
  while :; do
    address=$(detect_ipv4_address "${BRIDGE}" 2>/dev/null) || address=''
    [[ -n ${address} ]] && break
    [[ ${waited} -lt ${WAIT} ]] || break
    sleep 1
    waited=$((waited + 1))
  done
fi

# --- /etc/hosts -----------------------------------------------------------

if [[ -z ${address} ]]; then
  if dry_run_enabled; then
    log_warn "${BRIDGE} holds no address; ${hosts_path} would be left alone"
  else
    network_rollback
    die "${BRIDGE} did not take an address within ${WAIT}s; the previous network configuration has been restored."
  fi
else
  write_file_backup "${hosts_path}" "\
127.0.0.1	localhost
${address}	${PVE_FQDN}	${PVE_HOSTNAME}
::1		ip6-localhost ip6-loopback
fe00::0		ip6-localnet
ff00::0		ip6-mcastprefix
ff02::1		ip6-allnodes
ff02::2		ip6-allrouters
" 0644 >/dev/null
  # Only now: everything the new description needs in order to be usable is
  # in place.
  disarm_rollback
  log_info "${BRIDGE} holds ${address}; ${PVE_FQDN} resolves to it"
fi
