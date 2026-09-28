#!/bin/sh
# System defaults that INSTALL.md and RECOVERY.md rely on on the installed laptop.
#
#   - journald keeps the journal across reboots: the effective Storage= of journald.conf
#     and its drop-ins is "persistent". With the default, auto, logs live only in /run
#     unless /var/log/journal exists, and nothing in the image creates it, so
#     `journalctl -b -1` and reading /var/log/journal from a live USB (RECOVERY.md)
#     would find nothing;
#   - exactly one NTP client is enabled, out of the units listed in ntp-units.d (the
#     same lists timedated uses for Settings' "Automatic Date & Time"): none leaves the
#     clock wrong after every Windows session (local-time RTC, ADR 0010) and after a
#     CMOS reset, two fight over the clock;
#   - the commands the runbooks run on the installed system exist;
#   - the image is UEFI-only: bootupd has no BIOS component, which would otherwise run
#     grub2-install --target i386-pc onto the laptop's disk (grub2-pc itself stays
#     installed: the minimal manifest requires `grub2`, which only it provides).
#
# Environment: ROOT (see lib/common.sh).
set -eu
CHECK_NAME=system
APEX_CHECKS_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$APEX_CHECKS_DIR/lib/common.sh"

# Commands INSTALL.md §9 and RECOVERY.md run on the installed system.
RUNBOOK_COMMANDS='tar passwd journalctl busctl bootc cryptsetup grub2-editenv efibootmgr findmnt lsblk mount'

# systemd configuration directories in priority order (systemd.syntax(7)). /run is left
# out: during the image build it holds only the build's own mounts.
CONF_DIRS='/etc/systemd /usr/local/lib/systemd /usr/lib/systemd'

make_tmpdir

# --- journald Storage= -----------------------------------------------------------
# The main file is the first journald.conf found in CONF_DIRS; then the drop-ins of
# every journald.conf.d, sorted by file name, where a name in a higher-priority
# directory hides the same name in a lower one. The last Storage= in [Journal] wins.
: >"$TMPD/journald-files"
for d in $CONF_DIRS; do
    f=$(rootpath "$d/journald.conf")
    if [ -f "$f" ]; then
        printf '%s\n' "$f" >>"$TMPD/journald-files"
        break
    fi
done
for d in $CONF_DIRS; do
    for f in "$(rootpath "$d/journald.conf.d")"/*.conf; do
        if [ -e "$f" ] || [ -L "$f" ]; then basename -- "$f"; fi
    done
done | sort -u >"$TMPD/journald-dropins"
while IFS= read -r name; do
    for d in $CONF_DIRS; do
        f=$(rootpath "$d/journald.conf.d/$name")
        if [ -e "$f" ] || [ -L "$f" ]; then
            printf '%s\n' "$f" >>"$TMPD/journald-files"
            break
        fi
    done
done <"$TMPD/journald-dropins"

# One stream, with a marker line before each file so a section never carries over.
while IFS= read -r f; do
    printf '[apex-check-next-file]\n'
    # A drop-in masked with a symlink to /dev/null reads as empty.
    cat -- "$f" 2>/dev/null || true
    printf '\n'
done <"$TMPD/journald-files" >"$TMPD/journald-merged"
storage=$(awk '
    /^[[:space:]]*\[/ { section = $0; gsub(/[[:space:]]/, "", section); next }
    section == "[Journal]" && /^[[:space:]]*Storage[[:space:]]*=/ {
        value = $0
        sub(/^[^=]*=[[:space:]]*/, "", value)
        sub(/[[:space:]]+$/, "", value)
        storage = value
    }
    END { print storage }' "$TMPD/journald-merged")
files=$(while IFS= read -r f; do unroot "$f"; done <"$TMPD/journald-files" | paste -sd ' ' -)
if [ "$storage" = persistent ]; then
    pass "journald Storage=persistent (from: ${files:-no files})"
else
    fail "journald Storage=${storage:-auto (the default)}, not persistent: the journal is lost at every reboot (files: ${files:-none})"
fi

# --- NTP -------------------------------------------------------------------------
# is_enabled UNIT: prints the enablement state (systemctl works offline on ROOT).
is_enabled() {
    if [ "$ROOT" = / ]; then
        systemctl is-enabled "$1" </dev/null 2>/dev/null || true
    else
        systemctl --root="$ROOT" is-enabled "$1" </dev/null 2>/dev/null || true
    fi
}

for d in $CONF_DIRS; do
    for f in "$(rootpath "$d/ntp-units.d")"/*.list; do
        if [ -f "$f" ]; then read_list "$f"; fi
    done
done | sort -u >"$TMPD/ntp-units"
if [ ! -s "$TMPD/ntp-units" ]; then
    fail "no NTP unit is installed (no unit listed in ntp-units.d)"
else
    enabled='' states=''
    while IFS= read -r unit; do
        state=$(is_enabled "$unit")
        states="$states $unit=${state:-not-found}"
        if [ "$state" = enabled ]; then enabled="$enabled $unit"; fi
    done <"$TMPD/ntp-units"
    # shellcheck disable=SC2086 # split the unit list on purpose
    set -- $enabled
    case $# in
        1) pass "exactly one NTP client is enabled:$states" ;;
        0) fail "no NTP client is enabled:$states" ;;
        *) fail "$# NTP clients are enabled, expected exactly one:$states" ;;
    esac
fi

# --- UEFI only --------------------------------------------------------------------
if [ -e "$(rootpath /usr/lib/bootupd/updates/BIOS.json)" ]; then
    fail "bootupd has a BIOS component (/usr/lib/bootupd/updates/BIOS.json): bootc install would run grub2-install --target i386-pc"
else
    pass "bootupd has no BIOS component"
fi

# --- Runbook commands ------------------------------------------------------------
for c in $RUNBOOK_COMMANDS; do
    if [ -x "$(rootpath "/usr/bin/$c")" ] || [ -x "$(rootpath "/usr/sbin/$c")" ]; then
        pass "command present: $c"
    else
        fail "command missing: $c (INSTALL.md/RECOVERY.md use it on the installed system)"
    fi
done

finish
