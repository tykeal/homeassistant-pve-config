#!/usr/bin/env bats
# SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
# SPDX-License-Identifier: Apache-2.0

load helpers/test_helper

setup() {
  load_libs
  isolate_env
  TARGET="${BATS_TEST_TMPDIR}/target.txt"
}

@test "write_file creates a missing file and reports changed" {
  run write_file "${TARGET}" 'hello'
  [ "$status" -eq 0 ]
  [[ "$output" == *changed* ]]
  [ "$(cat "${TARGET}")" = 'hello' ]
}

@test "write_file reports unchanged when content already matches" {
  write_file "${TARGET}" 'hello' >/dev/null
  run write_file "${TARGET}" 'hello'
  [ "$status" -eq 0 ]
  [[ "$output" == *unchanged* ]]
}

@test "write_file rewrites when content differs" {
  write_file "${TARGET}" 'hello' >/dev/null
  run write_file "${TARGET}" 'goodbye'
  [[ "$output" == *changed* ]]
  [ "$(cat "${TARGET}")" = 'goodbye' ]
}

@test "write_file applies and converges on the requested mode" {
  write_file "${TARGET}" 'secret' 0600 >/dev/null
  [ "$(stat -c '%a' "${TARGET}")" = '600' ]

  run write_file "${TARGET}" 'secret' 0600
  [[ "$output" == *unchanged* ]]

  chmod 0644 "${TARGET}"
  run write_file "${TARGET}" 'secret' 0600
  [[ "$output" == *changed* ]]
  [ "$(stat -c '%a' "${TARGET}")" = '600' ]
}

@test "write_file creates missing parent directories" {
  local nested="${BATS_TEST_TMPDIR}/a/b/c.txt"
  run write_file "${nested}" 'deep'
  [ "$status" -eq 0 ]
  [ -f "${nested}" ]
}

@test "write_file changes nothing under a dry run" {
  PVE_CONFIG_DRY_RUN=1 run write_file "${TARGET}" 'hello'
  [ "$status" -eq 0 ]
  [[ "$output" == *changed* ]]
  [ ! -e "${TARGET}" ]
}

@test "ensure_line_in_file adds the line only once" {
  run ensure_line_in_file "${TARGET}" 'auth sufficient pam_ssh_agent_auth.so'
  [[ "$output" == *changed* ]]

  run ensure_line_in_file "${TARGET}" 'auth sufficient pam_ssh_agent_auth.so'
  [[ "$output" == *unchanged* ]]

  [ "$(grep -c 'pam_ssh_agent_auth' "${TARGET}")" -eq 1 ]
}

@test "ensure_line_in_file treats differing whitespace as equivalent" {
  ensure_line_in_file "${TARGET}" 'auth sufficient pam_ssh_agent_auth.so' >/dev/null
  run ensure_line_in_file "${TARGET}" 'auth    sufficient	pam_ssh_agent_auth.so'
  [[ "$output" == *unchanged* ]]
  [ "$(wc -l <"${TARGET}")" -eq 1 ]
}

@test "ensure_line_in_file can place the line first" {
  printf 'second\n' >"${TARGET}"
  ensure_line_in_file "${TARGET}" 'first' prepend >/dev/null
  [ "$(head -n 1 "${TARGET}")" = 'first' ]
  [ "$(wc -l <"${TARGET}")" -eq 2 ]
}

@test "ensure_line_in_file appends nothing under a dry run" {
  printf 'existing\n' >"${TARGET}"
  PVE_CONFIG_DRY_RUN=1 run ensure_line_in_file "${TARGET}" 'new line'
  [[ "$output" == *changed* ]]
  [ "$(cat "${TARGET}")" = 'existing' ]
}

@test "backup_file copies once and leaves the backup alone afterwards" {
  printf 'original\n' >"${TARGET}"
  run backup_file "${TARGET}"
  [[ "$output" == *changed* ]]
  [ "$(cat "${TARGET}.pve-config.bak")" = 'original' ]

  printf 'modified\n' >"${TARGET}"
  run backup_file "${TARGET}"
  [[ "$output" == *unchanged* ]]
  [ "$(cat "${TARGET}.pve-config.bak")" = 'original' ]
}

@test "backup_file does nothing for a file that does not exist" {
  run backup_file "${BATS_TEST_TMPDIR}/absent"
  [ "$status" -eq 0 ]
  [[ "$output" == *unchanged* ]]
  [ ! -e "${BATS_TEST_TMPDIR}/absent.pve-config.bak" ]
}

@test "run_cmd executes normally and only logs under a dry run" {
  run run_cmd touch "${TARGET}"
  [ "$status" -eq 0 ]
  [ -f "${TARGET}" ]

  rm -f "${TARGET}"
  PVE_CONFIG_DRY_RUN=1 run run_cmd touch "${TARGET}"
  [ "$status" -eq 0 ]
  [ ! -e "${TARGET}" ]
  [[ "$output" == *'would run'* ]]
}

@test "confirm honours ASSUME_YES and the non-interactive default" {
  export ASSUME_YES=1
  run confirm 'proceed?'
  [ "$status" -eq 0 ]

  export ASSUME_YES=0
  export NON_INTERACTIVE=1
  run confirm 'proceed?'
  [ "$status" -ne 0 ]

  run confirm 'proceed?' yes
  [ "$status" -eq 0 ]
}

@test "die reports the message and exits non-zero" {
  run bash -c "source '${REPO_ROOT}/lib/common.sh'; die 'boom'"
  [ "$status" -ne 0 ]
  [[ "$output" == *boom* ]]
}

@test "write_file preserves the content byte for byte" {
  write_file "${TARGET}" $'one\ntwo\n' >/dev/null
  [ "$(od -c <"${TARGET}" | tail -n 2 | head -n 1)" = "$(printf 'one\ntwo\n' | od -c | tail -n 2 | head -n 1)" ]
  [ "$(wc -c <"${TARGET}")" -eq 8 ]

  write_file "${TARGET}" 'no trailing newline' >/dev/null
  [ "$(wc -c <"${TARGET}")" -eq 19 ]

  run write_file "${TARGET}" 'no trailing newline'
  [[ "$output" == *unchanged* ]]
}

@test "write_file refuses to follow a symlink" {
  printf 'real\n' >"${BATS_TEST_TMPDIR}/real"
  ln -s "${BATS_TEST_TMPDIR}/real" "${BATS_TEST_TMPDIR}/link"
  run write_file "${BATS_TEST_TMPDIR}/link" 'attacker'
  [ "$status" -ne 0 ]
  [ "$(cat "${BATS_TEST_TMPDIR}/real")" = 'real' ]
}

@test "write_file keeps the existing mode when none is requested" {
  printf 'old\n' >"${TARGET}"
  chmod 640 "${TARGET}"
  write_file "${TARGET}" 'new' >/dev/null
  run stat -c '%a' "${TARGET}"
  [ "$output" = '640' ]
}

@test "ensure_line_in_file refuses to follow a symlink" {
  printf 'real\n' >"${BATS_TEST_TMPDIR}/real"
  ln -s "${BATS_TEST_TMPDIR}/real" "${BATS_TEST_TMPDIR}/link"
  run ensure_line_in_file "${BATS_TEST_TMPDIR}/link" 'attacker'
  [ "$status" -ne 0 ]
  [ "$(cat "${BATS_TEST_TMPDIR}/real")" = 'real' ]
}

@test "ensure_line_in_file keeps a trailing blank line" {
  printf 'first\n\n' >"${TARGET}"
  ensure_line_in_file "${TARGET}" 'added' >/dev/null
  [ "$(wc -l <"${TARGET}")" -eq 3 ]
  [ "$(sed -n '2p' "${TARGET}")" = '' ]
}

@test "ensure_line_in_file does not treat a commented variant as present" {
  printf '# auth sufficient pam_ssh_agent_auth.so\n' >"${TARGET}"
  run ensure_line_in_file "${TARGET}" 'auth sufficient pam_ssh_agent_auth.so'
  [[ "$output" == *changed* ]]
  [ "$(grep -c '^auth' "${TARGET}")" -eq 1 ]
}

@test "ensure_line_in_file is not confused by regex metacharacters" {
  ensure_line_in_file "${TARGET}" 'Match User *.admin [x]' >/dev/null
  run ensure_line_in_file "${TARGET}" 'Match User *.admin [x]'
  [[ "$output" == *unchanged* ]]
  [ "$(wc -l <"${TARGET}")" -eq 1 ]
}

@test "backup_file makes no backup under a dry run" {
  printf 'original\n' >"${TARGET}"
  PVE_CONFIG_DRY_RUN=1 run backup_file "${TARGET}"
  [ "$status" -eq 0 ]
  [ ! -e "${TARGET}.pve-config.bak" ]
}

@test "run_cmd masks a registered secret in its log line" {
  redact_register 'tskey-abcdef123'
  run run_cmd true 'tskey-abcdef123' plain
  [ "$status" -eq 0 ]
  [[ "$output" != *tskey-abcdef123* ]]
  [[ "$output" == *'<redacted>'* ]]
  [[ "$output" == *plain* ]]
}

@test "run_cmd still passes the real argument to the command" {
  redact_register 'tskey-abcdef123'
  run run_cmd printf '%s' 'tskey-abcdef123'
  [[ "$output" == *tskey-abcdef123* ]]
}

@test "the redaction registry rebuilds itself from the exported key list" {
  run bash -c "
    source '${REPO_ROOT}/lib/common.sh'
    export PVE_SECRET_TOKEN='s3cr3t-value'
    export PVE_CONFIG_SECRET_KEYS='PVE_SECRET_TOKEN'
    run_cmd true \"\${PVE_SECRET_TOKEN}\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" != *s3cr3t-value* ]]
  [[ "$output" == *'<redacted>'* ]]
}

@test "xtrace is suspended and then restored" {
  run bash -c "
    source '${REPO_ROOT}/lib/common.sh'
    set -x
    xtrace_suspend
    case \$- in *x*) echo STILL_TRACING ;; *) echo TRACE_OFF ;; esac
    xtrace_resume
    case \$- in *x*) echo TRACE_BACK ;; *) echo TRACE_LOST ;; esac
  " 2>/dev/null
  [[ "$output" == *TRACE_OFF* ]]
  [[ "$output" == *TRACE_BACK* ]]
}

@test "redaction handles empty, single character and glob secret values" {
  redact_register ''
  redact_register 'x'
  redact_register '*'
  run redact 'keep x and * here'
  [ "$status" -eq 0 ]
  [[ "$output" != *' x '* ]]
  [[ "$output" != *'*'* ]]
  [[ "$output" == *'keep'* ]]
  [[ "$output" == *'here'* ]]
}

@test "an empty secret value does not redact the whole line" {
  redact_register ''
  run redact 'nothing secret here'
  [ "$output" = 'nothing secret here' ]
}

@test "a crafted secret key name is not expanded into a command" {
  # Built with printf so the literal dollar sign is not written out here.
  local payload
  payload=$(printf 'x[\x24(touch %s/pwned)]' "${BATS_TEST_TMPDIR}")

  run env \
    PVE_CONFIG_SECRET_KEYS="${payload}" \
    bash -euo pipefail -c "
      source '${REPO_ROOT}/lib/common.sh'
      run_cmd true
    "
  [ "$status" -eq 0 ]
  [ ! -e "${BATS_TEST_TMPDIR}/pwned" ]
}

@test "secret values still rebuild from well formed key names" {
  run env \
    PVE_CONFIG_SECRET_KEYS='PVE_TOKEN' \
    PVE_TOKEN='tskey-secret' \
    bash -euo pipefail -c "
      source '${REPO_ROOT}/lib/common.sh'
      run_cmd true tskey-secret
    "
  [ "$status" -eq 0 ]
  [[ "$output" == *'<redacted>'* ]]
  [[ "$output" != *'tskey-secret'* ]]
}
