# apex-image

Builds the Apex Linux operating system image, the installer media and the
release pins.

Part of [Apex Linux](https://github.com/apex-linux/apex). See the
[specification](https://github.com/apex-linux/apex/blob/main/docs/spec.md)
and the
[engineering standards](https://github.com/apex-linux/apex/blob/main/docs/engineering.md).

## Build and test

You need `just`, `podman`, `flock` and Node.js (for `npx`). Every task is a
recipe in the [justfile](justfile); CI runs the same recipes.

```sh
just doctor  # Checks free disk and memory, and shows what Apex can clean.
just lint    # Runs shellcheck, shfmt, hadolint and markdownlint.
just clean   # Removes Apex's own images, disks and caches.
```

Heavy recipes run `just doctor` first, which refuses to continue with less
than 25 GiB of free disk or 4 GiB of available memory, and take the lock
`~/.cache/apex/heavy.lock` so that only one runs at a time. Large files go
under `~/.cache/apex/` or `build/`, never `/tmp`.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
