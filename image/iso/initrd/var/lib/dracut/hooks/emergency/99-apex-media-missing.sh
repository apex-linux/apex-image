#!/bin/bash
# A dracut hook: after the installer's wait for its media times out, and
# again at the emergency prompt, say in plain words what went wrong. The
# 99 prefix runs it after Anaconda's own report, so it is the last text on
# the screen.

# shellcheck source=/dev/null
. /usr/lib/apex/media-missing.sh
apex_media_missing
