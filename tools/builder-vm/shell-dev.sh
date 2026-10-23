#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

usage() {
    cat <<'EOF'
The shell dev loop (ADR 0014): apex-gnome's desktop/shell/ (the Apex JS, SCSS and
assets; the checkout APEX_GNOME_SRC, default ../apex-gnome) and the upstream JS and SCSS of the lane's gnome-shell work tree, run by a
nested `gnome-shell --devkit --unsafe-mode` in the desktop VM through
G_RESOURCE_OVERLAYS. An edit shows within seconds, and none of it enters the image.

  shell-dev.sh fetch     copy from the builder VM the inputs for the gnome-shell build
                         the desktop VM runs (the builder's rpms.lock.next when the VM
                         is off): the work tree's upstream JS and SCSS, made with
                         `lane.sh prep` when there is none, mutter-devkit, and the Apex
                         SRPM. The builder VM is started for this and stopped again if it
                         was not running
  shell-dev.sh [run]     send the inputs and desktop/shell/ to the VM, start the nested
                         shell as the user logged in to GNOME there, then look for edits
                         every second: SCSS recompiles and reloads the sheets, JS or a
                         theme asset restarts the nested shell. Ctrl+C stops it
  shell-dev.sh push      send the inputs and desktop/shell/ only (the C loop's SRPM)
  shell-dev.sh eval JS   run JS in the nested shell and print Eval's reply
  shell-dev.sh screenshot [FILE]
                         save the nested shell's screen as PNG and print its path
  shell-dev.sh stop      stop the nested shell
  shell-dev.sh probe     with the loop running: append a rule to an Apex partial, then a
                         line to layer.js, time each until the nested shell shows it, and
                         take the line out again; exit 1 when one took longer than 15 s
                         (APEX_SHELL_DEV_PROBE_LIMIT), or when a file changed meanwhile
                         so that its line could not be taken out. The files as they were
                         wait in the VM directory's .shell-dev-probe/ until then

The VM is the one desktop-vm.sh targets (APEX_DESKTOP_DIR, APEX_DESKTOP_THROWAWAY), and
the fetched inputs stay in its directory, under shell-dev/. Files reach the VM as tar
over desktop-vm.sh's ssh into /var/lib/apex-shell-dev, where sassc runs in a container.
/usr in the VM is writable until its next reboot (bootc usroverlay), for mutter-devkit.
EOF
}

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd -- "$HERE/../.." && pwd)
readonly HERE REPO
readonly DESKTOP=$HERE/desktop-vm.sh
readonly BUILDER=$HERE/builder-vm.sh
readonly GUEST_SCRIPT=$HERE/shell-dev-guest.sh
readonly SHELL_SOURCES=${APEX_GNOME_SRC:-$REPO/../apex-gnome}/desktop/shell
readonly GUEST_ROOT=/var/lib/apex-shell-dev
readonly GUEST_SCRIPT_PATH=$GUEST_ROOT/bin/shell-dev-guest.sh
readonly VM_LOCK=/usr/share/apex/rpms.lock
readonly BUILDER_WORK_DIR=apex-image/_build/pkg/gnome-shell
readonly BUILDER_STORE_PKG=apex-store/pkgs/gnome-shell
readonly BUILDER_LOCK_NEXT=apex-store/rpms.lock.next
readonly POLL_SECONDS=1
readonly PROBE_LIMIT_SECONDS=${APEX_SHELL_DEV_PROBE_LIMIT:-15}
readonly PROBE_PARTIAL=$SHELL_SOURCES/data/theme/apex/_top-bar.scss
readonly PROBE_MODULE=$SHELL_SOURCES/js/ui/apex/layer.js
readonly PROBE_BAR_HEIGHT=37
# The nested shell starts in the overview, where the sheet's #panel:overview outranks #panel.
readonly PROBE_RULE="#panel, #panel:overview { height: ${PROBE_BAR_HEIGHT}px; }"

STOP_BUILDER=0
STAGING=
PROBE_BACKUP=
PROBE_PENDING=()
PROBE_FILE_KEPT=0
PROBE_RESULTS=()
LOG_FOLLOWER=
NESTED_SHELL_STARTED=0

log() { printf '[shell-dev] %s\n' "$*" >&2; }
die() { printf '[shell-dev] error: %s\n' "$*" >&2; exit 1; }

require_tools() {
    local t missing=()
    for t in "$@"; do command -v "$t" >/dev/null 2>&1 || missing+=("$t"); done
    ((${#missing[@]} == 0)) || die "missing host tools: ${missing[*]}"
}

now_ms() {
    local ns
    ns=$(date +%s%N)
    printf '%s\n' "$((ns / 1000000))"
}

seconds_since() {
    local start_ms=$1
    local ms=$(($(now_ms) - start_ms))
    printf '%d.%d\n' "$((ms / 1000))" "$((ms % 1000 / 100))"
}

is_safe_word() { [[ $1 =~ ^[A-Za-z0-9._:+~^-]+$ ]]; }
is_rpm_file() { [[ $1 =~ ^[A-Za-z0-9._+~^-]+\.rpm$ ]]; }
sha256_is() { [[ $(sha256sum -- "$1" | cut -d' ' -f1) == "$2" ]]; }

lock_family() {
    local lock=$1
    awk '$1 == "family" && $2 == "gnome-shell" { print $3, $4; exit }' <<<"$lock"
}

manifest_stock() {
    local manifest=$1
    sed -n 's/^# pkg=.* stock=\([^ ]*\).*$/\1/p' <<<"$manifest" | head -n 1
}

manifest_entry() {
    local manifest=$1 kind=$2 name=$3
    awk -v kind="$kind" -v prefix="$name-" '
        $1 == kind && index($2, prefix) == 1 && substr($2, length(prefix) + 1) ~ /^[0-9]+:/ {
            print $2, $3, $4
            exit
        }' <<<"$manifest"
}

version_release() {
    local nevra=$1
    local version_release_arch=${nevra#*:}
    printf '%s\n' "${version_release_arch%.*}"
}

sources_state() {
    local inputs=$1
    find "$SHELL_SOURCES" "$inputs/source.env" "$inputs/tree" -type f -printf '%p\t%T@\t%s\n' 2>/dev/null |
        LC_ALL=C sort || true
}

changed_paths() {
    local old_state=$1 new_state=$2
    LC_ALL=C comm -3 <(printf '%s\n' "$old_state") <(printf '%s\n' "$new_state") |
        sed 's/^\t//' | cut -f1 | sed '/^$/d' | LC_ALL=C sort -u
}

reaction() {
    local path strongest=0
    local -r actions=(none reload restart prepare)
    local -r reload=1 restart=2 prepare=3
    for path in "$@"; do
        case $path in
            */meson.build | */apex.gresource.xml) ;;
            */source.env) strongest=$prepare ;;
            *.scss) ((strongest >= reload)) || strongest=$reload ;;
            # JS modules and theme assets load once per process.
            *.js | */data/theme/apex/*) ((strongest >= restart)) || strongest=$restart ;;
        esac
    done
    printf '%s\n' "${actions[strongest]}"
}

replace_dir() {
    local new=$1 target=$2
    local retired=$target.retired
    rm -rf -- "$retired"
    if [[ -e $target ]]; then mv -T -- "$target" "$retired"; fi
    mv -T -- "$new" "$target"
    rm -rf -- "$retired"
}

repos_base() {
    (
        # shellcheck source=SCRIPTDIR/../../.github/scripts/lib.sh
        . "$REPO/.github/scripts/lib.sh"
        local base
        base=$(containerfile_arg REPOS_BASE)
        is_fedora_pin "$base" || die "image/Containerfile's REPOS_BASE '$base' is not a digest-pinned Fedora image"
        printf '%s\n' "$base"
    )
}

guest_command() { printf '%q ' bash "$GUEST_SCRIPT_PATH" "$@"; }
guest() { "$DESKTOP" exec "$(guest_command "$@")"; }

on_exit() {
    if [[ -n $PROBE_BACKUP ]]; then finish_probe_backup; fi
    if [[ -n $LOG_FOLLOWER ]]; then kill "$LOG_FOLLOWER" 2>/dev/null || true; fi
    if ((NESTED_SHELL_STARTED)); then guest stop || true; fi
    if [[ -n $STAGING ]]; then rm -rf -- "$STAGING"; fi
    if ((STOP_BUILDER)); then "$BUILDER" stop; fi
}

fetch_rpm() {
    local key=$1 file=$2 sha=$3 earlier_fetch_dir=$4
    local earlier_copy=$earlier_fetch_dir/$file staged=$STAGING/rpms/$file
    if [[ -f $earlier_copy ]] && sha256_is "$earlier_copy" "$sha"; then
        cp -- "$earlier_copy" "$staged"
    else
        "$BUILDER" fetch "$BUILDER_STORE_PKG/$key/$file" "$staged" >&2
    fi
    sha256_is "$staged" "$sha" || die "$file does not match its sha256 in the lane's manifest"
}

# lane.sh prep deletes the work tree, and an existing one may hold uncommitted work.
make_work_tree_if_surely_absent() {
    local stock=$1 tree_test=0
    "$BUILDER" ssh test -e "$BUILDER_WORK_DIR/tree" || tree_test=$?
    case $tree_test in
        0)
            tree_test=0
            "$BUILDER" ssh test -d "$BUILDER_WORK_DIR/tree/.git" || tree_test=$?
            case $tree_test in
                0) ;;
                1) die "the builder VM's ~/$BUILDER_WORK_DIR/tree is not a git work tree; move it aside there, then fetch again" ;;
                *) die "cannot tell whether the builder VM's gnome-shell work tree is a git work tree (ssh exit $tree_test)" ;;
            esac ;;
        1)
            log "the builder VM has no gnome-shell work tree: making one from $stock (lane.sh prep, a few minutes)"
            "$BUILDER" run tools/builder-vm/snapshot.sh tools/builder-vm/lane.sh prep gnome-shell "$stock" ||
                die "lane.sh prep gnome-shell $stock failed" ;;
        *) die "cannot tell whether the builder VM has a gnome-shell work tree (ssh exit $tree_test)" ;;
    esac
}

fetch() {
    local vm_dir inputs
    vm_dir=$TARGET_VM_DIR
    inputs=$vm_dir/shell-dev
    require_tools tar sha256sum awk sed rsync
    if ! "$BUILDER" running; then
        log "starting the builder VM for the fetch; it stops again afterwards"
        STOP_BUILDER=1
        "$BUILDER" start
    fi

    local lock origin
    if "$DESKTOP" running; then
        origin="the VM's $VM_LOCK"
        lock=$("$DESKTOP" exec cat "$VM_LOCK") || die "cannot read $origin"
    else
        origin="the builder VM's ~/$BUILDER_LOCK_NEXT (the desktop VM is off)"
        lock=$("$BUILDER" ssh cat "$BUILDER_LOCK_NEXT") || die "cannot read $origin; build the image first (just vm-image)"
    fi
    local state key
    read -r state key <<<"$(lock_family "$lock")"
    case $state in
        built | held) ;;
        stock) die "$origin has Fedora's own gnome-shell (the owner chose stock): there is no Apex shell to develop against" ;;
        *) die "$origin has no gnome-shell family" ;;
    esac
    is_safe_word "$key" || die "unexpected store key '$key' in $origin"

    local manifest stock shell_nevra devkit_nevra devkit_sha devkit_file srpm_sha srpm_file
    manifest=$("$BUILDER" ssh cat "$BUILDER_STORE_PKG/$key/manifest.txt") ||
        die "the builder VM's store has no ~/$BUILDER_STORE_PKG/$key/manifest.txt"
    stock=$(manifest_stock "$manifest")
    read -r shell_nevra _ _ <<<"$(manifest_entry "$manifest" built gnome-shell)"
    read -r devkit_nevra devkit_sha devkit_file <<<"$(manifest_entry "$manifest" dev mutter-devkit)"
    read -r _ srpm_sha srpm_file <<<"$(manifest_entry "$manifest" apex-srpm gnome-shell)"
    if ! is_safe_word "$stock" || ! is_safe_word "$shell_nevra" || ! is_safe_word "$devkit_nevra" ||
        ! is_rpm_file "$devkit_file" || ! is_rpm_file "$srpm_file"; then
        die "the manifest of store key $key lacks the stock build, gnome-shell, mutter-devkit or the Apex SRPM"
    fi
    log "gnome-shell $(version_release "$shell_nevra") from $stock (store key $key, named by $origin)"

    make_work_tree_if_surely_absent "$stock"

    STAGING=$(mktemp -d "$vm_dir/.shell-dev.XXXXXX")
    mkdir -p "$STAGING/rpms"
    "$BUILDER" ssh "$(printf '%q ' tar -C "$BUILDER_WORK_DIR" --exclude=tree/js/ui/apex \
        --exclude=tree/data/theme/apex -cf - tree-info tree/js tree/data/theme)" |
        tar -C "$STAGING" -xf - || die "cannot copy the work tree from the builder VM"
    local tree_nvr
    tree_nvr=$(sed -n 's/^nvr=//p' "$STAGING/tree-info")
    [[ $tree_nvr == "$stock" ]] ||
        die "the builder VM's work tree is $tree_nvr, but the shell was built from $stock; export its commits (just pkg-export gnome-shell), then remake it: just pkg-rebase gnome-shell $stock"

    fetch_rpm "$key" "$devkit_file" "$devkit_sha" "$inputs/rpms"
    fetch_rpm "$key" "$srpm_file" "$srpm_sha" "$inputs/rpms"
    {
        printf 'key=%s\n' "$key"
        printf 'tree_nvr=%s\n' "$stock"
        printf 'shell_vr=%s\n' "$(version_release "$shell_nevra")"
        printf 'mutter_vr=%s\n' "$(version_release "$devkit_nevra")"
        printf 'devkit_rpm=%s\n' "$devkit_file"
        printf 'srpm=%s\n' "$srpm_file"
    } >"$STAGING/source.env"
    replace_dir "$STAGING" "$inputs"
    STAGING=
    log "inputs in $inputs; next: just shell-dev"
}

require_inputs() {
    local inputs=$1
    [[ -s $inputs/source.env ]] ||
        die "no dev-loop inputs for this VM yet: run 'just shell-dev fetch' first (it uses the builder VM)"
    "$DESKTOP" running || die "the desktop VM is not running: just desktop, then log in to GNOME in it"
}

install_guest_script() {
    "$DESKTOP" exec "install -d -m 0755 $GUEST_ROOT ${GUEST_SCRIPT_PATH%/*} && cat >$GUEST_SCRIPT_PATH" <"$GUEST_SCRIPT"
}

push_inputs() { tar -C "$1" -cf - source.env tree rpms | guest receive inputs; }
push_sources() { tar -C "$SHELL_SOURCES" -cf - . | guest receive src; }

push() {
    local inputs=$1
    install_guest_script
    push_inputs "$inputs"
    push_sources
}

follow_log() {
    "$DESKTOP" exec "$(guest_command log)" > >(sed -u 's/^/[shell] /' >&2) &
    LOG_FOLLOWER=$!
}

any_scss() {
    local path
    for path; do [[ $path != *.scss ]] || return 0; done
    return 1
}

send_changed_trees() {
    local inputs=$1 path sources_changed=0 inputs_changed=0
    shift
    for path in "$@"; do
        case $path in
            "$SHELL_SOURCES"/*) sources_changed=1 ;;
            "$inputs"/*) inputs_changed=1 ;;
        esac
    done
    if ((inputs_changed)); then push_inputs "$inputs" || return; fi
    if ((sources_changed)); then push_sources || return; fi
}

# A failure is reported and the loop goes on, so the next save can fix it.
apply() {
    local inputs=$1 base=$2 action=$3 started compile=(true)
    shift 3
    started=$(now_ms)
    if any_scss "$@" || [[ $action == prepare ]]; then compile=(guest compile "$base"); fi
    if ! send_changed_trees "$inputs" "$@"; then
        log "could not send the changes to the VM; save again to retry"
        return 0
    fi
    case $action in
        none) log "sent $# changed file(s); nothing to reload" ;;
        reload)
            if ! "${compile[@]}"; then
                log "sassc failed; the nested shell keeps the last good sheets"
            elif guest reload; then
                log "sheets recompiled and reloaded in $(seconds_since "$started") s"
            elif guest start; then
                log "the reload failed, so the nested shell restarted with the new sheets in $(seconds_since "$started") s"
            else
                log "the nested shell did not start; fix the error above and save again"
            fi ;;
        restart)
            if "${compile[@]}" && guest start; then
                log "nested shell restarted in $(seconds_since "$started") s"
            else
                log "the nested shell did not start; fix the error above and save again"
            fi ;;
        prepare)
            if guest prepare && "${compile[@]}" && guest start; then
                log "new inputs in place, nested shell restarted in $(seconds_since "$started") s"
            else
                log "the new inputs did not start the nested shell; see the error above"
            fi ;;
    esac
}

watch_sources() {
    local inputs=$1 base=$2 state next changed
    state=$(sources_state "$inputs")
    log "watching $SHELL_SOURCES and the work tree's copy in $inputs; Ctrl+C stops the nested shell"
    while true; do
        sleep "$POLL_SECONDS"
        next=$(sources_state "$inputs")
        [[ $next != "$state" ]] || continue
        mapfile -t changed < <(changed_paths "$state" "$next")
        state=$next
        ((${#changed[@]})) || continue
        apply "$inputs" "$base" "$(reaction "${changed[@]}")" "${changed[@]}"
    done
}

run() {
    local vm_dir inputs base
    vm_dir=$TARGET_VM_DIR
    inputs=$vm_dir/shell-dev
    require_tools tar find comm sed sort
    require_inputs "$inputs"
    base=$(repos_base)
    push "$inputs"
    guest prepare
    guest compile "$base"
    NESTED_SHELL_STARTED=1
    guest start
    follow_log
    watch_sources "$inputs" "$base"
}

restore_probe_file() {
    local file=$1 appended_line=$2
    local backup=$PROBE_BACKUP/${file##*/} shown=${file#"$REPO"/}
    if cmp -s -- "$file" <(cat -- "$backup"; printf '%s\n' "$appended_line"); then
        cp -p -- "$backup" "$file"
    elif [[ $(tail -n 1 -- "$file") == "$appended_line" ]]; then
        sed -i '$d' -- "$file"
        log "$shown changed during the probe: took out only the probe's last line"
    else
        log "$shown changed during the probe and no longer ends with the probe's line: left as it is, the file from before the probe is $backup"
        return 1
    fi
}

restore_pending_probe_files() {
    local entry
    for entry in "${PROBE_PENDING[@]}"; do
        restore_probe_file "${entry%%$'\t'*}" "${entry#*$'\t'}" || PROBE_FILE_KEPT=1
    done
    PROBE_PENDING=()
}

finish_probe_backup() {
    restore_pending_probe_files
    ((PROBE_FILE_KEPT)) || rm -rf -- "$PROBE_BACKUP"
    PROBE_BACKUP=
}

seconds_until_eval_answers() {
    local js=$1 want=$2 limit_seconds=$3 started
    started=$(now_ms)
    until [[ $(guest eval "$js" 2>/dev/null) == "$want" ]]; do
        (($(now_ms) - started < limit_seconds * 1000)) || return 1
        sleep 0.2
    done
    seconds_since "$started"
}

probe_edit() {
    local what=$1 file=$2 appended_line=$3 js=$4 want=$5 before took
    before=$(guest eval "$js")
    PROBE_PENDING+=("$file"$'\t'"$appended_line")
    printf '%s\n' "$appended_line" >>"$file"
    took=$(seconds_until_eval_answers "$js" "$want" "$((2 * PROBE_LIMIT_SECONDS))") || took=timeout
    restore_pending_probe_files
    seconds_until_eval_answers "$js" "$before" "$((2 * PROBE_LIMIT_SECONDS))" >/dev/null ||
        log "the nested shell did not answer $before again after ${file#"$REPO"/} was restored"
    PROBE_RESULTS+=("$took $what")
}

probe() {
    local vm_dir result took what verdict=0 backup
    [[ $PROBE_LIMIT_SECONDS =~ ^[1-9][0-9]*$ ]] || die "APEX_SHELL_DEV_PROBE_LIMIT must be a whole number of seconds"
    vm_dir=$TARGET_VM_DIR
    backup=$vm_dir/.shell-dev-probe
    [[ ! -e $backup ]] ||
        die "an earlier probe did not finish: $backup holds ${PROBE_PARTIAL#"$REPO"/} and ${PROBE_MODULE#"$REPO"/} as they were before it; put back what you need, then remove $backup"
    [[ $(guest eval 'Main.panel.height' 2>/dev/null) == "(true, '"* ]] ||
        die "no nested shell answers in $vm_dir: start the loop first (just shell-dev)"
    mkdir -p -- "$backup"
    PROBE_BACKUP=$backup
    cp -p -- "$PROBE_PARTIAL" "$PROBE_MODULE" "$PROBE_BACKUP/"
    PROBE_RESULTS=()
    probe_edit "SCSS edit of ${PROBE_PARTIAL#"$REPO"/}" "$PROBE_PARTIAL" \
        "$PROBE_RULE" 'Main.panel.height' "(true, '$PROBE_BAR_HEIGHT')"
    probe_edit "JS edit of ${PROBE_MODULE#"$REPO"/}" "$PROBE_MODULE" \
        "globalThis.apexDevloopProbe = $$;" 'globalThis.apexDevloopProbe' "(true, '$$')"
    finish_probe_backup
    ((PROBE_FILE_KEPT)) && verdict=1
    for result in "${PROBE_RESULTS[@]}"; do
        took=${result%% *}
        what=${result#* }
        if [[ $took != timeout ]] && ((10#${took/./} <= PROBE_LIMIT_SECONDS * 10)); then
            log "probe: the $what showed in the nested shell after $took s (limit $PROBE_LIMIT_SECONDS s)"
        else
            log "probe: the $what did not show within $PROBE_LIMIT_SECONDS s (${took/timeout/more than $((2 * PROBE_LIMIT_SECONDS))} s)"
            verdict=1
        fi
    done
    return "$verdict"
}

screenshot() {
    local vm_dir file
    vm_dir=$TARGET_VM_DIR
    file=${1:-$vm_dir/screenshots/shell-dev-$(date +%Y%m%d-%H%M%S).png}
    mkdir -p -- "$(dirname -- "$file")"
    guest screenshot >"$file.part" || { rm -f -- "$file.part"; die "no screenshot"; }
    mv -f -- "$file.part" "$file"
    printf '%s\n' "$file"
}

confirm_target_vm() {
    TARGET_VM_DIR=$("$DESKTOP" target)
    # desktop-vm.sh let this caller reach the VM; the piped calls that follow have no terminal to show it.
    export APEX_DESKTOP_THROWAWAY=${APEX_DESKTOP_THROWAWAY:-0}
}

main() {
    local cmd=${1:-run}
    shift || true
    trap on_exit EXIT
    trap 'exit 130' INT TERM
    case $cmd in
        help | -h | --help) usage; return ;;
        fetch | run | push | eval | screenshot | stop | probe) confirm_target_vm ;;
    esac
    case $cmd in
        fetch) (($# == 0)) || die "usage: $0 fetch"; fetch ;;
        run) (($# == 0)) || die "usage: $0 [run]"; run ;;
        push)
            (($# == 0)) || die "usage: $0 push"
            require_inputs "$TARGET_VM_DIR/shell-dev"
            push "$TARGET_VM_DIR/shell-dev"
            log "sent; in the VM: $GUEST_ROOT/inputs/rpms/ and $GUEST_ROOT/src/" ;;
        eval)
            (($# == 1)) || die "usage: $0 eval JS"
            guest eval "$1" ;;
        screenshot) (($# <= 1)) || die "usage: $0 screenshot [FILE]"; screenshot "$@" ;;
        stop) (($# == 0)) || die "usage: $0 stop"; guest stop ;;
        probe) (($# == 0)) || die "usage: $0 probe"; probe ;;
        *) die "unknown command '$cmd' ($0 help)" ;;
    esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
