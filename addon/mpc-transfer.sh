#!/bin/sh
# One-owner USB transfer disk. Only a SCSI eject permits importing; cable removal,
# app restarts and reboot never imply an eject. No SD block device is exported.
set -eu
DATA=${MPC_TRANSFER_DATA:-/data}
DIR=${MPC_TRANSFER_DIR:-$DATA/mpc-uac2/transfer}
MOUNTS=${MPC_TRANSFER_MOUNTS:-/proc/mounts}
RUN=${MPC_TRANSFER_RUN:-/run/mpc-uac2/transfer}
CFS=${MPC_TRANSFER_CFS:-/sys/kernel/config/usb_gadget}
G=$CFS/mpcuac2
LUN=$G/functions/mass_storage.transfer/lun.0
IMG=$DIR/disk.img
MNT=$RUN/mount
SELF=$(realpath "$0")
UDC_STATE=${MPC_TRANSFER_UDC_STATE:-/sys/class/udc/ff580000.usb/state}
SIZE_MB=${MPC_TRANSFER_SIZE_MB:-1024}

log() { echo "[mpc-transfer] $*"; }
state() { cat "$DIR/state" 2>/dev/null || :; }
set_state() {
    printf '%s\n' "$1" > "$DIR/state.new"
    mv "$DIR/state.new" "$DIR/state"
    sync
}
cleanup() { mountpoint -q "$MNT" && umount "$MNT" || :; }
# No local access while ANY USB LUN owns the image. Also reject a leftover mount
# (e.g. SIGKILL during import); after the lock is held it is safe to unmount it.
local_access() {
    for f in "$CFS"/*/functions/mass_storage.*/lun.*/file; do
        [ -f "$f" ] || continue
        backing=$(cat "$f") || return 1
        [ "$backing" != "$IMG" ] || return 1
    done
    if mountpoint -q "$MNT"; then umount "$MNT" || return 1; fi
}
format_disk() {
    local_access || return 1
    if [ ! -f "$IMG" ]; then
        rm -f "$DIR/disk.new"
        free=$(df -Pk "$DIR" | awk 'END {print $4}')
        [ "$free" -ge $((SIZE_MB * 1024 + 524288)) ] || { log 'not enough internal space (keeping audio/MIDI)'; return 1; }
        # Allocate real blocks, reserving the whole disk before presenting it.
        dd if=/dev/zero of="$DIR/disk.new" bs=1048576 count="$SIZE_MB" 2>/dev/null
        mv "$DIR/disk.new" "$IMG"
    fi
    LC_ALL=C mkfs.exfat -L 'MPCTransfer' "$IMG" >/dev/null
    mount -t exfat -o loop,rw,nosuid,nodev,noexec "$IMG" "$MNT"
    cat > "$MNT/START HERE.txt" <<'INFO'
Drop samples and folders here, then Eject MPCTransfer in Finder.
The MPC imports them into SD card / USB Imports / Transfer-<date>-<id>.
Wait for the new folder to appear on the MPC before removing the SD card.
Reconnect the USB cable to get an empty transfer drive for the next batch.
Audio and MIDI keep working. The SD card itself is never shared with the Mac.
If you unplug without ejecting, reconnect and eject to finish the transfer.
If the SD is absent or full, files are retained; insert/free the SD and wait for import.
This drive holds up to 1 GiB. START HERE.txt and Finder housekeeping files are not imported.
INFO
    sync
    umount "$MNT"
    rm -f "$DIR/batch"
    set_state ready
}
prepare() {
    case "$(state)" in
        '') [ ! -e "$IMG" ] || { log 'unrecognized existing disk; leaving it intact'; return 1; }; set_state reset; format_disk ;;
        reset) format_disk ;;
        ready|exported|pending) [ -f "$IMG" ] ;;
        *) log 'unknown state; leaving disk intact'; return 1 ;;
    esac
}
inode() { stat -c %i "$G/functions/mass_storage.transfer" 2>/dev/null; }
attach() {
    [ -f "$LUN/file" ] || return 0
    backing=$(cat "$LUN/file")
    if [ -n "$backing" ]; then
        if [ "$backing" = "$IMG" ] && [ "$(state)" = exported ]; then
            inode > "$RUN/armed"
        fi
        return 0
    fi
    prepare
    case "$(state)" in ready|exported) ;; *) return 0 ;; esac
    id=$(inode) || return 0
    # Do not make an ejected drive pop straight back into Finder. A new gadget
    # or physical disconnection starts a new session; audio is never rebound.
    if [ "$(cat "$RUN/ejected" 2>/dev/null || :)" = "$id" ]; then
        [ "$(cat "$UDC_STATE" 2>/dev/null || :)" = 'not attached' ] \
            || [ "$(cat "$RUN/reconnected" 2>/dev/null || :)" = "$id" ] || return 0
    fi
    local_access || return 1
    set_state exported
    printf '%s\n' "$IMG" > "$LUN/file"
    printf '%s\n' "$id" > "$RUN/armed"
    rm -f "$RUN/ejected" "$RUN/reconnected"
    log 'transfer disk offered to USB host'
}
# The SD partition must actually be mounted rw. Decode mount-table escapes;
# never fall back to internal storage or a directory left behind by a removed SD.
sd_mount() {
    awk '$1 == "/dev/mmcblk1p1" && $4 ~ /(^|,)rw(,|$)/ {print $2; exit}' "$MOUNTS"
}
# cmp streams even very large text/audio files; diff can buffer text in RAM.
verify_copy() {
    [ ! -L "$2" ] || return 1
    if [ -d "$1" ]; then
        [ -d "$2" ] || return 1
        for entry in "$1"/* "$1"/.[!.]* "$1"/..?*; do
            [ -e "$entry" ] || continue
            verify_copy "$entry" "$2/${entry##*/}" || return 1
        done
    else
        [ -f "$2" ] && cmp -s "$1" "$2" || return 1
    fi
}
import_disk() {
    # Keep our UDC bound until the SD copy is finished. The supervisor and app
    # pre-start hook use this same lock before handing USB to Controller mode.
    exec 9>"$RUN/../gadget.lock"
    flock -n 9 || return 1
    [ -n "$(cat "$G/UDC" 2>/dev/null || :)" ] || return 1
    [ ! -d "$CFS/smexstream" ] || return 1
    local_access || return 1
    encoded=$(sd_mount)
    [ -n "$encoded" ] || { log 'waiting for a writable SD card'; return 1; }
    sd=$(printf '%b' "$encoded")
    mountpoint -q "$sd" || return 1
    [ ! -L "$sd/USB Imports" ] || { log 'refusing symlink at USB Imports'; return 1; }
    mkdir -p "$sd/USB Imports"
    # A clean eject is necessary but not sufficient: refuse filesystem errors,
    # never auto-repair or format a disk containing an unimported batch.
    fsck.exfat -n "$IMG" >/dev/null 2>&1 || { log 'transfer disk needs repair on the computer; retaining files'; set_state exported; return 1; }
    mount -t exfat -o loop,ro,nosuid,nodev,noexec "$IMG" "$MNT"
    if [ ! -f "$DIR/batch" ]; then
        batch="Transfer-$(date +%Y%m%d-%H%M%S)-$(cut -c1-8 /proc/sys/kernel/random/uuid)"
        printf '%s\n' "$batch" > "$DIR/batch.new"
        mv "$DIR/batch.new" "$DIR/batch"
        sync
    fi
    batch=$(cat "$DIR/batch")
    case "$batch" in Transfer-*[!a-zA-Z0-9-]*|'') return 1 ;; Transfer-*) ;; *) return 1 ;; esac
    dest=$sd/USB\ Imports/$batch
    partial=$sd/USB\ Imports/.$batch.partial
    [ ! -L "$dest" ] && [ ! -L "$partial" ] || return 1
    # Completion marker travels with the atomic directory rename. A power loss
    # after rename but before resetting the image will not duplicate the batch.
    if [ -e "$dest" ]; then
        [ "$(cat "$dest/.mpc-transfer-complete" 2>/dev/null || :)" = "$batch" ] || return 1
    else
        if [ -e "$partial" ]; then
            [ "$(cat "$partial/.mpc-transfer-owner" 2>/dev/null || :)" = "$batch" ] || return 1
            rm -rf "$partial"
        fi
        mkdir "$partial"
        printf '%s\n' "$batch" > "$partial/.mpc-transfer-owner"
        count=0
        for source in "$MNT"/* "$MNT"/.[!.]* "$MNT"/..?*; do
            [ -e "$source" ] || continue
            name=${source##*/}
            case "$name" in 'START HERE.txt'|.DS_Store|.Spotlight-V100|.Trashes|.fseventsd|._*|.mpc-transfer-owner|.mpc-transfer-complete) continue ;; esac
            cp -R "$source" "$partial/" || return 1
            # Check the copy before acknowledging the batch or clearing its source.
            verify_copy "$source" "$partial/$name" || return 1
            count=$((count + 1))
        done
        # Recheck the mount after copying: card removal must never acknowledge a batch.
        [ "$(sd_mount)" = "$encoded" ] && mountpoint -q "$sd" || return 1
        if [ "$count" -gt 0 ]; then
            printf '%s\n' "$batch" > "$partial/.mpc-transfer-complete"
            sync
            mv "$partial" "$dest"
            sync
            log "imported to $dest"
        else
            rm -rf "$partial"
        fi
    fi
    umount "$MNT"
    set_state reset
    format_disk
}
tick() {
    if [ ! -f "$DIR/state" ]; then attach; return; fi
    s=$(state)
    if [ "$s" = exported ] && [ -f "$LUN/file" ]; then
        id=$(inode) || return 0
        if [ "$(cat "$RUN/armed" 2>/dev/null || :)" = "$id" ] \
            && [ -n "$(cat "$G/UDC" 2>/dev/null || :)" ]; then
            backing=$(cat "$LUN/file") || return 0
            if [ -z "$backing" ]; then
                printf '%s\n' "$id" > "$RUN/ejected"
                rm -f "$RUN/armed"
                set_state pending
                log 'host ejected; importing'
            fi
        fi
    fi
    case "$(state)" in pending) import_disk ;; reset) format_disk ;; esac
    attach
}
case "${1:-}" in
    watch)
        mkdir -p "$RUN"
        watcher=$(dirname "$SELF")/mpc-transfer-watch
        if [ -x "$watcher" ]; then
            "$watcher" "$UDC_STATE" "$G/functions/mass_storage.transfer" "$RUN/reconnected" &
            watcher_pid=$!
            trap 'kill "$watcher_pid" 2>/dev/null || :; wait "$watcher_pid" 2>/dev/null || :' EXIT
            trap 'exit 0' HUP INT TERM
        fi
        while :; do
            if [ -n "${watcher_pid:-}" ]; then kill -0 "$watcher_pid" 2>/dev/null || exit 1; fi
            if "$SELF" tick; then sleep 3; else sleep 30; fi
        done ;;
    attach|tick)
        # /data must be mounted before any allocation (not the read-only rootfs).
        mountpoint -q "$DATA" || exit 1
        umask 077
        mkdir -p "$DIR" "$RUN" "$MNT"
        exec 8>"$RUN/lock"
        flock -n 8 || exit 0
        trap cleanup EXIT
        trap 'exit 1' HUP INT TERM
        "$1" ;;
    *) echo "usage: $0 attach|tick|watch" >&2; exit 2 ;;
esac
