#![allow(
    clippy::expect_used,
    clippy::unwrap_used,
    reason = "test helpers panic on broken fixtures"
)]

use std::cell::RefCell;
use std::ffi::OsString;
use std::fmt::Write as _;
use std::path::{Path, PathBuf};
use std::time::Duration;

use apex_lane::container::{Args, Container, ModeKind, Paths};
use apex_lane::core::hash::sha256_hex;
use apex_lane::core::key::content_key;
use apex_lane::core::lock;
use apex_lane::core::utc::UtcSecond;
use apex_lane::error::{Exit, LaneError, Result};
use apex_lane::shell::bodhi::Bodhi;
use apex_lane::shell::clock::FixedClock;
use apex_lane::shell::cmd::{Cmd, Outcome, Program, Runner, StdRunner, Stderr, Stdout};
use apex_lane::shell::report::Reporter;
use apex_lane::vm::{Outcome as Built, Settings, Vm};

type Script = dyn Fn(&Cmd) -> Option<Outcome>;

struct Fake {
    log: RefCell<Vec<Cmd>>,
    script: Box<Script>,
    real: StdRunner,
}

impl Fake {
    fn new(script: impl Fn(&Cmd) -> Option<Outcome> + 'static) -> Self {
        Self {
            log: RefCell::default(),
            script: Box::new(script),
            real: StdRunner::inherit(),
        }
    }

    fn calls(&self, program: &str) -> Vec<Vec<String>> {
        self.log
            .borrow()
            .iter()
            .filter(|c| {
                c.program.name() == program
                    || argv(c)
                        .first()
                        .is_some_and(|a| a.ends_with(&format!("/{program}")))
            })
            .map(argv)
            .collect()
    }
}

fn argv(cmd: &Cmd) -> Vec<String> {
    cmd.args
        .iter()
        .map(|a| a.to_string_lossy().into_owned())
        .collect()
}

#[allow(
    clippy::unnecessary_wraps,
    reason = "the script answers with an Option"
)]
fn ok(stdout: &str) -> Option<Outcome> {
    Some(Outcome {
        code: 0,
        stdout: stdout.as_bytes().to_vec(),
        stderr: Vec::new(),
    })
}

#[allow(
    clippy::unnecessary_wraps,
    reason = "the script answers with an Option"
)]
fn exit(code: i32) -> Option<Outcome> {
    Some(Outcome {
        code,
        ..Outcome::default()
    })
}

impl Runner for Fake {
    fn run(&self, cmd: &Cmd) -> Result<Outcome> {
        self.log.borrow_mut().push(cmd.clone());
        if let Some(out) = (self.script)(cmd) {
            match &cmd.stdout {
                Stdout::File(p) => std::fs::write(p, &out.stdout).unwrap(),
                Stdout::Append(p) => {
                    let mut all = std::fs::read(p).unwrap_or_default();
                    all.extend_from_slice(&out.stdout);
                    std::fs::write(p, all).unwrap();
                }
                _ => {}
            }
            return Ok(out);
        }
        match cmd.program {
            Program::Git | Program::Cp | Program::Tar | Program::Diff | Program::Bash => {
                self.real.run(cmd)
            }
            _ => panic!("unexpected command: {cmd}"),
        }
    }

    fn pipe(&self, first: &Cmd, second: &Cmd) -> Result<(Outcome, Outcome)> {
        self.log.borrow_mut().push(first.clone());
        self.log.borrow_mut().push(second.clone());
        let out =
            (self.script)(first).unwrap_or_else(|| panic!("unexpected pipe: {first} | {second}"));
        Ok((out, Outcome::default()))
    }

    fn sleep(&self, _: Duration) {}
}

fn run_git(dir: &Path, args: &[&str]) -> String {
    let out = std::process::Command::new("git")
        .args([
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@x",
            "-c",
            "init.defaultBranch=main",
        ])
        .arg("-C")
        .arg(dir)
        .args(args)
        .output()
        .expect("git");
    assert!(
        out.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8(out.stdout).unwrap()
}

fn write(path: &Path, text: impl AsRef<[u8]>) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, text).unwrap();
}

const DIGEST: &str = "1e13e11f63e147a40a935c9046c79d53a30b861a3cf05ebb023bb53c562382cb";

fn base() -> String {
    format!("registry.fedoraproject.org/fedora@sha256:{DIGEST}")
}

const DEMO_ENV: &str = "source=fedora-srpm\nsrpm=demo\non_fail=hold\nfamily=demo\ninstall=demo\npin=mutter\nmirror=mutter\nsource1=desktop/demo\nsource1_paths=demo/\n";

const DEMO_EDIT: &str = concat!(
    "replace ^Release:[[:space:]]+%autorelease$\n\tRelease:        %{autorelease}@APEX_RELEASE@\nend\n",
    "after ^Source0:\n\tSource1:        @SOURCE1@\nend\n",
    "after ^BuildRequires:[[:space:]]+mutter-devel[[:space:]]\n\tBuildRequires:  mutter-devel = @PIN_EVR@\nend\n",
    "after ^Requires:[[:space:]]+mutter%\\{\\?_isa\\}[[:space:]]\n\tRequires:       mutter%{?_isa} = @PIN_EVR@\nend\n",
    "after ^%autosetup\n\ttar -xkf %{SOURCE1}\nend\n",
);

fn checkout(env: &str) -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    let r = dir.path();
    write(
        &r.join("image/Containerfile"),
        format!("FROM x\nARG REPOS_BASE={}\nARG GA_REACHED=0\n", base()),
    );
    write(&r.join("packaging/pkgs/demo/pkg.env"), env);
    write(&r.join("packaging/pkgs/demo/series"), "0001-a.patch\n");
    write(
        &r.join("packaging/pkgs/demo/patches/0001-a.patch"),
        demo_patch(),
    );
    write(&r.join("packaging/pkgs/demo/spec-edit"), DEMO_EDIT);
    write(&r.join("desktop/demo/demo/apex.js"), "// apex\n");
    write(
        &r.join("crates/apex-lane/Cargo.toml"),
        "[package]\nname = \"apex-lane\"\nversion = \"0.1.0\"\n",
    );
    write(&r.join("crates/apex-lane/src/lib.rs"), "\n");
    write(
        &r.join("Cargo.toml"),
        "[workspace]\nmembers = [\"crates/*\"]\n",
    );
    write(
        &r.join("Cargo.lock"),
        "version = 4\n\n[[package]]\nname = \"apex-lane\"\nversion = \"0.1.0\"\n",
    );
    run_git(r, &["init", "-q"]);
    run_git(r, &["add", "-A"]);
    run_git(r, &["commit", "-q", "-m", "init"]);
    dir
}

fn demo_patch() -> String {
    let dir = tempfile::tempdir().unwrap();
    write(&dir.path().join("hello.txt"), "hello\n");
    run_git(dir.path(), &["init", "-q"]);
    run_git(dir.path(), &["add", "-A"]);
    run_git(dir.path(), &["commit", "-q", "-m", "base"]);
    write(&dir.path().join("hello.txt"), "hello\napex\n");
    run_git(dir.path(), &["commit", "-q", "-a", "-m", "a"]);
    run_git(
        dir.path(),
        &["format-patch", "-1", "--stdout", "--zero-commit"],
    )
}

struct NoBodhi;

impl Bodhi for NoBodhi {
    fn types(&self, _: &str) -> String {
        String::new()
    }
}

fn settings(store: &Path, signing: &Path) -> Settings {
    Settings {
        store: store.to_path_buf(),
        ga_override: None,
        keep_work: false,
        signing_env: signing.to_path_buf(),
        exe: PathBuf::from("/opt/apex-lane"),
        uid: 1000,
        gid: 1000,
        is_root: false,
    }
}

fn mount(args: &[String], to: &str) -> PathBuf {
    let spec = args
        .iter()
        .find(|a| a.contains(&format!(":{to}:")))
        .expect("mount");
    PathBuf::from(spec.split(':').next().unwrap())
}

/// `scenario(out, store)` plays the container and returns its exit status.
fn vm_fake(scenario: impl Fn(&Path, &Path) -> i32 + 'static) -> Fake {
    Fake::new(move |cmd| {
        if cmd.program != Program::Sudo {
            return None;
        }
        let args = argv(cmd);
        match args[0].as_str() {
            "/usr/bin/podman" => {
                let work = mount(&args, "/work");
                let store = mount(&args, "/store");
                exit(scenario(&work.join("out"), &store))
            }
            "/usr/bin/chown" => ok(""),
            "/usr/bin/rm" => {
                let _ = std::fs::remove_dir_all(args.last().unwrap());
                ok("")
            }
            other => panic!("sudo {other}"),
        }
    })
}

const KEY: &str = "demo-1.0-1.fc45-s0123456789ab";

fn built_set(out: &Path, key: &str) {
    let files = [
        (
            "built",
            "demo-0:1.0-1.fc45.apex3.x86_64",
            "demo-1.0-1.fc45.apex3.x86_64.rpm",
        ),
        (
            "mirror",
            "mutter-0:51.0-1.fc45.x86_64",
            "mutter-51.0-1.fc45.x86_64.rpm",
        ),
        (
            "apex-srpm",
            "demo-0:1.0-1.fc45.apex3.src",
            "demo-1.0-1.fc45.apex3.src.rpm",
        ),
    ];
    let mut manifest = format!(
        "# apex-lane manifest 1: kind nevra sha256 file\n# pkg=demo family=demo key={key} release=1.fc45.apex3 n=3 stock=demo-1.0-1.fc45 pin=mutter-51.0-1.fc45 fedora=45 ga_reached=0 base={}\n",
        base()
    );
    for (kind, nevra, file) in files {
        write(&out.join(file), file);
        let _ = writeln!(
            manifest,
            "{kind} {nevra} {} {file}",
            sha256_hex(file.as_bytes())
        );
    }
    write(&out.join("manifest.txt"), manifest);
    write(&out.join("key.txt"), format!("{key}\n"));
    write(
        &out.join("attempt.txt"),
        "stock demo-1.0-1.fc45\npin mutter-51.0-1.fc45\n",
    );
}

struct VmTest {
    root: tempfile::TempDir,
    store: tempfile::TempDir,
    report: Reporter,
}

impl VmTest {
    fn new(env: &str) -> Self {
        Self {
            root: checkout(env),
            store: tempfile::tempdir().unwrap(),
            report: Reporter::capturing(),
        }
    }

    fn vm<'a>(&'a self, fake: &'a Fake, clock: &'a FixedClock) -> Vm<'a> {
        Vm {
            root: self.root.path().to_path_buf(),
            settings: settings(
                self.store.path(),
                &self.store.path().join("rpm-signing.env"),
            ),
            runner: fake,
            clock,
            bodhi: &NoBodhi,
            report: &self.report,
        }
    }

    fn next_lock(&self) -> String {
        std::fs::read_to_string(self.store.path().join("rpms.lock.next")).unwrap_or_default()
    }
}

fn clock() -> FixedClock {
    FixedClock(UtcSecond::parse(b"2026-10-12T04:10:00Z").unwrap())
}

#[test]
fn vm_build_stores_and_records_the_set() {
    let t = VmTest::new(DEMO_ENV);
    let fake = vm_fake(|out, _| {
        built_set(out, KEY);
        0
    });
    let c = clock();
    let outcomes = t.vm(&fake, &c).build("demo").expect("built");
    assert_eq!(outcomes, [Built::Built(KEY.into())]);
    let set = t.store.path().join("pkgs/demo").join(KEY);
    assert!(
        std::fs::read_to_string(set.join("manifest.txt"))
            .unwrap()
            .ends_with("\n# sig=none\n")
    );
    let lock_text = t.next_lock();
    assert!(lock_text.starts_with(lock::HEADER[0]));
    assert!(lock_text.contains(&format!(
        "family demo built {KEY}\nrpm demo built demo demo-0:1.0-1.fc45.apex3.x86_64 "
    )));
    assert!(lock_text.contains(&format!("pkgs/demo/{KEY}/mutter-51.0-1.fc45.x86_64.rpm\n")));
    let podman = fake.calls("podman");
    assert_eq!(podman.len(), 1);
    let p = &podman[0];
    let root = t.root.path().display();
    let (tree, archive) = {
        let tree = run_git(t.root.path(), &["rev-parse", "HEAD:desktop/demo"])
            .trim()
            .to_owned();
        let archive = format!("apex-demo-{}.tar", &tree[..12]);
        (tree, archive)
    };
    let expected: Vec<String> = [
        "/usr/bin/podman",
        "run",
        "--rm",
        "--pull=missing",
        "-v",
        &format!("{root}:/src:ro,z"),
        "-v",
        &format!("{root}/_build/lane/demo:/work:z"),
        "-v",
        &format!("{}/pkgs/demo:/store:ro,z", t.store.path().display()),
        "-v",
        "apex-lane-dnf-cache:/var/cache/libdnf5",
        "-v",
        "/opt/apex-lane:/usr/local/libexec/apex-lane:ro,z",
        &base(),
        "/usr/local/libexec/apex-lane",
        "in-container",
        "build",
        "demo",
        "--repos-base",
        &base(),
        "--ga-reached",
        "0",
        "--n",
        "1",
        "--tool",
        &p[p.iter().position(|a| a == "--tool").unwrap() + 1],
        "--source1",
        &archive,
        "--source1-tree",
        &tree,
    ]
    .iter()
    .map(|s| (*s).to_owned())
    .collect();
    assert_eq!(p, &expected);
    assert!(
        t.root
            .path()
            .join("_build/lane/demo/in")
            .join(&archive)
            .is_file()
    );
}

#[test]
fn vm_build_unchanged_takes_the_stored_key() {
    let t = VmTest::new(DEMO_ENV);
    built_set(&t.store.path().join("pkgs/demo").join(KEY), KEY);
    let fake = vm_fake(|out, _| {
        write(&out.join("unchanged"), format!("{KEY}\n"));
        0
    });
    let c = clock();
    assert_eq!(
        t.vm(&fake, &c).build("demo").unwrap(),
        [Built::Unchanged(KEY.into())]
    );
    assert!(
        t.next_lock()
            .contains(&format!("family demo built {KEY}\n"))
    );
}

fn failed(out: &Path) -> i32 {
    write(
        &out.join("failed.txt"),
        "0001-a.patch does not apply to demo-1.1-1.fc45\npkg=demo stock=demo-1.1-1.fc45 key=?\n",
    );
    write(
        &out.join("attempt.txt"),
        "stock demo-1.1-1.fc45\npin mutter-51.0-1.fc45\n",
    );
    3
}

#[test]
fn vm_build_holds_the_last_good_build() {
    let t = VmTest::new(DEMO_ENV);
    let good = t.store.path().join("pkgs/demo").join(KEY);
    built_set(&good, KEY);
    let rpms = lock::manifest_lock_rpms(
        "m",
        &std::fs::read(good.join("manifest.txt")).unwrap(),
        "demo",
        &format!("pkgs/demo/{KEY}"),
        &["demo".into()],
    )
    .unwrap();
    std::fs::write(
        t.store.path().join("rpms.lock"),
        lock::put(None, "demo", format!("built {KEY}").as_bytes(), &rpms),
    )
    .unwrap();
    let fake = vm_fake(|out, _| failed(out));
    let c = clock();
    assert_eq!(t.vm(&fake, &c).build("demo").unwrap(), [Built::Held]);
    let next = t.next_lock();
    assert!(next.contains(&format!("family demo held {KEY} since=2026-10-12T04:10:00Z limit=2026-10-15T04:10:00Z newer=demo-1.1-1.fc45 security=? reason=0001-a.patch does not apply to demo-1.1-1.fc45\n")), "{next}");
    assert!(next.ends_with(&String::from_utf8(rpms).unwrap()));
    assert!(t.store.path().join("pkgs/demo/last-failure.txt").is_file());
    assert_eq!(
        apex_lane::vm::build::exit_of(&[Built::Held]),
        Exit::NoShippableBuild
    );
}

#[test]
fn vm_build_without_a_last_good_build_stops() {
    let t = VmTest::new(DEMO_ENV);
    let fake = vm_fake(|out, _| failed(out));
    let c = clock();
    let err = t.vm(&fake, &c).build("demo").unwrap_err();
    assert_eq!(err.exit(), Exit::Error);
    assert!(err.to_string().contains("just pkg-stock demo"), "{err}");
}

#[test]
fn vm_build_degrades() {
    let t = VmTest::new(&DEMO_ENV.replace("on_fail=hold", "on_fail=degrade"));
    let fake = vm_fake(|out, _| failed(out));
    let c = clock();
    assert_eq!(t.vm(&fake, &c).build("demo").unwrap(), [Built::Degraded]);
    assert!(t.next_lock().ends_with("family demo degraded - since=2026-10-12T04:10:00Z reason=0001-a.patch does not apply to demo-1.1-1.fc45\n"));
}

#[test]
fn vm_build_keeps_a_stock_family_stock() {
    let t = VmTest::new(DEMO_ENV);
    let stock = lock::put(
        None,
        "demo",
        b"stock - since=2026-10-12T04:10:00Z reason=the owner chose Fedora's build",
        b"",
    );
    std::fs::write(t.store.path().join("rpms.lock.next"), &stock).unwrap();
    let fake = vm_fake(|out, _| failed(out));
    let c = clock();
    assert_eq!(t.vm(&fake, &c).build("demo").unwrap(), [Built::KeptStock]);
    assert_eq!(t.next_lock().into_bytes(), stock);
}

#[test]
fn stock_records_the_owners_choice() {
    let t = VmTest::new(DEMO_ENV);
    let fake = vm_fake(|_, _| 0);
    let c = clock();
    t.vm(&fake, &c).stock("demo").unwrap();
    assert!(t.next_lock().ends_with(
        "family demo stock - since=2026-10-12T04:10:00Z reason=the owner chose Fedora's build\n"
    ));
}

#[test]
fn the_signing_check_runs_before_the_container() {
    let t = VmTest::new(DEMO_ENV);
    write(
        &t.store.path().join("rpm-signing.env"),
        "APEX_RPM_KEY_FPR=x\n",
    );
    let fake = vm_fake(|_, _| panic!("the container must not start"));
    let c = clock();
    let err = t.vm(&fake, &c).build("demo").unwrap_err();
    assert!(matches!(err, LaneError::Infra(ref m) if m.contains("does not sign yet")));
    assert!(fake.calls("podman").is_empty());
}

#[test]
fn key_works_in_its_own_directory() {
    let t = VmTest::new(DEMO_ENV);
    let fake = vm_fake(|_, _| 0);
    let c = clock();
    assert_eq!(t.vm(&fake, &c).key("demo").unwrap(), Exit::Ok);
    let p = &fake.calls("podman")[0];
    assert!(p.contains(&format!(
        "{}/_build/lane/demo.key:/work:z",
        t.root.path().display()
    )));
    assert!(p.windows(2).any(|w| w == ["in-container", "key"]));
}

#[test]
fn two_packages_in_one_family_are_refused() {
    let t = VmTest::new(DEMO_ENV);
    write(
        &t.root.path().join("packaging/pkgs/demo2/pkg.env"),
        DEMO_ENV.replace("srpm=demo", "srpm=demo2"),
    );
    let fake = vm_fake(|_, _| 0);
    let c = clock();
    let err = t.vm(&fake, &c).load("demo").unwrap_err();
    assert_eq!(err.exit(), Exit::Usage);
    assert!(err.to_string().contains("share the family demo"), "{err}");
}

#[test]
fn a_dirty_lane_input_is_refused() {
    let t = VmTest::new(DEMO_ENV);
    write(
        &t.root.path().join("packaging/pkgs/demo/series"),
        "0001-a.patch\n# changed\n",
    );
    let fake = vm_fake(|_, _| 0);
    let c = clock();
    let err = t.vm(&fake, &c).build("demo").unwrap_err();
    assert_eq!(err.exit(), Exit::Usage);
    assert!(err.to_string().contains("uncommitted lane inputs"), "{err}");
}

#[test]
fn a_source1_member_outside_source1_paths_is_refused() {
    let t = VmTest::new(DEMO_ENV);
    write(&t.root.path().join("desktop/demo/README"), "x\n");
    run_git(t.root.path(), &["add", "-A"]);
    run_git(t.root.path(), &["commit", "-q", "-m", "x"]);
    let fake = vm_fake(|_, _| 0);
    let c = clock();
    let err = t.vm(&fake, &c).build("demo").unwrap_err();
    assert!(
        err.to_string()
            .contains("Source1 member 'README' is outside source1_paths (demo/)"),
        "{err}"
    );
}

fn promotable(t: &VmTest) -> (PathBuf, Vec<u8>) {
    let set = t.store.path().join("pkgs/demo").join(KEY);
    built_set(&set, KEY);
    let manifest = std::fs::read(set.join("manifest.txt")).unwrap();
    let rpms = lock::manifest_lock_rpms(
        "m",
        &manifest,
        "demo",
        &format!("pkgs/demo/{KEY}"),
        &["demo".into()],
    )
    .unwrap();
    let next = lock::put(None, "demo", format!("built {KEY}").as_bytes(), &rpms);
    std::fs::write(t.store.path().join("rpms.lock.next"), &next).unwrap();
    (set, next)
}

#[test]
fn promote_makes_the_next_lock_the_lock() {
    let t = VmTest::new(DEMO_ENV);
    let (_, next) = promotable(&t);
    let fake = vm_fake(|_, _| 0);
    let c = clock();
    t.vm(&fake, &c).promote().unwrap();
    assert_eq!(
        std::fs::read(t.store.path().join("rpms.lock")).unwrap(),
        next
    );
}

#[test]
fn promote_refuses_a_changed_file() {
    let t = VmTest::new(DEMO_ENV);
    let (set, _) = promotable(&t);
    std::fs::write(set.join("demo-1.0-1.fc45.apex3.x86_64.rpm"), "changed").unwrap();
    std::fs::write(t.store.path().join("rpms.lock"), "old").unwrap();
    let fake = vm_fake(|_, _| 0);
    let c = clock();
    let err = t.vm(&fake, &c).promote().unwrap_err();
    assert!(
        err.to_string().contains("does not match rpms.lock.next"),
        "{err}"
    );
    assert_eq!(
        std::fs::read(t.store.path().join("rpms.lock")).unwrap(),
        b"old"
    );
}

#[test]
fn promote_refuses_a_path_outside_the_store() {
    let t = VmTest::new(DEMO_ENV);
    let line = format!(
        "rpm demo built demo demo-0:1-1.x86_64 {} ../outside.rpm\n",
        "a".repeat(64)
    );
    std::fs::write(
        t.store.path().join("rpms.lock.next"),
        lock::put(None, "demo", b"built k", line.as_bytes()),
    )
    .unwrap();
    let fake = vm_fake(|_, _| 0);
    let c = clock();
    let err = t.vm(&fake, &c).promote().unwrap_err();
    assert!(
        err.to_string()
            .contains("not a relative path inside the store"),
        "{err}"
    );
}

#[test]
fn status_prints_both_locks() {
    let t = VmTest::new(DEMO_ENV);
    let fake = vm_fake(|_, _| 0);
    let c = clock();
    t.vm(&fake, &c).stock("demo").unwrap();
    let text = String::from_utf8(t.vm(&fake, &c).status().unwrap()).unwrap();
    assert_eq!(
        text,
        "rpms.lock.next (the next image build takes it):\n  demo                   stock     -\n      since=2026-10-12T04:10:00Z reason=the owner chose Fedora's build\nrpms.lock (the last image that passed its gates):\n  (no family)\n"
    );
}

const FEDORA_SPEC: &str = "Name:           demo\nVersion:        1.0\nRelease:        %autorelease\nSource0:        demo-1.0.tar.xz\nBuildRequires:  mutter-devel >= 50\nRequires:       mutter%{?_isa} >= 50\n%prep\n%autosetup -S git\n";

#[derive(Clone, Default)]
struct Tools {
    spec: Option<String>,
    patched_prep_fails: bool,
    patched_prep_extra_file: bool,
    rpmbuild_fails: bool,
    built_release: Option<String>,
    check_sh: Option<String>,
}

struct ContainerTest {
    src: tempfile::TempDir,
    work: tempfile::TempDir,
    store: tempfile::TempDir,
    keys: tempfile::TempDir,
    report: Reporter,
    archive: String,
    tree: String,
}

impl ContainerTest {
    fn new(env: &str, edit: &str) -> Self {
        let src = checkout(env);
        write(&src.path().join("packaging/pkgs/demo/spec-edit"), edit);
        let tree = run_git(src.path(), &["rev-parse", "HEAD:desktop/demo"])
            .trim()
            .to_owned();
        let archive = format!("apex-demo-{}.tar", &tree[..12]);
        let work = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(work.path().join("in")).unwrap();
        std::fs::create_dir_all(work.path().join("out")).unwrap();
        let tar = std::process::Command::new("git")
            .arg("-C")
            .arg(src.path())
            .args(["archive", "--format=tar", "-o"])
            .arg(work.path().join("in").join(&archive))
            .arg(&tree)
            .status()
            .unwrap();
        assert!(tar.success());
        let keys = tempfile::tempdir().unwrap();
        write(&keys.path().join("RPM-GPG-KEY-fedora-45-primary"), "key");
        Self {
            src,
            work,
            store: tempfile::tempdir().unwrap(),
            keys,
            report: Reporter::capturing(),
            archive,
            tree,
        }
    }

    fn run(&self, tools: &Tools, fake: &Fake) -> Result<()> {
        if let Some(check) = &tools.check_sh {
            write(&self.src.path().join("packaging/pkgs/demo/check.sh"), check);
        }
        Container {
            paths: Paths {
                src: self.src.path().to_path_buf(),
                work: self.work.path().to_path_buf(),
                store: self.store.path().to_path_buf(),
                fedora_keys: self.keys.path().to_path_buf(),
            },
            args: Args {
                mode: ModeKind::Build,
                pkg: "demo".into(),
                nvr: None,
                n: 3,
                tool: "t".repeat(64),
                repos_base: base(),
                ga_reached: 0,
                source1: Some(self.archive.clone()),
                source1_tree: Some(self.tree.clone()),
                locked_evr: None,
                keep_work: false,
            },
            runner: fake,
            report: &self.report,
            is_root: true,
        }
        .run()
    }

    fn out(&self, file: &str) -> String {
        std::fs::read_to_string(self.work.path().join("out").join(file)).unwrap_or_default()
    }
}

fn arg_after<'a>(args: &'a [String], flag: &str) -> Option<&'a str> {
    args.iter()
        .position(|a| a == flag)
        .map(|i| args[i + 1].as_str())
}

fn define_top(args: &[String]) -> PathBuf {
    let d = arg_after(args, "--define").unwrap();
    PathBuf::from(d.strip_prefix("_topdir ").unwrap())
}

fn nvra_of_file_name(file: &str) -> (String, String, String, String) {
    let stem = file.strip_suffix(".rpm").unwrap();
    let (rest, arch) = stem.rsplit_once('.').unwrap();
    let (rest, release) = rest.rsplit_once('-').unwrap();
    let (name, version) = rest.rsplit_once('-').unwrap();
    (name.into(), version.into(), release.into(), arch.into())
}

fn spec_release(spec: &Path) -> String {
    let text = std::fs::read_to_string(spec).unwrap();
    let line = text.lines().find(|l| l.starts_with("Release:")).unwrap();
    line.split("%{autorelease}")
        .nth(1)
        .map_or_else(|| "1.fc45".into(), |s| format!("1.fc45{s}"))
}

fn container_fake(tools: Tools) -> Fake {
    Fake::new(move |cmd| {
        let args = argv(cmd);
        let has = |a: &str| args.iter().any(|x| x == a);
        match cmd.program {
            Program::Dnf5 if has("makecache") || has("install") || has("builddep") => ok(""),
            Program::Dnf5 if has("repoquery") => match args.last().unwrap().as_str() {
                "demo" => ok("demo 0 1.0 1.fc45 demo-1.0-1.fc45.src.rpm\n"),
                "mutter-devel" => ok("0 51.0 1.fc45 mutter-51.0-1.fc45.src.rpm\n"),
                "mutter" => ok(
                    "mutter-0:51.0-1.fc45.x86_64 51.0-1.fc45 mutter-51.0-1.fc45.src.rpm\nmutter-0:50.0-1.fc45.x86_64 50.0-1.fc45 mutter-50.0-1.fc45.src.rpm\n",
                ),
                other => panic!("repoquery {other}"),
            },
            Program::Dnf5 if has("download") => {
                let dest = args
                    .iter()
                    .find_map(|a| a.strip_prefix("--destdir="))
                    .unwrap();
                let file = if has("--srpm") {
                    "demo-1.0-1.fc45.src.rpm".to_owned()
                } else {
                    format!("{}.rpm", args.last().unwrap())
                };
                write(&Path::new(dest).join(file), "downloaded");
                ok("")
            }
            Program::Rpm if has("-E") => ok(match args[1].as_str() {
                "%fedora" => "45\n",
                "%_arch" => "x86_64\n",
                "%{?dist}" => ".fc45\n",
                "%{_isa}" => "(x86-64)\n",
                lua if lua.starts_with("%{lua:") => "1\n",
                other => panic!("rpm -E {other}"),
            }),
            Program::Rpm if has("-q") && has("mutter-devel") => ok("51.0-1.fc45\n"),
            Program::Rpm if has("-qp") => rpm_query(&tools, &args),
            Program::Gpg => ok("fpr:::::::::4F50A6114CD5C6976A7F1179655A4B02F577861E:\n"),
            Program::Rpmkeys if has("--import") => ok(""),
            Program::Rpmkeys if has("-v") => ok(
                "x:\n    Header OpenPGP V4 RSA/SHA256 signature, key fingerprint: 4f50a6114cd5c6976a7f1179655a4b02f577861e: OK\n",
            ),
            Program::Rpmkeys => ok("x: digests signatures OK\n"),
            Program::Rpm2cpio => {
                let top = PathBuf::from(
                    args[0]
                        .rsplit_once("/dl/")
                        .map(|(w, _)| format!("{w}/rpmbuild"))
                        .unwrap(),
                );
                write(
                    &top.join("SOURCES/demo.spec"),
                    tools.spec.clone().unwrap_or_else(|| FEDORA_SPEC.into()),
                );
                write(&top.join("SOURCES/demo-1.0.tar.xz"), "tarball");
                ok("")
            }
            Program::Rpmspec => {
                let spec = PathBuf::from(args.last().unwrap());
                let text = std::fs::read_to_string(&spec).unwrap();
                if has("--srpm") {
                    ok(&format!("1.0-{}\n", spec_release(&spec)))
                } else if has("--buildrequires") {
                    ok(if text.contains("mutter-devel = 51.0-1.fc45") {
                        "mutter-devel >= 50\nmutter-devel = 51.0-1.fc45\n"
                    } else {
                        "mutter-devel >= 50\n"
                    })
                } else {
                    ok(if text.contains("mutter%{?_isa} = 51.0-1.fc45") {
                        "mutter(x86-64) >= 50\nmutter(x86-64) = 51.0-1.fc45\n"
                    } else {
                        "mutter(x86-64) >= 50\n"
                    })
                }
            }
            Program::Rpmbuild => rpmbuild(&tools, &args),
            _ => None,
        }
    })
}

fn rpmbuild(tools: &Tools, args: &[String]) -> Option<Outcome> {
    let has = |a: &str| args.iter().any(|x| x == a);
    let top = define_top(args);
    let tree = top.join("BUILD/demo-1.0-build/demo-1.0");
    if has("-bp") && has("--nodeps") {
        write(&tree.join("hello.txt"), "hello\n");
        return ok("stock prep\n");
    }
    if has("-bp") {
        if tools.patched_prep_fails {
            return exit(1);
        }
        write(&tree.join("hello.txt"), "hello\napex\n");
        write(&tree.join("demo/apex.js"), "// apex\n");
        if tools.patched_prep_extra_file {
            write(&tree.join("extra.txt"), "x\n");
        }
        return ok("patched prep\n");
    }
    if tools.rpmbuild_fails {
        return Some(Outcome {
            code: 1,
            stdout: b"error: Bad exit status\n".to_vec(),
            stderr: Vec::new(),
        });
    }
    let release = spec_release(&PathBuf::from(args.last().unwrap()));
    write(
        &top.join(format!("RPMS/x86_64/demo-1.0-{release}.x86_64.rpm")),
        "rpm",
    );
    write(
        &top.join(format!(
            "RPMS/x86_64/demo-debuginfo-1.0-{release}.x86_64.rpm"
        )),
        "debuginfo",
    );
    write(
        &top.join(format!("SRPMS/demo-1.0-{release}.src.rpm")),
        "srpm",
    );
    ok("built\n")
}

fn rpm_query(tools: &Tools, args: &[String]) -> Option<Outcome> {
    let has = |a: &str| args.iter().any(|x| x == a);
    let file = args.last().unwrap();
    let (name, version, release, arch) =
        nvra_of_file_name(Path::new(file).file_name().unwrap().to_str().unwrap());
    let release = tools
        .built_release
        .clone()
        .filter(|_| arch != "src")
        .unwrap_or(release);
    if has("--requires") {
        return ok("mutter(x86-64) = 51.0-1.fc45\n");
    }
    let format = arg_after(args, "--queryformat").unwrap();
    ok(&format
        .replace("%{name}", &name)
        .replace("%{epochnum}", "0")
        .replace("%{version}", &version)
        .replace("%{release}", &release)
        .replace("%{arch}", &arch)
        .replace("\\n", "\n"))
}

#[test]
fn container_build_writes_the_stored_set() {
    let t = ContainerTest::new(DEMO_ENV, DEMO_EDIT);
    let fake = container_fake(Tools::default());
    t.run(&Tools::default(), &fake).expect("built");
    let preimage = t.out("key-input.txt");
    let pkg_dir = t.src.path().join("packaging/pkgs/demo");
    let sha = |p: &Path| sha256_hex(&std::fs::read(p).unwrap());
    assert_eq!(
        preimage,
        format!(
            "apex lane key 2\npkg demo\nlane {}\ncheck -\nrepos --repo=fedora --repo=updates --setopt=install_weak_deps=False\nstock demo-1.0-1.fc45\npin 51.0-1.fc45\npkg.env {}\nspec-edit {}\npatch 0001-a.patch {}\nsource1 {}\nrelease .apex3\n",
            "t".repeat(64),
            sha(&pkg_dir.join("pkg.env")),
            sha(&pkg_dir.join("spec-edit")),
            sha(&pkg_dir.join("patches/0001-a.patch")),
            t.tree
        ),
        "the key's preimage is stored with the set"
    );
    let key = content_key("demo-1.0-1.fc45", &preimage);
    assert_eq!(t.out("key.txt"), format!("{key}\n"));
    assert_eq!(
        t.out("attempt.txt"),
        "stock demo-1.0-1.fc45\npin mutter-51.0-1.fc45\n"
    );
    let archive_sha = sha(&t.work.path().join("in").join(&t.archive));
    let s = |text: &str| sha256_hex(text.as_bytes());
    assert_eq!(
        t.out("manifest.txt"),
        format!(
            concat!(
                "# apex-lane manifest 1: kind nevra sha256 file\n",
                "# pkg=demo family=demo key={key} release=1.fc45.apex3 n=3 stock=demo-1.0-1.fc45 ",
                "pin=mutter-51.0-1.fc45 fedora=45 ga_reached=0 base={}\n",
                "fedora-srpm demo-0:1.0-1.fc45.src {} demo-1.0-1.fc45.src.rpm\n",
                "source1 {} {archive_sha} {}\n",
                "patch 0001-a {} 0001-a.patch\n",
                "built demo-0:1.0-1.fc45.apex3.x86_64 {} demo-1.0-1.fc45.apex3.x86_64.rpm\n",
                "mirror mutter-0:51.0-1.fc45.x86_64 {} mutter-51.0-1.fc45.x86_64.rpm\n",
                "apex-srpm demo-0:1.0-1.fc45.apex3.src {} demo-1.0-1.fc45.apex3.src.rpm\n",
            ),
            base(),
            s("downloaded"),
            t.tree,
            t.archive,
            sha(&pkg_dir.join("patches/0001-a.patch")),
            s("rpm"),
            s("downloaded"),
            s("srpm"),
            key = key,
            archive_sha = archive_sha,
        )
    );
    assert!(
        t.out("spec.diff")
            .contains("+Release:        %{autorelease}.apex3\n")
    );
    assert!(
        t.out("spec.diff")
            .contains("+Patch1001:      apex-0001-a.patch\n")
    );
    assert!(
        !t.work
            .path()
            .join("out/demo-debuginfo-1.0-1.fc45.apex3.x86_64.rpm")
            .exists()
    );
    let dnf = fake.calls("dnf5");
    assert_eq!(
        dnf[0],
        [
            "-q",
            "--refresh",
            "--setopt=minrate=65536",
            "--repo=fedora",
            "--repo=updates",
            "--repo=fedora-source",
            "--repo=updates-source",
            "makecache"
        ]
    );
    assert_eq!(
        dnf[1],
        [
            "-y",
            "-q",
            "--repo=fedora",
            "--repo=updates",
            "--setopt=install_weak_deps=False",
            "install",
            "rpm-build",
            "dnf5-plugins",
            "git-core",
            "cpio",
            "diffutils",
            "/usr/bin/gpg"
        ]
    );
}

#[test]
fn container_build_is_unchanged_when_the_key_is_stored() {
    let t = ContainerTest::new(DEMO_ENV, DEMO_EDIT);
    let fake = container_fake(Tools::default());
    t.run(&Tools::default(), &fake).expect("built");
    let key = t.out("key.txt").trim().to_owned();
    write(
        &t.store.path().join(&key).join("manifest.txt"),
        "# stored\n",
    );
    let fake = container_fake(Tools::default());
    t.run(&Tools::default(), &fake).expect("unchanged");
    assert_eq!(t.out("unchanged"), format!("{key}\n"));
    assert!(fake.calls("rpmbuild").is_empty());
}

#[test]
fn container_build_takes_m_above_the_stored_builds() {
    let t = ContainerTest::new(DEMO_ENV, DEMO_EDIT);
    write(
        &t.store
            .path()
            .join("demo-1.0-1.fc45-sffffffffffff/manifest.txt"),
        "# x\n# pkg=demo key=demo-1.0-1.fc45-sffffffffffff release=1.fc45.apex3 stock=demo-1.0-1.fc45\n",
    );
    let fake = container_fake(Tools::default());
    t.run(&Tools::default(), &fake).expect("built");
    assert!(t.out("manifest.txt").contains(" release=1.fc45.apex3.1 "));
    assert!(t.out("spec.diff").contains("%{autorelease}.apex3.1\n"));
}

fn holds(env: &str, edit: &str, tools: &Tools, reason: &str) {
    let t = ContainerTest::new(env, edit);
    let fake = container_fake(tools.clone());
    let err = t.run(tools, &fake).expect_err("holds");
    assert_eq!(err.exit(), Exit::NoShippableBuild, "{err}");
    let failed = t.out("failed.txt");
    assert_eq!(failed.lines().next(), Some(reason), "{failed}");
    assert!(
        failed
            .lines()
            .nth(1)
            .unwrap()
            .starts_with("pkg=demo stock=demo-1.0-1.fc45 key=demo-1.0-1.fc45-s")
    );
}

#[test]
fn exit3_an_anchor_that_matches_nothing() {
    holds(
        DEMO_ENV,
        &format!("{DEMO_EDIT}after ^Nope:\n\tx\nend\n"),
        &Tools::default(),
        "spec-edit: 'after ^Nope:' matches 0 lines of the spec, not 1",
    );
}

#[test]
fn exit3_no_autosetup() {
    let tools = Tools {
        spec: Some(FEDORA_SPEC.replace("%autosetup -S git", "%setup -q")),
        ..Tools::default()
    };
    holds(
        DEMO_ENV,
        DEMO_EDIT,
        &tools,
        "Fedora's spec no longer uses %autosetup or %autopatch; the Patch lines would be ignored",
    );
}

#[test]
fn exit3_a_patch_1nnn_in_fedoras_spec() {
    let tools = Tools {
        spec: Some(FEDORA_SPEC.replace("Source0:", "Patch1000: x.patch\nSource0:")),
        ..Tools::default()
    };
    holds(
        DEMO_ENV,
        DEMO_EDIT,
        &tools,
        "Fedora's spec already uses a Patch1NNN number, which the series needs",
    );
}

#[test]
fn exit3_no_patch_or_source_line() {
    let tools = Tools {
        spec: Some(FEDORA_SPEC.replace("Source0:        demo-1.0.tar.xz\n", "")),
        ..Tools::default()
    };
    let edit = DEMO_EDIT.replace("after ^Source0:\n\tSource1:        @SOURCE1@\nend\n", "");
    holds(
        DEMO_ENV,
        &edit,
        &tools,
        "no Patch or Source line in Fedora's spec",
    );
}

#[test]
fn exit3_the_release_edit_is_missing() {
    let edit = DEMO_EDIT.replace("replace ^Release:[[:space:]]+%autorelease$\n\tRelease:        %{autorelease}@APEX_RELEASE@\nend\n", "");
    holds(
        DEMO_ENV,
        &edit,
        &Tools::default(),
        "the edited spec gives 1.0-1.fc45, not 1.0-1.fc45.apex3 (the Release edit)",
    );
}

#[test]
fn exit3_the_pin_is_missing_from_buildrequires() {
    let edit = DEMO_EDIT.replace("after ^BuildRequires:[[:space:]]+mutter-devel[[:space:]]\n\tBuildRequires:  mutter-devel = @PIN_EVR@\nend\n", "");
    holds(
        DEMO_ENV,
        &edit,
        &Tools::default(),
        "the edited spec does not BuildRequire mutter-devel = 51.0-1.fc45",
    );
}

#[test]
fn exit3_the_prep_lines_fail_while_the_series_applies() {
    let tools = Tools {
        patched_prep_fails: true,
        ..Tools::default()
    };
    holds(
        DEMO_ENV,
        DEMO_EDIT,
        &tools,
        "spec-edit's %prep lines fail on demo-1.0-1.fc45 (the series applies)",
    );
}

#[test]
fn exit3_the_tree_is_not_exact() {
    let tools = Tools {
        patched_prep_extra_file: true,
        ..Tools::default()
    };
    holds(
        DEMO_ENV,
        DEMO_EDIT,
        &tools,
        "the %prep tree is not Fedora's tree plus the series, Source1 and the declared %prep changes",
    );
}

#[test]
fn exit3_rpmbuild_fails() {
    let tools = Tools {
        rpmbuild_fails: true,
        ..Tools::default()
    };
    holds(
        DEMO_ENV,
        DEMO_EDIT,
        &tools,
        "demo-1.0-1.fc45 with the Apex inputs does not build",
    );
}

#[test]
fn exit3_an_install_name_without_a_binary_rpm() {
    holds(
        &DEMO_ENV.replace("install=demo", "install=demo demo-extra"),
        DEMO_EDIT,
        &Tools::default(),
        "install= names demo-extra, but the build has no such binary RPM",
    );
}

#[test]
fn exit3_a_binary_rpm_at_another_release() {
    let tools = Tools {
        built_release: Some("1.fc45.apex9".into()),
        ..Tools::default()
    };
    holds(
        DEMO_ENV,
        DEMO_EDIT,
        &tools,
        "demo-1.0-1.fc45.apex3.x86_64.rpm is 0:1.0-1.fc45.apex9, not 0:1.0-1.fc45.apex3",
    );
}

#[test]
fn exit3_check_sh_fails() {
    let tools = Tools {
        check_sh: Some(
            "echo 'ok first'\necho 'not ok: the marker is missing'\necho 'ok last'\nexit 1\n"
                .into(),
        ),
        ..Tools::default()
    };
    holds(
        DEMO_ENV,
        DEMO_EDIT,
        &tools,
        "check.sh: not ok: the marker is missing",
    );
}

#[test]
fn check_sh_that_cannot_run_is_an_infrastructure_error() {
    let tools = Tools {
        check_sh: Some("exit 2\n".into()),
        ..Tools::default()
    };
    let t = ContainerTest::new(DEMO_ENV, DEMO_EDIT);
    let fake = container_fake(tools.clone());
    let err = t.run(&tools, &fake).expect_err("fails");
    assert_eq!(err.exit(), Exit::Error);
    assert!(!t.work.path().join("out/failed.txt").exists());
}

#[test]
fn check_sh_gets_its_four_variables() {
    let tools = Tools {
        check_sh: Some("set -u\n[ -d \"$RPMS_DIR\" ] && [ -d \"$PRISTINE\" ] && [ -f \"$SOURCE1\" ] && [ -n \"$CHECK_WORK\" ] && ls \"$RPMS_DIR\"\n".into()),
        ..Tools::default()
    };
    let t = ContainerTest::new(DEMO_ENV, DEMO_EDIT);
    let fake = container_fake(tools.clone());
    t.run(&tools, &fake).expect("built");
    assert_eq!(
        t.out("logs/check.log"),
        "demo-1.0-1.fc45.apex3.x86_64.rpm\n"
    );
}

#[test]
fn source1_must_be_staged() {
    let t = ContainerTest::new(DEMO_ENV, DEMO_EDIT);
    std::fs::remove_file(t.work.path().join("in").join(&t.archive)).unwrap();
    let fake = container_fake(Tools::default());
    let err = t.run(&Tools::default(), &fake).expect_err("refused");
    assert_eq!(err.exit(), Exit::Usage);
    assert!(fake.calls("dnf5").is_empty());
}

#[test]
fn a_command_through_sudo_keeps_its_argv() {
    let cmd = Cmd::new(Program::Podman)
        .args(["run", "x"])
        .privileged(false);
    assert_eq!(cmd.program, Program::Sudo);
    assert_eq!(
        cmd.args,
        ["/usr/bin/podman", "run", "x"].map(OsString::from)
    );
    assert_eq!(
        Cmd::new(Program::Podman).privileged(true).program,
        Program::Podman
    );
    assert_eq!(
        Cmd::new(Program::Git).stderr(Stderr::ToStdout).stderr,
        Stderr::ToStdout
    );
}

fn work_tree(root: &Path) -> PathBuf {
    let tree = root.join("_build/pkg/demo/tree");
    write(&tree.join("hello.txt"), "hello\n");
    run_git(&tree, &["init", "-q"]);
    run_git(&tree, &["add", "-A"]);
    run_git(&tree, &["commit", "-q", "-m", "demo-1.0-1.fc45 %prep"]);
    run_git(&tree, &["tag", "apex-base"]);
    write(&tree.join("hello.txt"), "hello\napex\n");
    run_git(&tree, &["commit", "-q", "-a", "-m", "a"]);
    write(&tree.join("new.txt"), "new\n");
    run_git(&tree, &["add", "new.txt"]);
    run_git(&tree, &["commit", "-q", "-m", "new"]);
    tree
}

#[test]
fn export_writes_one_patch_per_commit() {
    let t = VmTest::new(DEMO_ENV);
    work_tree(t.root.path());
    let fake = Fake::new(|_| None);
    let c = clock();
    t.vm(&fake, &c)
        .export("demo", &["0002-new.patch".into()])
        .expect("exported");
    let pkg_dir = t.root.path().join("packaging/pkgs/demo");
    assert_eq!(
        std::fs::read_to_string(pkg_dir.join("series")).unwrap(),
        "0001-a.patch\n0002-new.patch\n"
    );
    let new = std::fs::read_to_string(pkg_dir.join("patches/0002-new.patch")).unwrap();
    assert!(
        new.starts_with("From 0000000000000000000000000000000000000000 "),
        "{new}"
    );
    assert!(new.contains("+new\n"));
    assert!(!new.ends_with("-- \n2."), "no signature");
    let a = std::fs::read_to_string(pkg_dir.join("patches/0001-a.patch")).unwrap();
    assert!(
        a.contains("+apex\n") && a.contains("Subject: [PATCH] a\n"),
        "{a}"
    );
}

#[test]
fn export_refuses_a_commit_count_that_does_not_match() {
    let t = VmTest::new(DEMO_ENV);
    work_tree(t.root.path());
    let fake = Fake::new(|_| None);
    let c = clock();
    let err = t.vm(&fake, &c).export("demo", &[]).unwrap_err();
    assert_eq!(err.exit(), Exit::Usage);
    assert!(
        err.to_string()
            .contains("has 2 commits after apex-base, but series lists 1 and 0 new name(s)"),
        "{err}"
    );
}

#[test]
fn export_refuses_a_new_name_twice_and_ends_series_lines() {
    let t = VmTest::new(DEMO_ENV);
    work_tree(t.root.path());
    let fake = Fake::new(|_| None);
    let c = clock();
    let err = t
        .vm(&fake, &c)
        .export("demo", &["0002-new.patch".into(), "0002-new.patch".into()])
        .unwrap_err();
    assert!(
        err.to_string().contains("'0002-new.patch' is given twice"),
        "{err}"
    );
    let series = t.root.path().join("packaging/pkgs/demo/series");
    std::fs::write(&series, "0001-a.patch").unwrap();
    t.vm(&fake, &c)
        .export("demo", &["0002-new.patch".into()])
        .expect("exported");
    assert_eq!(
        std::fs::read_to_string(series).unwrap(),
        "0001-a.patch\n0002-new.patch\n"
    );
}
