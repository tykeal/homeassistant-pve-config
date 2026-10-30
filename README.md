<!--
SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
SPDX-License-Identifier: Apache-2.0
-->

# pve-config

Two bash scripts that take a freshly installed Proxmox VE host to a known
baseline before it ships to its site:

- `pve-baseline.sh` sets up the host: hostname, DHCP bridge, repositories,
  admin user, SSH and Zulip notifications.
- `pve-guests.sh` adds the web UI certificate, a Home Assistant OS VM, a
  Tailscale subnet router container and a Frigate container.

This is a one-time setup, not configuration management. Each script runs
once, in order, on a fresh install. Final configuration happens later,
remotely, over Tailscale. Re-running either script on a configured host
will fail part way (the user, guests and plugin already exist); reinstall
Proxmox instead.

## Usage

On the freshly installed host, logged in as `root` on the **local
console** (the baseline switches the network to DHCP, which drops SSH
sessions):

```bash
mkdir -p /root/pve-config && cd /root/pve-config
curl -fsSL https://github.com/tykeal/homeassistant-pve-config/archive/refs/heads/main.tar.gz \
  | tar xz --strip-components=1
cp pve-config.env.example pve-config.env
chmod 0600 pve-config.env
nano pve-config.env              # fill in every CHANGEME

./pve-baseline.sh
reboot

# after the reboot, as root on the console, or over SSH as the admin:
#   ssh -A admin@host
#   sudo -i
cd /root/pve-config
./pve-guests.sh
```

A published release tarball works the same way; download
`pve-config-<tag>.tar.gz` and its `.sha256` from the releases page, check
it with `sha256sum -c`, and unpack it.

Both scripts read `pve-config.env` from their own directory, or the file
given with `--config PATH`. They stop at the first error.

## What pve-baseline.sh does

1. Sets the hostname to `<installer short name>.<DOMAIN>`.
2. Removes every apt source pointing at `enterprise.proxmox.com` (PVE and
   Ceph) and adds `pve-no-subscription` for the installed Debian release.
3. Removes the subscription nag and installs an apt hook that re-applies
   that after upgrades.
4. Runs `apt-get full-upgrade` and installs `isc-dhcp-client`, `sudo`,
   `libpam-ssh-agent-auth` and `curl`.
5. Writes `/etc/network/interfaces` with every wired NIC as a port of
   `vmbr0` and `vmbr0` on DHCP, so whichever port gets plugged in at the
   site works.
6. Adds a dhclient hook keeping `/etc/hosts` in step with the DHCP address.
7. Sets the Postfix `myhostname`.
8. Restarts networking and waits for a lease.
9. Rewrites `/etc/hosts` with the leased address.
10. Makes `pve-cluster` wait at boot until `vmbr0` has its address.
11. Restarts `pve-cluster`, renames the node directory if needed, restarts
    the remaining Proxmox services.
12. Creates `ADMIN_USER` with `ADMIN_PUBKEYS`, in the `sudo` group and as a
    Proxmox `PVEAdmin` on `/`.
13. Sets sshd to keys only (`PermitRootLogin prohibit-password`).
14. Sets up passwordless `sudo` through the forwarded SSH agent
    (`pam_ssh_agent_auth`); connect with `ssh -A`.
15. Writes root's `.bashrc` (colours, safe aliases, backspace fix).
16. Installs the Zulip notifier (see below).

It finishes with a short verification summary.

## What pve-guests.sh does

1. **ACME** (skipped when `DME_API_KEY` is blank): adds the DNS Made Easy
   plugin, registers a Let's Encrypt account (staging with
   `ACME_STAGING=1`), sets `acmedomain0` to the host FQDN and orders the
   certificate. Proxmox renews it automatically.
2. **Home Assistant OS VM** with community-scripts `vm/haos-vm.sh` in its
   unattended mode: VMID `HAOS_VMID` (200), CPU type `host`, the current
   stable release, started and set to start on boot.
3. **Tailscale container** with community-scripts `ct/debian.sh`: CTID
   `TS_CTID` (100), unprivileged, nesting and `/dev/net/tun`, no IPv6,
   1 core / 512 MB / 2 GB. Inside it installs Tailscale, enables IPv4
   forwarding, joins the tailnet with `TS_AUTHKEY` (`--accept-routes`),
   installs the boot-time route advertiser (see below), and creates
   `ADMIN_USER` with the same key-only SSH and SSH-agent `sudo` as the host.
4. **Frigate container** with community-scripts `ct/frigate.sh`: CTID
   `FRIGATE_CTID` (101), privileged, GPU passthrough when `/dev/dri`
   exists. Unless set, it gets a quarter of the host RAM (2048-6144 MB)
   and half the cores (2-8).

It finishes with a summary of guest IDs, addresses and what remains.

## Configuration

Everything lives in `pve-config.env`; `pve-config.env.example` documents
each setting. Required:

| Setting | Used by | Meaning |
| ------- | ------- | ------- |
| `DOMAIN` | baseline | DNS domain of the host |
| `ADMIN_USER` | both | admin login on the host and the Tailscale container |
| `ADMIN_PUBKEYS` | both | that user's SSH public keys, one per line |
| `TS_AUTHKEY` | guests | Tailscale auth key |

Optional: `BRIDGE_PORTS`, the `ZULIP_*` and ACME settings, guest IDs,
names and sizes, storage names, and the community-scripts pins
(`COMMUNITY_SCRIPTS_REF`, `COMMUNITY_SCRIPTS_CORE_REF`; set both to `main`
to follow upstream).

Never commit `pve-config.env`; `.gitignore` excludes it.

## Zulip notifications

`pve-baseline.sh` always installs `/usr/local/bin/zulip-notify.sh` and the
`zulip-boot-notify` and `zulip-shutdown-notify` services. The credentials
go in `/etc/zulip-notify.env` (mode 0600). With the `ZULIP_*` settings
filled in, the baseline enables the services straight away. With them
blank, the notifier does nothing and the services stay disabled.

To turn it on later:

```bash
nano /etc/zulip-notify.env       # fill in all four values
systemctl enable zulip-boot-notify.service
systemctl enable --now zulip-shutdown-notify.service
/usr/local/bin/zulip-notify.sh boot
```

## Tailscale subnet routes

The host ships to a network whose subnet is unknown at setup time, so the
Tailscale container never hard-codes its routes. A small service,
`ts-advertise-routes.service`, runs
`/usr/local/sbin/ts-advertise-routes.sh` on every boot. It waits for `eth0`
to hold a DHCP address and for Tailscale to be up, reads the connected
subnets with `ip -4 route show dev eth0 proto kernel scope link`, and runs
`tailscale set --advertise-routes=<those subnets>`, replacing whatever the
setup site advertised.

Tailscale does not use a newly advertised route until somebody approves it.
Either approve it in the admin console after the host comes up at its
site, or add an `autoApprovers` rule to the tailnet policy covering the
subnets and the router's tag, for example:

```json
"autoApprovers": {
  "routes": { "10.0.0.0/8": ["tag:pve-router"], "192.168.0.0/16": ["tag:pve-router"] }
}
```

Use a **tagged** auth key (for example `tag:pve-router`). Tagged nodes have
key expiry turned off, so the router does not drop off the tailnet after
the default expiry period. With an untagged key, turn off key expiry for
the node in the admin console.

## community-scripts and prompts

The guests come from
[community-scripts](https://github.com/community-scripts/ProxmoxVE),
pinned to the commits in `pve-config.env.example`. The scripts run them
without a terminal:

- `vm/haos-vm.sh` runs with `VM_UNATTENDED=1` and `VM_*` overrides.
- The container scripts run with `mode=default` and `var_*` settings.
- `/usr/local/community-scripts/default.vars` gets the storage choices,
  and `/usr/local/community-scripts/diagnostics` gets
  `DIAGNOSTICS=no` unless it already exists, so no menus appear.
- The builders run under `setsid` with stdin from `/dev/null`. Their
  remaining prompts, such as Frigate's GPU choice (`read -t 60 </dev/tty`),
  then fail at once and take their default: all detected GPUs.

## Not handled

- Home Assistant onboarding or backup restore. Home Assistant releases
  from 2026.7 may default to port 80; move it back to 8123 if Nginx Proxy
  Manager is in use.
- Frigate configuration, cameras and recording storage.
- Approving Tailscale routes and key expiry (see above).
- Static addressing, VLANs, extra bridges, clustering, ZFS layout.
- Re-running on a configured host.

## Tests

```bash
bats tests/
```

The tests cover the small pure helpers (NIC detection, Frigate sizing) and
the two installed helper scripts. Everything else touches a real Proxmox
host, so only a hardware run can verify it.

## Contributing

Read [AGENTS.md](AGENTS.md) for commit conventions and the development
workflow.

## License

Apache-2.0. See [LICENSES](LICENSES/).
