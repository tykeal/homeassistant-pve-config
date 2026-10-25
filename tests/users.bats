#!/usr/bin/env bats
# Every @test runs in its own subshell, so the exports these tests use to
# vary the configuration cannot leak into one another; shellcheck's
# subshell-scope warnings describe a hazard that does not exist here.
# shellcheck disable=SC2030,SC2031
# SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
# SPDX-License-Identifier: Apache-2.0

load helpers/test_helper

# Real keys, not example-looking placeholders: ssh-keygen is asked to parse
# every key before it is installed, and it rejects anything else.
VALID_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHICzn119CbPFScmFx6z3R+fB1xufI4WNnsZ0U7HUtEM fixture@example.net'
VALID_KEY_TWO='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDz4H0f8E/En6+2jzdyOYqDv1Uhah1+F4xnYvAGNK1tf fixture@example.net'

setup() {
  load_libs
  isolate_env
  use_mocks
  isolate_system
}

# --- account convergence --------------------------------------------------

@test "user_converge creates the account and then reports unchanged" {
  run user_converge alice /bin/bash
  [ "$status" -eq 0 ]
  [[ "$output" == *changed* ]]
  [[ "$(mock_calls)" == *'useradd -m -s /bin/bash alice'* ]]

  run user_converge alice /bin/bash
  [ "$status" -eq 0 ]
  [[ "$output" == *unchanged* ]]
}

@test "user_converge does not fail on an account that already exists" {
  seed_user alice

  run user_converge alice /bin/bash
  [ "$status" -eq 0 ]
  [[ "$output" == *unchanged* ]]
  # The script this replaces called `useradd -m` unconditionally, which is
  # precisely what must not happen here.
  [[ "$(mock_calls)" != *useradd* ]]
}

@test "user_converge fixes a login shell that drifted" {
  seed_user alice /usr/sbin/nologin
  run user_converge alice /bin/bash
  [[ "$output" == *changed* ]]
  [[ "$(mock_calls)" == *'usermod -s /bin/bash alice'* ]]
  [ "$(user_shell alice)" = '/bin/bash' ]
}

@test "user_converge creates nothing under a dry run" {
  PVE_CONFIG_DRY_RUN=1 run user_converge alice /bin/bash
  [ "$status" -eq 0 ]
  [[ "$(mock_calls)" != *useradd* ]]
  run user_exists alice
  [ "$status" -ne 0 ]
}

@test "user_join_group adds the membership once" {
  user_converge alice /bin/bash >/dev/null
  run user_join_group alice sudo
  [[ "$output" == *changed* ]]
  [[ "$(mock_calls)" == *'usermod -aG sudo alice'* ]]

  run user_join_group alice sudo
  [[ "$output" == *unchanged* ]]
  run user_in_group alice sudo
  [ "$status" -eq 0 ]
}

@test "user_in_group does not match a user whose name is a prefix" {
  printf 'sudo:x:27:alicia\n' >>"${PVE_CONFIG_GROUP}"
  run user_in_group alice sudo
  [ "$status" -ne 0 ]
}

# --- authorized_keys ------------------------------------------------------

@test "authorized_keys_install writes the key with the modes sshd demands" {
  user_converge alice /bin/bash >/dev/null
  run authorized_keys_install alice 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILbgrECpDpZ8haPaqK/bgo6uENLr/PikB/9cnylD52Sj alice@example.net'
  [ "$status" -eq 0 ]
  [[ "$output" == *changed* ]]

  local file="${PVE_CONFIG_ROOT}/home/alice/.ssh/authorized_keys"
  [ "$(stat -c '%a' "${file}")" = '600' ]
  [ "$(stat -c '%a' "${PVE_CONFIG_ROOT}/home/alice/.ssh")" = '700' ]
  [ "$(cat "${file}")" = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILbgrECpDpZ8haPaqK/bgo6uENLr/PikB/9cnylD52Sj alice@example.net' ]
}

@test "authorized_keys_install never installs the same key twice" {
  user_converge alice /bin/bash >/dev/null
  local key='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILbgrECpDpZ8haPaqK/bgo6uENLr/PikB/9cnylD52Sj alice@example.net'
  for _ in 1 2 3; do
    authorized_keys_install alice "${key}" >/dev/null
  done

  local file="${PVE_CONFIG_ROOT}/home/alice/.ssh/authorized_keys"
  [ "$(grep -c AAAAC3NzaC1lZDI1NTE5AAAAILbgrECpDpZ8haPaqK/bgo6uENLr/PikB/9cnylD52Sj "${file}")" -eq 1 ]
  run authorized_keys_install alice "${key}"
  [[ "$output" == *unchanged* ]]
}

@test "authorized_keys_install treats a changed comment as the same key" {
  user_converge alice /bin/bash >/dev/null
  authorized_keys_install alice 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILbgrECpDpZ8haPaqK/bgo6uENLr/PikB/9cnylD52Sj alice@old' >/dev/null
  authorized_keys_install alice 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILbgrECpDpZ8haPaqK/bgo6uENLr/PikB/9cnylD52Sj alice@new' >/dev/null
  [ "$(grep -c AAAAC3NzaC1lZDI1NTE5AAAAILbgrECpDpZ8haPaqK/bgo6uENLr/PikB/9cnylD52Sj "${PVE_CONFIG_ROOT}/home/alice/.ssh/authorized_keys")" -eq 1 ]
}

@test "authorized_keys_install keeps keys the operator added by hand" {
  user_converge alice /bin/bash >/dev/null
  local dir="${PVE_CONFIG_ROOT}/home/alice/.ssh"
  mkdir -p "${dir}"
  printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBa7GpZO855NVuqJ9XXeljTOlV9U6ybTbW7xgVPcEnXF alice@laptop\n' >"${dir}/authorized_keys"

  authorized_keys_install alice 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILbgrECpDpZ8haPaqK/bgo6uENLr/PikB/9cnylD52Sj alice@example.net' >/dev/null
  [ "$(grep -c AAAAC3NzaC1lZDI1NTE5AAAAIBa7GpZO855NVuqJ9XXeljTOlV9U6ybTbW7xgVPcEnXF "${dir}/authorized_keys")" -eq 1 ]
  [ "$(grep -c AAAAC3NzaC1lZDI1NTE5AAAAILbgrECpDpZ8haPaqK/bgo6uENLr/PikB/9cnylD52Sj "${dir}/authorized_keys")" -eq 1 ]
}

@test "authorized_keys_install installs several keys at once" {
  user_converge alice /bin/bash >/dev/null
  authorized_keys_install alice 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILbgrECpDpZ8haPaqK/bgo6uENLr/PikB/9cnylD52Sj alice@one

ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCo2VrhciWI1kBtodczJbvAu8uTwPY4IcUuGFrIamJqjf5o2qZVKLGlfJFeaAbJEY0ljikkWPEq1X44d1AY44cl5gnoMfOlhL9AVIjjTErme5HAuUiviDblYs3kohShI6JDjeE4JP2xDoXsx0thKzYTU1ahkJxvjZwfMQ14CcZ76STNvkQ2VEMt4Dhkwf10u8LZnV4zxHz7a6QGXJeFREFj1+iI4Fabx5+l45sptcAaXCXfc3KsfEVTgeWXT4Xc8JlCDWLXWHVb8Rxw6tSLOyx+0vNTS8+tqvck/RbxLHlYxyCs7APDypdnvzgItsCx223622huZIkTv7VctkOI1f/z alice@two
' >/dev/null
  local file="${PVE_CONFIG_ROOT}/home/alice/.ssh/authorized_keys"
  [ "$(grep -c '^ssh-' "${file}")" -eq 2 ]
}

@test "authorized_keys_install refuses text that is not a public key" {
  user_converge alice /bin/bash >/dev/null
  run authorized_keys_install alice 'this is not a key'
  [ "$status" -ne 0 ]
}

@test "authorized_keys_install writes nothing under a dry run" {
  seed_user alice
  PVE_CONFIG_DRY_RUN=1 run authorized_keys_install alice 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILbgrECpDpZ8haPaqK/bgo6uENLr/PikB/9cnylD52Sj alice@x'
  [ "$status" -eq 0 ]
  [ ! -e "${PVE_CONFIG_ROOT}/home/alice/.ssh" ]
}

# --- key sources ----------------------------------------------------------

@test "a literal key is used as given" {
  run admin_key_source_resolve 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILbgrECpDpZ8haPaqK/bgo6uENLr/PikB/9cnylD52Sj alice@example.net'
  [ "$status" -eq 0 ]
  [ "$output" = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILbgrECpDpZ8haPaqK/bgo6uENLr/PikB/9cnylD52Sj alice@example.net' ]
}

@test "a file path is read for its keys" {
  local path="${PVE_CONFIG_ROOT}/root/admins.pub"
  mkdir -p "$(dirname "${path}")"
  printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILbgrECpDpZ8haPaqK/bgo6uENLr/PikB/9cnylD52Sj alice@one\nssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCo2VrhciWI1kBtodczJbvAu8uTwPY4IcUuGFrIamJqjf5o2qZVKLGlfJFeaAbJEY0ljikkWPEq1X44d1AY44cl5gnoMfOlhL9AVIjjTErme5HAuUiviDblYs3kohShI6JDjeE4JP2xDoXsx0thKzYTU1ahkJxvjZwfMQ14CcZ76STNvkQ2VEMt4Dhkwf10u8LZnV4zxHz7a6QGXJeFREFj1+iI4Fabx5+l45sptcAaXCXfc3KsfEVTgeWXT4Xc8JlCDWLXWHVb8Rxw6tSLOyx+0vNTS8+tqvck/RbxLHlYxyCs7APDypdnvzgItsCx223622huZIkTv7VctkOI1f/z alice@two\n' >"${path}"

  run admin_key_source_resolve /root/admins.pub
  [ "$status" -eq 0 ]
  [[ "$output" == *AAAAC3NzaC1lZDI1NTE5AAAAILbgrECpDpZ8haPaqK/bgo6uENLr/PikB/9cnylD52Sj* ]]
  [[ "$output" == *AAAAB3NzaC1yc2EAAAADAQABAAABAQCo2VrhciWI1kBtodczJbvAu8uTwPY4IcUuGFrIamJqjf5o2qZVKLGlfJFeaAbJEY0ljikkWPEq1X44d1AY44cl5gnoMfOlhL9AVIjjTErme5HAuUiviDblYs3kohShI6JDjeE4JP2xDoXsx0thKzYTU1ahkJxvjZwfMQ14CcZ76STNvkQ2VEMt4Dhkwf10u8LZnV4zxHz7a6QGXJeFREFj1+iI4Fabx5+l45sptcAaXCXfc3KsfEVTgeWXT4Xc8JlCDWLXWHVb8Rxw6tSLOyx+0vNTS8+tqvck/RbxLHlYxyCs7APDypdnvzgItsCx223622huZIkTv7VctkOI1f/z* ]]
}

@test "a key source that is neither a key nor a readable file is rejected" {
  run admin_key_source_resolve /root/missing.pub
  [ "$status" -ne 0 ]
}

@test "a per-user key source overrides the shared one" {
  export PVE_ADMIN_KEY_SOURCE='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILHrfCkywJkes8Ezp2GvAkgIzjzHNgf5ovg8Ti4BpFgZ everyone@example.net'
  export PVE_ADMIN_KEY_BOB='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDbenwxZoDAZb450Hv1dcwUiEktGfazwidTipczur0BF bob@example.net'

  run admin_keys_for alice
  [ "$output" = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILHrfCkywJkes8Ezp2GvAkgIzjzHNgf5ovg8Ti4BpFgZ everyone@example.net' ]

  run admin_keys_for bob
  [ "$output" = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDbenwxZoDAZb450Hv1dcwUiEktGfazwidTipczur0BF bob@example.net' ]
}

# --- key validation -------------------------------------------------------

@test "a key that only looks like one is rejected" {
  # The right algorithm token in front of truncated base64 passes every
  # shape test and is refused by sshd. Accepting it and then disabling
  # password authentication locks everybody out.
  run ssh_key_is_valid 'ssh-ed25519 AAAAnotarealkey alice@example.net'
  [ "$status" -ne 0 ]
}

@test "a real key is accepted" {
  run ssh_key_is_valid "${VALID_KEY}"
  [ "$status" -eq 0 ]
}

@test "authorized_keys_install refuses a key ssh-keygen will not parse" {
  seed_user alice
  run authorized_keys_install alice 'ssh-ed25519 AAAAnotarealkey alice@example.net'
  [ "$status" -ne 0 ]
  [ ! -e "${PVE_CONFIG_ROOT}/home/alice/.ssh/authorized_keys" ]
}

@test "admin_keys_require accepts a shared source covering everybody" {
  export PVE_ADMIN_USERS='alice bob'
  export PVE_ADMIN_KEY_SOURCE="${VALID_KEY}"
  run admin_keys_require
  [ "$status" -eq 0 ]
  [[ "$output" == *'alice 1'* ]]
  [[ "$output" == *'bob 1'* ]]
}

@test "admin_keys_require accepts per-user keys with no shared source" {
  export PVE_ADMIN_USERS='alice bob'
  unset PVE_ADMIN_KEY_SOURCE
  export PVE_ADMIN_KEY_ALICE="${VALID_KEY}"
  export PVE_ADMIN_KEY_BOB="${VALID_KEY_TWO}"
  run admin_keys_require
  [ "$status" -eq 0 ]
}

@test "admin_keys_require reports an administrator nobody gave a key" {
  export PVE_ADMIN_USERS='alice bob'
  unset PVE_ADMIN_KEY_SOURCE
  export PVE_ADMIN_KEY_ALICE="${VALID_KEY}"
  run admin_keys_require
  [ "$status" -ne 0 ]
  [[ "$output" == *bob* ]]
}

@test "admin_keys_require rejects an invalid key before anything is installed" {
  export PVE_ADMIN_USERS='alice'
  export PVE_ADMIN_KEY_SOURCE='ssh-ed25519 AAAAnotarealkey alice@example.net'
  run admin_keys_require
  [ "$status" -ne 0 ]
  [[ "$output" == *'ssh-keygen'* ]]
}

@test "admin_users splits the list and rejects an unusable name" {
  export PVE_ADMIN_USERS='alice bob'
  run admin_users
  [ "$output" = 'alice
bob' ]

  export PVE_ADMIN_USERS='alice ../root'
  run admin_users
  [ "$status" -ne 0 ]
}

@test "admin_users emits nothing when a later name is unusable" {
  # mapfile cannot see a failure inside process substitution, so a list that
  # was half emitted before the bad name would silently drop everybody after
  # it and still look like a success.
  export PVE_ADMIN_USERS='alice ../root bob'
  run admin_users
  [ "$status" -ne 0 ]

  local emitted
  emitted=$(admin_users 2>/dev/null) || true
  [ -z "${emitted}" ]
}

@test "authorized_keys_install adds a key a commented entry only looks like" {
  seed_user alice
  mkdir -p "${PVE_CONFIG_ROOT}/home/alice/.ssh"
  local file="${PVE_CONFIG_ROOT}/home/alice/.ssh/authorized_keys"
  printf '# %s\n' "${VALID_KEY}" >"${file}"

  run authorized_keys_install alice "${VALID_KEY}"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^ssh-ed25519' "${file}")" -eq 1 ]
  [ "$(grep -c '^# ssh-ed25519' "${file}")" -eq 1 ]
}

@test "authorized_keys_install fails rather than writing through a symlink" {
  seed_user alice
  mkdir -p "${PVE_CONFIG_ROOT}/home/alice/.ssh" "${PVE_CONFIG_ROOT}/elsewhere"
  ln -s /elsewhere/keys "${PVE_CONFIG_ROOT}/home/alice/.ssh/authorized_keys"

  run authorized_keys_install alice "${VALID_KEY}"
  [ "$status" -ne 0 ]
  [ ! -e "${PVE_CONFIG_ROOT}/elsewhere/keys" ]
}
