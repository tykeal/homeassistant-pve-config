#!/usr/bin/env bats
# SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
# SPDX-License-Identifier: Apache-2.0

load helpers/test_helper

setup() {
  load_libs
  isolate_env
  config_reset
  CONFIG="${PVE_CONFIG_DIR}/pve-config.conf"
  SECRETS="${PVE_CONFIG_DIR}/secrets.env"
  export NON_INTERACTIVE=1
}

@test "config_get falls back to the derived default when nothing is set" {
  run config_get PVE_DOMAIN 'example.net' 'Domain'
  [ "$status" -eq 0 ]
  [ "$output" = 'example.net' ]
}

@test "config_get fails in non-interactive mode when there is no default" {
  run bash -c "
    source '${REPO_ROOT}/lib/common.sh'
    source '${REPO_ROOT}/lib/config.sh'
    NON_INTERACTIVE=1
    config_get PVE_REQUIRED '' 'Required value'
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *PVE_REQUIRED* ]]
}

@test "a loaded config value beats the derived default" {
  printf "PVE_DOMAIN='from-file.net'\n" >"${CONFIG}"
  config_load "${CONFIG}"
  run config_get PVE_DOMAIN 'derived.net' 'Domain'
  [ "$output" = 'from-file.net' ]
}

@test "an environment override beats the loaded config" {
  printf "PVE_DOMAIN='from-file.net'\n" >"${CONFIG}"
  export PVE_DOMAIN='from-env.net'
  config_load "${CONFIG}"
  run config_get PVE_DOMAIN 'derived.net' 'Domain'
  [ "$output" = 'from-env.net' ]
}

@test "config_get prompts when interactive and keeps the typed answer" {
  NON_INTERACTIVE=0
  run bash -c "
    source '${REPO_ROOT}/lib/common.sh'
    source '${REPO_ROOT}/lib/config.sh'
    NON_INTERACTIVE=0
    config_get PVE_DOMAIN 'derived.net' 'Domain' 2>/dev/null <<<'typed.net'
  "
  [ "$status" -eq 0 ]
  [ "$output" = 'typed.net' ]
}

@test "config_get takes the default when the operator just presses enter" {
  run bash -c "
    source '${REPO_ROOT}/lib/common.sh'
    source '${REPO_ROOT}/lib/config.sh'
    NON_INTERACTIVE=0
    config_get PVE_DOMAIN 'derived.net' 'Domain' 2>/dev/null <<<''
  "
  [ "$status" -eq 0 ]
  [ "$output" = 'derived.net' ]
}

@test "config_save round-trips values containing spaces and quotes" {
  config_get PVE_PLAIN 'simple' 'Plain' >/dev/null
  config_get PVE_SPACED 'two words here' 'Spaced' >/dev/null
  config_get PVE_QUOTED "it's a \"test\"" 'Quoted' >/dev/null
  config_get PVE_KEY 'ssh-ed25519 AAAAC3Nza user@host' 'Key' >/dev/null
  config_save "${CONFIG}" >/dev/null

  run bash -c "
    source '${REPO_ROOT}/lib/common.sh'
    source '${REPO_ROOT}/lib/config.sh'
    config_load '${CONFIG}'
    printf '%s|%s|%s|%s\n' \"\$PVE_PLAIN\" \"\$PVE_SPACED\" \"\$PVE_QUOTED\" \"\$PVE_KEY\"
  "
  [ "$status" -eq 0 ]
  [ "$output" = "simple|two words here|it's a \"test\"|ssh-ed25519 AAAAC3Nza user@host" ]
}

@test "config_save output is a valid shell file with a header" {
  config_get PVE_DOMAIN 'example.net' 'Domain' >/dev/null
  config_save "${CONFIG}" >/dev/null
  run bash -n "${CONFIG}"
  [ "$status" -eq 0 ]
  run head -n 1 "${CONFIG}"
  [[ "$output" == '#'* ]]
}

@test "config_save is idempotent across repeated saves" {
  config_get PVE_DOMAIN 'example.net' 'Domain' >/dev/null
  config_save "${CONFIG}" >/dev/null
  run config_save "${CONFIG}"
  [[ "$output" == *unchanged* ]]
}

@test "secrets never reach the saved configuration" {
  printf "PVE_TAILSCALE_AUTHKEY='tskey-secret'\n" >"${SECRETS}"
  chmod 600 "${SECRETS}"
  secrets_load "${SECRETS}"
  config_get PVE_DOMAIN 'example.net' 'Domain' >/dev/null
  config_save "${CONFIG}" >/dev/null

  run grep -c 'tskey-secret' "${CONFIG}"
  [ "$status" -ne 0 ]
  [ "${PVE_TAILSCALE_AUTHKEY}" = 'tskey-secret' ]
}

@test "a world readable secrets file is a hard error" {
  printf "PVE_TAILSCALE_AUTHKEY='tskey-secret'\n" >"${SECRETS}"
  chmod 644 "${SECRETS}"
  run secrets_load "${SECRETS}"
  [ "$status" -ne 0 ]
  [[ "$output" == *600* ]]
}

@test "a group readable secrets file is a hard error" {
  printf "PVE_TAILSCALE_AUTHKEY='tskey-secret'\n" >"${SECRETS}"
  chmod 640 "${SECRETS}"
  run secrets_load "${SECRETS}"
  [ "$status" -ne 0 ]
}

@test "a secrets file that is a symlink is refused" {
  printf "PVE_TAILSCALE_AUTHKEY='tskey-secret'\n" >"${BATS_TEST_TMPDIR}/elsewhere.env"
  chmod 600 "${BATS_TEST_TMPDIR}/elsewhere.env"
  ln -s "${BATS_TEST_TMPDIR}/elsewhere.env" "${SECRETS}"
  run secrets_load "${SECRETS}"
  [ "$status" -ne 0 ]
  [[ "$output" == *symlink* ]]
}

@test "secrets_save creates the file at 0600 and keeps it out of the config" {
  config_mark_secret PVE_TAILSCALE_AUTHKEY
  config_get PVE_TAILSCALE_AUTHKEY 'tskey-written' 'Auth key' >/dev/null
  config_get PVE_DOMAIN 'example.net' 'Domain' >/dev/null
  secrets_save "${SECRETS}" >/dev/null
  config_save "${CONFIG}" >/dev/null

  run stat -c '%a' "${SECRETS}"
  [ "$output" = '600' ]
  run grep -c 'tskey-written' "${CONFIG}"
  [ "$status" -ne 0 ]

  config_reset
  secrets_load "${SECRETS}"
  [ "${PVE_TAILSCALE_AUTHKEY}" = 'tskey-written' ]
}

@test "a loaded secret is masked in run_cmd output" {
  printf "PVE_TAILSCALE_AUTHKEY='tskey-hidden'\n" >"${SECRETS}"
  chmod 600 "${SECRETS}"
  secrets_load "${SECRETS}"
  run run_cmd true 'tskey-hidden'
  [[ "$output" != *tskey-hidden* ]]
}

@test "an unset variable does not override the file but an empty one does" {
  printf "PVE_DOMAIN='from-file.net'\n" >"${CONFIG}"

  run bash -euo pipefail -c "
    source '${REPO_ROOT}/lib/common.sh'
    source '${REPO_ROOT}/lib/config.sh'
    unset PVE_DOMAIN
    config_load '${CONFIG}'
    printf '%s\n' \"\${PVE_DOMAIN}\"
  "
  [ "$output" = 'from-file.net' ]

  # An exported empty string is a deliberate override and has to win.
  run bash -euo pipefail -c "
    source '${REPO_ROOT}/lib/common.sh'
    source '${REPO_ROOT}/lib/config.sh'
    export PVE_DOMAIN=''
    NON_INTERACTIVE=1
    config_load '${CONFIG}'
    config_get PVE_DOMAIN 'derived.net' 'Domain' >/dev/null
    printf 'empty:%s\n' \"\${PVE_DOMAIN}\"
  " 2>/dev/null
  [ "$status" -eq 0 ]
  [ "$output" = 'empty:' ]
}

@test "awkward values survive a save and load round trip" {
  local nasty=$'has $DOLLAR and `backtick` and \\backslash and \'quote\' and\nnewline'
  config_mark_secret PVE_NASTY_SECRET
  PVE_NASTY_VALUE="${nasty}" config_get PVE_NASTY_VALUE '' 'x' >/dev/null
  PVE_NASTY_SECRET="${nasty}" config_get PVE_NASTY_SECRET '' 'y' >/dev/null
  config_save "${CONFIG}" >/dev/null
  secrets_save "${SECRETS}" >/dev/null

  config_reset
  unset PVE_NASTY_VALUE PVE_NASTY_SECRET
  config_load "${CONFIG}"
  secrets_load "${SECRETS}"
  [ "${PVE_NASTY_VALUE}" = "${nasty}" ]
  [ "${PVE_NASTY_SECRET}" = "${nasty}" ]
}

@test "a config line that is not a quoted assignment is rejected, not run" {
  printf 'PVE_DOMAIN=\x24(touch %s/pwned)\n' "${BATS_TEST_TMPDIR}" >"${CONFIG}"
  run config_load "${CONFIG}"
  [ "$status" -ne 0 ]
  [ ! -e "${BATS_TEST_TMPDIR}/pwned" ]
  [[ "$output" == *"${CONFIG}:1"* ]]
}

@test "a backtick command substitution is rejected" {
  printf 'PVE_DOMAIN="\x60touch %s/pwned\x60"\n' "${BATS_TEST_TMPDIR}" >"${CONFIG}"
  run config_load "${CONFIG}"
  [ "$status" -ne 0 ]
  [ ! -e "${BATS_TEST_TMPDIR}/pwned" ]
}

@test "an unquoted value, an export prefix and a function definition are all rejected" {
  local line
  while IFS= read -r line; do
    printf '%s\n' "${line}" >"${CONFIG}"
    run config_load "${CONFIG}"
    [ "$status" -ne 0 ]
  done < <(printf '%s\n' \
    'PVE_DOMAIN=bare' \
    "export PVE_DOMAIN='x'" \
    'f() { :; }' \
    'PVE_DOMAIN=\x24(id)' \
    'PVE_DOMAIN=\x60id\x60' \
    '. /etc/passwd' \
    'PVE_DOMAIN="x" > captured')
}

@test "an unterminated quoted value is reported with its line number" {
  printf "PVE_DOMAIN='never closed\n" >"${CONFIG}"
  run config_load "${CONFIG}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"${CONFIG}:1"* ]]
}

@test "comments and blank lines are accepted" {
  printf '# a comment\n\n   \nPVE_DOMAIN=\x27ok.net\x27\n' >"${CONFIG}"
  run config_load "${CONFIG}"
  [ "$status" -eq 0 ]
}

@test "secrets_require fails on a missing secret and passes on a present one" {
  run bash -c "
    source '${REPO_ROOT}/lib/common.sh'
    source '${REPO_ROOT}/lib/config.sh'
    secrets_require PVE_MISSING_SECRET
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *PVE_MISSING_SECRET* ]]

  export PVE_PRESENT_SECRET='value'
  run secrets_require PVE_PRESENT_SECRET
  [ "$status" -eq 0 ]
}

@test "loading an absent config or secrets file is not an error" {
  run config_load "${PVE_CONFIG_DIR}/absent.conf"
  [ "$status" -eq 0 ]
  run secrets_load "${PVE_CONFIG_DIR}/absent.env"
  [ "$status" -eq 0 ]
}

@test "a config setting BASH_ENV is rejected and never executed" {
  local payload="${BATS_TEST_TMPDIR}/payload.sh"
  printf 'printf pwned >"%s/pwned"\n' "${BATS_TEST_TMPDIR}" >"${payload}"
  printf "BASH_ENV='%s'\n" "${payload}" >"${CONFIG}"

  run config_load "${CONFIG}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"${CONFIG}:1"* ]]
  [ ! -e "${BATS_TEST_TMPDIR}/pwned" ]
  [ -z "${BASH_ENV:-}" ]
}

@test "shell control names outside the toolkit namespace are rejected" {
  local key
  for key in PATH IFS LD_PRELOAD SHELLOPTS HOME NOTPVE_X; do
    printf "%s='x'\n" "${key}" >"${CONFIG}"
    run config_load "${CONFIG}"
    [ "$status" -ne 0 ]
  done
}

@test "a lowercase pve key is not loadable either" {
  printf "pve_parsed='x'\n" >"${CONFIG}"
  run config_load "${CONFIG}"
  [ "$status" -ne 0 ]
}

@test "leading and trailing whitespace around an assignment is accepted" {
  printf "   PVE_PARSED='spaced.net'   \n" >"${CONFIG}"
  config_load "${CONFIG}"
  [ "${PVE_PARSED}" = 'spaced.net' ]
}

@test "an equals sign inside a value survives parsing" {
  config_set PVE_OPTS 'a=b=c'
  config_save "${CONFIG}" >/dev/null
  config_reset
  unset PVE_OPTS
  config_load "${CONFIG}"
  [ "${PVE_OPTS}" = 'a=b=c' ]
}

@test "a file whose last line has no terminating newline still parses" {
  printf "PVE_PARSED='tail.net'" >"${CONFIG}"
  config_load "${CONFIG}"
  [ "${PVE_PARSED}" = 'tail.net' ]
}

@test "a double quoted value containing a backslash is rejected" {
  printf 'PVE_PARSED="back\\slash"\n' >"${CONFIG}"
  run config_load "${CONFIG}"
  [ "$status" -ne 0 ]
}

@test "a plain double quoted value is accepted" {
  printf 'PVE_PARSED="plain value"\n' >"${CONFIG}"
  config_load "${CONFIG}"
  [ "${PVE_PARSED}" = 'plain value' ]
}

@test "config_ignore_stored re-asks for a key but keeps the rest of the file" {
  printf "PVE_PARSED='old.net'\nPVE_BRIDGE='vmbr9'\n" >"${CONFIG}"
  config_ignore_stored PVE_PARSED
  config_load "${CONFIG}"
  [ -z "${PVE_PARSED:-}" ]
  [ "${PVE_BRIDGE}" = 'vmbr9' ]

  run config_get PVE_PARSED 'derived.net' 'Domain'
  [ "$output" = 'derived.net' ]
}

@test "an ignored key that is never re-answered is still written back" {
  printf "PVE_PARSED='old.net'\n" >"${CONFIG}"
  config_ignore_stored PVE_PARSED
  config_load "${CONFIG}"
  config_save "${CONFIG}" >/dev/null
  run grep -c "PVE_PARSED='old.net'" "${CONFIG}"
  [ "$output" = '1' ]
}

@test "secrets_require registers an environment only credential for redaction" {
  export PVE_TOKEN='tskey-from-env'
  secrets_require PVE_TOKEN
  run run_cmd true tskey-from-env
  [ "$status" -eq 0 ]
  [[ "$output" == *'<redacted>'* ]]
  [[ "$output" != *'tskey-from-env'* ]]
}

@test "whitespace at the end of a line inside a value survives the round trip" {
  config_set PVE_BLOCK $'first line   \nsecond\t\nthird'
  config_save "${CONFIG}" >/dev/null
  config_reset
  unset PVE_BLOCK
  config_load "${CONFIG}"
  [ "${PVE_BLOCK}" = $'first line   \nsecond\t\nthird' ]
}

@test "a blank line inside a value is preserved" {
  config_set PVE_BLOCK $'top\n\nbottom'
  config_save "${CONFIG}" >/dev/null
  config_reset
  unset PVE_BLOCK
  config_load "${CONFIG}"
  [ "${PVE_BLOCK}" = $'top\n\nbottom' ]
}
