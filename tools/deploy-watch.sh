#!/usr/bin/env bash
# Build a release .prg and sideload it to a Garmin watch over MTP (Linux).
#
# Linux counterpart to Deploy-Watch.ps1. Same round trip: stamp -> release
# build -> pull logs -> clear logs -> copy .prg + .prg.debug.xml -> recreate
# the empty log stub. Every copy is size-checked afterwards.
#
# The watch mounts as MTP via gvfs (File Manager / gio), not a block device.
# Plug it in, unlock it, and wait until it appears under /run/user/$UID/gvfs/
# before running this.
#
# Usage:
#   ./tools/deploy-watch.sh
#   ./tools/deploy-watch.sh --target fr265
#   ./tools/deploy-watch.sh --no-build
#   ./tools/deploy-watch.sh --pull-only
#   ./tools/deploy-watch.sh --pull-only --keep-logs

set -euo pipefail

APP_NAME='GarminPocketCasts'
TARGET='fenix7x'
DEVICE_PATTERN='fenix|garmin|forerunner'
DEVELOPER_KEY=''
TIMEOUT_SEC=90
NO_BUILD=0
PULL_ONLY=0
KEEP_LOGS=0

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_ROOT="$REPO_ROOT/watch"
RELEASE_DIR="$APP_ROOT/bin/release"
LOG_PULL_ROOT="$REPO_ROOT/logs"
# Garmin's Linux layout matches macOS-style home path, not XDG.
CIQ_DIR="${GARMIN_CONNECTIQ_DIR:-$HOME/.Garmin/ConnectIQ}"

# Status lines go to stderr so $(find_*) only captures paths on stdout.
step() { printf '==> %s\n' "$*" >&2; }
ok()   { printf '    %s\n' "$*" >&2; }
warn() { printf '    warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \?//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-build)       NO_BUILD=1; shift ;;
    --pull-only)      PULL_ONLY=1; shift ;;
    --keep-logs)      KEEP_LOGS=1; shift ;;
    --app-name)       APP_NAME="$2"; shift 2 ;;
    --target)         TARGET="$2"; shift 2 ;;
    --device-pattern) DEVICE_PATTERN="$2"; shift 2 ;;
    --developer-key)  DEVELOPER_KEY="$2"; shift 2 ;;
    --timeout)        TIMEOUT_SEC="$2"; shift 2 ;;
    -h|--help)        usage 0 ;;
    *)                die "unknown argument: $1 (try --help)" ;;
  esac
done

# ---------------------------------------------------------------- build ------

set_build_stamp() {
  local path="$APP_ROOT/source/BuildInfo.mc"
  local stamp
  stamp="$(date +%y%m%d-%H%M%S)"
  [[ -f "$path" ]] || die "Missing $path"
  if ! grep -q 'const STAMP = "' "$path"; then
    die "Could not find 'const STAMP = ...' in $path"
  fi
  sed -i "s/const STAMP = \"[^\"]*\"/const STAMP = \"$stamp\"/" "$path"
  ok "build stamp $stamp"
}

resolve_developer_key() {
  local candidates=()
  [[ -n "$DEVELOPER_KEY" ]] && candidates+=("$DEVELOPER_KEY")
  [[ -n "${GARMIN_DEVELOPER_KEY:-}" ]] && candidates+=("$GARMIN_DEVELOPER_KEY")
  candidates+=("$CIQ_DIR/developer_key")

  local c
  for c in "${candidates[@]}"; do
    [[ -n "$c" && -f "$c" ]] && { printf '%s\n' "$c"; return 0; }
  done
  if [[ -n "$DEVELOPER_KEY" ]]; then
    die "Developer key not found at $DEVELOPER_KEY"
  fi
  die "No developer key. Set GARMIN_DEVELOPER_KEY to its path, or pass --developer-key <path>."
}

invoke_release_build() {
  local cfg="$CIQ_DIR/current-sdk.cfg"
  [[ -f "$cfg" ]] || die "No current-sdk.cfg at $cfg"
  local sdk_root sdk_bin monkeyc key prg
  sdk_root="$(tr -d '\r\n' < "$cfg")"
  sdk_bin="$sdk_root/bin"
  monkeyc="$sdk_bin/monkeyc"
  [[ -x "$monkeyc" ]] || die "monkeyc not found at $monkeyc"
  key="$(resolve_developer_key)"

  mkdir -p "$RELEASE_DIR"
  prg="$RELEASE_DIR/$APP_NAME.prg"

  set_build_stamp

  step "Building release $APP_NAME.prg for $TARGET"
  "$monkeyc" -o "$prg" -f "$APP_ROOT/monkey.jungle" \
    -y "$key" -d "$TARGET" -r -w -l 3
  ok "built $(wc -c < "$prg" | tr -d ' ') bytes"
}

# ------------------------------------------------------------------ MTP ------

gvfs_root() {
  printf '/run/user/%s/gvfs' "$(id -u)"
}

list_mtp_mounts() {
  local root
  root="$(gvfs_root)"
  [[ -d "$root" ]] || return 0
  # gvfs names look like: mtp:host=%5Busb%3A001%2C042%5D
  find "$root" -maxdepth 1 -mindepth 1 -type d \( -name 'mtp:*' -o -name 'gphoto2:*' \) 2>/dev/null \
    | sort
}

mount_label() {
  # Prefer a human name from gio; fall back to the directory basename.
  local mount="$1"
  local info name
  info="$(gio info "$mount" 2>/dev/null || true)"
  name="$(printf '%s\n' "$info" | sed -n 's/^.*standard::display-name: //p' | head -1)"
  if [[ -z "$name" ]]; then
    name="$(basename "$mount")"
  fi
  printf '%s\n' "$name"
}

find_mtp_device() {
  local mounts=()
  local m name matches=() fallbacks=()
  mapfile -t mounts < <(list_mtp_mounts)
  if [[ ${#mounts[@]} -eq 0 ]]; then
    die 'No MTP device mounted. Plug the watch in, unlock it, open it once in the file manager if needed, and wait for gvfs to mount it.'
  fi

  shopt -s nocasematch
  for m in "${mounts[@]}"; do
    name="$(mount_label "$m")"
    fallbacks+=("$name|$m")
    if [[ "$name" =~ $DEVICE_PATTERN ]] || [[ "$m" =~ $DEVICE_PATTERN ]]; then
      matches+=("$name|$m")
    fi
  done
  shopt -u nocasematch

  if [[ ${#matches[@]} -eq 1 ]]; then
    printf '%s\n' "${matches[0]#*|}"
    ok "found ${matches[0]%%|*}"
    return 0
  fi
  if [[ ${#matches[@]} -gt 1 ]]; then
    local names=()
    local entry
    for entry in "${matches[@]}"; do names+=("${entry%%|*}"); done
    die "Multiple devices match /$DEVICE_PATTERN/: ${names[*]}. Narrow it with --device-pattern."
  fi
  if [[ ${#mounts[@]} -eq 1 ]]; then
    warn "No name matched /$DEVICE_PATTERN/; using the only MTP mount: ${fallbacks[0]%%|*}"
    printf '%s\n' "${fallbacks[0]#*|}"
    return 0
  fi
  local all=()
  for entry in "${fallbacks[@]}"; do all+=("${entry%%|*}"); done
  die "No device matched /$DEVICE_PATTERN/. Candidates: ${all[*]}"
}

find_garmin_root() {
  local device_root="$1"
  local candidate

  if [[ -d "$device_root/GARMIN" ]]; then
    printf '%s\n' "$device_root/GARMIN"
    return 0
  fi

  # Common nesting: Internal Storage / Primary / Phone
  while IFS= read -r candidate; do
    if [[ -d "$candidate/GARMIN" ]]; then
      printf '%s\n' "$candidate/GARMIN"
      return 0
    fi
  done < <(find "$device_root" -maxdepth 2 -type d \( -iname 'internal storage' -o -iname 'primary' -o -iname 'phone' \) 2>/dev/null)

  # Last resort: any GARMIN dir a couple of levels down.
  candidate="$(find "$device_root" -maxdepth 3 -type d -name GARMIN 2>/dev/null | head -1 || true)"
  if [[ -n "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  die "No GARMIN folder under $device_root. Is the watch unlocked and finished mounting?"
}

# MTP on Linux is case-sensitive; Windows is not. Watches often expose
# GARMIN/Apps instead of GARMIN/APPS.
resolve_child_dir() {
  local parent="$1"
  local want="$2"
  local child
  if [[ -d "$parent/$want" ]]; then
    printf '%s\n' "$parent/$want"
    return 0
  fi
  while IFS= read -r child; do
    printf '%s\n' "$child"
    return 0
  done < <(find "$parent" -maxdepth 1 -type d -iname "$want" 2>/dev/null)
  return 1
}

ensure_dir() {
  local path="$1"
  if [[ -d "$path" ]]; then
    return 0
  fi
  mkdir -p "$path" 2>/dev/null || gio mkdir -p "$path" 2>/dev/null \
    || die "Could not create folder '$path' on the device (firmware may forbid it)."
}

wait_for_size() {
  local path="$1"
  local expect="$2"
  local deadline name size
  name="$(basename "$path")"
  deadline=$((SECONDS + TIMEOUT_SEC))
  while (( SECONDS < deadline )); do
    if [[ -e "$path" ]]; then
      size="$(stat -c '%s' "$path" 2>/dev/null || echo '')"
      if [[ -z "$size" ]]; then
        warn "$name: present, but could not read size"
        return 0
      fi
      if [[ "$size" == "$expect" ]]; then
        ok "$name -> $size bytes verified"
        return 0
      fi
    fi
    sleep 0.3
  done
  die "Timed out copying $name to the device (waited ${TIMEOUT_SEC}s)."
}

remove_device_file() {
  local path="$1"
  [[ -e "$path" ]] || return 1
  rm -f "$path" 2>/dev/null || gio remove "$path" 2>/dev/null || return 1
  local deadline=$((SECONDS + 20))
  while (( SECONDS < deadline )); do
    [[ -e "$path" ]] || return 0
    sleep 0.25
  done
  die "Deleted '$(basename "$path")' without error, but it is still listed on the device."
}

copy_to_device() {
  local dest_dir="$1"
  local local_path="$2"
  local name dest expect
  name="$(basename "$local_path")"
  dest="$dest_dir/$name"
  expect="$(stat -c '%s' "$local_path")"

  remove_device_file "$dest" || true
  # Prefer plain cp when gvfs exposes a filesystem path; fall back to gio.
  if ! cp -f "$local_path" "$dest" 2>/dev/null; then
    gio copy "$local_path" "$dest" || die "Failed copying $name to the device"
  fi
  wait_for_size "$dest" "$expect"
}

copy_from_device() {
  local src_dir="$1"
  local name="$2"
  local dest_dir="$3"
  local src="$src_dir/$name"
  local target="$dest_dir/$name"
  [[ -e "$src" ]] || return 1

  mkdir -p "$dest_dir"
  if ! cp -f "$src" "$target" 2>/dev/null; then
    gio copy "$src" "$target" || die "Timed out / failed pulling $name off the device."
  fi

  local deadline=$((SECONDS + TIMEOUT_SEC))
  while (( SECONDS < deadline )); do
    if [[ -f "$target" ]]; then
      ok "pulled $name ($(stat -c '%s' "$target") bytes)"
      return 0
    fi
    sleep 0.3
  done
  die "Timed out pulling $name off the device."
}

clear_device_logs() {
  local logs_folder="$1"
  local n stub_dir stub
  step 'Clearing device logs'
  for n in "$APP_NAME.TXT" "$APP_NAME.BAK" 'CIQ_LOG.YML' 'CIQ_LOG.BAK'; do
    if remove_device_file "$logs_folder/$n"; then
      ok "deleted $n"
    fi
  done

  # Without an empty stub named after the .prg, System.println is discarded.
  step 'Recreating the log stub'
  stub_dir="${XDG_CACHE_HOME:-$HOME/.cache}/garmin-connectiq"
  mkdir -p "$stub_dir"
  stub="$stub_dir/$APP_NAME.TXT"
  : > "$stub"
  copy_to_device "$logs_folder" "$stub"
  rm -f "$stub"
}

# ----------------------------------------------------------------- main ------

command -v gio >/dev/null 2>&1 || die 'gio not found (install glib2 / gvfs).'

if [[ "$NO_BUILD" -eq 0 && "$PULL_ONLY" -eq 0 ]]; then
  invoke_release_build
fi

PRG_LOCAL="$RELEASE_DIR/$APP_NAME.prg"
SYM_LOCAL="$RELEASE_DIR/$APP_NAME.prg.debug.xml"
if [[ "$PULL_ONLY" -eq 0 ]]; then
  [[ -f "$PRG_LOCAL" ]] || die "Missing build output: $PRG_LOCAL (drop --no-build?)"
  [[ -f "$SYM_LOCAL" ]] || die "Missing build output: $SYM_LOCAL (drop --no-build?)"
fi

step 'Locating the watch'
WATCH_ROOT="$(find_mtp_device)"
GARMIN="$(find_garmin_root "$WATCH_ROOT")"
APPS="$(resolve_child_dir "$GARMIN" APPS || true)"
[[ -n "$APPS" && -d "$APPS" ]] || die 'GARMIN/APPS (or Apps) not found on the device.'
LOGS="$(resolve_child_dir "$APPS" LOGS || true)"
if [[ -z "${LOGS:-}" || ! -d "$LOGS" ]]; then
  LOGS="$APPS/LOGS"
  ensure_dir "$LOGS"
fi
DEBUG="$(resolve_child_dir "$GARMIN" Debug || true)"
if [[ -z "${DEBUG:-}" || ! -d "$DEBUG" ]]; then
  DEBUG="$GARMIN/Debug"
fi

WATCH_NAME="$(mount_label "$WATCH_ROOT")"
SLUG="$(printf '%s' "$WATCH_NAME" | sed -E 's/[^A-Za-z0-9]+/-/g; s/^-|-$//g')"
STAMP="$(date +%Y-%m-%d_%H%M%S)"
[[ -n "$SLUG" ]] && STAMP="${STAMP}_$SLUG"
PULL_DIR="$LOG_PULL_ROOT/$STAMP"

step "Pulling logs -> logs/$STAMP"
PULLED=0
for n in "$APP_NAME.TXT" "$APP_NAME.BAK" 'CIQ_LOG.YML' 'CIQ_LOG.BAK'; do
  if copy_from_device "$LOGS" "$n" "$PULL_DIR"; then
    PULLED=$((PULLED + 1))
  fi
done
if [[ -d "$DEBUG" ]]; then
  for n in 'ERR_LOG.txt' 'ERR_LOG.BAK'; do
    if copy_from_device "$DEBUG" "$n" "$PULL_DIR"; then
      PULLED=$((PULLED + 1))
    fi
  done
fi
if [[ "$PULLED" -eq 0 ]]; then
  warn 'no logs on the device'
fi

if [[ "$PULL_ONLY" -eq 1 ]]; then
  if [[ "$KEEP_LOGS" -eq 0 ]]; then
    clear_device_logs "$LOGS"
  fi
  printf '\nLogs in: %s\n' "$PULL_DIR"
  if [[ "$KEEP_LOGS" -eq 0 ]]; then
    printf 'Device logs cleared.\n'
  fi
  exit 0
fi

if [[ "$KEEP_LOGS" -eq 0 ]]; then
  clear_device_logs "$LOGS"
fi

step 'Copying app to GARMIN/APPS'
copy_to_device "$APPS" "$PRG_LOCAL"

step 'Copying symbols to GARMIN/Debug'
ensure_dir "$DEBUG"
copy_to_device "$DEBUG" "$SYM_LOCAL"

STAMP_NOW='unknown'
BI_PATH="$APP_ROOT/source/BuildInfo.mc"
if [[ -f "$BI_PATH" ]]; then
  STAMP_NOW="$(sed -n 's/.*const STAMP = "\([^"]*\)";.*/\1/p' "$BI_PATH" | head -1)"
  [[ -n "$STAMP_NOW" ]] || STAMP_NOW='unknown'
fi

printf '\n'
printf 'Deployed build %s\n' "$STAMP_NOW"
printf 'Now: unplug the watch and open the app.\n'
printf "Confirm on the watch: the Settings menu's last row should read Build %s.\n" "$STAMP_NOW"
printf 'If it names an older build, restart the watch by hand - a new .prg over a\n'
printf 'running one is not always picked up, and nothing over USB can trigger a restart.\n'
printf 'Afterwards:  ./tools/deploy-watch.sh --pull-only\n'
