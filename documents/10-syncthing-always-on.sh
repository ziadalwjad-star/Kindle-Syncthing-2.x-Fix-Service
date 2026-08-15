#!/bin/sh
# Name: Syncthing Always-On

VERSION="1.0.0"
BIN="/mnt/us/filemanagers/bin/syncthing"
CONF="/mnt/us/filemanagers/settings"
DATA="/var/local/syncthing-filemanagers"
STATE="/var/local/kindle-syncthing-service"
SUPERVISOR="$STATE/supervisor.sh"
SERVICE="kindle-syncthing"
JOB="/etc/upstart/kindle-syncthing.conf"
OUT="/mnt/us/documents/SYNCTHING-ALWAYS-ON-STATUS.txt"
MANUAL_PIDFILE="$STATE/manual-gui.pid"
MANUAL_IFACEFILE="$STATE/manual-gui.iface"
ROOT_RW=0
ROOT_CHANGED=0
BACKUP_DIR=""

PATH="/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/bin"
export PATH
umask 077

exec >"$OUT" 2>&1

echo "Syncthing Always-On"
echo "VERSION=$VERSION"
date
echo

restore_root() {
    if [ "$ROOT_RW" = "1" ]; then
        mntroot ro >/dev/null 2>&1 || true
        ROOT_RW=0
    fi
}

restore_jobs() {
    [ "$ROOT_CHANGED" = "1" ] || return 0
    [ -n "$BACKUP_DIR" ] || return 0
    [ -d "$BACKUP_DIR" ] || return 0

    if ! mntroot rw >/dev/null 2>&1; then
        return 0
    fi

    rm -f \
        /etc/upstart/kindle-syncthing.conf \
        /etc/upstart/syncthing-news.conf \
        /etc/upstart/syncthing-watchdog.conf \
        /etc/upstart/syncthing.conf

    for FILE in "$BACKUP_DIR"/*.conf; do
        [ -f "$FILE" ] || continue
        cp "$FILE" "/etc/upstart/$(basename "$FILE")" 2>/dev/null || true
    done

    sync
    mntroot ro >/dev/null 2>&1 || true
    initctl reload-configuration >/dev/null 2>&1 || true
}

fail() {
    restore_root
    stop "$SERVICE" >/dev/null 2>&1 || true
    restore_jobs
    echo
    echo "RESULT=FAIL"
    echo "ERROR=$1"
    exit 1
}

trap restore_root EXIT
trap 'restore_root; exit 130' HUP INT TERM

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

remove_rule() {
    IFACE="$1"
    PORT="$2"
    PROTO="$3"

    [ -n "$IFACE" ] || return 0
    while iptables -D INPUT -i "$IFACE" -p "$PROTO" --dport "$PORT" -j ACCEPT 2>/dev/null; do
        :
    done
}

close_manual_firewall() {
    IFACE=""
    [ -s "$MANUAL_IFACEFILE" ] && IFACE=$(cat "$MANUAL_IFACEFILE" 2>/dev/null)
    [ -n "$IFACE" ] || IFACE=$(get_iface)

    remove_rule "$IFACE" 8384 tcp
    rm -f "$MANUAL_IFACEFILE"
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

stop_manual_mode() {
    if [ -s "$MANUAL_PIDFILE" ]; then
        P=$(cat "$MANUAL_PIDFILE" 2>/dev/null)
        stop_pid "$P"
    fi
    rm -f "$MANUAL_PIDFILE"
    close_manual_firewall
}

stop_all_syncthing() {
    for P in $(pidof syncthing 2>/dev/null); do
        stop_pid "$P"
    done
}

pid_is_service_syncthing() {
    P="$1"
    [ -n "$P" ] || return 1
    [ -r "/proc/$P/cmdline" ] || return 1

    CMDLINE=$(tr '\000' ' ' < "/proc/$P/cmdline" 2>/dev/null)
    printf '%s\n' "$CMDLINE" | grep -F -- "$BIN" >/dev/null 2>&1 || return 1
    printf '%s\n' "$CMDLINE" | grep -F -- "--gui-address=127.0.0.1:8384" >/dev/null 2>&1
}

service_child_pid() {
    if [ -s "$STATE/syncthing.pid" ]; then
        P=$(cat "$STATE/syncthing.pid" 2>/dev/null)
        if [ -n "$P" ] && kill -0 "$P" 2>/dev/null && pid_is_service_syncthing "$P"; then
            echo "$P"
            return 0
        fi
    fi
    return 1
}

service_healthy() {
    status "$SERVICE" 2>/dev/null | grep -q 'start/running' || return 1
    service_child_pid >/dev/null 2>&1
}

start_service() {
    if service_healthy; then
        return 0
    fi

    start "$SERVICE" >/dev/null 2>&1 || true

    N=0
    while [ "$N" -lt 30 ]; do
        if service_healthy; then
            return 0
        fi
        sleep 1
        N=$((N + 1))
    done

    return 1
}

current_install() {
    [ -f "$JOB" ] || return 1
    [ -x "$SUPERVISOR" ] || return 1
    grep -q '^SERVICE_VERSION="1.0.0"$' "$SUPERVISOR" 2>/dev/null
}

[ "$(id -u)" = "0" ] || fail "root privileges are required"

for CMD in initctl ip iptables mntroot pidof start status stop; do
    command -v "$CMD" >/dev/null 2>&1 || fail "required command is unavailable: $CMD"
done

[ -f "$BIN" ] || fail "Syncthing binary not found at $BIN"
chmod 0755 "$BIN" 2>/dev/null || true
[ -x "$BIN" ] || fail "Syncthing binary is not executable"

for FILE in "$CONF/config.xml" "$CONF/cert.pem" "$CONF/key.pem"; do
    [ -s "$FILE" ] || fail "missing required Syncthing file: $FILE"
done

TOP_HELP=$("$BIN" --help 2>&1 || true)
SERVE_HELP=$("$BIN" serve --help 2>&1 || true)

for OPT in --config --data; do
    printf '%s\n' "$TOP_HELP" | grep -q -- "$OPT" || fail "unsupported Syncthing CLI option: $OPT"
done

for OPT in --gui-address --no-browser --no-upgrade --no-restart --log-file --log-max-size --log-max-old-files; do
    printf '%s\n' "$SERVE_HELP" | grep -q -- "$OPT" || fail "unsupported Syncthing serve option: $OPT"
done

mkdir -p "$DATA" "$STATE" "$STATE/backup" || fail "unable to create runtime directories"
chmod 0700 "$DATA" "$STATE" "$STATE/backup" 2>/dev/null || true

DEVICE_ID=$("$BIN" --config="$CONF" --data="$DATA" device-id 2>/dev/null | tail -n 1)
[ -n "$DEVICE_ID" ] || fail "unable to read Syncthing device ID"
echo "DEVICE_ID=$DEVICE_ID"

stop_manual_mode

if current_install; then
    stop syncthing-news >/dev/null 2>&1 || true
    stop syncthing-watchdog >/dev/null 2>&1 || true
    stop syncthing >/dev/null 2>&1 || true

    if ! service_healthy; then
        stop_all_syncthing
    fi

    start_service || fail "installed always-on service did not start"

    P=$(service_child_pid)
    echo "ACTION=SWITCH_TO_ALWAYS_ON"
    echo "PID=$P"
    echo "GUI=127.0.0.1:8384"
    echo "RESULT=SUCCESS"
    exit 0
fi

stop "$SERVICE" >/dev/null 2>&1 || true
stop syncthing-news >/dev/null 2>&1 || true
stop syncthing-watchdog >/dev/null 2>&1 || true
stop syncthing >/dev/null 2>&1 || true
sleep 2
stop_all_syncthing

cat > "$SUPERVISOR" <<'SUPERVISOR_EOF'
#!/bin/sh

SERVICE_VERSION="1.0.0"
BIN="/mnt/us/filemanagers/bin/syncthing"
CONF="/mnt/us/filemanagers/settings"
DATA="/var/local/syncthing-filemanagers"
STATE="/var/local/kindle-syncthing-service"
PIDFILE="$STATE/syncthing.pid"
IFACEFILE="$STATE/firewall.iface"
LOG="$STATE/supervisor.log"
SYNCTHING_LOG="$DATA/syncthing.log"

CHECK_INTERVAL=20
START_GRACE=5
BACKOFF_INITIAL=2
BACKOFF_MAX=120
FIREWALL_EVERY=15

PATH="/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/bin"
export PATH
umask 077

CHILD_PID=""
BACKOFF="$BACKOFF_INITIAL"
LOOPS=0

rotate_log() {
    if [ -f "$LOG" ]; then
        SIZE=$(wc -c < "$LOG" 2>/dev/null || echo 0)
        case "$SIZE" in
            ''|*[!0-9]*) SIZE=0 ;;
        esac

        if [ "$SIZE" -gt 131072 ]; then
            mv -f "$LOG" "$LOG.1" 2>/dev/null || true
        fi
    fi
}

log() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || date)" "$*" >> "$LOG"
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
    OLD_IFACE=""
    [ -s "$IFACEFILE" ] && OLD_IFACE=$(cat "$IFACEFILE" 2>/dev/null)
    CURRENT_IFACE=$(get_iface)

    for IFACE in "$OLD_IFACE" "$CURRENT_IFACE"; do
        [ -n "$IFACE" ] || continue
        remove_rule "$IFACE" 8384 tcp
        remove_rule "$IFACE" 22000 tcp
        remove_rule "$IFACE" 22000 udp
        remove_rule "$IFACE" 21027 udp
    done

    rm -f "$IFACEFILE"
}

refresh_firewall() {
    IFACE=$(get_iface)
    [ -n "$IFACE" ] || return 0

    remove_firewall

    iptables -A INPUT -i "$IFACE" -p tcp --dport 22000 -j ACCEPT 2>/dev/null || true
    iptables -A INPUT -i "$IFACE" -p udp --dport 22000 -j ACCEPT 2>/dev/null || true
    iptables -A INPUT -i "$IFACE" -p udp --dport 21027 -j ACCEPT 2>/dev/null || true

    echo "$IFACE" > "$IFACEFILE"
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

stop_stale_syncthing() {
    for P in $(pidof syncthing 2>/dev/null); do
        if [ -z "$CHILD_PID" ] || [ "$P" != "$CHILD_PID" ]; then
            stop_pid "$P"
        fi
    done
}

child_is_syncthing() {
    [ -n "$CHILD_PID" ] || return 1
    [ -r "/proc/$CHILD_PID/cmdline" ] || return 1

    CMDLINE=$(tr '\000' ' ' < "/proc/$CHILD_PID/cmdline" 2>/dev/null)
    printf '%s\n' "$CMDLINE" | grep -F -- "$BIN" >/dev/null 2>&1 || return 1
    printf '%s\n' "$CMDLINE" | grep -F -- "--gui-address=127.0.0.1:8384" >/dev/null 2>&1
}

wait_for_files() {
    N=0

    while [ ! -x "$BIN" ] || [ ! -s "$CONF/config.xml" ] || [ ! -s "$CONF/cert.pem" ] || [ ! -s "$CONF/key.pem" ]; do
        if [ "$N" -eq 0 ]; then
            log "waiting for Syncthing binary and identity files"
        fi

        chmod 0755 "$BIN" 2>/dev/null || true
        sleep 10
        N=$((N + 1))

        if [ "$N" -ge 6 ]; then
            log "still waiting for Syncthing binary and identity files"
            N=0
        fi
    done
}

start_child() {
    stop_stale_syncthing
    refresh_firewall
    mkdir -p "$DATA" "$STATE" || return 1
    chmod 0700 "$DATA" "$STATE" 2>/dev/null || true
    chmod 0755 "$BIN" 2>/dev/null || true

    (
        unset UPSTART_JOB UPSTART_INSTANCE UPSTART_EVENTS
        HOME="$STATE"
        TMPDIR="/tmp"
        USER="root"
        LOGNAME="root"
        export HOME TMPDIR USER LOGNAME

        exec "$BIN" \
            --config="$CONF" \
            --data="$DATA" \
            serve \
            --no-browser \
            --no-upgrade \
            --no-restart \
            --gui-address=127.0.0.1:8384 \
            --log-file="$SYNCTHING_LOG" \
            --log-max-size=1048576 \
            --log-max-old-files=2
    ) >>"$LOG" 2>&1 &

    CHILD_PID=$!
    echo "$CHILD_PID" > "$PIDFILE"
    log "started Syncthing pid=$CHILD_PID"

    sleep "$START_GRACE"

    if kill -0 "$CHILD_PID" 2>/dev/null && child_is_syncthing; then
        return 0
    fi

    wait "$CHILD_PID" 2>/dev/null
    RC=$?
    log "Syncthing exited during startup rc=$RC"
    CHILD_PID=""
    rm -f "$PIDFILE"
    return 1
}

cleanup() {
    trap - HUP INT TERM
    log "stopping supervisor"
    stop_pid "$CHILD_PID"
    CHILD_PID=""
    rm -f "$PIDFILE"
    remove_firewall
    exit 0
}

trap cleanup HUP INT TERM

mkdir -p "$STATE" "$DATA" 2>/dev/null || exit 1
chmod 0700 "$STATE" "$DATA" 2>/dev/null || true
rotate_log
log "supervisor started"

while :; do
    wait_for_files

    if [ -z "$CHILD_PID" ]; then
        if start_child; then
            BACKOFF="$BACKOFF_INITIAL"
        else
            log "retrying Syncthing in ${BACKOFF}s"
            sleep "$BACKOFF"
            BACKOFF=$((BACKOFF * 2))
            [ "$BACKOFF" -gt "$BACKOFF_MAX" ] && BACKOFF="$BACKOFF_MAX"
            continue
        fi
    elif ! kill -0 "$CHILD_PID" 2>/dev/null || ! child_is_syncthing; then
        wait "$CHILD_PID" 2>/dev/null
        RC=$?
        log "Syncthing exited rc=$RC"
        CHILD_PID=""
        rm -f "$PIDFILE"
        sleep "$BACKOFF"
        BACKOFF=$((BACKOFF * 2))
        [ "$BACKOFF" -gt "$BACKOFF_MAX" ] && BACKOFF="$BACKOFF_MAX"
        continue
    else
        BACKOFF="$BACKOFF_INITIAL"
    fi

    LOOPS=$((LOOPS + 1))

    if [ "$LOOPS" -ge "$FIREWALL_EVERY" ]; then
        refresh_firewall
        LOOPS=0
    fi

    sleep "$CHECK_INTERVAL"
done
SUPERVISOR_EOF

chmod 0700 "$SUPERVISOR" || fail "unable to secure supervisor script"

TS=$(date '+%Y%m%d-%H%M%S')
BACKUP_DIR="$STATE/backup/$TS"
mkdir -p "$BACKUP_DIR" || fail "unable to create startup-job backup"

for OLD in \
    /etc/upstart/syncthing.conf \
    /etc/upstart/syncthing-watchdog.conf \
    /etc/upstart/syncthing-news.conf \
    /etc/upstart/kindle-syncthing.conf
do
    if [ -f "$OLD" ]; then
        cp "$OLD" "$BACKUP_DIR/$(basename "$OLD")" || fail "unable to back up $(basename "$OLD")"
    fi
done

mntroot rw >/dev/null 2>&1 || fail "unable to remount root filesystem read-write"
ROOT_RW=1
ROOT_CHANGED=1

rm -f \
    /etc/upstart/syncthing.conf \
    /etc/upstart/syncthing-watchdog.conf \
    /etc/upstart/syncthing-news.conf \
    /etc/upstart/kindle-syncthing.conf

cat > "$JOB" <<'JOB_EOF'
description "Kindle Syncthing service"

start on started wmt
stop on stopping filesystems

respawn
respawn limit 10 300
kill timeout 30

exec /bin/sh /var/local/kindle-syncthing-service/supervisor.sh
JOB_EOF

chmod 0644 "$JOB" || fail "unable to set Upstart job permissions"
sync

mntroot ro >/dev/null 2>&1 || fail "unable to restore root filesystem read-only"
ROOT_RW=0

initctl reload-configuration >/dev/null 2>&1 || fail "unable to reload Upstart configuration"

start_service || fail "always-on service did not start"

P=$(service_child_pid)
echo "INSTALL_TEST=PASS"
echo "START_PID=$P"

OLD_PID="$P"
kill "$OLD_PID" 2>/dev/null || fail "unable to run supervisor recovery test"

N=0
NEW_PID=""

while [ "$N" -lt 45 ]; do
    NEW_PID=$(service_child_pid 2>/dev/null || true)

    if [ -n "$NEW_PID" ] && [ "$NEW_PID" != "$OLD_PID" ] && kill -0 "$NEW_PID" 2>/dev/null; then
        break
    fi

    sleep 1
    N=$((N + 1))
done

if [ -z "$NEW_PID" ] || [ "$NEW_PID" = "$OLD_PID" ] || ! kill -0 "$NEW_PID" 2>/dev/null; then
    fail "supervisor recovery test failed"
fi

status "$SERVICE" 2>/dev/null | grep -q 'start/running' || fail "Upstart supervisor is not running"

ROOT_CHANGED=0

echo "RECOVERY_TEST=PASS"
echo "RECOVERY_PID=$NEW_PID"
echo "ACTION=INSTALL"
echo "CONFIG=$CONF"
echo "DATA=$DATA"
echo "GUI=127.0.0.1:8384"
echo "RESULT=SUCCESS"
