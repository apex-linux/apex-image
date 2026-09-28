//! `pkg.env` is read, never sourced by a shell.

use std::collections::BTreeMap;

use crate::core::names::{is_family_name, is_rpm_name, words};
use crate::core::text::{self, is_space};
use crate::error::ConfigError;

pub const KEYS: [&str; 12] = [
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
];
const REQUIRED: [&str; 5] = ["source", "srpm", "on_fail", "family", "install"];

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

pub fn parse(file: &str, bytes: &[u8]) -> Result<PkgEnv, ConfigError> {
    let cfg = read_values(file, bytes)?;
    for key in REQUIRED {
        if !cfg.contains_key(key) {
            return Err(ConfigError(format!("{file}: '{key}' is required")));
        }
    }
    let get = |key: &str| cfg.get(key).cloned().unwrap_or_default();
    match get("source").as_str() {
        "fedora-srpm" => {}
        reserved @ ("copr-srpm" | "git") => {
            return Err(ConfigError(format!(
                "{file}: source={reserved} is reserved for roadmap S1c/S2c"
            )));
        }
        other => {
            return Err(ConfigError(format!(
                "{file}: source must be fedora-srpm, not '{other}'"
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

    #[test]
    fn family_of_reads_like_image_sh() {
        assert_eq!(family_of(GOOD.as_bytes()).as_deref(), Some("gnome-shell"));
        assert_eq!(family_of(b"family= a  \n").as_deref(), Some("a"));
        assert_eq!(family_of(b"family=a b\n"), None);
    }
}
