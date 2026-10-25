#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
# SPDX-License-Identifier: Apache-2.0

# Proxmox access control convergence.
#
# `pveum user add` fails when the user is already there, which is why the
# script this replaces could only ever be run once. Both helpers here query
# first and tolerate a losing race afterwards.

pve_user_exists() {
  local user=$1 listing
  listing=$(pveum user list --output-format json 2>/dev/null) || return 1
  [[ ${listing} == *"\"${user}\""* ]]
}

pve_user_converge() {
  local user=$1
  if pve_user_exists "${user}"; then
    printf 'unchanged\n'
    return 0
  fi
  if dry_run_enabled; then
    log_info "would add the Proxmox user ${user}"
    printf 'changed\n'
    return 0
  fi

  # Run directly rather than through run_cmd so the failure text can be
  # inspected: an "already exists" is the desired state reached by someone
  # else, not an error.
  local output status=0
  log_info "running: pveum user add ${user}"
  output=$(pveum user add "${user}" 2>&1) || status=$?
  if [[ ${status} -ne 0 ]]; then
    if [[ ${output} == *'already exists'* ]]; then
      log_info "the Proxmox user ${user} already exists"
      printf 'unchanged\n'
      return 0
    fi
    log_error "${output}"
    die "Unable to create the Proxmox user ${user}"
  fi
  printf 'changed\n'
}

# True when one ACL entry grants this user this role on this path. The
# listing is split per entry first, so a role from one entry and a user from
# another cannot be mistaken for a grant that was never made.
_pve_acl_granted() {
  local path=$1 role=$2 user=$3 listing entry
  listing=$(pveum acl list --output-format json 2>/dev/null) || return 1
  [[ -n ${listing} ]] || return 1
  while IFS= read -r entry; do
    if [[ ${entry} == *"\"${user}\""* && ${entry} == *"\"${role}\""* &&
      ${entry} == *"\"${path}\""* ]]; then
      return 0
    fi
  done < <(printf '%s' "${listing}" | tr '}' '\n')
  return 1
}

pve_acl_converge() {
  local path=$1 role=$2 user=$3
  if _pve_acl_granted "${path}" "${role}" "${user}"; then
    printf 'unchanged\n'
    return 0
  fi
  run_cmd pveum acl modify "${path}" --roles "${role}" --users "${user}" ||
    die "Unable to grant ${role} on ${path} to ${user}"
  printf 'changed\n'
}

# True when /etc/pve is the filesystem pve-cluster publishes rather than an
# ordinary directory of the same name. The distinction matters: writing into
# the bare directory puts files where the mount is about to hide them, and
# renaming inside it corrupts nothing but achieves nothing either.
pve_cluster_is_mounted() {
  local target
  target="$(sysroot)/etc/pve"
  [[ -d ${target} ]] || return 1

  local fstype
  if command -v findmnt >/dev/null 2>&1; then
    fstype=$(findmnt -rn -o FSTYPE -- "${target}" 2>/dev/null) || return 1
    [[ -n ${fstype} ]] || return 1
    # pmxcfs is a FUSE filesystem; the exact name has changed across
    # releases, so the family is what is checked.
    [[ ${fstype} == fuse* ]]
    return
  fi

  command -v mountpoint >/dev/null 2>&1 || return 1
  mountpoint -q -- "${target}"
}

# /etc/pve is a FUSE mount that pve-cluster publishes a moment after it is
# asked to start. Everything that writes through it has to wait, or it
# writes into the empty directory the mount is about to cover.
pve_wait_for_cluster() {
  local timeout=${1:-30} waited=0 nodes
  nodes="$(sysroot)/etc/pve/nodes"
  if dry_run_enabled; then
    log_info "would wait for ${nodes} to become available"
    return 0
  fi
  while :; do
    if pve_cluster_is_mounted && [[ -d ${nodes} ]]; then
      return 0
    fi
    [[ ${waited} -lt ${timeout} ]] || break
    sleep 1
    waited=$((waited + 1))
  done

  if [[ -d ${nodes} ]] && ! pve_cluster_is_mounted; then
    log_error "$(sysroot)/etc/pve exists but is not the pve-cluster filesystem."
  fi
  return 1
}

# Renames the node directory pmxcfs created under the host's old name.
#
# `mv src dst` moves src *inside* dst when dst turns up between the check
# and the move, which is how a stale node directory ends up nested in the
# live one. -T refuses to do that: it either replaces the target or fails,
# and failing is the right answer here.
pve_node_rename() {
  local nodes_dir=$1 from=$2 to=$3

  if dry_run_enabled; then
    log_info "would rename the node directory ${from} to ${to}"
    printf 'changed\n'
    return 0
  fi

  pve_cluster_is_mounted ||
    die "Refusing to rename a node directory: $(sysroot)/etc/pve is not the pve-cluster filesystem."

  if mv -T -- "${nodes_dir}/${from}" "${nodes_dir}/${to}" 2>/dev/null; then
    log_info "renamed the node directory ${from} to ${to}"
    printf 'changed\n'
    return 0
  fi

  # pmxcfs is not a general purpose filesystem and will not rename a
  # directory that has anything in it, which a real node directory always
  # does: it holds the node's certificates and its guest configuration. The
  # supported migration is to copy the contents across and drop the old
  # directory, which is what the manual rename procedure amounts to.
  log_info "pmxcfs would not rename ${from}; copying its contents to ${to} instead"
  # Plain mkdir, not -p: if the destination turned up between the caller's
  # check and here, this fails rather than merging the old node's files into
  # the live one.
  mkdir -- "${nodes_dir}/${to}" ||
    die "Unable to create the node directory ${to}; it may have appeared in the meantime."
  if ! (shopt -s dotglob nullglob && cp -a -- "${nodes_dir}/${from}"/* "${nodes_dir}/${to}/"); then
    die "Unable to copy the node directory ${from} to ${to}; the host's node identity is unchanged."
  fi
  rm -rf -- "${nodes_dir:?}/${from}" ||
    die "Copied ${from} to ${to} but could not remove ${from}; remove it by hand."
  log_info "migrated the node directory ${from} to ${to}"
  printf 'changed\n'
}
