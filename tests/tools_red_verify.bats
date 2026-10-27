#!/usr/bin/env bats
# SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
# SPDX-License-Identifier: Apache-2.0

# tests/tools/red-verify.sh decides whether every other mutation result in
# this repository can be believed, so it gets the same treatment as the
# code it checks. Each case runs the real tool over a throwaway source
# file and a throwaway .bats file, both written for the test.

load helpers/test_helper

setup() {
  # Breaking the tool in place is not safe: bash reads a script as it
  # runs it, so these cases are pointed at a copy when the tool itself is
  # the thing under mutation.
  TOOL="${PVE_CONFIG_TEST_RED_VERIFY:-${REPO_ROOT}/tests/tools/red-verify.sh}"
  export FIXTURE_SOURCE="${BATS_TEST_TMPDIR}/fixture.sh"
  FIXTURE_TESTS="${BATS_TEST_TMPDIR}/fixture.bats"

  cat >"${FIXTURE_SOURCE}" <<'EOF'
#!/usr/bin/env bash
answer() { printf '42\n'; }
EOF

  cat >"${FIXTURE_TESTS}" <<'EOF'
#!/usr/bin/env bats
setup() { source "${FIXTURE_SOURCE}"; }

@test "builder answers the question" {
  run answer
  [ "${output}" = 42 ]
}

@test "builder answers it a second time" {
  run answer
  [ "${output}" = 42 ]
}

@test "a check nobody runs today" {
  skip "not today"
  false
}
EOF
}

# The inner run must not inherit the outer run's bats bookkeeping.
run_tool() {
  run env -u BATS_ROOT -u BATS_RUN_TMPDIR -u BATS_TEST_FILENAME \
    -u BATS_TEST_NAME -u BATS_TEST_TMPDIR -u BATS_TEST_DESCRIPTION \
    -u BATS_SUITE_TMPDIR -u BATS_LIBEXEC \
    "BATS=${BATS_ROOT}/bin/bats" \
    bash "${TOOL}" "$@"
}

leftover_backups() {
  find "${REPO_ROOT}" -maxdepth 1 -name '.red-verify.*' | sort | tr '\n' ' '
}

source_digest() {
  sha256sum -- "${FIXTURE_SOURCE}" | cut -d' ' -f1
}

@test "a test that notices the broken code is red" {
  run_tool "${FIXTURE_SOURCE}" "${FIXTURE_TESTS}" \
    'builder answers the question' "printf '42" "printf '43"
  [ "$status" -eq 0 ]
  [[ "${output}" == RED* ]]
}

@test "a filter matching more than one test proves nothing" {
  local before
  before=$(source_digest)

  run_tool "${FIXTURE_SOURCE}" "${FIXTURE_TESTS}" \
    'builder answers' "printf '42" "printf '43"
  [ "$status" -eq 4 ]
  [[ "${output}" == AMBIGUOUS* ]]
  [[ "${output}" == *'selects 2 tests'* ]]
  [ "$(source_digest)" = "${before}" ]
}

@test "a test that skips its body decides nothing" {
  run_tool "${FIXTURE_SOURCE}" "${FIXTURE_TESTS}" \
    'a check nobody runs today' "printf '42" "printf '43"
  [ "$status" -eq 4 ]
  [[ "${output}" == ERROR* ]]
  [[ "${output}" == *'reported a skip'* ]]
}

@test "a backup that cannot be taken leaves the source alone" {
  local before backups_before
  before=$(source_digest)
  backups_before=$(leftover_backups)
  mkdir -p "${BATS_TEST_TMPDIR}/bin"
  printf '#!/usr/bin/env bash\nexit 1\n' >"${BATS_TEST_TMPDIR}/bin/cp"
  chmod 0755 "${BATS_TEST_TMPDIR}/bin/cp"
  # shellcheck disable=SC2030,SC2031  # each @test is its own subshell
  PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"

  run_tool "${FIXTURE_SOURCE}" "${FIXTURE_TESTS}" \
    'builder answers the question' "printf '42" "printf '43"
  [ "$status" -eq 4 ]
  [[ "${output}" == ERROR* ]]
  [[ "${output}" == *'no complete backup'* ]]
  [ "$(source_digest)" = "${before}" ]
  # A run of this suite under the tool itself has its own backup sitting
  # there, so this counts new leftovers rather than any at all.
  [ "$(leftover_backups)" = "${backups_before}" ]
}

@test "a backup that comes back short leaves the source alone" {
  local before
  before=$(source_digest)
  mkdir -p "${BATS_TEST_TMPDIR}/bin"
  cat >"${BATS_TEST_TMPDIR}/bin/cp" <<'EOF'
#!/usr/bin/env bash
# A copy that stops part way: the file is there, the contents are not.
for arg; do :; done
head -c 3 -- "${*: -2:1}" >"${arg}"
EOF
  chmod 0755 "${BATS_TEST_TMPDIR}/bin/cp"
  # shellcheck disable=SC2030,SC2031  # each @test is its own subshell
  PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"

  run_tool "${FIXTURE_SOURCE}" "${FIXTURE_TESTS}" \
    'builder answers the question' "printf '42" "printf '43"
  [ "$status" -eq 4 ]
  [[ "${output}" == ERROR* ]]
  [[ "${output}" == *'no complete backup'* ]]
  [ "$(source_digest)" = "${before}" ]
}

@test "the source comes back whatever the outcome was" {
  local before
  before=$(source_digest)

  run_tool "${FIXTURE_SOURCE}" "${FIXTURE_TESTS}" \
    'builder answers the question' "printf '42" "printf '43"
  [ "$status" -eq 0 ]
  [ "$(source_digest)" = "${before}" ]

  run_tool "${FIXTURE_SOURCE}" "${FIXTURE_TESTS}" \
    'no test is called this' "printf '42" "printf '43"
  [ "$status" -eq 2 ]
  [ "$(source_digest)" = "${before}" ]
}
