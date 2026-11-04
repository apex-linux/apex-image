use crate::core::text;

pub const FORMAT_LINE: &str = "# apex-lane manifest 1: kind nevra sha256 file";

/// The last ` NAME=` on the first `# ` line that has one: the greedy sed rule the stored
/// manifests were read with.
pub fn header_field(manifest: &[u8], name: &str) -> Vec<u8> {
    let needle = format!(" {name}=");
    for line in text::lines(manifest) {
        let Some(rest) = line.strip_prefix(b"# ") else {
            continue;
        };
        let at = (0..rest.len())
            .rev()
            .find(|&i| rest[i..].starts_with(needle.as_bytes()));
        if let Some(at) = at {
            let value = &rest[at + needle.len()..];
            let end = value.iter().position(|&b| b == b' ').unwrap_or(value.len());
            return value[..end].to_vec();
        }
    }
    Vec::new()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Entry<'a> {
    pub kind: &'a [u8],
    pub nevra: &'a [u8],
    pub sha256: &'a [u8],
    pub file: &'a [u8],
}

pub fn entries(manifest: &[u8]) -> Vec<Entry<'_>> {
    text::lines(manifest)
        .into_iter()
        .filter(|line| !line.starts_with(b"#"))
        .map(|line| {
            let f = text::read_fields(line, 4);
            Entry {
                kind: f[0],
                nevra: f[1],
                sha256: f[2],
                file: f[3],
            }
        })
        .collect()
}

pub fn is_stored_kind(kind: &[u8]) -> bool {
    matches!(kind, b"built" | b"mirror" | b"dev" | b"apex-srpm")
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Header {
    pub pkg: String,
    pub family: String,
    pub key: String,
    pub release: String,
    pub n: u64,
    pub stock: String,
    pub pin_nvr: Option<String>,
    pub fedora: String,
    pub base: String,
}

pub fn render_header(h: &Header) -> String {
    format!(
        "{FORMAT_LINE}\n# pkg={} family={} key={} release={} n={} stock={} pin={} fedora={} base={}\n",
        h.pkg,
        h.family,
        h.key,
        h.release,
        h.n,
        h.stock,
        h.pin_nvr.as_deref().unwrap_or("-"),
        h.fedora,
        if h.base.is_empty() { "?" } else { &h.base },
    )
}

pub fn entry_line(kind: &str, nevra: &str, sha256: &str, file: &str) -> String {
    format!("{kind} {nevra} {sha256} {file}\n")
}

/// The Apex RPM key signs these; `mirror` and `dev` RPMs keep Fedora's signature.
pub fn is_signed_kind(kind: &[u8]) -> bool {
    matches!(kind, b"built" | b"apex-srpm")
}

const SIG_LINE: &[u8] = b"# sig=";

/// `manifest` after `signed` (name, new sha256) were signed with `fingerprint`: their entries get
/// the new digests and one `# sig=` line names the key. `None` when no entry names any of them.
pub fn resigned(
    manifest: &[u8],
    signed: &[(String, String)],
    fingerprint: &str,
) -> Option<Vec<u8>> {
    let mut out = Vec::with_capacity(manifest.len() + 64);
    let mut named = false;
    for line in text::lines(manifest) {
        if line.starts_with(SIG_LINE) {
            continue;
        }
        let f = text::read_fields(line, 4);
        let hit = if line.starts_with(b"#") {
            None
        } else {
            signed.iter().find(|(file, _)| file.as_bytes() == f[3])
        };
        if let Some((file, sha256)) = hit {
            named = true;
            out.extend_from_slice(
                entry_line(&text::lossy(f[0]), &text::lossy(f[1]), sha256, file).as_bytes(),
            );
        } else {
            out.extend_from_slice(line);
            out.push(b'\n');
        }
    }
    out.extend_from_slice(SIG_LINE);
    out.extend_from_slice(fingerprint.as_bytes());
    out.push(b'\n');
    named.then_some(out)
}

/// The fingerprint of the key the set was signed with, or `none` for a set stored before
/// the lane signed.
pub fn signed_with(manifest: &[u8]) -> Option<&[u8]> {
    text::lines(manifest)
        .into_iter()
        .rev()
        .find_map(|line| line.strip_prefix(SIG_LINE))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn header_field_rule() {
        let m = b"# apex-lane manifest 1: kind nevra sha256 file\n# pkg=x key=k1 release=r1 n=3 stock=s pin=-\n";
        assert_eq!(header_field(m, "key"), b"k1");
        assert_eq!(header_field(m, "release"), b"r1");
        assert_eq!(header_field(m, "pin"), b"-");
        assert_eq!(header_field(m, "nope"), b"");
        assert_eq!(
            header_field(b"# key=a\n# x key=b key=c\n", "key"),
            b"c",
            "the last on the first line that has it"
        );
        assert_eq!(header_field(b"#  key=a b\n", "key"), b"a");
        assert_eq!(
            header_field(b"# x key= y\n# x key=z\n", "key"),
            b"",
            "an empty value still counts"
        );
        assert_eq!(header_field(b"x key=a\n", "key"), b"");
    }

    #[test]
    fn resigning_replaces_digests_and_the_sig_line() {
        let m = b"# apex-lane manifest 1: kind nevra sha256 file\n# pkg=x\nbuilt a-0:1-1.x86_64 aaa a-1-1.x86_64.rpm\nmirror m-0:1-1.x86_64 mmm m-1-1.x86_64.rpm\napex-srpm a-0:1-1.src sss a-1-1.src.rpm\n# sig=none\n";
        let signed = [
            ("a-1-1.x86_64.rpm".to_owned(), "AAA".to_owned()),
            ("a-1-1.src.rpm".to_owned(), "SSS".to_owned()),
        ];
        assert_eq!(
            resigned(m, &signed, "F00D").unwrap(),
            b"# apex-lane manifest 1: kind nevra sha256 file\n# pkg=x\nbuilt a-0:1-1.x86_64 AAA a-1-1.x86_64.rpm\nmirror m-0:1-1.x86_64 mmm m-1-1.x86_64.rpm\napex-srpm a-0:1-1.src SSS a-1-1.src.rpm\n# sig=F00D\n"
        );
        assert_eq!(
            resigned(m, &[("other.rpm".into(), "x".into())], "F00D"),
            None
        );
        assert_eq!(signed_with(m), Some(&b"none"[..]));
        assert_eq!(
            signed_with(&resigned(m, &signed, "F00D").unwrap()),
            Some(&b"F00D"[..])
        );
        assert_eq!(signed_with(b"# pkg=x\nbuilt a b c d\n"), None);
        assert!(is_signed_kind(b"built") && is_signed_kind(b"apex-srpm"));
        assert!(!is_signed_kind(b"mirror") && !is_signed_kind(b"dev"));
    }

    #[test]
    fn data_lines() {
        let m = b"# h\nbuilt  a-0:1-1.x86_64 abc\tf g \n\n";
        let e = entries(m);
        assert_eq!(e.len(), 2);
        assert_eq!(e[0].file, b"f g");
        assert_eq!(e[1].kind, b"");
    }
}
