#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

# shellcheck source=lib/stage.sh
source "${PVE_CONFIG_LIB_DIR:?PVE_CONFIG_LIB_DIR is unset}/stage.sh"

stage_require PVE_ADMIN_USERS

SYSROOT=$(sysroot)

# Before anything here, because the fragment below disables password
# authentication. If a configured key is not one sshd would accept, this is
# the last moment at which saying so is any use.
admin_keys_require >/dev/null

mapfile -t USERS < <(admin_users)
[[ ${#USERS[@]} -gt 0 ]] || die 'PVE_ADMIN_USERS resolved to no usernames.'

# A valid key in the configuration is not the same as a key this host will
# accept. The driver happily runs this stage on its own, so on a fresh
# password-only machine 60-admin-users may never have run and disabling
# passwords here would close the only way in.
assert_admin_access() {
  local user home keys file installed reason
  for user in "${USERS[@]}"; do
    user_exists "${user}" ||
      die "${user} has no account on this host; run the 60-admin-users stage before hardening SSH."
    home=$(user_home "${user}") || home="/home/${user}"
    file="$(sysroot)${home}/.ssh/authorized_keys"
    [[ -f ${file} ]] ||
      die "${user} has no ${file}; run the 60-admin-users stage before hardening SSH."
    _slurp installed "${file}"
    keys=$(admin_keys_for "${user}")
    reason=$(authorized_keys_access_problem \
      "${installed}" "${keys}" "${user}" "${file}" \
      'run the 60-admin-users stage before hardening SSH') && continue
    die "${reason}"
  done
}

# sshd only reads ~/.ssh/authorized_keys because that is the default; a
# host that names somewhere else, or `none`, ignores every key installed
# above. Disabling passwords on top of that removes the last way in, so
# any AuthorizedKeysFile this host sets -- globally or under a Match -- has
# to still name the file the keys went into.
#
# The reading is lib/common.sh's, shared with the containers phase 2
# mirrors these administrators into: two systems asking the same question
# must not be able to answer it differently.
assert_authorized_keys_path() {
  local main="${SYSROOT}/etc/ssh/sshd_config" reason
  reason=$(sshd_authorized_keys_problem "${main}" "$(sysroot)" '' '') && return 0
  die "${reason}"
}

# AllowUsers, DenyUsers, AllowGroups and DenyGroups decide who sshd will
# even talk to, before any key is considered. A host that admits only root
# would reject every administrator configured here, and disabling password
# authentication on top of that leaves nobody able to log in at all. None
# of these four are permitted inside a Match block, so the unconditional
# part of the configuration is the whole story.
assert_ssh_admits_admins() {
  local main="${SYSROOT}/etc/ssh/sshd_config" user groups reason
  local -a pairs=()
  for user in "${USERS[@]}"; do
    groups=$(user_groups "${user}" | paste -sd, -)
    pairs+=("${user}" "${groups}")
  done
  reason=$(sshd_admission_problem "${main}" "$(sysroot)" '' '' \
    ${pairs[@]+"${pairs[@]}"}) && return 0
  die "${reason}"
}

if dry_run_enabled; then
  log_info 'would check that every administrator can already log in with a key'
else
  assert_admin_access
  assert_authorized_keys_path
  assert_ssh_admits_admins
fi

# --- sshd -----------------------------------------------------------------

# sshd only reads a fragment when the main configuration includes one, and
# it keeps the first value it obtains. A host whose sshd_config has no
# Include at all would take this file as validated and then never read it.
#
# The Include is added *after* the fragment has validated and installed.
# Publishing it first would leave it behind on a validation failure, and
# with it every other file in that directory -- including one some other
# tool left broken -- newly live for the next sshd restart.
sshd_main="${SYSROOT}/etc/ssh/sshd_config"
# Every letter spelled out: sshd reads its keywords without regard to
# case, so a host whose `iNcLuDe` already names the directory would
# otherwise gain a second Include line on every run.
include_match='^[[:space:]]*[Ii][Nn][Cc][Ll][Uu][Dd][Ee][[:space:]]+.*sshd_config\.d'
include_needed=0
if [[ -f ${sshd_main} ]] && ! grep -Eq "${include_match}" "${sshd_main}"; then
  include_needed=1
fi

hardening="# Managed by pve-config.
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
"

ensure_dir "${SYSROOT}/etc/ssh/sshd_config.d" 0755 >/dev/null
# The validator assembles the configuration sshd will read once the Include
# is in place, which is not yet what is on disk.
PVE_CONFIG_SSHD_ASSUME_INCLUDE="${include_needed}"
sshd_state=unchanged
state_of sshd_state install_validated \
  "${SYSROOT}/etc/ssh/sshd_config.d/99-hardening.conf" \
  "${hardening}" 0644 validate_sshd_config
unset PVE_CONFIG_SSHD_ASSUME_INCLUDE

include_state=unchanged
if [[ ${include_needed} -eq 1 ]]; then
  # Matched on sshd_config.d specifically: an Include naming some other
  # policy file is somebody's access control and is not ours to remove.
  state_of include_state ensure_exact_line "${sshd_main}" "${include_match}" \
    'Include /etc/ssh/sshd_config.d/*.conf' prepend
fi

# A reload that never happened leaves the old policy running, and the next
# run finds both files already correct and would skip it. The marker
# outlives the failure so the retry still reloads.
reload_marker="${SYSROOT}/var/lib/pve-config/sshd-reload-pending"
reload_needed=0
if [[ ${sshd_state} == changed || ${include_state} == changed || -f ${reload_marker} ]]; then
  reload_needed=1
fi

# Reloaded, not restarted: this host is very likely being configured over
# the connection that a restart would drop.
if [[ ${reload_needed} -eq 1 ]]; then
  ensure_dir "${SYSROOT}/var/lib/pve-config" 0755 >/dev/null
  write_file "${reload_marker}" "pending"$'\n' 0644 >/dev/null
  service_reload ssh.service >/dev/null
  remove_path "${reload_marker}" >/dev/null
fi

if [[ ${PVE_SUDO_SSH_AGENT:-yes} != yes ]]; then
  log_info 'PVE_SUDO_SSH_AGENT is not yes; leaving sudo authentication alone'
  exit 0
fi

# --- sudo via a forwarded agent -------------------------------------------

pkg_install sudo libpam-ssh-agent-auth >/dev/null

# One file holding every administrator's key. pam_ssh_agent_auth reads it as
# root, so it is deliberately not any individual's authorized_keys.
agent_keys=''
for user in "${USERS[@]}"; do
  user_keys=$(admin_keys_for "${user}")
  [[ -n ${user_keys} ]] || die "No SSH public key resolved for ${user}."
  agent_keys+="${user_keys%$'\n'}"$'\n'
done

ensure_dir "${SYSROOT}/etc/security" 0755 >/dev/null
write_file "${SYSROOT}/etc/security/authorized_keys" "${agent_keys}" 0600 >/dev/null

# Exactly one active line, wherever a previous run or a hand edit left one.
# The script this replaces used `sed -i '1a ...'`, which stacked another
# copy on every single invocation.
ensure_exact_line "${SYSROOT}/etc/pam.d/sudo" \
  'pam_ssh_agent_auth\.so' \
  'auth sufficient pam_ssh_agent_auth.so file=/etc/security/authorized_keys' \
  after-first >/dev/null

# sudo -i reads its own PAM stack, and an administrator who can sudo but not
# sudo -i has a confusing half-configured host.
ensure_symlink /etc/pam.d/sudo "${SYSROOT}/etc/pam.d/sudo-i" >/dev/null

ensure_dir "${SYSROOT}/etc/sudoers.d" 0755 >/dev/null
install_validated "${SYSROOT}/etc/sudoers.d/90-ssh-agent" \
  '# Managed by pve-config.
Defaults env_keep += "SSH_AUTH_SOCK"
' 0440 validate_sudoers_file >/dev/null

log_info "sudo accepts a forwarded agent key for: ${USERS[*]}"
