#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
# SPDX-License-Identifier: Apache-2.0

# Per-stage completion markers. These are what let the operator re-run the
# driver after the reboot and have it continue instead of starting over.
#
# A marker is named for the phase as well as the stage, because two phases
# may legitimately carry the same ordering prefix and basename.

state_dir() {
  printf '%s\n' "${PVE_CONFIG_STATE_DIR:-${PVE_CONFIG_DIR:-/root/pve-config}/state}"
}

# The identity of a stage: phase and basename joined. Markers, --stage and
# state_list all speak this.
state_id() {
  printf 'phase%s__%s\n' "$1" "$2"
}

_state_marker() {
  printf '%s/%s.done\n' "$(state_dir)" "$1"
}

state_is_done() {
  [[ -f $(_state_marker "$1") ]]
}

state_mark_done() {
  local id=$1 marker
  marker=$(_state_marker "${id}")
  if [[ -f ${marker} ]]; then
    return 0
  fi
  if dry_run_enabled; then
    log_info "would mark stage ${id} complete"
    return 0
  fi
  # Published through write_file so the marker appears only once it is
  # complete: a half written marker still satisfies state_is_done and
  # would silently skip the stage on the next run.
  local content
  printf -v content 'completed %s\n' "$(date -Is)"
  write_file "${marker}" "${content}" 0644 >/dev/null
}

state_clear() {
  local id=$1 marker
  marker=$(_state_marker "${id}")
  [[ -f ${marker} ]] || return 0
  if dry_run_enabled; then
    log_info "would clear stage ${id}"
    return 0
  fi
  rm -f -- "${marker}"
}

# Prints "phase<TAB>stage<TAB>timestamp" for every recorded completion, so
# the output stays readable even though the marker name is qualified.
state_list() {
  local dir marker id phase stage
  dir=$(state_dir)
  [[ -d ${dir} ]] || return 0
  local restore
  # shopt -p exits non-zero when the option is off, which would trip
  # errexit; the status carries no error here.
  restore=$(shopt -p nullglob) || true
  shopt -s nullglob
  for marker in "${dir}"/*.done; do
    id=$(basename -- "${marker}" .done)
    # A marker that does not carry a phase predates this naming or was
    # dropped in by hand; label it rather than splitting it into nonsense.
    if [[ ${id} =~ ^phase[0-9]+__.+$ ]]; then
      phase=${id%%__*}
      phase=${phase#phase}
      stage=${id#*__}
    else
      phase='?'
      stage="${id} (unrecognised marker)"
    fi
    printf '%s\t%s\t%s\n' "${phase}" "${stage}" "$(sed -n 's/^completed //p' "${marker}")"
  done
  eval "${restore}"
}

# The kernel's identifier for the current boot. It changes on every reboot
# and on nothing else, which is exactly the signal needed to tell "the
# operator rebooted" from "the operator ran the driver twice".
boot_id_path() {
  printf '%s\n' "${PVE_CONFIG_BOOT_ID_PATH:-/proc/sys/kernel/random/boot_id}"
}

state_current_boot_id() {
  local path id
  path=$(boot_id_path)
  [[ -r ${path} ]] || return 1
  IFS= read -r id <"${path}" || return 1
  [[ -n ${id} ]] || return 1
  printf '%s\n' "${id}"
}

_boot_id_marker() {
  printf '%s/phase%s.bootid\n' "$(state_dir)" "$1"
}

# Records the boot the given phase finished under.
state_record_boot_id() {
  local phase=$1 marker current
  current=$(state_current_boot_id) || return 0
  marker=$(_boot_id_marker "${phase}")
  if dry_run_enabled; then
    log_info "would record the boot id for phase ${phase}"
    return 0
  fi
  local content
  printf -v content '%s\n' "${current}"
  write_file "${marker}" "${content}" 0644 >/dev/null
}

state_recorded_boot_id() {
  local marker id
  marker=$(_boot_id_marker "$1")
  [[ -f ${marker} ]] || return 1
  IFS= read -r id <"${marker}" || return 1
  printf '%s\n' "${id}"
}

# True when the given phase finished during the boot that is still running,
# meaning the reboot it asked for has not happened yet. Unknown on either
# side means no opinion, so a host without a boot id is never blocked.
state_reboot_pending() {
  local phase=$1 recorded current
  recorded=$(state_recorded_boot_id "${phase}") || return 1
  current=$(state_current_boot_id) || return 1
  [[ ${recorded} == "${current}" ]]
}
