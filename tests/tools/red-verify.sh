#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
# SPDX-License-Identifier: Apache-2.0

# Prove that a test can fail.
#
# A test that passes whether or not the code is right is worse than no
# test: it reports coverage it does not have. This breaks the code on
# purpose and checks that the test notices.
#
# Usage:
#   tests/tools/red-verify.sh SOURCE TESTFILE TESTNAME OLD NEW
#
# SOURCE     the shell file to break, relative to the repository root
# TESTFILE   the .bats file holding the test
# TESTNAME   passed to `bats -f`, which treats it as an extended regex
# OLD        literal text to find in SOURCE; it may span lines
# NEW        literal text to put in its place
#
# The runner is $BATS, or `bats` on PATH.
#
# OLD and NEW are literal, not patterns. The replacement happens inside
# perl with both strings taken from the environment, so a `$` or a `/` in
# the code being broken is just a character. Handing perl a substitution
# written on the command line looks tidier and is a trap: perl
# interpolates the shell's text before matching, including inside \Q, so
# a mutation naming a shell variable silently edits somewhere else and
# reports a result about code nobody touched.
#
# It prints one of these, and exits with the status beside it:
#
#   RED      0  a test ran and failed, which is what we want
#   GREEN    1  a test ran and passed anyway, so it covers nothing
#   NOMATCH  2  TESTNAME selected no test at all
#   NOCHANGE 3  OLD is not in SOURCE, so nothing was broken
#   AMBIGUOUS 4 OLD or TESTNAME picks out more than one thing
#   ERROR    4  the run did not happen, so it proves nothing either way
#
# The whole value of this tool rests on one rule: RED means a test ran
# and failed. It must never mean that something went wrong. Three things
# enforce that, and each of them is here because the obvious version was
# wrong:
#
#   The runner is checked before anything is touched. A $BATS that is not
#   there exits non-zero like a failing test does, so without this a
#   missing runner "proves" every test in the suite.
#
#   A TAP plan naming at least one test is required, and the ok and not
#   ok lines are counted and checked against it. Only a `not ok` makes
#   this RED. A non-zero status with no failed test is a runner problem,
#   not a result.
#
#   OLD must appear exactly once. Only the first occurrence would be
#   replaced, so a snippet such as `*) return 2 ;;` that appears in two
#   functions breaks whichever one comes first in the file and reports a
#   result about code the caller never meant to touch.
#
#   TESTNAME must select exactly one test. `bats -f` takes a regex, so a
#   filter such as `builder` can match eight tests, and any one of them
#   failing for its own unrelated reason would read as this mutation
#   being caught. Same failure class as the one above, along the other
#   axis.
#
#   A test that reports a skip or a TODO directive did not run its body,
#   so it decides nothing about the mutation either.
#
#   A filter that selects nothing is NOMATCH, not RED. bats exits
#   non-zero in that case too, so a misspelled test name would otherwise
#   report success at proving nothing.
#
# SOURCE is restored on every exit path once it has been mutated, and it
# is mutated only after a backup has been taken and checked. A signal
# restores it and exits 128 plus the signal number, because an
# interrupted run has no result and must not be read as one.
set -euo pipefail

say() {
  printf '%-8s %s\n' "$1" "$2"
}

digest_of() {
  local out=''
  out=$(sha256sum -- "$1" 2>/dev/null) ||
    out=$(cksum -- "$1" 2>/dev/null) ||
    return 1
  printf '%s\n' "${out%% *}"
}

if [[ $# -ne 5 ]]; then
  printf 'usage: %s SOURCE TESTFILE TESTNAME OLD NEW\n' "$0" >&2
  exit 4
fi

source_file=$1
test_file=$2
test_name=$3
export RED_VERIFY_OLD=$4
export RED_VERIFY_NEW=$5

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
cd -- "${root}"

# Everything that could stop the run from happening is checked before the
# source file is touched, so a refusal never leaves broken code behind.
bats_cmd=${BATS:-bats}
if ! command -v -- "${bats_cmd}" >/dev/null 2>&1; then
  say ERROR "no bats runner: '${bats_cmd}' is not an executable on PATH. Set BATS to one."
  exit 4
fi
if [[ ! -f ${source_file} ]]; then
  say ERROR "no such file: ${source_file}"
  exit 4
fi
if [[ ! -f ${test_file} ]]; then
  say ERROR "no such test file: ${test_file}"
  exit 4
fi

backup=$(mktemp -- "${root}/.red-verify.XXXXXX")
if ! cp -p -- "${source_file}" "${backup}" ||
  ! cmp -s -- "${source_file}" "${backup}"; then
  rm -f -- "${backup}"
  say ERROR "no complete backup of ${source_file} could be taken, so it was left as it stands."
  exit 4
fi
if ! backup_digest=$(digest_of "${backup}"); then
  rm -f -- "${backup}"
  say ERROR "the backup of ${source_file} could not be checksummed, so ${source_file} was left as it stands."
  exit 4
fi

# Restoration is armed here, and not a line earlier. SOURCE needs no
# restoring until it has been mutated, and mktemp hands back an empty
# file: arming first means a copy that fails or is interrupted leaves
# restore ready to write nothing over a tracked file. The backup is a
# verified copy by the time anything can call restore, and restore
# checks it again before trusting it.
# shellcheck disable=SC2329  # run from the traps below
restore() {
  local now=''
  if [[ ! -f ${backup} ]]; then
    printf 'red-verify: the backup is gone; %s has been left as it stands\n' \
      "${source_file}" >&2
    return 0
  fi
  now=$(digest_of "${backup}") || now=''
  if [[ ${now} != "${backup_digest}" ]]; then
    printf 'red-verify: the backup of %s no longer matches what was copied; refusing to restore from it. It is at %s\n' \
      "${source_file}" "${backup}" >&2
    return 0
  fi
  cp -p -- "${backup}" "${source_file}"
  rm -f -- "${backup}"
}
trap restore EXIT
# Restoring and carrying on would leave the rest of this script deciding
# what an interrupted run proved. It proved nothing, so it stops here.
trap 'restore; exit 129' HUP
trap 'restore; exit 130' INT
trap 'restore; exit 143' TERM

occurrences=$(perl -0ne \
  'my $c = () = /\Q$ENV{RED_VERIFY_OLD}\E/g; print $c' \
  -- "${backup}")
if ((occurrences == 0)); then
  say NOCHANGE "that text is not in ${source_file}: ${test_name}"
  exit 3
fi
if ((occurrences > 1)); then
  say AMBIGUOUS "that text is in ${source_file} ${occurrences} times; only the first would be replaced. Give more context: ${test_name}"
  exit 4
fi

perl -0pe 's/\Q$ENV{RED_VERIFY_OLD}\E/$ENV{RED_VERIFY_NEW}/' \
  -- "${backup}" >"${source_file}"
if cmp -s -- "${backup}" "${source_file}"; then
  say ERROR "the replacement left ${source_file} unchanged: ${test_name}"
  exit 4
fi

out=$("${bats_cmd}" -f "${test_name}" "${test_file}" 2>&1) && status=0 || status=$?

# bats writes its "Found no tests" error without a trailing newline, so
# the plan that follows lands on the same line as the error text. The
# plan is therefore matched at end of line rather than as a whole line,
# because matching it as a whole line finds neither.
plan=$(grep -oE '^1\.\.[0-9]+$' <<<"${out}" | head -n 1 | cut -c4- || true)
if [[ -z ${plan} ]]; then
  plan=$(grep -oE '1\.\.[0-9]+$' <<<"${out}" | head -n 1 | cut -c4- || true)
fi
ok_count=$(grep -cE '^ok [0-9]+' <<<"${out}" || true)
not_ok_count=$(grep -cE '^not ok [0-9]+' <<<"${out}" || true)
skip_count=$(grep -ciE '^ok [0-9]+.*# *skip' <<<"${out}" || true)
todo_count=$(grep -ciE '^not ok [0-9]+.*# *todo' <<<"${out}" || true)

if [[ -z ${plan} ]]; then
  say ERROR "${bats_cmd} printed no TAP plan, so no test ran: ${test_name}"
  printf '%s\n' "${out}" >&2
  exit 4
fi

if ((plan == 0)) || grep -qF 'Found no tests' <<<"${out}"; then
  say NOMATCH "no test in ${test_file} has that name: ${test_name}"
  exit 2
fi

if ((plan > 1)); then
  say AMBIGUOUS "'${test_name}' is a regex and it selects ${plan} tests in ${test_file}; any one of them failing for its own reasons would read as this mutation being caught. Name one test."
  exit 4
fi

if ((ok_count + not_ok_count != plan)); then
  say ERROR "${bats_cmd} planned ${plan} tests and reported $((ok_count + not_ok_count)), so the run did not finish: ${test_name}"
  printf '%s\n' "${out}" >&2
  exit 4
fi

if ((skip_count > 0)); then
  say ERROR "${test_name} reported a skip, so its body never ran."
  printf '%s\n' "${out}" >&2
  exit 4
fi

if ((todo_count > 0)); then
  say ERROR "${test_name} is marked TODO, so a failure from it says nothing."
  printf '%s\n' "${out}" >&2
  exit 4
fi

if ((not_ok_count > 0)); then
  say RED "${test_name}"
  exit 0
fi

if ((status != 0)); then
  say ERROR "${bats_cmd} exited ${status} with no failed test, so this is a runner problem: ${test_name}"
  printf '%s\n' "${out}" >&2
  exit 4
fi

say GREEN "it passes with ${source_file} broken: ${test_name}"
exit 1
