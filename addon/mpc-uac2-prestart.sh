#!/bin/sh
# Runs before every start of the MPC app (acvs.service ExecStartPre). Two jobs:
#  1. release the USB-B port (stop our gadget) so the app can take it if it is starting in Controller mode;
#     mpc-uac2d brings our gadget back ~30 s later if the app turns out to be in Standalone.
#  2. crash-loop failsafe: if the app has started 4+ times within 120 s this boot, write /run/mpc-uac2/disabled
#     so the app runs completely stock for the rest of this boot (cleared automatically by the next reboot).
DIR=$(cd "$(dirname "$0")" && pwd)
sh $DIR/mpc-uac2.sh stop >/dev/null 2>&1
now=$(cut -d. -f1 /proc/uptime)
mkdir -p /run/mpc-uac2
echo "$now" >> /run/mpc-uac2/app-starts
n=$(awk -v now="$now" 'now - $1 <= 120' /run/mpc-uac2/app-starts | wc -l)
if [ "$n" -ge 4 ] && [ ! -e /run/mpc-uac2/disabled ]; then
    echo "MPC app started $n times in 120 s — USB audio add-on disabled for this boot $(date)" > /run/mpc-uac2/disabled
    echo "$(date +%H:%M:%S) crash-loop failsafe tripped ($n app starts in 120 s): add-on off until reboot" >> /tmp/mpc-uac2d.log
fi
exit 0
