#!/usr/bin/env bats
# SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
# SPDX-License-Identifier: Apache-2.0

# shellcheck disable=SC2030,SC2031

# The execution target. Every case here is about the guest path behaving
# like the host path an operator already relies on: the same convergence,
# the same honest dry run, and answers taken from the container rather than
# from the machine running the toolkit.

load helpers/test_helper

setup() {
  load_libs
  isolate_env
  use_mocks
  isolate_system
  CT=101
  GUEST=$(target_guest "${CT}")
  HOST=$(target_host)
  guest_root "${CT}" >/dev/null
}

# A value a shell would mangle if it were ever spliced into script text
# rather than passed as an argument.
# shellcheck disable=SC2016  # the metacharacters are the fixture
NASTY='a b"c'"'"'d;e$f`g` *|&'

# The command a recorded `pct exec` was asked to run. The wrapper's own
# arguments come first -- the tag, this call's token, a count, and that
# many environment assignments -- and the command follows them.
guest_command_of() {
  local rest=${1#* pve-config }
  local -a words
  read -r -a words <<<"${rest}"
  printf '%s' "${words[*]:$((2 + words[1]))}"
}

# pct invocations that change the container. A probe reads and nothing
# more, so it is allowed even on a dry run; everything else is a mutation.
guest_mutations() {
  local line command
  while IFS= read -r line; do
    case ${line} in
      'pct pull '*) continue ;;
      'pct exec '*' pve-config '*)
        command=$(guest_command_of "${line}")
        case ${command} in
          test\ * | stat\ * | dpkg-query\ * | 'systemctl is-active '* | 'systemctl is-enabled '*) continue ;;
        esac
        ;;
      'pct '*) ;;
      *) continue ;;
    esac
    printf '%s\n' "${line}"
  done < <(mock_calls)
}

no_guest_mutations() {
  [ -z "$(guest_mutations)" ]
}

# The command a guest probe or mutation was asked to run, one per line.
guest_commands() {
  local line
  while IFS= read -r line; do
    case ${line} in
      'pct exec '*' pve-config '*) printf '%s\n' "$(guest_command_of "${line}")" ;;
    esac
  done < <(mock_calls)
}

# --- target values --------------------------------------------------------

@test "a target names the host or a container" {
  [ "${HOST}" = 'host' ]
  [ "${GUEST}" = 'guest:101' ]
  target_is_host "${HOST}"
  target_is_guest "${GUEST}"
  run target_is_host "${GUEST}"
  [ "$status" -ne 0 ]
  [ "$(target_vmid "${GUEST}")" = '101' ]
  [ "$(target_describe "${HOST}")" = 'the host' ]
  [ "$(target_describe "${GUEST}")" = 'CT 101' ]
}

@test "a container id that is not a number is refused" {
  run target_guest '101; rm -rf /'
  [ "$status" -ne 0 ]
  [[ "$output" == *'Not a container id'* ]]
}

@test "a path passed where a target belongs is refused" {
  run target_write_file /etc/hosts /etc/hosts body
  [ "$status" -ne 0 ]
  [[ "$output" == *'Not an execution target'* ]]
}

@test "a path means the sysroot on the host and itself in a container" {
  [ "$(target_path "${HOST}" /etc/hosts)" = "${PVE_CONFIG_ROOT}/etc/hosts" ]
  [ "$(target_path "${GUEST}" /etc/hosts)" = '/etc/hosts' ]
}

# --- the host target still behaves as it always did -----------------------

@test "the host target writes through the existing primitive" {
  run target_write_file "${HOST}" /etc/motd 'hello' 0640
  [ "$status" -eq 0 ]
  [[ "$output" == *changed* ]]
  [ "$(cat "$(sysroot_file /etc/motd)")" = 'hello' ]
  [ "$(stat -c '%a' "$(sysroot_file /etc/motd)")" = '640' ]

  run target_write_file "${HOST}" /etc/motd 'hello' 0640
  [[ "$output" == *unchanged* ]]
  no_guest_mutations
}

@test "the host target keeps the backup ensure_exact_line takes" {
  printf '#%%PAM-1.0\n' >"$(sysroot_file /etc/motd)"
  run target_ensure_exact_line "${HOST}" /etc/motd 'auth' 'auth sufficient x.so'
  [ "$status" -eq 0 ]
  [[ "$output" == *changed* ]]
  [ -n "$(find "${PVE_CONFIG_ROOT}/etc" -name 'motd.*.bak' -print -quit)" ]
}

@test "the host target asks the host about its own accounts" {
  seed_user alice
  target_user_exists "${HOST}" alice
  run target_user_exists "${GUEST}" alice
  [ "$status" -ne 0 ]
  no_guest_mutations
}

# --- writing files into a container ---------------------------------------

@test "writing a file into a container pushes it and converges" {
  run target_write_file "${GUEST}" /etc/pve-config.conf 'body' 0640
  [ "$status" -eq 0 ]
  [[ "$output" == *changed* ]]
  [[ "$(mock_calls)" == *'pct push 101 '* ]]
  [ "$(cat "$(guest_file "${CT}" /etc/pve-config.conf)")" = 'body' ]
  [ "$(stat -c '%a' "$(guest_file "${CT}" /etc/pve-config.conf)")" = '640' ]

  : >"${PVE_CONFIG_MOCK_LOG}"
  run target_write_file "${GUEST}" /etc/pve-config.conf 'body' 0640
  [ "$status" -eq 0 ]
  [[ "$output" == *unchanged* ]]
  no_guest_mutations
}

@test "a file whose mode drifted in the container is pushed again" {
  target_write_file "${GUEST}" /etc/pve-config.conf 'body' 0640 >/dev/null
  chmod 0666 "$(guest_file "${CT}" /etc/pve-config.conf)"

  run target_write_file "${GUEST}" /etc/pve-config.conf 'body' 0640
  [[ "$output" == *changed* ]]
  [ "$(stat -c '%a' "$(guest_file "${CT}" /etc/pve-config.conf)")" = '640' ]
}

@test "a line is added to a container's file exactly once" {
  seed_guest_file "${CT}" /etc/sysctl.conf $'# header\nnet.ipv4.ip_forward=0\n'

  run target_ensure_line_in_file "${GUEST}" /etc/sysctl.conf 'net.ipv6.conf.all.forwarding=1'
  [ "$status" -eq 0 ]
  [[ "$output" == *changed* ]]

  local file
  file=$(guest_file "${CT}" /etc/sysctl.conf)
  for _ in 1 2 3; do
    target_ensure_line_in_file "${GUEST}" /etc/sysctl.conf 'net.ipv6.conf.all.forwarding=1' >/dev/null
  done
  [ "$(grep -c 'ipv6' "${file}")" -eq 1 ]
  [ "$(head -n1 "${file}")" = '# header' ]
}

@test "exactly one active line survives in a container's file" {
  seed_guest_file "${CT}" /etc/pam.d/sudo \
    $'#%PAM-1.0\nauth sufficient pam_x.so old\nauth sufficient pam_x.so older\n@include common-auth\n'

  run target_ensure_exact_line "${GUEST}" /etc/pam.d/sudo 'pam_x\.so' \
    'auth sufficient pam_x.so file=/etc/security/keys' after-first
  [ "$status" -eq 0 ]
  [[ "$output" == *changed* ]]

  local file
  file=$(guest_file "${CT}" /etc/pam.d/sudo)
  [ "$(grep -c 'pam_x.so' "${file}")" -eq 1 ]
  [ "$(sed -n 2p "${file}")" = 'auth sufficient pam_x.so file=/etc/security/keys' ]

  : >"${PVE_CONFIG_MOCK_LOG}"
  run target_ensure_exact_line "${GUEST}" /etc/pam.d/sudo 'pam_x\.so' \
    'auth sufficient pam_x.so file=/etc/security/keys' after-first
  [[ "$output" == *unchanged* ]]
  no_guest_mutations
}

@test "a directory in a container is created once with the mode asked for" {
  run target_ensure_dir "${GUEST}" /etc/pve-config/keys 0700
  [ "$status" -eq 0 ]
  [[ "$output" == *changed* ]]
  [ -d "$(guest_file "${CT}" /etc/pve-config/keys)" ]
  [ "$(stat -c '%a' "$(guest_file "${CT}" /etc/pve-config/keys)")" = '700' ]

  : >"${PVE_CONFIG_MOCK_LOG}"
  run target_ensure_dir "${GUEST}" /etc/pve-config/keys 0700
  [[ "$output" == *unchanged* ]]
  no_guest_mutations
}

@test "a world writable file in a container has its write bits cleared" {
  seed_guest_file "${CT}" /root/.ssh/authorized_keys 'ssh-ed25519 AAAA x' 0666

  run target_ensure_not_group_other_writable "${GUEST}" /root/.ssh/authorized_keys
  [ "$status" -eq 0 ]
  [[ "$output" == *changed* ]]
  [ "$(stat -c '%a' "$(guest_file "${CT}" /root/.ssh/authorized_keys)")" = '644' ]

  run target_ensure_not_group_other_writable "${GUEST}" /root/.ssh/authorized_keys
  [[ "$output" == *unchanged* ]]
}

@test "removing a path from a container converges" {
  seed_guest_file "${CT}" /etc/stale 'x'

  run target_remove_path "${GUEST}" /etc/stale
  [ "$status" -eq 0 ]
  [[ "$output" == *changed* ]]
  [ ! -e "$(guest_file "${CT}" /etc/stale)" ]

  run target_remove_path "${GUEST}" /etc/stale
  [[ "$output" == *unchanged* ]]
}

# --- answers come from the container --------------------------------------

@test "an account the host has is still created in the container" {
  seed_user deploy
  run target_user_converge "${GUEST}" deploy /bin/bash
  [ "$status" -eq 0 ]
  [[ "$output" == *changed* ]]
  grep -q '^deploy:' "$(guest_file "${CT}" /etc/passwd)"

  run target_user_converge "${GUEST}" deploy /bin/bash
  [[ "$output" == *unchanged* ]]
}

@test "a login shell that drifted in the container is corrected" {
  seed_guest_user "${CT}" deploy /usr/sbin/nologin

  run target_user_converge "${GUEST}" deploy /bin/bash
  [[ "$output" == *changed* ]]
  local shell=''
  target_user_shell shell "${GUEST}" deploy
  [ "${shell}" = '/bin/bash' ]

  run target_user_converge "${GUEST}" deploy /bin/bash
  [[ "$output" == *unchanged* ]]
}

@test "a group membership in the container is added once" {
  seed_guest_user "${CT}" deploy
  run target_user_join_group "${GUEST}" deploy sudo
  [ "$status" -eq 0 ]
  [[ "$output" == *changed* ]]
  target_user_in_group "${GUEST}" deploy sudo
  run target_user_in_group "${HOST}" deploy sudo
  [ "$status" -ne 0 ]

  : >"${PVE_CONFIG_MOCK_LOG}"
  run target_user_join_group "${GUEST}" deploy sudo
  [[ "$output" == *unchanged* ]]
  no_guest_mutations
}

@test "a package installed in the container does not count on the host" {
  run target_pkg_install "${GUEST}" curl
  [ "$status" -eq 0 ]
  [[ "$output" == *changed* ]]
  target_pkg_is_installed "${GUEST}" curl
  run target_pkg_is_installed "${HOST}" curl
  [ "$status" -ne 0 ]

  : >"${PVE_CONFIG_MOCK_LOG}"
  run target_pkg_install "${GUEST}" curl
  [[ "$output" == *unchanged* ]]
  no_guest_mutations
}

@test "a unit enabled in the container converges" {
  run target_service_enable "${GUEST}" tailscaled
  [ "$status" -eq 0 ]
  [[ "$output" == *changed* ]]
  target_service_is_enabled "${GUEST}" tailscaled
  run target_service_is_enabled "${HOST}" tailscaled
  [ "$status" -ne 0 ]

  : >"${PVE_CONFIG_MOCK_LOG}"
  run target_service_enable "${GUEST}" tailscaled
  [[ "$output" == *unchanged* ]]
  no_guest_mutations
}

@test "the systemd manager in each target is reloaded once" {
  target_systemd_daemon_reload "${GUEST}" >/dev/null
  run target_systemd_daemon_reload "${GUEST}"
  [[ "$output" == *unchanged* ]]
  [ "$(grep -cx 'systemctl daemon-reload' <(guest_commands))" -eq 1 ]
}

# --- the dry run mutates nothing, on either target ------------------------

@test "a dry run against a container describes the work and performs none" {
  seed_guest_user "${CT}" deploy /usr/sbin/nologin
  export PVE_CONFIG_DRY_RUN=1
  : >"${PVE_CONFIG_MOCK_LOG}"

  run target_write_file "${GUEST}" /etc/pve-config.conf 'body' 0640
  [[ "$output" == *changed* ]]
  run target_ensure_dir "${GUEST}" /etc/pve-config/keys 0700
  [[ "$output" == *changed* ]]
  run target_user_converge "${GUEST}" other /bin/bash
  [[ "$output" == *changed* ]]
  run target_user_converge "${GUEST}" deploy /bin/bash
  [[ "$output" == *changed* ]]
  run target_pkg_install "${GUEST}" curl
  [[ "$output" == *changed* ]]
  run target_service_enable "${GUEST}" tailscaled
  [[ "$output" == *changed* ]]

  no_guest_mutations
  [ ! -e "$(guest_file "${CT}" /etc/pve-config.conf)" ]
  [ ! -e "$(guest_file "${CT}" /etc/pve-config/keys)" ]
  run grep -q '^other:' "$(guest_file "${CT}" /etc/passwd)"
  [ "$status" -ne 0 ]
  grep -q '^deploy:x:[0-9]*:[0-9]*::/home/deploy:/usr/sbin/nologin$' \
    "$(guest_file "${CT}" /etc/passwd)"
}

@test "a dry run still reads the container to decide what is needed" {
  seed_guest_file "${CT}" /etc/pve-config.conf 'body'
  export PVE_CONFIG_DRY_RUN=1

  run target_write_file "${GUEST}" /etc/pve-config.conf 'body'
  [[ "$output" == *unchanged* ]]
  [[ "$(mock_calls)" == *'pct pull 101 /etc/pve-config.conf'* ]]
}

@test "a dry run against a container that is not there yet still describes it" {
  export PVE_CONFIG_DRY_RUN=1
  export PVE_CONFIG_MOCK_PCT_FAIL_VMID="${CT}"

  run target_write_file "${GUEST}" /etc/pve-config.conf 'body'
  [ "$status" -eq 0 ]
  [[ "$output" == *changed* ]]
  [[ "$output" == *'cannot reach'* ]]
  no_guest_mutations
}

# --- failures say which half failed ---------------------------------------

@test "a command that fails inside the container is reported as such" {
  run target_run "${GUEST}" sh -c 'exit 3'
  [ "$status" -eq 3 ]
  [[ "$output" == *'failed inside CT 101'* ]]
  [[ "$output" == *'status 3'* ]]
  [[ "$output" != *'pct could not'* ]]
}

@test "pct failing to reach the container is reported differently" {
  export PVE_CONFIG_MOCK_PCT_FAIL_VMID="${CT}"
  run target_run "${GUEST}" true
  [ "$status" -ne 0 ]
  [[ "$output" == *'pct could not run a command in CT 101'* ]]
  [[ "$output" != *'failed inside'* ]]
}

@test "pct succeeding without the command having run is a pct failure" {
  export PVE_CONFIG_MOCK_PCT_NO_SENTINEL=1
  run target_run "${GUEST}" true
  [ "$status" -ne 0 ]
  [[ "$output" == *'pct could not run a command in CT 101'* ]]
}

@test "a container pct cannot reach is never mistaken for an empty one" {
  export PVE_CONFIG_MOCK_PCT_FAIL_VMID="${CT}"
  run target_user_exists "${GUEST}" deploy
  [ "$status" -ne 0 ]
  [[ "$output" == *'pct could not run a command in CT 101'* ]]
}

@test "a push that cannot reach the container stops the run" {
  seed_guest_file "${CT}" /etc/pve-config.conf 'old'
  export PVE_CONFIG_MOCK_PCT_FAIL_VMID="${CT}"
  run target_write_file "${GUEST}" /etc/pve-config.conf 'new'
  [ "$status" -ne 0 ]
  [ "$(cat "$(guest_file "${CT}" /etc/pve-config.conf)")" = 'old' ]
}

# --- the pct exec boundary ------------------------------------------------

@test "a value full of shell metacharacters survives pct exec intact" {
  local got=''
  target_capture got "${GUEST}" printf '%s' "${NASTY}"
  [ "${got}" = "${NASTY}" ]
}

@test "a value full of shell metacharacters survives pct push intact" {
  run target_write_file "${GUEST}" /etc/pve-config.conf "${NASTY}"
  [ "$status" -eq 0 ]
  [ "$(cat "$(guest_file "${CT}" /etc/pve-config.conf)")" = "${NASTY}" ]

  run target_write_file "${GUEST}" /etc/pve-config.conf "${NASTY}"
  [[ "$output" == *unchanged* ]]
}

@test "a line full of shell metacharacters is added to a container once" {
  seed_guest_file "${CT}" /etc/pve-config.conf $'first\n'

  run target_ensure_line_in_file "${GUEST}" /etc/pve-config.conf "${NASTY}"
  [ "$status" -eq 0 ]
  [[ "$output" == *changed* ]]
  [ "$(sed -n 2p "$(guest_file "${CT}" /etc/pve-config.conf)")" = "${NASTY}" ]

  run target_ensure_line_in_file "${GUEST}" /etc/pve-config.conf "${NASTY}"
  [[ "$output" == *unchanged* ]]
  [ "$(wc -l <"$(guest_file "${CT}" /etc/pve-config.conf)")" -eq 2 ]
}

@test "a path with a space in it is created in the container" {
  run target_ensure_dir "${GUEST}" '/etc/pve config' 0755
  [ "$status" -eq 0 ]
  [ -d "$(guest_file "${CT}" '/etc/pve config')" ]

  run target_ensure_dir "${GUEST}" '/etc/pve config' 0755
  [[ "$output" == *unchanged* ]]
}

# --- reading and probing --------------------------------------------------

@test "a file is read back out of the container byte for byte" {
  seed_guest_file "${CT}" /etc/pve-config.conf $'one\ntwo\n'
  local body=''
  target_slurp body "${GUEST}" /etc/pve-config.conf
  [ "${body}" = $'one\ntwo\n' ]

  run target_slurp body "${GUEST}" /etc/absent
  [ "$status" -ne 0 ]
  # The assignment itself is checked outside `run`, which would discard it.
  body='stale'
  target_slurp body "${GUEST}" /etc/absent || true
  [ -z "${body}" ]
}

@test "a probe answers from the container and leaves it alone" {
  seed_guest_file "${CT}" /etc/pve-config.conf 'x'
  target_test "${GUEST}" f /etc/pve-config.conf
  run target_test "${GUEST}" f /etc/absent
  [ "$status" -ne 0 ]
  run target_test "${GUEST}" d /etc/pve-config.conf
  [ "$status" -ne 0 ]
  target_test "${GUEST}" d /etc
  no_guest_mutations
}

@test "the scratch file a push stages is not left behind" {
  target_write_file "${GUEST}" /etc/pve-config.conf 'body' >/dev/null
  [ -z "$(find "${TMPDIR}" -maxdepth 1 -name 'pve-config-target.*' -print -quit)" ]
}

# --- modes survive the push -----------------------------------------------

@test "a pushed file lands with exactly the mode asked for" {
  local mode
  for mode in 0640 0600 4755 2750 1777; do
    target_write_file "${GUEST}" "/etc/mode-${mode}" 'body' "${mode}" >/dev/null
    [ "$(stat -c '%a' "$(guest_file "${CT}" "/etc/mode-${mode}")")" \
      = "$(printf '%o' "$((8#${mode}))")" ]
  done
}

@test "a mode stat reported is pushed back unchanged" {
  seed_guest_file "${CT}" /etc/pve-config.conf $'first\n' 4711

  run target_ensure_line_in_file "${GUEST}" /etc/pve-config.conf 'second'
  [ "$status" -eq 0 ]
  [[ "$output" == *changed* ]]
  [ "$(stat -c '%a' "$(guest_file "${CT}" /etc/pve-config.conf)")" = '4711' ]
}

@test "a mode that is not octal is refused rather than guessed at" {
  run target_write_file "${GUEST}" /etc/pve-config.conf 'body' 0987
  [ "$status" -ne 0 ]
  [[ "$output" == *'Not an octal file mode'* ]]
  [ ! -e "$(guest_file "${CT}" /etc/pve-config.conf)" ]
}

# --- the end-of-command report --------------------------------------------

@test "output that looks like the end-of-command report is kept" {
  local got=''
  target_capture got "${GUEST}" printf '%s\n' alpha '@@pve-config-exit:77@@' \
    'pve-config-exit-whatever:0' omega
  [ "${got}" = $'alpha\n@@pve-config-exit:77@@\npve-config-exit-whatever:0\nomega' ]
}

@test "the end-of-command report differs from call to call" {
  target_probe "${GUEST}" true
  target_probe "${GUEST}" true
  local tokens
  tokens=$(sed -n 's/.* pve-config \([^ ]*\) .*/\1/p' "${PVE_CONFIG_MOCK_LOG}")
  [ "$(printf '%s\n' "${tokens}" | wc -l)" -eq 2 ]
  [ "$(printf '%s\n' "${tokens}" | sort -u | wc -l)" -eq 2 ]
}

# --- the environment a guest command runs with ----------------------------

@test "the host's environment does not follow a command into the container" {
  export PVE_DNS_API_SECRET='super-secret-value'
  local got=''
  target_capture got "${GUEST}" env
  [[ "${got}" != *super-secret-value* ]]
  [[ "${got}" != *PVE_DNS_API_SECRET* ]]
  [[ "${got}" == *'HOME=/root'* ]]
  [[ "${got}" == *'LC_ALL=C.UTF-8'* ]]
  [[ "${got}" == *'TERM=dumb'* ]]
}

@test "a malformed guest target is refused rather than handed to pct" {
  run target_describe 'guest:101junk'
  [ "$status" -ne 0 ]
  run target_probe 'guest:101junk' true
  [ "$status" -ne 0 ]
  [ ! -s "${PVE_CONFIG_MOCK_LOG}" ]
}
