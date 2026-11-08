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
#   WAIT     seconds to wait after 'up' before reporting, default 120. heimdall
#            waits up to 45 s for the dongles, then calibrates; kraken_doa waits
#            up to 300 s for calibration before starting its UI anyway.
#
# The build is long the first time. Everything is logged to
#   <repo>/docker-logs/run-<timestamp>/
# chowned to the invoking user so it can be read without root.

set -u

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
ok "usbfs_memory_mb = $(cat /sys/module/usbcore/parameters/usbfs_memory_mb 2>/dev/null || echo '?')"

# ---------------------------------------------------------------------- actions
case "$ACTION" in
  build|up)
    step "build image (JOBS=$JOBS WHISPER=$WHISPER)"
    info "first build compiles everything; this can take 10+ minutes"
    if JOBS="$JOBS" WHISPER="$WHISPER" docker compose build 2>&1 | tee "$OUT/build.log"; then
      ok "image built"
    else
      bad "build failed — see build.log"
      tail -25 "$OUT/build.log" | sed 's/^/     /'
      exit 1
    fi
    [ "$ACTION" = "build" ] && { step "done"; ok "image built, not started"; exit 0; }

    step "start stack"
    docker compose up -d 2>&1 | tee -a "$OUT/build.log" | sed 's/^/  /'
    ok "containers started"
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
