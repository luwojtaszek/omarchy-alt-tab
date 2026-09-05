#!/bin/bash
# End-to-end tests for apply-binds.sh: a fake hyprctl and logger on PATH, a
# scratch HOME, and assertions on exactly which hyprctl calls come out.
#
#   bash tests/apply-binds.test.sh
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
script="$here/../apply-binds.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/home/.config/omarchy"

export HOME="$work/home"
export PATH="$work/bin:$PATH"
export FAKE_LOG="$work/hyprctl.log" FAKE_JOURNAL="$work/journal.log"
export FAKE_STATUS="$work/status.json" FAKE_BINDS="$work/binds.json"
export FAKE_BINDS_DELAY=0

settings="$HOME/.config/omarchy/alt-tab.json"
summon="omarchy-shell shell summon io.github.luwojtaszek.alt-tab"

# hyprctl: one line per call, arguments tab-separated (no real argument
# ever holds a tab); answers the two read-only queries from fixture files.
cat >"$work/bin/hyprctl" <<'EOF'
#!/bin/bash
{ printf '%s' "$1"; for a in "${@:2}"; do printf '\t%s' "$a"; done; echo; } >>"$FAKE_LOG"
case "$*" in
  "-j status") cat "$FAKE_STATUS" ;;
  "-j binds") sleep "$FAKE_BINDS_DELAY"; cat "$FAKE_BINDS" ;;
  *) echo ok ;;
esac
EOF
# logger: keeps the message after "--".
cat >"$work/bin/logger" <<'EOF'
#!/bin/bash
while [[ $# -gt 0 && $1 != -- ]]; do shift; done
[[ ${1:-} == -- ]] && shift
printf '%s\n' "$*" >>"$FAKE_JOURNAL"
EOF
chmod +x "$work/bin/hyprctl" "$work/bin/logger"

# ── fixtures ────────────────────────────────────────────────────────
lua_status='{"configProvider": "lua", "backend": "drm"}'
classic_status='{"configProvider": "hyprlang", "backend": "drm"}'

bind_row() { # modmask key description [submap]
  printf '{"submap":"%s","modmask":%s,"key":"%s","keycode":0,"description":"%s"}' "${4:-}" "$1" "$2" "$3"
}
binds_none='[]'
binds_stock="[$(bind_row 8 TAB 'Focus on next window'),$(bind_row 9 TAB 'Focus on previous window')]"
binds_foreign_alt_tab="[$(bind_row 8 TAB 'My own thing')]"
binds_foreign_super_tab="[$(bind_row 64 TAB 'Next workspace')]"
binds_foreign_in_submap="[$(bind_row 8 TAB 'Resize thing' resize)]"
binds_ours_super="[$(bind_row 64 TAB 'Alt-Tab Switcher: next'),$(bind_row 65 TAB 'Alt-Tab Switcher: prev'),$(bind_row 64 GRAVE 'Alt-Tab Switcher: same app'),$(bind_row 65 GRAVE 'Alt-Tab Switcher: same app prev'),$(bind_row 68 GRAVE 'Alt-Tab Switcher: this workspace'),$(bind_row 69 GRAVE 'Alt-Tab Switcher: this workspace prev')]"

lua_bind() { printf "eval\to.bind(\"%s\", \"%s\", [[%s '%s']])\n" "$1" "$2" "$summon" "$3"; }
lua_unbind() { printf 'eval\thl.unbind("%s")\n' "$1"; }
classic_bind() { printf "keyword\tbindd\t%s,%s,exec,%s '%s'\n" "$1" "$2" "$summon" "$3"; }
classic_unbind() { printf 'keyword\tunbind\t%s\n' "$1"; }

# ── harness ─────────────────────────────────────────────────────────
pass=0
fail=0
rc=0
ok() { pass=$((pass + 1)); }
ko() { fail=$((fail + 1)); printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; }
assert_eq() { if [[ $2 == "$3" ]]; then ok; else ko "$1" "$2" "$3"; fi; }
assert_contains() { if [[ $2 == *"$3"* ]]; then ok; else ko "$1" "to contain: $3" "$2"; fi; }

run_script() { # $1=status $2=binds $3=settings-content|NOFILE [args...]
  printf '%s' "$1" >"$FAKE_STATUS"
  printf '%s' "$2" >"$FAKE_BINDS"
  : >"$FAKE_LOG"
  : >"$FAKE_JOURNAL"
  rm -rf "$settings"
  [[ $3 == NOFILE ]] || printf '%s' "$3" >"$settings"
  shift 3
  set +e
  timeout 30 bash "$script" "$@" >"$work/stdout" 2>"$work/stderr"
  rc=$?
  set -e
}
mutations() { grep -E '^(eval|keyword)' "$FAKE_LOG" || true; }
journal() { cat "$FAKE_JOURNAL"; }

assert_rejected() { # $1=name
  assert_eq "$1: exit 1" 1 "$rc"
  assert_eq "$1: no mutation" "" "$(mutations)"
  assert_contains "$1: journal" "$(journal)" "nothing registered"
}

# ── defaults ────────────────────────────────────────────────────────
run_script "$lua_status" "$binds_none" NOFILE
assert_eq "defaults: exit 0" 0 "$rc"
expected=$(
  lua_bind "ALT + TAB" "Alt-Tab Switcher: next" '{"dir":"next"}'
  lua_bind "ALT + SHIFT + TAB" "Alt-Tab Switcher: prev" '{"dir":"prev"}'
  lua_bind "ALT + GRAVE" "Alt-Tab Switcher: same app" '{"dir":"next","mode":"sameclass"}'
  lua_bind "ALT + SHIFT + GRAVE" "Alt-Tab Switcher: same app prev" '{"dir":"prev","mode":"sameclass"}'
  lua_bind "CTRL + ALT + GRAVE" "Alt-Tab Switcher: this workspace" '{"dir":"next","mode":"sameworkspace"}'
  lua_bind "CTRL + ALT + SHIFT + GRAVE" "Alt-Tab Switcher: this workspace prev" '{"dir":"prev","mode":"sameworkspace"}'
)
assert_eq "defaults: exact Lua registrations" "$expected" "$(mutations)"
assert_contains "defaults: journal" "$(journal)" "bind ALT + TAB -> Alt-Tab Switcher: next"

run_script "$lua_status" "$binds_stock" NOFILE
assert_eq "stock takeover: unbind before bind on the stock combos" \
  "$(lua_unbind "ALT + TAB"; lua_bind "ALT + TAB" "Alt-Tab Switcher: next" '{"dir":"next"}'; lua_unbind "ALT + SHIFT + TAB"; lua_bind "ALT + SHIFT + TAB" "Alt-Tab Switcher: prev" '{"dir":"prev"}')" \
  "$(mutations | head -4)"
assert_eq "stock takeover: six registrations in all" 6 "$(mutations | grep -c 'o.bind(')"
assert_contains "stock takeover: journal" "$(journal)" "takeover ALT + TAB -> Alt-Tab Switcher: next"

run_script "$lua_status" "$binds_foreign_alt_tab" NOFILE
assert_eq "foreign bind on a default combo is left alone" "" "$(mutations | grep 'ALT + TAB"' | grep -v SHIFT || true)"
assert_eq "foreign bind: the other five are registered" 5 "$(mutations | grep -c 'o.bind(')"
assert_contains "foreign bind: journal" "$(journal)" "leaving your own bind on ALT + TAB alone"

run_script "$lua_status" "$binds_foreign_in_submap" NOFILE
assert_eq "a bind inside a submap does not count as a conflict" 6 "$(mutations | grep -c 'o.bind(')"

run_script "$lua_status" "$binds_ours_super" '{"modifier": "SUPER"}'
assert_eq "idempotent: exit 0" 0 "$rc"
assert_eq "idempotent: already ours means no calls at all" "" "$(mutations)"

run_script "$lua_status" "$binds_foreign_super_tab" '{"modifier": "super"}'
assert_eq "SUPER: a non-ALT modifier takes over foreign binds and tells the switcher" \
  "$(lua_unbind "SUPER + TAB"; lua_bind "SUPER + TAB" "Alt-Tab Switcher: next" '{"dir":"next","modifier":"super"}')" \
  "$(mutations | head -2)"
assert_eq "SUPER: six registrations in all" 6 "$(mutations | grep -c 'o.bind(')"

run_script "$lua_status" "$binds_foreign_alt_tab" '{"modifier": "alt"}'
assert_eq "explicit ALT still leaves foreign binds alone" 5 "$(mutations | grep -c 'o.bind(')"

run_script "$lua_status" "$binds_stock" '{"autoBinds": false}'
assert_eq "autoBinds false: exit 0" 0 "$rc"
assert_eq "autoBinds false: no calls" "" "$(mutations)"
assert_contains "autoBinds false: journal" "$(journal)" "autoBinds is false"

# ── custom binds ────────────────────────────────────────────────────
run_script "$lua_status" "$binds_none" '{"binds": [
  {"combo": "super+shift+tab", "payload": {"dir": "prev", "modifier": "super"}, "description": "Window picker (back)"},
  {"combo": " Ctrl + F1 ", "payload": {"dir": "next", "modifier": "none", "hold": false}},
  {"combo": "SUPER + code:65", "payload": {"variant": "bare", "mode": "sameworkspace"}},
  {"combo": "XF86AudioPlay"}
]}'
assert_eq "custom: exit 0" 0 "$rc"
expected=$(
  lua_bind "SUPER + SHIFT + tab" "Window picker (back)" '{"dir":"prev","modifier":"super"}'
  lua_bind "CTRL + F1" "Alt-Tab Switcher: CTRL + F1" '{"dir":"next","modifier":"none","hold":false}'
  lua_bind "SUPER + code:65" "Alt-Tab Switcher: SUPER + code:65" '{"dir":"next","mode":"sameworkspace","variant":"bare"}'
  lua_bind "XF86AudioPlay" "Alt-Tab Switcher: XF86AudioPlay" '{"dir":"next"}'
)
assert_eq "custom: normalized combos, defaulted descriptions, regenerated payloads" "$expected" "$(mutations)"

run_script "$lua_status" "$binds_foreign_super_tab" '{"binds": [{"combo": "SUPER + TAB"}]}'
assert_eq "custom: a listed combo takes over a foreign bind" \
  "$(lua_unbind "SUPER + TAB"; lua_bind "SUPER + TAB" "Alt-Tab Switcher: SUPER + TAB" '{"dir":"next"}')" \
  "$(mutations)"

run_script "$lua_status" "$binds_none" '{"binds": []}'
assert_eq "custom: an empty list means the defaults" 6 "$(mutations | grep -c 'o.bind(')"

# ── classic config syntax ───────────────────────────────────────────
run_script "$classic_status" "$binds_stock" NOFILE
assert_eq "classic: exit 0" 0 "$rc"
expected=$(
  classic_unbind "ALT,TAB"
  classic_bind "ALT,TAB" "Alt-Tab Switcher: next" '{"dir":"next"}'
  classic_unbind "ALT SHIFT,TAB"
  classic_bind "ALT SHIFT,TAB" "Alt-Tab Switcher: prev" '{"dir":"prev"}'
  classic_bind "ALT,GRAVE" "Alt-Tab Switcher: same app" '{"dir":"next","mode":"sameclass"}'
  classic_bind "ALT SHIFT,GRAVE" "Alt-Tab Switcher: same app prev" '{"dir":"prev","mode":"sameclass"}'
  classic_bind "CTRL ALT,GRAVE" "Alt-Tab Switcher: this workspace" '{"dir":"next","mode":"sameworkspace"}'
  classic_bind "CTRL ALT SHIFT,GRAVE" "Alt-Tab Switcher: this workspace prev" '{"dir":"prev","mode":"sameworkspace"}'
)
assert_eq "classic: bindd carries the description, unbind precedes a takeover" "$expected" "$(mutations)"

# ── rejected settings: nothing is registered, ever ─────────────────
rejects=(
  '{"binds":[{"combo":"SUPER + TAB\"), os.exit() --"}]}'
  '{"binds":[{"combo":"SUPER + TAB","description":"x\", \"y"}]}'
  '{"binds":[{"combo":"SUPER + TAB","description":"a,b"}]}'
  '{"binds":[{"combo":"SUPER + TAB","description":"a\nb"}]}'
  '{"binds":[{"combo":"SUPER + TAB","description":"'"'"'; rm -rf ~; '"'"'"}]}'
  '{"binds":[{"combo":"SUPER + TAB","description":"$(id)"}]}'
  '{"binds":[{"combo":"SUPER + TAB","description":"back\\slash"}]}'
  '{"binds":[{"combo":"SUPER + TAB","description":""}]}'
  '{"binds":[{"combo":"SUPER + TAB","description":"01234567890123456789012345678901234567890123456789012345678901234"}]}'
  '{"binds":[{"combo":"SUPER + TAB","payload":{"dir":"next]] .. os.execute(\"id\") .. [["}}]}'
  '{"binds":[{"combo":"SUPER + TAB","payload":{"dir":"next","extra":1}}]}'
  '{"binds":[{"combo":"SUPER + TAB","payload":"{\"dir\":\"next\"}"}]}'
  '{"binds":[{"combo":"SUPER + TAB","payload":{"hold":"yes"}}]}'
  '{"binds":[{"combo":"SUPER + TAB","payload":{"mode":"SameClass"}}]}'
  '{"binds":[{"combo":"SUPER + TAB","payload":{"modifier":"ctrl"}}]}'
  '{"binds":[{"combo":"SUPER | TAB"}]}'
  '{"binds":[{"combo":"SUPER + TAB + "}]}'
  '{"binds":[{"combo":"SUPER + TAB"},{"combo":"super+tab"}]}'
  '{"binds":[{"combo":"SUPER + ALT"}]}'
  '{"binds":[{"combo":"mouse:272"}]}'
  '{"binds":[{"combo":"catchall"}]}'
  '{"binds":[{"combo":"SUPER + TAB","extra":true}]}'
  '{"binds":[{"payload":{"dir":"next"}}]}'
  '{"binds":["SUPER + TAB"]}'
  '{"binds":"SUPER + TAB"}'
  '{"modifier":"CTRL"}'
  '{"modifier":["SUPER"]}'
  '{"autoBinds":"false"}'
  '{"autobinds":false}'
  '[]'
  '"SUPER + TAB"'
  '{} {}'
  ''
  'not json'
)
for json in "${rejects[@]}"; do
  run_script "$lua_status" "$binds_stock" "$json"
  assert_rejected "rejected: $json"
done

# ── rejected settings files: shape, not content ────────────────────
run_raw() { # the settings path is prepared by the caller
  printf '%s' "$lua_status" >"$FAKE_STATUS"
  printf '%s' "$binds_none" >"$FAKE_BINDS"
  : >"$FAKE_LOG"
  : >"$FAKE_JOURNAL"
  set +e
  timeout 30 bash "$script" >"$work/stdout" 2>"$work/stderr"
  rc=$?
  set -e
}

printf '%s' '{"modifier": "SUPER"}' >"$work/real.json"
rm -rf "$settings"; ln -s "$work/real.json" "$settings"
run_raw
assert_rejected "symlinked settings file"
assert_contains "symlinked settings file: reason" "$(journal)" "symlink"

rm -rf "$settings"; mkdir "$settings"
run_raw
assert_rejected "directory at the settings path"

rm -rf "$settings"; mkfifo "$settings"
run_raw
assert_rejected "fifo at the settings path (must not block)"
rm -f "$settings"

run_script "$lua_status" "$binds_none" "$(printf '{"modifier": "SUPER"%70000s}' '')"
assert_rejected "oversized settings file"
assert_contains "oversized settings file: reason" "$(journal)" "limit"

# ── the compositor side ────────────────────────────────────────────
run_script "$lua_status" "garbage" NOFILE
assert_rejected "unreadable bind table"
assert_contains "unreadable bind table: reason" "$(journal)" "could not read the bind table"

big_binds=$(jq -nc '[range(45000) | {"submap":"","modmask":0,"key":"X","keycode":0,"description":"a fairly long description that pads the table out to well over the byte cap"}]')
run_script "$lua_status" "$big_binds" NOFILE
assert_rejected "oversized bind table"
assert_contains "oversized bind table: reason" "$(journal)" "exceeds"

export FAKE_BINDS_DELAY=20
start=$SECONDS
run_script "$lua_status" "$binds_none" NOFILE
elapsed=$((SECONDS - start))
export FAKE_BINDS_DELAY=0
assert_rejected "hung hyprctl"
if (( elapsed < 12 )); then ok; else ko "hung hyprctl: deadline" "under 12s" "${elapsed}s"; fi

# ── dry run ─────────────────────────────────────────────────────────
run_script "$lua_status" "$binds_stock" NOFILE --dry-run
assert_eq "dry run: exit 0" 0 "$rc"
assert_eq "dry run: no mutation" "" "$(mutations)"
assert_contains "dry run: prints the decisions" "$(cat "$work/stdout")" "takeover ALT + TAB -> Alt-Tab Switcher: next"
assert_contains "dry run: prints the commands" "$(cat "$work/stderr")" "would run: hyprctl eval"
run_script "$lua_status" "$binds_ours_super" '{"modifier": "SUPER"}' --dry-run
assert_contains "dry run: reports combos that are already ours" "$(cat "$work/stdout")" "SUPER + TAB is already ours"

# ── summary ─────────────────────────────────────────────────────────
printf '%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
