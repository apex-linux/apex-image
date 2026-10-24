use std::path::{Path, PathBuf};

use crate::core::names::is_pkg_name;
use crate::core::pkg_env::{self, PairEnv, PkgEnv, Recipe};
use crate::core::series::{self, Files};
use crate::core::spec_edit::{self, SpecEdit};
use crate::error::{Result, usage};
use crate::shell::fs;

#[derive(Debug, Clone)]
pub struct Pkg {
    pub name: String,
    pub recipe_root: PathBuf,
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

pub fn all(root: &Path) -> Result<Vec<String>> {
    Ok(fs::sorted_entries(&pkgs_dir(root))?
        .into_iter()
        .filter(|d| d.join("pkg.env").is_file())
        .map(|d| fs::file_name(&d))
        .collect())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Parse {
    Full,
    Export,
}

pub fn read_file(path: &Path) -> Result<Vec<u8>> {
    fs::read_opt(path)?.ok_or_else(|| usage(format!("{} not found", path.display())))
}

/// The kernel pair of a `source=copr-srpm` recipe.
#[derive(Debug, Clone)]
pub struct PairPkg {
    pub name: String,
    pub recipe_root: PathBuf,
    pub dir: PathBuf,
    pub env: PairEnv,
}

/// `Some` when `name`'s pkg.env is a pair recipe; a Fedora SRPM recipe goes through `load`.
pub fn load_pair(root: &Path, name: &str) -> Result<Option<PairPkg>> {
    if !is_pkg_name(name) {
        return Err(usage(format!("bad package name '{name}'")));
    }
    let dir = pkgs_dir(root).join(name);
    let env_path = dir.join("pkg.env");
    let Some(bytes) = fs::read_opt(&env_path)? else {
        return Ok(None);
    };
    match pkg_env::parse_recipe(&env_path.display().to_string(), &bytes)? {
        Recipe::Srpm(_) => Ok(None),
        Recipe::Pair(env) => Ok(Some(PairPkg {
            name: name.to_owned(),
            recipe_root: root.to_path_buf(),
            dir,
            env,
        })),
    }
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
        recipe_root: root.to_path_buf(),
        dir,
        env,
        series,
        spec_edit,
    })
}

/// One lane package per family: `lock_put` replaces a family's records whole, so a
/// second package would silently drop the first one's RPMs.
pub fn check_family_unique(roots: &[PathBuf], name: &str, family: &str) -> Result<()> {
    for root in roots {
        for other in all(root)? {
            if other == name {
                continue;
            }
            let path = pkgs_dir(root).join(&other).join("pkg.env");
            let family_of = fs::read_opt(&path)?.and_then(|b| pkg_env::family_of(&b));
            if family_of.as_deref() == Some(family) {
                return Err(usage(format!(
                    "packages {name} and {other} share the family {family}; the lane takes one package per family"
                )));
            }
        }
    }
    Ok(())
}
