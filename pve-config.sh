#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

PVE_CONFIG_SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PVE_CONFIG_DIR=${PVE_CONFIG_DIR:-${PVE_CONFIG_SCRIPT_DIR}}
PVE_CONFIG_LIB_DIR=${PVE_CONFIG_LIB_DIR:-${PVE_CONFIG_SCRIPT_DIR}/lib}

# shellcheck source=lib/common.sh
source "${PVE_CONFIG_LIB_DIR}/common.sh"
# shellcheck source=lib/version.sh
source "${PVE_CONFIG_LIB_DIR}/version.sh"
# shellcheck source=lib/config.sh
source "${PVE_CONFIG_LIB_DIR}/config.sh"
# shellcheck source=lib/detect.sh
source "${PVE_CONFIG_LIB_DIR}/detect.sh"
# shellcheck source=lib/state.sh
source "${PVE_CONFIG_LIB_DIR}/state.sh"
# shellcheck source=lib/schema.sh
source "${PVE_CONFIG_LIB_DIR}/schema.sh"

: "${PVE_CONFIG_DRY_RUN:=0}"
: "${NON_INTERACTIVE:=0}"
: "${ASSUME_YES:=0}"
: "${FORCE:=0}"
: "${RECONFIGURE:=0}"
STAGES_EXECUTED=0

usage() {
  cat <<'EOF'
Usage: pve-config.sh [OPTIONS]

Configures a Proxmox VE host in two phases. Phase 1 configures the host
itself and ends with a reboot that the operator performs. Phase 2 orders the
ACME certificate and creates the guests. Re-run this script after the reboot
and it continues where it left off.

Options:
  --list                 List discovered stages with phase and status
  --phase N              Run only the stages belonging to phase N
  --stage NAME           Run a single stage. NAME is the basename, with or
                         without .sh, and may be qualified as phase1__NAME
                         when the same basename exists in several phases
  --force                Re-run the selected stages even when already done.
                         On its own it re-runs the current phase, which is
                         still phase 1 while the reboot it asked for is
                         owed. Only --phase or --stage may override the
                         reboot gate
  --reconfigure          Prompt again for the keys the toolkit asks about.
                         Any other key in the config file is kept as is
  --dry-run              Report what would happen without changing anything
  --config PATH          Use an alternate configuration file
  --non-interactive      Never prompt; fail if a required value is missing
  -h, --help             Show this help
      --version          Print the toolkit version and exit

Files:
  pve-config.conf        Generated configuration, reused on later runs
  secrets.env            Generated secrets, mode 600, never committed
  state/                 Per-stage completion markers
EOF
}

# Reported by --version, and recorded into the state directory on every run
# that touches the host. The committed tree reads 0.0.0; a release tarball
# carries the tag it was built from.
version() {
  printf 'pve-config %s\n' "${PVE_CONFIG_VERSION:-unknown}"
}

stages_dir() {
  printf '%s\n' "${PVE_CONFIG_STAGES_DIR:-${PVE_CONFIG_DIR}/stages}"
}

stage_name() {
  local base
  base=$(basename -- "$1")
  printf '%s\n' "${base%.sh}"
}

stage_phase_of() {
  local dir
  dir=$(basename -- "$(dirname -- "$1")")
  printf '%s\n' "${dir#phase}"
}

_stage_glob() {
  local dir
  dir=$(stages_dir)
  [[ -d ${dir} ]] || return 0

  local restore
  # shopt -p exits non-zero when the option is off, which would trip
  # errexit; the status carries no error here.
  restore=$(shopt -p nullglob) || true
  shopt -s nullglob
  local -a paths=("${dir}"/phase*/[0-9][0-9]-*.sh)
  eval "${restore}"

  local path
  for path in ${paths[@]+"${paths[@]}"}; do
    printf '%s\n' "${path}"
  done
}

# A directory named phase<something-not-a-number> is an error rather than
# something to sort around: it would otherwise run in an arbitrary position.
# Two stages sharing an ordering prefix are an error for the same reason.
#
# This is deliberately separate from discovery, which runs inside command
# substitution where an exit would only kill the subshell.
stage_validate() {
  local path base phase prefix key
  local -A seen=()
  local -a paths=()
  mapfile -t paths < <(_stage_glob)
  for path in ${paths[@]+"${paths[@]}"}; do
    phase=$(stage_phase_of "${path}")
    if [[ ! ${phase} =~ ^[0-9]+$ ]]; then
      die "Invalid stage directory $(dirname -- "${path}"); expected phase<N>."
    fi
    base=$(basename -- "${path}")
    prefix=${base%%-*}
    key="${phase}/${prefix}"
    if [[ -n ${seen[${key}]+set} ]]; then
      die "Duplicate ordering prefix ${prefix} in phase ${phase}: ${seen[${key}]} and ${path}."
    fi
    seen[${key}]=${path}
  done
}

# Emits "phase<TAB>prefix<TAB>path" ordered by phase then by the numeric
# filename prefix. Prints nothing when no stages are installed, which is the
# state of a fresh checkout that carries the framework only.
stage_discover() {
  local path base
  local -a paths=()
  mapfile -t paths < <(_stage_glob)
  [[ ${#paths[@]} -gt 0 ]] || return 0

  for path in "${paths[@]}"; do
    base=$(basename -- "${path}")
    printf '%s\t%s\t%s\n' "$(stage_phase_of "${path}")" "${base%%-*}" "${path}"
  done | sort -k1,1n -k2,2n
}

stage_paths() {
  stage_discover | cut -f3
}

stage_id_of() {
  state_id "$(stage_phase_of "$1")" "$(stage_name "$1")"
}

stage_status() {
  if state_is_done "$1"; then
    printf 'done\n'
  else
    printf 'pending\n'
  fi
}

cmd_list() {
  stage_validate
  local -a paths=()
  mapfile -t paths < <(stage_paths)

  if [[ ${#paths[@]} -eq 0 ]]; then
    printf 'No stages installed under %s\n' "$(stages_dir)"
    return 0
  fi

  printf '%-7s %-32s %s\n' 'PHASE' 'STAGE' 'STATUS'
  local path
  for path in "${paths[@]}"; do
    printf '%-7s %-32s %s\n' \
      "$(stage_phase_of "${path}")" \
      "$(stage_name "${path}")" \
      "$(stage_status "$(stage_id_of "${path}")")"
  done
}

phases_in_order() {
  stage_discover | cut -f1 | awk '!seen[$0]++'
}

phase_is_complete() {
  local phase=$1 path found=0
  local -a paths=()
  mapfile -t paths < <(stage_paths)
  for path in ${paths[@]+"${paths[@]}"}; do
    if [[ $(stage_phase_of "${path}") == "${phase}" ]]; then
      found=1
      if ! state_is_done "$(stage_id_of "${path}")"; then
        return 1
      fi
    fi
  done
  [[ ${found} == 1 ]]
}

# Lowest phase that still has pending stages. Fails when every discovered
# stage is complete.
next_phase() {
  local -a paths=()
  mapfile -t paths < <(stage_paths)
  local path
  for path in ${paths[@]+"${paths[@]}"}; do
    if ! state_is_done "$(stage_id_of "${path}")"; then
      stage_phase_of "${path}"
      return 0
    fi
  done
  return 1
}

last_phase() {
  phases_in_order | tail -n 1
}

paths_for_phase() {
  local phase=$1 path
  local -a paths=()
  mapfile -t paths < <(stage_paths)
  for path in ${paths[@]+"${paths[@]}"}; do
    if [[ $(stage_phase_of "${path}") == "${phase}" ]]; then
      printf '%s\n' "${path}"
    fi
  done
}

# Matches --stage NAME against the discovered stages. NAME may be a bare
# basename, a basename with .sh, or a phase-qualified phase1__NAME or
# phase1/NAME. A bare name that exists in more than one phase is rejected
# rather than guessed at.
resolve_stage() {
  local want=${1%.sh} path qualified
  local -a paths=() matched=()
  want=${want//\//__}
  mapfile -t paths < <(stage_paths)
  for path in ${paths[@]+"${paths[@]}"}; do
    qualified=$(stage_id_of "${path}")
    if [[ ${want} == "${qualified}" || ${want} == "$(stage_name "${path}")" ]]; then
      matched+=("${path}")
    fi
  done

  if [[ ${#matched[@]} -eq 0 ]]; then
    die "No such stage: $1"
  fi
  if [[ ${#matched[@]} -gt 1 ]]; then
    local candidates=''
    for path in "${matched[@]}"; do
      candidates+=" $(stage_id_of "${path}")"
    done
    die "Stage name $1 is ambiguous; use one of:${candidates}"
  fi
  printf '%s\n' "${matched[0]}"
}

# Phase N may only run once the reboot that phase N-1 asked for has
# happened. The boot id recorded when the earlier phase finished is compared
# against the running one; equal means no reboot since.
assert_reboot_done() {
  local phase=$1 explicit=$2
  local previous=$((phase - 1))
  [[ ${phase} -ge 2 ]] || return 0
  state_reboot_pending "${previous}" || return 0
  # Only a phase or stage the operator named may override the gate. Bare
  # --force means "re-run what I would have run", which is never a phase
  # the host has not rebooted into.
  if [[ ${FORCE} == 1 && ${explicit} == 1 ]]; then
    log_warn "phase ${previous} finished during this boot; continuing because --force was given."
    return 0
  fi
  die "Phase ${previous} finished during this boot. Reboot the host, then run this script again to start phase ${phase}."
}

# Stages run as child processes so a failure inside one cannot abort the
# driver mid-loop or leave its shell options behind. A dry run still runs
# them: correctness depends on every stage routing its changes through the
# helpers in lib/common.sh, which is only tested by actually running them.
run_stage() {
  local path=$1 id name
  id=$(stage_id_of "${path}")
  name=$(stage_name "${path}")

  if state_is_done "${id}" && [[ ${FORCE} != 1 ]]; then
    log_info "skipping ${id} (already done)"
    return 0
  fi

  # Counted rather than inferred from completion: a run that only skipped
  # finished stages has changed nothing, so it must not make a reboot owed.
  STAGES_EXECUTED=$((STAGES_EXECUTED + 1))

  if dry_run_enabled; then
    log_info "dry run: stage ${id}"
  else
    log_info "running stage ${id}"
    # The marker goes before the run, not after it: a forced stage that
    # fails or is interrupted part way has changed the host and must come
    # back as pending rather than keep the old claim of completion. A
    # marker that will not clear would outlive such a failure, so the
    # child is not started at all.
    if ! state_clear "${id}"; then
      log_error "unable to clear the completion marker for ${id}"
      return 1
    fi
  fi

  # PS4 is normalised rather than inherited. It is expanded for every
  # traced command, so a PS4 holding a parameter expansion prints whatever
  # that parameter holds -- including a credential a stage is handling --
  # the moment anybody runs this toolkit with tracing on. The default is
  # what bash itself uses, so a run that set no prefix looks unchanged.
  #
  # PVE_CONFIG_TRACE_PREFIX is there for the operator who set a prefix on
  # purpose and wants it back. It is deliberate, and it reaches no secret:
  # the stages that handle credentials replace PS4 again themselves and
  # keep it replaced for as long as a credential is reachable.
  if ! PS4=${PVE_CONFIG_TRACE_PREFIX-'+ '} bash "${path}"; then
    log_error "stage ${id} failed"
    return 1
  fi

  if dry_run_enabled; then
    log_info "dry run: stage ${id} would be marked complete"
  else
    # The reboot the phase owes is persisted before its completion is
    # published. Published first, a crash or a failed write here would
    # leave a complete phase 1 with no recorded boot id, which reads as
    # "already rebooted" and lets phase 2 start on an unrebooted host.
    if [[ $(stage_phase_of "${path}") == 1 ]] && ! state_record_boot_id 1; then
      log_error "unable to record the reboot requirement for phase 1"
      return 1
    fi
    # Without a durable marker the run is not actually recorded, so a
    # failure here has to stop the driver rather than be logged over.
    if ! state_mark_done "${id}"; then
      log_error "unable to record completion of ${id}"
      return 1
    fi
    log_info "stage ${name} complete"
  fi
  return 0
}

run_stages() {
  local path
  for path in "$@"; do
    run_stage "${path}" || return 1
  done
}

# Exported so every stage child sees the same paths and run modes.
export_runtime() {
  PVE_CONFIG_STATE_DIR=$(state_dir)
  PVE_CONFIG_SECRET_KEYS=$(config_secret_keys)
  export PVE_CONFIG_DIR PVE_CONFIG_LIB_DIR PVE_CONFIG_STATE_DIR
  export PVE_CONFIG_DRY_RUN NON_INTERACTIVE ASSUME_YES PVE_CONFIG_SECRET_KEYS
}

reboot_notice() {
  cat <<'EOF'

Phase 1 is complete. Reboot the host now:

    reboot

After the host comes back, run this script again to continue with phase 2
(ACME certificate and guest creation).
EOF
}

# What phase 1 produced, read back off the host rather than echoed from the
# values that went in. Every lookup is guarded: this runs at the end of a
# successful phase and must never be the thing that fails it.
phase1_summary() {
  local root value
  root=$(sysroot)

  printf '\n=== Phase 1 summary ===\n'
  printf '%-14s %s\n' 'Hostname:' "$(hostname -f 2>/dev/null || printf 'unknown')"

  value=$(detect_ipv4_address vmbr0 2>/dev/null) || value='none'
  printf '%-14s %s\n' 'vmbr0:' "${value}"

  value=$(cd -- "${root}/etc/pve/nodes" 2>/dev/null && printf '%s ' */ || true)
  printf '%-14s %s\n' 'Node dir:' "${value:-unknown}"

  local unit
  for unit in pve-cluster pveproxy pvedaemon pvestatd; do
    value=$(systemctl is-active "${unit}.service" 2>/dev/null) || value='unknown'
    printf '%-14s %s\n' "${unit}:" "${value}"
  done

  if [[ -f ${root}/etc/apt/sources.list.d/proxmox.sources ]]; then
    value=$(sed -n 's/^Suites: //p' "${root}/etc/apt/sources.list.d/proxmox.sources")
    printf '%-14s %s\n' 'Apt suite:' "${value:-unknown}"
  fi

  printf '%-14s %s\n' 'Admins:' "${PVE_ADMIN_USERS:-none}"
}

# Resolves the whole schema before any stage runs. Stages are children, so a
# value they resolve cannot be saved by the driver; asking here is what makes
# every run after the first unattended.
preflight() {
  local config_path=$1 secrets_path=$2
  schema_resolve
  config_save "${config_path}" >/dev/null
  secrets_save "${secrets_path}" >/dev/null
}

main() {
  local mode='auto' want_phase='' want_stage='' config_path=''
  STAGES_EXECUTED=0

  while [[ $# -gt 0 ]]; do
    case $1 in
      --list)
        mode='list'
        ;;
      --phase)
        [[ $# -ge 2 ]] || die '--phase requires a number'
        mode='phase'
        want_phase=$2
        shift
        ;;
      --stage)
        [[ $# -ge 2 ]] || die '--stage requires a name'
        mode='stage'
        want_stage=$2
        shift
        ;;
      --force) FORCE=1 ;;
      --reconfigure) RECONFIGURE=1 ;;
      --dry-run) PVE_CONFIG_DRY_RUN=1 ;;
      --config)
        [[ $# -ge 2 ]] || die '--config requires a path'
        config_path=$2
        shift
        ;;
      --non-interactive) NON_INTERACTIVE=1 ;;
      -h | --help)
        usage
        return 0
        ;;
      --version)
        version
        return 0
        ;;
      *) die "Unknown option: $1" ;;
    esac
    shift
  done

  if [[ ${mode} == 'phase' && ! ${want_phase} =~ ^[0-9]+$ ]]; then
    die "--phase expects a number, got: ${want_phase}"
  fi

  config_path=${config_path:-${PVE_CONFIG_DIR}/pve-config.conf}
  local secrets_path="${PVE_CONFIG_DIR}/secrets.env"

  if [[ ${mode} == 'list' ]]; then
    cmd_list
    return 0
  fi

  # Listing and help stay usable anywhere; anything that can touch the host
  # does not.
  dry_run_enabled || require_root
  stage_validate

  local -a all=()
  mapfile -t all < <(stage_paths)
  if [[ ${#all[@]} -eq 0 ]]; then
    log_warn "No stages installed under $(stages_dir); nothing to do."
    return 0
  fi

  local -a selected=()
  local phase='' path explicit=0

  case ${mode} in
    stage)
      explicit=1
      path=$(resolve_stage "${want_stage}")
      selected=("${path}")
      phase=$(stage_phase_of "${path}")
      ;;
    phase)
      explicit=1
      phase=${want_phase}
      mapfile -t selected < <(paths_for_phase "${phase}")
      [[ ${#selected[@]} -gt 0 ]] || die "No stages found for phase ${phase}"
      ;;
    *)
      if ! phase=$(next_phase); then
        # Everything is done. Bare --force re-runs the last phase rather
        # than doing nothing at all.
        if [[ ${FORCE} == 1 ]]; then
          phase=$(last_phase)
          log_info "every stage is complete; --force re-runs phase ${phase}."
        else
          log_info 'Every stage is already complete; nothing to do.'
          return 0
        fi
      fi
      # Bare --force re-runs the current phase. While a reboot is still
      # owed, the current phase is the one that asked for it, not the next.
      if [[ ${FORCE} == 1 && ${phase} -ge 2 ]] && state_reboot_pending $((phase - 1)); then
        phase=$((phase - 1))
        log_info "a reboot is still pending; --force re-runs phase ${phase}."
      fi
      mapfile -t selected < <(paths_for_phase "${phase}")
      ;;
  esac

  assert_reboot_done "${phase}" "${explicit}"

  local phase1_was_complete=0
  if phase_is_complete 1; then
    phase1_was_complete=1
  fi

  # --reconfigure re-asks for the schema keys only. The files are still
  # parsed in full so that keys the schema does not know about -- which is
  # most of what later phases read -- survive the rewrite untouched.
  if [[ ${RECONFIGURE} == 1 ]]; then
    local key
    while read -r key; do
      if [[ -n ${key} ]]; then
        config_ignore_stored "${key}"
      fi
    done < <(schema_keys)
  fi
  config_load "${config_path}"
  secrets_load "${secrets_path}"
  preflight "${config_path}" "${secrets_path}"
  export_runtime

  # Stamp the configuring version before any stage runs, so a run that
  # fails part way still leaves the host saying what was driving it.
  state_record_version

  run_stages "${selected[@]}" || die 'Aborting; fix the failure above and re-run.'

  # Each phase 1 stage records the reboot it owes as it completes, so all
  # that is left here is the notice, which belongs to the moment phase 1
  # first becomes complete and is not repeated afterwards.
  if ! dry_run_enabled && [[ ${phase} == 1 ]] && [[ ${STAGES_EXECUTED} -gt 0 ]] &&
    [[ ${phase1_was_complete} == 0 ]] && phase_is_complete 1; then
    phase1_summary
    reboot_notice
  fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
