//! The Fedora releases the lane builds for: 45 from image/Containerfile, and a next release
//! (ROADMAP S6) from image/fedora/N.env, with a store of its own.

use std::path::{Path, PathBuf};

pub const CURRENT: &str = "45";

/// Fedora's primary release keys, as F45's signed fedora-gpg-keys ships them.
const RELEASE_KEYS: [(&str, &str); 2] = [
    ("45", "4F50A6114CD5C6976A7F1179655A4B02F577861E"),
    ("46", "D924B10D3E810DABDD8B56B596E7E91491211FCE"),
];

pub fn key_fpr(fedora: &str) -> Option<&'static str> {
    RELEASE_KEYS
        .iter()
        .find(|(release, _)| *release == fedora)
        .map(|(_, fpr)| *fpr)
}

pub fn is_next(fedora: &str) -> bool {
    fedora != CURRENT
}

/// `APEX_FEDORA`: empty means 45.
pub fn parse(value: &str) -> Result<String, String> {
    match value {
        "" => Ok(CURRENT.to_owned()),
        v if v.len() == 2 && v.bytes().all(|c| c.is_ascii_digit()) => Ok(v.to_owned()),
        v => Err(format!(
            "APEX_FEDORA must be a Fedora release such as 45, not '{v}'"
        )),
    }
}

/// A next release keeps its state below the 45 store, so the 45 rpms.lock is out of reach.
pub fn store(base: &Path, fedora: &str) -> PathBuf {
    if is_next(fedora) {
        base.join("next")
    } else {
        base.to_path_buf()
    }
}

pub fn env_path(root: &Path, fedora: &str) -> PathBuf {
    root.join("image/fedora").join(format!("{fedora}.env"))
}

/// NAME's value in an image/fedora/N.env, or "".
pub fn env_value(text: &[u8], name: &str) -> String {
    String::from_utf8_lossy(text)
        .lines()
        .find_map(|l| l.strip_prefix(name)?.strip_prefix('='))
        .unwrap_or_default()
        .trim()
        .to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn releases() {
        assert_eq!(parse("").unwrap(), "45");
        assert_eq!(parse("46").unwrap(), "46");
        for bad in ["4", "460", "f46", "46 "] {
            assert!(parse(bad).is_err(), "{bad}");
        }
        assert_eq!(
            key_fpr("45"),
            Some("4F50A6114CD5C6976A7F1179655A4B02F577861E")
        );
        assert!(key_fpr("47").is_none());
        assert!(!is_next("45") && is_next("46"));
    }

    #[test]
    fn a_next_store_is_below_the_45_store() {
        let base = Path::new("/home/b/apex-store");
        assert_eq!(store(base, "45"), base);
        assert_eq!(store(base, "46"), base.join("next"));
        assert!(
            !store(base, "46")
                .join("rpms.lock")
                .starts_with(base.join("rpms.lock"))
        );
    }

    #[test]
    fn env_values() {
        let text = b"# c\nFEDORA=46\nBASE=registry.fedoraproject.org/fedora-bootc@sha256:ab\nBASE_SOURCE=rawhide\n";
        assert_eq!(
            env_value(text, "BASE"),
            "registry.fedoraproject.org/fedora-bootc@sha256:ab"
        );
        assert_eq!(env_value(text, "BASE_SOURCE"), "rawhide");
        assert_eq!(env_value(text, "FEDORA_KEY_FPR"), "");
    }
}
