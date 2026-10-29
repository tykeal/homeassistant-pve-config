# SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
# SPDX-License-Identifier: Apache-2.0

# Shared test setup. Only the bats binary is available in CI, so everything
# here is plain bash; no bats-support, bats-assert or bats-file.

REPO_ROOT=$(cd -- "${BATS_TEST_DIRNAME}/.." && pwd)
export REPO_ROOT

# Puts the recording mocks ahead of anything real on PATH and points them at
# a per-test log, so a stage test can assert on the exact pct/qm calls made.
use_mocks() {
  export PVE_CONFIG_MOCK_LOG="${BATS_TEST_TMPDIR}/mock-calls.log"
  : >"${PVE_CONFIG_MOCK_LOG}"
  # What a mocked host command inherited. It lives beside the call log,
  # outside the state directory the convergence fingerprint covers, so a
  # test can assert on an environment without that assertion becoming
  # state.
  export PVE_CONFIG_MOCK_ENV_LOG="${BATS_TEST_TMPDIR}/mock-env.log"
  : >"${PVE_CONFIG_MOCK_ENV_LOG}"
  # The stateful mocks keep their fixtures here, which is what lets a stage
  # be run twice and converge on the second pass.
  export PVE_CONFIG_MOCK_STATE="${BATS_TEST_TMPDIR}/mock-state"
  mkdir -p "${PVE_CONFIG_MOCK_STATE}"
  # The guest target stages content through mktemp on its way to pct push.
  # Keeping that inside the test's own directory means a failed case leaves
  # its evidence with the rest, and leaves nothing behind in /tmp.
  export TMPDIR="${BATS_TEST_TMPDIR}"
  PATH="${REPO_ROOT}/tests/helpers/mocks:${PATH}"
  export PATH
}

mock_calls() {
  cat "${PVE_CONFIG_MOCK_LOG}" 2>/dev/null || true
}

# Makes one path look as though another user owns it, for the length of the
# test. The stand-in `stat` is kept out of the shared mock directory, so a
# test that does not ask for this sees the real one.
use_foreign_owner() {
  export PVE_CONFIG_MOCK_FOREIGN_PATH=$1
  PATH="${REPO_ROOT}/tests/helpers/mocks-foreign:${PATH}"
  export PATH
}

# The environment every mocked host command was started with.
mock_env() {
  cat "${PVE_CONFIG_MOCK_ENV_LOG}" 2>/dev/null || true
}

# Sources the libraries into the current test shell.
load_libs() {
  local lib
  for lib in common version config detect state schema pkg users service pve target acme; do
    # shellcheck disable=SC1090
    source "${REPO_ROOT}/lib/${lib}.sh"
  done
}

# Isolates every path the toolkit touches inside the test's own directory.
isolate_env() {
  export PVE_CONFIG_DIR="${BATS_TEST_TMPDIR}/install"
  export PVE_CONFIG_STATE_DIR="${PVE_CONFIG_DIR}/state"
  export PVE_CONFIG_STAGES_DIR="${PVE_CONFIG_DIR}/stages"
  export PVE_CONFIG_LIB_DIR="${REPO_ROOT}/lib"
  mkdir -p "${PVE_CONFIG_DIR}"
  export PVE_CONFIG_BOOT_ID_PATH="${BATS_TEST_TMPDIR}/boot_id"
  printf 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\n' >"${PVE_CONFIG_BOOT_ID_PATH}"
  export PVE_CONFIG_DRY_RUN=0 NON_INTERACTIVE=0 ASSUME_YES=0 FORCE=0 RECONFIGURE=0
  seed_nics nic0 nic1
  seed_default_route nic0
}

# A canned routing table. Uplink detection reads this instead of asking the
# kernel, so the bridge port a test derives does not depend on how the
# runner happens to be connected.
seed_default_route() {
  export PVE_CONFIG_DEFAULT_ROUTES="${BATS_TEST_TMPDIR}/default-routes"
  : >"${PVE_CONFIG_DEFAULT_ROUTES}"
  local dev
  for dev in "$@"; do
    printf 'default via 192.0.2.1 dev %s proto dhcp metric 100\n' "${dev}" \
      >>"${PVE_CONFIG_DEFAULT_ROUTES}"
  done
}

# A sysfs fixture standing in for /sys/class/net, so NIC detection answers
# from the test rather than from whatever the runner happens to be cabled
# with. Each name gets the `device` link detection uses to tell a real port
# from a virtual one.
seed_nics() {
  export PVE_CONFIG_SYSNET="${BATS_TEST_TMPDIR}/sysnet"
  rm -rf -- "${PVE_CONFIG_SYSNET}"
  local name
  for name in "$@"; do
    mkdir -p "${PVE_CONFIG_SYSNET}/${name}"
    : >"${PVE_CONFIG_SYSNET}/${name}/device"
  done
}

# Puts the bridge in the fixture holding the given ports, which is what an
# already-configured host looks like to detection on a re-run.
seed_bridge() {
  local bridge=$1
  shift
  mkdir -p "${PVE_CONFIG_SYSNET}/${bridge}/brif"
  : >"${PVE_CONFIG_SYSNET}/${bridge}/bridge"
  local port
  for port in "$@"; do
    mkdir -p "${PVE_CONFIG_SYSNET}/${bridge}/brif/${port}"
  done
}

# Writes a stage that records the fact it ran, so ordering and child-process
# execution can be observed from the test.
make_stage() {
  local phase=$1 file=$2 exit_code=${3:-0}
  mkdir -p "${PVE_CONFIG_STAGES_DIR}/phase${phase}"
  local path="${PVE_CONFIG_STAGES_DIR}/phase${phase}/${file}"
  cat >"${path}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${file}" >>"${BATS_TEST_TMPDIR}/stage-order.log"
printf '%s %s\n' "${file}" "\${PVE_CONFIG_DRY_RUN:-unset}" \
  >>"${BATS_TEST_TMPDIR}/stage-env.log"
exit ${exit_code}
EOF
  chmod +x "${path}"
  printf '%s\n' "${path}"
}

# Supplies every schema answer from the environment so the driver preflight
# has nothing to ask about.
schema_answers() {
  export PVE_HOSTNAME=testhost
  export PVE_DOMAIN=example.test
  export PVE_FQDN=testhost.example.test
  export PVE_ADMIN_USERS=admin
  export PVE_ADMIN_KEY_SOURCE='ssh-ed25519 AAAAtest admin@example.test'
  export PVE_SUITE=trixie
  export NON_INTERACTIVE=1
}

# Replaces the recorded boot id with a different one, which is what a real
# reboot looks like to the driver.
simulate_reboot() {
  printf '11111111-2222-3333-4444-555555555555\n' >"${PVE_CONFIG_BOOT_ID_PATH}"
}

stage_ran() {
  grep -qx -- "$1" "${BATS_TEST_TMPDIR}/stage-order.log" 2>/dev/null
}

stage_order() {
  cat "${BATS_TEST_TMPDIR}/stage-order.log" 2>/dev/null || true
}

# A scratch filesystem the stages write into instead of the host, plus the
# account fixtures lib/users.sh converges. The ids are the runner's own, so
# the ownership checks pass without the suite needing to be root.
isolate_system() {
  export PVE_CONFIG_ROOT="${BATS_TEST_TMPDIR}/sysroot"
  export PVE_CONFIG_PASSWD="${PVE_CONFIG_ROOT}/etc/passwd"
  export PVE_CONFIG_GROUP="${PVE_CONFIG_ROOT}/etc/group"
  export PVE_CONFIG_MOCK_HOME_BASE="/home"
  mkdir -p "${PVE_CONFIG_ROOT}/etc" "${PVE_CONFIG_ROOT}/home"
  printf 'root:x:0:0::/root:/bin/bash\n' >"${PVE_CONFIG_PASSWD}"
  printf 'root:x:0:\nsudo:x:27:\n' >"${PVE_CONFIG_GROUP}"
}

# Adds an account to the passwd fixture as if it had always been there.
seed_user() {
  local name=$1 shell=${2:-/bin/bash}
  printf '%s:x:%s:%s::/home/%s:%s\n' \
    "${name}" "$(id -u)" "$(id -g)" "${name}" "${shell}" >>"${PVE_CONFIG_PASSWD}"
}

# Runs one of the real stages as the driver would: a child process with
# nothing but the exported environment.
run_stage_file() {
  local phase=$1 file=$2
  bash "${REPO_ROOT}/stages/phase${phase}/${file}"
}

run_phase1_stage() {
  run_stage_file 1 "$1"
}

run_phase2_stage() {
  run_stage_file 2 "$1"
}

sysroot_file() {
  printf '%s\n' "${PVE_CONFIG_ROOT}$1"
}

# --- the simulated container ----------------------------------------------

# Where the pct mock keeps the container's filesystem. A test reads and
# seeds the guest through these rather than through pct, so an assertion
# about what ended up in the container does not depend on the same code
# path that put it there.
guest_root() {
  local root="${PVE_CONFIG_MOCK_STATE}/guests/$1/rootfs"
  if [[ ! -d ${root}/etc ]]; then
    mkdir -p -- "${root}/etc" "${root}/home" \
      "${root}/sys/class/net/lo" "${root}/sys/class/net/tailscale0"
    printf 'root:x:0:0::/root:/bin/bash\n' >"${root}/etc/passwd"
    printf 'root:x:0:\nsudo:x:27:\n' >"${root}/etc/group"
    # A container knows which Debian it is, and the toolkit reads that
    # rather than assuming the node's release.
    printf '%s\n' 'PRETTY_NAME="Debian GNU/Linux 13 (trixie)"' \
      'NAME="Debian GNU/Linux"' 'ID=debian' 'VERSION_ID="13"' \
      'VERSION_CODENAME=trixie' >"${root}/etc/os-release"
  fi
  printf '%s\n' "${root}"
}

guest_file() {
  printf '%s\n' "$(guest_root "$1")$2"
}

# Puts a file in the container as if it had always been there.
seed_guest_file() {
  local vmid=$1 path=$2 content=$3 mode=${4:-0644} dest
  dest=$(guest_file "${vmid}" "${path}")
  mkdir -p -- "$(dirname -- "${dest}")"
  printf '%s' "${content}" >"${dest}"
  chmod -- "${mode}" "${dest}"
}

# Adds an account to the container's passwd fixture. The ids are the
# runner's own, matching seed_user, so ownership checks pass unprivileged.
seed_guest_user() {
  local vmid=$1 name=$2 shell=${3:-/bin/bash}
  printf '%s:x:%s:%s::/home/%s:%s\n' \
    "${name}" "$(id -u)" "$(id -g)" "${name}" "${shell}" \
    >>"$(guest_file "${vmid}" /etc/passwd)"
}
