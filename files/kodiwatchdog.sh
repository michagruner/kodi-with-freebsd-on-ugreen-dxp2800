#!/bin/sh
# Keep the HDMI output active, HDMI audio present and Kodi alive.
#
# All external calls are wrapped in timeout(1): a wedged X/GPU must not hang
# the watchdog or an SSH session.

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin

MODE=1920x1080
RATE=60
INTERVAL=10
LOG=/var/log/kodiwatchdog.log
XTMO=5
REPROBE=/usr/local/bin/hdmi-audio-reprobe

export DISPLAY=:0

log() { echo "$(date "+%Y-%m-%d %H:%M:%S") $*" >> "$LOG"; }
x_up() { pgrep -q -f "Xorg :0"; }
kodi_up() { pgrep -q -f "kodi.bin"; }
xrandr_t() { timeout "$XTMO" /usr/local/bin/xrandr "$@"; }

start_kodi() {
    /usr/sbin/daemon -o /var/log/kodi-run.log -p /var/run/kodi.pid \
        /usr/bin/env DISPLAY=:0 HOME=/root /usr/local/bin/kodi
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
    sleep 2
    rm -f /tmp/.X11-unix/X0 /tmp/.X0-lock
    /usr/local/etc/rc.d/kodidisplay onestart </dev/null >/dev/null 2>&1
}

log "watchdog started"

while :; do
    if ! x_up; then
        log "Xorg is not running"
        restart_display
        sleep 20
        continue
    fi

    line=$(xrandr_t 2>/dev/null | grep '^HDMI-1')
    case "$line" in
        *" connected primary "[0-9]*)
            : # output active
            ;;
        *" connected "*)
            log "HDMI-1 connected but inactive - re-enabling"
            xrandr_t --output HDMI-1 --mode "$MODE" --rate "$RATE" --primary >>"$LOG" 2>&1
            sleep 2
            if timeout 60 "$REPROBE"; then
                log "audio codec reprobe succeeded after re-enable"
                if kodi_up; then
                    restart_kodi
                fi
            fi
            ;;
        *" disconnected "*)
            : # TV off - wait
            ;;
    esac

    if ! kodi_up; then
        log "Kodi not running - restarting"
        start_kodi
    fi

    sleep "$INTERVAL"
done
