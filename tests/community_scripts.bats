#!/usr/bin/env bats
# SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
# SPDX-License-Identifier: Apache-2.0

# The community-scripts pins are the one thing standing between phase 2 and
# an upstream push changing what a rebuild produces, so their shape and the
# way they reach an upstream script are guarded here. Nothing in this file
# touches the network.

load helpers/test_helper

# The pins honour whatever is already in the environment, which is the
# point of them but also means a caller who has exported either URL could
# make these cases pass while the file itself is broken. Every shell here
# starts without them, and without BASH_ENV, which bash would otherwise
# source into each non-interactive child.
clean_bash() {
  env -u BASH_ENV -u COMMUNITY_SCRIPTS_URL -u COMMUNITY_SCRIPTS_CORE_URL \
    bash "$@"
}

@test "both pins are commit SHAs, and the tag is a label beside one" {
  run clean_bash -c "source '${REPO_ROOT}/lib/community-scripts.sh'
    printf '%s %s %s\n' \
      \"\${COMMUNITY_SCRIPTS_PROXMOXVE_COMMIT}\" \
      \"\${COMMUNITY_SCRIPTS_CORE_COMMIT}\" \
      \"\${COMMUNITY_SCRIPTS_PROXMOXVE_TAG}\""
  [ "$status" -eq 0 ]

  local scripts core tag
  read -r scripts core tag <<<"$output"
  [[ ${scripts} =~ ^[0-9a-f]{40}$ ]]
  [[ ${core} =~ ^[0-9a-f]{40}$ ]]
  [[ ${tag} =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]
}

# A pin binds only when the upstream script inherits it, and an upstream
# script is a separate process. Reading the value back in the shell that
# did the assignment would pass with the export removed, so the check is
# made from a child.
@test "a child process inherits both URLs, each built from its own pin" {
  run clean_bash -euo pipefail -c "source '${REPO_ROOT}/lib/community-scripts.sh'
    expected_scripts=\"https://raw.githubusercontent.com/community-scripts/ProxmoxVE/\${COMMUNITY_SCRIPTS_PROXMOXVE_COMMIT}\"
    expected_core=\"https://raw.githubusercontent.com/community-scripts/core/\${COMMUNITY_SCRIPTS_CORE_COMMIT}\"
    bash -c '
      [ \"\$COMMUNITY_SCRIPTS_URL\" = \"\$1\" ] || { printf \"scripts: %s\n\" \"\${COMMUNITY_SCRIPTS_URL:-unset}\"; exit 1; }
      [ \"\$COMMUNITY_SCRIPTS_CORE_URL\" = \"\$2\" ] || { printf \"core: %s\n\" \"\${COMMUNITY_SCRIPTS_CORE_URL:-unset}\"; exit 1; }
      printf \"inherited\n\"
    ' _ \"\${expected_scripts}\" \"\${expected_core}\""
  [ "$status" -eq 0 ]
  [ "$output" = 'inherited' ]
}

# Pinning the scripts and leaving the engine on main is the mistake the
# file exists to prevent, and a tag can move where a SHA cannot.
@test "neither URL rests on a branch or a tag" {
  run clean_bash -euo pipefail -c "source '${REPO_ROOT}/lib/community-scripts.sh'
    printf '%s\n%s\n' \"\${COMMUNITY_SCRIPTS_URL}\" \"\${COMMUNITY_SCRIPTS_CORE_URL}\" \
      | sed 's#.*/##'"
  [ "$status" -eq 0 ]

  local ref
  while IFS= read -r ref; do
    [[ ${ref} =~ ^[0-9a-f]{40}$ ]] || {
      echo "a URL ends on ${ref}, which upstream can move"
      return 1
    }
  done <<<"$output"
}

@test "an exported URL wins, so a fork can be tested without an edit" {
  run clean_bash -euo pipefail -c "
    export COMMUNITY_SCRIPTS_CORE_URL='https://example.net/fork'
    source '${REPO_ROOT}/lib/community-scripts.sh'
    printf '%s\n' \"\${COMMUNITY_SCRIPTS_CORE_URL}\""
  [ "$status" -eq 0 ]
  [ "$output" = 'https://example.net/fork' ]
}

# The pins only bind if a stage carries them, and a stage is a child
# process that sources the prelude and nothing else.
@test "the stage prelude puts both URLs in a stage's environment" {
  run clean_bash -euo pipefail -c "
    PVE_CONFIG_LIB_DIR='${REPO_ROOT}/lib'
    export PVE_CONFIG_LIB_DIR PVE_CONFIG_SKIP_PLATFORM_CHECK=1
    source \"\${PVE_CONFIG_LIB_DIR}/stage.sh\"
    env | grep -c '^COMMUNITY_SCRIPTS_\(CORE_\)\?URL='"
  [ "$status" -eq 0 ]
  [ "$output" = '2' ]
}

# Every library here is safe to source more than once, and the prelude now
# carries one more. A readonly pin would abort the second pass of a stage
# running under errexit, which is the way every stage runs.
@test "sourcing the stage prelude twice under strict mode still succeeds" {
  run clean_bash -euo pipefail -c "
    PVE_CONFIG_LIB_DIR='${REPO_ROOT}/lib'
    export PVE_CONFIG_LIB_DIR PVE_CONFIG_SKIP_PLATFORM_CHECK=1
    source \"\${PVE_CONFIG_LIB_DIR}/stage.sh\"
    source \"\${PVE_CONFIG_LIB_DIR}/stage.sh\"
    printf '%s\n' \"\${COMMUNITY_SCRIPTS_CORE_URL}\"" 2>/dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"/community-scripts/core/"* ]]
}
