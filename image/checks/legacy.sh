#!/bin/sh
# Legacy gate (ADR 0007, ARCHITECTURE 7.1).
#
# Flags every installed package that
#   - requires GTK3 or GTK2 (toolkit consumers; GTK2 has no Wayland backend), or
#   - provides GTK3, GTK2 or the Xorg server itself (the toolkit or server packages), or
#   - requires the Xorg server (anything that needs an X server other than Xwayland), or
#   - belongs to the X11 session userland (xinit and the tools it drives), or
#   - is banned by name (legacy apps and services Apex never ships),
# and compares that set with image/audit/legacy-allowlist.txt (name<TAB>milestone<TAB>
# reason). Anything flagged but not allowlisted fails the build. Resolution is rpm's
# own (`rpm -q --whatrequires`, `--whatprovides`, `rpm -qa --requires`), not a
# home-grown parser.
#
# rpm headers keep requirements a package satisfies itself (gtk3's own binaries link
# libgtk-3, so gtk3 "requires" libgtk-3.so.0()(64bit)); createrepo drops those from
# the repodata, so they do not show up in a depsolve. Such a self-requirement is not
# counted as a consumer: the package is flagged as the provider instead.
#
# Environment: ROOT, APEX_IMAGE_DIR (see lib/common.sh); LEGACY_ALLOWLIST overrides
# the allowlist path.
set -eu
CHECK_NAME=legacy
APEX_CHECKS_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$APEX_CHECKS_DIR/lib/common.sh"

ALLOWLIST=${LEGACY_ALLOWLIST:-$APEX_IMAGE_DIR/audit/legacy-allowlist.txt}

# Capabilities whose consumers are GTK3 code.
GTK3_CAPS='libgtk-3.so.0()(64bit) libgdk-3.so.0()(64bit) gtk3 gtk3(x86-64)'
# GTK2 (X11 only). Nothing is allowlisted for it, and image/packages/exclude.txt
# excludes gtk2.
GTK2_CAPS='libgtk-x11-2.0.so.0()(64bit) libgdk-x11-2.0.so.0()(64bit) gtk2 gtk2(x86-64)'
# Capabilities of the Xorg server; Xwayland provides none of these.
XORG_CAPS='Xorg xorg-x11-server-Xorg xorg-x11-server-Xorg(x86-64) xorg-x11-server-common /usr/bin/Xorg /usr/libexec/Xorg'
# The X11 session userland: gdm on F45 still hard-requires xorg-x11-xinit, which
# requires the rest. Flagged so the allowlist records why each one is present.
X11_USERLAND='xorg-x11-xinit xorg-x11-xauth xhost xmodmap xrdb setxkbmap'
# Never shipped (ARCHITECTURE 7.1 "Never shipped", ADR 0009 for greenboot).
BANNED='gnome-terminal gedit eog evince totem cheese rhythmbox seahorse gnome-keyring gnome-classic-session xorg-x11-server-Xorg PackageKit gnome-software greenboot'

make_tmpdir
flagged=$TMPD/flagged      # name<TAB>why, possibly repeated
allowed=$TMPD/allowed      # allowlisted names

command -v rpm >/dev/null 2>&1 || { fail "rpm not found"; finish; }
if ! rpmq -q rpm >/dev/null 2>&1; then
    fail "cannot read the rpm database under ROOT=$ROOT"
    finish
fi

# self_provides NAME CAP: true when the installed package NAME provides CAP itself
# (for a path: owns that file).
self_provides() {
    case $2 in
        /*) rpmq -qf --qf '%{NAME}\n' "$2" 2>/dev/null | grep -Fxq -- "$1" ;;
        *)
            rpmq -q --provides "$1" 2>/dev/null |
                awk -v c="$2" '$1 == c { found = 1 } END { exit !found }'
            ;;
    esac
}

# --- Collect flagged packages ----------------------------------------------------
: >"$flagged"
for cap in $GTK3_CAPS $GTK2_CAPS $XORG_CAPS; do
    # `rpm -q --whatrequires/--whatprovides` exit 1 and print "no package requires
    # ..." when nothing matches; keep only real package names (they have no spaces).
    rpmq -q --whatrequires "$cap" --qf '%{NAME}\n' 2>/dev/null |
        grep -v '[[:space:]]' | sort -u >"$TMPD/requirers" || true
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        self_provides "$name" "$cap" && continue
        printf '%s\trequires %s\n' "$name" "$cap" >>"$flagged"
    done <"$TMPD/requirers"
    rpmq -q --whatprovides "$cap" --qf '%{NAME}\n' 2>/dev/null |
        grep -v '[[:space:]]' | sort -u |
        sed "s|\$|	provides $cap|" >>"$flagged" || true
done
# Versioned X server ABI requirements (xserver-abi(videodrv-NN) and friends) of
# X drivers: match by prefix over every installed requirement. %{=NAME} repeats the
# scalar NAME for each element of the REQUIRENAME array; without '=' rpm refuses the
# format for every package with more or fewer than one requirement and prints nothing
# for it. Any rpm error here fails the gate rather than silently shrinking its input.
if rpmq -qa --qf '[%{=NAME}\t%{REQUIRENAME}\n]' >"$TMPD/requires" 2>"$TMPD/requires.err" &&
    [ ! -s "$TMPD/requires.err" ]; then
    awk -F '\t' '$2 ~ /^xserver-abi\(/ { print $1 "\trequires " $2 }' "$TMPD/requires" >>"$flagged"
else
    fail "rpm could not list installed requirements: $(head -n 3 "$TMPD/requires.err" | paste -sd ' ' -)"
fi
for name in $X11_USERLAND; do
    if rpmq -q "$name" >/dev/null 2>&1; then
        printf '%s\tX11 session userland\n' "$name" >>"$flagged"
    fi
done
for name in $BANNED; do
    if rpmq -q "$name" >/dev/null 2>&1; then
        printf '%s\tbanned by name\n' "$name" >>"$flagged"
    fi
done
# Every X driver package, whatever it requires.
rpmq -qa --qf '%{NAME}\n' | grep '^xorg-x11-drv-' | sed 's|$|	X driver|' >>"$flagged" || true

# --- Parse and validate the allowlist ------------------------------------------------
if [ ! -r "$ALLOWLIST" ]; then
    fail "allowlist not readable: $ALLOWLIST"
    finish
fi
: >"$allowed"
lineno=0
while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    case $line in '' | '#'*) continue ;; esac
    # Exactly three non-empty TAB-separated fields; milestone M<n>[.<n>] or F<n>.
    if ! printf '%s\n' "$line" | awk -F '\t' '
        NF != 3 || $1 == "" || $2 == "" || $3 == "" { exit 1 }
        $1 !~ /^[A-Za-z0-9][A-Za-z0-9._+-]*$/ { exit 1 }
        $2 !~ /^(M[0-9]+(\.[0-9]+)?|F[0-9]+)$/ { exit 1 }'; then
        fail "$ALLOWLIST:$lineno: expected name<TAB>milestone<TAB>reason (milestone M<n>, M<n>.<n> or F<n>)"
        continue
    fi
    name=$(printf '%s\n' "$line" | cut -f1)
    if grep -qx -- "$name" "$allowed"; then
        fail "$ALLOWLIST:$lineno: duplicate entry $name"
        continue
    fi
    printf '%s\n' "$name" >>"$allowed"
done <"$ALLOWLIST"

# --- Set difference ----------------------------------------------------------------
flagged_names=$TMPD/flagged-names
cut -f1 "$flagged" | sort -u >"$flagged_names"
count=$(wc -l <"$flagged_names" | tr -d ' ')
pass "$count flagged package(s) found"

while IFS= read -r name; do
    [ -n "$name" ] || continue
    why=$(awk -F '\t' -v n="$name" '$1 == n { print $2 }' "$flagged" | sort -u | paste -sd ';' -)
    if grep -qx -- "$name" "$allowed"; then
        milestone=$(awk -F '\t' -v n="$name" '$1 == n { print $2; exit }' "$ALLOWLIST")
        pass "allowlisted until $milestone: $name ($why)"
    else
        fail "not allowlisted: $name ($why)"
    fi
done <"$flagged_names"

# Entries that no longer apply: the list only shrinks, so point them out.
while IFS= read -r name; do
    if ! grep -qx -- "$name" "$flagged_names"; then
        if rpmq -q "$name" >/dev/null 2>&1; then
            warn "stale allowlist entry (installed but no longer flagged): $name"
        else
            warn "stale allowlist entry (not installed): $name"
        fi
    fi
done <"$allowed"

finish
