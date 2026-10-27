#!/usr/bin/env bats
# SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
# SPDX-License-Identifier: Apache-2.0

# Stages and the driver run under `set -euo pipefail`, which the test shell
# does not use. These cases exercise the libraries the way a real stage
# does, so a helper that only works with errexit off cannot slip through.

load helpers/test_helper

setup() {
  isolate_env
}

# Log output goes to stderr; these cases assert on stdout only.
strict() {
  bash -euo pipefail -c "
    source '${REPO_ROOT}/lib/common.sh'
    source '${REPO_ROOT}/lib/config.sh'
    source '${REPO_ROOT}/lib/detect.sh'
    source '${REPO_ROOT}/lib/state.sh'
    source '${REPO_ROOT}/lib/schema.sh'
    $1
  " 2>/dev/null
}

@test "sourcing every library under strict mode has no side effects" {
  run strict 'true'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the file helpers survive strict mode" {
  run strict "
    write_file '${BATS_TEST_TMPDIR}/f' 'body' 0600 >/dev/null
    write_file '${BATS_TEST_TMPDIR}/f' 'body' 0600 >/dev/null
    ensure_line_in_file '${BATS_TEST_TMPDIR}/f' 'extra' >/dev/null
    ensure_line_in_file '${BATS_TEST_TMPDIR}/f' 'extra' >/dev/null
    backup_file '${BATS_TEST_TMPDIR}/f' >/dev/null
    backup_file '${BATS_TEST_TMPDIR}/f' >/dev/null
    printf 'done\n'
  "
  [ "$status" -eq 0 ]
  [ "$output" = 'done' ]
  [ "$(grep -c extra "${BATS_TEST_TMPDIR}/f")" -eq 1 ]
}

@test "state handling survives strict mode" {
  run strict "
    state_list >/dev/null
    state_mark_done \"\$(state_id 1 10-host)\"
    state_mark_done \"\$(state_id 1 10-host)\"
    state_record_boot_id 1
    state_reboot_pending 1 || true
    state_list
  "
  [ "$status" -eq 0 ]
  [[ "$output" == 1*10-host* ]]
}

@test "the detection helpers survive strict mode when their inputs are gone" {
  run strict "
    PVE_CONFIG_SYSNET='${BATS_TEST_TMPDIR}/absent'
    PVE_CONFIG_MEMINFO='${BATS_TEST_TMPDIR}/absent'
    PVE_CONFIG_OS_RELEASE='${BATS_TEST_TMPDIR}/absent'
    detect_physical_nics || true
    detect_ram_mb || true
    detect_debian_suite || true
    printf 'done\n'
  "
  [ "$status" -eq 0 ]
  [ "$output" = 'done' ]
}

@test "the schema resolves under strict mode" {
  run strict "
    NON_INTERACTIVE=1
    PVE_DOMAIN='example.net'
    PVE_ADMIN_USERS='admin'
    PVE_ADMIN_KEY_SOURCE='ssh-ed25519 AAAA admin@example.net'
    PVE_SUITE='trixie'
    schema_resolve
    config_save '${PVE_CONFIG_DIR}/c.conf' >/dev/null
    printf '%s\n' \"\$PVE_FQDN\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *example.net ]]
}

@test "bootstrap helpers survive strict mode" {
  run bash -euo pipefail -c "
    export PVE_CONFIG_REF='feat/x'
    source '${REPO_ROOT}/bootstrap.sh'
    bootstrap_encode_ref \"\${PVE_CONFIG_REF}\"
    bootstrap_archive_url
  "
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" = 'feat%2Fx' ]]
  [[ "${lines[1]}" == *'/tar.gz/feat%2Fx' ]]
}

@test "the config round trip survives strict mode" {
  run strict "
    NON_INTERACTIVE=1
    config_get PVE_DOMAIN 'example.net' 'Domain' >/dev/null
    config_save '${PVE_CONFIG_DIR}/c.conf' >/dev/null
    config_load '${PVE_CONFIG_DIR}/c.conf'
    printf '%s\n' \"\$PVE_DOMAIN\"
  "
  [ "$status" -eq 0 ]
  [ "$output" = 'example.net' ]
}

@test "bootstrap refuses to run as an unprivileged user" {
  run "${REPO_ROOT}/bootstrap.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *'root'* ]]
}

@test "bootstrap can be sourced without installing anything" {
  run bash -euo pipefail -c "source '${REPO_ROOT}/bootstrap.sh'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the execution target survives strict mode" {
  use_mocks
  isolate_system
  # A guest operation is a nested shell inside a command substitution
  # inside errexit, which is where a helper that only works with errexit
  # off would fall over.
  run bash -euo pipefail -c "
    for lib in common state pkg users service pve target; do
      source \"${REPO_ROOT}/lib/\${lib}.sh\"
    done
    guest=\$(target_guest 101)
    target_write_file \"\${guest}\" /etc/t 'body' 0640 >/dev/null
    target_write_file \"\${guest}\" /etc/t 'body' 0640 >/dev/null
    target_ensure_line_in_file \"\${guest}\" /etc/t 'extra' >/dev/null
    target_ensure_line_in_file \"\${guest}\" /etc/t 'extra' >/dev/null
    target_user_converge \"\${guest}\" deploy >/dev/null
    target_user_converge \"\${guest}\" deploy >/dev/null
    target_user_join_group \"\${guest}\" deploy sudo >/dev/null
    target_pkg_install \"\${guest}\" curl >/dev/null
    target_service_enable \"\${guest}\" unit >/dev/null
    target_test \"\${guest}\" f /etc/absent || true
    printf 'done\\n'
  "
  [ "$status" -eq 0 ]
  # Log output is on stderr, which run folds into $output here.
  [ "${lines[${#lines[@]} - 1]}" = 'done' ]
}

@test "every shipped shell file parses" {
  local file
  while IFS= read -r file; do
    run bash -n "${file}"
    [ "$status" -eq 0 ]
  done < <(find "${REPO_ROOT}" -name '.git' -prune -o -type f -name '*.sh' -print)
}

@test "version recording survives strict mode" {
  # Derived rather than hard-coded: a release tarball ships this suite
  # with lib/version.sh already stamped, so asserting '0.0.0' would fail
  # for every operator re-running the suite from a release.
  local expected
  expected=$(sed -n "s/^PVE_CONFIG_VERSION='\(.*\)'$/\1/p" \
    "${REPO_ROOT}/lib/version.sh")
  run strict "
    source '${REPO_ROOT}/lib/version.sh'
    source '${REPO_ROOT}/lib/version.sh'
    state_record_version
    state_record_version
    state_recorded_version
  "
  [ "$status" -eq 0 ]
  [ "$output" = "${expected}" ]
}
