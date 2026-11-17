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

# Builds the OS image as localhost/apex:main.
build:
    scripts/build.sh
