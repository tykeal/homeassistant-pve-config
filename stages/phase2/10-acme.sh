#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

# Nothing above this block may fork, and the block itself uses builtins
# only.
#
# The driver's secrets loader exports what it reads, so this process
# starts with the DNS credentials in its environment, and every fork hands
# a child a copy of it. Sourcing a library is already a fork: stage.sh
# runs stage_require_proxmox as it loads and that calls $(sysroot). So the
# capture happens here, before the first `source`, with plain parameter
# assignment and `unset`.
#
# Tracing goes off at the same time and stays off until the stage has
# finished with the credentials, and PS4 is replaced with a known safe
# one. An inherited PS4 is code: it is expanded for every traced command,
# so one that dereferences a variable prints whatever that variable holds.
# The driver sets a safe PS4 for the stages it runs, and an operator can
# keep one of their own with PVE_CONFIG_TRACE_PREFIX; this stage replaces
# it regardless, because that override is for reading a trace rather than
# for reading a credential. One command -- the `case` below --
# is still traced with the inherited prefix, before this shell can do
# anything about it, and at that point no credential has been read into a
# variable of this script's.
case ${-} in
  *x*) _ACME_BOOT_XTRACE=1 ;;
  *) _ACME_BOOT_XTRACE=0 ;;
esac
set +x
PS4='+ '
_ACME_BOOT_KEY_SET=${PVE_DNSMADEEASY_KEY+set}
_ACME_BOOT_SECRET_SET=${PVE_DNSMADEEASY_SECRET+set}

# Tracing that was already on when this shell started, with a credential
# already in the environment, is the one leak no boot block can prevent:
# bash expands the inherited PS4 for the very first command it runs, and
# the first command it runs is the one that would turn tracing off. By
# the time this test happens, a hostile prefix has had its line.
#
# So the run stops here. It stops rather than continuing because the
# alternative is the same prefix expanding against every remaining
# command of the stage, and because an operator who sees this has a
# credential to rotate and wants to hear it now. Reaching this needs
# control of the environment of the root shell, which is a position that
# also affords PATH, BASH_ENV and LD_PRELOAD -- it is not the attack to
# defend against, it is the one to be honest about.
if [[ ${_ACME_BOOT_XTRACE} -eq 1 ]] &&
  [[ -n ${_ACME_BOOT_KEY_SET} || -n ${_ACME_BOOT_SECRET_SET} ]]; then
  printf '%s\n' \
    'pve-config: refusing to run the ACME stage with tracing already enabled and PVE_DNSMADEEASY_KEY or PVE_DNSMADEEASY_SECRET in the environment.' \
    'Bash expands PS4 before the first command of this script, so a credential supplied this way has already been exposed to whatever that prefix does, and to anything reading this trace. Treat those credentials as compromised and rotate them.' \
    'Run without tracing, or put the credentials in the 0600 secrets file instead of the environment, which is the supported way and never exposes them to a trace at all.' >&2
  exit 1
fi
_ACME_BOOT_KEY=${PVE_DNSMADEEASY_KEY:-}
_ACME_BOOT_SECRET=${PVE_DNSMADEEASY_SECRET:-}
unset PVE_DNSMADEEASY_KEY PVE_DNSMADEEASY_SECRET

# shellcheck source=lib/stage.sh
source "${PVE_CONFIG_LIB_DIR:?PVE_CONFIG_LIB_DIR is unset}/stage.sh"
# shellcheck source=lib/acme.sh
source "${PVE_CONFIG_LIB_DIR}/acme.sh"

# The libraries take over the capture, and the secret region the block
# above opened by hand stays open until the credentials are gone.
acme_credentials_adopt "${_ACME_BOOT_XTRACE}" "${_ACME_BOOT_KEY_SET}" \
  "${_ACME_BOOT_SECRET_SET}" "${_ACME_BOOT_KEY}" "${_ACME_BOOT_SECRET}"
_ACME_BOOT_KEY=''
_ACME_BOOT_SECRET=''

SYSROOT=$(sysroot)

# A deployment that terminates TLS somewhere else, or that has no public
# DNS for this host, says so once and is left alone.
if [[ ${PVE_ACME_ENABLED:-no} != yes ]]; then
  acme_credentials_discard
  log_info 'PVE_ACME_ENABLED is not yes; leaving the node certificate alone'
  exit 0
fi

stage_require PVE_FQDN

# Said once, by name, rather than as "the certificate listing could not be
# read" at the far end of the stage.
acme_require_json_decoder

environment=${PVE_ACME_ENVIRONMENT:-staging}
case ${environment} in
  staging | production) ;;
  *) die "PVE_ACME_ENVIRONMENT is '${environment}'; it is staging or production." ;;
esac

# DNS Made Easy is the whole of the provider support. A deployment that
# names another one is told so here rather than reaching pvenode with an
# api value that would configure a plugin nobody has credentials for.
plugin=${PVE_ACME_DNS_PLUGIN:-dnsmadeeasy}
if [[ ${plugin} != dnsmadeeasy ]]; then
  die "PVE_ACME_DNS_PLUGIN is '${plugin}', and DNS Made Easy is the only supported provider. Set it to dnsmadeeasy."
fi

if [[ -z ${PVE_ACME_EMAIL:-} ]]; then
  die 'PVE_ACME_ENABLED is yes but PVE_ACME_EMAIL is unset. Set a contact address, or set PVE_ACME_ENABLED=no.'
fi

# A forced order discards the rate limit protection the ordinary path
# gives, so production never gets one. The refusal comes before any
# credential is touched, because an operator who meant staging has
# misconfigured the environment and must hear about it rather than spend a
# production order.
force=${PVE_ACME_FORCE_ORDER:-no}
if [[ ${force} == yes && ${environment} == production ]]; then
  die "PVE_ACME_FORCE_ORDER is yes and PVE_ACME_ENVIRONMENT is production. A forced order is permitted against the staging directory only, because the production directory counts orders against a weekly limit."
fi

directory=$(acme_directory_url "${environment}")
account=$(acme_account_name "${environment}")

# Tracing stays off from the first dereference of a credential until the
# last copy of one is gone, which is after the plugin has been pointed at
# the file: the content is an argument to the write and to the comparison,
# and `set -x` would print it at either. Redaction covers this toolkit's
# own log lines and does nothing about tracing, which is why the region
# below is wider than the read.
#
# The credentials are read from the secrets file into plain shell
# variables, so neither pvenode nor the DNS hook it runs is handed them in
# its environment.
acme_secret_begin
acme_credentials_read "${PVE_CONFIG_DIR:-/root/pve-config}/secrets.env"

# The names the DNS Made Easy hook in acme.sh reads. pvenode reads this
# file, encodes the content and keeps its own copy under /etc/pve/priv, so
# what the command line carries is the path.
credentials="ME_Key=${ACME_ME_KEY}
ME_Secret=${ACME_ME_SECRET}
"
ACME_ME_KEY=''
ACME_ME_SECRET=''

# Not /etc/pve. pmxcfs serves every file there as root:www-data 0640 and
# ignores chmod, so a credentials file put there is readable by the web
# server it is meant to protect. This directory is local, root owned and
# 0700, as the Zulip credentials already are.
credentials_dir="${SYSROOT}/etc/pve-config"
credentials_path="${credentials_dir}/dnsmadeeasy.conf"

# Ownership before mode. A directory or a file someone else owns is
# theirs to read and theirs to chmod back open, and write_file keeps the
# ownership of a file it replaces, so a pre-planted one would take
# delivery of the credentials.
acme_require_owned "${credentials_dir}"
acme_require_owned "${credentials_path}"

credentials_state=unchanged
ensure_dir "${credentials_dir}" 0700 >/dev/null
state_of credentials_state write_file "${credentials_path}" "${credentials}" 0600

# What was checked before the write is checked again after it, so a swap
# between the two checks is caught rather than passed over. It is a
# narrower guarantee than a race free write: the window is small, not
# absent, and an owner of a directory above this one is outside what
# either check can see.
acme_require_owned "${credentials_dir}"
acme_require_owned "${credentials_path}"

plugin_state=unchanged
state_of plugin_state acme_plugin_converge \
  "${plugin}" me "${credentials_path}" "${credentials}"
credentials=''
acme_secret_end
# And the region the capture at the top of this file opened: with the last
# credential gone, tracing can go back to whatever it was.
acme_secret_end

if [[ ${credentials_state} == changed ]]; then
  log_info "wrote the DNS Made Easy credentials to ${credentials_path}"
fi
if [[ ${plugin_state} == changed ]]; then
  log_info "configured the ACME DNS plugin ${plugin}"
fi

# Registration is where the terms of service are agreed to, and agreeing to
# them on an operator's behalf is not this toolkit's call to make.
account_exists=0
acme_account_exists "${account}" || account_exists=$?
case ${account_exists} in
  0) ;;
  1)
    if [[ ${PVE_ACME_ACCEPT_TOS:-no} != yes ]]; then
      die "Registering the ACME account ${account} accepts the CA terms of service at ${directory}. Read them, then set PVE_ACME_ACCEPT_TOS=yes."
    fi
    ;;
  *)
    die "Unable to read the ACME accounts on this node: 'pvenode acme account list' either failed or answered with something this toolkit cannot parse. Refusing to go on rather than registering an account over one that may already be there."
    ;;
esac

account_state=unchanged
state_of account_state acme_account_converge \
  "${account}" "${PVE_ACME_EMAIL}" "${directory}"
if [[ ${account_state} == changed ]]; then
  log_info "registered the ACME account ${account}"
fi

node_state=unchanged
state_of node_state acme_node_config_converge \
  "${PVE_FQDN}" "${plugin}" "${account}"
if [[ ${node_state} == changed ]]; then
  log_info "pointed ${PVE_FQDN} at the ${plugin} plugin"
fi

# The order is the expensive, rate limited step, so it happens only when
# the host has nothing to serve: no certificate for this name, one inside
# the renewal window, or one from the other directory. A forced order is
# the operator asking for one anyway, which only staging allows. An
# inspection that could not answer stops the stage rather than ordering on
# the strength of a question nobody answered.
#
# Which command runs follows what the host holds, because pvenode draws
# the same distinctions: an order declines to overwrite a certificate
# that is already there, a renewal is the command for one that is merely
# due, and the overwrite a replacement needs is a different thing from
# the operator asking for an order they do not need.
if [[ ${force} == yes ]]; then
  log_info "forcing a certificate order against the ${environment} directory"
  acme_cert_order yes >/dev/null
else
  cert_status=0
  cert_state=$(acme_cert_state "${PVE_FQDN}" "${environment}") || cert_status=$?
  ((cert_status == 0)) ||
    die "Unable to read the certificates on this node: 'pvenode cert info' either failed or answered with something this toolkit cannot parse. Refusing to order, because an order it did not need spends a ${environment} rate limit and leaves the stage ordering again on every run."
  case ${cert_state} in
    current) log_info "${PVE_FQDN} already holds a current ${environment} certificate; not ordering one" ;;
    absent) acme_cert_order no >/dev/null ;;
    renewable)
      log_info "renewing the certificate for ${PVE_FQDN}"
      acme_cert_renew >/dev/null
      ;;
    *)
      # Another name or another directory: the host is serving something
      # that is not what it was asked for, and pvenode will not replace
      # it without being told to. This is the step that promotes a
      # deployment from staging to production, so it is not the forced
      # order staging reserves to itself.
      log_info "replacing the certificate on ${PVE_FQDN} with a ${environment} one"
      acme_cert_order yes >/dev/null
      ;;
  esac
fi

log_info "ACME is configured for ${PVE_FQDN} against the ${environment} directory"
