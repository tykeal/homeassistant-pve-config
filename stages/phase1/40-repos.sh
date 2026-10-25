#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

# shellcheck source=lib/stage.sh
source "${PVE_CONFIG_LIB_DIR:?PVE_CONFIG_LIB_DIR is unset}/stage.sh"

SYSROOT=$(sysroot)
SOURCES_DIR="${SYSROOT}/etc/apt/sources.list.d"

if [[ ${PVE_NO_SUBSCRIPTION:-yes} != yes ]]; then
  log_info 'PVE_NO_SUBSCRIPTION is not yes; leaving the apt sources alone'
  exit 0
fi

# The suite is read off the running system rather than written down. A
# hardcoded release name keeps pointing at the old distribution after an
# upgrade, and apt will happily install from it.
suite=${PVE_SUITE:-}
if [[ -z ${suite} ]]; then
  suite=$(detect_debian_suite) ||
    die 'Unable to determine the Debian suite; set PVE_SUITE.'
fi

changed=0

# _slurp assigns by name, which shellcheck cannot see, so these are declared
# here rather than appearing out of nowhere further down.
ceph_body=''
stale_body=''

# The enterprise source needs a subscription. Left in place it makes every
# `apt-get update` fail with a 401, which is the single most common
# complaint about a fresh Proxmox install.
source_state=unchanged
for stale in pve-enterprise.sources pve-enterprise.list; do
  state_of source_state apt_source_remove "${SOURCES_DIR}/${stale}"
  if [[ ${source_state} == changed ]]; then
    changed=1
  fi
done

proxmox_source="Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: ${suite}
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
"

ensure_dir "${SOURCES_DIR}" 0755 >/dev/null
state_of source_state apt_source_install "${SOURCES_DIR}/proxmox.sources" "${proxmox_source}"
if [[ ${source_state} == changed ]]; then
  changed=1
fi

# Ceph is only present when the host was installed with it. Its enterprise
# component needs a subscription and fails `apt-get update` the same way, so
# both the URI and the component move to the public ones while the Ceph
# release and suite the file already carries are left alone.
ceph_to_no_subscription() {
  local body=$1
  body=${body//enterprise.proxmox.com/download.proxmox.com}
  body=${body//Components: enterprise/Components: no-subscription}
  body=${body//ceph-enterprise/ceph-no-subscription}
  printf '%s' "${body}"
}

ceph_source="${SOURCES_DIR}/ceph.sources"
if [[ -f ${ceph_source} ]]; then
  _slurp ceph_body "${ceph_source}"
  if [[ ${ceph_body} == *enterprise* ]]; then
    ceph_body=$(ceph_to_no_subscription "${ceph_body}")
    state_of source_state apt_source_install "${ceph_source}" "${ceph_body}"
    if [[ ${source_state} == changed ]]; then
      changed=1
    fi
  fi
fi

# A one-line ceph.list is the older form of the same thing. Removing it
# without putting anything back would leave an installed Ceph with no
# repository at all, so it is migrated to a deb822 source first.
for stale in ceph.list ceph-enterprise.list; do
  stale_path="${SOURCES_DIR}/${stale}"
  [[ -f ${stale_path} ]] || continue
  _slurp stale_body "${stale_path}"
  # Only an enterprise list is in the way. A no-subscription one the
  # operator added by hand is left exactly where it is.
  [[ ${stale_body} == *enterprise* ]] || continue

  if [[ ! -f ${ceph_source} ]]; then
    migrated=''
    while IFS= read -r entry || [[ -n ${entry} ]]; do
      entry=${entry#"${entry%%[![:space:]]*}"}
      [[ ${entry} == deb[[:space:]]* ]] || continue

      # A one-line entry may carry bracketed options between `deb` and the
      # URI. Splitting on whitespace without lifting them out first turns
      # the options into the URI and the URI into the suite, which is how a
      # migration ends up writing a source that points nowhere.
      options=''
      if [[ ${entry} == *'['*']'* ]]; then
        options=${entry#*[}
        options=${options%%]*}
        entry="${entry%%[*}${entry#*]}"
      fi
      read -r -a entry_fields <<<"${entry}"
      uri=${entry_fields[1]:-}
      ceph_suite=${entry_fields[2]:-}
      [[ -n ${uri} && -n ${ceph_suite} ]] || continue
      uri=$(ceph_to_no_subscription "${uri}")

      signed_by='/usr/share/keyrings/proxmox-archive-keyring.gpg'
      for option in ${options}; do
        [[ ${option} == signed-by=* ]] && signed_by=${option#signed-by=}
      done

      migrated="Types: deb
URIs: ${uri}
Suites: ${ceph_suite}
Components: no-subscription
Signed-By: ${signed_by}
"
      break
    done <<<"${stale_body}"
    if [[ -z ${migrated} ]]; then
      die "Unable to read a usable entry out of ${stale_path}; leaving it in place. Replace it with a no-subscription Ceph source by hand."
    fi
    log_info "migrating ${stale} to ${ceph_source}"
    state_of source_state apt_source_install "${ceph_source}" "${migrated}"
    if [[ ${source_state} == changed ]]; then
      changed=1
    fi
  fi

  state_of source_state apt_source_remove "${stale_path}"
  if [[ ${source_state} == changed ]]; then
    changed=1
  fi
done

# A refresh that failed leaves the stage pending, but the next run finds
# identical source files and would skip the refresh entirely -- marking the
# stage done without ever having downloaded an index. The marker outlives
# the failure so the retry still refreshes.
refresh_marker="${SYSROOT}/var/lib/pve-config/apt-refresh-pending"
if [[ -f ${refresh_marker} ]]; then
  changed=1
fi

if [[ ${changed} -eq 1 ]]; then
  ensure_dir "${SYSROOT}/var/lib/pve-config" 0755 >/dev/null
  write_file "${refresh_marker}" "pending"$'\n' 0644 >/dev/null
  apt_update
  remove_path "${refresh_marker}" >/dev/null
else
  log_info 'apt sources already point at pve-no-subscription'
fi
