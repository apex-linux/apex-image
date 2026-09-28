/// A lane package (a directory of packaging/pkgs), and a family: `^[a-z0-9][a-z0-9._+-]*$`.
/// image.sh and `apexctl manifest --held` accept no other family name.
pub fn is_pkg_name(s: &str) -> bool {
    let b = s.as_bytes();
    !b.is_empty()
        && (b[0].is_ascii_lowercase() || b[0].is_ascii_digit())
        && b.iter()
            .all(|&c| c.is_ascii_lowercase() || c.is_ascii_digit() || b"._+-".contains(&c))
}

pub fn is_family_name(s: &str) -> bool {
    is_pkg_name(s)
}

/// An RPM name: `^[A-Za-z0-9._+-]+$`.
pub fn is_package_name(s: &str) -> bool {
    !s.is_empty()
        && s.bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"._+-".contains(&c))
}

/// A series entry: `^[0-9]{4}-[A-Za-z0-9._-]+\.patch$`.
pub fn is_patch_name(s: &str) -> bool {
    let b = s.as_bytes();
    let Some(stem) = s.strip_suffix(".patch") else {
        return false;
    };
    b.len() > 11
        && b[..4].iter().all(u8::is_ascii_digit)
        && b[4] == b'-'
        && stem.len() > 5
        && stem.as_bytes()[5..]
            .iter()
            .all(|&c| c.is_ascii_alphanumeric() || b"._-".contains(&c))
}

/// A release or EVR value the lane writes into a spec or passes to rpm's Lua:
/// `^[A-Za-z0-9._:~^+-]+$`.
pub fn is_release_value(s: &str) -> bool {
    !s.is_empty()
        && s.bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"._:~^+-".contains(&c))
}

/// The package name of `name-epoch:version-release.arch`
/// (`^(.+)-[0-9]+:[^-]+-[^-]+\.[^.]+$`).
pub fn nevra_name(nevra: &[u8]) -> Option<&[u8]> {
    (1..nevra.len())
        .rev()
        .filter(|&i| nevra[i] == b'-')
        .find(|&i| is_epoch_vr_arch(&nevra[i + 1..]))
        .map(|i| &nevra[..i])
}

/// `[0-9]+:[^-]+-[^-]+\.[^.]+`
fn is_epoch_vr_arch(s: &[u8]) -> bool {
    let Some(colon) = s.iter().position(|&b| b == b':') else {
        return false;
    };
    if colon == 0 || !s[..colon].iter().all(u8::is_ascii_digit) {
        return false;
    }
    let rest = &s[colon + 1..];
    let dashes: Vec<usize> = rest
        .iter()
        .enumerate()
        .filter(|(_, b)| **b == b'-')
        .map(|(i, _)| i)
        .collect();
    let [dash] = dashes[..] else {
        return false;
    };
    let release_arch = &rest[dash + 1..];
    let Some(dot) = release_arch.iter().rposition(|&b| b == b'.') else {
        return false;
    };
    dash > 0 && dot > 0 && dot + 1 < release_arch.len()
}

/// `E:V-R` of a NEVRA, and no epoch when it is 0
/// (`sed -E 's/^.+-([0-9]+:[^-]+-[^-]+)\.[^.]+$/\1/; s/^0://'`).
pub fn nevra_evr(nevra: &[u8]) -> Vec<u8> {
    let evr = match nevra_name(nevra) {
        Some(name) => {
            let tail = &nevra[name.len() + 1..];
            let dot = tail.iter().rposition(|&b| b == b'.').unwrap_or(tail.len());
            tail[..dot].to_vec()
        }
        None => nevra.to_vec(),
    };
    match evr.strip_prefix(b"0:") {
        Some(rest) => rest.to_vec(),
        None => evr,
    }
}

/// `<stock NVR>-s<12 lowercase hex>`: the content key, also a store directory name.
pub fn is_content_key(s: &str) -> bool {
    let Some((nvr, hex)) = s.rsplit_once("-s") else {
        return false;
    };
    hex.len() == 12
        && hex
            .bytes()
            .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
        && is_release_value(nvr)
        && !nvr.contains(':')
}

/// The words of a pkg.env list value.
pub fn words(value: &str) -> Vec<String> {
    value
        .split([' ', '\t', '\n'])
        .filter(|w| !w.is_empty())
        .map(str::to_owned)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nevra_names() {
        assert_eq!(
            nevra_name(b"gnome-shell-common-0:51.0-1.fc45.apex1.noarch"),
            Some(&b"gnome-shell-common"[..])
        );
        assert_eq!(
            nevra_name(b"mutter-0:51.0-1.fc45.x86_64"),
            Some(&b"mutter"[..])
        );
        assert_eq!(nevra_name(b"mutter-51.0-1.fc45.x86_64"), None);
        assert_eq!(nevra_name(b"-0:1-1.x"), None);
        assert_eq!(nevra_name(b"a-0:1-1.x"), Some(&b"a"[..]));
        assert_eq!(nevra_name(b"a-0:1-1."), None);
    }

    #[test]
    fn nevra_evrs() {
        assert_eq!(
            nevra_evr(b"gnome-shell-0:51.0-1.fc45.apex2.x86_64"),
            b"51.0-1.fc45.apex2"
        );
        assert_eq!(nevra_evr(b"x-2:1.0-3.fc45.noarch"), b"2:1.0-3.fc45");
        assert_eq!(nevra_evr(b"not a nevra"), b"not a nevra");
    }

    #[test]
    fn names() {
        assert!(is_patch_name("0001-build.patch"));
        assert!(is_patch_name("0101-a.b_c-d.patch"));
        assert!(!is_patch_name("001-build.patch"));
        assert!(!is_patch_name("0001-.patch"));
        assert!(!is_patch_name("../x.patch"));
        assert!(!is_patch_name("0001-a/b.patch"));
        assert!(is_pkg_name("gnome-shell") && !is_pkg_name("Gnome") && !is_pkg_name("-x"));
        assert!(is_package_name("NetworkManager-libnm") && !is_package_name("a b"));
        assert!(is_content_key("gnome-shell-51.0-1.fc45-s22726911a8d4"));
        assert!(!is_content_key("gnome-shell-51.0-1.fc45-s22726911a8d"));
        assert!(!is_content_key("../x-s22726911a8d4"));
    }
}
