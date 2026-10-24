#!/bin/sh
# The dGPU's half of the kernel pair (ADR 0015): the kmod built for exactly this kernel and
# negativo17's userspace, or, without the pair or its NVIDIA set, an unbound dGPU.
set -eu
CHECK_NAME=nvidia
APEX_CHECKS_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$APEX_CHECKS_DIR/lib/common.sh"

MODDIR=$(rootpath /usr/lib/modules)
PAIR_FILES="/usr/lib/bootc/kargs.d/20-apex-pair.toml /usr/lib/modprobe.d/apex-nvidia.conf /usr/lib/udev/rules.d/61-apex-dgpu.rules /usr/lib/systemd/system-preset/79-apex-pair.preset"
# The kmod is built for the image, never on it, and only the Wayland userspace ships.
NEVER="akmods akmod-nvidia dkms dkms-nvidia kmodtool xorg-x11-nvidia nvidia-settings nvidia-xconfig"

installed() { root_rpm -q "$1" >/dev/null 2>&1; }

kmods() { root_rpm -qa --queryformat '%{NAME}\n' | grep '^kmod-nvidia' || true; }

no_nvidia_set() {
    left=$(kmods | paste -sd ' ' -)
    for n in nvidia-kmod-common nvidia-driver nvidia-driver-libs; do
        if installed "$n"; then left="$left $n"; fi
    done
    if [ -z "${left# }" ]; then
        pass "no kmod-nvidia and no NVIDIA userspace"
    else
        fail "NVIDIA packages without a kmod for this kernel: ${left# }"
    fi
}

mode=$(pair_mode)

if [ "$mode" = none ]; then
    no_nvidia_set
    for f in $PAIR_FILES; do
        if [ -e "$(rootpath "$f")" ]; then fail "$f is the pair's, but rpms.lock has no kernel pair"; fi
    done
    pass "no kernel pair: Fedora's kernel, and the dGPU stays unbound"
    finish
fi

set -- "$MODDIR"/*
kver=${1##*/}

shipped=
for n in $NEVER; do
    if installed "$n"; then shipped="$shipped $n"; fi
done
if [ -z "$shipped" ]; then
    pass "none of: $NEVER"
else
    fail "installed, though ADR 0015 excludes them:$shipped"
fi
if [ -d "$(rootpath /usr/src/kernels)" ]; then
    fail "/usr/src/kernels exists: a kernel's build tree shipped in the image"
fi

for f in /usr/lib/modprobe.d/apex-nvidia.conf /usr/lib/udev/rules.d/61-apex-dgpu.rules; do
    if [ -f "$(rootpath "$f")" ]; then pass "$f present"; else fail "$f missing"; fi
done
for f in /usr/lib/modprobe.d/apex-dgpu.conf /usr/lib/udev/rules.d/61-apex-dgpu-pm.rules; do
    if [ -e "$(rootpath "$f")" ]; then fail "$f is the Fedora kernel's, and the pair replaces it"; fi
done
if grep -Eq '^[[:space:]]*options[[:space:]]+nvidia[[:space:]].*NVreg_DynamicPowerManagement=0x02' \
    "$(rootpath /usr/lib/modprobe.d/apex-nvidia.conf)" 2>/dev/null; then
    pass "fine-grained RTD3 (NVreg_DynamicPowerManagement=0x02)"
else
    fail "apex-nvidia.conf does not set NVreg_DynamicPowerManagement=0x02"
fi
wants=$(find "$(rootpath /etc/systemd/system)" "$(rootpath /usr/lib/systemd/system)" -name nvidia-persistenced.service \
    -path '*.wants/*' 2>/dev/null || true)
if [ -z "$wants" ]; then
    pass "nvidia-persistenced is not enabled"
else
    fail "nvidia-persistenced is enabled ($(unroot "$wants" | paste -sd ' ' -)); it keeps the dGPU awake"
fi

# The kernel's %posttrans and nvidia-kmod-common's %post skip their bootloader work under
# rpm-ostree (K1); a compose that ran them would leave these behind.
for f in /etc/kernel/cmdline /etc/default/grub; do
    if [ -e "$(rootpath "$f")" ]; then fail "$f exists: a scriptlet edited the bootloader configuration"; fi
done
boot=$(find "$(rootpath /boot)" -mindepth 1 -maxdepth 1 2>/dev/null | sed 's|.*/||' | paste -sd ' ' -)
if [ -n "$boot" ]; then
    fail "/boot is not empty: $boot"
else
    pass "no bootloader configuration and an empty /boot"
fi

if [ "$mode" = pair-degraded ]; then
    no_nvidia_set
    manifest=$(rootpath /usr/share/apex/manifest.json)
    if [ -f "$manifest" ] && python3 -c 'import json, sys; sys.exit("nvidia" not in json.load(open(sys.argv[1])).get("degraded", []))' "$manifest" 2>/dev/null; then
        pass "manifest.json lists degraded=nvidia"
    else
        fail "the image takes the kernel without its NVIDIA set, but manifest.json does not list degraded=nvidia"
    fi
    warn "degraded=nvidia: the dGPU stays unbound in D3cold until a whole pair builds"
    finish
fi

kmod=kmod-nvidia-$kver
locked=$(pair_locked "$kmod")
have=$(root_rpm -q --queryformat '%{NAME}-%{EPOCHNUM}:%{VERSION}-%{RELEASE}.%{ARCH}' "$kmod" 2>/dev/null || true)
if [ -n "$locked" ] && [ "$have" = "$locked" ]; then
    pass "$locked, built for this kernel"
else
    fail "$kmod is ${have:-not installed}, but rpms.lock locks ${locked:-none}"
fi
others=$(kmods | grep -vx "$kmod" || true)
if [ -n "$others" ]; then fail "kmods for another kernel: $(printf '%s\n' "$others" | paste -sd ' ' -)"; fi
if installed "$kmod" && signed_by "$APEX_RPM_KEYID" "$kmod"; then
    pass "$kmod is signed by the Apex RPM key"
else
    fail "$kmod is not signed by the Apex RPM key ($APEX_RPM_KEYID)"
fi

version=$(root_rpm -q --queryformat '%{VERSION}' "$kmod" 2>/dev/null || true)
for n in nvidia-kmod-common nvidia-driver; do
    v=$(root_rpm -q --queryformat '%{VERSION}' "$n" 2>/dev/null || true)
    if [ -n "$version" ] && [ "$v" = "$version" ]; then
        pass "$n $v, the kmod's version"
    else
        fail "$n is ${v:-not installed}, not the kmod's version ${version:-?}"
    fi
done

gsp=$(find "$(rootpath /usr/lib/firmware/nvidia)" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*' 2>/dev/null |
    sed 's|.*/||' | sort -u | paste -sd ' ' -)
if [ -n "$version" ] && [ "$gsp" = "$version" ]; then
    pass "GSP firmware $gsp, the kmod's version"
else
    fail "the GSP firmware under /usr/lib/firmware/nvidia is ${gsp:-missing}, not the kmod's ${version:-?} alone"
fi
if ls "$(rootpath /usr/share/licenses)"/nvidia-*/* >/dev/null 2>&1; then
    pass "the NVIDIA licence ships"
else
    fail "no NVIDIA licence under /usr/share/licenses"
fi

# As modprobe reads them: by file name, /etc over /usr/lib, and the kernel keeps the last value.
effective() {
    for d in "$(rootpath /usr/lib/modprobe.d)" "$(rootpath /etc/modprobe.d)"; do
        for f in "$d"/*.conf; do [ -f "$f" ] && printf '%s %s\n' "${f##*/}" "$f"; done
    done | awk '{ path[$1] = $2 } END { for (n in path) print n, path[n] }' | sort |
        while read -r _ f; do cat "$f"; done |
        awk -v p="$1" '$1 == "options" && $2 == "nvidia" { for (i = 3; i <= NF; i++) if (index($i, p "=") == 1) v = substr($i, length(p) + 2) } END { print v }'
}
for want in NVreg_DynamicPowerManagement=0x02 NVreg_EnableS0ixPowerManagement=1 NVreg_PreserveVideoMemoryAllocations=1; do
    got=$(effective "${want%%=*}")
    if [ "$got" = "${want#*=}" ]; then
        pass "options nvidia: $want in effect"
    else
        fail "options nvidia: ${want%%=*} is '${got:-unset}' in effect, not ${want#*=}"
    fi
done

find "$MODDIR/$kver" -type f -name 'nvidia*.ko*' >"${TMPDIR:-/tmp}/apex-nvidia-modules.$$"
mods=$(cat "${TMPDIR:-/tmp}/apex-nvidia-modules.$$")
rm -f "${TMPDIR:-/tmp}/apex-nvidia-modules.$$"
if [ -z "$mods" ]; then
    fail "no NVIDIA module under /usr/lib/modules/$kver"
elif ! command -v modinfo >/dev/null 2>&1; then
    fail "modinfo not found on PATH; cannot read the NVIDIA modules' vermagic"
else
    wrong=
    for m in $mods; do
        magic=$(modinfo -F vermagic "$m" 2>/dev/null || true)
        case $magic in
            "$kver "*) ;;
            *) wrong="$wrong $(unroot "$m") ('${magic:-none}')" ;;
        esac
    done
    if [ -z "$wrong" ]; then
        pass "the NVIDIA modules' vermagic is $kver"
    else
        fail "NVIDIA modules not built for $kver:$wrong"
    fi
fi

finish
