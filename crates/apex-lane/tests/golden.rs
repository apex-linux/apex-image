//! Byte-exact expectations under tests/golden/; only the files apex-lane alone writes may
//! be rewritten.

#![allow(clippy::expect_used, reason = "test helpers panic on broken fixtures")]

use std::path::{Path, PathBuf};

use apex_lane::container::stored_builds;
use apex_lane::core::failed::{Failure, failed_txt};
use apex_lane::core::hold::bodhi_types;
use apex_lane::core::key::{KeyInputs, content_key, preimage};
use apex_lane::core::lock;
use apex_lane::core::manifest::{self, Header, header_field};
use apex_lane::core::pkg_env::OnFail;
use apex_lane::core::release::{StoredBuild, release_for};
use apex_lane::core::spec_edit::{self, ApplyError, Values};
use apex_lane::core::status;
use apex_lane::core::text;
use apex_lane::core::utc::UtcSecond;
use apex_lane::pkg::{self, Parse};
use apex_lane::shell::bodhi::Bodhi;
use apex_lane::shell::clock::FixedClock;
use apex_lane::shell::cmd::StdRunner;
use apex_lane::shell::report::Reporter;
use apex_lane::vm::{Settings, Vm};

fn golden(path: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/golden")
        .join(path)
}

fn read(path: &str) -> Vec<u8> {
    std::fs::read(golden(path)).unwrap_or_else(|e| panic!("{path}: {e}"))
}

fn read_str(path: &str) -> String {
    String::from_utf8(read(path)).expect("utf-8")
}

fn root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn recipes() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/recipes")
}

fn assert_same(path: &str, actual: &[u8]) {
    let expected = read(path);
    assert!(
        expected == actual,
        "{path} differs\n--- expected\n{}\n--- actual\n{}",
        text::lossy(&expected),
        text::lossy(actual)
    );
}

fn assert_blessed(path: &str, actual: &[u8]) {
    if std::env::var_os("APEX_LANE_BLESS").is_some() {
        std::fs::write(golden(path), actual).expect("bless");
    }
    assert_same(path, actual);
}

fn apply_case(name: &str, spec: &[u8], edit: &[u8], values: &Values, series: &[String]) {
    let parsed = spec_edit::parse(name, edit).expect("parses");
    let mut log = Vec::new();
    let (code, out, reason) = match spec_edit::apply(&parsed, spec, values, &mut |l| log.push(l)) {
        Ok(edited) if series.is_empty() => (0, edited, log.last().cloned().unwrap_or_default()),
        Ok(edited) => match spec_edit::insert_patch_lines(&edited, &spec_edit::patch_lines(series))
        {
            Ok(done) => (0, done, log.last().cloned().unwrap_or_default()),
            Err(_) => (
                3,
                edited,
                b"no Patch or Source line in the spec to add the series after".to_vec(),
            ),
        },
        Err(e @ ApplyError::Anchor { .. }) => (3, spec.to_vec(), e.reason()),
        Err(e) => (1, spec.to_vec(), e.reason()),
    };
    assert_eq!(
        read_str(&format!("spec-edit/{name}.exit")).trim(),
        code.to_string(),
        "{name}: exit"
    );
    assert_same(&format!("spec-edit/{name}.out"), &out);
    let mut reason = reason;
    reason.push(b'\n');
    assert_same(&format!("spec-edit/{name}.reason"), &reason);
}

#[test]
fn spec_edit_selftest() {
    apply_case(
        "selftest",
        &read("spec-edit/selftest.spec"),
        &read("spec-edit/selftest.spec-edit"),
        &Values {
            apex_release: ".apex3.1".into(),
            pin_evr: "51.0-1.fc45".into(),
            source1: "apex-shell-0123456789ab.tar".into(),
        },
        &[],
    );
}

/// CRLF lines, an ERE with a trailing space, two spaces after the directive, a tab-only
/// text line, Latin-1 bytes and no final newline.
#[test]
fn spec_edit_edge_cases() {
    apply_case(
        "edge",
        &read("spec-edit/edge.spec"),
        &read("spec-edit/edge.spec-edit"),
        &Values {
            apex_release: ".apex1".into(),
            pin_evr: String::new(),
            source1: "apex-x-0.tar".into(),
        },
        &[],
    );
}

/// gnome-shell.out is the spec inside the stored gnome-shell-51.0-1.fc45.apex2.src.rpm.
#[test]
fn spec_edit_gnome_shell_f45() {
    let gs = pkg::load(&recipes(), "gnome-shell", Parse::Full).expect("the fixture");
    apply_case(
        "gnome-shell",
        &read("spec-edit/gnome-shell-51.0-1.fc45.spec"),
        &std::fs::read(gs.dir.join("spec-edit")).expect("spec-edit"),
        &Values {
            apex_release: ".apex2".into(),
            pin_evr: "51.0-1.fc45".into(),
            source1: "apex-shell-9c3eeccdf015.tar".into(),
        },
        &gs.series,
    );
}

#[test]
fn patch_lines() {
    let line = spec_edit::patch_lines(&["0001-build.patch".to_owned()]);
    for (name, code) in [("source", 0), ("patch", 0), ("none", 3)] {
        let spec = read(&format!("spec-edit/patch-{name}.spec"));
        let out = spec_edit::insert_patch_lines(&spec, &line).unwrap_or_else(|_| spec.clone());
        assert_eq!(
            read_str(&format!("spec-edit/patch-{name}.exit")).trim(),
            code.to_string()
        );
        assert_same(&format!("spec-edit/patch-{name}.out"), &out);
    }
}

fn steps() -> Vec<(String, String, Vec<u8>)> {
    read_str("lock/steps.txt")
        .lines()
        .map(|l| {
            let mut f = l.splitn(3, '|');
            let (family, line, rpms) = (
                f.next().expect("family"),
                f.next().expect("line"),
                f.next().expect("rpms"),
            );
            let rpms = if rpms == "-" {
                Vec::new()
            } else {
                read(&format!("lock/{rpms}"))
            };
            (family.to_owned(), line.to_owned(), rpms)
        })
        .collect()
}

#[test]
fn lock_sequences() {
    for (seq, initial) in [("a", Some(read("lock/a-00.lock"))), ("b", None)] {
        let mut current = initial;
        for (i, (family, line, rpms)) in steps().into_iter().enumerate() {
            let next = lock::put(current.as_deref(), &family, line.as_bytes(), &rpms);
            assert_same(&format!("lock/{seq}-0{}.lock", i + 1), &next);
            current = Some(next);
        }
    }
}

const APEX2: &str = "gnome-shell-51.0-1.fc45-s22726911a8d4";
const APEX1: &str = "gnome-shell-51.0-1.fc45-sa221b6e4ead0";

fn test_vm<'a>(
    store: &Path,
    runner: &'a StdRunner,
    clock: &'a FixedClock,
    bodhi: &'a dyn Bodhi,
    report: &'a Reporter,
) -> Vm<'a> {
    Vm {
        root: root(),
        recipes: vec![recipes()],
        kernel_org: &NoKernelOrg,
        settings: Settings {
            store: store.to_path_buf(),
            ga_override: None,
            keep_work: false,
            signing_env: store.join("no-signing"),
            exe: store.join("no-exe"),
            uid: 0,
            gid: 0,
            is_root: false,
        },
        runner,
        clock,
        bodhi,
        report,
    }
}

struct NoKernelOrg;

impl apex_lane::shell::kernel_org::KernelOrg for NoKernelOrg {
    fn released(&self, _: &str) -> Option<UtcSecond> {
        None
    }
}

struct NoBodhi;

impl Bodhi for NoBodhi {
    fn types(&self, _: &str) -> String {
        String::new()
    }
}

#[test]
fn the_stores_manifests_parse() {
    let m = read(&format!("manifest/{APEX2}.txt"));
    assert_eq!(header_field(&m, "key"), APEX2.as_bytes());
    assert_eq!(header_field(&m, "release"), b"1.fc45.apex2");
    assert_eq!(header_field(&m, "pin"), b"mutter-51.0-1.fc45");
    let kinds: Vec<String> = manifest::entries(&m)
        .iter()
        .map(|e| text::lossy(e.kind))
        .collect();
    assert_eq!(
        kinds,
        [
            "fedora-srpm",
            "source1",
            "patch",
            "patch",
            "built",
            "built",
            "mirror",
            "mirror",
            "dev",
            "apex-srpm"
        ]
    );
    let stored: Vec<StoredBuild> = [APEX1, APEX2]
        .iter()
        .map(|k| StoredBuild::from_manifest(&read(&format!("manifest/{k}.txt"))))
        .collect();
    let stock = "gnome-shell-51.0-1.fc45";
    assert_eq!(
        release_for(&stored, stock, "1.fc45.apex2", APEX2),
        b"1.fc45.apex2"
    );
    assert_eq!(
        release_for(&stored, stock, "1.fc45.apex2", "other"),
        b"1.fc45.apex2.1"
    );
    assert_eq!(
        release_for(&stored, stock, "1.fc45.apex3", "other"),
        b"1.fc45.apex3"
    );
}

#[test]
fn manifest_header_renders_as_stored() {
    let m = read(&format!("manifest/{APEX2}.txt"));
    let header = manifest::render_header(&Header {
        pkg: "gnome-shell".into(),
        family: "gnome-shell".into(),
        key: APEX2.into(),
        release: "1.fc45.apex2".into(),
        n: 2,
        stock: "gnome-shell-51.0-1.fc45".into(),
        pin_nvr: Some("mutter-51.0-1.fc45".into()),
        fedora: "45".into(),
        ga_reached: 0,
        base: text::lossy(&header_field(&m, "base")),
    });
    assert_eq!(header.as_bytes(), &m[..header.len()]);
}

/// Only line 1, which names the writer, differs from the stored `rpms.lock.next`.
#[test]
fn record_built_writes_the_stores_lock() {
    let store = tempfile::tempdir().expect("tempdir");
    let set = store.path().join("pkgs/gnome-shell").join(APEX2);
    std::fs::create_dir_all(&set).expect("set");
    std::fs::write(
        set.join("manifest.txt"),
        read(&format!("manifest/{APEX2}.txt")),
    )
    .expect("manifest");
    assert_eq!(
        stored_builds(&store.path().join("pkgs/gnome-shell"))
            .expect("store")
            .len(),
        1
    );
    let (runner, clock, report) = (
        StdRunner::inherit(),
        FixedClock(UtcSecond(0)),
        Reporter::capturing(),
    );
    let vm = test_vm(store.path(), &runner, &clock, &NoBodhi, &report);
    let gs = vm.load("gnome-shell").expect("committed inputs");
    vm.record_built(&gs, APEX2).expect("recorded");
    let written = std::fs::read(store.path().join("rpms.lock.next")).expect("lock");
    let bash = read("lock/store-rpms.lock.next");
    let line1 = |b: &[u8]| b.iter().position(|&c| c == b'\n').map_or(0, |i| i + 1);
    assert_eq!(&written[line1(&written)..], &bash[line1(&bash)..]);
    assert_eq!(
        &written[..line1(&written)],
        format!("{}\n", lock::HEADER[0]).as_bytes()
    );
}

/// name, reason, stock, key, and whether the log's tail goes in.
type FailedCase<'a> = (&'a str, &'a [u8], Option<&'a str>, Option<&'a str>, bool);

#[test]
fn failed_txt_files() {
    let log = read("failed/build.log");
    let cases: [FailedCase<'_>; 3] = [
        (
            "with-log",
            b"gnome-shell-51.1-1.fc45 with the Apex inputs does not build",
            Some("gnome-shell-51.1-1.fc45"),
            Some("gnome-shell-51.1-1.fc45-s0123456789ab"),
            true,
        ),
        (
            "no-log",
            b"spec-edit: 'after ^Source0x:' matches 0 lines of the spec, not 1",
            Some("gnome-shell-51.1-1.fc45"),
            None,
            false,
        ),
        (
            "nothing-known",
            b"rpmbuild produced no binary RPM",
            None,
            None,
            false,
        ),
    ];
    for (name, reason, stock, key, with_log) in cases {
        let out = failed_txt(&Failure {
            reason,
            pkg: "gnome-shell",
            stock,
            key,
            log: with_log.then_some(("build.log", log.as_slice())),
        });
        assert_same(&format!("failed/{name}.txt"), &out);
    }
}

#[test]
fn status_files() {
    for name in ["before", "at-limit", "after", "no-family", "stock"] {
        let now = UtcSecond::parse(read_str(&format!("status/{name}.now")).trim().as_bytes())
            .expect("now");
        let files = read_str(&format!("status/{name}.files"));
        let mut lines = files.lines();
        let load = |f: Option<&str>| f.filter(|f| *f != "-").map(|f| read(&format!("lock/{f}")));
        let (next, locked) = (load(lines.next()), load(lines.next()));
        let mut out = status::render(
            "rpms.lock.next (the next image build takes it):",
            next.as_deref(),
            now,
        );
        out.extend(status::render(
            "rpms.lock (the last image that passed its gates):",
            locked.as_deref(),
            now,
        ));
        assert_same(&format!("status/{name}.txt"), &out);
    }
}

struct FixtureBodhi(PathBuf);

impl Bodhi for FixtureBodhi {
    fn types(&self, nvr: &str) -> String {
        std::fs::read(self.0.join(format!("{nvr}.json")))
            .map_or_else(|_| String::new(), |j| bodhi_types(&j))
    }
}

const GOOD: &str = "gnome-shell-51.0-1.fc45-s1111111111aa";

#[test]
fn hold_cases() {
    let dir = golden("hold");
    let mut cases: Vec<String> = std::fs::read_dir(&dir)
        .expect("hold/")
        .map(|e| e.expect("entry").file_name().to_string_lossy().into_owned())
        .collect();
    cases.sort();
    assert_eq!(cases.len(), 9);
    for case in cases {
        let input = |f: &str| std::fs::read(dir.join(&case).join("in").join(f)).ok();
        let expect = |f: &str| std::fs::read(dir.join(&case).join("expect").join(f)).ok();
        let store = tempfile::tempdir().expect("tempdir");
        let set = store.path().join("pkgs/gnome-shell").join(GOOD);
        std::fs::create_dir_all(&set).expect("set");
        let work = tempfile::tempdir().expect("tempdir");
        let copy = |from: &str, to: &Path| {
            if let Some(b) = input(from) {
                std::fs::write(to, b).expect("copy");
            }
        };
        copy("rpms.lock.next", &store.path().join("rpms.lock.next"));
        copy("rpms.lock", &store.path().join("rpms.lock"));
        copy("manifest.txt", &set.join("manifest.txt"));
        copy("attempt.txt", &work.path().join("attempt.txt"));
        copy("failed.txt", &work.path().join("failed.txt"));
        let now = UtcSecond::parse(text::chomp(&input("now").expect("now"))).expect("now");
        let on_fail = if input("on_fail").expect("on_fail").starts_with(b"hold") {
            OnFail::Hold
        } else {
            OnFail::Degrade
        };
        let (runner, clock, report) =
            (StdRunner::inherit(), FixedClock(now), Reporter::capturing());
        let bodhi = FixtureBodhi(dir.join(&case).join("in/bodhi"));
        let vm = test_vm(store.path(), &runner, &clock, &bodhi, &report);
        let mut gs = pkg::load(&recipes(), "gnome-shell", Parse::Full).expect("the fixture");
        gs.env.on_fail = on_fail;
        let result = vm.record_failure(&gs, work.path());
        let exit = u8::from(result.is_err());
        assert_eq!(
            text::chomp(&expect("exit").expect("exit")),
            exit.to_string().as_bytes(),
            "{case}: exit"
        );
        let written = std::fs::read(store.path().join("rpms.lock.next")).ok();
        match expect("rpms.lock.next") {
            Some(want) => assert_eq!(
                written.as_deref(),
                Some(want.as_slice()),
                "{case}: rpms.lock.next"
            ),
            None => assert_eq!(
                written,
                input("rpms.lock.next"),
                "{case}: rpms.lock.next unchanged"
            ),
        }
        assert_eq!(
            std::fs::read(store.path().join("pkgs/gnome-shell/last-failure.txt")).ok(),
            expect("last-failure.txt"),
            "{case}: last-failure.txt"
        );
        let mut stderr = report.captured();
        if let Err(e) = &result {
            stderr.extend_from_slice(format!("error: {e}\n").as_bytes());
        }
        let stderr = text::lossy(&stderr).replace(&store.path().display().to_string(), "STORE");
        assert_eq!(
            stderr,
            text::lossy(&expect("stderr").expect("stderr")),
            "{case}: summary"
        );
    }
}

#[test]
fn key_preimage() {
    let inputs = KeyInputs {
        pkg: "gnome-shell".into(),
        tool: "88838286103f4706f591bb9aded8a8dc9cab814326ecafcfbb2c07a1c64c4f68".into(),
        check_sh_sha256: Some("5b6f1c0cd6a4b4b0a3a4b49b64f2b91dd1bd41fcb42dbef4a9db18b7bf3fa0b1".into()),
        repos: "--repo=fedora --repo=updates --repo=updates-testing --setopt=updates-testing.includepkgs=gtk4-4.24.0-1.fc45,mutter-51.0-1.fc45 --setopt=install_weak_deps=False".into(),
        stock: "gnome-shell-51.0-1.fc45".into(),
        pin_evr: Some("51.0-1.fc45".into()),
        pkg_env_sha256: "0cc6d5e8a8a1fa0b19c6c10fe9e9f3a8f60e6fb0b5b6f0e2b0fce2e5d8e8a8c1".into(),
        spec_edit_sha256: "4d7a4dbd0c3ca3c5dc0ea3f6d1b6e0f5c1a9e7c3b2d4e6f8a0b2c4d6e8f0a2c4".into(),
        patches: vec![
            ("0001-build.patch".into(), "136976a28df383973c2658f2d31eb6f1415e851b9f1eb116fd63c4820bcdfbfd".into()),
            ("0002-loader.patch".into(), "9816c59b9eb897a4a5354650655850450932b5ac5039f0723bc1fd650bd643c9".into()),
        ],
        source1_tree: Some("9c3eeccdf015d3c9c3706aabec1c5bd7c5e26cdb".into()),
        n: 3,
    };
    let text = preimage(&inputs);
    assert_blessed("key/preimage.txt", text.as_bytes());
    assert_blessed(
        "key/key.txt",
        format!("{}\n", content_key(&inputs.stock, &text)).as_bytes(),
    );
}
