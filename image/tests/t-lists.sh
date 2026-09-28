#!/bin/sh
# Package lists, presets, kernel arguments and ignore files: the static facts the
# review findings depend on.
. "$(dirname -- "$0")/lib.sh"

P=$IMAGE_DIR/packages
list() { sed -e 's/#.*//' -e 's/[[:space:]]//g' -e '/^$/d' "$@"; }

list "$P/base.txt" "$P/gnome.txt" "$P/apex.txt" | sort >"$T/install"
list "$P/exclude.txt" | sort >"$T/exclude"

# Every entry is one package-name token, and nothing is listed twice.
for f in base gnome apex exclude; do
    if list "$P/$f.txt" | grep -Evq '^[A-Za-z0-9][A-Za-z0-9._+-]*$'; then
        not_ok "$f.txt: every entry is a package name"
    else
        ok "$f.txt: every entry is a package name"
    fi
done
if [ -z "$(uniq -d "$T/install")" ]; then ok "no package is installed from two lists"; else not_ok "duplicates: $(uniq -d "$T/install" | paste -sd ' ' -)"; fi
if [ -z "$(comm -12 "$T/install" "$T/exclude")" ]; then ok "no package is both installed and excluded"; else not_ok "installed and excluded: $(comm -12 "$T/install" "$T/exclude" | paste -sd ' ' -)"; fi

# Review findings: time sync, tar, the oomd policy, GTK2.
for p in chrony tar iputils systemd-oomd-defaults; do
    if grep -Fxq "$p" "$T/install"; then ok "installed: $p"; else not_ok "installed: $p"; fi
done
if grep -Fxq gtk2 "$T/exclude"; then ok "excluded: gtk2"; else not_ok "excluded: gtk2"; fi
# F45 has no passwd package: shadow-utils ships /usr/bin/passwd (image/checks/system.sh).
if grep -Fxq passwd "$T/install"; then not_ok "no nonexistent passwd package"; else ok "no nonexistent passwd package"; fi

# The allowlist is pinned: every entry name-version-release, one per package name.
list "$P/updates-testing-allowlist.txt" >"$T/allow"
if grep -Evq '^[A-Za-z0-9._+]+(-[A-Za-z0-9._+]+)*-[0-9][A-Za-z0-9._+~^]*-[0-9][A-Za-z0-9._+~^]*\.fc[0-9]+[A-Za-z0-9._+~^]*$' "$T/allow"; then
    not_ok "updates-testing allowlist: every entry is name-version-release"
else
    ok "updates-testing allowlist: every entry is name-version-release"
fi
sed 's/-[^-]*-[^-]*$//' "$T/allow" | sort | uniq -d >"$T/dupnames"
if [ -s "$T/dupnames" ]; then not_ok "allowlist: one build per package"; else ok "allowlist: one build per package"; fi

# 80-apex.preset's enable lines and the Containerfile's explicit list are the same set,
# except gdm (enabled by Fedora's preset and explicitly, not by Apex's).
PRESET=$IMAGE_DIR/system_files/usr/lib/systemd/system-preset/80-apex.preset
sed -n 's/^enable[[:space:]]\{1,\}//p' "$PRESET" | sort >"$T/preset-enable"
sed -n 's/^[[:space:]]*units="\([^"]*\)".*/\1/p' "$IMAGE_DIR/Containerfile" | tr ' ' '\n' |
    grep -v '^gdm\.service$' | sed '/^$/d' | sort >"$T/explicit"
if cmp -s "$T/preset-enable" "$T/explicit"; then
    ok "80-apex.preset enables exactly the Containerfile's explicit units"
else
    not_ok "80-apex.preset and the Containerfile's units differ: $(comm -3 "$T/preset-enable" "$T/explicit" | paste -sd ' ' -)"
fi
for u in chronyd.service apex-flatpak-preinstall.timer; do
    if grep -Fxq "$u" "$T/preset-enable"; then ok "preset enables $u"; else not_ok "preset enables $u"; fi
done
expect_file "preset keeps systemd-timesyncd off" '^disable systemd-timesyncd\.service$' "$PRESET"

# Kernel arguments: the boot splash (review finding) next to the boot-counting ones.
if command -v python3 >/dev/null 2>&1; then
    run python3 -c 'import sys, tomllib; print("\n".join(tomllib.load(open(sys.argv[1], "rb"))["kargs"]))' \
        "$IMAGE_DIR/system_files/usr/lib/bootc/kargs.d/10-apex.toml"
    expect_rc "kargs.d parses as TOML" 0
    for k in rhgb quiet panic=10 systemd.ssh_auto=no; do
        expect_out "karg $k" "^$k\$"
    done
    # The dracut rescue shell stays available (ARCHITECTURE §5.3).
    for k in rd.shell=0 rd.emergency=reboot; do
        expect_no_out "no karg $k" "^$k\$"
    done
fi

# Private keys stay out of git and of the build context (review finding).
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
