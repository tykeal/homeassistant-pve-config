#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
# SPDX-License-Identifier: Apache-2.0

# Package and apt source convergence. Everything here is a no-op once the
# host is already in the desired state, so a stage can call it on every run
# without the host spending a minute in apt on each one.

pkg_is_installed() {
  local pkg=$1 status
  command -v dpkg-query >/dev/null 2>&1 || return 1
  status=$(dpkg-query -W -f='${Status}' -- "${pkg}" 2>/dev/null) || return 1
  [[ ${status} == *' installed' ]]
}

# Installs only the packages that are missing. Reports changed or unchanged
# so a stage can decide whether the work that follows is needed at all.
pkg_install() {
  local pkg
  local -a missing=()
  for pkg in "$@"; do
    pkg_is_installed "${pkg}" || missing+=("${pkg}")
  done

  if [[ ${#missing[@]} -eq 0 ]]; then
    printf 'unchanged\n'
    return 0
  fi

  local DEBIAN_FRONTEND=noninteractive
  export DEBIAN_FRONTEND
  run_cmd apt-get install -y "${missing[@]}" ||
    die "Unable to install: ${missing[*]}"
  printf 'changed\n'
}

apt_update() {
  local DEBIAN_FRONTEND=noninteractive
  export DEBIAN_FRONTEND
  run_cmd apt-get update || die 'Unable to refresh the apt package lists'
}

# A deb822 source file. Writing it through write_file is what makes a
# repeated run report honestly instead of claiming it switched repository
# every time.
apt_source_install() {
  local path=$1 content=$2
  write_file "${path}" "${content}" 0644
}

apt_source_remove() {
  local path=$1
  remove_path "${path}"
}
