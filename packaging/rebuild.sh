#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The rebuild lane (ADR 0014; ARCHITECTURE 4.1 and 4.3; packaging/README.md): rebuild a
# Fedora SRPM with the Apex inputs of packaging/pkgs/PKG/ (pkg.env, spec-edit, series,
# patches/, Source1, check.sh), store the result by content key, and record it in the
# candidate lock. It generalises packaging/libfprint/build.sh, which keeps its own
# script until roadmap S2c moves libfprint into the lane.
#
# Run in the builder VM, from the checkout (the Justfile's pkg-* recipes):
#   rebuild.sh build PKG|all   build what changed and record it in rpms.lock.next; the
#                              lane's inputs must be committed (the recipes commit a
#                              dirty host tree as a throwaway snapshot in the VM)
#   rebuild.sh key PKG         print PKG's content key (resolves the SRPM and the pin)
#   rebuild.sh prep PKG [NVR]  a git work tree in _build/pkg/PKG/tree: Fedora's %prep of
#                              NVR (default: the build the lane resolves), the series as
#                              commits (git am -3), then Source1 and the %prep changes
#   rebuild.sh export PKG [NEW.patch...]
#                              write the work tree's commits back to patches/: one per
#                              series entry, in order; NEW names extra commits, appended
#                              to series
#   rebuild.sh status          the families of rpms.lock.next and rpms.lock
#   rebuild.sh promote         rpms.lock.next becomes rpms.lock (after the image gates)
#   rebuild.sh stock PKG       the owner's choice at a hold limit: the next image takes
#                              Fedora's build of PKG's family
#
# build, key and prep run the Fedora half as root in a fresh container of
# image/Containerfile's REPOS_BASE (the digest the compose resolves with), through
# sudo podman: rebuild.sh --in-container build|key|prep PKG. Signing, the store and the
# locks stay in the VM.
#
# Environment:
#   APEX_STORE       [~/apex-store] built sets (pkgs/PKG/KEY/), rpms.lock, rpms.lock.next
#   APEX_GA_REACHED  overrides image/Containerfile's GA_REACHED (lib.sh ga_reached)
#   APEX_KEEP_WORK   1: keep the container's rpmbuild tree in _build/lane/PKG/work
#   APEX_RPM_SIGNING_ENV  [~/.config/apex/rpm-signing.env] the Apex RPM key's settings;
#                    the lane refuses to run while it exists and signing is not wired
#
# Exit status: 0 built, or unchanged (the key is already stored); 1 infrastructure error
# (nothing recorded); 2 usage or configuration error; 3 the inputs give no shippable
# build: on_fail=hold keeps the family's last good build in the lock (held),
# on_fail=degrade drops it (degraded).

set -euo pipefail

SCRIPT_PATH=$(readlink -f -- "${BASH_SOURCE[0]}")
readonly SCRIPT_PATH
# shellcheck source=SCRIPTDIR/../.github/scripts/lib.sh
. "$(dirname -- "$SCRIPT_PATH")/../.github/scripts/lib.sh"

readonly EXIT_ERROR=1 EXIT_USAGE=2 EXIT_HOLD=3
readonly KEY_SCHEMA=1
# Fedora release keys (as packaging/libfprint/build.sh and builder-vm.sh): checked
# against the key file of the container before it is imported. Source: fedoraproject.org
# /security and fedora-repos dist-git, read on 2026-09-24.
readonly FEDORA_45_KEY_FPR=4F50A6114CD5C6976A7F1179655A4B02F577861E
# Source1's member dates, so the archive is a function of the tree id alone.
readonly SOURCE1_MTIME=@946684800
# pkg.env: the keys this lane knows, and those it requires.
readonly PKG_ENV_KEYS=(source srpm on_fail family install pin mirror mirror_dev source1
    source1_paths prep_moved prep_deleted)
readonly PKG_ENV_REQUIRED=(source srpm on_fail family install)
# spec-edit placeholders, filled in from SPEC_EDIT_VALUES.
readonly SPEC_EDIT_PLACEHOLDERS=(APEX_RELEASE PIN_EVR SOURCE1)
readonly LOCK_HEADER=(
    '# apex rpms.lock 1: written by packaging/rebuild.sh (packaging/README.md, "rpms.lock")'
    '#   family NAME STATE KEY [since=UTC] [limit=UTC] [newer=NVR,...] [security=0|1|?] [reason=TEXT]'
    '#   rpm FAMILY KIND NAME NEVRA SHA256 PATH   (PATH relative to APEX_STORE)'
    '# STATE: built | held (KEY: the last good build) | stock (the owner) | degraded (on_fail=degrade)'
    '# KIND:  built (Apex-built) | mirror (Fedora-signed, unmodified)'
)
# Hold limits (ADR 0014, decision 18): a newer Fedora build that is a security update, or
# any other.
readonly HOLD_LIMIT_SECURITY='72 hours'
readonly HOLD_LIMIT_OTHER='14 days'
# The podman volume that keeps dnf's metadata between lane containers.
readonly DNF_CACHE_VOLUME=apex-lane-dnf-cache

usage_error() {
    if in_github_actions; then printf '::error::%s\n' "$*" >&2; else printf 'usage error: %s\n' "$*" >&2; fi
    exit "$EXIT_USAGE"
}

git_() { git -c safe.directory="$APEX_ROOT" -C "$APEX_ROOT" "$@"; }

# ---------------------------------------------------------------------------------------
# Parsers. Every input is read with a strict parser before anything touches the network;
# a syntax error is a configuration error (exit 2). selftest.sh covers them.

# parse_pkg_env FILE: fill the associative array CFG from KEY=VALUE lines. The file is
# never sourced. Unknown or repeated keys, a missing required key, or a value outside
# [A-Za-z0-9._/:+ -] exit 2.
declare -A CFG=()
parse_pkg_env() {
    local file=$1 line n=0 key value k known
    CFG=()
    [[ -f $file ]] || usage_error "$file not found"
    while IFS= read -r line || [[ -n $line ]]; do
        n=$((n + 1))
        [[ $line =~ ^[[:space:]]*(#.*)?$ ]] && continue
        [[ $line =~ ^([a-z0-9_]+)=(.*)$ ]] || usage_error "$file:$n: expected KEY=VALUE"
        key=${BASH_REMATCH[1]}
        value=${BASH_REMATCH[2]}
        value=${value%"${value##*[![:space:]]}"}
        known=0
        for k in "${PKG_ENV_KEYS[@]}"; do [[ $k != "$key" ]] || known=1; done
        ((known)) || usage_error "$file:$n: unknown key '$key'"
        [[ ! -v "CFG[$key]" ]] || usage_error "$file:$n: '$key' is set twice"
        [[ -n $value && $value =~ ^[A-Za-z0-9._/:+\ -]+$ ]] ||
            usage_error "$file:$n: '$key' has an empty value or a character outside [A-Za-z0-9._/:+ -]"
        CFG[$key]=$value
    done <"$file"
    for k in "${PKG_ENV_REQUIRED[@]}"; do
        [[ -v "CFG[$k]" ]] || usage_error "$file: '$k' is required"
    done
    case ${CFG[source]} in
        fedora-srpm) ;;
        copr-srpm | git) usage_error "$file: source=${CFG[source]} is reserved for roadmap S1c/S2c" ;;
        *) usage_error "$file: source must be fedora-srpm, not '${CFG[source]}'" ;;
    esac
    [[ ${CFG[on_fail]} == hold || ${CFG[on_fail]} == degrade ]] ||
        usage_error "$file: on_fail must be hold or degrade"
    [[ ${CFG[srpm]} =~ ^[A-Za-z0-9._+-]+$ && ${CFG[family]} =~ ^[A-Za-z0-9._+-]+$ ]] ||
        usage_error "$file: srpm and family are single package names"
    if [[ -v "CFG[source1]" ]]; then
        [[ -v "CFG[source1_paths]" ]] || usage_error "$file: source1 needs source1_paths"
        [[ ${CFG[source1]} != /* && ${CFG[source1]} != *..* ]] ||
            usage_error "$file: source1 is a directory of this repository"
    fi
    if [[ -v "CFG[mirror]" || -v "CFG[mirror_dev]" ]]; then
        [[ -v "CFG[pin]" ]] || usage_error "$file: mirror and mirror_dev need pin"
    fi
    local pair
    for pair in ${CFG[prep_moved]:-}; do
        [[ $pair =~ ^[^:]+:[^:]+$ ]] || usage_error "$file: prep_moved entries are FROM:TO, not '$pair'"
    done
    return 0
}

# words KEY: the space-separated words of CFG[KEY], one per line (none when unset).
words() {
    local w
    for w in ${CFG[$1]:-}; do printf '%s\n' "$w"; done
}

# parse_series FILE PATCH_DIR [--no-files]: fill PATCHES with the series entries: one
# NNNN-name.patch per line, '#' comments, no duplicates, and each file must exist in
# PATCH_DIR (unless --no-files, for export). A patch is disabled by leaving it out.
PATCHES=()
parse_series() {
    local file=$1 dir=$2 check_files=1 line seen
    [[ ${3:-} != --no-files ]] || check_files=0
    PATCHES=()
    [[ -f $file ]] || usage_error "series file $file not found"
    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%%#*}
        line=${line#"${line%%[![:space:]]*}"}
        line=${line%"${line##*[![:space:]]}"}
        [[ -n $line ]] || continue
        [[ $line =~ ^[0-9]{4}-[A-Za-z0-9._-]+\.patch$ ]] ||
            usage_error "$file: '$line' is not a NNNN-name.patch file name"
        ((!check_files)) || [[ -f $dir/$line ]] || usage_error "$file: '$line' not found in $dir"
        for seen in "${PATCHES[@]}"; do
            [[ $seen != "$line" ]] || usage_error "$file lists '$line' twice"
        done
        PATCHES+=("$line")
    done <"$file"
    ((${#PATCHES[@]} > 0)) || usage_error "$file enables no patch"
}

# spec_edit_parse FILE OUTDIR: check the spec-edit syntax and write one block per edit
# to OUTDIR (NNN.op, NNN.ere, NNN.text). The format: a directive, "after ERE" or
# "replace ERE"; the text lines, each indented with one tab; then "end". Comments and
# blank lines only between blocks. A placeholder must be one of SPEC_EDIT_PLACEHOLDERS.
spec_edit_parse() {
    local file=$1 out=$2 line n=0 state=0 block=0 text p rest
    [[ -f $file ]] || usage_error "$file not found"
    mkdir -p -- "$out"
    while IFS= read -r line || [[ -n $line ]]; do
        n=$((n + 1))
        if ((state == 0)); then
            [[ $line =~ ^[[:space:]]*(#.*)?$ ]] && continue
            [[ $line =~ ^(after|replace)\ (.+)$ ]] ||
                usage_error "$file:$n: expected 'after ERE' or 'replace ERE'"
            block=$((block + 1))
            printf '%s\n' "${BASH_REMATCH[1]}" >"$out/$(printf '%03d' "$block").op"
            printf '%s\n' "${BASH_REMATCH[2]}" >"$out/$(printf '%03d' "$block").ere"
            : >"$out/$(printf '%03d' "$block").text"
            state=1
        elif [[ $line == end ]]; then
            [[ -s $out/$(printf '%03d' "$block").text ]] || usage_error "$file:$n: a block without text"
            state=0
        elif [[ $line == $'\t'* ]]; then
            text=${line#$'\t'}
            rest=$text
            for p in "${SPEC_EDIT_PLACEHOLDERS[@]}"; do rest=${rest//@"$p"@/}; done
            [[ ! $rest =~ @[A-Z0-9_]+@ ]] || usage_error "$file:$n: unknown placeholder ${BASH_REMATCH[0]}"
            printf '%s\n' "$text" >>"$out/$(printf '%03d' "$block").text"
        else
            usage_error "$file:$n: a text line starts with one tab; a block ends with 'end'"
        fi
    done <"$file"
    ((state == 0)) || usage_error "$file: the last block has no 'end'"
    ((block > 0)) || usage_error "$file has no edit"
}

# spec_edit_apply BLOCKDIR SPEC: apply the parsed blocks in order. Each ERE must match
# exactly one line of SPEC (grep -E); otherwise it prints why and returns 3, and SPEC is
# left as it was before that block. Placeholders come from SPEC_EDIT_VALUES.
declare -A SPEC_EDIT_VALUES=()
spec_edit_apply() {
    local dir=$1 spec=$2 f base op ere hits p value
    for f in "$dir"/*.op; do
        base=${f%.op}
        op=$(<"$f")
        ere=$(<"$base.ere")
        mapfile -t hits < <(grep -nE -- "$ere" "$spec" | cut -d: -f1)
        if ((${#hits[@]} != 1)); then
            printf "spec-edit: '%s %s' matches %d lines of the spec, not 1\n" "$op" "$ere" "${#hits[@]}" >&2
            return "$EXIT_HOLD"
        fi
        cp -- "$base.text" "$base.filled" || die "spec-edit: cannot copy $base.text"
        for p in "${SPEC_EDIT_PLACEHOLDERS[@]}"; do
            if grep -q "@$p@" "$base.filled"; then
                [[ -n ${SPEC_EDIT_VALUES[$p]:-} ]] || die "spec-edit: no value for @$p@"
                value=${SPEC_EDIT_VALUES[$p]}
                # Values are release strings, EVRs and file names: no sed metacharacters.
                [[ $value =~ ^[A-Za-z0-9._:~^+-]+$ ]] || die "spec-edit: unsafe value for @$p@: '$value'"
                sed -i "s|@$p@|$value|g" "$base.filled" || die "spec-edit: sed failed"
            fi
        done
        awk -v n="${hits[0]}" -v f="$base.filled" -v op="$op" '
            NR == n { if (op == "after") print; while ((getline l < f) > 0) print l; next }
            { print }' "$spec" >"$spec.new" || die "spec-edit: awk failed"
        mv -f -- "$spec.new" "$spec" || die "spec-edit: cannot replace $spec"
        log "spec-edit: $op line ${hits[0]}: $ere"
    done
}

# patch_lines SPEC LINESFILE: insert LINESFILE after the spec's last Patch line, or after
# its last Source line when it has none. Returns 3 when there is neither.
patch_lines() {
    local spec=$1 lines=$2 at
    at=$(grep -nE '^Patch[0-9]*[[:space:]]*:' "$spec" | tail -n 1 | cut -d: -f1 || true)
    [[ -n $at ]] || at=$(grep -nE '^Source[0-9]*[[:space:]]*:' "$spec" | tail -n 1 | cut -d: -f1 || true)
    if [[ -z $at ]]; then
        printf 'no Patch or Source line in the spec to add the series after\n' >&2
        return "$EXIT_HOLD"
    fi
    awk -v n="$at" -v f="$lines" 'NR == n { print; while ((getline l < f) > 0) print l; next } { print }' \
        "$spec" >"$spec.new" || die "patch lines: awk failed"
    mv -f -- "$spec.new" "$spec" || die "patch lines: cannot replace $spec"
}

# source1_member_ok MEMBER PATH...: MEMBER of the Source1 archive is allowed by the
# source1_paths entries PATH (a file, or a directory when it ends in /). A directory
# member is also allowed when it is a parent of an entry.
source1_member_ok() {
    local m=$1 p
    shift
    for p in "$@"; do
        if [[ $p == */ ]]; then
            [[ $m == "$p"* ]] && return 0
            [[ $m == */ && $p == "$m"* ]] && return 0
        else
            [[ $m == "$p" ]] && return 0
            [[ $m == */ && $p == "$m"* ]] && return 0
        fi
    done
    return 1
}

# checksig_ok KEYID: `rpmkeys --checksig -v` output on stdin has only OK signature
# lines, and one made by the key whose ID (the fingerprint's last 8 hex digits) is KEYID.
# rpm 4 prints "Header V4 RSA/SHA256 Signature, key ID f577861e: OK"; rpm 6 prints
# "Header OpenPGP V4 RSA/SHA256 signature, key fingerprint: 4f50...861e: OK".
checksig_ok() {
    local id=${1,,} line signed=0 any=0
    while IFS= read -r line; do
        [[ ${line,,} == *signature* ]] || continue
        any=1
        [[ $line == *": OK" ]] || return 1
        [[ ${line,,} != *"signature, key"*"$id"* ]] || signed=1
    done
    ((any && signed))
}

# release_for STORE_DIR STOCK_NVR BASE KEY: the release a new build of KEY gets. BASE is
# the stock release plus .apexN. A key already in the store keeps its release. Otherwise
# the first key of STOCK_NVR at that BASE gets BASE, and each later one BASE.M, M one
# above the highest stored (a pin-only Fedora update changes the key without a commit,
# and two different builds must never share one NEVRA). Builds of another stock NVR do
# not count: Fedora's next version usually restarts at release 1, and its NEVRA differs
# anyway. Reads the "# ... key=K release=R ... stock=NVR" header of every
# STORE_DIR/*/manifest.txt.
release_for() {
    local store=$1 stock=$2 base=$3 key=$4 f r stored_key top=-1 m
    for f in "$store"/*/manifest.txt; do
        [[ -f $f ]] || continue
        r=$(sed -n 's/^# .* release=\([^ ]*\).*$/\1/p' "$f" | head -n 1)
        stored_key=$(sed -n 's/^# .* key=\([^ ]*\).*$/\1/p' "$f" | head -n 1)
        if [[ $stored_key == "$key" ]]; then
            printf '%s\n' "$r"
            return 0
        fi
        [[ $(sed -n 's/^# .* stock=\([^ ]*\).*$/\1/p' "$f" | head -n 1) == "$stock" ]] || continue
        if [[ $r == "$base" ]]; then
            ((top >= 0)) || top=0
        elif [[ $r =~ ^${base//./\\.}\.([0-9]+)$ ]]; then
            m=${BASH_REMATCH[1]}
            ((10#$m <= top)) || top=$((10#$m))
        fi
    done
    if ((top < 0)); then
        printf '%s\n' "$base"
    else
        printf '%s.%d\n' "$base" $((top + 1))
    fi
}

# nevra_name NEVRA: the package name of name-epoch:version-release.arch.
nevra_name() {
    [[ $1 =~ ^(.+)-[0-9]+:[^-]+-[^-]+\.[^.]+$ ]] || return 1
    printf '%s\n' "${BASH_REMATCH[1]}"
}

# ---------------------------------------------------------------------------------------
# rpms.lock and rpms.lock.next: one record per line (LOCK_HEADER). selftest.sh covers
# these helpers.

# lock_family FILE FAMILY: the family line of FAMILY without "family NAME " (STATE KEY
# and the attributes); nothing when FILE or the family does not exist.
lock_family() {
    [[ -f $1 ]] || return 0
    awk -v f="$2" '$1 == "family" && $2 == f { sub(/^family [^ ]+ /, ""); print; exit }' "$1"
}

# lock_rpms FILE FAMILY: the rpm lines of FAMILY.
lock_rpms() {
    [[ -f $1 ]] || return 0
    awk -v f="$2" '$1 == "rpm" && $2 == f' "$1"
}

# lock_attr NAME: the value of NAME= in a family line on stdin (reason= runs to the end
# of the line).
lock_attr() {
    local line
    line=$(cat)
    if [[ $1 == reason ]]; then
        [[ $line == *" reason="* ]] && printf '%s\n' "${line#* reason=}"
        return 0
    fi
    line=${line%% reason=*}
    awk -v k="$1=" '{ for (i = 1; i <= NF; i++) if (index($i, k) == 1) { print substr($i, length(k) + 1); exit } }' <<<"$line"
}

# lock_put FILE FAMILY LINE [RPMS]: rewrite FILE with FAMILY's records replaced by
# "family FAMILY LINE" and the rpm lines in the file RPMS. Other families keep their
# records and order. The new file replaces the old one atomically.
lock_put() {
    local file=$1 family=$2 line=$3 rpms=${4:-} tmp
    tmp=$(mktemp "$file.XXXXXX")
    {
        printf '%s\n' "${LOCK_HEADER[@]}"
        if [[ -f $file ]]; then
            awk -v f="$family" '/^#/ || NF == 0 { next }
                ($1 == "family" || $1 == "rpm") && $2 == f { next } { print }' "$file"
        fi
        printf 'family %s %s\n' "$family" "$line"
        if [[ -n $rpms ]]; then cat -- "$rpms"; fi
    } >"$tmp"
    mv -f -- "$tmp" "$file"
}

# manifest_lock_rpms MANIFEST FAMILY KEYPATH INSTALL...: the rpm lock lines of a stored
# build: its built RPMs named in INSTALL, and every mirror RPM.
manifest_lock_rpms() {
    local manifest=$1 family=$2 keypath=$3 kind nevra sha file name want
    shift 3
    while read -r kind nevra sha file; do
        [[ $kind == built || $kind == mirror ]] || continue
        name=$(nevra_name "$nevra") || die "manifest $manifest: bad NEVRA '$nevra'"
        if [[ $kind == built ]]; then
            for want in "$@"; do
                if [[ $want == "$name" ]]; then
                    printf 'rpm %s built %s %s %s %s/%s\n' "$family" "$name" "$nevra" "$sha" "$keypath" "$file"
                fi
            done
        else
            printf 'rpm %s mirror %s %s %s %s/%s\n' "$family" "$name" "$nevra" "$sha" "$keypath" "$file"
        fi
    done < <(grep -v '^#' "$manifest")
}

# ---------------------------------------------------------------------------------------
# VM side.

STORE=${APEX_STORE:-$HOME/apex-store}

# load_pkg PKG: parse PKG's inputs (exit 2 on any error) and set PKG, PKG_DIR.
load_pkg() {
    PKG=$1
    [[ $PKG =~ ^[a-z0-9][a-z0-9._+-]*$ ]] || usage_error "bad package name '$PKG'"
    PKG_DIR=$APEX_ROOT/packaging/pkgs/$PKG
    [[ -f $PKG_DIR/pkg.env ]] || usage_error "no $PKG_DIR/pkg.env (packages: $(all_pkgs | paste -sd' ' -))"
    parse_pkg_env "$PKG_DIR/pkg.env"
    parse_series "$PKG_DIR/series" "$PKG_DIR/patches"
    local tmp
    tmp=$(mktemp -d)
    spec_edit_parse "$PKG_DIR/spec-edit" "$tmp"
    rm -rf -- "$tmp"
}

# all_pkgs: every package of the lane (a directory of packaging/pkgs with a pkg.env).
all_pkgs() {
    local f
    for f in "$APEX_ROOT"/packaging/pkgs/*/pkg.env; do
        [[ -f $f ]] || continue
        f=${f%/pkg.env}
        printf '%s\n' "${f##*/}"
    done
}

# lane_paths: the committed inputs of PKG that N counts and that must be clean.
lane_paths() {
    printf '%s\n' "packaging/pkgs/$PKG" packaging/rebuild.sh
    if [[ -v "CFG[source1]" ]]; then printf '%s\n' "${CFG[source1]}"; fi
}

# check_committed: the lane builds committed inputs only, from a full clone.
check_committed() {
    local -a paths
    mapfile -t paths < <(lane_paths)
    git_ rev-parse -q --verify HEAD >/dev/null || usage_error "the checkout has no commit"
    [[ $(git_ rev-parse --is-shallow-repository) == false ]] ||
        usage_error "a shallow clone cannot count .apexN; fetch the full history"
    local dirty
    dirty=$(git_ status --porcelain --untracked-files=all -- "${paths[@]}")
    [[ -z $dirty ]] || usage_error "uncommitted lane inputs (commit them, or use the just pkg-* recipes, which snapshot a dirty tree in the builder VM):"$'\n'"$dirty"
}

# stage_source1 DIR: write PKG's Source1 archive to DIR and set SOURCE1 (the file
# name) and SOURCE1_TREE. It is `git archive` of the committed tree with fixed dates,
# so its bytes follow from the tree id. Every member must match source1_paths and none
# may be a link.
stage_source1() {
    local dir=$1 m
    SOURCE1='' SOURCE1_TREE=''
    [[ -v "CFG[source1]" ]] || return 0
    # (HEAD:PATH takes everything after the colon as the path, so no ^{tree} suffix.)
    SOURCE1_TREE=$(git_ rev-parse -q --verify "HEAD:${CFG[source1]}") &&
        [[ $(git_ cat-file -t "$SOURCE1_TREE") == tree ]] ||
        usage_error "${CFG[source1]} is not a committed directory"
    SOURCE1=apex-${CFG[source1]##*/}-${SOURCE1_TREE:0:12}.tar
    git_ archive --format=tar --mtime="$SOURCE1_MTIME" -o "$dir/$SOURCE1" "$SOURCE1_TREE"
    local -a allowed
    mapfile -t allowed < <(words source1_paths)
    while IFS= read -r m; do
        source1_member_ok "$m" "${allowed[@]}" ||
            usage_error "Source1 member '$m' is outside source1_paths (${allowed[*]})"
    done < <(tar -tf "$dir/$SOURCE1")
    if tar -tvf "$dir/$SOURCE1" | grep '^[lh]' >/dev/null; then
        usage_error "Source1 contains a link; every member must be a file or a directory"
    fi
}

# release_n: N of .apexN, the number of commits that touch PKG's lane inputs.
release_n() {
    local -a paths
    mapfile -t paths < <(lane_paths)
    git_ rev-list --count HEAD -- "${paths[@]}"
}

# repos_base: image/Containerfile's REPOS_BASE, which must be a digest pin.
repos_base() {
    local ref
    ref=$(containerfile_arg REPOS_BASE)
    is_fedora_pin "$ref" || usage_error "image/Containerfile REPOS_BASE '$ref' is not a registry.fedoraproject.org digest pin"
    printf '%s\n' "$ref"
}

# run_container MODE WORKDIR [ARGS...]: rebuild.sh --in-container MODE PKG in a fresh
# REPOS_BASE container, the checkout read-only at /src, WORKDIR at /work, the package's
# store read-only at /store. dnf's metadata cache is a volume that outlives the
# container (DNF_CACHE_VOLUME); the container refreshes it first, so it only saves
# downloads. Returns the container's exit status (podman's own errors become 1).
run_container() {
    local mode=$1 work=$2 base rc=0
    shift 2
    base=$(repos_base) || return "$EXIT_USAGE"
    mkdir -p -- "$STORE/pkgs/$PKG" || return "$EXIT_ERROR"
    as_root podman run --rm --pull=missing \
        -v "$APEX_ROOT:/src:ro,z" -v "$work:/work:z" -v "$STORE/pkgs/$PKG:/store:ro,z" \
        -v "$DNF_CACHE_VOLUME:/var/cache/libdnf5" \
        -e APEX_GA_REACHED="$(ga_reached)" -e APEX_REPOS_BASE="$base" \
        -e APEX_N="${APEX_N:-}" -e APEX_SOURCE1="$SOURCE1" -e APEX_SOURCE1_TREE="$SOURCE1_TREE" \
        -e APEX_LOCKED_EVR="${LOCKED_EVR:-}" -e APEX_KEEP_WORK="${APEX_KEEP_WORK:-0}" \
        -e GITHUB_ACTIONS="${GITHUB_ACTIONS:-}" \
        "$base" /src/packaging/rebuild.sh --in-container "$mode" "$PKG" "$@" || rc=$?
    ((rc <= EXIT_HOLD)) || rc=$EXIT_ERROR
    return "$rc"
}

# own DIR: give DIR (written as root by the container) to the builder user.
own() { as_root chown -R "$(id -u):$(id -g)" -- "$1"; }

# lane_work: prepare _build/lane/PKG with in/ (Source1) and an empty out/.
lane_work() {
    WORK=$APEX_ROOT/_build/lane/$PKG
    if [[ -e $WORK ]]; then as_root rm -rf -- "$WORK"; fi
    mkdir -p -- "$WORK/in" "$WORK/out"
    stage_source1 "$WORK/in"
}

# locked_evr: the EVR of PKG's main package in rpms.lock, the last good build, with no
# epoch when it is 0 (as the container writes EVRs).
locked_evr() {
    lock_rpms "$STORE/rpms.lock" "${CFG[family]}" |
        awk -v n="${CFG[srpm]}" '$3 == "built" && $4 == n { print $5; exit }' |
        sed -E -e 's/^.+-([0-9]+:[^-]+-[^-]+)\.[^.]+$/\1/' -e 's/^0://'
}

# sign_built DIR: the plug-in point for the Apex RPM key (packaging/README.md,
# "Signing"). Until the key exists, the built RPMs stay unsigned and [apex] keeps
# gpgcheck=0. The key never enters the build container.
sign_built() {
    local conf=${APEX_RPM_SIGNING_ENV:-$HOME/.config/apex/rpm-signing.env}
    if [[ -e $conf ]]; then
        die "$conf exists, but this lane does not sign yet: add the rpmsign step of packaging/README.md (Signing) first"
    fi
    log "signing: no Apex RPM key yet; the built RPMs stay unsigned ([apex] gpgcheck=0)"
    printf '# sig=none\n' >>"$1/manifest.txt"
}

# verify_stored DIR: every file of the stored manifest DIR/manifest.txt has its sha256.
verify_stored() {
    local dir=$1 kind nevra sha file
    while read -r kind nevra sha file; do
        case $kind in built | mirror | dev | apex-srpm) ;; *) continue ;; esac
        [[ -f $dir/$file ]] || die "store: $dir/$file is missing"
        [[ $(sha256sum <"$dir/$file" | cut -d' ' -f1) == "$sha" ]] ||
            die "store: $dir/$file does not match its manifest sha256"
    done < <(grep -v '^#' "$dir/manifest.txt")
}

# record_built KEY: rpms.lock.next takes the stored build KEY for PKG's family.
record_built() {
    local key=$1 dir=$STORE/pkgs/$PKG/$1 rpms
    local -a install
    mapfile -t install < <(words install)
    rpms=$(mktemp)
    manifest_lock_rpms "$dir/manifest.txt" "${CFG[family]}" "pkgs/$PKG/$key" "${install[@]}" >"$rpms"
    local n
    n=$(awk '$3 == "built"' "$rpms" | wc -l)
    ((n == ${#install[@]})) || die "store: $key has $n of the ${#install[@]} install= packages (${install[*]})"
    lock_put "$STORE/rpms.lock.next" "${CFG[family]}" "built $key" "$rpms"
    rm -f -- "$rpms"
}

# bodhi_security NVR...: 1 when any NVR's Bodhi update is a security update, ? when one
# is not in Bodhi or the query fails (treated as security), else 0.
bodhi_security() {
    local nvr json types result=0
    for nvr in "$@"; do
        types=''
        json=$(curl -fsS --max-time 30 "https://bodhi.fedoraproject.org/updates/?builds=$nvr" 2>/dev/null) &&
            types=$(jq -r '[.updates[]?.type] | join(" ")' <<<"$json" 2>/dev/null) || types=''
        if [[ " $types " == *" security "* ]]; then
            result=1
        elif [[ -z $types && $result != 1 ]]; then
            result='?'
        fi
    done
    printf '%s\n' "$result"
}

# record_failure: the container exited 3. on_fail=hold keeps the family's last good
# build (rpms.lock) in rpms.lock.next and starts or keeps its timer; on_fail=degrade
# drops the family's RPMs. A family the owner set to stock stays stock. Exits 1 when a
# hold has no last good build: the image build must stop.
record_failure() {
    local out=$WORK/out reason now family=${CFG[family]} next=$STORE/rpms.lock.next
    reason=$(head -n 1 "$out/failed.txt" 2>/dev/null || true)
    reason=${reason:-the build failed (no reason recorded)}
    reason=$(printf '%s' "$reason" | tr -c '[:print:]' ' ')
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    mkdir -p -- "$STORE/pkgs/$PKG"
    if [[ -f $out/failed.txt ]]; then cp -- "$out/failed.txt" "$STORE/pkgs/$PKG/last-failure.txt"; fi
    if [[ ${CFG[on_fail]} == degrade ]]; then
        lock_put "$next" "$family" "degraded - since=$now reason=$reason"
        summary "### $PKG: degraded" "" "$reason" "" "The next image takes Fedora's $family."
        return 0
    fi
    local current
    current=$(lock_family "$next" "$family")
    if [[ $current == stock\ * ]]; then
        summary "### $PKG: failed, stays stock" "" "$reason" "" \
            "The owner chose Fedora's build of the $family family; the next image keeps it."
        return 0
    fi
    local good good_key gm good_stock='' good_pin=''
    good=$(lock_family "$STORE/rpms.lock" "$family")
    if [[ ! $good =~ ^(built|held)\ ([^ ]+) ]]; then
        die "$PKG: $reason. rpms.lock has no last good build of the $family family to hold, so the image build stops. Fix the series, or ship Fedora's build: rebuild.sh stock $PKG"
    fi
    good_key=${BASH_REMATCH[2]}
    gm=$STORE/pkgs/$PKG/$good_key/manifest.txt
    [[ -f $gm ]] || die "store: the last good build $good_key of $family is missing ($gm)"
    good_stock=$(sed -n 's/^# .* stock=\([^ ]*\).*$/\1/p' "$gm" | head -n 1)
    good_pin=$(sed -n 's/^# .* pin=\([^ ]*\).*$/\1/p' "$gm" | head -n 1)
    # newer: the Fedora builds of this attempt that the last good build was not made from.
    local kind nvr newer=()
    while read -r kind nvr; do
        case $kind in
            stock) [[ $nvr == "$good_stock" ]] || newer+=("$nvr") ;;
            pin) [[ $nvr == "$good_pin" ]] || newer+=("$nvr") ;;
        esac
    done < <(cat -- "$out/attempt.txt" 2>/dev/null || true)
    local newer_csv since=$now security=0 limit=''
    newer_csv=$(IFS=,; printf '%s' "${newer[*]}")
    if [[ $current == held\ * && "$(lock_attr newer <<<"$current")" == "$newer_csv" ]]; then
        since=$(lock_attr since <<<"$current")
        since=${since:-$now}
    fi
    local line="held $good_key since=$since"
    if ((${#newer[@]} > 0)); then
        security=$(bodhi_security "${newer[@]}")
        if [[ $security == 0 ]]; then
            limit=$(date -u -d "$since + $HOLD_LIMIT_OTHER" +%Y-%m-%dT%H:%M:%SZ)
        else
            limit=$(date -u -d "$since + $HOLD_LIMIT_SECURITY" +%Y-%m-%dT%H:%M:%SZ)
        fi
        line+=" limit=$limit newer=$newer_csv security=$security"
    fi
    line+=" reason=$reason"
    local rpms
    rpms=$(mktemp)
    lock_rpms "$STORE/rpms.lock" "$family" >"$rpms"
    lock_put "$next" "$family" "$line" "$rpms"
    rm -f -- "$rpms"
    local note="No newer Fedora build is waiting: the Apex inputs themselves fail, so there is no limit."
    if ((${#newer[@]} > 0)); then
        note="Newer Fedora builds: ${newer_csv//,/, } (security: $security). Limit: $limit."
        if (($(date -u +%s) >= $(date -u -d "$limit" +%s))); then
            note+=" LIMIT REACHED: rebase the series (just pkg-rebase $PKG NVR), or ship Fedora's build (just pkg-stock $PKG)."
        fi
    fi
    summary "### $PKG: held" "" "$reason" "" \
        "The next image keeps the last good build, $good_key, held since $since. $note"
}

# build_one PKG: one package through the lane. Returns 0 or 3, or exits 1 or 2. Run it
# in a subshell with errexit on (cmd_build): never as part of an || or && list, where
# bash would ignore errexit in the whole function.
build_one() {
    load_pkg "$1"
    check_committed
    local start=$SECONDS rc=0 key
    APEX_N=$(release_n)
    LOCKED_EVR=$(locked_evr)
    lane_work
    group "$PKG: Fedora's SRPM through the lane (N=$APEX_N${SOURCE1:+, Source1 $SOURCE1})"
    run_container build "$WORK" || rc=$?
    endgroup
    own "$WORK"
    case $rc in
        0) ;;
        "$EXIT_HOLD")
            record_failure
            return "$EXIT_HOLD"
            ;;
        *) exit "$rc" ;;
    esac
    if [[ -f $WORK/out/unchanged ]]; then
        key=$(<"$WORK/out/unchanged")
        verify_stored "$STORE/pkgs/$PKG/$key"
        record_built "$key"
        summary "### $PKG: unchanged" "" "The key \`$key\` is already stored; rpms.lock.next takes it."
        return 0
    fi
    key=$(<"$WORK/out/key.txt")
    [[ ! -e $STORE/pkgs/$PKG/$key ]] || die "store: $STORE/pkgs/$PKG/$key exists, but the container built it again"
    sign_built "$WORK/out"
    rm -rf -- "$STORE/pkgs/$PKG/.partial-$key"
    mv -T -- "$WORK/out" "$STORE/pkgs/$PKG/.partial-$key"
    mv -T -- "$STORE/pkgs/$PKG/.partial-$key" "$STORE/pkgs/$PKG/$key"
    verify_stored "$STORE/pkgs/$PKG/$key"
    record_built "$key"
    summary "### $PKG: built in $((SECONDS - start)) s" "" '```' \
        "$(cat "$STORE/pkgs/$PKG/$key/manifest.txt")" '```'
    return 0
}

with_store_lock() {
    mkdir -p -- "$STORE"
    exec {STORE_LOCK_FD}>"$STORE/.lock"
    flock -n "$STORE_LOCK_FD" || die "another lane run holds $STORE/.lock"
}

cmd_build() {
    (($# == 1)) || usage_error "usage: rebuild.sh build PKG|all"
    local -a pkgs
    if [[ $1 == all ]]; then
        mapfile -t pkgs < <(all_pkgs)
        ((${#pkgs[@]} > 0)) || usage_error "no package has a pkg.env under packaging/pkgs"
    else
        pkgs=("$1")
    fi
    with_store_lock
    local p rc worst=0
    for p in "${pkgs[@]}"; do
        set +e
        (
            set -e
            build_one "$p"
        )
        rc=$?
        set -e
        case $rc in
            0) ;;
            "$EXIT_HOLD") worst=$EXIT_HOLD ;;
            *) return "$rc" ;;
        esac
    done
    return "$worst"
}

cmd_key() {
    (($# == 1)) || usage_error "usage: rebuild.sh key PKG"
    load_pkg "$1"
    check_committed
    APEX_N=$(release_n)
    lane_work
    run_container key "$WORK"
}

cmd_prep() {
    (($# == 1 || $# == 2)) || usage_error "usage: rebuild.sh prep PKG [NVR]"
    load_pkg "$1"
    local nvr=${2:-} dir rc=0
    [[ -z $nvr || $nvr =~ ^${CFG[srpm]//+/\\+}-[^-]+-[^-]+$ ]] ||
        usage_error "NVR must be a build of ${CFG[srpm]}, like ${CFG[srpm]}-51.1-1.fc$APEX_FEDORA"
    dir=$APEX_ROOT/_build/pkg/$PKG
    if [[ -e $dir ]]; then as_root rm -rf -- "$dir"; fi
    mkdir -p -- "$dir/in"
    # The work tree takes the working copy's patches and Source1, committed or not; a
    # dirty Source1 tree is archived through a temporary index.
    SOURCE1='' SOURCE1_TREE=''
    if [[ -v "CFG[source1]" ]]; then
        local idx
        idx=$(mktemp -u)
        GIT_INDEX_FILE=$idx git_ read-tree HEAD
        GIT_INDEX_FILE=$idx git_ add -A -- "${CFG[source1]}"
        SOURCE1_TREE=$(GIT_INDEX_FILE=$idx git_ write-tree --prefix="${CFG[source1]}/")
        rm -f -- "$idx"
        SOURCE1=apex-${CFG[source1]##*/}-${SOURCE1_TREE:0:12}.tar
        git_ archive --format=tar --mtime="$SOURCE1_MTIME" -o "$dir/in/$SOURCE1" "$SOURCE1_TREE"
    fi
    APEX_N=0
    run_container prep "$dir" "$nvr" || rc=$?
    own "$dir"
    if [[ -d $dir/tree ]]; then
        log "work tree: $dir/tree (the series: the commits after the tag apex-base)"
        log "edit and commit (git commit --amend for a patch, a new commit for a new patch), then: just pkg-export $PKG"
    fi
    return "$rc"
}

cmd_export() {
    (($# >= 1)) || usage_error "usage: rebuild.sh export PKG [NEW.patch...]"
    load_pkg_for_export "$1"
    shift
    local tree=$APEX_ROOT/_build/pkg/$PKG/tree new p i
    [[ -d $tree/.git ]] || usage_error "no work tree $tree (just pkg-prep $PKG)"
    for new in "$@"; do
        [[ $new =~ ^[0-9]{4}-[A-Za-z0-9._-]+\.patch$ ]] || usage_error "'$new' is not a NNNN-name.patch file name"
        for p in "${PATCHES[@]}"; do [[ $p != "$new" ]] || usage_error "series already lists '$new'"; done
    done
    local -a names=("${PATCHES[@]}" "$@") commits
    [[ -z $(tree_git "$tree" status --porcelain --untracked-files=no) ]] ||
        usage_error "$tree has uncommitted changes to upstream files; commit them first"
    [[ ! -d $tree/.git/rebase-apply ]] || usage_error "$tree is in the middle of git am; finish it first"
    mapfile -t commits < <(tree_git "$tree" rev-list --reverse apex-base..HEAD)
    ((${#commits[@]} == ${#names[@]})) ||
        usage_error "$tree has ${#commits[@]} commits after apex-base, but series lists ${#PATCHES[@]} and $# new name(s) were given: one name per commit, in order"
    mkdir -p -- "$PKG_DIR/patches"
    for i in "${!commits[@]}"; do
        tree_git "$tree" format-patch -1 --stdout -N --zero-commit --no-signature "${commits[i]}" \
            >"$PKG_DIR/patches/${names[i]}"
        log "export: ${names[i]} <- $(tree_git "$tree" log -1 --format='%h %s' "${commits[i]}")"
    done
    for new in "$@"; do printf '%s\n' "$new" >>"$PKG_DIR/series"; done
}

# tree_git TREE ARGS...: git in a work tree with no user or system configuration, so
# that format-patch writes the same bytes on every machine.
tree_git() {
    local tree=$1
    shift
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -c safe.directory="$tree" -C "$tree" "$@"
}

# load_pkg_for_export PKG: as load_pkg, but series entries need no file yet.
load_pkg_for_export() {
    PKG=$1
    [[ $PKG =~ ^[a-z0-9][a-z0-9._+-]*$ ]] || usage_error "bad package name '$PKG'"
    PKG_DIR=$APEX_ROOT/packaging/pkgs/$PKG
    parse_pkg_env "$PKG_DIR/pkg.env"
    parse_series "$PKG_DIR/series" "$PKG_DIR/patches" --no-files
}

# print_lock FILE TITLE: one block per family, for status.
print_lock() {
    local file=$1 title=$2 name state key rest limit now
    printf '%s\n' "$title"
    if [[ ! -f $file ]] || ! grep -q '^family ' "$file"; then
        printf '  (no family)\n'
        return 0
    fi
    now=$(date -u +%s)
    while read -r _ name state key rest; do
        printf '  %-22s %-9s %s\n' "$name" "$state" "$key"
        if [[ -n $rest ]]; then printf '      %s\n' "$rest"; fi
        limit=$(lock_attr limit <<<"$rest")
        if [[ -n $limit ]] && ((now >= $(date -u -d "$limit" +%s))); then
            printf "      LIMIT REACHED: rebase the series, or ship Fedora's build (just pkg-stock)\n"
        fi
        lock_rpms "$file" "$name" | awk '{ printf "      %-7s %s\n", $3, $5 }'
    done < <(grep '^family ' "$file")
}

cmd_status() {
    (($# == 0)) || usage_error "usage: rebuild.sh status"
    print_lock "$STORE/rpms.lock.next" "rpms.lock.next (the next image build takes it):"
    print_lock "$STORE/rpms.lock" "rpms.lock (the last image that passed its gates):"
}

cmd_promote() {
    (($# == 0)) || usage_error "usage: rebuild.sh promote"
    with_store_lock
    [[ -f $STORE/rpms.lock.next ]] || die "no $STORE/rpms.lock.next to promote"
    local sha path
    while read -r _ _ _ _ _ sha path; do
        [[ -f $STORE/$path ]] || die "promote: $path is missing from the store"
        [[ $(sha256sum <"$STORE/$path" | cut -d' ' -f1) == "$sha" ]] || die "promote: $path does not match rpms.lock.next"
    done < <(grep '^rpm ' "$STORE/rpms.lock.next")
    cp -- "$STORE/rpms.lock.next" "$STORE/rpms.lock.tmp"
    mv -f -- "$STORE/rpms.lock.tmp" "$STORE/rpms.lock"
    log "promoted rpms.lock.next to rpms.lock"
}

cmd_stock() {
    (($# == 1)) || usage_error "usage: rebuild.sh stock PKG"
    load_pkg "$1"
    with_store_lock
    lock_put "$STORE/rpms.lock.next" "${CFG[family]}" \
        "stock - since=$(date -u +%Y-%m-%dT%H:%M:%SZ) reason=the owner chose Fedora's build"
    summary "### ${CFG[family]}: stock" "" \
        "The next image takes Fedora's build of the ${CFG[family]} family, with no Apex RPM, until a lane build succeeds again."
}

# ---------------------------------------------------------------------------------------
# Container side: rebuild.sh --in-container build|key|prep PKG, as root in REPOS_BASE.

OUT=/work/out

# fail_build REASON [LOG]: the inputs give no shippable build (exit 3). The reason and
# the log's tail go to OUT/failed.txt for the VM side.
fail_build() {
    local reason=$1 logfile=${2:-}
    mkdir -p -- "$OUT"
    {
        printf '%s\n' "$reason"
        printf 'pkg=%s stock=%s key=%s\n' "$PKG" "${STOCK_NVR:-?}" "${KEY:-?}"
        if [[ -n $logfile && -f $logfile ]]; then
            printf '\nlast 60 lines of %s:\n' "${logfile##*/}"
            tail -n 60 -- "$logfile"
        fi
    } >"$OUT/failed.txt"
    printf 'FAILED (exit 3): %s\n' "$reason" >&2
    if [[ -n $logfile && -f $logfile ]]; then tail -n 30 -- "$logfile" >&2; fi
    exit "$EXIT_HOLD"
}

# c_repos: the lane's dnf5 repository options. The compose's set (lib.sh dnf_repo_args:
# fedora, updates, and before GA the allowlisted updates-testing builds). Before GA the
# buildroot also admits every binary subpackage of the builds the allowlist already
# admits (their -devel packages, which the runtime allowlist leaves out), found by source
# RPM: no new build, only more of the reviewed ones, and only for the lane's dnf calls.
BIN_REPOS=()
SRC_REPOS=(--repo=fedora-source --repo=updates-source)
SETOPTS=(--setopt=install_weak_deps=False)
ADMITTED=''
c_repos() {
    local allow testing=0
    BIN_REPOS=(--repo=fedora --repo=updates)
    allow=$(testing_includepkgs)
    [[ $(ga_reached) == 1 || -z $allow ]] || testing=1
    # The metadata cache (DNF_CACHE_VOLUME) may be days old: fetch what changed first.
    # A mirror slower than 64 KiB/s for 30 s is dropped for the next one (dnf's default
    # threshold, 1000 B/s, once kept a run on a stalled mirror for 15 minutes).
    local -a refresh=(--repo=fedora --repo=updates --repo=fedora-source --repo=updates-source)
    ((!testing)) || refresh+=(--repo=updates-testing --repo=updates-testing-source)
    retry 3 10 dnf5 -q --refresh --setopt=minrate=65536 "${refresh[@]}" makecache >/dev/null ||
        die "cannot refresh the repository metadata"
    if ((testing)); then
        local builds all
        builds=$(retry 3 10 dnf5 -q --repo=updates-testing --setopt=updates-testing.includepkgs="$allow" \
            repoquery --available --queryformat '%{sourcerpm}\n' | sort -u) ||
            die "cannot query the allowlisted updates-testing builds"
        [[ -n $builds ]] || die "the updates-testing allowlist matches nothing in updates-testing"
        all=$(retry 3 10 dnf5 -q --repo=updates-testing repoquery --available --arch=x86_64,noarch \
            --queryformat '%{name}-%{version}-%{release} %{sourcerpm}\n') ||
            die "cannot query updates-testing"
        ADMITTED=$(awk 'NR == FNR { s[$1] = 1; next } ($2 in s) { print $1 }' \
            <(printf '%s\n' "$builds") <(printf '%s\n' "$all") | LC_ALL=C sort -u | paste -sd, -)
        [[ -n $ADMITTED ]] || die "no updates-testing package comes from the allowlisted builds"
        BIN_REPOS+=(--repo=updates-testing "--setopt=updates-testing.includepkgs=$ADMITTED")
        SRC_REPOS+=(--repo=updates-testing-source)
        log "buildroot admission: $(wc -l <<<"$builds") allowlisted builds give $(tr ',' '\n' <<<"$ADMITTED" | wc -l) packages (runtime allowlist: $(tr ',' '\n' <<<"$allow" | wc -l))"
    fi
}
dnf_bin() { dnf5 -y -q "${BIN_REPOS[@]}" "${SETOPTS[@]}" "$@"; }

# c_import_fedora_key: import the Fedora release key after checking its fingerprint.
FEDORA_KEY_ID=''
c_import_fedora_key() {
    local fedora key_file expected fpr home
    fedora=$(rpm -E '%fedora')
    key_file=/usr/share/pki/rpm-gpg/RPM-GPG-KEY-fedora-$fedora-primary
    [[ -f $key_file ]] || die "$key_file not found in the container"
    [[ $fedora == 45 ]] || die "no pinned release key fingerprint for Fedora $fedora"
    expected=$FEDORA_45_KEY_FPR
    home=$(mktemp -d)
    fpr=$(gpg --homedir "$home" --batch --quiet --show-keys --with-colons -- "$key_file" 2>/dev/null |
        awk -F: '$1 == "fpr" { print $10; exit }')
    rm -rf -- "$home"
    [[ ${fpr^^} == "${expected^^}" ]] || die "$key_file has fingerprint '$fpr', expected $expected"
    rpmkeys --import "$key_file"
    FEDORA_KEY_ID=${expected: -8}
}

# c_verify FILE: FILE carries only OK signatures, one by the Fedora release key. dnf
# checks downloads against the metadata only.
c_verify() {
    local file=$1 out
    out=$(rpmkeys --checksig -- "$file" 2>&1) || die "rpmkeys -K ${file##*/}: $out"
    [[ $out == *"signatures OK"* ]] || die "${file##*/}: signatures are not OK: $out"
    rpmkeys --checksig -v -- "$file" 2>&1 | checksig_ok "$FEDORA_KEY_ID" ||
        die "${file##*/} is not signed by the Fedora key $FEDORA_KEY_ID: $(rpmkeys --checksig -v -- "$file" 2>&1)"
}

# c_resolve [NVR]: the stock build (STOCK_*: the binary named srpm= whose source RPM is
# its own NVR) and the pin (PIN_EVR, PIN_NVR: the newest <pin>-devel).
c_resolve() {
    local want=${1:-} query arch
    arch=$(rpm -E '%_arch')
    query=$(dnf_bin repoquery --latest-limit=1 --arch="$arch,noarch" \
        --queryformat '%{name} %{epoch} %{version} %{release} %{sourcerpm}\n' "${want:-${CFG[srpm]}}")
    [[ $(wc -l <<<"$query") -eq 1 && -n $query ]] ||
        die "expected one ${want:-${CFG[srpm]}} in: ${BIN_REPOS[*]#--repo=}; repoquery returned: '$query'"
    read -r _ STOCK_EPOCH STOCK_VERSION STOCK_RELEASE STOCK_SOURCERPM <<<"$query"
    STOCK_NVR=${CFG[srpm]}-$STOCK_VERSION-$STOCK_RELEASE
    [[ $STOCK_SOURCERPM == "$STOCK_NVR.src.rpm" ]] ||
        die "${CFG[srpm]} comes from $STOCK_SOURCERPM, not $STOCK_NVR.src.rpm"
    PIN_EVR='' PIN_NVR=''
    if [[ -v "CFG[pin]" ]]; then
        local pe pv pr ps
        query=$(dnf_bin repoquery --latest-limit=1 --arch="$arch" \
            --queryformat '%{epoch} %{version} %{release} %{sourcerpm}\n' "${CFG[pin]}-devel")
        [[ $(wc -l <<<"$query") -eq 1 && -n $query ]] || die "expected one ${CFG[pin]}-devel, got '$query'"
        read -r pe pv pr ps <<<"$query"
        PIN_NVR=${CFG[pin]}-$pv-$pr
        [[ $ps == "$PIN_NVR.src.rpm" ]] || die "${CFG[pin]}-devel comes from $ps, not $PIN_NVR.src.rpm"
        PIN_EVR=$pv-$pr
        [[ $pe == 0 ]] || PIN_EVR=$pe:$PIN_EVR
    fi
    mkdir -p -- "$OUT"
    {
        printf 'stock %s\n' "$STOCK_NVR"
        if [[ -n $PIN_NVR ]]; then printf 'pin %s\n' "$PIN_NVR"; fi
    } >"$OUT/attempt.txt"
    log "stock: $STOCK_NVR (epoch $STOCK_EPOCH)${PIN_EVR:+; pin: ${CFG[pin]}-devel = $PIN_EVR}"
}

# c_mirror_nevras: the NEVRAs of the mirror= and mirror_dev= packages at the pin, as
# "kind nevra" lines; each must exist exactly once, built from the pin's source RPM.
c_mirror_nevras() {
    local kind name query arch
    arch=$(rpm -E '%_arch')
    for kind in mirror mirror_dev; do
        for name in ${CFG[$kind]:-}; do
            query=$(dnf_bin repoquery --arch="$arch,noarch" \
                --queryformat '%{name}-%{epoch}:%{version}-%{release}.%{arch} %{evr} %{sourcerpm}\n' "$name" |
                awk -v evr="$PIN_EVR" -v src="$PIN_NVR.src.rpm" '$2 == evr && $3 == src { print $1 }')
            [[ $(wc -l <<<"$query") -eq 1 && -n $query ]] ||
                die "expected one $name at ${CFG[pin]} $PIN_EVR, got: '$query'"
            printf '%s %s\n' "${kind/mirror_dev/dev}" "$query"
        done
    done
}

# c_key: the content key: the stock NVR plus a hash of every input that changes the
# output (packaging/README.md, "Content key"). The container digest is recorded in the
# manifest, not hashed: dependency drift does not warrant a rebuild.
c_key() {
    local sum p check=-
    [[ ! -f $PKG_DIR/check.sh ]] || check=$(sha256sum <"$PKG_DIR/check.sh" | cut -d' ' -f1)
    sum=$(
        {
            printf 'apex lane key %s\n' "$KEY_SCHEMA"
            printf 'pkg %s\n' "$PKG"
            printf 'script %s\n' "$(sha256sum <"$SCRIPT_PATH" | cut -d' ' -f1)"
            printf 'check %s\n' "$check"
            printf 'repos %s %s\n' "${BIN_REPOS[*]}" "${SETOPTS[*]}"
            printf 'stock %s\n' "$STOCK_NVR"
            printf 'pin %s\n' "${PIN_EVR:--}"
            printf 'pkg.env %s\n' "$(sha256sum <"$PKG_DIR/pkg.env" | cut -d' ' -f1)"
            printf 'spec-edit %s\n' "$(sha256sum <"$PKG_DIR/spec-edit" | cut -d' ' -f1)"
            for p in "${PATCHES[@]}"; do
                printf 'patch %s %s\n' "$p" "$(sha256sum <"$PKG_DIR/patches/$p" | cut -d' ' -f1)"
            done
            printf 'source1 %s\n' "${APEX_SOURCE1_TREE:--}"
            printf 'release .apex%s\n' "$APEX_N"
        } | sha256sum | cut -d' ' -f1
    )
    KEY=$STOCK_NVR-s${sum:0:12}
}

# c_srcdir TOP: the source tree %prep made: the one directory in BUILD/*-build/ (rpm
# >= 4.20), apart from SPECPARTS.
c_srcdir() {
    local -a dirs
    mapfile -t dirs < <(find "$1/BUILD" -mindepth 2 -maxdepth 2 -type d ! -name SPECPARTS -path '*-build/*')
    ((${#dirs[@]} == 1)) || return 1
    printf '%s\n' "${dirs[0]}"
}

# c_fetch_srpm DIR: download and verify the stock SRPM into DIR; set SRPM.
c_fetch_srpm() {
    local dir=$1 spec
    spec=${CFG[srpm]}-$STOCK_VERSION-$STOCK_RELEASE.$(rpm -E '%_arch')
    [[ $STOCK_EPOCH == 0 ]] || spec=${CFG[srpm]}-$STOCK_EPOCH:$STOCK_VERSION-$STOCK_RELEASE.$(rpm -E '%_arch')
    retry 3 10 dnf5 -y -q "${BIN_REPOS[@]}" "${SRC_REPOS[@]}" "${SETOPTS[@]}" \
        download --srpm --destdir="$dir" "$spec" >/dev/null || die "cannot download $STOCK_SOURCERPM"
    SRPM=$dir/$STOCK_SOURCERPM
    [[ -f $SRPM ]] || die "dnf did not download $STOCK_SOURCERPM"
    c_verify "$SRPM"
    log "$STOCK_SOURCERPM: signed by the Fedora key $FEDORA_KEY_ID"
}

# c_unpack TOP: SRPM into TOP/SOURCES, the spec into TOP/SPECS; set SPEC.
c_unpack() {
    local top=$1
    mkdir -p -- "$top"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
    (cd -- "$top/SOURCES" && rpm2cpio "$SRPM" | cpio -idm --quiet --no-absolute-filenames)
    local -a specs=("$top"/SOURCES/*.spec)
    [[ ${#specs[@]} -eq 1 && -f ${specs[0]} ]] || die "the SRPM holds ${#specs[@]} spec files"
    SPEC=$top/SPECS/${specs[0]##*/}
    mv -- "${specs[0]}" "$SPEC"
}

vercmp() { rpm -E "%{lua: print(rpm.vercmp('$1', '$2'))}"; }

# c_setup MODE PKG: parse the inputs again (exit 2), then the tools, the repositories
# and the Fedora key.
c_setup() {
    local mode=$1
    PKG=$2
    PKG_DIR=$APEX_ROOT/packaging/pkgs/$PKG
    [[ -f $PKG_DIR/pkg.env ]] || usage_error "no $PKG_DIR/pkg.env"
    ((EUID == 0)) || usage_error "--in-container runs as root in the REPOS_BASE container"
    parse_pkg_env "$PKG_DIR/pkg.env"
    parse_series "$PKG_DIR/series" "$PKG_DIR/patches"
    EDITS=$(mktemp -d)
    spec_edit_parse "$PKG_DIR/spec-edit" "$EDITS"
    [[ $mode == prep || ${APEX_N:-} =~ ^[0-9]+$ ]] || usage_error "APEX_N is not set"
    if [[ -v "CFG[source1]" ]]; then
        [[ -n ${APEX_SOURCE1:-} && -f /work/in/$APEX_SOURCE1 ]] || usage_error "Source1 is not staged in /work/in"
    fi
    group "Tools and repositories"
    c_repos
    local tools_log
    tools_log=$(mktemp)
    dnf_bin install rpm-build dnf5-plugins git-core cpio diffutils /usr/bin/gpg >"$tools_log" 2>&1 ||
        { tail -n 30 "$tools_log" >&2; die "cannot install the build tools"; }
    rm -f -- "$tools_log"
    c_import_fedora_key
    endgroup
}

c_build() {
    local t0=$SECONDS
    local -a times=()
    c_setup build "$1"
    c_resolve
    c_key
    if [[ -f /store/$KEY/manifest.txt ]]; then
        log "key $KEY is already stored: unchanged"
        printf '%s\n' "$KEY" >"$OUT/unchanged"
        return 0
    fi
    local base
    base=$STOCK_RELEASE.apex$APEX_N
    RELEASE=$(release_for /store "$STOCK_NVR" "$base" "$KEY")
    local suffix=${RELEASE#"$STOCK_RELEASE"}
    log "key $KEY; release $STOCK_VERSION-$RELEASE"
    times+=("setup-resolve $((SECONDS - t0))")

    local work
    if [[ ${APEX_KEEP_WORK:-0} == 1 ]]; then
        work=/work/work
        rm -rf -- "$work"
        mkdir -p -- "$work"
    else
        work=$(mktemp -d -t apex-lane.XXXXXX)
    fi
    local top=$work/rpmbuild logs=$OUT/logs
    mkdir -p -- "$work/dl" "$logs"

    group "Download and verify"
    local t=$SECONDS
    c_fetch_srpm "$work/dl"
    local mirrors kind nevra
    mirrors=$(c_mirror_nevras)
    if [[ -n $mirrors ]]; then
        mkdir -p -- "$work/mirror"
        # shellcheck disable=SC2046 # one NEVRA per word
        retry 3 10 dnf5 -y -q "${BIN_REPOS[@]}" "${SETOPTS[@]}" download --destdir="$work/mirror" \
            $(awk '{ print $2 }' <<<"$mirrors" | sed -E 's/-0:/-/') >/dev/null || die "cannot download the mirror RPMs"
        while read -r kind nevra; do
            local f
            f=$work/mirror/$(sed -E 's/-[0-9]+:/-/' <<<"$nevra").rpm
            [[ -f $f ]] || die "dnf did not download $nevra"
            c_verify "$f"
        done <<<"$mirrors"
        log "mirror RPMs signed by the Fedora key: $(awk '{ print $2 }' <<<"$mirrors" | paste -sd' ' -)"
    fi
    endgroup
    times+=("download $((SECONDS - t))")

    group "Unpack, release arithmetic, pristine %prep"
    t=$SECONDS
    c_unpack "$top"
    cp -- "$SPEC" "$work/stock.spec"
    local got stock_evr=$STOCK_VERSION-$STOCK_RELEASE apex_evr=$STOCK_VERSION-$RELEASE
    local dist
    dist=$(rpm -E '%{?dist}')
    [[ $dist == ".fc$(rpm -E '%fedora')" && $STOCK_RELEASE == *"$dist" ]] ||
        die "stock release $STOCK_RELEASE does not end in the container's %dist $dist"
    got=$(rpmspec -q --srpm --queryformat '%{version}-%{release}\n' --define "_topdir $top" -- "$SPEC")
    [[ $got == "$stock_evr" ]] ||
        die "Fedora's spec gives $got, Fedora built $stock_evr (is %autorelease expanded in the SRPM?)"
    [[ $(vercmp 1-1.fc45.apex1 1-1.fc45) == 1 && $(vercmp 1-2.fc45 1-1.fc45.apex1) == 1 &&
        $(vercmp 1-1.fc45.apex3.1 1-1.fc45.apex3) == 1 && $(vercmp 1-1.fc45.apex4 1-1.fc45.apex3.1) == 1 ]] ||
        die "rpm.vercmp does not order the release suffixes as expected"
    if [[ $STOCK_EPOCH != 0 ]]; then
        stock_evr=$STOCK_EPOCH:$stock_evr
        apex_evr=$STOCK_EPOCH:$apex_evr
    fi
    [[ $(vercmp "$apex_evr" "$stock_evr") == 1 ]] || die "$apex_evr does not sort above $stock_evr"
    if [[ -n ${APEX_LOCKED_EVR:-} ]] && [[ $(vercmp "$apex_evr" "$APEX_LOCKED_EVR") != 1 ]]; then
        die "$apex_evr does not sort above the locked build $APEX_LOCKED_EVR (an older commit, or Fedora withdrew a build)"
    fi
    rpmbuild --define "_topdir $top" --nodeps -bp "$SPEC" >"$logs/prep-stock.log" 2>&1 || {
        tail -n 40 "$logs/prep-stock.log" >&2
        die "Fedora's %prep fails without any Apex input: the container or the SRPM is broken"
    }
    local src
    src=$(c_srcdir "$top") || die "no single source tree under $top/BUILD after %prep"
    cp -a -- "$src" "$work/pristine"
    rm -rf -- "${top:?}/BUILD"/*
    endgroup
    times+=("pristine-prep $((SECONDS - t))")

    group "spec-edit and the series"
    grep -Eq '^%(autosetup|autopatch)([[:space:]]|$)' "$SPEC" ||
        fail_build "Fedora's spec no longer uses %autosetup or %autopatch; the Patch lines would be ignored"
    ! grep -Eq '^Patch1[0-9]{3}[[:space:]]*:' "$SPEC" ||
        fail_build "Fedora's spec already uses a Patch1NNN number, which the series needs"
    if [[ -n ${APEX_SOURCE1:-} ]]; then cp -- "/work/in/$APEX_SOURCE1" "$top/SOURCES/"; fi
    SPEC_EDIT_VALUES=([APEX_RELEASE]="$suffix" [PIN_EVR]="$PIN_EVR" [SOURCE1]="${APEX_SOURCE1:-}")
    local rc=0
    spec_edit_apply "$EDITS" "$SPEC" 2>"$work/spec-edit.err" || rc=$?
    cat "$work/spec-edit.err" >&2
    ((rc == 0)) || fail_build "$(tail -n 1 "$work/spec-edit.err")"
    local n=1000 p
    : >"$work/patch-lines"
    for p in "${PATCHES[@]}"; do
        n=$((n + 1))
        install -m 0644 -- "$PKG_DIR/patches/$p" "$top/SOURCES/apex-$p"
        printf 'Patch%d:      apex-%s\n' "$n" "$p" >>"$work/patch-lines"
    done
    patch_lines "$SPEC" "$work/patch-lines" || fail_build "no Patch or Source line in Fedora's spec"
    diff -u --label "$STOCK_NVR/${SPEC##*/}" --label "apex/${SPEC##*/}" "$work/stock.spec" "$SPEC" >"$OUT/spec.diff" || true
    cat "$OUT/spec.diff" >&2
    got=$(rpmspec -q --srpm --queryformat '%{version}-%{release}\n' --define "_topdir $top" -- "$SPEC")
    [[ $got == "$STOCK_VERSION-$RELEASE" ]] ||
        fail_build "the edited spec gives $got, not $STOCK_VERSION-$RELEASE (the Release edit)"
    if [[ -n $PIN_EVR ]]; then
        # Read into variables first: grep -q on a pipe can end the writer with SIGPIPE.
        local reqs isa
        isa=$(rpm -E '%{_isa}')
        reqs=$(rpmspec -q --buildrequires --define "_topdir $top" -- "$SPEC") || die "rpmspec --buildrequires failed"
        grep -Fxq "${CFG[pin]}-devel = $PIN_EVR" <<<"$reqs" ||
            fail_build "the edited spec does not BuildRequire ${CFG[pin]}-devel = $PIN_EVR"
        reqs=$(rpmspec -q --requires --define "_topdir $top" -- "$SPEC" 2>/dev/null) || die "rpmspec --requires failed"
        grep -Fxq "${CFG[pin]}$isa = $PIN_EVR" <<<"$reqs" ||
            fail_build "the edited spec does not Require ${CFG[pin]}$isa = $PIN_EVR"
    fi
    endgroup

    group "Build dependencies"
    t=$SECONDS
    retry 2 10 dnf5 -y -q "${BIN_REPOS[@]}" "${SETOPTS[@]}" builddep --define "_topdir $top" "$SPEC" \
        >"$logs/builddep.log" 2>&1 || { tail -n 30 "$logs/builddep.log" >&2; die "dnf5 builddep failed"; }
    if [[ -n $PIN_EVR ]]; then
        got=$(rpm -q --queryformat '%{evr}\n' "${CFG[pin]}-devel")
        [[ $got == "$PIN_EVR" ]] || die "the buildroot has ${CFG[pin]}-devel $got, not $PIN_EVR"
    fi
    endgroup
    times+=("builddep $((SECONDS - t))")

    group "Patched %prep, and the exact tree"
    t=$SECONDS
    rpmbuild --define "_topdir $top" -bp "$SPEC" >"$logs/prep-apex.log" 2>&1 ||
        fail_build "$(c_prep_culprit "$work")" "$logs/prep-apex.log"
    src=$(c_srcdir "$top") || die "no single source tree under $top/BUILD after the patched %prep"
    c_exact_tree "$src" "$work" "$top/SOURCES"
    rm -rf -- "${top:?}/BUILD"/*
    endgroup
    times+=("apex-prep $((SECONDS - t))")

    group "rpmbuild -ba $STOCK_VERSION-$RELEASE"
    t=$SECONDS
    # No --define dist and no --nocheck: the SRPM carries its own release, and Fedora's
    # %check runs.
    rpmbuild --define "_topdir $top" -ba "$SPEC" >"$logs/build.log" 2>&1 ||
        fail_build "$STOCK_NVR with the Apex inputs does not build" "$logs/build.log"
    endgroup
    times+=("rpmbuild $((SECONDS - t))")

    group "Lane checks"
    t=$SECONDS
    c_checks "$top" "$work"
    endgroup
    times+=("checks $((SECONDS - t))")

    c_outputs "$top" "$work" "$mirrors"
    times+=("total $((SECONDS - t0))")
    printf '%s\n' "${times[@]}" >"$OUT/timings.txt"
    log "timings (s): $(paste -sd' ' "$OUT/timings.txt")"
    if [[ ${APEX_KEEP_WORK:-0} != 1 ]]; then rm -rf -- "$work"; fi
}

# c_prep_culprit WORK: why the patched %prep failed, naming the first series entry that
# does not apply on its own to the pristine tree (a rebase conflict names its feature).
c_prep_culprit() {
    local work=$1 t=$1/culprit p
    rm -rf -- "$t"
    cp -a -- "$work/pristine" "$t"
    for p in "${PATCHES[@]}"; do
        if ! (cd -- "$t" && git apply -p1 -- "$PKG_DIR/patches/$p") >/dev/null 2>&1; then
            printf '%s does not apply to %s\n' "$p" "$STOCK_NVR"
            rm -rf -- "$t"
            return 0
        fi
    done
    rm -rf -- "$t"
    printf "spec-edit's %%prep lines fail on %s (the series applies)\n" "$STOCK_NVR"
}

# c_exact_tree SRC WORK SOURCES: the patched %prep tree SRC is exactly Fedora's tree plus
# the series, Source1 and the declared %prep changes (pkg.env prep_moved, prep_deleted):
# undo each on a copy, then compare with the pristine tree.
c_exact_tree() {
    local src=$1 work=$2 sources=$3 r=$2/reverted i pair from to m
    cp -a -- "$src" "$r"
    for ((i = ${#PATCHES[@]} - 1; i >= 0; i--)); do
        (cd -- "$r" && git apply -R -p1 -- "$PKG_DIR/patches/${PATCHES[i]}") ||
            fail_build "${PATCHES[i]} is not applied as written in the %prep tree"
    done
    for pair in ${CFG[prep_moved]:-}; do
        from=${pair%%:*}
        to=${pair#*:}
        [[ ! -e $r/$from ]] || fail_build "%prep did not move $from"
        [[ -f $r/$to ]] || fail_build "%prep did not move $from to $to"
        cmp -s -- "$r/$to" "$work/pristine/$from" || fail_build "$to differs from Fedora's $from"
        mv -- "$r/$to" "$r/$from"
    done
    for m in ${CFG[prep_deleted]:-}; do
        [[ ! -e $r/$m ]] || fail_build "%prep did not delete $m"
        [[ -f $work/pristine/$m ]] || fail_build "Fedora's tree has no $m to delete"
        cp -p -- "$work/pristine/$m" "$r/$m"
    done
    if [[ -n ${APEX_SOURCE1:-} ]]; then
        while IFS= read -r m; do
            [[ $m == */ ]] || rm -f -- "${r:?}/$m"
        done < <(tar -tf "$sources/$APEX_SOURCE1")
    fi
    # The directories that Source1 and the moves created, deepest first: each goes when
    # it is empty and Fedora's tree has no such directory.
    local d
    {
        if [[ -n ${APEX_SOURCE1:-} ]]; then tar -tf "$sources/$APEX_SOURCE1"; fi
        for pair in ${CFG[prep_moved]:-}; do printf '%s\n' "${pair#*:}"; done
    } | while IFS= read -r m; do
        m=${m%/}
        [[ $m == */* ]] || continue
        d=${m%/*}
        while [[ -n $d ]]; do
            printf '%s\n' "$d"
            if [[ $d == */* ]]; then d=${d%/*}; else d=''; fi
        done
    done | LC_ALL=C sort -u -r | while IFS= read -r d; do
        [[ -d $work/pristine/$d ]] || rmdir -- "$r/$d" 2>/dev/null || true
    done
    diff -r -q --no-dereference --exclude=.git -- "$work/pristine" "$r" >"$work/exact.diff" 2>&1 ||
        fail_build "the %prep tree is not Fedora's tree plus the series, Source1 and the declared %prep changes" "$work/exact.diff"
    rm -rf -- "$r"
    log "the %prep tree is exactly Fedora's plus the series, Source1 and the declared %prep changes"
}

# c_checks TOP WORK: the generic lane checks, then the package's own check.sh.
c_checks() {
    local top=$1 work=$2 f name rel ver ep
    local -a rpms install
    mapfile -t rpms < <(find "$top/RPMS" -type f -name '*.rpm' ! -name '*-debuginfo-*' ! -name '*-debugsource-*' | sort)
    ((${#rpms[@]} > 0)) || fail_build "rpmbuild produced no binary RPM"
    for f in "${rpms[@]}"; do
        read -r name ep ver rel < <(rpm -qp --queryformat '%{name} %{epochnum} %{version} %{release}\n' -- "$f")
        [[ $rel == "$RELEASE" && $ver == "$STOCK_VERSION" && $ep == "$STOCK_EPOCH" ]] ||
            fail_build "${f##*/} is $ep:$ver-$rel, not $STOCK_EPOCH:$STOCK_VERSION-$RELEASE"
    done
    mapfile -t install < <(words install)
    for name in "${install[@]}"; do
        printf '%s\n' "${rpms[@]##*/}" | grep -q "^$name-$STOCK_VERSION-$RELEASE\." ||
            fail_build "install= names $name, but the build has no such binary RPM"
    done
    if [[ -n $PIN_EVR ]]; then
        f=$(printf '%s\n' "${rpms[@]}" | grep "/${CFG[srpm]}-$STOCK_VERSION-$RELEASE\.[^.]*\.rpm$" | head -n 1 || true)
        [[ -n $f ]] || fail_build "no ${CFG[srpm]} binary RPM to check the pin on"
        local reqs
        reqs=$(rpm -qp --requires -- "$f") || die "rpm -qp --requires ${f##*/} failed"
        grep -Fxq "${CFG[pin]}$(rpm -E '%{_isa}') = $PIN_EVR" <<<"$reqs" ||
            fail_build "${f##*/} does not require ${CFG[pin]}$(rpm -E '%{_isa}') = $PIN_EVR"
    fi
    local -a srpms
    mapfile -t srpms < <(find "$top/SRPMS" -type f -name '*.src.rpm')
    ((${#srpms[@]} == 1)) || fail_build "rpmbuild produced ${#srpms[@]} source RPMs"
    [[ $(rpm -qp --queryformat '%{release}' -- "${srpms[0]}") == "$RELEASE" ]] ||
        fail_build "the Apex SRPM's release is not $RELEASE"
    log "releases: every RPM is $STOCK_VERSION-$RELEASE${PIN_EVR:+; ${CFG[srpm]} requires ${CFG[pin]}$(rpm -E '%{_isa}') = $PIN_EVR}"
    if [[ -f $PKG_DIR/check.sh ]]; then
        local dir rc=0
        dir=$(mktemp -d)
        mkdir -p -- "$dir/rpms"
        cp -- "${rpms[@]}" "$dir/rpms/"
        RPMS_DIR=$dir/rpms PRISTINE=$work/pristine SOURCE1=${APEX_SOURCE1:+/work/in/$APEX_SOURCE1} \
            CHECK_WORK=$dir/work bash "$PKG_DIR/check.sh" >"$OUT/logs/check.log" 2>&1 || rc=$?
        cat -- "$OUT/logs/check.log" >&2
        rm -rf -- "$dir"
        case $rc in
            0) ;;
            1) fail_build "check.sh: $(grep -v '^ok ' "$OUT/logs/check.log" | tail -n 1)" "$OUT/logs/check.log" ;;
            *) die "check.sh could not run its checks (exit $rc)" ;;
        esac
    fi
}

# c_outputs TOP WORK MIRRORS: the store set in OUT: the built RPMs (no debuginfo), the
# mirror and dev RPMs, the Apex SRPM, manifest.txt, key.txt.
c_outputs() {
    local top=$1 work=$2 mirrors=$3 f kind nevra p
    local -a rpms
    mapfile -t rpms < <(find "$top/RPMS" -type f -name '*.rpm' ! -name '*-debuginfo-*' ! -name '*-debugsource-*' | sort)
    nevra_of() { rpm -qp --queryformat '%{name}-%{epochnum}:%{version}-%{release}.%{arch}' -- "$1"; }
    sha_of() { sha256sum <"$1" | cut -d' ' -f1; }
    {
        printf '# apex-lane manifest 1: kind nevra sha256 file\n'
        printf '# pkg=%s family=%s key=%s release=%s n=%s stock=%s pin=%s fedora=%s ga_reached=%s base=%s\n' \
            "$PKG" "${CFG[family]}" "$KEY" "$RELEASE" "$APEX_N" "$STOCK_NVR" "${PIN_NVR:--}" \
            "$(rpm -E '%fedora')" "$(ga_reached)" "${APEX_REPOS_BASE:-?}"
        printf 'fedora-srpm %s %s %s\n' "$(rpm -qp --queryformat '%{name}-%{epochnum}:%{version}-%{release}.src' -- "$SRPM")" \
            "$(sha_of "$SRPM")" "${SRPM##*/}"
        if [[ -n ${APEX_SOURCE1:-} ]]; then
            printf 'source1 %s %s %s\n' "$APEX_SOURCE1_TREE" "$(sha_of "/work/in/$APEX_SOURCE1")" "$APEX_SOURCE1"
        fi
        for p in "${PATCHES[@]}"; do
            printf 'patch %s %s %s\n' "${p%.patch}" "$(sha_of "$PKG_DIR/patches/$p")" "$p"
        done
        for f in "${rpms[@]}"; do
            cp -- "$f" "$OUT/"
            printf 'built %s %s %s\n' "$(nevra_of "$f")" "$(sha_of "$f")" "${f##*/}"
        done
        if [[ -n $mirrors ]]; then
            while read -r kind nevra; do
                f=$work/mirror/$(sed -E 's/-[0-9]+:/-/' <<<"$nevra").rpm
                cp -- "$f" "$OUT/"
                printf '%s %s %s %s\n' "$kind" "$nevra" "$(sha_of "$f")" "${f##*/}"
            done <<<"$mirrors"
        fi
        f=$(find "$top/SRPMS" -type f -name '*.src.rpm')
        cp -- "$f" "$OUT/"
        printf 'apex-srpm %s %s %s\n' "$(rpm -qp --queryformat '%{name}-%{epochnum}:%{version}-%{release}.src' -- "$f")" \
            "$(sha_of "$f")" "${f##*/}"
    } >"$OUT/manifest.txt"
    printf '%s\n' "$KEY" >"$OUT/key.txt"
}

c_key_mode() {
    c_setup key "$1"
    c_resolve
    c_key
    printf '%s\n' "$KEY"
}

# c_prep PKG [NVR]: the patch-queue work tree in /work/tree.
c_prep() {
    c_setup prep "$1"
    local nvr=${2:-}
    c_resolve "${nvr:+$nvr.$(rpm -E '%_arch')}"
    local work top
    work=$(mktemp -d -t apex-prep.XXXXXX)
    top=$work/rpmbuild
    c_fetch_srpm "$work"
    c_unpack "$top"
    rpmbuild --define "_topdir $top" --nodeps -bp "$SPEC" >"$work/prep.log" 2>&1 || {
        tail -n 40 "$work/prep.log" >&2
        die "Fedora's %prep fails"
    }
    local src
    src=$(c_srcdir "$top") || die "no single source tree after %prep"
    rm -rf -- /work/tree
    cp -a -- "$src" /work/tree
    cd /work/tree
    local -a g=(git -c user.name='Apex lane' -c user.email=lane@localhost)
    [[ -d .git ]] || "${g[@]}" init -q
    [[ -z $("${g[@]}" status --porcelain) ]] || { "${g[@]}" add -A && "${g[@]}" commit -q -m "$STOCK_NVR %prep"; }
    "${g[@]}" tag -f apex-base >/dev/null
    printf 'nvr=%s\nbase=%s\n' "$STOCK_NVR" "$("${g[@]}" rev-parse HEAD)" >/work/tree-info
    local p
    for p in "${PATCHES[@]}"; do
        if ! "${g[@]}" am -3 --quiet -- "$PKG_DIR/patches/$p"; then
            printf '%s\n' "$p" >/work/prep-failed
            printf 'FAILED (exit 3): %s does not apply to %s. The work tree is in the middle of git am:\n' "$p" "$STOCK_NVR" >&2
            printf '  resolve it (git am --show-current-patch=diff; edit; git add; git am --continue), then just pkg-export %s\n' "$PKG" >&2
            exit "$EXIT_HOLD"
        fi
    done
    if [[ -n ${APEX_SOURCE1:-} ]]; then
        tar -xkf "/work/in/$APEX_SOURCE1" || die "Source1 collides with an upstream file"
        local pair m
        for pair in ${CFG[prep_moved]:-}; do
            mkdir -p -- "$(dirname -- "${pair#*:}")"
            mv -- "${pair%%:*}" "${pair#*:}"
            "${g[@]}" update-index --skip-worktree -- "${pair%%:*}"
        done
        for m in ${CFG[prep_deleted]:-}; do
            rm -- "$m"
            "${g[@]}" update-index --skip-worktree -- "$m"
        done
        for m in ${CFG[source1_paths]}; do printf '/%s\n' "$m" >>.git/info/exclude; done
    fi
    rm -rf -- "$work"
    log "work tree /work/tree: $STOCK_NVR, then ${PATCHES[*]}"
}

main_container() {
    local mode=${1:-}
    shift || true
    case $mode in
        build) (($# == 1)) || usage_error "usage: --in-container build PKG"; c_build "$1" ;;
        key) (($# == 1)) || usage_error "usage: --in-container key PKG"; c_key_mode "$1" ;;
        prep) (($# == 1 || $# == 2)) || usage_error "usage: --in-container prep PKG [NVR]"; c_prep "$@" ;;
        *) usage_error "unknown container mode '$mode'" ;;
    esac
}

main() {
    local cmd=${1:-}
    shift || true
    case $cmd in
        build) cmd_build "$@" ;;
        key) cmd_key "$@" ;;
        prep) cmd_prep "$@" ;;
        export) cmd_export "$@" ;;
        status) cmd_status "$@" ;;
        promote) cmd_promote "$@" ;;
        stock) cmd_stock "$@" ;;
        --in-container) main_container "$@" ;;
        -h | --help) awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' "$SCRIPT_PATH" ;;
        *) usage ;;
    esac
}

# selftest.sh sources this file to test its parsers; only a direct run starts main.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
