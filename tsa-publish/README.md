# tsa-publish

Publish a firmware release to the JetHome update server `https://tsa.jethome.com`
(update platform v2). This is a second delivery target next to GitHub releases:
test stands and tools pull firmware from here.

API base address is `{url}/{vendor}/{product}/api/v1`, authorized with the
`X-API-Key` header. The key is issued per product.

## The product on the server

The product must already exist and must be created with
`version_order: natural`. Our versions are not semver — neither `v1.16` (two
components and a leading `v`) nor `jxdio-expander-0.1` — and a product left on
the default semver ordering rejects the very first call:

```
POST /releases → 400  version "v1.16" is not semver 2.0.0
```

This is a server-side product setting, nothing the action can do.

Existing products: `jethome/tst-firmware-esp`, `jethome/tst-firmware-mcu`,
`jethome/cp210x-tools` — all three are set to `natural` and keep the last 10
releases on the `release` channel. Retention is a server policy; the action
knows nothing about it.

## Inputs

| Input | Required | Default | Purpose |
|-------|----------|---------|---------|
| `url` | no | `https://tsa.jethome.com` | Base URL of the server |
| `vendor` | no | `jethome` | Vendor slug |
| `product` | yes | | Product slug, the API key is issued per product |
| `version` | yes | | Release version, the whole tag (`v1.16`) |
| `artifacts` | yes | | Artifact list, one per line (see below) |
| `api_key` | yes | | CI API key, pass from secrets |
| `built_at` | no | commit time of the tag | Build time, RFC 3339 in UTC |
| `git_commit` | no | short SHA of the commit | Source commit |
| `publish` | no | | Autopublish channels, space separated |
| `public` | no | | `true` for a public build, empty for an internal one |
| `retry_delay` | no | `10` | Pause in seconds between upload retries |

The release version is used as given: the leading `v` of the tag is **not**
stripped, so the version on the platform matches what the firmware reports
about itself. Allowed characters are `A-Z a-z 0-9 . _ + : ~ -`, which also
covers firmware that versions itself with an ISO timestamp
(`2025-12-23T07:05:42+00:00`).

**Pass `public: 'true'` for a build that is meant to be public.** Without it
the release counts as an internal build and cannot be published into a public
channel at all: the server refuses with `internal build: CI uploaded …`, and
there is no "publish anyway" in the admin panel — an administrator has to mark
the release public first. Tag builds of the firmware matrices are public ones.

Without `publish` the release is only accepted, not published.

## Outputs

| Output | Purpose |
|--------|---------|
| `version` | published release version |
| `artifacts_accepted` | number of accepted artifacts |
| `release` | final release JSON as reported by the server |

## The `artifacts` input

One artifact per line, fields separated by spaces:

```
streams,comma,separated  kind  path  [audience]
```

* `streams` — one or more streams the artifact belongs to. The same file can be
  declared in several streams at once (a shared RAM loader, for example).
* `kind` — artifact kind within the stream (`factory`, `ram`, `loader`, …).
* `path` — path to the file, relative to the workspace. The consumer downloads
  it under the file's base name; `size` and `sha256` are computed from the file.
* `audience` — optional. `internal` keeps the file out of the public tree.

Empty lines and lines starting with `#` are ignored. A `(stream, kind)` pair
must be unique: the upload step addresses artifacts by it.

## Example

Firmware matrix of `jethome-iot/tst-firmware-esp`: a `factory` and a `ram` image
per board, plus a shared `ram_load.py` declared as `loader` in every stream that
has a RAM image.

```yaml
name: Publish firmware
on:
  release:
    types: [published]

jobs:
  publish:
    runs-on: self-hosted
    steps:
      - uses: actions/checkout@v4

      - name: Publish to tsa
        id: tsa
        uses: jethome-iot/actions/tsa-publish@master
        with:
          product: tst-firmware-esp
          version: ${{ github.event.release.tag_name }}
          publish: release
          public: 'true'
          api_key: ${{ secrets.TSA_CI_KEY }}
          artifacts: |
            jxd-r6-e1eth-test-selftest  factory  build/jxd-r6-e1eth-test-selftest.factory.bin
            jxd-r6-e1eth-test-selftest  ram      build/jxd-r6-e1eth-test-selftest-ram.bin
            eeprom-programmer           factory  build/eeprom-programmer.factory.bin
            eeprom-programmer           ram      build/eeprom-programmer-ram.bin
            jxd-pm380-e1eth-powermeter  factory  build/jxd-pm380-e1eth-powermeter.factory.bin
            jxd-pm380-e1eth-powermeter  ram      build/jxd-pm380-e1eth-powermeter-ram.bin
            jxd-r6-e1eth-test-selftest,eeprom-programmer,jxd-pm380-e1eth-powermeter  loader  tools/ram_load.py

      - name: Report
        shell: bash
        run: echo "accepted ${{ steps.tsa.outputs.artifacts_accepted }} artifact(s)"
```

## How it works

1. **prepare** — parse `artifacts`, compute `size` and `sha256` per file,
   build `release-info.json`.
2. **create-release** — `POST {base}/releases`. `201` created, `200` the same
   release already exists (a re-run), `409` the version is already released with
   different files. Then the server's per-channel publish decision is printed
   and artifact sizes are checked against the server's `max_artifact_size`.
3. **upload-artifacts** — per artifact `GET {base}/releases/{version}/artifact`
   for its current `status` and `received`, then `curl -T … -C <received>` to
   send the rest. Up to five attempts with a `retry_delay` pause. Images run up
   to 1.5 GB, so resuming matters.
4. **verify-release** — `GET {base}/releases/{version}`, print it and fail
   unless every artifact is `uploaded` or `published`.

The whole action is safe to re-run on the same release: already accepted
artifacts are skipped, an identical `POST /releases` answers `200`, and a file
the server already stores under the same `sha256` is accepted without an upload.

A server answer of `approval` for a channel is normal, not a failure: public
channels of a product are published by an administrator.

Acceptance is not yet publication. Until a release is published into a channel
it lands in the `full` tree only, which is reachable from networks with full
access, and a permanent file URL answers `404` to an anonymous client. After
publication the same URL serves the file with
`Cache-Control: public, max-age=31536000, immutable`.

## The API key

The key never reaches a command line — on a self-hosted runner the process list
is visible to everyone. It is passed to the steps through the environment and
handed to `curl` in a config file with mode `0600` (`curl_api_config.sh`),
removed by a `trap`, and registered with `::add-mask::` so the runner masks it
in logs.

## Tests

Run without a server or a key:

```bash
bash tsa-publish/tests/test.sh
```

The suite checks `artifacts` parsing, `release-info.json` assembly against
golden files and parsing of server responses. Two checks run against a stdlib
stub listener instead of the real server: the `Content-Range` that
`curl -T … -C <offset>` actually sends, which the upload step relies on, and
that the API key survives escaping into the `curl` config and arrives in the
`X-API-Key` header unchanged. To regenerate golden files:
`UPDATE_GOLDEN=1 bash tsa-publish/tests/test.sh`.

Publishing itself is not covered: it needs the server and a key.
