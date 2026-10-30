#!/bin/sh
# Keep the HDMI output active, HDMI audio present and Kodi alive.
# Also suspend Kodi when the TV is switched off (HDMI sink disconnects) and
# start it again when the TV comes back.
#
# The HDMI link often flaps for a few seconds while a TV wakes up, so Kodi is
# only started after the link has been stable for CONNECT_STABLE_TICKS, and
# only stopped after OFFLINE_STOP_TICKS of continuous disconnect.
#
# Every external call is wrapped in timeout(1): a wedged X/GPU must not hang
# the watchdog.  Xorg is only restarted via rc.d/kodidisplay (which locks).

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin

MODE=1920x1080
RATE=60
INTERVAL=10
CONNECT_STABLE_TICKS=2	# ~20 s of connected link before Kodi is started
OFFLINE_STOP_TICKS=3	# ~30 s of disconnected link before Kodi is stopped
LOG=/var/log/kodiwatchdog.log
MSG_LOG=/var/log/messages
MSG_CAP=67108864	# 64 MiB - guard against kernel log floods
XTMO=6
REPROBE=/usr/local/bin/hdmi-audio-reprobe

export DISPLAY=:0

log() { echo "$(date "+%Y-%m-%d %H:%M:%S") $*" >> "$LOG"; }
x_up() { pgrep -q -f "Xorg :0"; }
kodi_up() { pgrep -x kodi.bin >/dev/null 2>&1; }
xrandr_t() { timeout "$XTMO" /usr/local/bin/xrandr "$@"; }

# The default newsyslog checks sizes only hourly, so a kernel print loop can
# fill the disk; cap /var/log/messages and let syslogd reopen it.
check_messages() {
    [ -f "$MSG_LOG" ] || return 0
    size=$(stat -f %z "$MSG_LOG" 2>/dev/null) || return 0
    if [ "$size" -gt "$MSG_CAP" ]; then
        log "WARNING: $MSG_LOG grew to ${size} bytes (kernel log flood?) - truncating"
        : > "$MSG_LOG"
        pid=$(cat /var/run/syslog.pid 2>/dev/null)
        [ -n "$pid" ] && kill -HUP "$pid" 2>/dev/null
    fi
}

ensure_audio() {
    if grep -q '^pcm' /dev/sndstat; then
        return 0
    fi
    timeout 60 "$REPROBE"
}

start_kodi() {
    if kodi_up; then
        return 0
    fi
    log "starting Kodi"
    /usr/sbin/daemon -o /var/log/kodi-run.log -p /var/run/kodi.pid \
        /usr/bin/env DISPLAY=:0 HOME=/root /usr/local/bin/kodi
}

stop_kodi() {
    log "TV off - stopping Kodi"
    # graceful quit first (saves settings/library state)
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"Application.Quit"}' \
        | nc -6 -N ::1 9090 >/dev/null 2>&1
    i=0
    while [ "$i" -lt 10 ] && kodi_up; do
        sleep 1
        i=$((i+1))
    done
    if kodi_up; then
        pkill -TERM -f kodi.bin 2>/dev/null
        i=0
        while [ "$i" -lt 5 ] && kodi_up; do
            sleep 1
            i=$((i+1))
        done
    fi
    if kodi_up; then
        pkill -9 -f kodi.bin 2>/dev/null
    fi
    log "Kodi stopped"
}

restart_kodi() {
    log "restarting Kodi (to pick up display/audio state)"
    pkill -TERM -f kodi.bin 2>/dev/null
    sleep 3
    pkill -9 -f kodi.bin 2>/dev/null
    start_kodi
}

restart_display() {
    log "restarting display stack"
    pkill -9 -f "kodi.bin" 2>/dev/null
    pkill -9 -f "Xorg :0" 2>/dev/null
    sleep 3
    rm -f /tmp/.X11-unix/X0 /tmp/.X0-lock
    /usr/local/etc/rc.d/kodidisplay onestart </dev/null >/dev/null 2>&1
}

sink=unknown
connected_ticks=0
offline_ticks=0
log "watchdog started (start after ${CONNECT_STABLE_TICKS}, stop after ${OFFLINE_STOP_TICKS} ticks)"

while :; do
    if ! x_up; then
        log "Xorg is not running"
        restart_display
        sink=unknown
        connected_ticks=0
        offline_ticks=0
        sleep 20
        continue
    fi

    if ! line=$(xrandr_t 2>/dev/null | grep '^HDMI-1'); then
        log "X server unresponsive (xrandr timed out) - not restarting anything"
        sleep 30
        continue
    fi

    case "$line" in
        *" connected primary "[0-9]*)
            offline_ticks=0
            if [ "$sink" != connected ]; then
                log "HDMI-1 connected and active"
                sink=connected
            fi
            connected_ticks=$((connected_ticks+1))
            if ! kodi_up; then
                if [ "$connected_ticks" -ge "$CONNECT_STABLE_TICKS" ]; then
                    ensure_audio || log "audio codec still missing (TV on)"
                    start_kodi
                fi
            fi
            ;;
        *" connected "*)
            offline_ticks=0
            if [ "$sink" != connected ]; then
                log "HDMI-1 connected (inactive)"
                sink=connected
                connected_ticks=0
            fi
            connected_ticks=$((connected_ticks+1))
            log "HDMI-1 connected but inactive - re-enabling"
            xrandr_t --output HDMI-1 --mode "$MODE" --rate "$RATE" --primary >/dev/null 2>&1
            sleep 2
            ensure_audio && log "audio codec reprobe ok after re-enable"
            if [ "$connected_ticks" -ge "$CONNECT_STABLE_TICKS" ]; then
                if kodi_up; then
                    restart_kodi
                else
                    start_kodi
                fi
            fi
            ;;
        *" disconnected "*)
            connected_ticks=0
            if [ "$sink" != disconnected ]; then
                log "HDMI-1 disconnected (TV off?)"
                sink=disconnected
                offline_ticks=0
            fi
            offline_ticks=$((offline_ticks+1))
            if [ "$offline_ticks" -ge "$OFFLINE_STOP_TICKS" ] && kodi_up; then
                stop_kodi
            fi
            ;;
        *)
            log "HDMI-1 state not recognised: $line"
            ;;
    esac

    check_messages
    sleep "$INTERVAL"
done
