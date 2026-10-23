#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The tools that build from git HEAD see the host's working tree through this commit. It
# never leaves the VM: the next `builder-vm.sh sync` replaces this .git with the host's.
set -euo pipefail

checkout=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
if [[ $(id -un) != builder || $checkout != "$HOME/apex-image" ]]; then
    echo "snapshot.sh: only for the builder VM's checkout ~builder/apex-image (this is $checkout, user $(id -un))" >&2
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
