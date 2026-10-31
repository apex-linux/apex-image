#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
    cat >&2 <<'EOF'

The contracts between the image and the components it takes, checked against the
component checkouts APEX_SYSTEM_SRC, APEX_DESKTOP_SRC and APEX_GNOME_SRC (default: the
pinned clones of tools/components.sh fetch), and APEX_KERNEL_SRC when it is set.

  contracts.sh      exit 0 when every contract holds
EOF
    exit 2
}

(($# == 0)) || usage
require python3 cmp

python3 - "$APEX_SYSTEM_SRC/hardware/m7400qc/profile.toml" "$APEX_ROOT/image" <<'EOF' || die "contracts: see above"
import pathlib
import sys
import tomllib

profile_path, image = sys.argv[1], pathlib.Path(sys.argv[2])
with open(profile_path, "rb") as f:
    firmware = tomllib.load(f)["firmware"]


def listed(path):
    names = (line.split("#")[0].strip() for line in path.read_text().splitlines())
    return [name for name in names if name]


problems = []
base = listed(image / "packages/base.txt")
missing = [p for p in firmware["packages"] if p not in base]
if missing:
    problems.append(f"image/packages/base.txt lacks [firmware].packages of {profile_path}: {' '.join(missing)}")
files = listed(image / "checks/firmware-files.txt")
if files != firmware["required_files"]:
    problems.append(
        f"image/checks/firmware-files.txt is not [firmware].required_files of {profile_path}, in order:\n"
        f"  list:    {' '.join(files)}\n  profile: {' '.join(firmware['required_files'])}"
    )
for p in problems:
    print(f"error: {p}", file=sys.stderr)
sys.exit(1 if problems else 0)
EOF
log "contracts: the image installs and checks the firmware of the hardware profile"

python3 - "$APEX_ROOT/image/Containerfile" "$APEX_SYSTEM_SRC/crates/apexctl/src/manifest.rs" <<'EOF' || die "contracts: see above"
import re
import sys

containerfile, manifest_rs = (open(p, encoding="utf-8").read() for p in sys.argv[1:])
written = set(re.findall(r'echo ([a-z0-9-]+) >>"\$degraded"', containerfile))
accepted = re.search(r"DEGRADED_COMPONENTS: &\[&str\] = &\[([^\]]*)\]", manifest_rs)
if not written or not accepted:
    sys.exit("error: found no degraded names in the Containerfile, or no DEGRADED_COMPONENTS in apexctl")
refused = sorted(written - set(re.findall(r'"([^"]+)"', accepted.group(1))))
if refused:
    sys.exit(f"error: the Containerfile can label the image degraded={','.join(refused)}, "
             f"but the pinned apexctl build manifest refuses it ({sys.argv[2]})")
EOF
log "contracts: apexctl build manifest accepts every degraded name the image can write"

# Every layer feature must be a choice of the kill switch: gsettings refuses any other name.
gnome=$(component_at apex-gnome "$APEX_GNOME_SRC")
desktop=$(component_at apex-desktop "$APEX_DESKTOP_SRC")
features=$(layer_features "$APEX_GNOME_SRC/$APEX_LAYER_JS" 2>/dev/null) ||
    die "contracts: $gnome's $APEX_LAYER_JS has no FEATURES_IN_ENABLE_ORDER, or it is empty"
choices=$(python3 - "$APEX_DESKTOP_SRC/desktop/schemas/io.github.apex_linux.Apex.Desktop.gschema.xml" <<'EOF'
import sys
import xml.etree.ElementTree as ET

try:
    root = ET.parse(sys.argv[1]).getroot()
except (OSError, ET.ParseError) as e:
    sys.exit(f"error: cannot read {sys.argv[1]}: {e}")
key = root.find("./schema[@id='io.github.apex_linux.Apex.Desktop']/key[@name='disabled-features']")
if key is None:
    sys.exit("error: schema io.github.apex_linux.Apex.Desktop has no disabled-features key")
names = [c.get("value") for c in key.findall("./choices/choice")]
if not names:
    sys.exit("error: disabled-features has no <choices>: it takes any name, so none can be checked")
print("\n".join(names))
EOF
) || die "contracts: $desktop: see above"
lacking=$(comm -23 <(sort -u <<<"$features") <(sort -u <<<"$choices") | paste -sd' ' -)
[[ -z $lacking ]] ||
    die "contracts: $gnome's layer has features that $desktop's disabled-features cannot turn off (not in its <choices>): $lacking"
unused=$(comm -13 <(sort -u <<<"$features") <(sort -u <<<"$choices") | paste -sd' ' -)
[[ -z $unused ]] || warn "contracts: $desktop's disabled-features offers choices that $gnome's layer has no feature for: $unused"
log "contracts: every feature of $gnome's layer can be turned off by $desktop's disabled-features"

# Every dock favourite ships: a .desktop of a package the image lists, or a preinstalled Flatpak.
readonly FAVORITES=desktop/schemas/90_apex.gschema.override
favorites=$(python3 - "$APEX_DESKTOP_SRC/$FAVORITES" <<'EOF'
import ast
import sys

group = None
try:
    lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
except OSError as e:
    sys.exit(f"error: cannot read {sys.argv[1]}: {e}")
for line in lines:
    line = line.strip()
    if line.startswith("["):
        group = line
    elif group == "[org.gnome.shell]" and line.split("=", 1)[0].strip() == "favorite-apps":
        apps = ast.literal_eval(line.split("=", 1)[1].strip())
        if not apps:
            sys.exit(f"error: {sys.argv[1]}: favorite-apps is empty")
        print("\n".join(apps))
        sys.exit(0)
sys.exit(f"error: {sys.argv[1]} sets no [org.gnome.shell] favorite-apps")
EOF
) || die "contracts: $desktop: see above"
command -v "${APEX_DNF:-dnf5}" >/dev/null ||
    die "contracts: the dock favourites resolve with dnf5 repoquery (run in fedora:45, as the CI job does)"
listed=$(cat "$APEX_ROOT"/image/packages/{base,gnome,apex}.txt | sed 's/#.*//; s/[[:space:]]//g; /^$/d' | sort -u)
excluded=$(sed 's/#.*//; s/[[:space:]]//g; /^$/d' "$APEX_ROOT/image/packages/exclude.txt" | sort -u)
preinstalled=$(sed -n 's/^\[Flatpak Preinstall \([^]]*\)\]$/\1/p' \
    "$APEX_ROOT"/image/system_files/usr/share/flatpak/preinstall.d/*.preinstall | sort -u)
mapfile -t repos < <(dnf_repo_args)
dead=()
while IFS= read -r app; do
    if grep -qxF -- "${app%.desktop}" <<<"$preinstalled"; then
        continue
    fi
    providers=$("${APEX_DNF:-dnf5}" -q repoquery --setopt=optional_metadata_types=filelists "${repos[@]}" \
        --whatprovides "/usr/share/applications/$app" --qf '%{name}\n' | sed '/^$/d' | sort -u) ||
        die "contracts: dnf5 repoquery for $app failed"
    if [[ -z $providers ]]; then
        dead+=("$app (no package of the compose's repositories ships it, and no preinstall names it)")
    elif comm -12 <(printf '%s\n' "$providers") <(printf '%s\n' "$excluded") | grep -q .; then
        dead+=("$app (shipped by $(paste -sd' ' <<<"$providers"), which exclude.txt removes)")
    elif ! comm -12 <(printf '%s\n' "$providers") <(printf '%s\n' "$listed") | grep -q .; then
        dead+=("$app (shipped by $(paste -sd' ' <<<"$providers"), which image/packages does not list)")
    fi
done <<<"$favorites"
if ((${#dead[@]})); then
    printf 'error: %s favourite %s\n' "$desktop" "${dead[@]}" >&2
    die "contracts: $desktop's dock has favourites the image does not ship"
fi
log "contracts: every dock favourite of $desktop is in the image or preinstalled"

# The compose dnf-installs these lists from the same repositories; a name that stopped resolving
# would fail the VM's build two hours in, so it fails here, and Fedora, not the PR, moved.
where=$(printf '%s\n' "${repos[@]}" | sed -n 's/^--repo=//p' | paste -sd+)
gone=()
for list in base gnome; do
    file=$APEX_ROOT/image/packages/$list.txt
    mapfile -t names < <(sed 's/#.*//; s/[[:space:]]//g' "$file")
    wanted=()
    for name in "${names[@]}"; do [[ -z $name ]] || wanted+=("$name"); done
    ((${#wanted[@]})) || die "contracts: image/packages/$list.txt lists no package"
    found=$("${APEX_DNF:-dnf5}" -q repoquery "${repos[@]}" --qf '%{name}\n' -- "${wanted[@]}" | sort -u) ||
        die "contracts: dnf5 repoquery of image/packages/$list.txt failed"
    for i in "${!names[@]}"; do
        [[ -z ${names[i]} ]] || grep -qxF -- "${names[i]}" <<<"$found" ||
            gone+=("$list.txt:$((i + 1)) '${names[i]}' no longer resolves in $where (a Fedora change, not this PR's, unless it added the line)")
    done
done
if ((${#gone[@]})); then
    printf 'error: image/packages/%s\n' "${gone[@]}" >&2
    die "contracts: the compose would not find every package base.txt and gnome.txt list"
fi
log "contracts: every package of base.txt and gnome.txt resolves in $where"

# Copies of one component's files that another keeps, by explicit path, so a moved copy
# fails too: COPY ORIGINAL pairs.
readonly SCHEMA=io.github.apex_linux.Apex.Desktop.gschema.xml
copies=(
    "$APEX_GNOME_SRC/tests/layer/fixtures/$SCHEMA" "$APEX_DESKTOP_SRC/desktop/schemas/$SCHEMA"
    "$APEX_GNOME_SRC/tests/layer/fixtures/apex-shell-safe.service"
    "$APEX_DESKTOP_SRC/desktop/systemd/user/apex-shell-safe.service"
)
if [[ -d $APEX_SYSTEM_SRC/crates/apex-session-agent ]]; then
    copies+=("$APEX_SYSTEM_SRC/crates/apex-session-agent/tests/data/$SCHEMA" "$APEX_DESKTOP_SRC/desktop/schemas/$SCHEMA")
fi
# Settings' Software Updates page generates its D-Bus code from a copy of Update1's XML.
readonly UPDATE1=io.github.apex_linux.Apex.Update1.xml
if [[ -e $APEX_GNOME_SRC/desktop/control-center/panels/apex/$UPDATE1 ]]; then
    copies+=("$APEX_GNOME_SRC/desktop/control-center/panels/apex/$UPDATE1" "$APEX_SYSTEM_SRC/crates/apex-dbus/data/$UPDATE1")
fi
stale=0
for ((i = 0; i < ${#copies[@]}; i += 2)); do
    if [[ ! -f ${copies[i + 1]} ]]; then
        printf 'error: %s is missing\n' "${copies[i + 1]}" >&2
        stale=1
    elif ! cmp -s -- "${copies[i]}" "${copies[i + 1]}"; then
        printf 'error: %s is missing or differs from %s: copy it from the pinned original\n' \
            "${copies[i]}" "${copies[i + 1]}" >&2
        stale=1
    fi
done
((stale == 0)) || die "contracts: see above"
log "contracts: every copy of a component's file equals the pinned original"

# A component's new copy of a shipped file is caught here, not only when someone adds its row above.
readonly COPIES_ALLOWED=${APEX_COPIES_ALLOWED:-$APEX_ROOT/.github/scripts/copies-allowed.txt}
python3 - "$COPIES_ALLOWED" "${#copies[@]}" "${copies[@]}" \
    apex-system "$APEX_SYSTEM_SRC" packaging/apex.spec Makefile \
    apex-desktop "$APEX_DESKTOP_SRC" packaging/apex-desktop.spec - \
    apex-gnome "$APEX_GNOME_SRC" - - apex-kernel "${APEX_KERNEL_SRC:-}" - - <<'EOF' || die "contracts: see above"
import os
import re
import shlex
import sys

allowed_file, n, *rest = sys.argv[1:]
listed, rest = {os.path.realpath(p) for p in rest[: int(n)]}, rest[int(n) :]
trees = [tuple(rest[i : i + 4]) for i in range(0, len(rest), 4) if rest[i + 1]]
# apex-image is not scanned: its lane fixtures copy apex-gnome's recipes, frozen so the lane's
# tests don't move with the pin, and no spec ships a recipe, so an allow line for one would be stale.
SKIP = {".git", "_build", "node_modules", "target"}
SECTIONS = ("%files", "%changelog", "%check", "%install", "%prep", "%build", "%description", "%package")
problems, shipped = [], {}


def logical(path):
    try:
        return open(path, encoding="utf-8").read().replace("\\\n", " ").splitlines()
    except OSError as e:
        sys.exit(f"error: cannot read {e.filename}: {e.strerror}")


def sources(words):
    words = iter(words)
    for w in words:
        if w == "-t":
            next(words, None)
        elif not w.startswith("-") and "buildroot" not in w and "DESTDIR" not in w and "$(1)" not in w and "*" not in w:
            yield w


for name, root, spec, makefile in trees:
    if spec == "-":
        continue
    section = None
    for line in logical(f"{root}/{spec}"):
        words = line.split()
        if words and words[0] in SECTIONS:
            section = words[0]
        elif section == "%files" and words and words[0] not in ("%license", "%doc", "%dir") and words[0][0] != "#":
            if not words[-1].endswith("/") and "*" not in words[-1]:
                shipped.setdefault(os.path.basename(words[-1]), (name, words[-1]))
        elif section == "%install" and words[:1] == ["install"]:
            for src in sources(shlex.split(line)[1:]):
                shipped.setdefault(os.path.basename(src), (name, f"{src} (installed by {spec})"))
    if not any(owner == name for owner, _ in shipped.values()):
        problems.append(f"{root}/{spec} ships no file in its %files")
    if makefile == "-":
        continue
    lines = logical(f"{root}/{makefile}")
    found = 0
    variables = dict(m.groups() for m in (re.match(r"(\w+)\s*[:?]?=\s*(\S*)", l) for l in lines) if m)
    for line in lines:
        if "$(INSTALL)" not in line:
            continue
        for src in sources(line.split("$(INSTALL)", 1)[1].replace("'", " ").split()):
            for _ in range(5):
                src = re.sub(r"\$\((\w+)\)", lambda m: variables.get(m[1], m[0]), src)
            if "$(" not in os.path.basename(src):
                found += 1
                shipped.setdefault(os.path.basename(src), (name, f"{src} (installed by {makefile})"))
    if not found:
        problems.append(f"{root}/{makefile} installs no file with $(INSTALL)")
allowed = {}
for number, line in enumerate(open(allowed_file, encoding="utf-8"), 1):
    words = line.split("#", 1)[0].split(None, 2)
    if not words:
        continue
    if len(words) < 3:
        problems.append(f"{allowed_file}:{number}: want COMPONENT PATH REASON, got {line.strip()!r}")
        continue
    allowed[words[0], words[1]] = number
seen = set()
for name, root, *_ in trees:
    for top, dirs, files in os.walk(root):
        dirs[:] = sorted(d for d in dirs if d not in SKIP)
        for f in sorted(files):
            owner, installed = shipped.get(f, (name, ""))
            path = os.path.join(top, f)
            if owner == name or os.path.islink(path) or os.path.realpath(path) in listed:
                continue
            rel = os.path.relpath(path, root)
            if (name, rel) in allowed:
                seen.add((name, rel))
                continue
            problems.append(
                f"{name} {rel} has the name of {owner}'s {installed}, but no copy row compares it: "
                f"add it to contracts.sh's copies, or allow it in {os.path.basename(allowed_file)} with a reason"
            )
problems += [
    f"{allowed_file}:{number}: {name} {rel} is no longer a copy of a shipped file: delete the line"
    for (name, rel), number in allowed.items()
    if (name, rel) not in seen
]
for p in problems:
    print(f"error: {p}", file=sys.stderr)
sys.exit(1 if problems else 0)
EOF
log "contracts: every file of a component named like another's shipped file is a compared copy"

# G2 sets 90_apex's weekday, input-source, font and icon keys from its own copies, so its shells
# match the image's, Super+Space stays Spotlight's there too, and its fonts and icons are the image's.
readonly G2_PARTS=tests/shots/parts.sh G2_SCRIPTS=(tests/shots/patched.sh tests/shots/smoke.sh)
python3 - "$APEX_DESKTOP_SRC/$FAVORITES" "$APEX_GNOME_SRC" "$G2_PARTS" "${G2_SCRIPTS[@]}" <<'EOF' ||
import re
import shlex
import sys

override, gnome, parts, *scripts = sys.argv[1:]
KEYBINDINGS, INTERFACE = "org.gnome.desktop.wm.keybindings", "org.gnome.desktop.interface"
COPIED = {
    "INPUT_SOURCE_KEYS": (KEYBINDINGS, "switch-input-source"),
    "INPUT_SOURCE_BACKWARD_KEYS": (KEYBINDINGS, "switch-input-source-backward"),
    "SESSION_FONT_NAME": (INTERFACE, "font-name"),
    "SESSION_DOCUMENT_FONT_NAME": (INTERFACE, "document-font-name"),
    "SESSION_MONOSPACE_FONT_NAME": (INTERFACE, "monospace-font-name"),
    "SESSION_FONT_HINTING": (INTERFACE, "font-hinting"),
    "SESSION_ICON_THEME": (INTERFACE, "icon-theme"),
}
try:
    override_lines = open(override, encoding="utf-8").read().splitlines()
    parts_lines = open(f"{gnome}/{parts}", encoding="utf-8").read().splitlines()
    texts = {s: open(f"{gnome}/{s}", encoding="utf-8").read() for s in scripts}
except OSError as e:
    sys.exit(f"error: cannot read {e.filename}: {e.strerror}")
group, keys = None, {}
for line in override_lines:
    line = line.strip()
    if line.startswith("["):
        group = line.strip("[]")
    elif "=" in line and not line.startswith("#"):
        key, value = (s.strip() for s in line.split("=", 1))
        keys[group, key] = value
copies = []
for line in parts_lines:
    try:
        words = shlex.split(line, comments=True)
    except ValueError:
        continue
    if len(words) == 2 and words[0] == "readonly" and words[1].split("=", 1)[0] in COPIED:
        name, value = words[1].split("=", 1)
        copies.append((f"{parts} {name}", *COPIED[name], value))
problems = []
names = [where.split()[-1] for where, *_ in copies]
if off := [name for name in COPIED if names.count(name) != 1]:
    problems.append(f"{gnome}/{parts} does not copy {', '.join(off)} exactly once")
for script, text in texts.items():
    weekdays = re.findall(r"clock-show-weekday=(\w+)", text)
    if not weekdays:
        problems.append(f"{gnome}/{script} sets no clock-show-weekday")
    copies += [(script, INTERFACE, "clock-show-weekday", value) for value in weekdays]
problems += [
    f"{gnome}/{where} has {value!r}, but {override} sets [{group}] {key}={keys.get((group, key))!r}"
    for where, group, key, value in copies
    if keys.get((group, key)) != value
]
for p in problems:
    print(f"error: {p}", file=sys.stderr)
sys.exit(1 if problems else 0)
EOF
    die "contracts: $gnome's G2 settings: see above"
log "contracts: G2's shells set $desktop's weekday, input-source, font and icon keys as the image does"

qemu_parity "$APEX_ROOT/.github/scripts/qualify.sh" "$APEX_ROOT/tools/builder-vm/desktop-vm.sh" ||
    die "contracts: G4's VM and the desktop VM must run the same guest"
log "contracts: G4's VM and the desktop VM run QEMU with one -machine and -cpu, and vmport=off"

units=$(g4_user_units "$APEX_ROOT/.github/scripts/qualify.sh" "$APEX_SYSTEM_SRC" "$APEX_DESKTOP_SRC") ||
    die "contracts: G4's login contract and the components' user units disagree"
log "contracts: G4 expects exactly the Apex user units the components enable ($units)"
