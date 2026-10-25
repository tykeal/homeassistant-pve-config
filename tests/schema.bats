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

# --- names ----------------------------------------------------------------
#
# Phase 1 writes both names into /etc/hosts and into the dhclient exit hook
# that rewrites it as root on every lease. A name that is not a name is
# rejected here, once, however it arrived.

# Everything the config parser accepts but a host name may not hold.
hostile_names() {
  cat <<'EOF'
pve1'; touch /pwned; :'
pve1$(id)
pve1`id`
pve1;id
pve1 pve2
pve_1
-pve1
pve1-
EOF
}

@test "a short hostname that is not a DNS label is rejected" {
  local name
  while IFS= read -r name; do
    run _schema_validate_PVE_HOSTNAME "${name}"
    [ "$status" -ne 0 ] || {
      echo "accepted: ${name}"
      return 1
    }
  done < <(hostile_names)

  # A newline would otherwise smuggle a whole command past a line-anchored
  # check.
  run _schema_validate_PVE_HOSTNAME "$(printf 'pve1\nid')"
  [ "$status" -ne 0 ]

  # 64 characters is one past the limit a label may have.
  local long
  long=$(printf 'a%.0s' $(seq 64))
  run _schema_validate_PVE_HOSTNAME "${long}"
  [ "$status" -ne 0 ]
}

@test "an ordinary short hostname is accepted" {
  local name
  for name in pve1 a pve-01-b PVE1 "$(printf 'a%.0s' $(seq 63))"; do
    run _schema_validate_PVE_HOSTNAME "${name}"
    [ "$status" -eq 0 ] || {
      echo "rejected: ${name}"
      return 1
    }
  done
}

@test "an FQDN that is not a domain name is rejected" {
  export PVE_HOSTNAME='pve1'
  local name
  while IFS= read -r name; do
    run _schema_validate_PVE_FQDN "${name}.example.net"
    [ "$status" -ne 0 ] || {
      echo "accepted: ${name}.example.net"
      return 1
    }
    run _schema_validate_PVE_FQDN "pve1.example.net.${name}"
    [ "$status" -ne 0 ] || {
      echo "accepted: pve1.example.net.${name}"
      return 1
    }
  done < <(hostile_names)

  run _schema_validate_PVE_FQDN "$(printf 'pve1.example.net\nid')"
  [ "$status" -ne 0 ]
  # A bare name is not qualified, so nothing downstream can resolve it.
  run _schema_validate_PVE_FQDN 'pve1'
  [ "$status" -ne 0 ]
  # An empty label, from a doubled or trailing dot.
  run _schema_validate_PVE_FQDN 'pve1..net'
  [ "$status" -ne 0 ]
  run _schema_validate_PVE_FQDN 'pve1.example.net.'
  [ "$status" -ne 0 ]
}

@test "an FQDN that contradicts the short hostname is rejected" {
  export PVE_HOSTNAME='pve1'
  run _schema_validate_PVE_FQDN 'pve2.example.net'
  [ "$status" -ne 0 ]
  [[ "$output" == *'PVE_HOSTNAME'* ]]
  # DNS does not care about case, so neither does this.
  run _schema_validate_PVE_FQDN 'PVE1.example.net'
  [ "$status" -eq 0 ]
}

@test "an ordinary FQDN is accepted" {
  export PVE_HOSTNAME='pve1'
  local name
  for name in pve1.example.net pve1.a.b.example.net pve1.example-net.test; do
    run _schema_validate_PVE_FQDN "${name}"
    [ "$status" -eq 0 ] || {
      echo "rejected: ${name}"
      return 1
    }
  done
}

# shellcheck disable=SC2016  # the payload must stay literal to be a payload
@test "a wait that is not a count of seconds is rejected" {
  local value
  # bash evaluates an array subscript inside an arithmetic operand as code,
  # and the stages compare this value with -lt.
  for value in 'a[$(id)]' '60; id' '60s' '-1' '1e3' '' ' 60'; do
    run _schema_validate_PVE_NETWORK_WAIT_SECONDS "${value}"
    [ "$status" -ne 0 ] || {
      echo "accepted: ${value}"
      return 1
    }
  done
  run _schema_validate_PVE_NETWORK_WAIT_SECONDS '86401'
  [ "$status" -ne 0 ]
}

@test "an ordinary wait is accepted" {
  local value
  for value in 0 1 60 86400; do
    run _schema_validate_PVE_NETWORK_WAIT_SECONDS "${value}"
    [ "$status" -eq 0 ] || {
      echo "rejected: ${value}"
      return 1
    }
  done
}

# Everything the driver resolves before the first stage runs, bar the names
# under test.
resolve_names() {
  export PVE_CONFIG_OS_RELEASE="${BATS_TEST_TMPDIR}/os-release"
  printf 'VERSION_CODENAME=trixie\n' >"${PVE_CONFIG_OS_RELEASE}"
  export PVE_ADMIN_USERS='admin'
  export PVE_ADMIN_KEY_SOURCE='ssh-ed25519 AAAA admin@example.test'
  export PVE_BRIDGE_PORTS='eno1'
  NON_INTERACTIVE=1 schema_resolve
}

# shellcheck disable=SC2016  # the payload must stay literal to be a payload
@test "schema_resolve rejects a hostname from the environment" {
  export PVE_HOSTNAME='pve1$(id)' PVE_DOMAIN='example.test'
  run resolve_names
  [ "$status" -ne 0 ]
  [[ "$output" == *'PVE_HOSTNAME'* ]]
  [[ "$output" == *'pve1$(id)'* ]]
}

@test "schema_resolve rejects a hostname from the config file" {
  local config="${BATS_TEST_TMPDIR}/pve-config.conf"
  printf "PVE_HOSTNAME='pve1\x60id\x60'\nPVE_DOMAIN='example.test'\n" >"${config}"
  config_load "${config}"
  run resolve_names
  [ "$status" -ne 0 ]
  [[ "$output" == *'PVE_HOSTNAME'* ]]
}

@test "schema_resolve rejects an FQDN the short hostname contradicts" {
  export PVE_HOSTNAME='pve1' PVE_DOMAIN='example.test'
  export PVE_FQDN='other.example.test'
  run resolve_names
  [ "$status" -ne 0 ]
  [[ "$output" == *'PVE_FQDN'* ]]
}

# shellcheck disable=SC2016  # the payload must stay literal to be a payload
@test "schema_resolve rejects a wait it cannot count in seconds" {
  export PVE_HOSTNAME='pve1' PVE_DOMAIN='example.test'
  export PVE_NETWORK_WAIT_SECONDS='a[$(id)]'
  run resolve_names
  [ "$status" -ne 0 ]
  [[ "$output" == *'PVE_NETWORK_WAIT_SECONDS'* ]]
}

@test "schema_resolve accepts the names it derives for itself" {
  export PVE_HOSTNAME='pve1' PVE_DOMAIN='example.test'
  run resolve_names
  [ "$status" -eq 0 ]
}
