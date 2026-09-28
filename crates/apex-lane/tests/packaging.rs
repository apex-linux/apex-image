//! apex-lane is a dev tool: the apex RPM, its License tag and the image never carry it.

#![allow(clippy::expect_used, reason = "test helpers panic on broken fixtures")]

use std::path::Path;

fn repo_file(path: &str) -> String {
    std::fs::read_to_string(
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../..")
            .join(path),
    )
    .expect("repository file")
}

#[test]
fn not_in_the_rpm() {
    let makefile = repo_file("Makefile");
    let bins = makefile
        .lines()
        .find_map(|l| l.strip_prefix("APEX_BINS :="))
        .expect("the Makefile names APEX_BINS");
    assert!(
        !bins.split_whitespace().any(|b| b == "apex-lane"),
        "Makefile APEX_BINS: {bins}"
    );
    let licenses = repo_file("packaging/licenses.py");
    let default_bins = licenses
        .lines()
        .find_map(|l| l.strip_prefix("DEFAULT_BINS = "))
        .expect("licenses.py names DEFAULT_BINS");
    assert!(
        !default_bins.contains("apex-lane"),
        "licenses.py DEFAULT_BINS: {default_bins}"
    );
    assert!(!repo_file("packaging/apex.spec").contains("apex-lane"));
}

#[test]
fn not_in_the_apex_rpm_key() {
    assert!(repo_file(".github/scripts/rpms.sh").contains(r"$2 !~ /^crates\/apex-lane\//"));
}
