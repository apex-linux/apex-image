pub mod build;
pub mod checkout;
pub mod commands;

use std::path::{Path, PathBuf};

pub use build::Outcome;

use crate::core::text;
use crate::error::{Result, infra};
use crate::shell::bodhi::Bodhi;
use crate::shell::clock::Clock;
use crate::shell::cmd::{Cmd, Outcome as CmdOutcome, Program, Runner};
use crate::shell::report::Reporter;

pub const IN_CONTAINER_EXE: &str = "/usr/local/libexec/apex-lane";
pub const DNF_CACHE_VOLUME: &str = "apex-lane-dnf-cache";
pub const LANE_TREE_PATH: &str = "crates/apex-lane";

#[derive(Debug, Clone)]
pub struct Settings {
    pub store: PathBuf,
    pub ga_override: Option<String>,
    pub keep_work: bool,
    pub signing_env: PathBuf,
    pub exe: PathBuf,
    pub uid: u32,
    pub gid: u32,
    pub is_root: bool,
}

pub struct Vm<'a> {
    pub root: PathBuf,
    pub settings: Settings,
    pub runner: &'a dyn Runner,
    pub clock: &'a dyn Clock,
    pub bodhi: &'a dyn Bodhi,
    pub report: &'a Reporter,
}

impl std::fmt::Debug for Vm<'_> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Vm")
            .field("root", &self.root)
            .field("settings", &self.settings)
            .finish_non_exhaustive()
    }
}

pub fn find_root(dir: &Path) -> Option<PathBuf> {
    dir.ancestors()
        .find(|d| d.join("packaging/pkgs").is_dir() && d.join("image/Containerfile").is_file())
        .map(Path::to_path_buf)
}

impl Vm<'_> {
    fn git(&self) -> Cmd {
        Cmd::new(Program::Git)
            .arg("-c")
            .arg(format!("safe.directory={}", self.root.display()))
            .arg("-C")
            .arg(&self.root)
    }

    fn run_ok(&self, cmd: &Cmd) -> Result<CmdOutcome> {
        let out = self.runner.run(cmd)?;
        if !out.ok() {
            return Err(infra(format!("{cmd} failed (exit {})", out.code)));
        }
        Ok(out)
    }

    fn git_out<I, S>(&self, args: I) -> Result<Vec<u8>>
    where
        I: IntoIterator<Item = S>,
        S: AsRef<std::ffi::OsStr>,
    {
        Ok(self.run_ok(&self.git().args(args).capture())?.stdout)
    }

    fn head_object(&self, path: &str) -> Result<Option<String>> {
        let out = self.runner.run(
            &self
                .git()
                .args(["rev-parse", "-q", "--verify"])
                .arg(format!("HEAD:{path}"))
                .capture(),
        )?;
        Ok(out.ok().then(|| text::lossy(text::chomp(&out.stdout))))
    }

    fn store_pkg(&self, pkg: &str) -> PathBuf {
        self.settings.store.join("pkgs").join(pkg)
    }

    fn next_lock_file(&self) -> PathBuf {
        self.settings.store.join("rpms.lock.next")
    }

    fn lock_file(&self) -> PathBuf {
        self.settings.store.join("rpms.lock")
    }
}
