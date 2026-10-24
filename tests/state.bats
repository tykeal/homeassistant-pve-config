#!/usr/bin/env bats
# SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
# SPDX-License-Identifier: Apache-2.0

load helpers/test_helper

setup() {
  load_libs
  isolate_env
}

@test "state_dir honours the explicit override" {
  run state_dir
  [ "$output" = "${PVE_CONFIG_STATE_DIR}" ]
}

@test "state_dir derives from the install directory when not overridden" {
  unset PVE_CONFIG_STATE_DIR
  run state_dir
  [ "$output" = "${PVE_CONFIG_DIR}/state" ]
}

@test "a stage marker goes through its full lifecycle" {
  run state_is_done phase1__10-example
  [ "$status" -ne 0 ]

  state_mark_done phase1__10-example
  run state_is_done phase1__10-example
  [ "$status" -eq 0 ]

  state_clear phase1__10-example
  run state_is_done phase1__10-example
  [ "$status" -ne 0 ]
}

@test "state_mark_done is idempotent and keeps the first timestamp" {
  state_mark_done phase1__10-example
  local marker="${PVE_CONFIG_STATE_DIR}/phase1__10-example.done"
  local first
  first=$(cat "${marker}")

  run state_mark_done phase1__10-example
  [ "$status" -eq 0 ]
  [ "$(cat "${marker}")" = "${first}" ]
}

@test "the marker records a timestamp" {
  state_mark_done phase1__10-example
  run cat "${PVE_CONFIG_STATE_DIR}/phase1__10-example.done"
  [[ "$output" == completed*20* ]]
}

@test "state_clear on an unknown stage is not an error" {
  run state_clear phase1__99-never-ran
  [ "$status" -eq 0 ]
}

@test "state_list reports every completed stage" {
  state_mark_done phase1__10-first
  state_mark_done phase1__20-second
  run state_list
  [ "${#lines[@]}" -eq 2 ]
  [[ "$output" == *10-first* ]]
  [[ "$output" == *20-second* ]]
}

@test "state_list is empty before anything has run" {
  run state_list
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a dry run writes no marker" {
  PVE_CONFIG_DRY_RUN=1 run state_mark_done phase1__10-example
  [ "$status" -eq 0 ]
  [ ! -e "${PVE_CONFIG_STATE_DIR}/phase1__10-example.done" ]
}

@test "state_id qualifies a stage with its phase" {
  run state_id 2 10-acme
  [ "$output" = 'phase2__10-acme' ]
}

@test "the same stage name in two phases keeps separate markers" {
  state_mark_done "$(state_id 1 10-host)"

  run state_is_done "$(state_id 2 10-host)"
  [ "$status" -ne 0 ]

  run state_is_done "$(state_id 1 10-host)"
  [ "$status" -eq 0 ]
}

@test "state_list prints the phase and the stage separately" {
  state_mark_done "$(state_id 2 30-frigate)"
  run state_list
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == 2$'\t'30-frigate$'\t'* ]]
}

@test "no boot id is recorded until a phase asks for one" {
  run state_recorded_boot_id 1
  [ "$status" -ne 0 ]

  run state_reboot_pending 1
  [ "$status" -ne 0 ]
}

@test "a recorded boot id marks the reboot as still pending" {
  state_record_boot_id 1
  run state_reboot_pending 1
  [ "$status" -eq 0 ]
}

@test "a reboot clears the pending state" {
  state_record_boot_id 1
  simulate_reboot
  run state_reboot_pending 1
  [ "$status" -ne 0 ]
}

@test "a host without a readable boot id is never blocked" {
  rm -f "${PVE_CONFIG_BOOT_ID_PATH}"
  run state_record_boot_id 1
  [ "$status" -eq 0 ]
  run state_reboot_pending 1
  [ "$status" -ne 0 ]
}

@test "a dry run records no boot id" {
  PVE_CONFIG_DRY_RUN=1 run state_record_boot_id 1
  [ "$status" -eq 0 ]
  [ ! -e "${PVE_CONFIG_STATE_DIR}/phase1.bootid" ]
}

@test "a marker without a phase is labelled rather than mis-parsed" {
  mkdir -p "${PVE_CONFIG_STATE_DIR}"
  printf 'completed 2026-01-01T00:00:00Z\n' \
    >"${PVE_CONFIG_STATE_DIR}/10-host.done"

  run state_list
  [ "$status" -eq 0 ]
  [[ "$output" == *'unrecognised marker'* ]]
  [[ "$output" == *'10-host'* ]]
}

@test "a marker is published whole or not at all" {
  state_mark_done 'phase1__10-host'
  local marker="${PVE_CONFIG_STATE_DIR}/phase1__10-host.done"
  [ -f "${marker}" ]
  run cat "${marker}"
  [[ "$output" == completed\ * ]]

  # Nothing partial is left behind in the state directory either.
  run find "${PVE_CONFIG_STATE_DIR}" -name '.*' -type f
  [ -z "$output" ]
}
