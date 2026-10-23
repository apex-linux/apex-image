use std::path::Path;
use std::time::Instant;

use super::Vm;
use super::checkout::{Mode, Source1};
use super::sign::Signer;
use crate::core::hold::{self, FailureRoute, Timer};
use crate::core::lock;
use crate::core::manifest::{self, header_field};
use crate::core::names::is_content_key;
use crate::core::pkg_env::OnFail;
use crate::core::text;
use crate::core::utc::UtcSecond;
use crate::error::{Result, infra, usage};
use crate::pkg::{self, Parse, Pkg};
use crate::shell::cmd::{Cmd, Program};
use crate::shell::fs;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Outcome {
    Built(String),
    Unchanged(String),
    Held,
    Degraded,
    KeptStock,
}

impl Outcome {
    pub fn shippable(&self) -> bool {
        matches!(self, Self::Built(_) | Self::Unchanged(_))
    }
}

impl Vm<'_> {
    pub fn load(&self, name: &str) -> Result<Pkg> {
        let pkg = pkg::load(&self.recipe_root_of(name)?, name, Parse::Full)?;
        pkg::check_family_unique(&self.recipe_roots(), &pkg)?;
        Ok(pkg)
    }

    pub fn build(&self, target: &str) -> Result<Vec<Outcome>> {
        let pkgs = if target == "all" {
            let all = self.all_pkgs()?;
            if all.is_empty() {
                return Err(usage("no package has a pkg.env under packaging/pkgs"));
            }
            all
        } else {
            vec![target.to_owned()]
        };
        let _lock = fs::lock_store(&self.settings.store)?;
        let signer = self.signer()?;
        pkgs.iter().map(|p| self.build_one(p, &signer)).collect()
    }

    pub fn build_one(&self, name: &str, signer: &Signer) -> Result<Outcome> {
        let pkg = self.load(name)?;
        self.check_committed(&pkg)?;
        let start = Instant::now();
        let n = self.release_n(&pkg)?;
        let tool = self.tool_id()?;
        let locked = fs::read_opt(&self.lock_file())?.unwrap_or_default();
        let locked_evr = text::lossy(&lock::locked_evr(&locked, &pkg.env.family, &pkg.env.srpm));
        let work = self.lane_work(&pkg.name);
        self.fresh_work_dir(&work, &["in", "out"])?;
        let source1 = self.stage_source1(&pkg, &work.join("in"))?;
        self.report.group(&format!(
            "{}: Fedora's SRPM through the lane (N={n}{})",
            pkg.name,
            source1
                .as_ref()
                .map(|s: &Source1| format!(", Source1 {}", s.archive))
                .unwrap_or_default()
        ));
        let rc = self.run_container(
            &pkg,
            &work,
            &Mode::Build {
                n,
                tool,
                locked_evr,
            },
            source1.as_ref(),
        );
        self.report.endgroup();
        self.own(&work)?;
        match rc? {
            0 => {}
            3 => return self.record_failure(&pkg, &work.join("out")),
            2 => {
                return Err(usage(format!(
                    "the {} build container refused its inputs (exit 2)",
                    pkg.name
                )));
            }
            _ => {
                return Err(infra(format!(
                    "the {} build container failed (exit 1)",
                    pkg.name
                )));
            }
        }
        let out = work.join("out");
        let key_of = |file: &str| -> Result<String> {
            let key = text::lossy(text::chomp(&fs::read(&out.join(file))?));
            if !is_content_key(&key) {
                return Err(infra(format!(
                    "the container wrote '{key}' to {file}, not a content key"
                )));
            }
            Ok(key)
        };
        if out.join("unchanged").is_file() {
            let key = key_of("unchanged")?;
            let stored = self.store_pkg(&pkg.name).join(&key);
            Self::verify_stored(&stored)?;
            signer.check_stored(&stored)?;
            self.record_built(&pkg, &key)?;
            self.report.summary(&[
                format!("### {}: unchanged", pkg.name),
                String::new(),
                format!("The key `{key}` is already stored; rpms.lock.next takes it."),
            ]);
            return Ok(Outcome::Unchanged(key));
        }
        let key = key_of("key.txt")?;
        let stored = self.store_pkg(&pkg.name).join(&key);
        if stored.symlink_metadata().is_ok() {
            return Err(infra(format!(
                "store: {} exists, but the container built it again",
                stored.display()
            )));
        }
        self.sign_built(&out, signer)?;
        let partial = self.store_pkg(&pkg.name).join(format!(".partial-{key}"));
        remove_tree(&partial)?;
        self.move_tree(&out, &partial)?;
        self.move_tree(&partial, &stored)?;
        Self::verify_stored(&stored)?;
        self.record_built(&pkg, &key)?;
        let manifest_text = fs::read(&stored.join("manifest.txt"))?;
        self.report.summary(&[
            format!("### {}: built in {} s", pkg.name, start.elapsed().as_secs()),
            String::new(),
            "```".into(),
            text::lossy(text::chomp(&manifest_text)),
            "```".into(),
        ]);
        Ok(Outcome::Built(key))
    }

    fn move_tree(&self, from: &Path, to: &Path) -> Result<()> {
        match std::fs::rename(from, to) {
            Ok(()) => Ok(()),
            Err(e) if e.raw_os_error() == Some(nix::libc::EXDEV) => {
                self.run_ok(&Cmd::new(Program::Cp).arg("-a").arg("--").arg(from).arg(to))?;
                remove_tree(from)
            }
            Err(e) => Err(fs::io_error("cannot move", from, &e)),
        }
    }

    pub fn verify_stored(dir: &Path) -> Result<()> {
        let manifest_text = fs::read(&dir.join("manifest.txt"))?;
        for e in manifest::entries(&manifest_text) {
            if !manifest::is_stored_kind(e.kind) {
                continue;
            }
            let path = dir.join(text::lossy(e.file));
            let shown = format!("{}/{}", dir.display(), text::lossy(e.file));
            if !path.is_file() {
                return Err(infra(format!("store: {shown} is missing")));
            }
            if fs::sha256_file(&path)?.as_bytes() != e.sha256 {
                return Err(infra(format!(
                    "store: {shown} does not match its manifest sha256"
                )));
            }
        }
        Ok(())
    }

    fn lock_put(&self, family: &str, line: &[u8], rpms: &[u8]) -> Result<()> {
        let path = self.next_lock_file();
        let old = fs::read_opt(&path)?;
        fs::atomic_write(&path, &lock::put(old.as_deref(), family, line, rpms))
    }

    pub fn record_built(&self, pkg: &Pkg, key: &str) -> Result<()> {
        let dir = self.store_pkg(&pkg.name).join(key);
        let path = dir.join("manifest.txt");
        let rpms = lock::manifest_lock_rpms(
            &path.display().to_string(),
            &fs::read(&path)?,
            &pkg.env.family,
            &format!("pkgs/{}/{key}", pkg.name),
            &pkg.env.install,
        )
        .map_err(|e| infra(e.to_string()))?;
        let n = lock::built_count(&rpms);
        if n != pkg.env.install.len() {
            return Err(infra(format!(
                "store: {key} has {n} of the {} install= packages ({})",
                pkg.env.install.len(),
                pkg.env.install.join(" ")
            )));
        }
        self.lock_put(&pkg.env.family, format!("built {key}").as_bytes(), &rpms)
    }

    pub fn record_failure(&self, pkg: &Pkg, out: &Path) -> Result<Outcome> {
        let family = pkg.env.family.as_str();
        let failed = fs::read_opt(&out.join("failed.txt"))?;
        let reason = hold::reason_of(failed.as_deref());
        let now = self.clock.now();
        let store = self.store_pkg(&pkg.name);
        fs::create_dir_all(&store)?;
        if let Some(failed) = &failed {
            fs::write(&store.join("last-failure.txt"), failed)?;
        }
        let next_text = fs::read_opt(&self.next_lock_file())?.unwrap_or_default();
        let current = lock::family_line(&next_text, family);
        match hold::route_failure(pkg.env.on_fail == OnFail::Degrade, &current, &reason, now) {
            FailureRoute::Degrade { line } => {
                self.lock_put(family, &line, b"")?;
                self.report
                    .summary(&hold::summary_degraded(&pkg.name, family, &reason));
                return Ok(Outcome::Degraded);
            }
            FailureRoute::StayStock => {
                self.report
                    .summary(&hold::summary_stays_stock(&pkg.name, family, &reason));
                return Ok(Outcome::KeptStock);
            }
            FailureRoute::Hold => {}
        }
        let lock_text = fs::read_opt(&self.lock_file())?.unwrap_or_default();
        let Some(good_key) = hold::good_key(&lock::family_line(&lock_text, family)) else {
            return Err(infra(format!(
                "{}: {}. rpms.lock has no last good build of the {family} family to hold, so the image build stops. Fix the series, or ship Fedora's build: just pkg-stock {}",
                pkg.name,
                text::lossy(&reason),
                pkg.name
            )));
        };
        let good_manifest = store.join(&good_key).join("manifest.txt");
        if !good_manifest.is_file() {
            return Err(infra(format!(
                "store: the last good build {good_key} of {family} is missing ({})",
                good_manifest.display()
            )));
        }
        let good = fs::read(&good_manifest)?;
        let attempt = fs::read_opt(&out.join("attempt.txt"))?.unwrap_or_default();
        let newer = hold::newer(
            &attempt,
            &header_field(&good, "stock"),
            &header_field(&good, "pin"),
        );
        let newer_csv = newer.join(",");
        let since = hold::since(&current, &newer_csv, now);
        let timer = if newer.is_empty() {
            None
        } else {
            let security = newer
                .iter()
                .map(|nvr| hold::Security::of_types(&self.bodhi.types(nvr)))
                .fold(hold::Security::No, std::cmp::max);
            let start = UtcSecond::parse(&since).ok_or_else(|| {
                infra(format!(
                    "rpms.lock.next: the hold of {family} started at '{}', which is not a UTC time",
                    text::lossy(&since)
                ))
            })?;
            Some(Timer {
                limit: security.limit(start),
                security,
            })
        };
        let line = hold::held_line(&good_key, &since, &newer_csv, timer.as_ref(), &reason);
        self.lock_put(family, &line, &lock::rpm_lines(&lock_text, family))?;
        self.report.summary(&hold::summary_held(
            &pkg.name,
            &reason,
            &good_key,
            &since,
            &newer,
            timer.as_ref(),
            self.clock.now(),
        ));
        Ok(Outcome::Held)
    }

    pub fn stock(&self, name: &str) -> Result<()> {
        let pkg = self.load(name)?;
        let _lock = fs::lock_store(&self.settings.store)?;
        let family = &pkg.env.family;
        let line = format!(
            "stock - since={} reason={}",
            self.clock.now(),
            hold::STOCK_REASON
        );
        self.lock_put(family, line.as_bytes(), b"")?;
        self.report.summary(&[
            format!("### {family}: stock"),
            String::new(),
            format!("The next image takes Fedora's build of the {family} family, with no Apex RPM, until a lane build succeeds again."),
        ]);
        Ok(())
    }
}

fn remove_tree(path: &Path) -> Result<()> {
    match std::fs::remove_dir_all(path) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(fs::io_error("cannot remove", path, &e)),
    }
}

pub fn exit_of(outcomes: &[Outcome]) -> crate::Exit {
    if outcomes.iter().all(Outcome::shippable) {
        crate::Exit::Ok
    } else {
        crate::Exit::NoShippableBuild
    }
}
