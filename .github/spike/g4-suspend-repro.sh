#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# A throwaway spike, never merged: G4's lock-suspend row, reproduced on a hosted runner with
# qualify.sh's own start_vm. Run as root (QEMU may run in rootful podman).
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
usage: g4-suspend-repro.sh GUEST GPU QEMU [TRIALS]
  GUEST   base (the pinned fedora-bootc, kernel 7.2.11) or G (plus gdm and gnome-shell,
          a test user logged in through GDM, the session locked)
  GPU     virtio-vga (as G4) or VGA (bochs-drm)
  QEMU    fedora (Fedora 45's qemu-kvm-core in rootful podman) or native (Ubuntu's)
  TRIALS  per arm [2]; the arms are sw (S3, QMP system_wakeup), rtc (S3, rtc wakealarm)
          and s2idle (QMP send-key)
EOF
    exit 2
}

(($# >= 3)) || usage
readonly GUEST=$1 GPU=$2 QEMU_KIND=$3 TRIALS=${4:-2}
[[ $GUEST == base || $GUEST == G ]] || usage
[[ $GPU == virtio-vga || $GPU == VGA ]] || usage
[[ $QEMU_KIND == fedora || $QEMU_KIND == native ]] || usage
((EUID == 0)) || { echo "run as root" >&2; exit 2; }

SPIKE_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
BASE_IMAGE=$(sed -n 's/^ARG BASE=//p' "$SPIKE_ROOT/image/Containerfile")
readonly SPIKE_ROOT BASE_IMAGE
readonly OVMF_RPM=https://kojipkgs.fedoraproject.org/packages/edk2/20260812/9.fc45/noarch/edk2-ovmf-20260812-9.fc45.noarch.rpm
readonly KERNEL_WANT=7.2.11 KOJI_KERNEL=https://kojipkgs.fedoraproject.org/packages/kernel/7.2.11/200.fc45/x86_64
readonly TEST_USER=tester WAIT_SUSPEND=60 WAIT_RESUME=90
export QUALIFY_OUT=${RUNNER_TEMP:-/tmp}/g4-repro QUALIFY_MEM=3G QUALIFY_SMP=4 QUALIFY_LAYOUT=to-disk \
    QUALIFY_BOOT_TIMEOUT=300 QUALIFY_POLL=2
# shellcheck source=SCRIPTDIR/../scripts/qualify.sh
. "$SPIKE_ROOT/.github/scripts/qualify.sh"
set +E
trap - ERR

readonly IMAGE=localhost/g4-repro:$GUEST
readonly EVENTS=$QUALIFY_OUT/logs/qmp-events.log VERDICTS=$QUALIFY_OUT/verdicts.tsv
mkdir -p "$QUALIFY_OUT/logs" "$QUALIFY_OUT/bin"
say() { printf '[repro %s] %s\n' "$(date -u +%T)" "$*" >&2; }

firmware() {
    local fw=$QUALIFY_OUT/fw
    mkdir -p "$fw"
    curl -fsSL --retry 3 -o "$fw/ovmf.rpm" "$OVMF_RPM"
    (cd "$fw" && rpm2cpio ovmf.rpm | cpio -idm --quiet ./usr/share/edk2/ovmf/OVMF_CODE.fd ./usr/share/edk2/ovmf/OVMF_VARS.fd)
    export OVMF_CODE=$fw/usr/share/edk2/ovmf/OVMF_CODE.fd OVMF_VARS=$fw/usr/share/edk2/ovmf/OVMF_VARS.fd OVMF_FORMAT=raw
    say "firmware: edk2-ovmf-20260812-9.fc45, $(stat -c %s "$OVMF_CODE") bytes of OVMF_CODE.fd"
}

# The shim keeps start_vm's flags, swaps the GPU, and adds the event QMP and OVMF's debugcon.
qemu_shim() {
    if [[ $QEMU_KIND == fedora ]]; then
        printf '%s\n' 'FROM registry.fedoraproject.org/fedora:45' \
            "RUN dnf -y install qemu-kvm-core 'qemu-device-display-*' && dnf clean all" >"$QUALIFY_OUT/qemu.Containerfile"
        podman build -q -t localhost/g4-repro-qemu -f "$QUALIFY_OUT/qemu.Containerfile" "$QUALIFY_OUT" >/dev/null
        say "QEMU: $(podman run --rm localhost/g4-repro-qemu rpm -q qemu-kvm-core qemu-system-x86-core | paste -sd' ')"
    else
        say "QEMU: $(qemu-system-x86_64 --version | head -n 1) (Ubuntu)"
    fi
    cat >"$QUALIFY_OUT/bin/qemu-system-x86_64" <<'EOF'
#!/usr/bin/env bash
args=() pidfile=
while (($#)); do
    case $1 in
        virtio-vga) args+=("$REPRO_GPU") ;;
        -daemonize) [[ $REPRO_QEMU == native ]] && args+=(-daemonize) ;;
        -pidfile) pidfile=$2; args+=("$1" "$2"); shift ;;
        *) args+=("$1") ;;
    esac
    shift
done
stamp=$(date +%s)
args+=(-qmp "unix:$REPRO_EVENTS_SOCK,server=on,wait=off" -debugcon "file:$REPRO_LOGS/debugcon-$stamp.log"
    -global isa-debugcon.iobase=0x402)
if [[ $REPRO_QEMU == native ]]; then exec /usr/bin/qemu-system-x86_64 "${args[@]}"; fi
podman run -d --rm --name "g4-repro-qemu-$stamp" --privileged --pid=host --network=host -v /dev:/dev \
    -v "$REPRO_OUT:$REPRO_OUT" -v "$REPRO_FW:$REPRO_FW:ro" localhost/g4-repro-qemu qemu-system-x86_64 "${args[@]}" >/dev/null
for _ in $(seq 60); do [[ -s $pidfile ]] && exit 0; sleep 0.5; done
echo "qemu shim: no pidfile from the container" >&2
exit 1
EOF
    chmod +x "$QUALIFY_OUT/bin/qemu-system-x86_64"
    export PATH=$QUALIFY_OUT/bin:$PATH REPRO_GPU=$GPU REPRO_QEMU=$QEMU_KIND REPRO_LOGS=$QUALIFY_OUT/logs \
        REPRO_EVENTS_SOCK=$QUALIFY_OUT/qmp/events.sock REPRO_OUT=$QUALIFY_OUT REPRO_FW=$QUALIFY_OUT/fw
}

guest_image() {
    local gnome=''
    [[ $GUEST != G ]] || gnome="RUN dnf -y install gdm gnome-shell gnome-session && dnf clean all && systemctl set-default graphical.target && useradd -m $TEST_USER && echo $TEST_USER:repro | chpasswd && printf '[daemon]\nAutomaticLoginEnable=True\nAutomaticLogin=$TEST_USER\n' >/etc/gdm/custom.conf"
    cat >"$QUALIFY_OUT/guest.Containerfile" <<EOF
FROM $BASE_IMAGE
RUN set -eux; \\
    if ! dnf -y install 'kernel-$KERNEL_WANT*'; then \\
        dnf -y install $KOJI_KERNEL/kernel-$KERNEL_WANT-200.fc45.x86_64.rpm $KOJI_KERNEL/kernel-core-$KERNEL_WANT-200.fc45.x86_64.rpm \\
            $KOJI_KERNEL/kernel-modules-$KERNEL_WANT-200.fc45.x86_64.rpm $KOJI_KERNEL/kernel-modules-core-$KERNEL_WANT-200.fc45.x86_64.rpm || true; \\
    fi; \\
    for d in /usr/lib/modules/*; do v=\${d##*/}; case \$v in $KERNEL_WANT*) ;; *) if [ \$(ls /usr/lib/modules | wc -l) -gt 1 ]; then rpm -e --nodeps \$(rpm -qa | grep -F -- "-\$v") || true; rm -rf "\$d"; fi ;; esac; done; \\
    set -- /usr/lib/modules/*; kver=\${1##*/}; \\
    DRACUT_NO_XATTR=1 dracut --no-hostonly --reproducible -f "/usr/lib/modules/\$kver/initramfs.img" "\$kver"; \\
    echo "guest kernel: \$kver" >/usr/share/g4-repro-kernel
$gnome
EOF
    podman build -q -t "$IMAGE" -f "$QUALIFY_OUT/guest.Containerfile" "$QUALIFY_OUT" >/dev/null
    say "guest $GUEST: $BASE_IMAGE, $(podman run --rm "$IMAGE" cat /usr/share/g4-repro-kernel)"
}

events_tap() {
    python3 - "$REPRO_EVENTS_SOCK" "$EVENTS" >/dev/null 2>&1 <<'EOF' &
import json, socket, sys, time
for _ in range(60):
    try:
        s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); break
    except OSError:
        time.sleep(0.5)
f = s.makefile("rw"); f.readline()
f.write('{"execute":"qmp_capabilities"}\n'); f.flush(); f.readline()
with open(sys.argv[2], "a") as out:
    for line in f:
        m = json.loads(line)
        if "event" in m:
            out.write("%.3f %s %s\n" % (time.time(), m["event"], json.dumps(m.get("data", {})))); out.flush()
EOF
}

# Run in the guest by name: instrument, prep ARM, stats, ping-shell, login-lock.
guest_helper() {
    vm_ssh 'cat >/run/repro-guest.sh && chmod +x /run/repro-guest.sh' <<'EOF'
#!/bin/bash
set -u
case $1 in
instrument)
    echo N >/sys/module/printk/parameters/console_suspend
    echo 1 >/sys/power/pm_debug_messages
    echo 1 >/sys/power/pm_print_times
    dmesg -n 7
    systemctl is-active -q qualify-tap || systemd-run -q --unit=qualify-tap -p StandardOutput=tty -p TTYPath=/dev/ttyS0 \
        journalctl -f -n 0 -o short-monotonic
    systemctl is-active -q qualify-hb || systemd-run -q --unit=qualify-hb -p StandardOutput=tty -p TTYPath=/dev/ttyS0 \
        sh -c 'while :; do echo "repro-hb $(cut -d" " -f1 /proc/uptime) $(ip -br -4 a | tr "\n" " ") nm=$(nmcli -t -f STATE g 2>/dev/null)"; sleep 5; done' ;;
prep)
    case $2 in
        s2idle)
            echo s2idle >/sys/power/mem_sleep
            for w in /sys/bus/serio/devices/serio0/power/wakeup; do [ -e "$w" ] && echo enabled >"$w"; done ;;
        *) echo deep >/sys/power/mem_sleep ;;
    esac
    if [ "$2" = rtc ]; then echo 0 >/sys/class/rtc/rtc0/wakealarm; echo +20 >/sys/class/rtc/rtc0/wakealarm; fi
    cat /sys/power/mem_sleep ;;
stats)
    printf 'success=%s fail=%s wakeup_irq=%s uptime=%s\n' "$(cat /sys/power/suspend_stats/success)" \
        "$(cat /sys/power/suspend_stats/fail)" "$(cat /sys/power/pm_wakeup_irq 2>/dev/null || echo -)" "$(cut -d' ' -f1 /proc/uptime)" ;;
ping-shell)
    uid=$(id -u "$2")
    timeout 10 runuser -u "$2" -- env XDG_RUNTIME_DIR=/run/user/$uid DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus \
        gdbus call --session --dest org.gnome.Shell --object-path /org/gnome/Shell --method org.freedesktop.DBus.Peer.Ping ;;
login-lock)
    for _ in $(seq 90); do
        sid=$(loginctl list-sessions --no-legend | awk -v u="$2" '$3 == u && $4 == "seat0" { print $1; exit }')
        [ -n "$sid" ] && break
        sleep 2
    done
    [ -n "$sid" ] || { echo "no seat0 session of $2"; exit 1; }
    sleep 10
    loginctl lock-session "$sid"
    sleep 3
    loginctl show-session "$sid" -p LockedHint -p Type ;;
esac
EOF
}

boot() {
    rm -f "$REPRO_EVENTS_SOCK"
    start_vm repro "repro-$1"
    events_tap
    wait_ssh
    guest_helper
    vm_ssh /run/repro-guest.sh instrument >/dev/null 2>&1 || true
    if [[ $GUEST == G ]]; then
        say "login-lock: $(vm_ssh /run/repro-guest.sh login-lock "$TEST_USER" 2>&1 | paste -sd' ')"
    fi
}

# vm_ssh is a function, which timeout cannot run: a whole ssh attempt, banner included.
ssh_ok() {
    timeout 20 ssh -i "$QUALIFY_OUT/key" -p "$QUALIFY_SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -o BatchMode=yes -o ConnectTimeout=10 root@127.0.0.1 true >/dev/null 2>&1
}

hmp() { qmp_query "{\"execute\":\"human-monitor-command\",\"arguments\":{\"command-line\":\"$1\"}}" | jq -r . 2>/dev/null; }

dump_stuck() {
    local out=$QUALIFY_OUT/logs/$1.stuck.txt
    {
        echo "== query-status"; qmp_query '{"execute":"query-status"}' 2>&1
        echo "== info cpus"; hmp 'info cpus'
        for i in 1 2 3; do echo "== info registers -a ($i)"; hmp 'info registers -a'; sleep 1; done
        echo "== info usernet"; hmp 'info usernet'
    } >"$out" 2>&1 || true
}

# Lines of the console since OFFSET that name the suspend path, and the trial's events.
key_lines() {
    tail -c +"$(($2 + 1))" "$VM_SERIAL" 2>/dev/null | tr -d '\r' |
        grep -E 'PM: suspend (entry|exit)|PM: (resume|suspend) of devices|ACPI: PM: (Waking|Low-level|Preparing)|Restarting tasks|PM: Waking up|Freezing|Power key pressed|Operation .suspend. finished|NetworkManager.*(sleep|wake|state change)|pm_wakeup_irq|virtio_gpu|bochs|drm.*(resume|suspend)|repro-hb' |
        grep -vE 'repro-hb' | head -n 40
    grep -E ' (SUSPEND|WAKEUP|RESET|SHUTDOWN|STOP|RESUME) ' "$EVENTS" 2>/dev/null | tail -n +"$(($3 + 1))"
}

trial() {
    local arm=$1 n=$2 tag=$1-$2 off ev0 pre post verdict detail='' resumed=0 t0 woke=0
    pre=$(vm_ssh /run/repro-guest.sh stats 2>/dev/null) || pre=-
    vm_ssh /run/repro-guest.sh instrument >/dev/null 2>&1 || true
    vm_ssh /run/repro-guest.sh prep "$arm" >/dev/null 2>&1 || true
    off=$(stat -c %s "$VM_SERIAL")
    ev0=$(wc -l <"$EVENTS" 2>/dev/null || echo 0)
    vm_ssh 'systemd-run --quiet --on-active=2 systemctl suspend' >/dev/null 2>&1 || true
    t0=$SECONDS
    if [[ $arm == s2idle ]]; then
        until tail -c +"$((off + 1))" "$VM_SERIAL" | grep -q 'PM: suspend entry (s2idle)' || ((SECONDS - t0 > WAIT_SUSPEND)); do sleep 1; done
        sleep 5
    else
        until [[ $(vm_run_state 2>/dev/null) == suspended ]] || ((SECONDS - t0 > WAIT_SUSPEND)); do sleep 1; done
    fi
    if ((SECONDS - t0 > WAIT_SUSPEND)); then
        verdict=NOT-SUSPENDED detail="no suspend within ${WAIT_SUSPEND}s"
    else
        case $arm in
            sw) qmp '{"execute":"system_wakeup"}' >/dev/null 2>&1 && woke=1 ;;
            s2idle) qmp "$(key_press shift)" >/dev/null 2>&1 && woke=1 ;;
            rtc) woke=1 ;;
        esac
        t0=$SECONDS
        until ssh_ok; do
            if ((SECONDS - t0 >= WAIT_RESUME)) || ! vm_alive; then break; fi
            sleep 3
        done
        ssh_ok && resumed=1
    fi
    local events serial
    events=$(tail -n +"$((ev0 + 1))" "$EVENTS" 2>/dev/null | awk '{ print $2 }' | paste -sd' ')
    serial=$(tail -c +"$((off + 1))" "$VM_SERIAL" | tr -d '\r')
    if [[ -n $verdict ]]; then
        :
    elif ! vm_alive || [[ " $events " == *" SHUTDOWN "* ]]; then
        verdict=POWEROFF
    elif [[ $events =~ WAKEUP.*SUSPEND ]] || { [[ $arm != s2idle ]] && ((!resumed)) && [[ $(vm_run_state 2>/dev/null) == suspended && " $events " == *" WAKEUP "* ]]; }; then
        verdict=RESUSPENDED detail="it suspended again after the wake; no second system_wakeup was sent"
    elif ((resumed)); then
        post=$(vm_ssh /run/repro-guest.sh stats 2>/dev/null) || post=-
        detail="before: $pre; after: $post"
        verdict=PASS
        if [[ $GUEST == G ]] && ! vm_ssh /run/repro-guest.sh ping-shell "$TEST_USER" >/dev/null 2>&1; then
            verdict=RESUMED-SHELL-WEDGED detail+="; gnome-shell answers no D-Bus Ping"
        fi
    elif grep -q 'repro-hb' <<<"$(sed -n '/PM: suspend exit\|Restarting tasks/,$p' <<<"$serial")"; then
        verdict=RESUMED-NO-NET detail="the heartbeat runs on ttyS0 after resume; ssh does not answer"
    elif grep -qE 'ACPI: PM: Low-level resume complete|ACPI: PM: Waking up|PM: resume of devices|Restarting tasks' <<<"$serial"; then
        verdict=STUCK-EARLY-KERNEL detail="the kernel began its resume, then nothing: $(grep -E 'Low-level resume|Waking up|resume of devices|Restarting tasks' <<<"$serial" | tail -n 1 | cut -c1-160)"
    else
        verdict=STUCK-FIRMWARE detail="no kernel line after the wake (events: ${events:-none}; woke=$woke)"
    fi
    [[ $verdict == PASS* || $verdict == RESUMED-SHELL-WEDGED ]] || dump_stuck "$tag"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$GUEST" "$GPU" "$QEMU_KIND" "$arm" "$n" "$verdict" "$detail" >>"$VERDICTS"
    say "VERDICT $GUEST $GPU $QEMU_KIND $arm #$n: $verdict ($detail)"
    { echo "== $tag: $verdict"; key_lines "$tag" "$off" "$ev0"; } | tee -a "$QUALIFY_OUT/logs/key-lines.txt" >&2
    screendump "$tag" >/dev/null 2>&1 || true
    if [[ $verdict != PASS && $verdict != RESUMED-SHELL-WEDGED ]]; then
        say "power-cycling after $verdict"
        stop_vm || true
        boot "after-$tag"
    fi
}

main() {
    local arm n
    : >"$VERDICTS"
    firmware
    qemu_shim
    guest_image
    ensure_key
    install_disk repro "$IMAGE" "$IMAGE"
    boot first
    say "guest: $(vm_ssh 'uname -r; cat /sys/power/mem_sleep' | paste -sd' ')"
    for ((n = 1; n <= TRIALS; n++)); do
        for arm in sw rtc s2idle; do trial "$arm" "$n"; done
    done
    stop_vm || true
    {
        printf '### G4 lock-suspend repro: guest %s, %s, QEMU %s\n\n| Arm | Trial | Verdict | Detail |\n|---|---|---|---|\n' \
            "$GUEST" "$GPU" "$QEMU_KIND"
        awk -F'\t' '{ gsub(/\|/, "/", $7); printf "| %s | %s | %s | %s |\n", $4, $5, $6, $7 }' "$VERDICTS"
        printf '\n<details><summary>Key lines</summary>\n\n```\n'
        cut -c1-200 "$QUALIFY_OUT/logs/key-lines.txt"
        printf '```\n</details>\n'
    } >>"${GITHUB_STEP_SUMMARY:-/dev/stderr}"
    cat "$VERDICTS"
}

main "$@"
