#!/bin/sh
# mpc-uac2d — keeps the MPC One+ USB-B audio gadget on in STANDALONE and out of the way in CONTROLLER mode.
#  - standalone (no Akai "smexstream" gadget): once the MPC app has been up GRACE seconds, start our gadget (mpcuac2)
#  - controller mode (app created "smexstream"): stop ours; if the app's gadget is left unbound (because ours held the
#    port at that moment), bind it for the app once it's ready.
#  - off switches (any of): /data/mpc-uac2/disabled · /run/mpc-uac2/disabled (crash-loop failsafe, this boot only)
#    · a file named MPC-UAC2-OFF in the root of any USB stick / SD card the MPC has mounted
DIR=${MPC_UAC2_DIR:-$(cd "$(dirname "$0")" && pwd)}
CFS=/sys/kernel/config/usb_gadget
UDC=ff580000.usb
LOG=${MPC_UAC2D_LOG:-/tmp/mpc-uac2d.log}
GRACE=${GRACE:-30}
HZ=$(getconf CLK_TCK 2>/dev/null || echo 100)

log() { echo "$(date +%H:%M:%S) $*" >> "$LOG"; }
app_age() {                      # seconds since the MPC app process started; fails if not running
    pid=$(pidof MPC) || return 1
    # field 22 (starttime) counted after the "(comm)" field, which itself contains spaces ("MPC Main Thread")
    st=$(sed 's/^.*) //' /proc/"$pid"/stat 2>/dev/null | cut -d' ' -f20) || return 1
    [ -n "$st" ] || return 1
    up=$(cut -d. -f1 /proc/uptime)
    echo $(( up - st / HZ ))
}

off_switch() {
    for f in /data/mpc-uac2/disabled /run/mpc-uac2/disabled /media/*/MPC-UAC2-OFF; do [ -e "$f" ] && { echo "$f"; return 0; }; done
    return 1
}

MODEL=$(tr '\0' '\n' < /proc/device-tree/compatible 2>/dev/null | head -n 1)
case "$MODEL" in
    inmusic,acva2|inmusic,acva) ;;                                   # MPC One+ / MPC One
    *) log "unsupported model '$MODEL': add-on dormant"; while :; do sleep 3600; done ;;
esac
log "mpc-uac2d started on $MODEL (dir=$DIR grace=${GRACE}s)"
unbound_since=0
while :; do
    if why=$(off_switch); then
        [ -d $CFS/mpcuac2 ] && { log "off switch $why: stopping USB audio"; sh "$DIR/mpc-uac2.sh" stop >> "$LOG" 2>&1; }
        sleep 3; continue
    fi
    if [ -d $CFS/smexstream ]; then                                   # CONTROLLER MODE
        if [ -d $CFS/mpcuac2 ]; then log "controller mode: releasing the USB port"; sh "$DIR/mpc-uac2.sh" stop >> "$LOG" 2>&1; fi
        if [ -z "$(cat $CFS/smexstream/UDC 2>/dev/null)" ] && [ -z "$(cat /sys/class/udc/$UDC/function 2>/dev/null)" ] \
           && [ "$(cat $CFS/smexstream/functions/ffs.smexstream/ready 2>/dev/null)" = 1 ]; then
            now=$(cut -d. -f1 /proc/uptime)
            [ "$unbound_since" = 0 ] && unbound_since=$now
            if [ $(( now - unbound_since )) -ge 5 ]; then             # app left it unbound for 5 s: bind it for the app
                log "controller gadget ready but unbound for 5 s: binding it to $UDC"
                echo $UDC > $CFS/smexstream/UDC 2>> "$LOG" || log "bind failed"
                unbound_since=0
            fi
        else
            unbound_since=0
        fi
    else                                                               # STANDALONE
        unbound_since=0
        if [ ! -d $CFS/mpcuac2 ]; then
            age=$(app_age) && [ "$age" -ge "$GRACE" ] && { log "standalone (app up ${age}s): starting USB audio"; sh "$DIR/mpc-uac2.sh" start >> "$LOG" 2>&1; }
        fi
    fi
    sleep 1
done
