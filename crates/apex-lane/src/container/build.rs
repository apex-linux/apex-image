use std::path::{Path, PathBuf};
use std::time::Instant;

use super::{Attempt, Container, RETRY_DELAY, Setup, Stock};
use crate::core::exact_tree::prune_dirs;
use crate::core::manifest::{self, Header};
use crate::core::names::is_release_value;
use crate::core::release::{self, StoredBuild};
use crate::core::rpmout;
use crate::core::spec_edit::{self, ApplyError, Values};
use crate::core::text;
use crate::error::{Result, infra};
use crate::shell::cmd::{Cmd, Program, Stderr, Stdout, retry};
use crate::shell::fs;

struct Work {
    dir: PathBuf,
    top: PathBuf,
    logs: PathBuf,
    _tmp: Option<tempfile::TempDir>,
}

impl Work {
    fn spec_define(&self) -> [String; 2] {
        ["--define".into(), format!("_topdir {}", self.top.display())]
    }
}

struct Build<'s> {
    setup: &'s Setup,
    stock: &'s Stock,
    attempt: Attempt,
    key: String,
    release: String,
    work: Work,
    srpm: PathBuf,
    spec: PathBuf,
    mirrors: Vec<(String, String)>,
}

impl Container<'_> {
    pub(super) fn build(&self) -> Result<()> {
        let t0 = Instant::now();
        let setup = self.setup()?;
        let stock = self.resolve(&setup, None)?;
        let (key, preimage) = self.key(&setup, &stock)?;
        if self.paths.store.join(&key).join("manifest.txt").is_file() {
            self.report
                .log(&format!("key {key} is already stored: unchanged"));
            return fs::write(
                &self.paths.out().join("unchanged"),
                format!("{key}\n").as_bytes(),
            );
        }
        let base = release::base(&stock.release, self.args.n);
        let stored = stored_builds(&self.paths.store)?;
        let release = text::lossy(&release::release_for(&stored, &stock.nvr, &base, &key));
        if !is_release_value(&release) {
            return Err(infra(format!("the store gives the release '{release}'")));
        }
        self.report
            .log(&format!("key {key}; release {}-{release}", stock.version));
        let mut timings = vec![("setup-resolve", t0.elapsed().as_secs())];
        let work = self.work_dir()?;
        let mut b = Build {
            setup: &setup,
            stock: &stock,
            attempt: Attempt {
                stock: Some(stock.nvr.clone()),
                key: Some(key.clone()),
            },
            key,
            release,
            srpm: PathBuf::new(),
            spec: PathBuf::new(),
            mirrors: Vec::new(),
            work,
        };
        timed(&mut timings, "download", || self.download(&mut b))?;
        timed(&mut timings, "pristine-prep", || self.pristine(&mut b))?;
        self.edit_spec(&b)?;
        timed(&mut timings, "builddep", || self.builddep(&b))?;
        timed(&mut timings, "apex-prep", || self.patched_prep(&b))?;
        timed(&mut timings, "rpmbuild", || self.rpmbuild(&b))?;
        timed(&mut timings, "checks", || self.lane_checks(&b))?;
        self.outputs(&b, &preimage)?;
        timings.push(("total", t0.elapsed().as_secs()));
        let lines: Vec<String> = timings.iter().map(|(n, s)| format!("{n} {s}")).collect();
        fs::write(
            &self.paths.out().join("timings.txt"),
            &text::join_lines(&lines),
        )?;
        self.report
            .log(&format!("timings (s): {}", lines.join(" ")));
        Ok(())
    }

    fn work_dir(&self) -> Result<Work> {
        let (dir, tmp) = if self.args.keep_work {
            let dir = self.paths.work.join("work");
            if dir.exists() {
                std::fs::remove_dir_all(&dir)
                    .map_err(|e| fs::io_error("cannot remove", &dir, &e))?;
            }
            fs::create_dir_all(&dir)?;
            (dir, None)
        } else {
            let tmp = tempfile::Builder::new()
                .prefix("apex-lane.")
                .tempdir()
                .map_err(|e| infra(format!("cannot create a work directory: {e}")))?;
            (tmp.path().to_path_buf(), Some(tmp))
        };
        let logs = self.paths.out().join("logs");
        fs::create_dir_all(&dir.join("dl"))?;
        fs::create_dir_all(&logs)?;
        Ok(Work {
            top: dir.join("rpmbuild"),
            dir,
            logs,
            _tmp: tmp,
        })
    }

    fn download(&self, b: &mut Build<'_>) -> Result<()> {
        self.report.group("Download and verify");
        b.srpm = self.fetch_srpm(b.setup, b.stock, &b.work.dir.join("dl"))?;
        b.mirrors = self.mirror_nevras(b.setup, b.stock)?;
        if !b.mirrors.is_empty() {
            let dir = b.work.dir.join("mirror");
            fs::create_dir_all(&dir)?;
            let download = Self::dnf_bin(&b.setup.repos)
                .arg("download")
                .arg(format!("--destdir={}", dir.display()))
                .args(b.mirrors.iter().map(|(_, n)| rpmout::download_spec(n)))
                .stdout(Stdout::Null);
            if !retry(self.runner, self.report, 3, RETRY_DELAY, &download)?.ok() {
                return Err(infra("cannot download the mirror RPMs"));
            }
            for (_, nevra) in &b.mirrors {
                let f = mirror_file(&b.work, nevra);
                if !f.is_file() {
                    return Err(infra(format!("dnf did not download {nevra}")));
                }
                self.verify(b.setup, &f)?;
            }
            let all: Vec<&str> = b.mirrors.iter().map(|(_, n)| n.as_str()).collect();
            self.report.log(&format!(
                "mirror RPMs signed by the Fedora key: {}",
                all.join(" ")
            ));
        }
        self.report.endgroup();
        Ok(())
    }

    fn mirror_nevras(&self, setup: &Setup, stock: &Stock) -> Result<Vec<(String, String)>> {
        let env = &setup.pkg.env;
        let mut out = Vec::new();
        let wanted = env
            .mirror
            .iter()
            .map(|n| ("mirror", n))
            .chain(env.mirror_dev.iter().map(|n| ("dev", n)));
        for (kind, name) in wanted {
            let pin = stock
                .pin
                .as_ref()
                .ok_or_else(|| infra("mirror= needs a pin"))?;
            let query = self.run_ok(
                &Self::dnf_bin(&setup.repos)
                    .arg("repoquery")
                    .arg(format!("--arch={},noarch", setup.arch))
                    .args(["--queryformat", rpmout::MIRROR_FORMAT])
                    .arg(name)
                    .capture(),
                "repoquery failed",
            )?;
            let hits =
                rpmout::mirror_nevras(&query.stdout, &pin.evr, &format!("{}.src.rpm", pin.nvr));
            let Some(nevra) = rpmout::one_line(&hits) else {
                return Err(infra(format!(
                    "expected one {name} at {} {}, got: '{}'",
                    pin.name,
                    pin.evr,
                    text::lossy(text::chomp(&hits))
                )));
            };
            out.push((kind.to_owned(), text::lossy(nevra)));
        }
        Ok(out)
    }

    fn vercmp(&self, a: &str, b: &str) -> Result<String> {
        if !is_release_value(a) || !is_release_value(b) {
            return Err(infra(format!(
                "cannot compare '{a}' and '{b}' with rpm.vercmp"
            )));
        }
        self.rpm_eval(&format!("%{{lua: print(rpm.vercmp('{a}', '{b}'))}}"))
    }

    fn spec_version_release(&self, b: &Build<'_>) -> Result<String> {
        let out = self.run_ok(
            &Cmd::new(Program::Rpmspec)
                .args(["-q", "--srpm", "--queryformat", "%{version}-%{release}\\n"])
                .args(b.work.spec_define())
                .arg("--")
                .arg(&b.spec)
                .capture(),
            "rpmspec failed",
        )?;
        Ok(text::lossy(text::chomp(&out.stdout)))
    }

    fn pristine(&self, b: &mut Build<'_>) -> Result<()> {
        self.report
            .group("Unpack, release arithmetic, pristine %prep");
        b.spec = self.unpack(&b.srpm, &b.work.top)?;
        fs::copy_with_mode(&b.spec, &b.work.dir.join("stock.spec"))?;
        let stock = b.stock;
        let dist = self.rpm_eval("%{?dist}")?;
        let fedora = self.rpm_eval("%fedora")?;
        if dist != format!(".fc{fedora}") || !stock.release.ends_with(&dist) {
            return Err(infra(format!(
                "stock release {} does not end in the container's %dist {dist}",
                stock.release
            )));
        }
        let mut stock_evr = format!("{}-{}", stock.version, stock.release);
        let mut apex_evr = format!("{}-{}", stock.version, b.release);
        let got = self.spec_version_release(b)?;
        if got != stock_evr {
            return Err(infra(format!(
                "Fedora's spec gives {got}, Fedora built {stock_evr} (is %autorelease expanded in the SRPM?)"
            )));
        }
        for (a, c) in [
            ("1-1.fc45.apex1", "1-1.fc45"),
            ("1-2.fc45", "1-1.fc45.apex1"),
            ("1-1.fc45.apex3.1", "1-1.fc45.apex3"),
            ("1-1.fc45.apex4", "1-1.fc45.apex3.1"),
        ] {
            if self.vercmp(a, c)? != "1" {
                return Err(infra(
                    "rpm.vercmp does not order the release suffixes as expected",
                ));
            }
        }
        if stock.epoch != "0" {
            stock_evr = format!("{}:{stock_evr}", stock.epoch);
            apex_evr = format!("{}:{apex_evr}", stock.epoch);
        }
        if self.vercmp(&apex_evr, &stock_evr)? != "1" {
            return Err(infra(format!("{apex_evr} does not sort above {stock_evr}")));
        }
        if let Some(locked) = self.args.locked_evr.as_deref().filter(|l| !l.is_empty())
            && self.vercmp(&apex_evr, locked)? != "1"
        {
            return Err(infra(format!(
                "{apex_evr} does not sort above the locked build {locked} (an older commit, or Fedora withdrew a build)"
            )));
        }
        let log = b.work.logs.join("prep-stock.log");
        let prep = self.runner.run(
            &Cmd::new(Program::Rpmbuild)
                .args(b.work.spec_define())
                .args(["--nodeps", "-bp"])
                .arg(&b.spec)
                .log_to(&log),
        )?;
        if !prep.ok() {
            self.report
                .raw(text::tail_lines(&fs::read(&log).unwrap_or_default(), 40));
            return Err(infra(
                "Fedora's %prep fails without any Apex input: the container or the SRPM is broken",
            ));
        }
        let src = Self::srcdir(&b.work.top).ok_or_else(|| {
            infra(format!(
                "no single source tree under {}/BUILD after %prep",
                b.work.top.display()
            ))
        })?;
        self.copy_tree(&src, &b.work.dir.join("pristine"))?;
        Self::empty_build_dir(&b.work.top)?;
        self.report.endgroup();
        Ok(())
    }

    fn edit_spec(&self, b: &Build<'_>) -> Result<()> {
        self.report.group("spec-edit and the series");
        let pkg = &b.setup.pkg;
        let fail = |reason: &str| self.fail(&b.attempt, reason.as_bytes(), None);
        let stock_spec = fs::read(&b.spec)?;
        if !spec_edit::uses_autosetup(&stock_spec) {
            return Err(fail(
                "Fedora's spec no longer uses %autosetup or %autopatch; the Patch lines would be ignored",
            ));
        }
        if spec_edit::has_patch_1nnn(&stock_spec) {
            return Err(fail(
                "Fedora's spec already uses a Patch1NNN number, which the series needs",
            ));
        }
        let sources = b.work.top.join("SOURCES");
        if let Some(archive) = &self.args.source1 {
            fs::copy_with_mode(
                &self.paths.work.join("in").join(archive),
                &sources.join(archive),
            )?;
        }
        let values = Values {
            apex_release: release::suffix(&b.release, &b.stock.release).to_owned(),
            pin_evr: b
                .stock
                .pin
                .as_ref()
                .map(|p| p.evr.clone())
                .unwrap_or_default(),
            source1: self.args.source1.clone().unwrap_or_default(),
        };
        let edit = pkg
            .spec_edit
            .as_ref()
            .ok_or_else(|| infra("spec-edit was not parsed"))?;
        let mut log = |line: Vec<u8>| {
            self.report.raw(&line);
            self.report.raw(b"\n");
        };
        let edited = match spec_edit::apply(edit, &stock_spec, &values, &mut log) {
            Ok(spec) => spec,
            Err(e @ ApplyError::Anchor { .. }) => {
                let reason = e.reason();
                self.report.raw(&reason);
                self.report.raw(b"\n");
                return Err(self.fail(&b.attempt, &reason, None));
            }
            Err(e) => return Err(infra(text::lossy(&e.reason()))),
        };
        for p in &pkg.series {
            fs::install_0644(&pkg.patch(p), &sources.join(format!("apex-{p}")))?;
        }
        let Ok(edited) =
            spec_edit::insert_patch_lines(&edited, &spec_edit::patch_lines(&pkg.series))
        else {
            self.report
                .log("no Patch or Source line in the spec to add the series after");
            return Err(fail("no Patch or Source line in Fedora's spec"));
        };
        fs::write(&b.spec, &edited)?;
        self.write_spec_diff(b)?;
        self.check_edited_spec(b)?;
        self.report.endgroup();
        Ok(())
    }

    fn write_spec_diff(&self, b: &Build<'_>) -> Result<()> {
        let spec_name = fs::file_name(&b.spec);
        let diff = self.runner.run(
            &Cmd::new(Program::Diff)
                .arg("-u")
                .arg("--label")
                .arg(format!("{}/{spec_name}", b.stock.nvr))
                .arg("--label")
                .arg(format!("apex/{spec_name}"))
                .arg(b.work.dir.join("stock.spec"))
                .arg(&b.spec)
                .capture(),
        )?;
        fs::write(&self.paths.out().join("spec.diff"), &diff.stdout)?;
        self.report.raw(&diff.stdout);
        Ok(())
    }

    fn check_edited_spec(&self, b: &Build<'_>) -> Result<()> {
        let fail = |reason: &str| self.fail(&b.attempt, reason.as_bytes(), None);
        let want = format!("{}-{}", b.stock.version, b.release);
        let got = self.spec_version_release(b)?;
        if got != want {
            return Err(fail(&format!(
                "the edited spec gives {got}, not {want} (the Release edit)"
            )));
        }
        if let Some(pin) = &b.stock.pin {
            let isa = self.rpm_eval("%{_isa}")?;
            let query = |what: &str, stderr: Stderr| {
                self.run_ok(
                    &Cmd::new(Program::Rpmspec)
                        .args(["-q", what])
                        .args(b.work.spec_define())
                        .arg("--")
                        .arg(&b.spec)
                        .capture()
                        .stderr(stderr),
                    &format!("rpmspec {what} failed"),
                )
            };
            let build_requires = format!("{}-devel = {}", pin.name, pin.evr);
            if !rpmout::has_line(
                &query("--buildrequires", Stderr::Inherit)?.stdout,
                &build_requires,
            ) {
                return Err(fail(&format!(
                    "the edited spec does not BuildRequire {build_requires}"
                )));
            }
            let requires = format!("{}{isa} = {}", pin.name, pin.evr);
            if !rpmout::has_line(&query("--requires", Stderr::Null)?.stdout, &requires) {
                return Err(fail(&format!(
                    "the edited spec does not Require {requires}"
                )));
            }
        }
        Ok(())
    }

    fn builddep(&self, b: &Build<'_>) -> Result<()> {
        self.report.group("Build dependencies");
        let log = b.work.logs.join("builddep.log");
        fs::write(&log, b"")?;
        let builddep = Self::dnf_bin(&b.setup.repos)
            .arg("builddep")
            .args(b.work.spec_define())
            .arg(&b.spec)
            .stdout(Stdout::Append(log.clone()))
            .stderr(Stderr::ToStdout);
        if !retry(self.runner, self.report, 2, RETRY_DELAY, &builddep)?.ok() {
            self.report
                .raw(text::tail_lines(&fs::read(&log).unwrap_or_default(), 30));
            return Err(infra("dnf5 builddep failed"));
        }
        if let Some(pin) = &b.stock.pin {
            let out = self.runner.run(
                &Cmd::new(Program::Rpm)
                    .args(["-q", "--queryformat", "%{evr}\\n"])
                    .arg(format!("{}-devel", pin.name))
                    .capture(),
            )?;
            let got = text::lossy(text::chomp(&out.stdout));
            if !out.ok() || got != pin.evr {
                return Err(infra(format!(
                    "the buildroot has {}-devel {got}, not {}",
                    pin.name, pin.evr
                )));
            }
        }
        self.report.endgroup();
        Ok(())
    }

    fn patched_prep(&self, b: &Build<'_>) -> Result<()> {
        self.report.group("Patched %prep, and the exact tree");
        let log = b.work.logs.join("prep-apex.log");
        let prep = self.runner.run(
            &Cmd::new(Program::Rpmbuild)
                .args(b.work.spec_define())
                .arg("-bp")
                .arg(&b.spec)
                .log_to(&log),
        )?;
        if !prep.ok() {
            let reason = self.culprit(b)?;
            return Err(self.fail(&b.attempt, reason.as_bytes(), Some(&log)));
        }
        let src = Self::srcdir(&b.work.top).ok_or_else(|| {
            infra(format!(
                "no single source tree under {}/BUILD after the patched %prep",
                b.work.top.display()
            ))
        })?;
        self.exact_tree(b, &src)?;
        Self::empty_build_dir(&b.work.top)?;
        self.report.endgroup();
        Ok(())
    }

    /// The first series entry that does not apply after the ones before it: a rebase
    /// conflict names its feature.
    fn culprit(&self, b: &Build<'_>) -> Result<String> {
        let t = b.work.dir.join("culprit");
        let _ = std::fs::remove_dir_all(&t);
        self.copy_tree(&b.work.dir.join("pristine"), &t)?;
        let pkg = &b.setup.pkg;
        let mut reason = format!(
            "spec-edit's %prep lines fail on {} (the series applies)",
            b.stock.nvr
        );
        for p in &pkg.series {
            let out = self.runner.run(
                &git_apply(&t)
                    .args(["-p1", "--"])
                    .arg(pkg.patch(p))
                    .stdout(Stdout::Null)
                    .stderr(Stderr::Null),
            )?;
            if !out.ok() {
                reason = format!("{p} does not apply to {}", b.stock.nvr);
                break;
            }
        }
        let _ = std::fs::remove_dir_all(&t);
        Ok(reason)
    }

    /// Every Apex input undone on a copy of the patched tree leaves the pristine one.
    fn exact_tree(&self, b: &Build<'_>, src: &Path) -> Result<()> {
        let pkg = &b.setup.pkg;
        let env = &pkg.env;
        let pristine = b.work.dir.join("pristine");
        let r = b.work.dir.join("reverted");
        let fail = |reason: String| self.fail(&b.attempt, reason.as_bytes(), None);
        self.copy_tree(src, &r)?;
        for p in pkg.series.iter().rev() {
            let out = self
                .runner
                .run(&git_apply(&r).args(["-R", "-p1", "--"]).arg(pkg.patch(p)))?;
            if !out.ok() {
                return Err(fail(format!(
                    "{p} is not applied as written in the %prep tree"
                )));
            }
        }
        for (from, to) in &env.prep_moved {
            if r.join(from).exists() {
                return Err(fail(format!("%prep did not move {from}")));
            }
            if !r.join(to).is_file() {
                return Err(fail(format!("%prep did not move {from} to {to}")));
            }
            match (
                std::fs::read(r.join(to)),
                std::fs::read(pristine.join(from)),
            ) {
                (Ok(a), Ok(b)) if a == b => {}
                _ => return Err(fail(format!("{to} differs from Fedora's {from}"))),
            }
            std::fs::rename(r.join(to), r.join(from))
                .map_err(|e| fs::io_error("cannot move", &r.join(to), &e))?;
        }
        for m in &env.prep_deleted {
            if r.join(m).exists() {
                return Err(fail(format!("%prep did not delete {m}")));
            }
            if !pristine.join(m).is_file() {
                return Err(fail(format!("Fedora's tree has no {m} to delete")));
            }
            std::fs::copy(pristine.join(m), r.join(m))
                .map_err(|e| fs::io_error("cannot copy", &pristine.join(m), &e))?;
        }
        let members = match &self.args.source1 {
            Some(archive) => {
                let out = self.run_ok(
                    &Cmd::new(Program::Tar)
                        .arg("-tf")
                        .arg(b.work.top.join("SOURCES").join(archive))
                        .capture(),
                    "tar -tf failed",
                )?;
                text::lines(&out.stdout)
                    .into_iter()
                    .map(text::lossy)
                    .collect()
            }
            None => Vec::new(),
        };
        for m in members.iter().filter(|m| !m.ends_with('/')) {
            match std::fs::remove_file(r.join(m)) {
                Ok(()) => {}
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                Err(e) => return Err(fs::io_error("cannot remove", &r.join(m), &e)),
            }
        }
        let tos: Vec<String> = env.prep_moved.iter().map(|(_, to)| to.clone()).collect();
        for d in prune_dirs(&members, &tos) {
            if !pristine.join(&d).is_dir() {
                let _ = std::fs::remove_dir(r.join(&d));
            }
        }
        let diff_log = b.work.dir.join("exact.diff");
        let diff = self.runner.run(
            &Cmd::new(Program::Diff)
                .args(["-r", "-q", "--no-dereference", "--exclude=.git", "--"])
                .arg(&pristine)
                .arg(&r)
                .log_to(&diff_log),
        )?;
        if !diff.ok() {
            return Err(self.fail(
                &b.attempt,
                b"the %prep tree is not Fedora's tree plus the series, Source1 and the declared %prep changes",
                Some(&diff_log),
            ));
        }
        let _ = std::fs::remove_dir_all(&r);
        self.report.log("the %prep tree is exactly Fedora's plus the series, Source1 and the declared %prep changes");
        Ok(())
    }

    fn rpmbuild(&self, b: &Build<'_>) -> Result<()> {
        self.report
            .group(&format!("rpmbuild -ba {}-{}", b.stock.version, b.release));
        let log = b.work.logs.join("build.log");
        // No --define dist and no --nocheck: the SRPM carries its own release, and
        // Fedora's %check runs.
        let out = self.runner.run(
            &Cmd::new(Program::Rpmbuild)
                // ninja's parallel g-ir-scanner runs race on one ~/.cache store, which only
                // saves parse time: the GIRs and typelibs are the same without it.
                .env("GI_SCANNER_DISABLE_CACHE", "1")
                .args(b.work.spec_define())
                .arg("-ba")
                .arg(&b.spec)
                .log_to(&log),
        )?;
        if !out.ok() {
            let reason = format!("{} with the Apex inputs does not build", b.stock.nvr);
            return Err(self.fail(&b.attempt, reason.as_bytes(), Some(&log)));
        }
        self.report.endgroup();
        Ok(())
    }

    fn built_rpms(b: &Build<'_>) -> Result<Vec<PathBuf>> {
        fs::files_under(&b.work.top.join("RPMS"), &|name| {
            has_suffix(name, ".rpm")
                && !name.contains("-debuginfo-")
                && !name.contains("-debugsource-")
        })
    }

    fn apex_srpms(b: &Build<'_>) -> Result<Vec<PathBuf>> {
        fs::files_under(&b.work.top.join("SRPMS"), &|n| has_suffix(n, ".src.rpm"))
    }

    fn query(&self, rpm: &Path, format: &str) -> Result<String> {
        let out = self.runner.run(
            &Cmd::new(Program::Rpm)
                .args(["-qp", "--queryformat", format, "--"])
                .arg(rpm)
                .capture(),
        )?;
        Ok(text::lossy(text::chomp(&out.stdout)))
    }

    fn lane_checks(&self, b: &Build<'_>) -> Result<()> {
        self.report.group("Lane checks");
        let fail =
            |reason: String, log: Option<&Path>| self.fail(&b.attempt, reason.as_bytes(), log);
        let env = &b.setup.pkg.env;
        let stock = b.stock;
        let rpms = Self::built_rpms(b)?;
        if rpms.is_empty() {
            return Err(fail("rpmbuild produced no binary RPM".into(), None));
        }
        for f in &rpms {
            let got = self.query(f, "%{name} %{epochnum} %{version} %{release}\\n")?;
            let first = text::lines(got.as_bytes())
                .into_iter()
                .next()
                .unwrap_or_default();
            let v: Vec<String> = text::read_fields(first, 4)
                .into_iter()
                .map(text::lossy)
                .collect();
            let (ep, ver, rel) = (&v[1], &v[2], &v[3]);
            if *rel != b.release || *ver != stock.version || *ep != stock.epoch {
                return Err(fail(
                    format!(
                        "{} is {ep}:{ver}-{rel}, not {}:{}-{}",
                        fs::file_name(f),
                        stock.epoch,
                        stock.version,
                        b.release
                    ),
                    None,
                ));
            }
        }
        let names: Vec<String> = rpms.iter().map(|f| fs::file_name(f)).collect();
        let vr = format!("{}-{}", stock.version, b.release);
        for name in &env.install {
            let prefix = format!("{name}-{vr}.");
            if !names.iter().any(|n| n.starts_with(&prefix)) {
                return Err(fail(
                    format!("install= names {name}, but the build has no such binary RPM"),
                    None,
                ));
            }
        }
        let isa = self.rpm_eval("%{_isa}")?;
        if let Some(pin) = &stock.pin {
            let main = format!("{}-{vr}.", env.srpm);
            let Some(f) = rpms.iter().find(|f| {
                let n = fs::file_name(f);
                n.strip_prefix(&main)
                    .and_then(|rest| rest.strip_suffix(".rpm"))
                    .is_some_and(|arch| !arch.contains('.'))
            }) else {
                return Err(fail(
                    format!("no {} binary RPM to check the pin on", env.srpm),
                    None,
                ));
            };
            let reqs = self.run_ok(
                &Cmd::new(Program::Rpm)
                    .args(["-qp", "--requires", "--"])
                    .arg(f)
                    .capture(),
                &format!("rpm -qp --requires {} failed", fs::file_name(f)),
            )?;
            let want = format!("{}{isa} = {}", pin.name, pin.evr);
            if !rpmout::has_line(&reqs.stdout, &want) {
                return Err(fail(
                    format!("{} does not require {want}", fs::file_name(f)),
                    None,
                ));
            }
        }
        let srpms = Self::apex_srpms(b)?;
        if srpms.len() != 1 {
            return Err(fail(
                format!("rpmbuild produced {} source RPMs", srpms.len()),
                None,
            ));
        }
        if self.query(&srpms[0], "%{release}")? != b.release {
            return Err(fail(
                format!("the Apex SRPM's release is not {}", b.release),
                None,
            ));
        }
        self.report.log(&format!(
            "releases: every RPM is {vr}{}",
            stock
                .pin
                .as_ref()
                .map(|p| format!("; {} requires {}{isa} = {}", env.srpm, p.name, p.evr))
                .unwrap_or_default()
        ));
        self.check_sh(b, &rpms)?;
        self.report.endgroup();
        Ok(())
    }

    fn check_sh(&self, b: &Build<'_>, rpms: &[PathBuf]) -> Result<()> {
        let script = b.setup.pkg.check_sh();
        if !script.is_file() {
            return Ok(());
        }
        let dir = tempfile::tempdir()
            .map_err(|e| infra(format!("cannot create a directory for check.sh: {e}")))?;
        let rpms_dir = dir.path().join("rpms");
        fs::create_dir_all(&rpms_dir)?;
        for f in rpms {
            fs::copy_with_mode(f, &rpms_dir.join(fs::file_name(f)))?;
        }
        let log = self.paths.out().join("logs/check.log");
        let source1 = self
            .args
            .source1
            .as_ref()
            .map(|a| self.paths.work.join("in").join(a).display().to_string())
            .unwrap_or_default();
        let out = self.runner.run(
            &Cmd::new(Program::Bash)
                .arg(&script)
                .env("RPMS_DIR", &rpms_dir)
                .env("PRISTINE", b.work.dir.join("pristine"))
                .env("SOURCE1", source1)
                .env("CHECK_WORK", dir.path().join("work"))
                .log_to(&log),
        )?;
        let log_bytes = fs::read(&log).unwrap_or_default();
        self.report.raw(&log_bytes);
        match out.code {
            0 => Ok(()),
            1 => {
                let mut reason = b"check.sh: ".to_vec();
                reason.extend(rpmout::check_reason(&log_bytes));
                Err(self.fail(&b.attempt, &reason, Some(&log)))
            }
            rc => Err(infra(format!(
                "check.sh could not run its checks (exit {rc})"
            ))),
        }
    }

    fn outputs(&self, b: &Build<'_>, preimage: &str) -> Result<()> {
        let out = self.paths.out();
        let env = &b.setup.pkg.env;
        let nevra = |f: &Path| self.query(f, "%{name}-%{epochnum}:%{version}-%{release}.%{arch}");
        let src_nevra = |f: &Path| self.query(f, "%{name}-%{epochnum}:%{version}-%{release}.src");
        let mut m = manifest::render_header(&Header {
            pkg: b.setup.pkg.name.clone(),
            family: env.family.clone(),
            key: b.key.clone(),
            release: b.release.clone(),
            n: self.args.n,
            stock: b.stock.nvr.clone(),
            pin_nvr: b.stock.pin.as_ref().map(|p| p.nvr.clone()),
            fedora: self.rpm_eval("%fedora")?,
            ga_reached: self.args.ga_reached,
            base: self.args.repos_base.clone(),
        });
        let entry = |kind: &str, nevra: &str, file: &Path| -> Result<String> {
            Ok(manifest::entry_line(
                kind,
                nevra,
                &fs::sha256_file(file)?,
                &fs::file_name(file),
            ))
        };
        m.push_str(&entry("fedora-srpm", &src_nevra(&b.srpm)?, &b.srpm)?);
        if let (Some(archive), Some(tree)) = (&self.args.source1, &self.args.source1_tree) {
            let path = self.paths.work.join("in").join(archive);
            m.push_str(&manifest::entry_line(
                "source1",
                tree,
                &fs::sha256_file(&path)?,
                archive,
            ));
        }
        for p in &b.setup.pkg.series {
            let stem = p.strip_suffix(".patch").unwrap_or(p);
            m.push_str(&manifest::entry_line(
                "patch",
                stem,
                &fs::sha256_file(&b.setup.pkg.patch(p))?,
                p,
            ));
        }
        for f in Self::built_rpms(b)? {
            fs::copy_with_mode(&f, &out.join(fs::file_name(&f)))?;
            m.push_str(&entry("built", &nevra(&f)?, &f)?);
        }
        for (kind, n) in &b.mirrors {
            let f = mirror_file(&b.work, n);
            fs::copy_with_mode(&f, &out.join(fs::file_name(&f)))?;
            m.push_str(&entry(kind, n, &f)?);
        }
        let srpms = Self::apex_srpms(b)?;
        let [srpm] = &srpms[..] else {
            return Err(infra(format!(
                "rpmbuild produced {} source RPMs",
                srpms.len()
            )));
        };
        fs::copy_with_mode(srpm, &out.join(fs::file_name(srpm)))?;
        m.push_str(&entry("apex-srpm", &src_nevra(srpm)?, srpm)?);
        fs::write(&out.join("manifest.txt"), m.as_bytes())?;
        fs::write(&out.join("key.txt"), format!("{}\n", b.key).as_bytes())?;
        fs::write(&out.join("key-input.txt"), preimage.as_bytes())
    }
}

pub fn stored_builds(store: &Path) -> Result<Vec<StoredBuild>> {
    fs::sorted_entries(store)?
        .into_iter()
        .map(|d| d.join("manifest.txt"))
        .filter(|m| m.is_file())
        .map(|m| fs::read(&m).map(|b| StoredBuild::from_manifest(&b)))
        .collect()
}

/// Case-sensitive, as `find -name '*SUFFIX'` is.
fn has_suffix(name: &str, suffix: &str) -> bool {
    name.as_bytes().ends_with(suffix.as_bytes())
}

fn timed(
    timings: &mut Vec<(&'static str, u64)>,
    step: &'static str,
    run: impl FnOnce() -> Result<()>,
) -> Result<()> {
    let start = Instant::now();
    run()?;
    timings.push((step, start.elapsed().as_secs()));
    Ok(())
}

fn mirror_file(work: &Work, nevra: &str) -> PathBuf {
    work.dir
        .join("mirror")
        .join(format!("{}.rpm", rpmout::nevra_file_stem(nevra)))
}

/// `git apply` in TREE as its own top: inside an enclosing checkout, such as a kept work
/// directory, it would take paths from that checkout's top and skip the rest unchanged.
fn git_apply(tree: &Path) -> Cmd {
    Cmd::new(Program::Git)
        .env(
            "GIT_CEILING_DIRECTORIES",
            tree.parent().unwrap_or(tree).as_os_str(),
        )
        .arg("apply")
        .cwd(tree)
}
