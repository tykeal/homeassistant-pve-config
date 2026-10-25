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

# Appends a line only when an equivalent one is absent. Comparison collapses
# whitespace runs and is literal throughout, so regex metacharacters match
# as themselves and a commented out variant does not count as present. This
# is what stops a repeated run stacking duplicate PAM entries.
ensure_line_in_file() {
  local path=$1 line=$2 position=${3:-append}
  local want existing
  want=$(_squash_ws "${line}")

  if [[ -f ${path} ]]; then
    while IFS= read -r existing || [[ -n ${existing} ]]; do
      if [[ $(_squash_ws "${existing}") == "${want}" ]]; then
        printf 'unchanged\n'
        return 0
      fi
    done <"${path}"
  fi

  if dry_run_enabled; then
    log_info "would add line to ${path}: $(redact "${line}")"
    printf 'changed\n'
    return 0
  fi

  _refuse_symlink "${path}"

  local body=''
  _slurp body "${path}"

  local updated
  case ${position} in
    prepend)
      updated="${line}"$'\n'"${body}"
      ;;
    append)
      if [[ -n ${body} && ${body} != *$'\n' ]]; then
        updated="${body}"$'\n'"${line}"$'\n'
      else
        updated="${body}${line}"$'\n'
      fi
      ;;
    *) die "ensure_line_in_file: unknown position '${position}'" ;;
  esac

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
    if [[ $(ensure_owner "${path}" "${uid}" "${gid}") == changed ]]; then
      changed=1
    fi
  fi

  if [[ ${changed} -eq 1 ]]; then
    printf 'changed\n'
  else
    printf 'unchanged\n'
  fi
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

# Leaves exactly one active line matching a pattern, wherever the file had
# them before. ensure_line_in_file only appends when nothing matches, which
# is why a `sed -i '1a ...'` replacement needs this instead: the duplicates
# an earlier run left behind have to be removed, not merely not added to.
#
# Commented out variants are left alone, so an operator's note about why a
# line was disabled survives.
#
# position is append, prepend, or after-first, the last of which reproduces
# the placement a PAM stack expects without reproducing the duplication.
ensure_exact_line() {
  local path=$1 match=$2 line=$3 position=${4:-append}
  _refuse_symlink "${path}"

  local -a kept=()
  local existing
  if [[ -f ${path} ]]; then
    while IFS= read -r existing || [[ -n ${existing} ]]; do
      if ! _is_comment "${existing}" && [[ ${existing} =~ ${match} ]]; then
        continue
      fi
      kept+=("${existing}")
    done <"${path}"
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

  local rebuilt=''
  for existing in "${kept[@]}"; do
    rebuilt+="${existing}"$'\n'
  done

  local original=''
  _slurp original "${path}"
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

  local src="${root}/etc/ssh/sshd_config.d"
  if [[ -d ${src} ]]; then
    for existing in "${src}"/*.conf; do
      [[ -f ${existing} ]] || continue
      [[ $(basename -- "${existing}") == "${base}" ]] && continue
      cp -- "${existing}" "${conf_d}/" || return 1
    done
  fi
  cp -- "${candidate}" "${conf_d}/${base}" || return 1

  main="${dir}/sshd_config"
  local host_main="${root}/etc/ssh/sshd_config"
  if [[ -f ${host_main} ]]; then
    _slurp body "${host_main}"
    if [[ ${body} =~ (^|$'\n')[[:space:]]*[Ii]nclude[[:space:]] ]]; then
      body=$(printf '%s' "${body}" |
        sed -E "s|^([[:space:]]*[Ii]nclude[[:space:]]+).*sshd_config\.d/.*|\1${conf_d}/*.conf|")
      body+=$'\n'
    else
      log_warn "${host_main} has no Include line; $(basename -- "${target}") would never be read"
      body="Include ${conf_d}/*.conf"$'\n'"${body}"
    fi
  else
    body="Include ${conf_d}/*.conf"$'\n'
  fi

  printf '%s' "${body}" >"${main}" || return 1
  printf '%s\n' "${main}"
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
  if output=$("${binary}" -t -f "${effective}" 2>&1); then
    return 0
  fi

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
    return 0
  fi

  log_error "${output}"
  return 1
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
# is after they have gone down. Asking ifquery first moves the refusal to a
# point where nothing has changed yet.
validate_interfaces_file() {
  local candidate=$1 target=${2:-$1}
  command -v ifquery >/dev/null 2>&1 || {
    _validator_missing ifquery 'network interfaces file'
    return
  }
  log_info "checking the network interfaces candidate for ${target}"
  run_check ifquery --syntax-check -a -i "${candidate}" >&2
}

# Writes the candidate into a directory only root can reach, hands it to a
# validator, and installs it only once the validator is happy. A malformed
# sshd or sudoers file locks the operator out of a remote host, so this is
# the only way either is ever written.
#
# Validation runs during a dry run too, and leaves nothing behind on either
# path: the scratch directory is removed before this returns.
install_validated() {
  local path=$1 content=$2 mode=$3 validator=$4
  _refuse_symlink "${path}"
  declare -F "${validator}" >/dev/null 2>&1 ||
    die "install_validated: no such validator '${validator}'"

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

  write_file "${path}" "${content}" "${mode}"
}
