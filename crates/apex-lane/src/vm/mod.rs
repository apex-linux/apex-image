pub mod build;
pub mod bump;
pub mod checkout;
pub mod commands;
pub mod pair;
pub mod sign;

use std::path::{Path, PathBuf};

pub use build::Outcome;

use crate::core::text;
use crate::error::{Result, infra, usage};
use crate::pkg;
use crate::shell::bodhi::Bodhi;
use crate::shell::clock::Clock;
use crate::shell::cmd::{Cmd, Outcome as CmdOutcome, Program, Runner};
use crate::shell::kernel_org::KernelOrg;
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
    /// Checkouts holding `packaging/pkgs`; none means `root` holds them.
    pub recipes: Vec<PathBuf>,
    pub settings: Settings,
    pub runner: &'a dyn Runner,
    pub clock: &'a dyn Clock,
    pub bodhi: &'a dyn Bodhi,
    pub kernel_org: &'a dyn KernelOrg,
    pub report: &'a Reporter,
}

impl std::fmt::Debug for Vm<'_> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Vm")
            .field("root", &self.root)
            .field("recipes", &self.recipes)
            .field("settings", &self.settings)
            .finish_non_exhaustive()
    }
}

pub fn find_root(dir: &Path) -> Option<PathBuf> {
    dir.ancestors()
        .find(|d| d.join(LANE_TREE_PATH).is_dir() && d.join("image/Containerfile").is_file())
        .map(Path::to_path_buf)
}

impl Vm<'_> {
    fn git(&self) -> Cmd {
        Self::git_in(&self.root)
    }

    fn git_in(root: &Path) -> Cmd {
        Cmd::new(Program::Git)
            .arg("-c")
            .arg(format!("safe.directory={}", root.display()))
            .arg("-C")
            .arg(root)
    }

    pub fn recipe_roots(&self) -> Vec<PathBuf> {
        if self.recipes.is_empty() {
            vec![self.root.clone()]
        } else {
            self.recipes.clone()
        }
    }

    pub fn all_pkgs(&self) -> Result<Vec<String>> {
        let mut names = Vec::new();
        for root in self.recipe_roots() {
            names.extend(pkg::all(&root)?);
        }
        names.sort();
        Ok(names)
    }

    pub fn recipe_root_of(&self, name: &str) -> Result<PathBuf> {
        let roots = self.recipe_roots();
        let mut holding = roots
            .iter()
            .filter(|r| pkg::pkgs_dir(r).join(name).join("pkg.env").is_file());
        match (holding.next(), holding.next()) {
            (Some(root), None) => Ok(root.clone()),
            (Some(_), Some(_)) => Err(usage(format!(
                "more than one recipe checkout holds packaging/pkgs/{name}"
            ))),
            (None, _) => Err(usage(format!(
                "no recipe checkout holds packaging/pkgs/{name}/pkg.env (packages: {})",
                self.all_pkgs()?.join(" ")
            ))),
        }
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
        self.git_out_in(&self.root, args)
    }

    fn git_out_in<I, S>(&self, root: &Path, args: I) -> Result<Vec<u8>>
    where
        I: IntoIterator<Item = S>,
        S: AsRef<std::ffi::OsStr>,
    {
        Ok(self
            .run_ok(&Self::git_in(root).args(args).capture())?
            .stdout)
    }

    fn head_object(&self, path: &str) -> Result<Option<String>> {
        self.head_object_in(&self.root, path)
    }

    fn head_object_in(&self, root: &Path, path: &str) -> Result<Option<String>> {
        let out = self.runner.run(
            &Self::git_in(root)
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
