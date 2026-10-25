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

# --- sshd -----------------------------------------------------------------

hardening="# Managed by pve-config.
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
"

ensure_dir "${SYSROOT}/etc/ssh/sshd_config.d" 0755 >/dev/null
sshd_state=$(install_validated "${SYSROOT}/etc/ssh/sshd_config.d/99-hardening.conf" \
  "${hardening}" 0644 validate_sshd_config)

# Reloaded, not restarted: this host is very likely being configured over
# the connection that a restart would drop.
if [[ ${sshd_state} == changed ]]; then
  service_reload ssh.service >/dev/null
fi

if [[ ${PVE_SUDO_SSH_AGENT:-yes} != yes ]]; then
  log_info 'PVE_SUDO_SSH_AGENT is not yes; leaving sudo authentication alone'
  exit 0
fi

# --- sudo via a forwarded agent -------------------------------------------

pkg_install sudo libpam-ssh-agent-auth >/dev/null

mapfile -t USERS < <(admin_users)
[[ ${#USERS[@]} -gt 0 ]] || die 'PVE_ADMIN_USERS resolved to no usernames.'

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
