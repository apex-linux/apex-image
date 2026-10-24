//! `pkg.env` is read, never sourced by a shell.

use std::collections::BTreeMap;

use crate::core::names::{is_family_name, is_rpm_name, words};
use crate::core::text::{self, is_space};
use crate::error::ConfigError;

pub const KEYS: [&str; 14] = [
    "source",
    "srpm",
    "on_fail",
    "family",
    "install",
    "pin",
    "mirror",
    "mirror_dev",
    "source1",
    "source1_paths",
    "prep_moved",
    "prep_deleted",
    "kernel_env",
    "nvidia_env",
];
const REQUIRED: [&str; 5] = ["source", "srpm", "on_fail", "family", "install"];
const PAIR_REQUIRED: [&str; 5] = ["source", "family", "install", "kernel_env", "nvidia_env"];
const PAIR_ONLY: [&str; 2] = ["kernel_env", "nvidia_env"];
/// The name ROADMAP S1c, the image labels and apexctl's held list use.
pub const PAIR_FAMILY: &str = "kernel-cachyos";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OnFail {
    Hold,
    Degrade,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PkgEnv {
    pub srpm: String,
    pub on_fail: OnFail,
    pub family: String,
    pub install: Vec<String>,
    pub pin: Option<String>,
    pub mirror: Vec<String>,
    pub mirror_dev: Vec<String>,
    /// As written, leading spaces included: it names a directory of the repository.
    pub source1: Option<String>,
    pub source1_paths: Vec<String>,
    pub prep_moved: Vec<(String, String)>,
    pub prep_deleted: Vec<String>,
}

/// `source=copr-srpm`: the kernel and NVIDIA pair, built by its own job from the pins of
/// `kernel_env` and `nvidia_env`, two files of the recipe directory.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PairEnv {
    pub family: String,
    /// The kernel side's packages; the kmod built for that kernel always joins them.
    pub install: Vec<String>,
    pub kernel_env: String,
    pub nvidia_env: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Recipe {
    Srpm(PkgEnv),
    Pair(PairEnv),
}

fn is_value_char(c: u8) -> bool {
    c.is_ascii_alphanumeric() || b"._/:+ -".contains(&c)
}

fn read_values(file: &str, bytes: &[u8]) -> Result<BTreeMap<&'static str, String>, ConfigError> {
    let mut cfg: BTreeMap<&'static str, String> = BTreeMap::new();
    for (i, line) in text::lines(bytes).into_iter().enumerate() {
        let n = i + 1;
        if text::is_blank_or_comment(line) {
            continue;
        }
        let eq = line.iter().position(|&b| b == b'=');
        let key = eq.map(|eq| &line[..eq]).filter(|key| {
            !key.is_empty()
                && key
                    .iter()
                    .all(|&c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'_')
        });
        let (Some(eq), Some(key)) = (eq, key) else {
            return Err(ConfigError(format!("{file}:{n}: expected KEY=VALUE")));
        };
        let key = String::from_utf8_lossy(key);
        let Some(known) = KEYS.iter().find(|k| **k == key) else {
            return Err(ConfigError(format!("{file}:{n}: unknown key '{key}'")));
        };
        if cfg.contains_key(known) {
            return Err(ConfigError(format!("{file}:{n}: '{key}' is set twice")));
        }
        let value = text::trim_end_space(&line[eq + 1..]);
        if value.is_empty() || !value.iter().copied().all(is_value_char) {
            return Err(ConfigError(format!(
                "{file}:{n}: '{key}' has an empty value or a character outside [A-Za-z0-9._/:+ -]"
            )));
        }
        cfg.insert(known, String::from_utf8_lossy(value).into_owned());
    }
    Ok(cfg)
}

/// A Fedora SRPM recipe; a pair is refused, since only `build` and `key` know one.
pub fn parse(file: &str, bytes: &[u8]) -> Result<PkgEnv, ConfigError> {
    match parse_recipe(file, bytes)? {
        Recipe::Srpm(env) => Ok(env),
        Recipe::Pair(_) => Err(ConfigError(format!(
            "{file}: source=copr-srpm is the kernel pair, which has no Fedora SRPM, series or work tree"
        ))),
    }
}

pub fn parse_recipe(file: &str, bytes: &[u8]) -> Result<Recipe, ConfigError> {
    let cfg = read_values(file, bytes)?;
    match cfg.get("source").map(String::as_str) {
        Some("copr-srpm") => return parse_pair(file, &cfg).map(Recipe::Pair),
        Some(_) => {}
        None => return Err(ConfigError(format!("{file}: 'source' is required"))),
    }
    if let Some(key) = PAIR_ONLY.iter().find(|k| cfg.contains_key(**k)) {
        return Err(ConfigError(format!(
            "{file}: '{key}' belongs to a pair recipe (source=copr-srpm)"
        )));
    }
    parse_srpm(file, &cfg).map(Recipe::Srpm)
}

fn parse_srpm(file: &str, cfg: &BTreeMap<&'static str, String>) -> Result<PkgEnv, ConfigError> {
    for key in REQUIRED {
        if !cfg.contains_key(key) {
            return Err(ConfigError(format!("{file}: '{key}' is required")));
        }
    }
    let get = |key: &str| cfg.get(key).cloned().unwrap_or_default();
    match get("source").as_str() {
        "fedora-srpm" => {}
        "git" => {
            return Err(ConfigError(format!(
                "{file}: source=git is reserved for roadmap S2c"
            )));
        }
        other => {
            return Err(ConfigError(format!(
                "{file}: source must be fedora-srpm or copr-srpm, not '{other}'"
            )));
        }
    }
    let on_fail = match get("on_fail").as_str() {
        "hold" => OnFail::Hold,
        "degrade" => OnFail::Degrade,
        _ => {
            return Err(ConfigError(format!(
                "{file}: on_fail must be hold or degrade"
            )));
        }
    };
    let (srpm, family) = (get("srpm"), get("family"));
    if !is_rpm_name(&srpm) || !is_rpm_name(&family) {
        return Err(ConfigError(format!(
            "{file}: srpm and family are single package names"
        )));
    }
    if !is_family_name(&family) {
        return Err(ConfigError(format!(
            "{file}: family '{family}' must match ^[a-z0-9][a-z0-9._+-]*$, the names the image accepts"
        )));
    }
    let source1 = cfg.get("source1").cloned();
    if let Some(source1) = &source1 {
        if !cfg.contains_key("source1_paths") {
            return Err(ConfigError(format!("{file}: source1 needs source1_paths")));
        }
        if source1.starts_with('/') || source1.contains("..") {
            return Err(ConfigError(format!(
                "{file}: source1 is a directory of this repository"
            )));
        }
    }
    let pin = cfg.get("pin").cloned();
    if (cfg.contains_key("mirror") || cfg.contains_key("mirror_dev")) && pin.is_none() {
        return Err(ConfigError(format!(
            "{file}: mirror and mirror_dev need pin"
        )));
    }
    if let Some(pin) = &pin
        && !is_rpm_name(pin)
    {
        return Err(ConfigError(format!("{file}: pin is a single package name")));
    }
    let mut prep_moved = Vec::new();
    for pair in words(&get("prep_moved")) {
        match pair.split_once(':') {
            Some((from, to)) if !from.is_empty() && !to.is_empty() && !to.contains(':') => {
                prep_moved.push((from.to_owned(), to.to_owned()));
            }
            _ => {
                return Err(ConfigError(format!(
                    "{file}: prep_moved entries are FROM:TO, not '{pair}'"
                )));
            }
        }
    }
    Ok(PkgEnv {
        srpm,
        on_fail,
        family,
        install: words(&get("install")),
        pin,
        mirror: words(&get("mirror")),
        mirror_dev: words(&get("mirror_dev")),
        source1,
        source1_paths: words(&get("source1_paths")),
        prep_moved,
        prep_deleted: words(&get("prep_deleted")),
    })
}

fn parse_pair(file: &str, cfg: &BTreeMap<&'static str, String>) -> Result<PairEnv, ConfigError> {
    for key in PAIR_REQUIRED {
        if !cfg.contains_key(key) {
            return Err(ConfigError(format!(
                "{file}: '{key}' is required for source=copr-srpm"
            )));
        }
    }
    if let Some(key) = cfg.keys().find(|k| !PAIR_REQUIRED.contains(k)) {
        return Err(ConfigError(format!(
            "{file}: '{key}' does not apply to source=copr-srpm: the pair job reads its inputs from kernel_env and nvidia_env"
        )));
    }
    let get = |key: &str| cfg.get(key).cloned().unwrap_or_default();
    let family = get("family");
    if family != PAIR_FAMILY {
        return Err(ConfigError(format!(
            "{file}: the pair's family is {PAIR_FAMILY}, not '{family}'"
        )));
    }
    let install = words(&get("install"));
    if let Some(bad) = install.iter().find(|n| !is_rpm_name(n)) {
        return Err(ConfigError(format!(
            "{file}: install lists package names, not '{bad}'"
        )));
    }
    let (kernel_env, nvidia_env) = (get("kernel_env"), get("nvidia_env"));
    for (key, name) in [("kernel_env", &kernel_env), ("nvidia_env", &nvidia_env)] {
        if !is_recipe_file_name(name) {
            return Err(ConfigError(format!(
                "{file}: {key} names a file of the recipe directory, not '{name}'"
            )));
        }
    }
    if kernel_env == nvidia_env {
        return Err(ConfigError(format!(
            "{file}: kernel_env and nvidia_env are two files"
        )));
    }
    Ok(PairEnv {
        family,
        install,
        kernel_env,
        nvidia_env,
    })
}

fn is_recipe_file_name(name: &str) -> bool {
    !name.starts_with('.')
        && !name.is_empty()
        && name
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"._-".contains(&c))
}

/// The `family=` of a pkg.env, read the way image.sh reads it, without the full parse:
/// the family check must not depend on another package's pkg.env being valid.
pub fn family_of(bytes: &[u8]) -> Option<String> {
    text::lines(bytes).into_iter().find_map(|line| {
        let value = line.strip_prefix(b"family=")?;
        let value = text::trim_start_space(value);
        let end = value
            .iter()
            .position(|&b| is_space(b))
            .unwrap_or(value.len());
        (text::trim_end_space(&value[end..]).is_empty() && end > 0)
            .then(|| String::from_utf8_lossy(&value[..end]).into_owned())
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const GOOD: &str = "# a comment\nsource=fedora-srpm\nsrpm=gnome-shell\non_fail=hold\nfamily=gnome-shell\ninstall=gnome-shell gnome-shell-common\npin=mutter\nmirror=mutter mutter-common\nsource1=desktop/shell\nsource1_paths=apex.gresource.xml js/ui/apex/\nprep_moved=a/b.css:a/apex/stock/b.css\n";

    #[test]
    fn values() {
        let env = parse("pkg.env", GOOD.as_bytes()).unwrap();
        assert_eq!(env.install, ["gnome-shell", "gnome-shell-common"]);
        assert_eq!(env.pin.as_deref(), Some("mutter"));
        assert_eq!(
            env.prep_moved,
            [("a/b.css".to_owned(), "a/apex/stock/b.css".to_owned())]
        );
    }

    #[test]
    fn trailing_space_goes_leading_space_stays() {
        let text = GOOD.replace("source1=desktop/shell", "source1= desktop/shell  ");
        let env = parse("pkg.env", text.as_bytes()).unwrap();
        assert_eq!(env.source1.as_deref(), Some(" desktop/shell"));
    }

    #[test]
    fn a_last_line_without_newline_counts() {
        let text = format!("{}pin=x", GOOD.replace("pin=mutter\n", ""));
        assert_eq!(
            parse("p", text.as_bytes()).unwrap().pin.as_deref(),
            Some("x")
        );
    }

    const PAIR: &str = "source=copr-srpm\nfamily=kernel-cachyos\ninstall=kernel-cachyos kernel-cachyos-core kernel-cachyos-modules\nkernel_env=kernel.env\nnvidia_env=nvidia.env\n";

    fn pair_error(text: &str) -> String {
        parse_recipe("pkg.env", text.as_bytes()).unwrap_err().0
    }

    #[test]
    fn a_pair_recipe() {
        let Recipe::Pair(pair) = parse_recipe("pkg.env", PAIR.as_bytes()).unwrap() else {
            panic!("not a pair");
        };
        assert_eq!(pair.family, PAIR_FAMILY);
        assert_eq!(pair.install.len(), 3);
        assert_eq!(
            (pair.kernel_env.as_str(), pair.nvidia_env.as_str()),
            ("kernel.env", "nvidia.env")
        );
        assert_eq!(family_of(PAIR.as_bytes()).as_deref(), Some(PAIR_FAMILY));
        assert!(matches!(
            parse_recipe("pkg.env", GOOD.as_bytes()).unwrap(),
            Recipe::Srpm(_)
        ));
    }

    #[test]
    fn a_pair_is_not_a_fedora_srpm() {
        let err = parse("pkg.env", PAIR.as_bytes()).unwrap_err().0;
        assert!(err.contains("source=copr-srpm is the kernel pair"), "{err}");
        let err = pair_error(&format!("{GOOD}kernel_env=kernel.env\n"));
        assert!(
            err.contains("'kernel_env' belongs to a pair recipe"),
            "{err}"
        );
    }

    #[test]
    fn a_pair_recipe_is_checked() {
        for (text, says) in [
            (
                PAIR.replace("nvidia_env=nvidia.env\n", ""),
                "'nvidia_env' is required",
            ),
            (
                format!("{PAIR}srpm=kernel-cachyos\n"),
                "'srpm' does not apply",
            ),
            (
                format!("{PAIR}on_fail=degrade\n"),
                "'on_fail' does not apply",
            ),
            (format!("{PAIR}pin=mutter\n"), "'pin' does not apply"),
            (
                PAIR.replace("family=kernel-cachyos", "family=kernel"),
                "the pair's family is kernel-cachyos",
            ),
            (
                PAIR.replace("kernel_env=kernel.env", "kernel_env=../kernel.env"),
                "kernel_env names a file",
            ),
            (
                PAIR.replace("nvidia_env=nvidia.env", "nvidia_env=.env"),
                "nvidia_env names a file",
            ),
            (
                PAIR.replace("nvidia_env=nvidia.env", "nvidia_env=kernel.env"),
                "two files",
            ),
            (
                PAIR.replace("source=copr-srpm", "source=git"),
                "belongs to a pair recipe",
            ),
        ] {
            let err = pair_error(&text);
            assert!(err.contains(says), "{text:?}: {err}");
        }
        let git = GOOD.replace("source=fedora-srpm", "source=git");
        assert!(pair_error(&git).contains("reserved for roadmap S2c"));
    }

    #[test]
    fn family_of_reads_like_image_sh() {
        assert_eq!(family_of(GOOD.as_bytes()).as_deref(), Some("gnome-shell"));
        assert_eq!(family_of(b"family= a  \n").as_deref(), Some("a"));
        assert_eq!(family_of(b"family=a b\n"), None);
    }
}
