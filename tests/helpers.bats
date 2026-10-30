#!/usr/bin/env bats
# SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
# SPDX-License-Identifier: Apache-2.0

# Pure helpers inside pve-baseline.sh and pve-guests.sh. Sourcing a script
# defines its functions without running main.

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
}

fake_nic() {
  mkdir -p "${SYSFS}/$1"
  shift
  local f
  for f in "$@"; do
    mkdir -p "${SYSFS}/${f}"
  done
}

@test "detect_nics lists wired devices and skips virtual and wireless ones" {
  SYSFS="${BATS_TEST_TMPDIR}/net"
  fake_nic nic0 nic0/device
  fake_nic nic1 nic1/device
  fake_nic lo
  fake_nic vmbr0 vmbr0/bridge
  fake_nic wlp2s0 wlp2s0/device wlp2s0/wireless
  fake_nic wlan1 wlan1/device wlan1/phy80211
  source "${ROOT}/pve-baseline.sh"
  run detect_nics "${SYSFS}"
  [ "${status}" -eq 0 ]
  [ "${output}" = $'nic0\nnic1' ]
}

@test "frigate_size takes a quarter of RAM and half the cores" {
  source "${ROOT}/pve-guests.sh"
  run frigate_size 16000 8
  [ "${output}" = "4000 4" ]
}

@test "frigate_size clamps small and large hosts" {
  source "${ROOT}/pve-guests.sh"
  run frigate_size 4096 2
  [ "${output}" = "2048 2" ]
  run frigate_size 131072 64
  [ "${output}" = "6144 8" ]
}
