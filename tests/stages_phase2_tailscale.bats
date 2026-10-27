#!/usr/bin/env bats
# Every @test runs in its own subshell, so the exports these tests use to
# vary the configuration cannot leak into one another; shellcheck's
# subshell-scope warnings describe a hazard that does not exist here.
# shellcheck disable=SC2030,SC2031
# SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
# SPDX-License-Identifier: Apache-2.0

load helpers/test_helper
load helpers/stage_asserts

AUTHKEY='tskey-auth-k9f2a7cQ11CNTRL-3bXe'

# What the curl mock serves for the repository key, and its digest. The
# stage pins the real key's SHA-256, so a suite that did not pin the
# fixture's would be testing a code path the operator never takes.
KEYRING_PAYLOAD='pve-config test fixture: Tailscale repository signing key'

# The tag the stage puts on the container it owns.
OWNER_TAG='pve-config-tailscale'

setup() {
  load_libs
  isolate_env
  use_mocks
  isolate_system
  stage_config
  seed_secrets_file
  # The builder is fetched through the pin, which a test points at a
  # fixture tree rather than at GitHub.
  export COMMUNITY_SCRIPTS_URL="file://${REPO_ROOT}/tests/helpers/community-scripts"
  export COMMUNITY_SCRIPTS_CORE_URL='file:///nonexistent/core'
}

stage_config() {
  export PVE_HOSTNAME='pve1'
  export PVE_DOMAIN='example.net'
  export PVE_FQDN='pve1.example.net'
  export PVE_TAILSCALE_ENABLED='yes'
  export PVE_TAILSCALE_HOSTNAME='ts-pve1'
  export PVE_ACME_ENABLED='no'
  export PVE_TAILSCALE_KEYRING_SHA256
  PVE_TAILSCALE_KEYRING_SHA256=$(printf '%s\n' "${KEYRING_PAYLOAD}" |
    sha256sum | cut -d' ' -f1)
}

# A container configuration that looks like one an earlier run left.
seed_ct() {
  local id=$1 name=${2:-ts-pve1} tags=${3-${OWNER_TAG}}
  mkdir -p "$(dirname -- "$(ct_conf "${id}")")"
  {
    printf 'arch: amd64\n'
    printf 'hostname: %s\n' "${name}"
    printf 'ostype: debian\n'
    if [ -n "${tags}" ]; then printf 'tags: %s\n' "${tags}"; fi
  } >"$(ct_conf "${id}")"
}

seed_secrets_file() {
  SECRETS="${PVE_CONFIG_DIR}/secrets.env"
  printf "PVE_TAILSCALE_AUTHKEY='%s'\nPVE_DNSMADEEASY_KEY='%s'\n" \
    "${AUTHKEY}" 'me-key-4f2a9c' >"${SECRETS}"
  chmod 600 "${SECRETS}"
}

# The subnet the ip mock reports as vmbr0's, which is what the stage
# advertises when nothing is configured.
LAN_SUBNET='192.0.2.0/24'

run_tailscale() {
  run_phase2_stage 20-tailscale.sh
}

ct_conf() {
  printf '%s\n' "${PVE_CONFIG_ROOT}/etc/pve/lxc/${1:-100}.conf"
}

# Run the tailscale mock the way the container would, against that
# container's own mock state. Used to put the daemon into a state an
# operator could have put it into.
guest_tailscale() {
  local id=$1
  shift
  (
    export PATH="${REPO_ROOT}/tests/helpers/mocks:${PATH}"
    export PVE_CONFIG_MOCK_STATE="${PVE_CONFIG_MOCK_STATE}/guests/${id}/state"
    export PVE_CONFIG_MOCK_GUEST_ROOT
    PVE_CONFIG_MOCK_GUEST_ROOT=$(guest_root "${id}")
    tailscale "$@"
  )
}

# What the tailscale mock recorded as advertised.
advertised_routes() {
  cat "${PVE_CONFIG_MOCK_STATE}/guests/${1:-100}/state/tailscale_routes" 2>/dev/null || true
}

@test "20-tailscale builds the container, installs tailscale and joins the tailnet" {
  run run_tailscale
  [ "$status" -eq 0 ]

  [ -f "$(ct_conf 100)" ]
  grep -q '^hostname: ts-pve1$' "$(ct_conf 100)"
  grep -q '^unprivileged: 1$' "$(ct_conf 100)"
  grep -q '^features: nesting=1$' "$(ct_conf 100)"

  run grep -q 'tailscale' "$(guest_file 100 /etc/apt/sources.list.d/tailscale.sources)"
  [ "$status" -eq 0 ]
  [ -f "$(guest_file 100 /usr/share/keyrings/tailscale.gpg)" ]

  mock_calls | grep -q 'tailscale up '
  [ "$(advertised_routes 100)" = "${LAN_SUBNET}" ]
}

@test "a freshly built container ends up with both TUN lines and the device" {
  run run_tailscale
  [ "$status" -eq 0 ]

  grep -qxF 'lxc.cgroup2.devices.allow: c 10:200 rwm' "$(ct_conf 100)"
  grep -qxF 'lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file' "$(ct_conf 100)"
  [ -e "$(guest_file 100 /dev/net/tun)" ]
}

@test "20-tailscale adds the TUN lines to an adopted container that was built without them" {
  seed_ct 110
  export PVE_TAILSCALE_CTID=110

  run run_tailscale
  [ "$status" -eq 0 ]

  grep -qxF 'lxc.cgroup2.devices.allow: c 10:200 rwm' "$(ct_conf 110)"
  grep -qxF 'lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file' "$(ct_conf 110)"
  # It was not running, so the start that followed is what gave it the
  # device; nothing had to be rebooted.
  run grep -c 'pct reboot' <(mock_calls)
  [ "$output" = '0' ]
  [ -e "$(guest_file 110 /dev/net/tun)" ]
}

@test "20-tailscale restarts a running container that was missing the TUN lines" {
  seed_ct 110
  printf '110\n' >"${PVE_CONFIG_MOCK_STATE}/running"
  export PVE_TAILSCALE_CTID=110

  run run_tailscale
  [ "$status" -eq 0 ]

  mock_calls | grep -q '^pct reboot 110$'
  [ -e "$(guest_file 110 /dev/net/tun)" ]
}

@test "20-tailscale persists IPv4 forwarding and sets it now" {
  run run_tailscale
  [ "$status" -eq 0 ]

  grep -qxF 'net.ipv4.ip_forward = 1' \
    "$(guest_file 100 /etc/sysctl.d/99-tailscale-forwarding.conf)"
  grep -qxF 'net.ipv4.ip_forward=1' "${PVE_CONFIG_MOCK_STATE}/guests/100/state/sysctl"
}

@test "20-tailscale installs the advertise helper and enables its unit" {
  run run_tailscale
  [ "$status" -eq 0 ]

  local script
  script=$(guest_file 100 /usr/local/bin/ts-advertise-route.sh)
  [ -x "${script}" ]
  grep -q 'tailscale set --advertise-routes=' "${script}"
  grep -q 'After=network-online.target tailscaled.service' \
    "$(guest_file 100 /etc/systemd/system/ts-advertise-route.service)"
  grep -qxF 'ts-advertise-route.service' \
    "${PVE_CONFIG_MOCK_STATE}/guests/100/state/enabled"
  grep -qxF 'ts-advertise-route.service' \
    "${PVE_CONFIG_MOCK_STATE}/guests/100/state/active"
}

@test "detected routes leave the helper deriving them in the container" {
  # Provenance decides: nobody chose this list, so the helper keeps
  # working it out at every boot and a LAN renumber needs no rerun.
  run run_tailscale
  [ "$status" -eq 0 ]

  grep -qxF "CONFIGURED_ROUTES=''" \
    "$(guest_file 100 /usr/local/bin/ts-advertise-route.sh)"
  # The host-detected value still gets the first advertisement up.
  [ "$(advertised_routes 100)" = "${LAN_SUBNET}" ]
}

@test "the advertise helper derives the subnet when its baked list is blank" {
  run run_tailscale
  [ "$status" -eq 0 ]

  local script
  script=$(guest_file 100 /usr/local/bin/ts-advertise-route.sh)
  grep -qxF "CONFIGURED_ROUTES=''" "${script}"

  # Run the helper itself, against the ip mock's view of a container
  # whose default route is over an interface with a connected subnet.
  export PATH="${REPO_ROOT}/tests/helpers/mocks:${PATH}"
  export PVE_CONFIG_MOCK_STATE="${PVE_CONFIG_MOCK_STATE}/guests/100/state"
  export PVE_CONFIG_MOCK_GUEST_ROOT
  PVE_CONFIG_MOCK_GUEST_ROOT=$(guest_root 100)
  export PVE_CONFIG_MOCK_DEFAULT_DEV=mock0
  printf 'x\n' >"${PVE_CONFIG_MOCK_STATE}/tailscale_routes"

  run bash "${script}"
  [ "$status" -eq 0 ]
  [ "$(cat "${PVE_CONFIG_MOCK_STATE}/tailscale_routes")" = '192.0.2.0/24' ]
}

@test "a configured route list is advertised instead of the detected one" {
  export PVE_TAILSCALE_ROUTES='10.10.0.0/16,172.16.4.0/22'

  run run_tailscale
  [ "$status" -eq 0 ]
  [ "$(advertised_routes 100)" = '10.10.0.0/16,172.16.4.0/22' ]
  # Configured, so baked: an operator's list is not re-derived behind
  # their back, and the helper advertises exactly what they asked for.
  grep -qxF "CONFIGURED_ROUTES='10.10.0.0/16,172.16.4.0/22'" \
    "$(guest_file 100 /usr/local/bin/ts-advertise-route.sh)"
}

@test "a configured route list baked into the helper is what the helper advertises" {
  export PVE_TAILSCALE_ROUTES='10.10.0.0/16'

  run run_tailscale
  [ "$status" -eq 0 ]

  local script
  script=$(guest_file 100 /usr/local/bin/ts-advertise-route.sh)

  # Run the generated helper for real, in a container whose detected
  # subnet is a different one. The baked list must win.
  export PATH="${REPO_ROOT}/tests/helpers/mocks:${PATH}"
  export PVE_CONFIG_MOCK_STATE="${PVE_CONFIG_MOCK_STATE}/guests/100/state"
  export PVE_CONFIG_MOCK_GUEST_ROOT
  PVE_CONFIG_MOCK_GUEST_ROOT=$(guest_root 100)
  export PVE_CONFIG_MOCK_DEFAULT_DEV=mock0
  printf 'x\n' >"${PVE_CONFIG_MOCK_STATE}/tailscale_routes"

  run bash "${script}"
  [ "$status" -eq 0 ]
  [ "$(cat "${PVE_CONFIG_MOCK_STATE}/tailscale_routes")" = '10.10.0.0/16' ]
}

@test "a configured default route is advertised with a warning about what it does" {
  export PVE_TAILSCALE_ROUTES='10.0.0.0/8,0.0.0.0/0'

  run run_tailscale
  [ "$status" -eq 0 ]
  [[ "${output}" == *'0.0.0.0/0, a default route'* ]]
  [[ "${output}" == *'sends all of its traffic through this container'* ]]
  # Warned, not refused: the operator asked for it.
  [ "$(advertised_routes 100)" = '10.0.0.0/8,0.0.0.0/0' ]
}

@test "an ordinary configured route draws no default-route warning" {
  export PVE_TAILSCALE_ROUTES='192.168.1.0/24'

  run run_tailscale
  [ "$status" -eq 0 ]
  [[ "${output}" != *'default route'* ]]
  [ "$(advertised_routes 100)" = '192.168.1.0/24' ]
}

@test "a configured route that is not a CIDR stops the stage" {
  export PVE_TAILSCALE_ROUTES='192.168.1.0'

  run run_tailscale
  [ "$status" -ne 0 ]
  [[ "${output}" == *'not an IPv4 CIDR'* ]]
  run test -f "$(ct_conf 100)"
  [ "$status" -ne 0 ]
}

@test "a route with an out-of-range octet stops the stage" {
  export PVE_TAILSCALE_ROUTES='192.168.300.0/24'

  run run_tailscale
  [ "$status" -ne 0 ]
  [[ "${output}" == *'not an IPv4 CIDR'* ]]
}

@test "a route with an out-of-range prefix stops the stage" {
  export PVE_TAILSCALE_ROUTES='192.168.1.0/33'

  run run_tailscale
  [ "$status" -ne 0 ]
  [[ "${output}" == *'not an IPv4 CIDR'* ]]
}

@test "a bridge with no connected subnet stops the stage" {
  export PVE_CONFIG_MOCK_BRIDGE_IP=''

  run run_tailscale
  [ "$status" -ne 0 ]
  [[ "${output}" == *'Unable to read the IPv4 subnet of vmbr0'* ]]
}

@test "20-tailscale is a no-op when it is not enabled" {
  export PVE_TAILSCALE_ENABLED='no'

  run run_tailscale
  [ "$status" -eq 0 ]
  [[ "${output}" == *'not building a Tailscale subnet router'* ]]
  run test -f "$(ct_conf 100)"
  [ "$status" -ne 0 ]
}

@test "20-tailscale converges on a second run" {
  assert_stage_converges_with run_phase2_stage 20-tailscale.sh
}

@test "20-tailscale converges on a second run with routes configured" {
  export PVE_TAILSCALE_ROUTES='10.10.0.0/16'
  assert_stage_converges_with run_phase2_stage 20-tailscale.sh
}

@test "20-tailscale makes no mutating call under a dry run" {
  export PVE_CONFIG_DRY_RUN=1

  run run_tailscale
  [ "$status" -eq 0 ]
  assert_no_mutating_calls
  run test -f "$(ct_conf 100)"
  [ "$status" -ne 0 ]
}

@test "a dry run over an adoptable container tags nothing" {
  seed_ct 110 'unrelated-service' ''
  export PVE_TAILSCALE_CTID=110
  export PVE_TAILSCALE_ADOPT_EXISTING='yes'
  export PVE_CONFIG_DRY_RUN=1

  run run_tailscale
  [ "$status" -eq 0 ]
  assert_no_mutating_calls
  run grep -F 'tags:' "$(ct_conf 110)"
  [ "$status" -ne 0 ]
}

@test "a dry run over a converged deployment still changes nothing" {
  run run_tailscale
  [ "$status" -eq 0 ]

  : >"${PVE_CONFIG_MOCK_LOG}"
  local before after
  before=$(state_fingerprint)
  export PVE_CONFIG_DRY_RUN=1
  run run_tailscale
  [ "$status" -eq 0 ]
  after=$(state_fingerprint)
  [ "${before}" = "${after}" ]
  assert_no_mutating_calls
}

@test "the auth key reaches no argument list, no log line and no child environment" {
  run run_tailscale
  [ "$status" -eq 0 ]
  # `run` replaces $output, so the stage's own output is kept aside.
  local stage_output=${output}

  [[ "${stage_output}" != *"${AUTHKEY}"* ]]
  run grep -F "${AUTHKEY}" <(mock_calls)
  [ "$status" -ne 0 ]
  run grep -F "${AUTHKEY}" <(mock_env)
  [ "$status" -ne 0 ]
  run grep -rlF "${AUTHKEY}" "${PVE_CONFIG_ROOT}"
  [ "$status" -ne 0 ]
}

@test "the auth key file is removed from the container after the login" {
  run run_tailscale
  [ "$status" -eq 0 ]

  run test -e "$(guest_file 100 /etc/pve-config/tailscale.authkey)"
  [ "$status" -ne 0 ]
  mock_calls | grep -q 'tailscale up --auth-key=file:/etc/pve-config/tailscale.authkey'
}

@test "the auth key file is removed even when the login fails" {
  export PVE_CONFIG_MOCK_TAILSCALE_UP_FAIL=1

  run run_tailscale
  [ "$status" -ne 0 ]
  [[ "${output}" == *"'tailscale up' failed"* ]]
  run test -e "$(guest_file 100 /etc/pve-config/tailscale.authkey)"
  [ "$status" -ne 0 ]
}

@test "a stale key left by an interrupted run is removed before the probe" {
  run run_tailscale
  [ "$status" -eq 0 ]

  # What a run killed between writing the key and removing it leaves.
  seed_guest_file 100 /etc/pve-config/tailscale.authkey "${AUTHKEY}"
  : >"${PVE_CONFIG_MOCK_LOG}"

  run run_tailscale
  [ "$status" -eq 0 ]
  [[ "${output}" == *'already joined to the tailnet'* ]]
  run test -e "$(guest_file 100 /etc/pve-config/tailscale.authkey)"
  [ "$status" -ne 0 ]
}

@test "a key that cannot be removed fails the run loudly" {
  export PVE_CONFIG_MOCK_PCT_FAIL_RM=/etc/pve-config/tailscale.authkey

  run run_tailscale
  [ "$status" -ne 0 ]
  [[ "${output}" == *'Unable to remove /etc/pve-config/tailscale.authkey'* ]]
  [[ "${output}" == *'revoke the key'* ]]
}

@test "a removal that reports success but leaves the key fails the run" {
  export PVE_CONFIG_MOCK_PCT_RM_NOOP=/etc/pve-config/tailscale.authkey

  run run_tailscale
  [ "$status" -ne 0 ]
  [[ "${output}" == *'Unable to remove /etc/pve-config/tailscale.authkey'* ]]
  # The file really is still there: the run is telling the truth about
  # what it could not do.
  [ -e "$(guest_file 100 /etc/pve-config/tailscale.authkey)" ]
}

@test "a transport failure during the login still clears the key" {
  export PVE_CONFIG_MOCK_PCT_EXEC_FAIL='tailscale up'

  run run_tailscale
  [ "$status" -ne 0 ]
  run test -e "$(guest_file 100 /etc/pve-config/tailscale.authkey)"
  [ "$status" -ne 0 ]
}

@test "a converged deployment re-runs after the spent key has been revoked" {
  run run_tailscale
  [ "$status" -eq 0 ]

  # The responsible thing to do with a used one-off key.
  printf "PVE_DNSMADEEASY_KEY='x'\n" >"${SECRETS}"
  chmod 600 "${SECRETS}"

  run run_tailscale
  [ "$status" -eq 0 ]
  [[ "${output}" == *'already joined to the tailnet'* ]]
}

@test "a container that still needs a login says the key is required" {
  seed_ct 110
  export PVE_TAILSCALE_CTID=110
  printf "PVE_DNSMADEEASY_KEY='x'\n" >"${SECRETS}"
  chmod 600 "${SECRETS}"
  export PVE_CONFIG_MOCK_TAILSCALE_STATUS_JSON='{"BackendState":"NeedsLogin"}'

  run run_tailscale
  [ "$status" -ne 0 ]
  [[ "${output}" == *'PVE_TAILSCALE_AUTHKEY is required'* ]]
}

@test "the repository key is refused when it is not the pinned one" {
  export PVE_CONFIG_MOCK_KEYRING_PAYLOAD='not the tailscale signing key'

  run run_tailscale
  [ "$status" -ne 0 ]
  [[ "${output}" == *'not the pinned'* ]]
  run test -e "$(guest_file 100 /usr/share/keyrings/tailscale.gpg)"
  [ "$status" -ne 0 ]
  # Nothing was installed from the repository it would have signed.
  run grep -F 'apt-get install -y tailscale' <(mock_calls)
  [ "$status" -ne 0 ]
}

@test "a keyring already in place is checked rather than trusted" {
  run run_tailscale
  [ "$status" -eq 0 ]

  # A rotated, corrupt or planted key: present and non-empty, wrong.
  seed_guest_file 100 /usr/share/keyrings/tailscale.gpg 'planted'
  : >"${PVE_CONFIG_MOCK_LOG}"

  run run_tailscale
  [ "$status" -eq 0 ]
  [[ "${output}" == *'not the pinned'* ]]
  [ "$(cat "$(guest_file 100 /usr/share/keyrings/tailscale.gpg)")" = \
    "${KEYRING_PAYLOAD}" ]
}

@test "a pinned digest that is not a digest stops the stage" {
  export PVE_TAILSCALE_KEYRING_SHA256='deadbeef'

  run run_tailscale
  [ "$status" -ne 0 ]
  [[ "${output}" == *'64 hex'* ]]
}

@test "a missing auth key stops the stage before anything is built" {
  printf "PVE_DNSMADEEASY_KEY='x'\n" >"${SECRETS}"
  chmod 600 "${SECRETS}"

  run run_tailscale
  [ "$status" -ne 0 ]
  [[ "${output}" == *'PVE_TAILSCALE_AUTHKEY is required'* ]]
  run test -f "$(ct_conf 100)"
  [ "$status" -ne 0 ]
}

@test "an auth key that is not shaped like one stops the stage" {
  printf "PVE_TAILSCALE_AUTHKEY='not-a-key'\n" >"${SECRETS}"
  chmod 600 "${SECRETS}"

  run run_tailscale
  [ "$status" -ne 0 ]
  [[ "${output}" == *'begin with tskey-'* ]]
}

@test "an auth key set but empty in the environment is an error, not a fallback" {
  export PVE_TAILSCALE_AUTHKEY=''

  run run_tailscale
  [ "$status" -ne 0 ]
  [[ "${output}" == *'set in the environment but empty'* ]]
}

@test "an auth key in the environment wins over the one on disk" {
  # The key never reaches an argument list, so precedence is shown by
  # which of the two is validated: the file holds a well-formed key.
  export PVE_TAILSCALE_AUTHKEY='nope-not-a-key'

  run run_tailscale
  [ "$status" -ne 0 ]
  [[ "${output}" == *'begin with tskey-'* ]]
  [[ "${output}" != *'nope-not-a-key'* ]]
}

@test "tracing already on with the key in the environment refuses to run" {
  export PVE_TAILSCALE_AUTHKEY="${AUTHKEY}"

  run bash -x "${REPO_ROOT}/stages/phase2/20-tailscale.sh"
  [ "$status" -eq 1 ]
  [[ "${output}" == *'refusing to run the Tailscale stage with tracing already enabled'* ]]
  run grep -F "${AUTHKEY}" <(printf '%s' "${output}")
  [ "$status" -ne 0 ]
}

@test "the secrets of other stages do not reach the container builder" {
  # The driver exports every key it read from secrets.env, so a stage
  # child really does inherit all of them; running the stage on its own
  # would not model that.
  export PVE_DNSMADEEASY_KEY='me-key-4f2a9c'
  # Supplied through the environment rather than the file, which is what
  # the driver tells its children about in PVE_CONFIG_SECRET_KEYS.
  export PVE_ZULIP_BOT_API_KEY='zulip-4f2a9c'
  export PVE_CONFIG_SECRET_KEYS='PVE_ZULIP_BOT_API_KEY'
  export PVE_CONFIG_MOCK_BUILDER_ENV="${BATS_TEST_TMPDIR}/builder.env"

  run run_tailscale
  [ "$status" -eq 0 ]
  [ -s "${PVE_CONFIG_MOCK_BUILDER_ENV}" ]
  run grep -F 'me-key-4f2a9c' "${PVE_CONFIG_MOCK_BUILDER_ENV}"
  [ "$status" -ne 0 ]
  run grep -F 'zulip-4f2a9c' "${PVE_CONFIG_MOCK_BUILDER_ENV}"
  [ "$status" -ne 0 ]
  # Still reachable: the scrub is a list of secret names, not of
  # everything.
  grep -q '^PVE_CONFIG_ROOT=' "${PVE_CONFIG_MOCK_BUILDER_ENV}"
}

@test "the container builder is fetched through the pin and told the core pin" {
  run run_tailscale
  [ "$status" -eq 0 ]
  mock_calls | grep -q "curl -fsSL ${COMMUNITY_SCRIPTS_URL}/ct/debian.sh -o "
}

@test "the builder is told mode=default so it never reaches a settings menu" {
  run run_tailscale
  [ "$status" -eq 0 ]
  grep -q '^ct/debian.sh mode=default ' "${PVE_CONFIG_MOCK_LOG}"
  grep -q ' var_tun=yes var_unprivileged=1 var_nesting=1 ' "${PVE_CONFIG_MOCK_LOG}"
}

@test "the builder is told to build the container without IPv6" {
  run run_tailscale
  [ "$status" -eq 0 ]
  grep -q ' var_ipv6_method=none$' "${PVE_CONFIG_MOCK_LOG}"
}

@test "the builder fixture really does refuse a create with no IPv6 answer" {
  # Proves the guard the test above relies on is live.
  run env -u var_ipv6_method mode=default COMMUNITY_SCRIPTS_CORE_URL=x \
    var_ctid=100 var_hostname=ts-pve1 var_template_storage=local \
    var_container_storage=local var_unprivileged=1 \
    bash "${REPO_ROOT}/tests/helpers/community-scripts/ct/debian.sh"
  [ "$status" -ne 0 ]
  [[ "${output}" == *'IPv6 menu would be waiting for a terminal'* ]]

  run env var_ipv6_method=dhcp mode=default COMMUNITY_SCRIPTS_CORE_URL=x \
    var_ctid=100 var_hostname=ts-pve1 var_template_storage=local \
    var_container_storage=local var_unprivileged=1 \
    bash "${REPO_ROOT}/tests/helpers/community-scripts/ct/debian.sh"
  [ "$status" -ne 0 ]
  [[ "${output}" == *'built without IPv6'* ]]
}

@test "the builder fixture really does refuse a create with no mode" {
  # Proves the guard the test above relies on is live: without it the
  # toolkit could drop mode=default and nothing would notice.
  run env -u mode COMMUNITY_SCRIPTS_CORE_URL=x var_ctid=100 \
    var_hostname=ts-pve1 var_template_storage=local \
    var_container_storage=local var_unprivileged=1 \
    bash "${REPO_ROOT}/tests/helpers/community-scripts/ct/debian.sh"
  [ "$status" -ne 0 ]
  [[ "${output}" == *'settings menu would be waiting for a terminal'* ]]
}

@test "a builder that cannot be fetched through the pin fails the stage" {
  export PVE_CONFIG_MOCK_CURL_FAIL_URL='/ct/debian.sh'

  run run_tailscale
  [ "$status" -ne 0 ]
  [[ "${output}" == *'Unable to fetch the pinned container builder'* ]]
  run test -f "$(ct_conf 100)"
  [ "$status" -ne 0 ]
}

@test "a container carrying this toolkit's tag is adopted rather than rebuilt" {
  seed_ct 143

  run run_tailscale
  [ "$status" -eq 0 ]
  [[ "${output}" == *'adopting existing container 143'* ]]
  run test -f "$(ct_conf 100)"
  [ "$status" -ne 0 ]
  # Nothing was built: the builder records a line of its own when it runs.
  run grep -c '^ct/debian.sh ' "${PVE_CONFIG_MOCK_LOG}"
  [ "$output" = '0' ]
  [ -f "$(guest_file 143 /etc/apt/sources.list.d/tailscale.sources)" ]
}

@test "a pinned id holding somebody else's container is refused" {
  seed_ct 110 'unrelated-service' ''
  export PVE_TAILSCALE_CTID=110

  run run_tailscale
  [ "$status" -ne 0 ]
  [[ "${output}" == *"does not carry the ${OWNER_TAG} tag"* ]]
  [[ "${output}" == *'PVE_TAILSCALE_ADOPT_EXISTING=yes'* ]]
  # Nothing was done to it at all.
  run grep -F 'lxc.cgroup2.devices.allow' "$(ct_conf 110)"
  [ "$status" -ne 0 ]
  run grep -F 'pct ' <(mock_calls)
  [ "$status" -ne 0 ]
  run test -e "$(guest_file 110 /etc/apt/sources.list.d/tailscale.sources)"
  [ "$status" -ne 0 ]
}

@test "an untagged container is adopted only when the operator asks for it" {
  seed_ct 110 'unrelated-service' ''
  export PVE_TAILSCALE_CTID=110
  export PVE_TAILSCALE_ADOPT_EXISTING='yes'

  run run_tailscale
  [ "$status" -eq 0 ]
  [[ "${output}" == *'adopting pre-existing container 110'* ]]
  grep -qxF 'lxc.cgroup2.devices.allow: c 10:200 rwm' "$(ct_conf 110)"
}

@test "a container this toolkit built is given the ownership tag" {
  run run_tailscale
  [ "$status" -eq 0 ]
  grep -qxF "tags: ${OWNER_TAG}" "$(ct_conf 100)"
  mock_calls | grep -q "^pct set 100 -tags ${OWNER_TAG}$"
}

@test "the ownership tag is added beside the tags a container already carries" {
  seed_ct 110 'ts-pve1' 'homelab;network'
  export PVE_TAILSCALE_CTID=110
  export PVE_TAILSCALE_ADOPT_EXISTING='yes'

  run run_tailscale
  [ "$status" -eq 0 ]
  grep -qxF "tags: homelab;network;${OWNER_TAG}" "$(ct_conf 110)"
}

@test "a container that already carries the tag is not re-tagged" {
  run run_tailscale
  [ "$status" -eq 0 ]

  : >"${PVE_CONFIG_MOCK_LOG}"
  run run_tailscale
  [ "$status" -eq 0 ]
  run grep -F 'pct set' <(mock_calls)
  [ "$status" -ne 0 ]
}

@test "a tagged router on another node stops the stage" {
  export PVE_CONFIG_MOCK_CLUSTER_REMOTE='131:pve2'

  run run_tailscale
  [ "$status" -ne 0 ]
  [[ "${output}" == *'on node pve2'* ]]
  [[ "${output}" == *'131'* ]]
  run test -f "$(ct_conf 100)"
  [ "$status" -ne 0 ]
}

@test "a cluster listing that cannot be read stops the stage" {
  export PVE_CONFIG_MOCK_CLUSTER_FAIL=1

  run run_tailscale
  [ "$status" -ne 0 ]
  [[ "${output}" == *"Unable to read 'pvesh get /cluster/resources"* ]]
  run test -f "$(ct_conf 100)"
  [ "$status" -ne 0 ]
}

@test "a cluster listing that will not decode stops the stage" {
  export PVE_CONFIG_MOCK_CLUSTER_JSON='[{"type":"lxc","vmid":'

  run run_tailscale
  [ "$status" -ne 0 ]
  [[ "${output}" == *"Unable to read 'pvesh get /cluster/resources"* ]]
}

@test "two tagged routers on this node stop the stage rather than picking one" {
  seed_ct 141
  seed_ct 142

  run run_tailscale
  [ "$status" -ne 0 ]
  [[ "${output}" == *'More than one container on this node carries'* ]]
}

@test "a pinned id that is not the tagged container stops the stage" {
  seed_ct 143
  export PVE_TAILSCALE_CTID=150

  run run_tailscale
  [ "$status" -ne 0 ]
  [[ "${output}" == *'PVE_TAILSCALE_CTID is 150'* ]]
  [[ "${output}" == *'143'* ]]
}

@test "the next free id is used when 100 is taken by something else" {
  mkdir -p "$(dirname -- "$(ct_conf 100)")"
  printf 'arch: amd64\nhostname: other\nostype: debian\n' >"$(ct_conf 100)"
  export PVE_CONFIG_MOCK_NEXTID=137

  run run_tailscale
  [ "$status" -eq 0 ]
  [ -f "$(ct_conf 137)" ]
  grep -q '^hostname: ts-pve1$' "$(ct_conf 137)"
}

@test "a pinned container id is used as given" {
  export PVE_TAILSCALE_CTID=250

  run run_tailscale
  [ "$status" -eq 0 ]
  [ -f "$(ct_conf 250)" ]
  run test -f "$(ct_conf 100)"
  [ "$status" -ne 0 ]
}

@test "a container id below the Proxmox floor stops the stage" {
  export PVE_TAILSCALE_CTID=42

  run run_tailscale
  [ "$status" -ne 0 ]
  [[ "${output}" == *'container ids run from 100'* ]]
}

@test "a container id that is not a number stops the stage" {
  export PVE_TAILSCALE_CTID='one hundred'

  run run_tailscale
  [ "$status" -ne 0 ]
  [[ "${output}" == *'not a container id'* ]]
}

@test "a hostname that is not a DNS label stops the stage" {
  export PVE_TAILSCALE_HOSTNAME='Ts Pve1'

  run run_tailscale
  [ "$status" -ne 0 ]
  [[ "${output}" == *'not a container hostname'* ]]
}

@test "more than one container storage with none configured stops the stage" {
  export PVE_CONFIG_MOCK_PVESM_ROOTDIR='local-lvm local-zfs'

  run run_tailscale
  [ "$status" -ne 0 ]
  [[ "${output}" == *'more than one storage'* ]]
  run test -f "$(ct_conf 100)"
  [ "$status" -ne 0 ]
}

@test "template and container storage are resolved apart" {
  # The layout almost every Proxmox node has: templates on local, root
  # disks on a pool that holds no templates at all.
  export PVE_CONFIG_MOCK_PVESM_VZTMPL='local'
  export PVE_CONFIG_MOCK_PVESM_ROOTDIR='local-lvm'

  run run_tailscale
  [ "$status" -eq 0 ]
  grep -q ' var_template_storage=local var_container_storage=local-lvm ' \
    "${PVE_CONFIG_MOCK_LOG}"
}

@test "one storage named for both is refused when it cannot hold both" {
  export PVE_CONFIG_MOCK_PVESM_VZTMPL='local'
  export PVE_CONFIG_MOCK_PVESM_ROOTDIR='local-lvm local-zfs'
  export PVE_TAILSCALE_STORAGE='local-zfs'

  run run_tailscale
  [ "$status" -ne 0 ]
  [[ "${output}" == *"PVE_TAILSCALE_STORAGE names 'local-zfs'"* ]]
  [[ "${output}" == *"accepts 'vztmpl' content"* ]]
  run test -f "$(ct_conf 100)"
  [ "$status" -ne 0 ]
}

@test "the two storages can be named separately" {
  export PVE_CONFIG_MOCK_PVESM_VZTMPL='local backups'
  export PVE_CONFIG_MOCK_PVESM_ROOTDIR='local-lvm local-zfs'
  export PVE_TAILSCALE_TEMPLATE_STORAGE='local'
  export PVE_TAILSCALE_CONTAINER_STORAGE='local-zfs'

  run run_tailscale
  [ "$status" -eq 0 ]
  grep -q ' var_template_storage=local var_container_storage=local-zfs ' \
    "${PVE_CONFIG_MOCK_LOG}"
}

@test "a container storage that is not on this node is refused by name" {
  export PVE_CONFIG_MOCK_PVESM_ROOTDIR='local-lvm'
  export PVE_TAILSCALE_CONTAINER_STORAGE='nvme-pool'

  run run_tailscale
  [ "$status" -ne 0 ]
  [[ "${output}" == *"PVE_TAILSCALE_CONTAINER_STORAGE names 'nvme-pool'"* ]]
}

@test "a node with no template storage says so rather than guessing" {
  export PVE_CONFIG_MOCK_PVESM_VZTMPL=''

  run run_tailscale
  [ "$status" -ne 0 ]
  [[ "${output}" == *"No storage on this node accepts 'vztmpl' content"* ]]
}

@test "the community-scripts defaults are put back after the build" {
  local vars="${PVE_CONFIG_ROOT}/usr/local/community-scripts/default.vars"
  mkdir -p "$(dirname -- "${vars}")"
  printf 'var_container_storage=somebody-elses\nvar_verbose=yes\n' >"${vars}"

  run run_tailscale
  [ "$status" -eq 0 ]
  # The builder saw ours...
  grep -q '^ct/debian.sh default.vars var_template_storage=local var_container_storage=local $' \
    "${PVE_CONFIG_MOCK_LOG}"
  # ...and the host kept its own.
  run cat "${vars}"
  [ "$output" = 'var_container_storage=somebody-elses
var_verbose=yes' ]
}

@test "a node with no community-scripts defaults is left with none" {
  run run_tailscale
  [ "$status" -eq 0 ]
  run test -e "${PVE_CONFIG_ROOT}/usr/local/community-scripts/default.vars"
  [ "$status" -ne 0 ]
}

@test "the defaults are put back even when the builder fails" {
  local vars="${PVE_CONFIG_ROOT}/usr/local/community-scripts/default.vars"
  mkdir -p "$(dirname -- "${vars}")"
  printf 'var_verbose=yes\n' >"${vars}"
  # pct cannot reach that id, so the builder fails after the answers have
  # been put in place.
  export PVE_CONFIG_MOCK_PCT_FAIL_VMID=100

  run run_tailscale
  [ "$status" -ne 0 ]
  run cat "${vars}"
  [ "$output" = 'var_verbose=yes' ]
}

@test "resources are scaled to the host" {
  export PVE_CONFIG_MEMINFO="${BATS_TEST_TMPDIR}/meminfo"
  printf 'MemTotal:       33554432 kB\n' >"${PVE_CONFIG_MEMINFO}"

  run run_tailscale
  [ "$status" -eq 0 ]
  # 32768 MB / 64 is 512, inside the 256..1024 band.
  grep -qxF 'memory: 512' "$(ct_conf 100)"
}

@test "a small host still gets the floor rather than something unbootable" {
  export PVE_CONFIG_MEMINFO="${BATS_TEST_TMPDIR}/meminfo"
  printf 'MemTotal:        4194304 kB\n' >"${PVE_CONFIG_MEMINFO}"

  run run_tailscale
  [ "$status" -eq 0 ]
  grep -qxF 'memory: 256' "$(ct_conf 100)"
}

@test "a very large host is capped rather than given a share of everything" {
  export PVE_CONFIG_MEMINFO="${BATS_TEST_TMPDIR}/meminfo"
  printf 'MemTotal:      536870912 kB\n' >"${PVE_CONFIG_MEMINFO}"

  run run_tailscale
  [ "$status" -eq 0 ]
  grep -qxF 'memory: 1024' "$(ct_conf 100)"
}

@test "a configured memory size overrides the scaling" {
  export PVE_TAILSCALE_RAM_MB=2048

  run run_tailscale
  [ "$status" -eq 0 ]
  grep -qxF 'memory: 2048' "$(ct_conf 100)"
}

@test "a container that reports an unusable release name stops the stage" {
  run run_tailscale
  [ "$status" -eq 0 ]

  # A second deployment, on a container whose os-release has been
  # tampered with: the codename goes into an apt source and a command
  # line, so it is held to the shape of a Debian release name.
  seed_guest_file 100 /etc/os-release 'VERSION_CODENAME=; rm -rf /
'
  rm -f "$(guest_file 100 /usr/share/keyrings/tailscale.gpg)"

  run run_tailscale
  [ "$status" -ne 0 ]
  [[ "${output}" == *'not a Debian release name'* ]]
}

@test "a second run finds the container joined and spends no key" {
  run run_tailscale
  [ "$status" -eq 0 ]

  : >"${PVE_CONFIG_MOCK_LOG}"
  run run_tailscale
  [ "$status" -eq 0 ]
  [[ "${output}" == *'already joined to the tailnet'* ]]
  run grep -F 'tailscale up' <(mock_calls)
  [ "$status" -ne 0 ]
}

# Drives the probe against a container that is already built and joined,
# so the only thing varying is what the daemon answers with.
# Build a working container, then run again with whatever the test has
# said the daemon should answer.
#
# The knobs are held back for the first run. Every real container is
# probed now, including the one this build has just made, so a document
# meant for the second run would otherwise be answered to the first and
# stop the build before there was anything to probe.
probe_rerun() {
  local knob saved=() present=()
  local -r knobs=(
    PVE_CONFIG_MOCK_TAILSCALE_STATUS_JSON
    PVE_CONFIG_MOCK_TAILSCALE_STATUS_FAIL
    PVE_CONFIG_MOCK_TAILSCALE_STATE
  )
  for knob in "${knobs[@]}"; do
    present+=("${!knob+set}")
    saved+=("${!knob-}")
    unset "${knob}"
  done

  run run_tailscale
  [ "$status" -eq 0 ]

  local i=0
  for knob in "${knobs[@]}"; do
    if [[ -n ${present[i]} ]]; then
      export "${knob}=${saved[i]}"
    fi
    i=$((i + 1))
  done

  : >"${PVE_CONFIG_MOCK_LOG}"
  run run_tailscale
}

@test "a peer named after the backend state does not fool the probe" {
  # Nested inside a peer, and nowhere else: a probe reading the first
  # thing that resembles the field would call this machine logged in.
  export PVE_CONFIG_MOCK_TAILSCALE_STATUS_JSON='{"Version":"1.80.0","Peer":{"nodekey:dead":{"HostName":"x","BackendState":"Running"}},"Self":{"HostName":"ts-test"}}'

  probe_rerun
  [ "$status" -ne 0 ]
  [[ "${output}" == *'Refusing to spend an auth key'* ]]
  run grep -F 'tailscale up' <(mock_calls)
  [ "$status" -ne 0 ]
}

@test "a status document that will not decode stops the run" {
  export PVE_CONFIG_MOCK_TAILSCALE_STATUS_JSON='{"BackendState":"Running"'

  probe_rerun
  [ "$status" -ne 0 ]
  [[ "${output}" == *'Refusing to spend an auth key'* ]]
}

@test "a status document naming the state twice stops the run" {
  export PVE_CONFIG_MOCK_TAILSCALE_STATUS_JSON='{"BackendState":"NeedsLogin","BackendState":"Running"}'

  probe_rerun
  [ "$status" -ne 0 ]
  [[ "${output}" == *'Refusing to spend an auth key'* ]]
}

@test "a status document with no backend state at all stops the run" {
  export PVE_CONFIG_MOCK_TAILSCALE_STATUS_JSON='{"Version":"1.80.0"}'

  probe_rerun
  [ "$status" -ne 0 ]
  [[ "${output}" == *'Refusing to spend an auth key'* ]]
}

@test "a backend state this toolkit does not know stops the run" {
  export PVE_CONFIG_MOCK_TAILSCALE_STATUS_JSON='{"BackendState":"Rebooting"}'

  probe_rerun
  [ "$status" -ne 0 ]
  [[ "${output}" == *'Refusing to spend an auth key'* ]]
}

@test "a backend state that is not a string stops the run" {
  export PVE_CONFIG_MOCK_TAILSCALE_STATUS_JSON='{"BackendState":["Running"]}'

  probe_rerun
  [ "$status" -ne 0 ]
  [[ "${output}" == *'Refusing to spend an auth key'* ]]
}

@test "a status command that fails stops the run rather than spending a key" {
  export PVE_CONFIG_MOCK_TAILSCALE_STATUS_FAIL=1

  probe_rerun
  [ "$status" -ne 0 ]
  [[ "${output}" == *'Refusing to spend an auth key'* ]]
  run grep -F 'tailscale up' <(mock_calls)
  [ "$status" -ne 0 ]
}

@test "a daemon that is logged in but stopped is brought back up with no key" {
  run run_tailscale
  [ "$status" -eq 0 ]

  # `tailscale down` in the container: the machine keeps its identity and
  # stops routing. A subnet router that routes nothing is not converged.
  guest_tailscale 100 down

  # The spent key is revoked, the way a careful operator would. Nothing
  # on this path may need one.
  : >"${SECRETS}"
  unset PVE_TAILSCALE_AUTHKEY
  : >"${PVE_CONFIG_MOCK_LOG}"

  run run_tailscale
  [ "$status" -eq 0 ]
  [[ "${output}" == *'logged in but stopped'* ]]
  # Logged only when the stage changed something on this path.
  [[ "${output}" == *'brought container 100 back up'* ]]

  # It was brought up, and without a key.
  mock_calls | grep -q 'tailscale up '
  run grep -F -- '--auth-key' <(mock_calls)
  [ "$status" -ne 0 ]
  [ "$(advertised_routes 100)" = "${LAN_SUBNET}" ]

  # And the run after that finds nothing left to do.
  : >"${PVE_CONFIG_MOCK_LOG}"
  run run_tailscale
  [ "$status" -eq 0 ]
  [[ "${output}" == *'already joined'* ]]
  run grep -F 'tailscale up' <(mock_calls)
  [ "$status" -ne 0 ]
}

@test "a restarted node is not told it just spent a key" {
  run run_tailscale
  [ "$status" -eq 0 ]
  [[ "${output}" == *'Disable key expiry for ts-pve1'* ]]

  guest_tailscale 100 down
  : >"${PVE_CONFIG_MOCK_LOG}"

  run run_tailscale
  [ "$status" -eq 0 ]
  # The reminder still fires, because an expired key is one reason a node
  # stops -- but worded for a restart, not for a first join.
  [[ "${output}" == *'was logged in but stopped, and has been brought back up'* ]]
  [[ "${output}" == *'check whether key expiry is disabled'* ]]
  [[ "${output}" != *'Disable key expiry for ts-pve1'* ]]
}

@test "a dry run over a stopped daemon brings nothing up" {
  run run_tailscale
  [ "$status" -eq 0 ]
  guest_tailscale 100 down
  : >"${PVE_CONFIG_MOCK_LOG}"
  export PVE_CONFIG_DRY_RUN=1

  run run_tailscale
  [ "$status" -eq 0 ]
  [[ "${output}" == *'would bring container 100 back up'* ]]
  assert_no_mutating_calls
}

@test "an adoption gate that is neither yes nor no stops the stage" {
  export PVE_TAILSCALE_CTID=110
  export PVE_TAILSCALE_ADOPT_EXISTING=true
  seed_ct 110 '' unrelated-service

  run run_tailscale
  [ "$status" -ne 0 ]
  [[ "${output}" == *"is 'true'"* ]]
  [[ "${output}" == *'neither yes nor no'* ]]
  assert_no_mutating_calls
}

@test "a container that kept its identity across a package reinstall gets no second key" {
  run run_tailscale
  [ "$status" -eq 0 ]

  # dpkg without --purge leaves /var/lib/tailscale behind, so the machine
  # is still a tailnet member with the package gone. The next run
  # reinstalls it -- and must still ask the daemon who it is rather than
  # reading "we installed something" as "it cannot be logged in".
  local pkgs="${PVE_CONFIG_MOCK_STATE}/guests/100/state/packages"
  grep -vxF tailscale "${pkgs}" >"${pkgs}.new"
  mv -f -- "${pkgs}.new" "${pkgs}"
  grep -qxF up "${PVE_CONFIG_MOCK_STATE}/guests/100/state/tailnet"

  # The spent key is revoked, the way a careful operator would.
  : >"${SECRETS}"
  unset PVE_TAILSCALE_AUTHKEY
  : >"${PVE_CONFIG_MOCK_LOG}"

  run run_tailscale
  [ "$status" -eq 0 ]
  # It really did reinstall, so the branch under test was reached.
  mock_calls | grep -q 'apt-get install -y tailscale'
  [[ "${output}" == *'already joined'* ]]
  run grep -F 'tailscale up' <(mock_calls)
  [ "$status" -ne 0 ]
}

@test "a key spelled with a unicode escape cannot smuggle in a duplicate" {
  # A decoder reads \u0042ackendState and BackendState as one key and
  # keeps the last; a lexer comparing raw spellings sees two different
  # keys, counts one of each, and lets the forgery through as NeedsLogin.
  export PVE_CONFIG_MOCK_TAILSCALE_STATUS_JSON='{"\u0042ackendState":"Running","BackendState":"NeedsLogin"}'

  probe_rerun
  [ "$status" -ne 0 ]
  [[ "${output}" == *'Refusing to spend an auth key'* ]]
  run grep -F 'tailscale up' <(mock_calls)
  [ "$status" -ne 0 ]
}

@test "an escaped spelling of the field is still read as that field" {
  # The other half: decoding the key must not stop a document that names
  # it once, however it is spelled, from being read.
  export PVE_CONFIG_MOCK_TAILSCALE_STATUS_JSON='{"\u0042ackendState":"Running"}'

  probe_rerun
  [ "$status" -eq 0 ]
  [[ "${output}" == *'already joined'* ]]
  run grep -F 'tailscale up' <(mock_calls)
  [ "$status" -ne 0 ]
}

@test "a daemon that says NeedsLogin is the one case a key is spent on" {
  export PVE_CONFIG_MOCK_TAILSCALE_STATUS_JSON='{"BackendState":"NeedsLogin"}'

  probe_rerun
  [ "$status" -eq 0 ]
  mock_calls | grep -q 'tailscale up '
}

@test "a tailnet that wants machine approval says so instead of spending keys" {
  export PVE_CONFIG_MOCK_TAILSCALE_STATUS_JSON='{"BackendState":"NeedsMachineAuth"}'

  probe_rerun
  [ "$status" -ne 0 ]
  [[ "${output}" == *'waiting for machine authorisation'* ]]
  run grep -F 'tailscale up' <(mock_calls)
  [ "$status" -ne 0 ]
}

@test "the stage warns about key expiry when it has just joined" {
  run run_tailscale
  [ "$status" -eq 0 ]
  [[ "${output}" == *'Disable key expiry'* ]]
}

@test "the stage says the telemetry answer is about to be given for you" {
  run run_tailscale
  [ "$status" -eq 0 ]
  [[ "${output}" == *'will record DIAGNOSTICS=no for you'* ]]
}

@test "a node that has already answered about telemetry is not warned" {
  mkdir -p "${PVE_CONFIG_ROOT}/usr/local/community-scripts"
  printf 'DIAGNOSTICS=yes\n' \
    >"${PVE_CONFIG_ROOT}/usr/local/community-scripts/diagnostics"

  run run_tailscale
  [ "$status" -eq 0 ]
  [[ "${output}" != *'DIAGNOSTICS=no for you'* ]]
}

@test "a detected subnet that is not a CIDR stops the stage rather than being advertised" {
  # The host's own route table is not trusted blindly: whatever comes out
  # of it goes into --advertise-routes and into a generated script.
  export PVE_CONFIG_MOCK_BRIDGE_ROUTE='192.0.2.0/0024'

  run run_tailscale
  [ "$status" -ne 0 ]
  [[ "${output}" == *'not an IPv4 CIDR'* ]]
  run test -f "$(ct_conf 100)"
  [ "$status" -ne 0 ]
}
