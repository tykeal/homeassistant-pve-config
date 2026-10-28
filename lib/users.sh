#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
# SPDX-License-Identifier: Apache-2.0

# System account convergence.
#
# The account database is read out of the passwd and group files rather than
# through getent. Proxmox administrators are local accounts by definition,
# and reading the files directly is what lets the whole of this module be
# exercised against a scratch tree.

_users_passwd_file() {
  printf '%s\n' "${PVE_CONFIG_PASSWD:-$(sysroot)/etc/passwd}"
}

_users_group_file() {
  printf '%s\n' "${PVE_CONFIG_GROUP:-$(sysroot)/etc/group}"
}

# The passwd and group databases are parsed from their contents rather than
# from a path, so a container's copy -- which is read out through pct -- is
# understood by exactly the same code as the host's.
_passwd_field_from_body() {
  local body=$1 name=$2 field=$3 value
  value=$(awk -F: -v want="${name}" -v f="${field}" \
    '$1 == want { print $f; exit }' <<<"${body}" 2>/dev/null) || return 1
  [[ -n ${value} ]] || return 1
  printf '%s\n' "${value}"
}

# Supplementary membership only. A primary group is set when the account is
# created and is not what `usermod -aG` manages.
_group_has_member() {
  local body=$1 group=$2 name=$3 members member
  members=$(awk -F: -v g="${group}" '$1 == g { print $4; exit }' \
    <<<"${body}" 2>/dev/null) || return 1
  [[ -n ${members} ]] || return 1
  local -a list=()
  IFS=',' read -r -a list <<<"${members}"
  for member in ${list[@]+"${list[@]}"}; do
    [[ ${member} == "${name}" ]] && return 0
  done
  return 1
}

_users_field() {
  local name=$1 field=$2 body=''
  _slurp body "$(_users_passwd_file)"
  _passwd_field_from_body "${body}" "${name}" "${field}"
}

user_exists() {
  _users_field "$1" 1 >/dev/null 2>&1
}

user_uid() { _users_field "$1" 3; }
user_gid() { _users_field "$1" 4; }
user_shell() { _users_field "$1" 7; }

# The home directory as the passwd database records it, which is a path on
# the host rather than in the scratch tree. Callers prefix it themselves.
user_home() { _users_field "$1" 6; }

# Creates the account when it is absent and otherwise converges the login
# shell. The script this replaces called `useradd -m` unconditionally, which
# failed on every re-run once the account existed.
user_converge() {
  local name=$1 shell=${2:-/bin/bash} current

  if ! user_exists "${name}"; then
    run_cmd useradd -m -s "${shell}" "${name}" ||
      die "Unable to create the user ${name}"
    printf 'changed\n'
    return 0
  fi

  current=$(user_shell "${name}") || current=''
  if [[ ${current} != "${shell}" ]]; then
    run_cmd usermod -s "${shell}" "${name}" ||
      die "Unable to set the login shell of ${name}"
    printf 'changed\n'
    return 0
  fi

  printf 'unchanged\n'
}

user_in_group() {
  local name=$1 group=$2 body=''
  _slurp body "$(_users_group_file)"
  _group_has_member "${body}" "${group}" "${name}"
}

# Every group the account belongs to: the primary one named by its passwd
# entry, and each group that lists it as a member.
#
# Parsed from the contents of a group database rather than from a path, so
# a container's copy -- which is read out through pct -- is understood by
# exactly the same code as the host's.
_groups_from_body() {
  local body=$1 name=$2 gid=$3
  awk -F: -v n="${name}" -v g="${gid}" '
    $3 == g && g != "" { print $1; next }
    {
      split($4, members, ",")
      for (i in members) {
        if (members[i] == n) {
          print $1
          next
        }
      }
    }
  ' <<<"${body}" 2>/dev/null
}

user_groups() {
  local name=$1 gid body=''
  gid=$(user_gid "${name}") || gid=''
  _slurp body "$(_users_group_file)"
  _groups_from_body "${body}" "${name}" "${gid}"
}

user_join_group() {
  local name=$1 group changed=0
  shift
  for group in "$@"; do
    user_in_group "${name}" "${group}" && continue
    run_cmd usermod -aG "${group}" "${name}" ||
      die "Unable to add ${name} to the ${group} group"
    changed=1
  done

  if [[ ${changed} -eq 1 ]]; then
    printf 'changed\n'
  else
    printf 'unchanged\n'
  fi
}

# The identifying part of an authorized_keys entry: the algorithm and the
# blob, without the trailing comment. Two entries that differ only in their
# comment are the same key and must not both be installed.
#
# This is a shape test, not a validity test. Nothing is installed on the
# strength of it alone; see ssh_key_is_valid.
# The option list an authorized_keys entry carries, which is everything
# before the algorithm token.
_ssh_key_options() {
  local line=$1 field
  local -a fields=()
  read -r -a fields <<<"${line}"
  local -a opts=()
  for field in ${fields[@]+"${fields[@]}"}; do
    case ${field} in
      ssh-* | ecdsa-* | sk-ssh-* | sk-ecdsa-*) break ;;
      *) opts+=("${field}") ;;
    esac
  done
  printf '%s\n' "${opts[*]-}"
}

# Whether an entry would let an administrator log in from anywhere and get
# a shell. Source restrictions and forced commands may well be deliberate,
# but they are not something this toolkit can verify remote access through.
ssh_key_entry_is_unrestricted() {
  local opts
  opts=$(_ssh_key_options "$1")
  [[ -n ${opts} ]] || return 0
  case ",${opts,,}," in
    *from=* | *command=* | *restrict* | *no-pty*) return 1 ;;
  esac
  return 0
}

_ssh_key_identity() {
  local line=$1 field
  local -a fields=()
  read -r -a fields <<<"${line}"
  local i=0
  for field in ${fields[@]+"${fields[@]}"}; do
    case ${field} in
      ssh-* | ecdsa-* | sk-ssh-* | sk-ecdsa-*)
        if [[ -n ${fields[i + 1]:-} ]]; then
          printf '%s %s\n' "${field}" "${fields[i + 1]}"
          return 0
        fi
        ;;
    esac
    i=$((i + 1))
  done
  return 1
}

# Hands the key to ssh-keygen, which is the only thing that agrees with
# sshd about what a public key is. A key that merely looks like one -- the
# right algorithm token in front of truncated base64 -- is accepted
# everywhere else in this file and rejected by sshd, and installing one
# before password authentication is turned off locks everybody out.
#
# The key goes in on stdin, so no candidate file is created anywhere.
ssh_key_is_valid() {
  local key=$1
  command -v ssh-keygen >/dev/null 2>&1 ||
    die 'ssh-keygen is not installed; refusing to install an unverified SSH key.'
  printf '%s\n' "${key}" | ssh-keygen -l -f /dev/stdin >/dev/null 2>&1
}

_ssh_keys_normalise() {
  local text=$1 line
  while IFS= read -r line || [[ -n ${line} ]]; do
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [[ -n ${line} ]] || continue
    [[ ${line} == '#'* ]] && continue
    printf '%s\n' "${line}"
  done <<<"${text}"
}

# Why these keys would not get this administrator in through the given
# authorized_keys body, or nothing when they all would.
#
# Reported rather than fatal, because the host hardens itself and
# lib/guest-admin.sh hardens a container: the same question is asked of
# two systems, and the answer must not depend on which one is asking.
# Judged on contents rather than on a path for the same reason -- a
# container's file is read out through pct and never opened here.
authorized_keys_access_problem() {
  local body=$1 keys=$2 user=$3 file=$4 remedy=$5
  local -A active=() unrestricted=()
  local entry identity key

  # Active entries only. A commented out key is not one sshd would
  # accept, and taking it for one would disable passwords behind a login
  # nobody has.
  while IFS= read -r entry || [[ -n ${entry} ]]; do
    _is_comment "${entry}" && continue
    identity=$(_ssh_key_identity "${entry}") || continue
    active["${identity}"]=1
    # An entry carrying from= or a forced command may be deliberate, but
    # it is not one this toolkit can call a working remote login, and
    # rewriting someone else's restriction is not ours to do either.
    ssh_key_entry_is_unrestricted "${entry}" && unrestricted["${identity}"]=1
  done <<<"${body}"

  while IFS= read -r key || [[ -n ${key} ]]; do
    [[ -n ${key} ]] || continue
    key=$(_ssh_key_identity "${key}") || continue
    if [[ -z ${active[${key}]+set} ]]; then
      printf "%s's configured key is not active in %s; %s.\n" \
        "${user}" "${file}" "${remedy}"
      return 1
    fi
    if [[ -z ${unrestricted[${key}]+set} ]]; then
      printf "%s's only entry for that key in %s carries restrictions (from=, command=, restrict or no-pty) that this toolkit cannot verify remote logins through; add an unrestricted entry or relax the restriction before hardening SSH.\n" \
        "${user}" "${file}"
      return 1
    fi
  done <<<"${keys}"
  return 0
}

# The authorized_keys body that holds everything the file already had plus
# every wanted key that is not in it yet, assigned to the named variable.
#
# A key is installed only once ssh-keygen has accepted it, and an entry
# already present is matched on its identity rather than on its text, so a
# key whose comment changed is not added a second time. Both targets merge
# through this, so a container's file cannot drift away from the rule the
# host's follows.
_authorized_keys_merged() {
  local __var=$1 __body=$2 __keys=$3 __who=$4
  local __merged='' __line __identity
  local -A __seen=()

  if [[ -n ${__body} ]]; then
    while IFS= read -r __line || [[ -n ${__line} ]]; do
      __merged+="${__line}"$'\n'
      # A commented out key is kept, but it is not an active entry:
      # counting it as one would suppress the real key and leave the
      # administrator without a usable login once passwords are disabled.
      _is_comment "${__line}" && continue
      __identity=$(_ssh_key_identity "${__line}") || continue
      __seen["${__identity}"]=1
    done <<<"${__body%$'\n'}"
  fi

  while IFS= read -r __line || [[ -n ${__line} ]]; do
    [[ -n ${__line} ]] || continue
    __identity=$(_ssh_key_identity "${__line}") ||
      die "Not an SSH public key: ${__line}"
    ssh_key_is_valid "${__line}" ||
      die "ssh-keygen rejects this key for ${__who}: ${__line}"
    [[ -n ${__seen[${__identity}]+set} ]] && continue
    __seen["${__identity}"]=1
    __merged+="${__line}"$'\n'
  done < <(_ssh_keys_normalise "${__keys}")

  printf -v "${__var}" '%s' "${__merged}"
}

# Merges keys into a user's authorized_keys without ever duplicating one,
# and leaves the directory and file with the ownership and permissions sshd
# insists on before it will read them.
authorized_keys_install() {
  local user=$1 keys=$2
  local home ssh_dir file uid gid changed=0

  uid=$(user_uid "${user}") || uid=''
  gid=$(user_gid "${user}") || gid=''
  home=$(user_home "${user}") || home="/home/${user}"
  home="$(sysroot)${home}"
  ssh_dir="${home}/.ssh"
  file="${ssh_dir}/authorized_keys"

  local state
  state_of state ensure_dir "${home}" '' "${uid}" "${gid}"
  if [[ ${state} == changed ]]; then
    changed=1
  fi
  # StrictModes, which is on by default, makes sshd ignore authorized_keys
  # under a home anybody else can write to. The mode is otherwise left as
  # the operator set it: only the bits that cost the administrator their
  # login are cleared.
  state_of state ensure_not_group_other_writable "${home}"
  if [[ ${state} == changed ]]; then
    changed=1
  fi
  state_of state ensure_dir "${ssh_dir}" 0700 "${uid}" "${gid}"
  if [[ ${state} == changed ]]; then
    changed=1
  fi

  local existing='' merged
  [[ -f ${file} ]] && _slurp existing "${file}"
  _authorized_keys_merged merged "${existing}" "${keys}" "${user}"

  state_of state write_file "${file}" "${merged}" 0600
  if [[ ${state} == changed ]]; then
    changed=1
  fi
  if [[ -n ${uid} && -n ${gid} ]] && [[ -f ${file} ]]; then
    state_of state ensure_owner "${file}" "${uid}" "${gid}"
    if [[ ${state} == changed ]]; then
      changed=1
    fi
  fi

  if [[ ${changed} -eq 1 ]]; then
    printf 'changed\n'
  else
    printf 'unchanged\n'
  fi
}

# A key source is either the key itself or a path to a file holding one or
# more. Both forms exist because a literal keeps the deployment in one file
# while a path keeps a 700-character RSA key out of it.
admin_key_source_resolve() {
  local source=$1 body
  [[ -n ${source} ]] || return 1

  if _ssh_key_identity "${source}" >/dev/null 2>&1 || [[ ${source} == *$'\n'* ]]; then
    printf '%s\n' "${source}"
    return 0
  fi

  local path=${source}
  [[ ${path} == /* ]] && path="$(sysroot)${path}"
  [[ -f ${path} ]] || die "Admin key source is neither a public key nor a readable file: ${source}"
  _slurp body "${path}"
  [[ -n ${body} ]] || die "Admin key source file is empty: ${source}"
  printf '%s' "${body}"
}

# The admin usernames, in the order the operator listed them.
#
# Nothing is emitted until every name has passed: the callers read this
# through process substitution, where mapfile cannot see a later failure, so
# a half-written list would silently drop the administrators after the bad
# one and still look like a success.
admin_users() {
  local user
  local -a names=()
  for user in ${PVE_ADMIN_USERS:-}; do
    [[ ${user} =~ ^[a-z_][a-z0-9_-]*$ ]] ||
      die "Not a usable username in PVE_ADMIN_USERS: ${user}"
    names+=("${user}")
  done
  for user in ${names[@]+"${names[@]}"}; do
    printf '%s\n' "${user}"
  done
}

# Per-user keys win over the shared source, so a deployment with several
# administrators does not have to give them all the same key.
admin_keys_for() {
  local user=$1 upper override
  upper=${user^^}
  upper=${upper//-/_}
  override="PVE_ADMIN_KEY_${upper}"
  if [[ -n ${!override:-} ]]; then
    admin_key_source_resolve "${!override}"
    return 0
  fi
  [[ -n ${PVE_ADMIN_KEY_SOURCE:-} ]] ||
    die "No SSH key for ${user}: set ${override} or PVE_ADMIN_KEY_SOURCE."
  admin_key_source_resolve "${PVE_ADMIN_KEY_SOURCE}"
}

# Resolves and verifies every administrator's keys before anything is
# installed, so a deployment that would end up unreachable fails while the
# operator is still able to log in. A shared PVE_ADMIN_KEY_SOURCE is
# therefore optional: what matters is that each listed administrator ends
# up covered, by whichever source.
#
# Prints each user and their key count; dies on the first problem.
admin_keys_require() {
  local -a users=()
  mapfile -t users < <(admin_users)
  [[ ${#users[@]} -gt 0 ]] || die 'PVE_ADMIN_USERS resolved to no usernames.'

  local user keys line count
  for user in "${users[@]}"; do
    keys=$(admin_keys_for "${user}")
    count=0
    while IFS= read -r line; do
      [[ -n ${line} ]] || continue
      _ssh_key_identity "${line}" >/dev/null ||
        die "Not an SSH public key, for ${user}: ${line}"
      ssh_key_is_valid "${line}" ||
        die "ssh-keygen rejects a key configured for ${user}: ${line}"
      count=$((count + 1))
    done < <(_ssh_keys_normalise "${keys}")
    [[ ${count} -gt 0 ]] ||
      die "No usable SSH public key is configured for ${user}."
    printf '%s %s\n' "${user}" "${count}"
  done
}
