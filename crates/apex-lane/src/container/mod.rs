//! The Fedora half, as root in a fresh `REPOS_BASE` container.

mod build;
mod prep;

pub use build::stored_builds;

use std::path::{Path, PathBuf};
use std::time::Duration;

use crate::core::checksig::checksig_ok;
use crate::core::failed::{self, Failure};
use crate::core::key::{self, KeyInputs};
use crate::core::repos::{self, Repos, SETOPTS};
use crate::core::rpmout;
use crate::core::text;
use crate::error::{LaneError, Result, infra, usage};
use crate::pkg::{self, Parse, Pkg};
use crate::shell::cmd::{Cmd, Outcome, Program, Runner, Stderr, Stdout, retry};
use crate::shell::fs;
use crate::shell::report::Reporter;

/// The container's key file must match it before it is imported. From
/// fedoraproject.org/security and fedora-repos dist-git, 2026-09-24.
pub const FEDORA_45_KEY_FPR: &str = "4F50A6114CD5C6976A7F1179655A4B02F577861E";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ModeKind {
    Build,
    Key,
    Prep,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Args {
    pub mode: ModeKind,
    pub pkg: String,
    pub nvr: Option<String>,
    pub n: u64,
    pub tool: String,
    pub repos_base: String,
    pub ga_reached: u8,
    pub source1: Option<String>,
    pub source1_tree: Option<String>,
    pub locked_evr: Option<String>,
    pub keep_work: bool,
}

#[derive(Debug, Clone)]
pub struct Paths {
    pub src: PathBuf,
    pub recipes: PathBuf,
    pub work: PathBuf,
    pub store: PathBuf,
    pub fedora_keys: PathBuf,
}

impl Default for Paths {
    fn default() -> Self {
        Self {
            src: "/src".into(),
            recipes: "/recipes".into(),
            work: "/work".into(),
            store: "/store".into(),
            fedora_keys: "/usr/share/pki/rpm-gpg".into(),
        }
    }
}

impl Paths {
    fn out(&self) -> PathBuf {
        self.work.join("out")
    }
}

pub struct Container<'a> {
    pub paths: Paths,
    pub args: Args,
    pub runner: &'a dyn Runner,
    pub report: &'a Reporter,
    pub is_root: bool,
}

impl std::fmt::Debug for Container<'_> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Container")
            .field("paths", &self.paths)
            .field("args", &self.args)
            .finish_non_exhaustive()
    }
}

#[derive(Debug, Clone)]
pub struct Setup {
    pub pkg: Pkg,
    pub repos: Repos,
    pub key_id: String,
    pub arch: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Stock {
    pub epoch: String,
    pub version: String,
    pub release: String,
    pub sourcerpm: String,
    pub nvr: String,
    pub pin: Option<Pin>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Pin {
    pub name: String,
    pub nvr: String,
    pub evr: String,
}

#[derive(Debug, Clone, Default)]
pub struct Attempt {
    pub stock: Option<String>,
    pub key: Option<String>,
}

const RETRY_DELAY: Duration = Duration::from_secs(10);

impl Container<'_> {
    pub fn run(&self) -> Result<()> {
        match self.args.mode {
            ModeKind::Build => self.build(),
            ModeKind::Key => {
                let setup = self.setup()?;
                let stock = self.resolve(&setup, None)?;
                let (key, _) = self.key(&setup, &stock)?;
                println!("{key}");
                Ok(())
            }
            ModeKind::Prep => self.prep(),
        }
    }

    fn run_ok(&self, cmd: &Cmd, what: &str) -> Result<Outcome> {
        let out = self.runner.run(cmd)?;
        if !out.ok() {
            return Err(infra(format!("{what} (exit {}): {cmd}", out.code)));
        }
        Ok(out)
    }

    fn rpm_eval(&self, expr: &str) -> Result<String> {
        let out = self.run_ok(
            &Cmd::new(Program::Rpm).arg("-E").arg(expr).capture(),
            "rpm -E failed",
        )?;
        Ok(text::lossy(text::chomp(&out.stdout)))
    }

    fn dnf_bin(repos: &Repos) -> Cmd {
        Cmd::new(Program::Dnf5)
            .args(["-y", "-q"])
            .args(&repos.bin)
            .args(SETOPTS)
    }

    fn fail(&self, attempt: &Attempt, reason: &[u8], log: Option<&Path>) -> LaneError {
        let out = self.paths.out();
        let log_bytes = log.and_then(|p| std::fs::read(p).ok().map(|b| (fs::file_name(p), b)));
        let body = failed::failed_txt(&Failure {
            reason,
            pkg: &self.args.pkg,
            stock: attempt.stock.as_deref(),
            key: attempt.key.as_deref(),
            log: log_bytes.as_ref().map(|(n, b)| (n.as_str(), b.as_slice())),
        });
        if let Err(e) =
            fs::create_dir_all(&out).and_then(|()| fs::write(&out.join("failed.txt"), &body))
        {
            return e;
        }
        self.report
            .log(&format!("FAILED (exit 3): {}", text::lossy(reason)));
        if let Some((_, b)) = &log_bytes {
            self.report.raw(text::tail_lines(b, 30));
        }
        LaneError::NoShippableBuild(text::lossy(reason))
    }

    fn setup(&self) -> Result<Setup> {
        let env_path = pkg::pkgs_dir(&self.paths.recipes)
            .join(&self.args.pkg)
            .join("pkg.env");
        if !env_path.is_file() {
            return Err(usage(format!("no {}", env_path.display())));
        }
        if !self.is_root {
            return Err(usage(
                "in-container runs as root in the REPOS_BASE container",
            ));
        }
        let pkg = pkg::load(&self.paths.recipes, &self.args.pkg, Parse::Full)?;
        if pkg.env.source1.is_some() {
            let staged = self
                .args
                .source1
                .as_deref()
                .filter(|a| !a.is_empty() && !a.contains('/'))
                .is_some_and(|a| self.paths.work.join("in").join(a).is_file());
            if !staged || self.args.source1_tree.as_deref().is_none_or(str::is_empty) {
                return Err(usage("Source1 is not staged in /work/in"));
            }
        }
        self.report.group("Tools and repositories");
        let repos = self.repos()?;
        let tools = self.runner.run(
            &Self::dnf_bin(&repos)
                .args([
                    "install",
                    "rpm-build",
                    "dnf5-plugins",
                    "git-core",
                    "cpio",
                    "diffutils",
                    "/usr/bin/gpg",
                ])
                .capture()
                .stderr(Stderr::ToStdout),
        )?;
        if !tools.ok() {
            self.report.raw(text::tail_lines(&tools.stdout, 30));
            return Err(infra("cannot install the build tools"));
        }
        let key_id = self.import_fedora_key()?;
        self.report.endgroup();
        let arch = self.rpm_eval("%_arch")?;
        Ok(Setup {
            pkg,
            repos,
            key_id,
            arch,
        })
    }

    fn repos(&self) -> Result<Repos> {
        let allow_path = self
            .paths
            .src
            .join("image/packages/updates-testing-allowlist.txt");
        let allow = repos::testing_includepkgs(fs::read_opt(&allow_path)?.as_deref());
        let testing = self.args.ga_reached != 1 && !allow.is_empty();
        // --refresh: the cache volume may be days old. minrate: dnf's default, 1000 B/s,
        // once kept a run on a stalled mirror for 15 minutes.
        let refresh = Cmd::new(Program::Dnf5)
            .args(["-q", "--refresh", "--setopt=minrate=65536"])
            .args(repos::refresh_repos(testing))
            .arg("makecache")
            .stdout(Stdout::Null);
        if !retry(self.runner, self.report, 3, RETRY_DELAY, &refresh)?.ok() {
            return Err(infra("cannot refresh the repository metadata"));
        }
        if !testing {
            return Ok(Repos::released());
        }
        let builds = retry(
            self.runner,
            self.report,
            3,
            RETRY_DELAY,
            &Cmd::new(Program::Dnf5)
                .args(["-q", "--repo=updates-testing"])
                .arg(format!("--setopt=updates-testing.includepkgs={allow}"))
                .args([
                    "repoquery",
                    "--available",
                    "--queryformat",
                    "%{sourcerpm}\\n",
                ])
                .capture(),
        )?;
        if !builds.ok() {
            return Err(infra("cannot query the allowlisted updates-testing builds"));
        }
        let builds = repos::sort_unique(&builds.stdout);
        if text::chomp(&builds).is_empty() {
            return Err(infra(
                "the updates-testing allowlist matches nothing in updates-testing",
            ));
        }
        let all = retry(
            self.runner,
            self.report,
            3,
            RETRY_DELAY,
            &Cmd::new(Program::Dnf5)
                .args([
                    "-q",
                    "--repo=updates-testing",
                    "repoquery",
                    "--available",
                    "--arch=x86_64,noarch",
                ])
                .args([
                    "--queryformat",
                    "%{name}-%{version}-%{release} %{sourcerpm}\\n",
                ])
                .capture(),
        )?;
        if !all.ok() {
            return Err(infra("cannot query updates-testing"));
        }
        let admitted = repos::admitted(text::chomp(&builds), text::chomp(&all.stdout));
        if admitted.is_empty() {
            return Err(infra(
                "no updates-testing package comes from the allowlisted builds",
            ));
        }
        self.report.log(&format!(
            "buildroot admission: {} allowlisted builds give {} packages (runtime allowlist: {})",
            text::lines(text::chomp(&builds)).len(),
            admitted.split(',').count(),
            allow.split(',').count()
        ));
        Ok(Repos::released().with_testing(&admitted))
    }

    fn import_fedora_key(&self) -> Result<String> {
        let fedora = self.rpm_eval("%fedora")?;
        let key_file = self
            .paths
            .fedora_keys
            .join(format!("RPM-GPG-KEY-fedora-{fedora}-primary"));
        if !key_file.is_file() {
            return Err(infra(format!(
                "{} not found in the container",
                key_file.display()
            )));
        }
        let Some(pinned) = crate::core::fedora::key_fpr(&fedora) else {
            return Err(infra(format!(
                "no pinned release key fingerprint for Fedora {fedora}"
            )));
        };
        let home =
            tempfile::tempdir().map_err(|e| infra(format!("cannot create a gpg home: {e}")))?;
        let shown = self.runner.run(
            &Cmd::new(Program::Gpg)
                .arg("--homedir")
                .arg(home.path())
                .args(["--batch", "--quiet", "--show-keys", "--with-colons", "--"])
                .arg(&key_file)
                .capture()
                .stderr(Stderr::Null),
        )?;
        let fpr = rpmout::first_fingerprint(&shown.stdout);
        if !fpr.eq_ignore_ascii_case(pinned) {
            return Err(infra(format!(
                "{} has fingerprint '{fpr}', expected {pinned}",
                key_file.display()
            )));
        }
        self.run_ok(
            &Cmd::new(Program::Rpmkeys).arg("--import").arg(&key_file),
            "rpmkeys --import failed",
        )?;
        Ok(pinned[pinned.len() - 8..].to_owned())
    }

    /// dnf checks a download against the repository metadata only.
    fn verify(&self, setup: &Setup, file: &Path) -> Result<()> {
        let name = fs::file_name(file);
        let checksig = |verbose: bool| {
            let mut cmd = Cmd::new(Program::Rpmkeys).arg("--checksig");
            if verbose {
                cmd = cmd.arg("-v");
            }
            self.runner
                .run(&cmd.arg("--").arg(file).capture().stderr(Stderr::ToStdout))
        };
        let out = checksig(false)?;
        let shown = text::lossy(text::chomp(&out.stdout));
        if !out.ok() {
            return Err(infra(format!("rpmkeys -K {name}: {shown}")));
        }
        if !shown.contains("signatures OK") {
            return Err(infra(format!("{name}: signatures are not OK: {shown}")));
        }
        let verbose = checksig(true)?;
        if !verbose.ok() || !checksig_ok(&verbose.stdout, &setup.key_id) {
            return Err(infra(format!(
                "{name} is not signed by the Fedora key {}: {}",
                setup.key_id,
                text::lossy(text::chomp(&verbose.stdout))
            )));
        }
        Ok(())
    }

    fn resolve(&self, setup: &Setup, want: Option<&str>) -> Result<Stock> {
        let env = &setup.pkg.env;
        let want = want.unwrap_or(&env.srpm);
        let query = self.run_ok(
            &Self::dnf_bin(&setup.repos)
                .args(["repoquery", "--latest-limit=1"])
                .arg(format!("--arch={},noarch", setup.arch))
                .args(["--queryformat", rpmout::STOCK_FORMAT])
                .arg(want)
                .capture(),
            "repoquery failed",
        )?;
        let Some(line) = rpmout::one_line(&query.stdout) else {
            let repos: Vec<&str> = setup
                .repos
                .bin
                .iter()
                .map(|r| r.strip_prefix("--repo=").unwrap_or(r))
                .collect();
            return Err(infra(format!(
                "expected one {want} in: {}; repoquery returned: '{}'",
                repos.join(" "),
                text::lossy(text::chomp(&query.stdout))
            )));
        };
        let r = rpmout::stock_line(line);
        let nvr = format!("{}-{}-{}", env.srpm, r.version, r.release);
        if r.sourcerpm != format!("{nvr}.src.rpm") {
            return Err(infra(format!(
                "{} comes from {}, not {nvr}.src.rpm",
                env.srpm, r.sourcerpm
            )));
        }
        let pin = match &env.pin {
            None => None,
            Some(pin) => Some(self.resolve_pin(setup, pin)?),
        };
        let out = self.paths.out();
        fs::create_dir_all(&out)?;
        let mut attempt = format!("stock {nvr}\n");
        if let Some(p) = &pin {
            attempt = format!("{attempt}pin {}\n", p.nvr);
        }
        fs::write(&out.join("attempt.txt"), attempt.as_bytes())?;
        self.report.log(&format!(
            "stock: {nvr} (epoch {}){}",
            r.epoch,
            pin.as_ref()
                .map(|p| format!("; pin: {}-devel = {}", p.name, p.evr))
                .unwrap_or_default()
        ));
        Ok(Stock {
            epoch: r.epoch,
            version: r.version,
            release: r.release,
            sourcerpm: r.sourcerpm,
            nvr,
            pin,
        })
    }

    fn resolve_pin(&self, setup: &Setup, pin: &str) -> Result<Pin> {
        let query = self.run_ok(
            &Self::dnf_bin(&setup.repos)
                .args(["repoquery", "--latest-limit=1"])
                .arg(format!("--arch={}", setup.arch))
                .args(["--queryformat", rpmout::PIN_FORMAT])
                .arg(format!("{pin}-devel"))
                .capture(),
            "repoquery failed",
        )?;
        let Some(line) = rpmout::one_line(&query.stdout) else {
            return Err(infra(format!(
                "expected one {pin}-devel, got '{}'",
                text::lossy(text::chomp(&query.stdout))
            )));
        };
        let p = rpmout::pin_line(line);
        let nvr = format!("{pin}-{}-{}", p.version, p.release);
        if p.sourcerpm != format!("{nvr}.src.rpm") {
            return Err(infra(format!(
                "{pin}-devel comes from {}, not {nvr}.src.rpm",
                p.sourcerpm
            )));
        }
        let mut evr = format!("{}-{}", p.version, p.release);
        if p.epoch != "0" {
            evr = format!("{}:{evr}", p.epoch);
        }
        Ok(Pin {
            name: pin.to_owned(),
            nvr,
            evr,
        })
    }

    /// The content key and its preimage.
    fn key(&self, setup: &Setup, stock: &Stock) -> Result<(String, String)> {
        let pkg = &setup.pkg;
        let sha = |path: &Path| fs::sha256_file(path);
        let check = pkg.check_sh();
        let inputs = KeyInputs {
            pkg: pkg.name.clone(),
            tool: self.args.tool.clone(),
            check_sh_sha256: if check.is_file() {
                Some(sha(&check)?)
            } else {
                None
            },
            repos: setup.repos.key_text(),
            stock: stock.nvr.clone(),
            pin_evr: stock.pin.as_ref().map(|p| p.evr.clone()),
            pkg_env_sha256: sha(&pkg.dir.join("pkg.env"))?,
            spec_edit_sha256: sha(&pkg.dir.join("spec-edit"))?,
            patches: pkg
                .series
                .iter()
                .map(|p| Ok((p.clone(), sha(&pkg.patch(p))?)))
                .collect::<Result<_>>()?,
            source1_tree: self.args.source1_tree.clone(),
            n: self.args.n,
        };
        let preimage = key::preimage(&inputs);
        Ok((key::content_key(&stock.nvr, &preimage), preimage))
    }

    fn fetch_srpm(&self, setup: &Setup, stock: &Stock, dir: &Path) -> Result<PathBuf> {
        let srpm = &setup.pkg.env.srpm;
        let spec = if stock.epoch == "0" {
            format!("{srpm}-{}-{}.{}", stock.version, stock.release, setup.arch)
        } else {
            format!(
                "{srpm}-{}:{}-{}.{}",
                stock.epoch, stock.version, stock.release, setup.arch
            )
        };
        let download = Cmd::new(Program::Dnf5)
            .args(["-y", "-q"])
            .args(&setup.repos.bin)
            .args(&setup.repos.src)
            .args(SETOPTS)
            .args(["download", "--srpm"])
            .arg(format!("--destdir={}", dir.display()))
            .arg(spec)
            .stdout(Stdout::Null);
        if !retry(self.runner, self.report, 3, RETRY_DELAY, &download)?.ok() {
            return Err(infra(format!("cannot download {}", stock.sourcerpm)));
        }
        let path = dir.join(&stock.sourcerpm);
        if !path.is_file() {
            return Err(infra(format!("dnf did not download {}", stock.sourcerpm)));
        }
        self.verify(setup, &path)?;
        self.report.log(&format!(
            "{}: signed by the Fedora key {}",
            stock.sourcerpm, setup.key_id
        ));
        Ok(path)
    }

    fn unpack(&self, srpm: &Path, top: &Path) -> Result<PathBuf> {
        for d in ["BUILD", "RPMS", "SOURCES", "SPECS", "SRPMS"] {
            fs::create_dir_all(&top.join(d))?;
        }
        let sources = top.join("SOURCES");
        let (a, b) = self.runner.pipe(
            &Cmd::new(Program::Rpm2cpio).arg(srpm),
            &Cmd::new(Program::Cpio)
                .args(["-idm", "--quiet", "--no-absolute-filenames"])
                .cwd(&sources),
        )?;
        if !a.ok() || !b.ok() {
            return Err(infra(format!("cannot unpack {}", srpm.display())));
        }
        let specs: Vec<PathBuf> = fs::sorted_entries(&sources)?
            .into_iter()
            .filter(|p| fs::file_name(p).as_bytes().ends_with(b".spec"))
            .collect();
        let [spec] = &specs[..] else {
            return Err(infra(format!("the SRPM holds {} spec files", specs.len())));
        };
        if !spec.is_file() {
            return Err(infra("the SRPM holds 1 spec files"));
        }
        let dest = top.join("SPECS").join(fs::file_name(spec));
        std::fs::rename(spec, &dest).map_err(|e| fs::io_error("cannot move", spec, &e))?;
        Ok(dest)
    }

    fn srcdir(top: &Path) -> Option<PathBuf> {
        let dirs = |p: &Path| -> Vec<PathBuf> {
            std::fs::read_dir(p)
                .map(|rd| {
                    rd.filter_map(std::result::Result::ok)
                        .filter(|e| e.file_type().is_ok_and(|t| t.is_dir()))
                        .map(|e| e.path())
                        .collect()
                })
                .unwrap_or_default()
        };
        let found: Vec<PathBuf> = dirs(&top.join("BUILD"))
            .iter()
            .flat_map(|d| dirs(d))
            .filter(|d| fs::file_name(d) != "SPECPARTS" && d.to_string_lossy().contains("-build/"))
            .collect();
        match &found[..] {
            [one] => Some(one.clone()),
            _ => None,
        }
    }

    fn empty_build_dir(top: &Path) -> Result<()> {
        let build = top.join("BUILD");
        for entry in fs::sorted_entries(&build)? {
            let res = if entry.is_dir() && !entry.is_symlink() {
                std::fs::remove_dir_all(&entry)
            } else {
                std::fs::remove_file(&entry)
            };
            res.map_err(|e| fs::io_error("cannot remove", &entry, &e))?;
        }
        Ok(())
    }

    fn copy_tree(&self, from: &Path, to: &Path) -> Result<()> {
        self.run_ok(
            &Cmd::new(Program::Cp).arg("-a").arg("--").arg(from).arg(to),
            "cp -a failed",
        )
        .map(|_| ())
    }
}
