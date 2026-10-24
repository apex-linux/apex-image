//! The report of `kernel-bump`: the `CachyOS` tag, Source0, the config, BORE and the kmod's patches.

use std::path::Path;

use super::Vm;
use super::build::remove_tree;
use crate::core::bump_report::{self, Report, Same};
use crate::core::pair;
use crate::core::pins::{KernelPins, Nevra, NvidiaPins};
use crate::core::text;
use crate::error::{Result, infra};
use crate::shell::cmd::{Cmd, Program, Stderr};
use crate::shell::fs;

const BORE_PATCH: &str = "0001-bore-cachy.patch";
const CONFIG: &str = "config";

impl Vm<'_> {
    /// Fails on a tag or a Source0 that does not verify: the bump has no trusted input.
    pub(super) fn bump_report(
        &self,
        kernel: &KernelPins,
        nvidia: &NvidiaPins,
        (old, new): (&Path, &Path),
        srpm: &Nevra,
    ) -> Result<Report> {
        let pin = |value: &Option<String>, key: &str| {
            value.clone().ok_or_else(|| {
                infra(format!(
                    "kernel.env pins no {key}, so kernel-bump cannot verify the CachyOS tag"
                ))
            })
        };
        let tag_key = pin(&kernel.tag_key, "tag_key")?;
        let tag_repo = pin(&kernel.tag_repo, "tag_repo")?;
        let tag_key_url = pin(&kernel.tag_key_url, "tag_key_url")?;
        let work = self.lane_work("kernel-bump");
        remove_tree(&work)?;
        let (old_dir, new_dir) = (work.join("old"), work.join("new"));
        self.unpack_srpm(old, &old_dir)?;
        self.unpack_srpm(new, &new_dir)?;
        let tag = pair::tag_of(srpm);
        let source0 = format!("{tag}.tar.gz");
        if !new_dir.join(&source0).is_file() {
            return Err(infra(format!("{srpm} holds no Source0 {source0}")));
        }
        self.verify_tag(&tag, (&tag_key, &tag_key_url), &tag_repo)?;
        self.check_archive(&tag, &new_dir.join(&source0))?;
        let read = |dir: &Path, name: &str| fs::read(&dir.join(name));
        let sha = |dir: &Path, name: &str| fs::sha256_file(&dir.join(name));
        let config = bump_report::config_diff(&read(&old_dir, CONFIG)?, &read(&new_dir, CONFIG)?);
        let bore = Same::of(&sha(&old_dir, BORE_PATCH)?, &sha(&new_dir, BORE_PATCH)?);
        let kmod = self
            .settings
            .store
            .join("mirror")
            .join(nvidia.kmod_srpm.file_name());
        let nvidia_patches = if kmod.is_file() {
            Some(self.patches_of(&kmod)?)
        } else {
            None
        };
        if !self.settings.keep_work {
            remove_tree(&work)?;
        }
        Ok(Report {
            from: kernel.srpm.nvr(),
            to: srpm.nvr(),
            tag,
            tag_key,
            source0,
            config,
            bore,
            nvidia_patches,
        })
    }

    fn unpack_srpm(&self, srpm: &Path, dir: &Path) -> Result<()> {
        fs::create_dir_all(dir)?;
        let (a, b) = self.runner.pipe(
            &Cmd::new(Program::Rpm2cpio).arg(srpm),
            &Cmd::new(Program::Cpio)
                .args(["-idm", "--quiet", "--no-absolute-filenames"])
                .cwd(dir),
        )?;
        if !a.ok() || !b.ok() {
            return Err(infra(format!("cannot unpack {}", srpm.display())));
        }
        Ok(())
    }

    /// The tag is fetched into a bare mirror and checked in a keyring of the pinned key alone.
    fn verify_tag(
        &self,
        tag: &str,
        (tag_key, key_url): (&str, &str),
        repo_url: &str,
    ) -> Result<()> {
        let key = self.mirror_key(tag_key, key_url)?;
        let repo = self.settings.store.join("mirror/cachyos-linux.git");
        if !repo.join("HEAD").is_file() {
            self.run_ok(
                &Cmd::new(Program::Git)
                    .args(["init", "-q", "--bare"])
                    .arg(&repo),
            )?;
        }
        self.run_ok(
            &Self::git_in(&repo)
                .args(["fetch", "-q", "--depth", "1", "--no-tags", "--", repo_url])
                .arg(format!("+refs/tags/{tag}:refs/tags/{tag}")),
        )?;
        let home =
            tempfile::tempdir().map_err(|e| infra(format!("cannot create a gpg home: {e}")))?;
        self.run_ok(
            &Cmd::new(Program::Gpg)
                .arg("--homedir")
                .arg(home.path())
                .args(["--batch", "--quiet", "--import", "--"])
                .arg(&key),
        )?;
        let out = self.runner.run(
            &Self::git_in(&repo)
                .args(["verify-tag", "--raw", tag])
                .env("GNUPGHOME", home.path())
                .capture()
                .stderr(Stderr::Capture),
        )?;
        if !out.ok() || !bump_report::tag_signed_by(&out.stderr, tag_key) {
            return Err(infra(format!(
                "the CachyOS tag {tag} has no good signature by {tag_key} (git verify-tag, exit {}): {}",
                out.code,
                text::lossy(text::tail_lines(&out.stderr, 5))
            )));
        }
        Ok(())
    }

    /// Both uncompressed, so gzip's own bytes never decide; the prefix is the tarball's own.
    fn check_archive(&self, tag: &str, source0: &Path) -> Result<()> {
        let listed = self.run_ok(
            &Cmd::new(Program::Tar)
                .arg("-tzf")
                .arg(source0)
                .capture()
                .stderr(Stderr::Null),
        )?;
        let prefix = text::lines(&listed.stdout)
            .into_iter()
            .next()
            .map(|l| {
                text::lossy(l)
                    .split('/')
                    .next()
                    .unwrap_or_default()
                    .to_owned()
            })
            .filter(|p| !p.is_empty())
            .ok_or_else(|| infra(format!("{} lists no top directory", source0.display())))?;
        let repo = self.settings.store.join("mirror/cachyos-linux.git");
        let same = self.runner.run(
            &Cmd::new(Program::Bash)
                .args([
                    "-c",
                    "set -o pipefail; cmp -s -- <(gzip -dc -- \"$1\") <(git -C \"$2\" archive --format=tar --prefix=\"$3/\" \"$4\")",
                    "bash",
                ])
                .arg(source0)
                .arg(&repo)
                .args([prefix.as_str(), tag]),
        )?;
        if !same.ok() {
            return Err(infra(format!(
                "{} is not the CachyOS tag {tag}'s git archive (cmp exit {})",
                fs::file_name(source0),
                same.code
            )));
        }
        Ok(())
    }

    fn patches_of(&self, srpm: &Path) -> Result<Vec<String>> {
        let out = self.run_ok(
            &Cmd::new(Program::Rpm)
                .args([
                    "-qp",
                    "--nosignature",
                    "--queryformat",
                    "[%{PATCH}\\n]",
                    "--",
                ])
                .arg(srpm)
                .capture(),
        )?;
        Ok(text::lines(&out.stdout)
            .into_iter()
            .map(|l| text::lossy(l).trim().to_owned())
            .filter(|l| !l.is_empty())
            .collect())
    }
}
