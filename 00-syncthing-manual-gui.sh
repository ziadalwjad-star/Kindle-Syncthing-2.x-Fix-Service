#!/bin/sh
# Name: Syncthing Manual GUI

VERSION="1.1"
BIN="/mnt/us/filemanagers/bin/syncthing"
CONF="/mnt/us/filemanagers/settings"
DATA="/var/local/syncthing-filemanagers"
STATE="/var/local/kindle-syncthing-service"
SERVICE="kindle-syncthing"
OUT="/mnt/us/documents/SYNCTHING-MANUAL-GUI-STATUS.txt"
LOG="$STATE/manual-gui.log"
PIDFILE="$STATE/manual-gui.pid"
IFACEFILE="$STATE/manual-firewall.iface"
SERVICE_IFACEFILE="$STATE/service-firewall.iface"
LEGACY_MANUAL_IFACEFILE="$STATE/manual-gui.iface"
LEGACY_SERVICE_IFACEFILE="$STATE/firewall.iface"
LOCKDIR="$STATE/action.lock"
FIREWALL_CHAIN="KST_SYNCTHING"

PATH="/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/bin"
export PATH
umask 077

LOCK_HELD=0
FIREWALL_ACTIVE=0
FIREWALL_RESULT="UNKNOWN"
FIREWALL_RULES_SUMMARY="none"
FIREWALL_CONFIG_WARNING=0
MANUAL_PID=""
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

on_exit() {
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

remove_firewall() {
    OLD_MANUAL_IFACE=""
    OLD_SERVICE_IFACE=""
    CURRENT_IFACE=""

    [ -s "$IFACEFILE" ] && OLD_MANUAL_IFACE=$(cat "$IFACEFILE" 2>/dev/null)
    [ -s "$SERVICE_IFACEFILE" ] && OLD_SERVICE_IFACE=$(cat "$SERVICE_IFACEFILE" 2>/dev/null)
    CURRENT_IFACE=$(get_iface 2>/dev/null || true)

    for CLEAN_IFACE in "$OLD_MANUAL_IFACE" "$OLD_SERVICE_IFACE" "$CURRENT_IFACE"; do
        remove_jump "$CLEAN_IFACE"
    done

    iptables -F "$FIREWALL_CHAIN" >/dev/null 2>&1 || true
    iptables -X "$FIREWALL_CHAIN" >/dev/null 2>&1 || true
    rm -f "$IFACEFILE" "$SERVICE_IFACEFILE"
    FIREWALL_ACTIVE=0
}

open_firewall() {
    OPEN_IFACE="$1"

    remove_legacy_firewall
    remove_firewall

    if ! iptables -N "$FIREWALL_CHAIN" >/dev/null 2>&1; then
        iptables -F "$FIREWALL_CHAIN" >/dev/null 2>&1 || return 1
    fi

    iptables -F "$FIREWALL_CHAIN" >/dev/null 2>&1 || return 1

    build_firewall_rules 1
    if ! apply_firewall_rules; then
        remove_firewall
        return 1
    fi
    iptables -A INPUT -i "$OPEN_IFACE" -j "$FIREWALL_CHAIN" >/dev/null 2>&1 || {
        remove_firewall
        return 1
    }

    if ! printf '%s\n' "$OPEN_IFACE" > "$IFACEFILE"; then
        remove_firewall
        return 1
    fi

    FIREWALL_ACTIVE=1
    if [ "$FIREWALL_CONFIG_WARNING" = "1" ]; then
        FIREWALL_RESULT="OK_WITH_WARNING"
    else
        FIREWALL_RESULT="OK"
    fi
    return 0
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

pid_is_ours() {
    pid_is_config_data_syncthing "$1"
}

pid_is_manual_syncthing() {
    CHECK_PID="$1"
    pid_is_ours "$CHECK_PID" || return 1

    pid_has_arg "$CHECK_PID" "--gui-address=https://$IP:8384"
}

stop_managed_syncthing() {
    for FOUND_PID in $(pidof syncthing 2>/dev/null); do
        if pid_is_managed_syncthing "$FOUND_PID"; then
            stop_pid "$FOUND_PID"
        fi
    done
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

restore_jobs() {
    [ "$JOBS_STOPPED" = "1" ] || return 0

    RESTORE_FAILED=0
    [ "$SERVICE_WAS_RUNNING" = "1" ] && start "$SERVICE" >/dev/null 2>&1 || {
        [ "$SERVICE_WAS_RUNNING" = "1" ] && RESTORE_FAILED=1
    }
    [ "$NEWS_WAS_RUNNING" = "1" ] && start syncthing-news >/dev/null 2>&1 || {
        [ "$NEWS_WAS_RUNNING" = "1" ] && RESTORE_FAILED=1
    }
    [ "$WATCHDOG_WAS_RUNNING" = "1" ] && start syncthing-watchdog >/dev/null 2>&1 || {
        [ "$WATCHDOG_WAS_RUNNING" = "1" ] && RESTORE_FAILED=1
    }
    [ "$LEGACY_WAS_RUNNING" = "1" ] && start syncthing >/dev/null 2>&1 || {
        [ "$LEGACY_WAS_RUNNING" = "1" ] && RESTORE_FAILED=1
    }

    [ "$RESTORE_FAILED" = "0" ]
}

cleanup_failed_start() {
    ROLLBACK_NEEDED=0

    if [ -n "$MANUAL_PID" ] && pid_is_ours "$MANUAL_PID"; then
        stop_pid "$MANUAL_PID"
        ROLLBACK_NEEDED=1
    fi
    MANUAL_PID=""
    rm -f "$PIDFILE"

    if [ "$FIREWALL_ACTIVE" = "1" ]; then
        remove_firewall
        ROLLBACK_NEEDED=1
    fi

    [ "$JOBS_STOPPED" = "1" ] && ROLLBACK_NEEDED=1
    [ "$ROLLBACK_NEEDED" = "1" ] || return 0

    if restore_jobs; then
        echo "ROLLBACK=SUCCESS"
    else
        echo "ROLLBACK=PARTIAL"
    fi
}

fail() {
    trap - HUP INT TERM
    cleanup_failed_start
    echo
    echo "RESULT=FAIL"
    echo "ERROR=$1"
    screen "Syncthing Manual GUI: FAILED"
    screen "Reason: $1"
    screen "Details: $OUT"
    alert "Syncthing Manual GUI" "Failed: $1. See $OUT for details."
    exit 1
}

trap on_exit EXIT

if [ "$(id -u 2>/dev/null)" != "0" ]; then
    screen "Syncthing Manual GUI: FAILED"
    screen "Reason: root privileges are required"
    alert "Syncthing Manual GUI" "Failed: root privileges are required."
    exit 1
fi

mkdir -p "$STATE" || {
    screen "Syncthing Manual GUI: FAILED"
    screen "Reason: unable to create runtime state directory"
    alert "Syncthing Manual GUI" "Failed: unable to create runtime state directory."
    exit 1
}
chmod 0700 "$STATE" 2>/dev/null || true

if ! acquire_lock; then
    screen "Syncthing Manual GUI: BUSY"
    screen "Another Syncthing mode change is already running."
    alert "Syncthing Manual GUI" "Busy: another Syncthing mode change is already running."
    exit 1
fi

if ! : > "$OUT"; then
    screen "Syncthing Manual GUI: FAILED"
    screen "Reason: unable to write $OUT"
    alert "Syncthing Manual GUI" "Failed: unable to write the status file."
    exit 1
fi
chmod 0600 "$OUT" 2>/dev/null || true
exec >>"$OUT" 2>&1

trap 'fail "operation interrupted"' HUP INT TERM

printf '%s\n' "Syncthing Manual GUI"
printf '%s\n' "VERSION=$VERSION"
date
echo
screen "Syncthing Manual GUI: checking configuration..."
alert "Syncthing Manual GUI" "Starting. Checking secure LAN GUI configuration..."

for CMD in ip iptables nohup pidof start status stop; do
    command -v "$CMD" >/dev/null 2>&1 || fail "required command is unavailable: $CMD"
done

[ -f "$BIN" ] || fail "Syncthing binary not found at $BIN"
[ -x "$BIN" ] || fail "Syncthing binary is not executable"

for FILE in "$CONF/config.xml" "$CONF/cert.pem" "$CONF/key.pem"; do
    [ -s "$FILE" ] || fail "missing required Syncthing file: $FILE"
done

mkdir -p "$DATA" || fail "unable to create Syncthing data directory"
chmod 0700 "$DATA" "$STATE" 2>/dev/null || true

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

DEVICE_ID=$("$BIN" --config="$CONF" --data="$DATA" device-id 2>/dev/null | tail -n 1)
[ -n "$DEVICE_ID" ] || fail "unable to read Syncthing device identity"
echo "IDENTITY=OK"

GUI_XML=$(awk '
    /<gui[ >]/ { inside = 1 }
    inside { print }
    /<\/gui>/ { exit }
' "$CONF/config.xml")

GUI_ENABLED=$(printf '%s\n' "$GUI_XML" |
    sed -n 's/.*<gui[^>]*enabled="\([^"]*\)".*/\1/p' |
    head -n 1)
GUI_USER=$(printf '%s\n' "$GUI_XML" |
    sed -n 's|.*<user>\(.*\)</user>.*|\1|p' |
    head -n 1)
GUI_PASSWORD=$(printf '%s\n' "$GUI_XML" |
    sed -n 's|.*<password>\(.*\)</password>.*|\1|p' |
    head -n 1)
GUI_INSECURE=$(printf '%s\n' "$GUI_XML" |
    sed -n 's|.*<insecureAdminAccess>\(.*\)</insecureAdminAccess>.*|\1|p' |
    head -n 1)
GUI_AUTH_MODE=$(printf '%s\n' "$GUI_XML" |
    sed -n 's|.*<authMode>\(.*\)</authMode>.*|\1|p' |
    head -n 1)

[ "$GUI_ENABLED" != "false" ] || fail "Syncthing GUI is disabled in config.xml"
[ "$GUI_INSECURE" != "true" ] || fail "insecureAdminAccess is enabled; LAN GUI exposure was refused"
[ -z "$GUI_AUTH_MODE" ] || [ "$GUI_AUTH_MODE" = "static" ] || fail "unsupported GUI authentication mode: $GUI_AUTH_MODE"
[ -n "$GUI_USER" ] || fail "GUI username is not configured; LAN GUI exposure was refused"
[ -n "$GUI_PASSWORD" ] || fail "GUI password is not configured; LAN GUI exposure was refused"

IFACE=$(get_iface)
[ -n "$IFACE" ] || fail "no active network interface with IPv4 connectivity was found"

IP=$(get_ipv4 "$IFACE")
[ -n "$IP" ] || fail "no IPv4 address is available; connect Wi-Fi and try again"
GUI_URL="https://$IP:8384"

if [ -s "$PIDFILE" ]; then
    EXISTING_PID=$(cat "$PIDFILE" 2>/dev/null)
    if [ -n "$EXISTING_PID" ] && kill -0 "$EXISTING_PID" 2>/dev/null && pid_is_manual_syncthing "$EXISTING_PID"; then
        echo "MODE=manual-gui"
        echo "PID=$EXISTING_PID"
        echo "GUI=$GUI_URL"
        echo "RESULT=ALREADY_RUNNING"
        screen "Syncthing Manual GUI: already running"
        screen "Open: $GUI_URL"
        screen "Details: $OUT"
        alert "Syncthing Manual GUI" "Already running. Open $GUI_URL"
        exit 0
    fi
    rm -f "$PIDFILE"
fi

remember_jobs
screen "Syncthing Manual GUI: stopping background Syncthing..."
stop_jobs || fail "unable to stop an existing Syncthing startup job"
sleep 2
stop_managed_syncthing

open_firewall "$IFACE" || fail "unable to configure the Kindle firewall safely"

echo "FIREWALL=$FIREWALL_RESULT"
echo "FIREWALL_RULES=$FIREWALL_RULES_SUMMARY"
if [ "$FIREWALL_CONFIG_WARNING" = "1" ]; then
    echo "FIREWALL_CONFIG=WARNING"
    screen "Syncthing Manual GUI: firewall rules were applied, but a listener setting could not be represented safely in the IPv4 firewall."
fi
: > "$LOG" || fail "unable to create manual GUI log"
chmod 0600 "$LOG" 2>/dev/null || true

HOME="$STATE"
TMPDIR="/tmp"
USER="root"
LOGNAME="root"
export HOME TMPDIR USER LOGNAME

screen "Syncthing Manual GUI: starting secure LAN GUI..."
nohup "$BIN" \
    --config="$CONF" \
    --data="$DATA" \
    serve \
    --no-browser \
    --no-upgrade \
    --no-restart \
    --gui-address="$GUI_URL" \
    --log-file="$DATA/syncthing.log" \
    --log-max-size=1048576 \
    --log-max-old-files=2 \
    </dev/null >>"$LOG" 2>&1 3>&- &

MANUAL_PID=$!
printf '%s\n' "$MANUAL_PID" > "$PIDFILE"
sleep 8

if ! kill -0 "$MANUAL_PID" 2>/dev/null || ! pid_is_manual_syncthing "$MANUAL_PID"; then
    echo
    echo "Syncthing exited or changed process identity during startup."
    tail -n 100 "$LOG" 2>/dev/null || true
    fail "manual GUI startup failed"
fi

printf '%s\n' "MODE=manual-gui"
printf '%s\n' "PID=$MANUAL_PID"
printf '%s\n' "GUI=$GUI_URL"
printf '%s\n' "GUI_AUTH=required"
printf '%s\n' "GUI_TLS=forced-for-manual-mode"
printf '%s\n' "CONFIG=$CONF"
printf '%s\n' "DATA=$DATA"
printf '%s\n' "RESULT=SUCCESS"

screen "Syncthing Manual GUI: READY"
screen "Open: $GUI_URL"
screen "Login with your existing Syncthing credentials."
screen "A browser certificate warning is expected with Syncthing's local HTTPS certificate."
screen "Details: $OUT"
alert "Syncthing Manual GUI" "Ready. Open $GUI_URL. A certificate warning is expected for Syncthing's local HTTPS certificate."
