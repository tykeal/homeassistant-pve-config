#!/usr/bin/env bats
# Every @test runs in its own subshell, so the exports these tests use to
# vary the configuration cannot leak into one another; shellcheck's
# subshell-scope warnings describe a hazard that does not exist here.
# shellcheck disable=SC2030,SC2031
# SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
# SPDX-License-Identifier: Apache-2.0

load helpers/test_helper

setup() {
  load_libs
  isolate_env
}

@test "every schema key is named so the parser will load it" {
  local key
  while IFS= read -r key; do
    [[ ${key} =~ ^PVE_[A-Z0-9_]+$ ]] || {
      echo "schema key ${key} would be rejected by the config parser"
      return 1
    }
  done < <(schema_keys)
}

@test "the configuration example documents every schema key" {
  local example="${REPO_ROOT}/examples/pve-config.conf.example"
  local key
  while IFS= read -r key; do
    grep -q "^#\? *${key}=" "${example}" || {
      echo "${key} is in the schema but missing from the example"
      return 1
    }
  done < <(schema_entries | awk -F'|' '$2 == "no" { print $1 }')
}

@test "the examples do not offer keys the toolkit no longer reads" {
  # vmbr0 is fixed by convention, so a PVE_BRIDGE in the example would be a
  # setting that silently does nothing.
  run grep -n "^#\? *PVE_BRIDGE=" "${REPO_ROOT}/examples/pve-config.conf.example"
  [ "$status" -ne 0 ]
}

@test "no secret is declared in the configuration schema" {
  local secrets
  secrets=$(schema_entries | awk -F'|' '$2 == "yes" { print $1 }')
  [ -z "${secrets}" ]
}

@test "the secrets example carries the Zulip credentials the stage needs" {
  local example="${REPO_ROOT}/examples/secrets.env.example"
  local key
  for key in PVE_ZULIP_SITE PVE_ZULIP_BOT_EMAIL PVE_ZULIP_BOT_API_KEY; do
    grep -q "^${key}=" "${example}"
  done
  # A credential must never arrive with a usable default.
  grep -q "^PVE_ZULIP_BOT_API_KEY=''" "${example}"
}

@test "the derivations cover everything a host can answer for itself" {
  local key derive
  while IFS='|' read -r key _ _ derive _; do
    case ${key} in
      PVE_HOSTNAME | PVE_FQDN | PVE_SUITE | PVE_BRIDGE_PORTS)
        [ -n "${derive}" ] || {
          echo "${key} is derivable but would be prompted for"
          return 1
        }
        ;;
    esac
  done < <(schema_entries)
}

# --- bridge ports ---------------------------------------------------------

@test "the schema derives the bridge port from the uplink" {
  seed_nics eno1 eno2
  seed_default_route eno2
  run _schema_derive_bridge_ports
  [ "$status" -eq 0 ]
  [ "$output" = 'eno2' ]
}

@test "the schema demands bridge ports when no uplink can be identified" {
  seed_nics eno1 eno2
  seed_default_route
  export PVE_CONFIG_OS_RELEASE="${BATS_TEST_TMPDIR}/os-release"
  printf 'VERSION_CODENAME=trixie\n' >"${PVE_CONFIG_OS_RELEASE}"
  export PVE_DOMAIN='example.test' PVE_ADMIN_USERS='admin'
  export PVE_ADMIN_KEY_SOURCE='ssh-ed25519 AAAA admin@example.test'
  run env NON_INTERACTIVE=1 bash -c "
    source '${REPO_ROOT}/lib/common.sh'
    source '${REPO_ROOT}/lib/config.sh'
    source '${REPO_ROOT}/lib/detect.sh'
    source '${REPO_ROOT}/lib/schema.sh'
    schema_resolve"
  [ "$status" -ne 0 ]
  [[ "$output" == *'PVE_BRIDGE_PORTS'* ]]
  # The operator is told what the host does have, rather than being left to
  # guess which name the toolkit wanted.
  [[ "$output" == *eno1* ]]
  [[ "$output" == *eno2* ]]
}

@test "an explicit bridge port list overrides detection" {
  seed_nics eno1 eno2
  seed_default_route eno1
  export PVE_CONFIG_OS_RELEASE="${BATS_TEST_TMPDIR}/os-release"
  printf 'VERSION_CODENAME=trixie\n' >"${PVE_CONFIG_OS_RELEASE}"
  export PVE_DOMAIN='example.test' PVE_ADMIN_USERS='admin'
  export PVE_ADMIN_KEY_SOURCE='ssh-ed25519 AAAA admin@example.test'
  export PVE_BRIDGE_PORTS='eno2'
  NON_INTERACTIVE=1 schema_resolve
  [ "${PVE_BRIDGE_PORTS}" = 'eno2' ]
}
