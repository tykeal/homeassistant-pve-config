# SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
# SPDX-License-Identifier: Apache-2.0

# The two halves of the idempotency guarantee every stage has to meet,
# shared by the stage tests of each phase.

# Path, mode, ownership and content digest for everything a stage may have
# touched: the scratch root, the state directory, and the mock's own record
# of what it believes the host looks like. Comparing this across two runs is
# half the idempotency guarantee.
state_fingerprint() {
  local root path
  for root in "${PVE_CONFIG_ROOT}" "${PVE_CONFIG_STATE_DIR}" \
    "${PVE_CONFIG_MOCK_STATE}"; do
    [[ -e ${root} ]] || continue
    while IFS= read -r path; do
      if [[ -L ${path} ]]; then
        printf '%s link %s\n' "${path}" "$(readlink -- "${path}")"
      elif [[ -d ${path} ]]; then
        printf '%s dir %s\n' "${path}" "$(stat -c '%a %u:%g' -- "${path}")"
      else
        printf '%s %s %s\n' "${path}" "$(stat -c '%a %u:%g' -- "${path}")" \
          "$(cksum <"${path}" | cut -d' ' -f1)"
      fi
    done < <(find "${root}" | sort)
  done
}

# The other half. A stage can leave the filesystem alone and still have
# reinstalled a package, restarted a unit or re-added a Proxmox user; only
# the mock log shows that. Anything not on this list changes host state, so
# seeing it on a second pass is a convergence failure.
# Each pattern names an exact read-only invocation, not just a read-only
# tool: `hostname` reports, `hostname pve1` sets; `ip ... show` reports,
# `ip addr add` does not; `ssh-keygen -l` inspects, `ssh-keygen -f` writes
# a key file. Allowing a whole command name would let a second pass
# reconfigure the host without this noticing.
MOCK_READ_ONLY_PATTERNS=(
  '^hostname( -[sfd])?$'
  '^ip( -[46])?( -o)? (addr|route) show( dev)? [A-Za-z0-9_.-]+$'
  '^ip( -[46])?( -o)? route show default$'
  '^dpkg-query .*'
  '^systemctl (is-active|is-enabled|show|list-unit-files)( |$).*'
  '^pveum (user|acl|role) list( |$).*'
  '^pvenode acme (account|plugin) (list|info|config)( |$).*'
  '^pvenode (cert info|config get)( |$).*'
  '^sshd( -[^ ]+)* -t( |$).*'
  '^sshd( -[^ ]+)* -T( |$).*'
  '^visudo -c -f .*'
  '^ifreload --syntax-check .*'
  '^ifquery -a -i .*'
  '^findmnt( -[^ ]+)* .*'
  '^mountpoint -q .*'
  '^ssh-keygen -l -f /dev/stdin$'
)

assert_no_mutating_calls() {
  local line pattern offenders='' allowed
  while IFS= read -r line; do
    # The recorder appends the argument list, which is empty for a bare
    # invocation; trimming keeps the patterns describing commands rather
    # than that artefact.
    line=${line%"${line##*[![:space:]]}"}
    [[ -n ${line} ]] || continue
    allowed=0
    for pattern in "${MOCK_READ_ONLY_PATTERNS[@]}"; do
      if [[ ${line} =~ ${pattern} ]]; then
        allowed=1
        break
      fi
    done
    [[ ${allowed} -eq 1 ]] && continue
    offenders+="${line}"$'\n'
  done < <(mock_calls)
  if [[ -n ${offenders} ]]; then
    printf 'second pass issued mutating commands:\n%s' "${offenders}" >&2
    return 1
  fi
}

# Runs a stage twice through the given runner and fails when the second
# pass moved anything, on disk or through a command.
assert_stage_converges_with() {
  local runner=$1 stage=$2 before after
  "${runner}" "${stage}"
  before=$(state_fingerprint)
  : >"${PVE_CONFIG_MOCK_LOG}"
  "${runner}" "${stage}"
  after=$(state_fingerprint)
  [ "${before}" = "${after}" ]
  assert_no_mutating_calls
}
