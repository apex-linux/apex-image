#!/bin/bash
# Explains in plain words why the Apex installer stopped when it cannot find
# the media it was started from. Sourced by the dracut hooks in this initrd,
# where dracut-lib.sh provides warn and getarg.

apex_media_missing() {
  if [ -e /dev/root ]; then
    return 0
  fi
  local stage2
  stage2="$(getarg inst.stage2=)"
  warn "################ Apex installer: media not found ################"
  warn "The installer started, but cannot find the USB stick or disc it"
  warn "was started from. It looks for: ${stage2#hd:}"
  warn "If the ISO is on a Ventoy stick, update Ventoy to 1.1.18 or newer."
  warn "Otherwise write the ISO directly to a USB stick, with GNOME Disks"
  warn "(Restore Disk Image) or dd, as the apex-image README explains:"
  warn "https://github.com/apex-linux/apex-image#install-on-a-computer"
  warn "Type poweroff, or hold the power button, to switch off."
  warn "#################################################################"
}
