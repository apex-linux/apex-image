#!/bin/sh
# image/checks/composefs.sh: composefs on, in the image and in the initramfs.
. "$(dirname -- "$0")/lib.sh"

BIN=$T/bin
mkdir -p "$BIN"
cat >"$BIN/lsinitrd" <<'FAKE'
#!/bin/sh
[ "$2" = -f ] || exit 2
initramfs_dir=$(cat "$1")
cat "$initramfs_dir/$3" 2>/dev/null
FAKE
chmod 0755 "$BIN/lsinitrd"

mkroot() {
    root=$T/$1
    image_enabled=$2
    initramfs_enabled=$3
    mkdir -p "$root/usr/lib/ostree" "$root/usr/lib/modules/7.2.7-300.fc45.x86_64" "$root/initramfs/usr/lib/ostree"
    printf '%s\n' "$root/initramfs" >"$root/usr/lib/modules/7.2.7-300.fc45.x86_64/initramfs.img"
    if [ -n "$image_enabled" ]; then printf '[composefs]\nenabled = %s\n[sysroot]\nreadonly = true\n' "$image_enabled" >"$root/usr/lib/ostree/prepare-root.conf"; fi
    if [ -n "$initramfs_enabled" ]; then printf '[composefs]\nenabled = %s\n' "$initramfs_enabled" >"$root/initramfs/usr/lib/ostree/prepare-root.conf"; fi
    printf '%s\n' "$root"
}

check() {
    run env ROOT="$1" PATH="$BIN:$PATH" "$SH" "$CHECKS/composefs.sh"
}

check "$(mkroot on yes yes)"
expect_rc "composefs on in the image and the initramfs passes" 0
expect_out "and names both" '^PASS composefs: the initramfs.s /usr/lib/ostree/prepare-root.conf: \[composefs\] enabled = yes'

check "$(mkroot signed signed signed)"
expect_rc "signed composefs passes" 0

check "$(mkroot maybe maybe maybe)"
expect_rc "maybe is not on" 1
expect_out "and says so" 'enabled = maybe, so / is not a composefs mount'

check "$(mkroot stale yes no)"
expect_rc "an initramfs that turns it off fails, whatever the image says" 1
expect_out "naming the initramfs" "^FAIL composefs: the initramfs.s /usr/lib/ostree/prepare-root.conf: \\[composefs\\] enabled = no"

check "$(mkroot noinitrdconf yes '')"
expect_rc "an initramfs without the file fails" 1

check "$(mkroot noimageconf '' yes)"
expect_rc "an image without the file fails" 1

r=$(mkroot etcwins yes yes)
mkdir -p "$r/etc/ostree"
printf '[composefs]\nenabled = no\n' >"$r/etc/ostree/prepare-root.conf"
check "$r"
expect_rc "/etc/ostree overrides /usr/lib/ostree" 1

r=$(mkroot othersection yes yes)
printf '[sysroot]\nenabled = no\n' >>"$r/usr/lib/ostree/prepare-root.conf"
check "$r"
expect_rc "enabled= in another section does not count" 0

done_testing
