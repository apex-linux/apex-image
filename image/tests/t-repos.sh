#!/bin/sh
# The Containerfile's repos stage, run as written: its RUN script is taken from
# image/Containerfile and executed in a bubblewrap sandbox whose /etc/yum.repos.d,
# /apex and /run/apex-packages are test fixtures, with fake dnf5, rpm and createrepo_c
# (image/tests/fake). Needs bwrap with unprivileged user namespaces and overlayfs.
. "$(dirname -- "$0")/lib.sh"

command -v bwrap >/dev/null 2>&1 || skip_all "bwrap not found"
command -v python3 >/dev/null 2>&1 || skip_all "python3 not found"
if ! bwrap --overlay-src /usr --tmp-overlay /usr --symlink usr/bin /bin --symlink usr/lib /lib \
    --symlink usr/lib64 /lib64 --proc /proc --dev /dev /usr/bin/true 2>/dev/null; then
    skip_all "bwrap cannot create a sandbox here (user namespaces or overlayfs disabled)"
fi

# --- The stage's RUN script --------------------------------------------------------
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

list() { sed -e 's/#.*//' -e 's/[[:space:]]//g' -e '/^$/d' "$@"; }

# nvr_rows ALLOWLIST RELEASE_OVERRIDE: "name epoch version release arch" rows for its
# entries (epoch 1 where Fedora has it), optionally with another release.
nvr_rows() {
    list "$1" | while read -r s; do
        n=${s%-*-*} vr=${s#"${s%-*-*}"-}
        v=${vr%-*} r=${2:-${vr##*-}} e=0
        case $n in gdm | epiphany | epiphany-runtime) e=1 ;; esac
        printf '%s %s %s %s x86_64\n' "$n" "$e" "$v" "$r"
    done
}

# setup NAME: a fresh scenario: repo files, rpms/, packages/ and fake dnf5 data.
setup() {
    S=$T/$1
    mkdir -p "$S/etc/yum.repos.d" "$S/etc/alternatives" "$S/apex" "$S/dnf" "$S/packages"
    cp "$IMAGE_DIR"/packages/*.txt "$S/packages/"
    # $releasever and $basearch are dnf's variables, written literally.
    # shellcheck disable=SC2016
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
    : >"$S/apex/libfprint-1.94.10-1.fc45.apex1.x86_64.rpm"
    : >"$S/apex/libfprint-devel-1.94.10-1.fc45.apex1.x86_64.rpm"
    nvr_rows "$S/packages/updates-testing-allowlist.txt" >"$S/dnf/testing.txt"
    # Unrelated updates-testing content and an i686 build, none of it admitted.
    printf 'systemd 0 262 1.fc45 x86_64\ngnome-maps 0 51.0 1.fc45 x86_64\nglib2 0 2.90.0 1.fc45 i686\n' \
        >>"$S/dnf/testing.txt"
    # The stable repositories as on 2026-09-24: the 51~rc builds.
    nvr_rows "$S/packages/updates-testing-allowlist.txt" |
        awk '{ $3 = ($1 == "gtk4" ? "4.23.4" : "51~rc"); $4 = "2.fc45"; print }' >"$S/dnf/stable.txt"
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
        --ro-bind "$FAKE" /fake --bind "$S/dnf" /fakednf \
        --tmpfs /tmp --dir /var/cache --proc /proc --dev /dev \
        --clearenv --setenv PATH /fake:/usr/bin --setenv LC_ALL C \
        --setenv FAKE_DNF_DIR /fakednf --setenv FEDORA 45 --setenv GA_REACHED 0 \
        --setenv FEDORA_GA_DATE 2099-01-01 --setenv ALLOWLIST_GRACE_DAYS 7 \
        "$(command -v env)" "$@" "$(command -v "$SH")" -c "$(cat "$T/run.sh")"
}

REPOS=etc/yum.repos.d

# A. The committed allowlist, the update still in testing.
setup a
stage a
expect_rc "A: the committed allowlist builds" 0
expect_out "A: 38 pinned builds admitted" '^apex-gnome51 admits 38 pinned build\(s\) from updates-testing$'
expect_file "A: includepkgs pins name-version-release" '^includepkgs=adwaita-icon-theme-51\.0-1\.fc45,.*,gdm-51\.0-1\.fc45,' "$T/a/$REPOS/apex-gnome51.repo"
expect_file "A: the stanza never skips a failed download" '^skip_if_unavailable=False$' "$T/a/$REPOS/apex-gnome51.repo"
if grep -c '^skip_if_unavailable' "$T/a/$REPOS/apex-gnome51.repo" | grep -qx 1; then ok "A: skip_if_unavailable appears once"; else not_ok "A: skip_if_unavailable appears once"; fi
expect_file "A: it keeps the updates-testing metalink" '^metalink=.*repo=updates-testing-f' "$T/a/$REPOS/apex-gnome51.repo"
expect_file "A: updates-testing is disabled" '^enabled=0$' "$T/a/$REPOS/fedora-updates-testing.repo"
if grep -q '^enabled=1' "$T/a/$REPOS/fedora-updates-testing.repo"; then not_ok "A: updates-testing-debuginfo is disabled too"; else ok "A: updates-testing-debuginfo is disabled too"; fi
expect_file "A: [apex] admits only the names in apex.txt" '^includepkgs=apex,libfprint$' "$T/a/$REPOS/apex.repo"
expect_file "A: Fedora's libfprint is excluded" '^excludepkgs=libfprint$' "$T/a/$REPOS/fedora-fedora.repo"
expect_out "A: libfprint-devel from rpms/ is reported as not admitted" '^NOTE: rpms/ also has packages that are not in apex.txt; \[apex\] does not admit them: libfprint-devel$'

# B. Review finding: a failed updates-testing query must not read as "went stable".
setup b
: >"$T/b/dnf/fail-testing"
stage b
expect_rc "B: a failed updates-testing query fails the build" 1
expect_out "B: and says so" '^ERROR: cannot query apex-gnome51'
if [ -e "$T/b/$REPOS/apex-gnome51.repo" ]; then ok "B: the stanza is not silently dropped"; else not_ok "B: the stanza is not silently dropped"; fi

# C. Review finding: the update left testing but stable still has 51~rc (unpushed, or
#    the stable compose has not caught up): composing would downgrade GNOME.
setup c
: >"$T/c/dnf/testing.txt"
stage c
expect_rc "C: gone from testing, older in stable: fails" 1
expect_out "C: names the downgrade" '^ERROR: no pinned build is in updates-testing any more.*gtk4 \(4\.23\.4-2\.fc45 < 4\.24\.0-1\.fc45\)'
expect_out "C: compares an epoch-1 package with its stable epoch" ' gdm \(51~rc-2\.fc45 < 51\.0-1\.fc45\)'

# D. The update went stable: the same builds are in fedora/updates.
setup d
: >"$T/d/dnf/testing.txt"
nvr_rows "$T/d/packages/updates-testing-allowlist.txt" >"$T/d/dnf/stable.txt"
stage d
expect_rc "D: went stable: builds" 0
expect_out "D: with a warning to empty the list" '^WARNING: FEDORA-2026-48a7996f9c left updates-testing.*38 pinned packages'
if [ -e "$T/d/$REPOS/apex-gnome51.repo" ]; then not_ok "D: the stanza is dropped"; else ok "D: the stanza is dropped"; fi

# E. Stable has newer builds of everything.
setup e
: >"$T/e/dnf/testing.txt"
nvr_rows "$T/e/packages/updates-testing-allowlist.txt" 9.fc45 >"$T/e/dnf/stable.txt"
stage e
expect_rc "E: newer in stable: builds" 0

# F. One package still older in stable, one missing from stable, stable query failing.
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

# G. Review finding: an edited update (mutter rebuilt) is not admitted unreviewed.
setup g
sed -i 's/^mutter 0 51\.0 1\.fc45/mutter 0 51.0 2.fc45/' "$T/g/dnf/testing.txt"
stage g
expect_rc "G: a replaced build fails" 1
expect_out "G: names the pinned build" '^ERROR: allowlisted builds not in updates-testing.*: mutter-51\.0-1\.fc45$'

# H. includepkgs ignored (libdnf's behaviour for a list that matches nothing).
setup h
: >"$T/h/dnf/ignore-includes"
sed -i 's/ [0-9][0-9]*\.fc45 \([a-z0-9_]*\)$/ 7.fc45 \1/' "$T/h/dnf/testing.txt"
stage h
expect_rc "H: an unrestricted stanza fails" 1
expect_out "H: and says so" '^ERROR: includepkgs did not restrict apex-gnome51'

# I. Review finding: bare names are refused.
setup i
printf 'glib2\n' >>"$T/i/packages/updates-testing-allowlist.txt"
stage i
expect_rc "I: a bare package name fails" 1
expect_out "I: and says why" "^ERROR: updates-testing-allowlist.txt entry 'glib2' is not a pinned name-version-release"

# J. GA reached: no stanza, nothing queried in updates-testing.
setup j
stage j GA_REACHED=1
expect_rc "J: GA_REACHED=1 builds" 0
if [ -e "$T/j/$REPOS/apex-gnome51.repo" ]; then not_ok "J: no apex-gnome51"; else ok "J: no apex-gnome51"; fi

# K. The dated check.
setup k
stage k FEDORA_GA_DATE=2026-01-01
expect_rc "K: allowlist entries past GA + 7 days fail" 1

# L. The final check that updates-testing is off may not be skipped when dnf5 fails.
setup l
: >"$T/l/dnf/fail-repolist"
stage l
expect_rc "L: a failed repo list fails" 1

# M. Degraded libfprint: no Apex build in rpms/, stock libfprint stays visible.
setup m
rm "$T/m/apex"/libfprint*
stage m
expect_rc "M: without the Apex libfprint it builds" 0
if grep -q '^excludepkgs=libfprint' "$T/m/$REPOS/fedora-fedora.repo"; then not_ok "M: Fedora's libfprint is not excluded"; else ok "M: Fedora's libfprint is not excluded"; fi

# N. rpms/ without the apex RPM, and apex.txt without apex.
setup n
rm "$T/n/apex/apex-0.1.0-1.fc45.x86_64.rpm"
stage n
expect_rc "N: no apex RPM fails" 1
setup n2
sed -i 's/^apex$/# apex/' "$T/n2/packages/apex.txt"
stage n2
expect_rc "N: an apex.txt without apex fails" 1

done_testing
