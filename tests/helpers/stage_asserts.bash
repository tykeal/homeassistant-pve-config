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
  '^passwd -S .*'
  '^nft list (ruleset|table [a-z]+ [A-Za-z0-9_]+)$'
  '^nft -c -f /[^ ]+$'
  '^ifreload --syntax-check .*'
  '^ifquery -a -i .*'
  '^findmnt( -[^ ]+)* .*'
  '^mountpoint -q .*'
  '^ssh-keygen -l -f /dev/stdin$'
  '^pct (list|status [0-9]+)$'
  '^qm (list|status [0-9]+|config [0-9]+)$'
  '^nproc$'
  '^pct pull [0-9]+ /[^ ]+ [^ ]+$'
  '^pvesh get /cluster/nextid$'
  '^pvesh get /cluster/resources( |$).*'
  '^pvesm status( |$).*'
  '^sysctl -n .*'
  '^tailscale status( |$).*'
  # A command run inside a container is recorded whole, the toolkit's
  # wrapper and its five environment assignments included. Naming the
  # command that follows TERM=dumb is what keeps this a list of read-only
  # invocations rather than a licence for pct exec.
  '^pct exec [0-9]+ --keep-env 0 -- /bin/sh -c .* TERM=dumb (test|stat|ls -1A?|find|readlink|sha256sum|dpkg-query|sysctl -n|tailscale status|systemctl is-active|systemctl is-enabled|passwd -S|nft list|nft -c) .*$'
  # Asking the container's own sshd what its configuration resolves to
  # means building an overlay for it to read, which is a write. Named
  # down to the path so this stays a licence for one scratch directory
  # on a tmpfs no daemon reads rather than for writing into a container.
  # The copy and the mount reach /etc/ssh, so they are spelled out whole
  # rather than left to a wildcard: a bind whose target were /etc/ssh
  # outside a namespace would be a mutation, and must not pass here.
  '^pct exec [0-9]+ --keep-env 0 -- /bin/sh -c .* TERM=dumb mkdir -p -- /run/pve-config/sshd-check(/etc-ssh(/sshd_config\.d)?)?$'
  '^pct exec [0-9]+ --keep-env 0 -- /bin/sh -c .* TERM=dumb chmod -- 0[0-9]+ /run/pve-config/sshd-check(/etc-ssh(/sshd_config\.d)?)?$'
  '^pct exec [0-9]+ --keep-env 0 -- /bin/sh -c .* TERM=dumb rm -rf -- /run/pve-config/sshd-check$'
  '^pct exec [0-9]+ --keep-env 0 -- /bin/sh -c .* TERM=dumb cp -a /etc/ssh/\. /run/pve-config/sshd-check/etc-ssh/$'
  '^pct push [0-9]+ [^ ]+ /run/pve-config/sshd-check/etc-ssh/[^ ]+ --perms 0[0-7]+$'
  '^pct exec [0-9]+ --keep-env 0 -- /bin/sh -c .* TERM=dumb /bin/sh -c .*unshare -m .*pve-config /run/pve-config/sshd-check/etc-ssh /etc/ssh mount --bind .*sshd -T.*$'
  # The same dump as the namespace and mount mocks record it from inside
  # the container. The bind is only read-only because it happens in the
  # private namespace unshare opened, so both are named down to paths.
  '^unshare -m /bin/sh -c mount --bind .*sshd -T.* pve-config /run/pve-config/sshd-check/etc-ssh /etc/ssh$'
  '^mount --bind /run/pve-config/sshd-check/etc-ssh /etc/ssh$'
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
