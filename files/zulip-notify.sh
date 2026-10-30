#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
# SPDX-License-Identifier: Apache-2.0

# Post a boot or shutdown message for this host to a Zulip stream.
#
# Credentials live in /etc/zulip-notify.env (mode 0600). While any of them
# is blank this script does nothing and exits 0. To turn notifications on:
#
#   1. Fill in ZULIP_URL, ZULIP_BOT_EMAIL, ZULIP_API_KEY and ZULIP_STREAM
#      in /etc/zulip-notify.env
#   2. systemctl enable zulip-boot-notify.service
#      systemctl enable --now zulip-shutdown-notify.service
#   3. Test: /usr/local/bin/zulip-notify.sh boot

set -euo pipefail

ENV_FILE="${ZULIP_NOTIFY_ENV:-/etc/zulip-notify.env}"

if [[ -r "${ENV_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${ENV_FILE}"
fi

if [[ -z "${ZULIP_URL:-}" || -z "${ZULIP_BOT_EMAIL:-}" ||
  -z "${ZULIP_API_KEY:-}" || -z "${ZULIP_STREAM:-}" ]]; then
  exit 0
fi

host="$(hostname -f)"
timestamp="$(date '+%Y-%m-%d %H:%M:%S %Z')"

case "${1:-}" in
  boot) content=":white_check_mark: **${host}** is up at ${timestamp}" ;;
  shutdown) content=":warning: **${host}** is shutting down at ${timestamp}" ;;
  *)
    echo "usage: $0 boot|shutdown" >&2
    exit 2
    ;;
esac

curl -s -m 10 -X POST \
  -u "${ZULIP_BOT_EMAIL}:${ZULIP_API_KEY}" \
  --data-urlencode "type=stream" \
  --data-urlencode "to=${ZULIP_STREAM}" \
  --data-urlencode "topic=${host}" \
  --data-urlencode "content=${content}" \
  "${ZULIP_URL%/}/api/v1/messages" >/dev/null 2>&1 || true

exit 0
