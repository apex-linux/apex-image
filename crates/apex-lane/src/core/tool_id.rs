//! The lane's own part of the content key: its source at HEAD and the registry crates
//! compiled into it. Tests, dev-dependencies and unrelated workspace crates do not count.

use std::collections::{BTreeSet, VecDeque};

use crate::core::hash::sha256_hex;
use crate::error::ConfigError;

pub const CRATE: &str = "apex-lane";
pub const SOURCE_PATHS: [&str; 2] = ["crates/apex-lane/Cargo.toml", "crates/apex-lane/src"];

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
struct Package {
    name: String,
    version: String,
    source: Option<String>,
    checksum: Option<String>,
    dependencies: Vec<String>,
}

fn parse_lock(cargo_lock: &str) -> Result<Vec<Package>, ConfigError> {
    let doc: toml::Table = cargo_lock
        .parse()
        .map_err(|e| ConfigError(format!("Cargo.lock: {e}")))?;
    let packages = doc
        .get("package")
        .and_then(toml::Value::as_array)
        .ok_or_else(|| ConfigError("Cargo.lock has no [[package]]".into()))?;
    let text =
        |t: &toml::Table, key: &str| t.get(key).and_then(toml::Value::as_str).map(str::to_owned);
    packages
        .iter()
        .map(|p| {
            let t = p
                .as_table()
                .ok_or_else(|| ConfigError("Cargo.lock: a package is not a table".into()))?;
            Ok(Package {
                name: text(t, "name")
                    .ok_or_else(|| ConfigError("Cargo.lock: a package without a name".into()))?,
                version: text(t, "version").unwrap_or_default(),
                source: text(t, "source"),
                checksum: text(t, "checksum"),
                dependencies: t
                    .get("dependencies")
                    .and_then(toml::Value::as_array)
                    .map(|deps| {
                        deps.iter()
                            .filter_map(|d| d.as_str().map(str::to_owned))
                            .collect()
                    })
                    .unwrap_or_default(),
            })
        })
        .collect()
}

/// The package names of `[dependencies]` and `[build-dependencies]` (target tables too),
/// renames resolved against the workspace's `[workspace.dependencies]`.
fn roots(lane_toml: &str, workspace_toml: &str) -> Result<BTreeSet<String>, ConfigError> {
    let lane: toml::Table = lane_toml
        .parse()
        .map_err(|e| ConfigError(format!("{CRATE}/Cargo.toml: {e}")))?;
    let workspace: toml::Table = workspace_toml
        .parse()
        .map_err(|e| ConfigError(format!("Cargo.toml: {e}")))?;
    let workspace_deps = workspace
        .get("workspace")
        .and_then(|w| w.get("dependencies"))
        .and_then(toml::Value::as_table);
    let mut tables = Vec::new();
    for kind in ["dependencies", "build-dependencies"] {
        tables.extend(lane.get(kind).and_then(toml::Value::as_table));
        if let Some(targets) = lane.get("target").and_then(toml::Value::as_table) {
            tables.extend(
                targets
                    .values()
                    .filter_map(|t| t.get(kind).and_then(toml::Value::as_table)),
            );
        }
    }
    let package_of = |v: &toml::Value| {
        v.get("package")
            .and_then(toml::Value::as_str)
            .map(str::to_owned)
    };
    let mut out = BTreeSet::new();
    for table in tables {
        for (key, value) in table {
            let inherited = value.get("workspace").and_then(toml::Value::as_bool) == Some(true);
            let name = package_of(value)
                .or_else(|| {
                    inherited
                        .then(|| workspace_deps.and_then(|w| w.get(key)).and_then(package_of))
                        .flatten()
                })
                .unwrap_or_else(|| key.clone());
            out.insert(name);
        }
    }
    Ok(out)
}

/// `name`, `name version` or `name version (source)`.
fn resolve<'a>(packages: &'a [Package], dependency: &str) -> Vec<&'a Package> {
    let mut parts = dependency.splitn(3, ' ');
    let name = parts.next().unwrap_or_default();
    let version = parts.next();
    let source = parts
        .next()
        .map(|s| s.trim_start_matches('(').trim_end_matches(')'));
    packages
        .iter()
        .filter(|p| {
            p.name == name
                && version.is_none_or(|v| p.version == v)
                && source.is_none_or(|s| p.source.as_deref() == Some(s))
        })
        .collect()
}

pub fn preimage(
    ls_tree: &[u8],
    lane_toml: &str,
    workspace_toml: &str,
    cargo_lock: &str,
) -> Result<Vec<u8>, ConfigError> {
    let packages = parse_lock(cargo_lock)?;
    let lane = packages
        .iter()
        .find(|p| p.name == CRATE && p.source.is_none())
        .ok_or_else(|| ConfigError(format!("Cargo.lock has no {CRATE}")))?;
    let roots = roots(lane_toml, workspace_toml)?;
    let mut queue: VecDeque<&Package> = VecDeque::new();
    for dependency in &lane.dependencies {
        let name = dependency.split(' ').next().unwrap_or_default();
        if roots.contains(name) {
            let found = resolve(&packages, dependency);
            if found.is_empty() {
                return Err(ConfigError(format!(
                    "Cargo.lock: {CRATE} needs {dependency}, which it does not list"
                )));
            }
            queue.extend(found);
        }
    }
    let mut seen: BTreeSet<&Package> = BTreeSet::new();
    while let Some(p) = queue.pop_front() {
        if p.source.is_none() {
            return Err(ConfigError(format!(
                "{CRATE} depends on the workspace crate {}: the tool id counts only registry crates",
                p.name
            )));
        }
        if seen.insert(p) {
            for dependency in &p.dependencies {
                queue.extend(resolve(&packages, dependency));
            }
        }
    }
    let mut out = b"apex-lane tool 1\n".to_vec();
    out.extend_from_slice(ls_tree);
    let mut deps: Vec<&Package> = seen.into_iter().collect();
    deps.sort_by(|a, b| (&a.name, &a.version).cmp(&(&b.name, &b.version)));
    for p in deps {
        out.extend_from_slice(
            format!(
                "dep {} {} {} {}\n",
                p.name,
                p.version,
                p.source.as_deref().unwrap_or("-"),
                p.checksum.as_deref().unwrap_or("-")
            )
            .as_bytes(),
        );
    }
    Ok(out)
}

pub fn tool_id(
    ls_tree: &[u8],
    lane_toml: &str,
    workspace_toml: &str,
    cargo_lock: &str,
) -> Result<String, ConfigError> {
    preimage(ls_tree, lane_toml, workspace_toml, cargo_lock).map(|p| sha256_hex(&p))
}

#[cfg(test)]
mod tests {
    use super::*;

    const WORKSPACE: &str = "[workspace]\n[workspace.dependencies]\nre = { package = \"regex\", version = \"1\" }\nserde = \"1\"\n";
    const LANE: &str = "[package]\nname = \"apex-lane\"\n[dependencies]\nre.workspace = true\n[dev-dependencies]\nproptest = \"1\"\n";

    fn lock(extra: &str) -> String {
        format!(
            r#"version = 4

[[package]]
name = "apex-lane"
version = "0.1.0"
dependencies = [
 "proptest",
 "regex",
]

[[package]]
name = "memchr"
version = "2.8.3"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "aa"

[[package]]
name = "proptest"
version = "1.11.0"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "bb"

[[package]]
name = "regex"
version = "1.13.1"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "cc"
dependencies = [
 "memchr",
]
{extra}"#
        )
    }

    #[test]
    fn the_closure_follows_renames_and_leaves_dev_dependencies_out() {
        let text = String::from_utf8(
            preimage(
                b"100644 blob x\tcrates/apex-lane/src/main.rs\n",
                LANE,
                WORKSPACE,
                &lock(""),
            )
            .unwrap(),
        )
        .unwrap();
        assert_eq!(
            text,
            "apex-lane tool 1\n100644 blob x\tcrates/apex-lane/src/main.rs\ndep memchr 2.8.3 registry+https://github.com/rust-lang/crates.io-index aa\ndep regex 1.13.1 registry+https://github.com/rust-lang/crates.io-index cc\n"
        );
    }

    #[test]
    fn a_dev_dependency_bump_keeps_the_id() {
        let a = tool_id(b"", LANE, WORKSPACE, &lock("")).unwrap();
        let b = tool_id(
            b"",
            LANE,
            WORKSPACE,
            &lock("")
                .replace("1.11.0", "1.12.0")
                .replace("\"bb\"", "\"bd\""),
        )
        .unwrap();
        assert_eq!(a, b);
        let c = tool_id(b"", LANE, WORKSPACE, &lock("").replace("\"aa\"", "\"ab\"")).unwrap();
        assert_ne!(a, c);
    }

    #[test]
    fn a_workspace_crate_is_refused() {
        let lane =
            format!("{LANE}\n[build-dependencies]\napex-boot = {{ path = \"../apex-boot\" }}\n");
        let lock = lock("").replace(" \"regex\",\n", " \"apex-boot\",\n \"regex\",\n")
            + "\n[[package]]\nname = \"apex-boot\"\nversion = \"0.1.0\"\n";
        let err = tool_id(b"", &lane, WORKSPACE, &lock).unwrap_err();
        assert!(err.0.contains("workspace crate apex-boot"), "{err}");
    }
}
