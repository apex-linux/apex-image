#!/bin/sh
# Image signature trust material (ADR 0012, docs/specs/M1-IMPLEMENTATION.md section 2).
#
# Always:
#   - /usr/share/apex/keys/{release,release-backup,ci}.pub exist;
#   - /usr/share/apex/containers/policy.json exists, parses as JSON and has exactly the
#     structure ADR 0012 requires, compared field by field with TRUST_MAP below:
#       - top level: only "default" and "transports"; default is exactly
#         [{"type": "reject"}];
#       - transports: only "docker", with exactly the repositories of TRUST_MAP;
#       - each repository: exactly one requirement, of type sigstoreSigned, with
#         signedIdentity {"type": "matchRepository"}, keyPath or keyPaths naming exactly
#         that repository's keys, and no other field (so no insecureAcceptAnything,
#         keyData, signedBy, remapIdentity, fulcio or rekor settings anywhere);
#     and every key it references exists. bootc itself only checks that the default is
#     not insecureAcceptAnything, so this is the one automated guard of the mapping.
#     python3 is required (the image has it: tuned-ppd depends on it).
# When RELEASE_BUILD=1 additionally:
#   - every /usr/share/apex/keys/*.pub is a real public key: exactly one PEM
#     "PUBLIC KEY" block whose DER decodes (openssl when available, otherwise a
#     structural SubjectPublicKeyInfo check), with no placeholder markers;
#   - the release, backup and CI keys are three different keys.
#
# Environment: ROOT (see lib/common.sh); RELEASE_BUILD (0 or 1, default 0).
set -eu
CHECK_NAME=keys
APEX_CHECKS_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$APEX_CHECKS_DIR/lib/common.sh"

RELEASE_BUILD=${RELEASE_BUILD:-0}
case $RELEASE_BUILD in
    0 | 1) ;;
    *)
        fail "RELEASE_BUILD must be 0 or 1, got '$RELEASE_BUILD'"
        finish
        ;;
esac

# The trust mapping of ADR 0012 and the M1 contract (section 2): one line per trusted
# key, repository<TAB>key path. A key rotation or an emergency policy changes this and
# policy.json in the same reviewed change (keys/README.md); CI keys never sign for
# ghcr.io/sekirokenjii/apex.
TRUST_MAP='ghcr.io/sekirokenjii/apex	/usr/share/apex/keys/release.pub
ghcr.io/sekirokenjii/apex	/usr/share/apex/keys/release-backup.pub
ghcr.io/sekirokenjii/apex-testing	/usr/share/apex/keys/ci.pub'

KEYDIR=$(rootpath /usr/share/apex/keys)
POLICY=$(rootpath /usr/share/apex/containers/policy.json)
REQUIRED='release ci release-backup'

for k in $REQUIRED; do
    if [ -s "$KEYDIR/$k.pub" ]; then
        pass "present: /usr/share/apex/keys/$k.pub"
    else
        fail "missing or empty: /usr/share/apex/keys/$k.pub"
    fi
done

make_tmpdir

# --- policy.json ---------------------------------------------------------------------
if [ ! -s "$POLICY" ]; then
    fail "missing or empty: /usr/share/apex/containers/policy.json"
elif ! command -v python3 >/dev/null 2>&1; then
    fail "python3 not available: the trust mapping of policy.json cannot be checked"
else
    # Prints one referenced key path per line, or one problem per line on stderr and
    # exits 1.
    if python3 - "$POLICY" "$TRUST_MAP" >"$TMPD/keypaths" 2>"$TMPD/policy.err" <<'PY'
import json
import sys

problems = []


def problem(msg):
    problems.append(msg)


try:
    with open(sys.argv[1], encoding="utf-8") as f:
        policy = json.load(f)
except (OSError, ValueError) as e:
    sys.exit("does not parse: %s" % e)

expected = {}
for line in sys.argv[2].splitlines():
    repo, _, key = line.partition("\t")
    expected.setdefault(repo, set()).add(key)

if not isinstance(policy, dict):
    sys.exit("is not a JSON object")
extra = sorted(set(policy) - {"default", "transports"})
if extra:
    problem("unexpected top-level keys %s" % extra)
if policy.get("default") != [{"type": "reject"}]:
    problem('top-level default is not exactly [{"type": "reject"}]: %s'
            % json.dumps(policy.get("default")))

transports = policy.get("transports")
if not isinstance(transports, dict) or set(transports) != {"docker"}:
    problem('transports must hold only "docker", found %s'
            % json.dumps(sorted(transports) if isinstance(transports, dict) else transports))
docker = transports.get("docker") if isinstance(transports, dict) else None
if not isinstance(docker, dict):
    docker = {}
    problem('transports.docker is missing or not an object')
if set(docker) != set(expected):
    problem("docker scopes are %s, expected exactly %s"
            % (sorted(docker), sorted(expected)))

paths = []
for scope in sorted(expected):
    reqs = docker.get(scope)
    if reqs is None:
        continue
    where = "docker[%s]" % scope
    if not isinstance(reqs, list) or len(reqs) != 1 or not isinstance(reqs[0], dict):
        problem("%s must be a list of exactly one requirement: %s" % (where, json.dumps(reqs)))
        continue
    req = reqs[0]
    extra = sorted(set(req) - {"type", "keyPath", "keyPaths", "signedIdentity"})
    if extra:
        problem("%s has unexpected fields %s" % (where, extra))
    if req.get("type") != "sigstoreSigned":
        problem("%s type is %s, not sigstoreSigned" % (where, json.dumps(req.get("type"))))
    if req.get("signedIdentity") != {"type": "matchRepository"}:
        problem('%s signedIdentity is not exactly {"type": "matchRepository"}: %s'
                % (where, json.dumps(req.get("signedIdentity"))))
    if ("keyPath" in req) == ("keyPaths" in req):
        problem("%s must have exactly one of keyPath and keyPaths" % where)
        continue
    keys = [req["keyPath"]] if "keyPath" in req else req["keyPaths"]
    if not isinstance(keys, list) or not keys or not all(isinstance(k, str) for k in keys):
        problem("%s key paths are not a non-empty list of strings: %s" % (where, json.dumps(keys)))
        continue
    if len(set(keys)) != len(keys):
        problem("%s lists a key twice: %s" % (where, keys))
    if set(keys) != expected[scope]:
        problem("%s trusts %s, expected exactly %s"
                % (where, sorted(set(keys)), sorted(expected[scope])))
    paths.extend(keys)

if problems:
    for p in problems:
        print(p, file=sys.stderr)
    sys.exit(1)
for p in paths:
    print(p)
PY
    then
        pass "policy.json has exactly the ADR 0012 trust mapping (default reject)"
        while IFS= read -r kp; do
            [ -n "$kp" ] || continue
            if [ -s "$(rootpath "$kp")" ]; then
                pass "policy key exists: $kp"
            else
                fail "policy.json references a missing key: $kp"
            fi
        done <"$TMPD/keypaths"
        [ -s "$TMPD/keypaths" ] || fail "policy.json references no keyPath/keyPaths"
    else
        [ -s "$TMPD/policy.err" ] || echo "python3 failed without a message" >"$TMPD/policy.err"
        while IFS= read -r line; do
            fail "policy.json: $line"
        done <"$TMPD/policy.err"
    fi
fi

if [ "$RELEASE_BUILD" != 1 ]; then
    skip "not a release build (RELEASE_BUILD=0): key material may be placeholders"
    finish
fi

# --- Release build: keys must be real --------------------------------------------------
# der_of FILE OUT: extract the base64 body of the single PUBLIC KEY block into OUT.b64
# and decode it into OUT.
der_of() {
    blocks=$(grep -c '^-----BEGIN PUBLIC KEY-----$' "$1" || true)
    ends=$(grep -c '^-----END PUBLIC KEY-----$' "$1" || true)
    [ "$blocks" -eq 1 ] && [ "$ends" -eq 1 ] || return 1
    sed -n '/^-----BEGIN PUBLIC KEY-----$/,/^-----END PUBLIC KEY-----$/p' "$1" |
        sed -e '1d' -e '$d' | tr -d ' \r\n' >"$2.b64"
    base64 -d <"$2.b64" >"$2" 2>/dev/null
}

found=0
for f in "$KEYDIR"/*.pub; do
    [ -f "$f" ] || continue
    found=$((found + 1))
    rel=$(unroot "$f")
    name=$(basename "$f" .pub)
    # Look for markers outside the base64 body only (random base64 can spell words).
    if grep -Ev '^[A-Za-z0-9+/=]+$' "$f" | grep -Eiq 'placeholder|replace[ _-]?me|changeme|dummy|example|todo|not a real key'; then
        fail "$rel contains a placeholder marker"
        continue
    fi
    if ! der_of "$f" "$TMPD/$name.der"; then
        fail "$rel is not exactly one decodable PEM PUBLIC KEY block"
        continue
    fi
    if command -v openssl >/dev/null 2>&1; then
        if openssl pkey -pubin -inform DER -in "$TMPD/$name.der" -noout 2>/dev/null; then
            pass "$rel is a valid public key (openssl)"
        else
            fail "$rel does not parse as a public key (openssl)"
        fi
    else
        # SubjectPublicKeyInfo is a DER SEQUENCE (0x30); the smallest real one
        # (Ed25519) is 44 bytes, ECDSA P-256 is 91.
        first=$(od -An -tx1 -N1 "$TMPD/$name.der" | tr -d ' \n')
        size=$(wc -c <"$TMPD/$name.der" | tr -d ' ')
        if [ "$first" = 30 ] && [ "$size" -ge 44 ]; then
            pass "$rel decodes to a $size-byte DER SEQUENCE (openssl unavailable: structural check only)"
        else
            fail "$rel does not decode to a DER SubjectPublicKeyInfo"
        fi
    fi
done
[ "$found" -gt 0 ] || fail "no *.pub files in /usr/share/apex/keys"

# The three roles must hold three different keys.
for pair in release:ci release:release-backup ci:release-backup; do
    a=${pair%%:*}
    b=${pair#*:}
    # Compare the normalised base64 bodies (cmp is in diffutils, which the image lacks).
    if [ -s "$TMPD/$a.der.b64" ] && [ -s "$TMPD/$b.der.b64" ] &&
        [ "$(cat "$TMPD/$a.der.b64")" = "$(cat "$TMPD/$b.der.b64")" ]; then
        fail "$a.pub and $b.pub are the same key"
    fi
done

finish
