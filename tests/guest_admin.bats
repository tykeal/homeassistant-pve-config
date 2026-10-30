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

@test "a Match block keyed on one administrator is not a refusal" {
  # Deliberately out of scope. What this module guards is that an
  # administrator can log in with a key and that passwords are off, and
  # a Match block that alters something for one connection does not
  # touch either. The global dump is the only one taken, and a criteria
  # Match block does not appear in it -- probed against OpenSSH 10.2p1,
  # `sshd -T` with no -C resolves Match User alice to the global value.
  # The walker this replaced refused this container outright.
  seed_guest_file /etc/ssh/sshd_config 'Include /etc/ssh/sshd_config.d/*.conf

Match User alice
	DenyUsers alice
'
  converge >/dev/null
  grep -q 'PasswordAuthentication no' \
    "${ROOT}/etc/ssh/sshd_config.d/99-pve-config-admin.conf"
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

@test "an AllowUsers elsewhere adds to this one rather than replacing it" {
  # Probed against OpenSSH 10.2p1: AllowUsers accumulates across the
  # whole configuration instead of the first occurrence winning, so a
  # root-only AllowUsers ahead of the Include still leaves alice
  # admitted. Reading it as a setting one occurrence wins -- which is
  # what this suite asserted while this module did its own parsing --
  # refused a container the daemon would have been happy with.
  seed_guest_file /etc/ssh/sshd_config 'AllowUsers root
Include /etc/ssh/sshd_config.d/*.conf
'
  converge >/dev/null
  # Asserted against what sshd resolves, not against the file this
  # module wrote. The managed file holding the line it was written with
  # says nothing about accumulation: both entries have to survive into
  # the dump for the claim in the name to be true.
  run env PVE_CONFIG_MOCK_GUEST_ROOT="${ROOT}" sshd -T -f /etc/ssh/sshd_config
  [ "${status}" -eq 0 ]
  [[ ${output} == *$'\nallowusers alice'* ]]
  [[ ${output} == *$'\nallowusers root'* ]]
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

@test "an Include outside the drop-in directory is read, not refused" {
  # Nothing here enumerates or copies a file any more, so an Include
  # naming somewhere this module knows nothing about is sshd's to
  # follow. The run stops because of what the file says, which is only
  # visible if sshd followed it.
  seed_guest_file /etc/ssh/site-policy.conf 'AuthorizedKeysFile /etc/ssh/keys/%u
'
  seed_guest_file /etc/ssh/sshd_config 'Include /etc/ssh/site-policy.conf
'
  run converge
  [ "${status}" -ne 0 ]
  [[ ${output} == *'/etc/ssh/keys/%u'* ]]
  [ ! -e "${ROOT}/etc/ssh/sshd_config.d/99-pve-config-admin.conf" ]
}

@test "a nested Include is followed, not merely allowed" {
  # The drop-in names a directory below itself, so the policy that
  # decides who sshd admits is two levels down. A check that looked only
  # at the immediate children would judge a configuration the container
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
  # Lexically inside the directory and not inside it at all. The string
  # is nobody's business here: sshd resolves the path and reports what
  # it found at the end of it.
  seed_guest_file /etc/ssh/sshd_config.d/10-site.conf \
    'Include /etc/ssh/sshd_config.d/../site-policy.conf
'
  seed_guest_file /etc/ssh/site-policy.conf 'AuthorizedKeysFile /etc/ssh/keys/%u
'
  run converge
  [ "${status}" -ne 0 ]
  [[ ${output} == *'/etc/ssh/keys/%u'* ]]
  [ ! -e "${ROOT}/etc/ssh/sshd_config.d/99-pve-config-admin.conf" ]
}

@test "an Include spelled in mixed case is read as the Include it is" {
  # sshd matches its keywords without regard to case, so this pulls the
  # file in exactly as `Include` would. A round of review found this
  # silently skipped, with the AuthorizedKeysFile behind it never
  # inspected; the run has to stop on what the file says.
  seed_guest_file /etc/ssh/site-policy.conf 'AuthorizedKeysFile /etc/ssh/keys/%u
'
  seed_guest_file /etc/ssh/sshd_config 'iNcLuDe /etc/ssh/site-policy.conf
Include /etc/ssh/sshd_config.d/*.conf
'
  run converge
  [ "${status}" -ne 0 ]
  [[ ${output} == *'/etc/ssh/keys/%u'* ]]
  [ ! -e "${ROOT}/etc/ssh/sshd_config.d/99-pve-config-admin.conf" ]
}

@test "a quoted Include operand is read rather than stopping the run" {
  # Quoting is sshd's parser's business and this no longer has an
  # opinion about it. The operand refused outright while this module
  # parsed; now the run stops on the AuthorizedKeysFile behind it, which
  # is a message only a followed Include can produce.
  seed_guest_file /etc/ssh/site-policy.conf 'AuthorizedKeysFile /etc/ssh/keys/%u
'
  seed_guest_file /etc/ssh/sshd_config 'Include "/etc/ssh/site-policy.conf"
'
  run converge
  [ "${status}" -ne 0 ]
  [[ ${output} == *'/etc/ssh/keys/%u'* ]]
  [ ! -e "${ROOT}/etc/ssh/sshd_config.d/99-pve-config-admin.conf" ]
}

@test "a mixed case Include already names the directory" {
  # The container's own configuration pulls the drop-ins in, spelled its
  # way. Its glob does cover the fragment, and the managed Include goes
  # in anyway: deciding that the glob covers this file means reading
  # OpenSSH's syntax, which is the thing this no longer does. The
  # container's own line is left exactly as it wrote it, and the second
  # run changes nothing, so no run after the first reloads sshd.
  seed_guest_file /etc/ssh/sshd_config 'iNcLuDe /etc/ssh/sshd_config.d/*.conf
'
  converge >/dev/null
  local first second
  first=$(guest_body /etc/ssh/sshd_config)
  [ "$(head -1 <<<"${first}")" = \
    'Include /etc/ssh/sshd_config.d/99-pve-config-admin.conf' ]
  grep -qx 'iNcLuDe /etc/ssh/sshd_config.d/\*.conf' <<<"${first}"
  converge >/dev/null
  second=$(guest_body /etc/ssh/sshd_config)
  [ "${first}" = "${second}" ]
}

@test "an Include operand with a backslash in it is read as sshd reads it" {
  # Probed against OpenSSH 10.2p1: the backslash is an escape, so this
  # names site-policy.conf and sshd loads it. A shell glob would not
  # have found it, which is the disagreement that made this refuse.
  seed_guest_file /etc/ssh/site-policy.conf 'AuthorizedKeysFile /etc/ssh/keys/%u
'
  seed_guest_file /etc/ssh/sshd_config 'Include /etc/ssh/site\-policy.conf
'
  run converge
  [ "${status}" -ne 0 ]
  [[ ${output} == *'/etc/ssh/keys/%u'* ]]
  [ ! -e "${ROOT}/etc/ssh/sshd_config.d/99-pve-config-admin.conf" ]
}

@test "a drop-in named with a backslash is loaded like any other" {
  # The name was refused while this module had to reproduce it. sshd
  # reaches it through *.conf without caring, so the run stops on what
  # is in it.
  seed_guest_file '/etc/ssh/sshd_config.d/10-si\te.conf' 'AuthorizedKeysFile /etc/ssh/keys/%u
'
  run converge
  [ "${status}" -ne 0 ]
  [[ ${output} == *'/etc/ssh/keys/%u'* ]]
  [ ! -e "${ROOT}/etc/ssh/sshd_config.d/99-pve-config-admin.conf" ]
}

@test "a drop-in whose name holds a newline is read, not skipped" {
  # `ls -1` cannot say this name and `read` cannot hear it, so a listing
  # would skip the file and approve the configuration without it --
  # while sshd loads it through *.conf like any other. Nothing lists the
  # directory now, so the name is never spoken and never has to be.
  seed_guest_file "/etc/ssh/sshd_config.d/10-site
policy.conf" 'AuthorizedKeysFile /etc/ssh/keys/%u
'
  run converge
  [ "${status}" -ne 0 ]
  [[ ${output} == *'/etc/ssh/keys/%u'* ]]
  [ ! -e "${ROOT}/etc/ssh/sshd_config.d/99-pve-config-admin.conf" ]
}

@test "a drop-in whose name begins with a newline is read, not skipped" {
  # The blank line a listing makes of this is skipped by a parse and by
  # a count alike, so it was the hardest of the three to notice.
  seed_guest_file "/etc/ssh/sshd_config.d/
policy.conf" 'AuthorizedKeysFile /etc/ssh/keys/%u
'
  run converge
  [ "${status}" -ne 0 ]
  [[ ${output} == *'/etc/ssh/keys/%u'* ]]
  [ ! -e "${ROOT}/etc/ssh/sshd_config.d/99-pve-config-admin.conf" ]
}

@test "a drop-in whose name ends with a newline is not a drop-in" {
  # Probed against OpenSSH 10.2p1: `Include dir/*.conf` does not match
  # `policy.conf\n`, because the name does not end in `.conf` -- the
  # newline does. So this is not configuration, and a run that stopped
  # for it stopped for nothing. Seeded with something that would stop
  # the run if it were loaded, so the pass is about the glob and not
  # about the file being empty.
  seed_guest_file "/etc/ssh/sshd_config.d/policy.conf
" 'AuthorizedKeysFile /etc/ssh/keys/%u
'
  converge >/dev/null
  grep -q 'PasswordAuthentication no' \
    "${ROOT}/etc/ssh/sshd_config.d/99-pve-config-admin.conf"
}

@test "a hidden entry beside the drop-ins is not loaded by the glob" {
  # Probed against OpenSSH 10.2p1: `Include dir/*.conf` does not match a
  # name beginning with a dot, so a hidden file beside the drop-ins is
  # not configuration and the run carries on. The name ends in `.conf`,
  # so only the leading dot keeps it out; seeded with something that
  # would stop the run if it were loaded, so the pass is about the glob
  # and not about the file being empty.
  seed_guest_file /etc/ssh/sshd_config.d/.10-site.conf 'AuthorizedKeysFile /etc/ssh/keys/%u
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

@test "DisableForwarding alone also stops the root lock" {
  # Probed against OpenSSH 10.2p1: DisableForwarding yes turns agent
  # forwarding off without changing what allowagentforwarding resolves
  # to, so reading only that keyword answers half the question and
  # locks root behind a daemon that will not carry the key sudo wants.
  export PVE_GUEST_ADMIN_ROOT_LOCK='yes'
  converge >/dev/null
  printf 'root:x:20000:0:99999:7:::\n' >"${ROOT}/etc/shadow"
  seed_guest_file /etc/ssh/sshd_config.d/10-site.conf 'DisableForwarding yes
'
  run guest_admin_root_lock "${GUEST}"
  [ "${status}" -ne 0 ]
  [[ ${output} == *'disableforwarding yes'* ]]
  run grep -q '^root:!' "${ROOT}/etc/shadow"
  [ "${status}" -ne 0 ]
}

@test "a Match block at the end of sshd_config does not swallow the fragment" {
  # Include is textual, so a candidate that appended an Include of this
  # fragment to the end of a file ending inside a Match block would put
  # the fragment inside that block: read for bob and for nobody else,
  # and absent from the dump. The Include goes where the drop-in
  # directory is read instead. A sshd_config with the Include at the top
  # and Match blocks at the bottom is the ordinary shape of the file.
  seed_guest_file /etc/ssh/sshd_config 'Include /etc/ssh/sshd_config.d/*.conf

Match User bob
	X11Forwarding yes
'
  converge >/dev/null
  grep -q 'PasswordAuthentication no' \
    "${ROOT}/etc/ssh/sshd_config.d/99-pve-config-admin.conf"
}

@test "the Include is added only after the fragment is in place" {
  seed_guest_file /etc/ssh/sshd_config 'PermitRootLogin yes
'
  converge >/dev/null
  grep -qx 'Include /etc/ssh/sshd_config.d/99-pve-config-admin.conf' \
    "${ROOT}/etc/ssh/sshd_config"
  [ -f "${ROOT}/etc/ssh/sshd_config.d/99-pve-config-admin.conf" ]
}

@test "an Include that does not cover the fragment still leaves sshd reading it" {
  # The container pulls in the drop-in directory, by a glob that does
  # not match this file. Asking whether the directory is mentioned says
  # yes; asking whether sshd reads the fragment says no. The second is
  # the question, and the answer to it is what gets asserted here: the
  # real configuration, put to sshd afterwards, resolves the hardening.
  seed_guest_file /etc/ssh/sshd_config 'Include /etc/ssh/sshd_config.d/*.cfg
PasswordAuthentication yes
'
  converge >/dev/null
  run env PVE_CONFIG_MOCK_GUEST_ROOT="${ROOT}" sshd -T -f /etc/ssh/sshd_config
  [ "${status}" -eq 0 ]
  [[ ${output} == *$'\npasswordauthentication no'* ]]
}

@test "an Include naming one other drop-in still leaves sshd reading the fragment" {
  # The same divergence in the shape that is easiest to miss: a literal
  # Include of a sibling drop-in mentions the directory without reaching
  # anything else in it.
  seed_guest_file /etc/ssh/sshd_config.d/10-site.conf 'X11Forwarding yes
'
  seed_guest_file /etc/ssh/sshd_config 'Include /etc/ssh/sshd_config.d/10-site.conf
PasswordAuthentication yes
'
  converge >/dev/null
  run env PVE_CONFIG_MOCK_GUEST_ROOT="${ROOT}" sshd -T -f /etc/ssh/sshd_config
  [ "${status}" -eq 0 ]
  [[ ${output} == *$'\npasswordauthentication no'* ]]
}

@test "the overlay sshd reads is byte for byte what converge leaves behind" {
  # The claim the whole mechanism rests on, stated as a comparison of
  # two directory trees rather than as an assertion about one file.
  # The overlay is built from the container as it stands before converge
  # and kept; converge then runs. If what sshd was asked about is what
  # converge installs, the kept overlay and the converged /etc/ssh are
  # identical: every name, every type, every mode, every byte. Three
  # review rounds found divergences here that a narrower check missed,
  # so this checks the lot -- including a managed fragment from an
  # earlier run, which the overlay has to replace rather than keep, and
  # a main file whose mode is not the default.
  seed_guest_file /etc/ssh/sshd_config.d/10-site.conf 'X11Forwarding yes
'
  seed_guest_file /etc/ssh/sshd_config.d/99-pve-config-admin.conf \
    'PasswordAuthentication yes
'
  seed_guest_file /etc/ssh/sshd_config 'Include /etc/ssh/sshd_config.d/*.cfg
PasswordAuthentication yes
'
  chmod 0600 "${ROOT}/etc/ssh/sshd_config"
  local fragment kept="${ROOT}/../overlay-before-converge"
  fragment=$(guest_admin_sshd_fragment)
  _guest_admin_sshd_stage "${GUEST}" "${fragment}"
  cp -a -- "${ROOT}/run/pve-config/sshd-check/etc-ssh" "${kept}"
  converge >/dev/null
  run diff -r "${kept}" "${ROOT}/etc/ssh"
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
  [ "$(cd -- "${kept}" && find . -printf '%P %y %m\n' | sort)" = \
    "$(cd -- "${ROOT}/etc/ssh" && find . -printf '%P %y %m\n' | sort)" ]
}

@test "an installed fragment the container also globs cannot mask a later setting" {
  # The overlay replaces the installed fragment in place rather than
  # adding a second copy ahead of it, so the stale one cannot be read
  # during judgement and then vanish on publishing. Here the container
  # redirects the keys below its own glob: with the old fragment still
  # resolving first the dump said .ssh/authorized_keys and the run went
  # ahead, while the daemon would have read /etc/ssh/keys/%u and ignored
  # every administrator key with passwords already off.
  seed_guest_file /etc/ssh/sshd_config.d/99-pve-config-admin.conf \
    'AuthorizedKeysFile .ssh/authorized_keys
'
  seed_guest_file /etc/ssh/sshd_config 'Include /etc/ssh/sshd_config.d/*.conf
AuthorizedKeysFile /etc/ssh/keys/%u
'
  run converge
  [ "${status}" -ne 0 ]
  [[ ${output} == *'/etc/ssh/keys/%u'* ]]
}

@test "the overlay is gone from the container once sshd has answered" {
  # Every mount lives in the namespace unshare made for the one command,
  # so nothing survives it. The record the mount mock keeps stands in
  # for the mount table, and it being gone is that namespace closing.
  converge >/dev/null
  [ ! -e "${ROOT}/run/pve-config/mock-mount-binds" ]
}

@test "a namespace the container refuses stops the hardening rather than passing" {
  # unshare refused for want of privilege exits 1, and 1 is also the
  # status that means sshd read the configuration and said no -- the one
  # answer that lets a run carry on. Nothing here may be read as that.
  export PVE_CONFIG_MOCK_UNSHARE_DENIED=1
  run converge
  [ "${status}" -ne 0 ]
  [[ ${output} == *'no mount namespace'* ]]
  [ ! -e "${ROOT}/etc/ssh/sshd_config.d/99-pve-config-admin.conf" ]
}

@test "a container with no unshare in it stops the hardening" {
  # No util-linux, no namespace, no way to ask sshd anything.
  export PVE_CONFIG_MOCK_UNSHARE_MISSING=1
  run converge
  [ "${status}" -ne 0 ]
  [[ ${output} == *'no mount namespace'* ]]
  [ ! -e "${ROOT}/etc/ssh/sshd_config.d/99-pve-config-admin.conf" ]
}

@test "a mount the kernel refuses stops the hardening" {
  # The namespace was made and the bind was not. sshd would then have
  # read the container's own configuration and very likely accepted it,
  # which is the false accept this must not reach.
  export PVE_CONFIG_MOCK_MOUNT_DENIED=1
  run converge
  [ "${status}" -ne 0 ]
  [[ ${output} == *'no mount namespace'* ]]
  [ ! -e "${ROOT}/etc/ssh/sshd_config.d/99-pve-config-admin.conf" ]
}

@test "a drop-in an earlier overlay left behind is not judged" {
  # cp -a merges into a directory that is already there, so an overlay
  # an interrupted run left in place would carry a drop-in the container
  # no longer has. Here that stale drop-in is the one thing pointing the
  # keys back at the home directory; the container itself sends them to
  # /etc/ssh/keys/%u, which ignores every administrator key.
  seed_guest_file /run/pve-config/sshd-check/etc-ssh/sshd_config.d/00-stale.conf \
    'AuthorizedKeysFile .ssh/authorized_keys
'
  seed_guest_file /etc/ssh/sshd_config 'Include /etc/ssh/sshd_config.d/*.conf
AuthorizedKeysFile /etc/ssh/keys/%u
'
  run converge
  [ "${status}" -ne 0 ]
  [[ ${output} == *'/etc/ssh/keys/%u'* ]]
  [ ! -e "${ROOT}/etc/ssh/sshd_config.d/99-pve-config-admin.conf" ]
}

@test "an earlier overlay that cannot be cleared stops the hardening" {
  export PVE_CONFIG_MOCK_PCT_FAIL_RM=/run/pve-config/sshd-check
  run converge
  [ "${status}" -ne 0 ]
  [[ ${output} == *'Unable to clear /run/pve-config/sshd-check'* ]]
  [ ! -e "${ROOT}/etc/ssh/sshd_config.d/99-pve-config-admin.conf" ]
}

# The copy keeps every symbolic link as a link, so what each one reaches
# inside the namespace is the kernel's business: an absolute target
# starts again from the root and goes back through the bind, a relative
# one starts from the link's own directory. Each of these hides the
# policy behind a different shape of link; the run stops only if sshd
# followed it to the end. Probed against OpenSSH 10.2p1 under a real
# bind, every one of them reaches the policy.
seed_link() {
  mkdir -p -- "$(dirname -- "${ROOT}$1")"
  ln -s -- "$2" "${ROOT}$1"
}

@test "a drop-in that is an absolute link is read where it points" {
  seed_guest_file /etc/ssh/site-policy.conf 'AuthorizedKeysFile /etc/ssh/keys/%u
'
  seed_link /etc/ssh/sshd_config.d/10-site.conf /etc/ssh/site-policy.conf
  run converge
  [ "${status}" -ne 0 ]
  [[ ${output} == *'/etc/ssh/keys/%u'* ]]
  [ ! -e "${ROOT}/etc/ssh/sshd_config.d/99-pve-config-admin.conf" ]
}

@test "a drop-in that is a relative link is read where it points" {
  seed_guest_file /etc/ssh/site-policy.conf 'AuthorizedKeysFile /etc/ssh/keys/%u
'
  seed_link /etc/ssh/sshd_config.d/10-site.conf ../site-policy.conf
  run converge
  [ "${status}" -ne 0 ]
  [[ ${output} == *'/etc/ssh/keys/%u'* ]]
  [ ! -e "${ROOT}/etc/ssh/sshd_config.d/99-pve-config-admin.conf" ]
}

@test "a drop-in linked to a file outside /etc/ssh is read where it points" {
  # Nothing outside /etc/ssh is overlaid, so this is the container's own
  # file, read as the daemon will read it.
  seed_guest_file /etc/site-policy.conf 'AuthorizedKeysFile /etc/ssh/keys/%u
'
  seed_link /etc/ssh/sshd_config.d/10-site.conf /etc/site-policy.conf
  run converge
  [ "${status}" -ne 0 ]
  [[ ${output} == *'/etc/ssh/keys/%u'* ]]
  [ ! -e "${ROOT}/etc/ssh/sshd_config.d/99-pve-config-admin.conf" ]
}

@test "a chain of absolute and relative links is followed to its end" {
  seed_guest_file /etc/ssh/site-policy.conf 'AuthorizedKeysFile /etc/ssh/keys/%u
'
  seed_link /etc/ssh/sshd_config.d/10-site.conf /etc/ssh/links/a.conf
  seed_link /etc/ssh/links/a.conf ../b.conf
  seed_link /etc/ssh/b.conf /etc/ssh/site-policy.conf
  run converge
  [ "${status}" -ne 0 ]
  [[ ${output} == *'/etc/ssh/keys/%u'* ]]
  [ ! -e "${ROOT}/etc/ssh/sshd_config.d/99-pve-config-admin.conf" ]
}

@test "an Include through a linked directory is read where it points" {
  seed_guest_file /etc/ssh/policy.d/10-site.conf 'AuthorizedKeysFile /etc/ssh/keys/%u
'
  seed_link /etc/ssh/site.d /etc/ssh/policy.d
  seed_guest_file /etc/ssh/sshd_config 'Include /etc/ssh/sshd_config.d/*.conf
Include /etc/ssh/site.d/*.conf
'
  run converge
  [ "${status}" -ne 0 ]
  [[ ${output} == *'/etc/ssh/keys/%u'* ]]
  [ ! -e "${ROOT}/etc/ssh/sshd_config.d/99-pve-config-admin.conf" ]
}

@test "a drop-in that is a link loop stops the hardening" {
  # The real sshd reports ELOOP and exits 1: a refusal, not an answer.
  seed_link /etc/ssh/sshd_config.d/10-loop.conf 10-loop.conf
  run converge
  [ "${status}" -ne 0 ]
  [[ ${output} == *'will not run the configuration'* ]]
  [[ ${output} == *'10-loop.conf: Too many levels of symbolic links'* ]]
  [ ! -e "${ROOT}/etc/ssh/sshd_config.d/99-pve-config-admin.conf" ]
}

@test "a linked sshd_config.d is refused before anything is judged" {
  # sshd itself follows the link. Converge would have to put the
  # fragment through it, which it refuses everywhere, and it refuses
  # before an overlay is built, so nothing is judged and nothing lands.
  seed_guest_file /etc/ssh/real.d/10-site.conf 'X11Forwarding yes
'
  rm -rf -- "${ROOT}/etc/ssh/sshd_config.d"
  seed_link /etc/ssh/sshd_config.d /etc/ssh/real.d
  run converge
  [ "${status}" -ne 0 ]
  [[ ${output} == *'Refusing to use the symlink /etc/ssh/sshd_config.d '* ]]
  [ ! -e "${ROOT}/etc/ssh/real.d/99-pve-config-admin.conf" ]
  run grep -q 'unshare -m' <(mock_calls)
  [ "${status}" -ne 0 ]
}

@test "a linked sshd_config is refused before anything is judged" {
  # As above: sshd follows it, and converge refuses to write through it.
  seed_guest_file /etc/ssh/main.conf 'Include /etc/ssh/sshd_config.d/*.conf
'
  rm -f -- "${ROOT}/etc/ssh/sshd_config"
  seed_link /etc/ssh/sshd_config /etc/ssh/main.conf
  run converge
  [ "${status}" -ne 0 ]
  [[ ${output} == *'Refusing to write through the symlink /run/pve-config/sshd-check/etc-ssh/sshd_config'* ]]
  [ ! -e "${ROOT}/etc/ssh/sshd_config.d/99-pve-config-admin.conf" ]
  [ "$(guest_body /etc/ssh/main.conf)" = 'Include /etc/ssh/sshd_config.d/*.conf' ]
  run grep -q 'unshare -m' <(mock_calls)
  [ "${status}" -ne 0 ]
}

@test "the hardening wins over a conflicting setting the container set first" {
  # Deliberate. The managed Include goes at the top, so the fragment is
  # read before whatever the container says lower down, and a scalar
  # keeps its first value. Before this, the same container aborted the
  # run because the earlier value won. The owner's requirement is that
  # passwords are off, so the hardening winning is the wanted answer.
  seed_guest_file /etc/ssh/sshd_config 'PasswordAuthentication yes
PermitRootLogin yes
Include /etc/ssh/sshd_config.d/*.conf
'
  converge >/dev/null
  run env PVE_CONFIG_MOCK_GUEST_ROOT="${ROOT}" sshd -T -f /etc/ssh/sshd_config
  [ "${status}" -eq 0 ]
  [[ ${output} == *$'\npasswordauthentication no'* ]]
  [[ ${output} == *$'\npermitrootlogin prohibit-password'* ]]
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

@test "the root password is not locked when nothing includes the hardening" {
  # The fragment is still there and still right; what has gone is the
  # line that makes sshd read it. Locking root on the strength of a file
  # the daemon never opens is the whole shape of defect this guards.
  export PVE_GUEST_ADMIN_ROOT_LOCK='yes'
  converge >/dev/null
  printf 'root:x:20000:0:99999:7:::\n' >"${ROOT}/etc/shadow"
  grep -vx 'Include /etc/ssh/sshd_config.d/99-pve-config-admin.conf' \
    "${ROOT}/etc/ssh/sshd_config" >"${ROOT}/etc/ssh/sshd_config.new"
  mv -- "${ROOT}/etc/ssh/sshd_config.new" "${ROOT}/etc/ssh/sshd_config"
  run guest_admin_root_lock "${GUEST}"
  [ "${status}" -ne 0 ]
  [[ ${output} == *'so sshd never reads the hardening'* ]]
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

@test "a container missing the managed Include is one publishing would change" {
  # What decides whether the reload marker goes down before anything is
  # written, so a run killed between the write and the reload is picked
  # up by the next one. Asking the same question the installer answers,
  # through the same transformation: a container whose configuration is
  # already what converge would write needs no marker, and one missing
  # the line that makes sshd read the fragment does.
  converge >/dev/null
  run _guest_admin_sshd_publish_changes "${GUEST}" "$(guest_admin_sshd_fragment)"
  [ "${status}" -eq 1 ]
  grep -vx 'Include /etc/ssh/sshd_config.d/99-pve-config-admin.conf' \
    "${ROOT}/etc/ssh/sshd_config" >"${ROOT}/etc/ssh/sshd_config.new"
  mv -- "${ROOT}/etc/ssh/sshd_config.new" "${ROOT}/etc/ssh/sshd_config"
  run _guest_admin_sshd_publish_changes "${GUEST}" "$(guest_admin_sshd_fragment)"
  [ "${status}" -eq 0 ]
}

@test "an Include inside a drop-in is followed where it points" {
  # A round of review found this noticed and not followed, so a
  # configuration with a piece missing was judged. It is sshd that
  # resolves it now, inside the container, against the container's own
  # filesystem.
  seed_guest_file /etc/ssh/site-policy.conf 'AuthorizedKeysFile /etc/ssh/keys/%u
'
  seed_guest_file /etc/ssh/sshd_config.d/10-site.conf \
    'Include /etc/ssh/site-policy.conf
'
  run converge
  [ "${status}" -ne 0 ]
  [[ ${output} == *'/etc/ssh/keys/%u'* ]]
  [ ! -e "${ROOT}/etc/ssh/sshd_config.d/99-pve-config-admin.conf" ]
}

@test "a container with no sshd in it stops the hardening" {
  # The only thing that can answer what the container's sshd will run is
  # the container's sshd. Nothing to ask is not a clean configuration,
  # and the fragment this module writes says PasswordAuthentication no.
  export PVE_CONFIG_MOCK_SSHD_MISSING=1
  run converge
  [ "${status}" -ne 0 ]
  # Told apart from a configuration sshd read and refused, which is the
  # distinction the status this returns exists to make.
  [[ ${output} == *'no sshd to ask'* ]]
  [ ! -e "${ROOT}/etc/ssh/sshd_config.d/99-pve-config-admin.conf" ]
}

@test "a configuration sshd refuses stops the run and says why" {
  # sshd ran and would not have it, which is a different answer from
  # sshd not being there, and reaches a different message.
  seed_guest_file /etc/ssh/sshd_config.d/10-site.conf 'NotAKeyword yes
'
  run converge
  [ "${status}" -ne 0 ]
  [[ ${output} == *'will not run the configuration'* ]]
  [[ ${output} == *'NotAKeyword'* ]]
  [ ! -e "${ROOT}/etc/ssh/sshd_config.d/99-pve-config-admin.conf" ]
}

@test "a dump pct cannot run stops the hardening rather than passing" {
  # The container says nothing this toolkit objects to, so the only
  # thing that can stop the run is the dump this knob breaks: a fixture
  # that failed a later gate would pass whatever the dump did.
  seed_guest_file /etc/ssh/sshd_config.d/10-site.conf 'LogLevel INFO
'
  # The two operands the dump hands its scripts, in that order, which no
  # other call in the run puts together.
  export PVE_CONFIG_MOCK_PCT_EXEC_FAIL='/run/pve-config/sshd-check/etc-ssh /etc/ssh'
  run converge
  [ "${status}" -ne 0 ]
  # Named in the diagnostic, so the run can be seen to have stopped at
  # the dump rather than somewhere later. Anchored on the die, because
  # the command is also logged before it runs, failed or not.
  [[ ${output} == *'pct could not run a command in '*'unshare -m'* ]]
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

@test "the sshd mock refuses what the real tool would refuse" {
  # Every status and message below was taken from OpenSSH 10.2p1, by
  # running the same inputs against /usr/sbin/sshd. A mock that answered
  # the right question for the right input while also accepting a wrong
  # one would be testing half of what it looks like it tests, and this
  # mock is the only thing standing between these tests and a parser
  # nobody here writes any more.
  local dir="${ROOT}/run/mock-check"
  mkdir -p -- "${dir}"
  printf 'PasswordAuthentication no\n' >"${dir}/good.conf"
  printf 'NotAKeyword yes\n' >"${dir}/bad.conf"
  printf 'Match User alice\n\tPort 2222\n' >"${dir}/inmatch.conf"
  printf 'HostKey /etc/ssh/nothing_here\n' >"${dir}/nokey.conf"
  printf 'Match Nosuchcrit x\n' >"${dir}/badmatch.conf"
  printf 'Match User\n' >"${dir}/shortmatch.conf"
  printf 'PasswordAuthentication no\n' >"${dir}/unreadable.conf"
  chmod 000 -- "${dir}/unreadable.conf"
  export PVE_CONFIG_MOCK_GUEST_ROOT="${ROOT}"

  # A configuration it will run, which is the only one of these that may
  # produce a dump at all.
  run sshd -T -f /run/mock-check/good.conf
  [ "${status}" -eq 0 ]
  [[ ${output} == *'passwordauthentication no'* ]]

  # An unknown CLI option: exit 1, and no dump.
  run sshd -T --no-such-option -f /run/mock-check/good.conf
  [ "${status}" -eq 1 ]
  [[ ${output} != *passwordauthentication* ]]

  # A -f naming nothing: exit 1.
  run sshd -T -f /run/mock-check/absent.conf
  [ "${status}" -eq 1 ]
  [[ ${output} != *passwordauthentication* ]]

  # An unknown keyword: exit 255, with the second line real sshd prints.
  run sshd -T -f /run/mock-check/bad.conf
  [ "${status}" -eq 255 ]
  [[ ${output} == *'Bad configuration option: NotAKeyword'* ]]
  [[ ${output} == *'terminating, 1 bad configuration options'* ]]

  # A keyword that is not allowed inside a Match block: exit 255.
  run sshd -T -f /run/mock-check/inmatch.conf
  [ "${status}" -eq 255 ]
  [[ ${output} == *'not allowed within a Match block'* ]]

  # A HostKey whose file is not there: exit 1, with nothing to serve.
  run sshd -T -f /run/mock-check/nokey.conf
  [ "${status}" -eq 1 ]
  [[ ${output} == *'no hostkeys available'* ]]

  # A Match line naming a criterion sshd has no such attribute for, and
  # one naming an attribute without the value it takes: exit 255 both
  # ways, with no connection asked about. Probed against OpenSSH 10.2p1.
  run sshd -T -f /run/mock-check/badmatch.conf
  [ "${status}" -eq 255 ]
  [[ ${output} == *'Unsupported Match attribute Nosuchcrit'* ]]

  run sshd -T -f /run/mock-check/shortmatch.conf
  [ "${status}" -eq 255 ]
  [[ ${output} == *'Missing Match criteria for User'* ]]

  # A -f this cannot read, as against one that is not there: the real
  # binary distinguishes the two and so does this.
  run sshd -T -f /run/mock-check/unreadable.conf
  [ "${status}" -eq 1 ]
  [[ ${output} == *'Permission denied'* ]]
}

@test "the unshare and mount mocks refuse what the real tools would refuse" {
  # Statuses and messages probed against util-linux 2.41, run under
  # `unshare -U -r` so an ordinary user has the privilege the container
  # has. A mock that accepted a call the real tool rejects would let a
  # test pass over production that cannot work.
  use_mocks
  local dir="${ROOT}/run/mock-ns"
  mkdir -p -- "${dir}/src"
  export PVE_CONFIG_MOCK_GUEST_ROOT="${ROOT}"

  # -m with something to run, which is the one form production asks for.
  run unshare -m printf 'ran\n'
  [ "${status}" -eq 0 ]
  [ "${output}" = 'ran' ]

  # An option this does not stand in for, and -m with nothing to run.
  # The real binary starts a login shell for the second, which a
  # harness has no use for; refusing is the stricter answer.
  run unshare --no-such-option true
  [ "${status}" -eq 1 ]
  [[ ${output} == *"unrecognized option '--no-such-option'"* ]]
  run unshare -m
  [ "${status}" -eq 1 ]

  # A bind outside a namespace has nowhere to go, and the real one needs
  # privilege this harness does not have either way.
  run mount --bind /run/mock-ns/src /run/mock-ns
  [ "${status}" -eq 32 ]

  # Inside the namespace the forms the real tool refuses still fail,
  # with the statuses it gives: 32 for a mount it could not make, 1 for
  # a command line it could not read.
  run unshare -m mount --bind /run/mock-ns/absent /run/mock-ns
  [ "${status}" -eq 32 ]
  [[ ${output} == *'does not exist'* ]]
  run unshare -m mount --bind /run/mock-ns/src /run/mock-ns/absent
  [ "${status}" -eq 32 ]
  [[ ${output} == *'mount point does not exist'* ]]
  run unshare -m mount --bind /run/mock-ns/src
  [ "${status}" -eq 1 ]
  [[ ${output} == *'Invalid argument'* ]]
  run unshare -m mount --bind /run/mock-ns/src /run/mock-ns one-too-many
  [ "${status}" -eq 1 ]
  [[ ${output} == *'bad usage'* ]]
  run unshare -m mount --no-such-option /run/mock-ns/src /run/mock-ns
  [ "${status}" -eq 1 ]
  [[ ${output} == *"unrecognized option '--no-such-option'"* ]]

  # A bind that works is recorded while the namespace is up, and the
  # record goes with it. That record is what the sshd mock resolves
  # paths through, so this is the mount being visible inside and
  # nowhere else.
  # shellcheck disable=SC2016 # $1 and $2 are the inner shell's arguments
  run unshare -m /bin/sh -c 'mount --bind "$1" /etc/ssh && cat "$2"' \
    pve-config /run/mock-ns/src "${ROOT}/run/pve-config/mock-mount-binds"
  [ "${status}" -eq 0 ]
  [ "${output}" = $'/run/mock-ns/src\t/etc/ssh' ]
  [ ! -e "${ROOT}/run/pve-config/mock-mount-binds" ]
}

@test "the sshd mock follows links through the namespace as the kernel does" {
  # Each case was run through real OpenSSH 10.2p1 under a real bind in
  # `unshare -U -r -m`, and the mock has to give the same answer. Asked
  # directly, because through production the overlay and the container
  # hold the same links, which hides a mock that consults the mount
  # table only once.
  use_mocks
  export PVE_CONFIG_MOCK_GUEST_ROOT="${ROOT}"
  local ov="${ROOT}/run/pve-config/sshd-check/etc-ssh"
  mkdir -p -- "${ov}"
  printf '%s\t%s\n' /run/pve-config/sshd-check/etc-ssh /etc/ssh \
    >"${ROOT}/run/pve-config/mock-mount-binds"
  printf 'AuthorizedKeysFile /site/0\n' >"${ov}/site.conf"

  # The container's own file is not what the overlay holds at that name.
  # An absolute link is resolved from the root and back through the
  # bind, so it reads the overlay's target.
  printf 'AuthorizedKeysFile /live/0\n' >"${ROOT}/etc/ssh/abs.conf"
  printf 'Include /etc/ssh/abs.conf\n' >"${ov}/sshd_config"
  ln -s /etc/ssh/site.conf "${ov}/abs.conf"
  run sshd -T
  [ "${status}" -eq 0 ]
  [[ ${output} == *$'authorizedkeysfile /site/0\n'* ]]

  # A loop is ELOOP, which sshd reports and exits 1 on.
  printf 'Include /etc/ssh/loop.conf\n' >"${ov}/sshd_config"
  ln -s /etc/ssh/loop.conf "${ov}/loop.conf"
  run sshd -T
  [ "${status}" -eq 1 ]
  [ "${output}" = '/etc/ssh/loop.conf: Too many levels of symbolic links' ]

  # A dangling link is found, as lstat finds it, and cannot be opened.
  printf 'Include /etc/ssh/gone.conf\n' >"${ov}/sshd_config"
  ln -s /etc/ssh/nothing.conf "${ov}/gone.conf"
  run sshd -T
  [ "${status}" -eq 1 ]
  [ "${output}" = '/etc/ssh/gone.conf: No such file or directory' ]

  # A loop on the way to an operand means nothing is found there.
  printf 'Include /etc/ssh/ld/x.conf\n' >"${ov}/sshd_config"
  ln -s /etc/ssh/ld "${ov}/ld"
  run sshd -T
  [ "${status}" -eq 0 ]
  [[ ${output} == *$'authorizedkeysfile .ssh/authorized_keys .ssh/authorized_keys2\n'* ]]

  # A glob skips a directory it reaches, linked or not, and `..` after a
  # link climbs from where the link led.
  mkdir -p -- "${ov}/g/05-dir.conf" "${ov}/deep/x"
  ln -s /etc/ssh/deep "${ov}/g/06-dl.conf"
  ln -s /etc/ssh/deep/x "${ov}/up"
  printf 'AuthorizedKeysFile /deep/0\n' >"${ov}/deep/site.conf"
  printf 'Include /etc/ssh/g/*.conf\nInclude /etc/ssh/up/../site.conf\n' \
    >"${ov}/sshd_config"
  run sshd -T
  [ "${status}" -eq 0 ]
  [[ ${output} == *$'authorizedkeysfile /deep/0\n'* ]]
  # Skipped, not opened: the real one says nothing about either.
  [[ ${output} != *'directory'* ]]
}
