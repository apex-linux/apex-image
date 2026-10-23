# Apex update signature policy

`policy.json` in this directory is the containers-policy.json(5) file that every bootc
call made by `apex-updated` uses, through
`CONTAINERS_POLICY_JSON=/usr/share/apex/containers/policy.json`
(ADR 0012, ARCHITECTURE §5.1, M1 contract §2 and §6). JSON has no comment syntax, and
containers/image rejects unknown keys, so the explanation lives in this file.

## What it enforces

| Image | Accepted when |
|---|---|
| `ghcr.io/apex-linux/apex` (stable) | sigstore-signed by `keys/release.pub` or `keys/release-backup.pub` |
| `ghcr.io/apex-linux/apex-testing` | sigstore-signed by `keys/ci.pub` |
| anything else, any transport | rejected (global `default` is `reject`) |

- There are no transport-wide accept rules. Policy scopes match whole path
  components, so the `apex` scope does not cover `apex-testing`, and each repository
  only trusts its own keys.
- `matchRepository` is the only identity cosign signatures can satisfy. It does not
  bind a tag, so a signed older digest could be served under `:45`. The daemon's
  monotonic version check (ADR 0012) closes that gap; this file cannot.
- `registries.d/apex.yaml` (in `/usr/share/containers`) turns on sigstore attachments
  for `ghcr.io/apex-linux`; without it no signature would be found.
- A key file that does not parse (for example a placeholder) makes the requirement
  fail, so the policy fails closed.

## Why the file is in `/usr`

`/etc` is merged three ways on every update, so a local edit there would freeze the
policy and block a key rotation. Under `/usr` it changes only with the signed image.
The general `/etc/containers/policy.json` and `/usr/share/containers/policy.json` stay
Fedora's lenient defaults for podman and toolbox: that is a different trust decision.

## Transports bootc uses

On the ostree backend, `bootc upgrade`, `upgrade --check` and `switch` open the image
through the skopeo image proxy with the `docker` transport. The proxy evaluates this
policy when it opens an image, for any transport. Apex needs no other transport:

- `upgrade --from-downloaded`, `rollback` and `status` do not pull.
- Logically bound images (`/usr/lib/bootc/bound-images.d`) and bootc's experimental
  unified storage go through `containers-storage:`. Apex uses neither. If that changes,
  those images need an explicit scope here: this policy rejects them.

## Consequences for people running bootc by hand

- The installed origin is `ostree-image-signed:` because the install config sets
  `enforce-container-sigpolicy = true`. bootc then refuses to pull while the effective
  default policy is `insecureAcceptAnything`, which is Fedora's default. A plain
  `sudo bootc upgrade` therefore fails, on purpose. Use `apexctl`, or run
  `sudo env CONTAINERS_POLICY_JSON=/usr/share/apex/containers/policy.json bootc upgrade`.
- `bootc install` inside the Apex container reads its source image from the host's
  `containers-storage`. That read uses the container's default policy, not this file.
  Do not set `CONTAINERS_POLICY_JSON` for `bootc install`, and do not pass
  `--run-fetch-check`: this policy has no `containers-storage` scope and would reject
  the local source. The install-time signature check happens earlier, when the host
  pulls the image by digest with this policy and `cosign verify` (ADR 0010).
