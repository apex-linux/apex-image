#!/bin/sh
# The Containerfile's repos stage, its RUN script as written, in a bubblewrap sandbox
# whose /etc, /apex (rpms/) and /run/apex-packages are fixtures, with the fakes on PATH.
. "$(dirname -- "$0")/lib.sh"

command -v bwrap >/dev/null 2>&1 || skip_all "bwrap not found"
command -v python3 >/dev/null 2>&1 || skip_all "python3 not found"
if ! bwrap --overlay-src /usr --tmp-overlay /usr --symlink usr/bin /bin --symlink usr/lib /lib \
    --symlink usr/lib64 /lib64 --proc /proc --dev /dev /usr/bin/true 2>/dev/null; then
    skip_all "bwrap cannot create a sandbox here (user namespaces or overlayfs disabled)"
fi

awk '
    /^FROM .* AS repos$/ { stage = 1; next }
    stage && /^FROM / { exit }
    stage && /^RUN / { run = 1 }
    run { line = $0; more = sub(/\\$/, "", line); printf "%s", line; if (!more) exit }
' "$IMAGE_DIR/Containerfile" >"$T/run.raw"
case $(cat "$T/run.raw") in
    'RUN --mount=type=bind,source=image/packages,target=/run/apex-packages '*) ;;
    *)
        not_ok "the repos stage's RUN mounts image/packages at /run/apex-packages"
        done_testing
        exit 1
        ;;
esac
sed -e 's/^RUN[[:space:]]*//' -e ':a' -e 's/^--mount=[^[:space:]]*[[:space:]]*//' -e 'ta' \
    "$T/run.raw" >"$T/run.sh"
expect_file "the RUN script starts with set -eu" '^set -eu;' "$T/run.sh"
expect_file "[apex] verifies with the Apex RPM key, which COPY puts next to the RPMs" \
    ' apexkey=/apex/RPM-GPG-KEY-apex;' "$T/run.sh"
expect_file "and with Fedora's key" ' fedorakey=/usr/share/pki/rpm-gpg/RPM-GPG-KEY-fedora-[$]rel-primary;' "$T/run.sh"
awk '/^FROM .* AS repos$/ { stage = 1; next } stage && /^FROM / { exit } stage && /^COPY / { print }' \
    "$IMAGE_DIR/Containerfile" >"$T/copies"
printf '%s\n' 'COPY rpms/ /apex/' \
    'COPY image/system_files/usr/share/apex/keys/RPM-GPG-KEY-apex /apex/RPM-GPG-KEY-apex' >"$T/copies.want"
if cmp -s "$T/copies.want" "$T/copies"; then
    ok "the committed Apex RPM key is copied over rpms/, so the build context cannot replace it"
else
    not_ok "the committed Apex RPM key is copied over rpms/, so the build context cannot replace it" &&
        sed 's/^/#   /' "$T/copies"
fi
# The sandbox cannot add directories under the host's /usr, so Fedora's key sits at its root.
sed -i -e 's|/usr/share/pki/rpm-gpg/|/pki/|g' "$T/run.sh"

list() { sed -e 's/#.*//' -e 's/[[:space:]]//g' -e '/^$/d' "$@"; }

# The committed allowlist is empty once Fedora's stable repositories carry its builds.
pins() {
    printf '%s\n' adwaita-icon-theme-51.0-1.fc45 epiphany-51.0-2.fc45 gdm-51.0-1.fc45 \
        glib2-2.90.0-1.fc45 gtk4-4.24.0-1.fc45 mutter-51.0-1.fc45 tecla-51.0-1.fc45
}
PINS=$(pins | wc -l)

# nvr_rows ALLOWLIST [RELEASE]: fake dnf5 rows "name epoch version release arch" of its
# entries, with Fedora's epochs.
nvr_rows() {
    list "$1" | while read -r s; do
        n=${s%-*-*} vr=${s#"${s%-*-*}"-}
        v=${vr%-*} r=${2:-${vr##*-}} e=0
        case $n in gdm | epiphany | epiphany-runtime) e=1 ;; esac
        printf '%s %s %s %s x86_64\n' "$n" "$e" "$v" "$r"
    done
}

# setup NAME: the repo files, rpms/, packages/ and fake dnf5 data of a fresh scenario.
setup() {
    S=$T/$1
    mkdir -p "$S/etc/yum.repos.d" "$S/etc/alternatives" "$S/apex" "$S/dnf" "$S/packages" \
        "$S/pki"
    cp "$IMAGE_DIR"/packages/*.txt "$S/packages/"
    pins >"$S/packages/updates-testing-allowlist.txt"
    cp "$IMAGE_DIR/system_files/usr/share/apex/keys/RPM-GPG-KEY-apex" "$S/apex/"
    printf 'Fedora 45 key\n' >"$S/pki/RPM-GPG-KEY-fedora-45-primary"
    # shellcheck disable=SC2016 # $releasever and $basearch are dnf's, written literally
    for p in fedora updates; do
        {
            printf '[%s]\nname=Fedora $releasever - %s\nmetalink=https://mirrors.fedoraproject.org/metalink?repo=%s-f$releasever&arch=$basearch\nenabled=1\ncountme=1\ngpgcheck=1\nskip_if_unavailable=False\n\n' "$p" "$p" "$p"
            printf '[%s-debuginfo]\nname=debug\nenabled=0\n' "$p"
        } >"$S/etc/yum.repos.d/fedora-$p.repo"
    done
    # Pre-GA Branched: updates-testing is on by default.
    # shellcheck disable=SC2016
    {
        printf '[updates-testing]\nname=Fedora $releasever - $basearch - Test Updates\n'
        printf 'metalink=https://mirrors.fedoraproject.org/metalink?repo=updates-testing-f$releasever&arch=$basearch\n'
        printf 'enabled=1\ncountme=1\nrepo_gpgcheck=0\ntype=rpm\ngpgcheck=1\nmetadata_expire=6h\n'
        printf 'gpgkey=file:///usr/share/pki/rpm-gpg/RPM-GPG-KEY-fedora-$releasever-$basearch\n'
        printf 'skip_if_unavailable=True\n\n[updates-testing-debuginfo]\nname=debug\nenabled=1\n'
    } >"$S/etc/yum.repos.d/fedora-updates-testing.repo"
    : >"$S/apex/apex-0.1.0-1.fc45.x86_64.rpm"
    : >"$S/apex/apex-desktop-0.1.0-1.fc45.noarch.rpm"
    : >"$S/apex/libfprint-1.94.10-1.fc45.apex1.x86_64.rpm"
    : >"$S/apex/libfprint-devel-1.94.10-1.fc45.apex1.x86_64.rpm"
    for f in gnome-shell-51.0-1.fc45.apex1.x86_64 gnome-shell-common-51.0-1.fc45.apex1.noarch \
        mutter-51.0-1.fc45.x86_64 mutter-common-51.0-1.fc45.noarch; do
        : >"$S/apex/$f.rpm"
    done
    lane_lock built >"$S/apex/rpms.lock"
    nvr_rows "$S/packages/updates-testing-allowlist.txt" >"$S/dnf/testing.txt"
    # Unrelated updates-testing content and an i686 build, none of it admitted.
    printf 'systemd 0 262 1.fc45 x86_64\ngnome-maps 0 51.0 1.fc45 x86_64\nglib2 0 2.90.0 1.fc45 i686\n' \
        >>"$S/dnf/testing.txt"
    # The stable repositories still carry the 51~rc builds.
    nvr_rows "$S/packages/updates-testing-allowlist.txt" |
        awk '{ $3 = ($1 == "gtk4" ? "4.23.4" : $1 == "glib2" ? "2.89.2" : "51~rc"); $4 = "2.fc45"; print }' >"$S/dnf/stable.txt"
}

# lane_lock STATE: prints an rpms.lock whose gnome-shell family is in STATE; built and
# held families lock the four RPMs setup puts into /apex.
lane_lock() {
    sha=$(printf '%064d' 0 | tr 0 a)
    printf '# apex rpms.lock 1: written by apex-lane (packaging/README.md, "rpms.lock")\n'
    printf 'family gnome-shell %s gnome-shell-51.0-1.fc45-s0123456789ab\n' "$1"
    case $1 in
        built | held)
            for n in gnome-shell:x86_64:apex1 gnome-shell-common:noarch:apex1 mutter:x86_64: mutter-common:noarch:; do
                name=${n%%:*} rest=${n#*:}
                arch=${rest%%:*} apex=${rest#*:}
                kind=built
                [ -n "$apex" ] || kind=mirror
                vr=51.0-1.fc45${apex:+.$apex}
                printf 'rpm gnome-shell %s %s %s-0:%s.%s %s pkgs/gnome-shell/k/%s-%s.%s.rpm\n' \
                    "$kind" "$name" "$name" "$vr" "$arch" "$sha" "$name" "$vr" "$arch"
            done
            ;;
    esac
}

# stage NAME [VAR=VALUE...]: run the RUN script in scenario NAME.
stage() {
    S=$T/$1
    shift
    run bwrap --unshare-all --die-with-parent \
        --overlay-src /usr --tmp-overlay /usr \
        --symlink usr/bin /bin --symlink usr/sbin /sbin --symlink usr/lib /lib \
        --symlink usr/lib64 /lib64 \
        --bind "$S/etc" /etc --ro-bind-try /etc/alternatives /etc/alternatives \
        --bind "$S/apex" /apex --ro-bind "$S/packages" /run/apex-packages \
        --ro-bind "$S/pki" /pki \
        --ro-bind "$FAKE" /fake --bind "$S/dnf" /fakednf \
        --tmpfs /tmp --dir /var/cache --proc /proc --dev /dev \
        --clearenv --setenv PATH /fake:/usr/bin --setenv LC_ALL C \
        --setenv FAKE_DNF_DIR /fakednf --setenv FEDORA 45 --setenv GA_REACHED 0 \
        --setenv FEDORA_GA_DATE 2099-01-01 --setenv ALLOWLIST_GRACE_DAYS 7 \
        "$(command -v env)" "$@" "$(command -v "$SH")" -c "$(cat "$T/run.sh")"
}

REPOS=etc/yum.repos.d

setup a
stage a
expect_rc "A: pinned builds that only updates-testing carries build" 0
expect_out "A: every pinned build is admitted" "^apex-gnome51 admits $PINS pinned build\\(s\\) from updates-testing; fedora/updates lack $PINS of them\$"
expect_file "A: includepkgs pins name-version-release" '^includepkgs=adwaita-icon-theme-51\.0-1\.fc45,.*,gdm-51\.0-1\.fc45,' "$T/a/$REPOS/apex-gnome51.repo"
expect_file "A: the stanza never skips a failed download" '^skip_if_unavailable=False$' "$T/a/$REPOS/apex-gnome51.repo"
if grep -c '^skip_if_unavailable' "$T/a/$REPOS/apex-gnome51.repo" | grep -qx 1; then ok "A: skip_if_unavailable appears once"; else not_ok "A: skip_if_unavailable appears once"; fi
expect_file "A: it keeps the updates-testing metalink" '^metalink=.*repo=updates-testing-f' "$T/a/$REPOS/apex-gnome51.repo"
expect_file "A: updates-testing is disabled" '^enabled=0$' "$T/a/$REPOS/fedora-updates-testing.repo"
if grep -q '^enabled=1' "$T/a/$REPOS/fedora-updates-testing.repo"; then not_ok "A: updates-testing-debuginfo is disabled too"; else ok "A: updates-testing-debuginfo is disabled too"; fi
expect_file "A: [apex] admits only the names in apex.txt and rpms.lock" \
    '^includepkgs=apex,apex-desktop,gnome-shell,gnome-shell-common,libfprint,mutter,mutter-common$' "$T/a/$REPOS/apex.repo"
expect_file "A: [apex] checks signatures" '^gpgcheck=1$' "$T/a/$REPOS/apex.repo"
expect_file "A: with the Apex RPM key and Fedora's, for the mirrored mutter, both in the repository" \
    '^gpgkey=file:///repos/apex/RPM-GPG-KEY-apex file:///repos/apex/RPM-GPG-KEY-fedora-45-primary$' \
    "$T/a/$REPOS/apex.repo"
if cmp -s "$T/a/pki/RPM-GPG-KEY-fedora-45-primary" "$T/a/apex/RPM-GPG-KEY-fedora-45-primary"; then
    ok "A: Fedora's key is copied next to the RPMs"
else
    not_ok "A: Fedora's key is copied next to the RPMs"
fi
if grep -Eq '^gpgcheck=0' "$T/a/$REPOS/apex.repo"; then not_ok "A: no gpgcheck=0 in [apex]"; else ok "A: no gpgcheck=0 in [apex]"; fi
for p in fedora updates; do
    expect_file "A: $p excludes the locked names and libfprint, in one line" \
        '^excludepkgs=gnome-shell,gnome-shell-common,libfprint,mutter,mutter-common$' "$T/a/$REPOS/fedora-$p.repo"
    if [ "$(grep -c '^excludepkgs=' "$T/a/$REPOS/fedora-$p.repo")" = 1 ]; then ok "A: one excludepkgs line in $p"; else not_ok "A: one excludepkgs line in $p"; fi
done
expect_file "A: apex-gnome51 excludes them after its own check" \
    '^excludepkgs=gnome-shell,gnome-shell-common,libfprint,mutter,mutter-common$' "$T/a/$REPOS/apex-gnome51.repo"
expect_out "A: [apex] offers the locked builds" '^\[apex\] offers exactly the 4 locked build\(s\)$'
expect_out "A: the lane's families are printed" '^  family gnome-shell built gnome-shell-51\.0-1\.fc45-s0123456789ab$'
expect_out "A: libfprint-devel from rpms/ is reported as not admitted" '^NOTE: rpms/ also has packages that are not in apex.txt or rpms.lock; \[apex\] does not admit them: libfprint-devel$'

setup b
: >"$T/b/dnf/fail-testing"
stage b
expect_rc "B: a failed updates-testing query fails the build" 1
expect_out "B: and says so" '^ERROR: cannot query apex-gnome51'
if [ -e "$T/b/$REPOS/apex-gnome51.repo" ]; then ok "B: the stanza is not silently dropped"; else not_ok "B: the stanza is not silently dropped"; fi

setup c
: >"$T/c/dnf/testing.txt"
stage c
expect_rc "C: gone from testing, older in stable: fails" 1
expect_out "C: names the downgrade" '^ERROR: pinned builds are not in updates-testing, and the stable repositories carry them older.*gtk4 \(4\.23\.4-2\.fc45 < 4\.24\.0-1\.fc45\)'
expect_out "C: compares an epoch-1 package with its stable epoch" ' gdm \(51~rc-2\.fc45 < 51\.0-1\.fc45\)'

setup d
: >"$T/d/dnf/testing.txt"
nvr_rows "$T/d/packages/updates-testing-allowlist.txt" >"$T/d/dnf/stable.txt"
stage d
expect_rc "D: went stable and left updates-testing: builds" 0
expect_out "D: with a warning to drop the pins" '^WARNING: fedora/updates carry these pinned builds.*drop them from image/packages/updates-testing-allowlist.txt: adwaita-icon-theme-51\.0-1\.fc45 .* tecla-51\.0-1\.fc45$'
expect_out "D: mutter, which the lane excludes from fedora and updates, is found there too" '^WARNING: .* mutter-51\.0-1\.fc45 '
if [ -e "$T/d/$REPOS/apex-gnome51.repo" ]; then not_ok "D: the stanza is dropped"; else ok "D: the stanza is dropped"; fi

setup d2
nvr_rows "$T/d2/packages/updates-testing-allowlist.txt" >"$T/d2/dnf/stable.txt"
stage d2
expect_rc "D: went stable, still listed in updates-testing: builds" 0
expect_out "D: with the same warning" '^WARNING: fedora/updates carry these pinned builds.* gtk4-4\.24\.0-1\.fc45 '
if [ -e "$T/d2/$REPOS/apex-gnome51.repo" ]; then not_ok "D: and the stanza is dropped"; else ok "D: and the stanza is dropped"; fi

setup d3
printf 'gtk4 0 4.24.0 1.fc45 x86_64\n' >"$T/d3/dnf/testing.txt"
nvr_rows "$T/d3/packages/updates-testing-allowlist.txt" | awk '$1 == "gtk4" { $3 = "4.23.4"; $4 = "2.fc45" } { print }' >"$T/d3/dnf/stable.txt"
stage d3
expect_rc "D: one pin only in updates-testing, the rest stable: builds" 0
expect_out "D: the stanza stays for that one" '^apex-gnome51 admits 1 pinned build\(s\) from updates-testing; fedora/updates lack 1 of them$'
expect_no_out "D: which the warning leaves out" '^WARNING: .* gtk4-'
expect_out "D: and the warning names the others" '^WARNING: fedora/updates carry these pinned builds.* mutter-51\.0-1\.fc45 '

setup e
: >"$T/e/dnf/testing.txt"
nvr_rows "$T/e/packages/updates-testing-allowlist.txt" 9.fc45 >"$T/e/dnf/stable.txt"
stage e
expect_rc "E: newer in stable: builds" 0

setup f
: >"$T/f/dnf/testing.txt"
nvr_rows "$T/f/packages/updates-testing-allowlist.txt" |
    awk '$1 == "mutter" { $3 = "51~rc"; $4 = "2.fc45" } $1 != "tecla" { print }' >"$T/f/dnf/stable.txt"
stage f
expect_rc "F: partly older in stable: fails" 1
expect_out "F: names the older one" 'mutter \(51~rc-2\.fc45 < 51\.0-1\.fc45\)'
expect_out "F: names the missing one" 'tecla \(not in fedora/updates\)'
setup f2
: >"$T/f2/dnf/testing.txt"
: >"$T/f2/dnf/fail-stable"
stage f2
expect_rc "F: a failed stable query fails" 1
expect_out "F: and says so" '^ERROR: cannot query the stable repositories'

setup g
sed -i 's/^mutter 0 51\.0 1\.fc45/mutter 0 51.0 2.fc45/' "$T/g/dnf/testing.txt"
stage g
expect_rc "G: a replaced build fails" 1
expect_out "G: names the pinned package" '^ERROR: pinned builds are not in updates-testing.*: mutter \(51~rc-2\.fc45 < 51\.0-1\.fc45\)\. '

setup g2
nvr_rows "$T/g2/packages/updates-testing-allowlist.txt" | sed 's/^\(epiphany 1 51\.0\) 2\.fc45/\1 1.fc45/' >"$T/g2/dnf/stable.txt"
cp "$T/g2/dnf/stable.txt" "$T/g2/dnf/testing.txt"
stage g2
expect_rc "G: a pin Fedora unpushed, with an older build stable: fails" 1
expect_out "G: names it alone, by its stable epoch" '^ERROR: pinned builds are not in updates-testing.*: epiphany \(51\.0-1\.fc45 < 51\.0-2\.fc45\)\. '

setup h
: >"$T/h/dnf/ignore-includes"
sed -i 's/ [0-9][0-9]*\.fc45 \([a-z0-9_]*\)$/ 7.fc45 \1/' "$T/h/dnf/testing.txt"
stage h
expect_rc "H: an unrestricted stanza fails" 1
expect_out "H: and says so" '^ERROR: includepkgs did not restrict apex-gnome51'

setup i
printf 'glib2\n' >>"$T/i/packages/updates-testing-allowlist.txt"
stage i
expect_rc "I: a bare package name fails" 1
expect_out "I: and says why" "^ERROR: updates-testing-allowlist.txt entry 'glib2' is not a pinned name-version-release"

setup j
stage j GA_REACHED=1
expect_rc "J: GA_REACHED=1 builds" 0
if [ -e "$T/j/$REPOS/apex-gnome51.repo" ]; then not_ok "J: no apex-gnome51"; else ok "J: no apex-gnome51"; fi

setup k
stage k FEDORA_GA_DATE=2026-01-01
expect_rc "K: allowlist entries past GA + 7 days fail" 1
setup k2
printf '# no pins\n' >"$T/k2/packages/updates-testing-allowlist.txt"
stage k2 FEDORA_GA_DATE=2026-01-01
expect_rc "K: an empty allowlist builds, also past GA + 7 days" 0
expect_out "K: and is reported" '^updates-testing allowlist: <empty>$'
if [ -e "$T/k2/$REPOS/apex-gnome51.repo" ]; then not_ok "K: without apex-gnome51"; else ok "K: without apex-gnome51"; fi
expect_file "K: with updates-testing disabled" '^enabled=0$' "$T/k2/$REPOS/fedora-updates-testing.repo"
if grep 'repoquery' "$T/k2/dnf/log" | grep -qv 'apex-probe'; then
    not_ok "K: and no query of updates-testing or the stable repositories"
else
    ok "K: and no query of updates-testing or the stable repositories"
fi
setup k3
cp "$IMAGE_DIR/packages/updates-testing-allowlist.txt" "$T/k3/packages/"
nvr_rows "$T/k3/packages/updates-testing-allowlist.txt" >"$T/k3/dnf/testing.txt"
stage k3
expect_rc "K: the committed allowlist builds while updates-testing carries its builds" 0

setup l
: >"$T/l/dnf/fail-repolist"
stage l
expect_rc "L: a failed repo list fails" 1

setup m
rm "$T/m/apex"/libfprint*
stage m
expect_rc "M: without the Apex libfprint it builds" 0
expect_file "M: Fedora's libfprint is not excluded, the lane's names are" \
    '^excludepkgs=gnome-shell,gnome-shell-common,mutter,mutter-common$' "$T/m/$REPOS/fedora-fedora.repo"

setup n
rm "$T/n/apex/apex-0.1.0-1.fc45.x86_64.rpm"
stage n
expect_rc "N: no apex RPM fails" 1
setup n2
sed -i 's/^apex$/# apex/' "$T/n2/packages/apex.txt"
stage n2
expect_rc "N: an apex.txt without apex fails" 1

setup o
rm "$T/o/apex/rpms.lock"
stage o
expect_rc "O: rpms/ without rpms.lock fails" 1
expect_out "O: and names the lane" "^ERROR: rpms/ has no rpms.lock: image.sh context --lane-lock"
setup o2
printf 'family gnome-shell built k\n' >"$T/o2/apex/rpms.lock"
stage o2
expect_rc "O: a lock without its format line fails" 1

setup p
rm "$T/p/apex/mutter-51.0-1.fc45.x86_64.rpm"
stage p
expect_rc "P: a missing locked build fails" 1
expect_out "P: and names it" '^  < mutter mutter-0:51\.0-1\.fc45\.x86_64$'

setup q
: >"$T/q/apex/mutter-51.0-2.fc45.x86_64.rpm"
stage q
expect_rc "Q: a second build of a locked name fails" 1
expect_out "Q: and names it" '^  > mutter mutter-0:51\.0-2\.fc45\.x86_64$'

setup r
rm "$T/r/apex"/gnome-shell* "$T/r/apex"/mutter*
lane_lock stock >"$T/r/apex/rpms.lock"
stage r
expect_rc "R: a stock family builds" 0
expect_file "R: [apex] admits apex.txt only" '^includepkgs=apex,apex-desktop,libfprint$' "$T/r/$REPOS/apex.repo"
expect_file "R: fedora excludes libfprint only" '^excludepkgs=libfprint$' "$T/r/$REPOS/fedora-fedora.repo"
setup r2
rm "$T/r2/apex"/gnome-shell* "$T/r2/apex"/mutter* "$T/r2/apex"/libfprint*
lane_lock stock >"$T/r2/apex/rpms.lock"
stage r2
expect_rc "R: stock and degraded libfprint build" 0
if grep -q '^excludepkgs=' "$T/r2/$REPOS/fedora-fedora.repo"; then not_ok "R: nothing is excluded"; else ok "R: nothing is excluded"; fi

setup s
lane_lock built | sed 's/^family gnome-shell built/family gnome-shell stock/' >"$T/s/apex/rpms.lock"
stage s
expect_rc "S: rpm lines of a stock family fail" 1

setup t
lane_lock held >"$T/t/apex/rpms.lock"
stage t
expect_rc "T: a held family builds" 0
expect_file "T: with its names admitted" '^includepkgs=apex,apex-desktop,gnome-shell,gnome-shell-common,libfprint,mutter,mutter-common$' "$T/t/$REPOS/apex.repo"

setup u
rm "$T/u/apex/RPM-GPG-KEY-apex"
stage u
expect_rc "U: without the Apex RPM key it fails" 1
expect_out "U: and names it" '^ERROR: /apex/RPM-GPG-KEY-apex is missing: \[apex\] verifies its packages with it$'
setup u2
rm "$T/u2/pki/RPM-GPG-KEY-fedora-45-primary"
stage u2
expect_rc "U: without Fedora's key it fails" 1
expect_out "U: and names it" '^ERROR: /pki/RPM-GPG-KEY-fedora-45-primary is missing: \[apex\] verifies its packages with it$'

# pair_setup NAME [degraded]: scenario NAME with a kernel pair in rpms.lock, and Fedora's
# kernel in the stable repositories next to a kernel-headers that another SRPM builds.
pair_setup() {
    setup "$1"
    sha=$(printf '%064d' 0 | tr 0 a)
    uname=7.3.0-4.cachyos1.fc45.x86_64
    {
        if [ "${2:-}" = degraded ]; then
            printf 'family kernel-cachyos built kernel-cachyos-7.3.0-4.cachyos1.fc45-s0123456789ab since=2026-12-01T00:00:00Z degraded=nvidia side=kmod reason=kmod: it does not build\n'
        else
            printf 'family kernel-cachyos built kernel-cachyos-7.3.0-4.cachyos1.fc45-s0123456789ab\n'
        fi
        for n in kernel-cachyos kernel-cachyos-core kernel-cachyos-modules; do
            printf 'rpm kernel-cachyos built %s %s-0:%s %s pkgs/kernel/k/%s-%s.rpm\n' "$n" "$n" "$uname" "$sha" "$n" "$uname"
            : >"$S/apex/$n-$uname.rpm"
        done
        if [ "${2:-}" != degraded ]; then
            k=kmod-nvidia-$uname
            printf 'rpm kernel-cachyos built %s %s-0:615.78.08-1.fc45.x86_64 %s pkgs/kernel/k/%s-615.78.08-1.fc45.x86_64.rpm\n' "$k" "$k" "$sha" "$k"
            : >"$S/apex/$k-615.78.08-1.fc45.x86_64.rpm"
            printf 'rpm kernel-cachyos mirror nvidia-kmod-common nvidia-kmod-common-0:615.78.08-1.fc45.noarch %s pkgs/kernel/k/nvidia-kmod-common-615.78.08-1.fc45.noarch.rpm\n' "$sha"
            : >"$S/apex/nvidia-kmod-common-615.78.08-1.fc45.noarch.rpm"
            mkdir -p "$S/apex/pair"
            printf 'negativo17 key\n' >"$S/apex/pair/negativo17.gpg"
        fi
    } >>"$S/apex/rpms.lock"
    for n in kernel kernel-core kernel-modules kernel-modules-core; do
        printf '%s 0 7.2.9 200.fc45 x86_64 kernel-7.2.9-200.fc45.src.rpm\n' "$n"
    done >>"$S/dnf/stable.txt"
    printf 'kernel-headers 0 7.2.3 200.fc45 x86_64 kernel-headers-7.2.3-200.fc45.src.rpm\n' >>"$S/dnf/stable.txt"
}

setup v0
stage v0
expect_rc "V: without a kernel pair it builds as before" 0
expect_out "V: and says so" '^Kernel: none '
expect_file "V: and leaves none for the compose" '^none$' "$T/v0/apex/pair-mode"
if grep -q "repoquery.*kernel\*" "$T/v0/dnf/log"; then not_ok "V: and never asks for Fedora's kernel"; else ok "V: and never asks for Fedora's kernel"; fi

pair_setup v
stage v
expect_rc "V: a kernel pair builds" 0
expect_file "V: and tells the compose" '^pair$' "$T/v/apex/pair-mode"
expect_file "V: Fedora's kernel, by its SRPM, is excluded with the lane's names, kernel-headers is not" \
    '^excludepkgs=gnome-shell,gnome-shell-common,kernel,kernel-cachyos,kernel-cachyos-core,kernel-cachyos-modules,kernel-core,kernel-modules,kernel-modules-core,kmod-nvidia-7\.3\.0-4\.cachyos1\.fc45\.x86_64,libfprint,mutter,mutter-common,nvidia-kmod-common$' \
    "$T/v/$REPOS/fedora-fedora.repo"
expect_file "V: [apex] admits the pair" '^includepkgs=apex,apex-desktop,gnome-shell,gnome-shell-common,kernel-cachyos,kernel-cachyos-core,kernel-cachyos-modules,kmod-nvidia-7\.3\.0-4\.cachyos1\.fc45\.x86_64,libfprint,mutter,mutter-common,nvidia-kmod-common$' "$T/v/$REPOS/apex.repo"
expect_file "V: and checks the userspace with negativo17's key" \
    '^gpgkey=file:///repos/apex/RPM-GPG-KEY-apex file:///repos/apex/RPM-GPG-KEY-fedora-45-primary file:///repos/apex/pair/negativo17\.gpg$' "$T/v/$REPOS/apex.repo"

pair_setup v2 degraded
stage v2
expect_rc "V: a kernel without its NVIDIA set builds" 0
expect_file "V: as pair-degraded" '^pair-degraded$' "$T/v2/apex/pair-mode"
expect_file "V: Fedora's kernel is still excluded" '^excludepkgs=.*,kernel-core,' "$T/v2/$REPOS/fedora-fedora.repo"
expect_file "V: and no negativo17 key is needed" \
    '^gpgkey=file:///repos/apex/RPM-GPG-KEY-apex file:///repos/apex/RPM-GPG-KEY-fedora-45-primary$' "$T/v2/$REPOS/apex.repo"

pair_setup v3
sed -i 's/ reason=.*//; s/^\(family kernel-cachyos \)built \(kernel-cachyos-[^ ]*\)$/\1held \2 since=2026-12-01T00:00:00Z side=kmod reason=kmod: degraded=nvidia next/' "$T/v3/apex/rpms.lock"
stage v3
expect_rc "V: a held pair builds" 0
expect_file "V: as a whole pair, whatever its reason says" '^pair$' "$T/v3/apex/pair-mode"

pair_setup v4
rm "$T/v4/apex/pair/negativo17.gpg"
stage v4
expect_rc "V: a userspace without negativo17's key fails" 1
expect_out "V: and names it" '^ERROR: rpms/pair/negativo17\.gpg is missing'

pair_setup v5
: >"$T/v5/dnf/ignore-excludes"
stage v5
expect_rc "V: Fedora's kernel left after excludepkgs fails" 1
expect_out "V: and names it" "^ERROR: fedora and updates still offer Fedora's kernel after excludepkgs: kernel kernel-core kernel-modules kernel-modules-core$"

pair_setup v6
sed -i '/ kernel-[0-9.]*-200\.fc45\.src\.rpm$/d' "$T/v6/dnf/stable.txt"
stage v6
expect_rc "V: no Fedora kernel to exclude fails" 1
expect_out "V: and says so" '^ERROR: fedora and updates offer no package of the kernel SRPM to exclude$'

# The break-glass image (just image KERNEL=fedora): image.sh's own rewrite of a pair lock,
# and none of the pair's RPMs in rpms/.
pair_setup w
eval "$(sed -n '/^break_glass_lock() {$/,/^}$/p' "$REPO_ROOT/.github/scripts/image.sh")"
break_glass_lock "$T/w/apex/rpms.lock" >"$T/w/break-glass.lock"
mv "$T/w/break-glass.lock" "$T/w/apex/rpms.lock"
rm -rf "$T/w/apex"/kernel-cachyos-* "$T/w/apex"/kmod-nvidia-* "$T/w/apex"/nvidia-* "$T/w/apex/pair"
expect_file "W: the pair is the owner's stock choice in the image's lock" \
    '^family kernel-cachyos stock - reason=break-glass: ' "$T/w/apex/rpms.lock"
stage w
expect_rc "W: a break-glass image of a pair lock builds" 0
expect_file "W: on Fedora's kernel" '^none$' "$T/w/apex/pair-mode"
if grep -q "repoquery.*kernel\*" "$T/w/dnf/log"; then not_ok "W: and never asks for Fedora's kernel"; else ok "W: and never asks for Fedora's kernel"; fi
expect_file "W: excluding no kernel" '^excludepkgs=gnome-shell,gnome-shell-common,libfprint,mutter,mutter-common$' "$T/w/$REPOS/fedora-fedora.repo"
expect_file "W: and admitting none of the pair" '^includepkgs=apex,apex-desktop,gnome-shell,gnome-shell-common,libfprint,mutter,mutter-common$' "$T/w/$REPOS/apex.repo"

done_testing
