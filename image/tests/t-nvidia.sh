#!/bin/sh
. "$(dirname -- "$0")/lib.sh"
. "$TESTS_DIR/pair-root.sh"

command -v python3 >/dev/null 2>&1 || skip_all "python3 not found"

pair_root fedora fedora
check nvidia "$R"
expect_rc "Fedora's kernel: passes" 0
expect_out "and says the dGPU stays unbound" '^PASS nvidia: no kernel pair: Fedora.s kernel, and the dGPU stays unbound$'

pair_root fedora-files fedora
cp "$IMAGE_DIR/variants/pair/usr/lib/modprobe.d/apex-nvidia.conf" "$R/usr/lib/modprobe.d/"
check nvidia "$R"
expect_rc "Fedora's kernel with a pair-only file: fails" 1
expect_out "and names it" '^FAIL nvidia: /usr/lib/modprobe.d/apex-nvidia.conf is the pair.s'

pair_root fedora-kmod fedora
rpmdb_add "$R" kmod-nvidia-7.2.9-200.fc45.x86_64 '{"evr": "3:615.78.08-1.fc45"}'
check nvidia "$R"
expect_rc "Fedora's kernel with a kmod: fails" 1
expect_out "and names it" '^FAIL nvidia: NVIDIA packages without a kmod for this kernel: kmod-nvidia-7\.2\.9'

pair_root pair pair
check nvidia "$R"
expect_rc "the pair: passes" 0
expect_out "the locked kmod" "^PASS nvidia: $KMOD-3:615\\.78\\.08-1\\.fc45\\.x86_64, built for this kernel\$"
expect_out "signed by the Apex RPM key" "^PASS nvidia: $KMOD is signed by the Apex RPM key\$"
expect_out "one NVIDIA version" '^PASS nvidia: nvidia-driver 615\.78\.08, the kmod.s version$'
expect_out "the modules' vermagic" "^PASS nvidia: the NVIDIA modules' vermagic is $KVER\$"
expect_out "fine-grained RTD3" '^PASS nvidia: fine-grained RTD3'
expect_out "GSP firmware of the kmod's version" '^PASS nvidia: GSP firmware 615\.78\.08, the kmod.s version$'
expect_out "the effective options" '^PASS nvidia: options nvidia: NVreg_EnableS0ixPowerManagement=1 in effect$'

pair_root pair-unsigned pair
sed -i "s/\"$KMOD\": {\"evr\": \"3:615.78.08-1.fc45\", \"signature\": \"[^\"]*\"}/\"$KMOD\": {\"evr\": \"3:615.78.08-1.fc45\"}/" "$R/rpmdb.json"
check nvidia "$R"
expect_rc "an unsigned kmod: fails" 1
expect_out "and says so" "^FAIL nvidia: $KMOD is not signed by the Apex RPM key"

pair_root pair-other pair
sed -i 's/"nvidia-driver": {"evr": "3:615.78.08-1.fc45"/"nvidia-driver": {"evr": "3:615.80.01-1.fc45"/' "$R/rpmdb.json"
check nvidia "$R"
expect_rc "a userspace of another version: fails" 1
expect_out "and names it" '^FAIL nvidia: nvidia-driver is 615\.80\.01, not the kmod.s version 615\.78\.08$'

pair_root pair-vermagic pair
module "$R/usr/lib/modules/$KVER/extra/nvidia/nvidia-uvm.ko.xz" 7.2.9-200.fc45.x86_64 "$SIGNER"
check nvidia "$R"
expect_rc "a module built for another kernel: fails" 1
expect_out "and names it" '^FAIL nvidia: NVIDIA modules not built for .*nvidia-uvm\.ko\.xz'

pair_root pair-relock pair
sed -i "s/^rpm kernel-cachyos built $KMOD $KMOD-3:615.78.08-1/rpm kernel-cachyos built $KMOD $KMOD-3:615.78.08-2/" "$R/usr/share/apex/rpms.lock"
check nvidia "$R"
expect_rc "a kmod other than the locked one: fails" 1
expect_out "and names both" "^FAIL nvidia: $KMOD is $KMOD-3:615\\.78\\.08-1\\.fc45\\.x86_64, but rpms\\.lock locks $KMOD-3:615\\.78\\.08-2"

pair_root pair-akmods pair
rpmdb_add "$R" akmods '{}'
rpmdb_add "$R" nvidia-settings '{}'
check nvidia "$R"
expect_rc "akmods or nvidia-settings installed: fails" 1
expect_out "and names them" '^FAIL nvidia: installed, though ADR 0015 excludes them: akmods nvidia-settings$'

pair_root pair-old-files pair
cp "$IMAGE_DIR/system_files/usr/lib/modprobe.d/apex-dgpu.conf" "$R/usr/lib/modprobe.d/"
check nvidia "$R"
expect_rc "the Fedora kernel's apex-dgpu.conf left in a pair image: fails" 1

pair_root pair-persistenced pair
mkdir -p "$R/etc/systemd/system/multi-user.target.wants"
: >"$R/etc/systemd/system/multi-user.target.wants/nvidia-persistenced.service"
check nvidia "$R"
expect_rc "nvidia-persistenced enabled: fails" 1
expect_out "and says why" '^FAIL nvidia: nvidia-persistenced is enabled .*it keeps the dGPU awake$'

pair_root degraded degraded
check nvidia "$R"
expect_rc "degraded=nvidia: passes" 0
expect_out "with no NVIDIA set" '^PASS nvidia: no kmod-nvidia and no NVIDIA userspace$'
expect_out "with the label" '^PASS nvidia: manifest\.json lists degraded=nvidia$'
expect_out "and a warning" '^WARN nvidia: degraded=nvidia: the dGPU stays unbound in D3cold'

pair_root degraded-label degraded
printf '{"degraded": [], "held": []}\n' >"$R/usr/share/apex/manifest.json"
check nvidia "$R"
expect_rc "degraded=nvidia without the label: fails" 1

pair_root degraded-kmod degraded
rpmdb_add "$R" nvidia-kmod-common '{"evr": "3:615.78.08-1.fc45"}'
check nvidia "$R"
expect_rc "degraded=nvidia with NVIDIA userspace: fails" 1


pair_root pair-cmdline pair
mkdir -p "$R/etc/kernel"
printf 'root=x\n' >"$R/etc/kernel/cmdline"
check nvidia "$R"
expect_rc "/etc/kernel/cmdline written by a scriptlet: fails" 1
expect_out "and names it" '^FAIL nvidia: /etc/kernel/cmdline exists'

pair_root degraded-grub degraded
mkdir -p "$R/etc/default"
: >"$R/etc/default/grub"
check nvidia "$R"
expect_rc "/etc/default/grub in a degraded=nvidia image: fails" 1

pair_root pair-boot pair
mkdir -p "$R/boot/loader"
check nvidia "$R"
expect_rc "a non-empty /boot: fails" 1
expect_out "and lists it" '^FAIL nvidia: /boot is not empty: loader$'

pair_root pair-gsp pair
mkdir -p "$R/usr/lib/firmware/nvidia/615.71.09"
check nvidia "$R"
expect_rc "GSP firmware of two versions: fails" 1
expect_out "and names them" '^FAIL nvidia: the GSP firmware under /usr/lib/firmware/nvidia is 615\.71\.09 615\.78\.08, not'

pair_root pair-licence pair
rm -r "$R/usr/share/licenses"
check nvidia "$R"
expect_rc "no NVIDIA licence: fails" 1

pair_root pair-etc-options pair
mkdir -p "$R/etc/modprobe.d"
printf 'options nvidia NVreg_DynamicPowerManagement=0x00\n' >"$R/etc/modprobe.d/zz-local.conf"
check nvidia "$R"
expect_rc "a later file turning RTD3 off: fails" 1
expect_out "and shows the value in effect" "^FAIL nvidia: options nvidia: NVreg_DynamicPowerManagement is '0x00' in effect, not 0x02\$"

pair_root pair-etc-override pair
mkdir -p "$R/etc/modprobe.d"
printf 'options nvidia NVreg_EnableS0ixPowerManagement=0\n' >"$R/etc/modprobe.d/nvidia.conf"
check nvidia "$R"
expect_rc "/etc/modprobe.d/nvidia.conf replacing negativo17's: fails" 1
expect_out "and its options are the ones in effect" "^FAIL nvidia: options nvidia: NVreg_PreserveVideoMemoryAllocations is 'unset' in effect"

done_testing
