#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
# SPDX-License-Identifier: Apache-2.0

# Host facts. Anything derivable is derived so the operator is only asked for
# what no machine can know. Every function returns non-zero and prints
# nothing when its input is unavailable, so these are safe to call off-host.

# Override points exist so the behaviour can be exercised on a workstation
# that is not a Proxmox host.
_detect_sysnet() { printf '%s\n' "${PVE_CONFIG_SYSNET:-/sys/class/net}"; }
_detect_meminfo() { printf '%s\n' "${PVE_CONFIG_MEMINFO:-/proc/meminfo}"; }
_detect_os_release() { printf '%s\n' "${PVE_CONFIG_OS_RELEASE:-/etc/os-release}"; }

detect_hostname_short() {
  local name=''
  name=$(hostname -s 2>/dev/null) || name=''
  [[ -n ${name} ]] || name=${HOSTNAME%%.*}
  [[ -n ${name} ]] || return 1
  printf '%s\n' "${name}"
}

# Prefers the resolver's idea of the FQDN, falling back to joining the short
# name to the configured domain when DNS has nothing to say yet.
detect_fqdn() {
  local domain=${1:-} name fqdn=''
  fqdn=$(hostname -f 2>/dev/null) || fqdn=''
  if [[ -n ${fqdn} && ${fqdn} == *.* ]]; then
    printf '%s\n' "${fqdn}"
    return 0
  fi
  name=$(detect_hostname_short) || return 1
  [[ -n ${domain} ]] || return 1
  printf '%s.%s\n' "${name}" "${domain}"
}

# Lists candidate uplink interfaces: anything backed by a real device and
# not one of the virtual kinds the host creates for bridges, guests or VPNs.
detect_physical_nics() {
  local sysnet path name
  sysnet=$(_detect_sysnet)
  [[ -d ${sysnet} ]] || return 1

  local found=0
  local restore
  # shopt -p exits non-zero when the option is off, which would trip
  # errexit; the status carries no error here.
  restore=$(shopt -p nullglob) || true
  shopt -s nullglob
  for path in "${sysnet}"/*; do
    name=$(basename -- "${path}")
    case ${name} in
      lo | vmbr* | bond* | br-* | veth* | tap* | fwbr* | fwln* | fwpr* | wg* | tailscale* | docker* | virbr* | dummy* | *.*)
        continue
        ;;
    esac
    [[ -e ${path}/bridge ]] && continue
    [[ -e ${path}/bonding ]] && continue
    [[ -e ${path}/device ]] || continue
    printf '%s\n' "${name}"
    found=1
  done
  eval "${restore}"
  [[ ${found} -eq 1 ]]
}

detect_ipv4_address() {
  local iface=$1 line family cidr
  command -v ip >/dev/null 2>&1 || return 1
  line=$(ip -4 -o addr show dev "${iface}" 2>/dev/null) || return 1
  [[ -n ${line} ]] || return 1
  read -r _ _ family cidr _ <<<"${line}"
  [[ ${family} == inet && -n ${cidr} ]] || return 1
  printf '%s\n' "${cidr%%/*}"
}

# The connected subnet, as Tailscale subnet routing and firewall rules need
# it: taken from the kernel route rather than guessed from the netmask.
detect_ipv4_subnet() {
  local iface=$1 line subnet
  command -v ip >/dev/null 2>&1 || return 1
  line=$(ip -4 -o route show dev "${iface}" 2>/dev/null | grep 'proto kernel' | head -n 1) || return 1
  [[ -n ${line} ]] || return 1
  read -r subnet _ <<<"${line}"
  [[ ${subnet} == */* ]] || return 1
  printf '%s\n' "${subnet}"
}

detect_ram_mb() {
  local meminfo kb
  meminfo=$(_detect_meminfo)
  [[ -r ${meminfo} ]] || return 1
  kb=$(sed -nE 's/^MemTotal:[[:space:]]+([0-9]+) kB$/\1/p' "${meminfo}" | head -n 1)
  [[ -n ${kb} ]] || return 1
  printf '%s\n' $((kb / 1024))
}

detect_cpu_cores() {
  local cores=''
  cores=$(nproc 2>/dev/null) || cores=''
  if [[ -z ${cores} ]] && [[ -r /proc/cpuinfo ]]; then
    cores=$(grep -c '^processor' /proc/cpuinfo) || cores=''
  fi
  [[ -n ${cores} && ${cores} =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "${cores}"
}

# The Debian suite the host actually runs. Hardcoding a release name is how
# an apt source silently points at the wrong distribution after an upgrade.
detect_debian_suite() {
  local os_release suite
  os_release=$(_detect_os_release)
  [[ -r ${os_release} ]] || return 1
  suite=$(sed -nE 's/^VERSION_CODENAME=["]?([A-Za-z0-9_.-]+)["]?$/\1/p' "${os_release}" | head -n 1)
  [[ -n ${suite} ]] || return 1
  printf '%s\n' "${suite}"
}
