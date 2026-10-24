//! The kernel pair's public source artifact (N6): pair.sh's source set, checked with
//! apex-kernel's source-check.sh, as an OCI layout beside the image build. The runner pushes it.

use std::path::Path;

use serde_json::json;

use super::Vm;
use super::build::remove_tree;
use crate::core::lock;
use crate::core::pins;
use crate::core::text;
use crate::error::{Exit, Result, infra};
use crate::shell::cmd::{Cmd, Program, Stderr};
use crate::shell::fs;

/// pair.sh's `OUT/source`, kept in the stored set under this name.
pub const SOURCE_SET: &str = "source";
const SOURCE_CHECK: &str = "source-check.sh";
const PAIR_FAMILY: &str = "kernel-cachyos";
const LAYER_TYPE: &str = "application/vnd.oci.image.layer.v1.tar";
const MANIFEST_TYPE: &str = "application/vnd.oci.image.manifest.v1+json";
const CONFIG_TYPE: &str = "application/vnd.oci.image.config.v1+json";

impl Vm<'_> {
    pub fn sources(&self, lock_path: &Path, out: &Path) -> Result<Exit> {
        let locked = fs::read(lock_path)?;
        let line = text::lossy(&lock::family_line(&locked, PAIR_FAMILY));
        let mut fields = line.split(' ');
        let (state, key) = (
            fields.next().unwrap_or_default(),
            fields.next().unwrap_or_default(),
        );
        if line.is_empty() || state == "stock" {
            self.report.log(&format!(
                "{}: no kernel pair, so no source artifact",
                lock_path.display()
            ));
            return Ok(Exit::Ok);
        }
        if key.is_empty()
            || !key
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
        {
            return Err(infra(format!(
                "{}: the {PAIR_FAMILY} line names no store key: {line}",
                lock_path.display()
            )));
        }
        let pair = self.the_pair()?;
        let set = self.store_pkg(&pair.name).join(key).join(SOURCE_SET);
        if !set.is_dir() {
            return Err(infra(format!(
                "store: {} is missing: the pair predates pair.sh's source set; build it again",
                set.display()
            )));
        }
        self.source_check(&pair.dir.join(SOURCE_CHECK), &set)?;
        let srpms = Self::set_srpms(&set)?;
        let partial = out.with_extension("partial");
        remove_tree(&partial)?;
        self.write_layout(&partial, &set, key, &srpms)?;
        remove_tree(out)?;
        self.move_tree(&partial, out)?;
        self.report.log(&format!(
            "sources: {} for {key} ({})",
            out.display(),
            srpms.join(", ")
        ));
        Ok(Exit::Ok)
    }

    /// apex-kernel's own check: exit 1 names what the set lacks, exit 2 that it could not run.
    fn source_check(&self, script: &Path, set: &Path) -> Result<()> {
        if !script.is_file() {
            return Err(infra(format!(
                "{} is missing: the pinned apex-kernel predates the source set",
                script.display()
            )));
        }
        let checked = self.runner.run(
            &Cmd::new(Program::Bash)
                .arg(script)
                .arg(set)
                .capture()
                .stderr(Stderr::Capture),
        )?;
        let last = text::lossy(text::tail_lines(&checked.stderr, 1))
            .trim()
            .to_owned();
        match checked.code {
            0 => Ok(()),
            1 => Err(infra(format!(
                "{SOURCE_CHECK} refused {}: {last}; no source artifact",
                set.display()
            ))),
            code => Err(infra(format!(
                "{SOURCE_CHECK} could not run (exit {code}): {last}"
            ))),
        }
    }

    /// The pinned SRPMs the set holds, as NEVRAs, for the artifact's label.
    fn set_srpms(set: &Path) -> Result<Vec<String>> {
        let recipe = set.join("recipe");
        let kernel = pins::parse_kernel(
            "the source set's kernel.env",
            &fs::read(&recipe.join("kernel.env"))?,
        )?;
        let nvidia = pins::parse_nvidia(
            "the source set's nvidia.env",
            &fs::read(&recipe.join("nvidia.env"))?,
        )?;
        Ok([kernel.srpm, nvidia.kmod_srpm]
            .into_iter()
            .filter(|n| set.join("srpms").join(n.file_name()).is_file())
            .map(|n| n.to_string())
            .collect())
    }

    /// One uncompressed layer of SET as it is, its bytes fixed by sorted names, zero
    /// times and owners.
    fn write_layout(&self, dir: &Path, set: &Path, key: &str, srpms: &[String]) -> Result<()> {
        let blobs = dir.join("blobs/sha256");
        fs::create_dir_all(&blobs)?;
        let layer = dir.join("layer.tar");
        self.run_ok(
            &Cmd::new(Program::Tar)
                .args([
                    "--sort=name",
                    "--mtime=@0",
                    "--owner=0",
                    "--group=0",
                    "--numeric-owner",
                    "--format=posix",
                    "--pax-option=exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime",
                    "-cf",
                ])
                .arg(&layer)
                .arg("-C")
                .arg(set)
                .arg("."),
        )?;
        let layer_sha = fs::sha256_file(&layer)?;
        let layer_size = std::fs::metadata(&layer)
            .map_err(|e| fs::io_error("cannot stat", &layer, &e))?
            .len();
        std::fs::rename(&layer, blobs.join(&layer_sha))
            .map_err(|e| fs::io_error("cannot move", &layer, &e))?;
        let config = json!({
            "architecture": "amd64",
            "os": "linux",
            "config": {"Labels": {
                "io.github.apex-linux.apex.pair-key": key,
                "io.github.apex-linux.apex.srpms": srpms.join(","),
                "org.opencontainers.image.description": "The kernel pair's corresponding source: its SRPMs, recipe, licences and README.source",
            }},
            "rootfs": {"type": "layers", "diff_ids": [format!("sha256:{layer_sha}")]},
        });
        let (config_sha, config_size) = put_blob(&blobs, &config)?;
        let manifest = json!({
            "schemaVersion": 2,
            "mediaType": MANIFEST_TYPE,
            "config": {"mediaType": CONFIG_TYPE, "digest": format!("sha256:{config_sha}"), "size": config_size},
            "layers": [{"mediaType": LAYER_TYPE, "digest": format!("sha256:{layer_sha}"), "size": layer_size}],
        });
        let (manifest_sha, manifest_size) = put_blob(&blobs, &manifest)?;
        let index = json!({
            "schemaVersion": 2,
            "manifests": [{
                "mediaType": MANIFEST_TYPE,
                "digest": format!("sha256:{manifest_sha}"),
                "size": manifest_size,
                "annotations": {"org.opencontainers.image.ref.name": key},
            }],
        });
        fs::write(&dir.join("index.json"), index.to_string().as_bytes())?;
        fs::write(
            &dir.join("oci-layout"),
            br#"{"imageLayoutVersion":"1.0.0"}"#,
        )
    }
}

fn put_blob(blobs: &Path, value: &serde_json::Value) -> Result<(String, usize)> {
    let bytes = value.to_string().into_bytes();
    let sha = crate::core::hash::sha256_hex(&bytes);
    fs::write(&blobs.join(&sha), &bytes)?;
    Ok((sha, bytes.len()))
}
