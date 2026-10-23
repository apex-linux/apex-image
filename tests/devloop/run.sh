#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Against a fake ssh and fake VM processes only: no VM, network or root.
set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd -- "$HERE/../.." && pwd)
readonly DESKTOP_VM=$REPO/tools/builder-vm/desktop-vm.sh
readonly SHELL_DEV=$REPO/tools/builder-vm/shell-dev.sh
readonly SHELL_DEV_GUEST=$REPO/tools/builder-vm/shell-dev-guest.sh
readonly THROWAWAY_PORT=2299
readonly BUILDER_PORT=2222
readonly OWNER_PORT=2223
readonly OWNER_STARTED_PORT=2301
readonly GUEST_SCRIPT_PATH=/var/lib/apex-shell-dev/bin/shell-dev-guest.sh
readonly BOOTED_DIGEST=sha256:aaaa000000000000000000000000000000000000000000000000000000000000
readonly STAGED_DIGEST=sha256:bbbb000000000000000000000000000000000000000000000000000000000000
readonly IMAGE_ID=cccc000000000000000000000000000000000000000000000000000000000000
readonly APEX_SOURCE=https://github.com/apex-linux/apex-image

tests=0
failed=0
ok() { tests=$((tests + 1)); printf 'ok %d - %s\n' "$tests" "$*"; }
not_ok() { tests=$((tests + 1)); failed=$((failed + 1)); printf 'not ok %d - %s\n' "$tests" "$*"; }
check() {
    local name=$1
    shift
    if "$@"; then ok "$name"; else not_ok "$name"; fi
}

T=$(mktemp -d "${TMPDIR:-/tmp}/apex-devloop-test.XXXXXX")
FAKE_PIDS=()
cleanup() {
    local pid
    for pid in "${FAKE_PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
    rm -rf -- "$T"
}
trap cleanup EXIT

unset APEX_DESKTOP_DIR APEX_DESKTOP_THROWAWAY APEX_DESKTOP_SSH_PORT APEX_DESKTOP_UNGATED APEX_VM_DIR APEX_VM_SSH_PORT \
    APEX_SHELL_DEV_PROBE_LIMIT CLAUDECODE
export HOME=$T/home XDG_DATA_HOME=$T/data XDG_CACHE_HOME=$T/cache FAKE_STATE=$T/state
export FAKE_BUILDER_PORT=$BUILDER_PORT FAKE_OWNER_PORT=$OWNER_PORT
readonly OWNER_DIR=$XDG_DATA_HOME/apex/desktop
readonly BUILDER_DIR=$XDG_DATA_HOME/apex/builder
readonly THROWAWAY_DIR=$T/throwaway
mkdir -p "$HOME" "$T/bin" "$FAKE_STATE" "$BUILDER_DIR"

cat >"$T/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
port=
while (($#)); do
    case $1 in
        -p) port=$2; shift 2 ;;
        -i | -o | -l | -F) shift 2 ;;
        -*) shift ;;
        *) shift; break ;;
    esac
done
cmd=$*
printf '%s\t%s\n' "$port" "$cmd" >>"$FAKE_STATE/ssh.log"
state=$FAKE_STATE
if [[ $port == "$FAKE_OWNER_PORT" ]]; then
    echo "fake ssh: refusing the owner's desktop VM port" >&2
    exit 98
fi
if [[ $port == "$FAKE_BUILDER_PORT" ]]; then
    case $cmd in
        *"sudo podman image inspect"*) cat "$state/builder-image" ;;
        *"sudo podman save"*) printf 'FAKE-OCI-ARCHIVE' ;;
        "test -"*) [[ ! -e $state/builder-drops-ssh ]] || exit 255; cd "$state/builder-home" && eval "$cmd" ;;
        *) cd "$state/builder-home" && eval "$cmd" ;;
    esac
    exit
fi
case $cmd in
    true) ;;
    *VARIANT_ID*) cat "$state/variant" ;;
    *"bootc status"*) cat "$state/bootc-status.json" ;;
    *"df --output=avail"*) cat "$state/avail" ;;
    *"podman image inspect"*) [[ -s $state/guest-image ]] && cat "$state/guest-image" || exit 125 ;;
    *"podman load"*) cat >"$state/loaded-archive" ;;
    *"podman tag"*) read -r _ _ id _ <<<"$cmd"; printf '%s\n' "$id" >"$state/guest-image" ;;
    *"podman rmi"*) ;;
    *"bootc switch"* | *"bootc upgrade"*) cp "$state/bootc-status-staged.json" "$state/bootc-status.json" ;;
    "cat /usr/share/apex/rpms.lock") cat "$state/vm-lock" ;;
    *"cat >/var/lib/apex-shell-dev/bin/shell-dev-guest.sh"*) cat >"$state/guest-script" ;;
    *"shell-dev-guest.sh receive inputs"*) cat >"$state/inputs.tar" ;;
    *"shell-dev-guest.sh receive src"*) cat >"$state/src.tar" ;;
    *"shell-dev-guest.sh log"*) exec sleep 300 ;;
    *"shell-dev-guest.sh eval Main.panel.height"*)
        [[ -n ${FAKE_REPO:-} ]] || exit 0
        partial=$FAKE_REPO/desktop/shell/data/theme/apex/_top-bar.scss
        if [[ -n ${FAKE_OWNER_EDITS_DURING_PROBE:-} ]] && grep -q 'height: 37px' "$partial" && ! grep -q '^// owner' "$partial"; then
            sed -i '1i // owner edit during the probe' "$partial"
        fi
        if [[ -z ${FAKE_NESTED_SHELL_IGNORES_EDITS:-} ]] &&
            grep -Eq '#panel:overview[^{]*[{][^}]*height: *37px' "$partial"; then
            echo "(true, '37')"
        else
            echo "(true, '32')"
        fi ;;
    *"shell-dev-guest.sh eval globalThis.apexDevloopProbe"*)
        echo "(true, '$(sed -n 's/^globalThis.apexDevloopProbe = \([0-9]*\);$/\1/p' "$FAKE_REPO/desktop/shell/js/ui/apex/layer.js")')" ;;
    *"shell-dev-guest.sh "*) ;;
    *) echo "fake ssh: unexpected desktop command: $cmd" >&2; exit 97 ;;
esac
EOF
cat >"$T/bin/qemu-system-x86_64" <<'EOF'
#!/bin/sh
echo called >>"$FAKE_STATE/qemu-called"
exit 1
EOF
# A script run through its #! line keeps its own name as comm, which is how the scripts
# tell their QEMU from any other process.
for vm in apex-desktop apex-builder; do
    printf '#!/bin/sh\nwhile :; do sleep 1; done\n' >"$T/bin/$vm"
done
chmod +x "$T/bin/ssh" "$T/bin/qemu-system-x86_64" "$T/bin/apex-desktop" "$T/bin/apex-builder"
export PATH=$T/bin:$PATH

fake_vm() {
    local comm=$1 pidfile=$2
    "$T/bin/$comm" -pidfile "$pidfile" &
    FAKE_PIDS+=("$!")
    mkdir -p -- "$(dirname -- "$pidfile")"
    printf '%s\n' "$!" >"$pidfile"
}

RC=0
run_cmd() {
    RC=0
    "$@" >"$T/out" 2>"$T/err" || RC=$?
}
err_has() { grep -qF -- "$1" "$T/err"; }
ssh_log_has() { [[ -f $FAKE_STATE/ssh.log ]] && grep -qF -- "$1" "$FAKE_STATE/ssh.log"; }
throwaway() { env APEX_DESKTOP_THROWAWAY=1 APEX_DESKTOP_DIR="$THROWAWAY_DIR" APEX_DESKTOP_SSH_PORT="$THROWAWAY_PORT" "$@"; }

run_cmd env APEX_DESKTOP_THROWAWAY=1 APEX_DESKTOP_SSH_PORT=$THROWAWAY_PORT "$DESKTOP_VM" status
check "throwaway guard refuses the owner's directory" \
    test "$RC" -ne 0 -a ! -e "$OWNER_DIR"
check "throwaway guard names the owner's VM in its refusal" err_has "refuses the owner's desktop VM"

mkdir -p "$THROWAWAY_DIR"
: >"$THROWAWAY_DIR/throwaway"
run_cmd env APEX_DESKTOP_THROWAWAY=1 APEX_DESKTOP_DIR="$THROWAWAY_DIR" "$DESKTOP_VM" status
check "throwaway guard refuses the owner's default ssh port" test "$RC" -ne 0
check "throwaway guard says which port" err_has "refuses ssh port $OWNER_PORT"

mkdir -p "$OWNER_DIR"
printf "%s\n" "$OWNER_STARTED_PORT" >"$OWNER_DIR/ssh-port"
run_cmd env APEX_DESKTOP_THROWAWAY=1 APEX_DESKTOP_DIR="$THROWAWAY_DIR" APEX_DESKTOP_SSH_PORT="$OWNER_STARTED_PORT" "$DESKTOP_VM" status
check "throwaway guard refuses the port the owner's VM started with" test "$RC" -ne 0
rm -rf -- "$OWNER_DIR"

mkdir -p "$T/unmarked"
run_cmd env APEX_DESKTOP_THROWAWAY=1 APEX_DESKTOP_DIR="$T/unmarked" APEX_DESKTOP_SSH_PORT=$THROWAWAY_PORT "$DESKTOP_VM" status
check "throwaway guard refuses a directory install did not mark" test "$RC" -ne 0
check "the refusal says how to make a throwaway VM" err_has "APEX_DESKTOP_THROWAWAY=1"

: >"$T/unmarked/disk.qcow2"
run_cmd env APEX_DESKTOP_THROWAWAY=1 APEX_DESKTOP_DIR="$T/unmarked" APEX_DESKTOP_SSH_PORT=$THROWAWAY_PORT "$DESKTOP_VM" install
check "install does not mark a directory that has a disk" test "$RC" -ne 0 -a ! -e "$T/unmarked/throwaway"

run_cmd env APEX_DESKTOP_THROWAWAY=1 APEX_DESKTOP_DIR="$T/fresh" APEX_DESKTOP_SSH_PORT=$THROWAWAY_PORT "$DESKTOP_VM" install
check "install marks a new directory throwaway (it stops later: no builder VM)" \
    test "$RC" -ne 0 -a -e "$T/fresh/throwaway" -a ! -e "$FAKE_STATE/qemu-called"

run_cmd env APEX_DESKTOP_THROWAWAY=2 "$DESKTOP_VM" status
check "APEX_DESKTOP_THROWAWAY takes only 0 or 1" test "$RC" -ne 0

run_cmd throwaway "$DESKTOP_VM" target
check "target prints the VM directory" test "$RC" -eq 0 -a "$(cat "$T/out")" == "$THROWAWAY_DIR"
check "target line names a throwaway VM and its port" \
    err_has "target: a throwaway desktop VM in $THROWAWAY_DIR, ssh 127.0.0.1:$THROWAWAY_PORT"

run_cmd env APEX_DESKTOP_THROWAWAY=0 "$DESKTOP_VM" target </dev/null
check "the default target is the owner's VM" \
    err_has "target: the owner's desktop VM in $OWNER_DIR, ssh 127.0.0.1:$OWNER_PORT"

rm -f -- "$FAKE_STATE/ssh.log"
for command in target status stop exec update destroy; do
    run_cmd "$DESKTOP_VM" "$command" </dev/null
    check "without a terminal, $command refuses the owner's VM unless it is named" \
        test "$RC" -ne 0 -a ! -e "$FAKE_STATE/ssh.log"
done
check "the refusal says how to name it" err_has "set APEX_DESKTOP_THROWAWAY=0"
run_cmd env APEX_DESKTOP_THROWAWAY=0 "$DESKTOP_VM" status </dev/null
check "APEX_DESKTOP_THROWAWAY=0 names the owner's VM on purpose" \
    test "$RC" -eq 0 && err_has "target: the owner's desktop VM"

run_cmd env APEX_DESKTOP_DIR="$THROWAWAY_DIR" "$DESKTOP_VM" status
check "a marked directory is a throwaway VM without the guard too" err_has "target: a throwaway desktop VM"

if command -v script >/dev/null 2>&1; then
    on_a_terminal() { script -qec "$(printf '%q ' "$@")" /dev/null >"$T/out" 2>"$T/err" </dev/null; }
    RC=0
    on_a_terminal "$DESKTOP_VM" status || RC=$?
    check "on a terminal, the owner's VM needs no naming" test "$RC" -eq 0
    RC=0
    on_a_terminal env CLAUDECODE=1 "$DESKTOP_VM" status || RC=$?
    check "an agent's session is refused the owner's VM even on a terminal" \
        bash -c "test $RC -ne 0 && grep -qF 'CLAUDECODE is set' '$T/out'"
    RC=0
    on_a_terminal env CLAUDECODE=1 APEX_DESKTOP_THROWAWAY=0 "$DESKTOP_VM" status || RC=$?
    check "unless it names the owner's VM" test "$RC" -eq 0

    mkdir -p "$OWNER_DIR/shell-dev/tree" "$OWNER_DIR/shell-dev/rpms"
    printf 'key=k1\n' >"$OWNER_DIR/shell-dev/source.env"
    fake_vm apex-desktop "$OWNER_DIR/qemu.pid"
    printf '%s\n' "$OWNER_STARTED_PORT" >"$OWNER_DIR/ssh-port"
    rm -f -- "$FAKE_STATE/ssh.log"
    RC=0
    on_a_terminal "$SHELL_DEV" push || RC=$?
    check "on a terminal, shell-dev push reaches the owner's VM" test "$RC" -eq 0
    check "and its piped calls arrive there" ssh_log_has "$OWNER_STARTED_PORT"$'\t'"bash $GUEST_SCRIPT_PATH receive src"
    rm -f -- "$FAKE_STATE/ssh.log"
    RC=0
    on_a_terminal env CLAUDECODE=1 "$SHELL_DEV" push || RC=$?
    check "an agent's shell-dev push is still refused the owner's VM" test "$RC" -ne 0 -a ! -e "$FAKE_STATE/ssh.log"
    kill "$(cat "$OWNER_DIR/qemu.pid")"
    rm -rf -- "$OWNER_DIR"
else
    ok "# SKIP no script(1) for a terminal"
fi

mkdir -p "$T/stale"
: >"$T/stale/throwaway"
fake_vm apex-desktop "$OWNER_DIR/qemu.pid"
owner_qemu=$(cat "$OWNER_DIR/qemu.pid")
printf '%s\n' "$owner_qemu" >"$T/stale/qemu.pid"
printf '%s\n' "$THROWAWAY_PORT" >"$T/stale/ssh-port"
run_cmd env APEX_DESKTOP_THROWAWAY=1 APEX_DESKTOP_DIR="$T/stale" APEX_DESKTOP_SSH_PORT=$THROWAWAY_PORT "$DESKTOP_VM" running
check "a stale pidfile naming another desktop VM's QEMU is not this VM running" test "$RC" -ne 0
run_cmd env APEX_DESKTOP_THROWAWAY=1 APEX_DESKTOP_DIR="$T/stale" APEX_DESKTOP_SSH_PORT=$THROWAWAY_PORT "$DESKTOP_VM" stop </dev/null
check "and stop leaves that QEMU alone" kill -0 "$owner_qemu"
kill "$owner_qemu"
rm -rf -- "$OWNER_DIR" "$T/stale"

fake_vm apex-desktop "$THROWAWAY_DIR/qemu.pid"
printf '%s\n' "$THROWAWAY_PORT" >"$THROWAWAY_DIR/ssh-port"
fake_vm apex-builder "$BUILDER_DIR/qemu.pid"

run_cmd env APEX_DESKTOP_DIR="$THROWAWAY_DIR" APEX_DESKTOP_SSH_PORT=2400 "$DESKTOP_VM" exec true
check "a running VM is reached on the port it started with" \
    grep -qx "$THROWAWAY_PORT"$'\t'true "$FAKE_STATE/ssh.log"
check "exec prints no target line" test "$RC" -eq 0 -a ! -s "$T/err"

bootc_status() {
    local spec_transport=$1 spec_image=$2 staged_digest=$3
    jq -n --arg transport "$spec_transport" --arg image "$spec_image" --arg booted "$BOOTED_DIGEST" \
        --arg staged "$staged_digest" '{
        spec: {image: {image: $image, transport: $transport}},
        status: {
            staged: (if $staged == "" then null else
                {image: {image: {image: "localhost/apex:build", transport: "containers-storage"},
                         version: null, imageDigest: $staged}} end),
            booted: {image: {image: {image: $image, transport: $transport},
                             version: null, imageDigest: $booted}}}}'
}

readonly GATES_DIR=$FAKE_STATE/builder-home/apex-fedora/_build
g2_passed() {
    local id=$1 status=${2:-passed}
    rm -rf -- "$GATES_DIR"
    mkdir -p "$GATES_DIR/g2/20260930T000000Z"
    printf 'image-id %s\nruns 2\nlock-sha256 0\nstatus %s\n' "$id" "$status" >"$GATES_DIR/g2/20260930T000000Z/result.txt"
}

reset_guest() {
    rm -f -- "$FAKE_STATE"/{ssh.log,loaded-archive,guest-image}
    g2_passed "$IMAGE_ID"
    printf 'apex\n' >"$FAKE_STATE/variant"
    printf '    500000000000\n' >"$FAKE_STATE/avail"
    printf '%s|4000000000|1|%s\n' "$IMAGE_ID" "$APEX_SOURCE" >"$FAKE_STATE/builder-image"
    bootc_status registry ghcr.io/apex-linux/apex-testing:45 "" >"$FAKE_STATE/bootc-status.json"
    bootc_status containers-storage localhost/apex:build "$STAGED_DIGEST" >"$FAKE_STATE/bootc-status-staged.json"
}

reset_guest
run_cmd throwaway "$DESKTOP_VM" update docker.io/library/fedora:45
check "update refuses an image outside local storage" test "$RC" -ne 0
check "update refuses it before any ssh" test ! -e "$FAKE_STATE/ssh.log"

run_cmd throwaway "$DESKTOP_VM" update localhost/a localhost/b
check "update takes at most one IMAGE" test "$RC" -ne 0

mkdir -p "$T/stopped"
: >"$T/stopped/throwaway"
run_cmd env APEX_DESKTOP_THROWAWAY=1 APEX_DESKTOP_DIR="$T/stopped" APEX_DESKTOP_SSH_PORT=$THROWAWAY_PORT "$DESKTOP_VM" update
check "update refuses a VM that is not running" test "$RC" -ne 0
check "update says the VM is not running" err_has "is not running"

reset_guest
printf 'silverblue\n' >"$FAKE_STATE/variant"
run_cmd throwaway "$DESKTOP_VM" update
check "update refuses a guest that does not run Apex" test "$RC" -ne 0
check "the refusal names the guest's variant" err_has "VARIANT_ID='silverblue'"
check "a refused guest never reaches the builder VM" bash -c "! grep -q '^$BUILDER_PORT' '$FAKE_STATE/ssh.log'"

reset_guest
printf '%s|4000000000|1|https://example.com/other\n' "$IMAGE_ID" >"$FAKE_STATE/builder-image"
run_cmd throwaway "$DESKTOP_VM" update
check "update refuses an image that is not Apex's" test "$RC" -ne 0 -a ! -e "$FAKE_STATE/loaded-archive"
check "the refusal names the image's source label" err_has "https://example.com/other"

reset_guest
printf '    1000\n' >"$FAKE_STATE/avail"
run_cmd throwaway "$DESKTOP_VM" update
check "update refuses a guest without room for the image" test "$RC" -ne 0 -a ! -e "$FAKE_STATE/loaded-archive"

reset_guest
g2_passed "$IMAGE_ID" failed
run_cmd throwaway "$DESKTOP_VM" update
check "update refuses an image whose G2 failed" test "$RC" -ne 0 -a ! -e "$FAKE_STATE/loaded-archive"
check "and says how to take it anyway" err_has "APEX_DESKTOP_UNGATED=1 takes it anyway"
g2_passed "${IMAGE_ID/cccc/dddd}"
run_cmd throwaway "$DESKTOP_VM" update
check "update refuses an image that another image's G2 pass does not cover" test "$RC" -ne 0 -a ! -e "$FAKE_STATE/loaded-archive"
run_cmd env APEX_DESKTOP_UNGATED=1 APEX_DESKTOP_THROWAWAY=1 APEX_DESKTOP_DIR="$THROWAWAY_DIR" \
    APEX_DESKTOP_SSH_PORT="$THROWAWAY_PORT" "$DESKTOP_VM" update
check "APEX_DESKTOP_UNGATED=1 takes it, with a warning" \
    bash -c "test $RC -eq 0 && grep -qF 'has passed no gate' '$T/err'"
reset_guest
rm -rf -- "$GATES_DIR"
mkdir -p "$GATES_DIR"
printf 'lock-sha256 0\nimage-id %s\ng2 passed\ng4 not due: its key passed on 2026-09-29T20:39:16Z for image beef\n' "$IMAGE_ID" \
    >"$GATES_DIR/gates-passed.txt"
run_cmd throwaway "$DESKTOP_VM" update
check "the gates record covers an image too, with G4's verdict as recorded" \
    bash -c "test $RC -eq 0 && grep -qF 'passed G1 and G2, and G4 not due: its key passed on 2026-09-29T20:39:16Z for image beef' '$T/err'"

reset_guest
run_cmd throwaway "$DESKTOP_VM" update
check "update stages the image" test "$RC" -eq 0
check "after naming the G2 pass" err_has "passed G2 (_build/g2/20260930T000000Z)"
check "update prints the target before the change" err_has "target: a throwaway desktop VM in $THROWAWAY_DIR"
check "update streams podman save into podman load" \
    test "$(cat "$FAKE_STATE/loaded-archive" 2>/dev/null)" == FAKE-OCI-ARCHIVE
check "update tags the loaded image id" test "$(cat "$FAKE_STATE/guest-image")" == "$IMAGE_ID"
check "update switches to the containers-storage image" \
    ssh_log_has "bootc switch --transport containers-storage localhost/apex:build"
check "update prints the old digest" err_has "old digest (booted): $BOOTED_DIGEST"
check "update prints the new digest" err_has "new digest (staged): $STAGED_DIGEST"
check "update prints the rollback for this same VM" \
    err_has "APEX_DESKTOP_THROWAWAY=1 just desktop-ssh 'bootc rollback && systemctl reboot'"
check "update records the staged digest as staged" \
    test "$(jq -r .staged.digest "$THROWAWAY_DIR/image.json")" == "$STAGED_DIGEST"
check "and leaves the installed image as install wrote it" test "$(jq -r '.digest // "none"' "$THROWAWAY_DIR/image.json")" == none

run_cmd throwaway "$DESKTOP_VM" status
check "status of a running VM names the booted and staged images from the guest" \
    bash -c "grep -qF 'booted: localhost/apex:build unversioned $BOOTED_DIGEST' '$T/err' && grep -qF 'staged: localhost/apex:build unversioned $STAGED_DIGEST' '$T/err'"

reset_guest
bootc_status containers-storage localhost/apex:build "" >"$FAKE_STATE/bootc-status.json"
run_cmd throwaway "$DESKTOP_VM" update
check "update upgrades a guest that follows the image already" \
    bash -c "grep -q 'bootc upgrade' '$FAKE_STATE/ssh.log' && ! grep -q 'bootc switch' '$FAKE_STATE/ssh.log'"

reset_guest
bootc_status registry ghcr.io/apex-linux/apex-testing:45 "" >"$FAKE_STATE/bootc-status-staged.json"
run_cmd throwaway "$DESKTOP_VM" update
check "update reports when bootc staged nothing" test "$RC" -eq 0
check "that report names the booted digest" err_has "nothing staged"

run_cmd throwaway "$SHELL_DEV" nonsense
check "shell-dev refuses an unknown command" test "$RC" -ne 0
run_cmd throwaway "$SHELL_DEV" eval
check "shell-dev eval needs JS" test "$RC" -ne 0
run_cmd env APEX_DESKTOP_THROWAWAY=1 APEX_DESKTOP_SSH_PORT=$THROWAWAY_PORT "$SHELL_DEV" run
check "shell-dev keeps the throwaway guard" test "$RC" -ne 0 -a ! -e "$OWNER_DIR"
run_cmd throwaway "$SHELL_DEV" run
check "shell-dev run needs fetched inputs" test "$RC" -ne 0
check "shell-dev run says to fetch" err_has "just shell-dev fetch"

readonly BUILDER_HOME=$FAKE_STATE/builder-home
readonly KEY=k1
readonly STOCK=gnome-shell-51.0-1.fc45
readonly DEVKIT_RPM=mutter-devkit-51.0-1.fc45.x86_64.rpm
readonly SRPM=gnome-shell-51.0-1.fc45.apex3.src.rpm
work=$BUILDER_HOME/apex-fedora/_build/pkg/gnome-shell
mkdir -p "$work/tree/.git" "$work/tree/js/ui/apex" "$work/tree/js/misc" "$work/tree/src" \
    "$work/tree/data/theme/apex" "$work/tree/data/theme/gnome-shell-sass" \
    "$BUILDER_HOME/apex-store/pkgs/gnome-shell/$KEY" "$THROWAWAY_DIR/shell-dev/rpms"
printf 'nvr=%s\nbase=0123\n' "$STOCK" >"$work/tree-info"
for f in js/ui/main.js js/ui/apex/layer.js js/misc/util.js src/main.c data/theme/gnome-shell-light.scss \
    data/theme/apex/_apex.scss data/theme/gnome-shell-sass/_colors.scss; do
    printf '// %s\n' "$f" >"$work/tree/$f"
done
printf 'devkit\n' >"$THROWAWAY_DIR/shell-dev/rpms/$DEVKIT_RPM"
printf 'srpm\n' >"$THROWAWAY_DIR/shell-dev/rpms/$SRPM"
fixture_devkit_sha=$(sha256sum "$THROWAWAY_DIR/shell-dev/rpms/$DEVKIT_RPM" | cut -d' ' -f1)
fixture_srpm_sha=$(sha256sum "$THROWAWAY_DIR/shell-dev/rpms/$SRPM" | cut -d' ' -f1)
cat >"$BUILDER_HOME/apex-store/pkgs/gnome-shell/$KEY/manifest.txt" <<EOF
# apex-lane manifest 1: kind nevra sha256 file
# pkg=gnome-shell family=gnome-shell key=$KEY release=1.fc45.apex3 n=3 stock=$STOCK pin=mutter-51.0-1.fc45 fedora=45 ga_reached=0 base=registry.fedoraproject.org/fedora@sha256:0
fedora-srpm gnome-shell-0:51.0-1.fc45.src 00 gnome-shell-51.0-1.fc45.src.rpm
built gnome-shell-common-0:51.0-1.fc45.apex3.noarch 00 gnome-shell-common-51.0-1.fc45.apex3.noarch.rpm
built gnome-shell-0:51.0-1.fc45.apex3.x86_64 00 gnome-shell-51.0-1.fc45.apex3.x86_64.rpm
mirror mutter-common-0:51.0-1.fc45.noarch 00 mutter-common-51.0-1.fc45.noarch.rpm
mirror mutter-0:51.0-1.fc45.x86_64 00 mutter-51.0-1.fc45.x86_64.rpm
dev mutter-devkit-0:51.0-1.fc45.x86_64 $fixture_devkit_sha $DEVKIT_RPM
apex-srpm gnome-shell-0:51.0-1.fc45.apex3.src $fixture_srpm_sha $SRPM
EOF
fixture_manifest=$(cat "$BUILDER_HOME/apex-store/pkgs/gnome-shell/$KEY/manifest.txt")

printf 'family gnome-shell stock %s\n' "$KEY" >"$FAKE_STATE/vm-lock"
run_cmd throwaway "$SHELL_DEV" fetch
check "fetch refuses a lock that ships Fedora's own gnome-shell" test "$RC" -ne 0
check "that refusal says stock" err_has "Fedora's own gnome-shell"

printf 'family gnome-shell built %s\nrpm gnome-shell built gnome-shell x 00 p\n' "$KEY" >"$FAKE_STATE/vm-lock"
printf 'nvr=gnome-shell-51.1-1.fc45\n' >"$work/tree-info"
run_cmd throwaway "$SHELL_DEV" fetch
check "fetch refuses a work tree of another Fedora build" test "$RC" -ne 0
check "that refusal names both builds" err_has "gnome-shell-51.1-1.fc45, but the shell was built from $STOCK"
printf 'nvr=%s\nbase=0123\n' "$STOCK" >"$work/tree-info"

: >"$FAKE_STATE/builder-drops-ssh"
run_cmd throwaway "$SHELL_DEV" fetch
check "fetch never remakes a work tree it could not look for" test "$RC" -ne 0
check "that refusal says why" err_has "cannot tell whether the builder VM has a gnome-shell work tree"
rm -f -- "$FAKE_STATE/builder-drops-ssh"

mv "$work/tree/.git" "$work/tree-git"
run_cmd throwaway "$SHELL_DEV" fetch
check "fetch refuses a work tree without its .git" test "$RC" -ne 0 -a -d "$work/tree/js"
check "and never remakes it" bash -c "! grep -q 'lane.sh prep' '$FAKE_STATE/ssh.log'"
mv "$work/tree-git" "$work/tree/.git"

run_cmd throwaway "$SHELL_DEV" fetch
inputs=$THROWAWAY_DIR/shell-dev
check "fetch takes the VM's build" test "$RC" -eq 0
check "fetch records the build it fetched for" grep -qx "shell_vr=51.0-1.fc45.apex3" "$inputs/source.env"
check "fetch records mutter-devkit's build" grep -qx "mutter_vr=51.0-1.fc45" "$inputs/source.env"
check "fetch records the RPM names" \
    bash -c "grep -qx 'devkit_rpm=$DEVKIT_RPM' '$inputs/source.env' && grep -qx 'srpm=$SRPM' '$inputs/source.env'"
check "fetch copies the work tree's upstream JS and SCSS" \
    test -f "$inputs/tree/js/ui/main.js" -a -f "$inputs/tree/js/misc/util.js" -a -f "$inputs/tree/data/theme/gnome-shell-sass/_colors.scss"
check "fetch leaves out the work tree's copy of the Apex files" \
    test ! -e "$inputs/tree/js/ui/apex" -a ! -e "$inputs/tree/data/theme/apex"
check "fetch leaves out the C sources" test ! -e "$inputs/tree/src"
check "fetch keeps mutter-devkit and the Apex SRPM" test -f "$inputs/rpms/$DEVKIT_RPM" -a -f "$inputs/rpms/$SRPM"

mkdir -p "$OWNER_DIR/shell-dev" "$BUILDER_HOME/apex-store"
: >"$OWNER_DIR/shell-dev/owner-file"
cp "$FAKE_STATE/vm-lock" "$BUILDER_HOME/apex-store/rpms.lock.next"
run_cmd "$SHELL_DEV" fetch </dev/null
check "without a terminal, shell-dev fetch refuses the owner's VM" \
    bash -c "test $RC -ne 0 -a -e '$OWNER_DIR/shell-dev/owner-file' && grep -qF 'stdin is not a terminal' '$T/err'"
check "and writes nothing into its directory" \
    test "$(find "$OWNER_DIR" -mindepth 1 | sort | paste -sd' ')" == "$OWNER_DIR/shell-dev $OWNER_DIR/shell-dev/owner-file"
run_cmd "$SHELL_DEV" screenshot </dev/null
check "nor does shell-dev screenshot" test "$RC" -ne 0 -a ! -e "$OWNER_DIR/screenshots"
rm -rf -- "$OWNER_DIR" "$BUILDER_HOME/apex-store/rpms.lock.next"

rm -f -- "$FAKE_STATE"/{guest-script,inputs.tar,src.tar}
run_cmd throwaway "$SHELL_DEV" push
check "push succeeds" test "$RC" -eq 0
check "push installs the guest script" cmp -s "$SHELL_DEV_GUEST" "$FAKE_STATE/guest-script"
check "push sends the inputs" \
    bash -c "tar -tf '$FAKE_STATE/inputs.tar' | grep -qx source.env && tar -tf '$FAKE_STATE/inputs.tar' | grep -qx 'rpms/$SRPM'"
check "push sends desktop/shell" bash -c "tar -tf '$FAKE_STATE/src.tar' | grep -qx './js/ui/apex/layer.js'"

wait_for_ssh_log() {
    local wanted_count=$1 text=$2 polls count
    local -r max_polls=75 poll_seconds=0.2
    for ((polls = 0; polls < max_polls; polls++)); do
        count=$(grep -cF -- "$text" "$FAKE_STATE/ssh.log" 2>/dev/null) || true
        ((${count:-0} >= wanted_count)) && return 0
        sleep "$poll_seconds"
    done
    return 1
}

rm -f -- "$FAKE_STATE/ssh.log"
env APEX_DESKTOP_THROWAWAY=1 APEX_DESKTOP_DIR="$THROWAWAY_DIR" APEX_DESKTOP_SSH_PORT="$THROWAWAY_PORT" \
    "$SHELL_DEV" run >"$T/run.out" 2>"$T/run.err" &
run_pid=$!
FAKE_PIDS+=("$run_pid")
check "run prepares, compiles and starts the nested shell" wait_for_ssh_log 1 "shell-dev-guest.sh start"
sleep 1.5
printf '/* edited */\n' >>"$inputs/tree/data/theme/gnome-shell-light.scss"
check "an SCSS edit is sent, compiled and reloaded" wait_for_ssh_log 1 "shell-dev-guest.sh reload"
check "the reload recompiled the sheets first" wait_for_ssh_log 2 "shell-dev-guest.sh compile"
printf '// edited\n' >>"$inputs/tree/js/ui/main.js"
check "a JS edit restarts the nested shell" wait_for_ssh_log 2 "shell-dev-guest.sh start"
kill -TERM "$run_pid"
wait "$run_pid" || true
check "stopping the loop stops the nested shell" ssh_log_has "shell-dev-guest.sh stop"
check "each reload says how long it took" grep -q 'reloaded in [0-9]*\.[0-9] s' "$T/run.err"

# A copy of the scripts and desktop/shell, so that the probe edits no file of this checkout.
probe_repo=$T/repo
mkdir -p "$probe_repo/tools" "$probe_repo/desktop"
cp -r "$REPO/tools/builder-vm" "$probe_repo/tools/"
cp -r "$REPO/desktop/shell" "$probe_repo/desktop/"
before=$(find "$probe_repo/desktop/shell" -type f -exec sha256sum {} + | sort)
run_cmd throwaway "$probe_repo/tools/builder-vm/shell-dev.sh" probe
check "probe refuses without a nested shell that answers" test "$RC" -ne 0
check "and says to start the loop" err_has "start the loop first"
run_cmd env FAKE_REPO="$probe_repo" APEX_DESKTOP_THROWAWAY=1 APEX_DESKTOP_DIR="$THROWAWAY_DIR" \
    APEX_DESKTOP_SSH_PORT="$THROWAWAY_PORT" "$probe_repo/tools/builder-vm/shell-dev.sh" probe
check "probe times an SCSS and a JS edit within the limit" test "$RC" -eq 0
check "it names the Apex partial" err_has "the SCSS edit of desktop/shell/data/theme/apex/_top-bar.scss showed in the nested shell after"
check "and layer.js" err_has "the JS edit of desktop/shell/js/ui/apex/layer.js showed in the nested shell after"
check "every file of desktop/shell is back as it was" \
    test "$(find "$probe_repo/desktop/shell" -type f -exec sha256sum {} + | sort)" == "$before"
check "and the copies from before the probe are gone" test ! -e "$THROWAWAY_DIR/.shell-dev-probe"

probe_partial=$probe_repo/desktop/shell/data/theme/apex/_top-bar.scss
run_cmd env FAKE_REPO="$probe_repo" FAKE_NESTED_SHELL_IGNORES_EDITS=1 APEX_SHELL_DEV_PROBE_LIMIT=1 \
    APEX_DESKTOP_THROWAWAY=1 APEX_DESKTOP_DIR="$THROWAWAY_DIR" APEX_DESKTOP_SSH_PORT="$THROWAWAY_PORT" \
    "$probe_repo/tools/builder-vm/shell-dev.sh" probe
check "an edit the nested shell never shows fails the probe" test "$RC" -eq 1
check "which says so" err_has "did not show within 1 s"
check "and still restores every file" \
    test "$(find "$probe_repo/desktop/shell" -type f -exec sha256sum {} + | sort)" == "$before"

cp -p "$probe_partial" "$T/partial-before"
run_cmd env FAKE_REPO="$probe_repo" FAKE_OWNER_EDITS_DURING_PROBE=1 APEX_DESKTOP_THROWAWAY=1 \
    APEX_DESKTOP_DIR="$THROWAWAY_DIR" APEX_DESKTOP_SSH_PORT="$THROWAWAY_PORT" "$probe_repo/tools/builder-vm/shell-dev.sh" probe
check "an owner's edit during the probe survives it" \
    test "$(cat "$probe_partial")" == "$(printf '// owner edit during the probe\n'; cat "$T/partial-before")"
check "and the probe takes out only its own line" err_has "took out only the probe's last line"
cp -p "$T/partial-before" "$probe_partial"

mkdir -p "$THROWAWAY_DIR/.shell-dev-probe"
run_cmd env FAKE_REPO="$probe_repo" APEX_DESKTOP_THROWAWAY=1 APEX_DESKTOP_DIR="$THROWAWAY_DIR" \
    APEX_DESKTOP_SSH_PORT="$THROWAWAY_PORT" "$probe_repo/tools/builder-vm/shell-dev.sh" probe
check "a probe that did not finish stops the next one" test "$RC" -ne 0
check "which says where the files from before it are" err_has "$THROWAWAY_DIR/.shell-dev-probe holds"
rm -rf -- "$THROWAWAY_DIR/.shell-dev-probe"

# shellcheck source=SCRIPTDIR/../../tools/builder-vm/shell-dev.sh
in_shell_dev() { (. "$SHELL_DEV" && "$@"); }
# shellcheck source=SCRIPTDIR/../../tools/builder-vm/shell-dev-guest.sh
in_guest() { (. "$SHELL_DEV_GUEST" && "$@"); }

check "lock_family reads the gnome-shell family" \
    test "$(in_shell_dev lock_family $'family libfprint built x\nfamily gnome-shell held k9 since=2026-10-01T00:00:00Z')" == "held k9"
check "manifest_stock reads the stock build" test "$(in_shell_dev manifest_stock "$fixture_manifest")" == "$STOCK"
check "manifest_entry takes the named package, not a longer name" \
    test "$(in_shell_dev manifest_entry "$fixture_manifest" mirror mutter)" == "mutter-0:51.0-1.fc45.x86_64 00 mutter-51.0-1.fc45.x86_64.rpm"
check "manifest_entry finds the Apex SRPM" \
    test "$(in_shell_dev manifest_entry "$fixture_manifest" apex-srpm gnome-shell)" == "gnome-shell-0:51.0-1.fc45.apex3.src $fixture_srpm_sha $SRPM"
check "version_release drops name, epoch and arch" \
    test "$(in_shell_dev version_release gnome-shell-0:51.0-1.fc45.apex3.1.x86_64)" == 51.0-1.fc45.apex3.1

check "an SCSS edit reloads the sheets" test "$(in_shell_dev reaction /r/desktop/shell/data/theme/apex/_apex.scss)" == reload
check "a JS edit restarts the nested shell" test "$(in_shell_dev reaction /r/x.scss /r/desktop/shell/js/ui/apex/layer.js)" == restart
check "a theme asset restarts the nested shell" \
    test "$(in_shell_dev reaction /r/desktop/shell/data/theme/apex/diamond-light.svg)" == restart
check "a build file changes nothing at runtime" \
    test "$(in_shell_dev reaction /r/desktop/shell/data/theme/apex/meson.build /r/desktop/shell/apex.gresource.xml)" == none
check "new inputs prepare the VM again" test "$(in_shell_dev reaction /v/shell-dev/source.env /r/a.js)" == prepare
check "changed_paths lists added, removed and changed files" \
    test "$(in_shell_dev changed_paths $'/a\t1\t1\n/b\t1\t1' $'/a\t2\t1\n/c\t1\t1' | paste -sd,)" == /a,/b,/c

check "the overlays put the checkout before the work tree" \
    test "$(in_guest overlays /g)" == "/org/gnome/shell/ui/apex=/g/src/js/ui/apex:/org/gnome/shell/theme/apex=/g/src/data/theme/apex:/org/gnome/shell/theme=/g/theme:/org/gnome/shell/ui=/g/inputs/tree/js/ui:/org/gnome/shell/misc=/g/inputs/tree/js/misc:/org/gnome/shell/gdm=/g/inputs/tree/js/gdm"
check "JS reaches Eval as one GVariant string" \
    test "$(in_guest gvariant_string $'a"b\\c\nd')" == '"a\"b\\c\nd"'

printf '1..%d\n' "$tests"
((failed == 0))
