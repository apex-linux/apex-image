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

Fedora's `libfprint` is rebuilt with the patches that `apex-hardware`
carries in `patches/libfprint/` for the ELAN `04f3:0c6e` fingerprint reader.
If a patch stops applying, the build log says so and the image keeps
Fedora's package.

The `nvidia` flavor, `just build nvidia`, adds the NVIDIA driver for
machines with an NVIDIA GPU, as `apex-hardware`'s ADR 0001 decides: a
builder stage compiles negativo17's open kernel module for the image's
kernel with `akmods`, and the flavor installs it with negativo17's userspace
of the same version and `apex-hardware`'s flavor files
(`just install <destdir> nvidia`). The build fails unless the module's
`vermagic` names the image's kernel and the module and userspace versions
match. The module is not signed, so Secure Boot must be off; signing comes
with M3.

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
just iso     # Builds the installer, build/iso/apex-installer.iso.
just vm-install  # Installs from the installer onto a virtual disk.
just vm-disk     # Boots that disk; just vm-ssh runs commands in it.
just clean   # Removes Apex's own images, disks and caches.
```

You also need QEMU with KVM access, `virtiofsd` and OVMF for the virtual
machines. None of the recipes needs root.

Heavy recipes run `just doctor` first, which refuses to continue with less
than 25 GiB of free disk or 4 GiB of available memory, and take the lock
`~/.cache/apex/heavy.lock` so that only one runs at a time. Large files go
under `~/.cache/apex/` or `build/`, never `/tmp`.

## Published image

CI builds every pull request without publishing. On each push to `main` it
publishes the rolling image to `ghcr.io/apex-linux/apex:main` and the NVIDIA
flavor to `ghcr.io/apex-linux/apex:main-nvidia`. An installed
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

## Install on a computer

The installer is Fedora's netinst ISO with a kickstart that installs
`ghcr.io/apex-linux/apex:main` over the network, so the computer needs an
internet connection during the install. It asks for the target disk and
never erases a disk on its own.

1.  Build the ISO: `just iso`. It downloads Fedora's netinst ISO once,
    checks its signature and writes `build/iso/apex-installer.iso`
    (about 1.3 GB).
2.  Write it to a USB stick of 2 GB or more. Everything on the stick is
    lost. Either open GNOME Disks, select the stick, and choose
    "Restore Disk Image" with the ISO, or find the stick's device name with
    `lsblk` and run:

    ```sh
    sudo dd if=build/iso/apex-installer.iso of=/dev/sdX bs=4M \
        oflag=direct status=progress
    ```

    where `/dev/sdX` is the stick, not a disk you want to keep.
3.  On the computer, turn Secure Boot off in the firmware settings (on the
    ASUS M7400QC, F2 at power-on). Apex does not sign its NVIDIA module
    yet.
4.  Boot from the stick (Esc at power-on opens the ASUS boot menu; choose
    the UEFI entry for the stick) and pick "Install Apex Linux".
5.  In the installer, connect to Wi-Fi under "Network & Host Name" if there
    is no cable, then open "Installation Destination" and choose the disk.
    For an external SSD, select only that disk. To keep Ubuntu next to Apex,
    select the internal disk, choose custom partitioning and give Apex free
    space or a partition you made for it. To replace Ubuntu, select the
    internal disk and reclaim its space. Nothing is written until you press
    "Begin Installation".
6.  After the restart, GNOME Initial Setup creates your user account.
7.  On a computer with an NVIDIA GPU, switch to the NVIDIA flavor and
    restart:

    ```sh
    sudo bootc switch ghcr.io/apex-linux/apex:main-nvidia
    ```

Updates come with `sudo bootc upgrade` and a restart; `sudo bootc rollback`
returns to the previous image.

## Test the installer in a virtual machine

`just vm-install` builds a test variant of the ISO that installs, without
asking, onto an empty 40 GB virtual disk under `build/vm-disk/`, and adds an
SSH key for root. `just vm-disk` then boots that disk through its bootloader
like a real computer, with SSH on `localhost:2222`, and
`just vm-ssh bootc status` runs commands in it. Both use the published
image, not a local build, because the installer pulls it from the registry.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
