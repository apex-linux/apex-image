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
A component without an `install` recipe is skipped. A component may list
the Fedora packages it needs in `/usr/share/<component>/requires.txt`, one
`<rpm> <path-or-glob>` per line: the build installs them and fails if a
listed path is missing afterwards. After the components are copied in, the
build compiles the GSettings schemas and refreshes the icon caches. A
release pins the commits instead, in `release/sync`, one `component=commit`
line each: `APEX_SYNC=release/sync just build` builds from those pins.

Fingerprint authentication is on in PAM (authselect's `with-fingerprint`),
so an enrolled finger unlocks the session and authorizes administrator
actions; the password still works when the reader fails or is absent.

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
under `~/.cache/apex/` or `build/`, never `/tmp`. After a successful build,
`just build` keeps that build's builder stages as `localhost/apex-cache:<stage>`
and removes the untagged Apex images it superseded; it never removes a
tagged image or another project's image. `just doctor` reports what Apex
can free, and `just clean` frees it.

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
never erases a disk on its own. These steps install Apex beside another
system (Ubuntu here) into unallocated space on the same disk; `just
vm-dualboot` tests exactly this in a virtual machine.

1.  **Back up first.** Copy everything you cannot lose to another drive.
    Then, from Ubuntu, save the EFI system partition and the firmware boot
    entries next to that backup, so Ubuntu's boot files and entry can be
    restored by hand. With the backup drive mounted, for example at
    `/media/$USER/BACKUP`:

    ```sh
    B="/media/$USER/BACKUP/before-apex"
    mkdir -p "$B"
    sudo tar -C /boot/efi -cf "$B/esp.tar" .
    sudo efibootmgr -v > "$B/efibootmgr-v.txt"
    sudo sfdisk --dump /dev/nvme0n1 > "$B/nvme0n1.sfdisk"
    lsblk -o NAME,SIZE,FSTYPE,PARTLABEL,PARTUUID,MOUNTPOINTS > "$B/lsblk.txt"
    ```

2.  Check the free space: in GNOME Disks, the internal disk must show
    "Free Space" of at least 40 GB. The install uses only that space.
3.  Build the ISO with `just iso` (it downloads Fedora's netinst ISO once,
    checks its signature and writes `build/iso/apex-installer.iso`, about
    1.3 GB) and write it to a USB stick of 2 GB or more. Everything on the
    stick is lost. In GNOME Disks select the stick and use
    "Restore Disk Image", or find the stick with `lsblk` and run:

    ```sh
    sudo dd if=build/iso/apex-installer.iso of=/dev/sdX bs=4M \
        oflag=direct status=progress
    ```

    where `/dev/sdX` is the stick, not a disk you want to keep.
4.  Secure Boot must be off (on the ASUS M7400QC, F2 at power-on opens the
    firmware settings): Apex does not sign its NVIDIA module yet.
5.  Boot from the stick (Esc at power-on opens the ASUS boot menu; choose
    the UEFI entry for the stick) and pick "Install Apex Linux". Choose a
    language and press Continue.
6.  On "Installation Summary":
    *   "Network & Host Name": connect to Wi-Fi if there is no cable.
    *   "Installation Destination" is the screen that decides where Apex
        goes. Select only the internal disk; it shows its free space under
        its name. Leave "Storage Configuration" on "Automatic" and leave
        "Free up space by removing or shrinking existing partitions"
        unticked, then press Done. Automatic uses only the free space: it
        adds a `/boot` partition and a Btrfs partition for Apex, and
        mounts the existing EFI system partition without formatting it.
        If the installer asks to reclaim space, press Cancel: it found too
        little free space, and nothing has been written yet.
    *   Set "Keyboard" and "Time & Date", then press "Begin Installation".
        Nothing is written to the disk before this button.
7.  When it finishes, press "Reboot System" and remove the stick. The
    installer adds a firmware boot entry named "Fedora" (Apex's boot
    loader is Fedora's shim and GRUB) and puts it first. It writes
    `EFI/fedora` on the EFI system partition, about 7 MB, and replaces
    the removable-media fallback loader in `EFI/Boot` with Fedora's shim;
    Ubuntu's own `EFI/ubuntu` and its boot entry stay as they were. The
    fallback only runs when the firmware has no usable boot entry, for
    example after its settings are reset: then Fedora's shim starts and its
    fallback program recreates boot entries from the `BOOTX64.CSV` file in
    each `EFI/<name>` directory, which Ubuntu's shim package also ships. If
    Ubuntu's entry is ever missing, recreate it from Apex or Ubuntu with
    `sudo efibootmgr -c -d /dev/nvme0n1 -p 1 -L ubuntu -l '\EFI\ubuntu\shimx64.efi'`.
8.  GNOME Initial Setup creates your user account.
9.  On a computer with an NVIDIA GPU, switch to the NVIDIA flavor and
    restart:

    ```sh
    sudo bootc switch ghcr.io/apex-linux/apex:main-nvidia
    ```

Updates come with `sudo bootc upgrade` and a restart; `sudo bootc rollback`
returns to the previous image.

### Choose a system at power-on

Apex's GRUB menu lists only Apex. To start Ubuntu, press Esc at power-on
and choose "ubuntu" in the ASUS boot menu; without a choice the computer
starts the first entry, "Fedora" (Apex). To make Ubuntu the default
instead, run `sudo efibootmgr` in either system to see the entries and
`sudo efibootmgr -o XXXX,YYYY` with Ubuntu's number first.

### Remove Apex

From Ubuntu:

1.  Delete the two partitions Apex created in the former free space (its
    `/boot`, about 2 GB, ext4, and its Btrfs partition) with GNOME Disks.
    Do not touch the EFI system partition or Ubuntu's partition.
2.  Remove Apex's boot files and boot entry:
    `sudo rm -r /boot/efi/EFI/fedora`, then find the "Fedora" entry with
    `sudo efibootmgr` and delete it with `sudo efibootmgr -b XXXX -B`.
3.  Put back Ubuntu's fallback loader from the backup of step 1:

    ```sh
    B="/media/$USER/BACKUP/before-apex"
    sudo rm -r /boot/efi/EFI/Boot
    sudo tar -C /boot/efi -xf "$B/esp.tar" ./EFI/Boot
    ```

    Compare `sudo efibootmgr -v` with `$B/efibootmgr-v.txt`: Ubuntu's
    entry should be unchanged.

## Test the installer in a virtual machine

`just vm-dualboot` checks the dual-boot install before anyone tries it on
a real disk. It lays out a virtual disk like the reference machine's: a
700 MiB EFI system partition named "EFI System Partition" with a 196 MiB
file system holding another system's loader under `EFI/ubuntu`, 30 GiB of
free space and an ext4 partition with known contents at the end, plus a
UEFI boot entry for the other system that comes first in the boot order.
The stand-in loader is a small GRUB that prints a marker and powers off.
A test variant of the ISO installs Apex with automatic storage
configuration, as in step 6 above. The test then fails unless:

*   the table entries of both existing partitions, the ext4 partition's
    contents, the EFI partition's file system serial and every file under
    `EFI/ubuntu` are byte for byte unchanged, after the install and again
    after the steps below;
*   the other system's boot entry is still there and Apex added its own;
*   the installed system boots from the disk through its boot loader;
*   one `bootc upgrade` boots a newer image, when one is published (the
    log says "UPGRADE NOT EXERCISED" otherwise);
*   the other system's loader starts through its boot entry, chosen with
    `efibootmgr --bootnext`.

It also reports the free space left on the EFI partition, whether
`EFI/Boot` changed, the boot order and whether Apex's GRUB lists the other
system. `just vm-disk` then boots the result.

`just vm-install` builds a test variant of the ISO that installs, without
asking, onto an empty 40 GB virtual disk under `build/vm-disk/`, and adds an
SSH key for root. `just vm-disk` then boots that disk through its bootloader
like a real computer, with SSH on `localhost:2222`, and
`just vm-ssh bootc status` runs commands in it. Both use the published
image, not a local build, because the installer pulls it from the registry.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
