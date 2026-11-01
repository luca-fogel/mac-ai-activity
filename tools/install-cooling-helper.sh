#!/bin/bash
#
# Installs (or removes) aithermald — the privileged half of fan control.
#
# Deliberately a separate, explicit, interactive step. The app is read-only
# until this runs, and the only capability this adds is writing two SMC keys.
#
#   sudo ./tools/install-cooling-helper.sh            install and start
#   sudo ./tools/install-cooling-helper.sh --uninstall stop and remove
#   sudo ./tools/install-cooling-helper.sh --selftest  prove the write path only
#
set -euo pipefail

LABEL="com.foggylulu.aithermald"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
HELPER_DIR="/Library/PrivilegedHelperTools"
BIN="$HELPER_DIR/$LABEL"
SOCK="/var/run/aithermald.sock"
LOG="/var/log/aithermald.log"
CEILING="${AITHERMALD_CEILING:-95}"

repo="$(cd "$(dirname "$0")/.." && pwd)"

die() { echo "error: $*" >&2; exit 1; }

. "$repo/tools/helper-paths.sh"

[[ "$(id -u)" == "0" ]] || die "must run as root — SMC writes are privileged.
  try: sudo $0 ${1:-}"

# The uid that will be allowed to command the fans. Everything else is refused
# by the daemon itself, not merely by socket permissions.
OWNER_UID="${SUDO_UID:-0}"
[[ "$OWNER_UID" != "0" ]] || die "run this with sudo from your own account, not as root directly —
  the daemon needs to know which uid may command it"

build_binary() {
  local src="$repo/.build/release/aithermald"
  echo "building aithermald (release)..." >&2
  # Always rebuild incrementally so an upgrade cannot reuse an older binary.
  # Build as the invoking user; do not leave root-owned build artefacts.
  sudo -H -u "#$OWNER_UID" \
    swift build -c release --product aithermald --package-path "$repo" >/dev/null
  [[ -x "$src" ]] || die "build produced no binary at $src"
  echo "$src"
}

case "${1:-}" in
--uninstall)
  prepare_helper_directory
  # Install a fresh copy from this checkout rather than executing the old
  # /usr/local/libexec path, whose ancestors may be writable by another user.
  src="$(build_binary)"
  /usr/bin/install -o root -g wheel -m 0755 "$src" "$BIN"
  echo "stopping ${LABEL}..."
  launchctl bootout "system/${LABEL}" 2>/dev/null || true
  # Belt and braces: if the daemon was SIGKILLed, the SMC is still holding
  # whatever rpm it was last told, so hand the fans back explicitly.
  [[ -x "$BIN" ]] && "$BIN" --release || true
  rm -f "$PLIST" "$BIN" "$SOCK"
  echo "removed. Fans are back on the SMC's own control loop."
  exit 0
  ;;
--selftest)
  prepare_helper_directory
  src="$(build_binary)"
  /usr/bin/install -o root -g wheel -m 0755 "$src" "$BIN"
  exec "$BIN" --selftest --ceiling "$CEILING"
  ;;
"")
  ;;
*)
  die "unknown option: $1"
  ;;
esac

src="$(build_binary)"
prepare_helper_directory

echo "installing $BIN"
/usr/bin/install -o root -g wheel -m 0755 "$src" "$BIN"

echo "writing $PLIST"
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>                <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${BIN}</string>
        <string>--serve</string>
        <string>--allow-uid</string>
        <string>${OWNER_UID}</string>
        <string>--ceiling</string>
        <string>${CEILING}</string>
    </array>
    <key>RunAtLoad</key>            <true/>
    <!-- Restarting matters for safety, not for uptime: a fresh start writes
         mode 0 to every fan, which is what recovers from a crash that left one
         forced. -->
    <key>KeepAlive</key>            <true/>
    <key>ProcessType</key>          <string>Background</string>
    <key>StandardOutPath</key>      <string>${LOG}</string>
    <key>StandardErrorPath</key>    <string>${LOG}</string>
</dict>
</plist>
PLISTEOF
chown root:wheel "$PLIST"
chmod 0644 "$PLIST"

launchctl bootout "system/${LABEL}" 2>/dev/null || true
launchctl bootstrap system "$PLIST"

echo -n "waiting for socket"
for _ in $(seq 20); do
  [[ -S "$SOCK" ]] && break
  echo -n "."
  sleep 0.25
done
echo

if [[ -S "$SOCK" ]]; then
  ls -l "$SOCK"
  echo
  echo "installed. Open AI Activity → Cooling; the Control panel is now live."
  echo "  ceiling      ${CEILING} °C (release to automatic above this)"
  echo "  permitted    uid ${OWNER_UID} only"
  echo "  log          ${LOG}"
  echo "  remove with  sudo $0 --uninstall"
else
  echo "socket did not appear. Check ${LOG}:" >&2
  tail -20 "$LOG" 2>/dev/null >&2 || true
  exit 1
fi
