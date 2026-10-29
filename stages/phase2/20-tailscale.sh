#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

# Nothing above this block may fork, and the block itself uses builtins
# only.
#
# The driver's secrets loader exports what it reads, so this process
# starts with the Tailscale auth key in its environment, and every fork
# hands a child a copy of it. Sourcing a library is already a fork:
# stage.sh runs stage_require_proxmox as it loads and that calls
# $(sysroot). So the capture happens here, before the first `source`, with
# plain parameter assignment and `unset`.
#
# Tracing goes off at the same time and stays off until the stage has
# finished with the key, and PS4 is replaced with a known safe one. An
# inherited PS4 is code: it is expanded for every traced command, so one
# that dereferences a variable prints whatever that variable holds. One
# command -- the `case` below -- is still traced with the inherited
# prefix, before this shell can do anything about it, and at that point no
# credential has been read into a variable of this script's.
case ${-} in
  *x*) _TS_BOOT_XTRACE=1 ;;
  *) _TS_BOOT_XTRACE=0 ;;
esac
set +x
PS4='+ '
_TS_BOOT_KEY_SET=${PVE_TAILSCALE_AUTHKEY+set}

# Tracing that was already on when this shell started, with the key
# already in the environment, is the one leak no boot block can prevent:
# bash expands the inherited PS4 for the very first command it runs, and
# the first command it runs is the one that would turn tracing off. The
# run stops here rather than letting that prefix expand against every
# remaining command, and an operator who sees this has a key to revoke and
# wants to hear it now.
if [[ ${_TS_BOOT_XTRACE} -eq 1 && -n ${_TS_BOOT_KEY_SET} ]]; then
  printf '%s\n' \
    'pve-config: refusing to run the Tailscale stage with tracing already enabled and PVE_TAILSCALE_AUTHKEY in the environment.' \
    'Bash expands PS4 before the first command of this script, so a key supplied this way has already been exposed to whatever that prefix does, and to anything reading this trace. Revoke the key in the Tailscale admin console and issue another.' \
    'Run without tracing, or put the key in the 0600 secrets file instead of the environment, which is the supported way and never exposes it to a trace at all.' >&2
  exit 1
fi
_TS_BOOT_KEY=${PVE_TAILSCALE_AUTHKEY:-}
unset PVE_TAILSCALE_AUTHKEY

# shellcheck source=lib/stage.sh
source "${PVE_CONFIG_LIB_DIR:?PVE_CONFIG_LIB_DIR is unset}/stage.sh"
# shellcheck source=lib/tailscale.sh
source "${PVE_CONFIG_LIB_DIR}/tailscale.sh"
# shellcheck source=lib/guest-admin.sh
source "${PVE_CONFIG_LIB_DIR}/guest-admin.sh"

# The libraries take over the capture, and the secret region the block
# above opened by hand stays open until the key is gone.
tailscale_authkey_adopt "${_TS_BOOT_XTRACE}" "${_TS_BOOT_KEY_SET}" "${_TS_BOOT_KEY}"
_TS_BOOT_KEY=''

# A deployment that reaches its network another way says so once and is
# left alone. No container is built, and the key -- which may well be
# unset -- is dropped without being looked at.
if [[ ${PVE_TAILSCALE_ENABLED:-no} != yes ]]; then
  tailscale_authkey_discard
  log_info 'PVE_TAILSCALE_ENABLED is not yes; not building a Tailscale subnet router'
  exit 0
fi

stage_require PVE_TAILSCALE_HOSTNAME

# The daemon's own report is read with a JSON decoder, and a run that
# cannot decode it refuses to spend an auth key. Saying so here, once,
# beats the same answer arriving as "could not tell" much later.
json_require_decoder

# Put back whatever this run moves aside, and take the auth key file with
# it, however the run ends.
trap 'tailscale_cleanup' EXIT
trap 'tailscale_cleanup; exit 1' HUP INT TERM

hostname=${PVE_TAILSCALE_HOSTNAME}
if ! tailscale_hostname_valid "${hostname}"; then
  tailscale_authkey_discard
  die "PVE_TAILSCALE_HOSTNAME is '${hostname}', which is not a container hostname: lowercase letters, digits and hyphens, starting and ending with a letter or a digit, at most 63 characters."
fi

# The key is read now and demanded later. A malformed one is an error
# wherever it is found -- a dry run is the cheapest place to hear about a
# truncated paste -- but an absent one is only an error on a path that
# creates or authenticates a machine. An operator who revokes a spent key,
# which is the right thing to do with a spent key, must still be able to
# re-run this stage against a container that is already joined.
tailscale_secret_begin
have_authkey=0
if tailscale_authkey_read "${PVE_CONFIG_DIR:-/root/pve-config}/secrets.env"; then
  have_authkey=1
fi

advertise_routes=''
tailscale_routes_resolve advertise_routes "${PVE_TAILSCALE_ROUTES:-}" "${PVE_BRIDGE_NAME}"

ctid=''
tailscale_ctid_resolve ctid "${PVE_TAILSCALE_CTID:-}" \
  "${PVE_TAILSCALE_ADOPT_EXISTING:-no}"

ram=''
cores=''
tailscale_resources ram cores
if [[ -n ${PVE_TAILSCALE_RAM_MB:-} ]]; then
  if [[ ! ${PVE_TAILSCALE_RAM_MB} =~ ^[1-9][0-9]*$ ]]; then
    tailscale_secret_die "PVE_TAILSCALE_RAM_MB is '${PVE_TAILSCALE_RAM_MB}', which is not a number of megabytes." TAILSCALE_AUTHKEY
  fi
  ram=${PVE_TAILSCALE_RAM_MB}
fi
if [[ -n ${PVE_TAILSCALE_CORES:-} ]]; then
  if [[ ! ${PVE_TAILSCALE_CORES} =~ ^[1-9][0-9]*$ ]]; then
    tailscale_secret_die "PVE_TAILSCALE_CORES is '${PVE_TAILSCALE_CORES}', which is not a number of cores." TAILSCALE_AUTHKEY
  fi
  cores=${PVE_TAILSCALE_CORES}
fi

# The disk is not scaled. A subnet router holds a package, a state file
# and its logs; 2 GB is what the runbook this is built from asks for and
# what upstream's own Debian template defaults to, and a node with more
# room has nothing to do with it.
disk=${PVE_TAILSCALE_DISK_GB:-2}
if [[ ! ${disk} =~ ^[1-9][0-9]*$ ]]; then
  tailscale_secret_die "PVE_TAILSCALE_DISK_GB is '${disk}', which is not a number of gigabytes." TAILSCALE_AUTHKEY
fi

ct_state=unchanged
if tailscale_ct_exists "${ctid}"; then
  log_info "adopting existing container ${ctid} (${hostname}); converging it rather than building another"
else
  # A container that does not exist cannot already be logged in, so this
  # path needs the key whatever happens later.
  tailscale_authkey_require 'build the subnet router and join it to your tailnet'

  template_setting=PVE_TAILSCALE_STORAGE
  template_configured=${PVE_TAILSCALE_STORAGE:-}
  if [[ -n ${PVE_TAILSCALE_TEMPLATE_STORAGE:-} ]]; then
    template_setting=PVE_TAILSCALE_TEMPLATE_STORAGE
    template_configured=${PVE_TAILSCALE_TEMPLATE_STORAGE}
  fi
  container_setting=PVE_TAILSCALE_STORAGE
  container_configured=${PVE_TAILSCALE_STORAGE:-}
  if [[ -n ${PVE_TAILSCALE_CONTAINER_STORAGE:-} ]]; then
    container_setting=PVE_TAILSCALE_CONTAINER_STORAGE
    container_configured=${PVE_TAILSCALE_CONTAINER_STORAGE}
  fi

  # Resolved apart and checked apart. The commonest Proxmox layout keeps
  # templates on `local` and root disks on `local-lvm` or a ZFS pool, and
  # neither accepts the other's content.
  template_storage=''
  container_storage=''
  tailscale_storage_resolve template_storage vztmpl \
    "${template_configured}" "${template_setting}"
  tailscale_storage_resolve container_storage rootdir \
    "${container_configured}" "${container_setting}"

  tailscale_diagnostics_warn
  # The builder's storage answers are set aside and put back here, in the
  # stage's own shell, so that the cleanup trap can restore the
  # operator's file however this run ends. state_of collects its state
  # through a command substitution, and a subshell that is killed takes
  # the knowledge of what to restore with it.
  if ! dry_run_enabled; then
    tailscale_default_vars_push "${template_storage}" "${container_storage}"
  fi
  state_of ct_state tailscale_ct_create "${ctid}" "${hostname}" \
    "${ram}" "${cores}" "${disk}" "${PVE_BRIDGE_NAME}" \
    "${template_storage}" "${container_storage}"
  tailscale_default_vars_pop
fi
if [[ ${ct_state} == changed ]]; then
  log_info "built container ${ctid} (${hostname}) with ${ram} MB and ${cores} core(s)"
fi

# The mark the next run's adoption check looks for, put on before this one
# changes anything else about the container.
tag_state=unchanged
state_of tag_state tailscale_ct_tag_converge "${ctid}"
if [[ ${tag_state} == changed ]]; then
  log_info "tagged container ${ctid} with ${TAILSCALE_OWNER_TAG}"
fi

# Whether the builder wrote these or not. `var_tun` is read at create time
# only, so a container that predates this stage never got them, and a
# container that did get them is unharmed by being asked again.
tun_state=unchanged
state_of tun_state tailscale_tun_converge "${ctid}"
if [[ ${tun_state} == changed ]]; then
  log_info "gave container ${ctid} access to /dev/net/tun"
fi

start_state=unchanged
state_of start_state tailscale_ct_start "${ctid}"

# A container that was already running when the TUN lines were added is
# running without them: an LXC reads its configuration when it starts.
# One that this stage has just started, or just built, read them already.
if [[ ${tun_state} == changed && ${start_state} == unchanged ]]; then
  log_info "restarting container ${ctid} so it picks up /dev/net/tun"
  tailscale_ct_restart "${ctid}" >/dev/null
fi

target=$(target_guest "${ctid}")

# /dev/net/tun is what tailscaled routes through. Saying so here, by name,
# beats the backend error it would otherwise produce after the package had
# been installed. A dry run has no container to ask.
if ! dry_run_enabled && ! target_test "${target}" e /dev/net/tun; then
  tailscale_secret_die "Container ${ctid} has no /dev/net/tun even after its configuration was updated and it was restarted. Check $(tailscale_ct_conf_path "${ctid}") on this node." TAILSCALE_AUTHKEY
fi

codename=''
if dry_run_enabled && ! target_test "${target}" f /etc/os-release; then
  # The container a dry run would have built cannot be asked what it is.
  # The suite the node runs is what the builder would install.
  codename=$(detect_debian_suite 2>/dev/null) || codename=''
  [[ -n ${codename} ]] || codename=trixie
  log_info "assuming the container would run Debian ${codename}"
else
  tailscale_guest_codename codename "${target}"
fi

# The install flow tools/addon/add-tailscale-lxc.sh performs, reproduced
# here because that script cannot be driven: it stops on a `read -rp`
# confirmation and then on a whiptail list of container ids, and neither
# can be answered from the environment.
# The addon installs curl before it reaches for the repository key, and so
# does this: a minimal Debian template has no curl, and the key is fetched
# inside the container rather than carried in through a shell variable.
curl_state=unchanged
state_of curl_state target_pkg_install "${target}" curl ca-certificates
if [[ ${curl_state} == changed ]]; then
  log_info "installed curl in container ${ctid} so the repository key can be fetched"
fi

key_state=unchanged
state_of key_state tailscale_keyring_converge "${target}" "${codename}"

sources_state=unchanged
state_of sources_state target_write_file "${target}" "${TAILSCALE_SOURCES_PATH}" \
  "$(tailscale_sources_body "${codename}")" 0644

# The addon leaves these behind and so does this stage: the deb822 source
# above names /usr/share/keyrings/tailscale.gpg, and a stale keyring under
# the old name is a key apt still trusts for no reason. The one-line
# source that went with it has to go at the same time, or apt sees the
# same repository twice with two different Signed-By values and refuses
# to update at all.
legacy_state=unchanged
state_of legacy_state target_remove_path "${target}" "${TAILSCALE_LEGACY_SOURCES_PATH}"
target_remove_path "${target}" "${TAILSCALE_LEGACY_KEYRING_PATH}" >/dev/null

# A refresh that failed last run left the keyring and the sources file in
# place, so nothing here would look changed and target_pkg_install would
# go straight to an apt-get install with no package index behind it.
# Tailscale still being absent is the evidence that the refresh has not
# happened yet.
if [[ ${key_state} == changed || ${sources_state} == changed ||
  ${legacy_state} == changed ]] ||
  ! target_pkg_is_installed "${target}" tailscale; then
  log_info 'refreshing the apt package lists for the Tailscale repository'
  target_apt_update "${target}"
fi

pkg_state=unchanged
state_of pkg_state target_pkg_install "${target}" tailscale
if [[ ${pkg_state} == changed ]]; then
  log_info "installed tailscale in container ${ctid}"
fi

target_service_enable "${target}" tailscaled >/dev/null
target_service_start "${target}" tailscaled >/dev/null

forwarding_state=unchanged
state_of forwarding_state tailscale_forwarding_converge "${target}"
if [[ ${forwarding_state} == changed ]]; then
  log_info "enabled IPv4 forwarding in container ${ctid}"
fi

# The advertisement half, and what the helper is given depends on where
# the routes came from.
#
# Configured by the operator: bake the resolved list in. They are
# authoritative, and a helper that re-derived a subnet at every boot
# would be second-guessing a list somebody chose on purpose.
#
# Detected: bake nothing, and let the helper derive the subnet in the
# container at every boot. That is the whole point of the helper -- a LAN
# renumber or a DHCP change leaves the advertisement right without anyone
# running this toolkit again -- and freezing the value here would trade
# that away.
#
# So in the detected case the string handed to `tailscale up` below (what
# the host sees now) and the string the helper will work out (what the
# container sees at boot) are produced by two derivations. They agree on
# any node where the router shares the management LAN, which is the
# layout this stage builds. The difference is intentional: the container's
# answer is the live one, and the host's is only what gets the first
# advertisement up before the unit has ever run.
baked_routes=''
if [[ -n ${PVE_TAILSCALE_ROUTES:-} ]]; then
  baked_routes=${advertise_routes}
fi
script_state=unchanged
state_of script_state target_write_file "${target}" "${TAILSCALE_ADVERTISE_SCRIPT}" \
  "$(tailscale_advertise_script_body "${baked_routes}")" 0755

unit_state=unchanged
state_of unit_state target_write_file "${target}" "${TAILSCALE_UNIT_PATH}" \
  "$(tailscale_advertise_unit_body)" 0644

if [[ ${unit_state} == changed ]]; then
  target_systemd_daemon_reload "${target}" >/dev/null
fi

target_service_enable "${target}" "${TAILSCALE_ADVERTISE_UNIT}" >/dev/null

# The login. Tracing is already off and stays off until the last copy of
# the key is gone.
#
# A key file left behind by an interrupted earlier run goes first, before
# anything is asked about login state: a container that is already joined
# never reaches the branch that would have removed it, so a stale key
# would otherwise sit there at 0600 for the life of the container.
if ! tailscale_authkey_file_purge "${target}"; then
  tailscale_secret_die "Unable to remove a leftover ${TAILSCALE_AUTHKEY_PATH} from container ${ctid}. Delete that file and revoke the key it holds before running again." TAILSCALE_AUTHKEY
fi

# Every real container is asked what it is, including one this run has
# just built and one it has just reinstalled the package into. A
# container keeps /var/lib/tailscale across a package removal, so having
# installed something says nothing about whether this machine already
# holds an identity -- and inferring "not logged in" from "we installed
# tailscale" would spend a key on a machine that is already a member,
# which is the fail-open shape the probe exists to prevent.
#
# Inference is left for the dry run alone, and only where this run would
# have had to build or install the thing being asked: there is no daemon
# to ask, asking would stop the run on a tailscale that is not there, and
# a dry run spends nothing whatever it concludes.
login_known=0
needs_login=0
needs_up=0
if dry_run_enabled && [[ ${ct_state} == changed || ${pkg_state} == changed ]]; then
  login_known=1
  needs_login=1
fi

if ((login_known == 0)); then
  login_rc=0
  tailscale_login_state "${target}" || login_rc=$?
  case ${login_rc} in
    0) needs_login=0 ;;
    1) needs_login=1 ;;
    3) needs_up=1 ;;
    *) tailscale_secret_die "$(tailscale_login_state_unreadable "${target}")" TAILSCALE_AUTHKEY ;;
  esac
fi

login_state=unchanged
if ((needs_up)); then
  # An identity with the backend stopped. This stage exists to leave a
  # working subnet router behind, so "logged in but routing nothing" is
  # not a converged state to report success on -- and it is not a reason
  # to spend a key either, because the machine is already a member.
  # `tailscale up` with no key is what the Tailscale CLI offers for
  # exactly this.
  log_warn "The Tailscale daemon in container ${ctid} is logged in but stopped, so it is routing nothing. Bringing it back up; no auth key is needed or used for this."
  if dry_run_enabled; then
    log_info "would bring container ${ctid} back up, advertising ${advertise_routes}"
  else
    target_run "${target}" tailscale up \
      "--advertise-routes=${advertise_routes}" \
      --accept-routes \
      "--hostname=${hostname}" ||
      tailscale_secret_die "'tailscale up' failed in container ${ctid} while bringing an already-logged-in machine back up. Run it in the container and look at what it says; a new auth key will not help, because the machine still holds its identity." TAILSCALE_AUTHKEY
    log_info "brought container ${ctid} back up"
  fi
  login_state=changed
elif ((needs_login == 0)); then
  log_info "container ${ctid} is already joined to the tailnet"
elif dry_run_enabled; then
  # The key is wanted on this path, and a dry run is where that is
  # cheapest to find out.
  ((have_authkey)) ||
    tailscale_authkey_require 'join the subnet router to your tailnet'
  log_info "would join container ${ctid} to the tailnet, advertising ${advertise_routes}"
  login_state=changed
else
  tailscale_authkey_require 'join the subnet router to your tailnet'

  # The key crosses into the container as a 0600 file and `tailscale up`
  # is given the path, which is what --auth-key=file: is for: an argument
  # list is readable by every process on the machine, and the environment
  # of a child is readable by the child.
  #
  # The trap is armed before the file exists and disarmed only once its
  # removal has been confirmed, so a pct that cannot reach the container,
  # a signal, or a removal that does not take all end with the key gone
  # or with the run saying loudly that it is not.
  tailscale_authkey_file_arm "${target}"
  target_ensure_dir "${target}" "${TAILSCALE_AUTHKEY_DIR}" 0700 >/dev/null
  target_write_file "${target}" "${TAILSCALE_AUTHKEY_PATH}" \
    "${TAILSCALE_AUTHKEY}"$'\n' 0600 >/dev/null
  TAILSCALE_AUTHKEY=''

  up_status=0
  target_run "${target}" tailscale up \
    "--auth-key=file:${TAILSCALE_AUTHKEY_PATH}" \
    "--advertise-routes=${advertise_routes}" \
    --accept-routes \
    "--hostname=${hostname}" || up_status=$?

  if ! tailscale_authkey_file_purge "${target}"; then
    tailscale_secret_die "Unable to remove ${TAILSCALE_AUTHKEY_PATH} from container ${ctid} after logging in. Delete that file and revoke the key in the Tailscale admin console." TAILSCALE_AUTHKEY
  fi
  tailscale_authkey_file_disarm

  ((up_status == 0)) ||
    tailscale_secret_die "'tailscale up' failed in container ${ctid} with status ${up_status}. A key that has been used by an earlier run, or that has expired, is the usual cause; issue a fresh reusable key and run again." TAILSCALE_AUTHKEY
  login_state=changed
  log_info "joined container ${ctid} to the tailnet"
fi

TAILSCALE_AUTHKEY=''
tailscale_secret_end
# And the region the capture at the top of this file opened: with the last
# copy of the key gone, tracing can go back to whatever it was.
tailscale_secret_end

# Run after the login, because advertising routes is something only a
# logged in daemon can do. RemainAfterExit keeps the oneshot "active"
# once it has run, so a converged run finds nothing to start.
advertise_state=unchanged
state_of advertise_state target_service_start "${target}" "${TAILSCALE_ADVERTISE_UNIT}"
# RemainAfterExit leaves the unit active after it has run once, so
# starting it again is a no-op and the routes it advertised last time
# stay advertised. A changed helper or unit is a changed answer, and it
# only reaches the daemon when the unit is made to run again.
if [[ ${advertise_state} != changed &&
  (${script_state} == changed || ${unit_state} == changed) ]]; then
  target_service_restart "${target}" "${TAILSCALE_ADVERTISE_UNIT}" >/dev/null
  advertise_state=changed
fi
if [[ ${advertise_state} == changed ]]; then
  log_info "advertised ${advertise_routes} from container ${ctid}"
fi

# Key expiry is a property of the machine in the tailnet, and the
# `tailscale` CLI has no way to change it: it is set in the admin console,
# or through the Tailscale API, neither of which this toolkit holds
# credentials for. Saying so once a run, by name, is the honest version of
# "handled" -- the alternative is a tunnel that drops six months from now
# with nothing in any log to explain it.
if [[ ${login_state} == changed && ${needs_up} -eq 1 ]]; then
  # Not a fresh join: this node already held an identity and had stopped.
  # Saying "disable key expiry" in the first-join wording here would read
  # as though a key had just been spent, which none was.
  log_warn "Container ${ctid} was logged in but stopped, and has been brought back up. An expired key is one reason a node stops routing: check whether key expiry is disabled for ${hostname} in the Tailscale admin console, under Machines. Nothing on this node can renew a key."
elif [[ ${login_state} == changed ]]; then
  log_warn "Disable key expiry for ${hostname} in the Tailscale admin console, under Machines. A subnet router whose key expires stops routing, and nothing on this node can renew it."
fi

log_info "the Tailscale subnet router in container ${ctid} (${hostname}) advertises ${advertise_routes}"

# The administrators who manage this node manage the router too. Last,
# because it hardens the container's sshd and locks its root password, and
# neither belongs in front of the work that makes the container useful:
# a run that fails before the tunnel is up should not also have taken a
# way back in with it.
guest_admin_converge "${target}" >/dev/null
