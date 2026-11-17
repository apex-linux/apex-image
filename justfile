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

# Builds the OS image as localhost/apex:main. Components come from the tip of
# main, or from the pins in a sync file: just build release/sync
build sync="":
    scripts/build.sh "{{sync}}"

# Boots the built image to the GNOME greeter in a virtual machine with 4 GiB
# of memory. APEX_VM_DISPLAY=none runs it without a window.
vm:
    scripts/vm.sh

# Pushes the built image to ghcr.io/apex-linux/apex:main. Needs a registry
# login; CI does this on pushes to main.
publish:
    scripts/publish.sh
