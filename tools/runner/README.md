# Self-hosted runner for `vm.yml`

`apex-linux/apex-image`'s `.github/workflows/vm.yml` builds the image in the builder VM
([../builder-vm/README.md](../builder-vm/README.md)) from GitHub. The workflow runs on a
self-hosted runner on the host that runs the builder VM. That runner reaches the VM in
exactly one way: an SSH key that the VM's `authorized_keys` binds to `ci-build <sha>`.

```
GitHub ── JIT config ──▶ runner.sh once (systemd user service)
                           └─ rootless podman container, one job, then removed
                                └─ ssh apex-builder ci-build <sha>   (127.0.0.1:2222 only)
                                     └─ builder VM: fetch main, check out <sha>, build-image.sh,
                                        promote the lane lock; a tar of the results on stdout
```

## What it guarantees

| Property | How |
|---|---|
| A fresh runner for every job | `runner.sh once` asks GitHub for a just-in-time (JIT) runner config, which is valid for one job, and runs the runner in a new rootless podman container (`--rm`, all capabilities dropped, `no-new-privileges`). The container is removed when the job ends. `apex-runner.service` then starts the next one, so one runner is always waiting. |
| Only `vm.yml` on `main` gets the runner | The runner group `apex-kvm` serves only `apex-image` and only the workflow `apex-linux/apex-image/.github/workflows/vm.yml@refs/heads/main`. `vm.yml` has no `pull_request` trigger, and each of its jobs checks the repository and `refs/heads/main`. |
| The runner can only build `main` | The container mounts a key whose `authorized_keys` line is `restrict,command="/usr/local/libexec/apex/ci-build"`: no shell, no pty, no forwarding. `ci-build` accepts only `SSH_ORIGINAL_COMMAND` = `ci-build` plus 40 lowercase hex digits, and optionally the word `daily` (the scheduled run's absorption report and size metrics). It matches that against a regular expression and never evaluates it. After a fetch it refuses a commit that `origin/main` does not contain. |
| The RPM key and the store stay in the VM | `ci-build` returns only a tar of the result files: `ci-build.txt`, `gates-passed.txt`, `g2-result.txt`, `g4-results.md`, `g4-passed.txt`, `lock.diff`, G4's logs and, on the daily run, `absorb/`. `~/.local/share/apex/rpm-gnupg` and `~/apex-store` never leave the VM. |
| Nothing is published | No registry push, no image signing: that waits for the cosign keys (S1d). The workflow token has no permissions (`permissions: {}`), and the job uses no actions. |
| The container reaches only the VM's sshd on the host | Its network is pasta with only `127.0.0.1:2222` forwarded to the host's loopback, and `--no-map-gw`. `runner.sh check` tests this. |
| Builds never overlap | `ci-build`, `builder-vm.sh sync`, `run` and `image` all take `~/.apex-build.lock` in the VM. A CI build waits up to 30 minutes for the lock, then exits 75. `just vm-sync` refuses while a CI build runs. |

## The token

The host keeps one token, in `~/.config/apex/runner/token` (mode 0600). It is used for
three things only: creating and checking the runner group, asking for a JIT config per
job, and deleting a JIT runner that never got a job. Make a **fine-grained personal
access token**:

| Field | Value |
|---|---|
| Resource owner | `apex-linux` (the organisation must allow fine-grained tokens, and may have to approve this one) |
| Expiration | the shortest you will renew; 90 days is a reasonable choice |
| Repository access | Only select repositories: `apex-image` (this adds Metadata: read-only, which `runner.sh group` needs for the repository's id and visibility) |
| Repository permissions | none |
| Organization permissions | **Self-hosted runners: Read and write**, nothing else |

This is the smallest scope GitHub accepts for org-level JIT runners and runner groups.
A repository-level runner would need **Administration: write** on the repository, and
it could not be restricted to one workflow. The job itself gets no token permissions,
and the runner container never sees this token.

## Setup, one command per step

On the host that runs the builder VM, as your normal user, from a checkout of
`apex-image`. You need podman 4.4 or later (rootless, with pasta), curl, jq, ssh-keygen
and a systemd user session:

- Ubuntu 24.04 or later: `sudo apt install podman passt uidmap curl jq openssh-client`
- Fedora: `sudo dnf install podman passt curl jq openssh-clients`

Run the preflight first. It changes nothing, prints one PASS, FAIL or SKIP row per check
and exits 1 on any FAIL: `/dev/kvm`, nested KVM, rootless podman with pasta, subuid and
subgid ranges, cgroup v2, disk for the builder VM (45 GiB build, 25 GiB kernel scratch,
15 GiB ccache), RAM and threads for `APEX_VM_MEM` and `APEX_VM_CPUS`, HTTPS to GitHub,
ghcr.io, Fedora and the COPR, the runner's key and its forced command once they exist,
that the runner knows the builder VM's current host key (a VM made again after
`builder-vm.sh destroy` has a new one: `just runner key`), and time sync. Fix every FAIL, then go on with step 1.

```bash
just runner-preflight
```

1. Make the token above and store it:

   ```bash
   mkdir -p ~/.config/apex/runner && (umask 077 && cat >~/.config/apex/runner/token)   # paste, then Ctrl-D
   ```

2. Create the runner group and check its settings:

   ```bash
   just runner group
   ```

   It prints the settings to click wherever the API cannot set them. Some must always
   be set by hand, because the token has no administration rights:
   - **Organisation > Settings > Actions > General:** fork pull request workflows from
     outside collaborators require approval.
   - **Repository > Settings > Environments:** a `vm-dispatch` environment, with you as
     required reviewer and deployments limited to `main`.

   If the organisation's plan does not offer workflow access for runner groups, the
   command says so and exits 1. The group then still serves `apex-image` only, and
   the forced command still limits a job to building commits of `main`.

3. Make the runner's SSH key and its `known_hosts` entry. The builder VM must have been
   started once from this host (`just vm-start`), so that its host key is known.

   ```bash
   just runner key
   ```

4. Install `ci-build` in the builder VM and bind the key to it. The VM must be running.

   ```bash
   just vm-ci-install
   ```

   While `apex-image` is private, the VM also needs read access to fetch `main`. Add a
   read-only deploy key of the VM to the repository, then set its URL with
   `just vm-ssh "echo APEX_CI_REMOTE=git@github.com:apex-linux/apex-image.git >~/.config/apex/ci.env"`.
   Once the repository is public, the default HTTPS URL needs nothing.

5. Build the runner image. It pins actions/runner 2.338.0 by SHA-256.

   ```bash
   just runner image
   ```

6. Check the path from a throwaway container. `ci-build` must answer and refuse an
   empty request, and the desktop VM's port 2223 must be unreachable. Start the desktop
   VM first (`just desktop`) for that probe to mean something.

   ```bash
   just runner check
   ```

7. Install and start the service:

   ```bash
   just runner install
   sudo loginctl enable-linger "$USER"   # only if install says so: keeps it running without a login
   ```

`just runner status` shows the service, the waiting container and the group's runners.
`just runner uninstall` stops and removes the service and keeps the token, the key and
the image.

### Confirm on the first G4

The selftest proves G4's lock matrix (S3b) against a fake guest only. On the first
dispatched run that runs G4, check in `_build/qualify/` that:

- [ ] **The password conversations count as expected.** While the lock asks, there is one
  `pam/gdm-password` worker more than with the session unlocked. There is none more while
  the screen is off (`local-lock-blank-wake`). Esc ends the extra one (`local-lock-esc`).
- [ ] **OVMF resumes from S3.** With `-global ICH9-LPC.disable_s3=0`, `systemctl suspend`
  reaches QMP's `suspended`, and `system_wakeup` brings the guest back
  (`local-lock-suspend`).
- [ ] **`rpm-ostree kargs --append=apex.safe=1` works on the bootc image.** The next
  boot has `apex.safe=1` in `/proc/cmdline` (`local-lock-safe`).

The selftest proves the LUKS2 rehearsal (`just vm-qualify-luks`) against a fake serial
console and QMP only. On its first run, check in `_build/qualify/` that:

- [ ] **systemd's status lines reach ttyS0.** With `rd.systemd.show_status=true` after
  `rhgb quiet`, the initrd prints `Starting … Cryptography Setup for` and `Finished …`
  on the serial console (`local-luks`).
- [ ] **QMP's keys reach Plymouth's prompt.** The screendumps show the prompt, and the
  typed passphrase opens the disk.
- [ ] **The retry after a wrong passphrase** comes back within 3 polls
  (`local-luks-wrong`).
- [ ] **`cp --reflink` works across subvolumes** on the builder VM's btrfs (§8's `/var`
  move in `install_luks`).
- [ ] **G4's boot metrics have their markers.** `boot.tsv` has all five `systemd-analyze`
  phases, and `greeter` and `desktop`: gnome-shell still logs "GNOME Shell started at",
  and the test user's first "session opened for user" line is the greeter's login.
- [ ] **The counted rollback runs through LUKS2.** Each armed boot and GRUB's fallback
  to the previous deployment ask for the passphrase and open the root with it
  (`logs/local-attempt1-luks-prompt.png` … `logs/local-fallback-luks-prompt.png`).

### Confirm on the first publish

The selftest proves `just publish` against a fake registry, and `just publish-rehearsal`
against a throwaway one. On the owner's first real `just publish` (S1d), check that:

- [ ] **cosign authenticates to ghcr.io in the builder VM.** `cosign sign` pushes the
  `.sig` tag with the credentials skopeo uses (`REGISTRY_AUTH_FILE`), or with a login of
  its own that the run then names.
- [ ] **An older image finds the new `:45`.** A VM booted from the previous published
  digest runs `apexctl update check`, which finds the new `apex:45` and verifies it
  against the image's own policy (S1d's exit).

### Confirm on the first lane rehearsal

Run `just lane-rehearsal` only after the owner's decision on negativo17's key: it
builds and verifies against the pinned `negativo17_key`. The selftest proves it on a fake
lane, image.sh and COPR only. On its first run, check `~/apex-rehearsal/report.md` and that:

- [ ] **The previous COPR build is still there.** The COPR keeps 5 builds; the good pair
  is built at the one before the pinned one, mirrored and checked against the COPR key.
- [ ] **kernel-bump commits the point bump unattended.** Its tag verifies and its config
  holds no change beyond new symbols (`logs/kernel-bump.log`).
- [ ] **pair.sh's hook takes the real kmod-failure path.** `APEX_PAIR_FAULT=kmod` leaves
  `kernel.lock` and the kernel RPMs, and the lane holds with `side=kmod` and a limit.
- [ ] **The degraded=nvidia image passes G1**, and its labels say `degraded=nvidia`.
- [ ] **The RPMs carry `.apex9001` and up**, and the lane's own store has no `N ≥ 9000`.

## Upkeep

- **The runner release.** GitHub stops serving runners that are too old. When it
  requires a newer release, a JIT runner updates itself inside its container, and then
  the pin no longer applies. Bump `RUNNER_VERSION` and `RUNNER_SHA256` in `runner.sh`,
  then run `just runner image` and `systemctl --user restart apex-runner`. Take the
  SHA-256 from the release page's `actions-runner-linux-x64` line. The pinned value was
  computed from the downloaded tarball and not cross-checked against the release page
  (2026-10-23); compare it once before the first install.
- **The token** expires. Replace the file. The service reads it for every job.
- **Revoking.** Delete the `apex-ci` line from `~builder/.ssh/authorized_keys` in the
  VM, or rerun `just vm-ci-install` with a new key from `just runner key` after you
  delete `~/.config/apex/runner/ssh/`.

## Troubleshooting

- **`ci-build stale` warning.** The builder VM runs the copy of `ci-build` that
  `just vm-ci-install` installed in `/usr/local/libexec/apex/`, never the checkout's: a
  forced command that updated itself from `main` would let any commit rewrite it. When
  `main` changes `tools/builder-vm/ci-build.sh`, the next run warns, and a request the old
  copy does not know (such as the daily run's `daily`) is refused with exit 2. Fix:
  `just vm-ci-install` with the VM running, from a checkout of current `main`.

## What a run does

`vm.yml` runs on a push to `main` that touches `components.lock`, `image/**`,
`crates/apex-lane/**` or `tools/**`, once a day, and on `workflow_dispatch`. A dispatch
with a `sha` input builds that commit of `main` instead of the head, and needs the
`vm-dispatch` approval first.

The build step calls `ssh apex-builder ci-build <sha>`, with workflow commands stopped
for the VM's log. In the VM, `ci-build` then:

1. fetches `main` from `APEX_CI_REMOTE` (in `~/.config/apex/ci.env`, read as data);
2. checks the commit out in `~/apex-image`, with `git clean -ffdx` keeping only
   `_build/`;
3. runs `tools/components.sh fetch` once the repository has it (the components hook);
4. runs `build-image.sh`: the RPMs, libfprint, the rebuild lane, the image, G2 twice,
   G4 when `qualify.sh g4-due` says it is due, and `_build/gates-passed.txt`;
5. runs `lane.sh promote` when the gates passed and `rpms.lock.next` differs from
   `rpms.lock`;
6. on the daily run only (`ci-build <sha> daily`), runs `lane-absorb-report.sh`
   whatever the build's result: does each lane series apply at fuzz 0 to the newest
   F45 stable and updates-testing SRPM? It never changes the exit status.

The gates step writes the results to the job summary. It fails when there is no gates
file. The artifact `vm-logs-<sha>` holds the logs the run returned, and is kept 14 days:

| Directory | When | Size |
|---|---|---|
| `qualify-logs/` | G4 ran | G4's screendumps, journals and serial logs: each file at most 20 MiB, 200 MiB in all; `SKIPPED` names what was left out |
| `absorb/` | the daily run | the absorption report: `report.md`, `rows.tsv`, `warnings.tsv` and each SRPM's `logs/`, under the same caps |
| `metrics/` | every run | `metrics.tsv` (this build), `history.tsv` (the last 30) and `warnings.tsv` |

**Metrics** (S4's daily-driver budget, `tools/builder-vm/metrics.sh`) are warning-only. The
thresholds are a starting point, to tune after the first real runs:

| Metric | Source | Warns when |
|---|---|---|
| Size, layers, new bytes | the daily run only, the build that publishes: `image.sh rechunk` when the gates passed, against the published `apex:45`: the compressed config and layers, and the bytes of layers `apex:45` lacks (what an update downloads) | the size grows more than 15 % and `lock.diff` changes no family |
| firmware, loader, kernel, initrd, userspace | G4's login boot on the default layout: `systemd-analyze` (`logs/boot-blame.txt` has `blame`'s top 10) | userspace is more than 20 % above the last green build's |
| greeter | the same boot: the journal's first "GNOME Shell started at", seconds from the kernel | more than 20 % above the last green build's |
| desktop | the first "session opened for user" of the test user to its own shell's "GNOME Shell started at" | (shown only) |

The builder VM keeps the rows in `~/apex-store/metrics.tsv`, so the trend survives each
run; the job summary shows the last 10. The rechunk adds a few minutes to the daily run
only, so push builds stay fast.

The absorption report also joins the summary, with a warning for each family whose
updates-testing build does not take its series with `git apply`. The selftest runs
vm.yml's Commit, build and gates steps, taken from the workflow itself, against a fake
`ssh` and canned results: a green build, a red one, a busy VM (75), a refused commit
(2), an empty tar and a daily run with warnings.

The CI build uses the VM's one checkout, `~/apex-image`, its `_build/` and the VM's
image storage. After a CI run, that checkout holds the commit of `main` and
`localhost/apex:build` is that commit's image. The next `just vm-sync` replaces both
with your working tree. Nothing on the host is lost, because the host's tree is the
source.
