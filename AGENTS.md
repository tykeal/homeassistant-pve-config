<!--
SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
SPDX-License-Identifier: Apache-2.0
-->

# Agent Development Guidelines

This document codifies git and development practices for AI agents working on
this repository. These practices are derived from the project constitution and
established development conventions.

## Repository Purpose

`pve-config` provides a series of scripts that are executed from a **Proxmox
VE shell** (as `root`, on the bare metal host) to configure a Proxmox system
in a reproducible, repeatable fashion. The target base configuration is:

- A **Proxmox VE on-metal host** (storage, networking, repositories, host
  tuning)
- A **Home Assistant OS VM** guest
- A **Tailscale LXC container** guest
- A **Frigate LXC container** guest

### Design Constraints

These constraints shape every change made to this repository:

- **Idempotent**: Every script MUST be safe to re-run. Detect existing state
  and skip or converge rather than failing or duplicating resources.
- **Replicable**: Running the scripts on a fresh Proxmox install MUST produce
  the same result. No hidden manual steps.
- **Minimal dependencies**: Scripts run on a stock Proxmox VE host. Prefer
  tools present in the Proxmox/Debian base install (`bash`, `pvesh`, `qm`,
  `pct`, `pvesm`, `curl`, `jq`, `awk`, `sed`). Install anything else
  explicitly from within the scripts.
- **Non-interactive by default**: Scripts MUST be runnable unattended.
  Configuration comes from variables, config files, or environment, not
  prompts. Interactive prompts MAY exist only behind an explicit opt-in flag.
- **Destructive operations are opt-in**: Anything that deletes, reformats, or
  overwrites existing guests or storage MUST require an explicit flag and
  MUST print what it will do first.
- **No secrets in the repository**: API tokens, Tailscale auth keys, and
  passwords are supplied at runtime (environment variables or an ignored
  local config file). NEVER commit secrets.

### Shell Script Conventions

- Target `bash`, with a `#!/usr/bin/env bash` shebang.
- Start every script with `set -euo pipefail`.
- Quote all variable expansions; use `"${var}"` form.
- Use `local` for all function-scoped variables.
- Provide a `usage()` function and support `-h`/`--help`.
- Log progress to stderr; keep stdout for machine-consumable output.
- Validate that the script is running on a Proxmox host before mutating
  state (e.g. check for `pveversion`).
- Make scripts executable (`chmod +x`) and commit them with the executable
  bit set.

## Constitution

If `.specify/memory/constitution.md` exists in this repository, read it and
follow its principles. The constitution takes precedence over this file if
there is any conflict between the two documents.

## Git Commit Message Rules

This project follows the
[seven rules of a great Git commit message](https://chris.beams.io/posts/git-commit/).
Several rules are enforced automatically by **gitlint** (see `.gitlint`).

### Rule 1: Separate subject from body with a blank line

The blank line between the subject and body is critical. Git tools like `log`,
`shortlog`, and `rebase` rely on this separation. Simple changes may omit the
body entirely.

- **Enforcement**: Convention and tooling; gitlint validates structure.

### Rule 2: Limit the subject line to 50 characters

Keep subjects concise. The hard limit is 50 characters.

- **Enforcement**: gitlint `title-max-length` (configured to 50).

### Rule 3: Capitalize the subject line

The subject line MUST start with a capital letter. This project uses
Conventional Commits, whose capitalized types naturally satisfy this rule.

- **Enforcement**: gitlint `contrib-title-conventional-commits` requires
  capitalized types.

### Rule 4: Do not end the subject line with a period

The subject line MUST NOT end with a period. Trailing space is precious
when you are limited to 50 characters.

- **Enforcement**: gitlint `title-trailing-punctuation` (T3, enabled by
  default).

### Rule 5: Use the imperative mood in the subject line

Write the subject as if completing the sentence: "If applied, this commit
will \_\_\_\_\_\_\_\_." The Conventional Commit type prefix naturally leads into
imperative mood.

Good examples:

- `Fix: correct storage detection on ZFS pools`
- `Feat: add Frigate LXC provisioning script`
- `Refactor: extract guest ID allocation helper`

Bad examples:

- ~~`Fix: fixed the storage detection`~~ (past tense)
- ~~`Feat: adds Frigate provisioning`~~ (third person)
- ~~`Refactor: extracting guest ID helper`~~ (gerund)

- **Enforcement**: Manual discipline; not automatically enforceable.

### Rule 6: Wrap the body at 72 characters

Body text MUST be wrapped at 72 characters per line. Lines containing URLs
MAY exceed this limit, but enforcement tooling has limitations.

- **Enforcement**: gitlint `body-max-line-length` (configured to 72). The
  configured `ignore-by-body` rule disables this check for the entire
  commit body if any line matches the URL pattern, so you MUST still
  manually wrap non-URL lines to 72 characters.

### Rule 7: Use the body to explain what and why, not how

The code diff shows _how_ a change was made. The commit body should explain
_what_ problem is being solved and _why_ this approach was chosen. Include
context that will help future developers understand the rationale.

- **Enforcement**: Manual discipline; not automatically enforceable.

## Conventional Commit Format

This project uses **Conventional Commits** with **capitalized types**:

```plaintext
Type(scope): Short imperative description

Body explaining what and why. Wrap at 72 characters.
URLs on their own line are exempt from the wrap limit.

Co-authored-by: <AI Model Name> <appropriate-email@provider.com>
Signed-off-by: Name <email>
```

**Allowed types** (capitalized, enforced by gitlint):

- `Fix` — Bug fixes
- `Feat` — New features
- `Chore` — Maintenance tasks
- `Docs` — Documentation changes
- `Style` — Code style/formatting (no logic change)
- `Refactor` — Code refactoring (no behavior change)
- `Perf` — Performance improvements
- `Test` — Adding or updating tests
- `Revert` — Reverting previous commits
- `CI` — CI/CD configuration changes
- `Build` — Build system changes

**Suggested scopes** for this repository: `host`, `storage`, `network`,
`hass`, `tailscale`, `frigate`, `lib`, `lint`, `docs`.

### Commit Command

Always use the `-s` flag for Developer Certificate of Origin sign-off:

```bash
git commit -s -m "Type(scope): Short imperative description

Body explaining what changed and why.

Co-authored-by: <AI Model> <email@provider.com>"
```

### Co-Authorship

All AI-assisted commits MUST include a `Co-authored-by` trailer identifying
the AI model used:

| Model | Co-authored-by |
| ------- | ---------------- |
| Claude | `Co-authored-by: Claude <claude@anthropic.com>` |
| ChatGPT | `Co-authored-by: ChatGPT <chatgpt@openai.com>` |
| Gemini | `Co-authored-by: Gemini <gemini@google.com>` |
| Copilot | `Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>` |

This trailer goes at the end of the commit message body. Note that
`git commit -s` appends the `Signed-off-by` line after all other
content, so it will appear after the `Co-authored-by` trailer
automatically.

## Gitlint Enforcement Summary

The following gitlint rules are active (see `.gitlint` for full config):

| Rule | What it checks | Configured |
| ---- | -------------- | ---------- |
| `title-max-length` (T1) | Subject ≤50 chars | 50 |
| `title-trailing-punctuation` (T3) | No trailing `.` `;` `:` etc. | Enabled |
| `body-max-line-length` (B1) | Body lines ≤72 chars | 72 |
| `contrib-title-conventional-commits` | Capitalized type prefix | Required |
| `contrib-body-requires-signed-off-by` | DCO sign-off present | Required |
| `ignore-by-body` | Exempt URL lines from B1 | Enabled |

## Pre-Commit Hooks

This repository uses pre-commit hooks that run automatically on `git commit`.
The hooks enforce (non-exhaustive list):

- **shellcheck** — Shell script static analysis (`-x`, follows sourced files)
- **shfmt** — Shell script formatting (2-space indent, indented `case`
  branches); this hook rewrites files in place
- **gitlint** — Commit message format validation (see rules above); it also
  runs in CI on pull requests via the linting workflow's `commit_range`
- **reuse** — SPDX license header compliance
- **yamllint** — YAML linting (120 character line limit)
- **actionlint** — GitHub Actions workflow validation
- **write-good** — Prose linting for Markdown files
- **aislop** — Repository-wide AI-slop checks
- **pre-commit-hooks** — Generic hygiene: trailing whitespace, end-of-file
  fixer, LF line endings, merge conflict markers, large files, JSON/XML/YAML
  parse checks, and a `no-commit-to-branch` guard on `main`

Check `.pre-commit-config.yaml` for the complete list.

Because `no-commit-to-branch` blocks `main`, all work MUST happen on a
feature branch.

### Shell Linting

Shell scripts are linted and formatted automatically by the `shellcheck` and
`shfmt` pre-commit hooks. To run them on demand without committing:

```bash
pre-commit run shellcheck --all-files
pre-commit run shfmt --all-files
```

`shfmt` **rewrites files in place**. If it reformats something during a
commit, stage the result and commit again.

All `shellcheck` findings MUST be fixed, or justified with an inline
`# shellcheck disable=SCxxxx` comment that explains why the exception is
correct. Blanket disables at the top of a file are not acceptable.

The formatting style is fixed by the hook arguments in
`.pre-commit-config.yaml`:

| Flag | Effect |
| ---- | ------ |
| `--indent=2` | Two-space indentation |
| `--case-indent` | Indent `case` branches |
| `--write` | Rewrite the file in place |

### If Pre-Commit Fails

**CRITICAL**: Do NOT use `git reset` after a failed commit attempt.

1. Fix the issues identified by the pre-commit hooks
2. Stage the fixes: `git add <files>`
3. Attempt the commit again as if you hadn't tried before
4. The pre-commit hooks will run again on the new attempt

Pre-commit hooks may auto-fix some issues (e.g., end-of-file-fixer,
trailing-whitespace, shfmt). If files were modified by hooks, stage
them and commit again.

### Never Bypass Hooks

Using `--no-verify` to bypass pre-commit hooks is **PROHIBITED**. Likewise,
`--no-gpg-sign` is **PROHIBITED**; commits must remain signed.

## Atomic Commits

Each commit MUST represent exactly one logical change:

- ✅ One feature per commit
- ✅ One bug fix per commit
- ✅ One refactor per commit
- ❌ Multiple unrelated changes in one commit

Provisioning a guest is one logical change: do not combine the Tailscale
container script with the Frigate container script in a single commit.

### Task List Updates Are Separate Commits

Changes to task tracking documents (e.g., `tasks.md`) MUST be committed
separately from the code or documentation they track. Bundling a task
list update into the same commit as the work it describes breaks commit
atomicity — even when both changes are classified as documentation.

- ✅ Commit 1: `Feat(frigate): Add LXC provisioning script` (code + tests)
- ✅ Commit 2: `Docs(tasks): Mark T015 complete` (tasks.md only)
- ❌ Single commit with code changes **and** tasks.md update

## SPDX License Headers

All new source files MUST include SPDX headers. For shell scripts, the
header goes immediately after the shebang:

```bash
#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
# SPDX-License-Identifier: Apache-2.0
```

For YAML, Python, and other `#`-comment formats:

```yaml
# SPDX-FileCopyrightText: 2026 Andrew Grimberg <tykeal@bardicgrove.org>
# SPDX-License-Identifier: Apache-2.0
```

For Markdown, use an HTML comment block (see the top of this file).

If a file type cannot carry a comment, add an entry to `REUSE.toml`
instead. Verify compliance with `reuse lint`.

## Git Worktrees

When creating git worktrees for feature branches, bug fixes, or any
other work, **always** place them in the sibling `worktrees/` directory:

```bash
git worktree add /home/tykeal/repos/personal/homeassistant/worktrees/<branch-name> -b <branch-name> main
```

The `worktrees/` directory is a sibling of the repository under the
repository root's parent directory:

```plaintext
repos/personal/homeassistant/
├── pve-config/              ← this repository
└── worktrees/               ← all worktrees go here
    ├── feat/some-feature/
    └── fix/some-bugfix/
```

**NEVER** create worktrees inside the repository directory itself.

Clean up worktrees when the associated branch has been merged:

```bash
git worktree remove /home/tykeal/repos/personal/homeassistant/worktrees/<branch-name>
git branch -D <branch-name>
```

## Testing Requirements

These scripts mutate a hypervisor. They cannot be fully exercised on a
developer workstation, so verification is layered:

1. **Static analysis** — `shellcheck` and `shfmt` MUST be clean for every
   shell script. Both run as pre-commit hooks.
2. **Unit tests** — Testable helper functions (argument parsing, ID
   allocation, config validation, idempotency checks) SHOULD be covered by
   [`bats`](https://github.com/bats-core/bats-core) tests under `tests/`:

   ```bash
   bats tests/
   ```

3. **Dry run** — Scripts SHOULD support a `--dry-run` flag that prints the
   commands it would execute without running them. Exercise it before
   proposing a change as complete.
4. **Host validation** — Changes affecting real Proxmox state MUST be
   validated by the repository owner on a test host. Agents MUST NOT claim a
   provisioning change is verified based on static analysis alone; say
   explicitly what was and was not tested.

This repository is currently pure shell: there is no Python package, no
`pyproject.toml`, and no Python hooks in `.pre-commit-config.yaml`. If
Python helpers are introduced later, the corresponding `ruff`, `mypy`, and
`interrogate` hooks MUST be restored to `.pre-commit-config.yaml` before
that code lands.

## Continuous Integration

GitHub Actions workflows live under `.github/workflows/`:

| Workflow | File | Triggers | What it gates |
| -------- | ---- | -------- | ------------- |
| Linting 🧹 | `linting.yaml` | PR, push to `main`, manual | The full pre-commit hook set, plus `gitlint` commit-message linting on pull requests; this is the gating CI check |
| Build/Test | `build-test.yaml` | PR, push to `main`, manual | `bats` tests under `tests/`, when any exist |
| Semantic Pull Request 🛠️ | `semantic-pull-request.yaml` | PR opened/reopened/edited/synchronized | PR title must be a valid Conventional Commit |
| OpenSSF Scorecard | `openssf-scorecard.yaml` | Weekly schedule, branch protection changes, push to `main`, manual | Nothing; publishes the Scorecard badge and SARIF |
| Security Scans (Workflows) | `zizmor.yaml` | PR, push to `main`, weekly schedule, manual | Nothing; reports workflow-security findings |
| AI Slop Scan | `aislop.yaml` | Push to `main`, weekly schedule, manual | Nothing; publishes aislop SARIF |

Specific things worth knowing:

- **Linting runs every hook as one job.** It calls the lfreleng standalone
  linting reusable with no hook selector, which runs the complete hook set
  as a single run-all job rather than one job per hook. `shellcheck`,
  `shfmt`, `yamllint`, `reuse`, `actionlint`, and the rest therefore
  surface as one check run named `Lint: lint-all`, so a failure has to be
  read from the job log rather than from the check name.
- **`no-commit-to-branch` is skipped in CI.** It is a local-only guard that
  stops a developer committing straight to `main`. In CI it has no meaning,
  and on the `push: main` trigger the checkout sits on `main` by
  definition, so leaving it enabled would fail every run.
- **`gitlint` runs in CI on pull requests.** The linting workflow passes a
  `commit_range` covering the commits under review, which is what reaches
  prek's `commit-msg` stage; without a range that stage is skipped
  silently. pre-commit.ci does not run `commit-msg` hooks at all, so this
  workflow is the only automated commit-message check. The hook runs once
  per commit in the range. It complements the Semantic Pull Request check:
  that one validates only the PR title, while gitlint validates each full
  commit message (subject length and punctuation, body wrap, sign-off).
  The range is empty on `push` and `workflow_dispatch` because the
  reusable refuses a range with missing endpoints or one selecting no
  commits, so commit-message linting is a pull-request-time gate. It is
  also empty for pull requests authored by `dependabot[bot]`: those
  subjects are generated from dependency names and regularly exceed the
  50-character limit, and they can be neither shortened from our side nor
  exempted from within `.gitlint`, since `ignore-by-author-name` has no
  author under `--commit-msg-filename` and `ignore-by-title` is overwritten
  by `ignore-by-body`, which every Dependabot body triggers via its
  release-notes URL. The Semantic Pull Request check still covers those
  pull requests.
- **zizmor and aislop are advisory.** Both publish to GitHub code scanning
  rather than blocking a merge. The SARIF upload requires GitHub Advanced
  Security to be enabled for the repository.
- **Action pins are commit SHAs.** Every third-party `uses:` is pinned to a
  full 40-character commit SHA with the human-readable version in a
  trailing comment, and Dependabot bumps them weekly. Agents MUST NEVER
  replace a SHA pin with a floating tag or branch name; update the SHA and
  the trailing comment together.

## Development Workflow Summary

1. Create a worktree/branch off `main` (committing directly to `main` is
   blocked)
2. Make changes to the scripts
3. Lint shell scripts: `pre-commit run shellcheck shfmt --all-files`
4. Run tests if present: `bats tests/`
5. Exercise the change with `--dry-run` where possible
6. Stage changes: `git add <files>`
7. Commit with sign-off and co-authorship:

   ```bash
   git commit -s -m "Type(scope): Short imperative description

   Body explaining what and why.

   Co-authored-by: <AI Model> <email@provider.com>"
   ```

8. If pre-commit fails, fix issues and commit again (don't reset)
9. Push and open a pull request when ready

## Quick Reference

| Requirement | Command/Format |
| ------------ | ---------------- |
| Sign-off | `git commit -s` |
| Co-author | `Co-authored-by: <Model> <email>` |
| Subject format | `Type(scope): imperative description` |
| Type case | Capitalized (e.g., `Fix`, `Feat`) |
| Subject length | ≤50 chars (enforced by gitlint) |
| Body line length | ≤72 chars (URLs exempt) |
| Subject punctuation | No trailing period |
| Subject mood | Imperative ("Add", not "Added") |
| Body content | Explain what and why, not how |
| Branching | Feature branch required; `main` is blocked |
| Shell shebang | `#!/usr/bin/env bash` + `set -euo pipefail` |
| Shell lint | `shellcheck` + `shfmt` pre-commit hooks (auto) |
| Script behavior | Idempotent, non-interactive, `--dry-run` capable |
| Secrets | Runtime only; never committed |
| After failed commit | Fix and retry (no reset) |
