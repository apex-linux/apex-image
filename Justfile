# SPDX-License-Identifier: GPL-3.0-or-later
#
# Recipes never run sudo: the ones that need root print the command instead.

set shell := ["bash", "-euo", "pipefail", "-c"]

# The checkout of the recipe that just pkg-export writes into (apex-gnome; apex-kernel for the kernel).
recipes := env_var_or_default("APEX_RECIPES", "../apex-gnome")

# List the recipes.
default:
    @just --list

# apex-lane's fmt --check, clippy with warnings denied and tests, as ci.yml runs them.
check:
    cargo fmt --all --check
    cargo clippy --workspace --all-targets --locked -- -D warnings
    cargo test --workspace --locked

# Format the workspace.
fmt:
    cargo fmt --all

# Advisories, licenses, bans and sources (deny.toml); needs cargo-deny.
deny:
    cargo deny --locked check

# The image checks' tests, also run by ci.yml (files needing bwrap or systemd tools skip here without them).
image-test:
    image/tests/run.sh

# The dev loop's host side against a fake ssh, also run by ci.yml: the throwaway guard, desktop-update, shell-dev fetch.
devloop-test:
    tests/devloop/run.sh

# How to build the image; `just image KERNEL=fedora` builds the break-glass image in the VM: Fedora's kernel, degraded=nvidia, never promoted.
# `just image FEDORA=46` builds the next lane (image/fedora/46.env): G1 only, never promoted or published.
image *args:
    @if [ -z '{{ args }}' ]; then {{ just_executable() }} --justfile '{{ justfile() }}' _image-help; elif [ '{{ args }}' = KERNEL=fedora ]; then tools/builder-vm/builder-vm.sh image --kernel fedora; elif [ '{{ args }}' = FEDORA=46 ]; then APEX_FEDORA=46 tools/builder-vm/builder-vm.sh image; else echo 'usage: just image [KERNEL=fedora | FEDORA=46]' >&2; exit 2; fi

# How to build the image (it runs in the Fedora 45 builder VM, not on this host).
_image-help:
    @echo 'The image builds with rootful podman in the Fedora 45 KVM builder VM (ADR 0013): just vm-create, then just vm-image.'
    @echo 'just vm-image runs tools/builder-vm/build-image.sh in the VM, which:'
    @echo ''
    @echo '  tools/components.sh fetch        # apex-system, apex-desktop, apex-gnome and apex-kernel at components.lock'
    @echo '  eval "$(tools/components.sh env)"'
    @echo '  # each component builds its RPMs in its own checkout, as root in fedora:45, and the Apex RPM key signs them:'
    @echo '  #   $APEX_SYSTEM_SRC/.github/scripts/rpms.sh build    the apex RPM'
    @echo '  #   $APEX_DESKTOP_SRC/.github/scripts/rpms.sh build   apex-desktop'
    @echo '  #   $APEX_KERNEL_SRC/.github/scripts/libfprint.sh build   libfprint, with GA_REACHED and the updates-testing allowlist; exit 3 = degraded'
    @echo '  tools/builder-vm/lane.sh build all  # the rebuild lane (gnome-shell from apex-gnome); exit 3 = held, degraded or stock'
    @echo '  .github/scripts/image.sh context --rpms-dir _build/rpms/apex --desktop-dir _build/rpms/desktop --libfprint-dir _build/libfprint --lane-lock ~/apex-store/rpms.lock.next'
    @echo '  .github/scripts/image.sh build && .github/scripts/image.sh inspect'
    @echo '  $APEX_GNOME_SRC/tests/shots/run.sh  # G2, the headless shell, twice, with G2_IMAGE_DIR and G2_REPOS_BASE'
    @echo '  .github/scripts/qualify.sh g4-due _build/image/g4-key.txt && .github/scripts/qualify.sh local localhost/apex:build   # G4 when due'
    @echo ''
    @echo 'just publish then publishes that image once its gates passed: rechunk, push apex:<version>, cosign-sign, move apex:45.'

# Publish the last gated vm-image build (S1d): rechunk, push apex:<version>, sign with the owner's cosign key, move apex:45.
publish *flags:
    tools/builder-vm/builder-vm.sh run tools/builder-vm/publish-image.sh {{ flags }}

# The same steps against a throwaway registry and key in the builder VM; nothing is published.
publish-rehearsal:
    tools/builder-vm/builder-vm.sh run tools/builder-vm/publish-image.sh --rehearse

# How to run the KVM qualification locally (in the builder VM, with nested KVM).
qualify-local:
    @echo 'Qualification runs .github/scripts/qualify.sh in the builder VM; GitHub does not run it:'
    @echo ''
    @echo '  sudo dnf install qemu-system-x86 edk2-ovmf dosfstools btrfs-progs openssh-clients jq skopeo podman openssl'
    @echo '  test -w /dev/kvm   # nested KVM must be on (kvm_amd nested=1 on the host)'
    @echo '  .github/scripts/qualify.sh fresh ghcr.io/apex-linux/apex-testing@sha256:<digest>'
    @echo '  .github/scripts/qualify.sh all   ghcr.io/apex-linux/apex-testing@sha256:<digest>'
    @echo ''
    @echo 'The counted rollback on its own (FROM boots first; CANDIDATE is forced red through'
    @echo '/var/lib/apex/force-red, must reboot itself 3 times, and GRUB must fall back to FROM):'
    @echo ''
    @echo '  .github/scripts/qualify.sh red sha256:<from digest> sha256:<candidate digest>'
    @echo ''
    @echo 'It uses sudo for podman, losetup and mount, writes to _build/qualify (fixtures/, logs/,'
    @echo 'results.md) and needs about 60 GiB free. QUALIFY_LAYOUT=to-disk switches to the'
    @echo 'bootc install to-disk --via-loopback path.'

# ---- Fedora 45 builder VM (tools/builder-vm/README.md) --------------------------------

# Create the builder VM: download and verify Fedora Cloud 45, first boot, provision.
vm-create:
    tools/builder-vm/builder-vm.sh create

# Boot the builder VM in the background.
vm-start:
    tools/builder-vm/builder-vm.sh start

# Shut the builder VM down cleanly.
vm-stop:
    tools/builder-vm/builder-vm.sh stop

# Show whether the builder VM runs, and its disk and memory use.
vm-status:
    tools/builder-vm/builder-vm.sh status

# A shell in the builder VM (or: just vm-ssh 'CMD', run by the VM's shell).
[positional-arguments]
vm-ssh *args:
    tools/builder-vm/builder-vm.sh ssh "$@"

# Copy this checkout into the builder VM (~/apex-image).
vm-sync:
    tools/builder-vm/builder-vm.sh sync

# Build the RPMs, libfprint, the rebuild lane and the image in the builder VM (nothing is pushed), then G2 twice, and G4 when qualify.sh g4-due says it is due.
vm-image:
    tools/builder-vm/builder-vm.sh image

# Rebuild only the image in the builder VM, reusing the RPMs and the lane lock of the last vm-image.
vm-image-only:
    tools/builder-vm/builder-vm.sh image --image-only

# G4 on the last built image in the builder VM: install, counted rollback, GDM, login, lock and unlock (tools/builder-vm/README.md).
vm-qualify:
    tools/builder-vm/builder-vm.sh run env QUALIFY_MEM=3G QUALIFY_SMP=4 .github/scripts/qualify.sh local localhost/apex:build

# INSTALL.md's USB SSD rehearsal in the builder VM: G4 with root in LUKS2, unlocked through Plymouth's prompt at every boot.
vm-qualify-luks:
    tools/builder-vm/builder-vm.sh run env QUALIFY_LAYOUT=luks QUALIFY_MEM=3G QUALIFY_SMP=4 .github/scripts/qualify.sh local localhost/apex:build

# G2 in the builder VM: the headless shell of IMAGE (the last vm-image build), run twice and asserted (apex-gnome's tests/shots).
vm-g2 image="localhost/apex:build":
    tools/builder-vm/builder-vm.sh run bash -c '. .github/scripts/lib.sh && eval "$(tools/components.sh env)" && G2_IMAGE_DIR=$PWD/image G2_REPOS_BASE=$(containerfile_arg REPOS_BASE) G2_OUT_DIR=$PWD/_build/g2 "$APEX_GNOME_SRC/tests/shots/run.sh" "$1"' _ {{ image }}

# ---- Self-hosted runner: vm.yml drives the builder VM (tools/runner/README.md) ----------

# The runner on this host: group, key, image, check, install, status (tools/runner/runner.sh help).
[positional-arguments]
runner *args:
    tools/runner/runner.sh "$@"

# The KVM host's read-only checks before the builder VM and the runner: one PASS/FAIL row each.
runner-preflight:
    tools/runner/preflight.sh

# Install ci-build in the builder VM and bind the runner's key to it, after just runner key.
vm-ci-install:
    tools/builder-vm/builder-vm.sh ci-install "${XDG_CONFIG_HOME:-$HOME/.config}/apex/runner/ssh/id_ed25519.pub"

# ---- Rebuild lane: Fedora packages with Apex patches (packaging/README.md) -------------
# snapshot.sh first commits a dirty tree in the VM copy: the lane and lane.sh build from git HEAD.

# Rebuild PKG (or all) from Fedora's SRPM with its series and Source1, in the builder VM.
pkg-build pkg="all":
    tools/builder-vm/builder-vm.sh run tools/builder-vm/snapshot.sh tools/builder-vm/lane.sh build {{ pkg }}

# Print PKG's content key: Fedora's NVR plus a hash of the pin and every Apex input.
pkg-key pkg:
    tools/builder-vm/builder-vm.sh run tools/builder-vm/snapshot.sh tools/builder-vm/lane.sh key {{ pkg }}

# What the next image takes from the lane: each family's state, build and hold timer.
pkg-status:
    tools/builder-vm/builder-vm.sh run tools/builder-vm/snapshot.sh tools/builder-vm/lane.sh status

# A git work tree of PKG in the builder VM: Fedora's %prep, the series as commits, Source1.
pkg-prep pkg:
    tools/builder-vm/builder-vm.sh run tools/builder-vm/snapshot.sh tools/builder-vm/lane.sh prep {{ pkg }}

# The series onto another Fedora build of PKG (git am -3) in the work tree; then pkg-export.
pkg-rebase pkg nvr:
    tools/builder-vm/builder-vm.sh run tools/builder-vm/snapshot.sh tools/builder-vm/lane.sh prep {{ pkg }} {{ nvr }}

# Write the work tree's commits to packaging/pkgs/PKG (patches/, series) of the recipe's checkout on this host (APEX_RECIPES).
pkg-export pkg *new:
    test -f {{ recipes }}/packaging/pkgs/{{ pkg }}/pkg.env || { echo "no {{ recipes }}/packaging/pkgs/{{ pkg }}: set APEX_RECIPES to the recipe's checkout" >&2; exit 1; }
    tools/builder-vm/builder-vm.sh sync
    tools/builder-vm/builder-vm.sh ssh 'cd ~/apex-image && tools/builder-vm/snapshot.sh tools/builder-vm/lane.sh export {{ pkg }} {{ new }} >&2 && tar -C "$(tools/builder-vm/lane.sh --recipe-dir {{ pkg }})" -cf - series patches' | tar -C {{ recipes }}/packaging/pkgs/{{ pkg }} -xf -

# After an image built from rpms.lock.next passed its gates, make it rpms.lock.
# --allow-degraded is the owner's publish override for a kernel without its NVIDIA set (degraded=nvidia).
pkg-promote *flags:
    tools/builder-vm/builder-vm.sh run tools/builder-vm/snapshot.sh tools/builder-vm/lane.sh promote {{ flags }}

# At a hold limit, ship Fedora's build of PKG's family instead (an owner decision).
pkg-stock pkg:
    tools/builder-vm/builder-vm.sh run tools/builder-vm/snapshot.sh tools/builder-vm/lane.sh stock {{ pkg }}

# S1b's absorption check: does each recipe's series apply at fuzz 0 to the newest F45 stable and updates-testing SRPM?
lane-absorb-report *pkgs:
    tools/builder-vm/builder-vm.sh run tools/builder-vm/lane-absorb-report.sh {{ pkgs }}

# The kernel pair's bump check in the builder VM: a point bump commits the new pins on a branch of the apex-kernel checkout, a new major waits for the owner.
kernel-bump:
    tools/builder-vm/builder-vm.sh run tools/builder-vm/snapshot.sh tools/builder-vm/lane.sh kernel-bump

# S1c's lane rehearsals in a scratch store: point (a bump published to a throwaway registry), kmod (an injected kmod failure held, then degraded=nvidia), or all.
lane-rehearsal scenario="all":
    tools/builder-vm/builder-vm.sh run tools/builder-vm/snapshot.sh tools/builder-vm/lane-rehearsal.sh {{ scenario }}

# ---- Desktop VM: the built image in a window on this host (tools/builder-vm/README.md) ---

# Install the last vm-image build onto the desktop VM disk (desktop-install --replace redoes it).
[positional-arguments]
desktop-install *args:
    tools/builder-vm/desktop-vm.sh install "$@"

# Open the desktop VM window (APEX_DESKTOP_SHARP=1 just desktop: 1:1 pixels on a scaled host).
desktop:
    tools/builder-vm/desktop-vm.sh start

# Shut the desktop VM down cleanly.
desktop-stop:
    tools/builder-vm/desktop-vm.sh stop

# Show whether the desktop VM runs and which image it has.
desktop-status:
    tools/builder-vm/desktop-vm.sh status

# A root shell in the desktop VM (or: just desktop-ssh 'CMD', run by the guest's shell).
[positional-arguments]
desktop-ssh *args:
    tools/builder-vm/desktop-vm.sh ssh "$@"

# Stage the last vm-image build in the running desktop VM (podman save | load, bootc switch); keeps /var/home and /etc.
[positional-arguments]
desktop-update *args:
    tools/builder-vm/desktop-vm.sh update "$@"

# ---- Dev loop: the shell in the desktop VM (desktop/README.md) --------------------------

# JS and SCSS edits in a nested devkit shell in the desktop VM within seconds (first: just shell-dev fetch).
[positional-arguments]
shell-dev *args:
    tools/builder-vm/shell-dev.sh "$@"

# How to rebuild gnome-shell's C incrementally in an F45 toolbox in the desktop VM and run it through bootc usroverlay.
shell-c:
    @echo 'The C loop runs in the desktop VM: gnome-shell from the Apex SRPM of the build the VM runs, compiled'
    @echo 'with ninja in an F45 toolbox, then unpacked over a transient /usr (desktop/README.md, "The C loop").'
    @echo 'On this host:'
    @echo ''
    @echo '  just shell-dev fetch && just shell-dev push     # the SRPM lands in /var/lib/apex-shell-dev/inputs/rpms/'
    @echo ''
    @echo 'In a terminal in the VM window, as your user, once per shell build (about 15 minutes the first time, mostly downloads):'
    @echo ''
    @echo '  mkdir -p ~/apex-shell-c && cp /var/lib/apex-shell-dev/inputs/rpms/gnome-shell-*.src.rpm ~/apex-shell-c/'
    @echo '  srpm=$(ls ~/apex-shell-c/gnome-shell-*.src.rpm)    # the toolbox sees your home, not /var/lib'
    @echo '  toolbox create --distro fedora --release 45 apex-shell'
    @echo '  toolbox run -c apex-shell sudo dnf -y install rpm-build'
    @echo '  toolbox run -c apex-shell sudo dnf -y builddep "$srpm"'
    @echo '  toolbox run -c apex-shell rpmbuild -rc --noclean --define "_topdir $HOME/apex-shell-c" --define "_package_note_status 0" "$srpm"'
    @echo '  cd ~/apex-shell-c/BUILD/gnome-shell-*-build/gnome-shell-*/    # the tree: edit src/ here'
    @echo ''
    @echo 'Each round, from the tree (seconds to build and install):'
    @echo ''
    @echo '  toolbox run -c apex-shell ninja -C redhat-linux-build'
    @echo '  toolbox run -c apex-shell meson install -C redhat-linux-build --no-rebuild --destdir "$HOME/apex-shell-c/root"'
    @echo '  sudo bootc usroverlay    # once per boot: /usr stays writable until the next reboot, which drops the build'
    @echo '  tar -C ~/apex-shell-c/root -cf - usr | sudo tar -C / --no-same-owner --no-overwrite-dir -xf -'
    @echo ''
    @echo 'Then just shell-dev on this host (the nested shell), or log out and in (the session shell), runs it.'
