#!/usr/bin/env bats
# SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
# SPDX-License-Identifier: Apache-2.0

load helpers/test_helper

setup() {
  isolate_env
  BOOTSTRAP="${REPO_ROOT}/bootstrap.sh"
  SRC="${BATS_TEST_TMPDIR}/repo-1234567"
  ARCHIVE="${BATS_TEST_TMPDIR}/source.tar.gz"
  make_source_tree
  make_archive
  make_curl_mock
}

# Builds the tree a codeload tarball contains, with its single top level
# directory.
make_source_tree() {
  mkdir -p "${SRC}/lib" "${SRC}/stages/phase1" "${SRC}/examples"
  printf '#!/usr/bin/env bash\n# driver v%s\n' "${1:-1}" >"${SRC}/pve-config.sh"
  printf '#!/usr/bin/env bash\n' >"${SRC}/bootstrap.sh"
  local lib
  for lib in common version config detect state schema; do
    printf '#!/usr/bin/env bash\n' >"${SRC}/lib/${lib}.sh"
  done
  printf '#!/usr/bin/env bash\n' >"${SRC}/stages/phase1/10-host.sh"
  printf 'PVE_DOMAIN=\x27example.net\x27\n' >"${SRC}/examples/pve-config.conf.example"
}

make_archive() {
  tar -czf "${ARCHIVE}" -C "${BATS_TEST_TMPDIR}" "$(basename "${SRC}")"
}

# Runs the installer without the privilege check, which the suite cannot
# satisfy.
run_bootstrap() {
  run env \
    PVE_CONFIG_DIR="${PVE_CONFIG_DIR}" \
    PVE_CONFIG_BOOTSTRAP_ARCHIVE="${ARCHIVE}" \
    bash -euo pipefail -c "source '${BOOTSTRAP}'; bootstrap_install"
}

seed_install() {
  mkdir -p "${PVE_CONFIG_DIR}/lib" "${PVE_CONFIG_DIR}/state"
  printf 'old driver\n' >"${PVE_CONFIG_DIR}/pve-config.sh"
  printf 'stale\n' >"${PVE_CONFIG_DIR}/lib/gone.sh"
  printf "PVE_DOMAIN='kept.example'\n" >"${PVE_CONFIG_DIR}/pve-config.conf"
  printf "PVE_SECRET='kept'\n" >"${PVE_CONFIG_DIR}/secrets.env"
  chmod 600 "${PVE_CONFIG_DIR}/secrets.env"
  printf 'completed earlier\n' >"${PVE_CONFIG_DIR}/state/phase1__10-host.done"
}

# A curl standing in for github.com. It answers a -I probe from the
# redirect fixture and an ordinary download from a file named after the
# last URL segment, which is enough to serve a release, its checksum and a
# codeload tarball without a network.
make_curl_mock() {
  SERVER="${BATS_TEST_TMPDIR}/server"
  SHIM="${BATS_TEST_TMPDIR}/shim"
  CURL_LOG="${BATS_TEST_TMPDIR}/curl.log"
  mkdir -p "${SERVER}/files" "${SHIM}"
  : >"${CURL_LOG}"
  cat >"${SHIM}/curl" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
out='' head=0 url=''
while [[ $# -gt 0 ]]; do
  case $1 in
    -o)
      out=$2
      shift 2
      ;;
    -w) shift 2 ;;
    -*I*)
      head=1
      shift
      ;;
    -*) shift ;;
    *)
      url=$1
      shift
      ;;
  esac
done
printf '%s\n' "${url}" >>"${PVE_TEST_CURL_LOG}"
if [[ ${head} == 1 ]]; then
  [[ -f ${PVE_TEST_SERVER}/redirect ]] || exit 22
  printf '%s' "$(cat "${PVE_TEST_SERVER}/redirect")"
  exit 0
fi
src="${PVE_TEST_SERVER}/files/${url##*/}"
[[ -f ${src} ]] || exit 22
[[ -z ${out} ]] || cp -- "${src}" "${out}"
EOF
  chmod +x "${SHIM}/curl"
}

# Publishes a release of the fixture tree under the name the real workflow
# uses, with the checksum in the bare-filename form the real asset carries.
publish_release() {
  local tag=$1 rel="${BATS_TEST_TMPDIR}/rel"
  rm -rf -- "${rel}"
  mkdir -p "${rel}"
  cp -a "${SRC}" "${rel}/pve-config-${tag}"
  tar -czf "${SERVER}/files/pve-config-${tag}.tar.gz" \
    -C "${rel}" "pve-config-${tag}"
  (cd "${SERVER}/files" &&
    sha256sum "pve-config-${tag}.tar.gz" >"pve-config-${tag}.tar.gz.sha256")
}

set_latest() {
  printf 'https://github.com/tykeal/homeassistant-pve-config/releases/tag/%s' \
    "$1" >"${SERVER}/redirect"
}

# Runs the installer against the fake github, with any extra settings given
# as NAME=VALUE arguments.
run_net_bootstrap() {
  run env \
    PATH="${SHIM}:${PATH}" \
    PVE_TEST_SERVER="${SERVER}" \
    PVE_TEST_CURL_LOG="${CURL_LOG}" \
    PVE_CONFIG_DIR="${PVE_CONFIG_DIR}" \
    "$@" \
    bash -euo pipefail -c "source '${BOOTSTRAP}'; bootstrap_install; bootstrap_next_steps"
}

curl_log() { cat "${CURL_LOG}"; }

@test "a ref containing a slash is percent encoded" {
  run env PVE_CONFIG_REF='feat/config-framework' \
    bash -euo pipefail -c "source '${BOOTSTRAP}'; bootstrap_archive_url"
  [ "$status" -eq 0 ]
  [[ "$output" == *'/tar.gz/feat%2Fconfig-framework' ]]
  [[ "$output" != *'feat/config-framework'* ]]
}

@test "an ordinary ref is left alone" {
  run env PVE_CONFIG_REF='main' \
    bash -euo pipefail -c "source '${BOOTSTRAP}'; bootstrap_archive_url"
  [ "$output" = 'https://codeload.github.com/tykeal/homeassistant-pve-config/tar.gz/main' ]
}

@test "a fresh install lays down the code and an empty state directory" {
  run_bootstrap
  [ "$status" -eq 0 ]
  [ -x "${PVE_CONFIG_DIR}/pve-config.sh" ]
  [ -x "${PVE_CONFIG_DIR}/bootstrap.sh" ]
  [ -f "${PVE_CONFIG_DIR}/lib/common.sh" ]
  [ -f "${PVE_CONFIG_DIR}/lib/version.sh" ]
  [ -f "${PVE_CONFIG_DIR}/lib/schema.sh" ]
  [ -x "${PVE_CONFIG_DIR}/stages/phase1/10-host.sh" ]
  [ -f "${PVE_CONFIG_DIR}/examples/pve-config.conf.example" ]
  [ -d "${PVE_CONFIG_DIR}/state" ]
  [ ! -e "${PVE_CONFIG_DIR}.bootstrap" ]
  [ ! -e "${PVE_CONFIG_DIR}.old" ]
}

@test "an upgrade keeps the config, the secrets and the state" {
  seed_install
  run_bootstrap
  [ "$status" -eq 0 ]
  [ "$(cat "${PVE_CONFIG_DIR}/pve-config.conf")" = "PVE_DOMAIN='kept.example'" ]
  [ "$(cat "${PVE_CONFIG_DIR}/secrets.env")" = "PVE_SECRET='kept'" ]
  [ -f "${PVE_CONFIG_DIR}/state/phase1__10-host.done" ]
  run stat -c '%a' "${PVE_CONFIG_DIR}/secrets.env"
  [ "$output" = '600' ]
}

@test "an upgrade replaces the code and drops a file the new tree lost" {
  seed_install
  run_bootstrap
  [ "$status" -eq 0 ]
  [[ "$(cat "${PVE_CONFIG_DIR}/pve-config.sh")" == *'driver v1'* ]]
  [ ! -e "${PVE_CONFIG_DIR}/lib/gone.sh" ]
}

@test "an archive missing a required file leaves the install untouched" {
  seed_install
  rm "${SRC}/lib/schema.sh"
  make_archive

  run_bootstrap
  [ "$status" -ne 0 ]
  [[ "$output" == *'lib/schema.sh'* ]]
  [ "$(cat "${PVE_CONFIG_DIR}/pve-config.sh")" = 'old driver' ]
  [ "$(cat "${PVE_CONFIG_DIR}/pve-config.conf")" = "PVE_DOMAIN='kept.example'" ]
  [ -f "${PVE_CONFIG_DIR}/state/phase1__10-host.done" ]
  [ ! -e "${PVE_CONFIG_DIR}.bootstrap" ]
}

@test "an archive missing lib/version.sh is refused" {
  # The driver sources it unconditionally, so a tree without it installs
  # cleanly and then cannot start.
  seed_install
  rm "${SRC}/lib/version.sh"
  make_archive

  run_bootstrap
  [ "$status" -ne 0 ]
  [[ "$output" == *'lib/version.sh'* ]]
  [ "$(cat "${PVE_CONFIG_DIR}/pve-config.sh")" = 'old driver' ]
  [ ! -e "${PVE_CONFIG_DIR}.bootstrap" ]
}

@test "a failed swap restores the previous install" {
  seed_install

  # A mv that refuses to move the staged tree into place is the only way to
  # reach the rollback path without corrupting the filesystem.
  local shim="${BATS_TEST_TMPDIR}/shim"
  mkdir -p "${shim}"
  cat >"${shim}/mv" <<EOF
#!/usr/bin/env bash
if [[ \$* == *'.bootstrap/new'* ]]; then
  exit 1
fi
exec /bin/mv "\$@"
EOF
  chmod +x "${shim}/mv"

  run env \
    PATH="${shim}:${PATH}" \
    PVE_CONFIG_DIR="${PVE_CONFIG_DIR}" \
    PVE_CONFIG_BOOTSTRAP_ARCHIVE="${ARCHIVE}" \
    bash -euo pipefail -c "source '${BOOTSTRAP}'; bootstrap_install"

  [ "$status" -ne 0 ]
  [[ "$output" == *'restored'* ]]
  [ "$(cat "${PVE_CONFIG_DIR}/pve-config.sh")" = 'old driver' ]
  [ "$(cat "${PVE_CONFIG_DIR}/pve-config.conf")" = "PVE_DOMAIN='kept.example'" ]
  [ -f "${PVE_CONFIG_DIR}/state/phase1__10-host.done" ]
}

@test "an archive with an absolute entry is refused" {
  tar -cPzf "${ARCHIVE}" "${SRC}/pve-config.sh"
  run_bootstrap
  [ "$status" -ne 0 ]
  [[ "$output" == *'escapes the extraction root'* ]]
  [ ! -e "${PVE_CONFIG_DIR}/pve-config.sh" ]
}

@test "an archive with a parent directory entry is refused" {
  (cd "${SRC}/lib" && tar -cPzf "${ARCHIVE}" ../pve-config.sh)
  run_bootstrap
  [ "$status" -ne 0 ]
  [[ "$output" == *'escapes the extraction root'* ]]
}

@test "an archive containing a symlink is refused" {
  ln -s /etc/shadow "${SRC}/lib/evil.sh"
  make_archive
  run_bootstrap
  [ "$status" -ne 0 ]
  [[ "$output" == *'link entry'* ]]
  [ ! -e "${PVE_CONFIG_DIR}/lib" ]
}

@test "the installer refuses to run as an unprivileged user" {
  run "${BOOTSTRAP}"
  [ "$status" -ne 0 ]
  [[ "$output" == *'root'* ]]
}

# Stubs mv so that only a move INTO the install directory fails, which
# exercises the real bootstrap_swap: moving the old tree aside succeeds,
# installing the new one fails, and so does putting the old one back.
swap_with_failing_install() {
  run env \
    PVE_CONFIG_DIR="${PVE_CONFIG_DIR}" \
    bash -euo pipefail -c "
      source '${BOOTSTRAP}'
      mv() {
        case \"\$*\" in
          *\" \${PVE_CONFIG_DIR}\") return 1 ;;
        esac
        command mv \"\$@\"
      }
      mkdir -p '${BATS_TEST_TMPDIR}/staging/new'
      bootstrap_swap '${BATS_TEST_TMPDIR}/staging'
    "
}

@test "a swap that fails but rolls back leaves the previous install in place" {
  printf 'old driver\n' >"${PVE_CONFIG_DIR}/pve-config.sh"

  run env \
    PVE_CONFIG_DIR="${PVE_CONFIG_DIR}" \
    bash -euo pipefail -c "
      source '${BOOTSTRAP}'
      bootstrap_swap '${BATS_TEST_TMPDIR}/missing-staging'
    "
  [ "$status" -ne 0 ]
  [[ "$output" == *'previous install was restored'* ]]
  run cat "${PVE_CONFIG_DIR}/pve-config.sh"
  [ "$output" = 'old driver' ]
}

@test "a failed swap that cannot be rolled back says so and names the backup" {
  printf 'old driver\n' >"${PVE_CONFIG_DIR}/pve-config.sh"

  swap_with_failing_install
  [ "$status" -ne 0 ]
  [[ "$output" == *'Manual recovery required'* ]]
  [[ "$output" != *'previous install was restored'* ]]
  [[ "$output" == *"${PVE_CONFIG_DIR}.old"* ]]

  # The backup is exactly where the message said it would be.
  run cat "${PVE_CONFIG_DIR}.old/pve-config.sh"
  [ "$status" -eq 0 ]
  [ "$output" = 'old driver' ]
}

@test "a fresh install that fails does not claim a rollback" {
  rm -rf "${PVE_CONFIG_DIR}"

  run env \
    PVE_CONFIG_DIR="${PVE_CONFIG_DIR}" \
    bash -euo pipefail -c "
      source '${BOOTSTRAP}'
      bootstrap_swap '${BATS_TEST_TMPDIR}/missing-staging'
    "
  [ "$status" -ne 0 ]
  [[ "$output" == *'no previous installation'* ]]
  [[ "$output" != *'restored'* ]]
  [[ "$output" != *'Manual recovery required'* ]]
  [ ! -e "${PVE_CONFIG_DIR}" ]
}

@test "bootstrap answers --help instead of installing" {
  run env PVE_CONFIG_DIR="${PVE_CONFIG_DIR}" \
    bash "${BOOTSTRAP}" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *'Usage: bootstrap.sh'* ]]
  [[ "$output" == *'PVE_CONFIG_REF'* ]]
}

@test "bootstrap rejects an unknown argument before touching anything" {
  run env PVE_CONFIG_DIR="${PVE_CONFIG_DIR}" \
    bash "${BOOTSTRAP}" --install-everything
  [ "$status" -ne 0 ]
  [[ "$output" == *'Unknown argument'* ]]
}

@test "the entry point guard survives an unset BASH_SOURCE" {
  run env PVE_CONFIG_DIR="${PVE_CONFIG_DIR}" \
    bash -c "$(cat "${BOOTSTRAP}")" bootstrap.sh --help
  [ "$status" -eq 0 ]
  [[ "$output" == *'Usage: bootstrap.sh'* ]]
  [[ "$output" != *'unbound variable'* ]]
}

@test "a leftover backup stops the install rather than being deleted" {
  mkdir -p "${PVE_CONFIG_DIR}.old"
  printf 'the only copy\n' >"${PVE_CONFIG_DIR}.old/pve-config.sh"

  run_bootstrap
  [ "$status" -ne 0 ]
  [[ "$output" == *'still exists from an earlier failed install'* ]]
  run cat "${PVE_CONFIG_DIR}.old/pve-config.sh"
  [ "$output" = 'the only copy' ]
}

@test "an upgrade carries the admin key directory across" {
  mkdir -p "${PVE_CONFIG_DIR}/keys"
  printf 'ssh-ed25519 AAAAtest admin@example.test\n' \
    >"${PVE_CONFIG_DIR}/keys/admins.pub"

  run_bootstrap
  [ "$status" -eq 0 ]
  run cat "${PVE_CONFIG_DIR}/keys/admins.pub"
  [ "$output" = 'ssh-ed25519 AAAAtest admin@example.test' ]
}

@test "a staging copy failure stops before anything is swapped" {
  printf 'old driver\n' >"${PVE_CONFIG_DIR}/pve-config.sh"
  mkdir -p "${PVE_CONFIG_DIR}/state"
  printf 'marker\n' >"${PVE_CONFIG_DIR}/state/phase1__10-host.done"

  run env \
    PVE_CONFIG_DIR="${PVE_CONFIG_DIR}" \
    PVE_CONFIG_BOOTSTRAP_ARCHIVE="${ARCHIVE}" \
    bash -euo pipefail -c "
      source '${BOOTSTRAP}'
      # Only the assembly copies fail; fetching the offline archive still
      # has to work or the test never reaches the staging step.
      cp() {
        case "\$*" in
          *'/new/'*) return 1 ;;
        esac
        command cp "\$@"
      }
      bootstrap_install
    "
  [ "$status" -ne 0 ]
  [[ "$output" == *'Unable to assemble'* ]]
  run cat "${PVE_CONFIG_DIR}/pve-config.sh"
  [ "$output" = 'old driver' ]
  [ -f "${PVE_CONFIG_DIR}/state/phase1__10-host.done" ]
}

run_next_steps() {
  run env \
    PVE_CONFIG_DIR="${PVE_CONFIG_DIR}" \
    PVE_CONFIG_BOOTSTRAP_ARCHIVE="${ARCHIVE}" \
    bash -euo pipefail -c "source '${BOOTSTRAP}'; bootstrap_install; bootstrap_next_steps"
}

@test "a fresh install suggests seeding the generated files" {
  run_next_steps
  [ "$status" -eq 0 ]
  [[ "$output" == *'cp examples/pve-config.conf.example'* ]]
  [[ "$output" == *'cp examples/secrets.env.example'* ]]
}

@test "an upgrade does not suggest overwriting what it just preserved" {
  printf "PVE_DOMAIN='kept.net'\n" >"${PVE_CONFIG_DIR}/pve-config.conf"
  printf "PVE_TOKEN='kept'\n" >"${PVE_CONFIG_DIR}/secrets.env"
  chmod 600 "${PVE_CONFIG_DIR}/secrets.env"

  run_next_steps
  [ "$status" -eq 0 ]
  [[ "$output" != *'cp examples/pve-config.conf.example'* ]]
  [[ "$output" != *'cp examples/secrets.env.example'* ]]
  run cat "${PVE_CONFIG_DIR}/pve-config.conf"
  [ "$output" = "PVE_DOMAIN='kept.net'" ]
}

@test "with no configuration the latest published release is installed" {
  publish_release v9.9.9
  set_latest v9.9.9

  run_net_bootstrap
  [ "$status" -eq 0 ]
  [[ "$output" == *'release v9.9.9'* ]]
  [[ "$output" == *'verified pve-config-v9.9.9.tar.gz'* ]]
  [ -x "${PVE_CONFIG_DIR}/pve-config.sh" ]
  [ -f "${PVE_CONFIG_DIR}/lib/schema.sh" ]
  # The published tarball nests everything under pve-config-<tag>/, which
  # the staging strip has to remove rather than install.
  [ ! -e "${PVE_CONFIG_DIR}/pve-config-v9.9.9" ]
  run curl_log
  [[ "$output" == *'/releases/latest'* ]]
  [[ "$output" == *'/releases/download/v9.9.9/pve-config-v9.9.9.tar.gz'* ]]
}

@test "a release tarball that does not match its checksum is refused" {
  publish_release v9.9.9
  set_latest v9.9.9
  seed_install
  printf 'tampered\n' | gzip >"${SERVER}/files/pve-config-v9.9.9.tar.gz"

  run_net_bootstrap
  [ "$status" -ne 0 ]
  [[ "$output" == *'Checksum verification failed'* ]]
  [ "$(cat "${PVE_CONFIG_DIR}/pve-config.sh")" = 'old driver' ]
  [ "$(cat "${PVE_CONFIG_DIR}/pve-config.conf")" = "PVE_DOMAIN='kept.example'" ]
  [ -f "${PVE_CONFIG_DIR}/state/phase1__10-host.done" ]
  [ ! -e "${PVE_CONFIG_DIR}.bootstrap" ]
  [ ! -e "${PVE_CONFIG_DIR}.old" ]
}

@test "a release with no checksum asset is refused" {
  publish_release v9.9.9
  set_latest v9.9.9
  rm "${SERVER}/files/pve-config-v9.9.9.tar.gz.sha256"
  seed_install

  run_net_bootstrap
  [ "$status" -ne 0 ]
  [[ "$output" == *'no pve-config-v9.9.9.tar.gz.sha256'* ]]
  [ "$(cat "${PVE_CONFIG_DIR}/pve-config.sh")" = 'old driver' ]
}

@test "PVE_CONFIG_RELEASE installs that release without asking for the latest" {
  publish_release v9.9.9
  publish_release v8.8.8
  set_latest v9.9.9

  run_net_bootstrap PVE_CONFIG_RELEASE=v8.8.8
  [ "$status" -eq 0 ]
  run curl_log
  [[ "$output" == *'pve-config-v8.8.8.tar.gz'* ]]
  [[ "$output" != *'/releases/latest'* ]]
}

@test "a repository with no published release says so" {
  rm -f "${SERVER}/redirect"

  run_net_bootstrap
  [ "$status" -ne 0 ]
  [[ "$output" == *'Unable to resolve the latest release'* ]]
  [ ! -e "${PVE_CONFIG_DIR}/pve-config.sh" ]
}

@test "a redirect that carries no tag is reported as no release" {
  printf 'https://github.com/tykeal/homeassistant-pve-config/releases' \
    >"${SERVER}/redirect"

  run_net_bootstrap
  [ "$status" -ne 0 ]
  [[ "$output" == *'no published release to install'* ]]
}

@test "a tag the redirect returns is refused when it is not a usable tag" {
  printf 'https://github.com/tykeal/homeassistant-pve-config/releases/tag/../../evil' \
    >"${SERVER}/redirect"

  run_net_bootstrap
  [ "$status" -ne 0 ]
  [[ "$output" == *'Refusing to use the release tag'* ]]
  run curl_log
  [[ "$output" != *'/releases/download/'* ]]
}

@test "PVE_CONFIG_SHA256 accepts an archive whose digest matches" {
  local digest
  digest=$(sha256sum "${ARCHIVE}")
  digest=${digest%% *}

  run env \
    PVE_CONFIG_DIR="${PVE_CONFIG_DIR}" \
    PVE_CONFIG_BOOTSTRAP_ARCHIVE="${ARCHIVE}" \
    PVE_CONFIG_SHA256="${digest}" \
    bash -euo pipefail -c "source '${BOOTSTRAP}'; bootstrap_install"
  [ "$status" -eq 0 ]
  [[ "$output" == *'matches PVE_CONFIG_SHA256'* ]]
  [ -x "${PVE_CONFIG_DIR}/pve-config.sh" ]
}

@test "PVE_CONFIG_SHA256 that does not match leaves the install untouched" {
  seed_install

  run env \
    PVE_CONFIG_DIR="${PVE_CONFIG_DIR}" \
    PVE_CONFIG_BOOTSTRAP_ARCHIVE="${ARCHIVE}" \
    PVE_CONFIG_SHA256="$(printf 'a%.0s' {1..64})" \
    bash -euo pipefail -c "source '${BOOTSTRAP}'; bootstrap_install"
  [ "$status" -ne 0 ]
  [[ "$output" == *'Checksum mismatch'* ]]
  [ "$(cat "${PVE_CONFIG_DIR}/pve-config.sh")" = 'old driver' ]
  [ ! -e "${PVE_CONFIG_DIR}.bootstrap" ]
}

@test "a malformed PVE_CONFIG_SHA256 stops before anything is fetched" {
  publish_release v9.9.9
  set_latest v9.9.9

  run_net_bootstrap PVE_CONFIG_SHA256='deadbeef'
  [ "$status" -ne 0 ]
  [[ "$output" == *'64 hexadecimal characters'* ]]
  [ ! -s "${CURL_LOG}" ]
}

@test "PVE_CONFIG_SHA256 is the authority over the published checksum" {
  publish_release v9.9.9
  set_latest v9.9.9

  run_net_bootstrap PVE_CONFIG_RELEASE=v9.9.9 \
    PVE_CONFIG_SHA256="$(printf 'b%.0s' {1..64})"
  [ "$status" -ne 0 ]
  [[ "$output" == *'Checksum mismatch'* ]]
  # The published checksum would have passed, so it must not have been
  # consulted at all.
  run curl_log
  [[ "$output" != *'.sha256'* ]]
}

@test "PVE_CONFIG_REF is refused without an opt-in" {
  cp "${ARCHIVE}" "${SERVER}/files/main"

  run_net_bootstrap PVE_CONFIG_REF=main
  [ "$status" -ne 0 ]
  [[ "$output" == *'PVE_CONFIG_ALLOW_UNVERIFIED=1'* ]]
  [[ "$output" == *'--allow-unverified'* ]]
  [[ "$output" == *'PVE_CONFIG_SHA256'* ]]
  [ ! -s "${CURL_LOG}" ]
  [ ! -e "${PVE_CONFIG_DIR}/pve-config.sh" ]
}

@test "PVE_CONFIG_REF with the opt-in installs and warns twice" {
  cp "${ARCHIVE}" "${SERVER}/files/main"

  run_net_bootstrap PVE_CONFIG_REF=main PVE_CONFIG_ALLOW_UNVERIFIED=1
  [ "$status" -eq 0 ]
  [ -x "${PVE_CONFIG_DIR}/pve-config.sh" ]
  [[ "$output" == *'UNVERIFIED INSTALL'* ]]
  # Once up front and once after the next steps, so a scrolled terminal
  # still shows it.
  [[ "$output" == *'WARNING: it is unverified'* ]]
}

@test "a pinned PVE_CONFIG_REF install needs no opt-in and does not warn" {
  cp "${ARCHIVE}" "${SERVER}/files/main"
  local digest
  digest=$(sha256sum "${ARCHIVE}")
  digest=${digest%% *}

  run_net_bootstrap PVE_CONFIG_REF=main PVE_CONFIG_SHA256="${digest}"
  [ "$status" -eq 0 ]
  [ -x "${PVE_CONFIG_DIR}/pve-config.sh" ]
  [[ "$output" != *'UNVERIFIED'* ]]
  [[ "$output" != *'unverified'* ]]
}

@test "PVE_CONFIG_RELEASE and PVE_CONFIG_REF together are a configuration error" {
  run_net_bootstrap PVE_CONFIG_RELEASE=v9.9.9 PVE_CONFIG_REF=main \
    PVE_CONFIG_ALLOW_UNVERIFIED=1
  [ "$status" -ne 0 ]
  [[ "$output" == *'PVE_CONFIG_RELEASE'* ]]
  [[ "$output" == *'PVE_CONFIG_REF'* ]]
  [ ! -s "${CURL_LOG}" ]
}

@test "an unusable PVE_CONFIG_RELEASE is refused before any download" {
  run_net_bootstrap PVE_CONFIG_RELEASE='v1.0.0/../../etc'
  [ "$status" -ne 0 ]
  [[ "$output" == *'not a usable tag'* ]]
  [ ! -s "${CURL_LOG}" ]
}

@test "--allow-unverified is accepted and documented" {
  run env PVE_CONFIG_DIR="${PVE_CONFIG_DIR}" bash "${BOOTSTRAP}" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *'--allow-unverified'* ]]
  [[ "$output" == *'PVE_CONFIG_RELEASE'* ]]
  [[ "$output" == *'PVE_CONFIG_SHA256'* ]]

  # The flag reaches the same gate the environment variable does, so an
  # unprivileged run gets as far as the root check rather than stopping on
  # an unknown argument.
  run env PVE_CONFIG_DIR="${PVE_CONFIG_DIR}" bash "${BOOTSTRAP}" --allow-unverified
  [ "$status" -ne 0 ]
  [[ "$output" == *'root'* ]]
  [[ "$output" != *'Unknown argument'* ]]
}

# Replaces the published checksum of a release with an arbitrary body, so a
# malformed asset can be served without touching the tarball it claims to
# cover.
forge_checksum() {
  local tag=$1
  cat >"${SERVER}/files/pve-config-${tag}.tar.gz.sha256"
}

@test "a checksum naming a different file is refused as malformed" {
  publish_release v9.9.9
  set_latest v9.9.9
  seed_install
  local digest
  digest=$(sha256sum "${SERVER}/files/pve-config-v9.9.9.tar.gz")
  forge_checksum v9.9.9 <<<"${digest%% *}  decoy.tar.gz"

  run_net_bootstrap
  [ "$status" -ne 0 ]
  [[ "$output" == *'malformed'* ]]
  [[ "$output" != *'Checksum verification failed'* ]]
  [ "$(cat "${PVE_CONFIG_DIR}/pve-config.sh")" = 'old driver' ]
  [ ! -e "${PVE_CONFIG_DIR}.bootstrap" ]
}

@test "a checksum naming an absolute path is refused as malformed" {
  publish_release v9.9.9
  set_latest v9.9.9
  seed_install
  # sha256sum -c would happily verify this record, report success, and
  # never look at the tarball at all.
  forge_checksum v9.9.9 < <(sha256sum /etc/hostname)

  run_net_bootstrap
  [ "$status" -ne 0 ]
  [[ "$output" == *'malformed'* ]]
  [ "$(cat "${PVE_CONFIG_DIR}/pve-config.sh")" = 'old driver' ]
  [ ! -e "${PVE_CONFIG_DIR}.bootstrap" ]
}

@test "a checksum holding a second record is refused as malformed" {
  publish_release v9.9.9
  set_latest v9.9.9
  seed_install
  local digest
  digest=$(sha256sum "${SERVER}/files/pve-config-v9.9.9.tar.gz")
  digest=${digest%% *}
  forge_checksum v9.9.9 <<EOF
${digest}  pve-config-v9.9.9.tar.gz
${digest}  extra.tar.gz
EOF

  run_net_bootstrap
  [ "$status" -ne 0 ]
  [[ "$output" == *'malformed'* ]]
  [[ "$output" == *'2 records'* ]]
  [ "$(cat "${PVE_CONFIG_DIR}/pve-config.sh")" = 'old driver' ]
}

@test "an empty checksum asset is refused as malformed" {
  publish_release v9.9.9
  set_latest v9.9.9
  seed_install
  : >"${SERVER}/files/pve-config-v9.9.9.tar.gz.sha256"

  run_net_bootstrap
  [ "$status" -ne 0 ]
  [[ "$output" == *'is empty'* ]]
  [[ "$output" == *'malformed'* ]]
  [ "$(cat "${PVE_CONFIG_DIR}/pve-config.sh")" = 'old driver' ]
}

@test "an empty PVE_CONFIG_SHA256 is refused on a release install" {
  publish_release v9.9.9
  set_latest v9.9.9

  run_net_bootstrap PVE_CONFIG_SHA256=
  [ "$status" -ne 0 ]
  [[ "$output" == *'64 hexadecimal characters'* ]]
  [ ! -s "${CURL_LOG}" ]
  [ ! -e "${PVE_CONFIG_DIR}/pve-config.sh" ]
}

@test "an empty PVE_CONFIG_SHA256 is refused on a ref install" {
  cp "${ARCHIVE}" "${SERVER}/files/main"

  run_net_bootstrap PVE_CONFIG_REF=main PVE_CONFIG_SHA256=
  [ "$status" -ne 0 ]
  [[ "$output" == *'64 hexadecimal characters'* ]]
  [ ! -s "${CURL_LOG}" ]
  [ ! -e "${PVE_CONFIG_DIR}/pve-config.sh" ]
}

@test "an empty PVE_CONFIG_SHA256 is refused on a local archive install" {
  # A pin the operator meant to supply but did not must stop the install
  # rather than fall back to installing nothing-was-checked.
  seed_install

  run env \
    PVE_CONFIG_DIR="${PVE_CONFIG_DIR}" \
    PVE_CONFIG_BOOTSTRAP_ARCHIVE="${ARCHIVE}" \
    PVE_CONFIG_SHA256= \
    bash -euo pipefail -c "source '${BOOTSTRAP}'; bootstrap_install"
  [ "$status" -ne 0 ]
  [[ "$output" == *'64 hexadecimal characters'* ]]
  [ "$(cat "${PVE_CONFIG_DIR}/pve-config.sh")" = 'old driver' ]
}

@test "a latest-release redirect to another origin is refused" {
  printf 'https://example.invalid/path/releases/tag/v1.2.3' >"${SERVER}/redirect"

  run_net_bootstrap
  [ "$status" -ne 0 ]
  [[ "$output" == *'ended somewhere unexpected'* ]]
  run curl_log
  [[ "$output" != *'/releases/download/'* ]]
}
