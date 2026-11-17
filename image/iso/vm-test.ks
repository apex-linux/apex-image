# Additions for the virtual machine test only (just vm-install): they make
# the install unattended on the empty virtual disk vda and let the test log
# in over SSH. Never used for the USB stick.
ignoredisk --only-use=vda
clearpart --all --initlabel --drives=vda
autopart
lang en_US.UTF-8
keyboard us
timezone UTC --utc
services --enabled=sshd
poweroff
