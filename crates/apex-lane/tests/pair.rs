#![allow(
    clippy::expect_used,
    clippy::unwrap_used,
    reason = "test helpers panic on broken fixtures"
)]

//! The kernel pair through `Vm::build` and `Vm::kernel_bump`, with pair.sh, bump.sh, the
//! downloads, the rpm tools and the clock faked.

use std::cell::{Cell, RefCell};
use std::collections::BTreeMap;
use std::fmt::Write as _;
use std::path::{Path, PathBuf};
use std::time::Duration;

use apex_lane::core::hash::sha256_hex;
use apex_lane::core::pins::{self, Nevra};
use apex_lane::core::utc::UtcSecond;
use apex_lane::error::Result;
use apex_lane::shell::bodhi::Bodhi;
use apex_lane::shell::clock::FixedClock;
use apex_lane::shell::cmd::{Cmd, Outcome, Program, Runner, StdRunner};
use apex_lane::shell::kernel_org::KernelOrg;
use apex_lane::shell::report::Reporter;
use apex_lane::vm::sign::PUBLIC_KEY_PATH;
use apex_lane::vm::{Outcome as Built, Settings, Vm};

const APEX_FPR: &str = "553A938903DFFEEA647F7CC4ABEF111D1FCF882B";
const COPR_FPR: &str = "537DEED33436B0367F5B26D5B3E3132CF10859CF";
const NEGATIVO17_FPR: &str = "0C5D0F470484AE2FC40A9B6597F3008993E8909B";
const TAG_FPR: &str = "E8B9AA39F054E30E8290D492C3C4820857F654FE";
const PKG_ENV: &str = "source=copr-srpm\nfamily=kernel-cachyos\ninstall=kernel-cachyos kernel-cachyos-core kernel-cachyos-modules\nkernel_env=kernel.env\nnvidia_env=nvidia.env\n";
const T0: &str = "2026-12-01T00:00:00Z";
const KERNEL_SIDE: [&str; 4] = [
    "kernel-cachyos",
    "kernel-cachyos-core",
    "kernel-cachyos-modules",
    "kernel-cachyos-devel",
];

fn at(s: &str) -> UtcSecond {
    UtcSecond::parse(s.as_bytes()).unwrap()
}

fn argv(cmd: &Cmd) -> Vec<String> {
    cmd.args
        .iter()
        .map(|a| a.to_string_lossy().into_owned())
        .collect()
}

#[allow(clippy::unnecessary_wraps, reason = "the fake answers with an Option")]
fn ok(stdout: &str) -> Option<Outcome> {
    Some(Outcome {
        code: 0,
        stdout: stdout.as_bytes().to_vec(),
        stderr: Vec::new(),
    })
}

fn write(path: &Path, text: impl AsRef<[u8]>) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, text).unwrap();
}

fn git(dir: &Path, args: &[&str]) -> String {
    let out = std::process::Command::new("git")
        .args(["-c", "init.defaultBranch=main"])
        .arg("-C")
        .arg(dir)
        .args(args)
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8(out.stdout).unwrap()
}

fn commit_all(dir: &Path) {
    git(dir, &["add", "-A"]);
    git(dir, &["commit", "-q", "-m", "change"]);
}

fn init_repo(dir: &Path) {
    git(dir, &["init", "-q"]);
    git(dir, &["config", "user.name", "t"]);
    git(dir, &["config", "user.email", "t@x"]);
    commit_all(dir);
}

/// A mirrored file's bytes are its name, so its pinned sha256 follows from the name.
fn sha_of_name(file: &str) -> String {
    sha256_hex(file.as_bytes())
}

fn kernel_env(vr: &str) -> String {
    let srpm = format!("kernel-cachyos-0:{vr}.cachyos1.fc45.src");
    let file = Nevra::parse(&srpm).unwrap().file_name();
    format!(
        "# pins\ncopr=bieszczaders/kernel-cachyos\nchroot=fedora-45-x86_64\nsrpm={srpm}\nsrpm_sha256={}\ncopr_key={COPR_FPR}\ntag=cachyos-{vr}\ntag_repo=https://github.com/CachyOS/linux.git\ntag_key={TAG_FPR}\ntag_key_url=https://keys.openpgp.org/vks/v1/by-fingerprint/{TAG_FPR}\n",
        sha_of_name(&file)
    )
}

fn nvidia_env(vr: &str) -> String {
    let kmod = format!("nvidia-kmod-3:{vr}.fc45.src");
    let common = format!("nvidia-kmod-common-3:{vr}.fc45.noarch");
    let sha = |n: &str| sha_of_name(&Nevra::parse(n).unwrap().file_name());
    format!(
        "kmod_srpm={kmod}\nkmod_srpm_sha256={}\nuserspace={common} {}\nnegativo17_key={NEGATIVO17_FPR}\n",
        sha(&kmod),
        sha(&common)
    )
}

/// What the fake pair.sh does with a job: its exit status and stderr.
type Job = dyn Fn(&JobDirs) -> (i32, String);

struct JobDirs {
    out: PathBuf,
    job: PathBuf,
    mirror: PathBuf,
}

struct Fake {
    log: RefCell<Vec<Cmd>>,
    keyrings: RefCell<BTreeMap<String, String>>,
    job: RefCell<Box<Job>>,
    bump: RefCell<String>,
    /// Each SRPM's `config` by its version, `CONFIG_A=y` when not set.
    configs: RefCell<BTreeMap<String, String>>,
    tag_signer: RefCell<String>,
    archive_matches: Cell<bool>,
    /// Modules in kernel-cachyos-modules, by kernel version-release; 1000 otherwise.
    modules: RefCell<BTreeMap<String, usize>>,
    real: StdRunner,
}

fn fpr_of_key_file(path: &str) -> String {
    let text = std::fs::read_to_string(path).unwrap_or_default();
    text.strip_prefix("KEY:")
        .map_or_else(|| APEX_FPR.to_owned(), str::to_owned)
}

fn mount(args: &[String], to: &str) -> PathBuf {
    let spec = args
        .iter()
        .find(|a| a.contains(&format!(":{to}:")))
        .expect("mount");
    PathBuf::from(spec.split(':').next().unwrap())
}

/// `name-version-release.arch.rpm`, the kmod at epoch 3 like negativo17's.
fn nevra_of_file(file: &str) -> String {
    let stem = file.strip_suffix(".rpm").unwrap();
    let (nvr, arch) = stem.rsplit_once('.').unwrap();
    let (nv, release) = nvr.rsplit_once('-').unwrap();
    let (name, version) = nv.rsplit_once('-').unwrap();
    let epoch = if name.starts_with("kmod-nvidia") {
        3
    } else {
        0
    };
    format!("{name}-{epoch}:{version}-{release}.{arch}")
}

impl Fake {
    fn new() -> Self {
        Self {
            log: RefCell::default(),
            keyrings: RefCell::default(),
            job: RefCell::new(Box::new(|_: &JobDirs| -> (i32, String) {
                panic!("no job expected")
            })),
            bump: RefCell::default(),
            configs: RefCell::default(),
            tag_signer: RefCell::new(TAG_FPR.into()),
            archive_matches: Cell::new(true),
            modules: RefCell::default(),
            real: StdRunner::inherit(),
        }
    }

    fn on_job(&self, job: impl Fn(&JobDirs) -> (i32, String) + 'static) {
        *self.job.borrow_mut() = Box::new(job);
    }

    fn calls(&self, program: Program) -> usize {
        self.log
            .borrow()
            .iter()
            .filter(|c| {
                c.program == program || argv(c).first().is_some_and(|a| a == program.path())
            })
            .count()
    }

    /// The tools of `kernel-bump`'s report, past `bump.sh`.
    fn report_tools(&self, cmd: &Cmd) -> Option<Outcome> {
        let args = argv(cmd);
        let has = |a: &str| args.iter().any(|x| x == a);
        match cmd.program {
            Program::Rpm if has("[%{PATCH}\\n]") => ok("anatase-1.patch\nanatase-2.patch\n"),
            Program::Bash if args[1].contains("cmp -s") => Some(Outcome {
                code: i32::from(!self.archive_matches.get()),
                ..Outcome::default()
            }),
            Program::Tar if has("-tzf") => {
                let tarball = args.last().unwrap().rsplit('/').next().unwrap();
                let top = tarball.strip_suffix(".tar.gz").unwrap();
                ok(&format!("{top}/\n{top}/Makefile\n"))
            }
            Program::Git if has("fetch") => {
                assert!(has("https://github.com/CachyOS/linux.git"), "{args:?}");
                ok("")
            }
            Program::Git if has("verify-tag") => {
                let fpr = self.tag_signer.borrow();
                Some(Outcome {
                    code: 0,
                    stdout: Vec::new(),
                    stderr: format!(
                        "[GNUPG:] GOODSIG X Peter\n[GNUPG:] VALIDSIG {fpr} 2026-10-23 1 0 4 0 22 10 00 {fpr}\n"
                    )
                    .into_bytes(),
                })
            }
            _ => None,
        }
    }

    fn script(&self, cmd: &Cmd) -> Option<Outcome> {
        let args = argv(cmd);
        let has = |a: &str| args.iter().any(|x| x == a);
        match cmd.program {
            Program::Curl => {
                let to = &args[args.iter().position(|a| a == "-o").unwrap() + 1];
                let url = args.last().unwrap();
                let body = if url.ends_with("/pubkey.gpg") {
                    format!("KEY:{COPR_FPR}")
                } else if url.ends_with("RPM-GPG-KEY-slaanesh") {
                    format!("KEY:{NEGATIVO17_FPR}")
                } else if url.contains("keys.openpgp.org") {
                    format!("KEY:{TAG_FPR}")
                } else {
                    url.rsplit('/').next().unwrap().to_owned()
                };
                write(Path::new(to), body);
                ok("")
            }
            Program::Gpg if has("--show-keys") => ok(&format!(
                "pub:-:255:22:X:1::::scSC:\nfpr:::::::::{}:\n",
                fpr_of_key_file(args.last().unwrap())
            )),
            Program::Gpg => ok(""),
            Program::Rpmkeys => {
                let db = args[args.iter().position(|a| a == "--dbpath").unwrap() + 1].clone();
                if has("--import") {
                    let fpr = fpr_of_key_file(args.last().unwrap());
                    self.keyrings.borrow_mut().insert(db, fpr);
                    return ok("");
                }
                let fpr = self.keyrings.borrow()[&db].to_ascii_lowercase();
                ok(&format!(
                    "{}:\n    Header OpenPGP V4 RSA/SHA256 signature, key fingerprint: {fpr}: OK\n    Header SHA256 digest: OK\n",
                    args.last().unwrap()
                ))
            }
            Program::Rpmsign => {
                let rpm = args.last().unwrap();
                let mut bytes = std::fs::read(rpm).unwrap();
                bytes.extend_from_slice(b" +signature");
                std::fs::write(rpm, bytes).unwrap();
                ok("")
            }
            Program::Rpm if has("-qlp") => {
                let files = &args[args.iter().position(|a| a == "--").unwrap() + 1..];
                let mut listing = String::new();
                for f in files {
                    let name = f.rsplit('/').next().unwrap();
                    let Some(rest) = name.strip_prefix("kernel-cachyos-modules-") else {
                        let _ = writeln!(listing, "/usr/share/doc/{name}/README");
                        continue;
                    };
                    let vr = rest.split(".cachyos").next().unwrap();
                    let n = self.modules.borrow().get(vr).copied().unwrap_or(1000);
                    for i in 0..n {
                        let _ = writeln!(listing, "/lib/modules/{vr}/kernel/m{i}.ko.xz");
                    }
                }
                ok(&listing)
            }
            Program::Rpm => {
                let files = &args[args.iter().position(|a| a == "--").unwrap() + 1..];
                let lines: String = files
                    .iter()
                    .map(|f| nevra_of_file(f.rsplit('/').next().unwrap()) + "\n")
                    .collect();
                ok(&lines)
            }
            Program::Bash if args[0].ends_with("/bump.sh") => ok(&self.bump.borrow()),
            Program::Sudo => match args[0].as_str() {
                "/usr/bin/podman" => {
                    let dirs = JobDirs {
                        out: mount(&args, "/out"),
                        job: mount(&args, "/job"),
                        mirror: mount(&args, "/mirror"),
                    };
                    let (code, stderr) = (self.job.borrow())(&dirs);
                    Some(Outcome {
                        code,
                        stdout: Vec::new(),
                        stderr: stderr.into_bytes(),
                    })
                }
                "/usr/bin/chown" => ok(""),
                "/usr/bin/rm" => {
                    let _ = std::fs::remove_dir_all(args.last().unwrap());
                    ok("")
                }
                other => panic!("sudo {other}"),
            },
            _ => None,
        }
    }
}

impl Runner for Fake {
    fn run(&self, cmd: &Cmd) -> Result<Outcome> {
        self.log.borrow_mut().push(cmd.clone());
        if let Some(out) = self.report_tools(cmd).or_else(|| self.script(cmd)) {
            return Ok(out);
        }
        match cmd.program {
            Program::Git | Program::Cp => self.real.run(cmd),
            _ => panic!("unexpected command: {cmd}"),
        }
    }

    /// rpm2cpio | cpio of a kernel SRPM: its Source0, config and BORE patch.
    fn pipe(&self, first: &Cmd, second: &Cmd) -> Result<(Outcome, Outcome)> {
        assert_eq!(
            (first.program, second.program),
            (Program::Rpm2cpio, Program::Cpio)
        );
        let srpm = argv(first)[0].rsplit('/').next().unwrap().to_owned();
        let nevra = Nevra::parse(&format!(
            "kernel-cachyos-0:{}",
            srpm.strip_prefix("kernel-cachyos-")
                .unwrap()
                .strip_suffix(".rpm")
                .unwrap()
        ))
        .unwrap();
        let dir = second.cwd.clone().unwrap();
        let tag = format!(
            "cachyos-{}-{}",
            nevra.version,
            nevra.release.split('.').next().unwrap()
        );
        write(&dir.join(format!("{tag}.tar.gz")), &tag);
        let vr = format!(
            "{}-{}",
            nevra.version,
            nevra.release.split('.').next().unwrap()
        );
        let config = self.configs.borrow().get(&vr).cloned();
        write(
            &dir.join("config"),
            config.unwrap_or_else(|| "CONFIG_A=y\n".into()),
        );
        write(&dir.join("0001-bore-cachy.patch"), "bore");
        write(&dir.join("kernel-cachyos.spec"), "spec");
        Ok((Outcome::default(), Outcome::default()))
    }

    fn sleep(&self, _: Duration) {}
}

/// pair.sh's work from the staged job: the pinned kernel, the kmod for it, pair.lock.
fn good_job(dirs: &JobDirs) -> (i32, String) {
    write_pair(dirs, true);
    (0, "ok wrote /out/pair.lock\n".into())
}

fn write_pair(dirs: &JobDirs, with_kmod: bool) {
    let kernel =
        pins::parse_kernel("k", &std::fs::read(dirs.job.join("kernel.env")).unwrap()).unwrap();
    let nvidia =
        pins::parse_nvidia("n", &std::fs::read(dirs.job.join("nvidia.env")).unwrap()).unwrap();
    for file in [
        kernel.srpm.file_name(),
        nvidia.kmod_srpm.file_name(),
        "copr.gpg".into(),
        "negativo17.gpg".into(),
    ] {
        assert!(
            dirs.mirror.join(&file).is_file(),
            "the job's mirror has no {file}"
        );
    }
    let vr = format!("{}-{}", kernel.srpm.version, kernel.srpm.release);
    let uname = format!("{vr}.x86_64");
    let mut files: Vec<String> = KERNEL_SIDE
        .iter()
        .map(|n| format!("{n}-{uname}.rpm"))
        .collect();
    let kmod_file = format!(
        "kmod-nvidia-{uname}-{}-{}.x86_64.rpm",
        nvidia.kmod_srpm.version, nvidia.kmod_srpm.release
    );
    if with_kmod {
        files.push(kmod_file.clone());
    }
    let mut lock = format!("kernel=kernel-cachyos-0:{uname}\n");
    if with_kmod {
        let _ = writeln!(lock, "kmod={}", nevra_of_file(&kmod_file));
    }
    let _ = writeln!(lock, "module_cert_sha256={}", "c".repeat(64));
    for f in &files {
        write(&dirs.out.join("rpms").join(f), f);
        let _ = writeln!(lock, "rpm={f} {}", sha_of_name(f));
    }
    write(
        &dirs.out.join(if with_kmod {
            "pair.lock"
        } else {
            "kernel.lock"
        }),
        lock,
    );
    write(&dirs.out.join("signing_key.x509"), "cert");
    write(&dirs.out.join("kernel.log"), "built");
}

fn failing(reason: &'static str, keep_kernel: bool) -> impl Fn(&JobDirs) -> (i32, String) {
    move |dirs| {
        if keep_kernel {
            write_pair(dirs, false);
        }
        (1, format!("the log's tail\n{reason}\n"))
    }
}

struct Released(Option<UtcSecond>);

impl KernelOrg for Released {
    fn released(&self, _: &str) -> Option<UtcSecond> {
        self.0
    }
}

struct NoBodhi;

impl Bodhi for NoBodhi {
    fn types(&self, _: &str) -> String {
        String::new()
    }
}

/// A child forked by another test's thread keeps a store's flock until it execs, so
/// these tests, which take the store lock back to back, run one at a time.
static SERIAL: std::sync::Mutex<()> = std::sync::Mutex::new(());

struct PairTest {
    _serial: std::sync::MutexGuard<'static, ()>,
    root: tempfile::TempDir,
    recipes: tempfile::TempDir,
    store: tempfile::TempDir,
    report: Reporter,
    fake: Fake,
    released: Cell<Option<UtcSecond>>,
}

impl PairTest {
    fn new() -> Self {
        let serial = SERIAL
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let root = tempfile::tempdir().unwrap();
        let r = root.path();
        write(
            &r.join("image/Containerfile"),
            "FROM x\nARG REPOS_BASE=registry.fedoraproject.org/fedora@sha256:1e13e11f63e147a40a935c9046c79d53a30b861a3cf05ebb023bb53c562382cb\nARG GA_REACHED=1\n",
        );
        write(&r.join(PUBLIC_KEY_PATH), "the committed public key\n");
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
        init_repo(r);
        let recipes = tempfile::tempdir().unwrap();
        let k = recipes.path().join("packaging/pkgs/kernel");
        write(&k.join("pkg.env"), PKG_ENV);
        write(&k.join("kernel.env"), kernel_env("7.3.0-4"));
        write(&k.join("nvidia.env"), nvidia_env("615.78.08-1"));
        write(&k.join("pair.sh"), "#!/bin/bash\n");
        write(&k.join("config-required.txt"), "CONFIG_MODULE_SIG=y\n");
        write(&k.join("bump.sh"), "#!/bin/bash\n");
        init_repo(recipes.path());
        let t = Self {
            _serial: serial,
            root,
            recipes,
            store: tempfile::tempdir().unwrap(),
            report: Reporter::capturing(),
            fake: Fake::new(),
            released: Cell::new(None),
        };
        write(
            &t.store.path().join("rpm-signing.env"),
            format!(
                "APEX_RPM_KEY_FPR={APEX_FPR}\nAPEX_RPM_GNUPGHOME={}/gnupg\n",
                t.store.path().display()
            ),
        );
        t
    }

    fn pins(&self, kernel: &str, nvidia: &str) {
        let k = self.recipes.path().join("packaging/pkgs/kernel");
        write(&k.join("kernel.env"), kernel_env(kernel));
        write(&k.join("nvidia.env"), nvidia_env(nvidia));
        commit_all(self.recipes.path());
    }

    fn run<T>(&self, now: &str, f: impl FnOnce(&Vm<'_>) -> T) -> T {
        let clock = FixedClock(at(now));
        let released = Released(self.released.get());
        let vm = Vm {
            root: self.root.path().to_path_buf(),
            recipes: vec![self.recipes.path().to_path_buf()],
            settings: Settings {
                store: self.store.path().to_path_buf(),
                ga_override: None,
                keep_work: false,
                signing_env: self.store.path().join("rpm-signing.env"),
                exe: PathBuf::from("/opt/apex-lane"),
                uid: 1000,
                gid: 1000,
                is_root: false,
            },
            runner: &self.fake,
            clock: &clock,
            bodhi: &NoBodhi,
            kernel_org: &released,
            report: &self.report,
        };
        f(&vm)
    }

    fn build(&self, now: &str) -> Built {
        self.run(now, |vm| vm.build("kernel").expect("build").remove(0))
    }

    fn promote(&self) {
        self.run(T0, |vm| vm.promote(true).expect("promote"));
    }

    fn next_lock(&self) -> String {
        std::fs::read_to_string(self.store.path().join("rpms.lock.next")).unwrap()
    }

    fn family_line(&self) -> String {
        self.next_lock()
            .lines()
            .find(|l| l.starts_with("family kernel-cachyos "))
            .unwrap()
            .to_owned()
    }

    fn rpm_lines(lock: &str) -> Vec<String> {
        lock.lines()
            .filter(|l| l.starts_with("rpm kernel-cachyos "))
            .map(str::to_owned)
            .collect()
    }

    fn staged_nvidia(&self) -> String {
        std::fs::read_to_string(
            self.root
                .path()
                .join("_build/lane/kernel/in/job/nvidia.env"),
        )
        .unwrap()
    }

    /// A built, promoted pair of 7.3.0-4 and 615.78.08-1: the last good pair.
    fn with_good_pair(&self) -> String {
        self.fake.on_job(good_job);
        let Built::Built(key) = self.build(T0) else {
            panic!("not built")
        };
        self.promote();
        key
    }
}

/// image.sh's own check of a lane lock, run on the lock the lane wrote.
fn image_sh_accepts(lock: &Path) {
    let image_sh = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../.github/scripts/image.sh");
    let script = std::fs::read_to_string(image_sh).unwrap();
    let start = script.find("lane_lock_check() {").unwrap();
    let end = start + script[start..].find("\n}\n").unwrap() + 3;
    let check = format!(
        "log() {{ printf '%s\\n' \"$*\" >&2; }}\n{}\nlane_lock_check \"$1\" kernel-cachyos >/dev/null",
        &script[start..end]
    );
    let out = std::process::Command::new("bash")
        .args(["-c", &check, "check"])
        .arg(lock)
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "image.sh refuses the lock: {}",
        String::from_utf8_lossy(&out.stderr)
    );
}

#[test]
fn a_good_pair_is_signed_stored_and_locked() {
    let t = PairTest::new();
    let key = t.with_good_pair();
    assert!(
        key.starts_with("kernel-cachyos-7.3.0-4.cachyos1.fc45-s"),
        "{key}"
    );
    let lock = t.next_lock();
    assert_eq!(
        t.family_line(),
        format!("family kernel-cachyos built {key}")
    );
    let rpms = PairTest::rpm_lines(&lock);
    let names: Vec<&str> = rpms.iter().map(|l| l.split(' ').nth(3).unwrap()).collect();
    assert_eq!(
        names,
        [
            "kernel-cachyos",
            "kernel-cachyos-core",
            "kernel-cachyos-modules",
            "kmod-nvidia-7.3.0-4.cachyos1.fc45.x86_64",
            "nvidia-kmod-common"
        ],
        "the install= names, the kmod and the userspace; -devel is stored, not locked"
    );
    let userspace = "nvidia-kmod-common-615.78.08-1.fc45.noarch.rpm";
    assert_eq!(
        rpms[4],
        format!(
            "rpm kernel-cachyos mirror nvidia-kmod-common nvidia-kmod-common-3:615.78.08-1.fc45.noarch {} pkgs/kernel/{key}/{userspace}",
            sha_of_name(userspace)
        ),
        "negativo17's RPM, unmodified, from the mirror"
    );
    let kmod = &rpms[3];
    let file = "kmod-nvidia-7.3.0-4.cachyos1.fc45.x86_64-615.78.08-1.fc45.x86_64.rpm";
    let signed = sha256_hex(format!("{file} +signature").as_bytes());
    assert_eq!(
        *kmod,
        format!(
            "rpm kernel-cachyos built kmod-nvidia-7.3.0-4.cachyos1.fc45.x86_64 kmod-nvidia-7.3.0-4.cachyos1.fc45.x86_64-3:615.78.08-1.fc45.x86_64 {signed} pkgs/kernel/{key}/{file}"
        )
    );
    image_sh_accepts(&t.store.path().join("rpms.lock.next"));
    let set = t.store.path().join("pkgs/kernel").join(&key);
    for kept in [
        "pair.lock",
        "kernel.env",
        "nvidia.env",
        "signing_key.x509",
        "key-input.txt",
        "config-required.txt",
        "negativo17.gpg",
        "logs/kernel.log",
    ] {
        assert!(set.join(kept).is_file(), "the stored pair has no {kept}");
    }
    assert!(
        std::fs::read_to_string(set.join("manifest.txt"))
            .unwrap()
            .contains(&format!("# sig={APEX_FPR}"))
    );
    let podman = t
        .fake
        .log
        .borrow()
        .iter()
        .filter(|c| argv(c).first().is_some_and(|a| a == "/usr/bin/podman"))
        .map(argv)
        .collect::<Vec<_>>();
    assert_eq!(podman.len(), 1);
    let args = &podman[0];
    let tail = &args[args.len() - 6..];
    assert_eq!(
        tail,
        [
            "/usr/bin/bash",
            "/job/pair.sh",
            "/mirror",
            "/out",
            "--repo=fedora",
            "--repo=updates"
        ]
    );
    assert!(
        args.windows(2)
            .any(|w| w == ["--tmpfs", "/run/apex-modkey:rw,mode=0700"])
    );
}

#[test]
fn inputs_are_mirrored_at_first_sight_only() {
    let t = PairTest::new();
    let key = t.with_good_pair();
    let mirror = t.store.path().join("mirror");
    for file in [
        "kernel-cachyos-7.3.0-4.cachyos1.fc45.src.rpm",
        "nvidia-kmod-615.78.08-1.fc45.src.rpm",
        "nvidia-kmod-common-615.78.08-1.fc45.noarch.rpm",
        &format!("keys/{COPR_FPR}.gpg"),
        &format!("keys/{NEGATIVO17_FPR}.gpg"),
    ] {
        assert!(mirror.join(file).is_file(), "the mirror has no {file}");
    }
    assert_eq!(t.fake.calls(Program::Curl), 5);
    assert_eq!(t.build(T0), Built::Unchanged(key));
    assert_eq!(
        t.fake.calls(Program::Curl),
        5,
        "nothing is downloaded twice"
    );
}

#[test]
fn the_kernel_moves_before_the_driver() {
    let t = PairTest::new();
    t.with_good_pair();
    t.pins("7.3.1-1", "615.80.01-1");
    let Built::Built(first) = t.build(T0) else {
        panic!("not built")
    };
    assert!(first.starts_with("kernel-cachyos-7.3.1-1.cachyos1.fc45-s"));
    assert!(
        t.staged_nvidia().contains("nvidia-kmod-3:615.78.08-1"),
        "the old driver with the new kernel"
    );
    assert!(
        t.next_lock()
            .contains("kmod-nvidia-7.3.1-1.cachyos1.fc45.x86_64-3:615.78.08-1")
    );
    assert!(
        t.next_lock()
            .contains(" nvidia-kmod-common-3:615.78.08-1.fc45.noarch "),
        "the userspace waits with its driver"
    );
    assert!(
        String::from_utf8_lossy(&t.report.captured())
            .contains("nvidia-kmod-3:615.80.01-1.fc45.src waits for the image after this one")
    );
    assert!(
        t.store
            .path()
            .join("mirror/nvidia-kmod-615.80.01-1.fc45.src.rpm")
            .is_file(),
        "the waiting driver is mirrored at first sight"
    );
    t.promote();
    let Built::Built(second) = t.build(T0) else {
        panic!("not built")
    };
    assert_ne!(first, second);
    assert!(t.staged_nvidia().contains("nvidia-kmod-3:615.80.01-1"));
    assert!(
        t.next_lock()
            .contains("kmod-nvidia-7.3.1-1.cachyos1.fc45.x86_64-3:615.80.01-1")
    );
    assert!(
        t.next_lock()
            .contains(" nvidia-kmod-common-3:615.80.01-1.fc45.noarch ")
    );
}

#[test]
fn a_kernel_failure_holds_72_hours_from_the_kernel_org_release_then_a_rerun_clears_it() {
    let t = PairTest::new();
    let good = t.with_good_pair();
    let good_rpms = PairTest::rpm_lines(&t.next_lock());
    t.pins("7.3.1-1", "615.78.08-1");
    t.released.set(Some(at("2026-11-30T12:00:00Z")));
    t.fake.on_job(failing("kernel: rpmbuild -bb failed", false));
    assert_eq!(t.build(T0), Built::Held);
    assert_eq!(
        t.family_line(),
        format!(
            "family kernel-cachyos held {good} since={T0} limit=2026-12-03T12:00:00Z newer=kernel-cachyos-0:7.3.1-1.cachyos1.fc45.src security=1 side=kernel reason=kernel: rpmbuild -bb failed"
        )
    );
    assert_eq!(
        PairTest::rpm_lines(&t.next_lock()),
        good_rpms,
        "the last good pair stays"
    );
    image_sh_accepts(&t.store.path().join("rpms.lock.next"));
    let failure =
        std::fs::read_to_string(t.store.path().join("pkgs/kernel/last-failure.txt")).unwrap();
    assert!(failure.starts_with("kernel: rpmbuild -bb failed\nthe log's tail\n"));
    assert_eq!(t.build("2026-12-02T00:00:00Z"), Built::Held);
    assert!(
        t.family_line().contains(&format!("since={T0} ")),
        "the clock keeps its start"
    );
    let status = t.run("2026-12-04T00:00:00Z", |vm| vm.status().unwrap());
    assert!(String::from_utf8_lossy(&status).contains("LIMIT REACHED: the owner chooses"));
    t.fake.on_job(good_job);
    let Built::Built(key) = t.build("2026-12-04T00:00:00Z") else {
        panic!("not built")
    };
    assert_eq!(
        t.family_line(),
        format!("family kernel-cachyos built {key}")
    );
}

#[test]
fn a_kernel_failure_without_a_known_release_counts_from_the_first_failure() {
    let t = PairTest::new();
    t.with_good_pair();
    t.pins("7.3.1-1", "615.78.08-1");
    t.fake
        .on_job(failing("x.src.rpm does not have its pinned sha256", false));
    assert_eq!(t.build(T0), Built::Held);
    assert!(t.family_line().contains("limit=2026-12-04T00:00:00Z"));
    assert!(t.family_line().contains("side=kernel"));
}

#[test]
fn a_kmod_failure_on_a_point_release_holds_72_hours_then_degrades_nvidia() {
    let t = PairTest::new();
    let good = t.with_good_pair();
    t.pins("7.3.1-1", "615.78.08-1");
    t.fake.on_job(failing(
        "kmod: nvidia-kmod-3:615.78.08-1.fc45.src does not build for this kernel",
        true,
    ));
    assert_eq!(t.build(T0), Built::Held);
    let newer = "newer=kernel-cachyos-0:7.3.1-1.cachyos1.fc45.src";
    assert_eq!(
        t.family_line(),
        format!(
            "family kernel-cachyos held {good} since={T0} limit=2026-12-04T00:00:00Z {newer} security=1 side=kmod reason=kmod: nvidia-kmod-3:615.78.08-1.fc45.src does not build for this kernel"
        )
    );
    assert_eq!(t.build("2026-12-03T23:59:59Z"), Built::Held);
    assert_eq!(t.build("2026-12-04T00:00:00Z"), Built::Degraded);
    let line = t.family_line();
    let key = line.split(' ').nth(3).unwrap().to_owned();
    assert_ne!(key, good);
    assert_eq!(
        line,
        format!(
            "family kernel-cachyos built {key} since={T0} limit=2026-12-04T00:00:00Z {newer} security=1 degraded=nvidia side=kmod reason=kmod: nvidia-kmod-3:615.78.08-1.fc45.src does not build for this kernel"
        )
    );
    let lock = t.next_lock();
    let names: Vec<String> = PairTest::rpm_lines(&lock)
        .iter()
        .map(|l| l.split(' ').nth(4).unwrap().to_owned())
        .collect();
    assert_eq!(
        names,
        [
            "kernel-cachyos-0:7.3.1-1.cachyos1.fc45.x86_64",
            "kernel-cachyos-core-0:7.3.1-1.cachyos1.fc45.x86_64",
            "kernel-cachyos-modules-0:7.3.1-1.cachyos1.fc45.x86_64"
        ],
        "the new kernel without the NVIDIA set"
    );
    image_sh_accepts(&t.store.path().join("rpms.lock.next"));
    assert_eq!(t.build("2026-12-05T00:00:00Z"), Built::Degraded);
    assert_eq!(
        t.family_line(),
        line,
        "the same degraded set, the same clock"
    );
}

#[test]
fn a_kmod_hold_at_its_limit_without_the_kernel_stays_held() {
    let t = PairTest::new();
    let good = t.with_good_pair();
    t.pins("7.3.1-1", "615.78.08-1");
    t.fake.on_job(failing("kmod: it does not build", false));
    assert_eq!(t.build(T0), Built::Held);
    assert_eq!(t.build("2026-12-05T00:00:00Z"), Built::Held);
    assert!(
        t.family_line()
            .starts_with(&format!("family kernel-cachyos held {good} since={T0}"))
    );
    assert!(
        String::from_utf8_lossy(&t.report.captured())
            .contains("LIMIT REACHED, but the pair job kept no kernel")
    );
}

#[test]
fn a_kmod_failure_on_a_new_major_holds_14_days() {
    let t = PairTest::new();
    t.with_good_pair();
    t.pins("7.4.0-1", "615.78.08-1");
    t.fake.on_job(failing("kmod: it does not build", true));
    assert_eq!(t.build(T0), Built::Held);
    assert!(t.family_line().contains("limit=2026-12-15T00:00:00Z newer=kernel-cachyos-0:7.4.0-1.cachyos1.fc45.src security=0 side=kmod"));
    assert_eq!(t.build("2026-12-14T23:59:59Z"), Built::Held);
    assert_eq!(t.build("2026-12-15T00:00:00Z"), Built::Degraded);
}

#[test]
fn a_driver_that_does_not_build_holds_without_a_limit() {
    let t = PairTest::new();
    let good = t.with_good_pair();
    t.pins("7.3.0-4", "615.80.01-1");
    t.fake.on_job(failing("kmod: it does not build", true));
    assert_eq!(t.build(T0), Built::Held);
    assert_eq!(
        t.family_line(),
        format!(
            "family kernel-cachyos held {good} since={T0} newer=nvidia-kmod-3:615.80.01-1.fc45.src side=kmod reason=kmod: it does not build"
        )
    );
    assert_eq!(
        t.build("2027-01-01T00:00:00Z"),
        Built::Held,
        "no limit, so never degraded"
    );
}

#[test]
fn a_failure_with_no_last_good_pair_stops_the_image_build() {
    let t = PairTest::new();
    t.fake.on_job(failing("kernel: rpmbuild -bb failed", false));
    let err = t.run(T0, |vm| vm.build("kernel")).unwrap_err();
    assert_eq!(err.exit(), apex_lane::Exit::Error);
    assert!(
        err.to_string()
            .contains("no last good pair of kernel-cachyos")
    );
}

#[test]
fn pair_sh_that_cannot_run_is_an_infrastructure_error() {
    let t = PairTest::new();
    t.fake
        .on_job(|_| (2, "pair.sh cannot run: no dnf5 in the container\n".into()));
    let err = t.run(T0, |vm| vm.build("all")).unwrap_err();
    assert_eq!(err.exit(), apex_lane::Exit::Error);
    assert!(err.to_string().contains("no dnf5 in the container"));
    assert!(!t.store.path().join("rpms.lock.next").exists());
}

#[test]
fn key_prints_the_pairs_key_without_a_container() {
    let t = PairTest::new();
    t.run(T0, |vm| vm.key("kernel").unwrap());
    let shown = String::from_utf8_lossy(&t.report.captured()).into_owned();
    assert!(
        shown.starts_with("kernel-cachyos-7.3.0-4.cachyos1.fc45-s"),
        "{shown}"
    );
    assert_eq!(t.fake.calls(Program::Podman), 0);
}

#[test]
fn a_point_bump_commits_the_new_pins_on_a_branch() {
    let t = PairTest::new();
    let head = git(t.recipes.path(), &["rev-parse", "HEAD"]);
    *t.fake.bump.borrow_mut() = "point kernel-cachyos-0:7.3.1-1.cachyos1.fc45.src\nnvidia nvidia-kmod-3:615.80.01-1.fc45.src abc newer\n".into();
    t.run(T0, |vm| vm.kernel_bump().unwrap());
    let branch = "kernel-bump/kernel-cachyos-7.3.1-1.cachyos1.fc45";
    let env = git(
        t.recipes.path(),
        &[
            "show",
            &format!("{branch}:packaging/pkgs/kernel/kernel.env"),
        ],
    );
    let file = "kernel-cachyos-7.3.1-1.cachyos1.fc45.src.rpm";
    assert_eq!(
        env,
        kernel_env("7.3.1-1"),
        "srpm, its sha256 and the tag move; nothing else"
    );
    assert!(env.contains(&sha_of_name(file)));
    assert!(
        t.store.path().join("mirror").join(file).is_file(),
        "mirrored at first sight"
    );
    assert_eq!(
        git(t.recipes.path(), &["rev-parse", "HEAD"]),
        head,
        "HEAD stays"
    );
    assert_eq!(git(t.recipes.path(), &["status", "--porcelain"]), "");
    let shown = String::from_utf8_lossy(&t.report.captured()).into_owned();
    assert!(shown.contains(&format!("on {branch}")), "{shown}");
    assert!(shown.contains("nvidia-kmod-3:615.80.01-1.fc45.src is newer than the pins; a new driver waits for the owner"));
    t.run(T0, |vm| vm.kernel_bump().unwrap());
    assert!(String::from_utf8_lossy(&t.report.captured()).contains("already exists"));
}

#[test]
fn a_major_bump_waits_for_the_owner() {
    let t = PairTest::new();
    *t.fake.bump.borrow_mut() =
        "major kernel-cachyos-0:7.4.0-1.cachyos1.fc45.src waiting-for-owner EOL-in-12d\n".into();
    t.run(T0, |vm| vm.kernel_bump().unwrap());
    let shown = String::from_utf8_lossy(&t.report.captured()).into_owned();
    assert!(shown.contains("kernel-cachyos-0:7.4.0-1.cachyos1.fc45.src is a new major: waiting for owner; the pinned 7.3 reaches its EOL in 12d"), "{shown}");
    assert_eq!(
        git(t.recipes.path(), &["branch", "--list", "kernel-bump/*"]),
        ""
    );
    *t.fake.bump.borrow_mut() = "none\n".into();
    t.run(T0, |vm| vm.kernel_bump().unwrap());
    assert!(
        String::from_utf8_lossy(&t.report.captured())
            .contains("no newer build of the pinned major")
    );
}

#[test]
fn a_promoted_degraded_kernel_stays_degraded_until_a_whole_pair_builds() {
    let t = PairTest::new();
    t.with_good_pair();
    t.pins("7.3.1-1", "615.78.08-1");
    t.fake.on_job(failing("kmod: it does not build", true));
    assert_eq!(t.build(T0), Built::Held);
    assert_eq!(t.build("2026-12-04T00:00:00Z"), Built::Degraded);
    let degraded = t.family_line().split(' ').nth(3).unwrap().to_owned();
    let refused = t.run(T0, |vm| vm.promote(false)).unwrap_err();
    assert!(
        refused.to_string().contains("the owner's publish override"),
        "{refused}"
    );
    assert!(
        !std::fs::read_to_string(t.store.path().join("rpms.lock"))
            .unwrap()
            .contains(&degraded)
    );
    t.promote();
    t.run(T0, |vm| vm.promote(false))
        .expect("a degraded set already promoted is no new one");
    assert_eq!(t.build("2026-12-05T00:00:00Z"), Built::Degraded);
    assert!(
        t.family_line().starts_with(&format!(
            "family kernel-cachyos built {degraded} since={T0} degraded=nvidia side=kmod"
        )),
        "{}",
        t.family_line()
    );
    t.pins("7.3.2-1", "615.78.08-1");
    t.fake.on_job(failing("kernel: rpmbuild -bb failed", false));
    assert_eq!(t.build("2026-12-06T00:00:00Z"), Built::Held);
    assert!(
        t.family_line()
            .starts_with(&format!("family kernel-cachyos held {degraded} "))
    );
    assert!(t.family_line().contains(" degraded=nvidia side=kernel "));
    image_sh_accepts(&t.store.path().join("rpms.lock.next"));
    t.fake.on_job(good_job);
    let Built::Built(key) = t.build("2026-12-06T01:00:00Z") else {
        panic!("not built")
    };
    assert_eq!(
        t.family_line(),
        format!("family kernel-cachyos built {key}")
    );
    assert!(t.next_lock().contains("kmod-nvidia-7.3.2-1"));
}

#[test]
fn a_point_and_a_major_bump_together() {
    let t = PairTest::new();
    *t.fake.bump.borrow_mut() = "point kernel-cachyos-0:7.3.1-1.cachyos1.fc45.src\nmajor kernel-cachyos-0:7.4.0-1.cachyos1.fc45.src waiting-for-owner EOL-in-9d\n".into();
    t.run(T0, |vm| vm.kernel_bump().unwrap());
    let env = git(
        t.recipes.path(),
        &[
            "show",
            "kernel-bump/kernel-cachyos-7.3.1-1.cachyos1.fc45:packaging/pkgs/kernel/kernel.env",
        ],
    );
    assert_eq!(env, kernel_env("7.3.1-1"), "the point bump goes ahead");
    let shown = String::from_utf8_lossy(&t.report.captured()).into_owned();
    assert!(shown.contains("7.4.0-1.cachyos1.fc45.src is a new major: waiting for owner; the pinned 7.3 reaches its EOL in 9d"), "{shown}");
}

const POINT: &str = "point kernel-cachyos-0:7.3.1-1.cachyos1.fc45.src\n";
const POINT_BRANCH: &str = "kernel-bump/kernel-cachyos-7.3.1-1.cachyos1.fc45";

#[test]
fn a_point_bump_carries_its_report() {
    let t = PairTest::new();
    t.fake.configs.borrow_mut().insert(
        "7.3.1-1".into(),
        "CONFIG_A=y\n# CONFIG_B is not set\n".into(),
    );
    *t.fake.bump.borrow_mut() = POINT.into();
    t.run(T0, |vm| vm.kernel_bump().unwrap());
    let message = git(
        t.recipes.path(),
        &["log", "-1", "--format=%B", POINT_BRANCH],
    );
    for line in [
        "Bump report: kernel-cachyos-7.3.0-4.cachyos1.fc45 -> kernel-cachyos-7.3.1-1.cachyos1.fc45",
        &format!("- tag cachyos-7.3.1-1: git verify-tag gives VALIDSIG for {TAG_FPR} alone"),
        "- Source0 cachyos-7.3.1-1.tar.gz: byte-identical to the tag's git archive",
        "- BORE patch: byte-identical",
        "- config: 1 new, 0 changed, 0 removed",
        "  + CONFIG_B=n",
        "- NVIDIA kmod patches: the kmod SRPM is not mirrored yet",
    ] {
        assert!(message.contains(line), "no '{line}' in:\n{message}");
    }
    let shown = String::from_utf8_lossy(&t.report.captured()).into_owned();
    assert!(
        shown.contains("### kernel-bump: kernel-cachyos-7.3.1-1.cachyos1.fc45"),
        "{shown}"
    );
    assert!(
        t.store
            .path()
            .join("mirror/kernel-cachyos-7.3.0-4.cachyos1.fc45.src.rpm")
            .is_file(),
        "the pinned SRPM is mirrored for the diff"
    );
}

#[test]
fn a_config_change_beyond_new_symbols_holds_the_bump() {
    let t = PairTest::new();
    t.with_good_pair();
    t.fake
        .configs
        .borrow_mut()
        .insert("7.3.1-1".into(), "CONFIG_A=m\n".into());
    *t.fake.bump.borrow_mut() = POINT.into();
    t.run(T0, |vm| vm.kernel_bump().unwrap());
    assert_eq!(
        git(t.recipes.path(), &["branch", "--list", "kernel-bump/*"]),
        "",
        "no bump branch"
    );
    let shown = String::from_utf8_lossy(&t.report.captured()).into_owned();
    for line in [
        "  ~ CONFIG_A: y -> m",
        "- NVIDIA kmod patches: anatase-1.patch anatase-2.patch",
        "Held: the config changes beyond new symbols",
        "held: the config changes beyond new symbols; the owner reads the report",
    ] {
        assert!(shown.contains(line), "no '{line}' in:\n{shown}");
    }
}

#[test]
fn a_tag_or_source0_that_does_not_verify_stops_the_bump() {
    let t = PairTest::new();
    *t.fake.bump.borrow_mut() = POINT.into();
    *t.fake.tag_signer.borrow_mut() = COPR_FPR.into();
    let err = t.run(T0, |vm| vm.kernel_bump().unwrap_err().to_string());
    assert!(
        err.contains(&format!(
            "the CachyOS tag cachyos-7.3.1-1 has no good signature by {TAG_FPR}"
        )),
        "{err}"
    );
    *t.fake.tag_signer.borrow_mut() = TAG_FPR.into();
    t.fake.archive_matches.set(false);
    let err = t.run(T0, |vm| vm.kernel_bump().unwrap_err().to_string());
    assert!(
        err.contains("cachyos-7.3.1-1.tar.gz is not the CachyOS tag cachyos-7.3.1-1's git archive"),
        "{err}"
    );
    assert_eq!(
        git(t.recipes.path(), &["branch", "--list", "kernel-bump/*"]),
        ""
    );
}

fn with_key_expiry(t: &PairTest, date: &str) {
    let k = t.recipes.path().join("packaging/pkgs/kernel/kernel.env");
    let mut text = std::fs::read_to_string(&k).unwrap();
    let _ = writeln!(text, "copr_key_expires={date}");
    write(&k, text);
    commit_all(t.recipes.path());
}

#[test]
fn a_pinned_key_inside_14_days_is_in_the_build_summary() {
    let t = PairTest::new();
    with_key_expiry(&t, "2026-12-10");
    t.fake.on_job(good_job);
    assert!(matches!(t.build(T0), Built::Built(_)));
    let shown = String::from_utf8_lossy(&t.report.captured()).into_owned();
    let line =
        format!("the COPR key {COPR_FPR} expires on 2026-12-10, in 9 days: pin its successor now");
    assert!(
        shown.contains(&format!("### A pinned key expires soon\n\n{line}\n")),
        "{shown}"
    );
}

#[test]
fn a_pinned_key_that_expires_soon_warns_and_an_expired_one_holds() {
    let t = PairTest::new();
    with_key_expiry(&t, "2027-01-15");
    let Built::Built(good) = ({
        t.fake.on_job(good_job);
        t.build(T0)
    }) else {
        panic!("not built")
    };
    assert!(
        String::from_utf8_lossy(&t.report.captured()).contains(&format!(
            "the COPR key {COPR_FPR} expires on 2027-01-15, in 45 days"
        ))
    );
    t.promote();
    let k = t.recipes.path().join("packaging/pkgs/kernel/kernel.env");
    let text = std::fs::read_to_string(&k)
        .unwrap()
        .replace("2027-01-15", "2026-11-30");
    write(&k, text);
    commit_all(t.recipes.path());
    let (curls, podmans) = (t.fake.calls(Program::Curl), t.fake.calls(Program::Podman));
    t.fake.on_job(good_job);
    assert_eq!(t.build(T0), Built::Held);
    assert!(t.family_line().starts_with(&format!(
        "family kernel-cachyos held {good} since={T0} side=kernel reason=the COPR key {COPR_FPR} expired on 2026-11-30"
    )), "{}", t.family_line());
    assert_eq!(
        (t.fake.calls(Program::Curl), t.fake.calls(Program::Podman)),
        (curls, podmans),
        "nothing is downloaded or built with an expired key"
    );
}

#[test]
fn a_pair_whose_module_count_moves_more_than_5_percent_is_held() {
    let t = PairTest::new();
    let good = t.with_good_pair();
    t.pins("7.3.1-1", "615.78.08-1");
    t.fake.modules.borrow_mut().insert("7.3.1-1".into(), 949);
    t.fake.on_job(good_job);
    assert_eq!(t.build(T0), Built::Held);
    assert_eq!(
        t.family_line(),
        format!(
            "family kernel-cachyos held {good} since={T0} limit=2026-12-04T00:00:00Z newer=kernel-cachyos-0:7.3.1-1.cachyos1.fc45.src security=1 side=kernel reason=check: the pair has 949 modules, the last good pair {good} 1000: more than 5 % apart"
        )
    );
    let stored = std::fs::read_dir(t.store.path().join("pkgs/kernel"))
        .unwrap()
        .count();
    assert_eq!(
        stored, 2,
        "the good pair and last-failure.txt; nothing new is stored"
    );
    t.fake.modules.borrow_mut().insert("7.3.1-1".into(), 960);
    let Built::Built(key) = t.build("2026-12-01T01:00:00Z") else {
        panic!("not built")
    };
    assert_eq!(
        t.family_line(),
        format!("family kernel-cachyos built {key}")
    );
    assert!(
        String::from_utf8_lossy(&t.report.captured()).contains(&format!(
            "modules: 960 in the pair, 1000 in the last good pair {good}"
        ))
    );
}

#[test]
fn a_bump_without_the_tag_pins_says_which_is_missing() {
    let t = PairTest::new();
    let k = t.recipes.path().join("packaging/pkgs/kernel/kernel.env");
    let text = std::fs::read_to_string(&k).unwrap();
    let without = text.replace("tag_repo=https://github.com/CachyOS/linux.git\n", "");
    assert_ne!(without, text);
    write(&k, without);
    commit_all(t.recipes.path());
    *t.fake.bump.borrow_mut() = POINT.into();
    let err = t.run(T0, |vm| vm.kernel_bump().unwrap_err().to_string());
    assert!(
        err.contains("kernel.env pins no tag_repo, so kernel-bump cannot verify the CachyOS tag"),
        "{err}"
    );
}
