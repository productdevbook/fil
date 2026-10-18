#!/usr/bin/env bash
# CLI checks for fil: candidate list vs du, dry run, careful protection, Trash moves, bad ids.
# Every fixture is a fresh mktemp dir under /private/tmp; every fil call gets --home FIXTURE.
# Clean --yes really moves items to ~/.Trash; the script removes only the exact Trash path
# that fil reported for a fixture item, after checking it lies under ~/.Trash.
# Usage: scripts/verify-clean.sh   (exit 0 = all checks PASS)
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd) || exit 1
FIL="$ROOT/.build/release/fil"
FIXTURE_PREFIX=/private/tmp/fil-verify.
OUTSIDE_PREFIX=/private/tmp/fil-verify-outside.
SNAP_PREFIX=/private/tmp/fil-verify-snap.
TRASH="$HOME/.Trash"
DERIVED_ID="xcode-derived:Library/Developer/Xcode/DerivedData/a"
ARCHIVE_ID="xcode-archives:Library/Developer/Xcode/Archives/x.xcarchive"

F=""
OUTSIDE=""
SNAP_DIR=""
TRASH_ITEMS=()
PASSES=0
FAILS=0

# Guarded-prefix removal: only paths created by this script are ever deleted.
cleanup() {
  local p
  for p in ${TRASH_ITEMS[@]+"${TRASH_ITEMS[@]}"}; do
    case "$p" in "$TRASH"/?*) [[ -e $p ]] && rm -rf -- "$p" ;; esac
  done
  case "$F" in "$FIXTURE_PREFIX"*) [[ -d $F ]] && rm -rf -- "$F" ;; esac
  case "$OUTSIDE" in "$OUTSIDE_PREFIX"*) [[ -d $OUTSIDE ]] && rm -rf -- "$OUTSIDE" ;; esac
  case "$SNAP_DIR" in "$SNAP_PREFIX"*) [[ -d $SNAP_DIR ]] && rm -rf -- "$SNAP_DIR" ;; esac
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# ---------------------------------------------------------------- helpers

one_line() { printf '%s' "${1:0:300}" | tr '\n' ' '; }

pass() { echo "PASS $1"; PASSES=$((PASSES + 1)); }
fail() { echo "FAIL $1${2:+: $2}"; FAILS=$((FAILS + 1)); }

# check NAME RC DETAIL: RC 0 means PASS.
check() { if [[ $2 -eq 0 ]]; then pass "$1"; else fail "$1" "$3"; fi; }

# relay: reads "PASS<TAB>name<TAB>" / "FAIL<TAB>name<TAB>detail" lines from stdin.
relay() {
  local status name detail
  while IFS=$'\t' read -r status name detail; do
    if [[ $status == PASS ]]; then pass "$name"; else fail "$name" "$detail"; fi
  done
}

# mk PATH BYTES: a file of BYTES zero bytes, parent dirs created.
mk() { mkdir -p "$(dirname "$1")" && head -c "$2" /dev/zero > "$1"; }

# snapshot DIR: name, size and mtime of every entry (no symlink following).
snapshot() { find "$1" -exec stat -f '%N %z %m' {} + 2>/dev/null | LC_ALL=C sort; }

# ids_of: candidate ids from `fil list --json` on stdin.
ids_of() {
  python3 -I -c 'import json, sys
for c in json.load(sys.stdin).get("candidates", []):
    print(c["id"])'
}

# trash_path_from OUTPUT: first token of OUTPUT that starts with ~/.Trash/.
trash_path_from() {
  awk -v p="$TRASH/" '{ for (i = 1; i <= NF; i++) if (index($i, p) == 1) { print $i; exit } }' <<<"$1"
}

# trash_check NAME PATH: PATH must be an existing item under ~/.Trash; remove exactly that path.
trash_check() {
  local name=$1 p=$2
  if [[ -n $p && $p == "$TRASH"/?* && -e $p ]]; then
    pass "$name: exists under ~/.Trash"
    TRASH_ITEMS+=("$p")
    rm -rf -- "$p"
    [[ ! -e $p ]]; check "$name: removed exactly that Trash path" $? "still present: $p"
  else
    fail "$name: exists under ~/.Trash" "path=${p:-<none>}"
  fi
}

# ---------------------------------------------------------------- checks 1 (list) in python

read -r -d '' CHECK1_PY <<'PY'
import json, subprocess, sys

EXPECT = {
    "xcode-derived:Library/Developer/Xcode/DerivedData/a": ("xcode-derived", "safe", "trash"),
    "xcode-archives:Library/Developer/Xcode/Archives/x.xcarchive": ("xcode-archives", "careful", "trash"),
    "app-caches:Library/Caches/com.example.app": ("app-caches", "safe", "trash"),
    "app-caches:Library/Caches/com.apple.bird": ("app-caches", "review", "trash"),
    "homebrew-cache:Library/Caches/Homebrew": ("homebrew-cache", "safe", "trash"),
    "logs:Library/Logs/foo": ("logs", "safe", "trash"),
    "project-artifacts:proj/node_modules": ("project-artifacts", "review", "trash"),
    "project-artifacts:rust/target": ("project-artifacts", "review", "trash"),
}

def rep(name, problems):
    if problems:
        print("FAIL\t%s\t%s" % (name, "; ".join(problems)))
    else:
        print("PASS\t%s\t" % name)

try:
    cands = json.load(sys.stdin)["candidates"]
except Exception as e:
    rep("1 list --json parses", [str(e)])
    sys.exit(0)
rep("1 list --json parses", [])

by_id = {c["id"]: c for c in cands}
got, want = set(by_id), set(EXPECT)
rep("1 candidate set matches the expected 8 (no tiny, link or nested)",
    [] if got == want else ["missing=%s extra=%s" % (sorted(want - got), sorted(got - want))])

probs = []
for cid, (rule, safety, removal) in sorted(EXPECT.items()):
    c = by_id.get(cid)
    if c is None:
        continue
    have = (c.get("rule"), c.get("safety"), c.get("removal"))
    if have != (rule, safety, removal):
        probs.append("%s: got %s want %s" % (cid, have, (rule, safety, removal)))
rep("1 rule, safety and removal per candidate", probs)

bird = by_id.get("app-caches:Library/Caches/com.apple.bird") or {}
rep("1 com.apple.bird note mentions macOS",
    [] if "macOS" in (bird.get("note") or "") else ["note=%r" % bird.get("note")])

bad = [cid for cid, c in by_id.items()
       if "Caches/tiny" in cid or "Caches/link" in cid or c["path"].count("node_modules") > 1]
rep("1 tiny, link and nested node_modules absent", ["present: %s" % bad] if bad else [])

probs = []
for cid, c in sorted(by_id.items()):
    r = subprocess.run(["du", "-sk", c["path"]], capture_output=True, text=True)
    fields = r.stdout.split()
    if r.returncode != 0 or not fields:
        probs.append("%s: du failed: %s" % (cid, r.stderr.strip()))
        continue
    want_b = int(fields[0]) * 1024
    if c.get("bytes") != want_b:
        probs.append("%s: bytes=%s du*1024=%s" % (cid, c.get("bytes"), want_b))
rep("1 bytes equal du -sk x 1024 for each candidate", probs)
PY

# ---------------------------------------------------------------- main

SNAP_DIR=$(mktemp -d "${SNAP_PREFIX}XXXXXX") || exit 1
export FIL_SNAPSHOT_DIR="$SNAP_DIR"

echo "Building: swift build -c release"
built=0
for attempt in 1 2 3; do
  if (cd "$ROOT" && swift build -c release >"$SNAP_DIR/build.log" 2>&1); then
    built=1
    break
  fi
  echo "build attempt $attempt failed (locked or error), retrying"
  sleep 10
done
if [[ $built -ne 1 ]]; then
  tail -n 15 "$SNAP_DIR/build.log"
  echo "FAIL build"
  exit 1
fi
if [[ ! -x $FIL ]]; then
  echo "FAIL $FIL missing after build"
  exit 1
fi

F=$(mktemp -d "${FIXTURE_PREFIX}XXXXXX") || exit 1
OUTSIDE=$(mktemp -d "${OUTSIDE_PREFIX}XXXXXX") || exit 1
mk "$F/Library/Developer/Xcode/DerivedData/a/f" 5000000
mk "$F/Library/Developer/Xcode/Archives/x.xcarchive/f" 2000000
mk "$F/Library/Caches/com.example.app/f" 3000000
mk "$F/Library/Caches/com.apple.bird/f" 2000000
mk "$F/Library/Caches/Homebrew/f" 2000000
mk "$F/Library/Logs/foo/f" 2000000
mk "$F/proj/package.json" 20
mk "$F/proj/node_modules/f" 4000000
mk "$F/proj/node_modules/pkg/node_modules/inner/f" 1000
mk "$F/rust/Cargo.toml" 20
mk "$F/rust/target/f" 2000000
mk "$F/Library/Caches/tiny/f" 500000
mk "$OUTSIDE/f" 3000000
ln -s "$OUTSIDE" "$F/Library/Caches/link"

# Check 1: list --json against the expected candidates and du.
LIST=$("$FIL" list --home "$F" --json 2>/dev/null)
list_rc=$?
out=$(printf '%s' "$LIST" | python3 -I -c "$CHECK1_PY")
relay <<<"$out"
check "1 list exits 0" $list_rc "rc=$list_rc"

# Check 2: a dry run changes nothing on disk.
before=$(snapshot "$F")
"$FIL" clean xcode-archives --home "$F" >/dev/null 2>&1
after=$(snapshot "$F")
[[ $before == "$after" ]]
check "2 dry run (no --yes) changes nothing on disk" $? "file list, sizes or mtimes changed"

# Check 3: careful archive is not removed when cleaned by rule id.
"$FIL" clean xcode-archives --home "$F" --yes >/dev/null 2>&1
[[ -e $F/Library/Developer/Xcode/Archives/x.xcarchive ]]
check "3 careful archive kept when cleaned by rule id" $? "x.xcarchive was removed"

# Check 4: real clean of xcode-derived moves DerivedData/a to the Trash.
out4=$("$FIL" clean xcode-derived --home "$F" --yes 2>&1)
rc4=$?
dp=$(trash_path_from "$out4")
[[ $rc4 -eq 0 && -n $dp ]]
check "4 xcode-derived cleaned: exit 0 and output names a ~/.Trash path" $? "rc=$rc4 out=$(one_line "$out4")"
trash_check "4 DerivedData/a" "$dp"
ids4=$("$FIL" list --home "$F" --json 2>/dev/null | ids_of)
! grep -Fxq "$DERIVED_ID" <<<"$ids4" && [[ ! -e $F/Library/Developer/Xcode/DerivedData/a ]]
check "4 next list no longer shows $DERIVED_ID" $? "still listed or still on disk"

# Check 5: careful archive cleaned by its candidate id moves to the Trash.
out5=$("$FIL" clean "$ARCHIVE_ID" --home "$F" --yes 2>&1)
rc5=$?
ap=$(trash_path_from "$out5")
[[ $rc5 -eq 0 && -n $ap ]]
check "5 careful archive cleaned by candidate id: exit 0 and output names a ~/.Trash path" $? "rc=$rc5 out=$(one_line "$out5")"
trash_check "5 x.xcarchive" "$ap"
[[ ! -e $F/Library/Developer/Xcode/Archives/x.xcarchive ]]
check "5 archive gone from the fixture" $? "x.xcarchive still in fixture"

# Check 6: a nonexistent id makes clean exit non-zero.
"$FIL" clean "no-such-rule:Library/Nothing" --home "$F" >/dev/null 2>&1
rc6=$?
[[ $rc6 -ne 0 ]]
check "6 nonexistent id makes clean exit non-zero" $? "rc=$rc6"

echo
echo "$PASSES/$((PASSES + FAILS)) checks passed"
(( FAILS == 0 )) || exit 1
