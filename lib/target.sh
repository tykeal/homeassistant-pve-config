#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
# SPDX-License-Identifier: Apache-2.0

# Execution targets.
#
# Every primitive in this toolkit converges something: an account, a file, a
# package, a unit. Phase 1 converged them on the host, through $(sysroot).
# Phase 2 has to converge the same things inside an LXC, where the only way
# in is `pct exec` and `pct push`. Writing a second set of primitives for
# that is how the guest path would reacquire the bugs phase 1 removed, so
# the difference is pushed down here instead: a target is a value, the
# caller passes it, and the primitive decides how to reach it.
#
# A target is `host` or `guest:<vmid>`. It is a parameter rather than a mode
# flag because a stage has to work on both at once -- mirroring the host's
# administrators into a container means reading one and writing the other in
# the same breath.
#
# The host branch of every function calls the phase 1 primitive unchanged.
# That is deliberate: the host path is the one an operator's running machine
# depends on, and it keeps its atomic installs, its validators and its
# backups rather than being re-expressed in terms of something more general.
# Where the two branches share a decision -- is this line already present,
# does this account exist -- they share the code that makes it, so the guest
# cannot drift away from the host's answer.
#
# Paths are given as the target sees them: `/etc/hosts` means the host's
# file under $(sysroot) for a host target and the container's own file for a
# guest. See target_path.

# --- target values --------------------------------------------------------

target_host() {
  printf 'host\n'
}

# A container id is interpolated into a pct command line, so it is proven to
# be a number here rather than wherever it is eventually used.
target_guest() {
  local vmid=$1
  [[ ${vmid} =~ ^[0-9]+$ ]] || die "Not a container id: ${vmid}"
  printf 'guest:%s\n' "${vmid}"
}

target_is_host() {
  [[ $1 == host ]]
}

# Strict rather than a glob: a hand-built `guest:101junk` is a mistake
# worth hearing about here, not three calls later as a puzzling pct error.
target_is_guest() {
  [[ $1 =~ ^guest:[0-9]+$ ]]
}

target_vmid() {
  target_is_guest "$1" || return 1
  printf '%s\n' "${1#guest:}"
}

# Names the target in a log line or a failure. Also the guard every entry
# point runs: a caller that passed a path where a target belongs is told so
# here, rather than having the value treated as a host.
target_describe() {
  case $1 in
    host) printf 'the host\n' ;;
    guest:*)
      target_is_guest "$1" || die "Not an execution target: '$1'"
      printf 'CT %s\n' "${1#guest:}"
      ;;
    *) die "Not an execution target: '$1'" ;;
  esac
}

_target_valid() {
  target_describe "$1" >/dev/null
}

# Where a path lives for this process. The host's absolute paths are read
# beneath $(sysroot) so a test can point a stage at a scratch tree; a
# guest's are reached through pct and mean exactly what they say.
target_path() {
  local target=$1 path=$2
  if target_is_host "${target}"; then
    printf '%s\n' "$(sysroot)${path}"
    return 0
  fi
  _target_valid "${target}"
  printf '%s\n' "${path}"
}

# --- running commands -----------------------------------------------------

# The command's own exit status, when it ran at all. _guest_exec sets it;
# nothing outside this file should read it.
_GUEST_EXEC_STATUS=''

# The environment a guest command runs with.
#
# `pct exec` keeps the host's environment by default, which hands every
# command in the container -- and every maintainer script apt runs there --
# whatever the host happens to be holding. lib/config.sh exports the
# configuration, secrets included, so the default is a credential leak into
# a place this toolkit does not control. `--keep-env 0` clears it, and what
# the container needs is then stated here rather than inherited.
#
# PATH is named because the toolkit needs sbin for useradd, usermod and
# systemctl, and that requirement should not rest on anyone else's default.
# HOME is for apt and dpkg maintainer scripts, which write into it. The
# locale keeps the output this layer parses predictable without losing
# UTF-8, and C.UTF-8 needs no locale generation in a minimal container.
# TERM=dumb stops a maintainer script reaching for a full-screen frontend.
# Anything else a command needs it is given explicitly, as _target_apt
# gives apt its DEBIAN_FRONTEND.
_TARGET_GUEST_ENV=(
  'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
  'HOME=/root'
  'LANG=C.UTF-8'
  'LC_ALL=C.UTF-8'
  'TERM=dumb'
)

# Runs a command in a container and captures its standard output into the
# named variable.
#
# Values reach the container as arguments to `sh -c`, never spliced into the
# script text: `pct exec` is a nested shell boundary, and a password or a
# key comment containing a quote or a semicolon has to arrive as the one
# argument it started as.
#
# Output is text. Command substitution drops NUL bytes and trailing
# newlines, so a command whose output is binary does not round-trip here
# and nothing should be built on the assumption that it does. Reading a
# file is target_slurp's job, which keeps what a file holds.
#
# The wrapper reports the command's own status on a sentinel line and leaves
# pct with a zero status of its own, so a non-zero status from pct can only
# mean that pct never ran anything. The two failures need different
# remedies -- fix the command, or fix the container -- and they are
# indistinguishable from a bare exit status.
#
# Returns 0 when the command succeeded, 1 when it ran and failed, and 2 when
# pct itself failed.
_guest_exec() {
  local __var=$1 vmid=$2
  shift 2
  # Everything here is named out of the way of the variable the caller
  # asked to have filled in: these locals would otherwise shadow it.
  local __raw __status=0 __out='' __token __reported=''

  __token=$(_guest_sentinel)
  _GUEST_EXEC_STATUS=''
  # The token, the environment and the command are all positional
  # parameters rather than text in the script, for the same reason. The
  # wrapper is told how many assignments to expect instead of guessing
  # where they stop, so a command that looks like one cannot confuse it.
  # shellcheck disable=SC2016  # the wrapper's parameters are /bin/sh's, not ours
  __raw=$(pct exec "${vmid}" --keep-env 0 -- /bin/sh -c \
    '__pve_token=$1; __pve_env=$2; shift 2; while [ "${__pve_env}" -gt 0 ]; do export "$1"; shift; __pve_env=$((__pve_env - 1)); done; "$@"; __pve_status=$?; printf "\n%s:%s\n" "${__pve_token}" "${__pve_status}"' \
    pve-config "${__token}" "${#_TARGET_GUEST_ENV[@]}" "${_TARGET_GUEST_ENV[@]}" "$@") || __status=$?
  if [[ ${__status} -ne 0 ]]; then
    printf -v "${__var}" '%s' "${__raw}"
    return 2
  fi

  # Only the last line can be the report, and only when it carries this
  # call's token. A command is free to print anything it likes, including
  # something that looks like a sentinel, and still be quoted back in full.
  local __last=${__raw##*$'\n'}
  if [[ ${__last} == "${__token}:"* ]]; then
    __reported=${__last#"${__token}":}
    if [[ ${__raw} == *$'\n'* ]]; then
      __out=${__raw%$'\n'*}
    fi
  else
    __out=${__raw}
  fi

  # The sentinel is preceded by a newline of its own, so that a command
  # whose output has no final newline still gets a line to itself. Trailing
  # newlines are dropped the way `$( )` drops them on the host path, which
  # takes that one with it and leaves the two targets agreeing about what a
  # command said.
  while [[ ${__out} == *$'\n' ]]; do
    __out=${__out%$'\n'}
  done
  printf -v "${__var}" '%s' "${__out}"

  # pct succeeded but the wrapper never reported: whatever ran was not the
  # wrapper, so the command's status is unknown and must not be guessed at.
  [[ ${__reported} =~ ^[0-9]+$ ]] || return 2
  _GUEST_EXEC_STATUS=${__reported}
  [[ ${__reported} -eq 0 ]]
}

# A token no caller can predict, so that output which happens to look like
# the end-of-command report cannot be mistaken for one. The kernel's uuid
# source is there on any Linux host; $RANDOM is the fallback, and both are
# read here on the host rather than in the container, which is asked for
# nothing beyond `printf`.
_guest_sentinel() {
  local token=''
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    read -r token </proc/sys/kernel/random/uuid || token=''
  fi
  if [[ -z ${token} ]]; then
    printf -v token '%04x%04x%04x%04x' \
      "${RANDOM}" "${RANDOM}" "${RANDOM}" "${RANDOM}"
  fi
  printf 'pve-config-exit-%s\n' "${token}"
}

# A probe that could not be made during a dry run is a warning, not a
# failure: the container a stage would have created does not exist yet, and
# refusing to describe the work is worse than describing all of it. A real
# run has no such excuse.
_target_unreachable() {
  local target=$1 detail=$2 summary=$3
  if dry_run_enabled; then
    log_warn "pct cannot reach $(target_describe "${target}") yet; assuming ${summary} is not in place"
    return 1
  fi
  [[ -n ${detail} ]] && log_error "${detail}"
  die "pct could not run a command in $(target_describe "${target}"): ${summary}"
}

# Captures a read-only command's standard output into the named variable and
# returns the command's own status.
#
# The output is text: NUL bytes and trailing newlines do not survive, on
# either target, because both read through a command substitution. Every
# caller here reads a mode, a passwd field or a dpkg status. Use
# target_slurp for a file, which keeps the bytes.
#
# Checks run during a dry run as well, on either target: a probe changes
# nothing, and its answer is what keeps the mutation that follows
# conditional. Only commands that read are ever passed here.
#
# The variable is assigned in the caller's shell rather than printed, so a
# refusal reaches the caller. Read through `$( )` it would not: die runs in
# the subshell, the caller sees an empty string and a false comparison, and
# a container pct could not reach would read as a container with no such
# user -- which is how a second account gets created.
target_capture() {
  local __var=$1 target=$2
  shift 2
  _target_valid "${target}"

  local __rc=0
  if target_is_host "${target}"; then
    local __out
    __out=$(run_check "$@") || __rc=$?
    printf -v "${__var}" '%s' "${__out}"
    return "${__rc}"
  fi

  log_info "checking in $(target_describe "${target}"): $(redact "$*")"
  _guest_exec "${__var}" "$(target_vmid "${target}")" "$@" || __rc=$?
  if [[ ${__rc} -eq 2 ]]; then
    # Returns only on a dry run; a real run stops inside.
    _target_unreachable "${target}" "${!__var}" "$(redact "$*")" || return 1
  fi
  [[ ${__rc} -eq 0 ]] || return "${_GUEST_EXEC_STATUS:-${__rc}}"
}

# A read-only check whose output does not matter. Textual, as
# target_capture is.
target_probe() {
  local target=$1
  shift
  local _target_probe_out
  target_capture _target_probe_out "${target}" "$@"
}

# Runs a mutating command. A dry run logs it and runs nothing, on either
# target.
#
# The status is the command's own, so a caller keeps the `|| die` it would
# have written around run_cmd. pct failing to run the command at all is not
# that caller's problem to describe, and stops the run here.
target_run() {
  local target=$1
  shift
  _target_valid "${target}"

  if target_is_host "${target}"; then
    run_cmd "$@"
    return
  fi

  if dry_run_enabled; then
    log_info "would run in $(target_describe "${target}"): $(redact "$*")"
    return 0
  fi

  log_info "running in $(target_describe "${target}"): $(redact "$*")"
  local out='' rc=0
  _guest_exec out "$(target_vmid "${target}")" "$@" || rc=$?
  if [[ -n ${out} ]]; then
    log_info "$(redact "${out}")"
  fi
  if [[ ${rc} -eq 2 ]]; then
    [[ -n ${out} ]] && log_error "${out}"
    die "pct could not run a command in $(target_describe "${target}"): $(redact "$*")"
  fi
  if [[ ${rc} -ne 0 ]]; then
    log_error "the command failed inside $(target_describe "${target}") with status ${_GUEST_EXEC_STATUS}: $(redact "$*")"
    return "${_GUEST_EXEC_STATUS}"
  fi
  return 0
}

# --- inspecting a target's filesystem -------------------------------------

# A single-letter test operator applied on the target: f, d, e or L.
target_test() {
  local target=$1 flag=$2 path=$3
  _target_valid "${target}"
  if target_is_host "${target}"; then
    local rooted
    rooted=$(target_path "${target}" "${path}")
    case ${flag} in
      f) [[ -f ${rooted} ]] ;;
      d) [[ -d ${rooted} ]] ;;
      e) [[ -e ${rooted} ]] ;;
      L) [[ -L ${rooted} ]] ;;
      *) die "target_test: unknown test '${flag}'" ;;
    esac
    return
  fi
  case ${flag} in
    f | d | e | L) ;;
    *) die "target_test: unknown test '${flag}'" ;;
  esac
  target_probe "${target}" test "-${flag}" "${path}"
}

# A private file that exists only long enough to cross the pct boundary.
# mktemp creates at 0600, which keeps a key or a password private for the
# instant it is on the host's disk.
_target_scratch_file() {
  local tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/pve-config-target.XXXXXX") || return 1
  chmod 0600 -- "${tmp}" || {
    rm -f -- "${tmp}"
    return 1
  }
  printf '%s\n' "${tmp}"
}

# True when a file holds nothing a bash variable cannot carry.
#
# `read -r -d ''` stops at the first NUL, so a pulled file containing one
# would be compared on its leading fragment alone and a file that differs
# past that point would be reported `unchanged`. A NUL is refused rather
# than silently truncated.
_target_file_has_no_nul() {
  local file=$1 total stripped
  total=$(wc -c <"${file}") || return 1
  stripped=$(tr -d '\000' <"${file}" | wc -c) || return 1
  [[ ${total} -eq ${stripped} ]]
}

# Reads a file off the target into the named variable, returning non-zero
# when there is nothing to read.
#
# The container's copy is pulled out and examined here rather than being
# picked apart by a shell pipeline inside it. The guard is still answered
# from the guest's own filesystem -- which is the part that matters, since
# the host's /etc/passwd says nothing about a container -- while the
# comparison that follows stays the one the host path uses.
target_slurp() {
  local __var=$1 __target=$2 __path=$3
  printf -v "${__var}" '%s' ''
  _target_valid "${__target}"

  if target_is_host "${__target}"; then
    local __rooted
    __rooted=$(target_path "${__target}" "${__path}")
    [[ -f ${__rooted} ]] || return 1
    _slurp "${__var}" "${__rooted}"
    return 0
  fi

  # The existence check comes first so that a pull which fails means what
  # it says: the file is there and could not be read.
  target_test "${__target}" f "${__path}" || return 1

  local __vmid __tmp __out __status=0
  __vmid=$(target_vmid "${__target}")
  __tmp=$(_target_scratch_file) ||
    die "Unable to create a temporary file to read ${__path} from $(target_describe "${__target}")"
  log_info "reading ${__path} from $(target_describe "${__target}")"
  __out=$(pct pull "${__vmid}" "${__path}" "${__tmp}" 2>&1) || __status=$?
  if [[ ${__status} -ne 0 ]]; then
    rm -f -- "${__tmp}"
    [[ -n ${__out} ]] && log_error "${__out}"
    die "pct could not read ${__path} from $(target_describe "${__target}")"
  fi
  if ! _target_file_has_no_nul "${__tmp}"; then
    rm -f -- "${__tmp}"
    die "Refusing to read ${__path} from $(target_describe "${__target}"): it contains a NUL byte"
  fi
  _slurp "${__var}" "${__tmp}"
  rm -f -- "${__tmp}"
}

# True for a mode that is safe to hand to `$((8#...))`.
#
# One to four octal digits, optionally prefixed with a zero. `stat -c '%a'`
# drops every leading zero, so it reports 0000 as `0` and 0070 as `70`, and
# both have to pass.
_is_octal_mode() {
  [[ $1 =~ ^0?[0-7]{1,4}$ ]]
}

# The permission bits as the target reports them, or non-zero when the path
# is not there.
#
# A mode leaves this function only once it is known to be octal digits.
# Every consumer feeds it to `$((8#...))`, and bash arithmetic evaluates an
# array subscript, so an unvalidated string from a container would run
# commands as root on the host -- during a dry run as readily as any other
# time. The guest is not trusted to answer this question sensibly.
target_mode() {
  local __var=$1 target=$2 path=$3 __mode_raw
  _target_valid "${target}"
  if target_is_host "${target}"; then
    __mode_raw=$(stat -c '%a' -- "$(target_path "${target}" "${path}")" 2>/dev/null) || return 1
  else
    target_capture __mode_raw "${target}" stat -c '%a' -- "${path}" || return 1
    _is_octal_mode "${__mode_raw}" ||
      die "$(target_describe "${target}") reported a mode for ${path} that is not octal: '${__mode_raw}'"
  fi
  printf -v "${__var}" '%s' "${__mode_raw}"
  return 0
}

_target_mode_matches() {
  local target=$1 path=$2 mode=$3 current
  target_mode current "${target}" "${path}" || return 1
  [[ $((8#${current})) -eq $((8#${mode})) ]]
}

_target_refuse_symlink() {
  local target=$1 path=$2
  if target_test "${target}" L "${path}"; then
    die "Refusing to write through the symlink ${path} on $(target_describe "${target}")"
  fi
  if target_test "${target}" e "${path}" && ! target_test "${target}" f "${path}"; then
    die "Refusing to write ${path} on $(target_describe "${target}"): not a regular file"
  fi
}

# --- files ----------------------------------------------------------------

# An explicitly octal form of a mode, with every bit the caller asked for.
#
# `pct push --perms` prefixes a leading zero itself when the value has none
# and then parses base 0, so an unprefixed 640 already means 0640. Saying so
# in the value rather than relying on that is cheap, and it refuses a mode
# that is not octal at all instead of letting pct guess at it. `stat -c %a`
# drops every leading zero and keeps setuid, setgid and sticky in a fourth
# digit, so 0000 comes back as `0` and 0070 as `70`. One to four octal
# digits are accepted so a stat-reported mode round-trips intact.
_target_perms() {
  local __var=$1 mode=$2
  _is_octal_mode "${mode}" ||
    die "Not an octal file mode: '${mode}'"
  printf -v "${__var}" '0%o' "$((8#${mode}))"
}

# Copies content into the container. The scratch file is removed on every
# path out, including the failing one.
_guest_push() {
  local target=$1 path=$2 content=$3 mode=$4
  local vmid dir tmp out perms status=0
  vmid=$(target_vmid "${target}")
  dir=$(dirname -- "${path}")
  _target_perms perms "${mode}"

  target_run "${target}" mkdir -p -- "${dir}" ||
    die "Unable to create ${dir} on $(target_describe "${target}")"

  tmp=$(_target_scratch_file) ||
    die "Unable to create a temporary file for ${path}"
  if ! printf '%s' "${content}" >"${tmp}"; then
    rm -f -- "${tmp}"
    die "Unable to stage ${path} for $(target_describe "${target}")"
  fi

  out=$(pct push "${vmid}" "${tmp}" "${path}" --perms "${perms}" 2>&1) || status=$?
  rm -f -- "${tmp}"
  if [[ ${status} -ne 0 ]]; then
    [[ -n ${out} ]] && log_error "${out}"
    die "pct could not write ${path} into $(target_describe "${target}")"
  fi
}

# Writes content only when it differs from what the target already has.
#
# The host keeps its atomic install; a guest gets `pct push`, which replaces
# the file in one step of its own. Neither writes anything during a dry run.
target_write_file() {
  local target=$1 path=$2 content=$3 mode=${4:-}
  _target_valid "${target}"
  if target_is_host "${target}"; then
    write_file "$(target_path "${target}" "${path}")" "${content}" "${mode}"
    return
  fi

  _target_refuse_symlink "${target}" "${path}"

  local existing='' current='' present=0 changed=0
  if target_slurp existing "${target}" "${path}"; then
    present=1
    target_mode current "${target}" "${path}" || current=''
  fi

  if [[ ${present} -eq 0 || ${existing} != "${content}" ]]; then
    changed=1
  elif [[ -n ${mode} ]] && ! _target_mode_matches "${target}" "${path}" "${mode}"; then
    changed=1
  fi

  if [[ ${changed} -eq 0 ]]; then
    printf 'unchanged\n'
    return 0
  fi

  if dry_run_enabled; then
    log_info "would write ${path} on $(target_describe "${target}")"
    printf 'changed\n'
    return 0
  fi

  local perms=${mode}
  [[ -n ${perms} ]] || perms=${current:-0644}
  _guest_push "${target}" "${path}" "${content}" "${perms}"
  log_info "wrote ${path} on $(target_describe "${target}")"
  printf 'changed\n'
}

target_ensure_dir() {
  local target=$1 path=$2 mode=${3:-} uid=${4:-} gid=${5:-}
  _target_valid "${target}"
  if target_is_host "${target}"; then
    ensure_dir "$(target_path "${target}" "${path}")" "${mode}" "${uid}" "${gid}"
    return
  fi

  local changed=0
  if target_test "${target}" L "${path}"; then
    die "Refusing to use the symlink ${path} on $(target_describe "${target}") as a directory"
  fi
  if target_test "${target}" e "${path}" && ! target_test "${target}" d "${path}"; then
    die "Refusing to use ${path} on $(target_describe "${target}") as a directory: it is not one"
  fi

  if ! target_test "${target}" d "${path}"; then
    changed=1
    if dry_run_enabled; then
      log_info "would create the directory ${path} on $(target_describe "${target}")"
      printf 'changed\n'
      return 0
    fi
    target_run "${target}" mkdir -p -- "${path}" ||
      die "Unable to create the directory ${path} on $(target_describe "${target}")"
  fi

  if [[ -n ${mode} ]] && ! _target_mode_matches "${target}" "${path}" "${mode}"; then
    changed=1
    if dry_run_enabled; then
      log_info "would set mode ${mode} on ${path} on $(target_describe "${target}")"
    else
      target_run "${target}" chmod -- "${mode}" "${path}" ||
        die "Unable to set mode ${mode} on ${path} on $(target_describe "${target}")"
    fi
  fi

  if [[ -n ${uid} && -n ${gid} ]]; then
    local owner_state
    state_of owner_state target_ensure_owner "${target}" "${path}" "${uid}" "${gid}"
    if [[ ${owner_state} == changed ]]; then
      changed=1
    fi
  fi

  if [[ ${changed} -eq 1 ]]; then
    printf 'changed\n'
  else
    printf 'unchanged\n'
  fi
}

target_ensure_owner() {
  local target=$1 path=$2 uid=$3 gid=$4
  _target_valid "${target}"
  if target_is_host "${target}"; then
    ensure_owner "$(target_path "${target}" "${path}")" "${uid}" "${gid}"
    return
  fi

  local current=''
  if target_capture current "${target}" stat -c '%u:%g' -- "${path}"; then
    if [[ ${current} == "${uid}:${gid}" ]]; then
      printf 'unchanged\n'
      return 0
    fi
  fi
  if dry_run_enabled; then
    log_info "would set the owner of ${path} on $(target_describe "${target}") to ${uid}:${gid}"
    printf 'changed\n'
    return 0
  fi
  target_run "${target}" chown -- "${uid}:${gid}" "${path}" ||
    die "Unable to set the owner of ${path} on $(target_describe "${target}")"
  printf 'changed\n'
}

target_ensure_not_group_other_writable() {
  local target=$1 path=$2
  _target_valid "${target}"
  if target_is_host "${target}"; then
    ensure_not_group_other_writable "$(target_path "${target}" "${path}")"
    return
  fi

  local mode=''
  if ! target_mode mode "${target}" "${path}"; then
    printf 'unchanged\n'
    return 0
  fi
  if ((8#${mode} & 8#22)); then
    if dry_run_enabled; then
      log_info "would clear the group and other write bits on ${path} on $(target_describe "${target}")"
      printf 'changed\n'
      return 0
    fi
    target_run "${target}" chmod go-w -- "${path}" ||
      die "Unable to clear the write bits on ${path} on $(target_describe "${target}")"
    printf 'changed\n'
    return 0
  fi
  printf 'unchanged\n'
}

target_remove_path() {
  local target=$1 path=$2
  _target_valid "${target}"
  if target_is_host "${target}"; then
    remove_path "$(target_path "${target}" "${path}")"
    return
  fi

  if ! target_test "${target}" e "${path}" && ! target_test "${target}" L "${path}"; then
    printf 'unchanged\n'
    return 0
  fi
  if dry_run_enabled; then
    log_info "would remove ${path} on $(target_describe "${target}")"
    printf 'changed\n'
    return 0
  fi
  target_run "${target}" rm -f -- "${path}" ||
    die "Unable to remove ${path} on $(target_describe "${target}")"
  printf 'changed\n'
}

# The mode to give a file this is rewriting rather than creating, so a push
# does not quietly reset one the operator or the distribution chose.
_target_existing_mode() {
  local __var=$1 target=$2 path=$3
  target_mode "${__var}" "${target}" "${path}" || printf -v "${__var}" '%s' '0644'
}

target_ensure_line_in_file() {
  local target=$1 path=$2 line=$3 position=${4:-append}
  _target_valid "${target}"
  if target_is_host "${target}"; then
    ensure_line_in_file "$(target_path "${target}" "${path}")" "${line}" "${position}"
    return
  fi

  local body=''
  target_slurp body "${target}" "${path}" || body=''
  if _line_present_in_body "${body}" "${line}"; then
    printf 'unchanged\n'
    return 0
  fi

  if dry_run_enabled; then
    log_info "would add line to ${path} on $(target_describe "${target}"): $(redact "${line}")"
    printf 'changed\n'
    return 0
  fi

  _target_refuse_symlink "${target}" "${path}"
  local updated mode
  _line_appended_body updated "${body}" "${line}" "${position}"
  _target_existing_mode mode "${target}" "${path}"
  _guest_push "${target}" "${path}" "${updated}" "${mode}"
  log_info "added line to ${path} on $(target_describe "${target}")"
  printf 'changed\n'
}

# Leaves exactly one active line matching the pattern, collapsing any
# duplicates an earlier run left behind. The guest path takes no backup: a
# container this toolkit built has no operator state to preserve, and the
# backup on the host exists to keep what the operator had before.
target_ensure_exact_line() {
  local target=$1 path=$2 match=$3 line=$4 position=${5:-append}
  _target_valid "${target}"
  if target_is_host "${target}"; then
    ensure_exact_line "$(target_path "${target}" "${path}")" "${match}" "${line}" "${position}"
    return
  fi

  _target_refuse_symlink "${target}" "${path}"

  local original='' rebuilt
  target_slurp original "${target}" "${path}" || original=''
  _exact_line_body rebuilt "${original}" "${match}" "${line}" "${position}"
  if [[ ${rebuilt} == "${original}" ]]; then
    printf 'unchanged\n'
    return 0
  fi

  if dry_run_enabled; then
    log_info "would set the ${match} line in ${path} on $(target_describe "${target}")"
    printf 'changed\n'
    return 0
  fi

  local mode
  _target_existing_mode mode "${target}" "${path}"
  _guest_push "${target}" "${path}" "${rebuilt}" "${mode}"
  log_info "set the ${match} line in ${path} on $(target_describe "${target}")"
  printf 'changed\n'
}

# --- accounts -------------------------------------------------------------

# A passwd field as the target's own database records it. The guest's file
# is pulled out and parsed with the same awk the host path uses, so the two
# cannot disagree about what an account looks like.
#
# The value is assigned rather than printed for the same reason as
# target_capture: a container pct cannot reach must not read as an account
# that is merely absent.
target_user_field() {
  local __var=$1 target=$2 name=$3 field=$4 __value
  _target_valid "${target}"
  if target_is_host "${target}"; then
    __value=$(_users_field "${name}" "${field}") || return 1
    printf -v "${__var}" '%s' "${__value}"
    return 0
  fi

  # Not a __-prefixed name: those are the ones the helpers below reserve
  # for the variable a caller asks to have filled in.
  local passwd_body=''
  target_slurp passwd_body "${target}" /etc/passwd || return 1
  __value=$(_passwd_field_from_body "${passwd_body}" "${name}" "${field}") || return 1
  printf -v "${__var}" '%s' "${__value}"
}

target_user_exists() {
  local _target_user_name
  target_user_field _target_user_name "$1" "$2" 1
}

target_user_uid() { target_user_field "$1" "$2" "$3" 3; }
target_user_gid() { target_user_field "$1" "$2" "$3" 4; }
target_user_home() { target_user_field "$1" "$2" "$3" 6; }
target_user_shell() { target_user_field "$1" "$2" "$3" 7; }

# Creates the account when it is absent and otherwise converges the login
# shell. Both the question and the answer belong to the target: a container
# is asked about its own accounts, never about the host's.
target_user_converge() {
  local target=$1 name=$2 shell=${3:-/bin/bash} current=''

  if ! target_user_exists "${target}" "${name}"; then
    target_run "${target}" useradd -m -s "${shell}" "${name}" ||
      die "Unable to create the user ${name} on $(target_describe "${target}")"
    printf 'changed\n'
    return 0
  fi

  target_user_shell current "${target}" "${name}" || current=''
  if [[ ${current} != "${shell}" ]]; then
    target_run "${target}" usermod -s "${shell}" "${name}" ||
      die "Unable to set the login shell of ${name} on $(target_describe "${target}")"
    printf 'changed\n'
    return 0
  fi

  printf 'unchanged\n'
}

# Supplementary membership only, as on the host.
target_user_in_group() {
  local target=$1 name=$2 group=$3
  _target_valid "${target}"
  if target_is_host "${target}"; then
    user_in_group "${name}" "${group}"
    return
  fi
  local body=''
  target_slurp body "${target}" /etc/group || return 1
  _group_has_member "${body}" "${group}" "${name}"
}

target_user_join_group() {
  local target=$1 name=$2 group changed=0
  shift 2
  for group in "$@"; do
    target_user_in_group "${target}" "${name}" "${group}" && continue
    target_run "${target}" usermod -aG "${group}" "${name}" ||
      die "Unable to add ${name} to the ${group} group on $(target_describe "${target}")"
    changed=1
  done

  if [[ ${changed} -eq 1 ]]; then
    printf 'changed\n'
  else
    printf 'unchanged\n'
  fi
}

# --- packages -------------------------------------------------------------

target_pkg_is_installed() {
  local target=$1 pkg=$2 status=''
  _target_valid "${target}"
  if target_is_host "${target}"; then
    pkg_is_installed "${pkg}"
    return
  fi
  # shellcheck disable=SC2016  # dpkg-query expands the field itself
  target_capture status "${target}" dpkg-query -W -f='${Status}' -- "${pkg}" || return 1
  [[ ${status} == *' installed' ]]
}

# apt reads DEBIAN_FRONTEND from its own environment, and pct exec carries
# none of this process's, so the guest is given it explicitly.
_target_apt() {
  local target=$1
  shift
  if target_is_guest "${target}"; then
    target_run "${target}" env DEBIAN_FRONTEND=noninteractive apt-get "$@"
    return
  fi
  local DEBIAN_FRONTEND=noninteractive
  export DEBIAN_FRONTEND
  target_run "${target}" apt-get "$@"
}

target_pkg_install() {
  local target=$1
  shift
  _target_valid "${target}"

  local pkg
  local -a missing=()
  for pkg in "$@"; do
    target_pkg_is_installed "${target}" "${pkg}" || missing+=("${pkg}")
  done

  if [[ ${#missing[@]} -eq 0 ]]; then
    printf 'unchanged\n'
    return 0
  fi

  _target_apt "${target}" install -y "${missing[@]}" ||
    die "Unable to install on $(target_describe "${target}"): ${missing[*]}"
  printf 'changed\n'
}

target_apt_update() {
  local target=$1
  _target_valid "${target}"
  _target_apt "${target}" update ||
    die "Unable to refresh the apt package lists on $(target_describe "${target}")"
}

# --- services -------------------------------------------------------------

target_service_is_active() {
  local target=$1 unit=$2
  _target_valid "${target}"
  if target_is_host "${target}"; then
    service_is_active "${unit}"
    return
  fi
  target_probe "${target}" systemctl is-active --quiet -- "${unit}"
}

target_service_is_enabled() {
  local target=$1 unit=$2
  _target_valid "${target}"
  if target_is_host "${target}"; then
    service_is_enabled "${unit}"
    return
  fi
  target_probe "${target}" systemctl is-enabled --quiet -- "${unit}"
}

# One reload per target per stage process. Keyed by target rather than held
# in a single flag, because a stage that writes a unit file on the host and
# another in a container has two managers to tell.
declare -gA _TARGET_DAEMON_RELOADED=()

target_systemd_daemon_reload() {
  local target=$1
  _target_valid "${target}"
  if target_is_host "${target}"; then
    systemd_daemon_reload
    return
  fi
  if [[ -n ${_TARGET_DAEMON_RELOADED[${target}]+set} ]]; then
    printf 'unchanged\n'
    return 0
  fi
  target_run "${target}" systemctl daemon-reload ||
    die "Unable to reload the systemd manager on $(target_describe "${target}")"
  _TARGET_DAEMON_RELOADED[${target}]=1
  printf 'changed\n'
}

target_service_enable() {
  local target=$1 unit=$2
  if target_service_is_enabled "${target}" "${unit}"; then
    printf 'unchanged\n'
    return 0
  fi
  target_run "${target}" systemctl enable -- "${unit}" ||
    die "Unable to enable ${unit} on $(target_describe "${target}")"
  printf 'changed\n'
}

target_service_disable() {
  local target=$1 unit=$2
  if ! target_service_is_enabled "${target}" "${unit}"; then
    printf 'unchanged\n'
    return 0
  fi
  target_run "${target}" systemctl disable -- "${unit}" ||
    die "Unable to disable ${unit} on $(target_describe "${target}")"
  printf 'changed\n'
}

target_service_start() {
  local target=$1 unit=$2
  if target_service_is_active "${target}" "${unit}"; then
    printf 'unchanged\n'
    return 0
  fi
  target_run "${target}" systemctl start -- "${unit}" ||
    die "Unable to start ${unit} on $(target_describe "${target}")"
  printf 'changed\n'
}

# Starts a stopped unit rather than restarting it, as on the host.
target_service_restart() {
  local target=$1 unit=$2
  if ! target_service_is_active "${target}" "${unit}"; then
    target_service_start "${target}" "${unit}"
    return 0
  fi
  target_run "${target}" systemctl restart -- "${unit}" ||
    die "Unable to restart ${unit} on $(target_describe "${target}")"
  printf 'changed\n'
}

target_service_reload() {
  local target=$1 unit=$2
  if ! target_service_is_active "${target}" "${unit}"; then
    printf 'unchanged\n'
    return 0
  fi
  target_run "${target}" systemctl reload -- "${unit}" ||
    die "Unable to reload ${unit} on $(target_describe "${target}")"
  printf 'changed\n'
}
