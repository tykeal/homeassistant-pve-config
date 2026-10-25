#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

# shellcheck source=lib/stage.sh
source "${PVE_CONFIG_LIB_DIR:?PVE_CONFIG_LIB_DIR is unset}/stage.sh"

SYSROOT=$(sysroot)

# The only optional stage in phase 1. A deployment with no Zulip is the
# normal case, so it says so once and leaves.
if [[ ${PVE_ZULIP_ENABLED:-no} != yes ]]; then
  log_info 'Zulip notifications are not enabled; skipping'
  exit 0
fi

# Tracing stays off from the first dereference of a secret until the
# credentials have been written. Redaction covers this toolkit's own log
# lines; it does nothing about `set -x`, which would print the bot key
# verbatim the moment the presence check below expands it.
xtrace_suspend

# Enabled but incomplete is a configuration error, not a skip: letting the
# driver mark the stage done would record a notifier that was never
# installed. Only a deployment that has opted out gets to pass quietly.
for key in PVE_ZULIP_SITE PVE_ZULIP_BOT_EMAIL PVE_ZULIP_BOT_API_KEY; do
  if [[ -z ${!key:-} ]]; then
    die "Zulip is enabled but ${key} is unset. Add it to secrets.env, or set PVE_ZULIP_ENABLED=no."
  fi
done

# Registered even when the values came from the environment rather than the
# secrets file, so nothing below can print one.
secrets_require PVE_ZULIP_SITE PVE_ZULIP_BOT_EMAIL PVE_ZULIP_BOT_API_KEY

stream=${PVE_ZULIP_STREAM:-infrastructure}

# The credentials go in a 0600 environment file, not in the notifier. The
# notifier itself has to be executable by systemd and therefore readable,
# and a bot API key in a 0755 script is a credential published to every
# account on the host.
#
# Values are single-quoted, because the notifier sources this file: an
# unquoted stream name with a space in it would run its second word, and
# one with a metacharacter would be evaluated.
ensure_dir "${SYSROOT}/etc/pve-config" 0700 >/dev/null
write_file "${SYSROOT}/etc/pve-config/zulip.env" "\
PVE_ZULIP_SITE=$(_config_quote "${PVE_ZULIP_SITE}")
PVE_ZULIP_BOT_EMAIL=$(_config_quote "${PVE_ZULIP_BOT_EMAIL}")
PVE_ZULIP_BOT_API_KEY=$(_config_quote "${PVE_ZULIP_BOT_API_KEY}")
PVE_ZULIP_STREAM=$(_config_quote "${stream}")
PVE_ZULIP_TOPIC=$(_config_quote "${PVE_ZULIP_TOPIC:-}")
" 0600 >/dev/null

xtrace_resume

read -r -d '' notifier <<'NOTIFY' || true
#!/bin/sh
# Managed by pve-config. Announces this host coming up and going down.
set -eu

ENV_FILE=/etc/pve-config/zulip.env
[ -r "$ENV_FILE" ] || exit 0
# shellcheck source=/dev/null
. "$ENV_FILE"

[ -n "${PVE_ZULIP_SITE:-}" ] || exit 0
[ -n "${PVE_ZULIP_BOT_EMAIL:-}" ] || exit 0
[ -n "${PVE_ZULIP_BOT_API_KEY:-}" ] || exit 0

action=${1:-}
host=$(hostname -f 2>/dev/null || hostname)
stamp=$(date '+%Y-%m-%d %H:%M:%S %Z')
topic=${PVE_ZULIP_TOPIC:-}
[ -n "$topic" ] || topic=$host

case "$action" in
  boot) content=":white_check_mark: **${host}** is up at ${stamp}" ;;
  shutdown) content=":warning: **${host}** is shutting down at ${stamp}" ;;
  *)
    echo "usage: $0 boot|shutdown" >&2
    exit 2
    ;;
esac

# The credentials go in a netrc-style file on stdin so they never appear in
# the process table, where every user on the host can read them.
printf 'user = "%s:%s"\n' "$PVE_ZULIP_BOT_EMAIL" "$PVE_ZULIP_BOT_API_KEY" |
  curl -s -m 10 -X POST --config - \
    --data-urlencode 'type=stream' \
    --data-urlencode "to=${PVE_ZULIP_STREAM}" \
    --data-urlencode "topic=${topic}" \
    --data-urlencode "content=${content}" \
    "${PVE_ZULIP_SITE}/api/v1/messages" >/dev/null 2>&1 || true

exit 0
NOTIFY
notifier+=$'\n'

ensure_dir "${SYSROOT}/usr/local/bin" 0755 >/dev/null
write_file "${SYSROOT}/usr/local/bin/zulip-notify.sh" "${notifier}" 0755 >/dev/null

units_dir="${SYSROOT}/etc/systemd/system"
ensure_dir "${units_dir}" 0755 >/dev/null

read -r -d '' boot_unit <<'UNIT' || true
[Unit]
Description=Send a Zulip boot notification
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/zulip-notify.sh boot

[Install]
WantedBy=multi-user.target
UNIT
boot_unit+=$'\n'

read -r -d '' shutdown_unit <<'UNIT' || true
[Unit]
Description=Send a Zulip shutdown notification
DefaultDependencies=no
Before=shutdown.target
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/zulip-notify.sh shutdown
TimeoutStartSec=15

[Install]
WantedBy=shutdown.target
UNIT
shutdown_unit+=$'\n'

units_changed=0
if [[ $(write_file "${units_dir}/zulip-boot-notify.service" "${boot_unit}" 0644) == changed ]]; then
  units_changed=1
fi
if [[ $(write_file "${units_dir}/zulip-shutdown-notify.service" "${shutdown_unit}" 0644) == changed ]]; then
  units_changed=1
fi

if [[ ${units_changed} -eq 1 ]]; then
  systemd_daemon_reload >/dev/null
fi

service_enable zulip-boot-notify.service >/dev/null
service_enable zulip-shutdown-notify.service >/dev/null

log_info "Zulip boot and shutdown notices enabled for the ${stream} stream"
