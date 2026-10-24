#!/bin/sh
# The rebuilt shell as the rebuild lane locked it, its theme, schema, vendor defaults and
# crash guard, and no dev-loop or fault-injection setting in the image.
set -eu
CHECK_NAME=desktop
APEX_CHECKS_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$APEX_CHECKS_DIR/lib/common.sh"

LOCK=${APEX_RPMS_LOCK:-$(rootpath /usr/share/apex/rpms.lock)}
THEME=/usr/share/gnome-shell/gnome-shell-theme.gresource
SCHEMAS=/usr/share/glib-2.0/schemas
SCHEMA=$SCHEMAS/io.github.apex_linux.Apex.Desktop.gschema.xml
OVERRIDE=$SCHEMAS/90_apex.gschema.override
DCONF_PROFILE=/etc/dconf/profile/user
DCONF_DB=/etc/dconf/db/distro
DCONF_KEYFILES=/etc/dconf/db/distro.d
USERUNITS=/usr/lib/systemd/user
MARKERS='/*! apex-shell-theme light */
/*! apex-shell-theme dark */
/*! apex-shell-structure */'
DEV_ONLY_SETTINGS='G_RESOURCE_OVERLAYS
--unsafe-mode
APEX_SHELL_TEST_FAULT'

make_tmpdir

# Prints nothing when NAME is not installed: rpm -q would print its message on stdout.
query() {
    if root_rpm -q "$1" >/dev/null 2>&1; then
        root_rpm -q --qf "$2" "$1"
    fi
}

evr_of() {
    query "$1" '%{EPOCHNUM}:%{VERSION}-%{RELEASE}\n' | head -n 1
}

state=''
if [ ! -f "$LOCK" ]; then
    fail "no $(unroot "$LOCK"): the image build installs the rebuild lane's lock there (image/Containerfile)"
else
    state=$(awk '$1 == "family" && $2 == "gnome-shell" { print $3; exit }' "$LOCK")
    [ -n "$state" ] || fail "$(unroot "$LOCK") has no gnome-shell family: the image took no decision about the shell"
    awk '$1 == "family" { st[$2] = $3 }
        $1 == "rpm" && (st[$2] == "built" || st[$2] == "held") { print $4, $5 }' "$LOCK" >"$TMPD/locked"
    bad=0
    while read -r name nevra; do
        have=$(query "$name" '%{NAME}-%{EPOCHNUM}:%{VERSION}-%{RELEASE}.%{ARCH}\n' | paste -sd ' ' -)
        if [ "$have" != "$nevra" ]; then
            fail "$name: installed ${have:-nothing}, but the lane locked $nevra"
            bad=1
        fi
    done <"$TMPD/locked"
    if [ "$bad" -eq 0 ]; then
        pass "the $(wc -l <"$TMPD/locked" | tr -d ' ') locked RPM(s) are installed at their locked NEVRAs"
    fi
fi

case $state in
    built | held)
        for p in gnome-shell gnome-shell-common; do
            vr=$(query "$p" '%{VERSION}-%{RELEASE}\n' | head -n 1)
            if printf '%s\n' "$vr" | grep -Eq '\.apex[0-9]+(\.[0-9]+)?$'; then
                pass "$p $vr is an Apex build (the family is $state)"
            else
                fail "$p ${vr:-(not installed)} is not an .apexN build, but the lane's gnome-shell family is $state"
            fi
            if signed_by "$APEX_RPM_KEYID" "$p"; then
                pass "$p carries the Apex RPM signature ($APEX_RPM_KEYID)"
            else
                fail "$p is not signed by the Apex RPM key ($APEX_RPM_KEYID)"
            fi
        done
        pin=$(root_rpm -q --requires gnome-shell 2>/dev/null | sed -n 's/^mutter(x86-64) = \([^ ]*\)$/\1/p' | head -n 1)
        mutter=$(evr_of mutter)
        case $pin in
            '') fail "gnome-shell has no Requires: mutter(x86-64) = EVR (packaging/pkgs/gnome-shell/spec-edit)" ;;
            *:*) ;;
            *) pin=0:$pin ;;
        esac
        if [ -n "$pin" ]; then
            if [ "$pin" = "$mutter" ]; then
                pass "gnome-shell requires mutter = $pin, the installed mutter"
            else
                fail "gnome-shell requires mutter = $pin, but mutter ${mutter:-is not installed}"
            fi
        fi
        # The resource stores its CSS uncompressed, so the markers are plain bytes.
        printf '%s\n' "$MARKERS" >"$TMPD/markers"
        if [ ! -f "$(rootpath "$THEME")" ]; then
            fail "no $THEME"
        else
            while IFS= read -r m; do
                if grep -aFq -- "$m" "$(rootpath "$THEME")"; then
                    pass "$THEME carries $m"
                else
                    fail "$THEME lacks $m: the Apex SCSS did not reach the compiled sheets"
                fi
            done <"$TMPD/markers"
        fi
        skip "upstream's sheets under /org/gnome/shell/theme/stock/: in libshell's resource; the lane (check.sh) and G2 check them"
        ;;
    stock | degraded)
        for p in gnome-shell gnome-shell-common; do
            vr=$(query "$p" '%{VERSION}-%{RELEASE}\n' | head -n 1)
            if [ -z "$vr" ]; then
                fail "$p is not installed"
            elif printf '%s\n' "$vr" | grep -Eq '\.apex[0-9]+'; then
                fail "$p $vr is an Apex build, but the lane's gnome-shell family is $state"
            elif signed_by "$FEDORA_KEYID" "$p"; then
                pass "$p $vr is Fedora's build, signed by Fedora's key (the family is $state: degraded=shell)"
            else
                fail "$p is not signed by Fedora's key ($FEDORA_KEYID)"
            fi
        done
        if [ -f "$(rootpath "$THEME")" ] && grep -aFq -- 'apex-shell-' "$(rootpath "$THEME")"; then
            fail "$THEME carries an Apex marker, but the family is $state"
        else
            pass "no Apex marker in the theme: the stock shell"
        fi
        ;;
    '') ;;
    *)
        fail "the lane's gnome-shell family is in the unknown state '$state' (built, held, stock or degraded): nothing about the shell was checked"
        ;;
esac

for p in mutter mutter-common; do
    if ! root_rpm -q "$p" >/dev/null 2>&1; then
        fail "$p is not installed"
    elif signed_by "$FEDORA_KEYID" "$p"; then
        pass "$p $(evr_of "$p") carries Fedora's signature"
    else
        fail "$p is not signed by Fedora's key ($FEDORA_KEYID): mutter must be Fedora's binary (ADR 0014)"
    fi
done

# The Apex terminal series puts Ptyxis in the lane (ADR 0014); before it lands there is no family.
tstate=''
if [ -f "$LOCK" ]; then
    tstate=$(awk '$1 == "family" && $2 == "ptyxis" { print $3; exit }' "$LOCK")
fi
tvr=$(query ptyxis '%{VERSION}-%{RELEASE}\n' | head -n 1)
tapex=0
if printf '%s\n' "$tvr" | grep -Eq '\.apex[0-9]+'; then tapex=1; fi
if [ -z "$tvr" ]; then
    fail "ptyxis is not installed (image/packages/gnome.txt)"
else
    case $tstate in
        built | held)
            if [ "$tapex" -eq 0 ]; then
                fail "ptyxis $tvr is not an .apexN build, but the lane's ptyxis family is $tstate"
            elif signed_by "$APEX_RPM_KEYID" ptyxis; then
                pass "ptyxis $tvr is an Apex build with the Apex RPM signature (the family is $tstate)"
            else
                fail "ptyxis $tvr is not signed by the Apex RPM key ($APEX_RPM_KEYID)"
            fi
            ;;
        '' | stock | degraded)
            how="the family is $tstate: degraded=terminal"
            [ -n "$tstate" ] || how="the lane has no ptyxis family"
            if [ "$tapex" -eq 1 ]; then
                fail "ptyxis $tvr is an Apex build, but ${how%%:*}"
            elif signed_by "$FEDORA_KEYID" ptyxis; then
                pass "ptyxis $tvr is Fedora's build, signed by Fedora's key ($how)"
            else
                fail "ptyxis $tvr is not signed by Fedora's key ($FEDORA_KEYID)"
            fi
            ;;
        *)
            fail "the lane's ptyxis family is in the unknown state '$tstate' (built, held, stock or degraded)"
            ;;
    esac
fi

# The ostree checkout of the compose sets every mtime to 0.
rc=0
root_rpm -V --nomtime gnome-shell gnome-shell-common >"$TMPD/verify" 2>&1 || rc=$?
if [ "$rc" -eq 0 ] && [ ! -s "$TMPD/verify" ]; then
    pass "rpm -V gnome-shell gnome-shell-common is clean (mtimes aside)"
else
    fail "rpm -V gnome-shell gnome-shell-common (exit $rc): $(head -n 5 "$TMPD/verify" | paste -sd '|' -)"
fi

ext=$(rootpath /usr/share/gnome-shell/extensions)
shipped=''
for e in "$ext"/* "$ext"/.[!.]*; do
    if [ -e "$e" ] || [ -L "$e" ]; then shipped="$shipped ${e##*/}"; fi
done
if [ -n "$shipped" ]; then
    fail "shell extensions ship in /usr/share/gnome-shell/extensions:$shipped"
else
    pass "no shell extension in /usr/share/gnome-shell/extensions"
fi

# Binaries (-I) and documentation name these settings without setting them.
printf '%s\n' "$DEV_ONLY_SETTINGS" >"$TMPD/dev-only-settings"
rc=0
LC_ALL=C grep -rlIF -D skip -f "$TMPD/dev-only-settings" "$(rootpath /usr)" "$(rootpath /etc)" \
    >"$TMPD/named" 2>"$TMPD/grep.err" || rc=$?
docs=0
bad=0
case $rc in
    0 | 1) ;;
    *)
        # A file grep could not read was not searched: no pass line.
        fail "grep could not search every file under /usr and /etc (exit $rc): $(head -n 3 "$TMPD/grep.err" | paste -sd ' ' -)"
        bad=1
        ;;
esac
while IFS= read -r f; do
    [ -n "$f" ] || continue
    path=$(unroot "$f")
    case $path in
        /usr/share/doc/* | /usr/share/licenses/* | /usr/share/man/* | /usr/share/info/* | \
            /usr/share/help/* | /usr/share/gtk-doc/*)
            docs=$((docs + 1))
            ;;
        *)
            fail "$path names $(grep -oF -f "$TMPD/dev-only-settings" "$f" | sort -u | paste -sd ',' -)"
            bad=1
            ;;
    esac
done <"$TMPD/named"
if [ "$bad" -eq 0 ]; then
    pass "no text file under /usr or /etc names $(paste -sd ',' "$TMPD/dev-only-settings") ($docs documentation file(s) not counted)"
fi

if [ ! -f "$(rootpath "$SCHEMA")" ]; then
    fail "no $SCHEMA: the layer would run in safe mode (apex-desktop)"
else
    for k in layer-enabled disabled-features toggle-spotlight; do
        if grep -q "<key name=\"$k\"" "$(rootpath "$SCHEMA")"; then
            pass "the Apex schema has $k"
        else
            fail "the Apex schema has no key $k"
        fi
    done
    if ! command -v glib-compile-schemas >/dev/null 2>&1; then
        fail "glib-compile-schemas not found"
    else
        mkdir "$TMPD/schemas"
        cp "$(rootpath "$SCHEMA")" "$TMPD/schemas/"
        if glib-compile-schemas --strict --dry-run "$TMPD/schemas" >"$TMPD/out" 2>&1; then
            pass "the Apex schema compiles with --strict"
        else
            fail "the Apex schema fails --strict: $(head -n 3 "$TMPD/out" | paste -sd '|' -)"
        fi
    fi
fi

if [ ! -f "$(rootpath "$OVERRIDE")" ]; then
    fail "no $OVERRIDE: the vendor defaults are missing (apex-desktop)"
elif grep -Eq '^[[:space:]]*color-scheme[[:space:]]*=' "$(rootpath "$OVERRIDE")"; then
    fail "$OVERRIDE sets color-scheme: the rebuilt shell draws GNOME's 'default' light"
elif command -v glib-compile-schemas >/dev/null 2>&1; then
    mkdir "$TMPD/all"
    copy_schemas "$TMPD/all"
    if glib-compile-schemas --strict --dry-run "$TMPD/all" >/dev/null 2>&1; then
        cp "$(rootpath "$OVERRIDE")" "$TMPD/all/"
        if glib-compile-schemas --strict --dry-run "$TMPD/all" >"$TMPD/out" 2>&1; then
            pass "$OVERRIDE sets no color-scheme and compiles with --strict against the installed schemas"
        else
            fail "$OVERRIDE fails --strict: $(head -n 3 "$TMPD/out" | paste -sd '|' -)"
        fi
    else
        # image/Containerfile only warns here too: upstream schemas are not Apex's to fix.
        warn "the installed schemas fail --strict without the Apex override: $OVERRIDE was not validated"
    fi
fi

if [ ! -f "$(rootpath "$DCONF_PROFILE")" ]; then
    fail "no $DCONF_PROFILE: dconf reads no system database"
elif ! grep -qx 'system-db:distro' "$(rootpath "$DCONF_PROFILE")"; then
    fail "$DCONF_PROFILE does not list system-db:distro: the Apex Ptyxis profile is never read"
else
    pass "$DCONF_PROFILE lists system-db:distro"
fi
keyfiles=$(rootpath "$DCONF_KEYFILES")
if [ ! -f "$(rootpath "$DCONF_DB")" ]; then
    fail "no $DCONF_DB: the image build did not run dconf update"
elif [ -n "$(find "$keyfiles" -type f ! -path "$keyfiles/locks/*" -newer "$(rootpath "$DCONF_DB")" 2>/dev/null)" ]; then
    fail "$DCONF_DB is older than a file in $DCONF_KEYFILES: the image build did not run dconf update after it"
else
    pass "$DCONF_DB is compiled from every file in $DCONF_KEYFILES"
fi
locks=$(find "$keyfiles/locks" -type f 2>/dev/null | while IFS= read -r f; do unroot "$f"; done | paste -sd ' ' -)
if [ -n "$locks" ]; then
    fail "dconf locks ship in $DCONF_KEYFILES/locks (ADR 0011 refuses them): $locks"
else
    pass "no dconf lock in $DCONF_KEYFILES"
fi

# Only the Ptyxis profile, a relocatable schema no override reaches, belongs in dconf.
# A memory-backend set rejects an unknown key or a value of the wrong type.
find "$keyfiles" -maxdepth 1 -type f -exec awk '/^\[/ { path = substr($0, 2, length($0) - 2); next }
    /^[[:space:]]*(#|$)/ { next }
    { k = $0; sub(/[[:space:]]*=.*/, "", k); v = $0; sub(/^[^=]*=[[:space:]]*/, "", v)
      printf "%s\t%s\t%s\t%s\n", FILENAME, path, k, v }' {} + >"$TMPD/dconf-keys" 2>/dev/null || true
mkdir "$TMPD/compiled" "$TMPD/nodata"
copy_schemas "$TMPD/compiled" overrides
glib-compile-schemas "$TMPD/compiled" >/dev/null 2>&1 || true
gs() {
    env -i PATH="$PATH" GSETTINGS_SCHEMA_DIR="$TMPD/compiled" GSETTINGS_BACKEND=memory XDG_DATA_DIRS="$TMPD/nodata" \
        gsettings "$@" </dev/null
}
default_uuid=$(gs get org.gnome.Ptyxis default-profile-uuid 2>/dev/null | tr -d "'")
uuids=$(gs get org.gnome.Ptyxis profile-uuids 2>/dev/null || true)
bad=0
n=0
tab=$(printf '\t')
while IFS="$tab" read -r file path key value; do
    n=$((n + 1))
    where="$(unroot "$file") [$path] $key"
    case $path in
        org/gnome/Ptyxis/Profiles/*/*) uuid='' ;;
        org/gnome/Ptyxis/Profiles/?*) uuid=${path#org/gnome/Ptyxis/Profiles/} ;;
        *) uuid='' ;;
    esac
    if [ -z "$uuid" ]; then
        fail "$where: only the Ptyxis profile belongs in dconf; a fixed-path key goes in $OVERRIDE"
        bad=1
    elif [ "$uuid" != "$default_uuid" ] || ! printf '%s\n' "$uuids" | grep -qF "'$uuid'"; then
        fail "$where: profile $uuid is not Ptyxis's default-profile-uuid and in profile-uuids ($OVERRIDE)"
        bad=1
    elif ! gs set "org.gnome.Ptyxis.Profile:/$path/" "$key" "$value" >"$TMPD/out" 2>&1; then
        fail "$where=$value is not a valid org.gnome.Ptyxis.Profile setting: $(head -n 1 "$TMPD/out")"
        bad=1
    fi
done <"$TMPD/dconf-keys"
if [ "$n" -eq 0 ]; then
    fail "no key in $DCONF_KEYFILES: the Apex Ptyxis profile is missing (apex-desktop)"
elif [ "$bad" -eq 0 ]; then
    pass "the $n dconf default(s) in $DCONF_KEYFILES set Ptyxis's default profile $default_uuid, and each is a valid setting"
fi

dropin=$USERUNITS/org.gnome.Shell@.service.d/50-apex.conf
guard=$USERUNITS/apex-shell-safe.service
if [ ! -f "$(rootpath "$dropin")" ] || [ ! -f "$(rootpath "$guard")" ]; then
    fail "the crash guard is not installed ($dropin, $guard)"
elif ! grep -Eq '^OnFailure=([^#]* )?apex-shell-safe\.service( |$)' "$(rootpath "$dropin")"; then
    fail "$dropin does not add OnFailure=apex-shell-safe.service"
elif ! grep -q '^ConditionPathExists=%t/apex-shell-starting$' "$(rootpath "$guard")"; then
    fail "$guard is not gated on the layer's marker %t/apex-shell-starting"
elif ! grep -Eq '^Before=([^#]* )?gnome-session-restart-dbus\.service( |$)' "$(rootpath "$guard")"; then
    fail "$guard is not ordered before gnome-session-restart-dbus.service (its gsettings write would race the session bus restart)"
elif ! command -v systemd-analyze >/dev/null 2>&1; then
    fail "systemd-analyze not found"
else
    mkdir "$TMPD/run"
    rc=0
    env -i PATH=/usr/bin:/usr/sbin XDG_RUNTIME_DIR="$TMPD/run" SYSTEMD_UNIT_PATH="$(rootpath "$USERUNITS")" \
        systemd-analyze --user verify --man=no --recursive-errors=no \
        org.gnome.Shell@user.service apex-shell-safe.service </dev/null >"$TMPD/out" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
        fail "systemd-analyze --user verify (exit $rc): $(head -n 5 "$TMPD/out" | paste -sd '|' -)"
    elif grep -Eq '(apex-shell-safe\.service|50-apex\.conf)' "$TMPD/out"; then
        fail "systemd-analyze --user verify: $(grep -E '(apex-shell-safe\.service|50-apex\.conf)' "$TMPD/out" | head -n 5 | paste -sd '|' -)"
    else
        if [ -s "$TMPD/out" ]; then
            warn "systemd-analyze --user verify: messages about other units: $(head -n 3 "$TMPD/out" | paste -sd '|' -)"
        fi
        pass "the crash guard is installed: OnFailure=apex-shell-safe.service on GNOME Shell's unit, ordered before the session bus restart, and both verify"
    fi
fi

finish
