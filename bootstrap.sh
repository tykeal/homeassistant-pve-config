#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
# SPDX-License-Identifier: Apache-2.0

# Single entry point for a fresh Proxmox VE host:
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/tykeal/homeassistant-pve-config/main/bootstrap.sh)"
#
# Installs the toolkit under /root/pve-config and stops. Running the
# configuration is a separate, deliberate act.

set -euo pipefail

PVE_CONFIG_REPO=${PVE_CONFIG_REPO:-tykeal/homeassistant-pve-config}
PVE_CONFIG_REF=${PVE_CONFIG_REF:-main}
PVE_CONFIG_DIR=${PVE_CONFIG_DIR:-/root/pve-config}

# Only the code is replaced on an upgrade. Anything the operator or an
# earlier run produced is carried across untouched.
BOOTSTRAP_CODE_PATHS=(pve-config.sh bootstrap.sh lib stages examples)
BOOTSTRAP_REQUIRED_PATHS=(pve-config.sh bootstrap.sh lib/common.sh lib/config.sh lib/detect.sh lib/state.sh lib/schema.sh)
BOOTSTRAP_PRESERVE_PATHS=(pve-config.conf secrets.env state)

bootstrap_log() { printf '[bootstrap] %s\n' "$*" >&2; }
bootstrap_die() {
  printf '[bootstrap] ERROR: %s\n' "$*" >&2
  return 1
}

# A ref may contain a slash (feat/x), which codeload needs percent encoded
# or it reads as another path segment.
bootstrap_encode_ref() {
  local ref=$1 out='' i char
  for ((i = 0; i < ${#ref}; i++)); do
    char=${ref:i:1}
    case ${char} in
      [A-Za-z0-9._~-]) out+=${char} ;;
      *) out+=$(printf '%%%02X' "'${char}") ;;
    esac
  done
  printf '%s\n' "${out}"
}

bootstrap_archive_url() {
  printf 'https://codeload.github.com/%s/tar.gz/%s\n' \
    "${PVE_CONFIG_REPO}" "$(bootstrap_encode_ref "${PVE_CONFIG_REF}")"
}

# PVE_CONFIG_BOOTSTRAP_ARCHIVE lets the tests, and an air-gapped install,
# supply the tarball instead of fetching it.
bootstrap_fetch() {
  local dest=$1
  if [[ -n ${PVE_CONFIG_BOOTSTRAP_ARCHIVE:-} ]]; then
    if ! cp -- "${PVE_CONFIG_BOOTSTRAP_ARCHIVE}" "${dest}"; then
      bootstrap_die "Unable to read ${PVE_CONFIG_BOOTSTRAP_ARCHIVE}"
      return 1
    fi
    return 0
  fi
  local url
  url=$(bootstrap_archive_url)
  bootstrap_log "fetching ${PVE_CONFIG_REPO} at ${PVE_CONFIG_REF}"
  if ! command -v curl >/dev/null 2>&1; then
    bootstrap_die 'curl is required.'
    return 1
  fi
  if ! curl -fsSL -o "${dest}" "${url}"; then
    bootstrap_die "Unable to download ${url}"
    return 1
  fi
}

# Refuses an archive that could write outside the extraction root, and any
# symlink at all: nothing in this repository needs one, so a link in the
# tarball means the tarball is not the one it claims to be.
bootstrap_verify_archive() {
  local archive=$1 entry type

  while IFS= read -r entry; do
    [[ -n ${entry} ]] || continue
    case ${entry} in
      /* | ../* | *'/../'* | *'/..')
        bootstrap_die "Archive entry escapes the extraction root: ${entry}"
        return 1
        ;;
    esac
  done < <(tar -tzf "${archive}")

  # The entry name is unreliable on a link line ("name -> target"), so the
  # type is read on its own.
  while IFS= read -r type; do
    case ${type} in
      l | h)
        bootstrap_die 'Archive contains a link entry; refusing to install.'
        return 1
        ;;
    esac
  done < <(tar -tzvf "${archive}" | cut -c1)
}

bootstrap_stage() {
  local archive=$1 staging=$2 item
  mkdir -p -- "${staging}/src" "${staging}/new"
  if ! tar -xzf "${archive}" -C "${staging}/src" --strip-components=1; then
    bootstrap_die 'Unable to unpack the downloaded archive.'
    return 1
  fi

  # A truncated or unexpected archive must be caught before anything is
  # swapped, not discovered as a missing file after the fact.
  for item in "${BOOTSTRAP_REQUIRED_PATHS[@]}"; do
    if [[ ! -e ${staging}/src/${item} ]]; then
      bootstrap_die "Archive is missing ${item}; refusing to install."
      return 1
    fi
  done

  for item in "${BOOTSTRAP_CODE_PATHS[@]}"; do
    [[ -e ${staging}/src/${item} ]] || continue
    mkdir -p -- "$(dirname -- "${staging}/new/${item}")"
    cp -a -- "${staging}/src/${item}" "${staging}/new/${item}"
  done

  for item in "${BOOTSTRAP_PRESERVE_PATHS[@]}"; do
    [[ -e ${PVE_CONFIG_DIR}/${item} ]] || continue
    cp -a -- "${PVE_CONFIG_DIR}/${item}" "${staging}/new/${item}"
  done

  chmod +x "${staging}/new/pve-config.sh" "${staging}/new/bootstrap.sh"
  if [[ -d ${staging}/new/stages ]]; then
    find "${staging}/new/stages" -type f -name '*.sh' -exec chmod +x {} +
  fi
  mkdir -p -- "${staging}/new/state"
}

# Swaps the assembled tree in by rename. The previous install is moved
# aside rather than deleted so a failed rename can be undone.
bootstrap_swap() {
  local staging=$1 backup="${PVE_CONFIG_DIR}.old" backed_up=0
  rm -rf -- "${backup}"
  if [[ -e ${PVE_CONFIG_DIR} ]]; then
    if ! mv -- "${PVE_CONFIG_DIR}" "${backup}"; then
      bootstrap_die 'Unable to move the existing install aside.'
      return 1
    fi
    backed_up=1
  fi
  if ! mv -- "${staging}/new" "${PVE_CONFIG_DIR}"; then
    # Every one of these messages has to match what is actually on disk.
    # Claiming a rollback that did not happen, or one that had nothing to
    # roll back to, sends the operator looking for the wrong thing.
    if [[ ${backed_up} == 0 ]]; then
      bootstrap_die 'Unable to install the new tree; there was no previous installation, so nothing is installed.'
      return 1
    fi
    if ! mv -- "${backup}" "${PVE_CONFIG_DIR}"; then
      bootstrap_die "Unable to install the new tree and unable to restore the previous one. Manual recovery required: the previous install is at ${backup}, move it back to ${PVE_CONFIG_DIR}."
      return 1
    fi
    bootstrap_die 'Unable to install the new tree; the previous install was restored.'
    return 1
  fi
  # Only once the new tree is confirmed in place does the old one go.
  rm -rf -- "${backup}"
}

bootstrap_install() {
  if ! command -v tar >/dev/null 2>&1; then
    bootstrap_die 'tar is required.'
    return 1
  fi

  # Staging sits beside the install directory so the final move is a rename
  # on the same filesystem.
  local staging="${PVE_CONFIG_DIR}.bootstrap"
  rm -rf -- "${staging}"
  mkdir -p -- "${staging}"

  if ! {
    bootstrap_fetch "${staging}/source.tar.gz" &&
      bootstrap_verify_archive "${staging}/source.tar.gz" &&
      bootstrap_stage "${staging}/source.tar.gz" "${staging}" &&
      bootstrap_swap "${staging}"
  }; then
    rm -rf -- "${staging}"
    return 1
  fi

  rm -rf -- "${staging}"
  bootstrap_log "installed to ${PVE_CONFIG_DIR}"
}

bootstrap_next_steps() {
  cat <<EOF

Next steps:

  cd ${PVE_CONFIG_DIR}
  cp examples/pve-config.conf.example pve-config.conf   # optional, the
  cp examples/secrets.env.example secrets.env           # driver prompts too
  chmod 600 secrets.env
  ./pve-config.sh --list
  ./pve-config.sh --dry-run
  ./pve-config.sh

EOF
}

main() {
  if [[ ${EUID} -ne 0 ]]; then
    bootstrap_die 'This must be run as root on the Proxmox VE host.'
    return 1
  fi
  bootstrap_install || return 1
  bootstrap_next_steps
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
