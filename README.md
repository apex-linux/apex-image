# apex-image

Builds the Apex Linux operating system image, the installer media and the
release pins.

Part of [Apex Linux](https://github.com/apex-linux/apex). See the
[specification](https://github.com/apex-linux/apex/blob/main/docs/spec.md)
and the
[engineering standards](https://github.com/apex-linux/apex/blob/main/docs/engineering.md).

## What is in the image

The [Containerfile](Containerfile) starts from Fedora's `bootc` base image,
`quay.io/fedora/fedora-bootc:45`, and adds the stock Fedora GNOME desktop:
the comps groups in
[groups.txt](image/desktop/packages/groups.txt), which are the Fedora
Workstation environment without LibreOffice. Packages to leave out go in
[exclude.txt](image/desktop/packages/exclude.txt).

The image names itself Apex Linux in `os-release`, with `ID=apex` and
`ID_LIKE=fedora`, as a Fedora derivative should. `VERSION_ID` stays the
Fedora release it is built from until Apex has a version scheme of its own.

On top come the Apex components listed in
[components.txt](image/components/components.txt). The build fetches each
repository at the tip of its `main` branch and runs its
`just install <destdir>` recipe, which installs under `<destdir>/usr` only.
A component without an `install` recipe is skipped. A release pins the
commits instead, in `release/sync`, one `component=commit` line each:
`just build release/sync` builds from those pins.

## Build and test

You need `just`, `podman`, `flock` and Node.js (for `npx`). Every task is a
recipe in the [justfile](justfile); CI runs the same recipes.

```sh
just doctor  # Checks free disk and memory, and shows what Apex can clean.
just lint    # Runs shellcheck, shfmt, hadolint and markdownlint.
just build   # Builds the image as localhost/apex:main.
just vm      # Boots it to the GNOME greeter in a virtual machine.
just clean   # Removes Apex's own images, disks and caches.
```

You also need QEMU with KVM access and `virtiofsd` for `just vm`.

Heavy recipes run `just doctor` first, which refuses to continue with less
than 25 GiB of free disk or 4 GiB of available memory, and take the lock
`~/.cache/apex/heavy.lock` so that only one runs at a time. Large files go
under `~/.cache/apex/` or `build/`, never `/tmp`.

## Published image

CI builds every pull request without publishing. On each push to `main` it
publishes the rolling image to `ghcr.io/apex-linux/apex:main`. An installed
system follows it with stock `bootc`:

```sh
sudo bootc switch ghcr.io/apex-linux/apex:main
```

## Boot in a virtual machine

`just vm` needs no root. QEMU boots the kernel and initramfs of the built
image directly, and the guest reads its root file system from container
storage over virtiofs, the way `bcvk ephemeral` does. Writes go to a
memory-backed overlay and vanish at power-off. The guest gets 4 GiB of
memory and half the host's CPUs, and opens in a window;
`APEX_VM_DISPLAY=none just vm` runs without one, with the serial console in
`build/vm/serial.log` and a QMP socket in `build/vm/qmp.sock` for
screenshots.

Because the root starts empty each boot, the kernel command line skips
GNOME Initial Setup (`gnome.initial-setup=0`) to reach the greeter, and
turns SELinux off, since container storage carries no SELinux labels. It
boots the image's userspace, not an installed disk: the bootloader and
`bootc` updates are not exercised, and `bootloader-update.service` fails
because there is no EFI system partition.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
