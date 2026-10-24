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
}

# Builds the tree a codeload tarball contains, with its single top level
# directory.
make_source_tree() {
  mkdir -p "${SRC}/lib" "${SRC}/stages/phase1" "${SRC}/examples"
  printf '#!/usr/bin/env bash\n# driver v%s\n' "${1:-1}" >"${SRC}/pve-config.sh"
  printf '#!/usr/bin/env bash\n' >"${SRC}/bootstrap.sh"
  local lib
  for lib in common config detect state schema; do
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
