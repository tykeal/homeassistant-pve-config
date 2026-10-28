#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

# shellcheck source=lib/stage.sh
source "${PVE_CONFIG_LIB_DIR:?PVE_CONFIG_LIB_DIR is unset}/stage.sh"
# shellcheck source=lib/haos.sh
source "${PVE_CONFIG_LIB_DIR}/haos.sh"

# A deployment that runs Home Assistant somewhere else, or not at all,
# says so once and is left alone.
if [[ ${PVE_HAOS_ENABLED:-no} != yes ]]; then
  log_info 'PVE_HAOS_ENABLED is not yes; not building a Home Assistant OS virtual machine'
  exit 0
fi

stage_require PVE_HAOS_HOSTNAME

# The cluster listing is read with a JSON decoder, and that reading has a
# third answer: "I could not tell". Saying here, once, that the decoder is
# missing beats the same answer arriving later as a refusal to build.
acme_require_json_decoder

hostname=${PVE_HAOS_HOSTNAME}
haos_hostname_valid "${hostname}" ||
  die "PVE_HAOS_HOSTNAME is '${hostname}', which is not a machine name: lowercase letters, digits and hyphens, starting and ending with a letter or a digit, at most 63 characters."

vmid=''
haos_vmid_resolve vmid "${PVE_HAOS_VMID:-}" "${PVE_HAOS_ADOPT_EXISTING:-no}"

exists=0
haos_vm_exists "${vmid}" || exists=$?
((exists == 2)) &&
  die "Unable to tell whether virtual machine ${vmid} exists on this node. Refusing to build a machine on an id this node cannot account for."

needs_disk=0
owned=0
if ((exists == 0)); then
  log_info "virtual machine ${vmid} is already here; converging it rather than building another"

  # The resources are settings of a machine that exists, and this stage
  # does not change them: memory and cores are read when the appliance
  # boots, so writing them would mean rebooting somebody's running Home
  # Assistant to apply a number. An operator who configured one and is
  # not getting it hears about it rather than being left to wonder.
  for _haos_key in memory cores; do
    case ${_haos_key} in
      memory) _haos_name=PVE_HAOS_RAM_MB ;;
      *) _haos_name=PVE_HAOS_CORES ;;
    esac
    _haos_want=${!_haos_name:-}
    [[ -n ${_haos_want} ]] || continue
    _haos_have=''
    _haos_rc=0
    haos_vm_conf_value _haos_have "${vmid}" "${_haos_key}" || _haos_rc=$?
    ((_haos_rc == 2)) &&
      die "Unable to read the configuration of virtual machine ${vmid}."
    ((_haos_rc == 0)) || continue
    [[ ${_haos_have} == "${_haos_want}" ]] && continue
    log_warn "${_haos_name} is ${_haos_want} and virtual machine ${vmid} has ${_haos_key} ${_haos_have}. Resources are applied when the machine is built; change it with 'qm set ${vmid} --${_haos_key} ${_haos_want}' and reboot the appliance when you are ready for the outage."
  done

  # A machine this stage created but never finished giving a disk to: the
  # run was interrupted between the `qm create` and the import. It is
  # recognisable because the mark went on in the create, and finishing it
  # is the only alternative to leaving a machine that cannot boot and
  # that every later run reports as converged.
  #
  # Only for a machine carrying the mark. An adopted machine is somebody
  # else's work until this stage has tagged it, and attaching a Home
  # Assistant disk to it on the grounds that it has no scsi0 would be
  # this stage overwriting a decision it did not make.
  _haos_owned=0
  haos_vm_is_owned "${vmid}" || _haos_owned=$?
  ((_haos_owned == 2)) &&
    die "Unable to read the tags of virtual machine ${vmid}."
  ((_haos_owned == 0)) && owned=1

  _haos_rc=0
  haos_vm_conf_value _haos_have "${vmid}" scsi0 || _haos_rc=$?
  ((_haos_rc == 2)) &&
    die "Unable to read the configuration of virtual machine ${vmid}, so this node cannot tell whether it has a root disk."
  if ((_haos_rc == 1)); then
    if ((owned)); then
      needs_disk=1
      log_warn "virtual machine ${vmid} carries the ${HAOS_OWNER_TAG} tag and has no root disk, which is what an interrupted build leaves behind. Finishing it."
    else
      log_warn "virtual machine ${vmid} has no root disk and does not carry the ${HAOS_OWNER_TAG} tag, so this stage did not build it and will not give it one."
    fi
  fi
else
  needs_disk=1
  # The machine this run is about to build is this stage's by definition:
  # the mark goes on in the create.
  owned=1
fi

# The size the appliance's disk has to end up at. Read outside the build
# path because a machine that exists is held to it too: an attach that
# worked and a resize that did not is a machine running on a disk smaller
# than the deployment asked for, and the next run has to finish that
# rather than read the attached disk as proof the rest happened.
#
# The published image is a 32 GiB disk and qm will not shrink one, so a
# smaller figure is a setting that silently does not happen. The
# appliance can be given more.
disk=${PVE_HAOS_DISK_GB:-${HAOS_IMAGE_DISK_GB}}
_haos_is_number "${disk}" ||
  die "PVE_HAOS_DISK_GB is '${disk}', which is not a number of gigabytes."
((disk >= HAOS_IMAGE_DISK_GB)) ||
  die "PVE_HAOS_DISK_GB is ${disk}, and the Home Assistant OS image is a ${HAOS_IMAGE_DISK_GB} GiB disk. qm does not shrink a disk, so the machine would get ${HAOS_IMAGE_DISK_GB} GB whatever this said. Set ${HAOS_IMAGE_DISK_GB} or more."

if ((exists != 0 || needs_disk)); then
  # Everything here belongs to the build path alone. A deployment whose
  # appliance is already built is not asked which storage to use and
  # downloads nothing.
  haos_image_pin_consistent
  version=''
  haos_image_version version
  digest=''
  haos_image_digest_expected digest

  storage=''
  haos_storage_resolve storage "${PVE_HAOS_STORAGE:-}"

  # Before the machine exists: an image that cannot be fetched or does
  # not match the pin leaves nothing behind to clean up. What this opens
  # is a descriptor on the verified image, which is what the unpack
  # reads; the cache path is not consulted again.
  haos_image_fetch "${version}" "${digest}" >/dev/null

  if ((exists != 0)); then
    ram=''
    cores=''
    haos_resources ram cores
    if [[ -n ${PVE_HAOS_RAM_MB:-} ]]; then
      if ! _haos_is_number "${PVE_HAOS_RAM_MB}" || ((PVE_HAOS_RAM_MB < 1)); then
        die "PVE_HAOS_RAM_MB is '${PVE_HAOS_RAM_MB}', which is not a number of megabytes."
      fi
      ram=${PVE_HAOS_RAM_MB}
    fi
    if [[ -n ${PVE_HAOS_CORES:-} ]]; then
      if ! _haos_is_number "${PVE_HAOS_CORES}" || ((PVE_HAOS_CORES < 1)); then
        die "PVE_HAOS_CORES is '${PVE_HAOS_CORES}', which is not a number of cores."
      fi
      cores=${PVE_HAOS_CORES}
    fi

    vm_state=unchanged
    state_of vm_state haos_vm_create "${vmid}" "${hostname}" \
      "${ram}" "${cores}" "${PVE_BRIDGE_NAME}"
    if [[ ${vm_state} == changed ]]; then
      log_info "created virtual machine ${vmid} (${hostname}) with ${ram} MB and ${cores} core(s), tagged ${HAOS_OWNER_TAG}"
    fi
  fi

  attach_state=unchanged
  state_of attach_state haos_vm_disk_attach_converge "${vmid}" "${storage}"
  if [[ ${attach_state} == changed ]]; then
    log_info "gave virtual machine ${vmid} a Home Assistant OS ${version} root disk on ${storage}"
  fi
  haos_image_close
fi

# Three steps rather than one, each on its own reading of the machine.
# Only for a machine carrying the mark: an adopted machine is converged
# from the run after the one that tagged it, which is the run an operator
# has already been told about.
if ((owned)); then
  firmware_state=unchanged
  state_of firmware_state haos_vm_firmware_converge "${vmid}" \
    "${PVE_HAOS_STORAGE:-}"
  if [[ ${firmware_state} == changed ]]; then
    log_info "gave virtual machine ${vmid} its EFI disk and the appliance's boot wiring"
  fi

  size_state=unchanged
  state_of size_state haos_vm_disk_size_converge "${vmid}" "${disk}"
  if [[ ${size_state} == changed ]]; then
    log_info "grew the root disk of virtual machine ${vmid} to ${disk} GB"
  fi
fi

# The mark the next run's adoption check looks for. A machine this stage
# built carries it from the `qm create` that made it, so there is nothing
# to do here unless the machine is being adopted or somebody has edited
# its tags.
tag_state=unchanged
state_of tag_state haos_vm_tag_converge "${vmid}"
if [[ ${tag_state} == changed ]]; then
  log_info "tagged virtual machine ${vmid} with ${HAOS_OWNER_TAG}"
fi

start_state=unchanged
state_of start_state haos_vm_start "${vmid}"
if [[ ${start_state} == changed ]]; then
  log_info "started virtual machine ${vmid}"
fi

log_info "the Home Assistant OS appliance is virtual machine ${vmid} (${hostname})"
