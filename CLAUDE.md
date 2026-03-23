# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Collection of GitHub composite actions for JetHome firmware and package management workflows. The main action is **firmware-upload** — it transforms a dot-separated fullslug (e.g. `JetHome.j100.Armbian.release.bookworm.edge`) into a hierarchical JSON structure and uploads firmware to the fw.jethome.com API.

## Actions

| Action | Purpose |
|--------|---------|
| `firmware-upload/` | Parse fullslug → generate JSON hierarchy → upload firmware to fw.jethome.com |
| `repo-upload/` | Upload .deb packages to repo via SSH/rsync |
| `repo-upload-json/` | Upload .deb packages using JSON config (debs-to-repo-info.json) |
| `armbian-version/` | Extract Armbian version from stable/nightly.json |
| `armbian-jethome-version/` | Manage JetHome subversion (increment/decrement/zero) |

## firmware-upload Architecture

### Fullslug Format
```
<vendor>.<platform>.<project>[.<subtype1>.<subtype2>...]
```

### Pipeline (action.yml steps)
1. **checkvars** — parse fullslug into vendor, platform, slug; validate date/version
2. **apply-fw-template** — run `python3 main.py <args>` to generate hierarchy JSON, POST to `/api/import_hierarchy/`
3. **add-fw-slot** (optional) — POST to `/api/create_firmware/` when `generatefirmwareslot: true`
4. **deploy-to-fw-storage** — compute SHA256, upload file to `/api/upload_firmware/` with retry (3 attempts, exponential backoff)

### Hierarchy Generator (`generate_hierarchy/`)

`main.py` loads brand/platform/project from JSON templates, then dispatches to a project-specific module:

| Module | Slug aliases | Subtype format |
|--------|-------------|----------------|
| `armbian.py` | armbian | `channel release [clitype] branch` (3-4 subtypes) |
| `firmware.py` | firmware | `fwtype [device] channel` (2-3 subtypes) |
| `generic.py` | magicos, armbianha, jhaos | `channel` (1 subtype) |
| `burntools.py` | burntools | no subtypes |

Each module exports `generate(subtypes, load_json)` and optionally `ALIAS` list. Templates live in `generate_hierarchy/templates/`.

## Testing

Run hierarchy generator tests (from `firmware-upload/generate_hierarchy/`):
```bash
cd firmware-upload/generate_hierarchy && bash test.sh
```

Tests compare `python3 main.py <args>` output against reference files (`test*.out`). To add a test case, add a `check_main` call in `test.sh` with a new reference output file.

## Code Style

- Python: 4-space indentation (stdlib only, no external dependencies)
- YAML: 2-space indentation
- Shell steps in action.yml use `bash`
- Code comments in Russian

## CI/CD

- All GitHub Actions jobs must use `runs-on: self-hosted` (never GitHub-hosted runners)

## Adding a New Project Type

1. Create `firmware-upload/generate_hierarchy/modules/<slug>.py` with `generate(subtypes, load_json)` function
2. Optionally define `ALIAS = [...]` for alternative names
3. Add entry to `generate_hierarchy/templates/projects.json`
4. Add project-specific templates if needed (e.g. `templates/<slug>/`)
5. Add test cases to `test.sh` with reference output files
