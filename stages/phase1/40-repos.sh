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
for stale in pve-enterprise.sources pve-enterprise.list; do
  if [[ $(apt_source_remove "${SOURCES_DIR}/${stale}") == changed ]]; then
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
if [[ $(apt_source_install "${SOURCES_DIR}/proxmox.sources" "${proxmox_source}") == changed ]]; then
  changed=1
fi

# Ceph is only present when the host was installed with it. Its enterprise
# component fails the same way, so the file is converged in place rather
# than removed: the URIs and suite it already carries are the right ones.
ceph_source="${SOURCES_DIR}/ceph.sources"
if [[ -f ${ceph_source} ]]; then
  _slurp ceph_body "${ceph_source}"
  if [[ ${ceph_body} == *enterprise* ]]; then
    ceph_body=${ceph_body//Components: enterprise/Components: no-subscription}
    ceph_body=${ceph_body//ceph-enterprise/ceph-no-subscription}
    if [[ $(apt_source_install "${ceph_source}" "${ceph_body}") == changed ]]; then
      changed=1
    fi
  fi
fi

for stale in ceph.list ceph-enterprise.list; do
  if [[ -f "${SOURCES_DIR}/${stale}" ]]; then
    _slurp stale_body "${SOURCES_DIR}/${stale}"
    # Only an enterprise list is in the way. A no-subscription one the
    # operator added by hand is left exactly where it is.
    if [[ ${stale_body} == *enterprise* ]] &&
      [[ $(apt_source_remove "${SOURCES_DIR}/${stale}") == changed ]]; then
      changed=1
    fi
  fi
done

if [[ ${changed} -eq 1 ]]; then
  apt_update
else
  log_info 'apt sources already point at pve-no-subscription'
fi
