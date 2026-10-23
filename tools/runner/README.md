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
| The runner can only build `main` | The container mounts a key whose `authorized_keys` line is `restrict,command="/usr/local/libexec/apex/ci-build"`: no shell, no pty, no forwarding. `ci-build` accepts only `SSH_ORIGINAL_COMMAND` = `ci-build` plus 40 lowercase hex digits. It matches that against a regular expression and never evaluates it. After a fetch it refuses a commit that `origin/main` does not contain. |
| The RPM key and the store stay in the VM | `ci-build` returns only a tar of the result files: `ci-build.txt`, `gates-passed.txt`, `g2-result.txt`, `g4-results.md`, `g4-passed.txt` and `lock.diff`. `~/.local/share/apex/rpm-gnupg` and `~/apex-store` never leave the VM. |
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
`apex-image`. You need podman (rootless, with pasta), curl, jq, ssh-keygen and a
systemd user session.

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
   `rpms.lock`.

The gates step writes the results to the job summary. It fails when there is no gates
file.

The CI build uses the VM's one checkout, `~/apex-image`, its `_build/` and the VM's
image storage. After a CI run, that checkout holds the commit of `main` and
`localhost/apex:build` is that commit's image. The next `just vm-sync` replaces both
with your working tree. Nothing on the host is lost, because the host's tree is the
source.
