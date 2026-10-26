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
# Empty by default: the installer now takes the latest published release.
# A ref install bypasses every checksum the project publishes, so asking
# for one has to be an explicit act rather than the fallback.
PVE_CONFIG_REF=${PVE_CONFIG_REF:-}
PVE_CONFIG_RELEASE=${PVE_CONFIG_RELEASE:-}
# An empty pin and an absent pin have to be told apart. A pin is how an
# operator asserts trust, so PVE_CONFIG_SHA256=$(cmd) where cmd failed must
# stop the install rather than quietly install nothing-was-checked.
if [[ -n ${PVE_CONFIG_SHA256+set} ]]; then
  BOOTSTRAP_PIN_SUPPLIED=1
else
  BOOTSTRAP_PIN_SUPPLIED=0
fi
PVE_CONFIG_SHA256=${PVE_CONFIG_SHA256:-}
PVE_CONFIG_ALLOW_UNVERIFIED=${PVE_CONFIG_ALLOW_UNVERIFIED:-}
PVE_CONFIG_DIR=${PVE_CONFIG_DIR:-/root/pve-config}

# Set once the source of the tarball has been settled, and read again at
# the end so the warning survives a long scroll of install output.
BOOTSTRAP_UNVERIFIED=0

# Only the code is replaced on an upgrade. Anything the operator or an
# earlier run produced is carried across untouched.
BOOTSTRAP_CODE_PATHS=(pve-config.sh bootstrap.sh lib stages examples)
# Every library the driver sources unconditionally. A tree missing one of
# these installs cleanly and then fails on the first run, which is what the
# guard exists to catch before the swap.
BOOTSTRAP_REQUIRED_PATHS=(pve-config.sh bootstrap.sh lib/common.sh lib/version.sh lib/config.sh lib/detect.sh lib/state.sh lib/schema.sh)
# keys/ is an operator input the example config points at, so an upgrade
# must carry it across like any other generated file.
BOOTSTRAP_PRESERVE_PATHS=(pve-config.conf secrets.env state keys)

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

bootstrap_is_true() {
  case ${1:-} in
    1 | y | Y | yes | YES | true | TRUE) return 0 ;;
  esac
  return 1
}

# A tag arrives either from the operator or from a redirect GitHub sent
# back, and it goes straight into a URL and a filename. Anything outside
# this set is refused rather than escaped, because a tag that needs
# escaping is not one this project ever published.
bootstrap_valid_tag() {
  local tag=$1
  [[ ${tag} =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,99}$ ]] || return 1
  [[ ${tag} != *..* ]] || return 1
}

# Resolves "latest" by following the redirect that /releases/latest sends,
# whose effective URL ends in the tag. The REST API would answer the same
# question, but it costs one of the sixty unauthenticated calls an hour a
# whole NAT shares, and it would need a JSON parser Proxmox does not ship.
bootstrap_latest_tag() {
  local url effective prefix tag
  url="https://github.com/${PVE_CONFIG_REPO}/releases/latest"
  prefix="https://github.com/${PVE_CONFIG_REPO}/releases/tag/"
  if ! effective=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "${url}"); then
    bootstrap_die "Unable to resolve the latest release of ${PVE_CONFIG_REPO}. Set PVE_CONFIG_RELEASE to a published tag, or check network access to github.com."
    return 1
  fi
  # A repository with no published release lands on the releases index
  # instead, which names no tag.
  if [[ ${effective%/} == "https://github.com/${PVE_CONFIG_REPO}/releases" ]]; then
    bootstrap_die "${PVE_CONFIG_REPO} has no published release to install. Set PVE_CONFIG_REF with PVE_CONFIG_ALLOW_UNVERIFIED=1 to install an unverified ref instead."
    return 1
  fi
  # The whole prefix has to match, not just the /releases/tag/ segment:
  # any host can serve a path shaped like one, and a redirect somewhere
  # else must not get to choose which release this host installs.
  if [[ ${effective} != "${prefix}"* ]]; then
    bootstrap_die "The latest-release lookup for ${PVE_CONFIG_REPO} ended somewhere unexpected: ${effective}. Refusing to install."
    return 1
  fi
  tag=${effective#"${prefix}"}
  tag=${tag%%/*}
  tag=${tag%%\?*}
  if ! bootstrap_valid_tag "${tag}"; then
    bootstrap_die "Refusing to use the release tag github.com returned: ${tag}"
    return 1
  fi
  printf '%s\n' "${tag}"
}

# sha256sum -c checks whatever its input names, and it is happy to check a
# file that is not the one just downloaded: a record naming /etc/hostname
# verifies /etc/hostname and reports success. So the shape of the published
# checksum is settled first, and only a file holding exactly one record
# naming exactly the expected asset, with no path of its own, is allowed
# near sha256sum.
bootstrap_check_checksum_file() {
  local file=$1 asset=$2 record rest
  local -a records=()

  if [[ ! -s ${file} ]]; then
    bootstrap_die "The checksum asset ${asset}.sha256 is empty; it is malformed, not a sign the download went wrong. Refusing to install."
    return 1
  fi
  if ! mapfile -t records <"${file}"; then
    bootstrap_die "Unable to read the checksum asset ${asset}.sha256."
    return 1
  fi
  if [[ ${#records[@]} -ne 1 ]]; then
    bootstrap_die "The checksum asset ${asset}.sha256 holds ${#records[@]} records where it must hold one; it is malformed. Refusing to install."
    return 1
  fi

  record=${records[0]}
  rest=${record:64}
  # sha256sum writes the digest, a space, a mode marker, then the name.
  if [[ ! ${record:0:64} =~ ^[0-9a-fA-F]{64}$ ]] ||
    [[ ${rest:0:1} != ' ' ]] ||
    [[ ${rest:1:1} != ' ' && ${rest:1:1} != '*' ]] ||
    [[ ${rest:2} != "${asset}" ]]; then
    bootstrap_die "The checksum asset ${asset}.sha256 does not name ${asset} in the form sha256sum writes; it is malformed. Refusing to install."
    return 1
  fi
}

# Compares an archive against a hex digest. Used for the operator pin; the
# release asset goes through sha256sum -c instead, so the published file is
# read as published rather than reformatted on the way in.
bootstrap_verify_sha256() {
  local archive=$1 want=$2 got
  if ! command -v sha256sum >/dev/null 2>&1; then
    bootstrap_die 'sha256sum is required to verify the download.'
    return 1
  fi
  if ! got=$(sha256sum -- "${archive}"); then
    bootstrap_die 'Unable to checksum the downloaded archive.'
    return 1
  fi
  got=${got%% *}
  if [[ ${got,,} != "${want,,}" ]]; then
    bootstrap_die "Checksum mismatch: expected ${want,,}, got ${got,,}. Refusing to install."
    return 1
  fi
}

# Downloads a published release and proves the bytes are the ones the
# release carries. The checksum comes from the same origin as the tarball,
# so on its own it only rules out corruption and truncation. It is worth
# more than that here because immutable releases lock a published asset:
# the pair cannot be swapped after the fact. It is still not a signature,
# and an operator who wants one should pin PVE_CONFIG_SHA256 to a digest
# read somewhere other than this download.
bootstrap_fetch_release() {
  local dest=$1 tag=$2
  local dir asset base
  dir=$(dirname -- "${dest}")
  asset="pve-config-${tag}.tar.gz"
  base="https://github.com/${PVE_CONFIG_REPO}/releases/download/${tag}"

  bootstrap_log "fetching ${PVE_CONFIG_REPO} release ${tag}"
  if ! curl -fsSL -o "${dir}/${asset}" "${base}/${asset}"; then
    bootstrap_die "Unable to download ${base}/${asset}"
    return 1
  fi

  # An operator pin is the authority, so the published checksum is not
  # fetched at all when one is set; fetching it would only raise the
  # question of which one wins.
  if [[ ${BOOTSTRAP_PIN_SUPPLIED} == 0 ]]; then
    if ! curl -fsSL -o "${dir}/${asset}.sha256" "${base}/${asset}.sha256"; then
      bootstrap_die "Release ${tag} has no ${asset}.sha256 checksum; refusing to install an unverified download."
      return 1
    fi
    if ! command -v sha256sum >/dev/null 2>&1; then
      bootstrap_die 'sha256sum is required to verify the download.'
      return 1
    fi
    bootstrap_check_checksum_file "${dir}/${asset}.sha256" "${asset}" || return 1
    # The record names the asset and nothing else, and the staging
    # directory was created empty for this install, so the bare name can
    # only resolve to the file just downloaded.
    if ! (cd -- "${dir}" && sha256sum -c -- "${asset}.sha256" >/dev/null 2>&1); then
      bootstrap_die "Checksum verification failed for ${asset}; refusing to install."
      return 1
    fi
    bootstrap_log "verified ${asset} against its published checksum"
  fi

  if ! mv -- "${dir}/${asset}" "${dest}"; then
    bootstrap_die 'Unable to stage the downloaded archive.'
    return 1
  fi
}

bootstrap_fetch_ref() {
  local dest=$1 url
  url=$(bootstrap_archive_url)
  bootstrap_log "fetching ${PVE_CONFIG_REPO} at ${PVE_CONFIG_REF}"
  if ! curl -fsSL -o "${dest}" "${url}"; then
    bootstrap_die "Unable to download ${url}"
    return 1
  fi
}

# Settles which source the install uses, and refuses the combinations that
# cannot mean one thing. Everything here runs before a single byte is
# downloaded, so a misconfigured run stops without touching the network.
bootstrap_check_config() {
  if [[ -n ${PVE_CONFIG_RELEASE} && -n ${PVE_CONFIG_REF} ]]; then
    bootstrap_die 'PVE_CONFIG_RELEASE and PVE_CONFIG_REF both set, and they ask for different things. Set PVE_CONFIG_RELEASE for a published release, or PVE_CONFIG_REF for an unverified ref, not both.'
    return 1
  fi

  if [[ ${BOOTSTRAP_PIN_SUPPLIED} == 1 ]] &&
    ! [[ ${PVE_CONFIG_SHA256} =~ ^[0-9a-fA-F]{64}$ ]]; then
    bootstrap_die 'PVE_CONFIG_SHA256 must be 64 hexadecimal characters: the digest alone, without the filename column sha256sum prints. An empty value counts as malformed, because a pin that did not get set is not a pin.'
    return 1
  fi

  if [[ -n ${PVE_CONFIG_RELEASE} ]] && ! bootstrap_valid_tag "${PVE_CONFIG_RELEASE}"; then
    bootstrap_die "PVE_CONFIG_RELEASE is not a usable tag: ${PVE_CONFIG_RELEASE}"
    return 1
  fi

  # A local archive is bytes the operator already holds. There is no remote
  # origin to authenticate, so the opt-in would buy nothing; a pin still
  # applies, and is the way to check the file is the one intended.
  if [[ -n ${PVE_CONFIG_BOOTSTRAP_ARCHIVE:-} ]]; then
    bootstrap_log "installing from the supplied archive ${PVE_CONFIG_BOOTSTRAP_ARCHIVE}"
    return 0
  fi

  [[ -n ${PVE_CONFIG_REF} ]] || return 0

  # A pin makes a ref install verified, so demanding the opt-in as well
  # would be asking the operator to confirm a risk they already removed.
  [[ ${BOOTSTRAP_PIN_SUPPLIED} == 0 ]] || return 0

  if ! bootstrap_is_true "${PVE_CONFIG_ALLOW_UNVERIFIED}"; then
    bootstrap_die "PVE_CONFIG_REF installs from codeload, which publishes no checksum, so nothing proves the download is the code this project released. To install it anyway, set PVE_CONFIG_ALLOW_UNVERIFIED=1 or pass --allow-unverified. To install a verified build instead, unset PVE_CONFIG_REF, or set PVE_CONFIG_SHA256 to the digest you expect."
    return 1
  fi

  BOOTSTRAP_UNVERIFIED=1
  bootstrap_log '****************************************************************'
  bootstrap_log '*** UNVERIFIED INSTALL                                       ***'
  bootstrap_log "*** Installing ref ${PVE_CONFIG_REF} from codeload."
  bootstrap_log '*** No checksum covers this download, so nothing proves it is ***'
  bootstrap_log '*** the code this project published. Use it for development.  ***'
  bootstrap_log '****************************************************************'
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
  elif [[ -n ${PVE_CONFIG_REF} ]]; then
    if ! command -v curl >/dev/null 2>&1; then
      bootstrap_die 'curl is required.'
      return 1
    fi
    bootstrap_fetch_ref "${dest}" || return 1
  else
    if ! command -v curl >/dev/null 2>&1; then
      bootstrap_die 'curl is required.'
      return 1
    fi
    local tag=${PVE_CONFIG_RELEASE}
    if [[ -z ${tag} ]]; then
      tag=$(bootstrap_latest_tag) || return 1
    fi
    bootstrap_fetch_release "${dest}" "${tag}" || return 1
  fi

  # The pin is checked last and in every mode, so it is the final word on
  # whatever the earlier branch produced.
  if [[ ${BOOTSTRAP_PIN_SUPPLIED} == 1 ]]; then
    bootstrap_verify_sha256 "${dest}" "${PVE_CONFIG_SHA256}" || return 1
    bootstrap_log 'archive matches PVE_CONFIG_SHA256'
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

  # Assembly runs with errexit disabled, because the caller tests this
  # function's status. Every copy is therefore checked by hand: a silently
  # dropped file would otherwise be swapped in over a good installation.
  for item in "${BOOTSTRAP_CODE_PATHS[@]}"; do
    [[ -e ${staging}/src/${item} ]] || continue
    if ! mkdir -p -- "$(dirname -- "${staging}/new/${item}")" ||
      ! cp -a -- "${staging}/src/${item}" "${staging}/new/${item}"; then
      bootstrap_die "Unable to assemble ${item}."
      return 1
    fi
  done

  for item in "${BOOTSTRAP_PRESERVE_PATHS[@]}"; do
    [[ -e ${PVE_CONFIG_DIR}/${item} ]] || continue
    if ! cp -a -- "${PVE_CONFIG_DIR}/${item}" "${staging}/new/${item}"; then
      bootstrap_die "Unable to carry ${item} across from the existing install."
      return 1
    fi
  done

  if ! chmod +x "${staging}/new/pve-config.sh" "${staging}/new/bootstrap.sh"; then
    bootstrap_die 'Unable to make the driver executable.'
    return 1
  fi
  if [[ -d ${staging}/new/stages ]] &&
    ! find "${staging}/new/stages" -type f -name '*.sh' -exec chmod +x {} +; then
    bootstrap_die 'Unable to make the stages executable.'
    return 1
  fi
  if ! mkdir -p -- "${staging}/new/state"; then
    bootstrap_die 'Unable to create the state directory.'
    return 1
  fi

  # The assembled tree is what actually gets installed, so it is checked
  # rather than the archive it was built from.
  for item in "${BOOTSTRAP_REQUIRED_PATHS[@]}"; do
    if [[ ! -e ${staging}/new/${item} ]]; then
      bootstrap_die "Assembled tree is missing ${item}; refusing to install."
      return 1
    fi
  done
}

# Swaps the assembled tree in by rename. The previous install is moved
# aside rather than deleted so a failed rename can be undone.
bootstrap_swap() {
  local staging=$1 backup="${PVE_CONFIG_DIR}.old" backed_up=0
  # A leftover backup is the only copy of an installation an earlier run
  # could not put back. Deleting it to make room would destroy the very
  # thing its recovery message told the operator to go and find.
  if [[ -e ${backup} ]]; then
    bootstrap_die "${backup} still exists from an earlier failed install. Move it back to ${PVE_CONFIG_DIR} or delete it, then run this again."
    return 1
  fi
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

  bootstrap_check_config || return 1

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

# The seeding commands are only suggested when there is nothing to seed.
# After an upgrade they would overwrite the settings and credentials this
# installer just took care to preserve.
bootstrap_next_steps() {
  printf '\nNext steps:\n\n  cd %s\n' "${PVE_CONFIG_DIR}"
  if [[ ! -e ${PVE_CONFIG_DIR}/pve-config.conf ]]; then
    printf '  cp examples/pve-config.conf.example pve-config.conf   # optional, the\n'
  fi
  if [[ ! -e ${PVE_CONFIG_DIR}/secrets.env ]]; then
    printf '  cp examples/secrets.env.example secrets.env           # driver prompts too\n'
    printf '  chmod 600 secrets.env\n'
  fi
  printf '  ./pve-config.sh --list\n  ./pve-config.sh --dry-run\n  ./pve-config.sh\n\n'
  # Repeated here because the warning printed before the download has by
  # now scrolled off the top of a terminal.
  if [[ ${BOOTSTRAP_UNVERIFIED} == 1 ]]; then
    printf 'WARNING: this install came from ref %s and no checksum covers it.\n' \
      "${PVE_CONFIG_REF}"
    printf 'WARNING: it is unverified. Install a published release on a host you care about.\n\n'
  fi
}

bootstrap_usage() {
  cat <<EOF
Usage: bootstrap.sh [-h|--help] [--allow-unverified]

Installs the pve-config toolkit into ${PVE_CONFIG_DIR} and stops.

With no configuration it installs the latest published release and verifies
the download against the checksum published alongside it.

Options:
  --allow-unverified  Permit a PVE_CONFIG_REF install that no checksum covers

Environment:
  PVE_CONFIG_RELEASE  Release tag to install (default: the latest release)
  PVE_CONFIG_SHA256   Expected sha256 of the tarball, 64 hex characters.
                      Takes precedence over the published checksum, and
                      applies in every mode. An empty value is an error
  PVE_CONFIG_REF      Git ref to install from codeload. Unverified, so it
                      needs PVE_CONFIG_SHA256 or PVE_CONFIG_ALLOW_UNVERIFIED=1
  PVE_CONFIG_ALLOW_UNVERIFIED
                      Set to 1 to permit an unverified ref install
  PVE_CONFIG_DIR      Install directory (default: /root/pve-config)
  PVE_CONFIG_REPO     Source repository (default: tykeal/homeassistant-pve-config)
  PVE_CONFIG_BOOTSTRAP_ARCHIVE
                      Install from a local tarball instead of downloading
EOF
}

main() {
  # Argument handling comes before the privilege check so that --help is
  # answered rather than refused.
  while [[ $# -gt 0 ]]; do
    case $1 in
      -h | --help)
        bootstrap_usage
        return 0
        ;;
      --allow-unverified)
        PVE_CONFIG_ALLOW_UNVERIFIED=1
        shift
        ;;
      *)
        bootstrap_die "Unknown argument: $1"
        return 1
        ;;
    esac
  done

  if [[ ${EUID} -ne 0 ]]; then
    bootstrap_die 'This must be run as root on the Proxmox VE host.'
    return 1
  fi
  bootstrap_install || return 1
  bootstrap_next_steps
}

# The documented entry point is bash -c "$(curl ...)", where BASH_SOURCE is
# unset entirely; under set -u that must not be an error. An unset source
# means "not sourced", so the installer runs.
if [[ ${BASH_SOURCE[0]:-$0} == "$0" ]]; then
  main "$@"
fi
