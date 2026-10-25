#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

# shellcheck source=lib/stage.sh
source "${PVE_CONFIG_LIB_DIR:?PVE_CONFIG_LIB_DIR is unset}/stage.sh"

SYSROOT=$(sysroot)

# Quoted heredoc: everything below is for the shell that reads it later, not
# for this one.
read -r -d '' bashrc <<'BASHRC' || true
# ~/.bashrc: executed by bash(1) for non-login shells.
# Managed by pve-config. Edits are overwritten on the next run.

# Colourised ls.
export LS_OPTIONS='--color=auto'
eval "$(dircolors)"
alias ls='ls $LS_OPTIONS'
alias ll='ls $LS_OPTIONS -l'
alias l='ls $LS_OPTIONS -lA'

# Ask before destroying something.
alias rm='rm -i'
alias cp='cp -i'
alias mv='mv -i'

# Make backspace behave when arriving over ssh and sudo. stty has no
# terminal to talk to in a non-interactive shell -- which is every scp,
# rsync and `ssh host command` -- and the error it prints there is enough to
# break scp outright, so it is asked for only when there is a tty.
case $- in
  *i*)
    if [ -t 0 ]; then
      stty erase '^H'
    fi
    ;;
esac
BASHRC
bashrc+=$'\n'

bashrc_path="${SYSROOT}/root/.bashrc"
write_file_backup "${bashrc_path}" "${bashrc}" 0644 >/dev/null

log_info "root shell configured in ${bashrc_path}"
