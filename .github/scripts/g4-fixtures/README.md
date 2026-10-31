# G4 fixtures: spans of real guest journals

`selftest.sh` ("G4 against real guest journals") feeds these spans to the fake guest's state files.
qualify.sh's own functions then read the guest's real lines, not invented ones. Each span comes
from the `vm-logs-<sha>` artifact of a `vm.yml` run.

| File | Run (vm.yml run id, commit) | Source in `qualify-logs/` | Lines | Fed to |
|---|---|---|---|---|
| `run6-boot.mono` | 6 (40548525656, 43094ed) | `local-failure.journal.txt` | 1300-1710 | `boot_metrics`: the greeter, no user shell yet |
| `run13-boot.mono` | 13 (40640617144, 073bc67) | `local-local-lock-esc.journal.txt` | 1300-2560 | `boot_metrics`: the greeter to the user's shell |
| `run13-analyze.txt` | 13 | the same, PID 1's `Startup finished` line | | `systemd-analyze` |
| `run7-red-boot.assess` | 7 (40548575341, 87354a4) | `local-failure.journal.txt`, `apex-boot-assess` lines | | `forced_red_boots`: red without the hook |
| `run8-red-boot.assess` | 8 (40573708585, 4e33b53) | `local-failure.journal.txt`, `apex-boot-assess` lines | | `forced_red_boots`: red without the hook |
| `run16-forced-red-boot.assess` | 16 (41038614559, 5197371) | `local-fallback.assess-all-boots.txt`, its second boot | 36-68 | `forced_red_boots`: forced red |
| `run16-greeter.manager` | 16 | `local-settled-greeter.manager.journal.txt` | all | `assert_greeter` |
| `run11-login.journal` | 11 (40626417109, 0380e70) | `local-login.journal.txt` | all | `assert_apex_login` |
| `run13-lock-esc.journal` | 13 | `local-local-lock-esc.journal.txt`, `gnome-shell[1935]` | 3103-5464 | a lock row's JS ERROR detail |
| `run16-lock-blank-wake.journal` | 16 | `local-local-lock-blank-wake.journal.txt`, `gnome-shell[1943]` | all | blank and wake, with neither lock line |

Runs 7 and 8 failed the same row: an armed boot reported red and did not reboot itself. Neither
red came from the qualification hook, so neither counts as forced red.

Formats follow what the fake guest serves:
- `.mono`: `SECONDS UID MESSAGE`. The UID is the user of the PID that logged the line: the
  greeter's manager and shell are 60578, and the user's are 1000. Every other PID is 0, audit
  lines too.
- `.journal`, `.assess`: `journalctl -o cat` lines. `.assess` also drops the
  `apex-boot-assess[PID]:` prefix.
- `.manager`: `journalctl -o short-monotonic` lines.

Scrubbed before committing, by the script that cut them:
- the guest's host names (`apex`, and `apex-builder` that DHCP gave it) are `guest`;
- the test user's name is `@TEST_USER@`, which selftest replaces with qualify.sh's `TEST_USER`;
- 32-hex machine and boot IDs, and filesystem UUIDs, are zeros;
- IPv4 addresses are `192.0.2.1`, and MAC addresses `02:00:00:00:00:00`;
- every line is cut to 300 characters.

`g4-fixtures-check.sh`, which selftest runs, holds every file here to that and more. Each file
needs a row above and a selftest line that reads it. No line may hold a host name but `guest`, a
user name but `root`, `gdm`, `gdm-greeter` and `@TEST_USER@`, a machine, boot or filesystem ID, an
IPv4, IPv6 or MAC address but the ones above, an email address or a serial number. It decodes
audit's `proctitle=` hex and checks that too.

No password reaches a journal. The image digests (64-hex sha256) stay: they name builds, not people.
apex-ci's privacy guard passes over these files.
