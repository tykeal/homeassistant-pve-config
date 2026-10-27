#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
# SPDX-License-Identifier: Apache-2.0

# Stands in for community-scripts ct/debian.sh at the pinned commit.
#
# It is deliberately unforgiving. The real script hands off to
# core/build.func, which puts a whiptail settings menu on the screen when
# `mode` is unset on a create, and a menu of storages on the screen when
# the defaults file does not name them. Neither can be answered by an
# unattended run, so both are failures here rather than quiet successes:
# a fixture that built a container regardless would let the toolkit drop
# `mode=default` and never be told.
set -u

fail() {
  printf 'ct/debian.sh fixture: %s\n' "$1" >&2
  exit 1
}

# The engine is fetched from community-scripts/core, and the pin is the
# whole reason this toolkit fetches the way it does. An unpinned run would
# arrive here without it.
[[ -n ${COMMUNITY_SCRIPTS_CORE_URL:-} ]] ||
  fail 'COMMUNITY_SCRIPTS_CORE_URL is unset, so the engine would be fetched from the tip of main'

case ${mode:-} in
  1 | default | DEFAULT) ;;
  '') fail 'no mode was set: the settings menu would be waiting for a terminal' ;;
  *) fail "unknown mode '${mode}'" ;;
esac

[[ -n ${var_ctid:-} ]] || fail 'var_ctid is unset, so the engine would allocate an id of its own'
[[ -n ${var_hostname:-} ]] || fail 'var_hostname is unset'
[[ -n ${var_template_storage:-} ]] ||
  fail 'var_template_storage is unset: the storage menu would be waiting for a terminal'
[[ -n ${var_container_storage:-} ]] ||
  fail 'var_container_storage is unset: the storage menu would be waiting for a terminal'
[[ ${var_unprivileged:-} == 1 ]] || fail 'the container must be unprivileged'

# Issue #9 asks for no IPv6 on this container, and build.func puts an
# addressing menu on the screen when it is not told. A fixture that
# accepted silence would let the toolkit stop setting it and never say so.
case ${var_ipv6_method:-} in
  none) ;;
  '') fail 'var_ipv6_method is unset: the IPv6 menu would be waiting for a terminal' ;;
  *) fail "var_ipv6_method is '${var_ipv6_method}', but this container is built without IPv6" ;;
esac

# build.func reads its answers out of default.vars before it asks
# anything, and puts a storage menu on the screen when the file is not
# there. A fixture that built regardless would let the toolkit stop
# writing it and never be told -- and would hide a file put back too
# early, which is the same bug seen from the other side.
vars_file="${PVE_CONFIG_ROOT:-}/usr/local/community-scripts/default.vars"
[[ -f ${vars_file} ]] ||
  fail 'no default.vars: the storage menu would be waiting for a terminal'
printf 'ct/debian.sh default.vars %s\n' "$(tr '\n' ' ' <"${vars_file}")" \
  >>"${PVE_CONFIG_MOCK_LOG:-/dev/null}"

# The environment the builder was handed, so a test can prove which of the
# deployment's secrets reached it. The builder runs maintainer scripts of
# its own, so this is the boundary that matters.
if [[ -n ${PVE_CONFIG_MOCK_BUILDER_ENV:-} ]]; then
  env >>"${PVE_CONFIG_MOCK_BUILDER_ENV}"
fi

# Recorded so a test can read back what the toolkit actually set rather
# than only that the build succeeded.
printf 'ct/debian.sh mode=%s var_ctid=%s var_hostname=%s var_tun=%s var_unprivileged=%s var_nesting=%s var_ram=%s var_cpu=%s var_disk=%s var_template_storage=%s var_container_storage=%s var_ipv6_method=%s\n' \
  "${mode}" "${var_ctid}" "${var_hostname}" "${var_tun:-no}" \
  "${var_unprivileged}" "${var_nesting:-0}" "${var_ram:-}" "${var_cpu:-}" \
  "${var_disk:-}" "${var_template_storage}" "${var_container_storage}" \
  "${var_ipv6_method}" \
  >>"${PVE_CONFIG_MOCK_LOG:-/dev/null}"

features=''
[[ ${var_nesting:-0} == 1 ]] && features='nesting=1'

pct create "${var_ctid}" \
  "${var_template_storage}:vztmpl/debian-13-standard_13.0-1_amd64.tar.zst" \
  -hostname "${var_hostname}" \
  -memory "${var_ram:-512}" \
  -cores "${var_cpu:-1}" \
  -rootfs "${var_container_storage}:${var_disk:-2}" \
  -unprivileged "${var_unprivileged}" \
  -features "${features}" \
  -net0 "name=eth0,bridge=${var_brg:-vmbr0},ip=${var_net:-dhcp}" \
  -ostype debian || fail 'pct create failed'

# configure_additional_devices in pve/backend.func, which writes these two
# lines before the container is ever started.
if [[ ${var_tun:-no} == yes ]]; then
  conf="${PVE_CONFIG_ROOT:-}/etc/pve/lxc/${var_ctid}.conf"
  printf '%s\n' 'lxc.cgroup2.devices.allow: c 10:200 rwm' >>"${conf}"
  printf '%s\n' 'lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file' >>"${conf}"
fi

pct start "${var_ctid}" || fail 'pct start failed'
