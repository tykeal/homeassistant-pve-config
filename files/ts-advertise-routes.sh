#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
# SPDX-License-Identifier: Apache-2.0

# Advertise this container's connected IPv4 subnet(s) to Tailscale.
#
# Runs at every boot (ts-advertise-routes.service). The host ships to sites
# whose LAN differs from the one it was set up on, so the routes are derived
# from eth0 each time rather than fixed at install. `tailscale set` is
# harmless to repeat. A new subnet still needs approval in the Tailscale
# admin console unless an autoApprovers rule covers it.

set -euo pipefail

IFACE="${1:-eth0}"
TRIES="${TS_ROUTE_TRIES:-60}"
DELAY="${TS_ROUTE_DELAY:-2}"

# Connected subnets of the interface, comma-separated (e.g. 192.168.1.0/24).
connected_subnets() {
  ip -4 route show dev "$1" proto kernel scope link | awk '{print $1}' | paste -sd, -
}

routes=""
for ((i = 1; i <= TRIES; i++)); do
  routes="$(connected_subnets "${IFACE}" 2>/dev/null || true)"
  if [[ -n "${routes}" ]] && tailscale status >/dev/null 2>&1; then
    break
  fi
  routes=""
  sleep "${DELAY}"
done

if [[ -z "${routes}" ]]; then
  echo "ts-advertise-routes: no IPv4 subnet on ${IFACE} or tailscale not up; nothing advertised" >&2
  exit 1
fi

tailscale set --advertise-routes="${routes}"
echo "ts-advertise-routes: advertising ${routes}"
