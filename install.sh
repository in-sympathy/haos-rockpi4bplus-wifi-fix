#!/bin/sh
# haos-rockpi4-wifi-fix
#
# Makes the AzureWave AW-NB197SM WiFi module (Broadcom BCM43430/1, SDIO 02d0:a9a6)
# work on Radxa ROCK Pi 4 boards running Home Assistant OS from citruz/haos-rockpi.
#
# Root cause: the HAOS image ships only the Raspberry Pi nvram for this chip
# (xtalfreq=37400). The AW-NB197SM runs from a 26 MHz crystal, so the radio is
# mistuned: firmware loads, wlan0 comes up, but every scan returns nothing.
#
# Fix: bind-mount a 26 MHz nvram over the stock brcmfmac43430-sdio.txt and reload
# brcmfmac. A udev rule re-applies it on every boot. Nothing on the read-only
# rootfs is modified; all files live in /mnt/data and /etc/udev/rules.d, which
# HAOS keeps across reboots and OS updates.
#
# Run from the HAOS *host* root shell (console: type `login` at the `ha >` prompt,
# or SSH on port 22222). The Terminal & SSH app is a container and will not work.
#
#   sh install.sh               install and apply now
#   sh install.sh --status      show what is active
#   sh install.sh --reapply     re-apply and force a driver reload
#   sh install.sh --uninstall   remove everything, back to stock
#   add --force to skip the HAOS / board / chip checks
#
# https://github.com/citruz/haos-rockpi/issues/50

set -u

NAME=brcm-nvram-fix
DATA_DIR=${BNF_DATA_DIR:-/mnt/data/$NAME}
RULES_DIR=${BNF_RULES_DIR:-/etc/udev/rules.d}
RULE_FILE=$RULES_DIR/99-$NAME.rules
NVRAM=$DATA_DIR/brcmfmac43430-sdio.txt
HOOK=$DATA_DIR/apply.sh
STOCK=/lib/firmware/brcm/brcmfmac43430-sdio.txt
NVRAM_MD5=29030f406aa712ec2cd2c1c578273a46
SDIO_VENDOR=0x02d0
SDIO_DEVICE=0xa9a6

FORCE=0
ACTION=install

msg()  { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
usage: sh install.sh [option] [--force]
  (no option)   install and apply now
  --status      show what is active
  --reapply     re-apply and force a driver reload
  --uninstall   remove everything, back to stock
  --force       skip the HAOS / board / chip checks
EOF
}

is_mounted() { grep -qF " $1 " /proc/mounts; }
# does not depend on /proc/mounts parsing; also peels off stacked mounts
unmount_all() { i=0; while [ "$i" -lt 10 ] && umount "$1" 2>/dev/null; do i=$((i + 1)); done; }

board_compat() {
    [ -r /proc/device-tree/compatible ] || return 0
    tr '\0' '\n' </proc/device-tree/compatible 2>/dev/null | head -n 1
}

chip_present() {
    for d in /sys/bus/sdio/devices/*; do
        [ -r "$d/vendor" ] && [ -r "$d/device" ] || continue
        [ "$(cat "$d/vendor")" = "$SDIO_VENDOR" ] &&
            [ "$(cat "$d/device")" = "$SDIO_DEVICE" ] && return 0
    done
    return 1
}

need_ok() {  # need_ok <condition-description> : abort unless --force
    if [ "$FORCE" = 1 ]; then warn "$1 (continuing because of --force)"; else die "$1 (use --force to override)"; fi
}

preflight() {
    [ "$(id -u)" = 0 ] || die "run as root from the HAOS host shell"

    grep -qE '^ID="?(haos|hassos)"?$' /etc/os-release 2>/dev/null ||
        need_ok "this does not look like Home Assistant OS"

    compat=$(board_compat)
    case "$compat" in
        radxa,rock*) ;;
        *) need_ok "board '${compat:-unknown}' is not a Radxa ROCK Pi 4 variant" ;;
    esac

    chip_present ||
        need_ok "no AW-NB197SM / BCM43430 (SDIO $SDIO_VENDOR:$SDIO_DEVICE) found; boards with the AP6256 module (0x4345) do not need this fix"

    [ -d "${DATA_DIR%/*}" ] || die "${DATA_DIR%/*} does not exist"
    [ -d "$RULES_DIR" ] || die "$RULES_DIR does not exist"
    if [ -z "${BNF_RULES_DIR:-}" ] && ! is_mounted "$RULES_DIR"; then
        need_ok "$RULES_DIR is not on the persistent overlay; the boot hook would not survive a reboot"
    fi

    SYSTEMD_RUN=$(command -v systemd-run 2>/dev/null || true)
    if [ -z "$SYSTEMD_RUN" ]; then
        need_ok "systemd-run not found"
        SYSTEMD_RUN=/usr/bin/systemd-run
    fi
}

# Removes the manual workaround (directory bind mount) posted in the issue thread.
cleanup_legacy() {
    legacy_rule=$RULES_DIR/99-brcm-nvram.rules
    [ -f /mnt/data/fw/brcm-fix.sh ] || [ -f "$legacy_rule" ] || return 0
    msg "Removing the earlier manual workaround ..."
    rm -f "$legacy_rule"
    brcm_dir=$(readlink -f /lib/firmware/brcm 2>/dev/null || true)
    [ -n "$brcm_dir" ] && unmount_all "$brcm_dir"
    [ -f /mnt/data/fw/brcm-fix.sh ] && rm -rf /mnt/data/fw
    return 0
}

write_nvram() {
    mkdir -p "$DATA_DIR" || die "cannot create $DATA_DIR"
    # 26 MHz nvram for BCM43430/1 modules (AP6212 / AW-NB197SM class).
    # Identical to brcm/brcmfmac43430-sdio.txt from github.com/armbian/firmware.
    cat >"$NVRAM.tmp" <<'NVRAM_EOF'
#AP6212_NVRAM_V1.0_20140603
# 2.4 GHz, 20 MHz BW mode

# The following parameter values are just placeholders, need to be updated.
manfid=0x2d0
prodid=0x0726
vendid=0x14e4
devid=0x43e2
boardtype=0x0726
boardrev=0x1101
boardnum=22
macaddr=00:90:4c:c5:12:38
sromrev=11
boardflags=0x00404201
xtalfreq=26000
nocrc=1
ag0=255
aa2g=1
ccode=ALL

pa0itssit=0x20
extpagain2g=0

#PA parameters for 2.4GHz, measured at CHIP OUTPUT
pa2ga0=-168,7161,-820
AvVmid_c0=0x0,0xc8
cckpwroffset0=5

# PPR params
maxp2ga0=90
txpwrbckof=6
cckbw202gpo=0x5555
legofdmbw202gpo=0x77777777
mcsbw202gpo=0xaaaaaaaa

# OFDM IIR :
ofdmdigfilttype=7
# PAPD mode:
papdmode=2

il0macaddr=00:90:4c:c5:12:38
wl0id=0x431b

#OOB parameters
hostwake=0x40
hostrdy=0x41
usbrdy=0x03
usbrdydelay=100
deadman_to=0xffffffff
# muxenab: 0x1 for UART enable, 0x10 for Host awake
muxenab=0x10
# CLDO PWM voltage settings - 0x4 - 1.1 volt
#cldo_pwm=0x4

NVRAM_EOF
    sum=$(md5sum "$NVRAM.tmp" | cut -d ' ' -f 1)
    if [ "$sum" != "$NVRAM_MD5" ]; then
        rm -f "$NVRAM.tmp"
        die "embedded nvram checksum mismatch ($sum); was this file saved with CRLF line endings?"
    fi
    # mv keeps a currently bind-mounted older copy intact until the hook swaps it.
    mv -f "$NVRAM.tmp" "$NVRAM"
}

write_hook() {
    cat >"$HOOK.tmp" <<'HOOK_EOF'
#!/bin/sh
# brcm-nvram-fix boot hook, installed by haos-rockpi4-wifi-fix/install.sh.
# Bind-mounts the 26 MHz nvram over the stock BCM43430 nvram and reloads brcmfmac.
#   apply.sh            apply; reload the driver only if the nvram changed
#   apply.sh --reload   apply and always reload the driver
#   apply.sh --revert   remove the bind mount and reload with the stock nvram

DIR=$(dirname "$(readlink -f "$0")")
NVRAM=$DIR/brcmfmac43430-sdio.txt
STOCK=/lib/firmware/brcm/brcmfmac43430-sdio.txt
LOCK=/run/brcm-nvram-fix.lock
DRV=/sys/bus/sdio/drivers/brcmfmac
MODE=${1:-}

log() { printf 'brcm-nvram-fix: %s\n' "$*"; }
unmount_all() { i=0; while [ "$i" -lt 10 ] && umount "$1" 2>/dev/null; do i=$((i + 1)); done; }
same() {
    if command -v cmp >/dev/null 2>&1; then
        cmp -s "$1" "$2"
    else
        [ "$(md5sum <"$1")" = "$(md5sum <"$2")" ]
    fi
}

# Let the first probe finish so the module is not pulled out mid firmware load.
wait_probe() {
    [ -d "$DRV" ] || return 0
    i=0
    while [ "$i" -lt 15 ]; do
        for n in "$DRV"/*/net/*; do [ -e "$n" ] && return 0; done
        sleep 1
        i=$((i + 1))
    done
    log "no brcmfmac net device after 15 s, reloading anyway"
}

reload() {
    if grep -q '^brcmfmac ' /proc/modules; then
        # vendor modules (brcmfmac_cyw, _wcc, _bca) must go before brcmfmac itself
        mods=$(awk '$1 ~ /^brcmfmac/ {print $1}' /proc/modules | sort -r)
        # shellcheck disable=SC2086
        rmmod $mods || { log "rmmod failed: $mods"; return 1; }
        modprobe brcmfmac || { log "modprobe brcmfmac failed"; return 1; }
        log "brcmfmac module reloaded"
    elif [ -d "$DRV" ]; then
        devs=""
        for d in "$DRV"/mmc*; do [ -e "$d" ] && devs="$devs ${d##*/}"; done
        for d in $devs; do printf '%s' "$d" >"$DRV/unbind"; done
        for d in $devs; do printf '%s' "$d" >"$DRV/bind"; done
        log "built-in brcmfmac rebound:$devs"
    else
        modprobe brcmfmac || { log "brcmfmac not available"; return 1; }
        log "brcmfmac module loaded"
    fi
}

mkdir "$LOCK" 2>/dev/null || { log "another run is in progress, skipping"; exit 0; }
trap 'rmdir "$LOCK" 2>/dev/null' EXIT
trap 'exit 1' INT TERM

TARGET=$(readlink -f "$STOCK")
if [ -z "$TARGET" ] || [ ! -f "$TARGET" ]; then
    log "stock nvram $STOCK not found"
    exit 1
fi

if [ "$MODE" = --revert ]; then
    unmount_all "$TARGET"
    log "bind mount removed, stock nvram active"
    wait_probe
    reload
    exit $?
fi

[ -f "$NVRAM" ] || { log "missing $NVRAM"; exit 1; }

if same "$NVRAM" "$TARGET"; then
    if [ "$MODE" != --reload ]; then
        log "26 MHz nvram already active"
        exit 0
    fi
else
    # drop a stale bind from an older version before mounting the current file
    unmount_all "$TARGET"
    mount --bind "$NVRAM" "$TARGET" || { log "bind mount failed"; exit 1; }
    log "bound $NVRAM over $TARGET"
fi

wait_probe
reload
HOOK_EOF
    chmod 755 "$HOOK.tmp" || die "cannot write $HOOK"
    mv -f "$HOOK.tmp" "$HOOK" || die "cannot write $HOOK"
}

write_rule() {
    run="$SYSTEMD_RUN --no-block --collect -p SyslogIdentifier=$NAME -p RequiresMountsFor=$DATA_DIR /bin/sh $HOOK"
    cat >"$RULE_FILE.tmp" <<EOF
# Installed by haos-rockpi4-wifi-fix. Remove with: sh install.sh --uninstall
# Re-applies the 26 MHz BCM43430 nvram on every boot, once $DATA_DIR is mounted.
# Two triggers for robustness; the hook is idempotent and locked.
ACTION=="add", SUBSYSTEM=="sdio", KERNEL=="*:1", ATTR{vendor}=="$SDIO_VENDOR", ATTR{device}=="$SDIO_DEVICE", RUN+="$run"
ACTION=="add", SUBSYSTEM=="net", KERNEL=="wlan*", DRIVERS=="brcmfmac", ATTRS{vendor}=="$SDIO_VENDOR", ATTRS{device}=="$SDIO_DEVICE", RUN+="$run"
EOF
    mv -f "$RULE_FILE.tmp" "$RULE_FILE" || die "cannot write $RULE_FILE"
    udevadm control --reload-rules 2>/dev/null || true
}

wifi_dev() {
    nmcli -t -f DEVICE,TYPE device 2>/dev/null | awk -F: '$2 == "wifi" {print $1; exit}'
}

verify() {
    command -v nmcli >/dev/null 2>&1 || { warn "nmcli not found, skipping scan test"; return 0; }
    msg "Waiting for the WiFi interface ..."
    i=0
    dev=$(wifi_dev)
    while [ -z "$dev" ] && [ "$i" -lt 30 ]; do
        sleep 1
        i=$((i + 1))
        dev=$(wifi_dev)
    done
    if [ -z "$dev" ]; then
        warn "no WiFi device in NetworkManager; check: dmesg | grep -i brcmf"
        return 1
    fi

    msg "Scanning on $dev ..."
    i=0
    n=0
    while [ "$i" -lt 6 ]; do
        nmcli device wifi rescan ifname "$dev" >/dev/null 2>&1
        sleep 5
        n=$(nmcli -t -f BSSID device wifi list ifname "$dev" 2>/dev/null | grep -c .)
        [ "$n" -gt 0 ] && break
        i=$((i + 1))
    done
    if [ "$n" -gt 0 ]; then
        nmcli device wifi list ifname "$dev" 2>/dev/null | head -n 11
        msg ""
        msg "OK: $dev sees $n access point(s). This module is 2.4 GHz only."
        return 0
    fi
    warn "$dev is up but scans are still empty; run: sh install.sh --status"
    return 1
}

show_status() {
    target=$(readlink -f "$STOCK" 2>/dev/null || true)
    msg "board:      $(board_compat)"
    if chip_present; then msg "chip:       AW-NB197SM / BCM43430 ($SDIO_VENDOR:$SDIO_DEVICE)"; else msg "chip:       not found"; fi
    if [ -x "$HOOK" ] && [ -f "$NVRAM" ]; then msg "installed:  $DATA_DIR"; else msg "installed:  no"; fi
    if [ -f "$RULE_FILE" ]; then msg "boot hook:  $RULE_FILE"; else msg "boot hook:  missing"; fi
    if [ -n "$target" ] && is_mounted "$target"; then
        msg "nvram:      26 MHz override bind-mounted on $target"
    else
        msg "nvram:      stock image file"
    fi
    if [ -n "$target" ] && [ -f "$target" ]; then
        msg "xtalfreq:   $(grep '^xtalfreq' "$target" | head -n 1)"
    fi
    if grep -q '^brcmfmac ' /proc/modules 2>/dev/null; then msg "driver:     brcmfmac loaded"; else msg "driver:     brcmfmac module not loaded"; fi
    command -v nmcli >/dev/null 2>&1 && nmcli device status 2>/dev/null | awk 'NR == 1 || $2 == "wifi"'
    if command -v journalctl >/dev/null 2>&1; then
        msg ""
        msg "boot hook log (this boot):"
        journalctl -b -t "$NAME" --no-pager -o cat 2>/dev/null | tail -n 10
    fi
}

do_install() {
    preflight
    cleanup_legacy
    msg "Installing to $DATA_DIR ..."
    write_nvram
    write_hook
    write_rule
    msg "Boot hook: $RULE_FILE"
    msg "Applying now ..."
    if [ "$ACTION" = reapply ]; then /bin/sh "$HOOK" --reload; else /bin/sh "$HOOK"; fi ||
        die "applying failed; see the messages above"
    [ -n "${BNF_DATA_DIR:-}" ] && return 0
    verify
}

do_uninstall() {
    [ "$(id -u)" = 0 ] || die "run as root from the HAOS host shell"
    cleanup_legacy
    rm -f "$RULE_FILE"
    udevadm control --reload-rules 2>/dev/null || true
    if [ -f "$HOOK" ]; then
        /bin/sh "$HOOK" --revert || warn "revert reported an error; a reboot restores the stock state"
    else
        target=$(readlink -f "$STOCK" 2>/dev/null || true)
        [ -n "$target" ] && unmount_all "$target"
        warn "hook not found; reboot to reload the driver with the stock nvram"
    fi
    rm -rf "$DATA_DIR"
    msg "Uninstalled. WiFi is back to the stock (Raspberry Pi) nvram."
}

for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        --status) ACTION=status ;;
        --reapply) ACTION=reapply ;;
        --uninstall) ACTION=uninstall ;;
        -h | --help) usage; exit 0 ;;
        *) usage; die "unknown option: $arg" ;;
    esac
done

case "$ACTION" in
    status) show_status ;;
    uninstall) do_uninstall ;;
    *) do_install ;;
esac
