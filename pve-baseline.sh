#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
# SPDX-License-Identifier: Apache-2.0

# Step 1 of 2: baseline a freshly installed Proxmox VE host.
#
# Run once, as root, from the host's local console (the network is
# reconfigured to DHCP part way through, which drops SSH sessions). Reboot
# when it finishes, then run pve-guests.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--config PATH]

Baseline a fresh Proxmox VE install: hostname, DHCP bridge, repositories,
admin user with SSH-agent sudo, sshd hardening and Zulip notifications.

  --config PATH  settings file (default: ${SCRIPT_DIR}/pve-config.env)
  -h, --help     show this help
EOF
}

log() { echo "==> $*" >&2; }
die() {
  echo "ERROR: $*" >&2
  exit 1
}

# Sources the settings file and checks that the named variables are set
# and no longer hold the example's CHANGEME placeholder.
load_config() {
  local config="$1" var
  shift
  [[ -f "${config}" ]] || die "no settings file at ${config}; copy pve-config.env.example to it and fill it in"
  if [[ "$(stat -c %a "${config}")" != 600 ]]; then
    echo "WARNING: ${config} holds credentials; chmod 0600 it" >&2
  fi
  # shellcheck source=/dev/null
  source "${config}"
  for var in "$@"; do
    [[ -n "${!var:-}" ]] || die "${var} is not set in ${config}"
    if [[ "${!var}" == *CHANGEME* ]]; then
      die "${var} in ${config} still holds a CHANGEME placeholder"
    fi
  done
}

# Wired physical NICs: interfaces backed by a device, minus wireless ones.
detect_nics() {
  local sysfs="${1:-/sys/class/net}" dev
  for dev in "${sysfs}"/*; do
    if [[ -e "${dev}/device" && ! -e "${dev}/wireless" && ! -e "${dev}/phy80211" ]]; then
      echo "${dev##*/}"
    fi
  done
}

vmbr0_ip() {
  ip -4 -o addr show dev vmbr0 2>/dev/null | awk '{split($4, a, "/"); print a[1]; exit}'
}

main() {
  local config="${SCRIPT_DIR}/pve-config.env"
  while (($#)); do
    case "$1" in
      --config)
        config="${2:?--config needs a path}"
        shift 2
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        usage >&2
        exit 2
        ;;
    esac
  done

  [[ ${EUID} -eq 0 ]] || die "run as root"
  command -v pveversion >/dev/null || die "this is not a Proxmox VE host"
  load_config "${config}" DOMAIN ADMIN_USER ADMIN_PUBKEYS

  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    echo "WARNING: running over SSH; the network restart below will probably cut this session" >&2
  fi

  local name fqdn ip nic ports existing
  name="$(hostname -s)"
  fqdn="${name}.${DOMAIN}"
  local -a nics
  if [[ -n "${BRIDGE_PORTS:-}" ]]; then
    read -r -a nics <<<"${BRIDGE_PORTS}"
  else
    mapfile -t nics < <(detect_nics)
  fi
  ((${#nics[@]})) || die "no physical NICs found; set BRIDGE_PORTS"
  ports="${nics[*]}"

  log "Configuring ${fqdn} (vmbr0 ports: ${ports})"

  # --- 1. Hostname --------------------------------------------------------
  echo "${name}" >/etc/hostname
  hostnamectl set-hostname "${fqdn}"

  # --- 2. No-subscription repository, drop the enterprise ones -------------
  log "Switching to the pve-no-subscription repository"
  local codename
  codename="$(. /etc/os-release && echo "${VERSION_CODENAME}")"
  local src
  for src in /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list; do
    if [[ -f "${src}" ]] && grep -q 'enterprise\.proxmox\.com' "${src}"; then
      rm -f "${src}"
    fi
  done
  cat >/etc/apt/sources.list.d/proxmox.sources <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: ${codename}
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF

  # --- 3. Remove the subscription nag, and keep it removed after upgrades --
  cat >/usr/local/bin/pve-no-nag.sh <<'EOF'
#!/bin/sh
JS="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
[ -f "$JS" ] || exit 0
if ! grep -q 'NoMoreNagging' "$JS" 2>/dev/null; then
    echo 'Re-applying no-nag patch...'
    sed -i '/.*data\.status.*active/{s/!//;s/active/NoMoreNagging/}' "$JS"
    systemctl restart pveproxy.service
fi
EOF
  chmod +x /usr/local/bin/pve-no-nag.sh
  cat >/etc/apt/apt.conf.d/99-pve-no-nag <<'EOF'
DPkg::Post-Invoke { "/usr/local/bin/pve-no-nag.sh || true"; };
EOF
  /usr/local/bin/pve-no-nag.sh

  # --- 4. Packages: upgrade, then what the rest of this script needs ------
  log "Upgrading packages"
  export DEBIAN_FRONTEND=noninteractive
  local -a apt_opts=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
  apt-get update
  apt-get "${apt_opts[@]}" full-upgrade
  # isc-dhcp-client: ifupdown2 needs it for DHCP on vmbr0.
  apt-get "${apt_opts[@]}" install isc-dhcp-client sudo libpam-ssh-agent-auth curl

  # --- 5. Network: every NIC on vmbr0, address by DHCP --------------------
  log "Writing /etc/network/interfaces"
  {
    cat <<EOF
# This file describes the network interfaces available on your system
# and how to activate them. For more information, see interfaces(5).

source /etc/network/interfaces.d/*

# The loopback network interface
auto lo
iface lo inet loopback

# All wired NICs on vmbr0 (any of them can be the one plugged in)
EOF
    for nic in "${nics[@]}"; do
      printf '\nauto %s\niface %s inet manual\n' "${nic}" "${nic}"
    done
    cat <<EOF

auto vmbr0
iface vmbr0 inet dhcp
        bridge-ports ${ports}
        bridge-stp off
        bridge-fd 0
EOF
  } >/etc/network/interfaces

  # --- 6. Keep /etc/hosts in step with the DHCP address --------------------
  mkdir -p /etc/dhcp/dhclient-exit-hooks.d
  cat >/etc/dhcp/dhclient-exit-hooks.d/update-etc-hosts <<EOF
#!/bin/sh
if [ "\$reason" = "BOUND" ] || [ "\$reason" = "RENEW" ]; then
    if grep -q "${fqdn}" /etc/hosts; then
        sed -i "s|^.*\\s${fqdn}.*\$|\$new_ip_address ${fqdn} ${name}|" /etc/hosts
    else
        echo "\$new_ip_address ${fqdn} ${name}" >> /etc/hosts
    fi
fi
EOF
  chmod +x /etc/dhcp/dhclient-exit-hooks.d/update-etc-hosts

  # --- 7. Postfix ---------------------------------------------------------
  sed -i "s/^myhostname = .*/myhostname = ${fqdn}/" /etc/postfix/main.cf

  # --- 8. Bring the network up and wait for a lease ------------------------
  log "Restarting networking (DHCP on vmbr0)"
  ifdown -a && ifup -a
  for _ in $(seq 1 30); do
    ip="$(vmbr0_ip)"
    [[ -n "${ip}" ]] && break
    sleep 1
  done
  [[ -n "${ip}" ]] || die "vmbr0 got no DHCP address within 30s"

  # --- 9. /etc/hosts with the real address -------------------------------
  cat >/etc/hosts <<EOF
127.0.0.1   localhost
${ip}   ${fqdn}  ${name}
::1         ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
EOF

  # --- 10. pve-cluster waits on boot until vmbr0 has an address in hosts --
  mkdir -p /etc/systemd/system/pve-cluster.service.d
  cat >/etc/systemd/system/pve-cluster.service.d/wait-for-ip.conf <<'EOF'
[Service]
ExecStartPre=/bin/sh -c 'for i in $(seq 1 30); do ip=$(ip -4 addr show vmbr0 2>/dev/null | grep -oP "(?<=inet\s)\d+(\.\d+){3}"); [ -n "$ip" ] && grep -q "^$ip" /etc/hosts && exit 0; sleep 1; done; exit 0'
EOF
  systemctl daemon-reload

  # --- 11. pve-cluster, node directory, remaining services ----------------
  systemctl restart pve-cluster
  existing="$(find /etc/pve/nodes -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | head -1)"
  if [[ -n "${existing}" && "${existing}" != "${name}" ]]; then
    log "Renaming node dir: ${existing} -> ${name}"
    mv "/etc/pve/nodes/${existing}" "/etc/pve/nodes/${name}"
  fi
  systemctl restart pvedaemon pveproxy pvestatd

  # --- 12. Admin user -------------------------------------------------------
  log "Creating admin user ${ADMIN_USER}"
  useradd -m -s /bin/bash -G sudo "${ADMIN_USER}"
  install -d -m 0700 -o "${ADMIN_USER}" -g "${ADMIN_USER}" "/home/${ADMIN_USER}/.ssh"
  printf '%s\n' "${ADMIN_PUBKEYS}" >"/home/${ADMIN_USER}/.ssh/authorized_keys"
  chown "${ADMIN_USER}:${ADMIN_USER}" "/home/${ADMIN_USER}/.ssh/authorized_keys"
  chmod 0600 "/home/${ADMIN_USER}/.ssh/authorized_keys"
  pveum user add "${ADMIN_USER}@pam"
  pveum acl modify / --roles PVEAdmin --users "${ADMIN_USER}@pam"

  # --- 13. sshd: keys only -------------------------------------------------
  cat >/etc/ssh/sshd_config.d/99-hardening.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
  sshd -t
  systemctl restart ssh

  # --- 14. Passwordless sudo through the forwarded SSH agent --------------
  install -d -m 0755 /etc/security
  printf '%s\n' "${ADMIN_PUBKEYS}" >/etc/security/authorized_keys
  chmod 0600 /etc/security/authorized_keys
  sed -i '1a auth sufficient pam_ssh_agent_auth.so file=/etc/security/authorized_keys' /etc/pam.d/sudo
  rm -f /etc/pam.d/sudo-i
  ln -s /etc/pam.d/sudo /etc/pam.d/sudo-i
  echo 'Defaults env_keep += "SSH_AUTH_SOCK"' >/etc/sudoers.d/90-ssh-agent
  chmod 0440 /etc/sudoers.d/90-ssh-agent
  visudo -cq

  # --- 15. Root shell ------------------------------------------------------
  cat >/root/.bashrc <<'EOF'
# ~/.bashrc: executed by bash(1) for non-login shells.

# Note: PS1 is set in /etc/profile, and the default umask is defined
# in /etc/login.defs. You should not need this unless you want different
# defaults for root.
# PS1='${debian_chroot:+($debian_chroot)}\h:\w\$ '
# umask 022

export LS_OPTIONS='--color=auto'
eval "$(dircolors)"
alias ls='ls $LS_OPTIONS'
alias ll='ls $LS_OPTIONS -l'
alias l='ls $LS_OPTIONS -lA'

# Some more alias to avoid making mistakes:
alias rm='rm -i'
alias cp='cp -i'
alias mv='mv -i'

# Fix backspace when coming in via ssh and sudo
[ -t 0 ] && stty erase '^H'
EOF

  # --- 16. Zulip notifications (inactive until credentials exist) ---------
  log "Installing Zulip notifier"
  install -m 0755 "${SCRIPT_DIR}/files/zulip-notify.sh" /usr/local/bin/zulip-notify.sh
  install -m 0644 "${SCRIPT_DIR}/files/zulip-boot-notify.service" \
    "${SCRIPT_DIR}/files/zulip-shutdown-notify.service" /etc/systemd/system/
  install -m 0600 /dev/null /etc/zulip-notify.env
  {
    cat <<'EOF'
# Credentials for /usr/local/bin/zulip-notify.sh. While any value is blank
# the notifier does nothing. To activate it later:
#   1. fill in all four values below
#   2. systemctl enable zulip-boot-notify.service zulip-shutdown-notify.service
#   3. test with: /usr/local/bin/zulip-notify.sh boot
EOF
    printf 'ZULIP_URL=%q\nZULIP_BOT_EMAIL=%q\nZULIP_API_KEY=%q\nZULIP_STREAM=%q\n' \
      "${ZULIP_URL:-}" "${ZULIP_BOT_EMAIL:-}" "${ZULIP_API_KEY:-}" "${ZULIP_STREAM:-}"
  } >/etc/zulip-notify.env
  systemctl daemon-reload
  local zulip="inactive (no credentials; see /etc/zulip-notify.env)"
  if [[ -n "${ZULIP_URL:-}" && -n "${ZULIP_BOT_EMAIL:-}" &&
    -n "${ZULIP_API_KEY:-}" && -n "${ZULIP_STREAM:-}" ]]; then
    systemctl enable zulip-boot-notify.service zulip-shutdown-notify.service
    zulip="enabled"
  fi

  # --- Summary -------------------------------------------------------------
  cat <<EOF

=== Verification ===
Hostname:     $(hostname -f)
vmbr0 IP:     ${ip}
vmbr0 ports:  ${ports}
Node dir:     $(ls /etc/pve/nodes/)
pve-cluster:  $(systemctl is-active pve-cluster)
pveproxy:     $(systemctl is-active pveproxy)
sshd:         $(systemctl is-active ssh)
Admin user:   ${ADMIN_USER} (PVEAdmin on /, sudo via forwarded SSH agent)
Zulip:        ${zulip}

/etc/hosts:
$(cat /etc/hosts)

Test admin access from your workstation:
  ssh -A ${ADMIN_USER}@${ip} sudo whoami

Reboot now, then run pve-guests.sh:
  reboot
EOF
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
