#!/bin/bash
# Registers the switcher's default keybindings, run by Service.qml at shell
# startup and after every Hyprland config reload (dynamic binds don't survive
# a reload). Per combo:
#   - already carrying our description        -> leave as is
#   - unbound                                 -> bind
#   - bound only to known stock Omarchy binds -> take over (unbind + bind)
#   - bound to anything else (user's own)     -> leave the user in charge
# Opt out entirely with ~/.config/omarchy/alt-tab.json: {"autoBinds": false}
set -uo pipefail

SETTINGS="$HOME/.config/omarchy/alt-tab.json"
if [[ -f $SETTINGS ]] && command -v jq >/dev/null \
  && [[ $(jq -r '.autoBinds != false' "$SETTINGS" 2>/dev/null) == "false" ]]; then
  logger -t alt-tab-binds "autoBinds disabled in alt-tab.json"
  exit 0
fi

SUMMON="omarchy-shell shell summon io.github.luwojtaszek.alt-tab"
BINDS=$(hyprctl binds 2>/dev/null) || exit 0
if hyprctl dispatch 'hl.dsp.no_op()' 2>/dev/null | grep -q '^ok'; then LUA=1; else LUA=0; fi

# combo|modmask|key|our description|payload|takeover descriptions (;-separated)
TABLE=$(cat <<'EOF'
ALT + TAB|8|TAB|Alt-Tab Switcher: next|{"dir":"next"}|Focus on next window;Reveal active window on top
ALT + SHIFT + TAB|9|TAB|Alt-Tab Switcher: prev|{"dir":"prev"}|Focus on previous window
ALT + GRAVE|8|GRAVE|Alt-Tab Switcher: same app|{"dir":"next","mode":"sameclass"}|
ALT + SHIFT + GRAVE|9|GRAVE|Alt-Tab Switcher: same app prev|{"dir":"prev","mode":"sameclass"}|
EOF
)

# All descriptions bound on a given modmask+key, one per line.
combo_descs() {
  awk -v m="$1" -v k="$2" '
    BEGIN { RS=""; FS="\n" }
    {
      hasM = 0; hasK = 0; delete descs; n = 0
      for (i = 1; i <= NF; i++) {
        line = $i; gsub(/^[ \t]+|[ \t\r]+$/, "", line)
        if (line == "modmask: " m) hasM = 1
        if (line == "key: " k) hasK = 1
        if (index(line, "description: ") == 1) descs[++n] = substr(line, 14)
      }
      if (hasM && hasK) for (i = 1; i <= n; i++) print descs[i]
    }' <<<"$BINDS"
}

while IFS='|' read -r combo modmask key desc payload takeover; do
  [[ -z $combo ]] && continue
  descs=$(combo_descs "$modmask" "$key")
  if grep -qxF "$desc" <<<"$descs"; then
    continue # already ours
  fi
  action="bind"
  if [[ -n $descs ]]; then
    action="takeover"
    while IFS= read -r d; do
      [[ -z $d ]] && continue
      if ! grep -qxF "$d" <<<"${takeover//;/$'\n'}"; then
        action="skip"; break
      fi
    done <<<"$descs"
  fi
  if [[ $action == "skip" ]]; then
    logger -t alt-tab-binds "leaving user bind on $combo alone"
    continue
  fi
  if (( LUA )); then
    [[ $action == "takeover" ]] && hyprctl eval "hl.unbind(\"$combo\")" >/dev/null
    hyprctl eval "o.bind(\"$combo\", \"$desc\", [[$SUMMON '$payload']])" >/dev/null \
      && logger -t alt-tab-binds "$action $combo -> $desc"
  else
    classic="${combo//ALT + SHIFT/ALT SHIFT}"; classic="${classic// + /,}"
    classic="${classic/GRAVE/grave}"; classic="${classic/TAB/Tab}"
    [[ $action == "takeover" ]] && hyprctl keyword unbind "$classic" >/dev/null
    hyprctl keyword bind "$classic,exec,$SUMMON '$payload'" >/dev/null \
      && logger -t alt-tab-binds "$action $combo -> $desc (classic)"
  fi
done <<<"$TABLE"
exit 0
