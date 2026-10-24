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
use apex_lane::core::pins::{self, KernelPins, Nevra, NvidiaPins};
use apex_lane::core::utc::UtcSecond;
use apex_lane::error::{Exit, Result};
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
    apex_release: u32,
    fault: Option<String>,
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
    /// source-check.sh's exit and stderr; 0 by default.
    source_check: RefCell<(i32, String)>,
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

/// pair.sh's own check: exit 2 without a positive `APEX_RELEASE`.
fn apex_release_of(args: &[String]) -> u32 {
    let value = args
        .windows(2)
        .find_map(|w| {
            (w[0] == "-e")
                .then(|| w[1].strip_prefix("APEX_RELEASE="))
                .flatten()
        })
        .expect("podman run without -e APEX_RELEASE=N");
    value
        .parse()
        .ok()
        .filter(|&n| n > 0)
        .expect("APEX_RELEASE is no positive integer")
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
            source_check: RefCell::new((0, "ok SHA256SUMS lists and matches every file\n".into())),
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

    fn source_check_sh(&self, cmd: &Cmd) -> Option<Outcome> {
        let args = argv(cmd);
        (cmd.program == Program::Bash && args[0].ends_with("/source-check.sh")).then(|| {
            let (code, stderr) = self.source_check.borrow().clone();
            Outcome {
                code,
                stdout: Vec::new(),
                stderr: stderr.into_bytes(),
            }
        })
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
                        apex_release: apex_release_of(&args),
                        fault: args.windows(2).find_map(|w| {
                            (w[0] == "-e")
                                .then(|| w[1].strip_prefix("APEX_PAIR_FAULT="))
                                .flatten()
                                .map(str::to_owned)
                        }),
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
        if let Some(out) = self
            .report_tools(cmd)
            .or_else(|| self.source_check_sh(cmd))
            .or_else(|| self.script(cmd))
        {
            return Ok(out);
        }
        match cmd.program {
            Program::Git | Program::Cp | Program::Tar => self.real.run(cmd),
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
    let release = kernel
        .srpm
        .release
        .replace(".fc45", &format!(".apex{}.fc45", dirs.apex_release));
    let uname = format!("{}-{release}.x86_64", kernel.srpm.version);
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
    for name in ["vmlinux", "System.map", "config", "kernel.log"] {
        write(&dirs.out.join("debug").join(name), name);
    }
    write_source(dirs, &kernel, &nvidia, with_kmod);
}

/// pair.sh's public source set: both pinned SRPMs, even after a kmod failure.
fn write_source(dirs: &JobDirs, kernel: &KernelPins, nvidia: &NvidiaPins, with_kmod: bool) {
    let src = dirs.out.join("source");
    for nevra in [&kernel.srpm, &nvidia.kmod_srpm] {
        let file = nevra.file_name();
        std::fs::create_dir_all(src.join("srpms")).unwrap();
        std::fs::copy(dirs.mirror.join(&file), src.join("srpms").join(&file)).unwrap();
    }
    for name in ["kernel.env", "nvidia.env", "series", "kernel-spec.patch"] {
        let from = dirs.job.join(name);
        let text = std::fs::read(&from).unwrap_or_else(|_| name.as_bytes().to_vec());
        write(&src.join("recipe").join(name), text);
    }
    write(
        &src.join("licenses/kernel-COPYING"),
        "GPL-2.0 WITH Linux-syscall-note",
    );
    write(&src.join("licenses/GPL-2.0"), "GPL-2.0");
    let kmod = if with_kmod {
        nvidia.kmod_srpm.to_string()
    } else {
        "none: the kmod did not build".into()
    };
    write(
        &src.join("README.source"),
        format!("kernel={}\nkmod={kmod}\n", kernel.srpm),
    );
    write(&src.join("SHA256SUMS"), "sums\n");
}

/// pair.sh with its hook: `APEX_PAIR_FAULT=kmod` takes the kmod-failure path.
fn pair_sh(dirs: &JobDirs) -> (i32, String) {
    match dirs.fault.as_deref() {
        None => good_job(dirs),
        Some("kmod") => {
            let nvidia =
                pins::parse_nvidia("n", &std::fs::read(dirs.job.join("nvidia.env")).unwrap())
                    .unwrap();
            write_pair(dirs, false);
            (
                1,
                format!(
                    "kmod: {} does not build for this kernel\n",
                    nvidia.kmod_srpm
                ),
            )
        }
        Some(other) => (
            2,
            format!("APEX_PAIR_FAULT is kmod or empty, not '{other}'\n"),
        ),
    }
}

fn failing(reason: &'static str, keep_kernel: bool) -> impl Fn(&JobDirs) -> (i32, String) {
    move |dirs| {
        if keep_kernel {
            write_pair(dirs, false);
        } else {
            write(&dirs.out.join("debug/kernel.log"), "the kernel's build log");
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
    pair_fault: RefCell<Option<String>>,
    rehearsal: Cell<bool>,
    fedora: RefCell<String>,
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
        write(&k.join("source-check.sh"), "#!/bin/bash\n");
        init_repo(recipes.path());
        let t = Self {
            _serial: serial,
            root,
            recipes,
            store: tempfile::tempdir().unwrap(),
            report: Reporter::capturing(),
            fake: Fake::new(),
            released: Cell::new(None),
            pair_fault: RefCell::default(),
            rehearsal: Cell::new(false),
            fedora: RefCell::new("45".into()),
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
                fedora: self.fedora.borrow().clone(),
                ga_override: None,
                keep_work: false,
                signing_env: self.store.path().join("rpm-signing.env"),
                exe: PathBuf::from("/opt/apex-lane"),
                uid: 1000,
                gid: 1000,
                is_root: false,
                pair_fault: self.pair_fault.borrow().clone(),
                rehearsal: self.rehearsal.get(),
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
            "kmod-nvidia-7.3.0-4.cachyos1.apex1.fc45.x86_64",
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
    let file = "kmod-nvidia-7.3.0-4.cachyos1.apex1.fc45.x86_64-615.78.08-1.fc45.x86_64.rpm";
    let signed = sha256_hex(format!("{file} +signature").as_bytes());
    assert_eq!(
        *kmod,
        format!(
            "rpm kernel-cachyos built kmod-nvidia-7.3.0-4.cachyos1.apex1.fc45.x86_64 kmod-nvidia-7.3.0-4.cachyos1.apex1.fc45.x86_64-3:615.78.08-1.fc45.x86_64 {signed} pkgs/kernel/{key}/{file}"
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
        "debug/vmlinux",
        "debug/System.map",
        "debug/config",
        "debug/kernel.log",
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
            .contains("kmod-nvidia-7.3.1-1.cachyos1.apex1.fc45.x86_64-3:615.78.08-1")
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
            .contains("kmod-nvidia-7.3.1-1.cachyos1.apex2.fc45.x86_64-3:615.80.01-1")
    );
    assert!(
        t.next_lock()
            .contains(" nvidia-kmod-common-3:615.80.01-1.fc45.noarch ")
    );
}

#[test]
fn a_vmlinux_without_btf_holds_on_the_kernel_side() {
    let t = PairTest::new();
    let good = t.with_good_pair();
    t.pins("7.3.1-1", "615.78.08-1");
    t.fake
        .on_job(failing("kernel: vmlinux has no .BTF section", false));
    assert_eq!(t.build(T0), Built::Held);
    assert!(
        t.family_line()
            .starts_with(&format!("family kernel-cachyos held {good} "))
            && t.family_line()
                .ends_with(" side=kernel reason=kernel: vmlinux has no .BTF section"),
        "{}",
        t.family_line()
    );
}

#[test]
fn the_apex_release_counts_rebuilds_of_one_nevr_and_never_moves_for_one_key() {
    let t = PairTest::new();
    t.with_good_pair();
    t.pins("7.3.1-1", "615.78.08-1");
    t.fake.on_job(failing("kernel: rpmbuild -bb failed", false));
    assert_eq!(t.build(T0), Built::Held);
    t.fake.on_job(good_job);
    let Built::Built(key) = t.build(T0) else {
        panic!("not built")
    };
    assert!(
        t.next_lock()
            .contains(" kernel-cachyos-0:7.3.1-1.cachyos1.apex1.fc45.x86_64 "),
        "the held run took N=1 for this key, and the rerun keeps it"
    );
    let releases: Vec<String> = t
        .fake
        .log
        .borrow()
        .iter()
        .map(argv)
        .filter(|a| a.first().is_some_and(|a| a == "/usr/bin/podman"))
        .filter_map(|a| a.into_iter().find(|a| a.starts_with("APEX_RELEASE=")))
        .collect();
    assert_eq!(releases, ["APEX_RELEASE=1"; 3]);
    let ledger =
        std::fs::read_to_string(t.store.path().join("pkgs/kernel/apex-release.txt")).unwrap();
    let lines: Vec<&str> = ledger.lines().collect();
    assert_eq!(lines.len(), 2, "{ledger}");
    assert_eq!(
        lines[1],
        format!("kernel-cachyos-7.3.1-1.cachyos1.fc45 {key} 1")
    );
    std::fs::write(
        t.store.path().join("pkgs/kernel/apex-release.txt"),
        format!("{ledger}kernel-cachyos-7.3.1-1.cachyos1.fc45 an-older-pruned-key 4\n"),
    )
    .unwrap();
    t.promote();
    t.pins("7.3.1-1", "615.80.01-1");
    assert!(matches!(t.build(T0), Built::Built(_)));
    assert!(
        t.next_lock()
            .contains(" kernel-cachyos-0:7.3.1-1.cachyos1.apex5.fc45.x86_64 "),
        "a new key of the same NEVR takes one past the ledger's highest"
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
    assert_eq!(
        std::fs::read_to_string(t.store.path().join("pkgs/kernel/last-failure-kernel.log"))
            .unwrap(),
        "the kernel's build log"
    );
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
fn a_rehearsal_injects_the_kmod_failure_through_pair_sh_and_reaches_degraded() {
    let t = PairTest::new();
    let good = t.with_good_pair();
    t.fake.on_job(pair_sh);
    t.pins("7.3.1-1", "615.78.08-1");
    t.rehearsal.set(true);
    assert!(
        matches!(t.build(T0), Built::Built(_)),
        "the bump as a whole pair"
    );
    *t.pair_fault.borrow_mut() = Some("kmod".into());
    assert_eq!(
        t.build(T0),
        Built::Held,
        "the fault is an input of the key, so the stored whole pair is not taken"
    );
    assert!(
        t.family_line().starts_with(&format!("family kernel-cachyos held {good} since={T0} limit=2026-12-04T00:00:00Z "))
            && t.family_line().ends_with(" side=kmod reason=kmod: nvidia-kmod-3:615.78.08-1.fc45.src does not build for this kernel"),
        "{}",
        t.family_line()
    );
    assert_eq!(t.build("2026-12-04T00:00:01Z"), Built::Degraded);
    assert!(t.family_line().contains(" degraded=nvidia side=kmod "));
    let faults = t
        .fake
        .log
        .borrow()
        .iter()
        .map(argv)
        .filter(|a| a.first().is_some_and(|a| a == "/usr/bin/podman"))
        .map(|a| {
            a.iter()
                .filter(|a| a.starts_with("APEX_PAIR_FAULT="))
                .count()
        })
        .collect::<Vec<_>>();
    assert_eq!(
        faults,
        [0, 0, 1, 1],
        "only the rehearsal's jobs carry the hook"
    );
    assert!(
        t.next_lock()
            .contains(" kernel-cachyos-0:7.3.1-1.cachyos1.apex9002.fc45.x86_64 "),
        "a rehearsal's N starts at 9001, and the faulted key takes the next"
    );
}

#[test]
fn the_lanes_store_refuses_a_rehearsal_n_and_a_rehearsal_refuses_a_real_one() {
    let t = PairTest::new();
    let good = t.with_good_pair();
    let ledger = t.store.path().join("pkgs/kernel/apex-release.txt");
    t.pins("7.3.1-1", "615.78.08-1");
    std::fs::write(
        &ledger,
        format!(
            "{}kernel-cachyos-7.3.1-1.cachyos1.fc45 a-rehearsals-key 9001\n",
            std::fs::read_to_string(&ledger).unwrap()
        ),
    )
    .unwrap();
    let err = t.run(T0, |vm| vm.build("kernel").unwrap_err().to_string());
    assert!(
        err.contains("N=9002 is a rehearsal's (from 9000) in the lane's own store"),
        "{err}"
    );
    t.rehearsal.set(true);
    t.pins("7.3.0-4", "615.78.08-1");
    let err = t.run(T0, |vm| vm.build("kernel").unwrap_err().to_string());
    assert!(
        err.contains("N=1 is below 9000 in a rehearsal, where it could meet a real build"),
        "{err}"
    );
    assert!(t.family_line().contains(&good));
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
            "kernel-cachyos-0:7.3.1-1.cachyos1.apex1.fc45.x86_64",
            "kernel-cachyos-core-0:7.3.1-1.cachyos1.apex1.fc45.x86_64",
            "kernel-cachyos-modules-0:7.3.1-1.cachyos1.apex1.fc45.x86_64"
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
    *t.fake.bump.borrow_mut() = "point kernel-cachyos-0:7.3.1-1.cachyos1.fc45.src\nnvidia nvidia-kmod-3:615.80.01-1.fc45.src abc newer\nnvidia nvidia-driver-3:615.80.01-1.fc45.x86_64 abc newer soaking-3d\nnvidia nvidia-settings-3:615.80.01-1.fc45.x86_64 abc newer soaked\n".into();
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
    for line in [
        "nvidia-kmod-3:615.80.01-1.fc45.src is newer than the pins (not yet known to be soaked); a new driver waits for the owner",
        "nvidia-driver-3:615.80.01-1.fc45.x86_64 is newer than the pins (soaking, 3d to go)",
        "nvidia-settings-3:615.80.01-1.fc45.x86_64 is newer than the pins (soaked, ready for a driver bump)",
    ] {
        assert!(shown.contains(line), "{line}: {shown}");
    }
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
fn the_store_keeps_the_last_4_pairs_debug_files_and_prunes_what_no_lock_names() {
    let t = PairTest::new();
    let mut keys = Vec::new();
    for n in 0..6 {
        if n > 0 {
            let notes = t.recipes.path().join("packaging/pkgs/kernel/notes.txt");
            write(&notes, format!("{n}\n"));
            commit_all(t.recipes.path());
        }
        t.fake.on_job(good_job);
        let Built::Built(key) = t.build(T0) else {
            panic!("not built")
        };
        keys.push(key);
        if n == 0 {
            t.promote();
        }
    }
    let store = t.store.path().join("pkgs/kernel");
    for key in &keys[2..] {
        assert!(
            store.join(key).join("debug/vmlinux").is_file(),
            "{key} keeps its debug files"
        );
    }
    assert!(!store.join(&keys[1]).exists(), "no lock names {}", keys[1]);
    let promoted = store.join(&keys[0]);
    assert!(
        promoted.join("manifest.txt").is_file() && !promoted.join("debug").exists(),
        "rpms.lock names {}: its RPMs stay, its debug files go",
        keys[0]
    );
    image_sh_accepts(&t.store.path().join("rpms.lock"));
    image_sh_accepts(&t.store.path().join("rpms.lock.next"));
}

#[test]
fn a_pair_without_its_vmlinux_breaks_the_contract() {
    let t = PairTest::new();
    t.fake.on_job(|dirs| {
        let done = good_job(dirs);
        std::fs::remove_file(dirs.out.join("debug/vmlinux")).unwrap();
        done
    });
    let err = t.run(T0, |vm| vm.build("kernel").unwrap_err().to_string());
    assert!(
        err.contains("pair.sh wrote pair.lock without debug/vmlinux"),
        "{err}"
    );
    assert!(!t.store.path().join("rpms.lock.next").exists());
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
    let mut stored: Vec<String> = std::fs::read_dir(t.store.path().join("pkgs/kernel"))
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    stored.sort();
    assert_eq!(
        stored,
        [
            "apex-release.txt",
            good.as_str(),
            "last-failure-kernel.log",
            "last-failure.txt"
        ],
        "the good pair and the failure's reason and kernel log; nothing new is stored"
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

fn layer_listing(out: &Path) -> Vec<String> {
    let index: serde_json::Value =
        serde_json::from_slice(&std::fs::read(out.join("index.json")).unwrap()).unwrap();
    let blob = |digest: &str| {
        out.join("blobs/sha256")
            .join(digest.strip_prefix("sha256:").unwrap())
    };
    let manifest: serde_json::Value = serde_json::from_slice(
        &std::fs::read(blob(index["manifests"][0]["digest"].as_str().unwrap())).unwrap(),
    )
    .unwrap();
    let layer = blob(manifest["layers"][0]["digest"].as_str().unwrap());
    let listed = std::process::Command::new("tar")
        .arg("-tf")
        .arg(&layer)
        .output()
        .unwrap();
    let mut names: Vec<String> = String::from_utf8(listed.stdout)
        .unwrap()
        .lines()
        .filter(|l| !l.ends_with('/'))
        .map(|l| l.trim_start_matches("./").to_owned())
        .collect();
    names.sort();
    names
}

/// Every file of the stored source set, relative to it, as the layer should hold it.
fn set_listing(t: &PairTest, key: &str) -> Vec<String> {
    let set = t.store.path().join("pkgs/kernel").join(key).join("source");
    let mut names: Vec<String> = walk(&set)
        .into_iter()
        .map(|p| p.strip_prefix(&set).unwrap().display().to_string())
        .collect();
    names.sort();
    names
}

fn walk(dir: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    for e in std::fs::read_dir(dir).unwrap() {
        let p = e.unwrap().path();
        if p.is_dir() {
            out.extend(walk(&p));
        } else {
            out.push(p);
        }
    }
    out
}

fn source_checks(t: &PairTest) -> Vec<Vec<String>> {
    t.fake
        .log
        .borrow()
        .iter()
        .filter(|c| c.program == Program::Bash && argv(c)[0].ends_with("/source-check.sh"))
        .map(argv)
        .collect()
}

#[test]
fn the_source_artifact_wraps_pair_shs_set_as_it_is() {
    let t = PairTest::new();
    let key = t.with_good_pair();
    let out = t.store.path().join("sources");
    let lock = t.store.path().join("rpms.lock");
    assert_eq!(t.run(T0, |vm| vm.sources(&lock, &out).unwrap()), Exit::Ok);
    assert_eq!(
        std::fs::read_to_string(out.join("oci-layout")).unwrap(),
        r#"{"imageLayoutVersion":"1.0.0"}"#
    );
    let names = layer_listing(&out);
    assert_eq!(
        names,
        set_listing(&t, &key),
        "the layer is the stored set, nothing added"
    );
    for file in [
        "SHA256SUMS",
        "README.source",
        "licenses/kernel-COPYING",
        "srpms/kernel-cachyos-7.3.0-4.cachyos1.fc45.src.rpm",
        "srpms/nvidia-kmod-615.78.08-1.fc45.src.rpm",
        "recipe/kernel.env",
        "recipe/nvidia.env",
    ] {
        assert!(names.iter().any(|n| n == file), "no {file} in {names:?}");
    }
    assert!(
        !names.iter().any(|n| n == "recipe/pair.sh"),
        "no reassembled recipe: {names:?}"
    );
    let set = t.store.path().join("pkgs/kernel").join(&key).join("source");
    let checks = source_checks(&t);
    assert_eq!(checks.len(), 1, "{checks:?}");
    assert!(
        checks[0][0].ends_with("packaging/pkgs/kernel/source-check.sh"),
        "{checks:?}"
    );
    assert_eq!(checks[0][1], set.display().to_string());
    let index = std::fs::read_to_string(out.join("index.json")).unwrap();
    assert!(index.contains(&key), "{index}");
    t.run(T0, |vm| vm.sources(&lock, &out).unwrap());
    assert_eq!(
        std::fs::read_to_string(out.join("index.json")).unwrap(),
        index,
        "the same pair gives the same digest"
    );
}

#[test]
fn a_kernel_only_set_is_wrapped_as_pair_sh_wrote_it_and_no_pair_has_no_artifact() {
    let t = PairTest::new();
    t.with_good_pair();
    t.pins("7.3.1-1", "615.78.08-1");
    t.fake.on_job(failing("kmod: it does not build", true));
    assert_eq!(t.build(T0), Built::Held);
    assert_eq!(t.build("2026-12-04T00:00:00Z"), Built::Degraded);
    let out = t.store.path().join("sources");
    let next = t.store.path().join("rpms.lock.next");
    t.run(T0, |vm| vm.sources(&next, &out).unwrap());
    let names = layer_listing(&out);
    let srpms: Vec<&String> = names.iter().filter(|n| n.starts_with("srpms/")).collect();
    assert_eq!(
        srpms,
        [
            "srpms/kernel-cachyos-7.3.1-1.cachyos1.fc45.src.rpm",
            "srpms/nvidia-kmod-615.78.08-1.fc45.src.rpm"
        ],
        "pair.sh keeps both pinned SRPMs after a kmod failure"
    );
    assert!(names.iter().any(|n| n == "README.source"));

    let none = t.store.path().join("no-pair.lock");
    write(
        &none,
        "# apex rpms.lock 1: written by apex-lane\nfamily gnome-shell stock\n",
    );
    let empty = t.store.path().join("none");
    assert_eq!(t.run(T0, |vm| vm.sources(&none, &empty).unwrap()), Exit::Ok);
    assert!(!empty.exists());
    assert!(
        String::from_utf8_lossy(&t.report.captured())
            .contains("no kernel pair, so no source artifact")
    );
}

#[test]
fn a_pair_stored_before_the_source_set_is_named() {
    let t = PairTest::new();
    let key = t.with_good_pair();
    std::fs::remove_dir_all(t.store.path().join("pkgs/kernel").join(&key).join("source")).unwrap();
    let lock = t.store.path().join("rpms.lock");
    let out = t.store.path().join("sources");
    let err = t.run(T0, |vm| vm.sources(&lock, &out).unwrap_err().to_string());
    assert!(
        err.contains("the pair predates pair.sh's source set; build it again"),
        "{err}"
    );
    assert!(source_checks(&t).is_empty());
}

#[test]
fn a_set_that_fails_source_check_is_refused() {
    let t = PairTest::new();
    t.with_good_pair();
    let lock = t.store.path().join("rpms.lock");
    let out = t.store.path().join("sources");
    *t.fake.source_check.borrow_mut() = (
        1,
        "ok recipe/ holds the series and pins\nnot ok: srpms/nvidia-kmod-615.78.08-1.fc45.src.rpm does not have its pinned sha256\n".into(),
    );
    let err = t.run(T0, |vm| vm.sources(&lock, &out).unwrap_err().to_string());
    assert!(
        err.contains("source-check.sh refused")
            && err.contains("not ok: srpms/nvidia-kmod-615.78.08-1.fc45.src.rpm does not have its pinned sha256; no source artifact"),
        "{err}"
    );
    assert!(!out.exists(), "nothing is wrapped");
    assert!(!out.with_extension("partial").exists());

    *t.fake.source_check.borrow_mut() = (2, "source-check.sh cannot run: no sha256sum\n".into());
    let err = t.run(T0, |vm| vm.sources(&lock, &out).unwrap_err().to_string());
    assert!(
        err.contains(
            "source-check.sh could not run (exit 2): source-check.sh cannot run: no sha256sum"
        ),
        "{err}"
    );
    assert!(!out.exists());
}

#[test]
fn a_pin_without_source_check_sh_is_named() {
    let t = PairTest::new();
    t.with_good_pair();
    std::fs::remove_file(
        t.recipes
            .path()
            .join("packaging/pkgs/kernel/source-check.sh"),
    )
    .unwrap();
    let lock = t.store.path().join("rpms.lock");
    let out = t.store.path().join("sources");
    let err = t.run(T0, |vm| vm.sources(&lock, &out).unwrap_err().to_string());
    assert!(
        err.contains("source-check.sh is missing: the pinned apex-kernel predates the source set"),
        "{err}"
    );
    assert!(!out.exists());
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

/// The podman runs of pair.sh, as argv.
fn pair_jobs(t: &PairTest) -> Vec<Vec<String>> {
    t.fake
        .log
        .borrow()
        .iter()
        .map(argv)
        .filter(|a| a.first().is_some_and(|a| a == "/usr/bin/podman"))
        .collect()
}

const NEXT_BASE: &str = concat!(
    "registry.fedoraproject.org/fedora@sha256:",
    "4646464646464646464646464646464646464646464646464646464646464646"
);

#[test]
fn a_45_pair_job_is_as_before_and_a_next_one_names_its_fedora_and_base() {
    let t = PairTest::new();
    t.with_good_pair();
    let jobs = pair_jobs(&t);
    assert!(!jobs.is_empty());
    for job in &jobs {
        assert!(!job.iter().any(|a| a.starts_with("FEDORA=")), "{job:?}");
        assert!(job.iter().any(|a| a.ends_with(
            "@sha256:1e13e11f63e147a40a935c9046c79d53a30b861a3cf05ebb023bb53c562382cb"
        )));
    }
    drop(t);

    let t = PairTest::new();
    write(
        &t.root.path().join("image/fedora/46.env"),
        format!("FEDORA=46\nLANE=next\nREPOS_BASE={NEXT_BASE}\nGA_REACHED=1\n"),
    );
    *t.fedora.borrow_mut() = "46".into();
    t.fake.on_job(good_job);
    assert!(matches!(t.build(T0), Built::Built(_)));
    let jobs = pair_jobs(&t);
    assert!(!jobs.is_empty());
    for job in &jobs {
        let fedora = job.windows(2).any(|w| w[0] == "-e" && w[1] == "FEDORA=46");
        assert!(fedora && job.iter().any(|a| a == NEXT_BASE), "{job:?}");
    }
}

#[test]
fn a_next_release_without_its_env_file_is_named() {
    let t = PairTest::new();
    *t.fedora.borrow_mut() = "46".into();
    t.fake.on_job(good_job);
    let err = t.run(T0, |vm| vm.repos_base().unwrap_err().to_string());
    assert!(
        err.contains("APEX_FEDORA=46 has no") && err.contains("image/fedora/46.env"),
        "{err}"
    );
}

#[test]
fn the_next_lane_never_promotes() {
    let t = PairTest::new();
    t.with_good_pair();
    let locked = std::fs::read(t.store.path().join("rpms.lock")).unwrap();
    *t.fedora.borrow_mut() = "46".into();
    let err = t.run(T0, |vm| vm.promote(true).unwrap_err().to_string());
    assert!(
        err.contains("APEX_FEDORA=46 is the next lane: it never promotes"),
        "{err}"
    );
    assert_eq!(
        std::fs::read(t.store.path().join("rpms.lock")).unwrap(),
        locked
    );
}
