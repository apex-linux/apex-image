#!/bin/sh
# The one kernel and its initramfs: early KMS and microcode, the LUKS2 unlock, and no
# driver that must load from the root (snd-hda-intel) or must not bind the dGPU.
set -eu
CHECK_NAME=kernel
APEX_CHECKS_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$APEX_CHECKS_DIR/lib/common.sh"

MODDIR=$(rootpath /usr/lib/modules)

count=0
kver=
found=
for d in "$MODDIR"/*; do
    if [ -d "$d" ]; then
        count=$((count + 1))
        kver=${d##*/}
        found="$found $kver"
    fi
done
if [ "$count" -ne 1 ]; then
    fail "expected exactly one kernel under /usr/lib/modules, found $count:${found:- none}"
    finish
fi
pass "one kernel: $kver"

for f in vmlinuz initramfs.img; do
    if [ -s "$MODDIR/$kver/$f" ]; then
        pass "$f present"
    else
        fail "missing or empty: /usr/lib/modules/$kver/$f"
    fi
done

img=$MODDIR/$kver/initramfs.img
if ! command -v lsinitrd >/dev/null 2>&1; then
    fail "lsinitrd not found on PATH; cannot inspect the initramfs"
    finish
fi
if [ ! -s "$img" ]; then
    finish
fi

make_tmpdir
if ! lsinitrd "$img" >"$TMPD/listing" 2>"$TMPD/lsinitrd.err"; then
    fail "lsinitrd failed on $img: $(head -n 3 "$TMPD/lsinitrd.err" | paste -sd ' ' -)"
    finish
fi

initramfs_has() { grep -Eq -- "$1" "$TMPD/listing"; }

if initramfs_has 'kernel/x86/microcode/AuthenticAMD\.bin'; then
    pass "early AMD microcode (kernel/x86/microcode/AuthenticAMD.bin) in the early cpio"
else
    fail "AMD early microcode missing from the initramfs (is amd-ucode-firmware installed?)"
fi

if initramfs_has '/amdgpu\.ko(\.(xz|zst|gz))?$'; then
    pass "amdgpu module in the initramfs"
else
    fail "amdgpu module missing from the initramfs"
fi

fwcount=$(grep -Ec 'lib/firmware/amdgpu/green_sardine_' "$TMPD/listing" || true)
if [ "$fwcount" -gt 0 ]; then
    pass "amdgpu green_sardine firmware in the initramfs ($fwcount file(s))"
else
    fail "amdgpu green_sardine firmware missing from the initramfs"
fi

if initramfs_has '/snd-hda-intel\.ko(\.(xz|zst|gz))?$'; then
    fail "snd-hda-intel is in the initramfs; the ALC294 patch firmware would not be applied"
else
    pass "snd-hda-intel not in the initramfs"
fi

if initramfs_has '/(nouveau|nova[-_]core|nova[-_]drm)\.ko(\.(xz|zst|gz))?$'; then
    fail "nouveau or nova-core is in the initramfs; it could bind the dGPU before the root's blacklist applies"
else
    pass "nouveau and nova-core not in the initramfs"
fi

# lsinitrd prints the dracut modules one per line between "dracut modules:" and the next
# line of '=' characters; the file listing follows.
awk '/^=+$/ { if (m) exit } m && NF { print $1 } $0 == "dracut modules:" { m = 1 }' \
    "$TMPD/listing" >"$TMPD/modules"
for mod in crypt systemd-cryptsetup; do
    if grep -Fxq -- "$mod" "$TMPD/modules"; then
        pass "dracut module $mod in the initramfs"
    else
        fail "dracut module $mod missing from the initramfs; the LUKS2 root cannot be unlocked (are cryptsetup and systemd-udev installed?)"
    fi
done

# usr/lib/systemd/systemd-cryptsetup may be a symlink to the binary in usr/bin.
if grep -Eq -- '^-.* (\./)?usr/(bin|lib/systemd)/systemd-cryptsetup$' "$TMPD/listing"; then
    pass "systemd-cryptsetup in the initramfs"
else
    fail "systemd-cryptsetup binary missing from the initramfs"
fi
if initramfs_has ' (\./)?usr/lib/systemd/system-generators/systemd-cryptsetup-generator( -> .*)?$'; then
    pass "systemd-cryptsetup-generator in the initramfs"
else
    fail "systemd-cryptsetup-generator missing from the initramfs"
fi
if initramfs_has '/libcryptsetup\.so\.[0-9][0-9.]*( -> .*)?$'; then
    pass "libcryptsetup in the initramfs"
else
    fail "libcryptsetup missing from the initramfs; systemd-cryptsetup loads it at run time"
fi
if initramfs_has '/dm-crypt\.ko(\.(xz|zst|gz))?$'; then
    pass "dm-crypt module in the initramfs"
elif grep -Eq '(^|/)dm-crypt\.ko$' "$MODDIR/$kver/modules.builtin" 2>/dev/null; then
    pass "dm-crypt built into the kernel (modules.builtin)"
else
    fail "dm-crypt missing: not in the initramfs and not built into the kernel"
fi

blacklisted=
for f in "$(rootpath /usr/lib/modprobe.d)"/*.conf "$(rootpath /etc/modprobe.d)"/*.conf; do
    [ -f "$f" ] || continue
    if grep -Eq '^[[:space:]]*(blacklist[[:space:]]+nouveau|install[[:space:]]+nouveau[[:space:]]+/(usr/)?bin/(false|true))([[:space:]]|$)' "$f"; then
        blacklisted=$(unroot "$f")
        break
    fi
done
if [ -z "$blacklisted" ]; then
    for f in "$(rootpath /usr/lib/bootc/kargs.d)"/*.toml; do
        [ -f "$f" ] || continue
        if grep -Eq '(modprobe\.blacklist|rd\.driver\.blacklist|module_blacklist)=[^"[:space:]]*nouveau' "$f"; then
            blacklisted="$(unroot "$f") (kernel argument)"
            break
        fi
    done
fi
if [ -n "$blacklisted" ]; then
    pass "nouveau blacklisted by $blacklisted"
else
    fail "nouveau is not blacklisted in /usr/lib/modprobe.d, /etc/modprobe.d or /usr/lib/bootc/kargs.d"
fi

finish
