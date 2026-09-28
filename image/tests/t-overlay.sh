#!/bin/sh
# image/checks/overlay.sh with the host's systemd-analyze, udevadm and systemd-tmpfiles
# on a staged root: the committed overlay validates, and a broken line fails.
. "$(dirname -- "$0")/lib.sh"

for tool in systemd-analyze udevadm systemd-tmpfiles; do
    command -v "$tool" >/dev/null 2>&1 || skip_all "$tool not found"
done

# stage NAME: the overlay as $T/NAME-src, installed into $T/NAME with stubs of what the
# units run and of upower.service.
stage() {
    src=$T/$1-src
    r=$T/$1
    mkdir -p "$src" "$r/usr/bin"
    cp -R "$IMAGE_DIR/system_files/." "$src/"
    cp -R "$src/." "$r/"
    for b in flatpak sh busctl timeout udevadm getent upowerd true; do
        printf '#!/bin/sh\nexit 0\n' >"$r/usr/bin/$b"
        chmod 0755 "$r/usr/bin/$b"
    done
    printf '[Unit]\nDescription=Power management\n\n[Service]\nType=dbus\nBusName=org.freedesktop.UPower\nExecStart=/usr/bin/upowerd\n\n[Install]\nWantedBy=graphical.target\n' \
        >"$r/usr/lib/systemd/system/upower.service"
}

overlay() {
    run env ROOT="$T/$1" OVERLAY_DIR="$T/$1-src" "$SH" "$CHECKS/overlay.sh"
}

# break_file NAME RELPATH SED: stage NAME, then edit RELPATH in both copies.
break_file() {
    stage "$1"
    sed -i -e "$3" "$T/$1-src/$2" "$T/$1/$2"
    if cmp -s "$IMAGE_DIR/system_files/$2" "$T/$1/$2"; then
        not_ok "fixture $1: the edit changed nothing"
    fi
}

stage good
overlay good
expect_rc "the committed overlay validates" 0
for u in apex-flatpak-preinstall.service apex-flatpak-preinstall.timer \
    apex-flatpak-update.service apex-flatpak-update.timer upower.service; do
    expect_out "verified: $u" "^PASS overlay: systemd-analyze verify $u\$"
done
expect_out "verified: the udev rules" '^PASS overlay: udevadm verify /usr/lib/udev/rules.d/61-apex-dgpu-pm.rules$'
expect_out "verified: tmpfiles.d" '^PASS overlay: systemd-tmpfiles --dry-run /usr/lib/tmpfiles.d/apex-upower.conf$'

U=usr/lib/systemd/system
break_file quoting "$U/apex-flatpak-update.service" "s/^    esac'\$/    esac/"
overlay quoting
expect_rc "unbalanced quoting in the metered gate fails" 1
expect_out "and names the unit" '^FAIL overlay: systemd-analyze verify apex-flatpak-update\.service'

break_file key "$U/apex-flatpak-preinstall.service" 's/^Nice=19/Nicee=19/'
overlay key
expect_rc "an unknown key fails" 1

break_file timer "$U/apex-flatpak-update.timer" 's/^OnCalendar=.*/OnCalendar=every sixth hour/'
overlay timer
expect_rc "a bad OnCalendar fails" 1

break_file dropin "$U/upower.service.d/10-apex-wait-threshold.conf" 's/^ExecStartPre=/ExecStartPree=/'
overlay dropin
expect_rc "a bad key in the upower drop-in fails" 1
expect_out "through upower.service" '^FAIL overlay: systemd-analyze verify upower\.service'

break_file udev usr/lib/udev/rules.d/61-apex-dgpu-pm.rules 's/ATTR{vendor}=="0x10de", /ATTR{vendor}=="0x10de" /'
overlay udev
expect_rc "a udev rule without a comma between tokens fails" 1
expect_out "and names the file" '^FAIL overlay: udevadm verify /usr/lib/udev/rules.d/61-apex-dgpu-pm.rules'

break_file tmpfiles usr/lib/tmpfiles.d/apex-upower.conf 's/^f /q /; s/0640/06x0/'
overlay tmpfiles
expect_rc "a bad tmpfiles.d line fails" 1

stage missing
rm "$T/missing/$U/apex-flatpak-preinstall.timer"
overlay missing
expect_rc "an overlay unit missing from the root fails" 1

done_testing
