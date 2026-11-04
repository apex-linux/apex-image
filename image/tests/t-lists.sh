#!/bin/sh
# Static facts of the package lists, presets, kernel arguments and ignore files.
. "$(dirname -- "$0")/lib.sh"

P=$IMAGE_DIR/packages
list() { sed -e 's/#.*//' -e 's/[[:space:]]//g' -e '/^$/d' "$@"; }

list "$P/base.txt" "$P/gnome.txt" "$P/apex.txt" | sort >"$T/install"
list "$P/exclude.txt" | sort >"$T/exclude"

for f in base gnome apex exclude; do
    if list "$P/$f.txt" | grep -Evq '^[A-Za-z0-9][A-Za-z0-9._+-]*$'; then
        not_ok "$f.txt: every entry is a package name"
    else
        ok "$f.txt: every entry is a package name"
    fi
done
if [ -z "$(uniq -d "$T/install")" ]; then ok "no package is installed from two lists"; else not_ok "duplicates: $(uniq -d "$T/install" | paste -sd ' ' -)"; fi
if [ -z "$(comm -12 "$T/install" "$T/exclude")" ]; then ok "no package is both installed and excluded"; else not_ok "installed and excluded: $(comm -12 "$T/install" "$T/exclude" | paste -sd ' ' -)"; fi

for p in chrony tar iputils systemd-oomd-defaults; do
    if grep -Fxq "$p" "$T/install"; then ok "installed: $p"; else not_ok "installed: $p"; fi
done
if grep -Fxq gtk2 "$T/exclude"; then ok "excluded: gtk2"; else not_ok "excluded: gtk2"; fi
# legacy.sh's BANNED is ARCHITECTURE's never-shipped row: the compose excludes each one too.
sed -n "s/^BANNED='\(.*\)'$/\1/p" "$IMAGE_DIR/checks/legacy.sh" | tr ' ' '\n' | sed '/^$/d' | sort >"$T/banned"
if [ -s "$T/banned" ] && [ -z "$(comm -23 "$T/banned" "$T/exclude")" ]; then
    ok "exclude.txt excludes every package legacy.sh bans"
else
    not_ok "banned by legacy.sh but not in exclude.txt: $(comm -23 "$T/banned" "$T/exclude" | paste -sd ' ' -)"
fi
for p in gnome-tour cheese; do
    if grep -Fxq "$p" "$T/banned"; then ok "legacy.sh bans $p"; else not_ok "legacy.sh bans $p"; fi
done
PRE=$IMAGE_DIR/system_files/usr/share/flatpak/preinstall.d/apex.preinstall
if grep -q '^\[Flatpak Preinstall org\.mozilla\.firefox\]' "$PRE"; then
    not_ok "Firefox is installed on request, not preinstalled"
else
    ok "Firefox is installed on request, not preinstalled"
fi
if grep -Fxq epiphany "$T/install"; then ok "Epiphany is the image's browser"; else not_ok "Epiphany is the image's browser"; fi
if list "$P/apex.txt" | grep -Fxq apex-desktop; then ok "apex.txt: apex-desktop"; else not_ok "apex.txt: apex-desktop"; fi
if list "$P/apex.txt" | grep -Eq '^(gnome-shell|gnome-shell-common|mutter|mutter-common)$'; then
    not_ok "apex.txt names no lane package"
else
    ok "apex.txt names no lane package"
fi
# The rebuilt shell draws GNOME's 'default' colour scheme light.
OVERRIDE=$APEX_DESKTOP_SRC/desktop/schemas/90_apex.gschema.override
if grep -Eq '^[[:space:]]*color-scheme[[:space:]]*=' "$OVERRIDE"; then
    not_ok "the vendor override sets no color-scheme"
else
    ok "the vendor override sets no color-scheme"
fi
# F45 has no passwd package: shadow-utils ships /usr/bin/passwd.
if grep -Fxq passwd "$T/install"; then not_ok "no nonexistent passwd package"; else ok "no nonexistent passwd package"; fi

for f in "$P"/*; do printf '%s\n' "${f##*/}"; done | LC_ALL=C sort >"$T/lists"
printf '%s\n' apex.txt base.txt exclude.txt gnome.txt >"$T/lists.want"
if cmp -s "$T/lists.want" "$T/lists"; then
    ok "image/packages holds exactly the four lists the compose reads"
else
    not_ok "image/packages holds exactly the four lists the compose reads: $(comm -3 "$T/lists.want" "$T/lists" | paste -sd ' ' -)"
fi
grep -o '/run/apex-packages/[A-Za-z0-9._-]*\.txt' "$IMAGE_DIR/Containerfile" | sed 's|.*/||' | LC_ALL=C sort -u >"$T/read"
if cmp -s "$T/lists.want" "$T/read"; then
    ok "the Containerfile reads exactly those four lists"
else
    not_ok "the Containerfile reads exactly those four lists: $(comm -3 "$T/lists.want" "$T/read" | paste -sd ' ' -)"
fi

# gdm is enabled by Fedora's preset and by the Containerfile, not by 80-apex.preset.
PRESET=$IMAGE_DIR/system_files/usr/lib/systemd/system-preset/80-apex.preset
sed -n 's/^enable[[:space:]]\{1,\}//p' "$PRESET" | sort >"$T/preset-enable"
sed -n 's/^[[:space:]]*units="\([^"]*\)".*/\1/p' "$IMAGE_DIR/Containerfile" | tr ' ' '\n' |
    grep -v '^gdm\.service$' | sed '/^$/d' | sort >"$T/explicit"
if cmp -s "$T/preset-enable" "$T/explicit"; then
    ok "80-apex.preset enables exactly the Containerfile's explicit units"
else
    not_ok "80-apex.preset and the Containerfile's units differ: $(comm -3 "$T/preset-enable" "$T/explicit" | paste -sd ' ' -)"
fi
for u in chronyd.service apex-flatpak-preinstall.timer bootloader-update.service; do
    if grep -Fxq "$u" "$T/preset-enable"; then ok "preset enables $u"; else not_ok "preset enables $u"; fi
done
expect_file "preset keeps systemd-timesyncd off" '^disable systemd-timesyncd\.service$' "$PRESET"

if command -v python3 >/dev/null 2>&1; then
    run python3 -c 'import sys, tomllib; print("\n".join(tomllib.load(open(sys.argv[1], "rb"))["kargs"]))' \
        "$IMAGE_DIR/system_files/usr/lib/bootc/kargs.d/10-apex.toml"
    expect_rc "kargs.d parses as TOML" 0
    for k in rhgb quiet panic=10 systemd.ssh_auto=no; do
        expect_out "karg $k" "^$k\$"
    done
    # The dracut rescue shell stays available.
    for k in rd.shell=0 rd.emergency=reboot; do
        expect_no_out "no karg $k" "^$k\$"
    done
fi

if command -v git >/dev/null 2>&1 && git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    for f in cosign.key image/system_files/usr/share/apex/keys/cosign.key image/x/release.key; do
        if git -C "$REPO_ROOT" check-ignore -q --no-index "$f"; then ok "git ignores $f"; else not_ok "git ignores $f"; fi
    done
    if git -C "$REPO_ROOT" check-ignore -q --no-index image/system_files/usr/share/apex/keys/release.pub; then
        not_ok "git does not ignore the public keys"
    else
        ok "git does not ignore the public keys"
    fi
fi
expect_file ".containerignore excludes private keys everywhere" '^\*\*/\*\.key$' "$REPO_ROOT/.containerignore"
expect_file ".containerignore excludes cosign.key everywhere" '^\*\*/cosign\.key$' "$REPO_ROOT/.containerignore"

done_testing
