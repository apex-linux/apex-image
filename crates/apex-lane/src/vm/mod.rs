//! The builder VM's side: the checkout, the store and the locks. The Fedora half runs in a
//! container of `REPOS_BASE` (`crate::container`).

pub mod build;
pub mod checkout;
pub mod commands;

use std::path::{Path, PathBuf};

pub use build::Outcome;

use crate::error::{Result, infra};
use crate::shell::bodhi::Bodhi;
use crate::shell::clock::Clock;
use crate::shell::cmd::{Cmd, Program, Runner};
use crate::shell::report::Reporter;

/// Where the binary is mounted in the build container.
pub const IN_CONTAINER_EXE: &str = "/usr/local/libexec/apex-lane";
/// dnf's metadata cache, a podman volume that outlives the containers.
pub const DNF_CACHE_VOLUME: &str = "apex-lane-dnf-cache";
/// The crate whose tree the binary embeds.
pub const LANE_TREE_PATH: &str = "crates/apex-lane";

/// What the VM side takes from its environment.
#[derive(Debug, Clone)]
pub struct Settings {
    pub store: PathBuf,
    /// `APEX_GA_REACHED`.
    pub ga_override: Option<String>,
    /// `APEX_KEEP_WORK=1`.
    pub keep_work: bool,
    /// `APEX_RPM_SIGNING_ENV`: while it exists and signing is not wired, the lane stops.
    pub signing_env: PathBuf,
    /// This binary, mounted into the container.
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

/// The checkout that holds `dir`: the first ancestor with packaging/pkgs and
/// image/Containerfile.
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

    /// `git ARGS`, stdout captured; a failure is an error that names the command.
    fn git_out<I, S>(&self, args: I) -> Result<Vec<u8>>
    where
        I: IntoIterator<Item = S>,
        S: AsRef<std::ffi::OsStr>,
    {
        let cmd = self.git().args(args).capture();
        let out = self.runner.run(&cmd)?;
        if !out.ok() {
            return Err(infra(format!("{cmd} failed (exit {})", out.code)));
        }
        Ok(out.stdout)
    }

    fn store_pkg(&self, pkg: &str) -> PathBuf {
        self.settings.store.join("pkgs").join(pkg)
    }

    fn next_lock(&self) -> PathBuf {
        self.settings.store.join("rpms.lock.next")
    }

    fn lock(&self) -> PathBuf {
        self.settings.store.join("rpms.lock")
    }
}
