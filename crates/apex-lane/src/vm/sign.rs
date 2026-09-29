use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use super::Vm;
use crate::core::checksig::checksig_ok;
use crate::core::manifest;
use crate::core::rpmout;
use crate::core::signing;
use crate::core::text;
use crate::error::{Result, infra, usage};
use crate::shell::cmd::{Cmd, Program, Stderr};
use crate::shell::fs;

/// The image ships it, and the compose's `[apex]` verifies with it.
pub const PUBLIC_KEY_PATH: &str = "image/system_files/usr/share/apex/keys/RPM-GPG-KEY-apex";

/// The Apex RPM key of `rpm-signing.env`, matched against the committed public key, and
/// an rpm keyring that holds only that public key.
#[derive(Debug)]
pub struct Signer {
    pub fingerprint: String,
    gnupg_home: PathBuf,
    keyring: tempfile::TempDir,
}

impl Signer {
    /// A stored set the lane takes again carries a signature the image still trusts.
    pub fn check_stored(&self, dir: &Path) -> Result<()> {
        let listed = fs::read(&dir.join("manifest.txt"))?;
        let sig = manifest::signed_with(&listed).map_or_else(|| "none".to_owned(), text::lossy);
        if sig == self.fingerprint {
            return Ok(());
        }
        Err(infra(format!(
            "store: {} records sig={sig}, not the Apex RPM key {}, so the image would refuse its RPMs: move the set out of the store, and the lane builds and signs it again (docs/RECOVERY.md §6.8)",
            dir.display(),
            self.fingerprint
        )))
    }

    fn rpmkeys(&self) -> Cmd {
        let dir = self.keyring.path();
        Cmd::new(Program::Rpmkeys)
            .arg("--dbpath")
            .arg(dir)
            .args(["--define", "_keyring fs", "--define"])
            .arg(format!("_keyringpath {}/pubkeys/", dir.display()))
    }
}

fn temp_dir(what: &str) -> Result<tempfile::TempDir> {
    tempfile::tempdir().map_err(|e| infra(format!("cannot create {what}: {e}")))
}

impl Vm<'_> {
    /// Before any container starts, so a missing or mismatched key never costs a build.
    pub fn signer(&self) -> Result<Signer> {
        let conf = &self.settings.signing_env;
        let Some(bytes) = fs::read_opt(conf)? else {
            return Err(infra(format!(
                "no Apex RPM key: {} does not exist, and every RPM the lane builds is signed (packaging/README.md, Signing)",
                conf.display()
            )));
        };
        let env = signing::parse(&conf.display().to_string(), &bytes)?;
        let public = self.root.join(PUBLIC_KEY_PATH);
        let committed = self.primary_fingerprints(&public)?;
        if committed != [env.fingerprint.as_str()] {
            return Err(infra(format!(
                "{} holds the key(s) [{}], but {} names {}: the image would not trust these signatures",
                public.display(),
                committed.join(" "),
                conf.display(),
                env.fingerprint
            )));
        }
        let secret = self.runner.run(
            &Cmd::new(Program::Gpg)
                .arg("--homedir")
                .arg(&env.gnupg_home)
                .args(["--batch", "--with-colons", "--list-secret-keys", "--"])
                .arg(&env.fingerprint)
                .capture()
                .stderr(Stderr::Null),
        )?;
        if !secret.ok() {
            return Err(infra(format!(
                "{} holds no secret key {} (restore it from the offline backup: packaging/README.md, Signing)",
                env.gnupg_home.display(),
                env.fingerprint
            )));
        }
        let signer = Signer {
            fingerprint: env.fingerprint,
            gnupg_home: env.gnupg_home,
            keyring: temp_dir("an rpm keyring")?,
        };
        self.run_ok(&signer.rpmkeys().arg("--import").arg(&public))?;
        Ok(signer)
    }

    fn primary_fingerprints(&self, key: &Path) -> Result<Vec<String>> {
        let home = temp_dir("a gpg home")?;
        let shown = self.runner.run(
            &Cmd::new(Program::Gpg)
                .arg("--homedir")
                .arg(home.path())
                .args(["--batch", "--quiet", "--show-keys", "--with-colons", "--"])
                .arg(key)
                .capture()
                .stderr(Stderr::Null),
        )?;
        if !shown.ok() {
            return Err(infra(format!(
                "{} is not an OpenPGP public key (gpg --show-keys, exit {})",
                key.display(),
                shown.code
            )));
        }
        Ok(rpmout::primary_fingerprints(&shown.stdout)
            .into_iter()
            .map(|f| f.to_ascii_uppercase())
            .collect())
    }

    /// Signs each RPM in place, then verifies it against the committed public key alone.
    /// A `manifest.txt` beside them that lists one follows: new digests and `# sig=`.
    pub fn sign(&self, signer: &Signer, rpms: &[PathBuf]) -> Result<()> {
        let mut by_dir: BTreeMap<PathBuf, Vec<(String, String)>> = BTreeMap::new();
        for rpm in rpms {
            let rpmsign = self.runner.run(
                &Cmd::new(Program::Rpmsign)
                    .arg("--define")
                    .arg(format!("_gpg_path {}", signer.gnupg_home.display()))
                    .arg("--define")
                    .arg(format!("_openpgp_sign_id {}", signer.fingerprint))
                    .arg("--addsign")
                    .arg(rpm)
                    .capture()
                    .stderr(Stderr::ToStdout),
            )?;
            if !rpmsign.ok() {
                return Err(infra(format!(
                    "rpmsign {} failed (exit {}): {}",
                    rpm.display(),
                    rpmsign.code,
                    text::lossy(text::chomp(&rpmsign.stdout))
                )));
            }
            let check = self.runner.run(
                &signer
                    .rpmkeys()
                    .arg("-Kv")
                    .arg(rpm)
                    .capture()
                    .stderr(Stderr::ToStdout),
            )?;
            if !check.ok() || !checksig_ok(&check.stdout, &signer.fingerprint) {
                return Err(infra(format!(
                    "{} does not verify with the committed Apex RPM key {}: {}",
                    rpm.display(),
                    signer.fingerprint,
                    text::lossy(text::chomp(&check.stdout))
                )));
            }
            let dir = rpm.parent().unwrap_or_else(|| Path::new(".")).to_path_buf();
            by_dir
                .entry(dir)
                .or_default()
                .push((fs::file_name(rpm), fs::sha256_file(rpm)?));
        }
        for (dir, digests) in by_dir {
            let path = dir.join("manifest.txt");
            if let Some(listed) = fs::read_opt(&path)?
                && let Some(updated) = manifest::resigned(&listed, &digests, &signer.fingerprint)
            {
                fs::write(&path, &updated)?;
            }
        }
        self.report.log(&format!(
            "signed {} RPM(s) with the Apex RPM key {}",
            rpms.len(),
            signer.fingerprint
        ));
        Ok(())
    }

    pub fn sign_files(&self, rpms: &[PathBuf]) -> Result<()> {
        for rpm in rpms {
            let is_rpm = rpm.extension().is_some_and(|e| e == "rpm");
            if !is_rpm || !rpm.is_file() {
                return Err(usage(format!("{} is not an RPM file", rpm.display())));
            }
        }
        let signer = self.signer()?;
        self.sign(&signer, rpms)
    }

    pub(super) fn sign_built(&self, out: &Path, signer: &Signer) -> Result<()> {
        let listed = fs::read(&out.join("manifest.txt"))?;
        let rpms: Vec<PathBuf> = manifest::entries(&listed)
            .iter()
            .filter(|e| manifest::is_signed_kind(e.kind))
            .map(|e| out.join(text::lossy(e.file)))
            .collect();
        if rpms.is_empty() {
            return Err(infra(
                "the container's manifest.txt lists no built RPM to sign",
            ));
        }
        self.sign(signer, &rpms)
    }
}
