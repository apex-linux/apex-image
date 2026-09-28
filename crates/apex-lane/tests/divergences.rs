//! Where apex-lane deliberately differs from packaging/rebuild.sh, the Bash lane it
//! replaced; the differences in the VM and container flows are tested with them.

#![allow(clippy::expect_used, reason = "test helpers panic on broken fixtures")]

use std::path::Path;

use apex_lane::core::hold;
use apex_lane::core::key::{KeyInputs, preimage};
use apex_lane::core::lock;
use apex_lane::core::pkg_env;
use apex_lane::core::spec_edit;
use apex_lane::core::status;
use apex_lane::core::utc::UtcSecond;
use apex_lane::error::Exit;
use apex_lane::shell::bodhi::query_value;

fn refused_ere(ere: &str) -> String {
    let err = spec_edit::parse("spec-edit", format!("after {ere}\n\tx\nend\n").as_bytes())
        .expect_err("refused");
    assert_eq!(apex_lane::LaneError::from(err.clone()).exit(), Exit::Usage);
    err.0
}

/// grep -E cannot compile these: rebuild.sh held the family; the typo is configuration.
#[test]
fn an_ere_grep_cannot_compile_is_a_config_error() {
    assert!(refused_ere("a{2,1}").contains("counts down"));
    assert!(refused_ere("(a").contains("unmatched"));
    assert!(refused_ere("[z-a]").contains("backwards"));
}

#[test]
fn constructs_outside_the_ere_subset_are_refused() {
    assert!(refused_ere(r"\w+").contains("GNU escape"));
    assert!(refused_ere(r"(a)\1").contains("back-reference"));
    assert!(refused_ere("%{").contains("starts no interval"));
    assert!(refused_ere("[[=a=]]").contains("not in the ERE subset"));
}

#[test]
fn a_plus_in_an_nvr_reaches_bodhi_encoded() {
    assert_eq!(
        query_value("libsigc++30-3.6.0-1.fc45"),
        "libsigc%2B%2B30-3.6.0-1.fc45"
    );
}

#[test]
fn family_and_pin_are_names_the_image_accepts() {
    let base = "source=fedora-srpm\nsrpm=gnome-shell\non_fail=hold\ninstall=gnome-shell\n";
    for family in ["Gnome", ".gnome", "_x", "-x", "+x"] {
        let text = format!("{base}family={family}\n");
        assert!(
            pkg_env::parse("p", text.as_bytes()).is_err(),
            "family={family}"
        );
    }
    let text = format!("{base}family=gnome-shell\npin= mutter\n");
    assert!(
        pkg_env::parse("p", text.as_bytes()).is_err(),
        "a leading space in pin"
    );
}

#[test]
fn build_all_takes_the_packages_in_byte_order() {
    let root = tempfile::tempdir().expect("tempdir");
    for name in ["a.b", "a-b", "a+b", "ab"] {
        let dir = root.path().join("packaging/pkgs").join(name);
        std::fs::create_dir_all(&dir).expect("pkg dir");
        std::fs::write(dir.join("pkg.env"), b"").expect("pkg.env");
    }
    assert_eq!(
        apex_lane::pkg::all(root.path()).expect("list"),
        ["a+b", "a-b", "a.b", "ab"]
    );
}

#[test]
fn the_lock_names_its_writer() {
    let written = lock::put(None, "gnome-shell", b"built k", b"");
    assert!(written.starts_with(
        b"# apex rpms.lock 1: written by apex-lane (packaging/README.md, \"rpms.lock\")\n"
    ));
}

#[test]
fn the_key_names_the_lane_tool() {
    let text = preimage(&KeyInputs {
        pkg: "p".into(),
        tool: "0".repeat(64),
        check: None,
        repos: "r".into(),
        stock: "s".into(),
        pin_evr: None,
        pkg_env: "e".into(),
        spec_edit: "s".into(),
        patches: Vec::new(),
        source1_tree: None,
        n: 1,
    });
    let lines: Vec<&str> = text.lines().collect();
    assert_eq!(lines[0], "apex lane key 2");
    assert_eq!(lines[2], format!("lane {}", "0".repeat(64)));
    assert!(!text.contains("script "));
}

/// GNU `date -d` read almost anything (`limit=x` as the military time zone X); the lane
/// writes only `%Y-%m-%dT%H:%M:%SZ`, and reads only that.
#[test]
fn limit_and_since_are_read_strictly() {
    let lock_text = b"family gnome-shell held k since=2026-10-12T04:10:00Z limit=x reason=r\n";
    let out = status::render("t", Some(lock_text), UtcSecond(i64::MAX / 2));
    assert!(!String::from_utf8_lossy(&out).contains("LIMIT REACHED"));
    assert_eq!(UtcSecond::parse(b"2026-10-12 04:10:00"), None);
    assert_eq!(
        hold::since(
            b"held k since=yesterday newer=a reason=r",
            "a",
            UtcSecond(0)
        ),
        b"yesterday"
    );
}

#[test]
fn the_ere_subset_covers_the_committed_anchors() {
    let edit = std::fs::read(
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../packaging/pkgs/gnome-shell/spec-edit"),
    )
    .expect("spec-edit");
    assert_eq!(
        spec_edit::parse("spec-edit", &edit)
            .expect("parses")
            .blocks
            .len(),
        6
    );
}
