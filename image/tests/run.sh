#!/bin/sh
# Tests of image/: the checks (image/checks/*.sh), the Containerfile's repos stage, the
# overlay units and the package lists. They run on any Linux host with POSIX sh and
# python3; rpm, dnf5 and createrepo_c are faked (image/tests/fake). The repos-stage
# test needs bubblewrap (bwrap) and the overlay test systemd-analyze, udevadm and
# systemd-tmpfiles; without them those files are skipped, not failed, unless
# APEX_IMAGE_TESTS_NO_SKIP=1 (CI) turns a skip into a failure.
#
#   image/tests/run.sh             every t-*.sh, with sh, and again with dash and bash
#                                  when they are installed and are not sh itself
#   image/tests/run.sh t-keys.sh   one file
#
# Exits non-zero when any test fails. Output is TAP, one stream per file.
set -eu
dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

if [ "$#" -gt 0 ]; then
    files=$*
else
    files=$(cd "$dir" && ls t-*.sh)
fi

# sh first (the image runs the checks with sh, which is bash on Fedora and dash on
# Debian and Ubuntu), then each of dash and bash that is a different program.
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
