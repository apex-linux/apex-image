//! A lane package as the checkout holds it: `packaging/pkgs/<pkg>/`.

use std::path::{Path, PathBuf};

use crate::core::names::is_pkg_name;
use crate::core::pkg_env::{self, PkgEnv};
use crate::core::series::{self, Files};
use crate::core::spec_edit::{self, SpecEdit};
use crate::error::{Result, usage};
use crate::shell::fs;

#[derive(Debug, Clone)]
pub struct Pkg {
    pub name: String,
    pub dir: PathBuf,
    pub env: PkgEnv,
    pub series: Vec<String>,
    /// Not parsed for `export`.
    pub spec_edit: Option<SpecEdit>,
}

impl Pkg {
    pub fn patch(&self, entry: &str) -> PathBuf {
        self.dir.join("patches").join(entry)
    }

    pub fn check_sh(&self) -> PathBuf {
        self.dir.join("check.sh")
    }
}

pub fn pkgs_dir(root: &Path) -> PathBuf {
    root.join("packaging/pkgs")
}

/// Every package of the lane: a directory of packaging/pkgs with a pkg.env, in byte order.
pub fn all(root: &Path) -> Result<Vec<String>> {
    Ok(fs::sorted_entries(&pkgs_dir(root))?
        .into_iter()
        .filter(|d| d.join("pkg.env").is_file())
        .map(|d| fs::file_name(&d))
        .collect())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Parse {
    /// pkg.env, series with its files, spec-edit.
    Full,
    /// pkg.env and series without file checks.
    Export,
}

pub fn read_file(path: &Path) -> Result<Vec<u8>> {
    fs::read_opt(path)?.ok_or_else(|| usage(format!("{} not found", path.display())))
}

pub fn load(root: &Path, name: &str, parse: Parse) -> Result<Pkg> {
    if !is_pkg_name(name) {
        return Err(usage(format!("bad package name '{name}'")));
    }
    let dir = pkgs_dir(root).join(name);
    let env_path = dir.join("pkg.env");
    if parse == Parse::Full && !env_path.is_file() {
        return Err(usage(format!(
            "no {} (packages: {})",
            env_path.display(),
            all(root)?.join(" ")
        )));
    }
    let env = pkg_env::parse(&env_path.display().to_string(), &read_file(&env_path)?)?;
    let series_path = dir.join("series");
    let patches_dir = dir.join("patches");
    let series_bytes = fs::read_opt(&series_path)?
        .ok_or_else(|| usage(format!("series file {} not found", series_path.display())))?;
    let exists = |entry: &str| patches_dir.join(entry).is_file();
    let patches_label = patches_dir.display().to_string();
    let files = match parse {
        Parse::Full => Files::Check {
            dir: &patches_label,
            exists: &exists,
        },
        Parse::Export => Files::Skip,
    };
    let series = series::parse(&series_path.display().to_string(), &series_bytes, files)?;
    let spec_edit = match parse {
        Parse::Full => {
            let path = dir.join("spec-edit");
            Some(spec_edit::parse(
                &path.display().to_string(),
                &read_file(&path)?,
            )?)
        }
        Parse::Export => None,
    };
    Ok(Pkg {
        name: name.to_owned(),
        dir,
        env,
        series,
        spec_edit,
    })
}

/// One lane package per family: `lock_put` replaces a family's records whole, so a
/// second package would silently drop the first one's RPMs.
pub fn check_family_unique(root: &Path, pkg: &Pkg) -> Result<()> {
    for other in all(root)? {
        if other == pkg.name {
            continue;
        }
        let path = pkgs_dir(root).join(&other).join("pkg.env");
        let family = fs::read_opt(&path)?.and_then(|b| pkg_env::family_of(&b));
        if family.as_deref() == Some(pkg.env.family.as_str()) {
            return Err(usage(format!(
                "packages {} and {other} share the family {}; the lane takes one package per family",
                pkg.name, pkg.env.family
            )));
        }
    }
    Ok(())
}
