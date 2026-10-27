#!/usr/bin/env bats
# Every @test runs in its own subshell, so the exports these tests use to
# vary the configuration cannot leak into one another; shellcheck's
# subshell-scope warnings describe a hazard that does not exist here.
# shellcheck disable=SC2030,SC2031
# SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
# SPDX-License-Identifier: Apache-2.0

load helpers/test_helper
load helpers/stage_asserts

ME_KEY='me-key-4f2a9c'
ME_SECRET='me-secret-7b31de'

setup() {
  load_libs
  isolate_env
  use_mocks
  isolate_system
  stage_config
  seed_secrets_file
}

# Everything the driver would have resolved before phase 2 starts.
stage_config() {
  export PVE_HOSTNAME='pve1'
  export PVE_DOMAIN='example.net'
  export PVE_FQDN='pve1.example.net'
  export PVE_ACME_ENABLED='yes'
  export PVE_ACME_ENVIRONMENT='staging'
  export PVE_ACME_EMAIL='admin@example.net'
  export PVE_ACME_DNS_PLUGIN='dnsmadeeasy'
  export PVE_ACME_ACCEPT_TOS='yes'
  export PVE_ACME_FORCE_ORDER='no'
}

# The secrets file the driver wrote, at the mode the loader insists on.
seed_secrets_file() {
  SECRETS="${PVE_CONFIG_DIR}/secrets.env"
  printf "PVE_DNSMADEEASY_KEY='%s'\nPVE_DNSMADEEASY_SECRET='%s'\n" \
    "${ME_KEY}" "${ME_SECRET}" >"${SECRETS}"
  chmod 600 "${SECRETS}"
}

assert_stage_converges() {
  assert_stage_converges_with run_phase2_stage "$1"
}

credentials_file() {
  printf '%s\n' "${PVE_CONFIG_ROOT}/etc/pve-config/dnsmadeeasy.conf"
}

# Replaces the certificate the mock believes this host serves. Subject, SAN
# list and issuer are separate, because a certificate can name one host in
# its subject and cover another in its SAN.
seed_cert() {
  local subject=$1 san=$2 issuer=$3 days=${4:-90}
  printf '%s|%s|%s|%s\n' "${subject}" "${san}" "${issuer}" \
    "$(($(date +%s) + days * 86400))" >"${PVE_CONFIG_MOCK_STATE}/node-cert"
}

@test "10-acme writes the DNS credentials, configures the plugin and orders" {
  run run_phase2_stage 10-acme.sh
  [ "$status" -eq 0 ]

  local body
  body=$(cat "$(credentials_file)")
  [[ "${body}" == *"ME_Key=${ME_KEY}"* ]]
  [[ "${body}" == *"ME_Secret=${ME_SECRET}"* ]]

  local calls
  calls=$(mock_calls)
  [[ "${calls}" == *'pvenode acme plugin add dns dnsmadeeasy --api me --data'* ]]
  [[ "${calls}" == *'pvenode acme account register staging admin@example.net --directory https://acme-staging-v02.api.letsencrypt.org/directory'* ]]
  [[ "${calls}" == *'pvenode config set --acme account=staging --acmedomain0 pve1.example.net,plugin=dnsmadeeasy'* ]]
  [[ "${calls}" == *'pvenode acme cert order'* ]]
}

@test "10-acme keeps the credentials file at 0600 in a 0700 directory" {
  run_phase2_stage 10-acme.sh
  [ "$(stat -c '%a' "$(credentials_file)")" = '600' ]
  [ "$(stat -c '%a' "${PVE_CONFIG_ROOT}/etc/pve-config")" = '700' ]
}

@test "10-acme never puts a credential in an argument list or a log line" {
  export PVE_CONFIG_SECRET_KEYS='PVE_DNSMADEEASY_KEY PVE_DNSMADEEASY_SECRET'
  run run_phase2_stage 10-acme.sh
  [ "$status" -eq 0 ]

  # Everything the stage said, and every argument list it built.
  [[ "$output" != *"${ME_KEY}"* ]]
  [[ "$output" != *"${ME_SECRET}"* ]]
  [[ "$(mock_calls)" != *"${ME_KEY}"* ]]
  [[ "$(mock_calls)" != *"${ME_SECRET}"* ]]

  # What pvenode was given instead: the path of the file holding them.
  [[ "$(mock_calls)" == *"--data ${PVE_CONFIG_ROOT}/etc/pve-config/dnsmadeeasy.conf"* ]]
}

@test "10-acme keeps a credential out of the environment of its children" {
  # The driver's secrets loader exports what it reads, so the stage starts
  # with both values in its environment. Nothing it runs may inherit them.
  export PVE_DNSMADEEASY_KEY="${ME_KEY}"
  export PVE_DNSMADEEASY_SECRET="${ME_SECRET}"
  export PVE_CONFIG_SECRET_KEYS='PVE_DNSMADEEASY_KEY PVE_DNSMADEEASY_SECRET'

  run run_phase2_stage 10-acme.sh
  [ "$status" -eq 0 ]

  local inherited
  inherited=$(mock_env)
  [ -n "${inherited}" ]
  [[ "${inherited}" != *"${ME_KEY}"* ]]
  [[ "${inherited}" != *"${ME_SECRET}"* ]]
  run grep -q '^PVE_DNSMADEEASY_KEY=' "${PVE_CONFIG_MOCK_ENV_LOG}"
  [ "$status" -ne 0 ]
  run grep -q '^PVE_DNSMADEEASY_SECRET=' "${PVE_CONFIG_MOCK_ENV_LOG}"
  [ "$status" -ne 0 ]
}

@test "10-acme drops the exported credentials before it forks anything" {
  # Every fork hands the child a copy of the environment, and a command
  # substitution forks as surely as pvenode does -- sourcing stage.sh runs
  # one before the stage reaches its first statement.
  #
  # The probe is a DEBUG trap rather than a PS4 prefix: a prefix needs
  # tracing, and tracing with a credential exported is the one combination
  # this stage refuses outright. The trap fires for every command the
  # stage runs, in subshells too, and records only those that ran while
  # the credentials were still exported.
  export PVE_DNSMADEEASY_KEY="${ME_KEY}"
  export PVE_DNSMADEEASY_SECRET="${ME_SECRET}"
  export PVE_CONFIG_SECRET_KEYS='PVE_DNSMADEEASY_KEY PVE_DNSMADEEASY_SECRET'

  local probe="${BATS_TEST_TMPDIR}/exported.log"
  local rc="${BATS_TEST_TMPDIR}/probe.bash"
  export PROBE_LOG="${probe}"
  cat >"${rc}" <<'PROBE'
set -T
trap 'if [[ -n ${PVE_DNSMADEEASY_KEY+set} || -n ${PVE_DNSMADEEASY_SECRET+set} ]]; then printf "%s\n" "${BASH_COMMAND}" >>"${PROBE_LOG}"; fi' DEBUG
PROBE

  BASH_ENV="${rc}" bash "${REPO_ROOT}/stages/phase2/10-acme.sh" >/dev/null

  # The exact commands, in order. A pattern that merely allowed anything
  # beginning _ACME_BOOT_ would let `_ACME_BOOT_KEY=$(something)` through,
  # and a command substitution is the fork this test exists to catch.
  [ -s "${probe}" ]
  local expected="${BATS_TEST_TMPDIR}/expected"
  cat >"${expected}" <<'EXPECTED'
set -euo pipefail
case ${-} in
_ACME_BOOT_XTRACE=0
set +x
PS4='+ '
_ACME_BOOT_KEY_SET=${PVE_DNSMADEEASY_KEY+set}
_ACME_BOOT_SECRET_SET=${PVE_DNSMADEEASY_SECRET+set}
[[ ${_ACME_BOOT_XTRACE} -eq 1 ]]
_ACME_BOOT_KEY=${PVE_DNSMADEEASY_KEY:-}
_ACME_BOOT_SECRET=${PVE_DNSMADEEASY_SECRET:-}
unset PVE_DNSMADEEASY_KEY PVE_DNSMADEEASY_SECRET
EXPECTED
  # Trailing space is trimmed on the recorded side: bash reports `case`
  # with one, and this file may not carry it.
  run diff "${expected}" <(sed 's/[[:space:]]*$//' "${probe}")
  [ "$status" -eq 0 ]

  # Said again as a rule rather than as a transcript, so a rewrite of the
  # block that reintroduced a fork fails here too and not only above.
  local line
  # shellcheck disable=SC2016  # the patterns are literal command text
  while IFS= read -r line; do
    [[ "${line}" != *'$('* ]]
    [[ "${line}" != *'`'* ]]
    [[ "${line}" != *'<('* ]]
    [[ "${line}" != *'>('* ]]
    [[ "${line}" != 'source '* && "${line}" != '. '* ]]
  done <"${probe}"
}

@test "10-acme prints no credential while the shell traces every command" {
  export PVE_CONFIG_SECRET_KEYS='PVE_DNSMADEEASY_KEY PVE_DNSMADEEASY_SECRET'
  run bash -x "${REPO_ROOT}/stages/phase2/10-acme.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *'+ '* ]]
  [[ "$output" != *"${ME_KEY}"* ]]
  [[ "$output" != *"${ME_SECRET}"* ]]
}

@test "10-acme refuses to run when tracing is on and a credential is exported" {
  # Bash expands the inherited PS4 before the very first command of the
  # script, so a credential that arrived in the environment has already
  # been exposed to whatever that prefix does. Nothing inside the script
  # can prevent that; what it can do is stop, and say so.
  export PVE_DNSMADEEASY_KEY="${ME_KEY}"
  export PVE_DNSMADEEASY_SECRET="${ME_SECRET}"
  export PVE_CONFIG_SECRET_KEYS='PVE_DNSMADEEASY_KEY PVE_DNSMADEEASY_SECRET'

  run bash -x "${REPO_ROOT}/stages/phase2/10-acme.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *'refusing to run the ACME stage with tracing already enabled'* ]]
  [[ "$output" == *'rotate them'* ]]
  [[ "$output" != *"${ME_KEY}"* ]]
  [[ "$output" != *"${ME_SECRET}"* ]]

  # It stopped before it did anything: no credentials file, and no child
  # process of any kind.
  [ ! -f "$(credentials_file)" ]
  [ -z "$(mock_calls)" ]
}

@test "10-acme runs under tracing when the credentials come from the file" {
  # The refusal is about the environment. The supported way of supplying
  # the credentials stays debuggable.
  run bash -x "${REPO_ROOT}/stages/phase2/10-acme.sh"
  [ "$status" -eq 0 ]
  [[ "$output" != *"${ME_KEY}"* ]]
  [[ "$output" != *"${ME_SECRET}"* ]]
}

@test "acme_require_owned refuses a directory owned by somebody else" {
  [ "${EUID}" -ne 0 ] || skip 'the fixture is a path the test user does not own'
  run acme_require_owned /etc
  [ "$status" -ne 0 ]
  [[ "$output" == *'owned by uid 0'* ]]
}

@test "acme_require_owned refuses a file owned by somebody else" {
  [ "${EUID}" -ne 0 ] || skip 'the fixture is a path the test user does not own'
  run acme_require_owned /etc/hostname
  [ "$status" -ne 0 ]
  [[ "$output" == *'owned by uid 0'* ]]
}

@test "acme_require_owned accepts what the running user owns" {
  local path="${BATS_TEST_TMPDIR}/owned"
  : >"${path}"
  run acme_require_owned "${path}"
  [ "$status" -eq 0 ]
}

@test "10-acme refuses a credentials directory somebody else planted" {
  [ "${EUID}" -ne 0 ] || skip 'the fixture is a path the test user does not own'
  # A symlink is how an unprivileged attacker points a root-owned path at
  # a directory of their own.
  ln -s /etc "${PVE_CONFIG_ROOT}/etc/pve-config"

  run run_phase2_stage 10-acme.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *'symlink'* ]]
  [ ! -e "/etc/pve-config/dnsmadeeasy.conf" ]
}

@test "10-acme refuses a credentials file somebody else planted" {
  mkdir -p "${PVE_CONFIG_ROOT}/etc/pve-config"
  ln -s "${BATS_TEST_TMPDIR}/elsewhere" "$(credentials_file)"

  run run_phase2_stage 10-acme.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *'symlink'* ]]
  [ ! -e "${BATS_TEST_TMPDIR}/elsewhere" ]
}

@test "10-acme refuses a credentials directory another user owns" {
  mkdir -p "${PVE_CONFIG_ROOT}/etc/pve-config"
  use_foreign_owner "${PVE_CONFIG_ROOT}/etc/pve-config"

  run run_phase2_stage 10-acme.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *'owned by uid 4242'* ]]
  [ ! -e "$(credentials_file)" ]
}

@test "10-acme refuses a credentials file another user owns" {
  # Mode alone says nothing: a 0600 file somebody else owns is a file
  # somebody else reads, and write_file keeps the owner of what it
  # replaces.
  mkdir -p "${PVE_CONFIG_ROOT}/etc/pve-config"
  printf 'ME_Key=planted\n' >"$(credentials_file)"
  chmod 600 "$(credentials_file)"
  use_foreign_owner "$(credentials_file)"

  run run_phase2_stage 10-acme.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *'owned by uid 4242'* ]]
  [[ "$(cat "$(credentials_file)")" == 'ME_Key=planted' ]]
}

@test "10-acme refuses to order when the certificate listing fails" {
  PVE_CONFIG_MOCK_CERT_INFO=fail run run_phase2_stage 10-acme.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *'Unable to read the certificates'* ]]
  [[ "$(mock_calls)" != *'cert order'* ]]
}

@test "10-acme refuses to order when the certificate listing says nothing" {
  PVE_CONFIG_MOCK_CERT_INFO=empty run run_phase2_stage 10-acme.sh
  [ "$status" -ne 0 ]
  [[ "$(mock_calls)" != *'cert order'* ]]
}

@test "10-acme refuses to order when the certificate listing is not JSON" {
  PVE_CONFIG_MOCK_CERT_INFO=garbage run run_phase2_stage 10-acme.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *'Unable to read the certificates'* ]]
  [[ "$(mock_calls)" != *'cert order'* ]]
}

@test "10-acme orders again when the certificate covers another name" {
  run_phase2_stage 10-acme.sh
  # The subject still names this host. The SAN list, which is what a client
  # checks, covers somebody else.
  seed_cert "CN=${PVE_FQDN}" 'other.example.net' \
    "C=US,O=(STAGING) Let's Encrypt,CN=(STAGING) Wannabe Watercress R11"
  : >"${PVE_CONFIG_MOCK_LOG}"

  run run_phase2_stage 10-acme.sh
  [ "$status" -eq 0 ]
  [[ "$(mock_calls)" == *'pvenode acme cert order'* ]]
}

@test "10-acme keeps a certificate whose wildcard covers the host" {
  run_phase2_stage 10-acme.sh
  seed_cert 'CN=*.example.net' '*.example.net' \
    "C=US,O=(STAGING) Let's Encrypt,CN=(STAGING) Wannabe Watercress R11"
  : >"${PVE_CONFIG_MOCK_LOG}"

  run run_phase2_stage 10-acme.sh
  [ "$status" -eq 0 ]
  [[ "$(mock_calls)" != *'cert order'* ]]
}

@test "10-acme orders again when the certificate came from another CA" {
  export PVE_ACME_ENVIRONMENT='production'
  run_phase2_stage 10-acme.sh
  # Valid, current, covers the name, and nothing to do with Let's Encrypt.
  seed_cert "CN=${PVE_FQDN}" "${PVE_FQDN}" \
    'C=US,O=Example Trust Services,CN=Example Secure CA G2'
  : >"${PVE_CONFIG_MOCK_LOG}"

  run run_phase2_stage 10-acme.sh
  [ "$status" -eq 0 ]
  [[ "$(mock_calls)" == *'pvenode acme cert order'* ]]
}

@test "10-acme still runs when the credentials are only in the environment" {
  rm -f "${SECRETS}"
  export PVE_DNSMADEEASY_KEY="${ME_KEY}"
  export PVE_DNSMADEEASY_SECRET="${ME_SECRET}"

  run run_phase2_stage 10-acme.sh
  [ "$status" -eq 0 ]
  [[ "$(cat "$(credentials_file)")" == *"ME_Secret=${ME_SECRET}"* ]]
  [[ "$(mock_env)" != *"${ME_SECRET}"* ]]
}

@test "10-acme refuses a secrets file anyone else can read" {
  chmod 644 "${SECRETS}"
  run run_phase2_stage 10-acme.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *'must be 600'* ]]
  [ ! -e "$(credentials_file)" ]
}

@test "10-acme stops when neither the file nor the environment has the pair" {
  printf "PVE_DNSMADEEASY_KEY='%s'\n" "${ME_KEY}" >"${SECRETS}"
  chmod 600 "${SECRETS}"
  run run_phase2_stage 10-acme.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *'PVE_DNSMADEEASY_SECRET'* ]]
  [[ "$output" != *"${ME_KEY}"* ]]
}

@test "10-acme orders from the staging directory by default" {
  unset PVE_ACME_ENVIRONMENT
  run run_phase2_stage 10-acme.sh
  [ "$status" -eq 0 ]
  [[ "$(mock_calls)" == *'--directory https://acme-staging-v02.api.letsencrypt.org/directory'* ]]
  [[ "$(mock_calls)" != *'--directory https://acme-v02.api.letsencrypt.org/directory'* ]]
}

@test "10-acme orders from production when the deployment asks for it" {
  export PVE_ACME_ENVIRONMENT='production'
  run run_phase2_stage 10-acme.sh
  [ "$status" -eq 0 ]
  [[ "$(mock_calls)" == *'pvenode acme account register production admin@example.net --directory https://acme-v02.api.letsencrypt.org/directory'* ]]
  [[ "$(mock_calls)" == *'--acme account=production'* ]]
}

@test "10-acme refuses a forced order against production" {
  export PVE_ACME_ENVIRONMENT='production'
  export PVE_ACME_FORCE_ORDER='yes'
  run run_phase2_stage 10-acme.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *'staging directory only'* ]]
  [[ "$(mock_calls)" != *'cert order'* ]]
  [ ! -e "$(credentials_file)" ]
}

@test "10-acme forces an order on staging even when the certificate is current" {
  run_phase2_stage 10-acme.sh
  export PVE_ACME_FORCE_ORDER='yes'
  : >"${PVE_CONFIG_MOCK_LOG}"

  run run_phase2_stage 10-acme.sh
  [ "$status" -eq 0 ]
  [[ "$(mock_calls)" == *'pvenode acme cert order --force 1'* ]]
}

@test "10-acme refuses a DNS provider other than DNS Made Easy" {
  export PVE_ACME_DNS_PLUGIN='cloudflare'
  run run_phase2_stage 10-acme.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *'only supported provider'* ]]
  [[ "$(mock_calls)" != *'plugin add'* ]]
  [ ! -e "$(credentials_file)" ]
}

@test "10-acme refuses an environment that is neither staging nor production" {
  export PVE_ACME_ENVIRONMENT='testing'
  run run_phase2_stage 10-acme.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *'staging or production'* ]]
}

@test "10-acme stops before registering when the terms are not accepted" {
  export PVE_ACME_ACCEPT_TOS='no'
  run run_phase2_stage 10-acme.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *'PVE_ACME_ACCEPT_TOS'* ]]
  [[ "$(mock_calls)" != *'account register'* ]]
}

@test "10-acme needs a contact address once it is enabled" {
  unset PVE_ACME_EMAIL
  run run_phase2_stage 10-acme.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *'PVE_ACME_EMAIL'* ]]
}

@test "10-acme does nothing at all when it is not enabled" {
  export PVE_ACME_ENABLED='no'
  run run_phase2_stage 10-acme.sh
  [ "$status" -eq 0 ]
  [ ! -e "$(credentials_file)" ]
  [ -z "$(mock_calls)" ]
}

@test "10-acme is idempotent" {
  assert_stage_converges 10-acme.sh
}

@test "10-acme does not re-order a certificate that is already current" {
  run_phase2_stage 10-acme.sh
  : >"${PVE_CONFIG_MOCK_LOG}"
  run run_phase2_stage 10-acme.sh
  [ "$status" -eq 0 ]
  [[ "$(mock_calls)" != *'cert order'* ]]
  [[ "$output" == *'already holds a current staging certificate'* ]]
}

# `pvenode acme cert order` declines to overwrite a certificate that is
# already there, so a certificate that is merely due is renewed. Asking
# for an order here leaves a host that never converges: every run asks
# for one and pvenode refuses it.
@test "10-acme renews a certificate that is inside the renewal window" {
  PVE_CONFIG_MOCK_CERT_DAYS=5 run_phase2_stage 10-acme.sh
  : >"${PVE_CONFIG_MOCK_LOG}"
  run run_phase2_stage 10-acme.sh
  [ "$status" -eq 0 ]
  [[ "$(mock_calls)" == *'pvenode acme cert renew'* ]]
  [[ "$(mock_calls)" != *'pvenode acme cert order'* ]]
  [[ "$output" == *'renewing the certificate'* ]]
}

@test "10-acme replaces a certificate issued for another name" {
  run_phase2_stage 10-acme.sh
  local state="${PVE_CONFIG_MOCK_STATE}/node-cert"
  local subject san issuer notafter
  IFS='|' read -r subject san issuer notafter <"${state}"
  printf 'CN=old.example.net|old.example.net|%s|%s\n' "${issuer}" "${notafter}" \
    >"${state}"
  : >"${PVE_CONFIG_MOCK_LOG}"

  run run_phase2_stage 10-acme.sh
  [ "$status" -eq 0 ]
  [[ "$(mock_calls)" == *'pvenode acme cert order --force 1'* ]]
  [[ "$output" == *'replacing the certificate'* ]]
}

# A replacement is not the forced order staging reserves to itself: it is
# the only way a deployment promoted to production stops serving the
# staging certificate, and pvenode will not overwrite without it.
@test "10-acme forces the overwrite when it promotes to production" {
  run_phase2_stage 10-acme.sh
  export PVE_ACME_ENVIRONMENT='production'
  : >"${PVE_CONFIG_MOCK_LOG}"

  run run_phase2_stage 10-acme.sh
  [ "$status" -eq 0 ]
  [[ "$(mock_calls)" == *'pvenode acme cert order --force 1'* ]]
}

@test "acme_cert_state tells absent, current, renewable and replace apart" {
  run acme_cert_state 'pve1.example.net' staging
  [ "$status" -eq 0 ]
  [ "$output" = 'absent' ]

  seed_cert 'CN=pve1.example.net' 'pve1.example.net' \
    "C=US,O=(STAGING) Let's Encrypt,CN=R11" 90
  run acme_cert_state 'pve1.example.net' staging
  [ "$output" = 'current' ]

  seed_cert 'CN=pve1.example.net' 'pve1.example.net' \
    "C=US,O=(STAGING) Let's Encrypt,CN=R11" 5
  run acme_cert_state 'pve1.example.net' staging
  [ "$output" = 'renewable' ]

  run acme_cert_state 'pve1.example.net' production
  [ "$output" = 'replace' ]

  seed_cert 'CN=pve1.example.net' 'other.example.net' \
    "C=US,O=(STAGING) Let's Encrypt,CN=R11" 90
  run acme_cert_state 'pve1.example.net' staging
  [ "$output" = 'replace' ]
}

@test "10-acme re-orders when a deployment moves from staging to production" {
  run_phase2_stage 10-acme.sh
  export PVE_ACME_ENVIRONMENT='production'
  : >"${PVE_CONFIG_MOCK_LOG}"

  run run_phase2_stage 10-acme.sh
  [ "$status" -eq 0 ]
  [[ "$(mock_calls)" == *'pvenode acme account register production'* ]]
  [[ "$(mock_calls)" == *'pvenode acme cert order'* ]]
}

@test "10-acme hands pvenode the rotated credentials and nothing else" {
  run_phase2_stage 10-acme.sh
  printf "PVE_DNSMADEEASY_KEY='%s'\nPVE_DNSMADEEASY_SECRET='%s'\n" \
    "${ME_KEY}-new" "${ME_SECRET}-new" >"${SECRETS}"
  chmod 600 "${SECRETS}"
  : >"${PVE_CONFIG_MOCK_LOG}"

  run run_phase2_stage 10-acme.sh
  [ "$status" -eq 0 ]
  [[ "$(mock_calls)" == *'pvenode acme plugin set dnsmadeeasy --api me --data'* ]]
  [[ "$(mock_calls)" != *"${ME_SECRET}-new"* ]]
  [[ "$(cat "$(credentials_file)")" == *"ME_Secret=${ME_SECRET}-new"* ]]
}

@test "10-acme stops when the account belongs to the other directory" {
  run_phase2_stage 10-acme.sh
  # An account named for staging, registered against production, is a host
  # someone else has already set up differently.
  printf 'staging admin@example.net https://acme-v02.api.letsencrypt.org/directory\n' \
    >"${PVE_CONFIG_MOCK_STATE}/acme-accounts"

  run run_phase2_stage 10-acme.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *'deactivate'* ]]
}

@test "10-acme changes nothing under a dry run" {
  PVE_CONFIG_DRY_RUN=1 run run_phase2_stage 10-acme.sh
  [ "$status" -eq 0 ]
  [ ! -e "$(credentials_file)" ]
  [ ! -e "${PVE_CONFIG_ROOT}/etc/pve-config" ]

  local calls
  calls=$(mock_calls)
  [[ "${calls}" != *'account register'* ]]
  [[ "${calls}" != *'plugin add'* ]]
  [[ "${calls}" != *'config set'* ]]
  [[ "${calls}" != *'cert order'* ]]
  run assert_no_mutating_calls
  [ "$status" -eq 0 ]
}

@test "10-acme makes no mutating call under a dry run on a configured host" {
  run_phase2_stage 10-acme.sh
  : >"${PVE_CONFIG_MOCK_LOG}"
  PVE_CONFIG_DRY_RUN=1 run run_phase2_stage 10-acme.sh
  [ "$status" -eq 0 ]
  run assert_no_mutating_calls
  [ "$status" -eq 0 ]
}

@test "10-acme prints no credential through a trace prefix of somebody else's" {
  # PS4 is expanded before every traced command, so a PS4 that
  # dereferences a variable prints whatever that variable holds. The
  # names here are the ones this stage keeps credentials in.
  export PVE_CONFIG_SECRET_KEYS='PVE_DNSMADEEASY_KEY PVE_DNSMADEEASY_SECRET'

  run env \
    "PS4=+[\${_ACME_BOOT_SECRET:-}\${_ACME_ENV_SECRET:-}\${ACME_ME_SECRET:-}\${credentials:-}\${_ACME_BOOT_KEY:-}\${_ACME_ENV_KEY:-}\${ACME_ME_KEY:-}] " \
    bash -x "${REPO_ROOT}/stages/phase2/10-acme.sh"
  [ "$status" -eq 0 ]
  [[ "$output" != *"${ME_KEY}"* ]]
  [[ "$output" != *"${ME_SECRET}"* ]]
}

@test "10-acme takes the credentials in the environment over the ones on disk" {
  # A rotation that has not reached secrets.env yet, or a one-off run.
  # Using the file instead would configure the plugin with credentials the
  # provider has already retired.
  export PVE_DNSMADEEASY_KEY='rotated-key-11aa'
  export PVE_DNSMADEEASY_SECRET='rotated-secret-22bb'

  run run_phase2_stage 10-acme.sh
  [ "$status" -eq 0 ]

  local body
  body=$(cat "$(credentials_file)")
  [[ "${body}" == *'ME_Key=rotated-key-11aa'* ]]
  [[ "${body}" == *'ME_Secret=rotated-secret-22bb'* ]]
  [[ "${body}" != *"${ME_KEY}"* ]]
  [[ "${body}" != *"${ME_SECRET}"* ]]
}

@test "10-acme stops when a credential in the environment is set but empty" {
  export PVE_DNSMADEEASY_SECRET=''

  run run_phase2_stage 10-acme.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *'PVE_DNSMADEEASY_SECRET is set in the environment but empty'* ]]
  [ ! -f "$(credentials_file)" ]
}

@test "_acme_san_covers lets a wildcard stand for exactly one label" {
  run _acme_san_covers 'host.example.net' '*.example.net'
  [ "$status" -eq 0 ]
  run _acme_san_covers 'host.sub.example.net' '*.example.net'
  [ "$status" -ne 0 ]
  run _acme_san_covers 'example.net' '*.example.net'
  [ "$status" -ne 0 ]
  # A trailing root dot and a difference of case are both forms a
  # certificate may legitimately carry.
  run _acme_san_covers 'HOST.example.net.' '*.Example.NET'
  [ "$status" -eq 0 ]
}

@test "10-acme orders again when a wildcard covers only a shallower name" {
  export PVE_HOSTNAME='pve1' PVE_DOMAIN='sub.example.net'
  export PVE_FQDN='pve1.sub.example.net'
  run_phase2_stage 10-acme.sh
  seed_cert 'CN=*.example.net' '*.example.net' \
    "C=US,O=(STAGING) Let's Encrypt,CN=(STAGING) Wannabe Watercress R11"
  : >"${PVE_CONFIG_MOCK_LOG}"

  run run_phase2_stage 10-acme.sh
  [ "$status" -eq 0 ]
  [[ "$(mock_calls)" == *'pvenode acme cert order'* ]]
}

@test "_acme_issuer_environment reads a lookalike CA as neither directory" {
  run _acme_issuer_environment "C=US,O=Not LetsEncrypt Services,CN=R11"
  [ "$status" -eq 0 ]
  [ "$output" = 'other' ]
  run _acme_issuer_environment "C=US,O=Lets Encrypt Compatible CA,CN=R11"
  [ "$output" = 'other' ]
  run _acme_issuer_environment "C=US,O=Let's Encrypt,CN=R11"
  [ "$output" = 'production' ]
  run _acme_issuer_environment "C=US,O=(STAGING) Let's Encrypt,CN=x"
  [ "$output" = 'staging' ]
}

@test "10-acme orders again when a lookalike CA issued the certificate" {
  # Production, because that is where a CA nobody chose does the damage: a
  # certificate the stage accepts is one the operator is left trusting.
  export PVE_ACME_ENVIRONMENT='production'
  run_phase2_stage 10-acme.sh
  seed_cert "CN=${PVE_FQDN}" "${PVE_FQDN}" \
    "C=US,O=Not LetsEncrypt Services,CN=R11"
  : >"${PVE_CONFIG_MOCK_LOG}"

  run run_phase2_stage 10-acme.sh
  [ "$status" -eq 0 ]
  [[ "$(mock_calls)" == *'pvenode acme cert order'* ]]
}

@test "10-acme reads a certificate whose fields carry commas and brackets" {
  run_phase2_stage 10-acme.sh
  export PVE_CONFIG_MOCK_CERT_INFO='raw'
  export PVE_CONFIG_MOCK_CERT_RAW="[{\"filename\":\"pveproxy-ssl.pem\",\"subject\":\"CN=other.example.net, OU=a] bracket, O=x\",\"san\":[\"${PVE_FQDN}\"],\"issuer\":\"C=US,O=(STAGING) Let's Encrypt,CN=(STAGING) R11\",\"notafter\":$(($(date +%s) + 90 * 86400))}]"
  : >"${PVE_CONFIG_MOCK_LOG}"

  run run_phase2_stage 10-acme.sh
  [ "$status" -eq 0 ]
  [[ "$(mock_calls)" != *'pvenode acme cert order'* ]]
}

@test "10-acme refuses to order when one filename appears twice" {
  run_phase2_stage 10-acme.sh
  local notafter=$(($(date +%s) + 90 * 86400))
  export PVE_CONFIG_MOCK_CERT_INFO='raw'
  export PVE_CONFIG_MOCK_CERT_RAW="[{\"filename\":\"pveproxy-ssl.pem\",\"subject\":\"CN=${PVE_FQDN}\",\"san\":[\"${PVE_FQDN}\"],\"issuer\":\"C=US,O=(STAGING) Let's Encrypt,CN=x\",\"notafter\":${notafter}},{\"filename\":\"pveproxy-ssl.pem\",\"subject\":\"CN=other\",\"san\":[\"other.example.net\"],\"issuer\":\"C=US,O=Other,CN=x\",\"notafter\":${notafter}}]"
  : >"${PVE_CONFIG_MOCK_LOG}"

  run run_phase2_stage 10-acme.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *'Unable to read the certificates on this node'* ]]
  [[ "$(mock_calls)" != *'pvenode acme cert order'* ]]
}

@test "10-acme refuses to order when the listing decodes to the wrong shape" {
  run_phase2_stage 10-acme.sh
  export PVE_CONFIG_MOCK_CERT_INFO='raw'
  # Valid JSON, and not the array of certificates pvenode returns.
  export PVE_CONFIG_MOCK_CERT_RAW='{"filename":"pveproxy-ssl.pem"}'
  : >"${PVE_CONFIG_MOCK_LOG}"

  run run_phase2_stage 10-acme.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *'Unable to read the certificates on this node'* ]]
  [[ "$(mock_calls)" != *'pvenode acme cert order'* ]]
}

@test "10-acme refuses to order when a certificate field is the wrong type" {
  run_phase2_stage 10-acme.sh
  export PVE_CONFIG_MOCK_CERT_INFO='raw'
  export PVE_CONFIG_MOCK_CERT_RAW="[{\"filename\":\"pveproxy-ssl.pem\",\"subject\":\"CN=${PVE_FQDN}\",\"san\":\"${PVE_FQDN}\",\"issuer\":\"C=US,O=(STAGING) Let's Encrypt,CN=x\",\"notafter\":$(($(date +%s) + 90 * 86400))}]"
  : >"${PVE_CONFIG_MOCK_LOG}"

  run run_phase2_stage 10-acme.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *'Unable to read the certificates on this node'* ]]
  [[ "$(mock_calls)" != *'pvenode acme cert order'* ]]
}

@test "10-acme reconfigures a node whose ACME settings only resemble these" {
  run_phase2_stage 10-acme.sh
  # Every field here contains what the stage wants as a substring and is a
  # different value: another account, another domain, another plugin.
  printf 'acme=xaccount=staging-extra\nacmedomain0=evilpve1.example.net,plugin=dnsmadeeasy-extra\n' \
    >"${PVE_CONFIG_MOCK_STATE}/node-config"
  : >"${PVE_CONFIG_MOCK_LOG}"

  run run_phase2_stage 10-acme.sh
  [ "$status" -eq 0 ]
  [[ "$(mock_calls)" == *'pvenode config set --acme account=staging --acmedomain0 pve1.example.net,plugin=dnsmadeeasy'* ]]
}

@test "10-acme names the decoder it needs when perl cannot be reached" {
  # A perl that is not there, or one without the core modules, must not
  # read as a host whose certificates cannot be inspected.
  local bin="${BATS_TEST_TMPDIR}/noperl"
  mkdir -p "${bin}"
  printf '#!/usr/bin/env bash\nexit 127\n' >"${bin}/perl"
  chmod +x "${bin}/perl"
  PATH="${bin}:${PATH}"
  export PATH

  run run_phase2_stage 10-acme.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *'perl and JSON::PP'* ]]
  [[ "$(mock_calls)" != *'pvenode acme cert order'* ]]
}

@test "10-acme ignores a trace prefix an operator asked the driver for" {
  # PVE_CONFIG_TRACE_PREFIX hands the prefix back to an operator debugging
  # an ordinary stage. It is not a way to re-arm the leak here: this stage
  # replaces PS4 whatever the variable says, for as long as a credential
  # is reachable.
  export PVE_CONFIG_SECRET_KEYS='PVE_DNSMADEEASY_KEY PVE_DNSMADEEASY_SECRET'
  # shellcheck disable=SC2016  # the expansions are for the stage's shell
  export PVE_CONFIG_TRACE_PREFIX='+HOSTILE[${ACME_ME_SECRET:-}${credentials:-}${_ACME_BOOT_SECRET:-}] '

  run env "PS4=${PVE_CONFIG_TRACE_PREFIX}" \
    bash -x "${REPO_ROOT}/stages/phase2/10-acme.sh"
  [ "$status" -eq 0 ]
  [[ "$output" != *"${ME_KEY}"* ]]
  [[ "$output" != *"${ME_SECRET}"* ]]

  # The prefix is gone from every line the stage traced, not merely
  # harmless because the variables it names happen to be empty by then.
  local line
  while IFS= read -r line; do
    [[ "${line}" == *'HOSTILE'* ]] || continue
    [[ "${line}" == *'set -euo pipefail'* ||
      "${line}" == *'case'* ||
      "${line}" == *'_ACME_BOOT_XTRACE='* ||
      "${line}" == *'set +x'* ]]
  done <<<"$output"
}

# The decoder's own answers. Each of these is a document a host could
# really print -- a field that is null because nothing filled it in, a
# number where a string was expected, bytes that are not UTF-8 -- and
# each of them used to read as an answer rather than as a failure.
@test "the decoder refuses a null where a string belongs" {
  run _acme_json_cmd scalar directory -- printf '{"directory":null}'
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "the decoder refuses a number where a string belongs" {
  run _acme_json_cmd scalar directory -- printf '{"directory":123}'
  [ "$status" -eq 2 ]
}

@test "the decoder tells a missing field from a malformed one" {
  run _acme_json_cmd scalar directory -- printf '{"other":"x"}'
  [ "$status" -eq 1 ]
}

@test "the decoder refuses bytes that are not UTF-8" {
  run _acme_json_cmd scalar directory -- printf '{"directory":"\xc3\x28"}'
  [ "$status" -eq 2 ]
}

@test "the decoder refuses a listing whose filename is not a string" {
  # Not "the certificate is absent from this listing": a listing this
  # code cannot read says nothing about what is in it.
  run _acme_json_cmd entry pveproxy-ssl.pem -- printf '[{"filename":null}]'
  [ "$status" -eq 2 ]
}

@test "the decoder refuses the output of a command that failed" {
  # Valid JSON and a non-zero exit. A command that merely printed
  # nothing would fail the decode as well, and would not prove that the
  # command's own status is looked at at all.
  run _acme_json_cmd scalar directory -- \
    bash -c 'printf "{\"directory\":\"https://example.net\"}"; exit 3'
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "the decoder sees a NUL byte the shell would have dropped" {
  # A NUL cannot survive a shell variable: bash drops it and the text
  # either side closes up, so this issuer would arrive at the issuer
  # check as the exact string that check accepts. The document reaches
  # perl on a pipe instead, where the byte is still there to be refused.
  run bash -c "source '${REPO_ROOT}/lib/common.sh'; source '${REPO_ROOT}/lib/acme.sh'; _acme_json_cmd entry a -- printf '%b' '[{\"filename\":\"a\",\"notafter\":99,\"issuer\":\"C=US,O=(STAGING) Let'\"'\"'s Encrypt\\0000 and friends\",\"san\":[\"a\"]}]'"
  [ "$status" -eq 2 ]
}

@test "10-acme refuses to order when the certificate listing hides a NUL" {
  export PVE_CONFIG_MOCK_RAW_CERT_INFO="[{\"filename\":\"pveproxy-ssl.pem\",\"notafter\":$(($(date +%s) + 86400 * 90)),\"issuer\":\"C=US,O=(STAGING) Let's Encrypt\\0000 and friends\",\"san\":[\"pve1.example.net\"],\"subject\":\"CN=pve1.example.net\"}]"

  run run_phase2_stage 10-acme.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *'Unable to read the certificates'* ]]
  [[ "$(mock_calls)" != *'pvenode acme cert order'* ]]
}

@test "10-acme orders when the certificate listing carries no SAN list" {
  # Read, understood, and the answer is that this certificate covers
  # nothing that was asked for. A decoded no may order; only a read that
  # failed may not.
  export PVE_CONFIG_MOCK_RAW_CERT_INFO="[{\"filename\":\"pveproxy-ssl.pem\",\"notafter\":$(($(date +%s) + 86400 * 90)),\"issuer\":\"C=US,O=(STAGING) Let's Encrypt,CN=R11\",\"subject\":\"CN=pve1.example.net\"}]"

  run run_phase2_stage 10-acme.sh
  [ "$status" -eq 0 ]
  [[ "$(mock_calls)" == *'pvenode acme cert order'* ]]
}

@test "10-acme refuses to register when the account listing cannot be read" {
  export PVE_CONFIG_MOCK_RAW_ACCOUNT_LIST='@fail'

  run run_phase2_stage 10-acme.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *'Unable to read the ACME accounts'* ]]
  [[ "$(mock_calls)" != *'pvenode acme account register'* ]]
  [[ "$(mock_calls)" != *'pvenode acme cert order'* ]]
}

@test "10-acme refuses to register when the account listing is malformed" {
  export PVE_CONFIG_MOCK_RAW_ACCOUNT_LIST='[{"name":null}]'

  run run_phase2_stage 10-acme.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *'Unable to read the ACME accounts'* ]]
  [[ "$(mock_calls)" != *'pvenode acme account register'* ]]
}

@test "10-acme refuses to go on when an account's directory cannot be read" {
  # The account is there; which CA it is bound to is unreadable. Treating
  # that as "no directory recorded" accepted the account, and the next
  # order would have gone to whichever CA it really belongs to.
  export PVE_CONFIG_MOCK_RAW_ACCOUNT_LIST='[{"name":"staging"}]'
  export PVE_CONFIG_MOCK_RAW_ACCOUNT_INFO='{"directory":null}'

  run run_phase2_stage 10-acme.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *'could not be read'* ]]
  [[ "$(mock_calls)" != *'pvenode acme cert order'* ]]
}

@test "10-acme refuses to overwrite plugin credentials it could not read" {
  export PVE_CONFIG_MOCK_RAW_PLUGIN_LIST='[{"plugin":"dnsmadeeasy"}]'
  export PVE_CONFIG_MOCK_RAW_PLUGIN_CONFIG='{"api":"me","data":null}'

  run run_phase2_stage 10-acme.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *'Refusing to overwrite'* ]]
  [[ "$output" != *"${ME_KEY}"* ]]
  [[ "$output" != *"${ME_SECRET}"* ]]
  [[ "$(mock_calls)" != *'pvenode acme plugin set'* ]]
}

@test "10-acme refuses to write node settings it could not compare" {
  export PVE_CONFIG_MOCK_RAW_NODE_CONFIG='{"acme":123}'

  run run_phase2_stage 10-acme.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *'Unable to read the ACME settings'* ]]
  [[ "$(mock_calls)" != *'pvenode config set'* ]]
  [[ "$(mock_calls)" != *'pvenode acme cert order'* ]]
}

@test "_acme_issuer_environment refuses a name that ends in an escape" {
  # A terminal backslash escapes nothing, so the name is malformed.
  # Dropping it quietly turned this into the production organisation.
  run _acme_issuer_environment "C=US,O=Let's Encrypt\\"
  [ "$status" -eq 0 ]
  [ "$output" = 'other' ]
}

@test "acme_cert_is_current refuses a certificate whose issuer will not parse" {
  seed_cert 'CN=pve1.example.net' 'pve1.example.net' \
    "C=US,O=Let's Encrypt\\" 90

  run acme_cert_is_current 'pve1.example.net' production
  [ "$status" -eq 1 ]
}

# A fresh host must read as "nothing here yet", never as "unreadable":
# aborting on an empty state would turn a first run into a hard failure.
@test "an empty account list reads as no account rather than unreadable" {
  run acme_account_exists staging
  [ "$status" -eq 1 ]
}

@test "a host with no ACME certificate reads as no certificate" {
  # What pvenode lists on a host that has only the self signed pair the
  # installer made: a listing that decodes, without the file asked for.
  run acme_cert_is_current 'pve1.example.net' staging
  [ "$status" -eq 1 ]
}

@test "a node with no ACME settings reads as not configured" {
  run _acme_node_config_matches 'pve1.example.net' dnsmadeeasy staging
  [ "$status" -eq 1 ]
}

# These two seed the plugin as present before they break the listing.
# An absent plugin would not prove anything: `pvenode acme plugin config`
# exits 2 for a plugin that is missing just as it does for a backend that
# failed, so a boolean implementation reading the config would abort here
# by accident and the test would pass without the fix.
@test "10-acme refuses to touch a plugin when the plugin listing cannot be read" {
  # A plugin that could not be looked up is neither absent nor compared.
  # Acting on the strength of that failure puts the credentials into a
  # configuration nobody read.
  run_phase2_stage 10-acme.sh >/dev/null
  rm -f "${PVE_CONFIG_MOCK_LOG}"
  export PVE_CONFIG_MOCK_RAW_PLUGIN_LIST='@fail'

  run run_phase2_stage 10-acme.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *'Unable to read the ACME DNS plugins'* ]]
  [[ "$output" != *"${ME_KEY}"* ]]
  [[ "$output" != *"${ME_SECRET}"* ]]
  [[ "$(mock_calls)" != *'pvenode acme plugin add'* ]]
  [[ "$(mock_calls)" != *'pvenode acme plugin set'* ]]
  [[ "$(mock_calls)" != *'pvenode acme cert order'* ]]
}

@test "10-acme refuses to touch a plugin when the plugin listing is malformed" {
  run_phase2_stage 10-acme.sh >/dev/null
  rm -f "${PVE_CONFIG_MOCK_LOG}"
  export PVE_CONFIG_MOCK_RAW_PLUGIN_LIST='[{"plugin":null}]'

  run run_phase2_stage 10-acme.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *'Unable to read the ACME DNS plugins'* ]]
  [[ "$(mock_calls)" != *'pvenode acme plugin add'* ]]
  [[ "$(mock_calls)" != *'pvenode acme plugin set'* ]]
}

@test "10-acme reconfigures a plugin pointed at another provider" {
  # The credentials match; the api does not. The hook that runs with
  # these credentials is chosen by the api, so this node is misconfigured
  # -- and `pvenode acme cert order` is not idempotent, so leaving it
  # alone means ordering and failing on every run from here on.
  run_phase2_stage 10-acme.sh >/dev/null
  local state="${PVE_CONFIG_MOCK_STATE}/acme-plugin-dnsmadeeasy"
  local id api data
  read -r id api data <"${state}"
  [ "${api}" = 'me' ]
  printf '%s cf %s\n' "${id}" "${data}" >"${state}"
  rm -f "${PVE_CONFIG_MOCK_LOG}"

  run run_phase2_stage 10-acme.sh
  [ "$status" -eq 0 ]
  [[ "$(mock_calls)" == *'pvenode acme plugin set dnsmadeeasy --api me --data'* ]]
  [[ "$output" == *'configured the ACME DNS plugin dnsmadeeasy'* ]]
}

# Bash drops a NUL from a command substitution and the text either side
# closes up, so credentials stored with one would compare equal to the
# credentials that were wanted and a corrupted plugin would be left in
# place, reported as converged.
@test "10-acme refuses credentials that carry a NUL byte" {
  local corrupted
  corrupted=$(printf 'ME_Key=%s\0\nME_Secret=%s\n' "${ME_KEY}" "${ME_SECRET}" |
    base64 -w0)
  export PVE_CONFIG_MOCK_RAW_PLUGIN_LIST='[{"plugin":"dnsmadeeasy"}]'
  export PVE_CONFIG_MOCK_RAW_PLUGIN_CONFIG="{\"api\":\"me\",\"data\":\"${corrupted}\"}"

  run run_phase2_stage 10-acme.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *'Refusing to overwrite'* ]]
  [[ "$output" != *"${ME_KEY}"* ]]
  [[ "$output" != *"${ME_SECRET}"* ]]
  [[ "$(mock_calls)" != *'pvenode acme plugin set'* ]]
}

# Both managed node settings are read before either is compared. Deciding
# on the first one leaves the second unread, and the write that follows
# covers a setting nobody could read.
@test "10-acme refuses a node whose acmedomain0 cannot be read" {
  export PVE_CONFIG_MOCK_RAW_NODE_CONFIG='{"acme":"account=other","acmedomain0":null}'

  run run_phase2_stage 10-acme.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *'Unable to read the ACME settings'* ]]
  [[ "$(mock_calls)" != *'pvenode config set'* ]]
  [[ "$(mock_calls)" != *'pvenode acme cert order'* ]]
}

@test "10-acme refuses to overwrite a plugin whose provider it could not read" {
  export PVE_CONFIG_MOCK_RAW_PLUGIN_LIST='[{"plugin":"dnsmadeeasy"}]'
  export PVE_CONFIG_MOCK_RAW_PLUGIN_CONFIG='{"api":null,"data":"x"}'

  run run_phase2_stage 10-acme.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *'which provider it is configured for could not be read'* ]]
  [[ "$output" != *"${ME_SECRET}"* ]]
  [[ "$(mock_calls)" != *'pvenode acme plugin set'* ]]
}
