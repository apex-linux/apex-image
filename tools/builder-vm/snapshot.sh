#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Guest side, in the builder VM's checkout (~/apex-fedora): commit a dirty checkout as a
# throwaway snapshot, so that the tools that build from git HEAD (rpms.sh, image.sh,
# packaging/rebuild.sh) see the host's working tree. The checkout is an rsync copy whose
# .git is independent of the host repository, so the snapshot never leaves the VM: the
# next `builder-vm.sh sync` replaces this .git with the host's.
#
#   snapshot.sh [CMD [ARGS...]]   snapshot when needed, then run CMD in the checkout
#
# build-image.sh runs it first; the Justfile's pkg-* recipes run the lane through it.
# It refuses to run anywhere but the builder VM's checkout, as the builder user.
set -euo pipefail

checkout=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
if [[ $(id -un) != builder || $checkout != "$HOME/apex-fedora" ]]; then
    echo "snapshot.sh: only for the builder VM's checkout ~builder/apex-fedora (this is $checkout, user $(id -un))" >&2
    exit 2
fi
cd -- "$checkout"
if ! git rev-parse -q --verify HEAD >/dev/null || [[ -n $(git status --porcelain) ]]; then
    git add -A
    git -c user.name='Apex builder VM' -c user.email='builder-vm@localhost' \
        commit -q --no-verify -m 'builder-vm snapshot of the host working tree (local only, never pushed)'
    echo "snapshot commit $(git rev-parse --short=12 HEAD) of the host working tree (VM copy only)" >&2
fi
if (($#)); then
    exec "$@"
fi
