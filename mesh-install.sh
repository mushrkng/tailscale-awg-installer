#!/bin/sh
# mesh-install.sh — install self-build AmneziaWG-Tailscale and join the grib headscale mesh.
#
# One-liner:
#   curl -fsSL <gated-url>/install.sh | sudo sh -s -- --authkey <KEY> --hostname <NAME> [--advertise-routes 192.168.X.0/24]
#
# Does: detect OS/arch -> download self-build binary (GitHub Release) -> sha256 verify
#       -> install /usr/local/bin -> set up daemon (systemd | root LaunchDaemon)
#       -> tailscale up against the mesh control plane -> apply AmneziaWG obfuscation
#       -> (macOS) install /etc/resolver/mesh.ts so *.mesh.ts resolves.
set -eu

# ---- defaults (overridable by flags / env) -------------------------------
LOGIN_SERVER="${LOGIN_SERVER:-https://hs.gribtunnel.com}"
RELEASE="${RELEASE:-v1.98.2-awg1}"
RELEASE_BASE="https://github.com/mushrkng/tailscale/releases/download/${RELEASE}"
AWG_PROFILE="${AWG_PROFILE:-}"     # pre-filled in the gated VPS copy; else --awg-profile or manual
AUTHKEY="${TS_AUTHKEY:-}"
HOSTNAME_ARG=""
ROUTES=""
DO_UNINSTALL=0
MAGICDNS_IP="100.100.100.100"

R='\033[31m' G='\033[32m' Y='\033[33m' N='\033[0m'
log()  { printf "${G}[mesh]${N} %s\n" "$1"; }
warn() { printf "${Y}[mesh]${N} %s\n" "$1" >&2; }
die()  { printf "${R}[mesh] ERROR:${N} %s\n" "$1" >&2; exit 1; }

# ---- args ----------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --authkey)          AUTHKEY="${2:-}"; shift 2 ;;
    --hostname)         HOSTNAME_ARG="${2:-}"; shift 2 ;;
    --advertise-routes) ROUTES="${2:-}"; shift 2 ;;
    --awg-profile)      AWG_PROFILE="${2:-}"; shift 2 ;;
    --login-server)     LOGIN_SERVER="${2:-}"; shift 2 ;;
    --release)          RELEASE="${2:-}"; RELEASE_BASE="https://github.com/mushrkng/tailscale/releases/download/${RELEASE}"; shift 2 ;;
    --uninstall)        DO_UNINSTALL=1; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown arg: $1" ;;
  esac
done

[ "$(id -u)" = 0 ] || die "run as root (use sudo)"

# ---- platform detection --------------------------------------------------
OS=$(uname -s); ARCH=$(uname -m)
case "$OS" in
  Linux)  PLAT=linux ;;
  Darwin) PLAT=darwin ;;
  *) die "unsupported OS: $OS" ;;
esac
case "$ARCH" in
  x86_64|amd64)   GOARCH=amd64 ;;
  arm64|aarch64)  GOARCH=arm64 ;;
  *) die "unsupported arch: $ARCH" ;;
esac
TARGET="${PLAT}-${GOARCH}"
case "$TARGET" in
  darwin-arm64|linux-amd64) : ;;
  *) die "no prebuilt binary for ${TARGET} yet (Phase-2 CI will add it). Rebuild the fork for this arch." ;;
esac

if [ "$PLAT" = darwin ]; then
  SOCK="/var/run/tailscaled.socket"
  PLIST="/Library/LaunchDaemons/com.tailscale.tailscaled.plist"
else
  SOCK="/run/tailscale/tailscaled.sock"
  UNIT="/etc/systemd/system/tailscaled.service"
fi

# ---- uninstall -----------------------------------------------------------
if [ "$DO_UNINSTALL" = 1 ]; then
  log "uninstalling..."
  if [ "$PLAT" = darwin ]; then
    launchctl bootout system "$PLIST" 2>/dev/null || true
    rm -f "$PLIST" /etc/resolver/mesh.ts
    dscacheutil -flushcache 2>/dev/null || true; killall -HUP mDNSResponder 2>/dev/null || true
  else
    systemctl disable --now tailscaled 2>/dev/null || true
    rm -f "$UNIT"; systemctl daemon-reload 2>/dev/null || true
  fi
  rm -f /usr/local/bin/tailscale /usr/local/bin/tailscaled
  log "removed binaries + daemon (state in /var/lib/tailscale kept; rm manually if desired)"
  exit 0
fi

sumcheck() { # $1=file $2=expected-hex
  if command -v sha256sum >/dev/null 2>&1; then a=$(sha256sum "$1" | awk '{print $1}')
  else a=$(shasum -a 256 "$1" | awk '{print $1}'); fi
  [ "$a" = "$2" ] || die "sha256 mismatch for $1 (expected $2, got $a)"
}

# ---- download + verify ---------------------------------------------------
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
log "fetching self-build ${RELEASE} for ${TARGET}..."
curl -fsSL "$RELEASE_BASE/SHA256SUMS"          -o "$TMP/SHA256SUMS"          || die "download SHA256SUMS failed"
curl -fsSL "$RELEASE_BASE/tailscale-$TARGET"   -o "$TMP/tailscale"           || die "download tailscale failed"
curl -fsSL "$RELEASE_BASE/tailscaled-$TARGET"  -o "$TMP/tailscaled"          || die "download tailscaled failed"

exp_ts=$(grep " tailscale-$TARGET\$"  "$TMP/SHA256SUMS" | awk '{print $1}')
exp_td=$(grep " tailscaled-$TARGET\$" "$TMP/SHA256SUMS" | awk '{print $1}')
[ -n "$exp_ts" ] && [ -n "$exp_td" ] || die "SHA256SUMS missing entries for $TARGET"
sumcheck "$TMP/tailscale"  "$exp_ts"
sumcheck "$TMP/tailscaled" "$exp_td"
log "sha256 verified OK"

# ---- install -------------------------------------------------------------
install -m 0755 "$TMP/tailscale"  /usr/local/bin/tailscale
install -m 0755 "$TMP/tailscaled" /usr/local/bin/tailscaled
mkdir -p /var/lib/tailscale
[ "$PLAT" = darwin ] && xattr -dr com.apple.quarantine /usr/local/bin/tailscale /usr/local/bin/tailscaled 2>/dev/null || true
log "installed: $(/usr/local/bin/tailscale version | head -1)"

# ---- daemon --------------------------------------------------------------
if [ "$PLAT" = darwin ]; then
  cat > "$PLIST" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.tailscale.tailscaled</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/local/bin/tailscaled</string>
    <string>--state=/var/lib/tailscale/tailscaled.state</string>
    <string>--socket=/var/run/tailscaled.socket</string>
    <string>--port=41641</string>
    <string>--tun=utun</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/var/log/tailscaled.log</string>
  <key>StandardErrorPath</key><string>/var/log/tailscaled.log</string>
</dict>
</plist>
EOF
  launchctl bootout system "$PLIST" 2>/dev/null || true
  launchctl bootstrap system "$PLIST"
else
  command -v systemctl >/dev/null 2>&1 || die "systemd required (no systemctl found)"
  cat > "$UNIT" <<'EOF'
[Unit]
Description=Tailscale (AmneziaWG self-build, grib mesh)
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=/usr/local/bin/tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/run/tailscale/tailscaled.sock --port=41641
RuntimeDirectory=tailscale
StateDirectory=tailscale
Restart=on-failure
RestartSec=5s
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now tailscaled
fi

# wait for daemon socket
i=0; while [ ! -S "$SOCK" ] && [ "$i" -lt 30 ]; do i=$((i+1)); sleep 1; done
[ -S "$SOCK" ] || warn "tailscaled socket not up after 30s — continuing anyway"

# ---- join ----------------------------------------------------------------
[ -n "$AUTHKEY" ] || die "no --authkey given. Create one in headplane (${LOGIN_SERVER}/admin) and re-run."
log "joining mesh as '${HOSTNAME_ARG:-$(hostname)}' ..."
UP="up --login-server $LOGIN_SERVER --auth-key $AUTHKEY --accept-dns=false"
[ -n "$HOSTNAME_ARG" ] && UP="$UP --hostname $HOSTNAME_ARG"
[ -n "$ROUTES" ]       && UP="$UP --advertise-routes=$ROUTES"
# shellcheck disable=SC2086
/usr/local/bin/tailscale $UP

# ---- AmneziaWG obfuscation ----------------------------------------------
if [ -n "$AWG_PROFILE" ]; then
  log "applying AmneziaWG profile..."
  /usr/local/bin/tailscale awg set "$AWG_PROFILE" < /dev/null
else
  log "no profile baked — trying 'awg sync' from an online peer..."
  if ! /usr/local/bin/tailscale awg sync < /dev/null 2>/dev/null; then
    warn "awg sync failed. Run manually:  sudo tailscale awg set '<TS_AWG_PROFILE>'  (from homelab.env)"
  fi
fi
# restart daemon so AWG params take effect
if [ "$PLAT" = darwin ]; then launchctl kickstart -k system/com.tailscale.tailscaled
else systemctl restart tailscaled; fi
sleep 2

# ---- macOS MagicDNS resolver (standalone tailscaled doesn't grab primary) -
if [ "$PLAT" = darwin ]; then
  mkdir -p /etc/resolver
  printf 'nameserver %s\n' "$MAGICDNS_IP" > /etc/resolver/mesh.ts
  dscacheutil -flushcache 2>/dev/null || true
  killall -HUP mDNSResponder 2>/dev/null || true
  log "installed /etc/resolver/mesh.ts (*.mesh.ts -> MagicDNS)"
fi

# ---- report --------------------------------------------------------------
echo
log "done. AWG: $(/usr/local/bin/tailscale awg get 2>/dev/null | tr '\n' ' ' | head -c 120)"
/usr/local/bin/tailscale status 2>/dev/null | head -10 || true
echo
log "manage nodes/keys/routes at ${LOGIN_SERVER}/admin"
