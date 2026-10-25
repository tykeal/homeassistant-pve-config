#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

# shellcheck source=lib/stage.sh
source "${PVE_CONFIG_LIB_DIR:?PVE_CONFIG_LIB_DIR is unset}/stage.sh"

stage_require PVE_ADMIN_USERS

mapfile -t USERS < <(admin_users)
[[ ${#USERS[@]} -gt 0 ]] || die 'PVE_ADMIN_USERS resolved to no usernames.'

# Every key is checked before any of them is installed: a half-configured
# set of administrators is worse than none, because phase 1 goes on to turn
# password authentication off.
admin_keys_require >/dev/null

pkg_install sudo >/dev/null

for user in "${USERS[@]}"; do
  user_keys=$(admin_keys_for "${user}")
  [[ -n ${user_keys} ]] || die "No SSH public key resolved for ${user}."

  # Each of these converges rather than creating. `useradd -m` and
  # `pveum user add` both fail outright on a host where the account is
  # already there, which is what stopped the script this replaces from
  # being run twice.
  user_converge "${user}" /bin/bash >/dev/null
  user_join_group "${user}" sudo >/dev/null
  authorized_keys_install "${user}" "${user_keys}" >/dev/null

  pve_user_converge "${user}@pam" >/dev/null
  pve_acl_converge / PVEAdmin "${user}@pam" >/dev/null

  log_info "administrator ${user} configured"
done

log_info "administrators: ${USERS[*]}"
