#!/bin/sh
# The Flatpak units' shell steps, run as systemd would run them (fake/unit-exec), with
# fake busctl, getent and flatpak; and the timers' schedules.
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
EOF
chmod 0755 "$BIN"/*

# unit_run UNIT KEY INDEX: run that command line with /usr/bin/{busctl,getent,flatpak}
# pointed at the fakes.
unit_run() {
    run env FAKE_FLATPAK_LOG="$T/flatpak.log" FAKE_PASSWD="$T/passwd" \
        "$FAKE/unit-exec" --run "$U/$1" "$2" "$3" \
        /usr/bin/busctl="$BIN/busctl" /usr/bin/getent="$BIN/getent" \
        /usr/bin/flatpak="$BIN/flatpak" /usr/bin/sh="$(command -v "$SH")"
}

# The fakes read these from the environment.
FAKE_METERED='' FAKE_GETENT_FAIL=''
export FAKE_METERED FAKE_GETENT_FAIL

# --- Metered gate: same in both services (review finding: missing on the preinstall) --
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

# --- Unused-runtime cleanup (review finding: it removed per-user apps' runtimes) ------
mkdir -p "$T/home/alice" "$T/home/bob" "$T/root"
cat >"$T/passwd" <<EOF
root:x:0:0:root:$T/root:/bin/bash
alice:x:1000:1000:Alice:$T/home/alice:/bin/bash
bob:x:1001:1001::$T/home/bob:/bin/bash
nobody:x:65534:65534:Kernel Overflow User:/:/usr/sbin/nologin
EOF
cleanup_step() {
    rm -f "$T/flatpak.log"
    unit_run apex-flatpak-update.service ExecStart 2
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
unit_run apex-flatpak-update.service ExecStart 2
FAKE_GETENT_FAIL=''
expect_rc "getent failing: the step succeeds" 0
if [ -e "$T/flatpak.log" ]; then not_ok "getent failing: nothing is uninstalled"; else ok "getent failing: nothing is uninstalled"; fi

# --- Timers ------------------------------------------------------------------------
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
