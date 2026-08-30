#!/bin/bash
# Registers the switcher's keybindings. Run by Service.qml at shell startup
# and after every Hyprland config reload, since dynamic binds don't survive a
# reload.
#
# Settings live in ~/.config/omarchy/alt-tab.json:
#   {"autoBinds": false}            -> register nothing, ever
#   {"modifier": "SUPER"}           -> same defaults on another modifier
#   {"binds": [ {"combo": "...", "payload": {...}, "description": "..."} ]}
#                                   -> replace the defaults entirely
#
# Policy per combo:
#   already ours                        -> leave as is (idempotent)
#   unbound                             -> bind
#   only known stock Omarchy cycle binds-> take over
#   anything else (a bind of your own)  -> leave alone; your config wins
# Combos listed explicitly in `binds` are always taken over: asking for them
# in this file IS the user's decision.
set -uo pipefail

SETTINGS="$HOME/.config/omarchy/alt-tab.json"
PLUGIN_ID="io.github.luwojtaszek.alt-tab"
SUMMON="omarchy-shell shell summon $PLUGIN_ID"

# Stock Omarchy binds we are willing to replace on a default combo.
STOCK_DESCS='Focus on next window
Focus on previous window
Reveal active window on top
Focus on next monitor
Focus on previous monitor'

setting() { # $1=jq filter, $2=fallback
  local v
  [[ -f $SETTINGS ]] && command -v jq >/dev/null || { echo "$2"; return; }
  v=$(jq -r "$1 // empty" "$SETTINGS" 2>/dev/null) || v=""
  [[ -n $v && $v != "null" ]] && echo "$v" || echo "$2"
}

[[ $(setting '.autoBinds' true) == false ]] && { logger -t alt-tab-binds "autoBinds disabled"; exit 0; }

MODIFIER=$(setting '.modifier' ALT); MODIFIER=${MODIFIER^^}
MOD_LOWER=${MODIFIER,,}

BINDS=$(hyprctl binds 2>/dev/null) || exit 0
if hyprctl dispatch 'hl.dsp.no_op()' 2>/dev/null | grep -q '^ok'; then LUA=1; else LUA=0; fi

# combo -> Hyprland modmask / key name, so existing binds can be looked up.
combo_modmask() {
  local m=0 tok
  for tok in ${1//+/ }; do
    case "${tok^^}" in
      SHIFT) ((m |= 1)) ;;
      CAPS|CAPSLOCK) ((m |= 2)) ;;
      CTRL|CONTROL) ((m |= 4)) ;;
      ALT|MOD1) ((m |= 8)) ;;
      MOD2) ((m |= 16)) ;;
      MOD3) ((m |= 32)) ;;
      SUPER|MOD4|WIN|LOGO) ((m |= 64)) ;;
      MOD5) ((m |= 128)) ;;
    esac
  done
  echo "$m"
}
combo_key() { local t last; for t in ${1//+/ }; do last=$t; done; echo "${last^^}"; }

# All descriptions currently bound on a modmask+key, one per line.
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

# Work list: "combo|description|payload|force", one per line.
plan() {
  local custom
  custom=$(jq -c '.binds[]? | select(.combo)' "$SETTINGS" 2>/dev/null)
  if [[ -n ${custom:-} ]]; then
    while IFS= read -r entry; do
      local combo payload desc
      combo=$(jq -r '.combo' <<<"$entry")
      payload=$(jq -c '.payload // {"dir":"next"}' <<<"$entry")
      desc=$(jq -r '.description // empty' <<<"$entry")
      [[ -z $desc ]] && desc="Alt-Tab Switcher: $combo"
      printf '%s|%s|%s|1\n' "$combo" "$desc" "$payload"
    done <<<"$custom"
    return
  fi
  # Defaults, on MODIFIER. Non-ALT modifiers are passed to the switcher too,
  # so it watches the right key for the release that commits the selection.
  local extra=""
  [[ $MODIFIER != ALT ]] && extra=",\"modifier\":\"$MOD_LOWER\""
  cat <<EOF
$MODIFIER + TAB|Alt-Tab Switcher: next|{"dir":"next"$extra}|0
$MODIFIER + SHIFT + TAB|Alt-Tab Switcher: prev|{"dir":"prev"$extra}|0
$MODIFIER + GRAVE|Alt-Tab Switcher: same app|{"dir":"next","mode":"sameclass"$extra}|0
$MODIFIER + SHIFT + GRAVE|Alt-Tab Switcher: same app prev|{"dir":"prev","mode":"sameclass"$extra}|0
EOF
}

classic_combo() { # "SUPER + SHIFT + TAB" -> "SUPER SHIFT,Tab"
  local key mods=() tok
  key=$(combo_key "$1")
  for tok in ${1//+/ }; do
    case "${tok^^}" in TAB|GRAVE|SPACE|ESCAPE) ;; *) mods+=("${tok^^}") ;; esac
  done
  case $key in TAB) key=Tab ;; GRAVE) key=grave ;; SPACE) key=space ;; esac
  echo "${mods[*]},$key"
}

while IFS='|' read -r combo desc payload force; do
  [[ -z ${combo:-} ]] && continue
  modmask=$(combo_modmask "$combo")
  key=$(combo_key "$combo")
  descs=$(combo_descs "$modmask" "$key")

  grep -qxF "$desc" <<<"$descs" && continue # already ours

  action="bind"
  if [[ -n $descs ]]; then
    action="takeover"
    if [[ $force != 1 ]]; then
      while IFS= read -r d; do
        [[ -z $d ]] && continue
        grep -qxF "$d" <<<"$STOCK_DESCS" || { action="skip"; break; }
      done <<<"$descs"
    fi
  fi

  if [[ $action == skip ]]; then
    logger -t alt-tab-binds "leaving your own bind on $combo alone"
    continue
  fi

  if (( LUA )); then
    [[ $action == takeover ]] && hyprctl eval "hl.unbind(\"$combo\")" >/dev/null
    hyprctl eval "o.bind(\"$combo\", \"$desc\", [[$SUMMON '$payload']])" >/dev/null \
      && logger -t alt-tab-binds "$action $combo -> $desc"
  else
    classic=$(classic_combo "$combo")
    [[ $action == takeover ]] && hyprctl keyword unbind "$classic" >/dev/null
    hyprctl keyword bind "$classic,exec,$SUMMON '$payload'" >/dev/null \
      && logger -t alt-tab-binds "$action $combo -> $desc (classic)"
  fi
done < <(plan)
exit 0
