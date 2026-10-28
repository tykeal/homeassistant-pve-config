#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
# SPDX-License-Identifier: Apache-2.0

# Shared helpers. Sourcing this file defines functions and nothing else, so
# tests and stages can pull it in without triggering behaviour.

_log() {
  local colour=$1 level=$2
  shift 2
  if [[ -t 1 ]]; then
    printf '\033[%sm[%s]\033[0m %s\n' "${colour}" "${level}" "$*" >&2
  else
    printf '[%s] %s\n' "${level}" "$*" >&2
  fi
}

log_info() { _log '0;34' 'INFO' "$@"; }
log_warn() { _log '0;33' 'WARN' "$@"; }
log_error() { _log '0;31' 'ERROR' "$@"; }

die() {
  log_error "$@"
  exit 1
}

require_root() {
  [[ ${EUID} -eq 0 ]] || die 'This must be run as root on the Proxmox VE host.'
}

dry_run_enabled() {
  [[ ${PVE_CONFIG_DRY_RUN:-0} == 1 ]]
}

# Turns xtrace off around secret handling and puts it back as it was. Shell
# tracing would otherwise print every credential it touches.
xtrace_suspend() {
  if [[ ${-} == *x* ]]; then
    _XTRACE_RESUME=1
    set +x
  else
    _XTRACE_RESUME=0
  fi
}

xtrace_resume() {
  if [[ ${_XTRACE_RESUME:-0} == 1 ]]; then
    set -x
  fi
  _XTRACE_RESUME=0
}

_redact_init() {
  [[ -n ${_REDACT_INIT:-} ]] && return 0
  declare -ga _REDACT_VALUES=()
  _REDACT_INIT=1
  # Stages are children of the driver and never load the secrets file
  # themselves, so the driver passes the key names along and the registry is
  # rebuilt from the exported environment.
  # Indirect expansion runs command substitution hidden in a subscript, so
  # the name has to be proven a plain toolkit identifier before it is used.
  local key
  for key in ${PVE_CONFIG_SECRET_KEYS:-}; do
    if [[ ${key} =~ ^PVE_[A-Z0-9_]+$ ]]; then
      redact_register "${!key:-}"
    fi
  done
}

# Registers a value whose appearance in a log line must be masked.
redact_register() {
  local value
  _redact_init
  for value in "$@"; do
    [[ -n ${value} ]] || continue
    _REDACT_VALUES+=("${value}")
  done
}

redact() {
  local text=$1 secret
  _redact_init
  for secret in ${_REDACT_VALUES[@]+"${_REDACT_VALUES[@]}"}; do
    text=${text//"${secret}"/<redacted>}
  done
  printf '%s' "${text}"
}

# Runs a command unless this is a dry run, logging it either way with any
# registered secret masked. The command itself still receives the real
# arguments.
run_cmd() {
  if dry_run_enabled; then
    log_info "would run: $(redact "$*")"
    return 0
  fi
  log_info "running: $(redact "$*")"
  "$@"
}

_squash_ws() {
  local text=${1//$'\t'/ }
  while [[ ${text} == *'  '* ]]; do
    text=${text//  / }
  done
  text=${text# }
  printf '%s' "${text% }"
}

_mode_matches() {
  local path=$1 mode=$2 current
  current=$(stat -c '%a' -- "${path}" 2>/dev/null) || return 1
  [[ $((8#${current})) -eq $((8#${mode})) ]]
}

# Writes content through a temporary file in the same directory and renames
# it into place, so a reader never sees a half written file and a failure
# never truncates the original. mktemp creates at 0600, which keeps a secret
# private from the instant the file exists.
_atomic_install() {
  local path=$1 content=$2 mode=${3:-}
  local dir base tmp
  dir=$(dirname -- "${path}")
  base=$(basename -- "${path}")
  [[ -d ${dir} ]] || mkdir -p -- "${dir}"

  tmp=$(mktemp -- "${dir}/.${base}.XXXXXX") ||
    die "Unable to create a temporary file in ${dir}"

  if ! printf '%s' "${content}" >"${tmp}"; then
    rm -f -- "${tmp}"
    die "Unable to write ${path}"
  fi

  # Every metadata step is checked before the rename: installing a file
  # with the wrong owner or mode is how a secret ends up world readable,
  # and the temporary file is the only thing that may be left behind.
  local failure=''
  if [[ -e ${path} ]]; then
    chown --reference="${path}" -- "${tmp}" 2>/dev/null ||
      failure="Unable to copy the ownership of ${path}"
    if [[ -z ${failure} && -z ${mode} ]]; then
      chmod --reference="${path}" -- "${tmp}" 2>/dev/null ||
        failure="Unable to copy the permissions of ${path}"
    fi
  elif [[ -z ${mode} ]]; then
    chmod 0644 -- "${tmp}" || failure="Unable to set the permissions of ${path}"
  fi

  if [[ -z ${failure} && -n ${mode} ]]; then
    chmod -- "${mode}" "${tmp}" || failure="Unable to set mode ${mode} on ${path}"
  fi

  if [[ -n ${failure} ]]; then
    rm -f -- "${tmp}"
    die "${failure}"
  fi

  if ! mv -f -- "${tmp}" "${path}"; then
    rm -f -- "${tmp}"
    die "Unable to replace ${path}"
  fi
}

_refuse_symlink() {
  local path=$1
  if [[ -L ${path} ]]; then
    die "Refusing to write through the symlink ${path}"
  fi
  if [[ -e ${path} && ! -f ${path} ]]; then
    die "Refusing to write ${path}: not a regular file"
  fi
}

# Writes content only when it differs from what is already on disk. The
# content is written byte for byte, so a caller that wants a trailing
# newline includes one. Prints "changed" or "unchanged" so callers can
# report accurately rather than claiming work they did not do.
# True when write_file would alter the path, so a caller can decide whether
# anything more expensive (a backup, a validation run) is worth doing.
write_file_pending() {
  local path=$1 content=$2 mode=${3:-}
  if [[ ! -f ${path} ]]; then
    return 0
  fi
  if ! printf '%s' "${content}" | cmp -s - "${path}"; then
    return 0
  fi
  [[ -n ${mode} ]] && ! _mode_matches "${path}" "${mode}"
}

write_file() {
  local path=$1 content=$2 mode=${3:-}
  _refuse_symlink "${path}"

  local changed=0
  write_file_pending "${path}" "${content}" "${mode}" && changed=1

  if [[ ${changed} -eq 0 ]]; then
    printf 'unchanged\n'
    return 0
  fi

  if dry_run_enabled; then
    log_info "would write ${path}"
    printf 'changed\n'
    return 0
  fi

  _atomic_install "${path}" "${content}" "${mode}"
  log_info "wrote ${path}"
  printf 'changed\n'
}

# Reads a whole file into the named variable without losing trailing
# newlines, which command substitution would strip.
_slurp() {
  local __target=$1 __path=$2 __body=''
  if [[ -f ${__path} ]]; then
    IFS= read -r -d '' __body <"${__path}" || true
  fi
  printf -v "${__target}" '%s' "${__body}"
}

# The decisions below are made on a file's contents rather than on a path,
# so that a guest's file -- which is read out of the container rather than
# opened -- is judged by exactly the same rules as the host's. A container
# that answered these questions differently would reacquire the duplicate
# PAM line this whole approach exists to prevent.
#
# A body ends with the newline its last line carries, so one trailing
# newline is dropped before splitting: without that, every file would appear
# to end in a line that is not there.

# True when an equivalent line is already present. Comparison collapses
# whitespace runs and is literal throughout, so regex metacharacters match
# as themselves and a commented out variant does not count as present.
_line_present_in_body() {
  local body=$1 want existing
  [[ -n ${body} ]] || return 1
  want=$(_squash_ws "$2")
  while IFS= read -r existing || [[ -n ${existing} ]]; do
    if [[ $(_squash_ws "${existing}") == "${want}" ]]; then
      return 0
    fi
  done <<<"${body%$'\n'}"
  return 1
}

_line_appended_body() {
  local __var=$1 body=$2 line=$3 position=$4 __updated
  case ${position} in
    prepend)
      __updated="${line}"$'\n'"${body}"
      ;;
    append)
      if [[ -n ${body} && ${body} != *$'\n' ]]; then
        __updated="${body}"$'\n'"${line}"$'\n'
      else
        __updated="${body}${line}"$'\n'
      fi
      ;;
    *) die "ensure_line_in_file: unknown position '${position}'" ;;
  esac
  printf -v "${__var}" '%s' "${__updated}"
}

# Appends a line only when an equivalent one is absent. This is what stops a
# repeated run stacking duplicate PAM entries.
ensure_line_in_file() {
  local path=$1 line=$2 position=${3:-append}
  local body=''
  _slurp body "${path}"

  if _line_present_in_body "${body}" "${line}"; then
    printf 'unchanged\n'
    return 0
  fi

  if dry_run_enabled; then
    log_info "would add line to ${path}: $(redact "${line}")"
    printf 'changed\n'
    return 0
  fi

  _refuse_symlink "${path}"

  local updated
  _line_appended_body updated "${body}" "${line}" "${position}"

  _atomic_install "${path}" "${updated}"
  log_info "added line to ${path}"
  printf 'changed\n'
}

# Takes a single pristine copy before the toolkit first edits a file, so the
# operator can always see what the installer inherited.
#
# A file that was not there to begin with gets an empty tombstone instead.
# Without one, a managed file created by an early run would be backed up on
# a later one, presenting this toolkit's own output as operator state.
backup_file() {
  local path=$1
  local backup="${path}.pve-config.bak"
  local tombstone="${path}.pve-config.absent"

  if [[ -e ${backup} ]] || [[ -e ${tombstone} ]]; then
    printf 'unchanged\n'
    return 0
  fi

  if [[ ! -f ${path} ]]; then
    if dry_run_enabled; then
      log_info "would record that ${path} did not exist"
      printf 'changed\n'
      return 0
    fi
    _atomic_install "${tombstone}" '' 0644
    log_info "recorded that ${path} did not exist before pve-config"
    printf 'changed\n'
    return 0
  fi

  if dry_run_enabled; then
    log_info "would back up ${path} to ${backup}"
    printf 'changed\n'
    return 0
  fi
  cp -p -- "${path}" "${backup}"
  log_info "backed up ${path} to ${backup}"
  printf 'changed\n'
}

# write_file, preceded by a one-time backup of whatever the operator had
# there before. The backup is taken only when the content is genuinely about
# to change; backing up unconditionally would, on the second run, snapshot
# our own output over the original.
write_file_backup() {
  local path=$1 content=$2 mode=${3:-}
  if write_file_pending "${path}" "${content}" "${mode}"; then
    backup_file "${path}" >/dev/null
  fi
  write_file "${path}" "${content}" "${mode}"
}

# Yes/no prompt. ASSUME_YES answers yes; NON_INTERACTIVE takes the default
# without asking, so unattended runs never block on a terminal.
confirm() {
  local prompt=$1 default=${2:-no} reply=''
  if [[ ${ASSUME_YES:-0} == 1 ]]; then
    return 0
  fi
  if [[ ${NON_INTERACTIVE:-0} == 1 ]] || [[ ! -t 0 ]]; then
    [[ ${default} == yes ]]
    return
  fi
  local hint='y/N'
  [[ ${default} == yes ]] && hint='Y/n'
  read -r -p "${prompt} [${hint}] " reply || reply=''
  reply=${reply:-${default}}
  [[ ${reply} =~ ^[Yy]([Ee][Ss])?$ ]]
}

# Absolute system paths are built on this prefix so the stages can be
# exercised against a scratch tree instead of the host they would otherwise
# reconfigure. It is empty on a real host.
sysroot() {
  printf '%s\n' "${PVE_CONFIG_ROOT:-}"
}

# Private scratch space for candidate files. It lives beside the state
# directory, which is root owned, because a candidate sudoers or sshd
# fragment must never be visible at the path those daemons read.
# A private directory that lives only for the duration of one validation
# and is removed on every path out. Nothing persists, so a dry run leaves
# the host exactly as it found it, and a candidate sudoers or sshd file is
# never readable by anyone but root even for the instant it exists.
_validation_dir() {
  local dir
  dir=$(mktemp -d "${TMPDIR:-/tmp}/pve-config-validate.XXXXXX") || return 1
  chmod 0700 -- "${dir}" || {
    rm -rf -- "${dir}"
    return 1
  }
  printf '%s\n' "${dir}"
}

# Runs a read-only check. Unlike run_cmd this executes during a dry run as
# well: a validator changes nothing, and its verdict is the whole point of
# calling it.
run_check() {
  log_info "checking: $(redact "$*")"
  "$@"
}

# Captures a helper's verdict into a named variable, and dies when the
# helper itself failed.
#
# `[[ $(write_file ...) == changed ]]` cannot tell a refusal from a no-op:
# die runs inside the command substitution's subshell, so the caller sees an
# empty string and a comparison that is merely false. Everything that merges
# a verdict goes through this instead, so a refused symlink or a failed chown
# stops the run rather than being reported as "nothing to do".
state_of() {
  local __var=$1
  shift
  local __out
  __out=$("$@") || die "Failed while running: $(redact "$*")"
  printf -v "${__var}" '%s' "${__out}"
}

_owner_matches() {
  local path=$1 uid=$2 gid=$3 current
  current=$(stat -c '%u:%g' -- "${path}" 2>/dev/null) || return 1
  [[ ${current} == "${uid}:${gid}" ]]
}

# Numeric ids rather than names: the toolkit reads them out of the passwd
# database it is converging, and a name lookup would have to agree with it.
ensure_owner() {
  local path=$1 uid=$2 gid=$3
  if _owner_matches "${path}" "${uid}" "${gid}"; then
    printf 'unchanged\n'
    return 0
  fi
  if dry_run_enabled; then
    log_info "would set the owner of ${path} to ${uid}:${gid}"
    printf 'changed\n'
    return 0
  fi
  chown -- "${uid}:${gid}" "${path}" || die "Unable to set the owner of ${path}"
  log_info "set the owner of ${path} to ${uid}:${gid}"
  printf 'changed\n'
}

ensure_dir() {
  local path=$1 mode=${2:-} uid=${3:-} gid=${4:-}
  local changed=0

  if [[ -L ${path} ]]; then
    die "Refusing to use the symlink ${path} as a directory"
  fi
  if [[ -e ${path} && ! -d ${path} ]]; then
    die "Refusing to use ${path} as a directory: it is not one"
  fi

  if [[ ! -d ${path} ]]; then
    changed=1
    if dry_run_enabled; then
      log_info "would create the directory ${path}"
      printf 'changed\n'
      return 0
    fi
    mkdir -p -- "${path}" || die "Unable to create the directory ${path}"
    log_info "created the directory ${path}"
  fi

  if [[ -n ${mode} ]] && ! _mode_matches "${path}" "${mode}"; then
    changed=1
    if dry_run_enabled; then
      log_info "would set mode ${mode} on ${path}"
    else
      chmod -- "${mode}" "${path}" || die "Unable to set mode ${mode} on ${path}"
    fi
  fi

  if [[ -n ${uid} && -n ${gid} ]]; then
    local owner_state
    state_of owner_state ensure_owner "${path}" "${uid}" "${gid}"
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

# Clears the group and other write bits and leaves every other bit alone.
# Several things OpenSSH reads are refused outright when a path anybody
# else can write to leads to them, and rewriting the whole mode to repair
# that would discard whatever the operator meant by the rest of it.
ensure_not_group_other_writable() {
  local path=$1 mode
  if [[ ! -e ${path} ]]; then
    # Nothing on disk yet, which under a dry run is the normal case: the
    # directory the caller just reported it would create.
    printf 'unchanged\n'
    return 0
  fi
  mode=$(stat -c '%a' -- "${path}" 2>/dev/null) || die "Unable to read the mode of ${path}"
  if ((8#${mode} & 8#22)); then
    if dry_run_enabled; then
      log_info "would clear the group and other write bits on ${path}"
      printf 'changed\n'
      return 0
    fi
    chmod go-w -- "${path}" || die "Unable to clear the write bits on ${path}"
    log_info "cleared the group and other write bits on ${path}"
    printf 'changed\n'
    return 0
  fi
  printf 'unchanged\n'
}

remove_path() {
  local path=$1
  if [[ ! -e ${path} && ! -L ${path} ]]; then
    printf 'unchanged\n'
    return 0
  fi
  if dry_run_enabled; then
    log_info "would remove ${path}"
    printf 'changed\n'
    return 0
  fi
  rm -f -- "${path}" || die "Unable to remove ${path}"
  log_info "removed ${path}"
  printf 'changed\n'
}

# Points link at target. An existing regular file is backed up first, since
# replacing it is the one case where the original content would be lost.
ensure_symlink() {
  local target=$1 link=$2 current=''
  if [[ -L ${link} ]]; then
    current=$(readlink -- "${link}") || current=''
    if [[ ${current} == "${target}" ]]; then
      printf 'unchanged\n'
      return 0
    fi
  elif [[ -f ${link} ]]; then
    backup_file "${link}" >/dev/null
  elif [[ -e ${link} ]]; then
    die "Refusing to replace ${link} with a symlink: it is not a regular file"
  fi

  if dry_run_enabled; then
    log_info "would link ${link} to ${target}"
    printf 'changed\n'
    return 0
  fi
  ln -sfn -- "${target}" "${link}" || die "Unable to link ${link} to ${target}"
  log_info "linked ${link} to ${target}"
  printf 'changed\n'
}

_is_comment() {
  local text=$1
  text=${text#"${text%%[![:space:]]*}"}
  [[ ${text} == '#'* ]]
}

# The file as it would be with exactly one active line matching the
# pattern, wherever the file had them before.
#
# Commented out variants are left alone, so an operator's note about why a
# line was disabled survives.
#
# position is append, prepend, or after-first, the last of which reproduces
# the placement a PAM stack expects without reproducing the duplication.
_exact_line_body() {
  local __var=$1 body=$2 match=$3 line=$4 position=$5
  local -a kept=()
  local existing

  if [[ -n ${body} ]]; then
    while IFS= read -r existing || [[ -n ${existing} ]]; do
      if ! _is_comment "${existing}" && [[ ${existing} =~ ${match} ]]; then
        continue
      fi
      kept+=("${existing}")
    done <<<"${body%$'\n'}"
  fi

  case ${position} in
    prepend)
      kept=("${line}" ${kept[@]+"${kept[@]}"})
      ;;
    append)
      kept+=("${line}")
      ;;
    after-first)
      if [[ ${#kept[@]} -eq 0 ]]; then
        kept=("${line}")
      else
        local -a rest=("${kept[@]:1}")
        kept=("${kept[0]}" "${line}" ${rest[@]+"${rest[@]}"})
      fi
      ;;
    *) die "ensure_exact_line: unknown position '${position}'" ;;
  esac

  local __rebuilt=''
  for existing in "${kept[@]}"; do
    __rebuilt+="${existing}"$'\n'
  done
  printf -v "${__var}" '%s' "${__rebuilt}"
}

# Leaves exactly one active line matching a pattern. ensure_line_in_file
# only appends when nothing matches, which is why a `sed -i '1a ...'`
# replacement needs this instead: the duplicates an earlier run left behind
# have to be removed, not merely not added to.
ensure_exact_line() {
  local path=$1 match=$2 line=$3 position=${4:-append}
  _refuse_symlink "${path}"

  local original='' rebuilt
  _slurp original "${path}"
  _exact_line_body rebuilt "${original}" "${match}" "${line}" "${position}"

  if [[ ${rebuilt} == "${original}" ]]; then
    printf 'unchanged\n'
    return 0
  fi

  if dry_run_enabled; then
    log_info "would set the ${match} line in ${path}"
    printf 'changed\n'
    return 0
  fi

  backup_file "${path}" >/dev/null
  _atomic_install "${path}" "${rebuilt}"
  log_info "set the ${match} line in ${path}"
  printf 'changed\n'
}

_sshd_binary() {
  local candidate
  candidate=$(command -v sshd 2>/dev/null) || candidate=''
  if [[ -z ${candidate} && -x /usr/sbin/sshd ]]; then
    candidate=/usr/sbin/sshd
  fi
  [[ -n ${candidate} ]] || return 1
  printf '%s\n' "${candidate}"
}

# A validator's tool can be absent precisely because a dry run declined to
# install the package providing it. That cannot fail a dry run, and must
# always fail a real one.
_validator_missing() {
  local tool=$1 target=$2
  if dry_run_enabled; then
    log_warn "${tool} is not installed; would validate ${target} once it is"
    return 0
  fi
  log_error "${tool} is not installed; refusing to install an unvalidated ${target}"
  return 1
}

# Points every Include that referred to the host's sshd_config.d at the
# scratch copy of it, leaving the filename or glob it named -- and any other
# operand on the line -- exactly as it was.
_sshd_redirect_includes() {
  local body=$1 src=$2 conf_d=$3
  local bare='/etc/ssh/sshd_config.d'
  local root
  root=$(sysroot)
  local line trimmed keyword operand rewritten out=''
  local -a operands=()
  while IFS= read -r line || [[ -n ${line} ]]; do
    trimmed=${line#"${line%%[![:space:]]*}"}
    keyword=${trimmed%%[[:space:]]*}
    if [[ ${keyword,,} == include ]]; then
      rewritten=''
      # read, not an unquoted expansion: the operand is a pattern naming
      # files on the host, and letting the shell expand it here would
      # replace it with whatever happens to match outside the scratch tree.
      read -r -a operands <<<"${trimmed#"${keyword}"}"
      for operand in ${operands[@]+"${operands[@]}"}; do
        case ${operand} in
          "${src}"/*) operand="${conf_d}/${operand#"${src}/"}" ;;
          "${bare}"/*) operand="${conf_d}/${operand#"${bare}/"}" ;;
          # Everything else is read where sshd would read it, which under a
          # sysroot means beneath that root; a relative path resolves
          # against /etc/ssh exactly as sshd resolves it. A path already
          # beneath the root is left alone rather than rooted twice.
          "${root}"/*) ;;
          /*) operand="${root}${operand}" ;;
          *) operand="${root}/etc/ssh/${operand}" ;;
        esac
        rewritten+=" ${operand}"
      done
      line="${keyword}${rewritten}"
    fi
    out+="${line}"$'\n'
  done <<<"${body}"
  printf '%s' "${out%$'\n'}"
}

# Whether the assembled configuration actually pulls the candidate in. An
# Include naming one file rather than the whole directory does not, and
# validating a fragment on the strength of an Include that excludes it is
# how a host ends up reporting itself hardened and still taking passwords.
_sshd_includes_candidate() {
  local body=$1 candidate=$2
  local line trimmed keyword glob match
  local -a operands=()
  while IFS= read -r line || [[ -n ${line} ]]; do
    trimmed=${line#"${line%%[![:space:]]*}"}
    keyword=${trimmed%%[[:space:]]*}
    [[ ${keyword,,} == include ]] || continue
    read -r -a operands <<<"${trimmed#*[[:space:]]}"
    for glob in ${operands[@]+"${operands[@]}"}; do
      for match in ${glob}; do
        [[ ${match} == "${candidate}" ]] && return 0
      done
    done
  done <<<"${body}"
  return 1
}

# Assembles the configuration sshd would actually read: the host's own
# sshd_config, its Include redirected into a scratch tree, every other
# fragment it would pull in, and the candidate in place of the one being
# replaced. Checking the fragment on its own would miss every interaction
# between it and the rest of the configuration.
_sshd_effective_config() {
  local candidate=$1 target=$2 dir=$3
  local conf_d="${dir}/sshd_config.d"
  local base main body='' existing root
  root=$(sysroot)
  base=$(basename -- "${target}")

  mkdir -p -- "${conf_d}" || return 1

  # Every file in the directory, not only *.conf: an Include naming
  # `site-policy` or `*.cfg` pulls in whatever it names, and leaving those
  # out of the scratch tree would validate a configuration the daemon does
  # not have.
  local src="${root}/etc/ssh/sshd_config.d"
  if [[ -d ${src} ]]; then
    for existing in "${src}"/*; do
      [[ -f ${existing} ]] || continue
      [[ $(basename -- "${existing}") == "${base}" ]] && continue
      cp -- "${existing}" "${conf_d}/" || return 1
    done
  fi
  cp -- "${candidate}" "${conf_d}/${base}" || return 1

  main="${dir}/sshd_config"
  local host_main="${root}/etc/ssh/sshd_config"
  if [[ -f ${host_main} ]]; then
    local original=''
    _slurp original "${host_main}"
    body=$(_sshd_redirect_includes "${original}" "${src}" "${conf_d}")
    body+=$'\n'
    # Rewriting the directory an Include points at, rather than the whole
    # directive, is what keeps this honest: a host that includes one named
    # file rather than the whole directory still includes only that file
    # here, and the check below notices that the candidate is not among
    # them instead of approving a fragment sshd would never read.
    if ! _sshd_includes_candidate "${body}" "${conf_d}/${base}"; then
      if dry_run_enabled || [[ ${PVE_CONFIG_SSHD_ASSUME_INCLUDE:-0} == 1 ]]; then
        # The caller adds the Include before installing; during a dry run it
        # has not, and a caller that deliberately defers the Include until
        # the fragment has validated has not either. The assembled
        # configuration stands in for the one sshd will read rather than
        # failing on a file nothing has written yet.
        log_info "${host_main} does not include ${base}; an Include would be added"
        body="Include ${conf_d}/*.conf"$'\n'"${body}"
      else
        log_error "${host_main} does not include ${base}, so sshd would never read it"
        return 1
      fi
    fi
  else
    body="Include ${conf_d}/*.conf"$'\n'
  fi

  printf '%s' "${body}" >"${main}" || return 1
  printf '%s\n' "${main}"
}

# OpenSSH accepts ChallengeResponseAuthentication as an alias for
# KbdInteractiveAuthentication, so a conditional block spelled the old way
# would slip past a check that compared keywords literally.
_sshd_canonical_keyword() {
  local keyword=${1,,}
  case ${keyword} in
    challengeresponseauthentication) printf 'kbdinteractiveauthentication\n' ;;
    *) printf '%s\n' "${keyword}" ;;
  esac
}

_sshd_canonical_value() {
  local value=${1,,}
  case ${value} in
    prohibit-password | without-password) printf 'without-password\n' ;;
    forced-commands-only) printf 'forced-commands-only\n' ;;
    true) printf 'yes\n' ;;
    false) printf 'no\n' ;;
    *) printf '%s\n' "${value}" ;;
  esac
}

# sshd keeps the *first* value it obtains for a keyword, so a fragment that
# parses cleanly can still lose to the main configuration or to a fragment
# that sorts ahead of it; cloud-init's 50-cloud-init.conf turning password
# authentication back on is the usual way a host stays reachable by password
# after this toolkit has reported it hardened. Asking sshd what the assembled
# configuration resolves to is the only way to notice.
_sshd_candidate_takes_effect() {
  local binary=$1 candidate=$2 effective=$3
  local resolved line keyword value actual

  if ! resolved=$("${binary}" -T -f "${effective}" 2>/dev/null); then
    log_warn 'sshd would not resolve the effective configuration; its values were not verified'
    return 0
  fi

  while IFS= read -r line || [[ -n ${line} ]]; do
    line=${line#"${line%%[![:space:]]*}"}
    [[ -z ${line} || ${line} == '#'* ]] && continue
    keyword=${line%%[[:space:]]*}
    value=${line#"${keyword}"}
    value=${value#"${value%%[![:space:]]*}"}
    [[ -n ${value} ]] || continue
    keyword=${keyword,,}
    actual=$(awk -v k="${keyword}" \
      'tolower($1) == k { $1 = ""; sub(/^[[:space:]]+/, ""); print; exit }' \
      <<<"${resolved}")
    # Only keywords sshd reports back are checked; a repeated one such as
    # HostKey has no single effective value to compare against.
    [[ -n ${actual} ]] || continue
    # sshd reports some values under their canonical spelling rather than
    # the accepted synonym a file used: prohibit-password comes back as
    # without-password, and the booleans as yes and no.
    if [[ $(_sshd_canonical_value "${actual}") != "$(_sshd_canonical_value "${value}")" ]]; then
      log_error "sshd resolves ${keyword} to '${actual}' rather than the '${value}' this file asks for; something read earlier wins."
      return 1
    fi
  done <"${candidate}"
}

# Walks the Include graph of an sshd configuration and reports every
# directive it finds as `file US criteria US keyword US value`, with the
# criteria empty outside a conditional block. The unit separator is used
# rather than a tab because `read` would fold an empty field away between
# two whitespace delimiters. Includes are followed
# wherever they lead, not only into sshd_config.d: a policy file an
# operator includes by name is as much a part of this host's
# configuration as anything else, and a check that stops at the first
# Include is a check that can be stepped around.
#
# Relative Include paths resolve against /etc/ssh, as sshd resolves them,
# and everything is read beneath the sysroot so a test sees the tree it
# set up rather than the one this process is running on.
declare -gA _SSHD_SEEN=()
declare -g _SSHD_ROOT=''
declare -g _SSHD_LITERAL=''

# root is the sysroot every path is read beneath; literal names a prefix
# whose paths are already resolved (the scratch tree an assembled
# configuration lives in) and must not be rooted a second time.
_sshd_config_directives() {
  _SSHD_SEEN=()
  _SSHD_ROOT=${2-$(sysroot)}
  _SSHD_LITERAL=${3:-}
  _sshd_emit_directives "$1" ''
}

_sshd_resolve_include() {
  local operand=$1
  [[ ${operand} == /* ]] || operand="/etc/ssh/${operand}"
  if [[ -n ${_SSHD_LITERAL} && ${operand} == "${_SSHD_LITERAL}"* ]]; then
    printf '%s\n' "${operand}"
    return 0
  fi
  if [[ -n ${_SSHD_ROOT} && ${operand} == "${_SSHD_ROOT}"/* ]]; then
    printf '%s\n' "${operand}"
    return 0
  fi
  printf '%s\n' "${_SSHD_ROOT}${operand}"
}

_sshd_emit_directives() {
  local file=$1 criteria=$2
  [[ -r ${file} ]] || return 0

  local real
  real=$(readlink -f -- "${file}" 2>/dev/null) || real=${file}
  # A file read once globally and again under a Match says different
  # things each time, so the guard is against re-reading it in the same
  # context, not against reading it twice.
  [[ -n ${_SSHD_SEEN[${real}$'\x1f'${criteria}]+set} ]] && return 0
  _SSHD_SEEN[${real}$'\x1f'${criteria}]=1

  local line keyword value operand resolved target
  local -a operands=()
  while IFS= read -r line || [[ -n ${line} ]]; do
    line=${line#"${line%%[![:space:]]*}"}
    [[ -z ${line} || ${line} == '#'* ]] && continue
    keyword=${line%%[[:space:]]*}
    value=${line#"${keyword}"}
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    case ${keyword,,} in
      include)
        read -r -a operands <<<"${value}"
        for operand in ${operands[@]+"${operands[@]}"}; do
          resolved=$(_sshd_resolve_include "${operand}")
          # Word splitting and globbing are what resolve the pattern sshd
          # would resolve; the operand came from a configuration file this
          # host already reads.
          for target in ${resolved}; do
            [[ -f ${target} ]] || continue
            _sshd_emit_directives "${target}" "${criteria}"
          done
        done
        ;;
      match)
        # `Match all` returns to the unconditional part of the file.
        if [[ ${value,,} == all ]]; then
          criteria=''
        else
          criteria=${value}
        fi
        ;;
      *)
        [[ -n ${value} ]] || continue
        printf '%s\x1f%s\x1f%s\x1f%s\n' "${file}" "${criteria}" "${keyword,,}" "${value}"
        ;;
    esac
  done <"${file}"
}

# `sshd -T` reports the configuration as it resolves for no particular
# connection, so a Match block is never entered and its overrides are
# invisible to the check above. A `Match User alice` that turns password
# authentication back on would leave this host taking passwords for alice
# while the global dump agreed with the candidate in every respect.
#
# Rather than guess which contexts matter, any conditional setting that
# disagrees with the candidate is refused: the operator is asked to resolve
# the contradiction instead of being told the host is hardened when part of
# it is not.
_sshd_conditional_overrides() {
  local candidate=$1 main=$2

  local -A wanted=()
  local line keyword value
  while IFS= read -r line || [[ -n ${line} ]]; do
    line=${line#"${line%%[![:space:]]*}"}
    [[ -z ${line} || ${line} == '#'* ]] && continue
    keyword=${line%%[[:space:]]*}
    value=${line#"${keyword}"}
    value=${value#"${value%%[![:space:]]*}"}
    [[ -n ${value} ]] || continue
    wanted[$(_sshd_canonical_keyword "${keyword}")]=$(_sshd_canonical_value "${value}")
  done <"${candidate}"
  [[ ${#wanted[@]} -gt 0 ]] || return 0
  [[ -f ${main} ]] || return 0

  local criteria file
  while IFS=$'\x1f' read -r file criteria keyword value; do
    [[ -n ${criteria} ]] || continue
    keyword=$(_sshd_canonical_keyword "${keyword}")
    [[ -n ${wanted[${keyword}]+set} ]] || continue
    [[ $(_sshd_canonical_value "${value}") == "${wanted[${keyword}]}" ]] && continue
    log_error "${file} sets ${keyword} to '${value}' under 'Match ${criteria}', contradicting this file; resolve that before hardening."
    return 1
  done < <(_sshd_config_directives "${main}" "$(sysroot)" "$(dirname -- "${main}")")
}

# --- who an sshd configuration will admit ---------------------------------
#
# AllowUsers, DenyUsers, AllowGroups and DenyGroups decide who sshd will
# even talk to, before any key is considered. A host or a container that
# admits only root would reject every administrator configured here, and
# disabling password authentication on top of that leaves nobody able to
# log in at all.
#
# Both checks report a reason rather than dying, because phase 1 hardens
# the host and lib/guest-admin.sh hardens a container: the same question
# is asked of two configurations with two different consequences, and the
# answer must not depend on which one is asking.
#
# display_root is stripped from the paths named in a reason, so a
# container's configuration -- which is examined through a copy on this
# host -- is reported under the path the container knows it by.
_ssh_name_matches() {
  local name=$1 pattern=$2
  # A pattern may be qualified with the host it applies from; the account
  # it admits is the part before the '@'.
  pattern=${pattern%%@*}
  [[ -n ${pattern} ]] || return 1
  # shellcheck disable=SC2053 # the pattern is one, and matching it is the point
  [[ ${name} == ${pattern} ]]
}

# sshd only reads ~/.ssh/authorized_keys because that is the default; a
# configuration that names somewhere else, or `none`, ignores every key
# installed for an administrator. Disabling passwords on top of that
# removes the last way in.
sshd_authorized_keys_problem() {
  local main=$1 root=$2 literal=$3 display_root=$4
  [[ -f ${main} ]] || return 0

  local file criteria keyword value operand ok
  while IFS=$'\x1f' read -r file criteria keyword value; do
    [[ ${keyword} == authorizedkeysfile ]] || continue
    ok=0
    for operand in ${value}; do
      operand=${operand#'%h/'}
      [[ ${operand} == '.ssh/authorized_keys' ]] && ok=1
    done
    [[ ${ok} -eq 1 ]] && continue
    [[ -n ${display_root} ]] && file=${file#"${display_root}"}
    if [[ -n ${criteria} ]]; then
      printf "%s sets AuthorizedKeysFile to '%s' under 'Match %s', so the keys installed for the administrators would be ignored.\n" \
        "${file}" "${value}" "${criteria}"
    else
      printf "%s sets AuthorizedKeysFile to '%s', so the keys installed for the administrators would be ignored.\n" \
        "${file}" "${value}"
    fi
    return 1
  done < <(_sshd_config_directives "${main}" "${root}" "${literal}")
  return 0
}

# Why this configuration would not let one of these administrators in, or
# nothing when it would let all of them in.
#
# The administrators are given as pairs: a username, then the groups that
# account belongs to as a comma separated list. The groups come from the
# database of whichever system is being hardened, so a container is judged
# by its own group file rather than by the host's.
sshd_admission_problem() {
  local main=$1 root=$2 literal=$3 display_root=$4
  shift 4
  [[ -f ${main} ]] || return 0

  local display=${main}
  [[ -n ${display_root} ]] && display=${display#"${display_root}"}

  local -a allow_users=() deny_users=() allow_groups=() deny_groups=()
  local file criteria keyword value
  local -a more=()
  # sshd accumulates every occurrence of these keywords rather than
  # letting the first one win, so each directive adds to the list.
  while IFS=$'\x1f' read -r file criteria keyword value; do
    [[ -n ${criteria} ]] && continue
    read -r -a more <<<"${value}"
    case ${keyword} in
      allowusers) allow_users+=(${more[@]+"${more[@]}"}) ;;
      denyusers) deny_users+=(${more[@]+"${more[@]}"}) ;;
      allowgroups) allow_groups+=(${more[@]+"${more[@]}"}) ;;
      denygroups) deny_groups+=(${more[@]+"${more[@]}"}) ;;
    esac
  done < <(_sshd_config_directives "${main}" "${root}" "${literal}")

  local user pattern group admitted
  local -a groups=()
  while [[ $# -gt 0 ]]; do
    user=$1
    IFS=',' read -r -a groups <<<"${2:-}"
    shift 2

    for pattern in ${deny_users[@]+"${deny_users[@]}"}; do
      if _ssh_name_matches "${user}" "${pattern}"; then
        printf "%s denies %s with 'DenyUsers %s', so hardening would leave them unable to log in.\n" \
          "${display}" "${user}" "${pattern}"
        return 1
      fi
    done
    if [[ ${#allow_users[@]} -gt 0 ]]; then
      admitted=0
      for pattern in "${allow_users[@]}"; do
        _ssh_name_matches "${user}" "${pattern}" && admitted=1
      done
      if [[ ${admitted} -ne 1 ]]; then
        printf "%s admits only '%s', which does not include %s; hardening would leave them unable to log in.\n" \
          "${display}" "${allow_users[*]}" "${user}"
        return 1
      fi
    fi

    [[ ${#deny_groups[@]} -gt 0 || ${#allow_groups[@]} -gt 0 ]] || continue
    for pattern in ${deny_groups[@]+"${deny_groups[@]}"}; do
      for group in ${groups[@]+"${groups[@]}"}; do
        if _ssh_name_matches "${group}" "${pattern}"; then
          printf "%s denies %s's group %s with 'DenyGroups %s', so hardening would leave them unable to log in.\n" \
            "${display}" "${user}" "${group}" "${pattern}"
          return 1
        fi
      done
    done
    if [[ ${#allow_groups[@]} -gt 0 ]]; then
      admitted=0
      for pattern in "${allow_groups[@]}"; do
        for group in ${groups[@]+"${groups[@]}"}; do
          _ssh_name_matches "${group}" "${pattern}" && admitted=1
        done
      done
      if [[ ${admitted} -ne 1 ]]; then
        printf "%s admits only the groups '%s', none of which %s is in; hardening would leave them unable to log in.\n" \
          "${display}" "${allow_groups[*]}" "${user}"
        return 1
      fi
    fi
  done
  return 0
}

# Validators receive the candidate and the path it is destined for, and
# return non-zero when installing it would be a mistake. They never read the
# installed file, so a dry run checks exactly what a real run would write.
validate_sshd_config() {
  local candidate=$1 target=${2:-$1}
  local binary effective output

  binary=$(_sshd_binary) || {
    _validator_missing sshd 'sshd configuration'
    return
  }

  effective=$(_sshd_effective_config "${candidate}" "${target}" "$(dirname -- "${candidate}")") ||
    {
      log_error 'Unable to assemble the effective sshd configuration'
      return 1
    }

  log_info "checking the effective sshd configuration for ${target}"
  if ! output=$("${binary}" -t -f "${effective}" 2>&1); then
    # Off a real host, and as an ordinary user, sshd gets as far as loading
    # host keys and stops there. The configuration itself parsed, which is
    # the only thing being asked.
    #
    # Matched as the whole diagnostic rather than as a substring: a run that
    # also reported a real problem must not be waved through because this
    # line happened to appear in it. sshd ends the line with CR, hence the
    # trailing whitespace allowance.
    if [[ ${output} =~ ^[[:alnum:]_./-]*sshd:\ no\ hostkeys\ available\ --\ exiting\.[[:space:]]*$ ]]; then
      log_warn 'sshd found no host keys; the configuration itself parsed cleanly'
    else
      log_error "${output}"
      return 1
    fi
  fi

  _sshd_candidate_takes_effect "${binary}" "${candidate}" "${effective}" || return 1
  # The assembled configuration, not the installed one: a managed fragment
  # that drifted into a conflicting Match block is replaced by the
  # candidate, and rereading the obsolete file would refuse the repair.
  _sshd_conditional_overrides "${candidate}" "${effective}"
}

validate_sudoers_file() {
  local candidate=$1 target=${2:-$1}
  command -v visudo >/dev/null 2>&1 || {
    _validator_missing visudo 'sudoers file'
    return
  }
  log_info "checking the sudoers candidate for ${target}"
  run_check visudo -c -f "${candidate}" >&2
}

# ifupdown2 will refuse a description it cannot parse, and it refuses it at
# the point the interfaces are being reconfigured -- which on a remote host
# is after they have gone down. Parsing it first moves the refusal to a
# point where nothing has changed yet.
#
# `--syntax-check` belongs to ifreload; ifquery's `-s` is `--syntax-help`
# and parses nothing. ifreload is therefore asked first, and ifquery's
# documented parse-and-dump is the fallback for a build whose ifreload
# will not take an alternate interfaces file.
validate_interfaces_file() {
  local candidate=$1 target=${2:-$1}
  local output

  if command -v ifreload >/dev/null 2>&1; then
    log_info "checking the network interfaces candidate for ${target}"
    if output=$(ifreload --syntax-check -a -i "${candidate}" 2>&1); then
      [[ -n ${output} ]] && printf '%s\n' "${output}" >&2
      return 0
    fi
    if [[ ${output} != *'unrecognized arguments'* && ${output} != *'unrecognized option'* ]]; then
      printf '%s\n' "${output}" >&2
      return 1
    fi
    log_warn 'ifreload will not read an alternate interfaces file; parsing with ifquery instead'
  fi

  command -v ifquery >/dev/null 2>&1 || {
    _validator_missing ifreload 'network interfaces file'
    return
  }
  log_info "parsing the network interfaces candidate for ${target}"
  run_check ifquery -a -i "${candidate}" >&2
}

# Writes the candidate into a directory only root can reach, hands it to a
# validator, and installs it only once the validator is happy. A malformed
# sshd or sudoers file locks the operator out of a remote host, so this is
# the only way either is ever written.
#
# Validation runs during a dry run too, and leaves nothing behind on either
# path: the scratch directory is removed before this returns.
# Dies unless the validator accepts this content as the file at path.
#
# Separate from the install so that a file destined for a container is
# checked by exactly the tools and the reasoning the host's copy is: the
# candidate is prepared and validated here either way, and only where it
# is finally written differs.
assert_candidate_valid() {
  local path=$1 content=$2 mode=$3 validator=$4
  declare -F "${validator}" >/dev/null 2>&1 ||
    die "assert_candidate_valid: no such validator '${validator}'"

  local dir status=0
  dir=$(_validation_dir) || die "Unable to create a validation directory for ${path}"

  # The candidate is prepared and checked inside a subshell so that the
  # cleanup trap belongs to it. A trap set here would have to displace
  # whatever the caller had installed, and a stage that is holding a
  # rollback trap of its own cannot afford to have it dropped.
  (
    trap 'rm -rf -- "${dir}"' EXIT HUP INT TERM
    candidate="${dir}/$(basename -- "${path}")"
    printf '%s' "${content}" >"${candidate}" || exit 2
    chmod -- "${mode}" "${candidate}" || exit 2
    "${validator}" "${candidate}" "${path}" || exit 3
  ) || status=$?
  rm -rf -- "${dir}"

  [[ ${status} -ne 2 ]] || die "Unable to prepare the candidate for ${path}"
  [[ ${status} -eq 0 ]] ||
    die "Refusing to install ${path}: the candidate failed validation"
}

install_validated() {
  local path=$1 content=$2 mode=$3 validator=$4
  _refuse_symlink "${path}"
  assert_candidate_valid "${path}" "${content}" "${mode}" "${validator}"
  write_file "${path}" "${content}" "${mode}"
}
