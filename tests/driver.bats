#!/usr/bin/env bats
# SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
# SPDX-License-Identifier: Apache-2.0

load helpers/test_helper

setup() {
  isolate_env
  schema_answers
  DRIVER="${REPO_ROOT}/pve-config.sh"
  ORDER_LOG="${BATS_TEST_TMPDIR}/stage-order.log"
  ENV_LOG="${BATS_TEST_TMPDIR}/stage-env.log"
}

# Sources the driver so its functions can be exercised directly. The driver
# guards its entry point, so this runs no stages. The privilege check is
# replaced because the suite runs as an ordinary user.
source_driver() {
  # The driver lives one level up and is chosen at runtime, so shellcheck
  # cannot resolve it from here; it is linted in its own right.
  # shellcheck source=/dev/null
  source "${DRIVER}"
  require_root() { return 0; }
}

@test "--help works for an unprivileged user and documents the flags" {
  run "${DRIVER}" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *'--list'* ]]
  [[ "$output" == *'--phase N'* ]]
  [[ "$output" == *'--stage NAME'* ]]
  [[ "$output" == *'--force'* ]]
  [[ "$output" == *'--reconfigure'* ]]
  [[ "$output" == *'--dry-run'* ]]
  [[ "$output" == *'--config PATH'* ]]
  [[ "$output" == *'--non-interactive'* ]]
}

@test "--list says so plainly when no stages are installed" {
  run "${DRIVER}" --list
  [ "$status" -eq 0 ]
  [[ "$output" == *'No stages installed'* ]]
}

@test "--list reports phase and status for each stage" {
  make_stage 1 '10-host.sh' >/dev/null
  make_stage 2 '20-guests.sh' >/dev/null
  mkdir -p "${PVE_CONFIG_STATE_DIR}"
  printf 'completed now\n' >"${PVE_CONFIG_STATE_DIR}/phase1__10-host.done"

  run "${DRIVER}" --list
  [ "$status" -eq 0 ]
  [[ "$output" == *'PHASE'* ]]
  [[ "${lines[1]}" == '1'*'10-host'*'done'* ]]
  [[ "${lines[2]}" == '2'*'20-guests'*'pending'* ]]
}

@test "an unknown flag is rejected" {
  run "${DRIVER}" --nonsense
  [ "$status" -ne 0 ]
  [[ "$output" == *'Unknown option'* ]]
}

@test "--phase insists on a number" {
  make_stage 1 '10-host.sh' >/dev/null
  run "${DRIVER}" --dry-run --phase one
  [ "$status" -ne 0 ]
  [[ "$output" == *'--phase expects a number'* ]]
}

@test "stage discovery orders by phase then numeric prefix" {
  make_stage 2 '10-acme.sh' >/dev/null
  make_stage 1 '20-network.sh' >/dev/null
  make_stage 1 '05-hostname.sh' >/dev/null
  make_stage 10 '10-late.sh' >/dev/null

  source_driver
  run stage_paths
  [ "${#lines[@]}" -eq 4 ]
  [[ "${lines[0]}" == *'phase1/05-hostname.sh' ]]
  [[ "${lines[1]}" == *'phase1/20-network.sh' ]]
  [[ "${lines[2]}" == *'phase2/10-acme.sh' ]]
  [[ "${lines[3]}" == *'phase10/10-late.sh' ]]
}

@test "stage discovery ignores files that do not match the convention" {
  mkdir -p "${PVE_CONFIG_STAGES_DIR}/phase1"
  touch "${PVE_CONFIG_STAGES_DIR}/phase1/README.md"
  touch "${PVE_CONFIG_STAGES_DIR}/phase1/helper.sh"
  make_stage 1 '10-real.sh' >/dev/null

  source_driver
  run stage_paths
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == *'10-real.sh' ]]
}

@test "stage discovery is empty and quiet with no stages directory" {
  source_driver
  run stage_paths
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a phase directory without a number is rejected" {
  mkdir -p "${PVE_CONFIG_STAGES_DIR}/phasefoo"
  printf '#!/usr/bin/env bash\n' >"${PVE_CONFIG_STAGES_DIR}/phasefoo/10-x.sh"

  run "${DRIVER}" --list
  [ "$status" -ne 0 ]
  [[ "$output" == *'phasefoo'* ]]
}

@test "two stages sharing an ordering prefix are rejected" {
  make_stage 1 '10-host.sh' >/dev/null
  make_stage 1 '10-other.sh' >/dev/null

  run "${DRIVER}" --list
  [ "$status" -ne 0 ]
  [[ "$output" == *'Duplicate ordering prefix'* ]]
}

@test "the same prefix in two different phases is fine" {
  make_stage 1 '10-host.sh' >/dev/null
  make_stage 2 '10-acme.sh' >/dev/null

  run "${DRIVER}" --list
  [ "$status" -eq 0 ]
}

@test "the same stage name in two phases does not share a marker" {
  make_stage 1 '10-shared.sh' >/dev/null
  make_stage 2 '10-shared.sh' >/dev/null

  source_driver
  run_stage "${PVE_CONFIG_STAGES_DIR}/phase1/10-shared.sh"
  [ -f "${PVE_CONFIG_STATE_DIR}/phase1__10-shared.done" ]
  [ ! -e "${PVE_CONFIG_STATE_DIR}/phase2__10-shared.done" ]

  run phase_is_complete 2
  [ "$status" -ne 0 ]
}

@test "--stage rejects a name that exists in more than one phase" {
  make_stage 1 '10-shared.sh' >/dev/null
  make_stage 2 '10-shared.sh' >/dev/null

  run "${DRIVER}" --dry-run --stage 10-shared
  [ "$status" -ne 0 ]
  [[ "$output" == *'ambiguous'* ]]
  [[ "$output" == *'phase1__10-shared'* ]]
  [[ "$output" == *'phase2__10-shared'* ]]
}

@test "--stage accepts a phase qualified name" {
  make_stage 1 '10-shared.sh' >/dev/null
  make_stage 2 '10-shared.sh' >/dev/null

  run "${DRIVER}" --dry-run --stage phase1__10-shared
  [ "$status" -eq 0 ]
  [[ "$output" == *'phase1__10-shared'* ]]
  [[ "$output" != *'phase2__10-shared'* ]]
}

@test "--stage accepts the name with or without .sh" {
  make_stage 1 '10-host.sh' >/dev/null
  make_stage 1 '20-network.sh' >/dev/null

  run "${DRIVER}" --dry-run --stage 10-host
  [ "$status" -eq 0 ]
  [[ "$output" == *'phase1__10-host'* ]]
  [[ "$output" != *'20-network'* ]]

  run "${DRIVER}" --dry-run --stage 20-network.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *'phase1__20-network'* ]]
}

@test "an unknown stage name is an error" {
  make_stage 1 '10-host.sh' >/dev/null
  run "${DRIVER}" --dry-run --stage 99-nope
  [ "$status" -ne 0 ]
  [[ "$output" == *'No such stage'* ]]
}

@test "a marker left behind by a deleted stage does not block the phase" {
  make_stage 1 '10-host.sh' >/dev/null
  source_driver
  state_mark_done "$(state_id 1 10-host)"
  state_mark_done "$(state_id 1 99-removed)"

  run phase_is_complete 1
  [ "$status" -eq 0 ]
  run next_phase
  [ "$status" -ne 0 ]
  run cmd_list
  [[ "$output" != *'99-removed'* ]]
}

@test "a successful stage runs as a child and gets a marker" {
  local path
  path=$(make_stage 1 '10-host.sh')

  source_driver
  run run_stage "${path}"
  [ "$status" -eq 0 ]
  [ -f "${PVE_CONFIG_STATE_DIR}/phase1__10-host.done" ]
  [ "$(cat "${ORDER_LOG}")" = '10-host.sh' ]
}

@test "a failing stage leaves no marker and is named in the error" {
  local path
  path=$(make_stage 1 '10-host.sh' 3)

  source_driver
  run run_stage "${path}"
  [ "$status" -ne 0 ]
  [ ! -e "${PVE_CONFIG_STATE_DIR}/phase1__10-host.done" ]
  [[ "$output" == *'phase1__10-host failed'* ]]
}

@test "a completed stage is skipped unless forced" {
  local path
  path=$(make_stage 1 '10-host.sh')

  source_driver
  run_stage "${path}"
  rm -f "${ORDER_LOG}"

  run run_stage "${path}"
  [ "$status" -eq 0 ]
  [ ! -e "${ORDER_LOG}" ]

  export FORCE=1
  run run_stage "${path}"
  [ "$status" -eq 0 ]
  [ "$(cat "${ORDER_LOG}")" = '10-host.sh' ]
}

@test "run_stages stops at the first failure" {
  local first second third
  first=$(make_stage 1 '10-one.sh')
  second=$(make_stage 1 '20-two.sh' 1)
  third=$(make_stage 1 '30-three.sh')

  source_driver
  run run_stages "${first}" "${second}" "${third}"
  [ "$status" -ne 0 ]
  run cat "${ORDER_LOG}"
  [ "${#lines[@]}" -eq 2 ]
  [ ! -e "${PVE_CONFIG_STATE_DIR}/phase1__30-three.done" ]
}

@test "the default run picks the lowest incomplete phase" {
  make_stage 1 '10-host.sh' >/dev/null
  make_stage 2 '10-acme.sh' >/dev/null

  source_driver
  run next_phase
  [ "$output" = '1' ]

  state_mark_done "$(state_id 1 10-host)"
  run next_phase
  [ "$output" = '2' ]

  state_mark_done "$(state_id 2 10-acme)"
  run next_phase
  [ "$status" -ne 0 ]
}

@test "phase_is_complete tracks every stage in the phase" {
  make_stage 1 '10-host.sh' >/dev/null
  make_stage 1 '20-network.sh' >/dev/null

  source_driver
  run phase_is_complete 1
  [ "$status" -ne 0 ]

  state_mark_done "$(state_id 1 10-host)"
  state_mark_done "$(state_id 1 20-network)"
  run phase_is_complete 1
  [ "$status" -eq 0 ]
}

@test "a dry run executes the stage, tells it so, and writes no marker" {
  make_stage 1 '10-host.sh' >/dev/null

  run "${DRIVER}" --dry-run
  [ "$status" -eq 0 ]
  [ "$(cat "${ORDER_LOG}")" = '10-host.sh' ]
  [ "$(cat "${ENV_LOG}")" = '10-host.sh 1' ]
  [ ! -e "${PVE_CONFIG_STATE_DIR}/phase1__10-host.done" ]
}

@test "a real run tells the stage that it is not a dry run" {
  make_stage 1 '10-host.sh' >/dev/null

  source_driver
  run main
  [ "$status" -eq 0 ]
  [ "$(cat "${ENV_LOG}")" = '10-host.sh 0' ]
  [ -f "${PVE_CONFIG_STATE_DIR}/phase1__10-host.done" ]
}

@test "a dry run writes no configuration file" {
  make_stage 1 '10-host.sh' >/dev/null

  run "${DRIVER}" --dry-run
  [ "$status" -eq 0 ]
  [ ! -e "${PVE_CONFIG_DIR}/pve-config.conf" ]
}

@test "--dry-run with --phase selects only that phase" {
  make_stage 1 '10-host.sh' >/dev/null
  make_stage 2 '20-acme.sh' >/dev/null

  run "${DRIVER}" --dry-run --phase 2
  [ "$status" -eq 0 ]
  [ "$(cat "${ORDER_LOG}")" = '20-acme.sh' ]
}

@test "a dry run with nothing installed reports that there is nothing to do" {
  run "${DRIVER}" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *'nothing to do'* ]]
}

@test "a dry run reads an alternate config given with --config" {
  make_stage 1 '10-host.sh' >/dev/null
  printf "PVE_DOMAIN='alternate.example'\n" >"${BATS_TEST_TMPDIR}/other.conf"
  unset PVE_DOMAIN

  run "${DRIVER}" --dry-run --config "${BATS_TEST_TMPDIR}/other.conf"
  [ "$status" -eq 0 ]
}

@test "a phase 2 only stage set runs without a phase 1 reboot" {
  make_stage 2 '10-acme.sh' >/dev/null

  source_driver
  run main
  [ "$status" -eq 0 ]
  [ -f "${PVE_CONFIG_STATE_DIR}/phase2__10-acme.done" ]
  [[ "$output" != *'Reboot the host'* ]]
}

@test "the reboot notice appears exactly once, when phase 1 completes" {
  make_stage 1 '10-host.sh' >/dev/null
  make_stage 1 '20-network.sh' >/dev/null

  source_driver

  run main --stage 10-host
  [ "$status" -eq 0 ]
  [[ "$output" != *'Reboot the host'* ]]

  run main --stage 20-network
  [ "$status" -eq 0 ]
  [[ "$output" == *'Phase 1 is complete'* ]]
  [ -f "${PVE_CONFIG_STATE_DIR}/phase1.bootid" ]

  run main --stage 20-network --force
  [ "$status" -eq 0 ]
  [[ "$output" != *'Phase 1 is complete'* ]]
}

@test "a dry run never prints the reboot notice" {
  make_stage 1 '10-host.sh' >/dev/null

  source_driver
  run main --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" != *'Phase 1 is complete'* ]]
  [ ! -e "${PVE_CONFIG_STATE_DIR}/phase1.bootid" ]
}

@test "phase 2 waits for the reboot phase 1 asked for" {
  make_stage 1 '10-host.sh' >/dev/null
  make_stage 2 '10-acme.sh' >/dev/null

  source_driver
  run main
  [ "$status" -eq 0 ]
  [[ "$output" == *'Phase 1 is complete'* ]]

  run main
  [ "$status" -ne 0 ]
  [[ "$output" == *'Reboot the host'* ]]
  [ ! -e "${PVE_CONFIG_STATE_DIR}/phase2__10-acme.done" ]

  run main --phase 2
  [ "$status" -ne 0 ]

  simulate_reboot
  run main
  [ "$status" -eq 0 ]
  [ -f "${PVE_CONFIG_STATE_DIR}/phase2__10-acme.done" ]
}

@test "--force overrides the reboot guard" {
  make_stage 1 '10-host.sh' >/dev/null
  make_stage 2 '10-acme.sh' >/dev/null

  source_driver
  run main
  [ "$status" -eq 0 ]

  run main --phase 2 --force
  [ "$status" -eq 0 ]
  [ -f "${PVE_CONFIG_STATE_DIR}/phase2__10-acme.done" ]
}

@test "the driver reports when everything is already done" {
  make_stage 1 '10-host.sh' >/dev/null
  source_driver
  state_mark_done "$(state_id 1 10-host)"

  run main
  [ "$status" -eq 0 ]
  [[ "$output" == *'already complete'* ]]
  [ ! -e "${ORDER_LOG}" ]
}

@test "bare --force re-runs the current phase" {
  make_stage 1 '10-host.sh' >/dev/null
  make_stage 1 '20-network.sh' >/dev/null

  source_driver
  state_mark_done "$(state_id 1 10-host)"

  run main --force
  [ "$status" -eq 0 ]
  run cat "${ORDER_LOG}"
  [ "${#lines[@]}" -eq 2 ]
}

@test "bare --force re-runs the last phase when everything is done" {
  make_stage 1 '10-host.sh' >/dev/null
  make_stage 2 '10-acme.sh' >/dev/null

  source_driver
  state_mark_done "$(state_id 1 10-host)"
  state_mark_done "$(state_id 2 10-acme)"

  run main --force
  [ "$status" -eq 0 ]
  [ "$(cat "${ORDER_LOG}")" = '10-acme.sh' ]
}

@test "the preflight saves the answers so the next run needs none" {
  make_stage 1 '10-host.sh' >/dev/null

  source_driver
  run main
  [ "$status" -eq 0 ]
  [ -f "${PVE_CONFIG_DIR}/pve-config.conf" ]
  run grep -c "^PVE_DOMAIN='example.test'$" "${PVE_CONFIG_DIR}/pve-config.conf"
  [ "$output" = '1' ]
}

@test "the preflight exports the resolved values to the stage" {
  mkdir -p "${PVE_CONFIG_STAGES_DIR}/phase1"
  cat >"${PVE_CONFIG_STAGES_DIR}/phase1/10-report.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\${PVE_FQDN}" >"${BATS_TEST_TMPDIR}/fqdn"
EOF
  chmod +x "${PVE_CONFIG_STAGES_DIR}/phase1/10-report.sh"

  source_driver
  run main
  [ "$status" -eq 0 ]
  [ "$(cat "${BATS_TEST_TMPDIR}/fqdn")" = 'testhost.example.test' ]
}

@test "a non-interactive run names every missing required key" {
  make_stage 1 '10-host.sh' >/dev/null
  unset PVE_DOMAIN PVE_ADMIN_USERS

  source_driver
  run main --non-interactive
  [ "$status" -ne 0 ]
  [[ "$output" == *'PVE_DOMAIN'* ]]
  [[ "$output" == *'PVE_ADMIN_USERS'* ]]
  [ ! -e "${ORDER_LOG}" ]
}

@test "--reconfigure prefers the environment over the saved answers" {
  make_stage 1 '10-host.sh' >/dev/null

  source_driver
  run main
  [ "$status" -eq 0 ]

  export PVE_DOMAIN='second.test'
  run main --force --reconfigure
  [ "$status" -eq 0 ]
  run grep -c "^PVE_DOMAIN='second.test'$" "${PVE_CONFIG_DIR}/pve-config.conf"
  [ "$output" = '1' ]
}

@test "bare --force re-runs phase 1 while its reboot is still owed" {
  make_stage 1 '10-host.sh' >/dev/null
  make_stage 2 '10-acme.sh' >/dev/null

  source_driver
  run main
  [ "$status" -eq 0 ]

  : >"${ORDER_LOG}"
  run main --force
  [ "$status" -eq 0 ]
  [[ "$output" == *'a reboot is still pending'* ]]
  run cat "${ORDER_LOG}"
  [ "$output" = '10-host.sh' ]
  [ ! -e "${PVE_CONFIG_STATE_DIR}/phase2__10-acme.done" ]
}

@test "bare --force rolls into phase 2 once the host has rebooted" {
  make_stage 1 '10-host.sh' >/dev/null
  make_stage 2 '10-acme.sh' >/dev/null

  source_driver
  run main
  [ "$status" -eq 0 ]
  simulate_reboot

  run main --force
  [ "$status" -eq 0 ]
  [ -f "${PVE_CONFIG_STATE_DIR}/phase2__10-acme.done" ]
}

@test "--reconfigure keeps config keys the schema does not know about" {
  make_stage 1 '10-host.sh' >/dev/null
  local config="${PVE_CONFIG_DIR}/pve-config.conf"
  printf "PVE_BRIDGE='vmbr7'\nPVE_TAILSCALE_CTID='131'\n" >"${config}"

  source_driver
  run main --reconfigure
  [ "$status" -eq 0 ]

  run grep -c "PVE_BRIDGE='vmbr7'" "${config}"
  [ "$output" = '1' ]
  run grep -c "PVE_TAILSCALE_CTID='131'" "${config}"
  [ "$output" = '1' ]
  run grep -c "PVE_DOMAIN='example.test'" "${config}"
  [ "$output" = '1' ]
}

@test "--reconfigure re-derives a schema key instead of reusing the stored one" {
  make_stage 1 '10-host.sh' >/dev/null
  local config="${PVE_CONFIG_DIR}/pve-config.conf"
  printf "PVE_DOMAIN='stale.net'\n" >"${config}"

  source_driver
  PVE_DOMAIN='fresh.net' run main --reconfigure
  [ "$status" -eq 0 ]
  run grep -c "PVE_DOMAIN='fresh.net'" "${config}"
  [ "$output" = '1' ]
}

@test "the derived FQDN follows the resolved hostname" {
  source_driver
  PVE_HOSTNAME='newname' PVE_DOMAIN='example.test' run _schema_derive_fqdn
  [ "$status" -eq 0 ]
  [ "$output" = 'newname.example.test' ]
}

@test "schema resolution derives the FQDN from the hostname it just resolved" {
  make_stage 1 '10-host.sh' >/dev/null
  local config="${PVE_CONFIG_DIR}/pve-config.conf"

  source_driver
  unset PVE_FQDN
  PVE_HOSTNAME='pve9' PVE_DOMAIN='example.test' run main
  [ "$status" -eq 0 ]
  run grep -c "PVE_FQDN='pve9.example.test'" "${config}"
  [ "$output" = '1' ]
}

@test "a blank saved placeholder is derived rather than taken literally" {
  make_stage 1 '10-host.sh' >/dev/null
  local config="${PVE_CONFIG_DIR}/pve-config.conf"
  printf "PVE_FQDN=''\n" >"${config}"

  source_driver
  unset PVE_FQDN
  PVE_HOSTNAME='pve8' PVE_DOMAIN='example.test' run main
  [ "$status" -eq 0 ]
  run grep -c "PVE_FQDN='pve8.example.test'" "${config}"
  [ "$output" = '1' ]
}

# An export is a deliberate statement, so an empty one is never quietly
# replaced by a derivation; a required key set that way is reported missing.
@test "an exported empty value is honoured instead of being re-derived" {
  source_driver
  config_reset
  PVE_HOSTNAME='' run schema_resolve
  [ "$status" -ne 0 ]
  [[ "$output" == *'PVE_HOSTNAME'* ]]
  [[ "$output" != *'PVE_DOMAIN'* ]]
}

@test "a forced phase 1 rerun makes the reboot owed again" {
  make_stage 1 '10-host.sh' >/dev/null
  make_stage 2 '10-acme.sh' >/dev/null

  source_driver
  run main
  [ "$status" -eq 0 ]
  simulate_reboot

  run main --phase 1 --force
  [ "$status" -eq 0 ]
  [[ "$output" != *'Phase 1 is complete'* ]]

  run main
  [ "$status" -ne 0 ]
  [[ "$output" == *'Reboot the host'* ]]
}

@test "a forced stage that fails leaves itself pending" {
  make_stage 1 '10-host.sh' >/dev/null

  source_driver
  run main
  [ "$status" -eq 0 ]
  [ -f "${PVE_CONFIG_STATE_DIR}/phase1__10-host.done" ]

  make_stage 1 '10-host.sh' 1 >/dev/null
  run main --stage 10-host --force
  [ "$status" -ne 0 ]
  [ ! -e "${PVE_CONFIG_STATE_DIR}/phase1__10-host.done" ]
}

@test "a dry run of a completed forced stage keeps its marker" {
  make_stage 1 '10-host.sh' >/dev/null

  source_driver
  run main
  [ "$status" -eq 0 ]

  run main --stage 10-host --force --dry-run
  [ "$status" -eq 0 ]
  [ -f "${PVE_CONFIG_STATE_DIR}/phase1__10-host.done" ]
}

@test "a stage whose completion cannot be recorded fails the run" {
  make_stage 1 '10-host.sh' >/dev/null

  source_driver
  state_mark_done() { return 1; }
  run main
  [ "$status" -ne 0 ]
  [[ "$output" == *'unable to record completion'* ]]
}

@test "re-selecting a completed phase 1 does not make another reboot owed" {
  make_stage 1 '10-host.sh' >/dev/null
  make_stage 2 '10-acme.sh' >/dev/null

  source_driver
  run main
  [ "$status" -eq 0 ]
  simulate_reboot

  # Nothing runs here, so nothing can require another reboot.
  run main --phase 1
  [ "$status" -eq 0 ]
  run main --stage 10-host
  [ "$status" -eq 0 ]

  run main --phase 2
  [ "$status" -eq 0 ]
  [ -f "${PVE_CONFIG_STATE_DIR}/phase2__10-acme.done" ]
}
