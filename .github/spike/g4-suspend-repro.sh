#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# W17b, a draft PR that is never merged: run 17's local-lock-suspend replayed with qualify.sh's
# start_vm, Fedora 45's QEMU and OVMF; a verdict never fails the job, setup does (PR #131).
set -euo pipefail

REPRO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
export QUALIFY_OUT=${QUALIFY_OUT:-${RUNNER_TEMP:-/tmp}/g4-suspend-repro}
# run_g4 (tools/builder-vm/build-image.sh) gives the guest 3G and 4 vCPUs. to-disk: stock
# fedora-bootc also installs BIOS GRUB, which separate-boot's table has no partition for.
export QUALIFY_LAYOUT=to-disk QUALIFY_MEM=${QUALIFY_MEM:-3G} QUALIFY_SMP=${QUALIFY_SMP:-4}
export QUALIFY_BOOT_TIMEOUT=${QUALIFY_BOOT_TIMEOUT:-420} QUALIFY_LOGIN_TIMEOUT=${QUALIFY_LOGIN_TIMEOUT:-90}
# shellcheck source=SCRIPTDIR/../scripts/qualify.sh
. "$REPRO_ROOT/.github/scripts/qualify.sh"

: "${REPRO_TRIALS:=G-sw H-sw G-rtc H-rtc G-s2idle H-s2idle G-s2idle-stdvga H-s2idle-stdvga}"
: "${REPRO_EXTRAS:=auto}"
: "${REPRO_KERNEL:=7.2.11-300.fc45}" # "base" keeps the base image's kernel
: "${REPRO_EDK2:=20260812-9.fc45}"   # the guest's DMI line in run 17: BIOS edk2-20260812-9.fc45
: "${REPRO_QEMU:=fedora}"            # fedora: Fedora 45's qemu-kvm-core in a container; native: the host's
: "${REPRO_GUEST_IMAGE:=}"           # a bootc image to test instead of the derived one
: "${REPRO_WAKE_WINDOW:=90}" # G4 waits 900 s; a healthy resume answers in seconds
: "${REPRO_RTC_SECS:=25}"
: "${REPRO_PRINT_TIMES:=1}"
: "${REPRO_DEBUGCON:=1}"
: "${REPRO_DEADLINE:=$(($(date +%s) + 1500))}"
: "${REPRO_BASE:=$(sed -n 's/^ARG BASE=//p' "$REPRO_ROOT/image/Containerfile" | head -n 1)}"
[[ -n $REPRO_BASE ]] || die "no ARG BASE= in image/Containerfile and no REPRO_BASE"

readonly LOGS=$QUALIFY_OUT/logs
readonly TRIALS_DIR=$LOGS/trials
readonly TIMELINE=$LOGS/timeline.tsv
readonly ROWS=$LOGS/summary-rows.md
readonly QMP_LOG=$LOGS/qmp-events.jsonl
readonly EVENTS_SOCK=$QUALIFY_OUT/qmp/repro-events.sock
readonly WATCH_STOP=$QUALIFY_OUT/qmp/watch.stop
readonly BUILD_DIR=$QUALIFY_OUT/build
readonly GUEST_IMAGE_BUILT=localhost/repro-guest:45
readonly QEMU_IMAGE=localhost/repro-qemu:45
readonly KOJI=https://kojipkgs.fedoraproject.org/packages

# A second QMP monitor, held for the whole run: every event with the host's time, and
# query-status once a second. qualify.sh's own socket stays free for its one-shot clients.
QMP_WATCH=$(
    cat <<'EOF'
import json, os, socket, sys, time
path, out_path, stop_path = sys.argv[1:4]
out = open(out_path, "a", buffering=1)
def put(**rec):
    rec["t"] = round(time.time(), 3)
    out.write(json.dumps(rec, sort_keys=True) + "\n")
while not os.path.exists(stop_path):
    try:
        s = socket.socket(socket.AF_UNIX)
        s.settimeout(2)
        s.connect(path)
    except OSError:
        time.sleep(0.5)
        continue
    put(kind="connected")
    buf, last, next_poll, next_tick = b"", None, 0.0, 0.0
    try:
        s.sendall(b'{"execute":"qmp_capabilities"}\n')
        s.settimeout(0.25)
        while not os.path.exists(stop_path):
            if time.time() >= next_poll:
                s.sendall(b'{"execute":"query-status","id":"st"}\n')
                next_poll = time.time() + 1.0
            try:
                chunk = s.recv(65536)
            except socket.timeout:
                continue
            if not chunk:
                break
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                if not line.strip():
                    continue
                try:
                    msg = json.loads(line)
                except ValueError:
                    put(kind="garbage", raw=line[:200].decode("utf-8", "replace"))
                    continue
                if "event" in msg:
                    put(kind="event", event=msg["event"], data=msg.get("data"), qemu_ts=msg.get("timestamp"))
                elif msg.get("id") == "st" and "return" in msg:
                    st = msg["return"].get("status")
                    if st != last or time.time() >= next_tick:
                        put(kind="status", status=st, change=(st != last))
                        last, next_tick = st, time.time() + 15
                elif "error" in msg:
                    put(kind="error", error=msg["error"])
    except OSError as e:
        put(kind="oserror", error=str(e))
    finally:
        s.close()
    put(kind="disconnected")
    time.sleep(0.5)
EOF
)
readonly QMP_WATCH

# Reads one trial's directory and prints its summary row; writes verdict.json beside it.
CLASSIFY=$(
    cat <<'EOF'
import bisect, gzip, json, os, re, sys
tdir = sys.argv[1]
meta = {}
with open(os.path.join(tdir, "meta.tsv"), encoding="utf-8", errors="replace") as fh:
    for line in fh:
        k, _, v = line.rstrip("\n").partition("\t")
        if k:
            meta[k] = v
def num(k, d=None):
    try:
        return float(meta.get(k, ""))
    except ValueError:
        return d
STRIP = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\r")
def read(name):
    try:
        with open(os.path.join(tdir, name), "rb") as fh:
            return STRIP.sub("", fh.read().decode("utf-8", "replace"))
    except OSError:
        return ""
pre, post, ovmf = read("serial-pre.txt"), read("serial-post.txt"), read("ovmf-post.txt")
recov, pdown = read("serial-recovery.txt"), read("serial-powerdown.txt")
def lines(text, prefix=None):
    out = []
    for l in text.splitlines():
        tagged = l[:3] in ("JT ", "HB ", "EV ")
        if prefix is None and not tagged:
            out.append(l)
        elif prefix is not None and l.startswith(prefix):
            out.append(l[3:])
    return out
kpost, jt, hb, ev = lines(post), lines(post, "JT "), lines(post, "HB "), lines(post, "EV ")
kpost += [f for l in hb + ev for f in re.findall(r"\[ *\d+\.\d+\] .*", l)]
def count(rx, ls):
    r = re.compile(rx)
    return sum(1 for l in ls if r.search(l))
# QMP: events and run states from the watcher, from the suspend request on.
t_req = num("t_suspend_req", num("t_start", 0.0))
t_end = num("t_window_end", 1e18)
events, states = [], []
try:
    with open(meta["qmp_log"]) as fh:
        for l in fh:
            try:
                r = json.loads(l)
            except ValueError:
                continue
            if r.get("t", 0) < t_req - 1:
                continue
            if r.get("kind") == "event":
                events.append(r)
            elif r.get("kind") == "status":
                states.append(r)
except (OSError, KeyError):
    pass
susp = [e for e in events if e["event"] == "SUSPEND"]
t_susp = susp[0]["t"] if susp else None
wakes = [e for e in events if e["event"] == "WAKEUP" and t_susp is not None and e["t"] >= t_susp]
t_wake = wakes[0]["t"] if wakes else num("t_wake_sent")
def after(name, lo, hi):
    return [e for e in events if e["event"] == name and lo is not None and lo < e["t"] <= hi]
q_resusp = len(after("SUSPEND", t_wake, t_end))
q_wakeups = len(after("WAKEUP", (t_wake or 0) - 0.001, t_end))
q_resets = len(after("RESET", t_req, t_end))
q_shut = after("SHUTDOWN", t_wake, t_end)
q_shut_any = after("SHUTDOWN", t_wake, 1e18)
final_state = None
for s in states:
    if s["t"] <= t_end:
        final_state = s["status"]
tl = [f'{s["status"]}@{s["t"] - t_wake:+.0f}s' for s in states
      if s.get("change") and t_wake is not None and t_wake - 2 <= s["t"] <= t_end]
to_susp = (t_susp - num("t_suspend_req")) if (t_susp and num("t_suspend_req")) else None
# The guest's console after the wake (kernel lines only: JT/HB/EV are the guest's taps).
K = dict(llr=r"ACPI: PM: Low-level resume complete", waking=r"ACPI: PM: Waking up from system sleep state S3",
         finishing=r"PM: Finishing wakeup", exit=r"PM: suspend exit", entry=r"PM: suspend entry",
         thawed=r"Restarting tasks: Done",
         err=r"(virtio|drm|PM:).*(error|fail|time(d )?out)|BUG|WARNING|blocked for more than|Call Trace|soft lockup|rcu.*stall|Oops|panic")
k = {name: count(rx, kpost) for name, rx in K.items()}
k_err = [l.strip()[:160] for l in kpost if re.search(K["err"], l) and not re.search(r": calling |returned -?\d+ after", l)][:3]
opened = {}
for l in kpost:
    m = re.search(r"\]\s+(.+?): calling (\S+) @ \d+", l)
    if m:
        opened[(m.group(1), m.group(2))] = l.strip()
        continue
    m = re.search(r"\]\s+(.+?): (\S+) returned -?\d+ after", l)
    if m:
        opened.pop((m.group(1), m.group(2)), None)
open_calls = list(opened.values())[-2:]
cold = re.search(r"BdsDxe|GRUB version|Loading DXE CORE", post + ovmf) is not None
fw = dict(ran=re.search(r"Platform PEIM Loaded|SecCoreStartupWithStack", ovmf) is not None,
          s3=("Enter S3 PEIM" in ovmf), script=("S3ResumeExecuteBootScript" in ovmf),
          vector=re.search(r"OS waking vector", ovmf) is not None)
# Userspace taps after the wake.
u = dict(power_key=count(r"Power key pressed", jt), gsd_vm=count(r"Virtual machines only honor", jt),
         sleep_again=count(r"The system will suspend now|Performing sleep operation|Entering sleep state", jt),
         returned=count(r"System returned from sleep|Operation 'suspend' finished|finished\.$", jt),
         poweroff=count(r"System is powering down|Powering off|poweroff", jt),
         nm=[l.strip()[:140] for l in jt if re.search(r"NetworkManager.*(sleep|wake|asleep)", l)][-1:])
# evtest and printk share ttyS0, so a key line can be split by a kernel line.
def evkeys(code_name, code_num):
    n = len(re.findall(rf"code {code_num} \({code_name}\), value 1\b", re.sub(r"\[ *\d+\.\d+\] [^\n]*\n?", "", post)))
    for l in ev:
        p = l.split()
        if len(p) == 12 and all(x.isdigit() for x in p) and p[8] == "1" and p[9] == str(code_num) and p[10] == "1":
            n += 1
    return n
u["key_power"], u["key_wakeup"] = evkeys("KEY_POWER", 116), evkeys("KEY_WAKEUP", 143)
last_hb = hb[-1].strip() if hb else ""
net_down = bool(last_hb) and (re.search(r"ip=(none|\S*DOWN)", last_hb) is not None or re.search(r"nm=(asleep|disconnected)", last_hb) is not None)
# Snapshots: S3 time from CLOCK_BOOTTIME minus CLOCK_MONOTONIC, and printk's clock against monotonic.
def snap(name):
    d = {}
    for l in read(name).splitlines():
        a, _, b = l.partition("=")
        d[a] = b
    return d
spre, spost = snap("pre.txt"), snap("post.txt")
clock = ""
try:
    s3 = (float(spost["boottime_s"]) - float(spre["boottime_s"])) - (int(spost["mono_ns"]) - int(spre["mono_ns"])) / 1e9
    m = re.match(r"\[\s*([\d.]+)\]", spost.get("last_kmsg", ""))
    pk = (float(m.group(1)) - int(spost["mono_ns"]) / 1e9) if m else None
    clock = f"{'slept' if meta.get('wake') == 's2idle' else 'S3'} {s3:.1f}s" + (f", printk-mono {pk:+.1f}s" if pk is not None else "")
except (KeyError, ValueError):
    pass
woke_by = [k2[3:] for k2 in spost if k2.startswith("wk_") and spre.get(k2) != spost.get(k2)]
ss = {k2: (spre.get(k2), spost.get(k2)) for k2 in ("ss_success", "ss_fail", "ss_last_failed_step", "ss_last_failed_dev") if spre.get(k2) != spost.get(k2)}
# vCPUs at the timeout, symbolized with this boot's /proc/kallsyms.
syms = []
ks = meta.get("kallsyms", "")
if ks and os.path.exists(ks):
    try:
        with gzip.open(ks, "rt", errors="replace") as fh:
            for l in fh:
                p = l.split()
                if len(p) >= 3 and p[1] in ("t", "T", "w", "W") and p[0] != "0" * 16:
                    syms.append((p[0], p[2] + (p[3] if len(p) > 3 else "")))
    except (OSError, EOFError):
        syms = []
    syms.sort()
addrs = [a for a, _ in syms]
def where(rip):
    rip = rip.lower().rjust(16, "0")
    v = int(rip, 16)
    if rip >= "ffffffff80000000":
        i = bisect.bisect_right(addrs, rip) - 1
        return f"{syms[i][1]}+0x{v - int(addrs[i], 16):x}" if i >= 0 else "kernel"
    if 0xFF000000 <= v <= 0xFFFFFFFF:
        return "firmware-flash"
    if v < 0x100000:
        return "below-1M(trampoline?)"
    return "ram"
rips = []
for i in (1, 2, 3):
    text = read(f"regs-{i}.txt")
    cpus = re.findall(r"CPU#(\d+)", text)
    regs = re.findall(r"RIP=([0-9a-fA-F]+).*?HLT=(\d)", text)
    if regs:
        rips.append(" ".join(f"cpu{c}:{where(r)}{'(hlt)' if h == '1' else ''}" for c, (r, h) in zip(cpus, regs)))
# Verdict.
ssh = meta.get("ssh", "")
gnome = meta.get("mode") == "gnome"
bare = meta.get("inst") == "bare"
resusp = q_resusp > 0 or final_state == "suspended" or k["entry"] > 0
s2idle = meta.get("wake") == "s2idle"
if not meta.get("t_suspended_seen"):
    v = "NO-SUSPEND"
elif ssh == "ok" and s2idle and "ss_success" not in ss:
    v = "NO-SUSPEND"
elif ssh == "ok":
    if meta.get("boot_id_after") and meta.get("boot_id_after") != meta.get("boot_id_before"):
        v = "COLD-BOOT"
    elif gnome and meta.get("shell") == "silent":
        v = "SHELL-SILENT-AFTER-RESUME"
    elif gnome and meta.get("locked_after") == "no":
        v = "UNLOCKED-AFTER-RESUME"
    elif gnome and (meta.get("unlock") != "password" or meta.get("shell") != "answers"):
        v = "SESSION-BROKEN"
    else:
        v = "PASS"
elif ssh == "late":
    v = "PASS-SLOW"
elif ssh == "after-second-wakeup" or resusp:
    v = "RESUSPENDED"
elif q_shut or meta.get("qemu_exited") == "yes":
    v = "POWERED-OFF"
elif cold:
    v = "COLD-BOOT"
elif bare:
    v = "UNREACHABLE-BARE"
elif k["exit"]:
    v = ("RESUMED-NO-NET" if net_down else "RESUMED-NO-SSH") if hb else "USERSPACE-STALLED"
elif k["thawed"]:
    v = "STUCK-POST-SUSPEND"
elif k["llr"] or k["waking"]:
    v = "STUCK-DEVICE-RESUME"
elif fw["vector"]:
    v = "STUCK-EARLY-KERNEL"
elif fw["s3"]:
    v = "STUCK-FIRMWARE"
elif fw["ran"]:
    v = "STUCK-FIRMWARE-EARLY"
else:
    v = "NO-GUEST-OUTPUT"
def yn(b):
    return "y" if b else "n"
cell = lambda s: str(s).replace("|", "/").replace("\n", " ")
qmp_cell = (f"{final_state or '?'}; {' '.join(tl) or '-'}; re-SUSPEND x{q_resusp} WAKEUP x{q_wakeups} RESET x{q_resets}"
            + (f"; SHUTDOWN {(q_shut_any[0].get('data') or {}).get('reason', '?')}" if q_shut_any else ""))
fw_cell = ("cold boot" if cold else
           f"PEI {yn(fw['ran'])} S3-PEIM {yn(fw['s3'])} bootscript {yn(fw['script'])} OS-vector {yn(fw['vector'])}")
k_cell = (f"LLR {yn(k['llr'])} waking {yn(k['waking'])} finish {yn(k['finishing'])} exit {yn(k['exit'])} re-entry x{k['entry']}"
          + (f"; open: {open_calls[-1][-110:]}" if open_calls else "") + (f"; {k_err[0]}" if k_err else ""))
u_cell = (f"HB x{len(hb)}" + (f" [{last_hb[-90:]}]" if last_hb else "")
          + f"; KEY_POWER x{u['key_power']} KEY_WAKEUP x{u['key_wakeup']}"
          + (f"; 'Power key pressed' x{u['power_key']}" if u["power_key"] else "")
          + (f"; gsd VM rule x{u['gsd_vm']}" if u["gsd_vm"] else "")
          + (f"; sleep-again x{u['sleep_again']}" if u["sleep_again"] else "")
          + (f"; poweroff x{u['poweroff']}" if u["poweroff"] else "")
          + (f"; {u['nm'][0]}" if u["nm"] else ""))
s_cell = (f"locked {meta.get('locked_after', '?')}, unlock {meta.get('unlock', '?')}, shell {meta.get('shell', '?')}, "
          f"Apex layer {meta.get('apex_layer', '?')}"
          if gnome else "-")
t_ref = t_wake or num("t_suspend_req") or num("t_start", 0.0)
ssh_cell = {"ok": f"{num('t_ssh_ok') - t_ref:.0f}s" if num("t_ssh_ok") else "yes", "late": "late (ConnectTimeout=60)",
            "after-second-wakeup": "after a 2nd system_wakeup"}.get(ssh, "none")
extra = []
if meta.get("status_at_timeout"):
    extra.append(f"timeout state {meta['status_at_timeout']}")
if rips:
    extra.append("vCPUs " + rips[0])
if meta.get("powerdown_exit"):
    extra.append(f"system_powerdown: QEMU exited {meta['powerdown_exit']}"
                 + ("; guest reacted" if re.search(r"Power key|powering down|Stopping|reboot: Power down", pdown) else "; no guest reaction"))
if woke_by:
    extra.append("wakeup sources " + ",".join(woke_by[:4]))
if ss:
    extra.append("suspend_stats " + ",".join(f"{a}:{b[0]}->{b[1]}" for a, b in ss.items()))
if spost.get("pm_wakeup_irq", "-") not in ("", "-"):
    extra.append(f"pm_wakeup_irq {spost['pm_wakeup_irq']}")
row = (f"| {meta.get('trial')} | b{meta.get('boot', '?')}/S3#{meta.get('s3_in_boot', '?')} | {meta.get('wake')}"
       + (" (rtc did not fire)" if meta.get("rtc_woke") == "no" else "")
       + f" | {f'{to_susp:.0f}s' if to_susp is not None else '-'} | {ssh_cell} | {cell(qmp_cell)} | {cell(fw_cell)}"
       + f" | {cell(k_cell)} | {cell(u_cell)} | {cell(s_cell)} | {cell(clock or '-')} | **{v}**"
       + (f" ({cell('; '.join(extra))})" if extra else "") + " |")
json.dump(dict(verdict=v, meta=meta, qmp=dict(final=final_state, timeline=tl, resuspend=q_resusp, wakeups=q_wakeups,
                                               resets=q_resets, shutdown=[e.get("data") for e in q_shut_any]),
               firmware=fw, cold_boot=cold, kernel=k, kernel_errors=k_err, open_calls=open_calls, userspace=u,
               last_hb=last_hb, rips=rips, clock=clock, wakeup_sources=woke_by, suspend_stats=ss),
          open(os.path.join(tdir, "verdict.json"), "w"), indent=1, default=str)
print(row)
EOF
)
readonly CLASSIFY

GUEST_IDENTITY=$(
    cat <<'EOF'
echo "kernel $(uname -r)"
echo "cmdline $(cat /proc/cmdline)"
echo "virt $(systemd-detect-virt) chassis $(hostnamectl chassis 2>/dev/null)"
echo "mem_sleep $(cat /sys/power/mem_sleep) state $(cat /sys/power/state)"
echo "rtc0 wakeup $(cat /sys/class/rtc/rtc0/device/power/wakeup 2>/dev/null)"
echo "kptr_restrict $(cat /proc/sys/kernel/kptr_restrict)"
rpm -q kernel-core systemd gdm gnome-shell mutter gnome-settings-daemon NetworkManager evtest 2>&1
dmesg | grep -E 'DMI:|ACPI: PM: \(supports|Unstable clock|clocksource: Switched|kvm-clock: using|tsc: Marking|Power Button' || true
EOF
)
readonly GUEST_IDENTITY

GUEST_PREP=$(
    cat <<'EOF'
set -eu
user=$1
id -u "$user" >/dev/null 2>&1 || useradd --create-home --comment 'Apex qualification' "$user"
runuser -u "$user" -- sh -c 'mkdir -p ~/.config && echo yes > ~/.config/gnome-initial-setup-done'
mkdir -p /etc/gdm
printf '[daemon]\nAutomaticLoginEnable=True\nAutomaticLogin=%s\n' "$user" > /etc/gdm/custom.conf
EOF
)
readonly GUEST_PREP

# full keeps the console on through suspend with PM debug lines and taps (JT, HB, EV) on ttyS0,
# so userspace shows after a thaw with no network; bare is qualify.sh's quiet, suspended console.
GUEST_INSTRUMENT=$(
    cat <<'EOF'
set -u
mode=$1 times=$2
mkdir -p /run/repro
for u in repro-jtap repro-hb repro-ev; do
    systemctl stop "$u.service" 2>/dev/null
    systemctl reset-failed "$u.service" 2>/dev/null
done
sysctl -qw kernel.sysrq=1
if [ "$mode" = bare ]; then
    echo Y > /sys/module/printk/parameters/console_suspend
    dmesg -n 4
    echo 0 > /sys/power/pm_debug_messages
    echo 0 > /sys/power/pm_print_times
    echo "REPRO instrumentation off: console_suspend=Y loglevel=4" > /dev/ttyS0
    exit 0
fi
echo N > /sys/module/printk/parameters/console_suspend
dmesg -n 8
echo 1 > /sys/power/pm_debug_messages
echo "$times" > /sys/power/pm_print_times
cat > /run/repro/jtap.sh <<'EOS'
journalctl -f -n 0 -p info -o short-monotonic --no-hostname _TRANSPORT=journal _TRANSPORT=syslog _TRANSPORT=stdout |
    stdbuf -oL sed 's/^/JT /' > /dev/ttyS0
EOS
cat > /run/repro/hb.sh <<'EOS'
while :; do
    ip4=$(ip -4 -br addr show scope global 2>/dev/null | awk '{printf "%s:%s:%s,", $1, $2, $3}')
    printf 'HB real=%s up=%s ip=%s nm=%s sshd=%s load=%s\n' "$(date +%s)" "$(cut -d' ' -f1 /proc/uptime)" \
        "${ip4:-none}" "$(nmcli -t -f STATE general 2>/dev/null || echo na)" "$(systemctl is-active sshd 2>/dev/null)" \
        "$(cut -d' ' -f1 /proc/loadavg)"
    sleep 5
done > /dev/ttyS0
EOS
cat > /run/repro/ev.sh <<'EOS'
for e in /sys/class/input/event*; do
    [ "$(cat "$e/device/name" 2>/dev/null)" = "Power Button" ] || continue
    dev=/dev/input/${e##*/}
    echo "watching $dev (Power Button, no grab)"
    if command -v evtest >/dev/null; then stdbuf -oL evtest "$dev"; else stdbuf -oL od -An -v -w24 -tu2 "$dev"; fi
done 2>&1 | stdbuf -oL sed 's/^/EV /' > /dev/ttyS0
EOS
for u in jtap hb ev; do
    systemd-run --quiet --collect --unit="repro-$u" /bin/sh "/run/repro/$u.sh"
done
echo "REPRO instrumentation on: console_suspend=N loglevel=8 pm_debug_messages=1 pm_print_times=$times" > /dev/ttyS0
EOF
)
readonly GUEST_INSTRUMENT

# The kmsg line first, so that printk's newest timestamp can be set against CLOCK_MONOTONIC.
GUEST_SNAPSHOT=$(
    cat <<'EOF'
echo "repro: snapshot" > /dev/kmsg
printf 'last_kmsg=%s\n' "$(dmesg | tail -n 1)"
printf 'mono_ns=%s\n' "$(awk '/^now at/ {print $3; exit}' /proc/timer_list)"
printf 'boottime_s=%s\n' "$(cut -d' ' -f1 /proc/uptime)"
printf 'real=%s\n' "$(date +%s.%N)"
printf 'boot_id=%s\n' "$(cat /proc/sys/kernel/random/boot_id)"
for f in /sys/power/suspend_stats/*; do printf 'ss_%s=%s\n' "${f##*/}" "$(tr '\n' ' ' < "$f" 2>/dev/null)"; done
for w in /sys/class/wakeup/wakeup*; do
    printf 'wk_%s=%s/%s\n' "$(tr -c 'A-Za-z0-9_.:\n' _ < "$w/name")" "$(cat "$w/event_count")" "$(cat "$w/wakeup_count")"
done
printf 'pm_wakeup_irq=%s\n' "$(cat /sys/power/pm_wakeup_irq 2>/dev/null || echo -)"
printf 'mem_sleep=%s\n' "$(cat /sys/power/mem_sleep)"
printf 'printk=%s\n' "$(tr '\t' ' ' < /proc/sys/kernel/printk)"
printf 'console_suspend=%s\n' "$(cat /sys/module/printk/parameters/console_suspend)"
EOF
)
readonly GUEST_SNAPSHOT

now() { date +%s.%3N; }
left() { echo $((REPRO_DEADLINE - $(date +%s))); }
fsize() { stat -c %s "$1" 2>/dev/null || echo 0; }
mark() {
    printf '%s\t%s\t%s\n' "$(now)" "${TRIAL_ID:-setup}" "$*" >>"$TIMELINE"
    log "[$(date -u +%T) ${TRIAL_ID:-setup}] $*"
}
# qualify.sh's QMP_QUERY with 8 s instead of 30 s: a wedged monitor must not eat the budget.
qmpq() { python3 -c "${QMP_QUERY/settimeout(30)/settimeout(8)}" "$QMP_SOCKET" "$1"; }
hmp() {
    qmpq "$(jq -cn --arg c "$1" '{execute: "human-monitor-command", arguments: {"command-line": $c}}')" |
        jq -r 'if type == "string" then . else tojson end'
}
probe_ssh() {
    local ct=${1:-10}
    timeout $((ct + 15)) ssh -i "$QUALIFY_OUT/key" -p "$QUALIFY_SSH_PORT" -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes -o ConnectTimeout="$ct" \
        root@127.0.0.1 cat /proc/sys/kernel/random/boot_id 2>>"${TDIR:-$LOGS}/ssh-errors.txt"
}
# SSH answers within SECONDS: the boot ID on stdout.
probe_until() {
    local deadline=$((SECONDS + $1)) bid
    while ((SECONDS < deadline)); do
        vm_alive || return 1
        if bid=$(probe_ssh 10); then
            printf '%s\n' "$bid"
            return 0
        fi
        sleep 3
    done
    return 1
}
row() { printf '%s\n' "$1" >>"$ROWS"; log "$1"; }

# Fedora 45's qemu-kvm-core and edk2-ovmf (provision.sh's packages) and the derived guest.
build_images() {
    mkdir -p "$BUILD_DIR/qemu" "$BUILD_DIR/guest" "$QUALIFY_OUT/fw"
    cat >"$BUILD_DIR/qemu/Containerfile" <<'EOF'
ARG BASE
FROM ${BASE}
ARG EDK2_RPM
# bootc's /mnt points at a var/mnt it lacks: the runner's /mnt work directory is bound here.
RUN set -eux; \
    if [ -L /mnt ]; then rm /mnt; mkdir /mnt; fi; \
    dnf -y install qemu-kvm-core qemu-device-display-virtio-vga "$EDK2_RPM"; \
    dnf clean all; \
    rpm -q qemu-kvm-core qemu-system-x86-core qemu-device-display-virtio-vga edk2-ovmf
EOF
    cp "$REPRO_ROOT/image/system_files/usr/lib/bootc/kargs.d/10-apex.toml" "$BUILD_DIR/guest/"
    # apex-desktop's 90_apex.gschema.override, its only power key.
    printf '[org.gnome.settings-daemon.plugins.power]\npower-button-action='"'"'interactive'"'"'\n' \
        >"$BUILD_DIR/guest/90_apex-power.gschema.override"
    cat >"$BUILD_DIR/guest/Containerfile" <<'EOF'
ARG BASE
FROM ${BASE}
ARG KERNEL
COPY 10-apex.toml /usr/lib/bootc/kargs.d/10-apex.toml
COPY 90_apex-power.gschema.override /usr/share/glib-2.0/schemas/90_apex-power.gschema.override
RUN set -eux; \
    dnf -y install gdm gnome-shell gnome-session-wayland-session gnome-settings-daemon mesa-dri-drivers evtest; \
    if [ "$KERNEL" != base ]; then \
        kver="$KERNEL.x86_64"; \
        k="https://kojipkgs.fedoraproject.org/packages/kernel/${KERNEL%-*}/${KERNEL##*-}/x86_64"; \
        dnf -y install "$k/kernel-core-$kver.rpm" "$k/kernel-modules-core-$kver.rpm" "$k/kernel-modules-$kver.rpm"; \
        old=$(rpm -qa --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' 'kernel*' | \
            grep -E '^kernel(-core|-modules|-modules-core|-modules-extra)?-[0-9]' | grep -vF -- "-$kver" || true); \
        if [ -n "$old" ]; then rpm -e --nodeps $old; fi; \
        for d in /usr/lib/modules/*; do if [ "${d##*/}" != "$kver" ]; then rm -rf "$d"; fi; done; \
        dracut --no-hostonly --kver "$kver" --reproducible --zstd -v --add ostree -f "/usr/lib/modules/$kver/initramfs.img"; \
    fi; \
    glib-compile-schemas /usr/share/glib-2.0/schemas; \
    systemctl enable gdm.service; \
    systemctl set-default graphical.target; \
    dnf clean all; rm -rf /var/cache/libdnf5 /var/log/dnf5.log*; \
    rpm -q kernel-core gdm gnome-shell mutter gnome-settings-daemon; \
    test "$(ls /usr/lib/modules | wc -l)" = 1; \
    bootc container lint || echo "bootc container lint failed; not fatal for this diagnostic image"
EOF
    local edk2_rpm="$KOJI/edk2/${REPRO_EDK2%-*}/${REPRO_EDK2##*-}/noarch/edk2-ovmf-$REPRO_EDK2.noarch.rpm" qpid gpid=''
    group "podman build $QEMU_IMAGE (and $GUEST_IMAGE_BUILT) from $REPRO_BASE"
    as_root podman build --pull=never --build-arg "BASE=$REPRO_BASE" --build-arg "EDK2_RPM=$edk2_rpm" \
        -t "$QEMU_IMAGE" "$BUILD_DIR/qemu" >"$LOGS/build-qemu.log" 2>&1 &
    qpid=$!
    if [[ -z $REPRO_GUEST_IMAGE ]]; then
        as_root podman build --pull=never --build-arg "BASE=$REPRO_BASE" --build-arg "KERNEL=$REPRO_KERNEL" \
            -t "$GUEST_IMAGE_BUILT" "$BUILD_DIR/guest" >"$LOGS/build-guest.log" 2>&1 &
        gpid=$!
    fi
    wait "$qpid" || { tail -n 40 "$LOGS/build-qemu.log" >&2; die "the QEMU image did not build (logs/build-qemu.log)"; }
    if [[ -n $gpid ]]; then
        wait "$gpid" || { tail -n 60 "$LOGS/build-guest.log" >&2; die "the guest image did not build (logs/build-guest.log)"; }
    fi
    endgroup
    # The files /usr/share/OVMF/OVMF_CODE.fd and OVMF_VARS.fd point to on Fedora: find_ovmf's pick in the builder.
    as_root podman run --rm -v "$QUALIFY_OUT/fw:/out" "$QEMU_IMAGE" sh -c \
        'cp -L /usr/share/edk2/ovmf/OVMF_CODE.fd /usr/share/edk2/ovmf/OVMF_VARS.fd /out/ &&
         rpm -q edk2-ovmf qemu-kvm-core qemu-system-x86-core > /out/versions.txt &&
         qemu-system-x86_64 --version | head -n 1 >> /out/versions.txt'
    as_root chown -R "$(id -u):$(id -g)" "$QUALIFY_OUT/fw"
    export OVMF_CODE=$QUALIFY_OUT/fw/OVMF_CODE.fd OVMF_VARS=$QUALIFY_OUT/fw/OVMF_VARS.fd OVMF_FORMAT=raw
}

# Fedora's QEMU in the host's PID and network namespaces as the runner's uid, so the pidfile,
# kill -0, hostfwd, the QMP sockets and every path behave as qualify.sh's -daemonize expects.
install_qemu_shim() {
    mkdir -p "$QUALIFY_OUT/shim"
    cat >"$QUALIFY_OUT/shim/qemu-system-x86_64" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args=() pidfile='' socks=()
while (($#)); do
    case $1 in
        -daemonize) ;;
        -pidfile) pidfile=$2; args+=("$1" "$2"); shift ;;
        -qmp) s=${2#unix:}; socks+=("${s%%,*}"); args+=("$1" "$2"); shift ;;
        *) args+=("$1") ;;
    esac
    shift
done
opts=(--rm --privileged --network=host --pid=host --ipc=host --security-opt apparmor=unconfined
      --security-opt label=disable --user "$(id -u):$(id -g)" -e HOME=/tmp
      -v /dev/kvm:/dev/kvm -v "$QUALIFY_OUT:$QUALIFY_OUT")
if [[ -z $pidfile ]]; then exec sudo podman run "${opts[@]}" "$REPRO_QEMU_IMAGE" qemu-system-x86_64 "${args[@]}"; fi
rm -f "$pidfile"
cid=$(sudo podman run -d "${opts[@]}" "$REPRO_QEMU_IMAGE" sh -c 'exec qemu-system-x86_64 "$@" 2>>"$0"' \
    "$QUALIFY_OUT/logs/qemu.stderr.log" "${args[@]}")
for ((i = 0; i < 300; i++)); do
    ready=1
    [[ -s $pidfile ]] || ready=
    for s in "${socks[@]}"; do [[ -S $s ]] || ready=; done
    [[ -z $ready ]] || exit 0
    sudo podman container exists "$cid" || break
    sleep 0.2
done
echo "qemu (container $cid) did not start; see logs/qemu.stderr.log" >&2
tail -n 20 "$QUALIFY_OUT/logs/qemu.stderr.log" >&2 || true
exit 1
EOF
    chmod +x "$QUALIFY_OUT/shim/qemu-system-x86_64"
    export REPRO_QEMU_IMAGE=$QEMU_IMAGE PATH=$QUALIFY_OUT/shim:$PATH
}

# Only for the -stdvga control: the same start_vm with std VGA (bochs-drm) for virtio-vga.
define_stdvga() {
    local src
    src=$(declare -f start_vm | sed -e '1s/^start_vm /start_vm_stdvga /' -e 's/-device virtio-vga /-device VGA /')
    [[ $src == *'-device VGA '* ]] || return 1
    eval "$src"
}

kill_vm() {
    vm_alive || { VM_NAME=; return 0; }
    local pid i
    pid=$(cat "$QUALIFY_OUT/$VM_NAME.pid")
    kill "$pid" 2>/dev/null || true
    for ((i = 0; i < 15; i++)); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
    done
    kill -9 "$pid" 2>/dev/null || true
    VM_NAME=
}

PUBLISHED=0 SETUP_S=0 BOOTN=0 VM_VGA='' VM_DIRTY=0 S3_IN_BOOT=0 BOOT_ID='' KALLSYMS='' OVMF_LOG=/dev/null TRIAL_N=0 TDIR='' TRIAL_ID=''
declare -A META=() VERDICT=()

boot_vm() {
    local vga=${1:-virtio} log
    kill_vm
    BOOTN=$((BOOTN + 1))
    log=repro-boot$BOOTN
    rm -f "$EVENTS_SOCK"
    local -a extra=(-qmp "unix:$EVENTS_SOCK,server=on,wait=off")
    OVMF_LOG=/dev/null
    if [[ $REPRO_DEBUGCON == 1 ]]; then
        # Fedora's OVMF is a DEBUG build (edk2-build.py: tgts defaults to DEBUG): its PEI log
        # goes to port 0x402 when a debugcon is there, S3 resume included.
        OVMF_LOG=$LOGS/$log.ovmf.log
        extra+=(-debugcon "file:$OVMF_LOG" -global isa-debugcon.iobase=0x402)
    fi
    mark "boot $BOOTN ($vga VGA): start_vm repro $log ${extra[*]}"
    if [[ $vga == std ]]; then start_vm_stdvga repro "$log" "${extra[@]}"; else start_vm repro "$log" "${extra[@]}"; fi
    VM_VGA=$vga
    (wait_ssh) || { mark "boot $BOOTN: no SSH"; return 1; }
    S3_IN_BOOT=0
    BOOT_ID=$(vm_ssh cat /proc/sys/kernel/random/boot_id) || return 1
    vm_ssh bash -s <<<"$GUEST_IDENTITY" >"$LOGS/$log.identity.txt" 2>&1 || true
    KALLSYMS=$LOGS/$log.kallsyms.gz
    vm_ssh 'sysctl -qw kernel.kptr_restrict=1; cat /proc/kallsyms' 2>/dev/null | gzip >"$KALLSYMS" || true
    mark "boot $BOOTN: SSH up, boot_id $BOOT_ID, $(head -n 1 "$LOGS/$log.identity.txt")"
}

gnome_ready() {
    local found
    found=$(active_session user "$TEST_USER") || return 1
    read -r SESSION_ID SESSION_UID SESSION_TYPE <<<"$found"
    shell_answers "$SESSION_UID" && vm_ssh "pgrep -u $SESSION_UID -x gsd-media-keys >/dev/null"
}

headless_ready() {
    vm_ssh '! pgrep -x gnome-shell >/dev/null && ! loginctl list-sessions --no-legend | grep -q seat0'
}

ensure_mode() {
    local want=$1 deadline restarted=
    if [[ $want == gnome ]]; then
        gnome_ready && return 0
        vm_ssh 'systemctl is-active -q gdm.service || systemctl isolate graphical.target' || true
        deadline=$((SECONDS + 240))
        until gnome_ready; do
            ((SECONDS < deadline)) || return 1
            # Autologin happens when gdm starts; a greeter shown before custom.conf needs a restart.
            if [[ -z $restarted ]] && ((deadline - SECONDS < 180)); then
                vm_ssh 'systemctl restart gdm.service' || true
                restarted=1
            fi
            sleep "$QUALIFY_POLL"
        done
        sleep 10 # gsd and the shell finish starting
    else
        vm_ssh 'systemctl isolate multi-user.target' || true
        deadline=$((SECONDS + 90))
        until headless_ready; do
            ((SECONDS < deadline)) || return 1
            sleep 3
        done
    fi
}

# The G4 row's state at suspend: locked, and the screen off (Apex's lock blanks at once; run 17's
# lock screendump showed 'Display output is not active.').
lock_and_blank() {
    vm_ssh "loginctl lock-session $SESSION_ID" || return 1
    local deadline=$((SECONDS + QUALIFY_LOCK_TIMEOUT))
    until lockedhint_and_screensaver_agree "$SESSION_ID" "$SESSION_UID" yes; do
        ((SECONDS < deadline)) || return 1
        sleep "$QUALIFY_POLL"
    done
    display_power 3 || META[blank]=failed
    sleep 2
    screendump "$TRIAL_ID-locked"
}

snapshot() { vm_ssh bash -s <<<"$GUEST_SNAPSHOT" >"$TDIR/$1.txt" 2>&1; }

post_ok() {
    local mode=$1 since=$2 base=$3 deadline
    snapshot post || true
    vm_ssh "journalctl -b --since @$((since - 1)) -o short-monotonic --no-pager" >"$TDIR/journal.txt" 2>&1 || true
    vm_ssh "journalctl -k -b --since @$((since - 1)) -o short-monotonic --no-pager" >"$TDIR/kernel.txt" 2>&1 || true
    [[ $mode == gnome ]] || return 0
    deadline=$((SECONDS + 30))
    until still_locked; do
        ((SECONDS < deadline)) || break
        sleep 3
    done
    if still_locked; then META[locked_after]=yes; else META[locked_after]=no; fi
    META[psm_after]=$(user_run "$SESSION_UID" busctl --user get-property org.gnome.Mutter.DisplayConfig \
        /org/gnome/Mutter/DisplayConfig org.gnome.Mutter.DisplayConfig PowerSaveMode 2>&1 | tr '\n' ' ')
    screendump "$TRIAL_ID-resumed"
    if [[ ${META[locked_after]} == yes ]]; then
        # The rest of the G4 row: Enter until the prompt asks, then the password over QMP.
        (type_password_after_enter "$TRIAL_ID-unlock" "the lock screen after resume" "$base") >>"$TDIR/unlock.txt" 2>&1 || true
        deadline=$((SECONDS + QUALIFY_LOCK_TIMEOUT))
        until lockedhint_and_screensaver_agree "$SESSION_ID" "$SESSION_UID" no; do
            ((SECONDS < deadline)) || break
            sleep 3
        done
        if lockedhint_and_screensaver_agree "$SESSION_ID" "$SESSION_UID" no; then
            META[unlock]=password
        else
            vm_ssh "loginctl unlock-session $SESSION_ID" || true
            sleep 5
            if lockedhint_and_screensaver_agree "$SESSION_ID" "$SESSION_UID" no; then META[unlock]=loginctl-only; else META[unlock]=failed; fi
        fi
    fi
    if shell_answers "$SESSION_UID"; then META[shell]=answers; else META[shell]=silent; fi
    display_power 0 || true
    screendump "$TRIAL_ID-unlocked"
    [[ ${META[shell]} == answers && ${META[unlock]:-} != failed ]] || VM_DIRTY=1
}

diagnose() {
    mark "no SSH ${REPRO_WAKE_WINDOW}s after the wake: QMP and HMP diagnostics"
    # shellcheck disable=SC2016 # $pc is HMP's, not the shell's
    {
        printf 'query-status %s\n' "$(qmpq '{"execute":"query-status"}' 2>&1)"
        printf '\n== info status\n%s\n' "$(hmp 'info status' 2>&1)"
        printf '\n== info cpus\n%s\n' "$(hmp 'info cpus' 2>&1)"
        printf '\n== x/6i $pc (cpu 0)\n%s\n' "$(hmp 'x/6i $pc' 2>&1)"
    } >"$TDIR/hmp.txt"
    local i off
    off=$(fsize "$VM_SERIAL")
    qmp "$(key_press alt sysrq w)" || true
    sleep 5
    tail -c +$((off + 1)) "$VM_SERIAL" | tr -d '\r' >"$TDIR/sysrq-w.txt" 2>/dev/null || true
    for i in 1 2 3; do
        hmp 'info registers -a' >"$TDIR/regs-$i.txt" 2>&1 || true
        sleep 1
    done
    # slirp's sockets while an SSH attempt is in flight: SYN_SENT means the guest's TCP never
    # answered; ESTABLISHED with no banner means the kernel answers and sshd does not.
    (probe_ssh 10 >/dev/null 2>&1 &)
    sleep 3
    hmp 'info usernet' >"$TDIR/usernet.txt" 2>&1 || true
    qmpq '{"execute":"query-rx-filter"}' >"$TDIR/rx-filter.json" 2>&1 || true
    screendump "$TRIAL_ID-timeout"
    nudge_pointer >/dev/null 2>&1 || true
    sleep "$QUALIFY_POLL"
    screendump "$TRIAL_ID-timeout-nudged"
}

recover() {
    local mode=$1 since=$2 base=$3 wake_off=$4 st bid off deadline
    st=$(vm_run_state 2>/dev/null || echo '?')
    META[status_at_timeout]=${st:-?}
    if [[ $st == suspended ]]; then
        mark "recovery: a second system_wakeup"
        qmp '{"execute":"system_wakeup"}' || true
        if bid=$(probe_until 45); then
            META[ssh]=after-second-wakeup META[t_ssh_ok]=$(now) META[boot_id_after]=$bid
            post_ok "$mode" "$since" "$base"
            return 0
        fi
    fi
    if tail -c +$((wake_off + 1)) "$VM_SERIAL" | tr -d '\r' | grep -aq '^HB '; then
        mark "recovery: userspace runs (HB lines): one SSH attempt with ConnectTimeout=60"
        if bid=$(probe_ssh 60); then
            META[ssh]=late META[t_ssh_ok]=$(now) META[boot_id_after]=$bid
            post_ok "$mode" "$since" "$base"
            return 0
        fi
    fi
    mark "recovery: QMP system_powerdown, a liveness probe through the ACPI power button"
    off=$(fsize "$VM_SERIAL")
    qmp '{"execute":"system_powerdown"}' || true
    deadline=$((SECONDS + 30))
    while vm_alive && ((SECONDS < deadline)); do sleep 3; done
    if vm_alive; then META[powerdown_exit]=no; else META[powerdown_exit]=yes; fi
    tail -c +$((off + 1)) "$VM_SERIAL" >"$TDIR/serial-powerdown.txt" 2>/dev/null || true
}

finish_trial() {
    local k
    [[ -z ${1:-} ]] || META[verdict_override]=$1
    for k in "${!META[@]}"; do printf '%s\t%s\n' "$k" "${META[$k]}"; done | sort >"$TDIR/meta.tsv"
    if [[ -n ${1:-} ]]; then
        VERDICT[${META[name]}]=$1
        row "| $TRIAL_ID | b$BOOTN | ${META[wake]:-} | - | - | - | - | - | - | - | - | **$1** |"
        return 0
    fi
    row "$(python3 -I -c "$CLASSIFY" "$TDIR" 2>>"$TDIR/classify.err" || echo "| $TRIAL_ID | classifier failed (classify.err) |")"
    VERDICT[${META[name]}]=$(jq -r '.verdict // "?"' "$TDIR/verdict.json" 2>/dev/null || echo '?')
}

# MODE-WAKE[-OPT...]: G locked GNOME or H none; sw (QMP system_wakeup), rtc or s2idle (send-key);
# OPT nothing (gsd's power-button-action), stdvga (VGA, not virtio-vga), bare, rN (a repeat).
run_trial() {
    local name=$1 m wake opts mode vga=virtio inst=full pba=interactive need
    IFS=- read -r m wake opts <<<"$name"
    case $m in G) mode=gnome ;; H) mode=headless ;; *) warn "unknown trial $name"; return 0 ;; esac
    [[ $wake == sw || $wake == rtc || $wake == s2idle ]] || { warn "unknown wake in trial $name"; return 0; }
    [[ -$opts- != *-stdvga-* ]] || vga=std
    [[ -$opts- != *-bare-* ]] || inst=bare
    [[ -$opts- != *-nothing-* ]] || pba=nothing
    TRIAL_N=$((TRIAL_N + 1))
    TRIAL_ID=$(printf 't%02d-%s' "$TRIAL_N" "$name")
    TDIR=$TRIALS_DIR/$TRIAL_ID
    mkdir -p "$TDIR"
    META=([trial]=$TRIAL_ID [name]=$name [mode]=$mode [wake]=$wake [inst]=$inst [pba]=$pba [vga]=$vga
        [qmp_log]=$QMP_LOG [t_start]=$(now))
    # A failing trial: lock and suspend 20 s, the window, diagnostics 25 s, recovery up to 105 s,
    # the kill 15 s; a boot first (with the GNOME autologin) about 150 s more.
    need=$((REPRO_WAKE_WINDOW + 200))
    if ! vm_alive || [[ $VM_VGA != "$vga" || $VM_DIRTY == 1 ]]; then need=$((need + 150)); fi
    if (($(left) < need)); then
        mark "skipped: $(left)s left, a failing trial may need ${need}s"
        finish_trial SKIP-BUDGET
        return 0
    fi
    if ! vm_alive || [[ $VM_VGA != "$vga" || $VM_DIRTY == 1 ]]; then
        boot_vm "$vga" || { finish_trial BOOT-FAILED; VM_DIRTY=1; return 0; }
        VM_DIRTY=0
    fi
    if ! ensure_mode "$mode"; then
        mark "mode $mode not reached"
        vm_ssh 'loginctl list-sessions; systemctl --no-pager status gdm.service; dmesg | grep -iE "drm|bochs|virtio_gpu"
            journalctl -b --no-pager -o short-monotonic -u gdm.service _COMM=gnome-shell _COMM=gdm-session-wor _COMM=gnome-session-b' \
            >"$TDIR/mode-failed.txt" 2>&1 || true
        finish_trial MODE-FAILED
        VM_DIRTY=1
        return 0
    fi
    S3_IN_BOOT=$((S3_IN_BOOT + 1))
    META[boot]=$BOOTN META[s3_in_boot]=$S3_IN_BOOT META[kallsyms]=$KALLSYMS META[boot_id_before]=$BOOT_ID
    local since base=0 ser_off wake_ser wake_ovmf win_ser deadline bid ok=
    if [[ $mode == gnome ]]; then
        if [[ $pba == nothing ]]; then
            user_run "$SESSION_UID" gsettings set org.gnome.settings-daemon.plugins.power power-button-action "\"'nothing'\"" || true
        else
            user_run "$SESSION_UID" gsettings reset org.gnome.settings-daemon.plugins.power power-button-action || true
        fi
        META[pba_now]=$(user_run "$SESSION_UID" gsettings get org.gnome.settings-daemon.plugins.power power-button-action 2>&1)
        META[session]="$SESSION_ID uid $SESSION_UID $SESSION_TYPE"
        META[apex_layer]=$(vm_ssh 'rpm -q apex-desktop >/dev/null 2>&1 && echo yes || echo no' 2>/dev/null || echo '?')
        base=$(password_conversations)
    fi
    vm_ssh bash -s -- "$inst" "$REPRO_PRINT_TIMES" <<<"$GUEST_INSTRUMENT" >"$TDIR/instrument.txt" 2>&1 || true
    snapshot pre || true
    since=$(vm_ssh 'date +%s') || since=0
    if [[ $mode == gnome ]]; then
        lock_and_blank || { mark "the session did not lock"; META[lock]=failed; }
    fi
    # shellcheck disable=SC2016 # expanded in the guest; mem_sleep stays as the last trial left it
    if [[ $wake == s2idle ]]; then
        vm_ssh 'echo s2idle > /sys/power/mem_sleep; w=/sys/bus/serio/devices/serio0/power/wakeup;
            [ -e $w ] && echo enabled > $w; echo "mem_sleep $(cat /sys/power/mem_sleep); serio0 $(cat $w 2>/dev/null || echo none)"' \
            >"$TDIR/mem_sleep.txt" 2>&1 || META[mem_sleep]=failed
    else
        vm_ssh 'echo deep > /sys/power/mem_sleep; echo "mem_sleep $(cat /sys/power/mem_sleep)"' >"$TDIR/mem_sleep.txt" 2>&1 ||
            META[mem_sleep]=failed
    fi
    if [[ $wake == rtc ]]; then
        vm_ssh "echo enabled > /sys/class/rtc/rtc0/device/power/wakeup; echo 0 > /sys/class/rtc/rtc0/wakealarm;
            echo +$REPRO_RTC_SECS > /sys/class/rtc/rtc0/wakealarm; cat /sys/class/rtc/rtc0/wakealarm" >"$TDIR/rtc.txt" 2>&1 ||
            META[rtc_arm]=failed
    fi
    ser_off=$(fsize "$VM_SERIAL")
    META[t_suspend_req]=$(now)
    mark "systemd-run --on-active=2 systemctl suspend (S3 #$S3_IN_BOOT of boot $BOOTN)"
    vm_ssh 'systemd-run --quiet --on-active=2 systemctl suspend' || META[suspend_req]=failed
    # qualify.sh's wait: query-status every QUALIFY_POLL until 'suspended', QUALIFY_LOCK_TIMEOUT at most.
    # s2idle never leaves QEMU's 'running': the console's entry line, then 5 s for the freeze.
    local entered=''
    deadline=$((SECONDS + QUALIFY_LOCK_TIMEOUT))
    if [[ $wake == s2idle ]]; then
        until tail -c +$((ser_off + 1)) "$VM_SERIAL" 2>/dev/null | grep -q 'PM: suspend entry (s2idle)'; do
            if ((SECONDS >= deadline)) || ! vm_alive; then break; fi
            sleep 1
        done
        if tail -c +$((ser_off + 1)) "$VM_SERIAL" 2>/dev/null | grep -q 'PM: suspend entry (s2idle)'; then entered=1; sleep 5; fi
    else
        until [[ $(vm_run_state 2>/dev/null) == suspended ]]; do
            if ((SECONDS >= deadline)) || ! vm_alive; then break; fi
            sleep "$QUALIFY_POLL"
        done
        [[ $(vm_run_state 2>/dev/null) != suspended ]] || entered=1
    fi
    wake_ser=$(fsize "$VM_SERIAL")
    wake_ovmf=$(fsize "$OVMF_LOG")
    if [[ -n $entered ]]; then
        META[t_suspended_seen]=$(now)
        screendump "$TRIAL_ID-suspended"
        if [[ $wake == sw ]]; then
            META[t_wake_sent]=$(now)
            mark "QMP system_wakeup"
            qmp '{"execute":"system_wakeup"}' || META[wake_cmd]=error
        elif [[ $wake == s2idle ]]; then
            META[t_wake_sent]=$(now)
            mark "QMP send-key shift (the i8042 keyboard, serio0)"
            qmp "$(key_press shift)" || META[wake_cmd]=error
        else
            mark "waiting up to $((REPRO_RTC_SECS + 30))s for the RTC alarm"
            deadline=$((SECONDS + REPRO_RTC_SECS + 30))
            while [[ $(vm_run_state 2>/dev/null) == suspended ]] && ((SECONDS < deadline)); do sleep 1; done
            if [[ $(vm_run_state 2>/dev/null) == suspended ]]; then
                META[rtc_woke]=no META[t_wake_sent]=$(now)
                mark "no RTC wake: QMP system_wakeup instead"
                qmp '{"execute":"system_wakeup"}' || META[wake_cmd]=error
            else
                META[rtc_woke]=yes
            fi
        fi
        sleep 2
        screendump "$TRIAL_ID-wake+2s"
        local t0=$SECONDS shot15='' shot60=''
        while ((SECONDS - t0 < REPRO_WAKE_WINDOW)); do
            if ! vm_alive; then META[qemu_exited]=yes; break; fi
            if [[ -z $shot15 ]] && ((SECONDS - t0 >= 15)); then screendump "$TRIAL_ID-wake+15s"; shot15=1; fi
            if [[ -z $shot60 ]] && ((SECONDS - t0 >= 60)); then screendump "$TRIAL_ID-wake+60s"; shot60=1; fi
            if bid=$(probe_ssh 10); then ok=1; break; fi
            sleep 3
        done
    else
        mark "never suspended (${wake}) within ${QUALIFY_LOCK_TIMEOUT}s"
        bid=$(probe_until 30) && ok=1
    fi
    META[t_window_end]=$(now)
    win_ser=$(fsize "$VM_SERIAL")
    if [[ -n $ok ]]; then
        META[ssh]=ok META[t_ssh_ok]=$(now) META[boot_id_after]=$bid
        mark "SSH answers; boot_id $bid"
        post_ok "$mode" "$since" "$base"
        [[ $bid == "$BOOT_ID" ]] || { BOOT_ID=$bid; VM_DIRTY=1; }
    elif [[ ${META[qemu_exited]:-} == yes ]]; then
        mark "QEMU exited after the wake"
        VM_NAME=
    else
        META[ssh]=none
        diagnose
        recover "$mode" "$since" "$base" "$wake_ser"
        kill_vm
        VM_DIRTY=1
    fi
    head -c "$wake_ser" "$VM_SERIAL" | tail -c +$((ser_off + 1)) >"$TDIR/serial-pre.txt" 2>/dev/null || true
    head -c "$win_ser" "$VM_SERIAL" | tail -c +$((wake_ser + 1)) >"$TDIR/serial-post.txt" 2>/dev/null || true
    tail -c +$((win_ser + 1)) "$VM_SERIAL" >"$TDIR/serial-recovery.txt" 2>/dev/null || true
    tail -c +$((wake_ovmf + 1)) "$OVMF_LOG" >"$TDIR/ovmf-post.txt" 2>/dev/null || true
    finish_trial
    mark "verdict ${VERDICT[$name]:-?}"
}

auto_extras() {
    local -a x=()
    case ${VERDICT[G-sw]:-} in
        '' | SKIP-* | BOOT-FAILED | MODE-FAILED) ;;
        PASS)
            # Instrumentation that slows the console may hide a race; repeats measure the rate.
            x=(G-sw-bare G-sw-r2 G-sw-r3 G-sw-r4)
            ;;
        *)
            [[ ${VERDICT[G-rtc]:-} != PASS ]] || x+=(G-sw-nothing)
            [[ ${VERDICT[H-sw]:-} != PASS ]] || x+=(G-sw-stdvga)
            x+=(G-sw-r2)
            ;;
    esac
    printf '%s\n' "${x[@]}"
}

repro_cleanup() {
    local rc=$?
    TRIAL_ID=
    publish || true
    kill_vm || true
    touch "$WATCH_STOP"
    [[ -z ${WATCH_PID:-} ]] || wait "$WATCH_PID" 2>/dev/null || true
    unmount_all
    exit "$rc"
}

env_report() {
    local cpu nested
    cpu=$(lscpu | sed -n 's/^Model name: *//p' | head -n 1 || true)
    # One of the two never exists: under pipefail, cat's 1 would end the run in silence.
    nested=$(cat /sys/module/kvm_intel/parameters/nested /sys/module/kvm_amd/parameters/nested 2>/dev/null | head -n 1 || true)
    {
        printf 'host kernel %s; CPU %s; nested %s; %s vCPUs, %s RAM\n' "$(uname -r)" "$cpu" "${nested:-?}" "$(nproc)" \
            "$(free -g | awk '/^Mem:/ {print $2 "G"}')"
        printf 'QEMU (%s): %s\n' "$REPRO_QEMU" "$(qemu-system-x86_64 --version 2>/dev/null | head -n 1)"
        printf 'firmware: %s\n' "$(tr '\n' ' ' <"$QUALIFY_OUT/fw/versions.txt" 2>/dev/null)"
        printf 'base %s; guest %s; kernel %s\n' "$REPRO_BASE" "${REPRO_GUEST_IMAGE:-$GUEST_IMAGE_BUILT}" "$REPRO_KERNEL"
    } >"$LOGS/env.txt"
}

repro_main() {
    local t_setup=$SECONDS name img
    mkdir -p "$LOGS" "$TRIALS_DIR" "$QUALIFY_OUT/qmp"
    : >"$ROWS"
    : >"$QUALIFY_OUT/results.md"
    trap repro_cleanup EXIT
    trap 'exit 143' TERM INT
    rm -f "$WATCH_STOP"
    python3 -I -c "$QMP_WATCH" "$EVENTS_SOCK" "$QMP_LOG" "$WATCH_STOP" &
    WATCH_PID=$!

    mark "pull $REPRO_BASE"
    retry 5 15 as_root podman pull --quiet "$REPRO_BASE" >/dev/null
    build_images
    if [[ $REPRO_QEMU == fedora ]]; then install_qemu_shim; fi
    define_stdvga || warn "start_vm has no '-device virtio-vga ': the stdvga control is off"
    env_report
    img=$GUEST_IMAGE_BUILT
    if [[ -n $REPRO_GUEST_IMAGE ]]; then
        img=$REPRO_GUEST_IMAGE
        podman_pull "$img"
    fi
    ensure_key
    install_disk repro "$img" "$img"
    boot_vm virtio || die "the first boot reached no SSH (logs/repro-boot1.serial.log)"
    TEST_PASSWORD=$(openssl rand -hex 12)
    vm_ssh bash -s -- "$TEST_USER" <<<"$GUEST_PREP" || die "cannot prepare $TEST_USER and GDM's autologin"
    vm_ssh chpasswd <<<"$TEST_USER:$TEST_PASSWORD" || die "chpasswd for $TEST_USER failed"
    vm_ssh 'systemctl restart gdm.service' || warn "cannot restart gdm for the autologin"
    SETUP_S=$((SECONDS - t_setup))
    mark "setup took ${SETUP_S}s; $(left)s left"

    set +e
    for name in $REPRO_TRIALS; do run_trial "$name"; done
    if [[ $REPRO_EXTRAS == auto ]]; then
        for name in $(auto_extras); do run_trial "$name"; done
    fi
    TRIAL_ID=
    publish
    return 0
}

publish() {
    [[ $PUBLISHED == 0 ]] || return 0
    PUBLISHED=1
    summary "### G4 local-lock-suspend replay (W17b): $(sed -n 1p "$LOGS/env.txt" 2>/dev/null)" "" \
        "$(sed -n '2,$p' "$LOGS/env.txt" 2>/dev/null | sed 's/$/  /')" \
        "guest: $(head -n 1 "$LOGS/repro-boot1.identity.txt" 2>/dev/null); setup ${SETUP_S}s, whole run ${SECONDS}s" "" \
        "G trials lock stock GNOME (fedora-bootc + gdm, no apex-desktop): 'Apex: lock' does not apply, so they test GNOME's lock, the GPU and the suspend path, not the Apex layer; REPRO_GUEST_IMAGE can name an apex-testing digest." "" \
        "| Trial | Boot/S3 | Wake | To 'suspended' | SSH after wake | QMP after wake (state; changes; events) | OVMF after wake (debugcon) | Kernel console after wake | Userspace taps after wake | Session after | S3 clock | Verdict |" \
        "|---|---|---|---|---|---|---|---|---|---|---|---|" \
        "$(cat "$ROWS")" "" \
        "Verdicts: PASS; PASS-SLOW (H4); RESUSPENDED (A, H1a); POWERED-OFF (C, H1, R0: see KEY_POWER and 'Power key pressed'); COLD-BOOT (D);" \
        "STUCK-FIRMWARE[-EARLY] (H1b in OVMF); STUCK-EARLY-KERNEL (H1b, waking vector to 'Low-level resume complete');" \
        "STUCK-DEVICE-RESUME (H2, E: 'open' names the callback); STUCK-POST-SUSPEND (tasks thawed, no 'PM: suspend exit': sysrq-w.txt);" \
        "RESUMED-NO-NET, RESUMED-NO-SSH (H3, E); USERSPACE-STALLED; SHELL-SILENT-AFTER-RESUME (the shell answers no D-Bus, so 'unlocked' is unknown);" \
        "SESSION-BROKEN (H-virtio-gpu-no-restore, H5); UNLOCKED-AFTER-RESUME; MODE-FAILED (mode-failed.txt); UNREACHABLE-BARE (no console instrumentation); NO-SUSPEND." \
        "Logs: artifact g4-suspend-repro-logs (trials/<id>/: meta.tsv, verdict.json, serial-{pre,post,recovery}.txt, ovmf-post.txt, regs-*.txt, journal.txt; qmp-events.jsonl; *.png)."
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    repro_main "$@"
fi
