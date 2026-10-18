#!/usr/bin/env bash
# Scan-engine checks for fil scan: incremental (FSEvents) vs full scan vs du -skx.
# Every fixture is a fresh mktemp dir under /private/tmp, removed before exit.
# Usage: scripts/verify.sh   (exit 0 = all scenarios PASS)
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd) || exit 1
FIL="$ROOT/.build/release/fil"
FSEVENTS_WAIT=3
FIXTURE_PREFIX=/private/tmp/fil-verify.
SNAP_PREFIX=/private/tmp/fil-verify-snap.

CUR_DIR=""
SNAP_DIR=""
FAILS=0
TOTAL=0
DIFFS=""
PASS_TEXT=""

cleanup() {
  case "$CUR_DIR" in
    "$FIXTURE_PREFIX"*) [[ -d "$CUR_DIR" ]] && rm -rf -- "$CUR_DIR" ;;
  esac
  case "$SNAP_DIR" in
    "$SNAP_PREFIX"*) [[ -d "$SNAP_DIR" ]] && rm -rf -- "$SNAP_DIR" ;;
  esac
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# ---------------------------------------------------------------- helpers

one_line() { printf '%s' "${1:0:200}" | tr '\n' ' '; }

# mk PATH BYTES: create a file of BYTES zero bytes, making parent dirs.
mk() { mkdir -p "$(dirname "$1")" && head -c "$2" /dev/zero > "$1"; }

# run_scan DIR [EXTRA]: sets R_OUT (stdout+stderr) and R_RC.
run_scan() {
  R_OUT=$("$FIL" scan "$1" --porcelain ${2:+"$2"} 2>&1)
  R_RC=$?
}
run_ok() { [[ $R_RC -eq 0 ]]; }

# parse_porcelain OUTPUT: sets P_mode P_alloc P_logical P_files P_dirs.
# Returns 1 unless OUTPUT is exactly one line in the porcelain format.
parse_porcelain() {
  local re='^mode=(full|incremental) alloc=([0-9]+) logical=([0-9]+) files=([0-9]+) dirs=([0-9]+)$'
  [[ $1 =~ $re ]] || return 1
  P_mode=${BASH_REMATCH[1]}
  P_alloc=${BASH_REMATCH[2]}
  P_logical=${BASH_REMATCH[3]}
  P_files=${BASH_REMATCH[4]}
  P_dirs=${BASH_REMATCH[5]}
}

add_diff() { DIFFS="${DIFFS:+$DIFFS; }$*"; }

# end_scenario NAME: removes the fixture, prints PASS/FAIL, counts failures.
end_scenario() {
  if [[ -n "$CUR_DIR" ]]; then
    case "$CUR_DIR" in "$FIXTURE_PREFIX"*) rm -rf -- "$CUR_DIR" ;; esac
    CUR_DIR=""
  fi
  if [[ -z "$DIFFS" ]]; then
    echo "PASS $1  $PASS_TEXT"
  else
    echo "FAIL $1: $DIFFS"
    FAILS=$((FAILS + 1))
  fi
}

# probe: checks that fil scan accepts --porcelain before any scenario runs.
probe() {
  local d
  d=$(mktemp -d "${FIXTURE_PREFIX}XXXXXX") || exit 1
  CUR_DIR=$d
  : > "$d/probe"
  run_scan "$d"
  if ! run_ok || ! parse_porcelain "$R_OUT"; then
    echo "waiting for --porcelain (fil rc=$R_RC: $(one_line "$R_OUT"))"
    exit 2
  fi
  rm -rf -- "$d"
  CUR_DIR=""
}

# run_scenario NAME EXPECT SETUP CHANGE [WAIT]
# EXPECT=incremental: the post-change run must be mode=incremental.
# EXPECT=any: full fallback is accepted; the numbers must still match.
# WAIT: seconds to sleep after CHANGE before the incremental run (default FSEVENTS_WAIT).
run_scenario() {
  local name=$1 expect=$2 setup=$3 change=$4 wait=${5:-$FSEVENTS_WAIT}
  local d du_b inc_mode inc_alloc inc_logical inc_files inc_dirs
  local full_alloc full_logical full_files full_dirs
  TOTAL=$((TOTAL + 1))
  DIFFS=""
  PASS_TEXT=""

  d=$(mktemp -d "${FIXTURE_PREFIX}XXXXXX") || { DIFFS="mktemp failed"; end_scenario "$name"; return; }
  CUR_DIR=$d

  "$setup" "$d"
  run_scan "$d"
  if ! run_ok || ! parse_porcelain "$R_OUT"; then
    DIFFS="baseline run invalid (rc=$R_RC): $(one_line "$R_OUT")"
    end_scenario "$name"; return
  fi
  if [[ $P_mode != full ]]; then
    DIFFS="baseline mode=$P_mode (want full)"
    end_scenario "$name"; return
  fi

  "$change" "$d"
  sleep "$wait"

  run_scan "$d"
  if ! run_ok || ! parse_porcelain "$R_OUT"; then
    DIFFS="incremental run invalid (rc=$R_RC): $(one_line "$R_OUT")"
    end_scenario "$name"; return
  fi
  inc_mode=$P_mode; inc_alloc=$P_alloc; inc_logical=$P_logical
  inc_files=$P_files; inc_dirs=$P_dirs

  run_scan "$d" --full
  if ! run_ok || ! parse_porcelain "$R_OUT" || [[ $P_mode != full ]]; then
    DIFFS="full run invalid (rc=$R_RC): $(one_line "$R_OUT")"
    end_scenario "$name"; return
  fi
  full_alloc=$P_alloc; full_logical=$P_logical
  full_files=$P_files; full_dirs=$P_dirs

  du_b=$(( $(du -skx "$d" | awk '{print $1}') * 1024 ))

  if [[ $expect == incremental && $inc_mode != incremental ]]; then
    add_diff "mode=$inc_mode (want incremental)"
  fi
  [[ $inc_alloc == "$full_alloc" ]]     || add_diff "alloc inc=$inc_alloc full=$full_alloc"
  [[ $inc_logical == "$full_logical" ]] || add_diff "logical inc=$inc_logical full=$full_logical"
  [[ $inc_files == "$full_files" ]]     || add_diff "files inc=$inc_files full=$full_files"
  [[ $inc_dirs == "$full_dirs" ]]       || add_diff "dirs inc=$inc_dirs full=$full_dirs"
  [[ $full_alloc == "$du_b" ]]          || add_diff "alloc full=$full_alloc du=$du_b"

  if [[ $inc_mode == incremental ]]; then PASS_TEXT="(incremental)"; else PASS_TEXT="(full fallback)"; fi
  PASS_TEXT="$PASS_TEXT alloc=$full_alloc logical=$full_logical files=$full_files dirs=$full_dirs"
  end_scenario "$name"
}

# ---------------------------------------------------------------- fixtures

setup_add()        { mk "$1/base/a.bin" 5000; mk "$1/base/b.bin" 100; }
change_add()       { mk "$1/base/c.bin" 70000; mk "$1/new/d.bin" 1; mk "$1/new/e.bin" 4096; }

setup_delete_tree() {
  local i
  for i in 1 2 3 4 5; do mk "$1/tree/sub$i/f" 9000; done
  mk "$1/tree/top" 2000
  mk "$1/keep/k" 3000
}
change_delete_tree() { rm -rf -- "$1/tree"; }

setup_nested()     { mk "$1/root/x" 1000; }
change_nested() {
  mk "$1/root/p/q/r/deep.bin" 12345
  mk "$1/root/p/q/side" 7
  mk "$1/root/p/q/r/s/t/u/v" 1
  mkdir -p "$1/root/empty/inner"
}

setup_grow()       { mk "$1/g/file" 1000; mk "$1/g/other" 500; }
change_grow()      { head -c 1048576 /dev/zero >> "$1/g/file"; }

setup_rename_dir() { mk "$1/old/a" 5000; mk "$1/old/sub/b" 3000; }
change_rename_dir(){ mv "$1/old" "$1/renamed"; }

setup_move()       { mk "$1/src/m" 20000; mk "$1/dst/x" 10; }
change_move()      { mv "$1/src/m" "$1/dst/m"; }

setup_many() {
  local i
  mkdir -p "$1/many"
  for i in $(seq 1 1000); do head -c $(( (i * 37) % 9000 + 1 )) /dev/zero > "$1/many/f$i"; done
}
change_many()      { rm -- "$1/many/f500"; }

setup_hl_new_link() { mk "$1/orig/file" 40000; mkdir -p "$1/other"; }
change_hl_new_link(){ ln "$1/orig/file" "$1/other/link"; }

setup_hl_del_owner(){ mk "$1/own/file" 40000; mkdir -p "$1/peer"; ln "$1/own/file" "$1/peer/alias"; }
change_hl_del_owner(){ rm -- "$1/own/file"; }
change_hl_del_peer(){ rm -- "$1/peer/alias"; }

setup_rapid() {
  mk "$1/a/keep" 100
  mk "$1/b/gone" 200
  mk "$1/d/grow" 1000
}
change_rapid() {
  mk "$1/a/added" 300
  rm -- "$1/b/gone"
  mk "$1/c/new/file" 5000
  head -c 1048576 /dev/zero >> "$1/d/grow"
}

setup_hl_grow()    { mk "$1/own/file" 40000; mkdir -p "$1/peer"; ln "$1/own/file" "$1/peer/alias"; }
change_hl_grow_a() { head -c 1048576 /dev/zero >> "$1/own/file"; }
change_hl_grow_b() { head -c 1048576 /dev/zero >> "$1/peer/alias"; }

setup_hl_new_dir() { mk "$1/base/x" 100; }
change_hl_new_dir(){
  mkdir -p "$1/fresh"
  mk "$1/fresh/h1" 50000
  ln "$1/fresh/h1" "$1/fresh/h2"
}

# ---------------------------------------------------------------- main

# Snapshots go to a private temp dir, never to ~/Library/Caches/Fil.
SNAP_DIR=$(mktemp -d "${SNAP_PREFIX}XXXXXX") || exit 1
export FIL_SNAPSHOT_DIR="$SNAP_DIR"

echo "Building: swift build -c release"
if ! (cd "$ROOT" && swift build -c release 2>&1 | tail -n 15); then
  echo "FAIL build"
  exit 1
fi
if [[ ! -x $FIL ]]; then
  echo "FAIL $FIL missing after build"
  exit 1
fi

probe

run_scenario "add files"                    incremental setup_add change_add
run_scenario "delete dir tree"              incremental setup_delete_tree change_delete_tree
run_scenario "new nested dirs with files"   incremental setup_nested change_nested
run_scenario "grow existing file"           incremental setup_grow change_grow
run_scenario "rename dir"                   incremental setup_rename_dir change_rename_dir
run_scenario "move file between dirs"       incremental setup_move change_move
run_scenario "delete 1 of 1000 files"       incremental setup_many change_many
run_scenario "hardlink: new link, old file" any         setup_hl_new_link change_hl_new_link
run_scenario "hardlink: delete owner link"  incremental setup_hl_del_owner change_hl_del_owner
run_scenario "hardlink: delete peer link"   incremental setup_hl_del_owner change_hl_del_peer
run_scenario "hardlink: new file, 2 links"  incremental setup_hl_new_dir change_hl_new_dir
run_scenario "no wait: rapid changes"       incremental setup_rapid change_rapid 0
run_scenario "hardlink: grow via link A"    incremental setup_hl_grow change_hl_grow_a
run_scenario "hardlink: grow via link B"    incremental setup_hl_grow change_hl_grow_b

echo
echo "$((TOTAL - FAILS))/$TOTAL scenarios passed"
(( FAILS == 0 )) || exit 1
