#!/usr/bin/env bats
# SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
# SPDX-License-Identifier: Apache-2.0

load helpers/test_helper

setup() {
  load_libs
  isolate_env
  use_mocks
  isolate_system
}

# --- exactly one active line ----------------------------------------------

@test "ensure_exact_line adds the line when the file has none" {
  local pam="${BATS_TEST_TMPDIR}/sudo"
  printf '#%%PAM-1.0\n@include common-auth\n' >"${pam}"

  run ensure_exact_line "${pam}" 'pam_ssh_agent_auth\.so' \
    'auth sufficient pam_ssh_agent_auth.so file=/etc/security/authorized_keys' \
    after-first
  [ "$status" -eq 0 ]
  [[ "$output" == *changed* ]]
  [ "$(sed -n 2p "${pam}")" = 'auth sufficient pam_ssh_agent_auth.so file=/etc/security/authorized_keys' ]
}

@test "ensure_exact_line never duplicates across repeated runs" {
  local pam="${BATS_TEST_TMPDIR}/sudo"
  local line='auth sufficient pam_ssh_agent_auth.so file=/etc/security/authorized_keys'
  printf '#%%PAM-1.0\n@include common-auth\n' >"${pam}"

  for _ in 1 2 3 4 5; do
    ensure_exact_line "${pam}" 'pam_ssh_agent_auth\.so' "${line}" after-first >/dev/null
  done

  [ "$(grep -c 'pam_ssh_agent_auth' "${pam}")" -eq 1 ]
  run ensure_exact_line "${pam}" 'pam_ssh_agent_auth\.so' "${line}" after-first
  [[ "$output" == *unchanged* ]]
}

@test "ensure_exact_line collapses duplicates an earlier run left behind" {
  local pam="${BATS_TEST_TMPDIR}/sudo"
  local line='auth sufficient pam_ssh_agent_auth.so file=/etc/security/authorized_keys'
  printf '#%%PAM-1.0\n%s\n%s\n%s\n@include common-auth\n' \
    "${line}" "${line}" "${line}" >"${pam}"

  run ensure_exact_line "${pam}" 'pam_ssh_agent_auth\.so' "${line}" after-first
  [[ "$output" == *changed* ]]
  [ "$(grep -c 'pam_ssh_agent_auth' "${pam}")" -eq 1 ]
}

@test "ensure_exact_line leaves a commented out variant alone" {
  local pam="${BATS_TEST_TMPDIR}/sudo"
  local line='auth sufficient pam_ssh_agent_auth.so file=/etc/security/authorized_keys'
  printf '#%%PAM-1.0\n# %s\n' "${line}" >"${pam}"

  ensure_exact_line "${pam}" 'pam_ssh_agent_auth\.so' "${line}" after-first >/dev/null
  [ "$(grep -c '^# auth sufficient' "${pam}")" -eq 1 ]
  [ "$(grep -c '^auth sufficient' "${pam}")" -eq 1 ]
}

@test "ensure_exact_line replaces a drifted value in place" {
  local main="${BATS_TEST_TMPDIR}/main.cf"
  printf 'myhostname = old.example.net\nmydomain = example.net\n' >"${main}"

  ensure_exact_line "${main}" '^[[:space:]]*myhostname[[:space:]]*=' \
    'myhostname = new.example.net' >/dev/null
  [ "$(grep -c 'myhostname' "${main}")" -eq 1 ]
  [[ "$(cat "${main}")" == *'myhostname = new.example.net'* ]]
  [[ "$(cat "${main}")" == *'mydomain = example.net'* ]]
}

@test "ensure_exact_line changes nothing under a dry run" {
  local pam="${BATS_TEST_TMPDIR}/sudo"
  printf '#%%PAM-1.0\n' >"${pam}"
  PVE_CONFIG_DRY_RUN=1 run ensure_exact_line "${pam}" 'pam_ssh_agent_auth\.so' \
    'auth sufficient pam_ssh_agent_auth.so file=/etc/security/authorized_keys' after-first
  [[ "$output" == *changed* ]]
  [ "$(cat "${pam}")" = '#%PAM-1.0' ]
}

# --- directories, removal and symlinks ------------------------------------

@test "ensure_dir creates, converges the mode, then reports unchanged" {
  local dir="${BATS_TEST_TMPDIR}/a/b"
  run ensure_dir "${dir}" 0700
  [[ "$output" == *changed* ]]
  [ "$(stat -c '%a' "${dir}")" = '700' ]

  run ensure_dir "${dir}" 0700
  [[ "$output" == *unchanged* ]]

  chmod 0755 "${dir}"
  run ensure_dir "${dir}" 0700
  [[ "$output" == *changed* ]]
  [ "$(stat -c '%a' "${dir}")" = '700' ]
}

@test "ensure_dir creates nothing under a dry run" {
  PVE_CONFIG_DRY_RUN=1 run ensure_dir "${BATS_TEST_TMPDIR}/nope" 0700
  [[ "$output" == *changed* ]]
  [ ! -e "${BATS_TEST_TMPDIR}/nope" ]
}

@test "remove_path is a no-op on a path that is already gone" {
  local target="${BATS_TEST_TMPDIR}/gone"
  run remove_path "${target}"
  [[ "$output" == *unchanged* ]]

  : >"${target}"
  run remove_path "${target}"
  [[ "$output" == *changed* ]]
  [ ! -e "${target}" ]
}

@test "remove_path removes nothing under a dry run" {
  local target="${BATS_TEST_TMPDIR}/present"
  : >"${target}"
  PVE_CONFIG_DRY_RUN=1 run remove_path "${target}"
  [[ "$output" == *changed* ]]
  [ -e "${target}" ]
}

@test "ensure_symlink converges and then reports unchanged" {
  local link="${BATS_TEST_TMPDIR}/sudo-i"
  run ensure_symlink /etc/pam.d/sudo "${link}"
  [[ "$output" == *changed* ]]
  [ "$(readlink "${link}")" = '/etc/pam.d/sudo' ]

  run ensure_symlink /etc/pam.d/sudo "${link}"
  [[ "$output" == *unchanged* ]]
}

@test "ensure_symlink backs up a regular file before replacing it" {
  local link="${BATS_TEST_TMPDIR}/sudo-i"
  printf 'original\n' >"${link}"
  ensure_symlink /etc/pam.d/sudo "${link}" >/dev/null
  [ -L "${link}" ]
  [ "$(cat "${link}.pve-config.bak")" = 'original' ]
}

# --- validate then install ------------------------------------------------

@test "install_validated installs an sshd fragment that passes sshd -t" {
  local target="${PVE_CONFIG_ROOT}/etc/ssh/sshd_config.d/99-hardening.conf"
  run install_validated "${target}" 'PasswordAuthentication no
' 0644 validate_sshd_config
  [ "$status" -eq 0 ]
  [[ "$output" == *changed* ]]
  [ "$(cat "${target}")" = 'PasswordAuthentication no' ]
  [[ "$(mock_calls)" == *'sshd -t -f'* ]]
}

@test "install_validated refuses to install a bad sshd fragment" {
  local target="${PVE_CONFIG_ROOT}/etc/ssh/sshd_config.d/99-hardening.conf"
  run install_validated "${target}" 'ThisIsNotAnOption yes
' 0644 validate_sshd_config
  [ "$status" -ne 0 ]
  [ ! -e "${target}" ]
}

@test "install_validated refuses to install a bad sudoers file" {
  local target="${PVE_CONFIG_ROOT}/etc/sudoers.d/90-ssh-agent"
  run install_validated "${target}" 'this is not sudoers syntax
' 0440 validate_sudoers_file
  [ "$status" -ne 0 ]
  [ ! -e "${target}" ]
}

@test "install_validated installs a sudoers file at the mode sudo demands" {
  local target="${PVE_CONFIG_ROOT}/etc/sudoers.d/90-ssh-agent"
  install_validated "${target}" 'Defaults env_keep += "SSH_AUTH_SOCK"
' 0440 validate_sudoers_file >/dev/null
  [ "$(stat -c '%a' "${target}")" = '440' ]
}

@test "install_validated validates but installs nothing under a dry run" {
  local target="${PVE_CONFIG_ROOT}/etc/ssh/sshd_config.d/99-hardening.conf"
  PVE_CONFIG_DRY_RUN=1 run install_validated "${target}" 'PasswordAuthentication no
' 0644 validate_sshd_config
  [ "$status" -eq 0 ]
  [ ! -e "${target}" ]
  [[ "$(mock_calls)" == *'sshd -t -f'* ]]
}

@test "install_validated leaves no candidate behind when validation fails" {
  local target="${PVE_CONFIG_ROOT}/etc/sudoers.d/90-ssh-agent"
  run install_validated "${target}" 'nonsense
' 0440 validate_sudoers_file
  [ "$status" -ne 0 ]
  [ ! -e "${target}" ]
  # The candidate lives in a directory removed on every exit path, so
  # nothing is left behind for the next run to trip over.
  run find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'pve-config-validate.*'
  [ -z "$output" ]
}

@test "install_validated checks the whole effective sshd configuration" {
  # The fragment alone parses; it is the main config plus every fragment
  # that sshd actually reads, so that is what has to be checked.
  mkdir -p "${PVE_CONFIG_ROOT}/etc/ssh/sshd_config.d"
  printf 'Include %s/etc/ssh/sshd_config.d/*.conf\nPort 22\n' \
    "${PVE_CONFIG_ROOT}" >"${PVE_CONFIG_ROOT}/etc/ssh/sshd_config"
  printf 'ThisIsNotAnOption yes\n' \
    >"${PVE_CONFIG_ROOT}/etc/ssh/sshd_config.d/10-broken.conf"

  local target="${PVE_CONFIG_ROOT}/etc/ssh/sshd_config.d/99-hardening.conf"
  run install_validated "${target}" 'PasswordAuthentication no
' 0644 validate_sshd_config
  [ "$status" -ne 0 ]
  [ ! -e "${target}" ]
}

@test "install_validated accepts a candidate that completes the main config" {
  mkdir -p "${PVE_CONFIG_ROOT}/etc/ssh/sshd_config.d"
  printf 'Include %s/etc/ssh/sshd_config.d/*.conf\nPort 22\n' \
    "${PVE_CONFIG_ROOT}" >"${PVE_CONFIG_ROOT}/etc/ssh/sshd_config"

  local target="${PVE_CONFIG_ROOT}/etc/ssh/sshd_config.d/99-hardening.conf"
  run install_validated "${target}" 'PasswordAuthentication no
' 0644 validate_sshd_config
  [ "$status" -eq 0 ]
  [ -f "${target}" ]
}

@test "a dry run reports rather than fails when the validator is absent" {
  # Dry run deliberately installs nothing, so the package providing the
  # validator may not be there yet. Refusing then would make a dry run on a
  # fresh host impossible, which defeats the point of having one.
  PVE_CONFIG_DRY_RUN=1 run _validator_missing visudo 'sudoers file'
  [ "$status" -eq 0 ]
  [[ "$output" == *'would validate'* ]]
}

@test "a real run refuses to install what it could not validate" {
  PVE_CONFIG_DRY_RUN=0 run _validator_missing visudo 'sudoers file'
  [ "$status" -ne 0 ]
  [[ "$output" == *'unvalidated'* ]]
}

@test "install_validated refuses a network description ifupdown2 will not parse" {
  local target="${PVE_CONFIG_ROOT}/etc/network/interfaces"
  run install_validated "${target}" 'nonsense-keyword vmbr0
' 0644 validate_interfaces_file
  [ "$status" -ne 0 ]
  [ ! -e "${target}" ]
}

# --- packages -------------------------------------------------------------

@test "pkg_install installs only what is missing and then no-ops" {
  run pkg_install isc-dhcp-client
  [[ "$output" == *changed* ]]
  [[ "$(mock_calls)" == *'apt-get install -y isc-dhcp-client'* ]]

  run pkg_install isc-dhcp-client
  [[ "$output" == *unchanged* ]]
}

@test "pkg_install asks only for the packages that are absent" {
  pkg_install sudo >/dev/null
  : >"${PVE_CONFIG_MOCK_LOG}"
  run pkg_install sudo libpam-ssh-agent-auth
  [[ "$output" == *changed* ]]
  [[ "$(mock_calls)" == *'apt-get install -y libpam-ssh-agent-auth'* ]]
  [[ "$(mock_calls)" != *'install -y sudo'* ]]
}

@test "pkg_install installs nothing under a dry run" {
  PVE_CONFIG_DRY_RUN=1 run pkg_install sudo
  [ "$status" -eq 0 ]
  [[ "$(mock_calls)" != *'apt-get install'* ]]
}

# --- systemd --------------------------------------------------------------

@test "service_enable and service_start are no-ops once in the desired state" {
  run service_enable zulip-boot-notify.service
  [[ "$output" == *changed* ]]
  run service_enable zulip-boot-notify.service
  [[ "$output" == *unchanged* ]]

  run service_start pve-cluster.service
  [[ "$output" == *changed* ]]
  run service_start pve-cluster.service
  [[ "$output" == *unchanged* ]]
}

@test "service_disable only acts on an enabled unit" {
  run service_disable pveproxy.service
  [[ "$output" == *unchanged* ]]
  service_enable pveproxy.service >/dev/null
  run service_disable pveproxy.service
  [[ "$output" == *changed* ]]
}

@test "service_reload leaves a stopped unit alone and reloads a running one" {
  run service_reload ssh.service
  [[ "$output" == *unchanged* ]]
  [[ "$(mock_calls)" != *'systemctl reload'* ]]

  service_start ssh.service >/dev/null
  run service_reload ssh.service
  [[ "$output" == *changed* ]]
  [[ "$(mock_calls)" == *'systemctl reload -- ssh.service'* ]]
}

@test "service_restart starts a unit that is not running" {
  run service_restart pvestatd.service
  [[ "$output" == *changed* ]]
  [[ "$(mock_calls)" == *'systemctl start -- pvestatd.service'* ]]
  [[ "$(mock_calls)" != *'systemctl restart'* ]]
}

@test "systemd_daemon_reload collapses to one call per stage" {
  systemd_daemon_reload >/dev/null
  run systemd_daemon_reload
  [[ "$output" == *unchanged* ]]
  [ "$(grep -c 'systemctl daemon-reload' "${PVE_CONFIG_MOCK_LOG}")" -eq 1 ]
}

@test "systemd changes nothing under a dry run" {
  PVE_CONFIG_DRY_RUN=1 run service_enable zulip-boot-notify.service
  [ "$status" -eq 0 ]
  [[ "$(mock_calls)" != *'systemctl enable'* ]]
}

# --- Proxmox users and ACLs -----------------------------------------------

@test "pve_user_converge adds the user once and then reports unchanged" {
  run pve_user_converge admin@pam
  [[ "$output" == *changed* ]]
  [[ "$(mock_calls)" == *'pveum user add admin@pam'* ]]

  : >"${PVE_CONFIG_MOCK_LOG}"
  run pve_user_converge admin@pam
  [[ "$output" == *unchanged* ]]
  [[ "$(mock_calls)" != *'user add'* ]]
}

@test "pve_user_converge tolerates a user it did not know about" {
  # A listing the toolkit cannot read, over a user that really is there, is
  # exactly the case the "already exists" tolerance exists for. It is also
  # what the script this replaces died on every second run.
  pve_user_converge admin@pam >/dev/null
  export PVE_CONFIG_MOCK_PVEUM_LIST_FAILS=1

  run pve_user_converge admin@pam
  [ "$status" -eq 0 ]
  [[ "$output" == *unchanged* ]]
}

@test "pve_acl_converge grants once and then reports unchanged" {
  run pve_acl_converge / PVEAdmin admin@pam
  [[ "$output" == *changed* ]]
  run pve_acl_converge / PVEAdmin admin@pam
  [[ "$output" == *unchanged* ]]
}

@test "pve_acl_converge does not mistake another user's grant for this one" {
  pve_acl_converge / PVEAdmin alice@pam >/dev/null
  run pve_acl_converge / PVEAdmin bob@pam
  [[ "$output" == *changed* ]]
}

@test "pve user handling changes nothing under a dry run" {
  PVE_CONFIG_DRY_RUN=1 run pve_user_converge admin@pam
  [ "$status" -eq 0 ]
  [[ "$(mock_calls)" != *'user add'* ]]
}

# --- write_file_backup ----------------------------------------------------

@test "write_file_backup keeps the operator's original, not our own output" {
  local path="${PVE_CONFIG_ROOT}/etc/demo.conf"
  mkdir -p "$(dirname "${path}")"
  printf 'the original\n' >"${path}"

  write_file_backup "${path}" 'managed
' 0644 >/dev/null
  write_file_backup "${path}" 'managed
' 0644 >/dev/null

  [ "$(cat "${path}.pve-config.bak")" = 'the original' ]
}

@test "write_file_backup takes no backup of a file it is creating" {
  local path="${PVE_CONFIG_ROOT}/etc/demo.conf"
  mkdir -p "$(dirname "${path}")"
  run write_file_backup "${path}" 'managed
' 0644
  [ "${lines[-1]}" = 'changed' ]
  [ ! -e "${path}.pve-config.bak" ]
}

@test "write_file_backup writes nothing under a dry run" {
  local path="${PVE_CONFIG_ROOT}/etc/demo.conf"
  mkdir -p "$(dirname "${path}")"
  printf 'the original\n' >"${path}"

  PVE_CONFIG_DRY_RUN=1 run write_file_backup "${path}" 'managed
' 0644
  [ "${lines[-1]}" = 'changed' ]
  [ "$(cat "${path}")" = 'the original' ]
  [ ! -e "${path}.pve-config.bak" ]
}

@test "install_validated refuses a fragment an earlier file overrides" {
  # sshd keeps the first value it obtains, so a fragment that parses
  # cleanly can still be dead weight behind something read before it.
  mkdir -p "${PVE_CONFIG_ROOT}/etc/ssh/sshd_config.d"
  printf 'Include %s/etc/ssh/sshd_config.d/*.conf\n' \
    "${PVE_CONFIG_ROOT}" >"${PVE_CONFIG_ROOT}/etc/ssh/sshd_config"
  printf 'PasswordAuthentication yes\n' \
    >"${PVE_CONFIG_ROOT}/etc/ssh/sshd_config.d/50-cloud-init.conf"

  local target="${PVE_CONFIG_ROOT}/etc/ssh/sshd_config.d/99-hardening.conf"
  run install_validated "${target}" 'PasswordAuthentication no
' 0644 validate_sshd_config

  [ "$status" -ne 0 ]
  [ ! -e "${target}" ]
}

@test "install_validated refuses an sshd fragment nothing would include" {
  mkdir -p "${PVE_CONFIG_ROOT}/etc/ssh/sshd_config.d"
  printf 'Port 22\n' >"${PVE_CONFIG_ROOT}/etc/ssh/sshd_config"

  local target="${PVE_CONFIG_ROOT}/etc/ssh/sshd_config.d/99-hardening.conf"
  run install_validated "${target}" 'PasswordAuthentication no
' 0644 validate_sshd_config

  [ "$status" -ne 0 ]
  [ ! -e "${target}" ]
  [[ "$output" == *'does not include'* ]]
}

@test "install_validated reads a fragment that is not named .conf" {
  mkdir -p "${PVE_CONFIG_ROOT}/etc/ssh/sshd_config.d"
  printf 'Include %s/etc/ssh/sshd_config.d/*\n' \
    "${PVE_CONFIG_ROOT}" >"${PVE_CONFIG_ROOT}/etc/ssh/sshd_config"
  printf 'PasswordAuthentication yes\n' \
    >"${PVE_CONFIG_ROOT}/etc/ssh/sshd_config.d/10-site.cfg"

  local target="${PVE_CONFIG_ROOT}/etc/ssh/sshd_config.d/99-hardening.conf"
  run install_validated "${target}" 'PasswordAuthentication no
' 0644 validate_sshd_config

  [ "$status" -ne 0 ]
  [ ! -e "${target}" ]
}

@test "install_validated refuses the old spelling of a keyword" {
  mkdir -p "${PVE_CONFIG_ROOT}/etc/ssh/sshd_config.d"
  printf 'Include %s/etc/ssh/sshd_config.d/*.conf\nMatch User alice\n    ChallengeResponseAuthentication yes\n' \
    "${PVE_CONFIG_ROOT}" >"${PVE_CONFIG_ROOT}/etc/ssh/sshd_config"

  local target="${PVE_CONFIG_ROOT}/etc/ssh/sshd_config.d/99-hardening.conf"
  run install_validated "${target}" 'KbdInteractiveAuthentication no
' 0644 validate_sshd_config

  [ "$status" -ne 0 ]
  [ ! -e "${target}" ]
}

@test "install_validated repairs a managed fragment that drifted" {
  mkdir -p "${PVE_CONFIG_ROOT}/etc/ssh/sshd_config.d"
  printf 'Include %s/etc/ssh/sshd_config.d/*.conf\n' \
    "${PVE_CONFIG_ROOT}" >"${PVE_CONFIG_ROOT}/etc/ssh/sshd_config"
  printf 'Match User alice\n    PasswordAuthentication yes\n' \
    >"${PVE_CONFIG_ROOT}/etc/ssh/sshd_config.d/99-hardening.conf"

  local target="${PVE_CONFIG_ROOT}/etc/ssh/sshd_config.d/99-hardening.conf"
  run install_validated "${target}" 'PasswordAuthentication no
' 0644 validate_sshd_config

  [ "$status" -eq 0 ]
  [[ "$(cat "${target}")" == 'PasswordAuthentication no'* ]]
}

@test "install_validated refuses a conditional block an Include hides" {
  mkdir -p "${PVE_CONFIG_ROOT}/etc/ssh/sshd_config.d"
  printf 'Include %s/etc/ssh/sshd_config.d/*.conf\nInclude /etc/ssh/site-policy.conf\n' \
    "${PVE_CONFIG_ROOT}" >"${PVE_CONFIG_ROOT}/etc/ssh/sshd_config"
  printf 'Match User alice\n    PasswordAuthentication yes\n' \
    >"${PVE_CONFIG_ROOT}/etc/ssh/site-policy.conf"

  local target="${PVE_CONFIG_ROOT}/etc/ssh/sshd_config.d/99-hardening.conf"
  run install_validated "${target}" 'PasswordAuthentication no
' 0644 validate_sshd_config

  [ "$status" -ne 0 ]
  [ ! -e "${target}" ]
  [[ "$output" == *site-policy.conf* ]]
}

@test "install_validated refuses a conditional block that undoes the fragment" {
  mkdir -p "${PVE_CONFIG_ROOT}/etc/ssh/sshd_config.d"
  printf 'Include %s/etc/ssh/sshd_config.d/*.conf\nPort 22\nMatch User alice\n    PasswordAuthentication yes\n' \
    "${PVE_CONFIG_ROOT}" >"${PVE_CONFIG_ROOT}/etc/ssh/sshd_config"

  local target="${PVE_CONFIG_ROOT}/etc/ssh/sshd_config.d/99-hardening.conf"
  run install_validated "${target}" 'PasswordAuthentication no
' 0644 validate_sshd_config

  [ "$status" -ne 0 ]
  [ ! -e "${target}" ]
  [[ "$output" == *'Match User alice'* ]]
}

@test "install_validated accepts a conditional block about something else" {
  mkdir -p "${PVE_CONFIG_ROOT}/etc/ssh/sshd_config.d"
  printf 'Include %s/etc/ssh/sshd_config.d/*.conf\nPort 22\nMatch User backup\n    X11Forwarding yes\n' \
    "${PVE_CONFIG_ROOT}" >"${PVE_CONFIG_ROOT}/etc/ssh/sshd_config"

  local target="${PVE_CONFIG_ROOT}/etc/ssh/sshd_config.d/99-hardening.conf"
  run install_validated "${target}" 'PasswordAuthentication no
' 0644 validate_sshd_config

  [ "$status" -eq 0 ]
  [ -f "${target}" ]
}

@test "install_validated assembles the Include a caller has yet to add" {
  mkdir -p "${PVE_CONFIG_ROOT}/etc/ssh/sshd_config.d"
  printf 'Port 22\n' >"${PVE_CONFIG_ROOT}/etc/ssh/sshd_config"

  local target="${PVE_CONFIG_ROOT}/etc/ssh/sshd_config.d/99-hardening.conf"
  PVE_CONFIG_SSHD_ASSUME_INCLUDE=1 run install_validated "${target}" 'PasswordAuthentication no
' 0644 validate_sshd_config

  [ "$status" -eq 0 ]
  [ -f "${target}" ]
}

@test "ensure_not_group_other_writable clears only the write bits" {
  local dir="${PVE_CONFIG_ROOT}/home/alice"
  mkdir -p "${dir}"
  chmod 2775 "${dir}"

  local verdict
  verdict=$(ensure_not_group_other_writable "${dir}" 2>/dev/null)
  [ "${verdict}" = changed ]
  [ "$(stat -c '%a' "${dir}")" = 2755 ]

  verdict=$(ensure_not_group_other_writable "${dir}" 2>/dev/null)
  [ "${verdict}" = unchanged ]
}

@test "ensure_not_group_other_writable changes nothing under a dry run" {
  local dir="${PVE_CONFIG_ROOT}/home/alice"
  mkdir -p "${dir}"
  chmod 0777 "${dir}"

  local verdict
  verdict=$(PVE_CONFIG_DRY_RUN=1 ensure_not_group_other_writable "${dir}" 2>/dev/null)
  [ "${verdict}" = changed ]
  [ "$(stat -c '%a' "${dir}")" = 777 ]
}

# --- node identity --------------------------------------------------------

mark_pmxcfs() {
  mkdir -p "${PVE_CONFIG_MOCK_STATE}"
  printf '%s|%s\n' "${PVE_CONFIG_ROOT}/etc/pve" fuse.pve-cluster \
    >>"${PVE_CONFIG_MOCK_STATE}/mounts"
}

@test "pve_node_rename copies the contents when pmxcfs will not rename" {
  # pmxcfs refuses to rename a directory with anything in it, which a real
  # node directory always has.
  local nodes="${PVE_CONFIG_ROOT}/etc/pve/nodes"
  mkdir -p "${nodes}/install/qemu-server"
  printf 'cert\n' >"${nodes}/install/pve-ssl.pem"
  mark_pmxcfs

  mkdir -p "${BATS_TEST_TMPDIR}/nomv"
  printf '#!/usr/bin/env bash\nexit 1\n' >"${BATS_TEST_TMPDIR}/nomv/mv"
  chmod 0755 "${BATS_TEST_TMPDIR}/nomv/mv"

  PATH="${BATS_TEST_TMPDIR}/nomv:${PATH}" run pve_node_rename "${nodes}" install pve1
  [ "$status" -eq 0 ]
  [ ! -e "${nodes}/install" ]
  [ -d "${nodes}/pve1/qemu-server" ]
  [ "$(cat "${nodes}/pve1/pve-ssl.pem")" = 'cert' ]
}

@test "pve_node_rename refuses to merge into a node that appeared meanwhile" {
  local nodes="${PVE_CONFIG_ROOT}/etc/pve/nodes"
  mkdir -p "${nodes}/install" "${nodes}/pve1"
  printf 'old\n' >"${nodes}/install/pve-ssl.pem"
  printf 'live\n' >"${nodes}/pve1/pve-ssl.pem"
  mark_pmxcfs

  mkdir -p "${BATS_TEST_TMPDIR}/nomv"
  printf '#!/usr/bin/env bash\nexit 1\n' >"${BATS_TEST_TMPDIR}/nomv/mv"
  chmod 0755 "${BATS_TEST_TMPDIR}/nomv/mv"

  PATH="${BATS_TEST_TMPDIR}/nomv:${PATH}" run pve_node_rename "${nodes}" install pve1
  [ "$status" -ne 0 ]
  [ "$(cat "${nodes}/pve1/pve-ssl.pem")" = 'live' ]
  [ ! -e "${nodes}/pve1/install" ]
}

# --- platform guard -------------------------------------------------------

@test "stage_require_proxmox refuses a host with no Proxmox tooling" {
  # Deliberately against no scratch tree: the guard exists to stop a stage
  # reconfiguring an ordinary Debian machine, and the test runner is one.
  run env -u PVE_CONFIG_ROOT -u PVE_CONFIG_DRY_RUN \
    bash -c 'PVE_CONFIG_LIB_DIR='"${REPO_ROOT}"'/lib source '"${REPO_ROOT}"'/lib/stage.sh'
  [ "$status" -ne 0 ]
  [[ "$output" == *'does not look like a Proxmox VE host'* ]]
}

@test "install_validated refuses a fragment an Include names past" {
  # `Include .../sshd_config.d/site.conf` reads one named file, not the
  # directory, so the hardening fragment would never be read.
  mkdir -p "${PVE_CONFIG_ROOT}/etc/ssh/sshd_config.d"
  printf 'Include %s/etc/ssh/sshd_config.d/site.conf\n' \
    "${PVE_CONFIG_ROOT}" >"${PVE_CONFIG_ROOT}/etc/ssh/sshd_config"
  printf 'Port 22\n' >"${PVE_CONFIG_ROOT}/etc/ssh/sshd_config.d/site.conf"

  local target="${PVE_CONFIG_ROOT}/etc/ssh/sshd_config.d/99-hardening.conf"
  run install_validated "${target}" 'PasswordAuthentication no
' 0644 validate_sshd_config

  [ "$status" -ne 0 ]
  [ ! -e "${target}" ]
  [[ "$output" == *'does not include'* ]]
}

@test "install_validated accepts the canonical spelling of a value" {
  # sshd reports PermitRootLogin prohibit-password as without-password.
  mkdir -p "${PVE_CONFIG_ROOT}/etc/ssh/sshd_config.d"
  printf 'Include %s/etc/ssh/sshd_config.d/*.conf\n' \
    "${PVE_CONFIG_ROOT}" >"${PVE_CONFIG_ROOT}/etc/ssh/sshd_config"

  local target="${PVE_CONFIG_ROOT}/etc/ssh/sshd_config.d/99-hardening.conf"
  run install_validated "${target}" 'PermitRootLogin prohibit-password
' 0644 validate_sshd_config

  [ "$status" -eq 0 ]
  [ -f "${target}" ]
}
