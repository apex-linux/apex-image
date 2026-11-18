# Lists the available recipes.
default:
    @just --list

# Checks free disk and memory, and shows what Apex can clean.
doctor:
    scripts/doctor.sh

# Lints shell scripts, the Containerfile and Markdown.
lint:
    scripts/lint.sh

# Removes Apex's own images, disks and caches.
clean:
    scripts/clean.sh

# Builds the OS image as localhost/apex:main, or a flavor of it:
# just build nvidia. Components come from the tip of main, or from the pins in
# a sync file: APEX_SYNC=release/sync just build
build flavor="":
    scripts/build.sh "{{flavor}}"

# Boots the built image to the GNOME greeter in a virtual machine with 4 GiB
# of memory. APEX_VM_DISPLAY=none runs it without a window.
vm:
    scripts/vm.sh

# Pushes the built image to ghcr.io/apex-linux/apex:main, or a flavor to
# :main-<flavor>. Needs a registry login; CI does this on pushes to main.
publish flavor="":
    scripts/publish.sh "{{flavor}}"

# Builds the installer ISO, build/iso/apex-installer.iso: Fedora's netinst
# with a kickstart that installs ghcr.io/apex-linux/apex:main.
iso:
    scripts/iso.sh

# Installs Apex from a test variant of the installer ISO onto an empty
# virtual disk, unattended. The installer pulls ghcr.io/apex-linux/apex:main.
vm-install:
    scripts/vm-install.sh

# Boots the disk that vm-install installed, through its bootloader.
vm-disk:
    scripts/vm-disk.sh

# Runs a command as root in the VM that vm-disk booted, or opens a shell.
# Every argument goes to the VM, none to the host shell.
[positional-arguments]
vm-ssh *command:
    scripts/vm-ssh.sh "$@"

# Tests a dual-boot install in a VM: a disk laid out like the reference
# machine's, Apex installed into its free space, the other system unchanged.
vm-dualboot:
    scripts/vm-dualboot.sh

# Installs from a test variant of the installer ISO through a Ventoy USB
# stick, unattended. Needs the files of a Ventoy stick's VTOYEFI partition in
# ~/.cache/apex/ventoy-1.0.95-vtoyefi or APEX_VENTOY_DIR.
vm-ventoy:
    scripts/vm-ventoy.sh
