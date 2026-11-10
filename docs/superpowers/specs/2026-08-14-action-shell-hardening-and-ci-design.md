# Action shell hardening and CI — design

Date: 2026-08-14
Status: approved, not yet implemented

## Problem

The five composite actions in this repository carry their entire implementation as
inline `run: |` bash inside `action.yml`. That shell has no tests, is not reachable
by any linter without transformation, and interpolates `${{ inputs.* }}` directly
into the script body.

Measured against the current tree — five `action.yml` files, ten `run` blocks,
with `${{ ... }}` replaced by a shell variable reference so the linter sees a
variable rather than a literal:

| shellcheck severity | findings |
|---|---|
| error | 1 |
| warning | 13 |
| info | 67 |
| style | 74 |

Two of the thirteen warnings are artifacts of the extraction scaffold. The rest are
real: `cd` without `|| exit` (6), unquoted expansions feeding `for` and `$( )` (2),
iteration over `ls` output (1), a string built with escaped quotes that cannot
survive re-expansion (2).

`actionlint` cannot check these files. Passed an `action.yml` it parses it as a
workflow and emits 120 spurious `"jobs" section is missing` errors. It applies only
to `.github/workflows/`.

### Established facts about the current shell

Verified empirically under bash, not inferred:

- `-F 'vendor="'${VENDOR}'"'` produces argv `[-F] [vendor="JetHome"]`. The literal
  double quotes are load-bearing: curl's `-F` parser strips them, and they protect
  the value from `;` and `,` in `-F` syntax. Any rewrite must preserve them.
- `${SUPPORTED_DEVICES}` expanded unquoted splits correctly into `[-F]`
  `[supported_devices="jxd-r6,jxd-r7"]` for a comma-separated list. The trick works
  today.
- The same expansion with a value containing a space splits mid-value into
  `[supported_devices="jxd-r6]` `[jxd-r7"]`, and the guard `[ -z ${VAL} ]` aborts
  first with `[: a: binary operator expected`.

## Decisions

1. **Fixes land before CI**, as two pull requests. A CI that is red on its first run
   teaches the team to ignore it.
2. **Correctness is proved by argv goldens, not by review.** The actions have no
   tests; a refactor of production shell needs a mechanical check.
3. **The shell moves into `scripts/*.sh`,** with inputs passed through `env:`.
   shellcheck then reads the real files with no transformation, tests execute the
   real code rather than a rewritten copy, and direct interpolation of inputs into
   the script body — a script injection vector — disappears as a side effect.

## Deliverable 1 — harness, extraction, fixes

One pull request. This design document lands first as its own commit, followed by
three implementation commits in this order:

1. Test harness and argv goldens captured from the untouched tree. No change to any
   `action.yml`.
2. Shell moved into `scripts/*.sh`; inputs passed via `env:`. A pure move.
3. shellcheck findings fixed down to and including `info`.

The ordering is the safety argument: the goldens are recorded before the code is
touched, and commits 2 and 3 must not modify `tests/argv/`. A reviewer confirms this
with `git show --stat` on those two commits.

### Harness

`tests/stubs/` shadows external commands on `PATH`. Each stub appends its own argv to
`$ARGV_LOG` in a stable one-argument-per-line format prefixed by the program name.

| Stub | Reason |
|---|---|
| `curl` | capture argv; emit a canned success JSON so the real `jq` parses it |
| `ssh`, `rsync` | repo-upload and repo-upload-json |
| `sha256sum` | fixed digest for determinism; also absent on macOS |
| `date` | fixed timestamp, otherwise `DATE=$(date -Iseconds)` drifts |
| `mktemp` | fixed path, otherwise the temp name leaks into argv |
| `sleep` | otherwise the retry scenario waits 60 seconds |

`jq` and `python3` are deliberately not stubbed. The real hierarchy generator runs,
which makes the harness an integration test of the generator as well.

`tests/run_action.sh` sets the input environment, provides fake `GITHUB_OUTPUT`,
`GITHUB_ENV` and `GITHUB_ACTION_PATH`, runs one script, and diffs two artifacts
against the golden: the argv log and the resulting `GITHUB_OUTPUT`.

### Scenarios

firmware-upload:

- minimal inputs — no `date`, `version`, `changelog_file`, `supported_devices`, no slot
- full inputs — `generatefirmwareslot: true`, `update_latest: true`, changelog present
- `supported_devices` as a comma-separated list
- caller-supplied `hashpgp_file` versus computed digest
- retry — the curl stub fails twice, then succeeds

The other four actions get one or two scenarios each.

### The one intentional behaviour change

`supported_devices` containing a space currently aborts the step. Its golden is added
in commit 3, recording the fixed behaviour, not in commit 1. This is the single place
where argv changes on purpose, and the pull request description must name it.

### Script layout

```text
firmware-upload/
  action.yml            metadata and env wiring only
  scripts/checkvars.sh
  scripts/hierarchy.sh
  scripts/slot.sh
  scripts/deploy.sh
```

One script per run block; the four remaining actions get one script each. Inputs are
passed as explicit `env:` entries with upper-snake names — composite actions do not
receive `INPUT_*` automatically.

### Non-goals

`set -euo pipefail` is not added. It is a behaviour change the goldens cannot validate
across all paths: the retry loop relies on `|| true`, and several steps continue after
a non-zero status. It is a candidate for a later change, one script at a time.

## Deliverable 2 — CI

A second pull request. Triggers `push` and `pull_request`; every job runs on
`runs-on: self-hosted`, per the repository rule in CLAUDE.md.

| Job | Tool | Target |
|---|---|---|
| `shell` | shellcheck | `**/*.sh` — real files after the extraction, no transformation |
| `python` | ruff, `python3 -m compileall` | the hierarchy generator |
| `yaml` | yamllint, `check-jsonschema --builtin-schema vendor.github-actions` | the five `action.yml` |
| `workflows` | actionlint | `.github/workflows/` only |
| `json` | stdlib | every file under `templates/` parses as JSON and is listed by `git ls-files` |
| `test` | `tests/test.sh`, argv harness | generator and actions |

The tracked-template check in the `json` job is a direct guard against the bug fixed in
PR #4: a template that the code reads but git does not track, invisible until a clean
checkout runs.

Tools are installed at pinned versions — Python tools from `requirements-dev.txt`,
shellcheck from a release archive with its URL and SHA256 recorded in the repository.
No `latest`, no piping a downloaded script into a shell.

## Success criteria

- `tests/argv/` is byte-identical between commit 1 and commit 3, except the one golden
  added in commit 3 for the space-in-`supported_devices` case.
- `shellcheck -S info` reports nothing across `**/*.sh`.
- The full suite passes from a clean `git archive HEAD` extraction, so no untracked
  working-tree file can influence the result.
- CI is green on its first run against master.

## Risks

- **The stubs drift from the real tools.** A stub that accepts argv the real command
  would reject makes a green run meaningless. Mitigated by keeping stubs to argv
  capture plus a canned response, with no argument parsing of their own.
- **Scenarios miss a production input combination.** The goldens then prove less than
  they appear to. Mitigated by deriving the scenario list from actual calls in the
  sibling build repositories rather than from the input list in `action.yml`.
- **Self-hosted runners lack a tool.** Sibling repositories already use
  `sudo apt-get install -y` on these runners, so installation is possible, but the
  first CI run is the real test of that assumption.
