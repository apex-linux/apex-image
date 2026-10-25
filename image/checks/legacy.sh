#!/bin/sh
set -eu
CHECK_NAME=legacy
APEX_CHECKS_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$APEX_CHECKS_DIR/lib/common.sh"

ALLOWLIST=${LEGACY_ALLOWLIST:-$APEX_IMAGE_DIR/audit/legacy-allowlist.txt}

GTK3_CAPS='libgtk-3.so.0()(64bit) libgdk-3.so.0()(64bit) gtk3 gtk3(x86-64)'
GTK2_CAPS='libgtk-x11-2.0.so.0()(64bit) libgdk-x11-2.0.so.0()(64bit) gtk2 gtk2(x86-64)'
# Xwayland provides none of these.
XORG_CAPS='Xorg xorg-x11-server-Xorg xorg-x11-server-Xorg(x86-64) xorg-x11-server-common /usr/bin/Xorg /usr/libexec/Xorg'
# gdm hard-requires xorg-x11-xinit, which requires the rest: flagged so each keeps its allowlist reason.
X11_USERLAND='xorg-x11-xinit xorg-x11-xauth xhost xmodmap xrdb setxkbmap'
BANNED='gnome-terminal gedit eog evince totem cheese rhythmbox seahorse gnome-keyring gnome-classic-session gnome-tour xorg-x11-server-Xorg PackageKit gnome-software greenboot'

make_tmpdir
flagged=$TMPD/flagged
allowlisted=$TMPD/allowlisted

command -v rpm >/dev/null 2>&1 || { fail "rpm not found"; finish; }
if ! root_rpm -q rpm >/dev/null 2>&1; then
    fail "cannot read the rpm database under ROOT=$ROOT"
    finish
fi

# rpm keeps requirements a package satisfies itself (gtk3 "requires" libgtk-3): flag it only as provider.
self_provides() {
    case $2 in
        /*) root_rpm -qf --qf '%{NAME}\n' "$2" 2>/dev/null | grep -Fxq -- "$1" ;;
        *)
            root_rpm -q --provides "$1" 2>/dev/null |
                awk -v c="$2" '$1 == c { found = 1 } END { exit !found }'
            ;;
    esac
}

: >"$flagged"
for cap in $GTK3_CAPS $GTK2_CAPS $XORG_CAPS; do
    # With no match, rpm prints "no package requires ..." on stdout; names have no spaces.
    root_rpm -q --whatrequires "$cap" --qf '%{NAME}\n' 2>/dev/null |
        grep -v '[[:space:]]' | sort -u >"$TMPD/requirers" || true
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        self_provides "$name" "$cap" && continue
        printf '%s\trequires %s\n' "$name" "$cap" >>"$flagged"
    done <"$TMPD/requirers"
    root_rpm -q --whatprovides "$cap" --qf '%{NAME}\n' 2>/dev/null |
        grep -v '[[:space:]]' | sort -u |
        sed "s|\$|	provides $cap|" >>"$flagged" || true
done
# %{=NAME}: a bare %{NAME} next to the REQUIRENAME array makes rpm print nothing for
# every package without exactly one requirement, so any rpm error fails the gate.
if root_rpm -qa --qf '[%{=NAME}\t%{REQUIRENAME}\n]' >"$TMPD/requires" 2>"$TMPD/requires.err" &&
    [ ! -s "$TMPD/requires.err" ]; then
    awk -F '\t' '$2 ~ /^xserver-abi\(/ { print $1 "\trequires " $2 }' "$TMPD/requires" >>"$flagged"
else
    fail "rpm could not list installed requirements: $(head -n 3 "$TMPD/requires.err" | paste -sd ' ' -)"
fi
for name in $X11_USERLAND; do
    if root_rpm -q "$name" >/dev/null 2>&1; then
        printf '%s\tX11 session userland\n' "$name" >>"$flagged"
    fi
done
for name in $BANNED; do
    if root_rpm -q "$name" >/dev/null 2>&1; then
        printf '%s\tbanned by name\n' "$name" >>"$flagged"
    fi
done
root_rpm -qa --qf '%{NAME}\n' | grep '^xorg-x11-drv-' | sed 's|$|	X driver|' >>"$flagged" || true

if [ ! -r "$ALLOWLIST" ]; then
    fail "allowlist not readable: $ALLOWLIST"
    finish
fi
: >"$allowlisted"
lineno=0
while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    case $line in '' | '#'*) continue ;; esac
    if ! printf '%s\n' "$line" | awk -F '\t' '
        NF != 3 || $1 == "" || $2 == "" || $3 == "" { exit 1 }
        $1 !~ /^[A-Za-z0-9][A-Za-z0-9._+-]*$/ { exit 1 }
        $2 !~ /^(M[0-9]+(\.[0-9]+)?|F[0-9]+)$/ { exit 1 }'; then
        fail "$ALLOWLIST:$lineno: expected name<TAB>milestone<TAB>reason (milestone M<n>, M<n>.<n> or F<n>)"
        continue
    fi
    name=$(printf '%s\n' "$line" | cut -f1)
    if grep -qx -- "$name" "$allowlisted"; then
        fail "$ALLOWLIST:$lineno: duplicate entry $name"
        continue
    fi
    printf '%s\n' "$name" >>"$allowlisted"
done <"$ALLOWLIST"

flagged_names=$TMPD/flagged-names
cut -f1 "$flagged" | sort -u >"$flagged_names"
count=$(wc -l <"$flagged_names" | tr -d ' ')
pass "$count flagged package(s) found"

while IFS= read -r name; do
    [ -n "$name" ] || continue
    why=$(awk -F '\t' -v n="$name" '$1 == n { print $2 }' "$flagged" | sort -u | paste -sd ';' -)
    if grep -qx -- "$name" "$allowlisted"; then
        milestone=$(awk -F '\t' -v n="$name" '$1 == n { print $2; exit }' "$ALLOWLIST")
        pass "allowlisted until $milestone: $name ($why)"
    else
        fail "not allowlisted: $name ($why)"
    fi
done <"$flagged_names"

while IFS= read -r name; do
    if ! grep -qx -- "$name" "$flagged_names"; then
        if root_rpm -q "$name" >/dev/null 2>&1; then
            warn "stale allowlist entry (installed but no longer flagged): $name"
        else
            warn "stale allowlist entry (not installed): $name"
        fi
    fi
done <"$allowlisted"

finish
