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

  # The community-scripts pins belong to the toolkit, in
  # lib/community-scripts.sh. A per-deployment key here would be a second
  # answer to the same question, and the one an operator would edit.
  run grep -n "^#\? *PVE_COMMUNITY_SCRIPTS_" \
    "${REPO_ROOT}/examples/pve-config.conf.example"
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

# --- the Tailscale keys ----------------------------------------------------

# shellcheck disable=SC2016  # the payload must stay literal to be a payload
@test "a Tailscale route list that is not IPv4 CIDRs is rejected" {
  local value
  # A route reaches --advertise-routes and a script generated inside the
  # container, so a value carrying shell is refused here, not there.
  for value in '192.168.1.0' '192.168.1.0/33' '256.0.0.0/8' \
    '10.0.0.0/24,bogus' '10.0.0.0/24;id' '$(id)/24' '10.0.0.0/8/8' \
    '10.0.0/24' 'fd00::/8'; do
    run _schema_validate_PVE_TAILSCALE_ROUTES "${value}"
    [ "$status" -ne 0 ] || {
      echo "accepted: ${value}"
      return 1
    }
  done
}

@test "an ordinary Tailscale route list is accepted" {
  local value
  for value in '192.168.1.0/24' '10.0.0.0/8,172.16.4.0/22' '0.0.0.0/0' \
    '10.0.0.0/24, 10.1.0.0/24'; do
    run _schema_validate_PVE_TAILSCALE_ROUTES "${value}"
    [ "$status" -eq 0 ] || {
      echo "rejected: ${value}"
      return 1
    }
  done
}

# shellcheck disable=SC2016  # the payload must stay literal to be a payload
@test "an adoption gate that is neither yes nor no is rejected" {
  local value
  export PVE_TAILSCALE_CTID=110
  for value in 'true' 'Yes' 'YES' '1' 'y' 'no thanks' '$(id)'; do
    run _schema_validate_PVE_TAILSCALE_ADOPT_EXISTING "${value}"
    [ "$status" -ne 0 ] || {
      echo "accepted: ${value}"
      return 1
    }
  done
  run _schema_validate_PVE_TAILSCALE_ADOPT_EXISTING no
  [ "$status" -eq 0 ]
  run _schema_validate_PVE_TAILSCALE_ADOPT_EXISTING yes
  [ "$status" -eq 0 ]
}

@test "adoption without a container to adopt is rejected" {
  unset PVE_TAILSCALE_CTID
  run _schema_validate_PVE_TAILSCALE_ADOPT_EXISTING yes
  [ "$status" -ne 0 ]
  [[ "$output" == *'PVE_TAILSCALE_CTID'* ]]
}

# shellcheck disable=SC2016  # the payload must stay literal to be a payload
@test "a Tailscale container id that is not a usable VMID is rejected" {
  local value
  # The value reaches an arithmetic comparison and a pct argument.
  for value in '99' '0' 'a[$(id)]' '100; id' '1e3' '-1' ' 100'; do
    run _schema_validate_PVE_TAILSCALE_CTID "${value}"
    [ "$status" -ne 0 ] || {
      echo "accepted: ${value}"
      return 1
    }
  done
  run _schema_validate_PVE_TAILSCALE_CTID 100
  [ "$status" -eq 0 ]
}

# shellcheck disable=SC2016  # the payload must stay literal to be a payload
@test "a storage name Proxmox would not accept is rejected" {
  local name value
  for name in PVE_TAILSCALE_STORAGE PVE_TAILSCALE_TEMPLATE_STORAGE \
    PVE_TAILSCALE_CONTAINER_STORAGE; do
    for value in '-local' '1local' 'local lvm' 'local;id' '$(id)' 'local/lvm'; do
      run "_schema_validate_${name}" "${value}"
      [ "$status" -ne 0 ] || {
        echo "accepted: ${name}=${value}"
        return 1
      }
    done
    run "_schema_validate_${name}" 'local-zfs'
    [ "$status" -eq 0 ] || {
      echo "rejected: ${name}=local-zfs"
      return 1
    }
  done
}

# shellcheck disable=SC2016  # the payload must stay literal to be a payload
@test "a Tailscale resource size that is not a positive number is rejected" {
  local name value
  for name in PVE_TAILSCALE_RAM_MB PVE_TAILSCALE_CORES PVE_TAILSCALE_DISK_GB; do
    for value in '0' '-1' '1.5' 'a[$(id)]' '256; id' '2G'; do
      run "_schema_validate_${name}" "${value}"
      [ "$status" -ne 0 ] || {
        echo "accepted: ${name}=${value}"
        return 1
      }
    done
    run "_schema_validate_${name}" '2'
    [ "$status" -eq 0 ] || {
      echo "rejected: ${name}=2"
      return 1
    }
  done
}

@test "a keyring pin that is not a SHA-256 is rejected" {
  local value
  for value in 'deadbeef' "$(printf '%064d' 0)x" 'z1c7e09d7e4b1b24d1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1' ''; do
    run _schema_validate_PVE_TAILSCALE_KEYRING_SHA256 "${value}"
    [ "$status" -ne 0 ] || {
      echo "accepted: ${value}"
      return 1
    }
  done
  run _schema_validate_PVE_TAILSCALE_KEYRING_SHA256 \
    '3e03dacf222698c60b8e2f990b809ca1b3e104de127767864284e6c228f1fb39'
  [ "$status" -eq 0 ]
  # Hex is hex whichever case it is written in.
  run _schema_validate_PVE_TAILSCALE_KEYRING_SHA256 \
    '3E03DACF222698C60B8E2F990B809CA1B3E104DE127767864284E6C228F1FB39'
  [ "$status" -eq 0 ]
}

@test "schema_resolve rejects a Tailscale route list it cannot read as CIDRs" {
  export PVE_HOSTNAME='pve1' PVE_DOMAIN='example.test'
  export PVE_TAILSCALE_ENABLED='yes'
  export PVE_TAILSCALE_ROUTES='192.168.1.0'
  run resolve_names
  [ "$status" -ne 0 ]
  [[ "$output" == *'PVE_TAILSCALE_ROUTES'* ]]
}

@test "schema_resolve rejects an adoption gate that is neither yes nor no" {
  export PVE_HOSTNAME='pve1' PVE_DOMAIN='example.test'
  export PVE_TAILSCALE_ENABLED='yes'
  export PVE_TAILSCALE_CTID='110'
  export PVE_TAILSCALE_ADOPT_EXISTING='true'
  run resolve_names
  [ "$status" -ne 0 ]
  [[ "$output" == *'PVE_TAILSCALE_ADOPT_EXISTING'* ]]
  [[ "$output" == *'true'* ]]
}

@test "schema_resolve leaves the optional Tailscale keys unset and unprompted" {
  export PVE_HOSTNAME='pve1' PVE_DOMAIN='example.test'
  resolve_names
  [ -z "${PVE_TAILSCALE_CTID:-}" ]
  [ -z "${PVE_TAILSCALE_ROUTES:-}" ]
  [ -z "${PVE_TAILSCALE_TEMPLATE_STORAGE:-}" ]
  [ "${PVE_TAILSCALE_ADOPT_EXISTING}" = 'no' ]
}
