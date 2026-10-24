# Apex signing keys (public halves)

The `.pub` files are the cosign public keys that `/usr/share/apex/containers/policy.json`
trusts (ADR 0012, M1 contract §2). `RPM-GPG-KEY-apex` is the Apex RPM key
([below](#rpm-gpg-key-apex)). Only public keys ever go here. A CI check scans every image
layer for private keys.

| File | Trusted for | Private half lives in |
|---|---|---|
| `release.pub` | `ghcr.io/apex-linux/apex` | GitHub environment `release` (main only, manual approval) |
| `release-backup.pub` | `ghcr.io/apex-linux/apex` | offline only, encrypted; never in GitHub |
| `ci.pub` | `ghcr.io/apex-linux/apex-testing` | GitHub environment `testing` |
| `RPM-GPG-KEY-apex` | the RPMs of `[apex]` in the image build, not images | the builder VM; one offline backup |

## Placeholders

Until the owner generates the keys, each `.pub` file holds the marker line
`APEX-PLACEHOLDER-NOT-A-KEY` instead of a key. While any marker is present:

- the policy cannot load the key, so it rejects every Apex image (it fails closed);
- release builds must fail. The image check is
  `grep -rlx 'APEX-PLACEHOLDER-NOT-A-KEY' /usr/share/apex/keys`, which must print
  nothing for an image that is promoted to `apex`.

## Generating the keys

Use cosign 3.x. Pick a long passphrase for each key. The legacy signature format is
required at signing time (ADR 0012), not at generation time.

`cosign generate-key-pair` writes `cosign.key` and `cosign.pub` into the current
directory. Never run it inside the repository: generate in a private directory outside
it, for example `cd "$(mktemp -d -p "$XDG_RUNTIME_DIR")"` (tmpfs, removed at logout),
and copy only the `.pub` file into this directory under its new name. `.gitignore` and
`.containerignore` also exclude `*.key` as a second guard.

1. **CI key.** On a trusted machine, in such a directory, run
   `cosign generate-key-pair`. Store the contents of `cosign.key` as the secret
   `COSIGN_PRIVATE_KEY` and the passphrase as `COSIGN_PASSWORD` in the environment
   `testing`. Copy `cosign.pub` here as `ci.pub`. Delete the private directory.
2. **Release key.** Same steps, with the secrets in the environment `release`. Copy
   `cosign.pub` here as `release.pub`.
3. **Backup key.** Boot a live USB with networking disabled and run
   `cosign generate-key-pair` there (or generate it on a hardware token through
   cosign's PKCS#11 support). Keep the encrypted `cosign.key` on two offline media in
   different places. Copy only `cosign.pub` here, as `release-backup.pub`.
4. Record each key's fingerprint in the pull request that adds it:
   `openssl pkey -pubin -in release.pub -outform DER | sha256sum`. The install runbook
   checks the key on the live system against this repository (ADR 0010).

Signing, for reference (the workflows own this):

```sh
cosign sign --yes --new-bundle-format=false --use-signing-config=false \
  --key env://COSIGN_PRIVATE_KEY ghcr.io/apex-linux/apex@sha256:<digest>
```

## RPM-GPG-KEY-apex

The public half of the Apex RPM key: OpenPGP Ed25519, fingerprint
`B9A8 301A 20A1 4E73 2212 A4C5 8DA3 252B D6EF 25FA`. It signs every RPM the builder VM
builds. The image build's `[apex]` repository verifies with it, and G1 checks that this
file holds exactly the key pinned in `image/checks/lib/common.sh`. Its private half lives
only in the builder VM, with one offline backup (packaging/README.md, "Signing";
rotation in RECOVERY §6.8). `policy.json` does not use it.

## Rotation and compromise (ADR 0012)

- **Planned rotation:** image N adds the new public key next to the old one, N+1 is
  signed with the new key, N+2 drops the old key. The policy that verifies an update is
  the one inside the image that is currently booted, so a key must ship one image
  before anything is signed with it.
- **Release key compromised:** delete the GitHub secret, build an emergency image whose
  policy lists `[backup, new-backup]`, and sign it locally with the backup key.
- Every change to which key a repository trusts also updates the expected mapping at
  the top of `image/checks/keys.sh`, in the same reviewed change: the image build fails
  when `policy.json` and that mapping differ.
