//! The kernel pair's public source artifact (N6): both SRPMs, the pins and the recipe the
//! job built from, as an OCI layout beside the image build. The runner pushes it.

use std::fmt::Write as _;
use std::path::Path;

use serde_json::json;

use super::Vm;
use super::build::remove_tree;
use crate::core::lock;
use crate::core::manifest::header_field;
use crate::core::pins::{self, Nevra};
use crate::core::text;
use crate::error::{Exit, Result, infra};
use crate::shell::cmd::{Cmd, Program};
use crate::shell::fs;

pub const SOURCE_RECIPE: &str = "recipe";
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
        let pkg = self.the_pair()?.name;
        let set = self.store_pkg(&pkg).join(key);
        if !set.join(SOURCE_RECIPE).is_dir() {
            return Err(infra(format!(
                "store: {} has no {SOURCE_RECIPE}/: the pair predates the source artifact; build it again",
                set.display()
            )));
        }
        let kernel =
            pins::parse_kernel("the stored kernel.env", &fs::read(&set.join("kernel.env"))?)?;
        let nvidia =
            pins::parse_nvidia("the stored nvidia.env", &fs::read(&set.join("nvidia.env"))?)?;
        let whole = header_field(&fs::read(&set.join("manifest.txt"))?, "kmod") != b"-";
        let mut srpms = vec![(&kernel.srpm, kernel.srpm_sha256.as_str())];
        if whole {
            srpms.push((&nvidia.kmod_srpm, nvidia.kmod_srpm_sha256.as_str()));
        }
        let partial = out.with_extension("partial");
        remove_tree(&partial)?;
        let root = partial.join("root");
        fs::create_dir_all(&root.join("srpms"))?;
        for (nevra, sha256) in &srpms {
            self.stage_srpm(nevra, sha256, &root.join("srpms"))?;
        }
        let mut from = set.join(SOURCE_RECIPE).into_os_string();
        from.push("/.");
        fs::create_dir_all(&root.join(SOURCE_RECIPE))?;
        self.run_ok(
            &Cmd::new(Program::Cp)
                .args(["-a", "--"])
                .arg(from)
                .arg(root.join(SOURCE_RECIPE)),
        )?;
        let mut sums = String::new();
        for path in fs::files_under(&root, &|_| true)? {
            let rel = path
                .strip_prefix(&root)
                .unwrap_or(&path)
                .display()
                .to_string();
            let _ = writeln!(sums, "{}  {rel}", fs::sha256_file(&path)?);
        }
        fs::write(&root.join("SHA256SUMS"), sums.as_bytes())?;
        self.write_layout(&partial, key, &srpms)?;
        remove_tree(&root)?;
        remove_tree(out)?;
        self.move_tree(&partial, out)?;
        self.report.log(&format!(
            "sources: {} for {key} ({})",
            out.display(),
            srpms
                .iter()
                .map(|(n, _)| n.to_string())
                .collect::<Vec<_>>()
                .join(", ")
        ));
        Ok(Exit::Ok)
    }

    fn stage_srpm(&self, nevra: &Nevra, sha256: &str, dir: &Path) -> Result<()> {
        let from = self.settings.store.join("mirror").join(nevra.file_name());
        if !from.is_file() || fs::sha256_file(&from)? != sha256 {
            return Err(infra(format!(
                "the mirror has no {} with its pinned sha256",
                nevra.file_name()
            )));
        }
        fs::copy_with_mode(&from, &dir.join(nevra.file_name()))
    }

    /// One uncompressed layer, its bytes fixed by sorted names, zero times and owners.
    fn write_layout(&self, dir: &Path, key: &str, srpms: &[(&Nevra, &str)]) -> Result<()> {
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
                .arg(dir.join("root"))
                .arg("."),
        )?;
        let layer_sha = fs::sha256_file(&layer)?;
        let layer_size = std::fs::metadata(&layer)
            .map_err(|e| fs::io_error("cannot stat", &layer, &e))?
            .len();
        std::fs::rename(&layer, blobs.join(&layer_sha))
            .map_err(|e| fs::io_error("cannot move", &layer, &e))?;
        let names: Vec<String> = srpms.iter().map(|(n, _)| n.to_string()).collect();
        let config = json!({
            "architecture": "amd64",
            "os": "linux",
            "config": {"Labels": {
                "io.github.apex-linux.apex.pair-key": key,
                "io.github.apex-linux.apex.srpms": names.join(","),
                "org.opencontainers.image.description": "The kernel pair's corresponding source: its SRPMs, pins and recipe",
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
