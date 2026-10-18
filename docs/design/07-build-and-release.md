# 07. Build and release

How Fil is built, checked, signed, notarized and published, and the repository files around that. The code
and the workflow files are the truth for what exists; this chapter describes them and specifies the changes
from issues #22-#25 and #27-#30.

Status tags: **[Exists]** is in the repository today (file reference given), **[Change]** is a required change
to something that exists (reason and issue given), **[New]** is something that does not exist yet.
Secrets are named, never shown.

## 1. Swift package (`Package.swift`)

**[Exists]** `// swift-tools-version: 6.0`, package name `Fil`, `platforms: [.macOS("27.0")]`. Apple Silicon
only is a policy (CLAUDE.md), not a manifest setting; release builds pass `--arch arm64`.

| Target | Kind | Path | Dependencies | Product |
|---|---|---|---|---|
| `ScanCore` | library | `Sources/ScanCore` | none | `.library(name: "ScanCore")` |
| `CleanCore` | library | `Sources/CleanCore` | `ScanCore`, `Subprocess` (swift-subprocess) | `.library(name: "CleanCore")` |
| `MapCore` | library | `Sources/MapCore` | `CleanCore` | `.library(name: "MapCore")` |
| `fil` | executable | `Sources/fil` | `CleanCore`, `ScanCore` | `.executable(name: "fil")` |
| `TestSupport` | library (not a product) | `Tests/TestSupport` | none | none |
| `ScanCoreTests` | test | `Tests/ScanCoreTests` | `ScanCore`, `TestSupport` | |
| `CleanCoreTests` | test | `Tests/CleanCoreTests` | `CleanCore`, `ScanCore`, `TestSupport` | |
| `FilTests` | test | `Tests/FilTests` | `fil` | |
| `MapCoreTests` | test | `Tests/MapCoreTests` | `MapCore`, `CleanCore` | |

External dependency **[Exists]**: `https://github.com/swiftlang/swift-subprocess.git`, `exact: "1.0.2"`.
`Package.resolved` (version 3) pins it at revision `dbe21bd7dfd4ffef8c32588918542a8abfa1b54c` and its transitive
dependency `https://github.com/apple/swift-system` at `1.8.1` (`869129b7bf4ecc57b97d0193ad29690ca2134750`).
`Package.resolved` is committed.

## 2. Toolchain

- **[Exists]** Local: Xcode 27 with the macOS 27 SDK (`xcode-select -p` = `/Applications/Xcode.app/Contents/Developer`,
  Apple Swift 6.4, target `arm64-apple-macosx27.0.0` on the maintainer's machine). The bundled `swift format`
  is available (`swift format --version` prints `main`).
- **[Exists]** CI and release: GitHub-hosted runner label `xcode-27`, a preview image (macOS 27.0.1; Xcode 27.0,
  27.1 RC, 27.2 beta; arm64), the only hosted image with the macOS 27 SDK. Preview images are outside the Actions
  SLA. The `macos-*` labels (latest macOS 26) cannot build the package. Both workflows set
  `DEVELOPER_DIR=/Applications/Xcode_27.1_Release_Candidate.app/Contents/Developer`
  (`.github/workflows/ci.yml:17-21`, `release.yml:25`).
- **[Change]** When Xcode 27.1 is released, the image path changes. Keep the path in one place per workflow
  (job-level or workflow-level `env.DEVELOPER_DIR`, as now) and let the "Toolchain" step fail loudly:
  `test -d "$DEVELOPER_DIR" || { echo "::error::$DEVELOPER_DIR missing on this image"; ls -d /Applications/Xcode*; exit 1; }`.
  Reason: a renamed Xcode path today fails later with an unclear `xcrun` error. Issue: none yet; ship with #23.

## 3. CI workflow (`.github/workflows/ci.yml`)

**[Exists]**:

- `name: CI`. Triggers: `push` (every branch and every tag) and `pull_request`.
- `concurrency: group: ci-${{ github.ref }}`, `cancel-in-progress: true`.
- No `permissions:` block (the token gets the repository default).
- One job `build-and-test`, `runs-on: xcode-27`, `timeout-minutes: 30`, env `DEVELOPER_DIR` as above. Steps:
  1. `actions/checkout@v4`
  2. `Toolchain`: `xcrun --show-sdk-version`, `swift --version`
  3. `Build (release)`: `swift build -c release`
  4. `Test`: `swift test` (comment: if fseventsd misbehaves on the runner, add `--skip FSEvents`; the suite
     "Incremental update vs full scan (FSEvents)" replays real FSEvents history).
- `scripts/verify.sh` and `scripts/verify-clean.sh` do not run in CI.

Target `ci.yml` after #23 and #28 (complete; `<sha>` is resolved as in section 13.2):

```yaml
name: CI

on:
  push:
    branches: ["**"]        # branches only; a tag push is tested by the release workflow
  pull_request:

permissions:
  contents: read

concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true

jobs:
  build-and-test:
    runs-on: xcode-27
    timeout-minutes: 30
    env:
      DEVELOPER_DIR: /Applications/Xcode_27.1_Release_Candidate.app/Contents/Developer
    steps:
      - uses: actions/checkout@<sha> # v4.x.y
        with:
          persist-credentials: false

      - name: Toolchain
        run: |
          test -d "$DEVELOPER_DIR" || { echo "::error::$DEVELOPER_DIR missing on this image"; ls -d /Applications/Xcode*; exit 1; }
          xcrun --show-sdk-version
          swift --version

      - name: Format
        run: swift format lint --strict --recursive Package.swift Sources Tests

      - name: Build (release)
        run: swift build -c release

      - name: Test
        run: swift test

      - name: Completions and man page
        run: scripts/check-completions.sh
```

The required status check name is the job id `build-and-test` (unchanged), so branch protection (section 13.6)
refers to it.

## 4. Verification scripts

Both are bash (`#!/usr/bin/env bash`), use `set -uo pipefail` **without** `-e` on purpose (they count failures
and keep going), build with `swift build -c release`, use `$ROOT/.build/release/fil`, create every fixture with
`mktemp -d` under `/private/tmp`, set `FIL_SNAPSHOT_DIR` to a private temp directory (never the real snapshot
cache), and remove only paths that start with their own prefixes (trap on `EXIT`; `INT`/`TERM` exit 130).
Exit 0 = all pass, 1 = a failure or build failure.

### 4.1 `scripts/verify.sh`: scan engine **[Exists]**

Checks `fil scan --porcelain` incrementally (FSEvents) against a full scan and against `du -skx`.

- Prefixes: fixtures `/private/tmp/fil-verify.`, snapshots `/private/tmp/fil-verify-snap.`. `FSEVENTS_WAIT=3` seconds.
- Probe (exit 2 if it fails): `fil scan <tmp> --porcelain` must print exactly one line matching
  `^mode=(full|incremental) alloc=N logical=N files=N dirs=N cloneaware=N shared=N( unreadable=N)?$`.
- Per scenario: setup -> baseline scan (must be `mode=full`) -> change -> sleep -> scan (the incremental run)
  -> `scan --full`. Checks:
  - incremental mode when the scenario expects it (`EXPECT=incremental`; `any` accepts a full fallback);
  - `alloc`, `logical`, `files`, `dirs`, `cloneaware`, `shared` equal between incremental and full;
  - full `alloc` == `du -skx` KiB x 1024;
  - `cloneaware + shared == alloc`;
  - for clone scenarios, `shared` equals an expected value computed from `stat -f %b` x 512.
- 18 scenarios: add files; delete dir tree; new nested dirs with files; grow existing file; rename dir;
  move file between dirs; delete 1 of 1000 files; hardlink: new link, old file (`any`); hardlink: delete owner
  link; hardlink: delete peer link; hardlink: new file, 2 links; no wait: rapid changes (wait 0);
  hardlink: grow via link A; hardlink: grow via link B; clone: new file, 2 clones; clone: old file, 2 new clones;
  clone: delete original; clone: grow one clone.
- Output: `PASS <name>  (...)` / `FAIL <name>: <diffs>`, then `N/M scenarios passed`.
- **[Change]** The comment at `scripts/verify.sh:248` says snapshots never go "to ~/Library/Caches/Fil"; the real
  default is `~/Library/Caches/com.vucod.Fil/snapshots` (`Sources/ScanCore/Snapshot.swift:29`). Fix the comment.
  Reason: wrong path in a safety comment. Ship with #25.

### 4.2 `scripts/verify-clean.sh`: `fil list` / `fil clean` **[Exists]**

Every `fil` call gets `--home <fixture>`. `clean --yes` really moves items to `~/.Trash`; the script then
removes exactly the Trash path `fil` printed, after checking it lies under `~/.Trash/`.

- Prefixes: `/private/tmp/fil-verify.`, `/private/tmp/fil-verify-outside.`, `/private/tmp/fil-verify-snap.`.
- Build retried up to 3 times, 10 s apart (another build may hold the lock).
- Fixture: DerivedData `a` 5,000,000 B; `x.xcarchive` 2,000,000; `Caches/com.example.app` 3,000,000;
  `Caches/com.apple.bird` 2,000,000; `Caches/Homebrew` 2,000,000; `Logs/foo` 2,000,000; `proj/node_modules`
  4,000,000 with a nested `node_modules`; `rust/target` 2,000,000; `Caches/tiny` 500,000; a symlink
  `Caches/link` to a 3,000,000 B directory outside the fixture.
- Checks (`PASS`/`FAIL` lines, then `N/M checks passed`):
  1. `fil list --json` parses; the candidate set is exactly the expected 8 ids; rule, safety, removal per
     candidate; the `com.apple.bird` note mentions macOS; tiny, link and nested `node_modules` absent; each
     candidate's `bytes` == `du -sk` x 1024; exit 0. (Run in `python3 -I`.)
  2. `fil clean xcode-archives` without `--yes` changes nothing (name, size, mtime of every entry).
  3. `fil clean xcode-archives --yes` (by rule id) keeps the `careful` archive.
  4. `fil clean xcode-derived --yes`: exit 0, output names a `~/.Trash` path that exists; the next `list` no
     longer shows the candidate.
  5. `fil clean xcode-archives:Library/Developer/Xcode/Archives/x.xcarchive --yes` (by candidate id) moves the
     careful archive to the Trash.
  6. A nonexistent id makes `clean` exit non-zero.

**[Change]** (#25) Add this comment directly above `set -uo pipefail` in both scripts:
`# No -e on purpose: every check runs and failures are counted; the exit code is set at the end.`

## 5. Versioning

- **[Exists]** The single version constant is `let version = "0.1.1"` at `Sources/fil/main.swift:3`.
  `fil --version` / `fil -V` print `fil <version>`. Tags are `v<version>` (existing: `v0.1.0`, `v0.1.1`).
- **[Exists]** Checks that keep them equal: `scripts/release.sh` greps `^let version = "<VERSION>"$`
  (line 24) and compares `fil --version` of the signed binary with `fil <VERSION>` (line 41); the release
  workflow takes the version from the tag (`${GITHUB_REF_NAME#v}`) or, for a manual run, from `main.swift`.
- **[New]** Scheme: Semantic Versioning. Before 1.0, a minor bump (`0.x.0`) may break the public API of the
  libraries (e.g. MapCore, chapter 06 section 8) or `--porcelain` consumers; porcelain fields are still only
  appended. Patch = fixes only.

## 6. `scripts/release.sh` today **[Exists]**

zsh (`#!/bin/zsh`), `set -euo pipefail`. Usage `scripts/release.sh 0.1.1`. Builds, signs and notarizes;
publishing is the workflow's job. Steps (line numbers):

1. `VERSION=${1:?...}` (13). Notary auth (14-18): if `FIL_NOTARY_KEY` is set, App Store Connect API key
   (`--key $FIL_NOTARY_KEY --key-id $FIL_NOTARY_KEY_ID --issuer $FIL_NOTARY_ISSUER`, the latter two required);
   otherwise a notarytool keychain profile `--keychain-profile ${FIL_NOTARY_PROFILE:-fil-notary}` created once with
   `xcrun notarytool store-credentials`.
2. `ROOT=${0:A:h:h}`, `DIST=$ROOT/dist`, `NAME=fil-$VERSION-arm64`; `cd $ROOT` (19-23).
3. Version guard: `grep -q "^let version = \"$VERSION\"$" Sources/fil/main.swift` (24-25).
4. Clean tree guard: `git status --porcelain` must be empty (26). `dist/` is gitignored.
5. Identity (29-31): `FIL_SIGN_IDENTITY`, or the SHA-1 hash of the first `"Developer ID Application` identity
   from `security find-identity -v -p codesigning` (by hash, because the same certificate can be listed twice).
6. Build (33-34): `swift build -c release --arch arm64`; binary from `--show-bin-path`.
7. Stage and sign (36-41): `rm -rf $DIST/$NAME && mkdir -p $DIST/$NAME`; copy `fil`;
   `codesign --force --options runtime --timestamp --sign $IDENTITY --identifier com.productdevbook.fil`;
   `codesign --verify --strict --verbose=2`; `fil --version` must print `fil $VERSION`.
8. Notarize (44-46): `ditto -c -k` the binary into `$DIST/$NAME.zip` (notarytool needs a container);
   `xcrun notarytool submit ... --wait`; delete the zip. A bare Mach-O cannot be stapled: Gatekeeper looks the
   ticket up online.
9. Gatekeeper wait (50-54): up to 40 tries, 30 s apart (20 minutes), until
   `codesign -v --check-notarization -R=notarized $DIST/$NAME/fil` succeeds; otherwise exit 1 with
   "notarization ticket not visible after 20 minutes". Reason in the code: "Accepted" comes minutes before the
   online lookup finds the ticket, and a binary published earlier is killed on first run.
10. Tarball (56-57): `tar -C $DIST/$NAME -czf $DIST/$NAME.tar.gz fil` (archive root = `fil` only);
    `shasum -a 256 $DIST/$NAME.tar.gz | tee $DIST/$NAME.tar.gz.sha256`.

Contradiction found: step 10 writes the absolute path into the `.sha256` file. The published
`fil-0.1.1-arm64.tar.gz.sha256` contains `/Users/runner/work/fil/fil/dist/fil-0.1.1-arm64.tar.gz`, so
`shasum -c` fails for a user who downloads both files. Fixed in section 11.4.

## 7. `.github/workflows/release.yml` today **[Exists]**

- Triggers: `push: tags: ["v*"]` and `workflow_dispatch` (manual run: build, sign, notarize, publish nothing).
- `permissions: contents: write` for the whole workflow. `concurrency: group: release`, `cancel-in-progress: false`.
- One job `release`, `runs-on: xcode-27`, `timeout-minutes: 45`, `DEVELOPER_DIR` as CI. Steps:
  1. `actions/checkout@v4`.
  2. `Version`: `VERSION` = tag without `v`, or for a manual run `sed -n 's/^let version = "\(.*\)"$/\1/p' Sources/fil/main.swift`; written to `$GITHUB_ENV`.
  3. `Import the Developer ID certificate` (secrets `DEVELOPER_ID_CERTIFICATE_BASE64`, `DEVELOPER_ID_CERTIFICATE_PASSWORD`):
     create `$RUNNER_TEMP/signing.keychain-db` with a random (`uuidgen`) password; `set-keychain-settings -lut 21600`;
     unlock; decode the certificate to `$RUNNER_TEMP/cert.p12`; `security import ... -T /usr/bin/codesign`;
     `set-key-partition-list -S apple-tool:,apple:`; make it the user keychain list; delete `cert.p12`.
  4. `Build, sign and notarize` (secrets `ASC_KEY_P8`, `ASC_KEY_ID` as `FIL_NOTARY_KEY_ID`, `ASC_ISSUER_ID` as
     `FIL_NOTARY_ISSUER`): write the key to `$RUNNER_TEMP/AuthKey.p8`, run `scripts/release.sh "$VERSION"`, delete the key.
  5. `Publish the GitHub release` (tags only, `GH_TOKEN: github.token`): `gh release create "$GITHUB_REF_NAME"`
     with the tarball and `.sha256`, `--title "fil $VERSION" --verify-tag --generate-notes`, notes: signed and
     notarized, the `brew install --cask productdevbook/tap/fil` line, the SHA-256.
  6. `Update the Homebrew cask` (tags only, secret `TAP_DEPLOY_KEY`): key to `~/.ssh/tap_key`;
     `GIT_SSH_COMMAND="ssh -i ~/.ssh/tap_key -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"`;
     `git clone --depth 1 git@github.com:productdevbook/homebrew-tap.git`; `sed -i '' -E` replaces the
     `  version "..."` and `  sha256 "..."` lines of `Casks/fil.rb`; `git diff --stat`; commit `fil $VERSION` as
     `github-actions[bot]`; `git push origin HEAD`; delete the key.
  7. `Remove the signing keychain` (`if: always()`): `security delete-keychain ... || true`.

Gaps (each fixed below): no tests before signing (#22); actions pinned by tag, write token in every step (#23);
cask edit unchecked, no audit, key and `AuthKey.p8`/`cert.p12` left behind when a step fails (#24).

The Homebrew tap is the repository `productdevbook/homebrew-tap` (default branch `main`), used as
`productdevbook/tap`. Its `Casks/fil.rb` today **[Exists]** has `version`, `sha256`, `url
"https://github.com/productdevbook/fil/releases/download/v#{version}/fil-#{version}-arm64.tar.gz"`, `name "Fil"`,
`desc "Fast disk scanner and cleaner"`, `homepage`, `livecheck` (`url :url`, `strategy :github_latest`),
`depends_on arch: :arm64`, `depends_on macos: :golden_gate`, `binary "fil"`,
`zap trash: "~/Library/Caches/com.vucod.Fil/snapshots"`.

## 8. Secrets (names only)

| Secret | Used by | Content (description only) |
|---|---|---|
| `DEVELOPER_ID_CERTIFICATE_BASE64` | release, import step | base64 of the "Developer ID Application" certificate + private key as .p12 |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | release, import step | password of that .p12 |
| `ASC_KEY_P8` | release, notarize step | App Store Connect API private key (.p8 text) |
| `ASC_KEY_ID` | release, notarize step | its key id |
| `ASC_ISSUER_ID` | release, notarize step | its issuer id |
| `TAP_DEPLOY_KEY` | release, tap step | SSH private key of a deploy key with write access to `productdevbook/homebrew-tap` |
| `GITHUB_TOKEN` (built in) | release publish, CLA workflow | not a stored secret |

Local equivalents for `scripts/release.sh`: `FIL_NOTARY_KEY` (path to .p8), `FIL_NOTARY_KEY_ID`,
`FIL_NOTARY_ISSUER`, or `FIL_NOTARY_PROFILE`; optional `FIL_SIGN_IDENTITY`. No new secret is needed by any
change in this chapter.

## 9. Contribution flow

- **[Exists]** `CONTRIBUTING.md`: `swift build`, `swift build -c release`, `swift test`, `scripts/verify.sh`
  before a PR; follow `CLAUDE.md` and the file's style; the three engine rules (no per-file syscalls on the
  hot path; sizes equal `du -skx`; never unlink user data); engine changes come with a before/after benchmark and a
  `du` comparison; one change per PR, tests added, what and why described; CLA required.
- **[Exists]** `CLA.md`: individual CLA modelled on the Apache ICLA (copyright and patent license incl. the right to
  relicense; representations; signing "through the CLA Assistant bot on Your first pull request").
- **[Exists]** Security reports go to GitHub Security Advisories (`SECURITY.md`); only the latest release and
  `main` get fixes.
- Contradiction (#29): `CONTRIBUTING.md` and `CLA.md` section 6 describe a CLA Assistant bot; nothing in the
  repository runs one. See section 13.7.

## 10. Repository files

**[Exists]**:

| Path | Purpose |
|---|---|
| `README.md` | what Fil is, install (`brew install --cask productdevbook/tap/fil`), build, usage, safety model |
| `LICENSE` | GPL-3.0 |
| `CONTRIBUTING.md`, `CLA.md`, `SECURITY.md`, `TRADEMARK.md` | contribution rules, CLA text, vulnerability reporting, name and logo policy |
| `CLAUDE.md` | conventions and engine rules for coding agents and contributors |
| `.claude/settings.json`, `.claude/agents/macos-engineer.md`, `.claude/agents/scan-tester.md` | agent configuration |
| `.gitignore` | `.build/`, `.swiftpm/`, `*.xcodeproj`, `DerivedData/`, `dist/` |
| `Package.swift`, `Package.resolved` | package manifest and pinned dependencies |
| `Sources/`, `Tests/` | code and tests (section 1) |
| `scripts/verify.sh`, `scripts/verify-clean.sh`, `scripts/release.sh` | sections 4 and 6 |
| `.github/workflows/ci.yml`, `.github/workflows/release.yml` | sections 3 and 7 |
| `docs/specs/accounting.md`, `docs/specs/cleanup-rules.md` | engine and cleanup specs |
| `docs/design/` | design chapters (this one) |
| `branding/` | `fil-icon.svg`, `fil-mark.svg` and PNG renders |

**[New]** (introduced by section 13): `CHANGELOG.md`, `.swift-format`, `.git-blame-ignore-revs`,
`.github/dependabot.yml`, `.github/CODEOWNERS`, `.github/PULL_REQUEST_TEMPLATE.md`,
`.github/ISSUE_TEMPLATE/bug_report.yml`, `.github/ISSUE_TEMPLATE/feature_request.yml`,
`.github/ISSUE_TEMPLATE/config.yml`, `.github/workflows/cla.yml`, `completions/fil`, `completions/_fil`,
`completions/fil.fish`, `man/fil.1`, `packaging/homebrew/fil.rb.in`, `scripts/check-completions.sh`.

## 11. Target `scripts/release.sh`

### 11.1 Quoting (#25) **[Change]**

Reason: unquoted expansions (`--key $FIL_NOTARY_KEY`, `$DIST/$NAME`, `cp $BIN`, `--sign $IDENTITY`) are not
word-split by zsh but are still subject to globbing, and break under `SH_WORD_SPLIT` or another shell.
`set -euo pipefail` is already present (line 11); #25 asks to add it, so that part is done. Keep `#!/bin/zsh`.

### 11.2 Notarization result **[Change]**

Reason: the script relies on `notarytool submit --wait` and then on the 20-minute Gatekeeper loop to notice a
rejected submission; a rejection should fail at once with Apple's log. Issue: none yet; ship with #25.

### 11.3 Completions and man page in the tarball (#27) **[Change]**

Reason: the tarball contains only the binary, so the cask cannot install completions or a man page. The files
(section 13.5) are copied into the staging directory next to `fil` and archived with it.

### 11.4 Checksum file with a relative name **[Change]**

Reason: section 6, contradiction. Ship with #25.

### 11.5 Complete target text

```zsh
#!/bin/zsh
# Build, sign and notarize the fil CLI, and write the release tarball to dist/.
#
#   scripts/release.sh 0.1.2
#
# Needs a "Developer ID Application" identity in the keychain and notary credentials: either an
# App Store Connect API key (FIL_NOTARY_KEY = path to the .p8, FIL_NOTARY_KEY_ID, FIL_NOTARY_ISSUER),
# as in .github/workflows/release.yml, or a notarytool keychain profile (FIL_NOTARY_PROFILE,
# default "fil-notary"), created once with `xcrun notarytool store-credentials`.
# Publishing (GitHub release, Homebrew cask) is done by the release workflow.
set -euo pipefail

VERSION=${1:?usage: scripts/release.sh <version>}
if [[ -n "${FIL_NOTARY_KEY:-}" ]]; then
  NOTARY_AUTH=(--key "$FIL_NOTARY_KEY" --key-id "${FIL_NOTARY_KEY_ID:?}" --issuer "${FIL_NOTARY_ISSUER:?}")
else
  NOTARY_AUTH=(--keychain-profile "${FIL_NOTARY_PROFILE:-fil-notary}")
fi
ROOT=${0:A:h:h}
DIST="$ROOT/dist"
NAME="fil-$VERSION-arm64"
STAGE="$DIST/$NAME"

cd "$ROOT"
grep -qxF "let version = \"$VERSION\"" Sources/fil/main.swift \
  || { echo "Sources/fil/main.swift does not declare version $VERSION" >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "working tree is not clean" >&2; exit 1; }

# The same certificate can appear several times in the keychain list; sign by its hash.
IDENTITY=${FIL_SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
  | awk '/"Developer ID Application/ { print $2; exit }')}
[[ -n "$IDENTITY" ]] || { echo "no Developer ID Application identity found" >&2; exit 1; }

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/fil"

rm -rf -- "$STAGE"
mkdir -p "$STAGE/completions" "$STAGE/man"
cp "$BIN" "$STAGE/fil"
cp completions/fil completions/_fil completions/fil.fish "$STAGE/completions/"
cp man/fil.1 "$STAGE/man/"
codesign --force --options runtime --timestamp --sign "$IDENTITY" \
  --identifier com.productdevbook.fil "$STAGE/fil"
codesign --verify --strict --verbose=2 "$STAGE/fil"
[[ "$("$STAGE/fil" --version)" == "fil $VERSION" ]] || { echo "version check failed" >&2; exit 1; }

# notarytool takes a zip; a bare Mach-O cannot be stapled, Gatekeeper checks the ticket online.
ditto -c -k "$STAGE/fil" "$DIST/$NAME.zip"
RESULT=$(xcrun notarytool submit "$DIST/$NAME.zip" "${NOTARY_AUTH[@]}" --wait --output-format json)
rm -f -- "$DIST/$NAME.zip"
STATUS=$(plutil -extract status raw -o - - <<<"$RESULT")
if [[ "$STATUS" != Accepted ]]; then
  echo "notarization status: $STATUS" >&2
  xcrun notarytool log "$(plutil -extract id raw -o - - <<<"$RESULT")" "${NOTARY_AUTH[@]}" >&2 || true
  exit 1
fi

# "Accepted" comes minutes before Gatekeeper's online lookup finds the ticket; a release published
# earlier is killed on first run. Wait until the ticket is visible.
for i in {1..40}; do
  codesign -v --check-notarization -R=notarized "$STAGE/fil" 2>/dev/null && break
  (( i == 40 )) && { echo "notarization ticket not visible after 20 minutes" >&2; exit 1; }
  sleep 30
done

tar -C "$STAGE" -czf "$DIST/$NAME.tar.gz" fil completions man
(cd "$DIST" && shasum -a 256 "$NAME.tar.gz") | tee "$DIST/$NAME.tar.gz.sha256"
```

Tarball layout after the change (archive root): `fil`, `completions/fil`, `completions/_fil`,
`completions/fil.fish`, `man/fil.1`. The `.sha256` file is one line `<64 hex>  fil-X.Y.Z-arm64.tar.gz`.
Only `fil` is signed and notarized; the text files need neither.

Check: `zsh -n scripts/release.sh`; a local run with a keychain profile produces the five-entry tarball
(`tar -tzf dist/fil-*-arm64.tar.gz`) and `(cd dist && shasum -c fil-*-arm64.tar.gz.sha256)` prints `OK`.

## 12. Target `.github/workflows/release.yml`

Changes in one place: #22 (gate), #23 (SHA pins, least privilege), #24 (cask verification, cleanup), #27
(cask template with completion and man stanzas), #28 (changelog notes, format check). The single job is split
into four, so the signing secrets, the write token and the tap key never share a job.

| Job | Runner | Token permissions | Secrets | Runs when |
|---|---|---|---|---|
| `test` | `xcode-27` | `contents: read` | none | always |
| `build` | `xcode-27` | `contents: read` | certificate, notary key | after `test` |
| `publish` | `ubuntu-24.04` | `contents: write` | none | tags only, after `build` |
| `tap` | `xcode-27` | none (`{}`) | `TAP_DEPLOY_KEY` | tags only, after `publish` |

Complete target text (`<sha>`: section 13.2):

```yaml
name: Release

# Push a tag `vX.Y.Z` whose version matches Sources/fil/main.swift and that is on main. The workflow tests,
# builds, signs and notarizes `fil`, publishes the GitHub release and updates the cask in
# productdevbook/homebrew-tap. A manual run (Actions tab) tests, builds, signs and notarizes the current
# version without publishing anything.
on:
  push:
    tags: ["v*"]
  workflow_dispatch:

permissions: {}

concurrency:
  group: release
  cancel-in-progress: false

env:
  DEVELOPER_DIR: /Applications/Xcode_27.1_Release_Candidate.app/Contents/Developer

jobs:
  test:
    runs-on: xcode-27
    timeout-minutes: 30
    permissions:
      contents: read
    outputs:
      version: ${{ steps.version.outputs.version }}
    steps:
      - uses: actions/checkout@<sha> # v4.x.y
        with:
          fetch-depth: 0
          persist-credentials: false

      - name: Version
        id: version
        run: |
          V=$(sed -n 's/^let version = "\(.*\)"$/\1/p' Sources/fil/main.swift)
          [[ -n "$V" ]] || { echo "::error::no version in Sources/fil/main.swift"; exit 1; }
          if [[ "$GITHUB_REF_TYPE" == tag && "$GITHUB_REF_NAME" != "v$V" ]]; then
            echo "::error::tag $GITHUB_REF_NAME does not match version $V in Sources/fil/main.swift"; exit 1
          fi
          grep -q "^## \[$V\] - " CHANGELOG.md || { echo "::error::CHANGELOG.md has no section for $V"; exit 1; }
          echo "version=$V" >> "$GITHUB_OUTPUT"

      - name: Tag is on main
        if: github.ref_type == 'tag'
        run: git merge-base --is-ancestor "$GITHUB_SHA" origin/main

      - name: Toolchain
        run: |
          test -d "$DEVELOPER_DIR" || { echo "::error::$DEVELOPER_DIR missing on this image"; exit 1; }
          xcrun --show-sdk-version
          swift --version

      - name: Format
        run: swift format lint --strict --recursive Package.swift Sources Tests

      - name: Build (release)
        run: swift build -c release

      - name: Test
        run: swift test

      - name: Completions and man page
        run: scripts/check-completions.sh

  build:
    needs: test
    runs-on: xcode-27
    timeout-minutes: 45
    permissions:
      contents: read
    env:
      VERSION: ${{ needs.test.outputs.version }}
    outputs:
      sha256: ${{ steps.sum.outputs.sha256 }}
    steps:
      - uses: actions/checkout@<sha> # v4.x.y
        with:
          persist-credentials: false

      - name: Import the Developer ID certificate
        env:
          CERTIFICATE_BASE64: ${{ secrets.DEVELOPER_ID_CERTIFICATE_BASE64 }}
          CERTIFICATE_PASSWORD: ${{ secrets.DEVELOPER_ID_CERTIFICATE_PASSWORD }}
        run: |
          KEYCHAIN="$RUNNER_TEMP/signing.keychain-db"
          KEYCHAIN_PASSWORD=$(uuidgen)
          security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
          security set-keychain-settings -lut 21600 "$KEYCHAIN"
          security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
          printf '%s' "$CERTIFICATE_BASE64" | base64 --decode > "$RUNNER_TEMP/cert.p12"
          security import "$RUNNER_TEMP/cert.p12" -k "$KEYCHAIN" -P "$CERTIFICATE_PASSWORD" -T /usr/bin/codesign
          security set-key-partition-list -S apple-tool:,apple: -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
          security list-keychains -d user -s "$KEYCHAIN"
          rm -f "$RUNNER_TEMP/cert.p12"

      - name: Build, sign and notarize
        env:
          ASC_KEY_P8: ${{ secrets.ASC_KEY_P8 }}
          FIL_NOTARY_KEY_ID: ${{ secrets.ASC_KEY_ID }}
          FIL_NOTARY_ISSUER: ${{ secrets.ASC_ISSUER_ID }}
        run: |
          export FIL_NOTARY_KEY="$RUNNER_TEMP/AuthKey.p8"
          printf '%s' "$ASC_KEY_P8" > "$FIL_NOTARY_KEY"
          scripts/release.sh "$VERSION"

      - name: Checksum
        id: sum
        run: echo "sha256=$(cut -d' ' -f1 "dist/fil-$VERSION-arm64.tar.gz.sha256")" >> "$GITHUB_OUTPUT"

      - uses: actions/upload-artifact@<sha> # v4.x.y
        with:
          name: release
          path: |
            dist/fil-${{ env.VERSION }}-arm64.tar.gz
            dist/fil-${{ env.VERSION }}-arm64.tar.gz.sha256
          if-no-files-found: error
          retention-days: 7

      - name: Remove signing material
        if: always()
        run: |
          security delete-keychain "$RUNNER_TEMP/signing.keychain-db" || true
          rm -f "$RUNNER_TEMP/cert.p12" "$RUNNER_TEMP/AuthKey.p8"

  publish:
    needs: [test, build]
    if: github.ref_type == 'tag'
    runs-on: ubuntu-24.04
    timeout-minutes: 10
    permissions:
      contents: write
    env:
      VERSION: ${{ needs.test.outputs.version }}
      SHA256: ${{ needs.build.outputs.sha256 }}
    steps:
      - uses: actions/checkout@<sha> # v4.x.y
        with:
          persist-credentials: false

      - uses: actions/download-artifact@<sha> # v4.x.y
        with:
          name: release
          path: dist

      - name: Verify the checksum
        run: (cd dist && sha256sum -c "fil-$VERSION-arm64.tar.gz.sha256")

      - name: Release notes
        run: |
          awk -v h="## [$VERSION] " 'index($0, h) == 1 { f = 1; next } /^## \[/ { f = 0 } f' CHANGELOG.md \
            > "$RUNNER_TEMP/notes.md"
          [[ -n "$(tr -d '[:space:]' < "$RUNNER_TEMP/notes.md")" ]] || { echo "::error::empty changelog section"; exit 1; }
          cat >> "$RUNNER_TEMP/notes.md" <<EOF

          Signed with a Developer ID and notarized by Apple.

          \`\`\`sh
          brew install --cask productdevbook/tap/fil
          \`\`\`

          SHA-256 (fil-$VERSION-arm64.tar.gz): \`$SHA256\`
          EOF

      - name: Publish the GitHub release
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          NAME="fil-$VERSION-arm64"
          gh release create "$GITHUB_REF_NAME" "dist/$NAME.tar.gz" "dist/$NAME.tar.gz.sha256" \
            --title "fil $VERSION" --verify-tag --notes-file "$RUNNER_TEMP/notes.md"

  tap:
    needs: [test, build, publish]
    if: github.ref_type == 'tag'
    runs-on: xcode-27
    timeout-minutes: 20
    permissions: {}
    env:
      VERSION: ${{ needs.test.outputs.version }}
      SHA256: ${{ needs.build.outputs.sha256 }}
      HOMEBREW_NO_AUTO_UPDATE: "1"
      HOMEBREW_NO_INSTALL_FROM_API: "1"
      HOMEBREW_NO_ANALYTICS: "1"
    steps:
      - uses: actions/checkout@<sha> # v4.x.y
        with:
          persist-credentials: false

      - name: Tap
        env:
          TAP_DEPLOY_KEY: ${{ secrets.TAP_DEPLOY_KEY }}
        run: |
          printf '%s\n' "$TAP_DEPLOY_KEY" > "$RUNNER_TEMP/tap_key" && chmod 600 "$RUNNER_TEMP/tap_key"
          curl -fsSL https://api.github.com/meta | jq -r '.ssh_keys[] | "github.com " + .' > "$RUNNER_TEMP/known_hosts"
          echo "GIT_SSH_COMMAND=ssh -i $RUNNER_TEMP/tap_key -o IdentitiesOnly=yes -o UserKnownHostsFile=$RUNNER_TEMP/known_hosts -o StrictHostKeyChecking=yes" >> "$GITHUB_ENV"
          export GIT_SSH_COMMAND="ssh -i $RUNNER_TEMP/tap_key -o IdentitiesOnly=yes -o UserKnownHostsFile=$RUNNER_TEMP/known_hosts -o StrictHostKeyChecking=yes"
          brew tap productdevbook/tap git@github.com:productdevbook/homebrew-tap.git
          echo "TAP=$(brew --repository productdevbook/tap)" >> "$GITHUB_ENV"

      - name: Write the cask
        run: |
          sed -e "s/@VERSION@/$VERSION/" -e "s/@SHA256@/$SHA256/" packaging/homebrew/fil.rb.in > "$TAP/Casks/fil.rb"
          grep -qxF "  version \"$VERSION\"" "$TAP/Casks/fil.rb" || { echo "::error::version not written"; exit 1; }
          grep -qxF "  sha256 \"$SHA256\"" "$TAP/Casks/fil.rb" || { echo "::error::sha256 not written"; exit 1; }
          ! grep -q '@[A-Z0-9]*@' "$TAP/Casks/fil.rb" || { echo "::error::placeholder left in cask"; exit 1; }
          git -C "$TAP" diff --stat

      - name: Audit the cask
        run: brew audit --cask --strict --online productdevbook/tap/fil

      - name: Install smoke test
        run: |
          brew install --cask productdevbook/tap/fil
          [[ "$(fil --version)" == "fil $VERSION" ]]
          fil scan "$RUNNER_TEMP" --porcelain | grep -q '^mode=full '
          P=$(brew --prefix)
          test -f "$P/etc/bash_completion.d/fil"
          test -f "$P/share/zsh/site-functions/_fil"
          test -f "$P/share/fish/vendor_completions.d/fil.fish"
          test -f "$P/share/man/man1/fil.1"
          brew uninstall --cask fil

      - name: Push the cask
        run: |
          git -C "$TAP" -c user.name="github-actions[bot]" \
            -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
            commit -m "fil $VERSION" -- Casks/fil.rb
          git -C "$TAP" push origin HEAD:main

      - name: Remove the tap key
        if: always()
        run: rm -f "$RUNNER_TEMP/tap_key" "$RUNNER_TEMP/known_hosts"
```

Behaviour notes:

- **[Change]** (#22) Nothing is signed unless, on the tagged commit: the tag equals `v` + `main.swift` version,
  `CHANGELOG.md` has a section for it, the commit is on `main`, the format lint passes, `swift build -c release`
  and `swift test` pass and the completions match the CLI. Chosen over "check that CI succeeded for the SHA"
  because it does not depend on CI timing or on the CI run of a branch push.
- **[Change]** (#23) Top-level `permissions: {}`; only `publish` gets `contents: write`. `checkout` uses
  `persist-credentials: false` so no token is left in `.git/config` for later steps.
- **[Change]** (#24) The cask is rendered from a template in this repository instead of edited with `sed` on
  `version`/`sha256` lines; every replacement is checked with `grep -qxF`; `brew audit --cask --strict --online`
  and an install of the new cask (which also exercises Gatekeeper on a quarantined download for the first time)
  run before the push. If audit or install fail, the GitHub release already exists and the old cask stays
  live: re-run the `tap` job after fixing. Key and `known_hosts` live in `$RUNNER_TEMP` and are removed in an
  `if: always()` step; GitHub's SSH host keys come from `https://api.github.com/meta` with
  `StrictHostKeyChecking=yes` instead of trust-on-first-use (`accept-new`).
- **[Change]** (#24) `cert.p12` and `AuthKey.p8` are removed in the `if: always()` step too (today a failure in
  `scripts/release.sh` skips `rm "$FIL_NOTARY_KEY"`).
- **[Change]** (#28) Release notes come from the `CHANGELOG.md` section, not `--generate-notes`.
- `workflow_dispatch`: `test` and `build` run (an artifact `release` is uploaded for inspection); `publish` and
  `tap` are skipped.

## 13. Changes by issue

### 13.1 #22 Tests before release **[Change]**

Specified in section 12 (job `test`). Reason: a tag on a red commit is signed, notarized, published and pushed to
the cask today. Also **[New]** a manual release checklist in `CONTRIBUTING.md` under "Releasing (maintainer)":

1. Update `let version` in `Sources/fil/main.swift` and move `## [Unreleased]` entries in `CHANGELOG.md` to
   `## [X.Y.Z] - YYYY-MM-DD`.
2. Locally: `swift test`, `scripts/verify.sh`, `scripts/verify-clean.sh` (all must end with every check passed).
3. Commit `fil X.Y.Z` on `main`, push, wait for CI `build-and-test` to pass.
4. `git tag -a vX.Y.Z -m "fil X.Y.Z" && git push origin vX.Y.Z`.
5. After the workflow: `brew update && brew upgrade --cask fil && fil --version`.

### 13.2 #23 Pins, permissions, Dependabot **[Change]** / **[New]**

- Every `uses:` names a full 40-character commit SHA followed by the tag as a comment:
  `uses: actions/checkout@<sha> # v4.2.2`. Resolve a tag with
  `gh api repos/<owner>/<repo>/git/ref/tags/<tag> --jq '.object.type + " " + .object.sha'`; if the type is
  `tag` (annotated), dereference with `gh api repos/<owner>/<repo>/git/tags/<sha> --jq .object.sha`. Pin the
  latest release of each action at implementation time; never write a SHA from memory. Actions used:
  `actions/checkout`, `actions/upload-artifact`, `actions/download-artifact`, `contributor-assistant/github-action`.
- `ci.yml`: `permissions: contents: read` (section 3). `release.yml`: section 12. `cla.yml`: section 13.7.
- **[New]** `.github/dependabot.yml`:

```yaml
version: 2
updates:
  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: weekly
    groups:
      actions:
        patterns: ["*"]
  - package-ecosystem: swift
    directory: /
    schedule:
      interval: weekly
```

  Dependabot updates the SHA and the `# vX.Y.Z` comment together. A swift update changes `Package.swift`
  (`exact:`) and `Package.resolved`; CI must pass before merge.

### 13.3 #24 Cask verification and key cleanup **[Change]** / **[New]**

Specified in section 12 (job `tap`). **[New]** `packaging/homebrew/fil.rb.in`, the source of truth for the cask
(the tap's `Casks/fil.rb` becomes generated output; never edit it by hand):

```ruby
cask "fil" do
  version "@VERSION@"
  sha256 "@SHA256@"

  url "https://github.com/productdevbook/fil/releases/download/v#{version}/fil-#{version}-arm64.tar.gz"
  name "Fil"
  desc "Fast disk scanner and cleaner"
  homepage "https://github.com/productdevbook/fil"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: :golden_gate

  binary "fil"
  bash_completion "completions/fil"
  zsh_completion "completions/_fil"
  fish_completion "completions/fil.fish"
  manpage "man/fil.1"

  zap trash: "~/Library/Caches/com.vucod.Fil/snapshots"
end
```

The four new stanzas and the new tarball layout (section 11.5) ship in the same release, so the cask never points
at a tarball without those files.

### 13.4 #25 Script quoting **[Change]**

Section 11.5 (full text), the `verify*.sh` comment in section 4.2, and the comment fix in section 4.1.

### 13.5 #27 Completions and man page **[New]**

Decision: static files in the repository, not a `fil completion <shell>` command. Reason: no CLI code change,
the cask stanzas need files in the tarball anyway, and a check script keeps them in step with the help text.

- `completions/fil`: bash function `_fil` registered with `complete -F _fil fil`. Completes commands
  `scan doctor list clean help`; after `help`, the four command names; per command the options of its help
  text: `scan`: `-j --private --full --top --naive --porcelain --tolerant-hardlinks -q --quiet -v --verbose --no-color`
  and directories for `DIR`; `doctor`: `--no-open --no-color`; `list`: `--home --json --no-color`;
  `clean`: `--home --yes --no-color`; top level: `--help -h --version -V`. `--home` completes directories;
  `-j` and `--top` take a number (no completion). `clean` ids are not completed (they depend on the disk).
- `completions/_fil`: zsh `#compdef fil` with `_arguments` and per-command descriptions taken from
  `fil --help`, same option sets.
- `completions/fil.fish`: `complete -c fil ...` lines, same sets, with `-d` descriptions from the help text.
- `man/fil.1`: mdoc source. Sections: NAME (`fil - fast disk scanner and cleaner`), SYNOPSIS (one line per
  command), DESCRIPTION, COMMANDS (`scan`, `doctor`, `list`, `clean`, `help`, each with its options from the help
  text, hyphens written `\-`), ENVIRONMENT (`NO_COLOR`; `FIL_SNAPSHOT_DIR`: snapshot directory override),
  FILES (`~/Library/Caches/com.vucod.Fil/snapshots`), EXIT STATUS (0 success; 1 error, and for `doctor` "Full Disk
  Access missing"; 2 usage error, and for `clean` "an item could not be moved"), EXAMPLES (the README usage
  lines), SEE ALSO `du(1)`.
- `scripts/check-completions.sh` (bash, `set -uo pipefail`, no `-e`, counts failures like `verify*.sh`):
  builds if `.build/release/fil` is missing; for each command in `scan doctor list clean` collects every token
  matching `--[a-z][a-z-]*` and `-[a-zA-Z]` from `fil help <cmd>`; each must appear in `completions/fil`,
  `completions/_fil`, `completions/fil.fish`, and (as `\-\-name` / `\-x`, `grep -F`) in `man/fil.1`;
  each command name must appear in all four files; `mandoc -T lint -W warning man/fil.1` must be silent.
  Prints `PASS`/`FAIL <file>: missing <option>` lines and exits 1 on any failure.
- Tarball and cask: sections 11.5 and 13.3. README "Install" gains one line: the cask installs completions
  for bash, zsh and fish and the man page (`man fil`).

### 13.6 #28 Changelog, templates, formatter, branch protection **[New]**

- `CHANGELOG.md`, format "Keep a Changelog 1.1.0": title, one line about Semantic Versioning,
  `## [Unreleased]`, then `## [0.1.1] - 2026-10-18` and `## [0.1.0] - <tag date>` written from
  `git log v0.1.0..v0.1.1` and `git log v0.1.0`, subsections `Added`, `Changed`, `Fixed`, `Removed`. Header line
  format `## [X.Y.Z] - YYYY-MM-DD` exactly (the release workflow greps for it). Link references at the bottom
  (`[0.1.1]: https://github.com/productdevbook/fil/compare/v0.1.0...v0.1.1`).
- `.github/ISSUE_TEMPLATE/bug_report.yml` (issue form, label `bug`): required fields "fil --version", "macOS version
  (`sw_vers`)", "`fil doctor --no-open` output", "Command you ran", "What happened", "What you expected"; optional
  "`du -skx <dir>` output, if sizes are wrong". A markdown note at the top: security problems go to
  `https://github.com/productdevbook/fil/security/advisories/new`, not to an issue.
- `.github/ISSUE_TEMPLATE/feature_request.yml` (label `enhancement`): "Problem", "Proposed behaviour", "Alternatives".
- `.github/ISSUE_TEMPLATE/config.yml`: `blank_issues_enabled: false`; `contact_links`: "Report a vulnerability" ->
  the advisories URL.
- `.github/PULL_REQUEST_TEMPLATE.md`: "What and why"; checklist: `swift test` passes; `scripts/verify.sh` passes
  (engine changes); `scripts/verify-clean.sh` passes (cleanup changes); before/after benchmark and `du`
  comparison (engine changes); `CHANGELOG.md` `Unreleased` updated; CLA signed.
- `.github/CODEOWNERS`: `* @productdevbook`.
- `.swift-format` (JSON): `{"version": 1, "indentation": {"spaces": 4}, "lineLength": 120,
  "maximumBlankLines": 1, "respectsExistingLineBreaks": true}`; all other options default. Today 81 lines
  in `Sources/` and `Tests/` exceed 120 characters (longest 222). Introduce in two commits: (1) add the config
  and run `swift format format --in-place --recursive Package.swift Sources Tests`, nothing else in the commit;
  run `swift test`, `scripts/verify.sh`, `scripts/verify-clean.sh`; (2) add that commit's SHA to
  `.git-blame-ignore-revs` and the `Format` steps to `ci.yml` and `release.yml`. Because commit (1) touches engine
  files, it is reviewed like an engine change (CLAUDE.md), looking only for non-formatting differences.
- Topics and homepage (owner): `gh repo edit productdevbook/fil --add-topic macos,apple-silicon,disk-usage,disk-cleaner,cli,swift,apfs`.
  Homepage: only if a project site exists; none exists in this repository today.
- Branch protection (owner): a repository ruleset "main" targeting the default branch: block deletion; block
  force pushes; require status checks `build-and-test` and `cla` (`cla` applies to pull requests); require a
  pull request before merging; bypass list: role "Repository admin", mode "always". Reason for the bypass:
  CLAUDE.md's agent workflow commits directly to `main`; without the bypass those pushes are rejected.

### 13.7 #29 CLA workflow **[New]** / **[Change]**

Decision: a workflow in the repository (`contributor-assistant/github-action`), not the hosted CLA Assistant
app, so the check is visible and versioned. `.github/workflows/cla.yml`:

```yaml
name: CLA

on:
  issue_comment:
    types: [created]
  pull_request_target:
    types: [opened, synchronize, reopened, closed]

permissions:
  actions: write
  contents: write        # commits signatures to the cla-signatures branch
  pull-requests: write
  statuses: write

jobs:
  cla:
    if: >-
      github.event_name == 'pull_request_target' ||
      (github.event.issue.pull_request &&
       (github.event.comment.body == 'recheck' ||
        github.event.comment.body == 'I have read the CLA Document and I hereby sign the CLA'))
    runs-on: ubuntu-24.04
    steps:
      - uses: contributor-assistant/github-action@<sha> # v2.x.y
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        with:
          path-to-signatures: signatures/version1/cla.json
          path-to-document: https://github.com/productdevbook/fil/blob/main/CLA.md
          branch: cla-signatures
          allowlist: productdevbook,dependabot[bot],github-actions[bot]
```

Rule: this workflow never checks out or runs pull request code (`pull_request_target` runs with a write
token). Signatures live on branch `cla-signatures`, not on `main`, so the ruleset on `main` does not block them.

**[Change]** Wording, `CONTRIBUTING.md` "Contributor License Agreement": "The CLA check (`.github/workflows/cla.yml`)
comments on your first pull request. To sign, reply with exactly: `I have read the CLA Document and I hereby sign
the CLA`. Your signature is recorded on the `cla-signatures` branch and covers later contributions." `CLA.md`
section 6: replace "through the CLA Assistant bot on Your first pull request" with "by posting the sentence given by
the CLA check on Your first pull request".

### 13.8 #30 Agent settings and CLAUDE.md **[Change]**

- `.claude/settings.json` today lists 12 `permissions.deny` entries for MCP servers that belong to one machine's
  setup and have nothing to do with this project. Target content:

```json
{
  "permissions": {
    "allow": [
      "Bash(swift build:*)",
      "Bash(swift test:*)",
      "Bash(scripts/verify.sh)",
      "Bash(scripts/verify-clean.sh)",
      "Bash(scripts/check-completions.sh)",
      "Bash(.build/release/fil:*)",
      "Bash(du -skx:*)"
    ]
  }
}
```

  Personal entries move to each developer's `.claude/settings.local.json`. Add `.claude/settings.local.json` to
  `.gitignore` (it is not listed there today, although #30 says it is gitignored).
- The two agent files (`.claude/agents/macos-engineer.md`, `scan-tester.md`) carry the same personal server names
  in `disallowedTools`. Replace each `disallowedTools:` line with an allow list: `tools: Read, Write, Edit, Bash, Grep, Glob`.
  In `macos-engineer.md` the `description` becomes "Swift engineer for Fil's scan engine, libraries and `fil` CLI
  (Sources/: ScanCore on Darwin syscalls, getattrlistbulk, FSEvents; CleanCore; MapCore). Use for every change to
  Sources/ and Package.swift." (the current description does not match what this repository contains).
- `CLAUDE.md`: "`Sources/fil` (the `fil` CLI: `scan`, `list`, `clean`)" becomes
  "`Sources/fil` (the `fil` CLI: `scan`, `doctor`, `list`, `clean`)". Add one line under the Build bullet:
  "Release: `docs/design/07-build-and-release.md`; never run `scripts/release.sh` or push tags unless asked."

## 14. Steps only the repository owner can do

1. Create the ruleset on `main` (section 13.6).
2. Create the branch `cla-signatures` (`git push origin main:cla-signatures`) before merging `cla.yml`.
   Settings -> Actions -> General -> "Workflow permissions" can be set to "Read repository contents", because
   every workflow declares its own `permissions:`.
3. Enable Dependabot version updates (it reads `.github/dependabot.yml` once merged) and Dependabot alerts.
4. Set topics (and a homepage if one exists).
5. Keep the six secrets of section 8 valid (certificate and API key expiry); the deploy key on
   `productdevbook/homebrew-tap` must keep write access.
6. Hand-check the first release after these changes: `tar -tzf` the published tarball, `shasum -c` the
   published `.sha256`, `brew install --cask productdevbook/tap/fil`, `man fil`, tab completion in zsh.

## As built

- #23 (2026-10-18): actions pinned to the latest v4.x, not the newest majors (checkout v4.4.0, upload-artifact
  v4.6.2, download-artifact v4.3.0), to avoid untested major jumps; Dependabot proposes the majors.
- #24: `tap` taps `productdevbook/tap` with the deploy key, renders `packaging/homebrew/fil.rb.in` into it, audits
  and installs from the local tap, smoke-tests `fil --version` and `fil scan --porcelain`, then pushes. The
  template has no completion/man stanzas until #27/#45.

## Glossary additions

- **Developer ID**: Apple's certificate for signing software distributed outside the App Store; `fil` is signed
  with a "Developer ID Application" identity and the hardened runtime (`--options runtime`).
- **Notarization**: Apple's automated malware check of a signed binary (`xcrun notarytool submit`); the result is a
  ticket that Gatekeeper looks up.
- **Stapling**: attaching the notarization ticket to a file so Gatekeeper need not look it up online. Not possible
  for a bare Mach-O like `fil`; hence the wait until the ticket is visible online.
- **Gatekeeper wait**: the loop in `scripts/release.sh` that polls `codesign -v --check-notarization -R=notarized`
  up to 20 minutes before a release is published.
- **Tap / cask**: a Homebrew third-party repository (`productdevbook/homebrew-tap`, used as `productdevbook/tap`) and
  the Ruby file in it (`Casks/fil.rb`) that installs a prebuilt binary.
- **Cask template**: `packaging/homebrew/fil.rb.in`, rendered by the release workflow into the tap's `Casks/fil.rb`.
- **Runner image `xcode-27`**: the GitHub-hosted preview macOS image with the macOS 27 SDK used by both workflows.
- **SHA pin**: referencing a GitHub Action by full commit SHA instead of a movable tag.
- **CLA check**: the `cla` job of `.github/workflows/cla.yml` that blocks a pull request until its author has signed `CLA.md`.
- **Release gate**: the `test` job of the release workflow; nothing is signed or published unless it passes.
