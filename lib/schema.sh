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
PVE_ADMIN_KEY_SOURCE|no|yes||Admin SSH public key, either a literal ssh-... string or a path to a file holding one
PVE_SUITE|no|yes|detect_debian_suite|Debian suite for the Proxmox apt sources
EOF
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
    die "Missing required configuration: ${missing[*]}. Set them in the config file or the environment, or run without --non-interactive."
  fi
}
