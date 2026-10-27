#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
# SPDX-License-Identifier: Apache-2.0

# ACME convergence, through the pvenode tooling Proxmox ships.
#
# Every helper here asks the host what it already looks like before it
# changes anything, because the pvenode ACME commands are not convergent on
# their own: `acme plugin add` fails when the plugin is there, and `acme
# cert order` orders again whether or not the host already holds a valid
# certificate. An unconditional order is also the one mistake that costs
# the most, since the Let's Encrypt production directory counts failures
# and refuses the deployment for the rest of the week.
#
# Credentials never pass through an argument list. The DNS plugin reaches
# them through a root-only file whose path, and never whose contents, is
# what pvenode is told.
#
# They do not pass through the environment either. The driver's secrets
# loader exports everything it reads, so a credential that was left in the
# environment would be inherited by pvenode, by the acme.sh hook pvenode
# runs, and by every other child of this process. acme_credentials_read
# therefore reads the file itself, keeps the values in shell variables that
# are never exported, and drops the inherited copies.

# The two Let's Encrypt endpoints. Staging issues from an untrusted root
# and carries far looser rate limits, which is why it is what this toolkit
# reaches for unless a deployment says otherwise.
ACME_DIRECTORY_STAGING='https://acme-staging-v02.api.letsencrypt.org/directory'
ACME_DIRECTORY_PRODUCTION='https://acme-v02.api.letsencrypt.org/directory'

# Days of life left below which a certificate counts as spent. Proxmox
# renews at 30 days, so a certificate inside that window is one its own
# timer is about to replace.
ACME_RENEW_WINDOW_DAYS=30

# Tracing is held off for as long as a credential is reachable, which is
# longer than any single helper here runs. xtrace_suspend and xtrace_resume
# do not nest -- an inner resume turns tracing back on while an outer region
# is still holding a secret -- so the regions below are counted instead, and
# only the outermost one puts tracing back.
_ACME_SECRET_DEPTH=0
_ACME_SECRET_XTRACE=0

acme_secret_begin() {
  if ((_ACME_SECRET_DEPTH == 0)); then
    case ${-} in
      *x*) _ACME_SECRET_XTRACE=1 ;;
      *) _ACME_SECRET_XTRACE=0 ;;
    esac
    set +x
  fi
  _ACME_SECRET_DEPTH=$((_ACME_SECRET_DEPTH + 1))
}

acme_secret_end() {
  if ((_ACME_SECRET_DEPTH > 0)); then
    _ACME_SECRET_DEPTH=$((_ACME_SECRET_DEPTH - 1))
  fi
  if ((_ACME_SECRET_DEPTH == 0)) && ((_ACME_SECRET_XTRACE == 1)); then
    _ACME_SECRET_XTRACE=0
    set -x
  fi
}

# Dies out of a secret region: clears the named variables, closes every
# region this process opened, then reports. Nothing between the clearing
# and the report can be traced with a credential still in a variable, and
# the message itself never carries one.
#
# A die raised by a library this code called -- a secrets file with the
# wrong mode, say -- ends the process with tracing still off. That is the
# safe direction: the shell is exiting, and anything it still had to say
# cannot be traced with a credential live.
acme_secret_die() {
  local message=$1 name
  shift
  for name in "$@"; do
    printf -v "${name}" '%s' ''
  done
  while ((_ACME_SECRET_DEPTH > 0)); do
    acme_secret_end
  done
  die "${message}"
}

# What the driver left in the environment, taken over from the few lines
# of pure parameter assignment the stage runs before it sources anything.
#
# The capture itself cannot live here. Sourcing a library is enough to
# fork -- stage.sh runs stage_require_proxmox as it loads, and that is a
# command substitution -- so by the time this file exists a child has
# already inherited whatever was still exported. The stage therefore
# captures and unsets with builtins at its very top, and hands the result
# over here.
_ACME_ENV_KEY=''
_ACME_ENV_SECRET=''
_ACME_ENV_KEY_SET=''
_ACME_ENV_SECRET_SET=''

# Takes over the stage's boot capture and keeps the secret region it
# opened open.
#
# The stage turned tracing off before it touched the environment, so the
# region is seeded as already entered rather than begun here: beginning it
# now would record "tracing was off" and put nothing back at the end.
acme_credentials_adopt() {
  local xtrace=${1:-0} key_set=${2:-} secret_set=${3:-} key=${4:-} secret=${5:-}

  if ((_ACME_SECRET_DEPTH == 0)); then
    _ACME_SECRET_DEPTH=1
    _ACME_SECRET_XTRACE=${xtrace}
  fi

  _ACME_ENV_KEY_SET=${key_set}
  _ACME_ENV_SECRET_SET=${secret_set}
  _ACME_ENV_KEY=${key}
  _ACME_ENV_SECRET=${secret}
  # Registered here rather than later, so a log line between this point and
  # the read is masked whichever source the value came from.
  redact_register "${_ACME_ENV_KEY}" "${_ACME_ENV_SECRET}"
}

# Drops the captured credentials and closes the region the boot capture
# opened, for a stage that turns out to have nothing to do.
acme_credentials_discard() {
  _ACME_ENV_KEY=''
  _ACME_ENV_SECRET=''
  _ACME_ENV_KEY_SET=''
  _ACME_ENV_SECRET_SET=''
  while ((_ACME_SECRET_DEPTH > 0)); do
    acme_secret_end
  done
}

# The DNS Made Easy credentials, read into ACME_ME_KEY and ACME_ME_SECRET
# without exporting either of them.
#
# The secrets file is parsed rather than sourced, and only after the same
# ownership and permission checks the driver applies, so a file anybody
# else can reach is refused instead of read.
#
# An environment variable wins over the file. That is the direction an
# operator expects: a one-off run, or a rotation that has not reached
# secrets.env yet, must not quietly use the credentials still on disk. A
# variable that is set but empty is an error rather than a fallback,
# because supplying an empty secret is a mistake and bootstrap.sh already
# treats one that way.
#
# The caller opens a secret region before calling this and closes it once
# it has cleared its own copy, so the credentials are never reachable with
# tracing on.
acme_credentials_read() {
  local path=$1 file_key='' file_secret=''

  acme_secret_begin
  ACME_ME_KEY=''
  ACME_ME_SECRET=''

  if [[ -e ${path} || -L ${path} ]]; then
    _secrets_check_path "${path}"
    _config_parse_file "${path}"
    file_key=${_CONFIG_PARSED[PVE_DNSMADEEASY_KEY]:-}
    file_secret=${_CONFIG_PARSED[PVE_DNSMADEEASY_SECRET]:-}
    _CONFIG_PARSED=()
    _CONFIG_PARSED_ORDER=()
  fi

  if [[ -n ${_ACME_ENV_KEY_SET} ]]; then
    ACME_ME_KEY=${_ACME_ENV_KEY}
  else
    ACME_ME_KEY=${file_key}
  fi
  if [[ -n ${_ACME_ENV_SECRET_SET} ]]; then
    ACME_ME_SECRET=${_ACME_ENV_SECRET}
  else
    ACME_ME_SECRET=${file_secret}
  fi
  file_key=''
  file_secret=''
  # The captured copies have served their purpose. They are cleared now
  # rather than at the end of the stage, so nothing that runs later can
  # print them through a trace prefix or a dump of the shell's variables.
  _ACME_ENV_KEY=''
  _ACME_ENV_SECRET=''
  redact_register "${ACME_ME_KEY}" "${ACME_ME_SECRET}"

  if [[ -n ${_ACME_ENV_KEY_SET} && -z ${ACME_ME_KEY} ]]; then
    acme_secret_die \
      'PVE_DNSMADEEASY_KEY is set in the environment but empty. Give it a value or unset it; an empty one is not a way to ask for the value in secrets.env.' \
      ACME_ME_KEY ACME_ME_SECRET
  fi
  if [[ -n ${_ACME_ENV_SECRET_SET} && -z ${ACME_ME_SECRET} ]]; then
    acme_secret_die \
      'PVE_DNSMADEEASY_SECRET is set in the environment but empty. Give it a value or unset it; an empty one is not a way to ask for the value in secrets.env.' \
      ACME_ME_KEY ACME_ME_SECRET
  fi

  if [[ -z ${ACME_ME_KEY} || -z ${ACME_ME_SECRET} ]]; then
    acme_secret_die \
      'PVE_DNSMADEEASY_KEY and PVE_DNSMADEEASY_SECRET are required for the DNS-01 challenge; add them to secrets.env.' \
      ACME_ME_KEY ACME_ME_SECRET
  fi

  acme_secret_end
}

# Refuses a path the running user does not own, and refuses to follow a
# symlink to reach one.
#
# A mode is only half of a permission check. A directory someone else owns
# is a directory they can chmod back open after this stage has tightened
# it, and write_file copies the ownership of a file it replaces, so a
# pre-planted 0600 file keeps its hostile owner and then receives the
# credentials. Under root this demands root ownership; the tests run
# unprivileged, where it demands theirs, which is the same rule.
#
# What this guarantees is that the directory and the file themselves
# belong to the user running the stage. It says nothing about the
# directories above them: on the real host those are /etc and /, which
# only root can write, but a PVE_CONFIG_ROOT pointed somewhere else can
# sit under an ancestor that somebody else owns, and an owner of an
# ancestor can replace the whole subtree.
acme_require_owned() {
  local path=$1 owner
  if [[ -L ${path} ]]; then
    die "${path} is a symlink; refusing to keep DNS credentials behind it."
  fi
  [[ -e ${path} ]] || return 0
  owner=$(stat -c '%u' -- "${path}" 2>/dev/null) ||
    die "Unable to determine the owner of ${path}."
  if [[ ${owner} != "${EUID}" ]]; then
    die "${path} is owned by uid ${owner}, not by uid ${EUID}; refusing to keep DNS credentials there."
  fi
}

acme_directory_url() {
  local environment=$1
  case ${environment} in
    staging) printf '%s\n' "${ACME_DIRECTORY_STAGING}" ;;
    production) printf '%s\n' "${ACME_DIRECTORY_PRODUCTION}" ;;
    *) die "Unknown ACME environment '${environment}'; it is staging or production." ;;
  esac
}

# One account per directory, named after it. A single "default" account
# would have to be deactivated and registered again on every move between
# staging and production, and a deactivation cannot be undone.
acme_account_name() {
  local environment=$1
  case ${environment} in
    staging | production) printf '%s\n' "${environment}" ;;
    *) die "Unknown ACME environment '${environment}'; it is staging or production." ;;
  esac
}

# JSON is decoded by perl, not by this shell.
#
# The parser that used to live here split on commas and stopped at the
# first `]`, so a string holding either one moved every field after it.
# That is not a corner case: an issuer DN is full of commas. Worse, the
# three-valued answer acme_cert_is_current gives rests on knowing the
# difference between "the host says no" and "this code could not read the
# answer", and a parser that silently reads the wrong field cannot tell
# them apart.
#
# perl with JSON::PP is a core module, and Proxmox itself is written in
# perl, so this adds nothing to what a PVE host already carries. The
# program below is a constant: the document arrives on standard input and
# the parameters arrive in @ARGV, so nothing from the host is ever
# interpolated into code.
#
# Exit status is the contract:
#   0  the field was read, and is on standard output
#   1  the document was read and does not have it
#   2  anything else, including a document that will not decode, a field
#      of the wrong shape, and a perl that is not there at all
read -r -d '' _ACME_JSON_PROGRAM <<'PERL' || true
use strict;
use warnings;
use JSON::PP ();

my $mode = shift @ARGV;
exit 2 unless defined $mode;

# The document is read as bytes. That is what lets a NUL byte, or a
# sequence that is not UTF-8 at all, be seen and refused here: a NUL that
# travelled through a shell variable on its way would have been dropped
# silently, and the text either side of it would have been joined into a
# value nobody sent.
binmode STDIN, ':raw';
binmode STDOUT, ':utf8';
my $raw = do { local $/; <STDIN> };
exit 2 unless defined $raw && length $raw;
exit 2 unless utf8::decode($raw);
exit 2 unless $raw =~ /\S/;

my $data = eval { JSON::PP->new->decode($raw) };
exit 2 if $@ or !defined $data;

# A JSON string, and nothing else.
#
# null, a number, a boolean and a structure are each refused where a
# string is required, because each of them has a stringification that
# reads like an answer -- the empty string for null, the digits for a
# number -- and would then be compared against a directory, an issuer or
# a filename as though the host had said it. Re-encoding is how the shape
# is decided, since by this point perl has only a scalar either way.
my $probe = JSON::PP->new->allow_nonref;

sub text {
    my ($value) = @_;
    exit 2 unless defined $value;
    exit 2 if ref $value;
    exit 2 unless $probe->encode($value) =~ /\A"/;
    return $value;
}

# Only printable scalars leave here. A control character in a value would
# be read back as a line of its own by the caller.
sub emit {
    my ($prefix, $value) = @_;
    exit 2 if $value =~ /[\x00-\x1f\x7f]/;
    print defined $prefix ? "$prefix\t$value\n" : "$value\n";
}

if ($mode eq 'scalar') {
    my $key = shift @ARGV;
    exit 2 unless defined $key;
    exit 2 unless ref $data eq 'HASH';
    exit 1 unless exists $data->{$key};
    emit(undef, text($data->{$key}));
} elsif ($mode eq 'names') {
    my $key = shift @ARGV;
    $key = 'name' unless defined $key;
    exit 2 unless ref $data eq 'ARRAY';
    for my $item (@$data) {
        exit 2 unless ref $item eq 'HASH' && exists $item->{$key};
        emit(undef, text($item->{$key}));
    }
} elsif ($mode eq 'entry') {
    my $filename = shift @ARGV;
    exit 2 unless defined $filename;
    exit 2 unless ref $data eq 'ARRAY';
    my @hits;
    for my $item (@$data) {
        exit 2 unless ref $item eq 'HASH';
        # Every entry has to name a file. One that does not, or that
        # names it with something other than a string, is a listing this
        # code cannot say anything about -- including that the file it
        # was asked for is absent from it.
        exit 2 unless exists $item->{filename};
        next unless text($item->{filename}) eq $filename;
        push @hits, $item;
    }
    exit 1 unless @hits;
    # Two entries for one filename is not a listing this code can answer
    # from, whichever of them is the live certificate.
    exit 2 if @hits > 1;
    my $entry = $hits[0];
    for my $field (qw(notafter issuer)) {
        exit 2 unless exists $entry->{$field};
    }
    # notafter is the one field pvenode reports as a JSON number, so it
    # is the one field a number is right for. It is checked for being
    # digits here as well as in the caller, because the caller puts it in
    # an arithmetic context and bash evaluates an array subscript there.
    my $notafter = $entry->{notafter};
    exit 2 if !defined $notafter || ref $notafter;
    exit 2 unless $notafter =~ /\A[0-9]+\z/;
    emit('notafter', $notafter);
    emit('issuer', text($entry->{issuer}));
    # A listing with no SAN list, or an empty one, is a certificate that
    # covers nothing this stage asked for. That is a read that succeeded
    # and answered no, not a read that failed.
    if (exists $entry->{san}) {
        exit 2 unless ref $entry->{san} eq 'ARRAY';
        emit('san', text($_)) for @{ $entry->{san} };
    }
} else {
    exit 2;
}
exit 0;
PERL

# Runs a command and decodes what it printed.
#
# The output goes from the command to perl through a pipe and never
# through a shell variable. A variable cannot hold a NUL byte: bash drops
# it, and the text either side closes up, so an issuer of
# "O=(STAGING) Let's Encrypt\0 and friends" would arrive at the issuer
# check as the exact string the check accepts. On the pipe the byte
# survives to be refused.
#
# The arguments are the decoder's parameters, then --, then the command.
# Nothing the host said is ever an argument of the decoder, and the
# command itself -- a plugin configuration carries the encoded
# credentials -- prints to the pipe rather than into anything readable
# from /proc.
#
#   0  the field was read, and is on standard output
#   1  the document was read and does not have it
#   2  anything else, including a command that failed, a document that
#      will not decode, and a field of the wrong shape
_acme_json_cmd() {
  local arg seen=0
  local -a params=() cmd=()
  for arg in "$@"; do
    if ((seen)); then
      cmd+=("${arg}")
    elif [[ ${arg} == '--' ]]; then
      seen=1
    else
      params+=("${arg}")
    fi
  done
  ((seen)) || return 2
  ((${#cmd[@]} > 0)) || return 2

  local captured states source_status decode_status
  captured=$(
    # Without this the pipeline's failure would end the subshell under
    # `set -e` before either status could be reported.
    set +e
    "${cmd[@]}" 2>/dev/null |
      perl -e "${_ACME_JSON_PROGRAM}" -- ${params[@]+"${params[@]}"} 2>/dev/null
    printf '\n%s' "${PIPESTATUS[*]}"
  )
  states=${captured##*$'\n'}
  captured=${captured%$'\n'*}
  source_status=${states%% *}
  decode_status=${states##* }
  [[ ${source_status} == 0 ]] || return 2
  while [[ ${captured} == *$'\n' ]]; do
    captured=${captured%$'\n'}
  done
  case ${decode_status} in
    0) printf '%s' "${captured}" ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
}

# The decoder, checked once and by name.
#
# Without it every reading of a pvenode answer returns "I could not tell",
# which stops the stage with a message about unreadable certificates --
# true, and unhelpful. JSON::PP is a core module, and Debian keeps the
# core modules in perl-modules rather than perl-base, so the one host that
# could lack it is one stripped down to the essential package set.
acme_require_json_decoder() {
  perl -MJSON::PP -e 'exit 0' >/dev/null 2>&1 ||
    die 'This stage reads what pvenode reports with perl and JSON::PP, and one of them is missing. Install the perl package (JSON::PP ships with the core modules, not with perl-base).'
}

# Whether the host already holds this account.
#
#   0  it does
#   1  it does not, which is what an empty listing on a fresh host says
#   2  the listing could not be read
#
# The third answer is kept apart from the second all the way to the
# caller. Collapsing them registers an unreadable listing as "no account
# yet" and registers a second one over the top.
acme_account_exists() {
  local name=$1 names status=0 candidate
  names=$(_acme_json_cmd names -- \
    pvenode acme account list --output-format json) || status=$?
  ((status == 0)) || return 2
  [[ -n ${names} ]] || return 1
  while IFS= read -r candidate; do
    [[ ${candidate} == "${name}" ]] && return 0
  done <<<"${names}"
  return 1
}

# The directory an existing account is registered against. An account is
# bound to one CA for its lifetime, so this is what decides whether the
# account on the host is the account this run wants.
acme_account_directory() {
  local name=$1 status=0 value
  value=$(_acme_json_cmd scalar directory -- \
    pvenode acme account info "${name}" --output-format json) || status=$?
  ((status == 0)) || return ${status}
  printf '%s' "${value}"
}

# Registers the account for this directory when the host has none.
#
# `pvenode acme account register` reads the agreement to the CA's terms of
# service from its standard input and has no option for it, so the answer
# is piped in. That answer is the operator's: the caller refuses to come
# this far until the configuration says the terms are accepted.
acme_account_converge() {
  local name=$1 contact=$2 directory=$3 current=''

  local exists=0 status=0
  acme_account_exists "${name}" || exists=$?
  case ${exists} in
    0)
      current=$(acme_account_directory "${name}") || status=$?
      if ((status != 0)) || [[ -z ${current} ]]; then
        die "The ACME account ${name} is registered, and which directory it is registered against could not be read from 'pvenode acme account info'. Refusing to go on: an account bound to the other directory would issue from the wrong CA."
      fi
      if [[ ${current} != "${directory}" ]]; then
        die "The ACME account ${name} is registered against ${current}, not ${directory}. Deactivate it with 'pvenode acme account deactivate ${name}' and run this again."
      fi
      printf 'unchanged\n'
      return 0
      ;;
    1) ;;
    *)
      die "Unable to read the ACME accounts on this node: 'pvenode acme account list' either failed or answered with something this toolkit cannot parse. Refusing to register, because registering over an account that is already there is not something a rerun can undo."
      ;;
  esac

  if dry_run_enabled; then
    log_info "would register the ACME account ${name} against ${directory}"
    printf 'changed\n'
    return 0
  fi

  log_info "running: pvenode acme account register ${name} ${contact} --directory ${directory}"
  printf 'y\n' |
    pvenode acme account register "${name}" "${contact}" --directory "${directory}" ||
    die "Unable to register the ACME account ${name}."
  printf 'changed\n'
}

# The credentials pvenode holds for a plugin, decoded.
#
# pvenode stores them base64url encoded, so comparing the encoded forms
# would report a difference whenever padding or line wrapping differed
# rather than the credentials themselves. Nothing here is printed to a log;
# the value is a credential and the caller compares it in memory.
# One field of a plugin's configuration: 0 with the value, 1 when the
# configuration does not carry that field, 2 when it could not be read.
_acme_plugin_field() {
  local id=$1 field=$2 status=0 value
  value=$(_acme_json_cmd scalar "${field}" -- \
    pvenode acme plugin config "${id}" --output-format json) || status=$?
  ((status == 0)) || return ${status}
  printf '%s' "${value}"
}

# Answers 0 with the credentials, 1 when the plugin holds none yet, and 2
# when what it holds could not be read. Only the second of those may lead
# to the plugin being written.
_acme_plugin_data() {
  local id=$1 status=0 encoded len stripped
  encoded=$(_acme_plugin_field "${id}" data) || status=$?
  ((status == 0)) || return ${status}
  [[ -n ${encoded} ]] || return 1
  encoded=${encoded//-/+}
  encoded=${encoded//_//}
  while ((${#encoded} % 4 != 0)); do
    encoded+='='
  done
  # A NUL in the decoded credentials would not survive the command
  # substitution the caller reads this through: bash drops the byte and
  # the text either side closes up, so credentials stored as
  # "ME_Key=te<NUL>st" would compare equal to the wanted "ME_Key=test"
  # and a corrupted credential would stay installed, reported as
  # unchanged. The decoder refuses a NUL in the JSON itself; this is the
  # same byte arriving inside base64. Count it on the pipe, where it
  # still exists, and call credentials carrying one unreadable.
  len=$(printf '%s' "${encoded}" | base64 -d 2>/dev/null | wc -c) || return 2
  stripped=$(printf '%s' "${encoded}" | base64 -d 2>/dev/null |
    tr -d '\0' | wc -c) || return 2
  [[ ${len} == "${stripped}" ]] || return 2
  printf '%s' "${encoded}" | base64 -d 2>/dev/null || return 2
}

# Whether pvenode already has this plugin.
#
#   0  it does
#   1  it does not
#   2  the question could not be answered
#
# The listing is what answers it. `pvenode acme plugin config` exits
# non-zero for a plugin that is not there and for a pvenode that could
# not answer at all, and reading the two as the same thing adds a plugin
# -- with the credentials in it -- on the strength of a failure. A
# helper that never decoded anything had no status to collapse, which is
# exactly why it kept the habit longer than the ones that did.
acme_plugin_exists() {
  local id=$1 names status=0 candidate
  names=$(_acme_json_cmd names plugin -- \
    pvenode acme plugin list --output-format json) || status=$?
  ((status == 0)) || return 2
  [[ -n ${names} ]] || return 1
  while IFS= read -r candidate; do
    [[ ${candidate} == "${id}" ]] && return 0
  done <<<"${names}"
  return 1
}

# Points the plugin at the credentials in path. pvenode reads that file
# itself and keeps its own copy, so the credentials travel as a path and
# never as an argument, where every process on the host could read them out
# of /proc.
#
# The comparison is against what pvenode stored, so rotated credentials are
# noticed and an unchanged file is left alone.
acme_plugin_converge() {
  local id=$1 api=$2 path=$3 content=$4
  local stored='' want='' verb='add' present=0

  acme_secret_begin
  # Command substitution drops the trailing newline the credentials file
  # ends with, so the comparison is made without one on either side.
  want=${content}
  while [[ ${want} == *$'\n' ]]; do
    want=${want%$'\n'}
  done

  local exists=0
  acme_plugin_exists "${id}" || exists=$?
  case ${exists} in
    0)
      present=1
      verb='set'
      ;;
    1) ;;
    *)
      acme_secret_die \
        "Unable to read the ACME DNS plugins on this node: 'pvenode acme plugin list' either failed or answered with something this toolkit cannot parse. Refusing to add a plugin, and the credentials with it, on the strength of a failure that may only mean pvenode could not answer." \
        stored want content
      ;;
  esac

  if ((present == 1)); then
    local data_status=0 api_status=0 stored_api=''
    # The api decides which provider's hook runs with these credentials,
    # so a plugin configured for another one is not converged however
    # well the credentials match. Leaving it alone would strand the node:
    # the hook would keep failing, and `pvenode acme cert order` is not
    # idempotent, so every run would order again and fail again.
    stored_api=$(_acme_plugin_field "${id}" api) || api_status=$?
    case ${api_status} in
      0) ;;
      1) stored_api='' ;;
      *)
        acme_secret_die \
          "The ACME DNS plugin ${id} is configured and which provider it is configured for could not be read. Refusing to overwrite it on the strength of a comparison that did not happen." \
          stored want content
        ;;
    esac
    stored=$(_acme_plugin_data "${id}") || data_status=$?
    case ${data_status} in
      0)
        if [[ ${stored_api} == "${api}" && ${stored} == "${want}" ]]; then
          stored=''
          want=''
          acme_secret_end
          printf 'unchanged\n'
          return 0
        fi
        ;;
      1) ;;
      *)
        acme_secret_die \
          "The ACME DNS plugin ${id} is configured and the credentials pvenode holds for it could not be read. Refusing to overwrite them on the strength of a comparison that did not happen." \
          stored want content
        ;;
    esac
  fi
  stored=''
  want=''
  acme_secret_end

  if dry_run_enabled; then
    log_info "would configure the ACME DNS plugin ${id}"
    printf 'changed\n'
    return 0
  fi

  if [[ ${present} -eq 1 ]]; then
    run_cmd pvenode acme plugin "${verb}" "${id}" --api "${api}" --data "${path}" ||
      die "Unable to update the ACME DNS plugin ${id}."
  else
    run_cmd pvenode acme plugin "${verb}" dns "${id}" --api "${api}" --data "${path}" ||
      die "Unable to add the ACME DNS plugin ${id}."
  fi
  printf 'changed\n'
}

# The comma separated elements of a Proxmox property string, one per line.
_acme_property_fields() {
  local text=$1 field
  local -a parts=()
  IFS=',' read -r -a parts <<<"${text}"
  for field in ${parts[@]+"${parts[@]}"}; do
    printf '%s\n' "${field}"
  done
}

# The value of one key=value element, matched whole.
_acme_property_value() {
  local text=$1 key=$2 field
  while IFS= read -r field; do
    if [[ ${field} == "${key}="* ]]; then
      printf '%s' "${field#*=}"
      return 0
    fi
  done < <(_acme_property_fields "${text}")
  return 1
}

# The domain an acmedomain entry names: either the bare first element or
# an explicit domain= key, which is how Proxmox writes it either way.
_acme_property_domain() {
  local text=$1 field
  while IFS= read -r field; do
    if [[ ${field} == 'domain='* ]]; then
      printf '%s' "${field#*=}"
      return 0
    fi
    if [[ -n ${field} && ${field} != *=* ]]; then
      printf '%s' "${field}"
      return 0
    fi
  done < <(_acme_property_fields "${text}")
  return 1
}

# True when the node already names this account and validates this domain
# through this plugin.
#
# Each field is compared whole. A substring test calls account=staging a
# match for xaccount=staging-extra, and a node pointed at another domain
# or another plugin would read as converged -- or order for the wrong
# name, against the same rate limit.
_acme_node_config_matches() {
  local fqdn=$1 plugin=$2 account=$3 status=0 acme domain value
  local have_acme=0 have_domain=0
  # Both managed settings are read before either is compared. Returning
  # "does not match" on the first one leaves the second unread, and the
  # caller writes over both -- including one that could not be read.
  acme=$(_acme_json_cmd scalar acme -- \
    pvenode config get --output-format json) || have_acme=$?
  ((have_acme == 2)) && return 2
  status=0
  domain=$(_acme_json_cmd scalar acmedomain0 -- \
    pvenode config get --output-format json) || status=$?
  ((status == 2)) && return 2
  have_domain=${status}

  # A node with neither setting yet is a node to configure; one whose
  # settings could not be read is a node to leave alone.
  ((have_acme == 0)) || return 1
  ((have_domain == 0)) || return 1
  value=$(_acme_property_value "${acme}" account) || return 1
  [[ ${value} == "${account}" ]] || return 1
  value=$(_acme_property_domain "${domain}") || return 1
  [[ ${value} == "${fqdn}" ]] || return 1
  value=$(_acme_property_value "${domain}" plugin) || return 1
  [[ ${value} == "${plugin}" ]]
}

acme_node_config_converge() {
  local fqdn=$1 plugin=$2 account=$3 status=0
  _acme_node_config_matches "${fqdn}" "${plugin}" "${account}" || status=$?
  case ${status} in
    0)
      printf 'unchanged\n'
      return 0
      ;;
    1) ;;
    *)
      die "Unable to read the ACME settings on this node: 'pvenode config get' either failed or answered with something this toolkit cannot parse. Refusing to write settings over ones that could not be compared."
      ;;
  esac
  run_cmd pvenode config set --acme "account=${account}" \
    --acmedomain0 "${fqdn},plugin=${plugin}" ||
    die "Unable to record the ACME settings on the node."
  printf 'changed\n'
}

# The organisations the two Let's Encrypt directories issue under. They
# are matched exactly: a test for the word "letsencrypt" anywhere accepts
# "Not LetsEncrypt Services" and "Lets Encrypt Compatible CA" as the real
# thing, and the whole point of reading the issuer is to tell the real
# thing from everything else.
#
# The cost of exactness is that a rename at the CA stops every host
# recognising its own certificate and orders again. That is the direction
# to fail in -- an order too many against staging, rather than trusting a
# certificate from a CA nobody chose -- but it is a rename worth watching
# for.
ACME_ISSUER_ORG_STAGING="(STAGING) Let's Encrypt"
ACME_ISSUER_ORG_PRODUCTION="Let's Encrypt"

# The elements of an X.509 distinguished name, one per line, honouring the
# backslash escaping that lets a value hold a comma of its own.
# A terminal backslash escapes nothing, so a name that ends in one is
# malformed rather than merely unusual. Dropping it quietly turns
# "O=Let's Encrypt\\" into the organisation this code accepts.
_acme_dn_fields() {
  local dn=$1 field='' char escaped=0 i
  for ((i = 0; i < ${#dn}; i++)); do
    char=${dn:i:1}
    if ((escaped)); then
      field+=${char}
      escaped=0
      continue
    fi
    case ${char} in
      \\) escaped=1 ;;
      ',')
        printf '%s\n' "${field}"
        field=''
        ;;
      *) field+=${char} ;;
    esac
  done
  ((escaped)) && return 1
  printf '%s\n' "${field}"
}

# The value of one attribute of a distinguished name, or nothing at all
# when the name does not parse.
_acme_dn_value() {
  local dn=$1 key=$2 fields field
  fields=$(_acme_dn_fields "${dn}") || return 1
  while IFS= read -r field; do
    field=$(_squash_ws "${field}")
    if [[ ${field} == "${key}="* ]]; then
      printf '%s' "${field#*=}"
      return 0
    fi
  done <<<"${fields}"
  return 1
}

# The CA environment an issuer belongs to: staging, production, or other.
#
# This names the authority rather than excluding a magic string, and
# "other" satisfies neither environment, so a certificate from an
# unrelated CA an operator installed by hand is never mistaken for one
# this stage ordered.
_acme_issuer_environment() {
  local issuer=$1 org
  if ! org=$(_acme_dn_value "${issuer}" O); then
    printf 'other\n'
    return 0
  fi
  org=$(_squash_ws "${org}")
  case ${org} in
    "${ACME_ISSUER_ORG_STAGING}") printf 'staging\n' ;;
    "${ACME_ISSUER_ORG_PRODUCTION}") printf 'production\n' ;;
    *) printf 'other\n' ;;
  esac
}

# True when a name in this SAN list covers the FQDN.
#
# A wildcard stands for exactly one label, and for a label that is there:
# *.example.net covers host.example.net, and covers neither
# host.sub.example.net nor example.net itself. Names are compared without
# case and without a trailing root dot, which are both forms a certificate
# can legitimately carry.
_acme_san_covers() {
  local fqdn=$1 san=$2 entry suffix prefix
  fqdn=${fqdn%.}
  fqdn=${fqdn,,}
  [[ -n ${fqdn} ]] || return 1
  while IFS= read -r entry; do
    entry=${entry%.}
    entry=${entry,,}
    [[ -n ${entry} ]] || continue
    if [[ ${entry} == "${fqdn}" ]]; then
      return 0
    fi
    [[ ${entry} == '*.'* ]] || continue
    suffix=${entry#\*.}
    [[ -n ${suffix} ]] || continue
    [[ ${fqdn} == *".${suffix}" ]] || continue
    prefix=${fqdn%".${suffix}"}
    if [[ -n ${prefix} && ${prefix} != *.* ]]; then
      return 0
    fi
  done <<<"${san}"
  return 1
}

# Whether the host already serves an ACME certificate for this name, from
# this environment, with more than the renewal window left on it.
#
#   0  it does, so an order would spend a rate limit for nothing
#   1  it does not, so a certificate has to be ordered
#   2  the question could not be answered
#
# The third answer is the point of the three. A failed command, empty
# output or JSON this code cannot read all look exactly like "no
# certificate" to a boolean, and the caller would respond by ordering --
# every run, against production, until the rate limit ran out. An
# inspection that failed stops the stage instead.
#
# The issuer is part of the test because a staging certificate and a
# production one are both valid certificates for the same name. Without
# it, a deployment promoted to production would keep the untrusted staging
# certificate and report itself done. The name is read from the SAN list,
# because that is what a client checks; a subject that happens to name
# this host proves nothing about what the certificate covers.
# What this host is serving, as one word on stdout, with status 0:
#
#   absent      nothing is serving pveproxy-ssl.pem
#   current     a certificate for this name, from this directory, in date
#   renewable   the same certificate, inside the renewal window
#   replace     a certificate for another name or another directory
#
# Status 2 means the listing could not be read, and nothing is printed.
#
# The last three are told apart because pvenode tells them apart.
# `cert order` refuses to overwrite a certificate that is already there
# unless it is forced, and `cert renew` is the command for one that is
# merely due. Treating all three as "order one" leaves a host that can
# never converge: every run asks for an order pvenode declines.
acme_cert_state() {
  local fqdn=$1 environment=$2 fields status=0 now
  local notafter='' issuer='' san='' field value deadline
  fields=$(_acme_json_cmd entry pveproxy-ssl.pem -- \
    pvenode cert info --output-format json) || status=$?
  # Nothing is serving pveproxy-ssl.pem yet, which is what a host that has
  # never ordered one looks like.
  if ((status == 1)); then
    printf 'absent\n'
    return 0
  fi
  ((status == 0)) || return 2

  while IFS=$'\t' read -r field value; do
    case ${field} in
      notafter) notafter=${value} ;;
      issuer) issuer=${value} ;;
      san) san+="${value}"$'\n' ;;
    esac
  done <<<"${fields}"
  [[ ${notafter} =~ ^[0-9]+$ ]] || return 2
  # A certificate listed with no SAN list covers nothing that was asked
  # for -- but something is serving that file, so replacing it is a
  # replacement rather than a first order.
  if [[ -z ${san} ]]; then
    printf 'replace\n'
    return 0
  fi

  # Both numbers are checked for being numbers before either reaches an
  # arithmetic context. Bash evaluates an array subscript inside $(( )),
  # so a string that arrives from outside -- the clock here, the JSON
  # field above -- is code until something proves it is a number.
  now=$(date +%s 2>/dev/null) || return 2
  [[ ${now} =~ ^[0-9]+$ ]] || return 2
  deadline=$((now + ACME_RENEW_WINDOW_DAYS * 86400))
  if ! _acme_san_covers "${fqdn}" "${san}" ||
    [[ $(_acme_issuer_environment "${issuer}") != "${environment}" ]]; then
    printf 'replace\n'
    return 0
  fi
  if ((notafter > deadline)); then
    printf 'current\n'
  else
    printf 'renewable\n'
  fi
  return 0
}

# 0 when this host is already serving what was asked for, 1 when it is
# not, 2 when the listing could not be read.
acme_cert_is_current() {
  local state status=0
  state=$(acme_cert_state "$1" "$2") || status=$?
  ((status == 0)) || return 2
  [[ ${state} == current ]]
}

# Orders a certificate. `force` overwrites whatever is serving
# pveproxy-ssl.pem now, which pvenode otherwise declines to do: it is how
# a host moves from the staging directory to production, or from a
# certificate for an old name to one for the name configured today.
acme_cert_order() {
  local force=${1:-no}
  local -a args=(pvenode acme cert order)
  if [[ ${force} == yes ]]; then
    args+=(--force 1)
  fi

  if dry_run_enabled; then
    log_info "would order an ACME certificate: ${args[*]}"
    printf 'changed\n'
    return 0
  fi

  run_cmd "${args[@]}" || die 'Unable to order the ACME certificate.'
  printf 'changed\n'
}

# Renews the certificate this host already holds. This is the command for
# one that matches what was asked for and is merely due: `cert order`
# would refuse it as an overwrite, and forcing an order to get past that
# asks the CA for a new certificate where a renewal is what was wanted.
acme_cert_renew() {
  if dry_run_enabled; then
    log_info 'would renew the ACME certificate: pvenode acme cert renew'
    printf 'changed\n'
    return 0
  fi

  run_cmd pvenode acme cert renew || die 'Unable to renew the ACME certificate.'
  printf 'changed\n'
}
