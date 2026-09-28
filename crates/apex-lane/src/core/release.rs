//! `.apexN.M`: a pin-only Fedora update changes the key without a commit, and two builds
//! must never share a NEVRA, so M separates the keys of one stock NVR at one N.

use crate::core::manifest::header_field;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StoredBuild {
    pub key: Vec<u8>,
    pub release: Vec<u8>,
    pub stock: Vec<u8>,
}

impl StoredBuild {
    pub fn from_manifest(manifest: &[u8]) -> Self {
        Self {
            key: header_field(manifest, "key"),
            release: header_field(manifest, "release"),
            stock: header_field(manifest, "stock"),
        }
    }
}

pub fn base(stock_release: &str, n: u64) -> String {
    format!("{stock_release}.apex{n}")
}

/// `stored` in the store's directory order. A stored key keeps its release.
pub fn release_for(stored: &[StoredBuild], stock: &str, base: &str, key: &str) -> Vec<u8> {
    let mut top: Option<u64> = None;
    for build in stored {
        if build.key == key.as_bytes() {
            return build.release.clone();
        }
        if build.stock != stock.as_bytes() {
            continue;
        }
        let m = if build.release == base.as_bytes() {
            Some(0)
        } else {
            build
                .release
                .strip_prefix(base.as_bytes())
                .and_then(|rest| rest.strip_prefix(b"."))
                .filter(|digits| !digits.is_empty() && digits.iter().all(u8::is_ascii_digit))
                .map(|digits| {
                    digits.iter().fold(0u64, |n, d| {
                        n.saturating_mul(10).saturating_add(u64::from(d - b'0'))
                    })
                })
        };
        if let Some(m) = m {
            top = Some(top.map_or(m, |t| t.max(m)));
        }
    }
    match top {
        None => base.as_bytes().to_vec(),
        Some(m) => format!("{base}.{}", m.saturating_add(1)).into_bytes(),
    }
}

/// The part of the release after Fedora's.
pub fn suffix<'a>(release: &'a str, stock_release: &str) -> &'a str {
    release.strip_prefix(stock_release).unwrap_or(release)
}
