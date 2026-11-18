# Additions for the dual-boot test only (just vm-dualboot): install into the
# free space of vda beside the partitions already there, as the owner does
# with automatic storage configuration and no space reclaimed. There is no
# clearpart, so nothing on the disk may be removed. Never used for the USB
# stick.
ignoredisk --only-use=vda
autopart
lang en_US.UTF-8
keyboard us
# No --utc: the test must show that the clock ends up in UTC anyway, as
# it must for the owner, whose kickstart names no zone.
timezone UTC
services --enabled=sshd
poweroff
