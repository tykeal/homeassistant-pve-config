#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
# SPDX-License-Identifier: Apache-2.0

# Tailscale subnet router convergence.
#
# The guest is a plain unprivileged Debian container built by the pinned
# community-scripts ct/debian.sh, and everything that makes it a subnet
# router is converged inside it through lib/target.sh. There is an upstream
# addon, tools/addon/add-tailscale-lxc.sh, that does the install half of
# this; it cannot be used. It blocks on a `read -rp` confirmation and then
# on a whiptail radiolist of container ids with no way to answer either
# from the environment, and it re-sources the upstream helpers from inside
# the container, where the pin this toolkit sets is not in scope. The
# install flow is therefore reimplemented here, over the same pinned
# sources, and every fetch goes through COMMUNITY_SCRIPTS_URL.
#
# The auth key is a secret and is treated as one. It never appears in an
# argument list, in a log line, or in the environment of anything this
# code runs: it is written to a 0600 file inside the container and
# `tailscale up` is told the path, which is what --auth-key=file: exists
# for. The file is removed again as soon as the login has been made.

# The JSON machinery lives in lib/acme.sh: the decoder preflight and the
# pipeline that hands a command's output to perl without it ever passing
# through a shell variable. Reusing it is deliberate -- a second
# hand-rolled reader of a JSON document is how the ACME stage grew the
# fail-open bug that took three review rounds to remove.
# shellcheck source=lib/acme.sh
source "${PVE_CONFIG_LIB_DIR:?PVE_CONFIG_LIB_DIR is unset}/acme.sh"

# Where the pieces live inside the container. Several of these are read
# only by stages/phase2/20-tailscale.sh, which shellcheck cannot see from
# here.
# shellcheck disable=SC2034
{
  TAILSCALE_AUTHKEY_PATH='/etc/pve-config/tailscale.authkey'
  TAILSCALE_AUTHKEY_DIR='/etc/pve-config'
  TAILSCALE_ADVERTISE_SCRIPT='/usr/local/bin/ts-advertise-route.sh'
  TAILSCALE_ADVERTISE_UNIT='ts-advertise-route.service'
  TAILSCALE_UNIT_PATH='/etc/systemd/system/ts-advertise-route.service'
  TAILSCALE_SYSCTL_PATH='/etc/sysctl.d/99-tailscale-forwarding.conf'
  TAILSCALE_KEYRING_PATH='/usr/share/keyrings/tailscale.gpg'
  TAILSCALE_LEGACY_KEYRING_PATH='/usr/share/keyrings/tailscale-archive-keyring.gpg'
  TAILSCALE_LEGACY_SOURCES_PATH='/etc/apt/sources.list.d/tailscale.list'
  TAILSCALE_SOURCES_PATH='/etc/apt/sources.list.d/tailscale.sources'
  TAILSCALE_REPO_BASE='https://pkgs.tailscale.com/stable'
}

# The SHA-256 of the repository signing key, pinned.
#
# Without a pin the key is trust-on-first-use: whatever answers that URL
# becomes the root of trust for every package apt then installs as root
# inside the guest, and a keyring already on disk is trusted forever for
# being non-empty. Pinning it here is the same decision issue #13 made for
# the community-scripts sources, applied to the other thing this stage
# downloads.
#
# Tailscale publishes one key for every Debian suite -- bullseye, bookworm
# and trixie serve byte-identical files -- so one digest covers them all.
# It is the SHA-256 of the DER keyring behind
# https://pkgs.tailscale.com/stable/debian/<suite>.noarmor.gpg, whose
# OpenPGP fingerprint is 2596 A99E AAB3 3821 893C 0A79 458C A832 957F 5868.
# A genuine upstream rotation stops this stage until the digest here is
# updated, which is the point; PVE_TAILSCALE_KEYRING_SHA256 is the escape
# hatch for a deployment that has verified a new key itself.
TAILSCALE_KEYRING_SHA256='3e03dacf222698c60b8e2f990b809ca1b3e104de127767864284e6c228f1fb39'

# The durable mark this toolkit puts on the container it owns.
#
# A container id is just a number, and the number this stage would pick is
# a number somebody else's container can already have. Without a mark,
# adoption means appending device permissions to, rebooting, installing
# packages into and joining to a tailnet whatever happens to live at that
# id. A Proxmox tag lives in the container's configuration, so it survives
# reboots, backups and upgrades, and `pct` and the web UI both show it.
TAILSCALE_OWNER_TAG='pve-config-tailscale'

# The container id this toolkit reaches for when nothing pins one. The
# issue calls 100 the convention and the examples call the allocation
# automatic; both are honoured, in that order.
TAILSCALE_DEFAULT_CTID=100

# The two lines that give a container /dev/net/tun. `var_tun` asks the
# upstream builder for them, and this toolkit converges them itself as
# well: a container that predates this stage, or that was built with the
# hint unset, needs them just as much, and the builder only writes them
# once, at create time.
TAILSCALE_TUN_CGROUP_LINE='lxc.cgroup2.devices.allow: c 10:200 rwm'
TAILSCALE_TUN_MOUNT_LINE='lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file'

# --- the secret region ----------------------------------------------------

# The same counted region lib/acme.sh keeps, for the same reason: a key is
# reachable for longer than any one helper here runs, xtrace_suspend and
# xtrace_resume do not nest, and an inner resume would put tracing back
# while an outer region still held the key.
#
# It is duplicated rather than shared because the two stages hold
# unrelated credentials and must be able to open and close their regions
# without seeing each other's depth counter. Moving either onto a shared
# counter is a refactor of lib/acme.sh, which is a working, reviewed
# secret path this change has no business disturbing.
_TAILSCALE_SECRET_DEPTH=0
_TAILSCALE_SECRET_XTRACE=0

tailscale_secret_begin() {
  if ((_TAILSCALE_SECRET_DEPTH == 0)); then
    case ${-} in
      *x*) _TAILSCALE_SECRET_XTRACE=1 ;;
      *) _TAILSCALE_SECRET_XTRACE=0 ;;
    esac
    set +x
  fi
  _TAILSCALE_SECRET_DEPTH=$((_TAILSCALE_SECRET_DEPTH + 1))
}

tailscale_secret_end() {
  if ((_TAILSCALE_SECRET_DEPTH > 0)); then
    _TAILSCALE_SECRET_DEPTH=$((_TAILSCALE_SECRET_DEPTH - 1))
  fi
  if ((_TAILSCALE_SECRET_DEPTH == 0)) && ((_TAILSCALE_SECRET_XTRACE == 1)); then
    _TAILSCALE_SECRET_XTRACE=0
    set -x
  fi
}

# Dies out of a secret region: clears the named variables, closes every
# region this process opened, then reports. Nothing between the clearing
# and the report can be traced with the key still in a variable.
tailscale_secret_die() {
  local message=$1 name
  shift
  for name in "$@"; do
    printf -v "${name}" '%s' ''
  done
  while ((_TAILSCALE_SECRET_DEPTH > 0)); do
    tailscale_secret_end
  done
  die "${message}"
}

# What the driver left in the environment, taken over from the handful of
# lines the stage runs with builtins before it sources anything. The
# capture cannot live here: sourcing lib/stage.sh forks, and a fork hands
# the child a copy of the environment.
_TAILSCALE_ENV_KEY=''
_TAILSCALE_ENV_KEY_SET=''

# Takes over the stage's boot capture, keeping the region it opened open.
# The stage already turned tracing off, so the region is seeded as entered
# rather than begun: beginning it here would record "tracing was off" and
# put nothing back at the end.
tailscale_authkey_adopt() {
  local xtrace=${1:-0} key_set=${2:-} key=${3:-}

  if ((_TAILSCALE_SECRET_DEPTH == 0)); then
    _TAILSCALE_SECRET_DEPTH=1
    _TAILSCALE_SECRET_XTRACE=${xtrace}
  fi

  _TAILSCALE_ENV_KEY_SET=${key_set}
  _TAILSCALE_ENV_KEY=${key}
  redact_register "${_TAILSCALE_ENV_KEY}"
}

# Drops the captured key and closes the region, for a run that turns out
# to have nothing to do.
tailscale_authkey_discard() {
  _TAILSCALE_ENV_KEY=''
  _TAILSCALE_ENV_KEY_SET=''
  while ((_TAILSCALE_SECRET_DEPTH > 0)); do
    tailscale_secret_end
  done
}

# The auth key, read into TAILSCALE_AUTHKEY without exporting it.
#
# The secrets file is parsed rather than sourced, and only after the
# ownership and permission checks the driver applies, so a file anybody
# else can reach is refused instead of read. An environment variable wins
# over the file, as it does for the ACME credentials: a rotation that has
# not reached secrets.env yet must not quietly use the key still on disk.
# A variable that is set but empty is an error rather than a fallback.
tailscale_authkey_read() {
  local path=$1 file_key=''

  tailscale_secret_begin
  TAILSCALE_AUTHKEY=''

  if [[ -e ${path} || -L ${path} ]]; then
    _secrets_check_path "${path}"
    _config_parse_file "${path}"
    file_key=${_CONFIG_PARSED[PVE_TAILSCALE_AUTHKEY]:-}
    _CONFIG_PARSED=()
    _CONFIG_PARSED_ORDER=()
  fi

  if [[ -n ${_TAILSCALE_ENV_KEY_SET} ]]; then
    TAILSCALE_AUTHKEY=${_TAILSCALE_ENV_KEY}
  else
    TAILSCALE_AUTHKEY=${file_key}
  fi
  file_key=''
  _TAILSCALE_ENV_KEY=''
  redact_register "${TAILSCALE_AUTHKEY}"

  if [[ -n ${_TAILSCALE_ENV_KEY_SET} && -z ${TAILSCALE_AUTHKEY} ]]; then
    tailscale_secret_die \
      'PVE_TAILSCALE_AUTHKEY is set in the environment but empty. Give it a value or unset it; an empty one is not a way to ask for the value in secrets.env.' \
      TAILSCALE_AUTHKEY
  fi

  if [[ -z ${TAILSCALE_AUTHKEY} ]]; then
    # Not an error here. A converged deployment whose operator has
    # revoked the spent key -- which is the responsible thing to do with
    # a key that has been used -- still has to be able to re-run this
    # stage, and only the paths that create or authenticate a machine
    # need a key at all. tailscale_authkey_require is where it is
    # demanded, at the point of use.
    tailscale_secret_end
    return 1
  fi

  # A key that is not shaped like one has almost always been truncated or
  # pasted with a stray quote, and the failure it causes otherwise is a
  # `tailscale up` that reports a backend error with nothing useful in it.
  if [[ ${TAILSCALE_AUTHKEY} != tskey-* ]]; then
    tailscale_secret_die \
      'PVE_TAILSCALE_AUTHKEY does not look like a Tailscale auth key: the keys Tailscale issues begin with tskey-. Check that the whole value was copied.' \
      TAILSCALE_AUTHKEY
  fi
  if [[ ${TAILSCALE_AUTHKEY} == *[[:space:]]* ]]; then
    tailscale_secret_die \
      'PVE_TAILSCALE_AUTHKEY contains whitespace. Tailscale auth keys do not, so this one has picked up a line break or a stray space.' \
      TAILSCALE_AUTHKEY
  fi

  tailscale_secret_end
}

# Demanded at the point of use, not before.
tailscale_authkey_require() {
  local why=$1
  [[ -n ${TAILSCALE_AUTHKEY:-} ]] && return 0
  tailscale_secret_die \
    "PVE_TAILSCALE_AUTHKEY is required to ${why}; add it to secrets.env. Generate a reusable key with the ephemeral option off, and see the README on key expiry." \
    TAILSCALE_AUTHKEY
}

# --- the auth key inside the container ------------------------------------

# The container the key file may be sitting in, or empty when there is no
# file to worry about. The stage's cleanup trap reads this.
_TAILSCALE_KEYFILE_TARGET=''

# Removes the key file and proves it has gone.
#
#   0  there is no key file in that container
#   1  there may still be one
#
# Every call that can die is made in a subshell, because this runs from a
# trap as well as from the stage: a `die` in a trap handler ends the run
# where it stands, with the thing the handler was cleaning up still there
# and nothing said about it.
tailscale_authkey_file_purge() {
  local target=$1 rc=0

  (target_remove_path "${target}" "${TAILSCALE_AUTHKEY_PATH}" >/dev/null) || rc=$?
  ((rc == 0)) || return 1
  if dry_run_enabled; then
    return 0
  fi

  # Absence is decided inside the subshell, not from its exit status
  # alone. target_test dies on a transport failure, and a die in there
  # exits the subshell non-zero exactly as a "no such file" would: read
  # the other way round, a pct that could not run would be proof that
  # the key had gone. Only a subshell that reached its own `exit 0` has
  # seen the file missing.
  (
    target_test "${target}" e "${TAILSCALE_AUTHKEY_PATH}" && exit 1
    exit 0
  ) || return 1
  return 0
}

# Armed immediately before the key is written and disarmed only once its
# removal has been confirmed, so that a pct that fails, a signal, or a
# removal that does not take cannot leave a usable auth key on disk inside
# a container that stays up for years.
tailscale_authkey_file_arm() {
  _TAILSCALE_KEYFILE_TARGET=$1
}

tailscale_authkey_file_disarm() {
  _TAILSCALE_KEYFILE_TARGET=''
}

# What the stage traps on. Puts back anything this run moved aside and
# takes the key file with it.
tailscale_cleanup() {
  local target=${_TAILSCALE_KEYFILE_TARGET}
  _TAILSCALE_KEYFILE_TARGET=''

  tailscale_default_vars_pop

  # The key spends an instant in a 0600 file on the host on its way into
  # the container, and a signal during `pct push` ends the run before
  # that file is removed. The guest copy is not the only copy.
  if ! target_scratch_purge; then
    log_error "A staging file in ${TMPDIR:-/tmp} could not be removed and may hold the Tailscale auth key. Delete any pve-config-target.* file there, and revoke the key in the Tailscale admin console under Settings, Keys."
  fi

  [[ -n ${target} ]] || return 0
  if ! tailscale_authkey_file_purge "${target}"; then
    log_error "Unable to remove ${TAILSCALE_AUTHKEY_PATH} from $(target_describe "${target}"). An auth key is still on disk in that container: delete that file, and revoke the key in the Tailscale admin console under Settings, Keys."
  fi
}

# --- reading what the node and the daemon report -------------------------

# A decoder for the two JSON documents this stage reads.
#
# There are deliberately two JSON programs in this toolkit, this one and
# _ACME_JSON_PROGRAM in lib/acme.sh. Do not merge them. This one exists
# for two things acme's cannot express and that the ACME stage never
# needed: refusing a document in which the field appears more than once
# (JSON::PP silently keeps the last of a repeated key and offers no
# allow_dupkeys, so that needs a lexer), and walking the cluster resource
# listing, which is an array of objects rather than a flat field read.
# Bending acme's program to cover both would mean editing the decoder
# that the ACME secret path depends on, for the benefit of a stage that
# does not share its threat model.
#
# What is reused rather than rewritten is the surrounding machinery:
# acme_require_json_decoder preflights perl for both, and
# _tailscale_json_cmd below is _acme_json_cmd's pipeline, which hands a
# command's standard output to perl without it passing through a shell
# variable.
#
# The program is a constant. The document arrives on standard input and
# the parameters arrive in @ARGV, so nothing a node or a tailnet said is
# ever interpolated into code.
#
#   0  the answer was read, and is on standard output
#   1  the document was read and does not have it
#   2  anything else, including a document that will not decode, a field
#      of the wrong shape, a duplicated field, and a perl that is absent
read -r -d '' _TAILSCALE_JSON_PROGRAM <<'PERL' || true
use strict;
use warnings;
use JSON::PP ();

my $mode = shift @ARGV;
exit 2 unless defined $mode;

binmode STDIN, ':raw';
binmode STDOUT, ':utf8';
my $raw = do { local $/; <STDIN> };
exit 2 unless defined $raw && length $raw;
exit 2 unless utf8::decode($raw);
exit 2 unless $raw =~ /\S/;

my $data = eval { JSON::PP->new->decode($raw) };
exit 2 if $@ or !defined $data;

my $probe = JSON::PP->new->allow_nonref;

sub text {
    my ($value) = @_;
    exit 2 unless defined $value;
    exit 2 if ref $value;
    exit 2 unless $probe->encode($value) =~ /\A"/;
    return $value;
}

sub emit {
    my (@parts) = @_;
    for my $part (@parts) {
        exit 2 if $part =~ /[\x00-\x1f\x7f]/;
    }
    print join("\t", @parts), "\n";
}

# How many times a name is used as a key of the outermost object.
#
# JSON::PP keeps the last of a repeated key and says nothing, so a
# document carrying BackendState twice decodes to whichever copy was
# written second. This walks the raw text as a lexer -- strings and their
# escapes, nothing else -- and counts the name at depth 1 only, so a peer
# object that happens to hold the same key is not counted and a value that
# merely looks like it cannot be.
#
# Each key token is handed back to JSON::PP before it is compared, rather
# than compared as it was spelled. A decoder reads "\u0042ackendState"
# and "BackendState" as the same key; a lexer comparing raw text reads
# them as two different ones, counts one of each, and waves through the
# duplicate it exists to refuse. Comparing decoded values is the only way
# the count here means the same thing as the decode below.
sub top_level_key_count {
    my ($text, $name) = @_;
    my @chars = split //, $text;
    my ($i, $depth, $count) = (0, 0, 0);
    my $n = scalar @chars;
    while ($i < $n) {
        my $c = $chars[$i];
        if ($c eq '"') {
            my $start = $i;
            $i++;
            my $value = '';
            while ($i < $n) {
                my $d = $chars[$i];
                if ($d eq '\\') {
                    $value .= $d . ($chars[$i + 1] // '');
                    $i += 2;
                    next;
                }
                last if $d eq '"';
                $value .= $d;
                $i++;
            }
            return -1 if $i >= $n;
            $i++;
            # JSON string semantics, from the decoder itself, so an
            # escaped spelling of the name cannot slip past.
            my $decoded = eval { $probe->decode('"' . $value . '"') };
            return -1 if $@ or !defined $decoded or ref $decoded;
            if ($depth == 1 && $decoded eq $name) {
                my $j = $i;
                $j++ while $j < $n && $chars[$j] =~ /\s/;
                $count++ if $j < $n && $chars[$j] eq ':';
            }
            next;
        }
        $depth++ if $c eq '{' || $c eq '[';
        $depth-- if $c eq '}' || $c eq ']';
        $i++;
    }
    return $count;
}

if ($mode eq 'field') {
    my $key = shift @ARGV;
    exit 2 unless defined $key;
    exit 2 unless ref $data eq 'HASH';
    exit 2 unless top_level_key_count($raw, $key) == 1;
    exit 1 unless exists $data->{$key};
    emit(text($data->{$key}));
} elsif ($mode eq 'tagged-cts') {
    my $tag = shift @ARGV;
    exit 2 unless defined $tag && length $tag;
    exit 2 unless ref $data eq 'ARRAY';
    my $found = 0;
    for my $item (@$data) {
        exit 2 unless ref $item eq 'HASH';
        # A listing entry with no type is a listing this code cannot
        # answer from, including about the containers it does describe.
        exit 2 unless exists $item->{type};
        next unless text($item->{type}) eq 'lxc';
        exit 2 unless exists $item->{vmid};
        my $vmid = $item->{vmid};
        exit 2 if !defined $vmid || ref $vmid;
        exit 2 unless "$vmid" =~ /\A[0-9]+\z/;
        # tags is absent on an untagged guest, which is a guest that is
        # certainly not this toolkit's.
        next unless exists $item->{tags};
        my @tags = split /[;, ]+/, text($item->{tags});
        next unless grep { $_ eq $tag } @tags;
        my $node = exists $item->{node} ? text($item->{node}) : '';
        emit("$vmid", $node);
        $found = 1;
    }
    exit 1 unless $found;
} elsif ($mode eq 'cluster-ids') {
    exit 2 unless ref $data eq 'ARRAY';
    my $found = 0;
    for my $item (@$data) {
        exit 2 unless ref $item eq 'HASH';
        exit 2 unless exists $item->{type};
        my $type = text($item->{type});
        next unless $type eq 'lxc' || $type eq 'qemu';
        exit 2 unless exists $item->{vmid};
        my $vmid = $item->{vmid};
        exit 2 if !defined $vmid || ref $vmid;
        exit 2 unless "$vmid" =~ /\A[0-9]+\z/;
        my $node = exists $item->{node} ? text($item->{node}) : '';
        emit("$vmid", $type, $node);
        $found = 1;
    }
    exit 1 unless $found;
} else {
    exit 2;
}
exit 0;
PERL

# Runs a command and decodes what it printed, as _acme_json_cmd does and
# for the same reasons: the document goes down a pipe rather than through
# a shell variable, and the decoder's parameters are never the command's.
_tailscale_json_cmd() {
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
    set +e
    "${cmd[@]}" 2>/dev/null |
      perl -e "${_TAILSCALE_JSON_PROGRAM}" -- ${params[@]+"${params[@]}"} 2>/dev/null
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

# --- naming and addressing ------------------------------------------------

# A container hostname is a DNS label and becomes a Tailscale machine
# name, so it is held to the label rules here rather than reaching pct as
# something it will quietly mangle. The upstream builder lowercases and
# strips spaces; a name that needed either is a name the operator did not
# get.
tailscale_hostname_valid() {
  local name=$1
  [[ ${#name} -le 63 ]] || return 1
  [[ ${name} =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]
}

# An IPv4 CIDR, strictly. This value is advertised to a whole tailnet and
# is interpolated into a command line, so a malformed one stops here.
tailscale_route_valid() {
  local route=$1 octets prefix
  [[ ${route} == */* ]] || return 1
  prefix=${route#*/}
  octets=${route%/*}
  [[ ${prefix} =~ ^(3[0-2]|[12][0-9]|[0-9])$ ]] || return 1
  [[ ${octets} =~ ^((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])$ ]]
}

# The subnets to advertise, as a comma separated list.
#
# A configured list is taken as given -- an operator who names subnets has
# a reason, and the container's own view of the LAN is not always the
# whole of what should be routed. Otherwise the bridge the guest will sit
# on is asked what it is connected to, which is the one answer that is
# right without being told.
tailscale_routes_resolve() {
  local __var=$1 configured=${2:-} bridge=$3
  local route detected joined=''

  if [[ -n ${configured} ]]; then
    local rest=${configured}
    while [[ -n ${rest} ]]; do
      route=${rest%%,*}
      if [[ ${rest} == *,* ]]; then
        rest=${rest#*,}
      else
        rest=''
      fi
      route=${route//[[:space:]]/}
      if [[ -z ${route} ]]; then
        continue
      fi
      if ! tailscale_route_valid "${route}"; then
        die "PVE_TAILSCALE_ROUTES names '${route}', which is not an IPv4 CIDR such as 192.168.1.0/24."
      fi
      # A default route is a legitimate thing to advertise and almost
      # never the thing somebody meant. Refusing it would be out of
      # proportion to a configured value, so say what it does and go on.
      if [[ ${route} == 0.0.0.0/0 ]]; then
        log_warn "PVE_TAILSCALE_ROUTES advertises 0.0.0.0/0, a default route. Any tailnet peer that accepts it sends all of its traffic through this container, not just traffic for this LAN. Name the subnets you mean instead, unless that is what you want."
      fi
      if [[ -n ${joined} ]]; then
        joined="${joined},${route}"
      else
        joined=${route}
      fi
    done
    if [[ -z ${joined} ]]; then
      die 'PVE_TAILSCALE_ROUTES is set but names no subnet. Leave it unset to advertise the subnet this node is on.'
    fi
    printf -v "${__var}" '%s' "${joined}"
    return 0
  fi

  detected=$(detect_ipv4_subnet "${bridge}" 2>/dev/null) || detected=''
  if [[ -z ${detected} ]]; then
    die "Unable to read the IPv4 subnet of ${bridge}, so there is nothing to advertise. Set PVE_TAILSCALE_ROUTES to the subnet or subnets this node should route, as a comma separated list of CIDRs."
  fi
  if ! tailscale_route_valid "${detected}"; then
    die "The subnet read from ${bridge} is '${detected}', which is not an IPv4 CIDR. Set PVE_TAILSCALE_ROUTES explicitly."
  fi
  printf -v "${__var}" '%s' "${detected}"
}

# --- the container --------------------------------------------------------

# Where pct keeps a container's configuration. pmxcfs presents it under
# /etc/pve on a real node; a test points PVE_CONFIG_ROOT elsewhere.
tailscale_ct_conf_path() {
  local ctid=$1
  printf '%s\n' "$(sysroot)/etc/pve/lxc/${ctid}.conf"
}

# True when this node already has that container.
#
# The configuration file is the question pct itself answers from, and it
# gives a yes or a no without an exit status to interpret: `pct status`
# reports an absent container and a broken pct with statuses that have
# been known to differ between releases, and guessing wrong here means
# either building a second router or refusing to build the first.
tailscale_ct_exists() {
  local ctid=$1
  [[ -f $(tailscale_ct_conf_path "${ctid}") ]]
}

# The tags a container carries on this node, space separated.
#
# Read from the configuration file rather than from `pct config`, which is
# the same source pct reads and gives an answer without an exit status to
# interpret.
tailscale_ct_tags() {
  local __var=$1 ctid=$2 body='' line value=''
  printf -v "${__var}" '%s' ''

  local path
  path=$(tailscale_ct_conf_path "${ctid}")
  [[ -f ${path} ]] || return 1
  _slurp body "${path}"
  while IFS= read -r line; do
    # Everything from the first section header on is a snapshot or a
    # pending change, not what the container is now. A tag this toolkit
    # once set and has since removed would otherwise authorise adopting
    # a container that no longer carries it.
    [[ ${line} == '['*']' ]] && break
    case ${line} in
      tags:*)
        value=${line#tags:}
        value=${value//[;,]/ }
        ;;
    esac
  done <<<"${body}"
  printf -v "${__var}" '%s' "${value}"
}

# True when a container on this node carries this toolkit's mark.
tailscale_ct_is_owned() {
  local ctid=$1 tags='' tag
  tailscale_ct_tags tags "${ctid}" || return 1
  for tag in ${tags}; do
    [[ ${tag} == "${TAILSCALE_OWNER_TAG}" ]] && return 0
  done
  return 1
}

# Puts the mark on, keeping whatever tags are already there.
tailscale_ct_tag_converge() {
  local ctid=$1 tags='' tag joined=''

  if tailscale_ct_is_owned "${ctid}"; then
    printf 'unchanged\n'
    return 0
  fi

  if dry_run_enabled && ! tailscale_ct_exists "${ctid}"; then
    log_info "would tag container ${ctid} with ${TAILSCALE_OWNER_TAG}"
    printf 'changed\n'
    return 0
  fi

  tailscale_ct_tags tags "${ctid}" || tags=''
  for tag in ${tags}; do
    # A tag Proxmox will not take back is a `pct set` that fails and
    # leaves the container unmarked, so only well formed ones are kept.
    [[ ${tag} =~ ^[A-Za-z0-9_.+-]+$ ]] || continue
    if [[ -n ${joined} ]]; then
      joined="${joined};${tag}"
    else
      joined=${tag}
    fi
  done
  if [[ -n ${joined} ]]; then
    joined="${joined};${TAILSCALE_OWNER_TAG}"
  else
    joined=${TAILSCALE_OWNER_TAG}
  fi

  run_cmd pct set "${ctid}" -tags "${joined}" ||
    die "Unable to tag container ${ctid} with ${TAILSCALE_OWNER_TAG}."
  printf 'changed\n'
}

# Every container in the cluster carrying this toolkit's mark, one
# "vmid<tab>node" per line.
#
#   0  at least one, on standard output
#   1  the listing was read and holds none
#   2  the listing could not be read
#
# Cluster-wide on purpose. /etc/pve/lxc is this node's view, and a router
# built on another node of the same cluster is invisible there -- so a
# node-local check would build a second subnet router advertising the same
# routes, which is a routing conflict in the tailnet rather than a
# duplicate container nobody notices.
tailscale_cluster_tagged() {
  local __var=$1 out='' rc=0
  printf -v "${__var}" '%s' ''

  out=$(_tailscale_json_cmd tagged-cts "${TAILSCALE_OWNER_TAG}" -- \
    pvesh get /cluster/resources --type vm --output-format json) || rc=$?
  if ((rc == 0)); then
    printf -v "${__var}" '%s' "${out}"
  fi
  return "${rc}"
}

# Every guest in the cluster, one "vmid<tab>type<tab>node" per line.
#
#   0  at least one, on standard output
#   1  the listing was read and holds none
#   2  the listing could not be read
#
# Guest ids are unique across a Proxmox cluster and across both guest
# types, so a virtual machine numbered 100 on any node makes container
# 100 impossible. /etc/pve/lxc answers for neither, and the builder
# quietly picks a different id when the one it is given is taken, which
# leaves an untagged container behind.
tailscale_cluster_ids() {
  local __var=$1 out='' rc=0
  printf -v "${__var}" '%s' ''

  out=$(_tailscale_json_cmd cluster-ids -- \
    pvesh get /cluster/resources --type vm --output-format json) || rc=$?
  if ((rc == 0)); then
    printf -v "${__var}" '%s' "${out}"
  fi
  return "${rc}"
}

# Where a guest id is in use in the cluster, as "type<tab>node", or
# nothing when it is free.
_tailscale_cluster_holder() {
  local __var=$1 guests=$2 want=$3 vmid type node
  printf -v "${__var}" '%s' ''
  while IFS=$'\t' read -r vmid type node; do
    [[ ${vmid} == "${want}" ]] || continue
    printf -v "${__var}" '%s' "${type}"$'\t'"${node}"
    return 0
  done <<<"${guests}"
  return 1
}

# The container id to work on, and whether it is already there.
#
# Nothing existing is touched without proof that this toolkit built it.
# The mark is a Proxmox tag, so the proof survives a reboot, a restore and
# a release upgrade, and it is checked before the first mutation rather
# than after the container has been rebooted into a new device profile.
#
# A pinned id wins, and must either be free or carry the mark.
# PVE_TAILSCALE_ADOPT_EXISTING=yes is the deliberate exception: it marks
# the container this run and says so, which makes a legitimate adoption
# possible and never silent.
tailscale_ctid_resolve() {
  local __var=$1 configured=${2:-} adopt=${3:-no}
  local found='' nextid='' line vmid node here='' rc=0

  # A gate on a destructive action, so a value that is neither yes nor no
  # is an error rather than a quiet "no": an operator who wrote `true`
  # would otherwise get a refusal with nothing to connect it to.
  [[ -z ${adopt} ]] && adopt=no
  case ${adopt} in
    yes | no) ;;
    *) die "PVE_TAILSCALE_ADOPT_EXISTING is '${adopt}', which is neither yes nor no. It decides whether this stage may take over a container it did not build, so it is not guessed at. Use exactly yes or no, in lower case." ;;
  esac

  here=$(detect_hostname_short 2>/dev/null) || here=''

  tailscale_cluster_tagged found || rc=$?
  if ((rc == 2)); then
    die "Unable to read 'pvesh get /cluster/resources --type vm' as JSON, so this node cannot tell whether a Tailscale subnet router already exists in this cluster. Building one anyway could advertise the same routes twice. Fix the cluster query, or set PVE_TAILSCALE_CTID to the id this router should have."
  fi

  local guests='' grc=0
  tailscale_cluster_ids guests || grc=$?
  if ((grc == 2)); then
    die "Unable to read 'pvesh get /cluster/resources --type vm' as JSON, so this node cannot tell which guest ids are already taken in this cluster. Fix the cluster query, or set PVE_TAILSCALE_CTID to the id this router should have."
  fi

  local -a mine=()
  if ((rc == 0)); then
    while IFS=$'\t' read -r vmid node; do
      [[ -n ${vmid} ]] || continue
      if [[ -n ${here} && -n ${node} && ${node} != "${here}" ]]; then
        die "A Tailscale subnet router built by this toolkit already exists in this cluster as container ${vmid} on node ${node}. Two routers advertising the same subnet is a routing conflict, not a spare. Run this stage on ${node}, or remove that container first."
      fi
      mine+=("${vmid}")
    done <<<"${found}"
  fi

  if ((${#mine[@]} > 1)); then
    die "More than one container on this node carries the ${TAILSCALE_OWNER_TAG} tag (${mine[*]}). Remove the tag from the ones that are not the subnet router, or set PVE_TAILSCALE_CTID to the one that is."
  fi

  if [[ -n ${configured} ]]; then
    [[ ${configured} =~ ^[0-9]+$ ]] ||
      die "PVE_TAILSCALE_CTID is '${configured}', which is not a container id."
    if ((configured < 100 || configured > 999999999)); then
      die "PVE_TAILSCALE_CTID is '${configured}'; Proxmox container ids run from 100 to 999999999."
    fi
    local holder=''
    if ! tailscale_ct_exists "${configured}" &&
      _tailscale_cluster_holder holder "${guests}" "${configured}"; then
      die "PVE_TAILSCALE_CTID is ${configured}, which is already taken in this cluster by a ${holder%%$'\t'*} guest on node ${holder##*$'\t'}. Guest ids are unique cluster wide, so no container can be built with that id. Pick a free one."
    fi
    if tailscale_ct_exists "${configured}" && ! tailscale_ct_is_owned "${configured}"; then
      if [[ ${adopt} != yes ]]; then
        die "Container ${configured} already exists on this node and does not carry the ${TAILSCALE_OWNER_TAG} tag, so this toolkit did not build it. Refusing to reboot it, give it /dev/net/tun, install packages in it and join it to your tailnet. Point PVE_TAILSCALE_CTID at a free id, or set PVE_TAILSCALE_ADOPT_EXISTING=yes if that container really is the subnet router."
      fi
      log_warn "adopting pre-existing container ${configured}, which this toolkit did not build, because PVE_TAILSCALE_ADOPT_EXISTING is yes"
    fi
    if ((${#mine[@]} == 1)) && [[ ${mine[0]} != "${configured}" ]]; then
      die "PVE_TAILSCALE_CTID is ${configured}, but container ${mine[0]} on this node already carries the ${TAILSCALE_OWNER_TAG} tag. Remove that container or its tag before moving the router to ${configured}."
    fi
    printf -v "${__var}" '%s' "${configured}"
    return 0
  fi

  if ((${#mine[@]} == 1)); then
    printf -v "${__var}" '%s' "${mine[0]}"
    return 0
  fi

  local holder=''
  if ! tailscale_ct_exists "${TAILSCALE_DEFAULT_CTID}" &&
    ! _tailscale_cluster_holder holder "${guests}" "${TAILSCALE_DEFAULT_CTID}"; then
    printf -v "${__var}" '%s' "${TAILSCALE_DEFAULT_CTID}"
    return 0
  fi

  nextid=$(pvesh get /cluster/nextid 2>/dev/null) || nextid=''
  nextid=${nextid//[$'\t\r\n ']/}
  [[ ${nextid} =~ ^[0-9]+$ ]] ||
    die "Container ${TAILSCALE_DEFAULT_CTID} is taken and 'pvesh get /cluster/nextid' did not answer with an id. Set PVE_TAILSCALE_CTID to the id this router should have."
  if tailscale_ct_exists "${nextid}" ||
    _tailscale_cluster_holder holder "${guests}" "${nextid}"; then
    die "'pvesh get /cluster/nextid' answered with ${nextid}, which is already taken in this cluster. Set PVE_TAILSCALE_CTID to the id this router should have."
  fi
  printf -v "${__var}" '%s' "${nextid}"
}

# Memory and cores for the router, scaled to the node.
#
# A subnet router forwards packets; it does not need much, and what it
# takes is taken from whatever else this node runs. The runbook this is
# built from asks for 256 MB and one core, which is the floor here, and a
# larger node is allowed a little more headroom rather than a share
# proportional to its size.
tailscale_resources() {
  local __ram=$1 __cores=$2
  # Named out of the way of the variables a caller is likely to pass:
  # `local ram` here would shadow the caller's `ram` and printf -v would
  # fill in the shadow.
  local __ts_host_ram='' __ts_host_cores='' __ts_ram=256 __ts_cores=1

  __ts_host_ram=$(detect_ram_mb 2>/dev/null) || __ts_host_ram=''
  __ts_host_cores=$(detect_cpu_cores 2>/dev/null) || __ts_host_cores=''

  if [[ ${__ts_host_ram} =~ ^[0-9]+$ ]]; then
    __ts_ram=$((__ts_host_ram / 64))
    ((__ts_ram >= 256)) || __ts_ram=256
    ((__ts_ram <= 1024)) || __ts_ram=1024
  fi
  if [[ ${__ts_host_cores} =~ ^[0-9]+$ ]] && ((__ts_host_cores >= 8)); then
    __ts_cores=2
  fi

  printf -v "${__ram}" '%s' "${__ts_ram}"
  printf -v "${__cores}" '%s' "${__ts_cores}"
}

# The storages on this node that accept a given content type.
tailscale_storage_names() {
  local __var=$1 content=$2 listing='' line name joined=''

  listing=$(pvesm status -content "${content}" 2>/dev/null) || listing=''
  while IFS= read -r line; do
    [[ -n ${line} ]] || continue
    read -r name _ <<<"${line}"
    if [[ ${name} == 'Name' || -z ${name} ]]; then
      continue
    fi
    if [[ -n ${joined} ]]; then
      joined="${joined} ${name}"
    else
      joined=${name}
    fi
  done <<<"${listing}"
  printf -v "${__var}" '%s' "${joined}"
}

# The storage the builder should put a template, or a root disk, on.
#
# The two are resolved separately and each is checked against the content
# type it is for. The commonest Proxmox layout by a wide margin has `local`
# holding templates and `local-lvm` or a ZFS pool holding root disks, and
# nothing on either accepts the other's content -- so one name used for
# both fails inside the builder, after the template has been downloaded
# and part of the work has been done.
#
# A configured name is therefore verified rather than trusted. Otherwise a
# node with exactly one storage of the right kind has no question to ask,
# and a node with several is told what to set, which is the one case where
# guessing would put a container somewhere the operator did not choose.
tailscale_storage_resolve() {
  local __var=$1 content=$2 configured=${3:-} setting=${4:-PVE_TAILSCALE_STORAGE}
  local available='' name count=0
  # The caller's variable is filled in by name, so nothing below may be
  # called after one of the locals here.

  tailscale_storage_names available "${content}"

  if [[ -n ${configured} ]]; then
    for name in ${available}; do
      if [[ ${name} == "${configured}" ]]; then
        printf -v "${__var}" '%s' "${configured}"
        return 0
      fi
    done
    die "${setting} names '${configured}', which is not a storage on this node that accepts '${content}' content. The storages that do are: ${available:-none}. Proxmox keeps templates and container root disks on different storages in most layouts, so set PVE_TAILSCALE_TEMPLATE_STORAGE and PVE_TAILSCALE_CONTAINER_STORAGE separately rather than one name for both."
  fi

  for name in ${available}; do
    count=$((count + 1))
  done

  if ((count == 1)); then
    printf -v "${__var}" '%s' "${available}"
    return 0
  fi

  if ((count == 0)); then
    die "No storage on this node accepts '${content}' content, so there is nowhere to build the Tailscale container. Add one, or name it with ${setting}."
  fi
  die "This node has more than one storage accepting '${content}' content (${available}). Set ${setting} to the one the Tailscale container belongs on; the upstream builder would otherwise stop on a menu nobody is there to answer."
}

# The upstream engine keeps its answers in a defaults file and consults it
# before it asks anything, so the storage decision is put there for as long
# as the builder is running and no longer.
#
# This file belongs to community-scripts, not to this toolkit, and it is
# the answer sheet for every build on the host. Leaving our storage choices
# in it would silently decide where somebody's next, unrelated container
# lands. It is therefore moved aside, replaced for the duration of one
# builder invocation, and put back.
TAILSCALE_DEFAULT_VARS_PATH='/usr/local/community-scripts/default.vars'

_TAILSCALE_VARS_PATH=''
_TAILSCALE_VARS_BACKUP=''

tailscale_default_vars_push() {
  local template_storage=$1 container_storage=$2 path dir

  path="$(sysroot)${TAILSCALE_DEFAULT_VARS_PATH}"
  dir=$(dirname -- "${path}")
  ensure_dir "${dir}" 0755 >/dev/null

  if [[ -L ${path} ]]; then
    die "Refusing to write through the symlink ${path}"
  fi

  _TAILSCALE_VARS_BACKUP=''
  if [[ -e ${path} ]]; then
    _TAILSCALE_VARS_BACKUP=$(mktemp "${path}.pve-config.XXXXXX") ||
      die "Unable to set ${TAILSCALE_DEFAULT_VARS_PATH} aside while the container is built."
    mv -- "${path}" "${_TAILSCALE_VARS_BACKUP}" || {
      rm -f -- "${_TAILSCALE_VARS_BACKUP}"
      _TAILSCALE_VARS_BACKUP=''
      die "Unable to set ${TAILSCALE_DEFAULT_VARS_PATH} aside while the container is built."
    }
  fi
  _TAILSCALE_VARS_PATH=${path}

  printf '%s\n' \
    "var_template_storage=${template_storage}" \
    "var_container_storage=${container_storage}" >"${path}" || {
    tailscale_default_vars_pop
    die "Unable to write the community-scripts storage answers to ${TAILSCALE_DEFAULT_VARS_PATH}."
  }
}

tailscale_default_vars_pop() {
  local path=${_TAILSCALE_VARS_PATH} backup=${_TAILSCALE_VARS_BACKUP}
  _TAILSCALE_VARS_PATH=''
  _TAILSCALE_VARS_BACKUP=''
  [[ -n ${path} ]] || return 0

  rm -f -- "${path}"
  if [[ -n ${backup} ]]; then
    mv -- "${backup}" "${path}" ||
      log_error "Unable to put ${TAILSCALE_DEFAULT_VARS_PATH} back; the original is at ${backup}."
  fi
}

# The upstream engine asks about telemetry with a whiptail dialog before a
# container build, and records the answer in this file.
#
# An unattended build has no terminal, so the dialog fails and the engine
# takes the else branch, which records "no". That is an answer given on the
# operator's behalf by an accident of there being no screen, so the stage
# says out loud that it is about to happen and how to decide it properly.
TAILSCALE_DIAGNOSTICS_PATH='/usr/local/community-scripts/diagnostics'

tailscale_diagnostics_warn() {
  local path
  path="$(sysroot)${TAILSCALE_DIAGNOSTICS_PATH}"
  if [[ -e ${path} ]]; then
    return 0
  fi
  log_warn "No ${TAILSCALE_DIAGNOSTICS_PATH} on this node: the community-scripts build will record DIAGNOSTICS=no for you, because its telemetry prompt cannot be answered without a terminal. Write DIAGNOSTICS=yes or DIAGNOSTICS=no into that file to decide it yourself; see the Telemetry section of the README."
}

# Appends a line to a container's configuration when an equivalent one is
# not already there.
#
# ensure_line_in_file is not usable on this path. It installs through a
# temporary file and a rename, and copies the ownership of what it
# replaces; pmxcfs implements neither chown nor the metadata copy, so the
# install fails on the real node while passing on any ordinary
# filesystem. An append is what upstream does to the same file and what
# pmxcfs supports. The decision about whether the line is already there is
# still common.sh's, so the host and the guest cannot disagree about what
# "present" means.
# A container configuration is the current settings followed by any
# number of `[name]` sections holding snapshots and pending changes. Only
# the part before the first header describes the container as it runs, so
# that is the part this reads and writes. Appending at the end of the
# file puts the TUN lines inside the last snapshot, where they do nothing
# and where the presence check then finds them.
_tailscale_conf_split() {
  local __current=$1 __rest=$2 body=$3 line head='' tail='' seen=0
  while IFS= read -r line; do
    if ((seen == 0)) && [[ ${line} == '['*']' ]]; then
      seen=1
    fi
    if ((seen)); then
      tail+="${line}"$'\n'
    else
      head+="${line}"$'\n'
    fi
  done <<<"${body}"
  printf -v "${__current}" '%s' "${head}"
  printf -v "${__rest}" '%s' "${tail}"
}

tailscale_conf_ensure_line() {
  local path=$1 line=$2 body='' current='' rest=''

  _slurp body "${path}"
  _tailscale_conf_split current rest "${body}"
  if _line_present_in_body "${current}" "${line}"; then
    printf 'unchanged\n'
    return 0
  fi

  if dry_run_enabled; then
    log_info "would add to ${path}: ${line}"
    printf 'changed\n'
    return 0
  fi

  [[ -f ${path} ]] ||
    die "There is no container configuration at ${path} to add the TUN device to."
  if [[ -L ${path} ]]; then
    die "Refusing to write through the symlink ${path}"
  fi

  if [[ -z ${rest} ]]; then
    printf '%s\n' "${line}" >>"${path}" ||
      die "Unable to add the TUN device line to ${path}"
  else
    # pmxcfs has no rename and no metadata copy, so this writes the file
    # in place rather than installing a replacement over it.
    printf '%s%s\n%s' "${current}" "${line}" "${rest}" >"${path}" ||
      die "Unable to add the TUN device line to ${path}"
  fi
  log_info "added to ${path}: ${line}"
  printf 'changed\n'
}

# `var_tun` is a hint to the upstream builder and nothing more: it is read
# at create time only, it writes these two lines itself when it is set,
# and `pct set` has no feature matching it. Both lines are converged here
# regardless of how the container came to exist.
tailscale_tun_converge() {
  local ctid=$1 path changed=0 state
  path=$(tailscale_ct_conf_path "${ctid}")

  state_of state tailscale_conf_ensure_line "${path}" "${TAILSCALE_TUN_CGROUP_LINE}"
  if [[ ${state} == changed ]]; then
    changed=1
  fi
  state_of state tailscale_conf_ensure_line "${path}" "${TAILSCALE_TUN_MOUNT_LINE}"
  if [[ ${state} == changed ]]; then
    changed=1
  fi

  if [[ ${changed} -eq 1 ]]; then
    printf 'changed\n'
  else
    printf 'unchanged\n'
  fi
}

# The container's run state, as pct reports it.
tailscale_ct_status() {
  local __var=$1 ctid=$2 out=''
  printf -v "${__var}" '%s' ''
  out=$(pct status "${ctid}" 2>/dev/null) || return 1
  out=${out#status: }
  out=${out%%[[:space:]]*}
  [[ -n ${out} ]] || return 1
  printf -v "${__var}" '%s' "${out}"
}

# Brings the container up and waits for pct to agree that it is up.
#
# The wait is on `pct status` rather than on a command inside the
# container: a readiness probe through pct exec would be a second,
# hand-rolled copy of the guest execution layer, and lib/target.sh exists
# so that there is only one.
tailscale_ct_wait_running() {
  local ctid=$1 attempts=${2:-30} status=''
  local i
  for ((i = 0; i < attempts; i++)); do
    if tailscale_ct_status status "${ctid}" && [[ ${status} == running ]]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

tailscale_ct_start() {
  local ctid=$1 status=''

  if tailscale_ct_status status "${ctid}" && [[ ${status} == running ]]; then
    printf 'unchanged\n'
    return 0
  fi

  if dry_run_enabled; then
    log_info "would start container ${ctid}"
    printf 'changed\n'
    return 0
  fi

  run_cmd pct start "${ctid}" ||
    die "Unable to start container ${ctid}."
  tailscale_ct_wait_running "${ctid}" ||
    die "Container ${ctid} was started but never reached the running state."
  printf 'changed\n'
}

# A container already running when its TUN lines were added is running
# without them: the configuration is read when the container starts.
tailscale_ct_restart() {
  local ctid=$1

  if dry_run_enabled; then
    log_info "would restart container ${ctid} so it picks up /dev/net/tun"
    printf 'changed\n'
    return 0
  fi

  run_cmd pct reboot "${ctid}" ||
    die "Unable to restart container ${ctid} after adding the TUN device."
  tailscale_ct_wait_running "${ctid}" ||
    die "Container ${ctid} never came back after the restart."
  printf 'changed\n'
}

# Every credential name this deployment knows about, as `env -u` arguments.
#
# The driver exports what it reads, so this process holds every credential
# the deployment has, and a child inherits all of them. The upstream
# container builder is a script fetched over the network: it has no
# business seeing a DNS API secret or a Zulip bot key, and neither has any
# of the maintainer scripts it runs inside the container it builds.
#
# Two sources, because neither alone is complete. The secrets file names
# what is on disk, so a secret added to the deployment tomorrow is
# scrubbed without this code changing. PVE_CONFIG_SECRET_KEYS is what the
# driver exported, which also covers a credential supplied only through
# the environment. A credential that is in neither -- set in the
# environment by hand, under a name the toolkit has never heard of -- is
# not scrubbed, and cannot be: nothing here can tell it from PATH.
declare -ga _TAILSCALE_ENV_SCRUB=()

tailscale_env_scrub_build() {
  local path=$1 key
  local -A seen=()
  _TAILSCALE_ENV_SCRUB=()

  for key in ${PVE_CONFIG_SECRET_KEYS:-}; do
    [[ ${key} =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    if [[ -z ${seen[${key}]:-} ]]; then
      seen["${key}"]=1
      _TAILSCALE_ENV_SCRUB+=(-u "${key}")
    fi
  done

  [[ -f ${path} ]] || return 0
  _secrets_check_path "${path}"
  _config_parse_file "${path}"
  for key in ${_CONFIG_PARSED_ORDER[@]+"${_CONFIG_PARSED_ORDER[@]}"}; do
    if [[ -z ${seen[${key}]:-} ]]; then
      seen["${key}"]=1
      _TAILSCALE_ENV_SCRUB+=(-u "${key}")
    fi
  done
  _CONFIG_PARSED=()
  _CONFIG_PARSED_ORDER=()
}

# Builds the container with the pinned community-scripts ct/debian.sh.
#
# `mode=default` is set explicitly. The engine does fall back to a silent
# run when there is no terminal, but only on the update path; a create
# with no mode reaches the whiptail settings menu and waits there for
# somebody who is not coming.
#
# The script is fetched through COMMUNITY_SCRIPTS_URL, which is the pin,
# and it is handed COMMUNITY_SCRIPTS_CORE_URL so that the engine it
# sources is pinned too. An unpinned fetch of either is the thing this
# whole arrangement exists to prevent.
tailscale_ct_create() {
  local ctid=$1 hostname=$2 ram=$3 cores=$4 disk=$5 bridge=$6
  local template_storage=$7 container_storage=$8
  local url script rc=0

  url="${COMMUNITY_SCRIPTS_URL}/ct/debian.sh"

  if dry_run_enabled; then
    log_info "would build container ${ctid} (${hostname}) from ${url}"
    printf 'changed\n'
    return 0
  fi

  script=$(mktemp) || die 'Unable to create a temporary file for the container builder.'
  if ! curl -fsSL "${url}" -o "${script}"; then
    rm -f -- "${script}"
    die "Unable to fetch the pinned container builder from ${url}."
  fi

  tailscale_env_scrub_build "${PVE_CONFIG_DIR:-/root/pve-config}/secrets.env"

  # The storage answers this build reads out of default.vars are put
  # there by the caller, not here: this runs inside the command
  # substitution state_of uses to collect a state, so a backup taken here
  # would belong to a subshell and the stage's cleanup trap would have
  # nothing to put back.
  log_info "building container ${ctid} (${hostname}) with the pinned community-scripts ct/debian.sh"
  env ${_TAILSCALE_ENV_SCRUB[@]+"${_TAILSCALE_ENV_SCRUB[@]}"} \
    TERM=dumb \
    mode=default \
    var_ctid="${ctid}" \
    var_hostname="${hostname}" \
    var_unprivileged=1 \
    var_nesting=1 \
    var_tun=yes \
    var_ram="${ram}" \
    var_cpu="${cores}" \
    var_disk="${disk}" \
    var_brg="${bridge}" \
    var_net=dhcp \
    var_ipv6_method=none \
    var_template_storage="${template_storage}" \
    var_container_storage="${container_storage}" \
    bash "${script}" || rc=$?
  rm -f -- "${script}"

  ((rc == 0)) ||
    die "The community-scripts container builder failed with status ${rc}; container ${ctid} was not created."
  tailscale_ct_exists "${ctid}" ||
    die "The community-scripts container builder reported success but there is no configuration for container ${ctid}. It may have allocated a different id; set PVE_TAILSCALE_CTID and run again."
  printf 'changed\n'
}

# --- inside the container -------------------------------------------------

# The Debian release the container is running, read from its own
# os-release rather than assumed from the host's.
#
# The file is pulled out and parsed here instead of being sourced inside
# the container: sourcing untrusted shell is how a crafted os-release runs
# as root, and the value is about to be interpolated into an apt source.
tailscale_guest_codename() {
  local __var=$1 target=$2 body='' line value=''

  target_slurp body "${target}" /etc/os-release ||
    die "Unable to read /etc/os-release from $(target_describe "${target}")."

  while IFS= read -r line; do
    case ${line} in
      VERSION_CODENAME=*)
        value=${line#VERSION_CODENAME=}
        value=${value//\"/}
        value=${value//\'/}
        ;;
    esac
  done <<<"${body}"

  [[ ${value} =~ ^[a-z][a-z0-9]*$ ]] ||
    die "The container reports VERSION_CODENAME='${value}', which is not a Debian release name this toolkit will put into an apt source."
  printf -v "${__var}" '%s' "${value}"
}

# The deb822 source Tailscale publishes, written whole rather than
# appended to, so a release upgrade rewrites it instead of stacking a
# second suite into it.
tailscale_sources_body() {
  local codename=$1
  printf '%s\n' \
    'Types: deb' \
    "URIs: ${TAILSCALE_REPO_BASE}/debian" \
    "Suites: ${codename}" \
    'Components: main' \
    "Signed-By: ${TAILSCALE_KEYRING_PATH}"
}

# Fetches the repository signing key into the container, and proves it is
# the key this toolkit expects.
#
# The download happens inside the container rather than on the node. A
# keyring is binary, `read -r -d ''` stops at the first NUL, and every
# path this toolkit has for moving a file into a container carries it in a
# shell variable on the way -- so a keyring pushed that way would arrive
# truncated at its first zero byte and apt would reject the repository
# with a signature error that says nothing about why. curl writing the
# file in place never puts the bytes in a variable at all.
#
# What arrives is checked against a pinned SHA-256 before apt is told to
# trust it, and a keyring already on disk is checked the same way rather
# than being trusted for existing. Anything else is trust on first use:
# whatever answered that URL -- an intercepted TLS session, a compromised
# mirror -- would become the root of trust for packages installed as root
# inside the guest, and a rotated or truncated key would never converge.
tailscale_keyring_converge() {
  local target=$1 codename=$2 url expected actual=''

  expected=${PVE_TAILSCALE_KEYRING_SHA256:-${TAILSCALE_KEYRING_SHA256}}
  expected=${expected,,}
  [[ ${expected} =~ ^[0-9a-f]{64}$ ]] ||
    die "PVE_TAILSCALE_KEYRING_SHA256 is '${PVE_TAILSCALE_KEYRING_SHA256:-}', which is not a SHA-256 digest: 64 hexadecimal digits."

  url="${TAILSCALE_REPO_BASE}/debian/${codename}.noarmor.gpg"

  if target_test "${target}" f "${TAILSCALE_KEYRING_PATH}"; then
    if tailscale_keyring_digest actual "${target}" &&
      [[ ${actual} == "${expected}" ]]; then
      printf 'unchanged\n'
      return 0
    fi
    log_warn "The key in ${TAILSCALE_KEYRING_PATH} inside $(target_describe "${target}") is ${actual:-unreadable}, not the pinned ${expected}. Replacing it; apt was trusting a key this toolkit cannot account for."
    if dry_run_enabled; then
      log_info "would replace the Tailscale repository key from ${url} on $(target_describe "${target}")"
      printf 'changed\n'
      return 0
    fi
    target_remove_path "${target}" "${TAILSCALE_KEYRING_PATH}" >/dev/null
  elif dry_run_enabled; then
    log_info "would install the Tailscale repository key from ${url} on $(target_describe "${target}")"
    printf 'changed\n'
    return 0
  fi

  target_ensure_dir "${target}" /usr/share/keyrings 0755 >/dev/null
  target_run "${target}" curl -fsSL -o "${TAILSCALE_KEYRING_PATH}" "${url}" ||
    die "Unable to fetch the Tailscale repository key from ${url} inside $(target_describe "${target}")."

  if ! tailscale_keyring_digest actual "${target}"; then
    target_remove_path "${target}" "${TAILSCALE_KEYRING_PATH}" >/dev/null
    die "The Tailscale repository key fetched from ${url} could not be read back to check its digest."
  fi
  if [[ ${actual} != "${expected}" ]]; then
    target_remove_path "${target}" "${TAILSCALE_KEYRING_PATH}" >/dev/null
    die "The key fetched from ${url} has SHA-256 ${actual}, not the pinned ${expected}. Refusing to let apt install packages as root from a repository signed by a key this toolkit cannot recognise. If Tailscale has rotated its signing key, verify the new one and set PVE_TAILSCALE_KEYRING_SHA256."
  fi
  target_run "${target}" chmod 0644 "${TAILSCALE_KEYRING_PATH}" ||
    die "Unable to set the permissions on ${TAILSCALE_KEYRING_PATH} in $(target_describe "${target}")."

  printf 'changed\n'
}

# The SHA-256 of the keyring as the container holds it, computed in the
# container so the bytes are never carried out through a shell variable.
tailscale_keyring_digest() {
  local __var=$1 target=$2 out=''
  printf -v "${__var}" '%s' ''

  target_capture out "${target}" sha256sum "${TAILSCALE_KEYRING_PATH}" || return 1
  out=${out%% *}
  out=${out,,}
  [[ ${out} =~ ^[0-9a-f]{64}$ ]] || return 1
  printf -v "${__var}" '%s' "${out}"
}

# The helper that keeps the advertised routes right.
#
# It is the only thing that ever sets them after the first login, and it
# has two modes, chosen by the caller according to where the routes came
# from.
#
# A non-empty list is one the operator configured, resolved and
# normalised. It is baked in and advertised as given, because a list
# somebody chose is not something to re-derive behind their back.
#
# An empty list means the routes were detected, and the derivation below
# is then the live mechanism rather than a fallback: it reads the
# connected subnet of whichever interface carries the default route, in
# the container, on every boot. That is what keeps the advertisement
# right across a reboot, a DHCP change or a LAN renumber without anyone
# running this toolkit again.
#
# `ip route` is read rather than `ip addr` because the interface is
# whichever one holds the default route, and a tailscale* interface is
# refused so the router cannot come to advertise its own tunnel.
#
# `tailscale set` is convergent at the daemon: setting the routes it
# already has changes nothing and reports success, so this can run on
# every boot without a guard of its own.
# The three bodies below carry SPDX headers of their own, for the files
# they become inside the container. REUSE reads this file rather than
# those, so it is told to leave them alone.
# REUSE-IgnoreStart
tailscale_advertise_script_body() {
  local configured=${1:-}
  cat <<EOF
#!/bin/sh
# SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
# SPDX-License-Identifier: Apache-2.0
#
# Managed by pve-config. Advertise this container's connected LAN subnet
# to the tailnet. Edits are overwritten on the next run.
set -eu

CONFIGURED_ROUTES='${configured}'

routes=\${CONFIGURED_ROUTES}

if [ -z "\${routes}" ]; then
  dev=\$(ip -4 -o route show default 2>/dev/null |
    awk '{ for (i = 1; i < NF; i++) if (\$i == "dev") { print \$(i + 1); exit } }')
  if [ -z "\${dev}" ]; then
    echo 'ts-advertise-route: no IPv4 default route, nothing to advertise' >&2
    exit 1
  fi
  case \${dev} in
    tailscale*)
      echo "ts-advertise-route: the default route is over \${dev}, refusing to advertise the tailnet back to itself" >&2
      exit 1
      ;;
  esac
  routes=\$(ip -4 -o route show dev "\${dev}" 2>/dev/null |
    awk '/proto kernel/ { print \$1; exit }')
fi

if [ -z "\${routes}" ]; then
  echo 'ts-advertise-route: no connected IPv4 subnet to advertise' >&2
  exit 1
fi

exec tailscale set --advertise-routes="\${routes}"
EOF
}

tailscale_advertise_unit_body() {
  cat <<EOF
# SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
# SPDX-License-Identifier: Apache-2.0
#
# Managed by pve-config. Edits are overwritten on the next run.
[Unit]
Description=Advertise the connected LAN subnet to Tailscale
After=network-online.target tailscaled.service
Wants=network-online.target
Requires=tailscaled.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${TAILSCALE_ADVERTISE_SCRIPT}

[Install]
WantedBy=multi-user.target
EOF
}

tailscale_sysctl_body() {
  printf '%s\n' \
    '# SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>' \
    '# SPDX-License-Identifier: Apache-2.0' \
    '#' \
    '# Managed by pve-config. A subnet router forwards for its LAN.' \
    'net.ipv4.ip_forward = 1'
}
# REUSE-IgnoreEnd

# Forwarding, persisted and applied.
#
# A drop-in rather than an edit of /etc/sysctl.conf: the distribution owns
# that file, a drop-in is removable in one piece, and the value this
# toolkit sets is visible as this toolkit's. The running value is only
# written when it differs, so a converged run touches nothing.
tailscale_forwarding_converge() {
  local target=$1 changed=0 state current=''

  state_of state target_write_file "${target}" "${TAILSCALE_SYSCTL_PATH}" \
    "$(tailscale_sysctl_body)" 0644
  if [[ ${state} == changed ]]; then
    changed=1
  fi

  if target_capture current "${target}" sysctl -n net.ipv4.ip_forward; then
    current=${current//[[:space:]]/}
  else
    current=''
  fi

  if [[ ${current} != 1 ]]; then
    changed=1
    target_run "${target}" sysctl -w net.ipv4.ip_forward=1 >/dev/null ||
      die "Unable to enable IPv4 forwarding in $(target_describe "${target}")."
  fi

  if [[ ${changed} -eq 1 ]]; then
    printf 'changed\n'
  else
    printf 'unchanged\n'
  fi
}

# What tailscaled printed, on standard output, for the decoder to read.
#
# A function rather than a command so that _tailscale_json_cmd can run it
# the way acme runs pvenode: its output goes straight down a pipe into
# perl. A `die` inside target_capture ends this subshell, which the
# pipeline reports as a source command that failed -- which is the right
# answer, since a container that cannot be reached has told us nothing.
#
# One difference from the ACME path, deliberately accepted. ACME pipes a
# command's output directly into the decoder; this reads the container's
# output through target_capture, which is command substitution, which
# drops NUL bytes. lib/target.sh offers no way to pipe a guest command's
# stdout onwards without that round trip.
#
# It is tolerable here because of which way the resulting failure falls.
# --peers=false leaves a document built entirely by tailscaled from its
# own state: no peer names, no tailnet member can put bytes in it. A NUL
# would therefore have to come from the daemon itself, and stripping one
# can only corrupt the document -- which the decoder refuses, giving
# outcome 2, which withholds the key. The realistic failure is "this
# looks unreadable, so do nothing", never "this looks logged out, so
# spend a key". ACME had no such margin: its document carried
# operator-supplied and CA-supplied strings.
_tailscale_status_emit() {
  local target=$1 out=''
  target_capture out "${target}" tailscale status --peers=false --json || return 1
  printf '%s' "${out}"
}

# Whether the container is already joined to a tailnet.
#
#   0  it is, and the backend is running
#   1  it is not, and said so in a document this code decoded
#   2  this code could not tell
#   3  it is, but the backend is stopped: an identity with nothing routing
#
# The four are kept apart on purpose, and the caller spends an auth key
# on 1 alone. A probe that folded "the command failed", "the document will
# not decode" and "the daemon says NeedsLogin" into one false would answer
# every unreadable reply by spending a key -- the fail-open shape the ACME
# stage took three review rounds to remove.
#
# --peers=false keeps the reply to this machine's own state, the document
# is decoded by JSON::PP rather than matched against, the field is read
# from the top-level object only, and a document that names it twice is
# refused: a tailnet's peer names are chosen by other people, and a peer
# called "BackendState":"Running" is a thing a hostile member can arrange.
tailscale_login_state() {
  local target=$1 state='' rc=0

  state=$(_tailscale_json_cmd field BackendState -- \
    _tailscale_status_emit "${target}") || rc=$?
  ((rc == 0)) || return 2

  case ${state} in
    Running | Starting) return 0 ;;
    Stopped)
      # `tailscale down` has been run, or the backend stopped on its own.
      # The machine keeps its identity, so another auth key is the wrong
      # answer; but a subnet router that routes nothing is not a state
      # this stage may call converged either, so the caller brings it
      # back up with no key at all.
      return 3
      ;;
    NeedsLogin | NoState) return 1 ;;
    NeedsMachineAuth)
      die "The Tailscale container is waiting for machine authorisation: approve it in the Tailscale admin console under Machines, or turn off device approval for this tailnet. Spending another auth key will not change this."
      ;;
    *) return 2 ;;
  esac
}

# The message for a probe that could not tell. Kept in one place because
# both the dry run and the real run have to refuse the same way.
tailscale_login_state_unreadable() {
  local target=$1
  printf '%s' "Unable to read what the Tailscale daemon in $(target_describe "${target}") reports about itself: 'tailscale status --peers=false --json' failed, or answered with something this toolkit will not decode. Refusing to spend an auth key on a machine that may already be logged in. Run that command in the container and look at what it says."
}
