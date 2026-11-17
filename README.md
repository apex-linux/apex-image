# apex-image

Builds the Apex Linux operating system image, the installer media and the
release pins.

Part of [Apex Linux](https://github.com/apex-linux/apex). See the
[specification](https://github.com/apex-linux/apex/blob/main/docs/spec.md)
and the
[engineering standards](https://github.com/apex-linux/apex/blob/main/docs/engineering.md).

## What is in the image

The [Containerfile](Containerfile) starts from Fedora's `bootc` base image,
`quay.io/fedora/fedora-bootc:45`, and adds the stock Fedora GNOME desktop:
the comps groups in
[groups.txt](image/desktop/packages/groups.txt), which are the Fedora
Workstation environment without LibreOffice. Packages to leave out go in
[exclude.txt](image/desktop/packages/exclude.txt).

On top come the Apex components listed in
[components.txt](image/components/components.txt). The build fetches each
repository at the tip of its `main` branch and runs its
`just install <destdir>` recipe, which installs under `<destdir>/usr` only.
A component without an `install` recipe is skipped. A release pins the
commits instead, in `release/sync`, one `component=commit` line each:
`just build release/sync` builds from those pins.

## Build and test

You need `just`, `podman`, `flock` and Node.js (for `npx`). Every task is a
recipe in the [justfile](justfile); CI runs the same recipes.

```sh
just doctor  # Checks free disk and memory, and shows what Apex can clean.
just lint    # Runs shellcheck, shfmt, hadolint and markdownlint.
just build   # Builds the image as localhost/apex:main.
just clean   # Removes Apex's own images, disks and caches.
```

Heavy recipes run `just doctor` first, which refuses to continue with less
than 25 GiB of free disk or 4 GiB of available memory, and take the lock
`~/.cache/apex/heavy.lock` so that only one runs at a time. Large files go
under `~/.cache/apex/` or `build/`, never `/tmp`.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
