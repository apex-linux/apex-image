# Fedora 45 builder VM

The development host is Ubuntu, so it cannot run rootful podman, `bootc-base-imagectl
build-rootfs` or `rpmbuild` against Fedora 45. This VM runs them
([ADR 0013](../../docs/adr/0013-build-pipeline.md)):

- QEMU with KVM, user-mode networking and UEFI (OVMF), started as your normal user.
- **No root on the host.** `/dev/kvm` is usable through its ACL.
- The repository is copied in with `rsync` and runs from a disk local to the VM. The VM
  never mounts host directories.
- Inside the VM the tools run as the `builder` user, who has passwordless sudo there.
- sshd is reachable only at `127.0.0.1:2222`, with a key generated for this VM.

## Use

```bash
just vm-create
```

`just vm-create` does the following, once:

1. Downloads `Fedora-Cloud-Base-Generic-45_Beta-1.3.x86_64.qcow2`.
2. Verifies the image's signed CHECKSUM with the pinned Fedora 45 key, then checks its
   SHA-256.
3. Creates a 120 GiB copy-on-write disk.
4. Boots the VM with cloud-init and provisions the tools (`provision.sh`).

```bash
just vm-image
```

`just vm-image` copies this checkout into the VM and builds, in order:

- the apex and apex-desktop RPMs;
- the patched libfprint;
- the rebuild lane's packages (gnome-shell), into `rpms.lock.next` of the store below;
- the image, from those RPMs and that lock.

The Apex RPM key signs every RPM; nothing pushes or signs the image.

The results are in `~/apex-fedora/_build/` inside the VM.

The other recipes:

| Recipe | Does |
|---|---|
| `just vm-start` / `just vm-stop` | Boot in the background / clean ACPI shutdown. |
| `just vm-status` | Show whether it runs, plus uptime, disk and memory use. |
| `just vm-ssh [CMD…]` | Open a shell in the VM, or run `CMD`. |
| `just vm-sync` | Copy the checkout to `~/apex-fedora` in the VM. |
| `just vm-image-only` | Rebuild only the image, reusing the RPMs and the lane's `rpms.lock.next` of the last `just vm-image`. |

Run `tools/builder-vm/builder-vm.sh help` for every command, including `console` (the
serial log) and `destroy --yes`. `destroy` deletes the Apex RPM key with the disk; a new
VM gets it back from its offline backup
([packaging/README.md](../../packaging/README.md#signing), "A new builder VM").

The tools that build from git HEAD see uncommitted host changes through
`snapshot.sh`, which commits a dirty VM copy of the checkout as a throwaway snapshot.
The next sync replaces that copy's `.git` with the host's, so the snapshot never leaves
the VM.

## Rebuild lane

The `just pkg-*` recipes run `apex-lane` in the VM through `lane.sh`: Fedora SRPMs
rebuilt with the Apex series, such as gnome-shell with the Apex layer
([packaging/README.md](../../packaging/README.md#the-rebuild-lane)). `lane.sh` builds
`apex-lane` from the checkout's HEAD with Fedora's rust, in a container of
`image/Containerfile`'s `REPOS_BASE` (the image `localhost/apex-lane-builder`, made once
per digest by `rpms.sh toolchain`, and the podman volume `apex-lane-cargo` for cargo's
registry and target), and keeps the last three builds in `~/.cache/apex-lane/`. The
lane's state lives in `~/apex-store/` in the VM, outside the synced checkout: the built
sets by content key, `rpms.lock` and `rpms.lock.next`. dnf's metadata for the lane's
containers is kept in the podman volume `apex-lane-dnf-cache`. A cold gnome-shell build
takes about 10 minutes; the first run of `lane.sh` adds a few minutes for the builder
image and a cold `cargo build`.

The Apex RPM key signs every RPM the VM builds, in the VM and after the build container
exits ([packaging/README.md](../../packaging/README.md#signing)). Its GnuPG home,
`~/.local/share/apex/rpm-gnupg`, and `~/.config/apex/rpm-signing.env`, which names it,
live outside the synced checkout. `provision.sh` installs `rpm-sign` and `gnupg2`.

## Resources

| Setting | Default | Variable |
|---|---|---|
| Guest RAM | 6 GiB, returned to the host when free (balloon with free-page reporting), plus zram swap in the guest | `APEX_VM_MEM` |
| vCPUs | 8 of the host's 12 threads | `APEX_VM_CPUS` |
| Disk | 120 GiB virtual, grows on demand; a full image build needs about 45 GiB | `APEX_VM_DISK` |
| Files | `~/.local/share/apex/builder` (the verified base image is cached in `base/`) | `APEX_VM_DIR` |

## Qualification

The VM has nested KVM, `qemu-kvm` and OVMF.

```bash
just vm-qualify
```

`just vm-qualify` runs `qualify.sh local`. It takes the image that `just vm-image` just
built, installs it on a disk laid out like the laptop (ESP, ext4 `/boot`, btrfs root),
boots it with UEFI, and requires:

- a running system;
- a green `apex-boot-assess`;
- a disarmed boot counter;
- the expected booted digest;
- a working `apexctl status --json`.

The nested guest gets 3 GiB of RAM.

`just qualify-local` prints how to run the other scenarios (fresh, upgrade, counted
rollback) against published digests.

## Desktop VM

The desktop VM runs the image you built in a window on this host, so you can use it
before it reaches the laptop.

```bash
just vm-image          # once per change: build the image in the builder VM
just desktop-install   # install it onto the desktop VM disk
just desktop           # open the window
```

`just desktop-install` does the following:

1. Starts the builder VM if it is not running, and stops it again afterwards.
2. Installs `localhost/apex:build` onto a 64 GiB disk laid out like the laptop minus
   LUKS (ESP, ext4 `/boot`, btrfs root), with the same `install_disk` code as
   `qualify.sh`.
3. Copies the disk to `~/.local/share/apex/desktop` as a qcow2 of about 5 GiB.

To install a newer build over an existing VM, run `just desktop-install --replace`. It
discards the old disk and everything you did in it. While an install runs, `just desktop`
refuses to start.

The first boot runs `gnome-initial-setup`, where you create your user. The Flathub apps
install in the background.

**How it differs from a laptop install** ([INSTALL.md](../../docs/INSTALL.md))

- Root accepts this VM's SSH key. A kernel argument starts sshd, which the image ships
  disabled. Both carry over to later updates.
- The disk has no LUKS and no separate `/var` subvolume.
- Updates follow `apex-testing:45`, not `apex:45`. Until CI has published that tag,
  update checks fail and `apexctl status` shows the error.
- The image is a local build, not a verified, published digest.

**The VM**

- KVM on the host with UEFI.
- virtio-gpu with OpenGL (virgl) in a GTK window, titled "QEMU (Apex desktop)".
- PipeWire sound, playback only. `APEX_DESKTOP_MIC=1` also gives the guest the host's
  default microphone.
- A virtio tablet and keyboard.
- 4 GiB of RAM (free pages go back to the host) and 4 vCPUs.
- User-mode networking. The guest reaches the internet, and also every service that
  listens on the host's `127.0.0.1`, at `10.0.2.2`.

**In the window**

| Keys or menu | Does |
|---|---|
| Ctrl+Alt+G | Grabs keyboard and mouse, so Super and other shortcuts reach the guest. Press it again to release. |
| Ctrl+Alt+F | Full screen. |
| Machine > Power Down | Shuts the guest down cleanly. |
| Machine > Quit (Ctrl+Alt+Q), Machine > Reset | Stop or reset QEMU at once, like pulling the power. Avoid them. |

The close button is disabled, because closing the window would cut the power. Shut down
from GNOME, from the Machine menu, or with `just desktop-stop`.

**Other recipes**

| Recipe | Does |
|---|---|
| `just desktop-stop` | Runs `systemctl poweroff` over SSH, or presses the ACPI power button without SSH. After 180 s it stops QEMU hard, like pulling the power. |
| `just desktop-status` | Whether it runs, the installed image and digest, and disk use. |
| `just desktop-ssh ['CMD']` | A root shell in the guest, or `CMD` run by the guest's shell. |

The shell uses a key made for this VM. sshd is forwarded on `127.0.0.1:2223` only.

`tools/builder-vm/desktop-vm.sh help` lists everything else, including `screenshot` and
`destroy --yes`. `screenshot` only works with `APEX_DESKTOP_GL=off`, because QEMU cannot
read back an OpenGL scanout. With OpenGL, use Print Screen in the guest.

**Sharpness on a scaled host**

QEMU's GTK window reports its size to the guest in logical pixels. With the laptop at
166 % (GTK 3 draws it at 2x), the guest image is stretched, so text is soft.

For sharp text, start with:

```bash
APEX_DESKTOP_SHARP=1 just desktop
```

Then:

1. Maximize the window. The guest follows within a second.
2. Set **Settings > Displays > Scale** to 200 % in the guest, once. Otherwise
   everything is half size.

The guest now renders at the resolution of GTK's 2x window buffer, and QEMU does not
stretch it. GNOME still scales the window to 166 %, as it does every GTK 3 app, so the
result is sharp but not pixel-exact.

In this mode the window follows the guest's mode:

- It opens small.
- It cannot be dragged smaller than the guest's current mode.
- A window that is not maximized shrinks back to the firmware's mode at every guest
  reboot. Keep it maximized.
- Do not use full screen: it gives the guest logical pixels again.

A start without `APEX_DESKTOP_SHARP=1` also gives the guest logical pixels. With Scale
at 200 % everything is then twice as large, so set it back to 100 %.

**Variables**

| Variable | Default |
|---|---|
| `APEX_DESKTOP_MEM` | `4G` |
| `APEX_DESKTOP_CPUS` | `4` |
| `APEX_DESKTOP_DISK_GB` | `64` |
| `APEX_DESKTOP_SSH_PORT` | `2223` |
| `APEX_DESKTOP_GL` | `on` |
| `APEX_DESKTOP_AUDIO` | `pipewire` (or `pa`, `alsa`, `none`) |
| `APEX_DESKTOP_MIC` | `0` |
| `APEX_DESKTOP_SHARP` | `0` |
| `APEX_DESKTOP_DIR` | `~/.local/share/apex/desktop` |
