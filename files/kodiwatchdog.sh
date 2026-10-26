#!/bin/sh
# Keep the HDMI output active and Kodi alive on the FreeBSD media box.
# Re-enables HDMI-1 after TV hotplug cycles and restarts Kodi if it dies.

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin

export DISPLAY=:0
MODE="1920x1080"
RATE="60"
INTERVAL=10
LOG="/var/log/kodiwatchdog.log"

log() { echo "$(date "+%Y-%m-%d %H:%M:%S") $*" >> "$LOG"; }

x_up() { pgrep -q -f "Xorg :0"; }
kodi_up() { pgrep -q -f "kodi.bin"; }

restart_display() {
    log "restarting display stack"
    pkill -9 -f "kodi.bin" 2>/dev/null
    pkill -9 -f "Xorg :0" 2>/dev/null
    sleep 2
    rm -f /tmp/.X11-unix/X0 /tmp/.X0-lock
    /usr/local/etc/rc.d/kodidisplay onestart >/dev/null 2>&1
}

log "watchdog started"

while :; do
    if ! x_up; then
        log "Xorg is not running"
        restart_display
        sleep 20
        continue
    fi

    # Check HDMI-1 state: "connected primary WxH+X+Y" = active,
    # "connected (...)" without geometry = connected but outputs disabled.
    line=$(xrandr 2>/dev/null | grep "^HDMI-1")
    case "$line" in
        *" connected primary "*|*" connected "*) : ;;
    esac

    if echo "$line" | grep -q " connected primary [0-9]"; then
        : # output active
    elif echo "$line" | grep -q "^HDMI-1 connected"; then
        log "HDMI-1 connected but inactive - re-enabling"
        xrandr --output HDMI-1 --mode "$MODE" --rate "$RATE" --primary >>"$LOG" 2>&1
        /usr/local/bin/hdmi-audio-reprobe
        sleep 2
        if ! kodi_up; then
            log "Kodi not running after re-enable - restarting"
            restart_display
            sleep 20
            continue
        fi
    elif echo "$line" | grep -q "^HDMI-1 disconnected"; then
        : # TV off - wait
    fi

    if ! kodi_up; then
        log "Kodi not running - restarting"
        /usr/sbin/daemon -o /var/log/kodi-run.log -p /var/run/kodi.pid \
            /usr/bin/env DISPLAY=:0 HOME=/root /usr/local/bin/kodi
    fi

    sleep "$INTERVAL"
done
