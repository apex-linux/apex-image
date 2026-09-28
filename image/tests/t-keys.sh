#!/bin/sh
# image/checks/keys.sh: policy.json must hold exactly the trust mapping.
. "$(dirname -- "$0")/lib.sh"

command -v python3 >/dev/null 2>&1 || skip_all "python3 not found"

POLICY_SRC=$IMAGE_DIR/system_files/usr/share/apex/containers/policy.json

# mkroot NAME: prints the path of a root with the committed keys and policy.
mkroot() {
    r=$T/$1
    mkdir -p "$r/usr/share/apex/containers" "$r/usr/share/apex/keys"
    cp "$IMAGE_DIR"/system_files/usr/share/apex/keys/*.pub "$r/usr/share/apex/keys/"
    cp "$POLICY_SRC" "$r/usr/share/apex/containers/policy.json"
    printf '%s\n' "$r"
}

# edit ROOT PYTHON: runs PYTHON on ROOT's policy.json, loaded as `p`.
edit() {
    python3 - "$1/usr/share/apex/containers/policy.json" "$2" <<'PY'
import json, sys
path, code = sys.argv[1], sys.argv[2]
with open(path) as f:
    p = json.load(f)
exec(code)
with open(path, "w") as f:
    json.dump(p, f)
PY
}

keys() {
    run env ROOT="$1" RELEASE_BUILD=0 "$SH" "$CHECKS/keys.sh"
}

APEX='ghcr.io/sekirokenjii/apex'
TESTING='ghcr.io/sekirokenjii/apex-testing'

r=$(mkroot good)
keys "$r"
expect_rc "the committed policy passes" 0
expect_out "and is reported as the exact mapping" '^PASS keys: policy.json has exactly the ADR 0012 trust mapping'

n=0
while IFS='|' read -r name code; do
    n=$((n + 1))
    r=$(mkroot "bad$n")
    edit "$r" "$code"
    keys "$r"
    expect_rc "rejected: $name" 1
done <<EOF
CI key trusted for the stable repository|p["transports"]["docker"]["$APEX"][0]["keyPaths"].append("/usr/share/apex/keys/ci.pub")
CI key instead of the release keys|r = p["transports"]["docker"]["$APEX"][0]; del r["keyPaths"]; r["keyPath"] = "/usr/share/apex/keys/ci.pub"
release key trusted for testing|p["transports"]["docker"]["$TESTING"][0]["keyPath"] = "/usr/share/apex/keys/release.pub"
backup key dropped|p["transports"]["docker"]["$APEX"][0]["keyPaths"].pop()
insecureAcceptAnything for the registry|p["transports"]["docker"]["ghcr.io"] = [{"type": "insecureAcceptAnything"}]
second requirement in a scope|p["transports"]["docker"]["$TESTING"].append({"type": "insecureAcceptAnything"})
extra transport|p["transports"]["docker-daemon"] = {"": [{"type": "insecureAcceptAnything"}]}
default accepts|p["default"] = [{"type": "insecureAcceptAnything"}]
default reject plus accept|p["default"].append({"type": "insecureAcceptAnything"})
keyData next to the key paths|p["transports"]["docker"]["$APEX"][0]["keyData"] = "AAAA"
signedBy instead of sigstoreSigned|p["transports"]["docker"]["$TESTING"][0]["type"] = "signedBy"
remapIdentity|p["transports"]["docker"]["$APEX"][0]["signedIdentity"] = {"type": "remapIdentity", "prefix": "ghcr.io", "signedPrefix": "ghcr.io"}
matchRepoDigestOrExact|p["transports"]["docker"]["$APEX"][0]["signedIdentity"] = {"type": "matchRepoDigestOrExact"}
testing scope missing|del p["transports"]["docker"]["$TESTING"]
both keyPath and keyPaths|p["transports"]["docker"]["$TESTING"][0]["keyPaths"] = ["/usr/share/apex/keys/ci.pub"]
duplicate key path|p["transports"]["docker"]["$APEX"][0]["keyPaths"].append("/usr/share/apex/keys/release.pub")
extra top-level field|p["specificPolicies"] = {}
EOF

r=$(mkroot named)
edit "$r" "p['transports']['docker']['$APEX'][0]['keyPaths'].append('/usr/share/apex/keys/ci.pub')"
keys "$r"
expect_out "the failure names the wrong trust" "^FAIL keys: policy.json: docker\\[$APEX\\] trusts .*ci\\.pub"

r=$(mkroot order)
edit "$r" "p['transports']['docker']['$APEX'][0]['keyPaths'].reverse()"
keys "$r"
expect_rc "keyPaths order is free" 0

mkdir -p "$T/nopy"
# "$SH" too: the shell under test may be dash, which run.sh uses on Fedora.
for tool in "$SH" sh bash dirname mktemp rm cat grep sed tr od wc basename head tail paste; do
    if p=$(command -v "$tool"); then ln -sf "$p" "$T/nopy/$tool"; fi
done
r=$(mkroot nopython)
run env PATH="$T/nopy" ROOT="$r" RELEASE_BUILD=0 "$SH" "$CHECKS/keys.sh"
expect_rc "no python3 fails" 1
expect_out "and says why" '^FAIL keys: python3 not available'

done_testing
