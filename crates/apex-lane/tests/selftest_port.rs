#![allow(clippy::expect_used, reason = "test helpers panic on broken fixtures")]

use std::path::{Path, PathBuf};

use apex_lane::container::stored_builds;
use apex_lane::core::checksig::checksig_ok;
use apex_lane::core::lock;
use apex_lane::core::names::nevra_name;
use apex_lane::core::pkg_env;
use apex_lane::core::release::{StoredBuild, release_for};
use apex_lane::core::series::{self, Files};
use apex_lane::core::source1::member_ok;
use apex_lane::core::spec_edit::{self, ApplyError, NoAnchor, Values};
use apex_lane::core::text;
use apex_lane::pkg::{self, Parse};

const PKG_ENV: &str = "# a comment
source=fedora-srpm
srpm=gnome-shell
on_fail=hold
family=gnome-shell
install=gnome-shell gnome-shell-common
pin=mutter
mirror=mutter mutter-common
source1=desktop/shell
source1_paths=apex.gresource.xml js/ui/apex/
prep_moved=a/b.css:a/apex/stock/b.css
";

fn recipes() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/recipes")
}

#[test]
fn pkg_env_a_list_value() {
    let env = pkg_env::parse("pkg.env", PKG_ENV.as_bytes()).expect("parses");
    assert_eq!(env.install.join(" "), "gnome-shell gnome-shell-common");
}

#[test]
fn pkg_env_a_single_value() {
    let env = pkg_env::parse("pkg.env", PKG_ENV.as_bytes()).expect("parses");
    assert_eq!(env.pin.as_deref(), Some("mutter"));
}

fn refused(edit: impl Fn(Vec<String>) -> Vec<String>) {
    let lines = edit(PKG_ENV.lines().map(String::from).collect());
    let text = lines.join("\n") + "\n";
    let err = pkg_env::parse("bad.env", text.as_bytes()).expect_err("refused");
    assert!(err.0.starts_with("bad.env"), "{err}");
    assert_eq!(
        apex_lane::LaneError::from(err).exit(),
        apex_lane::Exit::Usage
    );
}

fn replace(lines: Vec<String>, prefix: &str, with: &str) -> Vec<String> {
    lines
        .into_iter()
        .map(|l| {
            if l.starts_with(prefix) {
                with.to_owned()
            } else {
                l
            }
        })
        .collect()
}

fn without(lines: Vec<String>, prefix: &str) -> Vec<String> {
    lines
        .into_iter()
        .filter(|l| !l.starts_with(prefix))
        .collect()
}

fn plus(mut lines: Vec<String>, line: &str) -> Vec<String> {
    lines.push(line.to_owned());
    lines
}

#[test]
fn pkg_env_refuses_an_unknown_key() {
    refused(|l| plus(l, "colour=blue"));
}

#[test]
fn pkg_env_refuses_a_repeated_key() {
    refused(|l| plus(l, "pin=mutter"));
}

#[test]
fn pkg_env_refuses_a_missing_required_key() {
    refused(|l| without(l, "family="));
}

#[test]
fn pkg_env_refuses_a_shell_character() {
    refused(|l| replace(l, "srpm=", "srpm=$(reboot)"));
}

#[test]
fn pkg_env_refuses_a_reserved_source() {
    refused(|l| replace(l, "source=", "source=copr-srpm"));
}

#[test]
fn pkg_env_refuses_an_unknown_on_fail() {
    refused(|l| replace(l, "on_fail=", "on_fail=maybe"));
}

#[test]
fn pkg_env_refuses_mirror_without_pin() {
    refused(|l| without(l, "pin="));
}

#[test]
fn pkg_env_refuses_source1_without_source1_paths() {
    refused(|l| without(l, "source1_paths="));
}

#[test]
fn pkg_env_refuses_a_prep_moved_entry_without_to() {
    refused(|l| replace(l, "prep_moved=", "prep_moved=a/b.css"));
}

#[test]
fn pkg_env_refuses_a_line_that_is_not_key_value() {
    refused(|l| plus(l, "just words"));
}

struct Patches(tempfile::TempDir);

impl Patches {
    fn new() -> Self {
        let dir = tempfile::tempdir().expect("tempdir");
        for p in ["0001-build.patch", "0002-loader.patch", "0101-extra.patch"] {
            std::fs::write(dir.path().join(p), b"").expect("patch file");
        }
        Self(dir)
    }

    fn parse(&self, text: &str, check_files: bool) -> Result<Vec<String>, String> {
        let exists = |e: &str| self.0.path().join(e).is_file();
        let label = self.0.path().display().to_string();
        let files = if check_files {
            Files::Check {
                dir: &label,
                exists: &exists,
            }
        } else {
            Files::Skip
        };
        series::parse("series", text.as_bytes(), files).map_err(|e| e.0)
    }
}

#[test]
fn series_entries_in_order_01xx_allowed() {
    let p = Patches::new();
    assert_eq!(
        p.parse(
            "# c\n0001-build.patch\n\n0002-loader.patch  # trailing comment\n0101-extra.patch\n",
            true
        )
        .expect("parses")
        .join(" "),
        "0001-build.patch 0002-loader.patch 0101-extra.patch"
    );
}

#[test]
fn series_refuses_a_duplicate() {
    assert!(
        Patches::new()
            .parse("0001-build.patch\n0001-build.patch\n", true)
            .is_err()
    );
}

#[test]
fn series_refuses_a_path() {
    assert!(
        Patches::new()
            .parse("0001-build.patch\n../x.patch\n", true)
            .is_err()
    );
}

#[test]
fn series_refuses_a_missing_patch() {
    assert!(Patches::new().parse("0003-missing.patch\n", true).is_err());
}

#[test]
fn series_without_file_checks_takes_a_missing_patch() {
    assert_eq!(
        Patches::new()
            .parse("0003-missing.patch\n", false)
            .expect("parses"),
        ["0003-missing.patch"]
    );
}

#[test]
fn series_refuses_an_empty_series() {
    assert!(Patches::new().parse("# nothing\n", true).is_err());
}

const SPEC: &str = "Name:           x
Release:        %autorelease
Source0:        x.tar.xz
Patch:          fedora.patch
BuildRequires:  meson
BuildRequires:  mutter-devel >= %{mutter_version}
Requires:       mutter%{?_isa} >= %{mutter_version}
%prep
%autosetup -S git -n x
";

const SPEC_EDIT: &str = "replace ^Release:[[:space:]]+%autorelease$\n\tRelease:        %{autorelease}@APEX_RELEASE@\nend\n\n# c\nafter ^Source0:\n\tSource1:        @SOURCE1@\nend\nafter ^Requires:[[:space:]]+mutter%\\{\\?_isa\\}[[:space:]]\n\tRequires:       mutter%{?_isa} = @PIN_EVR@\nend\nafter ^%autosetup[[:space:]]\n\ttar -xkf %{SOURCE1}\n\tmkdir data/stock\nend\n";

fn values() -> Values {
    Values {
        apex_release: ".apex3.1".into(),
        pin_evr: "51.0-1.fc45".into(),
        source1: "apex-shell-0123456789ab.tar".into(),
    }
}

fn apply(edit: &str, spec: &str) -> Result<Vec<u8>, ApplyError> {
    let parsed = spec_edit::parse("spec-edit", edit.as_bytes()).expect("parses");
    spec_edit::apply(&parsed, spec.as_bytes(), &values(), &mut |_| {})
}

#[test]
fn spec_edit_blocks_parsed() {
    let parsed = spec_edit::parse("spec-edit", SPEC_EDIT.as_bytes()).expect("parses");
    assert_eq!(parsed.blocks.len(), 4);
}

#[test]
fn spec_edit_the_edited_spec() {
    assert_eq!(
        String::from_utf8(apply(SPEC_EDIT, SPEC).expect("applies")).expect("utf-8"),
        "Name:           x
Release:        %{autorelease}.apex3.1
Source0:        x.tar.xz
Source1:        apex-shell-0123456789ab.tar
Patch:          fedora.patch
BuildRequires:  meson
BuildRequires:  mutter-devel >= %{mutter_version}
Requires:       mutter%{?_isa} >= %{mutter_version}
Requires:       mutter%{?_isa} = 51.0-1.fc45
%prep
%autosetup -S git -n x
tar -xkf %{SOURCE1}
mkdir data/stock
"
    );
}

#[test]
fn spec_edit_an_anchor_on_two_lines_holds_the_build() {
    let err = apply(
        "after ^BuildRequires:\n\tBuildRequires:  sassc\nend\n",
        SPEC,
    )
    .expect_err("holds");
    assert_eq!(
        err.reason(),
        b"spec-edit: 'after ^BuildRequires:' matches 2 lines of the spec, not 1"
    );
    assert!(matches!(err, ApplyError::Anchor { hits: 2, .. }));
}

#[test]
fn spec_edit_an_anchor_that_matches_nothing_holds_the_build() {
    let err = apply("after ^Nope:\n\tX: y\nend\n", SPEC).expect_err("holds");
    assert_eq!(
        err.reason(),
        b"spec-edit: 'after ^Nope:' matches 0 lines of the spec, not 1"
    );
}

fn edit_refused(text: &str) {
    let err = spec_edit::parse("spec-edit", text.as_bytes()).expect_err("refused");
    assert_eq!(
        apex_lane::LaneError::from(err).exit(),
        apex_lane::Exit::Usage
    );
}

#[test]
fn spec_edit_refuses_an_unknown_placeholder() {
    edit_refused("after ^Source0:\n\tSource9: @NOPE@\nend\n");
}

#[test]
fn spec_edit_refuses_a_text_line_indented_with_spaces() {
    edit_refused("after ^Source0:\n    Source9: x\nend\n");
}

#[test]
fn spec_edit_refuses_a_block_without_end() {
    edit_refused("after ^Source0:\n\tSource9: x\n");
}

#[test]
fn spec_edit_refuses_a_block_without_text() {
    edit_refused("after ^Source0:\nend\n");
}

fn one_patch_line() -> Vec<u8> {
    spec_edit::patch_lines(&["0001-build.patch".to_owned()])
}

#[test]
fn patch_lines_go_after_the_last_patch_line() {
    let edited = apply(SPEC_EDIT, SPEC).expect("applies");
    let out = spec_edit::insert_patch_lines(&edited, &one_patch_line()).expect("inserted");
    let patch: Vec<String> = text::lines(&out)
        .into_iter()
        .filter(|l| l.starts_with(b"Patch"))
        .map(text::lossy)
        .collect();
    assert_eq!(
        patch,
        [
            "Patch:          fedora.patch",
            "Patch1001:      apex-0001-build.patch"
        ]
    );
}

#[test]
fn patch_lines_go_after_the_last_source_line_without_a_patch_line() {
    let out = spec_edit::insert_patch_lines(
        b"Name: y\nSource0: a\nSource1: b\nBuildRequires: c\n",
        &one_patch_line(),
    )
    .expect("inserted");
    assert_eq!(
        text::lines(&out)[2..4],
        [&b"Source1: b"[..], b"Patch1001:      apex-0001-build.patch"]
    );
}

#[test]
fn no_patch_or_source_line_holds_the_build() {
    assert_eq!(
        spec_edit::insert_patch_lines(b"Name: y\n", &one_patch_line()),
        Err(NoAnchor)
    );
}

struct Store(tempfile::TempDir);

impl Store {
    fn new() -> Self {
        Self(tempfile::tempdir().expect("tempdir"))
    }

    fn key(&self, key: &str, release: &str, stock: Option<&str>) {
        let d = self.0.path().join(key);
        std::fs::create_dir_all(&d).expect("key dir");
        std::fs::write(
            d.join("manifest.txt"),
            format!(
                "# apex-lane manifest 1\n# pkg=x key={key} release={release} n=3 stock={} pin=-\n",
                stock.unwrap_or("x-51.0-1.fc45")
            ),
        )
        .expect("manifest");
    }

    fn rel(&self, stock: &str, base: &str, key: &str) -> String {
        let stored: Vec<StoredBuild> = stored_builds(self.0.path()).expect("store");
        String::from_utf8(release_for(&stored, stock, base, key)).expect("utf-8")
    }
}

#[test]
fn release_rule() {
    let s = Store::new();
    assert_eq!(
        s.rel("x-51.0-1.fc45", "1.fc45.apex3", "k1"),
        "1.fc45.apex3",
        "the first key of .apexN"
    );
    s.key("k1", "1.fc45.apex3", None);
    assert_eq!(
        s.rel("x-51.0-1.fc45", "1.fc45.apex3", "k1"),
        "1.fc45.apex3",
        "a stored key keeps its release"
    );
    assert_eq!(
        s.rel("x-51.0-1.fc45", "1.fc45.apex3", "k2"),
        "1.fc45.apex3.1",
        "a second key of the same .apexN gets .1"
    );
    s.key("k3", "1.fc45.apex3.4", None);
    assert_eq!(
        s.rel("x-51.0-1.fc45", "1.fc45.apex3", "k4"),
        "1.fc45.apex3.5",
        ".M is one above the highest stored"
    );
    assert_eq!(
        s.rel("x-51.0-1.fc45", "1.fc45.apex4", "k5"),
        "1.fc45.apex4",
        "another N starts again"
    );
    assert_eq!(
        s.rel("x-51.0-1.fc45", "1.fc45.apex31", "k6"),
        "1.fc45.apex31",
        ".apex3 does not count for .apex31"
    );
    assert_eq!(
        s.rel("x-51.0-2.fc45", "2.fc45.apex3", "k7"),
        "2.fc45.apex3",
        "another stock release starts again"
    );
    assert_eq!(
        s.rel("x-51.1-1.fc45", "1.fc45.apex3", "k8"),
        "1.fc45.apex3",
        "Fedora's next version at the same release starts again"
    );
    s.key("k9", "1.fc45.apex3", Some("x-51.1-1.fc45"));
    assert_eq!(
        s.rel("x-51.1-1.fc45", "1.fc45.apex3", "k10"),
        "1.fc45.apex3.1",
        ".M counts only builds of the same stock NVR"
    );
}

const SIG6: &str = "x.src.rpm:
    Header OpenPGP V4 RSA/SHA256 signature, key fingerprint: 4f50a6114cd5c6976a7f1179655a4b02f577861e: OK
    Header SHA256 digest: OK
    Payload SHA256 digest: OK
";

#[test]
fn checksig_rpm6_the_fedora_key() {
    assert!(checksig_ok(SIG6.as_bytes(), "F577861E"));
}

#[test]
fn checksig_another_key() {
    assert!(!checksig_ok(SIG6.as_bytes(), "0123abcd"));
}

#[test]
fn checksig_a_bad_signature_line() {
    let bad = SIG6.replace("861e: OK", "861e: BAD");
    assert!(!checksig_ok(bad.as_bytes(), "f577861e"));
}

#[test]
fn checksig_rpm4() {
    assert!(checksig_ok(
        b"    Header V4 RSA/SHA256 Signature, key ID f577861e: OK\n",
        "f577861e"
    ));
}

#[test]
fn checksig_no_signature_at_all() {
    assert!(!checksig_ok(b"    Header SHA256 digest: OK\n", "f577861e"));
}

#[test]
fn source1_members() {
    let allowed = ["apex.gresource.xml", "js/ui/apex/", "data/theme/apex/"].map(String::from);
    for m in [
        "apex.gresource.xml",
        "js/",
        "js/ui/",
        "js/ui/apex/",
        "js/ui/apex/hooks.js",
        "data/theme/apex/_apex.scss",
    ] {
        assert!(member_ok(m, &allowed), "Source1 member {m} is allowed");
    }
    for m in [
        "meson.build",
        "README.md",
        "js/ui/main.js",
        "data/theme/gnome-shell-light.scss",
        "apex.gresource.xml.in",
    ] {
        assert!(!member_ok(m, &allowed), "Source1 member {m} is refused");
    }
}

fn gs_rpms() -> Vec<u8> {
    format!(
        "rpm gnome-shell built gnome-shell gnome-shell-0:51.0-1.fc45.apex1.x86_64 {} pkgs/gnome-shell/k1/gnome-shell-51.0-1.fc45.apex1.x86_64.rpm\n",
        "a".repeat(64)
    )
    .into_bytes()
}

fn locks() -> (Vec<u8>, Vec<u8>) {
    let first = lock::put(None, "gnome-shell", b"built k1", &gs_rpms());
    let second = lock::put(
        Some(&first),
        "libfprint",
        b"degraded - since=2026-10-12T04:10:00Z reason=0001 does not apply",
        b"",
    );
    let held = lock::put(
        Some(&second),
        "gnome-shell",
        b"held k1 since=2026-10-12T04:10:00Z limit=2026-10-26T04:10:00Z newer=gnome-shell-51.1-1.fc45,mutter-51.1-1.fc45 security=0 reason=0002-loader.patch does not apply",
        &gs_rpms(),
    );
    (second, held)
}

#[test]
fn lock_records() {
    let (built, held_lock) = locks();
    assert_eq!(
        lock::family_line(&built, "gnome-shell"),
        b"built k1",
        "a built family"
    );
    assert_eq!(
        text::lines(&lock::rpm_lines(&built, "gnome-shell")).len(),
        1,
        "its rpm lines"
    );
    assert_eq!(
        lock::attr(&lock::family_line(&built, "libfprint"), "reason"),
        b"0001 does not apply",
        "a degraded family's reason runs to the end of the line"
    );
    let held = lock::family_line(&held_lock, "gnome-shell");
    assert!(
        held.starts_with(b"held k1 "),
        "held keeps the last good key"
    );
    assert_eq!(lock::attr(&held, "since"), b"2026-10-12T04:10:00Z");
    assert_eq!(
        lock::attr(&held, "newer"),
        b"gnome-shell-51.1-1.fc45,mutter-51.1-1.fc45"
    );
    assert_eq!(lock::attr(&held, "nope"), b"", "no such attribute");
    assert_eq!(
        text::lines(&lock::rpm_lines(&held_lock, "gnome-shell")).len(),
        1,
        "held keeps the rpm lines"
    );
    assert!(
        lock::family_line(&held_lock, "libfprint").starts_with(b"degraded - "),
        "the other family is kept"
    );
    assert_eq!(
        text::lines(&held_lock)
            .iter()
            .filter(|l| l.starts_with(b"family "))
            .count(),
        2,
        "one family line each"
    );
    assert!(
        held_lock.starts_with(b"# apex rpms.lock 1"),
        "the header comes first"
    );
}

#[test]
fn manifest_to_lock_lines() {
    let sha = "b".repeat(64);
    let manifest = format!(
        "# apex-lane manifest 1: kind nevra sha256 file
# pkg=gnome-shell family=gnome-shell key=k1 release=1.fc45.apex1 n=1
fedora-srpm gnome-shell-0:51.0-1.fc45.src {sha} gnome-shell-51.0-1.fc45.src.rpm
built gnome-shell-0:51.0-1.fc45.apex1.x86_64 {sha} gnome-shell-51.0-1.fc45.apex1.x86_64.rpm
built gnome-shell-common-0:51.0-1.fc45.apex1.noarch {sha} gnome-shell-common-51.0-1.fc45.apex1.noarch.rpm
built gnome-shell-tests-0:51.0-1.fc45.apex1.x86_64 {sha} gnome-shell-tests-51.0-1.fc45.apex1.x86_64.rpm
mirror mutter-0:51.0-1.fc45.x86_64 {sha} mutter-51.0-1.fc45.x86_64.rpm
dev mutter-devkit-0:51.0-1.fc45.x86_64 {sha} mutter-devkit-51.0-1.fc45.x86_64.rpm
apex-srpm gnome-shell-0:51.0-1.fc45.apex1.src {sha} gnome-shell-51.0-1.fc45.apex1.src.rpm
"
    );
    let install = ["gnome-shell", "gnome-shell-common"].map(String::from);
    let rpms = lock::manifest_lock_rpms(
        "m",
        manifest.as_bytes(),
        "gnome-shell",
        "pkgs/gnome-shell/k1",
        &install,
    )
    .expect("valid NEVRAs");
    assert_eq!(
        String::from_utf8(rpms).expect("utf-8"),
        format!(
            "rpm gnome-shell built gnome-shell gnome-shell-0:51.0-1.fc45.apex1.x86_64 {sha} pkgs/gnome-shell/k1/gnome-shell-51.0-1.fc45.apex1.x86_64.rpm
rpm gnome-shell built gnome-shell-common gnome-shell-common-0:51.0-1.fc45.apex1.noarch {sha} pkgs/gnome-shell/k1/gnome-shell-common-51.0-1.fc45.apex1.noarch.rpm
rpm gnome-shell mirror mutter mutter-0:51.0-1.fc45.x86_64 {sha} pkgs/gnome-shell/k1/mutter-51.0-1.fc45.x86_64.rpm
"
        )
    );
}

#[test]
fn nevra_name_of_a_nevra() {
    assert_eq!(
        nevra_name(b"gnome-shell-common-0:51.0-1.fc45.apex1.noarch"),
        Some(&b"gnome-shell-common"[..])
    );
}

fn gnome_shell() -> pkg::Pkg {
    pkg::load(&recipes(), "gnome-shell", Parse::Full).expect("the gnome-shell fixture parses")
}

#[test]
fn gnome_shell_install() {
    assert_eq!(
        gnome_shell().env.install,
        ["gnome-shell", "gnome-shell-common"]
    );
}

#[test]
fn gnome_shell_series() {
    assert_eq!(
        gnome_shell().series,
        ["0001-build.patch", "0002-loader.patch"]
    );
}

/// Fedora's lines as of f45 gnome-shell.spec, 2026-09-28.
#[test]
fn gnome_shell_spec_edit_applies_to_fedoras_lines() {
    let fedora = "Release:        %autorelease
Source0:        https://download.gnome.org/sources/%{name}/%{gnome_major_version}/%{name}-%{gnome_tarball_version}.tar.xz
Patch: gnome-shell-favourite-apps-firefox.patch
BuildRequires:  meson
BuildRequires:  mutter-devel >= %{mutter_version}
Requires:       mutter%{?_isa} >= %{mutter_version}
%autosetup -S git -n %{name}-%{gnome_tarball_version}
";
    let pkg = gnome_shell();
    let values = Values {
        apex_release: ".apex1".into(),
        pin_evr: "51.0-1.fc45".into(),
        source1: "apex-shell-0.tar".into(),
    };
    let edit = pkg.spec_edit.as_ref().expect("parsed");
    let out = spec_edit::apply(edit, fedora.as_bytes(), &values, &mut |_| {}).expect("applies");
    assert!(
        text::lines(&out).contains(&&b"Requires:       mutter%{?_isa} = 51.0-1.fc45"[..]),
        "the pin in Requires"
    );
}

#[test]
fn gnome_shell_spec_edit_prep_handles_each_declared_change() {
    let pkg = gnome_shell();
    let edit = std::fs::read_to_string(pkg.dir.join("spec-edit")).expect("spec-edit");
    for from in pkg
        .env
        .prep_moved
        .iter()
        .map(|(from, _)| from)
        .chain(&pkg.env.prep_deleted)
    {
        assert!(
            edit.contains(from.as_str()),
            "spec-edit's %prep handles {from}"
        );
    }
}
