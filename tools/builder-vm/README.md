# Fedora 45 builder VM

This VM runs rootful podman, `bootc-base-imagectl build-rootfs` and `rpmbuild` against
Fedora 45, which an Ubuntu host cannot and a Fedora host should not do as root
([ADR 0013](https://github.com/apex-linux/apex/blob/main/docs/adr/0013-build-pipeline.md)):

- QEMU with KVM, user-mode networking and UEFI (OVMF), started as your normal user.
  The host packages are `qemu-system-x86 qemu-utils ovmf curl gpgv rsync socat` on
  Ubuntu and `qemu-system-x86-core qemu-img edk2-ovmf curl gnupg2 rsync socat` on Fedora.
  The firmware is found in either place, or set `APEX_OVMF_CODE` and `APEX_OVMF_VARS`.
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

`just vm-image` copies this checkout into the VM. `tools/components.sh fetch` first
clones each component at its commit in `components.lock` into `_build/components/`, and
each RPM is built in its component's clone, as root in a fresh `fedora:45`. It builds, in
order:

- the apex RPM (apex-system's `rpms.sh build`) and apex-desktop (apex-desktop's);
- the patched libfprint (apex-kernel's `libfprint.sh build`, given this image's
  `GA_REACHED` and updates-testing allowlist);
- the rebuild lane's packages (gnome-shell, from apex-gnome's recipe), into
  `rpms.lock.next` of the store below;
- the image, from those RPMs and that lock;
- G4 (`qualify.sh local`, below), when `qualify.sh g4-due` says it is due: the image's
  G4 key differs from the last G4 pass, or that pass is 7 days old. The key
  (`qualify.sh g4-key`) holds the NEVRAs of gdm, gnome-shell, mutter, gjs,
  gnome-session, accountsservice, pam, systemd, the kernel, shim, GRUB and bootupd, and
  the digest of every file of apex and apex-desktop, of every `/usr` file of the image
  overlay (`image/system_files`: the install config, the schema override, the presets,
  the polkit rules, the bootloader-update drop-in) and of the kargs. When G4 is not due,
  the build says which image passed it and when. `just vm-image-only` only says whether
  G4 is due. G4 fails on any row of `results.md` that is not PASS;
- G2 (apex-gnome's `tests/shots/run.sh`, always twice, as `just vm-g2`).

G4 runs first because it fails far more often, and both gates always run, so one build
shows both verdicts; it exits with the status of the first gate that failed. G4 writes
its key to `_build/qualify/g4-pending.txt`; only the gates record below moves it to
`_build/g4-passed.txt`, so a key is recorded only for an image whose G2 passed too.
After a G4 failure, `qualify.sh local-diag` runs every G4 unit on its own, in
`_build/qualify/diag`, so one build shows every failing row; it records nothing and
never changes the verdict.

Every G4 verdict, in every mode, adds a row to `_build/qualify/verdicts.tsv`: the commit,
the image ID, the harness digest (`qualify.sh g4-harness`), the verdict, the UTC time,
the mode (`gate`, `image-only` or `t2`) and `APEX_COMPONENTS`.

**Qualify-only (T2, advisory).** After a G4 failure whose fix is in the harness alone,
the next build reruns G4 on the image already built, without the RPMs, the lane, the
image or G2, and then `local-diag` when it fails. It writes no gates record and no G4
key (it keeps `_build/qualify-only/`), so nothing it does promotes; `vm.yml` never shows
it green, and `metrics.sh` keeps it out of S4's history. The live log starts with
`== plan: qualify-only (advisory)`, or `== plan: gate (G4 first)` and why not. It runs
only when every one of these holds, and the full gate run does otherwise (any check that
cannot be made counts as failed):

- `tools/builder-vm/t2-enabled` is committed (delete it to turn qualify-only off);
- the build is the 45 image with its kernel pair, not `--image-only`, and no
  `APEX_SRC_<NAME>` is set;
- the revision in the image's own `/usr/share/apex/manifest.json` is on `origin/main`,
  and `git diff --no-renames` from it to `HEAD` touches only qualify.sh, its allowlist,
  selftest.sh, contracts.sh, `.github/workflows/`, `tools/runner/`, `.md` files outside
  `image/` and `crates/`, or the builder-VM scripts that build nothing (`ci-build.sh`,
  `builder-vm.sh`, `desktop-*.sh`, `shell-dev*.sh`, `provision.sh`, `publish-image.sh`,
  `install-cosign.sh`, `firmware.sh`, `lane-rehearsal.sh`, `rehearsal/`). `lib.sh` means
  the full gate: `image.sh` sources it too;
- the image's last `verdicts.tsv` row is a FAIL of a `gate` or `t2` run with pinned
  components, and its harness digest differs from `HEAD`'s;
- the image is the one in `_build/g2/latest/result.txt` or the last `gate` row's;
- the image is less than 72 hours old.

When G2 passed and G4 passed or was not due, `_build/gates-passed.txt` names the lane
lock the image carries (from G2's `result.txt`), the image, G4's verdict (`passed for
image ID`, or `not due: its key passed on DATE for image ID`) and `components pinned`, or
`components dev-override` for a build with `APEX_SRC_<NAME>` set
(`tools/components.sh help`). Neither record is written when `rpms.lock.next` changed
while the gates ran. `just pkg-promote` refuses a lock it does not name, and a dev-override build.

The Apex RPM key signs every RPM; nothing pushes or signs the image.

The results are in `~/apex-image/_build/` inside the VM.

The other recipes:

| Recipe | Does |
|---|---|
| `just vm-start` / `just vm-stop` | Boot in the background / clean ACPI shutdown. |
| `just vm-status` | Show whether it runs, plus uptime, disk and memory use. |
| `just vm-ssh [CMD…]` | Open a shell in the VM, or run `CMD`. |
| `just vm-sync` | Copy the checkout to `~/apex-image` in the VM. |
| `just vm-image-only` | Rebuild only the image, reusing the RPMs and the lane's `rpms.lock.next` of the last `just vm-image`. |
| `just vm-qualify-luks` | INSTALL.md's USB SSD rehearsal (ADR 0010) as G4 on the last build: root in LUKS2 with btrfs subvolumes `root` and `var`, a wrong passphrase refused and the right one typed into Plymouth's prompt over QMP at every boot, the counted rollback's (`local-red`) included. It records no G4 pass. |
| `just vm-g2 [IMAGE]` | G2 on the last build: its headless shell, run twice and asserted (apex-gnome's `tests/shots`). |
| `just publish [--allow-degraded]` | Publish the last `just vm-image` build whose gates passed (S1d): rechunk against `apex:45`, push `apex:<version>`, sign it with the owner's cosign key (`~/.config/apex/cosign.key`, `COSIGN_PASSWORD`), and move `apex:45` once the committed policy verifies it. It refuses while `release.pub` is the placeholder. |
| `just publish-rehearsal` | The same steps against a throwaway `registry:2` on the VM's localhost, a throwaway key and a policy that trusts only it. Then a policy with another key must refuse the image. Nothing is published. |
| `just lane-rehearsal [point\|kmod\|all]` | ROADMAP S1c's lane rehearsals in a scratch store (`~/apex-rehearsal`); see below. Nothing is promoted or published for real. |
| `just vm-ci-install` | Install `ci-build`, the self-hosted runner's only entry point, and bind the runner's key to it ([tools/runner](../runner/README.md)). |

`just lane-rehearsal` starts from a good pair at the COPR build before the pinned one,
built with the rehearsal's own `pkg.env` (`rehearsal/`), and lets kernel-bump commit the
point bump. `point`: the bump builds as a whole pair, its image passes G1 and goes to a
throwaway registry. `kmod`: with `APEX_PAIR_FAULT=kmod` the pair holds on the kmod side
and the image is labelled `held`; past the limit it becomes `degraded=nvidia`, its image
passes G1, and promote takes it only with `--allow-degraded`. The RPMs are signed with
the VM's RPM key at N from 9001, so they never share a NEVRA with a real build. The
scratch store is deleted at the end; `logs/` and `report.md` stay.

Run `tools/builder-vm/builder-vm.sh help` for every command, including `console` (the
serial log) and `destroy --yes`. `destroy` deletes the Apex RPM key with the disk; a new
VM gets it back from its offline backup
([packaging/README.md](../../packaging/README.md#signing), "A new builder VM").

The tools that build from git HEAD see uncommitted host changes through
`snapshot.sh`, which commits a dirty VM copy of the checkout as a throwaway snapshot.
The next sync replaces that copy's `.git` with the host's, so the snapshot never leaves
the VM.

## From GitHub

`vm.yml` in `apex-linux/apex-image` runs this build from a self-hosted runner on this
host ([tools/runner/README.md](../runner/README.md)). The runner's SSH key may only run
`ci-build <sha>` (`ci-build.sh`, installed in the VM as
`/usr/local/libexec/apex/ci-build`). `ci-build` checks out a commit of `main` in
`~/apex-image`, runs `build-image.sh` and `lane.sh promote`, and returns the gate
results as a tar. A CI build and `just vm-sync`, `vm-image` or any `builder-vm.sh run`
recipe never overlap: all of them take `~/.apex-build.lock` in the VM, and the sync
refuses while a CI build holds it.

## Rebuild lane

The `just pkg-*` recipes run `apex-lane` in the VM through `lane.sh`: Fedora SRPMs
rebuilt with the Apex series, such as gnome-shell with the Apex layer
([packaging/README.md](../../packaging/README.md#the-rebuild-lane)). `lane.sh` builds
`apex-lane` from the checkout's HEAD with Fedora's rust, in a container of
`image/Containerfile`'s `REPOS_BASE` (the image `localhost/apex-lane-builder`, made once
per digest with Fedora's rust from the compose's repositories, and the podman volume `apex-lane-cargo` for cargo's
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

## cosign

Fedora 45 packages no cosign, so `builder-vm.sh provision` installs a pinned upstream
release after `provision.sh`: `install-cosign.sh` downloads
`cosign-linux-amd64` of `COSIGN_VERSION` from github.com/sigstore/cosign's releases
(never "latest") and installs it as `/usr/local/bin/cosign` only when its sha256 is
`COSIGN_SHA256`; a mismatch or failed download installs nothing and fails provisioning.
Both values live in `cosign.env`, which `just runner-preflight` reads too: its `vm-cosign`
row checks the VM's binary against the same pin. `publish.sh`'s signing flags
(`--new-bundle-format=false`, `--use-signing-config=false`) need cosign 3.

**The trust root is the reviewed sha256 in `cosign.env`.** The release also publishes
`cosign_checksums.txt.sigstore.json`, but checking that bundle needs a cosign (or another
sigstore verifier) the VM would already have to trust, and the binary being installed
cannot vouch for itself. So the VM verifies nothing but the pin.

**A bump** is one PR that changes both lines of `cosign.env`. Before it, on a machine with a
cosign you already trust (the VM's current one will do), check the new release's bundle and
take the sha256 from the verified checksums file:

```sh
V=v3.x.y
curl -fsSLO https://github.com/sigstore/cosign/releases/download/$V/cosign_checksums.txt
curl -fsSLO https://github.com/sigstore/cosign/releases/download/$V/cosign_checksums.txt.sigstore.json
cosign verify-blob cosign_checksums.txt --bundle cosign_checksums.txt.sigstore.json \
    --certificate-identity keyless@projectsigstore.iam.gserviceaccount.com \
    --certificate-oidc-issuer https://accounts.google.com
grep ' cosign-linux-amd64$' cosign_checksums.txt
```

Then `builder-vm.sh provision` and `just runner-preflight`. The pinned v3.0.2 value was
taken from its release's `cosign_checksums.txt` and matched the downloaded binary
(2026-10-24). That checksums file's bundle first verified only by the v3.0.2 binary itself,
which proves nothing. On 2026-10-26 it verified with sigstore-python 4.5.1, a separate verifier
written in Python, not Go: `python -m sigstore verify identity --bundle
cosign_checksums.txt.sigstore.json --cert-identity
keyless@projectsigstore.iam.gserviceaccount.com --cert-oidc-issuer
https://accounts.google.com cosign_checksums.txt` printed `OK`, and the verified file's
`cosign-linux-amd64` line equals `COSIGN_SHA256` and the downloaded binary's sha256.

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

`just vm-qualify` runs `qualify.sh local`, G4 for a local build. It takes the image that
`just vm-image` just built, installs it on a disk laid out like the laptop (ESP, ext4
`/boot`, btrfs root), boots it with UEFI, and requires:

- a running system, a green `apex-boot-assess`, a disarmed boot counter, the expected
  booted digest and a working `apexctl status --json`, after every boot that is meant
  to stay up;
- `bootloader-update.service` run after the assessment of every green boot, and in no
  red one;
- the counted rollback: the guest derives a newer image from the booted one (its
  manifest version plus `.1`), stages it, forces it red and applies it; it must reboot
  itself 3 times, GRUB must fall back, and the image under test must roll it back;
- GDM's greeter, once the user `apexqa` exists (made only in the guest);
- the login of `apexqa` through GDM's greeter: its password, made for the run, is typed
  over QEMU's QMP socket (a Unix socket in `_build/qualify/qmp/`); the Apex layer arms
  its crash guard and logs no failure, `color-scheme` is `'default'`, and no Apex user
  unit runs;
- `loginctl lock-session` and an unlock by the password typed into the unlock dialog,
  then a second lock and `loginctl unlock-session`: each time gnome-shell's
  `LockedHint` and `org.gnome.ScreenSaver` follow, the shell survives, and it logs no
  `JS ERROR` from lock to unlock; no failed user unit;
- polkit through the shell's agent (S3b, board 13): `apexqa`, made an administrator
  (`wheel`), runs `pkexec /usr/bin/id -u` from its user manager. The shell's dialog must
  open (a `polkit-agent-helper-1` conversation, screendumped), refuse a wrong password
  (polkitd logs it) and ask again while pkexec waits, end pkexec with 126 on Esc, and
  take the password, after which pkexec prints 0 and exits 0. When the pinned apex-gnome
  lists the `polkit` feature, the session must have logged `Apex: feature polkit enabled`
  (the Apex dialog); otherwise the rows note the pin;
- the polkit actions G1 parsed: `pkaction --action-id ID --verbose` on the booted guest
  must know every action in `io.github.apex-linux.*.policy` and name the vendor Apex,
  which the dialog's details show (`local-polkit-actions`);
- the crash guard: a login with `APEX_SHELL_TEST_FAULT=abort-after-enable` in
  `apexqa`'s `~/.config/environment.d/` aborts the shell, `apex-shell-safe.service`
  turns the layer off, and the next login runs in safe mode, where the stock polkit
  dialog still takes the password (`local-safe-polkit`), and the safe login never logged
  `Apex: feature polkit enabled`.

The bootloader rows prove the order after the assessment and the green-boot condition
(the fallback boot's row); in the builder VM `bootupctl` finds no update, so they
exercise no ESP write. The safe-mode login's row checks the log line, `layer-enabled` and
that no `JS ERROR` is logged; G2's guard phase `next` proves that such a start loads
upstream's sheet.

`logs/` keeps a screendump of every password prompt and of the unlocked session. A pass
with no SKIP or WARN row records the image's G4 key, the time and the image ID in
`~/apex-image/_build/g4-passed.txt`, which `just vm-image` compares against. The
results are in `~/apex-image/_build/qualify/` (`results.md`, `logs/`). Each row of
`results.md` is `| test | result | detail | layer feature |`: the feature of the pinned
apex-gnome that gates it (`lock`, `motion`, `polkit`) and whether the session enabled it,
the pin does not list it (the row passes with that note) or safe mode turned it off; `-`
for an ungated row. vm.yml's summary prints the same table. The nested
guest gets 3 GiB of RAM; the run takes seven boots, about 20 minutes.

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

It refuses an image that has passed no G2 in the builder VM: neither
`_build/gates-passed.txt` nor a passed `_build/g2/*/result.txt` names its ID.
`APEX_DESKTOP_UNGATED=1` takes it anyway, with a warning. Each desktop VM's install
writes to its own directory under `_build/desktop/` in the builder VM, so two installs
never share a disk or a key.

To install a newer build over an existing VM, run `just desktop-install --replace`. It
discards the old disk and everything you did in it. While an install runs, `just desktop`
refuses to start.

The first boot runs `gnome-initial-setup`, where you create your user. The Flathub apps
install in the background.

**How it differs from a laptop install** ([INSTALL.md](https://github.com/apex-linux/apex/blob/main/docs/INSTALL.md))

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
| `just desktop-update [IMAGE]` | Stages the last `just vm-image` build in the running guest, keeping `/var/home` and `/etc` (below). |
| `just shell-dev`, `just shell-c` | The shell's dev loop in this VM, from the apex-gnome checkout `APEX_GNOME_SRC` (default `../apex-gnome`; [desktop/README.md](https://github.com/apex-linux/apex-gnome/blob/main/desktop/README.md#the-dev-loop)). |

The shell uses a key made for this VM. sshd is forwarded on `127.0.0.1:2223` only. A
running VM is reached on the port it was started with, which `desktop-vm.sh` records in
the VM directory, whatever `APEX_DESKTOP_SSH_PORT` says later.

**Which VM a command targets**

Every recipe that targets a desktop VM takes its directory from `APEX_DESKTOP_DIR`
(default `~/.local/share/apex/desktop`, the owner's VM) and prints it before it changes
anything:

```
[desktop-vm] target: the owner's desktop VM in /home/you/.local/share/apex/desktop, ssh 127.0.0.1:2223
```

Every command but `running` refuses the owner's VM when stdin is not a terminal (a
script) or `CLAUDECODE` is set (an agent), unless `APEX_DESKTOP_THROWAWAY` is set;
`APEX_DESKTOP_THROWAWAY=0` names the owner's VM on purpose. A VM is running only when a
QEMU of this name was started with this directory's pidfile, so a stale pidfile never
adopts another desktop VM's QEMU.

Tests and agents work on a throwaway VM with `APEX_DESKTOP_THROWAWAY=1`. It refuses the
owner's directory, the owner's SSH port (2223, or the port the owner's VM last started
with), and every directory without the `throwaway` marker. Only `install` into a
directory with no disk yet creates the marker:

```bash
export APEX_DESKTOP_THROWAWAY=1 APEX_DESKTOP_DIR=$HOME/.local/share/apex/desktop-throwaway APEX_DESKTOP_SSH_PORT=2231
just desktop-install && just desktop     # window title: "QEMU (Apex desktop (throwaway))"
just desktop-update
tools/builder-vm/desktop-vm.sh destroy --yes
```

**Image changes without a reinstall**

```bash
just vm-image          # build the image in the builder VM
just desktop-update    # stage it in the running desktop VM (about 2 minutes for a 3.3 GB image)
```

`just desktop-update [IMAGE]` (default `localhost/apex:build`):

1. Refuses a guest whose `/usr/lib/os-release` does not say `VARIANT_ID=apex`, and prints
   the booted image and digest.
2. Starts the builder VM if it is not running, and stops it again afterwards. Both VMs
   then run at once.
3. Refuses an image without the labels `containers.bootc=1` and
   `org.opencontainers.image.source=https://github.com/apex-linux/apex-image`, an
   image that has passed no G2 (as `desktop-install`; `APEX_DESKTOP_UNGATED=1` takes it
   anyway), and a guest with less than twice the image's size plus 2 GiB free in `/var`.
4. Streams `sudo podman save --format oci-archive` in the builder VM into `podman load`
   in the guest, over both VMs' ssh, and tags the loaded image ID as `IMAGE`.
5. Runs `bootc switch --transport containers-storage IMAGE`, or `bootc upgrade` when the
   guest follows that image already. Nothing changes until the guest restarts. bootc
   keeps `/var`, so `/var/home` too, and merges the guest's `/etc` changes.
6. Prints the old (booted) and new (staged) digests, and how to boot it and roll back:
   `just desktop-ssh 'bootc rollback && systemctl reboot'` after that boot brings the
   old digest back.

Afterwards the guest follows `localhost/apex:build` in its own container storage, and
the switch does not pass `--enforce-container-sigpolicy`. `apex-updated` checks updates
against the Apex signature policy, which has no `containers-storage` scope, so its checks
should fail, as they do for `apex-testing:45` until CI publishes it. The boot assessment
of such a boot warns `image-source: fail` and still reports the boot green.
`just desktop-install --replace` returns to a fresh install.

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
| `APEX_DESKTOP_THROWAWAY` | `0` (`1`: only a throwaway VM, above) |
| `APEX_DESKTOP_UNGATED` | `0` (`1`: install or update with an image that has passed no G2) |
