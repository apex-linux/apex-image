#!/bin/sh
# image/checks/system.sh: persistent journal, exactly one NTP client, runbook commands.
. "$(dirname -- "$0")/lib.sh"

command -v systemctl >/dev/null 2>&1 || skip_all "systemctl not found (needed for offline is-enabled)"

OVERLAY=$IMAGE_DIR/system_files
COMMANDS='tar passwd journalctl busctl bootc cryptsetup grub2-editenv efibootmgr findmnt lsblk mount'

# mkroot NAME: prints the path of a root with the overlay's journald drop-in, chronyd
# enabled and systemd-timesyncd not, and every runbook command.
mkroot() {
    r=$T/$1
    u=$r/usr/lib/systemd/system
    mkdir -p "$u" "$r/etc/systemd/system/multi-user.target.wants" "$r/usr/bin" \
        "$r/usr/lib/systemd/ntp-units.d" "$r/usr/lib/systemd/journald.conf.d"
    cp "$OVERLAY/usr/lib/systemd/journald.conf.d/10-apex-persistent.conf" \
        "$r/usr/lib/systemd/journald.conf.d/"
    printf '[Journal]\n#Storage=auto\n' >"$r/usr/lib/systemd/journald.conf"
    printf 'chronyd.service\n' >"$r/usr/lib/systemd/ntp-units.d/50-chronyd.list"
    printf '# systemd\nsystemd-timesyncd.service\n' >"$r/usr/lib/systemd/ntp-units.d/80-systemd-timesync.list"
    for s in chronyd systemd-timesyncd; do
        printf '[Service]\nExecStart=/usr/bin/true\n[Install]\nWantedBy=multi-user.target\n' >"$u/$s.service"
    done
    ln -s /usr/lib/systemd/system/chronyd.service "$r/etc/systemd/system/multi-user.target.wants/chronyd.service"
    for c in $COMMANDS; do
        printf '#!/bin/sh\n' >"$r/usr/bin/$c"
        chmod 0755 "$r/usr/bin/$c"
    done
    printf '%s\n' "$r"
}

sys_check() {
    run env ROOT="$1" "$SH" "$CHECKS/system.sh"
}

r=$(mkroot good)
sys_check "$r"
expect_rc "the Apex configuration passes" 0
expect_out "journal is persistent through the overlay drop-in" \
    '^PASS system: journald Storage=persistent .*10-apex-persistent\.conf'
expect_out "chronyd is the one NTP client" '^PASS system: exactly one NTP client is enabled:.*chronyd\.service=enabled'

r=$(mkroot nodropin)
rm "$r/usr/lib/systemd/journald.conf.d/10-apex-persistent.conf"
sys_check "$r"
expect_rc "without the drop-in the check fails" 1
expect_out "and names the default" '^FAIL system: journald Storage=auto \(the default\)'

r=$(mkroot masked)
mkdir -p "$r/etc/systemd/journald.conf.d"
ln -s /dev/null "$r/etc/systemd/journald.conf.d/10-apex-persistent.conf"
sys_check "$r"
expect_rc "a masked drop-in fails" 1

r=$(mkroot later)
printf '[Journal]\nStorage=volatile\n' >"$r/usr/lib/systemd/journald.conf.d/90-volatile.conf"
sys_check "$r"
expect_rc "a later drop-in with Storage=volatile fails" 1
expect_out "and reports the effective value" '^FAIL system: journald Storage=volatile'

r=$(mkroot othersection)
printf '[Other]\nStorage=persistent\n' >"$r/usr/lib/systemd/journald.conf.d/05-other.conf"
rm "$r/usr/lib/systemd/journald.conf.d/10-apex-persistent.conf"
sys_check "$r"
expect_rc "Storage= outside [Journal] does not count" 1

r=$(mkroot nontp)
rm "$r/etc/systemd/system/multi-user.target.wants/chronyd.service"
sys_check "$r"
expect_rc "no enabled NTP client fails" 1
expect_out "and says so" '^FAIL system: no NTP client is enabled'

r=$(mkroot twontp)
ln -s /usr/lib/systemd/system/systemd-timesyncd.service \
    "$r/etc/systemd/system/multi-user.target.wants/systemd-timesyncd.service"
sys_check "$r"
expect_rc "two enabled NTP clients fail" 1

r=$(mkroot nolist)
rm "$r"/usr/lib/systemd/ntp-units.d/*.list
sys_check "$r"
expect_rc "no ntp-units.d list fails" 1

r=$(mkroot notar)
rm "$r/usr/bin/tar"
sys_check "$r"
expect_rc "a missing runbook command fails" 1
expect_out "and names it" '^FAIL system: command missing: tar'

r=$(mkroot bios)
mkdir -p "$r/usr/lib/bootupd/updates"
printf '{}\n' >"$r/usr/lib/bootupd/updates/BIOS.json"
sys_check "$r"
expect_rc "a bootupd BIOS component fails" 1
expect_out "and is named" '^FAIL system: bootupd has a BIOS component'

done_testing
