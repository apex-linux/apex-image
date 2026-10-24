# shellcheck shell=sh disable=SC2034 # t-kernel.sh and t-nvidia.sh read the variables
# pair_root NAME MODE: a fake image root and rpms/ for kernel.sh and nvidia.sh, MODE being
# fedora (Fedora's kernel, no pair), pair or degraded (the pair's kernel, no NVIDIA set).

KVER=7.3.0-4.cachyos1.fc45.x86_64
FEDORA_KVER=7.2.9-200.fc45.x86_64
SIGNER="Apex kernel $KVER s0123456789ab"
KMOD=kmod-nvidia-$KVER
APEX_SIG="EdDSA/SHA512, Sat Oct 24 2026, Key ID 8da3252bd6ef25fa"
FEDORA_SIG="RSA/SHA256, Mon Sep 14 2026, Key ID 655a4b02f577861e"
NEGATIVO17_SIG="RSA/SHA512, Wed Oct 21 2026, Key ID 97f3008993e8909b"

# initramfs_listing KVER: what lsinitrd prints for an initramfs that passes kernel.sh.
initramfs_listing() {
    cat <<EOF
Image: initramfs.img: 40M
========================================================================
dracut modules:
crypt
systemd-cryptsetup
========================================================================
-rw-r--r--   1 root root 0 Jan  1 00:00 kernel/x86/microcode/AuthenticAMD.bin
-rw-r--r--   1 root root 0 Jan  1 00:00 usr/lib/modules/$1/kernel/drivers/gpu/drm/amd/amdgpu/amdgpu.ko.xz
-rw-r--r--   1 root root 0 Jan  1 00:00 usr/lib/firmware/amdgpu/green_sardine_dmcub.bin
-rwxr-xr-x   1 root root 0 Jan  1 00:00 usr/lib/systemd/systemd-cryptsetup
lrwxrwxrwx   1 root root 0 Jan  1 00:00 usr/lib/systemd/system-generators/systemd-cryptsetup-generator -> ../systemd-cryptsetup
-rwxr-xr-x   1 root root 0 Jan  1 00:00 usr/lib64/libcryptsetup.so.12.10.0
-rw-r--r--   1 root root 0 Jan  1 00:00 usr/lib/modules/$1/kernel/drivers/md/dm-crypt.ko.xz
EOF
}

# module FILE VERMAGIC SIGNER: a fake module as the fake modinfo reads it.
module() {
    mkdir -p "$(dirname -- "$1")"
    printf 'vermagic: %s SMP preempt mod_unload\n' "$2" >"$1"
    if [ -n "$3" ]; then printf 'signer: %s\n' "$3" >>"$1"; fi
}

pair_root() {
    R=$T/$1
    RPMS=$T/$1-rpms
    mode=$2
    kver=$KVER
    [ "$mode" != fedora ] || kver=$FEDORA_KVER
    m=$R/usr/lib/modules/$kver
    mkdir -p "$m" "$R/usr/share/apex" "$R/usr/lib/modprobe.d" "$RPMS/pair"
    printf 'kernel\n' >"$m/vmlinuz"
    initramfs_listing "$kver" >"$m/initramfs.img"
    : >"$m/modules.builtin"
    printf 'CONFIG_MODULE_SIG=y\nCONFIG_MODULE_SIG_SHA512=y\nCONFIG_DEBUG_INFO_BTF=y\nCONFIG_HZ=1000\n' >"$m/config"
    printf '# the pins\nCONFIG_MODULE_SIG=y\nCONFIG_DEBUG_INFO_BTF=y\n' >"$RPMS/pair/config-required.txt"
    module "$m/kernel/fs/erofs/erofs.ko.xz" "$kver" "$SIGNER"
    module "$m/kernel/drivers/md/dm-crypt.ko.xz" "$kver" "$SIGNER"
    sha=$(printf '%064d' 0 | tr 0 a)
    {
        printf '# apex rpms.lock 1: written by apex-lane\n'
        if [ "$mode" = degraded ]; then
            printf 'family kernel-cachyos built kernel-cachyos-7.3.0-4.cachyos1.fc45-sd123456789ab since=2026-12-01T00:00:00Z degraded=nvidia side=kmod reason=kmod: it does not build\n'
        elif [ "$mode" = pair ]; then
            printf 'family kernel-cachyos built kernel-cachyos-7.3.0-4.cachyos1.fc45-s0123456789ab\n'
        fi
        if [ "$mode" != fedora ]; then
            for n in kernel-cachyos kernel-cachyos-core kernel-cachyos-modules; do
                printf 'rpm kernel-cachyos built %s %s-0:%s %s pkgs/kernel/k/%s-%s.rpm\n' "$n" "$n" "$KVER" "$sha" "$n" "$KVER"
            done
        fi
        if [ "$mode" = pair ]; then
            printf 'rpm kernel-cachyos built %s %s-3:615.78.08-1.fc45.x86_64 %s pkgs/kernel/k/%s-615.78.08-1.fc45.x86_64.rpm\n' "$KMOD" "$KMOD" "$sha" "$KMOD"
            printf 'rpm kernel-cachyos mirror nvidia-kmod-common nvidia-kmod-common-3:615.78.08-1.fc45.noarch %s pkgs/kernel/k/nvidia-kmod-common-615.78.08-1.fc45.noarch.rpm\n' "$sha"
        fi
    } >"$R/usr/share/apex/rpms.lock"
    if [ "$mode" = fedora ]; then
        cp "$IMAGE_DIR/system_files/usr/lib/modprobe.d/apex-dgpu.conf" "$R/usr/lib/modprobe.d/"
        mkdir -p "$R/usr/lib/udev/rules.d"
        cp "$IMAGE_DIR/system_files/usr/lib/udev/rules.d/61-apex-dgpu-pm.rules" "$R/usr/lib/udev/rules.d/"
        printf '{"kernel-core": {"evr": "7.2.9-200.fc45", "signature": "%s", "sourcerpm": "kernel-7.2.9-200.fc45.src.rpm"}}\n' \
            "$FEDORA_SIG" >"$R/rpmdb.json"
        printf '{"degraded": [], "held": []}\n' >"$R/usr/share/apex/manifest.json"
        return 0
    fi
    cp -R "$IMAGE_DIR/variants/pair/." "$R/"
    {
        printf '{"kernel-cachyos-core": {"evr": "7.3.0-4.cachyos1.fc45", "signature": "%s"},\n' "$APEX_SIG"
        printf ' "kernel-headers": {"evr": "7.3.0-1.fc45", "signature": "%s", "sourcerpm": "kernel-headers-7.3.0-1.fc45.src.rpm"}' "$FEDORA_SIG"
        if [ "$mode" = pair ]; then
            printf ',\n "%s": {"evr": "3:615.78.08-1.fc45", "signature": "%s"},\n' "$KMOD" "$APEX_SIG"
            printf ' "nvidia-kmod-common": {"evr": "3:615.78.08-1.fc45", "arch": "noarch", "signature": "%s"},\n' "$NEGATIVO17_SIG"
            printf ' "nvidia-driver": {"evr": "3:615.78.08-1.fc45", "signature": "%s"}' "$NEGATIVO17_SIG"
        fi
        printf '}\n'
    } >"$R/rpmdb.json"
    if [ "$mode" = pair ]; then
        for n in nvidia nvidia-drm nvidia-modeset nvidia-uvm nvidia-peermem; do
            module "$m/extra/nvidia/$n.ko.xz" "$KVER" "$SIGNER"
        done
        printf '{"degraded": [], "held": []}\n' >"$R/usr/share/apex/manifest.json"
    else
        printf '{"degraded": ["nvidia"], "held": []}\n' >"$R/usr/share/apex/manifest.json"
    fi
}

# check NAME ROOT: run image/checks/NAME.sh on ROOT with the fakes.
check() {
    run env ROOT="$2" APEX_RPMS_DIR="$2-rpms" FAKE_RPMDB="$2/rpmdb.json" PATH="$(fake_path)" \
        "$SH" "$CHECKS/$1.sh"
}

# rpmdb_add ROOT NAME JSON: one more package in ROOT's fake rpm database.
rpmdb_add() {
    python3 - "$1/rpmdb.json" "$2" "$3" <<'PY'
import json, sys
path, name, pkg = sys.argv[1:]
db = json.load(open(path))
db[name] = json.loads(pkg)
json.dump(db, open(path, "w"))
PY
}
