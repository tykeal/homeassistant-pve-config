#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
# SPDX-License-Identifier: Apache-2.0

# Configuration resolution. Values are resolved once, recorded, and written
# back out so that the second run of the toolkit needs no operator input.
#
# Config and secrets files are parsed, never sourced. A generated file still
# lives in the same directory as everything else on a host that other people
# touch, and `source` would hand it the shell.

_config_init() {
  [[ -n ${_CONFIG_INIT:-} ]] && return 0
  declare -gA _CONFIG_VALUES=()
  declare -gA _CONFIG_SECRET=()
  declare -ga _CONFIG_ORDER=()
  declare -gA _CONFIG_PARSED=()
  declare -ga _CONFIG_PARSED_ORDER=()
  declare -gA _CONFIG_IGNORE=()
  declare -gA _CONFIG_FROM_FILE=()
  _CONFIG_INIT=1
}

config_reset() {
  unset _CONFIG_INIT _CONFIG_VALUES _CONFIG_SECRET _CONFIG_ORDER
  unset _CONFIG_PARSED _CONFIG_PARSED_ORDER _CONFIG_IGNORE _CONFIG_FROM_FILE
  _config_init
}

_config_record() {
  local key=$1 value=$2
  _config_init
  if [[ -z ${_CONFIG_VALUES[${key}]+set} ]]; then
    _CONFIG_ORDER+=("${key}")
  fi
  _CONFIG_VALUES["${key}"]=${value}
  unset "_CONFIG_IGNORE[${key}]"
}

# Marks keys whose stored value must not be reused. --reconfigure needs the
# rest of the file preserved verbatim, so the value is still parsed and kept
# for config_save; it is simply not treated as an answer.
config_ignore_stored() {
  local key
  _config_init
  for key in "$@"; do
    _CONFIG_IGNORE["${key}"]=1
  done
}

_config_is_ignored() {
  _config_init
  [[ -n ${_CONFIG_IGNORE[$1]+set} ]]
}

# True when the value now in the environment was put there by a loaded
# file rather than exported by the caller. Loading exports what it reads,
# so this is the only way to tell the two apart afterwards.
config_value_from_file() {
  _config_init
  [[ -n ${_CONFIG_FROM_FILE[$1]+set} ]]
}

config_mark_secret() {
  local key
  _config_init
  for key in "$@"; do
    _CONFIG_SECRET["${key}"]=1
  done
}

config_is_secret() {
  _config_init
  [[ -n ${_CONFIG_SECRET[$1]+set} ]]
}

config_has() {
  local key=$1
  _config_init
  [[ -n ${!key+set} ]] && return 0
  _config_is_ignored "${key}" && return 1
  [[ -n ${_CONFIG_VALUES[${key}]+set} ]]
}

# Wraps a value in single quotes so that spaces, quotes, newlines and shell
# metacharacters survive a save/load round trip untouched.
_config_quote() {
  local value=$1
  printf "'%s'" "${value//\'/\'\\\'\'}"
}

# Decodes the single-quoted form _config_quote emits. Returns 0 with the
# value in _CONFIG_DECODED, 2 when the quoting runs past the end of the
# buffer (a multi-line value), and 1 when the text is not a valid literal.
_config_decode_single() {
  local raw=$1 out='' i=1 ch n
  n=${#raw}
  [[ ${raw} == \'* ]] || return 1
  while ((i < n)); do
    ch=${raw:i:1}
    if [[ ${ch} == "'" ]]; then
      # The only quote allowed inside is the shell's own escape, '\''.
      if [[ ${raw:i:4} == "'\\''" ]]; then
        out+="'"
        i=$((i + 4))
        continue
      fi
      ((i == n - 1)) || return 1
      _CONFIG_DECODED=${out}
      return 0
    fi
    out+=${ch}
    i=$((i + 1))
  done
  return 2
}

# Double quotes are accepted for hand-written files, but only as a literal:
# anything the shell would expand is rejected rather than interpreted.
_config_decode_double() {
  local raw=$1 inner n
  n=${#raw}
  [[ ${raw} == '"'* ]] || return 1
  if ((n < 2)) || [[ ${raw: -1} != '"' ]]; then
    return 2
  fi
  inner=${raw:1:n-2}
  case ${inner} in
    *'"'* | *'$'* | *'`'* | *\\*) return 1 ;;
  esac
  _CONFIG_DECODED=${inner}
  return 0
}

_config_ltrim() {
  local text=$1
  printf '%s' "${text#"${text%%[![:space:]]*}"}"
}

_config_rtrim() {
  local text=$1
  printf '%s' "${text%"${text##*[![:space:]]}"}"
}

# Names the shell itself acts on. None of them can match the toolkit
# namespace, so this list is pure defence in depth against a future change
# that loosens _config_key_is_loadable.
_CONFIG_DENIED_KEYS=(
  BASH_ENV ENV SHELLOPTS BASHOPTS PATH IFS CDPATH GLOBIGNORE PS4
  LD_PRELOAD LD_LIBRARY_PATH LD_AUDIT BASH_XTRACEFD BASH_FUNC
)

# A generated file is only ever allowed to set toolkit keys. Accepting any
# valid identifier would let a tampered config export BASH_ENV or PATH and
# so regain the code execution that parsing instead of sourcing removed.
#
# PVE_CONFIG_* is reserved as well: those name the directories the toolkit
# reads and writes, so a config that set them could point the driver at a
# private file and have its contents copied into a world readable one.
# They remain available as environment overrides, which only someone who
# can already run the driver can set.
_config_key_is_loadable() {
  local key=$1 denied
  [[ ${key} =~ ^PVE_[A-Z0-9_]+$ ]] || return 1
  [[ ${key} == PVE_CONFIG_* ]] && return 1
  for denied in "${_CONFIG_DENIED_KEYS[@]}"; do
    if [[ ${key} == "${denied}" ]]; then
      return 1
    fi
  done
  return 0
}

# Accepts a complete KEY=value assignment. Returns 0 on success with the key
# in _CONFIG_DECODED_KEY and the value in _CONFIG_DECODED, 2 when more input
# is needed to close a quote, and 1 when the text is not acceptable.
_config_decode_assignment() {
  local buffer=$1 key rest
  [[ ${buffer} == *=* ]] || return 1
  key=${buffer%%=*}
  rest=${buffer#*=}
  _config_key_is_loadable "${key}" || return 1

  # The calls sit in an if so that a non-zero status reports "needs more
  # input" instead of aborting a caller that runs under errexit.
  local rc=0
  case ${rest} in
    "'"*) _config_decode_single "${rest}" && rc=0 || rc=$? ;;
    '"'*) _config_decode_double "${rest}" && rc=0 || rc=$? ;;
    *) return 1 ;;
  esac
  [[ ${rc} -eq 0 ]] || return "${rc}"
  _CONFIG_DECODED_KEY=${key}
  return 0
}

# Parses a KEY=value file into _CONFIG_PARSED. Anything that is not a blank
# line, a comment, or a quoted literal assignment is a fatal error naming
# the file and the line, so a config file cannot smuggle in a command.
_config_parse_file() {
  local path=$1
  _config_init
  _CONFIG_PARSED=()
  _CONFIG_PARSED_ORDER=()

  local raw buffer='' trimmed lineno=0 start=0 rc
  while IFS= read -r raw || [[ -n ${raw} ]]; do
    lineno=$((lineno + 1))
    if [[ -n ${buffer} ]]; then
      buffer+=$'\n'"${raw}"
    else
      # Only the leading whitespace is dropped here. Trailing whitespace is
      # inside the value once a quote is open, so it is trimmed for the
      # decode attempt but never removed from the buffer itself.
      trimmed=$(_config_ltrim "${raw}")
      [[ -z ${trimmed} ]] && continue
      [[ ${trimmed} == '#'* ]] && continue
      buffer=${trimmed}
      start=${lineno}
    fi

    _config_decode_assignment "$(_config_rtrim "${buffer}")" && rc=0 || rc=$?
    case ${rc} in
      0)
        if [[ -z ${_CONFIG_PARSED[${_CONFIG_DECODED_KEY}]+set} ]]; then
          _CONFIG_PARSED_ORDER+=("${_CONFIG_DECODED_KEY}")
        fi
        _CONFIG_PARSED["${_CONFIG_DECODED_KEY}"]=${_CONFIG_DECODED}
        buffer=''
        ;;
      2) continue ;;
      *)
        die "${path}:${start}: expected PVE_KEY='value'; refusing to interpret this line"
        ;;
    esac
  done <"${path}"

  [[ -z ${buffer} ]] || die "${path}:${start}: quoted value is never closed"
}

# Loads a KEY=value file. A variable that is already set in the environment
# wins, including when it is set to the empty string: an explicit export is
# a deliberate override and must beat the file a previous run generated.
config_load() {
  local path=$1
  _config_init
  [[ -f ${path} ]] || return 0

  _config_parse_file "${path}"

  local key
  for key in ${_CONFIG_PARSED_ORDER[@]+"${_CONFIG_PARSED_ORDER[@]}"}; do
    # An ignored key keeps its stored value so config_save round trips the
    # file, but it is not exported: it has to be answered again.
    if _config_is_ignored "${key}" && [[ -z ${!key+set} ]]; then
      if [[ -z ${_CONFIG_VALUES[${key}]+set} ]]; then
        _CONFIG_ORDER+=("${key}")
      fi
      _CONFIG_VALUES["${key}"]=${_CONFIG_PARSED[${key}]}
      continue
    fi
    if [[ -z ${!key+set} ]]; then
      printf -v "${key}" '%s' "${_CONFIG_PARSED[${key}]}"
      _CONFIG_FROM_FILE["${key}"]=1
    fi
    export "${key?}"
    _config_record "${key}" "${!key}"
  done
}

# Assigns a value directly, as if it had been resolved.
config_set() {
  local key=$1 value=$2
  _config_init
  printf -v "${key}" '%s' "${value}"
  export "${key?}"
  _config_record "${key}" "${value}"
}

# Resolves one value: environment override, then loaded config, then a
# prompt pre-filled with the derived default, then the default itself.
config_get() {
  local key=$1 default=${2:-} prompt=${3:-${1}}
  _config_init

  local value=''
  if [[ -n ${!key+set} ]]; then
    value=${!key}
  elif ! _config_is_ignored "${key}" && [[ -n ${_CONFIG_VALUES[${key}]+set} ]]; then
    value=${_CONFIG_VALUES[${key}]}
  elif [[ ${NON_INTERACTIVE:-0} == 1 ]]; then
    [[ -n ${default} ]] ||
      die "${key} is not set and has no default; set it in the config file or the environment."
    value=${default}
  elif [[ -t 0 ]]; then
    read -r -e -i "${default}" -p "${prompt}: " value || value=${default}
  else
    read -r -p "${prompt} [${default}]: " value || value=${default}
    value=${value:-${default}}
  fi

  printf -v "${key}" '%s' "${value}"
  export "${key?}"
  _config_record "${key}" "${value}"
  printf '%s\n' "${value}"
}

# Leaves the file body in _CONFIG_SERIALISED rather than printing it, so a
# value ending in a newline is not silently trimmed by command substitution.
_config_serialise() {
  local body=$1 key
  shift
  for key in "$@"; do
    body+="${key}=$(_config_quote "${_CONFIG_VALUES[${key}]}")"$'\n'
  done
  _CONFIG_SERIALISED=${body}
}

# Writes the resolved values back as a parseable file. Secrets are skipped
# on purpose: they belong in the chmod 600 secrets file only.
config_save() {
  local path=$1
  _config_init

  local header
  header=$'# Generated by pve-config. Edit by hand if you need to; the\n'
  header+=$'# toolkit rewrites this file on every run and keeps the values\n'
  header+=$'# it already knows. Secrets live in secrets.env, never here.\n\n'

  local -a keys=()
  local key
  for key in ${_CONFIG_ORDER[@]+"${_CONFIG_ORDER[@]}"}; do
    if ! config_is_secret "${key}"; then
      keys+=("${key}")
    fi
  done

  _config_serialise "${header}" ${keys[@]+"${keys[@]}"}
  write_file "${path}" "${_CONFIG_SERIALISED}" 0644
}

# Writes the resolved secrets at 0600. Keeping this separate from
# config_save is what guarantees a credential can never land in the
# world-readable file.
secrets_save() {
  local path=$1
  _config_init

  local -a keys=()
  local key
  for key in ${_CONFIG_ORDER[@]+"${_CONFIG_ORDER[@]}"}; do
    if config_is_secret "${key}"; then
      keys+=("${key}")
    fi
  done

  if [[ ${#keys[@]} -eq 0 ]]; then
    printf 'unchanged\n'
    return 0
  fi

  local header
  header=$'# Generated by pve-config. Mode 0600, never committed.\n\n'

  xtrace_suspend
  local result
  _config_serialise "${header}" "${keys[@]}"
  result=$(write_file "${path}" "${_CONFIG_SERIALISED}" 0600)
  xtrace_resume
  printf '%s\n' "${result}"
}

# Refuses to read a secrets file that anyone but its owner can reach, and
# refuses to follow a symlink into one.
_secrets_check_path() {
  local path=$1 mode owner

  if [[ -L ${path} ]]; then
    die "${path} is a symlink; refusing to read secrets through it."
  fi
  if [[ ! -f ${path} ]]; then
    die "${path} is not a regular file; refusing to read secrets from it."
  fi

  mode=$(stat -c '%a' -- "${path}" 2>/dev/null) ||
    die "Unable to determine the permissions of ${path}."
  if ((8#${mode} & 8#077)); then
    die "${path} is mode ${mode}; it holds secrets and must be 600."
  fi

  if [[ ${EUID} -eq 0 ]]; then
    owner=$(stat -c '%u' -- "${path}" 2>/dev/null) || owner=''
    [[ ${owner} == '0' ]] ||
      die "${path} is owned by uid ${owner:-unknown}; it must be owned by root."
  fi
}

# Loads the secrets file. Keys are tracked so config_save can never leak one
# into the world-readable config, and their values are registered for
# redaction so run_cmd cannot print them.
secrets_load() {
  local path=$1
  _config_init
  [[ -e ${path} || -L ${path} ]] || return 0

  _secrets_check_path "${path}"

  xtrace_suspend
  _config_parse_file "${path}"

  local key
  for key in ${_CONFIG_PARSED_ORDER[@]+"${_CONFIG_PARSED_ORDER[@]}"}; do
    config_mark_secret "${key}"
    if _config_is_ignored "${key}" && [[ -z ${!key+set} ]]; then
      if [[ -z ${_CONFIG_VALUES[${key}]+set} ]]; then
        _CONFIG_ORDER+=("${key}")
      fi
      _CONFIG_VALUES["${key}"]=${_CONFIG_PARSED[${key}]}
      continue
    fi
    if [[ -z ${!key+set} ]]; then
      printf -v "${key}" '%s' "${_CONFIG_PARSED[${key}]}"
      _CONFIG_FROM_FILE["${key}"]=1
    fi
    export "${key?}"
    _config_record "${key}" "${!key}"
    redact_register "${!key}"
  done
  xtrace_resume
}

# Fails loudly when a required secret is missing, without ever printing the
# value of one that is present.
secrets_require() {
  local key
  _config_init
  for key in "$@"; do
    config_mark_secret "${key}"
    [[ -n ${!key:-} ]] || die "${key} is required but unset; add it to secrets.env."
    # A credential supplied purely through the environment never passed
    # through secrets_load, so this is the only chance to mask it.
    redact_register "${!key}"
  done
}

# The names the driver hands to its children so they can rebuild the
# redaction registry from the environment.
config_secret_keys() {
  _config_init
  local key
  local -a names=()
  for key in ${_CONFIG_ORDER[@]+"${_CONFIG_ORDER[@]}"}; do
    if config_is_secret "${key}"; then
      names+=("${key}")
    fi
  done
  printf '%s' "${names[*]-}"
}
