<!--
SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
SPDX-License-Identifier: Apache-2.0
-->

# pve-config

A toolkit of bash scripts that configure a bare-metal Proxmox VE host into a
Home Assistant platform. You run it as `root` from a Proxmox VE shell.

## What this is and what it builds

`pve-config` converges a freshly installed Proxmox VE host into a known
system:

- a Proxmox VE host with its hostname, management bridge, apt sources,
  administrators and SSH policy set
- a Home Assistant OS VM
- a Tailscale LXC
- a Frigate LXC

The toolkit handles **more than one customer**. The code carries no customer
value:
each deployment supplies its own configuration file, so the same toolkit
builds every site. The toolkit also stays **idempotent**. Each stage
converges rather than asserts, so a second run against a configured host
changes nothing.

Phase 1 (the host) ships today. Phase 2 (certificates and guests) does not.
See [Status](#status).

## Prerequisites

- A freshly installed Proxmox VE host. The stages refuse to run on a machine
  that has no `pveversion`, `pvesh` or `pvecm`.
- A root shell on that host, over the console or SSH. Keep console or
  out-of-band access available: phase 1 rewrites the networking and the SSH
  policy of the machine you are probably sitting on.
- `curl` and `tar` on the host, which a stock Proxmox install carries.
- **A DHCP reservation for the host.** The management bridge takes its
  address from DHCP by design, so the host needs a stable lease. Create the
  reservation against the MAC of the NIC that carries the uplink before you
  start. Without one the address moves, and `/etc/hosts`, the certificate
  and the guests all end up pointing at the wrong place.

The toolkit also accepts a static address through
`PVE_BRIDGE_MODE='static'`, but DHCP with a reservation remains the
documented path.

## Bootstrap

Install the toolkit with one command on the host:

```shell
bash -c "$(curl -fsSL https://raw.githubusercontent.com/tykeal/homeassistant-pve-config/main/bootstrap.sh)"
```

The installer unpacks the repository into `/root/pve-config` and stops.
Running the configuration takes a separate, deliberate act.

The installer:

- downloads the repository tarball from codeload, then rejects any archive
  whose entries escape the extraction root or carry a link
- assembles `pve-config.sh`, `bootstrap.sh`, `lib/`, `stages/` and
  `examples/` into a staging tree beside the install directory
- carries `pve-config.conf`, `secrets.env`, `state/` and `keys/` across from
  an existing install, so an upgrade keeps your configuration, your
  credentials and the record of what has already run
- marks the driver and the stages executable, creates `state/`, then swaps
  the tree into place by rename

Three environment variables steer it:

| Variable | Default | Meaning |
| --- | --- | --- |
| `PVE_CONFIG_REF` | `main` | Git ref to install. Pin a tag or commit for a reproducible build |
| `PVE_CONFIG_DIR` | `/root/pve-config` | Install directory |
| `PVE_CONFIG_REPO` | `tykeal/homeassistant-pve-config` | Source repository |

To pin a ref:

```shell
PVE_CONFIG_REF=v1.0.0 bash -c "$(curl -fsSL https://raw.githubusercontent.com/tykeal/homeassistant-pve-config/main/bootstrap.sh)"
```

A ref containing a slash works; the installer percent-encodes it.

`bootstrap.sh --help` prints usage and skips the root check.

## Configuration model

Two files live in `/root/pve-config`:

- `pve-config.conf`, mode 0644, holds everything other than a credential
- `secrets.env`, mode 0600 and root-owned, holds the credentials

Both use `KEY="value"` assignments. The toolkit **parses** them rather than
sourcing them, so loading a file runs no command out of it. Anything other
than a blank line, a `#` comment or a quoted literal assignment aborts the
run and names the file and the line. Single and double quotes both work; a
double quoted value may not contain anything the shell would expand.

Parsing covers the load. Downstream, a stage that bakes a configured value
into a script it generates writes that value as a single-quoted assignment
the generated script reads back as a literal, so nothing in a config file is
ever read as shell syntax. The driver also holds `PVE_HOSTNAME` and
`PVE_FQDN` to the DNS label rules, whatever the value came from. Keep both
files at the permissions the toolkit sets.

Name every config key `PVE_*`, in capitals, digits and underscores. The
loader does not skip any other name: it treats the assignment as a line it
refuses to interpret and aborts the run, naming the file and the line. That
is what stops a config file from exporting `PATH` or `BASH_ENV`. The toolkit
reserves the `PVE_CONFIG_*` prefix for the directories it reads and writes,
and rejects those from a file the same way; set them in the environment
instead. Keep unrelated shell assignments out of these files.

### Precedence

For each key the driver takes the first of:

1. **Environment** — an exported variable wins, even when you export it
   empty. An explicit export means a deliberate override.
2. **Config file** — the value a previous run stored. An empty value here
   means "work it out", because the shipped example carries blank
   placeholders.
3. **Prompt** — pre-filled with the derived default. `--non-interactive`
   skips this step.
4. **Derived default** — read off the host.

A stored key counts as answered even when it holds an empty string, which
differs from a key the file omits. For a required key with no derivation —
`PVE_DOMAIN` and `PVE_ADMIN_USERS` — an empty stored value skips the
prompt and aborts the run with `Missing required configuration`. Fill
the key in, or clear the stored answers with `--reconfigure`.

The driver resolves the whole schema before any stage runs, then writes the
answers back. Stages run as child processes, so a value a stage resolved
could never reach the driver for saving; resolving up front makes every run
after the first unattended.

Deriving a default is not the same as skipping a question. An interactive
first run, with no config file to read, prompts for every schema key in
turn. The derivation decides how much of that work you do: the hostname,
FQDN, Debian suite, uplink NIC and the plain yes/no settings all arrive
pre-filled, so you press return through them, while the domain, the
administrators and their key start blank because no machine can know them.
A later run finds the stored answers and asks nothing.

### Schema keys

The driver resolves these keys on every run.

| Key | Required | Default or derivation | Meaning |
| --- | --- | --- | --- |
| `PVE_HOSTNAME` | yes | the running short hostname | Short hostname for this host, as a DNS label |
| `PVE_DOMAIN` | yes | none, so the driver asks | DNS domain for this deployment |
| `PVE_FQDN` | yes | `PVE_HOSTNAME`.`PVE_DOMAIN`, else the resolver's answer | Fully qualified domain name, starting with `PVE_HOSTNAME` |
| `PVE_ADMIN_USERS` | yes | none, so the driver asks | Space separated admin usernames to create |
| `PVE_ADMIN_KEY_SOURCE` | no | none | SSH public key shared by every admin: a literal `ssh-...` string, or a path to a file holding one or more keys |
| `PVE_SUITE` | yes | `VERSION_CODENAME` from `/etc/os-release` | Debian suite for the Proxmox apt sources |
| `PVE_BRIDGE_PORTS` | yes | the single NIC carrying the default route | Physical interfaces to enslave to `vmbr0`, space separated |
| `PVE_BRIDGE_MODE` | yes | `dhcp` | Addressing for `vmbr0`: `dhcp` or `static` |
| `PVE_BRIDGE_ADDRESS` | no | none | Static CIDR address for `vmbr0`; the stage reads it only in `static` mode |
| `PVE_BRIDGE_GATEWAY` | no | none | Default gateway; the stage reads it only in `static` mode |
| `PVE_NETWORK_WAIT_SECONDS` | yes | `60` | Seconds to wait for `vmbr0` to pick up an address |
| `PVE_NO_SUBSCRIPTION` | yes | `yes` | Use the no-subscription repository and suppress the subscription notice |
| `PVE_SUDO_SSH_AGENT` | yes | `yes` | Let `sudo` accept a forwarded SSH agent key |
| `PVE_ZULIP_ENABLED` | yes | `no` | Send boot and shutdown notices to Zulip |
| `PVE_ZULIP_STREAM` | no | the stage falls back to `infrastructure` | Zulip stream for the notices |
| `PVE_ZULIP_TOPIC` | no | the notifier falls back to the host FQDN | Zulip topic for the notices |

Derivation of `PVE_BRIDGE_PORTS` fails when the host has no default route,
or carries more than one. The driver then names what it found and asks,
rather than guessing and taking the host off the network.

`PVE_HOSTNAME` must be a DNS label, and `PVE_FQDN` a dotted name whose
labels are DNS labels and whose first label is `PVE_HOSTNAME`. The driver
checks both whatever the value came from, and names the one it refused.
Both names reach `/etc/hosts` and a hook that root runs on every DHCP
lease.

### Keys the stages and the example read

The schema omits these, so the driver never prompts for them. Set them in
the config file or the environment when you need them.

| Key | Default | Meaning |
| --- | --- | --- |
| `PVE_NETWORK_TAKEOVER` | `no` | Let the network stage replace an `/etc/network/interfaces` that describes more than `lo`, the bridge ports and `vmbr0` |
| `PVE_ADMIN_KEY_<USERNAME>` | none | Per-user key source, overriding `PVE_ADMIN_KEY_SOURCE`. Uppercase the username and turn any `-` into `_` |

The shipped `examples/pve-config.conf.example` also carries keys that phase
2 will read. They do nothing today, and the driver preserves them across a
rewrite: `PVE_ACME_ENVIRONMENT`, `PVE_ACME_EMAIL`, `PVE_ACME_DNS_PLUGIN`,
`PVE_TAILSCALE_HOSTNAME`, `PVE_TAILSCALE_CTID`, `PVE_HAOS_HOSTNAME`,
`PVE_HAOS_VMID`, `PVE_HAOS_RAM_MB`, `PVE_HAOS_CORES`,
`PVE_FRIGATE_HOSTNAME`, `PVE_FRIGATE_CTID`, `PVE_COMMUNITY_SCRIPTS_REPO` and
`PVE_COMMUNITY_SCRIPTS_REF`.

### Secret keys

`examples/secrets.env.example` lists the credentials. Phase 1 reads only the
Zulip three; the rest wait on phase 2.

| Key | Used by | Meaning |
| --- | --- | --- |
| `PVE_ZULIP_SITE` | phase 1 | Zulip server URL for the notifier |
| `PVE_ZULIP_BOT_EMAIL` | phase 1 | Zulip bot address |
| `PVE_ZULIP_BOT_API_KEY` | phase 1 | Zulip bot API key |
| `PVE_DNSMADEEASY_KEY` | phase 2 | DNS Made Easy API key for the ACME DNS-01 challenge |
| `PVE_DNSMADEEASY_SECRET` | phase 2 | DNS Made Easy API secret |
| `PVE_TAILSCALE_AUTHKEY` | phase 2 | Tailscale pre-authentication key for the LXC |

Enabling Zulip without all three of its values aborts the stage. A
deployment that opts out with `PVE_ZULIP_ENABLED='no'` passes quietly.

## Running it

```shell
cd /root/pve-config
./pve-config.sh --list
./pve-config.sh --dry-run
./pve-config.sh
```

### The two phases

Phase 1 configures the host and ends with a reboot you perform. Phase 2 will
order the ACME certificate and create the guests.

When phase 1 first reaches completion the driver prints a summary — hostname,
`vmbr0` address, node directory, the state of `pve-cluster`, `pveproxy`,
`pvedaemon` and `pvestatd`, the apt suite and the administrators — then asks
you to reboot. It reads that summary back off the host rather than echoing
the values that went in.

Reboot, then run `./pve-config.sh` again to continue.

### Why the driver enforces the reboot

The driver records the kernel's boot id when phase 1 finishes. Before
starting phase 2 it compares that id against the running one. Equal means
the host has not rebooted since, and the driver refuses with a message
telling you to reboot. The boot id changes on a reboot and on nothing else,
which distinguishes "the operator rebooted" from "the operator ran the
driver twice". A host where the driver cannot read a boot id never hits the
gate.

### Flags

| Flag | Effect |
| --- | --- |
| `--list` | Print every discovered stage with its phase and `done`/`pending` status. Needs no root and touches nothing |
| `--phase N` | Run only the stages in phase `N` |
| `--stage NAME` | Run one stage. `NAME` is the basename with or without `.sh`, or the qualified `phase1__NAME` or `phase1/NAME` when the basename exists in more than one phase. The driver rejects an ambiguous bare name |
| `--force` | Re-run the selected stages even when their markers say done |
| `--reconfigure` | Prompt again for the schema keys. Every other key in the file survives the rewrite untouched. It changes no marker, so pair it with `--force` to apply the answers |
| `--dry-run` | Run the stages and change nothing. Needs no root |
| `--config PATH` | Use an alternate configuration file instead of `pve-config.conf` |
| `--non-interactive` | Never prompt. A required value with no default aborts the run, and the driver reports all such keys at once |
| `-h`, `--help` | Print usage |

With no flag the driver picks the lowest phase that still has pending
stages, and runs that whole phase. Once every stage reaches `done` the
driver reports that and exits.

`--force` on its own means "re-run what I would have run". That means the
current phase, and while the reboot phase 1 asked for remains owed, the
current phase is phase 1 rather than phase 2. When every stage already says
`done`, bare `--force` re-runs the last phase rather than doing nothing.

`--reconfigure` re-asks the questions; it does not re-run anything. On a
host whose stages all say `done` the driver reports that and exits before it
ever reaches configuration resolution, so `--reconfigure` on its own has no
effect there. To change an answer and apply it, name the work as well:

```shell
./pve-config.sh --reconfigure --force --phase 1
```

`--force` does **not** open the reboot gate on its own. Only a phase or a
stage you name explicitly — `--force --phase 2` or `--force --stage ...` —
overrides the gate, and the driver warns when it does.

## The phase-1 stages

| Stage | Converges |
| --- | --- |
| `10-hostname` | Sets the kernel hostname to the FQDN, writes the short name to `/etc/hostname`, and points Postfix `myhostname` at the FQDN on a host that runs Postfix |
| `20-network` | Writes `/etc/network/interfaces` describing `lo`, the bridge ports and `vmbr0`; installs a dhclient exit hook that keeps `/etc/hosts` on the leased address; reloads, then waits for an address |
| `30-pve-cluster` | Holds `pve-cluster` until `vmbr0` has an address `/etc/hosts` knows, starts it, renames the stale node directory to the new hostname, then starts `pvedaemon`, `pveproxy` and `pvestatd` |
| `40-repos` | Drops the enterprise apt sources, installs the `pve-no-subscription` source for the running suite, migrates an enterprise Ceph source to its public counterpart, then refreshes the indexes |
| `50-no-nag` | Installs a patch script and an apt post-invoke hook that suppress the subscription notice, and re-apply it after every `proxmox-widget-toolkit` upgrade |
| `60-admin-users` | Creates each administrator, adds them to `sudo`, installs their keys, then registers them in Proxmox as `user@pam` with the `PVEAdmin` role on `/` |
| `70-ssh-sudo` | Confirms every administrator can already log in with a key, then turns off password and keyboard-interactive authentication and restricts root to keys; optionally wires `sudo` to `pam_ssh_agent_auth` |
| `80-root-shell` | Writes a `/root/.bashrc` with coloured `ls`, interactive `rm`/`cp`/`mv` aliases and a backspace fix that stays out of the way of `scp` |
| `90-zulip` | Optional. Installs a notifier, a 0600 credentials file and systemd units that announce the host coming up and going down |

Stages 40 and 50 exit early unless `PVE_NO_SUBSCRIPTION` says `yes`. Stage
90 exits early unless `PVE_ZULIP_ENABLED` says `yes`.

## Idempotency and safety

Every stage converges. A second run finds the host already in the desired
state and reports `unchanged`. The helpers compare before they write, so
they leave a file whose content already matches alone, mtime intact.

The safeguards below work to keep you from locking yourself out. They are
checks, not a guarantee. The network stage judges success by whether
`vmbr0` holds an address, which it can do while a wrong static gateway
leaves an off-subnet SSH session cut off, and no check can prove a route
you cannot test from the host. Have console or out-of-band access to hand
before you let a run touch networking or SSH policy.

- **It validates sshd and sudoers before install.** `install_validated`
  writes the candidate into a root-only scratch directory, runs `sshd -t -f`
  or `visudo -c -f` against it, then installs it atomically only on a pass.
  No path skips this check.
- **It verifies SSH keys before turning passwords off.** Stage 70 checks,
  for every administrator, that the account exists, that their
  `authorized_keys` carries the configured key as an active entry, and that
  at least one entry for that key carries no `from=`, `command=`, `restrict`
  or `no-pty` restriction the stage cannot verify a login through. It also
  checks that no `AuthorizedKeysFile` directive — global or under a `Match`
  — points anywhere other than `~/.ssh/authorized_keys`, and that
  `AllowUsers`, `DenyUsers`, `AllowGroups` and `DenyGroups` still admit
  every administrator. Any of these checks failing aborts the stage while
  passwords still work.
- **It reloads sshd rather than restarting it.** You are likely configuring
  the host over the connection a restart would drop.
- **The network stage rolls back.** It captures `/etc/network/interfaces`
  and `/etc/hosts` before activating the new description, and arms an exit
  trap. If `ifreload` fails, or `vmbr0` takes no address within
  `PVE_NETWORK_WAIT_SECONDS`, or anything else ends the stage inside that
  window, the trap puts the previous files back and reloads onto them. It
  disarms only once the bridge holds an address and `/etc/hosts` agrees
  with it.
- **The network stage refuses a destructive takeover.** It writes only `lo`,
  the bridge ports and `vmbr0`. When the existing file also describes a
  storage port, a VLAN or a second bridge, the stage stops and names them.
  Move them into `/etc/network/interfaces.d`, or set
  `PVE_NETWORK_TAKEOVER='yes'` to replace the file anyway.
- **It keeps the originals of the three files it rewrites wholesale.**
  Before first editing `/etc/network/interfaces`, `/etc/hosts` or
  `/root/.bashrc`, the toolkit copies the original to `<path>.pve-config.bak`.
  Stage 20 copies `/etc/hosts` aside before it installs the dhclient hook
  and before it reloads the network, so a lease arriving mid-run cannot get
  into the copy.
  A file that did not exist gets an empty `<path>.pve-config.absent`
  tombstone, so a later run cannot mistake the toolkit's own output for what
  you had. No other file carries this guarantee: stage 10 rewrites
  `/etc/hostname` and stage 70 rewrites its sshd fragment with no backup
  copy. Take your own backup of a host that holds anything you care about
  before provisioning it.
- **The driver writes completion markers last and clears them first.** It
  removes the marker of a forced stage before running it, so a stage that
  dies part way comes back as pending rather than keeping a stale claim of
  completion.

## Networking caveat

By default the driver enslaves only the NIC carrying the default route to
`vmbr0`. `PVE_BRIDGE_PORTS` overrides that when you need something else.

Bridging every port a machine happens to have is not safe. Two live ports in
one bridge with STP off give you an L2 loop and a broadcast storm — and the
stage writes `bridge-stp off`, as Proxmox does. On a multi-NIC host it also
merges networks you deliberately kept apart: a storage or WAN port would end
up on the management bridge.

When the host already carries a default route on `vmbr0` — the state of a
host this toolkit has configured — detection resolves the bridge back to the
ports it holds, so a re-run derives the same answer it did the first time.

Convention fixes the bridge name at `vmbr0`, and the toolkit offers no way
to change it. Every Proxmox document and support answer says `vmbr0`. The
stages read the name from a variable the prelude sets and deliberately does
not export, which keeps it out of reach of the config file.

## Secrets handling

`/root/pve-config/secrets.env` is the credential **input**. The driver
writes resolved secret values there at mode 0600 and skips them when writing
`pve-config.conf`, so a credential can never land in the world-readable
file.

A stage that needs a credential at runtime keeps its own copy. Stage 90
writes the Zulip site, bot address, bot API key, stream and topic to
`/etc/pve-config/zulip.env` at mode 0600, inside a 0700 directory, because
the notifier systemd starts has to read them. Editing or emptying
`secrets.env` leaves that copy as it stands; re-run the stage to rewrite it,
and rotate the credential at Zulip when you retire it.

The toolkit checks the file before reading it. It hard-fails when the file
is a symlink, when the path names something other than a regular file, when
any permission bit opens it to group or other, or — under root — when the
owner is anyone other than root. Fix the permissions rather than working
around the check:

```shell
chmod 600 /root/pve-config/secrets.env
chown root:root /root/pve-config/secrets.env
```

The toolkit registers every secret value for redaction, so the commands it
logs show a mask in place of the credential. It suspends shell tracing
around secret handling, because `set -x` would print a credential that
redaction never sees. Stages that write credentials to disk — the Zulip
environment file, for one — write them at 0600 under a 0700 directory.

You can also supply any secret as an environment variable. That does not
keep it off disk. When `secrets.env` already names the key, the driver
records your exported value and writes it back to that file; and stage 90
copies the Zulip credentials to `/etc/pve-config/zulip.env` whichever way
they arrived. An environment override stays off disk only for a key that
appears in neither file and that no stage persists.

## Dry run

`--dry-run` runs every selected stage for real and mutates nothing. It sets
`PVE_CONFIG_DRY_RUN=1`, which the helpers honour by logging the intended
change and making none, and the driver writes no completion marker.
Read-only validators still run, because their verdict is the point of
calling them. A dry run needs no root.

Preview a deployment this way:

```shell
./pve-config.sh --dry-run
```

## Troubleshooting

### State markers

`/root/pve-config/state` holds one `phase<N>__<stage>.done` file per
completed stage, each carrying its completion timestamp, plus a
`phase1.bootid` recording the boot phase 1 finished under.

```shell
./pve-config.sh --list          # phase, stage and status for every stage
ls -l /root/pve-config/state    # the markers themselves
cat /root/pve-config/state/phase1__20-network.done
```

### Re-running one stage

```shell
./pve-config.sh --stage 20-network --force
./pve-config.sh --stage 20-network --force --dry-run
```

Deleting a marker by hand has the same effect as `--force` for that stage.

### A stage failed

The driver stops at the first failure and leaves later stages untouched. Fix
the cause and re-run `./pve-config.sh`; it skips the completed stages and
picks up where it stopped.

### Bootstrap failed mid-swap

The installer moves the old tree to `/root/pve-config.old` before renaming
the new one into place, and each error message names the location:

- A message that the installer restored the previous install means the old
  tree sits back at `/root/pve-config`. Nothing more to do.
- A message that no previous installation existed means you lost no tree.
  Run the bootstrap again.
- A message demanding manual recovery names `/root/pve-config.old`. Move it
  back yourself:

  ```shell
  mv /root/pve-config.old /root/pve-config
  ```

A later bootstrap run refuses to start while `/root/pve-config.old` exists,
because that directory may hold the only copy of an installation. Move it
back or delete it first.

### Configuration errors

- `expected PVE_KEY='value'; refusing to interpret this line` — the config
  file holds something the parser will not accept. The message names the
  file and the line.
- `Missing required configuration: ...` — a `--non-interactive` run has keys
  with no value and no default. Set them in the config file or the
  environment, or drop `--non-interactive`.
- `This does not look like a Proxmox VE host` — the stages found no
  `pveversion`, `pvesh` or `pvecm`.

## Status

- **Phase 1 — implemented.** The nine host stages above.
- **Phase 2 — not yet implemented.** The ACME certificate and the Tailscale,
  Home Assistant OS and Frigate guests remain a later effort. Their
  configuration keys already appear in the example file and survive a
  rewrite, but no stage reads them yet.

## Contributing

Read [AGENTS.md](AGENTS.md) for commit conventions, coding standards and the
test and review workflow, and [stages/README.md](stages/README.md) for the
stage contract.

## License

Apache-2.0. See [LICENSES](LICENSES/).
