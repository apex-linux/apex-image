#!/bin/sh
# bootloader-update.service's drop-in: its ExecCondition against fake systemctl, journalctl
# and sleep, and the boot transaction it joins, which must keep apex-boot-assess's job.
. "$(dirname -- "$0")/lib.sh"

command -v python3 >/dev/null 2>&1 || skip_all "python3 not found"

DROPIN=$IMAGE_DIR/system_files/usr/lib/systemd/system/bootloader-update.service.d/10-apex-after-green-boot.conf
ASSESS_UNIT=$APEX_SYSTEM_SRC/crates/apex-boot/data/apex-boot-assess.service
INVOCATION=0123456789abcdef0123456789abcdef
DIGEST=sha256:$(printf 'a%.0s' $(seq 64))

BIN=$T/bin
mkdir -p "$BIN"
cat >"$BIN/systemctl" <<'EOF'
#!/bin/sh
# systemd prints the properties in its own order, not in the order asked for.
case "$*" in
    "show -p InvocationID --value apex-boot-assess.service") printf '%s\n' "$FAKE_INVOCATION" ;;
    "show -p ActiveState -p Result -p ExecMainStatus apex-boot-assess.service")
        [ -z "${FAKE_SYSTEMCTL_FAIL:-}" ] || exit 1
        printf '%s\n' "$FAKE_ASSESS_STATE" | tr ' ' '\n' | sort -r ;;
    *) printf 'fake systemctl: unexpected %s\n' "$*" >&2; exit 2 ;;
esac
EOF
cat >"$BIN/journalctl" <<'EOF'
#!/bin/sh
reads=$(($(cat "$FAKE_READS") + 1))
echo "$reads" >"$FAKE_READS"
[ "$*" = "--boot _SYSTEMD_INVOCATION_ID=$FAKE_INVOCATION --output=cat --no-pager --quiet" ] ||
    { printf 'fake journalctl: unexpected %s\n' "$*" >&2; exit 2; }
[ "$reads" -ge "${FAKE_JOURNAL_AFTER:-1}" ] || exit 0
cat "$FAKE_JOURNAL"
EOF
cat >"$BIN/sleep" <<'EOF'
#!/bin/sh
echo "$*" >>"$FAKE_SLEEPS"
EOF
chmod 0755 "$BIN"/*

FAKE_INVOCATION=$INVOCATION FAKE_READS=$T/reads FAKE_SLEEPS=$T/sleeps FAKE_JOURNAL=$T/journal
FAKE_ASSESS_STATE='ActiveState=active Result=success ExecMainStatus=0'
FAKE_JOURNAL_AFTER=1 FAKE_SYSTEMCTL_FAIL=''
export FAKE_INVOCATION FAKE_READS FAKE_SLEEPS FAKE_JOURNAL FAKE_ASSESS_STATE FAKE_JOURNAL_AFTER \
    FAKE_SYSTEMCTL_FAIL

condition() {
    assessment_journal=$1
    printf '%s\n' "$assessment_journal" >"$FAKE_JOURNAL"
    echo 0 >"$FAKE_READS"
    : >"$FAKE_SLEEPS"
    run "$FAKE/unit-exec" --run "$DROPIN" ExecCondition 0 \
        /usr/bin/systemctl="$BIN/systemctl" /usr/bin/journalctl="$BIN/journalctl" \
        /usr/bin/sleep="$BIN/sleep" /usr/bin/sh="$(command -v "$SH")"
}

assessing=" INFO assessing this boot (at most 305 s)"
condition "$assessing
 INFO decision: green (report green $DIGEST)
 INFO step 0 (ReportBoot(green, $DIGEST)): done"
expect_rc "a green decision lets bootupctl run" 0
expect_out "and says so" 'judged this boot green'

condition " INFO decision: green (report green)"
expect_rc "green with the booted digest unknown" 0
condition " INFO decision: inconsistent (report green $DIGEST); grubenv: unset apex_target, unset apex_counter"
expect_rc "a green verdict on a stale arming" 0

condition " INFO decision: red-unarmed (report red-unarmed $DIGEST); failed: failed-units"
expect_rc "red-unarmed: skipped" 1
expect_out "with the decision in the journal" 'did not judge this boot green \( INFO decision: red-unarmed '
condition " INFO decision: red-armed-session (report red $DIGEST); failed: forced-red"
expect_rc "an update on trial that failed in a session: skipped" 1
condition " INFO decision: red-armed-no-session (report red $DIGEST); grubenv: set apex_ok=0; failed: forced-red; reboot"
expect_rc "an update on trial that failed without a session: skipped" 1
condition " INFO decision: fallback (report fallback $DIGEST); grubenv: set apex_counter=3, unset apex_target, unset apex_counter"
expect_rc "the boot after GRUB fell back: skipped" 1
condition " INFO decision: armed-for-next-boot (report red-unarmed $DIGEST); failed: session"
expect_rc "red while an Apply waits for the next boot: skipped" 1
condition " INFO decision: green (report green-ish $DIGEST)"
expect_rc "only the verdict green counts" 1

condition " INFO decision: green (report green $DIGEST)
 INFO decision: red-unarmed (report red-unarmed $DIGEST); failed: session"
expect_rc "the last decision of the invocation wins" 1

FAKE_JOURNAL_AFTER=3
condition " INFO decision: green (report green $DIGEST)"
FAKE_JOURNAL_AFTER=1
expect_rc "a decision journald stores late still counts" 0
if [ "$(wc -l <"$FAKE_SLEEPS")" -eq 2 ]; then ok "after two waits"; else not_ok "after two waits (slept $(wc -l <"$FAKE_SLEEPS") times)"; fi

condition "$assessing"
expect_rc "no decision in the journal: skipped" 1
expect_out "and says so" 'no decision in its journal'
if [ "$(cat "$FAKE_READS")" -eq 11 ]; then ok "after ten waits for journald"; else not_ok "after ten waits for journald ($(cat "$FAKE_READS") reads)"; fi

SNAPSHOT=$APEX_SYSTEM_SRC/crates/apex-boot/src/snapshots/apex_boot__decide__tests__decision_table_snapshot.snap

# The Rust test assess_process checks that the logged "decision: " line has this form.
snapshot_decisions_as_logged() {
    sed -n 's/^.* => //p' "$SNAPSHOT" | sed "s/\\bT\\b/$DIGEST/g; s/\\bP\\b/$DIGEST/g" | grep -vx decision | sort -u
}

snapshot_decisions_as_logged >"$T/decisions"
wrong=''
while IFS= read -r decision; do
    case $decision in
        'green '*) expected_rc=0 ;;
        red-* | fallback*) expected_rc=1 ;;
        *'(report green'*) expected_rc=0 ;;
        *) expected_rc=1 ;;
    esac
    condition " INFO decision: $decision"
    [ "$RC" -eq "$expected_rc" ] || wrong="$wrong|$decision (exit $RC)"
done <"$T/decisions"
if [ "$(grep -c '^green ' "$T/decisions")" -gt 0 ] && [ "$(grep -c '^red-' "$T/decisions")" -gt 0 ] && [ -z "$wrong" ]; then
    ok "each of the $(wc -l <"$T/decisions") decisions of the snapshot: only a green verdict lets bootupctl run"
else
    not_ok "each decision of the snapshot: only a green verdict lets bootupctl run (wrong:${wrong:- none; the snapshot lacks green or red rows})"
fi

green=" INFO decision: green (report green $DIGEST)"
for state in 'ActiveState=activating ExecMainStatus=0 Result=success' \
    'ActiveState=active ExecMainStatus=1 Result=exit-code' \
    'ActiveState=failed ExecMainStatus=0 Result=timeout' \
    'ActiveState=inactive ExecMainStatus=0 Result=success'; do
    FAKE_ASSESS_STATE=$state
    condition "$green"
    expect_rc "assessment $state: skipped whatever its journal says" 1
    expect_out "and the reason names the state" "has not finished every step of this boot \\($state\\)"
done
FAKE_ASSESS_STATE='ActiveState=active Result=success ExecMainStatus=0'
FAKE_SYSTEMCTL_FAIL=1
condition "$green"
FAKE_SYSTEMCTL_FAIL=''
expect_rc "systemctl failing: skipped, not failed (exit 1, never 255)" 1

expect_file "ordered after the assessment" '^After=.*[[:space:]=]apex-boot-assess\.service([[:space:]]|$)' "$DROPIN"
expect_file "keeps the default ordering against shutdown" '^Before=shutdown\.target$' "$DROPIN"
expect_file "and the conflict with it" '^Conflicts=shutdown\.target$' "$DROPIN"
expect_file "and the requirement on sysinit.target" '^Requires=sysinit\.target$' "$DROPIN"
if grep -Eq '^(Wants|Requires|Requisite|BindsTo)=.*apex-boot-assess' "$DROPIN"; then
    not_ok "never pulls the assessment in"
else
    ok "never pulls the assessment in"
fi

if ! command -v systemd-analyze >/dev/null 2>&1; then
    done_testing
    exit
fi

boot_units() {
    unit_dir=$1
    dropin_under_test=$2
    mkdir -p "$unit_dir/multi-user.target.wants" "$unit_dir/graphical.target.wants" "$unit_dir/bootloader-update.service.d"
    printf '[Unit]\nDescription=sysinit\nDefaultDependencies=no\n' >"$unit_dir/sysinit.target"
    printf '[Unit]\nDescription=shutdown\nDefaultDependencies=no\n' >"$unit_dir/shutdown.target"
    printf '[Unit]\nDescription=basic\nRequires=sysinit.target\nAfter=sysinit.target\n' >"$unit_dir/basic.target"
    printf '[Unit]\nDescription=multi-user\nRequires=basic.target\nAfter=basic.target\n' >"$unit_dir/multi-user.target"
    printf '[Unit]\nDescription=graphical\nRequires=multi-user.target\nAfter=multi-user.target\n' >"$unit_dir/graphical.target"
    sed 's|^ExecStart=.*|ExecStart=/bin/true|' "$ASSESS_UNIT" >"$unit_dir/apex-boot-assess.service"
    printf '[Unit]\nDescription=bootupd\n\n[Service]\nType=oneshot\nExecStart=/bin/true\nRemainAfterExit=yes\n\n[Install]\nWantedBy=multi-user.target\n' \
        >"$unit_dir/bootloader-update.service"
    ln -s ../apex-boot-assess.service "$unit_dir/graphical.target.wants/apex-boot-assess.service"
    ln -s ../bootloader-update.service "$unit_dir/multi-user.target.wants/bootloader-update.service"
    cp "$dropin_under_test" "$unit_dir/bootloader-update.service.d/"
}

verify_boot() {
    run env SYSTEMD_UNIT_PATH="$1" systemd-analyze verify --man=no --generators=no graphical.target
}

boot_units "$T/units" "$DROPIN"
verify_boot "$T/units"
expect_rc "the boot transaction verifies" 0
expect_no_out "without an ordering cycle" 'ordering cycle'
expect_no_out "and keeps every start job" 'deleted to break'

printf '[Unit]\nAfter=apex-boot-assess.service\n' >"$T/after-only.conf"
boot_units "$T/after-only" "$T/after-only.conf"
verify_boot "$T/after-only"
expect_out "control: After= alone closes the cycle through multi-user.target" 'Found ordering cycle'
expect_out "which systemd breaks by dropping a start job, at times the assessment's" 'start deleted to break ordering cycle'

done_testing
