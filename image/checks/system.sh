#!/bin/sh
# What the install and recovery runbooks rely on: a persistent journal, exactly one NTP
# client, a UEFI-only bootupd and the commands they run.
set -eu
CHECK_NAME=system
APEX_CHECKS_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$APEX_CHECKS_DIR/lib/common.sh"

RUNBOOK_COMMANDS='tar passwd journalctl busctl bootc cryptsetup grub2-editenv efibootmgr findmnt lsblk mount'

# In priority order (systemd.syntax(7)). Not /run: during the build it holds only mounts.
CONF_DIRS='/etc/systemd /usr/local/lib/systemd /usr/lib/systemd'

make_tmpdir

# The first journald.conf, then every journald.conf.d drop-in by file name; a name in a
# higher-priority directory hides the same name in a lower one.
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

if [ -e "$(rootpath /usr/lib/bootupd/updates/BIOS.json)" ]; then
    fail "bootupd has a BIOS component (/usr/lib/bootupd/updates/BIOS.json): bootc install would run grub2-install --target i386-pc"
else
    pass "bootupd has no BIOS component"
fi

for c in $RUNBOOK_COMMANDS; do
    if [ -x "$(rootpath "/usr/bin/$c")" ] || [ -x "$(rootpath "/usr/sbin/$c")" ]; then
        pass "command present: $c"
    else
        fail "command missing: $c (INSTALL.md/RECOVERY.md use it on the installed system)"
    fi
done

finish
