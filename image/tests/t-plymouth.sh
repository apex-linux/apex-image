#!/bin/sh
# image/checks/plymouth.sh: the apex theme at DeviceScale=1, in the image and the initramfs.
. "$(dirname -- "$0")/lib.sh"

KVER=7.2.7-300.fc45.x86_64
BIN=$T/bin
mkdir -p "$BIN"
cat >"$BIN/lsinitrd" <<'FAKE'
#!/bin/sh
initramfs_dir=$(cat "$1")
if [ "$#" -eq 1 ]; then
    cd "$initramfs_dir" && find . -type f | sed 's|^\./||'
    exit
fi
[ "$2" = -f ] || exit 2
cat "$initramfs_dir/$3" 2>/dev/null
FAKE
chmod 0755 "$BIN/lsinitrd"

CONF='[Daemon]
Theme=apex
DeviceScale=1
# Administrator customizations go in this file
#[Daemon]
#Theme=fade-in'

# keyfiles DIR [FONT]: the two themes as apex-desktop installs them.
keyfiles() {
    mkdir -p "$1/apex" "$1/apex-twostep"
    printf '[Plymouth Theme]\nName=Apex\nModuleName=script\n\n[script]\nImageDir=/usr/share/plymouth/themes/apex\nScriptFile=/usr/share/plymouth/themes/apex/apex.script\nMonospaceFont=%s\n' \
        "${2:-monospace 20}" >"$1/apex/apex.plymouth"
    printf 'Window.SetBackgroundTopColor(0, 0, 0);\n' >"$1/apex/apex.script"
    printf '[Plymouth Theme]\nName=Apex two-step\nModuleName=two-step\n\n[two-step]\nMonospaceFont=monospace 20\n\n[boot-up]\nUseProgressBar=true\n' \
        >"$1/apex-twostep/apex-twostep.plymouth"
}

# mkroot NAME: an image root and its initramfs, both as the image build leaves them.
mkroot() {
    r=$T/$1
    mkdir -p "$r/etc/plymouth" "$r/usr/lib/modules/$KVER" "$r/initramfs/etc/plymouth"
    printf '%s\n' "$CONF" >"$r/etc/plymouth/plymouthd.conf"
    printf '%s\n' "$CONF" >"$r/initramfs/etc/plymouth/plymouthd.conf"
    keyfiles "$r/usr/share/plymouth/themes"
    keyfiles "$r/initramfs/usr/share/plymouth/themes"
    mkdir -p "$r/initramfs/usr/lib64/plymouth" "$r/initramfs/usr/share/fonts/google-noto-vf"
    : >"$r/initramfs/usr/lib64/plymouth/label-freetype.so"
    : >"$r/initramfs/usr/share/fonts/google-noto-vf/NotoSansMono[wght].ttf"
    printf '%s\n' "$r/initramfs" >"$r/usr/lib/modules/$KVER/initramfs.img"
    printf '%s\n' "$r"
}

check() {
    run env ROOT="$1" PATH="$BIN:$PATH" "$SH" "$CHECKS/plymouth.sh"
}

check "$(mkroot good)"
expect_rc "the apex theme at DeviceScale=1 in the image and the initramfs passes" 0
expect_out "the theme" '^PASS plymouth: /etc/plymouth/plymouthd.conf: \[Daemon\] Theme=apex$'
expect_out "the scale" '^PASS plymouth: /etc/plymouth/plymouthd.conf: \[Daemon\] DeviceScale=1, so'
expect_out "the initramfs's copy" '^PASS plymouth: the initramfs.s /etc/plymouth/plymouthd.conf: \[Daemon\] DeviceScale=1'
expect_out "the fallback's plugin" '^PASS plymouth: /usr/share/plymouth/themes/apex-twostep uses the two-step plugin$'
expect_out "the Esc text" '^PASS plymouth: apex: MonospaceFont=monospace 20 keeps the Esc text view legible'
expect_out "the theme in the initramfs" '^PASS plymouth: the initramfs carries /usr/share/plymouth/themes/apex/apex.script$'
expect_out "the Esc text view's plugin and font" '^PASS plymouth: the initramfs carries label-freetype and a font'

r=$(mkroot scale2)
sed -i 's/^DeviceScale=1$/DeviceScale=2/' "$r/etc/plymouth/plymouthd.conf"
check "$r"
expect_rc "DeviceScale=2 fails" 1
expect_out "and says why" "DeviceScale is '2', not 1: the script theme would draw upscaled, soft images"

r=$(mkroot noscale)
sed -i '/^DeviceScale=/d' "$r/etc/plymouth/plymouthd.conf" "$r/initramfs/etc/plymouth/plymouthd.conf"
check "$r"
expect_rc "no DeviceScale, so Plymouth's own HiDPI guess, fails" 1

r=$(mkroot commented)
printf '[Daemon]\n#Theme=bgrt\n' >"$r/etc/plymouth/plymouthd.conf"
check "$r"
expect_rc "a commented-out section does not count" 1
expect_out "and names the theme unset" "Theme is 'unset', not apex"

r=$(mkroot othersection)
printf '[Daemon]\nTheme=apex\n[Other]\nDeviceScale=1\n' >"$r/etc/plymouth/plymouthd.conf"
check "$r"
expect_rc "DeviceScale= in another section does not count" 1

r=$(mkroot staleinitrd)
printf '[Daemon]\nTheme=bgrt\n' >"$r/initramfs/etc/plymouth/plymouthd.conf"
check "$r"
expect_rc "an initramfs built before the theme was set fails" 1
expect_out "naming the initramfs" "^FAIL plymouth: the initramfs.s /etc/plymouth/plymouthd.conf: \\[Daemon\\] Theme is 'bgrt'"

r=$(mkroot notheme)
rm "$r/initramfs/usr/share/plymouth/themes/apex/apex.script"
check "$r"
expect_rc "an initramfs without the theme's script fails" 1

r=$(mkroot nolabel)
rm "$r/initramfs/usr/lib64/plymouth/label-freetype.so"
check "$r"
expect_rc "an initramfs without label-freetype fails" 1
expect_out "and says why" 'the Esc text view would have no text$'

r=$(mkroot nofont)
rm -r "${r:?}/initramfs/usr/share/fonts"
check "$r"
expect_rc "an initramfs without a font fails" 1

r=$(mkroot smallfont)
keyfiles "$r/usr/share/plymouth/themes" 'monospace 10'
check "$r"
expect_rc "Plymouth's 10 pt default fails at DeviceScale=1" 1
expect_out "and says why" "the Esc text view would be half size at DeviceScale=1"

r=$(mkroot nofallback)
rm -r "${r:?}/usr/share/plymouth/themes/apex-twostep"
check "$r"
expect_rc "an image without apex-twostep fails" 1

r=$(mkroot noconf)
rm "$r/etc/plymouth/plymouthd.conf"
check "$r"
expect_rc "an image without plymouthd.conf fails" 1

done_testing
