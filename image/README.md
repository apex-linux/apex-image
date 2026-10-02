# Image

The Containerfile, package lists, build checks and rootfs overlay (`system_files/`) of
the Apex image. The design is in [ARCHITECTURE](../docs/ARCHITECTURE.md) (delivery
model, build and publish, package policy); `.github/scripts/image.sh` builds it. This
file keeps the reasons the files themselves are too terse to carry.

## Containerfile

The repos stage:

- rpm-ostree's libdnf does not read dnf5's `repos.override.d`, so updates-testing is
  disabled in the repo files themselves.
- `[apex]` has priority 1, which beats version. Its `includepkgs` keeps a stray RPM in
  `rpms/` from replacing the signed Fedora package of the same name.
- `[apex-gnome51]` gets the Fedora excludes only after its own check, which must see
  the pinned builds.
- Each pin in `packages/updates-testing-allowlist.txt` is settled against `fedora` and
  `updates` first: updates-testing kept listing the builds of FEDORA-2026-48a7996f9c
  for days after Bodhi pushed it stable (seen 2026-10-02), so a build still being there
  says nothing. A pin the stable repositories carry at the same or a newer version is
  reported for removal; when that is every pin, `[apex-gnome51]` is dropped. A pin
  that is in neither place fails the build. That query clears `excludepkgs` of `fedora`
  and `updates`, or a pin of a name the lane locks (gnome-shell, mutter) would look
  missing there.
- An NVR carries no epoch. A pin is compared with the stable build of its name with
  the stable epoch on both sides; Fedora never lowers an epoch.
- The allowlist only offers a build. A pinned build whose requirements are not offered
  too is passed over without an error, and the compose installs the stable build of
  that name. `epiphany-runtime-51.0-2.fc45` and `gnome-control-center-51.0-2.fc45`
  need `libxml2.so.16`, which was never pinned: the stage admitted them, and the image
  of 2026-09-29 carried `epiphany-51~rc-1.fc45` and
  `gnome-control-center-51~rc.1-1.fc45`.

The final stage:

- A preset cannot undo an enablement symlink under `/usr`, so the auto-rebooting
  `bootc-fetch-apply-updates.timer` loses its symlink and is masked.
- The schema cache is compiled without `--strict`, so an upstream override for a
  schema that is not installed cannot break the build. Only the Apex override must
  pass `--strict`.

## Package lists

One package per line; `#` starts a comment. Weak dependencies are off, so the image
relies only on what is listed or hard-required by something listed. The minimal
manifest already has the kernel, systemd, bootc, ostree, bootupd, dnf, SELinux and
dracut. A GTK3 package also needs an entry in `audit/legacy-allowlist.txt`, which
records its reason.

`packages/base.txt`:

| Entry | Why |
|---|---|
| the four firmware packages | `hardware/m7400qc/profile.toml` `[firmware].packages`; `iwlwifi-mvm-firmware` hard-requires `iwlbluetooth-firmware` (AX200 Bluetooth) |
| no `alsa-sof-firmware` | the internal mic is the ALC294 DMIC, not the Cezanne ACP |
| `cryptsetup` | the admin and recovery tool for the LUKS2 root; its `cryptsetup-libs` is what `systemd-cryptsetup` loads |
| `systemd-udev` | ships `/usr/bin/systemd-cryptsetup` on F45 |
| `plymouth-system-theme` | resolves to `plymouth-theme-spinner`, which also carries the bgrt (firmware logo) theme |
| `exfatprogs` | exFAT formatting from Disks and Files; udisks2 only recommends it |
| `wpa_supplicant` | NetworkManager-wifi accepts wpa_supplicant or iwd; this names the tested one |
| `chrony` | the minimal manifest has no NTP client |
| `pipewire-gstreamer` | pipewiresrc and pipewiresink: Snapshot's camera and screen casting |
| `alsa-utils` | the ALC294 procedures in `docs/hardware` use amixer, alsactl and alsamixer |
| `tuned-ppd` | provides ppd-service, the power-profiles D-Bus API GNOME uses |
| `fwupd-efi` | the signed EFI helper for capsule updates through shim |
| `p11-kit-server`, `skopeo` | weak dependencies of toolbox worth keeping: host CA trust and image inspection |
| `cracklib-dicts` | libpwquality only recommends it, and its dictionary check fails without it |
| `libcanberra-backend-pulse` | libcanberra only recommends a backend; without one, event sounds are silent |
| `fedora-release-identity-basic` | fedora-release only recommends an identity; naming one keeps the compose deterministic |
| `tar` | not in the minimal manifest; the install runbook backs up the ESP with it. `passwd` needs no entry: shadow-utils ships it |
| `systemd-oomd-defaults` | without these drop-ins systemd-oomd manages nothing |

`packages/gnome.txt`:

| Entry | Why |
|---|---|
| `gnome-bluetooth` | a weak dependency of gnome-shell: the Bluetooth quick setting and panel |
| `gnome-online-accounts` | the backend of gvfs-goa and of Calendar and Contacts sync |
| `oo7-daemon`, `pam_oo7`, `oo7-portal` | oo7 replaces gnome-keyring on F45 |
| `adwaita-sans-fonts`, `adwaita-mono-fonts` | gsettings-desktop-schemas only weakly requires them |
| `default-fonts-*` | fontconfig's generic families, for web content and non-GTK4 clients |
| `m17n-db` | `vi-telex.mim`, for `m17n:vi:telex` |
| `mesa-dri-drivers` | also provides the VA-API drivers (radeonsi) on F45 |

`packages/exclude.txt`:

| Entry | Why |
|---|---|
| `xorg-x11-server-Xorg`, `xorg-x11-drv-*` | Xwayland stays; the Xorg server never ships |
| `PackageKit*`, `gnome-software*` | package managers do not belong on an image-based OS |
| `gnome-keyring*` | oo7 replaces gnome-keyring |
| `greenboot*` | apex-boot-assess replaces greenboot |
| `gnome-terminal` to `gnome-color-manager` | GTK3 applications with GTK4 replacements |
| `gtk2`, `ibus-gtk2` | GTK2 has no Wayland backend; ibus has only `(ibus-gtk2 if gtk2)` |
| `power-profiles-daemon` | tuned-ppd provides ppd-service; excluding the other provider keeps the choice deterministic |

A name F45 no longer has, such as cheese, guards nothing here, so
`checks/legacy.sh` bans it by name.

## Checks and tests

Each `checks/*.sh` sources `checks/lib/common.sh` after `set -eu` and `CHECK_NAME`,
prints one PASS, FAIL, WARN or SKIP line per assertion, and ends with `finish`, which
exits 1 on a FAIL. The final stage runs them with `sh`.

Each `tests/t-*.sh` sources `tests/lib.sh`, writes only under `$T` (removed on exit),
and ends with `done_testing`; the output is TAP. `tests/run.sh --help` shows how to run
them.
