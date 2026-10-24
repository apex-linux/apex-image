//! The kernel and NVIDIA pair (`source=copr-srpm`): apex-kernel's pair.sh in one fresh
//! container, from inputs mirrored at first sight, held and locked as ADR 0015 §4 says.

use std::path::{Path, PathBuf};
use std::time::Instant;

use super::Vm;
use super::build::{Outcome, remove_tree};
use super::sign::Signer;
use super::sources;
use crate::core::checksig::checksig_ok;
use crate::core::hold;
use crate::core::key::content_key;
use crate::core::lock;
use crate::core::manifest::{self, header_field};
use crate::core::pair::{self, Moves, PairLock, Side};
use crate::core::pins::{self, KernelPins, Nevra, NvidiaPins};
use crate::core::repos::{self, Repos};
use crate::core::text;
use crate::core::utc::UtcSecond;
use crate::error::{Exit, Result, infra, usage};
use crate::pkg::{self, PairPkg};
use crate::shell::cmd::{Cmd, Program, Stderr};
use crate::shell::fs;

pub const CCACHE_VOLUME: &str = "apex-lane-ccache";
/// pair.sh's default: one path in every job, so ccache hits directly (K1: 33 against 15 min).
const MODKEY_DIR: &str = "/run/apex-modkey";
const COPR_RESULTS: &str = "https://download.copr.fedorainfracloud.org/results";
const NEGATIVO17_REPOS: &str = "https://negativo17.org/repos/nvidia";
const NEGATIVO17_KEY_URL: &str = "https://negativo17.org/repos/RPM-GPG-KEY-slaanesh";
/// pair.sh reads its pins and keys under these names, whatever pkg.env calls the pins.
const JOB_KERNEL_ENV: &str = "kernel.env";
const JOB_NVIDIA_ENV: &str = "nvidia.env";
const COPR_KEYRING: &str = "copr.gpg";
const NEGATIVO17_KEYRING: &str = "negativo17.gpg";
const PAIR_LOCK: &str = "pair.lock";
const KERNEL_LOCK: &str = "kernel.lock";
const CONFIG_REQUIRED: &str = "config-required.txt";
const LOW_CPU_SHARES: &str = "256";
const STDERR_TAIL_LINES: usize = 30;

/// What one run builds: the pins in force, which side moves, the staged job and its key.
#[derive(Debug)]
struct Plan {
    kernel: KernelPins,
    nvidia: NvidiaPins,
    /// The recipe's own nvidia.env when the driver waits for the kernel to go first.
    waiting_nvidia: Option<NvidiaPins>,
    moves: Moves,
    good: Option<String>,
    job: PathBuf,
    dnf: Vec<String>,
    preimage: String,
    key: String,
}

struct Input<'a> {
    file: String,
    sha256: &'a str,
    url: String,
}

fn negativo17_url(chroot: &str, nevra: &Nevra) -> String {
    let release = chroot
        .rsplit_once('-')
        .map_or(chroot, |(release, _)| release);
    let dir = if nevra.arch == "src" {
        "SRPMS"
    } else {
        "x86_64"
    };
    format!("{NEGATIVO17_REPOS}/{release}/{dir}/{}", nevra.file_name())
}

fn copr_srpm_url(kernel: &KernelPins, srpm: &Nevra) -> String {
    let file = srpm.file_name();
    let first = file.chars().next().unwrap_or('k');
    format!(
        "{COPR_RESULTS}/{}/{}/Packages/{first}/{file}",
        kernel.copr, kernel.chroot
    )
}

impl Vm<'_> {
    /// `Some` for a pair recipe, after the one-package-per-family check.
    pub fn load_pair(&self, name: &str) -> Result<Option<PairPkg>> {
        let Some(p) = pkg::load_pair(&self.recipe_root_of(name)?, name)? else {
            return Ok(None);
        };
        pkg::check_family_unique(&self.recipe_roots(), &p.name, &p.env.family)?;
        Ok(Some(p))
    }

    fn pair_paths<'p>(&'p self, p: &'p PairPkg) -> Vec<(&'p Path, Vec<String>)> {
        let recipe = vec![format!("packaging/pkgs/{}", p.name)];
        let tool: Vec<String> = crate::core::tool_id::SOURCE_PATHS.map(String::from).into();
        if p.recipe_root == self.root {
            vec![(&self.root, [recipe, tool].concat())]
        } else {
            vec![(&p.recipe_root, recipe), (&self.root, tool)]
        }
    }

    fn read_kernel(path: &Path) -> Result<(KernelPins, Vec<u8>)> {
        let bytes = pkg::read_file(path)?;
        Ok((
            pins::parse_kernel(&path.display().to_string(), &bytes)?,
            bytes,
        ))
    }

    fn read_nvidia(path: &Path) -> Result<(NvidiaPins, Vec<u8>)> {
        let bytes = pkg::read_file(path)?;
        Ok((
            pins::parse_nvidia(&path.display().to_string(), &bytes)?,
            bytes,
        ))
    }

    fn good_pair_key(&self, family: &str) -> Result<Option<String>> {
        let locked = fs::read_opt(&self.lock_file())?.unwrap_or_default();
        Ok(hold::good_key(&lock::family_line(&locked, family)))
    }

    fn pair_dnf_options(&self) -> Result<Vec<String>> {
        let mut out = Repos::released().bin;
        let allow_path = self
            .root
            .join("image/packages/updates-testing-allowlist.txt");
        let allow = repos::testing_includepkgs(fs::read_opt(&allow_path)?.as_deref());
        if self.ga_reached()? != 1 && !allow.is_empty() {
            out.push("--repo=updates-testing".into());
            out.push(format!("--setopt=updates-testing.includepkgs={allow}"));
        }
        Ok(out)
    }

    fn plan(&self, p: &PairPkg, work: &Path) -> Result<Plan> {
        let (kernel, kernel_bytes) = Self::read_kernel(&p.dir.join(&p.env.kernel_env))?;
        let (nvidia, nvidia_bytes) = Self::read_nvidia(&p.dir.join(&p.env.nvidia_env))?;
        let good = self.good_pair_key(&p.env.family)?;
        let good_pins = match &good {
            Some(key) => {
                let set = self.store_pkg(&p.name).join(key);
                let (k, _) = Self::read_kernel(&set.join(JOB_KERNEL_ENV))?;
                let (_, n) = Self::read_nvidia(&set.join(JOB_NVIDIA_ENV))?;
                Some((k, n))
            }
            None => None,
        };
        let raw = Moves::of(
            good_pins.as_ref().map(|(k, n)| (k, n.as_slice())),
            &kernel,
            &nvidia_bytes,
        );
        let (nvidia, nvidia_bytes, waiting_nvidia, moves) = match &good_pins {
            Some((_, good_bytes)) if raw.driver_waits() => {
                let (good_nvidia, _) = Self::read_nvidia(
                    &self
                        .store_pkg(&p.name)
                        .join(good.as_deref().unwrap_or_default())
                        .join(JOB_NVIDIA_ENV),
                )?;
                let moves = Moves {
                    driver: false,
                    ..raw
                };
                (good_nvidia, good_bytes.clone(), Some(nvidia), moves)
            }
            _ => (nvidia, nvidia_bytes, None, raw),
        };
        let job = work.join("in/job");
        fs::create_dir_all(&job)?;
        let mut from = p.dir.clone().into_os_string();
        from.push("/.");
        self.run_ok(&Cmd::new(Program::Cp).args(["-a", "--"]).arg(from).arg(&job))?;
        fs::write(&job.join(JOB_KERNEL_ENV), &kernel_bytes)?;
        fs::write(&job.join(JOB_NVIDIA_ENV), &nvidia_bytes)?;
        let dnf = self.pair_dnf_options()?;
        let mut files = Vec::new();
        // The README is no input of the job: a fix to it must not rebuild a kernel.
        for path in fs::files_under(&job, &|name| name != "README.md")? {
            let rel = path
                .strip_prefix(&job)
                .unwrap_or(&path)
                .display()
                .to_string();
            files.push((rel, fs::sha256_file(&path)?));
        }
        let preimage = pair::preimage(&p.name, &self.tool_id()?, &dnf.join(" "), &files);
        let key = content_key(&kernel.srpm.nvr(), &preimage);
        Ok(Plan {
            kernel,
            nvidia,
            waiting_nvidia,
            moves,
            good,
            job,
            dnf,
            preimage,
            key,
        })
    }

    pub fn build_pair(&self, p: &PairPkg, signer: &Signer) -> Result<Outcome> {
        for (root, paths) in self.pair_paths(p) {
            self.check_clean(root, paths)?;
        }
        let start = Instant::now();
        let work = self.lane_work(&p.name);
        self.fresh_work_dir(&work, &["in", "out", "mirror"])?;
        let plan = self.plan(p, &work)?;
        self.mirror_pair(&plan, &work.join("mirror"))?;
        let stored = self.store_pkg(&p.name).join(&plan.key);
        if stored.symlink_metadata().is_ok() {
            Self::verify_stored(&stored)?;
            signer.check_stored(&stored)?;
            self.record_pair(p, &plan.key, format!("built {}", plan.key).as_bytes())?;
            self.report.summary(&[
                format!("### {}: unchanged", p.name),
                String::new(),
                format!(
                    "The pair `{}` is already stored; rpms.lock.next takes it.",
                    plan.key
                ),
            ]);
            return Ok(Outcome::Unchanged(plan.key));
        }
        self.report.group(&format!(
            "{}: the pair {} with {} (pair.sh)",
            p.name, plan.kernel.srpm, plan.nvidia.kmod_srpm
        ));
        let job = self.run_pair_job(&work, &plan);
        self.report.endgroup();
        self.own(&work)?;
        let (code, stderr) = job?;
        let out = work.join("out");
        match code {
            0 => {}
            1 => return self.record_pair_failure(p, &plan, &out, &stderr, signer),
            _ => {
                return Err(infra(format!(
                    "pair.sh could not run (exit {code}): {}",
                    text::lossy(&pair::reason_of_stderr(&stderr))
                )));
            }
        }
        if let Some(reason) = self.module_gate(p, &plan, &out)? {
            return self.record_pair_failure(p, &plan, &out, reason.as_bytes(), signer);
        }
        self.store_pair_set(p, &plan, &plan.key, &plan.preimage, PAIR_LOCK, signer)?;
        self.record_pair(p, &plan.key, format!("built {}", plan.key).as_bytes())?;
        let manifest_text = fs::read(&stored.join("manifest.txt"))?;
        let mut summary = vec![
            format!("### {}: built in {} s", p.name, start.elapsed().as_secs()),
            String::new(),
            "```".into(),
            text::lossy(text::chomp(&manifest_text)),
            "```".into(),
        ];
        if let Some(waiting) = &plan.waiting_nvidia {
            summary.push(String::new());
            summary.push(format!(
                "One side moves per image, the kernel first: {} waits for the image after this one.",
                waiting.kmod_srpm
            ));
        }
        self.report.summary(&summary);
        Ok(Outcome::Built(plan.key))
    }

    fn run_pair_job(&self, work: &Path, plan: &Plan) -> Result<(i32, Vec<u8>)> {
        let mount = |from: &Path, to: &str, opts: &str| -> Result<String> {
            let from = from.display().to_string();
            if from.contains([':', ',']) {
                return Err(infra(format!(
                    "cannot mount {from}: the path holds ':' or ','"
                )));
            }
            Ok(format!("{from}:{to}:{opts}"))
        };
        let cmd = Cmd::new(Program::Podman)
            .args([
                "run",
                "--rm",
                "--pull=missing",
                "--cpu-shares",
                LOW_CPU_SHARES,
            ])
            .arg("-v")
            .arg(mount(&plan.job, "/job", "ro,z")?)
            .arg("-v")
            .arg(mount(&work.join("mirror"), "/mirror", "ro,z")?)
            .arg("-v")
            .arg(mount(&work.join("out"), "/out", "z")?)
            .arg("-v")
            .arg(format!("{}:/var/cache/libdnf5", super::DNF_CACHE_VOLUME))
            .arg("-v")
            .arg(format!("{CCACHE_VOLUME}:/var/cache/ccache"))
            .arg("--tmpfs")
            .arg(format!("{MODKEY_DIR}:rw,mode=0700"))
            .args(["-e", "CCACHE_DIR=/var/cache/ccache", "-e"])
            .arg(format!("PAIR_ID={}", plan.key))
            .arg(self.repos_base()?)
            .args(["/usr/bin/bash", "/job/pair.sh", "/mirror", "/out"])
            .args(&plan.dnf)
            .stderr(Stderr::Capture);
        let out = self.runner.run(&cmd.privileged(self.settings.is_root))?;
        self.report
            .raw(text::tail_lines(&out.stderr, STDERR_TAIL_LINES));
        Ok((out.code, out.stderr))
    }

    /// Every input at first sight: the COPR keeps 5 builds, negativo17 the last 2 of each
    /// package, so a hold or a rebuild of an older pair works only from the store.
    fn mirror_pair(&self, plan: &Plan, dest: &Path) -> Result<()> {
        let mirror = self.settings.store.join("mirror");
        fs::create_dir_all(&mirror.join("keys"))?;
        let copr_key = self.mirror_key(
            &plan.kernel.copr_key,
            &format!("{COPR_RESULTS}/{}/pubkey.gpg", plan.kernel.copr),
        )?;
        let kernel = Input {
            file: plan.kernel.srpm.file_name(),
            sha256: &plan.kernel.srpm_sha256,
            url: copr_srpm_url(&plan.kernel, &plan.kernel.srpm),
        };
        self.mirror_input(&kernel, &copr_key, &plan.kernel.copr_key)?;
        link_or_copy(&mirror.join(&kernel.file), &dest.join(&kernel.file))?;
        link_or_copy(&copr_key, &dest.join(COPR_KEYRING))?;
        for (nvidia, staged) in [
            (Some(&plan.nvidia), true),
            (plan.waiting_nvidia.as_ref(), false),
        ] {
            let Some(nvidia) = nvidia else { continue };
            let key = self.mirror_key(&nvidia.negativo17_key, NEGATIVO17_KEY_URL)?;
            let mut inputs = vec![(&nvidia.kmod_srpm, nvidia.kmod_srpm_sha256.as_str())];
            inputs.extend(nvidia.userspace.iter().map(|(n, s)| (n, s.as_str())));
            for (nevra, sha256) in inputs {
                let input = Input {
                    file: nevra.file_name(),
                    sha256,
                    url: negativo17_url(&plan.kernel.chroot, nevra),
                };
                self.mirror_input(&input, &key, &nvidia.negativo17_key)?;
                if staged {
                    link_or_copy(&mirror.join(&input.file), &dest.join(&input.file))?;
                }
            }
            if staged {
                link_or_copy(&key, &dest.join(NEGATIVO17_KEYRING))?;
            }
        }
        Ok(())
    }

    fn download(&self, url: &str, to: &Path) -> Result<()> {
        let out = self.runner.run(
            &Cmd::new(Program::Curl)
                .args(["-fsSL", "--retry", "3", "--max-time", "1800", "-o"])
                .arg(to)
                .arg(url),
        )?;
        if !out.ok() {
            let _ = std::fs::remove_file(to);
            return Err(infra(format!(
                "cannot download {url} (curl exit {})",
                out.code
            )));
        }
        Ok(())
    }

    /// The key file holds exactly the pinned key, or nothing is mirrored with it.
    fn mirror_key(&self, fingerprint: &str, url: &str) -> Result<PathBuf> {
        let path = self
            .settings
            .store
            .join("mirror/keys")
            .join(format!("{fingerprint}.gpg"));
        let fresh = !path.is_file();
        let check = if fresh {
            let partial = path.with_extension("gpg.partial");
            self.download(url, &partial)?;
            partial
        } else {
            path.clone()
        };
        let found = self.primary_fingerprints(&check)?;
        if found != [fingerprint] {
            if fresh {
                let _ = std::fs::remove_file(&check);
            }
            return Err(infra(format!(
                "{} holds the key(s) [{}], not exactly the pinned {fingerprint}",
                if fresh {
                    url.to_owned()
                } else {
                    path.display().to_string()
                },
                found.join(" ")
            )));
        }
        if fresh {
            std::fs::rename(&check, &path).map_err(|e| fs::io_error("cannot store", &path, &e))?;
            self.report
                .log(&format!("mirror: the key {fingerprint} from {url}"));
        }
        Ok(path)
    }

    fn mirror_input(&self, input: &Input<'_>, key_file: &Path, fingerprint: &str) -> Result<()> {
        let path = self.settings.store.join("mirror").join(&input.file);
        if path.is_file() {
            if fs::sha256_file(&path)? != input.sha256 {
                return Err(infra(format!(
                    "the mirror's {} does not have its pinned sha256",
                    path.display()
                )));
            }
            return Ok(());
        }
        let partial = path.with_file_name(format!(".partial-{}", input.file));
        self.download(&input.url, &partial)?;
        let verified = self.verify_input(input, &partial, key_file, fingerprint);
        if verified.is_err() {
            let _ = std::fs::remove_file(&partial);
        }
        verified?;
        std::fs::rename(&partial, &path).map_err(|e| fs::io_error("cannot store", &path, &e))?;
        self.report
            .log(&format!("mirror: {} (first sight)", input.file));
        Ok(())
    }

    fn verify_input(
        &self,
        input: &Input<'_>,
        file: &Path,
        key_file: &Path,
        fingerprint: &str,
    ) -> Result<()> {
        if fs::sha256_file(file)? != input.sha256 {
            return Err(infra(format!(
                "{} does not have its pinned sha256 {}",
                input.url, input.sha256
            )));
        }
        let keyring =
            tempfile::tempdir().map_err(|e| infra(format!("cannot create an rpm keyring: {e}")))?;
        let rpmkeys = || {
            Cmd::new(Program::Rpmkeys)
                .arg("--dbpath")
                .arg(keyring.path())
                .args(["--define", "_keyring fs", "--define"])
                .arg(format!(
                    "_keyringpath {}/pubkeys/",
                    keyring.path().display()
                ))
        };
        self.run_ok(&rpmkeys().arg("--import").arg(key_file))?;
        let check = self.runner.run(
            &rpmkeys()
                .arg("-Kv")
                .arg(file)
                .capture()
                .stderr(Stderr::ToStdout),
        )?;
        if !check.ok() || !checksig_ok(&check.stdout, fingerprint) {
            return Err(infra(format!(
                "{} is not signed by its pinned key {fingerprint}: {}",
                input.url,
                text::lossy(text::chomp(&check.stdout))
            )));
        }
        Ok(())
    }

    fn module_count(&self, files: &[PathBuf]) -> Result<usize> {
        let out = self.run_ok(
            &Cmd::new(Program::Rpm)
                .args(["-qlp", "--nosignature", "--"])
                .args(files)
                .capture(),
        )?;
        Ok(pair::count_modules(&out.stdout))
    }

    /// ARCHITECTURE 4.2's gate that check.sh cannot run: it never sees the last good pair.
    fn module_gate(&self, p: &PairPkg, plan: &Plan, out: &Path) -> Result<Option<String>> {
        let Some(good) = &plan.good else {
            return Ok(None);
        };
        let set = self.store_pkg(&p.name).join(good);
        let listed = fs::read(&set.join("manifest.txt"))?;
        let previous: Vec<PathBuf> = manifest::entries(&listed)
            .iter()
            .filter(|e| e.kind == b"built")
            .map(|e| set.join(text::lossy(e.file)))
            .collect();
        let locked = pair::parse_pair_lock(&fs::read(&out.join(PAIR_LOCK))?, true)
            .map_err(|e| infra(format!("pair.sh's {PAIR_LOCK}: {e}")))?;
        let now: Vec<PathBuf> = locked
            .rpms
            .iter()
            .map(|(file, _)| out.join("rpms").join(file))
            .collect();
        let (previous, now) = (self.module_count(&previous)?, self.module_count(&now)?);
        self.report.log(&format!(
            "modules: {now} in the pair, {previous} in the last good pair {good}"
        ));
        Ok(pair::module_drift(previous, now, good))
    }

    fn rpm_nevras(&self, files: &[PathBuf]) -> Result<Vec<Nevra>> {
        let out = self.run_ok(
            &Cmd::new(Program::Rpm)
                .args(["-qp", "--nosignature", "--queryformat"])
                .arg("%{NAME}-%{EPOCHNUM}:%{VERSION}-%{RELEASE}.%{ARCH}\\n")
                .arg("--")
                .args(files)
                .capture(),
        )?;
        let lines = text::lines(&out.stdout);
        if lines.len() != files.len() {
            return Err(infra("rpm -qp named fewer packages than it was given"));
        }
        files
            .iter()
            .zip(lines)
            .map(|(file, line)| {
                Nevra::parse(&text::lossy(line))
                    .filter(|n| n.file_name() == fs::file_name(file))
                    .ok_or_else(|| {
                        infra(format!(
                            "{} is not the RPM its file name says ({})",
                            file.display(),
                            text::lossy(line)
                        ))
                    })
            })
            .collect()
    }

    /// The job's RPMs, signed, with a manifest the other families' code reads.
    fn store_pair_set(
        &self,
        p: &PairPkg,
        plan: &Plan,
        key: &str,
        preimage: &str,
        lock_name: &str,
        signer: &Signer,
    ) -> Result<()> {
        let work = self.lane_work(&p.name);
        let out = work.join("out");
        let bytes = fs::read(&out.join(lock_name))?;
        let locked = pair::parse_pair_lock(&bytes, lock_name == PAIR_LOCK)
            .map_err(|e| infra(format!("pair.sh's {lock_name}: {e}")))?;
        check_kernel(&locked, &plan.kernel)?;
        let set = work.join("set");
        remove_tree(&set)?;
        fs::create_dir_all(&set.join("logs"))?;
        let mut files = Vec::new();
        for (file, sha256) in &locked.rpms {
            let from = out.join("rpms").join(file);
            if !from.is_file() || fs::sha256_file(&from)? != *sha256 {
                return Err(infra(format!(
                    "pair.sh's {lock_name} names {file}, which out/rpms does not hold with that sha256"
                )));
            }
            let to = set.join(file);
            std::fs::rename(&from, &to).map_err(|e| fs::io_error("cannot move", &from, &e))?;
            files.push(to);
        }
        let nevras = self.rpm_nevras(&files)?;
        let mut manifest_text = format!(
            "{}\n# pkg={} family={} key={key} kernel={} kmod={} module_cert_sha256={} base={}\n",
            manifest::FORMAT_LINE,
            p.name,
            p.env.family,
            locked.kernel,
            locked
                .kmod
                .as_ref()
                .map_or_else(|| "-".to_owned(), Nevra::to_string),
            locked.module_cert_sha256,
            self.repos_base()?
        );
        for ((file, sha256), nevra) in locked.rpms.iter().zip(&nevras) {
            manifest_text.push_str(&manifest::entry_line(
                "built",
                &nevra.to_string(),
                sha256,
                file,
            ));
        }
        if lock_name == PAIR_LOCK {
            for (nevra, sha256) in &plan.nvidia.userspace {
                let file = nevra.file_name();
                let from = self.settings.store.join("mirror").join(&file);
                if fs::sha256_file(&from)? != *sha256 {
                    return Err(infra(format!(
                        "the mirror's {} does not have its pinned sha256",
                        from.display()
                    )));
                }
                link_or_copy(&from, &set.join(&file))?;
                manifest_text.push_str(&manifest::entry_line(
                    "mirror",
                    &nevra.to_string(),
                    sha256,
                    &file,
                ));
            }
        }
        fs::write(&set.join("manifest.txt"), manifest_text.as_bytes())?;
        fs::write(&set.join("key.txt"), format!("{key}\n").as_bytes())?;
        fs::write(&set.join("key-input.txt"), preimage.as_bytes())?;
        self.keep_inputs(plan, &set, lock_name)?;
        for entry in fs::sorted_entries(&out)? {
            if entry.is_file() {
                let name = fs::file_name(&entry);
                let to = if name == lock_name || name == "signing_key.x509" {
                    set.join(&name)
                } else {
                    set.join("logs").join(&name)
                };
                fs::copy_with_mode(&entry, &to)?;
            }
        }
        self.sign_built(&set, signer)?;
        fs::create_dir_all(&self.store_pkg(&p.name))?;
        let partial = self.store_pkg(&p.name).join(format!(".partial-{key}"));
        remove_tree(&partial)?;
        self.move_tree(&set, &partial)?;
        let stored = self.store_pkg(&p.name).join(key);
        self.move_tree(&partial, &stored)?;
        Self::verify_stored(&stored)
    }

    /// What the image checks a pair against, and the source artifact's pins and recipe.
    fn keep_inputs(&self, plan: &Plan, set: &Path, lock_name: &str) -> Result<()> {
        if lock_name == PAIR_LOCK {
            let key = self
                .settings
                .store
                .join("mirror/keys")
                .join(format!("{}.gpg", plan.nvidia.negativo17_key));
            fs::copy_with_mode(&key, &set.join(NEGATIVO17_KEYRING))?;
        }
        let config = plan.job.join(CONFIG_REQUIRED);
        if config.is_file() {
            fs::copy_with_mode(&config, &set.join(CONFIG_REQUIRED))?;
        }
        fs::copy_with_mode(&plan.job.join(JOB_KERNEL_ENV), &set.join(JOB_KERNEL_ENV))?;
        let recipe = set.join(sources::SOURCE_RECIPE);
        fs::create_dir_all(&recipe)?;
        let mut job = plan.job.clone().into_os_string();
        job.push("/.");
        self.run_ok(
            &Cmd::new(Program::Cp)
                .args(["-a", "--"])
                .arg(job)
                .arg(&recipe),
        )?;
        fs::copy_with_mode(&plan.job.join(JOB_NVIDIA_ENV), &set.join(JOB_NVIDIA_ENV))?;
        Ok(())
    }

    fn record_pair(&self, p: &PairPkg, key: &str, line: &[u8]) -> Result<()> {
        let path = self.store_pkg(&p.name).join(key).join("manifest.txt");
        let listed = fs::read(&path)?;
        let mut install = p.env.install.clone();
        let kmod = text::lossy(&header_field(&listed, "kmod"));
        if kmod != "-" {
            let nevra = Nevra::parse(&kmod)
                .ok_or_else(|| infra(format!("{}: kmod={kmod} is not a NEVRA", path.display())))?;
            install.push(nevra.name);
        }
        let rpms = lock::manifest_lock_rpms(
            &path.display().to_string(),
            &listed,
            &p.env.family,
            &format!("pkgs/{}/{key}", p.name),
            &install,
        )
        .map_err(|e| infra(e.to_string()))?;
        let n = lock::built_count(&rpms);
        if n != install.len() {
            return Err(infra(format!(
                "store: {key} has {n} of the {} packages the pair locks ({})",
                install.len(),
                install.join(" ")
            )));
        }
        self.lock_put(&p.env.family, line, &rpms)
    }

    fn record_pair_failure(
        &self,
        p: &PairPkg,
        plan: &Plan,
        out: &Path,
        stderr: &[u8],
        signer: &Signer,
    ) -> Result<Outcome> {
        let family = p.env.family.as_str();
        let reason = pair::reason_of_stderr(stderr);
        let side = Side::of_reason(&reason);
        let now = self.clock.now();
        let store = self.store_pkg(&p.name);
        let (good_key, good_degraded) = self.last_good_pair(p, plan, &reason, stderr)?;
        let mut newer = Vec::new();
        if plan.moves.kernel {
            newer.push(plan.kernel.srpm.to_string());
        }
        if plan.moves.driver {
            newer.push(plan.nvidia.kmod_srpm.to_string());
        }
        let newer_csv = newer.join(",");
        let next_text = fs::read_opt(&self.next_lock_file())?.unwrap_or_default();
        let current = lock::family_line(&next_text, family);
        let since = pair::since(&current, &newer_csv, now);
        let start = UtcSecond::parse(&since).ok_or_else(|| {
            infra(format!(
                "rpms.lock.next: the hold of {family} started at '{}', which is not a UTC time",
                text::lossy(&since)
            ))
        })?;
        let released = (side == Side::Kernel && plan.moves.kernel)
            .then(|| self.kernel_org.released(&plan.kernel.kernel_org_version()))
            .flatten();
        let timer = pair::timer(side, plan.moves, start, released);
        let reached = timer.as_ref().is_some_and(|t| now >= t.limit);
        if side == Side::Kmod && reached && out.join(KERNEL_LOCK).is_file() {
            let preimage = pair::degraded_preimage(&plan.preimage);
            let key = content_key(&plan.kernel.srpm.nvr(), &preimage);
            if store.join(&key).symlink_metadata().is_err() {
                self.store_pair_set(p, plan, &key, &preimage, KERNEL_LOCK, signer)?;
            }
            let line = pair::degraded_line(&key, &since, &newer_csv, timer.as_ref(), &reason);
            self.record_pair(p, &key, &line)?;
            self.report.summary(&[
                format!("### {}: {}", p.name, pair::DEGRADED_NVIDIA),
                String::new(),
                text::lossy(&reason),
                String::new(),
                format!(
                    "The kmod hold reached its limit: the next image takes {} without the NVIDIA set, and publishes only with the owner's override.",
                    plan.kernel.srpm.nvr()
                ),
            ]);
            return Ok(Outcome::Degraded);
        }
        let locked = fs::read_opt(&self.lock_file())?.unwrap_or_default();
        if good_degraded && side == Side::Kmod && !plan.moves.kernel {
            let since = if pair::is_degraded(&current) {
                lock::attr(&current, "since")
            } else {
                now.to_string().into_bytes()
            };
            let line = pair::degraded_line(&good_key, &since, &newer_csv, None, &reason);
            self.lock_put(family, &line, &lock::rpm_lines(&locked, family))?;
            self.report.summary(&[
                format!("### {}: {} (kmod)", p.name, pair::DEGRADED_NVIDIA),
                String::new(),
                text::lossy(&reason),
                String::new(),
                format!("The kmod still does not build: the image keeps {good_key} without the NVIDIA set."),
            ]);
            return Ok(Outcome::Degraded);
        }
        let line = pair::held_line(
            (&good_key, good_degraded),
            &since,
            &newer_csv,
            timer.as_ref(),
            side,
            &reason,
        );
        self.lock_put(family, &line, &lock::rpm_lines(&locked, family))?;
        self.report.summary(&pair::summary_held(
            &p.name,
            &reason,
            &good_key,
            &since,
            timer.as_ref(),
            side,
            side == Side::Kmod && reached,
        ));
        Ok(Outcome::Held)
    }

    /// The pair a hold keeps, and whether it is a kernel-only set; the failure is kept first.
    fn last_good_pair(
        &self,
        p: &PairPkg,
        plan: &Plan,
        reason: &[u8],
        stderr: &[u8],
    ) -> Result<(String, bool)> {
        let family = p.env.family.as_str();
        let store = self.store_pkg(&p.name);
        fs::create_dir_all(&store)?;
        let mut failure = reason.to_vec();
        failure.push(b'\n');
        failure.extend_from_slice(text::tail_lines(stderr, STDERR_TAIL_LINES));
        fs::write(&store.join("last-failure.txt"), &failure)?;
        let Some(good_key) = plan.good.clone() else {
            return Err(infra(format!(
                "{}: {}. rpms.lock has no last good pair of {family} to hold, so the image build stops",
                p.name,
                text::lossy(reason)
            )));
        };
        let Some(good_manifest) = fs::read_opt(&store.join(&good_key).join("manifest.txt"))? else {
            return Err(infra(format!(
                "store: the last good pair {good_key} of {family} is missing"
            )));
        };
        let degraded = header_field(&good_manifest, "kmod") == b"-";
        Ok((good_key, degraded))
    }

    pub fn pair_key(&self, p: &PairPkg) -> Result<Exit> {
        for (root, paths) in self.pair_paths(p) {
            self.check_clean(root, paths)?;
        }
        let work = self.lane_work(&format!("{}.key", p.name));
        self.fresh_work_dir(&work, &["in"])?;
        let plan = self.plan(p, &work)?;
        self.report.log(&plan.key);
        Ok(Exit::Ok)
    }

    pub(super) fn the_pair(&self) -> Result<PairPkg> {
        for name in self.all_pkgs()? {
            if let Some(p) = self.load_pair(&name)? {
                return Ok(p);
            }
        }
        Err(usage(
            "no recipe checkout holds a pair recipe (a pkg.env with source=copr-srpm)",
        ))
    }

    /// bump.sh's verdict: a point bump becomes a commit on a branch of the recipe's
    /// checkout, for the bump PR; pushing it and opening the PR is the runner's.
    pub fn kernel_bump(&self) -> Result<Exit> {
        let p = self.the_pair()?;
        let bump = self.runner.run(
            &Cmd::new(Program::Bash)
                .arg(p.dir.join("bump.sh"))
                .arg("check")
                .capture(),
        )?;
        if !bump.ok() {
            return Err(infra(format!("bump.sh check failed (exit {})", bump.code)));
        }
        let report = pair::parse_bump(&bump.stdout).map_err(infra)?;
        let kernel_path = p.dir.join(&p.env.kernel_env);
        let (kernel, kernel_bytes) = Self::read_kernel(&kernel_path)?;
        if let Some(srpm) = &report.point {
            self.point_bump(&p, &kernel, &kernel_bytes, srpm)?;
        }
        if let Some((srpm, eol)) = &report.major {
            self.report.log(&format!(
                "kernel: {srpm} is a new major: waiting for owner; the pinned {} reaches its EOL in {eol}",
                kernel.major()
            ));
        }
        if report.point.is_none() && report.major.is_none() {
            self.report
                .log("kernel: no newer build of the pinned major");
        }
        for nevra in &report.nvidia_newer {
            self.report.log(&format!(
                "nvidia: {nevra} is newer than the pins; a new driver waits for the owner (ADR 0015 §4)"
            ));
        }
        for name in &report.nvidia_missing {
            self.report.warn(&format!(
                "nvidia: negativo17 has no build of the pinned branch for {name}"
            ));
        }
        Ok(Exit::Ok)
    }

    fn point_bump(
        &self,
        p: &PairPkg,
        kernel: &KernelPins,
        kernel_bytes: &[u8],
        srpm: &Nevra,
    ) -> Result<()> {
        if !pair::is_point_of(kernel, srpm) {
            return Err(infra(format!(
                "bump.sh called {srpm} a point bump of {}",
                kernel.srpm
            )));
        }
        let branch = format!("kernel-bump/{}", srpm.nvr());
        let root = &p.recipe_root;
        let exists = self.runner.run(
            &Self::git_in(root)
                .args(["rev-parse", "-q", "--verify"])
                .arg(format!("refs/heads/{branch}"))
                .capture(),
        )?;
        if exists.ok() {
            self.report.log(&format!(
                "kernel: {srpm}: the branch {branch} already exists"
            ));
            return Ok(());
        }
        let mirror = self.settings.store.join("mirror");
        fs::create_dir_all(&mirror)?;
        let key = self.mirror_key(
            &kernel.copr_key,
            &format!("{COPR_RESULTS}/{}/pubkey.gpg", kernel.copr),
        )?;
        let file = srpm.file_name();
        let path = mirror.join(&file);
        if !path.is_file() {
            let partial = mirror.join(format!(".partial-{file}"));
            let url = copr_srpm_url(kernel, srpm);
            self.download(&url, &partial)?;
            let sha256 = fs::sha256_file(&partial)?;
            let input = Input {
                file: file.clone(),
                sha256: &sha256,
                url,
            };
            let verified = self.verify_input(&input, &partial, &key, &kernel.copr_key);
            if verified.is_err() {
                let _ = std::fs::remove_file(&partial);
            }
            verified?;
            std::fs::rename(&partial, &path)
                .map_err(|e| fs::io_error("cannot store", &path, &e))?;
            self.report.log(&format!("mirror: {file} (first sight)"));
        }
        let sha256 = fs::sha256_file(&path)?;
        let bumped = pair::bumped_kernel_env(kernel_bytes, srpm, &sha256);
        pins::parse_kernel("the bumped kernel.env", &bumped)?;
        let rel = format!("packaging/pkgs/{}/{}", p.name, p.env.kernel_env);
        let message = format!(
            "kernel: point bump to {}\n\nWritten by apex-lane kernel-bump: srpm and srpm_sha256 of the COPR-signed SRPM it mirrored, and its tag.\n",
            srpm.nvr()
        );
        let commit = self.commit_file(root, &rel, &bumped, &message)?;
        self.run_ok(&Self::git_in(root).arg("branch").arg(&branch).arg(&commit))?;
        self.report.log(&format!(
            "kernel: {srpm}: committed {rel} on {branch} ({commit}) in {}; the runner pushes it for the bump PR",
            root.display()
        ));
        Ok(())
    }

    /// A commit of HEAD with one file replaced, through a private index: the checkout's
    /// HEAD, index and work tree stay as they are.
    fn commit_file(&self, root: &Path, rel: &str, bytes: &[u8], message: &str) -> Result<String> {
        let tmp = tempfile::tempdir()
            .map_err(|e| infra(format!("cannot create a temporary directory: {e}")))?;
        let blob_file = tmp.path().join("blob");
        fs::write(&blob_file, bytes)?;
        let index = tmp.path().join("index");
        let git = || Self::git_in(root).env("GIT_INDEX_FILE", &index);
        let out = |cmd: Cmd| -> Result<String> {
            Ok(text::lossy(text::chomp(
                &self.run_ok(&cmd.capture())?.stdout,
            )))
        };
        let blob = out(git().args(["hash-object", "-w", "--"]).arg(&blob_file))?;
        self.run_ok(&git().args(["read-tree", "HEAD"]))?;
        self.run_ok(
            &git()
                .args(["update-index", "--cacheinfo"])
                .arg(format!("100644,{blob},{rel}")),
        )?;
        let tree = out(git().arg("write-tree"))?;
        out(git()
            .args(["commit-tree", &tree, "-p", "HEAD", "-m"])
            .arg(message))
    }
}

fn check_kernel(locked: &PairLock, kernel: &KernelPins) -> Result<()> {
    let built = &locked.kernel;
    if built.name != kernel.srpm.name
        || built.version != kernel.srpm.version
        || built.release != kernel.srpm.release
    {
        return Err(infra(format!(
            "pair.sh built {built}, not the pinned {}",
            kernel.srpm
        )));
    }
    Ok(())
}

fn link_or_copy(from: &Path, to: &Path) -> Result<()> {
    if std::fs::hard_link(from, to).is_ok() {
        return Ok(());
    }
    std::fs::copy(from, to)
        .map(|_| ())
        .map_err(|e| fs::io_error("cannot copy", from, &e))
}
