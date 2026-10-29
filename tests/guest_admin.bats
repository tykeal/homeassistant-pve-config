#!/usr/bin/env bats
# SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
# SPDX-License-Identifier: Apache-2.0

# shellcheck disable=SC2030,SC2031

# Mirroring the host's administrators into a container.
#
# The cases that matter here are the ones where getting it wrong locks an
# operator out: a PAM line that stacks up, password authentication going
# away before the keys that replace it are known to work, and the root
# password being locked on a container nobody has confirmed they can reach.

load helpers/test_helper

# Real ed25519 public keys. ssh-keygen is not mocked anywhere in this
# suite, so a key-shaped string it rejects would be rejected here too.
KEY_ALICE='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHICzn119CbPFScmFx6z3R+fB1xufI4WNnsZ0U7HUtEM alice@example.net'
KEY_BOB='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDz4H0f8E/En6+2jzdyOYqDv1Uhah1+F4xnYvAGNK1tf bob@example.net'

PAM_LINE='auth sufficient pam_ssh_agent_auth.so file=/etc/security/authorized_keys'

setup() {
  load_libs
  # shellcheck source=lib/guest-admin.sh
  source "${REPO_ROOT}/lib/guest-admin.sh"
  isolate_env
  use_mocks
  isolate_system
  CT=101
  GUEST=$(target_guest "${CT}")
  ROOT=$(guest_root "${CT}")
  export PVE_ADMIN_USERS='alice'
  export PVE_ADMIN_KEY_SOURCE="${KEY_ALICE}"
  # A container that already has the packages, so a case about one thing
  # is not also a case about apt.
  seed_installed sudo openssh-server libpam-ssh-agent-auth nftables
  seed_guest_file /etc/ssh/sshd_config 'Include /etc/ssh/sshd_config.d/*.conf
'
  # Debian's own boot configuration, which is what the restriction has to
  # survive a reboot inside.
  seed_guest_file /etc/nftables.conf '#!/usr/sbin/nft -f

flush ruleset
'
  # The stacks Debian trixie's sudo package ships, which are two files and
  # not one: a fixture starting from an absent or empty sudo-i could not
  # tell leaving the distro's session stack alone from replacing it.
  seed_guest_file /etc/pam.d/sudo '#%PAM-1.0

session    required   pam_limits.so

@include common-auth
@include common-account
@include common-session-noninteractive
'
  seed_guest_file /etc/pam.d/sudo-i '#%PAM-1.0

session    required   pam_limits.so

@include common-auth
@include common-account
@include common-session
'
}

# dpkg-query reads this, so a package can be present before the stage runs.
seed_installed() {
  local pkg
  mkdir -p "${PVE_CONFIG_MOCK_STATE}/guests/${CT}/state"
  for pkg in "$@"; do
    printf '%s\n' "${pkg}" \
      >>"${PVE_CONFIG_MOCK_STATE}/guests/${CT}/state/packages"
  done
}

seed_guest_file() {
  local path=$1 body=$2
  mkdir -p -- "$(dirname -- "${ROOT}${path}")"
  printf '%s' "${body}" >"${ROOT}${path}"
}

seed_ruleset() {
  mkdir -p "${PVE_CONFIG_MOCK_STATE}/guests/${CT}/state"
  printf '%s' "$1" >"${PVE_CONFIG_MOCK_STATE}/guests/${CT}/state/nft-ruleset"
}

guest_body() {
  cat -- "${ROOT}$1"
}

guest_mode() {
  stat -c '%a' -- "${ROOT}$1"
}

# A container whose root password is already locked, so a case that is not
# about the lock does not have to reach it.
seed_root_locked() {
  printf 'root:!x:20000:0:99999:7:::\n' >"${ROOT}/etc/shadow"
}

converge() {
  guest_admin_converge "${GUEST}"
}

# Names, modes and contents, so a case can tell a run that changed
# nothing from one that created a directory or a mode.
guest_fingerprint() {
  find "${ROOT}" -printf '%p %y %m\n' | sort
  find "${ROOT}" -type f -print0 | sort -z | xargs -0 -r sha256sum
}

@test "every administrator gets an account, their key and sudo" {
  export PVE_ADMIN_USERS='alice bob'
  export PVE_ADMIN_KEY_ALICE="${KEY_ALICE}"
  export PVE_ADMIN_KEY_BOB="${KEY_BOB}"
  run converge
  [ "${status}" -eq 0 ]

  grep -q '^alice:' "${ROOT}/etc/passwd"
  grep -q '^bob:' "${ROOT}/etc/passwd"
  [ "$(guest_body /home/alice/.ssh/authorized_keys)" = "${KEY_ALICE}" ]
  [ "$(guest_body /home/bob/.ssh/authorized_keys)" = "${KEY_BOB}" ]
  grep -q "${KEY_ALICE}" "${ROOT}/etc/security/authorized_keys"
  grep -q "${KEY_BOB}" "${ROOT}/etc/security/authorized_keys"
}

@test "the PAM line is left exactly once on a stack that already has it" {
  # Seeded with the line already in place, because a fixture starting from
  # a file without it cannot tell correct convergence from the `sed -i
  # '1a'` this module replaces: both end with one copy.
  seed_guest_file /etc/pam.d/sudo "@include common-auth
${PAM_LINE}
@include common-account
"
  run converge
  [ "${status}" -eq 0 ]
  [ "$(grep -c 'pam_ssh_agent_auth' "${ROOT}/etc/pam.d/sudo")" -eq 1 ]
}

@test "a stack that already stacked the line up is brought back to one" {
  # Two active copies, which is what the `sed -i '1a'` this module
  # replaces leaves behind after two runs. Converging has to take one
  # away, not add a third and not stop at two.
  seed_guest_file /etc/pam.d/sudo "@include common-auth
${PAM_LINE}
${PAM_LINE}
@include common-account
"
  run converge
  [ "${status}" -eq 0 ]
  [ "$(grep -c 'pam_ssh_agent_auth' "${ROOT}/etc/pam.d/sudo")" -eq 1 ]
  grep -qx "${PAM_LINE}" "${ROOT}/etc/pam.d/sudo"
}

@test "a second run leaves the PAM stack alone" {
  converge >/dev/null
  converge >/dev/null
  [ "$(grep -c 'pam_ssh_agent_auth' "${ROOT}/etc/pam.d/sudo")" -eq 1 ]
}

@test "the whole of it converges on a second run" {
  converge >/dev/null
  local before after
  before=$(guest_fingerprint)
  : >"${PVE_CONFIG_MOCK_LOG}"
  run converge
  [ "${status}" -eq 0 ]
  [ "${lines[-1]}" = 'unchanged' ]
  after=$(guest_fingerprint)
  [ "${before}" = "${after}" ]
}

@test "the agent key file is 0600 and the sudoers drop-in 0440" {
  converge >/dev/null
  [ "$(guest_mode /etc/security/authorized_keys)" = '600' ]
  [ "$(guest_mode /etc/sudoers.d/90-ssh-agent)" = '440' ]
  [ "$(guest_mode /home/alice/.ssh/authorized_keys)" = '600' ]
  [ "$(guest_mode /home/alice/.ssh)" = '700' ]
}

@test "sudo -i takes the agent line and keeps its own session stack" {
  converge >/dev/null
  [ ! -L "${ROOT}/etc/pam.d/sudo-i" ]
  [ "$(grep -c 'pam_ssh_agent_auth' "${ROOT}/etc/pam.d/sudo-i")" -eq 1 ]
  # The line that makes sudo -i a login session, which a symlink to
  # /etc/pam.d/sudo would have swapped for the noninteractive stack.
  grep -qx '@include common-session' "${ROOT}/etc/pam.d/sudo-i"
}

@test "a sudo-i somebody has already linked to sudo is left alone" {
  rm -f -- "${ROOT}/etc/pam.d/sudo-i"
  ln -s /etc/pam.d/sudo "${ROOT}/etc/pam.d/sudo-i"
  converge >/dev/null
  [ -L "${ROOT}/etc/pam.d/sudo-i" ]
  [ "$(readlink -- "${ROOT}/etc/pam.d/sudo-i")" = '/etc/pam.d/sudo' ]
}

@test "a sudo-i linked somewhere else stops the run rather than being followed" {
  rm -f -- "${ROOT}/etc/pam.d/sudo-i"
  ln -s /etc/pam.d/site-sudo "${ROOT}/etc/pam.d/sudo-i"
  run converge
  [ "${status}" -ne 0 ]
  [[ ${output} == *'site-sudo'* ]]
}

@test "the sudoers drop-in keeps SSH_AUTH_SOCK and is checked by visudo" {
  converge >/dev/null
  grep -q 'env_keep += "SSH_AUTH_SOCK"' "${ROOT}/etc/sudoers.d/90-ssh-agent"
  mock_calls | grep -q '^visudo -c -f '
}

@test "a sudoers file visudo refuses is never pushed into the container" {
  # The content is what visudo judges, so the refusal is provoked by
  # giving it something to refuse rather than by stubbing the answer.
  sudoers_rubbish() {
    target_install_validated "${GUEST}" /etc/sudoers.d/90-ssh-agent \
      'this is not sudoers syntax
' 0440 validate_sudoers_file
  }
  run sudoers_rubbish
  [ "${status}" -ne 0 ]
  [ ! -e "${ROOT}/etc/sudoers.d/90-ssh-agent" ]
}

@test "ssh is restricted to the tailnet in the container's own packet filter" {
  export PVE_GUEST_ADMIN_SSH_ACCESS='tailnet'
  converge >/dev/null
  local ruleset
  ruleset=$(cat "${PVE_CONFIG_MOCK_STATE}/guests/${CT}/state/nft-ruleset")
  [[ ${ruleset} == *'table inet pve_config_admin'* ]]
  [[ ${ruleset} == *'iifname "tailscale0" ip saddr 100.64.0.0/10 tcp dport 22 accept'* ]]
  [[ ${ruleset} == *'iifname "tailscale0" ip6 saddr fd7a:115c:a1e0::/48 tcp dport 22 accept'* ]]
  [[ ${ruleset} == *'tcp dport 22 drop'* ]]
  grep -q 'include "/etc/nftables.d/\*.nft"' "${ROOT}/etc/nftables.conf"
  mock_calls | grep -q 'systemctl enable -- nftables.service'
}

@test "the include goes after the flush Debian's own ruleset starts with" {
  export PVE_GUEST_ADMIN_SSH_ACCESS='tailnet'
  seed_guest_file /etc/nftables.conf '#!/usr/sbin/nft -f

flush ruleset
'
  converge >/dev/null
  local body
  body=$(grep -v '^$' "${ROOT}/etc/nftables.conf")
  [ "$(tail -n 1 <<<"${body}")" = 'include "/etc/nftables.d/*.nft"' ]
}

@test "a container whose filter already restricts ssh is not reloaded" {
  converge >/dev/null
  : >"${PVE_CONFIG_MOCK_LOG}"
  converge >/dev/null
  run grep -q 'nft -f' <(mock_calls)
  [ "${status}" -ne 0 ]
}

@test "a packet filter that cannot be read stops the run before hardening" {
  export PVE_CONFIG_MOCK_NFT_LIST_FAIL=1
  run converge
  [ "${status}" -ne 0 ]
  [[ ${output} == *'packet filter'* ]]
  [ ! -e "${ROOT}/etc/ssh/sshd_config.d/99-pve-config-admin.conf" ]
  run grep -q 'passwd -l root' <(mock_calls)
  [ "${status}" -ne 0 ]
}

@test "a restriction that cannot be applied stops the run before hardening" {
  export PVE_GUEST_ADMIN_SSH_ACCESS='tailnet'
  export PVE_CONFIG_MOCK_NFT_LOAD_FAIL=1
  run converge
  [ "${status}" -ne 0 ]
  # Reported as the load it is, and not as a container that merely has no
  # rules yet: those call for different answers from whoever reads this.
  [[ ${output} == *'Unable to load'* ]]
  [ ! -e "${ROOT}/etc/ssh/sshd_config.d/99-pve-config-admin.conf" ]
  run grep -q 'PasswordAuthentication no' -r "${ROOT}/etc/ssh"
  [ "${status}" -ne 0 ]
  run grep -q 'passwd -l root' <(mock_calls)
  [ "${status}" -ne 0 ]
}

@test "a restriction gone by the time the root lock is reached stops it" {
  export PVE_GUEST_ADMIN_SSH_ACCESS='tailnet'
  export PVE_GUEST_ADMIN_ROOT_LOCK='yes'
  converge >/dev/null
  printf 'root:x:20000:0:99999:7:::\n' >"${ROOT}/etc/shadow"
  : >"${PVE_CONFIG_MOCK_STATE}/guests/${CT}/state/nft-ruleset"
  run guest_admin_root_lock "${GUEST}"
  [ "${status}" -ne 0 ]
  [[ ${output} == *'does not restrict ssh to the tailnet'* ]]
  run grep -q '^root:!' "${ROOT}/etc/shadow"
  [ "${status}" -ne 0 ]
}

@test "a container with no tunnel interface is not given the restriction" {
  export PVE_GUEST_ADMIN_SSH_ACCESS='tailnet'
  # The accepts name the interface the tunnel's packets arrive on, so a
  # container that has no such interface would be given a filter that
  # drops ssh from everywhere, tunnel included.
  rm -rf -- "${ROOT}/sys/class/net/tailscale0"
  run converge
  [ "${status}" -ne 0 ]
  [[ ${output} == *'has no tailscale0 interface'* ]]
  [ ! -s "${PVE_CONFIG_MOCK_STATE}/guests/${CT}/state/nft-ruleset" ]
  [ ! -e "${ROOT}/etc/ssh/sshd_config.d/99-pve-config-admin.conf" ]
}

@test "a tunnel interface under another name is the one bound to" {
  export PVE_GUEST_ADMIN_SSH_ACCESS='tailnet'
  export PVE_GUEST_ADMIN_TAILNET_IFACE='ts0'
  mkdir -p -- "${ROOT}/sys/class/net/ts0"
  converge >/dev/null
  local ruleset
  ruleset=$(cat "${PVE_CONFIG_MOCK_STATE}/guests/${CT}/state/nft-ruleset")
  [[ ${ruleset} == *'iifname "ts0" ip saddr 100.64.0.0/10 tcp dport 22 accept'* ]]
}

@test "a boot file that goes on past the include stops the hardening" {
  export PVE_GUEST_ADMIN_SSH_ACCESS='tailnet'
  converge >/dev/null
  # The check, rather than a whole run: converge puts the include back at
  # the end of the file before it gets here, so the condition only
  # survives long enough to reach the check if that ever stops being
  # true. The guard is what is under test either way.
  printf '%s\n' 'flush ruleset' >>"${ROOT}/etc/nftables.conf"
  run _guest_admin_firewall_boot_keeps "${GUEST}"
  [ "${status}" -ne 0 ]
  [[ ${output} == *'goes on past the include'* ]]
}

@test "another fragment that flushes the ruleset stops the hardening" {
  export PVE_GUEST_ADMIN_SSH_ACCESS='tailnet'
  # nftables.conf loads /etc/nftables.d/*.nft in order, so a fragment
  # sorting after this module's takes the table away again at boot while
  # `nft -c` still calls the file a valid transaction.
  seed_guest_file /etc/nftables.d/zz-reset.nft '#!/usr/sbin/nft -f
flush ruleset
'
  run converge
  [ "${status}" -ne 0 ]
  [[ ${output} == *'flushes the ruleset'* ]]
  run grep -q 'passwd -l root' <(mock_calls)
  [ "${status}" -ne 0 ]
}

@test "the lan setting leaves the packet filter alone" {
  export PVE_GUEST_ADMIN_SSH_ACCESS='lan'
  converge >/dev/null
  [ ! -s "${PVE_CONFIG_MOCK_STATE}/guests/${CT}/state/nft-ruleset" ]
  [ ! -e "${ROOT}/etc/nftables.d/pve-config-admin.nft" ]
}

@test "moving a container from tailnet to lan lifts the restriction" {
  export PVE_GUEST_ADMIN_SSH_ACCESS='tailnet'
  converge >/dev/null
  grep -q 'table inet pve_config_admin' \
    "${PVE_CONFIG_MOCK_STATE}/guests/${CT}/state/nft-ruleset"
  export PVE_GUEST_ADMIN_SSH_ACCESS='lan'
  converge >/dev/null
  run grep -q 'table inet pve_config_admin' \
    "${PVE_CONFIG_MOCK_STATE}/guests/${CT}/state/nft-ruleset"
  [ "${status}" -ne 0 ]
  [ ! -e "${ROOT}/etc/nftables.d/pve-config-admin.nft" ]
}

@test "an include somebody else put in nftables.conf is left where it is" {
  export PVE_GUEST_ADMIN_SSH_ACCESS='tailnet'
  seed_guest_file /etc/nftables.d/site.rules 'table inet site {
	chain input {
		type filter hook input priority filter; policy accept;
	}
}
'
  seed_guest_file /etc/nftables.conf '#!/usr/sbin/nft -f

flush ruleset
include "/etc/nftables.d/site.rules"
'
  converge >/dev/null
  # `*.nft` does not load `site.rules`, so replacing that line with this
  # module's own would take the operator's firewall away at the next boot
  # without anything having said so.
  grep -qF 'include "/etc/nftables.d/site.rules"' "${ROOT}/etc/nftables.conf"
  grep -qF 'include "/etc/nftables.d/*.nft"' "${ROOT}/etc/nftables.conf"
}

@test "a table whose rules are not this toolkit's is still taken away" {
  export PVE_GUEST_ADMIN_SSH_ACCESS='lan'
  # This module's own table, carrying rules it did not write: ssh is
  # filtered either way, so reading "not restricted" off it and leaving
  # it alone would report the container reachable while it is not.
  seed_ruleset 'table inet pve_config_admin {
	chain input {
		type filter hook input priority filter; policy accept;
		tcp dport 22 drop
	}
}
'
  run converge
  [ "${status}" -eq 0 ]
  run grep -q 'table inet pve_config_admin' \
    "${PVE_CONFIG_MOCK_STATE}/guests/${CT}/state/nft-ruleset"
  [ "${status}" -ne 0 ]
  mock_calls | grep -q 'nft delete table inet pve_config_admin'
}

@test "sshd on a port the restriction does not cover stops the hardening" {
  export PVE_GUEST_ADMIN_SSH_ACCESS='tailnet'
  seed_guest_file /etc/ssh/sshd_config 'Include /etc/ssh/sshd_config.d/*.conf
Port 2222
'
  run converge
  [ "${status}" -ne 0 ]
  [[ ${output} == *'port 2222'* ]]
  [ ! -e "${ROOT}/etc/ssh/sshd_config.d/99-pve-config-admin.conf" ]
  run grep -q 'passwd -l root' <(mock_calls)
  [ "${status}" -ne 0 ]
}

@test "a second listener the restriction does not cover stops the hardening" {
  export PVE_GUEST_ADMIN_SSH_ACCESS='tailnet'
  seed_guest_file /etc/ssh/sshd_config 'Include /etc/ssh/sshd_config.d/*.conf
ListenAddress 0.0.0.0:2222
'
  run converge
  [ "${status}" -ne 0 ]
  [[ ${output} == *'port 2222'* ]]
}

@test "a bare IPv6 listener is not read as a port and does not stop it" {
  # The colons in an unbracketed IPv6 address are not a port separator,
  # and refusing one would abort a container configured exactly right.
  export PVE_GUEST_ADMIN_SSH_ACCESS='tailnet'
  seed_guest_file /etc/ssh/sshd_config 'Include /etc/ssh/sshd_config.d/*.conf
ListenAddress fd00::1
Port 22
'
  run converge
  [ "${status}" -eq 0 ]
}

@test "groups that cannot be read are not an account with no groups" {
  # An AllowGroups judged against an empty list admits everybody, which
  # is the answer that disables password authentication.
  converge >/dev/null
  rm -f -- "${ROOT}/etc/ssh/sshd_config.d/99-pve-config-admin.conf"
  seed_guest_file /etc/ssh/sshd_config 'Include /etc/ssh/sshd_config.d/*.conf
AllowGroups operators
'
  chmod 000 "${ROOT}/etc/group"
  run guest_admin_sshd_converge "${GUEST}"
  chmod 644 "${ROOT}/etc/group"
  [ "${status}" -ne 0 ]
  [[ ${output} == *'groups alice belongs to'* ]]
  [ ! -e "${ROOT}/etc/ssh/sshd_config.d/99-pve-config-admin.conf" ]
}

@test "an administrator denied inside a Match block stops the hardening" {
  # sshd never enters a Match block for a dump with no connection to
  # match on, so reading past it would take passwords away from an
  # account the daemon will not talk to.
  seed_guest_file /etc/ssh/sshd_config 'Include /etc/ssh/sshd_config.d/*.conf

Match User alice
	DenyUsers alice
'
  run converge
  [ "${status}" -ne 0 ]
  [[ ${output} == *'Match User alice'* ]]
  [ ! -e "${ROOT}/etc/ssh/sshd_config.d/99-pve-config-admin.conf" ]
}

@test "a dry run over a container that does not exist yet still plans" {
  # The container a dry run would have built answers nothing, and every
  # check below reads it: going on would end the plan with a transport
  # error instead of finishing it.
  export PVE_CONFIG_DRY_RUN=1
  export PVE_CONFIG_MOCK_PCT_FAIL_VMID="${CT}"
  run converge
  [ "${status}" -eq 0 ]
  [[ ${output} == *'would mirror the administrators'* ]]
}

@test "the root password is left alone unless the configuration asks" {
  converge >/dev/null
  run grep -q '^root:!' "${ROOT}/etc/shadow"
  [ "${status}" -ne 0 ]
  run grep -q 'passwd -l root' <(mock_calls)
  [ "${status}" -ne 0 ]
}

@test "a dry run loads no rules into the container" {
  export PVE_CONFIG_DRY_RUN=1
  run converge
  [ "${status}" -eq 0 ]
  [ ! -e "${PVE_CONFIG_MOCK_STATE}/guests/${CT}/state/nft-ruleset" ]
  run grep -q 'nft -f' <(mock_calls)
  [ "${status}" -ne 0 ]
}

@test "a ruleset nft would not parse is refused rather than loaded" {
  # The fixture is what nft judges, so a module that wrote a rule outside
  # the syntax would be caught here rather than reported as applied.
  seed_guest_file /etc/nftables.d/broken.nft 'table inet broken {
	chain input {
		tcp dport twenty-two accept
	}
}
'
  run target_run "${GUEST}" nft -f /etc/nftables.d/broken.nft
  [ "${status}" -ne 0 ]
  run grep -q 'table inet broken' \
    "${PVE_CONFIG_MOCK_STATE}/guests/${CT}/state/nft-ruleset"
  [ "${status}" -ne 0 ]
}

@test "sshd is hardened and admits the administrators over the tailnet" {
  export PVE_GUEST_ADMIN_SSH_ACCESS='tailnet'
  converge >/dev/null
  local fragment="${ROOT}/etc/ssh/sshd_config.d/99-pve-config-admin.conf"
  grep -qx 'PasswordAuthentication no' "${fragment}"
  grep -qx 'KbdInteractiveAuthentication no' "${fragment}"
  grep -q 'AllowUsers alice@100.64.0.0/10 alice@fd7a:115c:a1e0::/48' "${fragment}"
}

@test "the lan setting admits the administrators from anywhere" {
  export PVE_GUEST_ADMIN_SSH_ACCESS='lan'
  converge >/dev/null
  grep -qx 'AllowUsers alice' \
    "${ROOT}/etc/ssh/sshd_config.d/99-pve-config-admin.conf"
}

@test "an sshd configuration that admits only root stops the hardening" {
  # Before the Include, so this is the AllowUsers sshd keeps: a first
  # occurrence of a keyword is the one that counts, and the fragment this
  # module writes would be read but not obeyed.
  seed_guest_file /etc/ssh/sshd_config 'AllowUsers root
Include /etc/ssh/sshd_config.d/*.conf
'
  run converge
  [ "${status}" -ne 0 ]
  [[ ${output} == *"resolves allowusers to 'root'"* ]]
  [ ! -e "${ROOT}/etc/ssh/sshd_config.d/99-pve-config-admin.conf" ]
}

@test "an administrator sshd is told to deny stops the hardening" {
  seed_guest_file /etc/ssh/sshd_config 'Include /etc/ssh/sshd_config.d/*.conf
DenyUsers alice
'
  run converge
  [ "${status}" -ne 0 ]
  [[ ${output} == *'denies'* ]]
  [ ! -e "${ROOT}/etc/ssh/sshd_config.d/99-pve-config-admin.conf" ]
}

@test "an AuthorizedKeysFile pointing elsewhere stops the hardening" {
  seed_guest_file /etc/ssh/sshd_config 'Include /etc/ssh/sshd_config.d/*.conf
AuthorizedKeysFile /etc/ssh/keys/%u
'
  run converge
  [ "${status}" -ne 0 ]
  [[ ${output} == *'AuthorizedKeysFile'* ]]
  [ ! -e "${ROOT}/etc/ssh/sshd_config.d/99-pve-config-admin.conf" ]
}

@test "an Include this toolkit cannot reproduce stops the hardening" {
  seed_guest_file /etc/ssh/sshd_config 'Include /etc/ssh/site-policy.conf
'
  run converge
  [ "${status}" -ne 0 ]
  [[ ${output} == *'site-policy.conf'* ]]
  [ ! -e "${ROOT}/etc/ssh/sshd_config.d/99-pve-config-admin.conf" ]
}

@test "a nested Include is mirrored and read, not merely allowed" {
  # The drop-in names a directory below itself, so the policy that
  # decides who sshd admits is two levels down. A mirror that copied
  # only the immediate children would hold a configuration the container
  # is not running, and this AuthorizedKeysFile would take effect right
  # after the password lock.
  seed_guest_file /etc/ssh/sshd_config.d/10-site.conf \
    'Include /etc/ssh/sshd_config.d/site/*.conf
'
  seed_guest_file /etc/ssh/sshd_config.d/site/10-policy.conf \
    'AuthorizedKeysFile /etc/ssh/keys/%u
'
  run converge
  [ "${status}" -ne 0 ]
  [[ ${output} == *'AuthorizedKeysFile'* ]]
  [ ! -e "${ROOT}/etc/ssh/sshd_config.d/99-pve-config-admin.conf" ]
}

@test "an Include that climbs out of the drop-in directory stops it" {
  # Lexically inside the directory and not inside it at all. sshd
  # resolves the path; so does this, rather than reading the string.
  seed_guest_file /etc/ssh/sshd_config.d/10-site.conf \
    'Include /etc/ssh/sshd_config.d/../site-policy.conf
'
  seed_guest_file /etc/ssh/site-policy.conf 'AllowUsers root
'
  run converge
  [ "${status}" -ne 0 ]
  [[ ${output} == *'site-policy.conf'* ]]
  [ ! -e "${ROOT}/etc/ssh/sshd_config.d/99-pve-config-admin.conf" ]
}

@test "an Include spelled in mixed case is read as the Include it is" {
  # sshd matches its keywords without regard to case, so this pulls the
  # file in exactly as `Include` would.
  seed_guest_file /etc/ssh/sshd_config 'iNcLuDe /etc/ssh/site-policy.conf
Include /etc/ssh/sshd_config.d/*.conf
'
  run converge
  [ "${status}" -ne 0 ]
  [[ ${output} == *'site-policy.conf'* ]]
  [ ! -e "${ROOT}/etc/ssh/sshd_config.d/99-pve-config-admin.conf" ]
}

@test "a quoted Include operand stops the run rather than being parsed" {
  # Real sshd reads this; nothing here does. Quoting, backslash escapes
  # and whitespace inside an operand are sshd's parser's business, and
  # every attempt to reproduce a piece of it has missed the next piece.
  # Issue #30 replaces the walk with `sshd -T` and lifts this.
  seed_guest_file /etc/ssh/sshd_config 'Include "/etc/ssh/sshd_config.d/*.conf"
'
  run converge
  [ "${status}" -ne 0 ]
  [[ ${output} == *'includes'* ]]
  [ ! -e "${ROOT}/etc/ssh/sshd_config.d/99-pve-config-admin.conf" ]
}

@test "a mixed case Include already names the directory" {
  # The container's own configuration pulls the drop-ins in, spelled its
  # way. A second Include line would rewrite the file and reload sshd on
  # every run.
  seed_guest_file /etc/ssh/sshd_config 'iNcLuDe /etc/ssh/sshd_config.d/*.conf
'
  converge >/dev/null
  local body
  body=$(guest_body /etc/ssh/sshd_config)
  [ "$(grep -ci 'include /etc/ssh/sshd_config.d' <<<"${body}")" -eq 1 ]
}

@test "an Include operand with a backslash in it stops the run" {
  # Inside the directory, so only the charset stands between this and a
  # path whose meaning depends on whose parser reads it: sshd takes the
  # backslash as an escape, a shell glob does not.
  seed_guest_file /etc/ssh/sshd_config 'Include /etc/ssh/sshd_config.d/po\licy.conf
'
  run converge
  [ "${status}" -ne 0 ]
  [[ ${output} == *'includes'* ]]
  [ ! -e "${ROOT}/etc/ssh/sshd_config.d/99-pve-config-admin.conf" ]
}

@test "a drop-in named with a backslash stops the run" {
  seed_guest_file '/etc/ssh/sshd_config.d/10-si\te.conf' 'AllowUsers root
'
  run converge
  [ "${status}" -ne 0 ]
  [[ ${output} == *'will not reason about'* ]]
  [ ! -e "${ROOT}/etc/ssh/sshd_config.d/99-pve-config-admin.conf" ]
}

@test "a drop-in whose name holds a newline stops the run" {
  # `ls -1` cannot say this name and `read` cannot hear it, so the file
  # would be skipped and the mirror approved without it -- while sshd
  # loads it through *.conf like any other.
  seed_guest_file "/etc/ssh/sshd_config.d/10-site
policy.conf" 'AllowUsers root
'
  run converge
  [ "${status}" -ne 0 ]
  [[ ${output} == *'control character'* ]]
  [ ! -e "${ROOT}/etc/ssh/sshd_config.d/99-pve-config-admin.conf" ]
}

@test "a drop-in whose name begins with a newline stops the run" {
  # The blank line this produces is skipped by the parse and by the
  # count, so only a question asked about the names themselves sees it.
  seed_guest_file "/etc/ssh/sshd_config.d/
policy.conf" 'AllowUsers root
'
  run converge
  [ "${status}" -ne 0 ]
  [[ ${output} == *'control character'* ]]
  [ ! -e "${ROOT}/etc/ssh/sshd_config.d/99-pve-config-admin.conf" ]
}

@test "a drop-in whose name ends with a newline stops the run" {
  # Captured output loses a trailing newline, so this one is invisible
  # to the count as well.
  seed_guest_file "/etc/ssh/sshd_config.d/policy.conf
" 'AllowUsers root
'
  run converge
  [ "${status}" -ne 0 ]
  [[ ${output} == *'control character'* ]]
  [ ! -e "${ROOT}/etc/ssh/sshd_config.d/99-pve-config-admin.conf" ]
}

@test "a hidden entry beside the drop-ins is copied, not refused" {
  # Probed against OpenSSH 10.2p1: `Include dir/*.conf` does not load a
  # `.hidden.conf`, but an Include naming it outright does -- so the
  # copy holds it and the run carries on.
  seed_guest_file /etc/ssh/sshd_config.d/.10-site.conf.swp 'AllowUsers root
'
  converge >/dev/null
  grep -q 'PasswordAuthentication no' \
    "${ROOT}/etc/ssh/sshd_config.d/99-pve-config-admin.conf"
}

@test "a key that is not installed in the container stops the hardening" {
  # The account is there and the file is not what this run would have
  # written: a container somebody else has been editing.
  # shellcheck disable=SC2329  # the module under test calls it
  guest_admin_keys_install() { printf 'unchanged\n'; }
  run converge
  [ "${status}" -ne 0 ]
  [[ ${output} == *'refusing to disable password authentication'* ]]
  [ ! -e "${ROOT}/etc/ssh/sshd_config.d/99-pve-config-admin.conf" ]
}

@test "a restricted key is not a login this toolkit will harden behind" {
  converge >/dev/null
  printf 'from="10.0.0.1" %s\n' "${KEY_ALICE}" \
    >"${ROOT}/home/alice/.ssh/authorized_keys"
  rm -f -- "${ROOT}/etc/ssh/sshd_config.d/99-pve-config-admin.conf"
  # shellcheck disable=SC2329  # the module under test calls it
  guest_admin_keys_install() { printf 'unchanged\n'; }
  run guest_admin_sshd_converge "${GUEST}"
  [ "${status}" -ne 0 ]
  [[ ${output} == *'restrictions'* ]]
  [ ! -e "${ROOT}/etc/ssh/sshd_config.d/99-pve-config-admin.conf" ]
}

@test "a key that cannot carry the agent is not a login to harden behind" {
  converge >/dev/null
  # sudo in the container authenticates with the forwarded agent key, so
  # an entry that refuses to forward one is not the administrative access
  # this is about to rely on.
  printf 'no-agent-forwarding %s\n' "${KEY_ALICE}" \
    >"${ROOT}/home/alice/.ssh/authorized_keys"
  rm -f -- "${ROOT}/etc/ssh/sshd_config.d/99-pve-config-admin.conf"
  # shellcheck disable=SC2329  # the module under test calls it
  guest_admin_keys_install() { printf 'unchanged\n'; }
  run guest_admin_sshd_converge "${GUEST}"
  [ "${status}" -ne 0 ]
  [[ ${output} == *'no-agent-forwarding'* ]]
}

@test "an authentication chain no key finishes stops the hardening" {
  seed_guest_file /etc/ssh/sshd_config 'Include /etc/ssh/sshd_config.d/*.conf
AuthenticationMethods publickey,password
'
  run converge
  [ "${status}" -ne 0 ]
  [[ ${output} == *'AuthenticationMethods publickey,password'* ]]
  [ ! -e "${ROOT}/etc/ssh/sshd_config.d/99-pve-config-admin.conf" ]
}

@test "a key alone finishing one of the alternatives is enough" {
  seed_guest_file /etc/ssh/sshd_config 'Include /etc/ssh/sshd_config.d/*.conf
AuthenticationMethods publickey password
'
  converge >/dev/null
  [ -f "${ROOT}/etc/ssh/sshd_config.d/99-pve-config-admin.conf" ]
}

@test "sshd that will not forward an agent stops the root lock" {
  export PVE_GUEST_ADMIN_ROOT_LOCK='yes'
  converge >/dev/null
  printf 'root:x:20000:0:99999:7:::\n' >"${ROOT}/etc/shadow"
  seed_guest_file /etc/ssh/sshd_config.d/10-site.conf 'AllowAgentForwarding no
'
  run guest_admin_root_lock "${GUEST}"
  [ "${status}" -ne 0 ]
  [[ ${output} == *'allowagentforwarding no'* ]]
  run grep -q '^root:!' "${ROOT}/etc/shadow"
  [ "${status}" -ne 0 ]
}

@test "the Include is added only after the fragment is in place" {
  seed_guest_file /etc/ssh/sshd_config 'PermitRootLogin yes
'
  converge >/dev/null
  grep -q 'Include /etc/ssh/sshd_config.d/\*.conf' "${ROOT}/etc/ssh/sshd_config"
  [ -f "${ROOT}/etc/ssh/sshd_config.d/99-pve-config-admin.conf" ]
}

@test "TERM is set for the sessions pct enter starts" {
  converge >/dev/null
  grep -q 'xterm-256color' "${ROOT}/etc/profile.d/pve-config-term.sh"
  [ "$(grep -c 'pve-config-term' "${ROOT}/etc/bash.bashrc")" -eq 1 ]
}

@test "a bashrc that already sources the snippet gains no second line" {
  seed_guest_file /etc/bash.bashrc \
    '[ -f /etc/profile.d/pve-config-term.sh ] && . /etc/profile.d/pve-config-term.sh
'
  converge >/dev/null
  [ "$(grep -c 'pve-config-term' "${ROOT}/etc/bash.bashrc")" -eq 1 ]
}

@test "the root password is locked once key based access is confirmed" {
  export PVE_GUEST_ADMIN_ROOT_LOCK='yes'
  converge >/dev/null
  grep -q '^root:!' "${ROOT}/etc/shadow"
  mock_calls | grep -q 'passwd -l root'
}

@test "an already locked root password is left alone" {
  seed_root_locked
  converge >/dev/null
  : >"${PVE_CONFIG_MOCK_LOG}"
  converge >/dev/null
  run grep -q 'passwd -l root' <(mock_calls)
  [ "${status}" -ne 0 ]
}

@test "a root password status that cannot be read stops the run" {
  export PVE_GUEST_ADMIN_ROOT_LOCK='yes'
  export PVE_CONFIG_MOCK_PASSWD_S_FAIL=1
  run converge
  [ "${status}" -ne 0 ]
  [[ ${output} == *"root's password status"* ]]
  run grep -q 'passwd -l root' <(mock_calls)
  [ "${status}" -ne 0 ]
}

@test "a password status this toolkit does not know stops the run" {
  export PVE_GUEST_ADMIN_ROOT_LOCK='yes'
  export PVE_CONFIG_MOCK_PASSWD_STATUS='??'
  run converge
  [ "${status}" -ne 0 ]
  run grep -q 'passwd -l root' <(mock_calls)
  [ "${status}" -ne 0 ]
}

@test "the root password is not locked while sshd is stopped" {
  export PVE_GUEST_ADMIN_ROOT_LOCK='yes'
  converge >/dev/null
  # Back to a container that has everything installed and a daemon that is
  # not running, which is not a container anybody has been let into.
  printf 'root:x:20000:0:99999:7:::\n' >"${ROOT}/etc/shadow"
  rm -f -- "${PVE_CONFIG_MOCK_STATE}/guests/${CT}/state/active"
  run guest_admin_root_lock "${GUEST}"
  [ "${status}" -ne 0 ]
  [[ ${output} == *'sshd is not running'* ]]
  run grep -q '^root:!' "${ROOT}/etc/shadow"
  [ "${status}" -ne 0 ]
}

@test "the root password is not locked when the hardening is missing" {
  export PVE_GUEST_ADMIN_ROOT_LOCK='yes'
  converge >/dev/null
  printf 'root:x:20000:0:99999:7:::\n' >"${ROOT}/etc/shadow"
  rm -f -- "${ROOT}/etc/ssh/sshd_config.d/99-pve-config-admin.conf"
  run guest_admin_root_lock "${GUEST}"
  [ "${status}" -ne 0 ]
  [[ ${output} == *'refusing to lock the root password'* ]]
  run grep -q '^root:!' "${ROOT}/etc/shadow"
  [ "${status}" -ne 0 ]
}

@test "the root password is not locked when sudo would not accept a key" {
  export PVE_GUEST_ADMIN_ROOT_LOCK='yes'
  converge >/dev/null
  printf 'root:x:20000:0:99999:7:::\n' >"${ROOT}/etc/shadow"
  seed_guest_file /etc/pam.d/sudo '@include common-auth
'
  run guest_admin_root_lock "${GUEST}"
  [ "${status}" -ne 0 ]
  [[ ${output} == *'forwarded agent key'* ]]
  run grep -q '^root:!' "${ROOT}/etc/shadow"
  [ "${status}" -ne 0 ]
}

@test "a dry run changes nothing in the container" {
  export PVE_CONFIG_DRY_RUN=1
  local before after
  before=$(guest_fingerprint)
  run converge
  [ "${status}" -eq 0 ]
  after=$(guest_fingerprint)
  [ "${before}" = "${after}" ]
  run grep -qE 'passwd -l|useradd|usermod' <(mock_calls)
  [ "${status}" -ne 0 ]
}

@test "a container pct cannot reach stops the run rather than being changed" {
  export PVE_CONFIG_MOCK_PCT_FAIL_VMID="${CT}"
  run converge
  [ "${status}" -ne 0 ]
}

@test "a key the configuration got wrong is refused before anything installs" {
  export PVE_ADMIN_KEY_SOURCE='ssh-ed25519 AAAAtruncated alice@example.net'
  run converge
  [ "${status}" -ne 0 ]
  [[ ${output} == *'ssh-keygen'* ]]
  run grep -q '^alice:' "${ROOT}/etc/passwd"
  [ "${status}" -ne 0 ]
}

@test "the host is not a target for this" {
  run guest_admin_converge "$(target_host)"
  [ "${status}" -ne 0 ]
  [[ ${output} == *'not onto the host'* ]]
}

@test "the packages are installed and the lists refreshed only when they are" {
  rm -f -- "${PVE_CONFIG_MOCK_STATE}/guests/${CT}/state/packages"
  converge >/dev/null
  mock_calls | grep -q 'apt-get install -y sudo openssh-server libpam-ssh-agent-auth'
  : >"${PVE_CONFIG_MOCK_LOG}"
  converge >/dev/null
  run grep -q 'apt-get' <(mock_calls)
  [ "${status}" -ne 0 ]
}

@test "a filter whose drop comes first is not a filter anybody can reach" {
  # Every piece is there and the order makes it block every
  # administrator. Searching a ruleset for familiar text would call this
  # restricted and then harden behind it.
  seed_ruleset 'table inet pve_config_admin {
	chain input {
		type filter hook input priority filter; policy accept;
		tcp dport 22 drop
		iifname "tailscale0" ip saddr 100.64.0.0/10 tcp dport 22 accept
		iifname "tailscale0" ip6 saddr fd7a:115c:a1e0::/48 tcp dport 22 accept
	}
}
'
  run _guest_admin_firewall_live "${GUEST}"
  [ "${status}" -eq 1 ]
}

@test "rules in somebody else's table do not answer for this one" {
  seed_ruleset 'table inet pve_config_admin {
	chain input {
		type filter hook input priority filter; policy accept;
	}
}
table inet other {
	chain input {
		type filter hook input priority filter; policy accept;
		iifname "tailscale0" ip saddr 100.64.0.0/10 tcp dport 22 accept
		iifname "tailscale0" ip6 saddr fd7a:115c:a1e0::/48 tcp dport 22 accept
		tcp dport 22 drop
	}
}
'
  run _guest_admin_firewall_live "${GUEST}"
  [ "${status}" -eq 1 ]
}

@test "a chain that is not on the input hook does not restrict anything" {
  seed_ruleset 'table inet pve_config_admin {
	chain input {
		type filter hook output priority filter; policy accept;
		iifname "tailscale0" ip saddr 100.64.0.0/10 tcp dport 22 accept
		iifname "tailscale0" ip6 saddr fd7a:115c:a1e0::/48 tcp dport 22 accept
		tcp dport 22 drop
	}
}
'
  run _guest_admin_firewall_live "${GUEST}"
  [ "${status}" -eq 1 ]
}

@test "a filter whose order has been undone stops the root lock" {
  export PVE_GUEST_ADMIN_SSH_ACCESS='tailnet'
  export PVE_GUEST_ADMIN_ROOT_LOCK='yes'
  converge >/dev/null
  printf 'root:x:20000:0:99999:7:::\n' >"${ROOT}/etc/shadow"
  seed_ruleset 'table inet pve_config_admin {
	chain input {
		type filter hook input priority filter; policy accept;
		tcp dport 22 drop
		iifname "tailscale0" ip saddr 100.64.0.0/10 tcp dport 22 accept
		iifname "tailscale0" ip6 saddr fd7a:115c:a1e0::/48 tcp dport 22 accept
	}
}
'
  run guest_admin_root_lock "${GUEST}"
  [ "${status}" -ne 0 ]
  [[ ${output} == *'does not restrict ssh to the tailnet'* ]]
  run grep -q '^root:!' "${ROOT}/etc/shadow"
  [ "${status}" -ne 0 ]
}

@test "a restriction the container would lose at boot stops the hardening" {
  export PVE_GUEST_ADMIN_SSH_ACCESS='tailnet'
  # One malformed file in the include directory takes the whole boot
  # configuration down with it, so a container restricted now would come
  # back from a reboot restricting nothing.
  seed_guest_file /etc/nftables.d/sibling.nft 'table inet sibling {
	chain input {
		tcp dport twenty-two accept
	}
}
'
  run converge
  [ "${status}" -ne 0 ]
  [[ ${output} == *'would not survive a reboot'* ]]
  [ ! -e "${ROOT}/etc/ssh/sshd_config.d/99-pve-config-admin.conf" ]
  run grep -q 'passwd -l root' <(mock_calls)
  [ "${status}" -ne 0 ]
}

@test "the hardening stage refuses on its own when the filter is gone" {
  export PVE_GUEST_ADMIN_SSH_ACCESS='tailnet'
  # The gate inside the sshd stage, reached directly: the converge above
  # it would have refused first, which leaves this one unverified unless
  # it is asked by itself.
  converge >/dev/null
  rm -f -- "${ROOT}/etc/ssh/sshd_config.d/99-pve-config-admin.conf"
  seed_ruleset ''
  run guest_admin_sshd_converge "${GUEST}"
  [ "${status}" -ne 0 ]
  [[ ${output} == *'does not restrict ssh to the tailnet'* ]]
  [ ! -e "${ROOT}/etc/ssh/sshd_config.d/99-pve-config-admin.conf" ]
}

@test "the hardening stage refuses on its own when the filter cannot be read" {
  converge >/dev/null
  rm -f -- "${ROOT}/etc/ssh/sshd_config.d/99-pve-config-admin.conf"
  export PVE_CONFIG_MOCK_NFT_LIST_FAIL=1
  run guest_admin_sshd_converge "${GUEST}"
  [ "${status}" -ne 0 ]
  [[ ${output} == *'Unable to read the packet filter'* ]]
  [ ! -e "${ROOT}/etc/ssh/sshd_config.d/99-pve-config-admin.conf" ]
}

@test "a reload that never happened is picked up by the next run" {
  # Interrupted after the fragment went in and before sshd read it: every
  # file is right and the daemon is still serving the old policy.
  converge >/dev/null
  seed_guest_file /var/lib/pve-config/sshd-reload-pending 'pending
'
  : >"${PVE_CONFIG_MOCK_LOG}"
  converge >/dev/null
  mock_calls | grep -q 'systemctl reload -- ssh.service'
  [ ! -e "${ROOT}/var/lib/pve-config/sshd-reload-pending" ]
}

@test "an outstanding reload stops the root password being locked" {
  export PVE_GUEST_ADMIN_ROOT_LOCK='yes'
  converge >/dev/null
  printf 'root:x:20000:0:99999:7:::\n' >"${ROOT}/etc/shadow"
  seed_guest_file /var/lib/pve-config/sshd-reload-pending 'pending
'
  run guest_admin_root_lock "${GUEST}"
  [ "${status}" -ne 0 ]
  [[ ${output} == *'has not reloaded'* ]]
  run grep -q '^root:!' "${ROOT}/etc/shadow"
  [ "${status}" -ne 0 ]
}

@test "a converged container is left without a reload marker to clean up" {
  converge >/dev/null
  [ ! -e "${ROOT}/var/lib/pve-config/sshd-reload-pending" ]
  converge >/dev/null
  [ ! -e "${ROOT}/var/lib/pve-config/sshd-reload-pending" ]
}

@test "an Include inside a drop-in this toolkit cannot reproduce stops it" {
  # sshd resolves this against the container and the mirror never copies
  # it, so the admission walk would judge a configuration with a piece
  # missing. Nested one level down, where only a recursive walk sees it.
  seed_guest_file /etc/ssh/sshd_config.d/10-site.conf \
    'Include /etc/ssh/site-policy.conf
'
  run converge
  [ "${status}" -ne 0 ]
  [[ ${output} == *'site-policy.conf'* ]]
  [ ! -e "${ROOT}/etc/ssh/sshd_config.d/99-pve-config-admin.conf" ]
}

@test "a drop-in directory that cannot be listed is not an empty one" {
  # The listing really fails, because the directory really cannot be
  # read. Asked of the mirror directly: the stage above it puts the mode
  # back to 0755 before it gets here, which is the right thing for the
  # stage to do and would hide this.
  mkdir -p -- "${ROOT}/etc/ssh/sshd_config.d"
  printf 'PermitRootLogin yes\n' \
    >"${ROOT}/etc/ssh/sshd_config.d/10-site.conf"
  chmod 300 -- "${ROOT}/etc/ssh/sshd_config.d"
  mirror_it() {
    local dir
    _guest_admin_sshd_mirror "${GUEST}" 'PasswordAuthentication no' dir
  }
  run mirror_it
  chmod 755 -- "${ROOT}/etc/ssh/sshd_config.d"
  [ "${status}" -ne 0 ]
  # The listing by name: an unreadable directory also stops the count
  # that follows it, and a looser assertion would pass on either.
  [[ ${output} == *'Unable to list /etc/ssh/sshd_config.d'* ]]
}

@test "a listing pct cannot run stops the hardening rather than passing" {
  # The drop-in says nothing this toolkit objects to, so the only thing
  # that can stop the run is the listing this knob breaks: a fixture
  # that failed a later gate would pass whatever the listing did.
  seed_guest_file /etc/ssh/sshd_config.d/10-site.conf 'Port 22
'
  export PVE_CONFIG_MOCK_PCT_EXEC_FAIL='ls -1A -- /etc/ssh/sshd_config.d'
  run converge
  [ "${status}" -ne 0 ]
  # Named in the diagnostic, so the run can be seen to have stopped at
  # the listing rather than somewhere later.
  [[ ${output} == *'ls -1A -- /etc/ssh/sshd_config.d'* ]]
  [ ! -e "${ROOT}/etc/ssh/sshd_config.d/99-pve-config-admin.conf" ]
  run grep -q 'passwd -l root' <(mock_calls)
  [ "${status}" -ne 0 ]
}

@test "the passwd mock refuses what the real tool would refuse" {
  # A mock looser than the tool it stands in for hides the bug it is
  # there to catch: `passwd -S root extra` and `passwd -S -l root` are
  # both usage errors, and one that quietly kept the last of each would
  # answer calls this toolkit must never make.
  run target_run "${GUEST}" passwd -S root extra
  [ "${status}" -eq 2 ]
  run target_run "${GUEST}" passwd -S -l root
  [ "${status}" -eq 2 ]
  run target_run "${GUEST}" passwd -S root
  [ "${status}" -eq 0 ]
}

@test "the nft mock refuses what the real tool would refuse" {
  # Real nft exits 1 on every one of these: each command takes a fixed
  # number of operands, and a trailing token is a syntax error. A mock
  # that accepted them would let a malformed call through unnoticed.
  run target_run "${GUEST}" nft list ruleset junk
  [ "${status}" -ne 0 ]
  run target_run "${GUEST}" nft list table inet "${GUEST_ADMIN_NFT_TABLE}" junk
  [ "${status}" -ne 0 ]
  run target_run "${GUEST}" nft flush ruleset junk
  [ "${status}" -ne 0 ]
  run target_run "${GUEST}" nft delete table inet "${GUEST_ADMIN_NFT_TABLE}" junk
  [ "${status}" -ne 0 ]
  run target_run "${GUEST}" nft -f /etc/nftables.conf junk
  [ "${status}" -ne 0 ]
  run target_run "${GUEST}" nft list ruleset
  [ "${status}" -eq 0 ]
}

@test "counters and comments on a rule are not a filter this stops for" {
  export PVE_GUEST_ADMIN_SSH_ACCESS='tailnet'
  # nft prints what it holds, and a chain that has seen traffic prints
  # counters with it. Refusing a ruleset over the way it renders would
  # abort a container that is configured exactly right.
  seed_ruleset 'table inet pve_config_admin {
	chain input {
		type filter hook input priority filter; policy accept;
		iif "lo" counter packets 12 bytes 840 accept
		iifname "tailscale0" ip saddr 100.64.0.0/10 tcp dport 22 counter packets 3 bytes 180 accept comment "tailnet v4"
		iifname "tailscale0" ip6 saddr fd7a:115c:a1e0::/48 tcp dport 22 accept
		tcp dport 22 counter packets 0 bytes 0 drop
	}
}
'
  run _guest_admin_firewall_live "${GUEST}"
  [ "${status}" -eq 0 ]
}

@test "a table nft itself printed is read the way nft printed it" {
  # Not the mock's idea of nft's output: these documents came out of a
  # real nftables 1.1.6 in a network namespace. Rendering is where a
  # structural check goes wrong, and refusing a spelling nft chose would
  # abort a container that is configured exactly right. `plain` is the
  # fragment this module writes; `noisy` was written with `tcp dport
  # ssh`, an uppercase expanded IPv6 prefix, `priority 0`, counters and a
  # comment, and nft printed back what it printed back.
  local name
  for name in plain noisy nolo; do
    run _guest_admin_firewall_rules_restrict \
      "$(cat "${REPO_ROOT}/tests/fixtures/nft/${name}.txt")"
    [ "${status}" -eq 0 ] || {
      printf 'fixture %s answered %s\n' "${name}" "${status}"
      return 1
    }
  done
}

@test "a real table that does not restrict ssh is not read as one that does" {
  local name
  # Each of these came out of the same real nft: the accepts behind the
  # drop, no IPv6 accept, the chain on the forward hook, an accept
  # narrowed to one interface, a second chain in the table, a table with
  # nothing in it, a chain whose policy is drop, a chain holding every
  # required rule behind an accept that admits the whole LAN, one with a
  # rule this module never wrote, a table carrying `flags dormant` --
  # whose base chain is unregistered from its hook, so the rules below
  # it filter nothing at all -- and one whose accepts match the tailnet
  # address without naming the interface it arrives on, which a LAN host
  # addressed out of 100.64.0.0/10 also matches.
  for name in dropfirst nov6 forwardhook narrowed twochains empty policydrop \
    openaccept extrarule dormant saddronly; do
    run _guest_admin_firewall_rules_restrict \
      "$(cat "${REPO_ROOT}/tests/fixtures/nft/${name}.txt")"
    [ "${status}" -eq 1 ] || {
      printf 'fixture %s answered %s\n' "${name}" "${status}"
      return 1
    }
  done
}
