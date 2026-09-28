//! The container digest is recorded in the manifest, not hashed: dependency drift does not
//! warrant a rebuild.

use std::fmt::Write as _;

use crate::core::hash::sha256_hex;

pub const SCHEMA: u32 = 2;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KeyInputs {
    pub pkg: String,
    pub tool: String,
    /// sha256 of check.sh.
    pub check: Option<String>,
    /// The binary repositories and the setopts, as the dnf calls pass them.
    pub repos: String,
    pub stock: String,
    pub pin_evr: Option<String>,
    pub pkg_env: String,
    pub spec_edit: String,
    /// (series entry, sha256), in series order.
    pub patches: Vec<(String, String)>,
    pub source1_tree: Option<String>,
    pub n: u64,
}

pub fn preimage(k: &KeyInputs) -> String {
    let or_dash = |v: &Option<String>| {
        v.clone()
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| "-".into())
    };
    let mut out = format!(
        "apex lane key {SCHEMA}\npkg {}\nlane {}\ncheck {}\nrepos {}\nstock {}\npin {}\npkg.env {}\nspec-edit {}\n",
        k.pkg,
        k.tool,
        or_dash(&k.check),
        k.repos,
        k.stock,
        or_dash(&k.pin_evr),
        k.pkg_env,
        k.spec_edit,
    );
    for (entry, sha) in &k.patches {
        let _ = writeln!(out, "patch {entry} {sha}");
    }
    let _ = write!(
        out,
        "source1 {}\nrelease .apex{}\n",
        or_dash(&k.source1_tree),
        k.n
    );
    out
}

pub fn content_key(stock: &str, preimage: &str) -> String {
    format!("{stock}-s{}", &sha256_hex(preimage.as_bytes())[..12])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn preimage_text() {
        let k = KeyInputs {
            pkg: "gnome-shell".into(),
            tool: "t".repeat(64),
            check: None,
            repos: "--repo=fedora --repo=updates --setopt=install_weak_deps=False".into(),
            stock: "gnome-shell-51.0-1.fc45".into(),
            pin_evr: Some("51.0-1.fc45".into()),
            pkg_env: "e".into(),
            spec_edit: "s".into(),
            patches: vec![("0001-build.patch".into(), "a".into())],
            source1_tree: None,
            n: 3,
        };
        let text = preimage(&k);
        assert_eq!(
            text,
            format!(
                "apex lane key 2\npkg gnome-shell\nlane {}\ncheck -\nrepos --repo=fedora --repo=updates --setopt=install_weak_deps=False\nstock gnome-shell-51.0-1.fc45\npin 51.0-1.fc45\npkg.env e\nspec-edit s\npatch 0001-build.patch a\nsource1 -\nrelease .apex3\n",
                "t".repeat(64)
            )
        );
        let key = content_key(&k.stock, &text);
        assert!(key.starts_with("gnome-shell-51.0-1.fc45-s") && key.len() == 23 + 2 + 12);
    }
}
