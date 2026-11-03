use std::ffi::OsString;
use std::path::{Path, PathBuf};

use super::{DNF_CACHE_VOLUME, IN_CONTAINER_EXE, LANE_TREE_PATH, Vm};
use crate::core::fedora;
use crate::core::repos::{self, is_fedora_pin};
use crate::core::source1::{archive_name, member_ok};
use crate::core::text;
use crate::core::tool_id::{self, SOURCE_PATHS};
use crate::error::{Result, infra, usage};
use crate::pkg::Pkg;
use crate::shell::cmd::{Cmd, Program, Stderr, Stdout};
use crate::shell::fs;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Source1 {
    pub archive: String,
    pub tree: String,
}

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

/// Fixed, so the archive's bytes follow from the tree id alone.
const SOURCE1_MTIME: &str = "@946684800";

impl Vm<'_> {
    /// Each checkout with the paths that must be clean there and whose commits N counts:
    /// the recipe in its checkout, the lane itself in the lane checkout.
    pub fn lane_paths<'p>(&'p self, pkg: &'p Pkg) -> Vec<(&'p Path, Vec<String>)> {
        let mut recipe = vec![format!("packaging/pkgs/{}", pkg.name)];
        recipe.extend(pkg.env.source1.clone());
        let mut tool: Vec<String> = SOURCE_PATHS.map(String::from).into();
        // The deleted Bash lane: its history keeps counting, or N would drop.
        tool.push("packaging/rebuild.sh".into());
        if pkg.recipe_root == self.root {
            recipe.extend(tool);
            vec![(&self.root, recipe)]
        } else {
            vec![(&pkg.recipe_root, recipe), (&self.root, tool)]
        }
    }

    pub fn check_committed(&self, pkg: &Pkg) -> Result<()> {
        for (root, paths) in self.lane_paths(pkg) {
            self.check_clean(root, paths)?;
        }
        Ok(())
    }

    pub(super) fn check_clean(&self, root: &Path, paths: Vec<String>) -> Result<()> {
        let head = self.runner.run(
            &Self::git_in(root)
                .args(["rev-parse", "-q", "--verify", "HEAD"])
                .stdout(Stdout::Null),
        )?;
        if !head.ok() {
            return Err(usage(format!("{} has no commit", root.display())));
        }
        if text::chomp(&self.git_out_in(root, ["rev-parse", "--is-shallow-repository"])?)
            != b"false"
        {
            return Err(usage(format!(
                "{} is a shallow clone, which cannot count .apexN; fetch the full history",
                root.display()
            )));
        }
        let dirty = self.git_out_in(
            root,
            ["status", "--porcelain", "--untracked-files=all", "--"]
                .map(String::from)
                .into_iter()
                .chain(paths),
        )?;
        let dirty = text::chomp(&dirty);
        if !dirty.is_empty() {
            return Err(usage(format!(
                "uncommitted lane inputs in {} (commit them, or use the just pkg-* recipes, which snapshot a dirty tree in the builder VM):\n{}",
                root.display(),
                text::lossy(dirty)
            )));
        }
        Ok(())
    }

    /// The sum over the checkouts, so N only grows when the recipe moves to its own repo.
    pub fn release_n(&self, pkg: &Pkg) -> Result<u64> {
        let mut n = 0;
        for (root, paths) in self.lane_paths(pkg) {
            let out = self.git_out_in(
                root,
                ["rev-list", "--count", "HEAD", "--"]
                    .map(String::from)
                    .into_iter()
                    .chain(paths),
            )?;
            n += text::lossy(text::chomp(&out))
                .parse::<u64>()
                .map_err(|_| infra("git rev-list --count gave no number"))?;
        }
        Ok(n)
    }

    pub fn head_lane_tree(&self) -> Result<Option<String>> {
        self.head_object(LANE_TREE_PATH)
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
        Ok(tool_id::tool_id(
            &ls_tree,
            &show(SOURCE_PATHS[0])?,
            &show("Cargo.toml")?,
            &show("Cargo.lock")?,
        )?)
    }

    /// NAME of this release: image/Containerfile's ARG for 45, image/fedora/N.env's line
    /// for a next release; and where it came from.
    fn release_arg(&self, name: &str) -> Result<(String, String)> {
        let fedora = &self.settings.fedora;
        if !fedora::is_next(fedora) {
            let containerfile = fs::read(&self.root.join("image/Containerfile"))?;
            return Ok((
                repos::containerfile_arg(&containerfile, name),
                "image/Containerfile".to_owned(),
            ));
        }
        let path = fedora::env_path(&self.root, fedora);
        let text = fs::read_opt(&path)?
            .ok_or_else(|| usage(format!("APEX_FEDORA={fedora} has no {}", path.display())))?;
        Ok((
            fedora::env_value(&text, name),
            format!("image/fedora/{fedora}.env"),
        ))
    }

    pub fn repos_base(&self) -> Result<String> {
        let (base, from) = self.release_arg("REPOS_BASE")?;
        if !is_fedora_pin(&base) {
            return Err(usage(format!(
                "{from} REPOS_BASE '{base}' is not a registry.fedoraproject.org digest pin"
            )));
        }
        Ok(base)
    }

    fn archive(&self, root: &Path, tree: &str, out: &Path) -> Result<()> {
        self.run_ok(
            &Self::git_in(root)
                .args(["archive", "--format=tar"])
                .arg(format!("--mtime={SOURCE1_MTIME}"))
                .arg("-o")
                .arg(out)
                .arg(tree),
        )
        .map(|_| ())
    }

    fn tar_list(&self, archive: &Path, verbose: bool) -> Result<Vec<u8>> {
        let cmd = Cmd::new(Program::Tar)
            .arg(if verbose { "-tvf" } else { "-tf" })
            .arg(archive)
            .capture();
        Ok(self.run_ok(&cmd)?.stdout)
    }

    pub fn stage_source1(&self, pkg: &Pkg, dir: &Path) -> Result<Option<Source1>> {
        let Some(source1) = &pkg.env.source1 else {
            return Ok(None);
        };
        let not_committed = || usage(format!("{source1} is not a committed directory"));
        let root = &pkg.recipe_root;
        let tree = self
            .head_object_in(root, source1)?
            .ok_or_else(not_committed)?;
        let kind = self.git_out_in(root, ["cat-file", "-t", tree.as_str()])?;
        if text::chomp(&kind) != b"tree" {
            return Err(not_committed());
        }
        let archive = archive_name(source1, &tree);
        let path = dir.join(&archive);
        self.archive(root, &tree, &path)?;
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
            self.run_ok(&with_index(Self::git_in(&pkg.recipe_root).args(&args)))?;
        }
        let out = self.run_ok(&with_index(
            Self::git_in(&pkg.recipe_root)
                .arg("write-tree")
                .arg(format!("--prefix={source1}/"))
                .capture(),
        ))?;
        let tree = text::lossy(text::chomp(&out.stdout));
        let archive = archive_name(source1, &tree);
        self.archive(&pkg.recipe_root, &tree, &dir.join(&archive))?;
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

    /// Back to the builder user: the container writes as root.
    pub fn own(&self, dir: &Path) -> Result<()> {
        self.under_build(dir)?;
        self.run_ok(
            &Cmd::new(Program::Chown)
                .arg("-R")
                .arg(format!("{}:{}", self.settings.uid, self.settings.gid))
                .arg("--")
                .arg(dir)
                .privileged(self.settings.is_root),
        )
        .map(|_| ())
    }

    /// Removed as root: the container may have filled it as root.
    pub fn fresh_work_dir(&self, dir: &Path, subdirs: &[&str]) -> Result<()> {
        self.under_build(dir)?;
        if dir.symlink_metadata().is_ok() {
            self.run_ok(
                &Cmd::new(Program::Rm)
                    .arg("-rf")
                    .arg("--")
                    .arg(dir)
                    .privileged(self.settings.is_root),
            )?;
        }
        for sub in subdirs {
            fs::create_dir_all(&dir.join(sub))?;
        }
        Ok(())
    }

    pub fn run_container(
        &self,
        pkg: &Pkg,
        work: &Path,
        mode: &Mode,
        source1: Option<&Source1>,
    ) -> Result<i32> {
        let base = self.repos_base()?;
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
            .arg(mount(&pkg.recipe_root, "/recipes", "ro,z")?)
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
        cmd = cmd.arg("--repos-base").arg(&base);
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
        // Above 3: podman's own errors, or a crash.
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
