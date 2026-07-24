#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HDR="$ROOT/SheepShaver/src/gfxaccel/include/accel_logging.h"
SCHEME="$ROOT/SheepShaver/src/MacOSX/PocketShaver.xcodeproj/xcshareddata/xcschemes/PocketShaver.xcscheme"
SUBSYS_ALL="gl rave dsp nqd comp"

die(){ echo "gfxlog: $*" >&2; exit 1; }
[ -f "$HDR" ] || die "header not found: $HDR"
[ -f "$SCHEME" ] || die "scheme not found: $SCHEME"

flag_get(){ grep -E '^#define ACCEL_LOGGING_ENABLED ' "$HDR" | awk '{print $3}'; }
flag_set(){ # $1 = 0|1
  /usr/bin/sed -i '' -E "s/^#define ACCEL_LOGGING_ENABLED .*/#define ACCEL_LOGGING_ENABLED $1/" "$HDR"
}

# env_set KEY VALUE  (VALUE empty string => remove the variable)
env_set(){
  KEY="$1" VAL="${2-}" SCHEME="$SCHEME" /usr/bin/python3 - <<'PY'
import os, xml.etree.ElementTree as ET
key, val, path = os.environ["KEY"], os.environ["VAL"], os.environ["SCHEME"]
tree = ET.parse(path); root = tree.getroot()
launch = root.find("LaunchAction")
if launch is None: raise SystemExit("gfxlog: scheme has no LaunchAction")
env = launch.find("EnvironmentVariables")
if env is None:
    env = ET.SubElement(launch, "EnvironmentVariables")
existing = {e.get("key"): e for e in env.findall("EnvironmentVariable")}
if val == "":
    if key in existing: env.remove(existing[key])
elif key in existing:
    existing[key].set("value", val); existing[key].set("isEnabled", "YES")
else:
    e = ET.SubElement(env, "EnvironmentVariable")
    e.set("key", key); e.set("value", val); e.set("isEnabled", "YES")
tree.write(path, encoding="UTF-8", xml_declaration=True)
PY
}
env_get(){
  KEY="$1" SCHEME="$SCHEME" /usr/bin/python3 - <<'PY'
import os, xml.etree.ElementTree as ET
key, path = os.environ["KEY"], os.environ["SCHEME"]
env = ET.parse(path).getroot().find("LaunchAction/EnvironmentVariables")
val = ""
if env is not None:
    for e in env.findall("EnvironmentVariable"):
        if e.get("key") == key and e.get("isEnabled","YES") == "YES":
            val = e.get("value","")
print(val)
PY
}

cmd_status(){
  echo "compile flag : ACCEL_LOGGING_ENABLED=$(flag_get)  ($([ "$(flag_get)" = 1 ] && echo 'compiled in' || echo 'stripped'))"
  echo "GFXACCEL_LOG         = $(env_get GFXACCEL_LOG)"
  echo "GFXACCEL_LOG_VERBOSE = $(env_get GFXACCEL_LOG_VERBOSE)"
  echo "view logs    : tools/gfxlog.sh tail"
}

cmd_off(){ flag_set 0; echo "logging OFF (stripped). Rebuild to take effect."; }

cmd_on(){ # remaining args: subsystem tokens and/or -v   (string accumulator = bash 3.2 safe)
  local subs="" verbose=0 a
  for a in "$@"; do
    case "$a" in
      -v|--verbose) verbose=1 ;;
      gl|rave|dsp|nqd|comp) subs="${subs:+$subs,}$a" ;;
      *) die "unknown subsystem '$a' (want: $SUBSYS_ALL, or -v)";;
    esac
  done
  flag_set 1
  [ -n "$subs" ] || subs="all"
  env_set GFXACCEL_LOG "$subs"
  env_set GFXACCEL_LOG_VERBOSE "$([ "$verbose" = 1 ] && echo 1 || echo 0)"
  echo "logging ON  -> GFXACCEL_LOG=$(env_get GFXACCEL_LOG) VERBOSE=$(env_get GFXACCEL_LOG_VERBOSE). Rebuild to take effect."
}

cmd_set(){ # change subsystems only (no flag change)
  [ "$(flag_get)" = 1 ] || echo "note: compile flag is 0 (stripped) — run 'gfxlog on' + rebuild first." >&2
  local subs="" a
  for a in "$@"; do case "$a" in gl|rave|dsp|nqd|comp) subs="${subs:+$subs,}$a";; all) subs="all";; *) die "unknown subsystem '$a'";; esac; done
  [ -n "$subs" ] || die "usage: gfxlog set <gl|rave|dsp|nqd|comp|all> ..."
  env_set GFXACCEL_LOG "$subs"
  echo "GFXACCEL_LOG=$(env_get GFXACCEL_LOG) (relaunch, no rebuild needed)"
}

cmd_verbose(){ case "${1-}" in
  on)  env_set GFXACCEL_LOG_VERBOSE 1; echo "verbose ON (relaunch)";;
  off) env_set GFXACCEL_LOG_VERBOSE 0; echo "verbose OFF (relaunch)";;
  *) die "usage: gfxlog verbose on|off";; esac; }

cmd_tail(){
  local sel; sel="$(env_get GFXACCEL_LOG)"; [ -n "$sel" ] || sel="all"
  local pred='subsystem BEGINSWITH "com.pocketshaver"'
  echo "# streaming: $pred  (selected: $sel)" >&2
  if xcrun simctl list devices booted 2>/dev/null | grep -q Booted; then
    xcrun simctl spawn booted log stream --level debug --predicate "$pred"
  else
    log stream --level debug --predicate "$pred"
  fi
}

case "${1-status}" in
  status) cmd_status ;;
  off) cmd_off ;;
  on) shift; cmd_on "$@" ;;
  set|only) shift; cmd_set "$@" ;;
  verbose) shift; cmd_verbose "$@" ;;
  tail) cmd_tail ;;
  *) die "usage: gfxlog {status|off|on [gl rave dsp nqd comp] [-v]|set <subs>|verbose on|off|tail}";;
esac
