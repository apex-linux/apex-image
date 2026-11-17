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
