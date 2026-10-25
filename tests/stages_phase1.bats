#!/usr/bin/env bats
# Every @test runs in its own subshell, so the exports these tests use to
# vary the configuration cannot leak into one another; shellcheck's
# subshell-scope warnings describe a hazard that does not exist here.
# shellcheck disable=SC2030,SC2031
# SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
# SPDX-License-Identifier: Apache-2.0

load helpers/test_helper

setup() {
  load_libs
  isolate_env
  use_mocks
  isolate_system
  stage_config
}

# Everything the driver would have resolved before the first stage runs.
stage_config() {
  export PVE_HOSTNAME='pve1'
  export PVE_DOMAIN='example.net'
  export PVE_FQDN='pve1.example.net'
  export PVE_ADMIN_USERS='alice'
  export PVE_ADMIN_KEY_SOURCE='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBtD9AX2vF5RSCtsSjbHVvkK76/OV8nbPRhiRmknvyu3 alice@example.net'
  export PVE_SUITE='trixie'
  export PVE_BRIDGE_PORTS='nic0 nic1'
  export PVE_BRIDGE_MODE='dhcp'
  export PVE_NETWORK_WAIT_SECONDS='2'
  export PVE_NO_SUBSCRIPTION='yes'
  export PVE_SUDO_SSH_AGENT='yes'
  export PVE_ZULIP_ENABLED='no'
}

# Path, mode, ownership and content digest for everything a stage may have
# touched: the scratch root, the state directory, and the mock's own record
# of what it believes the host looks like. Comparing this across two runs is
# half the idempotency guarantee.
state_fingerprint() {
  local root path
  for root in "${PVE_CONFIG_ROOT}" "${PVE_CONFIG_STATE_DIR}" \
    "${PVE_CONFIG_MOCK_STATE}"; do
    [[ -e ${root} ]] || continue
    while IFS= read -r path; do
      if [[ -L ${path} ]]; then
        printf '%s link %s\n' "${path}" "$(readlink -- "${path}")"
      elif [[ -d ${path} ]]; then
        printf '%s dir %s\n' "${path}" "$(stat -c '%a %u:%g' -- "${path}")"
      else
        printf '%s %s %s\n' "${path}" "$(stat -c '%a %u:%g' -- "${path}")" \
          "$(cksum <"${path}" | cut -d' ' -f1)"
      fi
    done < <(find "${root}" | sort)
  done
}

# The other half. A stage can leave the filesystem alone and still have
# reinstalled a package, restarted a unit or re-added a Proxmox user; only
# the mock log shows that. Anything not on this list changes host state, so
# seeing it on a second pass is a convergence failure.
# Each pattern names an exact read-only invocation, not just a read-only
# tool: `hostname` reports, `hostname pve1` sets; `ip ... show` reports,
# `ip addr add` does not; `ssh-keygen -l` inspects, `ssh-keygen -f` writes
# a key file. Allowing a whole command name would let a second pass
# reconfigure the host without this noticing.
MOCK_READ_ONLY_PATTERNS=(
  '^hostname( -[sfd])?$'
  '^ip( -[46])?( -o)? (addr|route) show( dev)? [A-Za-z0-9_.-]+$'
  '^ip( -[46])?( -o)? route show default$'
  '^dpkg-query .*'
  '^systemctl (is-active|is-enabled|show|list-unit-files)( |$).*'
  '^pveum (user|acl|role) list( |$).*'
  '^sshd( -[^ ]+)* -t( |$).*'
  '^sshd( -[^ ]+)* -T( |$).*'
  '^visudo -c -f .*'
  '^ifreload --syntax-check .*'
  '^ifquery -a -i .*'
  '^findmnt( -[^ ]+)* .*'
  '^mountpoint -q .*'
  '^ssh-keygen -l -f /dev/stdin$'
)

assert_no_mutating_calls() {
  local line pattern offenders='' allowed
  while IFS= read -r line; do
    # The recorder appends the argument list, which is empty for a bare
    # invocation; trimming keeps the patterns describing commands rather
    # than that artefact.
    line=${line%"${line##*[![:space:]]}"}
    [[ -n ${line} ]] || continue
    allowed=0
    for pattern in "${MOCK_READ_ONLY_PATTERNS[@]}"; do
      if [[ ${line} =~ ${pattern} ]]; then
        allowed=1
        break
      fi
    done
    [[ ${allowed} -eq 1 ]] && continue
    offenders+="${line}"$'\n'
  done < <(mock_calls)
  if [[ -n ${offenders} ]]; then
    printf 'second pass issued mutating commands:\n%s' "${offenders}" >&2
    return 1
  fi
}

# Runs a stage twice and fails when the second pass moved anything, on
# disk or through a command.
assert_stage_converges() {
  local stage=$1 before after
  run_phase1_stage "${stage}"
  before=$(state_fingerprint)
  : >"${PVE_CONFIG_MOCK_LOG}"
  run_phase1_stage "${stage}"
  after=$(state_fingerprint)
  [ "${before}" = "${after}" ]
  assert_no_mutating_calls
}

# --- 10-hostname ----------------------------------------------------------

@test "10-hostname writes the short name and announces the FQDN" {
  run run_phase1_stage 10-hostname.sh
  [ "$status" -eq 0 ]
  [ "$(cat "${PVE_CONFIG_ROOT}/etc/hostname")" = 'pve1' ]
  [[ "$(mock_calls)" == *'hostnamectl set-hostname pve1.example.net'* ]]
}

@test "10-hostname converges postfix without touching the rest of main.cf" {
  mkdir -p "${PVE_CONFIG_ROOT}/etc/postfix"
  printf 'myhostname = install.localdomain\nrelayhost =\n' \
    >"${PVE_CONFIG_ROOT}/etc/postfix/main.cf"

  run_phase1_stage 10-hostname.sh
  local body
  body=$(cat "${PVE_CONFIG_ROOT}/etc/postfix/main.cf")
  [[ "${body}" == *'myhostname = pve1.example.net'* ]]
  [[ "${body}" == *'relayhost ='* ]]
  [ "$(grep -c myhostname "${PVE_CONFIG_ROOT}/etc/postfix/main.cf")" -eq 1 ]
}

@test "10-hostname survives a host with no postfix" {
  run run_phase1_stage 10-hostname.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *'postfix is not installed'* ]]
}

@test "10-hostname is idempotent" {
  mkdir -p "${PVE_CONFIG_ROOT}/etc/postfix"
  printf 'myhostname = install.localdomain\n' >"${PVE_CONFIG_ROOT}/etc/postfix/main.cf"
  assert_stage_converges 10-hostname.sh
}

@test "10-hostname changes nothing under a dry run" {
  PVE_CONFIG_DRY_RUN=1 run run_phase1_stage 10-hostname.sh
  [ "$status" -eq 0 ]
  [ ! -e "${PVE_CONFIG_ROOT}/etc/hostname" ]
  [[ "$(mock_calls)" != *'hostnamectl set-hostname'* ]]
}

# --- 20-network -----------------------------------------------------------

@test "20-network enslaves every detected NIC to vmbr0" {
  run run_phase1_stage 20-network.sh
  [ "$status" -eq 0 ]
  local body
  body=$(cat "${PVE_CONFIG_ROOT}/etc/network/interfaces")
  [[ "${body}" == *'iface nic0 inet manual'* ]]
  [[ "${body}" == *'iface nic1 inet manual'* ]]
  [[ "${body}" == *'bridge-ports nic0 nic1'* ]]
  [[ "${body}" == *'iface vmbr0 inet dhcp'* ]]
  [[ "${body}" == *'bridge-stp off'* ]]
  [[ "${body}" == *'bridge-fd 0'* ]]
}

@test "20-network copes with a single NIC" {
  export PVE_BRIDGE_PORTS='eno1'
  run_phase1_stage 20-network.sh
  local body
  body=$(cat "${PVE_CONFIG_ROOT}/etc/network/interfaces")
  [[ "${body}" == *'bridge-ports eno1'* ]]
  [ "$(grep -c 'inet manual' "${PVE_CONFIG_ROOT}/etc/network/interfaces")" -eq 1 ]
}

@test "20-network copes with more than two NICs" {
  export PVE_BRIDGE_PORTS='eno1 eno2 enp3s0 enp4s0'
  run_phase1_stage 20-network.sh
  local body
  body=$(cat "${PVE_CONFIG_ROOT}/etc/network/interfaces")
  [[ "${body}" == *'bridge-ports eno1 eno2 enp3s0 enp4s0'* ]]
  [ "$(grep -c 'inet manual' "${PVE_CONFIG_ROOT}/etc/network/interfaces")" -eq 4 ]
}

@test "20-network refuses to write a bridge with no ports" {
  export PVE_BRIDGE_PORTS=''
  run run_phase1_stage 20-network.sh
  [ "$status" -ne 0 ]
  [ ! -e "${PVE_CONFIG_ROOT}/etc/network/interfaces" ]
}

# shellcheck disable=SC2016  # the point is that these must not expand
@test "20-network keeps the dhclient hook variables out of its own expansion" {
  run_phase1_stage 20-network.sh
  local hook="${PVE_CONFIG_ROOT}/etc/dhcp/dhclient-exit-hooks.d/update-etc-hosts"
  [ "$(stat -c '%a' "${hook}")" = '755' ]

  local body
  body=$(cat "${hook}")
  # dhclient supplies these at run time; they must survive generation.
  [[ "${body}" == *'${reason}'* ]]
  [[ "${body}" == *'${new_ip_address}'* ]]
  # This host's own names are baked in at generation time instead.
  [[ "${body}" == *'pve1.example.net'* ]]
  [[ "${body}" == *"'pve1'"* ]]
  [[ "${body}" != *'@FQDN@'* ]]
}

@test "20-network writes /etc/hosts with the address the bridge holds" {
  run_phase1_stage 20-network.sh
  local body
  body=$(cat "${PVE_CONFIG_ROOT}/etc/hosts")
  [[ "${body}" == *'192.0.2.50	pve1.example.net	pve1'* ]]
  [[ "${body}" == *'127.0.0.1	localhost'* ]]
}

@test "20-network fails rather than writing /etc/hosts without an address" {
  export PVE_CONFIG_MOCK_BRIDGE_IP=''
  run run_phase1_stage 20-network.sh
  [ "$status" -ne 0 ]
  [ ! -e "${PVE_CONFIG_ROOT}/etc/hosts" ]
}

@test "20-network restores the previous interfaces file when no lease arrives" {
  local path="${PVE_CONFIG_ROOT}/etc/network/interfaces"
  local previous='auto lo
iface lo inet loopback
'
  mkdir -p "${PVE_CONFIG_ROOT}/etc/network"
  printf '%s' "${previous}" >"${path}"

  export PVE_CONFIG_MOCK_BRIDGE_IP=''
  run run_phase1_stage 20-network.sh
  [ "$status" -ne 0 ]
  # The host keeps the configuration it was reachable on; leaving the new
  # one installed would strand it until somebody walked to the console.
  [ "$(cat "${path}")" = "$(printf '%s' "${previous}")" ]
  [[ "$output" == *'restored'* ]]
  # and it is reloaded onto it, not merely written back.
  [ "$(grep -c 'ifreload -a' "${PVE_CONFIG_MOCK_LOG}")" -ge 2 ]
}

@test "20-network rolls back when /etc/hosts cannot be written" {
  local path="${PVE_CONFIG_ROOT}/etc/network/interfaces"
  local previous='auto lo
iface lo inet loopback
'
  mkdir -p "${PVE_CONFIG_ROOT}/etc/network"
  printf '%s' "${previous}" >"${path}"
  # write_file refuses to follow a symlink, so this fails after the new
  # description is already live -- exactly the window the trap covers.
  ln -s /dev/null "${PVE_CONFIG_ROOT}/etc/hosts"

  run run_phase1_stage 20-network.sh
  [ "$status" -ne 0 ]
  [ "$(cat "${path}")" = "$(printf '%s' "${previous}")" ]
  [[ "$output" == *'restoring the previous'* ]]
}

@test "the idempotency guard rejects a mutating invocation" {
  # The guard is only worth anything if it would actually fail; a list that
  # permits every `hostname` or `ip` call would quietly pass anything.
  printf 'hostname pve1\n' >"${PVE_CONFIG_MOCK_LOG}"
  run assert_no_mutating_calls
  [ "$status" -ne 0 ]

  printf 'ip addr add 192.0.2.1/24 dev vmbr0\n' >"${PVE_CONFIG_MOCK_LOG}"
  run assert_no_mutating_calls
  [ "$status" -ne 0 ]

  printf 'ssh-keygen -f /root/.ssh/id_ed25519 -N \n' >"${PVE_CONFIG_MOCK_LOG}"
  run assert_no_mutating_calls
  [ "$status" -ne 0 ]

  printf 'hostname -f\nip -4 -o addr show dev vmbr0\nssh-keygen -l -f /dev/stdin\n' \
    >"${PVE_CONFIG_MOCK_LOG}"
  run assert_no_mutating_calls
  [ "$status" -eq 0 ]
}

@test "20-network validates the candidate before installing it" {
  export PVE_BRIDGE_MODE='nonsense-mode'
  run run_phase1_stage 20-network.sh
  [ "$status" -ne 0 ]
  [ ! -e "${PVE_CONFIG_ROOT}/etc/network/interfaces" ]
  [[ "$(mock_calls)" != *'ifreload -a'* ]]
}

@test "20-network re-reads the bridge address after reloading" {
  # The address the bridge holds before the reload is not the one that ends
  # up in /etc/hosts; a stale entry makes the node unreachable by name.
  export PVE_CONFIG_MOCK_BRIDGE_IP='192.0.2.77'
  run_phase1_stage 20-network.sh
  [[ "$(cat "${PVE_CONFIG_ROOT}/etc/hosts")" == *'192.0.2.77	pve1.example.net'* ]]
}

@test "20-network does not take the host off the network on a re-run" {
  run_phase1_stage 20-network.sh
  : >"${PVE_CONFIG_MOCK_LOG}"
  run run_phase1_stage 20-network.sh
  [ "$status" -eq 0 ]
  # Nothing is reconfigured when the description already matches and the
  # bridge is already addressed, and ifdown is never reached for at all.
  [[ "$(mock_calls)" != *'ifreload -a'* ]]
  [[ "$(mock_calls)" != *ifdown* ]]
}

@test "20-network is idempotent" {
  assert_stage_converges 20-network.sh
}

# shellcheck disable=SC2016  # the payloads must stay literal
@test "20-network generates a hook no configured name can break out of" {
  local payload="${BATS_TEST_TMPDIR}/pwned"
  # Everything the parser accepts today, and nothing validation lets past.
  # The hook has to be safe on its own, because it runs as root on every
  # lease long after the run that wrote it.
  export PVE_FQDN="pve1.example.net'; touch ${payload}; :'"
  export PVE_HOSTNAME='pve1`touch '"${payload}"'`'

  run run_phase1_stage 20-network.sh
  [ "$status" -eq 0 ]
  [ ! -e "${payload}" ]

  local hook="${PVE_CONFIG_ROOT}/etc/dhcp/dhclient-exit-hooks.d/update-etc-hosts"
  sh -n "${hook}"

  # Running it is the real test: a name that escaped its quoting would run
  # here, as root, the first time the bridge took a lease.
  local scratch="${BATS_TEST_TMPDIR}/hookroot"
  mkdir -p "${scratch}"
  printf '127.0.0.1\tlocalhost\n' >"${scratch}/hosts"
  sed "s#/etc/hosts#${scratch}/hosts#g" "${hook}" >"${scratch}/hook.sh"

  run env reason=BOUND interface=vmbr0 new_ip_address=192.0.2.9 \
    sh "${scratch}/hook.sh"
  [ "$status" -eq 0 ]
  [ ! -e "${payload}" ]
  # The name is data: it lands in the file exactly as configured.
  run grep -qF "${PVE_FQDN}" "${scratch}/hosts"
  [ "$status" -eq 0 ]
}

# --- 30-pve-cluster -------------------------------------------------------

# The node directory plus the fact that /etc/pve is the pmxcfs filesystem
# rather than an ordinary directory of that name -- the stage checks, and
# refuses to rename anything when it is not.
seed_cluster() {
  mkdir -p "${PVE_CONFIG_ROOT}/etc/pve/nodes/${1:-install}"
  seed_mount "${PVE_CONFIG_ROOT}/etc/pve" fuse.pve-cluster
}

seed_mount() {
  mkdir -p "${PVE_CONFIG_MOCK_STATE}"
  printf '%s|%s\n' "$1" "$2" >>"${PVE_CONFIG_MOCK_STATE}/mounts"
}

# shellcheck disable=SC2016  # the point is that this must not expand
@test "30-pve-cluster installs a wait helper systemd cannot expand" {
  seed_cluster
  run run_phase1_stage 30-pve-cluster.sh
  [ "$status" -eq 0 ]

  local dropin="${PVE_CONFIG_ROOT}/etc/systemd/system/pve-cluster.service.d/wait-for-ip.conf"
  [[ "$(cat "${dropin}")" == *'ExecStartPre=/usr/local/lib/pve-config/wait-for-ip.sh'* ]]
  # A $ip in a unit file is expanded by systemd before /bin/sh sees it, so
  # the loop has to live in a script instead.
  [[ "$(cat "${dropin}")" != *'$ip'* ]]

  local helper="${PVE_CONFIG_ROOT}/usr/local/lib/pve-config/wait-for-ip.sh"
  [ "$(stat -c '%a' "${helper}")" = '755' ]
  [[ "$(cat "${helper}")" == *'vmbr0'* ]]
  [[ "$(mock_calls)" == *'systemctl daemon-reload'* ]]
}

@test "30-pve-cluster renames a stale node directory" {
  seed_cluster install
  run_phase1_stage 30-pve-cluster.sh
  [ -d "${PVE_CONFIG_ROOT}/etc/pve/nodes/pve1" ]
  [ ! -e "${PVE_CONFIG_ROOT}/etc/pve/nodes/install" ]
}

@test "30-pve-cluster leaves a node directory that is already correct" {
  seed_cluster pve1
  run run_phase1_stage 30-pve-cluster.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *'already pve1'* ]]
  [[ "$(mock_calls)" != *'mv -T'* ]]
}

@test "30-pve-cluster refuses to rename over an existing node directory" {
  seed_cluster install
  mkdir -p "${PVE_CONFIG_ROOT}/etc/pve/nodes/pve1"
  run run_phase1_stage 30-pve-cluster.sh
  [ "$status" -eq 0 ]
  [ -d "${PVE_CONFIG_ROOT}/etc/pve/nodes/install" ]
  [ -d "${PVE_CONFIG_ROOT}/etc/pve/nodes/pve1" ]
}

@test "30-pve-cluster refuses to rename when /etc/pve is not the pmxcfs mount" {
  mkdir -p "${PVE_CONFIG_ROOT}/etc/pve/nodes/install"
  export PVE_NETWORK_WAIT_SECONDS=1
  run run_phase1_stage 30-pve-cluster.sh
  [ "$status" -ne 0 ]
  [ -d "${PVE_CONFIG_ROOT}/etc/pve/nodes/install" ]
  [[ "$output" == *'not the pve-cluster filesystem'* ]]
}

@test "30-pve-cluster fails when the cluster filesystem never appears" {
  export PVE_NETWORK_WAIT_SECONDS=1
  run run_phase1_stage 30-pve-cluster.sh
  [ "$status" -ne 0 ]
}

@test "30-pve-cluster starts the Proxmox daemons once" {
  seed_cluster
  run_phase1_stage 30-pve-cluster.sh
  local calls
  calls=$(mock_calls)
  [[ "${calls}" == *'systemctl start -- pve-cluster.service'* ]]
  [[ "${calls}" == *'systemctl start -- pveproxy.service'* ]]
  [[ "${calls}" == *'systemctl start -- pvestatd.service'* ]]
}

@test "30-pve-cluster is idempotent" {
  seed_cluster
  assert_stage_converges 30-pve-cluster.sh
}

# shellcheck disable=SC2016  # the helper keeps these for /bin/sh to expand
@test "30-pve-cluster quotes the configured wait into its helper" {
  seed_cluster
  run_phase1_stage 30-pve-cluster.sh

  local helper="${PVE_CONFIG_ROOT}/usr/local/lib/pve-config/wait-for-ip.sh"
  sh -n "${helper}"
  local body
  body=$(cat "${helper}")
  # A configured value reaches the helper as a quoted literal and is read
  # back as a variable, never pasted into the loop as text.
  [[ "${body}" == *"wait_seconds='2'"* ]]
  [[ "${body}" == *'[ "$i" -lt "$wait_seconds" ]'* ]]
}

@test "30-pve-cluster changes nothing under a dry run" {
  seed_cluster install
  PVE_CONFIG_DRY_RUN=1 run run_phase1_stage 30-pve-cluster.sh
  [ "$status" -eq 0 ]
  [ -d "${PVE_CONFIG_ROOT}/etc/pve/nodes/install" ]
  [ ! -e "${PVE_CONFIG_ROOT}/etc/systemd/system/pve-cluster.service.d" ]
  [[ "$(mock_calls)" != *'systemctl start'* ]]
}

# --- 40-repos -------------------------------------------------------------

@test "40-repos swaps enterprise for no-subscription at the detected suite" {
  mkdir -p "${PVE_CONFIG_ROOT}/etc/apt/sources.list.d"
  printf 'Types: deb\nComponents: pve-enterprise\n' \
    >"${PVE_CONFIG_ROOT}/etc/apt/sources.list.d/pve-enterprise.sources"

  run run_phase1_stage 40-repos.sh
  [ "$status" -eq 0 ]
  [ ! -e "${PVE_CONFIG_ROOT}/etc/apt/sources.list.d/pve-enterprise.sources" ]

  local body
  body=$(cat "${PVE_CONFIG_ROOT}/etc/apt/sources.list.d/proxmox.sources")
  [[ "${body}" == *'Components: pve-no-subscription'* ]]
  [[ "${body}" == *'Suites: trixie'* ]]
  [[ "$(mock_calls)" == *'apt-get update'* ]]
}

@test "40-repos follows the suite the host actually runs" {
  export PVE_SUITE='forky'
  run_phase1_stage 40-repos.sh
  [[ "$(cat "${PVE_CONFIG_ROOT}/etc/apt/sources.list.d/proxmox.sources")" == *'Suites: forky'* ]]
}

@test "40-repos converges a ceph enterprise source in place" {
  mkdir -p "${PVE_CONFIG_ROOT}/etc/apt/sources.list.d"
  printf 'Types: deb\nURIs: http://download.proxmox.com/debian/ceph-squid\nSuites: trixie\nComponents: enterprise\n' \
    >"${PVE_CONFIG_ROOT}/etc/apt/sources.list.d/ceph.sources"

  run_phase1_stage 40-repos.sh
  local body
  body=$(cat "${PVE_CONFIG_ROOT}/etc/apt/sources.list.d/ceph.sources")
  [[ "${body}" == *'Components: no-subscription'* ]]
  [[ "${body}" == *'ceph-squid'* ]]
}

@test "40-repos leaves a no-subscription ceph list the operator added" {
  mkdir -p "${PVE_CONFIG_ROOT}/etc/apt/sources.list.d"
  printf 'deb http://download.proxmox.com/debian/ceph-squid trixie no-subscription\n' \
    >"${PVE_CONFIG_ROOT}/etc/apt/sources.list.d/ceph.list"

  run_phase1_stage 40-repos.sh
  [ -f "${PVE_CONFIG_ROOT}/etc/apt/sources.list.d/ceph.list" ]
}

@test "40-repos does not refresh apt when nothing moved" {
  run_phase1_stage 40-repos.sh
  : >"${PVE_CONFIG_MOCK_LOG}"
  run run_phase1_stage 40-repos.sh
  [[ "$(mock_calls)" != *'apt-get update'* ]]
}

@test "40-repos stands down when the no-subscription repo is not wanted" {
  export PVE_NO_SUBSCRIPTION='no'
  run run_phase1_stage 40-repos.sh
  [ "$status" -eq 0 ]
  [ ! -e "${PVE_CONFIG_ROOT}/etc/apt/sources.list.d/proxmox.sources" ]
}

@test "40-repos is idempotent" {
  mkdir -p "${PVE_CONFIG_ROOT}/etc/apt/sources.list.d"
  printf 'Types: deb\n' >"${PVE_CONFIG_ROOT}/etc/apt/sources.list.d/pve-enterprise.sources"
  assert_stage_converges 40-repos.sh
}

@test "40-repos changes nothing under a dry run" {
  mkdir -p "${PVE_CONFIG_ROOT}/etc/apt/sources.list.d"
  printf 'Types: deb\n' >"${PVE_CONFIG_ROOT}/etc/apt/sources.list.d/pve-enterprise.sources"
  PVE_CONFIG_DRY_RUN=1 run run_phase1_stage 40-repos.sh
  [ "$status" -eq 0 ]
  [ -e "${PVE_CONFIG_ROOT}/etc/apt/sources.list.d/pve-enterprise.sources" ]
  [ ! -e "${PVE_CONFIG_ROOT}/etc/apt/sources.list.d/proxmox.sources" ]
}

# --- 50-no-nag ------------------------------------------------------------

@test "50-no-nag installs a re-appliable patch and the apt hook" {
  run run_phase1_stage 50-no-nag.sh
  [ "$status" -eq 0 ]
  [ "$(stat -c '%a' "${PVE_CONFIG_ROOT}/usr/local/bin/pve-no-nag.sh")" = '755' ]
  [[ "$(cat "${PVE_CONFIG_ROOT}/etc/apt/apt.conf.d/99-pve-no-nag")" == *'DPkg::Post-Invoke'* ]]
}

@test "50-no-nag installs a patch that re-applies itself and then stops" {
  local js="${PVE_CONFIG_ROOT}/usr/share/javascript/proxmoxlib.js"
  mkdir -p "$(dirname "${js}")"
  printf 'if (!(data.status.toLowerCase() === "active")) {\n' >"${js}"
  export PVE_CONFIG_NO_NAG_JS="${js}"

  run_phase1_stage 50-no-nag.sh
  [[ "$(cat "${js}")" == *NoMoreNagging* ]]
  [[ "$(mock_calls)" == *'systemctl restart pveproxy.service'* ]]

  # An upgrade has not reinstated the notice, so a second pass must not
  # touch the file or bounce the web interface again.
  local patched
  patched=$(cat "${js}")
  : >"${PVE_CONFIG_MOCK_LOG}"
  run_phase1_stage 50-no-nag.sh
  [ "$(cat "${js}")" = "${patched}" ]
  [[ "$(mock_calls)" != *'systemctl restart'* ]]
}

@test "50-no-nag re-applies the patch after an upgrade reinstates the notice" {
  local js="${PVE_CONFIG_ROOT}/usr/share/javascript/proxmoxlib.js"
  mkdir -p "$(dirname "${js}")"
  printf 'if (!(data.status.toLowerCase() === "active")) {\n' >"${js}"
  export PVE_CONFIG_NO_NAG_JS="${js}"

  run_phase1_stage 50-no-nag.sh
  printf 'if (!(data.status.toLowerCase() === "active")) {\n' >"${js}"
  run_phase1_stage 50-no-nag.sh
  [[ "$(cat "${js}")" == *NoMoreNagging* ]]
}

@test "50-no-nag is idempotent" {
  assert_stage_converges 50-no-nag.sh
}

@test "50-no-nag changes nothing under a dry run" {
  PVE_CONFIG_DRY_RUN=1 run run_phase1_stage 50-no-nag.sh
  [ "$status" -eq 0 ]
  [ ! -e "${PVE_CONFIG_ROOT}/usr/local/bin/pve-no-nag.sh" ]
}

# --- 60-admin-users -------------------------------------------------------

@test "60-admin-users converges the account, the key and the Proxmox user" {
  run run_phase1_stage 60-admin-users.sh
  [ "$status" -eq 0 ]

  local calls
  calls=$(mock_calls)
  [[ "${calls}" == *'useradd -m -s /bin/bash alice'* ]]
  [[ "${calls}" == *'usermod -aG sudo alice'* ]]
  [[ "${calls}" == *'pveum user add alice@pam'* ]]
  [[ "${calls}" == *'pveum acl modify / --roles PVEAdmin --users alice@pam'* ]]
  [ "$(cat "${PVE_CONFIG_ROOT}/home/alice/.ssh/authorized_keys")" = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBtD9AX2vF5RSCtsSjbHVvkK76/OV8nbPRhiRmknvyu3 alice@example.net' ]
}

@test "60-admin-users survives an account that already exists" {
  seed_user alice
  run run_phase1_stage 60-admin-users.sh
  [ "$status" -eq 0 ]
  [[ "$(mock_calls)" != *useradd* ]]
}

@test "60-admin-users survives a Proxmox user that already exists" {
  run_phase1_stage 60-admin-users.sh
  : >"${PVE_CONFIG_MOCK_LOG}"
  export PVE_CONFIG_MOCK_PVEUM_LIST_FAILS=1

  run run_phase1_stage 60-admin-users.sh
  [ "$status" -eq 0 ]
  [[ "$(mock_calls)" == *'pveum user add alice@pam'* ]]
}

@test "60-admin-users handles several administrators" {
  export PVE_ADMIN_USERS='alice bob carol'
  run run_phase1_stage 60-admin-users.sh
  [ "$status" -eq 0 ]

  local user
  for user in alice bob carol; do
    [ -f "${PVE_CONFIG_ROOT}/home/${user}/.ssh/authorized_keys" ]
    [[ "$(mock_calls)" == *"pveum user add ${user}@pam"* ]]
  done
}

@test "60-admin-users gives each administrator their own key when told to" {
  export PVE_ADMIN_USERS='alice bob'
  export PVE_ADMIN_KEY_BOB='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPEGfEQ9kLDwwnJtIwSPIv2Vdq2jdD8j5zg76sU1nqjj bob@example.net'

  run_phase1_stage 60-admin-users.sh
  [[ "$(cat "${PVE_CONFIG_ROOT}/home/alice/.ssh/authorized_keys")" == *AAAAC3NzaC1lZDI1NTE5AAAAIBtD9AX2vF5RSCtsSjbHVvkK76/OV8nbPRhiRmknvyu3* ]]
  [[ "$(cat "${PVE_CONFIG_ROOT}/home/bob/.ssh/authorized_keys")" == *AAAAC3NzaC1lZDI1NTE5AAAAIPEGfEQ9kLDwwnJtIwSPIv2Vdq2jdD8j5zg76sU1nqjj* ]]
  [[ "$(cat "${PVE_CONFIG_ROOT}/home/bob/.ssh/authorized_keys")" != *AAAAC3NzaC1lZDI1NTE5AAAAIBtD9AX2vF5RSCtsSjbHVvkK76/OV8nbPRhiRmknvyu3* ]]
}

@test "60-admin-users accepts a key source given as a file path" {
  mkdir -p "${PVE_CONFIG_ROOT}/root"
  printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICBP5kYJobTkr52iXaj/kJux6zSaeieZx4sLVj3Pf8jJ alice@example.net\n' >"${PVE_CONFIG_ROOT}/root/admins.pub"
  export PVE_ADMIN_KEY_SOURCE='/root/admins.pub'

  run run_phase1_stage 60-admin-users.sh
  [ "$status" -eq 0 ]
  [[ "$(cat "${PVE_CONFIG_ROOT}/home/alice/.ssh/authorized_keys")" == *AAAAC3NzaC1lZDI1NTE5AAAAICBP5kYJobTkr52iXaj/kJux6zSaeieZx4sLVj3Pf8jJ* ]]
}

@test "60-admin-users is idempotent" {
  assert_stage_converges 60-admin-users.sh
}

@test "60-admin-users is idempotent for several administrators" {
  export PVE_ADMIN_USERS='alice bob'
  assert_stage_converges 60-admin-users.sh
}

@test "60-admin-users changes nothing under a dry run" {
  PVE_CONFIG_DRY_RUN=1 run run_phase1_stage 60-admin-users.sh
  [ "$status" -eq 0 ]
  [ ! -e "${PVE_CONFIG_ROOT}/home/alice" ]
  [[ "$(mock_calls)" != *useradd* ]]
  [[ "$(mock_calls)" != *'user add'* ]]
}

# 70-ssh-sudo refuses to disable password authentication until every
# administrator can already log in with a key, which is 60-admin-users'
# job. These tests stand in for it.
seed_admin_access() {
  local user key dir
  for user in ${PVE_ADMIN_USERS}; do
    seed_user "${user}"
    dir="${PVE_CONFIG_ROOT}/home/${user}/.ssh"
    mkdir -p "${dir}"
    key=$(admin_keys_for "${user}")
    printf '%s\n' "${key}" >"${dir}/authorized_keys"
    chmod 600 "${dir}/authorized_keys"
  done
}

# --- 70-ssh-sudo ----------------------------------------------------------

@test "70-ssh-sudo installs a validated sshd fragment and reloads ssh" {
  seed_admin_access
  run run_phase1_stage 70-ssh-sudo.sh
  [ "$status" -eq 0 ]

  local body
  body=$(cat "${PVE_CONFIG_ROOT}/etc/ssh/sshd_config.d/99-hardening.conf")
  [[ "${body}" == *'PasswordAuthentication no'* ]]
  [[ "${body}" == *'KbdInteractiveAuthentication no'* ]]
  [[ "${body}" == *'PermitRootLogin prohibit-password'* ]]
  [[ "$(mock_calls)" == *'sshd -t -f'* ]]
}

@test "70-ssh-sudo refuses to disable passwords behind an unusable key" {
  export PVE_ADMIN_KEY_SOURCE='ssh-ed25519 AAAAnotarealkey alice@example.net'
  run run_phase1_stage 70-ssh-sudo.sh
  [ "$status" -ne 0 ]
  # Nothing at all: installing the fragment and then failing would leave
  # the host with passwords off and no key that works.
  [ ! -e "${PVE_CONFIG_ROOT}/etc/ssh/sshd_config.d/99-hardening.conf" ]
  [[ "$(mock_calls)" != *'systemctl reload'* ]]
}

@test "60-admin-users refuses an unusable key before touching any account" {
  export PVE_ADMIN_USERS='alice bob'
  export PVE_ADMIN_KEY_BOB='ssh-ed25519 AAAAnotarealkey bob@example.net'
  run run_phase1_stage 60-admin-users.sh
  [ "$status" -ne 0 ]
  [[ "$(mock_calls)" != *useradd* ]]
  [[ "$(mock_calls)" != *'pveum user add'* ]]
}

@test "70-ssh-sudo leaves exactly one PAM line however often it runs" {
  seed_admin_access
  mkdir -p "${PVE_CONFIG_ROOT}/etc/pam.d"
  printf '#%%PAM-1.0\n@include common-auth\n' >"${PVE_CONFIG_ROOT}/etc/pam.d/sudo"

  for _ in 1 2 3 4; do
    run_phase1_stage 70-ssh-sudo.sh
  done

  [ "$(grep -c pam_ssh_agent_auth "${PVE_CONFIG_ROOT}/etc/pam.d/sudo")" -eq 1 ]
  [ "$(sed -n 2p "${PVE_CONFIG_ROOT}/etc/pam.d/sudo")" = \
    'auth sufficient pam_ssh_agent_auth.so file=/etc/security/authorized_keys' ]
}

@test "70-ssh-sudo gathers every administrator's key for pam_ssh_agent_auth" {
  export PVE_ADMIN_USERS='alice bob'
  export PVE_ADMIN_KEY_BOB='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPEGfEQ9kLDwwnJtIwSPIv2Vdq2jdD8j5zg76sU1nqjj bob@example.net'
  seed_admin_access

  run_phase1_stage 70-ssh-sudo.sh
  local file="${PVE_CONFIG_ROOT}/etc/security/authorized_keys"
  [ "$(stat -c '%a' "${file}")" = '600' ]
  [[ "$(cat "${file}")" == *AAAAC3NzaC1lZDI1NTE5AAAAIBtD9AX2vF5RSCtsSjbHVvkK76/OV8nbPRhiRmknvyu3* ]]
  [[ "$(cat "${file}")" == *AAAAC3NzaC1lZDI1NTE5AAAAIPEGfEQ9kLDwwnJtIwSPIv2Vdq2jdD8j5zg76sU1nqjj* ]]
}

@test "70-ssh-sudo points sudo-i at the same PAM stack" {
  seed_admin_access
  run_phase1_stage 70-ssh-sudo.sh
  [ -L "${PVE_CONFIG_ROOT}/etc/pam.d/sudo-i" ]
  [ "$(readlink "${PVE_CONFIG_ROOT}/etc/pam.d/sudo-i")" = '/etc/pam.d/sudo' ]
}

@test "70-ssh-sudo installs a validated sudoers drop-in at mode 440" {
  seed_admin_access
  run_phase1_stage 70-ssh-sudo.sh
  local file="${PVE_CONFIG_ROOT}/etc/sudoers.d/90-ssh-agent"
  [ "$(stat -c '%a' "${file}")" = '440' ]
  [[ "$(cat "${file}")" == *'SSH_AUTH_SOCK'* ]]
  [[ "$(mock_calls)" == *'visudo -c -f'* ]]
}

@test "70-ssh-sudo stops at sshd hardening when agent sudo is not wanted" {
  export PVE_SUDO_SSH_AGENT='no'
  seed_admin_access
  run run_phase1_stage 70-ssh-sudo.sh
  [ "$status" -eq 0 ]
  [ -f "${PVE_CONFIG_ROOT}/etc/ssh/sshd_config.d/99-hardening.conf" ]
  [ ! -e "${PVE_CONFIG_ROOT}/etc/sudoers.d/90-ssh-agent" ]
}

@test "70-ssh-sudo is idempotent" {
  seed_admin_access
  mkdir -p "${PVE_CONFIG_ROOT}/etc/pam.d"
  printf '#%%PAM-1.0\n@include common-auth\n' >"${PVE_CONFIG_ROOT}/etc/pam.d/sudo"
  assert_stage_converges 70-ssh-sudo.sh
}

@test "70-ssh-sudo changes nothing under a dry run" {
  PVE_CONFIG_DRY_RUN=1 run run_phase1_stage 70-ssh-sudo.sh
  [ "$status" -eq 0 ]
  [ ! -e "${PVE_CONFIG_ROOT}/etc/ssh/sshd_config.d/99-hardening.conf" ]
  [ ! -e "${PVE_CONFIG_ROOT}/etc/security/authorized_keys" ]
  [ ! -e "${PVE_CONFIG_ROOT}/etc/sudoers.d/90-ssh-agent" ]
}

# --- 80-root-shell --------------------------------------------------------

@test "80-root-shell writes the aliases and guards stty" {
  run run_phase1_stage 80-root-shell.sh
  [ "$status" -eq 0 ]

  local body
  body=$(cat "${PVE_CONFIG_ROOT}/root/.bashrc")
  [[ "${body}" == *"alias ll='ls \$LS_OPTIONS -l'"* ]]
  [[ "${body}" == *"alias rm='rm -i'"* ]]
  [[ "${body}" == *"stty erase '^H'"* ]]
  # The guard is the point: an unguarded stty breaks scp outright.
  [[ "${body}" == *'if [ -t 0 ]; then'* ]]
}

@test "80-root-shell stays quiet in a non-interactive shell" {
  run_phase1_stage 80-root-shell.sh
  run bash -c "set -- ; source '${PVE_CONFIG_ROOT}/root/.bashrc'" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" != *stty* ]]
}

@test "80-root-shell keeps a copy of what it replaced" {
  mkdir -p "${PVE_CONFIG_ROOT}/root"
  printf 'the original\n' >"${PVE_CONFIG_ROOT}/root/.bashrc"
  run_phase1_stage 80-root-shell.sh
  [ "$(cat "${PVE_CONFIG_ROOT}/root/.bashrc.pve-config.bak")" = 'the original' ]
}

@test "80-root-shell is idempotent" {
  assert_stage_converges 80-root-shell.sh
}

@test "80-root-shell changes nothing under a dry run" {
  PVE_CONFIG_DRY_RUN=1 run run_phase1_stage 80-root-shell.sh
  [ "$status" -eq 0 ]
  [ ! -e "${PVE_CONFIG_ROOT}/root/.bashrc" ]
}

# --- 90-zulip -------------------------------------------------------------

zulip_secrets() {
  export PVE_ZULIP_ENABLED='yes'
  export PVE_ZULIP_STREAM='infrastructure'
  export PVE_ZULIP_SITE='https://example.zulipchat.com'
  export PVE_ZULIP_BOT_EMAIL='pve-bot@example.zulipchat.com'
  export PVE_ZULIP_BOT_API_KEY='sekrit-bot-api-key'
  export PVE_CONFIG_SECRET_KEYS='PVE_ZULIP_BOT_API_KEY'
}

@test "90-zulip skips cleanly when Zulip is not configured" {
  run run_phase1_stage 90-zulip.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *'not enabled'* ]]
  [ ! -e "${PVE_CONFIG_ROOT}/usr/local/bin/zulip-notify.sh" ]
}

@test "90-zulip fails when it is enabled but has no credentials" {
  export PVE_ZULIP_ENABLED='yes'
  run run_phase1_stage 90-zulip.sh
  # Exiting 0 here would have the driver record a notifier that was never
  # installed; only an explicit opt-out may pass quietly.
  [ "$status" -ne 0 ]
  [[ "$output" == *'PVE_ZULIP_SITE is unset'* ]]
  [ ! -e "${PVE_CONFIG_ROOT}/usr/local/bin/zulip-notify.sh" ]
}

@test "90-zulip quotes an environment value containing spaces" {
  zulip_secrets
  export PVE_ZULIP_STREAM='pve alerts'
  run_phase1_stage 90-zulip.sh
  local env_file="${PVE_CONFIG_ROOT}/etc/pve-config/zulip.env"
  # Unquoted, sourcing this would run `alerts`.
  [[ "$(cat "${env_file}")" == *"PVE_ZULIP_STREAM='pve alerts'"* ]]
  run bash -c "set -eu; . '${env_file}'; printf '%s' \"\${PVE_ZULIP_STREAM}\""
  [ "$status" -eq 0 ]
  [ "$output" = 'pve alerts' ]
}

# shellcheck disable=SC2016  # the metacharacters are the fixture; expanding them is the bug
@test "90-zulip neutralises shell metacharacters in an environment value" {
  zulip_secrets
  export PVE_ZULIP_STREAM='pve$(touch /dev/null/boom)`id`;echo'
  run_phase1_stage 90-zulip.sh
  local env_file="${PVE_CONFIG_ROOT}/etc/pve-config/zulip.env"
  run bash -c "set -eu; . '${env_file}'; printf '%s' \"\${PVE_ZULIP_STREAM}\""
  [ "$status" -eq 0 ]
  [ "$output" = 'pve$(touch /dev/null/boom)`id`;echo' ]
}

@test "90-zulip keeps the bot key out of an xtrace" {
  zulip_secrets
  # Redaction covers this toolkit's log lines; `set -x` prints every
  # expansion regardless, which is what has to stay suspended here.
  run env BASH_XTRACEFD= bash -x "${REPO_ROOT}/stages/phase1/90-zulip.sh"
  [ "$status" -eq 0 ]
  [[ "$output" != *'sekrit-bot-api-key'* ]]
}

@test "90-zulip installs the notifier and enables both units" {
  zulip_secrets
  run run_phase1_stage 90-zulip.sh
  [ "$status" -eq 0 ]

  [ "$(stat -c '%a' "${PVE_CONFIG_ROOT}/usr/local/bin/zulip-notify.sh")" = '755' ]
  [ -f "${PVE_CONFIG_ROOT}/etc/systemd/system/zulip-boot-notify.service" ]
  [ -f "${PVE_CONFIG_ROOT}/etc/systemd/system/zulip-shutdown-notify.service" ]

  local calls
  calls=$(mock_calls)
  [[ "${calls}" == *'systemctl daemon-reload'* ]]
  [[ "${calls}" == *'systemctl enable -- zulip-boot-notify.service'* ]]
  [[ "${calls}" == *'systemctl enable -- zulip-shutdown-notify.service'* ]]
}

@test "90-zulip keeps the bot key out of the world-readable notifier" {
  zulip_secrets
  run_phase1_stage 90-zulip.sh

  local notifier="${PVE_CONFIG_ROOT}/usr/local/bin/zulip-notify.sh"
  [[ "$(cat "${notifier}")" != *sekrit-bot-api-key* ]]

  local env_file="${PVE_CONFIG_ROOT}/etc/pve-config/zulip.env"
  [ "$(stat -c '%a' "${env_file}")" = '600' ]
  [ "$(stat -c '%a' "${PVE_CONFIG_ROOT}/etc/pve-config")" = '700' ]
  [[ "$(cat "${env_file}")" == *sekrit-bot-api-key* ]]
}

@test "90-zulip never prints the bot key" {
  zulip_secrets
  run run_phase1_stage 90-zulip.sh
  [ "$status" -eq 0 ]
  [[ "$output" != *sekrit-bot-api-key* ]]
}

@test "90-zulip is idempotent" {
  zulip_secrets
  assert_stage_converges 90-zulip.sh
}

@test "90-zulip changes nothing under a dry run" {
  zulip_secrets
  PVE_CONFIG_DRY_RUN=1 run run_phase1_stage 90-zulip.sh
  [ "$status" -eq 0 ]
  [ ! -e "${PVE_CONFIG_ROOT}/etc/pve-config/zulip.env" ]
  [ ! -e "${PVE_CONFIG_ROOT}/usr/local/bin/zulip-notify.sh" ]
  [[ "$(mock_calls)" != *'systemctl enable'* ]]
}

# --- review follow-ups ----------------------------------------------------

@test "20-network refuses to drop an interface it does not manage" {
  mkdir -p "${PVE_CONFIG_ROOT}/etc/network"
  printf 'auto lo\niface lo inet loopback\n\nauto nic2\niface nic2 inet static\n        address 10.9.0.2/24\n' \
    >"${PVE_CONFIG_ROOT}/etc/network/interfaces"

  run run_phase1_stage 20-network.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *nic2* ]]
  [[ "$(cat "${PVE_CONFIG_ROOT}/etc/network/interfaces")" == *'10.9.0.2/24'* ]]
}

@test "20-network replaces unmanaged stanzas when told to take over" {
  mkdir -p "${PVE_CONFIG_ROOT}/etc/network"
  printf 'auto lo\niface lo inet loopback\n\nauto nic2\niface nic2 inet static\n        address 10.9.0.2/24\n' \
    >"${PVE_CONFIG_ROOT}/etc/network/interfaces"
  export PVE_NETWORK_TAKEOVER='yes'

  run run_phase1_stage 20-network.sh
  [ "$status" -eq 0 ]
  [[ "$(cat "${PVE_CONFIG_ROOT}/etc/network/interfaces")" != *'10.9.0.2/24'* ]]
}

@test "20-network leaves a bare manual stanza for an unused port alone" {
  mkdir -p "${PVE_CONFIG_ROOT}/etc/network"
  printf 'auto lo\niface lo inet loopback\n\niface nic2 inet manual\n' \
    >"${PVE_CONFIG_ROOT}/etc/network/interfaces"

  run run_phase1_stage 20-network.sh
  [ "$status" -eq 0 ]
}

# shellcheck disable=SC2016  # the hook keeps $interface for dhclient to expand
@test "20-network restricts the dhclient hook to the management bridge" {
  run_phase1_stage 20-network.sh
  local hook
  hook=$(cat "${PVE_CONFIG_ROOT}/etc/dhcp/dhclient-exit-hooks.d/update-etc-hosts")
  [[ "${hook}" == *'[ "${interface}" = '"'"'vmbr0'"'"' ]'* ]]
}

@test "20-network restores /etc/hosts along with the interfaces" {
  # The hook rewrites /etc/hosts as soon as the bridge takes a lease, so a
  # rollback that put back only the interfaces would leave the two
  # describing different networks.
  mkdir -p "${PVE_CONFIG_ROOT}/etc"
  printf '127.0.0.1\tlocalhost\n10.9.0.2\tpve1.example.net\tpve1\n' \
    >"${PVE_CONFIG_ROOT}/etc/hosts"
  export PVE_CONFIG_MOCK_BRIDGE_IP=''

  run run_phase1_stage 20-network.sh
  [ "$status" -ne 0 ]
  [[ "$(cat "${PVE_CONFIG_ROOT}/etc/hosts")" == *'10.9.0.2	pve1.example.net	pve1'* ]]
}

@test "40-repos moves an enterprise Ceph source off the subscription host" {
  mkdir -p "${PVE_CONFIG_ROOT}/etc/apt/sources.list.d"
  printf 'Types: deb\nURIs: https://enterprise.proxmox.com/debian/ceph-squid\nSuites: trixie\nComponents: enterprise\n' \
    >"${PVE_CONFIG_ROOT}/etc/apt/sources.list.d/ceph.sources"

  run run_phase1_stage 40-repos.sh
  [ "$status" -eq 0 ]
  local body
  body=$(cat "${PVE_CONFIG_ROOT}/etc/apt/sources.list.d/ceph.sources")
  [[ "${body}" == *'download.proxmox.com/debian/ceph-squid'* ]]
  [[ "${body}" == *'Components: no-subscription'* ]]
  [[ "${body}" != *enterprise* ]]
}

@test "40-repos migrates a legacy Ceph list before removing it" {
  mkdir -p "${PVE_CONFIG_ROOT}/etc/apt/sources.list.d"
  printf 'deb https://enterprise.proxmox.com/debian/ceph-squid trixie enterprise\n' \
    >"${PVE_CONFIG_ROOT}/etc/apt/sources.list.d/ceph.list"

  run run_phase1_stage 40-repos.sh
  [ "$status" -eq 0 ]
  [ ! -e "${PVE_CONFIG_ROOT}/etc/apt/sources.list.d/ceph.list" ]
  local body
  body=$(cat "${PVE_CONFIG_ROOT}/etc/apt/sources.list.d/ceph.sources")
  [[ "${body}" == *'download.proxmox.com/debian/ceph-squid'* ]]
  [[ "${body}" == *'Suites: trixie'* ]]
  [[ "${body}" == *'Components: no-subscription'* ]]
}

@test "40-repos refreshes again after a refresh that failed" {
  export PVE_CONFIG_MOCK_APT_UPDATE_FAILS=1
  run run_phase1_stage 40-repos.sh
  [ "$status" -ne 0 ]

  unset PVE_CONFIG_MOCK_APT_UPDATE_FAILS
  : >"${PVE_CONFIG_MOCK_LOG}"
  run run_phase1_stage 40-repos.sh
  [ "$status" -eq 0 ]
  [[ "$(mock_calls)" == *'apt-get update'* ]]
}

@test "70-ssh-sudo refuses to harden before the administrators can log in" {
  # The driver runs stages on their own, so 60-admin-users may never have
  # run and passwords may still be the only way in.
  run run_phase1_stage 70-ssh-sudo.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *'60-admin-users'* ]]
  [ ! -e "${PVE_CONFIG_ROOT}/etc/ssh/sshd_config.d/99-hardening.conf" ]
}

@test "90-zulip sends the shutdown notice from ExecStop" {
  zulip_secrets
  run_phase1_stage 90-zulip.sh
  local unit
  unit=$(cat "${PVE_CONFIG_ROOT}/etc/systemd/system/zulip-shutdown-notify.service")
  [[ "${unit}" == *'ExecStop=/usr/local/bin/zulip-notify.sh shutdown'* ]]
  [[ "${unit}" == *'RemainAfterExit=yes'* ]]
  [[ "${unit}" != *'WantedBy=shutdown.target'* ]]
}

@test "20-network refuses to drop a source directive it does not manage" {
  mkdir -p "${PVE_CONFIG_ROOT}/etc/network"
  printf 'source /etc/network/storage/*.cfg\n\nauto lo\niface lo inet loopback\n' \
    >"${PVE_CONFIG_ROOT}/etc/network/interfaces"

  run run_phase1_stage 20-network.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *'/etc/network/storage'* ]]
}

@test "20-network refuses to drop a manual stanza that carries commands" {
  mkdir -p "${PVE_CONFIG_ROOT}/etc/network"
  printf 'auto lo\niface lo inet loopback\n\niface nic2 inet manual\n        mtu 9000\n        up ip addr add 10.9.0.2/24 dev nic2\n' \
    >"${PVE_CONFIG_ROOT}/etc/network/interfaces"

  run run_phase1_stage 20-network.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *nic2* ]]
}

@test "40-repos keeps the signing key of a legacy Ceph list" {
  mkdir -p "${PVE_CONFIG_ROOT}/etc/apt/sources.list.d"
  printf 'deb [signed-by=/etc/apt/keyrings/ceph.gpg] https://enterprise.proxmox.com/debian/ceph-squid trixie enterprise\n' \
    >"${PVE_CONFIG_ROOT}/etc/apt/sources.list.d/ceph.list"

  run run_phase1_stage 40-repos.sh
  [ "$status" -eq 0 ]
  local body
  body=$(cat "${PVE_CONFIG_ROOT}/etc/apt/sources.list.d/ceph.sources")
  [[ "${body}" == *'URIs: http'*'download.proxmox.com/debian/ceph-squid'* ]]
  [[ "${body}" == *'Suites: trixie'* ]]
  [[ "${body}" == *'Signed-By: /etc/apt/keyrings/ceph.gpg'* ]]
}

@test "70-ssh-sudo does not take a commented key for an active one" {
  seed_user alice
  mkdir -p "${PVE_CONFIG_ROOT}/home/alice/.ssh"
  printf '# %s\n' "${PVE_ADMIN_KEY_SOURCE}" \
    >"${PVE_CONFIG_ROOT}/home/alice/.ssh/authorized_keys"

  run run_phase1_stage 70-ssh-sudo.sh
  [ "$status" -ne 0 ]
  [ ! -e "${PVE_CONFIG_ROOT}/etc/ssh/sshd_config.d/99-hardening.conf" ]
}

@test "70-ssh-sudo keeps an Include that names another policy file" {
  seed_admin_access
  mkdir -p "${PVE_CONFIG_ROOT}/etc/ssh"
  printf 'Include /etc/ssh/site-policy.conf\nPort 22\n' \
    >"${PVE_CONFIG_ROOT}/etc/ssh/sshd_config"

  run run_phase1_stage 70-ssh-sudo.sh
  [ "$status" -eq 0 ]
  local body
  body=$(cat "${PVE_CONFIG_ROOT}/etc/ssh/sshd_config")
  [[ "${body}" == *'Include /etc/ssh/site-policy.conf'* ]]
  [[ "${body}" == *'Include /etc/ssh/sshd_config.d/*.conf'* ]]
}

@test "90-zulip arms the shutdown unit in this boot" {
  zulip_secrets
  run_phase1_stage 90-zulip.sh
  [[ "$(mock_calls)" == *'systemctl start -- zulip-shutdown-notify.service'* ]]
}

@test "70-ssh-sudo leaves no Include behind when validation fails" {
  seed_admin_access
  mkdir -p "${PVE_CONFIG_ROOT}/etc/ssh/sshd_config.d"
  printf 'Port 22\n' >"${PVE_CONFIG_ROOT}/etc/ssh/sshd_config"
  printf 'NoSuchDirective yes\n' \
    >"${PVE_CONFIG_ROOT}/etc/ssh/sshd_config.d/10-broken.conf"

  run run_phase1_stage 70-ssh-sudo.sh
  [ "$status" -ne 0 ]
  [ ! -e "${PVE_CONFIG_ROOT}/etc/ssh/sshd_config.d/99-hardening.conf" ]
  [[ "$(cat "${PVE_CONFIG_ROOT}/etc/ssh/sshd_config")" != *sshd_config.d* ]]
}

@test "70-ssh-sudo refuses a host that has public keys turned off" {
  seed_admin_access
  mkdir -p "${PVE_CONFIG_ROOT}/etc/ssh/sshd_config.d"
  printf 'PubkeyAuthentication no\nInclude /etc/ssh/sshd_config.d/*.conf\n' \
    >"${PVE_CONFIG_ROOT}/etc/ssh/sshd_config"

  run run_phase1_stage 70-ssh-sudo.sh
  [ "$status" -ne 0 ]
  [ ! -e "${PVE_CONFIG_ROOT}/etc/ssh/sshd_config.d/99-hardening.conf" ]
}

@test "70-ssh-sudo reloads again after a reload that failed" {
  seed_admin_access
  systemctl start ssh.service
  run_phase1_stage 70-ssh-sudo.sh
  printf 'pending\n' \
    >"${PVE_CONFIG_ROOT}/var/lib/pve-config/sshd-reload-pending"

  : >"${PVE_CONFIG_MOCK_LOG}"
  run run_phase1_stage 70-ssh-sudo.sh
  [ "$status" -eq 0 ]
  [[ "$(mock_calls)" == *'systemctl reload -- ssh.service'* ]]
  [ ! -e "${PVE_CONFIG_ROOT}/var/lib/pve-config/sshd-reload-pending" ]
}

@test "70-ssh-sudo adds the Include once the fragment has validated" {
  seed_admin_access
  mkdir -p "${PVE_CONFIG_ROOT}/etc/ssh"
  printf 'Port 22\n' >"${PVE_CONFIG_ROOT}/etc/ssh/sshd_config"

  run run_phase1_stage 70-ssh-sudo.sh
  [ "$status" -eq 0 ]
  [ -f "${PVE_CONFIG_ROOT}/etc/ssh/sshd_config.d/99-hardening.conf" ]
  [[ "$(cat "${PVE_CONFIG_ROOT}/etc/ssh/sshd_config")" == 'Include /etc/ssh/sshd_config.d/*.conf'* ]]
}

@test "60-admin-users makes a world writable home fit for sshd" {
  mkdir -p "${PVE_CONFIG_ROOT}/home/alice"
  chmod 0777 "${PVE_CONFIG_ROOT}/home/alice"
  seed_user alice

  run run_phase1_stage 60-admin-users.sh
  [ "$status" -eq 0 ]
  [ "$(stat -c '%a' "${PVE_CONFIG_ROOT}/home/alice")" = 755 ]
}

@test "70-ssh-sudo refuses a host that reads keys from somewhere else" {
  seed_admin_access
  mkdir -p "${PVE_CONFIG_ROOT}/etc/ssh"
  printf 'Include /etc/ssh/sshd_config.d/*.conf\nAuthorizedKeysFile /etc/ssh/keys/%%u\n' \
    >"${PVE_CONFIG_ROOT}/etc/ssh/sshd_config"

  run run_phase1_stage 70-ssh-sudo.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *AuthorizedKeysFile* ]]
  [ ! -e "${PVE_CONFIG_ROOT}/etc/ssh/sshd_config.d/99-hardening.conf" ]
}

@test "70-ssh-sudo accepts the default key file spelled out" {
  seed_admin_access
  mkdir -p "${PVE_CONFIG_ROOT}/etc/ssh"
  printf 'Include /etc/ssh/sshd_config.d/*.conf\nAuthorizedKeysFile %%h/.ssh/authorized_keys .ssh/authorized_keys2\n' \
    >"${PVE_CONFIG_ROOT}/etc/ssh/sshd_config"

  run run_phase1_stage 70-ssh-sudo.sh
  [ "$status" -eq 0 ]
  [ -f "${PVE_CONFIG_ROOT}/etc/ssh/sshd_config.d/99-hardening.conf" ]
}

@test "20-network refuses an unindented stanza option" {
  mkdir -p "${PVE_CONFIG_ROOT}/etc/network"
  printf 'auto lo\niface lo inet loopback\n\niface nic2 inet manual\nup ip addr add 10.9.0.2/24 dev nic2\n' \
    >"${PVE_CONFIG_ROOT}/etc/network/interfaces"

  run run_phase1_stage 20-network.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *nic2* ]]
}

@test "20-network parses the candidate before activating it" {
  run run_phase1_stage 20-network.sh
  [ "$status" -eq 0 ]
  [[ "$(mock_calls)" == *'ifreload --syntax-check'* ]]
}

@test "20-network parses with ifquery when ifreload will not take a file" {
  export PVE_CONFIG_MOCK_IFRELOAD_NO_FILE=1
  run run_phase1_stage 20-network.sh
  [ "$status" -eq 0 ]
  [[ "$(mock_calls)" == *'ifquery -a -i'* ]]
}

@test "70-ssh-sudo hardens a host whose fragment directory is not empty" {
  seed_admin_access
  mkdir -p "${PVE_CONFIG_ROOT}/etc/ssh/sshd_config.d"
  printf 'Include /etc/ssh/sshd_config.d/*.conf\n' \
    >"${PVE_CONFIG_ROOT}/etc/ssh/sshd_config"
  printf 'X11Forwarding no\n' \
    >"${PVE_CONFIG_ROOT}/etc/ssh/sshd_config.d/50-site.conf"

  run run_phase1_stage 70-ssh-sudo.sh
  [ "$status" -eq 0 ]
  [ -f "${PVE_CONFIG_ROOT}/etc/ssh/sshd_config.d/99-hardening.conf" ]
}

@test "70-ssh-sudo refuses a host that does not admit the administrators" {
  seed_admin_access
  mkdir -p "${PVE_CONFIG_ROOT}/etc/ssh"
  printf 'AllowUsers root\nInclude /etc/ssh/sshd_config.d/*.conf\n' \
    >"${PVE_CONFIG_ROOT}/etc/ssh/sshd_config"

  run run_phase1_stage 70-ssh-sudo.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *AllowUsers* || "$output" == *'admits only'* ]]
  [ ! -e "${PVE_CONFIG_ROOT}/etc/ssh/sshd_config.d/99-hardening.conf" ]
}

@test "70-ssh-sudo accepts a host that admits the administrators" {
  seed_admin_access
  mkdir -p "${PVE_CONFIG_ROOT}/etc/ssh"
  printf 'AllowUsers root alice\nInclude /etc/ssh/sshd_config.d/*.conf\n' \
    >"${PVE_CONFIG_ROOT}/etc/ssh/sshd_config"

  run run_phase1_stage 70-ssh-sudo.sh
  [ "$status" -eq 0 ]
  [ -f "${PVE_CONFIG_ROOT}/etc/ssh/sshd_config.d/99-hardening.conf" ]
}

@test "70-ssh-sudo refuses a host that denies an administrator's group" {
  seed_admin_access
  printf 'wheel:x:%s:alice\n' "$(id -g)" >>"${PVE_CONFIG_GROUP}"
  mkdir -p "${PVE_CONFIG_ROOT}/etc/ssh"
  printf 'DenyGroups wheel\nInclude /etc/ssh/sshd_config.d/*.conf\n' \
    >"${PVE_CONFIG_ROOT}/etc/ssh/sshd_config"

  run run_phase1_stage 70-ssh-sudo.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *wheel* ]]
  [ ! -e "${PVE_CONFIG_ROOT}/etc/ssh/sshd_config.d/99-hardening.conf" ]
}

@test "70-ssh-sudo refuses a key entry that is locked to one address" {
  seed_admin_access
  local dir="${PVE_CONFIG_ROOT}/home/alice/.ssh"
  printf 'from="127.0.0.1" %s\n' "$(admin_keys_for alice)" >"${dir}/authorized_keys"

  run run_phase1_stage 70-ssh-sudo.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *restrictions* ]]
  [ ! -e "${PVE_CONFIG_ROOT}/etc/ssh/sshd_config.d/99-hardening.conf" ]
  # The restriction is the operator's, so the stage leaves it alone.
  [[ "$(cat "${dir}/authorized_keys")" == 'from="127.0.0.1" '* ]]
}

@test "70-ssh-sudo adds up every denial the configuration makes" {
  seed_admin_access
  mkdir -p "${PVE_CONFIG_ROOT}/etc/ssh"
  printf 'DenyUsers alice\nDenyUsers mallory\nInclude /etc/ssh/sshd_config.d/*.conf\n' \
    >"${PVE_CONFIG_ROOT}/etc/ssh/sshd_config"

  run run_phase1_stage 70-ssh-sudo.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *denies* ]]
  [ ! -e "${PVE_CONFIG_ROOT}/etc/ssh/sshd_config.d/99-hardening.conf" ]
}
