#!/bin/sh
# mpc-uac2.sh — USB-B audio (UAC2) gadget for an MPC One / One+ in STANDALONE mode.
#
# Adapted from PolyVector's script in TheKikGen/MPC-LiveXplore issue #55
# (https://github.com/TheKikGen/MPC-LiveXplore/issues/55#issuecomment, 2023-09-29/30),
# re-based on the gadget the MPC 3.9.1 app itself builds in Controller mode on this unit
# (captured 2026-10-18, see ../mpc-state/controller-mode.txt).
#
# Everything here lives in configfs (RAM). Nothing is written to the eMMC, nothing survives a reboot.
#
# Usage:  sh mpc-uac2.sh start|stop|status|restart
# Env:    MIDI_PORTS=0..3   USB-MIDI function ports (default 1, alongside USB audio; 0 = audio only).
#                           PolyVector once saw IRQ CPU storms with MIDI+audio, but a 3-minute full-load test
#                           on an MPC One+ (task 2541) showed none: 0 xruns both ways, app PID stable.
#         RATE=44100        sample rate offered to the host (MPC app default is 44100)
#
# Do NOT switch the MPC into Controller mode while this gadget is up: run `stop` first.

set -u
CFS=/sys/kernel/config/usb_gadget
NAME=mpcuac2                    # deliberately NOT "smexstream" (the app's own controller-mode gadget)
G=$CFS/$NAME
UDC_NAME=ff580000.usb           # USB-B port (dwc2 OTG). ff540000.usb is the internal host for the pads/controls.
MIDI_PORTS=${MIDI_PORTS:-1}
RATE=${RATE:-44100}

say() { echo "[mpc-uac2] $*"; }
die() { echo "[mpc-uac2] ERROR: $*" >&2; exit 1; }
w()   { [ -e "$2" ] && { echo "$1" > "$2" || say "warn: could not write '$1' to $2"; }; }   # write only if the attr exists

status() {
    echo "udc state      : $(cat /sys/class/udc/$UDC_NAME/state 2>/dev/null)"
    echo "udc function   : $(cat /sys/class/udc/$UDC_NAME/function 2>/dev/null)"
    echo "gadgets        : $(ls $CFS 2>/dev/null | tr '\n' ' ')"
    [ -d "$G" ] && echo "$NAME UDC     : $(cat $G/UDC 2>/dev/null)"
    echo "alsa cards     :"; sed 's/^/  /' /proc/asound/cards
}

start() {
    [ -d $CFS ] || die "configfs usb_gadget not mounted"
    [ -d $CFS/smexstream ] && die "the MPC app's own gadget (smexstream) exists — unit is in Controller mode. Switch to Standalone first."
    [ -d "$G" ] && { say "already exists — use restart"; status; exit 0; }
    UDC_FUNC=$(cat /sys/class/udc/$UDC_NAME/function 2>/dev/null)
    [ -n "$UDC_FUNC" ] && die "$UDC_NAME is already bound to '$UDC_FUNC'"

    # USB identity = what the MPC app itself uses in Controller mode on this model
    MODEL=$(tr '\0' '\n' < /proc/device-tree/compatible 2>/dev/null | head -n 1)
    case "$MODEL" in
        inmusic,acva2) PID=0x1056; PRODUCT="MPC One+" ;;   # captured on Will's One+ (3.9.1)
        inmusic,acva)  PID=0x1046; PRODUCT="MPC One"  ;;   # PolyVector's MPC One (issue #55)
        *) die "unsupported device '$MODEL' — only MPC One / One+ are known" ;;
    esac
    SERIAL=$(fw_printenv -n 'serial#' 2>/dev/null)
    [ -n "$SERIAL" ] || SERIAL=000000000000000

    mkdir "$G" || die "mkdir $G"
    cd "$G" || die "cd $G"

    # Device descriptor — identical to the app's own controller-mode gadget for this model
    w 0x09e8 idVendor
    w $PID   idProduct
    w 0x0101 bcdDevice
    w 0x0200 bcdUSB
    w 0x00   bDeviceClass
    w 0x00   bDeviceSubClass
    w 0x00   bDeviceProtocol
    w 0x40   bMaxPacketSize0
    w super-speed-plus max_speed

    mkdir -p strings/0x409
    w "$SERIAL"            strings/0x409/serialnumber
    w "Akai Professional"  strings/0x409/manufacturer
    w "$PRODUCT"           strings/0x409/product

    mkdir -p configs/config.1
    w 2    configs/config.1/MaxPower
    w 0xc0 configs/config.1/bmAttributes

    # UAC2 function — attribute values copied from the app's controller-mode gadget
    F=functions/uac2.audio
    mkdir $F || die "mkdir $F (is CONFIG_USB_CONFIGFS_F_UAC2 present?)"
    # c_* = host -> MPC (MPC capture), p_* = MPC -> host (MPC playback, what Ableton records)
    w 3        $F/c_chmask;  w 3        $F/p_chmask
    w "$RATE"  $F/c_srate;   w "$RATE"  $F/p_srate
    w 4        $F/c_ssize;   w 4        $F/p_ssize
    w async    $F/c_sync
    w 2        $F/c_hs_bint; w 2        $F/p_hs_bint
    w 0        $F/c_mute_present;   w 0 $F/p_mute_present
    w 0        $F/c_volume_present; w 0 $F/p_volume_present
    w 0        $F/c_volume_max;     w 0 $F/p_volume_max
    w -25600   $F/c_volume_min;     w -25600 $F/p_volume_min
    w 256      $F/c_volume_res;     w 256 $F/p_volume_res
    w 513      $F/c_terminal_type;  w 769 $F/p_terminal_type
    w 0        $F/explicit_feedback
    w 50       $F/fb_max
    w 1        $F/named_channels
    w 6        $F/req_number
    w 1        $F/shared_clock
    w "$PRODUCT Audio" $F/function_name
    w "$PRODUCT Audio" $F/if_ctrl_name
    w "USBH Out" $F/c_it_name;  w "USBD In"  $F/c_ot_name
    w "USBD Out" $F/p_it_name;  w "USBH In"  $F/p_ot_name
    w "Playback Channels" $F/c_it_ch_name; w "Capture Channels" $F/p_it_ch_name
    w "Playback Volume"   $F/c_fu_vol_name; w "Capture Volume"  $F/p_fu_vol_name
    w "Input Clock"  $F/clksrc_in_name; w "Output Clock" $F/clksrc_out_name
    ln -s $F configs/config.1/ || die "link uac2"

    if [ "$MIDI_PORTS" -gt 0 ] 2>/dev/null; then
        M=functions/midi.midi
        mkdir $M || die "mkdir $M"
        w 512 $M/buflen; w 32 $M/qlen
        w "MPC One +" $M/id
        w "$MIDI_PORTS" $M/in_ports; w "$MIDI_PORTS" $M/out_ports
        mkdir -p $M/strings/0x0409 2>/dev/null && w "$PRODUCT MIDI" $M/strings/0x0409/interface
        ln -s $M configs/config.1/ || die "link midi"
    fi
    # Deliberately omitted vs. controller mode:
    #  - ffs.smexstream   : Akai's controller protocol, needs the app on the other end
    #  - mass_storage     : would export the SD card (/dev/mmcblk1) read-write while the MPC has it mounted

    w 0x10    os_desc/b_vendor_code
    w MSFT100 os_desc/qw_sign
    w 1       os_desc/use
    [ -e os_desc/config.1 ] || ln -s configs/config.1 os_desc/ 2>/dev/null

    echo $UDC_NAME > UDC || { say "bind failed"; cd /; stop; exit 1; }
    sleep 1
    say "bound to $UDC_NAME"
    status
}

stop() {
    [ -d "$G" ] || { say "not running"; return 0; }
    cd "$G" || return 1
    [ -n "$(cat UDC 2>/dev/null)" ] && echo "" > UDC
    rm -f os_desc/config.1 2>/dev/null
    for l in configs/config.1/*.*; do [ -L "$l" ] && rm "$l"; done
    rmdir configs/config.1/strings/* 2>/dev/null
    rmdir configs/config.1 2>/dev/null
    for f in functions/*; do rmdir "$f"/strings/* 2>/dev/null; rmdir "$f" || say "warn: rmdir $f"; done
    rmdir strings/* 2>/dev/null
    cd /
    rmdir "$G" && say "removed"
}

case "${1:-}" in
    start)   start ;;
    stop)    stop ;;
    restart) stop; sleep 1; start ;;
    status)  status ;;
    *) echo "usage: $0 start|stop|restart|status   (env MIDI_PORTS=0..3, RATE=44100)"; exit 2 ;;
esac
