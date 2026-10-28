#!/usr/bin/env bats
# Every @test runs in its own subshell, so the exports these tests use to
# vary the configuration cannot leak into one another; shellcheck's
# subshell-scope warnings describe a hazard that does not exist here.
# shellcheck disable=SC2030,SC2031
# SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
# SPDX-License-Identifier: Apache-2.0

load helpers/test_helper
load helpers/stage_asserts

# The tag the stage puts on the machine it owns.
OWNER_TAG='pve-config-haos'

# The release the library pins, which is also what the curl mock says
# upstream currently calls stable.
VERSION='18.4'

setup() {
  load_libs
  isolate_env
  use_mocks
  isolate_system
  seed_image
  stage_config
  seed_secrets_file
  allow_mock_env
}

# The stage fetches and unpacks the image with nothing of this process's
# environment but an explicit list of names, so the mocks' own knobs have
# to be on that list to reach the mock the way a real curl's PATH and
# proxy settings reach it.
#
# Everything here is a name the suite added. Nothing from the toolkit's
# own configuration is on it, which is what the exhaustiveness test below
# relies on.
allow_mock_env() {
  export HAOS_ENV_KEEP="PATH HOME TMPDIR LANG LC_ALL TERM \
PVE_CONFIG_MOCK_LOG PVE_CONFIG_MOCK_ENV_LOG PVE_CONFIG_MOCK_STATE \
PVE_CONFIG_MOCK_HAOS_IMAGE_FILE PVE_CONFIG_MOCK_CURL_FAIL_URL"
}

stage_config() {
  export PVE_HOSTNAME='pve1'
  export PVE_DOMAIN='example.net'
  export PVE_FQDN='pve1.example.net'
  export PVE_HAOS_ENABLED='yes'
  export PVE_HAOS_HOSTNAME='haos'
  export PVE_TAILSCALE_ENABLED='no'
  export PVE_ACME_ENABLED='no'
  # One storage that takes disk images, which is the node that has no
  # question to ask.
  export PVE_CONFIG_MOCK_PVESM_IMAGES='local-lvm'
}

# The bytes the curl mock serves as the published image, and the digest
# the stage is told to expect.
#
# A real xz archive rather than a canned string: the stage unpacks what it
# verified and imports the result, so a fixture that was not one would
# make a successful build look like a failed one. The digest asserted here
# is a digest of the bytes that actually travelled rather than a constant
# both sides agree to.
seed_image() {
  command -v xz >/dev/null 2>&1 ||
    skip 'xz is needed to build an image fixture the stage can unpack'
  IMAGE_SOURCE="${BATS_TEST_TMPDIR}/haos_ova-${VERSION}.qcow2.xz"
  printf 'pve-config test fixture: Home Assistant OS %s disk image\n' \
    "${VERSION}" | xz -0 >"${IMAGE_SOURCE}"
  export IMAGE_SOURCE
  export PVE_CONFIG_MOCK_HAOS_IMAGE_FILE="${IMAGE_SOURCE}"
  export IMAGE_SHA256
  IMAGE_SHA256=$(sha256sum <"${IMAGE_SOURCE}" | cut -d' ' -f1)
  export PVE_HAOS_IMAGE_SHA256="${IMAGE_SHA256}"
  # The release and the digest are a pair, and the fixture's bytes are not
  # the published release's, so the suite pins both -- at the version the
  # library pins, which keeps the URL the one the stage would really ask
  # for.
  export PVE_HAOS_VERSION="${VERSION}"
}

seed_secrets_file() {
  SECRETS="${PVE_CONFIG_DIR}/secrets.env"
  printf "PVE_TAILSCALE_AUTHKEY='%s'\nPVE_DNSMADEEASY_KEY='%s'\n" \
    'tskey-auth-k9f2a7cQ11CNTRL-3bXe' 'me-key-4f2a9c' >"${SECRETS}"
  chmod 600 "${SECRETS}"
}

run_haos() {
  run_phase2_stage 40-haos.sh
}

vm_conf() {
  printf '%s\n' "${PVE_CONFIG_ROOT}/etc/pve/qemu-server/${1:-200}.conf"
}

# A machine configuration that looks like one an earlier run left: built,
# given its disks, and tagged.
# The lines are the ones qemu-server writes rather than the ones the
# stage asks for: settings in alphabetical order and the allocated size
# recorded on the disk. A fixture shaped the way the stage's own
# arguments are shaped would be a machine no node ever produced.
seed_vm() {
  local id=$1 name=${2:-haos} tags=${3-${OWNER_TAG}} size=${4:-32G}
  mkdir -p "$(dirname -- "$(vm_conf "${id}")")"
  {
    printf 'agent: enabled=1\n'
    printf 'boot: order=scsi0\n'
    printf 'name: %s\n' "${name}"
    printf 'memory: 4096\n'
    printf 'cores: 2\n'
    printf 'ostype: l26\n'
    printf 'efidisk0: local-lvm:vm-%s-disk-1,efitype=4m,size=528K\n' "${id}"
    printf 'scsi0: local-lvm:vm-%s-disk-0,discard=on,size=%s,ssd=1\n' \
      "${id}" "${size}"
    printf 'serial0: socket\n'
    if [ -n "${tags}" ]; then printf 'tags: %s\n' "${tags}"; fi
  } >"$(vm_conf "${id}")"
}

# A machine a `qm create` brought into existence and nothing else: what an
# interrupted build leaves on the node.
seed_half_built_vm() {
  local id=$1
  mkdir -p "$(dirname -- "$(vm_conf "${id}")")"
  {
    printf 'bios: ovmf\n'
    printf 'cores: 2\n'
    printf 'machine: q35\n'
    printf 'memory: 4096\n'
    printf 'name: haos\n'
    printf 'net0: virtio,bridge=vmbr0\n'
    printf 'ostype: l26\n'
    printf 'scsihw: virtio-scsi-pci\n'
    printf 'tags: %s\n' "${OWNER_TAG}"
  } >"$(vm_conf "${id}")"
}

# Where the stage keeps the image it verified.
cached_image() {
  printf '%s\n' \
    "${PVE_CONFIG_ROOT}/var/lib/vz/template/cache/haos_ova-${1:-${VERSION}}.qcow2.xz"
}

@test "40-haos builds the appliance unattended and starts it" {
  run run_haos
  [ "$status" -eq 0 ]

  [ -f "$(vm_conf 200)" ]
  grep -qxF 'name: haos' "$(vm_conf 200)"
  grep -qxF 'bios: ovmf' "$(vm_conf 200)"
  run grep -F 'qm start 200' <(mock_calls)
  [ "$status" -eq 0 ]
}

@test "the appliance lands on id 200 by convention" {
  run run_haos
  [ "$status" -eq 0 ]
  [[ "${output}" == *'virtual machine 200'* ]]
  [ -f "$(vm_conf 200)" ]
}

@test "a taken 200 moves the appliance to the next free id" {
  # A container already holds 200, and guest ids are unique across both
  # guest types, so the appliance cannot have it.
  mkdir -p "${PVE_CONFIG_ROOT}/etc/pve/lxc"
  printf 'hostname: something-else\nostype: debian\n' \
    >"${PVE_CONFIG_ROOT}/etc/pve/lxc/200.conf"
  export PVE_CONFIG_MOCK_NEXTID=314

  run run_haos
  [ "$status" -eq 0 ]
  [ -f "$(vm_conf 314)" ]
  run test -f "$(vm_conf 200)"
  [ "$status" -ne 0 ]
}

@test "an image whose digest is not the pinned one is refused" {
  # The host that answers is not the host that published: the bytes are
  # intact xz, and they are not the image this toolkit verified.
  printf 'a different image entirely\n' | xz -0 >"${IMAGE_SOURCE}" 2>/dev/null ||
    printf 'a different image entirely\n' >"${IMAGE_SOURCE}"

  run run_haos
  [ "$status" -ne 0 ]
  [[ "${output}" == *'Refusing to install it'* ]]
  run test -f "$(vm_conf 200)"
  [ "$status" -ne 0 ]
}

@test "a release pinned without its digest stops the stage" {
  # The two describe one image. A release on its own would be fetched and
  # then checked against the digest of another, and the operator would
  # read an error about a digest rather than about the pair.
  export PVE_HAOS_VERSION='18.3'
  unset PVE_HAOS_IMAGE_SHA256

  run run_haos
  [ "$status" -ne 0 ]
  [[ "${output}" == *'PVE_HAOS_IMAGE_SHA256'* ]]
  [[ "${output}" == *'PVE_HAOS_VERSION'* ]]
  run grep -F 'curl' <(mock_calls)
  [ "$status" -ne 0 ]
}

@test "a digest pinned without its release stops the stage" {
  export PVE_HAOS_IMAGE_SHA256="${IMAGE_SHA256}"
  unset PVE_HAOS_VERSION

  run run_haos
  [ "$status" -ne 0 ]
  [[ "${output}" == *'PVE_HAOS_VERSION'* ]]
  run grep -F 'curl' <(mock_calls)
  [ "$status" -ne 0 ]
}

@test "a cached image that is not the pinned one is replaced rather than used" {
  local cached
  cached=$(cached_image)
  mkdir -p "$(dirname -- "${cached}")"
  printf 'left here by something else\n' >"${cached}"

  run run_haos
  [ "$status" -eq 0 ]
  [ "$(sha256sum <"${cached}" | cut -d' ' -f1)" = "${IMAGE_SHA256}" ]
}

@test "a symlinked cache entry is refused rather than verified through" {
  local cached
  cached=$(cached_image)
  mkdir -p "$(dirname -- "${cached}")"
  ln -s "${IMAGE_SOURCE}" "${cached}"

  run run_haos
  [ "$status" -ne 0 ]
  [[ "${output}" == *'symlink'* ]]
}

@test "PVE_HAOS_ENABLED not yes leaves the node alone" {
  export PVE_HAOS_ENABLED='no'

  run run_haos
  [ "$status" -eq 0 ]
  [[ "${output}" == *'not building a Home Assistant OS virtual machine'* ]]
  run test -f "$(vm_conf 200)"
  [ "$status" -ne 0 ]
}

@test "a dry run builds nothing, downloads nothing and starts nothing" {
  export PVE_CONFIG_DRY_RUN=1

  run run_haos
  [ "$status" -eq 0 ]
  run test -f "$(vm_conf 200)"
  [ "$status" -ne 0 ]
  run test -e "$(cached_image)"
  [ "$status" -ne 0 ]
  assert_no_mutating_calls
}

@test "a dry run against an existing appliance mutates nothing either" {
  seed_vm 200
  export PVE_CONFIG_DRY_RUN=1

  run run_haos
  [ "$status" -eq 0 ]
  assert_no_mutating_calls
}

@test "the stage converges: a second run changes nothing" {
  assert_stage_converges_with run_phase2_stage 40-haos.sh
}

@test "a second run adopts the tagged machine rather than building another" {
  run run_haos
  [ "$status" -eq 0 ]

  : >"${PVE_CONFIG_MOCK_LOG}"
  run run_haos
  [ "$status" -eq 0 ]
  [[ "${output}" == *'already here'* ]]
  run grep -F 'qm create' <(mock_calls)
  [ "$status" -ne 0 ]
  run grep -F 'qm create' <(mock_calls)
  [ "$status" -ne 0 ]
}

@test "a machine this toolkit did not build is refused" {
  seed_vm 200 haos ''
  export PVE_HAOS_VMID=200

  run run_haos
  [ "$status" -ne 0 ]
  [[ "${output}" == *'did not build'* ]]
  run grep -F 'qm set 200' <(mock_calls)
  [ "$status" -ne 0 ]
}

@test "adoption takes the machine over, and says so" {
  seed_vm 200 haos ''
  export PVE_HAOS_VMID=200
  export PVE_HAOS_ADOPT_EXISTING='yes'

  run run_haos
  [ "$status" -eq 0 ]
  [[ "${output}" == *'adopting pre-existing virtual machine 200'* ]]
  grep -qxF "tags: ${OWNER_TAG}" "$(vm_conf 200)"
}

@test "adoption without a pinned id is refused" {
  # The escape hatch is only ever aimed by hand: without an id it would
  # take over whatever happened to be at the default.
  seed_vm 200 haos ''
  export PVE_HAOS_ADOPT_EXISTING='yes'

  run run_haos
  [ "$status" -ne 0 ]
  run grep -F 'qm set 200' <(mock_calls)
  [ "$status" -ne 0 ]
}

@test "PVE_HAOS_ADOPT_EXISTING that is neither yes nor no stops the stage" {
  export PVE_HAOS_VMID=200
  export PVE_HAOS_ADOPT_EXISTING='true'

  run run_haos
  [ "$status" -ne 0 ]
  [[ "${output}" == *'neither yes nor no'* ]]
}

@test "a cluster listing that cannot be read stops the stage" {
  export PVE_CONFIG_MOCK_CLUSTER_FAIL=1

  run run_haos
  [ "$status" -ne 0 ]
  [[ "${output}" == *'cannot tell whether a Home Assistant OS machine'* ]]
  run test -f "$(vm_conf 200)"
  [ "$status" -ne 0 ]
}

@test "a cluster listing that will not decode stops the stage" {
  export PVE_CONFIG_MOCK_CLUSTER_JSON='[{"type":"qemu","vmid":'

  run run_haos
  [ "$status" -ne 0 ]
  run test -f "$(vm_conf 200)"
  [ "$status" -ne 0 ]
}

@test "an appliance already built on another node is not duplicated" {
  export PVE_CONFIG_MOCK_CLUSTER_REMOTE='250:pve2'
  export PVE_CONFIG_MOCK_CLUSTER_REMOTE_TYPE='qemu'
  export PVE_CONFIG_MOCK_CLUSTER_REMOTE_TAG="${OWNER_TAG}"

  run run_haos
  [ "$status" -ne 0 ]
  [[ "${output}" == *'on node pve2'* ]]
  run test -f "$(vm_conf 200)"
  [ "$status" -ne 0 ]
}

@test "two machines carrying the mark stop the stage" {
  seed_vm 200
  seed_vm 201

  run run_haos
  [ "$status" -ne 0 ]
  [[ "${output}" == *'More than one virtual machine'* ]]
}

@test "a configured id another guest already holds is refused" {
  export PVE_CONFIG_MOCK_CLUSTER_VMS='321:pve1'
  export PVE_HAOS_VMID=321

  run run_haos
  [ "$status" -ne 0 ]
  [[ "${output}" == *'already taken in this cluster'* ]]
  run grep -F 'qm create' <(mock_calls)
  [ "$status" -ne 0 ]
}

@test "resources are scaled to the host" {
  export PVE_CONFIG_MEMINFO="${BATS_TEST_TMPDIR}/meminfo"
  printf 'MemTotal:       33554432 kB\n' >"${PVE_CONFIG_MEMINFO}"
  export PVE_CONFIG_MOCK_NPROC=8

  run run_haos
  [ "$status" -eq 0 ]
  # 32768 MB / 8 is 4096, inside the 2048..8192 band; 8 cores / 4 is 2,
  # inside the 2..4 band.
  grep -qxF 'memory: 4096' "$(vm_conf 200)"
  grep -qxF 'cores: 2' "$(vm_conf 200)"
}

@test "a small host still gets the floor rather than something unbootable" {
  export PVE_CONFIG_MEMINFO="${BATS_TEST_TMPDIR}/meminfo"
  printf 'MemTotal:        8388608 kB\n' >"${PVE_CONFIG_MEMINFO}"
  export PVE_CONFIG_MOCK_NPROC=2

  run run_haos
  [ "$status" -eq 0 ]
  # 8192 MB / 8 is 1024, which Home Assistant cannot usefully run in.
  grep -qxF 'memory: 2048' "$(vm_conf 200)"
  grep -qxF 'cores: 2' "$(vm_conf 200)"
}

@test "a very large host is capped rather than given a share of everything" {
  export PVE_CONFIG_MEMINFO="${BATS_TEST_TMPDIR}/meminfo"
  printf 'MemTotal:      536870912 kB\n' >"${PVE_CONFIG_MEMINFO}"
  export PVE_CONFIG_MOCK_NPROC=64

  run run_haos
  [ "$status" -eq 0 ]
  grep -qxF 'memory: 8192' "$(vm_conf 200)"
  grep -qxF 'cores: 4' "$(vm_conf 200)"
}

@test "configured resources override the scaling" {
  export PVE_HAOS_RAM_MB=6144
  export PVE_HAOS_CORES=3
  export PVE_HAOS_DISK_GB=64

  run run_haos
  [ "$status" -eq 0 ]
  grep -qxF 'memory: 6144' "$(vm_conf 200)"
  grep -qxF 'cores: 3' "$(vm_conf 200)"
  run grep -F 'qm resize 200 scsi0 64G' <(mock_calls)
  [ "$status" -eq 0 ]
}

@test "a disk smaller than the image is refused rather than silently ignored" {
  # qm does not shrink a disk, so the machine would get 32 GB whatever
  # was asked for.
  export PVE_HAOS_DISK_GB=16

  run run_haos
  [ "$status" -ne 0 ]
  [[ "${output}" == *'does not shrink a disk'* ]]
  run grep -F 'qm create' <(mock_calls)
  [ "$status" -ne 0 ]
}

@test "a node with several image storages is asked rather than guessed at" {
  export PVE_CONFIG_MOCK_PVESM_IMAGES='local-lvm tank'

  run run_haos
  [ "$status" -ne 0 ]
  [[ "${output}" == *'more than one storage'* ]]
  run grep -F 'qm create' <(mock_calls)
  [ "$status" -ne 0 ]
}

@test "a configured storage the node does not have is refused" {
  export PVE_HAOS_STORAGE='nowhere'

  run run_haos
  [ "$status" -ne 0 ]
  [[ "${output}" == *'not a storage on this node'* ]]
}

@test "a node with no image storage is told so" {
  export PVE_CONFIG_MOCK_PVESM_IMAGES=''

  run run_haos
  [ "$status" -ne 0 ]
  [[ "${output}" == *'nowhere to put'* ]]
}

@test "an existing machine is started when it is stopped" {
  seed_vm 200

  run run_haos
  [ "$status" -eq 0 ]
  run grep -F 'qm start 200' <(mock_calls)
  [ "$status" -eq 0 ]
}

@test "a status qm cannot answer stops the stage rather than starting blind" {
  seed_vm 200
  export PVE_CONFIG_MOCK_QM_STATUS_FAIL=200

  run run_haos
  [ "$status" -ne 0 ]
  run grep -F 'qm start 200' <(mock_calls)
  [ "$status" -ne 0 ]
}

@test "a machine that is neither running nor stopped is not started" {
  seed_vm 200
  # Paused, suspended or migrating: `qm start` is the wrong verb and the
  # stage has no business guessing which.
  export PVE_CONFIG_MOCK_QM_STATUS_SAYS='paused'

  run run_haos
  [ "$status" -ne 0 ]
  run grep -F 'qm start 200' <(mock_calls)
  [ "$status" -ne 0 ]
}

@test "a hostname that is not a machine name stops the stage" {
  export PVE_HAOS_HOSTNAME='haos; rm -rf /'

  run run_haos
  [ "$status" -ne 0 ]
  [[ "${output}" == *'not a machine name'* ]]
  run grep -F 'qm create' <(mock_calls)
  [ "$status" -ne 0 ]
}

@test "a configured size that is not a number stops the stage" {
  # It would otherwise reach an arithmetic context, where bash evaluates
  # an array subscript and an attacker-chosen string becomes code.
  # shellcheck disable=SC2016  # the command substitution is the payload
  export PVE_HAOS_DISK_GB='32[$(id>&2)]'

  run run_haos
  [ "$status" -ne 0 ]
  run grep -F 'uid=' <(mock_calls)
  [ "$status" -ne 0 ]
}

@test "configured resources that differ from an existing machine are reported, not applied" {
  run run_haos
  [ "$status" -eq 0 ]

  export PVE_HAOS_RAM_MB=6144
  : >"${PVE_CONFIG_MOCK_LOG}"
  run run_haos
  [ "$status" -eq 0 ]
  [[ "${output}" == *'reboot the appliance'* ]]
  run grep -F 'qm set 200 -memory' <(mock_calls)
  [ "$status" -ne 0 ]
}

@test "the machine is created with the appliance's wiring, not a default shell" {
  run run_haos
  [ "$status" -eq 0 ]

  # The recipe ported from the pinned vm/haos-vm.sh. HAOS boots UEFI, off
  # a virtio-scsi disk, on a q35 machine; a machine missing any of these
  # comes up to a firmware prompt and no automation.
  local conf
  conf=$(vm_conf 200)
  grep -qxF 'machine: q35' "${conf}"
  grep -qxF 'bios: ovmf' "${conf}"
  grep -qxF 'ostype: l26' "${conf}"
  grep -qxF 'scsihw: virtio-scsi-pci' "${conf}"
  grep -qxF 'onboot: 1' "${conf}"
  grep -qxF 'tablet: 0' "${conf}"
  grep -qxF 'localtime: 1' "${conf}"
  grep -qxF 'net0: virtio,bridge=vmbr0' "${conf}"
  # qemu-server writes back what it allocated for the EFI disk, so the
  # recipe is read from what the stage asked qm for as well as from what
  # the machine ended up with.
  grep -qxF 'efidisk0: local-lvm:vm-200-disk-1,efitype=4m,size=528K' "${conf}"
  run grep -F -- '--efidisk0 local-lvm:0,efitype=4m' <(mock_calls)
  [ "$status" -eq 0 ]
  grep -qxF 'scsi0: local-lvm:vm-200-disk-0,discard=on,size=32G,ssd=1' "${conf}"
  grep -qxF 'boot: order=scsi0' "${conf}"
  grep -qxF 'serial0: socket' "${conf}"
  # qemu-server stores the agent setting in either spelling, and the
  # create asks for it the way upstream does.
  grep -qE '^agent: (enabled=)?1$' "${conf}"
}

@test "the mark goes on in the create, before the machine can be started" {
  run run_haos
  [ "$status" -eq 0 ]

  # The create carries the tag itself. A `qm set -tags` afterwards would
  # leave a window in which an interrupted run had built a machine that
  # the next run reads as somebody else's.
  run grep -F "qm create 200" <(mock_calls)
  [ "$status" -eq 0 ]
  [[ "${output}" == *"-tags ${OWNER_TAG}"* ]]
  grep -qxF "tags: ${OWNER_TAG}" "$(vm_conf 200)"

  # And it is on the machine before anything starts it.
  local created started
  created=$(grep -n '^qm create 200' "${PVE_CONFIG_MOCK_LOG}" | head -n 1 | cut -d: -f1)
  started=$(grep -n '^qm start 200' "${PVE_CONFIG_MOCK_LOG}" | head -n 1 | cut -d: -f1)
  [ -n "${created}" ]
  [ -n "${started}" ]
  [ "${created}" -lt "${started}" ]
}

@test "a run interrupted after the create finishes that machine rather than building another" {
  # The reviewer's scenario: the create landed, the import did not, and
  # the machine is sitting there tagged and diskless.
  seed_half_built_vm 200

  run run_haos
  [ "$status" -eq 0 ]
  [[ "${output}" == *'has no root disk'* ]]

  # No second machine anywhere, and the one that was there now boots.
  run test -e "$(vm_conf 201)"
  [ "$status" -ne 0 ]
  run grep -F 'qm create' <(mock_calls)
  [ "$status" -ne 0 ]
  grep -qxF 'scsi0: local-lvm:vm-200-disk-0,discard=on,size=32G,ssd=1' \
    "$(vm_conf 200)"
  run grep -F 'qm start 200' <(mock_calls)
  [ "$status" -eq 0 ]
}

@test "a diskless machine this toolkit did not build is left alone" {
  seed_half_built_vm 200
  sed -i "/^tags: /d" "$(vm_conf 200)"
  export PVE_HAOS_VMID=200
  export PVE_HAOS_ADOPT_EXISTING='yes'

  run run_haos
  [ "$status" -eq 0 ]
  [[ "${output}" == *'will not give it one'* ]]
  run grep -F 'qm disk import' <(mock_calls)
  [ "$status" -ne 0 ]
}

@test "a disk an earlier run imported is attached rather than imported again" {
  seed_half_built_vm 200
  printf 'unused0: local-lvm:vm-200-disk-0\n' >>"$(vm_conf 200)"

  run run_haos
  [ "$status" -eq 0 ]
  run grep -F 'qm disk import' <(mock_calls)
  [ "$status" -ne 0 ]
  grep -qxF 'scsi0: local-lvm:vm-200-disk-0,discard=on,size=32G,ssd=1' \
    "$(vm_conf 200)"
  # And the volume stops being an unused one, so a third run finds
  # nothing to attach.
  run grep -c '^unused' "$(vm_conf 200)"
  [ "$status" -ne 0 ]
}

@test "an import qm does not describe is taken from the configuration it wrote" {
  # qm's report is the first source and the unused entry the second,
  # because the report has changed wording between releases.
  export PVE_CONFIG_MOCK_QM_IMPORT_QUIET=1

  run run_haos
  [ "$status" -eq 0 ]
  grep -qxF 'scsi0: local-lvm:vm-200-disk-0,discard=on,size=32G,ssd=1' \
    "$(vm_conf 200)"
}

@test "an import that fails leaves a machine with no disk and stops the stage" {
  export PVE_CONFIG_MOCK_QM_IMPORT_FAIL=1

  run run_haos
  [ "$status" -ne 0 ]
  [[ "${output}" == *'Unable to import'* ]]
  run grep -F 'qm start 200' <(mock_calls)
  [ "$status" -ne 0 ]
}

@test "an image that is verified but will not unpack never reaches a boot" {
  # The digest is of these bytes, so the fetch is satisfied and the
  # archive is still not one. A truncated or corrupted cache entry looks
  # exactly like this.
  printf 'not an xz archive at all\n' >"${IMAGE_SOURCE}"
  IMAGE_SHA256=$(sha256sum <"${IMAGE_SOURCE}" | cut -d' ' -f1)
  export PVE_HAOS_IMAGE_SHA256="${IMAGE_SHA256}"

  run run_haos
  [ "$status" -ne 0 ]
  [[ "${output}" == *'Unable to unpack'* ]]
  run grep -F 'qm disk import' <(mock_calls)
  [ "$status" -ne 0 ]
  run grep -F 'qm start 200' <(mock_calls)
  [ "$status" -ne 0 ]
}

@test "a cache entry that disappears before the build stops the stage" {
  # Nothing downstream opens the image without the fetch having verified
  # it; an image that is gone by then is not substituted for.
  run run_haos
  [ "$status" -eq 0 ]

  rm -f -- "$(vm_conf 200)"
  rm -f -- "$(cached_image)"
  export PVE_CONFIG_MOCK_CURL_FAIL_URL='haos_ova'

  run run_haos
  [ "$status" -ne 0 ]
  [[ "${output}" == *'Unable to fetch'* ]]
  run test -f "$(vm_conf 200)"
  [ "$status" -ne 0 ]
}

@test "the verified image is reused rather than fetched again" {
  run run_haos
  [ "$status" -eq 0 ]
  [ "$(sha256sum <"$(cached_image)" | cut -d' ' -f1)" = "${IMAGE_SHA256}" ]

  rm -f -- "$(vm_conf 200)"
  : >"${PVE_CONFIG_MOCK_LOG}"
  run run_haos
  [ "$status" -eq 0 ]
  run grep -F 'curl' <(mock_calls)
  [ "$status" -ne 0 ]
}

@test "nothing of this process's environment but the allowlist reaches a download" {
  export PVE_CONFIG_MOCK_ENV_LOG="${BATS_TEST_TMPDIR}/child-env"
  : >"${PVE_CONFIG_MOCK_ENV_LOG}"
  # A credential the driver exported, one the schema has never heard of,
  # and an ordinary configuration value. None of them is a name a child
  # fetching an image has any business seeing.
  export PVE_TAILSCALE_AUTHKEY='tskey-auth-k9f2a7cQ11CNTRL-3bXe'
  export GH_TOKEN='ghp_01234567890123456789012345678901'
  export AWS_SECRET_ACCESS_KEY='wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY'

  run run_haos
  [ "$status" -eq 0 ]

  # Exhaustive rather than a list of names that should be absent: every
  # name the download was given has to be one the allowlist names. A test
  # that only checked for the secrets it knows about would pass on a
  # stage that handed over everything else.
  local names name
  names=$(awk '
    /^#mock / { want = ($2 == "curl"); next }
    want && /^[A-Za-z_][A-Za-z0-9_]*=/ { sub(/=.*/, ""); print }
  ' "${PVE_CONFIG_MOCK_ENV_LOG}" | sort -u)
  [ -n "${names}" ]
  while IFS= read -r name; do
    [ -n "${name}" ] || continue
    # `_`, PWD and SHLVL are what a shell sets for itself on startup,
    # not names it was handed: `env -i sh -c env` prints them too.
    case "${name}" in
      _ | PWD | SHLVL) continue ;;
    esac
    # shellcheck disable=SC2076  # a literal match on a padded list
    [[ " ${HAOS_ENV_KEEP} " == *" ${name} "* ]] || {
      printf 'the download inherited %s, which is not on HAOS_ENV_KEEP\n' "${name}" >&2
      return 1
    }
  done <<<"${names}"
}

@test "a machine whose configuration cannot be read stops the stage" {
  # A path where qemu-server keeps a configuration that is not a
  # configuration: the question "does this machine exist" has no answer,
  # and an answer of "no" would build a second appliance over the top.
  mkdir -p "$(dirname -- "$(vm_conf 200)")"
  ln -s /nonexistent/elsewhere.conf "$(vm_conf 200)"

  run run_haos
  [ "$status" -ne 0 ]
  [[ "${output}" == *'cannot account for'* ]]
  run grep -F 'qm create' <(mock_calls)
  [ "$status" -ne 0 ]
}

@test "tags that cannot be read are never replaced with this toolkit's own" {
  # Adoption reaches the tag convergence, and a read that failed must not
  # become an empty tag list: the `qm set -tags` that followed would
  # delete whatever the machine actually carried.
  seed_vm 200 haos ''
  export PVE_HAOS_VMID=200
  export PVE_HAOS_ADOPT_EXISTING='yes'
  # Readable for the existence probe, unreadable for the tags: the file
  # becomes a directory between them.
  export PVE_CONFIG_MOCK_QM_STATUS_SAYS='stopped'
  rm -f -- "$(vm_conf 200)"
  mkdir -p "$(vm_conf 200)"

  run run_haos
  [ "$status" -ne 0 ]
  run grep -F 'qm set 200 -tags' <(mock_calls)
  [ "$status" -ne 0 ]
}

@test "a guest id long enough to overflow bash arithmetic is refused" {
  # 2**64 + 100, which compares as 100 after wrapping and would get past
  # a bare floor check.
  export PVE_HAOS_VMID='18446744073709551716'

  run run_haos
  [ "$status" -ne 0 ]
  [[ "${output}" == *'not a guest id'* ]]
  run grep -F 'qm create' <(mock_calls)
  [ "$status" -ne 0 ]
}

@test "a disk size long enough to overflow bash arithmetic is refused" {
  # 2**64, which compares as 0 and would be under the floor if it were
  # ever evaluated.
  export PVE_HAOS_DISK_GB='18446744073709551616'

  run run_haos
  [ "$status" -ne 0 ]
  [[ "${output}" == *'not a number of gigabytes'* ]]
  run grep -F 'qm create' <(mock_calls)
  [ "$status" -ne 0 ]
}

# --- the image that boots is the image that was verified -------------------

# The digest of what an archive unpacks to, which is what reaches qm.
unpacked_sha256() {
  xz -dc -- "$1" | sha256sum | cut -d' ' -f1
}

# What the qm mock recorded about the bytes it was handed.
imported_sha256() {
  cat "${PVE_CONFIG_MOCK_STATE}/imported-sha256" 2>/dev/null
}

@test "an image replaced between the check and the unpack never reaches the disk" {
  # The window the verification has to survive: the cache entry is
  # replaced while the stage is between verifying it and unpacking it.
  # Checking a pathname and opening that pathname again would import
  # these bytes; holding the checked object open imports the other ones.
  local evil="${BATS_TEST_TMPDIR}/evil.qcow2.xz"
  printf 'an entirely different disk image\n' | xz -0 >"${evil}"
  export PVE_CONFIG_MOCK_SWAP_ON='qm'
  export PVE_CONFIG_MOCK_SWAP_FILE
  PVE_CONFIG_MOCK_SWAP_FILE=$(cached_image)
  export PVE_CONFIG_MOCK_SWAP_SOURCE="${evil}"

  run run_haos
  [ "$status" -eq 0 ]

  # The swap really happened, so the assertion below is about the stage
  # rather than about a fixture that never changed.
  run cmp -s "$(cached_image)" "${IMAGE_SOURCE}"
  [ "$status" -ne 0 ]

  [ "$(imported_sha256)" = "$(unpacked_sha256 "${IMAGE_SOURCE}")" ]
  [ "$(imported_sha256)" != "$(unpacked_sha256 "${evil}")" ]
}

@test "a cache entry replaced before a second run is checked again, not trusted" {
  # The run after the swap has no descriptor from the run before. It
  # opens the name, finds bytes that are not the pin, and fetches again
  # rather than booting what it found.
  run run_haos
  [ "$status" -eq 0 ]
  printf 'an entirely different disk image\n' | xz -0 >"$(cached_image)"
  # The machine is taken away so the next run has a disk to import
  # again, which is what puts the replaced cache entry back in the path.
  rm -f "${PVE_CONFIG_MOCK_LOG}"
  rm -f "$(vm_conf 200)"

  run run_haos
  [ "$status" -eq 0 ]
  [[ "${output}" == *'Replacing it'* ]]
  [ "$(imported_sha256 | tail -n 1)" = "$(unpacked_sha256 "${IMAGE_SOURCE}")" ]
}

# --- the disk is converged a step at a time --------------------------------

@test "a machine attached to an undersized disk is grown on the next run" {
  # The reviewer's scenario: the attach worked and the resize did not, so
  # the machine is carrying the image's own 32 GiB and the deployment
  # asked for 64. Reading the attachment as proof the rest happened
  # leaves the appliance undersized for good.
  seed_vm 200 haos "${OWNER_TAG}" 32G
  export PVE_HAOS_VMID=200
  export PVE_HAOS_DISK_GB=64

  run run_haos
  [ "$status" -eq 0 ]
  run grep -F 'qm resize 200 scsi0 64G' <(mock_calls)
  [ "$status" -eq 0 ]
  grep -qxF 'scsi0: local-lvm:vm-200-disk-0,discard=on,size=64G,ssd=1' \
    "$(vm_conf 200)"
  # And nothing was built or imported to get there.
  run grep -E 'qm (create|disk import)' <(mock_calls)
  [ "$status" -ne 0 ]
}

@test "a disk already the configured size is left alone" {
  seed_vm 200 haos "${OWNER_TAG}" 64G
  export PVE_HAOS_VMID=200
  export PVE_HAOS_DISK_GB=64

  run run_haos
  [ "$status" -eq 0 ]
  run grep -F 'qm resize' <(mock_calls)
  [ "$status" -ne 0 ]
}

@test "a disk whose size cannot be read stops the stage rather than being resized" {
  # A scsi0 line with no size on it is not a size of zero and not the
  # size that was asked for: it is an answer this node does not have.
  seed_vm 200
  sed -i 's/^scsi0: .*/scsi0: local-lvm:vm-200-disk-0,discard=on,ssd=1/' \
    "$(vm_conf 200)"
  export PVE_HAOS_VMID=200

  run run_haos
  [ "$status" -ne 0 ]
  [[ "${output}" == *'whose size this node cannot see'* ]]
  run grep -F 'qm resize' <(mock_calls)
  [ "$status" -ne 0 ]
  run grep -F 'qm start' <(mock_calls)
  [ "$status" -ne 0 ]
}

@test "a machine with a disk but no EFI disk is given one" {
  seed_vm 200
  sed -i '/^efidisk0: /d' "$(vm_conf 200)"
  export PVE_HAOS_VMID=200

  run run_haos
  [ "$status" -eq 0 ]
  run grep -F -- '--efidisk0 local-lvm:0,efitype=4m' <(mock_calls)
  [ "$status" -eq 0 ]
  grep -q '^efidisk0: ' "$(vm_conf 200)"
  # The disk it already had is not imported again on the way.
  run grep -F 'qm disk import' <(mock_calls)
  [ "$status" -ne 0 ]
}

@test "a machine missing its boot order, console or agent is given them" {
  seed_vm 200
  sed -i '/^boot: /d;/^serial0: /d;/^agent: /d' "$(vm_conf 200)"
  export PVE_HAOS_VMID=200

  run run_haos
  [ "$status" -eq 0 ]
  grep -qxF 'boot: order=scsi0' "$(vm_conf 200)"
  grep -qxF 'serial0: socket' "$(vm_conf 200)"
  grep -qxF 'agent: enabled=1' "$(vm_conf 200)"
  # The EFI disk it has is not allocated a second time.
  run grep -F -- '--efidisk0' <(mock_calls)
  [ "$status" -ne 0 ]
}

@test "a machine booting from the wrong disk is pointed back at its own" {
  seed_vm 200
  sed -i 's/^boot: .*/boot: order=net0/' "$(vm_conf 200)"
  export PVE_HAOS_VMID=200

  run run_haos
  [ "$status" -eq 0 ]
  grep -qxF 'boot: order=scsi0' "$(vm_conf 200)"
}

# --- the volume that gets attached is the right one ------------------------

@test "a recovery with more than one unused disk stops rather than guessing" {
  # Two unused volumes and no way to tell which is the Home Assistant
  # import. Attaching the wrong one boots the appliance off somebody
  # else's disk, so this is an unreadable situation and it aborts.
  seed_half_built_vm 200
  {
    printf 'unused0: local-lvm:vm-200-disk-admin\n'
    printf 'unused1: local-lvm:vm-200-disk-haos\n'
  } >>"$(vm_conf 200)"

  run run_haos
  [ "$status" -ne 0 ]
  [[ "${output}" == *'cannot tell which of them'* ]]
  run grep -F -- '--scsi0' <(mock_calls)
  [ "$status" -ne 0 ]
  run grep -F 'qm disk import' <(mock_calls)
  [ "$status" -ne 0 ]
  run grep -F 'qm start' <(mock_calls)
  [ "$status" -ne 0 ]
}

@test "an unused disk past the ninth is attached by its volume, not its index" {
  # A machine that has collected disks numbers them past a single digit,
  # and unused10 is not unused1.
  seed_half_built_vm 200
  printf 'unused10: local-lvm:vm-200-disk-10\n' >>"$(vm_conf 200)"

  run run_haos
  [ "$status" -eq 0 ]
  grep -qxF 'scsi0: local-lvm:vm-200-disk-10,discard=on,size=32G,ssd=1' \
    "$(vm_conf 200)"
}

@test "the volume qm reports is read out of the report, index and all" {
  source "${REPO_ROOT}/lib/haos.sh"
  local volume=''

  # Production's own words, for a machine whose disks have run past nine.
  _haos_report_volume volume \
    "Successfully imported disk as 'unused10:local-lvm:vm-200-disk-10'"
  [ "${volume}" = 'local-lvm:vm-200-disk-10' ]

  _haos_report_volume volume \
    "Successfully imported disk as 'unused0:local-lvm:vm-200-disk-0'"
  [ "${volume}" = 'local-lvm:vm-200-disk-0' ]

  # A report that names no volume is not an answer.
  run _haos_report_volume volume 'transferred 32.0 GiB of 32.0 GiB (100.00%)'
  [ "$status" -ne 0 ]
}

@test "the imported volume is the one that appeared, not the first one listed" {
  source "${REPO_ROOT}/lib/haos.sh"
  local volume=''

  # The machine was carrying unused disks before the import. The one the
  # import made is the one that was not there before, whatever it sorts
  # as: vm-200-disk-10 sorts before vm-200-disk-9.
  _haos_new_volume volume \
    'local-lvm:vm-200-disk-9' \
    $'local-lvm:vm-200-disk-9\nlocal-lvm:vm-200-disk-10'
  [ "${volume}" = 'local-lvm:vm-200-disk-10' ]

  # Two new ones, or none, are not an answer either.
  run _haos_new_volume volume 'local-lvm:a' $'local-lvm:a\nlocal-lvm:b\nlocal-lvm:c'
  [ "$status" -ne 0 ]
  run _haos_new_volume volume 'local-lvm:a' 'local-lvm:a'
  [ "$status" -ne 0 ]
}
