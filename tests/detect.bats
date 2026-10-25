#!/usr/bin/env bats
# Every @test runs in its own subshell, so the exports these tests use to
# vary the detected host facts cannot leak into one another; shellcheck's
# subshell-scope warnings describe a hazard that does not exist here.
# shellcheck disable=SC2030,SC2031
# SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
# SPDX-License-Identifier: Apache-2.0

load helpers/test_helper

setup() {
  load_libs
  isolate_env
  FIXTURES="${BATS_TEST_TMPDIR}/fixtures"
  mkdir -p "${FIXTURES}"
}

@test "detect_debian_suite reads VERSION_CODENAME" {
  printf 'ID=debian\nVERSION_CODENAME=trixie\n' >"${FIXTURES}/os-release"
  PVE_CONFIG_OS_RELEASE="${FIXTURES}/os-release" run detect_debian_suite
  [ "$status" -eq 0 ]
  [ "$output" = 'trixie' ]
}

@test "detect_debian_suite accepts a quoted codename" {
  printf 'VERSION_CODENAME="bookworm"\n' >"${FIXTURES}/os-release"
  PVE_CONFIG_OS_RELEASE="${FIXTURES}/os-release" run detect_debian_suite
  [ "$output" = 'bookworm' ]
}

@test "detect_debian_suite degrades when os-release is absent or silent" {
  PVE_CONFIG_OS_RELEASE="${FIXTURES}/nothing-here" run detect_debian_suite
  [ "$status" -ne 0 ]
  [ -z "$output" ]

  printf 'ID=debian\n' >"${FIXTURES}/os-release"
  PVE_CONFIG_OS_RELEASE="${FIXTURES}/os-release" run detect_debian_suite
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "detect_ram_mb converts kB to MB" {
  printf 'MemTotal:       16384000 kB\nMemFree: 100 kB\n' >"${FIXTURES}/meminfo"
  PVE_CONFIG_MEMINFO="${FIXTURES}/meminfo" run detect_ram_mb
  [ "$status" -eq 0 ]
  [ "$output" = '16000' ]
}

@test "detect_ram_mb degrades when meminfo is missing" {
  PVE_CONFIG_MEMINFO="${FIXTURES}/nothing-here" run detect_ram_mb
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "detect_cpu_cores returns a positive integer" {
  run detect_cpu_cores
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]+$ ]]
  [ "$output" -ge 1 ]
}

@test "detect_physical_nics excludes loopback and virtual interfaces" {
  local sysnet="${FIXTURES}/net"
  mkdir -p "${sysnet}"/{lo,vmbr0,veth1234,eno1,enp3s0,tailscale0,docker0,vmbr0.42}
  mkdir -p "${sysnet}/eno1/device" "${sysnet}/enp3s0/device"
  mkdir -p "${sysnet}/vmbr0/bridge" "${sysnet}/vmbr0/device"
  PVE_CONFIG_SYSNET="${sysnet}" run detect_physical_nics
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [[ "$output" == *eno1* ]]
  [[ "$output" == *enp3s0* ]]
  [[ "$output" != *lo* ]]
  [[ "$output" != *vmbr0* ]]
  [[ "$output" != *docker0* ]]
}

@test "detect_physical_nics degrades when sysfs is unavailable" {
  PVE_CONFIG_SYSNET="${FIXTURES}/nothing-here" run detect_physical_nics
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "detect_physical_nics reports nothing when only virtual links exist" {
  local sysnet="${FIXTURES}/net"
  mkdir -p "${sysnet}/lo" "${sysnet}/vmbr0"
  PVE_CONFIG_SYSNET="${sysnet}" run detect_physical_nics
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

# --- uplink selection -----------------------------------------------------

@test "detect_uplink_nics picks the single interface a host has" {
  seed_nics eno1
  seed_default_route eno1
  run detect_uplink_nics
  [ "$status" -eq 0 ]
  [ "$output" = 'eno1' ]
}

@test "detect_uplink_nics picks only the port the default route uses" {
  seed_nics eno1 eno2
  seed_default_route eno2
  run detect_uplink_nics
  [ "$status" -eq 0 ]
  [ "$output" = 'eno2' ]
}

@test "detect_uplink_nics ignores the storage and WAN ports of a larger host" {
  seed_nics eno1 eno2 enp3s0f0 enp3s0f1
  seed_default_route eno1
  run detect_uplink_nics
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "$output" = 'eno1' ]
}

@test "detect_uplink_nics resolves a bridge back to the ports it holds" {
  seed_nics eno1 eno2
  seed_bridge vmbr0 eno1
  seed_default_route vmbr0
  run detect_uplink_nics
  [ "$status" -eq 0 ]
  [ "$output" = 'eno1' ]
}

@test "detect_uplink_nics reports nothing when there is no default route" {
  seed_nics eno1 eno2
  seed_default_route
  run detect_uplink_nics
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "detect_ipv4_address parses the address from the ip tool" {
  use_mocks
  run detect_ipv4_address mock0
  [ "$status" -eq 0 ]
  [ "$output" = '192.0.2.10' ]
  [[ "$(mock_calls)" == *'ip -4 -o addr show dev mock0'* ]]
}

@test "detect_ipv4_subnet parses the connected route" {
  use_mocks
  run detect_ipv4_subnet mock0
  [ "$status" -eq 0 ]
  [ "$output" = '192.0.2.0/24' ]
}

@test "the address helpers degrade on an unknown interface" {
  use_mocks
  run detect_ipv4_address nosuch0
  [ "$status" -ne 0 ]
  [ -z "$output" ]

  run detect_ipv4_subnet nosuch0
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "the address helpers degrade when the ip tool is absent" {
  run bash -c "
    source '${REPO_ROOT}/lib/detect.sh'
    PATH=''
    detect_ipv4_address mock0
  "
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "detect_hostname_short returns a name without a dot" {
  run detect_hostname_short
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [[ "$output" != *.* ]]
}

@test "detect_fqdn joins the short name to the domain as a fallback" {
  run bash -c "
    source '${REPO_ROOT}/lib/detect.sh'
    hostname() { [[ \$1 == -f ]] && return 1; printf 'pve1\n'; }
    detect_fqdn example.net
  "
  [ "$status" -eq 0 ]
  [ "$output" = 'pve1.example.net' ]
}

@test "detect_fqdn degrades when no domain is known" {
  run bash -c "
    source '${REPO_ROOT}/lib/detect.sh'
    hostname() { [[ \$1 == -f ]] && return 1; printf 'pve1\n'; }
    detect_fqdn
  "
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "the boot id path is overridable and degrades when absent" {
  run boot_id_path
  [ "$output" = "${BATS_TEST_TMPDIR}/boot_id" ]

  rm -f "${PVE_CONFIG_BOOT_ID_PATH}"
  run state_current_boot_id
  [ "$status" -ne 0 ]

  printf 'abc-123\n' >"${PVE_CONFIG_BOOT_ID_PATH}"
  run state_current_boot_id
  [ "$output" = 'abc-123' ]
}

@test "an empty boot id file is treated as unknown" {
  : >"${PVE_CONFIG_BOOT_ID_PATH}"
  run state_current_boot_id
  [ "$status" -ne 0 ]
}

@test "the schema derives what the host can tell it" {
  export PVE_CONFIG_OS_RELEASE="${BATS_TEST_TMPDIR}/os-release"
  printf 'VERSION_CODENAME=trixie\n' >"${PVE_CONFIG_OS_RELEASE}"
  export PVE_DOMAIN='example.test'
  export PVE_ADMIN_USERS='admin'
  export PVE_ADMIN_KEY_SOURCE='ssh-ed25519 AAAA admin@example.test'
  NON_INTERACTIVE=1 schema_resolve
  [ "${PVE_SUITE}" = 'trixie' ]
  [ "${PVE_FQDN}" = "${PVE_HOSTNAME}.example.test" ]
}

@test "the schema lists every key it manages" {
  run schema_entries
  [ "$status" -eq 0 ]
  [[ "$output" == *'PVE_DOMAIN|'* ]]
  [[ "$output" == *'PVE_ADMIN_KEY_SOURCE|'* ]]
}
