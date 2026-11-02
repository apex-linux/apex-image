#!/bin/sh
# The Flatpak units' shell steps, run as systemd would run them (fake/unit-exec), with
# fake busctl, getent, flatpak, systemctl and journalctl; and the timers' schedules.
. "$(dirname -- "$0")/lib.sh"

command -v python3 >/dev/null 2>&1 || skip_all "python3 not found"

U=$IMAGE_DIR/system_files/usr/lib/systemd/system
BIN=$T/bin
mkdir -p "$BIN"
cat >"$BIN/busctl" <<'EOF'
#!/bin/sh
# Prints the Metered property as busctl does ("u N"), or fails.
[ -n "${FAKE_METERED:-}" ] || exit 1
printf 'u %s\n' "$FAKE_METERED"
EOF
cat >"$BIN/getent" <<'EOF'
#!/bin/sh
[ "$1" = passwd ] || exit 2
[ -z "${FAKE_GETENT_FAIL:-}" ] || exit 2
cat "$FAKE_PASSWD"
EOF
cat >"$BIN/flatpak" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$FAKE_FLATPAK_LOG"
case $1 in
    list) cat "$FAKE_FLATPAK_LIST" ;;
    install) [ -z "${FAKE_INSTALL_FAIL:-}" ] || exit 1 ;;
esac
EOF
cat >"$BIN/systemctl" <<'EOF'
#!/bin/sh
case "$*" in
    *--value*) echo 0123abcd ;;
    *) printf '%s\n' $FAKE_ASSESS ;;
esac
EOF
cat >"$BIN/journalctl" <<'EOF'
#!/bin/sh
case "$*" in *_SYSTEMD_INVOCATION_ID=0123abcd*) printf '%s\n' "$FAKE_DECISION" ;; esac
EOF
chmod 0755 "$BIN"/*

# unit_run UNIT KEY INDEX: runs that Exec line with /usr/bin/{busctl,getent,flatpak}
# pointed at the fakes.
unit_run() {
    run env FAKE_FLATPAK_LOG="$T/flatpak.log" FAKE_PASSWD="$T/passwd" FAKE_FLATPAK_LIST="$T/flatpak.list" \
        "$FAKE/unit-exec" --run "$U/$1" "$2" "$3" \
        /usr/bin/busctl="$BIN/busctl" /usr/bin/getent="$BIN/getent" \
        /usr/bin/flatpak="$BIN/flatpak" /usr/bin/sh="$(command -v "$SH")" \
        /usr/bin/systemctl="$BIN/systemctl" /usr/bin/journalctl="$BIN/journalctl" \
        /sys/module/nvidia/version="$T/nvidia-version"
}

# apex-boot-assess's own decision lines, from its decision table as t-bootloader reads them,
# so a change to their format fails here too.
SNAPSHOT=$APEX_SYSTEM_SRC/crates/apex-boot/src/snapshots/apex_boot__decide__tests__decision_table_snapshot.snap
DIGEST=sha256:$(printf 'a%.0s' $(seq 64))
logged_decision() {
    sed -n 's/^.* => //p' "$SNAPSHOT" | sed "s/\\bT\\b/$DIGEST/g; s/\\bP\\b/$DIGEST/g" | grep -m 1 "^$1" | sed 's/^/ INFO decision: /'
}
GREEN_DECISION=$(logged_decision 'green (report green sha256:')
GREEN_PLAIN_DECISION=$(logged_decision 'green (report green)')
RED_DECISION=$(logged_decision 'red-armed-session (report red sha256:')
if [ -n "$GREEN_DECISION" ] && [ -n "$GREEN_PLAIN_DECISION" ] && [ -n "$RED_DECISION" ]; then
    ok "apex-boot's decision table logs a green decision with and without a digest, and a red one"
else
    not_ok "apex-boot's decision table logs a green decision with and without a digest, and a red one ($SNAPSHOT)"
fi

FAKE_METERED='' FAKE_GETENT_FAIL='' FAKE_INSTALL_FAIL=''
GREEN='ActiveState=active ExecMainStatus=0 Result=success'
FAKE_ASSESS=$GREEN FAKE_DECISION=$GREEN_DECISION
export FAKE_METERED FAKE_GETENT_FAIL FAKE_INSTALL_FAIL FAKE_ASSESS FAKE_DECISION

for unit in apex-flatpak-preinstall.service apex-flatpak-update.service; do
    for m in 1 3; do
        FAKE_METERED=$m
        unit_run "$unit" ExecCondition 0
        expect_rc "$unit: skipped on Metered=$m" 1
    done
    for m in 0 2 4; do
        FAKE_METERED=$m
        unit_run "$unit" ExecCondition 0
        expect_rc "$unit: runs on Metered=$m" 0
    done
    FAKE_METERED=''
    unit_run "$unit" ExecCondition 0
    expect_rc "$unit: runs when NetworkManager cannot be asked" 0
done

mkdir -p "$T/home/alice" "$T/home/bob" "$T/root"
cat >"$T/passwd" <<EOF
root:x:0:0:root:$T/root:/bin/bash
alice:x:1000:1000:Alice:$T/home/alice:/bin/bash
bob:x:1001:1001::$T/home/bob:/bin/bash
nobody:x:65534:65534:Kernel Overflow User:/:/usr/sbin/nologin
EOF
cleanup_step() {
    rm -f "$T/flatpak.log"
    unit_run apex-flatpak-update.service ExecStart 3
}

cleanup_step
expect_rc "no per-user Flatpaks: the cleanup runs" 0
expect_file "and removes unused system runtimes" '^uninstall --system --unused --noninteractive$' "$T/flatpak.log"

mkdir -p "$T/home/bob/.local/share/flatpak/app/org.example.App"
cleanup_step
expect_rc "a per-user app: the step still succeeds" 0
if [ -e "$T/flatpak.log" ]; then not_ok "a per-user app: flatpak uninstall is not run"; else ok "a per-user app: flatpak uninstall is not run"; fi
expect_out "and the journal says why" 'has per-user Flatpaks: unused system runtimes are kept'
rm -rf "$T/home/bob/.local"

mkdir -p "$T/home/alice/.local/share/flatpak/runtime/org.example.Platform"
cleanup_step
if [ -e "$T/flatpak.log" ]; then not_ok "a per-user runtime also keeps the cleanup off"; else ok "a per-user runtime also keeps the cleanup off"; fi
rm -rf "$T/home/alice/.local"

mkdir -p "$T/root/.local/share/flatpak/app/org.example.App"
cleanup_step
expect_file "root's own per-user apps do not block it (flatpak sees them)" '^uninstall ' "$T/flatpak.log"
rm -rf "$T/root/.local"

rm -f "$T/flatpak.log"
FAKE_GETENT_FAIL=1
unit_run apex-flatpak-update.service ExecStart 3
FAKE_GETENT_FAIL=''
expect_rc "getent failing: the step succeeds" 0
if [ -e "$T/flatpak.log" ]; then not_ok "getent failing: nothing is uninstalled"; else ok "getent failing: nothing is uninstalled"; fi

gl_step() {
    rm -f "$T/flatpak.log"
    : >>"$T/flatpak.log"
    unit_run apex-flatpak-update.service ExecStart 2
}
no_uninstall() {
    if grep -q '^uninstall' "$T/flatpak.log"; then not_ok "$1"; else ok "$1"; fi
}
GL=org.freedesktop.Platform.GL
printf '%s\n' org.freedesktop.Platform $GL.default $GL.nvidia-615-71-09 $GL.nvidia-615-78-08 \
    $GL.nvidia-615-80-01 org.example.GL.nvidia-1 >"$T/flatpak.list"

rm -f "$T/nvidia-version"
gl_step
expect_rc "GL.nvidia without the NVIDIA driver: the step succeeds" 0
expect_out "and says why" '^no NVIDIA driver loaded: no GL.nvidia extension$'
if [ -s "$T/flatpak.log" ]; then not_ok "and runs no flatpak"; else ok "and runs no flatpak"; fi

printf '615.78.08\n' >"$T/nvidia-version"
gl_step
expect_rc "GL.nvidia of a green boot: the step succeeds" 0
expect_file "installs the loaded driver's extension, dots as dashes" \
    "^install --system --noninteractive --or-update flathub runtime/$GL\\.nvidia-615-78-08/x86_64/1\\.4\$" "$T/flatpak.log"
expect_file "removes a stale one" "^uninstall --system --noninteractive $GL\\.nvidia-615-71-09\$" "$T/flatpak.log"
expect_file "and a newer one" "^uninstall --system --noninteractive $GL\\.nvidia-615-80-01\$" "$T/flatpak.log"
expect_true "and nothing else" test "$(grep -c '^uninstall' "$T/flatpak.log")" -eq 2

FAKE_ASSESS='ActiveState=active ExecMainStatus=1 Result=exit-code'
gl_step
expect_rc "a boot not judged green: the step succeeds" 0
expect_file "and installs the extension" '^install ' "$T/flatpak.log"
no_uninstall "but keeps the stale ones"
expect_out "and says why" 'has not judged this boot green: stale GL.nvidia extensions stay'
FAKE_ASSESS=$GREEN

FAKE_DECISION=$GREEN_PLAIN_DECISION
gl_step
expect_file "a green decision with no digest removes the stale ones too" \
    "^uninstall --system --noninteractive $GL\\.nvidia-615-71-09\$" "$T/flatpak.log"
FAKE_DECISION=$RED_DECISION
gl_step
no_uninstall "a red decision keeps the stale ones"
FAKE_DECISION=''
gl_step
no_uninstall "no decision in the journal keeps them too"
FAKE_DECISION=$GREEN_DECISION

FAKE_INSTALL_FAIL=1
gl_step
expect_rc "the extension fails to install: the step fails" 1
no_uninstall "and removes nothing"
FAKE_INSTALL_FAIL=''

printf 'x\n' >"$T/nvidia-version"
gl_step
expect_rc "an unreadable driver version: the step fails" 1
if grep -q '^install' "$T/flatpak.log"; then not_ok "and installs nothing"; else ok "and installs nothing"; fi
rm -f "$T/nvidia-version"

expect_file "the preinstall is retried after boot" '^OnBootSec=5min$' "$U/apex-flatpak-preinstall.timer"
expect_file "the last retry is 4 h after boot" '^OnBootSec=4h$' "$U/apex-flatpak-preinstall.timer"
if command -v systemd-analyze >/dev/null 2>&1; then
    cal=$(sed -n 's/^OnCalendar=//p' "$U/apex-flatpak-update.timer")
    run env TZ=UTC systemd-analyze calendar --iterations=5 --base-time='2026-09-24 01:00:00 UTC' "$cal"
    expect_out "update slots: 06:00" '(Next|Iteration).*2026-09-24 06:00:00'
    expect_out "update slots: 12:00" 'Iteration #2.*2026-09-24 12:00:00'
    expect_out "update slots: 18:00" 'Iteration #3.*2026-09-24 18:00:00'
    expect_out "update slots: midnight" 'Iteration #4.*2026-09-25 00:00:00'
fi

done_testing
