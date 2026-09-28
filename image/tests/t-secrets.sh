#!/bin/sh
# image/checks/secrets.sh: private keys in text formats, and in Apex's own packages.
. "$(dirname -- "$0")/lib.sh"

command -v python3 >/dev/null 2>&1 || skip_all "python3 not found (fake rpm)"

BEGIN='-----BEGIN'
PEM="$BEGIN PRIVATE KEY-----"

# mkroot NAME: prints the path of an empty root with an empty fake rpmdb.
mkroot() {
    r=$T/$1
    mkdir -p "$r/usr/share" "$r/etc"
    printf '{"rpm": {}}\n' >"$T/$1.db"
    printf '%s\n' "$r"
}

# own ROOTNAME PACKAGE PATH [modified]: record PATH as owned by PACKAGE.
own() {
    python3 - "$T/$1.db" "$2" "$3" "${4:-}" <<'PY'
import json, sys
db_path, pkg, path, modified = sys.argv[1:]
with open(db_path) as f:
    db = json.load(f)
entry = db.setdefault(pkg, {"files": [], "modified": []})
entry["files"].append(path)
if modified:
    entry["modified"].append(path)
with open(db_path, "w") as f:
    json.dump(db, f)
PY
}

secrets() {
    run env PATH="$(fake_path)" FAKE_RPMDB="$T/$1.db" ROOT="$T/$1" \
        SECRETS_FIXTURES=/dev/null "$SH" "$CHECKS/secrets.sh"
}

r=$(mkroot clean)
printf 'nothing to see\n' >"$r/etc/motd"
# A binary that merely contains the marker after a NUL byte (ssh-keygen and friends).
printf 'ELF\000%s\000' "$PEM" >"$r/usr/share/binary"
secrets clean
expect_rc "a root without keys passes" 0
expect_out "and finds nothing" '^PASS secrets: no private key blocks found'

r=$(mkroot yaml)
printf 'tls:\n  key: |\n    %s\n    MIIE\n' "$PEM" >"$r/etc/service.yaml"
secrets yaml
expect_rc "an indented PEM (YAML block scalar) fails" 1

r=$(mkroot json)
printf '{"private_key": "%s\\nMIIE\\n-----END PRIVATE KEY-----\\n"}\n' "$PEM" >"$r/etc/sa.json"
secrets json
expect_rc "a PEM at the start of a JSON string fails" 1

r=$(mkroot jsonmid)
printf '{"k": "x\\n%s\\nMIIE"}\n' "$PEM" >"$r/etc/sa2.json"
secrets jsonmid
expect_rc "a PEM after a literal \\\\n in JSON fails" 1

r=$(mkroot env)
printf 'KEY=%s\n' "$PEM" >"$r/etc/app.env"
secrets env
expect_rc "a PEM after = fails" 1

r=$(mkroot cosign)
printf '%s ENCRYPTED SIGSTORE PRIVATE KEY-----\nabc\n' "$BEGIN" >"$r/etc/cosign.key"
secrets cosign
expect_rc "a cosign key at the start of a line fails" 1

r=$(mkroot apexpkg)
mkdir -p "$r/usr/share/apex/tests"
printf '%s\nMIIE\n' "$PEM" >"$r/usr/share/apex/tests/fixture.key"
own apexpkg apex /usr/share/apex/tests/fixture.key
secrets apexpkg
expect_rc "a key in a file of the apex RPM fails" 1
expect_out "and says so" '^FAIL secrets: private key in a file of an Apex-built package \(apex\)'

r=$(mkroot fprint)
printf '%s\nMIIE\n' "$PEM" >"$r/usr/share/fp.pem"
own fprint libfprint /usr/share/fp.pem
secrets fprint
expect_rc "a key in a file of the Apex libfprint fails" 1

r=$(mkroot fedora)
mkdir -p "$r/usr/share/doc/openvpn"
printf '%s\nMIIE\n' "$PEM" >"$r/usr/share/doc/openvpn/client.key"
own fedora openvpn /usr/share/doc/openvpn/client.key
secrets fedora
expect_rc "an unmodified Fedora sample key passes" 0
expect_out "as a packaged file" '^PASS secrets: packaged, unmodified file from openvpn'

r=$(mkroot fedoramod)
mkdir -p "$r/usr/share/doc/openvpn"
printf '%s\nMIIE\n' "$PEM" >"$r/usr/share/doc/openvpn/client.key"
own fedoramod openvpn /usr/share/doc/openvpn/client.key modified
secrets fedoramod
expect_rc "a modified Fedora file with a key fails" 1

done_testing
