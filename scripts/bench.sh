#!/usr/bin/env bash
# Scan benchmark for fil: full scan (3x, interleaved with du -skx) and incremental update after 1,000 changes
# (3 rounds), on a generated fixture of at least 1 M files. Budget: docs/design/01-scan-engine.md section 12.
# Usage: scripts/bench.sh [--files N] [--wide] [--keep] [--reuse DIR] [--fil PATH]
#   --files N    fixture size in files (default 1000000)
#   --wide       instead: one folder of 100,000 subfolders, 3 updates of 10,000 events each (budget: < 1 s each)
#   --keep       keep the bench directory (fixture, snapshots) on exit
#   --reuse DIR  use an earlier kept /private/tmp/fil-bench.* directory whose marker says it is complete
#   --fil PATH   fil binary (default .build/release/fil)
# Everything lives under /private/tmp/fil-bench.*; FIL_SNAPSHOT_DIR is inside it. Exit 0 = all checks passed.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
FIL="$ROOT/.build/release/fil"
FILES=1000000
KEEP=0
REUSE=""
PREFIX=/private/tmp/fil-bench.
FSEVENTS_WAIT=4
JOBS=8
FIXTURE_VERSION=2
WIDE=0
WIDE_CHILDREN=100000
WIDE_EVENTS=10000

while [[ $# -gt 0 ]]; do
  case "$1" in
    --files) FILES=${2:?--files needs a number}; shift 2 ;;
    --wide) WIDE=1; shift ;;
    --keep) KEEP=1; shift ;;
    --reuse) REUSE=${2:?--reuse needs a directory}; KEEP=1; shift 2 ;;
    --fil) FIL=${2:?--fil needs a path}; shift 2 ;;
    -h|--help) sed -n '2,11p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[[ $FILES =~ ^[0-9]+$ && $FILES -ge 20000 ]] || { echo "--files needs a number >= 20000" >&2; exit 2; }
[[ -x $FIL ]] || { echo "no fil binary at $FIL (swift build -c release)" >&2; exit 2; }

if [[ -n $REUSE ]]; then
  case "$REUSE" in "$PREFIX"*) BENCH=$REUSE ;; *) echo "--reuse must be under $PREFIX*" >&2; exit 2 ;; esac
else
  BENCH=$(mktemp -d "${PREFIX}XXXXXX")
fi
FIX="$BENCH/fixture"
LISTS="$BENCH/lists"
export FIL_SNAPSHOT_DIR="$BENCH/snap"
MARKER="$BENCH/complete"
mkdir -p "$FIX" "$LISTS" "$FIL_SNAPSHOT_DIR" "$BENCH/out"

cleanup() {
  if [[ $KEEP -eq 1 ]]; then echo "kept: $BENCH"; return 0; fi
  case "$BENCH" in "$PREFIX"*) rm -rf -- "$BENCH" ;; esac
}
trap cleanup EXIT
trap 'exit 130' INT TERM

FAILS=0
fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }

median() {
  sort -n | awk '{a[NR]=$1} END {if (NR==0) {print "nan"} else if (NR%2) {print a[(NR+1)/2]} else {printf "%.3f\n", (a[NR/2]+a[NR/2+1])/2}}'
}

# ---------------------------------------------------------------- fixture

build_fixture() {
  local n=$FILES
  local nclone=3000 nlink=2000 ndata=5000
  local extras=$((nclone + nlink * 2 + ndata + 4 + 5))
  local bulk=$((n - extras))
  local wide=$((bulk * 4 / 10)) deep=$((bulk * 3 / 10))
  local mid=$((bulk - wide - deep))
  rm -rf -- "$FIX" "$LISTS"
  mkdir -p "$FIX" "$LISTS"
  rm -f -- "$FIL_SNAPSHOT_DIR"/*.bin

  # Directory and file lists (deterministic: index arithmetic only). Wide: 2000 files per folder.
  # Deep: chains of 16 nested folders, 20 files at each level. Mid: three levels, 60 files per leaf.
  awk -v fix="$FIX" -v wide="$wide" -v deep="$deep" -v mid="$mid" -v dirs="$LISTS/dirs.txt" -v files="$LISTS/files.txt" '
    BEGIN {
      nw = int((wide + 1999) / 2000)
      for (i = 0; i < nw; i++) {
        d = sprintf("%s/wide/w%05d", fix, i); print d > dirs
        c = (i < nw - 1) ? 2000 : wide - 2000 * (nw - 1)
        for (j = 0; j < c; j++) print d "/f" j > files
      }
      nc = int((deep + 319) / 320); left = deep
      for (i = 0; i < nc && left > 0; i++) {
        p = sprintf("%s/deep/c%05d", fix, i)
        for (l = 0; l < 16 && left > 0; l++) {
          p = p "/d" l; print p > dirs
          for (j = 0; j < 20 && left > 0; j++) { print p "/f" j > files; left-- }
        }
      }
      left = mid; i = 0
      while (left > 0) {
        a = int(i / 40); b = i % 40
        d = sprintf("%s/mid/a%04d/b%02d", fix, a, b); print d > dirs
        for (j = 0; j < 60 && left > 0; j++) { print d "/f" j > files; left-- }
        i++
      }
    }'
  mkdir -p "$FIX/data" "$FIX/clones" "$FIX/links" "$FIX/big" "$FIX/tpl"
  # xargs runs mkdir/touch in big batches, four at a time; no process per file.
  xargs -n 4000 -P 4 mkdir -p < "$LISTS/dirs.txt"
  # Seven files in eight are empty (touch); every eighth holds 1, 2, 4 or 8 KB (printf is a shell builtin: no fork).
  awk 'NR % 8 != 0' "$LISTS/files.txt" | xargs -n 8000 -P 4 touch
  awk 'NR % 8 == 0' "$LISTS/files.txt" | xargs -n 2000 -P 4 sh -c \
    'i=0; for f; do i=$((i + 1)); case $((i % 4)) in 0) w=1024 ;; 1) w=2048 ;; 2) w=4096 ;; *) w=8192 ;; esac
      printf "%0${w}d" 0 > "$f"; done' _

  # Templates; data files are plain copies, clones are cp -c, links are hard links.
  local s
  for s in 1 4 16 64; do head -c $((s * 1024)) /dev/zero > "$FIX/tpl/t${s}k"; done
  head -c 262144 /dev/zero > "$FIX/tpl/clone256k"
  awk -v fix="$FIX" -v n="$ndata" 'BEGIN {
    split("1 4 16 64", sz, " ")
    for (i = 0; i < n; i++) printf "%s/tpl/t%sk %s/data/d%05d\n", fix, sz[i % 4 + 1], fix, i }' | xargs -n 2 -P 4 cp
  awk -v fix="$FIX" -v n="$nclone" 'BEGIN {
    for (i = 0; i < n; i++) printf "%s/tpl/clone256k %s/clones/c%05d\n", fix, fix, i }' | xargs -n 2 -P 4 cp -c
  awk -v fix="$FIX" -v n="$nlink" 'BEGIN {
    for (i = 0; i < n; i++) {
      printf "%s/data/d%05d %s/links/l%05da\n", fix, i, fix, i
      printf "%s/data/d%05d %s/links/l%05db\n", fix, i, fix, i
    } }' | xargs -n 2 -P 4 ln
  # Four large sparse files (2, 4, 8, 16 GB logical, almost nothing allocated).
  local g
  for g in 2 4 8 16; do
    dd if=/dev/zero of="$FIX/big/sparse${g}g" bs=1 count=1 seek=$((g * 1073741824 - 1)) 2> /dev/null
  done
  # Sets for the 3 update rounds (300 deletes, 300 modifications, 400 additions each), spread over the whole tree.
  local total
  total=$(wc -l < "$LISTS/files.txt" | tr -d ' ')
  awk -v step="$((total / 4000))" 'NR % step == 3' "$LISTS/files.txt" > "$LISTS/pick.txt"
  awk 'NR % 3 == 1 && ++c <= 900' "$LISTS/pick.txt" > "$LISTS/victims.txt"
  awk 'NR % 3 == 2 && ++c <= 900' "$LISTS/pick.txt" > "$LISTS/mods.txt"
  awk 'NR % 3 == 0 && ++c <= 1200' "$LISTS/pick.txt" | sed 's|/[^/]*$||' > "$LISTS/adddirs.txt"
  printf 'version=%s files=%s\n' "$FIXTURE_VERSION" "$FILES" > "$MARKER"
}

T0=$SECONDS
FIXTURE_NOTE=reused
if [[ $WIDE -eq 1 ]]; then
  : # the wide fixture is built below
elif [[ -f $MARKER && "$(cat "$MARKER")" == "version=$FIXTURE_VERSION files=$FILES" ]]; then
  echo "fixture: reusing $FIX"
else
  echo "fixture: building $FILES files under $FIX"
  rm -f -- "$MARKER"
  build_fixture
  FIXTURE_NOTE=built
fi
FIXTURE_SECS=$((SECONDS - T0))
[[ $WIDE -eq 1 ]] || echo "fixture: $FIXTURE_NOTE in ${FIXTURE_SECS}s, load: $(sysctl -n vm.loadavg)"

# ---------------------------------------------------------------- measuring

# timed CMD...: stdout of CMD to T_OUT, wall seconds to T_REAL, peak RSS bytes to T_RSS.
timed() {
  local tf="$BENCH/out/time.txt"
  T_OUT=$(/usr/bin/time -l -o "$tf" "$@" 2> /dev/null)
  T_REAL=$(awk '/ real / { print $1; exit }' "$tf")
  T_RSS=$(awk '/maximum resident set size/ { print $1; exit }' "$tf")
}

RE='^mode=(full|incremental) alloc=([0-9]+) logical=([0-9]+) files=([0-9]+) dirs=([0-9]+) cloneaware=([0-9]+) shared=([0-9]+)'
# parse OUTPUT: sets P_mode P_alloc P_logical P_files P_dirs.
parse() {
  [[ $1 =~ $RE ]] || { fail "unparsable porcelain: ${1:0:200}"; return 1; }
  P_mode=${BASH_REMATCH[1]} P_alloc=${BASH_REMATCH[2]} P_logical=${BASH_REMATCH[3]}
  P_files=${BASH_REMATCH[4]} P_dirs=${BASH_REMATCH[5]}
}

# ---------------------------------------------------------------- --wide: child lookup in a folder of 100,000

# One folder with WIDE_CHILDREN subfolders. Each round adds one file in WIDE_EVENTS of them (every tenth, shifted per
# round), so the update replays WIDE_EVENTS events whose paths all resolve through the wide folder (issue #17).
if [[ $WIDE -eq 1 ]]; then
  WFIX="$BENCH/wide/fixture"
  WMARKER="$BENCH/wide/complete"
  T0=$SECONDS
  if [[ -f $WMARKER && "$(cat "$WMARKER")" == "children=$WIDE_CHILDREN" ]]; then
    echo "wide fixture: reusing $WFIX"
  else
    echo "wide fixture: building $WIDE_CHILDREN subfolders under $WFIX/w"
    rm -rf -- "$BENCH/wide"
    mkdir -p "$WFIX/w"
    awk -v d="$WFIX/w" -v n="$WIDE_CHILDREN" 'BEGIN { for (i = 0; i < n; i++) printf "%s/c%06d\n", d, i }' |
      xargs -n 4000 -P 4 mkdir
    printf 'children=%s\n' "$WIDE_CHILDREN" > "$WMARKER"
  fi
  echo "wide fixture: ready in $((SECONDS - T0))s, load: $(sysctl -n vm.loadavg)"
  find "$WFIX/w" -name 'benchwide-*' -type f -delete
  echo "--- updates ($WIDE_EVENTS events in a folder of $WIDE_CHILDREN subfolders, 3 rounds, each compared with --full)"
  WIDE_T=()
  for r in 1 2 3; do
    "$FIL" scan "$WFIX" --full -j "$JOBS" --top 0 --porcelain > /dev/null
    sleep "$FSEVENTS_WAIT"
    awk -v d="$WFIX/w" -v n="$WIDE_EVENTS" -v step="$((WIDE_CHILDREN / WIDE_EVENTS))" -v r="$r" \
      'BEGIN { for (k = 0; k < n; k++) printf "%s/c%06d/benchwide-r%d\n", d, k * step + r - 1, r }' |
      xargs -n 4000 touch
    sleep "$FSEVENTS_WAIT"
    timed "$FIL" scan "$WFIX" -j "$JOBS" --top 0 --porcelain
    parse "$T_OUT" || continue
    inc_mode=$P_mode inc_alloc=$P_alloc inc_files=$P_files inc_dirs=$P_dirs inc_logical=$P_logical
    full_out=$("$FIL" scan "$WFIX" --full -j "$JOBS" --top 0 --porcelain)
    parse "$full_out" || continue
    du_kb=$(du -skx "$WFIX" | awk '{ print $1 }')
    verdict=ok
    if [[ $inc_mode != incremental ]]; then
      verdict=FELL-BACK
      fail "wide update $r ran as $inc_mode, not incremental"
    fi
    if [[ $inc_alloc -ne $P_alloc || $inc_files -ne $P_files || $inc_dirs -ne $P_dirs || $inc_logical -ne $P_logical ]]; then
      verdict=DIFFERS
      fail "wide update $r: incremental alloc/logical/files/dirs $inc_alloc/$inc_logical/$inc_files/$inc_dirs, full $P_alloc/$P_logical/$P_files/$P_dirs"
    fi
    if [[ $inc_alloc -ne $((du_kb * 1024)) ]]; then
      verdict=MISMATCH
      fail "wide update $r: alloc $inc_alloc != du*1024 $((du_kb * 1024))"
    fi
    WIDE_T+=("$T_REAL")
    echo "update $r: ${T_REAL}s mode=$inc_mode files=$inc_files dirs=$inc_dirs (full: $P_files, $P_dirs) $verdict"
  done
  [[ ${#WIDE_T[@]} -gt 0 ]] || { echo "RESULT: no measurements"; exit 1; }
  wide_med=$(printf '%s\n' "${WIDE_T[@]}" | median)
  echo
  echo "=== medians"
  echo "machine:           $(sysctl -n hw.model), $(sysctl -n hw.ncpu) cpu, $(($(sysctl -n hw.memsize) / 1073741824)) GB, macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
  echo "load average:      $(sysctl -n vm.loadavg)"
  echo "wide update:       ${wide_med} s ($WIDE_EVENTS events, $WIDE_CHILDREN subfolders; budget < 1 s)"
  if awk -v t="$wide_med" 'BEGIN { exit !(t >= 1) }'; then fail "wide update median ${wide_med}s is not under 1 s"; fi
  if [[ $FAILS -gt 0 ]]; then echo "RESULT: $FAILS check(s) FAILED"; exit 1; fi
  echo "RESULT: all checks passed"
  exit 0
fi

# Pre-clean for a kept fixture: put back files an earlier run deleted, drop its additions.
xargs -n 500 touch < "$LISTS/victims.txt"
find "$FIX" -name 'benchadd-*' -type f -delete

# ---------------------------------------------------------------- full scans, interleaved with du

echo "--- full scans (fil scan --full -j $JOBS --top 0 --porcelain, 3x, interleaved with du -skx)"
FULL_T=() FULL_RSS=()
BASE_FILES=0
for i in 1 2 3; do
  du_kb=$(du -skx "$FIX" | awk '{ print $1 }')
  timed "$FIL" scan "$FIX" --full -j "$JOBS" --top 0 --porcelain
  parse "$T_OUT" || continue
  FULL_T+=("$T_REAL"); FULL_RSS+=("$T_RSS"); BASE_FILES=$P_files
  verdict=ok
  if [[ $P_alloc -ne $((du_kb * 1024)) ]]; then
    verdict=MISMATCH
    fail "full run $i: alloc $P_alloc != du*1024 $((du_kb * 1024))"
  fi
  echo "run $i: ${T_REAL}s files=$P_files dirs=$P_dirs alloc=$P_alloc du=$((du_kb * 1024)) rss=$((T_RSS / 1048576))MB $verdict"
done

# ---------------------------------------------------------------- incremental updates

# Round R: 300 deletes, 300 modifications (4 KB appended) and 400 additions, spread over the tree.
apply_changes() {
  local r=$1 lo=$(((r - 1) * 300 + 1)) hi=$((r * 300))
  sed -n "${lo},${hi}p" "$LISTS/victims.txt" | xargs -n 500 rm -f
  sed -n "${lo},${hi}p" "$LISTS/mods.txt" |
    xargs -n 100 sh -c 'for f; do head -c 4096 /dev/zero >> "$f"; done' _
  sed -n "$(((r - 1) * 400 + 1)),$((r * 400))p" "$LISTS/adddirs.txt" |
    awk -v r="$r" '{ printf "%s/benchadd-r%s-%d\n", $0, r, NR }' | xargs -n 500 touch
}

echo "--- incremental updates (3 rounds x 1,000 changes, each compared with --full)"
INC_T=()
for r in 1 2 3; do
  # Start every round from a fresh snapshot of the current tree.
  "$FIL" scan "$FIX" --full -j "$JOBS" --top 0 --porcelain > /dev/null
  sleep "$FSEVENTS_WAIT"
  apply_changes "$r"
  sleep "$FSEVENTS_WAIT"
  timed "$FIL" scan "$FIX" -j "$JOBS" --top 0 --porcelain
  parse "$T_OUT" || continue
  inc_mode=$P_mode inc_alloc=$P_alloc inc_files=$P_files inc_dirs=$P_dirs inc_logical=$P_logical
  # --full replaces the snapshot, so it runs after the incremental one.
  full_out=$("$FIL" scan "$FIX" --full -j "$JOBS" --top 0 --porcelain)
  parse "$full_out" || continue
  verdict=ok
  if [[ $inc_mode != incremental ]]; then
    verdict=FELL-BACK
    fail "update $r ran as $inc_mode, not incremental"
  fi
  if [[ $inc_alloc -ne $P_alloc || $inc_files -ne $P_files || $inc_dirs -ne $P_dirs || $inc_logical -ne $P_logical ]]; then
    verdict=DIFFERS
    fail "update $r: incremental alloc/logical/files/dirs $inc_alloc/$inc_logical/$inc_files/$inc_dirs, full $P_alloc/$P_logical/$P_files/$P_dirs"
  fi
  INC_T+=("$T_REAL")
  echo "update $r: ${T_REAL}s mode=$inc_mode files=$inc_files (full: $P_files) $verdict"
done

# ---------------------------------------------------------------- report

if [[ ${#FULL_T[@]} -eq 0 || ${#INC_T[@]} -eq 0 ]]; then echo "RESULT: no measurements"; exit 1; fi
full_med=$(printf '%s\n' "${FULL_T[@]}" | median)
inc_med=$(printf '%s\n' "${INC_T[@]}" | median)
rss_med=$(printf '%s\n' "${FULL_RSS[@]}" | median)
fps=$(awk -v f="$BASE_FILES" -v t="$full_med" 'BEGIN { printf "%d", f / t }')
snap_bytes=$(cat "$FIL_SNAPSHOT_DIR"/*.bin | wc -c | tr -d ' ')
echo
echo "=== medians"
echo "machine:           $(sysctl -n hw.model), $(sysctl -n hw.ncpu) cpu, $(($(sysctl -n hw.memsize) / 1073741824)) GB, macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
echo "load average:      $(sysctl -n vm.loadavg)"
echo "files in fixture:  $BASE_FILES"
echo "full scan:         ${full_med} s"
echo "files per second:  $fps"
echo "incremental:       ${inc_med} s"
echo "peak RSS:          $((${rss_med%.*} / 1048576)) MB"
echo "snapshot size:     $((snap_bytes / 1048576)) MB ($snap_bytes bytes)"
echo "fixture build:     ${FIXTURE_SECS} s ($FIXTURE_NOTE)"
if [[ $FAILS -gt 0 ]]; then echo "RESULT: $FAILS check(s) FAILED"; exit 1; fi
echo "RESULT: all checks passed"
