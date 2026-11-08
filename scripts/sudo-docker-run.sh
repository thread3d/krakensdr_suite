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

# The storage driver has to be configured BEFORE the daemon is started, not after:
# the reason it will not start is that its default (overlay2) needs kernel
# overlayfs, which this host may not have. Configuring it afterwards can never
# help, because the script has already exited.
apply_storage_driver() {
  mkdir -p /etc/docker
  [ -f /etc/docker/daemon.json ] && cp -n /etc/docker/daemon.json "/etc/docker/daemon.json.bak-$STAMP"
  python3 - "$STORAGE_DRIVER" <<'PYEMBED'
import json, os, sys
p = "/etc/docker/daemon.json"
d = {}
if os.path.exists(p):
    try:
        d = json.load(open(p))
    except Exception:
        d = {}
d["storage-driver"] = sys.argv[1]
json.dump(d, open(p, "w"), indent=4)
print("  daemon.json:", json.dumps(d))
PYEMBED
  ok "daemon.json requests storage-driver=$STORAGE_DRIVER"
}

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

if [ -n "$STORAGE_DRIVER" ]; then
  cur=""
  docker info >/dev/null 2>&1 && cur=$(docker info 2>/dev/null | awk -F': ' '/^ Storage Driver/{print $2}')
  if [ "$cur" != "$STORAGE_DRIVER" ]; then
    apply_storage_driver
    # Docker will not reuse a /var/lib/docker initialised by another driver.
    # It has never started successfully here, so anything present is stale -
    # move it aside rather than delete, and say where it went.
    if [ -d /var/lib/docker ] && [ -n "$(ls -A /var/lib/docker 2>/dev/null)" ]; then
      warn "moving /var/lib/docker aside (it belongs to another driver)"
      mv /var/lib/docker "/var/lib/docker.bak-$STAMP" && ok "kept at /var/lib/docker.bak-$STAMP"
    fi
    systemctl stop docker >/dev/null 2>&1
    if start_daemon; then
      ok "daemon started with $STORAGE_DRIVER"
    else
      bad "daemon will not start with $STORAGE_DRIVER"
      journalctl -u docker --no-pager 2>/dev/null | grep -iE "level=error" | tail -4 | sed 's/^/     /'
      exit 1
    fi
  fi
fi

if docker info >/dev/null 2>&1; then
  ok "daemon reachable"
else
  warn "daemon not reachable - trying to start it"
  if start_daemon; then
    ok "daemon started"
  else
    bad "dockerd will not start"
    echo "  --- last dockerd errors ---"
    journalctl -u docker --no-pager 2>/dev/null | grep -iE "level=error|failed to start daemon" | tail -5 | sed 's/^/     /'

    if ! grep -qw overlay /proc/filesystems 2>/dev/null; then
      bad "this kernel has no overlayfs, so docker's default overlay2 driver cannot work"
      echo "  running kernel   : $(uname -r)"
      echo "  module dirs      : $(ls /lib/modules 2>/dev/null | tr '\n' ' ')"
      echo "  .ko for running  : $(find "/lib/modules/$(uname -r)" -name '*.ko*' 2>/dev/null | wc -l)"
      echo "  /boot/Image is   : $(strings /boot/Image 2>/dev/null | grep -m1 -oE 'Linux version [0-9.]+-tegra' | sed 's/Linux version //')"
      echo
      info "If /boot/Image is a NEWER kernel than the one running, the box booted an old"
      info "kernel whose modules are not installed: a reboot fixes it and brings overlayfs"
      info "(and so overlay2) back."
      info "Otherwise retry with the vfs driver, which needs no kernel support:"
      info "  sudo STORAGE_DRIVER=vfs $0 $*"
    fi
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
    info "first build compiles everything; this can take 10+ minutes"
    JOBS="$JOBS" WHISPER="$WHISPER" docker compose build > "$OUT/build.log" 2>&1
    build_rc=$?
    grep -E "^#[0-9]+ |DONE|ERROR|CANCELED" "$OUT/build.log" | tail -20 | sed 's/^/  /'
    if [ "$build_rc" -eq 0 ]; then
      ok "image built"
    else
      bad "build failed (exit $build_rc) — see build.log"
      tail -30 "$OUT/build.log" | sed 's/^/     /'
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
