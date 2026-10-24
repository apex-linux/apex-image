#![allow(
    clippy::expect_used,
    clippy::unwrap_used,
    reason = "test helpers panic on broken fixtures"
)]
//! `apex-lane check-pins`, the contracts job's check of apex-kernel's pins, as a process.

use std::path::Path;
use std::process::Output;

const KERNEL_ENV: &str = concat!(
    "copr=bieszczaders/kernel-cachyos\n",
    "chroot=fedora-45-x86_64\n",
    "srpm=kernel-cachyos-0:7.3.0-4.cachyos1.fc45.src\n",
    "srpm_sha256=e6b57189499ce41b78255deadc86f38e318e24e895283b7e1f412a23de9cf49f\n",
    "copr_key=537DEED33436B0367F5B26D5B3E3132CF10859CF\n",
    "tag=cachyos-7.3.0-4\n",
    "tag_repo=https://github.com/CachyOS/linux.git\n",
    "tag_key=E8B9AA39F054E30E8290D492C3C4820857F654FE\n",
    "tag_key_url=https://keys.openpgp.org/vks/v1/by-fingerprint/E8B9AA39F054E30E8290D492C3C4820857F654FE\n",
);
const NVIDIA_ENV: &str = concat!(
    "kmod_srpm=nvidia-kmod-3:615.78.08-1.fc45.src\n",
    "kmod_srpm_sha256=2a16e83c24605b0f3c436caacb133c7b1b7724b105ed7c970ddf1a6809668532\n",
    "userspace=nvidia-driver-3:615.78.08-1.fc45.x86_64 2099da1e492b1abf2651c49b1a98f27ca215517bdddad06438769d0e25d2a6e4\n",
    "negativo17_key=0C5D0F470484AE2FC40A9B6597F3008993E8909B\n",
);

fn check_pins(kernel: &str) -> (Output, String) {
    check_pins_with(kernel, NVIDIA_ENV)
}

fn check_pins_with(kernel: &str, nvidia: &str) -> (Output, String) {
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join("kernel.env"), kernel).unwrap();
    std::fs::write(dir.path().join("nvidia.env"), nvidia).unwrap();
    let out = std::process::Command::new(env!("CARGO_BIN_EXE_apex-lane"))
        .arg("check-pins")
        .arg(dir.path())
        .current_dir(Path::new("/"))
        .env("GITHUB_ACTIONS", "")
        .output()
        .unwrap();
    let shown = format!(
        "{}{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    (out, shown)
}

#[test]
fn good_pins_pass_outside_any_checkout() {
    let (out, shown) = check_pins(KERNEL_ENV);
    assert_eq!(out.status.code(), Some(0), "{shown}");
    assert!(
        shown.contains("tag cachyos-7.3.0-4 from https://github.com/CachyOS/linux.git"),
        "{shown}"
    );
}

#[test]
fn a_missing_tag_repo_is_a_usage_error() {
    let (out, shown) =
        check_pins(&KERNEL_ENV.replace("tag_repo=https://github.com/CachyOS/linux.git\n", ""));
    assert_eq!(out.status.code(), Some(2), "{shown}");
    assert!(
        shown.contains("kernel.env: 'tag_repo' is required"),
        "{shown}"
    );
}

#[test]
fn a_url_that_is_not_https_is_a_usage_error() {
    let (out, shown) = check_pins(&KERNEL_ENV.replace("tag_repo=https://", "tag_repo=http://"));
    assert_eq!(out.status.code(), Some(2), "{shown}");
    assert!(
        shown.contains("tag_repo must be an https:// URL"),
        "{shown}"
    );
}

#[test]
fn without_soak_days_the_soak_is_bump_shs_seven_days() {
    let (out, shown) = check_pins(KERNEL_ENV);
    assert_eq!(out.status.code(), Some(0), "{shown}");
    assert!(shown.contains("NVIDIA soak 7 days"), "{shown}");
}

#[test]
fn soak_days_sets_the_soak() {
    let (out, shown) = check_pins_with(KERNEL_ENV, &format!("{NVIDIA_ENV}soak_days=10\n"));
    assert_eq!(out.status.code(), Some(0), "{shown}");
    assert!(shown.contains("NVIDIA soak 10 days"), "{shown}");
}

#[test]
fn a_soak_days_that_is_not_whole_days_is_a_usage_error() {
    let (out, shown) = check_pins_with(KERNEL_ENV, &format!("{NVIDIA_ENV}soak_days=0\n"));
    assert_eq!(out.status.code(), Some(2), "{shown}");
    assert!(
        shown.contains("nvidia.env: soak_days must be a whole number of days, 1 or more, not '0'"),
        "{shown}"
    );
}

/// The binary's own store rule: a 46 run reaches only <store>/next, never the 45 rpms.lock.
#[test]
fn a_46_run_cannot_reach_the_45_lock() {
    let store = tempfile::tempdir().unwrap();
    std::fs::write(store.path().join("rpms.lock"), "the 45 lock\n").unwrap();
    std::fs::write(store.path().join("rpms.lock.next"), "the 45 next lock\n").unwrap();
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let out = std::process::Command::new(env!("CARGO_BIN_EXE_apex-lane"))
        .arg("promote")
        .current_dir(&root)
        .env("APEX_FEDORA", "46")
        .env("APEX_STORE", store.path())
        .env("GITHUB_ACTIONS", "")
        .output()
        .unwrap();
    let shown = String::from_utf8_lossy(&out.stderr);
    assert_eq!(out.status.code(), Some(2), "{shown}");
    assert!(shown.contains("never promotes"), "{shown}");
    assert_eq!(
        std::fs::read_to_string(store.path().join("rpms.lock")).unwrap(),
        "the 45 lock\n"
    );
    assert_eq!(
        std::fs::read_to_string(store.path().join("rpms.lock.next")).unwrap(),
        "the 45 next lock\n"
    );
    assert!(!store.path().join("next/rpms.lock").exists());

    let bad = std::process::Command::new(env!("CARGO_BIN_EXE_apex-lane"))
        .arg("promote")
        .current_dir(&root)
        .env("APEX_FEDORA", "f46")
        .env("APEX_STORE", store.path())
        .env("GITHUB_ACTIONS", "")
        .output()
        .unwrap();
    assert_eq!(bad.status.code(), Some(2));
}
