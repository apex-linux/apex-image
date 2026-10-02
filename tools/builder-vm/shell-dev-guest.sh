#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

usage() {
    cat <<'EOF'
The desktop VM's half of shell-dev.sh, which installs it as
/var/lib/apex-shell-dev/bin/shell-dev-guest.sh and runs it as root in the guest. It
lives in /var and never in the image: G1 fails an image whose /usr or /etc names the
resource overlay variable or the unsafe-mode flag.

  receive inputs|src   replace that directory with the tar archive on stdin
  prepare              check the inputs against the installed gnome-shell and mutter,
                       make /usr writable until the next reboot (bootc usroverlay) and
                       install mutter-devkit there
  compile BASE         the light, dark and high-contrast sheets into theme/, with sassc
                       in a container of BASE (image/Containerfile's REPOS_BASE)
  start | stop         the nested devkit shell of the user logged in to GNOME
  reload               reload the nested shell's stylesheets
  eval JS              run JS in the nested shell and print Eval's reply
  screenshot           the nested shell's screen, as PNG on stdout
  log                  follow the nested shell's journal
EOF
}

readonly ROOT=/var/lib/apex-shell-dev
readonly UNIT=apex-shell-dev.service
readonly SHELL_ARGS=(--devkit --unsafe-mode)
readonly SASSC_REPO=localhost/apex-shell-dev-sassc
readonly THEME_VARIANTS=(light dark high-contrast)
readonly READY_TIMEOUT_SECONDS=60
readonly BUS_CONFIG=$ROOT/bus.conf
# The private bus starts inside the unit, in its cgroup, so it stops with the nested shell.
# shellcheck disable=SC2016 # expanded by the unit's shell
readonly NESTED_SHELL_SCRIPT='
bus=$1 config=$2
shift 2
rm -f "$bus"
systemd-socket-activate --now -E XDG_RUNTIME_DIR -l "$bus" -- dbus-broker-launch --scope user --config-file "$config" &
tries=0
until [ -S "$bus" ]; do
    tries=$((tries + 1))
    [ "$tries" -le 100 ] || exit 1
    sleep 0.05
done
DBUS_SESSION_BUS_ADDRESS=unix:path=$bus exec gnome-shell "$@"'

SESSION_USER=
SESSION_UID=

log() { printf '[shell-dev guest] %s\n' "$*" >&2; }
die() { printf '[shell-dev guest] error: %s\n' "$*" >&2; exit 1; }

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

# GLib takes the first overlay whose file exists, and the built-in resource when none does,
# so the checkout's Apex files come before the work tree's upstream ones.
overlays() {
    local root=$1
    local pairs=(
        "/org/gnome/shell/ui/apex=$root/src/js/ui/apex"
        "/org/gnome/shell/theme/apex=$root/src/data/theme/apex"
        "/org/gnome/shell/theme=$root/theme"
        "/org/gnome/shell/ui=$root/inputs/tree/js/ui"
        "/org/gnome/shell/misc=$root/inputs/tree/js/misc"
        "/org/gnome/shell/gdm=$root/inputs/tree/js/gdm"
    )
    local IFS=:
    printf '%s\n' "${pairs[*]}"
}

# gdbus call parses each argument as GVariant text, which could read JS as another value or type.
gvariant_string() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    printf '"%s"\n' "$s"
}

input() {
    local name=$1 value
    value=$(sed -n "s/^$name=//p" "$ROOT/inputs/source.env" 2>/dev/null | head -n 1)
    [[ $value =~ ^[A-Za-z0-9._:+~^-]+$ ]] ||
        die "inputs/source.env has no valid $name; run shell-dev.sh fetch, then shell-dev.sh again"
    printf '%s\n' "$value"
}

# rpm -q prints "package NAME is not installed" on stdout, so only a success is kept.
installed_vr() {
    local package=$1 vr
    vr=$(rpm -q --qf '%{VERSION}-%{RELEASE}\n' "$package" 2>/dev/null) || return 0
    printf '%s\n' "$vr"
}

receive() {
    case ${1:-} in
        inputs | src) ;;
        *) die "receive takes inputs or src" ;;
    esac
    local target=$ROOT/$1 incoming=$ROOT/.$1.incoming retired=$ROOT/.$1.retired
    install -d -m 0755 "$ROOT"
    rm -rf -- "$incoming" "$retired"
    mkdir -p -- "$incoming"
    tar -C "$incoming" --no-same-owner -xf -
    chmod -R a+rX -- "$incoming"
    if [[ -e $target ]]; then mv -T -- "$target" "$retired"; fi
    mv -T -- "$incoming" "$target"
    rm -rf -- "$retired"
}

usr_is_writable() {
    local probe=/usr/.apex-shell-dev-probe
    touch "$probe" 2>/dev/null && rm -f "$probe"
}

# The image imports no key into its rpmdb, and rpm 6 refuses a package it cannot verify;
# the import lives in the transient /usr, like mutter-devkit.
trust_fedora_key() {
    local release key
    release=$(sed -n 's/^VERSION_ID=//p' /usr/lib/os-release)
    key=/usr/share/pki/rpm-gpg/RPM-GPG-KEY-fedora-$release-primary
    [[ -r $key ]] || die "the image has no $key to verify mutter-devkit with"
    rpmkeys --import "$key"
}

prepare() {
    local shell_vr mutter_vr devkit
    shell_vr=$(installed_vr gnome-shell)
    [[ $shell_vr == "$(input shell_vr)" ]] ||
        die "the VM runs gnome-shell $shell_vr, the fetched inputs are for $(input shell_vr): run shell-dev.sh fetch while the VM runs, or update the VM (desktop-vm.sh update)"
    mutter_vr=$(installed_vr mutter)
    [[ $mutter_vr == "$(input mutter_vr)" ]] ||
        die "the VM runs mutter $mutter_vr, but mutter-devkit is $(input mutter_vr): run shell-dev.sh fetch while the VM runs"
    if ! usr_is_writable; then
        log "bootc usroverlay: /usr is writable until the next reboot, which drops mutter-devkit again"
        bootc usroverlay >&2
        usr_is_writable || die "/usr is still read-only after bootc usroverlay"
    fi
    devkit=$ROOT/inputs/rpms/$(input devkit_rpm)
    if [[ $(installed_vr mutter-devkit) != "$mutter_vr" ]]; then
        log "installing $(basename -- "$devkit") into the transient /usr"
        trust_fedora_key
        rpm -U --oldpackage --replacepkgs "$devkit" >&2
    fi
}

sassc_image() {
    local base=$1 image context
    [[ $base =~ ^registry\.fedoraproject\.org/[a-z0-9._-]+(:[A-Za-z0-9._-]+)?@sha256:([0-9a-f]{64})$ ]] ||
        die "BASE must be a digest-pinned registry.fedoraproject.org image, got '$base'"
    image=$SASSC_REPO:${BASH_REMATCH[2]:0:12}
    if ! podman image exists "$image"; then
        log "building $image: sassc on $base (once per base digest; needs the network)"
        context=$(mktemp -d)
        printf 'FROM %s\nRUN dnf -y install sassc && dnf clean all\n' "$base" >"$context/Containerfile"
        podman build --quiet -t "$image" "$context" >&2
        rm -rf -- "$context"
    fi
    printf '%s\n' "$image"
}

# Every sheet compiles before any replaces its predecessor, so a sassc error keeps the last good set.
compile() {
    local base=$1 image
    image=$(sassc_image "$base")
    [[ -d $ROOT/inputs/tree/data/theme && -d $ROOT/src/data/theme ]] ||
        die "no SCSS sources in $ROOT (shell-dev.sh pushes them)"
    install -d -m 0755 "$ROOT/theme"
    # shellcheck disable=SC2016 # expanded by the container's shell
    podman run --rm --network=none --security-opt label=disable \
        -v "$ROOT/inputs/tree/data/theme:/upstream:ro" \
        -v "$ROOT/src/data/theme:/apex:ro" \
        -v "$ROOT/theme:/out" \
        "$image" sh -ec '
            for variant; do
                sassc -M -t compact -I /apex "/upstream/gnome-shell-$variant.scss" "/out/.gnome-shell-$variant.css"
            done
            for variant; do
                chmod 0644 "/out/.gnome-shell-$variant.css"
                mv -f "/out/.gnome-shell-$variant.css" "/out/gnome-shell-$variant.css"
            done' sh "${THEME_VARIANTS[@]}"
}

gnome_session_users() {
    local id
    loginctl list-sessions --no-legend | awk '{print $1}' | while read -r id; do
        [[ $(loginctl show-session "$id" --property=Type --value) == wayland ]] || continue
        [[ $(loginctl show-session "$id" --property=Class --value) == user ]] || continue
        loginctl show-session "$id" --property=Name --value
    done | sort -u
}

resolve_session_user() {
    local users
    mapfile -t users < <(gnome_session_users)
    case ${#users[@]} in
        1) SESSION_USER=${users[0]} ;;
        0) die "nobody is logged in to GNOME in the VM; log in in the VM window first" ;;
        *) die "several users are logged in to GNOME (${users[*]}); log out all but one" ;;
    esac
    SESSION_UID=$(id -u "$SESSION_USER")
}

as_session_user() {
    setpriv --reuid="$SESSION_UID" --regid="$(id -g "$SESSION_USER")" --init-groups --reset-env \
        env XDG_RUNTIME_DIR="/run/user/$SESSION_UID" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$SESSION_UID/bus" "$@"
}

bus_socket() { printf '/run/user/%s/apex-shell-dev.bus\n' "$SESSION_UID"; }

# dbus-broker activates via the session's systemd, which never joins this bus (a 25 s stall each),
# and forwards UpdateActivationEnvironment to it, pointing the session's WAYLAND_DISPLAY at the nested shell.
write_bus_config() {
    cat >"$BUS_CONFIG" <<'EOF'
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <policy context="default">
    <allow send_destination="*"/>
    <allow receive_sender="*"/>
    <allow own="*"/>
    <deny send_destination="org.freedesktop.DBus" send_interface="org.freedesktop.DBus"
          send_member="UpdateActivationEnvironment"/>
  </policy>
</busconfig>
EOF
    chmod 0644 "$BUS_CONFIG"
}

nested_is_active() { as_session_user systemctl --user --quiet is-active "$UNIT"; }

nested_call() {
    local bus
    bus=$(bus_socket)
    [[ -S $bus ]] || die "the nested shell is not running (shell-dev.sh)"
    as_session_user gdbus call --address "unix:path=$bus" --dest "$1" --object-path "$2" --method "$3" "${@:4}"
}

eval_js() {
    local reply
    reply=$(nested_call org.gnome.Shell /org/gnome/Shell org.gnome.Shell.Eval "$(gvariant_string "$1")") || return 1
    printf '%s\n' "$reply"
    [[ $reply == "(true, "* ]]
}

stop_nested() {
    if nested_is_active; then as_session_user systemctl --user stop "$UNIT"; fi
    rm -f -- "$(bus_socket)"
}

start_nested() {
    stop_nested
    local manager_environment
    manager_environment=$(as_session_user systemctl --user show-environment) ||
        die "cannot reach the user manager of $SESSION_USER"
    grep -q '^WAYLAND_DISPLAY=' <<<"$manager_environment" ||
        die "the user manager of $SESSION_USER has no WAYLAND_DISPLAY; log in to GNOME in the VM window"
    local tool
    for tool in systemd-socket-activate dbus-broker-launch; do
        command -v "$tool" >/dev/null || die "$tool is not installed in the VM; the nested shell's bus needs it"
    done
    [[ -n $(installed_vr mutter-devkit) ]] || die "mutter-devkit is not installed (shell-dev.sh prepares it)"
    [[ -s $ROOT/theme/gnome-shell-light.css ]] || die "no compiled sheets yet (shell-dev.sh compiles them)"
    write_bus_config
    local started
    started=$(now_ms)
    # A stop signals only the shell, so its shutdown handlers (the layer's too) run while its bus is still up.
    as_session_user systemd-run --user --unit="$UNIT" --collect --quiet --property=KillMode=mixed \
        --setenv=G_RESOURCE_OVERLAYS="$(overlays "$ROOT")" \
        sh -c "$NESTED_SHELL_SCRIPT" sh "$(bus_socket)" "$BUS_CONFIG" "${SHELL_ARGS[@]}"
    until eval_js true >/dev/null 2>&1; do
        if ! nested_is_active; then
            journalctl --no-pager -n 20 -o cat "_SYSTEMD_USER_UNIT=$UNIT" >&2 || true
            die "the nested shell exited during start (its log is above)"
        fi
        (($(now_ms) - started < READY_TIMEOUT_SECONDS * 1000)) ||
            die "the nested shell did not answer on its bus within $READY_TIMEOUT_SECONDS s"
        sleep 0.2
    done
    log "nested shell of $SESSION_USER ready in $(seconds_since "$started") s"
}

reload_theme() {
    eval_js 'Main.loadTheme()' >/dev/null || die "Main.loadTheme() failed in the nested shell"
}

screenshot() {
    local dir=/run/user/$SESSION_UID/apex-shell-dev reply
    as_session_user mkdir -p "$dir"
    rm -f -- "$dir/screenshot.png"
    reply=$(nested_call org.gnome.Shell.Screenshot /org/gnome/Shell/Screenshot \
        org.gnome.Shell.Screenshot.Screenshot false false "$(gvariant_string "$dir/screenshot.png")") || true
    [[ $reply == "(true, "* && -s $dir/screenshot.png ]] || die "the nested shell took no screenshot: $reply"
    cat -- "$dir/screenshot.png"
}

main() {
    local cmd=${1:-}
    shift || true
    case $cmd in
        help | -h | --help) usage; return ;;
    esac
    [[ $(id -u) -eq 0 ]] || die "run it as root in the desktop VM, as shell-dev.sh does"
    case $cmd in
        receive) receive "$@" ;;
        prepare) prepare ;;
        compile) (($# == 1)) || die "usage: compile BASE"; compile "$1" ;;
        start) resolve_session_user; start_nested ;;
        stop)
            if [[ $(gnome_session_users | wc -l) == 1 ]]; then
                resolve_session_user
                stop_nested
            fi ;;
        reload) resolve_session_user; reload_theme ;;
        eval) (($# == 1)) || die "usage: eval JS"; resolve_session_user; eval_js "$1" ;;
        screenshot) resolve_session_user; screenshot ;;
        log) exec journalctl --no-pager -f -n 0 -o cat "_SYSTEMD_USER_UNIT=$UNIT" ;;
        *) die "unknown command '$cmd' ($0 help)" ;;
    esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
