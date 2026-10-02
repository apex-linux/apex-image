#!/bin/sh
# image/checks/overlay.sh with the host's systemd-analyze, udevadm and systemd-tmpfiles
# on a staged root: the committed overlay validates, and a broken line fails.
. "$(dirname -- "$0")/lib.sh"

for tool in systemd-analyze udevadm systemd-tmpfiles; do
    command -v "$tool" >/dev/null 2>&1 || skip_all "$tool not found"
done

# The stubs stand in for what the units run and for the packaged units the overlay's
# drop-ins extend.
stage() {
    name=$1
    src=$T/$name-src
    root=$T/$name
    mkdir -p "$src" "$root/usr/bin"
    ln -s usr/bin "$root/bin"
    cp -R "$IMAGE_DIR/system_files/." "$src/"
    cp -R "$src/." "$root/"
    for b in flatpak sh bash busctl timeout udevadm getent upowerd bootupctl true; do
        printf '#!/bin/sh\nexit 0\n' >"$root/usr/bin/$b"
        chmod 0755 "$root/usr/bin/$b"
    done
    printf '[Unit]\nDescription=Power management\n\n[Service]\nType=dbus\nBusName=org.freedesktop.UPower\nExecStart=/usr/bin/upowerd\n\n[Install]\nWantedBy=graphical.target\n' \
        >"$root/usr/lib/systemd/system/upower.service"
    printf '%s\n' '[Unit]' 'Description=Update bootloader on boot' '' '[Service]' 'Type=oneshot' \
        "ExecCondition=/bin/bash -c '[[ ! \$(findmnt -n -o FSTYPE /sysroot) =~ ^(erofs|squashfs)\$ ]]'" \
        'ExecStart=/usr/bin/bootupctl update' 'RemainAfterExit=yes' 'PrivateNetwork=yes' \
        'ProtectHome=yes' 'KillMode=mixed' 'MountFlags=slave' '' '[Install]' 'WantedBy=multi-user.target' \
        >"$root/usr/lib/systemd/system/bootloader-update.service"
}

overlay() {
    name=$1
    run env ROOT="$T/$name" OVERLAY_DIR="$T/$name-src" "$SH" "$CHECKS/overlay.sh"
}

break_file_in_both_copies() {
    name=$1
    relpath=$2
    sed_edit=$3
    stage "$name"
    sed -i -e "$sed_edit" "$T/$name-src/$relpath" "$T/$name/$relpath"
    if cmp -s "$IMAGE_DIR/system_files/$relpath" "$T/$name/$relpath"; then
        not_ok "fixture $name: the edit changed nothing"
    fi
}

stage good
overlay good
expect_rc "the committed overlay validates" 0
for u in apex-flatpak-preinstall.service apex-flatpak-preinstall.timer \
    apex-flatpak-update.service apex-flatpak-update.timer upower.service bootloader-update.service; do
    expect_out "verified: $u" "^PASS overlay: systemd-analyze verify $u\$"
done
expect_out "verified: the udev rules" '^PASS overlay: udevadm verify /usr/lib/udev/rules.d/61-apex-dgpu-pm.rules$'
expect_out "verified: tmpfiles.d" '^PASS overlay: systemd-tmpfiles --dry-run /usr/lib/tmpfiles.d/apex-upower.conf$'

U=usr/lib/systemd/system
break_file_in_both_copies quoting "$U/apex-flatpak-update.service" "s/^    esac'\$/    esac/"
overlay quoting
expect_rc "unbalanced quoting in the metered gate fails" 1
expect_out "and names the unit" '^FAIL overlay: systemd-analyze verify apex-flatpak-update\.service'

break_file_in_both_copies key "$U/apex-flatpak-preinstall.service" 's/^Nice=19/Nicee=19/'
overlay key
expect_rc "an unknown key fails" 1

break_file_in_both_copies timer "$U/apex-flatpak-update.timer" 's/^OnCalendar=.*/OnCalendar=every sixth hour/'
overlay timer
expect_rc "a bad OnCalendar fails" 1

break_file_in_both_copies dropin "$U/upower.service.d/10-apex-wait-threshold.conf" 's/^ExecStartPre=/ExecStartPree=/'
overlay dropin
expect_rc "a bad key in the upower drop-in fails" 1
expect_out "through upower.service" '^FAIL overlay: systemd-analyze verify upower\.service'

break_file_in_both_copies green "$U/bootloader-update.service.d/10-apex-after-green-boot.conf" "s/^    exit 1'\$/    exit 1/"
overlay green
expect_rc "unbalanced quoting in the green-boot condition fails" 1
expect_out "through bootloader-update.service" '^FAIL overlay: systemd-analyze verify bootloader-update\.service'

break_file_in_both_copies udev usr/lib/udev/rules.d/61-apex-dgpu-pm.rules 's/ATTR{vendor}=="0x10de", /ATTR{vendor}=="0x10de" /'
overlay udev
expect_rc "a udev rule without a comma between tokens fails" 1
expect_out "and names the file" '^FAIL overlay: udevadm verify /usr/lib/udev/rules.d/61-apex-dgpu-pm.rules'

break_file_in_both_copies tmpfiles usr/lib/tmpfiles.d/apex-upower.conf 's/^f /q /; s/0640/06x0/'
overlay tmpfiles
expect_rc "a bad tmpfiles.d line fails" 1

stage missing
rm "$T/missing/$U/apex-flatpak-preinstall.timer"
overlay missing
expect_rc "an overlay unit missing from the root fails" 1

done_testing
