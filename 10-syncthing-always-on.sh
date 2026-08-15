#!/bin/sh
# Name: Syncthing Always-On

VERSION="1.1"
SERVICE_GENERATION="4"
BIN="/mnt/us/filemanagers/bin/syncthing"
CONF="/mnt/us/filemanagers/settings"
DATA="/var/local/syncthing-filemanagers"
STATE="/var/local/kindle-syncthing-service"
SUPERVISOR="$STATE/supervisor.sh"
SERVICE="kindle-syncthing"
UPSTART_DIR="/etc/upstart"
JOB="$UPSTART_DIR/kindle-syncthing.conf"
OUT="/mnt/us/documents/SYNCTHING-ALWAYS-ON-STATUS.txt"
HEALTH="$STATE/health.txt"
MANUAL_PIDFILE="$STATE/manual-gui.pid"
MANUAL_IFACEFILE="$STATE/manual-firewall.iface"
SERVICE_IFACEFILE="$STATE/service-firewall.iface"
LEGACY_MANUAL_IFACEFILE="$STATE/manual-gui.iface"
LEGACY_SERVICE_IFACEFILE="$STATE/firewall.iface"
LOCKDIR="$STATE/action.lock"
FIREWALL_CHAIN="KST_SYNCTHING"

PATH="/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/bin"
export PATH
umask 077

LOCK_HELD=0
ROOT_RW=0
INSTALL_CHANGED=0
BACKUP_DIR=""
HAD_SUPERVISOR=0
JOBS_STOPPED=0
SERVICE_WAS_RUNNING=0
NEWS_WAS_RUNNING=0
WATCHDOG_WAS_RUNNING=0
LEGACY_WAS_RUNNING=0

exec 3>&1

screen() {
    printf '%s\n' "$*" >&3
}

alert() {
    ALERT_TITLE="$1"
    ALERT_TEXT="$2"

    command -v lipc-set-prop >/dev/null 2>&1 || return 0

    ALERT_TITLE=$(printf '%s' "$ALERT_TITLE" | tr '\n\r\t' '   ' | sed 's/\\/\\\\/g; s/"/\\"/g')
    ALERT_TEXT=$(printf '%s' "$ALERT_TEXT" | tr '\n\r\t' '   ' | sed 's/\\/\\\\/g; s/"/\\"/g')
    ALERT_JSON='{ "clientParams":{ "alertId":"appAlert1", "show":true, "customStrings":[ { "matchStr":"alertTitle", "replaceStr":"'"$ALERT_TITLE"'" }, { "matchStr":"alertText", "replaceStr":"'"$ALERT_TEXT"'" } ] } }'

    lipc-set-prop com.lab126.pillow pillowAlert "$ALERT_JSON" >/dev/null 2>&1 || true
}

process_start_time() {
    [ -r "/proc/$1/stat" ] || return 1
    awk '{ print $22 }' "/proc/$1/stat" 2>/dev/null
}

boot_id() {
    [ -r /proc/sys/kernel/random/boot_id ] || return 1
    cat /proc/sys/kernel/random/boot_id 2>/dev/null
}

write_lock_owner() {
    LOCK_START=$(process_start_time "$$") || return 1
    LOCK_BOOT=$(boot_id 2>/dev/null || true)

    printf '%s\n' "$$" > "$LOCKDIR/pid" || return 1
    printf '%s\n' "$LOCK_START" > "$LOCKDIR/start" || return 1
    [ -z "$LOCK_BOOT" ] || printf '%s\n' "$LOCK_BOOT" > "$LOCKDIR/boot" || return 1
    return 0
}

lock_owner_alive() {
    LOCK_PID=""
    LOCK_START=""
    LOCK_BOOT=""
    CURRENT_BOOT=""

    [ -s "$LOCKDIR/pid" ] && LOCK_PID=$(cat "$LOCKDIR/pid" 2>/dev/null)
    [ -s "$LOCKDIR/start" ] && LOCK_START=$(cat "$LOCKDIR/start" 2>/dev/null)
    [ -s "$LOCKDIR/boot" ] && LOCK_BOOT=$(cat "$LOCKDIR/boot" 2>/dev/null)

    [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null || return 1
    [ -n "$LOCK_START" ] || return 1
    case "$LOCK_START" in
        *[!0-9]*) return 1 ;;
    esac
    [ "$(process_start_time "$LOCK_PID" 2>/dev/null)" = "$LOCK_START" ] || return 1

    if [ -n "$LOCK_BOOT" ]; then
        CURRENT_BOOT=$(boot_id 2>/dev/null || true)
        [ -z "$CURRENT_BOOT" ] || [ "$CURRENT_BOOT" = "$LOCK_BOOT" ] || return 1
    fi

    return 0
}

release_lock() {
    [ "$LOCK_HELD" = "1" ] || return 0
    rm -rf "$LOCKDIR"
    LOCK_HELD=0
}

restore_root() {
    [ "$ROOT_RW" = "1" ] || return 0

    if mntroot ro >/dev/null 2>&1; then
        ROOT_RW=0
        return 0
    fi

    return 1
}

on_exit() {
    restore_root || true
    release_lock
}

acquire_lock() {
    if mkdir "$LOCKDIR" 2>/dev/null; then
        if ! write_lock_owner; then
            rm -rf "$LOCKDIR"
            return 1
        fi
        LOCK_HELD=1
        return 0
    fi

    if lock_owner_alive; then
        return 1
    fi

    rm -rf "$LOCKDIR"
    if mkdir "$LOCKDIR" 2>/dev/null; then
        if ! write_lock_owner; then
            rm -rf "$LOCKDIR"
            return 1
        fi
        LOCK_HELD=1
        return 0
    fi

    return 1
}

get_ipv4() {
    ip addr show "$1" 2>/dev/null | awk '
        $1 == "inet" {
            split($2, address, "/")
            if (address[1] != "127.0.0.1") {
                print address[1]
                exit
            }
        }
    '
}

get_iface() {
    DEFAULT_IFACE=$(ip route 2>/dev/null | awk '
        $1 == "default" {
            for (i = 1; i <= NF; i++) {
                if ($i == "dev" && (i + 1) <= NF) {
                    print $(i + 1)
                    exit
                }
            }
        }
    ')

    if [ -n "$DEFAULT_IFACE" ] && [ -n "$(get_ipv4 "$DEFAULT_IFACE")" ]; then
        printf '%s\n' "$DEFAULT_IFACE"
        return 0
    fi

    if ip link show wlan0 >/dev/null 2>&1 && [ -n "$(get_ipv4 wlan0)" ]; then
        printf '%s\n' "wlan0"
        return 0
    fi

    return 1
}

remove_direct_rule() {
    RULE_IFACE="$1"
    RULE_PORT="$2"
    RULE_PROTO="$3"

    [ -n "$RULE_IFACE" ] || return 0
    iptables -D INPUT -i "$RULE_IFACE" -p "$RULE_PROTO" --dport "$RULE_PORT" -j ACCEPT >/dev/null 2>&1 || true
}

remove_jump() {
    JUMP_IFACE="$1"
    [ -n "$JUMP_IFACE" ] || return 0
    while iptables -D INPUT -i "$JUMP_IFACE" -j "$FIREWALL_CHAIN" 2>/dev/null; do
        :
    done
}

remove_legacy_firewall() {
    for LEGACY_FILE in "$LEGACY_MANUAL_IFACEFILE" "$LEGACY_SERVICE_IFACEFILE"; do
        [ -s "$LEGACY_FILE" ] || continue
        LEGACY_IFACE=$(cat "$LEGACY_FILE" 2>/dev/null)
        if [ -n "$LEGACY_IFACE" ]; then
            remove_direct_rule "$LEGACY_IFACE" 8384 tcp
            remove_direct_rule "$LEGACY_IFACE" 22000 tcp
            remove_direct_rule "$LEGACY_IFACE" 22000 udp
            remove_direct_rule "$LEGACY_IFACE" 21027 udp
        fi
        rm -f "$LEGACY_FILE"
    done
}

close_firewall() {
    OLD_MANUAL_IFACE=""
    OLD_SERVICE_IFACE=""
    CURRENT_IFACE=""

    [ -s "$MANUAL_IFACEFILE" ] && OLD_MANUAL_IFACE=$(cat "$MANUAL_IFACEFILE" 2>/dev/null)
    [ -s "$SERVICE_IFACEFILE" ] && OLD_SERVICE_IFACE=$(cat "$SERVICE_IFACEFILE" 2>/dev/null)
    CURRENT_IFACE=$(get_iface 2>/dev/null || true)

    for CLEAN_IFACE in "$OLD_MANUAL_IFACE" "$OLD_SERVICE_IFACE" "$CURRENT_IFACE"; do
        remove_jump "$CLEAN_IFACE"
    done

    iptables -F "$FIREWALL_CHAIN" >/dev/null 2>&1 || true
    iptables -X "$FIREWALL_CHAIN" >/dev/null 2>&1 || true
    rm -f "$MANUAL_IFACEFILE" "$SERVICE_IFACEFILE"
}

pid_start_time() {
    [ -r "/proc/$1/stat" ] || return 1
    awk '{ print $22 }' "/proc/$1/stat" 2>/dev/null
}

pid_state() {
    [ -r "/proc/$1/stat" ] || return 1
    awk '{ print $3 }' "/proc/$1/stat" 2>/dev/null
}

stop_pid() {
    STOP_PID="$1"
    [ -n "$STOP_PID" ] || return 0

    STOP_START=$(pid_start_time "$STOP_PID")
    [ -n "$STOP_START" ] || return 0
    kill "$STOP_PID" 2>/dev/null || return 0

    STOP_WAIT=0
    while kill -0 "$STOP_PID" 2>/dev/null && [ "$STOP_WAIT" -lt 10 ]; do
        [ "$(pid_state "$STOP_PID" 2>/dev/null)" = "Z" ] && return 0
        sleep 1
        STOP_WAIT=$((STOP_WAIT + 1))
    done

    [ "$(pid_start_time "$STOP_PID" 2>/dev/null)" = "$STOP_START" ] || return 0
    [ "$(pid_state "$STOP_PID" 2>/dev/null)" = "Z" ] && return 0
    kill -9 "$STOP_PID" 2>/dev/null || true
}

pid_uses_filemanagers_binary() {
    CHECK_PID="$1"
    [ -n "$CHECK_PID" ] || return 1
    [ -r "/proc/$CHECK_PID/cmdline" ] || return 1

    CHECK_ARGS=$(tr '\000' '\n' < "/proc/$CHECK_PID/cmdline" 2>/dev/null)
    CHECK_ARG0=$(printf '%s\n' "$CHECK_ARGS" | sed -n '1p')
    CHECK_ARG1=$(printf '%s\n' "$CHECK_ARGS" | sed -n '2p')
    [ "$CHECK_ARG0" = "$BIN" ] || [ "$CHECK_ARG1" = "$BIN" ]
}

pid_has_arg() {
    CHECK_PID="$1"
    CHECK_ARG="$2"
    [ -r "/proc/$CHECK_PID/cmdline" ] || return 1
    tr '\000' '\n' < "/proc/$CHECK_PID/cmdline" 2>/dev/null |
        grep -F -x -e "$CHECK_ARG" >/dev/null 2>&1
}

pid_is_config_data_syncthing() {
    CHECK_PID="$1"
    pid_uses_filemanagers_binary "$CHECK_PID" || return 1
    pid_has_arg "$CHECK_PID" "--config=$CONF" || return 1
    pid_has_arg "$CHECK_PID" "--data=$DATA"
}

pid_is_legacy_syncthing() {
    CHECK_PID="$1"
    pid_uses_filemanagers_binary "$CHECK_PID" || return 1
    pid_has_arg "$CHECK_PID" "--home=$CONF" && return 0
    pid_has_arg "$CHECK_PID" "-home=$CONF"
}

pid_is_managed_syncthing() {
    CHECK_PID="$1"
    pid_is_config_data_syncthing "$CHECK_PID" && return 0
    pid_is_legacy_syncthing "$CHECK_PID"
}

pid_is_service_syncthing() {
    CHECK_PID="$1"
    pid_is_config_data_syncthing "$CHECK_PID" || return 1
    pid_has_arg "$CHECK_PID" "--gui-address=127.0.0.1:8384"
}

pid_is_manual_syncthing() {
    CHECK_PID="$1"
    pid_is_config_data_syncthing "$CHECK_PID" || return 1
    tr '\000' '\n' < "/proc/$CHECK_PID/cmdline" 2>/dev/null |
        grep -E '^--gui-address=' >/dev/null 2>&1 || return 1
    pid_has_arg "$CHECK_PID" "--gui-address=127.0.0.1:8384" && return 1
    return 0
}

stop_managed_syncthing() {
    for FOUND_PID in $(pidof syncthing 2>/dev/null); do
        if pid_is_managed_syncthing "$FOUND_PID"; then
            stop_pid "$FOUND_PID"
        fi
    done
}

stop_manual_mode() {
    if [ -s "$MANUAL_PIDFILE" ]; then
        MANUAL_PID=$(cat "$MANUAL_PIDFILE" 2>/dev/null)
        if [ -n "$MANUAL_PID" ] && kill -0 "$MANUAL_PID" 2>/dev/null; then
            if pid_is_manual_syncthing "$MANUAL_PID"; then
                stop_pid "$MANUAL_PID"
            else
                echo "STALE_MANUAL_PID=$MANUAL_PID"
                echo "STALE_MANUAL_PID_ACTION=ignored"
            fi
        fi
    fi

    rm -f "$MANUAL_PIDFILE"
    remove_legacy_firewall
    close_firewall
}

service_child_pid() {
    if [ -s "$STATE/syncthing.pid" ]; then
        SERVICE_PID=$(cat "$STATE/syncthing.pid" 2>/dev/null)
        if [ -n "$SERVICE_PID" ] && kill -0 "$SERVICE_PID" 2>/dev/null && pid_is_service_syncthing "$SERVICE_PID"; then
            printf '%s\n' "$SERVICE_PID"
            return 0
        fi
    fi
    return 1
}

health_value() {
    HEALTH_KEY="$1"
    [ -s "$HEALTH" ] || return 1
    sed -n "s/^${HEALTH_KEY}=//p" "$HEALTH" 2>/dev/null | head -n 1
}

service_healthy() {
    status "$SERVICE" 2>/dev/null | grep -q 'start/running' || return 1
    service_child_pid >/dev/null 2>&1 || return 1

    case "$(health_value STATE 2>/dev/null)" in
        RUNNING|RUNNING_OFFLINE|RUNNING_WITH_WARNING) return 0 ;;
    esac

    return 1
}

report_service_state() {
    RUN_STATE=$(health_value STATE 2>/dev/null || true)
    RUN_FIREWALL=$(health_value FIREWALL 2>/dev/null || true)
    RUN_RULES=$(health_value RULES 2>/dev/null || true)
    [ -n "$RUN_STATE" ] || RUN_STATE="UNKNOWN"
    [ -n "$RUN_FIREWALL" ] || RUN_FIREWALL="UNKNOWN"
    [ -n "$RUN_RULES" ] || RUN_RULES="UNKNOWN"
    SERVICE_RESULT="SUCCESS"

    echo "SERVICE_STATE=$RUN_STATE"
    echo "FIREWALL=$RUN_FIREWALL"
    echo "FIREWALL_RULES=$RUN_RULES"

    case "$RUN_STATE" in
        RUNNING)
            echo "NETWORK=ONLINE"
            screen "Syncthing Always-On: RUNNING"
            screen "Background sync is active. The GUI is local-only."
            alert "Syncthing Always-On" "Running. Background sync is active; the GUI is local-only."
            ;;
        RUNNING_OFFLINE)
            echo "NETWORK=WAITING"
            screen "Syncthing Always-On: WAITING FOR NETWORK"
            screen "The service is running and will connect when Wi-Fi is ready."
            alert "Syncthing Always-On" "Running, but Wi-Fi is not ready yet. Sync will resume automatically when networking returns."
            ;;
        RUNNING_WITH_WARNING)
            SERVICE_RESULT="WARNING"
            echo "NETWORK=DEGRADED"
            screen "Syncthing Always-On: RUNNING WITH WARNING"
            screen "Syncthing is running, but network/firewall state needs attention."
            alert "Syncthing Always-On" "Running with a network/firewall warning. See SYNCTHING-ALWAYS-ON-STATUS.txt for details."
            ;;
        *)
            SERVICE_RESULT="WARNING"
            echo "NETWORK=UNKNOWN"
            screen "Syncthing Always-On: RUNNING"
            screen "Background service is active; current network state is not yet known."
            alert "Syncthing Always-On" "Background service is active; current network state is still being determined."
            ;;
    esac
}

start_service() {
    if service_healthy; then
        return 0
    fi

    start "$SERVICE" >/dev/null 2>&1 || true

    START_WAIT=0
    while [ "$START_WAIT" -lt 35 ]; do
        if service_healthy; then
            return 0
        fi
        sleep 1
        START_WAIT=$((START_WAIT + 1))
    done

    return 1
}

current_install() {
    [ -f "$JOB" ] || return 1
    [ -x "$SUPERVISOR" ] || return 1
    /bin/sh -n "$SUPERVISOR" >/dev/null 2>&1 || return 1
    grep -F -q -e "SERVICE_VERSION=\"$VERSION\"" "$SUPERVISOR" 2>/dev/null || return 1
    grep -F -q -e "SERVICE_GENERATION=\"$SERVICE_GENERATION\"" "$SUPERVISOR" 2>/dev/null || return 1
    grep -F -q -e "FIREWALL_CHAIN=\"$FIREWALL_CHAIN\"" "$SUPERVISOR" 2>/dev/null || return 1
    grep -F -q -e "exec /bin/sh $SUPERVISOR" "$JOB" 2>/dev/null
}

job_running() {
    status "$1" 2>/dev/null | grep -q 'start/running'
}

remember_jobs() {
    job_running "$SERVICE" && SERVICE_WAS_RUNNING=1
    job_running syncthing-news && NEWS_WAS_RUNNING=1
    job_running syncthing-watchdog && WATCHDOG_WAS_RUNNING=1
    job_running syncthing && LEGACY_WAS_RUNNING=1
}

stop_jobs() {
    stop "$SERVICE" >/dev/null 2>&1 || true
    stop syncthing-news >/dev/null 2>&1 || true
    stop syncthing-watchdog >/dev/null 2>&1 || true
    stop syncthing >/dev/null 2>&1 || true
    JOBS_STOPPED=1

    STOP_JOB_FAILED=0
    [ "$SERVICE_WAS_RUNNING" = "1" ] && job_running "$SERVICE" && STOP_JOB_FAILED=1
    [ "$NEWS_WAS_RUNNING" = "1" ] && job_running syncthing-news && STOP_JOB_FAILED=1
    [ "$WATCHDOG_WAS_RUNNING" = "1" ] && job_running syncthing-watchdog && STOP_JOB_FAILED=1
    [ "$LEGACY_WAS_RUNNING" = "1" ] && job_running syncthing && STOP_JOB_FAILED=1

    [ "$STOP_JOB_FAILED" = "0" ]
}

restore_previous_runtime() {
    [ "$JOBS_STOPPED" = "1" ] || return 0

    RESTORE_RUNTIME_FAILED=0
    if [ "$SERVICE_WAS_RUNNING" = "1" ]; then
        start "$SERVICE" >/dev/null 2>&1 || RESTORE_RUNTIME_FAILED=1
    fi
    if [ "$NEWS_WAS_RUNNING" = "1" ]; then
        start syncthing-news >/dev/null 2>&1 || RESTORE_RUNTIME_FAILED=1
    fi
    if [ "$WATCHDOG_WAS_RUNNING" = "1" ]; then
        start syncthing-watchdog >/dev/null 2>&1 || RESTORE_RUNTIME_FAILED=1
    fi
    if [ "$LEGACY_WAS_RUNNING" = "1" ]; then
        start syncthing >/dev/null 2>&1 || RESTORE_RUNTIME_FAILED=1
    fi

    [ "$RESTORE_RUNTIME_FAILED" = "0" ]
}

rollback_install() {
    [ "$INSTALL_CHANGED" = "1" ] || return 0

    ROLLBACK_FAILED=0
    if [ "$JOBS_STOPPED" = "1" ]; then
        stop "$SERVICE" >/dev/null 2>&1 || true
    fi

    rm -f "$SUPERVISOR"
    if [ "$HAD_SUPERVISOR" = "1" ]; then
        cp "$BACKUP_DIR/supervisor.sh" "$SUPERVISOR" 2>/dev/null || ROLLBACK_FAILED=1
        chmod 0700 "$SUPERVISOR" 2>/dev/null || true
    fi

    if mntroot rw >/dev/null 2>&1; then
        ROOT_RW=1
        rm -f \
            "$UPSTART_DIR/kindle-syncthing.conf" \
            "$UPSTART_DIR/syncthing-news.conf" \
            "$UPSTART_DIR/syncthing-watchdog.conf" \
            "$UPSTART_DIR/syncthing.conf"

        for BACKUP_JOB in "$BACKUP_DIR"/*.conf; do
            [ -f "$BACKUP_JOB" ] || continue
            cp "$BACKUP_JOB" "$UPSTART_DIR/$(basename "$BACKUP_JOB")" 2>/dev/null || ROLLBACK_FAILED=1
        done

        sync
        if mntroot ro >/dev/null 2>&1; then
            ROOT_RW=0
        else
            ROLLBACK_FAILED=1
        fi
        initctl reload-configuration >/dev/null 2>&1 || ROLLBACK_FAILED=1
    else
        ROLLBACK_FAILED=1
    fi

    if ! restore_previous_runtime; then
        ROLLBACK_FAILED=1
    fi

    if [ "$ROLLBACK_FAILED" = "0" ]; then
        echo "ROLLBACK=SUCCESS"
        return 0
    fi

    echo "ROLLBACK=PARTIAL"
    return 1
}

fail() {
    trap - HUP INT TERM
    rollback_install || true

    ROOT_WARNING=""
    if ! restore_root; then
        ROOT_WARNING=" Root filesystem may still be writable."
        echo "ROOTFS=WARNING"
    fi

    echo
    echo "RESULT=FAIL"
    echo "ERROR=$1"
    screen "Syncthing Always-On: FAILED"
    screen "Reason: $1"
    [ -n "$ROOT_WARNING" ] && screen "Warning:$ROOT_WARNING"
    screen "Details: $OUT"
    alert "Syncthing Always-On" "Failed: $1.$ROOT_WARNING See $OUT for details."
    exit 1
}

trap on_exit EXIT

if [ "$(id -u 2>/dev/null)" != "0" ]; then
    screen "Syncthing Always-On: FAILED"
    screen "Reason: root privileges are required"
    alert "Syncthing Always-On" "Failed: root privileges are required."
    exit 1
fi

mkdir -p "$STATE" || {
    screen "Syncthing Always-On: FAILED"
    screen "Reason: unable to create runtime state directory"
    alert "Syncthing Always-On" "Failed: unable to create runtime state directory."
    exit 1
}
chmod 0700 "$STATE" 2>/dev/null || true

if ! acquire_lock; then
    screen "Syncthing Always-On: BUSY"
    screen "Another Syncthing mode change is already running."
    alert "Syncthing Always-On" "Busy: another Syncthing mode change is already running."
    exit 1
fi

if ! : > "$OUT"; then
    screen "Syncthing Always-On: FAILED"
    screen "Reason: unable to write $OUT"
    alert "Syncthing Always-On" "Failed: unable to write the status file."
    exit 1
fi
chmod 0600 "$OUT" 2>/dev/null || true
exec >>"$OUT" 2>&1

trap 'fail "operation interrupted"' HUP INT TERM

printf '%s\n' "Syncthing Always-On"
printf '%s\n' "VERSION=$VERSION"
printf '%s\n' "SERVICE_GENERATION=$SERVICE_GENERATION"
date
echo
screen "Syncthing Always-On: checking installation..."
alert "Syncthing Always-On" "Starting. Checking the background service; details are written to SYNCTHING-ALWAYS-ON-STATUS.txt."

for CMD in initctl ip iptables mntroot pidof start status stop; do
    command -v "$CMD" >/dev/null 2>&1 || fail "required command is unavailable: $CMD"
done

[ -f "$BIN" ] || fail "Syncthing binary not found at $BIN"
[ -x "$BIN" ] || fail "Syncthing binary is not executable"

for FILE in "$CONF/config.xml" "$CONF/cert.pem" "$CONF/key.pem"; do
    [ -s "$FILE" ] || fail "missing required Syncthing file: $FILE"
done

TOP_HELP=$("$BIN" --help 2>&1 || true)
SERVE_HELP=$("$BIN" serve --help 2>&1 || true)
for OPT in --config --data; do
    printf '%s\n' "$TOP_HELP" | grep -q -e "$OPT" || fail "unsupported Syncthing CLI option: $OPT"
done
for OPT in --gui-address --no-browser --no-upgrade --no-restart --log-file --log-max-size --log-max-old-files; do
    printf '%s\n' "$SERVE_HELP" | grep -q -e "$OPT" || fail "unsupported Syncthing serve option: $OPT"
done
echo "CLI_COMPATIBILITY=OK"
SYNCTHING_VERSION=$("$BIN" --version 2>/dev/null | head -n 1)
[ -n "$SYNCTHING_VERSION" ] || SYNCTHING_VERSION="unknown"
echo "SYNCTHING_VERSION=$SYNCTHING_VERSION"

mkdir -p "$DATA" "$STATE/backup" || fail "unable to create runtime directories"
chmod 0700 "$DATA" "$STATE" "$STATE/backup" 2>/dev/null || true

DEVICE_ID=$("$BIN" --config="$CONF" --data="$DATA" device-id 2>/dev/null | tail -n 1)
[ -n "$DEVICE_ID" ] || fail "unable to read Syncthing device identity"
echo "IDENTITY=OK"

if current_install; then
    screen "Syncthing Always-On: switching to background mode..."
    stop_manual_mode
    stop syncthing-news >/dev/null 2>&1 || true
    stop syncthing-watchdog >/dev/null 2>&1 || true
    stop syncthing >/dev/null 2>&1 || true

    if ! service_healthy; then
        stop_managed_syncthing
    fi

    start_service || fail "installed always-on service did not start; check $HEALTH"

    RUN_PID=$(service_child_pid)
    echo "ACTION=SWITCH_TO_ALWAYS_ON"
    echo "PID=$RUN_PID"
    echo "GUI_BIND=127.0.0.1:8384"
    report_service_state
    echo "RESULT=$SERVICE_RESULT"
    screen "Details: $OUT"
    exit 0
fi

remember_jobs

TS=$(date '+%Y%m%d-%H%M%S')
BACKUP_DIR="$STATE/backup/$TS-$$"
mkdir -p "$BACKUP_DIR" || fail "unable to create startup backup directory"
chmod 0700 "$BACKUP_DIR" 2>/dev/null || true

if [ -f "$SUPERVISOR" ]; then
    cp "$SUPERVISOR" "$BACKUP_DIR/supervisor.sh" || fail "unable to back up the installed supervisor"
    HAD_SUPERVISOR=1
fi

for OLD_JOB in \
    "$UPSTART_DIR/syncthing.conf" \
    "$UPSTART_DIR/syncthing-watchdog.conf" \
    "$UPSTART_DIR/syncthing-news.conf" \
    "$UPSTART_DIR/kindle-syncthing.conf"
do
    if [ -f "$OLD_JOB" ]; then
        cp "$OLD_JOB" "$BACKUP_DIR/$(basename "$OLD_JOB")" || fail "unable to back up $(basename "$OLD_JOB")"
    fi
done

SUPERVISOR_TMP="$STATE/.supervisor.sh.$$"
cat > "$SUPERVISOR_TMP" <<'SUPERVISOR_EOF'
#!/bin/sh

SERVICE_VERSION="1.1"
SERVICE_GENERATION="4"
BIN="/mnt/us/filemanagers/bin/syncthing"
CONF="/mnt/us/filemanagers/settings"
DATA="/var/local/syncthing-filemanagers"
STATE="/var/local/kindle-syncthing-service"
PIDFILE="$STATE/syncthing.pid"
IFACEFILE="$STATE/service-firewall.iface"
MANUAL_IFACEFILE="$STATE/manual-firewall.iface"
LEGACY_IFACEFILE="$STATE/firewall.iface"
LEGACY_MANUAL_IFACEFILE="$STATE/manual-gui.iface"
LOG="$STATE/supervisor.log"
SYNCTHING_LOG="$DATA/syncthing.log"
HEALTH="$STATE/health.txt"
PUBLIC_HEALTH="/mnt/us/documents/SYNCTHING-ALWAYS-ON-HEALTH.txt"
FAILURE_ALERTED="$STATE/failure-alerted"
FIREWALL_CHAIN="KST_SYNCTHING"

CHECK_INTERVAL=20
NETWORK_RETRY_INTERVAL=5
START_GRACE=5
BACKOFF_INITIAL=2
BACKOFF_MAX=120
FIREWALL_EVERY=15
STABLE_LOOPS=15

PATH="/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/bin"
export PATH
umask 077

CHILD_PID=""
BACKOFF="$BACKOFF_INITIAL"
LOOPS=0
HEALTHY_LOOPS=0
FIREWALL_STATE="UNKNOWN"
FIREWALL_RULES_SUMMARY="none"
FIREWALL_CONFIG_WARNING=0

background_alert() {
    ALERT_TITLE="$1"
    ALERT_TEXT="$2"

    command -v lipc-set-prop >/dev/null 2>&1 || return 0
    ALERT_TITLE=$(printf '%s' "$ALERT_TITLE" | tr '\n\r\t' '   ' | sed 's/\\/\\\\/g; s/"/\\"/g')
    ALERT_TEXT=$(printf '%s' "$ALERT_TEXT" | tr '\n\r\t' '   ' | sed 's/\\/\\\\/g; s/"/\\"/g')
    ALERT_JSON='{ "clientParams":{ "alertId":"appAlert1", "show":true, "customStrings":[ { "matchStr":"alertTitle", "replaceStr":"'"$ALERT_TITLE"'" }, { "matchStr":"alertText", "replaceStr":"'"$ALERT_TEXT"'" } ] } }'
    lipc-set-prop com.lab126.pillow pillowAlert "$ALERT_JSON" >/dev/null 2>&1 || true
}

rotate_log() {
    if [ -f "$LOG" ]; then
        LOG_SIZE=$(wc -c < "$LOG" 2>/dev/null || echo 0)
        case "$LOG_SIZE" in
            ''|*[!0-9]*) LOG_SIZE=0 ;;
        esac

        if [ "$LOG_SIZE" -gt 131072 ]; then
            mv -f "$LOG" "$LOG.1" 2>/dev/null || true
        fi
    fi
}

log() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || date)" "$*" >> "$LOG"
}

write_health() {
    HEALTH_STATE="$1"
    HEALTH_DETAIL="$2"
    HEALTH_TMP="$STATE/.health.$$"
    PUBLIC_TMP="${PUBLIC_HEALTH}.tmp.$$"

    {
        printf 'STATE=%s\n' "$HEALTH_STATE"
        printf 'TIME=%s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || date)"
        printf 'SERVICE_VERSION=%s\n' "$SERVICE_VERSION"
        printf 'SERVICE_GENERATION=%s\n' "$SERVICE_GENERATION"
        [ -n "$CHILD_PID" ] && printf 'PID=%s\n' "$CHILD_PID"
        printf 'FIREWALL=%s\n' "$FIREWALL_STATE"
        printf 'RULES=%s\n' "$FIREWALL_RULES_SUMMARY"
        printf 'DETAIL=%s\n' "$HEALTH_DETAIL"
    } > "$HEALTH_TMP" 2>/dev/null || return 1

    chmod 0600 "$HEALTH_TMP" 2>/dev/null || true
    mv -f "$HEALTH_TMP" "$HEALTH" 2>/dev/null || return 1

    if [ -d /mnt/us/documents ]; then
        cp "$HEALTH" "$PUBLIC_TMP" 2>/dev/null && {
            chmod 0600 "$PUBLIC_TMP" 2>/dev/null || true
            mv -f "$PUBLIC_TMP" "$PUBLIC_HEALTH" 2>/dev/null || rm -f "$PUBLIC_TMP"
        }
    fi

    case "$HEALTH_STATE" in
        ERROR|RETRYING)
            if [ ! -e "$FAILURE_ALERTED" ]; then
                : > "$FAILURE_ALERTED" 2>/dev/null || true
                background_alert "Syncthing Always-On" "Background synchronization stopped or failed and is retrying. See SYNCTHING-ALWAYS-ON-HEALTH.txt for details."
            fi
            ;;
        RUNNING)
            if [ -e "$FAILURE_ALERTED" ]; then
                rm -f "$FAILURE_ALERTED"
                background_alert "Syncthing Always-On" "Background synchronization recovered and is running normally."
            fi
            ;;
    esac
    return 0
}

get_ipv4() {
    ip addr show "$1" 2>/dev/null | awk '
        $1 == "inet" {
            split($2, address, "/")
            if (address[1] != "127.0.0.1") {
                print address[1]
                exit
            }
        }
    '
}

get_iface() {
    DEFAULT_IFACE=$(ip route 2>/dev/null | awk '
        $1 == "default" {
            for (i = 1; i <= NF; i++) {
                if ($i == "dev" && (i + 1) <= NF) {
                    print $(i + 1)
                    exit
                }
            }
        }
    ')

    if [ -n "$DEFAULT_IFACE" ] && [ -n "$(get_ipv4 "$DEFAULT_IFACE")" ]; then
        printf '%s\n' "$DEFAULT_IFACE"
        return 0
    fi

    if ip link show wlan0 >/dev/null 2>&1 && [ -n "$(get_ipv4 wlan0)" ]; then
        printf '%s\n' "wlan0"
        return 0
    fi

    return 1
}

is_valid_port() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$1" -ge 1 ] 2>/dev/null && [ "$1" -le 65535 ] 2>/dev/null
}

add_firewall_rule() {
    RULE_PROTO="$1"
    RULE_PORT="$2"
    is_valid_port "$RULE_PORT" || return 1
    FIREWALL_RULES="${FIREWALL_RULES}${FIREWALL_RULES:+
}$RULE_PROTO $RULE_PORT"
}

build_firewall_rules() {
    INCLUDE_GUI="$1"
    FIREWALL_RULES=""
    FIREWALL_RULES_SUMMARY="none"
    FIREWALL_CONFIG_WARNING=0

    [ "$INCLUDE_GUI" = "1" ] && add_firewall_rule tcp 8384

    LISTEN_VALUES=$(tr '<' '\n' < "$CONF/config.xml" 2>/dev/null |
        sed -n 's/^listenAddress>\([^<]*\).*/\1/p' |
        tr ',' '\n')
    [ -n "$LISTEN_VALUES" ] || LISTEN_VALUES="default"

    while IFS= read -r LISTEN_VALUE; do
        LISTEN_VALUE=$(printf '%s' "$LISTEN_VALUE" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        [ -n "$LISTEN_VALUE" ] || continue

        case "$LISTEN_VALUE" in
            default)
                add_firewall_rule tcp 22000
                add_firewall_rule udp 22000
                ;;
            tcp://*|tcp4://*)
                LISTEN_PORT=${LISTEN_VALUE##*:}
                if is_valid_port "$LISTEN_PORT"; then
                    add_firewall_rule tcp "$LISTEN_PORT"
                else
                    FIREWALL_CONFIG_WARNING=1
                fi
                ;;
            quic://*|quic4://*)
                LISTEN_PORT=${LISTEN_VALUE##*:}
                if is_valid_port "$LISTEN_PORT"; then
                    add_firewall_rule udp "$LISTEN_PORT"
                else
                    FIREWALL_CONFIG_WARNING=1
                fi
                ;;
            tcp6://*|quic6://*)
                FIREWALL_CONFIG_WARNING=1
                ;;
            dynamic+*|relay://*)
                ;;
            *)
                FIREWALL_CONFIG_WARNING=1
                ;;
        esac
    done <<EOF
$LISTEN_VALUES
EOF

    LOCAL_ENABLED=$(tr '<' '\n' < "$CONF/config.xml" 2>/dev/null |
        sed -n 's/^localAnnounceEnabled>\([^<]*\).*/\1/p' |
        head -n 1)
    [ -n "$LOCAL_ENABLED" ] || LOCAL_ENABLED="true"

    if [ "$LOCAL_ENABLED" != "false" ]; then
        LOCAL_PORT=$(tr '<' '\n' < "$CONF/config.xml" 2>/dev/null |
            sed -n 's/^localAnnouncePort>\([^<]*\).*/\1/p' |
            head -n 1)
        [ -n "$LOCAL_PORT" ] || LOCAL_PORT=21027
        if is_valid_port "$LOCAL_PORT"; then
            add_firewall_rule udp "$LOCAL_PORT"
        else
            FIREWALL_CONFIG_WARNING=1
        fi
    fi

    FIREWALL_RULES=$(printf '%s\n' "$FIREWALL_RULES" |
        awk 'NF == 2 && !seen[$0]++ { print $1, $2 }')
    FIREWALL_RULES_SUMMARY=$(printf '%s\n' "$FIREWALL_RULES" |
        awk 'NF == 2 { if (out != "") out = out ","; out = out $1 ":" $2 } END { print out }')
    [ -n "$FIREWALL_RULES_SUMMARY" ] || FIREWALL_RULES_SUMMARY="none"
}

apply_firewall_rules() {
    printf '%s\n' "$FIREWALL_RULES" |
        while read -r APPLY_PROTO APPLY_PORT; do
            [ -n "$APPLY_PROTO" ] || continue
            case "$APPLY_PROTO" in tcp|udp) ;; *) exit 1 ;; esac
            is_valid_port "$APPLY_PORT" || exit 1
            iptables -A "$FIREWALL_CHAIN" -p "$APPLY_PROTO" --dport "$APPLY_PORT" -j ACCEPT >/dev/null 2>&1 || exit 1
        done
}

remove_direct_rule() {
    RULE_IFACE="$1"
    RULE_PORT="$2"
    RULE_PROTO="$3"

    [ -n "$RULE_IFACE" ] || return 0
    iptables -D INPUT -i "$RULE_IFACE" -p "$RULE_PROTO" --dport "$RULE_PORT" -j ACCEPT >/dev/null 2>&1 || true
}

remove_jump() {
    JUMP_IFACE="$1"
    [ -n "$JUMP_IFACE" ] || return 0
    while iptables -D INPUT -i "$JUMP_IFACE" -j "$FIREWALL_CHAIN" 2>/dev/null; do
        :
    done
}

remove_legacy_firewall() {
    for LEGACY_FILE in "$LEGACY_IFACEFILE" "$LEGACY_MANUAL_IFACEFILE"; do
        [ -s "$LEGACY_FILE" ] || continue
        LEGACY_IFACE=$(cat "$LEGACY_FILE" 2>/dev/null)
        if [ -n "$LEGACY_IFACE" ]; then
            remove_direct_rule "$LEGACY_IFACE" 8384 tcp
            remove_direct_rule "$LEGACY_IFACE" 22000 tcp
            remove_direct_rule "$LEGACY_IFACE" 22000 udp
            remove_direct_rule "$LEGACY_IFACE" 21027 udp
        fi
        rm -f "$LEGACY_FILE"
    done
}

remove_firewall() {
    OLD_SERVICE_IFACE=""
    OLD_MANUAL_IFACE=""
    CURRENT_IFACE=""

    [ -s "$IFACEFILE" ] && OLD_SERVICE_IFACE=$(cat "$IFACEFILE" 2>/dev/null)
    [ -s "$MANUAL_IFACEFILE" ] && OLD_MANUAL_IFACE=$(cat "$MANUAL_IFACEFILE" 2>/dev/null)
    CURRENT_IFACE=$(get_iface 2>/dev/null || true)

    for CLEAN_IFACE in "$OLD_SERVICE_IFACE" "$OLD_MANUAL_IFACE" "$CURRENT_IFACE"; do
        remove_jump "$CLEAN_IFACE"
    done

    iptables -F "$FIREWALL_CHAIN" >/dev/null 2>&1 || true
    iptables -X "$FIREWALL_CHAIN" >/dev/null 2>&1 || true
    rm -f "$IFACEFILE" "$MANUAL_IFACEFILE"
}

refresh_firewall() {
    ACTIVE_IFACE=$(get_iface 2>/dev/null || true)
    remove_legacy_firewall
    remove_firewall

    if [ -z "$ACTIVE_IFACE" ]; then
        FIREWALL_STATE="NO_NETWORK"
        return 2
    fi

    if ! iptables -N "$FIREWALL_CHAIN" >/dev/null 2>&1; then
        iptables -F "$FIREWALL_CHAIN" >/dev/null 2>&1 || {
            FIREWALL_STATE="ERROR"
            return 1
        }
    fi

    iptables -F "$FIREWALL_CHAIN" >/dev/null 2>&1 || {
        FIREWALL_STATE="ERROR"
        return 1
    }

    build_firewall_rules 0
    if ! apply_firewall_rules; then
        FIREWALL_STATE="ERROR"
        remove_firewall
        return 1
    fi
    iptables -A INPUT -i "$ACTIVE_IFACE" -j "$FIREWALL_CHAIN" >/dev/null 2>&1 || {
        FIREWALL_STATE="ERROR"
        remove_firewall
        return 1
    }

    if ! printf '%s\n' "$ACTIVE_IFACE" > "$IFACEFILE"; then
        FIREWALL_STATE="ERROR"
        remove_firewall
        return 1
    fi

    if [ "$FIREWALL_CONFIG_WARNING" = "1" ]; then
        FIREWALL_STATE="OK_WITH_WARNING"
        return 3
    fi

    FIREWALL_STATE="OK"
    return 0
}

firewall_needs_refresh() {
    case "$FIREWALL_STATE" in
        OK|OK_WITH_WARNING) ;;
        *) return 0 ;;
    esac

    CURRENT_IFACE=$(get_iface 2>/dev/null || true)
    INSTALLED_IFACE=""
    [ -s "$IFACEFILE" ] && INSTALLED_IFACE=$(cat "$IFACEFILE" 2>/dev/null)

    [ "$CURRENT_IFACE" = "$INSTALLED_IFACE" ] || return 0
    [ "$LOOPS" -ge "$FIREWALL_EVERY" ]
}

pid_start_time() {
    [ -r "/proc/$1/stat" ] || return 1
    awk '{ print $22 }' "/proc/$1/stat" 2>/dev/null
}

pid_state() {
    [ -r "/proc/$1/stat" ] || return 1
    awk '{ print $3 }' "/proc/$1/stat" 2>/dev/null
}

stop_pid() {
    STOP_PID="$1"
    [ -n "$STOP_PID" ] || return 0

    STOP_START=$(pid_start_time "$STOP_PID")
    [ -n "$STOP_START" ] || return 0
    kill "$STOP_PID" 2>/dev/null || return 0

    STOP_WAIT=0
    while kill -0 "$STOP_PID" 2>/dev/null && [ "$STOP_WAIT" -lt 10 ]; do
        [ "$(pid_state "$STOP_PID" 2>/dev/null)" = "Z" ] && return 0
        sleep 1
        STOP_WAIT=$((STOP_WAIT + 1))
    done

    [ "$(pid_start_time "$STOP_PID" 2>/dev/null)" = "$STOP_START" ] || return 0
    [ "$(pid_state "$STOP_PID" 2>/dev/null)" = "Z" ] && return 0
    kill -9 "$STOP_PID" 2>/dev/null || true
}

pid_uses_filemanagers_binary() {
    CHECK_PID="$1"
    [ -n "$CHECK_PID" ] || return 1
    [ -r "/proc/$CHECK_PID/cmdline" ] || return 1

    CHECK_ARGS=$(tr '\000' '\n' < "/proc/$CHECK_PID/cmdline" 2>/dev/null)
    CHECK_ARG0=$(printf '%s\n' "$CHECK_ARGS" | sed -n '1p')
    CHECK_ARG1=$(printf '%s\n' "$CHECK_ARGS" | sed -n '2p')
    [ "$CHECK_ARG0" = "$BIN" ] || [ "$CHECK_ARG1" = "$BIN" ]
}

pid_has_arg() {
    CHECK_PID="$1"
    CHECK_ARG="$2"
    [ -r "/proc/$CHECK_PID/cmdline" ] || return 1
    tr '\000' '\n' < "/proc/$CHECK_PID/cmdline" 2>/dev/null |
        grep -F -x -e "$CHECK_ARG" >/dev/null 2>&1
}

pid_is_config_data_syncthing() {
    CHECK_PID="$1"
    pid_uses_filemanagers_binary "$CHECK_PID" || return 1
    pid_has_arg "$CHECK_PID" "--config=$CONF" || return 1
    pid_has_arg "$CHECK_PID" "--data=$DATA"
}

pid_is_legacy_syncthing() {
    CHECK_PID="$1"
    pid_uses_filemanagers_binary "$CHECK_PID" || return 1
    pid_has_arg "$CHECK_PID" "--home=$CONF" && return 0
    pid_has_arg "$CHECK_PID" "-home=$CONF"
}

pid_is_managed_syncthing() {
    CHECK_PID="$1"
    pid_is_config_data_syncthing "$CHECK_PID" && return 0
    pid_is_legacy_syncthing "$CHECK_PID"
}

child_is_syncthing() {
    [ -n "$CHILD_PID" ] || return 1
    pid_is_config_data_syncthing "$CHILD_PID" || return 1
    pid_has_arg "$CHILD_PID" "--gui-address=127.0.0.1:8384"
}

stop_stale_syncthing() {
    for FOUND_PID in $(pidof syncthing 2>/dev/null); do
        if [ -n "$CHILD_PID" ] && [ "$FOUND_PID" = "$CHILD_PID" ]; then
            continue
        fi
        if pid_is_managed_syncthing "$FOUND_PID"; then
            stop_pid "$FOUND_PID"
        fi
    done
}

wait_for_files() {
    WAIT_COUNT=0

    while [ ! -x "$BIN" ] || [ ! -s "$CONF/config.xml" ] || [ ! -s "$CONF/cert.pem" ] || [ ! -s "$CONF/key.pem" ]; do
        if [ "$WAIT_COUNT" -eq 0 ]; then
            log "waiting for Syncthing binary and identity files"
            FIREWALL_STATE="CLOSED"
            write_health "WAITING_FOR_FILES" "Syncthing binary or identity files are unavailable" || true
        fi

        sleep 10
        WAIT_COUNT=$((WAIT_COUNT + 1))

        if [ "$WAIT_COUNT" -ge 6 ]; then
            log "still waiting for Syncthing binary and identity files"
            WAIT_COUNT=0
        fi
    done
}

start_child() {
    stop_stale_syncthing

    refresh_firewall
    FIREWALL_RC=$?
    if [ "$FIREWALL_RC" = "1" ]; then
        log "firewall configuration failed"
        write_health "ERROR" "Unable to configure Syncthing firewall rules" || true
        return 1
    fi

    mkdir -p "$DATA" "$STATE" || return 1
    chmod 0700 "$DATA" "$STATE" 2>/dev/null || true

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
    printf '%s\n' "$CHILD_PID" > "$PIDFILE"
    log "started Syncthing pid=$CHILD_PID"

    if [ "$FIREWALL_STATE" = "NO_NETWORK" ]; then
        write_health "STARTING_OFFLINE" "Syncthing is starting; no active network interface is available yet" || true
    else
        write_health "STARTING_CHILD" "Syncthing process started; validating startup" || true
    fi

    sleep "$START_GRACE"

    if kill -0 "$CHILD_PID" 2>/dev/null && child_is_syncthing; then
        if [ "$FIREWALL_STATE" = "NO_NETWORK" ]; then
            write_health "RUNNING_OFFLINE" "Syncthing is running; no active network interface is available" || true
        elif [ "$FIREWALL_STATE" = "OK_WITH_WARNING" ]; then
            write_health "RUNNING_WITH_WARNING" "Syncthing is running; one or more listener settings could not be represented in the IPv4 firewall" || true
        else
            write_health "RUNNING" "Syncthing is running normally" || true
        fi
        return 0
    fi

    if kill -0 "$CHILD_PID" 2>/dev/null; then
        log "unexpected process identity during startup; leaving pid=$CHILD_PID untouched"
    fi

    wait "$CHILD_PID" 2>/dev/null
    CHILD_RC=$?
    log "Syncthing exited during startup rc=$CHILD_RC"
    CHILD_PID=""
    rm -f "$PIDFILE"
    write_health "RETRYING" "Syncthing did not complete startup; retry scheduled" || true
    return 1
}

increase_backoff() {
    BACKOFF=$((BACKOFF * 2))
    [ "$BACKOFF" -gt "$BACKOFF_MAX" ] && BACKOFF="$BACKOFF_MAX"
}

cleanup() {
    trap - HUP INT TERM
    log "stopping supervisor"
    if child_is_syncthing; then
        stop_pid "$CHILD_PID"
        wait "$CHILD_PID" 2>/dev/null || true
    fi
    CHILD_PID=""
    rm -f "$PIDFILE"
    remove_firewall
    FIREWALL_STATE="CLOSED"
    write_health "STOPPED" "Supervisor stopped" || true
    exit 0
}

trap cleanup HUP INT TERM

mkdir -p "$STATE" "$DATA" 2>/dev/null || exit 1
chmod 0700 "$STATE" "$DATA" 2>/dev/null || true
rotate_log
log "supervisor started"
FIREWALL_STATE="CLOSED"
write_health "STARTING" "Supervisor started" || true

while :; do
    wait_for_files

    if [ -z "$CHILD_PID" ]; then
        if start_child; then
            HEALTHY_LOOPS=0
        else
            log "retrying Syncthing in ${BACKOFF}s"
            write_health "RETRYING" "Retrying Syncthing in ${BACKOFF}s" || true
            sleep "$BACKOFF"
            increase_backoff
            continue
        fi
    elif ! kill -0 "$CHILD_PID" 2>/dev/null || ! child_is_syncthing; then
        wait "$CHILD_PID" 2>/dev/null
        CHILD_RC=$?
        log "Syncthing exited rc=$CHILD_RC"
        CHILD_PID=""
        rm -f "$PIDFILE"
        HEALTHY_LOOPS=0
        write_health "RETRYING" "Syncthing exited; retrying in ${BACKOFF}s" || true
        sleep "$BACKOFF"
        increase_backoff
        continue
    else
        HEALTHY_LOOPS=$((HEALTHY_LOOPS + 1))
        if [ "$HEALTHY_LOOPS" -ge "$STABLE_LOOPS" ]; then
            BACKOFF="$BACKOFF_INITIAL"
            HEALTHY_LOOPS="$STABLE_LOOPS"
        fi
    fi

    LOOPS=$((LOOPS + 1))

    if firewall_needs_refresh; then
        refresh_firewall
        FIREWALL_RC=$?
        if [ "$FIREWALL_RC" = "1" ]; then
            log "firewall refresh failed"
            write_health "RUNNING_WITH_WARNING" "Syncthing is running, but firewall refresh failed" || true
        elif [ "$FIREWALL_RC" = "2" ]; then
            write_health "RUNNING_OFFLINE" "Syncthing is running; no active network interface is available" || true
        elif [ "$FIREWALL_RC" = "3" ]; then
            write_health "RUNNING_WITH_WARNING" "Syncthing is running; one or more listener settings could not be represented in the IPv4 firewall" || true
        else
            write_health "RUNNING" "Syncthing is running normally" || true
        fi
        LOOPS=0
    fi

    case "$FIREWALL_STATE" in
        OK|OK_WITH_WARNING) sleep "$CHECK_INTERVAL" ;;
        *) sleep "$NETWORK_RETRY_INTERVAL" ;;
    esac
done
SUPERVISOR_EOF

/bin/sh -n "$SUPERVISOR_TMP" >/dev/null 2>&1 || {
    rm -f "$SUPERVISOR_TMP"
    fail "generated supervisor failed shell syntax validation"
}
chmod 0700 "$SUPERVISOR_TMP" || {
    rm -f "$SUPERVISOR_TMP"
    fail "unable to secure generated supervisor"
}
mv -f "$SUPERVISOR_TMP" "$SUPERVISOR" || fail "unable to install supervisor"
INSTALL_CHANGED=1

screen "Syncthing Always-On: installing startup service..."
stop_manual_mode
stop_jobs || fail "unable to stop an existing Syncthing startup job"
sleep 2
stop_managed_syncthing

mntroot rw >/dev/null 2>&1 || fail "unable to remount root filesystem read-write"
ROOT_RW=1

rm -f \
    "$UPSTART_DIR/syncthing.conf" \
    "$UPSTART_DIR/syncthing-watchdog.conf" \
    "$UPSTART_DIR/syncthing-news.conf" \
    "$UPSTART_DIR/kindle-syncthing.conf"

JOB_TMP="$UPSTART_DIR/.kindle-syncthing.conf.$$"
cat > "$JOB_TMP" <<'JOB_EOF'
description "Kindle Syncthing service"

start on started wmt
stop on stopping filesystems

respawn
respawn limit 10 300
kill timeout 30

exec /bin/sh /var/local/kindle-syncthing-service/supervisor.sh
JOB_EOF

chmod 0644 "$JOB_TMP" || fail "unable to set Upstart job permissions"
mv -f "$JOB_TMP" "$JOB" || fail "unable to install Upstart job"
sync

mntroot ro >/dev/null 2>&1 || fail "unable to restore root filesystem read-only"
ROOT_RW=0

initctl reload-configuration >/dev/null 2>&1 || fail "unable to reload Upstart configuration"

screen "Syncthing Always-On: starting service..."
start_service || fail "always-on service did not start; check $HEALTH"

RUN_PID=$(service_child_pid)
echo "INSTALL_TEST=PASS"
echo "START_PID=$RUN_PID"

screen "Syncthing Always-On: testing automatic recovery..."
OLD_PID="$RUN_PID"
kill "$OLD_PID" 2>/dev/null || fail "unable to run supervisor recovery test"

RECOVERY_WAIT=0
NEW_PID=""
while [ "$RECOVERY_WAIT" -lt 45 ]; do
    NEW_PID=$(service_child_pid 2>/dev/null || true)

    if [ -n "$NEW_PID" ] && [ "$NEW_PID" != "$OLD_PID" ] && kill -0 "$NEW_PID" 2>/dev/null && service_healthy; then
        break
    fi

    sleep 1
    RECOVERY_WAIT=$((RECOVERY_WAIT + 1))
done

if [ -z "$NEW_PID" ] || [ "$NEW_PID" = "$OLD_PID" ] || ! kill -0 "$NEW_PID" 2>/dev/null; then
    fail "supervisor recovery test failed; check $HEALTH and $STATE/supervisor.log"
fi

status "$SERVICE" 2>/dev/null | grep -q 'start/running' || fail "Upstart supervisor is not running"

INSTALL_CHANGED=0
JOBS_STOPPED=0

echo "RECOVERY_TEST=PASS"
echo "RECOVERY_PID=$NEW_PID"
echo "ACTION=INSTALL_OR_UPDATE"
echo "CONFIG=$CONF"
echo "DATA=$DATA"
echo "GUI_BIND=127.0.0.1:8384"
echo "HEALTH_FILE=$HEALTH"
report_service_state
echo "RESULT=$SERVICE_RESULT"

screen "Install and recovery checks passed."
screen "Startup service is installed."
screen "Details: $OUT"
