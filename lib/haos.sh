#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
# SPDX-License-Identifier: Apache-2.0

# Home Assistant OS virtual machine convergence.
#
# The guest is the appliance image Home Assistant publishes. Nothing is
# converged inside it: HAOS is a closed appliance with its own
# authentication, onboarding and update mechanism, it has no package
# manager this toolkit could drive and no account model it could add an
# administrator to. What this library converges is everything around it --
# which id the machine has, which storage it lands on, how much of the
# node it is given, that the toolkit can tell its own machine from
# somebody else's, and that the disk image it boots is the one that was
# verified.
#
# The container stages drive the pinned community-scripts ct/ helpers. The
# machine here is built with qm directly, and the asymmetry is deliberate:
#
#   * Integrity. vm/haos-vm.sh fetches its image with vm_fetch_image
#     --cache --verify-xz and no --sha256, and vm_image_checksum has no
#     case for Home Assistant's download hosts, so upstream checks the
#     download by unpacking it and by nothing else. Putting a verified
#     file in its cache first makes the happy path safe and leaves every
#     other path -- a cache entry that disappears, bytes that fail
#     _vm_image_ok, a release that moved between two fetches -- falling
#     through to an unchecked download. Fetching the pinned image here is
#     the only arrangement in which the image that boots is the image
#     this toolkit verified.
#   * Ownership. The helper creates the machine tagged community-script
#     and starts it, and any mark this toolkit added would land after it
#     was already running. An interrupted build would leave an untagged
#     machine that the next run reads as somebody else's, and the run
#     after that would build a second Home Assistant beside the first.
#     Creating the machine here puts the mark in the `qm create` that
#     brings it into existence, so there is no window in which this
#     toolkit's own machine is unrecognisable.
#   * Release choice. The helper has no version override: it reads
#     whatever the project currently calls stable and installs that. A
#     pinned release is not expressible through it.
#
# The build below is a port of the pinned vm/haos-vm.sh recipe, and the
# qm invocations carry the upstream lines they came from. The container
# path keeps using the upstream helpers, whose template fetch has
# different integrity properties and whose work this toolkit has no wish
# to reproduce.

# The JSON machinery lives in lib/acme.sh: the decoder preflight and the
# pipeline that hands a command's output to perl without it ever passing
# through a shell variable. The program below is this library's own, for
# the reasons set out above _HAOS_JSON_PROGRAM.
# shellcheck source=lib/acme.sh
source "${PVE_CONFIG_LIB_DIR:?PVE_CONFIG_LIB_DIR is unset}/acme.sh"

# The tag that says this toolkit built a machine.
#
# Named after the stage rather than after the toolkit, so a node that also
# runs the Tailscale stage carries two distinguishable marks and neither
# stage can adopt the other's guest.
HAOS_OWNER_TAG='pve-config-haos'

# The id the convention asks for. Issue #11 names 200; 100 belongs to the
# subnet router and 110 to Frigate.
HAOS_DEFAULT_VMID=200

# The Home Assistant OS release this toolkit installs, and the SHA-256 of
# the image it publishes for it.
#
# Pinned for the same reason the community-scripts commits are pinned: a
# deployment built from a given release of this toolkit has to get the
# same appliance, and the digest is the only thing that makes the download
# an installation of what was reviewed rather than of whatever answered.
# Both are overridable -- PVE_HAOS_VERSION and PVE_HAOS_IMAGE_SHA256 --
# because a release this toolkit has not caught up with is a thing an
# operator may legitimately want, and neither is usable without the other.
#
# Verified 2026-10-27 against the SHA256SUMS asset of the release.
HAOS_IMAGE_VERSION='18.4'
HAOS_IMAGE_SHA256='756ec485b1b153099ca53e88a5eebd63a801d56b791afe5c6d63ef94a35dc02d'

# How large the disk in that image is. The appliance can be given more,
# and qm does not shrink a disk, so this is also the floor. Read by the
# stage rather than here.
# shellcheck disable=SC2034  # used by stages/phase2/40-haos.sh
HAOS_IMAGE_DISK_GB=32

# Where the image comes from: the release asset Home Assistant publishes,
# which is fetched and checked against a pinned digest here.
HAOS_RELEASE_BASE='https://github.com/home-assistant/operating-system/releases/download'

# Where the verified image is kept between runs. The same directory
# Proxmox keeps downloaded templates and images in, so an operator
# looking for what a build used finds it where such things live.
HAOS_IMAGE_CACHE_DIR='/var/lib/vz/template/cache'

# What an external command is allowed to keep of this process's
# environment.
#
# The driver exports every configuration value it reads, credentials
# included, so a child started from here would otherwise inherit a DNS API
# secret, a Tailscale auth key and whatever else the shell that invoked
# the toolkit happened to be carrying -- a cloud credential, a GH_TOKEN. A
# list of names to remove can only ever cover the names somebody thought
# of; this is the other way round, and nothing not named here survives.
#
# The proxy variables are kept because a node behind one cannot fetch
# anything without them, and the fetch is verified against a pinned digest
# whatever route it took.
#
# Overridable for the same reason COMMUNITY_SCRIPTS_URL is: the test suite
# points its mocks' own knobs through it. It cannot weaken anything,
# because whoever can set it already owns this process's environment.
HAOS_ENV_KEEP="${HAOS_ENV_KEEP:-PATH HOME TMPDIR LANG LC_ALL TERM http_proxy https_proxy ftp_proxy no_proxy HTTP_PROXY HTTPS_PROXY FTP_PROXY NO_PROXY}"

# Fills _HAOS_ENV_CMD with the `env -i NAME=value ...` prefix that runs a
# command with that environment and no other.
declare -ga _HAOS_ENV_CMD=()

_haos_clean_env() {
  local name
  _HAOS_ENV_CMD=(env -i)
  for name in ${HAOS_ENV_KEEP}; do
    [[ ${name} =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    [[ -n ${!name+set} ]] || continue
    _HAOS_ENV_CMD+=("${name}=${!name}")
  done
}

# A whole number small enough to do arithmetic on.
#
# Bash arithmetic is 64-bit and wraps, so a digit string long enough gets
# past a comparison with a floor or a ceiling by overflowing it: 2**64+100
# compares as 100. Length is checked first, as text, and nine digits is
# more than any of memory in megabytes, cores, gigabytes of disk or a
# Proxmox guest id can legitimately be.
_haos_is_number() {
  [[ $1 =~ ^[0-9]{1,9}$ ]]
}

# --- reading what the node and the network say ----------------------------
#
# A second decoder, rather than another mode bolted onto the one in
# lib/acme.sh, for the reason set out above _TAILSCALE_JSON_PROGRAM: the
# ACME secret path depends on that program, and widening it for a stage
# that does not share its threat model is how a decoder grows a hole.
# Shared with the Tailscale library in shape and not in code, because the
# two read different documents: this one walks the cluster listing for
# virtual machines rather than containers.
#
# The program is a constant. The document arrives on standard input and
# the parameters arrive in @ARGV, so nothing a node said is ever
# interpolated into code.
#
#   0  the answer was read, and is on standard output
#   1  the document was read and does not have it
#   2  anything else, including a document that will not decode, a field
#      of the wrong shape, a duplicated field, and a perl that is absent
read -r -d '' _HAOS_JSON_PROGRAM <<'PERL' || true
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

if ($mode eq 'tagged-vms') {
    my $tag = shift @ARGV;
    exit 2 unless defined $tag && length $tag;
    exit 2 unless ref $data eq 'ARRAY';
    my $found = 0;
    for my $item (@$data) {
        exit 2 unless ref $item eq 'HASH';
        # A listing entry with no type is a listing this code cannot
        # answer from, including about the machines it does describe.
        exit 2 unless exists $item->{type};
        next unless text($item->{type}) eq 'qemu';
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
_haos_json_cmd() {
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
      perl -e "${_HAOS_JSON_PROGRAM}" -- ${params[@]+"${params[@]}"} 2>/dev/null
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

# --- naming ---------------------------------------------------------------

# The machine name reaches `qm create -name`, which takes a DNS label and
# nothing else, and it becomes the name Home Assistant announces on the
# LAN.
haos_hostname_valid() {
  local name=$1
  [[ ${#name} -le 63 ]] || return 1
  [[ ${name} =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]
}

# --- the machine ----------------------------------------------------------

# Where qemu-server keeps a machine's configuration. pmxcfs presents it
# under /etc/pve on a real node; a test points PVE_CONFIG_ROOT elsewhere.
haos_vm_conf_path() {
  local vmid=$1
  printf '%s\n' "$(sysroot)/etc/pve/qemu-server/${vmid}.conf"
}

# Whether a path's absence is a thing this node can actually attest to.
#
# A file that is not there and a file this process cannot look for are the
# same `[[ -f ]]` and opposite answers: the first authorises a build, the
# second has to stop one. The nearest ancestor that exists has to be a
# directory this process can read and search before "it is not there" is
# an answer rather than a guess.
_haos_absence_confirmed() {
  local dir=${1%/*}
  while [[ -n ${dir} ]]; do
    if [[ -e ${dir} ]]; then
      [[ -d ${dir} && -r ${dir} && -x ${dir} ]] && return 0
      return 1
    fi
    dir=${dir%/*}
  done
  return 1
}

# A machine's configuration, as qemu-server stores it.
#
#   0  the body is in the named variable
#   1  this node does not have that machine
#   2  the answer could not be had
#
# The configuration file is the question qm itself answers from, and it
# gives a yes or a no without an exit status to interpret: `qm status`
# reports an absent machine and a qm that cannot reach the cluster
# filesystem with statuses that have been known to differ between
# releases.
#
# Three answers rather than two, and the third is never folded into either
# of the others. Every caller here decides something -- whether to build a
# machine, whether a machine is this toolkit's, which tags to write back
# -- and a read error presented as "no" turns each of those decisions into
# a mutation made on no evidence.
#
# The locals carry a prefix because the value is returned through a name
# the caller chose: a local of that same name would shadow the caller's
# variable and hand back an empty body with a status of 0.
haos_vm_conf_read() {
  local __cr_var=$1 __cr_vmid=$2 __cr_path __cr_body=''
  printf -v "${__cr_var}" '%s' ''

  __cr_path=$(haos_vm_conf_path "${__cr_vmid}")
  if [[ -L ${__cr_path} ]]; then
    # qemu-server stores no symlinks, so one here is something else's
    # doing and not a file to read a machine's identity out of.
    return 2
  fi
  if [[ -e ${__cr_path} ]]; then
    [[ -f ${__cr_path} && -r ${__cr_path} ]] || return 2
    __cr_body=$(cat -- "${__cr_path}" 2>/dev/null) || return 2
    printf -v "${__cr_var}" '%s' "${__cr_body}"
    return 0
  fi
  _haos_absence_confirmed "${__cr_path}" || return 2
  return 1
}

# Whether this node already has that machine.
#
#   0  it does
#   1  it does not
#   2  the answer could not be had
haos_vm_exists() {
  local vmid=$1 __body='' rc=0
  haos_vm_conf_read __body "${vmid}" || rc=$?
  return "${rc}"
}

# The tags a machine carries on this node, space separated.
#
#   0  the tags, which may be none, are in the named variable
#   1  this node does not have that machine
#   2  the answer could not be had
haos_vm_tags() {
  local __var=$1 __vmid=$2 __body='' line value='' rc=0
  printf -v "${__var}" '%s' ''

  haos_vm_conf_read __body "${__vmid}" || rc=$?
  ((rc == 0)) || return "${rc}"
  while IFS= read -r line; do
    # Everything from the first section header on is a snapshot or a
    # pending change, not what the machine is now. A tag this toolkit once
    # set and has since removed would otherwise authorise adopting a
    # machine that no longer carries it.
    [[ ${line} == '['*']' ]] && break
    case ${line} in
      tags:*)
        value=${line#tags:}
        value=${value//[;,]/ }
        ;;
    esac
  done <<<"${__body}"
  printf -v "${__var}" '%s' "${value}"
}

# One scalar out of a machine's configuration, read from the file rather
# than from `qm config` for the same reason the tags are.
#
#   0  the value is in the named variable
#   1  there is no such machine, or it does not carry that key
#   2  the answer could not be had
haos_vm_conf_value() {
  local __var=$1 __vmid=$2 key=$3 __body='' line value='' rc=0
  printf -v "${__var}" '%s' ''

  haos_vm_conf_read __body "${__vmid}" || rc=$?
  ((rc == 0)) || return "${rc}"
  while IFS= read -r line; do
    # Snapshots and pending changes are not what the machine is now.
    [[ ${line} == '['*']' ]] && break
    case ${line} in
      "${key}: "*) value=${line#"${key}: "} ;;
    esac
  done <<<"${__body}"
  [[ -n ${value} ]] || return 1
  printf -v "${__var}" '%s' "${value}"
  return 0
}

# Whether a machine on this node carries this toolkit's mark.
#
#   0  it does
#   1  it does not, or this node does not have it
#   2  the answer could not be had
haos_vm_is_owned() {
  local vmid=$1 tags='' tag rc=0
  haos_vm_tags tags "${vmid}" || rc=$?
  ((rc == 0)) || return "${rc}"
  for tag in ${tags}; do
    [[ ${tag} == "${HAOS_OWNER_TAG}" ]] && return 0
  done
  return 1
}

# Puts the mark on, keeping whatever tags are already there.
#
# The machine this stage builds is created carrying the mark, so on the
# build path there is nothing here to do. What this converges is a machine
# that is being adopted, and a machine whose tags somebody has edited
# since.
#
# The tags that are kept are read, never assumed. A read that failed, if
# it were taken for "no tags", would write a tag list holding this
# toolkit's mark and nothing else -- deleting whatever the machine
# actually carried, which on a Proxmox node can be what a backup job, a
# firewall rule or an SDN policy selects on.
haos_vm_tag_converge() {
  local vmid=$1 tags='' tag joined='' rc=0

  haos_vm_is_owned "${vmid}" || rc=$?
  case ${rc} in
    0)
      printf 'unchanged\n'
      return 0
      ;;
    1) ;;
    *)
      die "Unable to read the tags of virtual machine ${vmid} from $(haos_vm_conf_path "${vmid}"), so this node cannot tell which tags it carries. Refusing to write a tag list that would replace them."
      ;;
  esac

  if dry_run_enabled; then
    log_info "would tag virtual machine ${vmid} with ${HAOS_OWNER_TAG}"
    printf 'changed\n'
    return 0
  fi

  rc=0
  haos_vm_tags tags "${vmid}" || rc=$?
  ((rc == 0)) ||
    die "Unable to read the tags of virtual machine ${vmid}. Refusing to write a tag list that would replace them."
  for tag in ${tags}; do
    # A tag Proxmox will not take back is a `qm set` that fails and leaves
    # the machine unmarked, so only well formed ones are kept.
    [[ ${tag} =~ ^[A-Za-z0-9_.+-]+$ ]] || continue
    if [[ -n ${joined} ]]; then
      joined="${joined};${tag}"
    else
      joined=${tag}
    fi
  done
  if [[ -n ${joined} ]]; then
    joined="${joined};${HAOS_OWNER_TAG}"
  else
    joined=${HAOS_OWNER_TAG}
  fi

  run_cmd qm set "${vmid}" -tags "${joined}" ||
    die "Unable to tag virtual machine ${vmid} with ${HAOS_OWNER_TAG}."
  printf 'changed\n'
}

# Every virtual machine in the cluster carrying this toolkit's mark, one
# "vmid<tab>node" per line.
#
#   0  at least one, on standard output
#   1  the listing was read and holds none
#   2  the listing could not be read
#
# Cluster-wide on purpose. /etc/pve/qemu-server is this node's view, and
# an appliance built on another node of the same cluster is invisible
# there -- so a node-local check would build a second Home Assistant,
# which is two automation engines driving the same house.
haos_cluster_tagged() {
  local __var=$1 out='' rc=0
  printf -v "${__var}" '%s' ''

  out=$(_haos_json_cmd tagged-vms "${HAOS_OWNER_TAG}" -- \
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
# types, so a container numbered 200 on any node makes virtual machine 200
# impossible, and `qm create` on a taken id fails. The id is settled
# before anything is downloaded or created, so a clash costs a message
# rather than a half-built machine.
haos_cluster_ids() {
  local __var=$1 out='' rc=0
  printf -v "${__var}" '%s' ''

  out=$(_haos_json_cmd cluster-ids -- \
    pvesh get /cluster/resources --type vm --output-format json) || rc=$?
  if ((rc == 0)); then
    printf -v "${__var}" '%s' "${out}"
  fi
  return "${rc}"
}

# Where a guest id is in use in the cluster, as "type<tab>node", or
# nothing when it is free.
_haos_cluster_holder() {
  local __var=$1 guests=$2 want=$3 vmid type node
  printf -v "${__var}" '%s' ''
  while IFS=$'\t' read -r vmid type node; do
    [[ ${vmid} == "${want}" ]] || continue
    printf -v "${__var}" '%s' "${type}"$'\t'"${node}"
    return 0
  done <<<"${guests}"
  return 1
}

# The machine id to work on, and whether it is already there.
#
# Nothing existing is touched without proof that this toolkit built it.
# The mark is a Proxmox tag, so the proof survives a reboot, a restore and
# a release upgrade, and it is checked before the first mutation rather
# than after an appliance has been started.
#
# A pinned id wins, and must either be free or carry the mark.
# PVE_HAOS_ADOPT_EXISTING=yes is the deliberate exception: it marks the
# machine this run and says so, which makes a legitimate adoption possible
# and never silent.
haos_vmid_resolve() {
  local __var=$1 configured=${2:-} adopt=${3:-no}
  # Prefixed out of the way of the names a caller is likely to pass. A
  # `local vmid` here would shadow the caller's `vmid`, and printf -v
  # would then fill in the shadow and leave the caller with nothing.
  local __haos_found='' __haos_nextid='' __haos_vmid __haos_node __haos_here='' __haos_rc=0

  # A gate on a destructive action, so a value that is neither yes nor no
  # is an error rather than a quiet "no": an operator who wrote `true`
  # would otherwise get a refusal with nothing to connect it to.
  [[ -z ${adopt} ]] && adopt=no
  case ${adopt} in
    yes | no) ;;
    *) die "PVE_HAOS_ADOPT_EXISTING is '${adopt}', which is neither yes nor no. It decides whether this stage may take over a virtual machine it did not build, so it is not guessed at. Use exactly yes or no, in lower case." ;;
  esac

  # Adoption is aimed by hand or not at all. Without an id it would take
  # over whatever happened to be at the default id, which is the one
  # mistake this escape hatch exists to make impossible.
  if [[ ${adopt} == yes && -z ${configured} ]]; then
    die "PVE_HAOS_ADOPT_EXISTING is yes but PVE_HAOS_VMID is not set. Adoption takes over a machine this toolkit did not build, so it is never aimed by guesswork: name the virtual machine that is the Home Assistant appliance."
  fi

  __haos_here=$(detect_hostname_short 2>/dev/null) || __haos_here=''

  haos_cluster_tagged __haos_found || __haos_rc=$?
  if ((__haos_rc == 2)); then
    die "Unable to read 'pvesh get /cluster/resources --type vm' as JSON, so this node cannot tell whether a Home Assistant OS machine built by this toolkit already exists in this cluster. Building one anyway would put a second automation engine on the same house. Fix the cluster query, or set PVE_HAOS_VMID to the id this machine should have."
  fi

  local __haos_guests='' __haos_grc=0
  haos_cluster_ids __haos_guests || __haos_grc=$?
  if ((__haos_grc == 2)); then
    die "Unable to read 'pvesh get /cluster/resources --type vm' as JSON, so this node cannot tell which guest ids are already taken in this cluster. Fix the cluster query, or set PVE_HAOS_VMID to the id this machine should have."
  fi

  local -a __haos_mine=()
  if ((__haos_rc == 0)); then
    while IFS=$'\t' read -r __haos_vmid __haos_node; do
      [[ -n ${__haos_vmid} ]] || continue
      if [[ -n ${__haos_here} && -n ${__haos_node} && ${__haos_node} != "${__haos_here}" ]]; then
        die "A Home Assistant OS machine built by this toolkit already exists in this cluster as virtual machine ${__haos_vmid} on node ${__haos_node}. Two of them share no state and would fight over the same devices, so this is not a spare. Run this stage on ${__haos_node}, or remove that machine first."
      fi
      __haos_mine+=("${__haos_vmid}")
    done <<<"${__haos_found}"
  fi

  if ((${#__haos_mine[@]} > 1)); then
    die "More than one virtual machine on this node carries the ${HAOS_OWNER_TAG} tag (${__haos_mine[*]}). Remove the tag from the ones that are not the Home Assistant appliance, or set PVE_HAOS_VMID to the one that is."
  fi

  if [[ -n ${configured} ]]; then
    _haos_is_number "${configured}" ||
      die "PVE_HAOS_VMID is '${configured}', which is not a guest id."
    if ((configured < 100 || configured > 999999999)); then
      die "PVE_HAOS_VMID is '${configured}'; Proxmox guest ids run from 100 to 999999999."
    fi
    local __haos_holder='' __haos_erc=0
    haos_vm_exists "${configured}" || __haos_erc=$?
    ((__haos_erc == 2)) &&
      die "Unable to tell whether virtual machine ${configured} exists on this node: $(haos_vm_conf_path "${configured}") could not be read. Refusing to act on a machine whose existence is unknown."
    if ((__haos_erc == 1)) &&
      _haos_cluster_holder __haos_holder "${__haos_guests}" "${configured}"; then
      die "PVE_HAOS_VMID is ${configured}, which is already taken in this cluster by a ${__haos_holder%%$'\t'*} guest on node ${__haos_holder##*$'\t'}. Guest ids are unique cluster wide, so no machine can be built with that id. Pick a free one."
    fi
    if ((__haos_erc == 0)); then
      local __haos_orc=0
      haos_vm_is_owned "${configured}" || __haos_orc=$?
      ((__haos_orc == 2)) &&
        die "Unable to read the tags of virtual machine ${configured}, so this node cannot tell whether this toolkit built it. Refusing to tag and start a machine that may be somebody else's."
      if ((__haos_orc == 1)); then
        if [[ ${adopt} != yes ]]; then
          die "Virtual machine ${configured} already exists on this node and does not carry the ${HAOS_OWNER_TAG} tag, so this toolkit did not build it. Refusing to tag it and start it. Point PVE_HAOS_VMID at a free id, or set PVE_HAOS_ADOPT_EXISTING=yes if that machine really is the Home Assistant appliance."
        fi
        log_warn "adopting pre-existing virtual machine ${configured}, which this toolkit did not build, because PVE_HAOS_ADOPT_EXISTING is yes"
      fi
    fi
    if ((${#__haos_mine[@]} == 1)) && [[ ${__haos_mine[0]} != "${configured}" ]]; then
      die "PVE_HAOS_VMID is ${configured}, but virtual machine ${__haos_mine[0]} on this node already carries the ${HAOS_OWNER_TAG} tag. Remove that machine or its tag before moving the appliance to ${configured}."
    fi
    printf -v "${__var}" '%s' "${configured}"
    return 0
  fi

  if ((${#__haos_mine[@]} == 1)); then
    printf -v "${__var}" '%s' "${__haos_mine[0]}"
    return 0
  fi

  local __haos_holder='' __haos_erc=0
  haos_vm_exists "${HAOS_DEFAULT_VMID}" || __haos_erc=$?
  ((__haos_erc == 2)) &&
    die "Unable to tell whether virtual machine ${HAOS_DEFAULT_VMID} exists on this node: $(haos_vm_conf_path "${HAOS_DEFAULT_VMID}") could not be read. Refusing to pick an id past one this node cannot account for."
  if ((__haos_erc == 1)) &&
    ! _haos_cluster_holder __haos_holder "${__haos_guests}" "${HAOS_DEFAULT_VMID}"; then
    printf -v "${__var}" '%s' "${HAOS_DEFAULT_VMID}"
    return 0
  fi

  __haos_nextid=$(pvesh get /cluster/nextid 2>/dev/null) || __haos_nextid=''
  __haos_nextid=${__haos_nextid//[$'\t\r\n ']/}
  _haos_is_number "${__haos_nextid}" ||
    die "Guest id ${HAOS_DEFAULT_VMID} is taken and 'pvesh get /cluster/nextid' did not answer with an id. Set PVE_HAOS_VMID to the id this machine should have."
  __haos_erc=0
  haos_vm_exists "${__haos_nextid}" || __haos_erc=$?
  ((__haos_erc == 2)) &&
    die "Unable to tell whether virtual machine ${__haos_nextid} exists on this node. Refusing to build on an id this node cannot account for."
  if ((__haos_erc == 0)) ||
    _haos_cluster_holder __haos_holder "${__haos_guests}" "${__haos_nextid}"; then
    die "'pvesh get /cluster/nextid' answered with ${__haos_nextid}, which is already taken in this cluster. Set PVE_HAOS_VMID to the id this machine should have."
  fi
  printf -v "${__var}" '%s' "${__haos_nextid}"
}

# Memory and cores for the appliance, scaled to the node.
#
# Home Assistant is not a subnet router. It runs a Python application
# server, a database, a supervisor and however many add-on containers the
# household ends up with, and the project's own documentation treats 2 GB
# as the minimum for an installation that will do anything. Upstream's own
# defaults -- 4096 MB and two cores -- are what a
# reviewed HAOS installation gets, and they are the middle of this band
# rather than its top.
#
# An eighth of the node's memory, held between 2 GB and 8 GB, and a
# quarter of its cores, held between two and four. The share is larger
# than the router's sixty-fourth because the appliance is the reason the
# node exists in these deployments; the ceiling is there because the
# second guest on the node still has to fit, and because a Home Assistant
# that is given 32 GB does not use 32 GB -- it leaves it unavailable.
haos_resources() {
  local __ram=$1 __cores=$2
  # Named out of the way of the variables a caller is likely to pass:
  # `local ram` here would shadow the caller's `ram` and printf -v would
  # fill in the shadow.
  local __haos_host_ram='' __haos_host_cores='' __haos_ram=4096 __haos_cores=2

  __haos_host_ram=$(detect_ram_mb 2>/dev/null) || __haos_host_ram=''
  __haos_host_cores=$(detect_cpu_cores 2>/dev/null) || __haos_host_cores=''

  # Checked before the arithmetic, never after. Bash evaluates an array
  # subscript inside an arithmetic context, so a value from outside this
  # script reaching $(( )) unvalidated is code execution as root.
  if _haos_is_number "${__haos_host_ram}"; then
    __haos_ram=$((__haos_host_ram / 8))
    ((__haos_ram >= 2048)) || __haos_ram=2048
    ((__haos_ram <= 8192)) || __haos_ram=8192
  fi
  if _haos_is_number "${__haos_host_cores}"; then
    __haos_cores=$((__haos_host_cores / 4))
    ((__haos_cores >= 2)) || __haos_cores=2
    ((__haos_cores <= 4)) || __haos_cores=4
  fi

  printf -v "${__ram}" '%s' "${__haos_ram}"
  printf -v "${__cores}" '%s' "${__haos_cores}"
}

# The storages on this node that accept a given content type.
haos_storage_names() {
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

# The storage the appliance's disks go on.
#
# One storage, not two: a virtual machine has no template to download, so
# the split the container path needs -- vztmpl on one storage, rootdir on
# another -- does not arise. `images` is the content type, and the EFI
# disk and the root disk both land on it.
#
# A configured name is verified before anything is created rather than
# discovered when `qm create` refuses it. A node with exactly one storage
# of the right kind has no question to ask, and a node with several is
# told what to set rather than guessed at.
haos_storage_resolve() {
  local __var=$1 configured=${2:-} setting=${3:-PVE_HAOS_STORAGE}
  local available='' name count=0

  haos_storage_names available images

  if [[ -n ${configured} ]]; then
    for name in ${available}; do
      if [[ ${name} == "${configured}" ]]; then
        printf -v "${__var}" '%s' "${configured}"
        return 0
      fi
    done
    die "${setting} names '${configured}', which is not a storage on this node that accepts 'images' content. The storages that do are: ${available:-none}."
  fi

  for name in ${available}; do
    count=$((count + 1))
  done

  if ((count == 1)); then
    printf -v "${__var}" '%s' "${available}"
    return 0
  fi

  if ((count == 0)); then
    die "No storage on this node accepts 'images' content, so there is nowhere to put the Home Assistant OS disk. Add one, or name it with ${setting}."
  fi
  die "This node has more than one storage accepting 'images' content (${available}). Set ${setting} to the one the Home Assistant OS machine belongs on; an unattended run has nobody to ask."
}

# --- the disk image -------------------------------------------------------

# The release to install, and the digest it must have.
#
# Both are read here rather than at each point of use so that a malformed
# override is refused once, before anything is downloaded.
haos_image_version() {
  local __var=$1 value=${PVE_HAOS_VERSION:-${HAOS_IMAGE_VERSION}}
  # The value becomes part of a URL and part of a filename, so it is held
  # to the shape Home Assistant publishes: 18.4, 18.4.1, 19.0.rc1.
  [[ ${value} =~ ^[0-9]+(\.[0-9a-zA-Z]+)*$ ]] ||
    die "PVE_HAOS_VERSION is '${PVE_HAOS_VERSION:-}', which is not a Home Assistant OS release such as 18.4."
  printf -v "${__var}" '%s' "${value}"
}

haos_image_digest_expected() {
  local __var=$1 value=${PVE_HAOS_IMAGE_SHA256:-${HAOS_IMAGE_SHA256}}
  value=${value,,}
  [[ ${value} =~ ^[0-9a-f]{64}$ ]] ||
    die "PVE_HAOS_IMAGE_SHA256 is '${PVE_HAOS_IMAGE_SHA256:-}', which is not a SHA-256 digest: 64 hexadecimal digits."
  printf -v "${__var}" '%s' "${value}"
}

# The release and the digest describe one image, so an override of either
# without the other describes nothing.
#
# A release set alone would be fetched and then checked against the digest
# of a different one, which fails -- but only after the download, and with
# an error about a digest rather than about the pair. A digest set alone
# describes an image this stage is not fetching. Both stop the stage here,
# naming both keys.
haos_image_pin_consistent() {
  if [[ -n ${PVE_HAOS_VERSION:-} && -z ${PVE_HAOS_IMAGE_SHA256:-} ]]; then
    die "PVE_HAOS_VERSION is '${PVE_HAOS_VERSION}' and PVE_HAOS_IMAGE_SHA256 is unset. The digest pinned in this toolkit belongs to ${HAOS_IMAGE_VERSION}, so set both keys together, taking the digest from the ${PVE_HAOS_VERSION} release's own SHA256SUMS asset."
  fi
  if [[ -z ${PVE_HAOS_VERSION:-} && -n ${PVE_HAOS_IMAGE_SHA256:-} ]]; then
    die "PVE_HAOS_IMAGE_SHA256 is set and PVE_HAOS_VERSION is unset, so that digest describes an image this stage is not fetching: it would fetch ${HAOS_IMAGE_VERSION}. Set both keys together."
  fi
}

haos_image_name() {
  local version=$1
  printf '%s\n' "haos_ova-${version}.qcow2.xz"
}

haos_image_url() {
  local version=$1
  printf '%s\n' "${HAOS_RELEASE_BASE}/${version}/$(haos_image_name "${version}")"
}

# Where a verified image is kept, and what it is called there. The name
# is the one the release publishes, so the file an operator finds is the
# file the digest in this library describes.
haos_image_cache_dir() {
  printf '%s\n' "$(sysroot)${HAOS_IMAGE_CACHE_DIR}"
}

haos_image_cache_path() {
  local version=$1
  printf '%s\n' "$(haos_image_cache_dir)/$(haos_image_name "${version}")"
}

# The SHA-256 of a file, or a failure that is not an answer.
haos_file_digest() {
  local __var=$1 path=$2 out=''
  printf -v "${__var}" '%s' ''
  out=$(sha256sum -- "${path}" 2>/dev/null) || return 1
  out=${out%% *}
  [[ ${out} =~ ^[0-9a-f]{64}$ ]] || return 1
  printf -v "${__var}" '%s' "${out}"
  return 0
}

# The descriptor the verified image is held open on, for as long as the
# stage needs it.
#
# Hashing a path and opening that path again later are two different
# objects whenever anything can write to the directory in between: the
# bytes that were checked and the bytes that reach `xz` would not have to
# be the same ones. An open descriptor is the file itself, so everything
# downstream reads through /dev/fd and never resolves the name again.
HAOS_IMAGE_FD=''

# What the last check actually read, for the message when it was not the
# pin.
HAOS_IMAGE_DIGEST_SEEN=''

# Opens a file and checks it through that descriptor, keeping it open.
#
#   0  the pin matched and HAOS_IMAGE_FD is the open image
#   1  the file could not be opened, could not be hashed, or is not the
#      pinned image
#
# /dev/fd/N reopens the object the descriptor already refers to, so the
# digest and the unpack see one inode whatever happens to the name.
_haos_image_open_verified() {
  local file=$1 expected=$2 fd='' actual=''

  # No redirection of this command's own errors: `exec {fd}<file 2>...`
  # applies the second redirection to the shell rather than to a child,
  # and the stage would lose its error output for the rest of the run.
  exec {fd}<"${file}" || return 1
  if ! haos_file_digest actual "/dev/fd/${fd}"; then
    exec {fd}<&-
    return 1
  fi
  if [[ ${actual} != "${expected}" ]]; then
    HAOS_IMAGE_DIGEST_SEEN=${actual}
    exec {fd}<&-
    return 1
  fi
  HAOS_IMAGE_FD=${fd}
  return 0
}

# Lets go of the verified image. Called when the stage is done with it.
haos_image_close() {
  local fd=${HAOS_IMAGE_FD}
  [[ -n ${fd} ]] || return 0
  HAOS_IMAGE_FD=''
  exec {fd}<&- || true
}

# Opens the pinned image, verified, and keeps it open.
#
# A cached file is checked again on every run rather than trusted for
# existing, and one that does not match is replaced -- the same decision
# the Tailscale keyring made. A download lands in a directory of this
# stage's own, created 0700, and moves into the cache only once it
# matches, so an interrupted fetch leaves nothing a later run would read
# as the image.
#
# What the rest of the stage uses is HAOS_IMAGE_FD, not the cache path.
# The file is opened before it is hashed and stays open, so replacing the
# cache entry afterwards replaces a name this stage has stopped looking
# at.
haos_image_fetch() {
  local version=$1 expected=$2
  local url path dir build='' tmp=''

  HAOS_IMAGE_DIGEST_SEEN=''
  url=$(haos_image_url "${version}")
  path=$(haos_image_cache_path "${version}")

  if [[ -L ${path} ]]; then
    die "Refusing to verify through the symlink ${path}; the image that was checked and the image that boots would not have to be the same file."
  fi
  if [[ -e ${path} ]]; then
    if [[ ! -f ${path} ]]; then
      die "${path} is not a regular file, so it is not an image this stage can check."
    fi
    if _haos_image_open_verified "${path}" "${expected}"; then
      printf 'unchanged\n'
      return 0
    fi
    log_warn "The cached ${path} is ${HAOS_IMAGE_DIGEST_SEEN:-unreadable}, not the pinned ${expected}. Replacing it."
  fi

  if dry_run_enabled; then
    log_info "would fetch ${url} and check it against ${expected}"
    printf 'changed\n'
    return 0
  fi

  dir=$(haos_image_cache_dir)
  ensure_dir "${dir}" 0755 >/dev/null

  # A directory of this stage's own, beside the cache so the move into it
  # is a rename rather than a copy, and 0700 so the download is not
  # something another process on the node can reach.
  build=$(mktemp -d "${dir}/.pve-config-haos.XXXXXX") ||
    die "Unable to create a private directory beside ${path} for the Home Assistant OS image."
  chmod 0700 -- "${build}" ||
    die "Unable to make ${build} private, so the image would be downloaded somewhere this stage does not control."
  tmp="${build}/image.xz"

  _haos_clean_env
  log_info "fetching the Home Assistant OS ${version} image from ${url}"
  if ! "${_HAOS_ENV_CMD[@]}" curl -fsSL "${url}" -o "${tmp}"; then
    rm -rf -- "${build}"
    die "Unable to fetch the Home Assistant OS image from ${url}."
  fi
  if ! _haos_image_open_verified "${tmp}" "${expected}"; then
    rm -rf -- "${build}"
    die "The image at ${url} is ${HAOS_IMAGE_DIGEST_SEEN:-unreadable}, not the pinned ${expected}. Refusing to install it. Check PVE_HAOS_VERSION and PVE_HAOS_IMAGE_SHA256 against the release's own SHA256SUMS."
  fi

  # The descriptor is already open on this file, so the move is about
  # leaving something for the next run rather than about what this one
  # reads. A move that fails costs a download next time and nothing else.
  if ! mv -- "${tmp}" "${path}"; then
    log_warn "Unable to keep the verified image at ${path}; this run has it open and will carry on, and the next run will fetch it again."
  fi
  rm -rf -- "${build}"
  log_info "the Home Assistant OS ${version} image is open and verified against ${expected}"
  printf 'changed\n'
}

# Unpacks the image this stage has open, and names what it unpacked.
#
# vm_extract_image in pve/vm-core.func, less the progress bar and the
# formats Home Assistant does not publish in, and reading the open
# descriptor rather than the cache path: the bytes that were hashed are
# the bytes that are unpacked, with no second lookup of a name in
# between. The unpacked file goes in a directory of this toolkit's own
# that the caller removes.
#
# xz is given the same scrubbed environment the download was: it is the
# second thing in this stage to parse bytes from the internet.
haos_image_extract() {
  local __var=$1 target=$2

  printf -v "${__var}" '%s' ''
  [[ -n ${HAOS_IMAGE_FD} ]] ||
    die "No verified Home Assistant OS image is open, so there is nothing this stage is willing to unpack."

  _haos_clean_env
  if ! "${_HAOS_ENV_CMD[@]}" xz -dc -- "/dev/fd/${HAOS_IMAGE_FD}" >"${target}"; then
    rm -f -- "${target}"
    die "Unable to unpack the verified Home Assistant OS image. The machine was not given a disk."
  fi
  [[ -s ${target} ]] ||
    die "Unpacking the verified Home Assistant OS image produced nothing. The machine was not given a disk."
  printf -v "${__var}" '%s' "${target}"
}

# --- building -------------------------------------------------------------

# Creates the machine, carrying this toolkit's mark from the first moment
# it exists.
#
# A port of the `qm create` in the pinned vm/haos-vm.sh:
#
#   qm create $VMID${MACHINE} -bios ovmf -agent 1 -tablet 0 -localtime 1 \
#     ${CPU_TYPE} -cores "$CORE_COUNT" -memory "$RAM_SIZE" -name "$HN" \
#     -tags community-script \
#     -net0 "virtio,bridge=$BRG,macaddr=$MAC$VLAN$MTU" -onboot 1 \
#     -ostype l26 -scsihw virtio-scsi-pci
#
# with MACHINE from vm_apply_machine_type q35, which is what the script's
# own default_settings asks for. Every option it sets is set here:
#
#   -machine q35           the chipset the appliance is tested on
#   -bios ovmf             HAOS boots UEFI; SeaBIOS does not boot it
#   -agent 1               the qemu guest agent HAOS ships
#   -tablet 0              a pointer an appliance with no desktop has no
#                          use for, and which costs a timer interrupt
#   -localtime 1           upstream's choice; HAOS sets its own clock
#   -ostype l26            Linux 2.6 or later
#   -scsihw virtio-scsi-pci  the controller the root disk is attached to
#   -onboot 1              the house's automation comes back after a
#                          power cut without anybody logging in
#
# Two deliberate differences from upstream, both noted in the report:
#
#   * The tag is this toolkit's, not community-script. The machine is not
#     built by a community script and the mark has to mean "this stage
#     owns this machine" and nothing else. It goes in this invocation
#     rather than a `qm set` afterwards, so there is no window in which
#     the machine exists unmarked: an interrupted run would otherwise
#     leave a machine the next run reads as somebody else's, and the run
#     after that would build a second Home Assistant.
#   * No macaddr. Upstream generates one from openssl; Proxmox generates
#     one just as well when the option is left out, and it is as stable
#     afterwards. CPU_TYPE is unset for the reason upstream leaves it
#     unset by default: the only value it takes is `host`, which ties the
#     machine to this node's processor model and so to this node.
haos_vm_create() {
  local vmid=$1 hostname=$2 ram=$3 cores=$4 bridge=$5

  if dry_run_enabled; then
    log_info "would create virtual machine ${vmid} (${hostname}) tagged ${HAOS_OWNER_TAG}"
    printf 'changed\n'
    return 0
  fi

  run_cmd qm create "${vmid}" \
    -machine q35 \
    -bios ovmf \
    -agent 1 \
    -tablet 0 \
    -localtime 1 \
    -cores "${cores}" \
    -memory "${ram}" \
    -name "${hostname}" \
    -tags "${HAOS_OWNER_TAG}" \
    -net0 "virtio,bridge=${bridge}" \
    -onboot 1 \
    -ostype l26 \
    -scsihw virtio-scsi-pci ||
    die "Unable to create virtual machine ${vmid}."

  local rc=0
  haos_vm_exists "${vmid}" || rc=$?
  ((rc == 0)) ||
    die "qm create reported success but there is no configuration for virtual machine ${vmid}."
  printf 'changed\n'
}

# Every volume sitting in a machine's configuration as an unused disk,
# one per line, in configuration order.
#
#   0  at least one, in the named variable
#   1  the configuration was read and holds none
#   2  the answer could not be had
haos_vm_unused_volumes() {
  local __var=$1 __uv_vmid=$2 __uv_body='' line value joined='' rc=0
  printf -v "${__var}" '%s' ''

  haos_vm_conf_read __uv_body "${__uv_vmid}" || rc=$?
  ((rc == 0)) || return "${rc}"
  while IFS= read -r line; do
    # Snapshots and pending changes are not what the machine is now.
    [[ ${line} == '['*']' ]] && break
    case ${line} in
      unused[0-9]*:*)
        value=${line#*: }
        value=${value//[$'\r\"\'']/}
        [[ -n ${value} ]] || continue
        if [[ -n ${joined} ]]; then
          joined="${joined}"$'\n'"${value}"
        else
          joined=${value}
        fi
        ;;
    esac
  done <<<"${__uv_body}"
  [[ -n ${joined} ]] || return 1
  printf -v "${__var}" '%s' "${joined}"
  return 0
}

# The volume qm says it just imported.
#
#   0  the volume is in the named variable
#   1  qm's report did not name one
#
# qm's own words are the first source, as in vm_import_disk in
# pve/vm-core.func. Production prints
#
#   Successfully imported disk as 'unused0:local-lvm:vm-200-disk-0'
#
# so the report carries the configuration key as well as the volume, and
# the key has to come off. The index runs past nine on a machine that has
# collected disks, which is why this takes digits rather than a digit.
_haos_report_volume() {
  local __var=$1 report=$2 __rv_volume=''
  printf -v "${__var}" '%s' ''

  __rv_volume=$(printf '%s\n' "${report}" |
    sed -n "s/.*[Ss]uccessfully imported disk\( as\)\? '\([^']*\)'.*/\2/p" |
    tail -n 1)
  if [[ ${__rv_volume} =~ ^unused[0-9]+:(.+)$ ]]; then
    __rv_volume=${BASH_REMATCH[1]}
  fi
  __rv_volume=${__rv_volume//[$'\r\"\'']/}
  [[ -n ${__rv_volume} ]] || return 1
  printf -v "${__var}" '%s' "${__rv_volume}"
  return 0
}

# The one volume in `after` that is not in `before`.
#
#   0  exactly one appeared, in the named variable
#   1  none appeared, or more than one did
#
# vm_import_disk reads the unused entries before the import and subtracts
# them from the ones after it. The subtraction is the point: a machine
# being recovered can be carrying unused disks that have nothing to do
# with this image, and the newest-looking name is not an answer --
# vm-200-disk-10 sorts before vm-200-disk-9.
_haos_new_volume() {
  local __var=$1 before=$2 after=$3 line found='' count=0
  printf -v "${__var}" '%s' ''

  while IFS= read -r line; do
    [[ -n ${line} ]] || continue
    grep -qxF -- "${line}" <<<"${before}" && continue
    found=${line}
    count=$((count + 1))
  done <<<"${after}"
  ((count == 1)) || return 1
  printf -v "${__var}" '%s' "${found}"
  return 0
}

# Attaches the root disk, importing the image when there is nothing to
# attach.
#
# The first of the three steps that give a machine its disk, each guarded
# on its own reading of the machine rather than on the one before it
# having happened. A run interrupted between any two of them is finished
# by the next one, and a machine whose disk is attached but never resized
# is not a converged machine.
#
# An import that happened but was never attached leaves an unused entry,
# which is attached rather than imported again: importing twice would
# leave a second copy of a 32 GiB disk on the storage every time. More
# than one unused entry stops the stage. Which of them is the Home
# Assistant image is not something this node can tell, and attaching the
# wrong one boots the appliance off somebody else's disk.
haos_vm_disk_attach_converge() {
  local vmid=$1 storage=$2
  # shellcheck disable=SC2034  # filled in by name, below
  local attached='' rc=0 report='' volume='' unpacked='' work=''
  local before='' after=''

  haos_vm_conf_value attached "${vmid}" scsi0 || rc=$?
  ((rc == 2)) &&
    die "Unable to read the configuration of virtual machine ${vmid}, so this node cannot tell whether it already has a disk. Refusing to import another."
  if ((rc == 0)); then
    printf 'unchanged\n'
    return 0
  fi

  if dry_run_enabled; then
    log_info "would import the Home Assistant OS image into ${storage} and attach it to virtual machine ${vmid}"
    printf 'changed\n'
    return 0
  fi

  rc=0
  haos_vm_unused_volumes before "${vmid}" || rc=$?
  ((rc == 2)) &&
    die "Unable to read the configuration of virtual machine ${vmid}."

  if ((rc == 0)); then
    # Recovery. One unused volume is the import an interrupted run left
    # behind; several are a question this node cannot answer.
    if [[ ${before} == *$'\n'* ]]; then
      die "Virtual machine ${vmid} has no root disk and carries more than one unused volume (${before//$'\n'/, }). This stage cannot tell which of them is the Home Assistant OS image it imported. Attach the right one with 'qm set ${vmid} --scsi0 <volume>,ssd=1,discard=on' or remove the ones that do not belong, then run again."
    fi
    volume=${before}
    log_info "attaching the disk an earlier run imported (${volume})"
  else
    work=$(mktemp -d "$(haos_image_cache_dir)/pve-config-haos.XXXXXX") ||
      die "Unable to create a working directory for unpacking the Home Assistant OS image."
    haos_image_extract unpacked "${work}/haos.qcow2"

    # --format raw as upstream: the target format, not the source's,
    # which qemu-img reads from the file itself.
    report=$(qm disk import "${vmid}" "${unpacked}" "${storage}" --format raw 2>&1) || {
      log_warn "${report}"
      rm -rf -- "${work}"
      die "Unable to import the Home Assistant OS disk into ${storage} for virtual machine ${vmid}."
    }
    log_info "imported the Home Assistant OS disk into ${storage}"
    rm -rf -- "${work}"

    if ! _haos_report_volume volume "${report}"; then
      rc=0
      haos_vm_unused_volumes after "${vmid}" || rc=$?
      ((rc == 2)) &&
        die "Unable to read the configuration of virtual machine ${vmid} after importing its disk."
      _haos_new_volume volume "${before}" "${after}" ||
        die "The Home Assistant OS disk was imported into ${storage}, but this node cannot tell which volume it created and the configuration of virtual machine ${vmid} does not show exactly one new unused disk. Refusing to guess which volume to boot from."
    fi
  fi

  run_cmd qm set "${vmid}" --scsi0 "${volume},ssd=1,discard=on" ||
    die "Unable to attach ${volume} to virtual machine ${vmid} as its root disk."
  printf 'changed\n'
}

# Sets a configuration key the machine does not have, and says whether it
# did anything.
#
#   0  the key was missing and has been set
#   1  the key is already there
#
# A key this node cannot read is neither of those, and stops the stage:
# writing one over a value it could not see is the mutation on no
# evidence this project keeps finding.
_haos_key_set_when_missing() {
  local vmid=$1 key=$2
  shift 2
  local current='' rc=0
  haos_vm_conf_value current "${vmid}" "${key}" || rc=$?
  ((rc == 2)) &&
    die "Unable to read the configuration of virtual machine ${vmid}, so this node cannot tell whether ${key} is set. Refusing to write over a setting it cannot see."
  ((rc == 0)) && return 1
  run_cmd qm set "${vmid}" "$@" ||
    die "Unable to set ${key} on virtual machine ${vmid}."
  return 0
}

# Sets a configuration key that is missing or is not what it has to be.
#
#   0  the key has been written
#   1  the key already says what it has to
#
# The wanted value is a pattern rather than a string because qemu-server
# writes back more than one spelling of the same setting: `-agent 1` is
# stored as `agent: 1` and `--agent enabled=1` as `agent: enabled=1`, and
# both mean the agent is on. Comparing against one of them would have
# this rewriting a correct setting on every run.
_haos_key_set_when_wrong() {
  local vmid=$1 key=$2 want=$3
  shift 3
  local current='' rc=0
  haos_vm_conf_value current "${vmid}" "${key}" || rc=$?
  ((rc == 2)) &&
    die "Unable to read the configuration of virtual machine ${vmid}, so this node cannot tell what ${key} is. Refusing to write over a setting it cannot see."
  ((rc == 0)) && [[ ${current} =~ ${want} ]] && return 1
  run_cmd qm set "${vmid}" "$@" ||
    die "Unable to set ${key} on virtual machine ${vmid}."
  return 0
}

# Gives the machine the firmware and console wiring the appliance boots
# with, each key on its own reading of the configuration.
#
# A port of:
#
#   qm set $VMID --efidisk0 ${STORAGE}:0,efitype=4m \
#     --scsi0 ${DISK_REF},${DISK_CACHE}ssd=1,discard=on \
#     --boot order=scsi0 --serial0 socket
#   qm set $VMID --agent enabled=1
#
# with DISK_CACHE empty, which is what default_settings leaves it as.
# efitype=4m is upstream's literal, and an OVMF machine with no EFI disk
# has nowhere to keep its boot entries. serial0 is what the Proxmox
# console attaches to on an appliance with no VGA login.
#
# Upstream writes all of it in one `qm set` and never looks again. Each
# key is converged separately here because a run that died between the
# attach and this is a machine with a disk and no way to boot it, and the
# next run has to be able to finish the job rather than read the disk as
# proof that the rest happened.
haos_vm_firmware_converge() {
  local vmid=$1 setting=$2
  local value='' storage='' rc=0 changed=0 efi=0

  haos_vm_conf_value value "${vmid}" efidisk0 || rc=$?
  ((rc == 2)) &&
    die "Unable to read the configuration of virtual machine ${vmid}, so this node cannot tell whether it has an EFI disk."
  ((rc == 0)) || efi=1

  if dry_run_enabled; then
    if ((efi)); then
      log_info "would give virtual machine ${vmid} an EFI disk and the appliance's boot wiring"
      printf 'changed\n'
      return 0
    fi
    printf 'unchanged\n'
    return 0
  fi

  # The storage is read only when there is an EFI disk to put on it. A
  # machine that already has one is converged on a node with several
  # image storages and no PVE_HAOS_STORAGE, which it could not be if
  # every run had to settle a question nothing was going to ask.
  if ((efi)); then
    haos_storage_resolve storage "${setting}"
  fi

  # The EFI disk is an allocation rather than a value to compare: asking
  # for it twice would leave a second one on the storage, so this one is
  # converged on the key being there at all.
  _haos_key_set_when_missing "${vmid}" efidisk0 \
    --efidisk0 "${storage}:0,efitype=4m" && changed=1
  _haos_key_set_when_wrong "${vmid}" boot '^order=scsi0$' \
    --boot order=scsi0 && changed=1
  _haos_key_set_when_wrong "${vmid}" serial0 '^socket$' \
    --serial0 socket && changed=1
  _haos_key_set_when_wrong "${vmid}" agent '^(enabled=)?1(,|$)' \
    --agent enabled=1 && changed=1

  if ((changed)); then
    printf 'changed\n'
  else
    printf 'unchanged\n'
  fi
}

# The size of a machine's root disk in whole gigabytes.
#
#   0  the size is in the named variable
#   1  the machine has no root disk
#   2  the size could not be had
#
# qemu-server records the size it allocated in the disk's own
# configuration line, as `size=32G`. Reading it is the only way to decide
# whether a resize has anything to do: `qm resize` to a size the disk
# already has fails, and treating that failure as success is how a disk
# that was never grown passes for a converged one.
haos_vm_disk_size_gb() {
  local __var=$1 __ds_vmid=$2 __ds_value='' __ds_size='' rc=0
  printf -v "${__var}" '%s' ''

  haos_vm_conf_value __ds_value "${__ds_vmid}" scsi0 || rc=$?
  ((rc == 0)) || return "${rc}"
  [[ ${__ds_value} =~ (^|,)size=([0-9]+)G(,|$) ]] || return 2
  __ds_size=${BASH_REMATCH[2]}
  _haos_is_number "${__ds_size}" || return 2
  printf -v "${__var}" '%s' "${__ds_size}"
  return 0
}

# Grows the root disk to the configured size, and is safe to run again.
#
# Upstream's vm_resize_disk warns and carries on, because it cannot tell a
# disk that is already large enough from a failure. This one reads the
# size first, so it asks only when there is something to do -- and a
# resize it asked for and did not get is an error rather than a line in
# the log.
haos_vm_disk_size_converge() {
  local vmid=$1 disk_gb=$2
  local have='' rc=0

  haos_vm_disk_size_gb have "${vmid}" || rc=$?
  case ${rc} in
    0) ;;
    1)
      if dry_run_enabled; then
        log_info "would grow the root disk of virtual machine ${vmid} to ${disk_gb}G"
        printf 'changed\n'
        return 0
      fi
      die "Virtual machine ${vmid} has no root disk to grow."
      ;;
    *)
      die "Unable to read the size of the root disk of virtual machine ${vmid} from its configuration. Refusing to resize a disk whose size this node cannot see."
      ;;
  esac

  ((have < disk_gb)) || {
    printf 'unchanged\n'
    return 0
  }

  if dry_run_enabled; then
    log_info "would grow the root disk of virtual machine ${vmid} from ${have}G to ${disk_gb}G"
    printf 'changed\n'
    return 0
  fi

  run_cmd qm resize "${vmid}" scsi0 "${disk_gb}G" ||
    die "Unable to grow the root disk of virtual machine ${vmid} to ${disk_gb}G."
  printf 'changed\n'
}

# --- running --------------------------------------------------------------

# What qm says the machine is doing.
#
#   0  the state is in the named variable
#   1  qm could not be asked, or said something this cannot read
haos_vm_status() {
  local __var=$1 vmid=$2 out='' line value=''
  printf -v "${__var}" '%s' ''

  out=$(qm status "${vmid}" 2>/dev/null) || return 1
  while IFS= read -r line; do
    case ${line} in
      'status: '*)
        value=${line#status: }
        break
        ;;
    esac
  done <<<"${out}"
  [[ ${value} =~ ^[a-z]+$ ]] || return 1
  printf -v "${__var}" '%s' "${value}"
  return 0
}

haos_vm_wait_running() {
  local vmid=$1 attempts=${2:-30} status=''
  local i
  for ((i = 0; i < attempts; i++)); do
    if haos_vm_status status "${vmid}" && [[ ${status} == running ]]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# Starts the appliance when it is not running, and stops when it cannot
# tell.
#
# An unreadable status is not a stopped machine. `qm start` against one
# that is already running fails, and against one that is paused or
# migrating it is the wrong verb entirely -- so a probe that could not be
# decoded ends the run rather than authorising a mutation. This is the
# invariant the rest of the toolkit is built on, applied to the one
# command here that would otherwise be issued on a guess.
haos_vm_start() {
  local vmid=$1 status='' rc=0 erc=0

  haos_vm_exists "${vmid}" || erc=$?
  ((erc == 2)) &&
    die "Unable to tell whether virtual machine ${vmid} exists on this node. Refusing to start a machine this node cannot account for."
  if dry_run_enabled && ((erc == 1)); then
    log_info "would start virtual machine ${vmid}"
    printf 'changed\n'
    return 0
  fi

  haos_vm_status status "${vmid}" || rc=$?
  if ((rc != 0)); then
    die "Unable to read 'qm status ${vmid}', so this node cannot tell whether the Home Assistant OS machine is running. Refusing to start a machine whose state is unknown."
  fi

  case ${status} in
    running) ;;
    stopped)
      if dry_run_enabled; then
        log_info "would start virtual machine ${vmid}"
        printf 'changed\n'
        return 0
      fi
      run_cmd qm start "${vmid}" ||
        die "Unable to start virtual machine ${vmid}."
      haos_vm_wait_running "${vmid}" ||
        die "Virtual machine ${vmid} was started but never reached the running state."
      printf 'changed\n'
      return 0
      ;;
    *)
      die "Virtual machine ${vmid} is '${status}', which is neither running nor stopped. Refusing to act on a machine in a state this stage has no verb for; sort it out with qm and run again."
      ;;
  esac
  printf 'unchanged\n'
}
