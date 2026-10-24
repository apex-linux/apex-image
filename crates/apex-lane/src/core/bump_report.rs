//! The report of a kernel point bump: what changed in the pair's inputs, for its PR.

use std::collections::BTreeMap;
use std::fmt::Write as _;

use crate::core::text;

#[derive(Debug, Default, PartialEq, Eq)]
pub struct ConfigDiff {
    pub added: Vec<String>,
    pub changed: Vec<String>,
    pub removed: Vec<String>,
}

impl ConfigDiff {
    /// New symbols come with every release; anything else is the owner's to read.
    pub fn holds(&self) -> bool {
        !self.changed.is_empty() || !self.removed.is_empty()
    }
}

/// `CONFIG_X=v` and `# CONFIG_X is not set` (as `n`), by symbol.
fn config_values(bytes: &[u8]) -> BTreeMap<String, String> {
    let mut values = BTreeMap::new();
    for line in text::lines(bytes) {
        let line = text::lossy(line);
        if let Some(rest) = line.strip_prefix("# ")
            && let Some(symbol) = rest.strip_suffix(" is not set")
            && symbol.starts_with("CONFIG_")
        {
            values.insert(symbol.to_owned(), "n".to_owned());
        } else if let Some((symbol, value)) = line.split_once('=')
            && symbol.starts_with("CONFIG_")
        {
            values.insert(symbol.to_owned(), value.to_owned());
        }
    }
    values
}

pub fn config_diff(old: &[u8], new: &[u8]) -> ConfigDiff {
    let (old, new) = (config_values(old), config_values(new));
    let mut diff = ConfigDiff::default();
    for (symbol, value) in &new {
        match old.get(symbol) {
            None => diff.added.push(format!("{symbol}={value}")),
            Some(was) if was != value => diff.changed.push(format!("{symbol}: {was} -> {value}")),
            Some(_) => {}
        }
    }
    for (symbol, was) in &old {
        if !new.contains_key(symbol) {
            diff.removed.push(format!("{symbol} (was {was})"));
        }
    }
    diff
}

/// `git verify-tag --raw`: a good signature whose key, or primary key, is exactly `fpr`.
pub fn tag_signed_by(status: &[u8], fpr: &str) -> bool {
    text::lines(status).into_iter().any(|line| {
        let fields: Vec<String> = text::lossy(line)
            .split_whitespace()
            .map(str::to_owned)
            .collect();
        fields.get(1).map(String::as_str) == Some("VALIDSIG")
            && fields.first().map(String::as_str) == Some("[GNUPG:]")
            && (fields.get(2).is_some_and(|f| f.eq_ignore_ascii_case(fpr))
                || fields.last().is_some_and(|f| f.eq_ignore_ascii_case(fpr)))
    })
}

#[derive(Debug, PartialEq, Eq)]
pub enum Same {
    Identical,
    Changed { old: String, new: String },
}

impl Same {
    pub fn of(old: &str, new: &str) -> Self {
        if old == new {
            Self::Identical
        } else {
            Self::Changed {
                old: old.to_owned(),
                new: new.to_owned(),
            }
        }
    }

    fn shown(&self) -> String {
        match self {
            Self::Identical => "byte-identical".into(),
            Self::Changed { old, new } => format!("changed, sha256 {old} -> {new}"),
        }
    }
}

#[derive(Debug)]
pub struct Report {
    pub from: String,
    pub to: String,
    pub tag: String,
    pub tag_key: String,
    pub source0: String,
    pub config: ConfigDiff,
    pub bore: Same,
    pub nvidia_patches: Option<Vec<String>>,
}

pub fn render(r: &Report) -> String {
    let mut out = format!("Bump report: {} -> {}\n\n", r.from, r.to);
    let _ = writeln!(
        out,
        "- tag {}: git verify-tag gives VALIDSIG for {} alone",
        r.tag, r.tag_key
    );
    let _ = writeln!(
        out,
        "- Source0 {}: byte-identical to the tag's git archive, both uncompressed",
        r.source0
    );
    let _ = writeln!(out, "- BORE patch: {}", r.bore.shown());
    if r.config == ConfigDiff::default() {
        let _ = writeln!(out, "- config: byte-identical in every symbol");
    } else {
        let _ = writeln!(
            out,
            "- config: {} new, {} changed, {} removed",
            r.config.added.len(),
            r.config.changed.len(),
            r.config.removed.len()
        );
        for (sign, lines) in [
            ("+", &r.config.added),
            ("~", &r.config.changed),
            ("-", &r.config.removed),
        ] {
            for line in lines {
                let _ = writeln!(out, "  {sign} {line}");
            }
        }
    }
    match &r.nvidia_patches {
        Some(patches) if patches.is_empty() => {
            let _ = writeln!(out, "- NVIDIA kmod patches: none");
        }
        Some(patches) => {
            let _ = writeln!(out, "- NVIDIA kmod patches: {}", patches.join(" "));
        }
        None => {
            let _ = writeln!(
                out,
                "- NVIDIA kmod patches: the kmod SRPM is not mirrored yet"
            );
        }
    }
    if r.config.holds() {
        let _ = writeln!(
            out,
            "\nHeld: the config changes beyond new symbols, so the owner reads it before the pair takes it."
        );
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn config_diffs() {
        let old = b"# comment\nCONFIG_A=y\nCONFIG_B=m\n# CONFIG_C is not set\nCONFIG_D=\"x\"\n";
        let same = config_diff(old, old);
        assert_eq!(same, ConfigDiff::default());
        assert!(!same.holds());
        let added = config_diff(
            old,
            &[&old[..], b"CONFIG_E=y\n# CONFIG_F is not set\n"].concat(),
        );
        assert_eq!(added.added, ["CONFIG_E=y", "CONFIG_F=n"]);
        assert!(!added.holds(), "new symbols alone go ahead");
        let moved = config_diff(old, b"CONFIG_A=y\nCONFIG_B=y\nCONFIG_C=y\n");
        assert_eq!(moved.changed, ["CONFIG_B: m -> y", "CONFIG_C: n -> y"]);
        assert_eq!(moved.removed, ["CONFIG_D (was \"x\")"]);
        assert!(moved.holds());
    }

    #[test]
    fn tag_signers() {
        let fpr = "E8B9AA39F054E30E8290D492C3C4820857F654FE";
        let good = format!(
            "[GNUPG:] NEWSIG\n[GNUPG:] GOODSIG C3C4820857F654FE Peter\n[GNUPG:] VALIDSIG {fpr} 2026-10-23 1761225240 0 4 0 22 10 00 {fpr}\n"
        );
        assert!(tag_signed_by(good.as_bytes(), fpr));
        assert!(tag_signed_by(good.as_bytes(), &fpr.to_ascii_lowercase()));
        let sub = format!(
            "[GNUPG:] VALIDSIG {} 2026-10-23 1 0 4 0 22 10 00 {fpr}\n",
            "A".repeat(40)
        );
        assert!(
            tag_signed_by(sub.as_bytes(), fpr),
            "a subkey of the pinned key"
        );
        assert!(!tag_signed_by(good.as_bytes(), &"B".repeat(40)));
        assert!(!tag_signed_by(
            b"[GNUPG:] BADSIG C3C4820857F654FE Peter\n",
            fpr
        ));
        assert!(!tag_signed_by(format!("VALIDSIG {fpr}\n").as_bytes(), fpr));
    }

    #[test]
    fn a_held_report() {
        let r = Report {
            from: "kernel-cachyos-7.3.0-4.cachyos1.fc45".into(),
            to: "kernel-cachyos-7.3.1-1.cachyos1.fc45".into(),
            tag: "cachyos-7.3.1-1".into(),
            tag_key: "F".into(),
            source0: "cachyos-7.3.1-1.tar.gz".into(),
            config: config_diff(b"CONFIG_A=y\n", b"CONFIG_A=m\n"),
            bore: Same::of("a", "a"),
            nvidia_patches: Some(vec!["anatase-1.patch".into(), "anatase-2.patch".into()]),
        };
        let shown = render(&r);
        assert!(shown.contains("- BORE patch: byte-identical\n"), "{shown}");
        assert!(
            shown.contains("- config: 0 new, 1 changed, 0 removed\n  ~ CONFIG_A: y -> m\n"),
            "{shown}"
        );
        assert!(shown.contains("- NVIDIA kmod patches: anatase-1.patch anatase-2.patch\n"));
        assert!(shown.ends_with("before the pair takes it.\n"));
    }
}
