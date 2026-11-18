# Additions for the virtual machine test only (just vm-install): they make
# the install unattended on the empty virtual disk vda and let the test log
# in over SSH. Never used for the USB stick.
ignoredisk --only-use=vda
clearpart --all --initlabel --drives=vda
autopart
lang en_US.UTF-8
keyboard us
# No --utc: the test must show that the clock ends up in UTC anyway, as
# it must for the owner, whose kickstart names no zone.
timezone UTC
services --enabled=sshd
poweroff
