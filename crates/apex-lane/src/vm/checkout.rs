use std::ffi::OsString;
use std::path::{Path, PathBuf};

use super::{DNF_CACHE_VOLUME, IN_CONTAINER_EXE, LANE_TREE_PATH, Vm};
use crate::core::repos::{self, is_fedora_pin};
use crate::core::source1::{archive_name, member_ok};
use crate::core::text;
use crate::core::tool_id::{self, SOURCE_PATHS};
use crate::error::{Result, infra, usage};
use crate::pkg::Pkg;
use crate::shell::cmd::{Cmd, Program, Stderr, Stdout};
use crate::shell::fs;

/// Source1 as staged for the container.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Source1 {
    pub archive: String,
    pub tree: String,
}

/// What the container is asked to do.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Mode {
    Build {
        n: u64,
        tool: String,
        locked_evr: String,
    },
    Key {
        n: u64,
        tool: String,
    },
    Prep {
        nvr: Option<String>,
    },
}

/// The paths N counts and that must be clean. packaging/rebuild.sh, the lane before
/// apex-lane, stays for good: git still counts a deleted path's history, so N never drops.
pub fn lane_paths(pkg: &Pkg) -> Vec<String> {
    let mut paths = vec![format!("packaging/pkgs/{}", pkg.name)];
    paths.extend(pkg.env.source1.clone());
    paths.extend(SOURCE_PATHS.map(String::from));
    paths.push("packaging/rebuild.sh".into());
    paths
}

const SOURCE1_MTIME: &str = "@946684800";

impl Vm<'_> {
    pub fn check_committed(&self, pkg: &Pkg) -> Result<()> {
        let head = self.runner.run(
            &self
                .git()
                .args(["rev-parse", "-q", "--verify", "HEAD"])
                .stdout(Stdout::Null),
        )?;
        if !head.ok() {
            return Err(usage("the checkout has no commit"));
        }
        if text::chomp(&self.git_out(["rev-parse", "--is-shallow-repository"])?) != b"false" {
            return Err(usage(
                "a shallow clone cannot count .apexN; fetch the full history",
            ));
        }
        let dirty = self.git_out(
            ["status", "--porcelain", "--untracked-files=all", "--"]
                .map(String::from)
                .into_iter()
                .chain(lane_paths(pkg)),
        )?;
        let dirty = text::chomp(&dirty);
        if !dirty.is_empty() {
            return Err(usage(format!(
                "uncommitted lane inputs (commit them, or use the just pkg-* recipes, which snapshot a dirty tree in the builder VM):\n{}",
                text::lossy(dirty)
            )));
        }
        Ok(())
    }

    /// N of `.apexN`: the commits that touch the lane paths.
    pub fn release_n(&self, pkg: &Pkg) -> Result<u64> {
        let out = self.git_out(
            ["rev-list", "--count", "HEAD", "--"]
                .map(String::from)
                .into_iter()
                .chain(lane_paths(pkg)),
        )?;
        text::lossy(text::chomp(&out))
            .parse()
            .map_err(|_| infra("git rev-list --count gave no number"))
    }

    pub fn head_lane_tree(&self) -> Result<Option<String>> {
        let out = self.runner.run(
            &self
                .git()
                .args(["rev-parse", "-q", "--verify"])
                .arg(format!("HEAD:{LANE_TREE_PATH}"))
                .capture(),
        )?;
        Ok(out.ok().then(|| text::lossy(text::chomp(&out.stdout))))
    }

    pub fn tool_id(&self) -> Result<String> {
        let show = |path: &str| -> Result<String> {
            let out = self.runner.run(
                &self
                    .git()
                    .arg("show")
                    .arg(format!("HEAD:{path}"))
                    .capture()
                    .stderr(Stderr::Null),
            )?;
            if !out.ok() {
                return Err(usage(format!(
                    "{path} is not committed at HEAD; the content key counts the committed lane"
                )));
            }
            Ok(text::lossy(&out.stdout))
        };
        let ls_tree = self.git_out(
            ["ls-tree", "-r", "HEAD", "--"]
                .into_iter()
                .chain(SOURCE_PATHS),
        )?;
        let id = tool_id::tool_id(
            &ls_tree,
            &show(SOURCE_PATHS[0])?,
            &show("Cargo.toml")?,
            &show("Cargo.lock")?,
        )?;
        Ok(id)
    }

    pub fn repos_base(&self) -> Result<String> {
        let containerfile = fs::read(&self.root.join("image/Containerfile"))?;
        let base = repos::containerfile_arg(&containerfile, "REPOS_BASE");
        if !is_fedora_pin(&base) {
            return Err(usage(format!(
                "image/Containerfile REPOS_BASE '{base}' is not a registry.fedoraproject.org digest pin"
            )));
        }
        Ok(base)
    }

    pub fn ga_reached(&self) -> Result<u8> {
        let containerfile = fs::read(&self.root.join("image/Containerfile"))?;
        repos::ga_reached(
            self.settings.ga_override.as_deref(),
            &repos::containerfile_arg(&containerfile, "GA_REACHED"),
        )
        .map_err(infra)
    }

    fn archive(&self, tree: &str, out: &Path) -> Result<()> {
        let cmd = self
            .git()
            .args(["archive", "--format=tar"])
            .arg(format!("--mtime={SOURCE1_MTIME}"))
            .arg("-o")
            .arg(out)
            .arg(tree);
        let res = self.runner.run(&cmd)?;
        if !res.ok() {
            return Err(infra(format!("{cmd} failed (exit {})", res.code)));
        }
        Ok(())
    }

    fn tar_list(&self, archive: &Path, verbose: bool) -> Result<Vec<u8>> {
        let cmd = Cmd::new(Program::Tar)
            .arg(if verbose { "-tvf" } else { "-tf" })
            .arg(archive)
            .capture();
        let out = self.runner.run(&cmd)?;
        if !out.ok() {
            return Err(infra(format!("{cmd} failed (exit {})", out.code)));
        }
        Ok(out.stdout)
    }

    /// The committed Source1 tree as a `git archive` with fixed dates, so its bytes follow
    /// from the tree id. Every member must match `source1_paths` and none may be a link.
    pub fn stage_source1(&self, pkg: &Pkg, dir: &Path) -> Result<Option<Source1>> {
        let Some(source1) = &pkg.env.source1 else {
            return Ok(None);
        };
        let not_committed = || usage(format!("{source1} is not a committed directory"));
        let out = self.runner.run(
            &self
                .git()
                .args(["rev-parse", "-q", "--verify"])
                .arg(format!("HEAD:{source1}"))
                .capture(),
        )?;
        if !out.ok() {
            return Err(not_committed());
        }
        let tree = text::lossy(text::chomp(&out.stdout));
        let kind = self.git_out(["cat-file", "-t", tree.as_str()])?;
        if text::chomp(&kind) != b"tree" {
            return Err(not_committed());
        }
        let archive = archive_name(source1, &tree);
        let path = dir.join(&archive);
        self.archive(&tree, &path)?;
        let allowed = &pkg.env.source1_paths;
        for m in text::lines(&self.tar_list(&path, false)?) {
            let m = text::lossy(m);
            if !member_ok(&m, allowed) {
                return Err(usage(format!(
                    "Source1 member '{m}' is outside source1_paths ({})",
                    allowed.join(" ")
                )));
            }
        }
        if text::lines(&self.tar_list(&path, true)?)
            .iter()
            .any(|l| l.starts_with(b"l") || l.starts_with(b"h"))
        {
            return Err(usage(
                "Source1 contains a link; every member must be a file or a directory",
            ));
        }
        Ok(Some(Source1 { archive, tree }))
    }

    /// Source1 from the working tree, committed or not, through a temporary index.
    pub fn source1_from_worktree(&self, pkg: &Pkg, dir: &Path) -> Result<Option<Source1>> {
        let Some(source1) = &pkg.env.source1 else {
            return Ok(None);
        };
        let tmp = tempfile::tempdir()
            .map_err(|e| infra(format!("cannot create a temporary directory: {e}")))?;
        let index = tmp.path().join("index");
        let with_index = |cmd: Cmd| cmd.env("GIT_INDEX_FILE", &index);
        for args in [
            vec!["read-tree".to_owned(), "HEAD".to_owned()],
            vec!["add".into(), "-A".into(), "--".into(), source1.clone()],
        ] {
            let cmd = with_index(self.git().args(&args));
            let out = self.runner.run(&cmd)?;
            if !out.ok() {
                return Err(infra(format!("{cmd} failed (exit {})", out.code)));
            }
        }
        let cmd = with_index(
            self.git()
                .arg("write-tree")
                .arg(format!("--prefix={source1}/"))
                .capture(),
        );
        let out = self.runner.run(&cmd)?;
        if !out.ok() {
            return Err(infra(format!("{cmd} failed (exit {})", out.code)));
        }
        let tree = text::lossy(text::chomp(&out.stdout));
        let archive = archive_name(source1, &tree);
        self.archive(&tree, &dir.join(&archive))?;
        Ok(Some(Source1 { archive, tree }))
    }

    /// Root only ever touches work directories under `_build/`.
    fn under_build(&self, dir: &Path) -> Result<()> {
        let build = self.root.join("_build");
        if !dir.starts_with(&build)
            || dir == build
            || dir.components().any(|c| c.as_os_str() == "..")
        {
            return Err(infra(format!(
                "{} is not a work directory under _build/",
                dir.display()
            )));
        }
        Ok(())
    }

    /// `chown -R` back to the builder user: the container writes as root.
    pub fn own(&self, dir: &Path) -> Result<()> {
        self.under_build(dir)?;
        let cmd = Cmd::new(Program::Chown)
            .arg("-R")
            .arg(format!("{}:{}", self.settings.uid, self.settings.gid))
            .arg("--")
            .arg(dir)
            .privileged(self.settings.is_root);
        let out = self.runner.run(&cmd)?;
        if !out.ok() {
            return Err(infra(format!("{cmd} failed (exit {})", out.code)));
        }
        Ok(())
    }

    /// A work directory the container may have filled as root, removed and made again.
    pub fn fresh_work_dir(&self, dir: &Path, subdirs: &[&str]) -> Result<()> {
        self.under_build(dir)?;
        if dir.symlink_metadata().is_ok() {
            let cmd = Cmd::new(Program::Rm)
                .arg("-rf")
                .arg("--")
                .arg(dir)
                .privileged(self.settings.is_root);
            let out = self.runner.run(&cmd)?;
            if !out.ok() {
                return Err(infra(format!("{cmd} failed (exit {})", out.code)));
            }
        }
        for sub in subdirs {
            fs::create_dir_all(&dir.join(sub))?;
        }
        Ok(())
    }

    /// The container's status; anything above 3 (podman's own errors, a crash) counts as
    /// 1.
    pub fn run_container(
        &self,
        pkg: &Pkg,
        work: &Path,
        mode: &Mode,
        source1: Option<&Source1>,
    ) -> Result<i32> {
        let base = self.repos_base()?;
        let ga = self.ga_reached()?;
        let store = self.store_pkg(&pkg.name);
        fs::create_dir_all(&store)?;
        let mount = |from: &Path, to: &str, opts: &str| -> Result<OsString> {
            let from = from.display().to_string();
            if from.contains([':', ',']) {
                return Err(infra(format!(
                    "cannot mount {from}: the path holds ':' or ','"
                )));
            }
            Ok(format!("{from}:{to}:{opts}").into())
        };
        let mut cmd = Cmd::new(Program::Podman)
            .args(["run", "--rm", "--pull=missing"])
            .arg("-v")
            .arg(mount(&self.root, "/src", "ro,z")?)
            .arg("-v")
            .arg(mount(work, "/work", "z")?)
            .arg("-v")
            .arg(mount(&store, "/store", "ro,z")?)
            .arg("-v")
            .arg(format!("{DNF_CACHE_VOLUME}:/var/cache/libdnf5"))
            .arg("-v")
            .arg(mount(&self.settings.exe, IN_CONTAINER_EXE, "ro,z")?)
            .arg(&base)
            .arg(IN_CONTAINER_EXE)
            .arg("in-container");
        let (name, nvr) = match mode {
            Mode::Build { .. } => ("build", None),
            Mode::Key { .. } => ("key", None),
            Mode::Prep { nvr } => ("prep", nvr.as_deref()),
        };
        cmd = cmd.arg(name).arg(&pkg.name).args(nvr);
        cmd = cmd
            .arg("--repos-base")
            .arg(&base)
            .arg("--ga-reached")
            .arg(ga.to_string());
        match mode {
            Mode::Build { n, tool, .. } | Mode::Key { n, tool } => {
                cmd = cmd.arg("--n").arg(n.to_string()).arg("--tool").arg(tool);
            }
            Mode::Prep { .. } => {}
        }
        if let Some(s) = source1 {
            cmd = cmd
                .arg("--source1")
                .arg(&s.archive)
                .arg("--source1-tree")
                .arg(&s.tree);
        }
        if let Mode::Build { locked_evr, .. } = mode {
            if !locked_evr.is_empty() {
                cmd = cmd.arg("--locked-evr").arg(locked_evr);
            }
            if self.settings.keep_work {
                cmd = cmd.arg("--keep-work");
            }
        }
        if self.report.github {
            cmd = cmd.arg("--github");
        }
        let out = self.runner.run(&cmd.privileged(self.settings.is_root))?;
        Ok(if (0..=3).contains(&out.code) {
            out.code
        } else {
            1
        })
    }

    pub fn lane_work(&self, dir_name: &str) -> PathBuf {
        self.root.join("_build/lane").join(dir_name)
    }
}
