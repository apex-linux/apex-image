# Packaging

How apex-image turns the components' packages into the image. The image compose never
runs `cargo` or `rpmbuild` itself: each package is built first, in the builder VM
(`tools/builder-vm/build-image.sh`), from the component that owns it, and fed to the
single depsolve of the compose through a local repository (`createrepo_c`, priority 1).

| RPM | Built from | By | Output |
|---|---|---|---|
| `apex` (`apexctl`, `apex-updated`, `apex-boot-assess`) | apex-system (`APEX_SYSTEM_SRC`) | its `.github/scripts/rpms.sh build` | `_build/rpms/apex/` |
| `apex-desktop` (the Apex GSettings schema and the shell's crash guard) | apex-desktop (`APEX_DESKTOP_SRC`) | its `.github/scripts/rpms.sh build` | `_build/rpms/desktop/` |
| libfprint with the ELAN `04f3:0c6e` patches | apex-kernel (`APEX_KERNEL_SRC`) | its `.github/scripts/libfprint.sh build`, given this image's `GA_REACHED` and updates-testing allowlist | `_build/libfprint/`, or "degraded" |
| gnome-shell with the Apex layer, and later the kernel pair | the recipes in `packaging/pkgs/` of apex-gnome and apex-kernel (`APEX_LANE_RECIPES`) | `apex-lane build` ([below](#the-rebuild-lane)) | `~/apex-store/`, `rpms.lock.next` |

`tools/components.sh fetch` clones each component at its commit in `components.lock`
into `_build/components/`, and `tools/components.sh env` names the clones. `just
vm-image` runs, in order: the components, the apex and apex-desktop RPMs, libfprint,
`apex-lane build all`, then the image from `rpms.lock.next` ([The image](#the-image)).
The Apex RPM key signs every RPM they build ([Signing](#signing)). This repository
keeps no RPM recipe of its own: `crates/apex-lane` and `rebuild.sh`, the Bash lane it
replaced, whose history keeps the release numbers from dropping.

## The rebuild lane

`apex-lane` rebuilds a Fedora SRPM with the Apex inputs of `packaging/pkgs/<pkg>/` in a
recipe checkout: apex-gnome for gnome-shell, apex-kernel for the kernel pair, every
checkout in `APEX_LANE_RECIPES`
([ARCHITECTURE 4.1](https://github.com/apex-linux/apex/blob/main/docs/ARCHITECTURE.md#41-rebuild-lane-s1a) and
[4.3](https://github.com/apex-linux/apex/blob/main/docs/ARCHITECTURE.md#43-hold-on-failure)). It generalises apex-kernel's
`packaging/libfprint/build.sh`, which keeps its own script until roadmap S2c moves
libfprint here. It runs in the builder VM, from this checkout; the Fedora half runs as root in a fresh
container of `image/Containerfile`'s `REPOS_BASE`, the digest the compose resolves
with, as `apex-lane in-container`, the same binary mounted read-only. Signing, the
store and the locks stay in the VM.

`apex-lane` is a Rust dev tool (`crates/apex-lane`), never shipped: it lives in this
repository, and no RPM carries it. `tools/builder-vm/lane.sh` builds it from the
checkout's `HEAD` with Fedora's rust in a container of `REPOS_BASE` (Fedora's rust from
the compose's repositories, once per `REPOS_BASE` digest, as
`localhost/apex-lane-builder`), so it links against the glibc of the lane's
containers; it caches the binary in `~/.cache/apex-lane` by its inputs and runs it in
the checkout. The binary embeds the tree id of `crates/apex-lane` it was built from, and
`build`, `key` and `prep` refuse to run from any other.

| Recipe | Runs | Does |
|---|---|---|
| `just pkg-build [PKG]` | `apex-lane build PKG\|all` | builds what changed and records it in `rpms.lock.next` |
| `just pkg-key PKG` | `apex-lane key PKG` | prints the content key |
| `just pkg-status` | `apex-lane status` | each family's state, build and hold timer, in `rpms.lock.next` and `rpms.lock` |
| `just pkg-prep PKG` | `apex-lane prep PKG` | a git work tree in the VM's `_build/pkg/PKG/tree`: Fedora's `%prep`, the series as commits, Source1 |
| `just pkg-rebase PKG NVR` | `apex-lane prep PKG NVR` | the same from another Fedora build, with `git am -3` |
| `just pkg-export PKG [NEW.patch…]` | `apex-lane export PKG` | the work tree's commits back to `packaging/pkgs/PKG/patches/` and `series` of the recipe's checkout on the host (`APEX_RECIPES`, default `../apex-gnome`) |
| `just pkg-promote [--allow-degraded]` | `apex-lane promote` | `rpms.lock.next` becomes `rpms.lock`, after an image built from it passed its gates; `--allow-degraded` is the owner's override for a new `degraded=nvidia` |
| `just pkg-stock PKG` | `apex-lane stock PKG` | the owner's choice at a hold limit: the next image takes Fedora's build of the family |
| `just kernel-bump` | `apex-lane kernel-bump` | the kernel pair's bump check: a point bump becomes a commit on a branch of the apex-kernel checkout; a new major waits for the owner |

The recipes sync the checkout into the VM first, and `lane.sh` takes the recipes from the
pinned components (`tools/components.sh`). The lane builds committed inputs only,
and `lane.sh` builds the tool from `HEAD`: in the VM, `tools/builder-vm/snapshot.sh`
commits a dirty host tree as a throwaway snapshot, as `just vm-image` does.

### What `apex-lane build` does

1. **Parses** `pkg.env`, `series` and `spec-edit` with strict parsers, archives Source1
   and checks its members, all before any network access (exit 2 on an error).
2. **Repositories.** The compose's set: `fedora`, `updates`, and before GA
   `updates-testing` limited to the allowlist (`lib.sh dnf_repo_args`). Before GA the
   buildroot also admits every binary subpackage of the builds the allowlist admits,
   found by source RPM. The runtime allowlist leaves out `-devel` packages, so without
   this `mutter-devel` resolves to `51~rc-2` and `mutter-devel >= 51.0` cannot be met.
   It adds no build, only more subpackages of reviewed ones, and only for the lane's own
   dnf calls; it goes away with `GA_REACHED=1`. dnf's metadata cache is a podman volume
   (`apex-lane-dnf-cache`), refreshed at the start of every run.
3. **Resolves** the stock build (the binary named `srpm=`, whose source RPM must be its
   own NVR) and the pin (the newest `<pin>-devel`), then the content key. A key already
   in the store is **unchanged**: nothing is built, and `rpms.lock.next` takes it.
4. **Downloads and verifies** the SRPM and the `mirror`/`mirror_dev` RPMs of the pin's
   exact build: `rpmkeys -K` must report every signature OK, one made by the pinned
   Fedora 45 key (`4F50 A611 4CD5 C697 6A7F 1179 655A 4B02 F577 861E`, checked against
   the key file before it is imported).
5. **Release arithmetic.** Fedora's spec must give the stock release, and `rpm.vercmp`
   must place the Apex release above the stock build and above the locked one.
6. **Pristine `%prep`**, with no Apex input. Its tree is kept for step 9.
7. **`spec-edit`**, then one `Patch<1001+i>: apex-<name>` line per series entry after
   the spec's last `Patch` line (Fedora's unnumbered `Patch:` stays `Patch0`, so its
   patch applies first). `rpmspec` must then give the Apex release, and the exact pin in
   `BuildRequires` and `Requires`.
8. **`dnf5 builddep`**; the buildroot must hold `<pin>-devel` at the pin.
9. **Patched `%prep`.** Fedora's `%autosetup -S git` applies the series with
   `git apply`: no fuzz. Then the tree must be exactly Fedora's plus the series, Source1
   and the `prep_moved`/`prep_deleted` changes: on a copy, each patch is reverted, each
   move and deletion undone and Source1 removed, and `diff -r` against the pristine tree
   must be empty.
10. **`rpmbuild -ba`**, with Fedora's `%check`, no `--define dist` and no `--nocheck`.
11. **Lane checks**: every built RPM carries the computed release; each `install=` name
    was built; the main package requires `<pin>(x86-64) = <EVR>`; then the package's own
    `check.sh`.
12. **Signs** the built RPMs and the Apex SRPM with the Apex RPM key, in the VM
    ([Signing](#signing)).
13. **Stores** the built RPMs (no debuginfo), the mirror RPMs, the Apex SRPM,
    `manifest.txt`, `key.txt`, `key-input.txt` (the text the key hashes), `spec.diff`
    and the logs under `~/apex-store/pkgs/PKG/KEY/`, and writes the family into
    `rpms.lock.next`.

### Exit status

| Exit | Meaning | `rpms.lock.next` |
|---|---|---|
| 0 | built, or the key is already stored | `built KEY` |
| 1 | infrastructure: a repository, a download, a signature, the pin, the release arithmetic, Fedora's own `%prep`, the store, or a hold with no last good build | unchanged; the image build stops |
| 2 | usage or configuration: `pkg.env`, `series`, `spec-edit` (an ERE outside the subset included), Source1's members, two packages in one family, uncommitted inputs, a shallow clone, a binary built from another `crates/apex-lane` | unchanged; the image build stops |
| 3 | the inputs give no shippable build: an anchor matches 0 or 2+ lines, a patch does not apply, the tree is not exact, the build or a lane check fails | `on_fail=hold`: `held`, keeping the last good build of `rpms.lock`; `on_fail=degrade`: `degraded`, no RPMs; the image build goes on |

`build all` builds every `pkgs/*/pkg.env` in byte order, stops at the first 1 or 2, and exits
3 when any package held or degraded. The reason of an exit 3 names the first series
entry that does not apply on its own to Fedora's tree, so a rebase conflict names its
feature; it and the log's tail are kept in `~/apex-store/pkgs/PKG/last-failure.txt`.

### `pkg.env`

`KEY=VALUE` lines, never sourced; `#` comments. An unknown or repeated key, or a value
outside `[A-Za-z0-9._/:+ -]`, exits 2.

| Key | Required | Value |
|---|---|---|
| `source` | yes | `fedora-srpm`, or `copr-srpm` for the kernel pair ([below](#the-kernel-pair-sourcecopr-srpm)). `git` (S2c) is reserved. |
| `srpm` | yes | the source package; its binary package of the same name is resolved |
| `on_fail` | yes | `hold` (a design package) or `degrade` |
| `family` | yes | the hold unit in the lock, `^[a-z0-9][a-z0-9._+-]*$`; one package per family |
| `install` | yes | the built binary packages the image takes |
| `pin` | no | a package name, built against at one exact EVR: its newest `-devel` in the lane's repositories. `spec-edit` writes it with `@PIN_EVR@`; the lane checks the result. |
| `mirror` | with `pin` | Fedora-signed binaries of the pin's build, stored and locked with the family |
| `mirror_dev` | with `pin` | the same, stored but never locked (the dev loop) |
| `source1` | no | a directory of this repository, archived as `Source1` (`@SOURCE1@`) |
| `source1_paths` | with `source1` | the paths Source1 may add to the tree; a trailing `/` means a directory |
| `prep_moved` | no | `FROM:TO` pairs that `spec-edit`'s `%prep` lines move (TO must equal Fedora's FROM); `prep` makes the same moves in the work tree |
| `prep_deleted` | no | Fedora files that `spec-edit`'s `%prep` lines delete |

### The kernel pair (`source=copr-srpm`)

The kernel and NVIDIA pair of apex-kernel's `packaging/pkgs/kernel/` is a recipe kind of
its own ([ARCHITECTURE 4.2](https://github.com/apex-linux/apex/blob/main/docs/ARCHITECTURE.md#42-kernel-and-nvidia-lane-s1c)):
no Fedora SRPM, series or `spec-edit`, but the COPR's signed SRPM and negativo17's
`nvidia-kmod`, pinned by two files of the recipe directory and built by its own job.

```
source=copr-srpm
family=kernel-cachyos
install=kernel-cachyos kernel-cachyos-core kernel-cachyos-modules
kernel_env=kernel.env
nvidia_env=nvidia.env
```

Those five keys, each required, and no other. `family` is `kernel-cachyos`, the name
of the image's `held=` label and apexctl's held list. `install` names the kernel side's
packages; the kmod built for that kernel joins them. `kernel_env` and `nvidia_env` name
files of the recipe directory, read with the same strictness: `KEY=VALUE`, `#` comments,
each key once (`userspace=` once per package), no space at either end of a value, since
the pair job reads them with `sed`.

| `kernel.env` | Required | Value |
|---|---|---|
| `copr`, `chroot` | yes | the COPR project (`OWNER/PROJECT`) and its chroot |
| `srpm`, `srpm_sha256` | yes | the `kernel-cachyos` SRPM's NEVRA (`MAJOR.MINOR.POINT`) and sha256 |
| `copr_key` | yes | the COPR key's fingerprint, 40 uppercase hex digits |
| `tag`, `tag_key` | no | the CachyOS tag and its key's fingerprint |
| `copr_key_expires`, `tag_key_expires` | no | `YYYY-MM-DD` |
| `tag_repo`, `tag_key_url` | for `kernel-bump` | `https://` URLs: the CachyOS git repository, and `tag_key`'s key file |

| `nvidia.env` | Required | Value |
|---|---|---|
| `kmod_srpm`, `kmod_srpm_sha256` | yes | the `nvidia-kmod` SRPM's NEVRA and sha256 |
| `userspace` | no, repeated | `NEVRA SHA256` of one x86_64 or noarch binary RPM |
| `negativo17_key` | yes | negativo17's key fingerprint |
| `negativo17_key_expires` | no | `YYYY-MM-DD` |

apex-kernel has no such `pkg.env` yet, so the lane sees no kernel family and builds
exactly what it built before.

**`apex-lane build kernel`** (and `build all`) runs the pair:

1. **One side per image, the kernel first.** The pins are compared with the last good
   pair of `rpms.lock` (its stored `kernel.env` and `nvidia.env`). When both sides
   moved, the job takes the new kernel with the old driver; the new driver follows once
   that image is promoted.
2. **Pinned keys (K7).** A key whose `*_key_expires` is less than 60 days away is
   warned about at every run and in `kernel-bump`. Inside 14 days the warning says to
   pin its successor now, in the build summary too. An expired one holds the pair before anything is downloaded, with
   the key, its fingerprint and the date as the reason: from then on no input could
   verify against it.
3. **Mirror at first sight** into `~/apex-store/mirror/`: each key file
   (`keys/FPR.gpg`, exactly the pinned key) and every pinned SRPM and binary, the
   waiting driver's too, each checked against its pinned sha256 and, with `rpmkeys -Kv`
   against a keyring holding only its key, its signature. The COPR keeps 5 builds and
   negativo17 the last 2 of each package, so a hold or a rebuild works from the store.
   Any failure here is exit 1.
4. **The key**: `KERNEL-NVR-s<12 hex>` over the lane's tool id, the dnf options and
   every file of the recipe directory (`README.md` aside) as the job sees it. A stored
   key is taken unchanged, with no container.
5. **The job**: apex-kernel's `pair.sh /mirror /out DNF-OPTION...` as root in one fresh
   container of `REPOS_BASE`, at low CPU weight, the recipe directory read-only at
   `/job`, the module key's tmpfs at `/run/apex-modkey`, ccache in the volume
   `apex-lane-ccache`. Exit 0: the RPMs of `pair.lock`, each sha256 checked and
   queried with `rpm -qp`, are signed with the Apex RPM key and stored under
   `pkgs/kernel/KEY/` with `pair.lock`, the pins, the module certificate and the logs,
   and, for the image's checks, the recipe's `config-required.txt` and (a whole pair)
   negativo17's key file as mirrored, `negativo17.gpg`. `pair.sh`'s `OUT/debug/`
   (`vmlinux` with DWARF, `System.map`, the built `config`, `kernel.log`) goes to
   `debug/` in the set; a lock without all four is exit 1 of the lane.
   Exit 1: a hold (below), the reason the last line of its stderr, and `debug/kernel.log`,
   when the kernel got that far, kept as `pkgs/kernel/last-failure-kernel.log`. Anything
   else is exit 1 of the lane. After an exit 0 the lane runs the one gate of ARCHITECTURE 4.2
   that check.sh cannot, since it never sees the last good pair: the modules in the
   pair's RPMs (`rpm -qlp`) within 5 % of the last good pair's, or a `check:` hold.
   BTF is check.sh's, through `config-required.txt` (`CONFIG_DEBUG_INFO_BTF=y`).
6. **The lock**: `family kernel-cachyos built KEY`, one `rpm` line of kind `built` for
   each `install=` package and the kmod built for that kernel, and one of kind `mirror`
   for each `userspace=` RPM of the driver the pair was built with, copied from the
   mirror into the set and checked against its pin. `kernel-cachyos-devel` is stored,
   not locked. A kernel-only set (`degraded=nvidia`) locks no userspace.
7. **Retention** (ARCHITECTURE 4.2), after each new pair: the 4 newest sets stay whole.
   An older one that `rpms.lock` or `rpms.lock.next` names loses only `debug/`; one
   that neither names is removed. The mirror is kept forever.

**Holds** (ARCHITECTURE 4.3) keep the last good pair's `rpm` lines:

| `pair.sh` exit 1 with | Hold | Limit, then |
|---|---|---|
| `kmod:` on a new point release | `held GOOD … side=kmod` | 72 h from the first failure; then `degraded=nvidia` |
| `kmod:` on a new major | the same | 14 days; then `degraded=nvidia` |
| anything else (`kernel:`, `check:`, an input) on a new kernel | `held GOOD … side=kernel` | 72 h from the kernel.org release (`releases.json`; from the first failure when it no longer lists it); then the owner chooses |
| either, when only the driver moved | `held GOOD …`, no limit | none: the running pair keeps working |

`newer=` names the SRPMs the good pair was not built from, `security=` is `1` for the
72 h clocks, and `since` survives reruns that fail the same way. At a kmod limit the
lane takes the new kernel without NVIDIA: `family kernel-cachyos built KEY' … degraded=nvidia
side=kmod reason=…`, the kernel-side RPMs only, under a key of its own. It takes that
kernel from the job's `/out/kernel.lock` (pair.lock without `kmod=`, which `pair.sh`
writes on a `kmod:` failure from apex-kernel a2907d3 on); without one, the family stays
held and the summary says LIMIT REACHED. Such a lock is the owner's to ship: `promote`
refuses a `rpms.lock.next` that takes a `degraded=nvidia` set `rpms.lock` does not
have, unless the owner gives the override, `just pkg-promote --allow-degraded`. A run that builds a
whole pair clears any hold. A failure with no last good pair in `rpms.lock` stops the
image build (exit 1), as for the other families; the pair has no `stock`.

**`apex-lane kernel-bump`** (`just kernel-bump`) runs the recipe's `bump.sh check`:

One run may print both kernel lines, the point line first.

- `point NEVRA`: mirrors that SRPM after checking it against the COPR key (and the
  pinned one, against its pinned sha256), then writes the bump report:
  - the CachyOS tag (`cachyos-VERSION-N`, N the release's first number), fetched from
    `tag_repo` into `~/apex-store/mirror/cachyos-linux.git`, and `git verify-tag`
    against `tag_key` alone (fetched from `tag_key_url`, its fingerprint checked,
    mirrored at first sight); a `kernel.env` without these pins is exit 1;
  - the new SRPM's Source0 against the tag's `git archive`, both uncompressed, byte for
    byte;
  - the BORE patch (`0001-bore-cachy.patch`) and the `config` against the pinned SRPM's:
    new symbols, changed values and removed symbols;
  - the patches of the pinned kmod SRPM, when it is mirrored.

  A tag or a Source0 that does not verify is exit 1, with no branch. A config that
  changes beyond new symbols holds the bump: the report goes to the summary with a
  warning, and no branch is written. Otherwise the lane commits `kernel.env` with the
  new `srpm`, its sha256 and `tag`, the report in the commit message, on the branch
  `kernel-bump/NVR` of the recipe's checkout, through a private index: HEAD and the
  work tree stay. The runner pushes it and opens the bump PR.
- `major NEVRA waiting-for-owner EOL-in-Nd`: prints "waiting for owner" with the EOL
  countdown.
- each newer NVIDIA build: a new driver waits for the owner.

### `series`

One `NNNN-name.patch` per line, relative to `patches/`, in application order; `#`
comments; no duplicates; every entry must exist. A patch is disabled by leaving it out
(ADR 0014 numbers the shell's patches 0001 to 0017, so libfprint's 01xx rule does not
apply here). Patches are `git format-patch` output against Fedora's `%prep` tree, `a/`
and `b/` prefixes, applied with `-p1`; `just pkg-export` writes them.

### `spec-edit`

Anchored edits, because Fedora's specs use `%autorelease` and change often. Blocks, with
comments and blank lines between them:

```
replace ERE        # or: after ERE
	text line      # each text line starts with one tab
end
```

Each ERE must match exactly one line of Fedora's spec, compared as bytes, as `grep -E`
does in the C locale. `after` inserts the text after that line, `replace` replaces the
line. No match, or more than one, exits 3. Placeholders: `@APEX_RELEASE@` (`.apexN` or
`.apexN.M`), `@PIN_EVR@`, `@SOURCE1@`; any other `@NAME@` exits 2. The lane adds the
`Patch` lines itself.

The ERE is the rest of the directive line after one space, trailing spaces included,
and must be in this subset of POSIX EREs, checked when `spec-edit` is read (exit 2
otherwise): literals; `.`; `^` and `$`; bracket expressions with ranges, negation and
the classes `[:alpha:]`, `[:digit:]`, `[:alnum:]`, `[:upper:]`, `[:lower:]`,
`[:space:]`, `[:blank:]`, `[:punct:]`, `[:print:]`, `[:graph:]`, `[:cntrl:]`,
`[:xdigit:]` (ASCII only inside brackets); groups; `|`; `*`, `+`, `?` and the intervals
`{m}`, `{m,}`, `{m,n}`, `{,n}` up to 255; and `\` before one of ``. [ ] ( ) { } * + ? |
^ $ \ /``, which stands for that character. Out of the subset, because GNU grep reads
them its own way: back-references, `\w \W \s \S \b \B \< \>`, a `{` that starts no
interval (write `\{` or `[{]`), an empty group or alternative, a quantifier after
nothing or after an anchor, and `[= =]` and `[. .]`.

### `check.sh`

Optional. The lane runs `pkgs/PKG/check.sh` in the container after its own checks, as
root, with `RPMS_DIR` (the built binary RPMs, no debuginfo), `PRISTINE` (Fedora's `%prep`
tree, no Apex input), `SOURCE1` (the archive) and `CHECK_WORK` (scratch, to create).
Exit 0 passes, 1 fails the build (exit 3) with the last line not starting with `ok ` as
the reason, anything else is an infrastructure error.

### Content key and release

`KEY = <stock NVR>-s<first 12 hex digits of a sha256>` over: the key schema (2), the
package, the lane's tool id, `check.sh`, the dnf repository options (the admission list
included), the stock NVR, the pin, `pkg.env`, `spec-edit`, each patch by name and
content, Source1's tree id and `.apexN`. `key-input.txt` in each stored set is that
text. The container digest is recorded in the manifest but not hashed: dependency
drift does not warrant a rebuild.

- **The tool id** is a sha256 over `git ls-tree -r HEAD` of `crates/apex-lane/Cargo.toml`
  and `crates/apex-lane/src`, and the name, version, source and checksum of every crate
  `Cargo.lock` compiles into the binary (the `[dependencies]` and `[build-dependencies]`
  of its `Cargo.toml`, and theirs). A change to the lane or to one of those crates
  rebuilds every package; its tests, its dev-dependencies and the rest of the workspace
  do not count. `apex-lane` depends on no workspace crate, whose source the id would
  miss; the id refuses one (exit 2).
- **N** in `.apexN` is `git rev-list --count HEAD` over `pkgs/PKG`, the Source1
  directory, `crates/apex-lane/src`, `crates/apex-lane/Cargo.toml` and
  `packaging/rebuild.sh`, the Bash lane `apex-lane` replaced: git still counts a
  deleted path's history, so N never drops below a Bash-built release. When the recipe
  sits in another checkout (`APEX_LANE_RECIPES`, ':'-separated), N is the count of its
  checkout over `pkgs/PKG` and the Source1 directory plus the count of the lane's
  checkout over the rest, which is never lower than the one count over both. Every
  committed change to an input moves it. In the builder VM a snapshot commit of a dirty
  tree adds one. A dependency bump in `Cargo.lock` alone changes the key but not N, and
  takes `.apexN.M`.
- **M** in `.apexN.M`: a key can change without a commit, when a Fedora update moves only
  the pin (a mutter-only update). The first key of a stock NVR at `.apexN` gets it bare;
  each later key of that stock NVR gets `.M`, one above the highest stored, so two builds
  never share a NEVRA. A stored key keeps its release.
- `rpm.vercmp` orders them: `51.0-1.fc45` < `51.0-1.fc45.apex1` < `.apex1.1` < `.apex2` <
  `51.0-2.fc45`.

### The store and `rpms.lock`

Builder state lives outside the checkout, which `builder-vm.sh sync` replaces
(`rsync --delete`), in `APEX_STORE` (default `~/apex-store`). The lock is builder state
too, not a committed file: the S1d timers absorb Fedora updates without a commit. Each
image carries the lock it was built from, at `/usr/share/apex/rpms.lock`.

```
~/apex-store/
  rpms.lock                   what the last image that passed its gates took
  rpms.lock.next              the candidate: what the next image build takes
  pkgs/PKG/KEY/               one build: RPMs, Apex SRPM, manifest.txt, key.txt, spec.diff, logs/
  pkgs/PKG/last-failure.txt   the reason and log tail of the last exit 3
  pkgs/kernel/KEY/debug/      vmlinux, System.map, config, kernel.log: the 4 newest pairs
  mirror/                     the pair's pinned inputs and keys, kept forever
```

`rpms.lock` format 1, one record per line (`reason=` runs to the end of the line):

```
family NAME STATE KEY [since=UTC] [limit=UTC] [newer=NVR,...] [security=0|1|?] [reason=TEXT]
rpm FAMILY KIND NAME NEVRA SHA256 PATH
```

- `STATE`: `built`; `held` (`KEY` is the last good build, whose `rpm` lines stay);
  `stock` (the owner's choice, no `rpm` lines); `degraded` (`on_fail=degrade`, none).
- `KIND`: `built` (Apex-built) or `mirror` (signed by its upstream, unmodified: Fedora,
  or negativo17 for the pair's NVIDIA userspace; the header line predates the pair). `PATH` is
  relative to `APEX_STORE`. `mirror_dev` RPMs are stored, never locked.
- A hold records `since` (the first failed run for this set of `newer` builds, kept
  across runs), `newer` (the Fedora builds the last good build was not made from),
  `security` (from Bodhi: `1` security, `0` not, `?` unknown, which counts as security)
  and `limit` (`since` + 72 h for security, + 14 days otherwise). Both times are
  `%Y-%m-%dT%H:%M:%SZ`, the only form the lane reads back. A hold with no newer
  Fedora build (the Apex inputs themselves fail) has no limit. `just pkg-status` prints
  `LIMIT REACHED` past the limit.
- `apex-lane build` writes `rpms.lock.next`; `promote` copies it to `rpms.lock` after
  the image built from it passes its gates, after checking every file's sha256 and that
  each path stays inside the store. A hold
  needs a last good build in `rpms.lock`; with none (the first build, or a lost store)
  the lane exits 1, and only the owner can choose `stock`.

### The image

The image takes gnome-shell only through the lane: nothing degrades a design package to
stock on its own (ADR 0014).

- `image.sh context --lane-lock ~/apex-store/rpms.lock.next` is required; the image
  build stops without it. It checks the lock (format 1; every family of
  `pkgs/*/pkg.env` recorded; rpm lines only for built and held families, at least one
  Apex-built; each NEVRA a build of its package, with a sha256 and a store path whose
  file name matches), copies the RPMs of the built and held families from the store
  into the build context's `rpms/`, verifying each sha256, and puts the lock itself
  there as `rpms/rpms.lock`. `--image-only` reuses the current `rpms.lock.next`.
- The Containerfile's repos stage requires `rpms/rpms.lock`, and `[apex]` must offer
  exactly the locked NEVRAs of the locked names (no missing build, no second build of a
  locked name). `[apex]` has `gpgcheck=1` with the Apex RPM key and Fedora's
  ([Signing](#signing)). `includepkgs` of `[apex]` is `image/packages/apex.txt` plus the
  locked names; `excludepkgs` of `[fedora]` and `[updates]` is the locked names plus
  libfprint when rpms/ carries the Apex libfprint, in one line each; `[apex-gnome51]`
  gets the same line after its own check. A stock or degraded family adds nothing, so
  Fedora's build is installed.
- The final stage installs the lock as `/usr/share/apex/rpms.lock`, records held
  families in the manifest's `held` field and a stock or degraded gnome-shell family as
  `degraded=shell` (docs/specs/M1-IMPLEMENTATION.md section 3); `image.sh` copies both
  into the `…apex.held` and `…apex.degraded` labels. The content key adds the lock's
  sha256, the apex-desktop key and the `desktop/` tree.
- G1's `image/checks/desktop.sh` checks the installed result against the lock: the
  locked NEVRAs, `.apexN` and the Apex RPM signature, the mutter pin and its Fedora
  signature, the theme markers (`grep -a` on `gnome-shell-theme.gresource`), `rpm -V`,
  the Apex schema and the crash guard (ARCHITECTURE 11).
- Nothing promotes the lock by itself: after the image passed its gates (G2, and G4
  when its key changed, a new gnome-shell, mutter or gdm NVR among others, or its last
  pass is a week old; `just vm-image` runs it when it is due), `just pkg-promote`. It
  refuses unless `_build/gates-passed.txt`, which `just vm-image` writes after those
  gates from the lock the image carries, names `rpms.lock.next` as it is now and says
  `components pinned`: an image built from a dev-override component (`APEX_SRC_<NAME>`)
  never promotes.

### Signing

The Apex RPM key (ARCHITECTURE 5.1) signs every RPM Apex builds: the lane's builds, and
the apex, apex-desktop and libfprint RPMs of `just vm-image`. It signs in the builder VM
after the build container exited, so the private key never meets a build script.

| | |
|---|---|
| Key | OpenPGP v4, Ed25519, signing only, no expiry, no passphrase (builds sign unattended); fingerprint `B9A8 301A 20A1 4E73 2212 A4C5 8DA3 252B D6EF 25FA` |
| Public half | `image/system_files/usr/share/apex/keys/RPM-GPG-KEY-apex`, shipped as `/usr/share/apex/keys/RPM-GPG-KEY-apex`; pinned in `image/checks/lib/common.sh` |
| Private half | the builder VM only: the GnuPG home `~/.local/share/apex/rpm-gnupg` |
| Offline backup | one armoured export of the secret key (`gpg --armor --export-secret-keys`), kept by the owner on offline media |
| Configuration | `~/.config/apex/rpm-signing.env` in the VM (`APEX_RPM_SIGNING_ENV`) |

`rpm-signing.env` is read, never sourced: `#` comments and exactly these two keys. An
unknown or repeated key, or a malformed value, exits 2.

```
APEX_RPM_KEY_FPR=B9A8301A20A14E732212A4C58DA3252BD6EF25FA
APEX_RPM_GNUPGHOME=/home/builder/.local/share/apex/rpm-gnupg
```

Before any container starts, `apex-lane build` requires the file (exit 1 without it: the
lane never stores an unsigned build), a committed public key that holds exactly that
key, and its secret half in the GnuPG home. After the container, before the store:

- `rpmsign --addsign --define "_gpg_path $APEX_RPM_GNUPGHOME" --define
  "_openpgp_sign_id $APEX_RPM_KEY_FPR"` signs the `built` RPMs and the Apex SRPM.
  `mirror` and `dev` RPMs keep Fedora's signature (rpm 6.1's rpmsign refuses a package
  that already carries one).
- `rpmkeys -Kv` must verify each against a keyring that holds only the committed public
  key.
- The manifest takes the signed files' sha256 and a `# sig=<fingerprint>` line (builds
  from before the key say `# sig=none`); the lock takes the signed sha256. The signature
  is not part of the content key, so a stored build keeps the key it was signed with. A
  stored build the lane takes again (unchanged) must record the key `rpm-signing.env`
  names, or the lane stops before the lock (RECOVERY §6.8).

`apex-lane sign RPM...` does the same to RPMs the lane does not build, and updates a
`manifest.txt` beside them that lists them. `build-image.sh` runs it on `_build/rpms/apex/`
and `_build/rpms/desktop/` after the components' `rpms.sh build`, and on
`_build/libfprint/` after `libfprint.sh build`, then rewrites their `SHA256SUMS`.

The Containerfile's repos stage copies the public key and Fedora's into the local
repository, where rpm-ostree's libdnf looks for a local repository's `gpgkey=` files,
and gives `[apex]` `gpgcheck=1` with both (the mirrored mutter is Fedora's), so the
compose refuses an unsigned or foreign RPM. G1 checks the result: `signing.sh`, that
the shipped key is the pinned one and that every Apex package carries its signature
(`apex.txt`'s names and every `.apexN` release; only a stock libfprint carries
Fedora's instead), and `desktop.sh`, the locked gnome-shell. By hand, in the VM:

```bash
rpm -qpi FILE.rpm | sed -n '/^Signature/,/^Source/p'   # EdDSA/SHA512, ..., Key ID 8da3252bd6ef25fa
```

**A new builder VM.** `builder-vm.sh destroy` deletes the key with the disk. From the
host, import the offline backup (`BACKUP.asc` below), then name it:

```bash
tools/builder-vm/builder-vm.sh ssh 'umask 077; install -d -m 0700 ~/.local/share/apex/rpm-gnupg &&
    GNUPGHOME=~/.local/share/apex/rpm-gnupg gpg --batch --import' <BACKUP.asc
tools/builder-vm/builder-vm.sh ssh 'umask 077; mkdir -p ~/.config/apex && printf "%s\n" \
    APEX_RPM_KEY_FPR=B9A8301A20A14E732212A4C58DA3252BD6EF25FA \
    "APEX_RPM_GNUPGHOME=$HOME/.local/share/apex/rpm-gnupg" >~/.config/apex/rpm-signing.env'
```

**A new key** (a rotation, or an exposed key: RECOVERY §6.8), in the VM, in a new GnuPG
home that `rpm-signing.env` then names:

```bash
install -d -m 0700 ~/.local/share/apex/rpm-gnupg-new
GNUPGHOME=~/.local/share/apex/rpm-gnupg-new gpg --batch --pinentry-mode loopback --passphrase '' \
    --quick-gen-key 'Apex RPM signing key (github.com/apex-linux)' ed25519 sign never
```

Its public half (`gpg --armor --export-options export-minimal --export FPR`) replaces
`RPM-GPG-KEY-apex`, and its fingerprint every copy that RECOVERY §6.8 lists, in one
reviewed change.
