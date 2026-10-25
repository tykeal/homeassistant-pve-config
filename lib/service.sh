#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
# SPDX-License-Identifier: Apache-2.0

# systemd convergence. Every query goes through systemctl so the answer
# reflects the running manager rather than a guess made from unit files.

service_is_active() {
  systemctl is-active --quiet -- "$1" 2>/dev/null
}

service_is_enabled() {
  systemctl is-enabled --quiet -- "$1" 2>/dev/null
}

# Reloading the manager is expensive and a stage may touch several units, so
# the request collapses to one call per stage process. A stage still asks
# only when it actually wrote a unit file.
systemd_daemon_reload() {
  if [[ ${_SYSTEMD_RELOADED:-0} == 1 ]]; then
    printf 'unchanged\n'
    return 0
  fi
  run_cmd systemctl daemon-reload || die 'Unable to reload the systemd manager'
  _SYSTEMD_RELOADED=1
  printf 'changed\n'
}

service_enable() {
  local unit=$1
  if service_is_enabled "${unit}"; then
    printf 'unchanged\n'
    return 0
  fi
  run_cmd systemctl enable -- "${unit}" || die "Unable to enable ${unit}"
  printf 'changed\n'
}

service_disable() {
  local unit=$1
  if ! service_is_enabled "${unit}"; then
    printf 'unchanged\n'
    return 0
  fi
  run_cmd systemctl disable -- "${unit}" || die "Unable to disable ${unit}"
  printf 'changed\n'
}

service_start() {
  local unit=$1
  if service_is_active "${unit}"; then
    printf 'unchanged\n'
    return 0
  fi
  run_cmd systemctl start -- "${unit}" || die "Unable to start ${unit}"
  printf 'changed\n'
}

# Starts a stopped unit rather than restarting it, which is the difference
# between bringing a host up and bouncing a service that is already serving.
# Callers reach for this only when they changed something the unit reads.
service_restart() {
  local unit=$1
  if ! service_is_active "${unit}"; then
    service_start "${unit}"
    return 0
  fi
  run_cmd systemctl restart -- "${unit}" || die "Unable to restart ${unit}"
  printf 'changed\n'
}

# A unit that is not running has nothing to reload, so asking it to is both
# pointless and, for sshd on a host reached over ssh, the wrong instinct.
service_reload() {
  local unit=$1
  if ! service_is_active "${unit}"; then
    printf 'unchanged\n'
    return 0
  fi
  run_cmd systemctl reload -- "${unit}" || die "Unable to reload ${unit}"
  printf 'changed\n'
}
