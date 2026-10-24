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
write_file() {
  local path=$1 content=$2 mode=${3:-}
  _refuse_symlink "${path}"

  local changed=0
  if [[ -f ${path} ]]; then
    if ! printf '%s' "${content}" | cmp -s - "${path}"; then
      changed=1
    fi
    if [[ -n ${mode} ]] && ! _mode_matches "${path}" "${mode}"; then
      changed=1
    fi
  else
    changed=1
  fi

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
backup_file() {
  local path=$1
  local backup="${path}.pve-config.bak"
  if [[ ! -f ${path} ]] || [[ -e ${backup} ]]; then
    printf 'unchanged\n'
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
