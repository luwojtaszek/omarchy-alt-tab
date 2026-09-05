#!/bin/bash
# Registers the switcher's keybindings. Run by Service.qml at shell startup
# and after every Hyprland config reload, since dynamic binds don't survive
# a reload. `bash apply-binds.sh --dry-run` prints what it would do instead
# of doing it.
#
# Settings live in ~/.config/omarchy/alt-tab.json (README, "Keybindings"):
#   {"autoBinds": false}            -> register nothing, ever
#   {"modifier": "SUPER"}           -> the default set on SUPER instead of ALT
#   {"binds": [ {"combo": "...", "payload": {...}, "description": "..."} ]}
#                                   -> replace the defaults entirely
#
# Policy per combo:
#   already ours                         -> leave as is (idempotent)
#   unbound                              -> bind
#   only known stock Omarchy cycle binds -> take over
#   anything else (a bind of your own)   -> leave alone; your config wins
# Combos listed under `binds`, and the defaults on a non-ALT modifier, are
# always taken over: asking for them in the settings file is the decision.
#
# Trust boundary. The settings file is untrusted input.
#   * It is read through a descriptor that is verified to be the regular,
#     user-owned, size-capped file that was checked: a symlink is refused,
#     and a file swapped in between the check and the open is detected
#     (device:inode of the path vs. the open descriptor).
#   * jq parses it once against the schema in SCHEMA below. Any violation
#     invalidates the whole file: nothing is registered and the reason goes
#     to the journal (journalctl -t alt-tab-binds).
#   * The only strings that reach Hyprland -- combo, description, summon
#     payload -- are matched against an allowlist again right where they
#     are interpolated into Lua source, the classic bind grammar and the
#     shell command the bind executes. No quote, backslash, bracket, comma,
#     newline or shell metacharacter can get there. The payload is
#     regenerated from validated enum values, never copied from the file.
#   * Every subprocess runs under a deadline and its output is size-capped;
#     Service.qml wraps the whole script in a process-group deadline too.
set -euo pipefail
export LC_ALL=C # byte semantics for ${#x}, [[ =~ ]] and ${x^^}

: "${HOME:?HOME is not set}"
readonly SETTINGS="$HOME/.config/omarchy/alt-tab.json"
readonly PLUGIN_ID="io.github.luwojtaszek.alt-tab"
readonly SUMMON="omarchy-shell shell summon $PLUGIN_ID"
readonly TAG="alt-tab-binds"

readonly SETTINGS_MAX_BYTES=65536 # a settings file is a few hundred bytes
readonly BINDS_MAX_BYTES=4194304  # `hyprctl -j binds` is ~120 KiB on stock Omarchy
readonly OUTPUT_MAX_BYTES=4096    # any other subprocess output that is kept
readonly DEADLINE=5               # seconds, per subprocess

# Sink allowlists. SCHEMA (jq) admits nothing outside these; they are
# checked again on every string right before it is interpolated, so the
# sinks stay safe even if the schema is edited carelessly one day.
readonly RE_COMBO='^[A-Za-z0-9_:]{1,32}( \+ [A-Za-z0-9_:]{1,32}){0,5}$'
readonly RE_DESC='^[A-Za-z0-9][A-Za-z0-9 ._:/()+-]{0,63}$'
readonly RE_PAYLOAD='^[{][a-z",:-]{1,160}[}]$'

# Stock Omarchy binds that a default combo may replace.
readonly STOCK_JSON='["Focus on next window","Focus on previous window","Reveal active window on top","Focus on next monitor","Focus on previous monitor"]'

DRY_RUN=0
[[ ${1:-} == --dry-run ]] && DRY_RUN=1

log() {
  if (( DRY_RUN )); then printf '%s\n' "$*"
  else timeout "$DEADLINE" logger -t "$TAG" -- "$*" 2>/dev/null || true; fi
}
die() { log "$*; nothing registered"; exit 1; }
run() { timeout --kill-after=1 "$DEADLINE" "$@"; } # every subprocess gets a deadline

# Mutating hyprctl calls go through here; --dry-run prints them instead.
hypr_apply() {
  if (( DRY_RUN )); then
    { printf 'would run: hyprctl'; printf ' %q' "$@"; echo; } >&2
    echo ok
    return 0
  fi
  run hyprctl "$@" 2>&1 | head -c "$OUTPUT_MAX_BYTES"
}

# ── Settings file ──────────────────────────────────────────────────

# Opens the settings file on the global descriptor `settings_fd` after
# verifying it. Returns 1 when there is no settings file at all.
settings_fd=-1
open_settings() {
  local ref got size
  [[ -e $SETTINGS || -L $SETTINGS ]] || return 1
  [[ -L $SETTINGS ]] && die "refusing $SETTINGS: it is a symlink"
  [[ -f $SETTINGS && -r $SETTINGS ]] || die "refusing $SETTINGS: not a readable regular file"
  ref=$(stat -c '%d:%i' -- "$SETTINGS") || die "cannot stat $SETTINGS"
  exec {settings_fd}<"$SETTINGS"
  # Verify the descriptor, not the path: what was opened must be the very
  # inode that was just checked, a regular file, and owned by this user.
  got=$(stat -L -c '%d:%i' -- "/dev/fd/$settings_fd") || die "cannot stat the opened $SETTINGS"
  [[ $ref == "$got" ]] || die "refusing $SETTINGS: it was replaced while being opened"
  [[ -f /dev/fd/$settings_fd && -O /dev/fd/$settings_fd ]] || die "refusing $SETTINGS: not a regular file owned by you"
  size=$(stat -L -c '%s' -- "/dev/fd/$settings_fd") || die "cannot stat the opened $SETTINGS"
  (( size <= SETTINGS_MAX_BYTES )) || die "refusing $SETTINGS: $size bytes, the limit is $SETTINGS_MAX_BYTES"
}

# The whole settings schema, in one place. Runs on the slurped file (an
# array of the JSON values it holds) and emits the plan as TSV rows:
#   setting <TAB> autoBinds <TAB> true|false
#   setting <TAB> modifier  <TAB> ALT|SUPER
#   bind    <TAB> combo     <TAB> description <TAB> payload
# Every emitted string is either drawn from a fixed vocabulary or has
# matched the same allowlist as RE_COMBO / RE_DESC above; the payload is
# rebuilt from validated enum values.
read -r -d '' SCHEMA <<'JQ' || true
def fail(msg): error(msg);

def modifiers: {
  "SHIFT": "SHIFT", "CAPS": "CAPS", "CAPSLOCK": "CAPS",
  "CTRL": "CTRL", "CONTROL": "CTRL",
  "ALT": "ALT", "MOD1": "ALT", "MOD2": "MOD2", "MOD3": "MOD3",
  "SUPER": "SUPER", "WIN": "SUPER", "LOGO": "SUPER", "MOD4": "SUPER",
  "MOD5": "MOD5"
};

# "super+shift+tab" -> "SUPER + SHIFT + tab": canonical modifiers first,
# then exactly one key -- a keysym name or code:<keycode>.
def combo:
  if type != "string" then fail("combo must be a string") else . end
  | if length > 96 then fail("combo is too long") else . end
  | split("+") | map(gsub("^\\s+|\\s+$"; ""))
  | if length > 6 then fail("combo has too many parts") else . end
  | if any(.[]; . == "") then fail("combo has an empty part") else . end
  | (.[:-1] | map(ascii_upcase | modifiers[.] // fail("unknown modifier \"\(.)\""))) as $mods
  | .[-1] as $key
  | if modifiers[$key | ascii_upcase] != null then fail("combo must end with a key, not a modifier") else . end
  | if ($key | ascii_downcase | IN("catchall", "mouse_down", "mouse_up")) then fail("unsupported key \"\($key)\"") else . end
  | if ($key | test("^[A-Za-z0-9_]{1,32}$")) or ($key | test("^code:[0-9]{1,5}$")) then .
    else fail("unsupported key \"\($key)\"") end
  | ($mods + [$key]) | join(" + ");

def description($combo):
  if . == null then "Alt-Tab Switcher: \($combo)" else . end
  | if type != "string" then fail("description must be a string") else . end
  | if test("^[A-Za-z0-9][A-Za-z0-9 ._:/()+-]{0,63}$") then .
    else fail("description may only use letters, digits, spaces and . _ : / ( ) + - (1 to 64 characters)") end;

def enum($name; $allowed):
  if IN($allowed[]) then . else fail("payload." + $name + " must be one of " + ($allowed | join(", "))) end;

def payload:
  if . == null then {} else . end
  | if type != "object" then fail("payload must be an object") else . end
  | (keys - ["dir", "hold", "mode", "modifier", "variant"]) as $unknown
  | if ($unknown | length) > 0 then fail("unknown payload key \"\($unknown[0])\"") else . end
  | { dir: (if has("dir") then .dir else "next" end) }
    + (if has("mode") then { mode: .mode } else {} end)
    + (if has("variant") then { variant: .variant } else {} end)
    + (if has("modifier") then { modifier: .modifier } else {} end)
    + (if has("hold") then { hold: .hold } else {} end)
  | .dir |= enum("dir"; ["next", "prev"])
  | if has("mode") then .mode |= enum("mode"; ["all", "sameclass", "sameworkspace"]) else . end
  | if has("variant") then .variant |= enum("variant"; ["two-line", "bare"]) else . end
  | if has("modifier") then .modifier |= enum("modifier"; ["alt", "super", "none"]) else . end
  | if has("hold") and (.hold | type) != "boolean" then fail("payload.hold must be true or false") else . end
  | tojson;

if length != 1 then fail("the file must hold exactly one JSON object") else .[0] end
| if type != "object" then fail("the top level must be a JSON object") else . end
| (keys - ["autoBinds", "binds", "modifier"]) as $unknown
| if ($unknown | length) > 0 then fail("unknown key \"\($unknown[0])\"") else . end
| (if has("autoBinds") then (.autoBinds | if type == "boolean" then . else fail("autoBinds must be true or false") end) else true end) as $auto
| (if has("modifier") then (.modifier | if type == "string" and (ascii_upcase | IN("ALT", "SUPER")) then ascii_upcase else fail("modifier must be ALT or SUPER") end) else "ALT" end) as $modifier
| (if has("binds") then (.binds | if type == "array" then . else fail("binds must be an array") end) else [] end) as $binds
| if ($binds | length) > 32 then fail("at most 32 binds") else . end
| [ ["setting", "autoBinds", ($auto | tostring)], ["setting", "modifier", $modifier] ]
  + [ $binds[]
      | if type != "object" then fail("each bind must be an object") else . end
      | (keys - ["combo", "description", "payload"]) as $unknown
      | if ($unknown | length) > 0 then fail("unknown bind key \"\($unknown[0])\"") else . end
      | if (has("combo") | not) then fail("a bind needs a combo") else . end
      | (.combo | combo) as $combo
      | ["bind", $combo, (.description | description($combo)), (.payload | payload)] ]
| ([ .[] | select(.[0] == "bind") | .[1] | ascii_upcase ] | if (unique | length) != length then fail("a combo is listed twice") else . end) as $combos
| .[] | @tsv
JQ

# ── Hyprland ───────────────────────────────────────────────────────

lua=0        # config provider: Lua (hyprctl eval) or classic (hyprctl keyword)
binds_json=  # `hyprctl -j binds`, size-capped and verified to be an array

combo_modmask() { # "CTRL + SUPER + TAB" -> 68 (Hyprland modmask)
  local m=0 tok
  for tok in $1; do
    case $tok in
      SHIFT) m=$(( m | 1 )) ;;   CAPS) m=$(( m | 2 )) ;;
      CTRL) m=$(( m | 4 )) ;;    ALT) m=$(( m | 8 )) ;;
      MOD2) m=$(( m | 16 )) ;;   MOD3) m=$(( m | 32 )) ;;
      SUPER) m=$(( m | 64 )) ;;  MOD5) m=$(( m | 128 )) ;;
    esac
  done
  echo "$m"
}

classic_combo() { # "CTRL + SUPER + TAB" -> "CTRL SUPER,TAB"
  local mods=() tok key=${1##* }
  for tok in $1; do
    [[ $tok == "+" || $tok == "$key" ]] && continue
    mods+=("$tok")
  done
  echo "${mods[*]},$key"
}

# What is on a combo right now: ours | free | stock | foreign.
# Descriptions of existing binds never leave jq; only the verdict does.
classify() { # $1=modmask $2=key $3=our description
  printf '%s' "$binds_json" | run jq -r --argjson m "$1" --arg k "$2" --arg ours "$3" --argjson stock "$STOCK_JSON" '
    [ .[]
      | select((.submap // "") == "" and .modmask == $m and (
          if ($k | startswith("code:")) then .keycode == ($k[5:] | tonumber)
          else ((.key // "") | ascii_upcase) == ($k | ascii_upcase) end))
      | (.description // "") ] as $found
    | if any($found[]; . == $ours) then "ours"
      elif ($found | length) == 0 then "free"
      elif all($found[]; IN($stock[])) then "stock"
      else "foreign" end' 2>/dev/null || echo error
}

register() { # $1=bind|takeover $2=combo $3=description $4=payload
  local action=$1 combo=$2 desc=$3 payload=$4 out classic
  # Sink guard: nothing outside the allowlists is ever interpolated.
  [[ $combo =~ $RE_COMBO ]] || die "internal error: combo failed the allowlist"
  [[ $desc =~ $RE_DESC ]] || die "internal error: description failed the allowlist"
  [[ $payload =~ $RE_PAYLOAD ]] || die "internal error: payload failed the allowlist"

  if (( lua )); then
    if [[ $action == takeover ]]; then
      out=$(hypr_apply eval "hl.unbind(\"$combo\")") || out=""
      [[ $out == ok* ]] || log "could not unbind $combo first: ${out:-no reply from hyprctl}"
    fi
    out=$(hypr_apply eval "o.bind(\"$combo\", \"$desc\", [[$SUMMON '$payload']])") || out=""
  else
    classic=$(classic_combo "$combo")
    if [[ $action == takeover ]]; then
      out=$(hypr_apply keyword unbind "$classic") || out=""
      [[ $out == ok* ]] || log "could not unbind $combo first: ${out:-no reply from hyprctl}"
    fi
    out=$(hypr_apply keyword bindd "$classic,$desc,exec,$SUMMON '$payload'") || out=""
  fi

  if [[ $out == ok* ]]; then log "$action $combo -> $desc"
  else log "failed to $action $combo: ${out:-no reply from hyprctl}"; fi
}

# ── Main ───────────────────────────────────────────────────────────

main() {
  command -v jq >/dev/null 2>&1 || die "jq is not installed"

  local auto=true modifier=ALT custom=() content plan kind a b c
  if open_settings; then
    content=$(head -c "$SETTINGS_MAX_BYTES" <&"$settings_fd")
    exec {settings_fd}<&-
    plan=$(printf '%s' "$content" | run jq -rs "$SCHEMA" 2>&1 | head -c 65536) \
      || die "invalid $SETTINGS: ${plan:-validation timed out}"
    while IFS=$'\t' read -r kind a b c; do
      case $kind in
        setting)
          case $a in
            autoBinds) auto=$b ;;
            modifier) modifier=$b ;;
            *) die "internal error: unexpected setting row" ;;
          esac ;;
        bind) custom+=("$a"$'\t'"$b"$'\t'"$c") ;;
        *) die "internal error: unexpected plan row" ;;
      esac
    done <<<"$plan"
  fi

  if [[ $auto != true ]]; then
    log "autoBinds is false: nothing to do"
    return 0
  fi
  [[ $modifier == ALT || $modifier == SUPER ]] || die "internal error: bad modifier"

  local provider
  provider=$(run hyprctl -j status 2>/dev/null | head -c "$OUTPUT_MAX_BYTES" \
    | run jq -r '.configProvider // ""' 2>/dev/null) || provider=""
  if [[ $provider == lua ]]; then lua=1; fi

  # Whatever came back before a deadline or the byte cap cut it off is kept
  # on purpose: an oversized table is reported as such, a truncated one
  # fails the array check below.
  binds_json=$(run hyprctl -j binds 2>/dev/null | head -c $((BINDS_MAX_BYTES + 1)) || true)
  (( ${#binds_json} <= BINDS_MAX_BYTES )) || die "the bind table exceeds $BINDS_MAX_BYTES bytes"
  printf '%s' "$binds_json" | run jq -e 'type == "array"' >/dev/null 2>&1 \
    || die "could not read the bind table from hyprctl"

  # The plan: explicit binds, or the default set on the chosen modifier.
  # Non-ALT defaults count as an explicit request too (asking for SUPER
  # means taking over what Omarchy had there, e.g. Super+Tab = Next
  # workspace), and the switcher is told which key's release commits.
  local rows=() force=0 extra=""
  if (( ${#custom[@]} )); then
    rows=("${custom[@]}")
    force=1
  else
    if [[ $modifier == SUPER ]]; then
      extra=',"modifier":"super"'
      force=1
    fi
    rows=(
      "$modifier + TAB"$'\t'"Alt-Tab Switcher: next"$'\t'"{\"dir\":\"next\"$extra}"
      "$modifier + SHIFT + TAB"$'\t'"Alt-Tab Switcher: prev"$'\t'"{\"dir\":\"prev\"$extra}"
      "$modifier + GRAVE"$'\t'"Alt-Tab Switcher: same app"$'\t'"{\"dir\":\"next\",\"mode\":\"sameclass\"$extra}"
      "$modifier + SHIFT + GRAVE"$'\t'"Alt-Tab Switcher: same app prev"$'\t'"{\"dir\":\"prev\",\"mode\":\"sameclass\"$extra}"
      "CTRL + $modifier + GRAVE"$'\t'"Alt-Tab Switcher: this workspace"$'\t'"{\"dir\":\"next\",\"mode\":\"sameworkspace\"$extra}"
      "CTRL + $modifier + SHIFT + GRAVE"$'\t'"Alt-Tab Switcher: this workspace prev"$'\t'"{\"dir\":\"prev\",\"mode\":\"sameworkspace\"$extra}"
    )
  fi

  local row combo desc payload state
  for row in "${rows[@]}"; do
    IFS=$'\t' read -r combo desc payload <<<"$row"
    state=$(classify "$(combo_modmask "$combo")" "${combo##* }" "$desc")
    case $state in
      ours) if (( DRY_RUN )); then log "$combo is already ours"; fi ;;
      free) register bind "$combo" "$desc" "$payload" ;;
      stock) register takeover "$combo" "$desc" "$payload" ;;
      foreign)
        if (( force )); then register takeover "$combo" "$desc" "$payload"
        else log "leaving your own bind on $combo alone"; fi ;;
      *) die "internal error: could not classify $combo" ;;
    esac
  done
  return 0
}

main "$@"
