#!/bin/sh
# image/checks/polkit.sh: apex-system's polkit actions parse strictly and name the Apex vendor.
. "$(dirname -- "$0")/lib.sh"

command -v python3 >/dev/null 2>&1 || skip_all "python3 not found"

POLICY=$APEX_SYSTEM_SRC/crates/apex-updated/data/io.github.apex-linux.apex.update.policy
NAME=io.github.apex-linux.apex.update.policy
ACTIONS=usr/share/polkit-1/actions

# mkroot NAME [SED]: a root with apex-system's policy, edited by SED when given.
mkroot() {
    r=$T/$1
    mkdir -p "$r/$ACTIONS"
    sed -e "${2:-}" "$POLICY" >"$r/$ACTIONS/$NAME"
    printf '%s\n' "$r"
}

check() {
    run env ROOT="$1" "$SH" "$CHECKS/polkit.sh"
}

check "$(mkroot good)"
expect_rc "apex-system's policy passes" 0
expect_out "and names its six actions" \
    "^PASS polkit: /$ACTIONS/$NAME: 6 actions, vendor Apex: io\\.github\\.apex-linux\\.apex\\.update\\.check .*\\.configure$"

check "$(mkroot novendor '/<vendor>Apex<\/vendor>/d')"
expect_rc "a missing vendor fails" 1
expect_out "and says the file has none" "io\\.github\\.apex-linux\\.apex\\.update\\.check's vendor is '' \\(no <vendor>\\)"

check "$(mkroot blank 's/<vendor>Apex</<vendor> </')"
expect_rc "a blank vendor fails" 1
expect_out "naming the file's vendor" "update\\.rollback's vendor is '' \\(the file's <vendor>\\), not 'Apex'"

check "$(mkroot override '/<action id="io.github.apex-linux.apex.update.apply">/a\
    <vendor>Other</vendor>')"
expect_rc "an action's own vendor overrides the file's" 1
expect_out "and is named" "update\\.apply's vendor is 'Other' \\(its own <vendor>\\)"
expect_no_out "the other actions still take the file's" "update\\.check's vendor"

check "$(mkroot truncated '/<\/policyconfig>/d')"
expect_rc "a truncated file fails, though polkitd reads it" 1
expect_out "and says it does not parse" "^FAIL polkit: /$ACTIONS/$NAME does not parse \\(no element found"

check "$(mkroot illformed 's/<\/message>/<\/mesage>/')"
expect_rc "an ill-formed file fails" 1

check "$(mkroot nodefaults '/<action id="io.github.apex-linux.apex.update.discard">/,/<\/action>/{/defaults>/d;/allow_/d}')"
expect_rc "an action without defaults fails" 1
expect_out "naming the action" "update\\.discard has no defaults"

check "$(mkroot nomessage '/<action id="io.github.apex-linux.apex.update.check">/,/<\/action>/{/<message>/d}')"
expect_rc "an action without a message fails" 1
expect_out "naming what is missing" "update\\.check has no message"

r=$(mkroot translated)
sed -i 's|<description>Check for system updates</description>|<description xml:lang="de">Nach Updates suchen</description>|' \
    "$r/$ACTIONS/$NAME"
check "$r"
expect_rc "only a translated description is not a description" 1
expect_out "and is named" "update\\.check has no description"

r=$T/none
mkdir -p "$r/$ACTIONS"
check "$r"
expect_rc "no Apex policy fails" 1
expect_out "and says so" "^FAIL polkit: no io\\.github\\.apex-linux\\.\\*\\.policy"

r=$(mkroot two)
sed 's/apex\.update/apex.other/g' "$POLICY" >"$r/$ACTIONS/io.github.apex-linux.apex.other.policy"
sed -i '/<vendor>Apex<\/vendor>/d' "$r/$ACTIONS/io.github.apex-linux.apex.other.policy"
check "$r"
expect_rc "every Apex policy is checked" 1
expect_out "the good one passes" "^PASS polkit: /$ACTIONS/$NAME: 6 actions"
expect_out "the bad one fails" "apex\\.other\\.check's vendor is ''"

done_testing
