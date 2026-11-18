# The Apex Linux installer's kickstart, embedded in Fedora's netinst ISO by
# scripts/iso.sh. It only names what to install: the rolling image, which
# the installed system keeps following with `bootc upgrade`. It deliberately
# has no storage commands, so Anaconda stops and asks for the target disk;
# it never selects or erases a disk on its own. Language, keyboard, time
# zone and the user account are asked for too, the user at first boot by
# GNOME Initial Setup.
#
# Root stays locked: the first user, made by GNOME Initial Setup or in the
# installer, is the administrator.
rootpw --lock

# Boot to the GNOME greeter, whichever installer mode was used.
xconfig --startxonboot

# Signature verification comes with signed images (M3).
ostreecontainer --url=ghcr.io/apex-linux/apex:main --transport=registry --no-signature-verification

# Anaconda deploys the image with ostree, which picks its boot loader
# backend by looking for any EFI/*/grub.cfg on the EFI system partition.
# Beside another Linux it finds that system's grub.cfg, runs grub2-mkconfig
# inside the installer and fails. bootupd owns the boot loader of a bootc
# system, so ostree only writes boot entries, as `bootc install` sets it up.
# The setting stays in the repository, so later upgrades behave the same.
%pre-install --erroronfail
set -eu
repo=/mnt/sysimage/ostree/repo
mkdir -p "${repo}"
ostree --repo="${repo}" init --mode=bare
ostree config --repo="${repo}" set sysroot.bootloader none
%end

# The computer's name, until the user changes it on Network & Host Name.
network --hostname=apex

%post --erroronfail
set -eu
# Keep the hardware clock in UTC, as Linux systems on the same computer
# expect. Without a zone in the kickstart the installer keeps it in local
# time, and a dual-booted system then reads a clock off by the zone's
# offset; "timezone --utc" without a zone makes Anaconda 45 fail, and a zone
# here would skip the Time & Date screen. The system clock is right at this
# point, so write it back as UTC.
printf '0.0 0 0.0\n0\nUTC\n' >/etc/adjtime
hwclock --systohc --utc || echo "Could not write the hardware clock"
# bootc mounts the root file system, a composefs overlay, from the kernel
# command line. A / line in fstab, which the installer writes, makes
# systemd-remount-fs fail on every boot ("No changes allowed in
# reconfigure"); bootc's own installs leave / out of fstab.
sed -i -E '/^[^#[:space:]]+[[:space:]]+\/[[:space:]]/d' /etc/fstab
# The installer names the Btrfs volume after itself (fedora_fedora).
# Btrfs takes its mount options from the first mount, which is the root
# file system from the kernel command line, so compression goes there too;
# the installer puts it only on the /home line of fstab, which no longer
# applies. The boot entry keeps the other root flags, such as the subvolume.
if [ "$(stat -f -c %T /)" = btrfs ]; then
  btrfs filesystem label / apex || echo "Could not relabel the Btrfs volume"
  flags="$(sed -n 's/^options .*rootflags=\([^ ]*\).*/\1/p' \
    /boot/loader/entries/*.conf | head -n 1)"
  ostree admin instutil set-kargs --merge \
    --replace="rootflags=${flags:+${flags},}compress=zstd:1" \
    || echo "Could not turn on Btrfs compression"
fi
%end
