<!--
SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
SPDX-License-Identifier: Apache-2.0
-->

# Stages

A stage is one unit of work. The driver executes each stage as a child
process, so a failure in one cannot damage the driver or the stages that
follow.

## Layout

```plaintext
stages/
├── phase1/   host configuration, ending with an operator reboot
└── phase2/   ACME certificate and guest creation
```

## Naming

A stage file is `NN-name.sh`, where `NN` is a two digit number that fixes
the order within the phase. The driver discovers stages with the glob
`stages/phase*/[0-9][0-9]-*.sh` and sorts by phase, then by that number.
The driver skips every other path, so support files can live alongside a
stage.

The name without the `.sh` suffix is the stage name. The completion marker
under `state/` combines the phase and that name, as `phase1__NN-name.done`,
because two phases may carry the same ordering prefix. A rename makes the
driver run the stage again.

`--stage` accepts the bare name. When the same name exists in more than one
phase, pass the qualified `phase1__NN-name` form instead; the driver rejects
an ambiguous name rather than picking one.

Two stages in one phase may not share an ordering prefix. Every directory
under `stages/` needs a name of the form `phase1`, `phase2` and so on. The
driver rejects both mistakes rather than guessing at an order.

## Contract

Each stage:

- starts with `#!/usr/bin/env bash` and `set -euo pipefail`
- sources the libraries from `${PVE_CONFIG_LIB_DIR}`
- reads its configuration from the environment the driver exports
- converges rather than asserts: a second run changes nothing
- routes **every** mutation through `run_cmd`, `write_file`,
  `ensure_line_in_file` or `backup_file` from `lib/common.sh`
- exits non-zero when it cannot reach the desired state

The driver writes the completion marker. A stage must never write its own.

## Dry run

`--dry-run` runs every selected stage for real. It sets
`PVE_CONFIG_DRY_RUN=1`, which the helpers in `lib/common.sh` honour by
logging the intended change and making none, and the driver writes no
completion marker.

That design puts the burden on the stage: a stage that calls `mv`, `sed -i`
or a Proxmox command directly will change the host during a dry run. Route
every mutation through the helpers.
