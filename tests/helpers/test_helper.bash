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
  PATH="${REPO_ROOT}/tests/helpers/mocks:${PATH}"
  export PATH
}

mock_calls() {
  cat "${PVE_CONFIG_MOCK_LOG}" 2>/dev/null || true
}

# Sources the libraries into the current test shell.
load_libs() {
  local lib
  for lib in common config detect state schema; do
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
