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
PVE_ACME_ENABLED|no|yes|_schema_default_no|Order a certificate for this host over the DNS-01 challenge
PVE_ACME_ENVIRONMENT|no|yes|_schema_default_staging|ACME directory to order from, staging or production
PVE_ACME_EMAIL|no|no||Contact address for the ACME account and for expiry warnings
PVE_ACME_DNS_PLUGIN|no|yes|_schema_default_dnsmadeeasy|DNS-01 plugin name; dnsmadeeasy is the only supported provider
PVE_ACME_ACCEPT_TOS|no|yes|_schema_default_no|Accept the CA terms of service, which registering an ACME account requires
PVE_ACME_FORCE_ORDER|no|yes|_schema_default_no|Order a certificate even when a current one is present, staging only
PVE_TAILSCALE_ENABLED|no|yes|_schema_default_no|Build a Tailscale subnet router container for this node
PVE_TAILSCALE_HOSTNAME|no|yes|_schema_derive_tailscale_hostname|Hostname for the Tailscale subnet router container
PVE_TAILSCALE_CTID|no|no||Container ID for the Tailscale subnet router; blank means 100, or the next free ID
PVE_TAILSCALE_ADOPT_EXISTING|no|yes|_schema_default_no|Let the Tailscale stage take over a container it did not build, which PVE_TAILSCALE_CTID must then name
PVE_TAILSCALE_ROUTES|no|no||Subnets the router advertises, comma separated; blank means the IPv4 subnet of vmbr0
PVE_TAILSCALE_STORAGE|no|no||Storage for both the router's template and its root disk; blank means the node's only one of each kind
PVE_TAILSCALE_TEMPLATE_STORAGE|no|no||Storage for the router's container template; blank falls back to PVE_TAILSCALE_STORAGE
PVE_TAILSCALE_CONTAINER_STORAGE|no|no||Storage for the router's root disk; blank falls back to PVE_TAILSCALE_STORAGE
PVE_TAILSCALE_RAM_MB|no|no||Memory for the router in MB; blank scales to the host, between 256 and 1024
PVE_TAILSCALE_CORES|no|no||CPU cores for the router; blank scales to the host, one or two
PVE_TAILSCALE_DISK_GB|no|no||Root disk size for the router in GB; blank means 2
PVE_TAILSCALE_KEYRING_SHA256|no|no||SHA-256 the Tailscale repository signing key must have; blank means the digest pinned in this toolkit
PVE_HAOS_ENABLED|no|yes|_schema_default_no|Build a Home Assistant OS virtual machine on this node
PVE_HAOS_HOSTNAME|no|yes|_schema_default_haos_hostname|Hostname for the Home Assistant OS virtual machine
PVE_HAOS_VMID|no|no||Guest ID for the Home Assistant OS machine; blank means 200, or the next free ID
PVE_HAOS_ADOPT_EXISTING|no|yes|_schema_default_no|Let the HAOS stage take over a machine it did not build, which PVE_HAOS_VMID must then name
PVE_HAOS_STORAGE|no|no||Storage for the appliance's disks; blank means the node's only one that takes disk images
PVE_HAOS_RAM_MB|no|no||Memory for the appliance in MB; blank scales to the host, between 2048 and 8192
PVE_HAOS_CORES|no|no||CPU cores for the appliance; blank scales to the host, between 2 and 4
PVE_HAOS_DISK_GB|no|no||Disk size for the appliance in GB; blank means 32, which is the published image
PVE_HAOS_VERSION|no|no||Home Assistant OS release to install; blank means the release pinned in this toolkit
PVE_HAOS_IMAGE_SHA256|no|no||SHA-256 the Home Assistant OS disk image must have; blank means the digest pinned in this toolkit
PVE_ZULIP_ENABLED|no|yes|_schema_default_no|Send boot and shutdown notices to Zulip
PVE_ZULIP_STREAM|no|no||Zulip stream for boot and shutdown notices
PVE_ZULIP_TOPIC|no|no||Zulip topic for boot and shutdown notices
EOF
}

_schema_default_yes() { printf 'yes\n'; }
_schema_default_no() { printf 'no\n'; }
_schema_default_dhcp() { printf 'dhcp\n'; }
_schema_default_wait() { printf '60\n'; }

# Staging, every time, until a deployment asks for production. The
# production directory counts failed orders against a weekly limit, so a
# first run that is wrong there costs the deployment a week; the same run
# against staging costs nothing.
_schema_default_staging() { printf 'staging\n'; }
_schema_default_dnsmadeeasy() { printf 'dnsmadeeasy\n'; }

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

# --- validation -----------------------------------------------------------
#
# A key may declare a _schema_validate_<KEY> function. schema_resolve calls
# it with the resolved value, whatever the value came from, so a derived
# answer, a config file, an environment override and a prompt are all held
# to the same rule. The function prints why it refused and returns non-zero.

# A label as DNS defines it: letters, digits and interior hyphens, at most
# 63 characters. Anything outside that set is not a legal host name, and is
# also the only way a configured name could be read as syntax by one of the
# scripts the stages generate around it.
_schema_label_valid() {
  local label=$1
  ((${#label} >= 1 && ${#label} <= 63)) || return 1
  [[ ${label} =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]]
}

# shellcheck disable=SC2329  # called indirectly, by name, from schema_resolve
_schema_validate_PVE_HOSTNAME() {
  local value=$1
  _schema_label_valid "${value}" && return 0
  printf 'a short hostname must be a DNS label: letters, digits and interior hyphens, 1 to 63 characters\n'
  return 1
}

# shellcheck disable=SC2329  # called indirectly, by name, from schema_resolve
_schema_validate_PVE_FQDN() {
  local value=$1 label
  local -a labels=()

  if ((${#value} > 253)); then
    printf 'a domain name may be at most 253 characters\n'
    return 1
  fi
  if [[ ! ${value} =~ ^[A-Za-z0-9.-]+$ ]]; then
    printf 'a domain name holds only letters, digits, hyphens and dots\n'
    return 1
  fi
  if [[ ${value} != *.* ]]; then
    printf 'a fully qualified name carries a domain, so it has at least one dot\n'
    return 1
  fi
  # read -a drops a trailing empty field, so an edge dot has to be caught
  # before the labels are split out.
  if [[ ${value} == .* || ${value} == *. || ${value} == *..* ]]; then
    printf 'a domain name has no empty label, so it neither begins nor ends with a dot\n'
    return 1
  fi

  IFS='.' read -r -a labels <<<"${value}"
  for label in "${labels[@]}"; do
    if ! _schema_label_valid "${label}"; then
      printf 'the label "%s" is not a DNS label: letters, digits and interior hyphens, 1 to 63 characters\n' \
        "${label}"
      return 1
    fi
  done

  # Phase 1 writes both names into the same /etc/hosts entry and tells
  # Proxmox about both, so a pair that disagrees names two different hosts.
  if [[ -n ${PVE_HOSTNAME:-} && ${labels[0],,} != "${PVE_HOSTNAME,,}" ]]; then
    printf 'it begins with "%s", but PVE_HOSTNAME is "%s"\n' \
      "${labels[0]}" "${PVE_HOSTNAME}"
    return 1
  fi
}

# shellcheck disable=SC2329  # called indirectly, by name, from schema_resolve
_schema_validate_PVE_NETWORK_WAIT_SECONDS() {
  local value=$1
  # The stages compare this with -lt, which evaluates its operands
  # arithmetically, and bash evaluates an array subscript inside such an
  # operand as code. A plain count of seconds is the only thing it may be.
  if [[ ! ${value} =~ ^(0|[1-9][0-9]*)$ ]] || ((10#${value} > 86400)); then
    printf 'a wait is a whole number of seconds, from 0 to 86400\n'
    return 1
  fi
}

# A stage reads a flag by comparing it with yes, so anything else disables
# the feature. "true", "1" and "Yes" all read as "off", which is the one
# way a deployment ends up with no certificate and no complaint.
_schema_yes_no_valid() {
  [[ $1 == yes || $1 == no ]]
}

# shellcheck disable=SC2329  # called indirectly, by name, from schema_resolve
_schema_validate_PVE_ACME_ENABLED() {
  _schema_yes_no_valid "$1" && return 0
  printf 'it is yes or no\n'
  return 1
}

# shellcheck disable=SC2329  # called indirectly, by name, from schema_resolve
_schema_validate_PVE_ACME_ACCEPT_TOS() {
  _schema_yes_no_valid "$1" && return 0
  printf 'it is yes or no\n'
  return 1
}

# shellcheck disable=SC2329  # called indirectly, by name, from schema_resolve
_schema_validate_PVE_ACME_ENVIRONMENT() {
  [[ $1 == staging || $1 == production ]] && return 0
  printf 'the ACME environment is staging or production\n'
  return 1
}

# DNS Made Easy is the only provider the certificate stage supports.
# Naming another one here would otherwise be found out by pvenode, after
# phase 2 had started.
# shellcheck disable=SC2329  # called indirectly, by name, from schema_resolve
_schema_validate_PVE_ACME_DNS_PLUGIN() {
  [[ $1 == dnsmadeeasy ]] && return 0
  printf 'DNS Made Easy is the only supported provider, so this is dnsmadeeasy\n'
  return 1
}

# shellcheck disable=SC2329  # called indirectly, by name, from schema_resolve
_schema_validate_PVE_ACME_EMAIL() {
  local value=$1
  if [[ ${value} =~ [[:space:]] ]] || [[ ${value} != *@*.* ]] ||
    [[ ${value} == @* || ${value} == *@ ]]; then
    printf 'an ACME contact is an email address, as name@example.net\n'
    return 1
  fi
}

# Declared after PVE_ACME_ENVIRONMENT, so the environment this run chose is
# already resolved and the pair can be judged together. A forced order
# against production spends one of a weekly allowance of them.
# shellcheck disable=SC2329  # called indirectly, by name, from schema_resolve
_schema_validate_PVE_ACME_FORCE_ORDER() {
  local value=$1
  if ! _schema_yes_no_valid "${value}"; then
    printf 'it is yes or no\n'
    return 1
  fi
  if [[ ${value} == yes && ${PVE_ACME_ENVIRONMENT:-staging} == production ]]; then
    printf 'a forced order is permitted against the staging directory only; PVE_ACME_ENVIRONMENT is production\n'
    return 1
  fi
}

# shellcheck disable=SC2329  # called indirectly, by name, from schema_resolve
_schema_validate_PVE_TAILSCALE_ENABLED() {
  _schema_yes_no_valid "$1" && return 0
  printf 'it is yes or no\n'
  return 1
}

# The adoption gate decides whether this toolkit may reboot, re-device,
# install into and join to a tailnet a container somebody else built. A
# value that is neither yes nor no is refused rather than read as no, so
# an operator who wrote `true` is told why the refusal happened.
# shellcheck disable=SC2329  # called indirectly, by name, from schema_resolve
_schema_validate_PVE_TAILSCALE_ADOPT_EXISTING() {
  local value=$1
  if ! _schema_yes_no_valid "${value}"; then
    printf 'it is yes or no\n'
    return 1
  fi
  if [[ ${value} == yes && -z ${PVE_TAILSCALE_CTID:-} ]]; then
    printf 'it only has meaning with PVE_TAILSCALE_CTID set to the container to adopt; adoption is never automatic\n'
    return 1
  fi
}

# shellcheck disable=SC2329  # called indirectly, by name, from schema_resolve
_schema_validate_PVE_TAILSCALE_CTID() {
  local value=$1
  if [[ ! ${value} =~ ^[0-9]+$ ]]; then
    printf 'a container id is a number\n'
    return 1
  fi
  if ((value < 100 || value > 999999999)); then
    printf 'Proxmox container ids run from 100 to 999999999\n'
    return 1
  fi
}

# Storage names reach `pvesm`, the community-scripts answers file and a
# `pct create` argument, so they are held to the shape Proxmox gives them.
# shellcheck disable=SC2329  # called indirectly, by name, from schema_resolve
_schema_validate_PVE_TAILSCALE_STORAGE() {
  _schema_storage_name_valid "$1"
}

# shellcheck disable=SC2329  # called indirectly, by name, from schema_resolve
_schema_validate_PVE_TAILSCALE_TEMPLATE_STORAGE() {
  _schema_storage_name_valid "$1"
}

# shellcheck disable=SC2329  # called indirectly, by name, from schema_resolve
_schema_validate_PVE_TAILSCALE_CONTAINER_STORAGE() {
  _schema_storage_name_valid "$1"
}

_schema_storage_name_valid() {
  local value=$1
  if [[ ! ${value} =~ ^[A-Za-z][A-Za-z0-9._-]*$ ]]; then
    printf 'a Proxmox storage name starts with a letter and holds letters, digits, dots, hyphens and underscores\n'
    return 1
  fi
}

# The routes go into --advertise-routes and into a script generated in the
# container, so they are checked here rather than only at the point of use.
# shellcheck disable=SC2329  # called indirectly, by name, from schema_resolve
_schema_validate_PVE_TAILSCALE_ROUTES() {
  local value=$1 route
  local -r octet='(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])'
  local -r prefix='(3[0-2]|[12]?[0-9])'
  local -a parts=()
  IFS=',' read -r -a parts <<<"${value}"
  for route in ${parts[@]+"${parts[@]}"}; do
    route=${route//[[:space:]]/}
    [[ -n ${route} ]] || continue
    if [[ ! ${route} =~ ^${octet}\.${octet}\.${octet}\.${octet}/${prefix}$ ]]; then
      printf '%s is not an IPv4 CIDR, for example 192.168.1.0/24\n' "${route}"
      return 1
    fi
  done
}

# shellcheck disable=SC2329  # called indirectly, by name, from schema_resolve
_schema_validate_PVE_TAILSCALE_RAM_MB() {
  _schema_positive_number "$1" 'a memory size in MB'
}

# shellcheck disable=SC2329  # called indirectly, by name, from schema_resolve
_schema_validate_PVE_TAILSCALE_CORES() {
  _schema_positive_number "$1" 'a core count'
}

# shellcheck disable=SC2329  # called indirectly, by name, from schema_resolve
_schema_validate_PVE_TAILSCALE_DISK_GB() {
  _schema_positive_number "$1" 'a disk size in GB'
}

_schema_positive_number() {
  local value=$1 what=$2
  if [[ ! ${value} =~ ^[0-9]+$ ]] || ((value < 1)); then
    printf 'it is %s, a whole number of at least 1\n' "${what}"
    return 1
  fi
}

# The pinned digest is the trust root for everything apt installs in the
# router, so a value that is not a SHA-256 is refused before it can be
# compared against anything.
# shellcheck disable=SC2329  # called indirectly, by name, from schema_resolve
_schema_validate_PVE_TAILSCALE_KEYRING_SHA256() {
  local value=${1,,}
  if [[ ! ${value} =~ ^[0-9a-f]{64}$ ]]; then
    printf 'a SHA-256 digest is 64 hexadecimal digits\n'
    return 1
  fi
}

# The container hostname becomes a DNS label and a Tailscale machine name.
# The upstream builder lowercases it and strips the spaces out, so a name
# that needs either is not the name the operator will get; it is refused
# here instead, while there is somebody to retype it.
# shellcheck disable=SC2329  # called indirectly, by name, from schema_resolve
_schema_validate_PVE_TAILSCALE_HOSTNAME() {
  local value=$1
  if [[ ${#value} -gt 63 ]]; then
    printf 'a hostname is at most 63 characters\n'
    return 1
  fi
  if [[ ! ${value} =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
    printf 'a container hostname is lowercase letters, digits and hyphens, and starts and ends with a letter or a digit\n'
    return 1
  fi
}

# --- Home Assistant OS ----------------------------------------------------

_schema_default_haos_hostname() { printf 'haos\n'; }

# Bash arithmetic wraps at 64 bits, so a value made only of digits can
# still compare as something else: 2**64 + 100 is 100 inside `(( ))`, and
# a floor check on it passes. Every number this stage takes is bounded as
# text, before an arithmetic context ever sees it. Nine digits is past
# every figure any of these keys has a use for.
_schema_haos_bounded_number() {
  local value=$1 what=$2
  if [[ ! ${value} =~ ^[0-9]{1,9}$ ]]; then
    printf 'it is %s, a whole number of at most nine digits\n' "${what}"
    return 1
  fi
  _schema_positive_number "${value}" "${what}"
}

# shellcheck disable=SC2329  # called indirectly, by name, from schema_resolve
_schema_validate_PVE_HAOS_ENABLED() {
  _schema_yes_no_valid "$1" && return 0
  printf 'it is yes or no\n'
  return 1
}

# The machine name reaches `qm create -name`, which takes a DNS label, and
# becomes the name the appliance answers to on the LAN. Proxmox refuses a
# name that is not one, so it is refused here rather than in the middle of
# a build.
# shellcheck disable=SC2329  # called indirectly, by name, from schema_resolve
_schema_validate_PVE_HAOS_HOSTNAME() {
  local value=$1
  if [[ ${#value} -gt 63 ]]; then
    printf 'a hostname is at most 63 characters\n'
    return 1
  fi
  if [[ ! ${value} =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
    printf 'a machine hostname is lowercase letters, digits and hyphens, and starts and ends with a letter or a digit\n'
    return 1
  fi
}

# shellcheck disable=SC2329  # called indirectly, by name, from schema_resolve
_schema_validate_PVE_HAOS_VMID() {
  local value=$1
  _schema_haos_bounded_number "${value}" 'a guest id' || return 1
  if ((value < 100 || value > 999999999)); then
    printf 'Proxmox guest ids run from 100 to 999999999\n'
    return 1
  fi
}

# The adoption gate decides whether this toolkit may tag and start a
# virtual machine somebody else built. A value that is neither yes nor no
# is refused rather than read as no, for the same reason the Tailscale one
# is.
# shellcheck disable=SC2329  # called indirectly, by name, from schema_resolve
_schema_validate_PVE_HAOS_ADOPT_EXISTING() {
  local value=$1
  if ! _schema_yes_no_valid "${value}"; then
    printf 'it is yes or no\n'
    return 1
  fi
  if [[ ${value} == yes && -z ${PVE_HAOS_VMID:-} ]]; then
    printf 'it only has meaning with PVE_HAOS_VMID set to the machine to adopt; adoption is never automatic\n'
    return 1
  fi
}

# shellcheck disable=SC2329  # called indirectly, by name, from schema_resolve
_schema_validate_PVE_HAOS_STORAGE() {
  _schema_storage_name_valid "$1"
}

# shellcheck disable=SC2329  # called indirectly, by name, from schema_resolve
_schema_validate_PVE_HAOS_RAM_MB() {
  _schema_haos_bounded_number "$1" 'a memory size in MB'
}

# shellcheck disable=SC2329  # called indirectly, by name, from schema_resolve
_schema_validate_PVE_HAOS_CORES() {
  _schema_haos_bounded_number "$1" 'a core count'
}

# The published image is a 32 GiB disk, and qm does not shrink one: a
# smaller figure here is a setting that silently does not happen.
# shellcheck disable=SC2329  # called indirectly, by name, from schema_resolve
_schema_validate_PVE_HAOS_DISK_GB() {
  local value=$1
  _schema_haos_bounded_number "${value}" 'a disk size in GB' || return 1
  if ((value < 32)); then
    printf 'the Home Assistant OS image is a 32 GiB disk and qm does not shrink one, so 32 is the smallest size that means anything\n'
    return 1
  fi
}

# A Home Assistant OS release, as the project spells them: 18.4, 18.4.1.
# The value becomes part of a download URL and part of a filename.
# shellcheck disable=SC2329  # called indirectly, by name, from schema_resolve
_schema_validate_PVE_HAOS_VERSION() {
  local value=$1
  if [[ ! ${value} =~ ^[0-9]+(\.[0-9a-zA-Z]+)*$ ]]; then
    printf 'a Home Assistant OS release is a dotted version such as 18.4\n'
    return 1
  fi
}

# The pinned digest is the only thing that makes the disk image an
# installation of what was reviewed rather than of whatever answered, so a
# value that is not a SHA-256 is refused before it is compared.
# shellcheck disable=SC2329  # called indirectly, by name, from schema_resolve
_schema_validate_PVE_HAOS_IMAGE_SHA256() {
  local value=${1,,}
  if [[ ! ${value} =~ ^[0-9a-f]{64}$ ]]; then
    printf 'a SHA-256 digest is 64 hexadecimal digits\n'
    return 1
  fi
}

# Applies a key's validator, if it declares one. Empty is left to the
# required check, which reports a missing value far better than a validator
# can.
_schema_validate() {
  local name=$1 value=$2 reason=''
  [[ -n ${value} ]] || return 0
  declare -F "_schema_validate_${name}" >/dev/null 2>&1 || return 0
  reason=$("_schema_validate_${name}" "${value}") && return 0
  if config_is_secret "${name}"; then
    die "${name} was rejected: ${reason}"
  fi
  die "${name} was rejected: ${reason}. Got: ${value}"
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

# The subnet router is named after the node it routes for, so a tailnet
# with several of them says which is which. Derived rather than asked
# for, because the answer is only ever the host's name with a prefix.
# shellcheck disable=SC2329  # called indirectly, by name, from schema_resolve
_schema_derive_tailscale_hostname() {
  local short=${PVE_HOSTNAME:-}
  [[ -n ${short} ]] || short=$(detect_hostname_short 2>/dev/null) || short=''
  [[ -n ${short} ]] || return 1
  short=${short,,}
  printf '%s\n' "ts-${short:0:60}"
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
    _schema_validate "${name}" "${value}"
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
