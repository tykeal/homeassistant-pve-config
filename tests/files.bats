#!/usr/bin/env bats
# SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
# SPDX-License-Identifier: Apache-2.0

# The helper scripts installed on the host and in the Tailscale container,
# run against stub commands on PATH.

bats_require_minimum_version 1.5.0

setup() {
  FILES="$(cd "${BATS_TEST_DIRNAME}/../files" && pwd)"
  BIN="${BATS_TEST_TMPDIR}/bin"
  CALLS="${BATS_TEST_TMPDIR}/calls"
  mkdir -p "${BIN}"
  : >"${CALLS}"
  PATH="${BIN}:${PATH}"
  export CALLS
}

# stub NAME BODY: a command on PATH that logs its arguments, then runs BODY.
stub() {
  # shellcheck disable=SC2016 # the stub expands $* and CALLS when it runs
  printf '#!/usr/bin/env bash\necho "%s $*" >>"${CALLS}"\n%s\n' "$1" "${2:-}" >"${BIN}/$1"
  chmod +x "${BIN}/$1"
}

zulip_env() {
  export ZULIP_NOTIFY_ENV="${BATS_TEST_TMPDIR}/zulip.env"
  printf '%s\n' "$@" >"${ZULIP_NOTIFY_ENV}"
}

@test "zulip-notify does nothing without credentials" {
  stub curl
  zulip_env 'ZULIP_URL=""' 'ZULIP_BOT_EMAIL=""' 'ZULIP_API_KEY=""' 'ZULIP_STREAM="infra"'
  run "${FILES}/zulip-notify.sh" boot
  [ "${status}" -eq 0 ]
  [ ! -s "${CALLS}" ]
}

@test "zulip-notify posts to the stream with credentials" {
  stub curl
  stub hostname 'echo pve1.example.com'
  zulip_env 'ZULIP_URL=https://z.example.com/' 'ZULIP_BOT_EMAIL=bot@example.com' \
    'ZULIP_API_KEY=secret' 'ZULIP_STREAM=infra'
  run "${FILES}/zulip-notify.sh" shutdown
  [ "${status}" -eq 0 ]
  grep -q -- '-u bot@example.com:secret' "${CALLS}"
  grep -q -- 'to=infra' "${CALLS}"
  grep -q -- 'content=:warning: \*\*pve1.example.com\*\* is shutting down' "${CALLS}"
  grep -q -- 'https://z.example.com/api/v1/messages' "${CALLS}"
}

@test "ts-advertise-routes advertises every connected subnet of eth0" {
  stub ip 'printf "192.168.1.0/24 proto kernel scope link src 192.168.1.5\n10.0.0.0/8 proto kernel scope link src 10.1.1.1\n"'
  stub tailscale
  run "${FILES}/ts-advertise-routes.sh"
  [ "${status}" -eq 0 ]
  grep -q -- 'ip -4 route show dev eth0 proto kernel scope link' "${CALLS}"
  grep -q -- 'tailscale set --advertise-routes=192.168.1.0/24,10.0.0.0/8' "${CALLS}"
}

@test "ts-advertise-routes waits for tailscale to come up" {
  stub ip 'echo "172.16.5.0/24 proto kernel scope link src 172.16.5.9"'
  # shellcheck disable=SC2016 # evaluated inside the stub
  stub tailscale '[ "$1" != status ] || [ "$(grep -c "^tailscale status" "${CALLS}")" -ge 3 ]'
  TS_ROUTE_DELAY=0 run "${FILES}/ts-advertise-routes.sh"
  [ "${status}" -eq 0 ]
  [ "$(grep -c '^tailscale status' "${CALLS}")" -eq 3 ]
  grep -q -- 'tailscale set --advertise-routes=172.16.5.0/24' "${CALLS}"
}

@test "ts-advertise-routes gives up without an address" {
  stub ip
  stub tailscale
  TS_ROUTE_TRIES=3 TS_ROUTE_DELAY=0 run "${FILES}/ts-advertise-routes.sh"
  [ "${status}" -eq 1 ]
  run ! grep -q -- 'tailscale set' "${CALLS}"
}
