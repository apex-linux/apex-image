use std::path::Path;

use super::Container;
use crate::core::text;
use crate::error::{LaneError, Result, infra};
use crate::shell::cmd::{Cmd, Program, Stdout};
use crate::shell::fs;

fn git_in(tree: &Path) -> Cmd {
    Cmd::new(Program::Git)
        .args([
            "-c",
            "user.name=Apex lane",
            "-c",
            "user.email=lane@localhost",
        ])
        .cwd(tree)
}

impl Container<'_> {
    fn init_tree(&self, tree: &Path, nvr: &str) -> Result<()> {
        let g = || git_in(tree);
        if !tree.join(".git").is_dir() {
            self.run_ok(&g().args(["init", "-q"]), "git init failed")?;
        }
        let status = self.run_ok(
            &g().args(["status", "--porcelain"]).capture(),
            "git status failed",
        )?;
        if !text::chomp(&status.stdout).is_empty() {
            self.run_ok(&g().args(["add", "-A"]), "git add failed")?;
            self.run_ok(
                &g().args(["commit", "-q", "-m"]).arg(format!("{nvr} %prep")),
                "git commit failed",
            )?;
        }
        self.run_ok(
            &g().args(["tag", "-f", "apex-base"]).stdout(Stdout::Null),
            "git tag failed",
        )?;
        let head = self.run_ok(
            &g().args(["rev-parse", "HEAD"]).capture(),
            "git rev-parse failed",
        )?;
        fs::write(
            &self.paths.work.join("tree-info"),
            format!(
                "nvr={nvr}\nbase={}\n",
                text::lossy(text::chomp(&head.stdout))
            )
            .as_bytes(),
        )
    }

    pub(super) fn prep(&self) -> Result<()> {
        let setup = self.setup()?;
        let want = self
            .args
            .nvr
            .as_ref()
            .map(|nvr| format!("{nvr}.{}", setup.arch));
        let stock = self.resolve(&setup, want.as_deref())?;
        let work = tempfile::Builder::new()
            .prefix("apex-prep.")
            .tempdir()
            .map_err(|e| infra(format!("cannot create a work directory: {e}")))?;
        let top = work.path().join("rpmbuild");
        let srpm = self.fetch_srpm(&setup, &stock, work.path())?;
        let spec = self.unpack(&srpm, &top)?;
        let log = work.path().join("prep.log");
        let prep = self.runner.run(
            &Cmd::new(Program::Rpmbuild)
                .arg("--define")
                .arg(format!("_topdir {}", top.display()))
                .args(["--nodeps", "-bp"])
                .arg(&spec)
                .log_to(&log),
        )?;
        if !prep.ok() {
            self.report
                .raw(text::tail_lines(&fs::read(&log).unwrap_or_default(), 40));
            return Err(infra("Fedora's %prep fails"));
        }
        let src = Self::srcdir(&top).ok_or_else(|| infra("no single source tree after %prep"))?;
        let tree = self.paths.work.join("tree");
        if tree.exists() {
            std::fs::remove_dir_all(&tree).map_err(|e| fs::io_error("cannot remove", &tree, &e))?;
        }
        self.copy_tree(&src, &tree)?;
        self.init_tree(&tree, &stock.nvr)?;
        let g = || git_in(&tree);
        let pkg = &setup.pkg;
        for p in &pkg.series {
            let am = self
                .runner
                .run(&g().args(["am", "-3", "--quiet", "--"]).arg(pkg.patch(p)))?;
            if !am.ok() {
                fs::write(
                    &self.paths.work.join("prep-failed"),
                    format!("{p}\n").as_bytes(),
                )?;
                self.report.log(&format!(
                    "FAILED (exit 3): {p} does not apply to {}. The work tree is in the middle of git am:",
                    stock.nvr
                ));
                self.report.log(&format!(
                    "  resolve it (git am --show-current-patch=diff; edit; git add; git am --continue), then just pkg-export {}",
                    pkg.name
                ));
                return Err(LaneError::NoShippableBuild(format!(
                    "{p} does not apply to {}",
                    stock.nvr
                )));
            }
        }
        self.add_source1_and_changes(&tree, pkg)?;
        self.report.log(&format!(
            "work tree /work/tree: {}, then {}",
            stock.nvr,
            pkg.series.join(" ")
        ));
        Ok(())
    }

    /// Excluded or marked skip-worktree, so `git commit -a` never picks them up.
    fn add_source1_and_changes(&self, tree: &Path, pkg: &crate::pkg::Pkg) -> Result<()> {
        let g = || git_in(tree);
        if let Some(archive) = &self.args.source1 {
            let untar = self.runner.run(
                &Cmd::new(Program::Tar)
                    .arg("-xkf")
                    .arg(self.paths.work.join("in").join(archive))
                    .cwd(tree),
            )?;
            if !untar.ok() {
                return Err(infra("Source1 collides with an upstream file"));
            }
        }
        let skip = |path: &str| {
            self.run_ok(
                &g().args(["update-index", "--skip-worktree", "--", path]),
                "git update-index failed",
            )
        };
        for (from, to) in &pkg.env.prep_moved {
            if let Some(parent) = Path::new(to).parent() {
                fs::create_dir_all(&tree.join(parent))?;
            }
            std::fs::rename(tree.join(from), tree.join(to))
                .map_err(|e| fs::io_error("cannot move", &tree.join(from), &e))?;
            skip(from)?;
        }
        for m in &pkg.env.prep_deleted {
            std::fs::remove_file(tree.join(m))
                .map_err(|e| fs::io_error("cannot remove", &tree.join(m), &e))?;
            skip(m)?;
        }
        if self.args.source1.is_some() {
            let exclude: Vec<String> = pkg
                .env
                .source1_paths
                .iter()
                .map(|p| format!("/{p}"))
                .collect();
            fs::append(&tree.join(".git/info/exclude"), &text::join_lines(&exclude))?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::container::{Args, ModeKind, Paths};
    use crate::core::pkg_env::{OnFail, PkgEnv};
    use crate::pkg::Pkg;
    use crate::shell::cmd::StdRunner;
    use crate::shell::report::Reporter;

    fn git(dir: &Path, args: &[&str]) -> String {
        let out = std::process::Command::new("git")
            .args(["-c", "user.name=t", "-c", "user.email=t@x"])
            .arg("-C")
            .arg(dir)
            .args(args)
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
        String::from_utf8(out.stdout).unwrap()
    }

    /// The exact-tree check expects them with or without Source1.
    #[test]
    fn the_declared_prep_changes_without_source1() {
        let tree = tempfile::tempdir().unwrap();
        for f in ["data/a.css", "data/b.css"] {
            std::fs::create_dir_all(tree.path().join("data")).unwrap();
            std::fs::write(tree.path().join(f), f).unwrap();
        }
        git(tree.path(), &["init", "-q"]);
        git(tree.path(), &["add", "-A"]);
        git(tree.path(), &["commit", "-q", "-m", "prep"]);
        let pkg = Pkg {
            name: "demo".into(),
            dir: tree.path().to_path_buf(),
            env: PkgEnv {
                srpm: "demo".into(),
                on_fail: OnFail::Hold,
                family: "demo".into(),
                install: vec!["demo".into()],
                pin: None,
                mirror: Vec::new(),
                mirror_dev: Vec::new(),
                source1: None,
                source1_paths: Vec::new(),
                prep_moved: vec![("data/a.css".into(), "data/stock/a.css".into())],
                prep_deleted: vec!["data/b.css".into()],
            },
            series: Vec::new(),
            spec_edit: None,
        };
        let (runner, report) = (StdRunner::inherit(), Reporter::capturing());
        let container = Container {
            paths: Paths::default(),
            args: Args {
                mode: ModeKind::Prep,
                pkg: "demo".into(),
                nvr: None,
                n: 0,
                tool: String::new(),
                repos_base: String::new(),
                ga_reached: 0,
                source1: None,
                source1_tree: None,
                locked_evr: None,
                keep_work: false,
            },
            runner: &runner,
            report: &report,
            is_root: true,
        };
        container
            .add_source1_and_changes(tree.path(), &pkg)
            .unwrap();
        assert!(tree.path().join("data/stock/a.css").is_file());
        assert!(!tree.path().join("data/a.css").exists());
        assert!(!tree.path().join("data/b.css").exists());
        assert_eq!(
            git(tree.path(), &["ls-files", "-v"]),
            "S data/a.css\nS data/b.css\n"
        );
        assert_eq!(
            git(
                tree.path(),
                &["status", "--porcelain", "--untracked-files=no"]
            ),
            ""
        );
    }
}
