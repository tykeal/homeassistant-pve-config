#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
# SPDX-License-Identifier: Apache-2.0

# Step 2 of 2: certificate and guests, run once after pve-baseline.sh and a
# reboot.
#
#   a. ACME certificate for the web UI (DNS Made Easy), when configured
#   b. Home Assistant OS VM         (community-scripts vm/haos-vm.sh)
#   c. Tailscale subnet router LXC  (community-scripts ct/debian.sh)
#   d. Frigate NVR LXC              (community-scripts ct/docker.sh and the
#                                    official Frigate image)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CS_DIR="/usr/local/community-scripts"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--config PATH]

Order the ACME certificate and build the Home Assistant OS VM, the
Tailscale subnet router container and the Frigate container.

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

# Frigate's share of the host: "<ram_mb> <cores>". A quarter of the RAM
# (2048-6144 MB) and half the cores (2-8).
frigate_size() {
  local host_mb="$1" host_cores="$2" ram cores
  ram=$((host_mb / 4))
  ((ram < 2048)) && ram=2048
  ((ram > 6144)) && ram=6144
  cores=$((host_cores / 2))
  ((cores < 2)) && cores=2
  ((cores > 8)) && cores=8
  echo "${ram} ${cores}"
}

# First storage on this node that accepts the given content type.
first_storage() {
  pvesm status -content "$1" | awk 'NR == 2 {print $1}'
}

# Runs a community-scripts builder with no controlling terminal and stdin
# from /dev/null. The engine's own prompts read /dev/tty (the GPU choice,
# the "remove failed container?" question); without a terminal they fail
# at once and take their defaults instead of waiting for a keyboard.
# TERM still has to name a real terminal type: the engine runs `clear`
# under `set -e`, and `clear` fails on an unset or "dumb" TERM.
run_builder() {
  local script="$1" term="${TERM:-dumb}" rc=0
  shift
  [[ "${term}" == dumb ]] && term=xterm-256color
  local file="${CS_DIR}/pve-config-${script//\//-}"
  curl -fsSL "${COMMUNITY_SCRIPTS_URL}/${script}" -o "${file}"
  env TERM="${term}" "$@" setsid bash "${file}" </dev/null || rc=$?
  rm -f "${file}"
  ((rc == 0)) || die "${script} failed (exit ${rc}); see its output above"
}

ct_ip() {
  pct exec "$1" -- ip -4 -o addr show dev eth0 2>/dev/null | awk '{split($4, a, "/"); print a[1]; exit}'
}

# Writes stdin to a file inside a container.
ct_write() {
  local ctid="$1" path="$2" mode="$3"
  # shellcheck disable=SC2016 # $1/$2 expand in the container's shell
  pct exec "${ctid}" -- sh -c 'cat >"$1" && chmod "$2" "$1"' sh "${path}" "${mode}"
}

setup_acme() {
  local fqdn directory creds
  fqdn="$(hostname -f)"
  directory="https://acme-v02.api.letsencrypt.org/directory"
  [[ "${ACME_STAGING:-0}" == 1 ]] && directory="https://acme-staging-v02.api.letsencrypt.org/directory"
  log "ACME: ordering a certificate for ${fqdn} from ${directory}"

  creds="/root/dnsmadeeasy.conf"
  (
    umask 077
    printf 'ME_Key=%s\nME_Secret=%s\n' "${DME_API_KEY}" "${DME_API_SECRET}" >"${creds}"
  )
  pvenode acme plugin add dns dnsmadeeasy --api me --data "${creds}"
  rm -f "${creds}"
  # register asks on stdin whether the CA's terms of service are accepted.
  echo y | pvenode acme account register default "${ACME_EMAIL}" --directory "${directory}"
  pvenode config set --acmedomain0 "${fqdn},plugin=dnsmadeeasy"
  pvenode acme cert order
}

setup_haos() {
  log "HAOS: building VM ${HAOS_VMID} (${HAOS_HOSTNAME})"
  # VM_UNATTENDED takes haos-vm.sh's defaults (current stable release,
  # 32G disk, q35, started on creation) with these overrides.
  run_builder vm/haos-vm.sh \
    VM_UNATTENDED=1 \
    VM_VMID="${HAOS_VMID}" \
    VM_HOSTNAME="${HAOS_HOSTNAME}" \
    VM_CPU=host \
    VM_CORES="${HAOS_CORES}" \
    VM_RAM="${HAOS_RAM_MB}" \
    VM_STORAGE="${GUEST_STORAGE}"
  qm config "${HAOS_VMID}" >/dev/null
}

setup_tailscale() {
  local ctid="${TS_CTID}"
  log "Tailscale: building container ${ctid} (${TS_HOSTNAME})"
  run_builder ct/debian.sh \
    mode=default \
    var_ctid="${ctid}" \
    var_hostname="${TS_HOSTNAME}" \
    var_unprivileged=1 \
    var_nesting=1 \
    var_tun=yes \
    var_cpu="${TS_CORES}" \
    var_ram="${TS_RAM_MB}" \
    var_disk="${TS_DISK_GB}" \
    var_net=dhcp \
    var_ipv6_method=none
  grep -q '/dev/net/tun' "/etc/pve/lxc/${ctid}.conf" || die "container ${ctid} has no /dev/net/tun"

  log "Tailscale: installing packages in container ${ctid}"
  pct exec "${ctid}" -- apt-get update -qq
  pct exec "${ctid}" -- env DEBIAN_FRONTEND=noninteractive \
    apt-get install -y -qq curl sudo openssh-server libpam-ssh-agent-auth
  pct exec "${ctid}" -- sh -c 'curl -fsSL https://tailscale.com/install.sh | sh'

  echo 'net.ipv4.ip_forward = 1' | ct_write "${ctid}" /etc/sysctl.d/99-tailscale.conf 0644
  pct exec "${ctid}" -- sysctl -p /etc/sysctl.d/99-tailscale.conf

  log "Tailscale: joining the tailnet as ${TS_HOSTNAME}"
  printf '%s\n' "${TS_AUTHKEY}" | ct_write "${ctid}" /root/ts-authkey 0600
  pct exec "${ctid}" -- tailscale up --auth-key=file:/root/ts-authkey \
    --hostname="${TS_HOSTNAME}" --accept-routes
  pct exec "${ctid}" -- rm -f /root/ts-authkey

  # Routes are re-derived from eth0 on every boot; run it once now too.
  pct push "${ctid}" "${SCRIPT_DIR}/files/ts-advertise-routes.sh" \
    /usr/local/sbin/ts-advertise-routes.sh --perms 0755
  pct push "${ctid}" "${SCRIPT_DIR}/files/ts-advertise-routes.service" \
    /etc/systemd/system/ts-advertise-routes.service --perms 0644
  pct exec "${ctid}" -- systemctl daemon-reload
  pct exec "${ctid}" -- systemctl enable ts-advertise-routes.service
  pct exec "${ctid}" -- /usr/local/sbin/ts-advertise-routes.sh

  log "Tailscale: admin user ${ADMIN_USER} with SSH-agent sudo"
  pct exec "${ctid}" -- useradd -m -s /bin/bash -G sudo "${ADMIN_USER}"
  pct exec "${ctid}" -- install -d -m 0700 -o "${ADMIN_USER}" -g "${ADMIN_USER}" "/home/${ADMIN_USER}/.ssh"
  printf '%s\n' "${ADMIN_PUBKEYS}" | ct_write "${ctid}" "/home/${ADMIN_USER}/.ssh/authorized_keys" 0600
  pct exec "${ctid}" -- chown "${ADMIN_USER}:${ADMIN_USER}" "/home/${ADMIN_USER}/.ssh/authorized_keys"

  printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n' |
    ct_write "${ctid}" /etc/ssh/sshd_config.d/99-hardening.conf 0644

  printf '%s\n' "${ADMIN_PUBKEYS}" | ct_write "${ctid}" /etc/security/authorized_keys 0600
  pct exec "${ctid}" -- sed -i '1a auth sufficient pam_ssh_agent_auth.so file=/etc/security/authorized_keys' /etc/pam.d/sudo
  pct exec "${ctid}" -- sh -c 'rm -f /etc/pam.d/sudo-i && ln -s /etc/pam.d/sudo /etc/pam.d/sudo-i'
  echo 'Defaults env_keep += "SSH_AUTH_SOCK"' | ct_write "${ctid}" /etc/sudoers.d/90-ssh-agent 0440
  pct exec "${ctid}" -- visudo -cq

  # TERM fix for `pct enter` sessions.
  pct exec "${ctid}" -- sh -c "echo 'export TERM=xterm-256color' >>/etc/bash.bashrc"
  pct exec "${ctid}" -- sshd -t
  pct exec "${ctid}" -- systemctl restart ssh
}

setup_frigate() {
  local ctid="${FRIGATE_CTID}" gpu="${FRIGATE_GPU}" host_mb size
  host_mb="$(awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo)"
  size="$(frigate_size "${host_mb}" "$(nproc)")"
  : "${FRIGATE_RAM_MB:=${size% *}}"
  : "${FRIGATE_CORES:=${size#* }}"
  if [[ "${gpu}" == auto ]]; then
    gpu=no
    [[ -d /dev/dri ]] && gpu=yes
  fi
  log "Frigate: building privileged Docker container ${ctid} (${FRIGATE_CORES} cores, ${FRIGATE_RAM_MB} MB, GPU ${gpu})"
  # var_gpu=yes makes the engine add a devN: entry for every Intel/AMD
  # /dev/dri node it finds. var_docker_socket=n answers the install's
  # "expose the Docker TCP socket?" question.
  run_builder ct/docker.sh \
    mode=default \
    var_os=debian \
    var_ctid="${ctid}" \
    var_hostname="${FRIGATE_HOSTNAME}" \
    var_unprivileged=0 \
    var_nesting=1 \
    var_gpu="${gpu}" \
    var_docker_socket=n \
    var_cpu="${FRIGATE_CORES}" \
    var_ram="${FRIGATE_RAM_MB}" \
    var_disk="${FRIGATE_DISK_GB}" \
    var_net=dhcp \
    var_ipv6_method=none
  pct config "${ctid}" >/dev/null

  pct exec "${ctid}" -- mkdir -p /opt/frigate/config /opt/frigate/storage
  local devices=""
  if [[ "${gpu}" == yes ]]; then
    if pct exec "${ctid}" -- test -c /dev/dri/renderD128; then
      devices=$'    devices:\n      - /dev/dri/renderD128:/dev/dri/renderD128\n'
      # Mirrors Frigate 0.18's own starter config, with GPU in place of CPU.
      ct_write "${ctid}" /opt/frigate/config/config.yml 0644 <<'EOF'
mqtt:
  enabled: False

ffmpeg:
  hwaccel_args: preset-vaapi

detectors:
  ov:
    type: openvino
    device: GPU

model:
  width: 300
  height: 300
  input_tensor: nhwc
  input_pixel_format: bgr
  path: /openvino-model/ssdlite_mobilenet_v2.xml
  labelmap_path: /openvino-model/coco_91cl_bkgr.txt

cameras: {}  # No cameras defined, UI wizard should be used
version: 0.18-0
EOF
    else
      echo "WARNING: no /dev/dri/renderD128 in container ${ctid}; Frigate runs without a GPU" >&2
    fi
  fi

  log "Frigate: starting ghcr.io/blakeblackshear/frigate:${FRIGATE_IMAGE_TAG}; the first pull takes a while"
  ct_write "${ctid}" /opt/frigate/docker-compose.yml 0644 <<EOF
services:
  frigate:
    container_name: frigate
    image: ghcr.io/blakeblackshear/frigate:${FRIGATE_IMAGE_TAG}
    restart: unless-stopped
    stop_grace_period: 30s
    shm_size: "${FRIGATE_SHM_SIZE}"
${devices}    volumes:
      - /etc/localtime:/etc/localtime:ro
      - /opt/frigate/config:/config
      - /opt/frigate/storage:/media/frigate
      - type: tmpfs
        target: /tmp/cache
        tmpfs:
          size: 1000000000
    ports:
      - "8971:8971"
      - "8554:8554"
      - "8555:8555/tcp"
      - "8555:8555/udp"
EOF
  pct exec "${ctid}" -- docker compose -f /opt/frigate/docker-compose.yml up -d --quiet-pull
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
  load_config "${config}" ADMIN_USER ADMIN_PUBKEYS TS_AUTHKEY \
    COMMUNITY_SCRIPTS_REF COMMUNITY_SCRIPTS_CORE_REF
  if [[ -n "${DME_API_KEY:-}" ]]; then
    load_config "${config}" ACME_EMAIL DME_API_KEY DME_API_SECRET
  fi
  [[ -f /etc/zulip-notify.env ]] || die "pve-baseline.sh has not run on this host"

  : "${HAOS_VMID:=200}" "${HAOS_HOSTNAME:=homeassistant}" "${HAOS_CORES:=2}" "${HAOS_RAM_MB:=4096}"
  : "${TS_CTID:=100}" "${TS_HOSTNAME:=ts-$(hostname -s)}" "${TS_CORES:=1}" "${TS_RAM_MB:=512}" "${TS_DISK_GB:=2}"
  : "${FRIGATE_CTID:=101}" "${FRIGATE_HOSTNAME:=frigate}" "${FRIGATE_DISK_GB:=25}" "${FRIGATE_GPU:=auto}"
  : "${FRIGATE_IMAGE_TAG:=stable}" "${FRIGATE_SHM_SIZE:=512mb}"
  : "${GUEST_STORAGE:=$(first_storage rootdir)}" "${TEMPLATE_STORAGE:=$(first_storage vztmpl)}"
  [[ -n "${GUEST_STORAGE}" ]] || die "no storage for guest disks found; set GUEST_STORAGE"
  [[ -n "${TEMPLATE_STORAGE}" ]] || die "no storage for container templates found; set TEMPLATE_STORAGE"

  export COMMUNITY_SCRIPTS_URL="https://raw.githubusercontent.com/community-scripts/ProxmoxVE/${COMMUNITY_SCRIPTS_REF}"
  export COMMUNITY_SCRIPTS_CORE_URL="https://raw.githubusercontent.com/community-scripts/core/${COMMUNITY_SCRIPTS_CORE_REF}"

  # The community-scripts engine reads its storage answers and telemetry
  # opt-in from these files; without them it would stop on a menu.
  mkdir -p "${CS_DIR}"
  printf 'var_template_storage=%s\nvar_container_storage=%s\n' \
    "${TEMPLATE_STORAGE}" "${GUEST_STORAGE}" >"${CS_DIR}/default.vars"
  [[ -f "${CS_DIR}/diagnostics" ]] || echo 'DIAGNOSTICS=no' >"${CS_DIR}/diagnostics"

  local acme="skipped (DME_API_KEY is blank)"
  if [[ -n "${DME_API_KEY:-}" ]]; then
    setup_acme
    acme="ordered for $(hostname -f)"
    [[ "${ACME_STAGING:-0}" == 1 ]] && acme+=" (Let's Encrypt STAGING)"
  else
    log "ACME: ${acme}"
  fi
  setup_haos
  setup_tailscale
  setup_frigate

  local haos_ip ts_routes
  ts_routes="$(pct exec "${TS_CTID}" -- ip -4 route show dev eth0 proto kernel scope link | awk '{print $1}' | paste -sd, -)"
  haos_ip="$(qm guest cmd "${HAOS_VMID}" network-get-interfaces 2>/dev/null |
    grep -oE '"ip-address" *: *"[0-9.]+"' | grep -v '127\.0\.0\.1' | head -1 | grep -oE '[0-9.]+' || true)"

  cat <<EOF

=== Summary ===
Certificate:    ${acme}
HAOS VM:        ${HAOS_VMID} (${HAOS_HOSTNAME}) ${haos_ip:-IP not reported yet; run: qm guest cmd ${HAOS_VMID} network-get-interfaces}
Tailscale CT:   ${TS_CTID} (${TS_HOSTNAME}) $(ct_ip "${TS_CTID}")
                tailnet IP $(pct exec "${TS_CTID}" -- tailscale ip -4 2>/dev/null || echo '?')
                advertising ${ts_routes} (re-derived on every boot)
Frigate CT:     ${FRIGATE_CTID} (${FRIGATE_HOSTNAME}) https://$(ct_ip "${FRIGATE_CTID}"):8971
                admin password, once Frigate has started:
                pct exec ${FRIGATE_CTID} -- docker logs frigate 2>&1 | grep -i password

Still to do, remotely over Tailscale:
  - approve the advertised subnet route in the Tailscale admin console
    (unless an autoApprovers rule covers it) and disable key expiry for
    ${TS_HOSTNAME} if the auth key was not tagged
  - Home Assistant onboarding or backup restore at http://<haos-ip>:8123
  - Frigate cameras and storage at https://<frigate-ip>:8971 (self-signed
    certificate; log in as admin and change the generated password)
EOF
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
