#!/bin/bash
# sudo-docker-run.sh -- build and start the KrakenSDR V2 suite in Docker,
#                       and collect a log bundle the caller can read.
#
# Docker is upstream's supported path for this suite and sidesteps the host
# toolchain entirely: the image contains every build and runtime dependency,
# including the krakenrf librtlsdr fork, so none of the C++20 / gcc 9 / conda
# problems of a native build apply. Ubuntu 20.04's gcc 9.4 cannot compile this
# suite at all (no -std=c++20), so Docker is not just convenient here.
#
# WHY ROOT
# /var/run/docker.sock is root:docker and the invoking user is not in the docker
# group. Rather than usermod + log out and back in, this runs the docker
# commands under sudo and hands the logs back.
#
# USAGE
#   sudo ./scripts/sudo-docker-run.sh              # build (if needed) and start
#   sudo ./scripts/sudo-docker-run.sh build        # build only
#   sudo ./scripts/sudo-docker-run.sh status       # state + health + URLs
#   sudo ./scripts/sudo-docker-run.sh logs         # recent logs
#   sudo ./scripts/sudo-docker-run.sh down         # stop and remove containers
#
# ENVIRONMENT
#   JOBS     parallel compile jobs for the image build, default 6 (this host has
#            8 cores; each job wants ~1 GB RAM)
#   WHISPER  1 to build Voice-to-Text's whisper.cpp, default 0. It adds roughly
#            10 minutes to a first build and is not needed for DoA.
#   STORAGE_DRIVER  force a docker storage driver (e.g. vfs). Unset = daemon default.
#            overlay2 needs kernel overlayfs; vfs needs nothing but is much slower.
#   WAIT     seconds to wait after 'up' before reporting, default 120. heimdall
#            waits up to 45 s for the dongles, then calibrates; kraken_doa waits
#            up to 300 s for calibration before starting its UI anyway.
#
# The build is long the first time. Everything is logged to
#   <repo>/docker-logs/run-<timestamp>/
# chowned to the invoking user so it can be read without root.

set -u
set -o pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "This needs root (it drives the Docker socket)." >&2
  echo "  sudo $0 $*" >&2
  exit 1
fi

CALLER="${SUDO_USER:-}"
[ "$CALLER" = "root" ] && CALLER=""
CALLER_HOME="$HOME"
[ -n "$CALLER" ] && CALLER_HOME="/home/$CALLER"

JOBS="${JOBS:-6}"
WHISPER="${WHISPER:-0}"
WAIT="${WAIT:-120}"
STORAGE_DRIVER="${STORAGE_DRIVER:-}"

ROOT=$(cd "$(dirname "$0")/.." && pwd)
STAMP=$(date +%Y%m%d-%H%M%S)
OUT="$ROOT/docker-logs/run-$STAMP"
mkdir -p "$OUT"
LOG="$OUT/run.log"

step() { printf '\n\033[1m=== %s ===\033[0m\n' "$*"; }
ok()   { printf '\033[32m[ok]\033[0m %s\n' "$*"; }
bad()  { printf '\033[31m[FAIL]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[warn]\033[0m %s\n' "$*"; }
info() { printf '       %s\n' "$*"; }

exec > >(tee -a "$LOG") 2>&1

echo "KrakenSDR V2 suite — Docker run"
echo "  started : $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "  repo    : $ROOT"
echo "  bundle  : $OUT"
echo "  JOBS=$JOBS WHISPER=$WHISPER"

ACTION="${1:-up}"

# --------------------------------------------------------------- compose plugin
step "docker"
cd "$ROOT" || exit 1
docker --version 2>/dev/null | sed 's/^/  /'
if docker compose version >/dev/null 2>&1; then
  ok "compose: $(docker compose version 2>/dev/null)"
else
  warn "the docker compose plugin is not visible to root — installing it"
  # The caller may have it under their home; root's HOME is /root, so copy it to
  # a system path where the docker CLI finds it for every user.
  mkdir -p /usr/local/lib/docker/cli-plugins
  SRC=""
  [ -x "$CALLER_HOME/.docker/cli-plugins/docker-compose" ] && SRC="$CALLER_HOME/.docker/cli-plugins/docker-compose"
  if [ -n "$SRC" ]; then
    cp -f "$SRC" /usr/local/lib/docker/cli-plugins/docker-compose && chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
    ok "copied compose plugin from $SRC"
  else
    curl -fsSL -o /usr/local/lib/docker/cli-plugins/docker-compose \
      https://github.com/docker/compose/releases/latest/download/docker-compose-linux-aarch64 \
      && chmod +x /usr/local/lib/docker/cli-plugins/docker-compose \
      && ok "downloaded compose plugin" \
      || { bad "could not obtain the compose plugin"; exit 1; }
  fi
  docker compose version >/dev/null 2>&1 || { bad "compose still unavailable"; exit 1; }
  ok "compose: $(docker compose version 2>/dev/null)"
fi

# If the kernel has no overlayfs and no driver was requested, choose vfs rather
# than failing: the default driver cannot possibly work here, so retrying it just
# produces the same error. This is what STORAGE_DRIVER=vfs did by hand, now
# automatic. Say so loudly - it is a real configuration change.
if [ -z "$STORAGE_DRIVER" ] && ! grep -qw overlay /proc/filesystems 2>/dev/null; then
  warn "this kernel has no overlayfs, so docker's default overlay2 driver cannot work"
  warn "falling back to the vfs storage driver automatically (slower; no kernel support needed)"
  info "to keep trying overlay2 instead, set STORAGE_DRIVER=overlay2 explicitly"
  info "a reboot onto the newer kernel (/boot/Image) would restore overlayfs and overlay2"
  STORAGE_DRIVER=vfs
fi

# -------------------------------------------------------------- docker daemon
step "docker daemon"

merge_daemon_json() {
  mkdir -p /etc/docker
  [ -f /etc/docker/daemon.json ] && cp -n /etc/docker/daemon.json "/etc/docker/daemon.json.bak-$STAMP"
  python3 - "$@" <<'PYEMBED'
import json, os, sys
p = "/etc/docker/daemon.json"
d = {}
if os.path.exists(p):
    try:
        d = json.load(open(p))
    except Exception:
        d = {}
for kv in sys.argv[1:]:
    k, v = kv.split("=", 1)
    d[k] = (v == "true") if v in ("true", "false") else v
json.dump(d, open(p, "w"), indent=4)
print("  daemon.json:", json.dumps(d))
PYEMBED
}

# Start the daemon and wait for it to answer. Reset the failure counter first:
# after three failed restarts systemd parks the unit in "start request repeated
# too quickly" and a plain 'systemctl start' can never recover from that.
start_daemon() {
  systemctl reset-failed docker >/dev/null 2>&1
  systemctl start docker >/dev/null 2>&1
  local i
  for i in $(seq 1 12); do
    docker info >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

# Only THIS attempt's journal lines - dumping the tail unfiltered showed errors
# from a previous run and sent me chasing the wrong thing entirely.
attempt_errors() {
  journalctl -u docker --since "$1" --no-pager 2>/dev/null \
    | grep -iE "level=error|failed to start daemon|level=warning.*modprobe" || true
}

if [ -n "$STORAGE_DRIVER" ]; then
  cur=""
  docker info >/dev/null 2>&1 && cur=$(docker info 2>/dev/null | awk -F': ' '/^ Storage Driver/{print $2}')
  if [ "$cur" != "$STORAGE_DRIVER" ]; then
    merge_daemon_json "storage-driver=$STORAGE_DRIVER"
    # Docker will not reuse a /var/lib/docker initialised by another driver.
    if [ -d /var/lib/docker ] && [ -n "$(ls -A /var/lib/docker 2>/dev/null)" ]; then
      warn "moving /var/lib/docker aside (it belongs to another driver)"
      mv /var/lib/docker "/var/lib/docker.bak-$STAMP" && ok "kept at /var/lib/docker.bak-$STAMP"
    fi
    systemctl stop docker >/dev/null 2>&1
  fi
fi

ATTEMPT_START="$(date '+%Y-%m-%d %H:%M:%S')"
if docker info >/dev/null 2>&1; then
  ok "daemon reachable"
elif start_daemon; then
  ok "daemon started"
else
  errs=$(attempt_errors "$ATTEMPT_START")

  # Docker's default bridge networking needs the kernel's netfilter modules. On a
  # kernel with no modules at all, 'iptables -t nat' cannot even list its tables,
  # so creating the DOCKER NAT chain fails and the daemon refuses to start. This
  # compose file uses network_mode: host for every service, so the bridge and its
  # NAT rules are never used - switching them off is safe here and unblocks the
  # daemon without a reboot.
  if printf '%s' "$errs" | grep -qiE "nat chain DOCKER|iptables table .?nat|Table does not exist"; then
    warn "docker's bridge/NAT networking needs kernel netfilter modules this kernel lacks"
    warn "this suite uses network_mode: host, so the bridge is never used - disabling it"
    merge_daemon_json "iptables=false" "bridge=none" || true
    ok "daemon.json now disables iptables and the default bridge"
    systemctl stop docker >/dev/null 2>&1
    ATTEMPT_START="$(date '+%Y-%m-%d %H:%M:%S')"
    if start_daemon; then
      ok "daemon started (host networking only)"
    else
      errs=$(attempt_errors "$ATTEMPT_START")
      bad "dockerd still will not start"
      printf '%s\n' "$errs" | tail -6 | sed 's/^/     /'
      exit 1
    fi
  else
    bad "dockerd will not start"
    echo "  --- this attempt's errors ---"
    printf '%s\n' "$errs" | tail -6 | sed 's/^/     /'

    if ! grep -qw overlay /proc/filesystems 2>/dev/null; then
      bad "this kernel has no overlayfs, so overlay2 cannot work"
    fi
    echo "  running kernel   : $(uname -r)"
    echo "  .ko for running  : $(find "/lib/modules/$(uname -r)" -name '*.ko*' 2>/dev/null | wc -l)"
    echo "  /boot/Image is   : $(strings /boot/Image 2>/dev/null | grep -m1 -oE 'Linux version [0-9.]+-tegra' | sed 's/Linux version //')"
    echo
    info "If /boot/Image is a NEWER kernel than the running one, the box booted an old"
    info "kernel whose modules are not installed. One reboot fixes every symptom at"
    info "once - overlayfs for the storage driver, and netfilter for the bridge."
    exit 1
  fi
fi

info "storage driver: $(docker info 2>/dev/null | awk -F': ' '/^ Storage Driver/{print $2}')"
if [ -n "$STORAGE_DRIVER" ]; then
  cur=$(docker info 2>/dev/null | awk -F': ' '/^ Storage Driver/{print $2}')
  if [ "$cur" = "$STORAGE_DRIVER" ]; then ok "using requested driver $STORAGE_DRIVER"
  else bad "daemon reports driver '$cur', not '$STORAGE_DRIVER'"; exit 1; fi
fi

# ------------------------------------------------------------------ preflight
step "preflight"
dongles=$(lsusb 2>/dev/null | grep -c "0bda:2838")
if [ "$dongles" -ge 5 ]; then ok "$dongles RTL2838 dongles on the USB bus"
else bad "only $dongles of 5 dongles present — heimdall waits up to 45 s then fails"; fi

if lsmod 2>/dev/null | grep -q "^dvb_usb_rtl28xxu"; then
  bad "dvb_usb_rtl28xxu is loaded and will claim the dongles"
  info "fix: sudo modprobe -r dvb_usb_rtl28xxu   (and blacklist it to persist)"
else
  ok "dvb_usb_rtl28xxu not loaded"
fi

# Only one program can own the dongles and these ports.
native=$(pgrep -c -x heimdall 2>/dev/null || true)
[ -z "$native" ] && native=0
for p in rtl_daq.out rebuffer.out decimate.out; do
  pgrep -x "$p" >/dev/null 2>&1 && native=$((native+1))
done
if [ "$native" -gt 0 ]; then
  bad "a native DAQ stack is running — it would fight the container for the dongles"
  info "stop it first (the heimdall_daq_fw scripts, or kill the stages)"
else
  ok "no native DAQ stack running"
fi
for port in 8070 8080 8081; do
  if ss -lnt 2>/dev/null | grep -q ":$port "; then
    warn "port $port is already in use"
  fi
done
# libusb caps total transfer buffers at 16 MB and five RTL2832U streams need more
# (the V1 DAQ failed with "Failed to submit transfer" until this was raised). The
# parameter resets on every boot, so set it here rather than remembering.
usbfs_now=$(cat /sys/module/usbcore/parameters/usbfs_memory_mb 2>/dev/null || echo '?')
if [ "$usbfs_now" = "0" ]; then
  ok "usbfs_memory_mb already 0 (unlimited)"
elif echo 0 > /sys/module/usbcore/parameters/usbfs_memory_mb 2>/dev/null; then
  ok "usbfs_memory_mb: $usbfs_now -> 0 (unlimited)"
else
  warn "could not raise usbfs_memory_mb (still $usbfs_now) — 5 dongles may hit libusb limits"
fi

# ---------------------------------------------------------------------- actions
case "$ACTION" in
  build|up)
    step "build image (JOBS=$JOBS WHISPER=$WHISPER)"
    info "first build compiles everything; this is the slow part"
    total_plugins=$(ls -d "$ROOT"/kraken_doa_v2/plugins/*/ 2>/dev/null | wc -l)
    : > "$OUT/build.log"
    JOBS="$JOBS" WHISPER="$WHISPER" docker compose build > "$OUT/build.log" 2>&1 &
    BUILD_PID=$!

    # Stream progress while it runs. Waiting silently for 20+ minutes gives no way
    # to tell "working" from "wedged", which is the worst part of a slow build.
    build_start=$(date +%s)
    last_state=""; last_print=0
    printf '  %-8s %-12s %-16s %s\n' "elapsed" "step" "plugins" "activity"
    while kill -0 "$BUILD_PID" 2>/dev/null; do
      cur_step=$(grep -oE "^Step [0-9]+/[0-9]+" "$OUT/build.log" 2>/dev/null | tail -1)
      plugins=$(grep -c "built plugin" "$OUT/build.log" 2>/dev/null || true)
      [ -z "$plugins" ] && plugins=0
      elapsed=$(( $(date +%s) - build_start ))
      # docker writes \r-carriage progress sequences; strip them or the columns jitter
      activity=$(grep -E "^(Compiling |built plugin |Linking |Build complete|Successfully|Removing intermediate)" \
                   "$OUT/build.log" 2>/dev/null | tail -1 | tr -d '\r' | cut -c1-58)
      state="${cur_step}|${plugins}"
      now=$(date +%s)
      # print on any change, and a heartbeat every 20 s so silence never looks like a hang
      if [ "$state" != "$last_state" ] || [ $((now - last_print)) -ge 20 ]; then
        printf '  %02d:%02d:%02d %-12s %-16s %s\n' \
          $((elapsed/3600)) $(( (elapsed%3600)/60 )) $((elapsed%60)) \
          "${cur_step:-starting}" "${plugins}/${total_plugins}" "$activity"
        last_state="$state"; last_print=$now
      fi
      sleep 3
    done
    wait "$BUILD_PID"; build_rc=$?

    if [ "$build_rc" -eq 0 ]; then
      ok "image built in $(( ($(date +%s) - build_start) / 60 )) min"
      info "build log: $OUT/build.log"
    else
      bad "build failed (exit $build_rc) after $(( ($(date +%s) - build_start) / 60 )) min"
      tail -30 "$OUT/build.log" | tr '\r' '\n' | sed 's/^/     /'
      exit 1
    fi
    [ "$ACTION" = "build" ] && { step "done"; ok "image built, not started"; exit 0; }

    step "start stack"
    if docker compose up -d >> "$OUT/build.log" 2>&1; then
      ok "containers started"
    else
      bad "'docker compose up' failed — see build.log"
      tail -20 "$OUT/build.log" | sed 's/^/     /'
      exit 1
    fi
    info "heimdall waits up to 45 s for the dongles, then calibrates;"
    info "kraken_doa waits up to 300 s for calibration before its UI starts anyway."
    info "waiting ${WAIT}s before reporting"
    sleep "$WAIT"
    ;;
  status|logs|down) : ;;
  *) bad "unknown action '$ACTION' (up|build|status|logs|down)"; exit 1 ;;
esac

# ---------------------------------------------------------------------- report
if [ "$ACTION" != "down" ]; then
  step "containers"
  docker compose ps 2>&1 | sed 's/^/  /' | tee "$OUT/ps.txt"

  step "health"
  for c in $(docker compose ps -q 2>/dev/null); do
    name=$(docker inspect --format '{{.Name}}' "$c" 2>/dev/null | sed 's|^/||')
    health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "$c" 2>/dev/null)
    state=$(docker inspect --format '{{.State.Status}}' "$c" 2>/dev/null)
    printf '  %-14s state=%-10s health=%s\n' "$name" "$state" "$health"
  done

  step "web endpoints"
  # heimdall UI is plain HTTP on 8070; the DoA UI is HTTPS (self-signed) on 8080.
  for url in "http://127.0.0.1:8070/" "http://127.0.0.1:8081/" ; do
    code=$(curl -sk -o /dev/null -m 8 -w '%{http_code}' "$url" 2>/dev/null)
    printf '  %-28s HTTP %s\n' "$url" "${code:-no-response}"
  done
  code=$(curl -sk -o /dev/null -m 8 -w '%{http_code}' "https://127.0.0.1:8080/" 2>/dev/null)
  printf '  %-28s HTTPS %s (self-signed)\n' "https://127.0.0.1:8080/" "${code:-no-response}"

  step "logs (errors only, as upstream defaults)"
  docker compose logs --no-color --tail 40 > "$OUT/compose.log" 2>&1
  sed 's/^/  /' "$OUT/compose.log" | tail -40

  docker compose ps -q 2>/dev/null | while read -r c; do
    n=$(docker inspect --format '{{.Name}}' "$c" 2>/dev/null | sed 's|^/||')
    docker logs --tail 200 "$c" > "$OUT/logs-$n.txt" 2>&1
  done
  info "per-container logs: $OUT/logs-*.txt"

  step "verdict"
  running=$(docker compose ps --status running -q 2>/dev/null | wc -l | tr -d ' ')
  if [ "$running" -ge 2 ]; then
    ok "$running container(s) running"
    info "heimdall UI : http://$(hostname -I 2>/dev/null | awk '{print $1}'):8070"
    info "DoA UI      : https://$(hostname -I 2>/dev/null | awk '{print $1}'):8080"
    info "DoA value   : http://$(hostname -I 2>/dev/null | awk '{print $1}'):8081"
    info "logs        : sudo docker compose logs -f   (in $ROOT)"
  else
    bad "only $running container(s) running — see logs above and $OUT/logs-*.txt"
  fi
else
  step "down"
  docker compose down 2>&1 | sed 's/^/  /'
  ok "stopped and removed"
fi

# ----------------------------------------------------------------------- bundle
if [ -n "$CALLER" ]; then
  chown -R "$CALLER":"$CALLER" "$ROOT/docker-logs" 2>/dev/null
fi
chmod -R a+rX "$ROOT/docker-logs" 2>/dev/null
step "bundle"
du -sh "$OUT" 2>/dev/null | sed 's/^/  /'
ok "logs: $OUT"
