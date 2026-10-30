# apex-image

The image of [Apex](https://github.com/apex-linux/apex), a Fedora 45 bootc desktop for
one laptop, the ASUS Vivobook Pro 14X OLED (M7400QC). This repository composes the image
from its components, gates it, and holds the builder VM and the pipeline that build it.

| Path | What it is |
|---|---|
| `image/` | The Containerfile, the package lists, the rootfs overlay and the build checks (G1) |
| `components.lock` | The commit of each component the image takes: apex-system, apex-desktop, apex-gnome and apex-kernel |
| `tools/components.sh` | Clones those commits into `_build/components/` and names them for the build |
| `crates/apex-lane`, `packaging/` | The rebuild lane: Fedora SRPMs rebuilt with the recipes of apex-gnome and apex-kernel, stored by content key and recorded in `rpms.lock` ([packaging/README.md](packaging/README.md)) |
| `tools/builder-vm/` | The Fedora 45 builder VM, the build, G2 and G4 (qualification), and the desktop VM ([README](tools/builder-vm/README.md)) |
| `tools/runner/`, `.github/workflows/vm.yml` | The self-hosted runner that drives the builder VM from GitHub ([README](tools/runner/README.md)) |
| `.github/scripts/` | The image, qualification and publishing scripts, and their self-test |
| `tests/devloop/` | The dev loop's host side against a fake ssh |

| Component | Gives the image |
|---|---|
| [apex-system](https://github.com/apex-linux/apex-system) | the `apex` RPM (`apexctl`, `apex-updated`, `apex-boot-assess`) and the machine profile's rendered files |
| [apex-desktop](https://github.com/apex-linux/apex-desktop) | the `apex-desktop` RPM: the Apex GSettings schema, the crash guard and the desktop data |
| [apex-gnome](https://github.com/apex-linux/apex-gnome) | the gnome-shell recipe with the Apex layer, and G2, the headless shell |
| [apex-kernel](https://github.com/apex-linux/apex-kernel) | the patched libfprint and the kernel lane's recipe |

The design is in the [apex](https://github.com/apex-linux/apex) repository:
[ARCHITECTURE §4](https://github.com/apex-linux/apex/blob/main/docs/ARCHITECTURE.md#4-build-and-publish),
[§11](https://github.com/apex-linux/apex/blob/main/docs/ARCHITECTURE.md#11-quality-gates)
and the [threat model](https://github.com/apex-linux/apex/blob/main/docs/THREAT-MODEL.md).

## Development

The image builds only in the builder VM; the development host needs a Rust toolchain for
`apex-lane` and `just`.

```bash
just check          # apex-lane: fmt, clippy -D warnings and the tests, as CI runs them
just image-test     # the image checks' tests (with the components fetched)
just vm-create      # once: the builder VM
just vm-image       # the components, the RPMs, the lane, the image, G4 when due, G2 twice
```

A change across repositories builds from a sibling checkout instead of the pinned commit:
`APEX_SRC_APEX_GNOME=../apex-gnome just vm-image`. Such a build is recorded as a
dev-override and never promotes the lane's lock; the change reaches the image when the
component's commit lands in `components.lock`.

`just image FEDORA=46` builds the next lane (roadmap S6) from `image/fedora/46.env`, its
own base and repos pins, never 45's. Its components build in Fedora 46, its lane lives in
`~/apex-store/next`, its state in `_build/next`, and the image is `localhost/apex:46`,
labelled `io.github.apex-linux.apex.lane=next`. It gates on G1 only and never promotes,
pushes or publishes: `lane.sh promote`, `image.sh push` and `publish.sh` refuse it. Until
Fedora 46 branches, `BASE_SOURCE=rawhide`: the base is a rawhide build, and the build
summary names its version label. Renovate tracks only `image/Containerfile`'s pins; the
46 digests move by hand.

CI (`ci.yml`) runs apex-lane's checks, shellcheck, actionlint, the self-test and the dev
loop's tests, the image checks' tests and the contracts against the pinned components,
and the privacy and comment guards of [apex-ci](https://github.com/apex-linux/apex-ci).
`vm.yml` builds and gates the image in the builder VM from `main`; nothing publishes the
image yet (roadmap S1d).

## Moving the builder VM to this repository (once)

A builder VM made from the monorepo keeps its checkout, `_build/` (the G4 record) and
`~/apex-store` under the old name. On the host that runs it:

1. `just vm-start`, then `just vm-ssh 'mv ~/apex-fedora ~/apex-image'`. The lane's store
   (`~/apex-store`) and the Apex RPM key stay where they are.
2. `just vm-sync` from a checkout of this repository: it replaces the VM copy's `.git`
   and work tree, and keeps `_build/`.
3. `just vm-ci-install`, so that `ci-build` uses `~/apex-image`; then
   `just vm-ssh 'echo APEX_CI_REMOTE=https://github.com/apex-linux/apex-image.git >~/.config/apex/ci.env'`.
4. `just vm-image`. The first run clones the four components into `_build/components/`
   and rebuilds the lane's builder image, since its toolchain step changed.

## License

GPL-3.0-or-later (`LICENSE`).
