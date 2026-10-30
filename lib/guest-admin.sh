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
GUEST_ADMIN_SSHD_ETC='/etc/ssh'
GUEST_ADMIN_SSHD_DIR='/etc/ssh/sshd_config.d'
GUEST_ADMIN_SSHD_PATH='/etc/ssh/sshd_config.d/99-pve-config-admin.conf'
GUEST_ADMIN_SSHD_MAIN='/etc/ssh/sshd_config'
# The line that makes sshd read this module's fragment, and the pattern
# that identifies it.
#
# It names the fragment outright rather than the directory it sits in. A
# container whose own configuration includes that directory may include
# it by a glob that does not cover this file -- `*.cfg`, or one drop-in
# by name -- and a check that only asked whether the directory was
# mentioned would judge a fragment the daemon never reads. Naming the
# file is the only form of the question with one answer.
#
# Prepended, always, and every line matching the pattern is taken out
# first. Finding an existing copy and leaving it where it is would mean
# deciding whether the place it sits in is conditional, which is reading
# OpenSSH's syntax again; the top of the file is the one position that
# cannot be inside a Match block. A duplicate include is harmless --
# probed against OpenSSH 10.2p1, a second copy of AllowUsers alice adds a
# second identical line to the dump and changes nothing, and a scalar
# keeps its first value -- so this sits happily beside a container's own
# `Include .../*.conf` that already covers the file. The container's own
# list keywords survive alongside this module's and may admit further
# key-authenticated accounts, which is in scope and accepted: an extra
# AllowUsers entry cannot keep an administrator out.
GUEST_ADMIN_SSHD_INCLUDE='Include /etc/ssh/sshd_config.d/99-pve-config-admin.conf'
GUEST_ADMIN_SSHD_INCLUDE_MATCH='^[[:space:]]*[Ii][Nn][Cc][Ll][Uu][Dd][Ee][[:space:]]+/etc/ssh/sshd_config\.d/99-pve-config-admin\.conf[[:space:]]*$'
GUEST_ADMIN_SSHD_INCLUDE_POSITION='prepend'
# Where the overlay is built, inside the container, for the container's
# own sshd to be asked about. /run is a tmpfs, and nothing reads this
# directory but the `sshd -T` that runs with it mounted over /etc/ssh: a
# file an interrupted run leaves behind changes nothing about the daemon.
#
# The layout under it is the real layout, derived rather than written out
# a second time. A path that had to be kept in step by hand is a path
# that drifts, and drift between what sshd was asked about and what sshd
# ends up running is the whole family of defects this replaced.
GUEST_ADMIN_SSHD_CHECK_DIR='/run/pve-config/sshd-check'
GUEST_ADMIN_SSHD_CHECK_ETC="${GUEST_ADMIN_SSHD_CHECK_DIR}/etc-ssh"
GUEST_ADMIN_SSHD_CHECK_DROPIN="${GUEST_ADMIN_SSHD_CHECK_ETC}${GUEST_ADMIN_SSHD_DIR#"${GUEST_ADMIN_SSHD_ETC}"}"
GUEST_ADMIN_SSHD_CHECK_MAIN="${GUEST_ADMIN_SSHD_CHECK_ETC}${GUEST_ADMIN_SSHD_MAIN#"${GUEST_ADMIN_SSHD_ETC}"}"
GUEST_ADMIN_SSHD_CHECK_FRAGMENT="${GUEST_ADMIN_SSHD_CHECK_ETC}${GUEST_ADMIN_SSHD_PATH#"${GUEST_ADMIN_SSHD_ETC}"}"
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

# The interface the tunnel's packets arrive on. The tailnet accepts are
# bound to it as well as to the source address, because 100.64.0.0/10 is
# carrier-grade NAT space and nothing stops a LAN from using it: an
# address-only rule admits a spoofed LAN packet to sshd's
# pre-authentication protocol, which is the exposure `tailnet` is asked
# for to close. `iifname` matches by name and is resolved per packet, so
# the rule loads whether or not the interface is up yet.
guest_admin_tailnet_iface() {
  printf '%s\n' "${PVE_GUEST_ADMIN_TAILNET_IFACE:-tailscale0}"
}

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
  local iface
  iface=$(guest_admin_tailnet_iface)
  printf '%s\n' \
    '#!/usr/sbin/nft -f' \
    '# Managed by pve-config. Reachability of sshd, not authorization.' \
    "table inet ${GUEST_ADMIN_NFT_TABLE} {}" \
    "delete table inet ${GUEST_ADMIN_NFT_TABLE}" \
    "table inet ${GUEST_ADMIN_NFT_TABLE} {" \
    '	chain input {' \
    '		type filter hook input priority filter; policy accept;' \
    '		iif "lo" accept' \
    "		iifname \"${iface}\" ip saddr ${GUEST_ADMIN_TAILNET_V4} tcp dport ${GUEST_ADMIN_SSH_PORT} accept" \
    "		iifname \"${iface}\" ip6 saddr ${GUEST_ADMIN_TAILNET_V6} tcp dport ${GUEST_ADMIN_SSH_PORT} accept" \
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
# means a perl JSON program and none of the modes this toolkit already
# declares answers a question shaped like this one. The hardened core is
# now shared (lib/json.sh), so what a JSON reading would cost here is a
# mode over that core rather than a fourth copy of the decoder; whoever
# revisits this should weigh it on those terms.
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

  local iface
  iface=$(guest_admin_tailnet_iface)
  local lo_rule='iif "lo" accept'
  local lo_rule_alt='iifname "lo" accept'
  # The interface the tunnel's packets arrive on, named in both accepts:
  # a rule matched on the source address alone also admits a LAN host
  # addressed out of 100.64.0.0/10, which is ordinary address space on a
  # network that has not heard of the tunnel.
  local on_iface="iifname \"${iface}\" "
  local v4_rule="${on_iface}ip saddr ${GUEST_ADMIN_TAILNET_V4} tcp dport ${GUEST_ADMIN_SSH_PORT} accept"
  local v6_rule="${on_iface}ip6 saddr ${GUEST_ADMIN_TAILNET_V6} tcp dport ${GUEST_ADMIN_SSH_PORT} accept"

  while IFS= read -r line; do
    trimmed=${line#"${line%%[![:space:]]*}"}
    trimmed=${trimmed%"${trimmed##*[![:space:]]}"}
    [[ -n ${trimmed} ]] || continue

    if [[ ${in_chain} -eq 0 ]]; then
      case ${trimmed} in
        'chain '*'{')
          chains=$((chains + 1))
          # This module writes one chain and owns the table, so a second
          # one is a table this cannot speak for.
          [[ ${chains} -eq 1 && ${trimmed} == 'chain input {' ]] || return 1
          in_chain=1
          ;;
        "table inet ${GUEST_ADMIN_NFT_TABLE} {" | '}')
          # The table's own header and its closing brace.
          ;;
        *)
          # Anything else between the braces of the table is something
          # this module did not write: a set, a second table's header --
          # or `flags dormant`, which unregisters every base chain from
          # its hook and leaves the rules below filtering nothing while
          # reading back exactly as written.
          return 1
          ;;
      esac
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

  # The rules name the tunnel interface, so a container that has no such
  # interface would be given a restriction that drops every ssh packet
  # including the ones over the tunnel. Refusing here leaves the
  # container as it is and says which name was looked for; a deployment
  # whose tunnel is called something else sets
  # PVE_GUEST_ADMIN_TAILNET_IFACE.
  local iface
  iface=$(guest_admin_tailnet_iface)
  if ! target_test "${target}" d "/sys/class/net/${iface}"; then
    if dry_run_enabled; then
      log_warn "$(target_describe "${target}") has no ${iface} interface yet; the tailnet restriction needs one before it can be applied"
    else
      die "$(target_describe "${target}") has no ${iface} interface, so a tailnet restriction bound to it would cut ssh off entirely; set PVE_GUEST_ADMIN_TAILNET_IFACE to the tunnel's name or bring the tunnel up first."
    fi
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

  _guest_admin_firewall_boot_keeps "${target}"

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

# Dies unless the boot configuration still has this module's table in it
# once it has finished loading.
#
# `nft -c -f` says the file is a valid transaction, which is a different
# claim from the table surviving it. Boot replays /etc/nftables.conf and
# everything it includes, in order, and a later statement can take the
# table away again: `flush ruleset` in a fragment that sorts after this
# module's wipes it, and the container comes back from a reboot with ssh
# open to the LAN while every check here reported it restricted.
#
# Narrow rather than clever, as elsewhere in this module. After this
# module's include, /etc/nftables.conf may hold comments and nothing
# else, and no other fragment in the directory may flush the ruleset or
# name this module's table. A configuration that does something this
# cannot account for stops the run instead of being interpreted.
_guest_admin_firewall_boot_keeps() {
  local target=$1 body='' line trimmed seen=0

  target_slurp body "${target}" "${GUEST_ADMIN_NFT_MAIN}" ||
    die "Unable to read ${GUEST_ADMIN_NFT_MAIN} in $(target_describe "${target}"); refusing to call a restriction it cannot read persistent."

  while IFS= read -r line || [[ -n ${line} ]]; do
    trimmed=${line#"${line%%[![:space:]]*}"}
    trimmed=${trimmed%"${trimmed##*[![:space:]]}"}
    if [[ ${seen} -eq 0 ]]; then
      grep -Eq "${GUEST_ADMIN_NFT_INCLUDE_MATCH}" <<<"${line}" && seen=1
      continue
    fi
    [[ -z ${trimmed} || ${trimmed} == '#'* ]] && continue
    die "${GUEST_ADMIN_NFT_MAIN} in $(target_describe "${target}") goes on past the include of ${GUEST_ADMIN_NFT_DIR} with ${trimmed}, and what that leaves of the ssh restriction at boot is not something this can judge; move it above the include."
  done <<<"${body}"

  # Any other fragment that flushes the ruleset or names this table. Its
  # own `delete table` is how it replaces itself, so it is excluded by
  # name; the grep answers with the status, so a name this cannot carry
  # back out of the container changes nothing about the decision.
  # shellcheck disable=SC2034  # target_capture fills it; only the status decides
  local own hits='' hits_rc=0
  own=$(basename -- "${GUEST_ADMIN_NFT_PATH}")
  target_capture hits "${target}" \
    grep -rlE --exclude="${own}" \
    "flush[[:space:]]+ruleset|(flush|delete|destroy)[[:space:]]+table[[:space:]].*${GUEST_ADMIN_NFT_TABLE}" \
    "${GUEST_ADMIN_NFT_DIR}" || hits_rc=$?
  case ${hits_rc} in
    1) ;;
    0)
      die "Something else in ${GUEST_ADMIN_NFT_DIR} in $(target_describe "${target}") flushes the ruleset or takes the ${GUEST_ADMIN_NFT_TABLE} table away, so the ssh restriction would not survive a reboot."
      ;;
    *)
      die "Unable to read ${GUEST_ADMIN_NFT_DIR} in $(target_describe "${target}"); refusing to call a restriction it cannot read persistent."
      ;;
  esac
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

# --- what sshd in the container will actually run -------------------------
#
# Nothing below reads an sshd configuration. Five rounds of review found
# five separate ways a bash reimplementation of OpenSSH's parser disagreed
# with OpenSSH -- a nested Include that was noticed and not followed, a
# `..` that a lexical containment check let through, a keyword spelled
# iNcLuDe, a filename holding a newline, a quoted operand -- and every one
# of them was a false accept on the path that disables password
# authentication. They are all the same defect: checking a proxy for the
# property instead of the property.
#
# The property is what the container's sshd will run, and the only thing
# that answers that without guessing is the container's sshd. `sshd -T`
# prints the configuration it resolved, after every Include has been
# followed by the parser that will follow them for real, one lowercase
# `keyword value` to a line, and exits non-zero on a configuration it will
# not run. It is run inside the container, so those Includes resolve
# against the container's filesystem and not this host's.

# The main configuration as it has to be for sshd to read a fragment:
# the Include that names that fragment, once, at the top, with any
# earlier copy of a managed Include taken out.
#
# The same transformation, with the same three constants, that
# target_ensure_exact_line applies when converge writes the real
# /etc/ssh/sshd_config. The overlay sshd is asked about, the check for
# whether publishing would change anything, and the lock's check that
# the hardening is in force all go through here, so none of them can
# drift from the file converge leaves on disk.
_guest_admin_sshd_main_with_include() {
  local __gasm_var=$1 __gasm_body=$2
  _exact_line_body "${__gasm_var}" "${__gasm_body}" \
    "${GUEST_ADMIN_SSHD_INCLUDE_MATCH}" "${GUEST_ADMIN_SSHD_INCLUDE}" \
    "${GUEST_ADMIN_SSHD_INCLUDE_POSITION}"
}

# Builds the overlay the container's sshd is asked about.
#
# No candidate is constructed. A candidate is a second configuration
# written by this module in the hope that it resolves the way the real
# one will, and every round of review has found another way for that
# hope to be wrong: a glob that did not cover the fragment, an existing
# Include that pulled in the very fragment converge was about to
# replace. The answer is to stop guessing and reproduce the container's
# own /etc/ssh, change in it exactly what converge changes, and let sshd
# read it at its real name.
#
# `cp -a SRC/. DST/` copies the contents of a directory without this
# module ever naming a file inside it. That matters more than it looks:
# the one time this toolkit listed that directory by name, a drop-in
# whose filename held a newline defeated the listing, and sshd read a
# file nothing had judged.
#
# Two files are then put over the copy, and they are the two files
# converge writes: the main configuration, through the same
# transformation converge applies to it, and the fragment. Everything
# else in the overlay is the container's own bytes.
_guest_admin_sshd_stage() {
  local target=$1 fragment=$2 main_body='' overlay=''

  target_slurp main_body "${target}" "${GUEST_ADMIN_SSHD_MAIN}" || main_body=''
  _guest_admin_sshd_main_with_include overlay "${main_body}"

  # Whatever an interrupted run left behind is not part of the container
  # and must not be judged as though it were. Checked here, unlike in
  # _guest_admin_sshd_unstage: `cp -a` merges into a directory that is
  # already there, so a removal that failed would leave a drop-in the
  # container no longer has sitting in the overlay for sshd to read.
  target_run "${target}" rm -rf -- "${GUEST_ADMIN_SSHD_CHECK_DIR}" >/dev/null ||
    die "Unable to clear ${GUEST_ADMIN_SSHD_CHECK_DIR} inside $(target_describe "${target}"); refusing to judge a configuration an earlier run may have left there."
  target_ensure_dir "${target}" "${GUEST_ADMIN_SSHD_CHECK_DIR}" 0700 >/dev/null
  target_ensure_dir "${target}" "${GUEST_ADMIN_SSHD_CHECK_ETC}" 0755 >/dev/null
  target_run "${target}" cp -a "${GUEST_ADMIN_SSHD_ETC}/." \
    "${GUEST_ADMIN_SSHD_CHECK_ETC}/" >/dev/null ||
    die "Unable to copy ${GUEST_ADMIN_SSHD_ETC} inside $(target_describe "${target}"); refusing to judge anything but the container's own configuration."
  target_ensure_dir "${target}" "${GUEST_ADMIN_SSHD_CHECK_DROPIN}" 0755 >/dev/null
  # No mode: the copy already carries the container's own, and converge
  # keeps it when it rewrites the file, so this keeps it too.
  target_write_file "${target}" "${GUEST_ADMIN_SSHD_CHECK_MAIN}" \
    "${overlay}" >/dev/null
  target_write_file "${target}" "${GUEST_ADMIN_SSHD_CHECK_FRAGMENT}" \
    "${fragment}" 0644 >/dev/null
}

# Takes the overlay away again. A failure to remove it is not worth
# stopping a run over and is deliberately not checked: the directory is a
# tmpfs path no daemon reads, and the next run rebuilds it from scratch.
_guest_admin_sshd_unstage() {
  local target=$1
  target_run "${target}" rm -rf -- "${GUEST_ADMIN_SSHD_CHECK_DIR}" >/dev/null 2>&1 ||
    log_warn "Unable to remove ${GUEST_ADMIN_SSHD_CHECK_DIR} from $(target_describe "${target}")"
  return 0
}

# The configuration the container's sshd resolves with the overlay in
# place.
#
#   0  sshd ran and accepted it; the variable holds the dump
#   1  sshd ran and refused it; the variable holds what it said
#   2  no answer that can be read; abort rather than mutate
#
# The overlay is mounted over /etc/ssh inside a mount namespace of its
# own, and `sshd -T` is then run with no -f at all, so it opens
# /etc/ssh/sshd_config exactly as the daemon will. Every Include in it,
# every glob, every sort order is sshd's own work on the real pathnames.
# There is nothing left for this module to get wrong about them.
#
# The namespace is made by the same `unshare -m` that runs the mount and
# the dump, so it and every mount in it cease to exist when that process
# does -- on a normal exit, on a failure, or on a kill. Probed: a child
# SIGKILLed while holding the bind leaves no mount behind, and a process
# outside the namespace reading /etc/ssh while the child holds it still
# sees the container's own file. util-linux sets the new namespace's
# propagation to private for exactly this reason.
#
# The two scripts exist to keep the statuses apart, which matters more
# here than it looks. `unshare` refused for want of privilege exits 1,
# and so does a great deal else; 1 is also the status this contract
# reads as "sshd ran and refused the configuration", which is the one
# status that lets a run carry on and mutate the container. So the inner
# script never passes a status through: it reports 0 for a dump, 2 for
# anything that stopped sshd being asked, and 3 -- a status it alone
# chooses -- for sshd having run and said no. sshd says no with 1 or
# 255 and nothing else (probed against OpenSSH 10.2p1: 255 for a bad
# keyword or Match line, 1 for a missing file or no usable host key), so
# only those become 3; 126, 127 and a death by signal are a shell or a
# kernel talking, not sshd, and are 2. The outer script maps 3 back to
# 1 and everything that is neither 0 nor 3 to 2. A namespace that could
# not be made, a mount that was refused, an sshd that is not installed,
# a shell that could not start: every one of them is 2.
#
# Nothing looks at the text of any of it. The status is the judgement.
# The commands' stderr is folded into the output so a refusal arrives
# with its reason attached for the operator, not for this code to read.
#
# A container that cannot be reached at all never reaches the case
# statement: target_capture dies on a transport that failed, rather than
# returning a status that could be read as a configuration verdict.
_guest_admin_sshd_dump() {
  local __dump_var=$1 __dump_target=$2 __dump_rc=0

  # Both scripts take the overlay as $1 and the directory it stands in
  # for as $2; the outer one takes the inner as $3. Passing the inner
  # script as an argument rather than quoting it inside the outer one
  # means neither has to escape the other, and no path is written out
  # twice. The $ signs below belong to the container's shell, not to
  # this one. Each script is one line, so the command as logged and
  # recorded is one line too.
  # shellcheck disable=SC2016
  local __dump_inner='mount --bind "$1" "$2" || exit 2; sshd -T; case $? in 0) exit 0 ;; 1 | 255) exit 3 ;; esac; exit 2'
  # shellcheck disable=SC2016
  local __dump_outer='exec 2>&1; unshare -m /bin/sh -c "$3" pve-config "$1" "$2"; case $? in 0) exit 0 ;; 3) exit 1 ;; esac; exit 2'

  target_capture "${__dump_var}" "${__dump_target}" /bin/sh -c \
    "${__dump_outer}" pve-config "${GUEST_ADMIN_SSHD_CHECK_ETC}" \
    "${GUEST_ADMIN_SSHD_ETC}" "${__dump_inner}" || __dump_rc=$?
  case ${__dump_rc} in
    0) return 0 ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
}

# The dump, or a message and a stopped run.
_guest_admin_sshd_effective() {
  local __eff_var=$1 __eff_target=$2 __eff_rc=0
  _guest_admin_sshd_dump "${__eff_var}" "${__eff_target}" || __eff_rc=$?
  case ${__eff_rc} in
    0) return 0 ;;
    1)
      die "sshd in $(target_describe "${__eff_target}") will not run the configuration this hardening would give it: ${!__eff_var}"
      ;;
    *)
      die "sshd in $(target_describe "${__eff_target}") could not be asked what the hardened configuration resolves to -- no sshd to ask, or no mount namespace to put the overlay in -- so there is no answer to read; refusing to harden. It said: ${!__eff_var}"
      ;;
  esac
}

# Every value the dump gives for one keyword, one to a line.
#
# Read by name, never compared whole: the set of keywords `sshd -T` prints
# grows with every OpenSSH release, and a check that compared entire dumps
# would start refusing containers over an upgrade that changed nothing
# this module cares about.
_guest_admin_sshd_values() {
  local dump=$1 keyword=$2 line
  while IFS= read -r line || [[ -n ${line} ]]; do
    [[ ${line} == "${keyword} "* ]] || continue
    printf '%s\n' "${line#"${keyword}" }"
  done <<<"${dump}"
}

# Dies unless every setting the fragment asks for is the one sshd
# resolved.
#
# The fragment is read here; the container's configuration is not. The
# fragment is this module's own file, with a shape this module chose, and
# what the container holds is only ever asked of sshd.
_guest_admin_sshd_takes_effect() {
  local target=$1 dump=$2 fragment=$3
  local line keyword value canon actual seen
  while IFS= read -r line || [[ -n ${line} ]]; do
    line=${line#"${line%%[![:space:]]*}"}
    [[ -z ${line} || ${line} == '#'* ]] && continue
    keyword=${line%%[[:space:]]*}
    value=${line#"${keyword}"}
    value=${value#"${value%%[![:space:]]*}"}
    keyword=$(_sshd_canonical_keyword "${keyword}")
    # sshd accumulates these rather than letting one occurrence win, so
    # there is no single resolved value to compare one against. Who they
    # admit is judged by _guest_admin_sshd_admits instead.
    case ${keyword} in
      allowusers | denyusers | allowgroups | denygroups) continue ;;
    esac
    canon=$(_sshd_canonical_value "${value}")
    seen=0
    while IFS= read -r actual; do
      seen=1
      [[ $(_sshd_canonical_value "${actual}") == "${canon}" ]] && continue
      die "sshd in $(target_describe "${target}") resolves ${keyword} to '${actual}' rather than the '${value}' this hardening asks for; something it reads first wins. Resolve that before hardening."
    done < <(_guest_admin_sshd_values "${dump}" "${keyword}")
    [[ ${seen} -eq 1 ]] ||
      die "sshd in $(target_describe "${target}") reports no ${keyword} in the configuration it resolved; refusing to harden against a configuration this cannot read."
  done <<<"${fragment}"
  return 0
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
#
# Only listenaddress is read, and Port is not. The dump reports every
# listener the daemon will bind as host:port with an IPv6 address
# bracketed, so the port of each one is the text after its last colon and
# there is no bare-IPv6 address to mistake for a port. Reading Port as
# well would add a value that may describe no listener at all.
_guest_admin_sshd_ports_guard() {
  local target=$1 dump=$2 access=${PVE_GUEST_ADMIN_SSH_ACCESS:-lan}
  [[ ${access} == tailnet ]] || return 0

  local entry port seen=0
  while IFS= read -r entry; do
    seen=1
    port=${entry%%[[:space:]]*}
    port=${port##*:}
    [[ ${port} == "${GUEST_ADMIN_SSH_PORT}" ]] && continue
    die "sshd in $(target_describe "${target}") listens on ${entry}, so it answers on port ${port}, which the tailnet restriction does not cover; refusing to report it restricted."
  done < <(_guest_admin_sshd_values "${dump}" listenaddress)
  [[ ${seen} -eq 1 ]] ||
    die "sshd in $(target_describe "${target}") reports no listener at all; refusing to report it restricted to the tailnet."
  return 0
}

# Dies unless this fragment would leave every administrator able to log
# in.
#
# Asked of the whole configuration sshd resolved rather than of the
# fragment, because an AllowUsers or an AuthorizedKeysFile somewhere else
# in the container's configuration decides the answer and the fragment
# cannot see it.
_guest_admin_sshd_admits() {
  local target=$1 dump=$2
  shift 2

  local display
  display="sshd in $(target_describe "${target}")"

  local value operand method ok
  while IFS= read -r value; do
    ok=0
    for operand in ${value}; do
      operand=${operand#'%h/'}
      [[ ${operand} == '.ssh/authorized_keys' ]] && ok=1
    done
    [[ ${ok} -eq 1 ]] && continue
    die "${display} resolves AuthorizedKeysFile to '${value}', so the keys installed for the administrators would be ignored."
  done < <(_guest_admin_sshd_values "${dump}" authorizedkeysfile)

  while IFS= read -r value; do
    ok=0
    # sshd takes alternatives separated by spaces and requirements
    # separated by commas, and succeeds when one alternative is satisfied
    # in full: `publickey,password` is not an alternative a key alone
    # finishes, `publickey password` is.
    for method in ${value}; do
      [[ ${method} == any || ${method} == publickey ]] && ok=1
    done
    [[ ${ok} -eq 1 ]] && continue
    die "${display} requires 'AuthenticationMethods ${value}', which no key alone satisfies; hardening would leave every administrator unable to finish authenticating."
  done < <(_guest_admin_sshd_values "${dump}" authenticationmethods)

  local -a allow_users=() deny_users=() allow_groups=() deny_groups=()
  mapfile -t allow_users < <(_guest_admin_sshd_values "${dump}" allowusers)
  mapfile -t deny_users < <(_guest_admin_sshd_values "${dump}" denyusers)
  mapfile -t allow_groups < <(_guest_admin_sshd_values "${dump}" allowgroups)
  mapfile -t deny_groups < <(_guest_admin_sshd_values "${dump}" denygroups)

  local user pattern group admitted
  local -a groups=()
  while [[ $# -gt 0 ]]; do
    user=$1
    IFS=',' read -r -a groups <<<"${2:-}"
    shift 2

    for pattern in ${deny_users[@]+"${deny_users[@]}"}; do
      if _ssh_name_matches "${user}" "${pattern}"; then
        die "${display} denies ${user} with 'DenyUsers ${pattern}', so hardening would leave them unable to log in."
      fi
    done
    if [[ ${#allow_users[@]} -gt 0 ]]; then
      admitted=0
      for pattern in "${allow_users[@]}"; do
        _ssh_name_matches "${user}" "${pattern}" && admitted=1
      done
      if [[ ${admitted} -ne 1 ]]; then
        die "${display} admits only '${allow_users[*]}', which does not include ${user}; hardening would leave them unable to log in."
      fi
    fi

    [[ ${#deny_groups[@]} -gt 0 || ${#allow_groups[@]} -gt 0 ]] || continue
    for pattern in ${deny_groups[@]+"${deny_groups[@]}"}; do
      for group in ${groups[@]+"${groups[@]}"}; do
        if _ssh_name_matches "${group}" "${pattern}"; then
          die "${display} denies ${user}'s group ${group} with 'DenyGroups ${pattern}', so hardening would leave them unable to log in."
        fi
      done
    done
    if [[ ${#allow_groups[@]} -gt 0 ]]; then
      admitted=0
      for pattern in "${allow_groups[@]}"; do
        for group in ${groups[@]+"${groups[@]}"}; do
          _ssh_name_matches "${group}" "${pattern}" && admitted=1
        done
      done
      if [[ ${admitted} -ne 1 ]]; then
        die "${display} admits only the groups '${allow_groups[*]}', none of which ${user} is in; hardening would leave them unable to log in."
      fi
    fi
  done
  return 0
}

# Dies unless the configuration the container's sshd would run, with this
# fragment in it, still lets every administrator in.
#
# The dump is the global one, with no -C. What it answers is the
# question this module exists to answer: can an administrator log in with
# a key, with password authentication off. A Match block that alters
# behaviour for some other user or some other address is deliberately not
# analysed -- it does not touch that question, and refusing it was
# strictness nobody asked for.
_guest_admin_sshd_judge() {
  local target=$1 fragment=$2
  local -a pairs=()
  local dump='' user raw groups

  # Not a subshell: a group file that cannot be read is a die, and a die
  # in a subshell is a message nobody acts on and a run that carries on
  # hardening. An AllowGroups judged against an empty list admits
  # everybody, which is the answer that disables password authentication.
  while IFS= read -r user; do
    [[ -n ${user} ]] || continue
    raw=$(target_user_groups "${target}" "${user}") ||
      die "Unable to read the groups ${user} belongs to in $(target_describe "${target}"); refusing to judge who its sshd would admit."
    groups=$(printf '%s\n' "${raw}" | paste -sd, -)
    pairs+=("${user}" "${groups}")
  done < <(_guest_admin_users)

  _guest_admin_sshd_effective dump "${target}"
  _guest_admin_sshd_takes_effect "${target}" "${dump}" "${fragment}"
  _guest_admin_sshd_ports_guard "${target}" "${dump}"
  _guest_admin_sshd_admits "${target}" "${dump}" ${pairs[@]+"${pairs[@]}"}
  return 0
}

# Dies unless sudo's agent authentication can still reach an agent.
#
# The administrative access that replaces root's password is a key login
# plus sudo authenticated by the forwarded agent. sshd refusing to forward
# the agent takes the second half away: the administrators can log in and
# none of them can become root. That is only a question for the lock,
# which is why it is asked there and not with the hardening -- a container
# whose root password is still set has lost nothing.
#
# Both keywords are read. DisableForwarding yes turns agent forwarding off
# without changing what AllowAgentForwarding resolves to, so either one
# alone answers half the question.
_guest_admin_sshd_forwarding_guard() {
  local target=$1 dump=$2
  local display
  display="sshd in $(target_describe "${target}")"

  local value
  while IFS= read -r value; do
    [[ ${value,,} == yes ]] && continue
    die "${display} resolves allowagentforwarding ${value,,}, so no administrator can forward the agent key sudo authenticates with; refusing to lock the root password."
  done < <(_guest_admin_sshd_values "${dump}" allowagentforwarding)
  while IFS= read -r value; do
    [[ ${value,,} == no ]] && continue
    die "${display} resolves disableforwarding ${value,,}, so no administrator can forward the agent key sudo authenticates with; refusing to lock the root password."
  done < <(_guest_admin_sshd_values "${dump}" disableforwarding)
  return 0
}

# Dies unless the running configuration still carries a forwarded agent,
# for every administrator.
_guest_admin_sshd_forwarding_confirmed() {
  local target=$1 fragment=$2 dump=''

  _guest_admin_sshd_stage "${target}" "${fragment}"
  _guest_admin_sshd_effective dump "${target}"
  _guest_admin_sshd_forwarding_guard "${target}" "${dump}"
  _guest_admin_sshd_unstage "${target}"
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

# Installs the fragment.
#
# The judgement this file gets is sshd's own, made inside the container by
# _guest_admin_sshd_judge before anything is written. There is nothing
# left for this host's sshd to say about a configuration it cannot
# assemble: the Includes in it name the container's filesystem.
_guest_admin_sshd_install() {
  local target=$1 fragment=$2
  _target_refuse_symlink "${target}" "${GUEST_ADMIN_SSHD_PATH}"
  target_write_file "${target}" "${GUEST_ADMIN_SSHD_PATH}" "${fragment}" 0644
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
  local wanted=''
  _guest_admin_sshd_main_with_include wanted "${main_body}" \
    "${GUEST_ADMIN_SSHD_INCLUDE}"
  [[ ${wanted} == "${main_body}" ]] || return 0
  return 1
}

# Installs the hardening fragment, having first established that doing so
# leaves every administrator able to get in.
guest_admin_sshd_converge() {
  local target=$1 fragment changed=0 state include_state=unchanged

  fragment=$(guest_admin_sshd_fragment) ||
    die "Unable to decide who $(target_describe "${target}") should admit."

  state_of state target_ensure_dir "${target}" "${GUEST_ADMIN_SSHD_DIR}" 0755
  if [[ ${state} == changed ]]; then
    changed=1
  fi

  # The gate. Nothing below this point can be undone from outside the
  # container, so everything that could refuse has already refused.
  if dry_run_enabled; then
    # The overlay cannot be built in the container, because a dry run
    # writes nothing to it, and sshd there has nothing to be asked about.
    log_info "would ask sshd in $(target_describe "${target}") what the hardened configuration resolves to, and check that every administrator can log in with a key before disabling passwords"
  else
    _guest_admin_keys_live "${target}"
    _guest_admin_sshd_stage "${target}" "${fragment}"
    _guest_admin_sshd_judge "${target}" "${fragment}"
    _guest_admin_sshd_unstage "${target}"
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
  state_of state _guest_admin_sshd_install "${target}" "${fragment}"
  if [[ ${state} == changed ]]; then
    changed=1
  fi

  # sshd only reads a fragment when the main configuration includes one,
  # and the Include is added after the fragment is in place: publishing it
  # first would make the fragment live before it holds the hardening.
  #
  # Added whatever the container already includes. Its own glob may or
  # may not cover this file, and working out which is reading OpenSSH's
  # syntax; naming the file is the question with one answer. The same
  # transformation built the overlay sshd was asked about, so the file
  # this writes is the file that was judged.
  state_of include_state target_ensure_exact_line "${target}" \
    "${GUEST_ADMIN_SSHD_MAIN}" "${GUEST_ADMIN_SSHD_INCLUDE_MATCH}" \
    "${GUEST_ADMIN_SSHD_INCLUDE}" "${GUEST_ADMIN_SSHD_INCLUDE_POSITION}"
  if [[ ${include_state} == changed ]]; then
    changed=1
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
  local wanted_main=''
  _guest_admin_sshd_main_with_include wanted_main "${main_body}" \
    "${GUEST_ADMIN_SSHD_INCLUDE}"
  [[ ${wanted_main} == "${main_body}" ]] ||
    die "${GUEST_ADMIN_SSHD_MAIN} in $(target_describe "${target}") does not include ${GUEST_ADMIN_SSHD_PATH} the way this run installs it, so sshd never reads the hardening; refusing to lock the root password."

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

  # And that a login can still carry the agent key sudo asks for.
  _guest_admin_sshd_forwarding_confirmed "${target}" "${fragment}"
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
