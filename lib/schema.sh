#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
# SPDX-License-Identifier: Apache-2.0

# The configuration schema.
#
# Stages run as child processes, so a value a stage resolves cannot flow
# back to the driver and be saved. The driver therefore resolves the whole
# schema up front: it derives what the host can tell it, asks for the rest
# once, writes the answers out, and exports them. Every run after the first
# is unattended.
#
# Record format, one key per line, pipe separated:
#
#   NAME|secret|required|derivation|prompt
#
# secret and required are yes or no. derivation names a function (usually
# from lib/detect.sh) that prints a default, or is empty when there is
# nothing to derive.

schema_entries() {
  cat <<'EOF'
PVE_HOSTNAME|no|yes|detect_hostname_short|Short hostname for this Proxmox host
PVE_DOMAIN|no|yes||DNS domain for this deployment, for example example.net
PVE_FQDN|no|yes|_schema_derive_fqdn|Fully qualified domain name for this host
PVE_ADMIN_USERS|no|yes||Space separated admin usernames to create
PVE_ADMIN_KEY_SOURCE|no|no||Admin SSH public key shared by every admin, either a literal ssh-... string or a path to a file holding one
PVE_SUITE|no|yes|detect_debian_suite|Debian suite for the Proxmox apt sources
PVE_BRIDGE_PORTS|no|yes|_schema_derive_bridge_ports|Physical interfaces to enslave to vmbr0, space separated
PVE_BRIDGE_MODE|no|yes|_schema_default_dhcp|Addressing for vmbr0, dhcp or static
PVE_BRIDGE_ADDRESS|no|no||Static CIDR address for vmbr0, only read when the mode is static
PVE_BRIDGE_GATEWAY|no|no||Default gateway for vmbr0, only read when the mode is static
PVE_NETWORK_WAIT_SECONDS|no|yes|_schema_default_wait|Seconds to wait for vmbr0 to pick up an address
PVE_NO_SUBSCRIPTION|no|yes|_schema_default_yes|Use the no-subscription repository and suppress the subscription notice
PVE_SUDO_SSH_AGENT|no|yes|_schema_default_yes|Allow sudo to accept a forwarded SSH agent key
PVE_ZULIP_ENABLED|no|yes|_schema_default_no|Send boot and shutdown notices to Zulip
PVE_ZULIP_STREAM|no|no||Zulip stream for boot and shutdown notices
PVE_ZULIP_TOPIC|no|no||Zulip topic for boot and shutdown notices
EOF
}

_schema_default_yes() { printf 'yes\n'; }
_schema_default_no() { printf 'no\n'; }
_schema_default_dhcp() { printf 'dhcp\n'; }
_schema_default_wait() { printf '60\n'; }

# The uplink, and only the uplink. Bridging every port the host happens to
# have risks an L2 loop between two live ports and merges networks that
# were deliberately separate, so the default route is what decides.
#
# When that is ambiguous the operator is told what was found and asked, in
# preference to this guessing and taking the host off the network.
_schema_derive_bridge_ports() {
  local -a uplinks=()
  mapfile -t uplinks < <(detect_uplink_nics 2>/dev/null) || true
  if [[ ${#uplinks[@]} -eq 1 ]]; then
    printf '%s\n' "${uplinks[0]}"
    return 0
  fi

  log_warn "$(_schema_hint_PVE_BRIDGE_PORTS)"
  return 1
}

# shellcheck disable=SC2329  # called indirectly, by name, from schema_resolve
_schema_hint_PVE_BRIDGE_PORTS() {
  local -a uplinks=() physical=()
  mapfile -t uplinks < <(detect_uplink_nics 2>/dev/null) || true
  mapfile -t physical < <(detect_physical_nics 2>/dev/null) || true
  if [[ ${#uplinks[@]} -gt 1 ]]; then
    printf 'several interfaces carry a default route (%s); name the one vmbr0 should hold\n' \
      "${uplinks[*]}"
  else
    printf 'no default route was found, so the uplink cannot be identified. Physical interfaces present: %s\n' \
      "${physical[*]:-none}"
  fi
}

# Emits the key names in declaration order.
schema_keys() {
  schema_entries | cut -d'|' -f1
}

# The answers win over whatever the resolver currently says: on a fresh host
# phase 1 is the thing that sets the identity, so the existing hostname and
# FQDN are the values being replaced. PVE_HOSTNAME and PVE_DOMAIN are
# declared ahead of PVE_FQDN, so both are resolved by the time this runs.
_schema_derive_fqdn() {
  local short=${PVE_HOSTNAME:-}
  [[ -n ${short} ]] || short=$(detect_hostname_short 2>/dev/null) || short=''
  if [[ -n ${short} && -n ${PVE_DOMAIN:-} ]]; then
    printf '%s.%s\n' "${short}" "${PVE_DOMAIN}"
    return 0
  fi
  detect_fqdn "${PVE_DOMAIN:-}"
}

# Resolves every key in the schema in the order it is declared, so a
# derivation may depend on a key resolved before it.
schema_resolve() {
  local -a entries=() missing=()
  local entry name secret required derive prompt default value from_env

  mapfile -t entries < <(schema_entries)

  for entry in ${entries[@]+"${entries[@]}"}; do
    [[ -n ${entry} ]] || continue
    IFS='|' read -r name secret required derive prompt <<<"${entry}"
    [[ -n ${name} ]] || continue

    if [[ ${secret} == yes ]]; then
      config_mark_secret "${name}"
    fi

    default=''
    if [[ -n ${derive} ]] && declare -F "${derive}" >/dev/null 2>&1; then
      default=$("${derive}" 2>/dev/null) || default=''
    fi

    # Collect every unanswerable key before giving up, so an unattended run
    # reports all of them at once instead of one per attempt.
    if ! config_has "${name}" && [[ ${NON_INTERACTIVE:-0} == 1 ]] && [[ -z ${default} ]]; then
      if [[ ${required} == yes ]]; then
        missing+=("${name}")
      fi
      continue
    fi

    # An exported empty string is a deliberate override and is honoured as
    # given; an empty value only means "work it out" when it came from the
    # config file, where the shipped example carries blank placeholders.
    from_env=0
    if [[ -n ${!name+set} ]] && ! config_value_from_file "${name}"; then
      from_env=1
    fi

    config_get "${name}" "${default}" "${prompt}" >/dev/null
    value=${!name}

    if [[ ${from_env} == 0 && -z ${value} && -n ${default} ]]; then
      config_set "${name}" "${default}"
      value=${default}
    fi

    if [[ ${required} == yes && -z ${value} ]]; then
      missing+=("${name}")
    fi
    if [[ ${secret} == yes ]]; then
      redact_register "${value}"
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    # A key whose derivation failed can usually say why, and saying so is
    # the difference between a usable error and a name to go looking for.
    local key hint
    for key in "${missing[@]}"; do
      if declare -F "_schema_hint_${key}" >/dev/null 2>&1; then
        hint=$("_schema_hint_${key}" 2>/dev/null) || hint=''
        [[ -n ${hint} ]] && log_error "${key}: ${hint}"
      fi
    done
    die "Missing required configuration: ${missing[*]}. Set them in the config file or the environment, or run without --non-interactive."
  fi
}
