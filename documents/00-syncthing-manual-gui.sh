#!/bin/sh
# Name: Syncthing Manual GUI

VERSION="1.0.0"
BIN="/mnt/us/filemanagers/bin/syncthing"
CONF="/mnt/us/filemanagers/settings"
DATA="/var/local/syncthing-filemanagers"
STATE="/var/local/kindle-syncthing-service"
SERVICE="kindle-syncthing"
OUT="/mnt/us/documents/SYNCTHING-MANUAL-GUI-STATUS.txt"
LOG="$STATE/manual-gui.log"
PIDFILE="$STATE/manual-gui.pid"
IFACEFILE="$STATE/manual-gui.iface"

PATH="/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/bin"
export PATH
umask 077

exec >"$OUT" 2>&1

echo "Syncthing Manual GUI"
echo "VERSION=$VERSION"
date
echo

fail() {
    echo
    echo "RESULT=FAIL"
    echo "ERROR=$1"
    exit 1
}

get_iface() {
    if ip link show wlan0 >/dev/null 2>&1; then
        echo "wlan0"
        return 0
    fi

    ip route 2>/dev/null | awk '
        $1 == "default" {
            for (i = 1; i <= NF; i++) {
                if ($i == "dev" && (i + 1) <= NF) {
                    print $(i + 1)
                    exit
                }
            }
        }
    '
}

get_ipv4() {
    IFACE="$1"
    ip addr show "$IFACE" 2>/dev/null |
        awk '/inet / {print $2}' |
        cut -d/ -f1 |
        head -n 1
}

remove_rule() {
    IFACE="$1"
    PORT="$2"
    PROTO="$3"

    [ -n "$IFACE" ] || return 0
    while iptables -D INPUT -i "$IFACE" -p "$PROTO" --dport "$PORT" -j ACCEPT 2>/dev/null; do
        :
    done
}

remove_firewall() {
    IFACE=""
    [ -s "$IFACEFILE" ] && IFACE=$(cat "$IFACEFILE" 2>/dev/null)
    [ -n "$IFACE" ] || IFACE=$(get_iface)

    remove_rule "$IFACE" 8384 tcp
    remove_rule "$IFACE" 22000 tcp
    remove_rule "$IFACE" 22000 udp
    remove_rule "$IFACE" 21027 udp
    rm -f "$IFACEFILE"
}

open_firewall() {
    IFACE="$1"

    remove_rule "$IFACE" 8384 tcp
    remove_rule "$IFACE" 22000 tcp
    remove_rule "$IFACE" 22000 udp
    remove_rule "$IFACE" 21027 udp

    iptables -A INPUT -i "$IFACE" -p tcp --dport 8384 -j ACCEPT 2>/dev/null || return 1
    iptables -A INPUT -i "$IFACE" -p tcp --dport 22000 -j ACCEPT 2>/dev/null || return 1
    iptables -A INPUT -i "$IFACE" -p udp --dport 22000 -j ACCEPT 2>/dev/null || return 1
    iptables -A INPUT -i "$IFACE" -p udp --dport 21027 -j ACCEPT 2>/dev/null || return 1

    echo "$IFACE" > "$IFACEFILE"
    return 0
}

stop_pid() {
    P="$1"
    [ -n "$P" ] || return 0
    kill "$P" 2>/dev/null || return 0

    N=0
    while kill -0 "$P" 2>/dev/null && [ "$N" -lt 10 ]; do
        sleep 1
        N=$((N + 1))
    done

    kill -9 "$P" 2>/dev/null || true
}

pid_is_manual_syncthing() {
    P="$1"
    [ -n "$P" ] || return 1
    [ -r "/proc/$P/cmdline" ] || return 1

    CMDLINE=$(tr '\000' ' ' < "/proc/$P/cmdline" 2>/dev/null)
    printf '%s\n' "$CMDLINE" | grep -F -- "$BIN" >/dev/null 2>&1 || return 1
    printf '%s\n' "$CMDLINE" | grep -F -- "--gui-address=$IP:8384" >/dev/null 2>&1
}

stop_all_syncthing() {
    for P in $(pidof syncthing 2>/dev/null); do
        stop_pid "$P"
    done
}

[ "$(id -u)" = "0" ] || fail "root privileges are required"

for CMD in ip iptables nohup pidof status stop; do
    command -v "$CMD" >/dev/null 2>&1 || fail "required command is unavailable: $CMD"
done

[ -f "$BIN" ] || fail "Syncthing binary not found at $BIN"
chmod 0755 "$BIN" 2>/dev/null || true
[ -x "$BIN" ] || fail "Syncthing binary is not executable"

for FILE in "$CONF/config.xml" "$CONF/cert.pem" "$CONF/key.pem"; do
    [ -s "$FILE" ] || fail "missing required Syncthing file: $FILE"
done

mkdir -p "$DATA" "$STATE" || fail "unable to create runtime directories"
chmod 0700 "$DATA" "$STATE" 2>/dev/null || true

DEVICE_ID=$("$BIN" --config="$CONF" --data="$DATA" device-id 2>/dev/null | tail -n 1)
[ -n "$DEVICE_ID" ] || fail "unable to read Syncthing device ID"
echo "DEVICE_ID=$DEVICE_ID"

GUI_XML=$(awk '
    /<gui[ >]/ { inside = 1 }
    inside { print }
    /<\/gui>/ { exit }
' "$CONF/config.xml")

GUI_ENABLED=$(printf '%s\n' "$GUI_XML" |
    sed -n 's/.*<gui[^>]*enabled="\([^"]*\)".*/\1/p' |
    head -n 1)
GUI_TLS=$(printf '%s\n' "$GUI_XML" |
    sed -n 's/.*<gui[^>]*tls="\([^"]*\)".*/\1/p' |
    head -n 1)
GUI_USER=$(printf '%s\n' "$GUI_XML" |
    sed -n 's|.*<user>\(.*\)</user>.*|\1|p' |
    head -n 1)
GUI_PASSWORD=$(printf '%s\n' "$GUI_XML" |
    sed -n 's|.*<password>\(.*\)</password>.*|\1|p' |
    head -n 1)

[ "$GUI_ENABLED" != "false" ] || fail "Syncthing GUI is disabled in config.xml"
[ -n "$GUI_USER" ] || fail "GUI username is not configured; LAN GUI exposure was refused"
[ -n "$GUI_PASSWORD" ] || fail "GUI password is not configured; LAN GUI exposure was refused"

IFACE=$(get_iface)
[ -n "$IFACE" ] || fail "no active Kindle network interface was found"

IP=$(get_ipv4 "$IFACE")
[ -n "$IP" ] || fail "no IPv4 address is available; connect Wi-Fi and try again"

SCHEME="http"
[ "$GUI_TLS" = "true" ] && SCHEME="https"
GUI_URL="$SCHEME://$IP:8384"

if [ -s "$PIDFILE" ]; then
    P=$(cat "$PIDFILE" 2>/dev/null)
    if [ -n "$P" ] && kill -0 "$P" 2>/dev/null && pid_is_manual_syncthing "$P"; then
        echo "MODE=manual-gui"
        echo "PID=$P"
        echo "GUI=$GUI_URL"
        echo "RESULT=ALREADY_RUNNING"
        exit 0
    fi
    rm -f "$PIDFILE"
fi

stop "$SERVICE" >/dev/null 2>&1 || true
stop syncthing-news >/dev/null 2>&1 || true
stop syncthing-watchdog >/dev/null 2>&1 || true
stop syncthing >/dev/null 2>&1 || true
sleep 2
stop_all_syncthing

remove_firewall
open_firewall "$IFACE" || fail "unable to configure Kindle firewall"

: > "$LOG"

HOME="$STATE"
TMPDIR="/tmp"
USER="root"
LOGNAME="root"
export HOME TMPDIR USER LOGNAME

nohup "$BIN" \
    --config="$CONF" \
    --data="$DATA" \
    serve \
    --no-browser \
    --no-upgrade \
    --gui-address="$IP:8384" \
    --log-file="$DATA/syncthing.log" \
    --log-max-size=1048576 \
    --log-max-old-files=2 \
    >>"$LOG" 2>&1 &

P=$!
echo "$P" > "$PIDFILE"
sleep 8

if ! kill -0 "$P" 2>/dev/null; then
    rm -f "$PIDFILE"
    remove_firewall
    echo
    echo "Syncthing exited during startup."
    tail -n 100 "$LOG" 2>/dev/null || true
    fail "manual GUI startup failed"
fi

echo "MODE=manual-gui"
echo "PID=$P"
echo "GUI=$GUI_URL"
echo "GUI_AUTH=existing Syncthing credentials"
echo "CONFIG=$CONF"
echo "DATA=$DATA"
echo "RESULT=SUCCESS"
