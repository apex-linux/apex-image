#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Against fakes only: no network, no root, no KVM.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require jq awk sed mktemp

FAILS=0
TESTS=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass() { TESTS=$((TESTS + 1)); }
flunk() {
    TESTS=$((TESTS + 1))
    FAILS=$((FAILS + 1))
    printf 'FAIL: %s\n' "$*" >&2
}

check() {
    local name=$1 expected=$2 actual=$3
    if [[ $expected == "$actual" ]]; then pass; else flunk "$name: expected '$expected', got '$actual'"; fi
}

check_true() {
    local name=$1
    shift
    if (set +e; "$@") >/dev/null 2>&1; then pass; else flunk "$name: expected success"; fi
}
check_false() {
    local name=$1
    shift
    if (set +e; "$@") >/dev/null 2>&1; then flunk "$name: expected failure"; else pass; fi
}

# --- versions --------------------------------------------------------------------------
check_true "valid version" version_valid 45.20260924.117
check_false "version without run" version_valid 45.20260924
check_false "version with short date" version_valid 45.2026092.1
check_false "version with letters" version_valid 45.20260924.1a
check_true "run number is numeric, not lexical" version_gt 45.20260924.10 45.20260924.9
check_true "date beats run" version_gt 45.20260925.1 45.20260924.999
check_true "fedora major beats date" version_gt 46.20260101.1 45.20261231.9
check_false "equal is not greater" version_gt 45.20260924.117 45.20260924.117
check_false "older is not greater" version_gt 45.20260923.500 45.20260924.1
check_true "leading zeros are decimal" version_gt 45.20260924.010 45.20260924.9
check_false "invalid operand dies" version_gt 45.20260924.1 garbage

# --- digests and tags ------------------------------------------------------------------
check_true "digest" is_digest "sha256:$(printf '%064d' 0)"
check_false "short digest" is_digest sha256:abc
check_false "uppercase digest" is_digest "sha256:$(printf 'A%.0s' {1..64})"

# --- Containerfile parsing ---------------------------------------------------------------
cat >"$TMP/Containerfile" <<'EOF'
ARG FEDORA=45
ARG BASE=registry.fedoraproject.org/fedora-bootc@sha256:5225b8afb65136bcf6131eb2b02ef7923a64e37264e5e0fdda47dfeef51851c1
ARG GA_REACHED="0"
ARG EMPTY=
ARG COMPOSE=build-rootfs
FROM registry.fedoraproject.org/fedora:${FEDORA} AS repos
FROM ${BASE} AS builder
FROM scratch AS rootfs-build-rootfs
COPY --from=builder /target-rootfs/ /
FROM --platform=linux/amd64 $BASE AS rootfs-dnf
FROM rootfs-${COMPOSE} AS final
FROM ${UNKNOWN}
EOF
check "ARG with default" "registry.fedoraproject.org/fedora-bootc@sha256:5225b8afb65136bcf6131eb2b02ef7923a64e37264e5e0fdda47dfeef51851c1" \
    "$(containerfile_arg BASE "$TMP/Containerfile")"
check "ARG quotes removed" 0 "$(containerfile_arg GA_REACHED "$TMP/Containerfile")"
check "ARG empty" "" "$(containerfile_arg EMPTY "$TMP/Containerfile")"
check "ARG missing" "" "$(containerfile_arg NOPE "$TMP/Containerfile")"
check "FROM images (stages, scratch and unresolved ARGs skipped)" \
    "registry.fedoraproject.org/fedora-bootc@sha256:5225b8afb65136bcf6131eb2b02ef7923a64e37264e5e0fdda47dfeef51851c1
registry.fedoraproject.org/fedora:45" \
    "$(containerfile_from_images "$TMP/Containerfile")"
check "FROM images with build-arg overrides" "example.org/base:1
registry.fedoraproject.org/fedora:46" \
    "$(containerfile_from_images "$TMP/Containerfile" BASE=example.org/base:1 FEDORA=46 COMPOSE=dnf)"

is_empty_or_csv_list() { [[ $1 =~ ^([A-Za-z0-9._+-]+(,[A-Za-z0-9._+-]+)*)?$ ]]; }
if [[ -f $APEX_TESTING_ALLOWLIST ]]; then
    check_true "includepkgs has no comments or blanks" is_empty_or_csv_list "$(testing_includepkgs)"
fi

# --- policy transforms -----------------------------------------------------------------
policy='{"default":[{"type":"reject"}],"transports":{"docker":{
  "ghcr.io/apex-linux/apex":[{"type":"sigstoreSigned","keyPaths":["/usr/share/apex/keys/release.pub","/usr/share/apex/keys/release-backup.pub"],"signedIdentity":{"type":"matchRepository"}}],
  "ghcr.io/apex-linux/apex-testing":[{"type":"sigstoreSigned","keyPath":"/usr/share/apex/keys/ci.pub","signedIdentity":{"type":"matchRepository"}}],
  "example.com/data":[{"type":"sigstoreSigned","keyData":"AAAA","signedIdentity":{"type":"matchRepository"}}]}}}'
rooted=$(policy_key_root /repo/image/system_files <<<"$policy")
check "keyPaths rooted" '["/repo/image/system_files/usr/share/apex/keys/release.pub","/repo/image/system_files/usr/share/apex/keys/release-backup.pub"]' \
    "$(jq -c '.transports.docker["ghcr.io/apex-linux/apex"][0].keyPaths' <<<"$rooted")"
check "keyPath rooted" '/repo/image/system_files/usr/share/apex/keys/ci.pub' \
    "$(jq -r '.transports.docker["ghcr.io/apex-linux/apex-testing"][0].keyPath' <<<"$rooted")"
check "keyData untouched" AAAA "$(jq -r '.transports.docker["example.com/data"][0].keyData' <<<"$rooted")"
check_true "rooted policy still rejects by default" policy_rejects_by_default <<<"$rooted"

wrong=$(policy_single_key /var/tmp/wrong.pub <<<"$policy")
check "every sigstoreSigned trusts only the wrong key" '["/var/tmp/wrong.pub"]' \
    "$(jq -c '[.. | objects | select(.type? == "sigstoreSigned") | (.keyPath // "MISSING")] | unique' <<<"$wrong")"
check "no other key material left" 0 \
    "$(jq '[.. | objects | select(has("keyPaths") or has("keyData") or has("keyDatas"))] | length' <<<"$wrong")"
check_true "wrong-key policy still rejects by default" policy_rejects_by_default <<<"$wrong"
check_false "accept-anything default is refused" policy_rejects_by_default <<<'{"default":[{"type":"insecureAcceptAnything"}]}'
check_false "reject plus more is refused" policy_rejects_by_default <<<'{"default":[{"type":"reject"},{"type":"insecureAcceptAnything"}]}'

committed="$APEX_ROOT/image/system_files/usr/share/apex/containers/policy.json"
if [[ -f $committed ]]; then
    check_true "committed policy rejects by default" policy_rejects_by_default <"$committed"
    absent_keys=$(policy_key_root "$APEX_ROOT/image/system_files" <"$committed" |
        jq -r '[.. | objects | (.keyPath // empty), (.keyPaths // [] | .[])] | .[]' |
        while IFS= read -r k; do [[ -f $k ]] || printf '%s ' "$k"; done)
    check "committed policy keys exist in the checkout" "" "$absent_keys"
fi

# --- trust mapping: policy.json and image/checks/keys.sh agree exactly ---------------------
# Trust changes only in one reviewed change of this, keys.sh's TRUST_MAP and policy.json.
EXPECTED_TRUST_MAP=$'ghcr.io/apex-linux/apex\t/usr/share/apex/keys/release-backup.pub
ghcr.io/apex-linux/apex\t/usr/share/apex/keys/release.pub
ghcr.io/apex-linux/apex-testing\t/usr/share/apex/keys/ci.pub'
keys_sh="$APEX_ROOT/image/checks/keys.sh"
if [[ -f $keys_sh ]]; then
    keys_map=$(sed -n "/^TRUST_MAP='/,/'\$/p" "$keys_sh" | sed -e "s/^TRUST_MAP='//" -e "s/'\$//" |
        LC_ALL=C sort)
    check "image/checks/keys.sh TRUST_MAP is the ADR 0012 mapping" "$EXPECTED_TRUST_MAP" "$keys_map"
fi
if [[ -f $committed ]]; then
    policy_map=$(policy_trust_map <"$committed" 2>&1) || true
    check "the committed policy.json trusts exactly the ADR 0012 mapping" "$EXPECTED_TRUST_MAP" "$policy_map"
fi
check "policy_trust_map of the fixture policy without its extra scope" "$EXPECTED_TRUST_MAP" \
    "$(jq 'del(.transports.docker["example.com/data"])' <<<"$policy" | policy_trust_map)"
check "key order in keyPaths does not matter" "$EXPECTED_TRUST_MAP" \
    "$(jq 'del(.transports.docker["example.com/data"])
        | .transports.docker["ghcr.io/apex-linux/apex"][0].keyPaths |= reverse' <<<"$policy" | policy_trust_map)"
A='.transports.docker["ghcr.io/apex-linux/apex"]'
TT='.transports.docker["ghcr.io/apex-linux/apex-testing"]'
while IFS='|' read -r name edit; do
    [[ -n $name ]] || continue
    if ! edited=$(jq -c "$edit" "$committed") || [[ -z $edited ]]; then
        flunk "trust mapping: the edit '$name' does not apply"
        continue
    fi
    trust_rc=0
    trust_map=$(policy_trust_map <<<"$edited" 2>/dev/null) || trust_rc=$?
    if ((trust_rc == 0)) && [[ $trust_map == "$EXPECTED_TRUST_MAP" ]]; then
        flunk "trust mapping: '$name' is accepted as the ADR 0012 mapping"
    else
        pass
    fi
done <<EOF
CI key trusted for the stable repository|${A}[0].keyPaths += ["/usr/share/apex/keys/ci.pub"]
CI key instead of the release keys|${A}[0] |= (del(.keyPaths) | .keyPath = "/usr/share/apex/keys/ci.pub")
release key trusted for testing|${TT}[0].keyPath = "/usr/share/apex/keys/release.pub"
backup key dropped|${A}[0].keyPaths |= .[:1]
insecureAcceptAnything for the registry|.transports.docker["ghcr.io"] = [{"type": "insecureAcceptAnything"}]
second requirement in a scope|$TT += [{"type": "insecureAcceptAnything"}]
extra transport|.transports["docker-daemon"] = {"": [{"type": "insecureAcceptAnything"}]}
default accepts|.default = [{"type": "insecureAcceptAnything"}]
default reject plus accept|.default += [{"type": "insecureAcceptAnything"}]
keyData next to the key paths|${A}[0].keyData = "AAAA"
signedBy instead of sigstoreSigned|${TT}[0].type = "signedBy"
remapIdentity|${A}[0].signedIdentity = {"type": "remapIdentity", "prefix": "ghcr.io", "signedPrefix": "ghcr.io"}
matchRepoDigestOrExact|${A}[0].signedIdentity = {"type": "matchRepoDigestOrExact"}
testing scope missing|del($TT)
both keyPath and keyPaths|${TT}[0].keyPaths = ["/usr/share/apex/keys/ci.pub"]
duplicate key path|${A}[0].keyPaths += ["/usr/share/apex/keys/release.pub"]
empty keyPaths|${A}[0].keyPaths = []
extra top-level field|.specificPolicies = {}
EOF

# --- manifest lock list -----------------------------------------------------------------
manifest='{"schema":1,"packages":[
  {"name":"bash","epoch":0,"version":"5.3.0","release":"2.fc45","arch":"x86_64"},
  {"name":"shim-x64","epoch":1,"version":"16.1","release":"7","arch":"x86_64"},
  {"name":"tzdata","version":"2026b","release":"1.fc45","arch":"noarch"}]}'
check "lock list" "bash-5.3.0-2.fc45.x86_64
shim-x64-1:16.1-7.x86_64
tzdata-2026b-1.fc45.noarch" "$(manifest_lock_list <<<"$manifest")"

# --- registry error classification (fake skopeo) ---------------------------------------
mkdir -p "$TMP/bin"
cat >"$TMP/bin/skopeo" <<'EOF'
#!/usr/bin/env bash
ref=${*: -1}
raw=0
[[ " $* " == *" --raw "* ]] && raw=1
case $ref in
    *found*) printf '{"Digest":"sha256:%064d","Labels":{"org.opencontainers.image.version":"45.20260924.1"}}\n' 7 ;;
    *missing*) echo "Error: reading manifest 45 in ${ref#docker://}: manifest unknown" >&2; exit 1 ;;
    *gone404*) echo "Error: reading manifest 45 in ${ref#docker://}: StatusCode: 404, \"\"" >&2; exit 1 ;;
    *private*) echo 'Error: requested access to the resource is denied' >&2; exit 1 ;;
    # The manifest exists, but its config blob fails with a 5xx; the blob's digest
    # contains "404" and the message "not found" would too for a missing blob.
    *blob*)
        if ((raw)); then printf '{"schemaVersion":2}'; exit 0; fi
        echo 'Error: reading blob sha256:9f1c404a7e0b: fetching blob: received unexpected HTTP status: 502 Bad Gateway (blob not found in cache)' >&2
        exit 1 ;;
    *) echo 'Error: pinging container registry: dial tcp: i/o timeout' >&2; exit 1 ;;
esac
EOF
chmod +x "$TMP/bin/skopeo"
rc_of() { local rc=0; "$@" >/dev/null 2>&1 || rc=$?; printf '%s' "$rc"; }
# Run in a subshell, which keeps PATH and the retry delay; returns its failure count.
registry_checks() {
    local FAILS=0
    PATH="$TMP/bin:$PATH"
    export APEX_RETRY_DELAY=0
    check "inspect found" 0 "$(rc_of registry_inspect ghcr.io/x/found:45)"
    check "inspect missing" 3 "$(rc_of registry_inspect ghcr.io/x/missing:45)"
    check "inspect denied" 4 "$(rc_of registry_inspect ghcr.io/x/private:45)"
    check "inspect network error" 1 "$(rc_of registry_inspect ghcr.io/x/offline:45)"
    check "a 404 while reading the manifest is absent" 3 "$(rc_of registry_inspect ghcr.io/x/gone404:45)"
    check "a blob error (digest with 404) is unknown, not absent" 1 "$(rc_of registry_inspect ghcr.io/x/blob:45)"
    check "digest after a blob error is unknown" 1 "$(rc_of registry_digest ghcr.io/x/blob:45)"
    check "manifest-only probe of that image succeeds" 0 "$(rc_of registry_manifest ghcr.io/x/blob:45)"
    check "digest" "sha256:$(printf '%064d' 7)" "$(registry_digest ghcr.io/x/found:45)"
    check "label" 45.20260924.1 "$(registry_label ghcr.io/x/found:45 org.opencontainers.image.version)"
    check "absent label" "" "$(registry_label ghcr.io/x/found:45 nope)"
    return "$FAILS"
}
registry_failures=0
(registry_checks) || registry_failures=$?
FAILS=$((FAILS + registry_failures))

# --- boot-counter state (qualify.sh) ---------------------------------------------------
D1="sha256:$(printf '1%.0s' {1..64})"
D2="sha256:$(printf '2%.0s' {1..64})"
env_armed=$(printf '# GRUB Environment Block\napex_target=%s\napex_counter=3\napex_ok=0\n' "$D1")
env_counted=$(printf 'apex_target=%s\napex_counter=-1\napex_ok=0\n' "$D1")
env_confirmed=$'saved_entry=x\nboot_success=0\napex_ok=1'
env_plain=$'apex_ok=0\nboot_success=1\nboot_counter=2'
check "grubenv value" 3 "$(grubenv_value apex_counter <<<"$env_armed")"
check "grubenv value with '=' inside" "a=b" "$(grubenv_value k <<<'k=a=b')"
check "grubenv last assignment wins" 2 "$(grubenv_value k <<<$'k=1\nk=2')"
check "grubenv empty value" "" "$(grubenv_value k <<<'k=')"
check_false "grubenv unset" grubenv_value apex_target <<<"$env_plain"
check_false "grubenv prefix is not the name" grubenv_value apex <<<"$env_armed"
check_true "armed as Apply writes it" grubenv_check armed "$D1" <<<"$env_armed"
check_false "armed for another digest" grubenv_check armed "$D2" <<<"$env_armed"
check_false "counted is not freshly armed" grubenv_check armed "$D1" <<<"$env_counted"
check_false "armed needs apex_ok=0" grubenv_check armed "$D1" <<<"${env_armed/apex_ok=0/apex_ok=1}"
check_false "armed but nothing set" grubenv_check armed "$D1" <<<"$env_plain"
check_true "disarmed ignores Fedora's own variables" grubenv_check disarmed <<<"$env_plain"
check_true "disarmed with empty values" grubenv_check disarmed <<<$'apex_target=\napex_counter='
check_true "disarmed: no grubenv at all" grubenv_check disarmed <<<""
check_false "a counter alone is still armed" grubenv_check disarmed <<<'apex_counter=-1'
check_false "a target alone is still armed" grubenv_check disarmed <<<"apex_target=$D1"
check_true "confirmed" grubenv_check confirmed <<<"$env_confirmed"
check_false "confirmed needs apex_ok=1" grubenv_check confirmed <<<"$env_plain"
check_false "confirmed must be disarmed" grubenv_check confirmed <<<"${env_counted/apex_ok=0/apex_ok=1}"
check_false "unknown state dies" grubenv_check sideways <<<"$env_plain"
check "the reason names both variables" "still armed: apex_target=$D1 apex_counter=-1" \
    "$(grubenv_check disarmed <<<"$env_counted" || true)"

green_state() {
    bash -c '. "$1"; has=$2; vm_ssh() { [[ $* == "test -e $APEX_MENU_SNIPPET" && $has == yes ]]; }; green_grubstate' \
        _ "$APEX_ROOT/.github/scripts/qualify.sh" "$1"
}
check "a green boot of an image with the menu snippet is confirmed" confirmed "$(green_state yes)"
check "a green boot of an older image is only disarmed" disarmed "$(green_state no)"

deny=$(printf '{"digests":[{"digest":"%s","reason":"fallback","at":1}],"extra":1}' "$D1")
check_true "denylisted" denylist_has "$D1" <<<"$deny"
check_false "not denylisted" denylist_has "$D2" <<<"$deny"
check_false "empty denylist" denylist_has "$D1" <<<'{"digests":[]}'
check_false "denylist without digests" denylist_has "$D1" <<<'{}'
health=$(printf '{"digest":"%s","failed_checks":["session","forced-red"],"at":1}' "$D1")
check_true "health failure with forced-red" health_failure_has "$D1" forced-red <<<"$health"
check_false "health failure of another digest" health_failure_has "$D2" forced-red <<<"$health"
check_false "health failure without that check" health_failure_has "$D1" failed-units <<<"$health"
check_false "health failure with no checks" health_failure_has "$D1" forced-red \
    <<<"{\"digest\":\"$D1\",\"failed_checks\":[],\"at\":1}"

# --- qualify.sh: counting the armed boots' self-reboots (fake QEMU and ssh) --------------
Q="$TMP/qualify"
mkdir -p "$Q/bin" "$Q/out/logs"
cat >"$Q/bin/qemu-system-x86_64" <<'EOF'
#!/usr/bin/env bash
# Fake QEMU: records its arguments and "boots" the next line of $FAKE_QEMU_PLAN. reboot:
# the guest reboots at once, which ends QEMU only under -no-reboot; stay: it keeps running.
set -euo pipefail
pidfile= serial= noreboot=0
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
    case ${args[i]} in
        -pidfile) pidfile=${args[i + 1]} ;;
        -serial) serial=${args[i + 1]#file:} ;;
        -no-reboot) noreboot=1 ;;
    esac
done
printf '%s\n' "$*" >>"$FAKE_QEMU_LOG"
plan=$(head -n 1 "$FAKE_QEMU_PLAN")
sed -i 1d "$FAKE_QEMU_PLAN"
: >"$serial"
secs=60
if [[ $plan == reboot ]] && ((noreboot)); then secs=0.3; fi
sleep "$secs" </dev/null >/dev/null 2>&1 &
printf '%s\n' "$!" >"$pidfile"
EOF
cat >"$Q/bin/ssh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_SSH_LOG"
exit 255
EOF
chmod +x "$Q/bin/qemu-system-x86_64" "$Q/bin/ssh"
: >"$Q/code.fd"
: >"$Q/vars.fd"
: >"$Q/out/red.raw"

# qualify.sh runs in a fresh bash: this shell already holds lib.sh's readonly names.
run_armed_attempts() {
    local attempt_timeout=${*: -1}
    printf '%s\n' "$@" | head -n -1 >"$Q/plan"
    : >"$Q/qemu.log"
    rm -f "$Q/ssh.log" "$Q/unlock.log" "$Q/out/results.md" "$Q/out/logs/"*
    local rc=0
    # shellcheck disable=SC2016 # expanded by the inner bash
    PATH="$Q/bin:$PATH" QUALIFY_OUT="$Q/out" QUALIFY_POLL=0.1 QUALIFY_ATTEMPT_TIMEOUT="$attempt_timeout" \
        OVMF_CODE="$Q/code.fd" OVMF_VARS="$Q/vars.fd" GITHUB_ACTIONS='' \
        FAKE_QEMU_LOG="$Q/qemu.log" FAKE_QEMU_PLAN="$Q/plan" FAKE_SSH_LOG="$Q/ssh.log" FAKE_LUKS=${FAKE_LUKS:-} \
        bash -c '. "$1"; require_kvm() { :; }; fake=$2
            if [[ -n $FAKE_LUKS ]]; then
                LUKS_PASSPHRASE=x
                luks_unlock() { printf "%s %s %s\n" "$1" "$2" "${3:-}" >>"$fake/unlock.log"; }
            fi
            armed_attempts red "$APEX_BOOT_ATTEMPTS"' \
        _ "$APEX_ROOT/.github/scripts/qualify.sh" "$Q" >"$Q/stderr.log" 2>&1 || rc=$?
    if [[ -f $Q/out/red.pid ]]; then kill "$(cat "$Q/out/red.pid")" 2>/dev/null || true; fi
    return "$rc"
}

rc=0
run_armed_attempts reboot reboot reboot stay 20 || rc=$?
check "three self-reboots, then the fallback boot keeps running" 0 "$rc"
((rc == 0)) || cat "$Q/stderr.log" >&2
check "QEMU started four times" 4 "$(wc -l <"$Q/qemu.log")"
check "every start has -no-reboot" 4 "$(grep -c -- ' -no-reboot' "$Q/qemu.log")"
check "one console log per boot" "red-attempt1.serial.log red-attempt2.serial.log red-attempt3.serial.log red-fallback.serial.log" \
    "$(find "$Q/out/logs" -type f -printf '%f\n' | sort | tr '\n' ' ' | sed 's/ $//')"
check "one result row per attempt" 3 "$(grep -c '^| red-attempt[1-3] | PASS |' "$Q/out/results.md")"
check_false "no ssh while the armed boots run" test -s "$Q/ssh.log"

rc=0
run_armed_attempts reboot stay 2 || rc=$?
check "an attempt that does not reboot fails" 1 "$rc"
check "the failing attempt is named" 1 "$(grep -c '^| red-attempt2 | FAIL |' "$Q/out/results.md" 2>/dev/null || true)"
check "no attempt after the failed one" 2 "$(wc -l <"$Q/qemu.log")"
check_false "no ssh before the failure" test -s "$Q/ssh.log"

rc=0
FAKE_LUKS=1 run_armed_attempts reboot reboot reboot stay 20 || rc=$?
check "on LUKS2, three self-reboots, then the fallback boot" 0 "$rc"
((rc == 0)) || cat "$Q/stderr.log" >&2
check "each of the four boots is unlocked from its own console's start, with no wrong passphrase" \
    "red-attempt1-luks 0 |red-attempt2-luks 0 |red-attempt3-luks 0 |red-fallback-luks 0 " \
    "$(tr '\n' '|' <"$Q/unlock.log" | sed 's/|$//')"

rc=0
PATH="$Q/bin:$PATH" bash -c '. "$1"' _ "$APEX_ROOT/.github/scripts/qualify.sh" >"$Q/stderr.log" 2>&1 || rc=$?
check "sourcing qualify.sh runs nothing" "0:" "$rc:$(cat "$Q/stderr.log")"

# --- qualify.sh: G4 is due when its key changes or its last pass is a week old ------------
G4_DIR="$TMP/g4"
mkdir -p "$G4_DIR"
key_script=$(bash -c '. "$1"; g4_key_script' _ "$APEX_ROOT/.github/scripts/qualify.sh")
check_true "the key names the NEVRAs of what G4's install, login and lock run on" \
    grep -qF "rpm -q --qf 'package %{NAME}-%{EPOCHNUM}:%{VERSION}-%{RELEASE}.%{ARCH}\n' gdm gnome-shell mutter gjs gnome-session accountsservice pam systemd \$kernel shim-x64 grub2-efi-x64 bootupd" <<<"$key_script"
check_true "the kernel is Fedora's, or the pair's with its kmod and nvidia-kmod-common" \
    grep -qF "rpm -q kernel >/dev/null 2>&1 || kernel=\"kernel-cachyos-core \$(rpm -qa --qf '%{NAME}\n' 'kmod-nvidia*' nvidia-kmod-common" <<<"$key_script"
check_true "the pair's own overlay files, where the image has them" \
    grep -qF "for f in /usr/lib/bootc/kargs.d/20-apex-pair.toml /usr/lib/modprobe.d/apex-nvidia.conf " <<<"$key_script"
check_true "every file of apex and apex-desktop by its digest, not their commit-stamped releases" \
    grep -qF "rpm -q --qf '[file %{FILEDIGESTS} %{FILENAMES}\n]' apex apex-desktop" <<<"$key_script"
overlay_line=$(grep '^sha256sum ' <<<"$key_script")
overlay_line=${overlay_line%%|*}
for overlay_file in /usr/lib/bootc/install/10-apex.toml \
    /usr/lib/systemd/system-preset/80-apex.preset /usr/share/polkit-1/rules.d/50-apex-no-layering.rules \
    /usr/lib/systemd/journald.conf.d/10-apex-persistent.conf \
    /usr/lib/systemd/system/bootloader-update.service.d/10-apex-after-green-boot.conf; do
    check_true "the key hashes the overlay's $overlay_file" grep -qF " $overlay_file" <<<"$overlay_line"
done
check "and every /usr file of the overlay, none of /etc" \
    "$(cd "$APEX_ROOT/image/system_files" && find usr -type f | wc -l)" "$(wc -w <<<"${overlay_line#sha256sum }")"
key_lines() {
    local shell_release=$1 apexctl_digest=$2
    printf '%s\n' "package gdm-1:51.0-1.fc45.x86_64" "package gnome-shell-0:51.0-$shell_release.x86_64" \
        "package mutter-0:51.0-1.fc45.x86_64" "file $apexctl_digest /usr/bin/apexctl"
}
key_lines 1.fc45.apex1 aaaa >"$G4_DIR/base.key"
key_lines 1.fc45.apex2 aaaa >"$G4_DIR/shell.key"
key_lines 1.fc45.apex1 bbbb >"$G4_DIR/apexctl.key"
sort -r "$G4_DIR/base.key" >"$G4_DIR/unsorted.key"
g4_due() {
    local key=$1 record=${2:-$G4_DIR/record} rc=0
    QUALIFY_G4_RECORD="$record" "$APEX_ROOT/.github/scripts/qualify.sh" g4-due "$key" \
        >"$G4_DIR/stdout" 2>"$G4_DIR/out" || rc=$?
    printf '%s\n' "$rc"
}
record_pass() {
    local key=$1 passed_at=$2
    { cat "$key"; printf 'passed-at %s\nimage-id feed\n' "$passed_at"; } >"$G4_DIR/record"
}
check "due when no pass is recorded" 0 "$(g4_due "$G4_DIR/base.key")"
check_true "and says so" grep -q 'G4 is due: no local pass is recorded' "$G4_DIR/out"
record_pass "$G4_DIR/base.key" "$(date -u -d '-1 day' +%FT%TZ)"
check "not due for the key of the last pass" 3 "$(g4_due "$G4_DIR/base.key")"
check "and prints when it passed, and on which image" "passed-at $(sed -n 's/^passed-at //p' "$G4_DIR/record")|image-id feed" \
    "$(paste -sd'|' "$G4_DIR/stdout")"
check "whatever the order of its lines" 3 "$(g4_due "$G4_DIR/unsorted.key")"
check "due when gnome-shell moves" 0 "$(g4_due "$G4_DIR/shell.key")"
check_true "and names the change" grep -qF 'package gnome-shell-0:51.0-1.fc45.apex2.x86_64' "$G4_DIR/out"
check "due when a file of apex changes" 0 "$(g4_due "$G4_DIR/apexctl.key")"
record_pass "$G4_DIR/base.key" "$(date -u -d '-8 days' +%FT%TZ)"
check "due a week after the last pass, with the key unchanged" 0 "$(g4_due "$G4_DIR/base.key")"
check_true "and says how old it is" grep -q 'G4 is due: this key passed on .*, 8 days ago' "$G4_DIR/out"
cp "$G4_DIR/base.key" "$G4_DIR/record"
check "due when the last pass records no time" 0 "$(g4_due "$G4_DIR/base.key")"
: >"$G4_DIR/empty.key"
check "an empty key is an error, not a verdict" 1 "$(g4_due "$G4_DIR/empty.key")"
check "a missing key too" 1 "$(g4_due "$G4_DIR/absent.key")"

# --- build-image.sh: G2 twice, G4 when due, and the gates record ---------------------------
BUILD_DIR="$TMP/build-image"
mkdir -p "$BUILD_DIR/work/tests/shots" "$BUILD_DIR/work/.github/scripts" "$BUILD_DIR/work/_build/image" \
    "$BUILD_DIR/work/_build/g2/latest" "$BUILD_DIR/work/image/packages" "$BUILD_DIR/store"
cp "$APEX_ROOT/.github/scripts/lib.sh" "$BUILD_DIR/work/.github/scripts/"
cp "$APEX_CONTAINERFILE" "$BUILD_DIR/work/image/"
cp "$APEX_TESTING_ALLOWLIST" "$BUILD_DIR/work/image/packages/"
printf 'lock\n' >"$BUILD_DIR/store/rpms.lock.next"
LANE_LOCK_SHA=$(sha256sum <"$BUILD_DIR/store/rpms.lock.next" | cut -d' ' -f1)
cat >"$BUILD_DIR/work/tests/shots/run.sh" <<'EOF'
#!/usr/bin/env bash
echo "$G2_RUNS" >"$FAKE/g2-runs"
printf '%s|%s|%s\n' "$G2_IMAGE_DIR" "$G2_REPOS_BASE" "$G2_OUT_DIR" >"$FAKE/g2-env"
exit "$(cat "$FAKE/g2-rc" 2>/dev/null || echo 0)"
EOF
cat >"$BUILD_DIR/work/.github/scripts/qualify.sh" <<'EOF'
#!/usr/bin/env bash
case $1 in
    g4-key) echo "package gdm-1:51.0-1.fc45.x86_64" ;;
    g4-due) cat "$FAKE/g4-due-stdout" 2>/dev/null; exit "$(cat "$FAKE/g4-due-rc")" ;;
    local) echo local >>"$FAKE/g4-ran"; exit "$(cat "$FAKE/g4-rc" 2>/dev/null || echo 0)" ;;
esac
EOF
chmod +x "$BUILD_DIR/work/tests/shots/run.sh" "$BUILD_DIR/work/.github/scripts/qualify.sh"
build_gates() {
    local image_only=${1:-0} rc=0
    rm -f "$BUILD_DIR/work/_build/gates-passed.txt" "$BUILD_DIR/g4-ran"
    (cd "$BUILD_DIR/work" && FAKE=$BUILD_DIR APEX_STORE=$BUILD_DIR/store APEX_GNOME_SRC=$BUILD_DIR/work APEX_COMPONENTS=${APEX_COMPONENTS:-pinned} bash -c '
        . "$1"
        image_id() { echo cafe; }
        gate_g2 && gate_g4 "$2" && { [[ $G4_VERDICT == due ]] || record_gates; }' \
        _ "$APEX_ROOT/tools/builder-vm/build-image.sh" "$image_only") >"$BUILD_DIR/out" 2>&1 || rc=$?
    printf '%s\n' "$rc"
}
g2_result() {
    local image_id=$1 lock_sha256=$2
    printf 'image-id %s\nruns 2\nlock-sha256 %s\nstatus passed\n' "$image_id" "$lock_sha256" \
        >"$BUILD_DIR/work/_build/g2/latest/result.txt"
}
g2_result cafe "$LANE_LOCK_SHA"
echo 0 >"$BUILD_DIR/g4-due-rc"
check "G2, then G4 when due, then the record" 0 "$(G2_RUNS=1 build_gates)"
check "G2 runs twice, whatever G2_RUNS says" 2 "$(cat "$BUILD_DIR/g2-runs")"
check "G2 is apex-gnome's run.sh, given this image/, its REPOS_BASE and this _build/g2" \
    "$BUILD_DIR/work/image|$(containerfile_arg REPOS_BASE)|$BUILD_DIR/work/_build/g2" "$(cat "$BUILD_DIR/g2-env")"
check "G4 ran" local "$(cat "$BUILD_DIR/g4-ran")"
check "the record names the lane lock the image carries, the image and G4's pass" \
    "lock-sha256 $LANE_LOCK_SHA|image-id cafe|g2 passed|g4 passed for image cafe|components pinned" \
    "$(paste -sd'|' "$BUILD_DIR/work/_build/gates-passed.txt")"
check "a build from a dev-override component says so in its record" "components dev-override" \
    "$(APEX_COMPONENTS=dev-override build_gates >/dev/null; grep '^components ' "$BUILD_DIR/work/_build/gates-passed.txt")"
echo 3 >"$BUILD_DIR/g4-due-rc"
printf 'passed-at 2026-09-29T17:10:00Z\nimage-id beef\n' >"$BUILD_DIR/g4-due-stdout"
check "G4 not due: the record" 0 "$(build_gates)"
check_false "without running G4" test -e "$BUILD_DIR/g4-ran"
check "names the pass G4 was not due for, not this image" "g4 not due: its key passed on 2026-09-29T17:10:00Z for image beef" \
    "$(grep '^g4 ' "$BUILD_DIR/work/_build/gates-passed.txt")"
check_false "and claims no G4 pass for this image" grep -q 'G4 passed\|and G4 passed' "$BUILD_DIR/out"
echo 0 >"$BUILD_DIR/g4-due-rc"
check "--image-only with G4 due records nothing" "0:no record" \
    "$(build_gates 1):$([[ -e $BUILD_DIR/work/_build/gates-passed.txt ]] && echo record || echo 'no record')"
echo 1 >"$BUILD_DIR/g4-rc"
check "a G4 failure records nothing" "1:no record" \
    "$(build_gates):$([[ -e $BUILD_DIR/work/_build/gates-passed.txt ]] && echo record || echo 'no record')"
rm -f "$BUILD_DIR/g4-rc"
g2_result cafe "$(printf 'older lock\n' | sha256sum | cut -d' ' -f1)"
check "a lane lock that moved during the gates records nothing" "1:no record" \
    "$(build_gates):$([[ -e $BUILD_DIR/work/_build/gates-passed.txt ]] && echo record || echo 'no record')"
check_true "and says so" grep -q 'the lane lock moved while the gates ran' "$BUILD_DIR/out"
g2_result beef "$LANE_LOCK_SHA"
check "a G2 result of another image records nothing" "1:no record" \
    "$(build_gates):$([[ -e $BUILD_DIR/work/_build/gates-passed.txt ]] && echo record || echo 'no record')"
g2_result cafe "$LANE_LOCK_SHA"
echo 1 >"$BUILD_DIR/g2-rc"
check "a G2 failure records nothing" "1:no record" \
    "$(build_gates):$([[ -e $BUILD_DIR/work/_build/gates-passed.txt ]] && echo record || echo 'no record')"
G2_RUN1=$BUILD_DIR/work/_build/g2/latest/run-1
mkdir -p "$G2_RUN1"
printf '%s\n' 'PASS motion: the user mode' 'FAIL motion: the shell exits 0 (got: exit=139)' \
    'FAIL dock-pin: a pinned favourite shows' 'FAIL default-scale1 dock: its menu (got null)' >"$G2_RUN1/assert.txt"
printf 'motion exit=139 secs=47 marker-after-exit=no\n' >"$G2_RUN1/results-direct.txt"
{ seq 1 100 | sed 's/^/line /'; echo 'GNOME Shell crashed with signal 11'; } >"$G2_RUN1/motion.log"
printf 'case %s\n' 'default-scale1' >"$G2_RUN1/default-scale1.log"
build_gates >/dev/null
check_true "a G2 failure prints a failing case's exit" grep -qx '== G2 motion: motion exit=139 secs=47 marker-after-exit=no' "$BUILD_DIR/out"
check_true "its crash lines, wherever they are" grep -qx '101:GNOME Shell crashed with signal 11' "$BUILD_DIR/out"
check_true "and its last lines" grep -qx 'line 22' "$BUILD_DIR/out"
check_false "but no more of them" grep -qx 'line 21' "$BUILD_DIR/out"
check_true "a case named before its subject is found too" grep -qx 'case default-scale1' "$BUILD_DIR/out"
check_false "a failing case without a log prints nothing" grep -q '== G2 dock-pin' "$BUILD_DIR/out"
check_false "nor does a passing line" grep -q '^== G2 PASS' "$BUILD_DIR/out"
rm -rf "$G2_RUN1" "$BUILD_DIR/g2-rc"
check "a break-glass image (KERNEL=fedora) records nothing, so lane.sh promote refuses it" "0:no record" \
    "$(APEX_KERNEL=fedora build_gates):$([[ -e $BUILD_DIR/work/_build/gates-passed.txt ]] && echo record || echo 'no record')"
check_true "and says so" grep -q 'break-glass image (KERNEL=fedora): its gates ran, but nothing is recorded' "$BUILD_DIR/out"

# --- firmware.sh: the VM scripts find Ubuntu's or Fedora's OVMF ------------------------------
# fw_fn SCRIPT [ARG]: SCRIPT runs in a shell that sourced firmware.sh; ARG is its $2.
fw_fn() { bash -c 'die() { printf "%s\n" "$*" >&2; exit 1; }; . "$1"; shift; eval "$1"' _ "$APEX_ROOT/tools/builder-vm/firmware.sh" "$@"; }
# shellcheck disable=SC2016 # expanded by the shell that sourced firmware.sh
fw_found() { fw_fn 'find_ovmf; printf "%s %s %s\n" "$OVMF_CODE" "$OVMF_VARS_TEMPLATE" "$OVMF_FORMAT"' 2>/dev/null; }
FW=$TMP/firmware
mkdir -p "$FW/fedora/usr/share/edk2/ovmf" "$FW/ubuntu/usr/share/OVMF" "$FW/none"
printf 'code' >"$FW/fedora/usr/share/edk2/ovmf/OVMF_CODE.fd"
printf 'vars' >"$FW/fedora/usr/share/edk2/ovmf/OVMF_VARS.fd"
printf 'code' >"$FW/ubuntu/usr/share/OVMF/OVMF_CODE_4M.fd"
printf 'vars' >"$FW/ubuntu/usr/share/OVMF/OVMF_VARS_4M.fd"
check "Fedora's edk2-ovmf is found" \
    "$FW/fedora/usr/share/edk2/ovmf/OVMF_CODE.fd $FW/fedora/usr/share/edk2/ovmf/OVMF_VARS.fd raw" \
    "$(FIRMWARE_ROOT=$FW/fedora fw_found)"
check "Ubuntu's 4M ovmf is found" \
    "$FW/ubuntu/usr/share/OVMF/OVMF_CODE_4M.fd $FW/ubuntu/usr/share/OVMF/OVMF_VARS_4M.fd raw" \
    "$(FIRMWARE_ROOT=$FW/ubuntu fw_found)"
check "no firmware on the host fails" 1 "$(FIRMWARE_ROOT=$FW/none rc_of fw_found)"
check "APEX_OVMF_CODE and APEX_OVMF_VARS win over the host's files" \
    "$FW/ubuntu/usr/share/OVMF/OVMF_CODE_4M.fd $FW/fedora/usr/share/edk2/ovmf/OVMF_VARS.fd raw" \
    "$(FIRMWARE_ROOT=$FW/fedora APEX_OVMF_CODE=$FW/ubuntu/usr/share/OVMF/OVMF_CODE_4M.fd \
        APEX_OVMF_VARS=$FW/fedora/usr/share/edk2/ovmf/OVMF_VARS.fd fw_found)"
check "only one of the two overrides fails" 1 \
    "$(APEX_OVMF_CODE=$FW/ubuntu/usr/share/OVMF/OVMF_CODE_4M.fd rc_of fw_found)"
printf 'vars' >"$FW/same.fd"
printf 'vars from another firmware build' >"$FW/other.fd"
# shellcheck disable=SC2016 # expanded by the shell that sourced firmware.sh
check "a variable store of this firmware's size starts" 0 \
    "$(FIRMWARE_ROOT=$FW/fedora rc_of fw_fn 'find_ovmf; check_vars "$2"' "$FW/same.fd")"
# shellcheck disable=SC2016 # expanded by the shell that sourced firmware.sh
check "a variable store from another host's firmware is refused" 1 \
    "$(FIRMWARE_ROOT=$FW/fedora rc_of fw_fn 'find_ovmf; check_vars "$2"' "$FW/other.fd")"

# --- ci-build.sh: the runner's forced command builds only 'ci-build <sha>' of main (fake git) ---
CI_DIR="$TMP/ci-build"
CI_SHA=$(printf 'a%.0s' {1..40})
CI_OTHER=$(printf 'b%.0s' {1..40})
mkdir -p "$CI_DIR/bin" "$CI_DIR/store" "$CI_DIR/home/apex-image/.git" "$CI_DIR/home/apex-image/tools/builder-vm"
cat >"$CI_DIR/bin/git" <<'EOF'
#!/usr/bin/env bash
while [[ ${1:-} == -c || ${1:-} == -C ]]; do shift 2; done
echo "$*" >>"$FAKE/git.log"
case $1 in
    rev-parse)
        case $2 in
            --git-dir) echo .git ;;
            --is-shallow-repository) echo false ;;
            HEAD) cat "$FAKE/head" ;;
        esac ;;
    cat-file) [[ $3 == "$(cat "$FAKE/main-sha")^{commit}" ]] ;;
    merge-base) [[ $3 == "$(cat "$FAKE/main-sha")" ]] ;;
    checkout) echo "$5" >"$FAKE/head" ;;
esac
EOF
cat >"$CI_DIR/home/apex-image/tools/builder-vm/build-image.sh" <<'EOF'
#!/usr/bin/env bash
mkdir -p _build
echo "lock-sha256 x" >_build/gates-passed.txt
if [[ -e $FAKE/with-logs ]]; then
    mkdir -p _build/qualify/logs
    echo shot >_build/qualify/logs/local-lock.png
    echo journal >_build/qualify/logs/local-unlock.journal.txt
    truncate -s 21M _build/qualify/logs/local.serial.log
fi
exit "$(cat "$FAKE/build-rc")"
EOF
cat >"$CI_DIR/home/apex-image/tools/builder-vm/lane.sh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$FAKE/lane.log"
EOF
chmod +x "$CI_DIR/bin/git" "$CI_DIR/home/apex-image/tools/builder-vm/"*.sh
printf 'old\n' >"$CI_DIR/store/rpms.lock"
printf 'new\n' >"$CI_DIR/store/rpms.lock.next"
ci_build() {
    local rc=0
    rm -f "$CI_DIR/git.log" "$CI_DIR/lane.log" "$CI_DIR/home/apex-image/_build/gates-passed.txt"
    echo 0000000000000000000000000000000000000000 >"$CI_DIR/head"
    HOME=$CI_DIR/home PATH="$CI_DIR/bin:$PATH" FAKE=$CI_DIR APEX_STORE=$CI_DIR/store \
        "$@" bash "$APEX_ROOT/tools/builder-vm/ci-build.sh" >"$CI_DIR/out.tar" 2>"$CI_DIR/err" || rc=$?
    printf '%s\n' "$rc"
}
ci_request() { ci_build env SSH_ORIGINAL_COMMAND="$1"; }
echo "$CI_SHA" >"$CI_DIR/main-sha"
echo 0 >"$CI_DIR/build-rc"
for request in '' ci-build "ci-build $CI_SHA " " ci-build $CI_SHA" "ci-build  $CI_SHA" "ci-build ${CI_SHA^^}" \
    "ci-build ${CI_SHA}a" "ci-build ${CI_SHA:1}" "ci-build $CI_SHA; touch $CI_DIR/pwned" \
    "ci-build \$(touch $CI_DIR/pwned)" "ci-build \`touch $CI_DIR/pwned\`" $'ci-build '"$CI_SHA"$'\ntouch '"$CI_DIR/pwned" \
    "ci-build $CI_SHA $CI_SHA" "ci-promote $CI_SHA" "ci-build HEAD" "ci-build main" "ci-build -h" \
    "ci-build $CI_SHA daily " "ci-build $CI_SHA  daily" "ci-build $CI_SHA dailyx" "ci-build $CI_SHA DAILY" \
    "ci-build daily $CI_SHA" "ci-build $CI_SHA daily daily" "ci-build $CI_SHA absorb"; do
    check "ci-build refuses $(printf '%q' "$request"), before any git" "2:no git" \
        "$(ci_request "$request"):$([[ -e $CI_DIR/git.log ]] && echo git || echo 'no git')"
done
check_false "and evaluates none of them" test -e "$CI_DIR/pwned"
check "ci-build refuses no SSH_ORIGINAL_COMMAND" 2 "$(ci_build env -u SSH_ORIGINAL_COMMAND)"
check "ci-build refuses arguments: authorized_keys fixes its argv" 2 \
    "$(HOME=$CI_DIR/home SSH_ORIGINAL_COMMAND="ci-build $CI_SHA" rc_of bash "$APEX_ROOT/tools/builder-vm/ci-build.sh" "$CI_SHA")"
echo "$CI_OTHER" >"$CI_DIR/main-sha"
check "ci-build refuses a commit that main does not contain, after the fetch" "2:fetched:no checkout" \
    "$(ci_request "ci-build $CI_SHA"):$(grep -q '^fetch .*+refs/heads/main:refs/remotes/origin/main$' "$CI_DIR/git.log" && echo fetched):$(grep -q '^checkout' "$CI_DIR/git.log" && echo checkout || echo 'no checkout')"
echo "$CI_SHA" >"$CI_DIR/main-sha"
check "ci-build builds a commit of main" 0 "$(ci_request "ci-build $CI_SHA")"
check "checked out at that commit, then cleaned keeping _build" "checkout -q --force --detach $CI_SHA|clean -q -ffdx -e /_build/" \
    "$(grep -E '^(checkout|clean)' "$CI_DIR/git.log" | paste -sd'|')"
check "and promoted the lane lock after the gates" promote "$(cat "$CI_DIR/lane.log")"
check "stdout is the results tar" "./ci-build.txt ./gates-passed.txt ./lock.diff" \
    "$(tar -tf "$CI_DIR/out.tar" | grep -v '^\./$' | sort | paste -sd' ')"
check "ci-build.txt names the commit and the promotion" "sha $CI_SHA|build-image 0|promote passed|exit 0" \
    "$(tar -xOf "$CI_DIR/out.tar" ./ci-build.txt | grep -Ev '^(started|finished) ' | paste -sd'|')"
echo 1 >"$CI_DIR/build-rc"
check "a failed build exits with its status and promotes nothing" "1:no promotion" \
    "$(ci_request "ci-build $CI_SHA"):$([[ -e $CI_DIR/lane.log ]] && echo promotion || echo 'no promotion')"
check "and still returns its results" "build-image 1|exit 1" \
    "$(tar -xOf "$CI_DIR/out.tar" ./ci-build.txt | grep -E '^(build-image|exit) ' | paste -sd'|')"
: >"$CI_DIR/with-logs"
mkdir -p "$CI_DIR/home/apex-image/_build/qualify/logs"
echo stale >"$CI_DIR/home/apex-image/_build/qualify/logs/old.journal.txt"
touch -d '2001-01-01' "$CI_DIR/home/apex-image/_build/qualify/logs/old.journal.txt"
ci_request "ci-build $CI_SHA" >/dev/null
check "a failed G4 returns this run's logs for vm.yml's artifact" \
    "./qualify-logs/SKIPPED ./qualify-logs/local-lock.png ./qualify-logs/local-unlock.journal.txt" \
    "$(tar -tf "$CI_DIR/out.tar" | grep '^\./qualify-logs/.' | sort | paste -sd' ')"
check "and names the file over 20 MiB it left out" "local.serial.log 21504 KiB" \
    "$(tar -xOf "$CI_DIR/out.tar" ./qualify-logs/SKIPPED)"
rm "$CI_DIR/with-logs"
rm -rf "$CI_DIR/home/apex-image/_build/qualify"
echo 0 >"$CI_DIR/build-rc"
cp "$APEX_ROOT/tools/builder-vm/ci-build.sh" "$CI_DIR/home/apex-image/tools/builder-vm/ci-build.sh"
ci_request "ci-build $CI_SHA" >/dev/null
check "an installed ci-build that is this commit's says nothing" 0 "$(tar -xOf "$CI_DIR/out.tar" ./ci-build.txt | grep -c '^stale ')"
echo '# a newer ci-build' >>"$CI_DIR/home/apex-image/tools/builder-vm/ci-build.sh"
check "a stale installed ci-build still builds" 0 "$(ci_request "ci-build $CI_SHA")"
check "and ci-build.txt says it is stale, with the fix" \
    "stale $(readlink -f "$APEX_ROOT/tools/builder-vm/ci-build.sh") differs from this commit's tools/builder-vm/ci-build.sh: run just vm-ci-install" \
    "$(tar -xOf "$CI_DIR/out.tar" ./ci-build.txt | grep '^stale ')"
rm "$CI_DIR/home/apex-image/tools/builder-vm/ci-build.sh"
cat >"$CI_DIR/home/apex-image/tools/builder-vm/lane-absorb-report.sh" <<'EOF'
#!/usr/bin/env bash
echo run >>"$FAKE/absorb.log"
mkdir -p _build/absorb/logs
printf '%s\t%s\t%s\t%s\t%s\n' \
    gnome-shell stable gnome-shell-51.0-1.fc45 applies '8 patch(es)' \
    gnome-shell testing gnome-shell-51.1-1.fc45 fails '0015-lock.patch: error: patch failed: js/ui/unlockDialog.js:894' \
    nautilus testing nautilus-51.1-1.fc45 applies '5 patch(es)' \
    ptyxis testing ptyxis-50.1-6.fc45 same 'updates-testing has nothing newer' >_build/absorb/rows.tsv
echo '# Lane absorption report' >_build/absorb/report.md
echo log >_build/absorb/logs/gnome-shell-testing.log
exit 3
EOF
chmod +x "$CI_DIR/home/apex-image/tools/builder-vm/lane-absorb-report.sh"
echo 0 >"$CI_DIR/build-rc"
rm -f "$CI_DIR/absorb.log"
cat >"$CI_DIR/home/apex-image/tools/builder-vm/metrics.sh" <<'EOF'
#!/usr/bin/env bash
echo "metrics ${5:-no-size}" >>"$FAKE/metrics.log"
EOF
rm -f "$CI_DIR/metrics.log"
check "the daily run's absorption report never gates: a failing family, exit 0" 0 "$(ci_request "ci-build $CI_SHA daily")"
check "its warning names the updates-testing family that fails, with the hunk" \
    "$(printf 'gnome-shell\tgnome-shell-51.1-1.fc45\tfails\t0015-lock.patch: error: patch failed: js/ui/unlockDialog.js:894')" \
    "$(tar -xOf "$CI_DIR/out.tar" ./absorb/warnings.tsv)"
check "the report, rows and logs go back for the summary and the artifact" \
    "./absorb/logs/gnome-shell-testing.log ./absorb/report.md ./absorb/rows.tsv ./absorb/warnings.tsv" \
    "$(tar -tf "$CI_DIR/out.tar" | grep '^\./absorb/.' | grep -v '/logs/$' | sort | paste -sd' ')"
check "ci-build.txt records the report's own status" "absorb 3" "$(tar -xOf "$CI_DIR/out.tar" ./ci-build.txt | grep '^absorb ')"
rm -f "$CI_DIR/absorb.log"
check "without daily no report runs" "0:no report" \
    "$(ci_request "ci-build $CI_SHA"):$([[ -e $CI_DIR/absorb.log ]] && echo report || echo 'no report')"
check "metrics run on every build, the image's size only on the daily one" "metrics size|metrics no-size" \
    "$(paste -sd'|' "$CI_DIR/metrics.log")"
echo 1 >"$CI_DIR/build-rc"
check "after a failed build the report still runs, and the build's status stands" "1:report" \
    "$(ci_request "ci-build $CI_SHA daily"):$([[ -e $CI_DIR/absorb.log ]] && echo report || echo 'no report')"
echo 0 >"$CI_DIR/build-rc"
rm -rf "$CI_DIR/home/apex-image/_build/absorb" "$CI_DIR/home/apex-image/tools/builder-vm/lane-absorb-report.sh" \
    "$CI_DIR/home/apex-image/tools/builder-vm/metrics.sh"

# ci-build <sha> next: the next release only, report-only, never a promotion.
CIW=$CI_DIR/home/apex-image
for request in "ci-build $CI_SHA next " "ci-build $CI_SHA NEXT" "ci-build $CI_SHA next daily" "ci-build next $CI_SHA" \
    "ci-build $CI_SHA daily next" "ci-build modes " "ci-build modes $CI_SHA"; do
    check "ci-build refuses $(printf '%q' "$request"), before any git" "2:no git" \
        "$(ci_request "$request"):$([[ -e $CI_DIR/git.log ]] && echo git || echo 'no git')"
done
check "ci-build modes names daily and next, before any git or lock" "0|daily next|no git" \
    "$(ci_request "ci-build modes")|$(cat "$CI_DIR/out.tar")|$([[ -e $CI_DIR/git.log ]] && echo git || echo 'no git')"
mv "$CIW/tools/builder-vm/build-image.sh" "$CI_DIR/build-image-45.sh"
cat >"$CIW/tools/builder-vm/build-image.sh" <<'EOF'
#!/usr/bin/env bash
echo "build-image APEX_FEDORA=${APEX_FEDORA:-}" >>"$FAKE/next.log"
mkdir -p _build/next/image "$APEX_STORE/next"
printf 'BASE_SOURCE=rawhide\nBASE_VERSION=46.20261024.0\n' >_build/next/image/build.env
printf 'family %s stock - since=2026-10-24T00:00:00Z reason=%s\n' \
    kernel-cachyos 'pair unavailable for Fedora 46: no fedora-46 pins in packaging/pkgs/kernel' \
    gnome-shell "next lane fallback at build.log ($APEX_STORE/next/pkgs/gnome-shell/last-failure.txt): rpmbuild failed" \
    >"$APEX_STORE/next/rpms.lock.next"
mkdir -p "$APEX_STORE/next/pkgs/gnome-shell"
echo 'rpmbuild failed' >"$APEX_STORE/next/pkgs/gnome-shell/last-failure.txt"
exit "$(cat "$FAKE/build-rc")"
EOF
chmod +x "$CIW/tools/builder-vm/build-image.sh"
cat >"$CIW/tools/builder-vm/metrics.sh" <<'EOF'
#!/usr/bin/env bash
echo metrics >>"$FAKE/next.log"
EOF
rm -f "$CI_DIR/next.log" "$CI_DIR/lane.log"
check "a commit without a next release builds nothing, and says so" "0|next none|no build" \
    "$(ci_request "ci-build $CI_SHA next")|$(tar -xOf "$CI_DIR/out.tar" ./ci-build.txt | grep '^next ')|$(
        [[ -e $CI_DIR/next.log ]] && echo build || echo 'no build')"
mkdir -p "$CIW/image/fedora"
cp "$APEX_ROOT/image/fedora/46.env" "$CIW/image/fedora/"
check "ci-build <sha> next builds the next release" 0 "$(ci_request "ci-build $CI_SHA next")"
check "as APEX_FEDORA=46, with no metrics" "build-image APEX_FEDORA=46" "$(cat "$CI_DIR/next.log")"
check_false "and no promotion" test -e "$CI_DIR/lane.log"
check "ci-build.txt names the release and the pair it could not take" \
    "next 46|build-image 0|pair unavailable for Fedora 46: no fedora-46 pins in packaging/pkgs/kernel|$(
        printf 'fallback gnome-shell at build.log (%s): rpmbuild failed' "$CI_DIR/store/next/pkgs/gnome-shell/last-failure.txt")|exit 0" \
    "$(tar -xOf "$CI_DIR/out.tar" ./ci-build.txt | grep -Ev '^(sha|started|finished) ' | paste -sd'|')"
check "next/ holds the base's version, the next lane's lock and each fallback's log" \
    "./next/build.env ./next/failures/gnome-shell.txt ./next/rpms.lock.next" \
    "$(tar -tf "$CI_DIR/out.tar" | grep '^\./next/.' | grep -v '/$' | sort | paste -sd' ')"
check "and never the 45 lane's lock" 0 "$(tar -tf "$CI_DIR/out.tar" | grep -c 'lock.diff')"
echo 1 >"$CI_DIR/build-rc"
check "a failed next build exits with its status and still returns its results" "1|build-image 1" \
    "$(ci_request "ci-build $CI_SHA next")|$(tar -xOf "$CI_DIR/out.tar" ./ci-build.txt | grep '^build-image ')"
echo 0 >"$CI_DIR/build-rc"
sed 's/^FEDORA=46$/FEDORA=47/' "$CIW/image/fedora/46.env" >"$CIW/image/fedora/47.env"
check "two next releases are an error, before any build" "1|no build" \
    "$(rm -f "$CI_DIR/next.log"; ci_request "ci-build $CI_SHA next")|$([[ -e $CI_DIR/next.log ]] && echo build || echo 'no build')"
rm -rf "$CIW/image" "$CIW/tools/builder-vm/metrics.sh" "$CI_DIR/store/next"
mv "$CI_DIR/build-image-45.sh" "$CIW/tools/builder-vm/build-image.sh"

# --- tools/components.sh: pinned full clones of components.lock, and the dev override ------
CO="$TMP/components"
mkdir -p "$CO/work/tools" "$CO/src"
cp "$APEX_ROOT/tools/components.sh" "$CO/work/tools/"
co_git() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=main "$@"; }
co_repo() {
    local name=$1
    co_git init -q "$CO/src/$name"
    echo one >"$CO/src/$name/a"
    co_git -C "$CO/src/$name" add a && co_git -C "$CO/src/$name" commit -qm one
    if [[ $name == apex-gnome ]]; then
        mkdir -p "$CO/src/$name/packaging/pkgs/gnome-shell"
        echo family=gnome-shell >"$CO/src/$name/packaging/pkgs/gnome-shell/pkg.env"
        co_git -C "$CO/src/$name" add packaging
    elif [[ $name == apex-kernel ]]; then
        mkdir -p "$CO/src/$name/packaging/libfprint"
        echo patch.patch >"$CO/src/$name/packaging/libfprint/series"
        co_git -C "$CO/src/$name" add packaging
    elif [[ $name == apex-desktop ]]; then
        mkdir -p "$CO/src/$name/packaging/pkgs/gnome-shell"
        echo family=shell >"$CO/src/$name/packaging/pkgs/gnome-shell/pkg.env"
        co_git -C "$CO/src/$name" add packaging
    fi
    echo two >"$CO/src/$name/a"
    co_git -C "$CO/src/$name" commit -qam two
    co_git clone -q --bare "$CO/src/$name" "$CO/$name.git"
}
co_repo apex-system
co_repo apex-desktop
co_repo apex-kernel
co_repo apex-gnome
CO_GNOME=$(git -C "$CO/src/apex-gnome" rev-parse HEAD)
CO_KERNEL=$(git -C "$CO/src/apex-kernel" rev-parse HEAD)
CO_SYS=$(git -C "$CO/src/apex-system" rev-parse HEAD)
CO_SYS_OLD=$(git -C "$CO/src/apex-system" rev-parse HEAD~1)
CO_DESK=$(git -C "$CO/src/apex-desktop" rev-parse HEAD)
components() { (cd "$CO/work" && rc_of tools/components.sh "$@"); }
co_out() { (cd "$CO/work" && tools/components.sh "$@" 2>/dev/null); }
co_lock() { printf '%s\n' "$@" >"$CO/work/components.lock"; }

check "no components.lock: fetch records none" 0 "$(components fetch)"
check "env: this checkout holds the recipes, nothing overridden" \
    "export APEX_KERNEL_SRC=$CO/work|export APEX_LANE_RECIPES=$CO/work|export APEX_COMPONENTS=pinned" "$(co_out env | paste -sd'|')"
check "and promotable" 0 "$(components promotable)"

co_lock '# components' '' "apex-system $CO/apex-system.git $CO_SYS_OLD" "apex-desktop $CO/apex-desktop.git $CO_DESK"
check "env refuses a state older than components.lock" 1 "$(components env)"
check "fetch clones each component at its commit" 0 "$(components fetch)"
check "apex-system is at its pinned commit" "$CO_SYS_OLD" "$(git -C "$CO/work/_build/components/apex-system" rev-parse HEAD)"
check "with the full history the lane counts" "2:false" \
    "$(git -C "$CO/work/_build/components/apex-system" rev-list --count --all):$(git -C "$CO/work/_build/components/apex-system" rev-parse --is-shallow-repository)"
check "env points at the clones, and at the recipes of apex-desktop" \
    "export APEX_SYSTEM_SRC=$CO/work/_build/components/apex-system|export APEX_DESKTOP_SRC=$CO/work/_build/components/apex-desktop|export APEX_KERNEL_SRC=$CO/work|export APEX_LANE_RECIPES=$CO/work:$CO/work/_build/components/apex-desktop|export APEX_COMPONENTS=pinned" \
    "$(co_out env | paste -sd'|')"
check "a pinned fetch is promotable" 0 "$(components promotable)"

echo stray >"$CO/work/_build/components/apex-system/stray"
co_lock "apex-system $CO/apex-system.git $CO_SYS" "apex-desktop $CO/apex-desktop.git $CO_DESK"
check "a new pin moves the clone and cleans it" "0:$CO_SYS:clean" \
    "$(components fetch):$(git -C "$CO/work/_build/components/apex-system" rev-parse HEAD):$([[ -e $CO/work/_build/components/apex-system/stray ]] && echo stray || echo clean)"

rm -rf "$CO/work/_build/components/apex-system"
git clone -q --depth 1 "file://$CO/apex-system.git" "$CO/work/_build/components/apex-system"
git -C "$CO/work/_build/components/apex-system" remote set-url origin "$CO/apex-system.git"
check "a shallow clone is deepened" "0:false" \
    "$(components fetch):$(git -C "$CO/work/_build/components/apex-system" rev-parse --is-shallow-repository)"

co_lock "apex-system $CO/apex-system.git $(printf 'c%.0s' {1..40})"
check "a commit the remote does not have fails" 1 "$(components fetch)"
check "and env refuses the state of the old lock" 1 "$(components env)"
for bad in "apex-system $CO/apex-system.git" "apex-system $CO/apex-system.git $CO_SYS extra" \
    "Apex-System $CO/apex-system.git $CO_SYS" "apex-system $CO/apex-system.git ${CO_SYS^^}" \
    "apex-system $CO/apex-system.git ${CO_SYS:1}" "apex-system --upload-pack=touch $CO_SYS" \
    "../x $CO/apex-system.git $CO_SYS"; do
    co_lock "$bad"
    check "components.lock line refused: $bad" 2 "$(components fetch)"
done
co_lock "apex-system $CO/apex-system.git $CO_SYS" "apex-system $CO/apex-system.git $CO_SYS"
check "a component listed twice is refused" 2 "$(components fetch)"
check "usage" 2 "$(components)"

co_lock "apex-system $CO/apex-system.git $CO_SYS" "apex-desktop $CO/apex-desktop.git $CO_DESK"
check "APEX_SRC_APEX_DESKTOP uses a sibling checkout" 0 \
    "$(cd "$CO/work" && APEX_SRC_APEX_DESKTOP=../src/apex-desktop rc_of tools/components.sh fetch)"
check "env names it and records dev-override" \
    "export APEX_DESKTOP_SRC=$CO/src/apex-desktop|export APEX_COMPONENTS=dev-override" \
    "$(co_out env | grep -E 'APEX_DESKTOP_SRC|APEX_COMPONENTS' | paste -sd'|')"
check "a dev-override is not promotable" 1 "$(components promotable)"
check "an override that is no directory fails" 1 \
    "$(cd "$CO/work" && APEX_SRC_APEX_SYSTEM=../nowhere rc_of tools/components.sh fetch)"
check "a pinned fetch makes it promotable again" "0:0" "$(components fetch):$(components promotable)"
co_lock "apex-system $CO/apex-system.git $CO_SYS" "apex-kernel $CO/apex-kernel.git $CO_KERNEL" \
    "apex-gnome $CO/apex-gnome.git $CO_GNOME"
check "APEX_KERNEL_SRC is the component that holds packaging/libfprint" \
    "0:export APEX_KERNEL_SRC=$CO/work/_build/components/apex-kernel" \
    "$(components fetch):$(co_out env | grep APEX_KERNEL_SRC)"
check "APEX_GNOME_SRC is apex-gnome, whose recipes the lane takes" \
    "export APEX_GNOME_SRC=$CO/work/_build/components/apex-gnome|export APEX_LANE_RECIPES=$CO/work:$CO/work/_build/components/apex-gnome" \
    "$(co_out env | grep -E 'APEX_GNOME_SRC|APEX_LANE_RECIPES' | paste -sd'|')"

# --- build-image.sh: each RPM from its pinned component, after components.sh fetch and env ---
BI="$TMP/build-image-components"
BIW=$BI/home/apex-image
mkdir -p "$BIW/tools/builder-vm" "$BIW/.github/scripts" "$BIW/image/packages"
cp "$APEX_ROOT/.github/scripts/lib.sh" "$BIW/.github/scripts/"
cp "$APEX_CONTAINERFILE" "$BIW/image/"
cp "$APEX_TESTING_ALLOWLIST" "$BIW/image/packages/"
cat >"$BIW/tools/components.sh" <<'EOF'
#!/usr/bin/env bash
echo "$1" >>"$FAKE/components.log"
[[ $1 != env ]] || printf 'export APEX_%s_SRC=/pinned/%s\n' SYSTEM system DESKTOP desktop KERNEL kernel
EOF
printf '#!/usr/bin/env bash\n' >"$BIW/tools/builder-vm/snapshot.sh"
cat >"$BIW/tools/builder-vm/lane.sh" <<'EOF'
#!/usr/bin/env bash
echo "lane.sh $*" >>"$FAKE/steps.log"
EOF
chmod +x "$BIW/tools/components.sh" "$BIW/tools/builder-vm/"*.sh
bi_main() {
    rm -f "$BI/components.log" "$BI/first-step" "$BI/steps.log"
    HOME=$BI/home FAKE=$BI bash -c '
        . "$1"
        sudo() { :; }
        build_inputs() { printf "%s|%s\n" "${APEX_SYSTEM_SRC:-unset}" "${APEX_KERNEL_SRC:-unset}" >"$FAKE/first-step"; }
        build_image() { :; }
        gate_g2() { :; }
        gate_g4() { G4_VERDICT=due; }
        main' _ "$APEX_ROOT/tools/builder-vm/build-image.sh" >/dev/null 2>&1
}
rm -f "$BIW/components.lock"
check "no components.lock: the build stops before its first step" "1|no step" \
    "$(rc_of bi_main)|$([[ -e $BI/first-step ]] && echo step || echo 'no step')"
echo "apex-kernel /x $CO_KERNEL" >"$BIW/components.lock"
(unset APEX_SYSTEM_SRC APEX_KERNEL_SRC; bi_main)
check "fetch, then env, in effect at the first build step" "fetch env|/pinned/system|/pinned/kernel" \
    "$(paste -sd' ' "$BI/components.log")|$(cat "$BI/first-step")"
(cd "$BIW" && rm -rf _build && FAKE=$BI APEX_SYSTEM_SRC=/pinned/system APEX_DESKTOP_SRC=/pinned/desktop \
    APEX_KERNEL_SRC=/pinned/kernel bash -c '
    . "$1"
    sudo() {
        [[ $1 == podman ]] || return 0
        local a out
        for a in "$@"; do [[ $a != /build/* ]] || out=$a; done
        mkdir -p "_build/${out#/build/}" && : >"_build/${out#/build/}/x.rpm"
        printf "%s\n" "$*" >>"$FAKE/steps.log"
    }
    build_inputs' _ "$APEX_ROOT/tools/builder-vm/build-image.sh") >/dev/null 2>&1
bi_podman() { grep "^podman run .* -v $1:/component:z " "$BI/steps.log" | grep -o ' registry.fedoraproject.org/fedora:45 .*'; }
check "the apex RPM: apex-system's rpms.sh, in its checkout" " registry.fedoraproject.org/fedora:45 .github/scripts/rpms.sh build /build/rpms/apex" \
    "$(bi_podman /pinned/system)"
check "apex-desktop: apex-desktop's rpms.sh" " registry.fedoraproject.org/fedora:45 .github/scripts/rpms.sh build /build/rpms/desktop" \
    "$(bi_podman /pinned/desktop)"
check "libfprint: apex-kernel's libfprint.sh" " registry.fedoraproject.org/fedora:45 .github/scripts/libfprint.sh build /build/libfprint" \
    "$(bi_podman /pinned/kernel)"
check "libfprint gets this image's GA_REACHED and updates-testing allowlist" \
    "-e GA_REACHED=$(ga_reached) -e TESTING_INCLUDEPKGS=$(testing_includepkgs)" \
    "$(grep -o -- '-e GA_REACHED=.* registry' "$BI/steps.log" | sed 's/ registry$//')"
check "only libfprint gets them" 1 "$(grep -c -- '-e GA_REACHED=' "$BI/steps.log")"
check "every RPM is signed, then the lane builds" "sign _build/rpms/apex/x.rpm|sign _build/rpms/desktop/x.rpm|sign _build/libfprint/x.rpm|build all" \
    "$(sed -n 's/^lane.sh //p' "$BI/steps.log" | paste -sd'|')"

bi_sources() {
    rm -f "$BI/steps.log"
    mkdir -p "$BIW/_build/image/sources"
    (cd "$BIW" && FAKE=$BI APEX_STORE=/store bash -c '. "$1"; source_artifact' \
        _ "$APEX_ROOT/tools/builder-vm/build-image.sh") >/dev/null 2>&1
}
bi_sources
check "the pair's source artifact goes next to the image" "sources --lock /store/rpms.lock.next --out _build/image/sources" \
    "$(sed -n 's/^lane.sh //p' "$BI/steps.log")"
APEX_KERNEL=fedora bi_sources
check "a break-glass image writes none, and leaves no stale one" "no call|no dir" \
    "$([[ -e $BI/steps.log ]] && echo call || echo 'no call')|$([[ -e $BIW/_build/image/sources ]] && echo dir || echo 'no dir')"

# The next lane (APEX_FEDORA=46): its own fedora, _build and store, then G1 only.
mkdir -p "$BIW/image/fedora"
cp "$APEX_ROOT/image/fedora/46.env" "$BIW/image/fedora/"
NEXT_REPOS_BASE=$(sed -n 's/^REPOS_BASE=//p' "$APEX_ROOT/image/fedora/46.env")
rm -f "$BI/steps.log" "$BI/next-gates"
# shellcheck disable=SC2016 # expanded by the inner bash
(cd "$BIW" && rm -rf _build && env HOME="$BI/home" FAKE="$BI" APEX_FEDORA=46 APEX_STORE=/store \
    APEX_SYSTEM_SRC=/pinned/system APEX_DESKTOP_SRC=/pinned/desktop APEX_KERNEL_SRC=/pinned/kernel bash -c '
    . "$1"
    sudo() {
        [[ $1 == podman ]] || return 0
        local a out
        for a in "$@"; do [[ $a != /build/* ]] || out=$a; done
        mkdir -p "$BUILD/${out#/build/}" && : >"$BUILD/${out#/build/}/x.rpm"
        printf "%s\n" "$*" >>"$FAKE/steps.log"
    }
    use_components() { :; }
    build_image() { printf "image %s %s\n" "$IMAGE" "$LANE_LOCK" >>"$FAKE/steps.log"; }
    gate_g2() { echo g2 >>"$FAKE/next-gates"; }
    gate_g4() { echo g4 >>"$FAKE/next-gates"; }
    record_gates() { echo record >>"$FAKE/next-gates"; }
    main' _ "$APEX_ROOT/tools/builder-vm/build-image.sh") >"$BI/next-out" 2>&1 || true
check "next: every component builds in 46.env's REPOS_BASE" 3 \
    "$(grep -c "^podman run .* -v $BIW/_build/next:/build:z .* $NEXT_REPOS_BASE " "$BI/steps.log")"
check "next: its RPMs are signed in _build/next, its lane builds" \
    "sign _build/next/rpms/apex/x.rpm|sign _build/next/rpms/desktop/x.rpm|sign _build/next/libfprint/x.rpm|build all" \
    "$(sed -n 's/^lane.sh //p' "$BI/steps.log" | paste -sd'|')"
check "next: the image is localhost/apex:46 from the next store's lane lock" \
    "image localhost/apex:46 /store/next/rpms.lock.next" \
    "$(grep '^image ' "$BI/steps.log")"
check "next: G1 only, so no G2, G4 or gates record" "no gates" "$(cat "$BI/next-gates" 2>/dev/null || echo 'no gates')"
check_true "and says so" grep -q 'the next lane gates on G1 only and records nothing' "$BI/next-out"
check_false "next: nothing lands in 45's _build/rpms" test -e "$BIW/_build/rpms"
check "next: libfprint gets 46.env's Fedora key, which apex-kernel's build needs past 45" 1 \
    "$(grep -c -- "-e FEDORA_KEY_FPR=$(sed -n 's/^FEDORA_KEY_FPR=//p' "$APEX_ROOT/image/fedora/46.env") " "$BI/steps.log")"

# --- qualify.sh: QMP over a unix socket ----------------------------------------------------
QMP_DIR="$TMP/qmp"
mkdir -p "$QMP_DIR"
cat >"$QMP_DIR/server.py" <<'EOF'
import json, os, socket, sys
path, log, error_on = sys.argv[1], sys.argv[2], sys.argv[3]
server = socket.socket(socket.AF_UNIX)
server.bind(path)
server.listen(1)
open(path + ".ready", "w").close()
conn, _ = server.accept()
stream = conn.makefile("rw")
stream.write(json.dumps({"QMP": {"version": {}}}) + "\n")
stream.flush()
with open(log, "w") as out:
    for line in stream:
        command = json.loads(line)
        out.write(line)
        out.flush()
        stream.write(json.dumps({"event": "X"}) + "\n")
        reply = {"error": {"class": "GenericError"}} if command["execute"] == error_on else {"return": {}}
        stream.write(json.dumps(reply) + "\n")
        stream.flush()
EOF
qmp_run() {
    local error_on=$1 rc=0
    shift
    rm -f "$QMP_DIR/sock" "$QMP_DIR/sock.ready"
    python3 "$QMP_DIR/server.py" "$QMP_DIR/sock" "$QMP_DIR/received" "$error_on" &
    local server=$!
    for _ in $(seq 50); do [[ -e $QMP_DIR/sock.ready ]] && break; sleep 0.1; done
    bash -c '. "$1"; QMP_SOCKET=$2; shift 2; qmp "$@"' _ "$APEX_ROOT/.github/scripts/qualify.sh" "$QMP_DIR/sock" "$@" >/dev/null 2>&1 || rc=$?
    wait "$server" 2>/dev/null || true
    printf '%s\n' "$rc"
}
check "qmp: commands over the socket" 0 "$(qmp_run none '{"execute":"send-key","arguments":{"keys":[]}}' '{"execute":"screendump"}')"
check "qmp: capabilities first, then each command in order" "qmp_capabilities send-key screendump" \
    "$(jq -r .execute "$QMP_DIR/received" | paste -sd' ')"
check "qmp: an error reply fails" 1 "$(qmp_run screendump '{"execute":"screendump"}')"
check_true "qemu: vmport is off, so the guest's mouse takes QMP's relative pointer moves" \
    grep -q -- '-machine q35,accel=kvm,vmport=off ' "$APEX_ROOT/.github/scripts/qualify.sh"

# --- qualify.sh: the guest-side session and GDM scripts, with a fake logind ---------------
LOGIND_DIR="$TMP/logind"
mkdir -p "$LOGIND_DIR/bin"
cat >"$LOGIND_DIR/bin/loginctl" <<'EOF'
#!/usr/bin/env bash
# As loginctl does, show-session prints the properties in its own order, not the order asked for.
case $1 in
    list-sessions) awk '{print $1, $6, $5, $3}' "$FAKE_SESSIONS" ;;
    show-session)
        read -r id class seat state name uid type < <(awk -v id="$2" '$1 == id' "$FAKE_SESSIONS")
        [[ -n ${id:-} ]] || exit 1
        printf 'Name=%s\nUser=%s\nType=%s\nClass=%s\nState=%s\nSeat=%s\n' \
            "$name" "$uid" "$type" "$class" "$state" "${seat#-}" ;;
    *) exit 2 ;;
esac
EOF
chmod +x "$LOGIND_DIR/bin/loginctl"
find_session() {
    PATH="$LOGIND_DIR/bin:$PATH" FAKE_SESSIONS="$LOGIND_DIR/sessions" bash -s -- "$@" \
        < <(bash -c '. "$1"; find_session_script' _ "$APEX_ROOT/.github/scripts/qualify.sh")
}
printf '%s\n' "2 user - active root 0 tty" "c1 greeter seat0 active gdm-greeter 60578 wayland" >"$LOGIND_DIR/sessions"
check "the greeter, not root's SSH session" "c1 60578 wayland" "$(find_session greeter)"
check_false "no user logged in yet" find_session user apexqa
printf '%s\n' "2 user - active root 0 tty" "5 user seat0 active bob 1001 wayland" \
    "3 user seat0 online apexqa 1000 wayland" "c1 greeter seat0 closing gdm-greeter 60578 wayland" >"$LOGIND_DIR/sessions"
check_false "an online session is not the active one" find_session user apexqa
check_false "a closing greeter is not GDM's greeter" find_session greeter
printf '4 user seat0 active apexqa 1000 wayland\n' >>"$LOGIND_DIR/sessions"
check "the test user's session, not another user's" "4 1000 wayland" "$(find_session user apexqa)"

# --- qualify.sh: bootloader-update, greeter login, lock and unlock against a fake guest ---
GUEST_DIR="$TMP/guest"
mkdir -p "$GUEST_DIR/out/logs"
cat >"$TMP/qualify-fake-guest.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
qualify_sh=$1
. "$qualify_sh"
STATE=$2
shift 2
from() { cat "$STATE/$1" 2>/dev/null || true; }
as_root() { [[ "$*" == "podman image inspect --format {{.Id}} localhost/apex:build" ]] && echo cafe; }
TEST_PASSWORD=$(from password)
conversations() { echo "${1:-$(from conversations)}" >"$STATE/conversations"; }
start_asking() {
    [[ ! -e $STATE/asking ]] || return 0
    : >"$STATE/asking"
    conversations "$(($(from conversations) + 1))"
}
stop_asking() {
    [[ -e $STATE/asking ]] || return 0
    rm "$STATE/asking"
    conversations "$(($(from conversations) - 1))"
}
password_typed() {
    if [[ "$TEST_USER:$(from typed)" != "$(from chpasswd)" ]]; then
        [[ -e $STATE/no-pam-log ]] || echo 'gdm-password]: pam_unix(gdm-password:auth): authentication failure' >>"$STATE/syslog"
        return 0
    fi
    if [[ $(from locked) == yes ]]; then
        echo no >"$STATE/locked"
        echo false >"$STATE/active"
        if [[ -e $STATE/js-error ]]; then echo 'gnome-shell[1234]: JS ERROR: TypeError: x is null' >>"$STATE/journal"; fi
    elif [[ -e $STATE/fault-file ]]; then
        if [[ ! -e $STATE/guard-broken ]]; then
            : >"$STATE/tripped"
            printf '%s\n' 'Apex: APEX_SHELL_TEST_FAULT=abort-after-enable: aborting the shell' \
                'Finished apex-shell-safe.service - Turn the Apex desktop layer off' >>"$STATE/journal"
        fi
    else
        cp "$STATE/session-after-login" "$STATE/session"
        : >"$STATE/manager-active"
        if [[ -e $STATE/safe-booted ]]; then echo 'Apex: safe mode (apex.safe=1)' >>"$STATE/journal"; fi
        if [[ -e $STATE/tripped ]]; then echo 'Apex: safe mode (layer-enabled is false)' >>"$STATE/journal"; fi
        if [[ -e $STATE/safe-js-error ]]; then echo 'gnome-shell[1236]: JS ERROR: TypeError: y is null' >>"$STATE/journal"; fi
    fi
    conversations "$(($(from conversations) - 1))"
    rm -f "$STATE/asking"
}
pkexec_typed() {
    if [[ "$TEST_USER:$(from typed)" == "$(from chpasswd)" ]]; then
        if [[ -e $STATE/pkexec-not-root ]]; then echo 1000 >"$STATE/pkexec.out"; else echo 0 >"$STATE/pkexec.out"; fi
        echo 0 >"$STATE/pkexec.rc"
        echo 0 >"$STATE/polkit"
        rm -f "$STATE/pkexec-running"
        return 0
    fi
    [[ -e $STATE/no-polkit-log ]] ||
        echo 'pam_unix(polkit-1:auth): authentication failure; logname= uid=1000 euid=0 tty= ruser=apexqa rhost=  user=apexqa' >>"$STATE/polkit-pam"
    if [[ -e $STATE/wrong-ends-pkexec ]]; then echo 127 >"$STATE/pkexec.rc"; rm -f "$STATE/pkexec-running"; fi
    if [[ -e $STATE/no-retry ]]; then echo 0 >"$STATE/polkit"; fi
}
qmp_query() { if [[ -e $STATE/suspended ]]; then echo '{"status":"suspended"}'; else echo '{"status":"running"}'; fi; }
wait_ssh() { :; }
vm_reboot() {
    : >"$STATE/journal"
    : >"$STATE/syslog"
    rm -f "$STATE/session" "$STATE/asking" "$STATE/manager-active"
    conversations 0
    echo 'c1 60578 wayland' >"$STATE/greeter"
    if [[ -e $STATE/karg && ! -e $STATE/safe-ignored ]]; then
        : >"$STATE/safe-booted"
        rm -f "$STATE/apex-lock"
    fi
}
qmp() {
    local cmd keys
    [[ ! -e $STATE/qmp-down ]] || return 1
    for cmd in "$@"; do
        printf '%s\n' "$cmd" >>"$STATE/qmp"
        if [[ $cmd == *system_wakeup* ]]; then
            rm -f "$STATE/suspended"
            if [[ -e $STATE/resume-unlocks ]]; then echo no >"$STATE/locked"; echo false >"$STATE/active"; fi
        fi
        keys=$(jq -r 'select(.execute == "send-key") | [.arguments.keys[].data] | join("+")' <<<"$cmd")
        case $keys in
            "") ;;
            ret)
                if [[ -e $STATE/ret-lost ]]; then
                    rm "$STATE/ret-lost"
                elif [[ -e $STATE/pkexec-running ]]; then
                    pkexec_typed
                    : >"$STATE/typed"
                elif [[ -s $STATE/typed ]]; then
                    password_typed
                    : >"$STATE/typed"
                elif [[ -e $STATE/takes-keys ]]; then
                    start_asking
                fi ;;
            esc)
                if [[ -e $STATE/pkexec-running ]]; then
                    [[ -e $STATE/esc-ignored ]] && continue
                    if [[ -e $STATE/cancel-127 ]]; then echo 127 >"$STATE/pkexec.rc"; else echo 126 >"$STATE/pkexec.rc"; fi
                    [[ -e $STATE/no-polkitd-log ]] ||
                        echo 'Operator of unix-session:4 FAILED to authenticate to gain authorization for action org.freedesktop.policykit.exec for unix-process:4321:1 [pkexec /usr/bin/id -u] (owned by unix-user:apexqa)' >>"$STATE/polkit-log"
                    [[ -e $STATE/cancel-keeps-helper ]] || echo 0 >"$STATE/polkit"
                    rm -f "$STATE/pkexec-running"
                else
                    [[ -e $STATE/esc-ignored ]] || stop_asking
                fi ;;
            *) printf '%s' "$keys" >>"$STATE/typed" ;;
        esac
    done
}
login_only() { wait_session "$1-login" user "$TEST_USER"; assert_apex_login "$1-login" 1000; }
# journalctl -b -o short-monotonic -g 'PATTERN' [_UID=N] over $STATE/mono's "SECONDS UID MESSAGE"
# lines; like journalctl, no match exits 1.
mono_journal() {
    local pat=${1#*-g \'} uid=
    pat=${pat%%\'*}
    [[ $1 != *_UID=* ]] || { uid=${1##*_UID=}; uid=${uid%% *}; }
    awk -v p="$pat" -v u="$uid" '$0 ~ p && (u == "" || $2 == u) {
        m = $0; sub(/^[^ ]+ [^ ]+ /, "", m); printf "[%12s] guest %s\n", $1, m }' "$STATE/mono" 2>/dev/null | grep .
}
user_cmd() { printf 'runuser -u %s -- env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus %s' "$TEST_USER" "$1"; }
vm_ssh() {
    local cmd="$*"
    case $cmd in
        "test -f $BOOTLOADER_GATE") [[ -e $STATE/gated ]] ;;
        "systemctl show -p Job --value $BOOTLOADER_UNIT") from job ;;
        "systemctl show $BOOTLOADER_UNIT -p "*) from bootloader.props ;;
        "systemctl show $ASSESS_UNIT -p ExecMainExitTimestampMonotonic") from assess.props ;;
        "journalctl --list-boots --no-pager 2>/dev/null") from boots ;;
        "journalctl -b "*" SYSLOG_IDENTIFIER=bootupctl "*) b=${cmd#journalctl -b }; from "bootupctl.${b%% *}" ;;
        "journalctl -b 0 _SYSTEMD_UNIT=$BOOTLOADER_UNIT SYSLOG_IDENTIFIER=sh "*) from condition ;;
        "journalctl -b 0 UNIT=$BOOTLOADER_UNIT UNIT_RESULT=exec-condition "*) from skipped ;;
        "journalctl -b 0 _PID=1 "*"ordering cycle"*) from cycle ;;
        "journalctl -b -u "*) ;;
        "bash -s -- user $TEST_USER") from session | grep . ;;
        "chpasswd") cat >"$STATE/chpasswd" ;;
        "pgrep -c -f 'pam/gdm-passwor[d]'") echo "$(from conversations)"; (($(from conversations) > 0)) ;;
        "bash -s -- greeter"*) from greeter | grep . ;;
        "systemctl is-active --quiet gdm.service") [[ ! -e $STATE/gdm-down ]] ;;
        "pgrep -u 60578 -x gnome-shell") from greeter-pid | grep . ;;
        "journalctl -b _UID=60578 _COMM=systemd -o short-monotonic --no-pager") from greeter-manager ;;
        "rm -rf $GUEST_TMP/candidate && mkdir -p $GUEST_TMP/candidate") ;;
        "cat > $GUEST_TMP/candidate/manifest.json && chmod 0644 $GUEST_TMP/candidate/manifest.json") cat >"$STATE/built-manifest" ;;
        "cat > $GUEST_TMP/candidate/Containerfile") cat >"$STATE/built-containerfile" ;;
        "timeout 1800 bootc image copy-to-storage") ;;
        "timeout 1800 podman build --pull=never --tag $LOCAL_CANDIDATE $GUEST_TMP/candidate") ;;
        "timeout 3600 bootc switch --transport containers-storage --download-only $LOCAL_CANDIDATE") ;;
        "podman rmi $LOCAL_CANDIDATE localhost/bootc >/dev/null") ;;
        "bootc status --format=json --format-version=1") from status ;;
        "grub2-editenv /boot/grub2/grubenv list") echo apex_ok=0 ;;
        *"org.gnome.ScreenSaver.GetActive"*) printf '(%s,)\n' "$(from active)" ;;
        "pgrep -u 1000 -x gnome-shell") from pid ;;
        "date +%s") echo 1000 ;;
        "journalctl -b _UID=1000 --since @999 -o short-monotonic --no-pager") from journal ;;
        "test -e /run/user/1000/$CRASH_GUARD_MARKER") [[ -e $STATE/marker ]] ;;
        "$(user_cmd 'gsettings get org.gnome.desktop.interface color-scheme')") from scheme ;;
        "$(user_cmd "gsettings get $APEX_SCHEMA layer-enabled")") if [[ -e $STATE/tripped ]]; then echo false; else echo true; fi ;;
        "$(user_cmd "systemctl --user list-units --state=active --plain --no-legend --no-pager 'apex*'")") from agents ;;
        "$(user_cmd "systemctl --user list-units --state=failed --plain --no-legend --no-pager 'apex*'")") from apex-failed ;;
        "$(user_cmd 'systemctl --user show -p ActiveState,SubState,NRestarts --no-pager apex-session-agent.service')") from agent-props ;;
        "$(user_cmd 'systemctl --user show -p ActiveState,Result,ExecMainCode,ExecMainStatus --no-pager apex-folder-icons.service')") from icons-props ;;
        "loginctl show-session 4 -p LockedHint --value") from locked ;;
        "loginctl lock-session 4")
            [[ -e $STATE/never-locks ]] || { echo yes >"$STATE/locked"; echo true >"$STATE/active"; rm -f "$STATE/asking"; }
            if [[ -e $STATE/apex-lock ]]; then start_asking; fi ;;
        "pgrep -c -f 'pam/gdm-fingerprin[t]'") n=$(from fingerprints); echo "${n:-0}"; ((${n:-0} > 0)) ;;
        "journalctl -b _UID=1000 --since @999 -o cat --no-pager") from journal ;;
        "journalctl -k -b --since @999 -o cat --no-pager" | "journalctl -k -b --since @999 -o short-monotonic --no-pager") from kernel ;;
        "journalctl -b _UID=1000 -n 1 -o cat --no-pager --show-cursor") echo "-- cursor: $(from journal | wc -l)" ;;
        "journalctl -b _UID=1000 --after-cursor="*)
            c=${cmd#*--after-cursor=\'}
            from journal | tail -n "+$((${c%%\'*} + 1))" ;;
        "journalctl -b --since @999 -o cat --no-pager --grep 'authentication failure'") from syslog | grep . ;;
        *"PowerSaveMode i 3")
            [[ -e $STATE/keeps-asking-blank ]] || stop_asking
            [[ -e $STATE/keeps-asking-blank || -e $STATE/blank-unlogged ]] ||
                echo 'Apex: lock: screen blank, prompt torn down' >>"$STATE/journal" ;;
        *"PowerSaveMode i 0")
            [[ -e $STATE/wake-unlogged ]] || echo 'Apex: lock: screen on, prompt rebuilt' >>"$STATE/journal"
            start_asking ;;
        "systemd-run --quiet --on-active=2 systemctl suspend") [[ -e $STATE/no-suspend ]] || : >"$STATE/suspended" ;;
        *"gsettings set org.gnome.desktop.a11y.interface reduced-motion \"'reduce'\"")
            if [[ -e $STATE/motion-js-error ]]; then echo 'gnome-shell[1234]: JS ERROR: TypeError: motion' >>"$STATE/journal"; fi ;;
        *"gsettings reset org.gnome.desktop.a11y.interface reduced-motion") ;;
        *"gsettings set $APEX_SCHEMA layer-enabled true") ;;
        "rpm-ostree kargs --append=apex.safe=1") : >"$STATE/karg" ;;
        "grep -qw apex.safe=1 /proc/cmdline") [[ -e $STATE/safe-booted ]] ;;
        "loginctl unlock-session 4")
            echo no >"$STATE/locked"
            echo false >"$STATE/active"
            if [[ -e $STATE/crash ]]; then echo 1235 >"$STATE/pid"; fi
            if [[ -e $STATE/js-error ]]; then echo 'gnome-shell[1234]: JS ERROR: TypeError: x is null' >>"$STATE/journal"; fi ;;
        "loginctl terminate-user $TEST_USER")
            rm -f "$STATE/session" "$STATE/manager-active" "$STATE/asking"
            conversations 0 ;;
        "systemctl -q is-active user@1000.service") [[ -e $STATE/manager-active ]] ;;
        "id -u $TEST_USER") echo 1000 ;;
        "runuser -u $TEST_USER -- sh -c 'mkdir -p ~$TEST_USER/.config/environment.d && echo APEX_SHELL_TEST_FAULT=abort-after-enable >~$TEST_USER/$TEST_FAULT_FILE'")
            : >"$STATE/fault-file" ;;
        "test -e ~$TEST_USER/$CRASH_GUARD_TRIPPED") [[ -e $STATE/tripped ]] ;;
        "rm -f ~$TEST_USER/$TEST_FAULT_FILE") rm -f "$STATE/fault-file" ;;
        *"systemctl --user list-units --state=failed"*) from failed-user-units ;;
        "cat $MANIFEST") from manifest ;;
        "usermod -aG wheel $TEST_USER") : >"$STATE/wheel" ;;
        "rm -f /run/user/1000/$PKEXEC_UNIT.rc /run/user/1000/$PKEXEC_UNIT.out") rm -f "$STATE/pkexec.rc" "$STATE/pkexec.out" ;;
        "$(user_cmd "systemd-run --user --quiet --collect --unit=$PKEXEC_UNIT sh -c 'pkexec /usr/bin/id -u >\$XDG_RUNTIME_DIR/$PKEXEC_UNIT.out 2>&1; echo \$? >\$XDG_RUNTIME_DIR/$PKEXEC_UNIT.rc'")")
            : >"$STATE/pkexec-running"
            [[ -e $STATE/no-agent ]] || echo 1 >"$STATE/polkit" ;;
        "pgrep -c -f 'polkit-agent-helpe[r]'") n=$(from polkit); echo "${n:-0}"; ((${n:-0} > 0)) ;;
        "cat /run/user/1000/$PKEXEC_UNIT.rc") from pkexec.rc | grep . ;;
        "cat /run/user/1000/$PKEXEC_UNIT.out") from pkexec.out ;;
        "journalctl -b --since @999 -o cat --no-pager --grep 'pam_unix\(polkit-1:auth\): authentication failure'") from polkit-pam | grep . ;;
        "journalctl -b --since @999 -o cat --no-pager --grep 'FAILED to authenticate to gain authorization for action org.freedesktop.policykit.exec'")
            from polkit-log | grep . ;;
        "cat $POLKIT_ACTIONS") from policies | grep . ;;
        "pkaction --action-id "*" --verbose")
            id=${cmd#pkaction --action-id }
            id=${id% --verbose}
            [[ ! -e $STATE/unloaded-$id ]] || { echo "No action with action id $id"; return 1; }
            printf '%s:\n  description:       x\n  vendor:            %s\n  vendor_url:        https://github.com/apex-linux\n' \
                "$id" "$(cat "$STATE/vendor-$id" 2>/dev/null || echo Apex)" ;;
        "sh -s") cat >/dev/null; from key ;;
        "systemd-analyze") from analyze | grep . ;;
        "systemd-analyze blame --no-pager | head -n 10") from blame ;;
        "journalctl -b -q --no-pager -o short-monotonic "*) mono_journal "$cmd" ;;
        *) printf 'unexpected vm_ssh: %s\n' "$cmd" >&2; return 99 ;;
    esac
}
"$@"
EOF
guest() {
    local rc=0
    : >"$GUEST_DIR/out/results.md"
    QUALIFY_OUT="$GUEST_DIR/out" QUALIFY_POLL=0.01 QUALIFY_LOGIN_TIMEOUT=2 QUALIFY_LOCK_TIMEOUT=2 \
        QUALIFY_G4_RECORD="$GUEST_DIR/record" GITHUB_ACTIONS='' APEX_GNOME_SRC="$GUEST_DIR/gnome" \
        bash "$TMP/qualify-fake-guest.sh" "$APEX_ROOT/.github/scripts/qualify.sh" "$GUEST_DIR/state" "$@" \
        >"$GUEST_DIR/stderr" 2>&1 || rc=$?
    printf '%s\n' "$rc"
}
row() {
    local test=$1 verdict=$2
    grep -c "^| $test | $verdict |" "$GUEST_DIR/out/results.md" || true
}
green_boot() {
    rm -rf "$GUEST_DIR/state"
    mkdir -p "$GUEST_DIR/state"
    : >"$GUEST_DIR/state/gated"
    printf '%s\n' ActiveState=active Result=success ExecMainStatus=0 ExecMainStartTimestampMonotonic=200000000 \
        >"$GUEST_DIR/state/bootloader.props"
    echo ExecMainExitTimestampMonotonic=150000000 >"$GUEST_DIR/state/assess.props"
    echo 'No update available for any component.' >"$GUEST_DIR/state/bootupctl.0"
}

green_boot
check "green boot: bootupctl ran after the assessment" 0 "$(guest assert_bootloader_updated t)"
check_true "and the row says so" grep -q '^| t-bootloader | PASS | bootupctl ran 50000 ms after the green assessment and succeeded: No update available' "$GUEST_DIR/out/results.md"
green_boot
sed -i 's/=200000000/=100000000/' "$GUEST_DIR/state/bootloader.props"
check "green boot: bootupctl before the assessment fails" 1 "$(guest assert_bootloader_updated t)"
check "with a FAIL row" 1 "$(row t-bootloader FAIL)"
green_boot
printf '%s\n' ActiveState=inactive Result=exec-condition ExecMainStatus=0 ExecMainStartTimestampMonotonic=0 \
    >"$GUEST_DIR/state/bootloader.props"
check "green boot: a skipped update fails" 1 "$(guest assert_bootloader_updated t)"
green_boot
sed -i 's/Result=success/Result=exit-code/; s/ExecMainStatus=0/ExecMainStatus=1/' "$GUEST_DIR/state/bootloader.props"
check "green boot: a failed bootupctl fails" 1 "$(guest assert_bootloader_updated t)"
green_boot
rm "$GUEST_DIR/state/gated"
check "green boot: an image without the drop-in fails" 1 "$(guest assert_bootloader_updated t)"
green_boot
rm "$GUEST_DIR/state/bootupctl.0"
check "green boot: no bootupctl line in the journal fails (the red check would prove nothing)" 1 \
    "$(guest assert_bootloader_updated t)"
green_boot
echo 'bootloader-update.service: Job apex-boot-assess.service/start deleted to break ordering cycle starting with bootloader-update.service/start' \
    >"$GUEST_DIR/state/cycle"
check "green boot: an ordering cycle at boot fails" 1 "$(guest assert_bootloader_updated t)"
check_true "and the row quotes systemd" grep -q '^| t-bootloader | FAIL | systemd broke an ordering cycle at boot: bootloader-update' "$GUEST_DIR/out/results.md"

red_boot() {
    green_boot
    rm "$GUEST_DIR/state/bootupctl.0"
    printf '%s\n' ActiveState=inactive Result=exec-condition ExecMainStartTimestampMonotonic=0 >"$GUEST_DIR/state/bootloader.props"
    echo 'apex-boot-assess.service did not judge this boot green ( INFO decision: fallback (report fallback)): the ESP is left alone' \
        >"$GUEST_DIR/state/condition"
}
red_boot
check "red boot: skipped by its condition" 0 "$(guest assert_bootloader_skipped t)"
check_true "and the row quotes the condition" grep -q '^| t-bootloader | PASS | skipped by its condition: apex-boot-assess.service did not judge' "$GUEST_DIR/out/results.md"
red_boot
printf '%s\n' ActiveState=active Result=success ExecMainStartTimestampMonotonic=90000000 >"$GUEST_DIR/state/bootloader.props"
check "red boot: bootupctl ran, which fails" 1 "$(guest assert_bootloader_skipped t)"
red_boot
echo 'Updated EFI: grub2-1:2.12-78.fc45.x86_64,shim-16.1-7.x86_64' >"$GUEST_DIR/state/bootupctl.0"
check "red boot: a bootupctl line alone fails" 1 "$(guest assert_bootloader_skipped t)"
red_boot
printf '%s\n' ActiveState=inactive Result=success ExecMainStartTimestampMonotonic=0 >"$GUEST_DIR/state/bootloader.props"
check "red boot: a unit that never started is not the condition's skip" 1 "$(guest assert_bootloader_skipped t)"
echo "bootloader-update.service: Skipped due to 'exec-condition'." >"$GUEST_DIR/state/skipped"
check "red boot: an unloaded unit whose skip systemd logged" 0 "$(guest assert_bootloader_skipped t)"

red_boot
printf '%s\n' ' -3 a' ' -2 b' ' -1 c' '  0 d' >"$GUEST_DIR/state/boots"
check "the three red boots before: bootupctl silent" 0 "$(guest assert_bootloader_quiet_before t 3)"
echo 'No update available for any component.' >"$GUEST_DIR/state/bootupctl.-2"
check "bootupctl in one of them fails" 1 "$(guest assert_bootloader_quiet_before t 3)"
check_true "naming that boot" grep -q '^| t-bootloader | FAIL | bootupctl ran in the red boots -2 ' "$GUEST_DIR/out/results.md"
printf '  0 d\n' >"$GUEST_DIR/state/boots"
check "a volatile journal skips the check" 0 "$(guest assert_bootloader_quiet_before t 3)"
check "with a SKIP row" 1 "$(row t-bootloader SKIP)"

rm -rf "$GUEST_DIR/state"
mkdir -p "$GUEST_DIR/state"
echo 'c1 60578 wayland' >"$GUEST_DIR/state/greeter"
echo 4321 >"$GUEST_DIR/state/greeter-pid"
cat >"$GUEST_DIR/state/greeter-manager" <<'EOF'
[    9.701] guest systemd[811]: apex-folder-icons.service - Set the Apex icons of the Projects and Screenshots folders was skipped because of an unmet condition check (ConditionEnvironment=XDG_SESSION_CLASS=user).
[    9.702] guest systemd[811]: apex-session-agent.service - Apex session agent was skipped because of an unmet condition check (ConditionEnvironment=XDG_SESSION_CLASS=user).
[    9.705] guest systemd[811]: Started org.gnome.Shell@gdm.service - GNOME Shell on Wayland.
[    9.710] guest systemd[811]: Reached target graphical-session.target - Current graphical user session.
EOF
cp "$GUEST_DIR/state/greeter-manager" "$GUEST_DIR/greeter-manager.ok"
check "GDM's greeter with its gnome-shell" 0 "$(guest assert_greeter local)"
check "passes" 1 "$(row local-greeter PASS)"
check_true "and says no Apex user unit started" grep -q '^| local-greeter | PASS | .*whose user manager started no Apex user unit' "$GUEST_DIR/out/results.md"
echo '[    9.703] guest systemd[811]: Started apex-session-agent.service - Apex session agent.' >>"$GUEST_DIR/state/greeter-manager"
check "an Apex agent started in the greeter fails" 1 "$(guest assert_greeter local)"
check_true "and quotes it" grep -q '^| local-greeter | FAIL | an Apex user unit started in the greeter: .*Started apex-session-agent.service' "$GUEST_DIR/out/results.md"
cp "$GUEST_DIR/greeter-manager.ok" "$GUEST_DIR/state/greeter-manager"
echo '[    9.703] guest systemd[811]: Starting apex-folder-icons.service - Set the Apex icons...' >>"$GUEST_DIR/state/greeter-manager"
check "a oneshot Apex unit that ran in the greeter fails" 1 "$(guest assert_greeter local)"
grep -v 'Reached target' "$GUEST_DIR/greeter-manager.ok" >"$GUEST_DIR/state/greeter-manager"
check "a greeter manager read before graphical-session.target fails" 1 "$(guest assert_greeter local)"
check_true "and names the target" grep -q "^| local-greeter | FAIL | the greeter's user manager (uid 60578) never reached graphical-session.target" "$GUEST_DIR/out/results.md"
echo '-- No entries --' >"$GUEST_DIR/state/greeter-manager"
check "a greeter manager that logged nothing fails" 1 "$(guest assert_greeter local)"
cp "$GUEST_DIR/greeter-manager.ok" "$GUEST_DIR/state/greeter-manager"
: >"$GUEST_DIR/state/greeter-pid"
check "a greeter session without gnome-shell fails" 1 "$(guest assert_greeter local)"
echo 4321 >"$GUEST_DIR/state/greeter-pid"
: >"$GUEST_DIR/state/gdm-down"
check "gdm.service down fails" 1 "$(guest assert_greeter local)"
rm "$GUEST_DIR/state/greeter"
check "no greeter session fails" 1 "$(guest assert_greeter local)"

rm -rf "$GUEST_DIR/state"
mkdir -p "$GUEST_DIR/state"
check "a password for the test user" 0 "$(guest set_test_password local)"
check_true "set with chpasswd, 24 hex digits" grep -Eqx 'apexqa:[0-9a-f]{24}' "$GUEST_DIR/state/chpasswd"
check_false "and in no row" grep -qF "$(cut -d: -f2 "$GUEST_DIR/state/chpasswd")" "$GUEST_DIR/out/results.md"
check_false "nor on the console" grep -qF "$(cut -d: -f2 "$GUEST_DIR/state/chpasswd")" "$GUEST_DIR/stderr"
qualify_fn() { bash -c '. "$1"; shift; "$@"' _ "$APEX_ROOT/.github/scripts/qualify.sh" "$@"; }
check "Enter in QMP" '{"execute":"send-key","arguments":{"keys":[{"type":"qcode","data":"ret"}]}}' "$(qualify_fn key_press ret)"
check_true "a chord is one command" jq -e '.arguments.keys == [{type: "qcode", data: "ctrl"}, {type: "qcode", data: "a"}]' \
    <<<"$(qualify_fn key_press ctrl a)"
check "typing a0f" 0 "$(guest type_text a0f)"
check "is three presses, in order" "a 0 f" "$(jq -r '.arguments.keys[].data' "$GUEST_DIR/state/qmp" | paste -sd' ')"
check "a key without a qcode of its own is refused" 1 "$(guest type_text aB)"

at_greeter() {
    rm -rf "$GUEST_DIR/state"
    mkdir -p "$GUEST_DIR/state"
    echo 'c1 60578 wayland' >"$GUEST_DIR/state/greeter"
    : >"$GUEST_DIR/state/takes-keys"
    echo 0 >"$GUEST_DIR/state/conversations"
    echo 0123456789abcdef01234567 >"$GUEST_DIR/state/password"
    echo apexqa:0123456789abcdef01234567 >"$GUEST_DIR/state/chpasswd"
    echo '4 1000 wayland' >"$GUEST_DIR/state/session-after-login"
}
keys_sent() { jq -r 'select(.execute == "send-key") | .arguments.keys[0].data' "$GUEST_DIR/state/qmp" | paste -sd' '; }
at_greeter
check "the login through GDM's greeter" 0 "$(guest greeter_login local)"
check "passes" 1 "$(row local-greeter-login PASS)"
check "Enter, the password, Enter" "ret 0 1 2 3 4 5 6 7 8 9 a b c d e f 0 1 2 3 4 5 6 7 ret" "$(keys_sent)"
check_true "with a screendump of the prompt" grep -qF "\"filename\":\"$GUEST_DIR/out/logs/local-greeter-login.png\"" "$GUEST_DIR/state/qmp"
at_greeter
rm "$GUEST_DIR/state/takes-keys"
check "a greeter that starts no password conversation fails" 1 "$(guest greeter_login local)"
check_true "and says so" grep -q '^| local-greeter-login | FAIL | GDM started no password conversation' "$GUEST_DIR/out/results.md"
at_greeter
echo apexqa:ffffffffffffffffffffffff >"$GUEST_DIR/state/chpasswd"
check "a password GDM does not take fails" 1 "$(guest greeter_login local)"
check "at the login" 1 "$(row local-greeter-login FAIL)"
at_greeter
: >"$GUEST_DIR/state/qmp-down"
check "no QMP fails" 1 "$(guest greeter_login local)"
check_true "naming the socket" grep -q '^| local-greeter-login | FAIL | QEMU took no key on its QMP socket' "$GUEST_DIR/out/results.md"
at_greeter
rm "$GUEST_DIR/state/greeter"
check "no greeter fails" 1 "$(guest greeter_login local)"

D0="sha256:$(printf '0%.0s' {1..64})"
manifest='{"schema": 1, "version": "45.20260929.0", "packages": [{"name": "gdm", "version": "51.0"}]}'
staged() {
    local digest=$1 download_only=$2
    jq -n --arg d "$digest" --argjson o "$download_only" '{status: {staged: {image: {imageDigest: $d}, downloadOnly: $o}}}' >"$GUEST_DIR/state/status"
}
rm -rf "$GUEST_DIR/state"
mkdir -p "$GUEST_DIR/state"
printf '%s\n' "$manifest" >"$GUEST_DIR/state/manifest"
staged "$D1" true
check "a newer image derived in the guest is staged" 0 "$(guest stage_local_candidate local-stage "$D0")"
check "its manifest version extends the booted one" 45.20260929.0.1 "$(jq -r .version "$GUEST_DIR/state/built-manifest")"
check "and nothing else changes in it" "$(jq -S 'del(.version)' <<<"$manifest")" "$(jq -S 'del(.version)' "$GUEST_DIR/state/built-manifest")"
check "the candidate is the booted image plus that manifest, labelled with its version" \
    "FROM localhost/bootc|COPY manifest.json /usr/share/apex/manifest.json|LABEL org.opencontainers.image.version=45.20260929.0.1" \
    "$(paste -sd'|' "$GUEST_DIR/state/built-containerfile")"
check_true "the row names the staged digest" grep -qF "| local-stage | PASS | staged localhost/apex-qualify:candidate ($D1, version 45.20260929.0.1)" "$GUEST_DIR/out/results.md"
staged "$D0" true
check "a candidate with the booted digest fails" 1 "$(guest stage_local_candidate local-stage "$D0")"
staged "$D1" false
check "a candidate that is not download-only fails" 1 "$(guest stage_local_candidate local-stage "$D0")"
staged "" true
check "no staged digest fails" 1 "$(guest stage_local_candidate local-stage "$D0")"
jq 'del(.version)' <<<"$manifest" >"$GUEST_DIR/state/manifest"
staged "$D1" true
check "a booted manifest without a version fails" 1 "$(guest stage_local_candidate local-stage "$D0")"

logged_in() {
    at_greeter
    rm "$GUEST_DIR/state/greeter"
    cp "$GUEST_DIR/state/session-after-login" "$GUEST_DIR/state/session"
    : >"$GUEST_DIR/state/manager-active"
    echo 1 >"$GUEST_DIR/state/conversations"
    echo false >"$GUEST_DIR/state/active"
    echo no >"$GUEST_DIR/state/locked"
    echo 1234 >"$GUEST_DIR/state/pid"
    echo "'default'" >"$GUEST_DIR/state/scheme"
    : >"$GUEST_DIR/state/marker"
    echo 'gnome-shell[1234]: Extension manager started' >"$GUEST_DIR/state/journal"
    echo 'apex-session-agent.service loaded active running Apex session agent' >"$GUEST_DIR/state/agents"
    printf '%s\n' SubState=running NRestarts=0 ActiveState=active >"$GUEST_DIR/state/agent-props"
    printf '%s\n' Result=success ExecMainStatus=0 ExecMainCode=1 ActiveState=inactive >"$GUEST_DIR/state/icons-props"
}
logged_in
check "login with the Apex layer, lock, and both unlocks" 0 "$(guest login_lock_unlock local)"
for r in local-login local-lock local-unlock local-unlock-signal local-user-units; do
    check "row $r passes" 1 "$(row "$r" PASS)"
done
check "the password went into the unlock dialog" "ret 0 1 2 3 4 5 6 7 8 9 a b c d e f 0 1 2 3 4 5 6 7 ret" "$(keys_sent)"
check_true "with a screendump of the lock screen" grep -qF "\"filename\":\"$GUEST_DIR/out/logs/local-lock.png\"" "$GUEST_DIR/state/qmp"
logged_in
echo 'gnome-shell[1234]: JS ERROR: Error: stock' >>"$GUEST_DIR/state/journal"
check "a JS ERROR at login only warns" 0 "$(guest login_only local)"
check "with a WARN row" 1 "$(row local-login WARN)"
logged_in
rm "$GUEST_DIR/state/marker"
check "a login whose layer never armed the crash guard fails" 1 "$(guest login_lock_unlock local)"
check_true "and says so" grep -q '^| local-login | FAIL | the layer never created /run/user/1000/apex-shell-starting' "$GUEST_DIR/out/results.md"
logged_in
echo 'gnome-shell[1234]: Apex: safe mode (APEX_SHELL_SAFE=1)' >>"$GUEST_DIR/state/journal"
check "a login in safe mode fails" 1 "$(guest login_lock_unlock local)"
logged_in
echo 'gnome-shell[1234]: Apex: hook session-mode threw; stock for the rest of the session: x' >>"$GUEST_DIR/state/journal"
check "a hook that threw at login fails" 1 "$(guest login_lock_unlock local)"
logged_in
echo "'prefer-dark'" >"$GUEST_DIR/state/scheme"
check "a login that changed color-scheme fails" 1 "$(guest login_lock_unlock local)"
logged_in
rm "$GUEST_DIR/state/agents"
check "a login without the Apex agent fails" 1 "$(guest login_lock_unlock local)"
check_true "and says so" grep -q "^| local-login | FAIL | the active Apex user units are '', not apex-session-agent.service alone" "$GUEST_DIR/out/results.md"
logged_in
echo 'apex-updated-user.service loaded active running Something else' >>"$GUEST_DIR/state/agents"
check "another active Apex user unit fails" 1 "$(guest login_lock_unlock local)"
logged_in
echo 'apex-folder-icons.service loaded failed failed Set the Apex icons' >"$GUEST_DIR/state/apex-failed"
check "a failed Apex user unit fails" 1 "$(guest login_lock_unlock local)"
check_true "and names it" grep -q '^| local-login | FAIL | a failed Apex user unit: apex-folder-icons.service' "$GUEST_DIR/out/results.md"
logged_in
sed -i 's/NRestarts=0/NRestarts=1/' "$GUEST_DIR/state/agent-props"
check "an agent that restarted fails" 1 "$(guest login_lock_unlock local)"
check_true "and quotes its state" grep -q "^| local-login | FAIL | apex-session-agent.service is 'ActiveState=active NRestarts=1 SubState=running'" "$GUEST_DIR/out/results.md"
logged_in
sed -i 's/ExecMainCode=1/ExecMainCode=0/' "$GUEST_DIR/state/icons-props"
check "folder icons that never ran fail" 1 "$(guest login_lock_unlock local)"
logged_in
sed -i 's/ExecMainStatus=0/ExecMainStatus=1/' "$GUEST_DIR/state/icons-props"
check "folder icons that exited 1 fail" 1 "$(guest login_lock_unlock local)"
logged_in
printf '%s\n' ActiveState=activating Result=success ExecMainCode=0 ExecMainStatus=0 >"$GUEST_DIR/state/icons-props"
check "folder icons still running at the deadline fail" 1 "$(guest login_lock_unlock local)"
logged_in
: >"$GUEST_DIR/state/js-error"
check "a JS ERROR between lock and unlock fails" 1 "$(guest login_lock_unlock local)"
check_true "and the row quotes it" grep -q '^| local-unlock | FAIL | 1 JS ERROR line(s) from lock to unlock' "$GUEST_DIR/out/results.md"
logged_in
rm "$GUEST_DIR/state/takes-keys"
check "an unlock dialog that asks for no password fails" 1 "$(guest login_lock_unlock local)"
check_true "at the unlock" grep -q '^| local-unlock | FAIL | GDM started no password conversation' "$GUEST_DIR/out/results.md"
logged_in
echo apexqa:ffffffffffffffffffffffff >"$GUEST_DIR/state/chpasswd"
check "a password the unlock dialog does not take fails" 1 "$(guest login_lock_unlock local)"
logged_in
: >"$GUEST_DIR/state/crash"
check "a gnome-shell that restarts at logind's unlock fails" 1 "$(guest login_lock_unlock local)"
check "at the signal unlock" 1 "$(row local-unlock-signal FAIL)"
logged_in
: >"$GUEST_DIR/state/never-locks"
check "a session that never locks fails" 1 "$(guest login_lock_unlock local)"
check "at the lock" 1 "$(row local-lock FAIL)"
logged_in
rm "$GUEST_DIR/state/session"
check "no session of the test user fails" 1 "$(guest login_lock_unlock local)"
logged_in
echo 'foo.service loaded failed failed Foo' >"$GUEST_DIR/state/failed-user-units"
check "a failed user unit fails" 1 "$(guest login_lock_unlock local)"
check "at the user units" 1 "$(row local-user-units FAIL)"

# S3b's lock matrix against the fake guest: apex-gnome's single-stage lock asks at once.
pin_features() { # the pinned apex-gnome's FEATURES_IN_ENABLE_ORDER
    mkdir -p "$GUEST_DIR/gnome/desktop/shell/js/ui/apex"
    printf 'const FEATURES_IN_ENABLE_ORDER = [%s];\n' "$1" >"$GUEST_DIR/gnome/desktop/shell/js/ui/apex/layer.js"
    [[ -d $GUEST_DIR/gnome/.git ]] || git -C "$GUEST_DIR/gnome" init -q
    git -C "$GUEST_DIR/gnome" add -A
    git -C "$GUEST_DIR/gnome" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m pin
}
pin_features "'spotlight', 'panel', 'lock'"
GNOME_PIN=$(git -C "$GUEST_DIR/gnome" rev-parse --short=8 HEAD)
apex_locked_in() {
    logged_in
    : >"$GUEST_DIR/state/apex-lock"
    echo 'gnome-shell[1234]: Apex: feature lock enabled' >>"$GUEST_DIR/state/journal"
}
apex_locked_in
check "login, lock and both unlocks with the Apex lock, which asks at once" 0 "$(guest login_lock_unlock local)"
check "its unlock row passes" 1 "$(row local-unlock PASS)"
apex_locked_in
check "the lock matrix" 0 "$(guest lock_matrix local 1000)"
for r in wrong-password esc blank-wake suspend reduce-motion; do
    check "row local-lock-$r passes" 1 "$(row "local-lock-$r" PASS)"
done
check_true "the wrong password went in before the right one" grep -qF '"data":"n"' "$GUEST_DIR/state/qmp"
check_true "Esc was pressed" grep -qF '"data":"esc"' "$GUEST_DIR/state/qmp"
check_true "the VM was woken" grep -qF system_wakeup "$GUEST_DIR/state/qmp"
check_true "results.md names the feature gating each row: lock for the blank wake" \
    grep -q '^| local-lock-blank-wake | PASS | .* | lock: enabled (apex-gnome [0-9a-f]*) |$' "$GUEST_DIR/out/results.md"
check_true "motion, not in this pin, for Reduce Motion" \
    grep -q '^| local-lock-reduce-motion | PASS | .* | motion: not in pinned apex-gnome [0-9a-f]* |$' "$GUEST_DIR/out/results.md"
check_true "and none for an ungated row" grep -q '^| local-lock-wrong-password | PASS | .* | - |$' "$GUEST_DIR/out/results.md"
lock_matrix_fails() { # FLAG ROW: with FLAG set, the matrix stops with ROW failed
    apex_locked_in
    : >"$GUEST_DIR/state/$1"
    check "$1: the matrix fails" 1 "$(guest lock_matrix local 1000)"
    check "$1: at $2" 1 "$(row "$2" FAIL)"
}
lock_matrix_fails no-pam-log local-lock-wrong-password
check_true "naming PAM" grep -q '^| local-lock-wrong-password | FAIL | PAM logged no authentication failure' "$GUEST_DIR/out/results.md"
lock_matrix_fails esc-ignored local-lock-esc
lock_matrix_fails keeps-asking-blank local-lock-blank-wake
# The lock's blank and the nudge's wake log both lines before the test blanks the screen.
lock_logged_both() {
    apex_locked_in
    printf '%s\n' 'Apex: lock: screen blank, prompt torn down' 'Apex: lock: screen on, prompt rebuilt' >>"$GUEST_DIR/state/journal"
}
lock_logged_both
check "blank and wake pass past the lock's own lines" 0 "$(guest lock_matrix local 1000)"
lock_logged_both
: >"$GUEST_DIR/state/blank-unlogged"
check "a blank the lock never logs fails, though the lock logged one earlier" 1 "$(guest lock_matrix local 1000)"
check_true "at blank and wake, naming the line" \
    grep -q "^| local-lock-blank-wake | FAIL | no 'Apex: lock: screen blank, prompt torn down' after the screen blanked" "$GUEST_DIR/out/results.md"
lock_logged_both
: >"$GUEST_DIR/state/wake-unlogged"
check "a wake the lock never logs fails, though the nudge logged one earlier" 1 "$(guest lock_matrix local 1000)"
check_true "naming that line" \
    grep -q "^| local-lock-blank-wake | FAIL | no 'Apex: lock: screen on, prompt rebuilt' after the screen woke" "$GUEST_DIR/out/results.md"
lock_matrix_fails no-suspend local-lock-suspend
lock_matrix_fails resume-unlocks local-lock-suspend
apex_locked_in
printf '%s\n' 'PM: suspend entry (deep)' 'ACPI: PM: Waking up from system sleep state S3' 'PM: suspend exit' >"$GUEST_DIR/state/kernel"
check "suspend: the matrix passes with the kernel's resume lines" 0 "$(guest lock_matrix local 1000)"
check_true "and keeps them in the row's kernel log" grep -qx 'PM: suspend exit' "$GUEST_DIR/out/logs/local-lock-suspend.kernel.txt"
check_true "with a screendump of the resumed screen" grep -qF 'local-lock-suspend-resumed.png' "$GUEST_DIR/state/qmp"
apex_locked_in
: >"$GUEST_DIR/state/resume-unlocks"
printf '%s\n' 'PM: suspend exit' 'virtio_gpu virtio0: [drm] *ERROR* timed out waiting for the control queue' >"$GUEST_DIR/state/kernel"
check "suspend: a resume that fails" 1 "$(guest lock_matrix local 1000)"
check_true "quotes the first virtio, DRM or PM failure line of the kernel" grep -qF \
    '; first kernel line on virtio, DRM or a PM failure since the row began: virtio_gpu virtio0: [drm] *ERROR* timed out' \
    "$GUEST_DIR/out/results.md"
lock_matrix_fails motion-js-error local-lock-reduce-motion
logged_in
check "the pin lists lock, but the session never enabled it: the matrix fails" 1 "$(guest lock_matrix local 1000)"
check_true "at blank and wake, naming the pin" grep -q "^| local-lock-blank-wake | FAIL | the pinned apex-gnome $GNOME_PIN lists 'lock', but the session never logged 'Apex: feature lock enabled'" "$GUEST_DIR/out/results.md"
pin_features "'spotlight', 'panel'"
GNOME_PIN=$(git -C "$GUEST_DIR/gnome" rev-parse --short=8 HEAD)
logged_in
check "a pin without lock: the matrix runs" 0 "$(guest lock_matrix local 1000)"
check_true "and blank and wake passes with the note" grep -q "^| local-lock-blank-wake | PASS | lock not in pinned apex-gnome $GNOME_PIN: no Apex prompt" "$GUEST_DIR/out/results.md"
check_true "as does Reduce Motion, which the pin has no feature for" grep -q "^| local-lock-reduce-motion | PASS | .*; motion not in pinned apex-gnome $GNOME_PIN" "$GUEST_DIR/out/results.md"
logged_in
rm "$GUEST_DIR/state/takes-keys"
echo "gnome-shell[1234]: JS ERROR: TypeError: can't convert undefined to object" >>"$GUEST_DIR/state/journal"
check "a lock screen that starts no conversation fails" 1 "$(guest lock_matrix local 1000)"
lock_failure="| local-lock-wrong-password | FAIL | GDM started no password conversation 2s into pressing Enter"
lock_failure+=" on the lock screen (logs/local-lock-wrong-password.png)"
lock_failure+=" (the screen at the failure: logs/local-lock-wrong-password-failed.png);"
lock_failure+=" first JS ERROR since the row began: gnome-shell[1234]: JS ERROR: TypeError: can't convert undefined to object |"
check_true "naming the first JS ERROR since the row began" grep -qF "$lock_failure" "$GUEST_DIR/out/results.md"
check_true "with a screendump after a pointer move" grep -qF "local-lock-wrong-password-failed.png" "$GUEST_DIR/state/qmp"
logged_in
rm "$GUEST_DIR/state/takes-keys"
check "without a JS ERROR it fails as well" 1 "$(guest lock_matrix local 1000)"
check_true "and says there was none" grep -q '^| local-lock-wrong-password | FAIL | .*; no JS ERROR since the row began |' "$GUEST_DIR/out/results.md"
logged_in
echo yes >"$GUEST_DIR/state/locked"
: >"$GUEST_DIR/state/ret-lost"
check "a Return lost while the curtain rises is pressed again" 0 "$(guest press_enter_until_asked local-lock-esc 'the lock screen' 1)"
check "twice in all" 2 "$(grep -cF '"data":"ret"' "$GUEST_DIR/state/qmp")"
logged_in
check "a login row's failure is not a lock row's" 1 "$(guest fail local-login 'x')"
check_true "so it gets no screendump" grep -q '^| local-login | FAIL | x |' "$GUEST_DIR/out/results.md"
pin_features "'spotlight', 'panel', 'lock', 'motion'"
apex_locked_in
echo 'gnome-shell[1234]: Apex: feature motion enabled' >>"$GUEST_DIR/state/journal"
check "a pin with motion, enabled in the session: the matrix passes" 0 "$(guest lock_matrix local 1000)"
check_false "with no note on Reduce Motion" grep -q '^| local-lock-reduce-motion | PASS | .*not in pinned' "$GUEST_DIR/out/results.md"
apex_locked_in
check "a pin with motion the session never enabled fails" 1 "$(guest lock_matrix local 1000)"
check "at Reduce Motion" 1 "$(row local-lock-reduce-motion FAIL)"
pin_features "'spotlight', 'panel', 'lock'"
rm -rf "$GUEST_DIR/gnome"
apex_locked_in
check "no pinned apex-gnome checkout fails" 1 "$(guest lock_matrix local 1000)"
# shellcheck disable=SC2016 # the row names the variable, unexpanded
check_true "and says how to get one" grep -q '^| local-lock-blank-wake | FAIL | no feature list in \$APEX_GNOME_SRC' "$GUEST_DIR/out/results.md"
pin_features "'spotlight', 'panel', 'lock'"

# S3b board 13: pkexec through the shell's polkit agent, then its stock dialog in safe mode.
logged_in
check "polkit: wrong password, Esc, then the password" 0 "$(guest polkit_agent local 1000)"
for r in local-polkit-wrong-password local-polkit-cancel local-polkit; do
    check "row $r passes" 1 "$(row "$r" PASS)"
done
check_true "the test user became an administrator" test -e "$GUEST_DIR/state/wheel"
check "the keys: the wrong password, Esc, the password" \
    "$(printf 'n o t t h e p a s s w o r d 0 ret esc %s ret' "$(fold -w1 <<<0123456789abcdef01234567 | paste -sd' ')")" \
    "$(keys_sent)"
check_true "and a screendump of each dialog" grep -qF 'local-polkit-dialog.png' "$GUEST_DIR/state/qmp"
logged_in
check "polkit in safe mode: the stock dialog, the password only" 0 "$(guest polkit_agent local-safe 1000 stock)"
check "its row passes" 1 "$(row local-safe-polkit PASS)"
check_true "naming the stock dialog" grep -q '^| local-safe-polkit | PASS | pkexec /usr/bin/id -u as apexqa: the shell.s stock dialog' "$GUEST_DIR/out/results.md"
check_true "and the feature as off" grep -q '^| local-safe-polkit | PASS | .* | polkit: off (safe mode, upstream.s dialog) |$' "$GUEST_DIR/out/results.md"
check "and no wrong-password or cancel row" 0 "$(($(row local-safe-polkit-wrong-password PASS) + $(row local-safe-polkit-cancel PASS)))"
polkit_fails() { # FLAG ROW: with FLAG set, the case stops with ROW failed
    logged_in
    : >"$GUEST_DIR/state/$1"
    check "polkit $1: the case fails" 1 "$(guest polkit_agent local 1000)"
    check "polkit $1: at $2" 1 "$(row "$2" FAIL)"
}
polkit_fails no-agent local-polkit-wrong-password
check_true "naming the missing dialog" grep -q '^| local-polkit-wrong-password | FAIL | pkexec opened no authentication dialog' "$GUEST_DIR/out/results.md"
polkit_fails no-polkit-log local-polkit-wrong-password
check_true "naming PAM's line" grep -qF '| local-polkit-wrong-password | FAIL | PAM logged no pam_unix(polkit-1:auth) authentication failure' "$GUEST_DIR/out/results.md"
polkit_fails no-polkitd-log local-polkit-cancel
check_true "naming polkitd's verdict" grep -qF '| local-polkit-cancel | FAIL | polkitd logged no FAILED to authenticate for org.freedesktop.policykit.exec after Esc' "$GUEST_DIR/out/results.md"
polkit_fails wrong-ends-pkexec local-polkit-wrong-password
polkit_fails no-retry local-polkit-wrong-password
polkit_fails esc-ignored local-polkit-cancel
polkit_fails cancel-127 local-polkit-cancel
check_true "naming the exit" grep -q '^| local-polkit-cancel | FAIL | pkexec exited 127 after Esc, not 126' "$GUEST_DIR/out/results.md"
polkit_fails cancel-keeps-helper local-polkit-cancel
polkit_fails pkexec-not-root local-polkit
check_true "naming what pkexec printed" grep -q "^| local-polkit | FAIL | pkexec /usr/bin/id -u exited 0 and printed '1000', not 0 and 0" "$GUEST_DIR/out/results.md"
# The Apex dialog is the polkit feature: the pin decides whether its rows assert it ran.
logged_in
check "polkit not in the pin: the rows pass" 0 "$(guest polkit_agent local 1000)"
check_true "with a note naming the pin" grep -q "^| local-polkit | PASS | .*shell.s dialog .*; polkit not in pinned apex-gnome [0-9a-f]* |" "$GUEST_DIR/out/results.md"
check "and each polkit row names the feature it waits for" 3 \
    "$(grep -c '^| local-polkit[a-z-]* | PASS | .* | polkit: not in pinned apex-gnome [0-9a-f]* |$' "$GUEST_DIR/out/results.md")"
pin_features "'spotlight', 'panel', 'lock', 'polkit'"
logged_in
echo 'gnome-shell[1234]: Apex: feature polkit enabled' >>"$GUEST_DIR/state/journal"
check "polkit in the pin and enabled: the rows pass" 0 "$(guest polkit_agent local 1000)"
check_true "naming the Apex dialog" grep -q '^| local-polkit | PASS | pkexec /usr/bin/id -u as apexqa: the Apex dialog (feature polkit enabled) (logs/local-polkit-dialog.png) took the password; it printed 0 and exited 0 |' "$GUEST_DIR/out/results.md"
check "and each polkit row names the enabled feature" 3 \
    "$(grep -c '^| local-polkit[a-z-]* | PASS | .* | polkit: enabled (apex-gnome [0-9a-f]*) |$' "$GUEST_DIR/out/results.md")"
logged_in
check "polkit in the pin but never enabled: the case fails" 1 "$(guest polkit_agent local 1000)"
check_true "at its first row, naming the causes" grep -q "^| local-polkit-wrong-password | FAIL | the pinned apex-gnome [0-9a-f]* lists 'polkit', but the session never logged 'Apex: feature polkit enabled' (the crash guard, disabled-features or a load error" "$GUEST_DIR/out/results.md"
check_true "and starts no pkexec" test ! -e "$GUEST_DIR/state/pkexec-running"
check_true "its row names the feature that never ran" \
    grep -q '^| local-polkit-wrong-password | FAIL | .* | polkit: listed, never enabled (apex-gnome [0-9a-f]*) |$' "$GUEST_DIR/out/results.md"
logged_in
echo 'gnome-shell[1234]: Apex: feature polkit enabled' >>"$GUEST_DIR/state/journal"
check "safe mode with the feature enabled: the case fails" 1 "$(guest polkit_agent local-safe 1000 stock)"
check_true "the dialog is not upstream's" grep -q "^| local-safe-polkit | FAIL | the safe login logged 'Apex: feature polkit enabled'" "$GUEST_DIR/out/results.md"
pin_features "'spotlight', 'panel', 'lock'"

# polkitd's own reading of the actions G1 parsed: what the dialog's details show.
policies() {
    rm -f "$GUEST_DIR"/state/unloaded-* "$GUEST_DIR"/state/vendor-*
    cat "$APEX_SYSTEM_POLICY" >"$GUEST_DIR/state/policies"
}
APEX_SYSTEM_POLICY=$TMP/apex-update.policy
printf '%s\n' '<policyconfig>' '  <vendor>Apex</vendor>' \
    '  <action id="io.github.apex-linux.apex.update.check">' '  </action>' \
    '  <action id="io.github.apex-linux.apex.update.rollback">' '  </action>' '</policyconfig>' >"$APEX_SYSTEM_POLICY"
policies
check "polkit actions: pkaction knows each, vendor Apex" 0 "$(guest polkit_actions local)"
check_true "and the row names them" grep -q '^| local-polkit-actions | PASS | pkaction --verbose names vendor Apex for the 2 actions of .*: io\.github\.apex-linux\.apex\.update\.check io\.github\.apex-linux\.apex\.update\.rollback |' "$GUEST_DIR/out/results.md"
policies
: >"$GUEST_DIR/state/unloaded-io.github.apex-linux.apex.update.rollback"
check "an action polkitd did not load fails" 1 "$(guest polkit_actions local)"
check_true "and is named" grep -q '^| local-polkit-actions | FAIL | pkaction does not know io\.github\.apex-linux\.apex\.update\.rollback' "$GUEST_DIR/out/results.md"
policies
: >"$GUEST_DIR/state/vendor-io.github.apex-linux.apex.update.check"
check "a blank vendor fails" 1 "$(guest polkit_actions local)"
check_true "naming it" grep -q "^| local-polkit-actions | FAIL | pkaction names vendor '' for io\.github\.apex-linux\.apex\.update\.check, not 'Apex'" "$GUEST_DIR/out/results.md"
check "and stops there" 0 "$(grep -c 'update\.rollback' "$GUEST_DIR/out/results.md" || true)"
policies
echo Other >"$GUEST_DIR/state/vendor-io.github.apex-linux.apex.update.rollback"
check "another vendor fails" 1 "$(guest polkit_actions local)"
check_true "naming it" grep -q "^| local-polkit-actions | FAIL | pkaction names vendor 'Other' for io\.github\.apex-linux\.apex\.update\.rollback" "$GUEST_DIR/out/results.md"
: >"$GUEST_DIR/state/policies"
check "no Apex policy on the guest fails" 1 "$(guest polkit_actions local)"
check_true "and says so" grep -q '^| local-polkit-actions | FAIL | no /usr/share/polkit-1/actions/io\.github\.apex-linux\.\*\.policy on the guest' "$GUEST_DIR/out/results.md"
printf '<policyconfig>\n  <action id="bad id; reboot">\n</policyconfig>\n' >"$GUEST_DIR/state/policies"
check "an id that is not a polkit id fails before any pkaction" 1 "$(guest polkit_actions local)"
check_true "naming it" grep -q '^| local-polkit-actions | FAIL | an action id is not a polkit id: bad' "$GUEST_DIR/out/results.md"

apex_locked_in
check "apex.safe=1: upstream's two-stage lock" 0 "$(guest safe_karg_lock local)"
check "passes" 1 "$(row local-lock-safe PASS)"
check_true "after Return lifted the curtain" grep -q '^| local-lock-safe | PASS | apex.safe=1: .Apex: safe mode (apex.safe=1)., no Apex lock; upstream.s two-stage lock asked only after Return' "$GUEST_DIR/out/results.md"
apex_locked_in
: >"$GUEST_DIR/state/safe-ignored"
check "a boot that ignores apex.safe=1 fails" 1 "$(guest safe_karg_lock local)"
check "at the safe row" 1 "$(row local-lock-safe FAIL)"

logged_in
echo 'c1 60578 wayland' >"$GUEST_DIR/state/greeter"
check "the crash guard trips at a real login, and the next login is safe" 0 "$(guest crash_guard_logins local)"
check "row local-crash-guard passes" 1 "$(row local-crash-guard PASS)"
check "row local-safe-login passes" 1 "$(row local-safe-login PASS)"
check_false "the fault leaves the user's environment.d" test -e "$GUEST_DIR/state/fault-file"
logged_in
echo 'c1 60578 wayland' >"$GUEST_DIR/state/greeter"
: >"$GUEST_DIR/state/safe-js-error"
check "a JS ERROR in the safe login fails" 1 "$(guest crash_guard_logins local)"
check_true "and the row quotes it" grep -q '^| local-safe-login | FAIL | 1 JS ERROR line(s) in the safe login' "$GUEST_DIR/out/results.md"
logged_in
echo 'c1 60578 wayland' >"$GUEST_DIR/state/greeter"
: >"$GUEST_DIR/state/guard-broken"
check "a fault login whose guard never trips fails" 1 "$(guest crash_guard_logins local)"
check "at the crash guard" 1 "$(row local-crash-guard FAIL)"

logged_in
rm -f "$GUEST_DIR/record"
printf '%s\n' "package gdm-1:51.0-1.fc45.x86_64" "file bbbb /usr/bin/apexctl" >"$GUEST_DIR/state/key"
check "a full pass records the guest's G4 key" 0 "$(guest record_g4_pass local localhost/apex:build)"
check "sorted, as g4-due reads it, then the time and the image" \
    "file bbbb /usr/bin/apexctl|package gdm-1:51.0-1.fc45.x86_64|passed-at|image-id cafe" \
    "$(sed 's/^passed-at .*/passed-at/' "$GUEST_DIR/record" | paste -sd'|')"
check "so G4 is no longer due" 3 "$(g4_due "$GUEST_DIR/record" "$GUEST_DIR/record")"
rm -f "$GUEST_DIR/record"
record_g4_pass_after_rows() {
    printf '%s\n' "$@" >"$GUEST_DIR/rows"
    local rc=0
    QUALIFY_OUT="$GUEST_DIR/out" QUALIFY_G4_RECORD="$GUEST_DIR/record" GITHUB_ACTIONS='' QUALIFY_LAYOUT=${LAYOUT:-separate-boot} \
        bash -c 'cp "$3" "$QUALIFY_OUT/results.md"; . "$1"; STATE=$2; vm_ssh() { cat >/dev/null; cat "$STATE/key"; }; record_g4_pass local localhost/apex:build' \
        _ "$APEX_ROOT/.github/scripts/qualify.sh" "$GUEST_DIR/state" "$GUEST_DIR/rows" >"$GUEST_DIR/stderr" 2>&1 || rc=$?
    printf '%s\n' "$rc"
}
check "a run with a SKIP row records nothing" "1:no record" \
    "$(record_g4_pass_after_rows '| local-install | PASS | x |' '| local-red | SKIP | y |'):$([[ -e $GUEST_DIR/record ]] && echo record || echo 'no record')"
check "nor one with a WARN row" "1:no record" \
    "$(record_g4_pass_after_rows '| local-login | WARN | 2 JS ERROR |'):$([[ -e $GUEST_DIR/record ]] && echo record || echo 'no record')"
check "nor a to-disk run, which skipped the counted rollback" "1:no record" \
    "$(LAYOUT=to-disk record_g4_pass_after_rows '| local-install | PASS | x |'):$([[ -e $GUEST_DIR/record ]] && echo record || echo 'no record')"

# boot_metrics is warning-only: whatever the journal lacks, G4 goes on to the login steps.
boot_then_login() { # MONO_LINES...: boot_metrics, then login_lock_unlock, as the local flow runs them
    logged_in
    printf 'Startup finished in 932ms (kernel) + 2.627s (initrd) + 28.699s (userspace) = 32.258s\n' \
        >"$GUEST_DIR/state/analyze"
    printf '%s\n' "$@" >"$GUEST_DIR/state/mono"
    guest eval 'boot_metrics local; login_lock_unlock local'
}
boot_row() { grep '^| local-boot-metrics |' "$GUEST_DIR/out/results.md"; }
check "boot metrics: a journal without any shell marker still runs the login steps" 0 "$(boot_then_login)"
check "and the boot row passes with what it has" 1 "$(row local-boot-metrics PASS)"
check_true "naming the greeter and desktop it could not time" grep -q \
    "no value for greeter: none of 'Started org.gnome.Shell@gdm.service Registering display with GDM GNOME Shell started at' in the journal, desktop: no 'gdm-password:session.: session opened for user apexqa'" \
    <<<"$(boot_row)"
check "the login steps after it ran and passed" 1 "$(row local-unlock PASS)"
check "boot.tsv holds the systemd-analyze phases only" "kernel 0.932 initrd 2.627 userspace 28.699" \
    "$(paste -sd' ' "$GUEST_DIR/out/boot.tsv")"
# VM run 6's journal (GNOME 51): the user's shell unit is @user, and systemd-user opens a
# session for the user before gdm-password does.
check "boot metrics: VM run 6's journal, the shells' units started" 0 "$(boot_then_login \
    '7.512 60578 Running GNOME Shell (using mutter 51.0) as a Wayland display server' \
    '8.731 60578 Registering display with GDM' \
    '8.988595 0 Started org.gnome.Shell@gdm.service - GNOME Shell on Wayland.' \
    '46.764169 0 pam_unix(systemd-user:session): session opened for user apexqa(uid=1000) by apexqa(uid=0)' \
    '46.935880 0 pam_unix(gdm-password:session): session opened for user apexqa(uid=1000) by apexqa(uid=0)' \
    '47.294161 1000 Started gnome-session-manager@gnome.service - GNOME Session Manager (session: gnome).' \
    '47.922820 1000 Running GNOME Shell (using mutter 51.0) as a Wayland display server' \
    '55.150626 1000 Registering session with GDM' \
    '55.590919 1000 Started org.gnome.Shell@user.service - GNOME Shell.' \
    '55.594178 1000 Reached target gnome-session-initialized.target - GNOME Session is initialized.')"
check "greeter at its unit's start, desktop from gdm-password's login to the user's unit" \
    "kernel 0.932 initrd 2.627 userspace 28.699 greeter 8.989 desktop 8.655" "$(paste -sd' ' "$GUEST_DIR/out/boot.tsv")"
check_true "the row names the markers it timed" grep -q \
    "greeter at 'Started org.gnome.Shell@gdm.service'; desktop at 'Started org.gnome.Shell@user.service' (boot.tsv" \
    <<<"$(boot_row)"
check "boot metrics: without the unit lines, the shells' registrations with GDM" 0 "$(boot_then_login \
    '8.731 60578 Registering display with GDM' \
    '46.935880 0 pam_unix(gdm-password:session): session opened for user apexqa(uid=1000)' \
    '47.922820 1000 Running GNOME Shell (using mutter 51.0) as a Wayland display server' \
    '55.150626 1000 Registering session with GDM')"
check "greeter at the display's, desktop at the session's, never the shell's process start" \
    "greeter 8.731 desktop 8.215" "$(sed -n 's/^\(greeter\|desktop\) /&/p' "$GUEST_DIR/out/boot.tsv" | paste -sd' ')"
check "boot metrics: the greeter's lines never time the user's desktop" 0 "$(boot_then_login \
    '8.731 60578 Registering session with GDM' \
    '8.988595 0 Started org.gnome.Shell@user.service - GNOME Shell.' \
    '46.935880 0 pam_unix(gdm-password:session): session opened for user apexqa(uid=1000)')"
check_true "the desktop stays untimed" grep -q "desktop: none of 'Started org.gnome.Shell@user.service" <<<"$(boot_row)"
check "boot metrics: systemd-user's session line alone is no login time" 0 "$(boot_then_login \
    '46.764169 0 pam_unix(systemd-user:session): session opened for user apexqa(uid=1000)' \
    '55.590919 1000 Started org.gnome.Shell@user.service - GNOME Shell.')"
check_true "the desktop stays untimed, naming gdm-password's line" grep -q \
    "desktop: no 'gdm-password:session.: session opened for user apexqa'" <<<"$(boot_row)"
logged_in
rm -f "$GUEST_DIR/state/analyze"
printf '' >"$GUEST_DIR/state/mono"
check "boot metrics: no systemd-analyze time is a SKIP, and the login steps still run" "0|1|1" \
    "$(guest eval 'boot_metrics local; login_lock_unlock local')|$(row local-boot-metrics SKIP)|$(row local-unlock PASS)"

# An errexit names its line, its command and its status before G4's summary.
errexit_of() { # SCRIPT: qualify.sh's ERR trap around SCRIPT; prints its stderr
    { bash -c '. "$1"; set -euo pipefail; trap_errexit; eval "$2"' _ "$APEX_ROOT/.github/scripts/qualify.sh" "$1" >/dev/null; } 2>&1 || true
}
# shellcheck disable=SC2016 # each script runs in the inner bash
check "errexit: a failed assignment names itself" "qualify.sh: line 1: v=\$(printf a | grep -q b) exited 1" \
    "$(errexit_of 'f() { local v; v=$(printf a | grep -q b); echo reached; }; f')"
# shellcheck disable=SC2016 # each script runs in the inner bash
check "errexit: failures the script tolerates print nothing" "done" \
    "$(errexit_of 'x=$(false; echo y) || true; if ! false; then :; fi; false || true; set +e; false; set -e; v=$(grep -q z /dev/null || true); echo done >&2')"

# --- repositories: the compose's set, never all of updates-testing ---------------------
repo_args_with() {
    local ga_reached=$1 allowlist=$2
    APEX_GA_REACHED=$ga_reached bash -c '. "$1"; fake_allowlist=$2; testing_includepkgs() { printf "%s\n" "$fake_allowlist"; }; dnf_repo_args | paste -sd" " -' \
        _ "$APEX_ROOT/.github/scripts/lib.sh" "$allowlist"
}
check "pre-GA with an allowlist: only those builds from updates-testing" \
    "--repo=fedora --repo=updates --repo=updates-testing --setopt=updates-testing.includepkgs=gtk4-4.24.0-1.fc45,glib2-2.90.0-1.fc45" \
    "$(repo_args_with 0 gtk4-4.24.0-1.fc45,glib2-2.90.0-1.fc45)"
check "pre-GA with an empty allowlist: no updates-testing" "--repo=fedora --repo=updates" "$(repo_args_with 0 '')"
check "after GA: no updates-testing" "--repo=fedora --repo=updates" "$(repo_args_with 1 gtk4-4.24.0-1.fc45)"

# --- contracts.sh: the image against a hardware profile (the CI job runs the pinned one) ----
CT=$TMP/contracts
CT_SCHEMA=io.github.apex_linux.Apex.Desktop.gschema.xml
mkdir -p "$CT/system/hardware/m7400qc" "$CT/desktop/desktop/schemas" "$CT/desktop/desktop/systemd/user" \
    "$CT/gnome/tests/layer/fixtures" "$CT/system/crates/apexctl/src"
ct_degraded() {
    printf 'pub const DEGRADED_COMPONENTS: &[&str] = &[%s];\n' "$1" >"$CT/system/crates/apexctl/src/manifest.rs"
}
ct_degraded '"adwaita", "audio", "files", "fingerprint", "nvidia", "settings", "shell", "terminal"'
ct_choices() { # NAMES: apex-desktop's schema with disabled-features offering NAMES
    local c=''
    for n in "$@"; do c+="<choice value=\"$n\"/>"; done
    printf '<schemalist><schema id="io.github.apex_linux.Apex.Desktop" path="/x/">%s</schema></schemalist>\n' \
        "<key name=\"disabled-features\" type=\"as\">${c:+<choices>$c</choices>}<default>[]</default></key>" \
        >"$CT/desktop/desktop/schemas/$CT_SCHEMA"
}
ct_features() { # LIST: apex-gnome's layer.js with FEATURES_IN_ENABLE_ORDER = [LIST]
    mkdir -p "$CT/gnome/${APEX_LAYER_JS%/*}"
    printf "import x from 'y';\nconst FEATURES_IN_ENABLE_ORDER = [%s];\n" "$1" >"$CT/gnome/$APEX_LAYER_JS"
}
ct_choices motion spotlight
ct_features "'motion', 'spotlight'"
ct_user_units() { # SYSTEM DESKTOP: the user units the components' specs ship and enable, as main's
    mkdir -p "$1/packaging" "$1/data" "$2/packaging" "$2/desktop/systemd/user"
    printf '%s\n' '%files' '%{_userunitdir}/apex-session-agent.service' '%{_userpresetdir}/80-apex.preset' >"$1/packaging/apex.spec"
    printf 'enable apex-session-agent.service\n' >"$1/data/80-apex.preset"
    printf '[Unit]\nConditionEnvironment=XDG_SESSION_CLASS=user\n[Service]\nExecStart=/a\nRestart=on-failure\n[Install]\nWantedBy=graphical-session.target\n' \
        >"$1/data/apex-session-agent.service"
    printf '%s\n' '%files' '%{_userunitdir}/apex-shell-safe.service' '%{_userunitdir}/apex-folder-icons.service' \
        '%{_userunitdir}/graphical-session.target.wants/apex-folder-icons.service' >"$2/packaging/apex-desktop.spec"
    printf '[Unit]\nConditionEnvironment=XDG_SESSION_CLASS=user\n[Service]\nType=oneshot\nExecStart=/b\n' \
        >"$2/desktop/systemd/user/apex-folder-icons.service"
    printf '[Unit]\n' >"$2/desktop/systemd/user/apex-shell-safe.service"
}
ct_user_units "$CT/system" "$CT/desktop"
G4U=$TMP/g4-user-units
g4u() { # QUALIFY: g4_user_units' exit on a fresh copy of the components after "$G4U/edit"; its errors in $G4U/err
    rm -rf "$G4U/system" "$G4U/desktop" && ct_user_units "$G4U/system" "$G4U/desktop"
    (cd "$G4U" && eval "$(cat "$G4U/edit")")
    (set +e; g4_user_units "$1" "$G4U/system" "$G4U/desktop" >"$G4U/out" 2>"$G4U/err"; echo $?)
}
mkdir -p "$G4U" && : >"$G4U/edit"
check "g4 user units: main's qualify.sh expects what the components enable" 0 "$(g4u "$APEX_ROOT/.github/scripts/qualify.sh")"
check "and names them" "long-running: apex-session-agent.service; oneshot: apex-folder-icons.service" "$(cat "$G4U/out")"
sed '/^apex_units_settled() {$/,/^}$/d' "$APEX_ROOT/.github/scripts/qualify.sh" >"$G4U/qualify-0380e70.sh"
check "g4 user units: a login contract that expects no Apex user unit (0380e70, run 11) fails" 1 "$(g4u "$G4U/qualify-0380e70.sh")"
check_true "and names the agent it would not expect" grep -q "expects the long-running Apex user units 'none', but the components enable 'apex-session-agent.service'" "$G4U/err"
echo "echo enable apex-extra.service >>system/data/80-apex.preset" >"$G4U/edit"
check "g4 user units: a preset enabling a unit no spec installs fails" 1 "$(g4u "$APEX_ROOT/.github/scripts/qualify.sh")"
echo "sed -i 's/^Restart=.*/Type=oneshot/' system/data/apex-session-agent.service" >"$G4U/edit"
check "g4 user units: an agent that became a oneshot fails" 1 "$(g4u "$APEX_ROOT/.github/scripts/qualify.sh")"
check_true "and says G4 expects it running" grep -q "expects the long-running Apex user units 'apex-session-agent.service', but the components enable 'none'" "$G4U/err"
echo "sed -i '/^ConditionEnvironment=/d' desktop/desktop/systemd/user/apex-folder-icons.service" >"$G4U/edit"
check "g4 user units: a unit that would start in the greeter fails" 1 "$(g4u "$APEX_ROOT/.github/scripts/qualify.sh")"
check_true "and says why" grep -q "apex-folder-icons.service: no ConditionEnvironment=XDG_SESSION_CLASS=user, so it starts in GDM's greeter" "$G4U/err"
echo "sed -i '/target.wants/d' desktop/packaging/apex-desktop.spec" >"$G4U/edit"
check "g4 user units: a oneshot nothing enables any more fails" 1 "$(g4u "$APEX_ROOT/.github/scripts/qualify.sh")"
# The compose's repositories, as dnf5 repoquery --whatprovides answers: FILE PACKAGE lines.
mkdir -p "$CT/bin"
cat >"$CT/bin/dnf5" <<'EOF'
#!/usr/bin/env bash
while (($#)); do
    if [[ $1 == --whatprovides ]]; then awk -v f="$2" '$1 == f { print $2 }' "$CT_PROVIDES"; fi
    shift
done
EOF
chmod +x "$CT/bin/dnf5"
printf '/usr/share/applications/%s\n' 'org.gnome.Nautilus.desktop nautilus' 'org.gnome.Ptyxis.desktop ptyxis' \
    'org.example.Unlisted.desktop unlisted' 'org.gnome.Terminal.desktop gnome-terminal' >"$CT/provides"
CT_KEYS="['<Super><Alt>space', 'XF86Keyboard']"
CT_BACK_KEYS="['<Shift><Super><Alt>space', '<Shift>XF86Keyboard']"
ct_favorites() { # LIST: apex-desktop's dock, favorite-apps=[LIST], and its input-source keys
    printf "[org.gnome.desktop.interface]\nicon-theme='Apex'\nclock-show-weekday=true\n\n[org.gnome.shell]\nfavorite-apps=[%s]\n" "$1" \
        >"$CT/desktop/desktop/schemas/90_apex.gschema.override"
    printf '\n[org.gnome.desktop.wm.keybindings]\n# Super+Space opens Spotlight.\n%s\n%s\n' \
        "switch-input-source=$CT_KEYS" "switch-input-source-backward=$CT_BACK_KEYS" \
        >>"$CT/desktop/desktop/schemas/90_apex.gschema.override"
}
ct_g2_keys() { # KEYS BACKWARD: apex-gnome's G2 copy of the input-source keys
    mkdir -p "$CT/gnome/tests/shots"
    printf '%s\n' "readonly PR_CASES=(default keys" '    fault-abort)' "# apex-desktop's 90_apex override." \
        "readonly INPUT_SOURCE_KEYS=\"$1\"" "readonly INPUT_SOURCE_BACKWARD_KEYS=\"$2\"" >"$CT/gnome/tests/shots/parts.sh"
}
ct_g2_keys "$CT_KEYS" "$CT_BACK_KEYS"
ct_g2_weekday() { # PATCHED SMOKE: the clock-show-weekday values G2's patched.sh and smoke.sh write
    printf "printf '%%s\\n' '[org.gnome.desktop.interface]' '%s' >x.override\n" "$1" >"$CT/gnome/tests/shots/patched.sh"
    printf "printf '[org.gnome.desktop.interface]\\n%s\\n' >y.override\n" "$2" >"$CT/gnome/tests/shots/smoke.sh"
}
ct_g2_weekday clock-show-weekday=true clock-show-weekday=true
ct_favorites "'org.gnome.Nautilus.desktop', 'org.gnome.Ptyxis.desktop', 'io.github.kolunmi.Bazaar.desktop'"
printf '[Unit]\n' >"$CT/desktop/desktop/systemd/user/apex-shell-safe.service"
cp "$CT/desktop/desktop/schemas/$CT_SCHEMA" "$CT/desktop/desktop/systemd/user/apex-shell-safe.service" \
    "$CT/gnome/tests/layer/fixtures/"
ct_run() {
    PATH="$CT/bin:$PATH" CT_PROVIDES="$CT/provides" APEX_SYSTEM_SRC="$CT/system" APEX_DESKTOP_SRC="$CT/desktop" \
        APEX_GNOME_SRC="$CT/gnome" rc_of "$APEX_ROOT/.github/scripts/contracts.sh"
}
contracts_with() {
    local packages=$1 files=$2
    printf '[firmware]\npackages = [%s]\nrequired_files = [%s]\n' "$packages" "$files" \
        >"$CT/system/hardware/m7400qc/profile.toml"
    ct_run
}
quoted() { sed 's/#.*//; s/[[:space:]]//g; /^$/d; s/.*/"&"/' "$1" | paste -sd, -; }
CT_FIRMWARE='"linux-firmware"'
CT_FILES=$(quoted "$APEX_ROOT/image/checks/firmware-files.txt")
check "contracts: a profile whose firmware the image installs and checks" 0 "$(contracts_with "$CT_FIRMWARE" "$CT_FILES")"
check "contracts: a profile firmware package that base.txt lacks" 1 \
    "$(contracts_with "$CT_FIRMWARE, \"x-firmware\"" "$CT_FILES")"
check "contracts: required_files that firmware-files.txt does not list" 1 \
    "$(contracts_with "$CT_FIRMWARE" "$CT_FILES, \"x/*.bin\"")"
check "contracts: no profile" 1 "$(APEX_SYSTEM_SRC="$TMP/nowhere" APEX_DESKTOP_SRC="$CT/desktop" \
    APEX_GNOME_SRC="$CT/gnome" rc_of "$APEX_ROOT/.github/scripts/contracts.sh")"
check "contracts: with the copies equal" 0 "$(contracts_with "$CT_FIRMWARE" "$CT_FILES")"
printf '<schemalist></schemalist>\n' >"$CT/gnome/tests/layer/fixtures/$CT_SCHEMA"
check "contracts: apex-gnome's schema copy differs from apex-desktop's" 1 "$(ct_run)"
rm "$CT/gnome/tests/layer/fixtures/$CT_SCHEMA"
check "contracts: apex-gnome's schema copy is missing" 1 "$(ct_run)"
cp "$CT/desktop/desktop/schemas/$CT_SCHEMA" "$CT/gnome/tests/layer/fixtures/"
check "contracts: copies equal again" 0 "$(ct_run)"
mkdir -p "$CT/system/crates/apex-session-agent/tests/data"
check "contracts: the session agent without its schema copy" 1 "$(ct_run)"
cp "$CT/desktop/desktop/schemas/$CT_SCHEMA" "$CT/system/crates/apex-session-agent/tests/data/"
check "contracts: the session agent with its schema copy" 0 "$(ct_run)"
ct_degraded '"adwaita", "audio", "files", "fingerprint", "nvidia", "settings", "shell"'
check "contracts: an apexctl that refuses a degraded name the Containerfile writes" 1 "$(ct_run)"
ct_degraded '"adwaita", "audio", "files", "fingerprint", "nvidia", "settings", "shell", "terminal"'
check "contracts: an apexctl that accepts every degraded name" 0 "$(ct_run)"
CT_UPDATE1=io.github.apex_linux.Apex.Update1.xml
mkdir -p "$CT/gnome/desktop/control-center/panels/apex" "$CT/system/crates/apex-dbus/data"
printf '<node/>\n' >"$CT/system/crates/apex-dbus/data/$CT_UPDATE1"
check "contracts: no Update1 copy in apex-gnome yet" 0 "$(ct_run)"
printf '<node></node>\n' >"$CT/gnome/desktop/control-center/panels/apex/$CT_UPDATE1"
check "contracts: Settings' Update1 copy differs from apex-system's" 1 "$(ct_run)"
cp "$CT/system/crates/apex-dbus/data/$CT_UPDATE1" "$CT/gnome/desktop/control-center/panels/apex/"
check "contracts: Settings' Update1 copy equals apex-system's" 0 "$(ct_run)"
rm "$CT/system/crates/apex-dbus/data/$CT_UPDATE1"
check "contracts: a Settings Update1 copy with no XML in apex-system" 1 "$(ct_run)"
cp "$CT/gnome/desktop/control-center/panels/apex/$CT_UPDATE1" "$CT/system/crates/apex-dbus/data/"
check "contracts: G2's input-source keys equal apex-desktop's" 0 "$(ct_run)"
ct_g2_keys "['<Super>space', 'XF86Keyboard']" "$CT_BACK_KEYS"
check "contracts: G2's switch-input-source differs from apex-desktop's" 1 "$(ct_run)"
ct_g2_keys "$CT_KEYS" "['<Shift><Super>space']"
check "contracts: G2's switch-input-source-backward differs from apex-desktop's" 1 "$(ct_run)"
rm "$CT/gnome/tests/shots/parts.sh"
check "contracts: no G2 parts.sh in apex-gnome" 1 "$(ct_run)"
ct_g2_keys "$CT_KEYS" "$CT_BACK_KEYS"
sed -i '/^switch-input-source-backward=/d' "$CT/desktop/desktop/schemas/90_apex.gschema.override"
check "contracts: an override without switch-input-source-backward" 1 "$(ct_run)"
ct_favorites "'org.gnome.Nautilus.desktop', 'org.gnome.Ptyxis.desktop', 'io.github.kolunmi.Bazaar.desktop'"
check "contracts: the G2 keys hold again" 0 "$(ct_run)"
ct_g2_weekday clock-show-weekday=false clock-show-weekday=true
check "contracts: G2's patched shell drops the weekday the image shows" 1 "$(ct_run)"
ct_g2_weekday clock-show-weekday=true ''
check "contracts: G2's smoke shell sets no weekday" 1 "$(ct_run)"
ct_g2_weekday clock-show-weekday=true clock-show-weekday=true
sed -i '/^clock-show-weekday=/d' "$CT/desktop/desktop/schemas/90_apex.gschema.override"
check "contracts: an override that no longer shows the weekday, while G2 does" 1 "$(ct_run)"
ct_favorites "'org.gnome.Nautilus.desktop', 'org.gnome.Ptyxis.desktop', 'io.github.kolunmi.Bazaar.desktop'"
check "contracts: the G2 weekday holds again" 0 "$(ct_run)"
ct_kill() { # CHOICES FEATURES: contracts.sh's exit, its output in $CT/out
    local rc=0
    read -ra ct_c <<<"$1"
    ct_choices "${ct_c[@]}"
    for f in "$CT/gnome/tests/layer/fixtures" "$CT/system/crates/apex-session-agent/tests/data"; do
        cp "$CT/desktop/desktop/schemas/$CT_SCHEMA" "$f/"
    done
    ct_features "$2"
    PATH="$CT/bin:$PATH" CT_PROVIDES="$CT/provides" APEX_SYSTEM_SRC="$CT/system" APEX_DESKTOP_SRC="$CT/desktop" \
        APEX_GNOME_SRC="$CT/gnome" GITHUB_ACTIONS='' "$APEX_ROOT/.github/scripts/contracts.sh" >"$CT/out" 2>&1 || rc=$?
    printf '%s' "$rc"
}
check "contracts: every layer feature is a kill-switch choice" 0 "$(ct_kill 'motion spotlight panel' "'motion', 'spotlight', 'panel'")"
check_true "and says so" grep -q "^contracts: every feature of apex-gnome (.*)'s layer can be turned off" "$CT/out"
check "contracts: a feature list wrapped over two lines" 0 "$(ct_kill 'motion spotlight panel' "'motion', 'spotlight',
    'panel'")"
check "contracts: a wrapped list with a feature the kill switch lacks" 1 "$(ct_kill 'motion spotlight' "'motion',
    'spotlight', 'dock'")"
check "contracts: a layer feature the kill switch lacks" 1 "$(ct_kill 'motion spotlight' "'motion', 'spotlight', 'glass', 'dock'")"
check_true "naming both components and the features" grep -q \
    "^error: contracts: apex-gnome (.*)'s layer has features that apex-desktop (.*)'s disabled-features cannot turn off (not in its <choices>): dock glass$" "$CT/out"
check "contracts: a choice with no layer feature only warns" 0 "$(ct_kill 'motion spotlight shadows' "'motion', 'spotlight'")"
check_true "naming it" grep -q "^warning: contracts: apex-desktop (.*)'s disabled-features offers choices that apex-gnome (.*)'s layer has no feature for: shadows$" "$CT/out"
check "contracts: an empty feature list" 1 "$(ct_kill 'motion spotlight' '')"
check_true "says so" grep -q "^error: contracts: apex-gnome (.*)'s desktop/shell/js/ui/apex/layer.js has no FEATURES_IN_ENABLE_ORDER, or it is empty" "$CT/out"
ct_dock() { # LIST: contracts.sh's exit with that dock, its output in $CT/out
    ct_favorites "$1"
    ct_kill 'motion spotlight' "'motion', 'spotlight'"
}
check "contracts: a dock of listed packages and a preinstalled Flatpak" 0 \
    "$(ct_dock "'org.gnome.Nautilus.desktop', 'org.gnome.Ptyxis.desktop', 'io.github.kolunmi.Bazaar.desktop'")"
check_true "and logs the dock contract" grep -q "^contracts: every dock favourite of apex-desktop (.*) is in the image or preinstalled$" "$CT/out"
check "contracts: a favourite whose package the image does not list" 1 \
    "$(ct_dock "'org.gnome.Nautilus.desktop', 'org.example.Unlisted.desktop'")"
check_true "names it and its package" grep -q \
    "^error: apex-desktop (.*) favourite org.example.Unlisted.desktop (shipped by unlisted, which image/packages does not list)$" "$CT/out"
check "contracts: Music resolves through apex.preinstall, never an RPM" 0 "$(ct_dock "'org.gnome.Music.desktop'")"
check "contracts: a favourite that nothing ships" 1 "$(ct_dock "'org.example.Gone.desktop'")"
check_true "names the favourite nothing ships" grep -q "favourite org.example.Gone.desktop (no package of the compose's repositories ships it" "$CT/out"
check "contracts: a favourite whose package exclude.txt removes" 1 "$(ct_dock "'org.gnome.Terminal.desktop'")"
check_true "names the package exclude.txt removes" grep -q "favourite org.gnome.Terminal.desktop (shipped by gnome-terminal, which exclude.txt removes)" "$CT/out"
ct_dock "'org.gnome.Nautilus.desktop'" >/dev/null
printf '[org.gnome.shell]\nenabled-extensions=[]\n' >"$CT/desktop/desktop/schemas/90_apex.gschema.override"
check "contracts: an override without favorite-apps" 1 "$(ct_kill 'motion spotlight' "'motion', 'spotlight'")"
ct_favorites "'org.gnome.Nautilus.desktop', 'org.gnome.Ptyxis.desktop', 'io.github.kolunmi.Bazaar.desktop'"
check "contracts: a free-form kill switch, no <choices>" 1 "$(ct_kill '' "'motion'")"
check_true "says it cannot be checked" grep -q '^error: disabled-features has no <choices>: it takes any name' "$CT/out"
check_true "naming apex-desktop" grep -q '^error: contracts: apex-desktop (.*): see above' "$CT/out"
ct_kill 'motion spotlight' "'motion', 'spotlight'" >/dev/null

# --- image.sh: the rebuild lane's lock in the image context ------------------------------
image_sh() { bash -c '. "$1"; shift; eval "$1"' _ "$APEX_ROOT/.github/scripts/image.sh" "$@"; }
IL="$TMP/image-lane"
mkdir -p "$IL/pkgs/gnome-shell/k1"
ilsha=$(printf 'c%.0s' {1..64})
{
    printf '# apex rpms.lock 1: written by apex-lane (packaging/README.md, "rpms.lock")\n'
    printf 'family gnome-shell built k1\n'
    printf 'rpm gnome-shell built gnome-shell gnome-shell-0:51.0-1.fc45.apex1.x86_64 %s pkgs/gnome-shell/k1/gnome-shell-51.0-1.fc45.apex1.x86_64.rpm\n' "$ilsha"
    printf 'rpm gnome-shell mirror mutter mutter-0:51.0-1.fc45.x86_64 %s pkgs/gnome-shell/k1/mutter-51.0-1.fc45.x86_64.rpm\n' "$ilsha"
    printf 'family libfprint degraded - since=2026-10-12T04:10:00Z reason=0001 does not apply\n'
} >"$IL/rpms.lock"
check "lane lock: the RPMs to copy" "pkgs/gnome-shell/k1/gnome-shell-51.0-1.fc45.apex1.x86_64.rpm $ilsha
pkgs/gnome-shell/k1/mutter-51.0-1.fc45.x86_64.rpm $ilsha" "$(image_sh "lane_lock_check '$IL/rpms.lock' gnome-shell libfprint" 2>/dev/null)"
check "lane lock: degraded families" libfprint "$(image_sh "lane_lock_states '$IL/rpms.lock' degraded")"
check "lane lock: no held family" "" "$(image_sh "lane_lock_states '$IL/rpms.lock' held")"
mkdir -p "$IL/r1/packaging/pkgs/a" "$IL/r2/packaging/pkgs/b"
printf 'family=fa\n' >"$IL/r1/packaging/pkgs/a/pkg.env"
printf 'family=fb\n' >"$IL/r2/packaging/pkgs/b/pkg.env"
check "lane families: every checkout in APEX_LANE_RECIPES" "fa fb" \
    "$(APEX_LANE_RECIPES="$IL/r1:$IL/r2" image_sh lane_families | paste -sd' ' -)"
bad_lane() {
    local name=$1 sed_script=$2
    shift 2
    local families=${*:-gnome-shell}
    sed -e "$sed_script" "$IL/rpms.lock" >"$IL/bad.lock"
    check "lane lock refuses $name" 1 "$(rc_of image_sh "lane_lock_check '$IL/bad.lock' $families")"
}
# shellcheck disable=SC2016 # sed scripts: $a appends a line
{
    bad_lane "a lock that misses a lane family" 's/^x//' gnome-shell nautilus
    bad_lane "another format" '1s/rpms.lock 1:/rpms.lock 2:/'
    bad_lane "an unknown state" 's/^family gnome-shell built/family gnome-shell maybe/'
    bad_lane "a repeated family" '$a family gnome-shell stock -'
    bad_lane "rpm lines of a stock family" 's/^family gnome-shell built/family gnome-shell stock/'
    bad_lane "an rpm line before its family" '2d'
    bad_lane "a built family with mirrors only" '/ built gnome-shell /d'
    bad_lane "a NEVRA of another package" 's/built gnome-shell gnome-shell-0:/built gnome-shell mutter-0:/'
    bad_lane "a NEVRA without an epoch" 's/gnome-shell-0:51/gnome-shell-51/'
    bad_lane "a short sha256" "s/$ilsha/abc/"
    bad_lane "a path outside the store" 's|pkgs/gnome-shell/k1/mutter|../mutter|'
    bad_lane "an absolute path" 's| pkgs/gnome-shell/k1/mutter| /tmp/mutter|'
    bad_lane "a file name that is not the NEVRA's" 's|/mutter-51.0-1.fc45.x86_64.rpm|/mutter-51.0-2.fc45.x86_64.rpm|'
    bad_lane "a package twice" '$a rpm gnome-shell mirror mutter mutter-0:51.0-1.fc45.x86_64 '"$ilsha"' pkgs/gnome-shell/k1/mutter-51.0-1.fc45.x86_64.rpm'
    bad_lane "an unknown record" '$a pin mutter 51.0'
}
check "lane lock refuses a missing file" 1 "$(rc_of image_sh "lane_lock_check '$IL/nope.lock' gnome-shell")"
GOLDEN=$APEX_ROOT/crates/apex-lane/tests/golden
golden_locks=0
for g in "$GOLDEN"/lock/b-*.lock "$GOLDEN"/lock/store-rpms.lock.next "$GOLDEN"/hold/*/expect/rpms.lock.next; do
    [[ -f $g ]] || continue
    golden_locks=$((golden_locks + 1))
    check "lane lock: apex-lane's golden ${g#"$GOLDEN"/} is accepted" 0 "$(rc_of image_sh "lane_lock_check '$g' gnome-shell")"
done
check "lane lock: apex-lane's golden locks are there" 1 "$((golden_locks > 0))"
mkdir -p "$IL/rpms" "$IL/desktop"
: >"$IL/rpms/apex-0.1.0-1.fc45.x86_64.rpm"
: >"$IL/desktop/apex-desktop-0.1.0-1.fc45.noarch.rpm"
(cd "$IL/rpms" && sha256sum -- *.rpm >SHA256SUMS)
(cd "$IL/desktop" && sha256sum -- *.rpm >SHA256SUMS)
image_context() {
    ctx_rc=0
    ctx_log=$(APEX_WORK="$IL/work" GITHUB_ACTIONS='' "$APEX_ROOT/.github/scripts/image.sh" context "$@" 2>&1) || ctx_rc=$?
}
image_context --rpms-dir "$IL/rpms" --desktop-dir "$IL/desktop"
check "image.sh context without --lane-lock fails" 1 "$ctx_rc"
check_true "and says the lane's lock is required" grep -q "the rebuild lane's lock is required" <<<"$ctx_log"
image_context --rpms-dir "$IL/rpms" --lane-lock "$IL/rpms.lock"
check "image.sh context without apex-desktop's RPMs fails" 1 "$ctx_rc"
check_true "and says apex-desktop is required" grep -q "apex-desktop is required" <<<"$ctx_log"
image_context --rpms-dir "$IL/rpms" --desktop-dir "$IL/desktop" --lane-lock "$IL/rpms.lock" --kernel cachyos
check "image.sh context --kernel takes fedora only" 1 "$ctx_rc"
image_context --rpms-dir "$IL/rpms" --desktop-dir "$IL/desktop" --lane-lock "$IL/rpms.lock" --kernel fedora
check "break-glass of a lock without a kernel pair fails" 1 "$ctx_rc"
check_true "and says the image already uses Fedora's kernel" \
    grep -q "no kernel pair in the lane lock .*: the image already uses Fedora's kernel" <<<"$ctx_log"
check_false "and writes no break-glass lock" test -e "$IL/work/break-glass.lock"
{
    cat "$IL/rpms.lock"
    printf 'family kernel-cachyos built kk
'
    printf 'rpm kernel-cachyos built kernel-cachyos-core kernel-cachyos-core-0:7.3.0-4.cachyos1.fc45.x86_64 %s pkgs/kernel/kk/kernel-cachyos-core-7.3.0-4.cachyos1.fc45.x86_64.rpm\n' "$ilsha"
} >"$IL/pair.lock"
image_sh "break_glass_lock '$IL/pair.lock'" >"$IL/break-glass.lock"
check "break-glass: the image's lock keeps the other families" 2 "$(grep -c '^family gnome-shell \|^family libfprint ' "$IL/break-glass.lock")"
check "break-glass: and none of the pair's rpm lines" 0 "$(grep -c '^rpm kernel-cachyos ' "$IL/break-glass.lock" || true)"
check "break-glass: the pair is the owner's stock choice" \
    "family kernel-cachyos stock - reason=break-glass: just image KERNEL=fedora, Fedora's kernel without the NVIDIA set" \
    "$(grep '^family kernel-cachyos ' "$IL/break-glass.lock")"
check "break-glass: a lock image.sh accepts, with the kernel family" 0 \
    "$(rc_of image_sh "lane_lock_check '$IL/break-glass.lock' gnome-shell libfprint kernel-cachyos")"
check "break-glass: and the store's lock is untouched" 1 "$(grep -c '^family kernel-cachyos built kk$' "$IL/pair.lock")"

# --- Fedora images: digest pins on registry.fedoraproject.org only ------------------------
DQ="sha256:$(printf 'd%.0s' {1..64})"
check_true "a registry.fedoraproject.org digest pin" is_fedora_pin "registry.fedoraproject.org/fedora-bootc@$DQ"
check_true "a registry.fedoraproject.org digest pin with a tag" is_fedora_pin "registry.fedoraproject.org/fedora:45@$DQ"
check_false "a quay.io digest pin is refused" is_fedora_pin "quay.io/fedora/fedora-bootc@$DQ"
check_false "a floating tag is refused" is_fedora_pin registry.fedoraproject.org/fedora:45
check_false "another registry is refused" is_fedora_pin "ghcr.io/x/fedora@$DQ"
check_false "a lookalike host is refused" is_fedora_pin "registry.fedoraproject.org.evil.example/fedora@$DQ"
check_false "a nested repository is refused" is_fedora_pin "registry.fedoraproject.org/x/fedora@$DQ"
if [[ -f $APEX_CONTAINERFILE ]]; then
    for arg in BASE REPOS_BASE; do
        check_true "image/Containerfile ARG $arg is a registry.fedoraproject.org digest pin" \
            is_fedora_pin "$(containerfile_arg "$arg")"
    done
fi
# One Fedora key per release, the same in apex-lane, the image checks and the release's env.
for release in 45 46; do
    lane_fpr=$(grep -oE "\(\"$release\", \"[0-9A-Fa-f]{40}\"\)" "$APEX_ROOT/crates/apex-lane/src/core/fedora.rs" |
        grep -oE '[0-9A-Fa-f]{40}')
    checks_fpr=$(sed -n "s/^FEDORA_${release}_KEY_FPR=//p" "$APEX_ROOT/image/checks/lib/common.sh")
    env_fpr=$(sed -n 's/^FEDORA_KEY_FPR=//p' "$APEX_ROOT/image/fedora/$release.env" 2>/dev/null || true)
    check "Fedora $release's key: apex-lane's table and image/checks agree" "${lane_fpr^^}" "${checks_fpr^^}"
    [[ $release == 45 ]] || check "and image/fedora/$release.env too" "${lane_fpr^^}" "${env_fpr^^}"
    check_true "Fedora $release's key is a fingerprint" grep -qE '^[0-9A-F]{40}$' <<<"${lane_fpr^^}"
done
for env in "$APEX_ROOT"/image/fedora/*.env; do
    for arg in BASE REPOS_BASE; do
        pin=$(sed -n "s/^$arg=//p" "$env")
        check_true "${env#"$APEX_ROOT"/} $arg is a registry.fedoraproject.org digest pin" is_fedora_pin "$pin"
        check_false "and not 45's ($arg)" test "$pin" = "$(containerfile_arg "$arg")"
    done
done
IB="$TMP/image-build"
mkdir -p "$IB/bin" "$IB/work" "$IB/tree/.github" "$IB/tree/image"
cp -R "$APEX_ROOT/.github/scripts" "$IB/tree/.github/"
cat >"$IB/bin/podman" <<'EOF'
#!/usr/bin/env bash
echo "unexpected: $0 $*" >&2
exit 99
EOF
cp "$IB/bin/podman" "$IB/bin/git"
chmod +x "$IB/bin/podman" "$IB/bin/git"
: >"$IB/work/inputs.env"
image_build_with() {
    local sed_script=$1
    sed "$sed_script" "$APEX_CONTAINERFILE" >"$IB/tree/image/Containerfile"
    ib_rc=0
    ib_log=$(PATH="$IB/bin:$PATH" APEX_WORK="$IB/work" GITHUB_ACTIONS='' \
        "$IB/tree/.github/scripts/image.sh" build 2>&1) || ib_rc=$?
}
for arg in BASE REPOS_BASE; do
    image_build_with "s|^ARG $arg=registry\.fedoraproject\.org/|ARG $arg=quay.io/fedora/|"
    check "image.sh build refuses ARG $arg on quay.io" 1 "$ib_rc"
    check_true "and says it must be on registry.fedoraproject.org ($arg)" \
        grep -q "ARG $arg in image/Containerfile must be a digest pin on registry.fedoraproject.org" <<<"$ib_log"
    check_false "and never reaches podman or git ($arg)" grep -q unexpected <<<"$ib_log"
done
image_build_with 's|^ARG REPOS_BASE=.*|ARG REPOS_BASE=|'
check "image.sh build refuses an empty REPOS_BASE" 1 "$ib_rc"
image_build_with 's|^\(ARG BASE=registry\.fedoraproject\.org/fedora-bootc\)@.*|\1:45|'
check "image.sh build refuses a floating BASE tag" 1 "$ib_rc"
# Past the check, image.sh build calls the fake git for the revision.
image_build_with 's|^$||'
check_true "the committed Containerfile passes the check" grep -q 'unexpected: .*git' <<<"$ib_log"
printf '#!/usr/bin/env bash\nexec "$@"\n' >"$IB/bin/sudo"
printf '#!/usr/bin/env bash\nprintf "%%040d\\n" 7\n' >"$IB/bin/git"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s"\n' "$IB/podman.log" >"$IB/bin/podman"
chmod +x "$IB/bin/sudo"
image_build_with 's|^$||'
check "image.sh build runs to its end against a podman that only records" 0 "$ib_rc"
built_version=$(sed -n 's/^APEX_VERSION=//p' "$IB/work/build.env")
check_true "it labels the image with the version it gives the manifest" \
    grep -q -- "^build .*--build-arg APEX_VERSION=$built_version .*--label org.opencontainers.image.version=$built_version " "$IB/podman.log"
# A 45 build is main's, argument for argument: the next lane adds only where it is next.
ib_steps() { # [ENV...]: image.sh build, inspect's env and rechunk; prints podman's build and run lines
    rm -f "$IB/podman.log"
    rm -rf "$IB/work" "$IB/tree/_build" && mkdir -p "$IB/work" && : >"$IB/work/inputs.env"
    env PATH="$IB/bin:$PATH" APEX_WORK="$IB/work" GITHUB_ACTIONS='' APEX_RUN_NUMBER=0 "$@" \
        "$IB/tree/.github/scripts/image.sh" build >/dev/null 2>&1 || return
    printf 'DEGRADED=\nHELD=\nCONTENT_KEY=k\nKERNEL_PAIR=none\n' >"$IB/work/image.env"
    env PATH="$IB/bin:$PATH" APEX_WORK="$IB/work" GITHUB_ACTIONS='' APEX_PREVIOUS_BUILD=none "$@" \
        "$IB/tree/.github/scripts/image.sh" rechunk >/dev/null 2>&1 || return
    grep -E '^(build|run) ' "$IB/podman.log"
}
printf '#!/usr/bin/env bash\necho "{\\"layers\\": []}"\n' >"$IB/bin/skopeo"
cat >"$IB/bin/podman" <<EOF
#!/usr/bin/env bash
printf '%s\\n' "\$*" >>"$IB/podman.log"
[[ "\$1 \$2" != "image inspect" ]] || echo 46.20261024.0
EOF
chmod +x "$IB/bin/skopeo"
sed 's|^$||' "$APEX_CONTAINERFILE" >"$IB/tree/image/Containerfile"
ib45=$(ib_steps) || ib45="image.sh failed: $ib45"
ib_v=$(sed -n 's/^APEX_VERSION=//p' "$IB/work/build.env")
ib_created=$(sed -n 's/^CREATED=//p' "$IB/work/build.env")
ib_base=$(containerfile_arg BASE)
check "a 45 build and rechunk take main's arguments, tag and labels" \
    "build --pull=missing --layers=false --cap-add=SYS_ADMIN,NET_ADMIN --device /dev/fuse \
--security-opt seccomp=unconfined --security-opt label=disable --build-arg BASE=$ib_base \
--build-arg REPOS_BASE=$(containerfile_arg REPOS_BASE) --build-arg APEX_VERSION=$ib_v \
--build-arg APEX_REVISION=$(printf '%040d' 7) --build-arg GA_REACHED=$(containerfile_arg GA_REACHED) \
--build-arg RELEASE_BUILD=0 --label org.opencontainers.image.version=$ib_v \
-f $IB/tree/image/Containerfile -t localhost/apex:build $IB/tree
run --rm --privileged --pull=never --security-opt label=disable \
--mount type=image,source=localhost/apex:build,target=/apex-rootfs -v $IB/work/oci:/out:z \
-v $IB/work/rechunk-tmp:/var/tmp:z --entrypoint /usr/bin/rpm-ostree $ib_base \
compose build-chunked-oci --bootc --format-version=2 --max-layers 127 --rootfs /apex-rootfs \
--label org.opencontainers.image.version=$ib_v --label org.opencontainers.image.revision=$(printf '%040d' 7) \
--label org.opencontainers.image.source=$APEX_SOURCE_URL --label org.opencontainers.image.created=$ib_created \
--label $APEX_LABEL_PREFIX.degraded= --label $APEX_LABEL_PREFIX.held= --label $APEX_LABEL_PREFIX.content-key=k \
--label $APEX_LABEL_PREFIX.fedora=45 --label $APEX_LABEL_PREFIX.kernel-pair=none --output oci:/out/apex:latest" \
    "$ib45"
check "and its version is 45.<date>.<run>" "45.$(date -u +%Y%m%d).0" "$ib_v"
mkdir -p "$IB/tree/image/fedora"
cp "$APEX_ROOT/image/fedora/46.env" "$IB/tree/image/fedora/"
ib_next_env() { sed -n "s/^$1=//p" "$APEX_ROOT/image/fedora/46.env"; }
ib46=$(ib_steps APEX_FEDORA=46) || ib46="image.sh failed: $ib46"
check "a 46 build takes 46.env's BASE and REPOS_BASE, never 45's" \
    "--build-arg BASE=$(ib_next_env BASE) --build-arg REPOS_BASE=$(ib_next_env REPOS_BASE) " \
    "$(grep -o -- '--build-arg BASE=[^ ]* --build-arg REPOS_BASE=[^ ]* ' <<<"$ib46")"
check "with its FEDORA and GA date, tagged localhost/apex:46" \
    "--build-arg FEDORA=46 --build-arg FEDORA_GA_DATE=$(ib_next_env FEDORA_GA_DATE) \
-f $IB/tree/image/Containerfile -t localhost/apex:46 " \
    "$(grep -o -- '--build-arg FEDORA=.* -t [^ ]* ' <<<"$ib46")"
check "its version is 46.<date>.<run>" "46.$(date -u +%Y%m%d).0" "$(sed -n 's/^APEX_VERSION=//p' "$IB/work/build.env")"
check "and build.env records the base's source and version label, for the report" "rawhide|46.20261024.0" \
    "$(sed -n 's/^BASE_SOURCE=//p' "$IB/work/build.env")|$(sed -n 's/^BASE_VERSION=//p' "$IB/work/build.env")"
check "and rechunk labels it Fedora 46 and the next lane, last" \
    "--label $APEX_LABEL_PREFIX.fedora=46 --label $APEX_LABEL_PREFIX.kernel-pair=none \
--label $APEX_LABEL_PREFIX.lane=next --output oci:/out/apex:latest" \
    "$(grep -o -- "--label $APEX_LABEL_PREFIX.fedora=.*" <<<"$ib46")"
check "rechunk runs 46.env's BASE" 1 "$(grep -c -- "--entrypoint /usr/bin/rpm-ostree $(ib_next_env BASE) " <<<"$ib46")"
check "a 45 build has no next-lane label or FEDORA argument" 0 "$(grep -c -e '\.lane=' -e 'FEDORA=' <<<"$ib45")"
mkdir -p "$IB/tree/_build/next/image" && : >"$IB/tree/_build/next/image/inputs.env"
env PATH="$IB/bin:$PATH" GITHUB_ACTIONS='' APEX_FEDORA=46 "$IB/tree/.github/scripts/image.sh" build >/dev/null 2>&1 || true
check_true "a 46 image.sh keeps its state in _build/next/image, not 45's _build/image" \
    test -s "$IB/tree/_build/next/image/build.env" -a ! -e "$IB/tree/_build/image"
rm -f "$IB/podman.log"
ib_rc=0
ib_log=$(env PATH="$IB/bin:$PATH" GITHUB_ACTIONS='' APEX_FEDORA=46 APEX_WORK="$IB/work" \
    "$IB/tree/.github/scripts/image.sh" push 2>&1) || ib_rc=$?
check "image.sh push refuses the next lane" 1 "$ib_rc"
check_true "and says it never pushes" grep -q 'next lane: it never pushes' <<<"$ib_log"
check_false "before podman" test -e "$IB/podman.log"
ib_rc=0
ib_log=$(env APEX_FEDORA=47 "$IB/tree/.github/scripts/image.sh" build 2>&1) || ib_rc=$?
check "a release without its image/fedora/N.env is refused" "2|1" \
    "$ib_rc|$(grep -c 'APEX_FEDORA=47 has no image/fedora/47.env' <<<"$ib_log")"
wf_quay=$(grep -rhoE 'quay\.io/fedora/[a-z0-9._-]+(:[A-Za-z0-9._-]+)?@sha256:[0-9a-f]{64}' \
    "$APEX_ROOT/.github/workflows" || true)
check "no workflow pins a Fedora image by digest on quay.io" "" "$wf_quay"
wf_unpinned=$(grep -rhE '^[[:space:]]*image:[[:space:]]' "$APEX_ROOT/.github/workflows" |
    grep -vE 'image: registry\.fedoraproject\.org/fedora:45@sha256:[0-9a-f]{64}$' || true)
check "every workflow container is registry.fedoraproject.org/fedora:45 by digest" "" "$wf_unpinned"
quay_refs=$(grep -nE '^[[:space:]]*[^#[:space:]].*quay' "$APEX_ROOT"/.github/scripts/*.sh \
    "$APEX_ROOT"/.github/workflows/*.yml "$APEX_ROOT/Justfile" "$APEX_CONTAINERFILE" |
    grep -v '/selftest\.sh:' || true)
check "quay.io is used nowhere in scripts, workflows, the Justfile or the Containerfile" "" "$quay_refs"

# --- renovate.json: every Containerfile digest pin and component pin has a manager -------
# The Fedora rules (one group, no release jumps) live in apex-ci's preset, which this extends.
if command -v python3 >/dev/null 2>&1; then
    renovate_problems=$(python3 - "$APEX_ROOT" <<'PY'
import json, re, sys
root = sys.argv[1]
cfg = json.load(open(f"{root}/renovate.json"))
problems = []
if cfg.get("extends") != ["local>apex-linux/apex-ci"]:
    problems.append("renovate.json does not extend local>apex-linux/apex-ci alone")
# Renovate's regex managers use JavaScript named groups; Python spells them (?P<...>).
def py(rx):
    return re.compile(rx.replace("(?<", "(?P<"))
def managers_of(path):
    return [m for m in cfg.get("customManagers", [])
            if any(re.search(p.strip("/"), path) for p in m.get("managerFilePatterns", []))]
def check_lines(path, pin):
    managers = managers_of(path)
    for line in open(f"{root}/{path}").read().splitlines():
        if not re.match(pin, line):
            continue
        hits = [(m, g) for m in managers for rx in m["matchStrings"] if (g := py(rx).search(line))]
        if len(hits) != 1:
            problems.append(f"{len(hits)} custom managers match: {line}")
            continue
        m, g = hits[0]
        new = re.sub(r"[0-9a-f]", "e", g.group("currentDigest"))
        out = m["autoReplaceStringTemplate"]
        for k in ("depName", "packageName"):
            if k in g.groupdict():
                out = out.replace("{{{" + k + "}}}", g.group(k))
        out = out.replace("{{{newDigest}}}", new)
        if out != line.strip().replace(g.group("currentDigest"), new):
            problems.append(f"replacement template rewrites '{line}' as '{out}'")
check_lines("image/Containerfile", r"^ARG [A-Z_]+=\S+@sha256:[0-9a-f]{64}\s*$")
check_lines("components.lock", r"^apex-[a-z-]+ \S+ [0-9a-f]{40}$")
for m in cfg.get("customManagers", []):
    for rx in m.get("matchStrings", []):
        if "quay" in rx:
            problems.append(f"a custom manager still accepts quay.io: {rx}")
print("\n".join(problems))
PY
)
    check "renovate.json keeps every Containerfile and component pin current" "" "$renovate_problems"
    check "components.lock: every line is a comment or a pinned component" "" \
        "$(grep -vE '^(#.*|apex-[a-z-]+ https://github\.com/apex-linux/[a-z-]+ [0-9a-f]{40})$' "$APEX_ROOT/components.lock" || true)"
    matches=$(python3 - "$APEX_ROOT" <<'PY'
import json, re, sys
cfg = json.load(open(f"{sys.argv[1]}/renovate.json"))
def hits(line):
    return sum(1 for m in cfg["customManagers"] for rx in m["matchStrings"]
               if re.compile(rx.replace("(?<", "(?P<")).search(line))
d = "@sha256:" + "1" * 64
print(" ".join(str(hits(l)) for l in [
    "ARG BASE=registry.fedoraproject.org/fedora-bootc" + d,
    "ARG REPOS_BASE=registry.fedoraproject.org/fedora" + d,
    "ARG BASE=quay.io/fedora/fedora-bootc" + d,
    "ARG REPOS_BASE=quay.io/fedora/fedora" + d,
    "apex-gnome https://github.com/apex-linux/apex-gnome " + "1" * 40,
    "apex-gnome https://example.org/apex-gnome " + "1" * 40]))
PY
)
    check "managers: BASE, REPOS_BASE and a component match one each; quay.io and other hosts none" \
        "1 1 0 0 1 0" "$matches"
fi

# --- ci-host.sh: preflight measures the scratch directory storage chose -----------------
H="$TMP/host"
mkdir -p "$H/store" "$H/scratch" "$H/runner"
printf '%s\n' "$H/scratch" >"$H/runner/apex-scratch"
host_rc=0
host_log=$(env -u APEX_SCRATCH RUNNER_TEMP="$H/runner" APEX_CI_STORE="$H/store" GITHUB_ACTIONS='' \
    "$APEX_ROOT/.github/scripts/ci-host.sh" preflight 0 0 2>&1) || host_rc=$?
check "preflight passes" 0 "$host_rc"
check_true "preflight reads the recorded scratch directory, not /var/tmp" grep -qF -- "$H/scratch" <<<"$host_log"
host_log=$(env -u APEX_SCRATCH RUNNER_TEMP="$H/none" APEX_CI_STORE="$H/store" GITHUB_ACTIONS='' \
    "$APEX_ROOT/.github/scripts/ci-host.sh" preflight 0 0 2>&1 || true)
check_true "preflight without a recorded directory says so" grep -q "no scratch directory recorded" <<<"$host_log"
check "APEX_SCRATCH wins over the record" /elsewhere \
    "$(APEX_SCRATCH=/elsewhere RUNNER_TEMP="$H/runner" bash -c '. "$1"; scratch_dir' _ "$APEX_ROOT/.github/scripts/ci-host.sh")"

# --- qualify.sh: the guests never depend on Flathub -------------------------------------
kargs=$(bash -c '. "$1"; install_kargs' _ "$APEX_ROOT/.github/scripts/qualify.sh" | paste -sd' ' -)
for unit in apex-flatpak-preinstall.service apex-flatpak-preinstall.timer \
    apex-flatpak-update.service apex-flatpak-update.timer; do
    check_true "qualification masks $unit" grep -qF -- "--karg systemd.mask=$unit" <<<"$kargs"
done
check_true "qualification still enables sshd" grep -qF -- "--karg systemd.wants=sshd.service" <<<"$kargs"
units_dir="$APEX_ROOT/image/system_files/usr/lib/systemd/system"
if [[ -d $units_dir ]]; then
    unmasked=$(find "$units_dir" -maxdepth 1 -name '*flatpak*' -printf '%f\n' | sort |
        while read -r u; do grep -qF -- "systemd.mask=$u" <<<"$kargs" || printf '%s ' "$u"; done)
    check "every Flatpak unit of the image is masked in qualification" "" "$unmasked"
fi

# --- image.sh replay-check: only main-branch image.yml runs of this repository ----------
run_json() { # EVENT BRANCH HEAD_REPO [PATH]
    jq -n --arg e "$1" --arg b "$2" --arg h "$3" --arg p "${4:-.github/workflows/image.yml}" \
        '{path: $p, event: $e, head_branch: $b, head_sha: "abc", status: "completed",
          conclusion: "success", head_repository: {full_name: $h},
          repository: {full_name: "apex-linux/apex-image"}}'
}
R=apex-linux/apex-image
check_true "a scheduled main run may be replayed" replay_run_ok "$R" <<<"$(run_json schedule main "$R")"
check_true "a push to main may be replayed" replay_run_ok "$R" <<<"$(run_json push main "$R")"
check_false "a pull request run may not" replay_run_ok "$R" <<<"$(run_json pull_request main "$R")"
check_false "a fork's run may not" replay_run_ok "$R" <<<"$(run_json pull_request main evil/apex-fedora)"
check_false "a dispatch on another branch may not" replay_run_ok "$R" <<<"$(run_json workflow_dispatch wip "$R")"
check_false "another workflow's run may not" replay_run_ok "$R" \
    <<<"$(run_json push main "$R" .github/workflows/ci.yml)"
check_false "a run still in progress may not" replay_run_ok "$R" \
    <<<"$(run_json push main "$R" | jq '.status = "in_progress"')"
check_false "a run without a head repository may not" replay_run_ok "$R" \
    <<<"$(run_json push main "$R" | jq '.head_repository = null')"
mkdir -p "$TMP/gh-bin" "$TMP/runs"
cat >"$TMP/gh-bin/gh" <<'EOF'
#!/usr/bin/env bash
# Fake gh: `gh api repos/<repo>/actions/runs/<id>` answers from $FAKE_RUNS/<id>.json.
[[ $1 == api ]] || exit 3
id=${2##*/}
cat "$FAKE_RUNS/$id.json" 2>/dev/null || { echo 'HTTP 404' >&2; exit 1; }
EOF
chmod +x "$TMP/gh-bin/gh"
run_json schedule main "$R" >"$TMP/runs/11.json"
run_json pull_request main evil/apex-fedora >"$TMP/runs/12.json"
replay() {
    PATH="$TMP/gh-bin:$PATH" FAKE_RUNS="$TMP/runs" GITHUB_REPOSITORY=$R GITHUB_ACTIONS='' \
        GITHUB_STEP_SUMMARY=/dev/null rc_of "$APEX_ROOT/.github/scripts/image.sh" replay-check "$1"
}
check "replay-check accepts a main schedule run" 0 "$(replay 11)"
check "replay-check refuses a fork PR run" 1 "$(replay 12)"
check "replay-check refuses an unreadable run" 1 "$(replay 13)"
check "replay-check refuses a non-numeric id" 1 "$(replay '11;x')"

# --- commit order: publish.sh never moves a tag back to older code ----------------------
G="$TMP/git"
git init -q "$G"
gitc() { git -C "$G" -c user.name=t -c user.email=t@example.invalid "$@"; }
gitc commit -q --allow-empty -m A
C_A=$(git -C "$G" rev-parse HEAD)
gitc commit -q --allow-empty -m B
C_B=$(git -C "$G" rev-parse HEAD)
gitc checkout -q -b side "$C_A"
gitc commit -q --allow-empty -m S
C_S=$(git -C "$G" rev-parse HEAD)
C_X=$(printf 'f%.0s' {1..40})
desc_rc() { APEX_GIT_ROOT=$G rc_of revision_descends "$1" "$2"; }
check "a descendant descends" 0 "$(desc_rc "$C_A" "$C_B")"
check "the same commit counts" 0 "$(desc_rc "$C_B" "$C_B")"
check "an older commit does not" 1 "$(desc_rc "$C_B" "$C_A")"
check "a sibling branch does not" 1 "$(desc_rc "$C_B" "$C_S")"
check "an unknown commit is unknown, not older" 2 "$(desc_rc "$C_X" "$C_B")"
check "an empty revision is unknown" 2 "$(desc_rc "" "$C_B")"

P="$TMP/publish"
mkdir -p "$P/bin" "$P/reg"
cat >"$P/bin/skopeo" <<'EOF'
#!/usr/bin/env bash
ref=${*: -1}
ref=${ref#docker://}
if [[ $1 == list-tags ]]; then
    [[ ! -f $FAKE_REG/list-tags.err ]] || { cat "$FAKE_REG/list-tags.err" >&2; exit 1; }
    [[ -f $FAKE_REG/tags.json ]] || { echo 'Error: listing tags: 502 Bad Gateway' >&2; exit 1; }
    cat "$FAKE_REG/tags.json"
    exit 0
fi
tag=${ref##*:}
if [[ -f $FAKE_REG/$tag.fail ]]; then echo 'Error: 502 Bad Gateway' >&2; exit 1; fi
if [[ -f $FAKE_REG/$tag.json ]]; then cat "$FAKE_REG/$tag.json"; exit 0; fi
echo "Error: reading manifest $tag in ${ref%:*}: manifest unknown" >&2
exit 1
EOF
chmod +x "$P/bin/skopeo"
label_json() { # DIGEST_CHAR VERSION REVISION
    jq -n --arg d "sha256:$(printf "$1%.0s" {1..64})" --arg v "$2" --arg r "$3" \
        '{Digest: $d, Labels: {"org.opencontainers.image.version": $v, "org.opencontainers.image.revision": $r}}'
}
increases() {
    # shellcheck disable=SC2016 # expanded by the inner bash
    PATH="$P/bin:$PATH" FAKE_REG="$P/reg" APEX_GIT_ROOT="$G" APEX_RETRY_DELAY=0 GITHUB_ACTIONS='' \
        rc_of bash -c '. "$1"; shift; check_increases "$@"' _ "$APEX_ROOT/.github/scripts/publish.sh" "$@"
}
D1="sha256:$(printf '1%.0s' {1..64})"
D2="sha256:$(printf '2%.0s' {1..64})"
label_json 1 45.20260924.150 "$C_A" >"$P/reg/45.json"
check "a newer version on a descendant commit moves" 0 "$(increases ghcr.io/x/t:45 "$D2" 45.20260925.151 "$C_B")"
label_json 1 45.20260924.150 "$C_B" >"$P/reg/45.json"
check "a re-run of an older run (newer date, ancestor commit) is refused" 1 \
    "$(increases ghcr.io/x/t:45 "$D2" 45.20260925.149 "$C_A")"
check "a newer version on a commit off main's line is refused" 1 \
    "$(increases ghcr.io/x/t:45 "$D2" 45.20260925.151 "$C_S")"
check "an unknown candidate commit is refused" 1 "$(increases ghcr.io/x/t:45 "$D2" 45.20260925.151 "$C_X")"
check "already there is a no-op" 10 "$(increases ghcr.io/x/t:45 "$D1" 45.20260925.151 "$C_B")"
check "an older version is refused" 1 "$(increases ghcr.io/x/t:45 "$D2" 45.20260923.999 "$C_B")"
rm -f "$P/reg/45.json"
printf '{"Repository":"ghcr.io/x/t","Tags":["sha-1","45.20260924.150"]}' >"$P/reg/tags.json"
check "an absent tag that list-tags confirms is a first publication" 0 \
    "$(increases ghcr.io/x/t:45 "$D2" 45.20260925.151 "$C_B")"
printf '{"Repository":"ghcr.io/x/t","Tags":["45"]}' >"$P/reg/tags.json"
check "an absent tag that list-tags still lists is refused" 1 \
    "$(increases ghcr.io/x/t:45 "$D2" 45.20260925.151 "$C_B")"
rm -f "$P/reg/tags.json"
check "an absent tag that list-tags cannot confirm is refused" 1 \
    "$(increases ghcr.io/x/t:45 "$D2" 45.20260925.151 "$C_B")"
echo 'time="2026-10-24T19:06:34Z" level=fatal msg="Error listing repository tags: fetching tags list: repository name not known to registry"' \
    >"$P/reg/list-tags.err"
check "a repository registry:2 does not know yet is a first publication" 0 \
    "$(increases ghcr.io/x/t:45 "$D2" 45.20260925.151 "$C_B")"
rm -f "$P/reg/list-tags.err"

# --- publish.sh: a stable move never adds a degraded component without the owner -------
degraded_json() { # DIGEST_CHAR DEGRADED
    jq -n --arg d "sha256:$(printf "$1%.0s" {1..64})" --arg g "$2" --arg l "$APEX_LABEL_PREFIX.degraded" \
        '{Digest: $d, Labels: {"org.opencontainers.image.version": "45.20260925.151", ($l): $g}}'
}
degraded_rc() { # PUBLISHED-TAG CANDIDATE-DEGRADED [ALLOW]
    degraded_json 2 "$2" >"$P/reg/${D2#sha256:}.json"
    # shellcheck disable=SC2016 # expanded by the inner bash
    PATH="$P/bin:$PATH" FAKE_REG="$P/reg" APEX_RETRY_DELAY=0 GITHUB_ACTIONS='' \
        rc_of bash -c '. "$1"; shift; check_degraded "$@"' _ "$APEX_ROOT/.github/scripts/publish.sh" \
        "ghcr.io/x/t:$1" "$D2" "${3:-0}"
}
degraded_json 1 fingerprint >"$P/reg/45.json"
check "the same degraded set moves" 0 "$(degraded_rc 45 fingerprint)"
check "a smaller degraded set moves" 0 "$(degraded_rc 45 '')"
check "a degraded component the published image lacks is refused" 1 "$(degraded_rc 45 fingerprint,nvidia)"
check "the owner's --allow-degraded moves it" 0 "$(degraded_rc 45 fingerprint,nvidia 1)"
degraded_json 1 audio,fingerprint >"$P/reg/45.json"
check "another set of the same size that adds one is refused" 1 "$(degraded_rc 45 fingerprint,nvidia)"
rm -f "$P/reg/45.json"
check "a first publication of a degraded image is refused" 1 "$(degraded_rc 45 nvidia)"
check "a first publication of a whole image moves" 0 "$(degraded_rc 45 '')"
printf 'broken' >"$P/reg/broken.fail"
check "a published tag that cannot be read is refused" 1 "$(degraded_rc broken '')"

# --- qualify.sh luks: the passphrase goes into Plymouth's prompt once systemd-cryptsetup asks ---
L="$TMP/luks"
luks() { # [wrong] [FROM]: luks_unlock on a fake serial console and QMP; prints the exit status
    local rc=0
    mkdir -p "$L/out/logs"
    : >"$L/out/results.md"
    # shellcheck disable=SC2016 # expanded by the inner bash
    QUALIFY_OUT="$L/out" QUALIFY_POLL=0.01 QUALIFY_LOGIN_TIMEOUT=2 QUALIFY_BOOT_TIMEOUT=2 GITHUB_ACTIONS='' \
        bash -c '
        . "$1"
        VM_SERIAL=$2/serial LUKS_PASSPHRASE=0123456789abcdef01234567 QMP_SOCKET=$2/qmp
        vm_alive() { [[ ! -e $FAKE/stopped ]]; }
        save_journal() { :; }
        qmp() {
            local cmd keys
            for cmd in "$@"; do
                keys=$(jq -r "select(.execute == \"send-key\") | [.arguments.keys[].data] | join(\"+\")" <<<"$cmd")
                case $keys in
                    "") ;;
                    ret)
                        if [[ $(cat "$FAKE/typed" 2>/dev/null) == "$LUKS_PASSPHRASE" && ! -e $FAKE/never-opens ]] ||
                            [[ -e $FAKE/wrong-opens ]]; then
                            echo "[  OK  ] Finished systemd-cryptsetup@luks.service - Cryptography Setup for luks-x." >>"$VM_SERIAL"
                        fi
                        : >"$FAKE/typed" ;;
                    *) printf "%s" "$keys" >>"$FAKE/typed" ;;
                esac
            done
        }
        luks_unlock local-luks "$4" "$3"' _ "$APEX_ROOT/.github/scripts/qualify.sh" "$L" "${1:-}" "${2:-0}" >"$L/stderr" 2>&1 || rc=$?
    printf '%s\n' "$rc"
}
luks_boot() {
    rm -rf "$L"
    mkdir -p "$L"
    export FAKE=$L
    printf '%s\n' '[    1.2] some boot line' '         Starting systemd-cryptsetup@luks.service - Cryptography Setup for luks-x...' >"$L/serial"
}
luks_boot
check "the passphrase opens the LUKS root, after a wrong one is refused" 0 "$(luks wrong)"
check "row local-luks-wrong passes" 1 "$(grep -c '^| local-luks-wrong | PASS |' "$L/out/results.md")"
check "row local-luks passes" 1 "$(grep -c '^| local-luks | PASS |' "$L/out/results.md")"
check "a reboot's unlock writes no row" 0 "$(luks_boot; luks)"
check "and no row" 0 "$(grep -c . "$L/out/results.md")"
luks_boot
: >"$L/serial"
check "a boot that never asks fails" 1 "$(luks wrong)"
check_true "and says the initramfs never asked" grep -q '^| local-luks | FAIL | no .Starting … Cryptography Setup.' "$L/out/results.md"
luks_boot
: >"$L/wrong-opens"
check "a wrong passphrase that opens the disk fails" 1 "$(luks wrong)"
check_true "at the wrong row" grep -q '^| local-luks-wrong | FAIL | a wrong passphrase opened the LUKS root' "$L/out/results.md"
luks_boot
: >"$L/never-opens"
check "a passphrase the prompt does not take fails" 1 "$(luks wrong)"
check_true "and says so" grep -q '^| local-luks | FAIL | the passphrase typed into the Plymouth prompt did not open' "$L/out/results.md"
luks_boot
echo '[  OK  ] Finished systemd-cryptsetup@luks.service - Cryptography Setup for luks-x.' >>"$L/serial"
check "an earlier boot's prompt and unlock do not count for the next boot" 1 "$(luks '' 3)"
check_true "which waits for its own prompt" grep -q '^| local-luks | FAIL | no .Starting … Cryptography Setup.' "$L/out/results.md"
unset FAKE

# --- publish.sh publish: push apex:<version>, sign it, move :45 only past the policy -----
R="$TMP/publish-registry"
mkdir -p "$R/bin"
cat >"$R/bin/skopeo" <<'EOF'
#!/usr/bin/env bash
policy=
if [[ $1 == --policy ]]; then policy=$2; shift 4; fi
cmd=$1
shift
last=${*: -1}
ref_file() {
    local r=${1#docker://}
    if [[ $r == *@* ]]; then grep -l "\"${r#*@}\"" "$FAKE_REG2"/tags/*/*.json 2>/dev/null | head -n 1; return; fi
    local repo=${r%:*}
    printf '%s\n' "$FAKE_REG2/tags/${repo//\//_}/${r##*:}.json"
}
case $cmd in
    inspect)
        if [[ $last == oci:* ]]; then cat "$FAKE_REG2/layout.json"; exit 0; fi
        f=$(ref_file "$last")
        [[ -n $f && -f $f ]] || { echo "Error: reading manifest x in y: manifest unknown" >&2; exit 1; }
        if [[ " $* " == *" --raw "* ]]; then jq -c 'if .Subject then {subject: {digest: .Subject}} else {} end' "$f"; else cat "$f"; fi ;;
    list-tags)
        repo=${last#docker://}
        d=$FAKE_REG2/tags/${repo//\//_}
        [[ -d $d ]] || { echo 'Error: name unknown' >&2; exit 1; }
        find "$d" -name '*.json' -printf '%f\n' | sed 's/\.json$//' | jq -R . | jq -sc '{Tags: .}' ;;
    copy)
        src=${*: -2:1} digestfile=
        for ((i = 1; i <= $#; i++)); do [[ ${!i} != --digestfile ]] || { j=$((i + 1)); digestfile=${!j}; }; done
        if [[ $last == oci:* && -e $FAKE_REG2/oci-write-fails ]]; then
            echo 'Error: writing blob: no space left on device' >&2
            exit 1
        fi
        d=${src#oci:}
        d=${d%:*}
        if [[ $src == oci:* && ! -f $d/index.json ]]; then json=$FAKE_REG2/layout.json
        elif [[ $src == oci:* ]]; then
            [[ ! -e $FAKE_REG2/source-push-fails ]] || { echo 'Error: writing manifest: unauthorized' >&2; exit 1; }
            m=$(jq -r '.manifests[0].digest' "$d/index.json")
            json=$FAKE_REG2/source.json
            jq --arg m "$m" '{Digest: $m, Subject: .subject.digest, ArtifactType: .artifactType}' \
                "$d/blobs/sha256/${m#sha256:}" >"$json"
        else json=$(ref_file "$src"); fi
        [[ -n $json && -f $json ]] || { echo "Error: reading manifest: manifest unknown" >&2; exit 1; }
        digest=$(jq -r .Digest "$json")
        if [[ -n $policy ]]; then
            key=$(jq -r '[.. | .keyPath? // empty][0]' "$policy")
            signer=$(cat "$FAKE_REG2/sig.${digest#sha256:}" 2>/dev/null || true)
            [[ -n $signer && $(cat "$key") == "$(cat "$signer")" ]] ||
                { echo 'Error: Source image rejected: no valid signature' >&2; exit 1; }
        fi
        if [[ $last == docker://* ]]; then
            out=$(ref_file "$last")
            mkdir -p "${out%/*}"
            cp "$json" "$out"
        fi
        [[ -z $digestfile ]] || printf '%s' "$digest" >"$digestfile"
        printf 'copy %s %s%s\n' "$src" "$last" "${policy:+ verified}" >>"$FAKE_REG2/log" ;;
esac
EOF
cat >"$R/bin/cosign" <<'EOF'
#!/usr/bin/env bash
case $1 in
    sign)
        key=
        for ((i = 1; i <= $#; i++)); do [[ ${!i} != --key ]] || { j=$((i + 1)); key=${!j}; }; done
        ref=${*: -1}
        printf '%s\n' "$key" >"$FAKE_REG2/sig.${ref##*sha256:}"
        printf 'sign %s\n' "$ref" >>"$FAKE_REG2/log" ;;
    generate-key-pair) tok=$RANDOM$RANDOM$$; echo "$tok" >cosign.key; echo "$tok" >cosign.pub ;;
esac
EOF
cat >"$R/bin/podman" <<'EOF'
#!/usr/bin/env bash
printf 'podman %s\n' "$*" >>"$FAKE_REG2/log"
EOF
chmod +x "$R/bin/"*
layout() { # VERSION REVISION DEGRADED DIGEST_CHAR [KERNEL_PAIR]
    jq -n --arg v "$1" --arg r "$2" --arg g "$3" --arg d "sha256:$(printf "$4%.0s" {1..64})" --arg l "$APEX_LABEL_PREFIX" \
        --arg p "${5:-none}" \
        '{Digest: $d, Labels: {"org.opencontainers.image.version": $v, "org.opencontainers.image.revision": $r,
          ($l + ".fedora"): "45", ($l + ".degraded"): $g, ($l + ".kernel-pair"): $p}}' >"$R/state/layout.json"
}
reset_registry() {
    rm -rf "$R/state" "$R/keys"
    mkdir -p "$R/state/tags" "$R/keys/other"
    (cd "$R/keys" && PATH="$R/bin:$PATH" cosign generate-key-pair)
    (cd "$R/keys/other" && PATH="$R/bin:$PATH" cosign generate-key-pair)
    mkdir -p "$R/keys/registries.d"
}
trust() { # PUB: a policy for ghcr.io/x/apex that trusts only PUB
    jq -n --arg k "$1" '{default: [{type: "reject"}], transports: {docker: {"ghcr.io/x/apex":
        [{type: "sigstoreSigned", keyPath: $k, signedIdentity: {type: "matchRepository"}}]}}}' >"$R/keys/policy.json"
}
publish_rc() { # ALLOW
    # shellcheck disable=SC2016 # expanded by the inner bash
    PATH="$R/bin:$PATH" FAKE_REG2="$R/state" APEX_GIT_ROOT="$G" APEX_RETRY_DELAY=0 GITHUB_ACTIONS='' \
        APEX_SOURCES_LAYOUT="$R/sources" APEX_SOURCE_CHECK="$R/source-check.sh" \
        rc_of bash -c '. "$1"; VERIFY_POLICY=$2; VERIFY_REGISTRIES_D=$3; publish_layout ghcr.io/x/apex /layout "$4" "$5"' \
        _ "$APEX_ROOT/.github/scripts/publish.sh" "$R/keys/policy.json" "$R/keys/registries.d" "${1:-0}" "$R/keys/cosign.key"
}
published() { jq -r .Digest "$R/state/tags/ghcr.io_x_apex/$1.json" 2>/dev/null || echo none; }
reset_registry
trust "$R/keys/cosign.pub"
layout 45.20260925.151 "$C_A" '' 1
check "a first publication" 0 "$(publish_rc)"
check "pushes apex:<version>" "$D1" "$(published 45.20260925.151)"
check "and moves :45 to it" "$D1" "$(published 45)"
check "in order: push, sign, the verified move" \
    "copy oci:/layout docker://ghcr.io/x/apex:45.20260925.151|sign ghcr.io/x/apex@$D1|copy docker://ghcr.io/x/apex@$D1 docker://ghcr.io/x/apex:45 verified" \
    "$(paste -sd'|' "$R/state/log")"
check "the same layout again is a no-op that passes" 0 "$(publish_rc)"
layout 45.20260925.152 "$C_A" '' 3
jq --arg l "$APEX_LABEL_PREFIX.lane" '.Labels[$l] = "next"' "$R/state/layout.json" >"$R/state/next.json"
mv "$R/state/next.json" "$R/state/layout.json"
: >"$R/state/log"
check "a next-lane layout (label lane=next) is refused" 1 "$(publish_rc)"
check "before anything is pushed, signed or moved" "|none" "$(cat "$R/state/log")|$(published 45.20260925.152)"
check "publish.sh refuses every command for APEX_FEDORA=46" "1|1" \
    "$(rc_of env PATH="$R/bin:$PATH" APEX_FEDORA=46 "$APEX_ROOT/.github/scripts/publish.sh" publish /layout)|$(
        env PATH="$R/bin:$PATH" APEX_FEDORA=46 "$APEX_ROOT/.github/scripts/publish.sh" publish /layout 2>&1 |
            grep -c 'APEX_FEDORA=46 is the next lane: it never publishes')"
check "and lane.sh promote too, before it builds anything" "1|1" \
    "$(rc_of env APEX_FEDORA=46 "$APEX_ROOT/tools/builder-vm/lane.sh" promote)|$(
        env APEX_FEDORA=46 "$APEX_ROOT/tools/builder-vm/lane.sh" promote 2>&1 |
            grep -c 'APEX_FEDORA=46 is the next lane: it never promotes')"
layout 45.20260925.151 "$C_B" '' 2
check "another image under a version that exists is refused" 1 "$(publish_rc)"
check "and the tag keeps its image" "$D1" "$(published 45.20260925.151)"
layout 45.20260926.152 "$C_B" nvidia 2
check "a newer image that adds degraded=nvidia is refused" 1 "$(publish_rc)"
check_false "before anything is pushed" grep -q '45.20260926.152' "$R/state/log"
check "unless the owner allows it" 0 "$(publish_rc 1)"
check ":45 moves" "$D2" "$(published 45)"
layout 45.20260924.150 "$C_B" nvidia 3
check "an older version is refused" 1 "$(publish_rc)"
reset_registry
trust "$R/keys/other/cosign.pub"
layout 45.20260925.151 "$C_A" '' 1
check "a policy that trusts another key refuses the move" 1 "$(publish_rc)"
check ":45 does not exist" none "$(published 45)"
check "though apex:<version> was pushed and signed" "$D1" "$(published 45.20260925.151)"
check "publish.sh publish refuses while release.pub is the placeholder" 1 \
    "$(PATH="$R/bin:$PATH" GITHUB_ACTIONS='' COSIGN_KEY_FILE="$R/keys/cosign.key" rc_of "$APEX_ROOT/.github/scripts/publish.sh" publish oci:/layout)"
reset_registry
layout 45.20260925.151 "$C_A" '' 1
check "the rehearsal: a throwaway registry, key and policy" 0 \
    "$(cd "$R" && PATH="$R/bin:$PATH" FAKE_REG2="$R/state" APEX_GIT_ROOT="$G" APEX_RETRY_DELAY=0 GITHUB_ACTIONS='' \
        rc_of "$APEX_ROOT/.github/scripts/publish.sh" rehearse oci:/layout)"
check "pushes to localhost and moves its :45" "$D1" "$(jq -r .Digest "$R/state/tags/localhost:5000_apex/45.json")"
check_true "starts and removes the registry" grep -q '^podman run -d --rm --name apex-publish-rehearsal -p 127.0.0.1:5000:5000 ' "$R/state/log"
reset_registry
layout 45.20260925.151 "$C_A" '' 1
: >"$R/state/oci-write-fails"
check "a refusal for any reason but the signature fails the rehearsal" 1 \
    "$(cd "$R" && PATH="$R/bin:$PATH" FAKE_REG2="$R/state" APEX_GIT_ROOT="$G" APEX_RETRY_DELAY=0 GITHUB_ACTIONS='' \
        rc_of "$APEX_ROOT/.github/scripts/publish.sh" rehearse oci:/layout)"

# A pair image publishes only with its source set, which apex-kernel's check accepts.
cat >"$R/source-check.sh" <<'EOF'
[[ -f $1/SHA256SUMS ]] || { echo 'not ok: SHA256SUMS lists every other file' >&2; exit 1; }
rc=$(cat "$FAKE_REG2/check-rc" 2>/dev/null || echo 0)
echo "source-check exit $rc" >&2
exit "$rc"
EOF
put_blob() { local sha; sha=$(sha256sum <"$1" | cut -c1-64); mv "$1" "$R/sources/blobs/sha256/$sha"; printf 'sha256:%s' "$sha"; }
sources() { # PAIR_KEY: _build/image/sources as apex-lane sources writes it
    rm -rf "$R/sources" "$R/src-root"
    mkdir -p "$R/sources/blobs/sha256" "$R/src-root/srpms"
    echo rpm >"$R/src-root/srpms/kernel-cachyos.src.rpm"
    echo sums >"$R/src-root/SHA256SUMS"
    tar -cf "$R/layer.tar" -C "$R/src-root" .
    local layer config manifest
    layer=$(put_blob "$R/layer.tar")
    jq -nc --arg k "$1" '{config: {Labels: {"io.github.apex-linux.apex.pair-key": $k}}}' >"$R/config.json"
    config=$(put_blob "$R/config.json")
    jq -nc --arg c "$config" --arg l "$layer" '{schemaVersion: 2, config: {digest: $c}, layers: [{digest: $l}]}' >"$R/m.json"
    manifest=$(put_blob "$R/m.json")
    jq -nc --arg m "$manifest" --arg k "$1" \
        '{schemaVersion: 2, manifests: [{digest: $m, size: 1, annotations: {"org.opencontainers.image.ref.name": $k}}]}' \
        >"$R/sources/index.json"
    echo '{"imageLayoutVersion":"1.0.0"}' >"$R/sources/oci-layout"
}
pair_publish() { # [SOURCES_KEY]: a fresh registry and a pair-k1 layout with its sources
    reset_registry
    trust "$R/keys/cosign.pub"
    layout 45.20260925.151 "$C_A" '' 1 k1
    sources "${1:-k1}"
}
S1="ghcr.io/x/apex:sha256-${D1#sha256:}.source"
pair_publish
check "a pair image publishes with its source artifact" 0 "$(publish_rc)"
art=$(jq -r .Digest "$R/state/tags/ghcr.io_x_apex/sha256-${D1#sha256:}.source.json")
check "in order: the image and its signature, the source to <repo>:sha256-<image>.source, its signature and verified copy, then :45" \
    "copy oci:TMP docker://ghcr.io/x/apex:45.20260925.151|sign ghcr.io/x/apex@$D1|copy oci:TMP docker://$S1|sign ghcr.io/x/apex@ART|copy docker://ghcr.io/x/apex@ART oci:TMP verified|copy docker://ghcr.io/x/apex@$D1 docker://ghcr.io/x/apex:45 verified" \
    "$(sed -E "s#oci:/[^ ]*#oci:TMP#g; s#$art#ART#g" "$R/state/log" | paste -sd'|')"
check "it refers to the image" "$D1" "$(jq -r .Subject "$R/state/tags/ghcr.io_x_apex/sha256-${D1#sha256:}.source.json")"
check "as an apex source artifact" application/vnd.apex-linux.source.v1 \
    "$(jq -r .ArtifactType "$R/state/tags/ghcr.io_x_apex/sha256-${D1#sha256:}.source.json")"
check ":45 moves to the image" "$D1" "$(published 45)"
pair_publish
rm -rf "$R/sources"
check "a pair image without its source artifact is refused" 1 "$(publish_rc)"
check "before anything is pushed" 0 "$(grep -c . "$R/state/log" 2>/dev/null || echo 0)"
pair_publish k0
check "the source artifact of another pair is refused" 1 "$(publish_rc)"
check "before anything is pushed" 0 "$(grep -c . "$R/state/log" 2>/dev/null || echo 0)"
pair_publish
echo 1 >"$R/state/check-rc"
check "a source set source-check.sh refuses is refused" 1 "$(publish_rc)"
check "before anything is pushed" 0 "$(grep -c . "$R/state/log" 2>/dev/null || echo 0)"
pair_publish
echo 2 >"$R/state/check-rc"
check "a source-check.sh that cannot run refuses too" 1 "$(publish_rc)"
pair_publish
rm "$R/src-root/SHA256SUMS"
tar -cf "$R/layer.tar" -C "$R/src-root" .
cp "$R/layer.tar" "$R/sources/blobs/sha256/$(jq -r '.manifests[0].digest' "$R/sources/index.json" | cut -c8- | xargs -I{} jq -r '.layers[0].digest' "$R/sources/blobs/sha256/{}" | cut -c8-)"
check "a source layer that no longer matches its digest is refused" 1 "$(publish_rc)"
pair_publish
: >"$R/state/source-push-fails"
check "a source push that fails stops the publication" 1 "$(publish_rc)"
check "after apex:<version> was pushed" "$D1" "$(published 45.20260925.151)"
check ":45 stays where it was" none "$(published 45)"
pair_publish
jq --arg l "$APEX_LABEL_PREFIX.kernel-pair" 'del(.Labels[$l])' "$R/state/layout.json" >"$R/state/l" && mv "$R/state/l" "$R/state/layout.json"
check "a layout without the kernel-pair label is refused" 1 "$(publish_rc)"
check "before anything is pushed" 0 "$(grep -c . "$R/state/log" 2>/dev/null || echo 0)"
pair_publish
check "the rehearsal of a pair image" 0 \
    "$(cd "$R" && PATH="$R/bin:$PATH" FAKE_REG2="$R/state" APEX_GIT_ROOT="$G" APEX_RETRY_DELAY=0 GITHUB_ACTIONS='' \
        APEX_SOURCES_LAYOUT="$R/sources" APEX_SOURCE_CHECK="$R/source-check.sh" \
        rc_of "$APEX_ROOT/.github/scripts/publish.sh" rehearse oci:/layout)"
check_true "pushes the source to localhost" test -f "$R/state/tags/localhost:5000_apex/sha256-${D1#sha256:}.source.json"

# --- oci-artifact.sh lookup: a cache hit must be attested by the workflow on main ------
O="$TMP/oci"
mkdir -p "$O/bin"
printf '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json"}' >"$O/manifest"
O_DIGEST="sha256:$(sha256sum <"$O/manifest" | cut -d' ' -f1)"
cat >"$O/bin/skopeo" <<'EOF'
#!/usr/bin/env bash
ref=${*: -1}
case $ref in
    *missing*) echo "Error: reading manifest x in y: manifest unknown" >&2; exit 1 ;;
esac
if [[ " $* " == *" --raw "* ]]; then cat "$FAKE_MANIFEST"; exit 0; fi
printf '{"Digest":"%s","Labels":{"io.github.apex-linux.apex.content-key":"%s"}}\n' "$FAKE_DIGEST" "$FAKE_LABEL"
EOF
cat >"$O/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$FAKE_GH_LOG"
[[ $FAKE_GH_OK == 1 ]]
EOF
chmod +x "$O/bin/skopeo" "$O/bin/gh"
lookup_rc() {
    local key=$1 label=$2 gh_ok=$3 repo=${4:-ghcr.io/x/apex-rpms}
    PATH="$O/bin:$PATH" FAKE_MANIFEST="$O/manifest" FAKE_DIGEST="$O_DIGEST" FAKE_LABEL=$label \
        FAKE_GH_OK=$gh_ok FAKE_GH_LOG="$O/gh.log" APEX_RETRY_DELAY=0 GITHUB_ACTIONS='' \
        rc_of "$APEX_ROOT/.github/scripts/oci-artifact.sh" lookup "$repo" "$key" rpms.yml
}
: >"$O/gh.log"
check "an attested artifact with its key is a hit" 0 "$(lookup_rc k1 k1 1)"
check_true "gh checks the rpms.yml identity on main" \
    grep -qF -- "--cert-identity https://github.com/apex-linux/apex-image/.github/workflows/rpms.yml@refs/heads/main" "$O/gh.log"
check_true "gh checks the source ref and hosted runners" \
    grep -qE -- "--source-ref refs/heads/main .*--deny-self-hosted-runners" "$O/gh.log"
check "an unattested artifact is a miss" 5 "$(lookup_rc k1 k1 0)"
check "an artifact labelled with another key is a miss" 5 "$(lookup_rc k1 k2 1)"
check "an absent artifact is a miss" 3 "$(lookup_rc k1 k1 1 ghcr.io/x/missing)"
check "a bad workflow name is refused" 1 \
    "$(PATH="$O/bin:$PATH" GITHUB_ACTIONS='' rc_of "$APEX_ROOT/.github/scripts/oci-artifact.sh" lookup ghcr.io/x/y k '../evil')"
# --- lane-rehearsal.sh: S1c's rehearsals on a fake lane, image.sh, publish.sh and COPR ---
LR="$TMP/lane-rehearsal"
mkdir -p "$LR/co/.github/scripts" "$LR/co/tools/builder-vm/rehearsal" "$LR/co/_build/rpms/apex" \
    "$LR/co/_build/rpms/desktop" "$LR/bin" "$LR/kernel/packaging/pkgs/kernel" "$LR/others"
cp "$APEX_ROOT/.github/scripts/lib.sh" "$LR/co/.github/scripts/"
cp "$APEX_ROOT/tools/builder-vm/lane-rehearsal.sh" "$LR/co/tools/builder-vm/"
cp "$APEX_ROOT/tools/builder-vm/rehearsal/pkg.env" "$LR/co/tools/builder-vm/rehearsal/"
printf '%s\n' copr=bieszczaders/kernel-cachyos chroot=fedora-45-x86_64 \
    srpm=kernel-cachyos-0:7.3.0-4.cachyos1.fc45.src srpm_sha256=pinned tag=cachyos-7.3.0-4 \
    >"$LR/kernel/packaging/pkgs/kernel/kernel.env"
printf 'kmod_srpm=nvidia-kmod-3:615.78.08-1.fc45.src\n' >"$LR/kernel/packaging/pkgs/kernel/nvidia.env"
cat >"$LR/bin/curl" <<'EOF'
#!/usr/bin/env bash
url=${*: -1}
case $url in
    */build/list/*) printf '{"items":[%s]}' "$(cat "$FAKE_LR/builds")" ;;
    */build-chroot*) [[ $url == *build_id=103* ]] && echo '{"state":"failed"}' || echo '{"state":"succeeded"}' ;;
    */Packages/k/kernel-cachyos-7.3.0-2.cachyos1.fc45.src.rpm) printf 'the 7.3.0-2 SRPM' ;;
    *) exit 22 ;;
esac
EOF
cat >"$LR/bin/lane" <<'EOF'
#!/usr/bin/env bash
printf '%s rehearsal=%s store=%s fault=%s now=%s\n' "$*" "$APEX_LANE_REHEARSAL" "$APEX_STORE" \
    "${APEX_PAIR_FAULT:-}" "${APEX_LANE_NOW:-}" >>"$FAKE_LR/lane.log"
recipes=${APEX_LANE_RECIPES%%:*}
next=$APEX_STORE/rpms.lock.next
reason='reason=kmod: nvidia-kmod-3:615.78.08-1.fc45.src does not build for this kernel'
mkdir -p "$APEX_STORE"
case $1 in
    build)
        cp "$recipes/packaging/pkgs/kernel/kernel.env" "$FAKE_LR/kernel.env.$(wc -l <"$FAKE_LR/lane.log")"
        if [[ ! -f $APEX_STORE/rpms.lock ]]; then
            echo 'family kernel-cachyos built kG' >"$next"
        elif [[ -z ${APEX_PAIR_FAULT:-} ]]; then
            echo 'family kernel-cachyos built kB' >"$next"
        elif [[ -z ${APEX_LANE_NOW:-} || $APEX_LANE_NOW < 2026-12-04T00:00:00Z ]]; then
            echo "family kernel-cachyos held kG since=2026-12-01T00:00:00Z limit=2026-12-04T00:00:00Z newer=x security=1 side=${FAKE_SIDE:-kmod} $reason" >"$next"
            exit 3
        else
            echo "family kernel-cachyos built kD since=2026-12-01T00:00:00Z limit=2026-12-04T00:00:00Z newer=x security=1 degraded=nvidia side=kmod $reason" >"$next"
            exit 3
        fi ;;
    promote)
        if grep -q degraded=nvidia "$next" && [[ ${2:-} != --allow-degraded ]]; then exit 1; fi
        cp "$next" "$APEX_STORE/rpms.lock" ;;
    kernel-bump)
        git -C "$recipes" branch -q kernel-bump/kernel-cachyos-7.3.0-4.cachyos1.fc45 ;;
esac
EOF
cat >"$LR/bin/image.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s image=%s work=%s previous=%s\n' "$*" "$APEX_IMAGE" "$APEX_WORK" "${APEX_PREVIOUS_BUILD:-}" >>"$FAKE_LR/image.log"
mkdir -p "$APEX_WORK"
case $1 in
    context) lane=${*: -1}; cp "$lane" "$APEX_WORK/lane" ;;
    build) [[ $APEX_WORK != *"${FAKE_G1_FAILS:-none}" ]] || exit 1 ;;
    inspect)
        held='' degraded=''
        grep -q ' held ' "$APEX_WORK/lane" && held=kernel-cachyos
        grep -q degraded=nvidia "$APEX_WORK/lane" && degraded=nvidia
        printf 'HELD=%s\nDEGRADED=%s\n' "$held" "$degraded" >"$APEX_WORK/image.env" ;;
    rechunk) mkdir -p "$APEX_WORK/oci" ;;
esac
EOF
cat >"$LR/bin/publish.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_LR/publish.log"
EOF
printf '#!/usr/bin/env bash\nexit 0\n' >"$LR/bin/podman"
printf '#!/usr/bin/env bash\nexec "$@"\n' >"$LR/bin/sudo"
chmod +x "$LR/bin/"*
lr_builds() { # ID:VERSION...: the COPR's build list items
    local b
    for b in "$@"; do printf '{"id":%s,"source_package":{"version":"%s"}}\n' "${b%%:*}" "${b#*:}"; done | paste -sd, -
}
LR_ALL_BUILDS=$(lr_builds 105:7.3.1-1.cachyos1 104:7.3.0-4.cachyos1 103:7.3.0-3.cachyos1 102:7.3.0-2.cachyos1 101:7.2.9-1.cachyos1)
rehearse() { # SCENARIO [VAR=VALUE...]: lane-rehearsal.sh on the fakes; prints its exit status
    local scenario=$1
    shift
    rm -rf "$LR/dir" "$LR/"*.log "$LR/kernel.env."*
    printf '%s' "${LR_BUILDS:-$LR_ALL_BUILDS}" >"$LR/builds"
    # shellcheck disable=SC2016 # expanded by the inner bash
    env PATH="$LR/bin:$PATH" FAKE_LR="$LR" APEX_REHEARSAL_DIR="$LR/dir" APEX_KERNEL_SRC="$LR/kernel" \
        APEX_LANE_RECIPES="$LR/others" APEX_REHEARSAL_LANE="$LR/bin/lane" APEX_REHEARSAL_IMAGE_SH="$LR/bin/image.sh" \
        APEX_REHEARSAL_PUBLISH_SH="$LR/bin/publish.sh" GITHUB_ACTIONS='' "$@" \
        bash -c '"$1" "$2" >"$3" 2>&1; printf "%s" "$?"' _ "$LR/co/tools/builder-vm/lane-rehearsal.sh" "$scenario" "$LR/stderr"
}
lr_rows() { sed -n 's/^| \([a-z-]*\) | \([A-Z]*\) |.*/\1 \2/p' "$LR/dir/report.md" | paste -sd, -; }
check "the rehearsals pass end to end" 0 "$(rehearse all)"
check "every step has its row" "prepare PASS,good-pair PASS,kernel-bump PASS,point PASS,publish PASS,kmod-hold PASS,kmod-limit PASS" "$(lr_rows)"
check_true "the good pair is pinned at the COPR build before the pinned one whose chroot succeeded" \
    grep -qx 'srpm=kernel-cachyos-0:7.3.0-2.cachyos1.fc45.src' "$LR/kernel.env.1"
check_true "with the sha256 of the downloaded SRPM" \
    grep -qx "srpm_sha256=$(printf 'the 7.3.0-2 SRPM' | sha256sum | cut -d' ' -f1)" "$LR/kernel.env.1"
check_true "and its CachyOS tag" grep -qx 'tag=cachyos-7.3.0-2' "$LR/kernel.env.1"
check "every lane call is a rehearsal on the scratch store" 0 "$(grep -cv "rehearsal=1 store=$LR/dir/store " "$LR/lane.log")"
check "only the kmod builds carry the fault" "build all fault=kmod now=|build all fault=kmod now=2026-12-04T00:00:01Z" \
    "$(grep 'fault=kmod' "$LR/lane.log" | sed 's/ rehearsal=1 store=[^ ]*//' | paste -sd'|')"
check "promote refused the degraded set, then took it with the override" "promote|promote|promote --allow-degraded" \
    "$(sed -n 's/^\(promote[^ ]*\( --allow-degraded\)\?\) rehearsal.*/\1/p' "$LR/lane.log" | paste -sd'|')"
check "every image is the rehearsal's own tag" 0 "$(grep -cv ' image=localhost/apex:rehearsal ' "$LR/image.log")"
check_true "the point image is rechunked against no previous build" grep -q '^rechunk .* previous=none$' "$LR/image.log"
check "publish.sh rehearses the point image" "rehearse oci:$LR/dir/image/point/oci/apex:latest" "$(cat "$LR/publish.log")"
check_false "the scratch store is deleted" test -e "$LR/dir/store"
check_false "and the recipes and image state" test -e "$LR/dir/recipes" -o -e "$LR/dir/image"
check_true "the logs and the report stay" test -f "$LR/dir/logs/good-pair.log" -a -s "$LR/dir/report.md"
check "point alone builds no kmod step" "prepare PASS,good-pair PASS,kernel-bump PASS,point PASS,publish PASS" \
    "$(rehearse point >/dev/null; lr_rows)"
check "kmod alone publishes nothing" "prepare PASS,good-pair PASS,kernel-bump PASS,kmod-hold PASS,kmod-limit PASS" \
    "$(rehearse kmod >/dev/null; lr_rows)"
check_false "kmod alone calls no publish.sh" test -e "$LR/publish.log"
check "a fault that holds on the kernel side fails the rehearsal" 1 "$(rehearse kmod FAKE_SIDE=kernel)"
check_true "at the kmod-hold row" grep -q '^| kmod-hold | FAIL | rpms.lock.next has .* not a kmod hold of kG' "$LR/dir/report.md"
check_false "and the scratch store is still deleted" test -e "$LR/dir/store"
check "a degraded image that fails G1 fails the rehearsal" 1 "$(rehearse kmod FAKE_G1_FAILS=kmod-limit)"
check_true "at the kmod-limit row" grep -q '^| kmod-limit | FAIL | the image did not build or failed G1' "$LR/dir/report.md"
mkdir -p "$LR/others/packaging/pkgs/kernel"
printf 'family=kernel-cachyos\n' >"$LR/others/packaging/pkgs/kernel/pkg.env"
check "a pair recipe of the product's own stops the rehearsal" 1 "$(rehearse all)"
check_true "which says so" grep -q '^| prepare | FAIL | .*would be a second kernel-cachyos family' "$LR/dir/report.md"
rm -rf "$LR/others/packaging"
check "no earlier build of the pinned major stops the rehearsal" 1 \
    "$(LR_BUILDS=$(lr_builds 104:7.3.0-4.cachyos1 101:7.2.9-1.cachyos1) rehearse all)"
check_true "which says so" grep -q '^| prepare | FAIL | the COPR has no build of 7.3 before the pinned 7.3.0-4.cachyos1' "$LR/dir/report.md"
check "an unknown scenario is a usage error" 2 "$(rehearse everything)"
# --- tools/runner/preflight.sh: the KVM host's checks on a fake root and fake tools --------
PF="$TMP/preflight"
mkdir -p "$PF/bin" "$PF/home/.config/apex/runner/ssh"
pf_root() {
    rm -rf "$PF/root"
    mkdir -p "$PF/root/dev" "$PF/root/sys/module/kvm_intel/parameters" "$PF/root/etc" \
        "$PF/root/sys/fs/cgroup" "$PF/root/proc"
    : >"$PF/root/dev/kvm"
    echo Y >"$PF/root/sys/module/kvm_intel/parameters/nested"
    printf '%s:100000:65536\n' "$(id -un)" | tee "$PF/root/etc/subuid" >"$PF/root/etc/subgid"
    : >"$PF/root/sys/fs/cgroup/cgroup.controllers"
    printf 'MemTotal:       32768000 kB\n' >"$PF/root/proc/meminfo"
    printf 'ssh-ed25519 AAAAkey apex-runner\n' >"$PF/home/.config/apex/runner/ssh/id_ed25519.pub"
    for f in id_ed25519 config; do echo x >"$PF/home/.config/apex/runner/ssh/$f"; done
    mkdir -p "$PF/home/vm/ssh"
    printf '[127.0.0.1]:2222 ssh-ed25519 AAAAhost\n' | tee "$PF/home/.config/apex/runner/ssh/known_hosts" >"$PF/home/vm/ssh/known_hosts"
    chmod 600 "$PF/home/.config/apex/runner/ssh/id_ed25519"
}
cat >"$PF/bin/podman" <<'EOF'
#!/usr/bin/env bash
case $1 in
    version) echo "${FAKE_PODMAN_VERSION:-5.4.2}" ;;
    info) echo "${FAKE_ROOTLESS:-true}" ;;
esac
EOF
cat >"$PF/bin/curl" <<'EOF'
#!/usr/bin/env bash
[[ ${*: -1} == *"${FAKE_UNREACHABLE:-none}"* ]] && { printf 000; exit 6; }
printf 200
EOF
cat >"$PF/bin/ssh-keygen" <<'EOF'
#!/usr/bin/env bash
[[ $1 == -F ]] && grep -F "$2 " "$4"
EOF
cat >"$PF/bin/df" <<'EOF'
#!/usr/bin/env bash
echo Avail
echo "${FAKE_AVAIL:-200000000000}"
EOF
cat >"$PF/bin/nproc" <<'EOF'
#!/usr/bin/env bash
echo "${FAKE_NPROC:-12}"
EOF
cat >"$PF/bin/timedatectl" <<'EOF'
#!/usr/bin/env bash
echo "${FAKE_NTP:-yes}"
EOF
printf '#!/usr/bin/env bash\nexit 0\n' >"$PF/bin/pasta"
cat >"$PF/bin/builder-vm" <<'EOF'
#!/usr/bin/env bash
case $1 in
    running) [[ ${FAKE_VM:-up} == up ]] ;;
    ssh)
        if [[ $2 == *"ci-build modes"* ]]; then
            [[ ${FAKE_MODES:-new} == new ]] || { echo "ci-build: refused" >&2; exit 2; }
            echo "daily next"
            exit 0
        fi
        if [[ $2 == *cosign* ]]; then
            [[ ${FAKE_COSIGN:-pinned} != missing ]] || exit 1
            sum=$(sed -n 's/^COSIGN_SHA256=//p' "$PIN")
            [[ ${FAKE_COSIGN:-pinned} != other ]] || sum=$(printf '0%.0s' {1..64})
            printf '%s  /usr/local/bin/cosign\nGitVersion:    %s\n' "$sum" "$(sed -n 's/^COSIGN_VERSION=//p' "$PIN")"
            exit 0
        fi
        printf '%s ssh-ed25519 AAAAkey apex-runner\n' "${FAKE_BINDING:-restrict,command=\"/usr/local/libexec/apex/ci-build\"}" ;;
esac
EOF
chmod +x "$PF/bin/"*
pf() { # [VAR=VALUE...]: preflight.sh on the fake root; prints its rows, then rc=N
    local rc=0
    env PATH="$PF/bin:$PATH" HOME="$PF/home" XDG_CONFIG_HOME= XDG_DATA_HOME= APEX_PREFLIGHT_ROOT="$PF/root" \
        PIN="$APEX_ROOT/tools/builder-vm/cosign.env" \
        APEX_PREFLIGHT_BUILDER_VM="$PF/bin/builder-vm" APEX_VM_DIR="$PF/home/vm" "$@" \
        "$APEX_ROOT/tools/runner/preflight.sh" >"$PF/out" 2>&1 || rc=$?
    printf 'rc=%s\n' "$rc"
}
pf_row() { awk -v n="$1" '$2 == n { print $1 }' "$PF/out"; }
pf_root
check "a ready host passes" "rc=0" "$(pf)"
check "with a row for each check" "kvm nested-kvm podman subids cgroup-v2 disk ram cpus net:github.com" \
    "$(awk 'NF > 2 { print $2 }' "$PF/out" | head -n 9 | paste -sd' ')"
check "and the builder VM's host key the runner knows" PASS "$(pf_row vm-host-key)"
check "and no row that fails or skips" 0 "$(grep -cE '^(FAIL|SKIP) ' "$PF/out")"
check "the forced command is found in the builder VM" PASS "$(pf >/dev/null; pf_row ci-build)"
pf_fails() { # ROW SETUP [VAR=VALUE...]: the row fails and the exit is 1
    local name=$1 setup=$2
    shift 2
    pf_root
    eval "$setup"
    check "preflight fails $name ${*:-($setup)}" "rc=1 FAIL" "$(pf "$@") $(pf_row "$name")"
}
# shellcheck disable=SC2016 # each setup is eval'd by pf_fails
{
pf_fails kvm 'rm "$PF/root/dev/kvm"'
pf_fails nested-kvm 'echo N >"$PF/root/sys/module/kvm_intel/parameters/nested"'
pf_fails nested-kvm 'rm -r "$PF/root/sys/module"'
pf_fails podman : FAKE_PODMAN_VERSION=4.3.1
pf_fails podman : FAKE_ROOTLESS=false
pf_fails subids 'printf "%s:100000:1000\n" "$(id -un)" >"$PF/root/etc/subgid"'
pf_fails cgroup-v2 'rm "$PF/root/sys/fs/cgroup/cgroup.controllers"'
pf_fails disk : FAKE_AVAIL=50000000000
pf_fails ram 'printf "MemTotal: 6000000 kB\n" >"$PF/root/proc/meminfo"'
pf_fails cpus : FAKE_NPROC=4
pf_fails net:ghcr.io : FAKE_UNREACHABLE=ghcr.io
pf_fails runner-key 'chmod 644 "$PF/home/.config/apex/runner/ssh/id_ed25519"'
pf_fails ci-build : FAKE_BINDING=no-restriction
pf_fails ci-build-modes : FAKE_MODES=old
pf_fails time-sync : FAKE_NTP=no
pf_fails vm-host-key 'printf "[127.0.0.1]:2222 ssh-ed25519 AAAAnew\n" >"$PF/home/vm/ssh/known_hosts"'
pf_fails vm-cosign : FAKE_COSIGN=missing
pf_fails vm-cosign : FAKE_COSIGN=other
}
check "the pinned cosign in the builder VM passes" PASS "$(pf >/dev/null; pf_row vm-cosign)"
pf_root
mkdir -p "$PF/home/vm"
truncate -s 0 "$PF/home/vm/disk.qcow2"
head -c 1048576 /dev/zero >"$PF/home/vm/disk.qcow2"
check "a smaller VM asks for less RAM and fewer threads" "rc=0" "$(pf APEX_VM_MEM=2G APEX_VM_CPUS=4 FAKE_NPROC=4 \
    FAKE_AVAIL=200000000000)"
check "the VM's own disk counts toward its space" PASS "$(pf FAKE_AVAIL=91268055040 >/dev/null; pf_row disk)"
pf_root
rm "$PF/home/.config/apex/runner/ssh/"*
check "before runner.sh key the key rows skip, and the host still passes" "rc=0 SKIP SKIP SKIP" \
    "$(pf) $(pf_row runner-key) $(pf_row ci-build) $(pf_row vm-host-key)"
pf_root
check "a stopped builder VM skips the binding and cosign" "rc=0 SKIP SKIP" "$(pf FAKE_VM=down) $(pf_row ci-build) $(pf_row vm-cosign)"
check "a forced command on the current grammar passes, naming its modes" "PASS|daily next" \
    "$(pf >/dev/null; pf_row ci-build-modes)|$(awk '$2 == "ci-build-modes" { print $(NF - 1), $NF }' "$PF/out")"
check_true "an old one's row says how to upgrade" grep -q 'old grammar (no next): just vm-ci-install' \
    <<<"$(pf FAKE_MODES=old >/dev/null; cat "$PF/out")"
check "an argument is a usage error" 2 "$(rc_of "$APEX_ROOT/tools/runner/preflight.sh" extra)"
# --- install-cosign.sh: the pinned release only, checked before it is installed ----------
IC="$TMP/install-cosign"
mkdir -p "$IC/bin"
cat >"$IC/bin/curl" <<'EOF'
#!/usr/bin/env bash
out=
for ((i = 1; i <= $#; i++)); do [[ ${!i} != -o ]] || { j=$((i + 1)); out=${!j}; }; done
printf '%s\n' "${*: -1}" >>"$FAKE_IC/urls"
[[ ! -e $FAKE_IC/offline ]] || exit 6
cp "$FAKE_IC/release" "$out"
EOF
printf '#!/usr/bin/env bash\n"$@"\n' >"$IC/bin/sudo"
chmod +x "$IC/bin/"*
ic() { # VERSION SHA256: install-cosign.sh into $IC/root/cosign; prints its exit
    rc_of env PATH="$IC/bin:$PATH" FAKE_IC="$IC" APEX_COSIGN_BIN="$IC/root/cosign" \
        "$APEX_ROOT/tools/builder-vm/install-cosign.sh" "$@"
}
ic_reset() { rm -rf "$IC/root" "$IC/urls" "$IC/offline"; echo 'the cosign release' >"$IC/release"; }
ic_reset
IC_SUM=$(sha256sum <"$IC/release" | cut -d' ' -f1)
check "the pinned release installs" 0 "$(ic v3.0.2 "$IC_SUM")"
check "from that version's release on GitHub, never latest" \
    https://github.com/sigstore/cosign/releases/download/v3.0.2/cosign-linux-amd64 "$(cat "$IC/urls")"
check_true "as an executable" test -x "$IC/root/cosign"
check "a re-run with the binary in place downloads nothing" "0 1" "$(ic v3.0.2 "$IC_SUM") $(grep -c . "$IC/urls")"
ic_reset
echo 'another binary' >"$IC/release"
check "a download without the pinned sha256 is refused" 1 "$(ic v3.0.2 "$IC_SUM")"
check_false "and nothing is installed" test -e "$IC/root/cosign"
ic_reset
: >"$IC/offline"
check "a failed download is refused" 1 "$(ic v3.0.2 "$IC_SUM")"
check_false "and nothing is installed" test -e "$IC/root/cosign"
ic_reset
check "a version that is not vX.Y.Z is a usage error" 2 "$(ic latest "$IC_SUM")"
check "a sha256 that is not 64 hex digits is a usage error" 2 "$(ic v3.0.2 abc)"
check "the pin file pins a version and a sha256" 2 \
    "$(grep -cE '^(COSIGN_VERSION=v[0-9]+\.[0-9]+\.[0-9]+|COSIGN_SHA256=[0-9a-f]{64})$' "$APEX_ROOT/tools/builder-vm/cosign.env")"

# --- lane-absorb-report.sh: a series is applies, fuzz or fails, as git apply and patch say -------
AB="$TMP/absorb"
mkdir -p "$AB/pristine" "$AB/recipe/patches"
seq -f 'line %g' 1 30 >"$AB/pristine/f.txt"
ab_patch() { # NAME SED [FROM-SED]: a -p1 patch of f.txt, made against FROM-SED's text when given
    mkdir -p "$AB/mk/a" "$AB/mk/b"
    sed "${3:-}" "$AB/pristine/f.txt" >"$AB/mk/a/f.txt"
    sed "$2" "$AB/mk/a/f.txt" >"$AB/mk/b/f.txt"
    (cd "$AB/mk" && diff -u a/f.txt b/f.txt) >"$AB/recipe/patches/$1" || true
}
ab_patch clean.patch 's/^line 5$/line five/'
ab_patch fuzzy.patch 's/^line 20$/line twenty/' 's/^line 17$/line seventeen/'
ab_patch broken.patch 's/^line 25 gone$/x/;s/^line 25$/line 25 again/' 's/^line 25$/line 25 gone/'
ab_patch after.patch 's/^line 28$/line 28!/'
absorb() { # PATCH...: apply_series on a fresh copy of the pristine tree
    rm -rf "$AB/tree"
    cp -r "$AB/pristine" "$AB/tree"
    printf '# a comment\n' >"$AB/recipe/series"
    printf '%s\n' "$@" >>"$AB/recipe/series"
    bash -c '. "$1"; apply_series "$2" "$3"' _ "$APEX_ROOT/tools/builder-vm/lane-absorb-report.sh" "$AB/tree" "$AB/recipe"
}
check "a series that git apply takes applies" "$(printf 'applies\t1 patch(es)')" "$(absorb clean.patch)"
check_true "and changes the tree" grep -qx 'line five' "$AB/tree/f.txt"
check "a patch only patch --fuzz takes is fuzz" "fuzz" "$(absorb clean.patch fuzzy.patch | cut -f1)"
check_true "naming the patch" grep -q 'fuzzy.patch: git apply refuses' <<<"$(absorb clean.patch fuzzy.patch)"
check "a patch neither takes fails" "fails" "$(absorb clean.patch broken.patch after.patch | cut -f1)"
check_true "with its name, its hunks and the patches not tried" \
    grep -q '^fails	broken.patch: error: .*FAILED.*(later patches not tried)$' <<<"$(absorb clean.patch broken.patch after.patch)"
check_false "the patches after a failure are not applied" grep -qx 'line 28!' "$AB/tree/f.txt"
check "an argument that looks like an option is a usage error" 2 \
    "$(rc_of "$APEX_ROOT/tools/builder-vm/lane-absorb-report.sh" --help)"

# --- runner.sh once: no job is taken until the builder VM's sshd sends its banner ----------
RB="$TMP/runner-builder"
mkdir -p "$RB"
rb_serve() { # REPLY: a loopback server that sends REPLY to each connection and closes it, at RB_PORT
    python3 - "$1" "$RB/port" >/dev/null 2>&1 <<'EOF' &
import socket, sys
s = socket.socket()
s.bind(("127.0.0.1", 0))
s.listen()
open(sys.argv[2] + ".tmp", "w").write(str(s.getsockname()[1]))
__import__("os").rename(sys.argv[2] + ".tmp", sys.argv[2])
while True:
    c, _ = s.accept()
    c.sendall(sys.argv[1].encode())
    c.close()
EOF
    RB_PID=$!
    until [[ -s $RB/port ]]; do sleep 0.05; done
    RB_PORT=$(cat "$RB/port")
    rm -f "$RB/port"
}
rb() { # PORT SCRIPT: SCRIPT with runner.sh's functions, its builder VM at 127.0.0.1:PORT, cut at 4 s
    # shellcheck disable=SC2016 # expanded by the inner bash
    APEX_VM_SSH_PORT=$1 timeout 4 bash -c '. "$1"; BUILDER_POLL=1 BUILDER_LOG_EVERY=1; eval "$2"' _ \
        "$APEX_ROOT/tools/runner/runner.sh" "$2"
}
rb_stop() { kill "$RB_PID"; wait "$RB_PID" 2>/dev/null || true; }
rb_serve $'SSH-2.0-OpenSSH_9.9\r\n'
rb_port=$RB_PORT
check "runner: sshd's banner means the builder VM answers" 0 "$(rc_of rb "$rb_port" builder_answers)"
check "runner: and wait_for_builder returns at once" 0 "$(rc_of rb "$rb_port" wait_for_builder)"
rb_stop
rb_serve ''
rb_port=$RB_PORT
check "runner: a port that accepts and resets (QEMU's forward, guest down) does not answer" 1 \
    "$(rc_of rb "$rb_port" builder_answers)"
rb_rc=0
rb "$rb_port" wait_for_builder 2>"$RB/wait.log" || rb_rc=$?
check "runner: wait_for_builder keeps waiting, taking no job" 124 "$rb_rc"
check_true "and says why, naming just vm-start" grep -qF \
    "the builder VM's sshd (127.0.0.1:$rb_port) does not answer; no job is taken until it does (just vm-start)" "$RB/wait.log"
rb_stop
check "runner: nothing listening does not answer" 1 "$(rc_of rb "$rb_port" builder_answers)"

# --- runner.sh once: logind's inhibitor locks are held while the job runs, and only then ------
FI="$TMP/runner-inhibit"
mkdir -p "$FI/bin"
cat >"$FI/bin/systemd-inhibit" <<'EOF'
#!/usr/bin/env bash
# --list shows the locks whose holder lives; otherwise --what is taken, unless refused, for COMMAND.
if [[ $1 == --list ]]; then
    echo 'WHO UID USER PID COMM WHAT WHY MODE'
    while read -r who uid user pid rest; do
        ! kill -0 "$pid" 2>/dev/null || echo "$who $uid $user $pid $rest"
    done <"$FAKE_INHIBIT/locks"
    exit 0
fi
while [[ $1 == --* ]]; do
    case $1 in --what=*) what=${1#*=} ;; --why=*) why=${1#*=} ;; esac
    shift
done
if [[ -e $FAKE_INHIBIT/refuse-$what ]]; then echo 'Failed to inhibit: Access denied' >&2; exit 1; fi
echo "apex-runner 1000 owner $$ tail $what $why block" >>"$FAKE_INHIBIT/locks"
exec "$@"
EOF
cat >"$FI/bin/podman" <<'EOF'
#!/usr/bin/env bash
# podman start --attach: a JIT runner's output for one job, which exits with $FAKE_INHIBIT/rc.
held() { systemd-inhibit --list | awk '$1 == "apex-runner" { print $6 }' | sort | paste -sd' ' -; }
echo 'Listening for Jobs'
held >"$FAKE_INHIBIT/before-job"
echo '2026-10-30 12:26:00Z: Running job: vm'
for _ in $(seq 50); do [[ $(held) == "$(cat "$FAKE_INHIBIT/expect")" ]] && break; sleep 0.1; done
held >"$FAKE_INHIBIT/during-job"
for _ in $(seq 100); do [[ -e $FAKE_INHIBIT/hold ]] || break; sleep 0.1; done
echo 'Job vm completed'
exit "$(cat "$FAKE_INHIBIT/rc")"
EOF
chmod +x "$FI/bin/"*
ri() { # RC EXPECT: attach_job on the fake runner whose job exits RC once the locks EXPECT are held
    echo "$1" >"$FI/rc"
    echo "$2" >"$FI/expect"
    : >"$FI/locks"
    rm -f "$FI/before-job" "$FI/during-job"
    # shellcheck disable=SC2016 # expanded by the inner bash
    PATH="$FI/bin:$PATH" FAKE_INHIBIT="$FI" bash -c '. "$1"; INHIBIT_WAIT=2; attach_job apex-kvm-x' _ \
        "$APEX_ROOT/tools/runner/runner.sh" >"$FI/out" 2>"$FI/err"
}
ri_held() { PATH="$FI/bin:$PATH" FAKE_INHIBIT="$FI" bash -c '. "$1"; inhibitors_held' _ "$APEX_ROOT/tools/runner/runner.sh"; }
ri_released() { # the locks end with the job: tail --pid sees the watcher gone within a second
    local i
    for i in $(seq 30); do [[ -z $(ri_held) ]] && return 0; sleep 0.1; done
    return 1
}
ri_rc=0
ri 0 'handle-lid-switch idle sleep' || ri_rc=$?
check "runner: a job that succeeds exits 0 through the watcher" 0 "$ri_rc"
check "runner: no lock while the runner waits for a job" "" "$(cat "$FI/before-job")"
check "runner: sleep, idle and the lid switch are held while the job runs" \
    'handle-lid-switch idle sleep' "$(cat "$FI/during-job")"
check_true "and the job's log says so" grep -qF \
    'sleep inhibitor: held (sleep idle handle-lid-switch) for VM job: vm, until the job ends' "$FI/err"
check_true "the runner's own output passes unchanged" grep -qx '2026-10-30 12:26:00Z: Running job: vm' "$FI/out"
check "runner: the locks end with the job" 0 "$(rc_of ri_released)"
ri_rc=0
ri 1 'handle-lid-switch idle sleep' || ri_rc=$?
check "runner: a job that fails keeps its exit status" 1 "$ri_rc"
check "runner: and its locks end too" 0 "$(rc_of ri_released)"
: >"$FI/refuse-sleep"
: >"$FI/refuse-handle-lid-switch"
ri 0 idle
check "runner: polkit's refusal of sleep and the lid leaves idle held" idle "$(cat "$FI/during-job")"
check_true "and the job's log names each refusal and asks to keep the laptop awake" grep -qF \
    'sleep inhibitor: refused (sleep: Failed to inhibit: Access denied;handle-lid-switch: Failed to inhibit: Access denied); keep the laptop awake for this job' \
    "$FI/err"
rm "$FI/refuse-sleep" "$FI/refuse-handle-lid-switch"
echo 'handle-lid-switch idle sleep' >"$FI/expect"
echo 0 >"$FI/rc"
: >"$FI/locks"
: >"$FI/hold"
# shellcheck disable=SC2016 # expanded by the inner bash
PATH="$FI/bin:$PATH" FAKE_INHIBIT="$FI" setsid bash -c '. "$1"; attach_job apex-kvm-x' _ \
    "$APEX_ROOT/tools/runner/runner.sh" >/dev/null 2>&1 &
ri_pid=$!
for _ in $(seq 50); do [[ $(ri_held) == 'handle-lid-switch idle sleep' ]] && break; sleep 0.1; done
kill -TERM -- "-$ri_pid" 2>/dev/null || true
wait "$ri_pid" 2>/dev/null || true
check "runner: a job stopped by a signal (systemctl stop) leaves no lock" 0 "$(rc_of ri_released)"
rm "$FI/hold"
: >"$FI/locks"
check "runner: status says when no lock is held" \
    'sleep inhibitor: none held (no job runs, or polkit refused the locks: see the job'"'"'s log)' \
    "$(PATH="$FI/bin:$PATH" FAKE_INHIBIT="$FI" bash -c '. "$1"; inhibitor_status' _ "$APEX_ROOT/tools/runner/runner.sh")"
sleep 30 &
printf 'apex-runner 1000 owner %s tail %s VM job: vm block\n' "$!" sleep "$!" idle >"$FI/locks"
check "runner: and which locks are held" 'sleep inhibitor: held (idle sleep)' \
    "$(PATH="$FI/bin:$PATH" FAKE_INHIBIT="$FI" bash -c '. "$1"; inhibitor_status' _ "$APEX_ROOT/tools/runner/runner.sh")"
kill "$!"

# --- vm.yml: the Commit, build and gates steps, taken from the workflow, on canned results ---
V="$TMP/vm-yml"
mkdir -p "$V/bin"
vm_step() { # NAME: the run: script of vm.yml's step NAME, as GitHub hands it to bash
    awk -v name="      - name: $1" '
        $0 == name { found = 1; next }
        found && /^      - name: / { exit }
        found && /^        run: \|$/ { body = 1; next }
        body && /^          / { print substr($0, 11); next }
        body && /^$/ { print ""; next }
        body { exit }' "$APEX_ROOT/.github/workflows/vm.yml"
}
cat >"$V/bin/ssh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$FAKE_VM/ssh.args"
echo "::error::a line of the VM's log" >&2
[[ ! -s $FAKE_VM/results.tar ]] || cat "$FAKE_VM/results.tar"
exit "$(cat "$FAKE_VM/ssh.rc")"
EOF
chmod +x "$V/bin/ssh"
vm_run() { # STEP [VAR=VALUE...]: one step with GitHub's files; prints its exit status
    local step=$1 rc=0
    shift
    vm_step "$step" >"$V/step.sh"
    [[ -s $V/step.sh ]] || { echo "no step '$step' in vm.yml"; return; }
    env PATH="$V/bin:$PATH" FAKE_VM="$V" RUNNER_TEMP="$V/temp" GITHUB_OUTPUT="$V/output" \
        GITHUB_STEP_SUMMARY="$V/summary" GITHUB_SHA="$CI_SHA" "$@" \
        bash --noprofile --norc -eo pipefail "$V/step.sh" >"$V/log" 2>&1 || rc=$?
    printf '%s' "$rc"
}
vm_reset() { rm -rf "$V/temp" "$V/output" "$V/summary" "$V/results" "$V/ssh.args" "$V/results.tar"; mkdir -p "$V/temp"; }
vm_results() { # FILE=CONTENT...: the results tar ci-build would return
    local kv
    rm -rf "$V/results"
    mkdir -p "$V/results"
    for kv in "$@"; do
        mkdir -p "$V/results/$(dirname "${kv%%=*}")"
        printf '%s\n' "${kv#*=}" >"$V/results/${kv%%=*}"
    done
    tar -C "$V/results" -cf "$V/results.tar" .
}
COMMIT='Commit'
BUILD='Components, RPMs, lane, image, G2 twice, G4 when due, gates, promote (builder VM)'
GATES='Gates file'
check "vm.yml has the three steps the selftest runs" "yes yes yes" \
    "$(for s in "$COMMIT" "$BUILD" "$GATES"; do [[ -n $(vm_step "$s") ]] && printf 'yes ' || printf 'no '; done | sed 's/ $//')"

vm_reset
check "Commit: a push builds GITHUB_SHA" "0|sha=$CI_SHA" "$(vm_run "$COMMIT" GITHUB_EVENT_NAME=push INPUT_SHA=)|$(cat "$V/output")"
vm_reset
check "Commit: the schedule asks for the daily extras" "0|sha=$CI_SHA extra=daily" \
    "$(vm_run "$COMMIT" GITHUB_EVENT_NAME=schedule INPUT_SHA=)|$(paste -sd' ' "$V/output")"
vm_reset
check "Commit: a dispatch builds its input" "0|sha=$CI_OTHER" \
    "$(vm_run "$COMMIT" GITHUB_EVENT_NAME=workflow_dispatch INPUT_SHA="$CI_OTHER")|$(cat "$V/output")"
vm_reset
check "Commit: a short sha is an error" "1|::error::not a full commit sha: abc123" \
    "$(vm_run "$COMMIT" GITHUB_EVENT_NAME=workflow_dispatch INPUT_SHA=abc123)|$(cat "$V/log")"

for case in "0:" "1:::error::the build in the builder VM failed (exit 1)" "2:::error::ci-build refused $CI_SHA" \
    "75:::error::another build holds the builder VM" \
    "255:::error::ssh lost or never reached the builder VM (exit 255): is it running? (just vm-status; tools/runner/README.md, Troubleshooting)"; do
    vm_reset
    echo "${case%%:*}" >"$V/ssh.rc"
    check "build: ssh exit ${case%%:*} is the step's exit, with its message" "${case%%:*}|${case#*:}" \
        "$(vm_run "$BUILD" SHA="$CI_SHA" EXTRA=)|$(grep -v -e "^::stop-commands::" -e '^::[0-9a-f]\{32\}::$' -e "a line of the VM's log" "$V/log")"
done
vm_stopped() { # the VM's line sits between ::stop-commands::TOKEN and ::TOKEN::
    local first token
    first=$(sed -n 1p "$V/log")
    token=${first#::stop-commands::}
    [[ $first == "::stop-commands::$token" && ${#token} == 32 ]] &&
        [[ $(sed -n 2p "$V/log") == "::error::a line of the VM's log" && $(sed -n 3p "$V/log") == "::$token::" ]]
}
check_true "build: the VM's log runs with workflow commands stopped, then they resume" vm_stopped
vm_reset
echo 0 >"$V/ssh.rc"
vm_run "$BUILD" SHA="$CI_SHA" EXTRA= >/dev/null
check "build: a push asks for the build alone" "apex-builder ci-build $CI_SHA" "$(cat "$V/ssh.args")"
vm_run "$BUILD" SHA="$CI_SHA" EXTRA=daily >/dev/null
check "build: the daily run adds daily" "apex-builder ci-build $CI_SHA daily" "$(cat "$V/ssh.args")"

vm_gates() { cp "$V/results.tar" "$V/temp/results.tar" 2>/dev/null || : >"$V/temp/results.tar"; vm_run "$GATES"; }
vm_reset
vm_results "ci-build.txt=sha $CI_SHA" "gates-passed.txt=lock-sha256 x" "lock.diff=+family a" "g2-result.txt=PASS" \
    "g4-results.md=| local | PASS |" "qualify-logs/local.png=png"
check "gates: a green build passes" 0 "$(vm_gates)"
check "gates: with each result in the summary" "## Builder VM|### ci-build|### Gates (gates-passed.txt)|### Lane lock (rpms.lock to rpms.lock.next, before the promotion)|### G2 (result.txt)|### G4 (results.md)" \
    "$(grep -E '^##' "$V/summary" | paste -sd'|')"
check_true "gates: G4's table has its header with the layer feature column" \
    grep -qx '| Test | Result | Detail | Layer feature |' "$V/summary"
check "gates: and G4's logs for the artifact" "logs=$V/temp/logs|local.png" \
    "$(cat "$V/output")|$(ls "$V/temp/logs/qualify-logs")"
vm_reset
vm_results "ci-build.txt=sha $CI_SHA" "lock.diff=x"
check "gates: a red build without a gates file fails" "1|::error::no gates file: G2 or G4 did not pass" \
    "$(vm_gates)|$(cat "$V/log")"
check "gates: and still writes its summary, but no artifact without logs" "yes|" \
    "$(grep -q '^### ci-build' "$V/summary" && echo yes)|$(cat "$V/output" 2>/dev/null)"
vm_reset
check "gates: an empty results tar is an error" "1|::error::the builder VM returned no results" "$(vm_gates)|$(cat "$V/log")"
vm_reset
vm_results "ci-build.txt=sha $CI_SHA" "gates-passed.txt=lock-sha256 x" "absorb/report.md=# Lane absorption report
| Family | x |" "absorb/rows.tsv=x" "absorb/warnings.tsv=$(printf 'gnome-shell\tgnome-shell-51.1-1.fc45\tfails\t0015-lock.patch: 100%% of hunk 4\nptyxis\tptyxis-51.0-1.fc45\tfuzz\t1 patch(es); x')"
check "gates: the daily run's warnings never fail the step" 0 "$(vm_gates)"
check "gates: one escaped warning per family" \
    "::warning title=absorb gnome-shell::gnome-shell-51.1-1.fc45 (updates-testing): fails 0015-lock.patch: 100%25 of hunk 4|::warning title=absorb ptyxis::ptyxis-51.0-1.fc45 (updates-testing): fuzz 1 patch(es); x" \
    "$(grep '^::warning' "$V/log" | paste -sd'|')"
check "gates: the report joins the summary and the artifact" "### Absorption (lane-absorb-report.sh)|warnings.tsv" \
    "$(grep -o '^### Absorption.*' "$V/summary")|$([[ -s $V/temp/logs/absorb/warnings.tsv ]] && echo warnings.tsv)"
vm_reset
vm_results "gates-passed.txt=x" "absorb/warnings.tsv=$(printf 'evil\tx\tfails\tline one\n::error::injected\tx\tfails\ty')"
vm_gates >/dev/null
check "gates: a warning line cannot issue a command of its own" 0 "$(grep -c '^::error::injected' "$V/log")"
check "gates: and its family cannot end the title property" \
    "::warning title=absorb %3A%3Aerror%3A%3Ainjected::x (updates-testing): fails y" "$(grep 'injected' "$V/log")"
check_true "gates: the artifact is vm-logs-<sha>" grep -qF "name: vm-logs-\${{ steps.commit.outputs.sha }}" "$APEX_ROOT/.github/workflows/vm.yml"
vm_reset
vm_results "gates-passed.txt=x" "ci-build.txt=$(printf 'sha %s\nstale /usr/local/libexec/apex/ci-build differs from this commit'"'"'s tools/builder-vm/ci-build.sh: run just vm-ci-install' "$CI_SHA")"
check "gates: a stale ci-build warns, and never fails the step" "0|::warning title=ci-build stale::the builder VM's installed ci-build differs from this commit's; run just vm-ci-install (tools/runner/README.md, Troubleshooting)" \
    "$(vm_gates)|$(grep '^::warning title=ci-build' "$V/log")"
vm_reset
vm_results "gates-passed.txt=x" "metrics/history.tsv=$(printf 'finished\tsha\tversion\tgates\tsize\tlayers\tprevious_size\tsize_change_pct\tnew_bytes\tfamilies\tfirmware\tloader\tkernel\tinitrd\tuserspace\tgreeter\tdesktop\n2026-10-24T03:20:00Z\t%s\t45.1\tyes\t1258291200\t70\t1048576000\t20.0\t209715200\t-\t-\t-\t1.0\t2.0\t12.5\t16.0\t3.0' "$CI_SHA")" \
    "metrics/warnings.tsv=$(printf 'size\tthe image grew 20.0 %% against x\nuserspace\t12.5 s, more than 20 %% above')"
check "gates: metrics warnings never fail the step" 0 "$(vm_gates)"
check "gates: the metrics table, in MiB and seconds" "| 2026-10-24T03:20:00Z | ${CI_SHA:0:12} | yes | 1200 | 20.0 | 200 | 12.5 | 16.0 | 3.0 |" \
    "$(grep "^| 2026-10-24" "$V/summary")"
check "gates: one warning per metric" "::warning title=metrics size::the image grew 20.0 %25 against x|::warning title=metrics userspace::12.5 s, more than 20 %25 above" \
    "$(grep '^::warning title=metrics' "$V/log" | paste -sd'|')"
check_true "gates: metrics/ joins the artifact" test -s "$V/temp/logs/metrics/history.tsv"
# next-compose: report-only, off until APEX_NEXT_COMPOSE, and never sent to an old ci-build.
cat >"$V/bin/ssh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_VM/ssh.args"
if [[ $* == "apex-builder ci-build modes" ]]; then
    [[ ! -e $FAKE_VM/old-host ]] || { echo "ci-build: refused" >&2; exit 2; }
    echo "daily next"
    exit 0
fi
echo "::error::a line of the VM's log" >&2
[[ ! -s $FAKE_VM/results.tar ]] || cat "$FAKE_VM/results.tar"
exit "$(cat "$FAKE_VM/ssh.rc")"
EOF
NEXT_MODES="Does the builder VM's ci-build take next"
NEXT_BUILD='Next release compose, lane, image, G1 (builder VM)'
NEXT_REPORT='Next lane report'
next_job=$(awk '/^  next-compose:$/ { f = 1; next } f && /^  [a-z]/ { exit } f' "$APEX_ROOT/.github/workflows/vm.yml")
check_true "next-compose runs only on the schedule, with APEX_NEXT_COMPOSE on" \
    grep -q "github.event_name == 'schedule' && vars.APEX_NEXT_COMPOSE == 'on'" <<<"$next_job"
check_true "after the 45 build, whatever its result" grep -qx '    needs: build' <<<"$next_job"
check "and no step of it exits non-zero on its own" 0 "$(grep -cE '^\s+exit [1-9"$]' <<<"$next_job")"
vm_reset
: >"$V/old-host"
check "modes: a ci-build on the old grammar is not sent next, and the step passes" "0||1" \
    "$(vm_run "$NEXT_MODES")|$(cat "$V/output" 2>/dev/null)|$(grep -c 'predates next: run just vm-ci-install' "$V/log")"
rm "$V/old-host"
vm_reset
check "modes: a current one is" "0|next=1" "$(vm_run "$NEXT_MODES")|$(cat "$V/output")"
vm_reset
echo 1 >"$V/ssh.rc"
check "build: a failed next build warns, and never fails the job" "0|apex-builder ci-build $CI_SHA next|1" \
    "$(vm_run "$NEXT_BUILD" SHA="$CI_SHA")|$(cat "$V/ssh.args")|$(grep -c "next lane's build in the builder VM failed (exit 1)" "$V/log")"
check_true "build: the VM's log runs with workflow commands stopped" vm_stopped
echo 0 >"$V/ssh.rc"
vm_reset
vm_results "ci-build.txt=$(printf 'sha %s\nnext 46\nbuild-image 0\npair unavailable for Fedora 46: no fedora-46 pins\n%s\nexit 0' \
    "$CI_SHA" 'fallback gnome-shell at build.log (/s/next/pkgs/gnome-shell/last-failure.txt): rpmbuild failed')" \
    "next/build.env=$(printf 'BASE_SOURCE=rawhide\nBASE_VERSION=46.20261024.0')" "next/failures/gnome-shell.txt=rpmbuild failed" \
    "next/rpms.lock.next=family kernel-cachyos stock - reason=pair unavailable for Fedora 46: no fedora-46 pins"
cp "$V/results.tar" "$V/temp/next.tar"
check "report: one line with the release, its rawhide base, the build and the pair" \
    "0|Fedora 46, base rawhide 46.20261024.0: build-image 0, pair unavailable for Fedora 46: no fedora-46 pins" \
    "$(vm_run "$NEXT_REPORT")|$(sed -n 3p "$V/summary")"
check_true "report: and the next lane's lock" grep -q '^family kernel-cachyos stock - reason=pair unavailable' "$V/summary"
check "report: G1's result, and each family that fell back, with its step and log" \
    "G1 passed on the image that built.|- **gnome-shell** at build.log (/s/next/pkgs/gnome-shell/last-failure.txt): rpmbuild failed" \
    "$(grep -E '^(G1 |- )' "$V/summary" | paste -sd'|')"
check "report: their logs go to the next-logs artifact" "logs=$V/temp/next/next/failures" "$(cat "$V/output")"
vm_reset
check "report: no results warn, and never fail the job" "0|1" \
    "$(vm_run "$NEXT_REPORT")|$(grep -c 'returned no results' "$V/log")"

# --- S4's budget: qualify.sh's boot phases and metrics.sh's rows, history and warnings -------
bp() { bash -c '. "$1"; boot_phases' _ "$APEX_ROOT/.github/scripts/qualify.sh" | paste -sd' '; }
check "boot phases: firmware to userspace, minutes included" \
    "firmware 3.123 loader 1.002 kernel 1.234 initrd 2.345 userspace 65.678" \
    "$(printf 'Startup finished in 3.123s (firmware) + 1.002s (loader) + 1.234s (kernel) + 2.345s (initrd) + 1min 5.678s (userspace) = 1min 13.382s\ngraphical.target reached after 1min 5.5s in userspace.\n' | bp)"
check "boot phases: a VM without firmware or loader times, in ms" "kernel 0.845 initrd 2.000 userspace 12.345" \
    "$(echo 'Startup finished in 845ms (kernel) + 2s (initrd) + 12.345s (userspace) = 15.190s' | bp)"
check "boot phases: an unfinished boot gives none" "" "$(echo 'Bootup is not yet finished (org.freedesktop.systemd1.Manager.FinishTimestampMonotonic=0).' | bp)"

M="$TMP/metrics"
mkdir -p "$M/co/.github/scripts" "$M/co/tools/builder-vm" "$M/co/_build/image" "$M/co/_build/qualify" "$M/bin" "$M/store"
cp "$APEX_ROOT/.github/scripts/lib.sh" "$M/co/.github/scripts/"
cp "$APEX_ROOT/tools/builder-vm/metrics.sh" "$M/co/tools/builder-vm/"
cat >"$M/bin/skopeo" <<'EOF'
#!/usr/bin/env bash
case ${*: -1} in
    oci:*) cat "$FAKE_M/now.json" ;;
    docker://*) [[ -s $FAKE_M/prev.json ]] && cat "$FAKE_M/prev.json" || exit 1 ;;
esac
EOF
cat >"$M/bin/image.sh" <<'EOF'
#!/usr/bin/env bash
echo "$1 previous=$APEX_PREVIOUS_BUILD" >>"$FAKE_M/image.log"
EOF
printf '#!/usr/bin/env bash\nexec "$@"\n' >"$M/bin/sudo"
chmod +x "$M/bin/"*
echo 'APEX_VERSION=45.20261024.1' >"$M/co/_build/image/build.env"
m_manifest() { # CONFIG_SIZE DIGEST:SIZE...
    local c=$1 l
    shift
    printf '{"config":{"size":%s},"layers":[%s]}' "$c" \
        "$(for l in "$@"; do printf '{"digest":"%s","size":%s}\n' "${l%%:*}" "${l#*:}"; done | paste -sd, -)"
}
m_run() { # [size] [gates] [boot USERSPACE GREETER]: one build; prints metrics.sh's exit
    local rc=0 size=()
    if [[ ${1:-} == size ]]; then size=(size); shift; fi
    : >"$M/stamp"
    sleep 0.01
    rm -f "$M/co/_build/gates-passed.txt" "$M/co/_build/qualify/boot.tsv"
    if [[ ${1:-} == gates ]]; then echo x >"$M/co/_build/gates-passed.txt"; shift; fi
    if [[ ${1:-} == boot ]]; then printf 'kernel 1.0\nuserspace %s\ngreeter %s\ndesktop 3.0\n' "$2" "$3" >"$M/co/_build/qualify/boot.tsv"; fi
    rm -rf "$M/out"
    env PATH="$M/bin:$PATH" FAKE_M="$M" APEX_STORE="$M/store" APEX_METRICS_IMAGE_SH="$M/bin/image.sh" GITHUB_ACTIONS='' \
        bash "$M/co/tools/builder-vm/metrics.sh" "$M/out" "$M/stamp" "$CI_SHA" "$M/lock.diff" "${size[@]}" 2>/dev/null || rc=$?
    printf '%s' "$rc"
}
m_col() { awk -F'\t' -v n="$1" 'NR == 1 { for (i = 1; i <= NF; i++) if ($i == n) c = i } NR == 2 { print $c }' "$M/out/metrics.tsv"; }
m_now() { m_manifest 1000 a:400000 "c$1:$1" >"$M/now.json"; }
: >"$M/lock.diff"
rm -f "$M/prev.json"
m_now 600000
check "metrics: the first build, before any apex:45, writes its row" 0 "$(m_run size gates boot 10.0 15.0)"
check "metrics: compressed size and layers, no previous to compare" "1001000 2 - - - yes" \
    "$(for c in size layers previous_size size_change_pct new_bytes gates; do printf '%s ' "$(m_col $c)"; done | sed 's/ $//')"
check "metrics: rechunked against the published apex:45" "rechunk previous=ghcr.io/apex-linux/apex:45" "$(cat "$M/image.log")"
check "metrics: boot values from this run's G4" "10.0 15.0 3.0 45.20261024.1" "$(m_col userspace) $(m_col greeter) $(m_col desktop) $(m_col version)"
check "metrics: no warning on the first build" "" "$(cat "$M/out/warnings.tsv")"
m_manifest 1000 a:400000 b:600000 >"$M/prev.json"
m_now 800000
m_run size gates boot 12.5 16.0 >/dev/null
check "metrics: the change against apex:45, and the bytes of the layers it lacks" "1001000 20.0 800000" \
    "$(m_col previous_size) $(m_col size_change_pct) $(m_col new_bytes)"
check "metrics: 20 % growth with no family change, and a 25 % slower userspace, warn" \
    "size userspace" "$(cut -f1 "$M/out/warnings.tsv" | paste -sd' ')"
check_true "metrics: the userspace warning names the last green build's time" \
    grep -q "^userspace	12.5 s, more than 20 % above the last green build's 10.0 s$" "$M/out/warnings.tsv"
printf -- '-family gnome-shell built k1\n+family gnome-shell built k2\n' >"$M/lock.diff"
m_run size gates boot 12.5 16.0 >/dev/null
check "metrics: growth that a family change explains does not warn" "gnome-shell|" \
    "$(m_col families)|$(grep '^size' "$M/out/warnings.tsv")"
: >"$M/lock.diff"
rm -f "$M/image.log"
m_run gates >/dev/null
check "metrics: a green build that is not the daily one takes no size and rechunks nothing" "yes -|no rechunk" \
    "$(m_col gates) $(m_col size)|$([[ -e $M/image.log ]] && echo rechunk || echo 'no rechunk')"
m_run size >/dev/null
check "metrics: a red build has no size, no rechunk and no boot values" "no - - -|no rechunk" \
    "$(m_col gates) $(m_col size) $(m_col userspace) $(m_col greeter)|$([[ -e $M/image.log ]] && echo rechunk || echo 'no rechunk')"
check "metrics: the history keeps every build" 5 "$(($(wc -l <"$M/store/metrics.tsv") - 1))"
for _ in $(seq 30); do m_run >/dev/null; done
check "metrics: and only the last 30 of them" "31 31" "$(wc -l <"$M/store/metrics.tsv") $(wc -l <"$M/out/history.tsv")"
check "metrics: OUT that cannot be written is the one error" 1 \
    "$(env PATH="$M/bin:$PATH" APEX_STORE="$M/store" bash "$M/co/tools/builder-vm/metrics.sh" /proc/x "$M/stamp" "$CI_SHA" "$M/lock.diff" >/dev/null 2>&1; echo $?)"

# --- .gitignore: biometric file names are never tracked ------------------------------------
for f in a.pgm B.PGM x/print.Variant rec.ioctl x/y/rec.UMOCKDEV cap.pcap cap.PcapNG \
    var/lib/fprint/u/1 image/system_files/var/lib/fprint/u/1; do
    check_true ".gitignore ignores $f" git -C "$APEX_ROOT" check-ignore -q --no-index "$f"
done

if ((FAILS > 0)); then
    die "selftest: $FAILS failure(s)"
fi
log "selftest: all $TESTS checks passed (plus the registry checks)"
