# Action shell hardening — implementation plan (PR 1)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the five composite actions testable and shellcheck-clean without changing what they send over the wire.

**Architecture:** Stub the external commands on `PATH`, capture their argv into a log, and freeze that log as a golden file. Capture the goldens from the untouched tree first, then move the inline `run:` bash into `scripts/*.sh` with inputs passed through `env:`, then fix the shellcheck findings. The goldens are the proof that neither step changed behaviour.

**Tech Stack:** bash, shellcheck, python3 (stdlib only, already used by the hierarchy generator), git.

**Design:** [docs/superpowers/specs/2026-08-14-action-shell-hardening-and-ci-design.md](../specs/2026-08-14-action-shell-hardening-and-ci-design.md)

## Global Constraints

- Branch `feature/action-argv-harness` already exists with the design doc committed. Do not create another branch.
- Never modify `tests/argv/*.expected` in the extraction or fix commits. That immutability is the safety argument of the whole PR. The single exception is Task 10, which adds one new golden file.
- The wire format must not change. `-F 'vendor="'${V}'"'` produces argv `[-F] [vendor="JetHome"]`; curl's `-F` parser strips the literal quotes itself. Keep the quote wrapping in any rewrite.
- Do not add `set -euo pipefail`. The retry loop relies on `|| true` and several steps continue after a non-zero status. Out of scope for this PR.
- All consumers pin `@master`: 185 uses of `firmware-upload`, 29 of `armbian-jethome-version`, 17 of `repo-upload-json`. A merge to master reaches production immediately; there is no staging.
- `repo-upload` and `armbian-version` have no consumers in the JetHome repositories. Work on those first — a mistake there costs nothing.
- Python stays stdlib-only. The extractor may not import PyYAML.
- Code comments in Russian, per CLAUDE.md. Python 4-space indent, YAML 2-space.

## Known traps

**`$RANDOM` cannot be used as an environment variable name.** `repo-upload` and `repo-upload-json` write `RANDOM=ID_$((RANDOM%1000000))` into `$GITHUB_ENV` and read it back as `${{ env.RANDOM }}`. That works only because GitHub substitutes it as text before bash starts. Inside a script, bash's special `$RANDOM` shadows the exported value:

```
$ RANDOM=ID_123456 bash -c 'echo $RANDOM'
27380
```

The SSH key path would become `~/.ssh/27380`, which does not exist, and every upload would fail silently. When extracting these two actions, rename the variable to `KEY_ID` in both the `env:` block and the script body.

**Production input shapes**, taken from `os/userpatches-jethub/gha/chunks/650.per-chunk-images_job.yaml`, not from the input list in `action.yml`:

| input | sdcard call | burn call |
|---|---|---|
| `url` | `https://fw.jethome.ru` | `https://fw.jethome.ru` |
| `fullslug` | `JetHome.<brd>.Armbian.<channel>.<release>.<branch>` | same |
| `image_type` | `sdcard` | `burn` |
| `firmware_file` | `<image>` | `tools/<imageburn>` |
| `hashpgp_file` | `<image>.asc` | `<imageburn>.asc` |
| `version` | build version | build version |
| `generatefirmwareslot` | `true` | `false` |
| `update_latest` | `true` | `true` |
| `supported_devices` | `D1,D1P` / `D2` / `H1` | same |
| `date` | not passed | not passed |
| `changelog_file` | not passed | not passed |
| `force_overwrite` | not passed (defaults `true`) | not passed |

`supported_devices` is always comma-separated with no spaces, so the space-splitting defect is latent, not live.

## File structure

```text
firmware-upload/
  action.yml                            modified: run bodies replaced by script calls + env
  scripts/checkvars.sh                  created
  scripts/apply-fw-template.sh          created
  scripts/add-fw-slot.sh                created
  scripts/deploy-to-fw-storage.sh       created
repo-upload/scripts/genkey.sh                 created
repo-upload/scripts/deploy-to-repo-storage.sh created
repo-upload-json/scripts/genkey.sh                 created
repo-upload-json/scripts/deploy-to-repo-storage.sh created
armbian-version/scripts/copyversion.sh        created
armbian-jethome-version/scripts/setversion.sh created

tests/
  stubs/curl  ssh  rsync  sha256sum  date  mktemp  sleep   created
  lib/log_argv.sh          created: shared argv-logging helper for stubs
  lib/extract_run_block.py created: pulls a run block out of action.yml (deleted in Task 7)
  run_action.sh            created: driver — sets env, runs one step, diffs golden
  scenarios/*.env          created: one file per scenario
  argv/*.expected          created: goldens
  test_actions.sh          created: runs every scenario
```

`tests/` is a new top-level directory. The existing generator suite stays where it is at `firmware-upload/generate_hierarchy/tests/test.sh`.

---

### Task 1: Harness skeleton, proved on armbian-version

`armbian-version` has no consumers and one short run block, so it is the safest place to get the harness right.

**Files:**
- Create: `tests/lib/log_argv.sh`, `tests/stubs/{curl,ssh,rsync,sha256sum,date,mktemp,sleep}`, `tests/lib/extract_run_block.py`, `tests/run_action.sh`, `tests/test_actions.sh`, `tests/scenarios/armbian-version-nightly.env`
- Create: `tests/argv/armbian-version-nightly.expected`

**Interfaces:**
- Produces: `tests/run_action.sh <scenario.env>` — exit 0 when the run matches its golden, 1 with a diff otherwise. Scenario files export `ACTION_DIR`, `STEP_ID`, and the step's environment variables.
- Produces: `UPDATE_GOLDEN=1` regenerates the golden, matching the convention already used by `generate_hierarchy/tests/test.sh`.

- [ ] **Step 1: Write the shared argv logger**

`tests/lib/log_argv.sh`:

```bash
#!/bin/bash
# Общий помощник для стабов: пишет имя программы и её argv в $ARGV_LOG.
# Формат намеренно простой и построчный — так diff эталона читаем глазами.
log_argv() {
    local prog="$1"
    shift
    {
        echo "${prog}"
        local a
        for a in "$@"; do
            printf '  [%s]\n' "${a}"
        done
    } >>"${ARGV_LOG}"
}
```

- [ ] **Step 2: Write the stubs**

`tests/stubs/date`:

```bash
#!/bin/bash
# shellcheck source=../lib/log_argv.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/log_argv.sh"
log_argv date "$@"
echo "2026-01-02T03:04:05+03:00"
```

`tests/stubs/sha256sum`:

```bash
#!/bin/bash
# shellcheck source=../lib/log_argv.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/log_argv.sh"
log_argv sha256sum "$@"
# Настоящий sha256sum печатает "<хеш>  <файл>", код разбирает это через awk.
echo "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  $1"
```

`tests/stubs/mktemp`:

```bash
#!/bin/bash
# shellcheck source=../lib/log_argv.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/log_argv.sh"
log_argv mktemp "$@"
# Детерминированные имена: иначе путь временного файла течёт в argv curl.
i=0
[ -f "${MKTEMP_COUNTER}" ] && i=$(cat "${MKTEMP_COUNTER}")
i=$((i + 1))
echo "${i}" >"${MKTEMP_COUNTER}"
path="${STUB_TMPDIR}/mktemp-${i}"
: >"${path}"
echo "${path}"
```

`tests/stubs/sleep`:

```bash
#!/bin/bash
# shellcheck source=../lib/log_argv.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/log_argv.sh"
log_argv sleep "$@"
# Не спим: сценарий с retry иначе занимает минуту.
```

`tests/stubs/ssh` and `tests/stubs/rsync` (identical apart from the name):

```bash
#!/bin/bash
# shellcheck source=../lib/log_argv.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/log_argv.sh"
log_argv ssh "$@"
```

`tests/stubs/curl`:

```bash
#!/bin/bash
# shellcheck source=../lib/log_argv.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/log_argv.sh"
log_argv curl "$@"
# CURL_FAIL_STATE хранит, сколько ещё вызовов должны вернуть неуспех.
# Нужен для сценария с retry: состояние между запусками процесса — только через файл.
n=0
[ -f "${CURL_FAIL_STATE:-/dev/null}" ] && n=$(cat "${CURL_FAIL_STATE}")
if [ "${n}" -gt 0 ]; then
    echo $((n - 1)) >"${CURL_FAIL_STATE}"
    printf '{"success": false, "error": "stub failure"}'
    exit 0
fi
printf '{"success": true}'
```

Make them executable: `chmod +x tests/stubs/*`.

- [ ] **Step 3: Write the run-block extractor**

This is temporary scaffolding. It exists only so Task 1 can capture goldens from `action.yml` files that still hold their shell inline. Task 7 deletes it.

`tests/lib/extract_run_block.py`:

```python
#!/usr/bin/python3
"""Достаёт тело run-блока из composite action.yml.

Временная обвязка: нужна, пока shell живёт внутри action.yml. После выноса
скриптов в scripts/*.sh драйвер зовёт их напрямую, и этот файл удаляется.
PyYAML не используем — в проекте только стандартная библиотека.
"""
import re
import sys


def extract(path, step_id):
    lines = open(path).read().split('\n')
    current_id = None
    i = 0
    while i < len(lines):
        m = re.match(r'^\s*id:\s*(\S+)\s*$', lines[i])
        if m:
            current_id = m.group(1)
        m = re.match(r'^(\s*)run:\s*\|\s*$', lines[i])
        if m and current_id == step_id:
            indent = len(m.group(1)) + 2
            i += 1
            body = []
            while i < len(lines):
                line = lines[i]
                if line.strip() and len(line) - len(line.lstrip()) < indent:
                    break
                body.append(line[indent:] if len(line) >= indent else '')
                i += 1
            return '\n'.join(body)
        i += 1
    raise SystemExit(f"step '{step_id}' with a literal run block not found in {path}")


def substitute(body):
    """Заменяет выражения GitHub на обращения к переменным окружения.

    Правила подстановки совпадают с теми, по которым Task 5-6 переносят код
    в скрипты, — поэтому имена переменных здесь и там одинаковые.
    """
    body = re.sub(r'\$\{\{\s*inputs\.([A-Za-z0-9_]+)\s*\}\}',
                  lambda m: '${INPUT_' + m.group(1).upper() + '}', body)
    body = re.sub(r'\$\{\{\s*steps\.([A-Za-z0-9_-]+)\.outputs\.([A-Za-z0-9_]+)\s*\}\}',
                  lambda m: '${' + m.group(1).replace('-', '_').upper() + '_' + m.group(2).upper() + '}', body)
    body = re.sub(r'\$\{\{\s*github\.action_path\s*\}\}', '${GITHUB_ACTION_PATH}', body)
    body = re.sub(r'\$\{\{\s*env\.RANDOM\s*\}\}', '${KEY_ID}', body)
    return body


if __name__ == '__main__':
    print(substitute(extract(sys.argv[1], sys.argv[2])))
```

- [ ] **Step 4: Write the driver**

`tests/run_action.sh`:

```bash
#!/bin/bash
# Прогоняет один шаг экшена со стабами вместо внешних команд и сравнивает
# перехваченный argv с эталоном.

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "${TESTS_DIR}")"

SCENARIO="$1"
NAME="$(basename "${SCENARIO}" .env)"
GOLDEN="${TESTS_DIR}/argv/${NAME}.expected"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

export STUB_TMPDIR="${WORK}/tmp"
mkdir -p "${STUB_TMPDIR}"
export ARGV_LOG="${WORK}/argv.log"
export MKTEMP_COUNTER="${WORK}/mktemp.counter"
export GITHUB_OUTPUT="${WORK}/github_output"
export GITHUB_ENV="${WORK}/github_env"
: >"${ARGV_LOG}"
: >"${GITHUB_OUTPUT}"
: >"${GITHUB_ENV}"

# Сценарий задаёт ACTION_DIR, STEP_ID и переменные окружения шага.
# shellcheck source=/dev/null
source "${SCENARIO}"

export GITHUB_ACTION_PATH="${REPO_DIR}/${ACTION_DIR}"
export PATH="${TESTS_DIR}/stubs:${PATH}"

SCRIPT="${REPO_DIR}/${ACTION_DIR}/scripts/${STEP_ID}.sh"
if [ -f "${SCRIPT}" ]; then
    # Скрипты уже вынесены — зовём настоящий код.
    bash "${SCRIPT}" >"${WORK}/stdout" 2>&1
else
    # Shell ещё внутри action.yml — достаём блок экстрактором.
    python3 "${TESTS_DIR}/lib/extract_run_block.py" \
        "${REPO_DIR}/${ACTION_DIR}/action.yml" "${STEP_ID}" >"${WORK}/step.sh"
    bash "${WORK}/step.sh" >"${WORK}/stdout" 2>&1
fi
RC=$?

ACTUAL="${WORK}/actual"
{
    echo "=== exit: ${RC}"
    echo "=== argv"
    cat "${ARGV_LOG}"
    echo "=== github_output"
    cat "${GITHUB_OUTPUT}"
    echo "=== github_env"
    cat "${GITHUB_ENV}"
} >"${ACTUAL}"

if [ ! -f "${GOLDEN}" ]; then
    if [ "${UPDATE_GOLDEN:-}" = "1" ]; then
        cp "${ACTUAL}" "${GOLDEN}"
        echo "📝 UPDATED: created ${NAME}.expected"
        exit 0
    fi
    echo "❌ FAILED: reference file ${NAME}.expected is missing" >&2
    cat "${ACTUAL}" >&2
    exit 1
fi

if diff -u "${GOLDEN}" "${ACTUAL}"; then
    echo "✅ PASSED: ${NAME}"
    exit 0
fi
echo "❌ FAILED: ${NAME} does not match its golden" >&2
exit 1
```

- [ ] **Step 5: Write the scenario for armbian-version**

`tests/scenarios/armbian-version-nightly.env`:

```bash
ACTION_DIR="armbian-version"
STEP_ID="copyversion"

export INPUT_PATHOS="os"
export INPUT_PATHARMBIAN="build"
export INPUT_BETA="yes"
```

This step reads `nightly.json` and `nightly-jethome.json` through the real `jq` and writes a `VERSION` file, so the scenario needs those files. Create them inside the driver's work directory instead of polluting the repository — add this to the scenario file:

```bash
# Шаг читает json'ы через настоящий jq и пишет VERSION. Готовим песочницу.
SANDBOX="$(mktemp -d)"
mkdir -p "${SANDBOX}/os" "${SANDBOX}/build"
echo '{"version": "25.11.1"}' >"${SANDBOX}/os/nightly.json"
echo '{"version": "1.7"}' >"${SANDBOX}/os/nightly-jethome.json"
cd "${SANDBOX}" || exit 1
```

- [ ] **Step 6: Capture the golden and read it**

Run: `UPDATE_GOLDEN=1 bash tests/run_action.sh tests/scenarios/armbian-version-nightly.env`
Expected: `📝 UPDATED: created armbian-version-nightly.expected`

Then read `tests/argv/armbian-version-nightly.expected` and confirm by eye that it records the real behaviour: `=== exit: 0` and a `github_output` line. Note that this action has a pre-existing bug — it writes `output=${VERSION}.${VERSIONJH}` inside single quotes, so the literal text is emitted rather than the value. **Freeze that as-is.** It is out of scope here; fixing it changes behaviour and belongs in its own commit.

- [ ] **Step 7: Verify the golden is stable**

Run: `bash tests/run_action.sh tests/scenarios/armbian-version-nightly.env`
Expected: `✅ PASSED: armbian-version-nightly`

Run it twice more. A golden that only passes on the first run means something non-deterministic leaked through — most likely a temp path or a timestamp.

- [ ] **Step 8: Write the suite runner**

`tests/test_actions.sh`:

```bash
#!/bin/bash
# Прогоняет все сценарии экшенов.

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILED=0

for scenario in "${TESTS_DIR}"/scenarios/*.env; do
    bash "${TESTS_DIR}/run_action.sh" "${scenario}" || FAILED=1
done

exit ${FAILED}
```

- [ ] **Step 9: Run the suite**

Run: `bash tests/test_actions.sh`
Expected: one `✅ PASSED` line, exit 0.

- [ ] **Step 10: Commit**

```bash
git add tests
git commit -m "test: add argv harness for composite actions

The five actions carry their implementation as inline run blocks with no
tests. Stub the external commands on PATH, capture their argv, and freeze
it as a golden so a later refactor can be shown not to change what the
actions send.

Cover armbian-version first: it has no consumers, so a mistake in the
harness itself costs nothing."
```

---

### Task 2: Goldens for armbian-jethome-version

**Files:**
- Create: `tests/scenarios/armbian-jethome-version-{inc,dec,zero,override}.env`
- Create: `tests/argv/armbian-jethome-version-{inc,dec,zero,override}.expected`

**Interfaces:**
- Consumes: `tests/run_action.sh` from Task 1.

- [ ] **Step 1: Write the four scenarios**

`tests/scenarios/armbian-jethome-version-inc.env`:

```bash
ACTION_DIR="armbian-jethome-version"
STEP_ID="setversion"

SANDBOX="$(mktemp -d)"
echo '{"version": "1.7"}' >"${SANDBOX}/nightly-jethome.json"
cd "${SANDBOX}" || exit 1

export INPUT_FILE="nightly-jethome.json"
export INPUT_TYPE="minor"
export INPUT_DO="inc"
export INPUT_OVERRIDE=""
```

The other three differ only in the last three exports:

- `-dec.env`: `INPUT_DO="dec"`
- `-zero.env`: `INPUT_DO="zero"`
- `-override.env`: `INPUT_OVERRIDE="9.9"`, `INPUT_DO="inc"`

- [ ] **Step 2: Capture the goldens**

Run:

```bash
for s in inc dec zero override; do
  UPDATE_GOLDEN=1 bash tests/run_action.sh "tests/scenarios/armbian-jethome-version-${s}.env"
done
```

Expected: four `📝 UPDATED` lines.

- [ ] **Step 3: Read each golden**

Confirm `1.7` becomes `1.8` for inc, `1.6` for dec, `1.0` for zero, `9.9` for override. This action carries the same single-quote defect in its `output=` line — freeze it, do not fix it here.

- [ ] **Step 4: Run the suite**

Run: `bash tests/test_actions.sh`
Expected: five `✅ PASSED` lines, exit 0.

- [ ] **Step 5: Commit**

```bash
git add tests
git commit -m "test: cover armbian-jethome-version with argv goldens

Freeze inc, dec, zero and override, including the existing defect in the
step output line, so the refactor is judged against current behaviour
rather than intended behaviour."
```

---

### Task 3: Goldens for firmware-upload

The action with 185 consumers. Four steps, and the scenarios follow the two production call shapes recorded in "Known traps" above.

**Files:**
- Create: `tests/scenarios/firmware-upload-{checkvars-minimal,checkvars-version,hierarchy,slot-on,slot-off,deploy-sdcard,deploy-computed-hash,deploy-retry}.env`
- Create: the matching `tests/argv/*.expected`

**Interfaces:**
- Consumes: `tests/run_action.sh` from Task 1, the curl stub's `CURL_FAIL_STATE` protocol.

- [ ] **Step 1: Write the checkvars scenarios**

`tests/scenarios/firmware-upload-checkvars-minimal.env` — no date, no version, the production shape:

```bash
ACTION_DIR="firmware-upload"
STEP_ID="checkvars"

export INPUT_FULLSLUG="JetHome.j100.Armbian.release.bookworm.edge"
export INPUT_DATE=""
export INPUT_VERSION=""
```

`tests/scenarios/firmware-upload-checkvars-version.env` — version passed, exercising the sanitiser:

```bash
ACTION_DIR="firmware-upload"
STEP_ID="checkvars"

export INPUT_FULLSLUG="JetHome.j100.Armbian.release.bookworm.edge"
export INPUT_DATE="2026-01-02T03:04:05+03:00"
export INPUT_VERSION="25.11.1/beta build"
```

The second one matters: the sanitiser is `sed 's/[^a-zA-Z0-9._-]/-/g'`, and the golden records what a slash and a space become.

- [ ] **Step 2: Write the hierarchy scenario**

`tests/scenarios/firmware-upload-hierarchy.env`:

```bash
ACTION_DIR="firmware-upload"
STEP_ID="apply-fw-template"

export INPUT_FULLSLUG="JetHome.j100.Armbian.release.bookworm.edge"
export INPUT_URL="https://fw.jethome.ru"
export INPUT_FWUPLOAD="test-token"
```

This runs the real `python3 main.py`, so the golden also pins the generator's integration with the action.

- [ ] **Step 3: Write the slot scenarios**

`tests/scenarios/firmware-upload-slot-on.env` — the sdcard production call:

```bash
ACTION_DIR="firmware-upload"
STEP_ID="add-fw-slot"

export INPUT_GENERATEFIRMWARESLOT="true"
export INPUT_UPDATE_LATEST="true"
export INPUT_SUPPORTED_DEVICES="D1,D1P"
export INPUT_CHANGELOG_FILE=""
export INPUT_URL="https://fw.jethome.ru"
export INPUT_FWUPLOAD="test-token"
export CHECKVARS_VENDOR="JetHome"
export CHECKVARS_PLATFORM="j100"
export CHECKVARS_SLUG="Armbian.release.bookworm.edge"
export CHECKVARS_VERSION="25.11.1"
export CHECKVARS_DATE="2026-01-02T03:04:05+03:00"
```

`-slot-off.env` is the burn call: same, with `INPUT_GENERATEFIRMWARESLOT="false"`. The golden must show curl was never called.

- [ ] **Step 4: Write the deploy scenarios**

`tests/scenarios/firmware-upload-deploy-sdcard.env` — hash file present:

```bash
ACTION_DIR="firmware-upload"
STEP_ID="deploy-to-fw-storage"

SANDBOX="$(mktemp -d)"
echo "firmware bytes" >"${SANDBOX}/image.img"
echo "aaaabbbbccccdddd" >"${SANDBOX}/image.img.asc"
cd "${SANDBOX}" || exit 1

export INPUT_FIRMWARE_FILE="image.img"
export INPUT_HASHPGP_FILE="image.img.asc"
export INPUT_IMAGE_TYPE="sdcard"
export INPUT_FORCE_OVERWRITE="true"
export INPUT_FULLSLUG="JetHome.j100.Armbian.release.bookworm.edge"
export INPUT_URL="https://fw.jethome.ru"
export INPUT_FWUPLOAD="test-token"
export CHECKVARS_VENDOR="JetHome"
export CHECKVARS_PLATFORM="j100"
export CHECKVARS_SLUG="Armbian.release.bookworm.edge"
export CHECKVARS_VERSION="25.11.1"
```

`-deploy-computed-hash.env`: identical but without the `.asc` file and with `INPUT_HASHPGP_FILE="image.img.asc"` still set — the code branches on `[ ! -e ... ]`, so a missing file means the sha256sum stub runs. This is a real production path whenever signing is skipped.

`-deploy-retry.env`: same as `-deploy-sdcard.env`, plus

```bash
# Стаб curl вернёт неуспех дважды, на третий раз — успех.
export CURL_FAIL_STATE="${SANDBOX}/curl.fail"
echo 2 >"${CURL_FAIL_STATE}"
```

The golden then records three curl invocations with byte-identical argv and two sleep calls.

- [ ] **Step 5: Capture and read every golden**

Run:

```bash
for s in checkvars-minimal checkvars-version hierarchy slot-on slot-off \
         deploy-sdcard deploy-computed-hash deploy-retry; do
  UPDATE_GOLDEN=1 bash tests/run_action.sh "tests/scenarios/firmware-upload-${s}.env"
done
```

Read every file. In particular confirm `deploy-sdcard` shows `[-F] [vendor="JetHome"]` with the literal quotes intact — that is the wire format the refactor must preserve.

- [ ] **Step 6: Run the suite three times**

Run: `bash tests/test_actions.sh && bash tests/test_actions.sh && bash tests/test_actions.sh`
Expected: thirteen `✅ PASSED` lines each time, exit 0. Three runs because the deploy scenarios involve temp files and a counter, which are the most likely sources of non-determinism.

- [ ] **Step 7: Commit**

```bash
git add tests
git commit -m "test: cover firmware-upload with argv goldens

Scenarios follow the two shapes the build workflows actually use — sdcard
with a firmware slot and burn without one — rather than the input list in
action.yml. Also cover the computed-hash branch, taken whenever signing is
skipped, and the retry loop.

The deploy goldens pin the literal quotes in -F fields; curl's own parser
strips them, so they are part of the wire format."
```

---

### Task 4: Goldens for repo-upload and repo-upload-json

**Files:**
- Create: `tests/scenarios/repo-upload-{stable,not-need}.env`, `tests/scenarios/repo-upload-json-{nightly,stable}.env`
- Create: the matching `tests/argv/*.expected`

**Interfaces:**
- Consumes: `tests/run_action.sh`, the `ssh` and `rsync` stubs.

- [ ] **Step 1: Write the repo-upload scenarios**

`tests/scenarios/repo-upload-stable.env`:

```bash
ACTION_DIR="repo-upload"
STEP_ID="deploy-to-repo-storage"

SANDBOX="$(mktemp -d)"
mkdir -p "${SANDBOX}/packages"
touch "${SANDBOX}/packages/linux-image-1.0.deb" "${SANDBOX}/packages/linux-headers-1.0.deb"
cd "${SANDBOX}" || exit 1

export INPUT_USER="repo"
export INPUT_HOSTNAME="repo.jethome.ru"
export INPUT_HOSTPATH="/home/repo/armbian"
export INPUT_DISTRO="bookworm,noble"
export INPUT_BRANCH="stable"
export INPUT_PATH="packages"
export INPUT_FILES="*.deb"
# Шаг genkey кладёт идентификатор ключа в GITHUB_ENV под именем RANDOM.
# В скрипте это имя недопустимо — bash перекрывает его встроенной переменной.
export KEY_ID="ID_424242"
export HOME="${SANDBOX}"
```

`-not-need.env`: same with `INPUT_BRANCH="experimental"`, which takes the early-exit path and writes `output=not_need`.

- [ ] **Step 2: Write the repo-upload-json scenarios**

`tests/scenarios/repo-upload-json-nightly.env`:

```bash
ACTION_DIR="repo-upload-json"
STEP_ID="deploy-to-repo-storage"

SANDBOX="$(mktemp -d)"
mkdir -p "${SANDBOX}/output/debs-beta/extra/noble-utils"
touch "${SANDBOX}/output/debs-beta/linux-image.deb"
touch "${SANDBOX}/output/debs-beta/extra/noble-utils/base-files.deb"
cat >"${SANDBOX}/debs.json" <<'JSON'
[
  {"debs": [{"relative_deb_path": "linux-image.deb"}]},
  {"debs": [{"relative_deb_path": "extra/noble-utils/base-files.deb"}]}
]
JSON
cd "${SANDBOX}" || exit 1

export INPUT_USER="repo"
export INPUT_HOSTNAME="repo.jethome.ru"
export INPUT_HOSTPATH="/home/repo"
export INPUT_TARGET="armbian-test"
export INPUT_NIGHTLY="yes"
export INPUT_JSON="debs.json"
export KEY_ID="ID_424242"
export HOME="${SANDBOX}"
```

The two entries matter: one package at the repository root and one in a subdirectory, which is the case PR #1 fixed. `-stable.env` sets `INPUT_NIGHTLY="no"` so the `debs` directory is used instead of `debs-beta`.

- [ ] **Step 3: Capture and read the goldens**

Run:

```bash
for s in repo-upload-stable repo-upload-not-need \
         repo-upload-json-nightly repo-upload-json-stable; do
  UPDATE_GOLDEN=1 bash tests/run_action.sh "tests/scenarios/${s}.env"
done
```

Confirm the subdirectory case shows an `ssh ... mkdir -p` call before its `rsync`, and the root case does not.

- [ ] **Step 4: Run the suite**

Run: `bash tests/test_actions.sh`
Expected: seventeen `✅ PASSED` lines, exit 0.

- [ ] **Step 5: Commit**

```bash
git add tests
git commit -m "test: cover repo-upload and repo-upload-json with argv goldens

Both actions build an SSH key path from a value passed through GITHUB_ENV
under the name RANDOM. The scenarios pass it as KEY_ID, the name the
extraction has to use — inside a script bash's own RANDOM shadows an
exported variable of that name.

The json scenarios cover a package at the repository root and one in a
subdirectory, the case fixed in PR #1."
```

---

### Task 5: Extract firmware-upload into scripts

The first behaviour-preserving refactor. From here on the goldens do the judging.

**Files:**
- Create: `firmware-upload/scripts/{checkvars,hierarchy,slot,deploy}.sh`
- Modify: `firmware-upload/action.yml`

**Interfaces:**
- Consumes: the environment variable names fixed by `extract_run_block.py`'s `substitute()` in Task 1 — `${{ inputs.x }}` becomes `$INPUT_X`, `${{ steps.checkvars.outputs.y }}` becomes `$CHECKVARS_Y`.
- Produces: `scripts/<step-id>.sh` per step. The driver prefers these over the extractor automatically, keyed on `STEP_ID`.

Script file names must equal the step `id` values: `checkvars.sh`, `apply-fw-template.sh`, `add-fw-slot.sh`, `deploy-to-fw-storage.sh`. The driver looks up `scripts/${STEP_ID}.sh`.

- [ ] **Step 1: Generate the script bodies mechanically**

Do not retype them. Use the extractor that already encodes the substitution rules:

```bash
mkdir -p firmware-upload/scripts
for id in checkvars apply-fw-template add-fw-slot deploy-to-fw-storage; do
  { echo '#!/bin/bash'
    python3 tests/lib/extract_run_block.py firmware-upload/action.yml "${id}"
  } >"firmware-upload/scripts/${id}.sh"
done
chmod +x firmware-upload/scripts/*.sh
```

- [ ] **Step 2: Read all four scripts**

Confirm no `${{` survives anywhere:

```bash
grep -n '\${{' firmware-upload/scripts/*.sh
```

Expected: no output. If anything matches, the substitution rules missed a form; extend `substitute()` rather than hand-editing the script.

- [ ] **Step 3: Rewrite action.yml to call the scripts**

Replace each step's `run: |` body with a script call and an `env:` block. The full replacement for the last step, as the worked example:

```yaml
    - name: Deploy to fw storage
      id: deploy-to-fw-storage
      shell: bash
      env:
        INPUT_FIRMWARE_FILE: ${{ inputs.firmware_file }}
        INPUT_HASHPGP_FILE: ${{ inputs.hashpgp_file }}
        INPUT_IMAGE_TYPE: ${{ inputs.image_type }}
        INPUT_FORCE_OVERWRITE: ${{ inputs.force_overwrite }}
        INPUT_FULLSLUG: ${{ inputs.fullslug }}
        INPUT_URL: ${{ inputs.url }}
        INPUT_FWUPLOAD: ${{ inputs.FWUPLOAD }}
        CHECKVARS_VENDOR: ${{ steps.checkvars.outputs.vendor }}
        CHECKVARS_PLATFORM: ${{ steps.checkvars.outputs.platform }}
        CHECKVARS_SLUG: ${{ steps.checkvars.outputs.slug }}
        CHECKVARS_VERSION: ${{ steps.checkvars.outputs.version }}
      run: bash "${GITHUB_ACTION_PATH}/scripts/deploy-to-fw-storage.sh"
```

The `env:` block for each step lists exactly the variables its script reads. Derive that list mechanically rather than by eye:

```bash
grep -o '\${INPUT_[A-Z_]*}\|\${CHECKVARS_[A-Z_]*}' \
  firmware-upload/scripts/deploy-to-fw-storage.sh | sort -u
```

Note `${GITHUB_ACTION_PATH}` needs no `env:` entry — the runner provides it.

- [ ] **Step 4: Run the suite**

Run: `bash tests/test_actions.sh`
Expected: seventeen `✅ PASSED`, exit 0. The driver now calls the scripts instead of the extractor, and every golden still matches.

- [ ] **Step 5: Prove the goldens were untouched**

Run: `git status --short tests/argv/`
Expected: no output. If any golden changed, the extraction was not behaviour-preserving. Investigate the diff rather than regenerating.

- [ ] **Step 6: Commit**

```bash
git add firmware-upload tests
git commit -m "refactor(firmware-upload): move step bodies into scripts

The shell was unreachable by any linter and untestable while it lived
inside action.yml. Move each step into scripts/<step-id>.sh and pass the
inputs through env instead of interpolating them into the script body,
which also removes a script injection vector.

Behaviour is unchanged: the argv goldens are byte-identical."
```

---

### Task 6: Extract the four remaining actions

**Files:**
- Create: `repo-upload/scripts/{genkey,deploy-to-repo-storage}.sh`, `repo-upload-json/scripts/{genkey,deploy-to-repo-storage}.sh`, `armbian-version/scripts/copyversion.sh`, `armbian-jethome-version/scripts/setversion.sh`
- Modify: the four `action.yml` files

**Interfaces:**
- Consumes: the same substitution rules as Task 5.

- [ ] **Step 1: Generate the script bodies**

```bash
for a in repo-upload repo-upload-json; do
  mkdir -p "${a}/scripts"
  for id in genkey deploy-to-repo-storage; do
    { echo '#!/bin/bash'
      python3 tests/lib/extract_run_block.py "${a}/action.yml" "${id}"
    } >"${a}/scripts/${id}.sh"
  done
done
mkdir -p armbian-version/scripts armbian-jethome-version/scripts
{ echo '#!/bin/bash'; python3 tests/lib/extract_run_block.py armbian-version/action.yml copyversion; } \
  >armbian-version/scripts/copyversion.sh
{ echo '#!/bin/bash'; python3 tests/lib/extract_run_block.py armbian-jethome-version/action.yml setversion; } \
  >armbian-jethome-version/scripts/setversion.sh
chmod +x */scripts/*.sh
```

- [ ] **Step 2: Handle the RANDOM rename**

`genkey.sh` currently contains, after substitution:

```bash
echo "RANDOM=ID_$((RANDOM%1000000))" >> $GITHUB_ENV
echo "HOME=${HOME}" >> $GITHUB_ENV
mkdir -p ${HOME}/.ssh
```

The name written into `GITHUB_ENV` must change, in both actions:

```bash
echo "KEY_ID=ID_$((RANDOM % 1000000))" >>"${GITHUB_ENV}"
```

The `$((RANDOM % 1000000))` on the right-hand side stays — that is bash's generator, which is what was intended. Only the exported name changes. Then every `${KEY_ID}` in `deploy-to-repo-storage.sh` resolves, and the `action.yml` step that consumes it becomes:

```yaml
      env:
        KEY_ID: ${{ env.KEY_ID }}
```

The `ssh-key-action` step in between also references the name and must be updated:

```yaml
        name: ${{ env.KEY_ID }}
        config: |
          Host bastion
            HostName repo.jethome.ru
            User repo
            IdentityFile ${HOME}/.ssh/${{ env.KEY_ID }}
```

- [ ] **Step 3: Verify no GitHub expressions survive**

Run: `grep -rn '\${{' */scripts/*.sh`
Expected: no output.

- [ ] **Step 4: Rewrite the four action.yml files**

Same shape as Task 5: `env:` block listing exactly the variables the script reads, `run: bash "${GITHUB_ACTION_PATH}/scripts/<step-id>.sh"`.

- [ ] **Step 5: Run the suite**

Run: `bash tests/test_actions.sh`
Expected: seventeen `✅ PASSED`, exit 0.

- [ ] **Step 6: Prove the goldens were untouched**

Run: `git status --short tests/argv/`
Expected: no output.

- [ ] **Step 7: Commit**

```bash
git add repo-upload repo-upload-json armbian-version armbian-jethome-version
git commit -m "refactor: move remaining action step bodies into scripts

Same move as firmware-upload. The key identifier that repo-upload and
repo-upload-json pass through GITHUB_ENV is renamed from RANDOM to KEY_ID:
inside a script bash's own RANDOM shadows an exported variable of that
name, which would have silently pointed every ssh call at a key path that
does not exist.

Behaviour is unchanged: the argv goldens are byte-identical."
```

---

### Task 7: Delete the extractor

**Files:**
- Delete: `tests/lib/extract_run_block.py`
- Modify: `tests/run_action.sh`

- [ ] **Step 1: Confirm every step now has a script**

```bash
for s in tests/scenarios/*.env; do
  ( source "$s"; [ -f "${ACTION_DIR}/scripts/${STEP_ID}.sh" ] \
      || echo "MISSING: ${ACTION_DIR}/${STEP_ID}" )
done
```

Expected: no output.

- [ ] **Step 2: Simplify the driver**

Replace the `if [ -f "${SCRIPT}" ]` branch in `tests/run_action.sh` with the direct call:

```bash
SCRIPT="${REPO_DIR}/${ACTION_DIR}/scripts/${STEP_ID}.sh"
bash "${SCRIPT}" >"${WORK}/stdout" 2>&1
RC=$?
```

- [ ] **Step 3: Delete the extractor**

Run: `git rm tests/lib/extract_run_block.py`

- [ ] **Step 4: Run the suite**

Run: `bash tests/test_actions.sh`
Expected: seventeen `✅ PASSED`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add tests
git commit -m "test: drop the run-block extractor

Scaffolding for capturing goldens while the shell still lived inside
action.yml. Every step now has a script and the driver calls it directly."
```

---

### Task 8: Fix shellcheck findings

**Files:**
- Modify: every file under `*/scripts/`, `firmware-upload/generate_hierarchy/tests/test.sh`

Baseline on the current tree: 1 error, 13 warnings, 67 info, 74 style. Target is a clean run at `-S info`.

- [ ] **Step 1: Get the real baseline on the extracted scripts**

Run: `shellcheck -S info -f gcc */scripts/*.sh firmware-upload/generate_hierarchy/tests/test.sh tests/*.sh tests/stubs/* | tee /tmp/baseline.txt; wc -l < /tmp/baseline.txt`

The count will differ from the pre-extraction measurement — the `$GHEXPR` scaffold is gone and real variable names are in place. Work from this list, not the earlier numbers.

- [ ] **Step 2: Fix the quoting findings**

SC2086 dominates. The rule is mechanical: quote the expansion. The one place it is not mechanical is the optional-flag pattern in `add-fw-slot.sh`, which relies on word splitting to become two argv entries. Convert it to an array:

```bash
# Было: строка с кавычками, раскрываемая без кавычек, — ломается на пробеле.
# Стало: массив, каждый элемент — отдельный аргумент curl.
EXTRA_ARGS=()
if [ -n "${INPUT_SUPPORTED_DEVICES}" ]; then
    EXTRA_ARGS+=(-F "supported_devices=\"${INPUT_SUPPORTED_DEVICES}\"")
fi
if [ -n "${INPUT_CHANGELOG_FILE}" ]; then
    EXTRA_ARGS+=(-F "changelog_file=@${INPUT_CHANGELOG_FILE}")
fi
```

and pass `"${EXTRA_ARGS[@]}"` to curl. Note the guard also changes from `[ -z ... ]` to `[ -n ... ]` with the branches swapped — the old form aborts with `[: a: binary operator expected` on a value containing a space.

- [ ] **Step 3: Fix the remaining categories**

- SC2164 — `cd "${DIR}" || exit 1`
- SC2045 in `repo-upload/scripts/deploy-to-repo-storage.sh` — iterating `$(ls ${files})`. Replace with a glob loop. `INPUT_FILES` holds a newline-separated pattern list, so expand each pattern with `compgen -G` and skip patterns that match nothing, preserving today's behaviour where a non-matching pattern contributes nothing.
- SC2129 — replace consecutive `>>` redirections to `$GITHUB_OUTPUT` with a grouped `{ ... } >>`.

- [ ] **Step 4: Run the suite after every file**

Run: `bash tests/test_actions.sh`
Expected: seventeen `✅ PASSED`, exit 0.

Fix one script, run the suite, then move to the next. A golden diff tells you immediately which edit changed behaviour; a batch of edits does not.

- [ ] **Step 5: Confirm shellcheck is clean**

Run: `shellcheck -S info */scripts/*.sh firmware-upload/generate_hierarchy/tests/test.sh tests/*.sh tests/stubs/*`
Expected: no output, exit 0.

- [ ] **Step 6: Prove the goldens were untouched**

Run: `git status --short tests/argv/`
Expected: no output.

- [ ] **Step 7: Commit**

```bash
git add .
git commit -m "fix: quote expansions and drop fragile idioms in action scripts

shellcheck is clean at -S info. The substantive changes: the optional curl
flags in add-fw-slot are built as an array instead of a string re-expanded
without quotes, and the package loop in repo-upload iterates a glob instead
of ls output.

Behaviour is unchanged: the argv goldens are byte-identical."
```

---

### Task 9: Cover the space-in-supported_devices case

The one deliberate behaviour change in this PR. It is safe to make: production only ever passes `D1,D1P`, `D2` or `H1`, so no live call is affected.

**Files:**
- Create: `tests/scenarios/firmware-upload-slot-spaces.env`, `tests/argv/firmware-upload-slot-spaces.expected`

- [ ] **Step 1: Write the scenario**

`tests/scenarios/firmware-upload-slot-spaces.env` — a copy of `-slot-on.env` with one line changed:

```bash
export INPUT_SUPPORTED_DEVICES="D1, D1P"
```

- [ ] **Step 2: Verify the old code would have failed here**

The fix from Task 8 is already committed, so the working tree is clean and there is nothing to stash. Check the scenario against the pre-fix code in a throwaway extraction instead:

```bash
OLD=$(mktemp -d)
git archive HEAD~1 | tar -x -C "$OLD"          # HEAD~1 = перед коммитом Task 8
cp tests/scenarios/firmware-upload-slot-spaces.env "$OLD/tests/scenarios/"
( cd "$OLD" && bash tests/run_action.sh tests/scenarios/firmware-upload-slot-spaces.env )
```

Expected: a failure, with `[: D1,: binary operator expected` in the output. This step exists to confirm the scenario actually exercises the defect rather than passing for unrelated reasons. If it passes there, the scenario is wrong.

- [ ] **Step 3: Capture the golden against the fixed code**

Run: `UPDATE_GOLDEN=1 bash tests/run_action.sh tests/scenarios/firmware-upload-slot-spaces.env`

Read it: the field must arrive as a single argv entry, `[-F] [supported_devices="D1, D1P"]`.

- [ ] **Step 4: Run the suite**

Run: `bash tests/test_actions.sh`
Expected: eighteen `✅ PASSED`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add tests
git commit -m "test: cover supported_devices containing a space

The value used to be re-expanded without quotes, splitting mid-value and
aborting the guard before that. Records the behaviour after the array
rewrite. The build workflows only ever pass comma-separated values, so no
live call was affected."
```

---

### Task 10: Verify from a clean checkout and open the PR

- [ ] **Step 1: Run everything from a clean extraction**

```bash
SP=$(mktemp -d)
git archive HEAD | tar -x -C "$SP"
cd "$SP" && bash tests/test_actions.sh && bash firmware-upload/generate_hierarchy/tests/test.sh
```

Expected: eighteen `✅ PASSED` from the action suite, twelve from the generator suite, exit 0 from both. This is the check that matters — it is the only one no untracked working-tree file can influence.

- [ ] **Step 2: Confirm the goldens survived the whole series**

```bash
git log --oneline --stat feature/action-argv-harness ^master -- tests/argv/
```

Expected: `tests/argv/` appears only in the golden-capture commits from Tasks 1-4 and in the Task 9 commit. If it appears in an extraction or fix commit, the safety argument of the PR is broken and that commit needs investigating.

- [ ] **Step 3: Update CLAUDE.md**

Add the new suite to the Testing section, next to the generator suite:

````markdown
Run action argv tests (from the repository root):
```bash
bash tests/test_actions.sh
```

These execute each action step with stubbed `curl`/`ssh`/`rsync` and compare the
captured argv against `tests/argv/*.expected`. To regenerate a single golden:
`UPDATE_GOLDEN=1 bash tests/run_action.sh tests/scenarios/<name>.env`.
````

Also document under the firmware-upload architecture section that each step's shell lives in `scripts/<step-id>.sh` and receives its inputs through `env:`, and add a line to "Adding a New Project Type" noting that a new action step needs a scenario and a golden.

- [ ] **Step 4: Commit and push**

```bash
git add CLAUDE.md
git commit -m "docs: describe the action argv suite and scripts layout"
git push -u origin feature/action-argv-harness
```

- [ ] **Step 5: Open the PR**

The description must state: the commit ordering and why it is the safety argument; that `tests/argv/` is untouched by the extraction and fix commits, with the `git log --stat` output as evidence; the one intentional behaviour change and why it is safe; the `RANDOM` to `KEY_ID` rename and what it would have broken; and that `set -euo pipefail` was deliberately left out.

## Self-review notes

Spec coverage checked section by section. Every element has a task: harness and stubs (Task 1), scenarios from production shapes (Tasks 2-4), extraction with env inputs (Tasks 5-6), shellcheck to `-S info` (Task 8), the intentional change (Task 9), clean-checkout verification (Task 10). The extractor's lifecycle — created in Task 1, deleted in Task 7 — is the one element the spec did not name; it follows from the decision to capture goldens before touching `action.yml`.

Deferred deliberately, each to its own commit later: the `output=${VER}` single-quote defect in `armbian-version` and `armbian-jethome-version`, `set -euo pipefail`, and the stray untracked files in `generate_hierarchy/`.

CI is deliverable 2 in the spec and gets its own plan after this PR merges.
