use std::path::{Path, PathBuf};

use super::Vm;
use super::checkout::Mode;
use crate::core::lock;
use crate::core::names::is_patch_name;
use crate::core::status;
use crate::core::text;
use crate::error::{Exit, Result, infra, usage};
use crate::pkg::{self, Parse};
use crate::shell::cmd::{Cmd, Program, Stderr, Stdout};
use crate::shell::fs;

fn exit_of_status(rc: i32) -> Exit {
    match rc {
        0 => Exit::Ok,
        2 => Exit::Usage,
        3 => Exit::NoShippableBuild,
        _ => Exit::Error,
    }
}

fn is_build_of(nvr: &str, srpm: &str) -> bool {
    nvr.strip_prefix(srpm)
        .and_then(|r| r.strip_prefix('-'))
        .and_then(|vr| vr.split_once('-'))
        .is_some_and(|(v, r)| !v.is_empty() && !r.is_empty() && !r.contains('-'))
}

impl Vm<'_> {
    pub fn key(&self, name: &str) -> Result<Exit> {
        let pkg = self.load(name)?;
        self.check_committed(&pkg)?;
        let n = self.release_n(&pkg)?;
        let tool = self.tool_id()?;
        // Not _build/lane/PKG: a build may be running there.
        let work = self.lane_work(&format!("{}.key", pkg.name));
        self.fresh_work_dir(&work, &["in", "out"])?;
        let source1 = self.stage_source1(&pkg, &work.join("in"))?;
        let rc = self.run_container(&pkg, &work, &Mode::Key { n, tool }, source1.as_ref());
        self.own(&work)?;
        Ok(exit_of_status(rc?))
    }

    /// Unlike build, prep takes the working copy's inputs, committed or not.
    pub fn prep(&self, name: &str, nvr: Option<&str>) -> Result<Exit> {
        let pkg = self.load(name)?;
        let srpm = &pkg.env.srpm;
        if let Some(nvr) = nvr
            && !is_build_of(nvr, srpm)
        {
            return Err(usage(format!(
                "NVR must be a build of {srpm}, like {srpm}-51.1-1.fc45"
            )));
        }
        let dir = self.root.join("_build/pkg").join(&pkg.name);
        self.fresh_work_dir(&dir, &["in"])?;
        let source1 = self.source1_from_worktree(&pkg, &dir.join("in"))?;
        let mode = Mode::Prep {
            nvr: nvr.map(str::to_owned),
        };
        let rc = self.run_container(&pkg, &dir, &mode, source1.as_ref());
        self.own(&dir)?;
        let rc = rc?;
        if dir.join("tree").is_dir() {
            self.report.log(&format!(
                "work tree: {} (the series: the commits after the tag apex-base)",
                dir.join("tree").display()
            ));
            self.report.log(&format!(
                "edit and commit (git commit --amend for a patch, a new commit for a new patch), then: just pkg-export {}",
                pkg.name
            ));
        }
        Ok(exit_of_status(rc))
    }

    /// No user or system configuration, so format-patch writes the same bytes everywhere.
    fn tree_git(tree: &Path) -> Cmd {
        Cmd::new(Program::Git)
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .arg("-c")
            .arg(format!("safe.directory={}", tree.display()))
            .arg("-C")
            .arg(tree)
    }

    pub fn export(&self, name: &str, new: &[String]) -> Result<()> {
        let pkg = pkg::load(&self.root, name, Parse::Export)?;
        let tree = self.root.join("_build/pkg").join(&pkg.name).join("tree");
        if !tree.join(".git").is_dir() {
            return Err(usage(format!(
                "no work tree {} (just pkg-prep {})",
                tree.display(),
                pkg.name
            )));
        }
        for (i, n) in new.iter().enumerate() {
            if !is_patch_name(n) {
                return Err(usage(format!("'{n}' is not a NNNN-name.patch file name")));
            }
            if pkg.series.contains(n) {
                return Err(usage(format!("series already lists '{n}'")));
            }
            if new[..i].contains(n) {
                return Err(usage(format!("'{n}' is given twice")));
            }
        }
        let run = |cmd: Cmd| -> Result<Vec<u8>> {
            let out = self.runner.run(&cmd.capture())?;
            if !out.ok() {
                return Err(infra(format!(
                    "git in {} failed (exit {})",
                    tree.display(),
                    out.code
                )));
            }
            Ok(out.stdout)
        };
        let dirty =
            run(Self::tree_git(&tree).args(["status", "--porcelain", "--untracked-files=no"]))?;
        if !text::chomp(&dirty).is_empty() {
            return Err(usage(format!(
                "{} has uncommitted changes to upstream files; commit them first",
                tree.display()
            )));
        }
        if tree.join(".git/rebase-apply").is_dir() {
            return Err(usage(format!(
                "{} is in the middle of git am; finish it first",
                tree.display()
            )));
        }
        let listed = self.runner.run(
            &Self::tree_git(&tree)
                .args(["rev-list", "--reverse", "apex-base..HEAD"])
                .capture()
                .stderr(Stderr::Null),
        )?;
        let commits: Vec<String> = if listed.ok() {
            text::lines(&listed.stdout)
                .into_iter()
                .map(text::lossy)
                .collect()
        } else {
            Vec::new()
        };
        let names: Vec<&String> = pkg.series.iter().chain(new).collect();
        if commits.len() != names.len() {
            return Err(usage(format!(
                "{} has {} commits after apex-base, but series lists {} and {} new name(s) were given: one name per commit, in order",
                tree.display(),
                commits.len(),
                pkg.series.len(),
                new.len()
            )));
        }
        self.write_patches(&tree, &commits, &names, &pkg.dir.join("patches"))?;
        if !new.is_empty() {
            let series = pkg.dir.join("series");
            let mut add = Vec::new();
            if fs::read_opt(&series)?.is_some_and(|s| !s.is_empty() && !s.ends_with(b"\n")) {
                add.push(b'\n');
            }
            add.extend(text::join_lines(new));
            fs::append(&series, &add)?;
        }
        Ok(())
    }

    fn write_patches(
        &self,
        tree: &Path,
        commits: &[String],
        names: &[&String],
        patches: &Path,
    ) -> Result<()> {
        fs::create_dir_all(patches)?;
        for (commit, name) in commits.iter().zip(names) {
            self.run_ok(
                &Self::tree_git(tree)
                    .args([
                        "format-patch",
                        "-1",
                        "--stdout",
                        "-N",
                        "--zero-commit",
                        "--no-signature",
                    ])
                    .arg(commit)
                    .stdout(Stdout::File(patches.join(name.as_str()))),
            )?;
            let subject = self.runner.run(
                &Self::tree_git(tree)
                    .args(["log", "-1", "--format=%h %s"])
                    .arg(commit)
                    .capture(),
            )?;
            self.report.log(&format!(
                "export: {name} <- {}",
                text::lossy(text::chomp(&subject.stdout))
            ));
        }
        Ok(())
    }

    pub fn status(&self) -> Result<Vec<u8>> {
        let now = self.clock.now();
        let mut out = status::render(
            "rpms.lock.next (the next image build takes it):",
            fs::read_opt(&self.next_lock_file())?.as_deref(),
            now,
        );
        out.extend(status::render(
            "rpms.lock (the last image that passed its gates):",
            fs::read_opt(&self.lock_file())?.as_deref(),
            now,
        ));
        Ok(out)
    }

    pub fn promote(&self) -> Result<()> {
        let _lock = fs::lock_store(&self.settings.store)?;
        let next = self.next_lock_file();
        let Some(text) = fs::read_opt(&next)? else {
            return Err(infra(format!("no {} to promote", next.display())));
        };
        for (sha, path) in lock::rpm_files(&text) {
            let shown = text::lossy(&path);
            if !lock::is_store_path(&path) {
                return Err(infra(format!(
                    "promote: {shown} is not a relative path inside the store"
                )));
            }
            let file: PathBuf = self.settings.store.join(&shown);
            if !file.is_file() {
                return Err(infra(format!("promote: {shown} is missing from the store")));
            }
            if fs::sha256_file(&file)?.as_bytes() != sha.as_slice() {
                return Err(infra(format!(
                    "promote: {shown} does not match rpms.lock.next"
                )));
            }
        }
        let tmp = self.settings.store.join("rpms.lock.tmp");
        fs::copy_with_mode(&next, &tmp)?;
        std::fs::rename(&tmp, self.lock_file())
            .map_err(|e| fs::io_error("cannot replace", &self.lock_file(), &e))?;
        self.report.log("promoted rpms.lock.next to rpms.lock");
        Ok(())
    }
}
