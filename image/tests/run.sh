#!/bin/sh
set -eu

usage() {
    cat <<'EOF'
Tests of image/, as TAP. rpm, dnf5 and createrepo_c are faked; a file whose tool is
missing is skipped, or fails under APEX_IMAGE_TESTS_NO_SKIP=1.

  image/tests/run.sh                 every t-*.sh, with sh, dash and bash
  image/tests/run.sh t-keys.sh ...   the named files
EOF
}

for arg in "$@"; do
    case $arg in
        -h | --help)
            usage
            exit 0
            ;;
        -*)
            usage >&2
            exit 2
            ;;
    esac
done

dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

if [ "$#" -gt 0 ]; then
    files=$*
else
    files=$(cd "$dir" && ls t-*.sh)
fi

# The image runs the checks with sh: bash on Fedora, dash on Debian and Ubuntu.
shells='sh'
sh_path=$(readlink -f "$(command -v sh)")
for s in dash bash; do
    if p=$(command -v "$s") && [ "$(readlink -f "$p")" != "$sh_path" ]; then
        shells="$shells $s"
    fi
done

failed=''
for f in $files; do
    for shell in $shells; do
        printf '# %s (%s)\n' "$f" "$shell"
        if ! TEST_SHELL=$shell "$shell" "$dir/${f##*/}"; then
            failed="$failed $f($shell)"
        fi
    done
done

if [ -n "$failed" ]; then
    printf '# FAILED:%s\n' "$failed"
    exit 1
fi
printf '# all test files passed\n'
