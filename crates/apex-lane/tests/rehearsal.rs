#![allow(
    clippy::expect_used,
    clippy::unwrap_used,
    reason = "test helpers panic on broken fixtures"
)]
//! The rehearsal hooks reach no lane run outside a rehearsal on a scratch store.

use std::path::Path;

fn status(env: &[(&str, &str)]) -> (Option<i32>, String) {
    let home = tempfile::tempdir().unwrap();
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let mut cmd = std::process::Command::new(env!("CARGO_BIN_EXE_apex-lane"));
    cmd.arg("status")
        .current_dir(&root)
        .env_clear()
        .env("HOME", home.path())
        .env("PATH", "/usr/bin:/bin");
    for (k, v) in env {
        cmd.env(k, v);
    }
    let out = cmd.output().unwrap();
    (
        out.status.code(),
        format!(
            "{}{}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        ),
    )
}

#[test]
fn a_fault_without_a_rehearsal_is_a_usage_error() {
    let (code, shown) = status(&[("APEX_PAIR_FAULT", "kmod")]);
    assert_eq!(code, Some(2), "{shown}");
    assert!(shown.contains("are rehearsal hooks"), "{shown}");
}

#[test]
fn a_rehearsal_on_the_lanes_own_store_is_a_usage_error() {
    let (code, shown) = status(&[
        ("APEX_LANE_REHEARSAL", "1"),
        ("APEX_LANE_NOW", "2026-12-04T00:00:01Z"),
    ]);
    assert_eq!(code, Some(2), "{shown}");
    assert!(shown.contains("needs a scratch APEX_STORE"), "{shown}");
}
