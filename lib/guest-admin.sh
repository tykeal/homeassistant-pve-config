#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
# SPDX-License-Identifier: Apache-2.0

# Mirroring the host's administrators into a container.
#
# A container this toolkit builds is part of the deployment, not a black
# box: the people who administer the node administer it too. This module
# gives the administrators named by PVE_ADMIN_USERS the same access inside
# a guest that phase 1 gives them on the host -- an account, their own
# keys, sshd that accepts nothing else, and sudo that a forwarded agent
# satisfies -- and it reaches the guest entirely through lib/target.sh, so
# the reasoning is the host's and only the plumbing differs.
#
# The one public entry point is guest_admin_converge, which takes a target.
# Nothing here knows what the container is for: the Tailscale router and
# the Frigate container ask for the same thing in the same way.
#
# Two orderings in here are load bearing, and both exist because this
# module takes a way in away:
#
#   * password authentication is disabled only after the keys that replace
#     it have been read back out of the container and found to be ones
#     sshd would accept;
#   * the root password is locked only after the hardened sshd is running
#     and that access has been confirmed a second time, against what is
#     actually installed rather than against what was written.
#
# Both of those wait on a third: the container is only reachable where
# PVE_GUEST_ADMIN_SSH_ACCESS says it should be, read back out of the
# running packet filter. A restriction that could not be applied, or could
# not be confirmed, stops the run before anything else is taken away.
#
# Everything that asks the container a question answers in three values:
# yes, no, and "the container could not be read", which aborts. A guest
# that cannot be read is never taken for a guest that needs changing.

GUEST_ADMIN_PACKAGES=(sudo openssh-server libpam-ssh-agent-auth nftables)

GUEST_ADMIN_AGENT_KEYS_PATH='/etc/security/authorized_keys'
GUEST_ADMIN_PAM_SUDO_PATH='/etc/pam.d/sudo'
GUEST_ADMIN_PAM_SUDO_I_PATH='/etc/pam.d/sudo-i'
GUEST_ADMIN_PAM_MATCH='pam_ssh_agent_auth\.so'
GUEST_ADMIN_PAM_LINE='auth sufficient pam_ssh_agent_auth.so file=/etc/security/authorized_keys'
GUEST_ADMIN_SUDOERS_PATH='/etc/sudoers.d/90-ssh-agent'
GUEST_ADMIN_SSHD_DIR='/etc/ssh/sshd_config.d'
GUEST_ADMIN_SSHD_PATH='/etc/ssh/sshd_config.d/99-pve-config-admin.conf'
GUEST_ADMIN_SSHD_MAIN='/etc/ssh/sshd_config'
GUEST_ADMIN_SSHD_INCLUDE='Include /etc/ssh/sshd_config.d/*.conf'
GUEST_ADMIN_SSHD_INCLUDE_MATCH='^[[:space:]]*[Ii][Nn][Cc][Ll][Uu][Dd][Ee][[:space:]]+.*sshd_config\.d'
GUEST_ADMIN_SSH_UNIT='ssh.service'
GUEST_ADMIN_STATE_DIR='/var/lib/pve-config'
GUEST_ADMIN_SSHD_RELOAD_MARKER='/var/lib/pve-config/sshd-reload-pending'
GUEST_ADMIN_PROFILE_PATH='/etc/profile.d/pve-config-term.sh'
GUEST_ADMIN_BASHRC_PATH='/etc/bash.bashrc'
GUEST_ADMIN_BASHRC_MATCH='pve-config-term\.sh'
GUEST_ADMIN_BASHRC_LINE='[ -f /etc/profile.d/pve-config-term.sh ] && . /etc/profile.d/pve-config-term.sh'

# The tailnet's own address space: 100.64.0.0/10 for IPv4, which Tailscale
# allocates out of the carrier-grade NAT range, and fd7a:115c:a1e0::/48 for
# IPv6. An AllowUsers pattern qualified with these admits a connection that
# arrived over the tunnel and no other.
GUEST_ADMIN_TAILNET_CIDRS=('100.64.0.0/10' 'fd7a:115c:a1e0::/48')
GUEST_ADMIN_TAILNET_V4='100.64.0.0/10'
GUEST_ADMIN_TAILNET_V6='fd7a:115c:a1e0::/48'

# The packet filter. Its own table, because nftables evaluates every table
# and a drop in any of them ends the packet: this can restrict ssh without
# owning, reading or disturbing whatever else the container filters.
GUEST_ADMIN_NFT_TABLE='pve_config_admin'
GUEST_ADMIN_NFT_DIR='/etc/nftables.d'
GUEST_ADMIN_NFT_PATH='/etc/nftables.d/pve-config-admin.nft'
GUEST_ADMIN_NFT_MAIN='/etc/nftables.conf'
GUEST_ADMIN_NFT_INCLUDE='include "/etc/nftables.d/*.nft"'
# Only this module's own wildcard include. A pattern that matched every
# include naming that directory would have target_ensure_exact_line
# replace an operator's `include "/etc/nftables.d/site.rules"` with this
# one, and `*.nft` does not load `site.rules`: their firewall would go
# away at the next reboot without anything having said so.
GUEST_ADMIN_NFT_INCLUDE_MATCH='^[[:space:]]*include[[:space:]]+"?/etc/nftables\.d/\*\.nft"?[[:space:]]*$'
GUEST_ADMIN_NFT_UNIT='nftables.service'
GUEST_ADMIN_SSH_PORT='22'

# --- the administrators ---------------------------------------------------

_guest_admin_users() {
  local -a users=()
  mapfile -t users < <(admin_users)
  [[ ${#users[@]} -gt 0 ]] || die 'PVE_ADMIN_USERS resolved to no usernames.'
  printf '%s\n' "${users[@]}"
}

# Every administrator's keys, one per line, in the order they are
# configured. Used for the file pam_ssh_agent_auth reads as root.
_guest_admin_all_keys() {
  local user keys out=''
  while IFS= read -r user; do
    [[ -n ${user} ]] || continue
    keys=$(admin_keys_for "${user}")
    [[ -n ${keys} ]] || die "No SSH public key resolved for ${user}."
    out+="${keys%$'\n'}"$'\n'
  done < <(_guest_admin_users)
  printf '%s' "${out}"
}

# --- packages -------------------------------------------------------------

# sudo, sshd and the PAM module, in one apt transaction. The package lists
# are refreshed only when something is actually missing: a converged
# container should not reach the network at all.
guest_admin_packages() {
  local target=$1 pkg
  local -a missing=()
  for pkg in "${GUEST_ADMIN_PACKAGES[@]}"; do
    target_pkg_is_installed "${target}" "${pkg}" || missing+=("${pkg}")
  done
  if [[ ${#missing[@]} -eq 0 ]]; then
    printf 'unchanged\n'
    return 0
  fi
  target_apt_update "${target}"
  target_pkg_install "${target}" "${GUEST_ADMIN_PACKAGES[@]}"
}

# --- accounts and their keys ----------------------------------------------

# The guest's copy of authorized_keys_install: the same merge, the same
# modes, the same refusal to install a key ssh-keygen has not accepted,
# reached through pct instead of through the filesystem.
guest_admin_keys_install() {
  local target=$1 user=$2 keys=$3
  local home ssh_dir file uid='' gid='' changed=0 state existing='' merged

  target_user_uid uid "${target}" "${user}" || uid=''
  target_user_gid gid "${target}" "${user}" || gid=''
  target_user_home home "${target}" "${user}" || home="/home/${user}"
  ssh_dir="${home}/.ssh"
  file="${ssh_dir}/authorized_keys"

  state_of state target_ensure_dir "${target}" "${home}" '' "${uid}" "${gid}"
  if [[ ${state} == changed ]]; then
    changed=1
  fi
  # StrictModes is on by default: sshd ignores authorized_keys under a home
  # anybody else can write to.
  state_of state target_ensure_not_group_other_writable "${target}" "${home}"
  if [[ ${state} == changed ]]; then
    changed=1
  fi
  state_of state target_ensure_dir "${target}" "${ssh_dir}" 0700 "${uid}" "${gid}"
  if [[ ${state} == changed ]]; then
    changed=1
  fi

  target_slurp existing "${target}" "${file}" || existing=''
  _authorized_keys_merged merged "${existing}" "${keys}" "${user}"

  state_of state target_write_file "${target}" "${file}" "${merged}" 0600
  if [[ ${state} == changed ]]; then
    changed=1
  fi
  state_of state target_ensure_owner "${target}" "${file}" "${uid}" "${gid}"
  if [[ ${state} == changed ]]; then
    changed=1
  fi

  if [[ ${changed} -eq 1 ]]; then
    printf 'changed\n'
  else
    printf 'unchanged\n'
  fi
}

guest_admin_users_converge() {
  local target=$1 user keys changed=0 state
  while IFS= read -r user; do
    [[ -n ${user} ]] || continue
    keys=$(admin_keys_for "${user}")
    [[ -n ${keys} ]] || die "No SSH public key resolved for ${user}."

    state_of state target_user_converge "${target}" "${user}" /bin/bash
    if [[ ${state} == changed ]]; then
      changed=1
    fi
    state_of state target_user_join_group "${target}" "${user}" sudo
    if [[ ${state} == changed ]]; then
      changed=1
    fi
    state_of state guest_admin_keys_install "${target}" "${user}" "${keys}"
    if [[ ${state} == changed ]]; then
      changed=1
    fi
  done < <(_guest_admin_users)

  if [[ ${changed} -eq 1 ]]; then
    printf 'changed\n'
  else
    printf 'unchanged\n'
  fi
}

# --- sudo through a forwarded agent ---------------------------------------

guest_admin_sudo_converge() {
  local target=$1 changed=0 state

  # One file holding every administrator's key. pam_ssh_agent_auth reads it
  # as root, so it is deliberately not any individual's authorized_keys.
  state_of state target_ensure_dir "${target}" /etc/security 0755
  if [[ ${state} == changed ]]; then
    changed=1
  fi
  local agent_keys
  agent_keys=$(_guest_admin_all_keys) ||
    die "Unable to resolve the administrators' SSH keys."
  state_of state target_write_file "${target}" "${GUEST_ADMIN_AGENT_KEYS_PATH}" \
    "${agent_keys}" 0600
  if [[ ${state} == changed ]]; then
    changed=1
  fi

  # Exactly one active line, wherever a previous run or a hand edit left
  # one. The script this productizes used `sed -i '1a ...'`, which stacked
  # another copy on top on every single invocation, and a PAM stack with
  # the module in it twice is the bug this whole module is shaped around.
  state_of state target_ensure_exact_line "${target}" "${GUEST_ADMIN_PAM_SUDO_PATH}" \
    "${GUEST_ADMIN_PAM_MATCH}" "${GUEST_ADMIN_PAM_LINE}" after-first
  if [[ ${state} == changed ]]; then
    changed=1
  fi

  state_of state _guest_admin_pam_sudo_i "${target}"
  if [[ ${state} == changed ]]; then
    changed=1
  fi

  state_of state target_ensure_dir "${target}" /etc/sudoers.d 0755
  if [[ ${state} == changed ]]; then
    changed=1
  fi
  # visudo on the host passes judgement before anything is pushed: a
  # sudoers file the container rejects is a container nobody can sudo in,
  # and sudo reads the whole directory, so one bad drop-in breaks the lot.
  state_of state target_install_validated "${target}" "${GUEST_ADMIN_SUDOERS_PATH}" \
    '# Managed by pve-config.
Defaults env_keep += "SSH_AUTH_SOCK"
' 0440 validate_sudoers_file
  if [[ ${state} == changed ]]; then
    changed=1
  fi

  if [[ ${changed} -eq 1 ]]; then
    printf 'changed\n'
  else
    printf 'unchanged\n'
  fi
}

# The same line in the stack `sudo -i` reads, and deliberately not a
# symlink to the stack `sudo` reads.
#
# The issue this implements asked for /etc/pam.d/sudo-i to be linked to
# /etc/pam.d/sudo, on the assumption that the two are equivalent. In Debian
# they are not. The sudo package ships both files and they differ in their
# session stack: sudo ends with `@include common-session-noninteractive`
# and sudo-i with `@include common-session`, because `sudo -i` starts a
# login shell and the full session stack is what registers it -- pam_systemd
# gives it a logind session and an XDG_RUNTIME_DIR, and the non-interactive
# stack does not. (Verified against the trixie source package, sudo
# 1.9.16p2-3+deb13u2, debian/etc/pam.d/sudo and debian/etc/pam.d/sudo-i.)
# Replacing sudo-i with a link to sudo would quietly take that away, and a
# PAM file is not something to discard on an assumption.
#
# So the agent line is converged into sudo-i the same way it is converged
# into sudo: exactly one copy, the rest of the file untouched.
#
# A sudo-i that is already a symlink to sudo is a container somebody has
# made that choice for; the line in sudo covers it and it is left alone. A
# symlink to anything else is refused rather than followed, and a sudo-i
# that does not exist is left absent: a file holding nothing but an auth
# line is a PAM stack with no account or session modules, which is worse
# than the fallback sudo already has.
_guest_admin_pam_sudo_i() {
  local target=$1 current=''

  if target_test "${target}" L "${GUEST_ADMIN_PAM_SUDO_I_PATH}"; then
    target_capture current "${target}" readlink -- "${GUEST_ADMIN_PAM_SUDO_I_PATH}" ||
      die "Unable to read where ${GUEST_ADMIN_PAM_SUDO_I_PATH} points in $(target_describe "${target}")"
    case ${current} in
      "${GUEST_ADMIN_PAM_SUDO_PATH}" | sudo)
        log_info "${GUEST_ADMIN_PAM_SUDO_I_PATH} already points at ${GUEST_ADMIN_PAM_SUDO_PATH} in $(target_describe "${target}")"
        printf 'unchanged\n'
        return 0
        ;;
      *)
        die "${GUEST_ADMIN_PAM_SUDO_I_PATH} in $(target_describe "${target}") is a symlink to ${current}; this toolkit will not write through it."
        ;;
    esac
  fi

  if ! target_test "${target}" f "${GUEST_ADMIN_PAM_SUDO_I_PATH}"; then
    log_warn "${GUEST_ADMIN_PAM_SUDO_I_PATH} does not exist in $(target_describe "${target}"); leaving sudo -i to whatever PAM falls back to"
    printf 'unchanged\n'
    return 0
  fi

  target_ensure_exact_line "${target}" "${GUEST_ADMIN_PAM_SUDO_I_PATH}" \
    "${GUEST_ADMIN_PAM_MATCH}" "${GUEST_ADMIN_PAM_LINE}" after-first
}

# --- a usable terminal under pct enter ------------------------------------

# `pct enter` attaches without a terminal description, which leaves TERM
# unset or `dumb` and with it an editor that cannot clear the screen. The
# script this productizes appended the fix to /etc/bash.bashrc on every
# run; this one writes a profile snippet and keeps exactly one line
# sourcing it.
guest_admin_term_converge() {
  local target=$1 changed=0 state

  # shellcheck disable=SC2016  # the guest's shell expands these, not this one
  state_of state target_write_file "${target}" "${GUEST_ADMIN_PROFILE_PATH}" \
    '# Managed by pve-config.
# pct enter attaches with no terminal description of its own.
case "${TERM:-}" in
  "" | dumb | unknown) TERM=xterm-256color ;;
esac
export TERM
' 0644
  if [[ ${state} == changed ]]; then
    changed=1
  fi

  # /etc/profile is read by a login shell, and `pct enter` starts one that
  # is not. The interactive startup file is where that session finds it.
  state_of state target_ensure_exact_line "${target}" "${GUEST_ADMIN_BASHRC_PATH}" \
    "${GUEST_ADMIN_BASHRC_MATCH}" "${GUEST_ADMIN_BASHRC_LINE}" append
  if [[ ${state} == changed ]]; then
    changed=1
  fi

  if [[ ${changed} -eq 1 ]]; then
    printf 'changed\n'
  else
    printf 'unchanged\n'
  fi
}

# --- reaching sshd at all -------------------------------------------------

# A packet filter in the container, so that `tailnet` means what it says.
#
# AllowUsers is an authorization control: sshd still listens on every
# address, still completes the TCP handshake and still runs the
# pre-authentication protocol with anything on the LAN that can reach the
# container, and only then declines to authenticate. The reachability this
# deployment asked for is an exposure property -- a pre-authentication flaw
# in sshd should not be reachable from the LAN at all -- and only something
# below sshd can give it. AllowUsers stays as the layer above.
#
# Three mechanisms were considered:
#
#   * sshd's own ListenAddress, bound to the tailnet address. Closest to a
#     true bind, and unusable here: the address does not exist until the
#     container has joined the tunnel, sshd refuses to start without it,
#     and deferring the bind means restarting sshd at the one moment a
#     mistake cannot be recovered from over the network.
#   * The Proxmox container firewall. Host-side and beyond the reach of
#     anything that goes wrong inside the guest, which is a real
#     advantage, but it is inert unless the node and datacenter firewalls
#     are switched on. Turning on a node-wide default-drop as a side
#     effect of configuring one container is exactly the class of change
#     that locks an operator out of a live node, and it is not this
#     stage's to make.
#   * nftables inside the container, which is what this does. It is
#     self-contained, it needs nothing switched on anywhere else, it is
#     independent of what sshd binds to, and it is applied, read back and
#     verified through the same pct target as everything else here. The
#     cost is that it is inside the guest: a root user in the container
#     can undo it. That is an acceptable trade for a container whose root
#     password this module is about to lock, and the verification before
#     the hardening would notice it gone on the next run.
#
# The rules live in a table of this module's own. The chain's policy is
# accept and the only drop in it is for ssh from off-tailnet, so a
# container that filters nothing still filters nothing else.
guest_admin_firewall_fragment() {
  printf '%s\n' \
    '#!/usr/sbin/nft -f' \
    '# Managed by pve-config. Reachability of sshd, not authorization.' \
    "table inet ${GUEST_ADMIN_NFT_TABLE} {}" \
    "delete table inet ${GUEST_ADMIN_NFT_TABLE}" \
    "table inet ${GUEST_ADMIN_NFT_TABLE} {" \
    '	chain input {' \
    '		type filter hook input priority filter; policy accept;' \
    '		iif "lo" accept' \
    "		ip saddr ${GUEST_ADMIN_TAILNET_V4} tcp dport ${GUEST_ADMIN_SSH_PORT} accept" \
    "		ip6 saddr ${GUEST_ADMIN_TAILNET_V6} tcp dport ${GUEST_ADMIN_SSH_PORT} accept" \
    "		tcp dport ${GUEST_ADMIN_SSH_PORT} drop" \
    '	}' \
    '}'
}

# One rule, reduced to the matchers and the verdict that decide whether a
# packet gets in.
#
# This reads nft's text output rather than the JSON of `nft -j`. JSON
# would be the more stable interface and the choice here is not an
# argument that it would not: it was rejected only because decoding it
# means a perl JSON program, this toolkit already carries three
# near-identical ones (_ACME_JSON_PROGRAM, _TAILSCALE_JSON_PROGRAM,
# _HAOS_JSON_PROGRAM), none of them answers a question shaped like this
# one, and a fourth copy would deepen a duplication the owner has already
# raised. Whoever consolidates those should revisit this with the shared
# decoder in hand.
#
# What the text form actually varies in was measured against nftables
# 1.1.6 rather than guessed, and tests/fixtures/nft holds what it printed.
# nft normalises more than it is given credit for: `tcp dport ssh` prints
# as `tcp dport 22`, an address written FD7A:115C:A1E0:0000:: prints as
# fd7a:115c:a1e0::, and `priority 0` prints as `priority filter`. What it
# does not normalise away is what this strips below -- a counter in the
# middle of a rule and a comment at the end of one -- plus its own choice
# of spacing.
#
# Getting that wrong has a direction. A ruleset this module no longer
# recognises stops the run, so a counter ticking on a converged container
# would abort a deployment that is configured exactly right. Taking the
# rendering out first compares the decision rather than the printout.
_guest_admin_nft_rule_normalise() {
  local rule=$1
  local -a __nft_words=()
  # Everything from `comment` on is annotation.
  rule=${rule%% comment \"*}
  # Counters print wherever they were written; this module writes none, so
  # any that appear were added to a rule it otherwise still recognises.
  rule=$(sed -E 's/ counter packets [0-9]+ bytes [0-9]+//g' <<<"${rule}")
  # Whitespace is nft's to choose.
  read -r -a __nft_words <<<"${rule}"
  printf '%s' "${__nft_words[*]}"
}

# Whether a printed copy of this module's table really restricts ssh.
#
# An allowlist, not a search for the pieces. Checking that the required
# rules are present somewhere answers a different question from whether
# the chain does what it was written to do: a `tcp dport 22 accept` ahead
# of the tailnet rules contains every required piece and admits the whole
# LAN, and a jump somewhere else hides whatever it jumps to.
#
# So the chain has to be the one this module writes, rule for rule, in
# order, with nothing else in it. That is defensible only because this
# module owns the table outright -- it creates it, replaces it wholesale
# and deletes it -- so a chain that is not the written one is not a
# variation to be understood, it is a table that has been edited and that
# the next load will replace. Reporting "not restricted" there is both
# true and convergent: the fragment is reloaded and this is asked again.
#
# The sequence, after the chain header:
#
#   1. optionally the loopback accept
#   2. the IPv4 tailnet accept, exactly
#   3. the IPv6 tailnet accept, exactly
#   4. the ssh deny, exactly
#
# and then the chain ends.
_guest_admin_firewall_rules_restrict() {
  local body=$1 line trimmed
  local chains=0 in_chain=0 saw_header=0 step=0 closed=0

  local lo_rule='iif "lo" accept'
  local lo_rule_alt='iifname "lo" accept'
  local v4_rule="ip saddr ${GUEST_ADMIN_TAILNET_V4} tcp dport ${GUEST_ADMIN_SSH_PORT} accept"
  local v6_rule="ip6 saddr ${GUEST_ADMIN_TAILNET_V6} tcp dport ${GUEST_ADMIN_SSH_PORT} accept"

  while IFS= read -r line; do
    trimmed=${line#"${line%%[![:space:]]*}"}
    trimmed=${trimmed%"${trimmed##*[![:space:]]}"}
    [[ -n ${trimmed} ]] || continue

    if [[ ${in_chain} -eq 0 ]]; then
      if [[ ${trimmed} == 'chain '*'{' ]]; then
        chains=$((chains + 1))
        # This module writes one chain and owns the table, so a second
        # one is a table this cannot speak for.
        [[ ${chains} -eq 1 && ${trimmed} == 'chain input {' ]] || return 1
        in_chain=1
      fi
      continue
    fi

    if [[ ${trimmed} == '}' ]]; then
      in_chain=0
      closed=1
      continue
    fi

    trimmed=$(_guest_admin_nft_rule_normalise "${trimmed}")

    if [[ ${saw_header} -eq 0 ]]; then
      # The hook is what decides whether these rules see an arriving
      # packet at all, and the policy is what the rest of the container's
      # traffic meets.
      [[ ${trimmed} == 'type filter hook input priority '*'; policy accept;' ]] || return 1
      saw_header=1
      continue
    fi

    case ${step} in
      0)
        # The loopback accept is optional only in the sense that a
        # container that never had it is still restricted; this module
        # writes it.
        if [[ ${trimmed} == "${lo_rule}" || ${trimmed} == "${lo_rule_alt}" ]]; then
          step=1
          continue
        fi
        [[ ${trimmed} == "${v4_rule}" ]] || return 1
        step=2
        ;;
      1)
        [[ ${trimmed} == "${v4_rule}" ]] || return 1
        step=2
        ;;
      2)
        [[ ${trimmed} == "${v6_rule}" ]] || return 1
        step=3
        ;;
      3)
        # drop and reject both stop the connection, and nftables 1.1.6
        # prints back whichever one is loaded. This module writes drop;
        # reading a reject as "not restricted" would abort a container
        # whose ssh is unreachable from the LAN, which is the property
        # being asked about.
        case ${trimmed} in
          "tcp dport ${GUEST_ADMIN_SSH_PORT} drop" | \
            "tcp dport ${GUEST_ADMIN_SSH_PORT} reject" | \
            "tcp dport ${GUEST_ADMIN_SSH_PORT} reject with "*) ;;
          *) return 1 ;;
        esac
        step=4
        ;;
      *)
        # A rule after the deny cannot re-admit ssh, but it is not a rule
        # this module wrote, so the chain is not the one it wrote.
        return 1
        ;;
    esac
  done <<<"${body}"

  [[ ${saw_header} -eq 1 && ${closed} -eq 1 && ${step} -eq 4 ]] || return 1
  return 0
}

# Whether the running ruleset restricts ssh to the tailnet.
#
#   0  it does
#   1  it does not
#   2  the container did not answer in a way this can be read
#
# The running ruleset is what decides, not the file that was pushed: a
# file nothing has loaded restricts nothing. Only this module's own table
# is asked for, so a rule that happens to exist in somebody else's table
# cannot answer for one that does not exist in this one.
_guest_admin_firewall_live() {
  local target=$1 table='' present=0

  _guest_admin_firewall_table table "${target}" || present=$?
  case ${present} in
    0) ;;
    1) return 1 ;;
    *) return 2 ;;
  esac

  _guest_admin_firewall_rules_restrict "${table}" || return 1
  return 0
}

# Whether this module's own table exists at all, and its body when it
# does.
#
#   0  it exists, and __body_var holds what nft printed
#   1  it does not exist
#   2  the container did not answer in a way this can be read
#
# Asked separately from whether the table restricts anything, because the
# two questions have different consequences: a table whose rules are not
# the ones this module writes still has to be taken away when the
# configuration stops asking for a restriction, and reading "no
# restriction" off an existing table would leave it in place while
# reporting the container open.
_guest_admin_firewall_table() {
  # The output variable is named by the caller, and lib/target.sh names
  # its own locals with a leading double underscore, so every local here
  # avoids both conventions rather than shadowing one of them.
  local __body_var=$1 fw_target=$2 fw_raw='' fw_status=0

  target_capture fw_raw "${fw_target}" nft list table inet "${GUEST_ADMIN_NFT_TABLE}" || fw_status=$?
  if [[ ${fw_status} -ne 0 ]]; then
    # A table that is not there and a kernel that will not answer both
    # fail here, and they mean opposite things. They are told apart by a
    # question that does not depend on the table: if the whole ruleset
    # lists, nft is working and the table is simply absent.
    local fw_ruleset='' fw_probe=0
    target_capture fw_ruleset "${fw_target}" nft list ruleset || fw_probe=$?
    if [[ ${fw_probe} -ne 0 ]]; then
      log_error "nft list failed in $(target_describe "${fw_target}"): ${fw_ruleset}"
      return 2
    fi
    printf -v "${__body_var}" '%s' ''
    return 1
  fi

  printf -v "${__body_var}" '%s' "${fw_raw}"
  return 0
}

# Dies unless the container's reachability is what the configuration asked
# for, right now, as the kernel in it has it.
#
# This is the gate the sshd hardening and the root password lock both wait
# behind. An unreadable answer aborts: a container that cannot say whether
# it is exposed is not one to take another way in away from.
_guest_admin_firewall_confirmed() {
  local target=$1 access=${PVE_GUEST_ADMIN_SSH_ACCESS:-lan} state=0

  # Where the LAN is allowed in, the question is whether this module's
  # table is gone, not whether its rules restrict: a table left behind
  # with rules this module did not write can block ssh just as
  # thoroughly, and reading its rules as "not restricted" is how a
  # container ends up unreachable while the run reports success.
  if [[ ${access} != tailnet ]]; then
    local body=''
    _guest_admin_firewall_table body "${target}" || state=$?
    case ${state} in
      1) return 0 ;;
      0)
        die "$(target_describe "${target}") still has the ${GUEST_ADMIN_NFT_TABLE} table, which PVE_GUEST_ADMIN_SSH_ACCESS=${access} does not ask for; refusing to go on until that is lifted."
        ;;
      *)
        die "Unable to read the packet filter in $(target_describe "${target}"); refusing to go on with hardening it."
        ;;
    esac
  fi

  _guest_admin_firewall_live "${target}" || state=$?
  case ${state} in
    2)
      die "Unable to read the packet filter in $(target_describe "${target}"); refusing to go on with hardening it."
      ;;
    0) return 0 ;;
    *)
      die "$(target_describe "${target}") does not restrict ssh to the tailnet; refusing to go on with hardening it."
      ;;
  esac
}

# Puts the container's ssh reachability where the configuration asks for
# it, and loads it.
#
# The file is both what a reboot reloads and what this compares against;
# the running ruleset is loaded from it only when something is actually
# out of place, so a converged container is never reconfigured.
guest_admin_firewall_converge() {
  local target=$1 access=${PVE_GUEST_ADMIN_SSH_ACCESS:-lan}
  local changed=0 state live=0

  if [[ ${access} != tailnet ]]; then
    _guest_admin_firewall_unrestrict "${target}"
    return
  fi

  state_of state target_ensure_dir "${target}" "${GUEST_ADMIN_NFT_DIR}" 0755
  if [[ ${state} == changed ]]; then
    changed=1
  fi

  local fragment
  fragment=$(guest_admin_firewall_fragment) ||
    die "Unable to decide how $(target_describe "${target}") should restrict ssh."
  state_of state target_write_file "${target}" "${GUEST_ADMIN_NFT_PATH}" \
    "${fragment}" 0644
  if [[ ${state} == changed ]]; then
    changed=1
  fi

  # Appended rather than prepended: Debian's own /etc/nftables.conf starts
  # with `flush ruleset`, and an include above that would be thrown away
  # the moment the file it is in gets to its second line.
  state_of state target_ensure_exact_line "${target}" "${GUEST_ADMIN_NFT_MAIN}" \
    "${GUEST_ADMIN_NFT_INCLUDE_MATCH}" "${GUEST_ADMIN_NFT_INCLUDE}" append
  if [[ ${state} == changed ]]; then
    changed=1
  fi

  state_of state target_service_enable "${target}" "${GUEST_ADMIN_NFT_UNIT}"
  if [[ ${state} == changed ]]; then
    changed=1
  fi

  if dry_run_enabled; then
    log_info "would restrict ssh in $(target_describe "${target}") to the tailnet"
    printf 'changed\n'
    return 0
  fi

  # What this run loads and what the container loads at boot are two
  # different things. Loading the fragment by itself says nothing about
  # whether nftables.service can read /etc/nftables.conf and everything
  # it includes -- and one unrelated malformed file in that directory
  # takes the whole configuration down with it, so a container that is
  # restricted now would come back from a reboot restricting nothing at
  # all. The boot configuration is checked as a whole, and a container
  # whose restriction would not survive a restart is not one to take a
  # password away from.
  local check='' check_rc=0
  target_capture check "${target}" nft -c -f "${GUEST_ADMIN_NFT_MAIN}" || check_rc=$?
  [[ ${check_rc} -eq 0 ]] ||
    die "${GUEST_ADMIN_NFT_MAIN} in $(target_describe "${target}") does not load, so the ssh restriction would not survive a reboot: ${check}"

  _guest_admin_firewall_live "${target}" || live=$?
  case ${live} in
    0) ;;
    1)
      target_run "${target}" nft -f "${GUEST_ADMIN_NFT_PATH}" ||
        die "Unable to load ${GUEST_ADMIN_NFT_PATH} in $(target_describe "${target}")"
      log_info "restricted ssh in $(target_describe "${target}") to the tailnet"
      changed=1
      ;;
    *)
      die "Unable to read the packet filter in $(target_describe "${target}"); refusing to guess at what it allows."
      ;;
  esac

  # Loading it is not the same claim as it being loaded.
  _guest_admin_firewall_confirmed "${target}"

  if [[ ${changed} -eq 1 ]]; then
    printf 'changed\n'
  else
    printf 'unchanged\n'
  fi
}

# Takes the restriction away again, for a container the configuration says
# the LAN may reach. Convergent in both directions: a container moved from
# tailnet to lan has to stop being restricted, or the setting is a lie.
_guest_admin_firewall_unrestrict() {
  local target=$1 changed=0 state live=0

  state_of state target_remove_path "${target}" "${GUEST_ADMIN_NFT_PATH}"
  if [[ ${state} == changed ]]; then
    changed=1
  fi

  if dry_run_enabled; then
    log_info "would stop restricting ssh in $(target_describe "${target}") to the tailnet"
    printf '%s\n' "${state}"
    return 0
  fi

  # Presence, not shape. A table whose rules are not the ones this module
  # writes is still this module's table, and still filters ssh; deciding
  # by whether it currently restricts would leave exactly those rules in
  # place and call the container reachable.
  local body=''
  _guest_admin_firewall_table body "${target}" || live=$?
  case ${live} in
    1) ;;
    0)
      target_run "${target}" nft delete table inet "${GUEST_ADMIN_NFT_TABLE}" ||
        die "Unable to remove the ssh restriction from $(target_describe "${target}")"
      log_info "stopped restricting ssh in $(target_describe "${target}") to the tailnet"
      changed=1
      ;;
    *)
      die "Unable to read the packet filter in $(target_describe "${target}"); refusing to guess at what it allows."
      ;;
  esac

  _guest_admin_firewall_confirmed "${target}"

  if [[ ${changed} -eq 1 ]]; then
    printf 'changed\n'
  else
    printf 'unchanged\n'
  fi
}

# --- sshd -----------------------------------------------------------------

# The hardening fragment this container is to be given.
guest_admin_sshd_fragment() {
  local access=${PVE_GUEST_ADMIN_SSH_ACCESS:-lan}
  local user cidr allow=''
  while IFS= read -r user; do
    [[ -n ${user} ]] || continue
    if [[ ${access} == tailnet ]]; then
      # Qualified with the tailnet's address space rather than bound to the
      # tailnet interface: an address the container has not been given yet
      # is one sshd refuses to start on, and a container is configured
      # before it joins the tunnel.
      for cidr in "${GUEST_ADMIN_TAILNET_CIDRS[@]}"; do
        allow+=" ${user}@${cidr}"
      done
    else
      allow+=" ${user}"
    fi
  done < <(_guest_admin_users)
  [[ -n ${allow} ]] || die 'No administrator to admit to the container.'

  printf '%s\n' '# Managed by pve-config.' \
    'PubkeyAuthentication yes' \
    'PasswordAuthentication no' \
    'KbdInteractiveAuthentication no' \
    'PermitRootLogin prohibit-password' \
    "AllowUsers${allow}"
}

# The container's own name for the drop-in directory, with every symlink
# resolved. Asked of the container, because the question is what sshd in
# it would open.
_guest_admin_sshd_dir_canon() {
  local target=$1 canon=''
  target_capture canon "${target}" readlink -f -- "${GUEST_ADMIN_SSHD_DIR}" ||
    return 1
  canon=${canon%$'\n'}
  [[ -n ${canon} ]] || return 1
  printf '%s' "${canon}"
}

# Whether an Include operand names something inside the mirrored drop-in
# directory, as the container resolves it.
#
# Three things are asked, and all three have to hold:
#
#   * the operand is absolute and lexically inside the directory, which
#     is cheap and rejects the obvious;
#   * no component of it is `..`, because `/etc/ssh/sshd_config.d/../x`
#     is lexically inside the directory and is not inside it at all;
#   * the part of it that is a real directory resolves, in the container,
#     to that directory or something under it. A string comparison cannot
#     see a symlink; this asks the filesystem sshd will ask.
#
# A path that will not resolve is a failure, not a pass: the caller dies
# on anything but 0.
_guest_admin_sshd_include_ok() {
  local operand=$1 target=$2 canon_dir=$3
  local probe canon=''

  # Only a plain, unquoted path. sshd's own parser handles quoting,
  # backslash escapes and whitespace inside operands, and every attempt
  # here to reproduce that has missed something; refusing what this
  # cannot read with certainty is the recoverable direction. Issue #30
  # replaces this whole surface with `sshd -T`, which is sshd's parser
  # rather than an imitation of it, and lifts the restriction.
  [[ ${operand} == *[!A-Za-z0-9/._*?-]* ]] && return 1
  [[ ${operand} == "${GUEST_ADMIN_SSHD_DIR}"/* ]] || return 1
  [[ ${operand} == */../* || ${operand} == */.. ]] && return 1

  # The longest leading part of the path with no wildcard in it, which is
  # the deepest directory that can be resolved rather than matched.
  probe=${operand%/*}
  while [[ ${probe} == *[\*\?\[]* ]]; do
    probe=${probe%/*}
    [[ -n ${probe} ]] || return 1
  done

  target_capture canon "${target}" readlink -f -- "${probe}" || return 1
  canon=${canon%$'\n'}
  [[ -n ${canon} ]] || return 1
  [[ ${canon} == "${canon_dir}" || ${canon} == "${canon_dir}"/* ]] || return 1
  return 0
}

# Dies unless every Include in this body names the mirrored drop-in
# directory.
#
# Only a configuration whose Includes all name that directory can be
# reproduced on this host, and a configuration that cannot be reproduced
# cannot be judged. Refusing is the fail-closed answer: the alternative is
# approving a fragment against a configuration that is missing whatever
# the other Include supplies -- an AllowUsers, an AuthorizedKeysFile, a
# Match block -- and then disabling password authentication against it.
#
# Asked of every file that is mirrored, not only of the main one: an
# Include nests, and sshd resolves each one against the container. What
# makes "inside the directory" enough is that the mirror below copies the
# whole of that directory, subdirectories included, so an operand that
# resolves inside it names something this host is holding a copy of.
_guest_admin_sshd_includes_local() {
  local body=$1 origin=$2 target=$3 dir=$4 canon_dir=$5
  local line trimmed keyword operand
  local -a operands=()

  while IFS= read -r line || [[ -n ${line} ]]; do
    trimmed=${line#"${line%%[![:space:]]*}"}
    keyword=${trimmed%%[[:space:]]*}
    # sshd reads its keywords without regard to case, so `iNcLuDe` pulls
    # a file in exactly as `Include` does. A matcher that only knew the
    # two usual spellings would walk straight past it.
    [[ ${keyword,,} == include ]] || continue
    read -r -a operands <<<"${trimmed#"${keyword}"}"
    for operand in ${operands[@]+"${operands[@]}"}; do
      _guest_admin_sshd_include_ok "${operand}" "${target}" "${canon_dir}" && continue
      rm -rf -- "${dir}"
      die "${origin} in $(target_describe "${target}") includes ${operand}, which this toolkit cannot resolve inside ${GUEST_ADMIN_SSHD_DIR}; it cannot tell what that file does to the configuration and will not harden sshd without knowing."
    done
  done <<<"${body}"
}

# Copies one directory of the container's sshd configuration into the
# mirror, and everything below it.
#
# Recursive because Include is: a drop-in naming
# `/etc/ssh/sshd_config.d/site/*.conf` is a drop-in whose real policy
# lives a directory down, and a mirror that stopped at the immediate
# children would hold a configuration the container is not running --
# then approve a fragment against it and lock the root password.
_guest_admin_sshd_mirror_dir() {
  local target=$1 dir=$2 rel=$3 depth=$4 canon_dir=$5
  local guest="${GUEST_ADMIN_SSHD_DIR}${rel}"
  local listing='' listing_rc=0 name body='' own

  if [[ ${depth} -gt 8 ]]; then
    rm -rf -- "${dir}"
    die "The sshd drop-in directory in $(target_describe "${target}") nests deeper than this toolkit will follow; refusing to judge a configuration it cannot read in full."
  fi

  # A listing that failed is not an empty directory. Taking it for one
  # would approve a fragment against a mirror that is missing whatever
  # could not be listed.
  # -A because a name beginning with a dot is still a name: sshd's own
  # glob does not load one (probed against OpenSSH 10.2p1: a
  # `.hidden.conf` beside a `normal.conf` is not picked up by
  # `Include dir/*.conf`), but an Include naming it outright does load
  # it, so the copy has to hold it either way.
  target_capture listing "${target}" ls -1A -- "${guest}" || listing_rc=$?
  if [[ ${listing_rc} -ne 0 ]]; then
    rm -rf -- "${dir}"
    die "Unable to list ${guest} in $(target_describe "${target}"); refusing to judge a configuration that cannot be read in full."
  fi

  # A name with a newline in it is two lines in `ls -1` output and two
  # names to `read`, neither of which exists -- so the file would be
  # skipped and the mirror would be approved without it, while sshd
  # loads it through `*.conf` as happily as any other. The count below
  # cannot be fooled that way: one character per entry, whatever the
  # name contains. Supporting such a name rather than refusing it needs
  # a NUL-safe way to carry a guest command's output back (issue #26);
  # until then this fails in the recoverable direction.
  local marks='' marks_rc=0
  target_capture marks "${target}" \
    find "${guest}" -mindepth 1 -maxdepth 1 -printf . || marks_rc=$?
  if [[ ${marks_rc} -ne 0 ]]; then
    rm -rf -- "${dir}"
    die "Unable to count the entries of ${guest} in $(target_describe "${target}"); refusing to judge a configuration that cannot be read in full."
  fi
  marks=${marks//[^.]/}

  # A name with a control character in it cannot survive the trip out of
  # the container, and the count above cannot see one whose newline sits
  # at either end: an empty line is skipped and a trailing one is eaten
  # by the capture. This asks the container about the names themselves,
  # so it holds whatever the name happens to be.
  local control='' control_rc=0
  target_capture control "${target}" \
    find "${guest}" -mindepth 1 -maxdepth 1 -regextype posix-extended \
    -regex '.*[[:cntrl:]].*' -printf . || control_rc=$?
  if [[ ${control_rc} -ne 0 ]]; then
    rm -rf -- "${dir}"
    die "Unable to examine the entry names of ${guest} in $(target_describe "${target}"); refusing to judge a configuration that cannot be read in full."
  fi
  control=${control//[^.]/}
  if [[ -n ${control} ]]; then
    rm -rf -- "${dir}"
    die "${guest} in $(target_describe "${target}") holds an entry whose name contains a control character; nothing here can carry that name out of the container intact (issue #26), so the configuration cannot be copied or judged."
  fi

  own=$(basename -- "${GUEST_ADMIN_SSHD_PATH}")
  local parsed=0
  while IFS= read -r name; do
    [[ -n ${name} ]] || continue
    parsed=$((parsed + 1))
    # A plain name, or nothing. A quote, a space or a backslash in a
    # drop-in filename turns every later step -- the glob an Include
    # resolves, the path pushed back into the container -- into a guess
    # about somebody else's parser. Issue #30 removes the need to guess.
    if [[ ${name} == *[!A-Za-z0-9._-]* || ${name} == -* ]]; then
      rm -rf -- "${dir}"
      die "${guest}/${name} in $(target_describe "${target}") has a name this toolkit will not reason about; rename it to letters, digits, dots, dashes and underscores, or remove it, before hardening sshd."
    fi
    [[ -z ${rel} && ${name} == "${own}" ]] && continue
    if target_test "${target}" d "${guest}/${name}"; then
      mkdir -p -- "${dir}${guest}/${name}" || {
        rm -rf -- "${dir}"
        die "Unable to stage ${guest}/${name} from $(target_describe "${target}")"
      }
      _guest_admin_sshd_mirror_dir "${target}" "${dir}" "${rel}/${name}" \
        "$((depth + 1))" "${canon_dir}"
      continue
    fi
    target_test "${target}" f "${guest}/${name}" || continue
    target_slurp body "${target}" "${guest}/${name}" || body=''
    # A drop-in can include too, and sshd resolves what it names from
    # the container's filesystem. One naming a path outside the
    # mirrored directory is a file this host never copied and never
    # judged.
    _guest_admin_sshd_includes_local "${body}" "${guest}/${name}" \
      "${target}" "${dir}" "${canon_dir}"
    printf '%s' "${body}" >"${dir}${guest}/${name}" || {
      rm -rf -- "${dir}"
      die "Unable to stage ${guest}/${name} from $(target_describe "${target}")"
    }
  done <<<"${listing}"

  if [[ ${parsed} -ne ${#marks} ]]; then
    rm -rf -- "${dir}"
    die "${guest} in $(target_describe "${target}") holds ${#marks} entries but only ${parsed} of them have names this toolkit can read back; a name with a newline in it cannot be carried across (issue #26), and a configuration that cannot be copied in full cannot be judged."
  fi
}

# Copies the container's sshd configuration onto this host, and prints the
# directory it put it in.
#
# Everything that judges an sshd configuration in this toolkit reads it
# from a filesystem, under $(sysroot). A container's is read out through
# pct, so it is staged here and $(sysroot) is pointed at the staging
# directory for the duration: the container is then judged by the host's
# code, on the container's own bytes.
#
# A file that exists and cannot be read aborts the run rather than being
# treated as absent, in target_slurp.
_guest_admin_sshd_mirror() {
  local target=$1 fragment=$2 __dir_var=$3
  local dir main_body=''

  dir=$(_validation_dir) ||
    die "Unable to create a directory to examine the sshd configuration of $(target_describe "${target}")"
  mkdir -p -- "${dir}${GUEST_ADMIN_SSHD_DIR}" || {
    rm -rf -- "${dir}"
    die "Unable to stage the sshd configuration of $(target_describe "${target}")"
  }

  if target_test "${target}" f "${GUEST_ADMIN_SSHD_MAIN}"; then
    target_slurp main_body "${target}" "${GUEST_ADMIN_SSHD_MAIN}" || main_body=''
  fi

  # Asked whether the directory is there or not: `readlink -f` resolves a
  # path whose last component does not exist yet, and a container that
  # has not been given the directory still ships an sshd_config that
  # includes it. Resolving both sides the same way is what makes the
  # containment check below a comparison of paths rather than of strings.
  local canon_dir=''
  canon_dir=$(_guest_admin_sshd_dir_canon "${target}") || {
    rm -rf -- "${dir}"
    die "Unable to resolve ${GUEST_ADMIN_SSHD_DIR} in $(target_describe "${target}"); refusing to judge a configuration it cannot read in full."
  }

  _guest_admin_sshd_includes_local "${main_body}" "${GUEST_ADMIN_SSHD_MAIN}" \
    "${target}" "${dir}" "${canon_dir}"

  # Every file in the directory, not only *.conf, and every directory
  # under it: an Include naming `site-policy`, `*.cfg` or `site/*.conf`
  # pulls in whatever it names.
  if target_test "${target}" d "${GUEST_ADMIN_SSHD_DIR}"; then
    _guest_admin_sshd_mirror_dir "${target}" "${dir}" '' 0 "${canon_dir}"
  fi

  printf '%s' "${fragment}" >"${dir}${GUEST_ADMIN_SSHD_PATH}" || {
    rm -rf -- "${dir}"
    die "Unable to stage the sshd fragment for $(target_describe "${target}")"
  }

  # The Include is added to the container only after the fragment has
  # validated and installed, exactly as phase 1 does it on the host. Here
  # it stands in for the configuration sshd will read once that has
  # happened.
  if ! grep -Eq "${GUEST_ADMIN_SSHD_INCLUDE_MATCH}" <<<"${main_body}"; then
    main_body="${GUEST_ADMIN_SSHD_INCLUDE}"$'\n'"${main_body}"
  fi
  printf '%s' "${main_body}" >"${dir}${GUEST_ADMIN_SSHD_MAIN}" || {
    rm -rf -- "${dir}"
    die "Unable to stage ${GUEST_ADMIN_SSHD_MAIN} from $(target_describe "${target}")"
  }

  printf -v "${__dir_var}" '%s' "${dir}"
}

# Dies unless the only port this container's sshd answers on is the one
# the packet filter protects.
#
# The restriction this module writes names tcp port 22 and nothing else.
# A configuration that moves sshd to another port, or adds a second
# listener on one, is reachable from the LAN through a port no rule
# covers -- while every check here reports the container restricted to
# the tailnet. Rather than grow the ruleset to follow a configuration
# this module does not own, a port it cannot vouch for stops the run.
#
# Only asked where the restriction is what makes the container safe to
# harden: with the LAN admitted there is no claim being made about which
# ports answer it.
_guest_admin_sshd_ports_guard() {
  local target=$1 mirror=$2 access=${PVE_GUEST_ADMIN_SSH_ACCESS:-lan}
  [[ ${access} == tailnet ]] || return 0

  local main="${mirror}${GUEST_ADMIN_SSHD_MAIN}"
  [[ -f ${main} ]] || return 0

  local file criteria keyword value port display
  while IFS=$'\x1f' read -r file criteria keyword value; do
    port=''
    case ${keyword} in
      port) port=${value%%[[:space:]]*} ;;
      listenaddress)
        # ListenAddress is `host`, `host:port`, `[v6]:port`, each with an
        # optional `rdomain NAME` after it. A bare IPv6 address has
        # colons and no port, which is why the bracketed form is the only
        # one a colon is read as a port separator in.
        local operand=${value%%[[:space:]]*}
        case ${operand} in
          \[*\]:*) port=${operand##*]:} ;;
          *:*:*) port='' ;;
          *:*) port=${operand##*:} ;;
        esac
        ;;
      *) continue ;;
    esac
    [[ -n ${port} ]] || continue
    [[ ${port} == "${GUEST_ADMIN_SSH_PORT}" ]] && continue
    display=${file#"${mirror}"}
    if [[ -n ${criteria} ]]; then
      die "${display} in $(target_describe "${target}") puts sshd on port ${port} under 'Match ${criteria}', which the tailnet restriction does not cover; refusing to report it restricted."
    fi
    die "${display} in $(target_describe "${target}") puts sshd on port ${port}, which the tailnet restriction does not cover; refusing to report it restricted."
  done < <(_sshd_config_directives "${main}" "${mirror}" "${mirror}")
  return 0
}

# Dies unless this fragment would leave every administrator able to log in.
#
# Asked of the whole assembled configuration rather than of the fragment,
# because an AllowUsers or an AuthorizedKeysFile somewhere else in the
# container's configuration decides the answer and the fragment cannot see
# it. The mirror is this host's copy of the container's files, so the paths
# in any complaint are rewritten back to the ones the container knows.
_guest_admin_sshd_admits() {
  local target=$1 mirror=$2
  local main="${mirror}${GUEST_ADMIN_SSHD_MAIN}" user groups raw reason
  local -a pairs=()

  while IFS= read -r user; do
    [[ -n ${user} ]] || continue
    # A group file that cannot be read is not an account with no groups.
    # Taking it for one would have an AllowGroups or a DenyGroups judged
    # against an empty list, which admits every administrator no matter
    # what the configuration says about them.
    raw=$(target_user_groups "${target}" "${user}") ||
      die "Unable to read the groups ${user} belongs to in $(target_describe "${target}"); refusing to judge who its sshd would admit."
    groups=$(printf '%s\n' "${raw}" | paste -sd, -)
    pairs+=("${user}" "${groups}")
  done < <(_guest_admin_users)

  _guest_admin_sshd_ports_guard "${target}" "${mirror}"

  if ! reason=$(sshd_authorized_keys_problem "${main}" "${mirror}" "${mirror}" "${mirror}"); then
    die "In $(target_describe "${target}"): ${reason}"
  fi
  if ! reason=$(sshd_admission_problem "${main}" "${mirror}" "${mirror}" "${mirror}" \
    ${pairs[@]+"${pairs[@]}"}); then
    die "In $(target_describe "${target}"): ${reason}"
  fi
}

# Dies unless every administrator's configured key is installed, active and
# unrestricted in the container right now.
#
# Read back out of the container rather than inferred from what was just
# written: a push that reported success and a file that holds the keys are
# not the same claim, and this one is the one that matters before password
# authentication goes away.
_guest_admin_keys_live() {
  local target=$1 user keys body='' reason
  while IFS= read -r user; do
    [[ -n ${user} ]] || continue
    target_user_exists "${target}" "${user}" ||
      die "${user} has no account in $(target_describe "${target}"); refusing to disable password authentication there."
    local home
    target_user_home home "${target}" "${user}" || home="/home/${user}"
    target_slurp body "${target}" "${home}/.ssh/authorized_keys" ||
      die "${user} has no ${home}/.ssh/authorized_keys in $(target_describe "${target}"); refusing to disable password authentication there."
    keys=$(admin_keys_for "${user}")
    reason=$(authorized_keys_access_problem "${body}" "${keys}" "${user}" \
      "${home}/.ssh/authorized_keys in $(target_describe "${target}")" \
      'refusing to disable password authentication there') && continue
    die "${reason}"
  done < <(_guest_admin_users)
}

# Installs the fragment with sshd's own judgement of the configuration the
# container will be running.
#
# Everything in this toolkit that judges an sshd configuration reads it
# from a filesystem under $(sysroot). The mirror is the container's
# configuration on this host, so sysroot is pointed at it for the duration
# of the install: the container is then judged by the host's code, on the
# container's own bytes, by the host's sshd binary. The assignment is a
# local, so it is the container's for exactly as long as this call.
_guest_admin_sshd_install() {
  local target=$1 fragment=$2 mirror=$3
  # shellcheck disable=SC2034  # read by sysroot, in everything called below
  local PVE_CONFIG_ROOT=${mirror}
  target_install_validated "${target}" "${GUEST_ADMIN_SSHD_PATH}" \
    "${fragment}" 0644 validate_sshd_config
}

# Whether publishing the hardening would change what sshd reads.
#
#   0  it would
#   1  it would not
#
# Asked before anything is written, so the reload marker can go down ahead
# of the change it is there to survive. A container that is already
# converged is left entirely alone, marker included.
_guest_admin_sshd_publish_changes() {
  local target=$1 fragment=$2 installed='' main_body=''

  target_slurp installed "${target}" "${GUEST_ADMIN_SSHD_PATH}" || return 0
  [[ ${installed} == "${fragment}" ]] || return 0
  target_slurp main_body "${target}" "${GUEST_ADMIN_SSHD_MAIN}" || return 0
  grep -Eq "${GUEST_ADMIN_SSHD_INCLUDE_MATCH}" <<<"${main_body}" || return 0
  return 1
}

# Installs the hardening fragment, having first established that doing so
# leaves every administrator able to get in.
guest_admin_sshd_converge() {
  local target=$1 fragment mirror='' changed=0 state include_state=unchanged

  fragment=$(guest_admin_sshd_fragment) ||
    die "Unable to decide who $(target_describe "${target}") should admit."

  state_of state target_ensure_dir "${target}" "${GUEST_ADMIN_SSHD_DIR}" 0755
  if [[ ${state} == changed ]]; then
    changed=1
  fi

  _guest_admin_sshd_mirror "${target}" "${fragment}" mirror

  # The gate. Nothing below this point can be undone from outside the
  # container, so everything that could refuse has already refused.
  if dry_run_enabled; then
    log_info "would check that every administrator can log in to $(target_describe "${target}") with a key before disabling passwords"
  else
    _guest_admin_keys_live "${target}"
    _guest_admin_sshd_admits "${target}" "${mirror}"
    # And that the container is only reachable where it was meant to be.
    # Hardening a container that is still exposed to the LAN would leave
    # the exposure in place behind a configuration that claims otherwise.
    _guest_admin_firewall_confirmed "${target}"
  fi

  # A run that is interrupted between writing the fragment and reloading
  # leaves the daemon on the old policy, and the next run finds every file
  # already correct and would skip the reload -- and then confirm access
  # against files rather than against the daemon, and lock the root
  # password against a container whose running sshd may admit nobody. The
  # marker is published before the fragment and removed only after the
  # reload, so an interruption anywhere in between is still visible on the
  # next run. Phase 1 does the same thing on the host, at
  # stages/phase1/70-ssh-sudo.sh.
  local pending=0
  if ! dry_run_enabled && target_test "${target}" f "${GUEST_ADMIN_SSHD_RELOAD_MARKER}"; then
    pending=1
    changed=1
  fi

  if [[ ${pending} -eq 0 ]] && ! dry_run_enabled &&
    _guest_admin_sshd_publish_changes "${target}" "${fragment}"; then
    target_ensure_dir "${target}" "${GUEST_ADMIN_STATE_DIR}" 0755 >/dev/null
    target_write_file "${target}" "${GUEST_ADMIN_SSHD_RELOAD_MARKER}" \
      'pending'$'\n' 0644 >/dev/null
    pending=1
  fi

  # Not a subshell: a refusal in there is a die, and a die in a subshell
  # is a message nobody acts on and a run that carries on hardening.
  state_of state _guest_admin_sshd_install "${target}" "${fragment}" "${mirror}"
  rm -rf -- "${mirror}"
  if [[ ${state} == changed ]]; then
    changed=1
  fi

  # sshd only reads a fragment when the main configuration includes one,
  # and the Include is added after the fragment is in place: publishing it
  # first would make every other file in that directory live.
  local main_body=''
  target_slurp main_body "${target}" "${GUEST_ADMIN_SSHD_MAIN}" || main_body=''
  if ! grep -Eq "${GUEST_ADMIN_SSHD_INCLUDE_MATCH}" <<<"${main_body}"; then
    state_of include_state target_ensure_exact_line "${target}" \
      "${GUEST_ADMIN_SSHD_MAIN}" "${GUEST_ADMIN_SSHD_INCLUDE_MATCH}" \
      "${GUEST_ADMIN_SSHD_INCLUDE}" prepend
    if [[ ${include_state} == changed ]]; then
      changed=1
    fi
  fi

  state_of state target_service_enable "${target}" "${GUEST_ADMIN_SSH_UNIT}"
  if [[ ${state} == changed ]]; then
    changed=1
  fi
  state_of state target_service_start "${target}" "${GUEST_ADMIN_SSH_UNIT}"
  if [[ ${state} == changed ]]; then
    # Started, so it read the new policy on the way up and there is
    # nothing stale left to reload.
    changed=1
  elif [[ ${changed} -eq 1 || ${pending} -eq 1 ]]; then
    # A daemon that was already running is holding the old policy.
    # Reloaded rather than restarted: a container reached over this very
    # tunnel should not have its connections dropped to pick up a file.
    target_service_reload "${target}" "${GUEST_ADMIN_SSH_UNIT}" >/dev/null
  fi

  if [[ ${pending} -eq 1 ]]; then
    target_remove_path "${target}" "${GUEST_ADMIN_SSHD_RELOAD_MARKER}" >/dev/null
  fi

  if [[ ${changed} -eq 1 ]]; then
    printf 'changed\n'
  else
    printf 'unchanged\n'
  fi
}

# --- the root password ----------------------------------------------------

# Whether root's password is locked in the container.
#
#   0  locked, nothing to do
#   1  usable or absent, and this module locks it
#   2  the container did not answer in a way this can be read
#
# `passwd -S` reports the status in its second field: L for a locked
# password, P for a usable one, NP for none at all. Anything else is a
# container this cannot speak for, and a guess either way is wrong: locking
# on a misread takes away an access path, and skipping on a misread leaves
# a password on an account that is now reachable from the tailnet.
_guest_admin_root_lock_state() {
  local target=$1 out='' status=0
  target_capture out "${target}" passwd -S root || status=$?
  if [[ ${status} -ne 0 ]]; then
    log_error "passwd -S root failed in $(target_describe "${target}"): ${out}"
    return 2
  fi

  local -a fields=()
  read -r -a fields <<<"${out}"
  if [[ ${#fields[@]} -lt 2 || ${fields[0]} != root ]]; then
    log_error "$(target_describe "${target}") reported an unreadable password status for root: '${out}'"
    return 2
  fi
  case ${fields[1]} in
    L) return 0 ;;
    P | NP) return 1 ;;
    *)
      log_error "$(target_describe "${target}") reported an unknown password status for root: '${fields[1]}'"
      return 2
      ;;
  esac
}

# Dies unless the container is, right now, running a hardened sshd that
# admits these administrators by key.
#
# This is the confirmation the root password lock waits for. It asks the
# container rather than this script's own memory of what it did: a push
# that succeeded and a daemon that is serving the result are different
# claims, and only the second one makes locking root safe.
_guest_admin_access_confirmed() {
  local target=$1 fragment installed='' main_body='' pam='' agent_keys=''

  _guest_admin_firewall_confirmed "${target}"

  # An outstanding reload means the daemon is still serving whatever it
  # read last, which is not what is on disk. Every file below would look
  # right and none of them would be in force.
  if target_test "${target}" f "${GUEST_ADMIN_SSHD_RELOAD_MARKER}"; then
    die "sshd in $(target_describe "${target}") has not reloaded the hardening this run installed; refusing to lock the root password."
  fi

  target_service_is_active "${target}" "${GUEST_ADMIN_SSH_UNIT}" ||
    die "sshd is not running in $(target_describe "${target}"); refusing to lock the root password."
  target_service_is_enabled "${target}" "${GUEST_ADMIN_SSH_UNIT}" ||
    die "sshd is not enabled in $(target_describe "${target}"); refusing to lock the root password."

  fragment=$(guest_admin_sshd_fragment) ||
    die "Unable to decide who $(target_describe "${target}") should admit."
  target_slurp installed "${target}" "${GUEST_ADMIN_SSHD_PATH}" ||
    die "${GUEST_ADMIN_SSHD_PATH} is missing from $(target_describe "${target}"); refusing to lock the root password."
  [[ ${installed} == "${fragment}" ]] ||
    die "${GUEST_ADMIN_SSHD_PATH} in $(target_describe "${target}") is not the hardening this run installed; refusing to lock the root password."

  target_slurp main_body "${target}" "${GUEST_ADMIN_SSHD_MAIN}" || main_body=''
  grep -Eq "${GUEST_ADMIN_SSHD_INCLUDE_MATCH}" <<<"${main_body}" ||
    die "${GUEST_ADMIN_SSHD_MAIN} in $(target_describe "${target}") does not include ${GUEST_ADMIN_SSHD_DIR}, so sshd never reads the hardening; refusing to lock the root password."

  # sudo is the other half of the access being confirmed: an administrator
  # who can log in and cannot become root has not replaced the root
  # password with anything.
  target_slurp pam "${target}" "${GUEST_ADMIN_PAM_SUDO_PATH}" ||
    die "${GUEST_ADMIN_PAM_SUDO_PATH} is missing from $(target_describe "${target}"); refusing to lock the root password."
  _line_present_in_body "${pam}" "${GUEST_ADMIN_PAM_LINE}" ||
    die "${GUEST_ADMIN_PAM_SUDO_PATH} in $(target_describe "${target}") does not accept a forwarded agent key; refusing to lock the root password."
  target_slurp agent_keys "${target}" "${GUEST_ADMIN_AGENT_KEYS_PATH}" ||
    die "${GUEST_ADMIN_AGENT_KEYS_PATH} is missing from $(target_describe "${target}"); refusing to lock the root password."
  local wanted_keys
  wanted_keys=$(_guest_admin_all_keys) ||
    die "Unable to resolve the administrators' SSH keys."
  [[ ${agent_keys} == "${wanted_keys}" ]] ||
    die "${GUEST_ADMIN_AGENT_KEYS_PATH} in $(target_describe "${target}") does not hold the administrators' keys; refusing to lock the root password."

  _guest_admin_keys_live "${target}"
}

# Locks root's password, once key-based access has been confirmed working.
#
# Off unless PVE_GUEST_ADMIN_ROOT_LOCK asks for it: a container whose root
# password is still set has one more way in that does not depend on this
# toolkit having got the keys right, and that fallback is the operator's
# to give up rather than this module's to take.
#
# `pct enter` from this host is the recovery path and is unaffected by a
# locked password, so this cannot lock anybody out of a container on the
# node that runs it. What it does take away is a password login from
# anywhere else, which is the point.
guest_admin_root_lock() {
  local target=$1 state=0

  if [[ ${PVE_GUEST_ADMIN_ROOT_LOCK:-no} != yes ]]; then
    printf 'unchanged\n'
    return 0
  fi

  if dry_run_enabled; then
    log_info "would lock the root password in $(target_describe "${target}") once key based access is confirmed"
    printf 'unchanged\n'
    return 0
  fi

  _guest_admin_root_lock_state "${target}" || state=$?
  case ${state} in
    0)
      printf 'unchanged\n'
      return 0
      ;;
    1) ;;
    *)
      die "Unable to read root's password status in $(target_describe "${target}"); refusing to guess at it."
      ;;
  esac

  _guest_admin_access_confirmed "${target}"

  target_run "${target}" passwd -l root ||
    die "Unable to lock the root password in $(target_describe "${target}")"
  log_info "locked the root password in $(target_describe "${target}")"
  printf 'changed\n'
}

# --- the whole of it ------------------------------------------------------

# Mirrors this deployment's administrators into a container.
#
# The order is the safety property: every key is validated before anything
# is installed, the accounts and their keys are in place before sshd is
# told to accept nothing else, and the root password is locked last of all
# and only against a container that has been read back and found to admit
# them.
guest_admin_converge() {
  local target=$1 state changed=0

  target_is_guest "${target}" ||
    die 'guest_admin_converge: the administrators are mirrored into a container, not onto the host.'

  # Before anything is installed: a half-configured set of administrators
  # is worse than none, because this goes on to turn password
  # authentication off.
  admin_keys_require >/dev/null

  # A dry run over a container that does not exist yet has nothing to
  # ask. Every probe below reads the container, and a container this node
  # cannot reach answers none of them: going on would stop the plan with
  # a transport error rather than finish it. The work is still reported,
  # because a run that is not a dry one would do it.
  if dry_run_enabled && ! target_test "${target}" f /etc/os-release; then
    log_info "would mirror the administrators into $(target_describe "${target}") once it exists"
    printf 'changed\n'
    return 0
  fi

  state_of state guest_admin_packages "${target}"
  if [[ ${state} == changed ]]; then
    changed=1
  fi
  state_of state guest_admin_users_converge "${target}"
  if [[ ${state} == changed ]]; then
    changed=1
  fi
  state_of state guest_admin_sudo_converge "${target}"
  if [[ ${state} == changed ]]; then
    changed=1
  fi
  state_of state guest_admin_term_converge "${target}"
  if [[ ${state} == changed ]]; then
    changed=1
  fi
  state_of state guest_admin_firewall_converge "${target}"
  if [[ ${state} == changed ]]; then
    changed=1
  fi
  state_of state guest_admin_sshd_converge "${target}"
  if [[ ${state} == changed ]]; then
    changed=1
  fi
  state_of state guest_admin_root_lock "${target}"
  if [[ ${state} == changed ]]; then
    changed=1
  fi

  local -a users=()
  mapfile -t users < <(_guest_admin_users)
  log_info "administrators mirrored into $(target_describe "${target}"): ${users[*]-}"

  if [[ ${changed} -eq 1 ]]; then
    printf 'changed\n'
  else
    printf 'unchanged\n'
  fi
}
